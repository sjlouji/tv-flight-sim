import Foundation
import Testing
@testable import FlightSim

/// Flies the real JSBSim 737 under autopilot control, closed loop at 60 frames per second.
@MainActor
@Suite(.serialized) struct AutopilotTests {
    let airport: Airport
    let database: NavDatabase

    init() throws {
        airport = try Airport.load(icao: "KSFO")
        database = try NavDatabase.load()
    }

    private func start(_ scenario: Scenario, adjust: (inout StartCondition) -> Void = { _ in }) throws -> TestFlight {
        try TestFlight.start(scenario, aircraft: .b737, at: airport, adjust: adjust)
    }

    @Test func holdsAltitudeAndTurnsToTheSelectedHeading() throws {
        var flight = try start(.airborne(altitudeFeet: 10_000, bearingDegrees: 270, distanceNM: 20, headingDegrees: 280))
        flight.autopilot.mcp.speedKnots = 250
        flight.press(.autothrottle, .autopilot)
        #expect(flight.autopilot.pitchMode == .altitudeHold)
        flight.autopilot.mcp.headingDegrees = 10
        var worstAltitudeError = 0.0
        try flight.fly(seconds: 100, check: { t, _, _ in worstAltitudeError = max(worstAltitudeError, abs(t.altitudeMSLFeet - 10_000)) })
        let t = flight.model.telemetry()
        #expect(abs(Navigation.angleDifference(t.headingDegrees, 10)) < 3, "Heading \(t.headingDegrees)")
        #expect(worstAltitudeError < 150, "Altitude strayed \(worstAltitudeError) ft during the turn")
        #expect(abs(t.calibratedAirspeedKnots - 250) < 8, "IAS \(t.calibratedAirspeedKnots)")
        #expect(abs(t.rollRadians) < 3 * .pi / 180, "Still banked \(t.rollRadians * 180 / .pi) degrees")
    }

    @Test func verticalSpeedDescentCapturesTheSelectedAltitude() throws {
        var flight = try start(.airborne(altitudeFeet: 10_000, bearingDegrees: 270, distanceNM: 20, headingDegrees: 90))
        flight.autopilot.mcp.speedKnots = 250
        flight.press(.autothrottle, .autopilot)
        flight.autopilot.mcp.altitudeFeet = 8_000
        flight.press(.verticalSpeed)
        flight.autopilot.mcp.verticalSpeedFPM = -1_500
        var steepest = 0.0
        try flight.fly(seconds: 130, check: { t, _, _ in steepest = min(steepest, t.verticalSpeedFeetPerMinute) })
        let t = flight.model.telemetry()
        #expect(steepest < -1_300 && steepest > -2_000, "Steepest descent \(steepest) ft/min")
        #expect(abs(t.altitudeMSLFeet - 8_000) < 60, "Altitude \(t.altitudeMSLFeet)")
        #expect(flight.autopilot.pitchMode == .altitudeHold)
        #expect(abs(t.calibratedAirspeedKnots - 250) < 10, "IAS \(t.calibratedAirspeedKnots)")
    }

    @Test func levelChangeClimbsAtTheSelectedSpeed() throws {
        var flight = try start(.airborne(altitudeFeet: 10_000, bearingDegrees: 270, distanceNM: 20, headingDegrees: 90))
        flight.autopilot.mcp.speedKnots = 280
        flight.press(.autothrottle, .autopilot)
        flight.autopilot.mcp.altitudeFeet = 18_000
        flight.press(.levelChange)
        #expect(flight.autopilot.thrustMode == .climb)
        var speeds: [Double] = []
        // Sample once the pitch-up has settled, until the level-off begins.
        try flight.fly(seconds: 300, check: { t, time, autopilot in
            if time > 25 && autopilot.pitchMode == .levelChange { speeds.append(t.calibratedAirspeedKnots) }
        })
        let t = flight.model.telemetry()
        #expect(abs(t.altitudeMSLFeet - 18_000) < 100, "Altitude \(t.altitudeMSLFeet)")
        #expect(flight.autopilot.pitchMode == .altitudeHold)
        let worst = speeds.map { abs($0 - 280) }.max() ?? 0
        #expect(!speeds.isEmpty && worst < 12, "Climb speed strayed \(worst) kt from 280")
    }

