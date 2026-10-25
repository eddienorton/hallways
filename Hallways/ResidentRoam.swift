//
//  ResidentRoam.swift
//  Hallways
//
//  Oct 18 (building life) -- ROAM: the ordinary life of any resident that
//  walks about. No itinerary: at each decision it picks a reachable place
//  from its preferences (floors it likes, now and then a favourite spot,
//  otherwise anywhere open on that floor), works out how long getting there
//  takes (walking pace, the elevator between floors), stays a while, and
//  decides again.
//
//  Two halves, sharing ONE decision function (Roam.decide):
//
//    Offscreen   Roam.advance -- the record worked forward to now, decision
//                by decision, no SceneKit. A long absence is capped: after
//                40 decisions it is simply where it got to, now.
//    On a floor  RoamPresentation -- a body acts the record out: walks the
//                route with the building's lead engine (CharacterLead: doors
//                and all, never through the player), takes the elevator by
//                the same door cycle every character uses, steps out of it
//                on arrival. Every SceneKit step has a deadline, so a body
//                that stops moving can delay the resident, never stall it.
//
//  What's the kind's own: its body (RoamerBody -- how it moves and sounds),
//  its RoamStyle (preferences, pace), its abilities (no elevator unless it
//  has .rideElevator).
//

import SceneKit
import simd

// MARK: - Preferences

struct RoamStyle {
    /// The floors it likes, with weights (a floor not listed: never).
    var floors: [Int: Double]
    /// Favourite spots (chosen now and then instead of anywhere).
    var places: [ResidentPlace] = []
    var placeChance: Double = 0.3
    /// How long it stays somewhere (seconds).
    var stay: ClosedRange<Double>
    /// Walking pace (m/s): its body's speed, and its offscreen travel times.
    var speed: Float
    /// The chance a decision is another floor (only with .rideElevator).
    var changeFloorChance: Double
    /// Door to door between floors (seconds).
    var elevatorRide: Double = 24
    /// A destination worth the walk (cells).
    var minDistance = 3
    /// Oct 18 (open the building): rooms it favours, by a word in their name
    /// ("Break", "Aquarium"...) -> weight (1 = like any other). Empty: no favourites.
    var roomTaste: [String: Double] = [:]
}

/// Oct 18 (open the building): where autonomous residents may and may not go --
/// the building's rules, not any one resident's.
enum ResidentPolicy {
    /// Everyone comes in here, at its entrance (the lobby cell farthest from the elevator).
    static let lobbyFloor = 1
    /// Never a stop: Administration (onboarding, Juanita, ID issuance, the escort).
    static let closedFloors: Set<Int> = [2]
    /// Rooms with scripted lives of their own: never a resident's destination.
    /// (Floor 3's conference room -- the staff meeting, The Box -- and the player's office.)
    static let closedRooms: Set<String> = ["F3 Conference Room", "F3 Office"]

    /// Oct 19: the building is open to its residents once onboarding is over --
    /// the same moment the lobby stops being a quiet onboarding floor
    /// (Admission.isQuietOnboarding) and residents can be shown there at all.
    /// Before it, nobody comes in: an arrival nobody could see would still
    /// book the car to the lobby, and the player watching the doors would see
    /// the car come and go with its doors shut (Oct 19, after Start Over).
    static var buildingOpen: Bool { Admission.isCompleted && Admission.isPrologueCompleted }

    static func isOpen(_ room: RoomDestination) -> Bool {
        !closedFloors.contains(room.floor) && room.floor != lobbyFloor && !closedRooms.contains(room.id)
    }
}

// MARK: - Decisions (pure)

enum Roam {
    /// A stable seed for a resident's n-th decision (String.hashValue changes every launch).
    static func seed(_ id: String, _ moves: Int) -> UInt64 {
        var h: UInt64 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt64(b) }
        return h &* 7919 &+ UInt64(max(0, moves)) &* 104_729 &+ 17
    }

    static func walkSeconds(_ routeCells: Int, plan: FloorPlan, style: RoamStyle) -> Double {
        Double(Float(max(0, routeCells - 1)) * plan.cellSize / max(0.1, style.speed))
    }

    /// The next decision, taken at `t`: where to, by when, for how long.
    /// `allowFloorChange` false: somewhere on this floor (e.g. the elevator
    /// was never free).
    static func decide(_ r: inout Resident, style: RoamStyle, abilities: Set<ResidentAbility>,
                       plans: (Int) -> FloorPlan?, at t: Date, allowFloorChange: Bool = true) {
        var rng = Rand(seed: seed(r.id, r.moves))
        r.moves += 1
        let stay = Double(rng.range(Float(style.stay.lowerBound), Float(style.stay.upperBound)))
        func stayPut(_ why: String) {
            r.leg = nil
            r.since = t
            r.dwell = stay
            r.why = "stays put: " + why
        }
        guard abilities.contains(.walk) || abilities.contains(.fly) else { stayPut("it can't walk or fly"); return }
        guard let herePlan = plans(r.floor), !herePlan.cells.isEmpty else { stayPut("no plan of F\(r.floor)"); return }
        let ordered = herePlan.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        let fresh = r.cell == nil                                          // (a newcomer: it comes by the elevator)
        // Oct 18 (open the building): a newcomer in the lobby walks in at the entrance.
        let entering = fresh && r.floor == ResidentPolicy.lobbyFloor && herePlan.elevator != nil
        let origin = entering ? (RoomRegistry.lobbyEntrance(herePlan) ?? herePlan.elevator!)
            : (r.cell.flatMap { herePlan.cells.contains($0) ? $0 : nil } ?? herePlan.elevator ?? ordered[0])
        // Which floor.
        var floor = r.floor
        var floorWhy = allowFloorChange ? "" : " (the elevator never came free)"
        let canRide = abilities.contains(.rideElevator) && herePlan.elevator != nil && allowFloorChange && (!fresh || entering)
        // Oct 23 (ten-floor experiment): floors out of use count for their stand-ins (ActiveBuilding).
        let liked = ActiveBuilding.fold(style.floors)
        if canRide {
            // (Oct 18: only floors with somewhere to go -- a room -- and never a closed floor or the lobby)
            let others = liked.filter { f in
                f.key != r.floor && f.value > 0 && !ResidentPolicy.closedFloors.contains(f.key) && f.key != ResidentPolicy.lobbyFloor
                    && plans(f.key).map { $0.elevator != nil && $0.rooms.contains(where: ResidentPolicy.isOpen) } ?? false
            }.sorted { $0.key < $1.key }
            let unwelcome = (liked[r.floor] ?? 0) <= 0 || !herePlan.rooms.contains(where: ResidentPolicy.isOpen)
            if !others.isEmpty, unwelcome || Double(rng.unit()) < style.changeFloorChance {
                let total = others.reduce(0) { $0 + $1.value }
                var pick = Double(rng.unit()) * total
                floor = others[others.count - 1].key
                for (f, w) in others {
                    if pick < w { floor = f; break }
                    pick -= w
                }
                floorWhy = unwelcome ? " (nothing for it on F\(r.floor))" : " (a change of floor, F\(r.floor)->F\(floor))"
            }
        }
        let plan: FloorPlan
        if floor == r.floor {
            plan = herePlan
        } else if let other = plans(floor) {
            plan = other
        } else {
            stayPut("no plan of F\(floor)")
            return
        }
        let start = floor == r.floor ? origin : (plan.elevator ?? origin)
        // Oct 18 (room-based life): which ROOM -- a registered room of that floor
        // (RoomRegistry, from the map), not the one it's just been in when there's
        // another, and an arrival cell of it it can actually walk to.
        let rooms = plan.rooms.filter(ResidentPolicy.isOpen)              // (Oct 18: never a scripted room, Floor 2, the lobby)
        guard !rooms.isEmpty else {
            stayPut("no rooms on F\(floor)")
            r.dwell = min(stay, 10)                        // (not long: it looks again soon)
            return
        }
        var candidates = rooms.count > 1 ? rooms.filter { $0.id != r.room } : rooms
        if style.roomTaste.isEmpty {
            for i in stride(from: candidates.count - 1, to: 0, by: -1) {          // (a shuffle, from its own seed)
                let j = Int(rng.unit() * Float(i + 1)) % (i + 1)
                candidates.swapAt(i, j)
            }
        } else {
            // Oct 18: a shuffle that favours its favourites (each room's chance of coming
            // first in proportion to its weight -- still random, still its own seed).
            func weight(_ room: RoomDestination) -> Double {
                let name = room.name.lowercased()
                return style.roomTaste.filter { name.contains($0.key.lowercased()) }.map { $0.value }.max() ?? 1
            }
            candidates = candidates.map { room -> (RoomDestination, Double) in
                let u = max(1e-6, Double(rng.unit()))
                return (room, pow(u, 1 / max(0.01, weight(room))))
            }.sorted { $0.1 > $1.1 }.map { $0.0 }
        }
        var destination: (cell: GridCoordinate, route: [GridCoordinate], room: RoomDestination)?
        var unreachable: [String] = []
        for room in candidates {
            let offset = Int(rng.unit() * Float(room.arrivals.count)) % max(1, room.arrivals.count)
            let order = Array(room.arrivals[offset...] + room.arrivals[..<offset]).filter { $0 != start } + [start]
            if let cell = order.first(where: { room.arrivals.contains($0) && plan.route(from: start, to: $0) != nil }),
               let route = plan.route(from: start, to: cell) {
                destination = (cell, route, room)
                break
            }
            unreachable.append(room.name)
        }
        guard let destination else {
            stayPut("no reachable room on F\(floor) (tried \(unreachable.joined(separator: ", ")))")
            r.dwell = min(stay, 10)
            return
        }
        let cellWhy = "room: \(destination.room.name)" + (unreachable.isEmpty ? "" : " (\(unreachable.joined(separator: ", ")) unreachable)")
        let walk = walkSeconds(destination.route.count, plan: plan, style: style)
        if fresh && !entering {
            // Placed on its floor at the elevator's landing, then to its place.
            // (Oct 19, one car: a plain walk from the doors -- no ride the car didn't make.)
            r.leg = ResidentLeg(from: ResidentPlace(floor: floor, cell: start), departed: t, boardAt: nil, alightAt: nil)
            r.since = t + walk + 2
        } else if floor == r.floor {
            r.leg = ResidentLeg(from: ResidentPlace(floor: r.floor, cell: origin), departed: t, boardAt: nil, alightAt: nil)
            r.since = t + walk + 1
        } else {
            // Oct 19 (one car): to the doors (by `boardAt` -- when it expects to get
            // there, not a booking), then the car: called there, waited for, ridden.
            // When it's there is up to the car: `since` is set when it steps out.
            let toLift = herePlan.elevator.flatMap { herePlan.route(from: origin, to: $0) }?.count ?? 1
            let atDoors = t + walkSeconds(toLift, plan: herePlan, style: style) + 3
            var leg = ResidentLeg(from: ResidentPlace(floor: r.floor, cell: origin), departed: t, boardAt: atDoors, alightAt: nil)
            leg.lift = .toDoors
            leg.outWalk = walk + 2
            r.leg = leg
            r.since = .distantFuture
        }
        r.floor = floor
        r.cell = destination.cell
        r.dwell = stay
        r.room = destination.room.id
        r.roomName = destination.room.name
        r.why = (entering ? "newcomer, in at the lobby entrance; " : (fresh ? "newcomer, in by the elevator; " : ""))
            + "\(cellWhy) on F\(floor), \(destination.route.count - 1) cells away" + floorWhy
    }

    /// Oct 20 (tasks): a journey to a GIVEN place -- a task's destination a guide
    /// leads the player to -- built the way `decide` builds one: a walk on this
    /// floor; between floors the walk to the doors, the car (called, waited for,
    /// ridden) and the walk out. From `origin` on its floor (r.floor). The routes
    /// are the ones its body walks (bathroom and window-room doors never crossed).
    /// False, record untouched: no way there (no plan, no route, no elevator, it can't ride).
    static func send(_ r: inout Resident, to place: ResidentPlace, from origin: GridCoordinate, style: RoamStyle,
                     abilities: Set<ResidentAbility>, plans: (Int) -> FloorPlan?, at t: Date, stay: Double, why: String) -> Bool {
        guard let herePlan = plans(r.floor), let there = plans(place.floor), there.cells.contains(place.cell),
              herePlan.cells.contains(origin) else { return false }
        func way(_ plan: FloorPlan, _ a: GridCoordinate, _ b: GridCoordinate) -> [GridCoordinate]? {
            let shut = plan.bathroomDoors.merging(plan.windowDoors) { a, _ in a }
            return CharacterLead.route(from: a, to: b, cells: plan.cells, doors: shut, canCross: { _ in false })
        }
        var leg: ResidentLeg
        let since: Date
        if place.floor == r.floor {
            guard let route = way(herePlan, origin, place.cell) else { return false }
            leg = ResidentLeg(from: ResidentPlace(floor: r.floor, cell: origin), departed: t, boardAt: nil, alightAt: nil)
            since = t + walkSeconds(route.count, plan: herePlan, style: style) + 1
        } else {
            guard abilities.contains(.rideElevator), let e = herePlan.elevator, let e2 = there.elevator,
                  let toLift = way(herePlan, origin, e), let out = way(there, e2, place.cell) else { return false }
            leg = ResidentLeg(from: ResidentPlace(floor: r.floor, cell: origin), departed: t,
                              boardAt: t + walkSeconds(toLift.count, plan: herePlan, style: style) + 3, alightAt: nil)
            leg.lift = .toDoors
            leg.outWalk = walkSeconds(out.count, plan: there, style: style) + 2
            since = .distantFuture                          // (there when the car has brought it and it has walked out)
        }
        let room = there.rooms.first { $0.cells.contains(place.cell) }
        r.moves += 1                                        // (a journey of its own: its name, Resident.journeyName)
        r.leg = leg
        r.since = since
        r.floor = place.floor
        r.cell = place.cell
        r.dwell = stay
        r.room = room?.id
        r.roomName = room?.name
        r.why = why
        return true
    }

    /// Oct 18 (repair): how far along its route a walker is at `now`, as a
    /// route index -- the place to show it when the player comes upon it mid-walk.
    /// It left `departed` and is due at the end at `arrives`.
    static func resumeIndex(routeCount: Int, departed: Date, arrives: Date, now: Date) -> Int {
        guard routeCount > 1 else { return 0 }
        let total = arrives.timeIntervalSince(departed)
        let f = total > 0 ? min(1, max(0, now.timeIntervalSince(departed) / total)) : 1
        return min(routeCount - 1, max(0, Int((f * Double(routeCount - 1)).rounded(.down))))
    }

    /// Oct 18 (repair): the walkable cell nearest a point (nil: no cells).
    static func nearestCell(to p: SIMD2<Float>, in cells: Set<GridCoordinate>, cellSize: Float) -> GridCoordinate? {
        cells.min { a, b in
            let da = simd_distance(p, SIMD2<Float>(Float(a.col) * cellSize, Float(a.row) * cellSize))
            let db = simd_distance(p, SIMD2<Float>(Float(b.col) * cellSize, Float(b.row) * cellSize))
            return da != db ? da < db : (a.row, a.col) < (b.row, b.col)
        }
    }

    /// Oct 18 (repair): a stay never outlasts the style's longest stay from now
    /// (normally always true; it matters when the style changes -- fast mode --
    /// under a stay chosen at the old pace). True if it shortened it.
    @discardableResult
    static func clampStay(_ r: inout Resident, style: RoamStyle, now: Date) -> Bool {
        guard !r.isTravelling(at: now), r.nextDecision > now.addingTimeInterval(style.stay.upperBound + 1) else { return false }
        r.dwell = now.timeIntervalSince(r.since) + style.stay.upperBound
        return true
    }

    /// Offscreen: the record worked forward to `now`.
    static func advance(_ r: inout Resident, style: RoamStyle, abilities: Set<ResidentAbility>,
                        plans: (Int) -> FloorPlan?, to now: Date) {
        clampStay(&r, style: style, now: now)
        var steps = 0
        while now >= r.nextDecision, steps < 40 {
            decide(&r, style: style, abilities: abilities, plans: plans, at: r.nextDecision)
            steps += 1
        }
        if steps == 40 {                                   // (a long absence: it's simply there now)
            r.leg = nil
            r.since = now
            r.why = "a long absence: 40 decisions caught up, simply there now"
        }
        if r.leg != nil, now >= r.since { r.leg = nil }    // (arrived)
    }
}

