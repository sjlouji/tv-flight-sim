import Foundation

/// Autobrake selector positions on the 737.
enum AutobrakeSetting: Int, CaseIterable, Sendable {
    case rto, off, one, two, three, max

    var label: String {
        switch self {
        case .rto: "RTO"
        case .off: "OFF"
        case .one: "1"
        case .two: "2"
        case .three: "3"
        case .max: "MAX"
        }
    }

    /// Target deceleration on the landing roll, ft/s² (Boeing figures for a dry runway).
    var decelerationFPS2: Double? {
        switch self {
        case .one: 4
        case .two: 5
        case .three: 7.2
        case .max: 14
        case .rto, .off: nil
        }
    }
}

/// Stages of a flight, used for checklists, lights and callouts.
enum FlightPhase: String, CaseIterable, Sendable {
    case beforeTakeoff = "Before takeoff"
    case takeoff = "Takeoff"
    case climb = "Climb"
    case cruise = "Cruise"
    case descent = "Descent"
    case approach = "Approach"
    case landing = "Landing"
    case afterLanding = "After landing"
}

/// Spoken and chimed alerts, as the 737 speaks them.
enum Callout: String, Sendable {
    case eightyKnots = "eighty knots"
    case v1 = "vee one"
    case rotate = "rotate"
    case positiveRate = "positive rate"
    case twentyFiveHundred = "twenty five hundred"
    case oneThousand = "one thousand"
    case fiveHundred = "five hundred"
    case minimums = "minimums"
    case oneHundred = "one hundred"
    case fifty = "fifty"
    case forty = "forty"
    case thirty = "thirty"
    case twenty = "twenty"
    case ten = "ten"
    case sinkRate = "sink rate"
    case pullUp = "pull up"
    case tooLowGear = "too low, gear"
    case bankAngle = "bank angle"
    case overspeed = "overspeed"
    case stall = "stall"

    /// Radio altitude (height of the wheels) at which each automatic altitude callout plays.
    static let altitudeCallouts: [(feet: Double, callout: Callout)] = [
        (2_500, .twentyFiveHundred), (1_000, .oneThousand), (500, .fiveHundred), (200, .minimums), (100, .oneHundred),
        (50, .fifty), (40, .forty), (30, .thirty), (20, .twenty), (10, .ten),
    ]
}

/// Exterior lights, switched automatically by flight phase the way crews set them.
struct ExteriorLights: Equatable, Sendable {
    var navigation = true
    var beacon = true
    var strobes = false
    var landing = false
    var taxi = false
}

/// The 737's automatic systems between the pilot's levers and JSBSim: autobrake, auto speedbrake,
/// exterior lights, flight phase and GPWS-style callouts.
struct AircraftSystems: Sendable {
    let aircraft: AircraftProfile
    var autobrake: AutobrakeSetting = .off
    private(set) var autobrakeActive = false
    private(set) var speedbrakeDeployed = false
    private(set) var phase: FlightPhase = .beforeTakeoff
    private(set) var lights = ExteriorLights()

    private var autobrakePressure = 0.0
    private var wasAirborne = false
    private var takeoffThrustSeen = false
    private var landingAutomationDone = false
    private var previousGroundSpeed: Double?
    private var deceleration = 0.0
    private var levelTime = 0.0
    private var calloutsDone: Set<Callout> = []
    private var previousHeight: Double?
    private var warningCooldown = 0.0

    enum Event: Equatable, Sendable {
        case message(String)
        case callout(Callout)
    }

    init(aircraft: AircraftProfile, phase: FlightPhase = .beforeTakeoff) {
        self.aircraft = aircraft
        self.phase = phase
        wasAirborne = phase != .beforeTakeoff && phase != .takeoff
    }

