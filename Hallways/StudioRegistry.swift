//
//  StudioRegistry.swift
//  Hallways
//
//  Oct 25 (PP 4) -- THE SIX RECORDING STUDIOS: Floor 4 (Recording A) holds Studios A, B and C;
//  Floor 5 (Recording B) holds D, E and F. Each floor is one corridor from the elevator (10,6)
//  east along row 10, with each studio off it through a short vestibule and a pair of lettered
//  double-glass doors (RoomEntranceDoorStyle.doubleGlass, 1.9 m) -- the floors' own data in
//  DefaultMazes.json (written by floor-maps/build_studio_floors.py; StudioTests checks the two agree).
//
//  This is the one place the studios are defined, by stable id and by cells -- never by a room's
//  name. RoomRegistry registers each as a residents' room (named from here); everything later
//  (a studio's composition, who is inside, the mixer, sessions, records) keys on `Studio.id`.
//  Nothing here is saved, and nothing here plays or records anything yet.
//
//  On a studio floor the old floor-specific fixtures are never built (SuppliesShowroom.install,
//  FloorFiveBlackout.install, the Floor 4 prototype extinguisher in HallwayScene), and the bundled
//  layout wins over any device copy saved before the studios (MazeLibrary, MazeStore.swift).
//

import Foundation

struct Studio: Equatable, Identifiable {
    /// Stable: "studio.a" ... "studio.f".
    let id: String
    /// "A" ... "F" (the lettering on its doors).
    let letter: String
    let floor: Int
    /// The room itself (its walls are the room's: the vestibule is the corridor's).
    let cells: Set<GridCoordinate>
    /// The short way in from the corridor; its `doorWall` holds the studio's doors.
    let vestibule: GridCoordinate
    let doorWall: Direction
    /// Reserved for the player-operated mixer (nothing is built there yet): the middle of the
    /// back wall, facing the doors.
    let mixerCell: GridCoordinate

    var name: String { "Studio \(letter)" }
    /// The first cell inside, through the doors.
    var entryCell: GridCoordinate {
        GridCoordinate(row: vestibule.row + doorWall.delta.row, col: vestibule.col + doorWall.delta.col)
    }
    /// Where musicians can gather: the room, less the way in and the mixer's place.
    var gatheringCells: Set<GridCoordinate> { cells.subtracting([entryCell, mixerCell]) }
}

enum StudioRegistry {
    private static func room(_ rows: ClosedRange<Int>, _ cols: ClosedRange<Int>) -> Set<GridCoordinate> {
        Set(rows.flatMap { r in cols.map { GridCoordinate(row: r, col: $0) } })
    }

    /// The six, in order. (Must match DefaultMazes.json floors 4 and 5.)
    static let all: [Studio] = [
        Studio(id: "studio.a", letter: "A", floor: 4, cells: room(6...8, 8...11),
               vestibule: GridCoordinate(row: 9, col: 9), doorWall: .north, mixerCell: GridCoordinate(row: 6, col: 10)),
        Studio(id: "studio.b", letter: "B", floor: 4, cells: room(12...14, 11...14),
               vestibule: GridCoordinate(row: 11, col: 12), doorWall: .south, mixerCell: GridCoordinate(row: 14, col: 13)),
        Studio(id: "studio.c", letter: "C", floor: 4, cells: room(9...11, 17...19),
               vestibule: GridCoordinate(row: 10, col: 16), doorWall: .east, mixerCell: GridCoordinate(row: 10, col: 19)),
        Studio(id: "studio.d", letter: "D", floor: 5, cells: room(12...14, 7...10),
               vestibule: GridCoordinate(row: 11, col: 9), doorWall: .south, mixerCell: GridCoordinate(row: 14, col: 9)),
        Studio(id: "studio.e", letter: "E", floor: 5, cells: room(6...8, 11...14),
               vestibule: GridCoordinate(row: 9, col: 12), doorWall: .north, mixerCell: GridCoordinate(row: 6, col: 13)),
        Studio(id: "studio.f", letter: "F", floor: 5, cells: room(9...11, 16...19),
               vestibule: GridCoordinate(row: 10, col: 15), doorWall: .east, mixerCell: GridCoordinate(row: 10, col: 19)),
    ]

    /// The studio floors (4 and 5).
    static let floors: Set<Int> = Set(all.map(\.floor))
    static func isStudioFloor(_ floor: Int) -> Bool { floors.contains(floor) }

    static func studios(onFloor floor: Int) -> [Studio] { all.filter { $0.floor == floor } }
    static func studio(id: String) -> Studio? { all.first { $0.id == id } }
    /// The studio a cell of a floor is inside (nil: none -- the corridor, a vestibule).
    static func studio(containing cell: GridCoordinate, onFloor floor: Int) -> Studio? {
        all.first { $0.floor == floor && $0.cells.contains(cell) }
    }
    /// The studio a registered room is (matched by its cells, never its name).
    static func studio(for room: RoomDestination) -> Studio? {
        all.first { $0.floor == room.floor && $0.cells == room.cells }
    }
}
