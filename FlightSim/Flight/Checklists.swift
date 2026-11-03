import Foundation

/// What a checklist item can look at to decide whether it is done.
struct ChecklistContext: Sendable {
    var telemetry: Telemetry
    var controls: FlightControls
    var flapDetent: Int
    var speedbrakeArmed: Bool
    var autobrake: AutobrakeSetting
    var autopilot: Autopilot
    var lights: ExteriorLights
    var hasRoute: Bool
    var fieldElevationFeet: Double
}

/// One challenge and response line, e.g. "Flaps — 5".
struct ChecklistItem: Identifiable, Sendable {
    let challenge: String
    let response: String
    /// Checks the aircraft state. Items without one ("Fuel — CHECK") are ticked by the pilot.
    let isSatisfied: (@Sendable (ChecklistContext) -> Bool)?

    var id: String { challenge + response }

    init(_ challenge: String, _ response: String, _ isSatisfied: (@Sendable (ChecklistContext) -> Bool)? = nil) {
        self.challenge = challenge
        self.response = response
        self.isSatisfied = isSatisfied
    }
}

struct Checklist: Identifiable, Sendable {
    let phase: FlightPhase
    let items: [ChecklistItem]
    var id: FlightPhase { phase }
    var title: String { phase.rawValue }
}

/// The pilot's manual ticks, kept per item for the whole flight.
struct ChecklistProgress: Equatable, Sendable {
    private(set) var ticked: Set<String> = []

    mutating func toggle(_ item: ChecklistItem) {
        if ticked.contains(item.id) { ticked.remove(item.id) } else { ticked.insert(item.id) }
    }

    func isDone(_ item: ChecklistItem, _ context: ChecklistContext) -> Bool {
        ticked.contains(item.id) || item.isSatisfied?(context) == true
    }

    func completedCount(_ checklist: Checklist, _ context: ChecklistContext) -> Int {
        checklist.items.filter { isDone($0, context) }.count
    }
}

