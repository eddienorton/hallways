//
//  ElevatorScheduler.swift
//  Hallways
//
//  Oct 19 (elevator overhaul) -- ONE CAR, ONE STATE.
//
//  The building's elevator is a single car with a single authoritative state
//  (BuildingElevator.State): which floor it is at or left, where it is going,
//  since when, its doors, who is waiting for it on which floor (calls), who is
//  in it and where each of them is going (riders). Everything else reads this:
//  the player's doors, the residents' bodies and records, the hall signs, the
//  shaft, Building Life. Nothing keeps a second idea of where the car is.
//
//  THE RULES (deliberately simple):
//
//    It moves only to serve someone: a call (someone waiting on a floor) or a
//    rider's destination. Nothing else ever moves it; with nothing to do it
//    stays where it is, doors shut. It never jumps: a run between floors takes
//    ElevatorTiming.run(n) -- the same count the cab's indicator shows the
//    player -- and its floor in between is the floor that count has reached.
//
//    The next stop: if the car has a direction and there are stops ahead in
//    it, the nearest of those; otherwise the nearest stop at all (ties: the
//    earliest asked). A request made while it is running is remembered and
//    served in turn; nobody already in the car loses their destination.
//
//    At a stop the doors open (the arrival chime and the slide), anyone whose
//    floor this is gets out, anyone waiting here gets in, the doors stay open
//    at least `dwell` -- and as long as someone is walking through them (a
//    hold) -- then close. A body acting it out on the player's floor walks in
//    or out itself and says so (board / alight); everyone else is moved at
//    once when the doors are open.
//
//    The player has the car while they use it (owner .player): their doors are
//    their own animation (the existing controls, unchanged), mirrored here; the
//    car runs only when they choose a floor, straight to it (it never stops
//    at a floor they didn't choose -- the ID reader and the floors' scripted
//    events stay theirs). Residents may get in and out while the player holds
//    the doors open, and ride along; whoever is still aboard when the player
//    steps out is taken on to their own floors afterwards. A scripted
//    character's door cycle (Mr. Tinky's ride home, the butterfly) is owner
//    .script the same way.
//
//  Pure data and arithmetic (no SceneKit): worked forward by `advance(to:)`,
//  tested directly (ElevatorCarTests), saved with the game (`save`/`load`).
//

import Foundation

/// HOW LONG THE CAR TAKES between floors.
///
/// `run(n)` is the car's run of n floors -- exactly the count the cab's floor
/// indicator shows the player (TapNavigationController.runElevatorIndicator):
/// Rocket Elevator (the default) lead-in + 0.3 s a floor; classic
/// (-HallwaysClassicElevator YES) lead-in + `ride(n)`. So the player's ride,
/// a resident's, the car moving empty, the hall signs and Building Life all
/// agree. (`ride` / `passing` / `floorsDone` are the classic indicator's.)
enum ElevatorTiming {
    /// Speed relative to before (0.65 = 35% slower). TUNE.
    static let speedFactor: Double = 0.65
    static let oneFloorBefore: TimeInterval = 4.5
    static let extraFloorBefore: TimeInterval = 0.5
    static var oneFloor: TimeInterval { oneFloorBefore / speedFactor }
    static var extraFloor: TimeInterval { extraFloorBefore / speedFactor }

    /// The classic count's travel time for a run of `floors` floors (0: none).
    static func ride(floors: Int) -> TimeInterval {
        floors <= 0 ? 0 : oneFloor + extraFloor * Double(floors - 1)
    }

    /// When, after setting off, a classic `n`-floor count reaches its `step`-th floor.
    static func passing(step: Int, of n: Int) -> TimeInterval {
        guard n > 0 else { return 0 }
        return ride(floors: n) * Double(min(max(step, 0), n)) / Double(n)
    }

    /// How many floors of a classic `n`-floor count are behind it `elapsed` seconds in.
    static func floorsDone(of n: Int, after elapsed: TimeInterval) -> Int {
        guard n > 0, elapsed > 0 else { return 0 }
        var i = 0
        while i < n, passing(step: i + 1, of: n) <= elapsed + 1e-9 { i += 1 }
        return i
    }

