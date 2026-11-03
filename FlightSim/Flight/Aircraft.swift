import Foundation
import simd

/// The aircraft the app offers.
enum AircraftType: String, CaseIterable, Identifiable, Sendable {
    case b737, b747, b787, a320, c130, c172, dhc6, global5000, f4

    var id: String { rawValue }
}

enum EngineKind: Sendable {
    case turbofan, turbojet, turboprop, piston
}

enum AirframeKind: Sendable {
    /// Swept wing, engines under the wing (737, 747, 787, A320).
    case jetAirliner
    /// Swept wing, engines on the rear fuselage, T-tail (Global 5000).
    case businessJet
    /// Straight high wing with propellers on the wing (C-130, Twin Otter).
    case highWingTurboprop
    /// High wing with struts and a propeller in the nose (Cessna 172).
    case lightSingle
    /// Swept low wing, engines in the fuselage, tandem canopy (F-4).
    case fighter
}

/// One flap lever position: its cockpit label and the JSBSim flap command (0...1) that selects it.
/// JSBSim's flap systems scale the command linearly to the model's largest flap angle, so the command is
/// the detent's angle divided by that maximum.
struct FlapDetent: Equatable, Sendable {
    let label: String
    let lever: Double
}

extension [FlapDetent] {
    /// Detents from flap angles in degrees, for a model whose full command is `maxDegrees`.
    static func degrees(_ labels: [String], _ angles: [Double], max maxDegrees: Double) -> [FlapDetent] {
        zip(labels, angles).map { FlapDetent(label: $0, lever: $1 / maxDegrees) }
    }

    /// Detents evenly spread over the command range.
    static func even(_ labels: [String]) -> [FlapDetent] {
        labels.enumerated().map { FlapDetent(label: $1, lever: Double($0) / Double(labels.count - 1)) }
    }
}

/// What the simulator needs to know about an aircraft beyond its JSBSim model: lever detents, speeds,
/// systems, size and the figures the aircraft page shows. Speeds and figures are the published ones.
struct AircraftProfile: Identifiable, Sendable {
    let type: AircraftType
    let name: String
    let summary: String
    let jsbsimModel: String
    let engineKind: EngineKind
    let engineDescription: String
    let airframe: AirframeKind
    let flaps: [FlapDetent]
    let takeoffFlapDetent: Int
    let landingFlapDetent: Int
    let v1: Double
    let vr: Double
    let v2: Double
    let approachSpeed: Double
    /// Calibrated airspeed in the en-route climb (10,000 to 26,000 ft) and at cruise altitude.
    let climbSpeed: Double
    let cruiseSpeed: Double
    /// Maximum operating speed (overspeed warning), knots calibrated.
    let maxSpeed: Double
    let ceiling: Double
    let retractableGear: Bool
    let hasReversers: Bool
    let hasSpeedbrake: Bool
    /// Has a passenger cabin with seats to view from.
    let hasCabin: Bool
    let carrierCapable: Bool
    /// Real dimensions, meters, for the drawn fuselage and the aircraft page.
    let lengthMeters: Float
    let wingspanMeters: Float
    let heightMeters: Float
    let fuselageRadius: Float
    /// How far the pilot's eye sits behind the nose tip, meters (places the drawn fuselage around the eye point).
    let eyeBehindNose: Float
    /// How far the eye sits above the fuselage centerline, in fuselage radii (places the drawn fuselage vertically).
    let eyeAboveCenter: Float
    /// The 747's raised forward fuselage around its upper deck.
    let upperDeck: Bool
    /// Where the captain's eye really is (model meters around the CG), for the JSBSim files whose eye point is
    /// wrong: the 787 and F-4 files put it at the wing or behind the CG, the Cessna's on the centerline instead
    /// of the left seat, and several others put it a story or more too high above the wheels. The physics does not use the eye point, so only the view changes.
    let eyeOverride: SIMD3<Float>?
    let livery: SIMD3<Float>
    /// Static thrust of one engine at takeoff power, pounds (sets how loud full power sounds).
    let maxThrustPounds: Double
    let capacity: String
    let maxTakeoffWeightKg: Int
    let rangeKm: Int
    let cruiseDescription: String
    /// True airspeed at cruise, knots (for the route's estimated flight time).
    let cruiseTrueAirspeed: Double

