import Metal
import RealityKit
import UIKit

/// The app's compiled Metal shaders (Shaders.metal), used by the custom materials.
enum ShaderLibrary {
    @MainActor
    static func load() throws -> MTLLibrary {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Log.world.error("No Metal device")
            throw MaterialError.noMetal
        }
        guard let library = device.makeDefaultLibrary() else {
            Log.world.error("The default Metal library is missing from the bundle")
            throw MaterialError.noShaderLibrary
        }
        return library
    }
}

/// How thick the haze is, for the scenery shaders.
struct HazeSettings: Equatable, Sendable {
    /// Extinction per meter at sea level (Koschmieder: 3.912 / visibility).
    var densityPerMeter: Float
    /// Altitude above sea level of the scenery's model origin (the airport reference elevation).
    var originAltitudeMeters: Float

    init(visibilityMeters: Double, originAltitudeMeters: Double) {
        densityPerMeter = Float(3.912 / visibilityMeters)
        self.originAltitudeMeters = Float(originAltitudeMeters)
    }
}

/// Materials for the airport, aircraft and interiors. Scenery materials fade into the haze with distance
/// (see `sceneryHazeSurface`); the aircraft's are standard physically based materials.
@MainActor
struct MaterialLibrary {
    let asphalt: CustomMaterial
    let concrete: CustomMaterial
    let grass: CustomMaterial
    let whitePaint: CustomMaterial
    let yellowPaint: CustomMaterial
    let terminal: CustomMaterial
    let hangar: CustomMaterial
    let building: CustomMaterial
    let fuselage: PhysicallyBasedMaterial
    let wing: PhysicallyBasedMaterial
    let engine: PhysicallyBasedMaterial
    let engineInlet: PhysicallyBasedMaterial
    let fanBlade: PhysicallyBasedMaterial
    let tire: PhysicallyBasedMaterial
    let window: PhysicallyBasedMaterial
    let whiteLight: UnlitMaterial
    let greenLight: UnlitMaterial
    let redLight: UnlitMaterial
    // Flight deck and cabin. Interiors are softly self-lit, like a lit cabin, so they read in any light.
    let panel: PhysicallyBasedMaterial
    let lining: PhysicallyBasedMaterial
    let glareshield: PhysicallyBasedMaterial
    let lever: PhysicallyBasedMaterial
    let seat: PhysicallyBasedMaterial
    let carpet: PhysicallyBasedMaterial
    let cabinWall: PhysicallyBasedMaterial
    let cabinCeiling: PhysicallyBasedMaterial
    let skin: PhysicallyBasedMaterial
    let hair: PhysicallyBasedMaterial
    let cabinLight: UnlitMaterial

