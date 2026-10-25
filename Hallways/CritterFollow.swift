//
//  CritterFollow.swift
//  Hallways
//
//  Oct 20 -- TAP A CRITTER TO FOLLOW IT.
//
//    Tap a roaming resident (a Hallwaysian, the chair, a critter, the
//    butterfly when she isn't guiding) -- follow it. Tap it again -- stop.
//    Tap another -- follow that one instead. Any other tap while following is
//    an ordinary tap (it brakes the walk, as always) and ends the following.
//    So does steering by hand, or a scripted scene starting.
//
//  NO NEW MOVEMENT SYSTEM: the player walks the existing escort walk (the
//  continuous walk that follows Mr. Tinky -- its corners, doors, collisions,
//  pace and following gap). This only tells it, a few times a second, the way
//  to the critter from where the player is (the floor plan's own route, the
//  one residents walk) and where the critter stands, and starts the walk again
//  when it has stopped (a dead end, the critter turned back, a door).
//
//  ITS RIDE: when the critter steps into the elevator, the way leads to the
//  elevator; there the walk boards it with the player's own boarding (the
//  car's doors, if they're still open, or a call -- never a jump). In the cab,
//  the critter's floor is pressed for the player -- the ID reader and all
//  (refused: the following ends there). Arrived, the player steps out when
//  the critter has, and following goes on. If the car left with the critter
//  before the player got there, the player calls it and rides to where the
//  critter went.
//
//  Mr. Tinky's escort is never touched: no following while a scripted escort
//  (or the meeting, the office desk, an eviction) is on, and he isn't a resident.
//  Oct 24 -- EXCEPT HIM: his escort now runs on FOLLOW (GuidedJourney: he is a
//  followable presentation while it does). During it he alone can be followed
//  (allowed(for:)); everyone else is refused as before. Three things differ for
//  him, all asked of GuidedJourney: once he has called the car the walk goes to
//  its doors (followGoesToElevator); boarding and riding, the cab is left to the
//  scripted ride (Floor 3 is pressed for the player there, never here); arrived,
//  the player steps out once he has (guideHasLeftCab).
//
//  Oct 20 (later, iPhone: "tapping critters does absolutely nothing") -- WHY:
//    1. A tap at close range DID start following, but nothing showed it: no
//       acknowledgment, a faint haptic, and the player stays put while the
//       critter is within the following gap (it was standing at an activity).
//       The second tap stopped it just as invisibly.
//    2. With the critter anywhere but straight ahead, the walk never set off:
//       the "it turned back" check compared the way to it with the CAMERA's
//       heading -- which, while the walk is still turning to its start
//       heading, is the old way -- and stopped the walk every tick (0.25 s),
//       restarted it, stopped it again.
//    3. Any informant guiding (the butterfly, now and then while Floor 5's
//       lights are out) refused following altogether, silently.
//  FIX: the critter acknowledges the tap at once (acknowledgeFollower -- a
//  little come-hither of its own kind); the turn-back check uses the walk's
//  own heading and waits until the walk is under way; only the guiding
//  butterfly herself is unfollowable.
//
//  Oct 20 (tasks) -- THE CRITTER LEADS: following one now also gives it a task
//  (TaskGuide, TaskRegistry.swift) and it sets off for that task's destination,
//  on its own floor or by the car to another; the follow walk below goes after
//  it as before. Arriving ends its guiding -- never the task itself (and, since
//  Oct 22, not this following either: the player stays with it). Switching
//  critters releases the first guide; stopping (a tap, a scripted scene, the
//  elevator refusing) releases it too.
//
//  Oct 20 (evening, iPhone: "sticky, extremely slow following") -- WHAT IT WAS:
//    1. Following FOUGHT the player's own hands. Any drag (looking round) stops
//       the walk (ContentView's pan: "gestures take over"); this tick then tried
//       to start it again four times a second while the finger was still down
//       (each refused: "gesture"), and the instant the finger lifted it started
//       -- turning the view straight back onto the way to the critter. Looking
//       round while following was yanked back again and again.
//    2. The walk only held its following gap with the critter DEAD AHEAD. Round
//       a corner (the critter off to the side) nothing held it: it sprinted at
//       its full pace to the corner, then braked hard once the critter was ahead
//       again -- surge, brake, crawl, at every turn.
//    3. Its pace is the critter's: the gap brake holds the player to whatever
//       the critter walks at -- its ordinary resident pace (Hallwaysians about
//       0.65-0.75 m/s, the chair 0.6, Pottle 0.35; Mr. Tinky leads at 2.8). The
//       guide walks exactly as it does roaming (the same walk); nothing slows it.
//    (And the come-hither was cut off: the guide's walk began in the same moment,
//    and a walk clears any gesture. Now the task is given first, then the
//    gesture plays on its way.)
//  FIX: the follow walk is never restarted while the player touches the screen,
//  nor until a moment after they let go (handsOffGrace); following a critter the
//  gap holds with it ahead or round to the side (TapNavigationController
//  .leaderHolds); and a light meter (one [Follow] line every 5 s while
//  following) says how fast each of them is really going, how often the walk
//  restarted, and the worst main-thread stall seen -- for the iPhone check.
//

