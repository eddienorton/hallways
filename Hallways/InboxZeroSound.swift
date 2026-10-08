import Foundation
import AVFoundation

// Oct 7 -- INBOX ZERO sounds, synthesised in code like the other computer
// games. The language is a desk, not an arcade: the formation marches to the
// clack of typewriter keys (faster as fewer envelopes are left, so the room
// itself gets tense), each drop of a row is a carriage return, a reply is a
// paper flick, and answering an envelope is a bright pluck that climbs a
// pentatonic step with every hit in a row.
//   step(p)      a typewriter key clack (two slightly different keys)
//   descend      carriage return: a quick ratchet into a low thunk
//   fire         a paper flick: short rising whisk
//   hit(n)       a paper pop + a pluck, one scale step higher per hit in a row
//   tink         a "!" knocked out of the air: a small metallic tink
//   enemyFire    a tiny falling blip (you hear incoming before you see it)
//   urgentPing   a soft two-note "attention" ping while URGENT crosses
//   urgentHit    a fast rising run of bells with a shimmer
//   streakLost   two soft falling notes (only when a real streak is lost)
//   playerHit    a crumple and a falling tone
//   waveClear    a whisk upward into a bright major arpeggio: inbox zero
//   over         four falling notes onto a soft thud
//   newRun       three quick rising blips: straight back in

@MainActor
enum InboxZeroSound {
    enum Cue: Hashable { case step(Int), descend, fire, hit(Int), tink, enemyFire, urgentPing, urgentHit, streakLost, playerHit, waveClear, over, newRun }

    private static var cache: [Cue: Data] = [:]
    private static var players: [AVAudioPlayer] = []

    @discardableResult
    static func prepare(_ cue: Cue) -> Data {
        if let cached = cache[cue] { return cached }
        let data = BobbinSound.wav(render(cue))
        cache[cue] = data
        return data
    }

    static func play(_ cue: Cue) {
        let data = prepare(cue)
        players.removeAll { !$0.isPlaying }
        guard players.count < 24, let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = 0.9
        HallwaysAudio.shared.manage(player)          // Oct 8: the mute switch
        player.prepareToPlay()
        player.play()
        players.append(player)
    }

    /// Render everything up front, so the first hit is instant.
    static func warmUp() {
        var cues: [Cue] = [.step(0), .step(1), .descend, .fire, .tink, .enemyFire, .urgentPing, .urgentHit, .streakLost, .playerHit, .waveClear, .over, .newRun]
        cues += (0...hitLevels).map { Cue.hit($0) }
        for cue in cues { prepare(cue) }
    }

    /// Pentatonic ladder for consecutive hits (C5 upward).
    static let hitLevels = 10
    private static let ladder: [Float] = [523.25, 587.33, 659.25, 783.99, 880.0, 1046.5, 1174.66, 1318.51, 1567.98, 1760.0, 2093.0]

    private static let rate = Float(BobbinSound.rate)

    private static func tone(_ f: Float, _ seconds: Float, decay: Float, bend: Float = 1, bright: Float = 0.2) -> [Float] {
        let n = Int(seconds * rate)
        var phase: Float = 0
        return (0..<n).map { i in
            let t = Float(i) / rate
            let u = Float(i) / Float(max(n, 1))
            phase += 2 * .pi * f * (1 + (bend - 1) * u) / rate
            let s = sin(phase) + bright * sin(2 * phase)
            return s * exp(-t / decay) * min(1, t / 0.002) * min(1, (seconds - t) / 0.008)
        }
    }

