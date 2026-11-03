import Metal
import RealityKit
import UIKit
import simd

/// The complete 3D world for one flight, and the per-frame link from the simulation to entities.
///
/// Every frame the world is re-centered on the aircraft (a floating origin on a local tangent frame), so
/// coordinates near the camera stay small and Float precision never shows as jitter however far the
/// flight goes. Earth-fixed content (airport, sea, clouds) is placed relative to the aircraft each frame.
@MainActor
final class FlightScene {
    let root = Entity()
    private let sky: Sky
    private let ocean: Ocean
    private let clouds: Clouds
    private let terrain: TerrainRenderer
    private let airportScene: AirportScene
    private let aircraft: AircraftModel
    private let cockpit: Cockpit
    private let cabin: Cabin?
    private let cameraRig: CameraRig
    private let instruments: InstrumentRenderer
    private let whiteout: ModelEntity
    private let airportFrame: LocalFrame
    private let hazeDensity: Float

    static func build(airport: Airport, setup: FlightSetup, aircraft profile: AircraftProfile, geometry: AircraftGeometry,
                      start: StartCondition, date: Date, instruments: InstrumentRenderer,
                      terrain heights: TerrainHeights) async throws -> FlightScene {
        let shaders = try ShaderLibrary.load()
        let fieldElevation = airport.reference.elevationM
        let startAltitude = (start.terrainElevationFeet + start.altitudeAGLFeet).feetToMeters
        let lightingRoot = Entity()
        let sky = try await Sky.build(lightingRoot: lightingRoot, shaders: shaders, weather: setup.weather,
                                      fieldElevationMeters: fieldElevation, date: date, latitude: start.latitude,
                                      longitude: start.longitude, altitudeMeters: startAltitude)
        let haze = HazeSettings(visibilityMeters: setup.weather.preset.visibilityMeters, originAltitudeMeters: fieldElevation)
        let materials = try await MaterialLibrary.load(shaders: shaders, sky: sky.texture, haze: haze)
        let airportScene = try AirportScene.build(airport: airport, materials: materials)
        let aircraft = try AircraftModel(profile: profile, geometry: geometry, materials: materials)
        let shape = aircraft.shape
        let cockpit = try Cockpit(materials: materials, profile: profile, shape: shape, engineCount: geometry.engines.count)
        let cabin = try CabinLayout(profile: profile, shape: shape).map { try Cabin(materials: materials, layout: $0, shape: shape) }
        let ocean = try Ocean(shaders: shaders, sky: sky.texture)
        let clouds = try Clouds(weather: setup.weather, fieldElevationMeters: fieldElevation, shaders: shaders, sky: sky.texture)
        let terrain = try TerrainRenderer(heights: heights, shaders: shaders, sky: sky.texture, hazeDensity: haze.densityPerMeter,
                                          lightingRoot: lightingRoot)

        // Tower camera: the control tower cab if the map has one, otherwise beside the runway's touchdown zone.
        let runway = setup.scenario.runwayDesignator(at: airport).flatMap { name in airport.runwayEnds().first { $0.designator == name } }
        let fallback = runway.map { end -> SIMD3<Float> in
            let p = end.threshold + end.direction * 450 + SIMD2(-end.direction.y, end.direction.x) * 220
            return SIMD3(p.x, 10, p.y)
        } ?? SIMD3(0, 30, 0)
        let towerECEF = airport.geoReference.frame.ecefPoint(scene: SIMD3<Double>(airportScene.towerCab ?? fallback))
        let seatNames = switch cockpit.style {
        case .airliner: ("Captain", "First officer")
        case .light: ("Left seat", "Right seat")
        case .fighter: ("Pilot", "Back seat")
        }
        let eyes = CameraEyes(captain: cockpit.captainEye, firstOfficer: cockpit.firstOfficerEye, cabinCrew: cabin?.crewEye,
                              passenger: cabin?.passengerEye, wing: aircraft.wingCamera.eye, wingTarget: aircraft.wingCamera.target,
                              seatNames: seatNames, aircraftLength: profile.lengthMeters)
        let rig = CameraRig(eyes: eyes, towerECEF: towerECEF)
        return FlightScene(sky: sky, lightingRoot: lightingRoot, ocean: ocean, clouds: clouds, terrain: terrain, airportScene: airportScene,
                           aircraft: aircraft, cockpit: cockpit, cabin: cabin, cameraRig: rig, instruments: instruments,
                           airportFrame: airport.geoReference.frame, hazeDensity: haze.densityPerMeter)
    }

    private init(sky: Sky, lightingRoot: Entity, ocean: Ocean, clouds: Clouds, terrain: TerrainRenderer, airportScene: AirportScene,
                 aircraft: AircraftModel,
                 cockpit: Cockpit, cabin: Cabin?, cameraRig: CameraRig, instruments: InstrumentRenderer, airportFrame: LocalFrame,
                 hazeDensity: Float) {
        self.sky = sky
        self.ocean = ocean
        self.clouds = clouds
        self.terrain = terrain
        self.airportScene = airportScene
        self.aircraft = aircraft
        self.cockpit = cockpit
        self.cabin = cabin
        self.cameraRig = cameraRig
        self.instruments = instruments
        self.airportFrame = airportFrame
        self.hazeDensity = hazeDensity

        var veil = UnlitMaterial(color: UIColor(red: 0.86, green: 0.88, blue: 0.9, alpha: 1))
        veil.blending = .transparent(opacity: .init(floatLiteral: 1))
        whiteout = ModelEntity(mesh: .generatePlane(width: 6, height: 6), materials: [veil])
        whiteout.isEnabled = false
        cameraRig.camera.addChild(whiteout)
        cameraRig.camera.addChild(clouds.rain)

        aircraft.root.addChild(cockpit.root)
        if let cabin { aircraft.root.addChild(cabin.root) }
        lightingRoot.addChild(airportScene.root)
        lightingRoot.addChild(aircraft.root)
        lightingRoot.addChild(ocean.entity)
        root.addChild(lightingRoot)
        root.addChild(sky.root)
        root.addChild(clouds.root)
        root.addChild(terrain.root)
        root.addChild(cameraRig.camera)
        applyLightReceiver(to: lightingRoot, light: lightingRoot)
        showInterior(for: cameraRig.mode)
    }

