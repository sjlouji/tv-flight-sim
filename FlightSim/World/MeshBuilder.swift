import RealityKit
import simd

/// Accumulates triangles for one material and turns them into a single RealityKit mesh.
/// Merging many features into one mesh keeps draw calls low on Apple TV.
struct MeshBuilder {
    private(set) var positions: [SIMD3<Float>] = []
    private(set) var normals: [SIMD3<Float>] = []
    private(set) var uvs: [SIMD2<Float>] = []
    private(set) var indices: [UInt32] = []

    var isEmpty: Bool { indices.isEmpty }

    /// Adds a flat horizontal polygon (scene x/z ring, any winding, may be concave) at height `y`.
    /// Texture coordinates repeat every `textureSize` meters.
    mutating func addPolygon(_ ring: [SIMD2<Float>], y: Float, textureSize: Float) {
        let triangles = Triangulator.triangulate(ring)
        guard !triangles.isEmpty else { return }
        let base = UInt32(positions.count)
        for point in ring {
            positions.append(SIMD3(point.x, y, point.y))
            normals.append(SIMD3(0, 1, 0))
            uvs.append(point / textureSize)
        }
        for triangle in triangles {
            // Counter-clockwise when seen from above (+y) so the face points up.
            indices.append(contentsOf: [base + UInt32(triangle.0), base + UInt32(triangle.2), base + UInt32(triangle.1)])
        }
    }

    /// Adds a flat ribbon of constant width along a polyline (scene x/z), e.g. a taxiway or a painted line.
    mutating func addRibbon(_ line: [SIMD2<Float>], width: Float, y: Float, textureSize: Float) {
        guard line.count >= 2 else { return }
        var distance: Float = 0
        let base = UInt32(positions.count)
        for (i, point) in line.enumerated() {
            let previous = line[max(i - 1, 0)]
            let next = line[min(i + 1, line.count - 1)]
            let tangent = simd_normalize(next - previous)
            var side = SIMD2(-tangent.y, tangent.x)
            // Mitre the corner so the ribbon keeps its width through bends (limited for sharp turns).
            if i > 0 && i < line.count - 1 {
                let incoming = simd_normalize(point - previous)
                let mitreScale = 1 / max(simd_dot(side, SIMD2(-incoming.y, incoming.x)), 0.5)
                side *= mitreScale
            }
            if i > 0 { distance += simd_distance(point, previous) }
            let left = point + side * (width / 2)
            let right = point - side * (width / 2)
            positions.append(SIMD3(left.x, y, left.y))
            positions.append(SIMD3(right.x, y, right.y))
            normals.append(contentsOf: [SIMD3(0, 1, 0), SIMD3(0, 1, 0)])
            uvs.append(SIMD2(0, distance / textureSize))
            uvs.append(SIMD2(width / textureSize, distance / textureSize))
        }
        for i in 0..<UInt32(line.count - 1) {
            let a = base + i * 2, b = a + 1, c = a + 2, d = a + 3
            indices.append(contentsOf: [a, b, c, b, d, c].upFacing(positions: positions))
        }
    }

