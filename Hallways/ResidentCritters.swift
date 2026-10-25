//
//  ResidentCritters.swift
//  Hallways
//
//  Oct 18 (open the building) -- THE BUILDING'S OTHER RESIDENTS.
//
//  The Menagerie already holds finished creatures -- bodies, gaits, voices --
//  that had nothing to do since the ambient menagerie was switched off
//  (LivingWorld.ambientCritters). One of them, never given a scripted part of
//  its own, is a resident here, living the same life as the chair (Roam: rooms,
//  the elevator, offscreen time, rebuilds):
//
//    Pottle                    a slow potted plant that walks on its pot
//
//  Oct 19 (Stage A, final cast): Clacker, Little Clacker, Dog, Cat and Little
//  Pottle are retired for good. Their saved records and Contacts are purged at
//  load (ResidentRoster.retiredIDs; BuildingLife, ContactsStore).
//
//  Not released (they have scripted parts): the Stalk (the staff meeting's
//  beckoning lamp), the Ladder (the meeting's boss), Jeff, Tinky, Juanita, the
//  Big Shot, Candy -- and the Frog and the Slinky, whose travel is built into
//  their own hops and steps (they can't follow a route).
//
//  HOW: a creature's own Critter object keeps its body, its gait (its own
//  animation, every frame) and its footsteps; its own brain sits out while a
//  ResidentErrand holds it -- the same mechanism the staff meeting uses to walk
//  them to the conference room (Critter.errand, freePoint). The errand only
//  says where to go next, how fast, and what to look at; CritterResidentBody
//  turns that into the RoamerBody the resident life already drives (walks with
//  the lead engine, doors, the elevator's door cycle, room visits).
//
//  ARRIVAL: each resident's record begins in the lobby with no place yet; at
//  its own time (staggered, one at a time) it walks in at the lobby entrance,
//  to the elevator, and off to its first room (Roam.decide's `entering`). Its
//  record is saved from the first moment, so it arrives once, ever.
//

import Foundation
import QuartzCore
import SceneKit
import UIKit
import simd

// MARK: - The errand: where to go, at what pace, what to look at

nonisolated final class ResidentErrand: CritterErrand, @unchecked Sendable {
    private let lock = NSLock()
    private var path: [SIMD2<Float>] = []
    private var index = 0
    private var pace: Float = 0.8
    private var look: SIMD2<Float>?
    private var hold: SIMD2<Float>?
    private var teleport: (point: SIMD2<Float>, heading: Float)?
    private var finished: (() -> Void)?
    private var clock: Double = 0
    private var nextVoice: Double = Double.random(in: 8...30)
    /// Oct 20 (follow a critter): hops still to make (seconds of hopping left).
    private var hopLeft: Double = 0
    /// Oct 20 (night): its step's length x (guiding: longer -- Pottle's rim-to-rim tip).
    private var strideScale: Float = 1
    static let hopSeconds: Double = 0.32
    static let hopHeight: Float = 0.06
    /// Its voice now and then while it goes about (never words).
    var voices: [SCNAudioSource] = []
    var voiceEvery: ClosedRange<Double> = 30...90

    var isMoving: Bool { lock.withLock { index < path.count } }

    /// Along these points, at `pace` (m/s); `then` (main thread) on arrival.
    func go(_ points: [SIMD2<Float>], pace: Float, then: @escaping () -> Void) {
        lock.withLock {
            path = points
            index = 0
            self.pace = pace
            finished = then
            look = nil
        }
    }

    /// Stop where it is (or at `p`): nothing of a walk carries on.
    func stop(at p: SIMD2<Float>?) {
        lock.withLock {
            path = []
            index = 0
            finished = nil
            if let p { hold = p }
        }
    }

    /// Set it down here, facing `heading`, at once.
    func place(_ p: SIMD2<Float>, heading: Float) {
        lock.withLock {
            teleport = (p, heading)
            path = []
            index = 0
            finished = nil
            hold = p
        }
    }

    func lookAt(_ p: SIMD2<Float>?) { lock.withLock { look = p } }

    /// A few little hops in place or along its way (Critter.lift -- "a hop an
    /// errand asks for"); its walk is untouched.
    func hop(times: Int) { lock.withLock { hopLeft = Double(max(0, times)) * Self.hopSeconds } }

    /// Oct 20 (night): the walk's pace now -- and its step's length -- even mid-walk.
    func setPace(_ p: Float, stride: Float) { lock.withLock { pace = p; strideScale = stride } }

    override func step(_ c: Critter, dt: Double, now: CFTimeInterval) {
        var done: (() -> Void)?
        var voice: SCNAudioSource?
        lock.lock()
        clock += dt
        if let t = teleport {
            c.pos = t.point
            c.heading = t.heading
            c.speed = 0
            c.velocity = .zero
            teleport = nil
        }
        if index < path.count, simd_distance(c.pos, path[index]) < 0.1 {
            index += 1
            if index >= path.count {
                hold = c.pos
                done = finished
                finished = nil
            }
        }
        if index < path.count {
            c.freePoint = path[index]
            c.wantSpeed = pace
            c.lookAt = nil
            c.pause = 0
        } else {
            c.freePoint = hold ?? c.pos              // (never let go: off a point, it would snap to the habitat's graph)
            c.wantSpeed = 0
            c.lookAt = look
        }
        if clock >= nextVoice, !voices.isEmpty, !ResidentMusic.hushesVoices {   // Oct 22 (stability pass): no murmurs with the identities on
            voice = voices.randomElement()
            nextVoice = clock + Double.random(in: voiceEvery)
        }
        (c as? Pottle)?.strideScale = strideScale                   // (render thread, as its gait reads it)
        if hopLeft > 0 {
            hopLeft = max(0, hopLeft - dt)
            let u = hopLeft.truncatingRemainder(dividingBy: Self.hopSeconds) / Self.hopSeconds
            c.lift = hopLeft > 0 ? Self.hopHeight * Float(sin(u * .pi)) : 0
        }
        lock.unlock()
        if let voice { c.say(voice, loud: false) }
        if let done { DispatchQueue.main.async { done() } }
    }
}

