import Testing
import SceneKit
import Combine
@testable import Hallways

/// Sept 28 (second furniture object): the office Desk.
@MainActor
@Suite(.serialized)
struct DeskFurnitureTests {
    /// Runs `body` with mazes.json and the saved-override list restored
    /// afterward, same isolation as TableFurnitureTests.
    private func withIsolatedPersistence(_ body: (URL) throws -> Void) rethrows {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mazes.json")
        let backup = try? Data(contentsOf: url)
        let key = "maze.savedFloorOverrideIDs"
        let oldOverrides = UserDefaults.standard.object(forKey: key)
        defer {
            if let backup { try? backup.write(to: url, options: .atomic) }
            else { try? FileManager.default.removeItem(at: url) }
            if let oldOverrides { UserDefaults.standard.set(oldOverrides, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try body(url)
    }

    @Test func deskRendersBesideTheWalkingLineFacingTheCenterAndStaysOutOfPickups() throws {
        let cells = Set((4...6).map { GridCoordinate(row: $0, col: 5) }) // north-south corridor
        let coord = GridCoordinate(row: 5, col: 5)
        let cellSize: CGFloat = 3.2
        let centerX = Float(CGFloat(coord.col) * cellSize)
        for position in [FloorPosition.left, .right] {
            let result = HallwayScene.build(fromMaze: cells, cellSize: cellSize, wallHeight: 3,
                floorNumber: 2, playerStart: GridCoordinate(row: 4, col: 5), playerEnd: GridCoordinate(row: 6, col: 5),
                desks: [coord: FurnitureDesk(position: position, orientation: .northSouth)])
            let desk = try #require(result.scene.rootNode.childNode(withName: "furnitureDesk", recursively: true))
            #expect(DecoratorTarget.read(desk)?.kind == .desk)
            #expect(result.objectNodes.isEmpty)
            #expect(result.scene.rootNode.childNode(withName: "furnitureTable", recursively: true) == nil)
            // Off the walking line, against the correct side.
            #expect(position == .left ? desk.position.x < centerX - 0.7 : desk.position.x > centerX + 0.7)
            #expect(abs(desk.position.z - Float(CGFloat(coord.row) * cellSize)) < 0.001)
            // Its front (local +z) points back toward the cell center.
            let front = desk.convertVector(SCNVector3(0, 0, 1), to: nil)
            #expect(position == .left ? front.x > 0.99 : front.x < -0.99)
            // The inner (front) edge still leaves the center line clear.
            let innerEdge = abs(desk.position.x - centerX) - Float(HallwayScene.deskDepth / 2)
            #expect(innerEdge > 0.6)
            // Top surface at desk height.
            let top = try #require(desk.childNode(withName: "furnitureDeskTop", recursively: false))
            #expect(abs(top.position.y + top.boundingBox.max.y - Float(HallwayScene.deskHeight)) < 0.0001)
        }
    }

    @Test func placementRulesReciprocalTableBlockUndoAndCellClosure() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let free = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.filter { store.canPlaceDesk(at: $0) }
            let deskCell = try #require(free.first)
            let tableCell = try #require(free.dropFirst().first)
            let fireCell = try #require(free.dropFirst(2).first)

            store.placeDesk(FurnitureDesk(position: .center, orientation: .eastWest), at: deskCell)
            #expect(store.desks[deskCell] == FurnitureDesk(position: .left, orientation: .eastWest)) // no CENTER
            #expect(store.objects[deskCell] == nil) // never a pickup
            #expect(!store.canPlaceDesk(at: deskCell)) // one desk per cell
            #expect(!store.canPlaceTable(at: deskCell)) // reciprocal: desk blocks table

            store.placeTable(FurnitureTable(), at: tableCell)
            #expect(!store.canPlaceDesk(at: tableCell)) // table blocks desk
            store.placeFire(at: fireCell)
            #expect(!store.canPlaceDesk(at: fireCell))
            if let pickupCell = store.cells.first(where: { store.objects[$0] != nil }) {
                #expect(!store.canPlaceDesk(at: pickupCell))
            }

            // Undo: placement change, deletion, creation.
            store.snapshotForUndo()
            store.updateDesk(FurnitureDesk(position: .right, orientation: .northSouth), at: deskCell)
            #expect(store.desks[deskCell] == FurnitureDesk(position: .right, orientation: .northSouth))
            store.undo()
            #expect(store.desks[deskCell] == FurnitureDesk(position: .left, orientation: .eastWest))
            store.snapshotForUndo()
            store.removeDesk(at: deskCell)
            #expect(store.desks[deskCell] == nil)
            #expect(store.canPlaceTable(at: deskCell))
            store.undo()
            #expect(store.desks[deskCell] != nil)
            let empty = try #require(free.dropFirst(3).first)
            store.snapshotForUndo()
            store.placeDesk(FurnitureDesk(), at: empty)
            store.undo()
            #expect(store.desks[empty] == nil)

            // Closing the cell removes its desk.
            store.setClosed(deskCell)
            #expect(store.desks[deskCell] == nil)
        }
    }

    @Test func desksRoundTripAndLegacyRecordsLoadWithoutMigration() throws {
        try withIsolatedPersistence { url in
            let store = MazeStore()
            store.switchTo(id: 2)
            let coord = try #require(store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.first { store.canPlaceDesk(at: $0) })
            let desk = FurnitureDesk(position: .right, orientation: .eastWest)
            store.placeDesk(desk, at: coord)
            store.saveCurrentFloorAsOverride()

            let restarted = MazeStore() // app relaunch
            restarted.switchTo(id: 2)
            #expect(restarted.desks[coord] == desk)
            restarted.switchTo(id: 3) // floor switch
            #expect(restarted.desks[coord] != desk)
            restarted.switchTo(id: 2)
            #expect(restarted.desks[coord] == desk)

            var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            for index in records.indices { records[index].removeValue(forKey: "desks") }
            try JSONSerialization.data(withJSONObject: records).write(to: url, options: .atomic)
            let legacy = MazeStore()
            legacy.switchTo(id: 2)
            #expect(!legacy.cells.isEmpty)
            #expect(legacy.desks.isEmpty)
        }
    }

    @Test func deskAvailabilityFollowsTheLiveCell() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let free = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.filter { store.canPlaceDesk(at: $0) }
            let first = try #require(free.first)
            let second = try #require(free.dropFirst().first)
            let state = DecoratorState()
            state.attach(scene: SCNScene(), store: store)
            state.enabled = true
            var cell = first
            state.currentPlayerCell = { cell }

            #expect(state.canAddFloorObjectAtCurrentCell(.desk))
            store.placeDesk(FurnitureDesk(), at: first)
            #expect(!state.canAddFloorObjectAtCurrentCell(.desk))
            #expect(!state.canAddFloorObjectAtCurrentCell(.table))
            cell = second
            #expect(state.canAddFloorObjectAtCurrentCell(.desk))
            #expect(state.canAddFloorObjectAtCurrentCell(.table))
            cell = first
            store.removeDesk(at: first)
            #expect(state.canAddFloorObjectAtCurrentCell(.desk))
        }
    }
}
