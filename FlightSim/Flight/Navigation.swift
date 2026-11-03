import Foundation

/// A latitude and longitude in degrees (WGS-84).
struct GeoPoint: Hashable, Sendable {
    var latitude: Double
    var longitude: Double
}

/// An airport from the worldwide list built by scripts/fetch_world_airports.py (OurAirports, public domain).
struct NavAirport: Decodable, Hashable, Sendable, Identifiable {
    /// One landing direction, with its threshold.
    struct Runway: Decodable, Hashable, Sendable {
        let id: String
        let lat: Double
        let lon: Double
        /// True course from this threshold toward the opposite one.
        let heading: Double
        let lengthFt: Double
        let widthFt: Double
        let elevationFt: Double

        var threshold: GeoPoint { GeoPoint(latitude: lat, longitude: lon) }
    }

    let icao: String
    let iata: String
    let name: String
    let city: String
    let country: String
    let lat: Double
    let lon: Double
    let elevationFt: Double
    let runways: [Runway]

    var id: String { icao }
    var position: GeoPoint { GeoPoint(latitude: lat, longitude: lon) }
    var longestRunway: Runway? { runways.max { $0.lengthFt < $1.lengthFt } }

    /// The runway end most into the wind, longest first among ties.
    func bestRunway(windFromDegrees: Double, windSpeedKnots: Double) -> Runway? {
        guard windSpeedKnots >= 3 else { return longestRunway }
        return runways.max { a, b in
            let headwindA = cos(Navigation.angleDifference(a.heading, windFromDegrees) * .pi / 180)
            let headwindB = cos(Navigation.angleDifference(b.heading, windFromDegrees) * .pi / 180)
            if abs(headwindA - headwindB) < 0.05 { return a.lengthFt < b.lengthFt }
            return headwindA < headwindB
        }
    }
}

/// The bundled worldwide airport list.
struct NavDatabase: Decodable, Sendable {
    let attribution: String
    let airports: [NavAirport]

    func airport(icao: String) -> NavAirport? { airports.first { $0.icao == icao } }

    /// Matches ICAO and IATA codes by prefix, and names and cities by substring, codes first.
    func search(_ text: String, limit: Int = 40) -> [NavAirport] {
        let query = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !query.isEmpty else { return [] }
        let codes = airports.filter { $0.icao.hasPrefix(query) || $0.iata.hasPrefix(query) }
        let names = airports.filter {
            !codes.contains($0) && ($0.name.uppercased().contains(query) || $0.city.uppercased().contains(query))
        }
        return Array((codes + names).prefix(limit))
    }

    static func load(bundle: Bundle = .main) throws -> NavDatabase {
        guard let url = bundle.url(forResource: "world", withExtension: "json", subdirectory: "Airports") else {
            throw NavigationError.missingDatabase
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(NavDatabase.self, from: Data(contentsOf: url))
        } catch {
            Log.flight.error("World airport list failed to decode: \(error.localizedDescription, privacy: .public)")
            throw NavigationError.invalidDatabase(error)
        }
    }
}

enum NavigationError: LocalizedError {
    case missingDatabase
    case invalidDatabase(Error)
    case noRunway(String)

    var errorDescription: String? {
        switch self {
        case .missingDatabase: "The worldwide airport list is missing from the app bundle."
        case .invalidDatabase(let error): "The worldwide airport list could not be read: \(error.localizedDescription)"
        case .noRunway(let icao): "\(icao) has no runway long enough for this aircraft."
        }
    }
}

/// Great-circle navigation on a spherical Earth (good to 0.5 %, the standard for flight planning).
enum Navigation {
    static let metersPerNauticalMile = 1852.0