/// Normal checklists in the Boeing style, built for the flown aircraft: items for systems it lacks (retractable
/// gear, speedbrake, autobrake, reversers) are left out and flap items name its own detents.
enum Checklists {
    static func all(for aircraft: AircraftProfile) -> [Checklist] {
        let takeoffFlaps = aircraft.takeoffFlapDetent
        let landingFlaps = aircraft.landingFlapDetent
        let gear = aircraft.retractableGear
        let speedbrake = aircraft.hasSpeedbrake
        let autobrake = aircraft.hasAutobrake
        func items(_ list: [ChecklistItem?]) -> [ChecklistItem] { list.compactMap { $0 } }
        return [
            Checklist(phase: .beforeTakeoff, items: items([
                ChecklistItem("Flaps", aircraft.flaps[takeoffFlaps].label, { $0.flapDetent == takeoffFlaps }),
                ChecklistItem("Stabilizer trim", "SET", { abs($0.controls.pitchTrim) < 0.5 }),
                speedbrake ? ChecklistItem("Speedbrake", "DOWN", { $0.controls.speedbrake == 0 && !$0.speedbrakeArmed }) : nil,
                autobrake ? ChecklistItem("Autobrake", "RTO", { $0.autobrake == .rto }) : nil,
                ChecklistItem("Autothrottle", "ARM", { $0.autopilot.autothrottleArmed }),
                ChecklistItem("MCP altitude", "SET", { $0.autopilot.mcp.altitudeFeet > $0.fieldElevationFeet + 1_000 }),
                ChecklistItem("Exterior lights", "ON", { $0.lights.strobes }),
            ])),
            Checklist(phase: .takeoff, items: items([
                ChecklistItem("Parking brake", "RELEASED", { !$0.controls.parkingBrake }),
                ChecklistItem("Thrust", "TAKEOFF", { $0.controls.throttle > 0.9 }),
                ChecklistItem("Rotate", "at \(Int(aircraft.vr)) kt", { $0.telemetry.calibratedAirspeedKnots > aircraft.vr }),
                gear ? ChecklistItem("Positive rate", "GEAR UP", { !$0.controls.gearDown }) : nil,
            ])),
            Checklist(phase: .climb, items: items([
                gear ? ChecklistItem("Landing gear", "UP", { $0.telemetry.gearPosition < 0.01 }) : nil,
                ChecklistItem("Flaps", aircraft.flaps[0].label, { $0.flapDetent == 0 }),
                ChecklistItem("Autopilot", "ENGAGED", { $0.autopilot.autopilotEngaged }),
                autobrake ? ChecklistItem("Autobrake", "OFF", { $0.autobrake == .off }) : nil,
                ChecklistItem("Speed", "250 kt below 10,000 ft", {
                    $0.telemetry.altitudeMSLFeet > 10_000 || $0.telemetry.calibratedAirspeedKnots < 260
                }),
            ])),
            Checklist(phase: .cruise, items: [
                ChecklistItem("Altitude", "LEVEL", { $0.autopilot.pitchMode == .altitudeHold && $0.autopilot.autopilotEngaged }),
                ChecklistItem("Autothrottle", "MCP SPD", { $0.autopilot.thrustMode == .speed }),
                ChecklistItem("Navigation", "LNAV", { $0.autopilot.rollMode == .lnav }),
                ChecklistItem("Fuel", "CHECK"),
            ]),
            Checklist(phase: .descent, items: items([
                ChecklistItem("MCP altitude", "SET lower", { $0.autopilot.mcp.altitudeFeet < $0.telemetry.altitudeMSLFeet - 1_000 }),
                ChecklistItem("Landing runway", "SET", { $0.hasRoute }),
                autobrake ? ChecklistItem("Autobrake", "SET", { ($0.autobrake.decelerationFPS2 ?? 0) > 0 }) : nil,
                ChecklistItem("Approach briefing", "COMPLETE"),
            ])),
            Checklist(phase: .approach, items: [
                ChecklistItem("Speed", "250 kt below 10,000 ft", {
                    $0.telemetry.altitudeMSLFeet > 10_000 || $0.telemetry.calibratedAirspeedKnots < 260
                }),
                ChecklistItem("Flaps", aircraft.flaps[takeoffFlaps].label, { $0.flapDetent >= takeoffFlaps }),
                ChecklistItem("Approach mode", "ARMED", {
                    $0.autopilot.localizerArmed || $0.autopilot.rollMode == .localizer
                }),
                ChecklistItem("Landing lights", "ON", { $0.lights.landing }),
            ]),
            Checklist(phase: .landing, items: items([
                gear ? ChecklistItem("Landing gear", "DOWN, 3 green", { $0.telemetry.gearPosition > 0.99 }) : nil,
                speedbrake ? ChecklistItem("Speedbrake", "ARMED", { $0.speedbrakeArmed }) : nil,
                ChecklistItem("Flaps", aircraft.flaps[landingFlaps].label, { $0.flapDetent >= landingFlaps }),
                autobrake ? ChecklistItem("Autobrake", "SET", { ($0.autobrake.decelerationFPS2 ?? 0) > 0 }) : nil,
            ])),
            Checklist(phase: .afterLanding, items: items([
                aircraft.hasReversers ? ChecklistItem("Reversers", "STOWED", { !$0.controls.reversers }) : nil,
                speedbrake ? ChecklistItem("Speedbrake", "DOWN", { $0.controls.speedbrake == 0 }) : nil,
                ChecklistItem("Flaps", aircraft.flaps[0].label, { $0.flapDetent == 0 }),
                autobrake ? ChecklistItem("Autobrake", "OFF", { $0.autobrake == .off }) : nil,
                ChecklistItem("Parking brake", "SET", { $0.controls.parkingBrake }),
            ])),
        ]
    }

    static func checklist(for phase: FlightPhase, aircraft: AircraftProfile) -> Checklist {
        guard let checklist = all(for: aircraft).first(where: { $0.phase == phase }) else {
            preconditionFailure("Every flight phase has a checklist; \(phase) is missing")
        }
        return checklist
    }
}
