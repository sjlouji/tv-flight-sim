import Testing
@testable import FlightSim

@Suite struct ControlMapperTests {
    private func press(_ mapper: inout ControlMapper, onGround: Bool = true, _ set: (inout GamepadSnapshot) -> Void) -> [CockpitEvent] {
        var pad = GamepadSnapshot()
        set(&pad)
        let events = mapper.update(with: pad, deltaTime: 1.0 / 60, onGround: onGround)
        _ = mapper.update(with: GamepadSnapshot(), deltaTime: 1.0 / 60, onGround: onGround)
        return events
    }

    @Test func flapsStepThroughTheNine737Detents() {
        var mapper = ControlMapper(aircraft: .profile(.b737), initial: FlightControls())
        #expect(mapper.flapLabel == "UP")
        for _ in 0..<3 { _ = press(&mapper) { $0.dpadDown = true } }
        #expect(mapper.flapLabel == "5")
        #expect(mapper.controls.flaps == 3.0 / 8.0)
        for _ in 0..<20 { _ = press(&mapper) { $0.dpadDown = true } }
        #expect(mapper.flapLabel == "40")
        #expect(mapper.controls.flaps == 1)
        for _ in 0..<20 { _ = press(&mapper) { $0.dpadUp = true } }
        #expect(mapper.flapLabel == "UP")
    }

    @Test func holdingAButtonDoesNotRepeatDiscreteCommands() {
        var mapper = ControlMapper(aircraft: .profile(.b737), initial: FlightControls())
        var pad = GamepadSnapshot()
        pad.dpadDown = true
        for _ in 0..<30 { _ = mapper.update(with: pad, deltaTime: 1.0 / 60, onGround: true) }
        #expect(mapper.flapLabel == "1")
    }

    @Test func gearCannotRetractOnTheGround() {
        var mapper = ControlMapper(aircraft: .profile(.b737), initial: FlightControls())
        let events = press(&mapper, onGround: true) { $0.buttonY = true }
        #expect(mapper.controls.gearDown)
        #expect(events == [.rejected("Gear can't retract on the ground")])
        _ = press(&mapper, onGround: false) { $0.buttonY = true }
        #expect(!mapper.controls.gearDown)
    }

    @Test func throttleMovesAtALimitedRateAndClamps() {
        var mapper = ControlMapper(aircraft: .profile(.b737), initial: FlightControls())
        var pad = GamepadSnapshot()
        pad.rightTrigger = 1
        _ = mapper.update(with: pad, deltaTime: 1, onGround: true)
        #expect(abs(mapper.controls.throttle - ControlMapper.throttleRatePerSecond) < 1e-9)
        for _ in 0..<10 { _ = mapper.update(with: pad, deltaTime: 1, onGround: true) }
        #expect(mapper.controls.throttle == 1)
    }

    @Test func reversersNeedGroundAndIdle() {
        var mapper = ControlMapper(aircraft: .profile(.b737), initial: FlightControls())
        #expect(press(&mapper, onGround: false) { $0.buttonB = true } == [.rejected("Reversers only work on the ground")])
        var thrust = GamepadSnapshot()
        thrust.rightTrigger = 1
        _ = mapper.update(with: thrust, deltaTime: 1, onGround: true)
        #expect(press(&mapper, onGround: true) { $0.buttonB = true } == [.rejected("Pull thrust levers to idle first")])
        var idle = GamepadSnapshot()
        idle.leftTrigger = 1
        _ = mapper.update(with: idle, deltaTime: 2, onGround: true)
        _ = press(&mapper, onGround: true) { $0.buttonB = true }
        #expect(mapper.controls.reversers)
        _ = press(&mapper, onGround: true) { $0.buttonB = true }
        #expect(!mapper.controls.reversers)
        #expect(mapper.controls.throttle == 0)
    }

    @Test func rightStickClickTurnsTheDpadIntoTrim() {
        var mapper = ControlMapper(aircraft: .profile(.b737), initial: FlightControls())
        var pad = GamepadSnapshot()
        pad.rightStickButton = true
        pad.dpadDown = true
        _ = mapper.update(with: pad, deltaTime: 1, onGround: false)
        #expect(mapper.flapLabel == "UP")
        #expect(mapper.controls.pitchTrim < 0)
    }

    @Test func stickDeadzoneAndCurve() {
        #expect(ControlMapper.shaped(0.05) == 0)
        #expect(ControlMapper.shaped(1) == 1)
        #expect(ControlMapper.shaped(-1) == -1)
        #expect(abs(ControlMapper.shaped(0.5)) < 0.5)
    }

    @Test func menuAndViewProduceEvents() {
        var mapper = ControlMapper(aircraft: .profile(.b737), initial: FlightControls())
        #expect(press(&mapper) { $0.menu = true } == [.togglePause])
        #expect(press(&mapper) { $0.view = true } == [.cycleCamera])
    }

    @Test func speedbrakeLeverHasAnArmDetent() {
        var mapper = ControlMapper(aircraft: .profile(.b737), initial: FlightControls())
        _ = press(&mapper) { $0.dpadRight = true }
        #expect(mapper.speedbrakeLabel == "ARM")
        #expect(mapper.speedbrakeArmed)
        #expect(mapper.controls.speedbrake == 0, "Armed is still stowed")
        _ = press(&mapper) { $0.dpadRight = true }
        #expect(mapper.speedbrakeLabel == "FLT")
        #expect(mapper.controls.speedbrake == 0.5)
        _ = press(&mapper) { $0.dpadRight = true }
        #expect(mapper.controls.speedbrake == 1)
    }

