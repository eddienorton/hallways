//
//  TaskRegistry.swift
//  Hallways
//
//  Oct 20 -- THE BUILDING'S TASKS, first registry: twenty places in the
//  building with something to do there, and the critters who take the player
//  to them. Deliberately small; the shape is meant to grow (more data per
//  task, dependencies, smarter choosing).
//
//  THE REGISTRY (TaskRegistry): each task has a stable id, a floor, a
//  destination cell on that floor's walkable plan, a state -- available,
//  assigned (a guide is leading the player there right now), completed -- and
//  a development label.
//
//    task.01  Floor 5's fuse box (Panel 5A). Its destination is the closet's
//             end cell, row 4 col 12 (FloorFiveBlackout.panelCell): the panel
//             hangs on that cell's north wall, facing south, and the walk-up a
//             panel tap makes stands in that same cell (1.5 m in front). It is
//             completed exactly when all eight breakers are on -- read from the
//             breakers' own saved state (floor5.circuits.v1), never a flag of
//             its own -- so with all of them on it is never offered.
//    task.02-20  Placeholder destinations: nineteen walkable cells spread over
//             the building's floors (never the lobby or Administration, never a
//             scripted room, an elevator cell, a doorway, furniture, or anywhere
//             the floor's own walk from its elevator can't reach). Chosen once,
//             saved with the game (tasks.registry.v1), kept on Resume, chosen
//             afresh after Start Over. No props, nothing to complete yet:
//             arriving is noted, and they stay available.
//
//  THE GUIDE (TaskGuide): tap a roaming critter (CritterFollow) -- it gets an
//  available task the player can reach (TaskSelector: at random, for now),
//  acknowledges the player, and goes there by its own life's journey (Roam.send:
//  its walk, and between floors the real car -- called, waited for, ridden).
//  The player follows with the follow walk. Arriving ends the GUIDING, never
//  the task by itself. One guide at a time: switching critters releases the
//  first, which goes back to its own life.
//

import Foundation

// MARK: - A task

struct BuildingTask: Codable, Equatable {
    enum Kind: String, Codable { case fuseBox, placeholder }
    enum State: String, Codable { case available, assigned, completed }

    let id: String
    let kind: Kind
    let floor: Int
    let cell: GridCoordinate
    /// For the developer (logs, the panel): "Floor 5 fuse box", "Placeholder 7".
    var label: String?
    /// As stored. (The fuse box's completion is read from the breakers: TaskRegistry.state(of:).)
    var state: State = .available
}

// MARK: - Choosing (kept apart: priorities and dependencies come later)

enum TaskSelector {
    /// One of `candidates`, at random (`roll` in 0..<1). nil: none.
    static func choose(from candidates: [BuildingTask], roll: Double = Double.random(in: 0..<1)) -> BuildingTask? {
        guard !candidates.isEmpty else { return nil }
        let sorted = candidates.sorted { $0.id < $1.id }
        return sorted[min(sorted.count - 1, Int(max(0, roll) * Double(sorted.count)))]
    }
}

// MARK: - The registry

final class TaskRegistry {
    nonisolated static let storageKey = "tasks.registry.v1"
    static let fuseBoxID = "task.01"
    static let placeholderCount = 19
    /// Placeholders keep this many cells (a walk) away from the elevator and from each other on a floor.
    static let minSpacing = 3

    static let shared = TaskRegistry(defaults: .standard, persists: !ResumeState.runningUnderTests)

    let defaults: UserDefaults
    let persists: Bool
    /// The breakers' own answer: all eight of Floor 5's circuits on (tests may stand in).
    var fuseBoxDone: () -> Bool = { FloorFiveBlackout.savedMask & 0xFF == 0xFF }
    private(set) var tasks: [BuildingTask] = []
    private var loaded = false

    init(defaults: UserDefaults, persists: Bool) {
        self.defaults = defaults
        self.persists = persists
    }

