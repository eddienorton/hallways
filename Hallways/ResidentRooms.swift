//
//  ResidentRooms.swift
//  Hallways
//
//  Oct 18 -- ROOMS AS DESTINATIONS: where residents go.
//
//  A resident's ordinary life is a round of real places: it picks a room,
//  walks (or rides) there, lingers a little, picks another. The rooms come
//  from the MAP, never from critter code:
//
//    Detected   any area of a floor closed off by doorways (room-entrance,
//               bathroom or window doors -- the same rule as the editor's
//               Connected Area fill, MazeStore.connectedArea) that is not the
//               elevator's area and is entered through a room-entrance door.
//               A room added in the editor is a destination at once; one
//               removed simply stops being one.
//    Authored   rooms the game's own feature code already defines by cells
//               (the conference room, the player's office, the Supply Room,
//               Floor 5's four rooms) -- registered from their OWN
//               definitions, which also name the detected rooms they match
//               and can say which cells aren't walkable (the conference
//               table, the office desk). A room the map no longer has (cells
//               edited away) is skipped.
//
//  Each room: a stable id (resilient to edits -- a stale id is just "not
//  there any more"), a name, its cells, and its ARRIVAL cells: open cells to
//  stand in (not furniture, not a table/desk bay), several where it can, so
//  residents don't pile onto one spot.
//

import Foundation

struct RoomDestination: Equatable {
    /// Stable: "F5 Break Room" for a named room, "F6 room@12,11" for an unnamed detected one.
    let id: String
    let floor: Int
    let name: String
    let cells: Set<GridCoordinate>
    /// Where a resident may stand in it (never empty for a registered room).
    let arrivals: [GridCoordinate]
}

/// A room the game's code defines (its own cells, its own name).
struct AuthoredRoom {
    let floor: Int
    let name: String
    let cells: Set<GridCoordinate>
    /// Cells of it nobody stands in (a table bay, a desk bay).
    var blocked: Set<GridCoordinate> = []
}

enum RoomRegistry {
    /// The rooms the game's feature code defines -- each from its own definition.
    static var authored: [AuthoredRoom] {
        var rooms = [
            AuthoredRoom(floor: ConferenceRoom.floor, name: "Conference Room", cells: ConferenceRoom.roomCells,
                         blocked: ConferenceRoom.tableBayCells),
            AuthoredRoom(floor: PlayerOffice.floor, name: "Office", cells: PlayerOffice.officeCells,
                         blocked: PlayerOffice.deskBayCells),
            AuthoredRoom(floor: SuppliesShowroom.floor, name: "Supply Room", cells: SuppliesShowroom.roomCells),
        ]
        // Floor 5's rooms (its breaker circuits 5-8; 1-4 are its halls).
        for c in FloorFiveBlackout.circuits where c.number >= 5 {
            rooms.append(AuthoredRoom(floor: FloorFiveBlackout.floor, name: c.label.capitalized, cells: c.cells))
        }
        return rooms
    }

