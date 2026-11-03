import RealityKit
import UIKit
import simd

/// Where a passenger cabin's floor, seats and windows go, worked out from the fuselage. The 737's cabin
/// (25 rows of 3 + 3 at 79 cm) is the reference; widebodies get a second aisle and a center block,
/// narrow fuselages a single seat each side. Nil for aircraft without a passenger cabin.
struct CabinLayout: Sendable {
    let floorY: Float
    /// Nose distances of the cabin's front and back walls.
    let start: Float
    let end: Float
    let firstRow: Float
    let rowPitch: Float
    let rows: Int
    /// Seat centers across the cabin, left to right.
    let seats: [Float]
    /// Window band on the right side (radians from +x toward +y) and along the cabin.
    let windowArc: ClosedRange<Float>
    let windowStart: Float
    let windowEnd: Float
    let windowPitch: Float
    let windowWidth: Float
    /// Nose distance of the row the passenger camera sits in: just ahead of the wing.
    let passengerRow: Float
    /// Whether an adult can stand in the aisle (the cabin crew view).
    let standingRoom: Bool

    static let seatWidth: Float = 0.45
    static let seatedEyeHeight: Float = 0.98

    init?(profile: AircraftProfile, shape: AirframeShape) {
        guard profile.hasCabin else { return nil }
        let r = shape.radius
        let wide = r >= 1.5
        floorY = shape.centerY - (wide ? 0.29 : 0.5) * r
        start = shape.eyeDistance + 1.4
        end = shape.length * (profile.airframe == .jetAirliner ? 0.815 : 0.68)
        firstRow = start + (wide ? 2.35 : 0.6)
        rowPitch = wide ? 0.79 : (profile.airframe == .businessJet ? 1.5 : 0.76)
        rows = max(Int((end - 1.4 - firstRow) / rowPitch) + 1, 1)
        // Half the cabin's width at armrest height.
        let armrest = floorY + 0.5 - shape.centerY
        let halfWidth = r * (1 - min(pow(armrest / (r * shape.oval), 2), 0.95)).squareRoot()
        let width = Self.seatWidth
        var seats: [Float] = []
        if r > 2.5 {
            // Two aisles: three seats by each wall, a center block between the aisles.
            let aisle = r * 0.38
            for index in 0..<3 { seats += [-(aisle + 0.25 + width * (Float(index) + 0.5)), aisle + 0.25 + width * (Float(index) + 0.5)] }
            let center = max(Int(2 * (aisle - 0.25) / width), 1)
            for index in 0..<center { seats.append((Float(index) - Float(center - 1) / 2) * width) }
        } else {
            let perSide = Int((halfWidth - 0.5) / width).clamped(1, 3)
            for index in 0..<perSide { seats += [-(0.47 + width * Float(index)), 0.47 + width * Float(index)] }
        }
        self.seats = seats.sorted()
        let eyeArc = shape.arc(atHeight: floorY + Self.seatedEyeHeight - shape.centerY, noseDistance: (start + end) / 2)
        windowArc = (eyeArc - 0.1)...(eyeArc + 0.1)
        windowStart = start + (wide ? 1.75 : 0.4)
        windowEnd = end - 0.6
        windowPitch = wide ? 0.51 : rowPitch
        windowWidth = wide ? 0.25 : 0.32
        let wingRow = profile.airframe == .jetAirliner ? shape.length * 0.42 : shape.length * 0.36
        passengerRow = wingRow.clamped(firstRow, firstRow + Float(rows - 1) * rowPitch)
        standingRoom = r >= 1.3
    }
}

/// The passenger cabin: lined walls with a window opening at every exterior window, carpet, overhead bins,
/// light strips, rows of seats, and passengers in about two thirds of them.
@MainActor
final class Cabin {
    let root = Entity()
    /// Cabin crew standing in the forward galley, looking aft down the aisle.
    let crewEye: SIMD3<Float>?
    /// A passenger in a left window seat just ahead of the wing, looking out.
    let passengerEye: SIMD3<Float>

