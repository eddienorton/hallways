//
//  CharacterLead.swift
//  Hallways
//
//  Oct 6 -- "PLAYER FOLLOWS CHARACTER" (prototype 1: Fredo through
//  Administration).
//
//  Hallways' third navigation relationship. A character owns a route,
//  goes ahead to the next place where the player could go wrong, stands
//  in the right branch looking back, and waits for the player to come
//  close before going on. It never moves the player or the camera, and
//  there is no UI: the character's position IS the direction.
//
//  Three small parts, deliberately not an NPC framework:
//
//  - CharacterLead.route / .plan: grid logic only. A shortest route over
//    the floor's cells, turned into steps -- travel legs, door openings,
//    and STOPS. A stop is made just past every door the route crosses and
//    a body-length into the branch at every real decision (a turn in a
//    cell with three or more ways out), plus the final stop.
//  - LeadPerformer: the character's body. How it travels, touches a door,
//    looks back, points the way, calls, urges, settles. Fredo's lives in
//    FredLead.swift.
//  - CharacterLead (the engine): runs the steps; at a stop it polls the
//    player's position (main thread, 0.15 s) and releases the stop when
//    the player comes within reach (or gets ahead of it). While waiting it
//    keeps watching the player, now and then points the way, now and then
//    calls, and ONCE per lead -- if the player hasn't come after a while --
//    comes round to stand in front of the player and urges, then goes back.
//
//  World coordinates throughout are the floor's: x = col * cellSize,
//  z = row * cellSize (SIMD2 = (x, z)).
//

import SceneKit
import simd

/// The character's body, as the lead engine sees it. All points are world
/// (x, z). Completions are called on the main thread.
protocol LeadPerformer: AnyObject {
    /// Where the character stands now (world x, z), or nil if it is gone.
    var groundPosition: SIMD2<Float>? { get }
    /// A one-shot gesture is playing (don't start another; don't re-face).
    var isGesturing: Bool { get }
    func travel(_ path: [SIMD2<Float>], then: @escaping () -> Void)
    /// Lunge to touch something at `point` (a door, a machine); `contact`
    /// fires at the touch, `then` when back in place.
    func touch(_ point: SIMD2<Float>, contact: @escaping () -> Void, then: @escaping () -> Void)
    /// Turn (smoothly) to keep the player in view.
    func watch(_ player: SIMD2<Float>)
    /// "That way": look along `onward`, then back at the player.
    func pointOnward(_ onward: SIMD2<Float>, player: SIMD2<Float>)
    /// The come-along call.
    func call()
    /// The one escalation flourish, in place, facing the player.
    func urge(player: SIMD2<Float>, onward: SIMD2<Float>?, then: @escaping () -> Void)
    /// Arrived at a stop: settle, facing the player.
    func arrive(player: SIMD2<Float>)
    /// The stop is released: a small "right, on we go".
    func depart()
    /// The lead is over.
    func settle(facing heading: Float?)
}

/// Lead events: the flight recorder AND the Debug console ("[Lead]").
func leadLog(_ event: String, _ fields: KeyValuePairs<String, Any?> = [:]) {
    diag(event, fields)
    navLog("[Lead] \(event) " + fields.map { "\($0.key)=\($0.value.map { "\($0)" } ?? "nil")" }.joined(separator: " "))
}

final class CharacterLead {
    struct Stop {
        var point: SIMD2<Float>
        /// The way he'll go next (unit), for "that way" glances.
        var onward: SIMD2<Float>?
        var isFinal = false
        /// Final pose heading (Noodle convention: yaw h faces (-sin h, -cos h)).
        var finalHeading: Float?
        /// Something to touch now and then while waiting (e.g. the kiosk).
        var touchTarget: SIMD2<Float>?
        /// Released when the player comes within this distance of the stop.
        var release: Float = 3.4
        /// A final stop that still waits for the player (then onFinalRelease).
        var waitsForPlayer = false
        var cell: GridCoordinate
        /// Oct 6: a pace stop on a long straight corridor -- only made at all
        /// if the player has fallen well behind (else he runs straight on).
        var isPace = false
    }