// MARK: - The body the resident life drives

final class CritterResidentBody: RoamerBody {
    let root: SCNNode
    let critter: Critter
    /// Its walking pace now (m/s): its own, or the guide's while it leads the player.
    var speed: Float { guidePace ?? ownPace }
    private let ownPace: Float
    private var guidePace: Float?
    var diagnosticID = "critter"
    private let errand = ResidentErrand()
    private var gesturing = false
    private var lookReset = 0

    init(critter: Critter, node: SCNNode, name: String, pace: Float, voices: [SCNAudioSource], voiceEvery: ClosedRange<Double>) {
        self.critter = critter
        root = node
        ownPace = pace
        node.name = name
        errand.voices = voices
        errand.voiceEvery = voiceEvery
        critter.errand = errand                                   // (before its tick ever runs: its own brain sits out)
        node.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }
        node.runAction(.repeatForever(critter.tickAction()), forKey: "critterTick")
    }

    var groundPosition: SIMD2<Float>? {
        guard root.parent != nil else { return nil }
        return SIMD2<Float>(root.position.x, root.position.z)
    }
    private var here: SIMD2<Float> { SIMD2<Float>(root.position.x, root.position.z) }
    var heading: Float { critter.heading }
    var isGesturing: Bool { gesturing }
    var isMoving: Bool { errand.isMoving }
    var isStepping: Bool { false }
    var activitySpecies: ResidentActivities.Species { .critter }

    func place(at p: SIMD2<Float>, heading: Float) {
        critter.pos = p
        critter.heading = heading
        errand.place(p, heading: heading)
        root.position = SCNVector3(p.x, 0, p.y)
        root.eulerAngles = SCNVector3(0, heading, 0)
    }

    func halt() {
        errand.stop(at: groundPosition)
        gesturing = false
    }

    func travel(_ path: [SIMD2<Float>], then: @escaping () -> Void) {
        var points: [SIMD2<Float>] = []
        var last = here
        for p in path where simd_distance(p, last) > 0.05 { points.append(p); last = p }
        guard !points.isEmpty else { DispatchQueue.main.async { then() }; return }
        errand.go(points, pace: speed, then: then)
    }

    func touch(_ point: SIMD2<Float>, contact: @escaping () -> Void, then: @escaping () -> Void) {
        let start = here
        let d = point - start
        let len = simd_length(d)
        let stop = len > 0.5 ? start + d * ((len - 0.45) / len) : start
        gesturing = true
        travel([stop]) { [weak self] in
            contact()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { then(); return }
                self.travel([start]) { [weak self] in
                    self?.gesturing = false
                    then()
                }
            }
            _ = self
        }
    }

    /// Look at a point for a while, then look where it likes again.
    private func glance(_ p: SIMD2<Float>, for seconds: Double) {
        errand.lookAt(p)
        lookReset += 1
        let token = lookReset
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.lookReset == token else { return }
            self.errand.lookAt(nil)
        }
    }

    func watch(_ player: SIMD2<Float>) { if !isMoving { glance(player, for: 3) } }

    /// Oct 20 (night): brisk while guiding (its steps longer as well as quicker: its
    /// own animation strides by distance); nil: its own pace -- at once, mid-walk too.
    func setGuidePace(_ mps: Float?) {
        guidePace = mps.map { max($0, ownPace) }
        let g = mps == nil ? (stride: Float(1), cadence: Float(1)) : GuidePace.gait(normalPace: ownPace, strideCap: GuidePace.pottleStrideCap)
        errand.setPace(speed, stride: g.stride)
    }

    /// Oct 20 (follow a critter): its come-hither -- a look at the player (if
    /// it's standing), two little hops and its own voice; its errand carries on.
    func acknowledge(player: SIMD2<Float>?) {
        if let p = player, !isMoving { glance(p, for: 2.5) }
        errand.hop(times: 2)
        if !ResidentMusic.greet(diagnosticID, on: root) { call() }                     // Oct 22 (musical building)
    }
    func pointOnward(_ onward: SIMD2<Float>, player: SIMD2<Float>) {}
    func call() { if !ResidentMusic.hushesVoices, let v = errand.voices.randomElement() { critter.say(v, loud: false) } }
    func urge(player: SIMD2<Float>, onward: SIMD2<Float>?, then: @escaping () -> Void) { DispatchQueue.main.async { then() } }
    func arrive(player: SIMD2<Float>) {}
    func depart() {}

    func settle(facing heading: Float?) {
        guard let heading else { return }
        glance(here + SIMD2<Float>(-sin(heading), -cos(heading)) * 2, for: 4)
    }

    func idle() {
        let a = Float.random(in: 0..<(2 * .pi))
        glance(here + SIMD2<Float>(cos(a), sin(a)) * 2, for: Double.random(in: 2...5))
    }

    func turn(toward p: SIMD2<Float>, duration: Double) { glance(p, for: 6) }

    func activityBeat(_ kind: ResidentActivities.Kind, toward thing: SIMD2<Float>?) {
        if let thing, Bool.random() { glance(thing + SIMD2<Float>(Float.random(in: -0.4...0.4), Float.random(in: -0.4...0.4)), for: 3) }
        else { idle() }
    }
}