    /// Oct 19 (one car): when, after the car sets off, an `n`-floor run shows its
    /// `step`-th floor -- the cab indicator's own schedule.
    static func runStep(_ step: Int, of n: Int) -> TimeInterval {
        let k = min(max(step, 0), max(n, 0))
        if RocketElevator.isOn { return RocketElevator.indicatorStepDelay(step: k, steps: n) }
        return TapNavigationController.elevatorIndicatorStepDelay(step: k, steps: max(1, n))
    }

    /// The car's whole run of `floors` floors (0: none).
    static func run(floors n: Int) -> TimeInterval { n <= 0 ? 0 : runStep(n, of: n) }

    /// Floors of an `n`-floor run behind the car `elapsed` seconds after it set off.
    static func runFloorsDone(of n: Int, after elapsed: TimeInterval) -> Int {
        guard n > 0, elapsed > 0 else { return 0 }
        var i = 0
        while i < n, runStep(i + 1, of: n) <= elapsed + 1e-9 { i += 1 }
        return i
    }
}

final class BuildingElevator {
    static let shared = BuildingElevator()

    // MARK: State

    nonisolated enum Doors: String, Codable, Sendable { case closed, opening, open, closing }
    /// Whose doors they are right now.
    nonisolated enum Owner: String, Codable, Sendable { case building, player, script }

    /// Someone waiting for the car on a floor.
    nonisolated struct Call: Codable, Equatable, Sendable {
        var who: String
        var floor: Int
        /// Where they're going (nil: not said yet -- the player, a character).
        var destination: Int?
        var since: Date
        /// The doors opened and closed here without them (a body that didn't
        /// make it in): not a reason to come back for a little while.
        var missedAt: Date? = nil
    }

    /// Someone in the car.
    nonisolated struct Rider: Codable, Equatable, Sendable {
        var who: String
        /// Their floor (nil: the player, before choosing).
        var destination: Int?
        var since: Date
    }

    nonisolated struct State: Codable, Equatable, Sendable {
        /// The floor it's at -- or, while running, the floor it left.
        var floor: Int
        /// Running to (nil: standing at `floor`).
        var target: Int? = nil
        /// When it left `floor` for `target`.
        var departed: Date? = nil
        var doors: Doors = .closed
        var doorsSince: Date
        /// Its way: 1 up, -1 down, 0 none yet.
        var direction: Int = 0
        var calls: [Call] = []
        var riders: [Rider] = []
        var owner: Owner = .building
        /// Who owns the doors (the scripted character's name; "player").
        var ownerName: String? = nil
        /// The moment this state was last worked forward to.
        var clock: Date
    }

    /// nil: not placed yet (a brand-new building before its first floor).
    private(set) var state: State?

    /// Bodies walking through the doors right now: they stay open until then (not saved).
    private(set) var holds: [String: Date] = [:]

    /// The floor where `acting` bodies are (the player's floor; nil: wherever --
    /// tests). Anywhere else everyone gets in and out at once.
    private var actingFloor: Int?
    private func acts(_ who: String, _ acting: Set<String>, at floor: Int) -> Bool {
        acting.contains(who) && (actingFloor == nil || actingFloor == floor)
    }

    // MARK: Timings (seconds)

    /// The chime's beat, then the doors' slide (the same as every door cycle's).
    static var doorOpenSeconds: TimeInterval { SoundEffects.elevatorDoorOpeningDelay + 1.6 }
    static let doorCloseSeconds: TimeInterval = 1.6
    /// The doors stay open at least this long at a stop.
    static let dwell: TimeInterval = 3.5
    /// A body getting in or out keeps them open at most this long after they opened.
    static let exchangeLimit: TimeInterval = 14
    /// After the doors opened and closed without a waiting body, the car doesn't
    /// come back for it for this long (it is called again when it's at the doors).
    static let missedPause: TimeInterval = 12

    // MARK: What happened (returned by every change)

