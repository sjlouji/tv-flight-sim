import CoreGraphics
import RealityKit
import UIKit
import simd

/// The glass displays in the cockpit, each drawn by InstrumentDrawing.
enum InstrumentDisplay: CaseIterable, Sendable {
    case pfd, nd, upperEICAS, lowerEICAS, mcp

    var pixelSize: (width: Int, height: Int) {
        switch self {
        case .mcp: (1024, 80)
        default: (512, 512)
        }
    }
}

/// The cockpit, built in model coordinates (meters around the center of gravity, nose toward -z) around
/// the pilot's eye so it sits inside the hull. Three layouts: an airliner flight deck (also used by the
/// C-130 and the Global 5000), a light-aircraft panel (Cessna 172, Twin Otter) and a tandem fighter
/// cockpit (F-4). Levers, yokes or stick and lights follow the simulation; the display units show the
/// live instruments.
@MainActor
final class Cockpit {
    enum Style {
        case airliner, light, fighter

        init(_ profile: AircraftProfile) {
            switch profile.airframe {
            case .jetAirliner, .businessJet: self = .airliner
            // The C-130 has an airliner-sized flight deck; the Twin Otter a light-aircraft panel.
            case .highWingTurboprop: self = profile.fuselageRadius > 1.5 ? .airliner : .light
            case .lightSingle: self = .light
            case .fighter: self = .fighter
            }
        }
    }

    let root = Entity()
    let style: Style
    let captainEye: SIMD3<Float>
    /// The right seat, or the F-4's back seat.
    let firstOfficerEye: SIMD3<Float>
    /// The displays this cockpit has, so only those are drawn.
    private(set) var displays: Set<InstrumentDisplay> = []

    private let shape: AirframeShape
    private let materials: MaterialLibrary
    private var textures: [InstrumentDisplay: TextureResource] = [:]
    private var thrustLevers: [Entity] = []
    private var speedbrakeLever: Entity?
    private var flapLever: Entity?
    private var gearLever: Entity?
    /// Control columns and their wheels; `restZ` is where a light aircraft's sliding yoke sits at neutral.
    private var yokes: [(column: Entity, wheel: Entity, restZ: Float)] = []
    private var sticks: [Entity] = []
    private var gearGreen: [ModelEntity] = []
    private var gearRed: [ModelEntity] = []
    private var parkingBrakeLight: ModelEntity?

    init(materials: MaterialLibrary, profile: AircraftProfile, shape: AirframeShape, engineCount: Int) throws {
        root.name = "Cockpit"
        self.shape = shape
        self.materials = materials
        style = Style(profile)
        captainEye = shape.eye
        firstOfficerEye = style == .fighter ? shape.eye + SIMD3(0, 0.18, 1.55) : SIMD3(-shape.eye.x, shape.eye.y, shape.eye.z)
        for display in InstrumentDisplay.allCases {
            let size = display.pixelSize
            textures[display] = try TextureResource(image: try Self.blank(width: size.width, height: size.height),
                                                    withName: "\(display)", options: .init(semantic: .color))
        }
        switch style {
        case .airliner: try buildAirliner(engineCount: engineCount, retractableGear: profile.retractableGear)
        case .light: try buildLight(engineCount: engineCount)
        case .fighter: try buildFighter(engineCount: engineCount)
        }
        root.components.set(DynamicLightShadowComponent(castsShadow: false))
    }

    /// A point `dx` across, `dy` up and `dd` aft of the captain's eye (dx in the captain's own frame: the
    /// first officer's side mirrors it when `mirrored`).
    private func at(_ dx: Float, _ dy: Float, _ dd: Float) -> SIMD3<Float> {
        SIMD3(dx, shape.eye.y + dy, shape.eye.z + dd)
    }

    /// The lining from `from` to `to` meters relative to the eye, with the windscreen panes cut out.
    private func addLining(from: Float, to: Float) throws {
        var lining = MeshBuilder()
        let panes = shape.windscreenPanes
        lining.addHullLining(shape, from: shape.eyeDistance + from, to: shape.eyeDistance + to, arc: -0.08...(.pi + 0.08), inset: 0.04,
                             openings: panes + panes.map(\.mirrored))
        root.addChild(try AircraftModel.part("Cockpit lining", lining, materials.lining))
    }