    static func distanceMeters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let (phi1, phi2) = (a.latitude * .pi / 180, b.latitude * .pi / 180)
        let dPhi = phi2 - phi1
        let dLambda = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * WGS84.meanRadius * atan2(h.squareRoot(), (1 - h).squareRoot())
    }

    /// Initial course from `a` toward `b`, degrees true (0 ..< 360).
    static func bearingDegrees(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let (phi1, phi2) = (a.latitude * .pi / 180, b.latitude * .pi / 180)
        let dLambda = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        return Telemetry.compassDegrees(atan2(y, x))
    }

    static func destination(from start: GeoPoint, bearingDegrees: Double, distanceMeters: Double) -> GeoPoint {
        let delta = distanceMeters / WGS84.meanRadius
        let theta = bearingDegrees * .pi / 180
        let phi1 = start.latitude * .pi / 180
        let lambda1 = start.longitude * .pi / 180
        let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta))
        let lambda2 = lambda1 + atan2(sin(theta) * sin(delta) * cos(phi1), cos(delta) - sin(phi1) * sin(phi2))
        var longitude = lambda2 * 180 / .pi
        longitude = (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        return GeoPoint(latitude: phi2 * 180 / .pi, longitude: longitude)
    }

    /// Distance of `point` from the great circle through `a` and `b`: positive right of the course from a to b.
    static func crossTrackMeters(_ point: GeoPoint, from a: GeoPoint, to b: GeoPoint) -> Double {
        let d13 = distanceMeters(a, point) / WGS84.meanRadius
        let theta13 = bearingDegrees(a, point) * .pi / 180
        let theta12 = bearingDegrees(a, b) * .pi / 180
        return asin(sin(d13) * sin(theta13 - theta12)) * WGS84.meanRadius
    }

    /// Distance along the course from `a` toward `b` to the point abeam `point` (negative if behind `a`).
    static func alongTrackMeters(_ point: GeoPoint, from a: GeoPoint, to b: GeoPoint) -> Double {
        let d13 = distanceMeters(a, point) / WGS84.meanRadius
        let dxt = crossTrackMeters(point, from: a, to: b) / WGS84.meanRadius
        let along = acos(min(max(cos(d13) / cos(dxt), -1), 1)) * WGS84.meanRadius
        let ahead = abs(angleDifference(bearingDegrees(a, point), bearingDegrees(a, b))) < 90
        return ahead ? along : -along
    }

    /// Signed smallest difference `a - b` in degrees, in -180 ... 180.
    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}

/// A point on the route.
struct Waypoint: Hashable, Sendable {
    let name: String
    let position: GeoPoint
}

/// The route from the departure airport to a landing runway at the destination:
/// departure, a fix 12 nm out on the extended runway centerline, and the runway threshold.
struct FlightPlan: Hashable, Sendable {
    let departureICAO: String
    let destination: NavAirport
    let arrivalRunway: NavAirport.Runway
    let waypoints: [Waypoint]

    static let finalFixDistanceNM = 12.0

    init(departureICAO: String, departure: GeoPoint, destination: NavAirport, arrivalRunway: NavAirport.Runway) {
        self.departureICAO = departureICAO
        self.destination = destination
        self.arrivalRunway = arrivalRunway
        let finalFix = Navigation.destination(from: arrivalRunway.threshold, bearingDegrees: arrivalRunway.heading + 180,
                                              distanceMeters: Self.finalFixDistanceNM * Navigation.metersPerNauticalMile)
        waypoints = [
            Waypoint(name: departureICAO, position: departure),
            Waypoint(name: "FINAL", position: finalFix),
            Waypoint(name: "RW\(arrivalRunway.id)", position: arrivalRunway.threshold),
        ]
    }

    var totalDistanceMeters: Double {
        zip(waypoints, waypoints.dropFirst()).reduce(0) { $0 + Navigation.distanceMeters($1.0.position, $1.1.position) }
    }

    /// The instrument landing system for the arrival runway.
    var landingSystem: LandingSystem {
        LandingSystem(threshold: arrivalRunway.threshold, courseDegrees: arrivalRunway.heading,
                      thresholdElevationFeet: arrivalRunway.elevationFt, runwayLengthMeters: arrivalRunway.lengthFt.feetToMeters)
    }
}

/// Lateral navigation along a flight plan: which leg is active, where the aircraft is relative to it.
struct RouteProgress: Equatable, Sendable {
    /// Index of the waypoint being flown to (the active leg runs from `activeWaypoint - 1`).
    private(set) var activeWaypoint = 1

    /// A waypoint is passed when the aircraft is abeam it, or within this distance (turn anticipation).
    static let sequenceDistanceMeters = 1.5 * Navigation.metersPerNauticalMile