// MARK: - Oct 20 (night) -- the guide's brisk pace

/// While a critter leads the player to a task it walks briskly -- about 1.4 m/s
/// (its roaming pace is 0.35-0.75) -- and goes back to its own pace the moment
/// the guiding ends. Its legs keep up with its body: the step gets longer AND
/// quicker (the stride taking the larger share of the change, capped), so the
/// feet neither slide nor scurry. Corridor walking only: the elevator runs as ever.
enum GuidePace {
    static let speed: Float = 1.4
    /// How much of the speed-up comes from longer steps (the rest from quicker ones).
    static let strideShare: Float = 0.7
    /// Steps never more than this much longer than its own.
    static let strideCap: Float = 1.8
    /// Pottle, four times its own pace: a longer tip of the pot each step, so it
    /// isn't tipping rim to rim twice as fast as ever.
    static let pottleStrideCap: Float = 2.6

    /// From a roaming pace to the guide's: (step length x, step rate x) -- their
    /// product is exactly speed / pace. A walker already at least as quick: (1, 1).
    static func gait(normalPace p: Float, strideCap cap: Float = strideCap) -> (stride: Float, cadence: Float) {
        guard p > 0.01, speed > p else { return (1, 1) }
        let k = speed / p
        let stride = min(cap, pow(k, strideShare))
        return (stride, k / stride)
    }
}

// MARK: - A body that roams

/// A roaming resident's body: the lead engine's performer, plus placing and idling.
protocol RoamerBody: LeadPerformer {
    var root: SCNNode { get }
    /// Its walking pace (m/s).
    var speed: Float { get }
    /// Facing (yaw; Noodle convention: yaw h faces (-sin h, -cos h)).
    var heading: Float { get }
    func place(at p: SIMD2<Float>, heading: Float)
    /// A small idle gesture while it stays somewhere.
    func idle()
    /// Oct 18 (diagnostics): whose body this is (for its [Life] lines).
    var diagnosticID: String { get set }
    /// A travel (move) action is running on it right now.
    var isMoving: Bool { get }
    /// Its footstep sound loop is running right now.
    var isStepping: Bool { get }
    /// Oct 18 (repair): stop everything it's doing at once (walk, footsteps, turn).
    func halt()
    /// Oct 18 (phase 2): its eyes' attention (nil: it has no eyes).
    var eyes: CritterAttention? { get }
    /// Which tastes it brings to a room (what it likes to do there).
    var activitySpecies: ResidentActivities.Species { get }
    /// One small beat of a room activity, in place (`toward`: the thing, x z).
    func activityBeat(_ kind: ResidentActivities.Kind, toward thing: SIMD2<Float>?)
    /// Turn to face a point (x, z), in place.
    func turn(toward p: SIMD2<Float>, duration: Double)
    /// Up from a rest, before it goes anywhere.
    func rise()
    /// Oct 20 (night): guiding the player -- walk at `mps` (GuidePace.speed), its
    /// gait matched to it; nil: its own pace again (at once).
    func setGuidePace(_ mps: Float?)
    /// Oct 20 (follow a critter): the player chose to follow it -- its come-hither
    /// (`player`: where they stand). Never stops or changes its walk.
    func acknowledge(player: SIMD2<Float>?)
}

extension RoamerBody {
    var eyes: CritterAttention? { nil }
    var activitySpecies: ResidentActivities.Species { .chair }
    func activityBeat(_ kind: ResidentActivities.Kind, toward thing: SIMD2<Float>?) { idle() }
    func turn(toward p: SIMD2<Float>, duration: Double) {}
    func rise() {}
    func acknowledge(player: SIMD2<Float>?) {
        if let p = player { watch(p) }
        eyes?.react(.recognizing)
        idle()
    }
    func setGuidePace(_ mps: Float?) {}
}

// MARK: - On the player's floor

final class RoamPresentation: ResidentPresentation {
    let residentID: String
    let floor: Int
    private let style: RoamStyle
    private let abilities: Set<ResidentAbility>
    private let makeBody: () -> RoamerBody
    private weak var root: SCNNode?
    private weak var controller: TapNavigationController?
    private let context: CharacterLead.Context
    private let life: BuildingLife

    private var body: RoamerBody?
    private var lead: CharacterLead?
    private var walkDeadline: Date?
    private var walkGoal: SIMD2<Float>?
    private var afterWalk: (() -> Void)?
    private var boarding = false                  // (Oct 19, one car: walking into the cab)
    private var exiting = false                   // (Oct 19, one car: walking out of it)
    private var queueSpot: SIMD2<Float>?          // (Oct 19: where it stands waiting at the doors)
    private var leaving = false                   // on its way out by the elevator
    /// Oct 19 (sharing the car): its body standing in the cab after boarding, while
    /// the doors are still open (the player got in too) -- taken away only once the
    /// doors are shut on it and the player isn't in there with it.
    private var cabBody: RoamerBody?
    private var nextIdle = Date.distantPast
    private var generation = 0

    // Oct 18 (diagnostics) -- what's been said already (log on change, not every tick).
    private var walkStarted: Date?
    private var walkEstimate: TimeInterval = 0
    private var walkCell: GridCoordinate?
    private var progress: (point: SIMD2<Float>, at: Date)?
    private var stallReported: Date?
    private var dwellingSince: Date?
    private var lastWaitNote: String?
    private var lastWaitKey: String?
    private var lastWaitNoteAt = Date.distantPast
    private var lastBlocker: String?
    private var lastBlockerAt = Date.distantPast
    private var mismatchReported: String?
    private var footstepsReported = false

    // Oct 18 (phase 2) -- its room activity: what, with what, where it stands, the next beat.
    private struct Activity {
        let kind: ResidentActivities.Kind
        let thing: RoomThing?
        var nextBeat: Date
    }
    private var activity: Activity?
    private var activityToken = 0

    init(residentID: String, floor: Int, root: SCNNode, controller: TapNavigationController, context: CharacterLead.Context,
         style: RoamStyle, abilities: Set<ResidentAbility>, life: BuildingLife = .shared, makeBody: @escaping () -> RoamerBody) {
        self.residentID = residentID
        self.floor = floor
        self.root = root
        self.controller = controller
        self.context = context
        self.style = style
        self.abilities = abilities
        self.life = life
        self.makeBody = makeBody
    }

