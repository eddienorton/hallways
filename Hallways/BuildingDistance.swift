//
//  BuildingDistance.swift
//  Hallways
//
//  Oct 19 -- BUILDING LIFE (step 1): how far, through the building, the player
//  is from any resident -- along the CURRENT floors' walkable cells, never in a
//  straight line through walls, and between floors by the one elevator.
//
//  THE TOPOLOGY is the residents' own: MazeStore.floorPlan(for:) (the live floor
//  from the live state, the others from the library) -- cells, room-entrance
//  doors (passable: anyone opens them), bathroom and window-room doors (never
//  crossed: the same rule as a resident's own routes), and each floor's
//  elevator cell. Nothing is precomputed from today's mazes: every answer is a
//  walk over the plan as it is NOW; results are cached per layout revision
//  (MazeStore.version) and dropped the moment the layout changes.
//
//  THE COST is metres of walking. Corridors: steps x the cell size. The
//  elevator: its real timing (ElevatorTiming) at a reference walking pace --
//
//      elevator(n floors) = (boardingSeconds + ElevatorTiming.run(n)) x referencePace
//
//  -- the car's own run (Oct 19: the count the cab shows the player) plus its
//  doors. With the Rocket Elevator: one floor about 11 m of walking, each
//  further floor 0.5 m more (6 s of doors + 0.35 s, + 0.3 s a floor, at
//  1.75 m/s) -- a floor change is worth about three cells of corridor.
//
//  WHERE A RESIDENT IS comes from its record (BuildingLife), exactly as its
//  presentation would show it if the player walked in: staying in a cell;
//  walking (its route, as far along as the times say -- Roam.resumeIndex);
//  at the doors waiting for the car; riding (Oct 19: where THE car is --
//  BuildingElevator's position, the one the Ant Farm draws); not in the
//  building yet. On the player's floor its body's real
//  position is used instead. Nothing is invented: no position, no distance.
//
//  UNREACHABLE is said, not guessed: no walk between the cells, no elevator on a
//  floor, a floor the player's elevator can't reach -> nil.
//

import Foundation
import simd

/// Where a resident is right now.
enum ResidentWhereabouts: Equatable {
    /// On a floor, in a cell (`point`: its body's exact spot, when it has one on the player's floor).
    case at(floor: Int, cell: GridCoordinate, point: SIMD2<Float>?, moving: Bool)
    /// In the elevator, between floors (`floor`: the floor its ride has reached).
    case riding(from: Int, to: Int, floor: Int)
    /// Not in the building yet (arriving at the front door later).
    case outside
    /// Its record doesn't place it (said why).
    case unknown(String)

    var floor: Int? {
        switch self {
        case .at(let f, _, _, _): return f
        case .riding(_, _, let f): return f
        default: return nil
        }
    }
}

/// Where the player is.
struct PlayerPlace: Equatable {
    let floor: Int
    let cell: GridCoordinate
}

enum BuildingDistance {
    /// The reference walking pace that turns elevator seconds into metres (m/s).
    static let referencePace: Double = 1.75
    /// Calling, doors opening, stepping in, doors closing (seconds).
    static let boardingSeconds: Double = 6

    /// The elevator's cost between two floors, in metres of walking (0: the same floor).
    static func elevatorMetres(floors n: Int) -> Double {
        n <= 0 ? 0 : (boardingSeconds + ElevatorTiming.run(floors: n)) * referencePace
    }

    // MARK: The meter

    /// Nearness at which the meter reads 0 (metres) -- about the width of the building and a few floors.
    static let meterFar: Double = 240
    /// The meter's knee: the first few cells move it most (metres).
    static let meterKnee: Double = 6

    /// 1 (right here) ... 0 (meterFar or more, or no way there):
    ///
    ///     meter(d) = 1 - ln(1 + d / knee) / ln(1 + far / knee)
    ///
    /// Logarithmic: a cell of progress matters a lot close by and still shows far
    /// away. (2 m -> 0.92, 7 m -> 0.79, 20 m -> 0.61, 50 m -> 0.40, 120 m -> 0.18.)
    static func meter(_ metres: Double?) -> Double {
        guard let d = metres, d.isFinite else { return 0 }
        let v = 1 - log(1 + max(0, d) / meterKnee) / log(1 + meterFar / meterKnee)
        return min(1, max(0, v))
    }
}