    /// Adds a flat rectangle centered at `center` whose length runs along `direction` (scene x/z, unit length).
    /// Texture u runs 0...1 from the left side to the right side (looking along `direction`),
    /// v runs 0...1 from the near end to the far end, so text reads upright to someone facing `direction`.
    mutating func addRectangle(center: SIMD2<Float>, direction: SIMD2<Float>, length: Float, width: Float, y: Float) {
        let right = SIMD2(-direction.y, direction.x)
        let halfLength = direction * (length / 2)
        let halfWidth = right * (width / 2)
        let corners = [center - halfLength - halfWidth, center - halfLength + halfWidth,
                       center + halfLength + halfWidth, center + halfLength - halfWidth]
        let base = UInt32(positions.count)
        positions.append(contentsOf: corners.map { SIMD3($0.x, y, $0.y) })
        normals.append(contentsOf: Array(repeating: SIMD3(0, 1, 0), count: 4))
        uvs.append(contentsOf: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)])
        indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3].upFacing(positions: positions))
    }

    /// Adds a closed axis-aligned box (used for light fixtures).
    mutating func addBox(center: SIMD3<Float>, size: SIMD3<Float>) {
        let h = size / 2
        let faces: [(normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
        ]
        for face in faces {
            let c = center + face.normal * h
            let u = face.u * h
            let v = face.v * h
            let base = UInt32(positions.count)
            positions.append(contentsOf: [c - u - v, c + u - v, c + u + v, c - u + v])
            normals.append(contentsOf: Array(repeating: face.normal, count: 4))
            uvs.append(contentsOf: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)])
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3].facing(face.normal, positions: positions))
        }
    }

    /// Extrudes a footprint into walls and a flat roof.
    mutating func addExtrusion(_ ring: [SIMD2<Float>], height: Float, baseY: Float = 0) {
        var outline = ring
        if outline.count > 1 && outline.first == outline.last { outline.removeLast() }
        guard outline.count >= 3 else { return }
        if Triangulator.signedArea(outline) < 0 { outline.reverse() }
        for i in 0..<outline.count {
            let a = outline[i]
            let b = outline[(i + 1) % outline.count]
            let edge = b - a
            let length = simd_length(edge)
            guard length > 0.01 else { continue }
            // For a counter-clockwise ring in (x, z) the outward normal is (dz, -dx).
            let normal = simd_normalize(SIMD3(edge.y, 0, -edge.x))
            let base = UInt32(positions.count)
            positions.append(contentsOf: [SIMD3(a.x, baseY, a.y), SIMD3(b.x, baseY, b.y),
                                          SIMD3(b.x, baseY + height, b.y), SIMD3(a.x, baseY + height, a.y)])
            normals.append(contentsOf: Array(repeating: normal, count: 4))
            uvs.append(contentsOf: [SIMD2(0, 0), SIMD2(length / 4, 0), SIMD2(length / 4, height / 4), SIMD2(0, height / 4)])
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3].facing(normal, positions: positions))
        }
        addPolygon(outline, y: baseY + height, textureSize: 8)
    }

    /// Adds a closed mesh made of explicit vertices (used by the aircraft model).
    mutating func addTriangles(_ vertices: [SIMD3<Float>], normals vertexNormals: [SIMD3<Float>], indices triangleIndices: [UInt32]) {
        let base = UInt32(positions.count)
        positions.append(contentsOf: vertices)
        normals.append(contentsOf: vertexNormals)
        uvs.append(contentsOf: Array(repeating: .zero, count: vertices.count))
        indices.append(contentsOf: triangleIndices.map { $0 + base })
    }

    @MainActor
    func makeMesh(name: String) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            Log.world.error("Mesh \(name, privacy: .public) failed to build: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

extension Array where Element == UInt32 {
    /// Reorders each triangle so its geometric normal points up.
    func upFacing(positions: [SIMD3<Float>]) -> [UInt32] { facing(SIMD3(0, 1, 0), positions: positions) }

    /// Reorders each triangle so its geometric normal points along `direction`.
    func facing(_ direction: SIMD3<Float>, positions: [SIMD3<Float>]) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(count)
        for t in stride(from: 0, to: count, by: 3) {
            let a = self[t], b = self[t + 1], c = self[t + 2]
            let normal = simd_cross(positions[Int(b)] - positions[Int(a)], positions[Int(c)] - positions[Int(a)])
            result.append(contentsOf: simd_dot(normal, direction) >= 0 ? [a, b, c] : [a, c, b])
        }
        return result
    }
}

/// Ear-clipping triangulation for simple polygons (no holes).
enum Triangulator {
    /// Signed area in the (x, y) plane; positive for counter-clockwise rings.
    static func signedArea(_ ring: [SIMD2<Float>]) -> Float {
        guard ring.count >= 3 else { return 0 }
        var area: Float = 0
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }

    /// Returns index triples into `ring`. A repeated closing point is ignored.
    /// Triangles are counter-clockwise in the (x, y) plane.
    static func triangulate(_ input: [SIMD2<Float>]) -> [(Int, Int, Int)] {
        var count = input.count
        if count > 1 && input.first == input.last { count -= 1 }
        guard count >= 3 else { return [] }
        let ring = Array(input.prefix(count))
        var remaining = Array(0..<count)
        if signedArea(ring) < 0 { remaining.reverse() }

        var triangles: [(Int, Int, Int)] = []
        var guardCounter = 0
        while remaining.count > 3 && guardCounter < count * count {
            guardCounter += 1
            var clipped = false
            for i in 0..<remaining.count {
                let prev = remaining[(i + remaining.count - 1) % remaining.count]
                let current = remaining[i]
                let next = remaining[(i + 1) % remaining.count]
                let a = ring[prev], b = ring[current], c = ring[next]
                guard cross(b - a, c - b) > 1e-9 else { continue }
                let containsOther = remaining.contains { index in
                    index != prev && index != current && index != next && pointInTriangle(ring[index], a, b, c)
                }
                if containsOther { continue }
                triangles.append((prev, current, next))
                remaining.remove(at: i)
                clipped = true
                break
            }
            if !clipped {
                Log.world.warning("Triangulation stopped early on a self-intersecting polygon with \(count) points")
                break
            }
        }
        if remaining.count == 3 { triangles.append((remaining[0], remaining[1], remaining[2])) }
        return triangles
    }

