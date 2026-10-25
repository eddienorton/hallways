import Foundation
import Testing
@testable import Hallways

/// Oct 19 (elevator overhaul) -- THE ONE CAR (BuildingElevator): it moves only
/// for a request, runs floor by floor (never a jump), opens its doors at every
/// stop, takes everyone where they're going (each their own floor), lets the
/// player have it and share it, stands still with nothing to do, and is saved
/// and resumed. Pure data: no scene.
@MainActor
struct ElevatorCarTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    private func car(at floor: Int) -> BuildingElevator {
        let c = BuildingElevator()
        c.placeIfNeeded(at: floor, now: t0)
        return c
    }

    /// Works the car forward in small steps (as the 4 Hz timer does), collecting what it did.
    @discardableResult
    private func run(_ c: BuildingElevator, from: Double, to: Double, step: Double = 0.25,
                     acting: Set<String> = [], each: ((Double, BuildingElevator.Position) -> Void)? = nil) -> [BuildingElevator.Happening] {
        var out: [BuildingElevator.Happening] = []
        var t = from
        while t <= to + 1e-9 {
            out += c.advance(to: at(t), acting: acting)
            if let p = c.position(now: at(t)) { each?(t, p) }
            t += step
        }
        return out
    }

    private func events(_ h: [BuildingElevator.Happening]) -> [BuildingElevator.Event] { h.map(\.event) }

    // MARK: Requests and movement

    @Test func calledFromADistantFloorItRunsThereAndOpensItsDoors() throws {
        let c = car(at: 12)
        c.call("chair.1", at: 4, to: 9, now: t0)
        let runTime = ElevatorTiming.run(floors: 8)
        var floors: [Int] = []
        let h = run(c, from: 0, to: runTime + BuildingElevator.doorOpenSeconds + 0.5) { _, p in floors.append(p.floor) }
        // It went from 12 to 4 -- every floor in between, in order, never a jump.
        #expect(floors.first == 12)
        for (a, b) in zip(floors, floors.dropFirst()) { #expect(b == a || b == a - 1, "\(a) -> \(b)") }
        #expect(events(h).contains(.departed(from: 12, to: 4)))
        #expect(events(h).contains(.arrived(4)))
        // ...and opened its doors there by itself; the resident got in (out of sight).
        #expect(events(h).contains(.doorsOpen(4)))
        #expect(events(h).contains(.boarded("chair.1", floor: 4, destination: 9)))
        let arrived = try #require(h.first { $0.event == .arrived(4) })
        #expect(abs(arrived.at.timeIntervalSince(at(runTime))) < 1e-6)
        #expect(c.rider("chair.1")?.destination == 9)
    }

    @Test func itNeverMovesWithoutARequestAndStaysPutWhenDone() {
        let c = car(at: 7)
        // Nothing asked: ten minutes, nothing.
        #expect(run(c, from: 0, to: 600, step: 5).isEmpty)
        #expect(c.position(now: at(600))?.floor == 7)
        #expect(c.position(now: at(600))?.doors == .closed)
        // One trip, then nothing again: it stays where the trip ended, doors shut.
        c.call("chair.1", at: 7, to: 3, now: at(600))
        let h = run(c, from: 600, to: 640)
        #expect(events(h).contains(.alighted("chair.1", floor: 3)))
        let after = run(c, from: 640, to: 1240, step: 5)
        #expect(after.isEmpty)
        #expect(c.position(now: at(1240))?.floor == 3)
        #expect(c.position(now: at(1240))?.doors == .closed)
        #expect(c.position(now: at(1240))?.moving == false)
    }

    @Test func itNeverTeleports() {
        let c = car(at: 1)
        c.call("a", at: 16, to: 2, now: t0)
        c.call("b", at: 9, to: 14, now: at(1))
        var last: Double?
        run(c, from: 0, to: 120, step: 0.05) { _, p in
            if let l = last { #expect(abs(p.exact - l) <= 1.0001, "jumped from \(l) to \(p.exact)") }
            last = p.exact
        }
        #expect(c.state?.calls.isEmpty == true)
        #expect(c.state?.riders.isEmpty == true)
    }

    @Test func severalRequestsAreAllServedNearestAheadFirst() throws {
        let c = car(at: 5)
        c.call("a", at: 8, to: 10, now: t0)
        c.call("b", at: 3, to: 1, now: t0)
        c.call("c", at: 6, to: 12, now: t0)
        let h = run(c, from: 0, to: 200)
        let stops = h.compactMap { if case .arrived(let f) = $0.event { return f } else { return nil } }
        // Up first (the nearest, 6, then 8, 10, 12 -- its way), then down for b.
        #expect(stops == [6, 8, 10, 12, 3, 1])
        for who in ["a", "b", "c"] {
            #expect(h.contains { if case .alighted(who, _) = $0.event { return true } else { return false } }, "\(who) delivered")
        }
        #expect(c.state?.calls.isEmpty == true && c.state?.riders.isEmpty == true)
    }

    @Test func aRequestDuringARunIsRememberedAndServed() {
        let c = car(at: 1)
        c.call("a", at: 12, to: 14, now: t0)
        run(c, from: 0, to: 1)
        #expect(c.position(now: at(1))?.moving == true)
        // Asked while it runs: it finishes its run (nobody loses a destination), then comes.
        c.call("b", at: 3, to: 2, now: at(1))
        let h = run(c, from: 1, to: 200)
        let stops = h.compactMap { if case .arrived(let f) = $0.event { return f } else { return nil } }
        #expect(stops.first == 12)
        #expect(stops.contains(14))
        #expect(stops.contains(3) && stops.contains(2))
        #expect(events(h).contains(.alighted("a", floor: 14)))
        #expect(events(h).contains(.alighted("b", floor: 2)))
    }

    @Test func ridersWithDifferentFloorsEachGetOutAtTheirOwn() {
        let c = car(at: 2)
        c.call("a", at: 2, to: 11, now: t0)
        c.call("b", at: 2, to: 8, now: t0)
        let h = run(c, from: 0, to: 120)
        #expect(events(h).contains(.alighted("b", floor: 8)))
        #expect(events(h).contains(.alighted("a", floor: 11)))
        let i8 = h.firstIndex { $0.event == .alighted("b", floor: 8) }!, i11 = h.firstIndex { $0.event == .alighted("a", floor: 11) }!
        #expect(i8 < i11)                                                  // (8 on the way to 11)
    }

    @Test func aWaitingResidentIsNeverGivenUpOn() {
        let c = car(at: 16)
        // A body at the doors on the player's floor (acting): the car comes, waits for it a while...
        c.call("slow", at: 1, to: 6, now: t0)
        let h = run(c, from: 0, to: 60, acting: ["slow"])
        #expect(events(h).contains(.doorsOpen(1)))
        // ...it never got in: the doors closed, but its call stands -- no expiry.
        #expect(c.callOf("slow") != nil)
        // Ten minutes later it's still waiting -- and whenever the car opens for it, it can get in.
        run(c, from: 60, to: 660, step: 5, acting: ["slow"])
        #expect(c.callOf("slow") != nil)
        c.call("slow", at: 1, to: 6, now: at(660))                       // (at the doors again)
        var t = 660.0
        while t < 720, c.position(now: at(t))?.doors != .open { t += 0.25; c.advance(to: at(t), acting: ["slow"]) }
        #expect(c.position(now: at(t))?.doors == .open)
        #expect(c.board("slow", destination: 6, now: at(t)))
        #expect(c.rider("slow")?.destination == 6)
    }

    @Test func aBodyWalkingThroughKeepsTheDoorsOpen() {
        let c = car(at: 3)
        c.call("walker", at: 3, to: 5, now: t0)
        run(c, from: 0, to: BuildingElevator.doorOpenSeconds + 0.1, acting: ["walker"])
        #expect(c.position(now: at(2))?.doors == .open)
        c.hold("walker", until: at(9))
        run(c, from: 2, to: 8.5, acting: ["walker"])
        #expect(c.position(now: at(8.5))?.doors == .open)                  // (past the dwell, still someone in the doorway)
        #expect(c.board("walker", destination: 5, now: at(8.5)))
        let h = run(c, from: 8.5, to: 40)
        #expect(events(h).contains(.doorsClosing(3)))
        #expect(events(h).contains(.alighted("walker", floor: 5)))
    }

    // MARK: The player

    @Test func thePlayersTapCallsTheCarAndItComesToThem() {
        let c = car(at: 12)
        #expect(!c.isHere(4))                                              // (the gate: not here -- call it)
        c.call("player", at: 4, to: nil, now: t0)
        let h = run(c, from: 0, to: ElevatorTiming.run(floors: 8) + BuildingElevator.doorOpenSeconds + 0.3)
        #expect(events(h).contains(.arrived(4)))
        #expect(events(h).contains(.doorsOpen(4)))
        #expect(c.isHere(4))
        // The player takes the doors (their own boarding): their call ends; nobody "boards" for them.
        let t = c.take(.player, name: "player", at: 4, now: at(20))
        #expect(t.map(\.event) == [.callEnded("player", floor: 4)])
        #expect(c.state?.owner == .player)
        #expect(!h.contains { if case .boarded("player", _, _) = $0.event { return true } else { return false } })
    }

    @Test func thePlayerAndAResidentShareARideAndEachGetsTheirFloor() throws {
        let c = car(at: 4)
        c.take(.player, name: "player", at: 4, now: t0)
        c.mirrorDoors(.opening, now: at(0.1))
        c.mirrorDoors(.open, now: at(1.8))
        // A resident walks in while the player holds the doors (its body: acting).
        c.call("chair.1", at: 4, to: 8, now: at(2))
        #expect(c.board("chair.1", destination: 8, now: at(4)))
        c.restoreRider("player", destination: nil, now: at(2))
        // Nothing moves while the player stands in the open cab.
        #expect(run(c, from: 4, to: 60, acting: ["chair.1"]).allSatisfy { if case .departed = $0.event { return false } else { return true } })
        // The player chooses 12; their doors shut; the car runs there -- straight (it never
        // stops at a floor the player didn't choose).
        c.mirrorDoors(.closing, now: at(60))
        c.mirrorDoors(.closed, now: at(61.6))
        let go = c.playerRuns(to: 12, now: at(62))
        #expect(go.map(\.event) == [.departed(from: 4, to: 12)])
        let ride = run(c, from: 62, to: 62 + ElevatorTiming.run(floors: 8) + 1)
        #expect(events(ride).contains(.arrived(12)))
        #expect(!events(ride).contains(.arrived(8)))
        #expect(c.position(now: at(62 + ElevatorTiming.run(floors: 8) + 1))?.doors == .closed)    // (the player's doors: theirs to open)
        // Arrived: the player's doors open; the resident (for 8) stays aboard.
        c.playerArrived(at: 12, now: at(70))
        c.mirrorDoors(.opening, now: at(70))
        c.mirrorDoors(.open, now: at(71.7))
        #expect(c.rider("chair.1")?.destination == 8)
        // The player steps out; their doors shut behind them; the car is the building's again...
        c.mirrorDoors(.closing, now: at(75))
        c.mirrorDoors(.closed, now: at(76.6))
        c.alight("player", now: at(76.6))
        c.giveBack(now: at(76.6))
        // ...and takes the resident on to its own floor.
        let on = run(c, from: 77, to: 120)
        #expect(events(on).contains(.departed(from: 12, to: 8)))
        #expect(events(on).contains(.alighted("chair.1", floor: 8)))
    }

    // MARK: Saved with the game

    @Test func aRunUnderWaySurvivesARelaunch() throws {
        let storage = ThrowawayStorage()
        let c = car(at: 2)
        c.call("a", at: 2, to: 15, now: t0)
        run(c, from: 0, to: BuildingElevator.doorOpenSeconds + BuildingElevator.dwell + BuildingElevator.doorCloseSeconds + 0.5)
        #expect(c.position(now: at(8))?.moving == true)
        // (the player had a call in too: it doesn't survive a relaunch -- they start on a floor)
        c.call("player", at: 9, to: nil, now: at(8))
        c.save(to: storage.defaults)
        let again = BuildingElevator()
        #expect(again.load(from: storage.defaults))
        #expect(again.state?.target == 15)
        #expect(again.state?.departed == c.state?.departed)
        #expect(again.rider("a")?.destination == 15)
        #expect(again.callOf("player") == nil)
        // It carries on exactly where it was: same floor reached at the same moment, then delivers.
        #expect(again.position(now: at(9))?.floor == c.position(now: at(9))?.floor)
        let h = run(again, from: 9, to: 60)
        #expect(events(h).contains(.alighted("a", floor: 15)))
        // Nothing saved: no car.
        #expect(!BuildingElevator().load(from: ThrowawayStorage().defaults))
    }

    // MARK: Building Life sees the same car

    @Test func buildingLifeDrawsTheCarAsItIs() throws {
        let c = car(at: 3)
        c.call("chair.1", at: 3, to: 10, now: t0)
        c.call("b", at: 7, to: 1, now: t0)
        run(c, from: 0, to: 7)
        let p = try #require(c.position(now: at(7)))
        let shown = try #require(BuildingLifeModel.carDisplay(p))
        #expect(shown.floor == p.floor && shown.direction == p.direction)
        #expect(shown.occupants == ["chair.1"])
        #expect(shown.calls.contains(7))
        #expect(!shown.players)
        // Doors open at a stop: drawn open.
        c.restore(BuildingElevator.State(floor: 7, doors: .open, doorsSince: t0, clock: t0))
        #expect(BuildingLifeModel.carDisplay(c.position(now: t0))?.doorsOpen == true)
    }

    // MARK: The doors, heard

    @Test func eachDoorMovementIsHeardOnce() {
        var m = ElevatorDoorMotion(fraction: 0)
        var cues: [ElevatorDoorMotion.Cue] = []
        // Standing shut (with a little float noise): nothing.
        for _ in 0..<20 { cues += m.update(fraction: 0.0005) }
        #expect(cues.isEmpty)
        // Opening over 32 samples: one opening sound.
        for i in 1...32 { cues += m.update(fraction: Double(i) / 32) }
        #expect(cues == [.opening])
        #expect(m.phase == .opening || m.phase == .open)
        // Standing open: nothing more.
        for _ in 0..<40 { cues += m.update(fraction: 1) }
        #expect(cues == [.opening])
        #expect(m.doors == .open)
        // Closing: one closing sound, and the clunk exactly once as they meet.
        for i in stride(from: 31, through: 0, by: -1) { cues += m.update(fraction: Double(i) / 32) }
        for _ in 0..<20 { cues += m.update(fraction: 0) }
        #expect(cues == [.opening, .closing, .shut])
        #expect(m.doors == .closed)
        // Reopened while closing (a threshold swipe): the opening sound again, no clunk.
        cues = []
        for i in 1...16 { cues += m.update(fraction: Double(i) / 32) }
        for i in stride(from: 15, through: 8, by: -1) { cues += m.update(fraction: Double(i) / 32) }
        for i in 9...32 { cues += m.update(fraction: Double(i) / 32) }
        #expect(cues == [.opening, .closing, .opening])
    }
}
