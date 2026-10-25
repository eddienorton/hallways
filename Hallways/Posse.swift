//
//  Posse.swift
//  Hallways
//
//  Oct 4 -- FIRST GAMEPLAY VERTICAL SLICE (Freddy / follow / elevator / fire).
//
//  The follower relationship, kept separate from any one critter:
//
//  - Posse.records: per-member story state that outlives a floor's scene
//    (following? where were they left?). The scene is rebuilt on every floor
//    change, so this is what carries a follower through the elevator.
//  - PosseMember: what a critter's driver offers the posse (id, name, where
//    it is, start/stop following). Freddy is the first; another critter
//    adopts the same protocol + FollowLeash to join later.
//  - FollowLeash: reusable render-thread follow logic -- a slot beside and a
//    little ahead of the player, a breadcrumb trail of where the player has
//    actually been (so a follower rounds corners the way we did), wall-safe
//    stepping, and a pragmatic hop-to-trail when it falls hopelessly behind.
//  - Tap a FREE member = engage it (Posse.handleTap, called from the scene's
//    tap handler before tap-to-walk): it follows. A FOLLOWING member is
//    transparent to the navigation surface: Posse.handleTap looks past it and
//    Posse.navigationHits drops it from the tap handler's own hit tests, so a
//    tap where he happens to stand acts on whatever is behind him. (Release
//    and conversation get their own deliberate gesture later.)
//
//  Deliberately NOT here yet: more than one follower at a time, capacity,
//  menus, persistence across app launches.
//

import SceneKit
import UIKit
import simd

// MARK: - Members

/// What a critter's driver exposes to the posse. Called from the main thread
/// (reads of position are a render-thread race, harmless for a UI check).
nonisolated protocol PosseMember: AnyObject {
    var memberID: String { get }
    var displayName: String { get }
    var groundPosition: SIMD2<Float> { get }
    var isFollowing: Bool { get }
    /// The member's root node in the scene (taps on any part of it resolve here).
    var sceneNode: SCNNode? { get }
    func startFollowing()
    func stayHere()
    /// Tapped while already following: a small "yes, I'm here".
    func acknowledge()
}

enum Posse {
    struct Record: Codable {
        var following = false
        /// Recruited at least once. Until then he turns up near wherever the
        /// player arrives (handy for testing); after, he lives where he is left.
        var met = false
        /// Where the member lives when not following (nil = not met yet).
        var homeFloor: Int?
        var home: SIMD2<Float>?
        var homeYaw: Float = 0
    }

    /// Story state per member id; survives scene rebuilds -- and (Oct 11,
    /// resume) app launches: met / following / home, saved on every change
    /// (ResumeState.posseKey). No animation state: a follower simply turns up
    /// around the player again, a member left somewhere is back at home.
    static var records: [String: Record] = loadRecords() {
        didSet {
            guard ResumeState.isRecording, let data = try? JSONEncoder().encode(records) else { return }
            UserDefaults.standard.set(data, forKey: ResumeState.posseKey)
        }
    }
    private static func loadRecords() -> [String: Record] {
        guard ResumeState.isRecording else { return [:] }
        let d = UserDefaults.standard
        guard let data = d.data(forKey: ResumeState.posseKey),
              var saved = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        diag("resume.posseRestored", ["members": saved.count])
        // Oct 17: Freddy (the living fire extinguisher) is removed from the game.
        // A save that still carries his record has it dropped; nothing else in
        // the save is touched.
        if saved.removeValue(forKey: "freddy") != nil {
            if let fixed = try? JSONEncoder().encode(saved) { d.set(fixed, forKey: ResumeState.posseKey) }
            diag("posse.retiredMemberDropped", ["member": "freddy"])
        }
        return saved
    }

    /// Oct 16 (III): the following member drawn at a screen point (its drawn
    /// bounds, grown for a finger), for the release gestures.
    static func followingMember(at point: CGPoint, in view: SCNView) -> PosseMember? {
        for m in members where m.isFollowing {
            guard let n = m.sceneNode, n.parent != nil else { continue }
            if let r = ToolBelt.screenRect(of: n, in: view, minimum: 0), r.contains(point) { return m }   // (his own shape: walking taps elsewhere stay walks)
        }
        return nil
    }

    /// Oct 16 (III): let a follower go -- swipe up on him, or press and hold
    /// him. He stays where he is (his new home), as Posse.release always meant.
    static func dismiss(_ member: PosseMember) {
        guard member.isFollowing else { return }
        release(member)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        diag("posse.dismissed", ["member": member.memberID, "floor": floor])
    }