// MARK: - A floor's habitat (the creatures' own plumbing, one per scene)

enum ResidentHabitats {
    private static weak var currentRoot: SCNNode?
    private static var currentHabitat: Habitat?

    /// The habitat for this scene (made once per scene): its walk graph is the
    /// floor's cells and doors. Residents never use it to choose a way -- the
    /// errand does -- it's only what a Critter needs to exist.
    static func habitat(root: SCNNode, camera: SCNNode, context: CharacterLead.Context) -> Habitat {
        if let h = currentHabitat, currentRoot === root { return h }
        let graph = Menagerie.makeGraph(cells: context.cells, cellSize: CGFloat(context.cellSize),
                                        doors: context.doors.map { ($0.key, $0.value) }, litCells: [])
        let h = Habitat(graph: graph, root: root, playerCamera: camera)
        currentRoot = root
        currentHabitat = h
        return h
    }
}

// MARK: - The roster

/// One resident of this kind: who, how it looks and sounds, how it lives.
struct ResidentProfile {
    let id: String
    let name: String
    /// Its place in the arrival line (0 first).
    let arrivalOrder: Int
    let normal: RoamStyle
    let fast: RoamStyle
    /// Its walking pace (m/s).
    let pace: Float
    let voiceEvery: ClosedRange<Double>
    let voices: @MainActor () -> [SCNAudioSource]
    let make: @MainActor (_ habitat: Habitat, _ cell: Int, _ shadow: UIImage) -> (Critter, SCNNode)
}

