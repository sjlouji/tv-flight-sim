import RealityKit
import UIKit
import simd

/// Builds the 3D airport from OpenStreetMap data: ground, pavements, markings, lights and buildings.
@MainActor
struct AirportScene {
    let root: Entity
    let papiLights: [PAPILight]
    /// The control tower cab (airport scene coordinates), from OpenStreetMap, for the tower camera.
    let towerCab: SIMD3<Float>?

    /// Surface heights in meters relative to the runway surface. The runway sits at 0 because that is
    /// where JSBSim puts the ground; the small steps keep coplanar surfaces from flickering.
    enum Layer {
        static let markings: Float = 0.05
        static let runway: Float = 0
        static let taxiway: Float = -0.08
        static let apron: Float = -0.16
        static let grass: Float = -0.3
    }

    static let edgeLightSpacing: Float = 60
    static let approachLightLength: Float = 900
    static let approachLightSpacing: Float = 30

    static func build(airport: Airport, materials: MaterialLibrary) throws -> AirportScene {
        let root = Entity()
        root.name = "Airport \(airport.icao)"
        let geo = airport.geoReference
        func project(_ ring: [[Double]]) -> [SIMD2<Float>] { ring.map { geo.groundPosition(latitude: $0[0], longitude: $0[1]) } }

        // The sea around the airport is the Ocean, drawn separately on the curved Earth.
        var grass = MeshBuilder()
        for ring in airport.boundary { grass.addPolygon(project(ring), y: Layer.grass, textureSize: 6) }
        root.addChild(try model("Grass", grass, materials.grass, castsShadow: false))

        var aprons = MeshBuilder()
        for apron in airport.aprons { aprons.addPolygon(project(apron.outline), y: Layer.apron, textureSize: 8) }
        root.addChild(try model("Aprons", aprons, materials.concrete, castsShadow: false))

        var taxiways = MeshBuilder()
        var taxiLines = MeshBuilder()
        for taxiway in airport.taxiways {
            let line = project(taxiway.centerline)
            taxiways.addRibbon(line, width: Float(taxiway.widthM), y: Layer.taxiway, textureSize: 10)
            taxiLines.addRibbon(line, width: 0.45, y: Layer.taxiway + Layer.markings, textureSize: 10)
        }
        root.addChild(try model("Taxiways", taxiways, materials.asphalt, castsShadow: false))
        root.addChild(try model("Taxiway centerlines", taxiLines, materials.yellowPaint, castsShadow: false))

        var runways = MeshBuilder()
        var paint = MeshBuilder()
        var whiteLights = MeshBuilder()
        var greenLights = MeshBuilder()
        let ends = airport.runwayEnds()
        for runway in airport.runways {
            runways.addRibbon(project(runway.centerline), width: Float(runway.widthM), y: Layer.runway, textureSize: 12)
        }
        var papiLights: [PAPILight] = []
        for end in ends {
            addMarkings(for: end, to: &paint)
            addRunwayLights(for: end, edges: &whiteLights, threshold: &greenLights)
            addApproachLights(for: end, to: &whiteLights)
            papiLights.append(contentsOf: makePAPI(for: end, materials: materials))
            // FAA airports (ICAO K... and P...) paint "1L"; ICAO Annex 14 airports paint "01L".
            let faaStyle = airport.icao.hasPrefix("K") || airport.icao.hasPrefix("P")
            root.addChild(try designation(for: end, dropLeadingZero: faaStyle))
        }
        root.addChild(try model("Runways", runways, materials.asphalt, castsShadow: false))
        root.addChild(try model("Runway markings", paint, materials.whitePaint, castsShadow: false))
        root.addChild(try model("Runway lights", whiteLights, materials.whiteLight, castsShadow: false))
        root.addChild(try model("Threshold lights", greenLights, materials.greenLight, castsShadow: false))
        papiLights.forEach { root.addChild($0.entity) }

        var builders: [Airport.Building.Kind: MeshBuilder] = [:]
        for building in airport.buildings {
            builders[building.kind, default: MeshBuilder()].addExtrusion(project(building.outline), height: Float(building.heightM),
                                                                       baseY: Layer.apron)
        }
        for (kind, builder) in builders {
            let material: CustomMaterial = switch kind {
            case .terminal, .controlTower: materials.terminal
            case .hangar: materials.hangar
            case .other: materials.building
            }
            root.addChild(try model("Buildings \(kind.rawValue)", builder, material, castsShadow: true))
        }
        let towerCab = airport.buildings.first { $0.kind == .controlTower }.map { tower -> SIMD3<Float> in
            let ring = project(tower.outline)
            let center = ring.reduce(SIMD2<Float>.zero, +) / Float(max(ring.count, 1))
            return SIMD3(center.x, Layer.apron + Float(tower.heightM) - 4, center.y)
        }
        if towerCab == nil { Log.world.warning("\(airport.icao, privacy: .public) has no control tower in the map data; the tower camera uses the runway viewpoint") }
        Log.world.info("Built \(airport.icao, privacy: .public): \(ends.count) runway ends, \(airport.taxiways.count) taxiways, \(airport.buildings.count) buildings")
        return AirportScene(root: root, papiLights: papiLights, towerCab: towerCab)
    }