    var id: AircraftType { type }
    /// Airliners and business jets have autobrakes; propeller aircraft and the F-4 are braked by hand.
    var hasAutobrake: Bool { airframe == .jetAirliner || airframe == .businessJet }
    var takeoffFlaps: Double { flaps[takeoffFlapDetent].lever }
    var landingFlaps: Double { flaps[landingFlapDetent].lever }

    /// Calibrated airspeed for level flight at an altitude: the faster of climb and cruise speed, capped at
    /// 250 kt below 10,000 ft; then the climb speed, and the cruise speed above 26,000 ft.
    func speed(atAltitude feet: Double) -> Double {
        if feet < 10_000 { return min(250, max(climbSpeed, cruiseSpeed)) }
        return feet < 26_000 ? climbSpeed : cruiseSpeed
    }

    /// The in-flight start altitudes this aircraft can use.
    var startAltitudes: [Double] {
        Self.allStartAltitudes.filter { $0 <= ceiling - 2_000 }
    }

    static let allStartAltitudes: [Double] = [3_000, 6_500, 10_000, 18_000, 24_000, 35_000, 41_000]

    static func profile(_ type: AircraftType) -> AircraftProfile {
        guard let profile = all.first(where: { $0.type == type }) else {
            preconditionFailure("Every aircraft type has a profile; \(type) is missing")
        }
        return profile
    }

