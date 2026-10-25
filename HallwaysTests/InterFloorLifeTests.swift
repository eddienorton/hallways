import Foundation
import Testing
@testable import Hallways

/// Oct 18 -- INTER-FLOOR LIFE: the -HallwaysLifeTestFloors test mode (parsing,
/// pacing, nothing saved), residents choosing rooms on another floor and
/// riding THE car there (Oct 19: called, waited for, ridden, out), and the
/// hall indicator following the car. Pure data: no scene.
@MainActor
struct InterFloorLifeTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The same little floor as BuildingLifeTests: a hall (row 10, cols 4-9,
    /// the elevator at 10,6), a north room behind a door at (10,5), a south room
    /// behind a door at (10,8), a bathroom (no destination) at (11,4).
    private func plan(_ floor: Int) -> FloorPlan {
        var cells = Set<GridCoordinate>()
        for col in 4...9 { cells.insert(GridCoordinate(row: 10, col: col)) }
        cells.formUnion([GridCoordinate(row: 9, col: 5), GridCoordinate(row: 8, col: 5), GridCoordinate(row: 8, col: 4)])
        cells.formUnion([GridCoordinate(row: 11, col: 8), GridCoordinate(row: 12, col: 8), GridCoordinate(row: 12, col: 9)])
        cells.insert(GridCoordinate(row: 11, col: 4))
        return FloorPlan(floor: floor, cells: cells,
                         doors: [GridCoordinate(row: 10, col: 5): .north, GridCoordinate(row: 10, col: 8): .south],
                         bathroomDoors: [GridCoordinate(row: 10, col: 4): .south],
                         elevator: GridCoordinate(row: 10, col: 6), furnished: [GridCoordinate(row: 12, col: 9)], cellSize: 3.52)
    }
    /// Floors 3, 4 and 5 all exist -- the test mode must keep to 4 and 5 by itself.
    private func plans(_ floor: Int) -> FloorPlan? { [3, 4, 5].contains(floor) ? plan(floor) : nil }
    private let fast = RoamStyle(floors: [3: 1, 4: 1], stay: 8...15, speed: 0.6, changeFloorChance: 0.6, elevatorRide: 12)
    private let interFloor = LifeTestMode(floors: [4, 5], interFloor: true)

    // MARK: Launch arguments

    @Test func theInterFloorArgumentIsRead() {
        let m = LifeTestMode.parse(arguments: ["/app", "-HallwaysLifeTestFloors", "4,5"], singleDefault: 0, floorsDefault: nil)
        #expect(m == LifeTestMode(floors: [4, 5], interFloor: true))
        #expect(m?.title == "FLOORS 4+5")
        // As Xcode hands it over when typed as one argument.
        #expect(LifeTestMode.parse(arguments: ["/app", "-HallwaysLifeTestFloors 4,5"], singleDefault: 0, floorsDefault: nil)?.floors == [4, 5])
        // From the argument domain (UserDefaults), any order, repeats dropped.
        #expect(LifeTestMode.parse(arguments: [], singleDefault: 0, floorsDefault: "5, 4,5")?.floors == [4, 5])
    }

    @Test func withoutItsHyphenNothingIsEnabled() {
        #expect(LifeTestMode.parse(arguments: ["/app", "HallwaysLifeTestFloors", "4,5"], singleDefault: 0, floorsDefault: nil) == nil)
        #expect(LifeTestMode.parse(arguments: ["/app", "HallwaysLifeTest", "5"], singleDefault: 0, floorsDefault: nil) == nil)
        // One floor is not an inter-floor test.
        #expect(LifeTestMode.parse(arguments: ["/app", "-HallwaysLifeTestFloors", "5"], singleDefault: 0, floorsDefault: nil) == nil)
    }

    @Test func theOneFloorTestIsUnchanged() {
        let m = LifeTestMode.parse(arguments: ["/app", "-HallwaysLifeTest", "5"], singleDefault: 0, floorsDefault: nil)
        #expect(m == LifeTestMode(floors: [5], interFloor: false))
        #expect(m?.title == "FLOOR 5")
        #expect(LifeTestMode.parse(arguments: ["/app", "-HallwaysLifeTest 5"], singleDefault: 0, floorsDefault: nil)?.floors == [5])
        let s = m!.pacing(fast)
        #expect(s.floors == [5: 1])
        #expect(s.stay == 3...8)
        #expect(s.changeFloorChance == 0)
    }

    @Test func bothGivenTheInterFloorTestWins() {
        let m = LifeTestMode.parse(arguments: ["/app", "-HallwaysLifeTest", "5", "-HallwaysLifeTestFloors", "4,5"],
                                   singleDefault: 5, floorsDefault: "4,5")
        #expect(m?.interFloor == true)
    }

    @Test func interFloorPacingKeepsToItsFloorsAndChangesOften() {
        let s = interFloor.pacing(fast)
        #expect(s.floors == [4: 1, 5: 1])
        #expect(s.stay == 12...20)
        #expect(s.changeFloorChance == 0.5)
        #expect(s.elevatorRide == 12)
        #expect(s.speed == fast.speed)
    }

    // MARK: Nothing saved

    @Test func testModesNeverSaveTheRealRecords() throws {
        #expect(BuildingLife.shouldPersist(underTests: false, test: nil))
        #expect(!BuildingLife.shouldPersist(underTests: false, test: interFloor))
        #expect(!BuildingLife.shouldPersist(underTests: false, test: LifeTestMode(floors: [5], interFloor: false)))
        #expect(!BuildingLife.shouldPersist(underTests: true, test: nil))
        // A life that doesn't persist leaves saved records exactly as they were.
        let storage = ThrowawayStorage()
        let real = BuildingLife(defaults: storage.defaults, persists: true, kinds: [ButterflyKind(), RoamingChairKind()])
        var chair = try #require(real.resident(RoamingChairKind.id))
        chair.floor = 3
        chair.moves = 41
        real.store(chair)
        let saved = storage.defaults.data(forKey: BuildingLife.storageKey)
        let test = BuildingLife(defaults: storage.defaults, persists: false, kinds: [ButterflyKind(), RoamingChairKind()])
        var moved = try #require(test.resident(RoamingChairKind.id))
        moved.floor = 5
        moved.moves = 99
        test.store(moved)
        #expect(storage.defaults.data(forKey: BuildingLife.storageKey) == saved)
        let again = BuildingLife(defaults: storage.defaults, persists: true, kinds: [ButterflyKind(), RoamingChairKind()])
        #expect(again.resident(RoamingChairKind.id)?.floor == 3)
        #expect(again.resident(RoamingChairKind.id)?.moves == 41)
    }

    // MARK: Choosing a room on the other floor

    @Test func residentsChooseRoomsOnBothTestFloorsAndNeverAnother() {
        let style = interFloor.pacing(fast)
        var r = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: GridCoordinate(row: 10, col: 9), since: t0, dwell: 1)
        var floorsSeen = Set<Int>()
        var trips = 0
        var t = t0.addingTimeInterval(1)
        for _ in 0..<40 {
            let before = r.floor
            Roam.decide(&r, style: style, abilities: [.walk, .rideElevator], plans: plans, at: t)
            #expect([4, 5].contains(r.floor))
            #expect(r.room?.hasPrefix("F\(r.floor) ") == true)          // a registered room of the floor it chose
            floorsSeen.insert(r.floor)
            if r.floor != before { trips += 1 }
            t = r.nextDecision
            r.leg = nil
        }
        #expect(floorsSeen == [4, 5])
        #expect(trips >= 8)                                                // (about half of 40)
    }

    /// The first decision for the other floor, from F4 (the test style changes floors often).
    private func tripUp() -> (Resident, Date) {
        let style = interFloor.pacing(fast)
        var r = Resident(id: "chair.1", kind: "roamingChair", floor: 4, cell: GridCoordinate(row: 10, col: 9), since: t0, dwell: 1)
        var t = t0.addingTimeInterval(1)
        for _ in 0..<40 where r.floor == 4 {
            Roam.decide(&r, style: style, abilities: [.walk, .rideElevator], plans: plans, at: t)
            if r.floor == 4 { t = r.nextDecision; r.leg = nil }
        }
        return (r, t)
    }

    @Test func aTripToTheOtherFloorGoesThroughTheCar() throws {
        let (r, t) = tripUp()
        #expect(r.floor == 5)
        let leg = try #require(r.leg)
        #expect(leg.from.floor == 4)
        // Oct 19 (one car): it walks to the doors (by boardAt -- when it gets there,
        // not a booking), then the car; when it's out is the car's to say.
        #expect(leg.lift == .toDoors)
        #expect(try #require(leg.boardAt) > t)
        #expect(leg.alightAt == nil)
        #expect(r.since == .distantFuture)
        #expect((leg.outWalk ?? 0) > 0)
        #expect(plan(5).rooms.contains { $0.id == r.room && $0.arrivals.contains(r.cell!) })
    }

    // MARK: The ride, by the record and the car

    @Test func aRideIsCarriedThroughOffscreenToTheRoom() throws {
        let style = interFloor.pacing(fast)
        var (r, _) = tripUp()
        let room = r.room, cell = r.cell
        let atDoors = try #require(r.leg?.boardAt)
        let life = BuildingLife(defaults: ThrowawayStorage().defaults, persists: false, kinds: [RoamingChairKind()])
        life.plans = plans
        life.store(r)
        life.car.restore(BuildingElevator.State(floor: 1, doorsSince: t0, clock: t0))      // (the car: in the lobby, on the test's clock)
        var stages: [LiftStage] = []
        var t = atDoors.addingTimeInterval(-1)
        while t < atDoors.addingTimeInterval(120) {
            life.liftSync(now: t)
            life.elevatorStep(now: t)
            if let s = life.resident(r.id)?.leg?.lift, stages.last != s { stages.append(s) }
            // While it rides, it is where the car is.
            if life.resident(r.id)?.leg?.lift == .riding {
                let w = BuildingRouter(plans: plans, revision: { 0 }).whereabouts(life.resident(r.id)!, now: t, carFloor: life.car.position(now: t)?.floor)
                if case .riding(let from, let to, let f) = w { #expect(from == 4 && to == 5 && f == life.car.position(now: t)?.floor) }
                else { Issue.record("riding, not \(w)") }
            }
            t = t.addingTimeInterval(0.25)
        }
        #expect(stages == [.toDoors, .waiting, .riding, .out])
        r = try #require(life.resident(r.id))
        let out = try #require(r.leg?.alightAt)
        #expect(r.since > out)
        #expect(life.car.position(now: t)?.floor == 5)                   // (the car brought it, and stays)
        // Out of the elevator and into the room: there, the leg over, the same room.
        Roam.advance(&r, style: style, abilities: [.walk, .rideElevator], plans: plans, to: r.since)
        #expect(r.floor == 5)
        #expect(r.leg == nil)
        #expect(r.room == room)
        #expect(r.cell == cell)
    }

    @Test func theRideReachesFloorsInOrderOverItsBookedTime() {
        // (an older save's booked ride -- only used to carry such a save over)
        let ride = ElevatorBoard.Ride(id: "chair.1", from: 2, to: 5, boardAt: t0, alightAt: t0.addingTimeInterval(12))
        #expect(ride.floorReached(at: t0) == 2)
        #expect(ride.floorReached(at: t0.addingTimeInterval(4.5)) == 3)
        #expect(ride.floorReached(at: t0.addingTimeInterval(8.5)) == 4)
        #expect(ride.floorReached(at: t0.addingTimeInterval(12)) == 5)
        let down = ElevatorBoard.Ride(id: "chair.1", from: 5, to: 4, boardAt: t0, alightAt: t0.addingTimeInterval(12))
        #expect(down.direction == -1)
        #expect(down.floorReached(at: t0.addingTimeInterval(2)) == 5)
        #expect(down.floorReached(at: t0.addingTimeInterval(12)) == 4)
    }

    // MARK: The hall indicator, from the car

    private func pair(_ x: (floor: Int, direction: Int)?) -> [Int]? { x.map { [$0.floor, $0.direction] } }

    @Test func theHallIndicatorFollowsTheCar() {
        let car = BuildingElevator()
        car.placeIfNeeded(at: 9, now: t0)
        // Standing: its floor, no arrow.
        #expect(pair(ElevatorBoard.indicator(floor: 5, playerUsing: false, car: car.position(now: t0))) == [9, 0])
        // Called down to 4: on its way, floor by floor, arrow down.
        car.call("chair.1", at: 4, to: 6, now: t0)
        car.advance(to: t0.addingTimeInterval(0.01))
        let p = car.position(now: t0.addingTimeInterval(0.01))
        #expect(pair(ElevatorBoard.indicator(floor: 5, playerUsing: false, car: p)) == [9, -1])
        // The player's own ride: left alone (they're in the cab).
        #expect(ElevatorBoard.indicator(floor: 5, playerUsing: true, car: p) == nil)
    }

    @Test func doorCyclePurposesSayWhatTheyAre() {
        #expect(CharacterElevatorPurpose.departure(to: 4).text == "departure for F4")
        #expect(CharacterElevatorPurpose.arrival(from: 5).text == "arrival from F5")
        #expect(CharacterElevatorPurpose.arrival(from: 5).isArrival)
        #expect(!CharacterElevatorPurpose.departure(to: 4).isArrival)
    }
}
