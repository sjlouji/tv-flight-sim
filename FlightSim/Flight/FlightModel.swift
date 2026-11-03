 import Foundation

/// Pilot commands sent to JSBSim every frame. Ranges follow JSBSim's normalized conventions.
struct FlightControls: Equatable, Sendable {
    /// -1 full left roll ... +1 full right roll.
    var aileron: Double = 0
    /// -1 stick fully back (nose up) ... +1 stick fully forward (nose down).
    var elevator: Double = 0
    /// -1 full left pedal ... +1 full right pedal.
    var rudder: Double = 0
    /// -1 ... +1, added to the elevator by the 737 flight control system.
    var pitchTrim: Double = 0
    /// -1 ... +1, added to the rudder by the 737 flight control system.
    var rudderTrim: Double = 0
    /// Thrust lever, 0 idle ... 1 takeoff/go-around thrust (afterburner on the F-4). Applies to every engine.
    var throttle: Double = 0
    /// Thrust reversers deployed. Only meaningful on the ground with the levers at idle.
    var reversers: Bool = false
    /// Flap command, 0 (UP) ... 1 (the model's largest flap angle). See `FlapDetent`.
    var flaps: Double = 0
    /// Speedbrake lever, 0 down ... 1 fully up.
    var speedbrake: Double = 0
    var gearDown: Bool = true
    /// Toe brakes, 0 ... 1.
    var brakes: Double = 0
    var parkingBrake: Bool = false
}

/// Aircraft state read back from JSBSim, in the units the cockpit displays use.
struct Telemetry: Equatable, Sendable {
    var latitude: Double = 0
    var longitude: Double = 0
    var altitudeMSLFeet: Double = 0
    /// Height of the center of gravity above the ground.
    var altitudeAGLFeet: Double = 0
    /// Height of the wheels above the ground (what a radio altimeter reads): zero on the runway.
    var radioAltitudeFeet: Double = 0
    var rollRadians: Double = 0
    var pitchRadians: Double = 0
    /// True heading, radians clockwise from north.
    var headingRadians: Double = 0
    /// Direction of travel over the ground, radians clockwise from north.
    var trackRadians: Double = 0
    var calibratedAirspeedKnots: Double = 0
    var trueAirspeedKnots: Double = 0
    var groundSpeedKnots: Double = 0
    var verticalSpeedFeetPerMinute: Double = 0
    var mach: Double = 0
    var angleOfAttackDegrees: Double = 0
    var sideslipDegrees: Double = 0
    /// Rates of change of bank and pitch attitude, radians per second (right wing down and nose up positive).
    /// These are Euler-angle rates, not body rates: in a level turn the body pitch rate is not zero.
    var rollRate: Double = 0
    var pitchRate: Double = 0
    /// Normal load factor in g (1 in level flight).
    var loadFactor: Double = 1
    /// Steady wind, the direction it blows from in degrees true, and its speed.
    var windFromDegrees: Double = 0
    var windSpeedKnots: Double = 0
    var outsideAirTemperatureC: Double = 15
    /// Per engine. Turbine spool speeds in percent (zero for a piston engine).
    var engineN1: [Double] = []
    var engineN2: [Double] = []
    /// Per engine: crankshaft RPM for a piston engine, propeller RPM for a turboprop, zero for a jet.
    var engineRPM: [Double] = []
    /// Per engine: how fast it turns as a fraction of its maximum (N1 or RPM), for sound and spinning fans.
    var engineSpool: [Double] = []
    var engineThrustPounds: [Double] = []
    var fuelFlowPoundsPerHour: [Double] = []
    var fuelPounds: Double = 0
    var grossWeightPounds: Double = 0
    var flapPosition: Double = 0
    var gearPosition: Double = 0
    var speedbrakePosition: Double = 0
    var elevatorPosition: Double = 0
    var leftAileronPosition: Double = 0
    var rightAileronPosition: Double = 0
    var rudderPosition: Double = 0
    var weightOnWheels: Bool = false
    var stallWarning: Bool = false

