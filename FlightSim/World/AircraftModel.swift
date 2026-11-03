import RealityKit
import UIKit
import simd

/// The drawn fuselage: a body of revolution placed around the pilot's eye point, with an optional raised
/// section (the 747's upper deck, a fighter's canopy). The exterior, flight deck and cabin all use it, so the
/// interiors fit inside the hull. Model axes: nose toward -z, right wing +x, up +y, meters around the CG.
struct AirframeShape: Sendable {
    /// A raised part of the fuselage: grows from nothing at `start` to full over `full`, gone again at `end`
    /// (nose distances), adding `extraScale` to the section's height and lifting its center `extraRise` radii.
    struct Hump: Sendable {
        let start: Float
        let full: ClosedRange<Float>
        let end: Float
        let extraScale: Float
        let extraRise: Float
    }

    struct Station: Sendable {
        let distance: Float
        let radius: Float
        let rise: Float
    }

    let noseZ: Float
    let length: Float
    let centerY: Float
    let radius: Float
    /// The cross-section is slightly taller than wide.
    let oval: Float = 1.06
    let eye: SIMD3<Float>
    /// The eye's distance aft of the nose tip.
    let eyeDistance: Float
    let stations: [Station]
    let hump: Hump?
    /// Flight deck windows on the right side (the left side mirrors them).
    private(set) var windscreenPanes: [HullOpening] = []

    init(profile: AircraftProfile, geometry: AircraftGeometry) {
        let r = profile.fuselageRadius
        let length = profile.lengthMeters
        radius = r
        self.length = length
        eye = geometry.eyePoint
        eyeDistance = profile.eyeBehindNose
        noseZ = eye.z - profile.eyeBehindNose
        centerY = eye.y - profile.eyeAboveCenter * r
        // Nose stations in radii (distance aft, radius, center rise); tail stations from a fraction of the length.
        let (nose, tail): ([SIMD3<Float>], [SIMD3<Float>]) = switch profile.airframe {
        case .jetAirliner:
            ([SIMD3(0, 0.027, -0.186), SIMD3(0.16, 0.293, -0.149), SIMD3(0.479, 0.543, -0.096), SIMD3(0.904, 0.734, -0.048),
              SIMD3(1.383, 0.862, -0.016), SIMD3(2.021, 0.957, 0), SIMD3(2.766, 1, 0)],
             [SIMD3(0.733, 1, 0), SIMD3(0.793, 0.947, 0.043), SIMD3(0.862, 0.755, 0.16), SIMD3(0.934, 0.457, 0.33), SIMD3(1, 0.117, 0.505)])
        case .businessJet:
            ([SIMD3(0, 0.03, -0.1), SIMD3(0.3, 0.35, -0.08), SIMD3(0.8, 0.6, -0.05), SIMD3(1.5, 0.82, -0.02), SIMD3(2.4, 0.95, 0),
              SIMD3(3.2, 1, 0)],
             [SIMD3(0.62, 1, 0), SIMD3(0.75, 0.9, 0.08), SIMD3(0.88, 0.6, 0.25), SIMD3(1, 0.15, 0.45)])
        case .highWingTurboprop:
            ([SIMD3(0, 0.05, -0.2), SIMD3(0.2, 0.45, -0.15), SIMD3(0.6, 0.75, -0.07), SIMD3(1.2, 0.93, -0.02), SIMD3(1.9, 1, 0)],
             [SIMD3(0.62, 1, 0), SIMD3(0.75, 0.85, 0.25), SIMD3(0.88, 0.55, 0.5), SIMD3(1, 0.2, 0.7)])
        case .lightSingle:
            ([SIMD3(0, 0.3, -0.1), SIMD3(0.15, 0.6, -0.05), SIMD3(0.6, 0.88, 0), SIMD3(1.4, 1, 0.05)],
             [SIMD3(0.42, 1, 0.05), SIMD3(0.6, 0.72, 0.2), SIMD3(0.8, 0.42, 0.35), SIMD3(1, 0.18, 0.5)])
        case .fighter:
            ([SIMD3(0, 0.03, -0.05), SIMD3(0.8, 0.32, -0.03), SIMD3(1.8, 0.55, 0), SIMD3(3, 0.8, 0.05), SIMD3(4.2, 1, 0.1)],
             [SIMD3(0.7, 1, 0.1), SIMD3(0.85, 0.95, 0.05), SIMD3(1, 0.85, 0)])
        }
        stations = nose.map { Station(distance: $0.x * r, radius: $0.y * r, rise: $0.z * r) }
            + tail.map { Station(distance: $0.x * length, radius: $0.y * r, rise: $0.z * r) }
        let eyeDistance = profile.eyeBehindNose
        hump = switch profile.airframe {
        case .jetAirliner where profile.upperDeck:
            Hump(start: 0, full: 0...(0.26 * length), end: 0.4 * length, extraScale: 0.3, extraRise: 0.3)
        case .fighter:
            Hump(start: eyeDistance - 1.2, full: (eyeDistance - 0.5)...(eyeDistance + 2.2), end: eyeDistance + 3.8,
                 extraScale: 0.35, extraRise: 0.15)
        default:
            nil
        }
        windscreenPanes = Self.panes(for: profile.airframe, shape: self)
    }

    func z(_ noseDistance: Float) -> Float { noseZ + noseDistance }

    /// Radius, center height and vertical stretch of the fuselage `distance` meters aft of the nose tip.
    func section(atNoseDistance distance: Float) -> (radius: Float, centerY: Float, scaleY: Float) {
        let upper = stations.firstIndex { $0.distance >= distance } ?? stations.count - 1
        let lower = max(upper - 1, 0)
        let a = stations[lower], b = stations[upper]
        let t = b.distance > a.distance ? ((distance - a.distance) / (b.distance - a.distance)).clamped(0, 1) : 0
        let radius = a.radius + (b.radius - a.radius) * t
        var center = centerY + a.rise + (b.rise - a.rise) * t
        var scale = oval
        if let hump {
            let amount: Float = if distance < hump.full.lowerBound {
                ((distance - hump.start) / max(hump.full.lowerBound - hump.start, 0.01)).clamped(0, 1)
            } else {
                1 - ((distance - hump.full.upperBound) / max(hump.end - hump.full.upperBound, 0.01)).clamped(0, 1)
            }
            let eased = amount * amount * (3 - 2 * amount)
            scale += hump.extraScale * eased
            center += hump.extraRise * self.radius * eased
        }
        return (radius, center, scale)
    }

