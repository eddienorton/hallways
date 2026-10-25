//
//  ElevatorDoorSound.swift
//  Hallways
//
//  Oct 19 (elevator overhaul) -- THE DOORS, HEARD.
//
//  The elevator's doors make three sounds: a motor-and-rollers slide as they
//  start to OPEN, the same slide falling in pitch as they start to CLOSE, and a
//  soft mechanical CLUNK as the two panels meet. They are cued by the doors'
//  own movement (ElevatorDoorMotion, sampled 20 times a second from the drawn
//  door positions) -- never by a timer of their own -- so every door movement
//  is heard exactly once, whatever moved them: the player's boarding and
//  arrival, the ride's close, the doors closing behind the player, a resident's
//  stop, a character's door cycle, a threshold swipe reopening them.
//
//  Played positionally at the doors through CritterAudio (the building's
//  distance and wall rules, the game's mute) -- so stepping out and walking
//  away, the player hears them close behind. The arrival chime (ding-dong)
//  is untouched: it is played where it always was.
//
//  Synthesised (the same cached-WAV path the creatures use): no new asset files.
//

import Foundation
import SceneKit

/// The doors' movement, sample by sample: which way they're going and when a
/// sound is due. Pure (tested: each cue once per movement).
nonisolated struct ElevatorDoorMotion: Sendable {
    enum Phase: Equatable, Sendable { case closed, opening, open, closing }
    enum Cue: Equatable, Sendable { case opening, closing, shut }

    private(set) var phase: Phase
    private var last: Double

    /// The doors' open fraction now (0 shut .. 1 open).
    init(fraction: Double = 0) {
        last = fraction
        phase = fraction < 0.02 ? .closed : (fraction > 0.97 ? .open : .open)
    }

    /// Below this change between samples the doors are standing still.
    static let still = 0.003

    /// The next sample: the cues it brings (usually none).
    mutating func update(fraction f: Double, at time: Double = 0) -> [Cue] {
        defer { last = f }
        let d = f - last
        var cues: [Cue] = []
        if d > Self.still {
            if phase != .opening { phase = .opening; cues.append(.opening) }
        } else if d < -Self.still, !(phase == .closed && f < 0.02) {          // (the last creep of a shut door is no new close)
            if phase != .closing { phase = .closing; cues.append(.closing) }
        } else if f > 0.97 {
            phase = .open
        } else if f < 0.02 {
            if phase == .closing { cues.append(.shut) }
            phase = .closed
        }
        // Closing and all but met: the clunk now (not a sample later).
        if phase == .closing, f < 0.01 {
            cues.append(.shut)
            phase = .closed
        }
        return cues
    }

    /// The car's view of these doors.
    var doors: BuildingElevator.Doors {
        switch phase {
        case .closed: return .closed
        case .opening: return .opening
        case .open: return .open
        case .closing: return .closing
        }
    }
}

enum ElevatorDoorSound {
    /// The slide: a small motor whirring up (opening) or down (closing), with the
    /// rollers' soft rumble; 0.9 s, quick in, long tail (it suits the classic
    /// 1.6 s slide and the Rocket Elevator's quick one alike).
    nonisolated static func slide(rising: Bool, seconds: Float = 0.9) -> [Float] {
        let rate = MenagerieSound.rate
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var rng = MenagerieSound.Rand(seed: rising ? 401 : 409)
        var lp: Float = 0, lp2: Float = 0
        var phase: Float = 0
        for k in 0..<n {
            let t = Float(k) / rate
            let u = t / seconds
            let f0: Float = rising ? 132 + 46 * min(1, u * 1.6) : 176 - 44 * min(1, u * 1.6)
            phase += 2 * .pi * f0 / rate
            if phase > 2 * .pi { phase -= 2 * .pi }
            let motor = sin(phase) * 0.5 + sin(2 * phase) * 0.22 + sin(3 * phase) * 0.08
            lp += ((rng.unit() * 2 - 1) - lp) * 0.06                         // rollers: low rumble
            lp2 += (lp - lp2) * 0.2
            let attack = min(1, t / 0.05)
            let release = max(0, 1 - max(0, u - 0.45) / 0.55)
            out[k] = (motor * 0.55 + lp2 * 2.2) * attack * release * release
        }
        return out
    }

    private static let openSource: SCNAudioSource? = MenagerieSound.source("elevator-door-slide-open-v1", volume: 0.32) {
        slide(rising: true)
    }
    private static let closeSource: SCNAudioSource? = MenagerieSound.source("elevator-door-slide-close-v1", volume: 0.32) {
        slide(rising: false)
    }
    /// The panels meeting: a padded mechanical clunk.
    private static let shutSource: SCNAudioSource? = MenagerieSound.source("elevator-door-clunk-v1", volume: 0.42) {
        var rng = MenagerieSound.Rand(seed: 419)
        return MenagerieSound.strike([(68, 0.22, 1), (136, 0.09, 0.45), (520, 0.025, 0.18)],
                                     seconds: 0.45, noise: 0.4, noiseDecay: 0.02, rng: &rng)
    }

    /// One cue, from the doors (positional, through the building's audio rules).
    static func play(_ cue: ElevatorDoorMotion.Cue, on node: SCNNode) {
        let source: SCNAudioSource?
        switch cue {
        case .opening: source = openSource
        case .closing: source = closeSource
        case .shut: source = shutSource
        }
        guard let source else { return }
        CritterAudio.play(source, on: node)
    }
}