    private static func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }

    private static func pointInTriangle(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        let d1 = cross(b - a, p - a), d2 = cross(c - b, p - b), d3 = cross(a - c, p - c)
        return d1 >= 0 && d2 >= 0 && d3 >= 0
    }
}

// MARK: - Aircraft shapes

/// Geometry of one lifting surface: leading edge position and chord as functions of span position.
struct Planform {
    let leadingEdge: (Float) -> SIMD3<Float>
    let chord: (Float) -> Float
    let thickness: Float
}

extension SIMD3 where Scalar == Float {
    /// Mirrors a right-side point to the left side when `side` is negative.
    func mirrored(_ side: Float) -> SIMD3<Float> { SIMD3(x * side, y, z) }
}

extension MeshBuilder {
    enum SpanAxis { case horizontal, vertical }

    /// A body of revolution along z around (centerX, y). `arc` limits it to part of the circumference
    /// (radians from +x, counter-clockwise toward +y).
    mutating func addLoft(_ sections: [(z: Float, radius: Float, y: Float)], scaleY: Float, segments: Int,
                          arc: ClosedRange<Float> = 0...(2 * .pi), centerX: Float = 0) {
        addLoft(sections.map { (z: $0.z, radius: $0.radius, y: $0.y, scaleY: scaleY) }, segments: segments, arc: arc, centerX: centerX)
    }