    /// A point `inset` meters inside the hull surface at a nose distance and an angle around the section
    /// (radians from +x, counter-clockwise toward +y).
    func hullPoint(atNoseDistance distance: Float, angle: Float, inset: Float) -> SIMD3<Float> {
        let section = section(atNoseDistance: distance)
        let r = section.radius - inset
        return SIMD3(cos(angle) * r, section.centerY + sin(angle) * r * section.scaleY, z(distance))
    }

    /// Where to sample the fuselage loft: every station plus enough in between for the hump to stay smooth.
    var loftDistances: [Float] {
        Set(stations.map(\.distance) + stride(from: 0, to: length, by: length / 64).map { $0 }).sorted()
    }

    /// The angle around the section at which a point `height` above the section center sits on the hull.
    func arc(atHeight height: Float, noseDistance: Float) -> Float {
        let section = section(atNoseDistance: noseDistance)
        return asin((height / (section.radius * section.scaleY)).clamped(-0.99, 0.99))
    }

    private static func panes(for airframe: AirframeKind, shape: AirframeShape) -> [HullOpening] {
        let d = shape.eyeDistance
        // Airliner windscreens have a center post between the left and right panes; a fighter canopy has none.
        let centerPost: Float = airframe == .fighter ? 0 : 0.03
        func pane(_ from: Float, _ to: Float, _ arc: ClosedRange<Float>) -> HullOpening {
            let upper = min(arc.upperBound, .pi / 2 - centerPost)
            return HullOpening(z: (d + from)...(d + to), arc: min(arc.lowerBound, upper - 0.05)...upper)
        }
        switch airframe {
        case .jetAirliner, .businessJet, .highWingTurboprop:
            // The 737's windows, turned up or down to where this aircraft's eye sits in the section.
            let eyeArc = shape.arc(atHeight: shape.eye.y - shape.section(atNoseDistance: d).centerY, noseDistance: d)
            let shift = eyeArc - 0.613
            return [pane(-1.10, -0.60, (0.62 + shift)...(1.52 + shift)),
                    pane(-0.55, 0, (0.34 + shift)...(1.02 + shift)),
                    pane(0.07, 0.50, (0.40 + shift)...(0.95 + shift))]
        case .lightSingle:
            return [pane(-1.0, -0.3, 0.25...1.5), pane(-0.25, 0.9, -0.15...1.0), pane(0.95, 1.5, 0.2...0.9)]
        case .fighter:
            return [pane(-1.1, -0.45, 0.75...(.pi / 2)), pane(-0.4, 2.2, 0.55...(.pi / 2))]
        }
    }
}

/// An aircraft built in code from its profile and its JSBSim geometry: fuselage, wings, tail, engines,
/// landing gear, moving control surfaces, spinning fans or propellers, and exterior lights. The origin is
/// the center of gravity, so the wheels touch the runway exactly where the physics says.
///
/// This stands in until purchased USDZ models replace it.
@MainActor
final class AircraftModel {
    let root = Entity()
    let shape: AirframeShape
    /// The wing camera: above the left wing root, looking out along the wing.
    private(set) var wingCamera: (eye: SIMD3<Float>, target: SIMD3<Float>) = (.zero, .zero)

    private let profile: AircraftProfile
    private var flaps: [Hinged] = []
    private var leftAileron: Hinged?
    private var rightAileron: Hinged?
    private var elevators: [Hinged] = []
    private var rudder: Hinged?
    private var spoilers: [Hinged] = []
    private var gearLegs: [Hinged] = []
    private var rotors: [Entity] = []
    private var rotorAngles: [Float] = []
    private var afterburners: [ModelEntity] = []
    private var navigationLights: [ModelEntity] = []
    private var strobeLights: [ModelEntity] = []
    private var beaconLights: [ModelEntity] = []
    private var landingLights: [ModelEntity] = []
    private let landingBeam = SpotLight()
    private var lightClock: Double = 0

    static let maxAileronDegrees: Float = 20
    static let maxElevatorDegrees: Float = 25
    static let maxRudderDegrees: Float = 25
    static let maxSpoilerDegrees: Float = 45
    /// Visual rotor speed at full power, turns per second. Real fans and propellers turn far faster than a
    /// frame can show; this keeps them visibly turning and blurring the way they look on camera.
    static let rotorTurnsPerSecond: Float = 9
    /// Thrust above which a fighter's afterburner flame shows, pounds per engine.
    static let afterburnerThrustPounds = 11_000.0

    struct Hinged {
        let entity: Entity
        let axis: SIMD3<Float>

        @MainActor func set(degrees: Float) {
            entity.orientation = simd_quatf(angle: degrees * .pi / 180, axis: axis)
        }
    }

    /// Wing layout per airframe: sweep and dihedral (degrees), taper ratio, thickness ratio, and the
    /// stabilizer and fin proportions relative to the wing.
    private struct Layout {
        var sweep: Float
        var dihedral: Float
        var taper: Float
        var thickness: Float
        var stabSpan: Float
        var stabChord: Float
        var stabSweep: Float
        var stabDihedral: Float
        var stabPosition: Float
        var finHeight: Float
        var finChord: Float
        var finSweep: Float
        var finPosition: Float

