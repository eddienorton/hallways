import Testing
import SceneKit
@testable import Hallways

/// Sept 28 (sixth furniture object): the Aquarium.
@MainActor
@Suite(.serialized)
struct AquariumFurnitureTests {
    /// Same isolation as the other furniture tests.
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

    @Test func aquariumRendersAgainstTheWallFacingTheCenterInEveryOrientation() throws {
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
                aquariums: [coord: FurnitureAquarium(position: position, orientation: orientation)])
            let tank = try #require(result.scene.rootNode.childNode(withName: "furnitureAquarium", recursively: true))
            #expect(DecoratorTarget.read(tank)?.kind == .aquarium)
            #expect(result.objectNodes.isEmpty) // never a pickup
            let dx = tank.position.x - center.x
            let dz = tank.position.z - center.z
            let across = orientation == .northSouth ? dx : dz
            let along = orientation == .northSouth ? dz : dx
            #expect(abs(along) < 0.001)
            #expect(position == .left ? across < -1.2 : across > 1.2)
            // Front (local +z, cabinet doors) faces the cell center.
            let front = tank.convertVector(SCNVector3(0, 0, 1), to: nil)
            let frontAcross = orientation == .northSouth ? front.x : front.z
            #expect(position == .left ? frontAcross > 0.99 : frontAcross < -0.99)
            // Back stays inside the wall face; front leaves a wide walking lane.
            #expect(abs(across) + Float(HallwayScene.aquariumDepth / 2) < Float(cellSize / 2) - 0.05)
            #expect(abs(across) - Float(HallwayScene.aquariumDepth / 2) > 0.9)
        }
    }

    @Test func dimensionsContentsAndOnlyTheRootIsTagged() throws {
        #expect(HallwayScene.aquariumWidth >= 1.1 && HallwayScene.aquariumWidth <= 1.4)
        #expect(HallwayScene.aquariumDepth >= 0.4 && HallwayScene.aquariumDepth <= 0.5)
        #expect(HallwayScene.aquariumHeight >= 1.3 && HallwayScene.aquariumHeight <= 1.5)
        let node = HallwayScene.buildAquariumNode(at: GridCoordinate(row: 1, col: 1), cellSize: 3.52, floorNumber: 2,
                                                  aquarium: FurnitureAquarium())
        #expect(node.name == "furnitureAquarium")
        #expect(DecoratorTarget.read(node)?.kind == .aquarium)
        var fish = 0, lights = 0, tagged = 0, animated = 0
        node.enumerateChildNodes { child, _ in
            if child.name == "furnitureAquariumFish" { fish += 1 }
            if child.light != nil { lights += 1 }
            if DecoratorTarget.read(child) != nil { tagged += 1 }
            if !child.actionKeys.isEmpty { animated += 1 }
            // Every part resolves to this aquarium by parent walk.
            #expect(HallwayScene.aquariumCoordinate(for: child) == GridCoordinate(row: 1, col: 1))
        }
        #expect(fish >= 4)
        #expect(lights == 1)
        #expect(tagged == 0)
        #expect(animated > fish) // fish lanes + bobs + tails + plants
        // One transparent water volume that doesn't write depth.
        let water = try #require(node.childNode(withName: "furnitureAquariumWater", recursively: false))
        let material = try #require(water.geometry?.firstMaterial)
        #expect(material.transparency < 1 && !material.writesToDepthBuffer)
        // A floor lamp's lookup never claims an aquarium.
        #expect(HallwayScene.floorLampCoordinate(for: water) == nil)
    }

    @Test func fishStayInsideTheTankWhileSwimming() throws {
        let node = HallwayScene.buildAquariumNode(at: GridCoordinate(row: 1, col: 1), cellSize: 3.52, floorNumber: 2,
                                                  aquarium: FurnitureAquarium())
        let halfW = Float(HallwayScene.aquariumWaterWidth / 2), halfD = Float(HallwayScene.aquariumWaterDepth / 2)
        let bottom = Float(HallwayScene.aquariumWaterBottom), top = bottom + Float(HallwayScene.aquariumWaterHeight)
        let lanes = node.childNodes.filter { $0.name == "furnitureAquariumFish" }
        #expect(!lanes.isEmpty)
        for lane in lanes {
            // Lane starts at -halfRun and swims +2·halfRun; a fish body is ~0.13 m long.
            let start = lane.position.x
            let end = start + 2 * abs(start)
            #expect(start - 0.08 > -halfW && end + 0.08 < halfW)
            #expect(abs(lane.position.z) + 0.03 < halfD)
            #expect(lane.position.y - 0.05 > bottom + 0.05 && lane.position.y + 0.08 < top) // above gravel, below surface
        }
    }

    @Test func occupancyIsExclusiveAndDeskChairPairingStillWorks() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let free = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
                .filter { store.canPlaceAquarium(at: $0) && store.canPlaceDesk(at: $0) && store.canPlaceOfficeChair(at: $0) }
            let tankCell = try #require(free.first)
            let tableCell = try #require(free.dropFirst().first)
            let lampCell = try #require(free.dropFirst(2).first)
            let pairCell = try #require(free.dropFirst(3).first)
            let fireCell = try #require(free.dropFirst(4).first)

            store.placeAquarium(FurnitureAquarium(position: .center, orientation: .eastWest), at: tankCell)
            #expect(store.aquariums[tankCell] == FurnitureAquarium(position: .left, orientation: .eastWest)) // no CENTER
            #expect(store.objects[tankCell] == nil)
            #expect(!store.canPlaceAquarium(at: tankCell))
            #expect(!store.canPlaceTable(at: tankCell))
            #expect(!store.canPlaceDesk(at: tankCell))
            #expect(!store.canPlaceWaterCooler(at: tankCell))
            #expect(!store.canPlaceOfficeChair(at: tankCell))
            #expect(!store.canPlaceFloorLamp(at: tankCell))
            #expect(!store.canPlaceFloorLamp(at: tankCell, side: .right)) // not even the opposite side

            store.placeTable(FurnitureTable(), at: tableCell)
            #expect(!store.canPlaceAquarium(at: tableCell))
            store.placeFloorLamp(FurnitureFloorLamp(), at: lampCell)
            #expect(!store.canPlaceAquarium(at: lampCell))
            store.placeFire(at: fireCell)
            #expect(!store.canPlaceAquarium(at: fireCell))
            if let pickupCell = store.cells.first(where: { store.objects[$0] != nil }) {
                #expect(!store.canPlaceAquarium(at: pickupCell))
            }

            // Desk + Chair exception untouched.
            store.placeDesk(FurnitureDesk(position: .right, orientation: .northSouth), at: pairCell)
            store.placeOfficeChair(FurnitureOfficeChair(position: .right, orientation: .northSouth), at: pairCell)
            #expect(store.desks[pairCell] != nil && store.officeChairs[pairCell] != nil)
            #expect(!store.canPlaceAquarium(at: pairCell))

            // Closing the cell removes its aquarium.
            store.setClosed(tankCell)
            #expect(store.aquariums[tankCell] == nil)
        }
    }

    @Test func undoCoversAddDeleteAndPositionChanges() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let free = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.filter { store.canPlaceAquarium(at: $0) }
            let coord = try #require(free.first)
            let empty = try #require(free.dropFirst().first)
            store.placeAquarium(FurnitureAquarium(position: .left, orientation: .eastWest), at: coord)

            store.snapshotForUndo()
            store.updateAquarium(FurnitureAquarium(position: .right, orientation: .northSouth), at: coord)
            #expect(store.aquariums[coord] == FurnitureAquarium(position: .right, orientation: .northSouth))
            store.undo()
            #expect(store.aquariums[coord] == FurnitureAquarium(position: .left, orientation: .eastWest))

            store.snapshotForUndo()
            store.removeAquarium(at: coord)
            #expect(store.aquariums[coord] == nil)
            #expect(store.canPlaceTable(at: coord))
            store.undo()
            #expect(store.aquariums[coord] == FurnitureAquarium(position: .left, orientation: .eastWest))

            store.snapshotForUndo()
            store.placeAquarium(FurnitureAquarium(), at: empty)
            #expect(store.aquariums[empty] != nil)
            store.undo()
            #expect(store.aquariums[empty] == nil)
        }
    }

    @Test func aquariumsRoundTripAndLegacyRecordsLoadWithoutMigration() throws {
        try withIsolatedPersistence { url in
            let store = MazeStore()
            store.switchTo(id: 2)
            let coord = try #require(store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.first { store.canPlaceAquarium(at: $0) })
            let aquarium = FurnitureAquarium(position: .right, orientation: .eastWest)
            store.placeAquarium(aquarium, at: coord)
            store.saveCurrentFloorAsOverride()

            let restarted = MazeStore() // app relaunch
            restarted.switchTo(id: 2)
            #expect(restarted.aquariums[coord] == aquarium) // RIGHT + axis persisted
            restarted.switchTo(id: 3) // floor switch
            #expect(restarted.aquariums[coord] != aquarium)
            restarted.switchTo(id: 2)
            #expect(restarted.aquariums[coord] == aquarium)

            var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            for index in records.indices { records[index].removeValue(forKey: "aquariums") }
            try JSONSerialization.data(withJSONObject: records).write(to: url, options: .atomic)
            let legacy = MazeStore()
            legacy.switchTo(id: 2)
            #expect(!legacy.cells.isEmpty)
            #expect(legacy.aquariums.isEmpty)
        }
    }

    @Test func decoratorAddEditDeleteLeavesNoOrphanNodesLightsOrAnimations() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let coord = try #require(store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.first { store.canPlaceAquarium(at: $0) })
            let scene = SCNScene()
            let hallwayRoot = SCNNode()
            hallwayRoot.name = "hallwaySceneRoot"
            scene.rootNode.addChildNode(hallwayRoot)
            let state = DecoratorState()
            state.attach(scene: scene, store: store)
            state.enabled = true
            state.currentPlayerCell = { coord }
            state.currentPlayerFacing = { .north }

            func counts() -> (roots: Int, lights: Int, animated: Int) {
                var roots = 0, lights = 0, animated = 0
                scene.rootNode.enumerateHierarchy { n, _ in
                    if n.name == "furnitureAquarium" { roots += 1 }
                    if n.light != nil { lights += 1 }
                    if !n.actionKeys.isEmpty { animated += 1 }
                }
                return (roots, lights, animated)
            }

            #expect(state.canAddFloorObjectAtCurrentCell(.aquarium))
            state.addFloorObject(.aquarium)
            #expect(store.aquariums[coord] != nil)
            #expect(store.objects[coord] == nil)
            #expect(state.selection?.kind == .aquarium)
            #expect(!state.canAddFloorObjectAtCurrentCell(.aquarium))
            #expect(!state.canAddFloorObjectAtCurrentCell(.table))
            #expect(!state.canAddFloorObjectAtCurrentCell(.floorLamp))
            let initial = counts()
            #expect(initial.roots == 1 && initial.lights == 1 && initial.animated > 0)

            // Side and axis edits rebuild in place: still exactly one of everything.
            let other: FloorPosition = store.aquariums[coord]?.position == .left ? .right : .left
            state.changeAquariumPosition(other)
            #expect(store.aquariums[coord]?.position == other)
            state.changeAquariumOrientation(store.aquariums[coord]?.orientation == .northSouth ? .eastWest : .northSouth)
            let edited = counts()
            #expect(edited.roots == 1 && edited.lights == 1 && edited.animated == initial.animated)
            store.undo()
            #expect(store.aquariums[coord]?.position == other)

            state.deleteAquarium()
            #expect(store.aquariums[coord] == nil)
            #expect(state.selection == nil)
            let gone = counts()
            #expect(gone.roots == 0 && gone.lights == 0 && gone.animated == 0)
        }
    }
}
