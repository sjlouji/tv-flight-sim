import CoreGraphics
import Foundation
import ImageIO
import Observation

/// A Web Mercator map tile (the slippy-map scheme the terrain service uses).
struct TileKey: Hashable, Sendable, CustomStringConvertible {
    let z: Int
    let x: Int
    let y: Int

    var description: String { "\(z)/\(x)/\(y)" }

    static func containing(_ point: GeoPoint, zoom z: Int) -> TileKey {
        let n = Double(1 << z)
        let latitude = point.latitude.clamped(-85.0511, 85.0511) * .pi / 180
        let x = Int(((point.longitude + 180) / 360 * n).rounded(.down))
        let y = Int(((1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2 * n).rounded(.down))
        return TileKey(z: z, x: x.clamped(0, Int(n) - 1), y: y.clamped(0, Int(n) - 1))
    }

    /// Longitude of a fractional tile x at this zoom.
    func longitude(_ fx: Double) -> Double { fx / Double(1 << z) * 360 - 180 }
    /// Latitude of a fractional tile y at this zoom.
    func latitude(_ fy: Double) -> Double { atan(sinh(.pi * (1 - 2 * fy / Double(1 << z)))) * 180 / .pi }

    /// The point at (u, v) across the tile, both 0 ... 1, u east and v south.
    func point(u: Double, v: Double) -> GeoPoint {
        GeoPoint(latitude: latitude(Double(y) + v), longitude: longitude(Double(x) + u))
    }

    var center: GeoPoint { point(u: 0.5, v: 0.5) }

    /// Approximate width of the tile on the ground, meters.
    var sizeMeters: Double {
        2 * .pi * WGS84.semiMajorAxis * cos(center.latitude * .pi / 180) / Double(1 << z)
    }

    var children: [TileKey] {
        [TileKey(z: z + 1, x: 2 * x, y: 2 * y), TileKey(z: z + 1, x: 2 * x + 1, y: 2 * y),
         TileKey(z: z + 1, x: 2 * x, y: 2 * y + 1), TileKey(z: z + 1, x: 2 * x + 1, y: 2 * y + 1)]
    }

    /// Where a point falls inside this tile, (u, v) in 0 ... 1, or nil if outside.
    func position(of point: GeoPoint) -> SIMD2<Double>? {
        let n = Double(1 << z)
        let latitude = point.latitude.clamped(-85.0511, 85.0511) * .pi / 180
        let fx = (point.longitude + 180) / 360 * n - Double(x)
        let fy = (1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2 * n - Double(y)
        guard (0...1).contains(fx), (0...1).contains(fy) else { return nil }
        return SIMD2(fx, fy)
    }
}

/// One terrain tile's heights: 256 x 256 samples, meters above sea level (negative is sea floor).
struct HeightTile: Sendable {
    static let size = 256
    let key: TileKey
    let heights: [Float]

    /// Bilinear height at (u, v) across the tile (pixel centers sit at (i + 0.5) / 256).
    func height(u: Double, v: Double) -> Double {
        let px = (u * Double(Self.size) - 0.5).clamped(0, Double(Self.size - 1))
        let py = (v * Double(Self.size) - 0.5).clamped(0, Double(Self.size - 1))
        let x0 = Int(px), y0 = Int(py)
        let x1 = min(x0 + 1, Self.size - 1), y1 = min(y0 + 1, Self.size - 1)
        let tx = px - Double(x0), ty = py - Double(y0)
        func at(_ x: Int, _ y: Int) -> Double { Double(heights[y * Self.size + x]) }
        let top = at(x0, y0) * (1 - tx) + at(x1, y0) * tx
        let bottom = at(x0, y1) * (1 - tx) + at(x1, y1) * tx
        return top * (1 - ty) + bottom * ty
    }

    /// Decodes a Terrarium-encoded PNG: height = R * 256 + G + B / 256 - 32768 meters.
    static func decode(_ data: Data, key: TileKey) throws -> HeightTile {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == size, image.height == size else {
            throw TerrainError.undecodable(key)
        }
        // Read the stored bytes directly. Drawing into a context would color-manage them, and these are
        // encoded numbers, not colors.
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              image.bitsPerComponent == 8, image.bitsPerPixel == 24 || image.bitsPerPixel == 32 else {
            throw TerrainError.undecodable(key)
        }
        let stride = image.bitsPerPixel / 8
        let alpha = image.alphaInfo
        let alphaFirst = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
        let littleEndian = image.byteOrderInfo == .order32Little
        // Channel offsets for red, green and blue within a pixel.
        let offsets: (Int, Int, Int) = switch (stride, alphaFirst, littleEndian) {
        case (4, true, false): (1, 2, 3)     // ARGB
        case (4, true, true): (2, 1, 0)      // BGRA
        case (4, false, true): (3, 2, 1)     // ABGR
        default: (0, 1, 2)                   // RGB or RGBA
        }
        var heights = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            let row = bytes + y * image.bytesPerRow
            for x in 0..<size {
                let pixel = row + x * stride
                let r = Float(pixel[offsets.0]), g = Float(pixel[offsets.1]), b = Float(pixel[offsets.2])
                heights[y * size + x] = r * 256 + g + b / 256 - 32_768
            }
        }
        return HeightTile(key: key, heights: heights)
    }
}

enum TerrainError: LocalizedError {
    case undecodable(TileKey)
    case http(TileKey, Int)

