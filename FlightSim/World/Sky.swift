import CoreGraphics
import Foundation
import Metal
import RealityKit
import UIKit
import simd

/// What the sky is drawn for.
struct SkyConditions: Equatable, Sendable {
    /// Unit directions toward the sun and moon, scene axes.
    var sun: SIMD3<Double>
    var moon: SIMD3<Double>
    var moonIllumination: Double
    /// Observer altitude above sea level, meters.
    var altitude: Double
    /// Aerosol (Mie) density relative to a clear day; hazier weather is larger.
    var haze: Double
    /// The lowest continuous cloud deck, if any.
    var deck: CloudDeck?

    struct CloudDeck: Equatable, Sendable {
        var baseMeters: Double
        var topMeters: Double
        var coverage: Double
        /// Fraction of daylight that gets through.
        var transmission: Double
    }
}

/// Single-scattering model of Earth's atmosphere (Rayleigh and Mie), the approach of Nishita et al.,
/// including the Earth's shadow, so twilight glows naturally. Directions below the horizon see the
/// sunlit surface through the haze, which is why the lower half of the sky never looks like sky.
enum AtmosphereModel {
    static let groundRadius = 6_360_000.0
    static let topRadius = 6_420_000.0
    static let rayleighScattering = SIMD3<Double>(5.8e-6, 13.5e-6, 33.1e-6)
    static let rayleighScaleHeight = 8_000.0
    static let mieScattering = 21e-6
    static let mieScaleHeight = 1_200.0
    static let mieAsymmetry = 0.76
    /// Ozone absorbs in the green and orange (Chappuis band), which keeps twilight skies blue rather than teal.
    static let ozoneAbsorption = SIMD3<Double>(0.650e-6, 1.881e-6, 0.085e-6)
    static let ozonePeakAltitude = 25_000.0
    static let ozoneHalfWidth = 15_000.0
    static let sunIntensity = 20.0
    /// Moonlight relative to sunlight, raised well above the real 2.5e-6 so night is dark but readable.
    static let moonlightRatio = 2e-4
    static let oceanAlbedo = 0.06
    static let cloudTopAlbedo = 0.8
    static let viewSamples = 12
    static let lightSamples = 6

    /// Scattered light reaching the observer along `direction`, linear HDR.
    static func radiance(_ direction: SIMD3<Double>, _ c: SkyConditions) -> SIMD3<Double> {
        var color = scattered(direction, light: c.sun, intensity: sunIntensity, c)
        if c.sun.y < 0.1 && c.moon.y > -0.05 {
            color += scattered(direction, light: c.moon, intensity: sunIntensity * moonlightRatio * c.moonIllumination, c)
        }
        // Faint airglow and starlight keep the night sky from being pure black.
        color += SIMD3(0.0012, 0.0016, 0.0032)
        if let deck = c.deck { color = applyDeck(deck, direction, color, c) }
        return color
    }

    /// Sunlight color and strength arriving at the observer (direct beam), 1 = unattenuated.
    static func transmittance(toward light: SIMD3<Double>, altitude: Double) -> SIMD3<Double> {
        let origin = SIMD3(0, groundRadius + max(altitude, 0), 0)
        guard let depth = opticalDepthToTop(from: origin, toward: light, haze: 1) else { return .zero }
        return exp(-extinction(depth, mie: mieScattering))
    }

    /// Extinction for optical depths (Rayleigh, Mie, ozone) along a path.
    private static func extinction(_ depth: SIMD3<Double>, mie: Double) -> SIMD3<Double> {
        rayleighScattering * depth.x + SIMD3(repeating: mie * 1.1 * depth.y) + ozoneAbsorption * depth.z
    }

    /// Relative densities (Rayleigh, Mie, ozone) at a height.
    private static func densities(_ height: Double) -> SIMD3<Double> {
        SIMD3(exp(-height / rayleighScaleHeight), exp(-height / mieScaleHeight),
              max(0, 1 - abs(height - ozonePeakAltitude) / ozoneHalfWidth))
    }