    /// Updates the PAPI lights for a viewer at `viewer` (scene coordinates).
    func update(viewer: SIMD3<Float>) {
        papiLights.forEach { $0.update(viewer: viewer) }
    }

    // MARK: - Markings (FAA AC 150/5340-1 proportions for a precision runway)

    private static func addMarkings(for end: RunwayEnd, to paint: inout MeshBuilder) {
        let y = Layer.runway + Layer.markings
        let direction = end.direction
        let right = SIMD2(-direction.y, direction.x)
        func point(along: Float, across: Float) -> SIMD2<Float> { end.threshold + direction * along + right * across }

        // Threshold "piano keys": 1.8 m stripes, 45 m long, filling the runway width minus a 3 m margin.
        let stripeWidth: Float = 1.8
        let usable = end.width - 6
        let stripeCount = max(Int(usable / (stripeWidth * 2)) & ~1, 4)
        let pitch = usable / Float(stripeCount)
        for i in 0..<stripeCount {
            let across = -usable / 2 + pitch * (Float(i) + 0.5)
            if abs(across) < pitch * 0.75 { continue }  // central gap
            paint.addRectangle(center: point(along: 6 + 22.5, across: across), direction: direction, length: 45, width: stripeWidth, y: y)
        }

        // Centerline: 36 m stripes with 24 m gaps, from after the designation to the runway midpoint.
        let half = end.length / 2
        var along: Float = 120
        while along + 36 < half {
            paint.addRectangle(center: point(along: along + 18, across: 0), direction: direction, length: 36, width: 0.9, y: y)
            along += 60
        }

        // Side stripes along both edges, this half of the runway.
        for side: Float in [-1, 1] {
            let line = [point(along: 0, across: side * (end.width / 2 - 1.5)), point(along: half, across: side * (end.width / 2 - 1.5))]
            paint.addRibbon(line, width: 0.9, y: y, textureSize: 10)
        }

        // Aiming point: two 45 m x 9 m blocks, 300 m from the threshold.
        for side: Float in [-1, 1] {
            paint.addRectangle(center: point(along: 300 + 22.5, across: side * 13.5), direction: direction, length: 45, width: 9, y: y)
        }

        // Touchdown zone bars: groups of 3, 2, 2, 1, 1 at 150 m spacing.
        for (index, bars) in [3, 2, 2, 1, 1].enumerated() {
            let station = 150 + Float(index) * 150
            guard station != 300, station + 22.5 < half else { continue }
            for bar in 0..<bars {
                let offset = 9 + Float(bar) * 3.3
                for side: Float in [-1, 1] {
                    paint.addRectangle(center: point(along: station + 11.25, across: side * offset), direction: direction,
                                       length: 22.5, width: 1.8, y: y)
                }
            }
        }
    }