    var headingDegrees: Double { Self.compassDegrees(headingRadians) }
    var trackDegrees: Double { Self.compassDegrees(trackRadians) }
    static func compassDegrees(_ radians: Double) -> Double {
        let degrees = (radians * 180 / .pi).truncatingRemainder(dividingBy: 360)
        return degrees < 0 ? degrees + 360 : degrees
    }
}

/// Where the aircraft is and how it is oriented at one instant. Rendering interpolates between two of these.
struct Pose: Equatable, Sendable {
    var latitude: Double = 0
    var longitude: Double = 0
    var altitudeMSLFeet: Double = 0
    var roll: Double = 0
    var pitch: Double = 0
    var heading: Double = 0

    /// Linear blend from `a` (fraction 0) to `b` (fraction 1). Angles take the short way around.
    static func interpolate(from a: Pose, to b: Pose, fraction t: Double) -> Pose {
        func angle(_ x: Double, _ y: Double) -> Double {
            var delta = (y - x).truncatingRemainder(dividingBy: 2 * .pi)
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            return x + delta * t
        }
        return Pose(latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: angle(a.longitude * .pi / 180, b.longitude * .pi / 180) * 180 / .pi,
                    altitudeMSLFeet: a.altitudeMSLFeet + (b.altitudeMSLFeet - a.altitudeMSLFeet) * t,
                    roll: angle(a.roll, b.roll), pitch: angle(a.pitch, b.pitch), heading: angle(a.heading, b.heading))
    }
}

/// Atmosphere conditions JSBSim simulates.
struct AtmosphereSettings: Equatable, Sendable {
    var windFromDegrees: Double = 0
    var windSpeedKnots: Double = 0
    /// MIL-F-8785C probability-of-exceedance index: 0 none, 3 light, 4 moderate, 6 severe.
    var turbulenceSeverity: Int = 0
    /// Sea-level temperature offset from the standard atmosphere, degrees Celsius.
    var temperatureOffsetC: Double = 0

    /// The air mass velocity JSBSim wants, which points away from where the wind comes from (ft/s).
    var windVelocityFps: (north: Double, east: Double) {
        let speed = windSpeedKnots / 0.592484
        let from = windFromDegrees * .pi / 180
        return (-speed * cos(from), -speed * sin(from))
    }
}

/// Where and how a flight starts.
struct StartCondition: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var terrainElevationFeet: Double
    var altitudeAGLFeet: Double
    var headingDegrees: Double
    var airspeedKnots: Double
    var flightPathAngleDegrees: Double
    var controls: FlightControls
    var onGround: Bool
}

/// Owns one JSBSim aircraft and runs it at a fixed time step regardless of frame rate.
@MainActor
final class FlightModel {
    static let timeStep = 1.0 / 120.0
    /// Fraction of forward thrust produced when the reversers are deployed (cos of the reverser angle).
    static let reverseThrustFraction = 0.4
    private static let maxStepsPerFrame = 24

    /// A piston engine's maximum RPM (the Cessna 172P's Lycoming O-320).
    static let pistonMaxRPM = 2_700.0
    /// Mixture at sea-level pressure for best power. JSBSim's piston engine burns 1.3 times the
    /// stoichiometric fuel at full rich and sea level, and richer as the air thins; past about 10,000 ft
    /// that floods it. Scaling the mixture with the pressure ratio keeps it near 1.15 times at any height,
    /// as a pilot leaning for best power does.
    static let bestPowerMixture = 1.15 / 1.3

    let profile: AircraftProfile
    let geometry: AircraftGeometry
    private let aircraft: JSBSimAircraft
    private let handles: PropertyHandles
    private var accumulator: Double = 0
    /// Pose one physics step before `currentPose`.
    private var previousPose = Pose()
    private var currentPose = Pose()

    init(dataDirectory: URL, profile: AircraftProfile) throws {
        self.profile = profile
        geometry = try AircraftDefinition.load(profile, dataDirectory: dataDirectory)
        aircraft = try JSBSimAircraft(rootDirectory: dataDirectory.path, model: profile.jsbsimModel, timeStep: Self.timeStep)
        handles = try PropertyHandles(aircraft: aircraft, engineCount: geometry.engines.count, wheelUnits: geometry.wheels.map(\.unit))
        Log.flight.info("Flight model \(profile.jsbsimModel, privacy: .public) ready with \(self.geometry.engines.count) engines")
    }