    var holdsResident: Bool { body != nil || cabBody != nil }
    /// Oct 19 (one car): its body walks into and out of the car itself.
    var actsElevator: Bool { true }
    var bodyNode: SCNNode? { body?.root.parent != nil ? body?.root : nil }
    /// Oct 22 (critter taps): its body, or its figure in the cab (seen through the open doors).
    var tapTargets: [SCNNode] { [body?.root, cabBody?.root].compactMap { $0 }.filter { $0.parent != nil } }
    var isRendered: Bool { body?.root.parent != nil }
    var bodyPosition: SIMD2<Float>? { body?.groundPosition }
    var isGuiding: Bool { false }
    func playerBoarding() -> Bool { false }
    func arrivalDoorsOpening() {}

    /// Oct 20 (tasks): how long it lingers where it led the player (then its own life again).
    static let guideStay: Double = 20
    var canGuide: Bool { true }

    /// Oct 20 (tasks): lead the player to `place`, from where its body stands --
    /// the same walk (and, between floors, the same doors and car) as any journey
    /// of its own. True: on its way.
    func guide(to place: ResidentPlace, why: String) -> Bool {
        guard let body, !boarding, !exiting, cabBody == nil, let at = body.groundPosition,
              var r = life.resident(residentID) else { return false }
        let now = BuildingClock.now()
        var origin = cellOf(at)
        if !context.cells.contains(origin) { origin = Roam.nearestCell(to: at, in: context.cells, cellSize: s) ?? origin }
        r.floor = floor                                         // (it is here, whatever it was heading for)
        r.cell = origin
        var brisk = style
        brisk.speed = max(style.speed, GuidePace.speed)               // (Oct 20, night: its record's times at the guide's pace)
        guard Roam.send(&r, to: place, from: origin, style: brisk, abilities: abilities, plans: life.plans, at: now,
                        stay: Self.guideStay, why: why) else {
            log("guide.refused", ["to": "F\(place.floor) \(LifeLog.cell(place.cell))", "why": "no way there from \(LifeLog.cell(origin))"])
            return false
        }
        // A call it had made at the doors: for its new floor now -- or none.
        if life.car.callOf(residentID) != nil {
            if r.floor == floor { life.car.cancelCall(residentID) } else { life.car.call(residentID, at: floor, to: r.floor, now: now) }
        }
        endActivity("guiding the player")
        dwellingSince = nil
        body.setGuidePace(GuidePace.speed)                            // (Oct 20, night: brisk while it leads)
        life.store(r)
        life.logDecision(r, now: now, offscreen: false)
        log("guide.started", ["to": "F\(place.floor) \(LifeLog.cell(place.cell))", "byCar": r.floor != floor])
        forgetPress()                                                 // (Oct 23: a half-done press is off)
        if r.floor == floor, let cell = r.cell {
            leaving = false
            queueSpot = nil
            walk(to: cell)
        } else {
            leave()
        }
        return true
    }

    /// Oct 20 (tasks): the guiding is over. Cut short (`resumeRoaming`) with its
    /// body here and free -- not at or in the car -- it decides afresh at once;
    /// otherwise it simply carries on (arrived: it lingers, then its own life).
    func releaseGuide(resumeRoaming: Bool) {
        body?.setGuidePace(nil)                                       // (Oct 20, night: its own pace again, at once)
        cabBody?.setGuidePace(nil)
        guard resumeRoaming, let body, !boarding, !exiting, cabBody == nil, let at = body.groundPosition,
              var r = life.resident(residentID), !quietTime else { return }
        let now = BuildingClock.now()
        // (queued at the doors for the task's floor: that trip is off too)
        if leaving {
            leaving = false
            queueSpot = nil
            life.car.cancelCall(residentID)
        }
        forgetPress()                                                 // (Oct 23: a half-done press is off)
        r.floor = floor
        r.cell = context.cells.contains(cellOf(at)) ? cellOf(at) : (Roam.nearestCell(to: at, in: context.cells, cellSize: s) ?? cellOf(at))
        r.leg = nil
        r.since = now
        endActivity("released from guiding")
        Roam.decide(&r, style: style, abilities: abilities, plans: life.plans, at: now)
        life.store(r)
        life.logDecision(r, now: now, offscreen: false)
        log("guide.released", ["next": "F\(r.floor) \(LifeLog.cell(r.cell))"])
        if r.floor == floor, let cell = r.cell { walk(to: cell) } else { leave() }
    }

    /// Oct 20 (follow a critter): chosen to be followed -- its own come-hither,
    /// once; whatever it was doing (a walk, an activity) carries on.
    func acknowledgeFollower(player: SIMD2<Float>?) {
        guard let body else { return }                                      // (in the cab: the doors' business)
        log("follow.acknowledged", ["walking": lead != nil, "activity": activity?.kind.rawValue])
        body.acknowledge(player: player)
    }

    // MARK: Following the player (Oct 23, FOLLOW ME -- CritterMenu.swift)

    /// Walking after the player: its own walk (the lead engine: routes, doors),
    /// re-aimed at its place behind the player a couple of times a second.
    private var followingPlayer = false
    private var nextFollowStep = Date.distantPast
    private var followWatching = false

    var canFollowPlayer: Bool { true }

    func setFollowingPlayer(_ on: Bool) -> Bool {
        let now = BuildingClock.now()
        if on {
            guard !followingPlayer else { return true }
            guard let body, !boarding, !exiting, cabBody == nil, let at = body.groundPosition,
                  var r = life.resident(residentID) else { return false }
            // (queued at the doors, or a call made: that trip is off)
            if leaving || life.car.callOf(residentID) != nil {
                leaving = false
                queueSpot = nil
                life.car.cancelCall(residentID)
            }
            forgetPress()
            endActivity("following the player")
            dwellingSince = nil
            r.floor = floor
            r.cell = walkableCell(at)
            FollowMe.hold(&r, now: now)
            life.store(r)
            followingPlayer = true
            followWatching = false
            nextFollowStep = .distantPast
            body.setGuidePace(GuidePace.speed)                                // (brisk, as when it leads)
            log("followMe.started", ["at": LifeLog.cell(r.cell), "rank": FollowMe.rank(residentID)])
            followStep(now: now)
            return true
        }
        guard followingPlayer else { return true }
        followingPlayer = false
        followWatching = false
        followPace = GuidePace.speed
        lastPlayer = nil; travel = nil; front = nil; faceSince = nil; companionMode = "behind"; lastLoggedMode = ""
        body?.setGuidePace(nil)
        afterWalk = nil
        lead?.cancel()
        lead = nil
        walkDeadline = nil
        walkGoal = nil
        guard let body, let at = body.groundPosition, var r = life.resident(residentID) else { return true }
        body.halt()
        // Back to its own life: it decides afresh, here and now (as a guide released).
        r.floor = floor
        r.cell = walkableCell(at)
        r.leg = nil
        r.since = now
        Roam.decide(&r, style: style, abilities: abilities, plans: life.plans, at: now)
        life.store(r)
        life.logDecision(r, now: now, offscreen: false)
        log("followMe.ended", ["next": "F\(r.floor) \(LifeLog.cell(r.cell))"])
        if r.floor == floor, let cell = r.cell { walk(to: cell) } else { leave() }
        return true
    }

    // MARK: Held still while its menu is open (Oct 23, menu pause -- CritterMenu.swift)

    /// Held: nothing moves it (its tick, the car, following the player all wait).
    private(set) var isHeld = false
    /// The walk it was on when held (to go on with, from where it stands).
    private var heldWalk: (cell: GridCoordinate, point: SIMD2<Float>?, then: (() -> Void)?)?

    func setHeld(_ on: Bool) -> Bool {
        if on {
            guard !isHeld else { return true }
            // (getting into, out of, or riding the car: the doors' business -- not held)
            guard let body, !boarding, !exiting, cabBody == nil else { return false }
            isHeld = true
            if lead != nil, let cell = walkCell {
                heldWalk = (cell, walkGoal, afterWalk)
                afterWalk = nil
                lead?.cancel()
                lead = nil
                generation += 1                               // (nothing of that walk finishes later)
                walkDeadline = nil
            }
            body.halt()                                       // (where it is, facing as it was)
            log("held", ["walking": heldWalk != nil, "at": LifeLog.point(body.groundPosition)])
            return true
        }
        guard isHeld else { return true }
        isHeld = false
        let resumed = heldWalk
        heldWalk = nil
        log("released", ["resumesWalk": resumed != nil])
        // The same walk, on from here (no new decision); standing, it simply carries on
        // (its stay, its activity, following the player: its next tick).
        if let w = resumed, body != nil {
            walk(to: w.cell, point: w.point, purpose: "on again after its menu", then: w.then)
        }
        return true
    }

    private func walkableCell(_ p: SIMD2<Float>) -> GridCoordinate {
        context.cells.contains(cellOf(p)) ? cellOf(p) : (Roam.nearestCell(to: p, in: context.cells, cellSize: s) ?? cellOf(p))
    }

    /// Its place by the player -- Oct 25: mostly AHEAD, in view (companionTarget); where that won't do
    /// (the doors of the car, a doorway, a wall), its old place behind the player (two abreast, a metre a
    /// row, by the order they were asked). On a walkable cell; walk there if it has moved, else watch them.
    private func followStep(now: Date) {
        nextFollowStep = now.addingTimeInterval(0.5)
        guard let body, let at = body.groundPosition, let pose = context.playerPose() else { return }
        let rank = FollowMe.rank(residentID)
        let forward = SIMD2<Float>(-sin(pose.yaw), -cos(pose.yaw))
        let side = SIMD2<Float>(-forward.y, forward.x)
        let back: Float = 1.7 + Float(rank / 2)
        var target = pose.position - forward * back + side * (rank % 2 == 0 ? 0.55 : -0.55)
        if !context.cells.contains(cellOf(target)) {
            let behind = pose.position - forward * back                        // (a narrow corridor: straight behind)
            target = context.cells.contains(cellOf(behind)) ? behind : center(walkableCell(target))
        }
        let companion = companionTarget(pose: pose, rank: rank, now: now)
        if let c = companion { target = c }
        if companion != nil || companionMode != "behind" {
            let mode = companion == nil ? "behind" : companionMode
            if mode != lastLoggedMode { lastLoggedMode = mode; log("followMe.place", ["mode": mode, "rank": rank]) }
        }
        // a long way off (the player strode ahead): a little brisker until it's back with them
        let pace: Float = simd_distance(at, target) > Self.catchUpDistance ? GuidePace.speed * Self.catchUpPace : GuidePace.speed
        if pace != followPace { followPace = pace; body.setGuidePace(pace) }
        let cell = cellOf(target)
        // Its record: here, following (renewed -- the stay never runs out while it follows).
        if var r = life.resident(residentID) {
            let here = walkableCell(at)
            if r.floor != floor || r.cell != here || r.why != FollowMe.why || r.leg != nil || r.nextDecision.timeIntervalSince(now) < 60 {
                r.floor = floor
                r.cell = here
                FollowMe.hold(&r, now: now)
                life.store(r)
            }
        }
        if let goal = walkGoal, lead != nil {
            // (still on its way to about the right place -- unless that walk is overdue: aimed afresh)
            if simd_distance(goal, target) < 1.5, walkDeadline.map({ now < $0 }) ?? true { return }
        } else if simd_distance(at, target) < 0.9 {
            if !followWatching {                                               // (there: it turns to the player)
                followWatching = true
                body.watch(pose.position)
            }
            return
        }
        followWatching = false
        walk(to: cell, point: target, purpose: FollowMe.why) { [weak self] in
            guard let self, self.followingPlayer, let p = self.context.playerPose() else { return }
            self.followWatching = true
            self.body?.watch(p.position)
        }
    }