    // MARK: - Airliner flight deck (737 dimensions, placed around the eye)

    private func buildAirliner(engineCount: Int, retractableGear: Bool) throws {
        let ex = abs(shape.eye.x)
        try addLining(from: -1.2, to: 1.35)
        var structure = MeshBuilder()
        var black = MeshBuilder()
        let floorY = shape.eye.y - 1.144
        structure.addRectangle(center: SIMD2(0, shape.eye.z + 0.3), direction: SIMD2(0, 1), length: 2.1, width: 2 * (ex + 0.55), y: floorY)
        // Glareshield, overhanging the panel. The panel face is 0.75 m in front of the pilots' eyes, with the
        // displays about 33 degrees below eye level.
        black.addBox(center: at(0, -0.339, -0.83), size: SIMD3(2 * ex + 0.88, 0.05, 0.28))
        structure.addBox(center: at(0, -0.664, -0.775), size: SIMD3(2 * ex + 0.78, 0.6, 0.05))
        // Center pedestal with the throttle quadrant.
        structure.addBox(center: at(0, -0.959, -0.2), size: SIMD3(0.4, 0.37, 1.1))
        black.addBox(center: at(0, -0.769, -0.27), size: SIMD3(0.42, 0.02, 0.36))
        for side: Float in [-1, 1] {
            structure.addBox(center: at(side * (ex + 0.42), -0.374, 0.25), size: SIMD3(0.18, 0.05, 1.4))
        }
        // Rear bulkhead with the door.
        structure.addBox(center: at(0, -0.294, 1.37), size: SIMD3(2 * ex + 1.7, 1.7, 0.04))
        black.addBox(center: at(0.35, -0.394, 1.34), size: SIMD3(0.7, 1.5, 0.02))
        var seats = MeshBuilder()
        for x in [-ex, ex] {
            addPilotSeat(&seats, x: x, recline: 0.2)
        }
        root.addChild(try AircraftModel.part("Flight deck structure", structure, materials.panel))
        root.addChild(try AircraftModel.part("Glareshield", black, materials.glareshield))
        root.addChild(try AircraftModel.part("Pilot seats", seats, materials.seat))

        // Overhead panel, sloping down toward the windshield.
        var overheadMaterial = materials.panel
        let overheadTexture = try Self.overheadTexture()
        overheadMaterial.baseColor = .init(tint: .white, texture: .init(overheadTexture))
        overheadMaterial.emissiveColor = .init(color: UIColor(white: 0.18, alpha: 1), texture: .init(overheadTexture))
        let overhead = ModelEntity(mesh: .generatePlane(width: min(1.1, 2 * ex), height: 1.2), materials: [overheadMaterial])
        overhead.position = at(0, 0.386, 0.05)
        overhead.orientation = simd_quatf(angle: .pi / 2 + 0.22, axis: SIMD3(1, 0, 0))
        root.addChild(overhead)

        // Display units: PFD outboard, ND inboard for each pilot, engine displays in the center, and the
        // mode control panel along the glareshield.
        for side: Float in [-1, 1] {
            try addScreen(.pfd, at: at(side * (ex + 0.1), -0.494, -0.748), size: 0.2)
            try addScreen(.nd, at: at(side * (ex - 0.14), -0.494, -0.748), size: 0.2)
        }
        try addScreen(.upperEICAS, at: at(0, -0.484, -0.748), size: 0.2)
        try addScreen(.lowerEICAS, at: at(0, -0.714, -0.748), size: 0.18)
        try addScreen(.mcp, at: at(0, -0.339, -0.688), width: min(0.9, 2 * ex), height: 0.07)

        // Thrust levers (one per engine), speedbrake lever left of them, flap lever right.
        let spacing: Float = engineCount > 2 ? 0.07 : 0.1
        let spread = Float(engineCount - 1) * spacing / 2
        for index in 0..<engineCount {
            thrustLevers.append(try lever(at: at(-spread + Float(index) * spacing, -0.774, -0.27), length: 0.22,
                                          knob: SIMD3(0.04, 0.03, 0.05)))
        }
        speedbrakeLever = try lever(at: at(-spread - 0.11, -0.774, -0.27), length: 0.18, knob: SIMD3(0.04, 0.03, 0.06))
        flapLever = try lever(at: at(spread + 0.11, -0.774, -0.27), length: 0.16, knob: SIMD3(0.05, 0.04, 0.04))

        if retractableGear {
            // Gear lever and the three green (down and locked) and red (in transit) lights on the center panel.
            let gear = Entity()
            gear.position = at(0.27, -0.674, -0.75)
            var handle = MeshBuilder()
            handle.addBox(center: SIMD3(0, 0, 0.06), size: SIMD3(0.025, 0.025, 0.12))
            handle.addCylinder(from: SIMD3(-0.025, 0, 0.12), to: SIMD3(0.025, 0, 0.12), radius: 0.025, segments: 12, capped: true)
            gear.addChild(try AircraftModel.part("Gear lever", handle, materials.lever))
            root.addChild(gear)
            gearLever = gear
            for index in 0..<3 {
                let x = 0.31 + Float(index) * 0.03
                gearGreen.append(try lamp(at: at(x, -0.594, -0.748), color: UIColor(red: 0.2, green: 1, blue: 0.3, alpha: 1)))
                gearRed.append(try lamp(at: at(x, -0.564, -0.748), color: UIColor(red: 1, green: 0.15, blue: 0.1, alpha: 1)))
            }
        }
        parkingBrakeLight = try lamp(at: at(-0.3, -0.594, -0.748), color: UIColor(red: 1, green: 0.15, blue: 0.1, alpha: 1), width: 0.05)

        for x in [-ex, ex] {
            try addYoke(base: at(x, -1.094, -0.49), height: 0.6, width: 0.17)
        }
    }

