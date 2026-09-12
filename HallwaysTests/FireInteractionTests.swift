import Testing
import SceneKit
import AVFoundation
@testable import Hallways

@MainActor
struct FireInteractionTests {
    private func pump(_ controller: TapNavigationController, _ renderer: SCNRenderer, time: inout Double, seconds: Double = 1.5) async {
        for _ in 0..<Int(seconds / 0.05) {
            time += 0.05
            controller.renderer(renderer, updateAtTime: time)
            _ = renderer.snapshot(atTime: time, with: CGSize(width: 32, height: 32), antialiasingMode: .none)
            await Task.yield()
        }
    }

    @Test func directFloorFiveStartsEmptyAndMapsActualGeometry() throws {
        let store = MazeStore()
        store.switchTo(id: 5)
        let start = try #require(store.startCoordinate)
        let built = HallwayScene.build(fromMaze: store.cells, cellSize: store.cellSize, wallHeight: store.wallHeight,
            fires: store.fires, extinguishers: store.extinguishers, floorNumber: 5, playerStart: start, playerEnd: start)
        let controller = TapNavigationController(cameraNode: built.cameraNode, scene: built.scene, cells: store.cells,
            cellSize: store.cellSize, startCell: start, startFacing: .south, endCell: start,
            fires: store.fires, fireNodes: built.fireNodes, extinguishers: store.extinguishers, extinguisherNodes: built.extinguisherNodes)
        #expect(!controller.carryingExtinguisher)
        #expect(controller.collectedObjects.isEmpty)
        #expect(controller.carriedMail.isEmpty)
        #expect(controller.paintProgress == nil)
        #expect(!controller.isMissionComplete)
        for (coord, node) in built.extinguisherNodes {
            #expect(node.parent != nil)
            for child in node.childNodes { #expect(controller.extinguisherCoordinate(for: child) == coord) }
        }
        for (coord, node) in built.fireNodes {
            for child in node.childNodes { #expect(controller.fireCoordinate(for: child) == coord) }
        }
        controller.reset()
        #expect(!controller.carryingExtinguisher)
    }

    @Test func pickupThenRepeatedFireUseAndReset() async {
        let start = GridCoordinate(row: 0, col: 0)
        let wall = GridCoordinate(row: 0, col: 1)
        let first = GridCoordinate(row: 0, col: 3)
        let second = GridCoordinate(row: 0, col: 4)
        let cells = Set((0...4).map { GridCoordinate(row: 0, col: $0) })
        let built = HallwayScene.build(fromMaze: cells, cellSize: 3.2, wallHeight: 3,
            fires: [first, second], extinguishers: [wall: .north], floorNumber: 5, playerStart: start, playerEnd: start)
        let controller = TapNavigationController(cameraNode: built.cameraNode, scene: built.scene, cells: cells,
            cellSize: 3.2, startCell: start, startFacing: .east, endCell: start,
            fires: [first, second], fireNodes: built.fireNodes, extinguishers: [wall: .north], extinguisherNodes: built.extinguisherNodes)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = built.scene; renderer.pointOfView = built.cameraNode
        var time = 0.0
        await pump(controller, renderer, time: &time, seconds: 0.1)
        #expect(!controller.extinguishFire(at: first)) // Out-of-range hit must fall through to walking.
        #expect(!controller.isMissionComplete)
        controller.advance()
        await pump(controller, renderer, time: &time, seconds: 3)
        #expect(controller.currentCell == wall)
        #expect(!controller.carryingExtinguisher) // Arrival itself does not pick it up.
        #expect(controller.pickUpExtinguisher(at: wall))
        #expect(!controller.carryingExtinguisher) // Ownership follows the animation.
        await pump(controller, renderer, time: &time)
        #expect(controller.carryingExtinguisher)
        #expect(built.extinguisherNodes[wall]?.parent == nil)
        #expect(controller.extinguisherAtCurrentCell == nil)
        #expect(!controller.pickUpExtinguisher(at: wall))
        controller.advance()
        await pump(controller, renderer, time: &time, seconds: 5)
        #expect(controller.currentCell == first)
        #expect(controller.extinguishFire(at: first))
        #expect(!controller.isMissionComplete)
        await pump(controller, renderer, time: &time)
        #expect(built.fireNodes[first]?.isHidden == true)
        #expect(controller.carryingExtinguisher)
        #expect(controller.extinguishFire(at: second)) // One cell ahead, without walking into flames.
        await pump(controller, renderer, time: &time)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.carryingExtinguisher)
        #expect(!controller.isMissionComplete)
        #expect(built.extinguisherNodes[wall]?.parent != nil)
        #expect(built.fireNodes[first]?.isHidden == false)
        #expect(controller.pickUpExtinguisher(at: wall)) // Reachable directly ahead.
        controller.reset() // Cancel before ownership transfers.
        await pump(controller, renderer, time: &time)
        #expect(!controller.carryingExtinguisher)
        #expect(built.extinguisherNodes[wall]?.parent != nil)
    }

    @Test func nearbyFireRequiresAnAcquiredExtinguisher() {
        let start = GridCoordinate(row: 0, col: 0), fire = GridCoordinate(row: 0, col: 1)
        let built = HallwayScene.build(fromMaze: [start, fire], cellSize: 3.2, wallHeight: 3,
            fires: [fire], floorNumber: 5, playerStart: start, playerEnd: start)
        let controller = TapNavigationController(cameraNode: built.cameraNode, scene: built.scene,
            cells: [start, fire], cellSize: 3.2, startCell: start, startFacing: .east, endCell: start,
            fires: [fire], fireNodes: built.fireNodes)
        #expect(controller.extinguishFire(at: fire)) // Handled with an explanation, not extinguished.
        #expect(controller.transientMessage == "Pick up a wall extinguisher first.")
        #expect(!controller.isMissionComplete)
        #expect(built.fireNodes[fire]?.isHidden == false)
    }
    @Test func wallExtinguisherBodyIsHitTestableInActualFloorFive() throws {
        let store = MazeStore(); store.switchTo(id: 5)
        let start = GridCoordinate(row: 10, col: 7)
        let target = GridCoordinate(row: 11, col: 7)
        let built = HallwayScene.build(fromMaze: store.cells, cellSize: store.cellSize, wallHeight: store.wallHeight,
            fires: store.fires, extinguishers: store.extinguishers, floorNumber: 5, playerStart: start, playerEnd: store.endCoordinate)
        built.cameraNode.eulerAngles.y = .pi // Looking down the hall, extinguisher visible on right.
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.scene = built.scene; view.pointOfView = built.cameraNode
        _ = view.snapshot()
        let wall = try #require(built.extinguisherNodes[target])
        let body = try #require(wall.childNodes.first { $0.geometry is SCNCylinder })
        let world = body.convertPosition(SCNVector3Zero, to: nil)
        let point = view.projectPoint(world)
        let hits = view.hitTest(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)), options: nil)
        print("FIRE HIT CHECK camera=\(built.cameraNode.position), target=\(world), projected=\(point), hits=\(hits.map { $0.node.name ?? String(describing: $0.node.geometry) })")
        #expect(hits.contains { hit in
            var node: SCNNode? = hit.node
            while let current = node {
                if current === wall { return true }
                node = current.parent
            }
            return false
        })
    }

    @Test func suppliedExtinguisherSoundDecodes() throws {
        let url = try #require(Bundle.main.url(forResource: "fire_extinguisher", withExtension: "mp3"))
        let player = try AVAudioPlayer(contentsOf: url)
        #expect(player.duration > 5 && player.duration < 5.2)
    }

}