    static let all: [AircraftProfile] = [
        AircraftProfile(
            type: .b737, name: "Boeing 737-300", summary: "Short to medium haul twin jet", jsbsimModel: "737",
            engineKind: .turbofan, engineDescription: "Two CFM56-3 turbofans", airframe: .jetAirliner,
            flaps: .even(["UP", "1", "2", "5", "10", "15", "25", "30", "40"]), takeoffFlapDetent: 3, landingFlapDetent: 7,
            v1: 135, vr: 140, v2: 150, approachSpeed: 145, climbSpeed: 290, cruiseSpeed: 270, maxSpeed: 340, ceiling: 37_000,
            retractableGear: true, hasReversers: true, hasSpeedbrake: true, hasCabin: true, carrierCapable: false,
            lengthMeters: 33.4, wingspanMeters: 28.9, heightMeters: 11.1, fuselageRadius: 1.88, eyeBehindNose: 3.05, eyeAboveCenter: 0.61, upperDeck: false, eyeOverride: nil,
            livery: SIMD3(0.05, 0.13, 0.32), maxThrustPounds: 23_500, capacity: "149 passengers", maxTakeoffWeightKg: 62_800, rangeKm: 4_200,
            cruiseDescription: "Mach 0.74 at FL350", cruiseTrueAirspeed: 430),
        AircraftProfile(
            type: .b747, name: "Boeing 747-400", summary: "Four-engine long-haul jumbo jet", jsbsimModel: "B747",
            engineKind: .turbofan, engineDescription: "Four GE CF6-80C2 turbofans", airframe: .jetAirliner,
            // Flaps 25 for landing: JSBSim's 747 cannot hold a steady approach with flaps 30.
            flaps: .degrees(["UP", "1", "5", "10", "20", "25", "30"], [0, 1, 5, 10, 20, 25, 30], max: 30),
            takeoffFlapDetent: 3, landingFlapDetent: 5,
            v1: 150, vr: 160, v2: 170, approachSpeed: 155, climbSpeed: 310, cruiseSpeed: 290, maxSpeed: 365, ceiling: 45_000,
            retractableGear: true, hasReversers: true, hasSpeedbrake: true, hasCabin: true, carrierCapable: false,
            lengthMeters: 70.7, wingspanMeters: 64.4, heightMeters: 19.4, fuselageRadius: 3.25, eyeBehindNose: 7.2, eyeAboveCenter: 1.3, upperDeck: true, eyeOverride: nil,
            livery: SIMD3(0.55, 0.06, 0.08), maxThrustPounds: 57_000, capacity: "416 passengers", maxTakeoffWeightKg: 396_890, rangeKm: 13_450,
            cruiseDescription: "Mach 0.85 at FL350", cruiseTrueAirspeed: 490),
        AircraftProfile(
            type: .b787, name: "Boeing 787-8", summary: "Composite long-haul twin jet", jsbsimModel: "787-8",
            engineKind: .turbofan, engineDescription: "Two Rolls-Royce Trent 1000 turbofans", airframe: .jetAirliner,
            flaps: .degrees(["UP", "1", "5", "15", "20", "25", "30"], [0, 1, 5, 15, 20, 25, 30], max: 35),
            takeoffFlapDetent: 2, landingFlapDetent: 6,
            v1: 140, vr: 148, v2: 158, approachSpeed: 145, climbSpeed: 300, cruiseSpeed: 265, maxSpeed: 350, ceiling: 43_000,
            retractableGear: true, hasReversers: true, hasSpeedbrake: true, hasCabin: true, carrierCapable: false,
            lengthMeters: 56.7, wingspanMeters: 60.1, heightMeters: 16.9, fuselageRadius: 2.88, eyeBehindNose: 3.3,
            eyeAboveCenter: 0.61, upperDeck: false, eyeOverride: SIMD3(-0.53, 2.0, -21.3),
            livery: SIMD3(0.10, 0.30, 0.60), maxThrustPounds: 64_000, capacity: "248 passengers", maxTakeoffWeightKg: 227_930, rangeKm: 13_530,
            cruiseDescription: "Mach 0.85 at FL390", cruiseTrueAirspeed: 488),
        AircraftProfile(
            type: .a320, name: "Airbus A320", summary: "Short to medium haul twin jet", jsbsimModel: "A320",
            engineKind: .turbofan, engineDescription: "Two CFM56-5 turbofans", airframe: .jetAirliner,
            // JSBSim's A320 needs about 20 kt more than the real aircraft's 138 kt to hold a steady approach.
            flaps: .degrees(["0", "1", "2", "3", "FULL"], [0, 10, 15, 20, 35], max: 40), takeoffFlapDetent: 1, landingFlapDetent: 4,
            v1: 140, vr: 145, v2: 150, approachSpeed: 160, climbSpeed: 290, cruiseSpeed: 270, maxSpeed: 350, ceiling: 39_000,
            retractableGear: true, hasReversers: true, hasSpeedbrake: true, hasCabin: true, carrierCapable: false,
            lengthMeters: 37.6, wingspanMeters: 34.1, heightMeters: 11.8, fuselageRadius: 1.98, eyeBehindNose: 3.05, eyeAboveCenter: 0.61, upperDeck: false, eyeOverride: SIMD3(-0.76, 1.8, -15.04),
            livery: SIMD3(0.04, 0.35, 0.30), maxThrustPounds: 25_000, capacity: "180 passengers", maxTakeoffWeightKg: 78_000, rangeKm: 6_150,
            cruiseDescription: "Mach 0.78 at FL370", cruiseTrueAirspeed: 447),
        AircraftProfile(
            type: .c130, name: "Lockheed C-130 Hercules", summary: "Four-engine military transport", jsbsimModel: "C130",
            engineKind: .turboprop, engineDescription: "Four Allison T56 turboprops", airframe: .highWingTurboprop,
            flaps: .even(["UP", "25%", "50%", "75%", "100%"]), takeoffFlapDetent: 2, landingFlapDetent: 4,
            v1: 105, vr: 115, v2: 125, approachSpeed: 130, climbSpeed: 200, cruiseSpeed: 190, maxSpeed: 250, ceiling: 33_000,
            retractableGear: true, hasReversers: false, hasSpeedbrake: false, hasCabin: false, carrierCapable: false,
            lengthMeters: 29.8, wingspanMeters: 40.4, heightMeters: 11.6, fuselageRadius: 2.2, eyeBehindNose: 2.7, eyeAboveCenter: 0.45, upperDeck: false, eyeOverride: SIMD3(-0.61, 1.2, -12.51),
            livery: SIMD3(0.30, 0.34, 0.28), maxThrustPounds: 10_000, capacity: "92 troops", maxTakeoffWeightKg: 70_300, rangeKm: 3_800,
            cruiseDescription: "290 kt at FL220", cruiseTrueAirspeed: 290),
        AircraftProfile(
            type: .c172, name: "Cessna 172P Skyhawk", summary: "Single-engine four-seat trainer", jsbsimModel: "c172p",
            engineKind: .piston, engineDescription: "One Lycoming O-320 piston engine", airframe: .lightSingle,
            flaps: .even(["UP", "10°", "20°", "30°"]), takeoffFlapDetent: 0, landingFlapDetent: 3,
            v1: 50, vr: 55, v2: 65, approachSpeed: 65, climbSpeed: 85, cruiseSpeed: 110, maxSpeed: 158, ceiling: 14_000,
            retractableGear: false, hasReversers: false, hasSpeedbrake: false, hasCabin: false, carrierCapable: false,
            lengthMeters: 8.2, wingspanMeters: 11.0, heightMeters: 2.7, fuselageRadius: 0.62, eyeBehindNose: 1.9, eyeAboveCenter: 0.35, upperDeck: false, eyeOverride: SIMD3(-0.28, 0.29, -0.1),
            livery: SIMD3(0.12, 0.30, 0.65), maxThrustPounds: 650, capacity: "3 passengers", maxTakeoffWeightKg: 1_089, rangeKm: 1_270,
            cruiseDescription: "120 kt at 6,500 ft", cruiseTrueAirspeed: 120),
        AircraftProfile(
            type: .dhc6, name: "de Havilland Twin Otter", summary: "Twin turboprop short-field commuter", jsbsimModel: "DHC6",
            engineKind: .turboprop, engineDescription: "Two Pratt & Whitney PT6A-27 turboprops", airframe: .highWingTurboprop,
            // Flaps 20 at 70 kt for landing: JSBSim's Twin Otter cannot hold a steady approach with full flaps.
            flaps: .degrees(["UP", "10", "20", "37.5"], [0, 10, 20, 37.5], max: 40), takeoffFlapDetent: 1, landingFlapDetent: 2,
            v1: 65, vr: 70, v2: 80, approachSpeed: 70, climbSpeed: 120, cruiseSpeed: 140, maxSpeed: 170, ceiling: 25_000,
            retractableGear: false, hasReversers: false, hasSpeedbrake: false, hasCabin: true, carrierCapable: false,
            lengthMeters: 15.8, wingspanMeters: 19.8, heightMeters: 5.9, fuselageRadius: 0.85, eyeBehindNose: 1.8, eyeAboveCenter: 0.45, upperDeck: false, eyeOverride: SIMD3(-0.46, -0.32, -3.0),
            livery: SIMD3(0.75, 0.15, 0.10), maxThrustPounds: 2_500, capacity: "19 passengers", maxTakeoffWeightKg: 5_670, rangeKm: 1_480,
            cruiseDescription: "150 kt at 10,000 ft", cruiseTrueAirspeed: 150),
        AircraftProfile(
            type: .global5000, name: "Bombardier Global 5000", summary: "Long-range business jet", jsbsimModel: "global5000",
            engineKind: .turbofan, engineDescription: "Two Rolls-Royce BR710 turbofans", airframe: .businessJet,
            flaps: .degrees(["UP", "6", "16", "30"], [0, 6, 16, 30], max: 30), takeoffFlapDetent: 1, landingFlapDetent: 3,
            v1: 120, vr: 128, v2: 135, approachSpeed: 125, climbSpeed: 290, cruiseSpeed: 250, maxSpeed: 340, ceiling: 51_000,
            retractableGear: true, hasReversers: true, hasSpeedbrake: true, hasCabin: true, carrierCapable: false,
            lengthMeters: 29.5, wingspanMeters: 28.7, heightMeters: 7.7, fuselageRadius: 1.35, eyeBehindNose: 2.6, eyeAboveCenter: 0.45, upperDeck: false, eyeOverride: SIMD3(-0.5, -0.21, -18.02),
            livery: SIMD3(0.12, 0.12, 0.14), maxThrustPounds: 14_750, capacity: "17 passengers", maxTakeoffWeightKg: 41_950, rangeKm: 9_630,
            cruiseDescription: "Mach 0.85 at FL450", cruiseTrueAirspeed: 488),
        AircraftProfile(
            type: .f4, name: "F-4N Phantom II", summary: "Carrier-based fighter with afterburners", jsbsimModel: "F4N",
            engineKind: .turbojet, engineDescription: "Two GE J79 afterburning turbojets", airframe: .fighter,
            flaps: .even(["UP", "HALF", "FULL"]), takeoffFlapDetent: 1, landingFlapDetent: 2,
            v1: 150, vr: 165, v2: 180, approachSpeed: 145, climbSpeed: 350, cruiseSpeed: 330, maxSpeed: 710, ceiling: 55_000,
            retractableGear: true, hasReversers: false, hasSpeedbrake: true, hasCabin: false, carrierCapable: true,
            lengthMeters: 19.2, wingspanMeters: 11.7, heightMeters: 5.0, fuselageRadius: 0.95, eyeBehindNose: 4.2, eyeAboveCenter: 1.0, upperDeck: false, eyeOverride: SIMD3(0, 0.97, -6.2),
            livery: SIMD3(0.42, 0.45, 0.48), maxThrustPounds: 17_900, capacity: "2 crew", maxTakeoffWeightKg: 28_030, rangeKm: 2_600,
            cruiseDescription: "Mach 0.86, Mach 2.2 top speed", cruiseTrueAirspeed: 500),
    ]
}