        init(_ profile: AircraftProfile) {
            switch profile.airframe {
            case .jetAirliner:
                self.init(sweep: profile.type == .b747 ? 37.5 : (profile.type == .b787 ? 32 : 25), dihedral: 6, taper: 0.25, thickness: 0.12,
                          stabSpan: 0.4, stabChord: 0.5, stabSweep: 30, stabDihedral: 6, stabPosition: 0.84,
                          finHeight: 0.21, finChord: 0.85, finSweep: 35, finPosition: 0.8)
            case .businessJet:
                self.init(sweep: 34, dihedral: 3, taper: 0.3, thickness: 0.11, stabSpan: 0.34, stabChord: 0.55, stabSweep: 32,
                          stabDihedral: 0, stabPosition: 0, finHeight: 0.2, finChord: 0.9, finSweep: 40, finPosition: 0.74)
            case .highWingTurboprop:
                self.init(sweep: 2, dihedral: 2, taper: 0.5, thickness: 0.16, stabSpan: 0.36, stabChord: 0.5, stabSweep: 5,
                          stabDihedral: 3, stabPosition: 0.84, finHeight: 0.17, finChord: 0.8, finSweep: 20, finPosition: 0.78)
            case .lightSingle:
                self.init(sweep: 0, dihedral: 1.7, taper: 0.7, thickness: 0.15, stabSpan: 0.31, stabChord: 0.7, stabSweep: 3,
                          stabDihedral: 0, stabPosition: 0.86, finHeight: 0.14, finChord: 0.8, finSweep: 35, finPosition: 0.8)
            case .fighter:
                self.init(sweep: 45, dihedral: 4, taper: 0.25, thickness: 0.05, stabSpan: 0.47, stabChord: 0.55, stabSweep: 35,
                          stabDihedral: -23, stabPosition: 0.82, finHeight: 0.25, finChord: 0.85, finSweep: 50, finPosition: 0.72)
            }
        }

        private init(sweep: Float, dihedral: Float, taper: Float, thickness: Float, stabSpan: Float, stabChord: Float, stabSweep: Float,
                     stabDihedral: Float, stabPosition: Float, finHeight: Float, finChord: Float, finSweep: Float, finPosition: Float) {
            self.sweep = sweep
            self.dihedral = dihedral
            self.taper = taper
            self.thickness = thickness
            self.stabSpan = stabSpan
            self.stabChord = stabChord
            self.stabSweep = stabSweep
            self.stabDihedral = stabDihedral
            self.stabPosition = stabPosition
            self.finHeight = finHeight
            self.finChord = finChord
            self.finSweep = finSweep
            self.finPosition = finPosition
        }
    }

