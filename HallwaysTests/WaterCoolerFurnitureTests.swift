import Testing
import SceneKit
@testable import Hallways

/// Sept 28 (third furniture object): the office Water Cooler.
@MainActor
@Suite(.serialized)
struct WaterCoolerFurnitureTests {
    /// Runs `body` with mazes.json and the saved-override list restored
    /// afterward, same isolation as the Table/Desk tests.
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

    @Test func coolerRendersAgainstTheWallFacingTheCenterInEveryOrientation() throws {
        let cellSize: CGFloat = 3.52
        let coord = GridCoordinate(row: 5, col: 5)
        let center = SCNVector3(Float(CGFloat(coord.col) * cellSize), 0, Float(CGFloat(coord.row) * cellSize))
        let cases: [(FloorPosition, FluorescentOrientation, [GridCoordinate])] = [
            (.left, .northSouth, (4...6).map { GridCoordinate(row: $0, col: 5) }),
            (.right, .northSouth, (4...6).map { GridCoordinate(row: $0, col: 5) }),
            (.left, .eastWest, (4...6).map { GridCoordinate(row: 5, col: $0) }),
            (.right, .eastWest, (4...6).map { GridCoordinate(row: 5, col: $0) }),
        ]
        for (position, orientation, corridor) in cases {
            let result = HallwayScene.build(fromMaze: Set(corridor), cellSize: cellSize, wallHeight: 3,
                floorNumber: 2, playerStart: corridor[0], playerEnd: corridor[2],
                waterCoolers: [coord: FurnitureWaterCooler(position: position, orientation: orientation)])
            let cooler = try #require(result.scene.rootNode.childNode(withName: "furnitureWaterCooler", recursively: true))
            #expect(DecoratorTarget.read(cooler)?.kind == .waterCooler)
            #expect(result.objectNodes.isEmpty)
            // Pushed to the correct side, well clear of the walking line.
            let dx = cooler.position.x - center.x
            let dz = cooler.position.z - center.z
            let across = orientation == .northSouth ? dx : dz
            let along = orientation == .northSouth ? dz : dx
            #expect(abs(along) < 0.001)
            #expect(position == .left ? across < -1.2 : across > 1.2)
            // Its front (local +z, the taps) points back toward the cell center.
            let front = cooler.convertVector(SCNVector3(0, 0, 1), to: nil)
            let frontAcross = orientation == .northSouth ? front.x : front.z
            #expect(position == .left ? frontAcross > 0.99 : frontAcross < -0.99)
            // Back of the cabinet stays inside the wall face (cell edge minus half a 0.1 m wall).
            #expect(abs(across) + Float(HallwayScene.waterCoolerDepth / 2) < Float(cellSize / 2) - 0.05)
        }
    }

