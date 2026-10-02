import AVFoundation

/// Every sound is synthesised at launch — no audio files. Wood thunks, creaks,
/// crashes and a few soft UI ticks.
final class SoundBoard {
    static let shared = SoundBoard()

    enum Sound: CaseIterable { case thunk, creak, crash, chime, tick, whoosh, sprout, nope, whistle, paint }

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var players: [(AVAudioPlayerNode, AVAudioUnitVarispeed)] = []
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private var next = 0
    private var started = false
    private let sr: Float = 44_100

    var enabled: Bool { UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true }

    private init() {
        for s in Sound.allCases { buffers[s] = render(s) }
        for _ in 0..<8 {
            let p = AVAudioPlayerNode()
            let v = AVAudioUnitVarispeed()
            engine.attach(p); engine.attach(v)
            engine.connect(p, to: v, format: format)
            engine.connect(v, to: engine.mainMixerNode, format: format)
            players.append((p, v))
        }
        engine.mainMixerNode.outputVolume = 0.8
    }

    /// `pitch` is in semitones.
    func play(_ s: Sound, volume: Float = 1, pitch: Float = 0) {
        guard enabled, let buf = buffers[s] else { return }
        if !started {
            do { try engine.start(); started = true } catch { return }
        }
        let (p, v) = players[next]
        next = (next + 1) % players.count
        p.stop()
        v.rate = pow(2, pitch / 12)
        p.volume = volume
        p.scheduleBuffer(buf, at: nil, options: [])
        p.play()
    }

    // MARK: synthesis

    private func render(_ s: Sound) -> AVAudioPCMBuffer {
        let samples: [Float]
        switch s {
        case .thunk: samples = thunk()
        case .creak: samples = creak()
        case .crash: samples = crash()
        case .chime: samples = chime()
        case .tick: samples = tick()
        case .whoosh: samples = whoosh()
        case .sprout: samples = sprout()
        case .nope: samples = nope()
        case .whistle: samples = whistle()
        case .paint: samples = paint()
        }
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        let ch = buf.floatChannelData![0]
        for i in 0..<samples.count { ch[i] = samples[i] }
        return buf
    }

