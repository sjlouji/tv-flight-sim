import Metal
import RealityKit
import UIKit
import simd

/// The weather you can see: cumulus fields built from lit billboard puffs (the way FlightGear draws
/// 3D clouds), stratus decks, rain streaks, and the whiteout when flying inside a cloud.
@MainActor
final class Clouds {
    let root = Entity()
    /// Rain streaks; attach to the camera so they always surround the viewer.
    let rain = Entity()

    private struct Cluster {
        let entity: ModelEntity
        /// Position in the 40 km tile (scene x, scene z), and its base and top altitude.
        let tilePosition: SIMD2<Double>
        let baseMeters: Double
        let topMeters: Double
        let radius: Double
    }

    private struct Deck {
        let entity: ModelEntity
        let altitudeMeters: Double
    }

    private var clusters: [Cluster] = []
    private var decks: [Deck] = []
    private let stratus: [(base: Double, top: Double)]
    private let rainIntensity: Double
    private var shown: WorldLighting?
    private var cumulusMaterial: CustomMaterial?

    /// The cumulus field is a 40 km tile wrapped around the aircraft, so clouds keep coming however far it flies.
    static let tileSize = 40_000.0
    /// The stratus noise repeats every 70.4 km (see `stratusSurface`).
    static let deckPeriod = 70_400.0
    static let deckSize: Float = 240_000
    static let clusterVariants = 8

    init(weather: WeatherSettings, fieldElevationMeters: Double, shaders: MTLLibrary, sky: TextureResource) throws {
        root.name = "Clouds"
        rainIntensity = weather.preset.rainIntensity
        let layers = weather.preset.layers
        stratus = layers.filter { $0.kind == .stratus }.map {
            (fieldElevationMeters + $0.baseFeet.feetToMeters, fieldElevationMeters + $0.topFeet.feetToMeters)
        }
        var rng = SeededGenerator(seed: 0xC10D)
        let puff = try Self.puffTexture()

        for layer in layers {
            let base = fieldElevationMeters + layer.baseFeet.feetToMeters
            let thickness = layer.thicknessFeet.feetToMeters
            switch layer.kind {
            case .cumulus:
                var material = try CustomMaterial(surfaceShader: .init(named: "cloudSurface", in: shaders),
                                                  geometryModifier: .init(named: "billboardGeometry", in: shaders), lightingModel: .unlit)
                material.baseColor = .init(tint: .white, texture: .init(puff))
                material.custom.texture = .init(sky)
                material.blending = .transparent(opacity: .init(scale: 0.75))
                cumulusMaterial = material
                let variants = try (0..<Self.clusterVariants).map { _ in try Self.clusterMesh(thickness: thickness, using: &rng) }
                let count = Int(layer.coverage * 230)
                for _ in 0..<count {
                    let variant = Int.random(in: 0..<variants.count, using: &rng)
                    let entity = ModelEntity(mesh: variants[variant].mesh, materials: [material])
                    let scale = Float.random(in: 0.7...1.3, using: &rng)
                    entity.scale = SIMD3(scale, Float.random(in: 0.8...1.1, using: &rng), scale)
                    entity.orientation = simd_quatf(angle: Float.random(in: 0..<(2 * .pi), using: &rng), axis: SIMD3(0, 1, 0))
                    entity.components.set(DynamicLightShadowComponent(castsShadow: false))
                    root.addChild(entity)
                    let half = Self.tileSize / 2
                    clusters.append(Cluster(entity: entity,
                                            tilePosition: SIMD2(Double.random(in: -half..<half, using: &rng), Double.random(in: -half..<half, using: &rng)),
                                            baseMeters: base, topMeters: base + thickness * Double(scale),
                                            radius: Double(variants[variant].radius * scale)))
                }
            case .stratus:
                for (altitude, fromAbove) in [(base, false), (base + thickness, true)] {
                    var material = try CustomMaterial(surfaceShader: .init(named: "stratusSurface", in: shaders),
                                                      geometryModifier: .init(named: "oceanGeometry", in: shaders), lightingModel: .unlit)
                    material.custom.texture = .init(sky)
                    material.blending = .transparent(opacity: .init(scale: Float(layer.coverage)))
                    material.faceCulling = .none
                    let entity = ModelEntity(mesh: try Self.deckMesh(), materials: [material])
                    entity.name = fromAbove ? "Cloud tops" : "Cloud base"
                    entity.components.set(DynamicLightShadowComponent(castsShadow: false))
                    root.addChild(entity)
                    decks.append(Deck(entity: entity, altitudeMeters: altitude))
                }
            }
        }
        if rainIntensity > 0 { rain.components.set(Self.rainEmitter(intensity: rainIntensity)) }
        Log.world.info("Clouds: \(self.clusters.count) cumulus, \(self.decks.count / 2) stratus decks, rain \(self.rainIntensity)")
    }

