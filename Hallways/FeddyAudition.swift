//
//  FeddyAudition.swift
//  Hallways
//
//  Oct 19 -- THE FEDDY AUDITION: the first Hallwaysian (HallwaysianSpecies,
//  HallwaysianMotion) on his own little stage, to be looked at from every
//  side and watched as often as we like. Nothing else in the game runs.
//
//  LAUNCH (Xcode scheme > Run > Arguments):   -HallwaysFeddyAudition YES
//  Without it the game starts exactly as before; with it the app opens this
//  view INSTEAD of the game. (The app's usual launch bookkeeping still runs --
//  diagnostics, the audio session, launch logging -- but no floor is built and
//  no story, resident, Contacts entry, save or game sound is touched.)
//
//  THE STAGE: a corner of an ordinary office floor, built by the game's own
//  HallwayScene (office walls, carpet, fluorescent lights, the elevator, a
//  desk and chair, a water cooler, a lamp, a filing cabinet) -- or a plain
//  grey studio ("Studio" button). Feddy stands two metres in front of the
//  elevator; a small test panel with a red button stands beside him.
//
//  THE AUDITION (one 60 s loop, or any act on its own):
//    1 Idle        breathing, blinks, a glance away and back, a weight shift
//    2 Walk        across (away from the panel), a turn (a look at you on the way round), back
//    3 Look        something on the floor, something up high, his own hand
//    4 Beckon      this way! -- then he leads off to the panel
//    5 Button      wind-up, reach, press (click); to you: "see?"; leans in
//    6 Surprise    the panel bites back: a jump, arms up, eyes wide, "o"
//    7 Happy       back to you; hands to his chest, a little rock, a wave
//  "Faces" holds him still and shows the seven expressions one by one.
//  Speed: 1x, 1/2, 1/4. Cameras: Player (eye height, 3 m), Face, Side, 3/4,
//  Low; drag to orbit, pinch to zoom; "Follow" keeps the camera with him.
//
//  Sounds are temporary, synthesised here (footsteps, a click, a buzz, a
//  spring, a little "hm", a ding) and played on their own players -- none of
//  the game's audio (Tinky's included) is used or changed.
//

import AVFoundation
import Combine
import QuartzCore
import SceneKit
import SwiftUI
import UIKit
import simd

enum FeddyAudition {
    /// `-HallwaysFeddyAudition YES`
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "HallwaysFeddyAudition") }
}

// MARK: - The script

/// One moment of the performance: what he aims for from now on.
struct FeddyBeat {
    var t: Double
    var set: [HallwaysianChannel: Float] = [:]
    var clear = false
    var gaze: HallwaysianOverlay.Gaze?
    var gazeHead: Float?
    var walk: SIMD2<Float>?
    var face: Float?
    var turn: Float?
    var fx: FeddyEffect??
    var sound: FeddySound?
}

/// Continuous movements layered on the held targets.
enum FeddyEffect { case beckon, rock, wave }

enum FeddySound: CaseIterable { case step, click, zap, boing, hm, ding }

enum FeddyScript {
    static let loop: Double = 60
    static let camera = SIMD3<Float>(0, 1.25, 3.0)          // (the default viewer, before the real camera is known)
    static let button = SIMD3<Float>(1.05, 0.82, 0)         // the test panel's button (stage space)
    static let pressSpot = SIMD2<Float>(0.62, 0)            // where he stands to press it, facing +X

    struct Act { let name: String; let start: Double; let end: Double; let place: SIMD3<Float> }   // place: x, z, yaw
    static let acts: [Act] = [
        Act(name: "Idle", start: 0, end: 8, place: SIMD3(0, 0, .pi)),
        Act(name: "Walk", start: 8, end: 21, place: SIMD3(0, 0, .pi)),
        Act(name: "Look", start: 21, end: 29, place: SIMD3(0, 0, .pi)),
        Act(name: "Beckon", start: 29, end: 36, place: SIMD3(0, 0, .pi)),
        Act(name: "Button", start: 36, end: 44.5, place: SIMD3(0.62, 0, -.pi / 2)),
        Act(name: "Surprise", start: 44.5, end: 50, place: SIMD3(0.62, 0, -.pi / 2)),
        Act(name: "Happy", start: 50, end: 60, place: SIMD3(0.62, 0, -.pi / 2)),
    ]

    static func act(at t: Double) -> Int { acts.lastIndex { t >= $0.start } ?? 0 }

    // shorthand
    private static func b(_ t: Double, _ set: [HallwaysianChannel: Float] = [:], clear: Bool = false,
                          gaze: HallwaysianOverlay.Gaze? = nil, head: Float? = nil, walk: SIMD2<Float>? = nil,
                          face: Float? = nil, turn: Float? = nil, fx: FeddyEffect?? = nil, sound: FeddySound? = nil) -> FeddyBeat {
        FeddyBeat(t: t, set: set, clear: clear, gaze: gaze, gazeHead: head, walk: walk, face: face, turn: turn, fx: fx, sound: sound)
    }
    private static let pi = Float.pi