final class CritterResidentKind: ResidentKind {
    let profile: ResidentProfile
    let kind: String
    let abilities: Set<ResidentAbility> = [.walk, .rideElevator]
    private static let shadow = Menagerie.shadowImage()

    init(_ profile: ResidentProfile) {
        self.profile = profile
        kind = "critter.\(profile.id)"
    }

    var style: RoamStyle { BuildingLife.pacing(normal: profile.normal, fast: profile.fast) }

    /// It isn't in the building yet: it comes in at the lobby entrance at its time.
    func newcomers(now: Date) -> [Resident] {
        [Resident(id: profile.id, kind: kind, floor: ResidentPolicy.lobbyFloor, cell: nil,
                  since: now.addingTimeInterval(ResidentRoster.arrivalDelay(order: profile.arrivalOrder)), dwell: 0)]
    }

    func advance(_ r: inout Resident, to now: Date, plans: (Int) -> FloorPlan?) {
        ResidentRoster.advance(&r, order: profile.arrivalOrder, style: style, abilities: abilities, plans: plans, to: now)
    }

    func present(_ id: String, on stage: FloorStage) -> ResidentPresentation? {
        guard Admission.isCompleted, !Admission.isQuietOnboarding(floor: stage.floor), let context = stage.context,
              let root = stage.root, let controller = stage.controller else { return nil }
        let camera = stage.camera
        let p = profile
        return RoamPresentation(residentID: id, floor: stage.floor, root: root, controller: controller, context: context,
                                style: style, abilities: abilities) { [weak root, weak camera] in
            let scene = root ?? SCNNode()                                 // (spawn never asks once the floor is gone)
            let habitat = ResidentHabitats.habitat(root: scene, camera: camera ?? scene, context: context)
            let any = context.cells.first.map { HabitatGraph.key(row: $0.row, col: $0.col) } ?? 0
            let (critter, node) = p.make(habitat, any, Self.shadow)
            return CritterResidentBody(critter: critter, node: node, name: "resident.\(p.id)", pace: p.pace,
                                       voices: p.voices(), voiceEvery: p.voiceEvery)
        }
    }
}

enum ResidentRoster {
    /// When the n-th newcomer walks in (seconds after it is first known):
    /// the first after half a minute, then one about every minute and a quarter.
    static func arrivalDelay(order: Int) -> TimeInterval { 30 + 75 * Double(max(0, order)) }

    /// Oct 19: "not in the building yet, and not yet due" -- a newcomer waiting
    /// for the building to open (far in the future: its record never decides).
    static let notYet = Date(timeIntervalSinceReferenceDate: 4_000_000_000)

    /// Oct 19: a newcomer waits outside until the building opens (onboarding
    /// over); its place in the line counts from that moment, not from when
    /// its record was made. True: held (don't advance it). Pure but for its log lines.
    @discardableResult
    static func holdArrival(_ r: inout Resident, order: Int, open: Bool, now: Date) -> Bool {
        holdArrival(&r, delay: arrivalDelay(order: order), open: open, now: now, order: order)
    }

    /// Oct 19 (the Hallwaysians): the same hold, with the arrival `delay` given
    /// directly (counted from the opening) rather than from a place in this line.
    @discardableResult
    static func holdArrival(_ r: inout Resident, delay: TimeInterval, open: Bool, now: Date, order: Int? = nil) -> Bool {
        guard r.cell == nil, r.leg == nil, r.floor == ResidentPolicy.lobbyFloor else { return false }
        if !open {
            if r.since < notYet {
                r.since = notYet
                r.dwell = 0
                r.why = "waiting outside: the building opens to residents when onboarding is over"
                LifeLog.pop(r.id, "arrival.held", floor: r.floor, ["why": "onboarding not finished", "order": order])
            }
            return true
        }
        if r.since >= notYet {
            r.since = now.addingTimeInterval(delay)
            r.dwell = 0
            r.why = "the building is open: in at the lobby entrance at its turn"
            LifeLog.pop(r.id, "arrival.scheduled", floor: r.floor, ["order": order, "arrival": LifeLog.at(r.since, now: now)])
        }
        return false
    }

