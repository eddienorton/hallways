import Foundation
import AVFoundation

// Oct 7 -- VIDEO POKER sounds, synthesised in code (no samples, no casino
// recordings): bright square-ish "computer" bleeps rendered once to WAV and
// played with AVAudioPlayer, in the same spirit as FootstepSynth/BobbinSound.
// The result sounds escalate hard with the hand: a deflating "bwomp" for no
// win, a two-note chirp for jacks, longer/higher/louder fanfares up the
// ladder, and for a royal flush about four seconds of the little computer
// losing its mind -- runs, a bell storm, a big shimmering chord. Bounded.

@MainActor
enum VideoPokerSound {
    enum Cue: Hashable {
        case deal, holdOn, holdOff, draw
        case result(VideoPokerHand)
    }

    private static var cache: [Cue: Data] = [:]
    private static var players: [AVAudioPlayer] = []

    /// Renders (and caches) a cue ahead of time, so playing it later is instant.
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

    /// One note: a soft square (fundamental + odd harmonics) with a quick
    /// attack and an exponential decay; `bend` glides the pitch (ratio at end).
    private static func note(_ f: Float, _ seconds: Float, bright: Float = 1, decay: Float = 0.25, bend: Float = 1,
                             vibrato: Float = 0) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        for i in 0..<n {
            let t = Float(i) / rate
            let u = Float(i) / Float(max(n, 1))
            let freq = f * (1 + (bend - 1) * u) * (1 + vibrato * sin(2 * .pi * 6.5 * t))
            phase += 2 * .pi * freq / rate
            var s = sin(phase)
            s += bright * 0.33 * sin(3 * phase)
            s += bright * 0.2 * sin(5 * phase)
            s += bright * 0.14 * sin(7 * phase)
            let env = min(1, t / 0.004) * exp(-t / max(decay, 0.01)) * min(1, (seconds - t) / 0.01)
            out[i] = s * env
        }
        return out
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

    /// Notes by semitone above C5 (523.25 Hz).
    private static func hz(_ semitone: Int) -> Float { 523.25 * pow(2, Float(semitone) / 12) }

    /// A run of notes, `step` seconds apart.
    private static func run(_ semis: [Int], step: Float, length: Float, gain: Float, into out: inout [Float],
                            at start: Float, decay: Float = 0.12) {
        for (k, s) in semis.enumerated() {
            mix(note(hz(s), length, decay: decay), into: &out, at: start + Float(k) * step, gain: gain)
        }
    }

    /// A held chord with a little shimmer.
    private static func chord(_ semis: [Int], seconds: Float, gain: Float, into out: inout [Float], at start: Float,
                              vibrato: Float = 0.006) {
        for s in semis { mix(note(hz(s), seconds, bright: 0.8, decay: seconds * 0.55, vibrato: vibrato), into: &out, at: start, gain: gain) }
    }

    private static func render(_ cue: Cue) -> [Float] {
        var out: [Float] = []
        switch cue {
        case .deal:                                                  // five quick card ticks
            for k in 0..<5 { mix(note(1500 + Float(k) * 60, 0.03, bright: 0.6, decay: 0.012), into: &out, at: Float(k) * 0.055, gain: 1) }
            return normalise(out, peak: 0.22)
        case .holdOn:                                                // up-blip
            mix(note(hz(7), 0.05, decay: 0.03), into: &out, at: 0, gain: 1)
            mix(note(hz(12), 0.07, decay: 0.04), into: &out, at: 0.04, gain: 1)
            return normalise(out, peak: 0.2)
        case .holdOff:                                               // down-blip
            mix(note(hz(12), 0.05, decay: 0.03), into: &out, at: 0, gain: 1)
            mix(note(hz(5), 0.07, decay: 0.04), into: &out, at: 0.04, gain: 1)
            return normalise(out, peak: 0.16)
        case .draw:                                                  // rising zip + card ticks
            mix(note(320, 0.16, bright: 0.5, decay: 0.12, bend: 3.2), into: &out, at: 0, gain: 0.7)
            for k in 0..<4 { mix(note(1600, 0.025, bright: 0.6, decay: 0.01), into: &out, at: 0.12 + Float(k) * 0.05, gain: 0.6) }
            return normalise(out, peak: 0.22)
        case .result(let hand):
            return renderResult(hand)
        }
    }