    enum Step {
        case travel([SIMD2<Float>])
        case door(anchor: GridCoordinate, contact: SIMD2<Float>)
        case stop(Stop)
        case run(() -> Void)
    }

    struct Context {
        var cells: Set<GridCoordinate>           // where the character may walk
        var doors: [GridCoordinate: Direction]   // room-entrance doors (anchor -> wall)
        var cellSize: Float
        /// Player's ground position (world x, z) and camera yaw.
        var playerPose: () -> (position: SIMD2<Float>, yaw: Float)?
        /// Can the door at this anchor be walked through right now?
        var isDoorOpen: (GridCoordinate) -> Bool
        /// Open the door for real (passable, closes behind the player as usual).
        var openDoor: (GridCoordinate) -> Void
    }

    // Feel.
    static let stopInset: Float = 1.3          // how far past a door / into a branch he waits
    static let doorStandOff: Float = 1.0       // where he stands to push a door (clear of the leaf's swing)
    static let escalateAfter: Double = 6
    static let callEvery: Double = 7
    static let pointEvery: Double = 3.3
    static let passClearance: Float = 0.8      // detour round the player closer than this
    static let detourOffset: Float = 0.95

    let performer: LeadPerformer
    let context: Context
    private var steps: [Step]
    private var index = 0
    private var waiting: (stop: Stop, since: CFTimeInterval, lastCall: CFTimeInterval, lastPoint: CFTimeInterval)?
    private var escalated = false
    private var busy = false
    private var finished = false
    private var timer: Timer?
    private var lastLookBack: CFTimeInterval = 0
    private var settledHeading: Float?
    var onFinish: (() -> Void)?
    var onFinalRelease: (() -> Void)?
    var name = "lead"

    init(performer: LeadPerformer, context: Context, steps: [Step]) {
        self.performer = performer
        self.context = context
        self.steps = steps
    }

    var isRunning: Bool { timer != nil && !finished }

