import Foundation

/// Values set on the mode control panel.
struct MCPSettings: Equatable, Sendable {
    var speedKnots: Double = 250
    var headingDegrees: Double = 0
    var altitudeFeet: Double = 10_000
    var verticalSpeedFPM: Double = 0

    static let verticalSpeedRange = -6_000.0...6_000.0
}

extension AircraftProfile {
    /// Speeds the autopilot speed window accepts: from well below the approach speed to the maximum operating speed.
    var mcpSpeedRange: ClosedRange<Double> { (approachSpeed * 0.7).rounded()...maxSpeed }
    var mcpAltitudeRange: ClosedRange<Double> { 0...ceiling }
}

/// Modes named as a Boeing flight mode annunciator shows them.
enum ThrustMode: String, Sendable {
    case off = ""
    case speed = "MCP SPD"
    case climb = "N1"
    case retard = "RETARD"
    case idle = "ARM"
}

enum RollMode: String, Sendable {
    case heading = "HDG SEL"
    case lnav = "LNAV"
    case localizer = "VOR/LOC"
}

enum PitchMode: String, Sendable {
    case altitudeHold = "ALT HOLD"
    case altitudeAcquire = "ALT ACQ"
    case verticalSpeed = "V/S"
    case levelChange = "MCP SPD"
    case glideslope = "G/S"
    case flare = "FLARE"
}

/// The buttons on the mode control panel.
enum MCPButton: String, CaseIterable, Sendable {
    case autopilot = "CMD"
    case autothrottle = "A/T"
    case n1 = "N1"
    case speed = "SPD"
    case levelChange = "LVL CHG"
    case heading = "HDG SEL"
    case lnav = "LNAV"
    case approach = "APP"
    case altitudeHold = "ALT HLD"
    case verticalSpeed = "V/S"
}

/// What the autopilot needs from navigation each frame.
struct GuidanceInput: Sendable {
    var position: GeoPoint
    /// Track that follows the active route leg, when there is a route.
    var lnavTrackDegrees: Double?
    var landingSystem: LandingSystem?
}

/// Autopilot (CMD) and autothrottle: classic cascaded control laws, the same on every aircraft.
///
/// Roll: heading or track error gives a bank angle (max 25 degrees), bank error gives a roll rate, roll rate
/// error gives aileron. Pitch: each vertical mode produces a vertical speed target; that becomes a flight path
/// angle, plus angle of attack gives a pitch attitude, and pitch error with pitch-rate damping gives elevator.
/// The elevator's steady part is moved into the stabilizer trim, as the real aircraft does, so disconnecting
/// does not jolt the aircraft. Gains were tuned against the JSBSim 737 and checked on every aircraft
/// (see AutopilotTests and AircraftTests).
struct Autopilot: Sendable {
    enum Event: Equatable, Sendable {
        case autopilotDisconnected(String)
        case autothrottleDisconnected(String)
        case rejected(String)
    }

    /// Commands that replace the pilot's when the automation is in control.
    struct Output: Equatable, Sendable {
        var aileron: Double?
        var elevator: Double?
        var pitchTrim: Double?
        var throttle: Double?
    }

    var mcp = MCPSettings()
    private(set) var autopilotEngaged = false
    private(set) var autothrottleArmed = false
    private(set) var rollMode: RollMode = .heading
    private(set) var pitchMode: PitchMode = .altitudeHold
    private(set) var thrustMode: ThrustMode = .off
    private(set) var localizerArmed = false
    private(set) var glideslopeArmed = false

    private var thrustSelection: ThrustMode = .speed
    private var heldAltitudeFeet = 0.0
    private var acquireRateFPM = 1_000.0
    private var levelChangeVerticalSpeed = 0.0
    private var elevatorIntegral = 0.0
    private var throttle = 0.0
    private var pitchTrim = 0.0
    private var previousAirspeed: Double?
    private var airspeedRate = 0.0

    static let maxBankDegrees = 25.0
    static let minimumEngageHeightFeet = 400.0
    /// Pilot stick deflection that disconnects the autopilot (as forcing the column does on the real aircraft).
    static let overrideDeflection = 0.3
    static let flareHeightFeet = 45.0
    static let retardHeightFeet = 27.0
    static let climbThrust = 0.95

