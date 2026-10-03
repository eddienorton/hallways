import Testing
import SceneKit
@testable import Hallways

/// Sept 28 (fifth furniture object): the Floor Lamp and its local light.
@MainActor
@Suite(.serialized)
struct FloorLampFurnitureTests {
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

    private func lights(in node: SCNNode) -> [SCNLight] {
        var found: [SCNLight] = []
        node.enumerateHierarchy { n, _ in if let l = n.light { found.append(l) } }
        return found
    }

    @Test func lampHasExactlyOneLocalLightOnlyWhenOnAndSitsByTheWall() throws {
        let cellSize: CGFloat = 3.52
        let coord = GridCoordinate(row: 5, col: 5)
        let cells = Set((4...6).map { GridCoordinate(row: $0, col: 5) })
        for (isOn, position) in [(true, FloorPosition.left), (false, .right)] {
            let result = HallwayScene.build(fromMaze: cells, cellSize: cellSize, wallHeight: 3, floorNumber: 2,
                playerStart: GridCoordinate(row: 4, col: 5), playerEnd: GridCoordinate(row: 6, col: 5),
                floorLamps: [coord: FurnitureFloorLamp(position: position, orientation: .northSouth, isOn: isOn)])
            let lamp = try #require(result.scene.rootNode.childNode(withName: "furnitureFloorLamp", recursively: true))
            #expect(result.objectNodes.isEmpty)
            #expect(DecoratorTarget.read(lamp)?.kind == .floorLamp)
            let lampLights = lights(in: lamp)
            #expect(lampLights.count == (isOn ? 1 : 0))
            if let light = lampLights.first {
                #expect(light.type == .omni)
                #expect(light.intensity > 0 && light.intensity < 300)
                #expect(light.attenuationEndDistance <= cellSize * 1.5) // local, not building-wide
            }
            // Beside the wall, shade clear of the wall face.
            let across = lamp.position.x - Float(CGFloat(coord.col) * cellSize)
            #expect(position == .left ? across < -1.2 : across > 1.2)
            #expect(abs(across) + Float(HallwayScene.floorLampShadeBottomRadius) < Float(cellSize / 2) - 0.05)
            // Every part resolves to the lamp for taps.
            lamp.enumerateHierarchy { n, _ in #expect(HallwayScene.floorLampCoordinate(for: n) == coord) }
        }
    }

    @Test func placementPersistenceUndoAndCoexistence() throws {
        try withIsolatedPersistence { url in
            let store = MazeStore()
            store.switchTo(id: 2)
            let free = store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.filter { store.canPlaceFloorLamp(at: $0) && store.canPlaceDesk(at: $0) }
            let lampCell = try #require(free.first)
            let deskCell = try #require(free.dropFirst().first)
            let fireCell = try #require(free.dropFirst(2).first)

            // Add, never a pickup.
            let lamp = FurnitureFloorLamp(position: .right, orientation: .eastWest, isOn: false)
            store.placeFloorLamp(lamp, at: lampCell)
            #expect(store.floorLamps[lampCell] == lamp)
            #expect(store.objects[lampCell] == nil)
            #expect(!store.canPlaceFloorLamp(at: lampCell)) // one per cell
            // Existing furniture stays out of a lamp's cell (conservative).
            #expect(!store.canPlaceTable(at: lampCell) && !store.canPlaceDesk(at: lampCell))
            #expect(!store.canPlaceWaterCooler(at: lampCell) && !store.canPlaceOfficeChair(at: lampCell))

            // Desk + Chair still coexist; a lamp may join only on the other side.
            store.placeDesk(FurnitureDesk(position: .left, orientation: .northSouth), at: deskCell)
            store.placeOfficeChair(FurnitureOfficeChair(position: .left, orientation: .northSouth), at: deskCell)
            #expect(store.desks[deskCell] != nil && store.officeChairs[deskCell] != nil)
            #expect(!store.canPlaceFloorLamp(at: deskCell, side: .left))
            #expect(store.canPlaceFloorLamp(at: deskCell, side: .right))
            store.placeFloorLamp(FurnitureFloorLamp(position: .left, orientation: .northSouth), at: deskCell)
            #expect(store.floorLamps[deskCell] == nil)
            store.placeFloorLamp(FurnitureFloorLamp(position: .right, orientation: .northSouth), at: deskCell)
            #expect(store.floorLamps[deskCell] != nil)
            #expect(store.desks[deskCell] != nil && store.officeChairs[deskCell] != nil)
            store.updateFloorLamp(FurnitureFloorLamp(position: .left, orientation: .northSouth), at: deskCell)
            #expect(store.floorLamps[deskCell]?.position == .right) // can't move onto the desk's side

            // Fire and pickups block it.
            store.placeFire(at: fireCell)
            #expect(!store.canPlaceFloorLamp(at: fireCell))
            if let pickupCell = store.cells.first(where: { store.objects[$0] != nil }) {
                #expect(!store.canPlaceFloorLamp(at: pickupCell))
            }

            // Undo: ON/OFF, position, delete, add.
            store.snapshotForUndo()
            store.updateFloorLamp(FurnitureFloorLamp(position: .right, orientation: .eastWest, isOn: true), at: lampCell)
            #expect(store.floorLamps[lampCell]?.isOn == true)
            store.undo()
            #expect(store.floorLamps[lampCell] == lamp)
            store.snapshotForUndo()
            store.updateFloorLamp(FurnitureFloorLamp(position: .left, orientation: .eastWest, isOn: false), at: lampCell)
            store.undo()
            #expect(store.floorLamps[lampCell]?.position == .right)
            store.snapshotForUndo()
            store.removeFloorLamp(at: lampCell)
            #expect(store.floorLamps[lampCell] == nil)
            store.undo()
            #expect(store.floorLamps[lampCell] == lamp)
            let emptyCell = try #require(free.dropFirst(3).first)
            store.snapshotForUndo()
            store.placeFloorLamp(FurnitureFloorLamp(), at: emptyCell)
            store.undo()
            #expect(store.floorLamps[emptyCell] == nil)

            // Persistence: position, axis, ON/OFF survive relaunch and floor switch.
            store.saveCurrentFloorAsOverride()
            let restarted = MazeStore()
            restarted.switchTo(id: 2)
            #expect(restarted.floorLamps[lampCell] == lamp)
            #expect(restarted.floorLamps[deskCell]?.position == .right)
            restarted.switchTo(id: 3)
            #expect(restarted.floorLamps[lampCell] != lamp)
            restarted.switchTo(id: 2)
            #expect(restarted.floorLamps[lampCell] == lamp)

            // Old records with no lamp key still load.
            var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            for index in records.indices { records[index].removeValue(forKey: "floorLamps") }
            try JSONSerialization.data(withJSONObject: records).write(to: url, options: .atomic)
            let legacy = MazeStore()
            legacy.switchTo(id: 2)
            #expect(!legacy.cells.isEmpty && legacy.floorLamps.isEmpty)

            // Closing the cell removes it.
            store.setClosed(lampCell)
            #expect(store.floorLamps[lampCell] == nil)
        }
    }

    @Test func playToggleAndDecoratorEditsNeverDuplicateTheLight() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 2)
            let coord = try #require(store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.first { store.canPlaceFloorLamp(at: $0) })
            let scene = SCNScene()
            let hallwayRoot = SCNNode()
            hallwayRoot.name = "hallwaySceneRoot"
            scene.rootNode.addChildNode(hallwayRoot)
            let state = DecoratorState()
            state.attach(scene: scene, store: store)
            state.enabled = true
            state.currentPlayerCell = { coord }
            state.currentPlayerFacing = { .north }

