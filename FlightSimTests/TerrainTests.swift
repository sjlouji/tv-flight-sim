import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FlightSim

@Suite struct TerrainTileTests {
    let sfo = GeoPoint(latitude: 37.6189, longitude: -122.375)

    @Test func tileMathRoundTrips() throws {
        let key = TileKey.containing(sfo, zoom: 12)
        let uv = try #require(key.position(of: sfo))
        let back = key.point(u: uv.x, v: uv.y)
        #expect(abs(back.latitude - sfo.latitude) < 1e-9 && abs(back.longitude - sfo.longitude) < 1e-9)
        // A zoom 12 tile at this latitude is about 7.7 km across.
        #expect(abs(key.sizeMeters - 7_750) < 150, "\(key.sizeMeters)")
        #expect(key.children.contains(TileKey.containing(sfo, zoom: 13)))
        #expect(key.position(of: GeoPoint(latitude: 40, longitude: -120)) == nil)
    }

    /// Terrarium encoding: height = R * 256 + G + B / 256 - 32768.
    @Test func decodesTerrariumHeights() throws {
        // 1,234.5 m: 34002.5 = 132 * 256 + 210 + 128 / 256.
        let data = try png(red: 132, green: 210, blue: 128)
        let tile = try HeightTile.decode(data, key: TileKey(z: 1, x: 0, y: 0))
        #expect(abs(tile.height(u: 0.5, v: 0.5) - 1_234.5) < 0.01, "Decoded \(tile.height(u: 0.5, v: 0.5))")
        #expect(throws: TerrainError.self) { try HeightTile.decode(Data([1, 2, 3]), key: TileKey(z: 1, x: 0, y: 0)) }
    }

    @Test func flattenedAreaContainsItsInside() {
        let ring = [GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 0, longitude: 1),
                    GeoPoint(latitude: 1, longitude: 1), GeoPoint(latitude: 1, longitude: 0)]
        let area = FlattenedArea(ring: ring, elevationMeters: 10)
        #expect(area.contains(GeoPoint(latitude: 0.5, longitude: 0.5)))
        #expect(!area.contains(GeoPoint(latitude: 1.5, longitude: 0.5)))
    }

    @Test @MainActor func groundUsesTerrainOutsideTheAirportAndTheSeaBelowZero() throws {
        let airport = try Airport.load(icao: "KSFO")
        let hills = GroundModel(airport: airport, terrain: { _ in 420 })
        let seaFloor = GroundModel(airport: airport, terrain: { _ in -12 })
        let away = Navigation.destination(from: sfo, bearingDegrees: 250, distanceMeters: 15_000)
        #expect(hills.elevationMeters(latitude: away.latitude, longitude: away.longitude) == 420)
        #expect(seaFloor.elevationMeters(latitude: away.latitude, longitude: away.longitude) == 0)
        // Inside the airport the airport's own surface wins over the terrain.
        let arp = airport.reference
        #expect(abs(hills.elevationMeters(latitude: arp.latitude, longitude: arp.longitude) - arp.elevationM) < 0.01)
    }

    private func png(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        let size = HeightTile.size
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<(size * size) { bytes[i * 4] = red; bytes[i * 4 + 1] = green; bytes[i * 4 + 2] = blue }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                             space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
