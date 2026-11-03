import Foundation
import Testing
import simd
@testable import FlightSim

/// Runs the real JSBSim 737 from the app bundle.
@MainActor
@Suite(.serialized) struct FlightModelTests {
    let airport: Airport

    init() throws {
        airport = try Airport.load(icao: "KSFO")
    }

    private func makeModel() throws -> FlightModel {
        let data = try #require(Bundle.main.url(forResource: "jsbsim-data", withExtension: nil))
        return try FlightModel(dataDirectory: data, profile: .profile(.b737))
    }

    private func run(_ model: FlightModel, seconds: Double, controls: FlightControls) throws {
        model.apply(controls)
        for _ in 0..<Int(seconds * 60) {
            model.apply(controls)
            try model.advance(by: 1.0 / 60)
        }
    }

    @Test func missingFlightDataFailsWithAnError() throws {
        let missing = URL(filePath: NSTemporaryDirectory()).appending(path: "no-jsbsim-data")
        #expect(throws: (any Error).self) { try FlightModel(dataDirectory: missing, profile: .profile(.b737)) }
    }

    @Test func takeoffStartSitsOnTheRunwayAndAccelerates() throws {
        let model = try makeModel()
        let start = try Scenario.takeoff(runway: "28L").startCondition(at: airport, for: model)
        try model.reset(to: start)
        var t = model.telemetry()
        #expect(t.weightOnWheels)
        #expect(t.radioAltitudeFeet < 1.5, "Wheels \(t.radioAltitudeFeet) ft above the runway")
        #expect(abs(t.headingRadians * 180 / .pi - start.headingDegrees) < 1)
        let placed = airport.geoReference.eastNorth(latitude: t.latitude, longitude: t.longitude)
        let intended = airport.geoReference.eastNorth(latitude: start.latitude, longitude: start.longitude)
        #expect(simd_distance(placed, intended) < 1, "Placed \(simd_distance(placed, intended)) m from the start point")

        var controls = start.controls
        controls.parkingBrake = false
        controls.throttle = 1
        try run(model, seconds: 30, controls: controls)
        t = model.telemetry()
        #expect(t.calibratedAirspeedKnots > 110, "737 should pass 110 kt within 30 s at takeoff thrust; got \(t.calibratedAirspeedKnots)")
        #expect(t.engineN1.allSatisfy { $0 > 85 })
        // Still close to the runway centerline (no steering input).
        let geo = airport.geoReference
        let end = try #require(airport.runwayEnds().first { $0.designator == "28L" })
        let p = geo.groundPosition(latitude: t.latitude, longitude: t.longitude)
        let offset = p - end.threshold
        let lateral = abs(offset.x * end.direction.y - offset.y * end.direction.x)
        #expect(lateral < 15, "Drifted \(lateral) m off the centerline")
    }

    @Test func approachStartIsTrimmedOnTheGlideslope() throws {
        let model = try makeModel()
        let start = try Scenario.approach(runway: "28L").startCondition(at: airport, for: model)
        let trimmed = try model.reset(to: start)
        var t = model.telemetry()
        #expect(!t.weightOnWheels)
        #expect(trimmed.throttle > 0.05 && trimmed.throttle < 0.9, "Trim thrust \(trimmed.throttle)")
        #expect(abs(t.calibratedAirspeedKnots - model.profile.approachSpeed) < 3)
        #expect(abs(t.flapPosition - start.controls.flaps) < 0.01)
        #expect(t.gearPosition > 0.99)
        try run(model, seconds: 5, controls: trimmed)
        t = model.telemetry()
        // 3 degrees at 145 kt is about 770 ft/min down.
        #expect(t.verticalSpeedFeetPerMinute < -500 && t.verticalSpeedFeetPerMinute > -1100, "VS \(t.verticalSpeedFeetPerMinute)")
        #expect(abs(t.calibratedAirspeedKnots - model.profile.approachSpeed) < 8, "IAS \(t.calibratedAirspeedKnots)")
    }