    // MARK: Companions, mostly ahead (Oct 25)
    //
    // Where a follower walks: AHEAD of the player most of the time (about 80%: within easy sight and
    // reach of a tap), now and then BESIDE them for a while (each its own rhythm), and BEHIND -- its old
    // place -- wherever ahead won't do. "Ahead" is the way the player has actually been GOING (their
    // movement, smoothed -- so a sudden turn leaves a follower going on a moment, then turning back to
    // catch up; it never knows a turn before the player makes it); standing still, the way the player is
    // LOOKING, once they've looked that way a little while (no running about at every glance). Several
    // followers fan out (each its own lateral place and distance, a slow sway of its own). Behind, as
    // before, at the car's doors (never in the way of the elevator), when the place ahead is a wall,
    // furniture, or through a doorway, and in the cab. Nobody is moved anywhere but by its own walk.

    static let catchUpDistance: Float = 6
    static let catchUpPace: Float = 1.35
    /// Ahead of the player (metres): standing, walking; each row of followers this much further.
    static let aheadStanding: Float = 2.3
    static let aheadWalking: Float = 2.8
    static let aheadRow: Float = 0.8
    /// Lateral places by rank (metres; + right of the way ahead).
    static let lanes: [Float] = [0, 1.1, -1.1, 1.9, -1.9, 0.55, -0.55]
    /// Its rhythm: of every `besideCycle` seconds, `besideSpell` beside the player instead of ahead.
    static let besideCycle: Double = 45
    static let besideSpell: Double = 9
    /// The player's looking-direction counts only after this long (seconds) and this much turn (degrees).
    static let faceSettle: TimeInterval = 1.2
    static let faceTurn: Float = 50
    /// Within this of the car's doors (metres): behind.
    static let doorsClearance: Float = 4.5

    private var followPace: Float = GuidePace.speed
    private var lastPlayer: (at: SIMD2<Float>, when: Date)?
    private var travel: SIMD2<Float>?
    private var front: SIMD2<Float>?
    private var faceSince: Date?
    private var companionMode = "behind"
    private var lastLoggedMode = ""

    private var personal: (phase: Double, jitter: Float, ahead: Float) {
        var h: UInt32 = 2166136261
        for u in residentID.unicodeScalars { h = (h ^ u.value) &* 16777619 }
        return (Double(h % 1000) / 1000, Float((h >> 10) % 100) / 100 - 0.5, Float((h >> 17) % 100) / 100 - 0.5)
    }

    /// Its companion place now (nil: behind, as before).
    private func companionTarget(pose: (position: SIMD2<Float>, yaw: Float), rank: Int, now: Date) -> SIMD2<Float>? {
        // the way the player is going (moving), or looking (standing)
        var moving = false
        if let last = lastPlayer {
            let dt = Float(now.timeIntervalSince(last.when))
            if dt >= 0.2 {
                let v = (pose.position - last.at) / dt
                if simd_length(v) > 0.35 {
                    moving = true
                    let dir = simd_normalize(v)
                    let blend = (travel ?? dir) * 0.55 + dir * 0.45                // (it follows the turn, a step behind it)
                    travel = simd_length(blend) > 0.1 ? simd_normalize(blend) : dir
                    front = travel
                    faceSince = nil
                }
                lastPlayer = (pose.position, now)
            } else {
                moving = travel != nil && companionMode == "ahead-walking"
            }
        } else {
            lastPlayer = (pose.position, now)
        }
        let looking = SIMD2<Float>(-sin(pose.yaw), -cos(pose.yaw))
        if !moving {
            travel = nil
            if let f = front {
                let turn = acos(max(-1, min(1, simd_dot(f, looking)))) * 180 / .pi
                if turn > Self.faceTurn {
                    if faceSince == nil { faceSince = now }
                    if let since = faceSince, now.timeIntervalSince(since) >= Self.faceSettle { front = looking; faceSince = nil }
                } else {
                    faceSince = nil
                }
            } else {
                front = looking
            }
        }
        guard let way = front else { return nil }
        // where ahead won't do: in or at the car, a scripted scene's walk
        if playerInElevator { companionMode = "behind"; return nil }
        if let d = playerDistanceToDoors(), d < Self.doorsClearance { companionMode = "behind"; return nil }
        let side = SIMD2<Float>(-way.y, way.x)
        let p = personal
        let lane = Self.lanes[rank % Self.lanes.count] + p.jitter * 0.5
        let sway = Float(sin(Date().timeIntervalSinceReferenceDate / 7 + p.phase * 6.28)) * 0.35
        let cyclePos = (Date().timeIntervalSinceReferenceDate / Self.besideCycle + p.phase).truncatingRemainder(dividingBy: 1)
        let beside = cyclePos < Self.besideSpell / Self.besideCycle
        var ahead = (moving ? Self.aheadWalking : Self.aheadStanding) + Self.aheadRow * Float(rank / 2) + p.ahead * 0.6
        var lateral = lane + sway
        if beside {
            ahead = 0.3
            lateral = (rank % 2 == 0 ? 1.4 : -1.4) + p.jitter * 0.3
        }
        // the place, or a nearer one, or straight ahead -- on a free cell, the same side of every door
        let tries: [(Float, Float)] = [(ahead, lateral), (min(ahead, 1.6), lateral * 0.5), (1.6, 0)]
        for (a, l) in tries {
            let t = pose.position + way * a + side * l
            if openWay(from: pose.position, to: t) {
                companionMode = beside ? "beside" : (moving ? "ahead-walking" : "ahead")
                return t
            }
        }
        companionMode = "behind"
        return nil
    }

    /// From the player to `t`: a walkable, unfurnished cell, reached without crossing any door
    /// (at most two cells away; the player's own cell counts).
    private func openWay(from a: SIMD2<Float>, to t: SIMD2<Float>) -> Bool {
        let start = cellOf(a), goal = cellOf(t)
        guard context.cells.contains(goal) else { return false }
        let plan = life.plans(floor)
        if plan?.furnished.contains(goal) == true { return false }
        if start == goal { return true }
        func door(_ x: GridCoordinate, _ y: GridCoordinate) -> Bool {
            guard let plan else { return false }
            for d in Direction.allCases where x.row + d.delta.row == y.row && x.col + d.delta.col == y.col {
                for doors in [plan.doors, plan.bathroomDoors, plan.windowDoors] {
                    if doors[x] == d || doors[y] == d.opposite { return true }
                }
            }
            return false
        }
        var frontier: [GridCoordinate] = [start]
        var seen: Set<GridCoordinate> = [start]
        for _ in 0..<2 {
            var next: [GridCoordinate] = []
            for c in frontier {
                for d in Direction.allCases {
                    let n = GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
                    guard context.cells.contains(n), !seen.contains(n), !door(c, n) else { continue }
                    if n == goal { return true }
                    seen.insert(n)
                    next.append(n)
                }
            }
            frontier = next
        }
        return false
    }

    /// Oct 18 (phase 2): "Copy Center / working at desk / looking at desk".
    var activityNote: String? {
        guard body != nil else { return nil }
        let doing: String
        if lead != nil {
            doing = leaving ? "heading for the elevator" : (activity?.thing.map { "approaching the \($0.label)" } ?? "walking")
        } else if leaving {
            doing = "waiting for the elevator"
        } else if let a = activity {
            doing = a.kind.rawValue + (a.thing.map { " " + ($0.kind == .desk || $0.kind == .table ? "at the " : "the ") + $0.label } ?? "")
        } else {
            doing = "standing"
        }
        return ResidentActivities.note(room: life.resident(residentID)?.roomName, doing: doing, attention: body?.eyes?.status)
    }

    var debugState: String {
        if cabBody != nil { return "in the car (seen in the cab)" }
        guard let body else { return lastWaitNote ?? "" }
        let at = LifeLog.cell(body.groundPosition.map { cellOf($0) })
        if lead != nil {
            let left = walkDeadline.map { LifeLog.seconds($0.timeIntervalSince(BuildingClock.now())) } ?? "-"
            return (leaving ? "walking to the elevator" : "walking to \(LifeLog.cell(walkCell))") + " from \(at) (deadline in \(left))"
        }
        if leaving { return "at the elevator, waiting" + (lastBlocker.map { " (\($0))" } ?? "") }
        return "standing at \(at)"
    }

    // MARK: Geometry

    private var s: Float { context.cellSize }
    private func cellOf(_ p: SIMD2<Float>) -> GridCoordinate {
        GridCoordinate(row: Int((p.y / s).rounded()), col: Int((p.x / s).rounded()))
    }
    private func center(_ c: GridCoordinate) -> SIMD2<Float> { SIMD2<Float>(Float(c.col) * s, Float(c.row) * s) }
    private func doorPoints() -> (outside: SIMD2<Float>, threshold: SIMD2<Float>, inside: SIMD2<Float>)? {
        guard let d = controller?.elevatorDoorwayFrame() else { return nil }
        return (d.center + d.outward * 1.6, d.center + d.outward * 0.3, d.center - d.outward * 0.9)
    }
    private var playerInElevator: Bool {
        guard let c = controller else { return true }
        return c.isElevatorWaitingForFloor || c.isElevatorRideInProgress
    }
    private func playerDistanceToDoors() -> Float? {
        guard let doors = doorPoints(), let pose = context.playerPose() else { return nil }
        return simd_distance(pose.position, doors.threshold)
    }
    /// Why the elevator isn't free for it right now (nil: free) -- the player,
    /// an escort, an eviction, the meeting, a guiding informant.
    private func elevatorBlocker() -> String? {
        if !Admission.isCompleted { return "onboarding under way" }          // (Oct 18: never a door cycle before the player is admitted)
        if GuidedJourney.trip != nil { return "escort under way" }
        if BonzoEviction.isActive { return "eviction under way" }
        if ConferenceMeeting.isActive { return "meeting under way" }
        if InformantGuide.current?.isGuiding ?? false { return "an informant is guiding" }
        // (Oct 19, one car: the player in the cab or at the doors is no reason to
        // wait -- they share the car.)
        return nil
    }
    /// Oct 18 (open the building): stepped out this long ago, it's already on its way from the doors.
    static let lateArrival: TimeInterval = 8
    /// How long the player beside the doors makes it wait (seconds).
    static let nearDoorsPatience: TimeInterval = 8
    private var elevatorFree: Bool { elevatorBlocker() == nil }
    /// A scripted scene is playing: no new errands for now.
    private var quietTime: Bool { GuidedJourney.trip != nil || BonzoEviction.isActive || ConferenceMeeting.isActive }

    private func log(_ event: String, _ fields: KeyValuePairs<String, Any?> = [:]) {
        LifeLog.event(residentID, event, floor: floor, fields)
    }

