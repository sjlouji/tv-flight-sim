import Foundation
import Observation
import RealityKit

/// Everything chosen on the start page.
struct FlightSetup: Sendable {
    var aircraft: AircraftType = .b737
    var scenario: Scenario
    var destinationICAO: String?
    var weather = WeatherSettings()
    var timeOfDay: TimeOfDay = .now
}

/// How the flight information is drawn over the 3D view.
enum DisplayMode: String, CaseIterable, Sendable {
    case headUp = "Head-up display"
    case glass = "Instruments"
    case map = "Map"
    case clean = "Clean view"

    var next: DisplayMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// The flight-deck panel: autopilot (mode control panel) and checklists.
struct PanelState: Equatable, Sendable {
    enum Tab: String, CaseIterable, Sendable {
        case autopilot = "Autopilot"
        case checklist = "Checklists"
    }

    /// Mode control panel controls, left to right.
    enum Control: Equatable, Sendable {
        case button(MCPButton)
        case speed, heading, altitude, verticalSpeed, autobrake

        var title: String {
            switch self {
            case .button(let button): button.rawValue
            case .speed: "SPD"
            case .heading: "HDG"
            case .altitude: "ALT"
            case .verticalSpeed: "V/S"
            case .autobrake: "AUTO BRAKE"
            }
        }

        var isValue: Bool {
            if case .button = self { return false }
            return true
        }
    }

    /// The panel's controls, top to bottom; the autobrake only on aircraft that have one.
    static func controls(for aircraft: AircraftProfile) -> [Control] {
        [.button(.autothrottle), .button(.n1), .speed, .button(.levelChange), .heading, .button(.lnav), .button(.approach),
         .altitude, .button(.altitudeHold), .verticalSpeed, .button(.autopilot)] + (aircraft.hasAutobrake ? [.autobrake] : [])
    }

    var tab: Tab = .autopilot
    var controlIndex = 0
    var checklistPhase: FlightPhase
    var checklistItem = 0
    /// True once the pilot picks a checklist; until then the panel follows the flight phase.
    var checklistChosen = false
}

/// Navigation figures for the displays.
struct NavigationDisplay: Equatable, Sendable {
    var plan: FlightPlan
    var activeWaypoint: String
    var distanceToGoNM: Double
    var timeToGoSeconds: Double?
    var desiredTrackDegrees: Double
    var crossTrackNM: Double
    var localizerDeviationDegrees: Double?
    var glideslopeDeviationDegrees: Double?
    var topOfDescentNM: Double?
}

/// Everything the 2D displays need, refreshed at a reduced rate to keep SwiftUI work low.
struct CockpitDisplay: Sendable {
    var aircraft: AircraftProfile
    var telemetry = Telemetry()
    var controls = FlightControls()
    var flapLabel = "UP"
    var speedbrakeLabel = "DOWN"
    var autopilot: Autopilot
    var autobrake: AutobrakeSetting = .off
    var autobrakeActive = false
    var phase: FlightPhase = .beforeTakeoff
    var lights = ExteriorLights()
    var navigation: NavigationDisplay?
    var checklistContext: ChecklistContext?
    var checklistProgress = ChecklistProgress()
    var simulationDate = Date()
    /// Time since the flight started (or was restarted).
    var flightTimeSeconds: Double = 0
}

/// One flight: input, flight model, automation, pause menu and failure reporting.
@MainActor
@Observable
final class FlightSession {
    enum Phase: Equatable {
        case loading
        case flying
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let airport: Airport
    let setup: FlightSetup
    let aircraft: AircraftProfile
    let plan: FlightPlan?
    private(set) var phase: Phase = .loading
    private(set) var isPaused = false
    private(set) var display: CockpitDisplay
    private(set) var cameraTitle = ""
    /// Starts from the "displayMode" user default when a launch argument sets it (used by the UI tests).
    private(set) var displayMode: DisplayMode = UserDefaults.standard.string(forKey: "displayMode").flatMap(DisplayMode.init(rawValue:)) ?? .headUp
    private(set) var panel: PanelState?
    private(set) var message: String?
    private(set) var controllerConnected = false
    /// Camera choices for the pause menu; set by the scene.
    private(set) var cameraTitles: [String] = []
    /// True while the camera is on the flight deck, where the 3D displays replace the 2D ones.
    private(set) var cameraInCockpit = false
    /// True in the cabin views, where a head-up display would make no sense.
    private(set) var cameraInCabin = false