    static let beats: [FeddyBeat] = makeBeats().sorted { $0.t < $1.t }

    private static func makeBeats() -> [FeddyBeat] {
        var list: [FeddyBeat] = []
        list += [
        // 1. IDLE -- breathing; a glance away and back; a weight shift; a small pleased look
        b(0.0, clear: true, gaze: .camera, fx: .some(nil)),
        b(2.0, [.smile: 0.1], gaze: .point(SIMD3(-1.8, 1.0, 1.6))),
        b(3.4, [.smile: 0.25], gaze: .camera),
        b(4.6, [.hipRoll: 0.035, .sway: -0.03, .headRoll: 0.06]),
        b(6.0, [.smile: 0.5, .low: 0.25, .headRoll: 0.12, .needle: 0.25]),
        b(7.4, clear: true, gaze: .camera),
        ]
        list += [
        // 2. WALK -- across; turn (a look at you on the way round); back; face you
        b(8.0, [.lidTilt: -0.08], gaze: .ahead, walk: SIMD2(-1.3, 0)),
        b(11.6, turn: pi),
        b(12.0, [.smile: 0.45], gaze: .camera),
        b(12.9, [.smile: 0.25], gaze: .ahead, turn: -pi / 2),
        b(13.7, walk: SIMD2(0, 0), face: pi),
        b(16.6, gaze: .camera),
        b(18.4, [.headPitch: -0.16, .lidTilt: 0]),
        b(18.9, [.headPitch: 0]),
        ]
        list += [
        // 3. LOOK AROUND -- the floor; up high; his own hand; back to you: hm?
        b(21.0, [.neckPitch: -0.22, .headRoll: 0.25, .lid: 0, .lidTilt: -0.15, .mouthW: 0.6, .smile: 0.05, .needle: 0.3, .lean: -0.08],
          gaze: .point(SIMD3(1.3, 0.05, 1.0))),
        b(21.4, sound: .hm),
        b(23.2, [.neckPitch: 0.08, .headRoll: -0.15, .lidR: 0.22, .smile: -0.1, .lean: 0.02], gaze: .point(SIMD3(-1.6, 2.6, -0.4))),
        b(25.0, [.shPitchR: 0.95, .elbowR: 1.7, .wrTwistR: 0.9, .curlR: 0.7, .headRoll: 0.2, .lidR: 0, .pupil: 0.85, .neckPitch: -0.05],
          gaze: .point(SIMD3(-0.25, 0.95, 0.35)), head: 0.85),
        b(27.0, [.headRoll: 0.3, .smile: 0.3, .needle: 0.1, .lidTilt: -0.1], clear: true, gaze: .camera, sound: .hm),
        b(28.5, [.headRoll: 0]),
        ]
        list += [
        // 4. BECKON -- this way! -- then he leads off to the panel
        b(29.0, [.shPitchR: 1.35, .shRollR: 0.3, .elbowR: 0.9, .wrTwistR: -1.5, .wrPitchR: 0.35, .lid: -0.05, .smile: 0.65,
                 .headRoll: -0.15, .lean: 0.04, .needle: 0.4], gaze: .camera, fx: .some(.beckon)),
        b(31.8, gaze: .point(button), head: 0.6),
        b(33.0, [.shPitchR: 0, .shRollR: 0.08, .elbowR: 0.22, .wrTwistR: 0, .wrPitchR: 0, .headRoll: -0.05], gaze: .camera, fx: .some(nil)),
        b(33.4, gaze: .ahead, walk: pressSpot, face: -pi / 2),
        b(34.3, gaze: .camera, head: 0.45),
        b(35.0, gaze: .ahead),
        ]
        list += [
        // 5. THE BUTTON -- wind up, reach, press (click), withdraw; to you: see?; leans in closer
        b(36.0, [.lid: 0, .lean: -0.05, .needle: 0.2], clear: true, gaze: .point(button)),
        b(37.0, [.shPitchR: 0.6, .elbowR: 1.35, .curlR: 1.0, .pointR: 1.0, .lean: 0.05, .headRoll: 0.12]),
        b(37.7, [.shPitchR: 1.42, .elbowR: 0.16, .wrPitchR: 0.15, .lean: -0.12, .neckPitch: -0.08]),
        b(38.3, [.shPitchR: 1.5, .lean: -0.16, .needle: 0.5], sound: .click),
        b(38.6, [.shPitchR: 1.33, .elbowR: 0.35]),
        b(39.3, [.shPitchR: 0.4, .elbowR: 1.1, .pointR: 0.6, .lean: 0, .lidTilt: -0.2, .mouthW: 0.7, .smile: 0.15]),
        b(40.5, [.smile: 0.4, .headRoll: 0.15, .pointR: 0, .shPitchR: 0, .elbowR: 0.22, .curlR: 0.35], gaze: .camera),
        b(41.8, [.lean: -0.1, .neckPitch: -0.18, .lid: 0.15, .lidTilt: 0.15, .smile: 0, .headRoll: 0], gaze: .point(button)),
        ]
        list += [
        // 6. SURPRISE -- the panel bites back
        b(44.6, sound: .zap),
        b(44.65, [.bob: 0.06, .lean: 0.28, .shPitchL: 0.9, .shPitchR: 0.9, .shRollL: 0.9, .shRollR: 0.9, .elbowL: 1.2, .elbowR: 1.2,
                  .curlL: 0, .curlR: 0, .thumbL: 0, .thumbR: 0, .lid: -0.35, .lidTilt: 0, .low: 0, .pupil: 0.62, .mouthO: 1,
                  .mouthW: 0.8, .needle: 1.0, .headPitch: 0.15, .neckPitch: 0.05], sound: .boing),
        b(45.0, [.bob: 0]),
        b(45.8, [.shPitchL: 0.35, .shPitchR: 0.35, .shRollL: 0.35, .shRollR: 0.35, .lean: 0.1, .mouthO: 0.35, .needle: 0.6]),
        b(46.6, [.lid: 0.1, .smile: -0.25, .pupil: 0.85, .lidTilt: -0.32, .needle: 0.35], clear: true, gaze: .point(button)),
        b(48.0, [.lidTilt: -0.15, .smile: 0.1, .headRoll: -0.1, .needle: 0.15], gaze: .camera),
        ]
        list += [
        // 7. HAPPY -- back to you; hands to his chest; a little rock; a wave
        b(50.0, clear: true, gaze: .camera, turn: pi),
        b(50.9, gaze: .ahead, walk: SIMD2(0, 0), face: pi),
        b(51.9, gaze: .camera),
        b(52.1, [.low: 0.6, .lid: 0.15, .smile: 1.0, .mouthW: 1.2, .shPitchL: 0.85, .shPitchR: 0.85, .shYawL: 0.5, .shYawR: 0.5,
                 .elbowL: 1.95, .elbowR: 1.95, .curlL: 0.7, .curlR: 0.7, .headRoll: 0.18, .needle: 0.8], fx: .some(.rock), sound: .ding),
        b(55.0, [.shPitchL: 0, .shYawL: 0, .elbowL: 0.22, .curlL: 0.35, .shPitchR: 0.45, .shYawR: 0, .shRollR: 1.3, .elbowR: 1.5,
                 .wrTwistR: 0.3, .curlR: 0.08, .thumbR: 0.08, .smile: 0.9, .headRoll: 0.1], fx: .some(.wave)),
        b(57.8, clear: true, gaze: .camera, fx: .some(nil)),
        ]
        return list
    }

