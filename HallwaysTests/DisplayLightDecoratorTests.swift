import Testing
import SceneKit
@testable import Hallways

@MainActor
struct DisplayLightDecoratorTests {
    @Test(arguments: [DecoratorTarget.Kind.missionSign, .floorMap])
    func realDisplayTapSelectsLightOnlyTargetAndEditsLive(kind: DecoratorTarget.Kind) async throws {
        let store = MazeStore()
        store.switchTo(id: 2)
        let (coord, direction) = try #require(store.missionSigns.first)
        if kind == .floorMap { store.placeFloorMap(direction, at: coord) }
        store.removePictureLight(at: coord)
        let built = HallwayScene.build(fromMaze: store.cells, cellSize: store.cellSize, wallHeight: store.wallHeight,
            floorMaps: kind == .floorMap ? [coord: direction] : [:],
            missionSigns: kind == .missionSign ? [coord: direction] : [:],
            floorNumber: store.currentMazeID)
        let scene = built.scene
        let target = DecoratorTarget(floor: store.currentMazeID, coord: coord, kind: kind)
        var found: SCNNode?
        scene.rootNode.enumerateChildNodes { node, _ in
            if DecoratorTarget.read(node) == target { found = node }
        }
        let frame = try #require(found)
        let plane = try #require(frame.childNodes.first { $0.geometry is SCNPlane })
        let panel = try #require(plane.geometry as? SCNPlane)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        scene.rootNode.addChildNode(camera)
        camera.position = frame.convertPosition(SCNVector3(0, 0, 1), to: nil)
        camera.look(at: plane.worldPosition)
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.scene = scene
        view.pointOfView = camera
        let state = DecoratorState()
        state.attach(scene: scene, store: store)
        state.enabled = true
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        // Render once so the offscreen SCNView has current camera/projection transforms.
        _ = view.snapshot()
        // Exercise real SceneKit hit-testing + parent identity resolution, not direct selection assignment.
        let selected = state.select(at: CGPoint(x: 200, y: 400), in: view)
        #expect(selected)
        #expect(state.selection == target)
        #expect(!state.pictureLightIsOn(target))
        state.setPictureLightOn(true)
        state.setPictureLightOn(true)
        #expect(store.pictureLights[coord] == direction)
        #expect(frame.childNodes.filter { $0.name == "pictureLight" }.count == 1)
        let fixture = try #require(frame.childNode(withName: "pictureLight", recursively: false))
        let light = try #require(fixture.childNode(withName: "pictureLightSource", recursively: false)?.light)
        #expect(abs(light.attenuationEndDistance - (panel.height + 0.4)) < 0.000001)
        state.changePictureLightBrightness(by: 2)
        #expect(light.intensity == 16)
        state.changePictureLightBrightness(by: -4)
        #expect(light.intensity == 1)
        #expect(frame.childNode(withName: "pictureLight", recursively: false) === fixture)
        let reload = MazeStore()
        reload.switchTo(id: store.currentMazeID)
        #expect(reload.pictureLights[coord] == direction)
        #expect(reload.lightBrightnessLevel(.picture, at: coord) == 1)
        // Picture-only methods and generic light movement/deletion must reject these displays.
        let originalWidth = (frame.geometry as? SCNBox)?.width
        state.changePictureSize(.fullLength)
        state.deletePicture()
        state.deleteSelected()
        state.move(.north)
        #expect(frame.parent != nil)
        #expect((frame.geometry as? SCNBox)?.width == originalWidth)
        #expect(frame.childNode(withName: "pictureLight", recursively: false) === fixture)
        state.setPictureLightOn(false)
        #expect(frame.childNode(withName: "pictureLight", recursively: false) == nil)
        #expect(store.pictureLights[coord] == nil)
        let afterOff = MazeStore()
        afterOff.switchTo(id: store.currentMazeID)
        #expect(afterOff.pictureLights[coord] == nil)
    }
}