    /// The pose to draw this frame: between the last two physics steps, by how far real time has moved past
    /// the older one. Without this, frames that happen to contain 1, 2 or 3 steps move the aircraft by
    /// visibly different distances, which reads as stutter.
    var renderPose: Pose {
        Pose.interpolate(from: previousPose, to: currentPose, fraction: min(accumulator / Self.timeStep, 1))
    }

    /// Ground height under the aircraft, feet above sea level. JSBSim uses it for the gear and height above ground.
    func setTerrainElevation(feet: Double) { set(handles.terrainElevation, feet) }

    func apply(_ atmosphere: AtmosphereSettings) {
        let wind = atmosphere.windVelocityFps
        set(handles.windNorth, wind.north)
        set(handles.windEast, wind.east)
        let speed = atmosphere.windSpeedKnots / 0.592484
        set(handles.turbulenceType, atmosphere.turbulenceSeverity > 0 ? 3 : 0)
        set(handles.turbulenceSeverity, Double(atmosphere.turbulenceSeverity))
        set(handles.turbulenceWindAt20Feet, max(speed, 15 / 0.592484))
        set(handles.temperatureOffset, atmosphere.temperatureOffsetC * 1.8)
    }

    /// Places the aircraft and trims it. Returns the start controls with the trimmed thrust and pitch trim,
    /// which the pilot's levers must start from or the trim is undone on the first frame.
    @discardableResult
    func reset(to start: StartCondition, atmosphere: AtmosphereSettings = AtmosphereSettings()) throws -> FlightControls {
        accumulator = 0
        try aircraft.reset(
            toLatitude: start.latitude,
            longitude: start.longitude,
            terrainElevation: start.terrainElevationFeet,
            altitudeAGL: start.altitudeAGLFeet,
            heading: start.headingDegrees,
            calibratedAirspeed: start.airspeedKnots,
            flightPathAngle: start.flightPathAngleDegrees
        )
        aircraft.setValue(-1, forHandle: handles.setRunning)
        // Propellers at high RPM and both magnetos on: levers this simulator does not model. The mixture
        // is leaned automatically (see `apply`).
        for engine in handles.engines {
            set(engine.propellerAdvance, 1)
        }
        if let magnetos = handles.magnetos { set(magnetos, 3) }
        if start.onGround {
            // Trimming against set brakes fails on some models (the Twin Otter's), so the brakes go on after.
            var released = start.controls
            released.parkingBrake = false
            released.brakes = 0
            apply(released)
            try aircraft.trim(with: .ground)
            apply(start.controls)
        } else {
            apply(start.controls)
            try aircraft.trim(with: .longitudinal)
        }
        // The weather goes in after the trim: JSBSim's initialization (which the trim repeats) resets the
        // winds, and trimming with wind in the initial conditions fails on a glideslope. The wind then
        // changes the airspeed a little at the start, which the pilot or autothrottle absorbs.
        apply(atmosphere)
        var trimmed = start.controls
        trimmed.throttle = get(handles.engines[0].throttle)
        trimmed.pitchTrim = get(handles.pitchTrim)
        currentPose = pose()
        previousPose = currentPose
        Log.flight.info("Reset at \(start.latitude), \(start.longitude), \(start.altitudeAGLFeet) ft AGL; trim thrust \(trimmed.throttle), pitch trim \(trimmed.pitchTrim)")
        return trimmed
    }

    /// Advances real time `seconds`, running as many fixed JSBSim steps as fit.
    func advance(by seconds: Double) throws {
        accumulator += max(0, seconds)
        var steps = Int(accumulator / Self.timeStep)
        if steps > Self.maxStepsPerFrame {
            Log.flight.warning("Frame took \(seconds) s; dropping \(steps - Self.maxStepsPerFrame) simulation steps")
            steps = Self.maxStepsPerFrame
            accumulator = 0
        } else {
            accumulator -= Double(steps) * Self.timeStep
        }
        guard steps > 0 else { return }
        // Keep the pose one step before the newest so rendering can interpolate between them.
        if steps > 1 {
            try aircraft.runSteps(steps - 1)
            previousPose = pose()
        } else {
            previousPose = currentPose
        }
        try aircraft.runSteps(1)
        currentPose = pose()
        // A diverged simulation (an impossible attitude or speed) turns the state into NaN; stop it visibly.
        let values = [currentPose.latitude, currentPose.longitude, currentPose.altitudeMSLFeet,
                      currentPose.roll, currentPose.pitch, currentPose.heading]
        guard values.allSatisfy(\.isFinite) else {
            Log.flight.error("Flight model state is no longer finite: \(String(describing: self.currentPose), privacy: .public)")
            throw FlightModelError.diverged
        }
    }