    // MARK: Load, generate, save

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard persists, let data = defaults.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([BuildingTask].self, from: data) else { return }
        // (an assignment never outlives a launch: nobody is guiding after a relaunch)
        tasks = saved.map { var t = $0; if t.state == .assigned { t.state = .available }; return t }
        TaskLog.line("registry.loaded", ["tasks": tasks.count, "floors": Set(tasks.map(\.floor)).sorted().map(String.init).joined(separator: ",")])
    }

    private func save() {
        guard persists, let data = try? JSONEncoder().encode(tasks) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// The twenty tasks exist (generated once, from the building's plans, then saved).
    func ensureGenerated(plans: (Int) -> FloorPlan?, floors: ClosedRange<Int> = 1...40, seed: UInt64? = nil) {
        loadIfNeeded()
        guard tasks.isEmpty else { return }
        let made = Self.generate(plans: plans, floors: floors, seed: seed ?? UInt64.random(in: 1...UInt64.max))
        guard !made.isEmpty else { return }                                  // (no plans yet: next time)
        tasks = made
        save()
        TaskLog.line("registry.generated", ["tasks": made.count,
                                            "fuseBox": made.first { $0.kind == .fuseBox }.map { "F\($0.floor) \(LifeLog.cell($0.cell))" } ?? "MISSING",
                                            "floors": Set(made.map(\.floor)).sorted().map(String.init).joined(separator: ",")])
        for t in made { TaskLog.line("registry.task", ["id": t.id, "floor": t.floor, "cell": LifeLog.cell(t.cell), "label": t.label]) }
    }

    /// Start Over: no tasks until the next floor is built (a fresh set then).
    func reset() {
        tasks = []
        loaded = true
        defaults.removeObject(forKey: Self.storageKey)
        TaskLog.line("registry.reset", [:])
    }

    // MARK: State

    func task(_ id: String) -> BuildingTask? { loadIfNeeded(); return tasks.first { $0.id == id } }
    var all: [BuildingTask] { loadIfNeeded(); return tasks }

    /// Its state now: the fuse box is completed when the breakers say so.
    func state(of t: BuildingTask) -> BuildingTask.State {
        if t.kind == .fuseBox, fuseBoxDone() { return .completed }
        return t.state
    }

    /// Tasks nobody is being led to and not completed.
    func available() -> [BuildingTask] { all.filter { state(of: $0) == .available } }

    /// A guide takes the player there now. False: it isn't available.
    @discardableResult
    func assign(_ id: String) -> Bool {
        loadIfNeeded()
        guard let i = tasks.firstIndex(where: { $0.id == id }), state(of: tasks[i]) == .available else { return false }
        tasks[i].state = .assigned
        save()
        return true
    }

    /// Its guide is done (arrived, cancelled, failed): available again -- unless
    /// it is completed (the fuse box with every breaker on). Returns its state now.
    @discardableResult
    func unassign(_ id: String) -> BuildingTask.State? {
        loadIfNeeded()
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        if tasks[i].state == .assigned { tasks[i].state = .available }
        save()
        return state(of: tasks[i])
    }

    // MARK: Generation (pure)

    /// Floor 5's fuse box approach: the panel's own cell (the closet's end, where
    /// a panel tap's walk-up stands) -- if this building's Floor 5 has it walkable
    /// and reachable from its elevator. nil (said so): no fuse-box task.
    static func fuseBoxCell(plan: FloorPlan?) -> GridCoordinate? {
        let cell = FloorFiveBlackout.panelCell
        guard let plan, let e = plan.elevator, plan.cells.contains(cell), walk(plan, from: e, to: cell) != nil else { return nil }
        return cell
    }

    /// Where a placeholder may be on `plan`: walkable, reachable from the elevator
    /// by the residents' own walk, not furniture, not a doorway, not a scripted
    /// room, not near the elevator, not the fuse box.
    static func placeholderCells(plan: FloorPlan) -> [GridCoordinate] {
        guard let e = plan.elevator else { return [] }
        let closed = plan.rooms.filter { ResidentPolicy.closedRooms.contains($0.id) }.reduce(into: Set<GridCoordinate>()) { $0.formUnion($1.cells) }
        return plan.cells.filter { c in
            !plan.furnished.contains(c) && !closed.contains(c)
                && !(plan.floor == FloorFiveBlackout.floor && c == FloorFiveBlackout.panelCell)
                && !Direction.allCases.contains(where: { plan.hasDoorway(c, $0) })
                && (walk(plan, from: e, to: c).map { $0.count - 1 >= minSpacing } ?? false)
        }.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
    }

    /// The floors placeholders may be on: with an elevator, open to residents
    /// (never the lobby or Administration -- onboarding's floors).
    static func placeholderFloors(plans: (Int) -> FloorPlan?, floors: ClosedRange<Int>) -> [FloorPlan] {
        floors.compactMap { f -> FloorPlan? in
            guard f != ResidentPolicy.lobbyFloor, !ResidentPolicy.closedFloors.contains(f),
                  let p = plans(f), p.elevator != nil, !p.cells.isEmpty else { return nil }
            return p
        }
    }

    /// The twenty: the fuse box (when this building has it) and nineteen
    /// placeholders, a floor at a time round the shuffled floors so they spread
    /// over the building, each its own cell, apart from the others on its floor.
    static func generate(plans: (Int) -> FloorPlan?, floors: ClosedRange<Int>, seed: UInt64) -> [BuildingTask] {
        var out: [BuildingTask] = []
        if let cell = fuseBoxCell(plan: plans(FloorFiveBlackout.floor)) {
            out.append(BuildingTask(id: fuseBoxID, kind: .fuseBox, floor: FloorFiveBlackout.floor, cell: cell,
                                    label: "Floor 5 fuse box (Panel 5A)"))
        } else {
            TaskLog.line("registry.fuseBoxMissing", ["why": "Floor 5's panel cell \(LifeLog.cell(FloorFiveBlackout.panelCell)) isn't walkable and reachable on this building's plan"])
        }
        var rng = Rand(seed: seed)
        var pools: [(floor: Int, cells: [GridCoordinate])] = placeholderFloors(plans: plans, floors: floors).map { p in
            var cells = placeholderCells(plan: p)
            for i in stride(from: cells.count - 1, to: 0, by: -1) {
                let j = Int(rng.unit() * Float(i + 1)) % (i + 1)
                cells.swapAt(i, j)
            }
            return (p.floor, cells)
        }.filter { !$0.cells.isEmpty }
        for i in stride(from: pools.count - 1, to: 0, by: -1) {
            let j = Int(rng.unit() * Float(i + 1)) % (i + 1)
            pools.swapAt(i, j)
        }
        var chosen: [Int: [GridCoordinate]] = [:]
        var made = 0
        var progress = true
        while made < placeholderCount, progress {
            progress = false
            for k in pools.indices where made < placeholderCount {
                let f = pools[k].floor
                // the first of this floor's (shuffled) cells far enough from its others
                guard let idx = pools[k].cells.firstIndex(where: { c in
                    (chosen[f] ?? []).allSatisfy { abs($0.row - c.row) + abs($0.col - c.col) >= minSpacing }
                }) else { continue }
                let cell = pools[k].cells.remove(at: idx)
                chosen[f, default: []].append(cell)
                made += 1
                progress = true
                let n = out.count + (out.first?.kind == .fuseBox ? 1 : 2)
                out.append(BuildingTask(id: String(format: "task.%02d", n), kind: .placeholder, floor: f, cell: cell,
                                        label: "Placeholder \(n) (F\(f) \(cell.row),\(cell.col))"))
            }
        }
        return out
    }

    /// The residents' walk on a plan (bathroom and window-room doors never crossed).
    static func walk(_ plan: FloorPlan, from a: GridCoordinate, to b: GridCoordinate) -> [GridCoordinate]? {
        let shut = plan.bathroomDoors.merging(plan.windowDoors) { a, _ in a }
        return CharacterLead.route(from: a, to: b, cells: plan.cells, doors: shut, canCross: { _ in false })
    }
}