    // MARK: - Light aircraft panel

    private func buildLight(engineCount: Int) throws {
        let ex = abs(shape.eye.x)
        try addLining(from: -1.1, to: 1.6)
        let eyeSection = shape.section(atNoseDistance: shape.eyeDistance)
        let floorY = max(shape.eye.y - 1.0, eyeSection.centerY - eyeSection.radius * eyeSection.scaleY + 0.12)
        let halfWidth = eyeSection.radius * 0.92
        var structure = MeshBuilder()
        var black = MeshBuilder()
        structure.addRectangle(center: SIMD2(0, shape.eye.z), direction: SIMD2(0, 1), length: 2.4, width: 2 * halfWidth, y: floorY)
        // The panel and its padded glareshield, 0.65 m ahead of the eyes.
        structure.addBox(center: at(0, -0.33, -0.65), size: SIMD3(2 * halfWidth, 0.36, 0.06))
        black.addBox(center: at(0, -0.13, -0.7), size: SIMD3(2 * halfWidth, 0.05, 0.16))
        // Rear bulkhead (the baggage area behind the seats).
        structure.addBox(center: at(0, -0.3, 1.5), size: SIMD3(2 * halfWidth, 1.2, 0.04))
        var seats = MeshBuilder()
        for x in [-ex, ex] {
            addPilotSeat(&seats, x: x, recline: 0.25, height: shape.eye.y - floorY - 0.83)
        }
        root.addChild(try AircraftModel.part("Panel", structure, materials.panel))
        root.addChild(try AircraftModel.part("Glareshield", black, materials.glareshield))
        root.addChild(try AircraftModel.part("Seats", seats, materials.seat))
        // A two-screen glass panel in front of the pilot, engine page in the middle.
        try addScreen(.pfd, at: at(-ex, -0.3, -0.618), size: 0.2)
        try addScreen(.nd, at: at(ex, -0.3, -0.618), size: 0.2)
        try addScreen(.upperEICAS, at: at(0, -0.33, -0.618), size: 0.14)
        // Throttle, one knob per engine, under the panel's center.
        for index in 0..<engineCount {
            thrustLevers.append(try lever(at: at((Float(index) - Float(engineCount - 1) / 2) * 0.06, -0.48, -0.6),
                                          length: 0.08, knob: SIMD3(0.035, 0.035, 0.035)))
        }
        flapLever = try lever(at: at(0.16, -0.48, -0.6), length: 0.06, knob: SIMD3(0.05, 0.02, 0.02))
        parkingBrakeLight = try lamp(at: at(-0.12, -0.42, -0.618), color: UIColor(red: 1, green: 0.15, blue: 0.1, alpha: 1), width: 0.04)
        for x in [-ex, ex] {
            try addYoke(base: at(x, -0.36, -0.62), height: 0.0, width: 0.13, forward: true)
        }
    }

