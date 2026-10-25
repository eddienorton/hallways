//
//  ResidentEyes.swift
//  Hallways
//
//  Oct 18 (resident life, phase 2) -- EYES AND ATTENTION: where a creature is
//  looking, shown with its eyes.
//
//  Two layers, shared by every creature that has eyes:
//
//    CritterEyes       the eyes themselves: pivots that turn to look (each
//                      eye aimed on its own, so they converge on what's near),
//                      and lid nodes squashed to blink, opened wide in
//                      surprise or narrowed when drowsy. The species BUILDS
//                      them into its own body -- the chair's are set into its
//                      backrest rail, the butterfly's are her own gold eyes --
//                      and hands them over.
//    CritterAttention  what to look at, ten times a second, in priority:
//                        a cue        a short scripted run of glances (FOLLOW ME,
//                                     hesitation)
//                        the player   noticed now and then when in sight; kept
//                                     in view a few seconds; closer = longer
//                        a focus      the thing it's busy with (an activity)
//                        the way      while moving: where it's going
//                        about        otherwise: small glances round the room
//                      plus blinking, and the reactions -- curious, surprised,
//                      hesitant, recognising -- each its eyes' own (wider,
//                      narrower, a double blink, quick glances) plus whatever
//                      the species adds (`express`: brows, antennae, a hop).
//
//  FOLLOW ME without words (followMe(onward:)): eyes on the player, then a
//  saccade to the way on, hold, back to the player, and again. Any creature
//  with eyes can do it -- the informant role isn't the butterfly's alone.
//
//  Nothing here moves a body or touches a resident's record: a look is only
//  a look. The species decides whether a long look round turns its body
//  (`turnBody`).
//

import Foundation
import QuartzCore
import SceneKit
import simd

/// What a creature's eyes are expressing (the panel says so; the species may add to it).
enum CritterExpression: String {
    case calm, curious, surprised, hesitant, recognizing, followMe, drowsy
}

// MARK: - The eyes

final class CritterEyes {
    /// Each eye's pivot: its local -z looks out of the eye; turned (x pitch, y yaw) to look.
    let pivots: [SCNNode]
    /// Each eye's lid node: scaled -- y squashed to blink, all three for wide/narrow.
    let lids: [SCNNode]
    let maxYaw: Float
    let maxPitch: Float
    /// The angles it's looking at (the eyes' average).
    private(set) var yaw: Float = 0
    private(set) var pitch: Float = 0
    /// How open: 1 normal, more is wide (surprise), less is narrowed (drowsy).
    private(set) var openness: Float = 1
    private var blinkingUntil: CFTimeInterval = 0

    init(pivots: [SCNNode], lids: [SCNNode], maxYaw: Float, maxPitch: Float) {
        self.pivots = pivots
        self.lids = lids
        self.maxYaw = maxYaw
        self.maxPitch = maxPitch
    }

    /// The angles of a look along `d` (a direction in the eye's parent's space):
    /// yaw across, pitch up -- defined by direction(yaw:pitch:), its inverse.
    static func angles(toward d: SIMD3<Float>) -> (yaw: Float, pitch: Float) {
        let flat = (d.y * d.y + d.z * d.z).squareRoot()
        let yaw = atan2(-d.x, flat)
        let pitch = atan2(d.y, max(0.0001, abs(d.z)))      // (behind it: the nearest it can manage)
        return (yaw, pitch)
    }

    static func clamp(_ v: Float, _ limit: Float) -> Float { min(limit, max(-limit, v)) }

    /// The way an eye looks at (yaw, pitch): (-sin y, cos y sin p, -cos y cos p).
    static func direction(yaw: Float, pitch: Float) -> SIMD3<Float> {
        SIMD3<Float>(-sin(yaw), cos(yaw) * sin(pitch), -cos(yaw) * cos(pitch))
    }

    /// The eye's turn (from looking along -z) for that look: the shortest
    /// rotation onto it -- set as an orientation, so no Euler order is involved.
    static func rotation(yaw: Float, pitch: Float) -> simd_quatf {
        simd_quatf(from: SIMD3<Float>(0, 0, -1), to: simd_normalize(direction(yaw: yaw, pitch: pitch)))
    }

