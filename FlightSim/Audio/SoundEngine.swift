import AVFAudio
import Foundation
import Synchronization

/// Engine, airflow and systems sound, synthesized live from the flight model, plus spoken callouts.
///
/// Nothing is sampled, so every sound follows the simulation exactly. Each engine type has its own voice:
/// a turbofan's blade-passing tone tracks N1 with the "buzzsaw" of supersonic fan tips at high thrust; a
/// turbojet is mostly roar and compressor whine; a turboprop is its propeller's blade tone over a turbine
/// whine; a piston engine is a train of cylinder firings plus its propeller. Engines on the left wing play
/// louder on the left. What the listener hears is filtered for where the camera is.
@MainActor
final class SoundEngine {
    enum Listener: Int, Sendable {
        case cockpit, cabin, exterior
    }

    enum Chime: Sendable {
        case autopilotDisconnect, autothrottleDisconnect
    }

    var listener: Listener = .exterior {
        didSet { shared.parameters.withLock { $0.listener = listener } }
    }

    private let engine = AVAudioEngine()
    private let speech = AVSpeechSynthesizer()
    private let shared = SharedSynthParameters()
    private var running = false
    private var previousGearPosition: Double?
    private var previousFlapPosition: Double?

    /// Each engine's share of the left and right channels, from its position on the aircraft.
    private var enginePan: [SIMD2<Double>] = []
    private var maxThrustPounds = 1.0

    func start(aircraft: AircraftProfile, geometry: AircraftGeometry) async throws {
        guard !running else { return }
        enginePan = geometry.engines.map { position in
            position.x < -0.2 ? SIMD2(1, 0) : (position.x > 0.2 ? SIMD2(0, 1) : SIMD2(0.5, 0.5))
        }
        maxThrustPounds = aircraft.maxThrustPounds
        shared.parameters.withLock { $0.voice = EngineVoice(aircraft) }
        try await Self.activateSession()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw SoundError.noOutput
        }
        let node = Self.makeSourceNode(synth: EngineSynth(shared: shared, sampleRate: sampleRate), format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            Log.app.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        running = true
        Log.app.info("Sound started at \(sampleRate) Hz")
    }

    /// Activating the audio session can block, so it happens off the main thread (AVAudioSession is thread-safe).
    @concurrent
    private nonisolated static func activateSession() async throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            Log.app.error("Audio session failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func stop() {
        guard running else { return }
        speech.stopSpeaking(at: .immediate)
        engine.stop()
        running = false
    }

    func setPaused(_ paused: Bool) {
        shared.parameters.withLock { $0.masterGain = paused ? 0 : 1 }
        if paused { speech.stopSpeaking(at: .immediate) }
    }

    func update(telemetry t: Telemetry, controls: FlightControls, deltaTime dt: Double) {
        let gearMoving = previousGearPosition.map { abs($0 - t.gearPosition) > 1e-5 } ?? false
        let flapsMoving = previousFlapPosition.map { abs($0 - t.flapPosition) > 1e-5 } ?? false
        let gearLocked = previousGearPosition.map { prev in
            (prev < 0.999 && t.gearPosition >= 0.999) || (prev > 0.001 && t.gearPosition <= 0.001)
        } ?? false
        previousGearPosition = t.gearPosition
        previousFlapPosition = t.flapPosition
        shared.parameters.withLock { p in
            // Left-side engines make the left voice, right-side the right; a centerline engine feeds both.
            var weight = SIMD2<Double>.zero, n1 = SIMD2<Double>.zero, n2 = SIMD2<Double>.zero
            var rpm = SIMD2<Double>.zero, thrust = SIMD2<Double>.zero
            for (i, pan) in enginePan.enumerated() where i < t.engineSpool.count {
                weight += pan
                n1 += pan * t.engineSpool[i] * 100
                n2 += pan * t.engineN2[i]
                rpm += pan * t.engineRPM[i]
                thrust += pan * (abs(t.engineThrustPounds[i]) / maxThrustPounds).clamped(0, 1.2)
            }
            let divisor = SIMD2(max(weight.x, 1e-9), max(weight.y, 1e-9))
            p.n1 = n1 / divisor
            p.n2 = n2 / divisor
            p.rpm = rpm / divisor
            p.thrust = thrust / divisor
            p.trueAirspeed = t.trueAirspeedKnots
            p.groundSpeed = t.weightOnWheels ? t.groundSpeedKnots : 0
            p.gearMoving = gearMoving
            p.flapsMoving = flapsMoving
            p.gearDown = t.gearPosition
            p.speedbrake = t.speedbrakePosition
            p.reversers = controls.reversers
            p.stickShaker = t.stallWarning
            if gearLocked { p.gearClunks &+= 1 }
        }
    }

