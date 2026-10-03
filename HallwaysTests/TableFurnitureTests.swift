import Testing
import SceneKit
import Combine
@testable import Hallways

/// Sept 28 (first furniture proof of concept): Table + Potted Plant.
@MainActor
@Suite(.serialized)
struct TableFurnitureTests {
    /// Runs `body` with the app's real persistence isolated: mazes.json
    /// and the saved-override list are restored afterward.
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

    @Test func tableRendersAgainstTheSideWithPlantOnTopAndStaysOutOfPickups() throws {
        let cells = Set((4...6).map { GridCoordinate(row: $0, col: 5) }) // north-south corridor
        let coord = GridCoordinate(row: 5, col: 5)
        let cellSize: CGFloat = 3.2
        let result = HallwayScene.build(fromMaze: cells, cellSize: cellSize, wallHeight: 3,
            floorNumber: 2, playerStart: GridCoordinate(row: 4, col: 5), playerEnd: GridCoordinate(row: 6, col: 5),
            tables: [coord: FurnitureTable(position: .left, orientation: .northSouth, hasPlant: true)])
        let table = try #require(result.scene.rootNode.childNode(withName: "furnitureTable", recursively: true))
        #expect(DecoratorTarget.read(table)?.kind == .table)
        #expect(result.objectNodes.isEmpty)
        // Off the walking line: well away from the cell center on x, centered on z.
        let centerX = Float(CGFloat(coord.col) * cellSize)
        #expect(table.position.x < centerX - 0.8)
        #expect(abs(table.position.z - Float(CGFloat(coord.row) * cellSize)) < 0.001)
        #expect(table.position.y == 0)
        // The plant is a child of the table, seated exactly on the top surface.
        let plant = try #require(table.childNode(withName: "furnitureTablePlant", recursively: false))
        #expect(abs(plant.position.y - Float(HallwayScene.tableHeight)) < 0.0001)
        #expect(DecoratorTarget.read(plant) == nil)
        let top = try #require(table.childNode(withName: "furnitureTableTop", recursively: false))
        let (topMin, topMax) = top.boundingBox
        #expect(abs(top.position.y + topMax.y - Float(HallwayScene.tableHeight)) < 0.0001)
        #expect(top.position.y + topMin.y > 0.5)
        // Whole plant stays below eye height.
        let plantTop = plant.childNodes.map { $0.position.y + $0.boundingBox.max.y }.max() ?? 0
        #expect(plantTop > 0.3)
        #expect(plant.position.y + plantTop < 1.4)
        // Nothing in the plant reaches below its base (no sinking into the tabletop).
        let plantBottom = plant.childNodes.map { $0.position.y + $0.boundingBox.min.y }.min() ?? -1
        #expect(abs(plantBottom) < 0.0001)

        // No plant -> no plant node.
        let bare = HallwayScene.build(fromMaze: cells, cellSize: cellSize, wallHeight: 3,
            floorNumber: 2, playerStart: GridCoordinate(row: 4, col: 5), playerEnd: GridCoordinate(row: 6, col: 5),
            tables: [coord: FurnitureTable(position: .right, orientation: .northSouth, hasPlant: false)])
        let bareTable = try #require(bare.scene.rootNode.childNode(withName: "furnitureTable", recursively: true))
        #expect(bareTable.childNode(withName: "furnitureTablePlant", recursively: true) == nil)
        #expect(bareTable.position.x > centerX + 0.8)
    }

    @Test func placementRulesUndoAndCellClosure() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let coords = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
            let free = try #require(coords.first { store.objects[$0] == nil && !store.hasFire($0) })

            // CENTER is never stored.
            store.placeTable(FurnitureTable(position: .center, orientation: .eastWest, hasPlant: false), at: free)
            #expect(store.tables[free]?.position == .left)
            #expect(store.objects[free] == nil) // never a pickup
            #expect(!store.canPlaceTable(at: free)) // one per cell