    private static func scattered(_ direction: SIMD3<Double>, light: SIMD3<Double>, intensity: Double,
                                  _ c: SkyConditions) -> SIMD3<Double> {
        let origin = SIMD3(0, groundRadius + max(c.altitude, 1), 0)
        guard let top = intersect(origin, direction, radius: topRadius)?.far else { return .zero }
        let ground = intersect(origin, direction, radius: groundRadius).flatMap { $0.near > 0 ? $0.near : nil }
        let length = ground ?? top
        let step = length / Double(viewSamples)
        let mie = mieScattering * c.haze
        var optical = SIMD3<Double>.zero
        var sumRayleigh = SIMD3<Double>.zero, sumMie = SIMD3<Double>.zero
        for i in 0..<viewSamples {
            let point = origin + direction * (step * (Double(i) + 0.5))
            let d = densities(simd_length(point) - groundRadius) * step
            optical += d
            guard let lightDepth = opticalDepthToTop(from: point, toward: light, haze: c.haze) else { continue }
            let attenuation = exp(-extinction(optical + lightDepth, mie: mie))
            sumRayleigh += attenuation * d.x
            sumMie += attenuation * d.y
        }
        let mu = simd_dot(direction, light)
        let phaseRayleigh = 3 / (16 * Double.pi) * (1 + mu * mu)
        let g = mieAsymmetry
        let phaseMie = 3 / (8 * Double.pi) * ((1 - g * g) * (1 + mu * mu)) / ((2 + g * g) * pow(1 + g * g - 2 * g * mu, 1.5))
        var color = intensity * (sumRayleigh * rayleighScattering * phaseRayleigh + sumMie * mie * phaseMie)
        if let ground {
            // The surface below: sunlit sea, seen through the air in between.
            let point = origin + direction * ground
            let normal = simd_normalize(point)
            let viewTransmittance = exp(-extinction(optical, mie: mie))
            if let lightDepth = opticalDepthToTop(from: point, toward: light, haze: c.haze) {
                let sunAtGround = exp(-extinction(lightDepth, mie: mie))
                let irradiance = intensity * sunAtGround * max(simd_dot(normal, light), 0)
                color += viewTransmittance * irradiance * oceanAlbedo / .pi
            }
        }
        return color
    }

    /// Below an overcast the sky is a gray ceiling; above one, the bright cloud tops fill the view downward.
    private static func applyDeck(_ deck: SkyConditions.CloudDeck, _ direction: SIMD3<Double>, _ clear: SIMD3<Double>,
                                  _ c: SkyConditions) -> SIMD3<Double> {
        let sunAtObserver = transmittance(toward: c.sun, altitude: c.altitude)
        let daylight = sunIntensity * simd_reduce_add(sunAtObserver) / 3 * max(c.sun.y, 0) + 0.02
        if c.altitude < deck.baseMeters {
            let ceiling = SIMD3(0.92, 0.95, 1.0) * daylight * deck.transmission * 0.12
            let blend = deck.coverage * smoothstep(-0.02, 0.06, direction.y)
            return clear * (1 - blend * 0.7) * (1 - blend) + ceiling * blend + clear * blend * 0.3 * deck.transmission
        }
        if c.altitude > deck.topMeters {
            let tops = SIMD3(1.0, 0.99, 0.97) * daylight * cloudTopAlbedo / .pi + clear * 0.3
            let blend = deck.coverage * smoothstep(0.0, -0.06, direction.y)
            return clear * (1 - blend) + tops * blend
        }
        // Inside the deck: uniform gray.
        return SIMD3(repeating: daylight * deck.transmission * 0.1)
    }

    /// Optical depth (Rayleigh, Mie, ozone) from `point` to the top of the atmosphere, or nil if the Earth blocks the light.
    private static func opticalDepthToTop(from point: SIMD3<Double>, toward light: SIMD3<Double>, haze: Double) -> SIMD3<Double>? {
        if let hit = intersect(point, light, radius: groundRadius), hit.near > 0 { return nil }
        guard let top = intersect(point, light, radius: topRadius)?.far else { return nil }
        let step = top / Double(lightSamples)
        var depth = SIMD3<Double>.zero
        for i in 0..<lightSamples {
            depth += densities(simd_length(point + light * (step * (Double(i) + 0.5))) - groundRadius) * step
        }
        return depth
    }

    /// Ray and sphere (centered on the Earth's center) intersection distances.
    private static func intersect(_ origin: SIMD3<Double>, _ direction: SIMD3<Double>, radius: Double) -> (near: Double, far: Double)? {
        let b = simd_dot(origin, direction)
        let c = simd_dot(origin, origin) - radius * radius
        let discriminant = b * b - c
        guard discriminant >= 0 else { return nil }
        let root = discriminant.squareRoot()
        let far = -b + root
        guard far > 0 else { return nil }
        return (-b - root, far)
    }

