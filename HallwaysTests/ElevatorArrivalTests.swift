import Testing
import SceneKit
@testable import Hallways

@MainActor
struct ElevatorArrivalTests {
    private func arrival() -> TapNavigationController {
        let cell = GridCoordinate(row: 11, col: 7)
        let camera = SCNNode()
        camera.position = SCNVector3(22.4, 1.6, 35.2)
        return TapNavigationController(cameraNode: camera, scene: SCNScene(), cells: [cell],
            cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            elevatorLeftDoor: SCNNode(), elevatorRightDoor: SCNNode(),
            elevatorMountDirection: .north, floorNumber: 2)
    }

    @Test func rideLookReleasePreservesCameraAndGeometry() {
        let controller = arrival()
        controller.openElevator() // Establish an active ride without running its timers.
        #expect(controller.isElevatorRideInProgress)
        let camera = controller.cameraNode
        camera.position = SCNVector3(22.4, 1.6, 32.06)
        let parked = camera.position
        controller.beginElevatorCameraDrag()
        controller.updateElevatorCameraDrag(fraction: 0.37)
        let yaw = camera.eulerAngles.y
        let keys = camera.actionKeys
        controller.endElevatorCameraDrag()
        #expect(!controller.isAnimating)
        #expect(camera.actionKeys == keys)
        let renderer = SCNRenderer(device: nil, options: nil)
        for i in 1...40 { controller.renderer(renderer, updateAtTime: Double(i) * 0.025) }
        #expect(camera.eulerAngles.y == yaw)
        #expect(SCNVector3EqualToVector3(camera.position, parked))
        #expect(controller.isElevatorRideInProgress)
    }

    @Test func arrivalWaitsAndGridRendererDoesNotOverwriteExplicitWalkOut() {
        let controller = arrival()
        controller.presentArrivalInsideElevator(preservedYaw: nil)
        let parked = controller.cameraNode.position
        let renderer = SCNRenderer(device: nil, options: nil)
        controller.renderer(renderer, updateAtTime: 1)
        controller.renderer(renderer, updateAtTime: 1.025)
        #expect(SCNVector3EqualToVector3(controller.cameraNode.position, parked))
        #expect(!controller.isAnimating)
        controller.advance()
        #expect(controller.isAnimating)
        #expect(controller.cameraNode.hasActions)
        // Advance ONLY the grid renderer: SceneKit owns the scripted action.
        // It must not replace the action's position with stale/zero grid data.
        controller.renderer(renderer, updateAtTime: 1.05)
        print("[ARRIVAL REPRO] parked=\(parked) afterGridTick=\(controller.cameraNode.position)")
        #expect(SCNVector3EqualToVector3(controller.cameraNode.position, parked))
        controller.cameraNode.removeAllActions()
    }
    @Test(arguments: [false, true])
    func passiveAndControlledArrivalsStayPutThroughIdleAndTurning(controlled: Bool) async {
        let controller = arrival()
        controller.presentArrivalInsideElevator(preservedYaw: controlled ? Direction.east.yaw : nil)
        let parked = controller.cameraNode.position
        #expect(controller.facing == (controlled ? .east : .south))
        #expect(controller.canGoForward == !controlled)
        let renderer = SCNRenderer(device: nil, options: nil)
        for i in 1...160 { controller.renderer(renderer, updateAtTime: Double(i) * 0.025) }
        #expect(!controller.isAnimating)
        #expect(!controller.cameraNode.hasActions)
        #expect(SCNVector3EqualToVector3(controller.cameraNode.position, parked))
        controller.beginDragRotate()
        controller.updateDragRotate(fraction: 0.5)
        controller.endDragRotate(fraction: 0.5)
        for i in 161...180 { controller.renderer(renderer, updateAtTime: Double(i) * 0.025) }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(!controller.isAnimating)
        #expect(SCNVector3EqualToVector3(controller.cameraNode.position, parked))
    }

    @Test(arguments: [false, true])
    func manualExitUsesWalkingSpeedAndTapOrHeldEasing(held: Bool) throws {
        let controller = arrival()
        controller.presentArrivalInsideElevator(preservedYaw: nil)
        controller.setWalkingHeld(held)
        controller.advance()
        let action = try #require(controller.cameraNode.action(forKey: "elevatorManualWalkOut"))
        #expect(abs(action.duration - 3.14 / 6.0) < 0.00001)
        let timing = try #require(action.timingFunction)
        #expect(abs(timing(0.25) - (held ? 0.25 : 0.15625)) < 0.00001)
        #expect(SoundEffects.walkingRate == 1)
        controller.cameraNode.removeAllActions()
        SoundEffects.stopWalking()
    }


    @Test(arguments: [false, true], [false, true])
    func exitClosesDoorsAndReturnUsesMissionGate(locked: Bool, controlled: Bool) async {
        let cell = GridCoordinate(row: 11, col: 7)
        let camera = SCNNode(), left = SCNNode(), right = SCNNode()
        camera.position = SCNVector3(22.4, 1.6, 35.2)
        left.position = SCNVector3(22.16, 1.3, 33.6)
        right.position = SCNVector3(22.64, 1.3, 33.6)
        let leftClosed = left.position, rightClosed = right.position
        let scene = SCNScene()
        [camera, left, right].forEach { scene.rootNode.addChildNode($0) }
        let controller = TapNavigationController(cameraNode: camera, scene: scene, cells: [cell],
            cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            objects: locked ? [GridCoordinate(row: 12, col: 7): .trashCan] : [:],
            elevatorLeftDoor: left, elevatorRightDoor: right, elevatorMountDirection: .north,
            elevatorButtonNodes: [3: SCNNode()], floorNumber: 2, nextFloorNumber: 3,
            missionObjectKind: locked ? .trashCan : nil)
        controller.presentArrivalInsideElevator(preservedYaw: controlled ? Direction.south.yaw : nil)
        if controlled { controller.playControlledArrivalDoorOpen() }
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.delegate = controller
        var time = 1.0
        func tick(_ count: Int) async {
            for _ in 0..<count {
                time += 0.025
                renderer.update(atTime: time)
                await Task.yield()
            }
        }
        renderer.update(atTime: time)
        controller.advance() // Also tests exiting before controlled doors finish opening.
        await tick(100)
        #expect(!controller.isAnimating)
        #expect(abs(camera.position.z - 35.2) < 0.0001)
        #expect(SCNVector3EqualToVector3(left.position, leftClosed))
        #expect(SCNVector3EqualToVector3(right.position, rightClosed))
        controller.playControlledArrivalDoorOpen() // A late curtain callback must not reopen it.
        #expect(!left.hasActions && !right.hasActions)
        controller.rotate(toward: .north)
        await tick(20)
        #expect(!controller.canReenterArrivedElevator)
        #expect(controller.isMissionComplete == !locked)
        controller.openElevator()
        if locked {
            #expect(controller.elevatorRejected != nil)
            #expect(!left.hasActions && !right.hasActions)
            #expect(controller.canRotate)
        } else {
            #expect(left.hasActions && right.hasActions)
            #expect(!controller.canRotate) // Fresh boarding/travel owns the interaction.
        }
        left.removeAllActions(); right.removeAllActions()
        SoundEffects.stopWalking()
    }
}
