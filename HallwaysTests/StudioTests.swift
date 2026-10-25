import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 25 (PP 4) -- THE RECORDING STUDIOS: Floors 4 and 5 as shipped in DefaultMazes.json, checked
/// against StudioRegistry. Pure data and scene checks: no saved data, no real stores.
@MainActor
struct StudioTests {
    private func cell(_ r: Int, _ c: Int) -> GridCoordinate { GridCoordinate(row: r, col: c) }

    private func bundled(_ id: Int) throws -> [String: Any] {
        let url = try #require(Bundle.main.url(forResource: "DefaultMazes", withExtension: "json"))
        let records = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        return try #require(records.first { ($0["id"] as? Int) == id })
    }
    private func coords(_ list: Any?) -> [GridCoordinate] {
        (list as? [[String: Any]] ?? []).compactMap { e in
            let c = (e["coord"] as? [String: Any]) ?? e
            guard let r = c["row"] as? Int, let col = c["col"] as? Int else { return nil }
            return GridCoordinate(row: r, col: col)
        }
    }
    private func doors(_ floor: [String: Any]) -> [GridCoordinate: Direction] {
        var out: [GridCoordinate: Direction] = [:]
        for d in floor["roomEntranceDoors"] as? [[String: Any]] ?? [] {
            if let c = coords([d]).first, let raw = d["direction"] as? String, let dir = Direction(rawValue: raw) { out[c] = dir }
        }
        return out
    }
    /// The floor's plan as the residents see it (the same shape MazeStore.floorPlan(for:) builds).
    private func plan(_ id: Int) throws -> FloorPlan {
        let floor = try bundled(id)
        return FloorPlan(floor: id, cells: Set(coords(floor["cells"])), doors: doors(floor), bathroomDoors: [:],
                         elevator: MazeStore.floor2ElevatorCoordinate, furnished: [], cellSize: 3.52)
    }

    // MARK: The registry

