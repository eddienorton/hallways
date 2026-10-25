//
//  BuildingLife.swift
//  Hallways
//
//  Oct 18 -- BUILDING LIFE: residents who live in the building whether or
//  not anyone is looking. "A critter's existence should not depend on the
//  player's attention. Its level of simulation can."
//
//  Deliberately small -- not an AI framework. Four pieces:
//
//    Resident        plain data (Codable, no SceneKit): who, what kind,
//                    which floor and cell, since when, how long it stays,
//                    the journey under way, what it remembers per problem,
//                    and where its body was last seen.
//    ResidentKind    one per species: its newcomers, its offscreen life
//                    (`advance`: worked forward to now, cheaply, no
//                    SceneKit), and its presentation on a floor.
//    BuildingLife    the one owner of the records: loads/saves them, runs a
//                    1 Hz tick while the app is active (offscreen residents
//                    advance; on-floor presentations get their tick), and
//                    catches up after backgrounding or a relaunch (each kind
//                    caps how far it replays).
//    FloorPresenter  when a floor is built: tears the old presentations down
//                    (each writes its body's state back first) and asks every
//                    kind for its presentation on the new floor.
//
//  The boundary: the RECORD is the truth. A presentation (a body in the
//  scene) acts it out and, while it does, "holds" the record -- BuildingLife
//  leaves a held record alone. Anything a body does through SceneKit has a
//  bounded completion (a deadline, a watchdog), so a scene that stops running
//  its actions can delay a resident but never stop its life.
//
//  Kinds today: the butterfly (GameFixture.swift -- her haunts, her informant
//  role) and the roaming chair (ResidentChair.swift, using ResidentRoam.swift).
//

import SceneKit
import SwiftUI
import UIKit
import simd
import Combine

// MARK: - The clock

/// The building's one clock: real time (no invented game time). Tests swap
/// `now`; everything a resident decides or saves reads it.
enum BuildingClock {
    static var now: () -> Date = { Date() }
}

// MARK: - Plain data

/// What a resident's body can do (a kind never assumes more).
enum ResidentAbility: String, Codable, CaseIterable {
    case walk, fly, rideElevator
}

/// A place in the building.
struct ResidentPlace: Codable, Equatable {
    var floor: Int
    var cell: GridCoordinate
}

/// A journey under way. Between floors it also says when the resident boards
/// the elevator where it came from, and when it steps out where it's going.
struct ResidentLeg: Codable, Equatable {
    var from: ResidentPlace
    var departed: Date
    var boardAt: Date?
    var alightAt: Date?
    /// Oct 19: when it got into the car (doors shut behind it) -- from then on the
    /// trip is under way: never re-booked, never shown back at its pickup. nil:
    /// not aboard yet. (Optional: older saves decode without it.)
    var boardedAt: Date? = nil
    /// Oct 19 (one car): where a trip between floors is -- walking to the doors,
    /// waiting at them (the car called), riding, out and walking on. nil: a walk
    /// on one floor (or an older save's trip, migrated on load). With it,
    /// `boardAt` is only when it expects to reach the doors (never a booking) and
    /// `alightAt` is when it really got out (nil until then).
    var lift: LiftStage? = nil
    /// Seconds from the doors to its place on the destination floor (its walk there).
    var outWalk: Double? = nil
    var changesFloor: Bool { lift != nil || alightAt != nil }
}

/// Oct 19 (one car): a trip between floors, step by step.
enum LiftStage: String, Codable {
    case toDoors, waiting, riding, out
}

/// Where its body was last seen (a rebuild of the same floor puts it back there).
struct ResidentPose: Codable, Equatable {
    var floor: Int
    var x: Float
    var z: Float
    var height: Float
    var heading: Float
    var at: Date
}

/// One resident of the building.
struct Resident: Codable {
    /// Stable for its whole life ("butterfly", "chair.1").
    var id: String
    /// Its ResidentKind.
    var kind: String
    /// Where it is -- or, while `since` is still ahead, where it is going.
    var floor: Int
    var cell: GridCoordinate?
    /// It got (or gets) there at `since`...
    var since: Date
    /// ...and stays this many seconds: its next decision is at since + dwell.
    var dwell: Double
    /// Decisions so far (seeds its choices: the same life replays the same way).
    var moves = 0
    /// Its place in its kind's list of favourite places, if it keeps one.
    var haunt = 0
    /// The journey under way (nil when it's there).
    var leg: ResidentLeg?
    /// What it remembers of its problems, per problem (the informant memory).
    var memories: [String: InformantMemory] = [:]
    /// Where its body was last seen.
    var shown: ResidentPose?
    /// Why it is where it is / going where it's going (diagnostics: "room: Break Room on F5"...).
    var why: String?
    /// Oct 18 (room-based life): the room it's in / going to (RoomDestination.id) and its name.
    /// A room edited away is simply not chosen again; nothing else depends on it.
    var room: String?
    var roomName: String?

    init(id: String, kind: String, floor: Int, cell: GridCoordinate?, since: Date, dwell: Double) {
        self.id = id
        self.kind = kind
        self.floor = floor
        self.cell = cell
        self.since = since
        self.dwell = dwell
    }

    var nextDecision: Date { since.addingTimeInterval(dwell) }
    /// Oct 22 (stability pass): riding (or waiting for) the car to another floor --
    /// `since` is the sentinel .distantFuture ("there when the car has brought it"),
    /// not a time. The schedule is right; only the logs printed it as ~62 billion
    /// seconds (distantFuture minus now). Reports say "after the car" instead.
    var awaitsCar: Bool { since == .distantFuture }
    /// Oct 19: "chair.1#12" -- the resident and the decision that began this journey.
    static func journeyName(_ r: Resident) -> String { "\(r.id)#\(r.moves)" }
    func isTravelling(at now: Date) -> Bool { now < since }

    /// A recent sighting of its body on `floor` (a rebuild, not a return visit).
    func recentPose(on floor: Int, now: Date, within seconds: TimeInterval = 180) -> ResidentPose? {
        guard let p = shown, p.floor == floor, now.timeIntervalSince(p.at) < seconds, now >= p.at else { return nil }
        return p
    }
}

/// A floor's walkable plan, for a resident's offscreen life (see
/// MazeStore.floorPlan(for:)). World x = col * cellSize, z = row * cellSize.
struct FloorPlan {
    let floor: Int
    let cells: Set<GridCoordinate>
    /// Room-entrance doors (anchor -> wall): a resident opens these.
    let doors: [GridCoordinate: Direction]
    /// Bathroom doors (anchor -> wall): a resident never goes through these.
    let bathroomDoors: [GridCoordinate: Direction]
    /// The elevator's hallway cell (nil: no elevator on this floor's plan).
    let elevator: GridCoordinate?
    /// Cells with furniture standing in them (not a place to stop).
    let furnished: Set<GridCoordinate>
    let cellSize: Float
    /// Oct 18: window-room doors (anchor -> wall): doorways that close off an area, like the others.
    var windowDoors: [GridCoordinate: Direction] = [:]
    /// Oct 18 (open the building): what furniture stands in each furnished cell
    /// ("desk", "table", "aquarium"...) -- names an open-plan floor's places.
    var furnitureKinds: [GridCoordinate: String] = [:]

    /// The shortest walk (room doors are opened on the way; bathroom doors never crossed).
    func route(from a: GridCoordinate, to b: GridCoordinate) -> [GridCoordinate]? {
        CharacterLead.route(from: a, to: b, cells: cells, doors: bathroomDoors, canCross: { _ in false })
    }
}

// MARK: - Kinds and presentations

/// Everything a presentation is given when a floor is built.
struct FloorStage {
    let floor: Int
    weak var root: SCNNode?
    weak var camera: SCNNode?
    weak var controller: TapNavigationController?
    let context: CharacterLead.Context?
}

/// One species of resident.
protocol ResidentKind: AnyObject {
    var kind: String { get }
    var abilities: Set<ResidentAbility> { get }
    /// Its residents when the building has none of them yet.
    func newcomers(now: Date) -> [Resident]
    /// Residents saved by an older build in an older format (migration).
    func legacyResidents(in defaults: UserDefaults) -> [Resident]
    /// Old storage keys (cleared by Start Over).
    var legacyKeys: [String] { get }
    /// Offscreen life: work `r` forward to `now`. Pure -- no SceneKit.
    func advance(_ r: inout Resident, to now: Date, plans: (Int) -> FloorPlan?)
    /// Its presentation on a floor just built (nil: none there).
    func present(_ id: String, on stage: FloorStage) -> ResidentPresentation?
    /// Oct 18 (inter-floor test): a duty that outranks its room round right
    /// now, in a few words for the panel (nil: none).
    func priorityNote(_ r: Resident, now: Date) -> String?
}

extension ResidentKind {
    func legacyResidents(in defaults: UserDefaults) -> [Resident] { [] }
    var legacyKeys: [String] { [] }
    func priorityNote(_ r: Resident, now: Date) -> String? { nil }
}

