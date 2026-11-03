import Metal
import RealityKit
import simd

/// Draws the terrain as a quadtree of map tiles: fine near the camera, coarse far away.
///
/// Each tile is built in its own Earth-anchored frame (tangent at its center, at sea level) and placed
/// relative to the aircraft every frame, like the airport, so it is exact and never jitters. A tile only
/// splits into its four children once all four are built, so the ground never has holes; skirts along the
/// edges hide the small steps between neighbors of different detail.
@MainActor
final class TerrainRenderer {
    let root = Entity()
    private let heights: TerrainHeights
    private let lightingRoot: Entity
    private var material: CustomMaterial
    private var meshes: [TileKey: (entity: ModelEntity, frame: LocalFrame)] = [:]
    private var building: Set<TileKey> = []
    private var buildQueue: [TileKey] = []
    private var visible: Set<TileKey> = []
    private var lastSelection = -Double.infinity
    private var clock = 0.0
    private var buildsInFlight = 0

    static let rootZoom = 6
    static let maxZoom = 13
    /// A tile splits when the camera is closer than this many tile widths.
    static let splitDistance = 1.8
    nonisolated static let gridSize = 32
    static let maxMeshes = 320
    /// Vertex work runs in the background; at most this many tiles at once.
    static let maxConcurrentBuilds = 4

    init(heights: TerrainHeights, shaders: MTLLibrary, sky: TextureResource, hazeDensity: Float, lightingRoot: Entity) throws {
        self.heights = heights
        self.lightingRoot = lightingRoot
        material = try CustomMaterial(surfaceShader: .init(named: "terrainSurface", in: shaders), lightingModel: .lit)
        material.custom.texture = .init(sky)
        material.custom.value = SIMD4(hazeDensity, 0, 0, 0)
        root.name = "Terrain"
    }

    /// Whether the coarse tiles around a point are built, so the flight can start without bare sea.
    func isReady(around point: GeoPoint) -> Bool { meshes[TileKey.containing(point, zoom: Self.rootZoom)] != nil }

    /// Places the visible tiles for this frame, and every quarter second chooses which tiles should be visible.
    func update(aircraftFrame: LocalFrame, camera: SIMD3<Float>, deltaTime dt: Double) {
        clock += dt
        if clock - lastSelection > 0.25 {
            lastSelection = clock
            select(cameraECEF: aircraftFrame.ecefPoint(scene: SIMD3<Double>(camera)), aircraftFrame: aircraftFrame)
        }
        while buildsInFlight < Self.maxConcurrentBuilds, !buildQueue.isEmpty {
            build(buildQueue.removeFirst())
        }
        for key in visible {
            guard let mesh = meshes[key] else { continue }
            mesh.entity.transform = aircraftFrame.transform(from: mesh.frame)
        }
    }

    private func select(cameraECEF: SIMD3<Double>, aircraftFrame: LocalFrame) {
        let here = GeoPoint(latitude: aircraftFrame.latitude, longitude: aircraftFrame.longitude)
        let center = TileKey.containing(here, zoom: Self.rootZoom)
        let n = 1 << Self.rootZoom
        var roots: [TileKey] = []
        for dy in -1...1 {
            for dx in -1...1 {
                let y = center.y + dy
                guard y >= 0 && y < n else { continue }
                roots.append(TileKey(z: Self.rootZoom, x: (center.x + dx + n) % n, y: y))
            }
        }
        var wanted: [TileKey] = []
        func visit(_ key: TileKey) {
            ensure(key)
            let mid = key.center
            let ground = heights.rawElevation(at: mid).map { max($0, 0) } ?? 0
            let distance = simd_distance(cameraECEF, WGS84.ecef(latitude: mid.latitude, longitude: mid.longitude, height: ground))
            if key.z < Self.maxZoom && distance < key.sizeMeters * Self.splitDistance {
                let children = key.children
                children.forEach(ensure)
                if children.allSatisfy({ meshes[$0] != nil }) {
                    children.forEach(visit)
                    return
                }
            }
            if meshes[key] != nil { wanted.append(key) }
        }
        roots.forEach(visit)
        let next = Set(wanted)
        for key in visible.subtracting(next) { meshes[key]?.entity.isEnabled = false }
        for key in next.subtracting(visible) { meshes[key]?.entity.isEnabled = true }
        visible = next
        // Physics needs the fine tile under the aircraft even when the view doesn't.
        heights.request(TileKey.containing(here, zoom: TerrainHeights.groundZoom))
        evict()
    }

    /// Makes sure a tile's heights are coming and its mesh will be built.
    private func ensure(_ key: TileKey) {
        guard meshes[key] == nil, !building.contains(key) else { return }
        building.insert(key)
        heights.request(key) { [weak self] _ in self?.buildQueue.append(key) }
    }

    /// Computes the tile's vertices in the background, then makes the mesh (a quick copy) on the main thread.
    private func build(_ key: TileKey) {
        guard let tile = heights.tile(key) else {
            building.remove(key)
            return
        }
        let frame = LocalFrame(latitude: key.center.latitude, longitude: key.center.longitude, height: 0)
        let flattened = heights.flattened
        buildsInFlight += 1
        Task {
            let geometry = await Self.geometry(tile, frame: frame, flattened: flattened)
            buildsInFlight -= 1
            building.remove(key)
            finish(key, frame: frame, geometry: geometry)
        }
    }