    /// `pilot` are the pilot's levers. Returns the commands to send to JSBSim and anything to announce.
    mutating func update(telemetry t: Telemetry, pilot: FlightControls, speedbrakeArmed: Bool,
                         deltaTime dt: Double) -> (FlightControls, [Event]) {
        guard dt > 0 else { return (pilot, []) }
        var events: [Event] = []
        var controls = pilot
        if let previous = previousGroundSpeed {
            let rate = (previous - t.groundSpeedKnots) / dt * 1.6878
            deceleration += (rate - deceleration) * min(dt * 4, 1)
        }
        previousGroundSpeed = t.groundSpeedKnots

        // On the landing roll with the levers at idle, the armed speedbrake and autobrake come on (once per landing).
        let landingRoll = t.weightOnWheels && wasAirborne && t.groundSpeedKnots > 30 && pilot.throttle < 0.1
        if pilot.throttle > 0.6 && t.weightOnWheels { takeoffThrustSeen = true }

        // Auto speedbrake: advancing the levers stows it again.
        if speedbrakeArmed && landingRoll && !landingAutomationDone {
            speedbrakeDeployed = true
            events.append(.message("Speedbrake up"))
        }
        // Rejected takeoff: levers pulled to idle above 85 kt on the takeoff roll.
        let rejected = t.weightOnWheels && !wasAirborne && takeoffThrustSeen && t.groundSpeedKnots > 85 && pilot.throttle < 0.1
        if rejected && !autobrakeActive {
            if autobrake == .rto {
                autobrakeActive = true
                autobrakePressure = 1
                events.append(.message("RTO autobrake"))
            }
            if speedbrakeArmed || autobrake == .rto { speedbrakeDeployed = true }
        }
        if speedbrakeDeployed && (pilot.throttle > 0.2 || !t.weightOnWheels) { speedbrakeDeployed = false }
        if speedbrakeDeployed { controls.speedbrake = 1 }

        // Landing autobrake.
        if landingRoll && !landingAutomationDone && autobrake.decelerationFPS2 != nil {
            autobrakeActive = true
            autobrakePressure = 0.2
        }
        if landingRoll { landingAutomationDone = true }
        if autobrakeActive {
            if pilot.brakes > 0.3 || pilot.throttle > 0.2 {
                autobrakeActive = false
                events.append(.message("Autobrake disarmed"))
            } else if t.groundSpeedKnots < 5 {
                autobrakeActive = false
                autobrake = .off
                events.append(.message("Autobrake off, stopped"))
            } else if let target = autobrake.decelerationFPS2 {
                autobrakePressure = (autobrakePressure + (target - deceleration) * 0.08 * dt).clamped(0, 1)
            }
            if autobrakeActive { controls.brakes = max(controls.brakes, autobrakePressure) }
        }

        updatePhase(t, controls: pilot, dt: dt)
        updateLights(t)
        events += callouts(t, controls: pilot, dt: dt)
        if !t.weightOnWheels && t.altitudeAGLFeet > 50 { wasAirborne = true }
        if t.weightOnWheels && t.groundSpeedKnots < 1 && phase == .afterLanding {
            wasAirborne = false
            takeoffThrustSeen = false
            landingAutomationDone = false
        }
        return (controls, events)
    }

    private mutating func updatePhase(_ t: Telemetry, controls: FlightControls, dt: Double) {
        let next: FlightPhase
        if t.weightOnWheels {
            if wasAirborne || phase == .landing || phase == .afterLanding {
                next = .afterLanding
            } else {
                next = t.groundSpeedKnots > 40 || (controls.throttle > 0.6 && !controls.parkingBrake) ? .takeoff : .beforeTakeoff
            }
        } else {
            let vs = t.verticalSpeedFeetPerMinute
            levelTime = abs(vs) < 400 ? levelTime + dt : 0
            switch phase {
            case .beforeTakeoff, .takeoff, .afterLanding:
                next = .climb
            case .climb:
                next = levelTime > 20 && t.altitudeMSLFeet > 10_000 ? .cruise : (vs < -800 ? .descent : .climb)
            case .cruise:
                next = vs < -800 ? .descent : (vs > 800 ? .climb : .cruise)
            case .descent:
                next = t.altitudeMSLFeet < 10_000 || controls.flaps > 0.01 ? .approach : (vs > 800 ? .climb : .descent)
            case .approach:
                next = controls.gearDown && t.altitudeAGLFeet < 2_000 ? .landing : (vs > 1_000 && t.altitudeMSLFeet > 10_000 ? .climb : .approach)
            case .landing:
                // A go-around: climbing away with the gear coming up.
                next = vs > 500 && !controls.gearDown ? .climb : .landing
            }
        }
        if next != phase {
            let previousPhase = phase.rawValue
            Log.flight.info("Flight phase \(previousPhase, privacy: .public) -> \(next.rawValue, privacy: .public)")
            phase = next
        }
    }

