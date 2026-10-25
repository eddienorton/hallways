//
//  HallwaysianMotion.swift
//  Hallways
//
//  Oct 19 -- THE HALLWAYSIANS (first specimen: Feddy). The species' movement
//  machinery, shared by every future Hallwaysian. Pure math, no SceneKit:
//
//    HallwaysianChannel  every movable thing on the body (joints, lids, mouth
//                        shape, the belly gauge), plus where he stands.
//    HallwaysianPose     one value per channel.
//    HallwaysianMotor    the body's life: every channel chases its target on
//                        a spring (stiffness and damping by group), so later
//                        joints lag, overshoot and wobble on their own; always-on
//                        breathing, blinks (the right lid a beat late), eye darts
//                        and a lazy left eye; locomotion (turn, walk, stop) with
//                        two-bone leg IK; and gaze (eyes lead, head follows).
//
//  A performance (FeddyAudition) only says WHAT to aim for -- an overlay of
//  held targets -- and the motor turns it into movement. The same channels,
//  springs and gait drive a fat Hallwaysian or a child; only HallwaysianGenome
//  changes.
//
//  Frame: the character's own stage space, Y up, metres; at yaw 0 he faces -Z
//  (a positive yaw turns him to his left), his right is +X.
//

import Foundation
import simd

// MARK: - Channels

nonisolated enum HallwaysianChannel: Int, CaseIterable, Sendable {
    // where he stands
    case x, z, yaw
    // body
    case bob, hipYaw, hipRoll, lean, twist, sway, breath
    // neck and head
    case neckPitch, neckYaw, headPitch, headYaw, headRoll
    // eyes: both, then each eye's own offset
    case lookX, lookY, lookLX, lookLY, lookRX, lookRY
    // lids: upper (0 open .. 1 shut), lower (0 down .. 1 up), each eye's offsets, slant, pupil size
    case lid, lidL, lidR, low, lowL, lowR, lidTilt, pupil
    // the wire mouth: curve (+ smile), width, roundness (1 = an "o")
    case smile, mouthW, mouthO
    // the belly gauge (-1 .. 1)
    case needle
    // arms (L = his left, R = his right)
    case shPitchL, shYawL, shRollL, elbowL, wrPitchL, wrTwistL, curlL, thumbL, pointL
    case shPitchR, shYawR, shRollR, elbowR, wrPitchR, wrTwistR, curlR, thumbR, pointR
    // legs
    case hipPitchL, legYawL, legRollL, kneeL, ankleL
    case hipPitchR, legYawR, legRollR, kneeR, ankleR

    /// The rest pose.
    var rest: Float {
        switch self {
        case .yaw: return .pi
        case .lid: return 0.1
        case .pupil: return 1
        case .smile: return 0.25
        case .mouthW: return 1
        case .shRollL, .shRollR: return 0.08
        case .elbowL, .elbowR: return 0.22
        case .curlL, .curlR: return 0.35
        case .thumbL, .thumbR: return 0.3
        case .legYawL, .legYawR: return 0.1
        default: return 0
        }
    }

    typealias Group = HallwaysianChannelGroup

    var group: Group {
        switch self {
        case .x, .z, .yaw: return .root
        case .breath, .hipPitchL, .kneeL, .ankleL, .hipPitchR, .kneeR, .ankleR: return .direct
        case .bob, .hipYaw, .hipRoll, .lean, .twist, .sway, .legYawL, .legRollL, .legYawR, .legRollR: return .body
        case .neckPitch, .neckYaw: return .neck
        case .headPitch, .headYaw, .headRoll: return .head
        case .lookX, .lookY, .lookLX, .lookLY, .lookRX, .lookRY: return .eye
        case .lid, .lidL, .lidR, .low, .lowL, .lowR, .lidTilt, .pupil: return .lid
        case .smile, .mouthW, .mouthO: return .mouth
        case .needle: return .needle
        case .shPitchL, .shYawL, .shRollL, .shPitchR, .shYawR, .shRollR: return .shoulder
        case .elbowL, .elbowR: return .elbow
        default: return .hand
        }
    }
}

nonisolated enum HallwaysianChannelGroup: Sendable {
    case root, direct, body, neck, head, eye, lid, mouth, needle, shoulder, elbow, hand

    /// (omega rad/s, damping ratio); nil = set directly. Under-damped groups
    /// overshoot a little -- the wobble; the elbows lag the shoulders.
    var spring: (Float, Float)? {
        switch self {
        case .root, .direct: return nil
        case .body: return (9, 0.7)
        case .neck: return (11, 0.55)
        case .head: return (14, 0.55)
        case .eye: return (38, 0.85)
        case .lid: return (32, 1)
        case .mouth: return (18, 0.7)
        case .needle: return (9, 0.22)
        case .shoulder: return (10, 0.6)
        case .elbow: return (11, 0.5)
        case .hand: return (15, 0.55)
        }
    }
}