    @ObservationIgnored var onExit: (() -> Void)?
    @ObservationIgnored var sceneSubscription: EventSubscription?
    /// The glass displays, drawn off the main thread; the 2D overlay and the flight deck both show them.
    @ObservationIgnored let instruments = InstrumentRenderer()
    @ObservationIgnored private var model: FlightModel?
    @ObservationIgnored private var mapper: ControlMapper
    @ObservationIgnored private var autopilot = Autopilot()
    @ObservationIgnored private var systems: AircraftSystems
    @ObservationIgnored private var route = RouteProgress()
    @ObservationIgnored private var checklists = ChecklistProgress()
    @ObservationIgnored private let ground: GroundModel
    /// Terrain heights, shared with the scene's terrain renderer.
    @ObservationIgnored let terrain = TerrainHeights()
    @ObservationIgnored private let input = GamepadInput()
    @ObservationIgnored private let sound = SoundEngine()
    @ObservationIgnored private var pendingCamera: CameraRequest?
    @ObservationIgnored private var displayTimer: Double = 0
    @ObservationIgnored private var messageExpiry: Double = 0
    @ObservationIgnored private var clock: Double = 0
    @ObservationIgnored private var startDate: Date
    @ObservationIgnored private var lastControls = FlightControls()
    @ObservationIgnored private var lastTelemetry = Telemetry()
    @ObservationIgnored private var slowFrames = 0
    @ObservationIgnored private var slowFrameWindowStart: Double = 0

    enum CameraRequest: Equatable {
        case next
        case named(String)
    }

    /// What the 3D scene needs after one frame of simulation.
    struct FrameResult {
        let pose: Pose
        let telemetry: Telemetry
        let controls: FlightControls
        let look: SIMD2<Float>
        let camera: CameraRequest?
        let lights: ExteriorLights
        let date: Date
        let deltaTime: Double
    }

    static let displayInterval = 1.0 / 20.0
    static let messageDuration = 3.0
    /// A frame this long (two display refreshes at 60 Hz) is a visible hitch and is logged.
    static let slowFrameSeconds = 1.0 / 30.0

    init(airport: Airport, setup: FlightSetup, database: NavDatabase) {
        self.airport = airport
        self.setup = setup
        let aircraft = AircraftProfile.profile(setup.aircraft)
        self.aircraft = aircraft
        mapper = ControlMapper(aircraft: aircraft, initial: FlightControls())
        systems = AircraftSystems(aircraft: aircraft)
        display = CockpitDisplay(aircraft: aircraft, autopilot: Autopilot())
        let terrain = self.terrain
        ground = GroundModel(airport: airport, terrain: { terrain.rawElevation(at: $0) })
        terrain.flattened = airport.boundary.map { ring in
            FlattenedArea(ring: ring.map { GeoPoint(latitude: $0[0], longitude: $0[1]) }, elevationMeters: airport.reference.elevationM)
        }
        startDate = setup.timeOfDay.date(today: Date(), latitude: airport.reference.latitude, longitude: airport.reference.longitude)
        if let icao = setup.destinationICAO, let destination = database.airport(icao: icao),
           let runway = destination.bestRunway(windFromDegrees: setup.weather.windFromDegrees, windSpeedKnots: setup.weather.windSpeedKnots) {
            plan = FlightPlan(departureICAO: airport.icao, departure: GeoPoint(latitude: airport.reference.latitude, longitude: airport.reference.longitude),
                              destination: destination, arrivalRunway: runway)
        } else {
            plan = nil
        }
    }

    var simulationDate: Date { startDate.addingTimeInterval(clock) }

    /// Where the flight starts, standing on the real terrain.
    func startCondition() throws -> StartCondition {
        guard let model else { throw SessionError.notStarted }
        let terrain = self.terrain
        return try setup.scenario.startCondition(at: airport, aircraft: aircraft, geometry: model.geometry,
                                                 terrain: { terrain.rawElevation(at: $0) })
    }