    /// A body of revolution whose sections may each be stretched vertically by their own `scaleY`.
    mutating func addLoft(_ sections: [(z: Float, radius: Float, y: Float, scaleY: Float)], segments: Int,
                          arc: ClosedRange<Float> = 0...(2 * .pi), centerX: Float = 0) {
        guard sections.count >= 2 else { return }
        let fullCircle = arc.upperBound - arc.lowerBound >= 2 * .pi - 0.001
        let columns = fullCircle ? segments : segments + 1
        var vertices: [SIMD3<Float>] = []
        var vertexNormals: [SIMD3<Float>] = []
        for section in sections {
            for i in 0..<columns {
                let angle = arc.lowerBound + (arc.upperBound - arc.lowerBound) * Float(i) / Float(segments)
                vertices.append(SIMD3(centerX + cos(angle) * section.radius, section.y + sin(angle) * section.scaleY * section.radius, section.z))
                vertexNormals.append(simd_normalize(SIMD3(cos(angle), sin(angle) / section.scaleY, 0)))
            }
        }
        var indices: [UInt32] = []
        for s in 0..<(sections.count - 1) {
            for i in 0..<segments {
                let next = fullCircle ? (i + 1) % segments : i + 1
                let a = UInt32(s * columns + i), b = UInt32(s * columns + next)
                let c = UInt32((s + 1) * columns + i), d = UInt32((s + 1) * columns + next)
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        addOriented(vertices, normals: vertexNormals, indices: indices, references: nil)
    }

    /// A flat disc facing -z (engine inlet).
    mutating func addDisc(center: SIMD3<Float>, radius: Float, scaleY: Float, segments: Int) {
        var vertices = [center]
        for i in 0..<segments {
            let angle = 2 * Float.pi * Float(i) / Float(segments)
            vertices.append(center + SIMD3(cos(angle) * radius, sin(angle) * radius * scaleY, 0))
        }
        let indices = (0..<segments).flatMap { [UInt32(0), UInt32(1 + $0), UInt32(1 + ($0 + 1) % segments)] }
        addOriented(vertices, normals: Array(repeating: SIMD3(0, 0, -1), count: vertices.count), indices: indices, references: nil)
    }

    /// A cylinder between two points, optionally with flat end caps.
    mutating func addCylinder(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: Float, segments: Int, capped: Bool = false) {
        let axis = simd_normalize(end - start)
        let helper: SIMD3<Float> = abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(axis, helper))
        let v = simd_cross(axis, u)
        func rim(_ i: Int) -> SIMD3<Float> {
            let angle = 2 * Float.pi * Float(i) / Float(segments)
            return u * cos(angle) + v * sin(angle)
        }
        var vertices: [SIMD3<Float>] = []
        var vertexNormals: [SIMD3<Float>] = []
        for point in [start, end] {
            for i in 0..<segments {
                vertices.append(point + rim(i) * radius)
                vertexNormals.append(rim(i))
            }
        }
        var indices: [UInt32] = []
        for i in 0..<segments {
            let a = UInt32(i), b = UInt32((i + 1) % segments), c = UInt32(segments + i), d = UInt32(segments + (i + 1) % segments)
            indices.append(contentsOf: [a, b, c, b, d, c])
        }
        addOriented(vertices, normals: vertexNormals, indices: indices, references: nil)
        guard capped else { return }
        for (point, normal) in [(start, -axis), (end, axis)] {
            let cap = [point] + (0..<segments).map { point + rim($0) * radius }
            let capIndices = (0..<segments).flatMap { [UInt32(0), UInt32(1 + $0), UInt32(1 + ($0 + 1) % segments)] }
            addOriented(cap, normals: Array(repeating: normal, count: cap.count), indices: capIndices, references: nil)
        }
    }

    /// A tapered lifting surface with a symmetric NACA 4-digit section and the chord running aft (+z).
    /// `chordRange` builds only part of the chord (0.72...1 is a flap); `offset` shifts every vertex.
    mutating func addSurface(_ planform: Planform, span: ClosedRange<Float>, chordRange: ClosedRange<Float>,
                             side: Float, axis: SpanAxis, offset: SIMD3<Float> = .zero) {
        let thicknessAxis: SIMD3<Float> = axis == .horizontal ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let samples = 10
        func section(_ s: Float) -> [SIMD3<Float>] {
            let le = planform.leadingEdge(s)
            let chord = planform.chord(s)
            var upper: [SIMD3<Float>] = []
            var lower: [SIMD3<Float>] = []
            for i in 0...samples {
                let t = Float(i) / Float(samples)
                // Cosine spacing concentrates points near the rounded leading edge.
                let x = chordRange.lowerBound + (chordRange.upperBound - chordRange.lowerBound) * (1 - cos(t * .pi)) / 2
                let half = Self.nacaHalfThickness(x, ratio: planform.thickness) * chord
                let point = le + SIMD3(0, 0, x * chord)
                upper.append((point + thicknessAxis * half).mirrored(side) + offset)
                lower.append((point - thicknessAxis * half).mirrored(side) + offset)
            }
            // Ring: upper surface front to back, then lower surface back to front (shared end points dropped).
            return upper + lower.reversed().dropFirst().dropLast()
        }
        let rootRing = section(span.lowerBound)
        let tipRing = section(span.upperBound)
        let n = rootRing.count
        let rootCenter = rootRing.reduce(.zero, +) / Float(n)
        let tipCenter = tipRing.reduce(.zero, +) / Float(n)
        let middle = (rootCenter + tipCenter) / 2
        let vertices = rootRing + tipRing
        var indices: [UInt32] = []
        var references: [SIMD3<Float>] = []
        for i in 0..<n {
            let j = (i + 1) % n
            let a = UInt32(i), b = UInt32(j), c = UInt32(n + i), d = UInt32(n + j)
            // Each quad spans root to tip, so its center minus the mid-span section center points outward.
            let outward = (rootRing[i] + rootRing[j] + tipRing[i] + tipRing[j]) / 4 - middle
            indices.append(contentsOf: [a, b, c, b, d, c])
            references.append(contentsOf: [outward, outward])
        }
        addOriented(vertices, normals: nil, indices: indices, references: references)
        for (ring, outward) in [(rootRing, rootCenter - tipCenter), (tipRing, tipCenter - rootCenter)] {
            let capIndices = (1..<(n - 1)).flatMap { [UInt32(0), UInt32($0), UInt32($0 + 1)] }
            let normal = simd_normalize(outward)
            addOriented(ring, normals: Array(repeating: normal, count: n), indices: capIndices, references: nil)
        }
    }

    /// Adds triangles whose winding is fixed to agree with a reference direction: the supplied vertex
    /// normals, or one explicit reference per triangle. With `normals: nil`, smooth normals are computed.
    mutating func addOriented(_ vertices: [SIMD3<Float>], normals: [SIMD3<Float>]?, indices: [UInt32], references: [SIMD3<Float>]?) {
        var fixed: [UInt32] = []
        fixed.reserveCapacity(indices.count)
        var computed = Array(repeating: SIMD3<Float>.zero, count: vertices.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            var (a, b, c) = (indices[t], indices[t + 1], indices[t + 2])
            let face = simd_cross(vertices[Int(b)] - vertices[Int(a)], vertices[Int(c)] - vertices[Int(a)])
            let reference = references?[t / 3] ?? (normals.map { $0[Int(a)] + $0[Int(b)] + $0[Int(c)] } ?? face)
            let flip = simd_dot(face, reference) < 0
            if flip { swap(&b, &c) }
            fixed.append(contentsOf: [a, b, c])
            for index in [a, b, c] { computed[Int(index)] += flip ? -face : face }
        }
        let finalNormals = normals ?? computed.map { simd_length($0) > 1e-9 ? simd_normalize($0) : SIMD3(0, 1, 0) }
        addTriangles(vertices, normals: finalNormals, indices: fixed)
    }
}

extension MeshBuilder {
    /// Half thickness of a symmetric NACA 4-digit airfoil at chord fraction `x`, as a fraction of chord.
    static func nacaHalfThickness(_ x: Float, ratio: Float) -> Float {
        let x = min(max(x, 0), 1)
        return 5 * ratio * (0.2969 * x.squareRoot() - 0.1260 * x - 0.3516 * x * x + 0.2843 * x * x * x - 0.1015 * x * x * x * x)
    }
}

/// A rectangular opening in the hull lining, in (distance aft of the nose, arc) coordinates.
struct HullOpening: Sendable {
    let z: ClosedRange<Float>
    let arc: ClosedRange<Float>

