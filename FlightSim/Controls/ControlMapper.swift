import Foundation
import simd

/// One frame of controller state, independent of the GameController framework so it can be tested.
struct GamepadSnapshot: Equatable, Sendable {
    var leftStick: SIMD2<Float> = .zero
    var rightStick: SIMD2<Float> = .zero
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var leftShoulder = false
    var rightShoulder = false
    var buttonA = false
    var buttonB = false
    var buttonX = false
    var buttonY = false
    var dpadUp = false
    var dpadDown = false
    var dpadLeft = false
    var dpadRight = false
    var leftStickButton = false
    var rightStickButton = false
    /// Xbox "Menu", PlayStation "Options", or the Siri Remote Back button.
    var menu = false
    /// Xbox "View", PlayStation "Create/Share".
    var view = false
    /// Siri Remote touch-surface click. Only used by the pause menu.
    var remoteSelect = false
}

/// Navigation inside the flight-deck panel (autopilot and checklists).
enum PanelInput: Equatable, Sendable {
    case up, down, left, right, select, back, previousTab, nextTab
}

enum CockpitEvent: Equatable, Sendable {
    case togglePause
    case cycleCamera
    case cycleDisplay
    case togglePanel
    case panel(PanelInput)
    /// A command the aircraft refused, shown briefly on screen.
    case rejected(String)
}

/// Turns controller input into cockpit commands for the flown aircraft.
///
/// Layout (Xbox names; PlayStation equivalents in brackets):
/// - Left stick: pitch and roll. Bumpers [L1/R1]: rudder and nosewheel steering.
/// - Right trigger / left trigger [R2/L2]: thrust levers forward / back, faster the harder they are pressed;
///   the levers stay where they are left.
/// - D-pad up/down: flaps one detent up/down. D-pad left/right: speedbrake lever (DOWN, ARM, FLT, UP).
/// - Hold right stick click [R3] + D-pad: pitch trim (up/down) and rudder trim (left/right).
///   Tap R3: change the display (glass cockpit, head-up, map, clean).
/// - A [Cross]: wheel brakes while held. X [Square]: parking brake. Y [Triangle]: landing gear.
/// - B [Circle]: thrust reversers (on the ground, levers at idle), on aircraft that have them.
/// - Left stick click [L3]: flight-deck panel (autopilot, checklists). While it is open the D-pad moves and
///   changes, A selects, B closes and the bumpers switch tabs; the sticks and triggers still fly.
/// - Right stick: look around. View [Create]: change camera. Menu [Options]: pause.
struct ControlMapper: Sendable {
    static let stickDeadzone: Float = 0.08
    static let throttleRatePerSecond = 0.8
    static let rudderRatePerSecond = 3.0
    static let brakeRatePerSecond = 4.0
    static let trimRatePerSecond = 0.15
    static let idleThreshold = 0.05
    static let speedbrakeLabels = ["DOWN", "ARM", "FLT", "UP"]
    static let speedbrakeLever = [0.0, 0.0, 0.5, 1.0]
    static let armDetent = 1
    /// A right stick click shorter than this, with no D-pad press, is a tap.
    static let tapSeconds = 0.35
    /// Held D-pad directions repeat in the panel after this delay, at `repeatInterval`.
    static let repeatDelay = 0.4
    static let repeatInterval = 0.08

    let aircraft: AircraftProfile
    private(set) var controls: FlightControls
    private(set) var flapDetent: Int
    private(set) var speedbrakeDetent = 0
    private(set) var cameraLook: SIMD2<Float> = .zero
    /// True when the triggers moved the thrust levers this frame (the autothrottle gives way to that).
    private(set) var pilotMovedThrust = false
    private var previous = GamepadSnapshot()
    private var rightStickHeld = 0.0
    private var rightStickUsedForTrim = false
    private var dpadHeld = 0.0
    private var nextRepeat = 0.0