    /// This floor's live members (rebuilt with every scene).
    private static var members: [PosseMember] = []
    private static weak var playerCamera: SCNNode?
    private static weak var view: SCNView?
    private static var floor = 0

    /// Called on every floor build, after the arrival pose is final.
    static func installFloor(view: SCNView, scene: SCNScene, playerCamera: SCNNode, floor: Int,
                             cells: Set<GridCoordinate>, cellSize: CGFloat, start: GridCoordinate, end: GridCoordinate,
                             fires: [GridCoordinate: SCNNode], allowFirstMeetings: Bool = true,
                             allowMembers: Bool = true,
                             extinguish: @escaping (GridCoordinate) -> Bool) {
        let tracePhase = ElevatorArrivalTrace.shared.beginPhase("Posse.installFloor")
        defer { ElevatorArrivalTrace.shared.endPhase("Posse.installFloor", tracePhase) }
        let traceMembers = ElevatorArrivalTrace.shared.beginPhase("Posse.releasePreviousMembers")
        self.view = view
        self.playerCamera = playerCamera
        self.floor = floor
        members = []
        ElevatorArrivalTrace.shared.endPhase("Posse.releasePreviousMembers", traceMembers)
        // Oct 5 (clean onboarding): nobody -- not even a follower -- appears on
        // a quiet onboarding floor. Records are left untouched.
        guard allowMembers else {
            diag("posse.heldBack", ["floor": floor, "following": records.filter { $0.value.following }.map(\.key).joined(separator: ",")])
            return
        }
        // Oct 17: Freddy, the only member installed here, is removed from the
        // game -- no member is placed. (The posse machinery itself is kept.)
    }

    struct FloorContext {
        let scene: SCNScene
        let playerCamera: SCNNode
        let cells: Set<GridCoordinate>
        let cellSize: Float
        let start: GridCoordinate
        let end: GridCoordinate
        let fires: [GridCoordinate: SCNNode]
        let extinguish: (GridCoordinate) -> Bool
    }

    /// Where (and whether) a member appears on this floor:
    /// following -> beside the player (in the elevator cab after a ride);
    /// never recruited -> a couple of cells from where the player arrives
    /// (the same spot again on a rebuild of the same floor);
    /// left on this floor -> where they were left; left elsewhere -> absent.
    enum Placement {
        case besidePlayer
        case at(SIMD2<Float>, yaw: Float)
    }

    private static func placement(for id: String, context: FloorContext, allowFirstMeeting: Bool = true) -> Placement? {
        var record = records[id] ?? Record()
        if record.following { return .besidePlayer }
        // Oct 5 (Admission): some floors are not a place to meet anyone yet.
        if !record.met, !allowFirstMeeting { return nil }
        if !record.met, record.homeFloor != floor {
            guard let spot = meetingSpot(context: context) else { return nil }
            record.homeFloor = floor
            record.home = spot.0
            record.homeYaw = spot.1
            records[id] = record
        }
        guard record.homeFloor == floor, let home = record.home else { return nil }
        return .at(home, yaw: record.homeYaw)
    }

    /// A cell two (else one) steps from the start, not the elevator, not on fire.
    private static func meetingSpot(context: FloorContext) -> (SIMD2<Float>, Float)? {
        var distance: [GridCoordinate: Int] = [context.start: 0]
        var queue = [context.start]
        var i = 0
        while i < queue.count {
            let c = queue[i]; i += 1
            guard let d = distance[c], d < 3 else { continue }
            for dir in Direction.allCases {
                let n = GridCoordinate(row: c.row + dir.delta.row, col: c.col + dir.delta.col)
                if context.cells.contains(n), distance[n] == nil { distance[n] = d + 1; queue.append(n) }
            }
        }
        func ok(_ c: GridCoordinate) -> Bool { c != context.end && context.fires[c] == nil }
        let pickCell = distance.filter { $0.value == 2 && ok($0.key) }.keys.randomElement()
            ?? distance.filter { $0.value == 1 && ok($0.key) }.keys.randomElement()
        guard let cell = pickCell else { return nil }
        let s = context.cellSize
        let center = SIMD2<Float>(Float(cell.col) * s, Float(cell.row) * s)
        let toStart = SIMD2<Float>(Float(context.start.col) * s, Float(context.start.row) * s) - center
        let jitter = SIMD2<Float>(Float.random(in: -0.35...0.35), Float.random(in: -0.35...0.35))
        return (center + jitter, atan2(toStart.x, toStart.y))
    }

