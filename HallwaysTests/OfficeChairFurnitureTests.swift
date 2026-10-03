import Testing
import SceneKit
@testable import Hallways

/// Sept 28 (fourth furniture object): the Office Chair, and the first
/// allowed pairing of two furniture pieces in one cell (Desk + Chair).
@MainActor
@Suite(.serialized)
struct OfficeChairFurnitureTests {
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

    @Test func sameSideDeskAndChairFaceEachOtherOffTheWalkingLine() throws {
        let cellSize: CGFloat = 3.52
        let coord = GridCoordinate(row: 5, col: 5)
        let centerX = Float(CGFloat(coord.col) * cellSize), centerZ = Float(CGFloat(coord.row) * cellSize)
        let cases: [(FloorPosition, FluorescentOrientation, [GridCoordinate])] = [
            (.left, .northSouth, (4...6).map { GridCoordinate(row: $0, col: 5) }),
            (.right, .northSouth, (4...6).map { GridCoordinate(row: $0, col: 5) }),
            (.left, .eastWest, (4...6).map { GridCoordinate(row: 5, col: $0) }),
            (.right, .eastWest, (4...6).map { GridCoordinate(row: 5, col: $0) }),
        ]
        for (position, orientation, corridor) in cases {
            let result = HallwayScene.build(fromMaze: Set(corridor), cellSize: cellSize, wallHeight: 3,
                floorNumber: 2, playerStart: corridor[0], playerEnd: corridor[2],
                desks: [coord: FurnitureDesk(position: position, orientation: orientation)],
                officeChairs: [coord: FurnitureOfficeChair(position: position, orientation: orientation)])
            let desk = try #require(result.scene.rootNode.childNode(withName: "furnitureDesk", recursively: true))
            let chair = try #require(result.scene.rootNode.childNode(withName: "furnitureOfficeChair", recursively: true))
            #expect(result.objectNodes.isEmpty)
            // Independent nodes: neither is inside the other.
            #expect(chair.parent === desk.parent)
            #expect(desk.childNode(withName: "furnitureOfficeChair", recursively: true) == nil)
            #expect(DecoratorTarget.read(chair)?.kind == .officeChair)
            #expect(DecoratorTarget.read(desk)?.kind == .desk)

            func across(_ n: SCNNode) -> Float { orientation == .northSouth ? n.position.x - centerX : n.position.z - centerZ }
            func along(_ n: SCNNode) -> Float { orientation == .northSouth ? n.position.z - centerZ : n.position.x - centerX }
            let sign: Float = position == .left ? -1 : 1
            // Chair is on the desk's side, between the desk and the center line.
            #expect(abs(along(chair)) < 0.001)
            #expect(across(chair) * sign > 0.5)
            #expect(across(chair) * sign < across(desk) * sign)
            // Clear of the walking line: the base's inner reach stays > 0.35 m from center.
            #expect(across(chair) * sign - Float(HallwayScene.officeChairBaseRadius) > 0.35)
            // The seat's front edge meets (tucks just under) the desk's front edge.
            let deskFront = across(desk) * sign - Float(HallwayScene.deskDepth / 2)
            let seatFront = across(chair) * sign + Float(HallwayScene.officeChairSeatDepth / 2)
            #expect(seatFront > deskFront && seatFront < deskFront + 0.1)
            // They face each other: chair faces the wall, desk faces the center.
            func frontAcross(_ n: SCNNode) -> Float {
                let f = n.convertVector(SCNVector3(0, 0, 1), to: nil)
                return orientation == .northSouth ? f.x : f.z
            }
            #expect(frontAcross(chair) * sign > 0.99)
            #expect(frontAcross(desk) * sign < -0.99)
        }
    }