    init(aircraft: AircraftProfile, initial: FlightControls) {
        self.aircraft = aircraft
        controls = initial
        // The detent nearest the starting flap command.
        flapDetent = aircraft.flaps.indices.min { abs(aircraft.flaps[$0].lever - initial.flaps) < abs(aircraft.flaps[$1].lever - initial.flaps) } ?? 0
        // DOWN and ARM share lever position 0; a stowed lever starts in DOWN.
        speedbrakeDetent = Self.speedbrakeLever.firstIndex { $0 >= initial.speedbrake - 1e-9 } ?? 0
    }

    var flapLabel: String { aircraft.flaps[flapDetent].label }
    var speedbrakeLabel: String { Self.speedbrakeLabels[speedbrakeDetent] }
    var speedbrakeArmed: Bool { speedbrakeDetent == Self.armDetent }

    /// The automation moved these levers (autothrottle, autopilot trim); the pilot's levers follow,
    /// so taking over again starts where the automation left them.
    mutating func adopt(throttle: Double?, pitchTrim: Double?) {
        if let throttle { controls.throttle = throttle }
        if let pitchTrim { controls.pitchTrim = pitchTrim }
    }

    /// Applies one frame of input. `onGround` comes from the gear weight-on-wheels sensors.
    mutating func update(with pad: GamepadSnapshot, deltaTime dt: Double, onGround: Bool, panelOpen: Bool = false) -> [CockpitEvent] {
        defer { previous = pad }
        var events: [CockpitEvent] = []
        func pressed(_ keyPath: KeyPath<GamepadSnapshot, Bool>) -> Bool { pad[keyPath: keyPath] && !previous[keyPath: keyPath] }

        if pressed(\.menu) { events.append(.togglePause) }
        if pressed(\.view) { events.append(.cycleCamera) }
        if pressed(\.leftStickButton) { events.append(.togglePanel) }

        controls.aileron = Double(Self.shaped(pad.leftStick.x))
        controls.elevator = Double(Self.shaped(pad.leftStick.y))
        cameraLook = SIMD2(Self.shaped(pad.rightStick.x), Self.shaped(pad.rightStick.y))

        // Pressure squared: a light squeeze nudges the levers, a full press moves them across in 1.25 s.
        let forward = Double(pad.rightTrigger * pad.rightTrigger)
        let back = Double(pad.leftTrigger * pad.leftTrigger)
        let leverInput = forward - back
        pilotMovedThrust = abs(leverInput) > 0.01
        if pilotMovedThrust {
            controls.throttle = (controls.throttle + leverInput * Self.throttleRatePerSecond * dt).clamped(0, 1)
        }

        if panelOpen {
            controls.rudder = Self.approach(controls.rudder, 0, rate: Self.rudderRatePerSecond * dt)
            controls.brakes = Self.approach(controls.brakes, 0, rate: Self.brakeRatePerSecond * dt)
            if pressed(\.buttonA) { events.append(.panel(.select)) }
            if pressed(\.buttonB) { events.append(.panel(.back)) }
            if pressed(\.leftShoulder) { events.append(.panel(.previousTab)) }
            if pressed(\.rightShoulder) { events.append(.panel(.nextTab)) }
            events += panelDirections(pad, dt: dt)
            rightStickHeld = 0
            return events
        }

        let rudderTarget = (pad.rightShoulder ? 1.0 : 0) - (pad.leftShoulder ? 1.0 : 0)
        controls.rudder = Self.approach(controls.rudder, rudderTarget, rate: Self.rudderRatePerSecond * dt)

        controls.brakes = Self.approach(controls.brakes, pad.buttonA ? 1 : 0, rate: Self.brakeRatePerSecond * dt)
        if pressed(\.buttonX) { controls.parkingBrake.toggle() }

        if pressed(\.buttonY) {
            if !aircraft.retractableGear {
                events.append(.rejected("The \(aircraft.name) has fixed gear"))
            } else if controls.gearDown && onGround {
                events.append(.rejected("Gear can't retract on the ground"))
            } else {
                controls.gearDown.toggle()
            }
        }

        if pressed(\.buttonB) {
            if controls.reversers {
                controls.reversers = false
                controls.throttle = 0
            } else if !aircraft.hasReversers {
                events.append(.rejected("The \(aircraft.name) has no thrust reversers"))
            } else if !onGround {
                events.append(.rejected("Reversers only work on the ground"))
            } else if controls.throttle > Self.idleThreshold {
                events.append(.rejected("Pull thrust levers to idle first"))
            } else {
                controls.reversers = true
            }
        }

        if pad.rightStickButton {
            rightStickHeld += dt
            let pitchInput = (pad.dpadDown ? 1.0 : 0) - (pad.dpadUp ? 1.0 : 0)
            let rudderInput = (pad.dpadRight ? 1.0 : 0) - (pad.dpadLeft ? 1.0 : 0)
            if pitchInput != 0 || rudderInput != 0 { rightStickUsedForTrim = true }
            controls.pitchTrim = (controls.pitchTrim - pitchInput * Self.trimRatePerSecond * dt).clamped(-1, 1)
            controls.rudderTrim = (controls.rudderTrim + rudderInput * Self.trimRatePerSecond * dt).clamped(-1, 1)
        } else {
            if previous.rightStickButton && !rightStickUsedForTrim && rightStickHeld < Self.tapSeconds {
                events.append(.cycleDisplay)
            }
            rightStickHeld = 0
            rightStickUsedForTrim = false

            if pressed(\.dpadDown) { flapDetent = min(flapDetent + 1, aircraft.flaps.count - 1) }
            if pressed(\.dpadUp) { flapDetent = max(flapDetent - 1, 0) }
            controls.flaps = aircraft.flaps[flapDetent].lever

            if aircraft.hasSpeedbrake {
                let maxBrake = Self.speedbrakeLever.count - 1
                if pressed(\.dpadRight) { speedbrakeDetent = min(speedbrakeDetent + 1, maxBrake) }
                if pressed(\.dpadLeft) { speedbrakeDetent = max(speedbrakeDetent - 1, 0) }
                controls.speedbrake = Self.speedbrakeLever[speedbrakeDetent]
            } else if pressed(\.dpadRight) || pressed(\.dpadLeft) {
                events.append(.rejected("The \(aircraft.name) has no speedbrake"))
            }
        }
        return events
    }

