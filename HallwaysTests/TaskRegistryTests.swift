import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 20 -- THE TASK REGISTRY and CRITTER-GUIDED DESTINATIONS: twenty tasks
/// (Floor 5's fuse box, nineteen placeholders spread over the building on real
/// walkable cells), saved and reset with the game; a tapped critter gets one,
/// goes there by its own journey (the car between floors), and arriving ends
/// the guiding -- never the task by itself. No scene; a small made-up building.
@MainActor
struct TaskRegistryTests {
    // MARK: A small building: floors 1-8, each a 10x10 block with its elevator at (5,0);
    // Floor 5 is 18x20 so it has the fuse box's cell (4,12); a table at (2,2) on every floor.

    private func plan(_ f: Int, rows: Int = 10, cols: Int = 10, panel: Bool = true) -> FloorPlan {
        var cells = Set<GridCoordinate>()
        for r in 0..<rows { for c in 0..<cols { cells.insert(GridCoordinate(row: r, col: c)) } }
        if !panel { cells.remove(FloorFiveBlackout.panelCell) }
        return FloorPlan(floor: f, cells: cells, doors: [:], bathroomDoors: [:], elevator: GridCoordinate(row: 5, col: 0),
                         furnished: [GridCoordinate(row: 2, col: 2)], cellSize: 3.52)
    }
    private func building(panel: Bool = true) -> (Int) -> FloorPlan? {
        { f in
            guard (1...8).contains(f) else { return nil }
            return f == 5 ? self.plan(5, rows: 18, cols: 20, panel: panel) : self.plan(f)
        }
    }

    // MARK: The twenty

    @Test func twentyTasksTheFuseBoxAndNineteenSpreadOverTheBuilding() throws {
        let plans = building()
        let tasks = TaskRegistry.generate(plans: plans, floors: 1...40, seed: 42)
        #expect(tasks.count == 20)
        #expect(Set(tasks.map(\.id)).count == 20)
        #expect(tasks.map(\.id) == (1...20).map { String(format: "task.%02d", $0) })
        // Task 1: the real fuse box -- Floor 5, the panel's own (approach) cell.
        let fuse = try #require(tasks.first)
        #expect(fuse.id == TaskRegistry.fuseBoxID && fuse.kind == .fuseBox)
        #expect(fuse.floor == 5 && fuse.cell == FloorFiveBlackout.panelCell)
        // The nineteen: real cells, never the lobby or Administration, the elevator, furniture;
        // distinct; on several floors; apart from each other on a floor; all reachable.
        let placeholders = tasks.filter { $0.kind == .placeholder }
        #expect(placeholders.count == 19)
        #expect(Set(placeholders.map { "\($0.floor):\($0.cell.row),\($0.cell.col)" }).count == 19)
        #expect(Set(placeholders.map(\.floor)).count >= 4)
        for t in placeholders {
            let p = try #require(plans(t.floor))
            #expect(t.floor != 1 && t.floor != 2, "\(t.id) on an onboarding floor")
            #expect(p.cells.contains(t.cell) && !p.furnished.contains(t.cell) && t.cell != p.elevator)
            #expect(TaskRegistry.walk(p, from: p.elevator!, to: t.cell) != nil)
            #expect(!(t.floor == 5 && t.cell == FloorFiveBlackout.panelCell))
            for o in placeholders where o.id != t.id && o.floor == t.floor {
                #expect(abs(o.cell.row - t.cell.row) + abs(o.cell.col - t.cell.col) >= TaskRegistry.minSpacing)
            }
        }
        // The same seed, the same set; another seed, another set.
        #expect(TaskRegistry.generate(plans: plans, floors: 1...40, seed: 42) == tasks)
        #expect(TaskRegistry.generate(plans: plans, floors: 1...40, seed: 7) != tasks)
    }

    @Test func noFuseBoxTaskWhenTheBuildingHasNoSuchCell() {
        let tasks = TaskRegistry.generate(plans: building(panel: false), floors: 1...40, seed: 3)
        #expect(!tasks.contains { $0.kind == .fuseBox })
        #expect(tasks.filter { $0.kind == .placeholder }.count == 19)
    }

    // MARK: Saved with the game; Start Over makes a fresh set

