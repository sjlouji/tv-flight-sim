import Foundation
import Testing
@testable import FlightSim

extension Scenario {
    /// The start condition for the aircraft `model` flies.
    @MainActor func startCondition(at airport: Airport, for model: FlightModel) throws -> StartCondition {
        try startCondition(at: airport, aircraft: model.profile, geometry: model.geometry)
    }
}

/// A JSBSim aircraft flown closed loop at 60 frames per second, the way the app flies it.
@MainActor
struct TestFlight {
    let model: FlightModel
    var controls: FlightControls
    var autopilot: Autopilot

    static func start(_ scenario: Scenario, aircraft: AircraftType, at airport: Airport,
                      adjust: (inout StartCondition) -> Void = { _ in }) throws -> TestFlight {
        let data = try #require(Bundle.main.url(forResource: "jsbsim-data", withExtension: nil))
        let model = try FlightModel(dataDirectory: data, profile: .profile(aircraft))
        var condition = try scenario.startCondition(at: airport, for: model)
        adjust(&condition)
        let trimmed = try model.reset(to: condition)
        var autopilot = Autopilot()
        autopilot.mcp.headingDegrees = condition.headingDegrees
        return TestFlight(model: model, controls: trimmed, autopilot: autopilot)
    }

    mutating func press(_ buttons: MCPButton..., guidance: GuidanceInput? = nil) {
        for button in buttons {
            let t = model.telemetry()
            let events = autopilot.press(button, telemetry: t, controls: controls,
                                         guidance: guidance ?? GuidanceInput(position: GeoPoint(latitude: t.latitude, longitude: t.longitude)))
            #expect(events.isEmpty, "\(button) rejected: \(events)")
        }
    }

    /// Runs the loop with the autopilot in charge, calling `guidance` each frame and `check` once per simulated second.
    mutating func fly(seconds: Double, guidance: (Telemetry) -> GuidanceInput? = { _ in nil },
                      check: (Telemetry, Double, Autopilot) -> Void = { _, _, _ in }) throws {
        let dt = 1.0 / 60
        for frame in 0..<Int(seconds * 60) {
            let t = model.telemetry()
            let input = guidance(t) ?? GuidanceInput(position: GeoPoint(latitude: t.latitude, longitude: t.longitude))
            var pilot = controls
            pilot.aileron = 0
            pilot.elevator = 0
            let (output, _) = autopilot.update(telemetry: t, pilot: pilot, pilotMovedThrust: false, guidance: input, deltaTime: dt)
            controls.aileron = output.aileron ?? 0
            controls.elevator = output.elevator ?? 0
            controls.pitchTrim = output.pitchTrim ?? controls.pitchTrim
            controls.throttle = output.throttle ?? controls.throttle
            model.apply(controls)
            try model.advance(by: dt)
            if frame % 60 == 0 { check(t, Double(frame) * dt, autopilot) }
        }
    }

    /// Runs the loop with `pilot` deciding the controls each frame.
    mutating func fly(seconds: Double, pilot: (Telemetry, inout FlightControls) -> Void) throws {
        let dt = 1.0 / 60
        for _ in 0..<Int(seconds * 60) {
            pilot(model.telemetry(), &controls)
            model.apply(controls)
            try model.advance(by: dt)
        }
    }
}

/// Every aircraft: its JSBSim file reads, it sits on the runway, takes off, and holds altitude on autopilot.
@MainActor
@Suite(.serialized) struct AircraftTests {
    let airport: Airport

    init() throws {
        airport = try Airport.load(icao: "KSFO")
    }

    private static let engineCounts: [AircraftType: Int] = [
        .b737: 2, .b747: 4, .b787: 2, .a320: 2, .c130: 4, .c172: 1, .dhc6: 2, .global5000: 2, .f4: 2,
    ]

