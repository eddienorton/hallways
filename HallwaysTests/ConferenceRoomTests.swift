import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 8 -- the Conference Room (Floor 3). Pure data and scene checks: no
/// saved data, no real stores. Simulator only.
@MainActor
struct ConferenceRoomTests {
    private func cell(_ r: Int, _ c: Int) -> GridCoordinate { GridCoordinate(row: r, col: c) }

    /// Floor 3 exactly as shipped in DefaultMazes.json.
    private func bundledFloor3() throws -> [String: Any] {
        let url = try #require(Bundle.main.url(forResource: "DefaultMazes", withExtension: "json"))
        let records = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        return try #require(records.first { ($0["id"] as? Int) == 3 })
    }
    private func coords(_ list: Any?) -> [GridCoordinate] {
        (list as? [[String: Any]] ?? []).compactMap { e in
            let c = (e["coord"] as? [String: Any]) ?? e
            guard let r = c["row"] as? Int, let col = c["col"] as? Int else { return nil }
            return GridCoordinate(row: r, col: col)
        }
    }

    @Test func floor3HasTheRoomAlcoveAndLabelledGlassDoors() throws {
        let floor = try bundledFloor3()
        let cells = Set(coords(floor["cells"]))
        #expect(ConferenceRoom.roomCells.isSubset(of: cells))
        #expect(cells.contains(ConferenceRoom.doorCell))
        let doors = try #require(floor["roomEntranceDoors"] as? [[String: Any]])
        let door = try #require(doors.first { coords([$0]).first == ConferenceRoom.doorCell })
        #expect(door["direction"] as? String == "east")
        #expect(door["style"] as? String == "doubleGlass")
        #expect(door["label"] as? String == "CONFERENCE ROOM")
    }

    @Test func theRoomTouchesTheCorridorOnlyThroughTheAlcove() throws {
        let cells = Set(coords(try bundledFloor3()["cells"]))
        let added = ConferenceRoom.roomCells.union([ConferenceRoom.doorCell])
        for c in added {
            for d in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let n = cell(c.row + d.0, c.col + d.1)
                guard cells.contains(n), !added.contains(n) else { continue }
                #expect(c == ConferenceRoom.doorCell && n == cell(6, 7), "unexpected opening \(c) -> \(n)")
            }
        }
    }

    @Test func onlyThreeFixturesWereAddedAndTheOfficeIsUntouched() throws {
        let floor = try bundledFloor3()
        let fixtures = Set(coords(floor["fluorescentLights"]))
        let added = ConferenceRoom.roomCells.union([ConferenceRoom.doorCell])
        #expect(fixtures.intersection(added) == [cell(6, 8), cell(5, 10), cell(7, 10)])
        let cells = Set(coords(floor["cells"]))
        #expect(PlayerOffice.officeCells.isSubset(of: cells))
        #expect(PlayerOffice.officeCells.isDisjoint(with: added))
        #expect(coords(floor["roomEntranceDoors"]).contains(PlayerOffice.doorCell))
    }

    @Test func installBuildsTableEightChairsAndBoardClearOfThePlayer() {
        let root = SCNNode()
        let cells = ConferenceRoom.roomCells.union([ConferenceRoom.doorCell])
        ConferenceRoom.install(into: root, cellSize: 3.52, cells: cells)
        let room = root.childNode(withName: "conferenceRoom", recursively: false)
        #expect(room != nil)
        #expect(room?.childNode(withName: "conferenceRoomTable", recursively: false) != nil)
        #expect(room?.childNode(withName: "conferenceRoomBoard", recursively: false) != nil)
        let chairs = room?.childNodes.filter { $0.name?.hasPrefix("conferenceRoomChair") == true } ?? []
        #expect(chairs.count == 8)
        let s: Float = 3.52
        for chair in chairs {
            let p = chair.position
            // Inside the room's walls (with room for the chair itself).
            #expect(p.x > 8.5 * s + 0.4 && p.x < 10.5 * s - 0.35)
            #expect(p.z > 4.5 * s + 0.4 && p.z < 7.5 * s - 0.4)
            // Well clear of where the player walks (column 9's centre line).
            #expect(p.x - 9 * s > 1.4)
        }
    }

    @Test func aMismatchedLayoutBuildsNothing() {
        let root = SCNNode()
        ConferenceRoom.install(into: root, cellSize: 3.52, cells: [cell(6, 8), cell(6, 9)])
        #expect(root.childNode(withName: "conferenceRoom", recursively: false) == nil)
    }

    @Test func theTableBayIsNotWalkable() {
        #expect(ConferenceRoom.tableBayCells.isSubset(of: ConferenceRoom.roomCells))
        #expect(!ConferenceRoom.tableBayCells.contains(ConferenceRoom.entryCell))
        #expect(ConferenceRoom.roomCells.subtracting(ConferenceRoom.tableBayCells) == [cell(5, 9), cell(6, 9), cell(7, 9)])
    }

    /// The doors stop the player until opened, from either side.
    @Test func theGlassDoorsGateEntryAndExit() {
        let walkable: Set<GridCoordinate> = [cell(6, 7), ConferenceRoom.doorCell, cell(5, 9), cell(6, 9), cell(7, 9)]
        let doors: [GridCoordinate: Direction] = [ConferenceRoom.doorCell: .east]

        let entering = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: walkable, cellSize: 3.52,
                                               startCell: ConferenceRoom.doorCell, startFacing: .east, endCell: cell(6, 7),
                                               roomEntranceDoors: doors)
        #expect(!entering.openDirections.contains(.east))
        entering.openRoomEntranceDoor(at: ConferenceRoom.doorCell)
        #expect(entering.openDirections.contains(.east))

        let leaving = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: walkable, cellSize: 3.52,
                                              startCell: ConferenceRoom.entryCell, startFacing: .west, endCell: cell(6, 7),
                                              roomEntranceDoors: doors)
        #expect(!leaving.openDirections.contains(.west))
        leaving.openRoomEntranceDoor(at: ConferenceRoom.doorCell)
        #expect(leaving.openDirections.contains(.west))
    }
}