    init(profile: AircraftProfile, geometry: AircraftGeometry, materials: MaterialLibrary) throws {
        self.profile = profile
        let shape = AirframeShape(profile: profile, geometry: geometry)
        self.shape = shape
        root.name = profile.name
        let layout = Layout(profile)
        let r = shape.radius
        let airframe = profile.airframe
        let liveryMaterial = MaterialLibrary.solid(UIColor(red: CGFloat(profile.livery.x), green: CGFloat(profile.livery.y),
                                                           blue: CGFloat(profile.livery.z), alpha: 1), roughness: 0.3, metallic: 0.1, clearcoat: 0.6)
        let skin = airframe == .fighter ? liveryMaterial : materials.fuselage

        // Fuselage.
        var body = MeshBuilder()
        body.addLoft(shape.loftDistances.map { d in
            let s = shape.section(atNoseDistance: d)
            return (z: shape.z(d), radius: s.radius, y: s.centerY, scaleY: s.scaleY)
        }, segments: 40)
        root.addChild(try Self.part("Fuselage", body, skin))

        // Windows: flight deck panes, and a row of cabin windows along each side.
        var windows = MeshBuilder()
        for pane in shape.windscreenPanes {
            for arc in [pane.arc, pane.mirrored.arc] {
                windows.addLoft([pane.z.lowerBound, pane.z.upperBound].map { d in
                    let s = shape.section(atNoseDistance: d)
                    return (z: shape.z(d), radius: s.radius + 0.012, y: s.centerY, scaleY: s.scaleY)
                }, segments: 6, arc: arc)
            }
        }
        let cabinWindows = CabinLayout(profile: profile, shape: shape)
        if let cabinWindows {
            for arc in [cabinWindows.windowArc, (.pi - cabinWindows.windowArc.upperBound)...(.pi - cabinWindows.windowArc.lowerBound)] {
                windows.addLoft([cabinWindows.windowStart, cabinWindows.windowEnd].map { d in
                    let s = shape.section(atNoseDistance: d)
                    return (z: shape.z(d), radius: s.radius + 0.015, y: s.centerY, scaleY: s.scaleY)
                }, segments: 8, arc: arc)
            }
        }
        root.addChild(try Self.part("Windows", windows, materials.window))

        // Wing: trapezoidal planform from the JSBSim span and area, its mean chord's quarter point on the
        // aerodynamic reference point.
        let semispan = geometry.wingspan / 2
        let rootChord = 2 * geometry.wingArea / (geometry.wingspan * (1 + layout.taper))
        let meanChord = 2 / 3 * rootChord * (1 + layout.taper + layout.taper * layout.taper) / (1 + layout.taper)
        let meanChordSpan = geometry.wingspan / 6 * (1 + 2 * layout.taper) / (1 + layout.taper)
        let sweep = tan(layout.sweep * .pi / 180)
        let leadingEdgeZ = geometry.aeroReference.z - meanChordSpan * sweep - meanChord / 4
        let wingSection = shape.section(atNoseDistance: leadingEdgeZ - shape.noseZ)
        let highWing = airframe == .highWingTurboprop || airframe == .lightSingle
        let wingY = highWing ? wingSection.centerY + 0.82 * r * wingSection.scaleY
            : wingSection.centerY - (airframe == .fighter ? 0.35 : 0.6) * r
        let wingRootX = highWing ? r * 0.5 : r * 0.85
        let dihedral = tan(layout.dihedral * .pi / 180)
        let wing = Planform(
            leadingEdge: { s in SIMD3(s, wingY + (s - wingRootX) * dihedral, leadingEdgeZ + s * sweep) },
            chord: { s in rootChord * (1 - (1 - layout.taper) * s / semispan) },
            thickness: layout.thickness)
        let spanFraction = { (f: Float) in wingRootX + (semispan - wingRootX) * f }
        let flapEnd = spanFraction(airframe == .fighter ? 0.45 : 0.62)
        let aileronEnd = spanFraction(0.95)
        var wings = MeshBuilder()
        for side: Float in [-1, 1] {
            wings.addSurface(wing, span: wingRootX...semispan, chordRange: 0...0.72, side: side, axis: .horizontal)
            wings.addSurface(wing, span: aileronEnd...semispan, chordRange: 0.72...1, side: side, axis: .horizontal)
        }
        // Wing struts on the light aircraft: from the lower fuselage to the wing's underside.
        if highWing && r < 1.2 {
            for side: Float in [-1, 1] {
                let anchor = spanFraction(0.5)
                let top = wing.leadingEdge(anchor) + SIMD3(0, -0.05, wing.chord(anchor) * 0.3)
                let bottom = SIMD3(r * 0.85, wingSection.centerY - 0.55 * r, top.z)
                wings.addCylinder(from: bottom.mirrored(side), to: top.mirrored(side), radius: 0.05, segments: 8, capped: true)
            }
        }
        root.addChild(try Self.part("Wings", wings, materials.wing))
        for side: Float in [-1, 1] {
            flaps.append(try hinged("Flap", materials.wing, wing, span: wingRootX...flapEnd, chordRange: 0.72...1, side: side))
            let aileron = try hinged("Aileron", materials.wing, wing, span: (flapEnd + 0.1)...aileronEnd, chordRange: 0.72...1, side: side)
            if side < 0 { leftAileron = aileron } else { rightAileron = aileron }
            if profile.hasSpeedbrake && (airframe == .jetAirliner || airframe == .businessJet) {
                // Spoiler panels lie on the upper wing surface just ahead of the flaps.
                let panel = Planform(
                    leadingEdge: { s in wing.leadingEdge(s) + SIMD3(0, MeshBuilder.nacaHalfThickness(0.55, ratio: wing.thickness) * wing.chord(s), 0) },
                    chord: wing.chord, thickness: 0.012)
                spoilers.append(try hinged("Spoiler", materials.wing, panel, span: (wingRootX + 0.1 * semispan)...spanFraction(0.58),
                                           chordRange: 0.55...0.72, side: side))
            }
        }

        // Fin and rudder, in the livery color.
        var livery = MeshBuilder()
        let finHeight = geometry.wingspan * layout.finHeight
        let finChord = rootChord * layout.finChord
        let finDistance = shape.length * layout.finPosition
        let finSection = shape.section(atNoseDistance: finDistance + finChord * 0.5)
        let finBase = SIMD3<Float>(0, finSection.centerY + finSection.radius * finSection.scaleY * 0.8, shape.z(finDistance))
        let finSweep = tan(layout.finSweep * .pi / 180)
        let fin = Planform(leadingEdge: { h in finBase + SIMD3(0, h, h * finSweep) },
                           chord: { h in finChord * (1 - 0.6 * h / finHeight) }, thickness: 0.1)
        livery.addSurface(fin, span: 0...finHeight, chordRange: 0...0.7, side: 1, axis: .vertical)
        rudder = try hinged("Rudder", liveryMaterial, fin, span: (finHeight * 0.05)...finHeight, chordRange: 0.7...1, side: 1,
                            axis: .vertical)
        if airframe != .fighter {
            // A cheat line along the cabin.
            livery.addLoft([shape.length * 0.18, shape.length * 0.72].map { d in
                let s = shape.section(atNoseDistance: d)
                return (z: shape.z(d), radius: s.radius + 0.012, y: s.centerY, scaleY: s.scaleY)
            }, segments: 32, arc: .pi * 1.18 ... .pi * 1.82)
        }
        root.addChild(try Self.part("Livery", livery, liveryMaterial))

        // Horizontal stabilizer and elevators: on the fin top for the T-tail, else on the tail cone.
        let stabSemispan = geometry.wingspan * layout.stabSpan / 2
        let stabChord = rootChord * layout.stabChord
        let stabRoot: SIMD3<Float>
        let stabRootX: Float
        if airframe == .businessJet {
            stabRoot = fin.leadingEdge(finHeight * 0.95) + SIMD3(0, 0, fin.chord(finHeight * 0.95) * 0.1)
            stabRootX = 0.05
        } else {
            let distance = shape.length * layout.stabPosition
            let section = shape.section(atNoseDistance: distance + stabChord * 0.4)
            stabRoot = SIMD3(0, section.centerY + 0.1 * r, shape.z(distance))
            stabRootX = section.radius * 0.8
        }
        let stabSweep = tan(layout.stabSweep * .pi / 180)
        let stabDihedral = tan(layout.stabDihedral * .pi / 180)
        let stabilizer = Planform(
            leadingEdge: { s in SIMD3(s, stabRoot.y + s * stabDihedral, stabRoot.z + s * stabSweep) },
            chord: { s in stabChord * (1 - 0.6 * s / stabSemispan) }, thickness: 0.1)
        var stab = MeshBuilder()
        let elevatorChord: ClosedRange<Float> = airframe == .fighter ? 0.99...1 : 0.7...1
        for side: Float in [-1, 1] {
            stab.addSurface(stabilizer, span: stabRootX...stabSemispan, chordRange: 0...elevatorChord.lowerBound, side: side, axis: .horizontal)
            elevators.append(try hinged("Elevator", materials.wing, stabilizer, span: stabRootX...stabSemispan, chordRange: elevatorChord,
                                        side: side))
        }
        root.addChild(try Self.part("Stabilizer", stab, materials.wing))

        // Engines.
        var nacelles = MeshBuilder()
        var dark = MeshBuilder()
        let voice = EngineVoice(profile)
        let wingUnderside = { (x: Float) -> Float in
            wing.leadingEdge(abs(x)).y - MeshBuilder.nacaHalfThickness(0.3, ratio: wing.thickness) * wing.chord(abs(x))
        }
        for position in Self.spreadEngines(geometry.engines) {
            let side: Float = position.x < 0 ? -1 : 1
            switch profile.engineKind {
            case .turbofan where airframe == .businessJet:
                // Pods on the rear fuselage, on short stubs.
                let radius = 0.8 * Float((profile.maxThrustPounds / 23_500).squareRoot())
                let distance = shape.length * 0.74
                let section = shape.section(atNoseDistance: distance)
                let center = SIMD3(side * (section.radius + radius + 0.3), section.centerY + 0.45 * r, shape.z(distance))
                try addJetNacelle(&nacelles, &dark, materials, center: center, radius: radius, blades: voice.fanBlades)
                // The stub reaches from inside the hull to the nacelle's inner wall.
                nacelles.addBox(center: SIMD3(side * (section.radius + 0.15), center.y, center.z + 0.2 * radius),
                                size: SIMD3(0.6, 0.15, 2.2 * radius))
            case .turbofan:
                // Under the wing on a pylon, the nacelle mostly ahead of the leading edge.
                let radius = 0.8 * Float((profile.maxThrustPounds / 23_500).squareRoot())
                let edge = wing.leadingEdge(abs(position.x))
                let center = SIMD3(position.x, min(position.y, wingUnderside(position.x) - radius * 1.25), edge.z - 0.3 * radius)
                try addJetNacelle(&nacelles, &dark, materials, center: center, radius: radius, blades: voice.fanBlades)
                let pylonBase = center.y + radius * 0.75
                let pylonHeight = max(wingUnderside(position.x) - pylonBase + 0.1, 0.1)
                let pylon = Planform(leadingEdge: { h in SIMD3(center.x, pylonBase + h, center.z - 2 * radius + h * 0.5) },
                                     chord: { _ in 3.75 * radius }, thickness: 0.12)
                nacelles.addSurface(pylon, span: 0...pylonHeight, chordRange: 0...1, side: 1, axis: .vertical)
            case .turbojet:
                // Inside the fuselage: intakes beside the cockpit, nozzles at the tail.
                let nozzle = SIMD3(side * 0.5, shape.centerY - 0.15, shape.z(shape.length) - 0.5)
                dark.addCylinder(from: nozzle, to: nozzle + SIMD3(0, 0, 0.6), radius: 0.42, segments: 18, capped: true)
                nacelles.addCylinder(from: nozzle + SIMD3(0, 0, -1.2), to: nozzle + SIMD3(0, 0, 0.55), radius: 0.5, segments: 18)
                let intake = SIMD3(side * (r + 0.25), shape.centerY - 0.1, shape.z(shape.eyeDistance + 2.4))
                nacelles.addBox(center: intake + SIMD3(0, 0, 1.6), size: SIMD3(0.5, 0.9, 3.6))
                dark.addBox(center: intake + SIMD3(0, 0, -0.21), size: SIMD3(0.42, 0.8, 0.02))
                afterburners.append(try afterburner(at: nozzle + SIMD3(0, 0, 0.62)))
            case .turboprop:
                // A nacelle under the wing with the propeller well ahead of the leading edge.
                let radius = 0.19 * Float((profile.maxThrustPounds / 1_000).squareRoot())
                let edge = wing.leadingEdge(abs(position.x))
                let center = SIMD3(position.x, wingUnderside(position.x) - radius * 0.35, edge.z)
                let hub = center + SIMD3(0, 0, -2.4 * radius)
                nacelles.addLoft([(z: hub.z + 0.3 * radius, radius: radius * 0.75, y: center.y), (z: hub.z + radius, radius: radius, y: center.y),
                                  (z: center.z + wing.chord(abs(position.x)) * 0.8, radius: radius * 0.9, y: center.y),
                                  (z: center.z + wing.chord(abs(position.x)) * 1.3, radius: radius * 0.2, y: center.y + radius * 0.3)],
                                 scaleY: 1.15, segments: 20, centerX: center.x)
                try addPropeller(materials, hub: hub, radius: radius * 3.5, blades: Int(voice.propellerBlades), spinnerRadius: radius * 0.75)
            case .piston:
                // A propeller on the nose.
                let hub = SIMD3(0, position.y, shape.noseZ - 0.05)
                try addPropeller(materials, hub: hub, radius: 0.95, blades: Int(voice.propellerBlades), spinnerRadius: r * 0.35)
            }
        }
        // The Cessna's engine is inside its nose, so it has no nacelle.
        if !nacelles.isEmpty { root.addChild(try Self.part("Nacelles", nacelles, materials.engine)) }
        if !dark.isEmpty { root.addChild(try Self.part("Inlets", dark, materials.engineInlet)) }

        // Landing gear, from the JSBSim wheel positions. Mains fold inboard, the nose leg forward.
        let wheelRadius = (0.3 * r).clamped(0.18, 0.6)
        let noseWheel = geometry.wheels.min { $0.position.z < $1.position.z }
        for wheel in geometry.wheels {
            let isNose = wheel.name == noseWheel?.name
            let p = wheel.position
            let side: Float = p.x < -0.05 ? -1 : (p.x > 0.05 ? 1 : 0)
            let section = shape.section(atNoseDistance: p.z - shape.noseZ)
            let underWing = !highWing && abs(p.x) > section.radius * 0.7 && abs(p.x) < semispan
            let top = underWing ? SIMD3(p.x, wingUnderside(p.x) + 0.1, p.z)
                : SIMD3(side * min(abs(p.x), section.radius * 0.6), section.centerY - section.radius * 0.6, p.z)
            let radius = isNose ? wheelRadius * 0.65 : wheelRadius
            let pairs = r > 3 && !isNose ? 2 : 1
            let count = r > 1.3 ? 2 : 1
            gearLegs.append(try gearLeg(isNose ? "Nose gear" : "Main gear", materials, top: top, axle: p + SIMD3(0, radius, 0),
                                        wheelRadius: radius, wheels: count, rows: pairs,
                                        foldAxis: isNose ? SIMD3(1, 0, 0) : SIMD3(0, 0, side == 0 ? 1 : -side)))
        }

        // Exterior lights: red left and green right wingtip, white tail; strobes; red beacons; landing lights.
        let tipZ = wing.chord(semispan) * 0.4
        let leftTip = wing.leadingEdge(semispan).mirrored(-1) + SIMD3(0, 0, tipZ)
        let rightTip = wing.leadingEdge(semispan) + SIMD3(0, 0, tipZ)
        let tailSection = shape.section(atNoseDistance: shape.length)
        let tail = SIMD3<Float>(0, tailSection.centerY, shape.z(shape.length) + 0.05)
        let scale = (shape.length / 33.4).clamped(0.45, 1.6)
        let red = SIMD3<Float>(1, 0.08, 0.05), green = SIMD3<Float>(0.1, 1, 0.3), white = SIMD3<Float>(1, 1, 1)
        navigationLights = [try light("Nav left", at: leftTip, color: red, size: 1.4 * scale),
                            try light("Nav right", at: rightTip, color: green, size: 1.4 * scale),
                            try light("Nav tail", at: tail, color: white, size: 1.2 * scale)]
        strobeLights = [try light("Strobe left", at: leftTip + SIMD3(0, 0, 0.3), color: white, size: 3 * scale),
                        try light("Strobe right", at: rightTip + SIMD3(0, 0, 0.3), color: white, size: 3 * scale),
                        try light("Strobe tail", at: tail + SIMD3(0, 0, 0.2), color: white, size: 2.5 * scale)]
        let beaconSection = shape.section(atNoseDistance: shape.length * 0.45)
        beaconLights = [try light("Beacon top", at: SIMD3(0, beaconSection.centerY + r * beaconSection.scaleY + 0.06, shape.z(shape.length * 0.45)),
                                  color: red, size: 1.6 * scale),
                        try light("Beacon belly", at: SIMD3(0, beaconSection.centerY - r * beaconSection.scaleY - 0.06, shape.z(shape.length * 0.5)),
                                  color: red, size: 1.6 * scale)]
        let lampX = wingRootX + 0.6
        for side: Float in [-1, 1] {
            let lens = wing.leadingEdge(lampX).mirrored(side) + SIMD3(0, 0, -0.1)
            landingLights.append(try light(side < 0 ? "Landing left" : "Landing right", at: lens, color: SIMD3(1, 0.97, 0.9), size: 2.2 * scale))
        }
        let groundY = geometry.wheels.map(\.position.y).min() ?? 0
        landingBeam.light.color = UIColor(red: 1, green: 0.96, blue: 0.88, alpha: 1)
        landingBeam.light.intensity = 600_000
        landingBeam.light.innerAngleInDegrees = 12
        landingBeam.light.outerAngleInDegrees = 26
        landingBeam.light.attenuationRadius = 900
        let beamOrigin = wing.leadingEdge(lampX) * SIMD3(0, 1, 1)
        landingBeam.look(at: SIMD3(0, groundY - 8, -300), from: beamOrigin, relativeTo: root)
        root.addChild(landingBeam)

        let cameraSection = shape.section(atNoseDistance: leadingEdgeZ + rootChord - shape.noseZ)
        let cameraTarget = wing.leadingEdge(semispan * 0.6).mirrored(-1) + SIMD3(0, -0.3, wing.chord(semispan * 0.6) * 0.3)
        wingCamera = (eye: SIMD3(-r * 1.2, cameraSection.centerY + r * 1.25 + (highWing ? 1.0 : 0), leadingEdgeZ + wingRootX * sweep + rootChord),
                      target: cameraTarget)
    }