    static func apply(_ effect: FeddyEffect, time t: Double, to o: inout HallwaysianOverlay) {
        let tt = Float(t)
        func held(_ c: HallwaysianChannel, _ fallback: Float) -> Float { o.targets[c] ?? fallback }
        switch effect {
        case .beckon:
            let u = 0.5 - 0.5 * cos(2 * Float.pi * 2.0 * tt)
            o.targets[.curlR] = 0.1 + 1.15 * u
            o.targets[.elbowR] = held(.elbowR, 0.9) + 0.3 * u
            o.targets[.headPitch] = held(.headPitch, 0) + 0.05 * sin(2 * Float.pi * 2.0 * tt)
        case .rock:
            o.targets[.sway] = 0.07 * sin(2 * Float.pi * 0.85 * tt)
            o.targets[.headRoll] = held(.headRoll, 0) + 0.12 * sin(2 * Float.pi * 0.85 * tt + 0.6)
            o.targets[.hipRoll] = -0.025 * sin(2 * Float.pi * 0.85 * tt)
        case .wave:
            o.targets[.elbowR] = held(.elbowR, 1.5) + 0.38 * sin(2 * Float.pi * 2.1 * tt)
            o.targets[.shYawR] = held(.shYawR, 0) + 0.12 * sin(2 * Float.pi * 2.1 * tt + 0.5)
        }
    }