    nonisolated enum Event: Equatable, Sendable {
        case departed(from: Int, to: Int)
        case arrived(Int)
        case doorsOpening(Int)
        case doorsOpen(Int)
        case doorsClosing(Int)
        case doorsClosed(Int)
        case boarded(String, floor: Int, destination: Int?)
        case alighted(String, floor: Int)
        /// A call that ends without boarding (the player's: the car came).
        case callEnded(String, floor: Int)
    }
    nonisolated struct Happening: Equatable, Sendable {
        let at: Date
        let event: Event
    }

    // MARK: Placing

    /// The car's first position (a new building; an old save that never had a car).
    /// Never moves a car that already has one.
    @discardableResult
    func placeIfNeeded(at floor: Int, now: Date) -> Bool {
        guard state == nil else { return false }
        state = State(floor: floor, doorsSince: now, clock: now)
        return true
    }

    /// Start Over / a new building: nothing waiting, nobody aboard, nowhere yet.
    func reset() {
        state = nil
        holds = [:]
    }

    /// Tests: a car exactly as given.
    func restore(_ s: State?) {
        state = s
        holds = [:]
    }

    // MARK: Asking

    /// `who` waits on `floor` (for `destination`). Asking again only updates the
    /// call; someone already aboard is not "waiting". True if anything changed.
    @discardableResult
    func call(_ who: String, at floor: Int, to destination: Int?, now: Date) -> Bool {
        guard var s = state, !s.riders.contains(where: { $0.who == who }) else { return false }
        if let i = s.calls.firstIndex(where: { $0.who == who }) {
            let was = s.calls[i]
            s.calls[i].floor = floor
            s.calls[i].destination = destination ?? was.destination
            s.calls[i].missedAt = nil                                   // (at the doors again: come for it)
            if was.floor != floor { s.calls[i].since = now }
        } else {
            s.calls.append(Call(who: who, floor: floor, destination: destination, since: now))
        }
        if s.clock < now { s.clock = now }                              // (a car with nothing to do decides from now, not before)
        // A call at the floor where the doors are closing: they open again (the
        // building's doors only -- the player's and a character's are their own).
        if s.owner == .building, s.target == nil, s.floor == floor, s.doors == .closing {
            s.doors = .opening
            s.doorsSince = now
        }
        let changed = s != state
        state = s
        return changed
    }

    /// `who` no longer waits (a legitimate reason: its plans changed).
    func cancelCall(_ who: String) {
        state?.calls.removeAll { $0.who == who }
    }

    func callOf(_ who: String) -> Call? { state?.calls.first { $0.who == who } }

    /// The player's and a scripted character's calls ("script:<name>") only bring
    /// the car: nobody rides on them, and they end when its doors close there.
    nonisolated static func isOneShot(_ who: String) -> Bool { who == "player" || who.hasPrefix("script:") }
    func rider(_ who: String) -> Rider? { state?.riders.first { $0.who == who } }

    /// `who` walked in (its body, on the player's floor) -- only with the car
    /// here and its doors open. True: aboard.
    /// `force` (a scripted character's own door cycle, reported after its doors
    /// shut): only the car standing here is required.
    @discardableResult
    func board(_ who: String, destination: Int?, now: Date, force: Bool = false, at floor: Int? = nil) -> Bool {
        guard var s = state, s.target == nil, force || s.doors == .open || s.doors == .opening,
              floor.map({ $0 == s.floor }) ?? true else { return false }
        if let i = s.riders.firstIndex(where: { $0.who == who }) {
            if let destination { s.riders[i].destination = destination }
            state = s
            return true
        }
        let dest = destination ?? s.calls.first(where: { $0.who == who })?.destination
        s.calls.removeAll { $0.who == who }
        s.riders.append(Rider(who: who, destination: dest, since: now))
        state = s
        holds[who] = nil
        return true
    }

    /// `who` stepped out here. True if it was aboard.
    @discardableResult
    func alight(_ who: String, now: Date) -> Bool {
        guard var s = state, s.riders.contains(where: { $0.who == who }) else { return false }
        s.riders.removeAll { $0.who == who }
        state = s
        holds[who] = nil
        return true
    }