/// A resident acted out on the player's floor.
protocol ResidentPresentation: AnyObject {
    var residentID: String { get }
    /// Its body (or a door cycle) is acting the record out: BuildingLife leaves it alone.
    var holdsResident: Bool { get }
    /// It has a body in the scene.
    var isRendered: Bool { get }
    /// It is guiding the player (the informant role).
    var isGuiding: Bool { get }
    /// The building's 1 Hz tick (a presentation may keep finer timing of its own).
    func tick(now: Date)
    /// The floor is going: write the body's state back, then remove it.
    func teardown()
    /// The player was just accepted into this floor's elevator. True: it's coming along.
    func playerBoarding() -> Bool
    /// The doors of the cab the player arrived in are opening.
    func arrivalDoorsOpening()
    /// What its body is doing right now, in a few words (diagnostics).
    var debugState: String { get }
    /// Oct 18: where its body is right now (world x, z), if it has one in the scene.
    var bodyPosition: SIMD2<Float>? { get }
    /// Oct 18: while a mission has it (guiding the player): what, and to where.
    var missionNote: String? { get }
    /// Oct 18 (phase 2): room / activity / attention, in words, while it has a body here.
    var activityNote: String? { get }
    /// Oct 18 (contacts): its body's node while it's in the scene (a portrait is drawn from it).
    var bodyNode: SCNNode? { get }
    /// Oct 22 (critter taps): every node a tap on it may land on -- its body, and
    /// its figure standing in the cab (a resident seen through the car's open
    /// doors). Default: its body.
    var tapTargets: [SCNNode] { get }
    /// Oct 19 (one car): its body walks into and out of the car itself (the car
    /// waits for it); false: the car moves it out of sight.
    var actsElevator: Bool { get }
    /// Oct 19 (one car): four times a second -- the car may have moved or its doors changed.
    func carChanged(now: Date)
    /// Oct 20 (follow a critter): the player just chose to follow it -- a little
    /// come-hither of its own, once, and on with whatever it was doing.
    func acknowledgeFollower(player: SIMD2<Float>?)
    /// Oct 20 (tasks): lead the player to `place` -- a real journey there (its own
    /// walk, the car between floors). True: on its way. False: it can't now.
    func guide(to place: ResidentPlace, why: String) -> Bool
    /// Oct 20 (tasks): it can lead the player somewhere (a roaming body; not the butterfly).
    var canGuide: Bool { get }
    /// Oct 20 (tasks): its guiding is over. `resumeRoaming`: cut short -- back to
    /// its own life now (a fresh decision), if it's free to make one here.
    func releaseGuide(resumeRoaming: Bool)
    /// Oct 23 (FOLLOW ME): it can walk after the player (a roaming body).
    var canFollowPlayer: Bool { get }
    /// Oct 23 (FOLLOW ME): start (true) or stop walking after the player. True: done.
    func setFollowingPlayer(_ on: Bool) -> Bool
    /// Oct 23 (menu pause): held still while its menu is open (true: held), and
    /// let go again (false) -- carrying on with what it was doing.
    func setHeld(_ on: Bool) -> Bool
    /// Oct 23 (menu pause): held still now.
    var isHeld: Bool { get }
}

extension ResidentPresentation {
    var debugState: String { "" }
    var bodyPosition: SIMD2<Float>? { nil }
    var missionNote: String? { nil }
    var activityNote: String? { nil }
    var bodyNode: SCNNode? { nil }
    var tapTargets: [SCNNode] { bodyNode.map { [$0] } ?? [] }
    var actsElevator: Bool { false }
    func carChanged(now: Date) {}
    func acknowledgeFollower(player: SIMD2<Float>?) {}
    func guide(to place: ResidentPlace, why: String) -> Bool { false }
    var canGuide: Bool { false }
    func releaseGuide(resumeRoaming: Bool) {}
    var canFollowPlayer: Bool { false }
    func setFollowingPlayer(_ on: Bool) -> Bool { false }
    func setHeld(_ on: Bool) -> Bool { false }
    var isHeld: Bool { false }
}

// MARK: - The residents' console

/// Oct 18 (diagnostics): one line per state change, e.g.
///   [Life] +812.4s chair.1 F4 elevator.delayed reason=playerNearDoors(3.1m)
/// Filter Xcode's console with "[Life]" (everything), "chair.1" (one
/// resident), "[Life][WARN" / "[Life][STALL]" (problems only). "+812.4s" is
/// the time since launch -- the same clock as the flight recorder's lines.
/// Detailed tracing (waypoints, body travels) only with the launch argument
/// -HallwaysLifeTrace YES. Everything also goes to the flight recorder
/// (diag "life.<event>"), console or not.
enum LifeLog {
    nonisolated static var tracing: Bool { UserDefaults.standard.bool(forKey: "HallwaysLifeTrace") }

    static func event(_ id: String, _ name: String, floor: Int? = nil, _ fields: KeyValuePairs<String, Any?> = [:]) {
        emit("[Life]", id, name, floor, fields)
    }
    /// Detail (only with -HallwaysLifeTrace YES).
    static func trace(_ id: String, _ name: String, floor: Int? = nil, _ fields: KeyValuePairs<String, Any?> = [:]) {
        guard tracing else { return }
        emit("[Life][trace]", id, name, floor, fields)
    }
    /// Something isn't as it should be (always shown).
    static func warn(_ id: String, _ name: String, floor: Int? = nil, _ fields: KeyValuePairs<String, Any?> = [:]) {
        emit("[Life][WARN]", id, name, floor, fields)
    }
    /// Oct 19 (population debugging): one resident's whole story, filter "[Pop]" --
    /// created, arrival scheduled/held, lobby entry, body attached, the car's slot
    /// (pickup and destination), doors open/closed, boarding, stepping out; and
    /// "[Pop][WARN]" for anything that breaks the chain (a car stopping on the
    /// player's floor with nobody there to use it, a request given up). Events
    /// only -- never per frame. TEMPORARY: remove once lobby arrivals are confirmed.
    static func pop(_ id: String, _ name: String, floor: Int? = nil, _ fields: KeyValuePairs<String, Any?> = [:]) {
        emit("[Pop]", id, name, floor, fields)
    }
    static func popWarn(_ id: String, _ name: String, floor: Int? = nil, _ fields: KeyValuePairs<String, Any?> = [:]) {
        emit("[Pop][WARN]", id, name, floor, fields)
    }
    /// A clock time for the [Pop] lines ("+812.4s" since launch, as the line prefix uses).
    static func at(_ d: Date, now: Date) -> String {
        if d.timeIntervalSince(now) > 86_400 * 365 { return "not yet scheduled" }
        let up = ProcessInfo.processInfo.systemUptime - DiagnosticRecorder.shared.startUptime + d.timeIntervalSince(now)
        return String(format: "+%.1fs (in %.0fs)", up, d.timeIntervalSince(now))
    }

    /// A body told to move that isn't moving (always shown).
    static func stall(_ id: String, _ name: String, floor: Int? = nil, _ fields: KeyValuePairs<String, Any?> = [:]) {
        emit("[Life][STALL]", id, name, floor, fields)
    }

    static func cell(_ c: GridCoordinate?) -> String { c.map { "\($0.row),\($0.col)" } ?? "-" }
    static func point(_ p: SIMD2<Float>?) -> String { p.map { String(format: "(%.2f,%.2f)", $0.x, $0.y) } ?? "-" }
    static func seconds(_ t: TimeInterval) -> String { String(format: "%.0fs", t) }

    private static func emit(_ tag: String, _ id: String, _ name: String, _ floor: Int?, _ fields: KeyValuePairs<String, Any?>) {
        var detail = ""
        for (k, v) in fields { detail += " \(k)=" + (v.map { value(of: $0) } ?? "nil") }
        diag("life.\(name)", ["id": id, "floor": floor, "tag": tag, "detail": detail])
        #if DEBUG
        let elapsed = ProcessInfo.processInfo.systemUptime - DiagnosticRecorder.shared.startUptime
        print("\(tag) " + String(format: "+%.1fs", elapsed) + " \(id)" + (floor.map { " F\($0)" } ?? "") + " \(name)" + detail)
        #endif
    }

    private static func value(of v: Any) -> String {
        switch v {
        case let f as Float: return String(format: "%.2f", f)
        case let d as Double: return String(format: "%.1f", d)
        case let c as GridCoordinate: return "\(c.row),\(c.col)"
        case let p as SIMD2<Float>: return point(p)
        default:
            let s = "\(v)"
            return s.contains(" ") ? "\"" + s + "\"" : s
        }
    }
}

// MARK: - The owner of the records

final class BuildingLife {
    nonisolated static let storageKey = "building.residents.v1"