    /// Look at a world point (nil: straight ahead). Returns the average angle,
    /// clamped -- and how far past its limit the target is (yaw), so the
    /// species can turn its body when it must.
    @discardableResult
    func aim(at world: SIMD3<Float>?, duration: TimeInterval) -> (yaw: Float, pitch: Float, beyond: Float) {
        var ys: Float = 0, ps: Float = 0, over: Float = 0
        for p in pivots {
            var y: Float = 0, x: Float = 0
            if let world, let parent = p.parent {
                let local = parent.convertPosition(SCNVector3(world.x, world.y, world.z), from: nil)
                let d = SIMD3<Float>(local.x - p.position.x, local.y - p.position.y, local.z - p.position.z)
                if simd_length(d) > 0.001 {
                    let a = Self.angles(toward: d)
                    over = max(over, abs(a.yaw) - maxYaw)
                    y = Self.clamp(a.yaw, maxYaw)
                    x = Self.clamp(a.pitch, maxPitch)
                }
            }
            ys += y
            ps += x
            let q = Self.rotation(yaw: y, pitch: x)
            guard abs(simd_dot(p.simdOrientation.vector, q.vector)) < 0.99998 else { continue }      // (already looking there)
            let axisAngle = q.angle < 0.0001 ? SCNVector4(0, 1, 0, 0) : SCNVector4(q.axis.x, q.axis.y, q.axis.z, q.angle)
            let turn = SCNAction.rotate(toAxisAngle: axisAngle, duration: duration)
            turn.timingMode = .easeOut
            p.runAction(turn, forKey: "look")
        }
        let n = Float(max(1, pivots.count))
        yaw = ys / n
        pitch = ps / n
        return (yaw, pitch, max(0, over))
    }

    /// A blink (two quick ones for `double`).
    func blink(double: Bool = false) {
        let now = CACurrentMediaTime()
        guard now >= blinkingUntil else { return }
        let o = CGFloat(openness)
        let shut = SCNAction.customAction(duration: 0.06) { n, t in
            let u = Float(t / 0.06)
            n.scale = SCNVector3(Float(o), Float(o) * (1 - 0.9 * u), Float(o))
        }
        let open = SCNAction.customAction(duration: 0.09) { n, t in
            let u = Float(t / 0.09)
            n.scale = SCNVector3(Float(o), Float(o) * (0.1 + 0.9 * u), Float(o))
        }
        var one: [SCNAction] = [shut, .wait(duration: 0.04), open]
        if double { one += [.wait(duration: 0.12), shut, .wait(duration: 0.03), open] }
        blinkingUntil = now + (double ? 0.5 : 0.22)
        for l in lids { l.runAction(.sequence(one), forKey: "lid") }
    }

    /// Wider (surprise) or narrower (drowsy) -- held until changed.
    func setOpenness(_ o: Float, duration: TimeInterval = 0.12) {
        openness = o
        let s = CGFloat(o)
        for l in lids {
            l.removeAction(forKey: "lid")
            l.runAction(.scale(to: s, duration: duration), forKey: "lid")
        }
        blinkingUntil = CACurrentMediaTime() + duration
    }
}

// MARK: - Attention

final class CritterAttention {
    let id: String
    let eyes: CritterEyes
    /// The body (its parent: the scene). Nothing is done while it's out of a scene.
    weak var body: SCNNode?
    /// Where its eyes are (world) -- for "straight ahead" and distances.
    var eyePoint: () -> SIMD3<Float>? = { nil }
    /// The way it faces (world x, z; unit).
    var forward: () -> SIMD2<Float> = { SIMD2<Float>(0, -1) }
    /// The player's eyes (world), if there's a player to look at.
    var player: () -> SIMD3<Float>? = { nil }
    /// Is that point (x, z) in plain view (no closed door, no wall between)?
    var canSee: (SIMD2<Float>) -> Bool = { _ in true }
    /// Moving under its own power right now.
    var isMoving: () -> Bool = { false }
    /// Something its body is doing that shouldn't be turned from (a gesture).
    var isBusy: () -> Bool = { false }
    /// The species' own part of an expression (brows, antennae, a hop...).
    var express: ((CritterExpression) -> Void)?
    /// After every look: the eyes' angles (the butterfly's antennae follow them).
    var onLook: ((Float, Float) -> Void)?
    /// Asked to turn the body toward a point (x, z) it can't see without turning.
    var turnBody: ((SIMD2<Float>) -> Void)?

