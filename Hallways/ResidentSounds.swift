//
//  ResidentSounds.swift
//  Hallways
//
//  Oct 18 (resident audio) -- WHO MADE THAT SOUND, AND THE RESIDENTS' VOICES.
//
//  SoundCatalog  every synthesised sound by name (MenagerieSound registers each
//                one as it's made), so a playing SCNAudioSource can be named.
//  AudioWatch    what critter sounds have played lately: which critter, which
//                sound, how far, how loud, through how much building -- and how
//                often. The developer panel's SOUNDS lines; the phone's
//                proximity pulse. Every critter sound in the game goes through
//                CritterAudio.play, which reports here.
//  ResidentVoice the residents' own sound identities (Hallenese, never words):
//                  chair      soft wooden shuffles as it walks (not a beat:
//                             irregular, quiet), a restrained creak now and then,
//                             a knock at a door, a small swivel squeak at work
//                  butterfly  her chirps (her voice, unchanged) and a very soft,
//                             airy wing flutter -- never a thump
//                and their Contacts previews -- the same sounds, by name.
//
//  The pounding (Oct 18 trace): the chair's footsteps were a raw SceneKit
//  playAudio loop, a click every 0.3 s that bypassed CritterAudio entirely --
//  no distance fade, no walls, no Mute -- so it sounded the same wherever the
//  chair was on the floor; and the butterfly's "flutter" was a 140 Hz thud,
//  also played raw. Both now go through CritterAudio, and both are replaced
//  (see ResidentChair / ButterflyBody). AudioWatch is how to confirm on device.
//

import Foundation
import QuartzCore
import SceneKit
import simd

// MARK: - Names of sounds

nonisolated enum SoundCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: [ObjectIdentifier: String] = [:]

    static func register(_ source: SCNAudioSource, name: String) {
        lock.lock(); names[ObjectIdentifier(source)] = name; lock.unlock()
    }

    static func name(of source: SCNAudioSource) -> String {
        lock.lock(); defer { lock.unlock() }
        return names[ObjectIdentifier(source)] ?? "unnamed sound"
    }

    /// Where a synthesised sound's file is (for a plain, non-positional preview).
    static func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mng-v1-\(name).wav")
    }
}

// MARK: - What's been heard

nonisolated final class AudioWatch: @unchecked Sendable {
    struct Entry: Equatable {
        let critter: String
        let sound: String
        let outcome: String
        let gain: Float
        let distance: Float
        let at: CFTimeInterval
        /// Where it came from (world x, z), when it played.
        let point: SIMD2<Float>?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []
    nonisolated(unsafe) private static var lastLog: [String: CFTimeInterval] = [:]

    /// The node's critter: its own name, or the nearest named ancestor's.
    static func critterName(_ node: SCNNode) -> String {
        var n: SCNNode? = node
        while let c = n {
            if let name = c.name, !name.isEmpty { return name }
            n = c.parent
        }
        return "unnamed node"
    }

    static func heard(critter: String, source: SCNAudioSource, outcome: String, gain: Float, distance: Float,
                      at point: SIMD2<Float>? = nil, now: CFTimeInterval = CACurrentMediaTime()) {
        let e = Entry(critter: critter, sound: SoundCatalog.name(of: source), outcome: outcome, gain: gain, distance: distance,
                      at: now, point: point)
        lock.lock()
        entries.append(e)
        entries.removeAll { now - $0.at > 12 }
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        let key = "\(e.critter)|\(e.sound)"
        let due = now - (lastLog[key] ?? 0) >= 2
        if due { lastLog[key] = now }
        let count = entries.filter { $0.critter == e.critter && $0.sound == e.sound && now - $0.at <= 8 }.count
        lock.unlock()
        if due {
            print(String(format: "[Sound] %@ %@ %.1fm vol %.2f (%@) x%d in 8s", e.critter, e.sound, e.distance, e.gain, e.outcome, count))
        }
    }

    /// The last `seconds` of sounds.
    static func recent(_ seconds: CFTimeInterval = 8, now: CFTimeInterval = CACurrentMediaTime()) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { now - $0.at <= seconds }
    }

    /// For the panel: each critter/sound heard lately, loudest-latest first --
    /// "residentChair  chair-shuffle-2  4.3m  vol 0.21  clear  x9/8s".
    static func summary(_ seconds: CFTimeInterval = 8, now: CFTimeInterval = CACurrentMediaTime()) -> [String] {
        let list = recent(seconds, now: now)
        var groups: [String: [Entry]] = [:]
        for e in list { groups["\(e.critter)|\(e.sound)", default: []].append(e) }
        return groups.values.compactMap { g -> (CFTimeInterval, String)? in
            guard let last = g.max(by: { $0.at < $1.at }) else { return nil }
            let line = String(format: "%@ %@ %.1fm vol %.2f %@ x%d/%ds", last.critter, last.sound, last.distance, last.gain,
                              last.outcome, g.count, Int(seconds))
            return (last.at, line)
        }
        .sorted { $0.0 > $1.0 }
        .map { $0.1 }
    }

    /// How loud the loudest critter heard in the last few seconds was (0...1) --
    /// the phone's proximity pulse.
    static func nearness(_ seconds: CFTimeInterval = 3, now: CFTimeInterval = CACurrentMediaTime()) -> Float {
        recent(seconds, now: now).filter { $0.gain > 0 }.map { e -> Float in
            let age = Float(now - e.at)
            return min(1, e.gain * 2.2) * max(0, 1 - age / Float(seconds))        // (fading as it ages)
        }.max() ?? 0
    }

    static func reset() { lock.lock(); entries = []; lastLog = [:]; lock.unlock() }
}

