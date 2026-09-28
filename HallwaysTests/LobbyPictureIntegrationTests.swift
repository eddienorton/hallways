import Testing
import SceneKit
@testable import Hallways

@MainActor
@Suite(.serialized)
struct LobbyPictureIntegrationTests {
    private let faces = [
        WallFace(coord: .init(row: 13, col: 7), direction: .west),
        WallFace(coord: .init(row: 11, col: 7), direction: .west),
        WallFace(coord: .init(row: 13, col: 7), direction: .east)
    ]

    // Exercise the real persisted-record decoder without exposing private storage types.
    // These tests run in the simulator test app; preserve its pre-test file/defaults.
    private func withLegacyFloor(_ change: (inout [String: Any]) -> Void = { _ in },
                                 test: (MazeStore) throws -> Void) throws {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mazes.json")
        let oldData = try? Data(contentsOf: url)
        let defaults = UserDefaults.standard
        let keys = ["maze.savedFloorOverrideIDs", MazeStore.devStartOnLastFloorKey, MazeStore.devLastJumpedFloorKey]
        let oldDefaults = keys.map { defaults.object(forKey: $0) }
        defer {
            if let oldData { try? oldData.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
            for (key, value) in zip(keys, oldDefaults) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let bundleURL = try #require(Bundle.main.url(forResource: "DefaultMazes", withExtension: "json"))
        let records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: bundleURL)) as? [[String: Any]])
        var record = try #require(records.first { $0["id"] as? Int == 1 })
        change(&record)
        try JSONSerialization.data(withJSONObject: [record]).write(to: url)
        defaults.set([1], forKey: keys[0])
        defaults.set(false, forKey: MazeStore.devStartOnLastFloorKey)
        try test(MazeStore())
    }

    @Test func legacyDefaultsHaveOneSelectableFrameAndExactOriginalGeometry() throws {
        try withLegacyFloor { store in
            #expect(store.pictures.count == 3)
            let built = HallwayScene.build(fromMaze: store.cells, cellSize: store.cellSize, wallHeight: store.wallHeight,
                pictures: store.pictures, floorNumber: 1, playerStart: store.startCoordinate,
                playerEnd: store.endCoordinate, pictureImageSelections: store.pictureImageSelections)
            let state = DecoratorState()
            state.attach(scene: built.scene, store: store)
            state.enabled = true
            let view = SCNView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            view.scene = built.scene
            view.pointOfView = built.cameraNode
            for face in faces {
                #expect(store.pictures[face] == .lobbyOriginal)
                #expect(!store.canPlacePicture(face.direction, at: face.coord))
                let target = DecoratorTarget(floor: 1, coord: face.coord, kind: .picture, direction: face.direction)
                var frames: [SCNNode] = []
                built.scene.rootNode.enumerateChildNodes { node, _ in
                    if DecoratorTarget.read(node) == target { frames.append(node) }
                }
                #expect(frames.count == 1)
                let frame = try #require(frames.first)
                let actual = try #require(frame.geometry as? SCNBox)
                guard case .lobbyDefault(let resource) = store.pictureImageSelections[face] else {
                    Issue.record("Missing original lobby resource"); continue
                }
                let texture = HallwayScene.framedPhoto(try #require(HallwayScene.lobbyPictureImage(resource)))
                var materials: [SCNMaterial] = []
                let half = store.cellSize / 2
                let wx = CGFloat(face.coord.col) * store.cellSize + CGFloat(face.direction.delta.col) * half
                let wz = CGFloat(face.coord.row) * store.cellSize + CGFloat(face.direction.delta.row) * half
                let legacy = HallwayScene.buildPictureNode(direction: face.direction, wallCenterX: wx, wallCenterZ: wz,
                    texture: texture, backfillWall: false, scale: 1.4, coord: face.coord, floorNumber: 1,
                    cellSize: store.cellSize, wallHeight: store.wallHeight, effectiveWallImageName: "lobby-wall",
                    root: SCNNode(), wallMaterials: &materials).frameNode
                let expected = try #require(legacy.geometry as? SCNBox)
                #expect(actual.width == expected.width && actual.height == expected.height && actual.length == expected.length)
                #expect(SCNMatrix4EqualToMatrix4(frame.transform, legacy.transform))
                built.cameraNode.position = SCNVector3(Float(CGFloat(face.coord.col) * store.cellSize), 1.6, Float(CGFloat(face.coord.row) * store.cellSize))
                built.cameraNode.look(at: frame.worldPosition)
                let point = view.projectPoint(frame.worldPosition)
                #expect(state.select(at: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)), in: view))
                #expect(state.selection == target)
                let controller = TapNavigationController(cameraNode: built.cameraNode, scene: built.scene, cells: store.cells,
                    cellSize: store.cellSize, startCell: face.coord, startFacing: face.direction,
                    endCell: try #require(store.endCoordinate), floorNumber: 1, pictures: Set(store.pictures.keys))
                controller.activatePictureMenu(at: face.coord)
                #expect(controller.activePictureMenu == face)
            }
        }
    }

    @Test func contentResizeAndDeletionSurviveReloadWithoutReseeding() throws {
        try withLegacyFloor { store in
            let built = HallwayScene.build(fromMaze: store.cells, cellSize: store.cellSize, wallHeight: store.wallHeight,
                pictures: store.pictures, floorNumber: 1, pictureImageSelections: store.pictureImageSelections)
            let state = DecoratorState()
            state.attach(scene: built.scene, store: store)
            state.enabled = true
            let changed = faces[0], deleted = faces[1]
            store.setPictureImageSelection(.builtIn("chosen-test-image"), direction: changed.direction, at: changed.coord)
            state.selection = .init(floor: 1, coord: changed.coord, kind: .picture, direction: changed.direction)
            state.changePictureSize(.poster)
            state.selection = .init(floor: 1, coord: deleted.coord, kind: .picture, direction: deleted.direction)
            state.deletePicture()
            #expect(store.pictures[deleted] == nil)
            #expect(store.canPlacePicture(deleted.direction, at: deleted.coord))
            let wall = DecoratorTarget(floor: 1, coord: deleted.coord, kind: .wallSurface, direction: deleted.direction)
            var wallCount = 0
            built.scene.rootNode.enumerateChildNodes { node, _ in
                if DecoratorTarget.read(node) == wall { wallCount += 1 }
                #expect(DecoratorTarget.read(node) != .init(floor: 1, coord: deleted.coord, kind: .picture, direction: deleted.direction))
            }
            #expect(wallCount == 1)
            let reloaded = MazeStore()
            #expect(reloaded.pictures[deleted] == nil)
            #expect(reloaded.pictures[changed] == .poster)
            #expect(reloaded.pictureImageSelections[changed] == .builtIn("chosen-test-image"))
            for face in faces where face != deleted { reloaded.removePicture(face.direction, at: face.coord) }
            reloaded.saveCurrentFloorAsOverride()
            #expect(MazeStore().pictures.isEmpty)
        }
    }

    @Test func legacyOverrideRetainsExistingAuthoredContentAndUnrelatedData() throws {
        try withLegacyFloor({ record in
            record["pictures"] = [["coord": ["row": 13, "col": 7], "direction": "west", "size": "poster"]]
            record["pictureImageSelections"] = [["coord": ["row": 13, "col": 7], "selection": ["cameraRoll": ["_0": "existing-photo"]]]]
            record["mirrors"] = [["coord": ["row": 11, "col": 7], "direction": "west"]]
            record["wallTexture"] = "retained-wall"
            record["missionHeading"] = "Retained mission"
        }, test: { store in
            #expect(store.pictures.count == 2)
            #expect(store.pictures[faces[0]] == .poster)
            #expect(store.pictureImageSelections[faces[0]] == .cameraRoll("existing-photo"))
            #expect(store.pictures[faces[1]] == nil)
            #expect(store.pictureImageSelections[faces[2]] == .lobbyDefault("lobby-plaque"))
            #expect(store.mirrors[faces[1].coord] == .west)
            #expect(store.wallTexture == "retained-wall")
            #expect(store.missionHeading == "Retained mission")
            store.saveCurrentFloorAsOverride()
            let reload = MazeStore()
            #expect(reload.pictures == store.pictures)
            #expect(reload.pictureImageSelections == store.pictureImageSelections)
            #expect(reload.mirrors == store.mirrors)
        })
    }
}