    // MARK: - Fighter: tandem seats under one canopy

    private func buildFighter(engineCount: Int) throws {
        try addLining(from: -1.2, to: 3.0)
        let section = shape.section(atNoseDistance: shape.eyeDistance)
        let halfWidth = section.radius * 0.8
        let floorY = shape.eye.y - 1.0
        var structure = MeshBuilder()
        var black = MeshBuilder()
        var seats = MeshBuilder()
        for (index, eye) in [captainEye, firstOfficerEye].enumerated() {
            let d = eye.z - shape.eye.z
            let dy = eye.y - shape.eye.y
            structure.addRectangle(center: SIMD2(0, eye.z + 0.1), direction: SIMD2(0, 1), length: 1.4, width: 2 * halfWidth, y: floorY + dy)
            // Instrument panel, glareshield and the side consoles.
            structure.addBox(center: at(0, dy - 0.42, d - 0.62), size: SIMD3(0.8, 0.34, 0.06))
            black.addBox(center: at(0, dy - 0.24, d - 0.68), size: SIMD3(0.82, 0.04, 0.16))
            for side: Float in [-1, 1] {
                structure.addBox(center: at(side * (halfWidth - 0.08), dy - 0.62, d - 0.05), size: SIMD3(0.16, 0.08, 0.9))
            }
            // Ejection seat: tall back with the headbox.
            seats.addBox(center: at(0, dy - 0.8, d + 0.12), size: SIMD3(0.46, 0.1, 0.46))
            seats.addBox(center: at(0, dy - 0.35, d + 0.38), size: SIMD3(0.46, 0.95, 0.12))
            seats.addBox(center: at(0, dy + 0.18, d + 0.4), size: SIMD3(0.3, 0.26, 0.14))
            if index == 0 {
                try addScreen(.pfd, at: at(0, dy - 0.4, d - 0.588), size: 0.22)
                try addScreen(.nd, at: at(-0.27, dy - 0.45, d - 0.588), size: 0.15)
                try addScreen(.upperEICAS, at: at(0.27, dy - 0.45, d - 0.588), size: 0.15)
                // Head-up display combiner glass above the panel.
                var glass = UnlitMaterial(color: UIColor(red: 0.6, green: 0.9, blue: 0.7, alpha: 1))
                glass.blending = .transparent(opacity: .init(floatLiteral: 0.12))
                let combiner = ModelEntity(mesh: .generatePlane(width: 0.16, height: 0.14), materials: [glass])
                combiner.position = at(0, dy - 0.13, d - 0.5)
                combiner.orientation = simd_quatf(angle: -0.35, axis: SIMD3(1, 0, 0))
                root.addChild(combiner)
            } else {
                try addScreen(.nd, at: at(-0.13, dy - 0.42, d - 0.588), size: 0.18)
                try addScreen(.upperEICAS, at: at(0.13, dy - 0.42, d - 0.588), size: 0.18)
            }
            sticks.append(try stick(at: at(0, dy - 0.95, d - 0.3)))
        }
        root.addChild(try AircraftModel.part("Cockpit structure", structure, materials.panel))
        root.addChild(try AircraftModel.part("Glareshields", black, materials.glareshield))
        root.addChild(try AircraftModel.part("Ejection seats", seats, materials.seat))
        // Throttles on the left console, side by side.
        for index in 0..<engineCount {
            thrustLevers.append(try lever(at: at(-(halfWidth - 0.08) + Float(index) * 0.045, -0.58, -0.05), length: 0.14,
                                          knob: SIMD3(0.04, 0.05, 0.05)))
        }
        parkingBrakeLight = try lamp(at: at(0.3, -0.3, -0.588), color: UIColor(red: 1, green: 0.15, blue: 0.1, alpha: 1), width: 0.04)
    }

    // MARK: - Per frame