    static func load(bundle: Bundle = .main, shaders: MTLLibrary, sky: TextureResource, haze: HazeSettings) async throws -> MaterialLibrary {
        let repeatSampler = Self.repeatSampler()
        func hazed(_ material: PhysicallyBasedMaterial) throws -> CustomMaterial {
            var custom = try CustomMaterial(from: material, surfaceShader: .init(named: "sceneryHazeSurface", in: shaders))
            custom.custom.texture = .init(sky)
            custom.custom.value = SIMD4(haze.densityPerMeter, haze.originAltitudeMeters, 0, 0)
            return custom
        }
        let asphalt = try await Self.textured("asphalt", tint: .init(white: 0.62, alpha: 1), sampler: repeatSampler, bundle: bundle)
        let concrete = try await Self.textured("concrete", tint: .init(white: 0.95, alpha: 1), sampler: repeatSampler, bundle: bundle)
        let grass = try await Self.textured("grass", tint: .init(red: 0.78, green: 0.86, blue: 0.70, alpha: 1), sampler: repeatSampler, bundle: bundle)
        return MaterialLibrary(
            asphalt: try hazed(asphalt),
            concrete: try hazed(concrete),
            grass: try hazed(grass),
            whitePaint: try hazed(Self.solid(UIColor(white: 0.92, alpha: 1), roughness: 0.6, metallic: 0)),
            yellowPaint: try hazed(Self.solid(UIColor(red: 0.95, green: 0.75, blue: 0.10, alpha: 1), roughness: 0.6, metallic: 0)),
            terminal: try hazed(Self.solid(UIColor(red: 0.62, green: 0.68, blue: 0.74, alpha: 1), roughness: 0.25, metallic: 0.6)),
            hangar: try hazed(Self.solid(UIColor(red: 0.78, green: 0.79, blue: 0.80, alpha: 1), roughness: 0.45, metallic: 0.5)),
            building: try hazed(Self.solid(UIColor(red: 0.80, green: 0.77, blue: 0.72, alpha: 1), roughness: 0.8, metallic: 0)),
            fuselage: Self.solid(UIColor(white: 0.96, alpha: 1), roughness: 0.28, metallic: 0.15, clearcoat: 0.6),
            wing: Self.solid(UIColor(red: 0.74, green: 0.76, blue: 0.79, alpha: 1), roughness: 0.35, metallic: 0.55),
            engine: Self.solid(UIColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 1), roughness: 0.3, metallic: 0.7),
            engineInlet: Self.solid(UIColor(white: 0.08, alpha: 1), roughness: 0.5, metallic: 0.8),
            fanBlade: Self.solid(UIColor(white: 0.55, alpha: 1), roughness: 0.35, metallic: 0.9),
            tire: Self.solid(UIColor(white: 0.05, alpha: 1), roughness: 0.9, metallic: 0),
            window: Self.solid(UIColor(red: 0.05, green: 0.08, blue: 0.12, alpha: 1), roughness: 0.05, metallic: 0.2, clearcoat: 1),
            whiteLight: UnlitMaterial(color: UIColor(red: 1, green: 0.96, blue: 0.85, alpha: 1)),
            greenLight: UnlitMaterial(color: UIColor(red: 0.2, green: 1, blue: 0.3, alpha: 1)),
            redLight: UnlitMaterial(color: UIColor(red: 1, green: 0.12, blue: 0.08, alpha: 1)),
            panel: Self.solid(UIColor(red: 0.30, green: 0.33, blue: 0.36, alpha: 1), roughness: 0.7, metallic: 0, glow: 0.25),
            lining: Self.solid(UIColor(red: 0.62, green: 0.64, blue: 0.65, alpha: 1), roughness: 0.8, metallic: 0, glow: 0.3),
            glareshield: Self.solid(UIColor(white: 0.06, alpha: 1), roughness: 0.95, metallic: 0, glow: 0.02),
            lever: Self.solid(UIColor(white: 0.12, alpha: 1), roughness: 0.4, metallic: 0.3, glow: 0.04),
            seat: Self.solid(UIColor(red: 0.12, green: 0.16, blue: 0.30, alpha: 1), roughness: 0.9, metallic: 0, glow: 0.12),
            carpet: Self.solid(UIColor(red: 0.20, green: 0.18, blue: 0.22, alpha: 1), roughness: 1, metallic: 0, glow: 0.10),
            cabinWall: Self.solid(UIColor(red: 0.70, green: 0.69, blue: 0.66, alpha: 1), roughness: 0.7, metallic: 0, glow: 0.08),
            cabinCeiling: Self.solid(UIColor(red: 0.80, green: 0.80, blue: 0.78, alpha: 1), roughness: 0.7, metallic: 0, glow: 0.1),
            skin: Self.solid(UIColor(red: 0.78, green: 0.60, blue: 0.48, alpha: 1), roughness: 0.6, metallic: 0, glow: 0.12),
            hair: Self.solid(UIColor(red: 0.14, green: 0.10, blue: 0.08, alpha: 1), roughness: 0.8, metallic: 0, glow: 0.05),
            cabinLight: UnlitMaterial(color: UIColor(red: 1, green: 0.97, blue: 0.9, alpha: 1))
        )
    }

    private static func repeatSampler() -> MaterialParameters.Texture.Sampler {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.maxAnisotropy = 8
        return MaterialParameters.Texture.Sampler(descriptor)
    }

    private static func textured(_ name: String, tint: UIColor, sampler: MaterialParameters.Texture.Sampler,
                                 bundle: Bundle) async throws -> PhysicallyBasedMaterial {
        let color = try await texture("\(name)_color", semantic: .color, bundle: bundle)
        let normal = try await texture("\(name)_normal", semantic: .normal, bundle: bundle)
        let roughness = try await texture("\(name)_roughness", semantic: .scalar, bundle: bundle)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: tint, texture: .init(color, sampler: sampler))
        material.normal = .init(texture: .init(normal, sampler: sampler))
        material.roughness = .init(scale: 1, texture: .init(roughness, sampler: sampler))
        material.metallic = 0.0
        return material
    }

    private static func texture(_ name: String, semantic: TextureResource.Semantic, bundle: Bundle) async throws -> TextureResource {
        guard let url = bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Textures") else {
            Log.world.error("Texture \(name, privacy: .public) is missing from the bundle")
            throw MaterialError.missingTexture(name)
        }
        do {
            return try await TextureResource(contentsOf: url, withName: name, options: .init(semantic: semantic))
        } catch {
            Log.world.error("Texture \(name, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// `glow` adds a little emission in the surface's own color, standing in for interior lighting.
    static func solid(_ color: UIColor, roughness: Float, metallic: Float, clearcoat: Float = 0, glow: CGFloat = 0) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: metallic)
        if clearcoat > 0 {
            material.clearcoat = .init(floatLiteral: clearcoat)
            material.clearcoatRoughness = .init(floatLiteral: 0.05)
        }
        if glow > 0 {
            var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            material.emissiveColor = .init(color: UIColor(red: r * glow, green: g * glow, blue: b * glow, alpha: 1))
            material.emissiveIntensity = 1
        }
        return material
    }
}

enum MaterialError: LocalizedError {
    case missingTexture(String)
    case noMetal
    case noShaderLibrary

    var errorDescription: String? {
        switch self {
        case .missingTexture(let name): "The texture \(name) is missing from the app bundle."
        case .noMetal: "This device has no Metal GPU."
        case .noShaderLibrary: "The app's shaders are missing from the bundle."
        }
    }
}
