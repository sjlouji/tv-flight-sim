import Foundation
import simd

/// Ways to start a flight at the departure airport.
enum Scenario: Hashable, Sendable {
    /// Lined up on the runway threshold, engines running, parking brake set.
    case takeoff(runway: String)
    /// On the 3 degree glideslope, gear down and landing flaps set.
    case approach(runway: String, distanceNM: Double = 3)
    /// Anywhere around the airport: in cruise configuration at `altitudeFeet`, `distanceNM` from the
    /// airport along `bearingDegrees` (true), flying `headingDegrees`.
    case airborne(altitudeFeet: Double, bearingDegrees: Double, distanceNM: Double, headingDegrees: Double)

    var title: String {
        switch self {
        case .takeoff(let runway): "Takeoff, runway \(runway)"
        case .approach(let runway, let distance): "Final approach, runway \(runway), \(Int(distance)) nm"
        case .airborne(let altitude, _, let distance, _):
            "In flight at \(Self.altitudeText(altitude)), \(Int(distance)) nm out"
        }
    }

    /// The runway the scene's runway camera looks along. Airborne starts use the longest runway.
    func runwayDesignator(at airport: Airport) -> String? {
        switch self {
        case .takeoff(let runway), .approach(let runway, _): runway
        case .airborne: airport.runwayEnds().max { $0.length < $1.length }?.designator
        }
    }

    static func altitudeText(_ feet: Double) -> String {
        feet >= 18_000 ? "FL\(Int(feet / 100))" : "\(Int(feet).formatted()) ft"
    }

    static let glideslopeDegrees = 3.0
    static let thresholdCrossingHeightFeet = 50.0
    /// Distance down the runway from the threshold where a takeoff starts (on the threshold stripes, as airliners line up).
    static let takeoffLineUpMeters: Float = 25

    /// `terrain` gives terrain heights outside the airport (nil: sea level there).
    func startCondition(at airport: Airport, aircraft: AircraftProfile, geometry: AircraftGeometry,
                        terrain: ((GeoPoint) -> Double?)? = nil) throws -> StartCondition {
        let geo = airport.geoReference
        let ground = GroundModel(airport: airport, terrain: terrain)
        func groundFeet(_ c: GeoPoint) -> Double {
            ground.elevationMeters(latitude: c.latitude, longitude: c.longitude).metersToFeet
        }
        switch self {
        case .takeoff(let runway):
            let end = try Self.runwayEnd(runway, at: airport)
            let spot = end.threshold + end.direction * Self.takeoffLineUpMeters
            let coordinate = geo.coordinate(east: Double(spot.x), north: Double(-spot.y))
            var controls = FlightControls()
            controls.flaps = aircraft.takeoffFlaps
            controls.gearDown = true
            controls.parkingBrake = true
            return StartCondition(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                  terrainElevationFeet: groundFeet(coordinate), altitudeAGLFeet: geometry.groundCGHeightFeet,
                                  headingDegrees: end.trueHeadingDegrees, airspeedKnots: 0,
                                  flightPathAngleDegrees: 0, controls: controls, onGround: true)
        case .approach(let runway, let distanceNM):
            let end = try Self.runwayEnd(runway, at: airport)
            let distance = distanceNM * Navigation.metersPerNauticalMile
            let spot = end.threshold - end.direction * Float(distance)
            let coordinate = geo.coordinate(east: Double(spot.x), north: Double(-spot.y))
            let threshold = geo.coordinate(east: Double(end.threshold.x), north: Double(-end.threshold.y))
            let heightMSLFeet = groundFeet(threshold) + distance.metersToFeet * tan(Self.glideslopeDegrees * .pi / 180)
                + Self.thresholdCrossingHeightFeet
            let terrain = groundFeet(coordinate)
            var controls = FlightControls()
            controls.flaps = aircraft.landingFlaps
            controls.gearDown = true
            controls.throttle = 0.5
            return StartCondition(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                  terrainElevationFeet: terrain, altitudeAGLFeet: heightMSLFeet - terrain,
                                  headingDegrees: end.trueHeadingDegrees, airspeedKnots: aircraft.approachSpeed,
                                  flightPathAngleDegrees: -Self.glideslopeDegrees, controls: controls, onGround: false)
        case .airborne(let altitudeFeet, let bearing, let distanceNM, let heading):
            let coordinate = Navigation.destination(from: GeoPoint(latitude: geo.latitude, longitude: geo.longitude), bearingDegrees: bearing,
                                                    distanceMeters: distanceNM * Navigation.metersPerNauticalMile)
            let terrain = groundFeet(coordinate)
            var controls = FlightControls()
            controls.gearDown = !aircraft.retractableGear
            controls.throttle = 0.7
            return StartCondition(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                  terrainElevationFeet: terrain, altitudeAGLFeet: altitudeFeet - terrain,
                                  headingDegrees: heading, airspeedKnots: aircraft.speed(atAltitude: altitudeFeet),
                                  flightPathAngleDegrees: 0, controls: controls, onGround: false)
        }
    }

    private static func runwayEnd(_ designator: String, at airport: Airport) throws -> RunwayEnd {
        guard let end = airport.runwayEnds().first(where: { $0.designator == designator }) else {
            throw ScenarioError.unknownRunway(designator, airport.icao)
        }
        return end
    }
}

enum ScenarioError: LocalizedError {
    case unknownRunway(String, String)

    var errorDescription: String? {
        switch self {
        case .unknownRunway(let runway, let icao): "Runway \(runway) does not exist at \(icao)."
        }
    }
}