    /// Eyes adapt to a darker sky; so does this exposure, up to 25 times, so twilight reads as deep blue and
    /// moonlit night shows shapes instead of black. The same scaling lights the scenery (image-based lighting).
    static func exposure(_ c: SkyConditions) -> Double {
        let zenith = radiance(SIMD3(0, 1, 0), c)
        let luminance = 0.2126 * zenith.x + 0.7152 * zenith.y + 0.0722 * zenith.z
        return (0.12 / max(luminance, 1e-6)).clamped(1, 25)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = ((x - edge0) / (edge1 - edge0)).clamped(0, 1)
        return t * t * (3 - 2 * t)
    }

    /// The whole sky as an equirectangular HDR image (row 0 at the zenith, the center column looking north,
    /// east to the right), the layout the shaders and image-based lighting use.
    @concurrent
    static func panorama(width: Int, height: Int, conditions: SkyConditions) async throws -> CGImage {
        let exposure = Float(exposure(conditions))
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for row in 0..<height {
            let theta = (Double(row) + 0.5) / Double(height) * .pi
            for column in 0..<width {
                let azimuth = ((Double(column) + 0.5) / Double(width) - 0.5) * 2 * .pi
                let direction = SIMD3(sin(theta) * sin(azimuth), cos(theta), -sin(theta) * cos(azimuth))
                let color = radiance(direction, conditions)
                let index = (row * width + column) * 4
                pixels[index] = Float(color.x) * exposure
                pixels[index + 1] = Float(color.y) * exposure
                pixels[index + 2] = Float(color.z) * exposure
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let provider = CGDataProvider(data: Data(bytes: pixels, count: pixels.count * 4) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                      | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            Log.world.error("Sky panorama image could not be created")
            throw SkyError.imageCreation
        }
        return image
    }
}

/// The sky for one flight: dome, sun, moon and stars, the sunlight, and image-based lighting, all following
/// the real sun and moon for the aircraft's position and the simulation clock.
@MainActor
final class Sky {
    let root = Entity()
    /// The sky panorama other materials sample for reflections and haze (updated in place).
    let texture: TextureResource
    private(set) var sunDirection = SIMD3<Float>(0, 1, 0)
    /// Sun color at the observer (after the atmosphere), for tinting water glint and clouds.
    private(set) var sunColor = SIMD3<Float>(1, 1, 1)
    /// 1 when the sun is up and not hidden by an overcast, 0 when not.
    private(set) var sunVisibility: Float = 1
    /// 0 in daylight ... 1 in full night.
    private(set) var nightFactor: Float = 0

    let light = DirectionalLight()
    private let dome: ModelEntity
    private let sunDisc: ModelEntity
    private let moonDisc: ModelEntity
    private let stars: ModelEntity
    private let lightingRoot: Entity
    private let weather: WeatherSettings
    private let fieldElevation: Double
    private var conditions: SkyConditions?
    private var rendering = false
    private var lastRender = -Double.infinity
    private var clock = 0.0
    private var environment: EnvironmentResource?
    private var blend: (from: EnvironmentResource, to: EnvironmentResource, progress: Float)?
    private var moonPhaseShown = -1.0
    private var glowShown: [ObjectIdentifier: (value: SIMD4<Float>, tint: SIMD3<Float>)] = [:]

    static let panoramaSize = (width: 512, height: 256)
    static let domeRadius: Float = 2_000_000
    static let bodyDistance: Float = 1_500_000
    static let starDistance: Float = 1_700_000
    static let sunlightLux: Float = 10_000
    static let moonlightLux: Float = 160
    static let iblBlendSeconds: Float = 2

    /// Builds the sky for the start conditions. `lightingRoot` receives the image-based light.
    static func build(lightingRoot: Entity, shaders: MTLLibrary, weather: WeatherSettings, fieldElevationMeters: Double,
                      date: Date, latitude: Double, longitude: Double, altitudeMeters: Double) async throws -> Sky {
        let conditions = makeConditions(weather: weather, fieldElevation: fieldElevationMeters, date: date,
                                        latitude: latitude, longitude: longitude, altitude: altitudeMeters)
        let image = try await AtmosphereModel.panorama(width: panoramaSize.width, height: panoramaSize.height, conditions: conditions)
        let texture = try await TextureResource(image: image, withName: "Sky", options: .init(semantic: .hdrColor))
        let environment = try await EnvironmentResource(equirectangular: image, withName: "Sky light")
        let sky = try Sky(texture: texture, environment: environment, shaders: shaders, lightingRoot: lightingRoot,
                          weather: weather, fieldElevation: fieldElevationMeters)
        sky.conditions = conditions
        sky.update(date: date, latitude: latitude, longitude: longitude, altitudeMeters: altitudeMeters, deltaTime: 0)
        return sky
    }

    private init(texture: TextureResource, environment: EnvironmentResource, shaders: MTLLibrary, lightingRoot: Entity,
                 weather: WeatherSettings, fieldElevation: Double) throws {
        self.texture = texture
        self.environment = environment
        self.lightingRoot = lightingRoot
        self.weather = weather
        self.fieldElevation = fieldElevation
        root.name = "Sky"

        var domeMaterial = try CustomMaterial(surfaceShader: .init(named: "skyDomeSurface", in: shaders), lightingModel: .unlit)
        domeMaterial.custom.texture = .init(texture)
        domeMaterial.faceCulling = .front
        dome = ModelEntity(mesh: .generateSphere(radius: Self.domeRadius), materials: [domeMaterial])
        dome.name = "Sky dome"
        dome.components.set(DynamicLightShadowComponent(castsShadow: false))

        var sunMaterial = try CustomMaterial(surfaceShader: .init(named: "glowSurface", in: shaders), lightingModel: .unlit)
        sunMaterial.baseColor = .init(tint: .white, texture: .init(try Self.glowTexture()))
        sunMaterial.blending = .transparent(opacity: .init(floatLiteral: 1))
        // The disc is 0.53 degrees across; the quad is larger to hold the glow around it.
        let sunSize = Self.bodyDistance * tan(0.53 * .pi / 180) * 5
        sunDisc = ModelEntity(mesh: .generatePlane(width: sunSize, height: sunSize), materials: [sunMaterial])
        sunDisc.components.set(BillboardComponent())

        var moonMaterial = try CustomMaterial(surfaceShader: .init(named: "glowSurface", in: shaders), lightingModel: .unlit)
        moonMaterial.blending = .transparent(opacity: .init(floatLiteral: 1))
        let moonSize = Self.bodyDistance * tan(0.52 * .pi / 180) * 1.6
        moonDisc = ModelEntity(mesh: .generatePlane(width: moonSize, height: moonSize), materials: [moonMaterial])
        moonDisc.components.set(BillboardComponent())

        var starMaterial = try CustomMaterial(surfaceShader: .init(named: "starSurface", in: shaders),
                                              geometryModifier: .init(named: "billboardGeometry", in: shaders), lightingModel: .unlit)
        starMaterial.blending = .transparent(opacity: .init(floatLiteral: 1))
        stars = ModelEntity(mesh: try Self.starMesh(), materials: [starMaterial])
        stars.name = "Stars"

        for entity in [sunDisc, moonDisc, stars] { entity.components.set(DynamicLightShadowComponent(castsShadow: false)) }
        root.addChild(dome)
        root.addChild(stars)
        root.addChild(moonDisc)
        root.addChild(sunDisc)

        light.light.intensity = Self.sunlightLux
        light.shadow = DirectionalLightComponent.Shadow(shadowProjection: .automatic(maximumDistance: 300), depthBias: 2)
        root.addChild(light)
        lightingRoot.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.4))
    }