    /// A rider the records say is in the car and the car doesn't have (a relaunch,
    /// an older save): put back in, for its floor. Never moves the car.
    func restoreRider(_ who: String, destination: Int?, now: Date) {
        guard var s = state, !s.riders.contains(where: { $0.who == who }) else { return }
        s.calls.removeAll { $0.who == who }
        s.riders.append(Rider(who: who, destination: destination, since: now))
        state = s
    }

    /// A rider's floor (the player choosing one).
    func setDestination(_ who: String, _ floor: Int?) {
        guard let i = state?.riders.firstIndex(where: { $0.who == who }) else { return }
        state?.riders[i].destination = floor
    }

    /// A body walking through the doors keeps them open (until `until` at the latest).
    func hold(_ who: String, until: Date) { holds[who] = until }
    func release(_ who: String) { holds[who] = nil }
    /// Someone is walking through the doors right now.
    func doorwayBusy(now: Date) -> Bool { holds.values.contains { $0 > now } }

    // MARK: The player's (and a scripted character's) doors

    /// The car is here, standing (doors in any state): the player (or a character)
    /// may have its doors. False: it isn't -- it's been called instead.
    func isHere(_ floor: Int) -> Bool {
        guard let s = state else { return false }
        return s.target == nil && s.floor == floor
    }

    /// The doors here are now `name`'s (the player's / a scripted character's own
    /// animation). Only with the car standing here. Their own call ends.
    @discardableResult
    func take(_ owner: Owner, name: String, at floor: Int, now: Date) -> [Happening] {
        guard var s = state, s.target == nil, s.floor == floor else { return [] }
        var out: [Happening] = []
        s.owner = owner
        s.ownerName = name
        if s.calls.contains(where: { $0.who == name }) {
            s.calls.removeAll { $0.who == name }
            out.append(Happening(at: now, event: .callEnded(name, floor: floor)))
        }
        state = s
        return out
    }

    /// The doors are the building's again (the player stepped out and they shut,
    /// the character's cycle ended, or that scene is gone).
    func giveBack(now: Date) {
        guard var s = state, s.owner != .building else { return }
        s.owner = .building
        s.ownerName = nil
        if s.target == nil, s.doors != .closed {
            // (whoever had them is gone without shutting them: they shut now -- nobody here sees them)
            s.doors = .closed
            s.doorsSince = now
        }
        state = s
    }

    /// Their doors moved: the car's door state follows them (owner .player /
    /// .script only). Opened: anyone getting out or in here, done out of sight.
    @discardableResult
    func mirrorDoors(_ doors: Doors, now: Date, acting: Set<String> = [], actingFloor: Int? = nil) -> [Happening] {
        guard var s = state, s.owner != .building, s.target == nil, s.doors != doors else { return [] }
        self.actingFloor = actingFloor
        s.doors = doors
        s.doorsSince = now
        var out: [Happening] = []
        switch doors {
        case .opening: out.append(Happening(at: now, event: .doorsOpening(s.floor)))
        case .open:
            out.append(Happening(at: now, event: .doorsOpen(s.floor)))
            out += exchange(&s, at: now, acting: acting)
        case .closing: out.append(Happening(at: now, event: .doorsClosing(s.floor)))
        case .closed: out.append(Happening(at: now, event: .doorsClosed(s.floor)))
        }
        state = s
        return out
    }

    /// The player chose `floor` and their doors are shut: the car runs there now,
    /// straight (no stops on the way).
    @discardableResult
    func playerRuns(to floor: Int, now: Date) -> [Happening] {
        guard var s = state, s.owner == .player, s.target == nil, floor != s.floor else { return [] }
        if let i = s.riders.firstIndex(where: { $0.who == "player" }) {
            s.riders[i].destination = floor
        } else {
            s.riders.append(Rider(who: "player", destination: floor, since: now))
        }
        s.doors = .closed
        s.doorsSince = now
        s.target = floor
        s.departed = now
        s.direction = floor > s.floor ? 1 : -1
        let from = s.floor
        state = s
        return [Happening(at: now, event: .departed(from: from, to: floor))]
    }