    /// Places the cloud field around the aircraft. `velocity` is the aircraft's velocity in scene axes (m/s),
    /// so rain streaks past at the right speed. Returns how far inside a cloud the aircraft is (0 ... 1).
    func update(anchor: SIMD2<Double>, altitudeMeters: Double, velocity: SIMD3<Float>, lighting: WorldLighting) -> Float {
        var whiteout = 0.0
        let half = Self.tileSize / 2
        for cluster in clusters {
            // The cluster's nearest copy in the repeating tile.
            var offset = cluster.tilePosition - anchor
            offset -= (offset / Self.tileSize).rounded(.toNearestOrAwayFromZero) * Self.tileSize
            cluster.entity.position = SIMD3(Float(offset.x), Float(cluster.baseMeters - altitudeMeters), Float(offset.y))
            let horizontal = simd_length(offset)
            if horizontal < cluster.radius && altitudeMeters > cluster.baseMeters && altitudeMeters < cluster.topMeters {
                whiteout = max(whiteout, 0.85 * (1 - horizontal / cluster.radius))
            }
            cluster.entity.isEnabled = horizontal < half + cluster.radius
        }
        let deckShift = WorldAnchor.shift(anchor, period: Self.deckPeriod)
        for deck in decks {
            deck.entity.position = SIMD3(-deckShift.x, Float(deck.altitudeMeters - altitudeMeters), -deckShift.y)
        }
        for layer in stratus {
            let inside = min(altitudeMeters - layer.base, layer.top - altitudeMeters)
            whiteout = max(whiteout, (inside / 60).clamped(0, 1) * 0.95)
        }
        if rainIntensity > 0, var emitter = rain.components[ParticleEmitterComponent.self] {
            // Rain falls at about 9 m/s; relative to the aircraft it streams past at the airspeed.
            let relative = SIMD3<Float>(0, -9, 0) - velocity
            let speed = simd_length(relative)
            emitter.emissionDirection = relative / max(speed, 0.1)
            emitter.speed = speed
            emitter.isEmitting = stratus.allSatisfy { altitudeMeters < $0.base }
            rain.components.set(emitter)
        }
        applyLighting(lighting)
        return Float(whiteout)
    }

    /// All cumulus share one material; each deck has its own (its coverage is in the material).
    private func applyLighting(_ lighting: WorldLighting) {
        if let shown, !lighting.differs(from: shown) { return }
        shown = lighting
        if var material = cumulusMaterial {
            lighting.apply(to: &material)
            cumulusMaterial = material
            for cluster in clusters { cluster.entity.model?.materials = [material] }
        }
        for deck in decks {
            guard var material = deck.entity.model?.materials.first as? CustomMaterial else { continue }
            lighting.apply(to: &material)
            deck.entity.model?.materials = [material]
        }
    }

    // MARK: - Geometry

    /// One cumulus: puffs filling a dome with a flat base, larger and denser low down.
    private static func clusterMesh(thickness: Double, using rng: inout SeededGenerator) throws -> (mesh: MeshResource, radius: Float) {
        let radius = Float.random(in: 500...1_300, using: &rng)
        let height = Float(min(thickness, Double(radius) * 2.4)) * Float.random(in: 0.6...1, using: &rng)
        let count = Int(Float.random(in: 26...46, using: &rng))
        var puffs: [(center: SIMD3<Float>, size: Float, height: Float)] = []
        for _ in 0..<count {
            let h = pow(Float.random(in: 0...1, using: &rng), 1.6)
            let spread = radius * (1 - 0.65 * h) * Float.random(in: 0...1, using: &rng).squareRoot()
            let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
            let size = radius * (0.42 - 0.18 * h) * Float.random(in: 0.8...1.2, using: &rng)
            puffs.append((SIMD3(cos(angle) * spread, max(h * height, size * 0.4), sin(angle) * spread), size, h))
        }
        // Low puffs first: seen from below or the side, the brighter tops then draw over the darker base.
        puffs.sort { $0.center.y < $1.center.y }
        var positions: [SIMD3<Float>] = [], uv0: [SIMD2<Float>] = [], uv1: [SIMD2<Float>] = [], indices: [UInt32] = []
        for puff in puffs {
            let base = UInt32(positions.count)
            for corner in [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)] {
                positions.append(puff.center)
                uv0.append(corner)
                uv1.append(SIMD2(puff.size, puff.height))
            }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return (try Sky.billboardMesh(name: "Cumulus", positions: positions, uv0: uv0, uv1: uv1, indices: indices), radius)
    }