    /// The runway number and letter, painted after the threshold stripes and readable from the approach.
    private static func designation(for end: RunwayEnd, dropLeadingZero: Bool) throws -> ModelEntity {
        let length: Float = 40
        let width: Float = 18
        var builder = MeshBuilder()
        builder.addRectangle(center: end.threshold + end.direction * (60 + length / 2), direction: end.direction,
                             length: length, width: width, y: Layer.runway + Layer.markings)
        let painted = dropLeadingZero && end.designator.hasPrefix("0") ? String(end.designator.dropFirst()) : end.designator
        let image = designationImage(painted)
        let texture = try TextureResource(image: image, withName: "Designation \(end.designator)", options: .init(semantic: .color))
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(white: 0.92, alpha: 1), texture: .init(texture))
        material.roughness = 0.6
        material.metallic = 0.0
        material.opacityThreshold = 0.5
        let entity = ModelEntity(mesh: try builder.makeMesh(name: "Designation \(end.designator)"), materials: [material])
        entity.name = "Designation \(end.designator)"
        return entity
    }

    private static func designationImage(_ designator: String) -> CGImage {
        let number = String(designator.prefix { $0.isNumber })
        let letter = String(designator.drop { $0.isNumber })
        let size = CGSize(width: 256, height: 568)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let font = UIFont.systemFont(ofSize: 250, weight: .bold).withCondensedWidth()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            // Number at the far end (top of the image), letter nearer the threshold.
            let numberText = NSAttributedString(string: number, attributes: attributes)
            let numberSize = numberText.size()
            numberText.draw(at: CGPoint(x: (size.width - numberSize.width) / 2, y: 0))
            if !letter.isEmpty {
                let letterText = NSAttributedString(string: letter, attributes: attributes)
                let letterSize = letterText.size()
                letterText.draw(at: CGPoint(x: (size.width - letterSize.width) / 2, y: size.height - letterSize.height))
            }
        }
        guard let cgImage = image.cgImage else {
            preconditionFailure("UIGraphicsImageRenderer always produces a CGImage-backed image")
        }
        return cgImage
    }

    // MARK: - Lights

    private static func addRunwayLights(for end: RunwayEnd, edges: inout MeshBuilder, threshold: inout MeshBuilder) {
        let direction = end.direction
        let right = SIMD2(-direction.y, direction.x)
        let fixture = SIMD3<Float>(0.45, 0.35, 0.45)
        var along: Float = 0
        while along <= end.length / 2 {
            for side: Float in [-1, 1] {
                let p = end.threshold + direction * along + right * (side * (end.width / 2 + 1))
                edges.addBox(center: SIMD3(p.x, fixture.y / 2, p.y), size: fixture)
            }
            along += edgeLightSpacing
        }
        let count = Int(end.width / 3)
        for i in 0...count {
            let p = end.threshold - direction * 2 + right * (-end.width / 2 + Float(i) * end.width / Float(count))
            threshold.addBox(center: SIMD3(p.x, fixture.y / 2, p.y), size: fixture)
        }
    }

    /// A simplified ALSF-2 approach lighting system: a five-light bar every 30 m out to 900 m,
    /// with a wide crossbar at 300 m. At San Francisco these stand on piers over the bay.
    private static func addApproachLights(for end: RunwayEnd, to lights: inout MeshBuilder) {
        let direction = end.direction
        let right = SIMD2(-direction.y, direction.x)
        let fixture = SIMD3<Float>(0.5, 0.5, 0.5)
        var distance = approachLightSpacing
        while distance <= approachLightLength {
            let center = end.threshold - direction * distance
            let height: Float = 1 + distance * 0.003
            let barHalfWidth: Float = distance == 300 ? 15 : 2
            let step: Float = distance == 300 ? 1.5 : 1
            var across = -barHalfWidth
            while across <= barHalfWidth + 0.01 {
                let p = center + right * across
                lights.addBox(center: SIMD3(p.x, height, p.y), size: fixture)
                across += step
            }
            distance += approachLightSpacing
        }
    }

    private static func makePAPI(for end: RunwayEnd, materials: MaterialLibrary) -> [PAPILight] {
        let direction = end.direction
        let right = SIMD2(-direction.y, direction.x)
        // Four units on the left, 300 m past the threshold. The unit nearest the runway switches at the highest angle.
        let angles: [Float] = [3.5, 3.1667, 2.8333, 2.5]
        return angles.enumerated().map { index, angle in
            let p = end.threshold + direction * 300 - right * (end.width / 2 + 15 + Float(index) * 9)
            return PAPILight(position: SIMD3(p.x, 0.6, p.y), transitionAngleDegrees: angle,
                             white: materials.whiteLight, red: materials.redLight)
        }
    }

    private static func model(_ name: String, _ builder: MeshBuilder, _ material: any Material, castsShadow: Bool) throws -> Entity {
        guard !builder.isEmpty else { return Entity() }
        let entity = ModelEntity(mesh: try builder.makeMesh(name: name), materials: [material])
        entity.name = name
        if !castsShadow { entity.components.set(DynamicLightShadowComponent(castsShadow: false)) }
        return entity
    }
}

/// One precision approach path indicator unit: white above its transition angle, red below.
@MainActor
final class PAPILight {
    let entity: ModelEntity
    private let position: SIMD3<Float>
    private let transitionAngleDegrees: Float
    private let white: UnlitMaterial
    private let red: UnlitMaterial
    private var showingWhite = false

    init(position: SIMD3<Float>, transitionAngleDegrees: Float, white: UnlitMaterial, red: UnlitMaterial) {
        self.position = position
        self.transitionAngleDegrees = transitionAngleDegrees
        self.white = white
        self.red = red
        entity = ModelEntity(mesh: .generateBox(width: 1.4, height: 1.0, depth: 1.4), materials: [red])
        entity.position = position
        entity.name = "PAPI \(transitionAngleDegrees)"
    }

    nonisolated static func showsWhite(viewer: SIMD3<Float>, light: SIMD3<Float>, transitionAngleDegrees: Float) -> Bool {
        let horizontal = simd_length(SIMD2(viewer.x - light.x, viewer.z - light.z))
        let elevation = atan2(viewer.y - light.y, max(horizontal, 0.001)) * 180 / .pi
        return elevation > transitionAngleDegrees
    }

    func update(viewer: SIMD3<Float>) {
        let white = Self.showsWhite(viewer: viewer, light: position, transitionAngleDegrees: transitionAngleDegrees)
        guard white != showingWhite else { return }
        showingWhite = white
        entity.model?.materials = [white ? self.white : red]
    }
}

private extension UIFont {
    func withCondensedWidth() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitCondensed) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