    private static func renderResult(_ hand: VideoPokerHand) -> [Float] {
        var out: [Float] = []
        switch hand {
        case .nothing:                                               // bwah-bwommp: the machine shrugs at you
            mix(note(196, 0.2, bright: 1, decay: 0.3, bend: 0.97), into: &out, at: 0, gain: 1)
            mix(note(147, 0.5, bright: 1, decay: 0.4, bend: 0.82), into: &out, at: 0.2, gain: 1)
            return normalise(out, peak: 0.26)
        case .jacksOrBetter:                                         // small "ding-ding"
            run([7, 12], step: 0.09, length: 0.22, gain: 1, into: &out, at: 0, decay: 0.12)
            return normalise(out, peak: 0.3)
        case .twoPair:
            run([0, 4, 7, 12], step: 0.075, length: 0.22, gain: 1, into: &out, at: 0)
            return normalise(out, peak: 0.36)
        case .threeOfAKind:
            run([0, 4, 7, 12, 16], step: 0.07, length: 0.22, gain: 1, into: &out, at: 0)
            chord([12, 16, 19], seconds: 0.35, gain: 0.5, into: &out, at: 0.36)
            return normalise(out, peak: 0.4)
        case .straight, .flush:                                      // clearly a celebration
            run([0, 2, 4, 7, 9, 12, 14, 16], step: 0.06, length: 0.2, gain: 1, into: &out, at: 0)
            run([19, 24], step: 0.12, length: 0.28, gain: 1, into: &out, at: 0.5)
            chord([12, 16, 19, 24], seconds: 0.6, gain: 0.45, into: &out, at: 0.72)
            return normalise(out, peak: 0.48)
        case .fullHouse:                                             // substantial: two climbs + a fanfare chord
            run([0, 4, 7, 12, 16, 19, 24], step: 0.05, length: 0.18, gain: 1, into: &out, at: 0)
            run([5, 9, 12, 17, 21, 24, 29], step: 0.05, length: 0.18, gain: 1, into: &out, at: 0.38)
            for k in 0..<3 { mix(note(hz(24), 0.16, decay: 0.1), into: &out, at: 0.78 + Float(k) * 0.12, gain: 0.9) }
            chord([12, 16, 19, 24, 28], seconds: 0.9, gain: 0.4, into: &out, at: 1.15)
            return normalise(out, peak: 0.55)
        case .fourOfAKind:                                           // big event: fast ladder, bell bursts, big chord
            run(Array(stride(from: 0, through: 31, by: 2)), step: 0.04, length: 0.14, gain: 1, into: &out, at: 0, decay: 0.08)
            for k in 0..<10 { mix(note(hz(k % 2 == 0 ? 24 : 28), 0.1, decay: 0.06), into: &out, at: 0.7 + Float(k) * 0.07, gain: 0.85) }
            chord([0, 12, 16, 19, 24, 28], seconds: 1.2, gain: 0.38, into: &out, at: 1.45)
            return normalise(out, peak: 0.62)
        case .straightFlush:                                         // very big: two ladders, a warbling trill, huge chord
            run(Array(stride(from: 0, through: 33, by: 3)), step: 0.04, length: 0.14, gain: 1, into: &out, at: 0, decay: 0.08)
            run(Array(stride(from: 5, through: 38, by: 3)), step: 0.04, length: 0.14, gain: 1, into: &out, at: 0.5, decay: 0.08)
            for k in 0..<20 { mix(note(hz(k % 2 == 0 ? 24 : 27), 0.07, decay: 0.05), into: &out, at: 1.0 + Float(k) * 0.05, gain: 0.8) }
            chord([0, 7, 12, 16, 19, 24, 28], seconds: 1.4, gain: 0.34, into: &out, at: 2.0, vibrato: 0.01)
            return normalise(out, peak: 0.7)
        case .royalFlush:                                            // ~4 s: the office computer loses its mind
            for pass in 0..<3 {
                run(Array(stride(from: pass * 4, through: pass * 4 + 36, by: 3)), step: 0.035, length: 0.12, gain: 1,
                    into: &out, at: Float(pass) * 0.45, decay: 0.07)
            }
            // Bell storm: a rising, alternating major-chord flurry.
            let bells = [24, 28, 31, 36, 31, 28]
            for k in 0..<36 {
                let s = bells[k % bells.count] + (k / 12) * 2
                mix(note(hz(s), 0.09, decay: 0.05), into: &out, at: 1.35 + Float(k) * 0.045, gain: 0.75)
            }
            // Siren-ish sweeps under the bells.
            for k in 0..<3 { mix(note(hz(12), 0.35, bright: 0.4, decay: 0.4, bend: 2), into: &out, at: 1.35 + Float(k) * 0.5, gain: 0.35) }
            // The big shimmering chord.
            chord([0, 7, 12, 16, 19, 24, 28, 31, 36], seconds: 1.6, gain: 0.3, into: &out, at: 3.0, vibrato: 0.014)
            return normalise(out, peak: 0.8)
        }
    }
}
