import Foundation
import RealityKit
import simd

/// Converts geographic coordinates to the scene's local frame around an airport reference point.
///
/// Scene axes follow RealityKit: +x east, +y up, -z north. Units are meters.
/// Horizontal positions use an exact WGS-84 east/north tangent-plane projection.
/// Height is altitude above the airport elevation, so the scene ground is flat
/// (Earth curvature is not drawn; it is under 1 m within 3.5 km of the airport).
struct GeoReference: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let elevationMeters: Double

    /// The tangent frame this reference's flat scene coordinates live in (origin at the reference elevation).
    var frame: LocalFrame { LocalFrame(latitude: latitude, longitude: longitude, height: elevationMeters) }

    /// East and north offsets in meters from the reference point.
    func eastNorth(latitude lat: Double, longitude lon: Double) -> SIMD2<Double> {
        let point = WGS84.ecef(latitude: lat, longitude: lon, height: 0)
        let origin = WGS84.ecef(latitude: latitude, longitude: longitude, height: 0)
        let delta = point - origin
        let phi = latitude * .pi / 180
        let lambda = longitude * .pi / 180
        let east = -sin(lambda) * delta.x + cos(lambda) * delta.y
        let north = -sin(phi) * cos(lambda) * delta.x - sin(phi) * sin(lambda) * delta.y + cos(phi) * delta.z
        return SIMD2(east, north)
    }

    /// Scene position for a point at `altitudeMSLMeters`.
    func scenePosition(latitude lat: Double, longitude lon: Double, altitudeMSLMeters: Double) -> SIMD3<Float> {
        let en = eastNorth(latitude: lat, longitude: lon)
        return SIMD3(Float(en.x), Float(altitudeMSLMeters - elevationMeters), Float(-en.y))
    }

    /// Scene position on the airport ground plane.
    func groundPosition(latitude lat: Double, longitude lon: Double) -> SIMD2<Float> {
        let en = eastNorth(latitude: lat, longitude: lon)
        return SIMD2(Float(en.x), Float(-en.y))
    }

    /// Inverse of `eastNorth` for short distances (used to place start positions), accurate to centimeters within 20 km.
    func coordinate(east: Double, north: Double) -> GeoPoint {
        var lat = latitude
        var lon = longitude
        for _ in 0..<4 {
            let current = eastNorth(latitude: lat, longitude: lon)
            let phi = lat * .pi / 180
            let metersPerDegreeLat = 111_132.954 - 559.822 * cos(2 * phi)
            let metersPerDegreeLon = 111_412.84 * cos(phi)
            lat += (north - current.y) / metersPerDegreeLat
            lon += (east - current.x) / metersPerDegreeLon
        }
        return GeoPoint(latitude: lat, longitude: lon)
    }
}

/// WGS-84 ellipsoid constants and the geodetic to Earth-centered (ECEF) conversion.
enum WGS84 {
    static let semiMajorAxis = 6_378_137.0
    static let flattening = 1 / 298.257_223_563
    static let eccentricitySquared = flattening * (2 - flattening)
    /// Mean Earth radius, for great-circle navigation.
    static let meanRadius = 6_371_008.8

    static func ecef(latitude lat: Double, longitude lon: Double, height: Double) -> SIMD3<Double> {
        let phi = lat * .pi / 180
        let lambda = lon * .pi / 180
        let n = semiMajorAxis / sqrt(1 - eccentricitySquared * sin(phi) * sin(phi))
        return SIMD3((n + height) * cos(phi) * cos(lambda),
                     (n + height) * cos(phi) * sin(lambda),
                     (n * (1 - eccentricitySquared) + height) * sin(phi))
    }
}

/// A frame tangent to the ellipsoid at a point, with the scene's axes (+x east, +y up, -z north), in meters.
///
/// The renderer re-centers the world on the aircraft every frame with one of these, so everything near the
/// camera has small coordinates. Float precision then never limits smoothness, however far the flight goes,
/// and distant content drops below the horizon with the Earth's curvature.
struct LocalFrame: Equatable, Sendable {
    /// Frame origin, Earth-centered Earth-fixed.
    let origin: SIMD3<Double>
    /// Rotates an ECEF vector into scene axes. Rows are east, up and south.
    let rotation: simd_double3x3
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double, height: Double) {
        self.latitude = latitude
        self.longitude = longitude
        let phi = latitude * .pi / 180
        let lambda = longitude * .pi / 180
        let east = SIMD3(-sin(lambda), cos(lambda), 0)
        let north = SIMD3(-sin(phi) * cos(lambda), -sin(phi) * sin(lambda), cos(phi))
        let up = SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
        origin = WGS84.ecef(latitude: latitude, longitude: longitude, height: height)
        rotation = simd_double3x3(rows: [east, up, -north])
    }

    func scenePoint(ecef point: SIMD3<Double>) -> SIMD3<Double> { rotation * (point - origin) }
    func ecefPoint(scene point: SIMD3<Double>) -> SIMD3<Double> { origin + rotation.transpose * point }

    /// The transform that places content built in `other`'s coordinates into this frame.
    func transform(from other: LocalFrame) -> Transform {
        let r = rotation * other.rotation.transpose
        let t = rotation * (other.origin - origin)
        let columns = (SIMD3<Float>(r.columns.0), SIMD3<Float>(r.columns.1), SIMD3<Float>(r.columns.2))
        return Transform(scale: .one, rotation: simd_quatf(simd_float3x3(columns: columns)), translation: SIMD3<Float>(t))
    }
}

/// Aircraft attitude conversion from JSBSim Euler angles (north-east-down frame) to a scene orientation.
enum Attitude {
    /// Orientation for a model whose nose points to -z, right wing to +x and top to +y.
    static func orientation(roll phi: Double, pitch theta: Double, heading psi: Double) -> simd_quatf {
        let (sφ, cφ) = (sin(phi), cos(phi))
        let (sθ, cθ) = (sin(theta), cos(theta))
        let (sψ, cψ) = (sin(psi), cos(psi))
        // Body axes expressed in north-east-down (columns of the body-to-NED rotation, ZYX order).
        let forwardNED = SIMD3(cθ * cψ, cθ * sψ, -sθ)
        let rightNED = SIMD3(sφ * sθ * cψ - cφ * sψ, sφ * sθ * sψ + cφ * cψ, sφ * cθ)
        let downNED = SIMD3(cφ * sθ * cψ + sφ * sψ, cφ * sθ * sψ - sφ * cψ, cφ * cθ)
        let modelX = scene(fromNED: rightNED)
        let modelY = -scene(fromNED: downNED)
        let modelZ = -scene(fromNED: forwardNED)
        return simd_quatf(simd_float3x3(columns: (modelX, modelY, modelZ)))
    }

    /// North-east-down vector to scene axes (+x east, +y up, -z north).
    static func scene(fromNED v: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3(Float(v.y), Float(-v.z), Float(-v.x))
    }
}

extension Double {
    static let feetPerMeter = 3.280_839_9
    var feetToMeters: Double { self / .feetPerMeter }
    var metersToFeet: Double { self * .feetPerMeter }
}