    private func pose() -> Pose {
        Pose(latitude: get(handles.latitude), longitude: get(handles.longitude), altitudeMSLFeet: get(handles.altitudeMSL),
             roll: get(handles.roll), pitch: get(handles.pitch), heading: get(handles.heading))
    }

    func apply(_ controls: FlightControls) {
        set(handles.aileron, controls.aileron.clamped(-1, 1))
        set(handles.elevator, controls.elevator.clamped(-1, 1))
        set(handles.rudder, controls.rudder.clamped(-1, 1))
        set(handles.steering, controls.rudder.clamped(-1, 1))
        set(handles.pitchTrim, controls.pitchTrim.clamped(-1, 1))
        set(handles.yawTrim, controls.rudderTrim.clamped(-1, 1))
        set(handles.flaps, controls.flaps.clamped(0, 1))
        set(handles.speedbrake, controls.speedbrake.clamped(0, 1))
        set(handles.gear, controls.gearDown ? 1 : 0)
        let brake = controls.parkingBrake ? 1 : controls.brakes.clamped(0, 1)
        set(handles.leftBrake, brake)
        set(handles.rightBrake, brake)
        let reverserAngle = controls.reversers ? acos(-Self.reverseThrustFraction) : 0
        let mixture = profile.engineKind == .piston ? Self.bestPowerMixture * get(handles.pressureRatio) : 1
        for engine in handles.engines {
            set(engine.throttle, controls.throttle.clamped(0, 1))
            set(engine.mixture, mixture)
            if let reverser = engine.reverserAngle { set(reverser, reverserAngle) }
        }
    }

    func telemetry() -> Telemetry {
        let windNorth = get(handles.windNorth)
        let windEast = get(handles.windEast)
        let windFrom = atan2(-windEast, -windNorth)
        return Telemetry(
            latitude: get(handles.latitude),
            longitude: get(handles.longitude),
            altitudeMSLFeet: get(handles.altitudeMSL),
            altitudeAGLFeet: get(handles.altitudeAGL),
            radioAltitudeFeet: max(get(handles.altitudeAGL) - geometry.groundCGHeightFeet, 0),
            rollRadians: get(handles.roll),
            pitchRadians: get(handles.pitch),
            headingRadians: get(handles.heading),
            trackRadians: atan2(get(handles.velocityEast), get(handles.velocityNorth)),
            calibratedAirspeedKnots: get(handles.calibratedAirspeed),
            trueAirspeedKnots: get(handles.trueAirspeed),
            groundSpeedKnots: get(handles.groundSpeedFps) * 0.592484,
            verticalSpeedFeetPerMinute: get(handles.verticalSpeedFps) * 60,
            mach: get(handles.mach),
            angleOfAttackDegrees: get(handles.alpha),
            sideslipDegrees: get(handles.beta),
            rollRate: get(handles.rollRate),
            pitchRate: get(handles.pitchRate),
            loadFactor: get(handles.loadFactor),
            windFromDegrees: Telemetry.compassDegrees(windFrom),
            windSpeedKnots: (windNorth * windNorth + windEast * windEast).squareRoot() * 0.592484,
            outsideAirTemperatureC: (get(handles.temperatureRankine) - 491.67) / 1.8,
            engineN1: handles.engines.map { $0.n1.map(get) ?? 0 },
            engineN2: handles.engines.map { $0.n2.map(get) ?? 0 },
            engineRPM: handles.engines.map { ($0.engineRPM ?? $0.propellerRPM).map(get) ?? 0 },
            engineSpool: handles.engines.map(spool),
            engineThrustPounds: handles.engines.map { get($0.thrust) },
            fuelFlowPoundsPerHour: handles.engines.map { get($0.fuelFlowPPS) * 3600 },
            fuelPounds: get(handles.totalFuel),
            grossWeightPounds: get(handles.weight),
            flapPosition: get(handles.flapPosition),
            gearPosition: get(handles.gearPosition),
            speedbrakePosition: get(handles.speedbrakePosition),
            elevatorPosition: get(handles.elevatorPosition),
            leftAileronPosition: get(handles.leftAileronPosition),
            rightAileronPosition: get(handles.rightAileronPosition),
            rudderPosition: get(handles.rudderPosition),
            weightOnWheels: handles.weightOnWheels.contains { get($0) > 0.5 },
            stallWarning: get(handles.stallWarning) > 0.5
        )
    }

