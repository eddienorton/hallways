import Testing
import SceneKit
@testable import Hallways

/// Oct 19 -- THE ELEVATOR THRESHOLD BY SWIPE. A vertical swipe (finger down =
/// walk forward, up = walk backward) crosses an open cab's doorway exactly as
/// the tap does: out of the arrived cab facing the hallway (swipe down), back
/// in having just stepped out (swipe up, still facing the hallway). Closed
/// doors: no crossing. The hallway and the cab look are unchanged.
@MainActor
struct ElevatorThresholdSwipeTests {
    private struct Cab {
        let scene = SCNScene()
        let camera = SCNNode()
        let left = SCNNode()
        let right = SCNNode()
        let controller: TapNavigationController
        init(direction: Direction = .north) {
            let cell = GridCoordinate(row: 0, col: 0)
            camera.position = SCNVector3(0, 1.6, 0)
            left.position = SCNVector3(-0.24, 1.3, -1.6)
            right.position = SCNVector3(0.24, 1.3, -1.6)
            controller = TapNavigationController(cameraNode: camera, scene: scene, cells: [cell],
                cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
                elevatorLeftDoor: left, elevatorRightDoor: right,
                elevatorMountDirection: direction, floorNumber: 12)
            [camera, left, right].forEach { scene.rootNode.addChildNode($0) }
            controller.elevatorReachableFloors = Set(1...16)
        }
    }

    private func tick(_ renderer: SCNRenderer, from start: Double, through end: Double,
                      until done: (() -> Bool)? = nil) async -> Double {
        var t = start
        while t <= end {
            renderer.update(atTime: t)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            t += 0.025
            if let done, done() { return t }
        }
        return t
    }

    private func renderer(_ cab: Cab) -> SCNRenderer {
        let r = SCNRenderer(device: nil, options: nil)
        r.scene = cab.scene
        r.delegate = cab.controller
        return r
    }

    /// Arrived, doors open, facing the hallway: a swipe down walks out (as the tap does).
    @Test func swipeDownInsideTheOpenCabWalksOut() async {
        let cab = Cab()
        cab.controller.presentArrivalInsideElevator(preservedYaw: 0)          // (facing the doors: out)
        // Doors still shut: no crossing.
        #expect(cab.controller.elevatorThresholdCrossing(forward: true) == nil)
        #expect(!cab.controller.crossElevatorThreshold(forward: true))
        cab.controller.playControlledArrivalDoorOpen()
        let r = renderer(cab)
        _ = await tick(r, from: 1, through: 2.8)
        #expect(cab.controller.canStartElevatorExit)
        #expect(cab.controller.elevatorThresholdCrossing(forward: true) == .exit)    // swipe down: out
        #expect(cab.controller.elevatorThresholdCrossing(forward: false) == nil)     // swipe up: the back wall
        #expect(cab.controller.crossElevatorThreshold(forward: true))
        _ = await tick(r, from: 2.825, through: 15) { !cab.controller.isElevatorRideInProgress && !cab.controller.isAnimating }
        #expect(abs(cab.camera.position.x) < 0.0001 && abs(cab.camera.position.z) < 0.0001)   // the hallway cell's centre
        #expect(!cab.controller.isElevatorRideInProgress)
        #expect(cab.controller.elevatorAwaitingEntryDirection == nil)
    }