// MARK: - The residents' voices

nonisolated enum ResidentVoice {
    // The chair: wood, quietly.
    /// A soft wooden shuffle -- a brush of noise with a small dull knock in it.
    static let chairShuffles: [SCNAudioSource] = MenagerieSound.variants("chair-shuffle", count: 5, volume: 0.16) { rng in
        let knock = MenagerieSound.strike([(rng.range(520, 680), 0.018, 0.5), (rng.range(1150, 1400), 0.008, 0.2)],
                                          seconds: 0.09, noise: 0.25, noiseDecay: 0.004, rng: &rng)
        let brush = MenagerieSound.strike([(rng.range(250, 320), 0.03, 0.08)], seconds: 0.16, noise: 1, noiseDecay: 0.04, rng: &rng)
        return MenagerieSound.mix([(0, brush, 0.35), (0.02, knock, 0.55)])
    }
    /// A restrained creak (lower and quieter than its old idle creak).
    static let chairCreaks: [SCNAudioSource] = MenagerieSound.variants("chair-softcreak", count: 3, volume: 0.24) { rng in
        MenagerieSound.creak(resonance: rng.range(380, 520), q: 10, startHz: rng.range(22, 30), endHz: rng.range(34, 46),
                             seconds: rng.range(0.3, 0.5), rng: &rng)
    }
    /// A small swivel squeak (its mechanical side).
    static let chairSwivel = MenagerieSound.source("chair-swivel", volume: 0.18) {
        MenagerieSound.sweep(880, 1240, seconds: 0.22, wobble: 0.08, curve: 0.8)
    }
    /// Its knock on a door it's pushing (was the heavy thump).
    static let chairKnock = MenagerieSound.source("chair-knock", volume: 0.3) {
        var rng = MenagerieSound.Rand(seed: 31)
        return MenagerieSound.strike([(420, 0.03, 0.6), (900, 0.015, 0.25)], seconds: 0.12, noise: 0.3, noiseDecay: 0.003, rng: &rng)
    }

    // The butterfly: air.
    /// A very soft flutter: a few tiny, quick puffs of high air.
    static let butterflyWings: [SCNAudioSource] = MenagerieSound.variants("butterfly-wings", count: 3, volume: 0.14) { rng in
        let rate = MenagerieSound.rate
        let puffs = 4 + Int(rng.unit() * 3)
        let n = Int(rate * (0.04 * Float(puffs) + 0.06))
        var out = [Float](repeating: 0, count: n)
        var prev: Float = 0
        for k in 0..<puffs {
            let start = Int(rate * 0.04 * Float(k))
            let len = Int(rate * 0.028)
            let level = 1 - Float(k) / Float(puffs + 1)
            for i in 0..<len where start + i < n {
                let x = rng.range(-1, 1)
                let airy = x - prev                       // (a difference of noise: thin and high, no body)
                prev = x
                let env = sin(Float(i) / Float(len) * .pi)
                out[start + i] += airy * env * level
            }
        }
        return out
    }
}

