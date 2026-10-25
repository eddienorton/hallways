//
//  ElevatorBoard.swift
//  Hallways
//
//  Oct 18 (inter-floor life) -- THE ELEVATOR, AS IT REALLY IS, READ OUT.
//  Oct 19 (elevator overhaul) -- and the player's floor joined to THE car.
//
//  The car is BuildingElevator (ElevatorScheduler.swift): one state, worked
//  forward four times a second by BuildingLife.elevatorStep. This file is
//  where the floor the player is on meets it:
//
//    attach        a floor's controller is told how to ask for the car (its
//                  `carGate`: here -> the doors are yours; elsewhere -> called),
//                  when the player's ride sets off (`onElevatorTravel`), and its
//                  doors are made audible (ElevatorDoorSound).
//    syncPlayer    the player's (or a scripted character's) own doors and ride,
//                  told to the car: whose doors, how open, the run to the floor
//                  chosen, the arrival, the stepping out.
//    present       the car's own stops on this floor shown: its doors opening
//                  and closing for someone else; the player's call answered when
//                  the car opens here; the hall sign; the shaft; the panel.
//
//  Nothing here moves the car or decides anything about it.
//

import Foundation
import SceneKit      // (the shaft sound plays on the elevator surround)

enum ElevatorBoard {
    /// The floor being shown's controller (FloorPresenter sets it).
    static weak var controller: TapNavigationController?

    /// An older save's resident ride, as its booked times had it (used only to
    /// carry such a save over: BuildingLife.migrateLegacyLegs).
    struct Ride: Equatable {
        let id: String
        let from: Int
        let to: Int
        let boardAt: Date
        let alightAt: Date
        var direction: Int { to > from ? 1 : (to < from ? -1 : 0) }
        /// The floor that booked ride had reached at `now`.
        func floorReached(at now: Date) -> Int {
            let steps = abs(to - from)
            let span = alightAt.timeIntervalSince(boardAt)
            guard steps > 0, span > 0 else { return to }
            let elapsed = max(0, now.timeIntervalSince(boardAt)) * ElevatorTiming.ride(floors: steps) / span
            return from + direction * ElevatorTiming.floorsDone(of: steps, after: elapsed)
        }
    }

    // MARK: Attach (a floor built)

    /// The player tapped while the car was elsewhere: their call, on this floor.
    private static var playerCall: (floor: Int, at: Date)?
    /// The car is the player's but stands on a floor they aren't on (since when).
    private static var playerAwaySince: Date?

    static func attach(_ c: TapNavigationController) {
        let life = BuildingLife.shared
        c.carGate = { [weak c] floor, who in
            let car = life.car, now = BuildingClock.now()
            guard car.state != nil else { return true }                       // (no car placed yet: as before)
            if car.isHere(floor), car.state?.owner == .building || car.state?.ownerName == who {
                let owner: BuildingElevator.Owner = who == "player" ? .player : .script
                life.apply(car.take(owner, name: who, at: floor, now: now), now: now)
                if who == "player" { playerCall = nil }
                life.saveCar()
                LifeLog.event(who, "elevator.doorsTaken", floor: floor, ["car": car.position(now: now)?.state])
                return true
            }
            car.call(who, at: floor, to: nil, now: now)
            life.saveCar()
            if who == "player" { playerCall = (floor, now) }
            LifeLog.event(who, "elevator.called", floor: floor,
                          ["car": car.position(now: now).map { "F\($0.floor) \($0.state)" }, "controllerFloor": c?.elevatorFloor])
            return false
        }
        c.onElevatorTravel = { from, to in
            let car = life.car, now = BuildingClock.now()
            guard car.state?.owner == .player, car.isHere(from) else {
                LifeLog.warn("player", "elevator.travelNotOwned", floor: from, ["to": "F\(to)", "car": car.position(now: now)?.state])
                return
            }
            life.apply(car.playerRuns(to: to, now: now), now: now)
            life.saveCar()
        }
        c.doorwayBusy = { life.car.doorwayBusy(now: BuildingClock.now()) }
        // Oct 20 (sharing the car): the player swiping in through a resident's open
        // doors holds them open, as a resident walking through them does.
        c.holdCarDoorway = { hold in
            if hold { life.car.hold("player", until: BuildingClock.now().addingTimeInterval(3)) } else { life.car.release("player") }
        }
        c.enableDoorSounds()
    }

    // MARK: The player's doors and ride, told to the car

