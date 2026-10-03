import Testing
import SceneKit
@testable import Hallways

/// Oct 2 (beta: Carol, iPhone 15 Plus): after a ride the arrival curtain
/// opened while the destination controller was still unpublished, so a
/// controlled arrival's real doors never opened ("doors closed, froze").
@MainActor struct ElevatorArrivalCurtainTests {
    private func controller() -> TapNavigationController {
        TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: [GridCoordinate(row: 0, col: 0)],
            cellSize: 3.52, startCell: GridCoordinate(row: 0, col: 0), startFacing: .north,
            endCell: GridCoordinate(row: 0, col: 0))
    }

    @Test func curtainWaitsForTheDestinationControllerNotJustTheScene() {
        let bridge = NavigationBridge()
        #expect(!bridge.arrivalReadyToOpen)
        // makeUIView: arrival presented synchronously...
        bridge.arrivalSceneReady = true
        // ...but `controller` is only published on the next main-queue hop.
        #expect(!bridge.arrivalReadyToOpen)
        bridge.controller = controller()
        #expect(bridge.arrivalReadyToOpen)
    }

    @Test func aStaleControllerCannotOpenTheNextArrival() {
        let bridge = NavigationBridge()
        bridge.controller = controller()
        // onReachedEnd / onElevatorArrivedControlled: new ride begins.
        bridge.arrivalSceneReady = false
        bridge.controller = nil
        #expect(!bridge.arrivalReadyToOpen)
    }

    // MARK: Oct 2, second report: PASSIVE ride stuck behind the curtain

    typealias D = NavigationBridge.ArrivalCurtainDecision
    private func decide(_ controlled: Bool, scene: Bool, controller: Bool, _ elapsed: Double) -> D {
        NavigationBridge.arrivalCurtainDecision(controlled: controlled, sceneReady: scene,
                                               controllerReady: controller, elapsed: elapsed)
    }

    @Test func passiveArrivalOpensOnTheSceneAloneWithoutTheController() {
        #expect(decide(false, scene: false, controller: false, 0.5) == .wait)
        #expect(decide(false, scene: true, controller: false, 0.5) == .open)   // Carol's case: no hang
        #expect(decide(false, scene: true, controller: true, 0.5) == .open)
    }

    @Test func controlledArrivalStillWaitsForSceneAndController() {
        #expect(decide(true, scene: true, controller: false, 0.5) == .wait)     // Build 3 protection kept
        #expect(decide(true, scene: false, controller: true, 0.5) == .wait)
        #expect(decide(true, scene: true, controller: true, 0.5) == .open)
    }

    @Test func neitherPathCanWaitPastTheTimeout() {
        let t = NavigationBridge.arrivalCurtainTimeout
        #expect(t == 3)
        #expect(decide(false, scene: false, controller: false, t - 0.01) == .wait)
        #expect(decide(false, scene: false, controller: false, t) == .openAfterTimeout)
        #expect(decide(true, scene: true, controller: false, t + 1) == .openAfterTimeout)
        #expect(decide(true, scene: false, controller: false, 60) == .openAfterTimeout)
    }

    @Test func controlledDoorOpenIsDeferredNotLostWhenTheControllerIsMissing() {
        let bridge = NavigationBridge()
        bridge.deliverControlledArrivalDoorOpen()           // timeout fired, no controller yet
        #expect(bridge.pendingControlledDoorOpen)
        bridge.controller = controller()                    // makeUIView publishes it...
        bridge.deliverControlledArrivalDoorOpen()           // ...and delivers the pending request
        #expect(!bridge.pendingControlledDoorOpen)
    }
}
