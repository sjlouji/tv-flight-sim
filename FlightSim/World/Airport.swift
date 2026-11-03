


import Foundation
import simd

/// Airport layout produced by scripts/fetch_airport.py from OpenStreetMap.
struct Airport: Decodable, Sendable {
    struct Reference: Decodable, Sendable {
        let latitude: Double
        let longitude: Double
        let elevationM: Double
    }

    struct Runway: Decodable, Sendable {
        let ref: String
        let widthM: Double
        let surface: String
        let centerline: [[Double]]
    }

    struct Taxiway: Decodable, Sendable {
        let ref: String
        let widthM: Double
        let centerline: [[Double]]
    }

    struct Apron: Decodable, Sendable {
        let outline: [[Double]]
    }

    struct Building: Decodable, Sendable {
        enum Kind: String, Decodable, Sendable { case terminal, hangar, controlTower = "control_tower", other }
        let kind: Kind
        let heightM: Double
        let outline: [[Double]]
    }

    struct Point: Decodable, Sendable {
        let ref: String
        let position: [Double]
    }

    let icao: String
    let name: String
    let attribution: String
    let reference: Reference
    let boundary: [[[Double]]]
    let runways: [Runway]
    let taxiways: [Taxiway]
    let aprons: [Apron]
    let buildings: [Building]
    let gates: [Point]

    var geoReference: GeoReference {
        GeoReference(latitude: reference.latitude, longitude: reference.longitude, elevationMeters: reference.elevationM)
    }

    static func load(icao: String, bundle: Bundle = .main) throws -> Airport {
        guard let url = bundle.url(forResource: icao, withExtension: "json", subdirectory: "Airports") else {
            throw AirportError.missingData(icao)
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Airport.self, from: Data(contentsOf: url))
        } catch {
            Log.world.error("Failed to decode airport \(icao, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw AirportError.invalidData(icao, error)
        }
    }

    /// Both landing directions of every runway, with thresholds in scene coordinates.
    func runwayEnds() -> [RunwayEnd] {
        let geo = geoReference
        return runways.flatMap { runway -> [RunwayEnd] in
            guard let first = runway.centerline.first, let last = runway.centerline.last else { return [] }
            let a = geo.groundPosition(latitude: first[0], longitude: first[1])
            let b = geo.groundPosition(latitude: last[0], longitude: last[1])
            return RunwayEnd.pair(ref: runway.ref, endA: a, endB: b, width: Float(runway.widthM))
        }
    }
}

/// The ground JSBSim should feel: the airport's flat surface inside its boundary; outside it, the terrain
/// (or the sea surface where the terrain is below sea level, or where no terrain is available).
///
/// The airport is built flat on a plane tangent at its reference point, while JSBSim's ground follows the
/// curved Earth. Away from the reference point the plane rises above the curve (0.3 m at 2 km), so the
/// height is measured to the plane itself; that keeps the wheels exactly on the drawn runway.
struct GroundModel {
    private let frame: LocalFrame
    private let boundary: [[SIMD2<Double>]]
    private let terrain: ((GeoPoint) -> Double?)?

    /// `terrain` gives the terrain height at a point, or nil where none is loaded.
    init(airport: Airport, terrain: ((GeoPoint) -> Double?)? = nil) {
        self.terrain = terrain
        frame = airport.geoReference.frame
        let geo = airport.geoReference
        boundary = airport.boundary.map { ring in ring.map { SIMD2<Double>(geo.groundPosition(latitude: $0[0], longitude: $0[1])) } }
    }

    /// Ground height above sea level, in meters, below a point.
    func elevationMeters(latitude: Double, longitude: Double) -> Double {
        let seaLevel = frame.scenePoint(ecef: WGS84.ecef(latitude: latitude, longitude: longitude, height: 0))
        guard boundary.contains(where: { Self.contains($0, SIMD2(seaLevel.x, seaLevel.z)) }) else {
            return max(terrain?(GeoPoint(latitude: latitude, longitude: longitude)) ?? 0, 0)
        }
        // The sea-level point lies `seaLevel.y` (negative) below the airport plane.
        return -seaLevel.y
    }

    /// Even-odd ray casting; works for either winding and with or without a repeated closing point.
    static func contains(_ ring: [SIMD2<Double>], _ point: SIMD2<Double>) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

enum AirportError: LocalizedError {
    case missingData(String)
    case invalidData(String, Error)

    var errorDescription: String? {
        switch self {
        case .missingData(let icao): "Airport data for \(icao) is not in the app bundle."
        case .invalidData(let icao, let error): "Airport data for \(icao) could not be read: \(error.localizedDescription)"
        }
    }
}

/// One landing direction of a runway, e.g. "28L".
struct RunwayEnd: Equatable, Sendable {
    let designator: String
    /// Threshold position on the ground plane (scene x, scene z).
    let threshold: SIMD2<Float>
    /// The opposite threshold.
    let farEnd: SIMD2<Float>
    let width: Float

    var length: Float { simd_distance(threshold, farEnd) }
    /// Unit vector along the landing direction on the ground plane (scene x, scene z).
    var direction: SIMD2<Float> { simd_normalize(farEnd - threshold) }
    /// True bearing in degrees clockwise from north.
    var trueHeadingDegrees: Double {
        let east = Double(direction.x)
        let north = Double(-direction.y)
        let degrees = atan2(east, north) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Splits "10L/28R" into its two directions, deciding which end is which from the designator numbers.
    static func pair(ref: String, endA: SIMD2<Float>, endB: SIMD2<Float>, width: Float) -> [RunwayEnd] {
        let parts = ref.split(separator: "/").map(String.init)
        guard parts.count == 2, let firstNumber = headingNumber(parts[0]) else { return [] }
        let candidate = RunwayEnd(designator: parts[0], threshold: endA, farEnd: endB, width: width)
        // A runway numbered 10 points about 100 degrees (magnetic). Magnetic variation is
        // under 30 degrees almost everywhere, so the orientation closer to the number wins.
        let difference = abs(angleDifference(candidate.trueHeadingDegrees, Double(firstNumber) * 10))
        let aIsFirst = difference < 90
        let first = RunwayEnd(designator: parts[0], threshold: aIsFirst ? endA : endB, farEnd: aIsFirst ? endB : endA, width: width)
        let second = RunwayEnd(designator: parts[1], threshold: first.farEnd, farEnd: first.threshold, width: width)
        return [first, second]
    }

    static func headingNumber(_ designator: String) -> Int? {
        Int(designator.prefix { $0.isNumber })
    }

    private static func angleDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}