    /// Moves the levers, yokes or sticks and the lights to match the controls.
    func update(controls: FlightControls, telemetry: Telemetry) {
        let throttleAngle = Self.degrees(25 - 50 * Float(controls.throttle))
        thrustLevers.forEach { $0.orientation = simd_quatf(angle: throttleAngle, axis: SIMD3(1, 0, 0)) }
        speedbrakeLever?.orientation = simd_quatf(angle: Self.degrees(-20 + 55 * Float(controls.speedbrake)), axis: SIMD3(1, 0, 0))
        flapLever?.orientation = simd_quatf(angle: Self.degrees(-20 + 50 * Float(controls.flaps)), axis: SIMD3(1, 0, 0))
        gearLever?.orientation = simd_quatf(angle: Self.degrees(controls.gearDown ? -35 : 35), axis: SIMD3(1, 0, 0))
        for (column, wheel, restZ) in yokes {
            if style == .light {
                // Light-aircraft yokes slide in and out of the panel.
                column.position.z = restZ + Float(controls.elevator) * 0.06
            } else {
                column.orientation = simd_quatf(angle: Self.degrees(-12 * Float(controls.elevator)), axis: SIMD3(1, 0, 0))
            }
            wheel.orientation = simd_quatf(angle: Self.degrees(-70 * Float(controls.aileron)), axis: SIMD3(0, 0, 1))
        }
        for stick in sticks {
            stick.orientation = simd_quatf(angle: Self.degrees(-15 * Float(controls.elevator)), axis: SIMD3(1, 0, 0))
                * simd_quatf(angle: Self.degrees(-15 * Float(controls.aileron)), axis: SIMD3(0, 0, 1))
        }
        let locked = telemetry.gearPosition > 0.99
        let moving = telemetry.gearPosition > 0.01 && !locked
        gearGreen.forEach { $0.isEnabled = locked }
        gearRed.forEach { $0.isEnabled = moving }
        parkingBrakeLight?.isEnabled = controls.parkingBrake
    }

    /// Shows a freshly drawn instrument image.
    func show(_ image: CGImage, on display: InstrumentDisplay) throws {
        guard let texture = textures[display] else { return }
        try texture.replace(withImage: image, options: .init(semantic: .color))
    }

    // MARK: - Builders

    private static func degrees(_ value: Float) -> Float { value * .pi / 180 }

    private func addScreen(_ display: InstrumentDisplay, at position: SIMD3<Float>, size: Float) throws {
        try addScreen(display, at: position, width: size, height: size)
    }

    private func addScreen(_ display: InstrumentDisplay, at position: SIMD3<Float>, width: Float, height: Float) throws {
        guard let texture = textures[display] else { return }
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        let screen = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
        screen.position = position
        root.addChild(screen)
        displays.insert(display)
    }

    /// Seat pan, reclined back and headrest, with the pan `height` above the floor's level below the eye.
    private func addPilotSeat(_ seats: inout MeshBuilder, x: Float, recline angle: Float, height: Float = 0.33) {
        let pan = shape.eye.y - 0.814
        seats.addBox(center: at(x, -0.814, 0.1), size: SIMD3(0.5, 0.1, 0.5))
        let recline = simd_quatf(angle: angle, axis: SIMD3(1, 0, 0))
        let pivot = at(x, -0.774, 0.35)
        seats.addBox(center: at(x, -0.374, 0.35), size: SIMD3(0.5, 0.8, 0.1), rotation: recline, pivot: pivot)
        seats.addBox(center: at(x, 0.126, 0.37), size: SIMD3(0.28, 0.22, 0.1), rotation: recline, pivot: pivot)
        seats.addBox(center: SIMD3(x, pan - height / 2 - 0.05, shape.eye.z + 0.1), size: SIMD3(0.2, max(height, 0.05), 0.2))
    }