    /// Loads the aircraft into JSBSim. Returns its geometry, which the scene builds the drawn aircraft from.
    func loadAircraft(bundle: Bundle = .main) throws -> AircraftGeometry {
        guard let dataDirectory = bundle.url(forResource: "jsbsim-data", withExtension: nil) else {
            throw SessionError.missingFlightData
        }
        let model = try FlightModel(dataDirectory: dataDirectory, profile: aircraft)
        self.model = model
        return model.geometry
    }

    /// Loads the terrain under the airport and the start position before the flight begins. If it can't be
    /// downloaded the flight still starts, with a notice on screen (the ground outside airports is then sea level).
    func prepareTerrain() async {
        let airportPoint = GeoPoint(latitude: airport.reference.latitude, longitude: airport.reference.longitude)
        var points = [airportPoint]
        if case .airborne(_, let bearing, let distance, _) = setup.scenario {
            points.append(Navigation.destination(from: airportPoint, bearingDegrees: bearing,
                                                 distanceMeters: distance * Navigation.metersPerNauticalMile))
        }
        for point in points {
            do {
                try await terrain.load(around: point)
            } catch {
                Log.world.error("Terrain could not be loaded at the start: \(error.localizedDescription, privacy: .public)")
                show("Terrain is unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Places the loaded aircraft and starts flying. Failures are shown on screen, never hidden.
    func start() {
        do {
            guard let geometry = model?.geometry else { throw SessionError.notStarted }
            try restart()
            phase = .flying
            Task {
                do {
                    try await sound.start(aircraft: aircraft, geometry: geometry)
                } catch {
                    Log.app.error("Sound failed to start: \(error.localizedDescription, privacy: .public)")
                    show("Sound is unavailable: \(error.localizedDescription)")
                }
            }
        } catch {
            fail(error)
        }
    }

    func restart() throws {
        guard let model else { throw SessionError.notStarted }
        let start = try startCondition()
        let trimmed = try model.reset(to: start, atmosphere: setup.weather.atmosphere)
        mapper = ControlMapper(aircraft: aircraft, initial: trimmed)
        autopilot = Autopilot()
        route = RouteProgress()
        checklists = ChecklistProgress()
        clock = 0
        let telemetry = model.telemetry()
        autopilot.mcp.headingDegrees = start.headingDegrees.rounded()
        switch setup.scenario {
        case .takeoff:
            systems = AircraftSystems(aircraft: aircraft, phase: .beforeTakeoff)
            if aircraft.hasAutobrake { systems.autobrake = .rto }
            autopilot.mcp.speedKnots = aircraft.v2 + 20
            autopilot.mcp.altitudeFeet = min(5_000, aircraft.ceiling)
        case .approach:
            systems = AircraftSystems(aircraft: aircraft, phase: .landing)
            if aircraft.hasAutobrake { systems.autobrake = .two }
            autopilot.mcp.speedKnots = aircraft.approachSpeed
            autopilot.mcp.altitudeFeet = 2_000
        case .airborne(let altitude, _, _, _):
            systems = AircraftSystems(aircraft: aircraft, phase: altitude > 10_000 ? .cruise : .climb)
            autopilot.mcp.speedKnots = aircraft.speed(atAltitude: altitude)
            autopilot.mcp.altitudeFeet = altitude
        }
        isPaused = false
        panel = nil
        lastControls = trimmed
        lastTelemetry = telemetry
        refreshDisplay(telemetry)
    }

    func fail(_ error: Error) {
        Log.app.error("Flight failed: \(error.localizedDescription, privacy: .public)")
        phase = .failed(error.localizedDescription)
        sound.stop()
        sceneSubscription?.cancel()
        sceneSubscription = nil
    }

    func end() {
        sceneSubscription?.cancel()
        sceneSubscription = nil
        sound.stop()
        input.stop()
        onExit?()
    }

    // MARK: - Pause menu (SwiftUI focus drives it while paused)

    func resume() { isPaused = false; sound.setPaused(false) }

    func restartFromMenu() {
        do { try restart(); sound.setPaused(false) } catch { fail(error) }
    }

    func selectCamera(_ title: String) {
        pendingCamera = .named(title)
        resume()
    }

    func selectDisplayMode(_ mode: DisplayMode) { displayMode = mode }

    /// Called by the scene when the camera changes.
    func cameraChanged(title: String, all titles: [String], inCockpit: Bool, inCabin: Bool) {
        cameraTitle = title
        if cameraInCockpit != inCockpit { cameraInCockpit = inCockpit }
        if cameraInCabin != inCabin { cameraInCabin = inCabin }
        if cameraTitles != titles { cameraTitles = titles }
    }

    // MARK: - Per frame

    /// Runs once per rendered frame. Returns the aircraft state to draw, or nil if there is nothing to draw yet.
    func frame(deltaTime dt: Double) -> FrameResult? {
        guard phase == .flying, let model else { return nil }
        if dt > Self.slowFrameSeconds { noteSlowFrame(dt) }
        if controllerConnected != input.isConnected { controllerConnected = input.isConnected }
        if message != nil && clock > messageExpiry { message = nil }

        let pad = input.snapshot()
        if isPaused {
            // The pause menu is a focusable SwiftUI view; keep the mapper's button history current so
            // the press that resumed doesn't also act on the aircraft.
            _ = mapper.update(with: pad, deltaTime: 0, onGround: lastTelemetry.weightOnWheels, panelOpen: true)
            return FrameResult(pose: model.renderPose, telemetry: lastTelemetry, controls: lastControls, look: .zero,
                               camera: takeCameraRequest(), lights: systems.lights, date: simulationDate, deltaTime: 0)
        }
        clock += dt

        let before = lastTelemetry
        for event in mapper.update(with: pad, deltaTime: dt, onGround: before.weightOnWheels, panelOpen: panel != nil) {
            handle(event, telemetry: before)
        }
        let guidance = guidanceInput(before)
        let (automation, autopilotEvents) = autopilot.update(telemetry: before, pilot: mapper.controls,
                                                             pilotMovedThrust: mapper.pilotMovedThrust, guidance: guidance, deltaTime: dt)
        mapper.adopt(throttle: automation.throttle, pitchTrim: automation.pitchTrim)
        var commanded = mapper.controls
        if let aileron = automation.aileron { commanded.aileron = aileron }
        if let elevator = automation.elevator { commanded.elevator = elevator }
        let (controls, systemEvents) = systems.update(telemetry: before, pilot: commanded,
                                                      speedbrakeArmed: mapper.speedbrakeArmed, deltaTime: dt)
        model.setTerrainElevation(feet: ground.elevationMeters(latitude: before.latitude, longitude: before.longitude).metersToFeet)
        model.apply(controls)
        do {
            try model.advance(by: dt)
        } catch {
            fail(error)
            return nil
        }
        let telemetry = model.telemetry()
        if let plan { route.update(position: GeoPoint(latitude: telemetry.latitude, longitude: telemetry.longitude), plan: plan) }
        announce(autopilotEvents: autopilotEvents, systemEvents: systemEvents)
        sound.update(telemetry: telemetry, controls: controls, deltaTime: dt)
        lastControls = controls
        lastTelemetry = telemetry

        displayTimer += dt
        if displayTimer >= Self.displayInterval {
            displayTimer = 0
            refreshDisplay(telemetry)
        }
        return FrameResult(pose: model.renderPose, telemetry: telemetry, controls: controls, look: mapper.cameraLook,
                           camera: takeCameraRequest(), lights: systems.lights, date: simulationDate, deltaTime: dt)
    }

    /// Tells the sound which space the listener is in (cockpit, cabin or outside), as the camera changes.
    func setListener(_ listener: SoundEngine.Listener) { sound.listener = listener }

    private func takeCameraRequest() -> CameraRequest? {
        defer { pendingCamera = nil }
        return pendingCamera
    }

    private func noteSlowFrame(_ dt: Double) {
        if clock - slowFrameWindowStart > 10 {
            if slowFrames > 0 { Log.app.warning("\(self.slowFrames) slow frames in the last 10 s") }
            slowFrames = 0
            slowFrameWindowStart = clock
        }
        slowFrames += 1
        if slowFrames == 1 { Log.app.warning("Slow frame: \(dt * 1000, format: .fixed(precision: 1)) ms") }
    }

    private func handle(_ event: CockpitEvent, telemetry: Telemetry) {
        switch event {
        case .togglePause:
            isPaused = true
            sound.setPaused(true)
        case .cycleCamera:
            pendingCamera = .next
        case .cycleDisplay:
            displayMode = displayMode.next
            show(displayMode.rawValue)
        case .togglePanel:
            panel = panel == nil ? PanelState(checklistPhase: systems.phase) : nil
        case .panel(let input):
            handlePanel(input, telemetry: telemetry)
        case .rejected(let text):
            show(text)
        }
    }

    private func handlePanel(_ input: PanelInput, telemetry: Telemetry) {
        guard var state = panel else { return }
        switch input {
        case .back:
            panel = nil
            return
        case .previousTab, .nextTab:
            let tabs = PanelState.Tab.allCases
            let index = tabs.firstIndex(of: state.tab)! + (input == .nextTab ? 1 : tabs.count - 1)
            state.tab = tabs[index % tabs.count]
        case .left, .right, .up, .down, .select:
            switch state.tab {
            case .autopilot: autopilotPanel(input, state: &state, telemetry: telemetry)
            case .checklist: checklistPanel(input, state: &state)
            }
        }
        panel = state
        refreshDisplay(lastTelemetry)
    }

    private func autopilotPanel(_ input: PanelInput, state: inout PanelState, telemetry: Telemetry) {
        let controls = PanelState.controls(for: aircraft)
        let control = controls[state.controlIndex]
        switch input {
        case .up: state.controlIndex = (state.controlIndex + controls.count - 1) % controls.count
        case .down: state.controlIndex = (state.controlIndex + 1) % controls.count
        case .left, .right:
            let step = input == .right ? 1.0 : -1.0
            switch control {
            case .speed:
                let range = aircraft.mcpSpeedRange
                autopilot.mcp.speedKnots = (autopilot.mcp.speedKnots + step).clamped(range.lowerBound, range.upperBound)
            case .heading:
                autopilot.mcp.headingDegrees = Telemetry.compassDegrees((autopilot.mcp.headingDegrees + step) * .pi / 180).rounded()
            case .altitude:
                autopilot.mcp.altitudeFeet = (autopilot.mcp.altitudeFeet + step * 500)
                    .clamped(aircraft.mcpAltitudeRange.lowerBound, aircraft.mcpAltitudeRange.upperBound)
            case .verticalSpeed:
                autopilot.mcp.verticalSpeedFPM = (autopilot.mcp.verticalSpeedFPM + step * 100)
                    .clamped(MCPSettings.verticalSpeedRange.lowerBound, MCPSettings.verticalSpeedRange.upperBound)
            case .autobrake:
                let all = AutobrakeSetting.allCases
                let index = (all.firstIndex(of: systems.autobrake)! + (input == .right ? 1 : all.count - 1)) % all.count
                systems.autobrake = all[index]
            case .button:
                break
            }
        case .select:
            let button: MCPButton? = switch control {
            case .button(let button): button
            case .speed: .speed
            case .heading: .heading
            case .altitude: .altitudeHold
            case .verticalSpeed: .verticalSpeed
            case .autobrake: nil
            }
            if let button {
                let events = autopilot.press(button, telemetry: telemetry, controls: mapper.controls, guidance: guidanceInput(telemetry))
                announce(autopilotEvents: events, systemEvents: [])
            }
        case .back, .previousTab, .nextTab:
            break
        }
    }

    private func checklistPanel(_ input: PanelInput, state: inout PanelState) {
        let phases = FlightPhase.allCases
        let checklist = Checklists.checklist(for: state.checklistPhase, aircraft: aircraft)
        switch input {
        case .left, .right:
            let index = phases.firstIndex(of: state.checklistPhase)! + (input == .right ? 1 : phases.count - 1)
            state.checklistPhase = phases[index % phases.count]
            state.checklistItem = 0
            state.checklistChosen = true
        case .up: state.checklistItem = max(state.checklistItem - 1, 0)
        case .down: state.checklistItem = min(state.checklistItem + 1, checklist.items.count - 1)
        case .select:
            let item = checklist.items[state.checklistItem]
            checklists.toggle(item)
            if state.checklistItem < checklist.items.count - 1 { state.checklistItem += 1 }
        case .back, .previousTab, .nextTab:
            break
        }
    }

    private func announce(autopilotEvents: [Autopilot.Event], systemEvents: [AircraftSystems.Event]) {
        for event in autopilotEvents {
            switch event {
            case .autopilotDisconnected(let reason):
                show("Autopilot disconnected: \(reason)")
                sound.chime(.autopilotDisconnect)
            case .autothrottleDisconnected(let reason):
                show("Autothrottle disconnected: \(reason)")
                sound.chime(.autothrottleDisconnect)
            case .rejected(let text):
                show(text)
            }
        }
        for event in systemEvents {
            switch event {
            case .message(let text): show(text)
            case .callout(let callout): sound.speak(callout)
            }
        }
    }

    private func guidanceInput(_ t: Telemetry) -> GuidanceInput {
        let position = GeoPoint(latitude: t.latitude, longitude: t.longitude)
        guard let plan else { return GuidanceInput(position: position) }
        return GuidanceInput(position: position, lnavTrackDegrees: route.desiredTrackDegrees(position: position, plan: plan),
                             landingSystem: plan.landingSystem)
    }

    private func show(_ text: String) {
        message = text
        messageExpiry = clock + Self.messageDuration
    }

    private func refreshDisplay(_ telemetry: Telemetry) {
        if var state = panel, !state.checklistChosen, state.checklistPhase != systems.phase {
            state.checklistPhase = systems.phase
            state.checklistItem = 0
            panel = state
        }
        let context = ChecklistContext(telemetry: telemetry, controls: lastControls, flapDetent: mapper.flapDetent,
                                       speedbrakeArmed: mapper.speedbrakeArmed, autobrake: systems.autobrake, autopilot: autopilot,
                                       lights: systems.lights, hasRoute: plan != nil,
                                       fieldElevationFeet: airport.reference.elevationM.metersToFeet)
        display = CockpitDisplay(aircraft: aircraft, telemetry: telemetry, controls: lastControls, flapLabel: mapper.flapLabel,
                                 speedbrakeLabel: mapper.speedbrakeLabel, autopilot: autopilot, autobrake: systems.autobrake,
                                 autobrakeActive: systems.autobrakeActive, phase: systems.phase, lights: systems.lights,
                                 navigation: navigationDisplay(telemetry), checklistContext: context,
                                 checklistProgress: checklists, simulationDate: simulationDate, flightTimeSeconds: clock)
    }

    private func navigationDisplay(_ t: Telemetry) -> NavigationDisplay? {
        guard let plan else { return nil }
        let position = GeoPoint(latitude: t.latitude, longitude: t.longitude)
        let leg = route.activeLeg(plan)
        let remaining = route.remainingMeters(position: position, plan: plan) / Navigation.metersPerNauticalMile
        let ils = plan.landingSystem
        let onFinal = ils.distanceToThresholdMeters(position) > 0 && ils.distanceToThresholdMeters(position) < 25 * Navigation.metersPerNauticalMile
        let descentNM = (t.altitudeMSLFeet - plan.arrivalRunway.elevationFt) / 1_000 * 3 + 10
        return NavigationDisplay(
            plan: plan, activeWaypoint: leg.to.name, distanceToGoNM: remaining,
            timeToGoSeconds: t.groundSpeedKnots > 30 ? remaining / t.groundSpeedKnots * 3_600 : nil,
            desiredTrackDegrees: route.desiredTrackDegrees(position: position, plan: plan),
            crossTrackNM: Navigation.crossTrackMeters(position, from: leg.from.position, to: leg.to.position) / Navigation.metersPerNauticalMile,
            localizerDeviationDegrees: onFinal ? ils.localizerDeviationDegrees(position) : nil,
            glideslopeDeviationDegrees: onFinal ? ils.glideslopeDeviationDegrees(position, altitudeFeet: t.altitudeMSLFeet) : nil,
            topOfDescentNM: remaining > descentNM && t.altitudeMSLFeet > 10_000 ? remaining - descentNM : nil)
    }
}

enum SessionError: LocalizedError {
    case missingFlightData
    case notStarted

    var errorDescription: String? {
        switch self {
        case .missingFlightData: "The JSBSim aircraft data is missing from the app bundle."
        case .notStarted: "The flight model has not been loaded."
        }
    }
}