    /// A waiting note, said once when it changes (and again at most every 30 s).
    /// `key`: what counts as "the same wait" (a countdown in the note isn't a change).
    private func noteWait(_ note: String, key: String? = nil, now: Date) {
        let k = key ?? note
        lastWaitNote = note
        guard k != lastWaitKey || now.timeIntervalSince(lastWaitNoteAt) >= 30 else { return }
        lastWaitKey = k
        lastWaitNoteAt = now
        log("waiting", ["for": note])
    }

    /// The elevator's blocker, said when it changes (and again at most every 15 s).
    private func noteBlocker(_ blocker: String, purpose: String, now: Date) {
        let kind = blocker.components(separatedBy: " (").first ?? blocker      // ("near the doors (3.1m)": the distance isn't a change)
        let lastKind = lastBlocker.map { $0.components(separatedBy: " (").first ?? $0 }
        lastBlocker = blocker
        guard kind != lastKind || now.timeIntervalSince(lastBlockerAt) >= 15 else { return }
        lastBlockerAt = now
        log("elevator.delayed", ["for": purpose, "reason": blocker])
    }

    // MARK: The tick (the building's, 1 Hz)

    func tick(now: Date) {
        // (Oct 19, one car: in the cab, getting in or out -- carChanged has it, four times a second)
        if cabBody != nil || boarding || exiting { return }
        if isHeld, body != nil { return }                    // Oct 23 (menu pause): still, until let go
        guard var r = life.resident(residentID) else { return }
        guard let body else { maybeAppear(r, now: now); return }
        // Oct 23 (FOLLOW ME): asked to follow the player (a new floor's body too): that, only.
        if !followingPlayer, FollowMe.contains(residentID) { _ = setFollowingPlayer(true) }
        if followingPlayer { followStep(now: now); return }
        if lead != nil {
            checkProgress(body, now: now)
            if let deadline = walkDeadline, now > deadline {
                recoverTimedOutWalk(body, now: now)
            }
            return
        }
        if leaving { tryToLeave(now: now); return }
        // Staying somewhere.
        if Roam.clampStay(&r, style: style, now: now) {
            life.store(r)
            log("dwell.shortened", ["to": LifeLog.seconds(r.nextDecision.timeIntervalSince(now)), "why": "the stay outlasted this pace (fast mode?)"])
        }
        checkStanding(body, record: r, now: now)
        if now >= r.nextDecision, quietTime {
            noteWait("a scripted scene (escort / eviction / meeting) -- no new errands", now: now)
        } else if now >= r.nextDecision {
            log("dwell.ended", ["stayed": dwellingSince.map { LifeLog.seconds(now.timeIntervalSince($0)) }])
            dwellingSince = nil
            endActivity("its stay is over")
            Roam.decide(&r, style: style, abilities: abilities, plans: life.plans, at: now)
            life.store(r)
            life.logDecision(r, now: now, offscreen: false)
            if r.floor == floor, let cell = r.cell {
                walk(to: cell)
            } else {
                leave()
            }
            return
        }
        if var a = activity {
            // Oct 18 (phase 2): its room activity, a beat every few seconds.
            if now >= a.nextBeat, !body.isMoving {
                a.nextBeat = now.addingTimeInterval(Double.random(in: 2.5...5))
                activity = a
                body.activityBeat(a.kind, toward: a.thing?.center)
            }
        } else if now >= nextIdle {
            nextIdle = now.addingTimeInterval(Double.random(in: 12...28))
            self.body?.idle()
        }
    }

    /// Walking: is the body really getting anywhere? (A stall is no progress for
    /// 6 s with no door to push -- a body pushing a door is given 15 s.)
    private func checkProgress(_ body: RoamerBody, now: Date) {
        guard let at = body.groundPosition else { return }
        guard let p = progress, simd_distance(p.point, at) < 0.15 else {
            if stallReported != nil {
                log("walk.resumed", ["at": LifeLog.point(at)])
                stallReported = nil
            }
            progress = (at, now)
            return
        }
        let still = now.timeIntervalSince(p.at)
        let limit: TimeInterval = body.isGesturing ? 15 : 6
        guard still >= limit else { return }
        if let reported = stallReported, now.timeIntervalSince(reported) < 30 { return }
        stallReported = now
        let r = life.resident(residentID)
        let why: String
        if body.isMoving {
            why = "a travel action is running but the body hasn't moved -- SceneKit isn't advancing its actions"
        } else if body.isGesturing {
            why = "stuck in a gesture (a door push?)"
        } else {
            why = "no travel running -- the lead is waiting between steps"
        }
        LifeLog.stall(residentID, "walk.noProgress", floor: floor,
                      ["for": LifeLog.seconds(still), "why": why, "body": LifeLog.point(at), "bodyCell": LifeLog.cell(cellOf(at)),
                       "goal": LifeLog.point(walkGoal), "goalCell": LifeLog.cell(walkCell),
                       "toGo": walkGoal.map { simd_distance(at, $0) }, "record": "F\(r?.floor ?? 0) \(LifeLog.cell(r?.cell))",
                       "moving": body.isMoving, "stepping": body.isStepping, "gesturing": body.isGesturing,
                       "deadlineIn": walkDeadline.map { LifeLog.seconds($0.timeIntervalSince(now)) }])
    }

    /// Standing somewhere: does the record agree with the body, and is it quiet?
    private func checkStanding(_ body: RoamerBody, record r: Resident, now: Date) {
        if body.isStepping, !body.isMoving {
            if !footstepsReported {
                footstepsReported = true
                LifeLog.warn(residentID, "body.footstepsWhileStill", floor: floor,
                             ["at": LifeLog.point(body.groundPosition), "note": "footstep loop running with no travel action"])
            }
        } else {
            footstepsReported = false
        }
        guard let at = body.groundPosition else { return }
        let bodyCell = cellOf(at)
        let key = "\(r.floor) \(LifeLog.cell(r.cell)) / \(LifeLog.cell(bodyCell))"
        if r.floor != floor || r.cell != bodyCell {
            if mismatchReported != key {
                mismatchReported = key
                LifeLog.warn(residentID, "position.mismatch", floor: floor,
                             ["record": "F\(r.floor) \(LifeLog.cell(r.cell))", "body": "F\(floor) \(LifeLog.cell(bodyCell))",
                              "bodyPoint": LifeLog.point(at), "travelling": r.isTravelling(at: now)])
            }
        } else {
            mismatchReported = nil
        }
    }

    /// No body here yet: should it be here (or arriving) now?
    private func maybeAppear(_ r: Resident, now: Date) {
        if r.floor == floor {
            guard let cell = r.cell else {
                noteWait("not placed yet: first decision in \(LifeLog.seconds(r.nextDecision.timeIntervalSince(now)))", key: "notPlaced", now: now)
                return
            }
            if let pose = r.recentPose(on: floor, now: now), pose.at >= (r.leg?.departed ?? .distantPast) {
                // A rebuild of this floor: back where it was, carrying on.
                spawn(at: SIMD2<Float>(pose.x, pose.z), heading: pose.heading, why: "back where it was seen \(LifeLog.seconds(now.timeIntervalSince(pose.at))) ago (rebuild)")
                if r.isTravelling(at: now) || cellOf(SIMD2<Float>(pose.x, pose.z)) != cell { walk(to: cell) } else { arrived() }
                return
            }
            if let leg = r.leg, r.isTravelling(at: now) {
                if leg.changesFloor, leg.from.floor != floor {
                    // Oct 19 (one car): coming here by the car. Out already (unseen): on
                    // its walk from the doors. Still in the car: carChanged shows it in
                    // the cab when the car opens its doors here, and walks it out.
                    if leg.lift == .out, let out = leg.alightAt, let doors = doorPoints() {
                        resumeWalk(from: cellOf(doors.outside), to: cell, departed: out, arrives: r.since, now: now) { [weak self] in
                            self?.walk(to: cell)
                        }
                    } else {
                        noteWait("on its way here by the car (\(leg.lift?.rawValue ?? "?"), car at F\(life.car.position(now: now)?.floor ?? 0))",
                                 key: "byCar F\(leg.from.floor)", now: now)
                    }
                } else {
                    resumeWalk(from: leg.from.cell, to: cell, departed: leg.departed, arrives: r.since, now: now) { [weak self] in
                        self?.walk(to: cell)
                    }
                }
                return
            }
            let home = context.cells.contains(cell) ? cell : (Roam.nearestCell(to: center(cell), in: context.cells, cellSize: s) ?? cell)
            if home != cell {
                LifeLog.warn(residentID, "position.recovered", floor: floor,
                             ["record": LifeLog.cell(cell), "action": "its recorded cell isn't walkable here: shown at \(LifeLog.cell(home))"])
            }
            spawn(at: center(home), heading: Float(Roam.seed(residentID, r.moves) % 628) / 100, why: "staying here when the floor was built")
            if home != cell, var fixed = life.resident(residentID) {
                fixed.cell = home
                life.store(fixed)
            }
            arrived()
        } else if let leg = r.leg, leg.from.floor == floor, r.floor != floor, leg.lift == .riding || leg.lift == .out || leg.boardedAt != nil {
            // Oct 19: it got in -- it is in the car (or upstairs), never shown back
            // here at its pickup (the Dog boarding over and over). (Seen in the cab
            // while the car's doors are open here: carChanged.)
            noteWait("aboard: in the car for F\(r.floor)" + (leg.alightAt.map { ", out in \(LifeLog.seconds($0.timeIntervalSince(now)))" } ?? ""),
                     key: "aboard F\(r.floor)", now: now)
        } else if let leg = r.leg, leg.from.floor == floor, r.isTravelling(at: now),
                  let pose = r.recentPose(on: floor, now: now), pose.at >= leg.departed {
            // A rebuild while it was on its way out: back where it was, still leaving.
            spawn(at: SIMD2<Float>(pose.x, pose.z), heading: pose.heading, why: "rebuilt while leaving for F\(r.floor)")
            leave()
        } else if let leg = r.leg, leg.from.floor == floor, r.floor != floor, leg.lift == .waiting || (leg.lift == .toDoors && now >= (leg.boardAt ?? now)),
                  let doors = doorPoints() {
            // Oct 19 (one car): at the doors, waiting for the car -- there when the player comes.
            let spot = waitingPoint(rank: queueRank(), doors: doors)
            spawn(at: spot, heading: ResidentActivities.heading(from: spot, to: doors.threshold), why: "waiting at the doors for the car")
            leaving = true
            queueSpot = spot
        } else if let leg = r.leg, leg.from.floor == floor, let board = leg.boardAt, now < board,
                  let doors = doorPoints() {
            // Oct 18 (repair): the player has come upon it still walking to this
            // floor's elevator, on its way to F(r.floor): shown on that walk, and on it goes.
            resumeWalk(from: leg.from.cell, to: cellOf(doors.outside), departed: leg.departed, arrives: board, now: now) { [weak self] in
                self?.leave()
            }
        } else {
            noteWait("elsewhere: F\(r.floor) \(LifeLog.cell(r.cell))" + (r.isTravelling(at: now) ? " (travelling)" : ""), now: now)
        }
    }