    /// Oct 18: DEBUG-only accelerated resident testing -- launch argument
    /// -HallwaysLifeFast YES. Kinds that support it use faster pacing (the
    /// chair: RoamingChairKind.fastStyle); the clock is the same real clock.
    /// Always off in a Release build.
    static var fastMode: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "HallwaysLifeFast")
        #else
        return false
        #endif
    }

    static let shared = BuildingLife(defaults: .standard, persists: shouldPersist(underTests: ResumeState.runningUnderTests, test: testMode),
                                     kinds: [ButterflyKind(), RoamingChairKind()] + ResidentRoster.kinds
                                         + HallwaysianCast.kinds      // (Oct 18: the building's other residents; Oct 19: the six Hallwaysians)
                                         + CastResidents.kinds        // (Oct 21: the meeting's cast -- the Mailbox first; ResidentCast.swift)
                                         + StationedResidents.kinds,  // (Oct 21: Juanita and Tinky, at their posts)
                                     car: BuildingElevator.shared)

    /// Oct 18 (inter-floor test): the real records are written only in normal
    /// play -- never under unit tests, never in EITHER test mode.
    static func shouldPersist(underTests: Bool, test: LifeTestMode?) -> Bool {
        !underTests && test == nil
    }

    /// Oct 18: the test mode this run is in, if any (DEBUG only):
    ///   -HallwaysLifeTest N          one floor (the regression test)
    ///   -HallwaysLifeTestFloors 4,5  between floors, by the elevator
    /// Both given: the inter-floor test wins (said at launch). Never under unit tests.
    static var testMode: LifeTestMode? { launchTestMode }
    private static let launchTestMode: LifeTestMode? = {
        #if DEBUG
        // (The scheme's Test action shares the Run arguments: unit tests never run in a test mode.)
        if ResumeState.runningUnderTests { return nil }
        return LifeTestMode.parse(arguments: ProcessInfo.processInfo.arguments,
                                  singleDefault: UserDefaults.standard.integer(forKey: "HallwaysLifeTest"),
                                  floorsDefault: UserDefaults.standard.string(forKey: LifeTestMode.floorsKey))
        #else
        return nil
        #endif
    }()

    /// Oct 18: DEBUG-only CONTROLLED TEST -- launch argument -HallwaysLifeTest N
    /// (a floor). Every resident lives on floor N only: placed near the player
    /// when that floor is first built this run, rooms of that floor only, no
    /// floor changes, lingering 3-8 s. NOTHING IS SAVED in this mode: the real
    /// records on disk are read but never written, so leaving test mode (a run
    /// without the argument) carries on exactly where real life left off.
    /// (Oct 18: the ONE-floor test only -- nil in the inter-floor test, whose
    /// residents do change floors. Every one-floor rule keys off this.)
    static var testFloor: Int? { testMode.flatMap { $0.interFloor ? nil : $0.floors.first } }

    /// Oct 18: said once at launch (HallwaysApp.init) -- the launch arguments
    /// as the app actually received them, and what Building Life made of them.
    static func reportLaunch() {
        let ours = ProcessInfo.processInfo.arguments.dropFirst().filter { $0.hasPrefix("-Hallways") || Int($0) != nil || $0 == "YES" || $0 == "NO" }
        LifeLog.event("building", "launch", ["arguments": ours.joined(separator: " "), "testFloor": testFloor,
                                            "testMode": testMode?.title, "fastMode": fastMode, "panel": LifePanel.enabled])
    }
    /// The floor the player is on (the last one built).
    var currentFloor: Int?
    /// Residents already placed near the player for this run's test.
    var testPlaced = false

    /// A kind's pacing as it applies now: normal, fast (-HallwaysLifeFast), or
    /// the controlled test (-HallwaysLifeTest N). Same code, only these numbers.
    static func pacing(normal: RoamStyle, fast: RoamStyle) -> RoamStyle {
        if let m = testMode { return m.pacing(fast) }
        return fastMode ? fast : normal
    }

    let defaults: UserDefaults
    let persists: Bool
    private var kinds: [String: ResidentKind] = [:]
    private var kindOrder: [String] = []
    private var order: [String] = []
    private var residents: [String: Resident] = [:]
    private var loaded = false
    private var timer: Timer?
    private var lastStatus = Date.distantPast
    private var lastHeld = Set<String>()
    /// Start Over in progress: teardowns don't write back.
    private var resetting = false

    /// Any floor's plan (set by the scene builder; nil until then).
    var plans: (Int) -> FloorPlan? = { _ in nil }
    /// Oct 18 (diagnostics): the player's ground position on the floor being shown.
    var playerPosition: () -> SIMD2<Float>? = { nil }
    /// The presentations on the player's floor (FloorPresenter's).
    var presentations: [ResidentPresentation] = []

    /// Oct 19 (one car): THE elevator (BuildingElevator.shared for the building;
    /// a test's own for a test's own building).
    let car: BuildingElevator

    init(defaults: UserDefaults, persists: Bool, kinds: [ResidentKind], car: BuildingElevator? = nil) {
        self.defaults = defaults
        self.persists = persists
        self.car = car ?? BuildingElevator()
        for k in kinds {
            self.kinds[k.kind] = k
            kindOrder.append(k.kind)
        }
    }

    // MARK: Records

    var residentIDs: [String] { loadIfNeeded(); return order }

    func resident(_ id: String) -> Resident? { loadIfNeeded(); return residents[id] }

    func kind(of id: String) -> ResidentKind? { resident(id).flatMap { kinds[$0.kind] } }

    /// A presentation's (or a kind's) new version of a record.
    func store(_ r: Resident) {
        guard !resetting else { return }
        loadIfNeeded()
        if residents[r.id] == nil { order.append(r.id) }
        residents[r.id] = r
        save()
    }

    /// Oct 23 (ten-floor experiment, ActiveBuilding): nobody is left on, or on the
    /// way to or from, a floor out of use. Such a resident is set down at its
    /// stand-in floor's elevator landing (as a newcomer arrives there) and goes on
    /// from there -- same resident, same everything else. The car: if anything of it
    /// (where it is, where it's going, a call, a rider) is on a floor out of use, it
    /// starts afresh in the lobby, and anyone mid-ride is set down on their own
    /// floor's landing the same way. Nothing at all when every floor is in use.
    private func settleIntoFloorsInUse(now: Date) {
        var carStartsOver = false
        if let s = car.state {
            var floors = [s.floor] + [s.target].compactMap { $0 }
            for c in s.calls { floors.append(c.floor); if let d = c.destination { floors.append(d) } }
            for r in s.riders { if let d = r.destination { floors.append(d) } }
            if floors.contains(where: { !ActiveBuilding.isActive($0) }) {
                car.reset()
                car.placeIfNeeded(at: ResidentPolicy.lobbyFloor, now: now)
                carStartsOver = true
            }
        }
        var moved: [String] = []
        for id in order {
            guard var r = residents[id] else { continue }
            let outOfUse = !ActiveBuilding.isActive(r.floor) || (r.leg.map { !ActiveBuilding.isActive($0.from.floor) } ?? false)
            let midRide = carStartsOver && (r.leg?.changesFloor ?? false)
            guard outOfUse || midRide else { continue }
            let was = r.floor
            r.floor = ActiveBuilding.standIn(for: r.floor)
            r.cell = nil                                                   // (shown at the landing, then off to a room)
            r.leg = nil
            r.since = now
            r.dwell = 0
            r.room = nil
            r.roomName = nil
            r.shown = nil
            r.why = outOfUse ? "F\(was) is out of use for now (the building is floors 1-\(ActiveBuilding.topFloor) for now): on F\(r.floor) instead"
                             : "the car started afresh: set down on F\(r.floor)"
            residents[id] = r
            moved.append("\(id) F\(was)->F\(r.floor)")
        }
        guard carStartsOver || !moved.isEmpty else { return }
        save()
        saveCar()
        diag("residents.floorsInUse", ["topFloor": ActiveBuilding.topFloor, "carStartedOver": carStartsOver,
                                       "moved": moved.joined(separator: ", ")])
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        var list: [Resident] = []
        var source = "new"
        if persists, let data = defaults.data(forKey: Self.storageKey) {
            if let saved = try? JSONDecoder().decode([Resident].self, from: data) {
                list = saved
                source = "saved"
            } else {
                diag("residents.unreadable", ["bytes": data.count])
            }
        } else if persists {
            for name in kindOrder {
                let old = kinds[name]?.legacyResidents(in: defaults) ?? []
                if !old.isEmpty { source = "migrated" }
                list += old
            }
        }
        // Oct 19 (Stage A): residents retired from the cast for good. Their saved
        // records go now -- before the elevator ever books them a slot -- and the
        // save below writes the list without them.
        let retired = list.filter { ResidentRoster.retiredIDs.contains($0.id) }.map(\.id)
        if !retired.isEmpty {
            list.removeAll { ResidentRoster.retiredIDs.contains($0.id) }
            diag("residents.retired.purged", ["ids": retired.joined(separator: ","), "kept": list.count])
        }
        // Oct 19 (later): the six Hallwaysians' front-door arrival, given once more
        // to a save the first build had already scattered them in.
        let rearrived = HallwaysianCast.rearriveIfNeeded(&list, defaults: defaults, persists: persists, now: BuildingClock.now())
        if !rearrived.isEmpty {
            diag("residents.hallwaysians.rearrival", ["ids": rearrived.joined(separator: ","), "note": "in at the front door shortly"])
        }
        let now = BuildingClock.now()
        var newcomerIDs = Set<String>()
        for name in kindOrder {
            for n in kinds[name]?.newcomers(now: now) ?? [] where !list.contains(where: { $0.id == n.id }) {
                list.append(n)
                newcomerIDs.insert(n.id)
            }
        }
        // Oct 19 (one car): an older save's elevator trips (booked times) become
        // trips on the real car -- see migrateLegacyLegs.
        let carriedOver = Self.migrateLegacyLegs(&list, now: now)
        residents = [:]
        order = []
        for r in list where residents[r.id] == nil {
            residents[r.id] = r
            order.append(r.id)
        }
        diag("residents.loaded", ["source": source, "count": order.count, "ids": order.joined(separator: ",")])
        // The car: as saved -- or, never saved, placed once: where a migrated rider's
        // old ride had got to, else in the lobby. Never moved after that except by running.
        if !(persists && car.load(from: defaults)) {
            car.placeIfNeeded(at: carriedOver.first?.reached ?? ResidentPolicy.lobbyFloor, now: now)
            LifeLog.event("building", "elevator.placed", ["floor": car.state?.floor, "why": carriedOver.isEmpty ? "a building with no car yet: the lobby"
                                                          : "an older save mid-ride: where that ride had got to"])
        } else {
            LifeLog.event("building", "elevator.loaded", ["floor": car.state?.floor, "state": car.position(now: now)?.state,
                                                          "riders": car.state?.riders.map { $0.who }.joined(separator: ","),
                                                          "calls": car.state?.calls.map { "\($0.who)@F\($0.floor)" }.joined(separator: ",")])
        }
        saveCar()
        settleIntoFloorsInUse(now: now)                                    // Oct 23 (ten-floor experiment: ActiveBuilding)
        if let m = Self.testMode {
            LifeLog.event("building", "testMode.on", ["mode": m.title, "note": m.note])
        }
        // (said every launch, on or off: launch arguments only reach a run started from Xcode)
        if Self.fastMode {
            LifeLog.event("building", "fastMode.on", ["note": "-HallwaysLifeFast: accelerated resident pacing (DEBUG only)"])
        } else {
            LifeLog.event("building", "fastMode.off", ["note": "normal pacing (add -HallwaysLifeFast YES in the scheme, run from Xcode)"])
        }
        for id in order {
            guard let r = residents[id] else { continue }
            let how = newcomerIDs.contains(id) ? "created" : (source == "migrated" ? "migrated" : "loaded")
            LifeLog.pop(id, "resident.\(how)", floor: r.floor,
                        ["kind": r.kind, "cell": LifeLog.cell(r.cell), "arrival": r.cell == nil ? LifeLog.at(r.since, now: now) : "already in",
                         "buildingOpen": ResidentPolicy.buildingOpen])
            LifeLog.event(id, "resident.\(how)", floor: r.floor,
                          ["kind": r.kind, "cell": LifeLog.cell(r.cell), "arrivesIn": r.awaitsCar ? "after the car" : LifeLog.seconds(max(0, r.since.timeIntervalSince(now))),
                           "nextDecisionIn": r.awaitsCar ? "after the car" : LifeLog.seconds(r.nextDecision.timeIntervalSince(now)), "byElevator": r.leg?.changesFloor ?? false])
        }
        save()
    }

    private func save() {
        guard persists, !resetting else { return }
        let list = order.compactMap { residents[$0] }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.storageKey) }
    }

    // MARK: The tick

    /// Begin (idempotent): records loaded, the 1 Hz tick running -- in the
    /// run loop's common modes, so it keeps going while the player scrolls
    /// the editor.
    func start() {
        loadIfNeeded()
        guard timer == nil else { return }
        if self === BuildingLife.shared { HallwaysianMusic.prepareAll() }   // Oct 22 (musical building): in the background, once
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                if let self { self.tick() } else { t.invalidate() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Oct 19 (one car): the car, four times a second -- its doors and runs on
        // time (the residents' own lives keep the 1 Hz tick).
        let e = Timer(timeInterval: 0.25, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                if let self { self.elevatorStep(now: BuildingClock.now()) } else { t.invalidate() }
            }
        }
        RunLoop.main.add(e, forMode: .common)
        elevatorTimer = e
        tick()
    }
    private var elevatorTimer: Timer?

    /// Back in the app: everyone caught up at once (timers don't run in the background).
    func appBecameActive() {
        guard timer != nil else { return }
        diag("residents.catchUp", [:])
        tick()
    }

    /// Leaving the app: the records are already saved on every change; once more for certain.
    func appResigned() { save(); saveCar() }

    func tick() {
        // Oct 21 (TEST ONLY, -HallwaysPerfPauseLife YES): the residents' lives stand
        // still for this launch (records unchanged, so nothing is saved wrongly).
        if PerfSwitches.pauseLife, self === BuildingLife.shared { return }
        let perf = PerfMonitor.begin("life.tick"); defer { PerfMonitor.end(perf) }   // Oct 21: measurement only (PerfMonitor)
        loadIfNeeded()
        let now = BuildingClock.now()
        let held = Set(presentations.filter { $0.holdsResident }.map { $0.residentID })
        if held != lastHeld {
            for id in held.subtracting(lastHeld) { LifeLog.trace(id, "record.heldByBody") }
            for id in lastHeld.subtracting(held) { LifeLog.trace(id, "record.releasedByBody") }
            lastHeld = held
        }
        var changed = false
        for id in order {
            guard !held.contains(id), var r = residents[id], let kind = kinds[r.kind] else { continue }
            let before = (r.floor, r.cell, r.since, r.dwell, r.moves)
            let hadLeg = r.leg != nil
            kind.advance(&r, to: now, plans: plans)
            if (r.floor, r.cell, r.since, r.dwell, r.moves) != before {
                residents[id] = r
                changed = true
                let decisions = r.moves - before.4
                if decisions > 0 {
                    logDecision(r, now: now, offscreen: true, decisions: decisions)
                } else {
                    LifeLog.event(id, "record.updated", floor: r.floor, ["cell": LifeLog.cell(r.cell), "offscreen": true])
                }
            } else if hadLeg, r.leg == nil {
                residents[id] = r
                changed = true
                LifeLog.event(id, "arrived", floor: r.floor, ["cell": LifeLog.cell(r.cell), "offscreen": true,
                                                              "stays": LifeLog.seconds(r.dwell - now.timeIntervalSince(r.since))])
            }
        }
        // Oct 19 (one car): every trip between floors is in the car's hands (a call, a rider).
        if liftSync(now: now, held: held) { changed = true }
        if changed { save() }
        for p in presentations { p.tick(now: now) }
        elevatorStep(now: now)
        ContactsStore.shared.check(player: playerPosition())          // Oct 18 (contacts): met anyone?
        if self === BuildingLife.shared { ResidentMusicConductor.shared.tick(life: self) }   // Oct 22 (musical building)
        if self === BuildingLife.shared { StickyProbe.tick(sceneRoot: CharacterRegistry.sceneRoot) }   // Oct 22 (evening): measurement only
        if LifePanel.enabled { LifePanel.update(panelLines(now: now)) }
        // (Oct 19: the hall's floor indicator and the ELEVATOR panel follow the car -- elevatorStep.)
        if now.timeIntervalSince(lastStatus) >= 30 {
            lastStatus = now
            logStatus(now: now)
        }
    }

    // MARK: The car (Oct 19: ONE car, request-driven -- ElevatorScheduler.swift)
    //
    // A resident going to another floor: walks to the doors (`toDoors`), calls
    // the car there and waits as long as it takes (`waiting`), gets in when its
    // doors are open (`riding`), gets out when they open on its floor (`out`) and
    // walks on to its place. On the player's floor its body does each of those
    // itself (RoamPresentation); everywhere else the car moves it at once with
    // its doors open. Its record says which -- never a booked time.

    func saveCar() {
        guard persists, !resetting else { return }
        car.save(to: defaults)
    }

    /// Who has a body on the player's floor that walks in and out of the car itself.
    var actingIDs: Set<String> {
        Set(presentations.filter { $0.actsElevator }.map { $0.residentID })
    }

    /// Its body has reached the doors (the player's floor): it waits there for the car.
    func callCar(_ id: String, now: Date) {
        loadIfNeeded()
        guard var r = residents[id], var leg = r.leg, leg.changesFloor, leg.from.floor != r.floor else { return }
        if leg.lift != .waiting {
            leg.lift = .waiting
            r.leg = leg
            residents[id] = r
            save()
        }
        // (once: a call the car missed stands, and it comes back for it after a pause)
        guard car.rider(id) == nil, car.callOf(id) == nil else { return }
        car.call(id, at: leg.from.floor, to: r.floor, now: now)
        saveCar()
        LifeLog.pop(id, "car.called", floor: leg.from.floor, ["journey": Resident.journeyName(r), "for": "F\(r.floor)",
                                                             "car": car.position(now: now)?.state])
    }

    /// Its body walked into the car (doors open). `force`: a scripted character's
    /// door cycle, told after its doors shut. True: aboard.
    @discardableResult
    func boarded(_ id: String, now: Date, force: Bool = false) -> Bool {
        loadIfNeeded()
        guard let r = residents[id], let leg = r.leg, leg.changesFloor, leg.from.floor != r.floor else {
            LifeLog.popWarn(id, "boarding.invalid", ["why": "no trip between floors in its record"])
            return false
        }
        if leg.lift == .riding || leg.lift == .out {
            LifeLog.popWarn(id, "boarding.duplicate", floor: leg.from.floor, ["journey": Resident.journeyName(r), "action": "ignored"])
            return false
        }
        if car.rider(id) == nil {
            guard car.board(id, destination: r.floor, now: now, force: force, at: leg.from.floor) else {
                LifeLog.popWarn(id, "boarding.refused", floor: leg.from.floor, ["why": "the car isn't here with its doors open",
                                                                                 "car": car.position(now: now)?.state])
                return false
            }
        }
        recordBoarding(id, at: now, seen: true)
        saveCar()
        return true
    }

    /// Its body stepped out of the car on its floor: on its way to its place from now.
    func alighted(_ id: String, now: Date) {
        loadIfNeeded()
        car.alight(id, now: now)
        recordAlighting(id, at: now, seen: true)
        saveCar()
    }

    private func recordBoarding(_ id: String, at t: Date, seen: Bool) {
        guard var r = residents[id], var leg = r.leg, leg.changesFloor, leg.lift != .riding, leg.lift != .out else { return }
        leg.lift = .riding
        leg.boardedAt = t
        r.leg = leg
        r.since = .distantFuture                                     // (there when the car has brought it)
        r.shown = nil
        residents[id] = r
        save()
        LifeLog.pop(id, "boarding.completed", floor: leg.from.floor,
                    ["journey": Resident.journeyName(r), "seen": seen, "to": "F\(r.floor)"])
    }

    private func recordAlighting(_ id: String, at t: Date, seen: Bool) {
        guard var r = residents[id], var leg = r.leg, leg.changesFloor, leg.lift != .out else { return }
        leg.lift = .out
        leg.alightAt = t
        if leg.boardedAt == nil { leg.boardedAt = t }
        r.leg = leg
        r.since = t.addingTimeInterval(leg.outWalk ?? walkFromDoors(r))
        r.shown = nil
        residents[id] = r
        save()
        LifeLog.pop(id, "stepped.out", floor: r.floor, ["journey": Resident.journeyName(r), "seen": seen,
                                                      "to": "\(r.roomName ?? "?") \(LifeLog.cell(r.cell))"])
    }

    /// From the doors to its place (an older trip without a walk on record).
    private func walkFromDoors(_ r: Resident) -> Double {
        guard let plan = plans(r.floor), let e = plan.elevator, let cell = r.cell,
              let route = plan.route(from: e, to: cell) else { return 6 }
        return Double(Float(max(0, route.count - 1)) * plan.cellSize / 1.1) + 2
    }

    /// What the car did, into the records (everything it did out of sight).
    func apply(_ happened: [BuildingElevator.Happening], now: Date) {
        for h in happened {
            switch h.event {
            case .boarded(let id, let floor, _):
                recordBoarding(id, at: h.at, seen: false)
                LifeLog.event(id, "elevator.boarded", floor: floor, ["offscreen": true])
            case .alighted(let id, let floor):
                recordAlighting(id, at: h.at, seen: false)
                LifeLog.event(id, "elevator.alighted", floor: floor, ["offscreen": true])
            case .departed(let from, let to):
                LifeLog.event("elevator", "car.departed", floor: from, ["to": "F\(to)", "riders": car.state?.riders.map { $0.who }.joined(separator: ",")])
            case .arrived(let f):
                LifeLog.event("elevator", "car.arrived", floor: f, [:])
            case .doorsOpening(let f):
                LifeLog.trace("elevator", "doors.opening", floor: f)
            case .doorsOpen(let f):
                LifeLog.event("elevator", "doors.open", floor: f, ["owner": car.state?.owner.rawValue])
            case .doorsClosing(let f):
                LifeLog.trace("elevator", "doors.closing", floor: f)
            case .doorsClosed(let f):
                LifeLog.event("elevator", "doors.closed", floor: f, ["owner": car.state?.owner.rawValue])
            case .callEnded(let who, let f):
                LifeLog.event(who, "elevator.callEnded", floor: f, [:])
            }
        }
    }

    /// Four times a second (and on every tick): the player's doors and rides told
    /// to the car, the car worked forward, what it did written into the records,
    /// the player's floor shown it (doors, call, signs), the bodies told.
    func elevatorStep(now: Date) {
        let perf = PerfMonitor.begin("life.elevatorStep"); defer { PerfMonitor.end(perf) }   // Oct 21: measurement only (PerfMonitor)
        loadIfNeeded()
        guard car.state != nil else { return }
        let before = car.state
        let isBuilding = self === BuildingLife.shared
        // (bodies act on the player's floor only: everywhere else the car moves everyone at once)
        if isBuilding { apply(ElevatorBoard.syncPlayer(car: car, now: now, acting: actingIDs, actingFloor: currentFloor), now: now) }
        let happened = car.advance(to: now, acting: actingIDs, actingFloor: currentFloor)
        apply(happened, now: now)
        if isBuilding { ElevatorBoard.present(life: self, now: now) }
        for p in presentations { p.carChanged(now: now) }
        if !car.sameIgnoringClock(before) { saveCar() }
    }

    /// Every trip between floors is in the car's hands -- a call where it's
    /// waiting, a rider while it rides -- and nothing else is. (After a relaunch or
    /// an older save this puts back what the records say; normally nothing to do.)
    /// True if a record changed.
    @discardableResult
    func liftSync(now: Date, held: Set<String> = []) -> Bool {
        loadIfNeeded()
        guard car.state != nil else { return false }
        var changed = false
        var travellers = Set<String>()
        for id in order {
            guard var r = residents[id], var leg = r.leg, leg.changesFloor, leg.from.floor != r.floor else { continue }
            travellers.insert(id)
            switch leg.lift ?? .toDoors {
            case .toDoors:
                // Out of sight, at the doors by now: it calls the car. (A body here calls when it gets there.)
                guard !held.contains(id), now >= (leg.boardAt ?? now) else { break }
                leg.lift = .waiting
                r.leg = leg
                residents[id] = r
                changed = true
                car.call(id, at: leg.from.floor, to: r.floor, now: now)
                LifeLog.pop(id, "car.called", floor: leg.from.floor, ["journey": Resident.journeyName(r), "for": "F\(r.floor)",
                                                                     "seen": false, "car": car.position(now: now)?.state])
            case .waiting:
                if car.callOf(id) == nil, car.rider(id) == nil, !held.contains(id) {
                    car.call(id, at: leg.from.floor, to: r.floor, now: now)
                    LifeLog.pop(id, "car.callRestored", floor: leg.from.floor, ["journey": Resident.journeyName(r)])
                }
            case .riding:
                if car.rider(id) == nil {
                    car.restoreRider(id, destination: r.floor, now: now)
                    LifeLog.pop(id, "car.riderRestored", floor: r.floor, ["journey": Resident.journeyName(r),
                                                                         "car": car.position(now: now)?.state])
                }
            case .out:
                if car.rider(id) != nil { car.alight(id, now: now) }
                if car.callOf(id) != nil { car.cancelCall(id) }
            }
        }
        // Calls and riders no record stands behind (a plan changed): gone.
        for c in car.state?.calls ?? [] where !BuildingElevator.isOneShot(c.who) && !travellers.contains(c.who) {
            car.cancelCall(c.who)
            LifeLog.pop(c.who, "car.callCancelled", floor: c.floor, ["why": residents[c.who] == nil ? "no such resident" : "its trip changed"])
        }
        for rider in car.state?.riders ?? [] where rider.who != "player" && !travellers.contains(rider.who) {
            car.alight(rider.who, now: now)
            LifeLog.popWarn(rider.who, "car.riderDropped", ["why": "its record isn't riding"])
        }
        return changed
    }

    /// Oct 19 (one car): an older save's trips (booked boarding and stepping-out
    /// times) become trips on the real car, by where they were at `now`:
    ///   not yet at the doors        walking to them (`toDoors`, the same time to get there)
    ///   boarded (or past boarding)  in the car, for its floor (`riding`)
    ///   stepped out                 walking on from the doors (`out`)
    /// (The old "in by the elevator" newcomer shape -- a leg on its own floor --
    /// becomes a plain walk from the doors.) Returns the riders, with the floor
    /// their old ride had reached, so a car that was never saved can be placed
    /// where they are.
    @discardableResult
    static func migrateLegacyLegs(_ list: inout [Resident], now: Date) -> [(id: String, reached: Int)] {
        var riders: [(id: String, reached: Int)] = []
        for i in list.indices {
            guard var leg = list[i].leg, leg.lift == nil, let oldAlight = leg.alightAt else { continue }
            var r = list[i]
            if leg.from.floor == r.floor {
                leg.alightAt = nil
                leg.boardAt = nil
                r.leg = leg
                list[i] = r
                continue
            }
            let walk = max(0, r.since.timeIntervalSince(oldAlight))
            if now >= oldAlight {
                leg.lift = .out
                leg.boardedAt = leg.boardedAt ?? leg.boardAt
            } else if leg.boardedAt != nil || now >= (leg.boardAt ?? now) {
                let board = leg.boardedAt ?? leg.boardAt ?? now
                leg.lift = .riding
                leg.boardedAt = board
                leg.alightAt = nil
                leg.outWalk = walk
                r.since = .distantFuture
                let ride = ElevatorBoard.Ride(id: r.id, from: leg.from.floor, to: r.floor, boardAt: board, alightAt: oldAlight)
                riders.append((r.id, ride.floorReached(at: now)))
            } else {
                leg.lift = .toDoors
                leg.alightAt = nil
                leg.outWalk = walk
                r.since = .distantFuture
            }
            r.leg = leg
            list[i] = r
            LifeLog.pop(r.id, "trip.migrated", floor: r.floor, ["stage": leg.lift?.rawValue, "from": "F\(leg.from.floor)"])
        }
        return riders
    }

    // MARK: Start Over

    func resetForNewPlayer() {
        resetting = true
        for p in presentations { p.teardown() }
        presentations = []
        residents = [:]
        order = []
        defaults.removeObject(forKey: Self.storageKey)
        BuildingElevator.clear(in: defaults)                          // (Oct 19: the car starts again with the building)
        car.reset()
        for name in kindOrder { for key in kinds[name]?.legacyKeys ?? [] { defaults.removeObject(forKey: key) } }
        resetting = false
        loaded = false
        diag("residents.reset", [:])
    }

    // MARK: Diagnostics

    struct Status {
        var id: String
        var kind: String
        var floor: Int
        var cell: GridCoordinate?
        /// "dwelling", "travelling" or "guiding".
        var activity: String
        /// While travelling: where to (floor and cell).
        var destination: String?
        /// The room it's in or going to (name), if any.
        var room: String?
        /// Seconds until its next decision (negative: overdue -- held by its body).
        var nextDecisionIn: Int
        var rendered: Bool
        /// Oct 22 (stability pass): in (or waiting for) the car -- nextDecisionIn is meaningless (0).
        var awaitsCar = false
        /// The next decision, in words for the logs.
        var nextText: String { awaitsCar ? "after the car" : "\(nextDecisionIn)s" }
        /// In plain words: where it is, what it's waiting for.
        var explanation: String = ""
        var line: String {
            let at = cell.map { "\($0.row),\($0.col)" } ?? "-"
            return "\(id) (\(kind)) floor \(floor) cell \(at) \(activity)" + (destination.map { " -> \($0)" } ?? "")
                + " next \(nextText)" + (rendered ? " rendered" : "")
        }
    }

    func status(now: Date) -> [Status] {
        residentIDs.compactMap { id in
            guard let r = residents[id] else { return nil }
            let p = presentations.first { $0.residentID == id }
            let travelling = r.isTravelling(at: now)
            // (Oct 18: lingering = staying in a room; waiting = anywhere else -- the elevator, a hallway)
            let activity = p?.isGuiding == true ? "guiding" : (travelling ? "travelling" : (r.room != nil ? "lingering" : "waiting"))
            let destination = travelling ? "floor \(r.floor) cell " + (r.cell.map { "\($0.row),\($0.col)" } ?? "-") : nil
            var s = Status(id: id, kind: r.kind, floor: r.floor, cell: r.cell, activity: activity, destination: destination,
                           nextDecisionIn: r.awaitsCar ? 0 : Int(r.nextDecision.timeIntervalSince(now).rounded()), rendered: p?.isRendered ?? false)
            s.awaitsCar = r.awaitsCar
            s.explanation = explain(r, presentation: p, now: now)
            s.room = r.roomName
            return s
        }
    }

    /// What it's up to, in words -- the record's view, plus its body's when it has one here.
    private func explain(_ r: Resident, presentation p: ResidentPresentation?, now: Date) -> String {
        var parts: [String] = []
        if let leg = r.leg, r.isTravelling(at: now) {
            if leg.changesFloor {
                // Oct 19 (one car): where its trip is, by the car -- never a booked time.
                switch leg.lift {
                case .toDoors?:
                    parts.append("walking to the elevator on F\(leg.from.floor) (there in \(LifeLog.seconds(max(0, (leg.boardAt ?? now).timeIntervalSince(now))))), for F\(r.floor)")
                case .waiting?:
                    parts.append("waiting at the elevator on F\(leg.from.floor) for F\(r.floor) (car: \(car.position(now: now)?.state ?? "?") at F\(car.position(now: now)?.floor ?? 0))")
                case .riding?:
                    parts.append("in the car F\(leg.from.floor)->F\(r.floor) (car at F\(car.position(now: now)?.floor ?? 0), \(car.position(now: now)?.state ?? "?"))")
                default:
                    parts.append("out of the elevator on F\(r.floor), walking to \(LifeLog.cell(r.cell)) (there in \(LifeLog.seconds(r.since.timeIntervalSince(now))))")
                }
            } else {
                parts.append("walking on F\(r.floor) to \(LifeLog.cell(r.cell)) (there in \(LifeLog.seconds(r.since.timeIntervalSince(now))))")
            }
        } else if r.cell == nil {
            parts.append("not placed yet (first decision in \(LifeLog.seconds(r.nextDecision.timeIntervalSince(now))))")
        } else {
            let left = r.nextDecision.timeIntervalSince(now)
            parts.append(left >= 0 ? "staying at F\(r.floor) \(LifeLog.cell(r.cell)) for \(LifeLog.seconds(left)) more"
                                   : "overdue to decide by \(LifeLog.seconds(-left))")
        }
        if let why = r.why { parts.append("why: \(why)") }
        if let p {
            let body = p.debugState
            parts.append(p.holdsResident ? "body here: \(body.isEmpty ? "acting it out" : body)" : (body.isEmpty ? "no body here" : body))
            if let at = p.bodyPosition {
                parts.append(Self.whereabouts(of: at, from: playerPosition()))
            }
        } else {
            parts.append("offscreen")
        }
        return parts.joined(separator: "; ")
    }

    /// "14 m north-east of you" (world z grows southward: rows).
    static func whereabouts(of at: SIMD2<Float>, from player: SIMD2<Float>?) -> String {
        guard let player else { return "rendered at \(LifeLog.point(at))" }
        let d = at - player
        let distance = simd_length(d)
        guard distance > 0.5 else { return "rendered right beside you" }
        var compass = ""
        if d.y < -distance * 0.38 { compass += "north" } else if d.y > distance * 0.38 { compass += "south" }
        if d.x > distance * 0.38 { compass += compass.isEmpty ? "east" : "-east" } else if d.x < -distance * 0.38 { compass += compass.isEmpty ? "west" : "-west" }
        return String(format: "rendered %.0f m %@ of you", distance, compass)
    }

    func logStatus(now: Date) {
        for s in status(now: now) {
            diag("resident.status", ["id": s.id, "kind": s.kind, "floor": s.floor,
                                     "cell": s.cell.map { "\($0.row),\($0.col)" }, "activity": s.activity,
                                     "destination": s.destination, "nextDecisionIn": s.awaitsCar ? "after the car" : "\(s.nextDecisionIn)", "rendered": s.rendered,
                                     "explanation": s.explanation])
            LifeLog.event(s.id, "status", floor: s.floor, ["activity": s.activity, "cell": LifeLog.cell(s.cell), "room": s.room,
                                                           "next": s.nextText, "rendered": s.rendered,
                                                           "what": s.explanation])
        }
    }

    /// The developer panel's lines: the heading, the player, then each resident --
    /// live, from the records and the bodies in the scene this second.
    /// Cells are written x (column), y (row).
    func panelLines(now: Date) -> [String] {
        func xy(_ c: GridCoordinate?) -> String { c.map { "x\($0.col) y\($0.row)" } ?? "x- y-" }
        var lines = [Self.testMode.map { "LIFE TEST: \($0.title)   (nothing saved)" } ?? (Self.fastMode ? "RESIDENTS (fast pacing)" : "RESIDENTS")]
        let cs = currentFloor.flatMap { plans($0)?.cellSize } ?? 3.52
        let player = playerPosition()
        let playerCell = player.map { GridCoordinate(row: Int(($0.y / cs).rounded()), col: Int(($0.x / cs).rounded())) }
        lines.append("PLAYER    F\(currentFloor.map(String.init) ?? "-")  \(xy(playerCell))")
        for s in status(now: now) {
            let p = presentations.first { $0.residentID == s.id }
            let name = s.id.split(separator: ".").first.map { String($0).uppercased() } ?? s.id
            var activity = s.activity
            if let note = p?.missionNote { activity = note }
            let dest = s.room.map { (s.activity == "travelling" ? "-> " : "in ") + $0 } ?? "-> (no room)"
            let body: String
            if let p, let at = p.bodyPosition {
                body = "BODY: rendered, " + Self.whereabouts(of: at, from: player).replacingOccurrences(of: "rendered ", with: "")
                    + " at \(xy(GridCoordinate(row: Int((at.y / cs).rounded()), col: Int((at.x / cs).rounded()))))"
            } else if let p {
                body = "BODY: not spawned" + (p.debugState.isEmpty ? "" : " (\(p.debugState))")
            } else {
                body = "BODY: not on this floor"
            }
            lines.append("\(name.padding(toLength: 9, withPad: " ", startingAt: 0)) F\(s.floor)  \(xy(s.cell))  \(dest)")
            lines.append("          \(activity) | next \(max(0, s.nextDecisionIn))s | \(body)")
            // Oct 18 (phase 2): what it's doing in the room, and what its eyes are on.
            if let note = p?.activityNote { lines.append("  \(name): \(note)") }
            // Oct 18 (inter-floor test): a mission that outranks its room round, said plainly.
            if let r = residents[s.id], let note = kinds[r.kind]?.priorityNote(r, now: now) {
                lines.append("          ! \(note)")
            }
        }
        // Oct 18 (resident audio): every critter sound heard lately -- who, which, how far, how loud.
        let heard = AudioWatch.summary()
        lines.append("SOUNDS F\(currentFloor.map(String.init) ?? "-") (only this floor's can be heard)" + (heard.isEmpty ? ": none in 8s" : ""))
        for h in heard.prefix(5) { lines.append("  " + h) }
        return lines
    }

    /// Oct 18 (controlled test): every resident placed near the player on the
    /// test floor -- separate open hallway cells 2-5 steps away, reachable from
    /// where the player stands -- deciding within a couple of seconds. Records
    /// in memory only (test mode saves nothing).
    func placeForTest(floor: Int, playerCell given: GridCoordinate, plan: FloorPlan) {
        guard !testPlaced else { return }
        testPlaced = true
        // (arriving by the elevator, the camera may still be in the cab: count from the landing)
        let playerCell = plan.cells.contains(given) ? given : (plan.elevator ?? given)
        let now = BuildingClock.now()
        let roomCells = plan.rooms.reduce(into: Set<GridCoordinate>()) { $0.formUnion($1.cells) }
        let near = plan.cells.subtracting(roomCells)
            .filter { $0 != plan.elevator && $0 != playerCell && !plan.furnished.contains($0) }
            .compactMap { c -> (GridCoordinate, Int)? in
                guard let route = plan.route(from: playerCell, to: c) else { return nil }
                return (c, route.count - 1)
            }
            .sorted { ($0.1, $0.0.row, $0.0.col) < ($1.1, $1.0.row, $1.0.col) }
        var taken: [GridCoordinate] = []
        for (i, id) in residentIDs.enumerated() {
            guard var r = resident(id) else { continue }
            let pick = near.first { c, d in d >= 2 && d <= 5 && !taken.contains { abs($0.row - c.row) + abs($0.col - c.col) < 2 } }?.0
                ?? near.first { c, _ in !taken.contains(c) }?.0
            guard let cell = pick else {
                LifeLog.warn(id, "test.notPlaced", floor: floor, ["why": "no open hallway cell near the player"])
                continue
            }
            taken.append(cell)
            r.floor = floor
            r.cell = cell
            r.leg = nil
            r.shown = nil
            r.room = nil
            r.roomName = nil
            r.since = now
            r.dwell = 2 + Double(i) * 2
            r.why = "test: placed near you"
            for k in r.memories.keys { r.memories[k]?.riding = false }
            store(r)
            LifeLog.event(id, "test.placed", floor: floor, ["cell": LifeLog.cell(cell), "player": LifeLog.cell(playerCell),
                                                          "rooms": plan.rooms.map { $0.name }.joined(separator: ", ")])
        }
    }

    /// A decision: where to, why, how, by when, for how long. (`decisions` > 1: an offscreen catch-up.)
    func logDecision(_ r: Resident, now: Date, offscreen: Bool, decisions: Int = 1) {
        let at = r.cell.map { "\($0.row),\($0.col)" } ?? "-"
        diag("resident.decided", ["id": r.id, "floor": r.floor, "cell": at,
                                  "arrivesIn": r.awaitsCar ? "after the car" : "\(Int(r.since.timeIntervalSince(now).rounded()))",
                                  "stays": Int(r.dwell), "byElevator": r.leg?.changesFloor ?? false, "offscreen": offscreen])
        let how: String
        if let leg = r.leg, r.isTravelling(at: now) {
            how = leg.changesFloor ? (leg.from.floor == r.floor ? "comesInByElevator" : "elevatorFromF\(leg.from.floor)") : "walk"
        } else {
            how = "staysPut"
        }
        LifeLog.event(r.id, "destination.chosen", floor: r.floor,
                      ["cell": at, "from": r.leg.map { "F\($0.from.floor) \(LifeLog.cell($0.from.cell))" }, "how": how,
                       "why": r.why, "thereIn": r.awaitsCar ? "after the car" : LifeLog.seconds(max(0, r.since.timeIntervalSince(now))),
                       "stays": LifeLog.seconds(r.dwell), "offscreen": offscreen,
                       "decisions": (decisions > 1 ? "\(decisions) (catch-up)" : nil) as String?])
    }
}