    /// Just stepped out, still facing the hallway, the doors not yet shut: a
    /// swipe up walks backward into the cab -- the doors open again, the
    /// player keeps looking out, and the cab is as on arrival (a swipe down
    /// takes them out again).
    @Test func swipeUpJustOutsideWalksBackIn() async {
        let cab = Cab()
        let closedRight = cab.right.position
        cab.controller.presentArrivalInsideElevator(preservedYaw: 0)
        cab.controller.playControlledArrivalDoorOpen()
        let r = renderer(cab)
        var t = await tick(r, from: 1, through: 2.8)
        #expect(cab.controller.crossElevatorThreshold(forward: true))
        t = await tick(r, from: t, through: 15) { !cab.controller.isElevatorRideInProgress && !cab.controller.isAnimating }
        // Out, facing the hallway; the doors closing behind.
        #expect(cab.controller.elevatorAwaitingEntryDirection == nil)
        #expect(cab.controller.elevatorThresholdNearby)
        #expect(cab.controller.elevatorThresholdCrossing(forward: false) == .enter)  // swipe up: back in
        #expect(cab.controller.elevatorThresholdCrossing(forward: true) == nil)      // swipe down: the hallway, not the cab
        let yaw = cab.camera.eulerAngles.y
        #expect(cab.controller.crossElevatorThreshold(forward: false))
        t = await tick(r, from: t, through: t + 8) { cab.controller.isElevatorRideInProgress && !cab.controller.isAnimating }
        _ = await tick(r, from: t, through: t + 1)
        let depth = Float(HallwayScene.ElevatorGeometry(cellSize: 3.2).entryDistance)
        #expect(abs(cab.camera.position.z + depth) < 0.01)                       // in the cab (north: -z)
        #expect(abs(cab.camera.eulerAngles.y - yaw) < 0.0001)                    // still looking out: backed in
        #expect(cab.controller.elevatorAwaitingEntryDirection == .south)
        #expect(cab.right.position.x > closedRight.x + 0.7)                      // the doors open again
        #expect(cab.controller.canStartElevatorExit)
        #expect(cab.controller.elevatorThresholdCrossing(forward: true) == .exit)
    }

    /// Once the doors have shut behind the player, a swipe back does nothing.
    @Test func shutDoorsAreNotCrossed() async {
        let cab = Cab()
        cab.controller.presentArrivalInsideElevator(preservedYaw: 0)
        cab.controller.playControlledArrivalDoorOpen()
        let r = renderer(cab)
        var t = await tick(r, from: 1, through: 2.8)
        #expect(cab.controller.crossElevatorThreshold(forward: true))
        t = await tick(r, from: t, through: 15) { !cab.controller.isElevatorRideInProgress && !cab.controller.isAnimating }
        _ = await tick(r, from: t, through: t + 3)                                   // (the close-behind is 1.6 s)
        let p = cab.camera.position
        #expect(!cab.controller.elevatorThresholdNearby)
        #expect(cab.controller.elevatorThresholdCrossing(forward: false) == nil)
        #expect(!cab.controller.crossElevatorThreshold(forward: false))
        #expect(SCNVector3EqualToVector3(p, cab.camera.position))
        #expect(!cab.controller.isElevatorRideInProgress)
    }

    /// A plain hallway cell by a shut elevator: nothing to cross, the ordinary pan as before.
    @Test func theHallwayIsUntouched() {
        let cab = Cab()
        #expect(!cab.controller.elevatorThresholdNearby)
        #expect(cab.controller.elevatorThresholdCrossing(forward: true) == nil)
        #expect(cab.controller.elevatorThresholdCrossing(forward: false) == nil)
    }

    /// The swipe is continuous: the camera follows the finger toward the
    /// doorway while the drag goes on; a short drag glides back; a long one
    /// carries on from exactly where the finger left it (no jump).
    @Test func theSwipeMovesTheCameraWhileDragging() async {
        let cab = Cab()
        cab.controller.presentArrivalInsideElevator(preservedYaw: 0)
        cab.controller.playControlledArrivalDoorOpen()
        let r = renderer(cab)
        var t = await tick(r, from: 1, through: 2.8)
        let start = cab.camera.position
        // A short drag, released: part way toward the doorway, then back.
        #expect(cab.controller.beginThresholdScrub(forward: true))
        cab.controller.updateThresholdScrub(cells: 0.05)
        let a = cab.camera.position
        cab.controller.updateThresholdScrub(cells: 0.1)
        let b = cab.camera.position
        #expect(b.z > a.z && a.z > start.z)                                   // (north cab: out is +z), during the drag
        cab.controller.endThresholdScrub(commit: false)
        t = await tick(r, from: t, through: t + 1.5) { !cab.controller.isAnimating }
        _ = await tick(r, from: t, through: t + 0.2)
        #expect(abs(cab.camera.position.z - start.z) < 0.001)
        #expect(cab.controller.isElevatorRideInProgress)                       // (still aboard)
        // A longer drag, released: on out from where it is -- no jump at the release.
        #expect(cab.controller.beginThresholdScrub(forward: true))
        cab.controller.updateThresholdScrub(cells: 0.3)
        let held = cab.camera.position
        #expect(held.z > start.z + 0.5)
        cab.controller.endThresholdScrub(commit: true)
        #expect(SCNVector3EqualToVector3(held, cab.camera.position))
        t = await tick(r, from: t + 0.225, through: t + 15) { !cab.controller.isElevatorRideInProgress && !cab.controller.isAnimating }
        #expect(abs(cab.camera.position.x) < 0.0001 && abs(cab.camera.position.z) < 0.0001)
        // Backing in, continuously too.
        #expect(cab.controller.beginThresholdScrub(forward: false))
        cab.controller.updateThresholdScrub(cells: 0.2)
        #expect(cab.camera.position.z < -0.5)                                 // (into the north cab: -z)
        cab.controller.endThresholdScrub(commit: true)
        _ = await tick(r, from: t, through: t + 8) { cab.controller.isElevatorRideInProgress && !cab.controller.isAnimating }
        #expect(cab.controller.elevatorAwaitingEntryDirection == .south)
    }