    /// The areas of a floor, split at every doorway (room-entrance, bathroom, window).
    static func areas(of plan: FloorPlan) -> [Set<GridCoordinate>] {
        var seen = Set<GridCoordinate>()
        var out: [Set<GridCoordinate>] = []
        for start in plan.cells.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }) where !seen.contains(start) {
            var area: Set<GridCoordinate> = [start]
            var queue = [start]
            var i = 0
            while i < queue.count {
                let here = queue[i]
                i += 1
                for d in Direction.allCases {
                    let next = GridCoordinate(row: here.row + d.delta.row, col: here.col + d.delta.col)
                    guard plan.cells.contains(next), !area.contains(next), !plan.hasDoorway(here, d) else { continue }
                    area.insert(next)
                    queue.append(next)
                }
            }
            seen.formUnion(area)
            out.append(area)
        }
        return out
    }

    /// The floor's rooms: detected from its doorways, named (and refined) by
    /// the authored rooms they match, plus authored rooms with no doorway of
    /// their own (the Supply Room opens straight off its foyer).
    static func rooms(in plan: FloorPlan) -> [RoomDestination] {
        let authoredHere = authored.filter { $0.floor == plan.floor && !$0.cells.isEmpty && $0.cells.isSubset(of: plan.cells) }
        var claimed = Set<String>()
        var rooms: [RoomDestination] = []
        let hall = plan.elevator.flatMap { e in areas(of: plan).first { $0.contains(e) } } ?? []
        for area in areas(of: plan) where area != hall {
            // Entered through a room-entrance door (not only a bathroom or a window).
            let entered = area.contains { c in Direction.allCases.contains { plan.doorAnchorIsRoomEntrance(c, $0) } }
            guard entered else { continue }
            let match = authoredHere.max { a, b in a.cells.intersection(area).count < b.cells.intersection(area).count }
            let named = match.flatMap { $0.cells.intersection(area).count * 2 >= area.count ? $0 : nil }
            if let named { claimed.insert(named.name) }
            let first = area.min { ($0.row, $0.col) < ($1.row, $1.col) }!
            let name = named?.name ?? "Room at \(first.row),\(first.col)"
            let room = make(id: "F\(plan.floor) \(name)", floor: plan.floor, name: name, cells: area,
                            blocked: named?.blocked ?? [], plan: plan)
            if let room { rooms.append(room) }
        }
        for a in authoredHere where !claimed.contains(a.name) {
            if let room = make(id: "F\(plan.floor) \(a.name)", floor: plan.floor, name: a.name, cells: a.cells, blocked: a.blocked, plan: plan) {
                rooms.append(room)
            }
        }
        rooms += spots(in: plan, outside: rooms.reduce(into: Set<GridCoordinate>()) { $0.formUnion($1.cells) })
        return rooms.sorted { $0.id < $1.id }
    }

    /// Oct 18 (open the building): an open-plan floor's furnished places -- a
    /// group of furniture standing together outside any room (desks, a lounge's
    /// tables, an aquarium) -- are destinations too, named for what's there, with
    /// the open floor around them to stand on. (Many floors have furniture and
    /// no rooms; a hallway cell on its own is never a destination.)
    static func spots(in plan: FloorPlan, outside roomCells: Set<GridCoordinate>) -> [RoomDestination] {
        let loose = plan.furnished.intersection(plan.cells).subtracting(roomCells)
        var seen = Set<GridCoordinate>()
        var out: [RoomDestination] = []
        for start in loose.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }) where !seen.contains(start) {
            // The group: furniture within a step of furniture (diagonals too).
            var group: Set<GridCoordinate> = [start]
            var queue = [start]
            while let c = queue.popLast() {
                for dr in -1...1 { for dc in -1...1 where dr != 0 || dc != 0 {
                    let n = GridCoordinate(row: c.row + dr, col: c.col + dc)
                    if loose.contains(n), !group.contains(n) { group.insert(n); queue.append(n) }
                } }
            }
            seen.formUnion(group)
            // Where to stand: the open cells beside it (not furniture, the elevator, a doorway or a room).
            var stand = Set<GridCoordinate>()
            for c in group { for d in Direction.allCases {
                let n = GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
                guard plan.cells.contains(n), !plan.furnished.contains(n), n != plan.elevator, !roomCells.contains(n),
                      !Direction.allCases.contains(where: { plan.hasDoorway(n, $0) }) else { continue }
                stand.insert(n)
            } }
            guard !stand.isEmpty else { continue }
            let first = group.min { ($0.row, $0.col) < ($1.row, $1.col) }!
            let name = spotName(group.compactMap { plan.furnitureKinds[$0] }) + " at \(first.row),\(first.col)"
            out.append(RoomDestination(id: "F\(plan.floor) \(name)", floor: plan.floor, name: name, cells: group.union(stand),
                                       arrivals: stand.sorted { ($0.row, $0.col) < ($1.row, $1.col) }))
        }
        return out
    }

    /// A furnished place's name, from what stands there most.
    static func spotName(_ kinds: [String]) -> String {
        let names = ["desk": "Desks", "table": "Tables", "officeChair": "Seating", "floorLamp": "Lamp corner",
                     "aquarium": "Aquarium", "filingCabinet": "Files", "waterCooler": "Water cooler"]
        var count: [String: Int] = [:]
        for k in kinds { count[k, default: 0] += 1 }
        // (an aquarium or a water cooler names the place whatever else is there)
        if count["aquarium"] != nil { return "Aquarium" }
        if count["waterCooler"] != nil { return "Water cooler" }
        let top = count.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
        return top.flatMap { names[$0] } ?? "Furniture"
    }

    /// Oct 18 (open the building): the lobby's entrance -- its cell farthest (by a
    /// legal walk) from the elevator. Where every resident comes in.
    static func lobbyEntrance(_ plan: FloorPlan) -> GridCoordinate? {
        guard let elevator = plan.elevator else { return nil }
        return plan.cells.compactMap { c -> (GridCoordinate, Int)? in
            plan.route(from: elevator, to: c).map { (c, $0.count) }
        }.max { a, b in a.1 != b.1 ? a.1 < b.1 : (a.0.row, a.0.col) > (b.0.row, b.0.col) }?.0
    }

    private static func make(id: String, floor: Int, name: String, cells: Set<GridCoordinate>, blocked: Set<GridCoordinate>,
                             plan: FloorPlan) -> RoomDestination? {
        let open = cells.filter { !blocked.contains($0) && !plan.furnished.contains($0) && $0 != plan.elevator }
            .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        guard !open.isEmpty else { return nil }
        // Not the doorway cells when it can help it (it shouldn't stand in the door).
        let inner = open.filter { c in !Direction.allCases.contains { plan.hasDoorway(c, $0) } }
        return RoomDestination(id: id, floor: floor, name: name, cells: cells, arrivals: inner.isEmpty ? open : inner)
    }
}

extension FloorPlan {
    /// The edge from `c` going `d` is a doorway (any kind).
    func hasDoorway(_ c: GridCoordinate, _ d: Direction) -> Bool {
        let n = GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
        func on(_ doors: [GridCoordinate: Direction]) -> Bool { doors[c] == d || doors[n] == d.opposite }
        return on(doors) || on(bathroomDoors) || on(windowDoors)
    }
    /// The edge from `c` going `d` is a room-entrance door.
    func doorAnchorIsRoomEntrance(_ c: GridCoordinate, _ d: Direction) -> Bool {
        let n = GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
        return doors[c] == d || doors[n] == d.opposite
    }
    /// This floor's rooms (see RoomRegistry).
    var rooms: [RoomDestination] { RoomRegistry.rooms(in: self) }
}