// MARK: - The floor's presentations

enum FloorPresenter {
    /// A floor's scene is built: everyone's presentation on it (the old floor's taken down first).
    static func floorBuilt(floor: Int, root: SCNNode, camera: SCNNode, controller: TapNavigationController,
                           context: CharacterLead.Context?, plans: @escaping (Int) -> FloorPlan?) {
        let life = BuildingLife.shared
        teardownAll()
        life.plans = plans
        life.currentFloor = floor
        TaskRegistry.shared.ensureGenerated(plans: plans)                   // Oct 20: the twenty tasks (once; then saved)
        life.start()
        // Oct 18 (controlled test, -HallwaysLifeTest N): everyone near the player, on that floor.
        // (The inter-floor test, -HallwaysLifeTestFloors: on the first of its floors the player reaches.)
        if let m = BuildingLife.testMode, m.floors.contains(floor), let plan = plans(floor) {
            let p = camera.worldPosition
            let cs = plan.cellSize
            life.placeForTest(floor: floor, playerCell: GridCoordinate(row: Int((p.z / cs).rounded()), col: Int((p.x / cs).rounded())), plan: plan)
        }
        // Oct 19 (DEBUG, -HallwaysHallwaysiansNear YES): the six Hallwaysians near the player, once a run.
        if HallwaysianCast.nearRequested, let plan = plans(floor) {
            let p = camera.worldPosition
            let cs = plan.cellSize
            HallwaysianCast.gatherIfAsked(life: life, floor: floor,
                                          playerCell: GridCoordinate(row: Int((p.z / cs).rounded()), col: Int((p.x / cs).rounded())), plan: plan)
        }
        for r in (plans(floor)?.rooms ?? []) {
            LifeLog.trace("building", "room", floor: floor, ["name": r.name, "id": r.id, "cells": r.cells.count, "arrivals": r.arrivals.count])
        }
        LifeLog.event("building", "rooms", floor: floor, ["here": (plans(floor)?.rooms ?? []).map { $0.name }.joined(separator: ", ")])
        ElevatorBoard.controller = controller
        CharacterRegistry.sceneRoot = root                                  // Oct 18 (contacts)
        // Oct 19 (one car): building a floor never moves the car (it used to be put
        // here). The controller is told how to ask for it, and its doors are heard.
        ElevatorBoard.attach(controller)
        let stage = FloorStage(floor: floor, root: root, camera: camera, controller: controller, context: context)
        FollowMe.floorBuilt(floor: floor, plan: plans(floor))               // Oct 23 (FOLLOW ME): its followers come along (before anyone is shown)
        life.playerPosition = { [weak camera, weak controller] in
            guard let camera else { return nil }
            // Oct 25 (PP 8, the mud fix): the camera as last drawn, from the frame snapshot (no scene-lock wait).
            if let controller, controller.cameraNode === camera {
                let p = controller.drawnPlayerPose().position
                return SIMD2<Float>(p.x, p.z)
            }
            let p = camera.presentation.worldPosition
            return SIMD2<Float>(p.x, p.z)
        }
        var made: [ResidentPresentation] = []
        for id in life.residentIDs {
            guard let kind = life.kind(of: id) else { continue }
            if let p = kind.present(id, on: stage) {
                made.append(p)
                LifeLog.event(id, "presenter.attached", floor: floor,
                              ["recordFloor": life.resident(id)?.floor, "rendered": p.isRendered, "body": p.debugState,
                               "where": p.bodyPosition.map { BuildingLife.whereabouts(of: $0, from: life.playerPosition()) }])
            } else {
                LifeLog.event(id, "presenter.none", floor: floor, ["why": context == nil ? "no floor context" : "kind declined (onboarding / not admitted)"])
            }
        }
        life.presentations = made
        diag("residents.floorBuilt", ["floor": floor, "presented": made.map { $0.residentID }.joined(separator: ",")])
        life.logStatus(now: BuildingClock.now())
    }

