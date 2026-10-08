import Foundation
import AVFoundation

// Oct 7 -- PAPER JAM sounds: office machinery, synthesised in code like the
// other computer games. Ticks and ratchets and a soft bell -- a desk printer,
// not an arcade. No music: the falling has its own rhythm.
//   move     a very soft tick          rotate   a crisp two-click "tsk"
//   soft     a faint low tick           lock     "ka-chunk": a click on a low thump
//   drop     a short downward whoosh into a heavier chunk
//   clear    a paper-feed ratchet that runs longer and climbs higher with
//            each extra row, then bells: 1 row one bell, 2 two, 3 a triad,
//            4 ("full ream") an arpeggio with a shimmer on top
//   danger   a quiet low double thump while the stack is high
//   over     the ratchet grinding down and stopping on a thud
//   new      a quick feed whirr: straight back in

@MainActor
enum PaperJamSound {
    enum Cue: Hashable { case move, rotate, soft, lock, drop, clear(Int), danger, over, newRun }

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

    /// Render everything up front, so the first line clear is instant.
    static func warmUp() {
        for cue in [Cue.move, .rotate, .soft, .lock, .drop, .clear(1), .clear(2), .clear(3), .clear(4), .danger, .over] { prepare(cue) }
    }

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
            let s = sin(2 * .pi * f * t) + 0.4 * sin(2 * .pi * f * 2.76 * t) * exp(-t / 0.15) + 0.2 * sin(2 * .pi * f * 5.4 * t) * exp(-t / 0.06)
            return s * exp(-t / (seconds * 0.4)) * min(1, t / 0.002) * min(1, (seconds - t) / 0.02)
        }
    }

    private static func click(_ seconds: Float, seed: UInt32, dark: Float = 0.5) -> [Float] {
        var x = seed == 0 ? 1 : seed
        var lp: Float = 0
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            let r = Float(x % 10_000) / 5_000 - 1
            lp += (r - lp) * dark
            return lp * exp(-Float(i) / rate / 0.004)
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

    /// A paper-feed ratchet: `count` clicks, speeding up / climbing (or slowing / falling).
    private static func ratchet(_ count: Int, start: Float, gap: Float, rising: Bool, into out: inout [Float], at t0: Float, gain: Float) {
        var t = t0
        for k in 0..<count {
            let u = Float(k) / Float(max(count - 1, 1))
            let f = rising ? 900 + 900 * u : 1500 - 1100 * u
            mix(click(0.012, seed: UInt32(101 + k * 13), dark: 0.6), into: &out, at: t, gain: gain)
            mix(tone(f, 0.02, decay: 0.005), into: &out, at: t, gain: gain * 0.35)
            t += rising ? gap * (1 - 0.4 * u) : gap * (1 + 1.5 * u)
        }
    }

    private static func render(_ cue: Cue) -> [Float] {
        var out: [Float] = []
        switch cue {
        case .move:
            mix(click(0.01, seed: 7, dark: 0.7), into: &out, at: 0, gain: 1)
            return normalise(out, peak: 0.07)
        case .rotate:
            mix(click(0.01, seed: 9, dark: 0.8), into: &out, at: 0, gain: 1)
            mix(click(0.01, seed: 19, dark: 0.8), into: &out, at: 0.022, gain: 0.8)
            mix(tone(2200, 0.03, decay: 0.008), into: &out, at: 0.02, gain: 0.3)
            return normalise(out, peak: 0.12)
        case .soft:
            mix(tone(300, 0.03, decay: 0.008), into: &out, at: 0, gain: 1)
            return normalise(out, peak: 0.05)
        case .lock:
            mix(click(0.015, seed: 23, dark: 0.35), into: &out, at: 0, gain: 0.8)
            mix(tone(95, 0.14, decay: 0.04, bend: 0.8), into: &out, at: 0.012, gain: 1)
            return normalise(out, peak: 0.2)
        case .drop:
            var lp: Float = 0
            var x: UInt32 = 77
            let n = Int(0.08 * rate)
            for i in 0..<n {                                         // short whoosh, closing down
                x ^= x << 13; x ^= x >> 17; x ^= x << 5
                let r = Float(x % 10_000) / 5_000 - 1
                let u = Float(i) / Float(n)
                lp += (r - lp) * (0.4 - 0.3 * u)
                out.append(lp * sin(.pi * u) * 0.6)
            }
            mix(click(0.02, seed: 29, dark: 0.3), into: &out, at: 0.07, gain: 1)
            mix(tone(80, 0.2, decay: 0.06, bend: 0.75), into: &out, at: 0.075, gain: 1.2)
            return normalise(out, peak: 0.28)
        case .clear(let rows):
            let r = min(max(rows, 1), 4)
            ratchet(5 + 4 * r, start: 0, gap: 0.03, rising: true, into: &out, at: 0, gain: 0.7)
            let bells: [[Float]] = [[1046.5], [1046.5, 1318.5], [1046.5, 1318.5, 1568], [1046.5, 1318.5, 1568, 2093]]
            let at = Float(5 + 4 * r) * 0.024
            for (k, f) in bells[r - 1].enumerated() { mix(bell(f, 0.9), into: &out, at: at + Float(k) * 0.07, gain: 0.7) }
            if r == 4 {
                for k in 0..<6 { mix(bell(2093 * pow(2, Float(k % 3) * 4 / 12), 0.35), into: &out, at: at + 0.32 + Float(k) * 0.05, gain: 0.35) }
            }
            return normalise(out, peak: 0.24 + 0.06 * Float(r))
        case .danger:
            mix(tone(62, 0.12, decay: 0.05), into: &out, at: 0, gain: 1)
            mix(tone(58, 0.12, decay: 0.05), into: &out, at: 0.16, gain: 0.8)
            return normalise(out, peak: 0.14)
        case .over:
            ratchet(14, start: 0, gap: 0.035, rising: false, into: &out, at: 0, gain: 0.8)
            mix(tone(70, 0.45, decay: 0.15, bend: 0.7), into: &out, at: 1.05, gain: 1.3)
            mix(click(0.03, seed: 31, dark: 0.25), into: &out, at: 1.05, gain: 0.8)
            return normalise(out, peak: 0.36)
        case .newRun:
            ratchet(8, start: 0, gap: 0.018, rising: true, into: &out, at: 0, gain: 0.6)
            return normalise(out, peak: 0.14)
        }
    }
}