    /// A control column and wheel; for a light aircraft (`forward`) the yoke shaft comes out of the panel.
    private func addYoke(base: SIMD3<Float>, height: Float, width: Float, forward: Bool = false) throws {
        let column = Entity()
        column.position = base
        var post = MeshBuilder()
        if forward {
            post.addCylinder(from: .zero, to: SIMD3(0, 0, 0.22), radius: 0.015, segments: 10)
        } else {
            post.addCylinder(from: .zero, to: SIMD3(0, height - 0.04, -0.04), radius: 0.03, segments: 10)
        }
        column.addChild(try AircraftModel.part("Column", post, materials.lever))
        let wheel = Entity()
        wheel.position = forward ? SIMD3(0, 0, 0.22) : SIMD3(0, height, -0.04)
        var horns = MeshBuilder()
        horns.addCylinder(from: SIMD3(-width, 0, 0), to: SIMD3(width, 0, 0), radius: 0.018, segments: 10, capped: true)
        for side: Float in [-1, 1] {
            horns.addCylinder(from: SIMD3(side * width, 0, 0), to: SIMD3(side * (width + 0.02), 0.11, 0), radius: 0.022, segments: 10, capped: true)
            horns.addCylinder(from: SIMD3(side * width, 0, 0), to: SIMD3(side * (width - 0.02), -0.06, 0), radius: 0.02, segments: 10, capped: true)
        }
        horns.addBox(center: SIMD3(0, -0.02, 0.01), size: SIMD3(0.12, 0.07, 0.03))
        wheel.addChild(try AircraftModel.part("Wheel", horns, materials.lever))
        column.addChild(wheel)
        root.addChild(column)
        yokes.append((column, wheel, base.z))
    }

    /// A center stick pivoting at the floor.
    private func stick(at base: SIMD3<Float>) throws -> Entity {
        let pivot = Entity()
        pivot.position = base
        var grip = MeshBuilder()
        grip.addCylinder(from: .zero, to: SIMD3(0, 0.5, 0.05), radius: 0.018, segments: 10)
        grip.addBox(center: SIMD3(0, 0.55, 0.05), size: SIMD3(0.045, 0.12, 0.05))
        pivot.addChild(try AircraftModel.part("Stick", grip, materials.lever))
        root.addChild(pivot)
        return pivot
    }

    /// A lever pivoting fore and aft; its entity origin is the pivot.
    private func lever(at position: SIMD3<Float>, length: Float, knob: SIMD3<Float>) throws -> Entity {
        let pivot = Entity()
        pivot.position = position
        var shaft = MeshBuilder()
        shaft.addBox(center: SIMD3(0, length / 2, 0), size: SIMD3(0.018, length, 0.022))
        shaft.addBox(center: SIMD3(0, length, 0), size: knob)
        pivot.addChild(try AircraftModel.part("Lever", shaft, materials.lever))
        root.addChild(pivot)
        return pivot
    }

    private func lamp(at position: SIMD3<Float>, color: UIColor, width: Float = 0.022) throws -> ModelEntity {
        let entity = ModelEntity(mesh: .generatePlane(width: width, height: 0.018), materials: [UnlitMaterial(color: color)])
        entity.position = position
        entity.isEnabled = false
        root.addChild(entity)
        return entity
    }

    private static func blank(width: Int, height: Int) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SkyError.imageCreation }
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw SkyError.imageCreation }
        return image
    }

    /// The overhead panel: rows of system panels with switches and a few lit annunciators.
    private static func overheadTexture() throws -> TextureResource {
        let image = try Sky.drawImage(size: 512) { context, size in
            context.setFillColor(UIColor(red: 0.33, green: 0.36, blue: 0.39, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            var rng = SeededGenerator(seed: 0x0737)
            let rows = 6, columns = 5
            let cellWidth = size / CGFloat(columns), cellHeight = size / CGFloat(rows)
            for row in 0..<rows {
                for column in 0..<columns {
                    let cell = CGRect(x: CGFloat(column) * cellWidth + 6, y: CGFloat(row) * cellHeight + 6,
                                      width: cellWidth - 12, height: cellHeight - 12)
                    context.setStrokeColor(UIColor(white: 0.85, alpha: 0.6).cgColor)
                    context.setLineWidth(2)
                    context.stroke(cell)
                    for knob in 0..<3 {
                        let x = cell.minX + cell.width * (0.2 + 0.3 * CGFloat(knob))
                        let y = cell.minY + cell.height * 0.55
                        context.setFillColor(UIColor(white: 0.08, alpha: 1).cgColor)
                        context.fill(CGRect(x: x - 5, y: y - 12, width: 10, height: 24))
                        if Int.random(in: 0..<5, using: &rng) == 0 {
                            context.setFillColor(UIColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1).cgColor)
                            context.fill(CGRect(x: x - 12, y: cell.minY + 8, width: 24, height: 10))
                        }
                    }
                }
            }
        }
        return try TextureResource(image: image, withName: "Overhead panel", options: .init(semantic: .color))
    }
}
