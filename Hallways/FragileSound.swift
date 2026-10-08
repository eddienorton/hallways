import Foundation
import AVFoundation

// Oct 7 -- FRAGILE sounds: synthesised bubble wrap. No samples.
// A real bubble-wrap pop is mostly a sharp air crack with a short hollow
// "plip" behind it, so each pop is: a broadband click, a fast-dropping
// resonant body, a little thump of escaping air and a breath of noise.
// Six variants (different pitch and grain) are rotated at random so a run
// of pops never sounds like one sample repeated; within a quick run each
// pop's body climbs a little higher. Pops are panned to where the bubble
// sits on the sheet.
//   pop(v, step)  v = variant 0..5, step = place in a quick run (0 = alone)
//   squeak        a stubborn bubble giving way but holding
//   bang          the stubborn bubble finally going: bigger, lower, louder
//   peel          the spent sheet pulled away, a new one off the roll

@MainActor
enum FragileSound {
    enum Cue: Hashable { case pop(Int, Int), squeak, bang, peel }

    static let variants = 6
    private static var cache: [Cue: Data] = [:]
    private static var players: [AVAudioPlayer] = []

    @discardableResult
    static func prepare(_ cue: Cue) -> Data {
        if let cached = cache[cue] { return cached }
        let data = BobbinSound.wav(render(cue))
        cache[cue] = data
        return data
    }

    /// `pan` -1 (left) ... 1 (right).
    static func play(_ cue: Cue, pan: Float = 0, volume: Float = 0.9) {
        let data = prepare(cue)
        players.removeAll { !$0.isPlaying }
        guard players.count < 24, let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = volume
        player.pan = max(-1, min(1, pan))
        player.prepareToPlay()
        player.play()
        players.append(player)
    }

    static func warmUp() {
        for v in 0..<variants { for s in 0...FragileGame.maxRunStep { prepare(.pop(v, s)) } }
        for cue in [Cue.squeak, .bang, .peel] { prepare(cue) }
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
            return s * exp(-t / decay) * min(1, t / 0.0005) * min(1, (seconds - t) / 0.004)
        }
    }

    private static func noise(_ seconds: Float, seed: UInt32, dark: Float, decay: Float) -> [Float] {
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

    private static func mix(_ part: [Float], into out: inout [Float], at seconds: Float, gain: Float) {
        let o = Int(seconds * rate)
        if out.count < o + part.count { out += [Float](repeating: 0, count: o + part.count - out.count) }
        for (i, v) in part.enumerated() { out[o + i] += v * gain }
    }

    private static func normalise(_ out: [Float], peak target: Float) -> [Float] {
        let peak = out.map { abs($0) }.max() ?? 0
        return peak > 0 ? out.map { $0 / peak * target } : out
    }

    private static let variantPitch: [Float] = [0.88, 0.94, 1.0, 1.05, 1.11, 1.18]

    private static func render(_ cue: Cue) -> [Float] {
        var out: [Float] = []
        switch cue {
        case .pop(let v, let step):
            let vp = variantPitch[min(max(v, 0), variants - 1)]
            let climb = pow(2, Float(min(step, FragileGame.maxRunStep)) * 1.25 / 12)
            let seed = UInt32(11 + v * 17)
            mix(noise(0.006, seed: seed, dark: 0.92, decay: 0.0012), into: &out, at: 0, gain: 1.0)            // the crack
            mix(tone(1350 * vp * climb, 0.05, decay: 0.009, bend: 0.62, bright: 0.35), into: &out, at: 0.0006, gain: 0.75)  // hollow plip
            mix(tone(170 * vp, 0.045, decay: 0.012, bend: 0.8), into: &out, at: 0.001, gain: 0.45)             // air thump
            mix(noise(0.035, seed: seed &+ 5, dark: 0.35, decay: 0.006), into: &out, at: 0.002, gain: 0.4)      // breath
            return normalise(out, peak: 0.34 + 0.012 * Float(min(step, FragileGame.maxRunStep)))
        case .squeak:
            let n = Int(0.14 * rate)
            var phase: Float = 0
            for i in 0..<n {                                                          // rubbery stretch
                let t = Float(i) / rate
                let u = Float(i) / Float(n)
                let f = 430 + 220 * u + 35 * sin(2 * .pi * 38 * t)
                phase += 2 * .pi * f / rate
                out.append((sin(phase) + 0.45 * sin(2 * phase) + 0.2 * sin(3 * phase)) * sin(.pi * u) * 0.6)
            }
            mix(tone(120, 0.06, decay: 0.02), into: &out, at: 0, gain: 0.7)
            return normalise(out, peak: 0.15)
        case .bang:
            mix(noise(0.01, seed: 97, dark: 0.95, decay: 0.002), into: &out, at: 0, gain: 1.0)
            mix(tone(780, 0.08, decay: 0.014, bend: 0.55, bright: 0.4), into: &out, at: 0.0008, gain: 0.8)
            mix(tone(115, 0.12, decay: 0.03, bend: 0.75), into: &out, at: 0.001, gain: 0.9)
            mix(noise(0.09, seed: 101, dark: 0.3, decay: 0.018), into: &out, at: 0.002, gain: 0.6)
            let body = out
            mix(body, into: &out, at: 0.055, gain: 0.18)                              // a little room
            return normalise(out, peak: 0.55)
        case .peel:
            var x: UInt32 = 4242
            var t: Float = 0
            while t < 0.42 {                                                          // crackle, thickening
                x ^= x << 13; x ^= x >> 17; x ^= x << 5
                mix(noise(0.004, seed: x, dark: 0.85, decay: 0.001), into: &out, at: t, gain: 0.35 + 0.5 * t)
                t += 0.004 + Float(x % 100) / 100 * (0.03 - 0.05 * t)
            }
            var lp: Float = 0
            let n = Int(0.4 * rate)
            for i in 0..<n {                                                          // the sheet whisking in
                x ^= x << 13; x ^= x >> 17; x ^= x << 5
                let r = Float(x % 10_000) / 5_000 - 1
                let u = Float(i) / Float(n)
                lp += (r - lp) * (0.05 + 0.3 * u)
                let o = Int(0.3 * rate) + i
                while out.count <= o { out.append(0) }
                out[o] += lp * sin(.pi * u) * 0.5
            }
            mix(tone(90, 0.18, decay: 0.05, bend: 0.8), into: &out, at: 0.66, gain: 0.5)   // settles on the desk
            return normalise(out, peak: 0.2)
        }
    }
}