import Foundation
import SceneKit
import UIKit
import simd

enum CritterFollow {
    /// Who is being followed (nil: nobody).
    private(set) static var targetID: String?
    private static var timer: Timer?
    private static var lastElevatorAsk = Date.distantPast
    private static var pressedFor: (floor: Int, at: Date)?
    /// When this following last (re)started the walk (the turn-back check waits a moment after it).
    private static var walkStartedAt = Date.distantPast
    /// The walk has had this long to turn onto its way before "it turned back" can stop it.
    static let turnBackGrace: TimeInterval = 1.0
    /// Evening, Oct 20: after the player's own hands (a look round, a drag) the follow
    /// walk waits this long before it takes over again -- never while a finger is down.
    /// (Night: 1.2 s was more than needed. The finger-down check is what stops the
    /// fight; this is only a beat for the drag's own settle to finish and the eye to
    /// land before the walk turns the view back toward the critter -- a smooth turn,
    /// the walk's own, never a snap.)
    static let handsOffGrace: TimeInterval = 0.4
    private static var lastManualAt = Date.distantPast
    private static var meter = FollowMeter()

    /// The tick's pace (seconds).
    static let interval: TimeInterval = 0.25
    /// Close enough: it stands this far ahead (metres, the escort's own gap + a little).
    static var closeEnough: Double { TapNavigationController.escortFollowGap + 0.7 }

    // MARK: Taps

    /// A tap in the world: on a roaming resident -> follow / stop / switch (true:
    /// consumed). Anywhere else while following: following ends and the tap goes
    /// on as an ordinary tap (false).
    static func handleTap(at point: CGPoint, in view: SCNView, controller: TapNavigationController) -> Bool {
        let perf = PerfMonitor.begin("follow.tapResolve"); defer { PerfMonitor.end(perf) }
        let resolution = CritterTapTarget.resolve(at: point, in: view, controller: controller)
        // Oct 24: allowed for whoever this tap concerns -- the critter tapped, else the one followed
        // (Tinky on his escort: yes; anyone else during it: no, as before).
        var tappedID: String?
        if case .resident(let id, _) = resolution { tappedID = id }
        guard allowed(for: tappedID ?? targetID) else {
            if case .resident(let id, let how) = resolution {
                // On a critter, but a scripted scene has the player (the escort, the meeting...): an ordinary tap.
                diag("follow.tapRefused", ["who": id, "how": how, "why": blocker(for: id) ?? "?",
                                           "point": String(format: "%.0f,%.0f", point.x, point.y)])
            }
            if let was = targetID {
                stop(reason: "a scripted scene")
                if GuidedJourney.isGuideID(was) {                                // (Oct 24: said, as any stop is)
                    controller.showBrief("Stopped following \(CharacterRegistry.identity(was)?.name ?? "Tinky")", seconds: 1.4)
                }
            }
            CritterMenuModel.shared.close()                  // Oct 23 (menu): never over a scripted scene
            return false
        }
        guard case .resident(let id, let how) = resolution else {
            if case .miss(let report) = resolution, let report { diag("follow.tapMiss", report.fields) }
            // Oct 23 (menu): a tap elsewhere with the menu open only puts the menu away
            // (the tap still walks, as any tap; following carries on).
            if CritterMenuModel.shared.target != nil {
                CritterMenuModel.shared.close()
                return false
            }
            if let was = targetID {
                stop(reason: "tapped elsewhere")
                // Oct 22 (stability pass): a deliberate tap ends it -- said so, and (identities
                // on) its goodbye, the same as tapping it again. (Was silent: a tap that just
                // missed it ended the following with no word and no goodbye, so the next tap
                // on it "followed" again -- the repeated greeting heard on Floor 12.)
                let name = CharacterRegistry.identity(was)?.name ?? "it"
                controller.showBrief("Stopped following \(name)", seconds: 1.4)
                if !GuidedJourney.isGuideID(was) { ResidentMusic.farewell(was) }       // (Oct 24: no music for him yet)
            }
            return false
        }
        diag("follow.tapHit", ["who": id, "how": how, "point": String(format: "%.0f,%.0f", point.x, point.y)])
        // Oct 23 (menu): a tap on a critter opens its menu -- FOLLOW (tapped(), as before),
        // FOLLOW ME, LISTEN, DISMISS (CritterMenu.swift).
        CritterMenuModel.shared.open(id, controller: controller)
        return true
    }