            func lampLights() -> Int {
                var count = 0
                scene.rootNode.enumerateHierarchy { n, _ in
                    if n.light != nil, HallwayScene.floorLampCoordinate(for: n) != nil { count += 1 }
                }
                return count
            }
            func lampNodes() -> Int { scene.rootNode.childNodes(passingTest: { n, _ in n.name == "furnitureFloorLamp" }).count }

            state.addFloorObject(.floorLamp)
            #expect(store.floorLamps[coord]?.isOn == true) // new lamps start ON
            #expect(lampNodes() == 1 && lampLights() == 1)
            state.setFloorLampOn(false)
            #expect(lampNodes() == 1 && lampLights() == 0)
            state.setFloorLampOn(true)
            state.changeFloorLampOrientation(.eastWest)
            #expect(lampNodes() == 1 && lampLights() == 1)

            // Play mode: tap toggles, persists, still exactly one lamp.
            state.enabled = false
            #expect(state.toggleFloorLamp(at: coord))
            #expect(store.floorLamps[coord]?.isOn == false)
            #expect(lampNodes() == 1 && lampLights() == 0)
            #expect(state.toggleFloorLamp(at: coord))
            #expect(lampNodes() == 1 && lampLights() == 1)

            // Delete removes the node and its light.
            state.enabled = true
            state.selection = DecoratorTarget(floor: store.currentMazeID, coord: coord, kind: .floorLamp)
            state.deleteFloorLamp()
            #expect(store.floorLamps[coord] == nil)
            #expect(lampNodes() == 0 && lampLights() == 0)
        }
    }

    @Test func brightnessMapsPersistsUndoesAndSurvivesOnOff() throws {
        // Calibrated mapping (on the first-pass scale of 190 x [0.25, 0.5, 1, 1.5, 2]):
        // UI 1 = 25% of old level 1, UI 5 = old "3.5", evenly between.
        let expected: [CGFloat] = [11.875, 50.46875, 89.0625, 160.3125, 237.5]
        for (level, value) in zip(FurnitureFloorLamp.brightnessRange, expected) {
            #expect(abs(HallwayScene.floorLampIntensity(brightness: level) - value) < 0.001)
        }
        #expect(HallwayScene.floorLampIntensity(brightness: 5) < 190 * 2.0) // not the old level 5 (380)
        #expect(HallwayScene.floorLampIntensity(brightness: 1) <= 190 * 0.25 / 4 + 0.001) // quarter of old level 1
        let levels = FurnitureFloorLamp.brightnessRange.map { HallwayScene.floorLampIntensity(brightness: $0) }
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 < $1 })
        #expect(FurnitureFloorLamp(brightness: 99).sanitized.brightness == FurnitureFloorLamp.brightnessRange.upperBound)
        #expect(FurnitureFloorLamp(brightness: -4).sanitized.brightness == FurnitureFloorLamp.brightnessRange.lowerBound)

        try withIsolatedPersistence { url in
            let store = MazeStore()
            store.switchTo(id: 2)
            let coord = try #require(store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.first { store.canPlaceFloorLamp(at: $0) })
            let scene = SCNScene()
            let hallwayRoot = SCNNode()
            hallwayRoot.name = "hallwaySceneRoot"
            scene.rootNode.addChildNode(hallwayRoot)
            let state = DecoratorState()
            state.attach(scene: scene, store: store)
            state.enabled = true
            state.currentPlayerCell = { coord }
            state.currentPlayerFacing = { .north }
            func liveIntensity() -> CGFloat? {
                var found: CGFloat?
                scene.rootNode.enumerateHierarchy { n, _ in
                    if let l = n.light, HallwayScene.floorLampCoordinate(for: n) == coord { found = l.intensity }
                }
                return found
            }

            state.addFloorObject(.floorLamp)
            #expect(store.floorLamps[coord]?.brightness == 3)
            #expect(liveIntensity() == HallwayScene.floorLampIntensity(brightness: 3))
            // Live edit, undoable.
            state.changeFloorLampBrightness(by: -2)
            #expect(store.floorLamps[coord]?.brightness == 1)
            #expect(liveIntensity() == HallwayScene.floorLampIntensity(brightness: 1))
            state.changeFloorLampBrightness(by: -1) // already at the bottom: no-op
            #expect(store.floorLamps[coord]?.brightness == 1)
            store.undo()
            #expect(store.floorLamps[coord]?.brightness == 3)
            state.changeFloorLampBrightness(by: -1)
            #expect(store.floorLamps[coord]?.brightness == 2)

            // OFF is dark regardless of brightness; ON restores it.
            #expect(state.toggleFloorLamp(at: coord))
            #expect(liveIntensity() == nil && store.floorLamps[coord]?.brightness == 2)
            #expect(state.toggleFloorLamp(at: coord))
            #expect(liveIntensity() == HallwayScene.floorLampIntensity(brightness: 2))

            // Save / relaunch / rebuild keeps it.
            let restarted = MazeStore()
            restarted.switchTo(id: 2)
            #expect(restarted.floorLamps[coord]?.brightness == 2)
            let rebuilt = HallwayScene.buildFloorLampNode(at: coord, cellSize: restarted.cellSize, floorNumber: 2, lamp: try #require(restarted.floorLamps[coord]))
            var rebuiltIntensity: CGFloat?
            rebuilt.enumerateHierarchy { n, _ in if let l = n.light { rebuiltIntensity = l.intensity } }
            #expect(rebuiltIntensity == HallwayScene.floorLampIntensity(brightness: 2))

            // A lamp saved before brightness existed loads at the default (today's look).
            var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            for index in records.indices {
                if var lamps = records[index]["floorLamps"] as? [[String: Any]] {
                    for i in lamps.indices { lamps[i].removeValue(forKey: "brightness") }
                    records[index]["floorLamps"] = lamps
                }
            }
            try JSONSerialization.data(withJSONObject: records).write(to: url, options: .atomic)
            let legacy = MazeStore()
            legacy.switchTo(id: 2)
            #expect(legacy.floorLamps[coord]?.brightness == FurnitureFloorLamp.defaultBrightness)
            #expect(legacy.floorLamps[coord]?.isOn == true)
        }
    }
}
