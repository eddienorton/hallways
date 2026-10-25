import Foundation
import Testing
@testable import Hallways

/// Oct 19 (elevator overhaul) -- A RESIDENT'S ELEVATOR JOURNEY ON THE ONE CAR,
/// start to finish: it walks to the doors, calls the car there, waits as long as
/// it takes (no booking to expire), gets in when the doors open, rides, gets out
/// at its own floor -- once each. Several share a ride; a changed plan withdraws
/// its call; the player never sends a rider anywhere early; a relaunch mid-ride
/// carries on; an older save's booked trips are carried over. Records and the
/// car only: no scene.
@MainActor
struct ElevatorJourneyTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    private let lobby = GridCoordinate(row: 14, col: 7)
    private let room = GridCoordinate(row: 9, col: 5)

    /// A trip in its record (as Roam.decide makes it): from `from` to `to`, at the doors at `doors`.
    private func trip(_ id: String, from: Int = 1, to: Int, doors: Double, kind: String = "roamingChair") -> Resident {
        var r = Resident(id: id, kind: kind, floor: to, cell: room, since: .distantFuture, dwell: 60)
        var leg = ResidentLeg(from: ResidentPlace(floor: from, cell: lobby), departed: at(doors - 15), boardAt: at(doors), alightAt: nil)
        leg.lift = .toDoors
        leg.outWalk = 8
        r.leg = leg
        return r
    }

    private func life(_ storage: ThrowawayStorage, persists: Bool = false, carAt floor: Int = 7) -> BuildingLife {
        let life = BuildingLife(defaults: storage.defaults, persists: persists, kinds: [ButterflyKind(), RoamingChairKind()])
        _ = life.residentIDs                                                     // (loaded)
        life.car.restore(BuildingElevator.State(floor: floor, doorsSince: t0, clock: t0))
        return life
    }

    /// The building's own step (4 Hz), from `from` to `to` seconds.
    private func live(_ life: BuildingLife, from: Double, to: Double, held: Set<String> = []) {
        var t = from
        while t <= to {
            life.liftSync(now: at(t), held: held)
            life.elevatorStep(now: at(t))
            t += 0.25
        }
    }

    private func stage(_ life: BuildingLife, _ id: String) -> LiftStage? { life.resident(id)?.leg?.lift }

    // MARK: One journey

    @Test func oneResidentCompletesOneJourney() throws {
        let storage = ThrowawayStorage()
        let life = life(storage, carAt: 7)
        let id = RoamingChairKind.id
        life.store(trip(id, to: 5, doors: 10))
        // Walking to the doors: no call yet, the car stays put.
        live(life, from: 0, to: 9.5)
        #expect(stage(life, id) == .toDoors)
        #expect(life.car.callOf(id) == nil)
        #expect(life.car.position(now: at(9.5))?.floor == 7 && life.car.position(now: at(9.5))?.moving == false)
        // At the doors: it calls; the car comes down from 7 to the lobby, opens, it gets in.
        live(life, from: 10, to: 10)
        #expect(stage(life, id) == .waiting)
        #expect(life.car.callOf(id)?.floor == 1)
        live(life, from: 10.25, to: 60)
        let r = try #require(life.resident(id))
        let leg = try #require(r.leg)
        #expect(leg.lift == .out)
        #expect(leg.boardedAt != nil && leg.alightAt != nil)
        #expect(leg.boardedAt! < leg.alightAt!)
        #expect(r.since == leg.alightAt!.addingTimeInterval(8))              // (then its walk to its place)
        #expect(life.car.rider(id) == nil && life.car.callOf(id) == nil)
        #expect(life.car.position(now: at(60))?.floor == 5)                 // (the car stays where it left it)
    }

    // MARK: Once only

    @Test func aRepeatedBoardingCallbackIsNotAnotherTrip() throws {
        let storage = ThrowawayStorage()
        let life = life(storage, carAt: 1)
        let id = RoamingChairKind.id
        life.store(trip(id, to: 4, doors: 0))
        life.callCar(id, now: at(0))
        // The doors open at its floor: its body walks in -- twice reported.
        life.car.advance(to: at(0.1), acting: [id])
        life.car.advance(to: at(2), acting: [id])
        #expect(life.car.position(now: at(2))?.doors == .open)
        #expect(life.boarded(id, now: at(3)))
        #expect(!life.boarded(id, now: at(3.5)))
        #expect(life.car.state?.riders.filter { $0.who == id }.count == 1)
        #expect(stage(life, id) == .riding)
    }

    // MARK: Sharing

    @Test func severalResidentsShareTheCarEachToTheirOwnFloor() throws {
        let storage = ThrowawayStorage()
        let life = life(storage, carAt: 1)
        let ids = ["chair.1", "butterfly"]
        life.store(trip("chair.1", to: 8, doors: 0))
        life.store(trip("butterfly", to: 3, doors: 0, kind: ButterflyKind.kindName))
        live(life, from: 0, to: 2)
        // Both got in at the one stop.
        for id in ids { #expect(life.car.rider(id) != nil, "\(id) aboard") }
        live(life, from: 2.25, to: 80)
        let chairOut = try #require(life.resident("chair.1")?.leg?.alightAt)
        let herOut = try #require(life.resident("butterfly")?.leg?.alightAt)
        #expect(herOut < chairOut)                                           // (3 on the way up to 8)
        #expect(life.resident("chair.1")?.floor == 8 && life.resident("butterfly")?.floor == 3)
    }

    @Test func aChangedPlanWithdrawsItsCall() throws {
        let storage = ThrowawayStorage()
        let life = life(storage, carAt: 12)
        let id = RoamingChairKind.id
        life.store(trip(id, to: 4, doors: 0))
        live(life, from: 0, to: 0.5)
        #expect(life.car.callOf(id) != nil)
        // It changes its mind (stays on its floor): its call goes, and the car with nobody to fetch stays.
        var r = try #require(life.resident(id))
        r.floor = 1; r.cell = lobby; r.leg = nil; r.since = at(1)
        life.store(r)
        life.liftSync(now: at(1))
        #expect(life.car.callOf(id) == nil)
    }

    // MARK: The player

    @Test func thePlayerCallingNeverDeliversARiderEarly() throws {
        let storage = ThrowawayStorage()
        let life = life(storage, carAt: 1)
        let id = RoamingChairKind.id
        life.store(trip(id, to: 14, doors: 0))
        live(life, from: 0, to: BuildingElevator.doorOpenSeconds + BuildingElevator.dwell + BuildingElevator.doorCloseSeconds + 0.5)
        #expect(life.car.position(now: at(7))?.moving == true)
        // The player taps on F3 as it goes up: called, not here (no taking it, no jump).
        #expect(!life.car.isHere(3))
        life.car.call("player", at: 3, to: nil, now: at(7))
        var deliveredAt: Int?
        var t = 7.25
        while t < 90 {
            life.liftSync(now: at(t))
            life.elevatorStep(now: at(t))
            if deliveredAt == nil, stage(life, id) == .out { deliveredAt = life.car.position(now: at(t))?.floor }
            t += 0.25
        }
        #expect(deliveredAt == 14)                                           // (out at its own floor, in its own time)
        #expect(life.resident(id)?.floor == 14)
        // ...and then the car came for the player.
        #expect(life.car.isHere(3) || life.car.callOf("player") == nil)
    }

    // MARK: Saved

    @Test func aJourneyUnderWaySurvivesARelaunch() throws {
        let storage = ThrowawayStorage()
        let first = life(storage, persists: true, carAt: 1)
        let id = RoamingChairKind.id
        first.store(trip(id, to: 11, doors: 0))
        live(first, from: 0, to: 7)
        #expect(stage(first, id) == .riding)
        #expect(first.car.position(now: at(7))?.moving == true)
        first.saveCar()
        // Relaunch: the same car, mid-run, the same rider in it.
        let second = BuildingLife(defaults: storage.defaults, persists: true, kinds: [ButterflyKind(), RoamingChairKind()])
        #expect(stage(second, id) == .riding)
        #expect(second.car.state?.target == 11)
        #expect(second.car.rider(id)?.destination == 11)
        live(second, from: 7.25, to: 60)
        #expect(stage(second, id) == .out)
        #expect(second.car.position(now: at(60))?.floor == 11)
        #expect(second.car.state?.riders.isEmpty == true)
    }

    @Test func anOlderSavesBookedTripsAreCarriedOver() throws {
        let storage = ThrowawayStorage()
        let now = BuildingClock.now()
        func old(_ id: String, kind: String, from: Int, to: Int, board: Double, alight: Double, boarded: Bool) -> Resident {
            var r = Resident(id: id, kind: kind, floor: to, cell: room, since: now.addingTimeInterval(alight + 9), dwell: 30)
            r.leg = ResidentLeg(from: ResidentPlace(floor: from, cell: lobby), departed: now.addingTimeInterval(board - 10),
                                boardAt: now.addingTimeInterval(board), alightAt: now.addingTimeInterval(alight))
            r.leg?.boardedAt = boarded ? now.addingTimeInterval(board) : nil
            return r
        }
        let saved = [old("chair.1", kind: "roamingChair", from: 2, to: 9, board: -4, alight: 6, boarded: true),     // riding
                     old("butterfly", kind: ButterflyKind.kindName, from: 6, to: 4, board: 30, alight: 40, boarded: false)]   // walking to the doors
        storage.defaults.set(try JSONEncoder().encode(saved), forKey: BuildingLife.storageKey)
        let life = BuildingLife(defaults: storage.defaults, persists: true, kinds: [ButterflyKind(), RoamingChairKind()])
        #expect(stage(life, "chair.1") == .riding)
        #expect(life.resident("chair.1")?.since == .distantFuture)
        #expect(life.resident("chair.1")?.leg?.outWalk == 9)
        #expect(stage(life, "butterfly") == .toDoors)
        #expect(life.resident("butterfly")?.leg?.boardAt == now.addingTimeInterval(30))
        // The car (never saved before) is placed once, where the old ride had got to -- and runs from there.
        let placed = try #require(life.car.state?.floor)
        #expect((2...9).contains(placed))
        life.liftSync(now: now)
        #expect(life.car.rider("chair.1")?.destination == 9)
    }

    // MARK: A body at the doors

    @MainActor private final class Walker: ResidentPresentation {
        let residentID: String
        init(_ id: String) { residentID = id }
        var holdsResident: Bool { true }
        var isRendered: Bool { true }
        var isGuiding: Bool { false }
        var actsElevator: Bool { true }
        func tick(now: Date) {}
        func teardown() {}
        func playerBoarding() -> Bool { false }
        func arrivalDoorsOpening() {}
    }

    @Test func aBodyAtTheDoorsIsWaitedForAndGetsIn() throws {
        let storage = ThrowawayStorage()
        let life = life(storage, carAt: 9)
        let id = RoamingChairKind.id
        life.store(trip(id, to: 6, doors: 0))
        life.presentations = [Walker(id)]
        // Its body reached the doors and called (out of sight it wouldn't be "held").
        life.callCar(id, now: at(0))
        var t = 0.0
        while t < 40, life.car.position(now: at(t))?.doors != .open {
            t += 0.25
            life.liftSync(now: at(t), held: [id])
            life.elevatorStep(now: at(t))
        }
        #expect(life.car.position(now: at(t))?.floor == 1)
        // Not moved in by the car: its body walks in -- the doors wait for it.
        #expect(life.car.rider(id) == nil)
        life.car.hold(id, until: at(t + 6))
        let opened = t
        while t < opened + 5.5 { t += 0.25; life.elevatorStep(now: at(t)) }
        #expect(life.car.position(now: at(t))?.doors == .open)
        #expect(life.boarded(id, now: at(t)))
        #expect(stage(life, id) == .riding)
    }
}