    /// A flat grid for a cloud deck; the shader drops it with the Earth's curvature.
    private static func deckMesh() throws -> MeshResource {
        let cells = 48
        let half = deckSize / 2
        var positions: [SIMD3<Float>] = []
        for row in 0...cells {
            for column in 0...cells {
                positions.append(SIMD3(-half + deckSize * Float(column) / Float(cells), 0, -half + deckSize * Float(row) / Float(cells)))
            }
        }
        var indices: [UInt32] = []
        for row in 0..<cells {
            for column in 0..<cells {
                let a = UInt32(row * (cells + 1) + column), b = a + 1
                let c = a + UInt32(cells + 1), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        var builder = MeshBuilder()
        builder.addTriangles(positions, normals: Array(repeating: SIMD3(0, 1, 0), count: positions.count),
                             indices: indices.upFacing(positions: positions))
        return try builder.makeMesh(name: "Cloud deck")
    }

    /// A soft puff: a radial falloff broken up by a few octaves of noise so edges look like cloud, not discs.
    private static func puffTexture() throws -> TextureResource {
        let size = 128
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var rng = SeededGenerator(seed: 0x9F1F)
        let lattice = (0..<(17 * 17)).map { _ in Float.random(in: 0...1, using: &rng) }
        func noise(_ x: Float, _ y: Float, _ cells: Int) -> Float {
            let fx = x * Float(cells), fy = y * Float(cells)
            let ix = Int(fx), iy = Int(fy)
            let tx = fx - Float(ix), ty = fy - Float(iy)
            func at(_ i: Int, _ j: Int) -> Float { lattice[(j % 17) * 17 + (i % 17)] }
            let top = at(ix, iy) * (1 - tx) + at(ix + 1, iy) * tx
            let bottom = at(ix, iy + 1) * (1 - tx) + at(ix + 1, iy + 1) * tx
            return top * (1 - ty) + bottom * ty
        }
        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) + 0.5) / Float(size), v = (Float(y) + 0.5) / Float(size)
                let r = simd_length(SIMD2(u - 0.5, v - 0.5)) * 2
                let detail = noise(u, v, 4) * 0.45 + noise(u, v, 8) * 0.35 + noise(u, v, 16) * 0.2
                // Billowy: noise eats into the edge (so it isn't a circle) and mottles the inside; never fully
                // opaque, so overlapping puffs build up density the way cloud does.
                let edge = r + (detail - 0.5) * 0.55
                let density = (pow(max(1 - edge, 0), 1.3) * (0.35 + 0.7 * detail)).clamped(0, 0.7)
                let index = (y * size + x) * 4
                let alpha = UInt8(density * 255)
                pixels[index] = alpha
                pixels[index + 1] = alpha
                pixels[index + 2] = alpha
                pixels[index + 3] = alpha
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw SkyError.imageCreation
        }
        return try TextureResource(image: image, withName: "Cloud puff", options: .init(semantic: .color))
    }

    /// Rain streaks in a box around the camera.
    private static func rainEmitter(intensity: Double) -> ParticleEmitterComponent {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .box
        emitter.emitterShapeSize = SIMD3(60, 30, 60)
        emitter.birthLocation = .volume
        emitter.emissionDirection = SIMD3(0, -1, 0)
        emitter.speed = 9
        emitter.mainEmitter.birthRate = Float(6_000 * intensity)
        emitter.mainEmitter.lifeSpan = 1.2
        emitter.mainEmitter.size = 0.012
        emitter.mainEmitter.stretchFactor = 18
        emitter.mainEmitter.billboardMode = .billboardYAligned
        emitter.mainEmitter.isLightingEnabled = false
        emitter.mainEmitter.blendMode = .alpha
        return emitter
    }
}