    /// Four times a second. Returns what the car did as a result (BuildingLife applies it).
    static func syncPlayer(car: BuildingElevator, now: Date, acting: Set<String>, actingFloor: Int?) -> [BuildingElevator.Happening] {
        guard let s = car.state else { return [] }
        guard let c = controller else {
            // No floor shown (between scenes, the editor): whoever had the doors gets
            // 20 s to come back, then they're the building's again -- the car never freezes.
            if s.owner != .building, s.target == nil {
                playerAwaySince = playerAwaySince ?? now
                if now.timeIntervalSince(playerAwaySince!) > 20 {
                    car.alight("player", now: now)
                    car.giveBack(now: now)
                    playerAwaySince = nil
                    LifeLog.event(s.ownerName ?? "player", "elevator.doorsReturned", floor: s.floor, ["why": "no floor shown for 20 s"])
                }
            }
            return []
        }
        let here = c.elevatorFloor
        var out: [BuildingElevator.Happening] = []
        // In the cab on this floor and the car isn't theirs yet: the cab has arrived.
        if c.playerInCab, s.owner != .player || s.target == here {
            if s.target == here || (s.target == nil && s.floor == here) {
                out += car.playerArrived(at: here, now: now)
                LifeLog.event("player", "elevator.arrivedWithCar", floor: here, [:])
            } else if s.owner == .building, s.target == nil, c.arrivedElevatorDoorOpenForCar {
                // (a relaunch straight into a cab the car was never at -- a controlled
                // reconstruction: the car is put here, said so; never in normal play)
                var moved = s
                moved.floor = here
                moved.doors = .closed
                car.restore(moved)
                out += car.playerArrived(at: here, now: now)
                LifeLog.warn("player", "elevator.reconstructed", floor: here, ["was": "F\(s.floor)", "why": "the player is in the cab here at launch"])
            }
        }
        guard let now2 = car.state else { return out }
        switch now2.owner {
        case .player:
            if c.playerInCab, car.isHere(here), car.rider("player") == nil {
                car.restoreRider("player", destination: c.elevatorDestinationFloor, now: now)
            }
            // (a ride that reached this floor without telling the car it set off -- a
            // ride path with no panel: the car runs here now, never jumps)
            if c.playerInCab, now2.target == nil, now2.floor != here, c.arrivedElevatorDoorOpenForCar {
                LifeLog.warn("player", "elevator.lateRun", floor: here, ["from": "F\(now2.floor)"])
                out += car.playerRuns(to: here, now: now)
            }
            if car.isHere(here) { out += car.mirrorDoors(c.elevatorDoorPhaseForCar, now: now, acting: acting, actingFloor: actingFloor) }
            // Out, and the doors shut behind them: the building's again. (Their scene
            // gone some other way -- Start Over, the editor -- for 20 s: the same.)
            if now2.target == nil, now2.floor == here { playerAwaySince = nil } else if now2.target == nil { playerAwaySince = playerAwaySince ?? now }
            let away = playerAwaySince.map { now.timeIntervalSince($0) > 20 } ?? false
            if now2.target == nil, !c.playerInCab, (now2.floor == here && c.elevatorDoorsShut && !c.doorsClosingBehindPlayer) || away {
                car.alight("player", now: now)
                car.giveBack(now: now)
                playerAwaySince = nil
                LifeLog.event("player", "elevator.doorsReturned", floor: now2.floor, ["riders": car.state?.riders.map { $0.who }.joined(separator: ","),
                                                                                       "away": away])
            }
        case .script:
            if car.isHere(here) { out += car.mirrorDoors(c.elevatorDoorPhaseForCar, now: now, acting: acting, actingFloor: actingFloor) }
            if !c.characterUsingElevator, c.elevatorDoorsShut || !car.isHere(here) {
                car.giveBack(now: now)
                LifeLog.event(now2.ownerName ?? "script", "elevator.doorsReturned", floor: now2.floor, [:])
            }
        case .building:
            break
        }
        return out
    }

    // MARK: The car shown on the player's floor

    static func present(life: BuildingLife, now: Date) {
        guard let c = controller else { return }
        let car = life.car
        let here = c.elevatorFloor
        let at = car.position(now: now)
        // The building's doors on this floor: open while the car stands here with its
        // doors open for someone else; otherwise shut (never open on an empty shaft).
        // (The player's or a character's own doors here: theirs -- not touched.)
        if let s = car.state, !(s.owner != .building && s.target == nil && s.floor == here) {
            let standing = s.owner == .building && s.target == nil && s.floor == here
            c.runCarDoors(open: standing && (s.doors == .opening || s.doors == .open))
        }
        if let s = car.state, s.owner == .building, s.target == nil, s.floor == here {
            // The player called it here and is at the doors: once they're open, in they go (the same boarding).
            if let call = playerCall, call.floor == here, s.doors == .open {
                if c.playerAtElevatorCell, !c.isAnimating {
                    playerCall = nil
                    LifeLog.event("player", "elevator.callAnswered", floor: here, [:])
                    c.openElevator()
                }
            }
        }
        if let call = playerCall, call.floor != here || car.callOf("player") == nil, car.state?.owner != .player {
            playerCall = nil                                                  // (the car came and went, or they left the floor)
        }
        // Oct 23 (critters call the car): a resident's call from this floor lights its
        // way's button too (pressed in front of you, or standing when you came) -- the
        // dispatcher's own calls, so the lamp says exactly what the car will answer.
        let residentWays = Set((car.state?.calls ?? []).compactMap { call -> Int? in
            guard call.who != "player", call.floor == here, let to = call.destination, to != here else { return nil }
            return to > here ? 1 : -1
        })
        for way in residentWays { c.showResidentHallCall(way) }
        // Oct 22 (hall call): the hall's lit button goes out once no call of the player's stands
        // (Oct 23: nor any resident's from here).
        c.syncHallCall(callStanding: playerCall != nil || car.callOf("player") != nil || !residentWays.isEmpty)
        // The hall sign over the doors: the car's floor and way (the player's own ride: as built).
        if c.playerElevatorState == nil, let at {
            c.showHallIndicator(floor: at.floor, direction: at.direction)
        } else {
            c.showHallIndicator(floor: here, direction: 0)
        }
        shaftSound(controller: c, car: at, now: now)
        if LifePanel.enabled { LifePanel.updateElevator(lines(life: life, controller: c, now: now)) }
    }