    /// The seven expressions (Faces mode), each a set of held targets.
    static let expressions: [(name: String, set: [HallwaysianChannel: Float])] = [
        ("Curiosity", [.headRoll: 0.22, .headPitch: 0.05, .neckPitch: -0.08, .lid: 0.12, .lidR: -0.1, .lidTilt: -0.12,
                       .smile: 0.15, .mouthW: 0.7, .needle: 0.4, .lookY: -0.05]),
        ("Happiness", [.lid: 0.2, .low: 0.55, .smile: 1.0, .mouthW: 1.2, .headRoll: -0.08, .headPitch: 0.08,
                       .shPitchL: 0.2, .shPitchR: 0.2, .shRollL: 0.35, .shRollR: 0.35, .needle: 0.7]),
        ("Confusion", [.headRoll: -0.25, .lid: 0.05, .lidR: 0.35, .lookLY: 0.12, .lookRX: 0.1, .lookRY: -0.05,
                       .smile: -0.25, .mouthW: 0.8, .needle: -0.2]),
        ("Surprise", [.lid: -0.15, .pupil: 0.7, .mouthO: 1.0, .mouthW: 0.8, .headPitch: 0.1, .lean: 0.12,
                      .shPitchL: 0.3, .shPitchR: 0.3, .shRollL: 0.5, .shRollR: 0.5, .elbowL: 0.9, .elbowR: 0.9,
                      .curlL: 0, .curlR: 0, .needle: 1.0]),
        ("Concern", [.lid: 0.3, .lidTilt: -0.38, .low: 0.15, .smile: -0.6, .mouthW: 0.85, .headPitch: -0.12, .lean: -0.06,
                     .lookY: -0.1, .needle: -0.4]),
        ("Annoyance", [.lid: 0.5, .lidTilt: 0.6, .low: 0.45, .smile: -0.35, .mouthW: 0.65, .headPitch: -0.05, .lookX: 0.2,
                       .needle: -0.7]),
        ("Affection", [.lid: 0.45, .low: 0.65, .smile: 0.8, .mouthW: 0.9, .headRoll: 0.28, .headPitch: 0.02,
                       .shPitchL: 0.85, .shPitchR: 0.85, .shYawL: 0.5, .shYawR: 0.5, .elbowL: 1.95, .elbowR: 1.95,
                       .curlL: 0.7, .curlR: 0.7, .needle: 0.8]),
    ]
    static let expressionHold: Double = 2.8
}

// MARK: - The performance (no SceneKit: a clock, the beats, the motor)

struct FeddyPerformance {
    enum Mode: Equatable { case loop, act(Int), faces(Int?) }      // faces(nil) = cycle; faces(i) = hold one

    private(set) var motor: HallwaysianMotor
    private(set) var clock: Double = 0                       // script time, 0 ..< loop
    private var next = 0
    private var held: [HallwaysianChannel: Float] = [:]
    private var gaze: HallwaysianOverlay.Gaze = .camera
    private var gazeHead: Float = 0.7
    private var effect: FeddyEffect?
    private(set) var mode: Mode = .loop
    private(set) var faceTime: Double = 0
    /// When the button was last pressed / zapped (script clock), for the panel's light.
    private(set) var clickAt: Double = -99
    private(set) var zapAt: Double = -99

    init(genome: HallwaysianGenome) {
        motor = HallwaysianMotor(genome: genome)
        restart(at: 0)
    }

    var actIndex: Int { FeddyScript.act(at: clock) }
    var label: String {
        switch mode {
        case .faces(let i):
            let k = i ?? (Int(faceTime / FeddyScript.expressionHold) % FeddyScript.expressions.count)
            return "Face: \(FeddyScript.expressions[k].name)"
        default:
            let a = FeddyScript.acts[actIndex]
            return "\(actIndex + 1). \(a.name)"
        }
    }

    mutating func setMode(_ m: Mode) {
        mode = m
        switch m {
        case .loop: restart(at: 0)
        case .act(let i): restart(at: FeddyScript.acts[i].start)
        case .faces:
            faceTime = 0
            motor.place(x: 0, z: 0, yaw: .pi)
        }
    }

    /// Start the script at `t`, Feddy standing where that act begins.
    private mutating func restart(at t: Double) {
        let a = FeddyScript.acts[FeddyScript.act(at: t)]
        motor.place(x: a.place.x, z: a.place.y, yaw: a.place.z)
        clock = t
        held = [:]; gaze = .camera; gazeHead = 0.7; effect = nil
        next = FeddyScript.beats.firstIndex { $0.t >= t } ?? FeddyScript.beats.count
        clickAt = -99; zapAt = -99
    }