    @Test func lightTriggerPressureMovesTheLeversSlowly() {
        var mapper = ControlMapper(aircraft: .profile(.b737), initial: FlightControls())
        var pad = GamepadSnapshot()
        pad.rightTrigger = 0.5
        _ = mapper.update(with: pad, deltaTime: 1, onGround: true)
        #expect(abs(mapper.controls.throttle - 0.25 * ControlMapper.throttleRatePerSecond) < 1e-9)
        #expect(mapper.pilotMovedThrust)
        _ = mapper.update(with: GamepadSnapshot(), deltaTime: 1, onGround: true)
        #expect(!mapper.pilotMovedThrust)
        #expect(abs(mapper.controls.throttle - 0.2) < 1e-9, "Levers stay where they were left")
    }

    @Test func rightStickTapCyclesTheDisplayButHoldingWithDpadOnlyTrims() {
        var mapper = ControlMapper(aircraft: .profile(.b737), initial: FlightControls())
        #expect(press(&mapper) { $0.rightStickButton = true }.isEmpty)
        var pad = GamepadSnapshot()
        pad.rightStickButton = true
        _ = mapper.update(with: pad, deltaTime: 0.1, onGround: true)
        #expect(mapper.update(with: GamepadSnapshot(), deltaTime: 0.1, onGround: true) == [.cycleDisplay])
        pad.dpadUp = true
        _ = mapper.update(with: pad, deltaTime: 0.1, onGround: true)
        #expect(mapper.update(with: GamepadSnapshot(), deltaTime: 0.1, onGround: true).isEmpty)
    }

    @Test func panelTakesTheDpadAndButtonsAndRepeatsHeldDirections() {
        var mapper = ControlMapper(aircraft: .profile(.b737), initial: FlightControls())
        #expect(press(&mapper) { $0.leftStickButton = true } == [.togglePanel])
        var pad = GamepadSnapshot()
        pad.dpadDown = true
        var events = mapper.update(with: pad, deltaTime: 1.0 / 60, onGround: false, panelOpen: true)
        #expect(events == [.panel(.down)])
        #expect(mapper.flapLabel == "UP", "The D-pad belongs to the panel, not the flaps")
        // Held for a second: one press, then repeats after the delay.
        for _ in 0..<60 { events += mapper.update(with: pad, deltaTime: 1.0 / 60, onGround: false, panelOpen: true) }
        #expect(events.count > 5)
        pad = GamepadSnapshot()
        pad.buttonY = true
        _ = mapper.update(with: pad, deltaTime: 1.0 / 60, onGround: false, panelOpen: true)
        #expect(mapper.controls.gearDown, "Face buttons don't operate the aircraft while the panel is open")
    }

    @Test func automationLeversAreAdopted() {
        var mapper = ControlMapper(aircraft: .profile(.b737), initial: FlightControls())
        mapper.adopt(throttle: 0.62, pitchTrim: -0.2)
        _ = mapper.update(with: GamepadSnapshot(), deltaTime: 1.0 / 60, onGround: false)
        #expect(mapper.controls.throttle == 0.62)
        #expect(mapper.controls.pitchTrim == -0.2)
    }

    @Test func initialFlapSettingIsPreserved() {
        var controls = FlightControls()
        controls.flaps = AircraftProfile.profile(.b737).landingFlaps
        #expect(ControlMapper(aircraft: .profile(.b737), initial: controls).flapLabel == "30")
        controls.flaps = AircraftProfile.profile(.b747).flaps[3].lever
        #expect(ControlMapper(aircraft: .profile(.b747), initial: controls).flapLabel == "10")
    }

    @Test func flapsStepThroughTheAircraftsOwnDetents() {
        var mapper = ControlMapper(aircraft: .profile(.a320), initial: FlightControls())
        var pad = GamepadSnapshot()
        var labels: [String] = []
        for _ in 0..<5 {
            pad.dpadDown = true
            _ = mapper.update(with: pad, deltaTime: 1.0 / 60, onGround: true)
            labels.append(mapper.flapLabel)
            pad.dpadDown = false
            _ = mapper.update(with: pad, deltaTime: 1.0 / 60, onGround: true)
        }
        #expect(labels == ["1", "2", "3", "FULL", "FULL"])
        #expect(abs(mapper.controls.flaps - 35.0 / 40) < 1e-9)
    }

    @Test func systemsTheAircraftLacksAreRefused() {
        var mapper = ControlMapper(aircraft: .profile(.c172), initial: FlightControls())
        var pad = GamepadSnapshot()
        pad.buttonY = true
        let gear = mapper.update(with: pad, deltaTime: 1.0 / 60, onGround: false)
        #expect(gear == [.rejected("The Cessna 172P Skyhawk has fixed gear")])
        #expect(mapper.controls.gearDown)
        pad = GamepadSnapshot()
        pad.dpadRight = true
        let speedbrake = mapper.update(with: pad, deltaTime: 1.0 / 60, onGround: false)
        #expect(speedbrake == [.rejected("The Cessna 172P Skyhawk has no speedbrake")])
        #expect(mapper.controls.speedbrake == 0)
        pad = GamepadSnapshot()
        pad.buttonB = true
        let reversers = mapper.update(with: pad, deltaTime: 1.0 / 60, onGround: true)
        #expect(reversers == [.rejected("The Cessna 172P Skyhawk has no thrust reversers")])
        #expect(!mapper.controls.reversers)
    }
}
