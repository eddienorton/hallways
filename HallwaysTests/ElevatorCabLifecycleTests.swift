import Testing
import SceneKit
@testable import Hallways

@MainActor
struct ElevatorCabLifecycleTests {
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

    private func tick(_ renderer: SCNRenderer, from start: Double, through end: Double) async {
        var t = start
        while t <= end {
            renderer.update(atTime: t)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            t += 0.025
        }
    }

    @Test(arguments: Direction.allCases)
    func arrivalKeepsCabRelativePoseAndLiveLook(direction: Direction) {
        let cab = Cab(direction: direction)
        let offset = SIMD2<Double>(0.5, -0.6)
        cab.controller.presentArrivalInsideElevator(preservedYaw: 0.73, offset: offset)
        let p = cab.camera.position
        let d = direction.delta
        let depth = Float(HallwayScene.ElevatorGeometry(cellSize: 3.2).entryDistance)
        #expect(abs(p.x - (depth * Float(d.col) + Float(offset.x * Double(d.col) - offset.y * Double(d.row)))) < 0.0001)
        #expect(abs(p.z - (depth * Float(d.row) + Float(offset.x * Double(d.row) + offset.y * Double(d.col)))) < 0.0001)
        let yaw = cab.camera.eulerAngles.y
        #expect(abs(Double(yaw) - direction.opposite.yaw - 0.73) < 0.0001)
        #expect(cab.controller.isElevatorRideInProgress)
        #expect(cab.controller.canRotate) // Preserve Decorator's existing selection gate.
        cab.controller.rotate(toward: direction)
        cab.controller.beginDragRotate()
        #expect(!cab.controller.isAnimating) // Grid rotation cannot own the cab camera.
        cab.controller.beginElevatorCameraDrag()
        cab.controller.updateElevatorCameraDrag(fraction: 0.4)
        cab.controller.endElevatorCameraDrag()
        #expect(abs(cab.camera.eulerAngles.y - yaw - Float(0.4 * Double.pi / 2)) < 0.0001)
        #expect(SCNVector3EqualToVector3(p, cab.camera.position))
        cab.controller.playControlledArrivalDoorOpen()
        #expect(!cab.camera.hasActions)
    }

    /// Oct 7 (Annette, Build 10): staying aboard no longer closes the
    /// doors on a timer -- they stay open, the way out stays live.
    @Test func stayingAboardKeepsTheDoorsOpen() async {
        let cab = Cab()
        let closed = cab.right.position
        cab.controller.presentArrivalInsideElevator(preservedYaw: 1.17, offset: SIMD2(0.4, 0.7))
        cab.controller.playControlledArrivalDoorOpen()
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = cab.scene
        renderer.delegate = cab.controller
        await tick(renderer, from: 1, through: 10)
        #expect(cab.right.position.x > closed.x + 0.7)
        await tick(renderer, from: 10.025, through: 30)
        #expect(cab.right.position.x > closed.x + 0.7)
        #expect(!cab.controller.isElevatorWaitingForFloor)
        #expect(cab.controller.elevatorDestinationFloor == nil)
        #expect(cab.controller.isElevatorRideInProgress)
        #expect(cab.controller.canGoForward)
        #expect(cab.controller.canStartElevatorExit)
        #expect(cab.controller.elevatorDoorsOpenIdle)
        let yaw = cab.camera.eulerAngles.y
        cab.controller.beginElevatorCameraDrag()
        cab.controller.updateElevatorCameraDrag(fraction: -0.3)
        #expect(cab.camera.eulerAngles.y != yaw)
        cab.controller.endElevatorCameraDrag()
    }