    /// One frame: returns the sounds to play.
    mutating func update(dt: Double, camera: SIMD3<Float>) -> [FeddySound] {
        var sounds: [FeddySound] = []
        var overlay = HallwaysianOverlay()
        if case .faces(let hold) = mode {
            faceTime += dt
            let k = hold ?? (Int(faceTime / FeddyScript.expressionHold) % FeddyScript.expressions.count)
            overlay.targets = FeddyScript.expressions[k].set
            overlay.gaze = .camera
        } else {
            clock += dt
            var end = FeddyScript.loop
            if case .act(let i) = mode { end = FeddyScript.acts[i].end }
            if clock >= end {
                if case .act(let i) = mode { restart(at: FeddyScript.acts[i].start) } else { restart(at: 0) }
            }
            let beats = FeddyScript.beats
            while next < beats.count, beats[next].t <= clock {
                let b = beats[next]
                if b.clear { held = [:] }
                for (c, v) in b.set { held[c] = v }
                if let g = b.gaze { gaze = g; gazeHead = b.gazeHead ?? 0.7 } else if let h = b.gazeHead { gazeHead = h }
                if let f = b.fx { effect = f }
                if let w = b.walk { motor.walk(to: w, face: b.face) } else if let y = b.turn { motor.turn(to: y) }
                if let s = b.sound {
                    sounds.append(s)
                    if s == .click { clickAt = clock }
                    if s == .zap { zapAt = clock }
                }
                next += 1
            }
            overlay.targets = held
            overlay.gaze = gaze
            overlay.gazeHead = gazeHead
            if let e = effect { FeddyScript.apply(e, time: clock, to: &overlay) }
        }
        for e in motor.update(dt: dt, overlay: overlay, camera: camera) {
            if case .step = e { sounds.append(.step) }
        }
        return sounds
    }

    /// The panel's button: lit after the press, flickering in the zap.
    var buttonGlow: Float {
        if clock - zapAt >= 0 && clock - zapAt < 0.45 { return Int(clock * 30) % 2 == 0 ? 1 : 0.2 }
        if clock - clickAt >= 0 && clock - clickAt < 6.2 { return 0.75 }
        return 0
    }
}

// MARK: - Sounds (temporary; synthesised once, played on their own players)

final class FeddySounds {
    private var players: [FeddySound: [AVAudioPlayer]] = [:]
    private var turn: [FeddySound: Int] = [:]
    var muted = false

    init() {
        for s in FeddySound.allCases {
            let count = s == .step ? 4 : 1
            players[s] = (0..<count).compactMap { i in
                let samples = MenagerieSound.normalized(Self.render(s, variant: i))
                guard let p = try? AVAudioPlayer(data: BobbinSound.wav(samples)) else { return nil }
                p.volume = Self.volume(s)
                HallwaysAudio.shared.manage(p)                          // Oct 24: under Mute / the silences, like every player
                p.prepareToPlay()
                return p
            }
        }
    }

    func play(_ s: FeddySound, pan: Float = 0) {
        guard !muted, let list = players[s], !list.isEmpty else { return }
        let i = (turn[s] ?? 0) % list.count
        turn[s] = i + 1
        let p = list[i]
        p.pan = max(-1, min(1, pan))
        p.currentTime = 0
        p.play()
    }

    private static func volume(_ s: FeddySound) -> Float {
        switch s {
        case .step: return 0.32
        case .click: return 0.6
        case .zap: return 0.55
        case .boing: return 0.5
        case .hm: return 0.45
        case .ding: return 0.4
        }
    }

    private static func render(_ s: FeddySound, variant: Int) -> [Float] {
        var rng = MenagerieSound.Rand(seed: UInt64(variant) &* 977 &+ 31)
        switch s {
        case .step:
            // a rubber foot on carpet, and the faint tick of a brass ankle
            let pitch = 1 + Float(variant) * 0.06
            let thud = MenagerieSound.strike([(150 * pitch, 0.03, 0.6), (95 * pitch, 0.05, 0.3)], seconds: 0.12, noise: 0.35,
                                             noiseDecay: 0.006, rng: &rng)
            let tick = MenagerieSound.strike([(2600 * pitch, 0.008, 0.4), (4100 * pitch, 0.005, 0.2)], seconds: 0.04, rng: &rng)
            return MenagerieSound.mix([(at: 0, samples: thud, gain: 1), (at: 0.012, samples: tick, gain: 0.25)])
        case .click:
            let a = MenagerieSound.strike([(3200, 0.004, 0.6), (1500, 0.01, 0.4)], seconds: 0.05, noise: 0.5, noiseDecay: 0.002, rng: &rng)
            let b = MenagerieSound.strike([(2600, 0.004, 0.5), (1200, 0.01, 0.3)], seconds: 0.05, noise: 0.4, noiseDecay: 0.002, rng: &rng)
            return MenagerieSound.mix([(at: 0, samples: a, gain: 1), (at: 0.09, samples: b, gain: 0.6)])
        case .zap:
            // a mains buzz with crackle, 0.4 s
            let rate = MenagerieSound.rate
            let n = Int(0.42 * rate)
            var out = [Float](repeating: 0, count: n)
            var gate: Float = 1
            for i in 0..<n {
                let t = Float(i) / rate
                if i % 400 == 0 { gate = rng.unit() < 0.75 ? 1 : 0.25 }
                let saw = (t * 120).truncatingRemainder(dividingBy: 1) * 2 - 1
                let hum = 0.6 * saw + 0.3 * sin(2 * .pi * 240 * t)
                let crackle = (rng.unit() * 2 - 1) * (rng.unit() < 0.08 ? 1 : 0.15)
                out[i] = (hum * 0.6 + crackle * 0.5) * gate * min(1, t / 0.005) * min(1, (0.42 - t) / 0.05)
            }
            return out
        case .boing:
            // a spring let go
            let rate = MenagerieSound.rate
            let n = Int(0.5 * rate)
            var out = [Float](repeating: 0, count: n)
            var phase: Float = 0
            for i in 0..<n {
                let t = Float(i) / rate
                let f: Float = 330 + 260 * exp(-t / 0.12) + 40 * sin(2 * .pi * 11 * t)
                phase += 2 * .pi * f / rate
                out[i] = sin(phase) * exp(-t / 0.16) * min(1, t / 0.003)
            }
            return out
        case .hm:
            // a little mechanical "hm?": two soft rising tones
            let a = MenagerieSound.sweep(210, 230, seconds: 0.16, wobble: 0.4)
            let b = MenagerieSound.sweep(225, 290, seconds: 0.2, wobble: 0.4, curve: 2)
            return MenagerieSound.mix([(at: 0, samples: a, gain: 0.8), (at: 0.17, samples: b, gain: 1)])
        case .ding:
            return MenagerieSound.strike([(1760, 0.35, 0.5), (4420, 0.12, 0.2), (2640, 0.2, 0.15)], seconds: 0.8, rng: &rng)
        }
    }
}