/// The building's routes, cached per layout revision. One per user (the app).
final class BuildingRouter {
    private let plans: (Int) -> FloorPlan?
    private let revision: () -> Int
    private var cachedRevision: Int?
    private var planCache: [Int: FloorPlan?] = [:]
    private var fields: [String: [GridCoordinate: Int]] = [:]
    private var routes: [String: [GridCoordinate]?] = [:]
    /// How many walks were actually computed (tests: the cache works).
    private(set) var searches = 0

    init(plans: @escaping (Int) -> FloorPlan?, revision: @escaping () -> Int) {
        self.plans = plans
        self.revision = revision
    }

    private func sync() {
        let r = revision()
        if fields.count > 600 || routes.count > 2000 { fields = [:]; routes = [:] }   // (a long walk about: start the cache afresh)
        if r != cachedRevision {
            cachedRevision = r
            planCache = [:]
            fields = [:]
            routes = [:]
        }
    }

    func plan(_ floor: Int) -> FloorPlan? {
        sync()
        if let p = planCache[floor] { return p }
        let p = plans(floor)
        planCache[floor] = p
        return p
    }

    /// Doors nobody walks through on the way (bathroom, window rooms).
    private static func shut(_ plan: FloorPlan) -> [GridCoordinate: Direction] {
        var shut = plan.bathroomDoors
        shut.merge(plan.windowDoors) { a, _ in a }
        return shut
    }

    /// Steps from `cell` to every cell it can walk to on `floor` (nil: not a walkable cell).
    func field(floor: Int, from cell: GridCoordinate) -> [GridCoordinate: Int]? {
        sync()
        let key = "\(floor)|\(cell.row),\(cell.col)"
        if let f = fields[key] { return f }
        guard let plan = plan(floor), plan.cells.contains(cell) else { return nil }
        searches += 1
        let shut = Self.shut(plan)
        var dist: [GridCoordinate: Int] = [cell: 0]
        var queue = [cell]
        var head = 0
        while head < queue.count {
            let c = queue[head]; head += 1
            let d = dist[c]!
            for dir in Direction.allCases {
                let n = GridCoordinate(row: c.row + dir.delta.row, col: c.col + dir.delta.col)
                guard plan.cells.contains(n), dist[n] == nil, CharacterLead.doorAnchor(c, dir, shut) == nil else { continue }
                dist[n] = d + 1
                queue.append(n)
            }
        }
        fields[key] = dist
        return dist
    }

    /// The walk between two cells (the residents' rule), cached.
    func route(floor: Int, from a: GridCoordinate, to b: GridCoordinate) -> [GridCoordinate]? {
        sync()
        let key = "\(floor)|\(a.row),\(a.col)|\(b.row),\(b.col)"
        if let r = routes[key] { return r }
        guard let plan = plan(floor) else { return nil }
        searches += 1
        let r = CharacterLead.route(from: a, to: b, cells: plan.cells, doors: Self.shut(plan), canCross: { _ in false })
        routes[key] = r
        return r
    }

    /// Metres of walking between two cells of one floor (nil: no way).
    func walkMetres(floor: Int, from a: GridCoordinate, to b: GridCoordinate) -> Double? {
        guard let plan = plan(floor), let steps = field(floor: floor, from: a)?[b] else { return nil }
        return Double(steps) * Double(plan.cellSize)
    }

    // MARK: Distance