    /// Where it's going (while moving): it looks that way.
    var destination: SIMD3<Float>?
    /// The thing it's busy with.
    private(set) var focus: (name: String, point: SIMD3<Float>)?
    /// How keenly it looks at its focus: "work" reads along it, "watch" holds still.
    private var focusStyle = FocusStyle.study
    enum FocusStyle { case study, work, watch }

    /// How far it notices the player (metres).
    var noticeRange: Float = 6
    /// Closer than this, the player is watched as long as they stay.
    var closeRange: Float = 2.2

    private struct Cue { let label: String; let point: () -> SIMD3<Float>?; let hold: Double }
    private var cues: [Cue] = []
    private var cueUntil: CFTimeInterval = 0
    private var cueLabel: String?

    private var watchingPlayer = false
    private var watchUntil: CFTimeInterval = 0
    private var playerCooldown: CFTimeInterval = 0
    private var recentPlayer: [(t: CFTimeInterval, d: Float)] = []
    private var beyondSince: CFTimeInterval?
    private var nextBlink: CFTimeInterval = 0
    private var nextGlance: CFTimeInterval = 0
    private var glance: SIMD3<Float>?
    private var drift = SIMD3<Float>(repeating: 0)
    private var nextDrift: CFTimeInterval = 0
    private(set) var expression = CritterExpression.calm
    private var expressionUntil: CFTimeInterval = 0
    private var resting = false
    private var timer: Timer?
    private var rng: Rand

    /// When each creature last had the player in view (any floor, this run):
    /// a sighting after a while is RECOGNITION, not a first look.
    static var lastSawPlayer: [String: Date] = [:]

    init(id: String, eyes: CritterEyes, body: SCNNode) {
        self.id = id
        self.eyes = eyes
        self.body = body
        var h: UInt64 = 1469598103934665603
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        rng = Rand(seed: h ^ UInt64(Date().timeIntervalSinceReferenceDate * 1000))
    }