    /// Moves the sun, moon and stars, keeps the sky centered on `camera`, and re-renders the panorama when
    /// the sun or the observer's altitude has changed enough to notice.
    func update(date: Date, latitude: Double, longitude: Double, altitudeMeters: Double, deltaTime dt: Double,
                camera: SIMD3<Float> = .zero) {
        clock += dt
        let next = Self.makeConditions(weather: weather, fieldElevation: fieldElevation, date: date,
                                       latitude: latitude, longitude: longitude, altitude: altitudeMeters)
        let sun = SIMD3<Float>(next.sun)
        let moon = SIMD3<Float>(next.moon)
        sunDirection = sun
        root.position = camera
        light.look(at: .zero, from: (sun.y > -0.035 ? sun : moon) * 100, relativeTo: root)

        let transmittance = SIMD3<Float>(AtmosphereModel.transmittance(toward: next.sun, altitude: altitudeMeters))
        let peak = max(transmittance.max(), 1e-4)
        sunColor = transmittance / peak
        let deck = next.deck
        let belowDeck = deck.map { altitudeMeters < $0.baseMeters } ?? false
        let deckLight = Float(belowDeck ? (deck?.transmission ?? 1) : 1)
        let sunUp = smoothstep(-0.02, 0.05, sun.y)
        sunVisibility = sunUp * (belowDeck ? 0 : 1)
        nightFactor = smoothstep(-0.05, -0.22, sun.y) * (belowDeck ? 0.1 : 1)

        // Sun (or moon) light on the scenery, dimmed by the atmosphere and any overcast.
        let moonUp = smoothstep(-0.02, 0.1, moon.y)
        let sunLux = Self.sunlightLux * simd_reduce_add(transmittance) / 3 * sunUp * deckLight
        let moonLux = Self.moonlightLux * Float(next.moonIllumination) * moonUp * deckLight * (1 - sunUp)
        light.light.intensity = max(sunLux + moonLux, 1)
        light.light.color = sunUp > 0.01 ? UIColor(red: CGFloat(sunColor.x), green: CGFloat(sunColor.y), blue: CGFloat(sunColor.z), alpha: 1)
                                         : UIColor(red: 0.7, green: 0.78, blue: 1, alpha: 1)

        sunDisc.position = sun * Self.bodyDistance
        moonDisc.position = moon * Self.bodyDistance
        setGlow(sunDisc, tint: sunColor, intensity: 40 * sunVisibility + 0.01, opacity: sunVisibility)
        setGlow(moonDisc, tint: SIMD3(1, 0.98, 0.92), intensity: 1.2, opacity: moonUp * (belowDeck ? 0 : 1) * (1 - 0.85 * sunUp))
        if abs(next.moonIllumination - moonPhaseShown) > 0.02 { updateMoonTexture(illumination: next.moonIllumination) }
        stars.orientation = Astronomy.celestialToScene(date: date, latitude: latitude, longitude: longitude)
        let starBrightness = nightFactor * min(1 + Float(altitudeMeters) / 8_000, 1.6)
        stars.isEnabled = starBrightness > 0.001
        if var material = stars.model?.materials.first as? CustomMaterial, abs(material.custom.value.x - starBrightness) > 0.005 {
            material.custom.value = SIMD4(starBrightness, 0, 0, 0)
            stars.model?.materials = [material]
        }
        advanceLightingBlend(Float(dt))

        guard !rendering, clock - lastRender > 1.5, let current = conditions, Self.differs(current, next) else { return }
        rendering = true
        lastRender = clock
        conditions = next
        Task { await self.render(next) }
    }

