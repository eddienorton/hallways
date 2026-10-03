import Testing
import SceneKit
@testable import Hallways

/// Sept 28 (seventh furniture object): the Filing Cabinet and its drawers.
@MainActor
@Suite(.serialized)
struct FilingCabinetFurnitureTests {
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

    private func drawer(_ index: Int, of cabinet: SCNNode) throws -> SCNNode {
        try #require(cabinet.childNode(withName: HallwayScene.filingCabinetDrawerNames[index], recursively: false))
    }

    /// A scene the DecoratorState can edit, with the player standing on `coord`.
    private func decorator(for store: MazeStore, at coord: GridCoordinate) -> (DecoratorState, SCNScene) {
        let scene = SCNScene()
        let hallwayRoot = SCNNode()
        hallwayRoot.name = "hallwaySceneRoot"
        scene.rootNode.addChildNode(hallwayRoot)
        let state = DecoratorState()
        state.attach(scene: scene, store: store)
        state.enabled = true
        state.currentPlayerCell = { coord }
        state.currentPlayerFacing = { .north }
        return (state, scene)
    }

    @Test func cabinetRendersAgainstTheWallFacingTheCenterInEveryOrientation() throws {
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
                filingCabinets: [coord: FurnitureFilingCabinet(position: position, orientation: orientation, openDrawerIndex: 1)])
            let cabinet = try #require(result.scene.rootNode.childNode(withName: "furnitureFilingCabinet", recursively: true))
            #expect(DecoratorTarget.read(cabinet)?.kind == .filingCabinet)
            #expect(result.objectNodes.isEmpty) // never a pickup
            let dx = cabinet.position.x - center.x
            let dz = cabinet.position.z - center.z
            let across = orientation == .northSouth ? dx : dz
            let along = orientation == .northSouth ? dz : dx
            #expect(abs(along) < 0.001)
            #expect(position == .left ? across < -1.2 : across > 1.2)
            // Drawer fronts (local +z) face the cell center.
            let front = cabinet.convertVector(SCNVector3(0, 0, 1), to: nil)
            let frontAcross = orientation == .northSouth ? front.x : front.z
            #expect(position == .left ? frontAcross > 0.99 : frontAcross < -0.99)
            // Back inside the wall face; even an OPEN drawer leaves the center line clear.
            #expect(abs(across) + Float(HallwayScene.filingCabinetDepth / 2) < Float(cellSize / 2) - 0.05)
            #expect(abs(across) - Float(HallwayScene.filingCabinetDepth / 2) - Float(HallwayScene.filingCabinetDrawerTravel) > 0.5)
            // Built straight from persisted state: drawer 1 open, the others closed.
            for index in 0..<FurnitureFilingCabinet.drawerCount {
                let expected = HallwayScene.filingCabinetDrawerPosition(index: index, open: index == 1)
                let actual = try drawer(index, of: cabinet).position
                #expect(SCNVector3EqualToVector3(actual, expected))
            }
        }
    }

    @Test func dimensionsAndDrawerHierarchyAndHitResolution() throws {
        #expect(HallwayScene.filingCabinetWidth >= 0.45 && HallwayScene.filingCabinetWidth <= 0.55)
        #expect(HallwayScene.filingCabinetDepth >= 0.55 && HallwayScene.filingCabinetDepth <= 0.65)
        #expect(HallwayScene.filingCabinetHeight >= 1.2 && HallwayScene.filingCabinetHeight <= 1.4)
        let coord = GridCoordinate(row: 1, col: 1)
        let node = HallwayScene.buildFilingCabinetNode(at: coord, cellSize: 3.52, floorNumber: 2, cabinet: FurnitureFilingCabinet())
        #expect(node.name == "furnitureFilingCabinet")
        #expect(DecoratorTarget.read(node)?.kind == .filingCabinet)
        var tagged = 0
        node.enumerateChildNodes { child, _ in if DecoratorTarget.read(child) != nil { tagged += 1 } }
        #expect(tagged == 0) // only the root is tagged -> Decorate selects the WHOLE cabinet
        // Drawers top (0) to bottom (2), each a real box: front + pull + label + 5 box panels.
        var lastY = Float.greatestFiniteMagnitude
        for index in 0..<FurnitureFilingCabinet.drawerCount {
            let d = try drawer(index, of: node)
            #expect(d.position.y < lastY)
            lastY = d.position.y
            #expect(d.childNodes.count >= 8)
            // Every descendant of a drawer resolves to (cabinet, that drawer).
            d.enumerateChildNodes { child, _ in
                let hit = HallwayScene.filingCabinetHit(for: child)
                #expect(hit?.coord == coord && hit?.drawerIndex == index)
            }
        }
        // The carcass resolves to the cabinet with no drawer.
        let shell = try #require(node.childNode(withName: "furnitureFilingCabinetShell", recursively: false))
        for child in shell.childNodes {
            let hit = HallwayScene.filingCabinetHit(for: child)
            #expect(hit?.coord == coord && hit?.drawerIndex == nil)
        }
        // Other furniture never resolves as a filing cabinet.
        let aquarium = HallwayScene.buildAquariumNode(at: coord, cellSize: 3.52, floorNumber: 2, aquarium: FurnitureAquarium())
        #expect(HallwayScene.filingCabinetHit(for: aquarium.childNodes[0]) == nil)
    }

    @Test func drawerTransformsAreFixedAndNeverAccumulate() throws {
        let node = HallwayScene.buildFilingCabinetNode(at: GridCoordinate(row: 1, col: 1), cellSize: 3.52, floorNumber: 2,
                                                       cabinet: FurnitureFilingCabinet())
        for index in 0..<FurnitureFilingCabinet.drawerCount {
            let closed = HallwayScene.filingCabinetDrawerPosition(index: index, open: false)
            let open = HallwayScene.filingCabinetDrawerPosition(index: index, open: true)
            #expect(abs(open.z - closed.z - Float(HallwayScene.filingCabinetDrawerTravel)) < 0.0001)
            #expect(open.x == closed.x && open.y == closed.y)
        }
        // Hammer the same state many times: positions never drift.
        for _ in 0..<25 { HallwayScene.setFilingCabinetDrawers(node, openDrawerIndex: 2, animated: false) }
        for index in 0..<FurnitureFilingCabinet.drawerCount {
            let actual = try drawer(index, of: node).position
            #expect(SCNVector3EqualToVector3(actual, HallwayScene.filingCabinetDrawerPosition(index: index, open: index == 2)))
        }
        // Animated requests are absolute moves that replace each other (one action per drawer, max).
        for open in [0, 1, 0, nil, 2, 2] as [Int?] { HallwayScene.setFilingCabinetDrawers(node, openDrawerIndex: open, animated: true) }
        for index in 0..<FurnitureFilingCabinet.drawerCount {
            let keys = try drawer(index, of: node).actionKeys
            #expect(keys.count <= 1)
        }
        // Snapping afterwards lands exactly on the fixed transforms.
        HallwayScene.setFilingCabinetDrawers(node, openDrawerIndex: nil, animated: false)
        for index in 0..<FurnitureFilingCabinet.drawerCount {
            let d = try drawer(index, of: node)
            #expect(d.actionKeys.isEmpty)
            #expect(SCNVector3EqualToVector3(d.position, HallwayScene.filingCabinetDrawerPosition(index: index, open: false)))
        }
    }

    @Test func playTapsKeepAtMostOneDrawerOpen() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let coord = try #require(store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.first { store.canPlaceFilingCabinet(at: $0) })
            let (state, scene) = decorator(for: store, at: coord)
            state.addFloorObject(.filingCabinet)
            #expect(store.filingCabinets[coord]?.openDrawerIndex == nil) // new cabinets start closed
            state.enabled = false // Play

            #expect(state.tapFilingCabinetDrawer(0, at: coord))
            #expect(store.filingCabinets[coord]?.openDrawerIndex == 0)
            #expect(state.tapFilingCabinetDrawer(2, at: coord)) // switching: 0 closes, 2 opens
            #expect(store.filingCabinets[coord]?.openDrawerIndex == 2)
            #expect(state.tapFilingCabinetDrawer(2, at: coord)) // tapping the open one closes it
            #expect(store.filingCabinets[coord]?.openDrawerIndex == nil)
            #expect(!state.tapFilingCabinetDrawer(3, at: coord)) // no such drawer
            #expect(!state.tapFilingCabinetDrawer(0, at: GridCoordinate(row: -99, col: -99)))

            // Live drawers are heading to (at most) one open position.
            state.tapFilingCabinetDrawer(1, at: coord)
            let cabinet = try #require(scene.rootNode.childNode(withName: "furnitureFilingCabinet", recursively: true))
            HallwayScene.setFilingCabinetDrawers(cabinet, openDrawerIndex: store.filingCabinets[coord]?.openDrawerIndex, animated: false)
            let open = try (0..<FurnitureFilingCabinet.drawerCount).filter { index in
                try drawer(index, of: cabinet).position.z > 0.01
            }
            #expect(open == [1])
            // Out-of-range persisted indices mean "all closed".
            #expect(FurnitureFilingCabinet(openDrawerIndex: 7).sanitized.openDrawerIndex == nil)
            #expect(FurnitureFilingCabinet(openDrawerIndex: -1).sanitized.openDrawerIndex == nil)
        }
    }

    @Test func occupancyIsExclusiveAndDeskChairPairingStillWorks() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let free = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
                .filter { store.canPlaceFilingCabinet(at: $0) && store.canPlaceDesk(at: $0) && store.canPlaceOfficeChair(at: $0) }
            let cabinetCell = try #require(free.first)
            let aquariumCell = try #require(free.dropFirst().first)
            let lampCell = try #require(free.dropFirst(2).first)
            let pairCell = try #require(free.dropFirst(3).first)
            let fireCell = try #require(free.dropFirst(4).first)

            store.placeFilingCabinet(FurnitureFilingCabinet(position: .center, orientation: .eastWest), at: cabinetCell)
            #expect(store.filingCabinets[cabinetCell] == FurnitureFilingCabinet(position: .left, orientation: .eastWest)) // no CENTER
            #expect(store.objects[cabinetCell] == nil)
            #expect(!store.canPlaceFilingCabinet(at: cabinetCell))
            #expect(!store.canPlaceTable(at: cabinetCell))
            #expect(!store.canPlaceDesk(at: cabinetCell))
            #expect(!store.canPlaceWaterCooler(at: cabinetCell))
            #expect(!store.canPlaceOfficeChair(at: cabinetCell))
            #expect(!store.canPlaceFloorLamp(at: cabinetCell))
            #expect(!store.canPlaceFloorLamp(at: cabinetCell, side: .right))
            #expect(!store.canPlaceAquarium(at: cabinetCell))

            store.placeAquarium(FurnitureAquarium(), at: aquariumCell)
            #expect(!store.canPlaceFilingCabinet(at: aquariumCell))
            store.placeFloorLamp(FurnitureFloorLamp(), at: lampCell)
            #expect(!store.canPlaceFilingCabinet(at: lampCell))
            store.placeFire(at: fireCell)
            #expect(!store.canPlaceFilingCabinet(at: fireCell))
            if let pickupCell = store.cells.first(where: { store.objects[$0] != nil }) {
                #expect(!store.canPlaceFilingCabinet(at: pickupCell))
            }

            // Desk + Chair exception untouched.
            store.placeDesk(FurnitureDesk(position: .right, orientation: .northSouth), at: pairCell)
            store.placeOfficeChair(FurnitureOfficeChair(position: .right, orientation: .northSouth), at: pairCell)
            #expect(store.desks[pairCell] != nil && store.officeChairs[pairCell] != nil)
            #expect(!store.canPlaceFilingCabinet(at: pairCell))

            store.setClosed(cabinetCell)
            #expect(store.filingCabinets[cabinetCell] == nil)
        }
    }

    @Test func decoratorEditsAreUndoableAndDeleteLeavesNothingBehind() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let coord = try #require(store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.first { store.canPlaceFilingCabinet(at: $0) })
            let (state, scene) = decorator(for: store, at: coord)
            func cabinetCount() -> Int {
                var count = 0
                scene.rootNode.enumerateHierarchy { n, _ in if n.name == "furnitureFilingCabinet" { count += 1 } }
                return count
            }
            func actionCount() -> Int {
                var count = 0
                scene.rootNode.enumerateHierarchy { n, _ in count += n.actionKeys.count }
                return count
            }

            #expect(state.canAddFloorObjectAtCurrentCell(.filingCabinet))
            state.addFloorObject(.filingCabinet)
            #expect(store.filingCabinets[coord] != nil && store.objects[coord] == nil)
            #expect(state.selection?.kind == .filingCabinet)
            #expect(!state.canAddFloorObjectAtCurrentCell(.filingCabinet))
            #expect(!state.canAddFloorObjectAtCurrentCell(.aquarium))
            #expect(cabinetCount() == 1)
            let original = try #require(store.filingCabinets[coord])

            // Open a drawer in Play, then edit in Decorate: the drawer stays open.
            state.enabled = false
            state.tapFilingCabinetDrawer(1, at: coord)
            state.enabled = true
            let other: FloorPosition = original.position == .left ? .right : .left
            state.changeFilingCabinetPosition(other)
            #expect(store.filingCabinets[coord]?.position == other)
            #expect(store.filingCabinets[coord]?.openDrawerIndex == 1)
            state.changeFilingCabinetOrientation(original.orientation == .northSouth ? .eastWest : .northSouth)
            #expect(cabinetCount() == 1)
            store.undo()
            #expect(store.filingCabinets[coord]?.orientation == original.orientation)
            store.undo()
            #expect(store.filingCabinets[coord]?.position == original.position)

            // Delete with a slide in flight: nothing survives.
            state.enabled = false
            state.tapFilingCabinetDrawer(2, at: coord)
            state.enabled = true
            state.deleteFilingCabinet()
            #expect(store.filingCabinets[coord] == nil)
            #expect(state.selection == nil)
            #expect(cabinetCount() == 0)
            #expect(actionCount() == 0)
            store.undo()
            #expect(store.filingCabinets[coord] != nil)

            // Undo of the add itself.
            store.removeFilingCabinet(at: coord)
            store.snapshotForUndo()
            store.placeFilingCabinet(FurnitureFilingCabinet(), at: coord)
            store.undo()
            #expect(store.filingCabinets[coord] == nil)
        }
    }

    @Test func stateRoundTripsAndLegacyRecordsLoadAllClosed() throws {
        try withIsolatedPersistence { url in
            let store = MazeStore()
            store.switchTo(id: 2)
            let free = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.filter { store.canPlaceFilingCabinet(at: $0) }
            let coord = try #require(free.first)
            let closedCoord = try #require(free.dropFirst().first)
            let cabinet = FurnitureFilingCabinet(position: .right, orientation: .eastWest, openDrawerIndex: 2)
            store.placeFilingCabinet(cabinet, at: coord)
            store.placeFilingCabinet(FurnitureFilingCabinet(), at: closedCoord)
            store.saveCurrentFloorAsOverride()

            let restarted = MazeStore() // relaunch
            restarted.switchTo(id: 2)
            #expect(restarted.filingCabinets[coord] == cabinet) // side, axis, open drawer
            #expect(restarted.filingCabinets[closedCoord]?.openDrawerIndex == nil)
            restarted.switchTo(id: 3) // floor switch
            #expect(restarted.filingCabinets[coord] != cabinet)
            restarted.switchTo(id: 2)
            #expect(restarted.filingCabinets[coord] == cabinet)
            // A rebuilt scene opens exactly the persisted drawer.
            let persisted = try #require(restarted.filingCabinets[coord])
            let node = HallwayScene.buildFilingCabinetNode(at: coord, cellSize: restarted.cellSize, floorNumber: 2, cabinet: persisted)
            let reopened = try drawer(2, of: node).position
            #expect(SCNVector3EqualToVector3(reopened, HallwayScene.filingCabinetDrawerPosition(index: 2, open: true)))
            #expect(node.childNodes.allSatisfy { $0.actionKeys.isEmpty })

            // Old JSON: no openDrawerIndex field -> all closed; no filingCabinets key -> none.
            var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            for index in records.indices {
                if var cabinets = records[index]["filingCabinets"] as? [[String: Any]] {
                    for c in cabinets.indices { cabinets[c].removeValue(forKey: "openDrawerIndex") }
                    records[index]["filingCabinets"] = cabinets
                }
            }
            try JSONSerialization.data(withJSONObject: records).write(to: url, options: .atomic)
            let noField = MazeStore()
            noField.switchTo(id: 2)
            #expect(noField.filingCabinets[coord] == FurnitureFilingCabinet(position: .right, orientation: .eastWest))
            #expect(noField.filingCabinets[coord]?.openDrawerIndex == nil)

            for index in records.indices { records[index].removeValue(forKey: "filingCabinets") }
            try JSONSerialization.data(withJSONObject: records).write(to: url, options: .atomic)
            let legacy = MazeStore()
            legacy.switchTo(id: 2)
            #expect(!legacy.cells.isEmpty)
            #expect(legacy.filingCabinets.isEmpty)
        }
    }
}