    // MARK: Follow / stay (main thread)

    /// Oct 8 flight recorder: every member installed on this floor (where,
    /// following or not) and every record (following, home floor). Reads only.
    static var diagSummary: String {
        let live = members.map { m in
            "\(m.memberID):\(m.isFollowing ? "following" : "staying")@\(String(format: "%.2f,%.2f", m.groundPosition.x, m.groundPosition.y))"
        }
        let recorded = records.keys.sorted().map { id -> String in
            let r = records[id]!
            return "\(id).record:\(r.following ? "following" : "not-following"),met=\(r.met),home=F\(r.homeFloor.map(String.init) ?? "?")"
        }
        let all = live + recorded
        return all.isEmpty ? "none" : all.joined(separator: ";")
    }

    static func recruit(_ member: PosseMember) {
        member.startFollowing()
        var record = records[member.memberID] ?? Record()
        record.following = true
        record.met = true
        records[member.memberID] = record
        diag("posse.follow", ["member": member.memberID, "floor": floor])
        Cast.log("\(member.memberID) -> hanging (recruited, floor \(floor))")
    }

    static func release(_ member: PosseMember) {
        member.stayHere()
        var record = records[member.memberID] ?? Record()
        record.following = false
        record.homeFloor = floor
        record.home = member.groundPosition
        records[member.memberID] = record
        diag("posse.stay", ["member": member.memberID, "floor": floor])
        Cast.log("\(member.memberID) -> independent (stays, floor \(floor))")
    }

    /// Oct 6 ([Cast] summary): where this member is, in one phrase.
    static func castSummary(_ id: String, floor: Int) -> String {
        let here = members.contains { $0.memberID == id }
        guard let record = records[id] else { return here ? "present (not met)" : "absent" }
        if record.following { return here ? "hanging (here)" : "hanging (not here)" }
        if !record.met { return here ? "waiting to be met (here)" : "absent" }
        return here ? "independent (here)" : "independent (home floor \(record.homeFloor.map(String.init) ?? "?"))"
    }

    /// Is this node part of a member who is following right now?
    static func isFollowerNode(_ node: SCNNode) -> Bool {
        let following = members.filter { $0.isFollowing }
        guard !following.isEmpty else { return false }
        var candidate: SCNNode? = node
        while let n = candidate {
            if following.contains(where: { $0.sceneNode === n }) { return true }
            candidate = n.parent
        }
        return false
    }

    /// A scene tap's hit list with following members removed (see above).
    static func navigationHits(_ hits: [SCNHitTestResult]) -> [SCNHitTestResult] {
        guard members.contains(where: { $0.isFollowing }) else { return hits }
        return hits.filter { !isFollowerNode($0.node) }
    }

    /// Scene tap: did it land on a posse member? If so, engage it and consume
    /// the tap (true). The nearest thing under the finger decides -- a wall in
    /// front of the member wins -- except Noodle, who is looked through.
    static func handleTap(in view: SCNView, at point: CGPoint) -> Bool {
        guard !members.isEmpty else { return false }
        let hits = view.hitTest(point, options: [
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.ignoreHiddenNodes: true,
            SCNHitTestOption.backFaceCulling: false
        ])
        for hit in hits {
            // The same invisible helpers the tap-walk's own hit test looks past.
            if hit.node.name == "decoratorHitProxy" || hit.node.name == "hangingPickupString" { continue }
            var node: SCNNode? = hit.node
            var owner: PosseMember?
            var isNoodle = false
            while let n = node {
                if CritterTags.id(of: n) == .jeff { isNoodle = true; break }      // Oct 6: by identity, not name
                if let m = members.first(where: { $0.sceneNode === n }) { owner = m; break }
                node = n.parent
            }
            if isNoodle { continue }
            guard let member = owner else { return false }    // something else is in front
            // Oct 4 (second audition): a FOLLOWING member is transparent to taps
            // -- he is part of the travelling group, not a dead patch of the
            // navigation surface -- so look past him. (No release for now.)
            if member.isFollowing { continue }
            recruit(member)
            diag("posse.tap", ["member": member.memberID, "action": "follow"])
            return true
        }
        return false
    }
}

// MARK: - Reusable follow logic (render thread)

