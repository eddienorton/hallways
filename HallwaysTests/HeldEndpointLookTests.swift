import Testing
import SceneKit
@testable import Hallways

/// Sept 28: when a held (long-press) walk reaches its endpoint, the same
/// finger keeps working as ordinary Free Look -- horizontal only, from a
/// fresh origin at the stop -- and never resumes walking.
@MainActor
struct HeldEndpointLookTests {
    private let quarterTurn = 140.0 // ContentView's dragRotateDistance

    private func makeController(cells: Set<GridCoordinate>, start: GridCoordinate, facing: Direction,
                                end: GridCoordinate) -> TapNavigationController {
        let camera = SCNNode()
        camera.position = SCNVector3(Float(start.col) * 3.52, 1.6, Float(start.row) * 3.52)
        camera.eulerAngles = SCNVector3(0, Float(facing.yaw), 0)
        return TapNavigationController(cameraNode: camera, scene: SCNScene(), cells: cells, cellSize: 3.52,
            startCell: start, startFacing: facing, endCell: end, floorNumber: 2)
    }

    /// A straight east-west corridor, walking east from (5,6) to the dead
    /// end at (5,8). The target cell is BEHIND the player so arriving
    /// never involves the floor's end cell.
    private func deadEndCorridor() -> TapNavigationController {
        makeController(cells: Set((5...8).map { GridCoordinate(row: 5, col: $0) }),
                       start: GridCoordinate(row: 5, col: 6), facing: .east, end: GridCoordinate(row: 5, col: 5))
    }