    var statusSummary: String {
        guard autopilotEngaged || autothrottleArmed else { return "Autopilot off" }
        return [thrustMode.rawValue, autopilotEngaged ? rollMode.rawValue : "", autopilotEngaged ? pitchMode.rawValue : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Pilot actions

    /// Handles a mode control panel button. `controls` are the pilot's current levers, which the automation
    /// starts from so engaging it never jumps the aircraft.
    mutating func press(_ button: MCPButton, telemetry t: Telemetry, controls: FlightControls,
                        guidance: GuidanceInput) -> [Event] {
        switch button {
        case .autopilot:
            if autopilotEngaged { return disconnectAutopilot("Autopilot off") }
            guard !t.weightOnWheels, t.radioAltitudeFeet >= Self.minimumEngageHeightFeet else {
                return [.rejected("Autopilot engages above \(Int(Self.minimumEngageHeightFeet)) ft")]
            }
            autopilotEngaged = true
            pitchTrim = controls.pitchTrim
            elevatorIntegral = controls.elevator
            if abs(t.verticalSpeedFeetPerMinute) < 300 {
                holdAltitude(t.altitudeMSLFeet)
            } else {
                pitchMode = .verticalSpeed
                mcp.verticalSpeedFPM = (t.verticalSpeedFeetPerMinute / 100).rounded() * 100
            }
        case .autothrottle:
            if autothrottleArmed { return disconnectAutothrottle("Autothrottle off") }
            autothrottleArmed = true
            throttle = controls.throttle
            // Arming on the ground means takeoff thrust; in the air it holds the selected speed.
            thrustSelection = t.weightOnWheels ? .climb : .speed
        case .n1:
            guard autothrottleArmed else { return [.rejected("Arm the autothrottle first")] }
            thrustSelection = .climb
        case .speed:
            guard autothrottleArmed else { return [.rejected("Arm the autothrottle first")] }
            thrustSelection = .speed
            if pitchMode == .levelChange { pitchMode = .verticalSpeed; mcp.verticalSpeedFPM = (t.verticalSpeedFeetPerMinute / 100).rounded() * 100 }
        case .levelChange:
            guard autopilotEngaged else { return [.rejected("Engage the autopilot first")] }
            pitchMode = .levelChange
            levelChangeVerticalSpeed = t.verticalSpeedFeetPerMinute
            glideslopeArmed = false
        case .heading:
            rollMode = .heading
            localizerArmed = false
        case .lnav:
            guard guidance.lnavTrackDegrees != nil else { return [.rejected("No route to follow")] }
            rollMode = .lnav
            localizerArmed = false
        case .approach:
            guard guidance.landingSystem != nil else { return [.rejected("No landing runway selected")] }
            localizerArmed = true
            glideslopeArmed = true
        case .altitudeHold:
            holdAltitude(t.altitudeMSLFeet)
        case .verticalSpeed:
            pitchMode = .verticalSpeed
            mcp.verticalSpeedFPM = (t.verticalSpeedFeetPerMinute / 100).rounded() * 100
            glideslopeArmed = false
        }
        refreshThrustMode(t)
        return []
    }

    mutating func disconnectAutopilot(_ reason: String) -> [Event] {
        guard autopilotEngaged else { return [] }
        autopilotEngaged = false
        localizerArmed = false
        glideslopeArmed = false
        if pitchMode == .flare { pitchMode = .altitudeHold }
        Log.flight.info("Autopilot disconnected: \(reason, privacy: .public)")
        return [.autopilotDisconnected(reason)]
    }

    mutating func disconnectAutothrottle(_ reason: String) -> [Event] {
        guard autothrottleArmed else { return [] }
        autothrottleArmed = false
        thrustMode = .off
        Log.flight.info("Autothrottle disconnected: \(reason, privacy: .public)")
        return [.autothrottleDisconnected(reason)]
    }

    // MARK: - Per frame

    /// Runs the control laws. `pilot` is the pilot's own input this frame: stick force disconnects the
    /// autopilot and trigger input disconnects the autothrottle.
    mutating func update(telemetry t: Telemetry, pilot: FlightControls, pilotMovedThrust: Bool,
                         guidance: GuidanceInput, deltaTime dt: Double) -> (Output, [Event]) {
        guard dt > 0 else { return (Output(), []) }
        var events: [Event] = []
        if let previous = previousAirspeed {
            let rate = (t.calibratedAirspeedKnots - previous) / dt
            airspeedRate += (rate - airspeedRate) * min(dt * 2, 1)
        }
        previousAirspeed = t.calibratedAirspeedKnots

        if autopilotEngaged {
            if abs(pilot.aileron) > Self.overrideDeflection || abs(pilot.elevator) > Self.overrideDeflection {
                events += disconnectAutopilot("Pilot override")
            } else if t.stallWarning {
                events += disconnectAutopilot("Stall warning")
            } else if abs(t.rollRadians) > 45 * .pi / 180 || abs(t.pitchRadians) > 30 * .pi / 180 {
                events += disconnectAutopilot("Unusual attitude")
            } else if t.weightOnWheels && pitchMode == .flare {
                events += disconnectAutopilot("Touchdown")
            }
        }
        if autothrottleArmed && pilotMovedThrust {
            events += disconnectAutothrottle("Thrust levers moved")
        } else if autothrottleArmed && t.weightOnWheels && thrustMode == .retard && throttle < 0.01 {
            events += disconnectAutothrottle("Touchdown")
        }

        var output = Output()
        if autopilotEngaged {
            updateModeTransitions(t, guidance: guidance)
            output.aileron = rollCommand(t, guidance: guidance)
            let (elevator, trim) = pitchCommand(t, guidance: guidance, dt: dt)
            output.elevator = elevator
            output.pitchTrim = trim
        }
        refreshThrustMode(t)
        if autothrottleArmed {
            output.throttle = thrustCommand(t, dt: dt)
        } else {
            throttle = pilot.throttle
        }
        return (output, events)
    }

    // MARK: - Mode logic

    private mutating func holdAltitude(_ altitude: Double) {
        pitchMode = .altitudeHold
        heldAltitudeFeet = altitude
    }

    private mutating func updateModeTransitions(_ t: Telemetry, guidance: GuidanceInput) {
        let altitudeError = mcp.altitudeFeet - t.altitudeMSLFeet
        if pitchMode == .verticalSpeed || pitchMode == .levelChange {
            let closing = (altitudeError > 0) == (t.verticalSpeedFeetPerMinute > 0)
            let band = max(abs(t.verticalSpeedFeetPerMinute) * 0.15, 150)
            if closing && abs(altitudeError) < band {
                pitchMode = .altitudeAcquire
                acquireRateFPM = max(abs(t.verticalSpeedFeetPerMinute), 300)
            }
        }
        if pitchMode == .altitudeAcquire && abs(altitudeError) < 25 {
            holdAltitude(mcp.altitudeFeet)
        }
        if let ils = guidance.landingSystem {
            let distance = ils.distanceToThresholdMeters(guidance.position)
            let courseError = abs(Navigation.angleDifference(t.trackDegrees, ils.courseDegrees))
            // Capture once the needle comes off the stop (inside two dots) while heading the runway's way.
            if localizerArmed && distance > 0 && courseError < 90
                && abs(ils.localizerDeviationDegrees(guidance.position)) < LandingSystem.localizerFullScaleDegrees * 0.95 {
                rollMode = .localizer
                localizerArmed = false
            }
            if glideslopeArmed && rollMode == .localizer && distance > 0
                && abs(ils.glideslopeDeviationDegrees(guidance.position, altitudeFeet: t.altitudeMSLFeet)) < 0.25 {
                pitchMode = .glideslope
                glideslopeArmed = false
            }
            if pitchMode == .glideslope && t.radioAltitudeFeet < Self.flareHeightFeet {
                pitchMode = .flare
            }
        }
    }

    private mutating func refreshThrustMode(_ t: Telemetry) {
        guard autothrottleArmed else { thrustMode = .off; return }
        if autopilotEngaged && pitchMode == .levelChange {
            thrustMode = mcp.altitudeFeet > t.altitudeMSLFeet ? .climb : (throttle > 0.02 ? .retard : .idle)
        } else if pitchMode == .flare && autopilotEngaged && t.radioAltitudeFeet < Self.retardHeightFeet {
            thrustMode = .retard
        } else if thrustMode == .retard && t.weightOnWheels {
            thrustMode = .retard
        } else {
            thrustMode = thrustSelection
        }
    }

    // MARK: - Control laws

    private func rollCommand(_ t: Telemetry, guidance: GuidanceInput) -> Double {
        let bankLimit: Double
        let error: Double
        switch rollMode {
        case .heading:
            error = Navigation.angleDifference(mcp.headingDegrees, t.headingDegrees)
            bankLimit = Self.maxBankDegrees
        case .lnav:
            error = Navigation.angleDifference(guidance.lnavTrackDegrees ?? t.trackDegrees, t.trackDegrees)
            bankLimit = Self.maxBankDegrees
        case .localizer:
            guard let ils = guidance.landingSystem else { return 0 }
            let offset = ils.lateralOffsetMeters(guidance.position)
            let intercept = (offset * 0.04).clamped(-30, 30)
            error = Navigation.angleDifference(ils.courseDegrees - intercept, t.trackDegrees)
            bankLimit = t.altitudeAGLFeet < 500 ? 10 : 20
        }
        let bankCommand = (error * 1.6).clamped(-bankLimit, bankLimit)
        let rollDegrees = t.rollRadians * 180 / .pi
        let rateCommand = ((bankCommand - rollDegrees) * 0.8).clamped(-5, 5)
        let rateDegrees = t.rollRate * 180 / .pi
        return (0.08 * (rateCommand - rateDegrees)).clamped(-0.6, 0.6)
    }

    private mutating func pitchCommand(_ t: Telemetry, guidance: GuidanceInput, dt: Double) -> (elevator: Double, trim: Double) {
        let verticalSpeedTarget = verticalSpeedCommand(t, guidance: guidance, dt: dt)
        let trueSpeedFPM = max(t.trueAirspeedKnots, 60) / 0.592484 * 60
        let pathTarget = asin((verticalSpeedTarget / trueSpeedFPM).clamped(-0.35, 0.35)) * 180 / .pi
        let path = asin((t.verticalSpeedFeetPerMinute / trueSpeedFPM).clamped(-0.99, 0.99)) * 180 / .pi
        let pitchDegrees = t.pitchRadians * 180 / .pi
        // Flight path error asks for a pitch rate (limited to 1.5 degrees per second as airline autopilots
        // are, and to the attitude limits); the pitch-rate error drives the elevator. The path follows pitch
        // with a lag of about two seconds, so a gain of 0.35 gives a well damped response.
        var rateCommand = ((pathTarget - path) * 0.35).clamped(-1.5, 1.5)
        if pitchDegrees > 20 { rateCommand = min(rateCommand, 0) }
        if pitchDegrees < -10 { rateCommand = max(rateCommand, 0) }
        // Elevator +1 is nose down, hence the minus signs.
        let rateError = rateCommand - t.pitchRate * 180 / .pi
        elevatorIntegral = (elevatorIntegral - 0.04 * rateError * dt).clamped(-0.5, 0.5)
        // Stabilizer trim takes over the steady elevator, about 0.05 per second like the 737's trim motor.
        let transfer = elevatorIntegral.clamped(-0.05 * dt, 0.05 * dt)
        pitchTrim = (pitchTrim + transfer).clamped(-1, 1)
        elevatorIntegral -= transfer
        let elevator = (-0.1 * rateError + elevatorIntegral).clamped(-0.6, 0.6)
        return (elevator, pitchTrim)
    }

    private mutating func verticalSpeedCommand(_ t: Telemetry, guidance: GuidanceInput, dt: Double) -> Double {
        switch pitchMode {
        case .altitudeHold:
            return ((heldAltitudeFeet - t.altitudeMSLFeet) * 4).clamped(-1_000, 1_000)
        case .altitudeAcquire:
            return ((mcp.altitudeFeet - t.altitudeMSLFeet) * 4).clamped(-acquireRateFPM, acquireRateFPM)
        case .verticalSpeed:
            return mcp.verticalSpeedFPM
        case .levelChange:
            // Speed on elevator: too fast means climb more (or descend less). Integral plus proportional and
            // acceleration terms, so the climb rate settles where thrust minus drag holds the speed.
            let climbing = mcp.altitudeFeet > t.altitudeMSLFeet
            let speedError = t.calibratedAirspeedKnots - mcp.speedKnots
            let limits = climbing ? 0.0...6_000.0 : -6_000.0...0.0
            levelChangeVerticalSpeed = (levelChangeVerticalSpeed + speedError * 30 * dt)
                .clamped(limits.lowerBound, limits.upperBound)
            return (levelChangeVerticalSpeed + speedError * 60 + airspeedRate * 150).clamped(limits.lowerBound, limits.upperBound)
        case .glideslope:
            guard let ils = guidance.landingSystem else { return 0 }
            let distance = ils.distanceToThresholdMeters(guidance.position)
            let nominal = -t.groundSpeedKnots * 101.27 * tan(LandingSystem.glideslopeDegrees * .pi / 180)
            let error = ils.glideslopeAltitudeFeet(distanceMeters: distance) - t.altitudeMSLFeet
            return (nominal + error * 4).clamped(-2_000, 500)
        case .flare:
            return -(t.radioAltitudeFeet * 60 / 4.5) - 100
        }
    }

    private mutating func thrustCommand(_ t: Telemetry, dt: Double) -> Double {
        switch thrustMode {
        case .off:
            break
        case .speed:
            let error = mcp.speedKnots - t.calibratedAirspeedKnots
            throttle += (0.012 * error - 0.05 * airspeedRate).clamped(-0.15, 0.15) * dt
        case .climb:
            throttle += (Self.climbThrust - throttle).clamped(-0.15 * dt, 0.15 * dt)
        case .retard, .idle:
            throttle += (0 - throttle).clamped(-0.25 * dt, 0.25 * dt)
        }
        throttle = throttle.clamped(0, 1)
        return throttle
    }
}