// MARK: - The stage (SceneKit)

final class FeddyStage {
    enum Room { case office, studio }
    enum CameraSpot: String, CaseIterable { case player = "Player", face = "Face", side = "Side", threeQuarter = "3/4", low = "Low" }

    let scene: SCNScene
    let stage = SCNNode()
    let body: HallwaysianBody
    let cameraNode = SCNNode()
    private(set) var performance: FeddyPerformance
    let sounds = FeddySounds()
    private var buttonMaterial = SCNMaterial()
    var follow = false
    private var lastRoot = SIMD3<Float>(0, 0, 0)
    let room: Room

    init(room: Room) {
        self.room = room
        let genome = HallwaysianGenome.feddy
        body = HallwaysianBody(genome: genome)
        performance = FeddyPerformance(genome: genome)
        switch room {
        case .office:
            scene = Self.officeScene()
            // in front of the elevator (cell 10,7, door on its south wall), facing north
            stage.simdPosition = SIMD3(Float(Self.cellSize) * 7, 0, Float(Self.cellSize) * 10 - 0.2)
            stage.eulerAngles.y = .pi
        case .studio:
            scene = Self.studioScene()
        }
        stage.name = "feddyAuditionStage"
        scene.rootNode.addChildNode(stage)
        stage.addChildNode(body.root)
        stage.addChildNode(makePanel())
        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.zNear = 0.02
        camera.zFar = 80
        cameraNode.camera = camera
        cameraNode.name = "feddyAuditionCamera"
        scene.rootNode.addChildNode(cameraNode)
        place(camera: .player)
        diag("feddy.audition.stage", ["room": room == .office ? "office" : "studio", "height": Double(genome.height)])
    }

    var label: String { performance.label }
    var mode: FeddyPerformance.Mode { performance.mode }

    func setMode(_ m: FeddyPerformance.Mode) { performance.setMode(m) }

    /// One frame. `viewer`: the camera actually in use (the user may have orbited).
    func update(dt: Double, viewer: SCNNode?) {
        let eye = (viewer ?? cameraNode).presentation.simdWorldPosition
        let local = stage.simdConvertPosition(eye, from: nil)
        let played = performance.update(dt: dt, camera: local)
        body.apply(performance.motor.pose)
        let glow = CGFloat(performance.buttonGlow)
        buttonMaterial.emission.contents = UIColor(red: 1, green: 0.15 + 0.3 * glow, blue: 0.08, alpha: 1).withAlphaComponent(1)
        buttonMaterial.emission.intensity = glow
        // the viewer's left/right for the pan
        let rootWorld = body.root.presentation.simdWorldPosition
        let listener = viewer ?? cameraNode
        let pan = max(-1, min(1, listener.simdConvertPosition(rootWorld, from: nil).x / 2.5))
        for s in played { sounds.play(s, pan: pan) }
        if follow, let v = viewer {
            let delta = rootWorld - lastRoot
            if simd_length(delta) < 1 { v.simdWorldPosition += SIMD3(delta.x, 0, delta.z) }
        }
        lastRoot = rootWorld
    }

