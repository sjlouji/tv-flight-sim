import Metal
import RealityKit
import UIKit
import simd

/// Sun and haze values shared by the world's custom materials (see Shaders.metal).
struct WorldLighting: Equatable, Sendable {
    var sunAzimuth: Float
    var sunElevation: Float
    var sunVisibility: Float
    var hazeDensity: Float
    var sunColor: SIMD3<Float>

    var customValue: SIMD4<Float> { SIMD4(sunAzimuth, sunElevation, sunVisibility, hazeDensity) }

    /// True when the change is big enough to be worth a material write.
    func differs(from other: WorldLighting) -> Bool {
        simd_length(customValue - other.customValue) > 0.002 || simd_length(sunColor - other.sunColor) > 0.01
    }

    func apply(to material: inout CustomMaterial) {
        material.custom.value = customValue
        material.baseColor.tint = UIColor(red: CGFloat(sunColor.x), green: CGFloat(sunColor.y), blue: CGFloat(sunColor.z), alpha: 1)
    }
}

/// Keeps Earth-anchored patterns (waves, cloud fields) still while the world is re-centered on the aircraft:
/// the mesh moves with the aircraft but is shifted back by the aircraft's position modulo the pattern period.
enum WorldAnchor {
    /// `anchor` is the aircraft's position in a fixed Earth frame (scene x, scene z). Returns it modulo
    /// `period`, in -period/2 ..< period/2, small enough for Float precision.
    static func shift(_ anchor: SIMD2<Double>, period: Double) -> SIMD2<Float> {
        func wrap(_ value: Double) -> Float {
            let r = value - (value / period).rounded() * period
            return Float(r)
        }
        return SIMD2(wrap(anchor.x), wrap(anchor.y))
    }
}

/// The sea: a disc of water out to the horizon that follows the aircraft, curved with the Earth in the
/// shader, with Earth-anchored waves, Fresnel sky reflection, sun glint and haze.
@MainActor
final class Ocean {
    let entity: ModelEntity
    private var shown: WorldLighting?

    /// The wave pattern repeats every 1,600 m (see `oceanSurface`).
    static let wavePeriod = 1_600.0
    static let radius: Float = 450_000

    init(shaders: MTLLibrary, sky: TextureResource) throws {
        var material = try CustomMaterial(surfaceShader: .init(named: "oceanSurface", in: shaders),
                                          geometryModifier: .init(named: "oceanGeometry", in: shaders), lightingModel: .unlit)
        material.custom.texture = .init(sky)
        entity = ModelEntity(mesh: try Self.mesh(), materials: [material])
        entity.name = "Ocean"
        entity.components.set(DynamicLightShadowComponent(castsShadow: false))
    }

    /// `altitudeMeters` is the aircraft's height above sea level; the sea sits that far below the origin.
    func update(anchor: SIMD2<Double>, altitudeMeters: Double, lighting: WorldLighting) {
        let shift = WorldAnchor.shift(anchor, period: Self.wavePeriod)
        entity.position = SIMD3(-shift.x, Float(-altitudeMeters), -shift.y)
        if let shown, !lighting.differs(from: shown) { return }
        guard var material = entity.model?.materials.first as? CustomMaterial else { return }
        lighting.apply(to: &material)
        entity.model?.materials = [material]
        shown = lighting
    }

    /// Rings spaced geometrically from 2 m to the horizon, so vertices are dense near the aircraft
    /// (smooth curvature and haze) and sparse far away.
    private static func mesh() throws -> MeshResource {
        let segments = 128
        let rings = 80
        var positions: [SIMD3<Float>] = [.zero]
        for ring in 1...rings {
            let r = 2 * pow(radius / 2, Float(ring) / Float(rings))
            for segment in 0..<segments {
                let angle = Float(segment) / Float(segments) * 2 * .pi
                positions.append(SIMD3(cos(angle) * r, 0, sin(angle) * r))
            }
        }
        var indices: [UInt32] = []
        for segment in 0..<segments {
            indices += [0, UInt32(1 + segment), UInt32(1 + (segment + 1) % segments)]
        }
        for ring in 0..<(rings - 1) {
            for segment in 0..<segments {
                let a = UInt32(1 + ring * segments + segment)
                let b = UInt32(1 + ring * segments + (segment + 1) % segments)
                let c = a + UInt32(segments), d = b + UInt32(segments)
                indices += [a, c, b, b, c, d]
            }
        }
        var builder = MeshBuilder()
        builder.addTriangles(positions, normals: Array(repeating: SIMD3(0, 1, 0), count: positions.count),
                             indices: indices.upFacing(positions: positions))
        return try builder.makeMesh(name: "Ocean")
    }
}
