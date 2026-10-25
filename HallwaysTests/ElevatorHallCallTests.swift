import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 22 -- CALLING THE CAR FROM THE HALL. The doors frame the call panel (no
/// call); UP / DOWN make the call and light; only the directions a floor has.
@MainActor
struct ElevatorHallCallTests {
    @Test func onlyTheDirectionsAFloorHas() {
        let building = Set(1...16)
        #expect(TapNavigationController.hallCallDirections(floor: 1, reachable: building) == [1])       // (the lobby: up only)
        #expect(TapNavigationController.hallCallDirections(floor: 16, reachable: building) == [-1])     // (the top: down only)
        #expect(TapNavigationController.hallCallDirections(floor: 2, reachable: building) == [1, -1])
        #expect(TapNavigationController.hallCallDirections(floor: 7, reachable: building) == [1, -1])
        #expect(TapNavigationController.hallCallDirections(floor: 5, reachable: []) == [1, -1])         // (not known yet: both)
    }

    /// A hall with its elevator front (HallwayScene's names) on the north wall.
    private func hall() -> (TapNavigationController, SCNScene) {
        let scene = SCNScene()
        let camera = SCNNode()
        camera.position = SCNVector3(0, 1.6, 0.4)
        scene.rootNode.addChildNode(camera)
        let left = SCNNode(), right = SCNNode()
        left.position = SCNVector3(-0.24, 1.3, -1.84)
        right.position = SCNVector3(0.24, 1.3, -1.84)
        scene.rootNode.addChildNode(left)
        scene.rootNode.addChildNode(right)
        let panel = SCNNode(geometry: SCNBox(width: 0.2, height: 0.54, length: 0.04, chamferRadius: 0))
        panel.name = "elevatorExteriorCallPanel"
        panel.position = SCNVector3(0.71, 1.28, -1.66)
        for (y, name) in [(Float(0.11), "elevatorExteriorUpButton"), (Float(-0.11), "elevatorExteriorDownButton")] {
            let b = SCNNode(geometry: SCNCylinder(radius: 0.046, height: 0.012))
            b.name = name
            b.position = SCNVector3(0, y, 0.056)
            panel.addChildNode(b)
        }
        scene.rootNode.addChildNode(panel)
        let cell = GridCoordinate(row: 0, col: 0)
        let c = TapNavigationController(cameraNode: camera, scene: scene, cells: [cell, GridCoordinate(row: 1, col: 0)],
                                        cellSize: 3.52, startCell: cell, startFacing: .north, endCell: cell,
                                        elevatorLeftDoor: left, elevatorRightDoor: right, elevatorMountDirection: .north, floorNumber: 1)
        c.elevatorReachableFloors = Set(1...16)
        return (c, scene)
    }

    @Test func theLobbyHasNoDownButtonAndTappingTheDoorsCallsNothing() {
        let (c, scene) = hall()
        c.frameHallCallButtons()                                                    // (the doors tapped)
        #expect(c.hallCallLit.isEmpty)                                              // no call, nothing lit
        let down = scene.rootNode.childNode(withName: "elevatorExteriorDownButton", recursively: true)
        let up = scene.rootNode.childNode(withName: "elevatorExteriorUpButton", recursively: true)
        #expect(down?.isHidden == true)                                             // (the lobby: no DOWN)
        #expect(up?.isHidden == false)
    }

    @Test func aPressLightsItsButtonAndASecondPressChangesNothing() {
        let (c, _) = hall()
        c.pressHallCall(1)
        #expect(c.hallCallLit == [1])
        c.pressHallCall(1)                                                          // (again: the call stands, nothing restarts)
        #expect(c.hallCallLit == [1])
        c.pressHallCall(-1)                                                         // (the lobby has no DOWN: still just UP)
        #expect(c.hallCallLit == [1])
    }
}