/// Geometry read from the aircraft's JSBSim file, converted to the scene's model axes: meters around the
/// center of gravity, nose toward -z, right wing toward +x, up +y. The drawn aircraft is built from this,
/// so its wheels, engines and eye point sit exactly where the physics has them.
struct AircraftGeometry: Sendable {
    struct Wheel: Sendable {
        let name: String
        /// The JSBSim gear unit index (for its compression and steering properties).
        let unit: Int
        let position: SIMD3<Float>
    }

    let eyePoint: SIMD3<Float>
    let aeroReference: SIMD3<Float>
    let wingspan: Float
    let wingArea: Float
    let wheels: [Wheel]
    /// Where each engine's thrust acts (its propeller disc or jet nozzle), in engine order.
    let engines: [SIMD3<Float>]

    /// The center of gravity's height above the bottom of the wheels, feet (where it sits on the runway).
    var groundCGHeightFeet: Double {
        Double(-(wheels.map(\.position.y).min() ?? 0)).metersToFeet
    }
}

enum AircraftDefinitionError: LocalizedError {
    case missingFile(String, Error)
    case unreadable(String, String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let model, let error): "The JSBSim file for \(model) could not be opened: \(error.localizedDescription)"
        case .unreadable(let model, let reason): "The JSBSim file for \(model) could not be read: \(reason)"
        }
    }
}

