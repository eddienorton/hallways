import Foundation

/// Oct 6 -- the player's own footsteps, synthesised (no recorded assets),
/// in the same spirit as the critter / Administration sounds.
///
/// SoundEffects still plays them exactly as before -- one looping
/// AVAudioPlayer per direction, started/stopped by navigation, its rate
/// following the walking pace -- only the loop's SOURCE changed. Each loop
/// matches the old recordings' length and two-step cadence (shoes: 1.24 s,
/// steps ~0.62 s apart; heels: 1.0 s, ~0.5 s apart), and the backward loop
/// is the forward one reversed, as the old "-reverse" files were.
///
/// The sound: a soft shoe on a hard office floor -- a low muffled heel
/// strike with a little body thump, then a quieter sole roll -- or, for
/// heels, a small bright click over a low knock, then a light sole tap;
/// each with two faint early reflections for an indoor room. Quiet: peaks
/// at about the old recordings' level.
nonisolated enum FootstepSynth {
    enum Style: String { case shoe, heel }

    private static let rate = Float(BobbinSound.rate)

    /// A cached WAV loop for this style/direction (rendered once per install).
    static func loopURL(_ style: Style, reverse: Bool) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("footsteps-v1-\(style.rawValue)\(reverse ? "-reverse" : "").wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            var samples = loop(style)
            if reverse { samples.reverse() }
            guard (try? BobbinSound.wav(samples).write(to: url)) != nil else { return nil }
        }
        return url
    }

    private static func loop(_ style: Style) -> [Float] {
        let length: Float = style == .shoe ? 1.24 : 1.0
        let second: Float = style == .shoe ? 0.64 : 0.52
        var out = [Float](repeating: 0, count: Int(length * rate))
        var rng = MenagerieSound.Rand(seed: style == .shoe ? 61 : 62)
        // Left foot, right foot: slightly different weight and pitch.
        for (at, gain, pitch) in [(Float(0.02), Float(1.0), Float(1.0)), (second, Float(0.86), Float(0.94))] {
            let step: [Float]
            if style == .shoe { step = shoeStep(pitch: pitch, rng: &rng) } else { step = heelStep(pitch: pitch, rng: &rng) }
            add(step, into: &out, at: at, gain: gain)
        }
        // Indoor room: two faint early reflections.
        let dry = out
        add(dry, into: &out, at: 0.021, gain: 0.16)
        add(dry, into: &out, at: 0.037, gain: 0.09)
        let peak = out.map { abs($0) }.max() ?? 1
        let target: Float = style == .shoe ? 0.12 : 0.08
        return peak > 0 ? out.map { $0 / peak * target } : out
    }

    private static func add(_ samples: [Float], into out: inout [Float], at: Float, gain: Float) {
        let o = Int(at * rate)
        for (i, v) in samples.enumerated() where o + i < out.count { out[o + i] += v * gain }
    }

    /// Low-passed noise burst (k: smoothing, smaller = darker) with an exp decay.
    private static func noiseBurst(seconds: Float, decay: Float, k: Float, rng: inout MenagerieSound.Rand) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var lp: Float = 0, lp2: Float = 0
        for i in 0..<n {
            let t = Float(i) / rate
            lp += ((rng.unit() * 2 - 1) - lp) * k
            lp2 += (lp - lp2) * k
            out[i] = lp2 * exp(-t / decay) * min(1, t / 0.0015)
        }
        // Filtered noise is quiet by nature; normalise so `gain` means level.
        let peak = out.map { abs($0) }.max() ?? 0
        return peak > 0 ? out.map { $0 / peak } : out
    }

    private static func tone(_ f: Float, seconds: Float, decay: Float) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            let t = Float(i) / rate
            return sin(2 * .pi * f * t) * exp(-t / decay) * min(1, t / 0.002)
        }
    }

    private static func shoeStep(pitch: Float, rng: inout MenagerieSound.Rand) -> [Float] {
        var step = [Float](repeating: 0, count: Int(0.22 * rate))
        add(noiseBurst(seconds: 0.08, decay: 0.012, k: 0.09 * pitch, rng: &rng), into: &step, at: 0, gain: 1.0)   // heel strike
        add(tone(95 * pitch, seconds: 0.12, decay: 0.035), into: &step, at: 0, gain: 0.35)                         // body thump
        add(tone(180 * pitch, seconds: 0.08, decay: 0.018), into: &step, at: 0, gain: 0.12)
        add(noiseBurst(seconds: 0.09, decay: 0.018, k: 0.2 * pitch, rng: &rng), into: &step, at: 0.06, gain: 0.45) // sole roll
        add(noiseBurst(seconds: 0.06, decay: 0.025, k: 0.45, rng: &rng), into: &step, at: 0.07, gain: 0.06)       // faint scuff
        return step
    }

    private static func heelStep(pitch: Float, rng: inout MenagerieSound.Rand) -> [Float] {
        var step = [Float](repeating: 0, count: Int(0.2 * rate))
        add(tone(2600 * pitch, seconds: 0.05, decay: 0.008), into: &step, at: 0, gain: 0.45)                       // click
        add(tone(4100 * pitch, seconds: 0.04, decay: 0.005), into: &step, at: 0, gain: 0.2)
        add(noiseBurst(seconds: 0.02, decay: 0.003, k: 0.6, rng: &rng), into: &step, at: 0, gain: 0.35)
        add(tone(160 * pitch, seconds: 0.08, decay: 0.02), into: &step, at: 0, gain: 0.3)                          // low knock
        add(noiseBurst(seconds: 0.06, decay: 0.015, k: 0.15, rng: &rng), into: &step, at: 0.09, gain: 0.3)        // sole tap
        return step
    }
}
