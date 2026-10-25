import Foundation
import Testing
@testable import Hallways

/// Oct 18 -- OPEN THE BUILDING: the residents' roster and arrivals (one at a
/// time, in at the lobby entrance), the building's rules on where they may go
/// (never Floor 2, never Floor 3's scripted rooms, never the lobby as a stop),
/// open-plan floors' furnished places as destinations, favourite rooms, and the
/// elevator's one timing. Pure data: no scene.
@MainActor
struct PopulationTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func g(_ r: Int, _ c: Int) -> GridCoordinate { GridCoordinate(row: r, col: c) }

    /// The lobby as DefaultMazes draws it: (10..14, 7), the elevator at (10,7).
    private func lobby() -> FloorPlan {
        FloorPlan(floor: 1, cells: Set((10...14).map { g($0, 7) }), doors: [:], bathroomDoors: [:],
                  elevator: g(10, 7), furnished: [], cellSize: 3.52)
    }

    /// A floor with a hall (row 10, cols 4-9, the elevator at 10,6) and a room
    /// behind a door at (10,5) -- (9,5), (8,5), (8,4).
    private func roomFloor(_ floor: Int) -> FloorPlan {
        var cells = Set((4...9).map { g(10, $0) })
        cells.formUnion([g(9, 5), g(8, 5), g(8, 4)])
        return FloorPlan(floor: floor, cells: cells, doors: [g(10, 5): .north], bathroomDoors: [:],
                         elevator: g(10, 6), furnished: [], cellSize: 3.52)
    }

    /// An open-plan floor: no rooms, a block of rows 8-12 x cols 2-12, the
    /// elevator at (10,6); desks at (8,3)-(8,4), an aquarium at (12,11).
    private func openFloor(_ floor: Int) -> FloorPlan {
        var cells = Set<GridCoordinate>()
        for r in 8...12 { for c in 2...12 { cells.insert(g(r, c)) } }
        var plan = FloorPlan(floor: floor, cells: cells, doors: [:], bathroomDoors: [:], elevator: g(10, 6),
                             furnished: [g(8, 3), g(8, 4), g(12, 11)], cellSize: 3.52)
        plan.furnitureKinds = [g(8, 3): "desk", g(8, 4): "desk", g(12, 11): "aquarium"]
        return plan
    }

    // MARK: The roster

    @Test func theRosterIsTheFinalCastAndArrivesOneAtATime() {
        let ids = ResidentRoster.profiles.map { $0.id }
        // Oct 19 (Stage A, the final cast): the Pottle alone -- Clacker, Little
        // Clacker, Dog, Cat and Little Pottle are retired (CastCleanupTests).
        #expect(ids == ["pottle.1"])
        #expect(Set(ids).count == ids.count)
        // With the chair and the butterfly: three residents.
        #expect(Set(ids + [RoamingChairKind.id, Butterfly.id]).count == 3)
        // Never a character with a scripted part.
        for scripted in ["jeff", "tinky", "juanita", "bigShot", "candy", "stalk", "ladder", "frog", "slinky"] {
            #expect(!ids.contains { $0.lowercased().hasPrefix(scripted.lowercased()) })
        }
        // Staggered: the chair first (order 0), then each in turn -- no two at once.
        let orders = [0] + ResidentRoster.profiles.map { $0.arrivalOrder }
        #expect(Set(orders).count == orders.count)
        let delays = orders.sorted().map { ResidentRoster.arrivalDelay(order: $0) }
        for (a, b) in zip(delays, delays.dropFirst()) { #expect(b - a >= 60) }
        #expect(delays.first! >= 20)                                        // (nobody on the very first frame)
        // Every one has a Contacts entry of its own.
        for id in ids { #expect(CharacterRegistry.identity(id) != nil) }
        // Never Floor 2, the lobby, or Floor 3, by preference.
        for p in ResidentRoster.profiles {
            #expect(p.normal.floors[2] == nil && p.normal.floors[1] == nil && p.normal.floors[3] == nil)
        }
        #expect(RoamingChairKind.normalStyle.floors[2] == nil && RoamingChairKind.normalStyle.floors[3] == nil)
        #expect(Butterfly.normalStyle.floors[2] == nil && Butterfly.normalStyle.floors[3] == nil)
    }

    @Test func aNewcomerIsInTheLobbyWithNoPlaceUntilItsTime() {
        for kind in ResidentRoster.kinds {
            let n = kind.newcomers(now: t0)
            #expect(n.count == 1)
            #expect(n[0].floor == ResidentPolicy.lobbyFloor)
            #expect(n[0].cell == nil)
            #expect(n[0].since > t0)
        }
        let chair = RoamingChairKind().newcomers(now: t0)[0]
        #expect(chair.floor == 1 && chair.cell == nil && chair.since > t0)
    }

    // MARK: Arrival

    @Test func theLobbyEntranceIsTheFarEndFromTheElevator() {
        #expect(RoomRegistry.lobbyEntrance(lobby()) == g(14, 7))
    }

    @Test func aNewcomerWalksInAtTheEntranceAndRidesUp() throws {
        var style = RoamStyle(floors: [2: 50, 4: 1], stay: 30...60, speed: 0.8, changeFloorChance: 0.3)
        style.roomTaste = [:]
        let plans: (Int) -> FloorPlan? = { f in f == 1 ? self.lobby() : (2...5).contains(f) ? self.roomFloor(f) : nil }
        for n in 0..<20 {
            var r = Resident(id: "clacker.\(n)", kind: "critter.clacker", floor: 1, cell: nil, since: t0, dwell: 0)
            Roam.advance(&r, style: style, abilities: [.walk, .rideElevator], plans: plans, to: t0)
            #expect(r.floor == 4)                                           // (never Floor 2, however much it "likes" it)
            let leg = try #require(r.leg)
            #expect(leg.from == ResidentPlace(floor: 1, cell: g(14, 7)))   // (in at the entrance)
            let atDoors = try #require(leg.boardAt)
            #expect(atDoors > t0)                                           // (it walks the lobby first)
            #expect(leg.lift == .toDoors)                                   // (Oct 19: then calls THE car -- no booked ride)
            #expect(leg.alightAt == nil && r.since == .distantFuture)
            #expect(r.why?.contains("lobby entrance") ?? false)
        }
    }

    // MARK: Where they may go

    @Test func closedFloorsAndScriptedRoomsAreNeverDestinations() {
        func room(_ floor: Int, _ name: String) -> RoomDestination {
            RoomDestination(id: "F\(floor) \(name)", floor: floor, name: name, cells: [g(1, 1)], arrivals: [g(1, 1)])
        }
        #expect(!ResidentPolicy.isOpen(room(2, "Room at 3,3")))
        #expect(!ResidentPolicy.isOpen(room(1, "Desks at 3,3")))
        #expect(!ResidentPolicy.isOpen(room(3, "Conference Room")))
        #expect(!ResidentPolicy.isOpen(room(3, "Office")))
        #expect(ResidentPolicy.isOpen(room(4, "Supply Room")))
        #expect(ResidentPolicy.isOpen(room(5, "Break Room")))
        // Already on Floor 2 somehow (an old save): it leaves for a floor with somewhere to go.
        let plans: (Int) -> FloorPlan? = { f in (2...4).contains(f) ? self.roomFloor(f) : nil }
        var r = Resident(id: "dog.1", kind: "critter.dog", floor: 2, cell: g(10, 7), since: t0, dwell: 0)
        Roam.decide(&r, style: RoamStyle(floors: [2: 1, 4: 1], stay: 20...30, speed: 0.8, changeFloorChance: 0),
                    abilities: [.walk, .rideElevator], plans: plans, at: t0)
        #expect(r.floor == 4)
    }

    @Test func anOpenPlanFloorsFurnitureMakesPlacesToGo() throws {
        let plan = openFloor(8)
        let rooms = plan.rooms
        let desks = try #require(rooms.first { $0.name.hasPrefix("Desks") })
        let tank = try #require(rooms.first { $0.name.hasPrefix("Aquarium") })
        #expect(desks.id == "F8 Desks at 8,3")
        for spot in [desks, tank] {
            #expect(!spot.arrivals.isEmpty)
            for a in spot.arrivals {
                #expect(!plan.furnished.contains(a))                        // (beside it, never in it)
                #expect(a != plan.elevator)
                #expect(plan.cells.contains(a))
            }
        }
        // A hallway on its own, with nothing in it, is never a place.
        let bare = FloorPlan(floor: 8, cells: plan.cells, doors: [:], bathroomDoors: [:], elevator: g(10, 6), furnished: [], cellSize: 3.52)
        #expect(bare.rooms.isEmpty)
    }

    @Test func favouritesAreChosenMoreOftenButNotAlways() {
        var style = RoamStyle(floors: [8: 1], stay: 20...30, speed: 0.8, changeFloorChance: 0)
        style.roomTaste = ["Aquarium": 4]
        let plan = openFloor(8)
        var tank = 0, other = 0
        for n in 0..<200 {
            var r = Resident(id: "cat.\(n)", kind: "critter.cat", floor: 8, cell: g(10, 8), since: t0, dwell: 0)
            Roam.decide(&r, style: style, abilities: [.walk], plans: { $0 == 8 ? plan : nil }, at: t0)
            if r.roomName?.hasPrefix("Aquarium") ?? false { tank += 1 } else { other += 1 }
        }
        #expect(tank > 120)                                                 // (about 4 in 5)
        #expect(other > 10)                                                 // (never only the favourite)
    }

    // MARK: The elevator's one timing

    @Test func theCarIsAboutAThirdSlowerAndCountsEvenly() {
        #expect(abs(ElevatorTiming.ride(floors: 1) / 4.5 - 1 / 0.65) < 0.0001)       // (+54%: 35% less speed)
        #expect(ElevatorTiming.ride(floors: 0) == 0)
        for n in [1, 2, 4, 15] {
            var last: TimeInterval = 0
            for s in 1...n {
                let at = ElevatorTiming.passing(step: s, of: n)
                #expect(at > last)                                          // (no pause at any floor)
                last = at
                #expect(ElevatorTiming.floorsDone(of: n, after: at) == s)
                #expect(ElevatorTiming.floorsDone(of: n, after: at - 0.01) == s - 1)
            }
            #expect(abs(last - ElevatorTiming.ride(floors: n)) < 0.000001)
            // The player's cab and the residents' car agree: the cab's last digit lands at the car's ride.
            #expect(abs(TapNavigationController.elevatorIndicatorStepDelay(step: n, steps: n)
                        - (TapNavigationController.elevatorIndicatorLeadIn + ElevatorTiming.ride(floors: n))) < 0.000001)
        }
        // Oct 19 (one car): the car runs on the count the player's cab shows -- the same one.
        for n in [1, 4, 15] {
            #expect(abs(ElevatorTiming.run(floors: n) - ElevatorTiming.runStep(n, of: n)) < 0.000001)
            if !RocketElevator.isOn {
                #expect(abs(ElevatorTiming.run(floors: n) - TapNavigationController.elevatorIndicatorStepDelay(step: n, steps: n)) < 0.000001)
            } else {
                #expect(abs(ElevatorTiming.run(floors: n) - RocketElevator.indicatorStepDelay(step: n, steps: n)) < 0.000001)
            }
        }
    }

    // MARK: Oct 19 -- the building opens after onboarding

    /// Before the building opens (Start Over, onboarding), a newcomer waits
    /// outside: no decision, no lobby walk, no car booked to the lobby. Its
    /// place in line counts from the opening, not from when it was created.
    @Test func newcomersWaitOutsideUntilTheBuildingOpens() throws {
        var r = try #require(ResidentRoster.kinds.first?.newcomers(now: t0).first)
        #expect(ResidentRoster.holdArrival(&r, order: 1, open: false, now: t0.addingTimeInterval(5)))
        #expect(r.since >= ResidentRoster.notYet)
        #expect(r.cell == nil && r.leg == nil)
        // Still held minutes later; nothing changes while it waits.
        let held = r.since
        #expect(ResidentRoster.holdArrival(&r, order: 1, open: false, now: t0.addingTimeInterval(600)))
        #expect(r.since == held)
        // Opened at t0+900: due its own interval after that.
        let opened = t0.addingTimeInterval(900)
        #expect(!ResidentRoster.holdArrival(&r, order: 1, open: true, now: opened))
        #expect(r.since == opened.addingTimeInterval(ResidentRoster.arrivalDelay(order: 1)))
        // ...and once scheduled, opening again changes nothing.
        let due = r.since
        #expect(!ResidentRoster.holdArrival(&r, order: 1, open: true, now: opened.addingTimeInterval(3)))
        #expect(r.since == due)
        // A resident already in the building is never held.
        var inside = Resident(id: "dog.1", kind: "critter.dog", floor: 5, cell: g(10, 6), since: t0, dwell: 30)
        #expect(!ResidentRoster.holdArrival(&inside, order: 2, open: false, now: t0))
        #expect(inside.since == t0)
    }

    /// Held, a newcomer's record books nothing: Roam never runs, so no car comes to the lobby.
    @Test func aHeldNewcomerBooksNoCar() throws {
        let plans: (Int) -> FloorPlan? = { f in f == 1 ? self.lobby() : (4...5).contains(f) ? self.roomFloor(f) : nil }
        var r = Resident(id: "clacker.1", kind: "critter.clacker", floor: 1, cell: nil, since: t0, dwell: 0)
        let style = RoamStyle(floors: [4: 1], stay: 20...30, speed: 1, changeFloorChance: 0.5)
        if !ResidentRoster.holdArrival(&r, order: 1, open: false, now: t0.addingTimeInterval(120)) {
            Roam.advance(&r, style: style, abilities: [.walk, .rideElevator], plans: plans, to: t0.addingTimeInterval(120))
        }
        #expect(r.leg == nil && r.cell == nil && r.floor == 1)              // (no trip: nothing to call the car for)
    }

    // MARK: Oct 19 -- the shaft's sound

    @Test func theShaftIsHeardOnlyAsTheCarComesNear() {
        #expect(ElevatorShaftSound.audible(carFloor: 3, direction: -1, here: 1) == 2)     // coming down, two away
        #expect(ElevatorShaftSound.audible(carFloor: 2, direction: -1, here: 1) == 1)
        #expect(ElevatorShaftSound.audible(carFloor: 1, direction: 1, here: 1) == 0)      // setting off from here
        #expect(ElevatorShaftSound.audible(carFloor: 3, direction: 1, here: 1) == nil)    // going away
        #expect(ElevatorShaftSound.audible(carFloor: 4, direction: -1, here: 1) == nil)   // too far
        #expect(ElevatorShaftSound.audible(carFloor: 11, direction: -1, here: 5) == nil)
        #expect(ElevatorShaftSound.audible(carFloor: 2, direction: 0, here: 1) == nil)    // standing still
    }

    @Test func theRumbleIsSmoothAndHasNoNoise() {
        let a = ElevatorShaftSound.rumble(), b = ElevatorShaftSound.rumble()
        #expect(a == b)                                                     // (no random noise in it: the same every time)
        let n = a.count
        #expect(n > 0)
        let edge = max(1, n / 100)
        #expect(a.prefix(edge).map { abs($0) }.max()! < 0.02)               // swells in...
        #expect(a.suffix(edge).map { abs($0) }.max()! < 0.02)               // ...and out (never a click)
        // No sample-to-sample jumps a hiss would make (the loudest step is small).
        var step: Float = 0
        for i in 1..<n { step = max(step, abs(a[i] - a[i - 1])) }
        #expect(step < 0.12)
    }
}