    /// Moves control surfaces and gear to match the flight model, spins fans and propellers, and runs the lights.
    func update(with telemetry: Telemetry, lights: ExteriorLights, nightFactor: Float, deltaTime dt: Double) {
        lightClock += dt
        for (index, rotor) in rotors.enumerated() {
            let engine = min(index, telemetry.engineSpool.count - 1)
            guard engine >= 0 else { break }
            rotorAngles[index] += Float(telemetry.engineSpool[engine]) * Self.rotorTurnsPerSecond * 2 * .pi * Float(dt)
            rotorAngles[index] = rotorAngles[index].truncatingRemainder(dividingBy: 2 * .pi)
            rotor.orientation = simd_quatf(angle: rotorAngles[index], axis: SIMD3(0, 0, -1))
        }
        for (index, flame) in afterburners.enumerated() where index < telemetry.engineThrustPounds.count {
            flame.isEnabled = telemetry.engineThrustPounds[index] > Self.afterburnerThrustPounds
        }
        // Lights glow brightest at night; in daylight they are small bright points.
        let glow = 0.35 + 0.65 * nightFactor
        navigationLights.forEach { setLight($0, on: lights.navigation, glow: glow) }
        // Strobes: two quick flashes every 1.2 s. Beacon: one red flash a second.
        let strobePhase = lightClock.truncatingRemainder(dividingBy: 1.2)
        let strobeOn = lights.strobes && (strobePhase < 0.05 || (strobePhase > 0.12 && strobePhase < 0.17))
        strobeLights.forEach { setLight($0, on: strobeOn, glow: 1) }
        let beaconOn = lights.beacon && lightClock.truncatingRemainder(dividingBy: 1.0) < 0.12
        beaconLights.forEach { setLight($0, on: beaconOn, glow: glow) }
        landingLights.forEach { setLight($0, on: lights.landing, glow: glow) }
        landingBeam.isEnabled = lights.landing && nightFactor > 0.1

        let maxFlapDegrees: Float = profile.airframe == .lightSingle ? 30 : 40
        flaps.forEach { $0.set(degrees: Float(telemetry.flapPosition) * maxFlapDegrees) }
        leftAileron?.set(degrees: Float(telemetry.leftAileronPosition) * Self.maxAileronDegrees)
        rightAileron?.set(degrees: Float(telemetry.rightAileronPosition) * Self.maxAileronDegrees)
        elevators.forEach { $0.set(degrees: Float(telemetry.elevatorPosition) * Self.maxElevatorDegrees) }
        rudder?.set(degrees: Float(telemetry.rudderPosition) * Self.maxRudderDegrees)
        spoilers.forEach { $0.set(degrees: -Float(telemetry.speedbrakePosition) * Self.maxSpoilerDegrees) }
        guard profile.retractableGear else { return }
        let fold = (1 - Float(telemetry.gearPosition)) * 90
        for leg in gearLegs {
            leg.set(degrees: fold)
            leg.entity.isEnabled = telemetry.gearPosition > 0.02
        }
    }