    /// Every presentation down (each writes its body's state back).
    static func teardownAll() {
        let life = BuildingLife.shared
        for p in life.presentations {
            LifeLog.event(p.residentID, "presenter.teardown", ["rendered": p.isRendered, "body": p.debugState])
            p.teardown()
        }
        life.presentations = []
    }

    static func playerBoarding() {
        for p in BuildingLife.shared.presentations { _ = p.playerBoarding() }
        FollowMe.playerBoarding()                                            // Oct 23 (FOLLOW ME): who's close enough to come
    }

    static func arrivalDoorsOpening() {
        for p in BuildingLife.shared.presentations { p.arrivalDoorsOpening() }
    }
}

// MARK: - The developer panel

/// Oct 18: a DEBUG-only readout of the residents -- heading, the player's
/// floor and cell, then each resident: floor, cell, room, activity (or its
/// mission, when it's guiding), countdown, and its body (spawned? where?).
/// Drawn by SwiftUI (LifeTestOverlay, in ContentView's root ZStack) from this
/// model, refreshed by BuildingLife's 1 Hz tick. Shown in the controlled
/// test (-HallwaysLifeTest N) or with -HallwaysLifePanel YES.
final class LifePanelModel: ObservableObject {
    static let shared = LifePanelModel()
    @Published var lines: [String] = []
    /// Oct 18 (inter-floor life): the ELEVATOR panel's lines (ElevatorBoard).
    @Published var elevatorLines: [String] = []
}

