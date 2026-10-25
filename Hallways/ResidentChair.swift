//
//  ResidentChair.swift
//  Hallways
//
//  Oct 18 (building life) -- THE ROAMING CHAIR: the second resident, and the
//  test of the architecture. A plain wooden office chair that wanders the
//  building on its own: Floors 3 and 4, from one place to another, a stay of
//  a minute or three, now and then the elevator to the other floor (the
//  ding, the doors, out it trots). No mission, no scripted encounter.
//
//  Everything it is, is here: who it is (one resident, "chair.1"), what it
//  can do (walk, ride the elevator), what it likes (RoamStyle), and its body
//  (Menagerie's chair model and sounds, moved along a path). Its life --
//  deciding, travelling, the elevator, offscreen time, rebuilds -- is the
//  shared Roam (ResidentRoam.swift) and BuildingLife.
//

import SceneKit
import UIKit      // (Oct 18: UIColor for its eyes -- member import visibility is on)
import simd

// MARK: - The kind

final class RoamingChairKind: ResidentKind {
    static let id = "chair.1"
    let kind = "roamingChair"
    let abilities: Set<ResidentAbility> = [.walk, .rideElevator]
    /// Its pace: room to room on Floors 3 and 4, lingering 20-50 s in each
    /// (Oct 18: rooms, not hallway cells -- see RoomRegistry), about one
    /// decision in three a change of floor.
    /// Oct 18 (open the building): the whole building now -- never Floor 2 or 3
    /// (onboarding; Tinky's office and the meeting) -- desks and seats first.
    static let normalStyle: RoamStyle = {
        var s = RoamStyle(floors: [4: 1, 5: 1.5, 6: 1, 7: 1.5, 8: 0.5, 11: 1.5, 12: 0.5], stay: 40...120,
                          speed: ChairResidentBody.speed, changeFloorChance: 0.35)
        s.roomTaste = ["Desks": 2, "Seating": 2, "Conference": 1.5, "Office": 1.5, "Tables": 1.5]
        return s
    }()
    /// DEBUG-only accelerated testing (-HallwaysLifeFast YES): short stays,
    /// mostly floor changes, a quicker ride. Same clock, same code; only these numbers.
    static let fastStyle: RoamStyle = {
        var s = normalStyle
        s.stay = 8...15
        s.changeFloorChance = 0.6
        s.elevatorRide = 12
        return s
    }()
    /// (the controlled test, -HallwaysLifeTest N, is applied by BuildingLife.pacing)
    var style: RoamStyle { BuildingLife.pacing(normal: Self.normalStyle, fast: Self.fastStyle) }

    func newcomers(now: Date) -> [Resident] {
        // Oct 18 (open the building): first in line at the lobby entrance (no cell
        // yet: at its time it walks in, to the elevator, and up to its first room).
        // (A save that already has the chair keeps it where it is: newcomers are only
        // made for a kind the building has none of.)
        [Resident(id: Self.id, kind: kind, floor: ResidentPolicy.lobbyFloor, cell: nil,
                  since: now.addingTimeInterval(ResidentRoster.arrivalDelay(order: 0)), dwell: 0)]
    }

    func advance(_ r: inout Resident, to now: Date, plans: (Int) -> FloorPlan?) {
        // (Oct 19: a newcomer -- after Start Over -- waits for the building to open, first in line)
        ResidentRoster.advance(&r, order: 0, style: style, abilities: abilities, plans: plans, to: now)
    }

    func present(_ id: String, on stage: FloorStage) -> ResidentPresentation? {
        guard Admission.isCompleted, !Admission.isQuietOnboarding(floor: stage.floor), let context = stage.context,
              let root = stage.root, let controller = stage.controller else { return nil }
        return RoamPresentation(residentID: id, floor: stage.floor, root: root, controller: controller, context: context,
                                style: style, abilities: abilities) { ChairResidentBody() }
    }
}

// MARK: - The body

/// The chair's gait and facing, shared with the render thread (the walk and turn actions).
/// Oct 18 (repair): its yaw is kept HERE, never read back from SceneKit's
/// eulerAngles -- SceneKit can hand a yaw past +/-90 degrees back as
/// (180, 180 - yaw, 180), and a turn computed from that (or a single-component
/// write like eulerAngles.y = h on top of it) tips the chair over.
nonisolated final class ChairGait: @unchecked Sendable {
    var phase: Float = 0
    var yaw: Float = 0

    static func wrap(_ a: Float) -> Float {
        var a = a.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a <= -.pi { a += 2 * .pi }
        return a
    }
}