    @Test func explicitExitTurnsWhileMovingAndCancelsDwell() async {
        let cab = Cab()
        cab.controller.presentArrivalInsideElevator(preservedYaw: 1.5, offset: SIMD2(0.3, 0.7))
        cab.controller.playControlledArrivalDoorOpen()
        let yaw = cab.camera.eulerAngles.y, p = cab.camera.position
        #expect(!cab.controller.canGoForward)
        cab.controller.advance() // Closed/opening doors reject an early tap.
        #expect(!cab.controller.isAnimating)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = cab.scene
        renderer.delegate = cab.controller
        await tick(renderer, from: 1, through: 2.8)
        #expect(cab.controller.canGoForward)
        cab.controller.advance()
        #expect(cab.camera.eulerAngles.y == yaw) // No immediate snap.
        await tick(renderer, from: 2.825, through: 3.1)
        #expect(cab.camera.eulerAngles.y != yaw)
        #expect(!SCNVector3EqualToVector3(cab.camera.position, p))
        await tick(renderer, from: 3.125, through: 15)
        #expect(abs(cab.camera.position.x) < 0.0001 && abs(cab.camera.position.z) < 0.0001)
        #expect(!cab.controller.isElevatorRideInProgress)
        #expect(!cab.controller.isElevatorWaitingForFloor)
        #expect(!cab.controller.isAnimating)
        #expect(cab.controller.elevatorAwaitingEntryDirection == nil)
    }

    @Test func playerLookWinsOverExitAlignment() async {
        let cab = Cab()
        cab.controller.presentArrivalInsideElevator(preservedYaw: 1.5)
        #expect(!cab.controller.canStartElevatorExit)
        cab.controller.advanceWhileHeld()
        #expect(!cab.controller.isAnimating)
        cab.controller.playControlledArrivalDoorOpen()
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = cab.scene
        renderer.delegate = cab.controller
        await tick(renderer, from: 1, through: 2.8)
        cab.controller.advance()
        cab.controller.beginElevatorCameraDrag()
        cab.controller.updateElevatorCameraDrag(fraction: 0.2)
        cab.controller.endElevatorCameraDrag()
        let yaw = cab.camera.eulerAngles.y
        await tick(renderer, from: 2.825, through: 5)
        #expect(cab.camera.eulerAngles.y == yaw)
        #expect(abs(cab.camera.position.z) < 0.0001)
    }