    // Oct 18 (open the building): the car heard moving in its shaft (Oct 19: once per approach, quietly).
    private static var nextRumble = Date.distantPast

    /// Oct 22: OFF FOR NOW -- the suspected "moo" (a 3.6 s, ~98 Hz harmonic tone that
    /// swells and glides: ElevatorShaftSound.rumble). Switched off to find out whether
    /// it's the recurring moo heard on Floor 11; nothing else about the car changes
    /// (its doors, chimes, the ride, the indicators). Back on: `-HallwaysShaftRumble YES`
    /// (or make this `true`). The sound itself (ResidentSounds.swift) is untouched.
    static var shaftRumbleEnabled: Bool { UserDefaults.standard.bool(forKey: "HallwaysShaftRumble") }

    static func shaftSound(controller c: TapNavigationController, car at: BuildingElevator.Position?, now: Date) {
        guard shaftRumbleEnabled else { return }                              // (Oct 22: off -- see above)
        let here = c.elevatorFloor
        guard c.playerElevatorState == nil, !Admission.isQuietOnboarding(floor: here), let at, at.owner != .player, at.moving,
              now >= nextRumble, let away = ElevatorShaftSound.audible(carFloor: at.floor, direction: at.direction, here: here),
              let node = c.elevatorExteriorNode, node.parent != nil,
              let sound = ElevatorShaftSound.rumble(floorsAway: away) else { return }
        nextRumble = now.addingTimeInterval(Double(ElevatorShaftSound.seconds) + 0.6)   // (one at a time: never overlapping)
        CritterAudio.play(sound, on: node)
    }

    /// What the hall indicator on floor `floor` should show (nil: as built).
    /// The player's own ride wins (they're in the cab); then the car.
    static func indicator(floor: Int, playerUsing: Bool, car: BuildingElevator.Position?) -> (floor: Int, direction: Int)? {
        if playerUsing { return nil }
        return car.map { ($0.floor, $0.direction) }
    }

    private static func name(_ id: String) -> String {
        id.split(separator: ".").first.map { String($0).uppercased() } ?? id
    }
    private static func arrow(_ d: Int) -> String { d > 0 ? "UP" : (d < 0 ? "DOWN" : "IDLE") }

    /// The ELEVATOR panel (DEBUG): the car as it is.
    static func lines(life: BuildingLife, controller c: TapNavigationController, now: Date) -> [String] {
        let car = life.car
        var out = ["ELEVATOR   (one car: BuildingElevator)"]
        guard let at = car.position(now: now) else { return out + ["CAR  not placed yet"] }
        out.append("CAR  F\(at.floor) \(arrow(at.direction))  \(at.state)  doors \(at.doors.rawValue)  owner \(at.owner.rawValue)"
                   + (at.target.map { "  -> F\($0)" } ?? ""))
        out.append("IN IT  " + (at.riders.isEmpty ? "nobody" : at.riders.map { "\(name($0.who))->F\($0.destination.map(String.init) ?? "?")" }.joined(separator: ", ")))
        if at.calls.isEmpty {
            out.append("WAITING  nobody")
        } else {
            for (i, call) in at.calls.prefix(6).enumerated() {
                out.append("WAITING \(i + 1). \(name(call.who)) at F\(call.floor)" + (call.destination.map { " for F\($0)" } ?? "")
                           + " (\(LifeLog.seconds(now.timeIntervalSince(call.since))))" + (call.missedAt != nil ? " missed" : ""))
            }
        }
        if let call = playerCall { out.append("PLAYER CALL  F\(call.floor), \(LifeLog.seconds(now.timeIntervalSince(call.at))) ago") }
        if let refusal = c.playerElevatorRefusal {
            out.append("PLAYER TAP: no -- \(refusal)")
        } else {
            out.append(car.isHere(c.elevatorFloor) ? "PLAYER TAP: the doors open (the car is here)" : "PLAYER TAP: calls the car")
        }
        let shown = c.hallIndicatorShown
        out.append("HALL SIGN F\(c.elevatorFloor): " + (shown.map { "\($0.floor) \(arrow($0.direction))" } ?? "\(c.elevatorFloor) idle"))
        return out
    }
}