final class ChairResidentBody: RoamerBody {
    static let speed: Float = 0.6
    /// Oct 20: the roaming chair is a fifth bigger than as built (proportions kept).
    static let sizeScale: Float = 1.2
    private static let shadow = Menagerie.shadowImage()

    let root: SCNNode
    private let lift: SCNNode
    private let seat: SCNNode
    private let legs: [SCNNode]
    private let gait = ChairGait()
    private var gesturing = false
    /// Oct 18 (diagnostics): whose body (its [Life] lines).
    var diagnosticID = "chair"
    private var travels = 0
    private var oddReported = false
    /// Oct 18 (phase 2): its eyes -- set into the backrest's top rail, looking
    /// out over the seat -- and what they attend to.
    let attention: CritterAttention
    var eyes: CritterAttention? { attention }
    private let eyeMount: SCNNode
    private let brows: [SCNNode]

    init() {
        let model = Chair.model(shadow: Self.shadow)
        root = model.root
        lift = model.body
        seat = model.seat
        legs = model.legs
        root.name = "residentChair"
        root.scale = SCNVector3(Self.sizeScale, Self.sizeScale, Self.sizeScale)    // (Oct 20: 1.2x; its turns set only yaw)
        let face = Self.buildFace(on: model.seat)
        eyeMount = face.mount
        brows = face.brows
        attention = CritterAttention(id: RoamingChairKind.id,
                                     eyes: CritterEyes(pivots: face.pivots, lids: face.lids, maxYaw: 0.85, maxPitch: 0.5),
                                     body: model.root)
        root.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }
        let mount = eyeMount, g = gait
        attention.eyePoint = { [weak mount] in
            guard let mount, mount.parent != nil else { return nil }
            let w = mount.convertPosition(SCNVector3Zero, to: nil)
            return SIMD3<Float>(w.x, w.y, w.z)
        }
        attention.forward = { SIMD2<Float>(-sin(g.yaw), -cos(g.yaw)) }
        attention.isMoving = { [weak self] in self?.isMoving ?? false }
        attention.isBusy = { [weak self] in self?.gesturing ?? false }
        attention.turnBody = { [weak self] p in
            guard let self else { return }
            self.face(Self.heading(p - self.here), duration: 0.7)
        }
        attention.express = { [weak self] e in self?.express(e) }
        attention.start()
    }

    // MARK: Its face (Oct 18, phase 2)

    /// Two eyes set into the front of the backrest's top rail -- brass-ringed,
    /// ivory, with irises the green of its cushion -- and a carved wooden brow
    /// over each. The rail faces the way the chair does (-z), so it looks out
    /// over its own seat.
    private static func buildFace(on seat: SCNNode) -> (mount: SCNNode, pivots: [SCNNode], lids: [SCNNode], brows: [SCNNode]) {
        let mount = SCNNode()
        mount.name = "residentChairEyes"
        mount.position = SCNVector3(0, 0.458, 0.1775)          // the top rail's front face (rail: y 0.46, z 0.19, 0.025 deep)
        seat.addChildNode(mount)
        let brass = SupplyModels.mat(UIColor(red: 0.72, green: 0.55, blue: 0.26, alpha: 1), metal: 0.85, rough: 0.3)
        let ivory = SupplyModels.mat(UIColor(red: 0.96, green: 0.93, blue: 0.85, alpha: 1), rough: 0.22,
                                     glow: UIColor(red: 0.2, green: 0.19, blue: 0.16, alpha: 1))      // (readable in a dim room)
        let iris = SupplyModels.mat(UIColor(red: 0.2, green: 0.4, blue: 0.32, alpha: 1), rough: 0.35,
                                    glow: UIColor(red: 0.03, green: 0.07, blue: 0.05, alpha: 1))
        let pupil = SupplyModels.mat(UIColor(white: 0.02, alpha: 1), rough: 0.1)
        let glint = SCNMaterial()
        glint.lightingModel = .constant
        glint.diffuse.contents = UIColor.white
        let walnut = SupplyModels.mat(UIColor(red: 0.3, green: 0.18, blue: 0.1, alpha: 1), rough: 0.6)
        var pivots: [SCNNode] = [], lids: [SCNNode] = [], brows: [SCNNode] = []
        for x in [Float(-0.085), 0.085] {
            SupplyModels.part(SCNTube(innerRadius: 0.031, outerRadius: 0.037, height: 0.008), brass, in: mount,
                              at: SCNVector3(x, 0, -0.001), euler: SCNVector3(Float.pi / 2, 0, 0))
            let pivot = SCNNode()
            pivot.position = SCNVector3(x, 0, 0.004)
            mount.addChildNode(pivot)
            let lid = SCNNode()
            pivot.addChildNode(lid)
            SupplyModels.part(SCNSphere(radius: 0.03), ivory, in: lid)
            let i = SupplyModels.part(SCNSphere(radius: 0.016), iris, in: lid, at: SCNVector3(0, 0, -0.0275))
            i.scale = SCNVector3(1, 1, 0.35)
            let p = SupplyModels.part(SCNSphere(radius: 0.0085), pupil, in: lid, at: SCNVector3(0, 0, -0.031))
            p.scale = SCNVector3(1, 1, 0.35)
            SupplyModels.part(SCNSphere(radius: 0.0035), glint, in: lid, at: SCNVector3(-0.006, 0.007, -0.0345))
            pivots.append(pivot)
            lids.append(lid)
            let brow = SCNNode()
            brow.position = SCNVector3(x, 0.046, -0.004)
            mount.addChildNode(brow)
            SupplyModels.part(SCNBox(width: 0.062, height: 0.011, length: 0.014, chamferRadius: 0.004), walnut, in: brow)
            brows.append(brow)
        }
        return (mount, pivots, lids, brows)
    }

    /// Its part of an expression: brows and a little body language.
    private func express(_ e: CritterExpression) {
        func browsTo(lift dy: Float, tilt: Float, hold: Double) {
            for (i, b) in brows.enumerated() {
                let side: Float = i == 0 ? -1 : 1
                let go = SCNAction.group([.move(to: SCNVector3(b.position.x, 0.046 + dy, -0.004), duration: 0.12),
                                          .rotateTo(x: 0, y: 0, z: CGFloat(tilt * side), duration: 0.12)])
                let back = SCNAction.group([.move(to: SCNVector3(b.position.x, 0.046, -0.004), duration: 0.35),
                                            .rotateTo(x: 0, y: 0, z: 0, duration: 0.35)])
                b.runAction(.sequence([go, .wait(duration: hold), back]), forKey: "brow")
            }
        }
        let still = !isMoving && !gesturing
        switch e {
        case .surprised:
            browsTo(lift: 0.014, tilt: 0, hold: 0.7)
            guard still else { return }
            let rear = SCNAction.rotateBy(x: 0.14, y: 0, z: 0, duration: 0.1)
            seat.runAction(.sequence([rear, .wait(duration: 0.35), rear.reversed()]))
            creak()
        case .curious:
            browsTo(lift: 0.006, tilt: 0.18, hold: 1.2)
            guard still else { return }
            let tilt = SCNAction.rotateBy(x: 0, y: 0, z: 0.07, duration: 0.3)
            tilt.timingMode = .easeInEaseOut
            seat.runAction(.sequence([tilt, .wait(duration: 1.0), tilt.reversed()]))
        case .hesitant:
            browsTo(lift: -0.003, tilt: -0.22, hold: 1.0)
            guard still else { return }
            face(gait.yaw + 0.18, duration: 0.25)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, !self.isMoving else { return }
                self.face(self.gait.yaw - 0.18, duration: 0.3)
            }
        case .recognizing, .followMe:
            browsTo(lift: 0.008, tilt: 0, hold: 0.5)
            guard still else { return }
            nod()
        case .drowsy:
            browsTo(lift: -0.006, tilt: 0.06, hold: 2.5)
        case .calm:
            break
        }
    }

    /// Oct 20 (follow a critter): its come-hither when the player chooses to
    /// follow it -- eyes on them, brows up and a nod (its own .followMe), a
    /// little side-to-side shuffle of the seat, a creak. Its walk carries on.
    func acknowledge(player: SIMD2<Float>?) {
        if let p = player { attention.glanceAt(SIMD3<Float>(p.x, 1.5, p.y), label: "the player following", hold: 1.2) }
        attention.react(.followMe, for: 1.6)
        if !ResidentMusic.greet(diagnosticID, on: root) { say(ResidentVoice.chairCreaks.randomElement()) }   // Oct 22 (musical building)
        guard !gesturing else { return }
        let rock = SCNAction.rotateBy(x: 0, y: 0, z: 0.1, duration: 0.12)
        rock.timingMode = .easeInEaseOut
        seat.runAction(.sequence([rock, rock.reversed(), rock.reversed(), rock]))      // (unkeyed: always runs to its end, the seat level again)
    }

    /// A small forward dip of the seat and back: a nod.
    func nod() {
        let dip = SCNAction.rotateBy(x: -0.12, y: 0, z: 0, duration: 0.14)
        dip.timingMode = .easeInEaseOut
        seat.runAction(.sequence([dip, dip.reversed(), dip, dip.reversed()]))
    }

    var speed: Float { guidePace ?? Self.speed }
    /// Oct 20 (night): guiding the player -- the guide's pace (nil: its own trot).
    private var guidePace: Float?
    /// Its trot's step (m): its own 0.2, longer while guiding (GuidePace.gait).
    private var stepLength: Float = 0.2
    /// How far its legs swing (rad): a longer step, a little more swing.
    private var legSwing: Float = 0.4

    /// Oct 20 (night): brisk while guiding; nil: its own trot. Taken up by its next
    /// walk (a guide's walk always begins with it; so does its next errand after).
    func setGuidePace(_ mps: Float?) {
        guidePace = mps.map { max($0, Self.speed) }
        let g = mps == nil ? (stride: Float(1), cadence: Float(1)) : GuidePace.gait(normalPace: Self.speed)
        stepLength = 0.2 * g.stride
        legSwing = min(0.6, 0.4 * pow(g.stride, 0.5))
    }
    /// Oct 18 (repair): the MODEL position. Its own actions write the model
    /// node every frame, so this is always where the chair is -- whereas the
    /// presentation node of a body just added to the scene still reads the
    /// origin, (0,0), until SceneKit commits the frame: a walk planned at once
    /// from there started at cell (0,0) (the reported "(0,0) route origin").
    var groundPosition: SIMD2<Float>? {
        guard root.parent != nil else { return nil }
        return SIMD2<Float>(root.position.x, root.position.z)
    }
    var heading: Float { gait.yaw }
    var isGesturing: Bool { gesturing }
    var isMoving: Bool { root.action(forKey: "move") != nil }
    var isStepping: Bool { root.action(forKey: "steps") != nil }

    /// Oct 18 (diagnostics): the chair should only ever turn about y -- its
    /// up axis straight up. (Checked on the node's actual transform, not its
    /// Euler readback, which can legitimately show x = z = 180 for an upright
    /// yaw past 90 degrees.) Said once per body.
    private func checkOrientation(_ when: String) {
        let raw = root.simdTransform.columns.1
        let up = simd_length(raw) > 1e-6 ? raw / simd_length(raw) : raw        // (Oct 20: its 1.2x size taken out)
        guard !oddReported, up.y < 0.95 else { return }
        oddReported = true
        LifeLog.warn(diagnosticID, "body.orientationOdd",
                     ["when": when, "up": String(format: "(%.2f, %.2f, %.2f)", up.x, up.y, up.z), "yaw": gait.yaw,
                      "note": "not upright: something other than its own yaw has rotated it"])
    }

    /// Its facing, set whole (never one Euler component on top of a readback).
    private static func apply(yaw: Float, to node: SCNNode) {
        node.eulerAngles = SCNVector3(0, yaw, 0)
    }
    private var here: SIMD2<Float> { groundPosition ?? SIMD2<Float>(root.position.x, root.position.z) }
    private static func heading(_ v: SIMD2<Float>) -> Float { atan2(-v.x, -v.y) }

    func place(at p: SIMD2<Float>, heading: Float) {
        halt()
        root.position = SCNVector3(p.x, 0, p.y)
        gait.yaw = ChairGait.wrap(heading)
        Self.apply(yaw: gait.yaw, to: root)
    }

    /// Oct 18 (repair): everything it was doing stops at once -- a superseded
    /// walk, its footsteps, a turn -- so nothing old keeps moving the body after
    /// its route changes or its presenter goes.
    func halt() {
        root.removeAction(forKey: "move")
        root.removeAction(forKey: "steps")
        root.removeAction(forKey: "face")
        root.removeAction(forKey: "scoot")
        lift.removeAction(forKey: "rest")
        for leg in legs { leg.eulerAngles.x = 0 }
        gesturing = false
    }

    /// Oct 22 (sound audit): its creak is its VOICE (a surprised creak, an idle
    /// creak, a creak while it works or rests, its come-along) -- with the musical
    /// identities on its signature is its only voice, so these stay quiet. Its
    /// shuffles (footsteps), knock (a door) and swivel / scoot (visible motion) are
    /// sounds of what it does, and stay.
    private func creak() {
        guard !ResidentMusic.hushesVoices else { return }
        say(ResidentVoice.chairCreaks.randomElement())
    }

    private func say(_ source: SCNAudioSource?) {
        guard let source, root.parent != nil else { return }
        CritterAudio.play(source, on: root)
    }

    /// Turn to yaw `h` the short way round, from its own kept yaw (never an
    /// Euler rotateTo, which interpolates x and z too and can tumble it).
    private func face(_ h: Float, duration: Double = 0.5) {
        root.removeAction(forKey: "face")
        let g = gait
        let from = g.yaw
        let delta = ChairGait.wrap(h - from)
        guard abs(delta) > 0.001 else { return }
        let turn = SCNAction.customAction(duration: duration) { n, elapsed in
            let u = Float(min(1, elapsed / CGFloat(duration)))
            let eased = u * u * (3 - 2 * u)
            g.yaw = ChairGait.wrap(from + delta * eased)
            n.eulerAngles = SCNVector3(0, g.yaw, 0)
        }
        root.runAction(turn, forKey: "face")
    }

    // MARK: Walking: a brisk four-legged trot, legs in diagonal pairs

    func travel(_ path: [SIMD2<Float>], then: @escaping () -> Void) {
        checkOrientation("travel")
        if root.action(forKey: "move") != nil {
            LifeLog.warn(diagnosticID, "body.travelSuperseded",
                         ["at": LifeLog.point(here), "note": "a running travel was replaced: its completion will never run",
                          "stepping": isStepping])
        }
        root.removeAction(forKey: "face")
        root.removeAction(forKey: "move")
        var points = [here]
        for p in path where simd_distance(p, points[points.count - 1]) > 0.05 { points.append(p) }
        guard points.count > 1 else {
            LifeLog.trace(diagnosticID, "body.travel.zeroLength", ["at": LifeLog.point(here), "stepping": isStepping])
            DispatchQueue.main.async { then() }
            return
        }
        var cumulative: [Float] = [0]
        for i in 1..<points.count { cumulative.append(cumulative[i - 1] + simd_distance(points[i], points[i - 1])) }
        let total = cumulative[cumulative.count - 1]
        let duration = Double(total / self.speed) + 0.15
        travels += 1
        let number = travels, startedAt = CACurrentMediaTime(), id = diagnosticID
        LifeLog.trace(id, "body.travel.start", ["n": number, "from": LifeLog.point(points[0]), "to": LifeLog.point(points[points.count - 1]),
                                                "waypoints": points.count - 1, "metres": total, "seconds": duration,
                                                "yaw": gait.yaw])
        let pts = points, cum = cumulative
        func point(at s: Float) -> SIMD2<Float> {
            var i = 0
            while i < cum.count - 2 && cum[i + 1] < s { i += 1 }
            let span = max(0.0001, cum[i + 1] - cum[i])
            let t = min(1, max(0, (s - cum[i]) / span))
            return pts[i] + (pts[i + 1] - pts[i]) * t
        }
        var lastElapsed: CGFloat = 0
        let g = gait, legNodes = legs, liftNode = lift, seatNode = seat, speed = self.speed
        let stepLen = stepLength, swing = legSwing                      // (Oct 20, night: as this walk began)
        let move = SCNAction.customAction(duration: duration) { n, elapsed in
            let u = Float(min(1, elapsed / CGFloat(duration)))
            let along = u * total
            let p = point(at: along)
            let ahead = point(at: min(total, along + 0.25)) - p
            let dt = Float(max(0, elapsed - lastElapsed))
            if simd_length(ahead) > 0.01 {
                // Face where it's going: the short way round from its kept yaw, set whole.
                let dir = simd_normalize(ahead)
                let turn = ChairGait.wrap(atan2(-dir.x, -dir.y) - g.yaw)
                g.yaw = ChairGait.wrap(g.yaw + turn * min(1, dt * 6))
                n.eulerAngles = SCNVector3(0, g.yaw, 0)
            }
            lastElapsed = elapsed
            n.position = SCNVector3(p.x, 0, p.y)
            // The trot: diagonal pairs swing, a little bob, a little sway.
            g.phase += dt * speed / stepLen * .pi
            let s = sin(g.phase)
            let easing = min(1, min(along, total - along) / 0.25)
            for (i, leg) in legNodes.enumerated() {
                let pairOffset: Float = (i == 0 || i == 3) ? 0 : .pi
                leg.eulerAngles.x = sin(g.phase + pairOffset) * swing * easing
            }
            liftNode.position.y = 0.46 + abs(s) * 0.012 * easing
            seatNode.eulerAngles.z = s * 0.03 * easing
        }
        // Oct 18 (resident audio): soft wooden shuffles while it goes -- irregular,
        // quiet, now and then a creak -- through CritterAudio (distance, walls,
        // Mute), from where it is. (Was a raw click every 0.3 s that bypassed all
        // of that: the "pounding" heard from anywhere on the floor.)
        let shuffles = ResidentVoice.chairShuffles, creaks = ResidentVoice.chairCreaks
        // Oct 23 (walking music): with the musical identities on, its walking sound is its
        // signature (ResidentWalkingMusic, the same for every critter) -- no shuffles then.
        if !shuffles.isEmpty, !ResidentMusic.hushesVoices {
            let step = SCNAction.run { n in if let s = shuffles.randomElement() { CritterAudio.play(s, on: n) } }
            let maybeCreak = SCNAction.run { n in
                // (Oct 22, sound audit: the random walking creak is a voice too -- quiet with the identities on)
                if !ResidentMusic.hushesVoices, Int.random(in: 0..<7) == 0, let c = creaks.randomElement() { CritterAudio.play(c, on: n) }
            }
            root.runAction(.repeatForever(.sequence([step, .wait(duration: 0.62, withRange: 0.36), maybeCreak])), forKey: "steps")
        }
        root.runAction(move, forKey: "move") { [weak self] in
            DispatchQueue.main.async {
                guard let self else { then(); return }
                self.root.removeAction(forKey: "steps")
                for leg in self.legs { leg.eulerAngles.x = 0 }
                LifeLog.trace(id, "body.travel.done", ["n": number, "at": LifeLog.point(self.groundPosition),
                                                       "took": CACurrentMediaTime() - startedAt, "planned": duration])
                then()
            }
        }
    }

    /// A nudge at a door: up to it, a bump with the seat, back.
    func touch(_ point: SIMD2<Float>, contact: @escaping () -> Void, then: @escaping () -> Void) {
        let start = here
        let d = point - start
        let len = simd_length(d)
        let stop = len > 0.45 ? start + d * ((len - 0.4) / len) : start
        LifeLog.trace(diagnosticID, "body.touch", ["at": LifeLog.point(start), "target": LifeLog.point(point)])
        gesturing = true
        travel([stop]) { [weak self] in
            guard let self else { contact(); then(); return }
            let bump = SCNAction.rotateBy(x: -0.25, y: 0, z: 0, duration: 0.12)
            self.seat.runAction(.sequence([bump, bump.reversed()]))
            self.say(ResidentVoice.chairKnock)
            contact()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { then(); return }
                self.travel([start]) { [weak self] in
                    self?.gesturing = false
                    then()
                }
            }
        }
    }

    func watch(_ player: SIMD2<Float>) {
        guard !gesturing, root.action(forKey: "move") == nil else { return }
        face(Self.heading(player - here))
    }

    // MARK: Room activities (Oct 18, phase 2) -- small beats, each a second or two

    func turn(toward p: SIMD2<Float>, duration: Double = 0.6) {
        guard !isMoving else { return }
        face(Self.heading(p - here), duration: duration)
    }

    /// One beat of an activity. Never moves it off its spot (a scoot comes back).
    func activityBeat(_ kind: ResidentActivities.Kind, toward thing: SIMD2<Float>?) {
        guard !gesturing, !isMoving else { return }
        let roll = Int.random(in: 0..<4)
        switch kind {
        case .working:
            switch roll {
            case 0:                                                 // a swivel and back, as if turning to something
                let back = gait.yaw
                face(back + Float.random(in: -0.45...0.45), duration: 0.5)
                say(ResidentVoice.chairSwivel)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                    guard let self, !self.isMoving else { return }
                    self.face(back, duration: 0.6)
                }
            case 1:                                                 // shifts its weight
                let shift = SCNAction.rotateBy(x: 0, y: 0, z: CGFloat(Float.random(in: 0.04...0.07) * (Bool.random() ? 1 : -1)), duration: 0.35)
                shift.timingMode = .easeInEaseOut
                seat.runAction(.sequence([shift, .wait(duration: 1.2), shift.reversed()]))
            case 2:                                                 // scoots in a touch, then back
                if let thing {
                    let d = thing - here
                    let n = simd_length(d) > 0.01 ? d / simd_length(d) * 0.1 : .zero
                    let scoot = SCNAction.moveBy(x: CGFloat(n.x), y: 0, z: CGFloat(n.y), duration: 0.3)
                    scoot.timingMode = .easeInEaseOut
                    root.runAction(.sequence([scoot, .wait(duration: 1.4), scoot.reversed()]), forKey: "scoot")
                    say(ResidentVoice.chairShuffles.randomElement())
                }
            default:                                                // leans in over the work
                let lean = SCNAction.rotateBy(x: -0.1, y: 0, z: 0, duration: 0.4)
                lean.timingMode = .easeInEaseOut
                seat.runAction(.sequence([lean, .wait(duration: 1.6), lean.reversed()]))
                if Bool.random() { creak() }
            }
        case .inspecting, .visiting:
            if roll < 2 {                                           // leans in to look
                let lean = SCNAction.rotateBy(x: -0.13, y: 0, z: 0, duration: 0.45)
                lean.timingMode = .easeInEaseOut
                seat.runAction(.sequence([lean, .wait(duration: 1.2), lean.reversed()]))
            } else if roll == 2, let thing {                        // a look from a little to one side
                turn(toward: thing + SIMD2<Float>(Float.random(in: -0.6...0.6), Float.random(in: -0.6...0.6)), duration: 0.5)
            } else if kind == .visiting {
                nod()
            }
        case .resting:
            let sink = SCNAction.move(to: SCNVector3(0, 0.43, 0), duration: 0.8)
            sink.timingMode = .easeInEaseOut
            lift.runAction(sink, forKey: "rest")
            if roll == 0 { creak() }
        case .lookingAround:
            face(gait.yaw + Float.random(in: -1.3...1.3), duration: 0.9)
        case .circling, .investigating:
            idle()
        }
    }

    /// Up from resting (a walk does this anyway, frame by frame).
    func rise() {
        lift.removeAction(forKey: "rest")
        if lift.position.y < 0.455 { lift.runAction(.move(to: SCNVector3(0, 0.46, 0), duration: 0.3)) }
    }

    func pointOnward(_ onward: SIMD2<Float>, player: SIMD2<Float>) {}
    func call() { creak() }
    func urge(player: SIMD2<Float>, onward: SIMD2<Float>?, then: @escaping () -> Void) { DispatchQueue.main.async { then() } }
    func arrive(player: SIMD2<Float>) {}
    func depart() {}

    func settle(facing heading: Float?) {
        if let heading { face(heading) }
    }

    /// Staying put: now and then it dips its seat (grazing), creaks, or turns a little.
    func idle() {
        guard !gesturing, root.action(forKey: "move") == nil else { return }
        checkOrientation("idle")
        switch Int.random(in: 0..<3) {
        case 0:
            LifeLog.trace(diagnosticID, "body.idle", ["gesture": "seat dip"])
            let dip = SCNAction.rotateBy(x: -0.18, y: 0, z: 0, duration: 0.5)
            dip.timingMode = .easeInEaseOut
            seat.runAction(.sequence([dip, .wait(duration: Double.random(in: 1.5...3)), dip.reversed()]))
        case 1:
            LifeLog.trace(diagnosticID, "body.idle", ["gesture": "creak"])
            creak()
        default:
            let turn = Float.random(in: -1.2...1.2)
            LifeLog.trace(diagnosticID, "body.idle", ["gesture": "turn in place", "by": turn, "fromYaw": gait.yaw])
            face(gait.yaw + turn, duration: 0.9)
        }
    }
}
