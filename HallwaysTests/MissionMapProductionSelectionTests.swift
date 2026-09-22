import Testing
import SceneKit
@testable import Hallways

// Sept 21 (Task B: real-device Mission Statement / Floor Map Decorator
// selection investigation). Eddie's on-device repro: DECORATE -> tap a
// Mission Statement or Floor Map -> only the ordinary wall-bump
// ("thump") plays, no inspector -- while Codex's own passing
// DisplayLightDecoratorTests (a REAL floor 2 topology via
// MazeStore.switchTo(id: 2), which already rules out "isolated single-
// cell maze" as the gap) uses a camera placed 1 unit in front of the
// FRAME and precisely aimed with `camera.look(at: plane.worldPosition)`,
// with SCNCamera's own DEFAULT fieldOfView (60 degrees) rather than the
// real 75-degree FOV HallwayScene.build's own cameraNode actually uses.
// This test instead uses that real cameraNode's own fieldOfView/zNear
// (via a throwaway build() call, so it can never drift from whatever
// production actually sets), positions the camera at the display's own
// cell center at real eye height (1.6, same as HallwayScene.build),
// and only THEN aims it -- exercising the real production node
// hierarchy end to end through DecoratorState.select(at:in:), not a
// direct DecoratorTarget/selection assertion. If this still selects
// correctly, the discrepancy isn't reproducible from static geometry
// under even a best-case aim, which points at something in the real
// gesture/animation-state path instead -- see select()'s own new
// [DECORDIAG] logging for that half of the investigation.
@MainActor
struct MissionMapProductionSelectionTests {
    @Test(arguments: [DecoratorTarget.Kind.missionSign, .floorMap])
    func realFloorTwoTopologySelectsAtProductionFieldOfView(kind: DecoratorTarget.Kind) throws {
        let store = MazeStore()
        store.switchTo(id: 2)

        let coord: GridCoordinate
        let direction: Direction
        switch kind {
        case .missionSign:
            (coord, direction) = try #require(store.missionSigns.first)
        case .floorMap:
            (coord, direction) = try #require(store.floorMaps.first)
        default:
            Issue.record("unexpected kind")
            return
        }

        // The real production camera's own fieldOfView/zNear/zFar --
        // read once from a throwaway build() so this can never
        // silently drift out of sync with whatever HallwayScene.build
        // actually ships (see this file's header comment).
        let productionCameraProbe = HallwayScene.build(fromMaze: store.cells, cellSize: store.cellSize, wallHeight: store.wallHeight,
            floorNumber: store.currentMazeID, playerStart: coord, playerEnd: coord).cameraNode
        let productionFOV = try #require(productionCameraProbe.camera?.fieldOfView)
        let productionZNear = try #require(productionCameraProbe.camera?.zNear)

        let built = HallwayScene.build(fromMaze: store.cells, cellSize: store.cellSize, wallHeight: store.wallHeight,
            floorMaps: kind == .floorMap ? [coord: direction] : [:],
            missionSigns: kind == .missionSign ? [coord: direction] : [:],
            floorNumber: store.currentMazeID, playerStart: coord, playerEnd: coord)
        let scene = built.scene

        let target = DecoratorTarget(floor: store.currentMazeID, coord: coord, kind: kind)
        var found: SCNNode?
        scene.rootNode.enumerateChildNodes { node, _ in
            if DecoratorTarget.read(node) == target { found = node }
        }
        let frame = try #require(found)
        let plane = try #require(frame.childNodes.first { $0.geometry is SCNPlane })

        // Real eye height (1.6, matching HallwayScene.build's own
        // cameraNode), standing at the display's own cell center --
        // the SAME real-world standing spot a player is actually in
        // when they tap this display (Pictures are tapped the same
        // way, from their own cell, not an adjacent one) -- with the
        // real 75-degree production FOV, not SCNCamera's 60-degree
        // default. Aimed as well as a real player's tap ever could be
        // (dead-on at the plane's own center), so a failure here is a
        // real geometry/hit-test gap, not a sloppy-tap artifact.
        let camera = SCNCamera()
        camera.fieldOfView = productionFOV
        camera.zNear = productionZNear
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(Float(store.cellSize) * Float(coord.col), 1.6, Float(store.cellSize) * Float(coord.row))
        scene.rootNode.addChildNode(cameraNode)
        cameraNode.look(at: plane.worldPosition)

        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.scene = scene
        view.pointOfView = cameraNode
        let tapPoint = view.projectPoint(plane.worldPosition)

        let state = DecoratorState()
        state.attach(scene: scene, store: store)
        state.enabled = true
        _ = view.snapshot() // force current camera/projection transforms, same as DisplayLightDecoratorTests

        let selected = state.select(at: CGPoint(x: CGFloat(tapPoint.x), y: CGFloat(tapPoint.y)), in: view)
        #expect(selected)
        #expect(state.selection == target)
    }
}