enum LifePanel {
    static var enabled: Bool {
        #if DEBUG
        return BuildingLife.testMode != nil || UserDefaults.standard.bool(forKey: "HallwaysLifePanel")
        #else
        return false
        #endif
    }

    static func update(_ lines: [String]) {
        if LifePanelModel.shared.lines != lines { LifePanelModel.shared.lines = lines }
    }

    static func updateElevator(_ lines: [String]) {
        if LifePanelModel.shared.elevatorLines != lines { LifePanelModel.shared.elevatorLines = lines }
    }
}

/// The panel itself: small monospaced text on a dark plate, top-left under
/// the status area; touches go straight through it.
struct LifeTestOverlay: View {
    @ObservedObject var model = LifePanelModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            residents
            // Oct 18 (inter-floor life): the ELEVATOR panel, its own plate just below.
            if !model.elevatorLines.isEmpty { elevator }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 54)
        .padding(.leading, 8)
        .padding(.trailing, 70)
        .allowsHitTesting(false)
    }

    private var elevator: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.elevatorLines.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(.system(size: i == 0 ? 11 : 10, weight: i == 0 ? .heavy : .medium, design: .monospaced))
                    .foregroundStyle(i == 0 ? Color.cyan : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
    }

    private var residents: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.lines.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(.system(size: i == 0 ? 12 : 10, weight: i == 0 ? .heavy : .medium, design: .monospaced))
                    .foregroundStyle(i == 0 ? Color.yellow : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if model.lines.isEmpty {
                Text("LIFE TEST: waiting for the first floor...").font(.system(size: 11, weight: .heavy, design: .monospaced)).foregroundStyle(Color.yellow)
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Test markers

/// Oct 18: DEBUG-only, in the controlled test: a bright name tag floating above
/// each resident's body, drawn through walls -- so a critter in a dark room or
/// round a corner can be found. Never in normal play.
enum LifeMarker {
    static func attach(to node: SCNNode, text: String, height: Float) {
        guard BuildingLife.testMode != nil else { return }
        let size = CGSize(width: 256, height: 64)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 0.92).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 18).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34, weight: .heavy), .foregroundColor: UIColor.black]
            let t = text as NSString
            let ts = t.size(withAttributes: attrs)
            t.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2), withAttributes: attrs)
        }
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.readsFromDepthBuffer = false                 // (seen through walls: it's a finder)
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        let plane = SCNPlane(width: 0.8, height: 0.2)
        plane.materials = [m]
        let tag = SCNNode(geometry: plane)
        tag.name = "lifeTestMarker"
        tag.position = SCNVector3(0, height, 0)
        tag.renderingOrder = 5000
        tag.constraints = [SCNBillboardConstraint()]
        node.addChildNode(tag)
    }
}

