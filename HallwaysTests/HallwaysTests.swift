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
        #expect(store.floorCount == 3)
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

}
