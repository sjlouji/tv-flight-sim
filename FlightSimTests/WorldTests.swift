import Foundation
import Testing
import simd
@testable import FlightSim

@Suite struct GeoReferenceTests {
    let geo = GeoReference(latitude: 37.6218, longitude: -122.379, elevationMeters: 4)

    @Test func referencePointIsTheOrigin() {
        let p = geo.scenePosition(latitude: 37.6218, longitude: -122.379, altitudeMSLMeters: 4)
        #expect(simd_length(p) < 0.001)
    }

    @Test func northIsNegativeZAndEastIsPositiveX() {
        let north = geo.groundPosition(latitude: 37.6218 + 0.009, longitude: -122.379)
        #expect(abs(north.x) < 0.5)
        #expect(north.y < -990 && north.y > -1010)
        let east = geo.groundPosition(latitude: 37.6218, longitude: -122.379 + 0.0114)
        #expect(east.x > 990 && east.x < 1015)
    }

    @Test func coordinateInvertsEastNorth() {
        let c = geo.coordinate(east: 4_000, north: -2_500)
        let back = geo.eastNorth(latitude: c.latitude, longitude: c.longitude)
        #expect(abs(back.x - 4_000) < 0.05)
        #expect(abs(back.y + 2_500) < 0.05)
    }
}

@Suite struct AttitudeTests {
    func forward(_ q: simd_quatf) -> SIMD3<Float> { q.act(SIMD3(0, 0, -1)) }
    func right(_ q: simd_quatf) -> SIMD3<Float> { q.act(SIMD3(1, 0, 0)) }

    @Test func headingEastPointsTheNoseAtPositiveX() {
        let q = Attitude.orientation(roll: 0, pitch: 0, heading: .pi / 2)
        #expect(simd_distance(forward(q), SIMD3(1, 0, 0)) < 1e-5)
        #expect(simd_distance(right(q), SIMD3(0, 0, 1)) < 1e-5)
    }

    @Test func pitchUpRaisesTheNose() {
        let q = Attitude.orientation(roll: 0, pitch: 10 * .pi / 180, heading: 0)
        #expect(forward(q).y > 0.17)
    }

    @Test func rightRollLowersTheRightWing() {
        let q = Attitude.orientation(roll: 20 * .pi / 180, pitch: 0, heading: 0)
        #expect(right(q).y < -0.3)
    }
}

@Suite struct RunwayTests {
    @Test func designatorDecidesWhichEndIsWhich() {
        // A runway lying west to east: "09" must start at the west end.
        let west = SIMD2<Float>(-1000, 0)
        let east = SIMD2<Float>(1000, 0)
        let ends = RunwayEnd.pair(ref: "09/27", endA: east, endB: west, width: 45)
        #expect(ends.map(\.designator) == ["09", "27"])
        #expect(ends[0].threshold == west)
        #expect(abs(ends[0].trueHeadingDegrees - 90) < 0.01)
        #expect(abs(ends[1].trueHeadingDegrees - 270) < 0.01)
    }

    @Test @MainActor func sanFranciscoRunwaysMatchTheirRealHeadings() throws {
        let airport = try Airport.load(icao: "KSFO")
        let ends = Dictionary(uniqueKeysWithValues: airport.runwayEnds().map { ($0.designator, $0) })
        #expect(Set(ends.keys) == ["10L", "28R", "10R", "28L", "01R", "19L", "01L", "19R"])
        // Published true headings: 28L/28R about 298 degrees, 01L/01R about 28 degrees.
        let heading28L = try #require(ends["28L"]).trueHeadingDegrees
        let heading01R = try #require(ends["01R"]).trueHeadingDegrees
        #expect(abs(heading28L - 298) < 2)
        #expect(abs(heading01R - 28) < 2)
        #expect(try #require(ends["28L"]).length > 3_000)
    }
}

@Suite struct TriangulatorTests {
    func area(_ ring: [SIMD2<Float>], _ triangles: [(Int, Int, Int)]) -> Float {
        triangles.reduce(0) { total, t in total + abs(Triangulator.signedArea([ring[t.0], ring[t.1], ring[t.2]])) }
    }

    @Test func squareBecomesTwoTriangles() {
        let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        let triangles = Triangulator.triangulate(square)
        #expect(triangles.count == 2)
        #expect(abs(area(square, triangles) - 100) < 0.01)
    }