    /// The player's cab has arrived at `floor` (its doors about to open): the car
    /// is there. Normally it already is (the run is shorter than the arrival);
    /// if the run is still going it ends now.
    @discardableResult
    func playerArrived(at floor: Int, now: Date) -> [Happening] {
        guard var s = state else { return [] }
        var out: [Happening] = []
        if s.target == floor {
            s.floor = floor
            s.target = nil
            s.departed = nil
            out.append(Happening(at: now, event: .arrived(floor)))
        }
        guard s.target == nil, s.floor == floor else { return out }
        s.owner = .player
        s.ownerName = "player"
        state = s
        return out
    }

    // MARK: Where it is

    nonisolated struct Position: Equatable, Sendable {
        /// The floor it is at -- or, running, the floor its count has reached.
        let floor: Int
        /// Exactly where between floors (for drawing): `floor` .. the next one.
        let exact: Double
        /// 1 up, -1 down, 0 standing.
        let direction: Int
        let doors: Doors
        /// Running to (nil: standing).
        let target: Int?
        let owner: Owner
        /// Who's in it, and who's waiting where.
        let riders: [Rider]
        let calls: [Call]
        var moving: Bool { target != nil }
        /// Short words for panels.
        var state: String {
            if let t = target { return "running F\(floor) -> F\(t)" }
            switch doors {
            case .closed: return riders.isEmpty && calls.isEmpty ? "idle" : "standing"
            case .opening: return "doors opening"
            case .open: return "doors open"
            case .closing: return "doors closing"
            }
        }
        /// (diagnostics: who it's busy with)
        var rider: String? { owner == .player ? "player" : riders.first?.who }
    }

    func position(now: Date) -> Position? {
        guard let s = state else { return nil }
        var floor = s.floor, exact = Double(s.floor)
        if let t = s.target, let d = s.departed {
            let n = abs(t - s.floor), way = t > s.floor ? 1 : -1
            let elapsed = max(0, now.timeIntervalSince(d))
            let done = min(n, ElevatorTiming.runFloorsDone(of: n, after: elapsed))
            floor = s.floor + way * done
            let a = ElevatorTiming.runStep(done, of: n), b = ElevatorTiming.runStep(done + 1, of: n)
            let frac = done >= n || b <= a ? 0 : min(1, max(0, (elapsed - a) / (b - a)))
            exact = Double(floor) + Double(way) * frac
        }
        return Position(floor: floor, exact: exact, direction: s.target.map { $0 > s.floor ? 1 : -1 } ?? 0,
                        doors: s.doors, target: s.target, owner: s.owner, riders: s.riders, calls: s.calls)
    }

    // MARK: Working it forward

    /// Everything the car does up to `now`, in order. `acting`: who has a body on
    /// the player's floor that will walk in or out itself (the car waits for it,
    /// up to `exchangeLimit`); everyone else gets in and out at once.
    @discardableResult
    func advance(to now: Date, acting: Set<String> = [], actingFloor: Int? = nil) -> [Happening] {
        guard var s = state else { return [] }
        self.actingFloor = actingFloor
        var out: [Happening] = []
        var guardCount = 0
        while guardCount < 400, let due = nextTransition(s, acting: acting, now: now), due <= now {
            guardCount += 1
            // (never stamped before the moment the car last stood: a door held open
            // past its dwell closes when it's let go, not back in the past)
            let t = max(due, s.clock)
            out += step(&s, at: t, acting: acting)
            s.clock = t
        }
        if s.clock < now { s.clock = now }
        holds = holds.filter { $0.value > now }
        state = s
        return out
    }

