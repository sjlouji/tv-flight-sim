import Foundation
import RealityKit
import simd

/// Where the cameras inside and around the aircraft sit, in model coordinates.
struct CameraEyes: Sendable {
    let captain: SIMD3<Float>
    let firstOfficer: SIMD3<Float>
    /// Nil where there is no cabin to stand in or sit in.
    let cabinCrew: SIMD3<Float>?
    let passenger: SIMD3<Float>?
    /// Above the left wing root, looking out along the wing.
    let wing: SIMD3<Float>
    let wingTarget: SIMD3<Float>
    /// What the two cockpit seats are called ("Captain", "Left seat", "Pilot" ...).
    let seatNames: (left: String, right: String)
    /// The aircraft's length, which sets how far back the chase and orbit cameras sit.
    let aircraftLength: Float
}

/// A critically damped spring (Apple's default "no bounce" motion): moves smoothly to its target,
/// never overshoots, and picks up from wherever it is if the target changes.
struct Spring: Sendable {
    var value: Float
    var velocity: Float = 0

    init(_ value: Float) { self.value = value }

    /// `response` is roughly how long, in seconds, it takes to get there.
    mutating func update(toward target: Float, response: Float, deltaTime dt: Float) {
        guard dt > 0 else { return }
        let omega = 2 * Float.pi / response
        // Sub-steps keep the integration stable on long frames.
        let steps = max(1, Int((dt * omega / 0.3).rounded(.up)))
        let h = dt / Float(steps)
        for _ in 0..<steps {
            let acceleration = -omega * omega * (value - target) - 2 * omega * velocity
            velocity += acceleration * h
            value += velocity * h
        }
    }
}

/// Positions the scene camera for the selected view. The aircraft is always at the origin (the world is
/// re-centered on it each frame), so cameras that ride with it are exact and never jitter.
@MainActor
final class CameraRig {
    enum Mode: String, CaseIterable, Sendable {
        case captain, firstOfficer, cabinCrew, passenger, wing, chase, orbit, tower, flyby

        var title: String {
            switch self {
            case .captain: "Captain"
            case .firstOfficer: "First officer"
            case .cabinCrew: "Cabin crew"
            case .passenger: "Passenger window"
            case .wing: "Wing"
            case .chase: "Chase"
            case .orbit: "Orbit"
            case .tower: "Tower"
            case .flyby: "Flyby"
            }
        }

        enum Interior { case cockpit, cabin }

        var interior: Interior? {
            switch self {
            case .captain, .firstOfficer: .cockpit
            case .cabinCrew, .passenger: .cabin
            default: nil
            }
        }

        var listener: SoundEngine.Listener {
            switch interior {
            case .cockpit: .cockpit
            case .cabin: .cabin
            case nil: .exterior
            }
        }
    }

    let camera = PerspectiveCamera()
    private(set) var mode: Mode
    /// The views this aircraft has, in cycling order.
    let modes: [Mode]
    private let eyes: CameraEyes
    private let tower: SIMD3<Double>
    private var flyby: SIMD3<Double>?
    // Head and orbit angles (yaw, pitch), as springs so motion starts and stops smoothly.
    private var yaw = Spring(0)
    private var pitch = Spring(0)
    private var orbitYaw: Float = 0
    private var orbitPitch: Float = 0.2
    private var chaseHeading: Spring?
    private var headBob = Spring(0)

    /// Chase and orbit distances for a 33 m airliner; other aircraft scale with their length.
    static let chaseDistance: Float = 62
    static let orbitDistance: Float = 48
    private var sizeScale: Float { (eyes.aircraftLength / 33.4).clamped(0.4, 2.0) }
    static let lookRate: Float = 1.8
    static let headReturnSeconds: Float = 0.6