    /// Put the camera at one of the preset spots around Feddy (as he stands now).
    func place(camera spot: CameraSpot) {
        let pose = performance.motor.pose
        let g = body.genome
        let feddy = SIMD3<Float>(pose[.x], 0, pose[.z])
        let yaw = pose[.yaw]
        let forward = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))       // his facing (stage space)
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let head = feddy + SIMD3(0, g.eyeLevel, 0)
        var from: SIMD3<Float>, to: SIMD3<Float>
        switch spot {
        case .player:
            from = SIMD3(0, PlayerHeight.currentEyeHeight, 3.0)
            to = SIMD3(0.3, 0.6, 0)
        case .face:
            from = head + forward * 0.95 + SIMD3(0, 0.02, 0)
            to = head - SIMD3(0, 0.05, 0)
        case .side:
            from = feddy + right * 2.3 + SIMD3(0, 0.75, 0)
            to = feddy + SIMD3(0, 0.6, 0)
        case .threeQuarter:
            from = feddy + simd_normalize(forward * 0.82 + right * 0.57) * 2.0 + SIMD3(0, 0.95, 0)
            to = feddy + SIMD3(0, 0.62, 0)
        case .low:
            from = feddy + forward * 1.5 + SIMD3(0, 0.22, 0)
            to = feddy + SIMD3(0, 0.75, 0)
        }
        let worldFrom = stage.simdConvertPosition(from, to: nil)
        let worldTo = stage.simdConvertPosition(to, to: nil)
        cameraNode.simdWorldPosition = worldFrom
        cameraNode.simdLook(at: worldTo)
        orbitTarget = worldTo
    }

    /// Where the orbit control should pivot (set with each preset).
    private(set) var orbitTarget = SIMD3<Float>(0, 0.6, 0)

    // MARK: Environment

    /// The game's cell size and wall height (MazeStore's, for every floor).
    static let cellSize: CGFloat = 3.52
    static let wallHeight: CGFloat = 3.0

    /// A corner of an ordinary office floor, built by the game's own HallwayScene.
    private static func officeScene() -> SCNScene {
        var cells = Set<GridCoordinate>()
        for r in 7...10 { for c in 5...9 { cells.insert(GridCoordinate(row: r, col: c)) } }
        func g(_ r: Int, _ c: Int) -> GridCoordinate { GridCoordinate(row: r, col: c) }
        let result = HallwayScene.build(
            fromMaze: cells, cellSize: cellSize, wallHeight: wallHeight,
            floorNumber: 6, totalFloors: 16, theme: .office,
            fluorescentLights: [g(9, 7): .eastWest, g(10, 6): .northSouth, g(10, 8): .northSouth, g(8, 7): .eastWest,
                                g(8, 5): .eastWest, g(8, 9): .eastWest],
            tables: [g(9, 9): FurnitureTable(position: .right, orientation: .northSouth, hasPlant: true)],
            desks: [g(10, 5): FurnitureDesk(position: .left, orientation: .eastWest)],
            waterCoolers: [g(10, 9): FurnitureWaterCooler(position: .right, orientation: .northSouth)],
            officeChairs: [g(9, 5): FurnitureOfficeChair(position: .left, orientation: .eastWest)],
            floorLamps: [g(10, 8): FurnitureFloorLamp(position: .right, orientation: .northSouth)],
            filingCabinets: [g(10, 6): FurnitureFilingCabinet(position: .left, orientation: .northSouth)],
            clocks: [WallFace(coord: g(10, 6), direction: .south)])
        result.cameraNode.removeFromParentNode()          // (ours is the audition's)
        return result.scene
    }

    /// A plain grey studio: floor, key, fill, rim.
    private static func studioScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor(white: 0.36, alpha: 1)
        let floor = SCNFloor()
        floor.reflectivity = 0
        floor.firstMaterial = HallwaysianBody.material(UIColor(white: 0.55, alpha: 1), rough: 0.9)
        scene.rootNode.addChildNode(SCNNode(geometry: floor))
        func light(_ type: SCNLight.LightType, _ intensity: CGFloat, _ at: SIMD3<Float>, color: UIColor = .white) {
            let l = SCNLight()
            l.type = type
            l.intensity = intensity
            l.color = color
            let n = SCNNode()
            n.light = l
            n.simdPosition = at
            n.simdLook(at: SIMD3(0, 0.6, 0))
            scene.rootNode.addChildNode(n)
        }
        light(.directional, 900, SIMD3(-2.2, 3.0, 2.6))
        light(.omni, 350, SIMD3(2.6, 1.4, 1.6), color: UIColor(red: 0.88, green: 0.92, blue: 1, alpha: 1))
        light(.omni, 500, SIMD3(0.6, 2.6, -3.0))
        light(.ambient, 260, SIMD3(0, 3, 0))
        return scene
    }

    /// A small steel test panel on a post, a red button facing him (stage space).
    private func makePanel() -> SCNNode {
        let steel = HallwaysianBody.material(UIColor(red: 0.55, green: 0.56, blue: 0.58, alpha: 1), metal: 0.45, rough: 0.4)
        buttonMaterial = HallwaysianBody.material(UIColor(red: 0.75, green: 0.08, blue: 0.06, alpha: 1), rough: 0.3)
        let b = FeddyScript.button
        let panel = SCNNode()
        panel.name = "feddyTestPanel"
        panel.simdPosition = SIMD3(b.x + 0.06, 0, b.z)
        func add(_ geo: SCNGeometry, _ m: SCNMaterial, _ at: SIMD3<Float>, _ euler: SIMD3<Float> = .zero) {
            geo.materials = [m]
            let n = SCNNode(geometry: geo)
            n.simdPosition = at
            n.simdEulerAngles = euler
            panel.addChildNode(n)
        }
        add(SCNCylinder(radius: 0.018, height: CGFloat(b.y - 0.06)), steel, SIMD3(0, (b.y - 0.06) / 2, 0))
        add(SCNCylinder(radius: 0.12, height: 0.015), steel, SIMD3(0, 0.0075, 0))
        add(SCNBox(width: 0.08, height: 0.16, length: 0.16, chamferRadius: 0.01), steel, SIMD3(0, b.y, 0))
        add(SCNCylinder(radius: 0.022, height: 0.02), buttonMaterial, SIMD3(-0.045, b.y, 0), SIMD3(0, 0, .pi / 2))
        return panel
    }
}