    private var seed: UInt32 = 12345
    private func noise() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed >> 8) / Float(1 << 24) * 2 - 1
    }

    private func buffer(_ seconds: Float) -> [Float] { [Float](repeating: 0, count: Int(seconds * sr)) }

    /// Axe into wood: a pitched-down knock plus a bright splintery click.
    private func thunk() -> [Float] {
        var out = buffer(0.32)
        var phase: Float = 0, lp: Float = 0, bp: Float = 0
        for i in 0..<out.count {
            let t = Float(i) / sr
            let f = 165 * exp(-t * 9) + 70
            phase += 2 * .pi * f / sr
            let body = sin(phase) * exp(-t * 22) + 0.45 * sin(phase * 2.03) * exp(-t * 35)
            let n = noise()
            lp += (n - lp) * 0.35
            bp += ((n - lp) - bp) * 0.5
            let click = bp * exp(-t * 90) * 0.9
            let rattle = lp * exp(-t * 14) * 0.25
            out[i] = tanh((body * 0.9 + click + rattle) * 1.4) * 0.8
        }
        return out
    }

    /// Wood fibres giving way: stick-slip pulses through a resonant body.
    private func creak() -> [Float] {
        var out = buffer(1.15)
        var phase: Float = 0, y1: Float = 0, y2: Float = 0
        var lp: Float = 0
        for i in 0..<out.count {
            let t = Float(i) / sr
            let rate = 18 + 30 * t + 6 * sin(t * 9)
            phase += rate / sr
            let pulse: Float = (phase.truncatingRemainder(dividingBy: 1) < 0.08) ? 1 : 0
            let excitation = pulse * (0.7 + 0.3 * noise())
            // two-pole resonator ~ 420Hz drifting down
            let f0 = 520 - 160 * t
            let r: Float = 0.985
            let c = 2 * r * cos(2 * .pi * f0 / sr)
            let y = excitation + c * y1 - r * r * y2
            y2 = y1; y1 = y
            lp += (noise() - lp) * 0.02
            let env = min(1, t * 3) * (1 - smoothstep(0.85, 1.15, t))
            out[i] = (y * 0.06 + lp * 0.15) * env
        }
        return normalise(out, to: 0.55)
    }

    /// Tree hitting the ground: thump, rumble, crackle of branches.
    private func crash() -> [Float] {
        var out = buffer(1.6)
        var phase: Float = 0, lp: Float = 0, lp2: Float = 0
        for i in 0..<out.count {
            let t = Float(i) / sr
            phase += 2 * .pi * (55 * exp(-t * 3) + 32) / sr
            let thump = sin(phase) * exp(-t * 5)
            let n = noise()
            let cutoff = 0.25 * exp(-t * 2.5) + 0.01
            lp += (n - lp) * cutoff
            lp2 += (lp - lp2) * cutoff
            let rumble = lp2 * exp(-t * 2.2) * 2.4
            let crackle: Float = (noise() > 0.995 - 0.01 * exp(-t * 3)) ? noise() * exp(-t * 2.5) : 0
            let leaves = (n - lp) * 0.05 * exp(-t * 1.6)
            out[i] = thump * 0.9 + rumble + crackle * 0.8 + leaves
        }
        return normalise(out.map { tanh($0 * 1.3) }, to: 0.85)
    }

    /// A small bright two-note marimba-ish chime.
    private func chime() -> [Float] {
        var out = buffer(1.1)
        let notes: [(Float, Float)] = [(784, 0), (1175, 0.09)]
        for (f, start) in notes {
            for i in Int(start * sr)..<out.count {
                let t = Float(i) / sr - start
                let env = exp(-t * 5.5) * min(1, t * 400)
                out[i] += (sin(2 * .pi * f * t) + 0.3 * sin(2 * .pi * f * 3.98 * t) * exp(-t * 12)) * env * 0.35
            }
        }
        return out
    }

    private func tick() -> [Float] {
        var out = buffer(0.06)
        for i in 0..<out.count {
            let t = Float(i) / sr
            out[i] = sin(2 * .pi * (1900 - 6000 * t) * t) * exp(-t * 120) * 0.3
        }
        return out
    }

    private func whoosh() -> [Float] {
        var out = buffer(0.5)
        var lp: Float = 0, bp: Float = 0
        for i in 0..<out.count {
            let t = Float(i) / sr
            let x = t / 0.5
            let cutoff = 0.02 + 0.18 * sin(.pi * x)
            let n = noise()
            lp += (n - lp) * cutoff
            bp += ((n - lp) - bp) * cutoff
            out[i] = lp * sin(.pi * x) * 0.9
        }
        return normalise(out, to: 0.35)
    }

    private func sprout() -> [Float] {
        var out = buffer(0.18)
        var phase: Float = 0
        for i in 0..<out.count {
            let t = Float(i) / sr
            phase += 2 * .pi * (500 + 2400 * t) / sr
            out[i] = sin(phase) * sin(.pi * t / 0.18) * 0.22
        }
        return out
    }

    private func nope() -> [Float] {
        var out = buffer(0.28)
        var phase: Float = 0
        for i in 0..<out.count {
            let t = Float(i) / sr
            let f: Float = t < 0.12 ? 220 : 165
            phase += 2 * .pi * f / sr
            let env = t < 0.12 ? exp(-t * 18) : exp(-(t - 0.12) * 14)
            out[i] = (sin(phase) + 0.3 * sin(phase * 3)) * env * 0.4
        }
        return out
    }

    /// The ranger's two-tone whistle.
    private func whistle() -> [Float] {
        var out = buffer(0.55)
        var phase: Float = 0
        for i in 0..<out.count {
            let t = Float(i) / sr
            let f: Float = t < 0.2 ? 1500 + 900 * t / 0.2 : 2100 - 600 * min(1, (t - 0.25) / 0.2)
            phase += 2 * .pi * (f + 25 * sin(t * 40)) / sr
            let env = t < 0.2 ? min(1, t * 40) * (1 - smoothstep(0.16, 0.2, t)) : smoothstep(0.24, 0.27, t) * (1 - smoothstep(0.45, 0.55, t))
            out[i] = (sin(phase) + 0.05 * noise()) * env * 0.18
        }
        return out
    }

    /// A quick spray-paint psst.
    private func paint() -> [Float] {
        var out = buffer(0.16)
        var hp: Float = 0, prev: Float = 0
        for i in 0..<out.count {
            let t = Float(i) / sr
            let n = noise()
            hp = 0.9 * (hp + n - prev); prev = n
            out[i] = hp * sin(.pi * t / 0.16) * 0.12
        }
        return out
    }

    private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private func normalise(_ s: [Float], to peak: Float) -> [Float] {
        let m = s.map(abs).max() ?? 1
        guard m > 0 else { return s }
        return s.map { $0 / m * peak }
    }
}
