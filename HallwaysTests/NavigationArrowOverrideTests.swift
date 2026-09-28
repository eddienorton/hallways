import Testing
import SceneKit
@testable import Hallways

@MainActor
@Suite(.serialized)
struct NavigationArrowOverrideTests {
    @Test func originalIntersectionRulesAndLiveVisibility() throws {
        let cells = Set((4...6).flatMap { row in (4...6).map { GridCoordinate(row: row, col: $0) } })
        let center = GridCoordinate(row: 5, col: 5)
        let edge = GridCoordinate(row: 4, col: 5)
        let corner = GridCoordinate(row: 4, col: 4)
        let result = HallwayScene.build(fromMaze: cells, cellSize: 3.2, wallHeight: 3,
                                       floorNumber: 2, playerStart: center, playerEnd: corner)
        let marker = try #require(result.scene.rootNode.childNode(withName: HallwayScene.navigationArrowNodeName(at: center), recursively: true))
        let other = try #require(result.scene.rootNode.childNode(withName: HallwayScene.navigationArrowNodeName(at: edge), recursively: true))
        #expect(marker.childNodes.count == 8) // Four shafts and four heads.
        #expect(other.childNodes.count == 6) // Three open sides.
        #expect(result.scene.rootNode.childNode(withName: HallwayScene.navigationArrowNodeName(at: corner), recursively: true) == nil)
        #expect(!marker.isHidden && !other.isHidden)
        let cameraPosition = result.cameraNode.position
        let controller = TapNavigationController(cameraNode: result.cameraNode, scene: result.scene,
            cells: cells, cellSize: 3.2, startCell: center, startFacing: .north, endCell: corner)
        let directions = controller.openDirections
        HallwayScene.setNavigationArrowsHidden(true, at: center, in: result.scene)
        #expect(marker.isHidden && !other.isHidden)
        #expect(controller.openDirections == directions)
        #expect(SCNVector3EqualToVector3(cameraPosition, result.cameraNode.position))
        HallwayScene.setNavigationArrowsHidden(false, at: center, in: result.scene)
        #expect(!marker.isHidden && marker.childNodes.count == 8)
        HallwayScene.setNavigationArrowsHidden(false, at: corner, in: result.scene)
        #expect(result.scene.rootNode.childNode(withName: HallwayScene.navigationArrowNodeName(at: corner), recursively: true) == nil)
        let rebuilt = HallwayScene.build(fromMaze: cells, cellSize: 3.2, wallHeight: 3,
            floorNumber: 2, playerStart: center, playerEnd: corner, hiddenNavigationArrows: [center])
        #expect(rebuilt.scene.rootNode.childNode(withName: HallwayScene.navigationArrowNodeName(at: center), recursively: true)?.isHidden == true)
        #expect(rebuilt.scene.rootNode.childNode(withName: HallwayScene.navigationArrowNodeName(at: edge), recursively: true)?.isHidden == false)
    }

    @Test func decoratorTogglePersistsAndLegacyRecordsDefaultToEnabled() throws {
        // Isolate this test's normal persistence writes inside the simulator.
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
        let store = MazeStore()
        store.switchTo(id: 2)
        let coord = try #require(store.cells.first)
        store.setNavigationArrowsEnabled(true, at: coord)
        let scene = SCNScene()
        let marker = SCNNode()
        marker.name = HallwayScene.navigationArrowNodeName(at: coord)
        scene.rootNode.addChildNode(marker)
        let state = DecoratorState()
        state.attach(scene: scene, store: store)
        state.enabled = true
        state.currentPlayerCell = { coord }
        #expect(state.navigationArrowsEnabledAtCurrentCell)
        let cellsBefore = store.cells
        state.setNavigationArrowsEnabledAtCurrentCell(false)
        #expect(marker.isHidden && !state.navigationArrowsEnabledAtCurrentCell)
        #expect(store.cells == cellsBefore)
        let restarted = MazeStore()
        restarted.switchTo(id: 2)
        #expect(restarted.hiddenNavigationArrows.contains(coord))
        store.switchTo(id: 3)
        store.switchTo(id: 2)
        #expect(store.hiddenNavigationArrows.contains(coord))
        state.setNavigationArrowsEnabledAtCurrentCell(true)
        #expect(!marker.isHidden && state.navigationArrowsEnabledAtCurrentCell)
        #expect(!store.hiddenNavigationArrows.contains(coord))
        store.undo()
        #expect(store.hiddenNavigationArrows.contains(coord))

        // Simulate an older saved record with no new key at all.
        var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for index in records.indices { records[index].removeValue(forKey: "hiddenNavigationArrows") }
        try JSONSerialization.data(withJSONObject: records).write(to: url, options: .atomic)
        let legacy = MazeStore()
        legacy.switchTo(id: 2)
        #expect(legacy.hiddenNavigationArrows.isEmpty)
    }
}