    var cameraTitle: String { cameraRig.title(cameraRig.mode) }
    var cameraTitles: [String] { cameraRig.modes.map(cameraRig.title) }
    var listener: SoundEngine.Listener { cameraRig.mode.listener }
    var cameraInCockpit: Bool { cameraRig.mode.interior == .cockpit }
    var cameraInCabin: Bool { cameraRig.mode.interior == .cabin }

    /// Draws one frame. `overlay` lists the displays the 2D glass cockpit shows (they're drawn either way).
    func update(_ frame: FlightSession.FrameResult, display: CockpitDisplay, overlay: [InstrumentDisplay]) {
        let pose = frame.pose
        let dt = Float(frame.deltaTime)
        let altitude = pose.altitudeMSLFeet.feetToMeters
        let aircraftFrame = LocalFrame(latitude: pose.latitude, longitude: pose.longitude, height: altitude)
        let orientation = Attitude.orientation(roll: pose.roll, pitch: pose.pitch, heading: pose.heading)
        aircraft.root.position = .zero
        aircraft.root.orientation = orientation
        airportScene.root.transform = aircraftFrame.transform(from: airportFrame)

        switch frame.camera {
        case .next: cameraRig.cycle()
        case .named(let title): cameraRig.select(title: title)
        case nil: break
        }
        showInterior(for: cameraRig.mode)

        let t = frame.telemetry
        let groundSpeed = Float(t.groundSpeedKnots / 1.943_84)
        let track = Float(t.trackRadians)
        let velocity = SIMD3(sin(track) * groundSpeed, Float(t.verticalSpeedFeetPerMinute / 196.85), -cos(track) * groundSpeed)
        cameraRig.update(orientation: orientation, frame: aircraftFrame, velocity: velocity, look: frame.look,
                         loadFactor: Float(t.loadFactor), onGround: t.weightOnWheels, deltaTime: dt)
        let cameraPosition = cameraRig.camera.position(relativeTo: nil)

        sky.update(date: frame.date, latitude: pose.latitude, longitude: pose.longitude, altitudeMeters: altitude,
                   deltaTime: frame.deltaTime, camera: cameraPosition)
        let sun = sky.sunDirection
        let lighting = WorldLighting(sunAzimuth: atan2(sun.x, -sun.z), sunElevation: asin(sun.y.clamped(-1, 1)),
                                     sunVisibility: sky.sunVisibility, hazeDensity: hazeDensity, sunColor: sky.sunColor)
        let anchorPoint = airportFrame.scenePoint(ecef: aircraftFrame.origin)
        let anchor = SIMD2(anchorPoint.x, anchorPoint.z)
        ocean.update(anchor: anchor, altitudeMeters: altitude, lighting: lighting)
        terrain.update(aircraftFrame: aircraftFrame, camera: cameraPosition, deltaTime: frame.deltaTime)
        let inCloud = clouds.update(anchor: anchor, altitudeMeters: altitude, velocity: velocity, lighting: lighting)
        whiteout.isEnabled = inCloud > 0.01
        if whiteout.isEnabled {
            // Inside the cockpit or cabin, the veil hangs outside the windows so the interior stays visible.
            whiteout.position = SIMD3(0, 0, cameraRig.mode.interior == nil ? -0.6 : -2.4)
            whiteout.components.set(OpacityComponent(opacity: inCloud))
        }

        aircraft.update(with: t, lights: frame.lights, nightFactor: sky.nightFactor, deltaTime: frame.deltaTime)
        airportScene.update(viewer: airportScene.root.convert(position: cameraPosition, from: nil))

        var visible = overlay
        if cameraRig.mode.interior == .cockpit {
            cockpit.update(controls: frame.controls, telemetry: t)
            visible = Array(cockpit.displays.union(overlay))
        }
        let cockpit = self.cockpit
        let cockpitVisible = cameraRig.mode.interior == .cockpit
        instruments.update(state: display, visible: visible, deltaTime: frame.deltaTime) { kind, image in
            guard cockpitVisible else { return }
            do {
                try cockpit.show(image, on: kind)
            } catch {
                Log.world.error("Cockpit display update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func showInterior(for mode: CameraRig.Mode) {
        cockpit.root.isEnabled = mode.interior == .cockpit
        cabin?.root.isEnabled = mode.interior == .cabin
    }

    /// Every model needs a receiver component to be lit by the sky.
    private func applyLightReceiver(to entity: Entity, light: Entity) {
        for child in entity.children {
            if child.components.has(ModelComponent.self) {
                child.components.set(ImageBasedLightReceiverComponent(imageBasedLight: light))
            }
            applyLightReceiver(to: child, light: light)
        }
    }
}