    /// The same opening on the left side (arcs mirror about the top, pi / 2).
    var mirrored: HullOpening { HullOpening(z: z, arc: (.pi - arc.upperBound)...(.pi - arc.lowerBound)) }
}

extension MeshBuilder {
    /// The inside of the fuselage wall between two stations, facing inward, `inset` meters inside the skin,
    /// over the arc range given (radians from +x toward +y), with rectangular openings left for windows.
    /// Facing inward means it is invisible from outside (back faces are culled) and the exterior skin is
    /// invisible from inside, so each is seen only from its own side.
    mutating func addHullLining(_ shape: AirframeShape, from start: Float, to end: Float, arc: ClosedRange<Float>, inset: Float,
                                openings: [HullOpening]) {
        // Grid lines: regular spacing plus every opening edge, so the openings are cut exactly.
        var zs = Set(stride(from: start, through: end, by: 0.25))
        var arcs = Set(stride(from: arc.lowerBound, through: arc.upperBound, by: 0.12))
        zs.formUnion([start, end])
        arcs.formUnion([arc.lowerBound, arc.upperBound])
        for opening in openings {
            zs.formUnion([opening.z.lowerBound, opening.z.upperBound].filter { $0 > start && $0 < end })
            arcs.formUnion([opening.arc.lowerBound, opening.arc.upperBound].filter { arc.contains($0) })
        }
        let zLines = zs.sorted(), arcLines = arcs.sorted()
        func point(_ z: Float, _ angle: Float) -> SIMD3<Float> { shape.hullPoint(atNoseDistance: z, angle: angle, inset: inset) }
        for i in 0..<(zLines.count - 1) {
            for j in 0..<(arcLines.count - 1) {
                let zMid = (zLines[i] + zLines[i + 1]) / 2, arcMid = (arcLines[j] + arcLines[j + 1]) / 2
                if openings.contains(where: { $0.z.contains(zMid) && $0.arc.contains(arcMid) }) { continue }
                let quad = [point(zLines[i], arcLines[j]), point(zLines[i], arcLines[j + 1]),
                            point(zLines[i + 1], arcLines[j + 1]), point(zLines[i + 1], arcLines[j])]
                let inward = simd_normalize(SIMD3(-cos(arcMid), -sin(arcMid) / shape.section(atNoseDistance: zMid).scaleY, 0))
                addOriented(quad, normals: Array(repeating: inward, count: 4), indices: [0, 1, 2, 0, 2, 3], references: nil)
            }
        }
    }

    /// An axis-aligned box seen from outside, rotated by `rotation` about `pivot` (for levers, seats, panels).
    mutating func addBox(center: SIMD3<Float>, size: SIMD3<Float>, rotation: simd_quatf, pivot: SIMD3<Float>) {
        var box = MeshBuilder()
        box.addBox(center: .zero, size: size)
        let moved = box.positions.map { pivot + rotation.act($0 + center - pivot) }
        addTriangles(moved, normals: box.normals.map { rotation.act($0) }, indices: box.indices)
    }
}
