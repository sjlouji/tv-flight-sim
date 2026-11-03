import GameController

/// Reads the connected game controller each frame and tracks connection changes.
@MainActor
final class GamepadInput {
    private var observers: [NSObjectProtocol] = []

    var isConnected: Bool { extendedGamepad != nil }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            let name = (note.object as? GCController)?.vendorName ?? "unknown controller"
            MainActor.assumeIsolated { self?.controllersChanged(name: name, connected: true) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            let name = (note.object as? GCController)?.vendorName ?? "unknown controller"
            MainActor.assumeIsolated { self?.controllersChanged(name: name, connected: false) }
        })
        GCController.startWirelessControllerDiscovery()
    }

    func stop() {
        GCController.stopWirelessControllerDiscovery()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// The current controller state, or a neutral snapshot with only the Siri Remote menu button when no gamepad is connected.
    func snapshot() -> GamepadSnapshot {
        var snapshot = GamepadSnapshot()
        if let pad = extendedGamepad {
            snapshot.leftStick = SIMD2(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
            snapshot.rightStick = SIMD2(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
            snapshot.leftTrigger = pad.leftTrigger.value
            snapshot.rightTrigger = pad.rightTrigger.value
            snapshot.leftShoulder = pad.leftShoulder.isPressed
            snapshot.rightShoulder = pad.rightShoulder.isPressed
            snapshot.buttonA = pad.buttonA.isPressed
            snapshot.buttonB = pad.buttonB.isPressed
            snapshot.buttonX = pad.buttonX.isPressed
            snapshot.buttonY = pad.buttonY.isPressed
            snapshot.dpadUp = pad.dpad.up.isPressed
            snapshot.dpadDown = pad.dpad.down.isPressed
            snapshot.dpadLeft = pad.dpad.left.isPressed
            snapshot.dpadRight = pad.dpad.right.isPressed
            snapshot.leftStickButton = pad.leftThumbstickButton?.isPressed ?? false
            snapshot.rightStickButton = pad.rightThumbstickButton?.isPressed ?? false
            snapshot.menu = pad.buttonMenu.isPressed
            snapshot.view = pad.buttonOptions?.isPressed ?? false
        }
        if let remote = GCController.controllers().first(where: { $0.extendedGamepad == nil })?.microGamepad {
            snapshot.menu = snapshot.menu || remote.buttonMenu.isPressed
            snapshot.remoteSelect = remote.buttonA.isPressed
        }
        return snapshot
    }

    private var extendedGamepad: GCExtendedGamepad? {
        GCController.controllers().lazy.compactMap(\.extendedGamepad).first
    }

    private func controllersChanged(name: String, connected: Bool) {
        Log.input.info("\(connected ? "Connected" : "Disconnected", privacy: .public) \(name, privacy: .public)")
    }
}