// MARK: - The view

final class FeddyAuditionModel: NSObject, ObservableObject {
    @Published var label = ""
    @Published var speed: Double = 1
    @Published var paused = false
    @Published var room: FeddyStage.Room = UserDefaults.standard.bool(forKey: "FeddyStudio") ? .studio : .office
    @Published var follow = false
    @Published var muted = false
    @Published private(set) var modeName = "All"
    private(set) var stage: FeddyStage
    weak var view: SCNView?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    override init() {
        stage = FeddyStage(room: UserDefaults.standard.bool(forKey: "FeddyStudio") ? .studio : .office)
        super.init()
    }

    func attach(_ view: SCNView) {
        self.view = view
        view.scene = stage.scene
        view.pointOfView = stage.cameraNode
        view.defaultCameraController.target = SCNVector3(stage.orbitTarget)
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func detach() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        let dt = last == 0 ? 1.0 / 60 : min(0.1, now - last)
        last = now
        stage.follow = follow
        stage.sounds.muted = muted || paused
        if !paused { stage.update(dt: dt * speed, viewer: view?.pointOfView) }
        if label != stage.label { label = stage.label }
    }

    func play(_ mode: FeddyPerformance.Mode, name: String) {
        stage.setMode(mode)
        modeName = name
        paused = false
        diag("feddy.audition.mode", ["mode": name])
    }

    func camera(_ spot: FeddyStage.CameraSpot) {
        stage.place(camera: spot)
        view?.pointOfView = stage.cameraNode
        view?.defaultCameraController.target = SCNVector3(stage.orbitTarget)
    }

    func toggleRoom() {
        room = room == .office ? .studio : .office
        stage = FeddyStage(room: room)
        if let v = view { attach(v) }
        modeName = "All"
    }
}

struct FeddyAuditionView: View {
    @StateObject private var model = FeddyAuditionModel()

    var body: some View {
        ZStack {
            FeddySceneView(model: model).ignoresSafeArea()
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FEDDY — audition").font(.headline)
                        Text(model.label).font(.subheadline.monospaced())
                    }
                    Spacer()
                    Button(model.room == .office ? "Studio" : "Office") { model.toggleRoom() }
                    Button(model.muted ? "Sound off" : "Sound on") { model.muted.toggle() }
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                Spacer()
                controls
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onDisappear { model.detach() }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", selected: model.modeName == "All") { model.play(.loop, name: "All") }
                    ForEach(Array(FeddyScript.acts.enumerated()), id: \.offset) { i, act in
                        chip("\(i + 1) \(act.name)", selected: model.modeName == act.name) { model.play(.act(i), name: act.name) }
                    }
                    chip("Faces", selected: model.modeName == "Faces") { model.play(.faces(nil), name: "Faces") }
                }
            }
            if model.modeName == "Faces" || model.modeName.hasPrefix("Face ") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(FeddyScript.expressions.enumerated()), id: \.offset) { i, e in
                            chip(e.name, selected: false) { model.play(.faces(i), name: "Face \(e.name)") }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(FeddyStage.CameraSpot.allCases, id: \.self) { spot in
                    chip(spot.rawValue, selected: false) { model.camera(spot) }
                }
                chip("Follow", selected: model.follow) { model.follow.toggle() }
            }
            HStack(spacing: 6) {
                chip(model.paused ? "Play" : "Pause", selected: model.paused) { model.paused.toggle() }
                ForEach([1.0, 0.5, 0.25], id: \.self) { s in
                    chip(s == 1 ? "1x" : (s == 0.5 ? "½x" : "¼x"), selected: model.speed == s) { model.speed = s }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.18), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct FeddySceneView: UIViewRepresentable {
    let model: FeddyAuditionModel

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = true
        model.attach(view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if view.scene !== model.stage.scene { model.attach(view) }
    }
}