    private func setLight(_ entity: ModelEntity, on: Bool, glow: Float) {
        entity.isEnabled = on
        guard on else { return }
        entity.components.set(OpacityComponent(opacity: glow))
    }

    /// JSBSim's C-130 puts each wing's two engines at one point; real ones sit at 72 % and 144 % of it.
    static func spreadEngines(_ engines: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var result = engines
        for i in engines.indices {
            let twins = engines.indices.filter { simd_distance(engines[$0], engines[i]) < 0.1 }
            guard twins.count == 2 else { continue }
            result[i].x = engines[i].x * (twins.first == i ? 0.725 : 1.44)
        }
        return result
    }

    // MARK: - Part builders

    /// A turbofan nacelle (737 CFM56 proportions scaled to `radius`) with its fan behind the inlet.
    private func addJetNacelle(_ nacelles: inout MeshBuilder, _ dark: inout MeshBuilder, _ materials: MaterialLibrary,
                               center: SIMD3<Float>, radius: Float, blades: Double) throws {
        let k = radius / 0.8
        let outline: [(Float, Float, Float)] = [(-2.0, 0.80, 0), (-1.7, 0.86, 0), (-0.4, 0.88, 0), (1.0, 0.72, 0), (1.6, 0.45, 0.04)]
        nacelles.addLoft(outline.map { (z: center.z + $0.0 * k, radius: $0.1 * k, y: center.y + $0.2 * k) }, scaleY: 0.92, segments: 28,
                         centerX: center.x)
        // The dark core sits behind the fan, so the spinning blades show in the inlet.
        dark.addDisc(center: SIMD3(center.x, center.y, center.z - 1.25 * k), radius: radius, scaleY: 0.92, segments: 28)
        try addRotor(fan(materials, radius: radius * 0.93, blades: max(Int(blades * 0.6), 12)), at: SIMD3(center.x, center.y, center.z - 1.6 * k))
    }