    private func render(_ next: SkyConditions) async {
        defer { rendering = false }
        do {
            let image = try await AtmosphereModel.panorama(width: Self.panoramaSize.width, height: Self.panoramaSize.height, conditions: next)
            try texture.replace(withImage: image, options: .init(semantic: .hdrColor))
            let newEnvironment = try await EnvironmentResource(equirectangular: image, withName: "Sky light")
            if let environment { blend = (environment, newEnvironment, 0) }
            environment = newEnvironment
        } catch {
            Log.world.error("Sky update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func advanceLightingBlend(_ dt: Float) {
        guard var current = blend else { return }
        current.progress = min(current.progress + dt / Self.iblBlendSeconds, 1)
        let source: ImageBasedLightComponent.Source = current.progress >= 1 ? .single(current.to) : .blend(current.from, current.to, current.progress)
        lightingRoot.components.set(ImageBasedLightComponent(source: source, intensityExponent: 0.4))
        blend = current.progress >= 1 ? nil : current
    }

    /// Updates a sun or moon disc material, only when something changed visibly (material writes aren't free).
    private func setGlow(_ entity: ModelEntity, tint: SIMD3<Float>, intensity: Float, opacity: Float) {
        entity.isEnabled = opacity > 0.001
        guard var material = entity.model?.materials.first as? CustomMaterial else { return }
        let value = SIMD4(intensity, opacity, 0, 0)
        let shown = glowShown[ObjectIdentifier(entity)]
        if let shown, simd_length(shown.value - value) < 0.01, simd_length(shown.tint - tint) < 0.01 { return }
        glowShown[ObjectIdentifier(entity)] = (value, tint)
        material.baseColor.tint = UIColor(red: CGFloat(tint.x), green: CGFloat(tint.y), blue: CGFloat(tint.z), alpha: 1)
        material.custom.value = value
        entity.model?.materials = [material]
    }

    private func updateMoonTexture(illumination: Double) {
        guard var material = moonDisc.model?.materials.first as? CustomMaterial else { return }
        do {
            material.baseColor = .init(tint: .white, texture: .init(try Self.moonTexture(illumination: illumination)))
            moonDisc.model?.materials = [material]
            moonPhaseShown = illumination
        } catch {
            Log.world.error("Moon texture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Conditions

    private static func makeConditions(weather: WeatherSettings, fieldElevation: Double, date: Date, latitude: Double,
                                       longitude: Double, altitude: Double) -> SkyConditions {
        let sun = Astronomy.sun(at: date, latitude: latitude, longitude: longitude).sceneDirection
        let moon = Astronomy.moon(at: date, latitude: latitude, longitude: longitude).sceneDirection
        let preset = weather.preset
        let deck = preset.layers.first { $0.kind == .stratus }.map { layer in
            SkyConditions.CloudDeck(baseMeters: fieldElevation + layer.baseFeet.feetToMeters,
                                    topMeters: fieldElevation + layer.topFeet.feetToMeters,
                                    coverage: layer.coverage, transmission: preset.daylightTransmission)
        }
        return SkyConditions(sun: SIMD3<Double>(sun), moon: SIMD3<Double>(moon),
                             moonIllumination: Astronomy.moonIllumination(at: date), altitude: altitude,
                             haze: (40_000 / preset.visibilityMeters).clamped(0.7, 6), deck: deck)
    }

    /// Re-render when the sun moves 0.3 degree, or the observer climbs or descends noticeably.
    private static func differs(_ a: SkyConditions, _ b: SkyConditions) -> Bool {
        let sunMoved = acos(min(simd_dot(a.sun, b.sun), 1)) > 0.3 * .pi / 180
        let moonMoved = acos(min(simd_dot(a.moon, b.moon), 1)) > 1 * .pi / 180
        let altitudeChanged = abs(a.altitude - b.altitude) > max(300, a.altitude * 0.08)
        let deckCrossed = a.deck.map { ($0.baseMeters > a.altitude) != ($0.baseMeters > b.altitude)
            || ($0.topMeters > a.altitude) != ($0.topMeters > b.altitude) } ?? false
        return sunMoved || moonMoved || altitudeChanged || deckCrossed
    }

    // MARK: - Meshes and textures

    /// The bright stars plus 1,400 fainter ones (fixed seed), as billboard quads in the celestial frame.
    private static func starMesh() throws -> MeshResource {
        var rng = SeededGenerator(seed: 0x5743_4152)
        var stars: [(direction: SIMD3<Float>, magnitude: Double)] = StarCatalog.bright.map { star in
            let ra = star.rightAscensionHours * 15 * .pi / 180
            let dec = star.declinationDegrees * .pi / 180
            return (SIMD3<Float>(Float(cos(dec) * cos(ra)), Float(cos(dec) * sin(ra)), Float(sin(dec))), star.magnitude)
        }
        for _ in 0..<1_400 {
            let z = Double.random(in: -1...1, using: &rng)
            let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
            let r = (1 - z * z).squareRoot()
            // Faint stars far outnumber bright ones; pick magnitudes 2.5 ... 5.5 weighted toward faint.
            let magnitude = 5.5 - 3 * pow(Double.random(in: 0...1, using: &rng), 2.5)
            stars.append((SIMD3<Float>(Float(r * cos(angle)), Float(r * sin(angle)), Float(z)), magnitude))
        }
        var positions: [SIMD3<Float>] = [], uv0: [SIMD2<Float>] = [], uv1: [SIMD2<Float>] = [], indices: [UInt32] = []
        for star in stars {
            let brightness = Float(pow(10, -0.4 * (star.magnitude - 1)).clamped(0.03, 1.6))
            // Larger than true point size so stars survive a TV's resolution.
            let size = starDistance * tan(Float(0.05 + 0.09 * min(brightness, 1)) * .pi / 180)
            let base = UInt32(positions.count)
            for corner in [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)] {
                positions.append(star.direction * starDistance)
                uv0.append(corner)
                uv1.append(SIMD2(size, brightness))
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        return try billboardMesh(name: "Stars", positions: positions, uv0: uv0, uv1: uv1, indices: indices)
    }

    /// One corner of a billboard quad: the quad's center, which corner (uv0, 0...1), and (half size, a per-quad
    /// value) in uv1 for the shaders.
    struct BillboardVertex {
        var position: SIMD3<Float>
        var uv0: SIMD2<Float>
        var uv1: SIMD2<Float>
    }

    /// Builds a billboard mesh with LowLevelMesh, which (unlike MeshDescriptor before tvOS 27) carries a second
    /// UV set. The corners are listed counter-clockwise as the camera sees them, so the quads are front-facing.
    static func billboardMesh(name: String, positions: [SIMD3<Float>], uv0: [SIMD2<Float>], uv1: [SIMD2<Float>],
                              indices: [UInt32]) throws -> MeshResource {
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<BillboardVertex>.offset(of: \.position)!),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<BillboardVertex>.offset(of: \.uv0)!),
            .init(semantic: .uv1, format: .float2, offset: MemoryLayout<BillboardVertex>.offset(of: \.uv1)!),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<BillboardVertex>.stride)]
        descriptor.vertexCapacity = positions.count
        descriptor.indexCapacity = indices.count
        descriptor.indexType = .uint32
        do {
            let mesh = try LowLevelMesh(descriptor: descriptor)
            mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
                let vertices = raw.bindMemory(to: BillboardVertex.self)
                for i in positions.indices { vertices[i] = BillboardVertex(position: positions[i], uv0: uv0[i], uv1: uv1[i]) }
            }
            mesh.withUnsafeMutableIndices { raw in
                let buffer = raw.bindMemory(to: UInt32.self)
                for i in indices.indices { buffer[i] = indices[i] }
            }
            // Bounds include the largest quad so culling never drops a billboard that reaches into view.
            let pad = SIMD3<Float>(repeating: uv1.map(\.x).max() ?? 0)
            let low = positions.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) } - pad
            let high = positions.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) } + pad
            mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indices.count, topology: .triangle,
                                                     bounds: BoundingBox(min: low, max: high))])
            return try MeshResource(from: mesh)
        } catch {
            Log.world.error("Billboard mesh \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// A white disc with a soft glow around it.
    private static func glowTexture() throws -> TextureResource {
        let image = try drawImage(size: 256) { context, size in
            let center = CGPoint(x: size / 2, y: size / 2)
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: [UIColor.white.cgColor, UIColor.white.cgColor,
                                                     UIColor(white: 1, alpha: 0.35).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray,
                                            locations: [0, 0.2, 0.24, 1]) else { throw SkyError.imageCreation }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size / 2, options: [])
        }
        return try TextureResource(image: image, withName: "Sun glow", options: .init(semantic: .color))
    }

    /// The moon's disc lit to its phase (bright limb to the right).
    private static func moonTexture(illumination: Double) throws -> TextureResource {
        let image = try drawImage(size: 128) { context, size in
            let radius = size * 0.42
            let center = CGPoint(x: size / 2, y: size / 2)
            context.setFillColor(UIColor(white: 0.07, alpha: 0.9).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            // The terminator is an ellipse whose half-width goes from +r (new) through 0 (quarter) to -r (full).
            let terminator = radius * CGFloat(1 - 2 * illumination)
            let lit = CGMutablePath()
            lit.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            lit.addEllipse(in: CGRect(x: center.x - abs(terminator), y: center.y - radius, width: abs(terminator) * 2, height: radius * 2))
            context.saveGState()
            context.addPath(lit)
            context.clip(using: illumination > 0.5 ? .winding : .evenOdd)
            context.setFillColor(UIColor(white: 0.95, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.restoreGState()
        }
        return try TextureResource(image: image, withName: "Moon", options: .init(semantic: .color))
    }

    static func drawImage(size: Int, _ draw: (CGContext, CGFloat) throws -> Void) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SkyError.imageCreation
        }
        try draw(context, CGFloat(size))
        guard let image = context.makeImage() else { throw SkyError.imageCreation }
        return image
    }
}

/// A small deterministic random number generator (SplitMix64) so procedural content is the same every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = ((x - edge0) / (edge1 - edge0)).clamped(0, 1)
    return t * t * (3 - 2 * t)
}

enum SkyError: LocalizedError {
    case imageCreation

    var errorDescription: String? {
        switch self {
        case .imageCreation: "The sky image could not be created."
        }
    }
}
