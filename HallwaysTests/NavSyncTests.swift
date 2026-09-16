import Testing
import SceneKit
@testable import Hallways

@MainActor
struct NavSyncTests {
    @Test(arguments: [false, true])
    func completedTurnCannotReplayPreviousWalk(south: Bool) async throws {
        let start = GridCoordinate(row: 10, col: 7)
        let end = GridCoordinate(row: south ? 11 : 10, col: south ? 7 : 8)
        let camera = SCNNode()
        camera.position = SCNVector3(22.4, 1.6, 32)
        let controller = TapNavigationController(cameraNode: camera, scene: SCNScene(),
            cells: [start, end], cellSize: 3.2, startCell: start,
            startFacing: south ? .south : .east, endCell: end, floorNumber: 2)
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        controller.advance()
        for _ in 0..<45 {
            time += 1.0 / 60
            controller.renderer(renderer, updateAtTime: time)
        }
        // Drain the arrival before starting the next gesture.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        try #require(!controller.isAnimating)
        try #require(controller.currentCell == end)
        let arrived = controller.cameraNode.position
        controller.beginDragRotate()
        controller.updateDragRotate(fraction: 0.4)
        controller.endDragRotate(fraction: 0.4)
        // Hold main-thread completion pending while render frames continue.
        // Eleven ticks finish the pivot; the old code then falls through to
        // translation and replays the previous walk from its stale start.
        for _ in 0..<13 {
            time += 1.0 / 60
            controller.renderer(renderer, updateAtTime: time)
        }
        print("[NAVSYNC REPRO] arrived=\(arrived) afterTurn=\(controller.cameraNode.position)")
        #expect(SCNVector3EqualToVector3(controller.cameraNode.position, arrived))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(!controller.isAnimating)
        #expect(controller.currentCell == end)
        #expect(SCNVector3EqualToVector3(controller.cameraNode.position, arrived))
        controller.openHandheldMap()
        controller.closeHandheldMap()
        #expect(SCNVector3EqualToVector3(controller.cameraNode.position, arrived))
    }
}
