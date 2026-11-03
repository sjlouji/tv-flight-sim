import Foundation
import Testing
@testable import FlightSim

@Suite struct AircraftSystemsTests {
    private let boeing = AircraftProfile.profile(.b737)
    private let cessna = AircraftProfile.profile(.c172)

    private func rolling(_ speed: Double, onGround: Bool = true) -> Telemetry {
        var t = Telemetry()
        t.weightOnWheels = onGround
        t.groundSpeedKnots = speed
        t.calibratedAirspeedKnots = speed
        t.radioAltitudeFeet = onGround ? 0 : 1_000
        return t
    }

    private func landed(_ systems: inout AircraftSystems, speedbrakeArmed: Bool = true) -> FlightControls {
        var pilot = FlightControls()
        pilot.throttle = 0
        _ = systems.update(telemetry: rolling(140, onGround: false), pilot: pilot, speedbrakeArmed: speedbrakeArmed, deltaTime: 0.1)
        return systems.update(telemetry: rolling(135), pilot: pilot, speedbrakeArmed: speedbrakeArmed, deltaTime: 0.1).0
    }

    @Test func armedSpeedbrakeDeploysOnTheLandingRollAndStowsWithThrust() {
        var systems = AircraftSystems(aircraft: boeing, phase: .landing)
        #expect(landed(&systems).speedbrake == 1)
        var pilot = FlightControls()
        pilot.throttle = 0.5
        #expect(systems.update(telemetry: rolling(120), pilot: pilot, speedbrakeArmed: true, deltaTime: 0.1).0.speedbrake == 0)
    }

    @Test func autobrakeBrakesUntilThePilotTakesOver() {
        var systems = AircraftSystems(aircraft: boeing, phase: .landing)
        systems.autobrake = .three
        var controls = landed(&systems)
        // Slowing 2 kt/s (3.4 ft/s²), less than the 7.2 ft/s² autobrake 3 aims for, so it presses harder.
        for speed in stride(from: 134.0, to: 100, by: -0.2) {
            controls = systems.update(telemetry: rolling(speed), pilot: FlightControls(), speedbrakeArmed: true, deltaTime: 0.1).0
        }
        #expect(systems.autobrakeActive)
        #expect(controls.brakes > 0.1)
        var pilot = FlightControls()
        pilot.brakes = 0.6
        let (_, events) = systems.update(telemetry: rolling(99), pilot: pilot, speedbrakeArmed: true, deltaTime: 0.1)
        #expect(!systems.autobrakeActive)
        #expect(events.contains(.message("Autobrake disarmed")))
    }

    @Test func rejectedTakeoffBrakesFully() {
        var systems = AircraftSystems(aircraft: boeing)
        systems.autobrake = .rto
        var pilot = FlightControls()
        pilot.throttle = 0.95
        _ = systems.update(telemetry: rolling(100), pilot: pilot, speedbrakeArmed: false, deltaTime: 0.1)
        pilot.throttle = 0
        let (controls, events) = systems.update(telemetry: rolling(101), pilot: pilot, speedbrakeArmed: false, deltaTime: 0.1)
        #expect(controls.brakes == 1)
        #expect(controls.speedbrake == 1)
        #expect(events.contains(.message("RTO autobrake")))
    }

    @Test func altitudeCalloutsCountDownOnTheApproach() {
        var systems = AircraftSystems(aircraft: boeing, phase: .landing)
        var pilot = FlightControls()
        pilot.gearDown = true
        var heard: [Callout] = []
        for height in stride(from: 1_100.0, through: 0, by: -5) {
            var t = rolling(140, onGround: false)
            t.radioAltitudeFeet = height
            t.verticalSpeedFeetPerMinute = -700
            for case .callout(let callout) in systems.update(telemetry: t, pilot: pilot, speedbrakeArmed: true, deltaTime: 0.1).1 {
                heard.append(callout)
            }
        }
        #expect(heard == [.oneThousand, .fiveHundred, .minimums, .oneHundred, .fifty, .forty, .thirty, .twenty, .ten])
    }

    private func takeoffCallouts(_ aircraft: AircraftProfile) -> (FlightPhase, [Callout]) {
        var systems = AircraftSystems(aircraft: aircraft)
        var pilot = FlightControls()
        pilot.throttle = 0.95
        var heard: [Callout] = []
        for speed in stride(from: 0.0, through: aircraft.vr + 5, by: 1) {
            for case .callout(let callout) in systems.update(telemetry: rolling(speed), pilot: pilot, speedbrakeArmed: false, deltaTime: 0.1).1 {
                heard.append(callout)
            }
        }
        return (systems.phase, heard)
    }

    @Test func takeoffPhaseAndSpeedCallouts() {
        let (phase, heard) = takeoffCallouts(boeing)
        #expect(phase == .takeoff)
        #expect(heard == [.eightyKnots, .v1, .rotate])
    }

    @Test func lightAircraftSkipTheEightyKnotCallAndRotateAtTheirOwnSpeed() {
        #expect(takeoffCallouts(cessna).1 == [.v1, .rotate])
    }

    @Test(arguments: AircraftType.allCases)
    func everyPhaseHasAChecklist(type: AircraftType) {
        for phase in FlightPhase.allCases {
            #expect(!Checklists.checklist(for: phase, aircraft: .profile(type)).items.isEmpty)
        }
    }

    @Test func checklistsLeaveOutSystemsTheAircraftLacks() {
        let items = FlightPhase.allCases.flatMap { Checklists.checklist(for: $0, aircraft: cessna).items.map(\.challenge) }
        #expect(!items.contains("Landing gear"))
        #expect(!items.contains("Speedbrake"))
        #expect(!items.contains("Autobrake"))
        let landingFlaps = Checklists.checklist(for: .landing, aircraft: cessna).items.first { $0.challenge == "Flaps" }
        #expect(landingFlaps?.response == "30°")
    }

    @Test func checklistItemsTickFromTheAircraftState() {
        var controls = FlightControls()
        controls.gearDown = true
        var telemetry = Telemetry()
        telemetry.gearPosition = 1
        let context = ChecklistContext(telemetry: telemetry, controls: controls, flapDetent: 7, speedbrakeArmed: true,
                                       autobrake: .two, autopilot: Autopilot(), lights: ExteriorLights(), hasRoute: true,
                                       fieldElevationFeet: 13)
        let landing = Checklists.checklist(for: .landing, aircraft: boeing)
        var progress = ChecklistProgress()
        #expect(progress.completedCount(landing, context) == landing.items.count)
        let fuel = Checklists.checklist(for: .cruise, aircraft: boeing).items.first { $0.challenge == "Fuel" }!
        #expect(!progress.isDone(fuel, context))
        progress.toggle(fuel)
        #expect(progress.isDone(fuel, context))
    }
}