    /// Begin looking (idempotent). Stops by itself once the attention is gone.
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                if let self { self.step() } else { t.invalidate() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        nextBlink = CACurrentMediaTime() + Double(rng.range(1, 3))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: What the creature tells it

    func setFocus(_ name: String, at point: SIMD3<Float>, style: FocusStyle = .study) {
        focus = (name, point)
        focusStyle = style
        nextDrift = 0
    }

    func clearFocus() { focus = nil }

    /// Drowsy, resting: eyes narrowed, slow blinks, few glances.
    func setResting(_ on: Bool) {
        guard on != resting else { return }
        resting = on
        eyes.setOpenness(on ? 0.5 : 1, duration: 0.6)
        if on { react(.drowsy, for: 3) }
    }

    /// FOLLOW ME: the player, the way on, the player, the way on, the player.
    func followMe(onward: SIMD3<Float>) {
        let p: () -> SIMD3<Float>? = { [weak self] in self?.player() }
        play([Cue(label: "follow-me: you", point: p, hold: 0.7), Cue(label: "follow-me: that way", point: { onward }, hold: 0.9),
              Cue(label: "follow-me: you", point: p, hold: 0.55), Cue(label: "follow-me: that way", point: { onward }, hold: 0.9),
              Cue(label: "follow-me: you", point: p, hold: 0.6)])
        react(.followMe, for: 3.6)
    }

    /// Hesitation: eyes flicking between two things (where it means to go, and something else).
    func hesitate(between a: SIMD3<Float>, aName: String, and b: SIMD3<Float>, bName: String) {
        play([Cue(label: "hesitating: \(aName)", point: { a }, hold: 0.5), Cue(label: "hesitating: \(bName)", point: { b }, hold: 0.45),
              Cue(label: "hesitating: \(aName)", point: { a }, hold: 0.6)])
        react(.hesitant, for: 1.6)
    }

    /// A glance at something (it holds it a moment, then carries on).
    func glanceAt(_ point: SIMD3<Float>, label: String, hold: Double = 0.8) {
        play([Cue(label: label, point: { point }, hold: hold)])
    }

    private func play(_ list: [Cue]) {
        cues = list
        cueLabel = nil
        cueUntil = 0
    }

    /// An expression: its eyes' part here, the species' part through `express`.
    func react(_ e: CritterExpression, for seconds: Double = 1.4) {
        expression = e
        expressionUntil = CACurrentMediaTime() + seconds
        switch e {
        case .surprised:
            eyes.setOpenness(1.4, duration: 0.06)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                guard let self else { return }
                self.eyes.setOpenness(self.resting ? 0.5 : 1, duration: 0.25)
                self.eyes.blink(double: true)
            }
        case .curious:
            eyes.setOpenness(1.15, duration: 0.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.expression != .surprised else { return }
                self.eyes.setOpenness(self.resting ? 0.5 : 1, duration: 0.3)
            }
        case .recognizing:
            eyes.blink(double: true)
        case .hesitant:
            eyes.setOpenness(0.85, duration: 0.15)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                self.eyes.setOpenness(self.resting ? 0.5 : 1, duration: 0.25)
            }
        case .followMe, .calm, .drowsy:
            break
        }
        express?(e)
    }

    // MARK: Looking (ten times a second)

    /// In words, for the panel: what it's looking at (and how).
    var status: String {
        let now = CACurrentMediaTime()
        let what = currentLabel
        return now < expressionUntil && expression != .calm ? "\(expression.rawValue), \(what)" : what
    }
    private var currentLabel = "looking ahead"

    private func step() {
        let perf = PerfMonitor.begin("eyes.step"); defer { PerfMonitor.end(perf) }   // Oct 21: measurement only (PerfMonitor)
        guard let body, body.parent != nil, let me = eyePoint() else { return }
        let now = CACurrentMediaTime()
        // Blinking: every few seconds, now and then twice; slow and seldom when drowsy.
        if now >= nextBlink {
            eyes.blink(double: rng.unit() < 0.15)
            nextBlink = now + Double(resting ? rng.range(4, 8) : rng.range(2.2, 5.5))
        }
        sensePlayer(me: me, now: now)
        // What to look at.
        var target: SIMD3<Float>?
        var quick = false
        if let cue = currentCue(now: now) {
            target = cue.point()
            currentLabel = cue.label
            quick = true
        } else if watchingPlayer, let p = player() {
            target = p
            currentLabel = "watching player"
        } else if let f = focus {
            if now >= nextDrift {
                // Its eyes move over the thing: along it (working), about it (studying), or hold (watching).
                switch focusStyle {
                case .work: drift = SIMD3<Float>(rng.range(-0.25, 0.25), rng.range(-0.05, 0.05), rng.range(-0.15, 0.15))
                case .study: drift = SIMD3<Float>(rng.range(-0.15, 0.15), rng.range(-0.15, 0.2), rng.range(-0.15, 0.15))
                case .watch: drift = .zero
                }
                nextDrift = now + Double(rng.range(0.9, 2.4))
                quick = true
            }
            target = f.point + drift
            currentLabel = "looking at \(f.name)"
        } else if isMoving() {
            let fwd = forward()
            let ahead = me + SIMD3<Float>(fwd.x, -0.15, fwd.y) * 3
            if let d = destination {
                let to = SIMD2<Float>(d.x - me.x, d.z - me.z)
                let len = simd_length(to)
                // Toward where it's going when that's within its view; the path ahead otherwise.
                if len > 0.5, simd_dot(to / len, fwd) > 0.35 { target = d; currentLabel = "looking toward its destination" }
                else { target = ahead; currentLabel = "looking ahead" }
            } else {
                target = ahead
                currentLabel = "looking ahead"
            }
        } else {
            if now >= nextGlance || glance == nil {
                let fwd = forward()
                let spread: Float = resting ? 0.4 : 1.1
                let a = rng.range(-spread, spread)
                let dir = SIMD2<Float>(fwd.x * cos(a) - fwd.y * sin(a), fwd.x * sin(a) + fwd.y * cos(a))
                glance = me + SIMD3<Float>(dir.x * 3, rng.range(-0.6, 0.4), dir.y * 3)
                nextGlance = now + Double(resting ? rng.range(4, 8) : rng.range(1.4, 3.8))
                quick = true
            }
            target = glance
            currentLabel = resting ? "resting, eyes half-closed" : "looking around"
        }
        let look = eyes.aim(at: target, duration: quick ? 0.09 : 0.2)
        onLook?(look.yaw, look.pitch)
        // Something it really wants to see is behind it: after a moment, it turns.
        if look.beyond > 0.25, !isMoving(), !isBusy(), let t = target, watchingPlayer || cueLabel != nil {
            if beyondSince == nil { beyondSince = now }
            if let s = beyondSince, now - s > 0.8 {
                beyondSince = nil
                turnBody?(SIMD2<Float>(t.x, t.z))
            }
        } else {
            beyondSince = nil
        }
    }

    private func currentCue(now: CFTimeInterval) -> Cue? {
        if cueLabel != nil, now >= cueUntil {                 // (this glance held long enough: the next)
            if !cues.isEmpty { cues.removeFirst() }
            cueLabel = nil
        }
        if cueLabel == nil, let next = cues.first {
            cueLabel = next.label
            cueUntil = now + next.hold
        }
        return cueLabel == nil ? nil : cues.first
    }

    private func sensePlayer(me: SIMD3<Float>, now: CFTimeInterval) {
        guard let p = player() else { watchingPlayer = false; return }
        let d = simd_distance(SIMD2<Float>(me.x, me.z), SIMD2<Float>(p.x, p.z))
        recentPlayer.append((now, d))
        recentPlayer.removeAll { now - $0.t > 1.6 }
        let inView = d < noticeRange && canSee(SIMD2<Float>(p.x, p.z))
        if !inView {
            if watchingPlayer {
                watchingPlayer = false
                playerCooldown = now + 1.5
            }
            return
        }
        Self.lastSawPlayer[id] = watchingPlayer ? Date() : Self.lastSawPlayer[id]
        if watchingPlayer {
            if d < closeRange { watchUntil = max(watchUntil, now + 1) }          // (right beside it: it keeps an eye on them)
            if now > watchUntil {
                watchingPlayer = false
                playerCooldown = now + Double(rng.range(3.5, 8))
            }
            return
        }
        guard now >= playerCooldown, !resting || d < closeRange else { return }
        // Noticed: always when close; otherwise now and then (about one second in four).
        guard d < closeRange || rng.unit() < 0.025 else { return }
        watchingPlayer = true
        watchUntil = now + Double(d < closeRange ? rng.range(3, 6) : rng.range(2, 4.5))
        let approached = (recentPlayer.first?.d ?? d) - d
        let last = Self.lastSawPlayer[id]
        Self.lastSawPlayer[id] = Date()
        if d < closeRange, approached > 1.2 {
            react(.surprised, for: 1.2)                                  // (they came up on it quickly)
        } else if let last, Date().timeIntervalSince(last) > 25, Date().timeIntervalSince(last) < 600 {
            react(.recognizing, for: 1.6)                                // (that one again)
        } else {
            react(.curious, for: 1.5)
        }
    }
}

// MARK: - Sight

enum CritterSight {
    /// Can a creature in cell `a` see cell `b`? Joined by a short walk (at most
    /// one cell's detour) through open cells and open doors only.
    static func connected(_ a: GridCoordinate, _ b: GridCoordinate, cells: Set<GridCoordinate>,
                          doors: [GridCoordinate: Direction], isOpen: (GridCoordinate) -> Bool) -> Bool {
        if a == b { return true }
        guard cells.contains(a), cells.contains(b) else { return false }
        let limit = abs(a.row - b.row) + abs(a.col - b.col) + 1
        var seen: Set<GridCoordinate> = [a]
        var frontier = [a]
        for _ in 0..<limit {
            var next: [GridCoordinate] = []
            for c in frontier {
                for d in Direction.allCases {
                    let n = GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
                    guard cells.contains(n), !seen.contains(n) else { continue }
                    if doors[c] == d, !isOpen(c) { continue }
                    if doors[n] == d.opposite, !isOpen(n) { continue }
                    if n == b { return true }
                    seen.insert(n)
                    next.append(n)
                }
            }
            frontier = next
        }
        return false
    }
}