/// Reads the parts of a JSBSim aircraft file the simulator needs beyond the physics.
enum AircraftDefinition {
    static func load(_ profile: AircraftProfile, dataDirectory: URL) throws -> AircraftGeometry {
        let file = dataDirectory.appending(path: "aircraft/\(profile.jsbsimModel)/\(profile.jsbsimModel).xml")
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            Log.flight.error("Cannot open \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw AircraftDefinitionError.missingFile(profile.jsbsimModel, error)
        }
        return try parse(data, profile: profile)
    }

    static func parse(_ data: Data, profile: AircraftProfile) throws -> AircraftGeometry {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else {
            throw AircraftDefinitionError.unreadable(profile.jsbsimModel, parser.parserError?.localizedDescription ?? "invalid XML")
        }
        guard let cg = reader.locations["CG"] else { throw AircraftDefinitionError.unreadable(profile.jsbsimModel, "no CG location") }
        guard let fileEye = reader.locations["EYEPOINT"] else {
            throw AircraftDefinitionError.unreadable(profile.jsbsimModel, "no eye point")
        }
        func model(_ p: SIMD3<Double>) -> SIMD3<Float> {
            // JSBSim's structural frame: x aft, y right, z up.
            SIMD3(Float(p.y - cg.y), Float(p.z - cg.z), Float(p.x - cg.x))
        }
        // Some files (the A320's) also mark structural points as BOGEY contacts; the wheels are the lowest ones.
        let bogeys = reader.contacts.enumerated().compactMap { index, contact in
            contact.type == "BOGEY" ? AircraftGeometry.Wheel(name: contact.name, unit: index, position: model(contact.location)) : nil
        }
        let lowest = bogeys.map(\.position.y).min() ?? 0
        let wheels = bogeys.filter { $0.position.y < lowest + 0.5 }
        guard wheels.count >= 3 else { throw AircraftDefinitionError.unreadable(profile.jsbsimModel, "fewer than three wheels") }
        guard let span = reader.metrics["wingspan"], let area = reader.metrics["wingarea"] else {
            throw AircraftDefinitionError.unreadable(profile.jsbsimModel, "missing wing metrics")
        }
        guard reader.engineCount > 0, reader.thrusters.count == reader.engineCount else {
            throw AircraftDefinitionError.unreadable(profile.jsbsimModel,
                                                     "\(reader.engineCount) engines but \(reader.thrusters.count) thruster locations")
        }
        return AircraftGeometry(eyePoint: profile.eyeOverride ?? model(fileEye), aeroReference: model(reader.locations["AERORP"] ?? cg),
                                wingspan: Float(span), wingArea: Float(area), wheels: wheels,
                                engines: reader.thrusters.map(model))
    }