    private func finish(_ key: TileKey, frame: LocalFrame, geometry: (vertices: [Vertex], indices: [UInt32])) {
        do {
            let mesh = try Self.lowLevelMesh(geometry.vertices, indices: geometry.indices, name: "Terrain \(key)")
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.name = "Terrain \(key)"
            entity.isEnabled = false
            entity.components.set(DynamicLightShadowComponent(castsShadow: false))
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lightingRoot))
            root.addChild(entity)
            meshes[key] = (entity, frame)
        } catch {
            Log.world.error("Terrain mesh \(key.description, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops built tiles nobody is looking at, oldest zoom levels last (they're the cheapest to keep).
    private func evict() {
        guard meshes.count > Self.maxMeshes else { return }
        let removable = meshes.keys.filter { !visible.contains($0) }.sorted { $0.z > $1.z }
        for key in removable.prefix(meshes.count - Self.maxMeshes) {
            meshes[key]?.entity.removeFromParent()
            meshes[key] = nil
        }
    }

    // MARK: - Mesh

    struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        /// Earth-anchored meters (east-ish, north) for the shader's noise, continuous across tiles.
        var anchor: SIMD2<Float>
        /// Height above sea level (m) and latitude (degrees), for the shader's land cover.
        var info: SIMD2<Float>
    }

    @concurrent
    private static func geometry(_ tile: HeightTile, frame: LocalFrame, flattened: [FlattenedArea]) async -> (vertices: [Vertex], indices: [UInt32]) {
        let n = gridSize
        let key = tile.key
        var vertices: [Vertex] = []
        vertices.reserveCapacity((n + 1) * (n + 1) + 4 * (n + 1))
        for j in 0...n {
            for i in 0...n {
                let u = Double(i) / Double(n), v = Double(j) / Double(n)
                let point = key.point(u: u, v: v)
                var height = tile.height(u: u, v: v)
                if let area = flattened.first(where: { $0.contains(point) }) {
                    // Just under the airport's own surfaces, so they draw on top.
                    height = area.elevationMeters - 2
                } else if height < 1 {
                    // The sea floor and the shoreline sit under the ocean surface, clear of it.
                    height = min(height, 0) - 8
                }
                let local = frame.scenePoint(ecef: WGS84.ecef(latitude: point.latitude, longitude: point.longitude, height: height))
                let anchor = SIMD2(Float(point.longitude * 111_320 * cos(point.latitude * .pi / 180)), Float(point.latitude * 110_540))
                vertices.append(Vertex(position: SIMD3<Float>(local), normal: SIMD3(0, 1, 0), anchor: anchor,
                                       info: SIMD2(Float(height), Float(point.latitude))))
            }
        }
        // Normals from the neighbors in the grid.
        for j in 0...n {
            for i in 0...n {
                let left = vertices[j * (n + 1) + max(i - 1, 0)].position, right = vertices[j * (n + 1) + min(i + 1, n)].position
                let up = vertices[max(j - 1, 0) * (n + 1) + i].position, down = vertices[min(j + 1, n) * (n + 1) + i].position
                let normal = simd_cross(down - up, right - left)
                vertices[j * (n + 1) + i].normal = simd_length(normal) > 0 ? simd_normalize(normal) : SIMD3(0, 1, 0)
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(n * n * 6 + 4 * n * 6)
        for j in 0..<n {
            for i in 0..<n {
                let a = UInt32(j * (n + 1) + i), b = a + 1, c = a + UInt32(n + 1), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        // Skirts: each edge hangs a strip straight down, hiding gaps against coarser neighbors.
        let skirtDepth = Float(max(30, key.sizeMeters * 0.012))
        let edges: [[Int]] = [
            (0...n).map { $0 },                                  // north edge
            (0...n).map { n * (n + 1) + $0 },                    // south edge
            (0...n).map { $0 * (n + 1) },                        // west edge
            (0...n).map { $0 * (n + 1) + n },                    // east edge
        ]
        for edge in edges {
            let base = UInt32(vertices.count)
            for index in edge {
                var skirt = vertices[index]
                let ecef = frame.ecefPoint(scene: SIMD3<Double>(skirt.position))
                let down = -SIMD3<Float>(frame.rotation * simd_normalize(ecef))
                skirt.position += down * skirtDepth
                vertices.append(skirt)
            }
            for k in 0..<(edge.count - 1) {
                let top0 = UInt32(edge[k]), top1 = UInt32(edge[k + 1])
                let bottom0 = base + UInt32(k), bottom1 = base + UInt32(k + 1)
                // Both windings, so the skirt shows from either side.
                indices += [top0, bottom0, top1, top1, bottom0, bottom1, top0, top1, bottom0, top1, bottom1, bottom0]
            }
        }
        return (vertices, indices)
    }

    private static func lowLevelMesh(_ vertices: [Vertex], indices: [UInt32], name: String) throws -> MeshResource {
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.position)!),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.normal)!),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.anchor)!),
            .init(semantic: .uv1, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.info)!),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)]
        descriptor.vertexCapacity = vertices.count
        descriptor.indexCapacity = indices.count
        descriptor.indexType = .uint32
        let mesh = try LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let buffer = raw.bindMemory(to: Vertex.self)
            for i in vertices.indices { buffer[i] = vertices[i] }
        }
        mesh.withUnsafeMutableIndices { raw in
            let buffer = raw.bindMemory(to: UInt32.self)
            for i in indices.indices { buffer[i] = indices[i] }
        }
        let low = vertices.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1.position) }
        let high = vertices.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1.position) }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indices.count, topology: .triangle, bounds: BoundingBox(min: low, max: high))])
        do {
            return try MeshResource(from: mesh)
        } catch {
            Log.world.error("Terrain mesh \(name, privacy: .public) failed to build: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