    @Test func threeStudiosOnEachRecordingFloorWithStableUniqueIDs() {
        #expect(StudioRegistry.all.map(\.id) == ["studio.a", "studio.b", "studio.c", "studio.d", "studio.e", "studio.f"])
        #expect(Set(StudioRegistry.all.map(\.id)).count == 6)
        #expect(StudioRegistry.studios(onFloor: 4).map(\.letter) == ["A", "B", "C"])
        #expect(StudioRegistry.studios(onFloor: 5).map(\.letter) == ["D", "E", "F"])
        #expect(StudioRegistry.floors == [4, 5])
        for s in StudioRegistry.all { #expect(StudioRegistry.studio(id: s.id) == s) }
        // No two studios share a cell.
        let all = StudioRegistry.all.flatMap { s in s.cells.map { "\(s.floor):\($0.row),\($0.col)" } }
        #expect(Set(all).count == all.count)
    }

    @Test func entranceInteriorMixerAndGatheringAreConsistent() {
        for s in StudioRegistry.all {
            #expect(!s.cells.contains(s.vestibule))
            #expect(s.cells.contains(s.entryCell))
            #expect(s.cells.contains(s.mixerCell))
            #expect(s.mixerCell != s.entryCell)
            // Room for a group: at least 3 x 3, and eight or more cells to gather in.
            let rows = Set(s.cells.map(\.row)), cols = Set(s.cells.map(\.col))
            #expect(rows.count >= 3 && cols.count >= 3 && s.cells.count == rows.count * cols.count)
            #expect(s.gatheringCells.count >= 7)
        }
    }

    // MARK: The bundled floors match

    @Test func theBundledFloorsHaveEveryStudioAndItsLetteredDoubleGlassDoors() throws {
        for f in [4, 5] {
            let floor = try bundled(f)
            let cells = Set(coords(floor["cells"]))
            #expect(cells.contains(MazeStore.floor2ElevatorCoordinate))
            let doorList = try #require(floor["roomEntranceDoors"] as? [[String: Any]])
            for s in StudioRegistry.studios(onFloor: f) {
                #expect(s.cells.isSubset(of: cells))
                #expect(cells.contains(s.vestibule))
                let door = try #require(doorList.first { coords([$0]).first == s.vestibule })
                #expect(door["direction"] as? String == s.doorWall.rawValue)
                #expect(door["style"] as? String == "doubleGlass")                 // the existing wide door (1.9 m)
                #expect(door["label"] as? String == "STUDIO \(s.letter)")
            }
            #expect(RoomEntranceDoorStyle.doubleGlass.doorWidth >= 1.9)
        }
    }

    /// Each studio is closed off by walls except its doors: the area behind them is exactly the room.
    @Test func eachStudioIsEnteredOnlyThroughItsDoors() throws {
        for f in [4, 5] {
            let p = try plan(f)
            let areas = RoomRegistry.areas(of: p)
            for s in StudioRegistry.studios(onFloor: f) {
                #expect(areas.contains(s.cells), "\(s.id)")
            }
            // The rest -- elevator, corridor, vestibules -- is one area.
            let hall = try #require(areas.first { $0.contains(MazeStore.floor2ElevatorCoordinate) })
            #expect(hall.count + StudioRegistry.studios(onFloor: f).reduce(0) { $0 + $1.cells.count } == p.cells.count)
        }
    }

    @Test func everyStudioIsReachableFromItsElevatorForResidentsAndThePlayer() throws {
        for f in [4, 5] {
            let p = try plan(f)
            for s in StudioRegistry.studios(onFloor: f) {
                let path = try #require(TaskRegistry.walk(p, from: MazeStore.floor2ElevatorCoordinate, to: s.mixerCell), "\(s.id)")
                #expect(path.contains(s.vestibule) && path.contains(s.entryCell))
                for g in s.gatheringCells { #expect(TaskRegistry.walk(p, from: s.entryCell, to: g) != nil) }
            }
        }
    }

    @Test func theStudiosAreTheRecordingFloorsResidentRooms() throws {
        for f in [4, 5] {
            let rooms = try plan(f).rooms.filter { StudioRegistry.studio(for: $0) != nil }
            #expect(rooms.count == 3)
            for room in rooms {
                let s = try #require(StudioRegistry.studio(for: room))
                #expect(room.name == s.name)
                #expect(!room.arrivals.isEmpty && Set(room.arrivals).isSubset(of: s.cells))
            }
            // The retired rooms are gone from these floors.
            let names = Set(try plan(f).rooms.map(\.name))
            #expect(!names.contains("Supply Room") && !names.contains("Break Room") && !names.contains("Server Room"))
        }
    }

    // MARK: Nothing old built into the new floors; Floor 5 lit

    @Test func noRetiredFixturesInTheStudioFloors() throws {
        for f in [4, 5] {
            let floor = try bundled(f)
            let cells = Set(coords(floor["cells"]))
            let start = MazeStore.floor2ElevatorCoordinate
            let built = HallwayScene.build(fromMaze: cells, cellSize: 3.52, wallHeight: 3, floorNumber: f, totalFloors: 7,
                                           playerStart: start, playerEnd: start)
            let root = built.scene.rootNode
            SuppliesShowroom.install(into: root, cellSize: 3.52, cells: cells)
            FloorFiveBlackout.install(into: root, cellSize: 3.52, cells: cells)
            #expect(root.childNode(withName: "supplyRoom", recursively: true) == nil)
            #expect(root.childNode(withName: "floorFive", recursively: true) == nil)
            #expect(root.childNode(withName: "breakerPanel", recursively: true) == nil)
            #expect(root.childNode(withName: "fireExtinguisher", recursively: true) == nil)   // (Floor 4's old prototype prop)
            #expect(!SuppliesShowroom.isInstalled(in: root))
            for key in ["photoBooths", "ticTacToeTerminals", "missionSigns", "objects", "fires"] {
                #expect((floor[key] as? [Any] ?? []).isEmpty, "\(f) \(key)")
            }
        }
    }

    @Test func everyStudioAndTheCorridorsAreLit() throws {
        for f in [4, 5] {
            let lights = Set(coords(try bundled(f)["fluorescentLights"]))
            for s in StudioRegistry.studios(onFloor: f) { #expect(lights.intersection(s.cells).count >= 4, "\(s.id)") }
            #expect(lights.contains { $0.row == 10 && $0.col >= 7 })
        }
        #expect((1...8).allSatisfy(FloorFiveBlackout.isOn))
    }
}