    private final class Clock { var time = 1.0 }
    private let clock = Clock()
    private func settle(_ controller: TapNavigationController, frames: Int = 240) async {
        let renderer = SCNRenderer(device: nil, options: nil)
        for _ in 0..<frames {
            clock.time += 1.0 / 60
            controller.renderer(renderer, updateAtTime: clock.time)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func yaw(_ c: TapNavigationController) -> Double { Double(c.cameraNode.eulerAngles.y) }
    private func angle(_ a: Double, equals b: Double) -> Bool { abs(atan2(sin(a - b), cos(a - b))) < 0.0001 }

    /// Holds and polls like ContentView's 0.12 s timer until the walk
    /// reports its endpoint (or gives up).
    private func holdUntilEndpoint(_ controller: TapNavigationController) async -> Bool {
        controller.setWalkingHeld(true)
        for _ in 0..<12 {
            if controller.advanceWhileHeld() { return true }
            await settle(controller, frames: 30)
        }
        return false
    }

    @Test func automaticLTurnStillContinuesAndOnlyTheTrueEndpointReports() async {
        let start = GridCoordinate(row: 2, col: 2), corner = GridCoordinate(row: 1, col: 2), exit = GridCoordinate(row: 1, col: 3)
        let controller = makeController(cells: [start, corner, exit], start: start, facing: .north, end: exit)
        controller.setWalkingHeld(true)
        #expect(controller.advanceWhileHeld() == false) // walks
        await settle(controller)
        #expect(controller.currentCell == corner)
        #expect(controller.advanceWhileHeld() == false) // the unambiguous L: auto-turn, NOT an endpoint
        #expect(controller.isAnimating)
        await settle(controller)
        #expect(controller.facing == .east)
        #expect(controller.advanceWhileHeld() == false) // keeps walking round the corner
        await settle(controller)
        #expect(controller.currentCell == exit)
        #expect(controller.advanceWhileHeld() == true) // genuine endpoint
        #expect(!controller.heldEndpointLookActive) // reporting alone changes nothing
        #expect(!controller.isAnimating)
    }

    @Test func driftBeforeTheStopNeverTurnsTheCameraAndLaterMovementDoes() async {
        let controller = deadEndCorridor()
        #expect(await holdUntilEndpoint(controller))
        #expect(controller.currentCell == GridCoordinate(row: 5, col: 8))
        let stopYaw = yaw(controller)

        // The finger drifted 35 pt right during the walk; that spot is the new zero.
        #expect(controller.beginHeldEndpointLook(fingerX: 235, pointsPerQuarterTurn: quarterTurn))
        #expect(controller.heldEndpointLookActive && controller.isDragRotating)
        #expect(yaw(controller) == stopYaw)
        controller.updateHeldEndpointLook(fingerX: 235) // perfectly still
        #expect(angle(yaw(controller), equals: stopYaw))
        controller.updateHeldEndpointLook(fingerX: 215) // 20 pt left = turning right, same sign as a pan
        #expect(angle(yaw(controller), equals: stopYaw - 20 / quarterTurn * .pi / 2))
        // Well past 90 degrees, like ordinary Free Look.
        controller.updateHeldEndpointLook(fingerX: 235 + 1.6 * quarterTurn)
        #expect(angle(yaw(controller), equals: stopYaw + 1.6 * .pi / 2))
        #expect(controller.advanceWhileHeld() == false) // a stray poll can't walk mid-look

        // Release: arbitrary yaw kept, logical facing = nearest cardinal, state cleared.
        controller.endHeldEndpointLook(fingerX: 235 + 1.6 * quarterTurn)
        await settle(controller)
        #expect(!controller.heldEndpointLookActive && !controller.isDragRotating && !controller.isAnimating)
        #expect(angle(yaw(controller), equals: stopYaw + 1.6 * .pi / 2)) // no release snap
        #expect(controller.facing == .west) // 144 degrees left of east: nearest is west
        #expect(controller.currentCell == GridCoordinate(row: 5, col: 8))

        // A NEW walk uses the normal align-before-walk and grid movement.
        controller.setWalkingHeld(true)
        #expect(controller.advanceWhileHeld() == false)
        await settle(controller)
        controller.setWalkingHeld(false)
        #expect(controller.currentCell.col < 8)
        #expect(angle(yaw(controller), equals: Direction.west.yaw))
        #expect(controller.cameraNode.position.z == Float(5) * 3.52) // no sideways drift
    }

    @Test func lookingTowardAnOpenHallwayDoesNotResumeWalking() async {
        // Blocked T: forward is a wall, both sides open -- the held walk
        // can't continue, so it's an endpoint.
        let start = GridCoordinate(row: 2, col: 2), junction = GridCoordinate(row: 1, col: 2)
        let west = GridCoordinate(row: 1, col: 1), east = GridCoordinate(row: 1, col: 3)
        let controller = makeController(cells: [start, junction, west, east], start: start, facing: .north, end: east)
        #expect(await holdUntilEndpoint(controller))
        #expect(controller.currentCell == junction)

        #expect(controller.beginHeldEndpointLook(fingerX: 100, pointsPerQuarterTurn: quarterTurn))
        controller.updateHeldEndpointLook(fingerX: 100 + quarterTurn) // look straight down the west branch
        #expect(angle(yaw(controller), equals: Direction.west.yaw))
        for _ in 0..<3 { controller.advanceWhileHeld() }
        await settle(controller)
        #expect(controller.currentCell == junction) // still standing
        controller.endHeldEndpointLook(fingerX: 100 + quarterTurn)
        await settle(controller)
        #expect(controller.currentCell == junction) // releasing doesn't walk either
        #expect(controller.facing == .west)
        #expect(!controller.isAnimating)

        // Lift, then a new press walks the way you're now facing.
        controller.setWalkingHeld(true)
        controller.advanceWhileHeld()
        await settle(controller)
        #expect(controller.currentCell == west)
    }

    @Test func rapidLiftAndResetsLeaveNoStuckState() async {
        let controller = deadEndCorridor()
        controller.endHeldEndpointLook(fingerX: 50) // lift before any endpoint: no-op
        #expect(!controller.heldEndpointLookActive && !controller.isDragRotating)
        #expect(await holdUntilEndpoint(controller))
        let stopYaw = yaw(controller)
        let facing = controller.facing

        // Lift right at the endpoint.
        #expect(controller.beginHeldEndpointLook(fingerX: 80, pointsPerQuarterTurn: quarterTurn))
        #expect(!controller.beginHeldEndpointLook(fingerX: 90, pointsPerQuarterTurn: quarterTurn)) // one at a time
        controller.endHeldEndpointLook(fingerX: 80)
        await settle(controller)
        #expect(!controller.heldEndpointLookActive && !controller.isDragRotating && !controller.isAnimating)
        #expect(angle(yaw(controller), equals: stopYaw))
        #expect(controller.facing == facing)
        controller.updateHeldEndpointLook(fingerX: 300) // stale moves after release do nothing
        #expect(angle(yaw(controller), equals: stopYaw))

        // A floor reset mid-look clears the state.
        #expect(await holdUntilEndpoint(controller))
        #expect(controller.beginHeldEndpointLook(fingerX: 80, pointsPerQuarterTurn: quarterTurn))
        controller.reset()
        #expect(!controller.heldEndpointLookActive && !controller.isDragRotating)
        controller.endHeldEndpointLook(fingerX: 200) // the eventual lift is harmless
        #expect(!controller.isAnimating)
    }

    @Test func freeLookOffStillUsesTheLegacyDragRules() async {
        let controller = deadEndCorridor()
        controller.freeLookEnabled = false
        #expect(await holdUntilEndpoint(controller))
        let stopYaw = yaw(controller)
        #expect(controller.beginHeldEndpointLook(fingerX: 0, pointsPerQuarterTurn: quarterTurn))
        controller.updateHeldEndpointLook(fingerX: 3 * quarterTurn)
        #expect(angle(yaw(controller), equals: stopYaw + .pi / 2)) // clamped to a quarter turn
        controller.endHeldEndpointLook(fingerX: 0.4 * quarterTurn) // past the 30% commit
        await settle(controller)
        #expect(controller.facing == .north)
        #expect(angle(yaw(controller), equals: Direction.north.yaw))
    }
}