    /// The rule itself: the way walked (where the player looks, or away from it)
    /// within 60 degrees of the way through the doorway; doors open; nothing busy.
    @Test func theRule() {
        typealias C = TapNavigationController
        let north = Direction.north, south = Direction.south
        // Inside a north-mounted cab, the way out is south.
        #expect(C.thresholdCrossing(yaw: south.yaw, forward: true, insideExit: south, exitPermitted: true,
                                    atElevatorCell: true, mount: north, doorsOpen: true, busy: false) == .exit)
        #expect(C.thresholdCrossing(yaw: north.yaw, forward: false, insideExit: south, exitPermitted: true,
                                    atElevatorCell: true, mount: north, doorsOpen: true, busy: false) == .exit)   // backing out
        #expect(C.thresholdCrossing(yaw: north.yaw, forward: true, insideExit: south, exitPermitted: true,
                                    atElevatorCell: true, mount: north, doorsOpen: true, busy: false) == nil)     // into the back wall
        #expect(C.thresholdCrossing(yaw: south.yaw + 0.9, forward: true, insideExit: south, exitPermitted: true,
                                    atElevatorCell: true, mount: north, doorsOpen: true, busy: false) == .exit)   // 52 degrees off: still out
        #expect(C.thresholdCrossing(yaw: south.yaw + 1.2, forward: true, insideExit: south, exitPermitted: true,
                                    atElevatorCell: true, mount: north, doorsOpen: true, busy: false) == nil)     // 69 degrees: no
        #expect(C.thresholdCrossing(yaw: south.yaw, forward: true, insideExit: south, exitPermitted: false,
                                    atElevatorCell: true, mount: north, doorsOpen: true, busy: false) == nil)     // doors not open yet
        // Outside, at the elevator's cell.
        #expect(C.thresholdCrossing(yaw: south.yaw, forward: false, insideExit: nil, exitPermitted: false,
                                    atElevatorCell: true, mount: north, doorsOpen: true, busy: false) == .enter)  // backing in
        #expect(C.thresholdCrossing(yaw: north.yaw, forward: true, insideExit: nil, exitPermitted: false,
                                    atElevatorCell: true, mount: north, doorsOpen: true, busy: false) == .enter)  // walking in
        #expect(C.thresholdCrossing(yaw: south.yaw, forward: false, insideExit: nil, exitPermitted: false,
                                    atElevatorCell: true, mount: north, doorsOpen: false, busy: false) == nil)    // shut doors
        #expect(C.thresholdCrossing(yaw: south.yaw, forward: false, insideExit: nil, exitPermitted: false,
                                    atElevatorCell: false, mount: north, doorsOpen: true, busy: false) == nil)    // not at the elevator
        #expect(C.thresholdCrossing(yaw: south.yaw, forward: false, insideExit: nil, exitPermitted: false,
                                    atElevatorCell: true, mount: north, doorsOpen: true, busy: true) == nil)      // mid-animation / ride
    }
}