    func chime(_ chime: Chime) {
        shared.parameters.withLock { p in
            switch chime {
            case .autopilotDisconnect: p.wailers &+= 1
            case .autothrottleDisconnect: p.beeps &+= 1
            }
        }
    }

    func speak(_ callout: Callout) {
        // Altitude callouts come quickly near the ground; a late one is worse than a cut-off one.
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: callout.rawValue)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.55
        utterance.pitchMultiplier = 0.8
        speech.speak(utterance)
    }

    /// Built outside the main actor: the render block runs on the real-time audio thread, and a closure
    /// formed in a main-actor method would be treated as main-actor isolated there.
    private nonisolated static func makeSourceNode(synth: EngineSynth, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            synth.render(frameCount: Int(frameCount), buffers: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
    }
}

enum SoundError: LocalizedError {
    case noOutput
    var errorDescription: String? { "No audio output is available." }
}

/// The parameters, behind a mutex, shared by the main thread (writer) and the audio thread (reader).
final class SharedSynthParameters: Sendable {
    let parameters = Mutex(SynthParameters())
}

/// Values the main thread sets and the audio thread reads, once per buffer.
struct SynthParameters: Sendable {
    var voice = EngineVoice(kind: .turbofan, fanRPM: 5_175, fanBlades: 38, propellerBlades: 0)
    /// Left and right engine groups: spool speed in percent (N1, or RPM as a percentage of maximum), N2,
    /// and propeller or crankshaft RPM.
    var n1 = SIMD2<Double>.zero
    var n2 = SIMD2<Double>.zero
    var rpm = SIMD2<Double>.zero
    /// Thrust as a fraction of takeoff thrust.
    var thrust = SIMD2<Double>.zero
    var trueAirspeed: Double = 0
    /// Ground speed while rolling on the wheels, else 0.
    var groundSpeed: Double = 0
    var gearMoving = false
    var flapsMoving = false
    var gearDown: Double = 1
    var speedbrake: Double = 0
    var reversers = false
    var stickShaker = false
    var listener: SoundEngine.Listener = .exterior
    var masterGain: Double = 1
    /// Counters: each increment starts one sound.
    var gearClunks: UInt32 = 0
    var wailers: UInt32 = 0
    var beeps: UInt32 = 0
}

/// What an engine sounds like: its type and the frequencies that make its tones.
struct EngineVoice: Sendable {
    let kind: EngineKind
    /// Fan or compressor RPM at 100 % N1, and its blade count (the blade-passing tone).
    let fanRPM: Double
    let fanBlades: Double
    let propellerBlades: Double
    /// A turboprop's governed propeller speed: constant-speed propellers hold it from idle power up.
    let propellerRPM: Double

    init(kind: EngineKind, fanRPM: Double, fanBlades: Double, propellerBlades: Double, propellerRPM: Double = 0) {
        self.kind = kind
        self.fanRPM = fanRPM
        self.fanBlades = fanBlades
        self.propellerBlades = propellerBlades
        self.propellerRPM = propellerRPM
    }

