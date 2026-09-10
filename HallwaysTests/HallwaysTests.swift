import Testing
import SceneKit
import AVFoundation
@testable import Hallways

@MainActor
struct HallwaysTests {
    private func finishMove(_ controller: TapNavigationController, renderer: SCNRenderer, time: inout Double) async {
        for _ in 0..<400 {
            time += 0.05
            controller.renderer(renderer, updateAtTime: time)
            await Task.yield()
            if !controller.isAnimating { return }
        }
        #expect(!controller.isAnimating)
    }

    @Test func mailMustReachItsAddressAndResetRestoresIt() async {
        let scene = SCNScene()
        let camera = SCNNode(); camera.position.y = 1.6
        scene.rootNode.addChildNode(camera)
        let cells = Set((0...4).map { GridCoordinate(row: 0, col: $0) })
        let first = GridCoordinate(row: 0, col: 1)
        let second = GridCoordinate(row: 0, col: 2)
        let room301 = GridCoordinate(row: 0, col: 3)
        let room302 = GridCoordinate(row: 0, col: 4)
        let controller = TapNavigationController(cameraNode: camera, scene: scene, cells: cells, cellSize: 3.2,
            startCell: GridCoordinate(row: 0, col: 0), startFacing: .east, endCell: room302,
            objects: [first: .envelope, second: .envelope],
            roomDoors: [room301: RoomDoorPlacement(coord: room301, direction: .north, roomNumber: 301),
                        room302: RoomDoorPlacement(coord: room302, direction: .north, roomNumber: 302)],
            itemRooms: [first: 301, second: 302], missionObjectKind: .envelope)
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == first)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.carriedMail.map(\.roomNumber) == [301, 302])
        #expect(!controller.isMissionComplete)
        // A remote door cannot accept delivery.
        controller.deliverMail(at: room301)
        #expect(controller.carriedMail.count == 2)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == room301)
        // Standing alongside the door without facing it cannot deliver.
        controller.deliverMail(at: room301)
        #expect(controller.carriedMail.count == 2)
        controller.rotate(toward: .north); await finishMove(controller, renderer: renderer, time: &time)
        controller.deliverMail(at: room301)
        #expect(controller.carriedMail.map(\.roomNumber) == [302])
        #expect(!controller.isMissionComplete)
        controller.deliverMail(at: room301)
        #expect(controller.carriedMail.map(\.roomNumber) == [302])
        controller.rotate(toward: .east); await finishMove(controller, renderer: renderer, time: &time)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        controller.rotate(toward: .north); await finishMove(controller, renderer: renderer, time: &time)
        controller.deliverMail(at: room302)
        #expect(controller.carriedMail.isEmpty)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.carriedMail.map(\.roomNumber) == [301])
    }

    @Test func mapStopsOnReturnAndBackingUpKeepsFacing() async {
        let scene = SCNScene()
        let camera = SCNNode(); camera.position.y = 1.6
        scene.rootNode.addChildNode(camera)
        let start = GridCoordinate(row: 0, col: 0)
        let map = GridCoordinate(row: 0, col: 2)
        let end = GridCoordinate(row: 0, col: 4)
        let controller = TapNavigationController(cameraNode: camera, scene: scene,
            cells: Set((0...4).map { GridCoordinate(row: 0, col: $0) }), cellSize: 3.2,
            startCell: start, startFacing: .east, endCell: end, floorMaps: [map: .north])
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == map)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == end)
        controller.stepBackward(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == GridCoordinate(row: 0, col: 3))
        #expect(controller.facing == .east)
        controller.rotate(toward: .west); await finishMove(controller, renderer: renderer, time: &time)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == map)
    }

    @Test func elevatorPinchUsesMissionGate() {
        let scene = SCNScene()
        let camera = SCNNode()
        let left = SCNNode(), right = SCNNode()
        scene.rootNode.addChildNode(camera)
        let start = GridCoordinate(row: 0, col: 0)
        let letter = GridCoordinate(row: 1, col: 0)
        let controller = TapNavigationController(cameraNode: camera, scene: scene, cells: [start, letter], cellSize: 3.2,
            startCell: start, startFacing: .north, endCell: start, objects: [letter: .envelope],
            elevatorLeftDoor: left, elevatorRightDoor: right, elevatorMountDirection: .north,
            missionObjectKind: .envelope)
        controller.pinchForward()
        #expect(controller.elevatorRejected != nil)
        #expect(controller.currentCell == start)
    }
    @Test func recoveredFloorsKeepMailAddressesAndPlayableChuteAudio() throws {
        let store = MazeStore()
        #expect(store.floorCount == 4)
        store.switchTo(id: 2)
        #expect(store.nextMazeID == 3)
        store.switchTo(id: 3)
        #expect(store.missionObjectKind == .envelope)
        let rooms = Set(store.roomDoors.values.map(\.roomNumber))
        #expect(rooms == [301, 302, 303, 304])
        let letters = store.objects.filter { $0.value == .envelope }
        #expect(letters.count == 4)
        #expect(letters.keys.allSatisfy { coord in
            store.itemRooms[coord].map { rooms.contains($0) } ?? false
        })
        store.switchTo(id: 4)
        #expect(store.missionObjectKind == .paintBucket)
        #expect(store.objects.values.contains(.paintBucket))
        #expect(store.cells.count == 55)
        #expect(store.mirrors.count == 3)
        let url = try #require(Bundle.main.url(forResource: "trash-chute", withExtension: "mp3"))
        let player = try AVAudioPlayer(contentsOf: url)
        #expect(player.duration > 2)
        #expect(SoundEffects.playTrashChute())
        #expect(AVAudioSession.sharedInstance().category == .playback)
    }

    @Test func everyObjectKindHasSceneGeometry() {
        let coords = ObjectKind.allCases.enumerated().map { GridCoordinate(row: 0, col: $0.offset) }
        let objects = Dictionary(uniqueKeysWithValues: zip(coords, ObjectKind.allCases))
        let result = HallwayScene.build(fromMaze: Set(coords), cellSize: 3.2, wallHeight: 3,
                                       objects: objects, playerStart: coords.first, playerEnd: coords.last)
        #expect(result.objectNodes.count == ObjectKind.allCases.count)
        #expect(result.objectNodes.values.allSatisfy { !$0.childNodes.isEmpty || $0.geometry != nil })
    }

    @Test func mailAudioAssetsDecodeAndPlay() throws {
        for name in ["mail-pick-up", "mail-letter-drop-in-door-slot"] {
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "mp3"))
            let player = try AVAudioPlayer(contentsOf: url)
            #expect(player.duration > 0)
        }
        #expect(SoundEffects.playMailPickup())
        #expect(SoundEffects.playMailDelivery())
    }

    @Test func mirrorEditsSurviveFloorSwitchExportAndUndo() throws {
        let store = MazeStore()
        store.switchTo(id: 2)
        let coord = GridCoordinate(row: 5, col: 4)
        #expect(store.canPlaceMirror(.north, at: coord))
        store.placeMirror(.north, at: coord)
        #expect(store.mirrors[coord] == .north)
        store.placeMirror(.south, at: MazeStore.elevatorCoordinate) // Open neighbor, not a wall.
        #expect(store.mirrors[MazeStore.elevatorCoordinate] == nil)
        store.switchTo(id: 3)
        store.switchTo(id: 2)
        #expect(store.mirrors[coord] == .north)
        let json = try #require(store.exportLibraryJSON()?.data(using: .utf8))
        let floors = try #require(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let second = try #require(floors.first { $0["id"] as? Int == 2 })
        let mirrors = try #require(second["mirrors"] as? [[String: Any]])
        #expect(mirrors.contains { item in
            let placed = item["coord"] as? [String: Int]
            return placed?["row"] == 5 && placed?["col"] == 4 && item["direction"] as? String == "north"
        })
        store.snapshotForUndo()
        store.removeMirror(at: coord)
        #expect(store.mirrors[coord] == nil)
        store.undo()
        #expect(store.mirrors[coord] == .north)
    }

    @Test func mirrorsStopWalkingOnReturnTrips() async {
        let scene = SCNScene()
        let camera = SCNNode(); camera.position.y = 1.6
        scene.rootNode.addChildNode(camera)
        let start = GridCoordinate(row: 0, col: 0)
        let mirror = GridCoordinate(row: 0, col: 2)
        let end = GridCoordinate(row: 0, col: 4)
        let controller = TapNavigationController(cameraNode: camera, scene: scene,
            cells: Set((0...4).map { GridCoordinate(row: 0, col: $0) }), cellSize: 3.2,
            startCell: start, startFacing: .east, endCell: end, mirrors: [mirror: .north])
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == mirror)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == end)
        controller.rotate(toward: .west); await finishMove(controller, renderer: renderer, time: &time)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == mirror)
    }

    @Test func mirrorFacesIntoHallwayOnEveryWall() throws {
        let coord = GridCoordinate(row: 3, col: 4)
        let center = SCNVector3(12.8, 1.6, 9.6)
        for direction in Direction.allCases {
            let mirror = HallwayScene.makeMirrorNode(at: coord, direction: direction, cellSize: 3.2)
            let surface = try #require(mirror.childNode(withName: "mirrorSurface", recursively: true))
            let facing = mirror.convertVector(SCNVector3(0, 0, 1), to: nil)
            let toCenter = SCNVector3(center.x - mirror.position.x, 0, center.z - mirror.position.z)
            #expect(facing.x * toCenter.x + facing.z * toCenter.z > 0)
            #expect(surface.geometry?.firstMaterial?.diffuse.contents is UIImage)
        }
    }

    @Test func heldWalkingTurnsAtBothLCornersButTapsDoNot() async {
        for side in [Direction.east, .west] {
            let start = GridCoordinate(row: 2, col: 2)
            let corner = GridCoordinate(row: 1, col: 2)
            let exit = GridCoordinate(row: 1, col: 2 + side.delta.col)
            let scene = SCNScene(), camera = SCNNode()
            scene.rootNode.addChildNode(camera)
            let controller = TapNavigationController(cameraNode: camera, scene: scene,
                cells: [start, corner, exit], cellSize: 3.2,
                startCell: start, startFacing: .north, endCell: exit)
            let renderer = SCNRenderer(device: nil, options: nil)
            var time = 1.0
            controller.advanceWhileHeld()
            await finishMove(controller, renderer: renderer, time: &time)
            #expect(controller.currentCell == corner)
            controller.advance() // Ordinary taps still cannot turn for you.
            #expect(!controller.isAnimating)
            #expect(controller.facing == .north)
            controller.advanceWhileHeld()
            #expect(controller.isAnimating)
            controller.advanceWhileHeld() // Polling during the pivot queues nothing.
            await finishMove(controller, renderer: renderer, time: &time)
            #expect(controller.facing == side)
            #expect(controller.currentCell == corner)
            // No next tick means release: finishing the pivot does not start walking.
            #expect(!controller.isAnimating)
            controller.advanceWhileHeld()
            await finishMove(controller, renderer: renderer, time: &time)
            #expect(controller.currentCell == exit)
            controller.advanceWhileHeld() // No automatic U-turn at the dead end.
            #expect(!controller.isAnimating)
            #expect(controller.facing == side)
        }
    }

    @Test func heldWalkingWaitsAtBlockedTJunction() async {
        let start = GridCoordinate(row: 2, col: 2)
        let junction = GridCoordinate(row: 1, col: 2)
        let scene = SCNScene(), camera = SCNNode()
        scene.rootNode.addChildNode(camera)
        let controller = TapNavigationController(cameraNode: camera, scene: scene,
            cells: [start, junction, GridCoordinate(row: 1, col: 1), GridCoordinate(row: 1, col: 3)],
            cellSize: 3.2, startCell: start, startFacing: .north,
            endCell: GridCoordinate(row: 1, col: 3))
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        controller.advanceWhileHeld()
        await finishMove(controller, renderer: renderer, time: &time)
        for _ in 0..<3 { controller.advanceWhileHeld() }
        #expect(controller.currentCell == junction)
        #expect(controller.facing == .north)
        #expect(!controller.isAnimating)
    }

    @Test func longPressFromWallChoosesOnlyUnambiguousSide() async {
        for sides in [[Direction.east], [.west], [.east, .west]] {
            let start = GridCoordinate(row: 1, col: 1)
            let neighbors = sides.map { GridCoordinate(row: 1, col: 1 + $0.delta.col) }
            let scene = SCNScene(), camera = SCNNode()
            scene.rootNode.addChildNode(camera)
            let controller = TapNavigationController(cameraNode: camera, scene: scene,
                cells: Set([start] + neighbors), cellSize: 3.2,
                startCell: start, startFacing: .north, endCell: neighbors[0])
            let renderer = SCNRenderer(device: nil, options: nil)
            var time = 1.0
            controller.advanceWhileHeld()
            if sides.count == 2 {
                for _ in 0..<3 { controller.advanceWhileHeld() }
                #expect(!controller.isAnimating)
                #expect(controller.currentCell == start)
                #expect(controller.facing == .north)
                // A swipe-selected direction unlocks continuation.
                controller.rotate(toward: .east)
            }
            await finishMove(controller, renderer: renderer, time: &time)
            #expect(controller.facing == sides[0])
            #expect(controller.currentCell == start)
            controller.advanceWhileHeld()
            await finishMove(controller, renderer: renderer, time: &time)
            #expect(controller.currentCell == neighbors[0])
        }
    }

    @Test func paintBucketPaintsEveryArrivalThenResetRestoresProgress() async {
        let start = GridCoordinate(row: 0, col: 0)
        let bucket = GridCoordinate(row: 0, col: 1)
        let far = GridCoordinate(row: 0, col: 2)
        let cells: Set = [start, bucket, far]
        let built = HallwayScene.build(fromMaze: cells, cellSize: 3.2, wallHeight: 3,
                                       objects: [bucket: .paintBucket],
                                       missionObjectKind: .paintBucket,
                                       playerStart: start, playerEnd: start)
        let left = SCNNode(), right = SCNNode()
        built.scene.rootNode.addChildNode(left)
        built.scene.rootNode.addChildNode(right)
        let controller = TapNavigationController(
            cameraNode: built.cameraNode, scene: built.scene, cells: cells, cellSize: 3.2,
            startCell: start, startFacing: .west, endCell: start,
            objects: [bucket: .paintBucket], objectNodes: built.objectNodes,
            elevatorLeftDoor: left, elevatorRightDoor: right, elevatorMountDirection: .west,
            missionObjectKind: .paintBucket)
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        controller.pinchForward()
        #expect(controller.elevatorRejected != nil)
        #expect(controller.paintedCells.isEmpty)
        controller.rotate(toward: .east); await finishMove(controller, renderer: renderer, time: &time)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.hasPaintBucket)
        #expect(controller.paintedCells == [bucket])
        #expect(!controller.isMissionComplete)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.paintedCells == [bucket, far])
        controller.rotate(toward: .west); await finishMove(controller, renderer: renderer, time: &time)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == start)
        #expect(controller.paintedCells == cells)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.hasPaintBucket)
        #expect(controller.paintedCells.isEmpty)
        #expect(!controller.isMissionComplete)
        controller.rotate(toward: .east); await finishMove(controller, renderer: renderer, time: &time)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.hasPaintBucket)
        #expect(controller.paintedCells == [bucket])
    }

}
