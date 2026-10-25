import Foundation
import Testing
import simd
@testable import Hallways

/// Oct 19 -- BUILDING LIFE: the building-wide distance service. Walks over the
/// CURRENT plans (never straight lines), the elevator by its real timing,
/// residents placed by their records (walking, riding, outside), honest nils.
@MainActor
struct BuildingDistanceTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let s: Float = 3.52
    private func g(_ r: Int, _ c: Int) -> GridCoordinate { GridCoordinate(row: r, col: c) }

    /// A U: two corridors (rows 2 and 6, cols 2-8) joined only at col 2; the
    /// elevator at (2,8). (2,8) and (6,8) are 4 rows apart in a straight line,
    /// 16 steps apart on foot.
    private func uFloor(_ floor: Int, extra: Set<GridCoordinate> = [], bathroom: [GridCoordinate: Direction] = [:]) -> FloorPlan {
        var cells = Set((2...8).map { g(2, $0) }).union((2...8).map { g(6, $0) }).union((3...5).map { g($0, 2) })
        cells.formUnion(extra)
        return FloorPlan(floor: floor, cells: cells, doors: [:], bathroomDoors: bathroom, elevator: g(2, 8), furnished: [], cellSize: 3.52)
    }

    private final class Building {
        var plans: [Int: FloorPlan] = [:]
        var revision = 0
        lazy var router = BuildingRouter(plans: { [unowned self] in self.plans[$0] }, revision: { [unowned self] in self.revision })
    }

    @Test func sameFloorFollowsTheCorridorsNotTheWalls() {
        let b = Building()
        b.plans[5] = uFloor(5)
        let d = b.router.distance(from: PlayerPlace(floor: 5, cell: g(2, 8)), to: .at(floor: 5, cell: g(6, 8), point: nil, moving: false))
        #expect(d.metres == Double(16) * Double(s))                   // (6 + 4 + 6 steps round the U; never 4 through the wall)
        #expect(d.why == nil)
    }

    @Test func anotherFloorIsByTheElevator() {
        let b = Building()
        b.plans[5] = uFloor(5)
        b.plans[8] = uFloor(8)
        // Player at the far end of F5's lower corridor; resident on F8 two steps from its elevator.
        let d = b.router.distance(from: PlayerPlace(floor: 5, cell: g(6, 8)), to: .at(floor: 8, cell: g(2, 6), point: nil, moving: false))
        let expected = 16 * Double(s) + BuildingDistance.elevatorMetres(floors: 3) + 2 * Double(s)
        #expect(abs(d.metres! - expected) < 1e-6)
        // The elevator's cost grows with the floors, from its real timing.
        #expect(BuildingDistance.elevatorMetres(floors: 0) == 0)
        #expect(BuildingDistance.elevatorMetres(floors: 1) < BuildingDistance.elevatorMetres(floors: 2))
        #expect(abs(BuildingDistance.elevatorMetres(floors: 1)
                    - (BuildingDistance.boardingSeconds + ElevatorTiming.run(floors: 1)) * BuildingDistance.referencePace) < 1e-9)
        // A floor the player's elevator doesn't serve: no distance, said why.
        let barred = b.router.distance(from: PlayerPlace(floor: 5, cell: g(2, 8)), to: .at(floor: 8, cell: g(2, 6), point: nil, moving: false),
                                       reachable: [5])
        #expect(barred.metres == nil && barred.why != nil)
    }

    @Test func aChangedLayoutChangesTheDistance() {
        let b = Building()
        b.plans[5] = uFloor(5)
        let to = ResidentWhereabouts.at(floor: 5, cell: g(6, 8), point: nil, moving: false)
        let before = b.router.distance(from: PlayerPlace(floor: 5, cell: g(2, 8)), to: to).metres
        let searches = b.router.searches
        _ = b.router.distance(from: PlayerPlace(floor: 5, cell: g(2, 8)), to: to)
        #expect(b.router.searches == searches)                          // (cached: the same layout, no new walk)
        // A shortcut is built (a corridor down col 8): the store's revision moves on.
        b.plans[5] = uFloor(5, extra: [g(3, 8), g(4, 8), g(5, 8)])
        b.revision += 1
        let after = b.router.distance(from: PlayerPlace(floor: 5, cell: g(2, 8)), to: to).metres
        #expect(before == 16 * Double(s))
        #expect(after == 4 * Double(s))
        #expect(b.router.searches > searches)
    }

    @Test func aShutDoorIsNoWayThrough() {
        let b = Building()
        // The shortcut down col 8 has a bathroom door at its top: nobody walks through.
        b.plans[5] = uFloor(5, extra: [g(3, 8), g(4, 8), g(5, 8)], bathroom: [g(2, 8): .south])
        let d = b.router.distance(from: PlayerPlace(floor: 5, cell: g(2, 8)), to: .at(floor: 5, cell: g(6, 8), point: nil, moving: false))
        #expect(d.metres == 16 * Double(s))                             // (round the U again)
        // A cell nothing joins: no distance, never a guess.
        b.plans[6] = uFloor(6, extra: [g(9, 9)])
        let island = b.router.distance(from: PlayerPlace(floor: 6, cell: g(2, 8)), to: .at(floor: 6, cell: g(9, 9), point: nil, moving: false))
        #expect(island.metres == nil && island.why != nil)
        // No plan for the floor at all: no distance.
        let nowhere = b.router.distance(from: PlayerPlace(floor: 6, cell: g(2, 8)), to: .at(floor: 12, cell: g(2, 2), point: nil, moving: false))
        #expect(nowhere.metres == nil)
    }

    @Test func aResidentRidingTheElevatorIsInTheCar() {
        let b = Building()
        b.plans[4] = uFloor(4)
        b.plans[12] = uFloor(12)
        var r = Resident(id: "hw.lanky", kind: "hallwaysian.hw.lanky", floor: 12, cell: g(2, 4), since: .distantFuture, dwell: 60)
        let board = t0.addingTimeInterval(10)
        var leg = ResidentLeg(from: ResidentPlace(floor: 4, cell: g(6, 3)), departed: t0, boardAt: board, alightAt: nil)
        leg.lift = .toDoors
        r.leg = leg
        // Before the doors: walking to F4's elevator, somewhere on its route.
        if case .at(let f, _, _, let moving) = b.router.whereabouts(r, now: t0.addingTimeInterval(5)) { #expect(f == 4 && moving) }
        else { Issue.record("not walking to the elevator") }
        // Waiting at the doors: at F4's elevator.
        r.leg?.lift = .waiting
        #expect(b.router.whereabouts(r, now: t0.addingTimeInterval(30)) == .at(floor: 4, cell: g(2, 8), point: nil, moving: false))
        // In the car: where THE car is (Oct 19: one car, one position).
        r.leg?.lift = .riding
        let mid = b.router.whereabouts(r, now: t0.addingTimeInterval(40), carFloor: 8)
        guard case .riding(let from, let to, let at) = mid else { Issue.record("not riding"); return }
        #expect(from == 4 && to == 12 && at == 8)
        // From F4's elevator doors: the walk to them plus the car's run down to F4.
        let d = b.router.distance(from: PlayerPlace(floor: 4, cell: g(2, 8)), to: mid)
        #expect(abs(d.metres! - BuildingDistance.elevatorMetres(floors: at - 4)) < 1e-6)
        // Out and walking on F12 to its room.
        let out = t0.addingTimeInterval(50)
        r.leg?.lift = .out
        r.leg?.alightAt = out
        r.since = out.addingTimeInterval(100)
        if case .at(let f, _, _, _) = b.router.whereabouts(r, now: out.addingTimeInterval(1)) { #expect(f == 12) }
        else { Issue.record("not out on F12") }
        // There.
        #expect(b.router.whereabouts(r, now: t0.addingTimeInterval(300)) == .at(floor: 12, cell: g(2, 4), point: nil, moving: false))
    }

    @Test func notYetInTheBuildingIsNoDistance() {
        let b = Building()
        b.plans[1] = uFloor(1)
        let r = Resident(id: "hw.tiny", kind: "hallwaysian.hw.tiny", floor: 1, cell: nil, since: t0.addingTimeInterval(60), dwell: 0)
        #expect(b.router.whereabouts(r, now: t0) == .outside)
        let d = b.router.distance(from: PlayerPlace(floor: 1, cell: g(2, 8)), to: .outside)
        #expect(d.metres == nil && d.why == "not in the building yet")
    }

    @Test func aBodyOnThePlayersFloorWinsOverItsRecord() {
        let b = Building()
        b.plans[5] = uFloor(5)
        let r = Resident(id: "chair.1", kind: "chair", floor: 5, cell: g(6, 8), since: t0, dwell: 60)
        let w = b.router.whereabouts(r, now: t0, body: (floor: 5, point: SIMD2(4 * s, 2 * s)))
        #expect(w == .at(floor: 5, cell: g(2, 4), point: SIMD2(4 * s, 2 * s), moving: false))
    }

    @Test func theMeterIsHotNearAndColdFar() {
        #expect(BuildingDistance.meter(0) == 1)
        #expect(BuildingDistance.meter(nil) == 0)
        #expect(BuildingDistance.meter(BuildingDistance.meterFar) < 1e-9)
        #expect(BuildingDistance.meter(10_000) == 0)
        var last = 2.0
        for d in stride(from: 0.0, through: 260, by: 3.52) {
            let m = BuildingDistance.meter(d)
            #expect(m <= last)                                           // (never warmer further away)
            last = m
        }
        // A cell of progress still shows far away (a floor and more off).
        #expect(BuildingDistance.meter(100) - BuildingDistance.meter(100 + 3.52) > 0.005)
    }

    /// A save's records (decoded, as old saves are) are placed without anything new in them.
    @Test func anExistingSavesRecordsArePlaced() throws {
        let json = #"[{"id":"pottle.1","kind":"critter.pottle.1","floor":7,"cell":{"row":2,"col":5},"since":800000000,"dwell":90,"moves":3,"haunt":0,"memories":{}}]"#
        let saved = try JSONDecoder().decode([Resident].self, from: Data(json.utf8))
        let b = Building()
        b.plans[7] = uFloor(7)
        #expect(b.router.whereabouts(saved[0], now: t0.addingTimeInterval(10)) == .at(floor: 7, cell: g(2, 5), point: nil, moving: false))
    }

    /// The directory, live: nearest first, and it changes as a resident moves
    /// (its record) or the player does -- the same residents, nothing added.
    @Test func theDirectoryFollowsTheBuilding() throws {
        let b = Building()
        b.plans[5] = uFloor(5)
        b.plans[9] = uFloor(9)
        let storage = ThrowawayStorage()
        let life = BuildingLife(defaults: storage.defaults, persists: false, kinds: HallwaysianCast.kinds)
        let ids = life.residentIDs
        #expect(Set(ids) == Set(HallwaysianCast.ids))
        var near = try #require(life.resident("hw.feddy")), far = try #require(life.resident("hw.tiny"))
        near.floor = 5; near.cell = g(2, 6); near.since = t0; near.dwell = 600
        far.floor = 9; far.cell = g(6, 8); far.since = t0; far.dwell = 600
        life.store(near); life.store(far)
        var list = BuildingLifeModel.entries(life: life, router: b.router, player: PlayerPlace(floor: 5, cell: g(2, 8)),
                                             reachable: nil, bodyFloor: 5, now: t0.addingTimeInterval(1))
        #expect(list.count == ids.count)                                         // (everyone listed, met or not)
        #expect(list[0].id == "hw.feddy" && list[1].id == "hw.tiny")
        #expect(list[0].meter > list[1].meter)
        #expect(list.dropFirst(2).allSatisfy { $0.whereabouts == .outside && $0.metres == nil })   // (the rest not in yet: last, no distance)
        // Feddy goes further up, to F13; Tiny is now the nearer.
        b.plans[13] = uFloor(13)
        near.floor = 13; near.cell = g(6, 8)
        life.store(near)
        list = BuildingLifeModel.entries(life: life, router: b.router, player: PlayerPlace(floor: 5, cell: g(2, 8)),
                                         reachable: nil, bodyFloor: 5, now: t0.addingTimeInterval(2))
        #expect(list[0].id == "hw.tiny" && list[1].id == "hw.feddy")
        // The player walks: the meter moves with them.
        let before = list[0].meter
        list = BuildingLifeModel.entries(life: life, router: b.router, player: PlayerPlace(floor: 5, cell: g(6, 8)),
                                         reachable: nil, bodyFloor: 5, now: t0.addingTimeInterval(3))
        #expect(list.first { $0.id == "hw.tiny" }!.meter < before)              // (16 more steps to F5's elevator)
    }
}