    /// Published figures for each aircraft's engines.
    init(_ aircraft: AircraftProfile) {
        switch aircraft.type {
        case .b737: self.init(kind: .turbofan, fanRPM: 5_175, fanBlades: 38, propellerBlades: 0)
        case .a320: self.init(kind: .turbofan, fanRPM: 5_000, fanBlades: 36, propellerBlades: 0)
        case .b747: self.init(kind: .turbofan, fanRPM: 3_280, fanBlades: 38, propellerBlades: 0)
        case .b787: self.init(kind: .turbofan, fanRPM: 2_700, fanBlades: 20, propellerBlades: 0)
        case .global5000: self.init(kind: .turbofan, fanRPM: 7_000, fanBlades: 24, propellerBlades: 0)
        case .f4: self.init(kind: .turbojet, fanRPM: 7_460, fanBlades: 22, propellerBlades: 0)
        case .c130: self.init(kind: .turboprop, fanRPM: 13_820, fanBlades: 14, propellerBlades: 4, propellerRPM: 1_020)
        case .dhc6: self.init(kind: .turboprop, fanRPM: 37_500, fanBlades: 14, propellerBlades: 3, propellerRPM: 2_200)
        case .c172: self.init(kind: .piston, fanRPM: 2_700, fanBlades: 0, propellerBlades: 2)
        }
    }
}

/// The synthesizer. Its state is touched only by the audio render thread (the parameters it reads are
/// behind a mutex it never waits on), which is why it is `@unchecked Sendable`.
final class EngineSynth: @unchecked Sendable {
    private let shared: SharedSynthParameters
    private let sampleRate: Double
    private var p = SynthParameters()
    // Smoothed copies, so parameter steps never click.
    private var n1 = SIMD2<Double>.zero, n2 = SIMD2<Double>.zero, rpm = SIMD2<Double>.zero, thrust = SIMD2<Double>.zero
    private var propPhase = SIMD2<Double>.zero, firingPhase = SIMD2<Double>.zero, firing = SIMD2<Double>.zero
    private var air = 0.0, roll = 0.0, gain = 1.0
    private var fanPhase = SIMD2<Double>.zero, shaftPhase = SIMD2<Double>.zero, whinePhase = SIMD2<Double>.zero, motorPhase = 0.0
    private var roarState = SIMD2<Double>.zero, rumbleState = 0.0, windLow = 0.0, windBand = 0.0, interior = SIMD2<Double>.zero
    private var buzzState = SIMD2<Double>.zero
    private var noiseSeed: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var thumpPhase = 0.0, thump = 0.0, clunk = 0.0
    private var heardClunks: UInt32 = 0, heardWailers: UInt32 = 0, heardBeeps: UInt32 = 0
    private var wailerTime = -1.0, beepTime = -1.0, time = 0.0

    init(shared: SharedSynthParameters, sampleRate: Double) {
        self.shared = shared
        self.sampleRate = sampleRate
        let initial = shared.parameters.withLock { $0 }
        heardClunks = initial.gearClunks
        heardWailers = initial.wailers
        heardBeeps = initial.beeps
    }

