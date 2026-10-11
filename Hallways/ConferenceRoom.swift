import SceneKit
import UIKit
import simd

/// Oct 8 -- THE CONFERENCE ROOM (Floor 3), staged for the staff-meeting
/// storyline. A room only: no meetings, schedules or story triggers yet.
///
/// Layout (DefaultMazes Floor 3, additions only):
///
///          col: 7   8   9   10
///     row 5     #   .   R   T
///     row 6     #   A | R   T      A  = recessed alcove off the middle corridor
///     row 7     #   .   R   T      |  = "CONFERENCE ROOM" double glass doors
///                                  R  = the player's side of the room
///                                  T  = the table bay: seen, not walked
///
/// The doors are an ordinary Room Entrance (doubleGlass, labelled) in the
/// east wall of the alcove (6,8); the lights are three ordinary fluorescent
/// fixtures. This file builds only the furnishings: one polished table down
/// the bay, eight chairs around it, and a presentation board on the north
/// wall. Room-local == world x/z, y = 0 at the floor's top surface -- the
/// same convention as PlayerOffice.
enum ConferenceRoom {
    static let floor = PlayerOffice.floor
    /// The alcove; its east wall holds the doors.
    static let doorCell = GridCoordinate(row: 6, col: 8)
    /// The first cell inside, entered heading east.
    static let entryCell = GridCoordinate(row: 6, col: 9)
    static let roomCells: Set<GridCoordinate> = [
        GridCoordinate(row: 5, col: 9), GridCoordinate(row: 6, col: 9), GridCoordinate(row: 7, col: 9),
        GridCoordinate(row: 5, col: 10), GridCoordinate(row: 6, col: 10), GridCoordinate(row: 7, col: 10),
    ]
    /// The table, its chairs and the space around them: seen, not walked
    /// (subtracted from navigation, like the office desk bay).
    static let tableBayCells: Set<GridCoordinate> = [
        GridCoordinate(row: 5, col: 10), GridCoordinate(row: 6, col: 10), GridCoordinate(row: 7, col: 10),
    ]
    static let floorTopY: Float = 0.05

    // The table, metres.
    static let tableLength: Float = 5.4          // north-south
    static let tableWidth: Float = 1.3
    static let tableTopHeight: Float = 0.75
    /// The table's centre sits a little west of the bay's centre line, so the
    /// far chairs clear the east wall and the near chairs face the player.
    static let tableOffsetX: Float = -0.25

    static weak var roomNode: SCNNode?
    /// World x/z of the table's centre (this build).
    private(set) static var tableCenter = SIMD2<Float>(0, 0)

    static func install(into root: SCNNode, cellSize: CGFloat, cells: Set<GridCoordinate>) {
        guard roomCells.isSubset(of: cells), cells.contains(doorCell) else {
            diag("conferenceRoom.layoutMismatch", ["cells": cells.count])
            return
        }
        let s = Float(cellSize)
        let room = SCNNode()
        room.name = "conferenceRoom"
        room.position = SCNVector3(0, floorTopY, 0)
        root.addChildNode(room)
        roomNode = room

        let northZ = (Float(5) - 0.5) * s, southZ = (Float(7) + 0.5) * s
        let westX = (Float(9) - 0.5) * s, eastX = (Float(10) + 0.5) * s
        let cx = Float(10) * s + tableOffsetX, cz = Float(6) * s
        tableCenter = SIMD2<Float>(cx, cz)

        let table = makeTable()
        table.position = SCNVector3(cx, 0, cz)
        room.addChildNode(table)

        // Eight chairs, squared to the table and pulled in a little: three
        // along each long side, one at each end. Local +Z is the way a seat
        // faces; yaw = Direction.yaw of the OPPOSITE way (see Direction.yaw).
        let sideOffset = tableWidth / 2 + 0.42
        let endOffset = tableLength / 2 + 0.42
        var seats: [(SCNVector3, Float)] = []
        for dz: Float in [-1.75, 0, 1.75] {
            seats.append((SCNVector3(cx - sideOffset, 0, cz + dz), Float(Direction.west.yaw)))   // west side, facing east
            seats.append((SCNVector3(cx + sideOffset, 0, cz + dz), Float(Direction.east.yaw)))   // east side, facing west
        }
        seats.append((SCNVector3(cx, 0, cz - endOffset), Float(Direction.north.yaw)))           // north end, facing south
        seats.append((SCNVector3(cx, 0, cz + endOffset), Float(Direction.south.yaw)))           // south end, facing north
        for (i, seat) in seats.enumerated() {
            let chair = AdministrationReception.makeDeskChair()
            chair.name = "conferenceRoomChair\(i)"
            chair.position = seat.0
            chair.eulerAngles.y = seat.1
            room.addChildNode(chair)
        }

        // The presentation board: centred on the north wall, facing the room.
        let board = makePresentationBoard()
        board.position = SCNVector3((westX + eastX) / 2, 0, northZ + 0.02)
        room.addChildNode(board)

        diag("conferenceRoom.installed", ["tableX": Double(cx), "tableZ": Double(cz), "chairs": seats.count,
                                          "southZ": Double(southZ)])
    }