    @Test func positiveAileronRollsRight() throws {
        let model = try makeModel()
        let start = try Scenario.approach(runway: "28L").startCondition(at: airport, for: model)
        var controls = try model.reset(to: start)
        controls.aileron = 0.5
        try run(model, seconds: 2, controls: controls)
        #expect(model.telemetry().rollRadians > 5 * .pi / 180)
    }

    @Test func positiveElevatorPitchesNoseDown() throws {
        let model = try makeModel()
        let start = try Scenario.approach(runway: "28L").startCondition(at: airport, for: model)
        var controls = try model.reset(to: start)
        let pitchBefore = model.telemetry().pitchRadians
        controls.elevator = 0.5
        try run(model, seconds: 1.5, controls: controls)
        #expect(model.telemetry().pitchRadians < pitchBefore - 2 * .pi / 180)
    }

    @Test func positiveRudderTurnsRightOnTheGround() throws {
        let model = try makeModel()
        let start = try Scenario.takeoff(runway: "28L").startCondition(at: airport, for: model)
        try model.reset(to: start)
        let headingBefore = model.telemetry().headingRadians
        var controls = start.controls
        controls.parkingBrake = false
        controls.throttle = 0.4
        controls.rudder = 1
        try run(model, seconds: 12, controls: controls)
        var change = model.telemetry().headingRadians - headingBefore
        if change > .pi { change -= 2 * .pi }
        if change < -.pi { change += 2 * .pi }
        #expect(change > 5 * .pi / 180, "Heading changed \(change * 180 / .pi) degrees")
    }
}

@MainActor
@Suite struct WeatherInFlightModelTests {
    @Test func windSurvivesResetAndTrim() throws {
        let data = try #require(Bundle.main.url(forResource: "jsbsim-data", withExtension: nil))
        let model = try FlightModel(dataDirectory: data, profile: .profile(.b737))
        let airport = try Airport.load(icao: "KSFO")
        let start = try Scenario.airborne(altitudeFeet: 10_000, bearingDegrees: 270, distanceNM: 20, headingDegrees: 90).startCondition(at: airport, for: model)
        let atmosphere = AtmosphereSettings(windFromDegrees: 270, windSpeedKnots: 30)
        let controls = try model.reset(to: start, atmosphere: atmosphere)
        model.apply(controls)
        for _ in 0..<120 { try model.advance(by: 1.0 / 60) }
        let t = model.telemetry()
        #expect(abs(t.windSpeedKnots - 30) < 0.5, "Wind \(t.windSpeedKnots) kt")
        #expect(abs(Navigation.angleDifference(t.windFromDegrees, 270)) < 1)
        // Flying east with a 30 kt tailwind: ground speed is about true airspeed plus 30.
        #expect(abs(t.groundSpeedKnots - t.trueAirspeedKnots - 30) < 3, "GS \(t.groundSpeedKnots), TAS \(t.trueAirspeedKnots)")
    }
}

@MainActor
@Suite struct ApproachWithWindTests {
    @Test(arguments: [0.0, 10, 25])
    func approachTrimsInWind(speed: Double) throws {
        let data = try #require(Bundle.main.url(forResource: "jsbsim-data", withExtension: nil))
        let model = try FlightModel(dataDirectory: data, profile: .profile(.b737))
        let airport = try Airport.load(icao: "KSFO")
        let start = try Scenario.approach(runway: "28L", distanceNM: 6).startCondition(at: airport, for: model)
        let atmosphere = WeatherSettings(preset: .scattered, windFromDegrees: 280, windSpeedKnots: speed).atmosphere
        _ = try model.reset(to: start, atmosphere: atmosphere)
        // The headwind arrives after the trim, so the airspeed starts up to the wind speed above the target.
        #expect(abs(model.telemetry().calibratedAirspeedKnots - model.profile.approachSpeed) < speed + 3)
    }
}