    func render(frameCount: Int, buffers: UnsafeMutableAudioBufferListPointer) {
        if let latest = shared.parameters.withLockIfAvailable({ $0 }) { p = latest }
        if p.gearClunks != heardClunks { heardClunks = p.gearClunks; clunk = 1 }
        if p.wailers != heardWailers { heardWailers = p.wailers; wailerTime = 0 }
        if p.beeps != heardBeeps { heardBeeps = p.beeps; beepTime = 0 }
        guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        let dt = 1 / sampleRate
        let smoothing = 1 - exp(-dt / 0.05)
        let listener = p.listener
        // Engines are muffled inside: the cockpit is quieter and duller than the cabin over the wing.
        let interiorCutoff = listener == .cockpit ? 900.0 : 1_500.0
        let interiorAlpha = 1 - exp(-2 * .pi * interiorCutoff * dt)
        let engineGain = listener == .exterior ? 1.0 : (listener == .cabin ? 0.55 : 0.3)
        let windGain = listener == .exterior ? 0.35 : (listener == .cockpit ? 0.9 : 0.5)
        let shakerOn = p.stickShaker

        for frame in 0..<frameCount {
            time += dt
            gain += (p.masterGain - gain) * smoothing
            air += (p.trueAirspeed - air) * smoothing
            roll += (p.groundSpeed - roll) * smoothing
            var engineOut = SIMD2<Double>.zero
            for i in 0..<2 {
                n1[i] += (p.n1[i] - n1[i]) * smoothing
                n2[i] += (p.n2[i] - n2[i]) * smoothing
                rpm[i] += (p.rpm[i] - rpm[i]) * smoothing
                thrust[i] += (p.thrust[i] * (p.reversers ? 1.4 : 1) - thrust[i]) * smoothing
                engineOut[i] = engineSample(i, dt: dt) * engineGain
                if listener != .exterior {
                    interior[i] += (engineOut[i] - interior[i]) * interiorAlpha
                    engineOut[i] = interior[i] * 1.6
                }
            }
            // Airflow over the airframe: band-limited noise rising with the square of speed, more with gear and spoilers.
            let windLevel = pow(air / 300, 2).clamped(0, 1.6) * (1 + 0.4 * p.gearDown + 0.6 * p.speedbrake)
            let n = noise()
            windLow += (n - windLow) * 0.08
            windBand += ((n - windLow) - windBand) * 0.3
            let wind = (windLow * 0.6 + windBand * 0.4) * windLevel * windGain * 0.5
            // Rolling: low rumble plus a thump at each centerline light (every 15 m).
            rumbleState += (noise() - rumbleState) * 0.01
            let rollLevel = (roll / 120).clamped(0, 1.2)
            thumpPhase += roll * 0.514 / 15 * dt
            if thumpPhase >= 1 { thumpPhase -= 1; thump = 1 }
            thump *= exp(-dt / 0.03)
            let rolling = (rumbleState * 3 + thump * sin(2 * .pi * 60 * time) * 0.3) * rollLevel
            // Gear and flap motors, gear lock clunk.
            motorPhase = (motorPhase + (p.gearMoving ? 420 : 260) * dt).truncatingRemainder(dividingBy: 1)
            let motor = (p.gearMoving ? 0.05 : 0) + (p.flapsMoving ? 0.03 : 0)
            let motors = sin(2 * .pi * motorPhase) * motor
            clunk *= exp(-dt / 0.08)
            let clunkSound = clunk * (noise() * 0.6 + sin(2 * .pi * 45 * time)) * 0.6
            // Stick shaker: a heavy 30 Hz rattle.
            let shaker = shakerOn ? (sin(2 * .pi * 30 * time) > 0 ? 0.25 : -0.25) * (0.7 + 0.3 * noise()) : 0
            let alerts = alertSample(dt)

            let common = wind + rolling + motors + clunkSound + shaker + alerts
            // Left engine to the left speaker, right to the right, with some crossfeed.
            let l = (engineOut[0] * 0.75 + engineOut[1] * 0.25 + common) * gain * 0.6
            let r = (engineOut[1] * 0.75 + engineOut[0] * 0.25 + common) * gain * 0.6
            left[frame] = Float(tanh(l))
            right[frame] = Float(tanh(r))
        }
    }

