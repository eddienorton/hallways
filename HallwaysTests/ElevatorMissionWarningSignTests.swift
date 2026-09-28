import Testing
import SceneKit
@testable import Hallways

@MainActor
struct ElevatorMissionWarningSignTests {
    @Test(arguments: ["Please extinguish all fires before using the elevator.",
                      String(repeating: "A longer future mission instruction with several requirements. ", count: 30),
                      String(repeating: "W", count: 180)])
    func completeTextFits(instruction: String) {
        let layout = ElevatorMissionWarningSign.layout(.init(headline: "MISSION IN PROGRESS", instruction: instruction,
                                                             status: "Fires remaining: 999"))
        #expect(layout.bounds.width <= layout.available.width)
        #expect(layout.bounds.height <= layout.available.height)
        #expect(layout.origin.y + layout.bounds.minY >= layout.available.minY)
        #expect(layout.origin.y + layout.bounds.maxY <= layout.available.maxY + 0.001)
        #expect(layout.manager.glyphRange(for: layout.container).length == layout.manager.numberOfGlyphs)
        #expect(layout.storage.string.contains(instruction))
    }

    @Test(arguments: Direction.allCases)
    func signIsGroundedInsideElevatorCell(direction: Direction) {
        let sign = ElevatorMissionWarningSign()
        let door = SCNVector3(Float(direction.delta.col) * 1.68, 1.025, Float(direction.delta.row) * 1.68)
        sign.place(left: door, right: door, direction: direction, cellSize: 3.2)
        #expect(sign.node.position.y == 0)
        #expect(abs(sign.node.position.x) <= 0.84)
        #expect(abs(sign.node.position.z) <= 0.84)
        let front = sign.node.convertVector(SCNVector3(0, 0, 1), to: nil)
        #expect(abs(front.x + Float(direction.delta.col)) < 0.001)
        #expect(abs(front.z + Float(direction.delta.row)) < 0.001)
        sign.node.enumerateChildNodes { node, _ in
            #expect(DecoratorTarget.read(node) == nil)
            #expect(node.physicsBody == nil)
        }
    }

    @Test func liveMissionChangesOwnTheSign() {
        let scene = SCNScene(), camera = SCNNode(), left = SCNNode(), right = SCNNode()
        let cell = GridCoordinate(row: 0, col: 0)
        let fire = GridCoordinate(row: 1, col: 0)
        let controller = TapNavigationController(cameraNode: camera, scene: scene, cells: [cell, fire],
            cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            elevatorLeftDoor: left, elevatorRightDoor: right, elevatorMountDirection: .north,
            floorNumber: 5, fires: [fire])
        let original = scene.rootNode.childNode(withName: "systemElevatorMissionSign", recursively: false)
        #expect(original != nil) // Exists before any rejection.
        controller.openElevator()
        #expect(controller.elevatorRejected != nil)
        #expect(scene.rootNode.childNode(withName: "systemElevatorMissionSign", recursively: false) === original)
        controller.unregisterFire(at: fire)
        #expect(controller.isMissionComplete)
        #expect(original?.parent == nil)
        controller.registerFire(at: fire, node: SCNNode())
        #expect(!controller.isMissionComplete)
        #expect(scene.rootNode.childNode(withName: "systemElevatorMissionSign", recursively: false) != nil)
    }

    @Test func winningMissionRemovesSignAndResetRestoresIt() {
        let scene = SCNScene(), camera = SCNNode()
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: camera, scene: scene, cells: [cell],
            cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            elevatorLeftDoor: SCNNode(), elevatorRightDoor: SCNNode(), elevatorMountDirection: .north,
            floorNumber: 7, ticTacToeTerminals: [cell: .south])
        #expect(scene.rootNode.childNode(withName: "systemElevatorMissionSign", recursively: false) != nil)
        controller.activateTicTacToeTerminal(at: cell)
        controller.completeTicTacToeTerminal(at: cell)
        #expect(controller.isMissionComplete)
        #expect(scene.rootNode.childNode(withName: "systemElevatorMissionSign", recursively: false) == nil)
        controller.reset()
        #expect(!controller.isMissionComplete)
        #expect(scene.rootNode.childNode(withName: "systemElevatorMissionSign", recursively: false) != nil)
    }

    @Test(arguments: [1, 2])
    func arrivalContinuesOneGridCellOnlyOnMissionFloors(floor: Int) async {
        let scene = SCNScene(), camera = SCNNode(), left = SCNNode(), right = SCNNode()
        let cells = Set((0...3).map { GridCoordinate(row: $0, col: 0) })
        let start = GridCoordinate(row: 0, col: 0)
        camera.position = SCNVector3(0, 1.6, 0)
        [camera, left, right].forEach { scene.rootNode.addChildNode($0) }
        let controller = TapNavigationController(cameraNode: camera, scene: scene, cells: cells,
            cellSize: 3.2, startCell: start, startFacing: .south, endCell: start,
            elevatorLeftDoor: left, elevatorRightDoor: right, elevatorMountDirection: .north,
            floorNumber: floor, fires: [GridCoordinate(row: 3, col: 0)])
        controller.presentArrivalInsideElevator(preservedYaw: nil)
        #expect(scene.rootNode.childNode(withName: "systemElevatorMissionSign", recursively: false) == nil)
        // A mission update inside the cab must not reveal the sign early.
        controller.registerFire(at: GridCoordinate(row: 3, col: 0), node: SCNNode())
        #expect(scene.rootNode.childNode(withName: "systemElevatorMissionSign", recursively: false) == nil)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.delegate = controller
        renderer.update(atTime: 1)
        controller.advance()
        #expect(scene.rootNode.childNode(withName: "systemElevatorMissionSign", recursively: false) == nil)
        for i in 1...240 {
            renderer.update(atTime: 1 + Double(i) * 0.025)
            await Task.yield()
        }
        #expect(controller.currentCell == GridCoordinate(row: floor == 1 ? 0 : 1, col: 0))
        #expect(abs(camera.position.z - (floor == 1 ? 0 : 3.2)) < 0.001)
        #expect(!controller.isAnimating)
        #expect(scene.rootNode.childNode(withName: "systemElevatorMissionSign", recursively: false) != nil)
    }
}