// MARK: - Test modes (DEBUG launch arguments)

/// Oct 18: a controlled resident test. Either ONE floor (-HallwaysLifeTest 5:
/// the regression test -- no floor changes, nothing by the elevator) or
/// INTER-FLOOR (-HallwaysLifeTestFloors 4,5: rooms of those floors only,
/// short stays, frequent trips by the elevator). Either way nothing is saved.
struct LifeTestMode: Equatable {
    static let singleKey = "HallwaysLifeTest"
    static let floorsKey = "HallwaysLifeTestFloors"
    /// The floors it may live on (sorted, no repeats).
    let floors: [Int]
    let interFloor: Bool

    var title: String {
        interFloor ? "FLOORS " + floors.map(String.init).joined(separator: "+") : "FLOOR \(floors.first ?? 0)"
    }
    var note: String {
        interFloor
            ? "-\(Self.floorsKey): residents live on F\(floors.map(String.init).joined(separator: "/F")), rooms only, 12-20 s stays, a floor change half the time by the elevator; NOTHING SAVED"
            : "-\(Self.singleKey): residents live on F\(floors.first ?? 0) only, rooms only, 3-8 s stays; NOTHING SAVED"
    }

    /// The test's pacing, from a kind's fast pacing: only these numbers change.
    func pacing(_ fast: RoamStyle) -> RoamStyle {
        var s = fast
        s.floors = Dictionary(uniqueKeysWithValues: floors.map { ($0, 1.0) })
        if interFloor {
            s.stay = 12...20                     // (Oct 18, phase 2: long enough to see a room activity through)
            s.changeFloorChance = 0.5
            s.elevatorRide = min(s.elevatorRide, 12)
        } else {
            s.stay = 3...8
            s.changeFloorChance = 0
        }
        return s
    }