    @Test func savedOnceKeptOnResumeFreshAfterStartOver() throws {
        let storage = ThrowawayStorage()
        let first = TaskRegistry(defaults: storage.defaults, persists: true)
        first.ensureGenerated(plans: building(), seed: 11)
        let made = first.all
        #expect(made.count == 20)
        first.ensureGenerated(plans: building(), seed: 99)                  // (generated once: never again)
        #expect(first.all == made)
        #expect(first.assign("task.05"))
        // Resume: the same twenty -- and an assignment never outlives a launch.
        let resumed = TaskRegistry(defaults: storage.defaults, persists: true)
        resumed.ensureGenerated(plans: building(), seed: 12)
        #expect(resumed.all.map(\.cell) == made.map(\.cell))
        #expect(resumed.state(of: try #require(resumed.task("task.05"))) == .available)
        // Start Over: gone, then a fresh set with the next floor built.
        resumed.reset()
        #expect(resumed.all.isEmpty)
        #expect(storage.defaults.data(forKey: TaskRegistry.storageKey) == nil)
        resumed.ensureGenerated(plans: building(), seed: 13)
        #expect(resumed.all.count == 20)
        #expect(resumed.all.filter { $0.kind == .placeholder }.map(\.cell) != made.filter { $0.kind == .placeholder }.map(\.cell))
        #expect(ResumeState.allKeys.contains(TaskRegistry.storageKey))     // (Start Over clears it)
    }

    // MARK: The fuse box is the breakers' to complete

    @Test func theFuseBoxIsCompletedOnlyByTheBreakers() throws {
        let storage = ThrowawayStorage()
        let reg = TaskRegistry(defaults: storage.defaults, persists: false)
        var allOn = false
        reg.fuseBoxDone = { allOn }
        reg.ensureGenerated(plans: building(), seed: 5)
        let fuse = try #require(reg.task(TaskRegistry.fuseBoxID))
        #expect(reg.state(of: fuse) == .available)
        // Led there and arrived: still available (arriving isn't completing).
        #expect(reg.assign(fuse.id))
        #expect(reg.state(of: try #require(reg.task(fuse.id))) == .assigned)
        #expect(reg.unassign(fuse.id) == .available)
        // Every breaker on: completed -- never offered again.
        allOn = true
        #expect(reg.state(of: fuse) == .completed)
        #expect(!reg.available().contains { $0.id == fuse.id })
        #expect(!reg.assign(fuse.id))
    }

    // MARK: Choosing

    @Test func choosingIsRandomAndKeptApart() {
        let tasks = TaskRegistry.generate(plans: building(), floors: 1...40, seed: 21)
        #expect(TaskSelector.choose(from: [], roll: 0.5) == nil)
        #expect(TaskSelector.choose(from: tasks, roll: 0)?.id == "task.01")
        #expect(TaskSelector.choose(from: tasks, roll: 0.999)?.id == "task.20")
        #expect(TaskSelector.choose(from: tasks, roll: 0.5) != nil)
    }

    @Test func onlyTasksThePlayerCanBeLedTo() {
        let plans = building()
        let up = BuildingTask(id: "t", kind: .placeholder, floor: 7, cell: GridCoordinate(row: 3, col: 3))
        // Same floor: always. Another floor: the guide must ride, and the player's card must open it.
        #expect(TaskGuide.reachable(up, from: 7, canRide: false, hasEmployeeID: false, plans: plans))
        #expect(TaskGuide.reachable(up, from: 4, canRide: true, hasEmployeeID: true, plans: plans))
        #expect(!TaskGuide.reachable(up, from: 4, canRide: false, hasEmployeeID: true, plans: plans))
        #expect(!TaskGuide.reachable(up, from: 1, canRide: true, hasEmployeeID: false, plans: plans))   // (no ID: not past Floor 2)
        let gone = BuildingTask(id: "g", kind: .placeholder, floor: 30, cell: GridCoordinate(row: 1, col: 1))
        #expect(!TaskGuide.reachable(gone, from: 4, canRide: true, hasEmployeeID: true, plans: plans))
    }

    // MARK: The journey there: its own walk, or the car