    /// Why following isn't allowed now (nil: it is) -- for the tap diagnostics.
    static var followingBlocker: String? { blocker(for: nil) }

    /// Oct 24: why following `id` isn't allowed now (nil: it is). Tinky, while his
    /// escort can be followed, is exempt from the escort's own rules.
    static func blocker(for id: String?) -> String? {
        let escortExempt = GuidedJourney.isGuideID(id) && GuidedJourney.followableBody != nil
        if GuidedJourney.trip != nil, !escortExempt { return "escort under way" }
        if CharacterLead.activeGuidedRoute != nil, !escortExempt { return "a guided route" }
        if ConferenceMeeting.isActive { return "the meeting" }
        if OfficeComputer.shared.isActive { return "at the office computer" }
        if BonzoEviction.isActive { return "eviction" }
        return nil
    }

    /// What a tap on resident `id` does (pure): follow it, stop following it, or
    /// switch to it from whoever is followed now.
    enum TapOutcome: Equatable {
        case follow(String)
        case unfollow(String)
        case switchTo(from: String, to: String)
    }

    static func outcome(tapping id: String, following current: String?) -> TapOutcome {
        guard let current else { return .follow(id) }
        return current == id ? .unfollow(id) : .switchTo(from: current, to: id)
    }

    /// A tap on resident `id`'s body: follow / stop / switch. Following (or
    /// switching) is acknowledged at once by the critter -- once; stopping isn't.
    static func tapped(_ id: String, controller: TapNavigationController) {
        let what = outcome(tapping: id, following: targetID)
        diag("follow.tap", ["who": id, "outcome": "\(what)"])
        TaskLog.line("critter.tapped", ["critter": id, "outcome": "\(what)", "floor": controller.elevatorFloor])
        let name = CharacterRegistry.identity(id)?.name ?? "it"
        switch what {
        case .unfollow:
            // Oct 22: unmistakably "stopped" -- a soft double tick and a word (never the critter's voice;
            // Oct 22, morning: with the musical identities on, its goodbye -- its signature an octave down).
            let soft = UIImpactFeedbackGenerator(style: .soft)
            soft.impactOccurred(intensity: 0.7)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { soft.impactOccurred(intensity: 0.45) }
            stop(reason: "tapped it again")
            controller.stopContinuousWalk(reason: "unfollow")
            controller.showBrief("Stopped following \(name)", seconds: 1.4)
            if !GuidedJourney.isGuideID(id) { ResidentMusic.farewell(id) }         // (Oct 24: Tinky -- no music yet)
        case .follow, .switchTo:
            // Oct 22: unmistakably "following" -- a firm tick, a word, and the critter's own come-hither.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            controller.showBrief("Following \(name)", seconds: 1.4)
            // (whatever walk was going -- a tap walk, a latched walk, another follow -- gives way)
            if controller.isFreeTapWalking { controller.stopFreeTapWalk() }
            if controller.isWalkLatched { controller.stopWalkLatch(reason: "follow") }
            controller.stopContinuousWalk(reason: targetID != nil ? "follow switched" : "follow")
            if let old = targetID, old != id {
                TaskGuide.release(old, outcome: .canceled, why: "the player switched to \(id)")      // (back to its own life)
            }
            // (Oct 24: Tinky has a destination of his own -- the escort's -- no task)
            if !GuidedJourney.isGuideID(id) { TaskGuide.assign(guide: id, floor: controller.elevatorFloor) }  // (Oct 20: its task, and off it goes)
            acknowledge(id)                                  // (after: the walk it set off on doesn't cut the come-hither short)
            start(id, controller: controller)
            if GuidedJourney.isGuideID(id) { GuidedJourney.followSelected() }   // (Oct 24: his escort goes on)
        }
    }