// MARK: - The car moving in its shaft (Oct 18; rebuilt Oct 19)

/// What the player hears of the elevator when someone else is using it.
///
/// Oct 19 (Eddie: "far too loud... a hissing hand dryer"): the Oct 18 whir
/// was a 55/110 Hz hum plus low-passed noise, normalised to full scale and
/// replayed every 1.9 s while the car moved anywhere within six floors. An
/// iPhone speaker can't reproduce 55-110 Hz, so what reached the ear was the
/// noise and the speaker straining -- the hiss -- nearly all the time.
///
/// Now: a quiet motor RUMBLE with no noise at all -- a 98 Hz fundamental the
/// speaker can hint at, carried by harmonics it can play (196-490 Hz), a slow
/// hunting wobble, the pitch rising as the car gets up to speed and falling
/// as it slows (subtle acceleration and deceleration), swelling in and out.
/// Played ONCE per approach, only when the car is coming toward this floor
/// (two floors away or nearer) or setting off from it; never on an
/// onboarding floor; never while the player rides. CritterAudio fades it
/// with the player's distance from the doors. The arrival chime is untouched
/// and stays the clear signal.
nonisolated enum ElevatorShaftSound {
    static let seconds: Float = 3.6

    /// One pass of the motor (pure: no noise, gentle ends). `glide` > 0: the
    /// pitch rises into the run then eases off (a car speeding up and slowing down).
    static func rumble(seconds: Float = seconds, base: Float = 98, glide: Float = 0.06) -> [Float] {
        let rate = MenagerieSound.rate
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        let partials: [(Float, Float)] = [(1, 0.55), (2, 0.5), (3, 0.32), (4, 0.18), (5, 0.08)]
        var phase = [Float](repeating: 0, count: partials.count)
        for k in 0..<n {
            let t = Float(k) / rate
            let u = t / seconds                                        // 0 -> 1 through the pass
            let speed = sin(.pi * u)                                    // up to speed, then slowing
            let f0 = base * (1 + glide * (speed - 0.5)) * (1 + 0.004 * sin(2 * .pi * 3.1 * t))   // (a little hunting)
            var v: Float = 0
            for (j, p) in partials.enumerated() {
                phase[j] += 2 * .pi * f0 * p.0 / rate
                if phase[j] > 2 * .pi { phase[j] -= 2 * .pi }
                v += sin(phase[j]) * p.1
            }
            let swell = pow(speed, 1.4)                                 // in and out: never a click
            let throb = 1 + 0.12 * sin(2 * .pi * 6.5 * t)               // the motor's soft beat
            out[k] = v * swell * throb
        }
        return out
    }

    /// Near (this floor or the next), farther (two floors). Quiet: the chime is louder.
    static let rumbles: [SCNAudioSource] = [0.09, 0.045].enumerated().compactMap { i, volume in
        MenagerieSound.source("elevator-shaft-rumble-v2-\(i)", volume: volume) { rumble() }
    }

    /// Should the shaft be heard on floor `here` now? Only a car coming toward
    /// it from at most two floors away, or setting off from it. Pure.
    static func audible(carFloor: Int, direction: Int, here: Int) -> Int? {
        guard direction != 0 else { return nil }
        let away = abs(carFloor - here)
        guard away <= 2 else { return nil }
        if away == 0 { return 0 }                                       // (stopping here, or setting off)
        let toward = (here - carFloor).signum() == direction
        return toward ? away : nil
    }

    /// Which rumble for a car `floorsAway` (nil: not heard).
    static func rumble(floorsAway: Int) -> SCNAudioSource? {
        let i = floorsAway <= 1 ? 0 : 1
        return i < rumbles.count ? rumbles[i] : nil
    }
}