// MARK: - The guide: a critter leading the player to a task

enum TaskGuide {
    enum Outcome: String { case arrived, canceled, failed }

    /// The one guide now: who, to which task, from which floor.
    private(set) static var current: (guide: String, task: String, fromFloor: Int)?
    /// The guide's journey count when it set off for the task (its record's `moves`):
    /// a new decision since means its journey there was replaced.
    private static var journey: Int?

    /// Can a guide on `floor` lead the player to `task` now? (pure but for the ID card)
    static func reachable(_ task: BuildingTask, from floor: Int, canRide: Bool, hasEmployeeID: Bool,
                          plans: (Int) -> FloorPlan?) -> Bool {
        guard let there = plans(task.floor), there.cells.contains(task.cell) else { return false }
        if task.floor == floor { return true }
        return canRide && ElevatorAccess.permits(task.floor, hasEmployeeID: hasEmployeeID)
            && plans(floor)?.elevator != nil && there.elevator != nil
    }

    /// The tasks `guide` (standing at `cell` on `floor`) could lead the player to,
    /// not right where it stands when there are others.
    static func candidates(registry: TaskRegistry, floor: Int, cell: GridCoordinate?, canRide: Bool, hasEmployeeID: Bool,
                           plans: (Int) -> FloorPlan?) -> [BuildingTask] {
        let ok = registry.available().filter { reachable($0, from: floor, canRide: canRide, hasEmployeeID: hasEmployeeID, plans: plans) }
        guard let cell else { return ok }
        let far = ok.filter { $0.floor != floor || abs($0.cell.row - cell.row) + abs($0.cell.col - cell.col) >= TaskRegistry.minSpacing }
        return far.isEmpty ? ok : far
    }