    private static func bell(_ f: Float, _ seconds: Float) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            let t = Float(i) / rate
            let s = sin(2 * .pi * f * t) + 0.35 * sin(2 * .pi * f * 2.76 * t) * exp(-t / 0.12) + 0.15 * sin(2 * .pi * f * 5.4 * t) * exp(-t / 0.05)
            return s * exp(-t / (seconds * 0.4)) * min(1, t / 0.002) * min(1, (seconds - t) / 0.02)
        }
    }

    /// Filtered noise: `dark` near 1 is bright, near 0 is dull; decays over `decay` s.
    private static func noise(_ seconds: Float, seed: UInt32, dark: Float = 0.5, decay: Float = 0.004) -> [Float] {
        var x = seed == 0 ? 1 : seed
        var lp: Float = 0
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            let r = Float(x % 10_000) / 5_000 - 1
            lp += (r - lp) * dark
            return lp * exp(-Float(i) / rate / decay)
        }
    }

    /// A noise whisk whose brightness sweeps from `from` to `to`, shaped as a swell.
    private static func whisk(_ seconds: Float, seed: UInt32, from: Float, to: Float) -> [Float] {
        var x = seed == 0 ? 1 : seed
        var lp: Float = 0
        var hp: Float = 0
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            let r = Float(x % 10_000) / 5_000 - 1
            let u = Float(i) / Float(max(n, 1))
            lp += (r - lp) * (from + (to - from) * u)
            hp += (lp - hp) * 0.05
            return (lp - hp) * sin(.pi * u)
        }
    }

    private static func mix(_ part: [Float], into out: inout [Float], at seconds: Float, gain: Float) {
        let o = Int(seconds * rate)
        if out.count < o + part.count { out += [Float](repeating: 0, count: o + part.count - out.count) }
        for (i, v) in part.enumerated() { out[o + i] += v * gain }
    }

    private static func normalise(_ out: [Float], peak target: Float) -> [Float] {
        let peak = out.map { abs($0) }.max() ?? 0
        return peak > 0 ? out.map { $0 / peak * target } : out
    }

    private static func render(_ cue: Cue) -> [Float] {
        var out: [Float] = []
        switch cue {
        case .step(let p):
            // A typewriter key: a dry clack with a little wooden body.
            mix(noise(0.02, seed: p == 0 ? 41 : 43, dark: 0.55, decay: 0.005), into: &out, at: 0, gain: 1)
            mix(tone(p == 0 ? 210 : 180, 0.05, decay: 0.012, bright: 0.5), into: &out, at: 0.002, gain: 0.6)
            return normalise(out, peak: 0.11)
        case .descend:
            for k in 0..<7 {                                              // carriage-return ratchet
                mix(noise(0.01, seed: UInt32(61 + k * 7), dark: 0.6), into: &out, at: Float(k) * 0.018, gain: 0.7)
                mix(tone(1100 + Float(k) * 90, 0.015, decay: 0.004), into: &out, at: Float(k) * 0.018, gain: 0.25)
            }
            mix(noise(0.03, seed: 71, dark: 0.3, decay: 0.01), into: &out, at: 0.13, gain: 0.9)
            mix(tone(110, 0.12, decay: 0.035, bend: 0.85), into: &out, at: 0.132, gain: 1)
            return normalise(out, peak: 0.16)
        case .fire:
            mix(whisk(0.07, seed: 5, from: 0.15, to: 0.7), into: &out, at: 0, gain: 1)
            mix(tone(700, 0.06, decay: 0.02, bend: 1.8), into: &out, at: 0.005, gain: 0.25)
            return normalise(out, peak: 0.12)
        case .hit(let n):
            let f = ladder[min(max(n, 0), hitLevels)]
            mix(noise(0.03, seed: 13, dark: 0.45, decay: 0.008), into: &out, at: 0, gain: 0.9)   // paper pop
            mix(tone(f, 0.16, decay: 0.05, bright: 0.35), into: &out, at: 0.004, gain: 1)
            mix(tone(f * 2, 0.08, decay: 0.02), into: &out, at: 0.004, gain: 0.25)
            return normalise(out, peak: 0.2 + 0.008 * Float(min(n, hitLevels)))
        case .tink:
            mix(tone(2600, 0.09, decay: 0.025), into: &out, at: 0, gain: 1)
            mix(tone(3720, 0.06, decay: 0.015), into: &out, at: 0, gain: 0.5)
            mix(noise(0.008, seed: 17, dark: 0.9), into: &out, at: 0, gain: 0.5)
            return normalise(out, peak: 0.13)
        case .enemyFire:
            mix(tone(900, 0.05, decay: 0.018, bend: 0.65), into: &out, at: 0, gain: 1)
            return normalise(out, peak: 0.05)
        case .urgentPing:
            mix(tone(1318.5, 0.12, decay: 0.05), into: &out, at: 0, gain: 1)
            mix(tone(987.8, 0.16, decay: 0.06), into: &out, at: 0.11, gain: 0.9)
            return normalise(out, peak: 0.09)
        case .urgentHit:
            mix(noise(0.04, seed: 19, dark: 0.4, decay: 0.012), into: &out, at: 0, gain: 1)
            let run: [Float] = [1046.5, 1318.5, 1568, 2093, 2637]
            for (k, f) in run.enumerated() { mix(bell(f, 0.6), into: &out, at: 0.02 + Float(k) * 0.05, gain: 0.7) }
            for k in 0..<5 { mix(bell(2637 * pow(2, Float(k % 3) * 4 / 12), 0.3), into: &out, at: 0.32 + Float(k) * 0.045, gain: 0.3) }
            return normalise(out, peak: 0.34)
        case .streakLost:
            mix(tone(659.25, 0.12, decay: 0.05), into: &out, at: 0, gain: 1)
            mix(tone(493.88, 0.2, decay: 0.08), into: &out, at: 0.1, gain: 1)
            return normalise(out, peak: 0.09)
        case .playerHit:
            mix(noise(0.18, seed: 23, dark: 0.25, decay: 0.05), into: &out, at: 0, gain: 1)     // crumple
            mix(noise(0.05, seed: 29, dark: 0.6, decay: 0.012), into: &out, at: 0.04, gain: 0.6)
            mix(tone(320, 0.4, decay: 0.14, bend: 0.3, bright: 0.4), into: &out, at: 0.02, gain: 0.9)
            return normalise(out, peak: 0.3)
        case .waveClear:
            mix(whisk(0.22, seed: 31, from: 0.08, to: 0.8), into: &out, at: 0, gain: 0.8)        // sent!
            let chord: [Float] = [523.25, 659.25, 783.99, 1046.5, 1318.5]
            for (k, f) in chord.enumerated() { mix(bell(f, 1.1), into: &out, at: 0.18 + Float(k) * 0.075, gain: 0.6) }
            mix(tone(261.6, 0.9, decay: 0.35, bright: 0.1), into: &out, at: 0.18, gain: 0.35)
            return normalise(out, peak: 0.34)
        case .over:
            let fall: [Float] = [783.99, 659.25, 523.25, 392.0]
            for (k, f) in fall.enumerated() { mix(tone(f, 0.32, decay: 0.12, bright: 0.25), into: &out, at: Float(k) * 0.17, gain: 0.8) }
            mix(noise(0.05, seed: 37, dark: 0.2, decay: 0.02), into: &out, at: 0.7, gain: 0.9)
            mix(tone(70, 0.45, decay: 0.15, bend: 0.7), into: &out, at: 0.7, gain: 1.3)
            return normalise(out, peak: 0.34)
        case .newRun:
            for (k, f) in [Float(659.25), 880, 1318.5].enumerated() { mix(tone(f, 0.06, decay: 0.025), into: &out, at: Float(k) * 0.05, gain: 1) }
            return normalise(out, peak: 0.13)
        }
    }
}