    var errorDescription: String? {
        switch self {
        case .undecodable(let key): "Terrain tile \(key) could not be decoded."
        case .http(let key, let status): "Terrain tile \(key) failed to download (HTTP \(status))."
        }
    }
}

/// Downloads terrain tiles from the AWS Terrain Tiles open dataset (Mapzen "Terrarium" encoding; sources
/// include SRTM, GMTED2010 and ETOPO1) and keeps them in the Caches folder. Concurrent requests for the
/// same tile share one download.
actor TerrainTileLoader {
    static let baseURL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium"
    private let session: URLSession
    private let cacheDirectory: URL
    private var inFlight: [TileKey: Task<HeightTile, Error>] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
        cacheDirectory = URL.cachesDirectory.appending(path: "Terrain", directoryHint: .isDirectory)
    }

    func tile(_ key: TileKey) async throws -> HeightTile {
        if let existing = inFlight[key] { return try await existing.value }
        let task = Task { [session, cacheDirectory] in
            try await Self.load(key, session: session, cacheDirectory: cacheDirectory)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    @concurrent
    private static func load(_ key: TileKey, session: URLSession, cacheDirectory: URL) async throws -> HeightTile {
        let file = cacheDirectory.appending(path: "\(key.z)/\(key.x)/\(key.y).png")
        if let cached = try? Data(contentsOf: file), let tile = try? HeightTile.decode(cached, key: key) {
            return tile
        }
        guard let url = URL(string: "\(baseURL)/\(key.z)/\(key.x)/\(key.y).png") else { throw TerrainError.http(key, -1) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            Log.world.error("Terrain tile \(key.description, privacy: .public) download failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            Log.world.error("Terrain tile \(key.description, privacy: .public) returned HTTP \(status)")
            throw TerrainError.http(key, status)
        }
        let tile = try HeightTile.decode(data, key: key)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        } catch {
            // The tile is still used; only the offline copy is missing, and the log says so.
            Log.world.error("Terrain tile \(key.description, privacy: .public) could not be cached: \(error.localizedDescription, privacy: .public)")
        }
        return tile
    }
}

/// An area where the terrain is replaced by a flat surface (an airport), so runways sit on level ground.
struct FlattenedArea: Sendable {
    /// Ring of (latitude, longitude) points.
    let ring: [GeoPoint]
    let elevationMeters: Double
    private let bounds: (min: GeoPoint, max: GeoPoint)

    init(ring: [GeoPoint], elevationMeters: Double) {
        self.ring = ring
        self.elevationMeters = elevationMeters
        bounds = (GeoPoint(latitude: ring.map(\.latitude).min() ?? 0, longitude: ring.map(\.longitude).min() ?? 0),
                  GeoPoint(latitude: ring.map(\.latitude).max() ?? 0, longitude: ring.map(\.longitude).max() ?? 0))
    }

    func contains(_ point: GeoPoint) -> Bool {
        guard point.latitude >= bounds.min.latitude, point.latitude <= bounds.max.latitude,
              point.longitude >= bounds.min.longitude, point.longitude <= bounds.max.longitude else { return false }
        return GroundModel.contains(ring.map { SIMD2($0.longitude, $0.latitude) }, SIMD2(point.longitude, point.latitude))
    }
}

/// The terrain heights the app has, for physics and for building meshes. Tiles are kept up to a memory budget,
/// least recently used first out.
@MainActor
@Observable
final class TerrainHeights {
    /// Shown on screen when terrain can't be downloaded, so a flat world is never a silent surprise.
    private(set) var problem: String?
    @ObservationIgnored let loader = TerrainTileLoader()
    @ObservationIgnored private(set) var tiles: [TileKey: HeightTile] = [:]
    @ObservationIgnored private var lastUse: [TileKey: Int] = [:]
    @ObservationIgnored private var useCounter = 0
    @ObservationIgnored private var requested: Set<TileKey> = []
    @ObservationIgnored private var failures = 0
    @ObservationIgnored var flattened: [FlattenedArea] = []

    static let maxTiles = 260
    /// Physics uses this zoom (about 19 m per sample at mid latitudes).
    static let groundZoom = 12

    /// Loads one tile (if it isn't here or on its way). `onReady` runs when it arrives.
    func request(_ key: TileKey, onReady: (@MainActor (HeightTile) -> Void)? = nil) {
        if let tile = tiles[key] {
            touch(key)
            onReady?(tile)
            return
        }
        guard !requested.contains(key) else { return }
        requested.insert(key)
        Task {
            defer { requested.remove(key) }
            do {
                let tile = try await loader.tile(key)
                store(tile)
                failures = 0
                if problem != nil { problem = nil }
                onReady?(tile)
            } catch {
                failures += 1
                if failures >= 3 { problem = "Terrain is unavailable (\(error.localizedDescription)). The ground outside airports is shown at sea level." }
            }
        }
    }

    /// Waits for the ground tile under a point (used before a flight starts).
    func load(around point: GeoPoint) async throws {
        let key = TileKey.containing(point, zoom: Self.groundZoom)
        if tiles[key] != nil { return }
        let tile = try await loader.tile(key)
        store(tile)
    }

    func tile(_ key: TileKey) -> HeightTile? {
        guard let tile = tiles[key] else { return nil }
        touch(key)
        return tile
    }

    /// Ground height at a point: a flattened airport if inside one, otherwise the finest terrain tile here.
    /// Nil when no terrain covers the point yet.
    func elevation(at point: GeoPoint) -> Double? {
        if let area = flattened.first(where: { $0.contains(point) }) { return area.elevationMeters }
        return rawElevation(at: point)
    }

    /// The terrain height ignoring flattened areas.
    func rawElevation(at point: GeoPoint) -> Double? {
        for zoom in stride(from: Self.groundZoom + 1, through: 5, by: -1) {
            let key = TileKey.containing(point, zoom: zoom)
            if let tile = tiles[key], let uv = key.position(of: point) {
                return tile.height(u: uv.x, v: uv.y)
            }
        }
        return nil
    }

    private func store(_ tile: HeightTile) {
        tiles[tile.key] = tile
        touch(tile.key)
        guard tiles.count > Self.maxTiles else { return }
        let oldest = lastUse.sorted { $0.value < $1.value }.prefix(tiles.count - Self.maxTiles).map(\.key)
        for key in oldest {
            tiles[key] = nil
            lastUse[key] = nil
        }
    }

    private func touch(_ key: TileKey) {
        useCounter += 1
        lastUse[key] = useCounter
    }
}