    mutating func update(position: GeoPoint, plan: FlightPlan) {
        while activeWaypoint < plan.waypoints.count - 1 {
            let from = plan.waypoints[activeWaypoint - 1].position
            let to = plan.waypoints[activeWaypoint].position
            let legLength = Navigation.distanceMeters(from, to)
            let along = Navigation.alongTrackMeters(position, from: from, to: to)
            guard along >= legLength - Self.sequenceDistanceMeters else { break }
            activeWaypoint += 1
        }
    }

    func activeLeg(_ plan: FlightPlan) -> (from: Waypoint, to: Waypoint) {
        (plan.waypoints[activeWaypoint - 1], plan.waypoints[activeWaypoint])
    }

    /// Track to fly to follow the active leg: its course plus an intercept angle proportional to the
    /// cross-track error (limited to 35 degrees), so the aircraft converges smoothly onto the line.
    func desiredTrackDegrees(position: GeoPoint, plan: FlightPlan) -> Double {
        let leg = activeLeg(plan)
        let crossTrack = Navigation.crossTrackMeters(position, from: leg.from.position, to: leg.to.position)
        let toNext = max(Navigation.distanceMeters(position, leg.to.position), 1)
        let course = Navigation.bearingDegrees(position, leg.to.position) + atan2(crossTrack, toNext) * 180 / .pi
        let intercept = min(max(crossTrack / Navigation.metersPerNauticalMile * 25, -35), 35)
        return Telemetry.compassDegrees((course - intercept) * .pi / 180)
    }

    /// Distance still to fly along the route.
    func remainingMeters(position: GeoPoint, plan: FlightPlan) -> Double {
        var total = Navigation.distanceMeters(position, plan.waypoints[activeWaypoint].position)
        for index in activeWaypoint..<(plan.waypoints.count - 1) {
            total += Navigation.distanceMeters(plan.waypoints[index].position, plan.waypoints[index + 1].position)
        }
        return total
    }
}

/// A synthetic ILS on the arrival runway: localizer along the centerline, 3 degree glideslope
/// crossing the threshold at 50 ft.
struct LandingSystem: Equatable, Sendable {
    let threshold: GeoPoint
    let courseDegrees: Double
    let thresholdElevationFeet: Double
    let runwayLengthMeters: Double

    static let glideslopeDegrees = 3.0
    static let crossingHeightFeet = 50.0
    /// Full-scale needle deflection (two dots).
    static let localizerFullScaleDegrees = 2.5
    static let glideslopeFullScaleDegrees = 0.7

    private var farPoint: GeoPoint {
        Navigation.destination(from: threshold, bearingDegrees: courseDegrees, distanceMeters: runwayLengthMeters)
    }
    private var outerPoint: GeoPoint {
        Navigation.destination(from: threshold, bearingDegrees: courseDegrees + 180, distanceMeters: 40 * Navigation.metersPerNauticalMile)
    }

    /// Meters right (+) or left (-) of the extended centerline.
    func lateralOffsetMeters(_ position: GeoPoint) -> Double {
        Navigation.crossTrackMeters(position, from: outerPoint, to: threshold)
    }

    /// Meters from the threshold along the approach (positive before reaching it).
    func distanceToThresholdMeters(_ position: GeoPoint) -> Double {
        -Navigation.alongTrackMeters(position, from: threshold, to: farPoint)
    }

    /// Altitude of the glideslope above sea level at a distance before the threshold.
    func glideslopeAltitudeFeet(distanceMeters: Double) -> Double {
        thresholdElevationFeet + Self.crossingHeightFeet + distanceMeters.metersToFeet * tan(Self.glideslopeDegrees * .pi / 180)
    }

    /// Localizer deviation in degrees: negative when the aircraft is right of the centerline (fly left).
    func localizerDeviationDegrees(_ position: GeoPoint) -> Double {
        Navigation.angleDifference(Navigation.bearingDegrees(position, farPoint), courseDegrees)
    }

    /// Glideslope deviation in degrees: positive when above the slope (fly down).
    func glideslopeDeviationDegrees(_ position: GeoPoint, altitudeFeet: Double) -> Double {
        let distance = max(distanceToThresholdMeters(position) + 300, 1)
        let height = (altitudeFeet - thresholdElevationFeet).feetToMeters
        return atan2(height, distance) * 180 / .pi - Self.glideslopeDegrees
    }
}