    @Test func bottleSitsOnTopAndEveryPartSelectsTheCooler() throws {
        let node = HallwayScene.buildWaterCoolerNode(at: GridCoordinate(row: 1, col: 1), cellSize: 3.52, floorNumber: 2,
                                                     cooler: FurnitureWaterCooler())
        let body = try #require(node.childNode(withName: "furnitureWaterCoolerBody", recursively: false))
        let bottle = try #require(node.childNode(withName: "furnitureWaterCoolerBottle", recursively: false))
        let bodyTop = body.position.y + body.boundingBox.max.y
        #expect(abs(bodyTop - Float(HallwayScene.waterCoolerBodyHeight)) < 0.001)
        #expect(bottle.position.y + bottle.boundingBox.min.y >= bodyTop - 0.001) // bottle on top, not sunk in
        let top = node.childNodes.map { $0.position.y + $0.boundingBox.max.y * $0.scale.y }.max() ?? 0
        #expect(top > 1.3 && top < 1.6) // tall, but below the 1.6 m eye
        // Only the root is tagged, so a hit on any part resolves to the cooler.
        for child in node.childNodes { #expect(DecoratorTarget.read(child) == nil) }
        #expect(DecoratorTarget.read(node)?.kind == .waterCooler)
    }

    @Test func placementRulesReciprocalBlockingUndoAndCellClosure() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let free = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.filter { store.canPlaceWaterCooler(at: $0) }
            let coolerCell = try #require(free.first)
            let tableCell = try #require(free.dropFirst().first)
            let deskCell = try #require(free.dropFirst(2).first)
            let fireCell = try #require(free.dropFirst(3).first)
            let empty = try #require(free.dropFirst(4).first)

            store.placeWaterCooler(FurnitureWaterCooler(position: .center, orientation: .eastWest), at: coolerCell)
            #expect(store.waterCoolers[coolerCell] == FurnitureWaterCooler(position: .left, orientation: .eastWest)) // no CENTER
            #expect(store.objects[coolerCell] == nil) // never a pickup
            #expect(!store.canPlaceWaterCooler(at: coolerCell)) // one per cell
            #expect(!store.canPlaceTable(at: coolerCell)) // reciprocal
            #expect(!store.canPlaceDesk(at: coolerCell)) // reciprocal

            store.placeTable(FurnitureTable(), at: tableCell)
            #expect(!store.canPlaceWaterCooler(at: tableCell))
            store.placeDesk(FurnitureDesk(), at: deskCell)
            #expect(!store.canPlaceWaterCooler(at: deskCell))
            store.placeFire(at: fireCell)
            #expect(!store.canPlaceWaterCooler(at: fireCell))
            if let pickupCell = store.cells.first(where: { store.objects[$0] != nil }) {
                #expect(!store.canPlaceWaterCooler(at: pickupCell))
            }

            // Undo: move/axis change, deletion, creation.
            store.snapshotForUndo()
            store.updateWaterCooler(FurnitureWaterCooler(position: .right, orientation: .northSouth), at: coolerCell)
            #expect(store.waterCoolers[coolerCell] == FurnitureWaterCooler(position: .right, orientation: .northSouth))
            store.undo()
            #expect(store.waterCoolers[coolerCell] == FurnitureWaterCooler(position: .left, orientation: .eastWest))
            store.snapshotForUndo()
            store.removeWaterCooler(at: coolerCell)
            #expect(store.waterCoolers[coolerCell] == nil)
            #expect(store.canPlaceTable(at: coolerCell) && store.canPlaceDesk(at: coolerCell))
            store.undo()
            #expect(store.waterCoolers[coolerCell] != nil)
            store.snapshotForUndo()
            store.placeWaterCooler(FurnitureWaterCooler(), at: empty)
            #expect(store.waterCoolers[empty] != nil)
            store.undo()
            #expect(store.waterCoolers[empty] == nil)

            // Closing the cell removes its cooler.
            store.setClosed(coolerCell)
            #expect(store.waterCoolers[coolerCell] == nil)
        }
    }

    @Test func coolersRoundTripAndLegacyRecordsLoadWithoutMigration() throws {
        try withIsolatedPersistence { url in
            let store = MazeStore()
            store.switchTo(id: 2)
            let coord = try #require(store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.first { store.canPlaceWaterCooler(at: $0) })
            let cooler = FurnitureWaterCooler(position: .right, orientation: .eastWest)
            store.placeWaterCooler(cooler, at: coord)
            store.saveCurrentFloorAsOverride()

            let restarted = MazeStore() // app relaunch
            restarted.switchTo(id: 2)
            #expect(restarted.waterCoolers[coord] == cooler)
            restarted.switchTo(id: 3) // floor switch
            #expect(restarted.waterCoolers[coord] != cooler)
            restarted.switchTo(id: 2)
            #expect(restarted.waterCoolers[coord] == cooler)

            var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            for index in records.indices { records[index].removeValue(forKey: "waterCoolers") }
            try JSONSerialization.data(withJSONObject: records).write(to: url, options: .atomic)
            let legacy = MazeStore()
            legacy.switchTo(id: 2)
            #expect(!legacy.cells.isEmpty)
            #expect(legacy.waterCoolers.isEmpty)
        }
    }

    @Test func coolerAvailabilityFollowsTheLiveCell() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let free = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.filter { store.canPlaceWaterCooler(at: $0) }
            let first = try #require(free.first)
            let second = try #require(free.dropFirst().first)
            let state = DecoratorState()
            state.attach(scene: SCNScene(), store: store)
            state.enabled = true
            var cell = first
            state.currentPlayerCell = { cell }

            #expect(state.canAddFloorObjectAtCurrentCell(.waterCooler))
            store.placeWaterCooler(FurnitureWaterCooler(), at: first)
            #expect(!state.canAddFloorObjectAtCurrentCell(.waterCooler))
            #expect(!state.canAddFloorObjectAtCurrentCell(.table))
            #expect(!state.canAddFloorObjectAtCurrentCell(.desk))
            cell = second
            #expect(state.canAddFloorObjectAtCurrentCell(.waterCooler))
            cell = first
            store.removeWaterCooler(at: first)
            #expect(state.canAddFloorObjectAtCurrentCell(.waterCooler))
        }
    }
}