    /// One sample of engine group `i` (0 left, 1 right) in the aircraft's engine voice.
    private func engineSample(_ i: Int, dt: Double) -> Double {
        let voice = p.voice
        let spool = (n1[i] / 100).clamped(0, 1.1)
        // Exhaust or propwash roar: noise whose brightness and level rise with thrust.
        let cutoff = 250 + 1_400 * thrust[i]
        roarState[i] += (noise() - roarState[i]) * (1 - exp(-2 * .pi * cutoff * dt))
        let roar = roarState[i] * pow(thrust[i].clamped(0, 1.4), 0.7) * 2.2
        // Compressor (fan) blade-passing tone and its second harmonic.
        let shaft = max(n1[i], 0) / 100 * voice.fanRPM / 60
        fanPhase[i] = (fanPhase[i] + shaft * voice.fanBlades * dt).truncatingRemainder(dividingBy: 1)
        let fan = sin(2 * .pi * fanPhase[i]) + 0.35 * sin(4 * .pi * fanPhase[i])
        // High-pressure spool whine.
        whinePhase[i] = (whinePhase[i] + max(n2[i], n1[i] * 0.95, 0) / 100 * 3_100 * dt).truncatingRemainder(dividingBy: 1)
        let whine = sin(2 * .pi * whinePhase[i]) * spool.clamped(0, 1)
        // A propeller's blade-passing tone: a buzzy sawtooth with its harmonics. A turboprop's governor holds
        // its RPM once the engine is past about 60 % N1; a piston engine's propeller turns with the crankshaft.
        let propellerRPM = voice.kind == .turboprop ? voice.propellerRPM * (spool / 0.6).clamped(0, 1) : max(rpm[i], 0)
        propPhase[i] = (propPhase[i] + propellerRPM / 60 * voice.propellerBlades * dt).truncatingRemainder(dividingBy: 1)
        let blade = (2 * propPhase[i] - 1) * 0.6 + sin(2 * .pi * propPhase[i]) * 0.4
        switch voice.kind {
        case .turbofan:
            // Buzzsaw: shaft-order harmonics once the fan tips go supersonic (above ~80 % N1).
            shaftPhase[i] = (shaftPhase[i] + shaft * dt).truncatingRemainder(dividingBy: 1)
            buzzState[i] += ((2 * shaftPhase[i] - 1) - buzzState[i]) * 0.25
            let buzz = buzzState[i] * ((n1[i] - 78) / 15).clamped(0, 1)
            return fan * 0.05 * spool + buzz * 0.10 + whine * 0.025 + roar
        case .turbojet:
            // Mostly roar, harsher than a fan, with a thin compressor tone.
            return fan * 0.02 * spool + whine * 0.04 + roar * 1.3
        case .turboprop:
            return blade * 0.16 * (0.35 + thrust[i]) + whine * 0.03 + roar * 0.35
        case .piston:
            // A four-cylinder four-stroke fires twice per revolution; each firing is a short decaying bang.
            firingPhase[i] += max(rpm[i], 0) / 60 * 2 * dt
            if firingPhase[i] >= 1 { firingPhase[i] -= 1; firing[i] = 1 }
            firing[i] *= exp(-dt / 0.006)
            let bang = firing[i] * (0.6 * noise() + 0.4) * (0.4 + 0.6 * thrust[i].clamped(0, 1))
            return bang * 0.45 + blade * 0.08 * (0.3 + thrust[i]) + roar * 0.2
        }
    }

    /// Autopilot disconnect "wailer" (2 s of alternating tones) and the autothrottle disconnect beeps.
    private func alertSample(_ dt: Double) -> Double {
        var out = 0.0
        if wailerTime >= 0 {
            let frequency = Int(wailerTime * 8) % 2 == 0 ? 1_050.0 : 1_450.0
            out += sin(2 * .pi * frequency * wailerTime) * 0.18
            wailerTime += dt
            if wailerTime > 2 { wailerTime = -1 }
        }
        if beepTime >= 0 {
            let on = beepTime.truncatingRemainder(dividingBy: 0.3) < 0.15
            out += on ? sin(2 * .pi * 880 * beepTime) * 0.15 : 0
            beepTime += dt
            if beepTime > 0.6 { beepTime = -1 }
        }
        return out
    }

    /// White noise in -1 ... 1 (xorshift; no allocation or locking, safe on the audio thread).
    private func noise() -> Double {
        noiseSeed ^= noiseSeed << 13
        noiseSeed ^= noiseSeed >> 7
        noiseSeed ^= noiseSeed << 17
        return Double(noiseSeed >> 11) / Double(1 << 52) - 1
    }
}