    @Test(arguments: AircraftType.allCases)
    func geometryComesFromTheJSBSimFile(type: AircraftType) throws {
        let data = try #require(Bundle.main.url(forResource: "jsbsim-data", withExtension: nil))
        let profile = AircraftProfile.profile(type)
        let geometry = try AircraftDefinition.load(profile, dataDirectory: data)
        #expect(geometry.engines.count == Self.engineCounts[type])
        #expect(geometry.wheels.count == 3, "Wheels: \(geometry.wheels.map(\.name))")
        let nose = try #require(geometry.wheels.min { $0.position.z < $1.position.z })
        #expect(geometry.wheels.filter { $0.name != nose.name }.allSatisfy { $0.position.z > nose.position.z + 1 })
        #expect(geometry.wheels.allSatisfy { $0.position.y < 0 }, "Wheels must hang below the center of gravity")
        #expect(geometry.eyePoint.z < 0, "The pilot sits ahead of the center of gravity")
        #expect(geometry.eyePoint.y > geometry.wheels.map(\.position.y).max() ?? 0)
        #expect(abs(geometry.wingspan - profile.wingspanMeters) / profile.wingspanMeters < 0.08,
                "JSBSim span \(geometry.wingspan) m, published \(profile.wingspanMeters) m")
        // The drawn fuselage holds the pilot and stays clear of the runway.
        let shape = AirframeShape(profile: profile, geometry: geometry)
        let groundY = geometry.wheels.map(\.position.y).min() ?? 0
        #expect(shape.centerY - shape.radius * shape.oval > groundY + 0.2, "Fuselage bottom below the wheels")
        let eyeSection = shape.section(atNoseDistance: shape.eyeDistance)
        #expect(shape.eye.y < eyeSection.centerY + eyeSection.radius * eyeSection.scaleY - 0.15, "Eye outside the hull")
    }

    @Test(arguments: AircraftType.allCases)
    func sitsOnTheRunwayWithEnginesRunning(type: AircraftType) throws {
        var flight = try TestFlight.start(.takeoff(runway: "28L"), aircraft: type, at: airport)
        try flight.fly(seconds: 2) { _, _ in }
        let t = flight.model.telemetry()
        #expect(t.weightOnWheels)
        #expect(t.radioAltitudeFeet < 1.5, "Wheels \(t.radioAltitudeFeet) ft above the runway")
        #expect(t.groundSpeedKnots < 1, "Rolling at \(t.groundSpeedKnots) kt with the parking brake set")
        #expect(t.engineSpool.count == Self.engineCounts[type])
        #expect(t.engineSpool.allSatisfy { $0 > 0.15 && $0 < 0.8 }, "Idle spool \(t.engineSpool)")
    }

    @Test(arguments: AircraftType.allCases)
    func takesOffAndClimbs(type: AircraftType) throws {
        let profile = AircraftProfile.profile(type)
        var flight = try TestFlight.start(.takeoff(runway: "28L"), aircraft: type, at: airport)
        flight.controls.parkingBrake = false
        var rotated = false
        try flight.fly(seconds: 70) { t, controls in
            controls.throttle = 1
            // Rotate at VR toward 10 degrees nose up, wings level.
            if t.calibratedAirspeedKnots >= profile.vr { rotated = true }
            let pitch = t.pitchRadians * 180 / .pi
            let target = rotated ? 10.0 : 0
            controls.elevator = ((pitch - target) * 0.06 + t.pitchRate * 180 / .pi * 0.15).clamped(-0.8, 0.5)
            // Positive aileron rolls right, so a right bank takes negative aileron.
            controls.aileron = -(t.rollRadians * 180 / .pi * 0.05 + t.rollRate * 180 / .pi * 0.05).clamped(-0.5, 0.5)
            if t.radioAltitudeFeet > 100 && profile.retractableGear { controls.gearDown = false }
        }
        let t = flight.model.telemetry()
        #expect(rotated, "Never reached VR \(profile.vr) kt; IAS \(t.calibratedAirspeedKnots)")
        #expect(t.radioAltitudeFeet > 300, "Only \(Int(t.radioAltitudeFeet)) ft up after 70 s")
        #expect(t.verticalSpeedFeetPerMinute > 300, "Climbing \(Int(t.verticalSpeedFeetPerMinute)) ft/min")
        #expect(!t.stallWarning)
    }

    @Test(arguments: AircraftType.allCases)
    func holdsAltitudeSpeedAndHeadingOnAutopilot(type: AircraftType) throws {
        let profile = AircraftProfile.profile(type)
        let altitude = min(10_000, profile.ceiling - 4_000)
        let speed = profile.speed(atAltitude: altitude)
        var flight = try TestFlight.start(.airborne(altitudeFeet: altitude, bearingDegrees: 270, distanceNM: 20, headingDegrees: 280),
                                          aircraft: type, at: airport)
        flight.autopilot.mcp.speedKnots = speed
        flight.press(.autothrottle, .autopilot)
        flight.autopilot.mcp.headingDegrees = 320
        var worstAltitudeError = 0.0
        try flight.fly(seconds: 90, check: { t, _, _ in worstAltitudeError = max(worstAltitudeError, abs(t.altitudeMSLFeet - altitude)) })
        let t = flight.model.telemetry()
        #expect(flight.autopilot.autopilotEngaged)
        #expect(abs(Navigation.angleDifference(t.headingDegrees, 320)) < 4, "Heading \(t.headingDegrees)")
        #expect(worstAltitudeError < 200, "Altitude strayed \(Int(worstAltitudeError)) ft")
        #expect(abs(t.calibratedAirspeedKnots - speed) < 12, "IAS \(t.calibratedAirspeedKnots), wanted \(speed)")
    }

    @Test(arguments: AircraftType.allCases)
    func trimsOnFinalApproachAndHoldsTheGlidepath(type: AircraftType) throws {
        let profile = AircraftProfile.profile(type)
        var flight = try TestFlight.start(.approach(runway: "28L", distanceNM: 6), aircraft: type, at: airport)
        try flight.fly(seconds: 5) { _, _ in }
        let t = flight.model.telemetry()
        #expect(abs(t.calibratedAirspeedKnots - profile.approachSpeed) < 8, "IAS \(t.calibratedAirspeedKnots)")
        // Three degrees down at the approach speed.
        let expected = -t.groundSpeedKnots * 101.27 * tan(3 * Double.pi / 180)
        #expect(abs(t.verticalSpeedFeetPerMinute - expected) < 300, "VS \(Int(t.verticalSpeedFeetPerMinute)), expected \(Int(expected))")
    }

    @Test func flapDetentsMatchTheModelsFlapAngles() {
        // The 747's flaps 10 is a third of its 30-degree travel; the A320's FULL is 35 of 40 degrees.
        #expect(abs(AircraftProfile.profile(.b747).flaps[3].lever - 10.0 / 30) < 1e-9)
        #expect(abs(AircraftProfile.profile(.a320).landingFlaps - 35.0 / 40) < 1e-9)
        for profile in AircraftProfile.all {
            #expect(profile.flaps.first?.lever == 0)
            #expect(zip(profile.flaps, profile.flaps.dropFirst()).allSatisfy { $0.lever < $1.lever })
            #expect(profile.flaps.allSatisfy { $0.lever <= 1 })
        }
    }

    @Test func c130EnginesAreSpreadAlongTheWing() {
        let left = SIMD3<Float>(-6.73, -0.27, 0), right = SIMD3<Float>(6.73, -0.27, 0)
        let spread = AircraftModel.spreadEngines([left, left, right, right]).map(\.x)
        #expect(spread.map { ($0 * 100).rounded() / 100 } == [-4.88, -9.69, 4.88, 9.69])
    }
}