    @Test func rearmedPanelAcceptsAnotherTripWithoutMovingTheRider() async throws {
        let cab = Cab()
        let plate = SCNNode(geometry: SCNBox(width: 0.5, height: 0.8, length: 0.02, chamferRadius: 0))
        plate.name = "elevatorControlPanel"
        plate.position = SCNVector3(1, 1.5, -3.14)
        cab.scene.rootNode.addChildNode(plate)
        for (floor, x) in [(5, Float(-0.1)), (12, Float(0.1))] {
            let cap = SCNNode(geometry: SCNSphere(radius: 0.04))
            cap.name = "elevatorControlButton_\(floor)"
            cap.position = SCNVector3(x, 0, -0.04)
            cap.geometry?.firstMaterial?.diffuse.contents = UIColor(white: 0.82, alpha: 1)
            plate.addChildNode(cap)
        }
        func hits(x: Float, y: Float = 0) -> [SCNHitTestResult] {
            cab.scene.rootNode.hitTestWithSegment(
                from: plate.convertPosition(SCNVector3(x, y, -1), to: nil),
                to: plate.convertPosition(SCNVector3(x, y, 0.1), to: nil), options: nil)
        }
        cab.controller.presentArrivalInsideElevator(preservedYaw: 0.81, offset: SIMD2(0.3, -0.6))
        cab.controller.playControlledArrivalDoorOpen()
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = cab.scene
        renderer.delegate = cab.controller
        await tick(renderer, from: 1, through: 14)
        let p = cab.camera.position, yaw = cab.camera.eulerAngles.y
        let closed: Float = 0.24 // Cab's right door, shut.
        // Oct 7: the doors are still open -- the panel is live anyway.
        #expect(cab.controller.elevatorDoorsOpenIdle)
        #expect(cab.controller.pressElevatorButton(hits: hits(x: 0.1)))
        #expect(cab.controller.elevatorDoorsOpenIdle) // Current floor only clicks.
        #expect(cab.controller.elevatorDestinationFloor == nil)
        #expect(cab.controller.pressElevatorButton(hits: hits(x: 0, y: 0.3)))
        // Oct 8: a miss on the plate glides square-on to the panel (the
        // boarding glide), choosing nothing.
        let align = try #require(cab.camera.action(forKey: "elevatorPanelApproach"))
        // Oct 8: at the standard wall-landing pace (cell 3.2 m / 6 m/s), not
        // the boarding glide's 1.6 s.
        #expect(align.duration >= 3.2 / 6 - 1e-9 && align.duration < 1.0)
        #expect(cab.controller.elevatorDestinationFloor == nil)
        #expect(cab.controller.elevatorDoorsOpenIdle)
        #expect(cab.controller.pressElevatorButton(hits: hits(x: -0.1)))
        #expect(!cab.controller.elevatorDoorsOpenIdle)
        #expect(!cab.controller.canGoForward) // No walking through closing doors.
        #expect(cab.controller.elevatorDestinationFloor == nil) // Departs once shut.
        await tick(renderer, from: 14.025, through: 16)
        #expect(abs(cab.right.position.x - closed) < 0.0001)
        #expect(cab.controller.elevatorDestinationFloor == 5)
        #expect(!cab.controller.isElevatorWaitingForFloor)
        #expect(SCNVector3EqualToVector3(p, cab.camera.position))
        #expect(cab.camera.eulerAngles.y == yaw)
        var arrivalYaw: Double?
        cab.controller.onElevatorArrivedControlled = { arrivalYaw = $0 }
        // Real dispatch clock exercises the actual departure/handoff chain.
        cab.controller.beginElevatorCameraDrag()
        cab.controller.updateElevatorCameraDrag(fraction: 0.3)
        cab.controller.endElevatorCameraDrag()
        let chosenYaw = cab.camera.eulerAngles.y
        // All digits have been assigned, but handoff must wait for an actual
        // rendered destination-number frame, not another fixed travel timer.
        try await Task.sleep(for: .seconds(4.2))
        #expect(arrivalYaw == nil)
        cab.camera.camera = SCNCamera()
        renderer.pointOfView = cab.camera
        _ = renderer.snapshot(atTime: 20, with: CGSize(width: 32, height: 32), antialiasingMode: .none)
        try await Task.sleep(for: .milliseconds(100))
        #expect(arrivalYaw != nil)
        #expect(abs((arrivalYaw ?? 0) - (Double(chosenYaw) - Direction.south.yaw)) < 0.0001)
        #expect(cab.camera.eulerAngles.y == chosenYaw)
        #expect(SCNVector3EqualToVector3(p, cab.camera.position))
        #expect(abs((cab.controller.elevatorArrivalOffset?.x ?? 0) - 0.3) < 0.0001)
        #expect(abs((cab.controller.elevatorArrivalOffset?.y ?? 0) + 0.6) < 0.0001)
    }

    @Test func allSixteenDestinationLampsStartNeutral() throws {
        let cell = GridCoordinate(row: 0, col: 0)
        let result = HallwayScene.build(fromMaze: [cell], cellSize: 3.2, wallHeight: 3,
            floorNumber: 12, totalFloors: 16, playerStart: cell, playerEnd: cell)
        let plate = try #require(result.scene.rootNode.childNode(withName: "elevatorControlPanel", recursively: true))
        for floor in 1...16 {
            let cap = try #require(plate.childNode(withName: "elevatorControlButton_\(floor)", recursively: false))
            let color = try #require(cap.geometry?.firstMaterial?.diffuse.contents as? UIColor)
            #expect(color == UIColor(white: 0.82, alpha: 1))
        }
    }
}