    /// `towerECEF` is the tower cab (or another fixed viewpoint) on the Earth. `initialMode` comes from the
    /// "initialCamera" user default, which launch arguments such as `-initialCamera tower` set (UI tests).
    init(eyes: CameraEyes, towerECEF: SIMD3<Double>,
         initialMode: Mode = UserDefaults.standard.string(forKey: "initialCamera").flatMap(Mode.init(rawValue:)) ?? .chase) {
        self.eyes = eyes
        tower = towerECEF
        modes = Mode.allCases.filter { mode in
            switch mode {
            case .cabinCrew: eyes.cabinCrew != nil
            case .passenger: eyes.passenger != nil
            default: true
            }
        }
        let start = modes.contains(initialMode) ? initialMode : .chase
        mode = start
        select(start)
    }

    func title(_ mode: Mode) -> String {
        switch mode {
        case .captain: eyes.seatNames.left
        case .firstOfficer: eyes.seatNames.right
        default: mode.title
        }
    }

    func cycle() {
        let index = modes.firstIndex(of: mode) ?? 0
        select(modes[(index + 1) % modes.count])
    }

    func select(title: String) {
        guard let match = modes.first(where: { self.title($0) == title }) else {
            Log.app.error("Unknown camera \(title, privacy: .public)")
            return
        }
        select(match)
    }

    private func select(_ newMode: Mode) {
        mode = newMode
        yaw = Spring(0)
        pitch = Spring(0)
        chaseHeading = nil
        flyby = nil
        camera.camera.near = newMode.interior == nil ? 0.5 : 0.04
        camera.camera.far = .infinity
        camera.camera.fieldOfViewInDegrees = switch newMode {
        case .captain, .firstOfficer: 62
        case .cabinCrew: 64
        case .passenger: 58
        case .wing: 60
        case .tower: 30
        case .flyby: 40
        case .chase, .orbit: 55
        }
    }