    func start() {
        guard timer == nil else { return }
        leadLog("lead.start", ["name": name, "steps": steps.count])
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                if let self { self.poll() } else { t.invalidate() }
            }
        }
        runStep()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        finished = true
    }

    // MARK: Steps

    private func runStep() {
        guard !finished else { return }
        guard index < steps.count else { return }
        let step = steps[index]
        switch step {
        case .travel(let path):
            busy = true
            let player = context.playerPose()?.position
            let route = player.map { detoured(path, around: $0) } ?? path
            performer.travel(route) { [weak self] in self?.advance() }
        case .door(let anchor, let contact):
            if context.isDoorOpen(anchor) { advance(); return }
            busy = true
            performer.touch(contact, contact: { [weak self] in
                self?.context.openDoor(anchor)
                leadLog("lead.doorOpened", ["row": anchor.row, "col": anchor.col])
            }, then: { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.advance() }
            })
        case .stop(let stop):
            busy = false
            let now = CACurrentMediaTime()
            let player = context.playerPose()?.position ?? stop.point
            // A pace stop the player is already keeping up with: don't stop.
            if stop.isPace, simd_distance(player, stop.point) < stop.release {
                index += 1
                runStep()
                return
            }
            performer.arrive(player: player)
            if stop.isFinal && !stop.waitsForPlayer {
                finish(stop)
                return
            }
            // A thing to touch (the kiosk) is touched soon after arriving.
            waiting = (stop, now, now, stop.touchTarget != nil ? now - Self.pointEvery + 1.4 : now)
            // Call on arrival when the player is not already on his heels.
            if simd_distance(player, stop.point) > stop.release + 1 || stop.isFinal {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self, self.waiting != nil, !self.performer.isGesturing else { return }
                    self.performer.call()
                    self.waiting?.lastCall = CACurrentMediaTime()
                }
            }
            leadLog("lead.waiting", ["name": name, "row": stop.cell.row, "col": stop.cell.col, "final": stop.isFinal])
        case .run(let block):
            block()
            advance()
        }
    }

    private func advance() {
        busy = false
        index += 1
        runStep()
    }

    private func finish(_ stop: Stop) {
        settledHeading = stop.finalHeading
        lastLookBack = CACurrentMediaTime()
        performer.settle(facing: stop.finalHeading)
        waiting = nil
        finished = true
        leadLog("lead.finished", ["name": name])
        onFinish?()
        // Keep polling: a settled character still glances back now and then.
    }

    // MARK: Polling (main thread)

    private func poll() {
        guard let me = performer.groundPosition else { cancel(); return }
        guard let pose = context.playerPose() else { return }
        let now = CACurrentMediaTime()
        if finished {
            // Waiting naturally: now and then a look back at the player, then
            // back to facing where he brought you.
            if now - lastLookBack > 6.5, !performer.isGesturing {
                lastLookBack = now
                performer.watch(pose.position)
                let heading = settledHeading
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                    guard let self, self.timer != nil else { return }
                    self.performer.settle(facing: heading)
                }
            }
            _ = me
            return
        }
        guard !busy, let w = waiting else { return }
        let stop = w.stop
        // Released: the player has come close -- or is already further along.
        let near = simd_distance(pose.position, stop.point) < stop.release
            || (stop.isFinal && simd_distance(pose.position, me) < stop.release)
        let ahead = nextStopPoint().map { simd_distance(pose.position, $0) + 0.5 < simd_distance(me, $0) } ?? false
        if near || ahead {
            waiting = nil
            leadLog("lead.released", ["name": name, "row": stop.cell.row, "col": stop.cell.col, "ahead": ahead])
            if stop.isFinal {
                finished = true
                onFinalRelease?()
                return
            }
            performer.depart()
            busy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.advance() }
            return
        }
        if performer.isGesturing { return }
        // One escalation per lead.
        if !escalated, now - w.since > Self.escalateAfter {
            escalated = true
            escalate(stop: stop, player: pose)
            return
        }
        if now - w.lastCall > Self.callEvery {
            waiting?.lastCall = now
            waiting?.lastPoint = now
            performer.call()
            return
        }
        if now - w.lastPoint > Self.pointEvery {
            waiting?.lastPoint = now
            if let target = stop.touchTarget {
                performer.touch(target, contact: {}, then: {})
            } else if let onward = stop.onward {
                performer.pointOnward(onward, player: pose.position)
            }
            return
        }
        performer.watch(pose.position)
    }

    private func nextStopPoint() -> SIMD2<Float>? {
        for step in steps[(index + 1)...] { if case .stop(let s) = step { return s.point } }
        return nil
    }

    // MARK: Escalation -- come round in front of the player, urge, go back

    private func escalate(stop: Stop, player: (position: SIMD2<Float>, yaw: Float)) {
        let forward = SIMD2<Float>(-sin(player.yaw), -cos(player.yaw))
        let playerCell = cell(of: player.position)
        var spot: SIMD2<Float>?
        var pathCells: [GridCoordinate] = []
        for distance: Float in [2.6, 2.2, 1.9] {
            let candidate = player.position + forward * distance
            let c = cell(of: candidate)
            guard context.cells.contains(c),
                  let path = Self.route(from: stop.cell, to: c, cells: context.cells, doors: context.doors,
                                        canCross: context.isDoorOpen) else { continue }
            // In front of the player must not mean behind a closed door from them.
            guard Self.route(from: playerCell, to: c, cells: context.cells, doors: context.doors,
                             canCross: context.isDoorOpen).map({ $0.count <= 2 }) ?? false else { continue }
            spot = candidate
            pathCells = path
            break
        }
        leadLog("lead.escalate", ["name": name, "comesRound": spot != nil])
        busy = true
        guard let spot else {
            performer.urge(player: player.position, onward: stop.onward) { [weak self] in
                guard let self else { return }
                self.busy = false
                let t = CACurrentMediaTime()
                self.waiting?.lastCall = t
                self.waiting?.lastPoint = t
            }
            return
        }
        let out = pathCells.dropFirst().dropLast().map { center($0) } + [spot]
        let back = pathCells.dropFirst().dropLast().reversed().map { center($0) } + [stop.point]
        performer.travel(detoured(Array(out), around: player.position)) { [weak self] in
            guard let self else { return }
            let now = self.context.playerPose()?.position ?? player.position
            self.performer.urge(player: now, onward: stop.onward) { [weak self] in
                guard let self else { return }
                let p = self.context.playerPose()?.position ?? now
                self.performer.travel(self.detoured(Array(back), around: p)) { [weak self] in
                    guard let self else { return }
                    self.busy = false
                    let t = CACurrentMediaTime()
                    self.waiting?.lastCall = t
                    self.waiting?.lastPoint = t - Self.pointEvery + 0.6
                    self.performer.arrive(player: self.context.playerPose()?.position ?? p)
                }
            }
        }
    }

    // MARK: Geometry

    func cell(of p: SIMD2<Float>) -> GridCoordinate {
        GridCoordinate(row: Int((p.y / context.cellSize).rounded()), col: Int((p.x / context.cellSize).rounded()))
    }

    func center(_ c: GridCoordinate) -> SIMD2<Float> {
        SIMD2<Float>(Float(c.col) * context.cellSize, Float(c.row) * context.cellSize)
    }

    /// Never run THROUGH the player: a leg passing closer than
    /// passClearance goes round them, on whichever side is open floor.
    private func detoured(_ path: [SIMD2<Float>], around player: SIMD2<Float>) -> [SIMD2<Float>] {
        guard var from = performer.groundPosition else { return path }
        var out: [SIMD2<Float>] = []
        for to in path {
            let d = to - from
            let len2 = simd_length_squared(d)
            if len2 > 0.0001 {
                let t = max(0, min(1, simd_dot(player - from, d) / len2))
                let closest = from + d * t
                if t > 0.02, t < 0.98, simd_distance(closest, player) < Self.passClearance {
                    let dir = d / len2.squareRoot()
                    let left = SIMD2<Float>(-dir.y, dir.x)
                    let a = player + left * Self.detourOffset, b = player - left * Self.detourOffset
                    let pick = context.cells.contains(cell(of: a)) ? a : (context.cells.contains(cell(of: b)) ? b : a)
                    out.append(pick)
                }
            }
            out.append(to)
            from = to
        }
        return out
    }

    // MARK: Planning (grid only)

    /// Shortest cell route (4-neighbour, both cells walkable). Ties prefer
    /// north, west, east, south. A door edge is crossable unless `canCross`
    /// says no.
    static func route(from a: GridCoordinate, to b: GridCoordinate, cells: Set<GridCoordinate>,
                      doors: [GridCoordinate: Direction], canCross: ((GridCoordinate) -> Bool)? = nil) -> [GridCoordinate]? {
        guard cells.contains(a), cells.contains(b) else { return nil }
        if a == b { return [a] }
        var parent: [GridCoordinate: GridCoordinate] = [a: a]
        var queue = [a]
        var head = 0
        while head < queue.count {
            let c = queue[head]; head += 1
            for d in [Direction.north, .west, .east, .south] {
                let n = GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
                guard cells.contains(n), parent[n] == nil else { continue }
                if let anchor = doorAnchor(c, d, doors), let canCross, !canCross(anchor) { continue }
                parent[n] = c
                if n == b {
                    var path = [b]
                    var p = c
                    while p != a { path.append(p); p = parent[p]! }
                    path.append(a)
                    return path.reversed()
                }
                queue.append(n)
            }
        }
        return nil
    }

    static func doorAnchor(_ c: GridCoordinate, _ d: Direction, _ doors: [GridCoordinate: Direction]) -> GridCoordinate? {
        if doors[c] == d { return c }
        let n = GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
        if doors[n] == d.opposite { return n }
        return nil
    }

    /// Turn a cell route into travel / door / stop steps. `final` describes
    /// the last stop (its point defaults to the last cell's centre).
    /// `decisionInset`: where a decision stop stands, measured from the
    /// edge into the chosen branch. The default (stopInset, past the edge)
    /// suits an open room (Administration). In corridors a NEGATIVE inset
    /// keeps him at the mouth of the branch, still inside the junction, so he
    /// is in view as you come up to it; `decisionRelease` then lets him go on
    /// only once you have really arrived.
    /// `paceEvery` (Oct 6): on a straight run, after this many cells without
    /// a stop, a pace stop at the next cell centre (released at 7 m: he only
    /// actually pauses and looks back when the player has fallen behind).
    static func plan(route cells: [GridCoordinate], context: Context, finalPoint: SIMD2<Float>? = nil,
                     finalHeading: Float? = nil, decisionInset: Float = stopInset,
                     decisionRelease: Float = 3.4, paceEvery: Int? = nil) -> [Step] {
        guard cells.count >= 2 else { return [] }
        let s = context.cellSize
        func center(_ c: GridCoordinate) -> SIMD2<Float> { SIMD2<Float>(Float(c.col) * s, Float(c.row) * s) }
        func dir(_ a: GridCoordinate, _ b: GridCoordinate) -> SIMD2<Float> {
            SIMD2<Float>(Float(b.col - a.col), Float(b.row - a.row))
        }
        func openWays(_ c: GridCoordinate) -> Int {
            Direction.allCases.filter { context.cells.contains(GridCoordinate(row: c.row + $0.delta.row, col: c.col + $0.delta.col)) }.count
        }
        var steps: [Step] = []
        var pending: [SIMD2<Float>] = []
        func flush() { if !pending.isEmpty { steps.append(.travel(pending)); pending = [] } }
        var stopInNext = false
        var sinceStop = 0
        for i in 1..<cells.count {
            let a = cells[i - 1], b = cells[i]
            let d = dir(a, b)
            let edge = (center(a) + center(b)) / 2
            let onward: SIMD2<Float>? = i + 1 < cells.count ? dir(b, cells[i + 1]) : nil
            if i > 1 {
                let previous = dir(cells[i - 2], a)
                if previous != d {
                    sinceStop = 0
                    if openWays(a) >= 3 { stopInNext = true } else { pending.append(center(a)) }
                }
            }
            sinceStop += 1
            let direction = Direction.allCases.first { $0.delta.row == b.row - a.row && $0.delta.col == b.col - a.col }
            if let direction, let anchor = doorAnchor(a, direction, context.doors) {
                pending.append(edge - d * doorStandOff)
                flush()
                steps.append(.door(anchor: anchor, contact: edge - d * 0.35))
                stopInNext = false
                sinceStop = 0
                if i == cells.count - 1 { break }             // the final stop follows
                let p = edge + d * stopInset
                pending.append(p)
                flush()
                steps.append(.stop(Stop(point: p, onward: onward ?? d, cell: b)))
                continue
            }
            if stopInNext, i < cells.count - 1 {
                stopInNext = false
                let p = edge + d * decisionInset
                pending.append(p)
                flush()
                steps.append(.stop(Stop(point: p, onward: d, release: decisionRelease, cell: decisionInset < 0 ? a : b)))
                sinceStop = 0
                continue
            }
            // A long straight run: a pace stop at b's centre, if the run goes
            // on at least two more cells the same way (never just before a turn).
            if let paceEvery, sinceStop >= paceEvery, i + 2 < cells.count,
               dir(b, cells[i + 1]) == d, dir(cells[i + 1], cells[i + 2]) == d {
                pending.append(center(b))
                flush()
                steps.append(.stop(Stop(point: center(b), onward: d, release: 7.0, cell: b, isPace: true)))
                sinceStop = 0
            }
        }
        let last = cells[cells.count - 1]
        let goal = finalPoint ?? center(last)
        pending.append(goal)
        flush()
        steps.append(.stop(Stop(point: goal, onward: nil, isFinal: true, finalHeading: finalHeading, cell: last)))
        return steps
    }
}