    /// D-pad presses in the panel, repeating while held so values can be wound quickly.
    private mutating func panelDirections(_ pad: GamepadSnapshot, dt: Double) -> [CockpitEvent] {
        let directions: [(KeyPath<GamepadSnapshot, Bool>, PanelInput)] = [
            (\.dpadUp, .up), (\.dpadDown, .down), (\.dpadLeft, .left), (\.dpadRight, .right),
        ]
        guard let held = directions.first(where: { pad[keyPath: $0.0] }) else {
            dpadHeld = 0
            return []
        }
        if !previous[keyPath: held.0] {
            dpadHeld = 0
            nextRepeat = Self.repeatDelay
            return [.panel(held.1)]
        }
        dpadHeld += dt
        guard dpadHeld >= nextRepeat else { return [] }
        nextRepeat += Self.repeatInterval
        return [.panel(held.1)]
    }

    /// Deadzone plus a cubic blend: fine control near center, full deflection at the stops.
    static func shaped(_ value: Float) -> Float {
        let magnitude = abs(value)
        guard magnitude > stickDeadzone else { return 0 }
        let scaled = min((magnitude - stickDeadzone) / (1 - stickDeadzone), 1)
        let curved = 0.35 * scaled + 0.65 * scaled * scaled * scaled
        return value < 0 ? -curved : curved
    }

    private static func approach(_ current: Double, _ target: Double, rate: Double) -> Double {
        if current < target { return min(current + rate, target) }
        return max(current - rate, target)
    }
}