nonisolated final class FollowLeash: @unchecked Sendable {
    /// Probes see walls, doors and furniture -- not creatures, Noodle or the cage's glass.
    static let probeMask = ~(CritterCategory.storyCritters | Menagerie.categoryBit | Bobbin.categoryBit | Cage.panelBit)

    // Where the follower likes to be, relative to the player (metres).
    // Oct 4 follow-up: the old 0.95 ahead / 0.7 aside sat under and outside
    // the portrait companion camera's frame (it sees the floor only from
    // ~1.3 m out and ~0.27 m of width per metre). This sits him just behind
    // and beside Noodle, in plain view.
    var slotAhead: Float = 1.55
    var slotSide: Float = 0.38
    /// Off the grid (the elevator cab): in front of the player, to one side.
    var cabAhead: Float = 1.1
    var cabSide: Float = 0.6

    private weak var playerCamera: SCNNode?
    private weak var root: SCNNode?
    private let cellKeys: Set<Int>
    private let cellSize: Float
    private var side: Float = 1
    private(set) var trail: [SIMD2<Float>] = []
    private var lastPlayer: SIMD2<Float>?
    private var playerVelocity = SIMD2<Float>(0, 0)
    private var checkClock: Double = 0
    private enum SlotKind { case side, behind, player }
    private var slotKind = SlotKind.side
    private var routeDirect = true
    private var target: SIMD2<Float>?
    /// Oct 8 flight recorder: who this leash belongs to ("freddy"), and the
    /// last decisions recorded -- only CHANGES are written, never per frame.
    var diagLabel = "follower"
    private var diagLastDirect: Bool?
    private var diagLastSlot: SlotKind?
    private var diagClock: Double = 0
    private var diagLastRouteLog: Double = -10
    private var diagLastSlotLog: Double = -10
    private static func diagPoint(_ p: SIMD2<Float>) -> String { String(format: "%.2f,%.2f", p.x, p.y) }

    struct Reading {
        let player: SIMD2<Float>
        let playerForward: SIMD2<Float>
        let onGrid: Bool
        let target: SIMD2<Float>
        /// True when the target is the slot itself (it moves with the player).
        let direct: Bool
        /// The player's ground velocity (smoothed), for keeping pace.
        let playerVelocity: SIMD2<Float>
        /// Set when the follower is hopelessly cut off: put it here instead.
        let reposition: SIMD2<Float>?
    }

    init(playerCamera: SCNNode, root: SCNNode, cells: Set<GridCoordinate>, cellSize: Float) {
        self.playerCamera = playerCamera
        self.root = root
        self.cellKeys = Set(cells.map { TinCanRatDriver.cellKey(row: $0.row, col: $0.col) })
        self.cellSize = cellSize
    }

    func playerGround() -> (pos: SIMD2<Float>, forward: SIMD2<Float>)? {
        guard let camera = playerCamera else { return nil }
        let eye = camera.presentation.worldPosition
        let yaw = camera.presentation.eulerAngles.y
        return (SIMD2<Float>(eye.x, eye.z), SIMD2<Float>(-sin(yaw), -cos(yaw)))
    }

    func onGrid(_ p: SIMD2<Float>) -> Bool {
        cellKeys.contains(TinCanRatDriver.cellKey(row: Int((p.y / cellSize).rounded()), col: Int((p.x / cellSize).rounded())))
    }

    /// Clear floor-level line between two points?
    func clear(_ a: SIMD2<Float>, _ b: SIMD2<Float>, height: Float = 0.3) -> Bool {
        guard let root, simd_distance(a, b) > 0.01 else { return true }
        let hits = root.hitTestWithSegment(from: SCNVector3(a.x, height, a.y), to: SCNVector3(b.x, height, b.y), options: [
            SCNHitTestOption.categoryBitMask.rawValue: Self.probeMask,
            SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.any.rawValue,
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: false
        ])
        return hits.isEmpty
    }

    /// A step from `a` toward `b`, stopped short of anything solid (`radius` clearance).
    func safeStep(from a: SIMD2<Float>, to b: SIMD2<Float>, radius: Float) -> SIMD2<Float> {
        let d = b - a
        let length = simd_length(d)
        guard length > 0.0005, let root else { return b }
        let dir = d / length
        let probeEnd = b + dir * radius
        let hits = root.hitTestWithSegment(from: SCNVector3(a.x, 0.2, a.y), to: SCNVector3(probeEnd.x, 0.2, probeEnd.y), options: [
            SCNHitTestOption.categoryBitMask.rawValue: Self.probeMask,
            SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue,
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: false
        ])
        guard let hit = hits.first else { return b }
        let p = hit.worldCoordinates
        let reach = simd_length(SIMD2<Float>(p.x, p.z) - a) - radius
        return a + dir * max(0, min(length, reach))
    }

    /// Forget the old floor's trail (after a reposition).
    func reset() { trail = []; lastPlayer = nil; target = nil; checkClock = 0 }

    func update(follower pos: SIMD2<Float>, dt: Double) -> Reading? {
        guard let ground = playerGround() else { return nil }
        diagClock += dt
        let player = ground.pos, forward = ground.forward
        let right = SIMD2<Float>(-forward.y, forward.x)   // forward turned 90 degrees clockwise
        // Breadcrumbs of where the player has actually been.
        if let last = lastPlayer, simd_distance(last, player) > 3 {           // a jump (elevator, reset)
            trail = []
            diag("follow.trailReset", ["who": diagLabel, "jump": simd_distance(last, player), "player": Self.diagPoint(player)])
        }
        if let last = lastPlayer, dt > 0, simd_distance(last, player) <= 3 {
            playerVelocity += ((player - last) / Float(dt) - playerVelocity) * min(1, Float(dt) * 10)
        } else {
            playerVelocity = .zero
        }
        lastPlayer = player
        if trail.isEmpty || simd_distance(trail[trail.count - 1], player) > 0.3 {
            trail.append(player)
            if trail.count > 80 { trail.removeFirst(trail.count - 80) }
        }
        let grid = onGrid(player)
        func slotFor(_ s: Float) -> SIMD2<Float> {
            grid ? player + forward * slotAhead + right * s * slotSide
                 : player + forward * cabAhead + right * s * cabSide
        }
        let behind = player - forward * 0.8
        func slotPosition() -> SIMD2<Float> {
            switch slotKind {
            case .side: return slotFor(side)
            case .behind: return behind
            case .player: return player
            }
        }
        checkClock -= dt
        var reposition: SIMD2<Float>?
        if checkClock <= 0 || target == nil {
            checkClock = 0.12
            // The slot: this side, else the other side, else just behind, else the player's spot.
            if clear(player, slotFor(side)) { slotKind = .side }
            else if clear(player, slotFor(-side)) { side = -side; slotKind = .side }
            else if clear(player, behind) { slotKind = .behind }
            else { slotKind = .player }
            let slot = slotPosition()
            // The route: straight to the slot if it can see it, else the most
            // recent breadcrumb it can see (the way we came round the corner).
            if clear(pos, slot) {
                routeDirect = true
                target = slot
            } else {
                routeDirect = false
                var found: SIMD2<Float>?
                var i = trail.count - 1
                var tries = 0
                while i >= 0, tries < 8 {
                    if clear(pos, trail[i]) { found = trail[i]; break }
                    i -= 3; tries += 1
                }
                target = found ?? target ?? slot
                // Hopelessly cut off, or far behind: pop onto the trail behind the player.
                if (found == nil && simd_distance(pos, player) > 4.5) || simd_distance(pos, player) > 9 {
                    let back = trail.count >= 5 ? trail[trail.count - 5] : behind
                    reposition = clear(player, back) ? back : player
                    diag("follow.reposition", ["who": diagLabel, "from": Self.diagPoint(pos),
                                               "to": Self.diagPoint(reposition ?? player), "player": Self.diagPoint(player),
                                               "distance": simd_distance(pos, player), "trailVisible": found != nil])
                }
            }
            // Route/slot changes: at most one line per half-second each (they
            // can flicker while rounding a corner).
            if diagLastDirect != routeDirect, diagClock - diagLastRouteLog >= 0.5 {
                diagLastDirect = routeDirect
                diagLastRouteLog = diagClock
                diag("follow.route", ["who": diagLabel, "direct": routeDirect, "follower": Self.diagPoint(pos),
                                      "player": Self.diagPoint(player), "onGrid": grid])
            }
            if diagLastSlot != slotKind, diagClock - diagLastSlotLog >= 0.5 {
                diagLastSlot = slotKind
                diagLastSlotLog = diagClock
                diag("follow.slot", ["who": diagLabel, "slot": "\(slotKind)"])
            }
        } else if routeDirect {
            // Between checks the slot keeps riding along with the player.
            target = slotPosition()
        }
        return Reading(player: player, playerForward: forward, onGrid: grid, target: target ?? slotPosition(),
                       direct: routeDirect, playerVelocity: playerVelocity, reposition: reposition)
    }
}