// MARK: - Pose

nonisolated struct HallwaysianPose: Sendable {
    var values: [Float]

    static var rest: HallwaysianPose { HallwaysianPose(values: HallwaysianChannel.allCases.map(\.rest)) }

    subscript(_ c: HallwaysianChannel) -> Float {
        get { values[c.rawValue] }
        set { values[c.rawValue] = newValue }
    }
}

/// What a performance asks for: held targets (absolute, replacing rest), and where to look.
nonisolated struct HallwaysianOverlay: Sendable {
    enum Gaze: Sendable, Equatable { case ahead, camera, point(SIMD3<Float>) }
    var targets: [HallwaysianChannel: Float] = [:]
    var gaze: Gaze = .camera
    /// How much of a look the head takes (the eyes do the rest).
    var gazeHead: Float = 0.7
    var blinks = true
    var saccades = true
}

// MARK: - Random (SplitMix64: the same sequence as the Blender sketchpad)

nonisolated struct HallwaysianRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * unit() }
}

// MARK: - The motor

nonisolated struct HallwaysianMotor: Sendable {
    /// A foot touched down ("L"/"R") -- for footstep sounds.
    enum Event: Sendable, Equatable { case step(left: Bool) }

    let thigh: Float, shin: Float
    private(set) var stride: Float, cadence: Float
    /// Oct 20 (night): its own gait, as built (setGait changes the live one).
    let baseStride: Float, baseCadence: Float
    private(set) var pose = HallwaysianPose.rest
    private var velocity = [Float](repeating: 0, count: HallwaysianChannel.allCases.count)
    private var rng: HallwaysianRandom
    private(set) var time: Double = 0
    // life
    private var nextBlink: Double = 1.2, blinkAt: Double = -9, doubleBlink = false
    private var nextSaccade: Double = 0.6, saccade = SIMD2<Float>(0, 0)
    private var driftAt: Double = 4, drift: Float = 0
    // locomotion
    private(set) var goal: SIMD2<Float>?
    private(set) var faceYaw: Float?
    private(set) var walkAmount: Float = 0
    private var stepping: Float = 0
    private(set) var phase: Float = 0
    private var footDown = [true, true]
    private var plan: [(f: Float, lift: Float, swinging: Bool)] = [(0, 0, false), (0, 0, false)]
    /// Head height above the floor (for gaze pitch).
    let headHeight: Float

    init(genome g: HallwaysianGenome, seed: UInt64 = 7) {
        thigh = g.thigh; shin = g.shin; stride = g.stride; cadence = g.cadence
        baseStride = g.stride; baseCadence = g.cadence
        headHeight = g.eyeLevel
        rng = HallwaysianRandom(seed: seed)
    }

    var isBusy: Bool { goal != nil || faceYaw != nil || walkAmount > 0.05 }

    // MARK: Commands

    mutating func walk(to point: SIMD2<Float>, face: Float? = nil) { goal = point; faceYaw = face }
    mutating func turn(to yaw: Float) { goal = nil; faceYaw = yaw }
    /// Oct 20 (night): steps `stride` x longer and `cadence` x quicker than his own
    /// (1, 1: his own). The walk's speed is stride x cadence, the feet planted to
    /// the same stride -- so they never slide.
    mutating func setGait(stride s: Float, cadence c: Float) {
        stride = baseStride * s
        cadence = baseCadence * c
    }

    /// Oct 19 (residents): stop where he is -- no goal, no turn, no drift on.
    mutating func stop() { goal = nil; faceYaw = nil; walkAmount = 0 }

    /// Put him somewhere, standing still (no walk, no lag).
    mutating func place(x: Float, z: Float, yaw: Float) {
        pose = .rest
        pose[.x] = x; pose[.z] = z; pose[.yaw] = yaw
        velocity = velocity.map { _ in 0 }
        goal = nil; faceYaw = nil; walkAmount = 0; stepping = 0
        plan = [(0, 0, false), (0, 0, false)]
        solveLegs()
    }

    // MARK: The frame

    /// One step of life. `camera`: the viewer, in the same stage space (for gaze).
    mutating func update(dt rawDt: Double, overlay: HallwaysianOverlay, camera: SIMD3<Float>) -> [Event] {
        let dt = Float(max(0, min(rawDt, 0.1)))
        time += Double(dt)
        var target = HallwaysianPose.rest
        for (c, v) in overlay.targets { target[c] = v }
        var events: [Event] = []
        locomotion(dt, &target, &events)
        gaze(&target, overlay, camera)
        life(dt, &target, overlay)
        // springs (semi-implicit Euler, sub-stepped: stable at any frame rate)
        let steps = max(1, Int((dt / (1.0 / 240)).rounded(.up)))
        let h = dt / Float(steps)
        for c in HallwaysianChannel.allCases {
            let goalValue = target[c]
            guard let spring = c.group.spring else {
                pose[c] = goalValue; velocity[c.rawValue] = 0
                continue
            }
            let w = spring.0, zeta = spring.1
            var x = pose[c], v = velocity[c.rawValue]
            for _ in 0..<steps {
                let a = w * w * (goalValue - x) - 2 * zeta * w * v
                v += a * h
                x += v * h
            }
            pose[c] = x; velocity[c.rawValue] = v
        }
        solveLegs()
        return events
    }

    // MARK: Life: breath, blinks, eye darts, the lazy eye

    private mutating func life(_ dt: Float, _ t: inout HallwaysianPose, _ o: HallwaysianOverlay) {
        let now = time
        let breath = sin(2 * Float.pi * Float(now) / 3.6)
        t[.breath] = 0.012 * breath
        t[.shRollL] += 0.015 * breath
        t[.shRollR] += 0.015 * breath
        if o.blinks {
            if now >= nextBlink {
                blinkAt = now
                doubleBlink = rng.unit() < 0.2
                nextBlink = now + Double(rng.range(2.2, 5.0))
            }
            let twice = doubleBlink
            let shut: (Double) -> Bool = { u in (u >= 0 && u < 0.11) || (twice && u > 0.24 && u < 0.35) }
            let u = now - blinkAt
            if shut(u) { t[.lidL] = 1.2 - t[.lid] }
            if shut(u - 0.03) { t[.lidR] = 1.2 - t[.lid] }          // (the right lid a beat late)
        }
        if o.saccades {
            if now >= nextSaccade {
                saccade = SIMD2(rng.range(-0.07, 0.07), rng.range(-0.045, 0.045))
                nextSaccade = now + Double(rng.range(0.7, 2.4))
            }
            t[.lookX] += saccade.x; t[.lookY] += saccade.y
        }
        // now and then his left eye wanders a little, then snaps back
        if now >= driftAt {
            drift = rng.range(0.08, 0.14) * (rng.unit() < 0.5 ? 1 : -1)
            driftAt = now + Double(rng.range(6, 11))
        }
        if drift != 0 { drift = abs(drift) > 0.03 ? drift * max(0, 1 - dt / 1.6) : 0 }
        t[.lookLX] += drift
    }

    // MARK: Gaze: head and eyes share the turn (the eyes are on faster springs, so they lead)

    private func gaze(_ t: inout HallwaysianPose, _ o: HallwaysianOverlay, _ camera: SIMD3<Float>) {
        let point: SIMD3<Float>
        switch o.gaze {
        case .ahead: return
        case .camera: point = camera
        case .point(let p): point = p
        }
        let dx = point.x - pose[.x], dz = point.z - pose[.z]
        let world = atan2(-dx, -dz)
        let rel = Self.wrap(world - pose[.yaw])
        let dist = max(0.3, (dx * dx + dz * dz).squareRoot())
        let pitch = atan2(point.y - headHeight, dist)
        let share = o.gazeHead
        let hy = max(-1.1, min(1.1, rel * share))
        t[.headYaw] += hy * 0.75
        t[.neckYaw] += hy * 0.25
        t[.headPitch] += max(-0.6, min(0.6, pitch * share))
        t[.lookX] += max(-0.5, min(0.5, rel - hy))
        t[.lookY] += max(-0.4, min(0.4, pitch * (1 - share)))
    }

    // MARK: Locomotion: turn, walk, stop -- the feet planned here, solved after the springs

    private mutating func locomotion(_ dt: Float, _ t: inout HallwaysianPose, _ events: inout [Event]) {
        var wantWalk: Float = 0
        var turnRate: Float = 0
        if let g = goal {
            let dx = g.x - pose[.x], dz = g.y - pose[.z]
            let d = (dx * dx + dz * dz).squareRoot()
            if d < 0.012 {
                goal = nil
                walkAmount = 0                                   // (on the mark: no drift past it)
            } else {
                let err = Self.wrap(atan2(-dx, -dz) - pose[.yaw])
                if abs(err) > 0.35 && walkAmount < 0.3 {
                    turnRate = Self.sign(err) * min(2.4, abs(err) * 6)         // turn first, stepping
                } else {
                    turnRate = err * 5
                    wantWalk = d > 0.12 ? 1 : d / 0.12
                }
            }
        } else if let f = faceYaw {
            let err = Self.wrap(f - pose[.yaw])
            if abs(err) < 0.02 { faceYaw = nil } else { turnRate = Self.sign(err) * min(2.4, abs(err) * 6) }
        }
        pose[.yaw] = Self.wrap(pose[.yaw] + turnRate * dt)
        walkAmount += (wantWalk - walkAmount) * min(1, dt * 5)
        let stepTurn = min(1, abs(turnRate) / 1.5)
        stepping += (stepTurn - stepping) * min(1, dt * 8)
        var speed = stride * cadence * walkAmount
        if let g = goal {                                    // never past the mark
            let dx = g.x - pose[.x], dz = g.y - pose[.z]
            speed = min(speed, (dx * dx + dz * dz).squareRoot() * 4)
        }
        pose[.x] += -sin(pose[.yaw]) * speed * dt
        pose[.z] += -cos(pose[.yaw]) * speed * dt
        t[.x] = pose[.x]; t[.z] = pose[.z]; t[.yaw] = pose[.yaw]

        let moving = max(walkAmount, stepping * 0.6)
        if moving > 0.02 {
            phase = (phase + cadence * dt * (walkAmount > 0.05 ? 1 : 1.15)).truncatingRemainder(dividingBy: 1)
        }
        let amp = walkAmount
        let lift: Float = 0.045 * moving
        let duty: Float = 0.58
        for side in 0..<2 {
            let ph = (phase + (side == 0 ? 0 : 0.5)).truncatingRemainder(dividingBy: 1)
            var f: Float, l: Float
            if ph < duty {                                   // stance: the foot travels back under him
                let u = ph / duty
                f = (0.5 - u) * stride * 0.5 * amp
                l = 0
            } else {                                         // swing: forward, lifted
                let u = (ph - duty) / (1 - duty)
                f = (-0.5 + Self.smooth(u)) * stride * 0.5 * amp
                l = lift * sin(.pi * u)
            }
            let down = ph < duty
            if moving > 0.3, down, !footDown[side] { events.append(.step(left: side == 0)) }
            footDown[side] = down
            plan[side] = (f, l, !down && moving > 0.02)
        }
        // the body over the legs
        let w = moving, cyc = 2 * Float.pi * phase
        t[.bob] += -0.014 * w * cos(2 * cyc) - 0.008 * w
        t[.hipRoll] += 0.05 * w * sin(cyc)
        t[.twist] += -0.10 * amp * sin(cyc)
        t[.lean] += -0.06 * amp
        t[.headPitch] += 0.035 * w * cos(2 * cyc + 0.6)          // a little pigeon nod
        let swing: Float = 0.42 * amp
        t[.shPitchL] += swing * sin(cyc)
        t[.shPitchR] += -swing * 0.8 * sin(cyc)                  // (the right swings less)
        t[.elbowL] += 0.25 * amp
        t[.elbowR] += 0.25 * amp
    }

    /// After the springs: each foot where the plan puts it, under wherever the pelvis is now.
    private mutating func solveLegs() {
        let a = thigh, b = shin
        let base = (a + b) * 0.996
        let channels: [(HallwaysianChannel, HallwaysianChannel, HallwaysianChannel)] =
            [(.hipPitchL, .kneeL, .ankleL), (.hipPitchR, .kneeR, .ankleR)]
        for side in 0..<2 {
            let (f, l, swinging) = plan[side]
            let h = base + pose[.bob] - l
            let ik = Self.legIK(thigh: a, shin: b, forward: f, down: h)
            pose[channels[side].0] = ik.hip
            pose[channels[side].1] = ik.knee
            pose[channels[side].2] = -(ik.hip + ik.knee) + (swinging ? 0.3 * l / 0.045 : 0)
        }
    }

    // MARK: Helpers

    /// Two-bone planar IK: the hip pitch (+ forward) and knee (- bends back) that put
    /// the ankle `forward` ahead of and `down` below the hip. Out of reach: straight.
    static func legIK(thigh a: Float, shin b: Float, forward f: Float, down h: Float) -> (hip: Float, knee: Float) {
        let d = min((f * f + h * h).squareRoot(), a + b - 1e-4)
        let cosK = (a * a + b * b - d * d) / (2 * a * b)
        let bend = Float.pi - acos(max(-1, min(1, cosK)))
        let alpha = atan2(f, h)
        let gamma = acos(max(-1, min(1, (a * a + d * d - b * b) / (2 * a * max(d, 1e-4)))))
        return (alpha + gamma, -bend)
    }

    static func wrap(_ a: Float) -> Float {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x < -.pi { x += 2 * .pi }
        return x
    }

    static func sign(_ x: Float) -> Float { x < 0 ? -1 : 1 }

    static func smooth(_ u: Float) -> Float {
        let v = max(0, min(1, u))
        return v * v * (3 - 2 * v)
    }
}