    /// The critter's come-hither: once, the moment it is chosen (its own
    /// gesture, a sound of its own; its errand carries on).
    static func acknowledge(_ id: String) {
        guard let p = BuildingLife.shared.presentations.first(where: { $0.residentID == id }) else { return }
        // Oct 22: not again within a few seconds (on, off, on: one come-hither, not a chorus).
        let now = Date()
        if let last = acknowledgedAt[id], now.timeIntervalSince(last) < acknowledgeQuiet {
            // Oct 22 (stability pass): the gesture isn't repeated, but with the identities
            // on its greeting still is (cutting off its goodbye) -- every follow is heard.
            if let body = p.bodyNode, !GuidedJourney.isGuideID(id) { _ = ResidentMusic.greet(id, on: body) }
            diag("follow.acknowledged", ["who": id, "skipped": "just did (gesture)"])
            return
        }
        acknowledgedAt[id] = now
        p.acknowledgeFollower(player: BuildingLife.shared.playerPosition())
        diag("follow.acknowledged", ["who": id])
    }
    private static var acknowledgedAt: [String: Date] = [:]
    static let acknowledgeQuiet: TimeInterval = 4

    /// The roaming resident whose body this node is part of (nil: none -- or one
    /// that can't be followed now: the butterfly while she guides).
    static func residentID(owning node: SCNNode) -> String? {
        for p in BuildingLife.shared.presentations where !p.isGuiding {
            for target in p.tapTargets {
                var n: SCNNode? = node
                while let m = n {
                    if m === target { return p.residentID }
                    n = m.parent
                }
            }
        }
        return nil
    }

    /// Nothing scripted holds the player: no escort (Mr. Tinky's included), no
    /// meeting, desk, eviction. (Oct 20, later: a guiding informant no longer
    /// refuses everyone -- only she herself can't be followed while she guides:
    /// residentID(owning:).)
    static var followingAllowed: Bool { allowed(for: nil) }

    /// Oct 24: following `id` (nil: anyone at all) is allowed now.
    static func allowed(for id: String?) -> Bool { blocker(for: id) == nil }

    // MARK: Following

