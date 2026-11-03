import Foundation
import Testing
import simd
@testable import FlightSim

@Suite struct NavigationTests {
    let sfo = GeoPoint(latitude: 37.6189, longitude: -122.3750)
    let lax = GeoPoint(latitude: 33.9425, longitude: -118.4081)

    @Test func sanFranciscoToLosAngeles() {
        // Published great-circle distance 293 nm, initial course about 137 degrees true.
        let nm = Navigation.distanceMeters(sfo, lax) / Navigation.metersPerNauticalMile
        #expect(abs(nm - 293) < 2, "\(nm) nm")
        #expect(abs(Navigation.bearingDegrees(sfo, lax) - 137) < 2)
    }

    @Test func destinationInvertsDistanceAndBearing() {
        let point = Navigation.destination(from: sfo, bearingDegrees: 45, distanceMeters: 100_000)
        #expect(abs(Navigation.distanceMeters(sfo, point) - 100_000) < 1)
        #expect(abs(Navigation.bearingDegrees(sfo, point) - 45) < 0.01)
    }

    @Test func crossTrackIsPositiveRightOfCourse() {
        // Course due east along the equator; a point north of it is left, south is right.
        let a = GeoPoint(latitude: 0, longitude: 0), b = GeoPoint(latitude: 0, longitude: 1)
        #expect(Navigation.crossTrackMeters(GeoPoint(latitude: -0.01, longitude: 0.5), from: a, to: b) > 1_000)
        #expect(Navigation.crossTrackMeters(GeoPoint(latitude: 0.01, longitude: 0.5), from: a, to: b) < -1_000)
        #expect(abs(Navigation.alongTrackMeters(GeoPoint(latitude: 0.01, longitude: 0.5), from: a, to: b) - 55_660) < 100)
        #expect(Navigation.alongTrackMeters(GeoPoint(latitude: 0, longitude: -0.5), from: a, to: b) < 0)
    }

    @Test func routeSequencesWaypointsAndSteersBackToTheLine() throws {
        let runway = NavAirport.Runway(id: "25L", lat: lax.latitude, lon: lax.longitude, heading: 263, lengthFt: 12_000,
                                       widthFt: 150, elevationFt: 125)
        let destination = NavAirport(icao: "KLAX", iata: "LAX", name: "Los Angeles", city: "Los Angeles", country: "US",
                                     lat: lax.latitude, lon: lax.longitude, elevationFt: 125, runways: [runway])
        let plan = FlightPlan(departureICAO: "KSFO", departure: sfo, destination: destination, arrivalRunway: runway)
        #expect(plan.waypoints.map(\.name) == ["KSFO", "FINAL", "RW25L"])
        var progress = RouteProgress()
        let course = Navigation.bearingDegrees(sfo, plan.waypoints[1].position)
        // 2 nm right of the first leg: steer left of the course.
        let right = Navigation.destination(from: Navigation.destination(from: sfo, bearingDegrees: course, distanceMeters: 50_000),
                                           bearingDegrees: course + 90, distanceMeters: 2 * 1852)
        progress.update(position: right, plan: plan)
        let track = progress.desiredTrackDegrees(position: right, plan: plan)
        #expect(Navigation.angleDifference(track, course) < -20)
        // Abeam the final fix, the route moves on to the runway leg.
        progress.update(position: plan.waypoints[1].position, plan: plan)
        #expect(progress.activeLeg(plan).to.name == "RW25L")
    }

    @Test func landingSystemDeviationSigns() {
        let ils = LandingSystem(threshold: GeoPoint(latitude: 0, longitude: 0), courseDegrees: 90, thresholdElevationFeet: 0,
                                runwayLengthMeters: 3_000)
        // 10 km before the threshold, 100 m right (south) of the centerline, on the glideslope.
        let onSlope = GeoPoint(latitude: -100 / 111_320, longitude: -10_000 / 111_320)
        let altitude = ils.glideslopeAltitudeFeet(distanceMeters: 10_000)
        #expect(ils.lateralOffsetMeters(onSlope) > 90 && ils.lateralOffsetMeters(onSlope) < 110)
        #expect(ils.localizerDeviationDegrees(onSlope) < 0, "Right of the centerline reads fly left")
        #expect(abs(ils.glideslopeDeviationDegrees(onSlope, altitudeFeet: altitude)) < 0.1)
        #expect(ils.glideslopeDeviationDegrees(onSlope, altitudeFeet: altitude + 500) > 0.4)
    }

    @Test @MainActor func worldDatabaseHasTheMajorAirports() throws {
        let database = try NavDatabase.load()
        #expect(database.airports.count > 2_000)
        #expect(database.airport(icao: "EGLL")?.runways.contains { $0.id == "27L" } == true)
        #expect(database.search("LAX").first?.icao == "KLAX")
        #expect(database.search("heathrow").first?.icao == "EGLL")
    }
}

