import Foundation
import AVFoundation

// Oct 7 -- MINEFIELD sounds, synthesised in code like the other computer
// games. Its own voice: quiet, precise, glassy -- crisp ticks and small
// sonar-like pings, nothing musical-instrument or casino about it.
//   reveal   one tiny crisp click (a single numbered cell)
//   cascade  a fast ripple of clicks climbing in pitch, one per opened cell
//            (capped), with a soft rising swell under big openings
//   flag     a low "plant" thud with a small ping on top; unflag: the reverse
//   boom     a sharp crack, a deep falling boom and two sour alarm beeps
//   win      glassy pings climbing to a bright chord
//   field    a soft downward sweep and two ticks: a fresh field laid

@MainActor
enum MinefieldSound {
    enum Cue: Hashable { case reveal, cascade(Int), flag, unflag, boom, win, newField }

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
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = 0.9
        player.prepareToPlay()
        player.play()
        players.append(player)
    }

    // MARK: Synthesis

    private static let rate = Float(BobbinSound.rate)

    private static func ping(_ f: Float, _ seconds: Float, decay: Float, bend: Float = 1) -> [Float] {
        let n = Int(seconds * rate)
        var phase: Float = 0
        return (0..<n).map { i in
            let t = Float(i) / rate
            let u = Float(i) / Float(max(n, 1))
            phase += 2 * .pi * f * (1 + (bend - 1) * u) / rate
            let s = sin(phase) + 0.25 * sin(2.01 * phase)          // a little glassy
            return s * exp(-t / decay) * min(1, t / 0.0015) * min(1, (seconds - t) / 0.006)
        }
    }

    /// Crisp high click: bright filtered noise, very short.
    private static func click(_ seconds: Float, seed: UInt32, bright: Float = 0.75, decay: Float = 0.004) -> [Float] {
        var x = seed == 0 ? 1 : seed
        var prev: Float = 0
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            let r = Float(x % 10_000) / 5_000 - 1
            let hp = r - prev * bright                              // crude high-pass: crisp, not hissy-low
            prev = r
            let t = Float(i) / rate
            return hp * exp(-t / decay)
        }
    }

    private static func noiseBoom(_ seconds: Float, seed: UInt32) -> [Float] {
        var x = seed
        var lp: Float = 0, lp2: Float = 0
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            let r = Float(x % 10_000) / 5_000 - 1
            lp += (r - lp) * 0.05
            lp2 += (lp - lp2) * 0.05
            let t = Float(i) / rate
            return lp2 * 6 * exp(-t / 0.35) * min(1, t / 0.002)
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
        case .reveal:
            mix(click(0.02, seed: 7), into: &out, at: 0, gain: 1)
            mix(ping(2400, 0.04, decay: 0.008), into: &out, at: 0, gain: 0.35)
            return normalise(out, peak: 0.16)
        case .cascade(let n):
            let steps = min(max(n, 2), 26)
            let gap: Float = steps > 14 ? 0.016 : 0.022
            for k in 0..<steps {
                let f = 1500 * pow(2, Float(k) / Float(steps) * 1.3)     // climbs ~1.3 octaves
                mix(click(0.018, seed: UInt32(31 + k * 17)), into: &out, at: Float(k) * gap, gain: 0.8)
                mix(ping(f, 0.05, decay: 0.012), into: &out, at: Float(k) * gap, gain: 0.45)
            }
            if steps >= 10 {                                             // the swell under a big opening
                mix(ping(330, Float(steps) * gap + 0.25, decay: 0.3, bend: 1.5), into: &out, at: 0, gain: 0.35)
                mix(ping(1320 * 1.26, 0.35, decay: 0.12), into: &out, at: Float(steps) * gap, gain: 0.5)
            }
            return normalise(out, peak: steps >= 10 ? 0.3 : 0.22)
        case .flag:
            mix(ping(140, 0.1, decay: 0.03, bend: 0.8), into: &out, at: 0, gain: 1)
            mix(click(0.015, seed: 3, bright: 0.4), into: &out, at: 0, gain: 0.5)
            mix(ping(1760, 0.08, decay: 0.025), into: &out, at: 0.03, gain: 0.35)
            return normalise(out, peak: 0.22)
        case .unflag:
            mix(ping(1760, 0.06, decay: 0.02, bend: 0.7), into: &out, at: 0, gain: 0.35)
            mix(ping(160, 0.08, decay: 0.025, bend: 1.2), into: &out, at: 0.03, gain: 0.8)
            return normalise(out, peak: 0.16)
        case .boom:
            mix(click(0.03, seed: 99, bright: 0.2, decay: 0.01), into: &out, at: 0, gain: 1)       // crack
            mix(noiseBoom(1.0, seed: 4242), into: &out, at: 0.005, gain: 1)                       // boom
            mix(ping(120, 0.9, decay: 0.35, bend: 0.35), into: &out, at: 0.005, gain: 0.9)       // falling body
            for k in 0..<2 {                                                                       // sour alarm
                mix(ping(880, 0.14, decay: 0.12), into: &out, at: 0.45 + Float(k) * 0.2, gain: 0.3)
                mix(ping(932, 0.14, decay: 0.12), into: &out, at: 0.45 + Float(k) * 0.2, gain: 0.3)
            }
            return normalise(out, peak: 0.55)
        case .win:
            let steps: [Float] = [0, 4, 7, 12, 16, 19, 24]
            for (k, s) in steps.enumerated() {
                mix(ping(880 * pow(2, s / 12), 0.35, decay: 0.15), into: &out, at: Float(k) * 0.075, gain: 0.8)
                mix(click(0.015, seed: UInt32(200 + k)), into: &out, at: Float(k) * 0.075, gain: 0.3)
            }
            for s: Float in [12, 16, 19, 24] { mix(ping(880 * pow(2, s / 12), 1.2, decay: 0.5), into: &out, at: 0.6, gain: 0.4) }
            mix(ping(220, 1.2, decay: 0.5), into: &out, at: 0.6, gain: 0.4)
            return normalise(out, peak: 0.45)
        case .newField:
            mix(ping(900, 0.18, decay: 0.08, bend: 0.5), into: &out, at: 0, gain: 0.6)
            mix(click(0.02, seed: 61), into: &out, at: 0.12, gain: 0.8)
            mix(click(0.02, seed: 62), into: &out, at: 0.18, gain: 0.8)
            return normalise(out, peak: 0.16)
        }
    }
}