    /// Oct 18 (repair): the player has come upon it partway along a walk: shown
    /// where it would be by now -- on a cell of its legal route, never an
    /// unplaced body or a point off the plan -- then it carries on from there.
    /// If the route can't be rebuilt, it's set down at its destination, said so.
    private func resumeWalk(from start: GridCoordinate, to end: GridCoordinate, departed: Date, arrives: Date, now: Date,
                            then carryOn: @escaping () -> Void) {
        guard let route = CharacterLead.route(from: start, to: end, cells: context.cells, doors: context.doors), !route.isEmpty else {
            let landing = context.cells.contains(end) ? end : (Roam.nearestCell(to: center(end), in: context.cells, cellSize: s) ?? end)
            LifeLog.warn(residentID, "resume.noRoute", floor: floor,
                         ["from": LifeLog.cell(start), "to": LifeLog.cell(end), "action": "shown at \(LifeLog.cell(landing)) instead"])
            spawn(at: center(landing), heading: 0, why: "mid-journey, route not rebuildable")
            carryOn()
            return
        }
        let i = Roam.resumeIndex(routeCount: route.count, departed: departed, arrives: arrives, now: now)
        let here = route[i]
        let next = i + 1 < route.count ? route[i + 1] : here
        let d = SIMD2<Float>(Float(next.col - here.col), Float(next.row - here.row))
        let facing: Float = simd_length(d) > 0 ? atan2(-d.x, -d.y) : 0
        // Oct 19: just come in at the lobby's front door (the entrance is the lobby's
        // dead end; the doors are on its far wall, behind the player's own walk-in
        // spawn): it appears on the doorstep, inside the doors, not mid-cell.
        if floor == ResidentPolicy.lobbyFloor, i == 0, simd_length(d) > 0,
           let plan = life.plans(floor), let entrance = RoomRegistry.lobbyEntrance(plan), entrance == start {
            let doorstep = center(here) - simd_normalize(d) * (s / 2 - 0.45)
            spawn(at: doorstep, heading: facing, why: "in at the lobby's front door, \(LifeLog.cell(start))->\(LifeLog.cell(end))")
            LifeLog.pop(residentID, "lobby.enteredVisibly", floor: floor,
                        ["doorstep": LifeLog.point(doorstep), "to": LifeLog.cell(end), "attached": body?.root.parent != nil])
            carryOn()
            return
        }
        spawn(at: center(here), heading: facing,
              why: "mid-journey: \(i) of \(route.count - 1) cells along \(LifeLog.cell(start))->\(LifeLog.cell(end))")
        if floor == ResidentPolicy.lobbyFloor {
            LifeLog.pop(residentID, "lobby.seenMidWalk", floor: floor, ["cell": LifeLog.cell(here), "step": "\(i)/\(route.count - 1)"])
        }
        carryOn()
    }

    // MARK: Body

    private func spawn(at p: SIMD2<Float>, heading: Float, why: String) {
        guard let root, body == nil else { return }
        let b = makeBody()
        b.diagnosticID = residentID
        b.place(at: p, heading: heading)
        // Oct 20 (night): still leading the player (a new floor's body, out of the car): brisk.
        if TaskGuide.current?.guide == residentID { b.setGuidePace(GuidePace.speed) }
        root.addChildNode(b.root)
        LifeMarker.attach(to: b.root, text: residentID.uppercased(), height: 1.35)      // (DEBUG test mode only)
        body = b
        if let eyes = b.eyes {
            // Oct 18 (phase 2): what its eyes can see -- the player, and through which doors.
            let ctx = context, size = s
            eyes.player = { ctx.playerPose().map { SIMD3<Float>($0.position.x, 1.55, $0.position.y) } }
            eyes.canSee = { [weak b] p in
                guard let at = b?.groundPosition else { return false }
                let cell = { (q: SIMD2<Float>) in GridCoordinate(row: Int((q.y / size).rounded()), col: Int((q.x / size).rounded())) }
                return CritterSight.connected(cell(at), cell(p), cells: ctx.cells, doors: ctx.doors, isOpen: ctx.isDoorOpen)
            }
        }
        lastWaitNote = nil
        lastWaitKey = nil
        nextIdle = BuildingClock.now().addingTimeInterval(Double.random(in: 6...14))
        log("body.spawned", ["at": LifeLog.point(p), "cell": LifeLog.cell(cellOf(p)), "why": why])
        LifeLog.pop(residentID, "body.attached", floor: floor,
                    ["cell": LifeLog.cell(cellOf(p)), "inScene": b.root.parent != nil, "node": b.root.name, "why": why])
    }

    private func removeBody(_ why: String) {
        endActivity(nil)
        body?.eyes?.stop()
        lead?.cancel()
        lead = nil
        if let body {
            log("body.removed", ["at": LifeLog.point(body.groundPosition), "why": why])
            body.halt()
        }
        body?.root.removeAllAudioPlayers()                // (Oct 18: no sound left playing where it used to be)
        body?.root.removeFromParentNode()
        body = nil
    }

    /// Where it is now, as the record's "last seen".
    private func writePose() {
        guard let body, let p = body.groundPosition, var r = life.resident(residentID) else { return }
        r.shown = ResidentPose(floor: floor, x: p.x, z: p.y, height: 0, heading: body.heading, at: BuildingClock.now())
        life.store(r)
        LifeLog.trace(residentID, "record.poseSaved", floor: floor, ["at": LifeLog.point(p)])
    }

    /// Oct 19: the boarded body leaves the scene (concealed by shut doors, or the scene going).
    private func dropCabBody(_ why: String) {
        guard let b = cabBody else { return }
        cabBody = nil
        cabSlot = nil
        b.eyes?.stop()
        b.halt()
        b.root.removeAllAudioPlayers()
        b.root.removeFromParentNode()
        log("body.removed", ["at": LifeLog.point(b.groundPosition), "why": "in the car: \(why)"])
    }

    func teardown() {
        generation += 1
        isHeld = false                                        // Oct 23 (menu pause): never held past its scene
        heldWalk = nil
        forgetPress()
        dropCabBody("scene going")
        if !boarding && !exiting { writePose() }     // (getting in or out it's in the doorway, not anywhere to come back to)
        if boarding || exiting { life.car.release(residentID) }
        removeBody("scene going (rebuild / floor change)")
        boarding = false
        exiting = false
        cabSlot = nil
        leaving = false
    }

    // MARK: Walking (the building's lead engine, nobody to wait for)