@Suite struct InterpolationTests {
    @Test func poseBlendsPositionAndTakesTheShortWayAroundAngles() {
        let a = Pose(latitude: 10, longitude: 179.9, altitudeMSLFeet: 1_000, roll: 0, pitch: 0, heading: 359 * .pi / 180)
        let b = Pose(latitude: 11, longitude: -179.9, altitudeMSLFeet: 2_000, roll: 0.2, pitch: 0, heading: 1 * .pi / 180)
        let mid = Pose.interpolate(from: a, to: b, fraction: 0.5)
        #expect(abs(mid.latitude - 10.5) < 1e-9)
        #expect(abs(mid.altitudeMSLFeet - 1_500) < 1e-9)
        #expect(abs(abs(mid.longitude) - 180) < 1e-6, "Longitude \(mid.longitude) must cross the date line, not go round")
        #expect(abs(Telemetry.compassDegrees(mid.heading)) < 1e-6 || abs(Telemetry.compassDegrees(mid.heading) - 360) < 1e-6)
        #expect(abs(mid.roll - 0.1) < 1e-9)
    }

    /// The stutter fix: with uneven frame times the drawn aircraft must still move evenly.
    @Test @MainActor func renderedMotionIsSmoothWithUnevenFrames() throws {
        let data = try #require(Bundle.main.url(forResource: "jsbsim-data", withExtension: nil))
        let model = try FlightModel(dataDirectory: data, profile: .profile(.b737))
        let airport = try Airport.load(icao: "KSFO")
        let controls = try model.reset(to: Scenario.airborne(altitudeFeet: 10_000, bearingDegrees: 0, distanceNM: 10, headingDegrees: 90)
            .startCondition(at: airport, for: model))
        model.apply(controls)
        let geo = airport.geoReference
        var previous: SIMD2<Double>?
        var speeds: [Double] = []
        // Frame times jitter around 60 Hz the way a real display link does.
        let frames = [0.0166, 0.0168, 0.0165, 0.0170, 0.0163, 0.0167, 0.0166, 0.0169, 0.0164, 0.0167]
        for i in 0..<300 {
            let dt = frames[i % frames.count]
            try model.advance(by: dt)
            let pose = model.renderPose
            let p = geo.eastNorth(latitude: pose.latitude, longitude: pose.longitude)
            if let previous, i > 10 { speeds.append(simd_distance(p, previous) / dt) }
            previous = p
        }
        let mean = speeds.reduce(0, +) / Double(speeds.count)
        let worst = speeds.map { abs($0 - mean) / mean }.max() ?? 1
        #expect(worst < 0.03, "Drawn speed varies \(worst * 100)% frame to frame; it must look steady")
    }
}

@Suite struct LocalFrameTests {
    @Test func originIsZeroAndUpIsTheEllipsoidNormal() {
        let frame = LocalFrame(latitude: 37.6, longitude: -122.4, height: 100)
        #expect(simd_length(frame.scenePoint(ecef: frame.origin)) < 1e-6)
        let above = frame.scenePoint(ecef: WGS84.ecef(latitude: 37.6, longitude: -122.4, height: 1_100))
        #expect(abs(above.y - 1_000) < 1e-6 && abs(above.x) < 1e-6 && abs(above.z) < 1e-6)
        let north = frame.scenePoint(ecef: WGS84.ecef(latitude: 37.61, longitude: -122.4, height: 100))
        #expect(north.z < -1_000 && abs(north.x) < 1)
    }

    @Test func transformBetweenFramesMatchesPointConversion() {
        let airport = LocalFrame(latitude: 37.6189, longitude: -122.375, height: 4)
        let aircraft = LocalFrame(latitude: 37.70, longitude: -122.20, height: 3_000)
        let local = SIMD3<Double>(1_200, 0, -800)
        let expected = aircraft.scenePoint(ecef: airport.ecefPoint(scene: local))
        let moved = aircraft.transform(from: airport).matrix * SIMD4<Float>(SIMD3<Float>(local), 1)
        #expect(simd_distance(SIMD3<Float>(moved.x, moved.y, moved.z), SIMD3<Float>(expected)) < 0.05)
    }
}

@Suite @MainActor struct GroundModelTests {
    @Test func airportSurfaceInsideTheBoundaryAndSeaOutside() throws {
        let airport = try Airport.load(icao: "KSFO")
        let ground = GroundModel(airport: airport)
        let arp = airport.reference
        #expect(abs(ground.elevationMeters(latitude: arp.latitude, longitude: arp.longitude) - arp.elevationM) < 0.01)
        let bay = Navigation.destination(from: GeoPoint(latitude: arp.latitude, longitude: arp.longitude), bearingDegrees: 70,
                                         distanceMeters: 6_000)
        #expect(ground.elevationMeters(latitude: bay.latitude, longitude: bay.longitude) == 0)
        // 2 km from the reference point the flat airport plane sits about 0.3 m above the curved Earth.
        let end = try #require(airport.runwayEnds().first { $0.designator == "28L" })
        let threshold = airport.geoReference.coordinate(east: Double(end.threshold.x), north: Double(-end.threshold.y))
        let distance = Navigation.distanceMeters(threshold, GeoPoint(latitude: arp.latitude, longitude: arp.longitude))
        let rise = ground.elevationMeters(latitude: threshold.latitude, longitude: threshold.longitude) - arp.elevationM
        #expect(abs(rise - distance * distance / (2 * WGS84.meanRadius)) < 0.05)
    }
}
