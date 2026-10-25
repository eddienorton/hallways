import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 18 -- BUILDING LIFE: residents' records, the butterfly's migration,
/// offscreen life (her haunts; the chair's roaming) and its limits. Pure data:
/// no scene, no SceneKit, an injected clock, throwaway storage.
@MainActor
struct BuildingLifeTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Oct 18 (room-based life): a hall (row 10, cols 4-9, the elevator at 10,6)
    /// with two ROOMS off it, each behind a room-entrance door --
    ///   north room  (9,5) (8,5) (8,4)    door on the hall's (10,5), north wall
    ///   south room  (11,8) (12,8) (12,9) door on the hall's (10,8), south wall; (12,9) furnished
    /// -- and a bathroom (11,4) behind a bathroom door, which is no destination.
    static let northRoom: Set<GridCoordinate> = [GridCoordinate(row: 9, col: 5), GridCoordinate(row: 8, col: 5), GridCoordinate(row: 8, col: 4)]
    static let southRoom: Set<GridCoordinate> = [GridCoordinate(row: 11, col: 8), GridCoordinate(row: 12, col: 8), GridCoordinate(row: 12, col: 9)]
    private func plan(_ floor: Int) -> FloorPlan {
        var cells = Set<GridCoordinate>()
        for col in 4...9 { cells.insert(GridCoordinate(row: 10, col: col)) }
        cells.formUnion(Self.northRoom)
        cells.formUnion(Self.southRoom)
        cells.insert(GridCoordinate(row: 11, col: 4))                        // the bathroom
        return FloorPlan(floor: floor, cells: cells,
                         doors: [GridCoordinate(row: 10, col: 5): .north, GridCoordinate(row: 10, col: 8): .south],
                         bathroomDoors: [GridCoordinate(row: 10, col: 4): .south],
                         elevator: GridCoordinate(row: 10, col: 6), furnished: [GridCoordinate(row: 12, col: 9)], cellSize: 3.52)
    }
    private func plans(_ floor: Int) -> FloorPlan? { [3, 4].contains(floor) ? plan(floor) : nil }
    private let style = RoamStyle(floors: [3: 1, 4: 1], stay: 60...170, speed: 0.6, changeFloorChance: 0.35)

    // MARK: The butterfly's record

    @Test func theButterflysOldRecordIsCarriedOver() throws {
        let storage = ThrowawayStorage()
        let since = t0.timeIntervalSinceReferenceDate
        let old = """
        {"floor":4,"cell":{"row":10,"col":9},"haunt":2,"since":\(since),"dwell":180,"moves":7,
         "memory":{"engaged":true,"riding":false,"attempts":1,"lapses":2,"lastProgress":3}}
        """
        storage.defaults.set(Data(old.utf8), forKey: Butterfly.lifeKey)
        let life = BuildingLife(defaults: storage.defaults, persists: true, kinds: [ButterflyKind(), RoamingChairKind()])
        let her = try #require(life.resident(Butterfly.id))
        #expect(her.floor == 4)
        #expect(her.cell == GridCoordinate(row: 10, col: 9))
        #expect(her.haunt == 2)
        #expect(her.moves == 7)
        #expect(her.since == t0)
        #expect(her.dwell == 180)
        let memory = try #require(her.memories[Butterfly.concern.name])
        #expect(memory.engaged)
        #expect(memory.lapses == 2)
        #expect(memory.attempts == 1)
        #expect(memory.lastProgress == 3)
        // The chair moved in alongside her; both are saved under the new key.
        #expect(life.resident(RoamingChairKind.id) != nil)
        #expect(storage.defaults.data(forKey: BuildingLife.storageKey) != nil)
    }

    @Test func recordsSurviveARelaunch() throws {
        let storage = ThrowawayStorage()
        let first = BuildingLife(defaults: storage.defaults, persists: true, kinds: [ButterflyKind(), RoamingChairKind()])
        var chair = try #require(first.resident(RoamingChairKind.id))
        chair.floor = 3
        chair.cell = GridCoordinate(row: 9, col: 5)
        chair.moves = 12
        first.store(chair)
        let second = BuildingLife(defaults: storage.defaults, persists: true, kinds: [ButterflyKind(), RoamingChairKind()])
        let again = try #require(second.resident(RoamingChairKind.id))
        #expect(again.floor == 3)
        #expect(again.cell == GridCoordinate(row: 9, col: 5))
        #expect(again.moves == 12)
        #expect(second.residentIDs == first.residentIDs)
    }

    @Test func startOverForgetsEveryone() throws {
        let storage = ThrowawayStorage()
        let life = BuildingLife(defaults: storage.defaults, persists: true, kinds: [ButterflyKind(), RoamingChairKind()])
        var her = try #require(life.resident(Butterfly.id))
        her.floor = 1
        her.moves = 30
        life.store(her)
        life.resetForNewPlayer()
        let fresh = try #require(life.resident(Butterfly.id))
        #expect(fresh.floor == 5)
        #expect(fresh.moves == 0)
    }

    // MARK: Offscreen life: the building's tick

    @Test func theTickLivesHerLifeExactlyAsHerOwnRoutineWould() throws {
        let storage = ThrowawayStorage()
        let saved = BuildingClock.now
        defer { BuildingClock.now = saved }
        var now = t0
        BuildingClock.now = { now }
        let life = BuildingLife(defaults: storage.defaults, persists: true, kinds: [ButterflyKind()])
        // (one floor: her routine alone can't change floors any more -- that takes THE
        // car, which only the building runs: Oct 19. Her room round is what's compared.)
        let herPlans: (Int) -> FloorPlan? = { [4].contains($0) ? self.plan($0) : nil }
        life.plans = herPlans
        var expected = try #require(life.resident(Butterfly.id))
        // (long enough for many of her moves, short enough for fewer than 40 -- whatever the pacing)
        let span = 30 * (Butterfly.style.stay.lowerBound + 1)
        for step in 1...Int(span / 20) {
            now = t0.addingTimeInterval(Double(step) * 20)
            life.tick()
        }
        now = t0.addingTimeInterval(span)
        life.tick()
        Roam.advance(&expected, style: Butterfly.style, abilities: Butterfly.abilities, plans: herPlans, to: now)
        let her = try #require(life.resident(Butterfly.id))
        #expect(her.moves == expected.moves)
        #expect(her.moves > 5)                                      // (she's been about)
        #expect(her.room != nil)                                    // (room to room)
        #expect(her.floor == expected.floor)
        #expect(her.haunt == expected.haunt)
        #expect(her.since == expected.since)
    }

    @Test func statusSaysWhereEveryoneIsAndWhatTheyreDoing() throws {
        let storage = ThrowawayStorage()
        let life = BuildingLife(defaults: storage.defaults, persists: true, kinds: [ButterflyKind(), RoamingChairKind()])
        var chair = try #require(life.resident(RoamingChairKind.id))
        chair.floor = 3
        chair.cell = GridCoordinate(row: 11, col: 7)
        chair.since = t0.addingTimeInterval(30)
        chair.dwell = 100
        life.store(chair)
        let lines = life.status(now: t0)
        let s = try #require(lines.first { $0.id == RoamingChairKind.id })
        #expect(s.activity == "travelling")
        #expect(s.destination == "floor 3 cell 11,7")
        #expect(s.nextDecisionIn == 130)
        #expect(!s.rendered)
    }

    // MARK: Roaming (no itinerary)

    @Test func aNewcomerArrivesByTheElevator() {
        var r = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: nil, since: t0, dwell: 15)
        Roam.advance(&r, style: style, abilities: [.walk, .rideElevator], plans: plans, to: t0.addingTimeInterval(16))
        #expect(r.floor == 4)
        #expect(r.cell != nil)
        // (Oct 19, one car: set down at the elevator's landing and walks on -- no
        // ride the car didn't make)
        #expect(r.leg?.changesFloor != true)
        #expect(r.leg?.from.cell == GridCoordinate(row: 10, col: 6))
    }

    /// A resident kind with the test's own style (Roam, nothing else).
    private final class TestRoamer: ResidentKind {
        let kind = "testRoamer"
        let abilities: Set<ResidentAbility> = [.walk, .rideElevator]
        let style: RoamStyle
        init(style: RoamStyle) { self.style = style }
        func newcomers(now: Date) -> [Resident] { [] }
        func advance(_ r: inout Resident, to now: Date, plans: (Int) -> FloorPlan?) {
            Roam.advance(&r, style: style, abilities: abilities, plans: plans, to: now)
        }
        func present(_ id: String, on stage: FloorStage) -> ResidentPresentation? { nil }
    }

    @Test func roamingGoesOnlyWhereItCanAndWhereItLikes() throws {
        // Oct 19 (one car): between floors it takes THE car -- so its life is lived by the
        // building (records, calls, the car), not by Roam alone.
        let saved = BuildingClock.now
        defer { BuildingClock.now = saved }
        var now = t0
        BuildingClock.now = { now }
        let life = BuildingLife(defaults: ThrowawayStorage().defaults, persists: false, kinds: [TestRoamer(style: style)])
        life.plans = plans
        life.store(Resident(id: "roamer.1", kind: "testRoamer", floor: 4, cell: nil, since: t0, dwell: 15))
        var floors = Set<Int>()
        for half in 1...6 {
            let end = t0.addingTimeInterval(Double(half) * 1800)
            while now < end {
                now = now.addingTimeInterval(1)
                life.tick()
            }
            let r = try #require(life.resident("roamer.1"))
            if r.isTravelling(at: now) { continue }                  // (mid-journey: its place is where it's going)
            floors.insert(r.floor)
            let cell = try #require(r.cell)
            #expect(plan(r.floor).cells.contains(cell))
            #expect(Self.northRoom.contains(cell) || Self.southRoom.contains(cell))   // always a room, never the hall
            #expect(cell != GridCoordinate(row: 12, col: 9))         // never stops in the furniture
            #expect(cell != GridCoordinate(row: 11, col: 4))         // never the bathroom
            #expect(r.room != nil && r.roomName != nil)
        }
        #expect(floors == [3, 4])                                     // (by the car, both ways)
        #expect((life.resident("roamer.1")?.moves ?? 0) > 30)
    }

    @Test func noElevatorWithoutTheAbility() {
        var r = Resident(id: "chair.2", kind: "roamingChair", floor: 4, cell: GridCoordinate(row: 9, col: 5), since: t0, dwell: 15)
        for hour in 1...4 {
            Roam.advance(&r, style: style, abilities: [.walk], plans: plans, to: t0.addingTimeInterval(Double(hour) * 3600))
            #expect(r.floor == 4)
            #expect(r.leg?.changesFloor != true)
        }
    }

    @Test func theSameLifeReplaysTheSameWay() {
        var a = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: nil, since: t0, dwell: 15)
        var b = a
        let later = t0.addingTimeInterval(2400)                     // (fewer than 40 decisions: no catch-up cap)
        Roam.advance(&a, style: style, abilities: [.walk, .rideElevator], plans: plans, to: later)
        for minute in stride(from: 1, through: 40, by: 7) {
            Roam.advance(&b, style: style, abilities: [.walk, .rideElevator], plans: plans, to: t0.addingTimeInterval(Double(minute) * 60))
        }
        Roam.advance(&b, style: style, abilities: [.walk, .rideElevator], plans: plans, to: later)
        #expect(a.moves == b.moves)
        #expect(a.floor == b.floor)
        #expect(a.cell == b.cell)
        #expect(a.since == b.since)
    }

    @Test func aLongAbsenceIsNotReplayedStepByStep() {
        var r = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: GridCoordinate(row: 9, col: 5), since: t0, dwell: 15)
        let month = t0.addingTimeInterval(30 * 86_400)
        // (on its own floor: between floors it would wait for THE car, which runs only in the building)
        Roam.advance(&r, style: style, abilities: [.walk], plans: plans, to: month)
        #expect(r.moves == 40)
        #expect(r.since == month)
        #expect(r.leg == nil)
    }

    /// Oct 18 (diagnostics): every decision says why, and the status says what it's waiting for.
    @Test func decisionsSayWhyAndStatusExplains() throws {
        var r = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: nil, since: t0, dwell: 15)
        Roam.advance(&r, style: style, abilities: [.walk, .rideElevator], plans: plans, to: t0.addingTimeInterval(16))
        let why = try #require(r.why)
        #expect(why.contains("newcomer"))
        #expect(why.contains("F4"))
        var lost = Resident(id: "chair.9", kind: "roamingChair", floor: 7, cell: GridCoordinate(row: 1, col: 1), since: t0, dwell: 15)
        Roam.advance(&lost, style: style, abilities: [.walk], plans: plans, to: t0.addingTimeInterval(20))
        #expect(lost.why == "stays put: no plan of F7")

        let storage = ThrowawayStorage()
        let life = BuildingLife(defaults: storage.defaults, persists: true, kinds: [ButterflyKind(), RoamingChairKind()])
        var chair = try #require(life.resident(RoamingChairKind.id))
        chair.floor = 4
        chair.cell = GridCoordinate(row: 9, col: 5)
        chair.since = .distantFuture                                       // (Oct 19, one car: there when the car brings it)
        chair.dwell = 100
        chair.leg = ResidentLeg(from: ResidentPlace(floor: 3, cell: GridCoordinate(row: 11, col: 7)), departed: t0,
                                boardAt: t0.addingTimeInterval(10), alightAt: nil)
        chair.leg?.lift = .riding
        life.store(chair)
        let s = try #require(life.status(now: t0.addingTimeInterval(20)).first { $0.id == RoamingChairKind.id })
        #expect(s.explanation.contains("in the car F3->F4"))
        #expect(s.explanation.contains("offscreen"))
    }

    // MARK: Oct 18 (navigation repair)

    /// Coming upon a walker mid-journey: shown on a cell of its route, as far along as time says.
    @Test func midJourneyShowsItPartwayAlongItsRoute() {
        let departed = t0, arrives = t0.addingTimeInterval(100)
        #expect(Roam.resumeIndex(routeCount: 11, departed: departed, arrives: arrives, now: t0) == 0)
        #expect(Roam.resumeIndex(routeCount: 11, departed: departed, arrives: arrives, now: t0.addingTimeInterval(50)) == 5)
        #expect(Roam.resumeIndex(routeCount: 11, departed: departed, arrives: arrives, now: t0.addingTimeInterval(99)) == 9)
        #expect(Roam.resumeIndex(routeCount: 11, departed: departed, arrives: arrives, now: t0.addingTimeInterval(500)) == 10)
        #expect(Roam.resumeIndex(routeCount: 11, departed: departed, arrives: arrives, now: t0.addingTimeInterval(-5)) == 0)
        #expect(Roam.resumeIndex(routeCount: 1, departed: departed, arrives: arrives, now: t0.addingTimeInterval(50)) == 0)
    }

    /// A walk never starts off the plan: the nearest walkable cell to any point.
    @Test func theNearestWalkableCellIsAlwaysOnThePlan() throws {
        let cells = plan(3).cells
        // World origin -- the reported "(0,0)" -- is far outside this block of cells.
        let fixed = try #require(Roam.nearestCell(to: SIMD2<Float>(0, 0), in: cells, cellSize: 3.52))
        #expect(cells.contains(fixed))
        #expect(fixed == GridCoordinate(row: 8, col: 4))
        let inside = try #require(Roam.nearestCell(to: SIMD2<Float>(7 * 3.52 + 0.4, 10 * 3.52 - 0.3), in: cells, cellSize: 3.52))
        #expect(inside == GridCoordinate(row: 10, col: 7))
        #expect(Roam.nearestCell(to: SIMD2<Float>(0, 0), in: [], cellSize: 3.52) == nil)
    }

    /// Every route a decision plans starts and ends on walkable cells and steps cell to cell.
    @Test func plannedRoutesAreLegal() throws {
        var r = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: GridCoordinate(row: 9, col: 5), since: t0, dwell: 15)
        for hour in 1...3 {
            Roam.advance(&r, style: style, abilities: [.walk, .rideElevator], plans: plans, to: t0.addingTimeInterval(Double(hour) * 1800))
            let p = plan(r.floor)
            let cell = try #require(r.cell)
            var start = r.leg?.from.cell ?? cell
            if r.leg?.changesFloor == true { start = try #require(p.elevator) }
            let route = try #require(p.route(from: start, to: cell))
            for c in route { #expect(p.cells.contains(c)) }
            for (a, b) in zip(route, route.dropFirst()) { #expect(abs(a.row - b.row) + abs(a.col - b.col) == 1) }
        }
    }

    /// Fast mode's shorter stays apply to a stay chosen at the old pace -- and never otherwise.
    @Test func aStayNeverOutlastsItsStylesLongest() {
        let fast = RoamStyle(floors: [3: 1, 4: 1], stay: 12...25, speed: 0.6, changeFloorChance: 0.6, elevatorRide: 12)
        var long = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: GridCoordinate(row: 9, col: 5), since: t0, dwell: 170)
        #expect(Roam.clampStay(&long, style: fast, now: t0.addingTimeInterval(10)))
        #expect(long.nextDecision == t0.addingTimeInterval(35))
        var fine = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: GridCoordinate(row: 9, col: 5), since: t0, dwell: 20)
        #expect(!Roam.clampStay(&fine, style: fast, now: t0.addingTimeInterval(10)))
        var travelling = long
        travelling.since = t0.addingTimeInterval(60)
        #expect(!Roam.clampStay(&travelling, style: fast, now: t0))
        var normal = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: GridCoordinate(row: 9, col: 5), since: t0, dwell: 170)
        #expect(!Roam.clampStay(&normal, style: style, now: t0))
    }

    /// The chair's body: where it's put is where it is AT ONCE (no (0,0) before a frame
    /// renders), its yaw is its own (no mirrored readback), and it stays upright.
    @Test func theChairsBodyIsWhereItWasPutAndUpright() throws {
        let parent = SCNNode()
        let body = ChairResidentBody()
        parent.addChildNode(body.root)
        for yaw: Float in [0, 1.2, 2.5, -2.9, 3.1] {
            body.place(at: SIMD2<Float>(24.64, 17.6), heading: yaw)
            let at = try #require(body.groundPosition)
            #expect(abs(at.x - 24.64) < 0.001 && abs(at.y - 17.6) < 0.001)
            #expect(abs(ChairGait.wrap(body.heading - yaw)) < 0.001)
            #expect(body.root.simdTransform.columns.1.y > 0.999)
        }
        body.place(at: SIMD2<Float>(1, 1), heading: 7.0)                         // (wrapped into -pi...pi)
        #expect(body.heading > -.pi && body.heading <= .pi)
        #expect(!body.isMoving && !body.isStepping)
        body.halt()
        #expect(!body.isMoving && !body.isStepping && !body.isGesturing)
    }

    @Test func anglesWrapTheShortWayRound() {
        #expect(abs(ChairGait.wrap(3 * .pi / 2) - (-.pi / 2)) < 0.0001)
        #expect(abs(ChairGait.wrap(-3 * .pi / 2) - (.pi / 2)) < 0.0001)
        #expect(abs(ChairGait.wrap(0.5)) - 0.5 < 0.0001)
        #expect(ChairGait.wrap(.pi) <= .pi && ChairGait.wrap(-.pi) > -.pi)
    }

    // MARK: Oct 18 (visible-life pass)

    /// The butterfly's body is where she was put AT ONCE (no world-origin start
    /// before a frame renders -- the flight-from-the-corner bug).
    @Test func theButterflysBodyIsWhereItWasPut() throws {
        let parent = SCNNode()
        let body = ButterflyBody(camera: nil)
        parent.addChildNode(body.root)
        body.place(at: SIMD2<Float>(42.24, 28.16), height: 2.05, heading: 1.0)
        let at = try #require(body.groundPosition)
        #expect(abs(at.x - 42.24) < 0.001 && abs(at.y - 28.16) < 0.001)
    }

    /// "Where is it?" in plain words, from the player.
    @Test func whereaboutsSayDistanceAndDirection() {
        let me = SIMD2<Float>(10, 10)
        #expect(BuildingLife.whereabouts(of: SIMD2<Float>(10, 0), from: me) == "rendered 10 m north of you")
        #expect(BuildingLife.whereabouts(of: SIMD2<Float>(20, 20), from: me) == "rendered 14 m south-east of you")
        #expect(BuildingLife.whereabouts(of: SIMD2<Float>(0, 10), from: me) == "rendered 10 m west of you")
        #expect(BuildingLife.whereabouts(of: SIMD2<Float>(10.2, 10), from: me) == "rendered right beside you")
        #expect(BuildingLife.whereabouts(of: SIMD2<Float>(1, 2), from: nil).hasPrefix("rendered at"))
    }

    // MARK: Oct 18 (room-based life)

    /// Rooms come from the map: the areas behind room-entrance doors -- not the hall,
    /// not a bathroom -- with arrival cells off the furniture and out of the doorway.
    @Test func roomsAreFoundFromTheMapsDoors() throws {
        let rooms = plan(4).rooms
        #expect(rooms.count == 2)
        let north = try #require(rooms.first { $0.cells == Self.northRoom })
        let south = try #require(rooms.first { $0.cells == Self.southRoom })
        #expect(north.name == "Room at 8,4")
        #expect(north.id == "F4 Room at 8,4")
        #expect(Set(north.arrivals) == [GridCoordinate(row: 8, col: 4), GridCoordinate(row: 8, col: 5)])   // (not the doorway cell)
        #expect(south.arrivals == [GridCoordinate(row: 12, col: 8)])                                          // (not the doorway, not the furniture)
    }

    /// A room the game's own code defines with no door of its own -- Floor 4's
    /// Supply Room, straight off its foyer -- is a destination by its own definition.
    @Test func anAuthoredRoomIsADestinationWithoutADoor() throws {
        var cells = SuppliesShowroom.roomCells
        cells.insert(GridCoordinate(row: 10, col: 6))
        cells.insert(SuppliesShowroom.foyerCell)
        let floor4 = FloorPlan(floor: SuppliesShowroom.floor, cells: cells, doors: [:], bathroomDoors: [:],
                               elevator: GridCoordinate(row: 10, col: 6), furnished: [], cellSize: 3.52)
        let rooms = floor4.rooms
        #expect(rooms.map(\.name) == ["Supply Room"])
        #expect(Set(try #require(rooms.first).arrivals) == SuppliesShowroom.roomCells)
        // ...and not on a floor whose map doesn't have its cells any more.
        let edited = FloorPlan(floor: SuppliesShowroom.floor, cells: [GridCoordinate(row: 10, col: 6), SuppliesShowroom.foyerCell],
                               doors: [:], bathroomDoors: [:], elevator: GridCoordinate(row: 10, col: 6), furnished: [], cellSize: 3.52)
        #expect(edited.rooms.isEmpty)
    }

    /// Not the same room twice in a row when there's another.
    @Test func itGoesSomewhereNewEachTime() throws {
        var r = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: GridCoordinate(row: 8, col: 4), since: t0, dwell: 15)
        let north = try #require(plan(4).rooms.first { $0.cells == Self.northRoom })
        r.room = north.id
        for i in 0..<6 {
            let was = r.room
            Roam.decide(&r, style: style, abilities: [.walk], plans: plans, at: t0.addingTimeInterval(Double(i) * 300))
            #expect(r.room != nil && r.room != was)
        }
    }

    /// A room it can't reach is never its destination (it picks another).
    @Test func anUnreachableRoomIsPassedOver() throws {
        let base = plan(4)
        // An island room: a door on its south wall to a cell that doesn't exist.
        var cells = base.cells
        let island: Set<GridCoordinate> = [GridCoordinate(row: 2, col: 2), GridCoordinate(row: 2, col: 3)]
        cells.formUnion(island)
        var doors = base.doors
        doors[GridCoordinate(row: 2, col: 2)] = .south
        let withIsland = FloorPlan(floor: 4, cells: cells, doors: doors, bathroomDoors: base.bathroomDoors,
                                   elevator: base.elevator, furnished: base.furnished, cellSize: 3.52)
        #expect(withIsland.rooms.contains { $0.cells == island })
        var r = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: GridCoordinate(row: 10, col: 7), since: t0, dwell: 15)
        for i in 0..<20 {
            Roam.decide(&r, style: style, abilities: [.walk], plans: { $0 == 4 ? withIsland : nil }, at: t0.addingTimeInterval(Double(i) * 300))
            #expect(!island.contains(r.cell ?? GridCoordinate(row: 2, col: 2)))
        }
    }

    /// A floor with no rooms: it doesn't wander the halls -- it waits briefly and looks again.
    @Test func noRoomsMeansAShortWaitNotAHallwayStay() {
        let hallOnly = FloorPlan(floor: 4, cells: Set((4...9).map { GridCoordinate(row: 10, col: $0) }), doors: [:], bathroomDoors: [:],
                                 elevator: GridCoordinate(row: 10, col: 6), furnished: [], cellSize: 3.52)
        var r = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: GridCoordinate(row: 10, col: 8), since: t0, dwell: 15)
        Roam.decide(&r, style: style, abilities: [.walk], plans: { $0 == 4 ? hallOnly : nil }, at: t0)
        #expect(r.cell == GridCoordinate(row: 10, col: 8))
        #expect(r.dwell <= 10)
        #expect(r.why == "stays put: no rooms on F4")
    }

    /// The developer panel: a heading, the player, then two lines per resident --
    /// floor, cell (x = column, y = row), room; activity, countdown, body.
    @Test func thePanelSaysWhereEveryoneIs() throws {
        let storage = ThrowawayStorage()
        let life = BuildingLife(defaults: storage.defaults, persists: true, kinds: [ButterflyKind(), RoamingChairKind()])
        var chair = try #require(life.resident(RoamingChairKind.id))
        chair.floor = 5
        chair.cell = GridCoordinate(row: 9, col: 17)
        chair.room = "F5 Break Room"
        chair.roomName = "Break Room"
        chair.since = t0
        chair.dwell = 6
        life.store(chair)
        let lines = life.panelLines(now: t0.addingTimeInterval(2))
        #expect(lines.count == 2 + 2 * life.residentIDs.count)
        #expect(lines[1].hasPrefix("PLAYER"))
        let row = try #require(lines.firstIndex { $0.hasPrefix("CHAIR") })
        #expect(lines[row].contains("F5  x17 y9  in Break Room"))
        #expect(lines[row + 1].contains("lingering | next 4s | BODY: not on this floor"))
    }

    @Test func withoutAPlanItSimplyStays() {
        var r = Resident(id: "chair.1", kind: "roamingChair", floor: 7, cell: GridCoordinate(row: 1, col: 1), since: t0, dwell: 15)
        Roam.advance(&r, style: style, abilities: [.walk, .rideElevator], plans: plans, to: t0.addingTimeInterval(20))
        #expect(r.floor == 7)
        #expect(r.cell == GridCoordinate(row: 1, col: 1))
        #expect(r.leg == nil)
    }
}