    /// A fan: spinner and twisted blades, turning about the engine axis.
    private func fan(_ materials: MaterialLibrary, radius: Float, blades count: Int) throws -> Entity {
        let hub = Entity()
        var blades = MeshBuilder()
        for index in 0..<count {
            let angle = Float(index) / Float(count) * 2 * .pi
            let radial = SIMD3(cos(angle), sin(angle) * 0.92, 0)
            let tangent = SIMD3(-sin(angle), cos(angle), 0)
            // Each blade is a thin, twisted plate from the hub to the casing.
            let twist = simd_quatf(angle: 0.6, axis: radial)
            let width = radius * 0.14
            let chord = twist.act(tangent) * width
            let depth = twist.act(SIMD3<Float>(0, 0, 1)) * width
            let root = radial * radius * 0.27, tip = radial * radius
            let quad = [root - chord - depth, root + chord + depth, tip + chord + depth, tip - chord - depth]
            let normal = simd_normalize(simd_cross(quad[1] - quad[0], quad[3] - quad[0]))
            blades.addTriangles(quad, normals: Array(repeating: normal, count: 4), indices: [0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2])
        }
        hub.addChild(try Self.part("Fan blades", blades, materials.fanBlade))
        var spinner = MeshBuilder()
        let k = radius / 0.74
        spinner.addLoft([(z: -0.38 * k, radius: 0.01, y: 0), (z: -0.2 * k, radius: 0.15 * k, y: 0), (z: 0.05 * k, radius: 0.22 * k, y: 0)],
                        scaleY: 1, segments: 16)
        hub.addChild(try Self.part("Spinner", spinner, materials.engineInlet))
        return hub
    }

    /// A propeller: spinner and flat blades, pitched slightly, turning about the engine axis.
    private func addPropeller(_ materials: MaterialLibrary, hub position: SIMD3<Float>, radius: Float, blades count: Int,
                              spinnerRadius: Float) throws {
        let hub = Entity()
        var blades = MeshBuilder()
        for index in 0..<max(count, 2) {
            let angle = Float(index) / Float(max(count, 2)) * 2 * .pi
            let rotation = simd_quatf(angle: angle, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: 0.35, axis: SIMD3(0, 1, 0))
            blades.addBox(center: SIMD3(0, radius * 0.55, 0), size: SIMD3(radius * 0.12, radius * 0.9, 0.025),
                          rotation: rotation, pivot: .zero)
        }
        hub.addChild(try Self.part("Propeller blades", blades, materials.engineInlet))
        var spinner = MeshBuilder()
        spinner.addLoft([(z: -spinnerRadius * 1.6, radius: 0.01, y: 0), (z: -spinnerRadius * 0.8, radius: spinnerRadius * 0.75, y: 0),
                         (z: 0.1, radius: spinnerRadius, y: 0)], scaleY: 1, segments: 16)
        hub.addChild(try Self.part("Spinner", spinner, materials.engine))
        try addRotor(hub, at: position)
    }