    /// The critter `id` was chosen to be followed: give it a task and send it
    /// there. True: it's guiding. False: following only (no task, said why).
    @discardableResult
    static func assign(guide id: String, floor: Int, life: BuildingLife = .shared, registry: TaskRegistry = .shared,
                       roll: Double = Double.random(in: 0..<1), hasEmployeeID: Bool? = nil) -> Bool {
        if let c = current { release(c.guide, outcome: .canceled, why: "another guide was chosen", life: life, registry: registry) }
        registry.ensureGenerated(plans: life.plans)
        guard let p = life.presentations.first(where: { $0.residentID == id }), let r = life.resident(id) else {
            TaskLog.line("guide.none", ["critter": id, "why": "no body here"])
            return false
        }
        guard p.canGuide else {
            TaskLog.line("guide.none", ["critter": id, "why": "it doesn't lead the way (followed only)"])
            return false
        }
        let canRide = life.kind(of: id)?.abilities.contains(.rideElevator) ?? false
        let here = p.bodyPosition.flatMap { at -> GridCoordinate? in
            guard let plan = life.plans(floor) else { return nil }
            return GridCoordinate(row: Int((at.y / plan.cellSize).rounded()), col: Int((at.x / plan.cellSize).rounded()))
        } ?? r.cell
        var options = candidates(registry: registry, floor: floor, cell: here, canRide: canRide, hasEmployeeID: hasEmployeeID ?? Admission.isCompleted,
                                 plans: life.plans)
        // (one it can't find a way to is dropped and another tried -- never a silent nothing;
        // a few refusals in a row is the guide itself, not the places: stop asking)
        var refusals = 0
        while refusals < 3, let task = TaskSelector.choose(from: options, roll: roll) {
            options.removeAll { $0.id == task.id }
            guard registry.assign(task.id) else { continue }
            let cross = task.floor != floor
            if p.guide(to: ResidentPlace(floor: task.floor, cell: task.cell), why: "guiding the player to \(task.id) (\(task.label ?? ""))") {
                current = (id, task.id, floor)
                journey = life.resident(id)?.moves
                TaskLog.line("guide.assigned", ["critter": id, "task": task.id, "label": task.label, "to": "F\(task.floor) \(LifeLog.cell(task.cell))",
                                                "from": "F\(floor) \(LifeLog.cell(here))", "crossFloor": cross])
                return true
            }
            registry.unassign(task.id)
            refusals += 1
            TaskLog.line("guide.unreachable", ["critter": id, "task": task.id, "to": "F\(task.floor) \(LifeLog.cell(task.cell))",
                                               "action": "another task tried"])
        }
        TaskLog.line("guide.none", ["critter": id, "why": registry.all.isEmpty ? "no tasks yet" : "no available task it can lead to from F\(floor)",
                                    "available": registry.available().count])
        return false
    }

    /// The guiding of `id` is over (nothing if it isn't the guide).
    static func release(_ id: String, outcome: Outcome, why: String, life: BuildingLife = .shared, registry: TaskRegistry = .shared) {
        guard let c = current, c.guide == id else { return }
        current = nil
        journey = nil
        let state = registry.unassign(c.task)
        TaskLog.line("guide.\(outcome.rawValue)", ["critter": id, "task": c.task, "why": why,
                                                   "task.state": state?.rawValue ?? "?",
                                                   "note": state == .completed ? "the task is COMPLETED" : "the task remains available"])
        life.presentations.first { $0.residentID == id }?.releaseGuide(resumeRoaming: outcome != .arrived)
    }

    /// While guiding (the follow tick): there yet? Its plans changed? True: it arrived just now.
    @discardableResult
    static func check(now: Date, life: BuildingLife = .shared, registry: TaskRegistry = .shared) -> Bool {
        guard let c = current else { return false }
        guard let task = registry.task(c.task), let r = life.resident(c.guide) else {
            release(c.guide, outcome: .failed, why: "the task or the critter is gone", life: life, registry: registry)
            return false
        }
        // (its cell may move a step once there -- up to a thing in the room -- so the
        // journey, not the cell, says whether it's still the one to the task)
        guard r.floor == task.floor, journey.map({ $0 == r.moves }) ?? (r.cell == task.cell) else {
            release(c.guide, outcome: .failed, why: "its journey changed (now F\(r.floor) \(LifeLog.cell(r.cell)))", life: life, registry: registry)
            return false
        }
        guard r.leg == nil, now >= r.since else { return false }
        release(c.guide, outcome: .arrived, why: "at F\(task.floor) \(LifeLog.cell(task.cell))", life: life, registry: registry)
        TaskLog.line("task.arrival", ["task": task.id, "label": task.label,
                                      "note": task.kind == .fuseBox ? "the fuse box: done when every breaker is on" : "placeholder: nothing to do here yet"])
        return true
    }

    /// Start Over / tests.
    static func clear() { current = nil; journey = nil }
}

// MARK: - Logs

enum TaskLog {
    /// One line: "[Tasks] guide.assigned critter=hw.feddy task=task.07 ..." (console and flight recorder).
    static func line(_ event: String, _ fields: KeyValuePairs<String, Any?>) {
        var s = "[Tasks] \(event)"
        for (k, v) in fields { s += " \(k)=\(v.map { "\($0)" } ?? "nil")" }
        navLog(s)
        diag("tasks.\(event)", ["detail": s])
    }
}