    /// When the car next does something by itself (nil: nothing to do).
    private func nextTransition(_ s: State, acting: Set<String>, now: Date) -> Date? {
        if let t = s.target, let d = s.departed {
            return d.addingTimeInterval(ElevatorTiming.run(floors: abs(t - s.floor)))
        }
        guard s.owner == .building else { return nil }                 // (their doors: they say when)
        switch s.doors {
        case .opening: return s.doorsSince.addingTimeInterval(Self.doorOpenSeconds)
        case .open: return closeTime(s, acting: acting, now: now)
        case .closing: return s.doorsSince.addingTimeInterval(Self.doorCloseSeconds)
        case .closed:
            let from = max(s.doorsSince, s.clock)
            if nextStop(s, at: from) != nil { return from }
            // (only calls it passed by recently: when the first of them counts again)
            let missed = s.calls.compactMap { $0.missedAt?.addingTimeInterval(Self.missedPause) }.filter { $0 > from }
            return missed.min()
        }
    }

    /// The doors close after the dwell, once nobody is walking through them --
    /// and nobody acting is still to get in or out (at most exchangeLimit).
    private func closeTime(_ s: State, acting: Set<String>, now: Date) -> Date {
        var t = s.doorsSince.addingTimeInterval(Self.dwell)
        let limit = s.doorsSince.addingTimeInterval(Self.exchangeLimit)
        let waitingHere = s.calls.contains { $0.floor == s.floor && $0.missedAt == nil && acts($0.who, acting, at: s.floor) }
        let gettingOut = s.riders.contains { $0.destination == s.floor && acts($0.who, acting, at: s.floor) }
        let walking = holds.values.filter { $0 > now }.max()
        if waitingHere || gettingOut || walking != nil {
            // (re-evaluated every advance: until they're done, "later")
            t = max(t, min(limit, now.addingTimeInterval(0.25)))
            if let w = walking { t = max(t, min(limit, w)) }
        }
        return t
    }

    /// The next floor to stop at (nil: nowhere). Its own floor first (someone to
    /// let in or out here), then ahead in its way, then the nearest.
    private func nextStop(_ s: State, at t: Date) -> Int? {
        var stops = Set(s.riders.compactMap { $0.destination })
        for c in s.calls where c.missedAt.map({ t >= $0.addingTimeInterval(Self.missedPause) }) ?? true {
            stops.insert(c.floor)
        }
        guard !stops.isEmpty else { return nil }
        if stops.contains(s.floor) { return s.floor }
        if s.direction != 0 {
            let ahead = stops.filter { ($0 - s.floor) * s.direction > 0 }
            if let f = ahead.min(by: { abs($0 - s.floor) < abs($1 - s.floor) }) { return f }
        }
        func asked(_ f: Int) -> Date {
            s.calls.filter { $0.floor == f }.map(\.since).min() ?? s.riders.filter { $0.destination == f }.map(\.since).min() ?? .distantFuture
        }
        return stops.min { a, b in
            let da = abs(a - s.floor), db = abs(b - s.floor)
            return da != db ? da < db : asked(a) < asked(b)
        }
    }