    /// Meters per unit for JSBSim's length units (inches when no unit is given).
    static func meters(_ unit: String?) -> Double {
        switch unit?.uppercased() {
        case "FT": 0.3048
        case "M": 1
        case "CM": 0.01
        default: 0.0254
        }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var locations: [String: SIMD3<Double>] = [:]
        var metrics: [String: Double] = [:]
        var contacts: [(type: String, name: String, location: SIMD3<Double>)] = []
        var engineCount = 0
        var thrusters: [SIMD3<Double>] = []

        private var path: [String] = []
        private var text = ""
        private var current = SIMD3<Double>.zero
        private var currentUnit: String?
        private var locationName: String?
        private var contact: (type: String, name: String)?
        private var metricUnit: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            path.append(name)
            text = ""
            switch name {
            case "location":
                current = .zero
                currentUnit = attributes["unit"]
                locationName = attributes["name"]
            case "contact":
                contact = (attributes["type"] ?? "", attributes["name"] ?? "")
            case "engine":
                engineCount += 1
            case "wingspan", "wingarea":
                metricUnit = attributes["unit"]
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
            // The element's parent: `path` still ends with this element.
            let parent = path.dropLast().last
            defer { path.removeLast(); text = "" }
            switch name {
            case "x", "y", "z":
                guard parent == "location", let value else { return }
                let scaled = value * AircraftDefinition.meters(currentUnit)
                switch name {
                case "x": current.x = scaled
                case "y": current.y = scaled
                default: current.z = scaled
                }
            case "location":
                switch parent {
                // AERORP and EYEPOINT sit in <metrics>; the CG in <mass_balance>.
                case "metrics", "mass_balance": if let locationName { locations[locationName] = current }
                case "contact": if let contact { contacts.append((contact.type, contact.name, current)) }
                case "thruster": thrusters.append(current)
                default: break
                }
            case "contact":
                contact = nil
            case "wingspan":
                if let value, parent == "metrics" { metrics[name] = value * AircraftDefinition.meters(metricUnit ?? "FT") }
            case "wingarea":
                if let value, parent == "metrics" { metrics[name] = value * (metricUnit?.uppercased() == "M2" ? 1 : 0.09290304) }
            default:
                break
            }
        }
    }
}