    /// "4,5" / "4 5" / "4+5" -> [4, 5] (nil: fewer than two floors).
    static func floorList(_ text: String) -> [Int]? {
        let numbers = text.split(whereSeparator: { ",+ ;".contains($0) }).compactMap { Int($0) }.filter { $0 > 0 }
        let floors = Array(Set(numbers)).sorted()
        return floors.count >= 2 ? floors : nil
    }

    /// From the launch: the argument domain's values (UserDefaults), or -- in
    /// case the scheme hands an argument over as one word -- the raw arguments.
    /// The inter-floor test wins when both are given.
    static func parse(arguments: [String], singleDefault: Int, floorsDefault: String?) -> LifeTestMode? {
        var floors = floorsDefault.flatMap(floorList)
        var single = singleDefault > 0 ? singleDefault : nil
        for (i, a) in arguments.enumerated() {
            let next = i + 1 < arguments.count ? arguments[i + 1] : ""
            if floors == nil {
                if a == "-\(floorsKey)" { floors = floorList(next) }
                else if a.hasPrefix("-\(floorsKey) ") { floors = floorList(String(a.dropFirst(floorsKey.count + 2))) }
            }
            if single == nil {
                if a == "-\(singleKey)", let n = Int(next), n > 0 { single = n }
                else if a.hasPrefix("-\(singleKey) "),
                        let n = Int(a.dropFirst(singleKey.count + 2).trimmingCharacters(in: .whitespaces)), n > 0 { single = n }
            }
        }
        if let floors { return LifeTestMode(floors: floors, interFloor: true) }
        if let single { return LifeTestMode(floors: [single], interFloor: false) }
        return nil
    }
}