    /// How fast the engine turns, 0...1: N1 for turbofans and turboprops, the single spool (JSBSim's N2)
    /// for a turbojet, crankshaft RPM for a piston engine.
    private func spool(_ engine: PropertyHandles.Engine) -> Double {
        if profile.engineKind == .turbojet, let n2 = engine.n2 { return get(n2) / 100 }
        if let n1 = engine.n1 { return get(n1) / 100 }
        if let rpm = engine.engineRPM { return get(rpm) / Self.pistonMaxRPM }
        preconditionFailure("PropertyHandles requires N1 or engine RPM for every engine")
    }

    private func set(_ handle: Int, _ value: Double) { aircraft.setValue(value, forHandle: handle) }
    private func get(_ handle: Int) -> Double { aircraft.value(forHandle: handle) }
}

/// JSBSim properties resolved once at load time. A typo or a model without a required property fails loudly here.
/// Engine gauges differ by engine type, so those are looked up and may be absent (a piston engine has no N1).
private struct PropertyHandles {
    struct Engine {
        let throttle, mixture, propellerAdvance, thrust, fuelFlowPPS: Int
        let reverserAngle, n1, n2, engineRPM, propellerRPM: Int?
    }

    let aileron, elevator, rudder, steering, pitchTrim, yawTrim: Int
    let flaps, speedbrake, gear, leftBrake, rightBrake, setRunning: Int
    let magnetos: Int?
    let engines: [Engine]
    let latitude, longitude, altitudeMSL, altitudeAGL, terrainElevation: Int
    let roll, pitch, heading: Int
    let calibratedAirspeed, trueAirspeed, groundSpeedFps, verticalSpeedFps, mach, alpha, beta, loadFactor: Int
    let rollRate, pitchRate: Int
    let velocityNorth, velocityEast: Int
    let windNorth, windEast, turbulenceType, turbulenceSeverity, turbulenceWindAt20Feet, temperatureOffset, temperatureRankine: Int
    let pressureRatio: Int
    let totalFuel, weight: Int
    let flapPosition, gearPosition, speedbrakePosition: Int
    let elevatorPosition, leftAileronPosition, rightAileronPosition, rudderPosition: Int
    let weightOnWheels: [Int]
    let stallWarning: Int