    /// One thing the car does at `t`.
    private func step(_ s: inout State, at t: Date, acting: Set<String>) -> [Happening] {
        var out: [Happening] = []
        if let target = s.target {
            // Arrived.
            s.floor = target
            s.target = nil
            s.departed = nil
            out.append(Happening(at: t, event: .arrived(target)))
            if s.owner == .building {
                s.doors = .opening
                s.doorsSince = t
                out.append(Happening(at: t, event: .doorsOpening(target)))
            }
            return out
        }
        switch s.doors {
        case .opening:
            s.doors = .open
            s.doorsSince = t
            out.append(Happening(at: t, event: .doorsOpen(s.floor)))
            out += exchange(&s, at: t, acting: acting)
        case .open:
            // Anyone who came to the doors while they stood open (out of sight) gets in now.
            out += exchange(&s, at: t, acting: acting)
            // Whoever was still to get out here, and hasn't by the limit, is out.
            for r in s.riders where r.destination == s.floor && r.who != "player" {
                s.riders.removeAll { $0.who == r.who }
                out.append(Happening(at: t, event: .alighted(r.who, floor: s.floor)))
            }
            s.doors = .closing
            s.doorsSince = t
            out.append(Happening(at: t, event: .doorsClosing(s.floor)))
        case .closing:
            s.doors = .closed
            s.doorsSince = t
            out.append(Happening(at: t, event: .doorsClosed(s.floor)))
            // Waiting here and not in: the player's call is over (the car came);
            // anyone else's stays, but the car won't come straight back for it.
            for c in s.calls where c.floor == s.floor && c.missedAt == nil {
                if Self.isOneShot(c.who) {
                    s.calls.removeAll { $0.who == c.who }
                    out.append(Happening(at: t, event: .callEnded(c.who, floor: s.floor)))
                } else if let i = s.calls.firstIndex(where: { $0.who == c.who }) {
                    s.calls[i].missedAt = t
                }
            }
        case .closed:
            guard let stop = nextStop(s, at: t) else { return out }
            if stop == s.floor {
                s.doors = .opening
                s.doorsSince = t
                out.append(Happening(at: t, event: .doorsOpening(s.floor)))
            } else {
                s.direction = stop > s.floor ? 1 : -1
                s.target = stop
                s.departed = t
                out.append(Happening(at: t, event: .departed(from: s.floor, to: stop)))
            }
        }
        return out
    }

    /// The doors are open at `s.floor`: out and in, for everyone not acting it
    /// out with a body. The player's call ends (their doors take it from here).
    private func exchange(_ s: inout State, at t: Date, acting: Set<String>) -> [Happening] {
        var out: [Happening] = []
        for r in s.riders where r.destination == s.floor && r.who != "player" && !acts(r.who, acting, at: s.floor) {
            s.riders.removeAll { $0.who == r.who }
            out.append(Happening(at: t, event: .alighted(r.who, floor: s.floor)))
        }
        for c in s.calls where c.floor == s.floor {
            if Self.isOneShot(c.who) { continue }                     // (the player walks in themselves; a character's cycle is its own)
            guard !acts(c.who, acting, at: s.floor) else { continue }
            s.calls.removeAll { $0.who == c.who }
            s.riders.append(Rider(who: c.who, destination: c.destination, since: t))
            out.append(Happening(at: t, event: .boarded(c.who, floor: s.floor, destination: c.destination)))
        }
        // Someone just got in for somewhere: the car's way is theirs if it has none.
        if s.direction == 0, let d = s.riders.compactMap({ $0.destination }).first(where: { $0 != s.floor }) {
            s.direction = d > s.floor ? 1 : -1
        }
        return out
    }

    /// The state as it matters (its clock aside): for "did anything change?".
    func sameIgnoringClock(_ other: State?) -> Bool {
        guard var a = state, var b = other else { return state == nil && other == nil }
        a.clock = .distantPast
        b.clock = .distantPast
        return a == b
    }

    // MARK: Saved with the game

    static let storageKey = "building.elevator.car.v1"

    func save(to defaults: UserDefaults) {
        guard let s = state, let data = try? JSONEncoder().encode(s) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// The car as saved (nil: no car saved -- an older save, or a new building).
    @discardableResult
    func load(from defaults: UserDefaults) -> Bool {
        guard let data = defaults.data(forKey: Self.storageKey), var s = try? JSONDecoder().decode(State.self, from: data) else { return false }
        // Whoever had the doors when the game closed doesn't have them now: they're
        // the building's (shut). The player isn't in the car after a relaunch
        // (they start on a floor) -- their place in it, and their call, are gone.
        if s.owner != .building {
            s.owner = .building
            s.ownerName = nil
            if s.target == nil { s.doors = .closed }
        }
        s.riders.removeAll { $0.who == "player" }
        s.calls.removeAll { Self.isOneShot($0.who) }
        if s.target == nil, s.doors == .opening || s.doors == .open || s.doors == .closing {
            s.doors = .closing                                          // (they finish closing; nobody is mid-doorway)
        }
        state = s
        holds = [:]
        return true
    }

    static func clear(in defaults: UserDefaults) { defaults.removeObject(forKey: storageKey) }
}