    private func walk(to cell: GridCoordinate, point: SIMD2<Float>? = nil, purpose: String? = nil, then: (() -> Void)? = nil) {
        guard let body, var me = body.groundPosition else { return }
        if lead != nil { log("walk.replanned", ["to": LifeLog.cell(cell)]) }
        lead?.cancel()
        lead = nil
        body.halt()                                       // (nothing of an old walk keeps moving it)
        generation += 1
        let gen = generation
        let goal = point ?? center(cell)
        var from = cellOf(me)
        // Oct 18 (repair): a walk only ever starts from a walkable cell.
        if !context.cells.contains(from) {
            guard let fixed = Roam.nearestCell(to: me, in: context.cells, cellSize: s) else { return }
            LifeLog.warn(residentID, "route.badOrigin", floor: floor,
                         ["body": LifeLog.point(me), "cell": LifeLog.cell(from), "action": "moved to the nearest walkable cell \(LifeLog.cell(fixed))"])
            from = fixed
            me = center(fixed)
            body.place(at: me, heading: body.heading)
        }
        var steps: [CharacterLead.Step]
        // Oct 19 (wall-crossing): bathroom and window-room doors are never walked
        // through (they aren't doors it can open -- the same rule as its offscreen
        // plan, FloorPlan.route); room-entrance doors are pushed open on the way.
        var shut = life.plans(floor)?.bathroomDoors ?? [:]
        shut.merge(life.plans(floor)?.windowDoors ?? [:]) { a, _ in a }
        let route = CharacterLead.route(from: from, to: cell, cells: context.cells, doors: shut, canCross: { _ in false })
        if let route, route.count >= 2 {
            // Oct 19 (wall-crossing): corners at cell centres (it keeps no waiting stops).
            steps = CharacterLead.plan(route: route, context: context, finalPoint: goal, turnAtCentres: true).filter { step in
                if case .stop(let s) = step { return s.isFinal }
                return true
            }
            // Never expected: said once if the walk as planned would leave the walkable cells.
            var walked = [me]
            for step in steps { if case .travel(let pts) = step { walked += pts } }
            if let off = CharacterLead.firstPointOffCells(walked, cells: context.cells, cellSize: s) {
                LifeLog.warn(residentID, "route.leavesWalkable", floor: floor,
                             ["from": LifeLog.cell(from), "to": LifeLog.cell(cell), "at": LifeLog.point(off), "offCell": LifeLog.cell(cellOf(off)),
                              "note": "the planned path crosses a non-walkable cell (walked anyway; please report)"])
            }
        } else if from == cell {
            // Within its own cell: a step or two, nothing to cross.
            steps = [.travel([goal]), .stop(CharacterLead.Stop(point: goal, onward: nil, isFinal: true, cell: cell))]
        } else {
            // Oct 18 (repair): no route = no walk. Never a straight line through walls:
            // it stays where it is (a walkable cell) and decides again shortly.
            LifeLog.warn(residentID, "route.failed", floor: floor,
                         ["from": LifeLog.cell(from), "to": LifeLog.cell(cell), "toWalkable": context.cells.contains(cell),
                          "action": "stays at \(LifeLog.cell(from)), decides again in 10s"])
            routeFailed(at: from)
            return
        }
        var doorCount = 0, travelLegs = 0
        for step in steps {
            if case .door = step { doorCount += 1 }
            if case .travel = step { travelLegs += 1 }
        }
        let length = Float(max(1, (route?.count ?? 2) - 1)) * s + simd_distance(me, goal) * 0.3
        walkEstimate = Double(length / max(0.1, body.speed)) + Double(doorCount) * 4      // (a door push: ~4 s)
        walkDeadline = BuildingClock.now().addingTimeInterval(walkEstimate * 1.6 + 8)
        walkGoal = goal
        walkCell = cell
        walkStarted = BuildingClock.now()
        progress = nil
        stallReported = nil
        afterWalk = then
        body.eyes?.destination = SIMD3<Float>(goal.x, 0.9, goal.y)          // (Oct 18: it looks where it's going)
        log("walk.started", ["from": LifeLog.cell(from), "to": LifeLog.cell(cell), "goal": LifeLog.point(goal),
                             "routeCells": route?.count, "doors": doorCount, "legs": travelLegs,
                             "estimate": LifeLog.seconds(walkEstimate), "purpose": purpose ?? (then == nil ? "destination" : "to the elevator")])
        let lead = CharacterLead(performer: body, context: context, steps: steps)
        lead.name = "resident.\(residentID)"
        lead.onFinish = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.finishWalk()
        }
        lead.onLost = { [weak self] in
            guard let self, self.generation == gen else { return }
            LifeLog.warn(self.residentID, "walk.bodyLost", floor: self.floor, ["note": "its body left the scene mid-walk"])
            self.lead = nil
            self.body = nil
        }
        self.lead = lead
        lead.start()
    }

    /// Oct 18 (repair): a walk past its deadline is said to be what it is -- a
    /// timeout, with where the body got to and why -- and then deliberately put
    /// right: the body stopped, then set down at its goal (a walkable cell on its
    /// legal route), and its stay begins there. Never logged as a completed walk.
    private func recoverTimedOutWalk(_ body: RoamerBody, now: Date) {
        let at = body.groundPosition
        LifeLog.warn(residentID, "walk.timedOut", floor: floor,
                     ["goal": LifeLog.point(walkGoal), "goalCell": LifeLog.cell(walkCell), "body": LifeLog.point(at),
                      "bodyCell": LifeLog.cell(at.map { cellOf($0) }),
                      "toGo": at.flatMap { a in walkGoal.map { simd_distance(a, $0) } }, "moving": body.isMoving,
                      "gesturing": body.isGesturing, "estimate": LifeLog.seconds(walkEstimate),
                      "took": walkStarted.map { LifeLog.seconds(now.timeIntervalSince($0)) }])
        lead?.cancel()
        lead = nil
        body.halt()
        if let goal = walkGoal {
            let facing = at.map { a -> Float in
                let d = goal - a
                return simd_length(d) > 0.05 ? atan2(-d.x, -d.y) : body.heading
            } ?? body.heading
            body.place(at: goal, heading: facing)
        }
        log("walk.recovered", ["action": "set down at its goal", "cell": LifeLog.cell(walkCell)])
        endWalk(recovered: true)
    }

    private func finishWalk() {
        lead?.cancel()
        lead = nil
        let took = walkStarted.map { BuildingClock.now().timeIntervalSince($0) } ?? 0
        log("walk.completed", ["at": LifeLog.point(body?.groundPosition), "cell": LifeLog.cell(body?.groundPosition.map { cellOf($0) }),
                               "goalCell": LifeLog.cell(walkCell), "took": LifeLog.seconds(took), "estimate": LifeLog.seconds(walkEstimate)])
        endWalk(recovered: false)
    }

    private func endWalk(recovered: Bool) {
        walkDeadline = nil
        walkGoal = nil
        walkStarted = nil
        progress = nil
        stallReported = nil
        if let then = afterWalk {
            afterWalk = nil
            then()
            return
        }
        arrived(recovered: recovered)
    }

    /// Oct 18 (repair): its walk couldn't be routed. It stays put in the walkable
    /// cell it's in -- on this floor, the record says so -- and decides again soon.
    private func routeFailed(at cell: GridCoordinate) {
        leaving = false
        forgetPress()                                                 // (Oct 23)
        afterWalk = nil
        walkDeadline = nil
        walkGoal = nil
        guard var r = life.resident(residentID) else { return }
        let now = BuildingClock.now()
        r.floor = floor
        r.cell = cell
        r.leg = nil
        r.since = now
        r.dwell = 10
        r.why = "its route failed: waiting a moment, then deciding again"
        life.store(r)
        dwellingSince = now
        log("dwell.started", ["cell": LifeLog.cell(cell), "for": LifeLog.seconds(10), "why": r.why])
    }

    /// There: the record says so from now (its stay counts from its real arrival).
    private func arrived(recovered: Bool = false) {
        guard var r = life.resident(residentID), r.floor == floor else { return }
        let now = BuildingClock.now()
        if r.leg != nil || r.since > now {
            LifeLog.trace(residentID, "record.synced", floor: floor,
                          ["recordSaidThereIn": LifeLog.seconds(r.since.timeIntervalSince(now)), "now": "arrived"])
            r.leg = nil
            r.since = now
            life.store(r)
        }
        dwellingSince = now
        mismatchReported = nil
        log("dwell.started", ["cell": LifeLog.cell(r.cell), "bodyCell": LifeLog.cell(body?.groundPosition.map { cellOf($0) }),
                              "for": LifeLog.seconds(r.nextDecision.timeIntervalSince(now)), "why": r.why,
                              "afterRecovery": (recovered ? true : nil) as Bool?])
        body?.settle(facing: nil)
        beginActivity(r, now: now)
    }

    // MARK: Room activities (Oct 18, phase 2)

    /// In a room: find what's there, choose what to do about it, go up to it.
    /// (Not in a room -- a hallway spot -- it simply looks about.)
    private func beginActivity(_ r: Resident, now: Date) {
        endActivity(nil)
        guard let body, let root, let me = body.groundPosition else { return }
        body.eyes?.destination = nil
        let cells = r.room.flatMap { id in life.plans(floor)?.rooms.first(where: { $0.id == id })?.cells }
        guard let cells else {
            activity = Activity(kind: .lookingAround, thing: nil, nextBeat: now.addingTimeInterval(2))
            log("activity.chosen", ["kind": "looking around", "why": "not in a room"])
            return
        }
        let things = RoomThings.find(in: root, cells: cells, cellSize: s)
        let choice = ResidentActivities.choose(for: body.activitySpecies, things: things, seed: Roam.seed(residentID, r.moves) ^ 0xA11CE)
        activity = Activity(kind: choice.kind, thing: choice.thing, nextBeat: now.addingTimeInterval(3))
        log("activity.chosen", ["room": r.roomName, "kind": choice.kind.rawValue, "thing": choice.thing?.label,
                                "inRoom": things.isEmpty ? "nothing catalogued" : things.map { $0.label }.joined(separator: ", ")])
        guard let thing = choice.thing else {
            if choice.kind == .resting { body.eyes?.setResting(true) }
            return
        }
        body.eyes?.setFocus(thing.label, at: thing.lookPoint, style: choice.kind == .working ? .work : .study)
        let ctx = context
        let allowed: (SIMD2<Float>) -> Bool = { [weak self] p in
            guard let self else { return false }
            let c = self.cellOf(p)
            return cells.contains(c) && ctx.cells.contains(c)
        }
        let token = activityToken
        let faceIt: () -> Void = { [weak self] in
            guard let self, self.activityToken == token, let body = self.body else { return }
            body.turn(toward: thing.center, duration: 0.6)
            if choice.kind != .working { body.eyes?.react(.curious, for: 1.5) }
        }
        guard let stand = ResidentActivities.standPoint(for: thing, from: me, standoff: 0.35, allowed: allowed) else {
            faceIt()                                         // (nowhere beside it to stand: it regards it from here)
            return
        }
        if cellOf(stand) == cellOf(me) {
            body.travel([stand]) { faceIt() }
        } else if var rec = life.resident(residentID) {
            rec.cell = cellOf(stand)                         // (its place in the room is now beside the thing)
            life.store(rec)
            walk(to: cellOf(stand), point: stand, purpose: "up to the \(thing.label)") { faceIt() }
        }
    }

    /// The activity stops (a decision, the elevator, the floor going): nothing of it lingers.
    private func endActivity(_ why: String?) {
        activityToken += 1
        guard activity != nil else { return }
        if let why { log("activity.ended", ["kind": activity?.kind.rawValue, "why": why]) }
        activity = nil
        body?.eyes?.clearFocus()
        body?.eyes?.setResting(false)
        body?.rise()
    }

    // MARK: The elevator (Oct 19: THE car -- it calls it, waits, gets in, rides, gets out)

    private func leave() {
        if let tf = BuildingLife.testFloor {
            // (the controlled test never changes floors -- if a decision somehow did, it stays)
            LifeLog.warn(residentID, "test.elevatorBlocked", floor: floor, ["note": "test mode on F\(tf): no floor changes"])
            stayOnThisFloor()
            return
        }
        guard let doors = doorPoints(), abilities.contains(.rideElevator) else {
            log("elevator.unavailable", ["why": abilities.contains(.rideElevator) ? "no elevator doors on this floor" : "it can't ride"])
            stayOnThisFloor()
            return
        }
        // Oct 18 (phase 2): a backward look at what it was busy with, then the way out.
        if let eyes = body?.eyes, let thing = activity?.thing {
            eyes.hesitate(between: SIMD3<Float>(doors.threshold.x, 1.2, doors.threshold.y), aName: "the elevator",
                          and: thing.lookPoint, bName: "the \(thing.label)")
        }
        endActivity("leaving for another floor")
        leaving = true
        lastBlocker = nil
        let spot = waitingPoint(rank: queueRank(), doors: doors)             // (Oct 19: its own place at the doors)
        queueSpot = nil
        walk(to: cellOf(spot), point: spot) { [weak self] in
            self?.queueSpot = spot
            self?.body?.settle(facing: ResidentActivities.heading(from: spot, to: doors.threshold))
        }
    }

    /// It can't ride from here (no doors, the test): somewhere on this floor instead.
    // MARK: Pressing the hall button (Oct 23)

    /// Since when it has been on its way to the hall button, or pressing it.
    private var pressingSince: Date?
    private var pressToken = 0

    /// Walk up to its way's hall button and press it (its own touch gesture --
    /// every body has one: the lunge it pushes doors with). The call goes to the
    /// dispatcher at the touch, and the button lights. False: nothing to press
    /// (already lit, no such button here, no body) -- it calls as before.
    private func pressHallButton(doors: (outside: SIMD2<Float>, threshold: SIMD2<Float>, inside: SIMD2<Float>), now: Date) -> Bool {
        guard let body, let me = body.groundPosition, let c = controller, c.elevatorFloor == floor,
              let r = life.resident(residentID), r.floor != floor else { return false }
        let way = r.floor > floor ? 1 : -1
        guard !c.hallCallLit.contains(way), let b = c.hallCallButtonPoint(way) else { return false }
        let button = SIMD2<Float>(b.x, b.z)
        // In front of the button, on the hall side of the doors' wall.
        let outward = doors.outside - doors.threshold
        let out = simd_length(outward) > 0.01 ? simd_normalize(outward) : SIMD2<Float>(0, 1)
        var stand = button + out * 0.6
        if !context.cells.contains(cellOf(stand)) { stand = center(walkableCell(stand)) }
        pressingSince = now
        pressToken += 1
        let token = pressToken
        let id = residentID, from = floor
        log("callButton.going", ["way": way > 0 ? "up" : "down", "for": "F\(r.floor)"])
        let press: () -> Void = { [weak self] in
            guard let self, self.pressToken == token, let body = self.body else { return }
            body.touch(button, contact: { [weak self] in
                guard let self, self.pressToken == token else { return }
                let t = BuildingClock.now()
                self.life.callCar(id, now: t)                                         // (into the dispatcher, as ever)
                self.controller?.showResidentHallCall(way)                            // (lit, as the player's press lights it)
                LifeLog.event(id, "callButton.pressed", floor: from, ["way": way > 0 ? "up" : "down"])
            }, then: { [weak self] in
                guard let self, self.pressToken == token else { return }
                self.pressingSince = nil
                self.queueSpot = nil                                                  // (back to its place at the doors)
            })
        }
        if simd_distance(me, stand) > 0.35 {
            walk(to: cellOf(stand), point: stand, purpose: "to the call button", then: press)
        } else {
            press()
        }
        return true
    }

    /// (Its press is off: it stopped leaving, the scene went, it was asked to follow...)
    private func forgetPress() {
        pressingSince = nil
        pressToken += 1
    }

    private func stayOnThisFloor() {
        forgetPress()
        endActivity("staying on this floor instead")
        leaving = false
        guard var r = life.resident(residentID) else { return }
        let now = BuildingClock.now()
        if r.floor != floor || r.leg != nil {
            r.floor = floor
            r.cell = body?.groundPosition.map { cellOf($0) } ?? r.leg?.from.cell ?? r.cell
        }
        Roam.decide(&r, style: style, abilities: abilities, plans: life.plans, at: now, allowFloorChange: false)
        life.store(r)                                             // (its trip is off: the car's call goes with it -- liftSync)
        life.logDecision(r, now: now, offscreen: false)
        if r.floor == floor, let cell = r.cell { walk(to: cell) }
    }

    /// At the doors (1 Hz): in its place in the queue, it calls the car -- and
    /// waits, however long the car takes (carChanged gets it in).
    private func tryToLeave(now: Date) {
        guard let doors = doorPoints() else { stayOnThisFloor(); return }
        guard !boarding else { return }
        // Oct 23: on its way to (or at) the hall button: that first (never stuck there).
        if let since = pressingSince {
            if now.timeIntervalSince(since) < 15 { return }
            pressingSince = nil
            log("callButton.abandoned", ["why": "the press didn't finish in 15 s"])
        }
        // Its own place at the doors -- the next to board in front, the rest beside
        // and behind, each its own spot (no stacking), in the order they called.
        let rank = queueRank()
        let spot = waitingPoint(rank: rank, doors: doors)
        let moved = queueSpot.map { simd_distance($0, spot) > 0.3 } ?? true
        if moved, let at = body?.groundPosition, simd_distance(at, spot) > 0.4 {
            walk(to: cellOf(spot), point: spot, purpose: rank == 0 ? "to the doors" : "to its place in the queue (\(rank) ahead)") { [weak self] in
                self?.queueSpot = spot
                self?.body?.settle(facing: ResidentActivities.heading(from: spot, to: doors.threshold))
            }
            return
        }
        queueSpot = spot
        // (a scripted scene holding the building's attention: it waits without calling --
        // no doors opening and shutting for nobody meanwhile)
        if let blocker = elevatorBlocker() {
            noteBlocker(blocker, purpose: "calling the car", now: now)
            return
        }
        // Oct 23 (critters call the car): no call of its own yet and its way's button
        // isn't lit -- it goes and presses it (the call is made as it touches it,
        // and the button lights). Lit already (someone's call stands): it just waits.
        if life.car.callOf(residentID) == nil, life.car.rider(residentID) == nil, pressHallButton(doors: doors, now: now) { return }
        life.callCar(residentID, now: now)                          // (once: a missed call stands; the car comes back for it)
        let car = life.car
        let doing = car.position(now: now).map { "car at F\($0.floor), \($0.state)" } ?? "car not placed"
        noteWait("at the doors, waiting for the car (\(doing))", key: "atDoors", now: now)
    }

    /// The car's doors are open here: those at them walk in, one to each place
    /// in the cab; those it brought here walk out; anyone riding on is seen
    /// standing in the cab until the doors shut. Four times a second.
    func carChanged(now: Date) {
        if isHeld, body != nil, cabBody == nil, !boarding, !exiting { return }      // Oct 23 (menu pause): still
        // Oct 23 (FOLLOW ME): following the player -- re-aimed twice a second; never at the car.
        if followingPlayer, cabBody == nil, !boarding, !exiting {
            if now >= nextFollowStep { followStep(now: now) }
            return
        }
        let car = life.car
        guard let s = car.state, let doors = doorPoints() else { return }
        let standingHere = s.target == nil && s.floor == floor
        let parting = standingHere && (s.doors == .opening || s.doors == .open)
        let open = standingHere && s.doors == .open
        let r = life.resident(residentID)
        let aboard = car.rider(residentID) != nil
        // In the cab and the doors have shut on it (and the player isn't in there with it): out of sight.
        if cabBody != nil, !parting, (s.doors == .closed || !standingHere), !(controller?.playerInCab ?? false) {
            dropCabBody(standingHere ? "the doors shut on it" : "the car left")
        }
        // Walking in: the doors stay open for it.
        if boarding { car.hold(residentID, until: now.addingTimeInterval(3)); return }
        if exiting { car.hold(residentID, until: now.addingTimeInterval(3)); return }
        // At the doors, waiting, and they're open here: in it goes.
        if leaving, lead == nil, open, body != nil, !aboard, r?.leg?.lift == .waiting {
            if let blocker = elevatorBlocker() {
                noteBlocker(blocker, purpose: "getting in", now: now)
            } else {
                boardNow(doors: doors, now: now)
            }
            return
        }
        // In the car: arriving here, or riding on.
        guard aboard, let r, body == nil else { return }
        if r.floor == floor, r.leg?.lift == .riding {
            // Its floor: there in the cab as the doors part; out once they're open.
            if parting, cabBody == nil { showInCab(doors: doors, why: "in the car as its doors open on its floor") }
            if open, let b = cabBody { stepOut(b, doors: doors, now: now) }
        } else if parting, cabBody == nil {
            showInCab(doors: doors, why: "riding on: seen in the car while its doors are open here")
        }
    }

    /// Walk in (holding the doors), then aboard: it stays in sight, standing in the cab.
    private func boardNow(doors: (outside: SIMD2<Float>, threshold: SIMD2<Float>, inside: SIMD2<Float>), now: Date) {
        guard let body else { return }
        let car = life.car
        let slot = freeCabSlot()
        cabSlot = slot
        let spot = cabPoint(slot, doors: doors)
        boarding = true
        car.hold(residentID, until: now.addingTimeInterval(4))
        let gen = generation
        let journey = life.resident(residentID).map { Resident.journeyName($0) } ?? residentID
        LifeLog.pop(residentID, "boarding.started", floor: floor, ["journey": journey, "car": car.position(now: now)?.state])
        endActivity("getting into the car")
        lead?.cancel()
        lead = nil
        // (at most 8 s: a walk whose completion never came still ends -- set down in its place)
        let finish = Self.once(within: 8) { [weak self, weak body] in
            guard let self, self.generation == gen else { return }
            if let body, let at = body.groundPosition, simd_distance(at, spot) > 0.2 { body.halt(); body.place(at: spot, heading: body.heading) }
            self.boarding = false
            self.life.car.release(self.residentID)
            if self.life.boarded(self.residentID, now: BuildingClock.now()), let b = self.body {
                // In: seen standing in the cab, facing the doors, until they shut on it.
                b.turn(toward: doors.outside, duration: 0.5)
                self.body = nil
                self.cabBody = b
                self.leaving = false
                self.queueSpot = nil
                self.log("elevator.boarded", ["slot": slot])
            } else {
                // (the doors had closed: back to its place at the doors, still waiting)
                self.cabSlot = nil
                self.log("elevator.missed", ["note": "the doors closed before it was in; back to the queue"])
                self.queueSpot = nil
            }
        }
        body.travel([doors.threshold, doors.inside, spot]) { finish() }
    }

    /// Out of the cab and on to its place.
    private func stepOut(_ b: RoamerBody, doors: (outside: SIMD2<Float>, threshold: SIMD2<Float>, inside: SIMD2<Float>), now: Date) {
        exiting = true
        cabBody = nil
        cabSlot = nil
        body = b
        life.car.hold(residentID, until: now.addingTimeInterval(4))
        let gen = generation
        LifeLog.pop(residentID, "exit.started", floor: floor, ["journey": life.resident(residentID).map { Resident.journeyName($0) }])
        let finish = Self.once(within: 8) { [weak self, weak b] in
            guard let self, self.generation == gen else { return }
            if let b, let at = b.groundPosition, simd_distance(at, doors.outside) > 0.2 { b.halt(); b.place(at: doors.outside, heading: b.heading) }
            self.exiting = false
            self.life.alighted(self.residentID, now: BuildingClock.now())
            self.life.car.release(self.residentID)
            guard let r = self.life.resident(self.residentID), let cell = r.cell else { return }
            self.walk(to: cell)
        }
        b.travel([doors.threshold, doors.outside]) { finish() }
    }

    /// `done` exactly once: when called, or at the latest after `seconds`.
    private static func once(within seconds: Double, _ done: @escaping () -> Void) -> () -> Void {
        var called = false
        let fire = { if !called { called = true; done() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { fire() }
        return fire
    }

    /// A body standing in the cab (its place in it), facing the doors.
    private func showInCab(doors: (outside: SIMD2<Float>, threshold: SIMD2<Float>, inside: SIMD2<Float>), why: String) {
        guard body == nil, cabBody == nil else { return }
        let slot = freeCabSlot()
        cabSlot = slot
        let p = cabPoint(slot, doors: doors)
        let d = doors.outside - p
        spawn(at: p, heading: atan2(-d.x, -d.y), why: why)
        cabBody = body
        body = nil
    }

    /// Its place in the cab: 0 and 1 to either side, 2 at the back (the middle is the player's).
    private var cabSlot: Int?
    private func freeCabSlot() -> Int {
        let taken = Set(life.presentations.compactMap { $0 as? RoamPresentation }.filter { $0 !== self && $0.floor == floor }.compactMap { $0.cabSlot })
        return (0..<3).first { !taken.contains($0) } ?? 2
    }
    private func cabPoint(_ slot: Int, doors: (outside: SIMD2<Float>, threshold: SIMD2<Float>, inside: SIMD2<Float>)) -> SIMD2<Float> {
        let out = doors.outside - doors.inside
        guard simd_length(out) > 0.01 else { return doors.inside }
        let o = simd_normalize(out)
        let side = SIMD2<Float>(-o.y, o.x)
        switch slot {
        case 0: return doors.inside + side * Self.cabSideOffset
        case 1: return doors.inside - side * Self.cabSideOffset
        default: return doors.inside - o * 0.6
        }
    }

    // MARK: Oct 19 -- waiting at the doors

    /// Its place among those waiting at these doors: 0 is the first to have
    /// called (or, not called yet, the first there).
    private func queueRank() -> Int {
        let car = life.car
        let waiting = life.presentations.compactMap { $0 as? RoamPresentation }
            .filter { $0.floor == floor && $0.leaving && $0.body != nil && !$0.boarding }
        func key(_ p: RoamPresentation) -> (Double, String) {
            (car.callOf(p.residentID)?.since.timeIntervalSinceReferenceDate ?? .greatestFiniteMagnitude, p.residentID)
        }
        let sorted = waiting.sorted { key($0) < key($1) }
        return sorted.firstIndex { $0 === self } ?? 0
    }

    /// Where the rank-th waiting resident stands: the next to board right in front
    /// of the doors, the others to either side and further back -- never between
    /// the doors and the one whose turn it is. Only walkable places count.
    private func waitingPoint(rank: Int, doors: (outside: SIMD2<Float>, threshold: SIMD2<Float>, inside: SIMD2<Float>)) -> SIMD2<Float> {
        let d = doors.outside - doors.threshold
        guard simd_length(d) > 0.01 else { return doors.outside }
        let out = simd_normalize(d)
        let side = SIMD2<Float>(-out.y, out.x)
        let offsets: [(Float, Float)] = [(0, 0), (1.05, 0.6), (-1.05, 0.6), (0, 1.7), (1.05, 2.3), (-1.05, 2.3), (0, 3.2), (1.05, 3.9), (-1.05, 3.9)]
        let spots = offsets.map { doors.outside + side * $0.0 + out * $0.1 }.filter { context.cells.contains(cellOf($0)) }
        guard !spots.isEmpty else { return doors.outside }
        return spots[min(rank, spots.count - 1)]
    }

    /// Oct 19: how far to the side of the cab's middle a resident stands (m).
    static let cabSideOffset: Float = 0.55
}