    @MainActor
    init(aircraft: JSBSimAircraft, engineCount: Int, wheelUnits: [Int]) throws {
        func handle(_ name: String) throws -> Int { try aircraft.handle(forProperty: name).intValue }
        /// A property only some engine types have. Absence is expected for those types, so it is not an error.
        func gauge(_ name: String) -> Int? {
            do {
                return try handle(name)
            } catch {
                Log.flight.debug("No \(name, privacy: .public) on this model")
                return nil
            }
        }
        aileron = try handle("fcs/aileron-cmd-norm")
        elevator = try handle("fcs/elevator-cmd-norm")
        rudder = try handle("fcs/rudder-cmd-norm")
        steering = try handle("fcs/steer-cmd-norm")
        pitchTrim = try handle("fcs/pitch-trim-cmd-norm")
        yawTrim = try handle("fcs/yaw-trim-cmd-norm")
        flaps = try handle("fcs/flap-cmd-norm")
        speedbrake = try handle("fcs/speedbrake-cmd-norm")
        gear = try handle("gear/gear-cmd-norm")
        leftBrake = try handle("fcs/left-brake-cmd-norm")
        rightBrake = try handle("fcs/right-brake-cmd-norm")
        setRunning = try handle("propulsion/set-running")
        magnetos = gauge("propulsion/magneto_cmd")
        engines = try (0..<engineCount).map { index in
            let engine = "propulsion/engine[\(index)]"
            let result = Engine(throttle: try handle("fcs/throttle-cmd-norm[\(index)]"),
                                mixture: try handle("fcs/mixture-cmd-norm[\(index)]"),
                                propellerAdvance: try handle("fcs/advance-cmd-norm[\(index)]"),
                                thrust: try handle("\(engine)/thrust-lbs"),
                                fuelFlowPPS: try handle("\(engine)/fuel-flow-rate-pps"),
                                reverserAngle: gauge("\(engine)/reverser-angle-rad"),
                                n1: gauge("\(engine)/n1"), n2: gauge("\(engine)/n2"),
                                engineRPM: gauge("\(engine)/engine-rpm"), propellerRPM: gauge("\(engine)/propeller-rpm"))
            guard result.n1 != nil || result.engineRPM != nil else {
                throw FlightModelError.missingEngineGauge(index)
            }
            return result
        }
        latitude = try handle("position/lat-geod-deg")
        longitude = try handle("position/long-gc-deg")
        altitudeMSL = try handle("position/h-sl-ft")
        altitudeAGL = try handle("position/h-agl-ft")
        terrainElevation = try handle("position/terrain-elevation-asl-ft")
        roll = try handle("attitude/phi-rad")
        pitch = try handle("attitude/theta-rad")
        heading = try handle("attitude/psi-rad")
        calibratedAirspeed = try handle("velocities/vc-kts")
        trueAirspeed = try handle("velocities/vtrue-kts")
        groundSpeedFps = try handle("velocities/vg-fps")
        verticalSpeedFps = try handle("velocities/h-dot-fps")
        velocityNorth = try handle("velocities/v-north-fps")
        velocityEast = try handle("velocities/v-east-fps")
        mach = try handle("velocities/mach")
        alpha = try handle("aero/alpha-deg")
        beta = try handle("aero/beta-deg")
        loadFactor = try handle("accelerations/Nz")
        rollRate = try handle("velocities/phidot-rad_sec")
        pitchRate = try handle("velocities/thetadot-rad_sec")
        windNorth = try handle("atmosphere/wind-north-fps")
        windEast = try handle("atmosphere/wind-east-fps")
        turbulenceType = try handle("atmosphere/turb-type")
        turbulenceSeverity = try handle("atmosphere/turbulence/milspec/severity")
        turbulenceWindAt20Feet = try handle("atmosphere/turbulence/milspec/windspeed_at_20ft_AGL-fps")
        temperatureOffset = try handle("atmosphere/delta-T")
        temperatureRankine = try handle("atmosphere/T-R")
        pressureRatio = try handle("atmosphere/delta")
        totalFuel = try handle("propulsion/total-fuel-lbs")
        weight = try handle("inertia/weight-lbs")
        flapPosition = try handle("fcs/flap-pos-norm")
        gearPosition = try handle("gear/gear-pos-norm")
        speedbrakePosition = try handle("fcs/speedbrake-pos-norm")
        elevatorPosition = try handle("fcs/elevator-pos-norm")
        leftAileronPosition = try handle("fcs/left-aileron-pos-norm")
        rightAileronPosition = try handle("fcs/right-aileron-pos-norm")
        rudderPosition = try handle("fcs/rudder-pos-norm")
        weightOnWheels = try wheelUnits.map { try handle("gear/unit[\($0)]/WOW") }
        stallWarning = try handle("systems/stall-warn-norm")
    }
}

enum FlightModelError: LocalizedError {
    case missingEngineGauge(Int)
    case diverged

    var errorDescription: String? {
        switch self {
        case .missingEngineGauge(let index): "Engine \(index + 1) reports neither N1 nor RPM."
        case .diverged: "The flight model became unstable and stopped. Restart the flight from the pause menu."
        }
    }
}

extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self { min(max(self, lower), upper) }
}