    init(materials: MaterialLibrary, layout: CabinLayout, shape: AirframeShape) throws {
        root.name = "Cabin"
        let floorY = layout.floorY
        let z = shape.z
        let outermost = layout.seats.map(abs).max() ?? 0.5

        // Walls and ceiling, with an opening for every passenger window on both sides.
        let floorArc = shape.arc(atHeight: floorY - shape.centerY, noseDistance: (layout.start + layout.end) / 2)
        var openings: [HullOpening] = []
        var windowCenter = layout.windowStart + layout.windowWidth
        while windowCenter < layout.windowEnd - layout.windowWidth {
            let opening = HullOpening(z: (windowCenter - layout.windowWidth / 2)...(windowCenter + layout.windowWidth / 2), arc: layout.windowArc)
            openings += [opening, opening.mirrored]
            windowCenter += layout.windowPitch
        }
        var lining = MeshBuilder()
        lining.addHullLining(shape, from: layout.start, to: layout.end, arc: floorArc...(.pi - floorArc), inset: 0.1, openings: openings)
        root.addChild(try AircraftModel.part("Cabin lining", lining, materials.cabinWall))

        let middle = (layout.start + layout.end) / 2
        var carpet = MeshBuilder()
        carpet.addRectangle(center: SIMD2(0, z(middle)), direction: SIMD2(0, 1), length: layout.end - layout.start,
                            width: 2 * (outermost + 0.3), y: floorY)
        root.addChild(try AircraftModel.part("Cabin floor", carpet, materials.carpet))

        // Overhead bins along both sides with light strips above them; galley bulkheads front and back.
        var bins = MeshBuilder()
        var strips = MeshBuilder()
        let cabinLength = layout.end - layout.start - 3
        let ceiling = shape.centerY + shape.radius * shape.oval * 0.75
        if shape.radius >= 1.5 {
            for side: Float in [-1, 1] {
                bins.addBox(center: SIMD3(side * (outermost - 0.12), ceiling - 0.4, z(middle)), size: SIMD3(0.5, 0.36, cabinLength))
                strips.addBox(center: SIMD3(side * (outermost - 0.42), ceiling - 0.08, z(middle)), size: SIMD3(0.06, 0.02, cabinLength))
            }
        } else {
            strips.addBox(center: SIMD3(0, ceiling + 0.05, z(middle)), size: SIMD3(0.12, 0.02, cabinLength))
        }
        let wallHeight = ceiling - floorY + 0.4
        bins.addBox(center: SIMD3(outermost * 0.6, floorY + wallHeight / 2, z(layout.firstRow - 0.65)), size: SIMD3(outermost * 0.9, wallHeight, 0.08))
        bins.addBox(center: SIMD3(-outermost * 0.6, floorY + wallHeight / 2, z(layout.firstRow - 0.65)), size: SIMD3(outermost * 0.9, wallHeight, 0.08))
        bins.addBox(center: SIMD3(0, floorY + wallHeight / 2, z(layout.end - 0.3)), size: SIMD3(2 * outermost + 0.6, wallHeight, 0.08))
        root.addChild(try AircraftModel.part("Overhead bins", bins, materials.cabinCeiling))
        root.addChild(try AircraftModel.part("Cabin lights", strips, materials.cabinLight))

        // The passenger camera's seat: the left window seat in the row nearest the wing.
        let passengerRowIndex = Int(((layout.passengerRow - layout.firstRow) / layout.rowPitch).rounded())
        let viewerSeatX = layout.seats.first ?? -0.5

        // Seats and passengers (fixed seed, so the same people fly every time).
        var seats = MeshBuilder()
        var headrests = MeshBuilder()
        var heads = MeshBuilder()
        var hair = MeshBuilder()
        var clothes = [MeshBuilder(), MeshBuilder(), MeshBuilder()]
        var rng = SeededGenerator(seed: 0x0CAB1)
        let recline = simd_quatf(angle: 0.15, axis: SIMD3(1, 0, 0))
        for row in 0..<layout.rows {
            let seatZ = z(layout.firstRow + Float(row) * layout.rowPitch)
            for x in layout.seats {
                seats.addBox(center: SIMD3(x, floorY + 0.42, seatZ), size: SIMD3(0.44, 0.1, 0.46))
                seats.addBox(center: SIMD3(x, floorY + 0.21, seatZ), size: SIMD3(0.3, 0.32, 0.3))
                let pivot = SIMD3(x, floorY + 0.46, seatZ + 0.22)
                seats.addBox(center: SIMD3(x, floorY + 0.84, seatZ + 0.22), size: SIMD3(0.44, 0.76, 0.09), rotation: recline, pivot: pivot)
                headrests.addBox(center: SIMD3(x, floorY + 1.12, seatZ + 0.17), size: SIMD3(0.36, 0.18, 0.1), rotation: recline, pivot: pivot)
                let isViewerSeat = x == viewerSeatX && row == passengerRowIndex
                guard !isViewerSeat, Double.random(in: 0...1, using: &rng) < 0.65 else { continue }
                let lean = Float.random(in: -0.04...0.04, using: &rng)
                clothes[Int.random(in: 0..<3, using: &rng)].addBox(center: SIMD3(x + lean, floorY + 0.74, seatZ + 0.06), size: SIMD3(0.36, 0.5, 0.22))
                heads.addEllipsoid(center: SIMD3(x + lean, floorY + 1.14, seatZ + 0.02), radii: SIMD3(0.075, 0.1, 0.09))
                hair.addEllipsoid(center: SIMD3(x + lean, floorY + 1.18, seatZ + 0.04), radii: SIMD3(0.08, 0.075, 0.09))
            }
        }
        root.addChild(try AircraftModel.part("Passenger seats", seats, materials.seat))
        root.addChild(try AircraftModel.part("Headrest covers", headrests, materials.cabinCeiling))
        root.addChild(try AircraftModel.part("Passenger faces", heads, materials.skin))
        root.addChild(try AircraftModel.part("Passenger hair", hair, materials.hair))
        let clothingColors = [UIColor(red: 0.15, green: 0.2, blue: 0.35, alpha: 1), UIColor(red: 0.45, green: 0.12, blue: 0.12, alpha: 1),
                              UIColor(white: 0.75, alpha: 1)]
        for (index, builder) in clothes.enumerated() where !builder.isEmpty {
            let material = MaterialLibrary.solid(clothingColors[index], roughness: 0.9, metallic: 0, glow: 0.12)
            root.addChild(try AircraftModel.part("Passenger clothes \(index)", builder, material))
        }
        root.components.set(DynamicLightShadowComponent(castsShadow: false))

        // Standing in the aisle just aft of the forward galley, below the ceiling.
        crewEye = layout.standingRoom ? SIMD3(0, min(floorY + 1.62, ceiling - 0.12), z(layout.firstRow - 0.4)) : nil
        // Seated eye height, leaning slightly toward the window.
        passengerEye = SIMD3(viewerSeatX + 0.19, floorY + CabinLayout.seatedEyeHeight,
                             z(layout.firstRow + Float(passengerRowIndex) * layout.rowPitch - 0.02))
    }
}

extension MeshBuilder {
    /// A closed ellipsoid (heads, hair), built as a stack of elliptical sections.
    mutating func addEllipsoid(center: SIMD3<Float>, radii: SIMD3<Float>) {
        let stacks = 7
        let sections = (0...stacks).map { index -> (z: Float, radius: Float, y: Float) in
            let t = -1 + 2 * Float(index) / Float(stacks)
            return (z: center.z + t * radii.z, radius: max(radii.x * (1 - t * t).squareRoot(), 0.002), y: center.y)
        }
        addLoft(sections, scaleY: radii.y / radii.x, segments: 10, centerX: center.x)
    }
}