    @Test func theGuidesJourneyIsARealOne() throws {
        let plans = building()
        let style = RoamStyle(floors: [3: 1], stay: 30...60, speed: 1, changeFloorChance: 0)
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var r = Resident(id: "hw.feddy", kind: "hallwaysian.hw.feddy", floor: 3, cell: GridCoordinate(row: 8, col: 8), since: t0, dwell: 60)
        // Same floor: a walk, there when it has walked it.
        var same = r
        #expect(Roam.send(&same, to: ResidentPlace(floor: 3, cell: GridCoordinate(row: 1, col: 8)), from: GridCoordinate(row: 8, col: 8),
                          style: style, abilities: [.walk, .rideElevator], plans: plans, at: t0, stay: 20, why: "test"))
        #expect(same.floor == 3 && same.cell == GridCoordinate(row: 1, col: 8))
        #expect(same.leg?.changesFloor == false && same.since > t0)
        // Another floor: to the doors, the car, then out -- no arrival time until it has ridden.
        #expect(Roam.send(&r, to: ResidentPlace(floor: 7, cell: GridCoordinate(row: 3, col: 6)), from: GridCoordinate(row: 8, col: 8),
                          style: style, abilities: [.walk, .rideElevator], plans: plans, at: t0, stay: 20, why: "test"))
        let leg = try #require(r.leg)
        #expect(leg.lift == .toDoors && leg.from.floor == 3 && r.floor == 7 && r.since == .distantFuture)
        // It can't ride: no journey between floors (record untouched).
        var walker = Resident(id: "x", kind: "x", floor: 3, cell: GridCoordinate(row: 8, col: 8), since: t0, dwell: 60)
        #expect(!Roam.send(&walker, to: ResidentPlace(floor: 7, cell: GridCoordinate(row: 3, col: 6)), from: GridCoordinate(row: 8, col: 8),
                           style: style, abilities: [.walk], plans: plans, at: t0, stay: 20, why: "test"))
        #expect(walker.floor == 3 && walker.leg == nil)
    }

    // MARK: Assign, arrive, switch -- the guiding ends; the task stays

    /// A body on the player's floor that leads the way by its record (Roam.send).
    @MainActor private final class Guide: ResidentPresentation {
        let residentID: String
        let life: BuildingLife
        var released: [Bool] = []
        init(_ id: String, life: BuildingLife) { residentID = id; self.life = life }
        var holdsResident: Bool { true }
        var isRendered: Bool { true }
        var isGuiding: Bool { false }
        var canGuide: Bool { true }
        var bodyPosition: SIMD2<Float>? { SIMD2<Float>(8 * 3.52, 8 * 3.52) }      // (cell 8,8)
        func tick(now: Date) {}
        func teardown() {}
        func playerBoarding() -> Bool { false }
        func arrivalDoorsOpening() {}
        func guide(to place: ResidentPlace, why: String) -> Bool {
            guard var r = life.resident(residentID) else { return false }
            let style = RoamStyle(floors: [3: 1], stay: 30...60, speed: 1, changeFloorChance: 0)
            guard Roam.send(&r, to: place, from: GridCoordinate(row: 8, col: 8), style: style, abilities: [.walk, .rideElevator],
                            plans: life.plans, at: BuildingClock.now(), stay: 20, why: why) else { return false }
            life.store(r)
            return true
        }
        func releaseGuide(resumeRoaming: Bool) { released.append(resumeRoaming) }
    }

    private func world(_ storage: ThrowawayStorage) -> (BuildingLife, TaskRegistry) {
        let life = BuildingLife(defaults: storage.defaults, persists: false, kinds: [RoamingChairKind()])
        life.plans = building()
        _ = life.residentIDs
        let reg = TaskRegistry(defaults: storage.defaults, persists: false)
        reg.fuseBoxDone = { false }
        return (life, reg)
    }

    @Test func aTappedCritterGetsATaskLeadsThereAndTheTaskStays() throws {
        let storage = ThrowawayStorage()
        let (life, reg) = world(storage)
        defer { TaskGuide.clear() }
        let id = RoamingChairKind.id
        life.store(Resident(id: id, kind: "roamingChair", floor: 3, cell: GridCoordinate(row: 8, col: 8), since: .distantPast, dwell: 60))
        let guide = Guide(id, life: life)
        life.presentations = [guide]
        #expect(TaskGuide.assign(guide: id, floor: 3, life: life, registry: reg, roll: 0.37, hasEmployeeID: true))
        let c = try #require(TaskGuide.current)
        #expect(c.guide == id)
        let task = try #require(reg.task(c.task))
        #expect(reg.state(of: task) == .assigned)
        let r = try #require(life.resident(id))
        #expect(r.floor == task.floor && r.cell == task.cell)                      // (on its way there)
        // Not there yet: nothing ends.
        #expect(!TaskGuide.check(now: BuildingClock.now(), life: life, registry: reg))
        #expect(TaskGuide.current != nil)
        // There: the guiding ends -- the task is available again (a placeholder has nothing to complete).
        var there = r
        there.leg = nil
        there.since = BuildingClock.now().addingTimeInterval(-1)
        there.cell = GridCoordinate(row: task.cell.row, col: task.cell.col == 0 ? 1 : task.cell.col - 1)   // (a step to a thing in the room: still there)
        life.store(there)
        #expect(TaskGuide.check(now: BuildingClock.now(), life: life, registry: reg))
        #expect(TaskGuide.current == nil)
        #expect(reg.state(of: try #require(reg.task(task.id))) == .available)
        #expect(guide.released == [false])                                          // (arrived: it lingers, then its own life)
    }

    @Test func switchingReleasesTheFirstGuideOneGuideAtATime() throws {
        let storage = ThrowawayStorage()
        let (life, reg) = world(storage)
        defer { TaskGuide.clear() }
        let a = RoamingChairKind.id, b = "chair.2"
        life.store(Resident(id: a, kind: "roamingChair", floor: 3, cell: GridCoordinate(row: 8, col: 8), since: .distantPast, dwell: 60))
        life.store(Resident(id: b, kind: "roamingChair", floor: 3, cell: GridCoordinate(row: 8, col: 8), since: .distantPast, dwell: 60))
        let ga = Guide(a, life: life), gb = Guide(b, life: life)
        life.presentations = [ga, gb]
        #expect(TaskGuide.assign(guide: a, floor: 3, life: life, registry: reg, roll: 0.1, hasEmployeeID: true))
        let first = try #require(TaskGuide.current?.task)
        #expect(TaskGuide.assign(guide: b, floor: 3, life: life, registry: reg, roll: 0.9, hasEmployeeID: true))
        #expect(TaskGuide.current?.guide == b)
        #expect(ga.released == [true])                                              // (released: back to its own life)
        #expect(reg.state(of: try #require(reg.task(first))) == .available)
        #expect(reg.available().count == 19)                                        // (only b's task is taken)
        // Stopped (a tap on it again): released, its task back.
        TaskGuide.release(b, outcome: .canceled, why: "test", life: life, registry: reg)
        #expect(TaskGuide.current == nil && gb.released == [true])
        #expect(reg.available().count == 20)
    }

    @Test func theButterflyIsFollowedButDoesntLead() {
        let storage = ThrowawayStorage()
        let (life, reg) = world(storage)
        defer { TaskGuide.clear() }
        final class Flier: ResidentPresentation {
            let residentID = "butterfly"
            var holdsResident: Bool { true }
            var isRendered: Bool { true }
            var isGuiding: Bool { false }
            func tick(now: Date) {}
            func teardown() {}
            func playerBoarding() -> Bool { false }
            func arrivalDoorsOpening() {}
        }
        life.store(Resident(id: "butterfly", kind: "roamingChair", floor: 3, cell: GridCoordinate(row: 8, col: 8), since: .distantPast, dwell: 60))
        life.presentations = [Flier()]
        #expect(!TaskGuide.assign(guide: "butterfly", floor: 3, life: life, registry: reg))
        #expect(TaskGuide.current == nil)
        #expect(reg.available().count == 20)
    }

    // MARK: Critter size

    @Test func roamingCrittersAreAFifthBigger() {
        #expect(HallwaysianResidentBody.sizeScale == 1.2)
        #expect(ChairResidentBody.sizeScale == 1.2)
        #expect(ResidentRoster.residentSizeScale == 1.2)
        let chair = ChairResidentBody()
        #expect(abs(chair.root.scale.x - 1.2) < 1e-6 && abs(chair.root.scale.y - 1.2) < 1e-6)
        chair.place(at: SIMD2<Float>(3, 4), heading: 1)                             // (placing and turning keep the size)
        #expect(abs(chair.root.scale.x - 1.2) < 1e-6)
    }

    @Test func aGuideWhoseJourneyWasReplacedHasFailed() throws {
        let storage = ThrowawayStorage()
        let (life, reg) = world(storage)
        defer { TaskGuide.clear() }
        let id = RoamingChairKind.id
        life.store(Resident(id: id, kind: "roamingChair", floor: 3, cell: GridCoordinate(row: 8, col: 8), since: .distantPast, dwell: 60))
        let guide = Guide(id, life: life)
        life.presentations = [guide]
        #expect(TaskGuide.assign(guide: id, floor: 3, life: life, registry: reg, roll: 0.5, hasEmployeeID: true))
        var r = try #require(life.resident(id))
        r.moves += 1                                                                // (a new decision of its own)
        life.store(r)
        #expect(!TaskGuide.check(now: BuildingClock.now(), life: life, registry: reg))
        #expect(TaskGuide.current == nil && guide.released == [true])
        #expect(reg.available().count == 20)
    }
}