            // Blocked by pickups and Fire.
            if let pickupCell = coords.first(where: { store.objects[$0] != nil }) {
                #expect(!store.canPlaceTable(at: pickupCell))
            }
            let fireCell = try #require(coords.first { $0 != free && store.objects[$0] == nil && !store.hasFire($0) })
            store.placeFire(at: fireCell)
            #expect(!store.canPlaceTable(at: fireCell))

            // Undo restores plant state, position, and existence.
            store.snapshotForUndo()
            store.updateTable(FurnitureTable(position: .right, orientation: .northSouth, hasPlant: true), at: free)
            #expect(store.tables[free] == FurnitureTable(position: .right, orientation: .northSouth, hasPlant: true))
            store.undo()
            #expect(store.tables[free] == FurnitureTable(position: .left, orientation: .eastWest, hasPlant: false))
            store.snapshotForUndo()
            store.removeTable(at: free)
            #expect(store.tables[free] == nil)
            store.undo()
            #expect(store.tables[free] != nil)

            // Closing the cell removes its table (and therefore its plant).
            store.setClosed(free)
            #expect(store.tables[free] == nil)
        }
    }

    /// Regression: the Decorator's "+" menu availability is computed in
    /// DecoratorOverlay's body, so a player move must make DecoratorState
    /// publish (and only when the cell actually changes); availability
    /// itself must follow the live current cell.
    @Test func decoratorPublishesOnPlayerMoveAndTableAvailabilityFollowsTheCell() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let coords = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.filter { store.canPlaceTable(at: $0) }
            let first = try #require(coords.first)
            let second = try #require(coords.dropFirst().first)

            let state = DecoratorState()
            state.attach(scene: SCNScene(), store: store)
            state.enabled = true
            var cell = first
            state.currentPlayerCell = { cell }

            var publishes = 0
            let subscription = state.objectWillChange.sink { publishes += 1 }
            defer { subscription.cancel() }
            state.playerCellDidChange(first)
            #expect(publishes == 1)
            state.playerCellDidChange(first)
            #expect(publishes == 1) // same cell: no redundant re-render
            state.playerCellDidChange(second)
            #expect(publishes == 2)

            #expect(state.canAddFloorObjectAtCurrentCell(.table))
            store.placeTable(FurnitureTable(), at: first)
            #expect(!state.canAddFloorObjectAtCurrentCell(.table)) // one per cell
            cell = second
            #expect(state.canAddFloorObjectAtCurrentCell(.table)) // moved: available again
            cell = first
            #expect(!state.canAddFloorObjectAtCurrentCell(.table))
            store.removeTable(at: first)
            #expect(state.canAddFloorObjectAtCurrentCell(.table)) // deleted: available again
        }
    }

    @Test func tablesRoundTripAndLegacyRecordsLoadWithoutMigration() throws {
        try withIsolatedPersistence { url in
            let store = MazeStore()
            store.switchTo(id: 2)
            let coord = try #require(store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.first { store.canPlaceTable(at: $0) })
            let table = FurnitureTable(position: .right, orientation: .eastWest, hasPlant: true)
            store.placeTable(table, at: coord)
            store.saveCurrentFloorAsOverride()

            // App relaunch.
            let restarted = MazeStore()
            restarted.switchTo(id: 2)
            #expect(restarted.tables[coord] == table)
            // Floor switching.
            restarted.switchTo(id: 3)
            #expect(restarted.tables[coord] != table)
            restarted.switchTo(id: 2)
            #expect(restarted.tables[coord] == table)

            // Older saved records have no "tables" key at all.
            var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            for index in records.indices { records[index].removeValue(forKey: "tables") }
            try JSONSerialization.data(withJSONObject: records).write(to: url, options: .atomic)
            let legacy = MazeStore()
            legacy.switchTo(id: 2)
            #expect(!legacy.cells.isEmpty)
            #expect(legacy.tables.isEmpty)
        }
    }
}