    static func start(_ id: String, controller: TapNavigationController) {
        targetID = id
        pressedFor = nil
        lastElevatorAsk = .distantPast
        lastManualAt = .distantPast
        meter = FollowMeter()
        diag("follow.start", ["who": id, "floor": controller.elevatorFloor])
        LifeLog.event(id, "follow.started", floor: controller.elevatorFloor, [:])
        attach(controller)
        if timer == nil {
            let t = Timer(timeInterval: interval, repeats: true) { _ in
                MainActor.assumeIsolated { tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        tick()
    }

    static func stop(reason: String) {
        guard let id = targetID else { return }
        targetID = nil
        pressedFor = nil
        timer?.invalidate()
        timer = nil
        diag("follow.stop", ["who": id, "why": reason])
        let failed = reason.hasPrefix("the elevator wouldn't") || reason == "no such resident"
        TaskGuide.release(id, outcome: failed ? .failed : .canceled, why: reason)            // (nothing if it wasn't guiding)
        LifeLog.event(id, "follow.stopped", ["why": reason])
        if GuidedJourney.isGuideID(id) { GuidedJourney.followStopped(reason: reason) }      // (Oct 24: he waits for FOLLOW again)
    }

    /// The floor's controller learns where to go (each floor built, while following).
    static func attach(_ c: TapNavigationController) {
        c.followGuidance = { [weak c] in
            guard let c else { return nil }
            return guidance(for: c)
        }
    }

    /// Where the walk should go now: the cells from the player to the critter
    /// (or to the elevator, after it), and where it stands.
    static func guidance(for c: TapNavigationController) -> (route: [GridCoordinate], leader: SIMD2<Float>?)? {
        guard let id = targetID, let plan = BuildingLife.shared.plans(c.elevatorFloor) else { return nil }
        let goal: GridCoordinate
        var leader: SIMD2<Float>?
        if GuidedJourney.isGuideID(id), GuidedJourney.followGoesToElevator, let e = plan.elevator {
            goal = e                                                     // (Oct 24: he called the car -- to its doors)
        } else if let at = bodyHere(id) {
            let s = plan.cellSize
            var cell = GridCoordinate(row: Int((at.y / s).rounded()), col: Int((at.x / s).rounded()))
            if !plan.cells.contains(cell) { cell = Roam.nearestCell(to: at, in: plan.cells, cellSize: s) ?? cell }
            goal = cell
            leader = at
        } else if let e = plan.elevator {
            goal = e                                                     // (it went by the elevator: after it)
        } else {
            return nil
        }
        let here = c.currentCell
        if here == goal { return ([here, here], leader) }
        guard let route = plan.route(from: here, to: goal), route.count >= 2 else { return nil }
        return (route, leader)
    }

    /// The critter's body on the player's floor, out in the open (not in the cab).
    static func bodyHere(_ id: String) -> SIMD2<Float>? {
        guard let p = BuildingLife.shared.presentations.first(where: { $0.residentID == id }), p.isRendered else { return nil }
        return p.bodyPosition
    }

    /// A few times a second while following: keep the walk going after it.
    static func tick() {
        let perf = PerfMonitor.begin("follow.tick"); defer { PerfMonitor.end(perf) }   // Oct 21: measurement only (PerfMonitor)
        guard let id = targetID else { return }
        guard let c = ElevatorBoard.controller else { return }              // (between floors: wait)
        guard allowed(for: id) else { stop(reason: "a scripted scene"); return }
        let life = BuildingLife.shared
        guard let r = life.resident(id) else { stop(reason: "no such resident"); return }
        if c.followGuidance == nil { attach(c) }                              // (a new floor's controller)
        // Oct 20 (tasks): there? -- its guiding is over.
        // Oct 22 (musical building): but NOT this following -- the player keeps
        // its company (and its check-ins) until they tap it again, tap elsewhere,
        // steer, or a scene starts. (Was: stop(reason: "the guide arrived").) The
        // task's own arrival is unchanged: TaskGuide.check has released the guide.
        if TaskGuide.check(now: BuildingClock.now()) {
            #if DEBUG
            c.showBrief("Here it is.")                                         // (development: the arrival, noted)
            #endif
            diag("follow.guideArrived", ["who": id, "following": "continues"])
        }
        if c.playerIsSteering, c.continuousWalkState == .stopped {
            stop(reason: "you took over")
            return
        }
        let now = Date()
        meter.sample(now: now, guide: bodyHere(id), player: { let p = c.cameraNode.presentation.worldPosition; return SIMD2<Float>(p.x, p.z) }(),
                     who: id)
        // Oct 24 (Tinky's escort): boarding and riding belong to the scripted ride (Floor 3 is
        // pressed for the player); arrived, out once he is out of the cab.
        if GuidedJourney.isGuideID(id) {
            if GuidedJourney.followWaitsInCab { return }
            // (the player rode off without him: this following is over; he waits, still owed)
            if let t = GuidedJourney.trip, t.stage == .awaitingFollow || t.stage == .leading || t.stage == .callingCar,
               c.elevatorFloor != t.fromFloor {
                stop(reason: "rode away without him")
                return
            }
            if c.playerInCab {
                if GuidedJourney.guideHasLeftCab, c.elevatorDoorsOpenIdle { c.stepOutOfElevatorForFollow() }
                return
            }
        }
        // In the cab: ride to where it's going, then out after it.
        if c.playerInCab {
            guard c.elevatorDoorsOpenIdle else { return }                    // (boarding, riding, doors moving: wait)
            let car = life.car
            let destination = car.rider(id)?.destination ?? r.floor
            if bodyHere(id) != nil || (destination == c.elevatorFloor && car.rider(id) == nil) {
                // It's here (out, or never left): step out after it.
                if car.rider(id) == nil { c.stepOutOfElevatorForFollow() }
                return
            }
            guard destination != c.elevatorFloor else { return }           // (it's still getting out here: wait)
            if let p = pressedFor, p.floor == destination, now.timeIntervalSince(p.at) < 4 { return }
            pressedFor = (destination, now)
            if !c.pressElevatorFloorForFollow(destination) {
                stop(reason: "the elevator wouldn't take you to F\(destination)")
            }
            return
        }
        // Oct 20 (tasks): it's getting into (or is in) the car standing here with its
        // doors open -- they wait for the player coming after it (as for anyone
        // walking through them; the car's own limit still applies).
        let car = life.car
        let eye = c.cameraNode.presentation.worldPosition
        let nearDoors = c.elevatorDoorwayFrame().map { simd_distance(SIMD2<Float>(eye.x, eye.z), $0.center) < 9 } ?? false   // (only near them)
        if nearDoors, car.isHere(c.elevatorFloor), let doors = car.position(now: BuildingClock.now())?.doors, doors == .open || doors == .opening,
           car.rider(id) != nil || (r.leg?.lift == .waiting && r.leg?.from.floor == c.elevatorFloor) {
            c.holdCarDoorway?(true)
        }
        // On a floor: the walk after it (the escort walk), restarted when it stops.
        guard let way = guidance(for: c) else { return }                     // (no way there right now: wait)
        let near: Bool = {
            guard let leader = way.leader else { return false }
            let p = c.cameraNode.presentation.worldPosition
            return Double(simd_distance(SIMD2(p.x, p.z), leader)) <= closeEnough
        }()
        if c.continuousWalkState != .stopped {
            // Walking -- but the way now goes back behind: stop, to turn round next tick.
            // (Oct 20, later: by the WALK's heading, never the camera's -- and only once
            // the walk has had a moment to turn onto its way: a walk setting off toward a
            // critter behind is still facing the old way for its first half second.)
            if now.timeIntervalSince(walkStartedAt) >= turnBackGrace,
               let i = way.route.firstIndex(of: c.currentCell), i + 1 < way.route.count {
                let a = way.route[i], b = way.route[i + 1]
                if let d = Direction.allCases.first(where: { $0.delta.row == b.row - a.row && $0.delta.col == b.col - a.col }),
                   d == c.walkHeading.opposite {
                    c.stopContinuousWalk(reason: "follow: it turned back")
                }
            }
            return
        }
        guard !c.isAnimating else { return }
        // The player's own hands: a finger down (looking round), or only just lifted --
        // their view, not ours. (This used to restart the walk under the finger.)
        let touching = c.isDragRotating || c.activeTouchGesture?() != nil
        if touching { lastManualAt = now }
        guard mayRestart(touching: touching, lastManual: lastManualAt, now: now) else { return }
        if way.leader == nil, c.currentCell == way.route.last {
            // At the elevator after it: board (its doors, if still open) or call.
            if now.timeIntervalSince(lastElevatorAsk) > 2 {
                lastElevatorAsk = now
                c.openElevator()
            }
            return
        }
        if near { return }                                                   // (it's just ahead: stand)
        if c.startFollowWalk() {
            walkStartedAt = now
            meter.restarts += 1
        }
    }

    /// Hands-off, pure (tests): may the follow walk take over again now?
    static func mayRestart(touching: Bool, lastManual: Date, now: Date) -> Bool {
        !touching && now.timeIntervalSince(lastManual) >= handsOffGrace
    }
}

/// Evening, Oct 20 -- a light meter for following (DEBUG and Release alike, one
/// line every 5 s, only while following): the guide's and the player's real
/// speeds, how often the follow walk restarted, and the longest gap between
/// ticks (0.25 s due) -- a main-thread stall shows as a long one.
struct FollowMeter {
    var restarts = 0
    private var windowStart: Date?
    private var lastTick: Date?
    private var worstGap: TimeInterval = 0
    private var guideTo: SIMD2<Float>?
    private var guideTravel: Float = 0, playerTravel: Float = 0
    private var lastPlayer: SIMD2<Float>?

    /// One tick's positions; every 5 s the line it logged (nil otherwise).
    @discardableResult
    mutating func sample(now: Date, guide: SIMD2<Float>?, player: SIMD2<Float>, who: String) -> String? {
        if let t = lastTick { worstGap = max(worstGap, now.timeIntervalSince(t)) }
        lastTick = now
        if let g = guide {
            if let last = guideTo { guideTravel += simd_distance(last, g) }
            guideTo = g
        } else {
            guideTo = nil
        }
        if let last = lastPlayer { playerTravel += simd_distance(last, player) }
        lastPlayer = player
        guard let start = windowStart else { windowStart = now; return nil }
        let span = now.timeIntervalSince(start)
        guard span >= 5 else { return nil }
        let gap = guide.map { simd_distance($0, player) }
        let line = String(format: "[Follow] %@ guide %.2f m/s, you %.2f m/s, gap %@, walk restarts %d, worst tick gap %.2f s (due 0.25)",
                          who, Double(guideTravel) / span, Double(playerTravel) / span,
                          gap.map { String(format: "%.1f m", $0) } ?? "-", restarts, worstGap)
        navLog(line)
        diag("follow.meter", ["who": who, "guideMps": Double(guideTravel) / span, "playerMps": Double(playerTravel) / span,
                              "restarts": restarts, "worstTickGap": worstGap])
        windowStart = now
        guideTravel = 0
        playerTravel = 0
        restarts = 0
        worstGap = 0
        return line
    }
}