    @Test func concaveClockwiseClosedRingKeepsItsArea() {
        // An L shape, clockwise, with the closing point repeated (as OpenStreetMap rings are).
        let ring: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0, 20), SIMD2(10, 20), SIMD2(10, 10), SIMD2(20, 10), SIMD2(20, 0), SIMD2(0, 0)]
        let triangles = Triangulator.triangulate(ring)
        #expect(triangles.count == 4)
        #expect(abs(area(ring, triangles) - 300) < 0.01)
    }
}

@Suite struct AstronomyTests {
    let sfo = (latitude: 37.6189, longitude: -122.375)

    private func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: text) else { preconditionFailure("Bad test date \(text)") }
        return date
    }

    @Test func sunIsHighInTheSouthAtSolarNoonOnTheSolstice() {
        // San Francisco solar noon on 21 June 2026 is about 20:12 UTC; the sun is 90 - 37.6 + 23.44 = 75.8 degrees up.
        let sun = Astronomy.sun(at: utc("2026-06-21T20:12:00Z"), latitude: sfo.latitude, longitude: sfo.longitude)
        #expect(abs(sun.elevationDegrees - 75.8) < 0.5, "Elevation \(sun.elevationDegrees)")
        #expect(abs(sun.azimuthDegrees - 180) < 4, "Azimuth \(sun.azimuthDegrees)")
        #expect(sun.sceneDirection.y > 0.95)
    }

    @Test func sunriseAndSunsetMatchPublishedTimes() throws {
        // Published for San Francisco, 21 June 2026: sunrise 05:48 PDT (12:48 UTC), sunset 20:35 PDT (03:35 UTC next day).
        let times = try #require(Astronomy.sunriseSunset(near: utc("2026-06-21T19:00:00Z"), latitude: sfo.latitude, longitude: sfo.longitude))
        #expect(abs(times.rise.timeIntervalSince(utc("2026-06-21T12:48:00Z"))) < 240)
        #expect(abs(times.set.timeIntervalSince(utc("2026-06-22T03:35:00Z"))) < 240)
        #expect(Astronomy.sunriseSunset(near: utc("2026-06-21T12:00:00Z"), latitude: 80, longitude: 0) == nil, "Polar day has no sunset")
    }

    @Test func moonPhaseFollowsTheCalendar() {
        #expect(Astronomy.moonIllumination(at: utc("2024-04-23T23:49:00Z")) > 0.97, "Full moon")
        #expect(Astronomy.moonIllumination(at: utc("2024-04-08T18:21:00Z")) < 0.03, "New moon (the total eclipse)")
    }

    @Test func polarisSitsAboveTheNorthHorizonAtTheLatitude() {
        let rotation = Astronomy.celestialToScene(date: utc("2026-01-10T06:00:00Z"), latitude: sfo.latitude, longitude: sfo.longitude)
        let pole = rotation.act(SIMD3<Float>(0, 0, 1))
        let elevation = asin(Double(pole.y)) * 180 / .pi
        #expect(abs(elevation - sfo.latitude) < 0.1)
        #expect(pole.z < 0 && abs(pole.x) < 0.01, "The celestial pole is due north")
    }

    @Test func timeOfDayChoicesFallInOrder() {
        let now = utc("2026-03-15T20:00:00Z")
        let dates = TimeOfDay.allCases.filter { $0 != .now }.map { $0.date(today: now, latitude: sfo.latitude, longitude: sfo.longitude) }
        #expect(dates == dates.sorted())
        let dawn = Astronomy.sun(at: dates[0], latitude: sfo.latitude, longitude: sfo.longitude)
        let night = Astronomy.sun(at: dates.last!, latitude: sfo.latitude, longitude: sfo.longitude)
        #expect(dawn.elevationDegrees < 0 && dawn.elevationDegrees > -6, "Dawn is civil twilight")
        #expect(night.elevationDegrees < -18, "Night is astronomically dark")
    }
}

@Suite struct PAPITests {
    @Test func onGlideslopeShowsTwoWhiteTwoRed() {
        let light = SIMD3<Float>(0, 0, 0)
        let viewer = SIMD3<Float>(0, 1000 * tan(3 * .pi / 180), 1000)
        let angles: [Float] = [3.5, 3.1667, 2.8333, 2.5]
        let white = angles.map { PAPILight.showsWhite(viewer: viewer, light: light, transitionAngleDegrees: $0) }
        #expect(white == [false, false, true, true])
    }
}
