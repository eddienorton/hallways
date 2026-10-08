import Foundation
import AVFoundation

// Oct 7 -- LETTERHEAD sounds, synthesised in code like the other computer
// games (rendered once to WAV, played with AVAudioPlayer). Its own voice --
// soft wooden/marimba tones and paper-ish clicks, not Video Poker's bright
// square-wave casino bleeps:
//   tap      a small wooden pop that climbs a step with each letter added
//   remove   the same pop, falling; clear: a quick downward brush
//   shuffle  a little rattle of clicks
//   word     a marimba figure whose length/height grows with the word
//            (3: two notes ... 5: a run + chord); 6 letters: a much bigger
//            cascade with a bell chord on top
//   nope     two muted low knocks (harmless)
//   tick     a wood-block tick each of the last five seconds
//   time up  a bright two-bell "ding-dong" over a low knock
//   result   a short payoff after time up, bigger with a better round

@MainActor
enum LetterheadSound {
    enum Cue: Hashable {
        case tap(Int), remove, clear, shuffle, nope
        case word(Int)                 // letters
        case tick(Int)                 // seconds left (1...5)
        case timeUp
        case result(Int)               // tier 0...3
    }

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

    /// Marimba-ish: a sine plus a quickly-decaying 4th harmonic (the wooden
    /// "tok"), short attack, exponential decay.
    private static func mallet(_ f: Float, _ seconds: Float, decay: Float = 0.18, bend: Float = 1) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        for i in 0..<n {
            let t = Float(i) / rate
            let u = Float(i) / Float(max(n, 1))
            phase += 2 * .pi * f * (1 + (bend - 1) * u) / rate
            let body = sin(phase) * exp(-t / decay)
            let tok = 0.5 * sin(4 * phase) * exp(-t / (decay * 0.15))
            out[i] = (body + tok) * min(1, t / 0.002) * min(1, (seconds - t) / 0.008)
        }
        return out
    }

    /// A bell: inharmonic partials, long decay.
    private static func bell(_ f: Float, _ seconds: Float) -> [Float] {
        let n = Int(seconds * rate)
        let partials: [(Float, Float, Float)] = [(1, 1, 1), (2.76, 0.45, 0.5), (5.4, 0.25, 0.25), (8.93, 0.12, 0.15)]
        return (0..<n).map { i in
            let t = Float(i) / rate
            var s: Float = 0
            for (ratio, amp, d) in partials { s += amp * sin(2 * .pi * f * ratio * t) * exp(-t / (seconds * 0.45 * d)) }
            return s * min(1, t / 0.003) * min(1, (seconds - t) / 0.02)
        }
    }

    /// Soft clicky noise burst (paper / wood).
    private static func click(_ seconds: Float, seed: UInt32, k: Float = 0.5) -> [Float] {
        var x = seed == 0 ? 1 : seed
        var lp: Float = 0
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            let r = Float(x % 10_000) / 5_000 - 1
            lp += (r - lp) * k
            let t = Float(i) / rate
            return lp * exp(-t / 0.006)
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

    /// Pentatonic steps above A4 (no wrong notes, whatever the run).
    private static func pent(_ step: Int) -> Float {
        let scale = [0, 2, 4, 7, 9]
        let semis = scale[((step % 5) + 5) % 5] + 12 * Int((Float(step) / 5).rounded(.down))
        return 440 * pow(2, Float(semis) / 12)
    }

    private static func render(_ cue: Cue) -> [Float] {
        var out: [Float] = []
        switch cue {
        case .tap(let n):
            mix(mallet(pent(n + 3), 0.12, decay: 0.05), into: &out, at: 0, gain: 1)
            return normalise(out, peak: 0.2)
        case .remove:
            mix(mallet(pent(4), 0.12, decay: 0.05, bend: 0.75), into: &out, at: 0, gain: 1)
            return normalise(out, peak: 0.16)
        case .clear:
            mix(mallet(pent(7), 0.18, decay: 0.08, bend: 0.5), into: &out, at: 0, gain: 1)
            mix(click(0.05, seed: 11, k: 0.3), into: &out, at: 0, gain: 0.5)
            return normalise(out, peak: 0.16)
        case .shuffle:
            for k in 0..<8 { mix(click(0.03, seed: UInt32(17 + k * 31), k: 0.6), into: &out, at: Float(k) * 0.028 + (k % 2 == 0 ? 0 : 0.008), gain: 1) }
            return normalise(out, peak: 0.2)
        case .nope:
            mix(mallet(150, 0.14, decay: 0.05), into: &out, at: 0, gain: 1)
            mix(mallet(130, 0.16, decay: 0.06), into: &out, at: 0.1, gain: 1)
            return normalise(out, peak: 0.2)
        case .word(let letters):
            switch letters {
            case ...3:
                for (k, s) in [5, 7].enumerated() { mix(mallet(pent(s), 0.25), into: &out, at: Float(k) * 0.07, gain: 1) }
                return normalise(out, peak: 0.26)
            case 4:
                for (k, s) in [5, 7, 9].enumerated() { mix(mallet(pent(s), 0.28), into: &out, at: Float(k) * 0.065, gain: 1) }
                return normalise(out, peak: 0.3)
            case 5:
                for (k, s) in [5, 7, 9, 10, 12].enumerated() { mix(mallet(pent(s), 0.3), into: &out, at: Float(k) * 0.06, gain: 1) }
                for s in [10, 12, 15] { mix(mallet(pent(s), 0.5, decay: 0.3), into: &out, at: 0.34, gain: 0.5) }
                return normalise(out, peak: 0.38)
            default:                                                     // SIX: a real moment
                for k in 0..<10 { mix(mallet(pent(5 + k), 0.28, decay: 0.14), into: &out, at: Float(k) * 0.05, gain: 1) }
                for k in 0..<6 { mix(mallet(pent(15 - k % 3), 0.18, decay: 0.08), into: &out, at: 0.52 + Float(k) * 0.06, gain: 0.7) }
                for f: Float in [880, 1108.7, 1318.5] { mix(bell(f, 1.3), into: &out, at: 0.55, gain: 0.45) }
                return normalise(out, peak: 0.55)
            }
        case .tick(let secondsLeft):
            let f: Float = secondsLeft <= 3 ? 1600 : 1300
            mix(mallet(f, 0.06, decay: 0.012), into: &out, at: 0, gain: 1)
            mix(click(0.02, seed: 5, k: 0.7), into: &out, at: 0, gain: 0.4)
            return normalise(out, peak: secondsLeft <= 3 ? 0.22 : 0.16)
        case .timeUp:
            mix(bell(988, 0.9), into: &out, at: 0, gain: 1)
            mix(bell(784, 1.2), into: &out, at: 0.22, gain: 1)
            mix(mallet(110, 0.4, decay: 0.15), into: &out, at: 0, gain: 0.8)
            return normalise(out, peak: 0.4)
        case .result(let tier):
            let notes = [3, 5, 7, 9][min(max(tier, 0), 3)]
            for k in 0..<notes { mix(mallet(pent(4 + k), 0.3, decay: 0.15), into: &out, at: Float(k) * 0.07, gain: 1) }
            if tier >= 2 { for s in [9, 12, 14] { mix(mallet(pent(s + tier), 0.7, decay: 0.4), into: &out, at: Float(notes) * 0.07, gain: 0.45) } }
            if tier >= 3 { mix(bell(1318.5, 1.2), into: &out, at: Float(notes) * 0.07, gain: 0.4) }
            return normalise(out, peak: 0.24 + 0.06 * Float(tier))
        }
    }
}
