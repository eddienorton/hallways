import Foundation
import AVFoundation

// Oct 7 -- MERGER sounds, synthesised in code like the other computer games.
// Its own voice: round, soft "felt-tipped" synth plinks (sine + gentle
// octave, rounded decay) -- not Poker's bright squares, Letterhead's wood or
// Minefield's glass. Merges are pitched and sized by the value they make:
//   4-8       one soft plink
//   16-64     a rising two-note plink, higher each step
//   128-256   a three-note chord bloom
//   512-1024  an arpeggio up into a held chord with shimmer
//   2048+     a full run, a chord and a bell-ish top -- the grin
// Extra merges in the same move add a quick little echo per merge (combo).
//   slide     a soft paper "fff" (moved, nothing merged)
//   bump      a dull tiny thock (that way doesn't move anything)
//   over      a slow descending three notes and a low thud
//   new       a quick paper shuffle

@MainActor
enum MergerSound {
    enum Cue: Hashable { case merge(Int, extra: Int), slide, bump, over, newBoard }

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
        HallwaysAudio.shared.manage(player)          // Oct 8: the mute switch
        player.prepareToPlay()
        player.play()
        players.append(player)
    }

    private static let rate = Float(BobbinSound.rate)

    private static func plink(_ f: Float, _ seconds: Float, decay: Float = 0.25, vibrato: Float = 0) -> [Float] {
        let n = Int(seconds * rate)
        var phase: Float = 0
        return (0..<n).map { i in
            let t = Float(i) / rate
            phase += 2 * .pi * f * (1 + vibrato * sin(2 * .pi * 5.5 * t)) / rate
            let s = sin(phase) + 0.3 * sin(2 * phase) + 0.08 * sin(3 * phase)
            return s * exp(-t / decay) * min(1, t / 0.006) * min(1, (seconds - t) / 0.02)
        }
    }

    private static func paper(_ seconds: Float, seed: UInt32, rising: Bool) -> [Float] {
        var x = seed == 0 ? 1 : seed
        var lp: Float = 0
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            let r = Float(x % 10_000) / 5_000 - 1
            let u = Float(i) / Float(max(n, 1))
            lp += (r - lp) * (rising ? 0.08 + 0.3 * u : 0.35 - 0.25 * u)
            return lp * sin(.pi * u)
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

    /// Major-scale steps above C5.
    private static func note(_ step: Int) -> Float {
        let scale = [0, 2, 4, 5, 7, 9, 11]
        let octave = Int((Float(step) / 7).rounded(.down))
        let semis = scale[((step % 7) + 7) % 7] + 12 * octave
        return 523.25 * pow(2, Float(semis) / 12)
    }

    private static func render(_ cue: Cue) -> [Float] {
        var out: [Float] = []
        switch cue {
        case .merge(let value, let extra):
            let level = max(2, Int(log2(Double(max(value, 4)))))       // 4 -> 2, 8 -> 3 ... 2048 -> 11
            let base = level - 2                                          // 0, 1, 2 ...
            switch level {
            case ...3:
                mix(plink(note(base), 0.22, decay: 0.12), into: &out, at: 0, gain: 1)
            case 4...6:
                mix(plink(note(base), 0.22, decay: 0.12), into: &out, at: 0, gain: 1)
                mix(plink(note(base + 2), 0.28, decay: 0.15), into: &out, at: 0.07, gain: 1)
            case 7...8:
                for (k, s) in [0, 2, 4].enumerated() { mix(plink(note(base + s), 0.6, decay: 0.3), into: &out, at: Float(k) * 0.05, gain: 0.8) }
            case 9...10:
                for (k, s) in [0, 2, 4, 7].enumerated() { mix(plink(note(base - 2 + s), 0.3, decay: 0.15), into: &out, at: Float(k) * 0.07, gain: 0.9) }
                for s in [7, 9, 11] { mix(plink(note(base - 2 + s), 1.1, decay: 0.5, vibrato: 0.006), into: &out, at: 0.3, gain: 0.5) }
            default:
                for k in 0..<8 { mix(plink(note(k), 0.25, decay: 0.12), into: &out, at: Float(k) * 0.06, gain: 0.9) }
                for s in [7, 9, 11, 14] { mix(plink(note(s), 1.6, decay: 0.7, vibrato: 0.008), into: &out, at: 0.5, gain: 0.45) }
                mix(plink(note(18) * 1.003, 1.4, decay: 0.5), into: &out, at: 0.55, gain: 0.35)
            }
            for k in 0..<min(extra, 3) {                                 // combo echoes
                mix(plink(note(base + 4 + k), 0.12, decay: 0.05), into: &out, at: 0.12 + Float(k) * 0.06, gain: 0.5)
            }
            let peak = min(0.18 + 0.04 * Float(level), 0.62)
            return normalise(out, peak: peak)
        case .slide:
            mix(paper(0.09, seed: 13, rising: false), into: &out, at: 0, gain: 1)
            return normalise(out, peak: 0.09)
        case .bump:
            mix(plink(110, 0.08, decay: 0.025), into: &out, at: 0, gain: 1)
            return normalise(out, peak: 0.12)
        case .over:
            for (k, s) in [4, 2, -1].enumerated() { mix(plink(note(s), 0.5, decay: 0.3), into: &out, at: Float(k) * 0.22, gain: 0.8) }
            mix(plink(82, 0.6, decay: 0.2), into: &out, at: 0.66, gain: 1)
            return normalise(out, peak: 0.32)
        case .newBoard:
            for k in 0..<3 { mix(paper(0.07, seed: UInt32(41 + k * 7), rising: true), into: &out, at: Float(k) * 0.06, gain: 1) }
            return normalise(out, peak: 0.14)
        }
    }
}