    @Test func approachModeCapturesTheLocalizerAndGlideslope() throws {
        var flight = try start(.approach(runway: "28L", distanceNM: 12)) { start in
            // Arrive 25 degrees off the runway heading, level, as a vector to intercept would.
            start.headingDegrees += 25
            start.flightPathAngleDegrees = 0
        }
        let end = try #require(database.airport(icao: "KSFO")?.runways.first { $0.id == "28L" })
        let ils = LandingSystem(threshold: end.threshold, courseDegrees: end.heading, thresholdElevationFeet: end.elevationFt,
                                runwayLengthMeters: end.lengthFt.feetToMeters)
        flight.autopilot.mcp.speedKnots = AircraftProfile.profile(.b737).approachSpeed
        flight.autopilot.mcp.altitudeFeet = 2_000
        let guidance: (Telemetry) -> GuidanceInput = { t in
            GuidanceInput(position: GeoPoint(latitude: t.latitude, longitude: t.longitude), lnavTrackDegrees: nil, landingSystem: ils)
        }
        let first = flight.model.telemetry()
        flight.press(.autothrottle, .autopilot, .approach, guidance: guidance(first))
        var at300: (offset: Double, deviation: Double)?
        try flight.fly(seconds: 400, guidance: guidance) { t, _, autopilot in
            let position = GeoPoint(latitude: t.latitude, longitude: t.longitude)
            if at300 == nil && autopilot.pitchMode == .glideslope && t.radioAltitudeFeet < 300 {
                at300 = (ils.lateralOffsetMeters(position), ils.glideslopeDeviationDegrees(position, altitudeFeet: t.altitudeMSLFeet))
            }
        }
        let reached = try #require(at300, "Never reached 300 ft on the glideslope; roll \(flight.autopilot.rollMode), pitch \(flight.autopilot.pitchMode)")
        #expect(abs(reached.offset) < 15, "\(reached.offset) m off the centerline at 300 ft")
        #expect(abs(reached.deviation) < 0.2, "Glideslope deviation \(reached.deviation) degrees at 300 ft")
        let t = flight.model.telemetry()
        #expect(t.weightOnWheels, "The flare and touchdown did not happen; AGL \(t.altitudeAGLFeet)")
    }

    @Test func lnavFollowsTheRoute() throws {
        var flight = try start(.airborne(altitudeFeet: 12_000, bearingDegrees: 180, distanceNM: 10, headingDegrees: 90))
        let destination = try #require(database.airport(icao: "KLAX"))
        let runway = try #require(destination.longestRunway)
        let geo = airport.geoReference
        let plan = FlightPlan(departureICAO: "KSFO", departure: GeoPoint(latitude: geo.latitude, longitude: geo.longitude),
                              destination: destination, arrivalRunway: runway)
        var progress = RouteProgress()
        flight.autopilot.mcp.speedKnots = 280
        let guidance: (Telemetry) -> GuidanceInput = { t in
            let position = GeoPoint(latitude: t.latitude, longitude: t.longitude)
            progress.update(position: position, plan: plan)
            return GuidanceInput(position: position, lnavTrackDegrees: progress.desiredTrackDegrees(position: position, plan: plan))
        }
        flight.press(.autothrottle, .autopilot, guidance: guidance(flight.model.telemetry()))
        flight.press(.lnav, guidance: guidance(flight.model.telemetry()))
        try flight.fly(seconds: 240, guidance: guidance)
        let t = flight.model.telemetry()
        let leg = progress.activeLeg(plan)
        let crossTrack = Navigation.crossTrackMeters(GeoPoint(latitude: t.latitude, longitude: t.longitude),
                                                     from: leg.from.position, to: leg.to.position)
        #expect(abs(crossTrack) < 0.3 * Navigation.metersPerNauticalMile, "Cross-track \(crossTrack) m")
        #expect(abs(Navigation.angleDifference(t.trackDegrees, Navigation.bearingDegrees(leg.from.position, leg.to.position))) < 8)
    }

    @Test func stickInputDisconnectsTheAutopilot() throws {
        var flight = try start(.airborne(altitudeFeet: 10_000, bearingDegrees: 270, distanceNM: 20, headingDegrees: 90))
        flight.press(.autopilot)
        var pilot = flight.controls
        pilot.elevator = -0.6
        let (_, events) = flight.autopilot.update(telemetry: flight.model.telemetry(), pilot: pilot, pilotMovedThrust: false,
                                                  guidance: GuidanceInput(position: GeoPoint(latitude: 0, longitude: 0)), deltaTime: 1.0 / 60)
        #expect(events == [.autopilotDisconnected("Pilot override")])
        #expect(!flight.autopilot.autopilotEngaged)
    }

    @Test func autopilotWillNotEngageOnTheGround() throws {
        var flight = try start(.takeoff(runway: "28L"))
        let t = flight.model.telemetry()
        let events = flight.autopilot.press(.autopilot, telemetry: t, controls: flight.controls,
                                            guidance: GuidanceInput(position: GeoPoint(latitude: t.latitude, longitude: t.longitude)))
        #expect(events == [.rejected("Autopilot engages above 400 ft")])
    }
}