    /// `orientation` is the aircraft's attitude in scene axes, `frame` the aircraft-centered Earth frame,
    /// `velocity` its velocity (m/s, scene axes), `look` the right stick, `loadFactor` in g.
    func update(orientation q: simd_quatf, frame: LocalFrame, velocity: SIMD3<Float>, look: SIMD2<Float>,
                loadFactor: Float, onGround: Bool, deltaTime dt: Float) {
        switch mode {
        case .captain, .firstOfficer, .cabinCrew, .passenger, .wing:
            let base: (eye: SIMD3<Float>, yaw: Float, pitch: Float, yawLimit: Float) = switch mode {
            case .captain: (eyes.captain, 0, -0.25, 2.6)
            case .firstOfficer: (eyes.firstOfficer, 0, -0.25, 2.6)
            case .cabinCrew: (eyes.cabinCrew ?? eyes.captain, .pi, -0.14, 1.2)
            case .passenger: (eyes.passenger ?? eyes.captain, 1.62, -0.3, 0.7)
            default: (eyes.wing, 0, 0, 1.4)
            }
            moveHead(look: look, yawLimit: base.yawLimit, dt: dt)
            // The head sinks slightly as the load factor rises (and lifts in a push-over), a cue real pilots feel.
            headBob.update(toward: (1 - loadFactor).clamped(-1.5, 1.5) * 0.025, response: 0.5, deltaTime: dt)
            var local = simd_quatf(angle: base.yaw + yaw.value, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: base.pitch + pitch.value, axis: SIMD3(1, 0, 0))
            if mode == .wing {
                local = lookRotation(from: eyes.wing, to: eyes.wingTarget) * simd_quatf(angle: yaw.value, axis: SIMD3(0, 1, 0))
                    * simd_quatf(angle: pitch.value, axis: SIMD3(1, 0, 0))
            }
            camera.position = q.act(base.eye + SIMD3(0, headBob.value, 0))
            camera.orientation = q * local
        case .chase:
            // Follow the direction of travel (heading on the ground), level with the horizon.
            let forward = q.act(SIMD3<Float>(0, 0, -1))
            let horizontal = SIMD2(velocity.x, velocity.z)
            let travel = simd_length(horizontal) > 15 ? atan2(velocity.x, -velocity.z) : atan2(forward.x, -forward.z)
            var heading = chaseHeading ?? Spring(travel)
            heading.update(toward: heading.value + angleDifference(travel, heading.value), response: 1.2, deltaTime: dt)
            chaseHeading = heading
            moveHead(look: look, yawLimit: .pi, dt: dt)
            let orbitYawNow = heading.value + yaw.value
            let elevation = (0.14 + pitch.value).clamped(-0.05, 1.3)
            place(atYaw: orbitYawNow, elevation: elevation, distance: Self.chaseDistance * sizeScale, lookAt: SIMD3(0, 2 * sizeScale, 0),
                  onGround: onGround)
        case .orbit:
            orbitYaw -= look.x * Self.lookRate * dt
            orbitPitch = (orbitPitch - look.y * Self.lookRate * dt).clamped(-0.3, 1.4)
            let forward = q.act(SIMD3<Float>(0, 0, -1))
            place(atYaw: atan2(forward.x, -forward.z) + orbitYaw, elevation: orbitPitch, distance: Self.orbitDistance * sizeScale,
                  lookAt: SIMD3(0, 1.5 * sizeScale, 0), onGround: onGround)
        case .tower:
            let position = SIMD3<Float>(frame.scenePoint(ecef: tower))
            let distance = simd_length(position)
            camera.camera.fieldOfViewInDegrees = (2 * atan(30 / max(distance, 1)) * 180 / .pi).clamped(1.5, 45)
            camera.look(at: .zero, from: position, relativeTo: nil)
        case .flyby:
            let speed = simd_length(velocity)
            var point = flyby.map { SIMD3<Float>(frame.scenePoint(ecef: $0)) }
            // A new spot once the aircraft has gone well past the last one: ahead on its path, off to the side.
            if point == nil || (simd_dot(point!, velocity) < 0 && simd_length(point!) > 500) {
                let direction = speed > 2 ? velocity / speed : q.act(SIMD3<Float>(0, 0, -1))
                let side = simd_normalize(simd_cross(direction, SIMD3(0, 1, 0)))
                let ahead = direction * max(speed * 9, 120) + side * 55 + SIMD3(0, onGround ? 6 : 18, 0)
                flyby = frame.ecefPoint(scene: SIMD3<Double>(ahead))
                point = ahead
            }
            if let point { camera.look(at: SIMD3(0, 1.5, 0), from: point, relativeTo: nil) }
        }
    }

    /// Right stick turns the head; released, the head drifts back to center.
    private func moveHead(look: SIMD2<Float>, yawLimit: Float, dt: Float) {
        if simd_length(look) > 0.01 {
            yaw.value = (yaw.value - look.x * Self.lookRate * dt).clamped(-yawLimit, yawLimit)
            pitch.value = (pitch.value + look.y * Self.lookRate * dt).clamped(-1.0, 0.85)
            yaw.velocity = 0
            pitch.velocity = 0
        } else {
            yaw.update(toward: 0, response: Self.headReturnSeconds, deltaTime: dt)
            pitch.update(toward: 0, response: Self.headReturnSeconds, deltaTime: dt)
        }
    }

    private func place(atYaw yawAngle: Float, elevation: Float, distance: Float, lookAt target: SIMD3<Float>, onGround: Bool) {
        var position = SIMD3(-sin(yawAngle) * cos(elevation), sin(elevation), cos(yawAngle) * cos(elevation)) * distance
            + SIMD3(0, 4 * sizeScale, 0)
        if onGround { position.y = max(position.y, 1.5) }
        camera.look(at: target, from: position, relativeTo: nil)
    }

    private func lookRotation(from eye: SIMD3<Float>, to target: SIMD3<Float>) -> simd_quatf {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        return simd_quatf(simd_float3x3(columns: (right, up, -forward)))
    }

    private func angleDifference(_ a: Float, _ b: Float) -> Float {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }
}