    private func addRotor(_ rotor: Entity, at position: SIMD3<Float>) throws {
        rotor.position = position
        root.addChild(rotor)
        rotors.append(rotor)
        rotorAngles.append(Float(rotors.count) * 0.7)
    }

    /// The afterburner flame: an orange glow disc in the nozzle, shown at reheat thrust.
    private func afterburner(at position: SIMD3<Float>) throws -> ModelEntity {
        let flame = try light("Afterburner", at: position + SIMD3(0, 0, 0.6), color: SIMD3(1, 0.55, 0.15), size: 1.6)
        flame.isEnabled = false
        return flame
    }

    /// A movable surface (flap, aileron, elevator, rudder, spoiler) whose entity origin sits on its hinge line.
    /// For horizontal surfaces a positive angle moves the trailing edge down on either side.
    private func hinged(_ name: String, _ material: any Material, _ planform: Planform, span: ClosedRange<Float>,
                        chordRange: ClosedRange<Float>, side: Float, axis spanAxis: MeshBuilder.SpanAxis = .horizontal) throws -> Hinged {
        func hinge(_ s: Float) -> SIMD3<Float> {
            (planform.leadingEdge(s) + SIMD3(0, 0, planform.chord(s) * chordRange.lowerBound)).mirrored(side)
        }
        let hingeRoot = hinge(span.lowerBound)
        var builder = MeshBuilder()
        builder.addSurface(planform, span: span, chordRange: chordRange, side: side, axis: spanAxis, offset: -hingeRoot)
        let entity = try Self.part("\(name) \(side < 0 ? "left" : "right")", builder, material)
        entity.position = hingeRoot
        root.addChild(entity)
        var hingeAxis = simd_normalize(hinge(span.upperBound) - hingeRoot)
        if spanAxis == .horizontal && hingeAxis.x < 0 { hingeAxis = -hingeAxis }
        return Hinged(entity: entity, axis: hingeAxis)
    }

    /// A gear leg from its attachment point down to the axle, with `wheels` tires side by side in `rows`
    /// rows (the 747's four-wheel trucks). Its entity origin is the attachment point, where it folds.
    private func gearLeg(_ name: String, _ materials: MaterialLibrary, top: SIMD3<Float>, axle: SIMD3<Float>, wheelRadius: Float,
                         wheels: Int, rows: Int, foldAxis: SIMD3<Float>) throws -> Hinged {
        let foot = axle - top
        let tireWidth = wheelRadius * 0.6
        let spacing = wheels > 1 ? wheelRadius * 1.6 : 0
        var strut = MeshBuilder()
        strut.addCylinder(from: .zero, to: foot, radius: max(wheelRadius * 0.22, 0.04), segments: 12)
        var tires = MeshBuilder()
        for row in 0..<rows {
            let rowZ = rows > 1 ? (Float(row) - 0.5) * wheelRadius * 2.4 : 0
            let center = foot + SIMD3(0, 0, rowZ)
            if wheels > 1 || rows > 1 {
                strut.addCylinder(from: center - SIMD3(spacing / 2, 0, 0), to: center + SIMD3(spacing / 2, 0, 0),
                                  radius: max(wheelRadius * 0.14, 0.03), segments: 10)
            }
            for index in 0..<wheels {
                let offset = wheels > 1 ? (Float(index) - Float(wheels - 1) / 2) * spacing : 0
                tires.addCylinder(from: center + SIMD3(offset - tireWidth / 2, 0, 0), to: center + SIMD3(offset + tireWidth / 2, 0, 0),
                                  radius: wheelRadius, segments: 24, capped: true)
            }
        }
        if rows > 1 {
            strut.addCylinder(from: foot - SIMD3(0, 0, wheelRadius * 1.2), to: foot + SIMD3(0, 0, wheelRadius * 1.2),
                              radius: max(wheelRadius * 0.14, 0.03), segments: 10)
        }
        let leg = Entity()
        leg.name = name
        leg.position = top
        leg.addChild(try Self.part("\(name) strut", strut, materials.engine))
        leg.addChild(try Self.part("\(name) tires", tires, materials.tire))
        root.addChild(leg)
        return Hinged(entity: leg, axis: simd_normalize(foldAxis))
    }

    /// A light: a small lens plus a camera-facing glow that keeps it visible from far away at night.
    private func light(_ name: String, at position: SIMD3<Float>, color: SIMD3<Float>, size: Float) throws -> ModelEntity {
        let tint = UIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        var material = UnlitMaterial(color: tint)
        material.color = .init(tint: tint, texture: .init(try Self.glowTexture()))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        let glow = ModelEntity(mesh: .generatePlane(width: size, height: size), materials: [material])
        glow.name = name
        glow.position = position
        glow.components.set(BillboardComponent())
        glow.components.set(DynamicLightShadowComponent(castsShadow: false))
        root.addChild(glow)
        return glow
    }

    private static var cachedGlow: TextureResource?

    /// A soft round glow, shared by every exterior light.
    private static func glowTexture() throws -> TextureResource {
        if let cachedGlow { return cachedGlow }
        let image = try Sky.drawImage(size: 64) { context, size in
            let center = CGPoint(x: size / 2, y: size / 2)
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: [UIColor.white.cgColor, UIColor(white: 1, alpha: 0.5).cgColor,
                                                     UIColor(white: 1, alpha: 0).cgColor] as CFArray,
                                            locations: [0, 0.15, 1]) else { throw SkyError.imageCreation }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size / 2, options: [])
        }
        let texture = try TextureResource(image: image, withName: "Light glow", options: .init(semantic: .color))
        cachedGlow = texture
        return texture
    }

    static func part(_ name: String, _ builder: MeshBuilder, _ material: any Material) throws -> ModelEntity {
        let entity = ModelEntity(mesh: try builder.makeMesh(name: name), materials: [material])
        entity.name = name
        return entity
    }
}