    @Test func chairGeometryIsAChairAndEveryPartSelectsIt() throws {
        let node = HallwayScene.buildOfficeChairNode(at: GridCoordinate(row: 1, col: 1), cellSize: 3.52, floorNumber: 2, chair: FurnitureOfficeChair())
        let seat = try #require(node.childNode(withName: "furnitureOfficeChairSeat", recursively: false))
        #expect(abs(seat.position.y + seat.boundingBox.max.y - Float(HallwayScene.officeChairSeatHeight)) < 0.001)
        let back = try #require(node.childNode(withName: "furnitureOfficeChairBack", recursively: false))
        #expect(back.position.z < 0) // back behind the seat
        node.enumerateChildNodes { child, _ in #expect(DecoratorTarget.read(child) == nil) }
        #expect(DecoratorTarget.read(node)?.kind == .officeChair)
    }

    @Test func deskAndChairShareACellAsIndependentRecords() throws {
        try withIsolatedPersistence { url in
            let store = MazeStore()
            store.switchTo(id: 2)
            let free = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.filter { store.canPlaceOfficeChair(at: $0) && store.canPlaceDesk(at: $0) }
            let shared = try #require(free.first)
            let alone = try #require(free.dropFirst().first)
            let tableCell = try #require(free.dropFirst(2).first)
            let coolerCell = try #require(free.dropFirst(3).first)
            let fireCell = try #require(free.dropFirst(4).first)
            let chairOnlyCell = try #require(free.dropFirst(5).first)

            // Alone.
            store.placeOfficeChair(FurnitureOfficeChair(position: .right, orientation: .northSouth), at: chairOnlyCell)
            #expect(store.officeChairs[chairOnlyCell] != nil)
            store.placeDesk(FurnitureDesk(position: .left, orientation: .northSouth), at: alone)
            #expect(store.desks[alone] != nil)
            #expect(store.canPlaceOfficeChair(at: alone)) // a desk doesn't block a chair

            // Desk + Chair, same side, one cell, two records.
            let desk = FurnitureDesk(position: .right, orientation: .eastWest)
            let chair = FurnitureOfficeChair(position: .right, orientation: .eastWest)
            store.placeDesk(desk, at: shared)
            store.placeOfficeChair(FurnitureOfficeChair(position: .left, orientation: .eastWest), at: shared)
            #expect(store.officeChairs[shared] == nil) // opposite side refused
            store.placeOfficeChair(chair, at: shared)
            #expect(store.desks[shared] == desk && store.officeChairs[shared] == chair)
            #expect(store.objects[shared] == nil) // neither is a pickup
            #expect(!store.canPlaceOfficeChair(at: shared)) // one chair per cell
            #expect(!store.canPlaceTable(at: shared) && !store.canPlaceWaterCooler(at: shared))

            // A desk may join a chair's cell only on the chair's side.
            store.placeDesk(FurnitureDesk(position: .left, orientation: .northSouth), at: chairOnlyCell)
            #expect(store.desks[chairOnlyCell] == nil)
            #expect(store.canPlaceDesk(at: chairOnlyCell))

            // Other restrictions still hold.
            store.placeTable(FurnitureTable(), at: tableCell)
            #expect(!store.canPlaceOfficeChair(at: tableCell))
            store.placeWaterCooler(FurnitureWaterCooler(), at: coolerCell)
            #expect(!store.canPlaceOfficeChair(at: coolerCell))
            store.placeFire(at: fireCell)
            #expect(!store.canPlaceOfficeChair(at: fireCell))
            if let pickupCell = store.cells.first(where: { store.objects[$0] != nil }) {
                #expect(!store.canPlaceOfficeChair(at: pickupCell))
            }
            #expect(!store.canPlaceTable(at: chairOnlyCell) && !store.canPlaceWaterCooler(at: chairOnlyCell))

            // Independent Undo and deletion.
            store.snapshotForUndo()
            store.updateOfficeChair(FurnitureOfficeChair(position: .left, orientation: .eastWest), at: shared)
            #expect(store.desks[shared] == desk) // moving the chair never moves the desk
            store.undo()
            #expect(store.officeChairs[shared] == chair)
            store.snapshotForUndo()
            store.updateDesk(FurnitureDesk(position: .left, orientation: .eastWest), at: shared)
            #expect(store.officeChairs[shared] == chair) // moving the desk never moves the chair
            store.undo()
            #expect(store.desks[shared] == desk)
            store.snapshotForUndo()
            store.removeDesk(at: shared)
            #expect(store.desks[shared] == nil && store.officeChairs[shared] == chair)
            store.undo()
            store.snapshotForUndo()
            store.removeOfficeChair(at: shared)
            #expect(store.officeChairs[shared] == nil && store.desks[shared] == desk)
            store.undo()
            #expect(store.desks[shared] == desk && store.officeChairs[shared] == chair)

            // Save / relaunch / floor switch restores both.
            store.saveCurrentFloorAsOverride()
            let restarted = MazeStore()
            restarted.switchTo(id: 2)
            #expect(restarted.desks[shared] == desk && restarted.officeChairs[shared] == chair)
            restarted.switchTo(id: 3)
            #expect(restarted.officeChairs[shared] != chair)
            restarted.switchTo(id: 2)
            #expect(restarted.desks[shared] == desk && restarted.officeChairs[shared] == chair)

            // Old saved records with no chair key still load.
            var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            for index in records.indices { records[index].removeValue(forKey: "officeChairs") }
            try JSONSerialization.data(withJSONObject: records).write(to: url, options: .atomic)
            let legacy = MazeStore()
            legacy.switchTo(id: 2)
            #expect(legacy.officeChairs.isEmpty)
            #expect(legacy.desks[shared] == desk)

            // Closing the cell removes both.
            store.setClosed(shared)
            #expect(store.desks[shared] == nil && store.officeChairs[shared] == nil)
        }
    }

    @Test func chairAvailabilityFollowsTheLiveCell() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let free = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.filter { store.canPlaceOfficeChair(at: $0) && store.canPlaceDesk(at: $0) }
            let first = try #require(free.first)
            let second = try #require(free.dropFirst().first)
            let state = DecoratorState()
            state.attach(scene: SCNScene(), store: store)
            state.enabled = true
            var cell = first
            state.currentPlayerCell = { cell }

            store.placeDesk(FurnitureDesk(), at: first)
            #expect(state.canAddFloorObjectAtCurrentCell(.officeChair)) // desk + chair allowed
            store.placeOfficeChair(FurnitureOfficeChair(), at: first)
            #expect(!state.canAddFloorObjectAtCurrentCell(.officeChair))
            #expect(!state.canAddFloorObjectAtCurrentCell(.table))
            cell = second
            #expect(state.canAddFloorObjectAtCurrentCell(.officeChair))
        }
    }

    @Test func yourHeightMovesTheViewNotTheFurniture() throws {
        let cells = Set((4...6).map { GridCoordinate(row: $0, col: 5) })
        let coord = GridCoordinate(row: 5, col: 5)
        let result = HallwayScene.build(fromMaze: cells, cellSize: 3.52, wallHeight: 3, floorNumber: 2,
            playerStart: coord, playerEnd: GridCoordinate(row: 6, col: 5),
            desks: [coord: FurnitureDesk()], officeChairs: [coord: FurnitureOfficeChair()])
        let controller = TapNavigationController(cameraNode: result.cameraNode, scene: result.scene,
            cells: cells, cellSize: 3.52, startCell: coord, startFacing: .north, endCell: GridCoordinate(row: 6, col: 5))
        let desk = try #require(result.scene.rootNode.childNode(withName: "furnitureDesk", recursively: true))
        let chair = try #require(result.scene.rootNode.childNode(withName: "furnitureOfficeChair", recursively: true))
        let deskBefore = desk.position, chairBefore = chair.position
        controller.setEyeHeight(PlayerHeight.eyeHeight(forInches: 84))
        #expect(SCNVector3EqualToVector3(desk.position, deskBefore))
        #expect(SCNVector3EqualToVector3(chair.position, chairBefore))
    }
}