    /// Metres of walking (and riding) from the player to the resident, through the
    /// building as it is now; nil: there is no way (said by `why`).
    /// `reachable`: the floors the player's elevator serves (nil: every floor with an elevator).
    func distance(from player: PlayerPlace, to w: ResidentWhereabouts, reachable: Set<Int>? = nil) -> (metres: Double?, why: String?) {
        func liftOK(_ f: Int) -> Bool { reachable.map { $0.contains(f) } ?? true }
        func toLift(_ floor: Int, _ cell: GridCoordinate) -> Double? {
            guard let e = plan(floor)?.elevator else { return nil }
            return walkMetres(floor: floor, from: cell, to: e)
        }
        switch w {
        case .outside:
            return (nil, "not in the building yet")
        case .unknown(let why):
            return (nil, why)
        case .at(let floor, let cell, _, _):
            if floor == player.floor {
                guard let m = walkMetres(floor: floor, from: player.cell, to: cell) else { return (nil, "no way through on this floor") }
                return (m, nil)
            }
            guard liftOK(floor), liftOK(player.floor) else { return (nil, "the elevator doesn't go there") }
            guard let out = toLift(player.floor, player.cell) else { return (nil, "no way to the elevator from here") }
            guard let e = plan(floor)?.elevator, let walk = walkMetres(floor: floor, from: e, to: cell) else {
                return (nil, "no way from the elevator to it")
            }
            return (out + BuildingDistance.elevatorMetres(floors: abs(floor - player.floor)) + walk, nil)
        case .riding(_, _, let carFloor):
            // In the car: the walk to this floor's doors, and the car's run to here.
            guard let out = toLift(player.floor, player.cell) else { return (nil, "no way to the elevator from here") }
            let n = abs(carFloor - player.floor)
            return (out + (n == 0 ? BuildingDistance.boardingSeconds * BuildingDistance.referencePace : BuildingDistance.elevatorMetres(floors: n)), nil)
        }
    }

    // MARK: Where a resident is

    /// The resident's whereabouts from its record at `now`; `body`: its body's
    /// spot on the player's floor, when it has one there (it wins). `carFloor`:
    /// the floor THE car is at (Oct 19: a rider is where the car is -- one car,
    /// one position; nil: not known).
    func whereabouts(_ r: Resident, now: Date, body: (floor: Int, point: SIMD2<Float>)? = nil, carFloor: Int? = nil) -> ResidentWhereabouts {
        if let b = body, let plan = plan(b.floor) {
            let s = plan.cellSize
            var cell = GridCoordinate(row: Int((b.point.y / s).rounded()), col: Int((b.point.x / s).rounded()))
            if !plan.cells.contains(cell) { cell = Roam.nearestCell(to: b.point, in: plan.cells, cellSize: s) ?? cell }
            return .at(floor: b.floor, cell: cell, point: b.point, moving: r.isTravelling(at: now))
        }
        guard let cell = r.cell else {
            return r.floor == ResidentPolicy.lobbyFloor ? .outside : .unknown("not placed yet")
        }
        guard let leg = r.leg, r.isTravelling(at: now) else { return .at(floor: r.floor, cell: cell, point: nil, moving: false) }
        func along(_ floor: Int, _ a: GridCoordinate, _ b: GridCoordinate, _ from: Date, _ to: Date) -> ResidentWhereabouts {
            guard let route = route(floor: floor, from: a, to: b), !route.isEmpty else {
                return .at(floor: floor, cell: b, point: nil, moving: true)          // (no route: its destination, as a rebuild would show it)
            }
            let i = Roam.resumeIndex(routeCount: route.count, departed: from, arrives: to, now: now)
            return .at(floor: floor, cell: route[i], point: nil, moving: true)
        }
        guard leg.changesFloor, leg.from.floor != r.floor else {
            return along(r.floor, leg.from.cell, cell, leg.departed, r.since)
        }
        // Oct 19 (one car): by the stage of its trip -- never a booked time.
        switch leg.lift ?? .toDoors {
        case .toDoors, .waiting:
            guard let e = plan(leg.from.floor)?.elevator else { return .unknown("no elevator on F\(leg.from.floor)") }
            if leg.lift != .waiting, let at = leg.boardAt, now < at { return along(leg.from.floor, leg.from.cell, e, leg.departed, at) }
            return .at(floor: leg.from.floor, cell: e, point: nil, moving: false)          // (at the doors, waiting for the car)
        case .riding:
            return .riding(from: leg.from.floor, to: r.floor, floor: carFloor ?? leg.from.floor)
        case .out:
            guard let e = plan(r.floor)?.elevator, let out = leg.alightAt else { return .at(floor: r.floor, cell: cell, point: nil, moving: true) }
            return along(r.floor, e, cell, out, r.since)
        }
    }
}