    private mutating func updateLights(_ t: Telemetry) {
        let onRunwayOrFlying = phase != .beforeTakeoff && phase != .afterLanding || t.groundSpeedKnots > 40
        lights.navigation = true
        lights.beacon = true
        lights.strobes = onRunwayOrFlying || phase == .beforeTakeoff
        lights.landing = t.altitudeMSLFeet < 10_000 && (phase != .afterLanding || t.groundSpeedKnots > 30)
        lights.taxi = t.weightOnWheels
    }

    private mutating func callouts(_ t: Telemetry, controls: FlightControls, dt: Double) -> [Event] {
        var events: [Event] = []
        func once(_ callout: Callout) {
            guard !calloutsDone.contains(callout) else { return }
            calloutsDone.insert(callout)
            events.append(.callout(callout))
        }
        let speed = t.calibratedAirspeedKnots
        if phase == .takeoff && t.weightOnWheels {
            // "80 knots" is the airliner crosscheck; light aircraft rotate before then.
            if speed >= 80 && aircraft.v1 > 100 { once(.eightyKnots) }
            if speed >= aircraft.v1 { once(.v1) }
            if speed >= aircraft.vr { once(.rotate) }
        }
        if phase == .climb && !t.weightOnWheels && t.verticalSpeedFeetPerMinute > 300 && t.altitudeAGLFeet < 1_000 {
            once(.positiveRate)
        }
        // Altitude callouts count down the wheel height on the way to the runway.
        let height = t.radioAltitudeFeet
        if let previous = previousHeight, phase == .landing || phase == .approach {
            for (feet, callout) in Callout.altitudeCallouts where previous > feet && height <= feet && t.verticalSpeedFeetPerMinute < 0 {
                once(callout)
            }
        }
        previousHeight = height
        // Climbing back through 2,500 ft re-arms the approach callouts for the next landing.
        if height > 2_700 && (phase == .climb || phase == .cruise) {
            calloutsDone.subtract(Callout.altitudeCallouts.map(\.callout))
        }
        if phase == .afterLanding && t.groundSpeedKnots < 30 {
            calloutsDone.subtract([.eightyKnots, .v1, .rotate, .positiveRate])
        }

        // Warnings repeat while the condition lasts, every few seconds.
        warningCooldown -= dt
        if warningCooldown <= 0 && !t.weightOnWheels {
            var warning: Callout?
            if t.stallWarning {
                warning = .stall
            } else if speed > aircraft.maxSpeed + 5 {
                warning = .overspeed
            } else if abs(t.rollRadians) > 35 * .pi / 180 {
                warning = .bankAngle
            } else if height < 2_000 && t.verticalSpeedFeetPerMinute < -max(2_500, height * 3) {
                warning = height < 1_000 ? .pullUp : .sinkRate
            } else if aircraft.retractableGear && height < 500 && !controls.gearDown && t.verticalSpeedFeetPerMinute < -200 && speed < 190 {
                warning = .tooLowGear
            }
            if let warning {
                events.append(.callout(warning))
                warningCooldown = 3
            }
        }
        return events
    }
}