    // MARK: Furnishings

    /// A polished walnut boardroom table on two pedestals, with a flush
    /// brushed-metal power/data box in the middle. Long axis along local Z.
    static func makeTable() -> SCNNode {
        let root = SCNNode()
        root.name = "conferenceRoomTable"
        let walnut = AdministrationReception.material(UIColor(red: 0.27, green: 0.15, blue: 0.09, alpha: 1), rough: 0.18)
        let edge = AdministrationReception.material(UIColor(red: 0.17, green: 0.09, blue: 0.05, alpha: 1), rough: 0.3)
        let base = AdministrationReception.material(UIColor(white: 0.12, alpha: 1), metal: 0.3, rough: 0.45)
        let metal = AdministrationReception.material(UIColor(white: 0.62, alpha: 1), metal: 0.9, rough: 0.28)
        let w = CGFloat(tableWidth), l = CGFloat(tableLength)
        let topT: Float = 0.05
        // Top, with a slightly darker edge band beneath it.
        AdministrationReception.box(w, CGFloat(topT), l, walnut, 0, tableTopHeight - topT / 2, 0, in: root, chamfer: 0.012)
        AdministrationReception.box(w - 0.04, 0.04, l - 0.04, edge, 0, tableTopHeight - topT - 0.02, 0, in: root, chamfer: 0.006)
        // Two pedestals, each on a low plinth.
        for z: Float in [-1.5, 1.5] {
            AdministrationReception.box(0.46, CGFloat(tableTopHeight - topT - 0.06), 0.62, base,
                                        0, (tableTopHeight - topT - 0.06) / 2 + 0.02, z, in: root, chamfer: 0.01)
            AdministrationReception.box(0.62, 0.02, 0.8, base, 0, 0.01, z, in: root, chamfer: 0.005)
        }
        // The power/data box, flush in the top's centre line.
        AdministrationReception.box(0.18, 0.006, 0.42, metal, 0, tableTopHeight + 0.003, 0, in: root, chamfer: 0.002)
        return root
    }

    /// A simple wall-mounted whiteboard: a white panel in a thin aluminium
    /// frame with a marker tray. Faces local +Z; origin on the floor at the wall.
    static func makePresentationBoard() -> SCNNode {
        let root = SCNNode()
        root.name = "conferenceRoomBoard"
        let white = AdministrationReception.material(UIColor(white: 0.95, alpha: 1), rough: 0.22)
        let aluminium = AdministrationReception.material(UIColor(white: 0.7, alpha: 1), metal: 0.85, rough: 0.35)
        let width: Float = 2.2, height: Float = 1.2, centreY: Float = 1.55, depth: Float = 0.025
        AdministrationReception.box(CGFloat(width), CGFloat(height), CGFloat(depth), white, 0, centreY, depth / 2, in: root, chamfer: 0.002)
        let frame: Float = 0.03
        for y in [centreY - height / 2, centreY + height / 2] {
            AdministrationReception.box(CGFloat(width + 2 * frame), CGFloat(frame), CGFloat(depth + 0.01), aluminium,
                                        0, y, depth / 2, in: root, chamfer: 0.003)
        }
        for x in [-width / 2, width / 2] {
            AdministrationReception.box(CGFloat(frame), CGFloat(height), CGFloat(depth + 0.01), aluminium,
                                        x, centreY, depth / 2, in: root, chamfer: 0.003)
        }
        // Marker tray along the bottom edge, with two markers.
        AdministrationReception.box(0.9, 0.025, 0.07, aluminium, 0, centreY - height / 2 - 0.03, 0.05, in: root, chamfer: 0.004)
        let markerColors = [UIColor(red: 0.1, green: 0.2, blue: 0.55, alpha: 1), UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)]
        for (i, color) in markerColors.enumerated() {
            let marker = SCNNode(geometry: SCNCylinder(radius: 0.009, height: 0.13))
            marker.geometry?.materials = [AdministrationReception.material(color, rough: 0.4)]
            marker.eulerAngles.z = .pi / 2
            marker.position = SCNVector3(Float(i) * 0.18 - 0.2, centreY - height / 2 - 0.008, 0.055)
            root.addChildNode(marker)
        }
        return root
    }
}