    /// A newcomer's life: held until the building opens, then the shared Roam;
    /// its walk in at the lobby entrance said in full for the [Pop] trace.
    static func advance(_ r: inout Resident, order: Int, style: RoamStyle, abilities: Set<ResidentAbility>,
                        plans: (Int) -> FloorPlan?, to now: Date) {
        if holdArrival(&r, order: order, open: ResidentPolicy.buildingOpen, now: now) { return }
        let outside = r.cell == nil && r.floor == ResidentPolicy.lobbyFloor
        Roam.advance(&r, style: style, abilities: abilities, plans: plans, to: now)
        guard outside else { return }
        if let leg = r.leg, leg.from.floor == ResidentPolicy.lobbyFloor {
            LifeLog.pop(r.id, "lobby.entry", floor: leg.from.floor,
                        ["entrance": LifeLog.cell(leg.from.cell), "destination": "F\(r.floor) \(r.roomName ?? "?") \(LifeLog.cell(r.cell))",
                         "boardsAt": leg.boardAt.map { LifeLog.at($0, now: now) }, "outAt": leg.alightAt.map { LifeLog.at($0, now: now) },
                         "why": r.why])
        } else if r.cell == nil {
            LifeLog.popWarn(r.id, "lobby.entry.failed", floor: r.floor, ["why": r.why, "action": "tries again shortly"])
        }
    }

    private static func fast(_ s: RoamStyle) -> RoamStyle {
        var f = s
        f.stay = 8...15
        f.changeFloorChance = max(0.5, s.changeFloorChance)
        return f
    }

    static let profiles: [ResidentProfile] = {
        func style(_ floors: [Int: Double], stay: ClosedRange<Double>, pace: Float, change: Double, taste: [String: Double]) -> RoamStyle {
            var s = RoamStyle(floors: floors, stay: stay, speed: pace, changeFloorChance: change)
            s.roomTaste = taste
            return s
        }
        var list: [ResidentProfile] = []
        func add(_ id: String, _ name: String, order: Int, pace: Float, floors: [Int: Double], stay: ClosedRange<Double>,
                 change: Double, taste: [String: Double], voiceEvery: ClosedRange<Double>,
                 voices: @escaping @MainActor () -> [SCNAudioSource],
                 make: @escaping @MainActor (Habitat, Int, UIImage) -> (Critter, SCNNode)) {
            let s = style(floors, stay: stay, pace: pace, change: change, taste: taste)
            list.append(ResidentProfile(id: id, name: name, arrivalOrder: order, normal: s, fast: fast(s), pace: pace,
                                        voiceEvery: voiceEvery, voices: voices, make: make))
        }
        // A slow, settled plant: long stays by light and water.
        add("pottle.1", "Pottle", order: 1, pace: 0.35,
            floors: [6: 1, 7: 1, 11: 2, 12: 1, 16: 0.5],
            stay: 120...300, change: 0.15, taste: ["Lamp": 2, "Aquarium": 3, "Darkroom": 2], voiceEvery: 40...110,
            voices: { Pottle.rustles }, make: { h, c, s in Pottle.make(habitat: h, cell: c, shadow: s, scale: ResidentRoster.residentSizeScale) })
        return list
    }()

    static let kinds: [ResidentKind] = profiles.map { CritterResidentKind($0) }
    /// Oct 20: the roaming critters are a fifth bigger than as designed (Pottle's own size knob: its
    /// body, gait and step sounds all scale together).
    static let residentSizeScale: Float = 1.2

    /// Oct 19 (Stage A): residents retired from the cast for good. A saved game
    /// may still hold their records or Contacts; both are dropped at load.
    static let retiredIDs: Set<String> = ["clacker.1", "clacker.2", "dog.1", "cat.1", "pottle.2"]

    static func profile(_ id: String) -> ResidentProfile? { profiles.first { $0.id == id } }
}
