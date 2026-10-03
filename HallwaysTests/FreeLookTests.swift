import Testing
import SceneKit
@testable import Hallways

/// Sept 28 free-look experiment: DISCRETE POSITION, CONTINUOUS VISION.
@MainActor
struct FreeLookTests {
    // A straight east-west corridor: start at the west end, facing east.
    private let start = GridCoordinate(row: 5, col: 5)
    private let middle = GridCoordinate(row: 5, col: 6)
    private let end = GridCoordinate(row: 5, col: 7)

    private func makeController() -> TapNavigationController {
        let camera = SCNNode()
        camera.position = SCNVector3(Float(start.col) * 3.52, 1.6, Float(start.row) * 3.52)
        camera.eulerAngles = SCNVector3(0, Float(Direction.east.yaw), 0)
        return TapNavigationController(cameraNode: camera, scene: SCNScene(),
            cells: [start, middle, end], cellSize: 3.52, startCell: start,
            startFacing: .east, endCell: end, floorNumber: 2)
    }

    private final class Clock { var time = 1.0 }
    private let clock = Clock()
    private func settle(_ controller: TapNavigationController, frames: Int = 120) async {
        let renderer = SCNRenderer(device: nil, options: nil)
        for _ in 0..<frames {
            clock.time += 1.0 / 60
            controller.renderer(renderer, updateAtTime: clock.time)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func yaw(_ c: TapNavigationController) -> Double { Double(c.cameraNode.eulerAngles.y) }

    @Test func releaseKeepsArbitraryYawAndFacingBecomesNearestCardinal() async {
        let controller = makeController()
        let base = yaw(controller)
        controller.beginDragRotate()
        controller.updateDragRotate(fraction: 0.3) // 27 degrees left of east
        controller.endDragRotate(fraction: 0.3, velocityFraction: 5) // a flick must not commit a turn
        await settle(controller)
        #expect(!controller.isAnimating)
        #expect(abs(yaw(controller) - (base + 0.3 * .pi / 2)) < 0.0001) // camera stays put
        #expect(controller.facing == .east) // nearest cardinal

        controller.beginDragRotate()
        controller.updateDragRotate(fraction: 0.5) // now 72 degrees left of east
        controller.endDragRotate(fraction: 0.5)
        await settle(controller)
        #expect(abs(yaw(controller) - (base + 0.8 * .pi / 2)) < 0.0001) // not snapped to north
        #expect(controller.facing == .north)

        // No one-gesture quarter-turn limit.
        controller.beginDragRotate()
        controller.updateDragRotate(fraction: 1.5) // to ~117 degrees past north
        #expect(abs(yaw(controller) - (base + 2.3 * .pi / 2)) < 0.0001)
        controller.endDragRotate(fraction: 1.5)
        await settle(controller)
        #expect(controller.facing == .west)
    }

    @Test func walkingAlignsFirstThenUsesTheOrdinaryWalk() async {
        let controller = makeController()
        controller.beginDragRotate()
        controller.endDragRotate(fraction: 0.35) // ~31 degrees off east; facing stays east
        await settle(controller)
        #expect(controller.facing == .east)
        controller.advance()
        #expect(controller.isAnimating)
        await settle(controller, frames: 240)
        #expect(controller.currentCell != start) // walked east
        #expect(abs(yaw(controller) - Direction.east.yaw) < 0.0001) // straightened on the way
        #expect(controller.cameraNode.position.z == Float(start.row) * 3.52) // no sideways drift
    }

    @Test func blockedLogicalFacingStaysBlocked() async {
        let controller = makeController()
        controller.beginDragRotate()
        controller.endDragRotate(fraction: 0.7) // ~63 degrees: nearest is north, a wall here
        await settle(controller)
        #expect(controller.facing == .north)
        let lookedYaw = yaw(controller)
        let position = controller.cameraNode.position
        controller.advance()
        await settle(controller)
        #expect(controller.currentCell == start)
        #expect(SCNVector3EqualToVector3(controller.cameraNode.position, position))
        #expect(abs(yaw(controller) - lookedYaw) < 0.0001) // a refused walk doesn't turn you
    }

    @Test func scoutFromArbitraryYawAlignsTheCamera() async {
        let controller = makeController()
        controller.beginDragRotate()
        controller.endDragRotate(fraction: 0.3)
        await settle(controller)
        controller.beginDragMove()
        #expect(controller.cameraNode.action(forKey: "freeLookAlign") != nil)
        // A new horizontal drag cancels the alignment so it can't fight the finger.
        controller.endDragMove(fraction: 0)
        await settle(controller)
        controller.beginDragRotate()
        #expect(controller.cameraNode.action(forKey: "freeLookAlign") == nil)
    }

    @Test func flagOffRestoresSnapToCardinal() async {
        let controller = makeController()
        controller.freeLookEnabled = false
        controller.beginDragRotate()
        controller.updateDragRotate(fraction: 0.4)
        controller.endDragRotate(fraction: 0.4) // old 30% commit threshold
        await settle(controller)
        #expect(controller.facing == .north)
        #expect(abs(yaw(controller) - Direction.north.yaw) < 0.0001 || abs(abs(yaw(controller) - Direction.north.yaw) - 2 * .pi) < 0.0001)
        controller.beginDragRotate()
        controller.updateDragRotate(fraction: 3)
        #expect(abs(yaw(controller) - (Direction.north.yaw + .pi / 2)) < 0.0001) // clamped to a quarter turn
    }
}
