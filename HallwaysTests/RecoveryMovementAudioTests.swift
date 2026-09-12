import Testing
import SceneKit
import AVFoundation
@testable import Hallways

@MainActor
struct RecoveryMovementAudioTests {
    private func controller(length: Int = 20) -> TapNavigationController {
        TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: Set((0...length).map { GridCoordinate(row: 0, col: $0) }), cellSize: 3.2,
            startCell: GridCoordinate(row: 0, col: 0), startFacing: .east,
            endCell: GridCoordinate(row: 0, col: length), floorNumber: 2)
    }
    @Test func heldRunWaitsTwoCellsThenAcceleratesAndReleaseSlows() async {
        let c = controller(), renderer = SCNRenderer(device: nil, options: nil)
        c.setWalkingHeld(true); c.advanceWhileHeld()
        var time = 0.0
        for _ in 0..<40 {
            time += 0.025; c.renderer(renderer, updateAtTime: time); await Task.yield()
        }
        #expect(c.cameraNode.position.x < 6.4)
        #expect(c.movementPace == 1)
        for _ in 0..<40 {
            time += 0.025; c.renderer(renderer, updateAtTime: time); await Task.yield()
        }
        #expect(c.movementPace > 1.5)
        #expect(c.cameraNode.position.x > 12) // Faster than the 6 units/sec walk.
        #expect(abs(Double(SoundEffects.walkingRate) - c.movementPace) < 0.001)
        let paceBeforeRelease = c.movementPace
        c.setWalkingHeld(false)
        time += 0.025; c.renderer(renderer, updateAtTime: time)
        #expect(c.movementPace < paceBeforeRelease && c.movementPace > 1)
        for _ in 0..<80 {
            time += 0.025; c.renderer(renderer, updateAtTime: time); await Task.yield()
        }
        #expect(c.movementPace < 1.01)
        c.reset(); #expect(c.movementPace == 1)
    }
    @Test func onlyIdleBlockedForwardAttemptsAreWalls() {
        let c = controller()
        #expect(!c.forwardIsBlockedByWall)
        c.advance()
        #expect(!c.forwardIsBlockedByWall)
        c.reset(); c.openHandheldMap()
        #expect(!c.forwardIsBlockedByWall)
        c.closeHandheldMap()
        let wall = controller(length: 0)
        #expect(wall.forwardIsBlockedByWall)
        wall.beginDragRotate()
        #expect(!wall.forwardIsBlockedByWall)
    }
    @Test func requestedSoundsAreBundledAndDecodable() throws {
        for name in ["hit-wall", "warning-buzz", "paint-splat", "trash-chute-open", "trash-chute-close"] {
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "mp3"))
            let player = try AVAudioPlayer(contentsOf: url)
            #expect(player.duration > 0)
            #expect(player.prepareToPlay())
        }
    }
    @Test func cashCallbackPrecedesArrivalMapRasterization() async {
        let start = GridCoordinate(row: 0, col: 0), end = GridCoordinate(row: 0, col: 1)
        let plane = SCNNode(geometry: SCNPlane(width: 1, height: 1))
        plane.geometry?.materials = [SCNMaterial()]
        let c = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: [start,end],
            cellSize: 3.2, startCell: start, startFacing: .east, endCell: end,
            objects: [end: .cash100], floorNumber: 2, floorMapPlaneNodes: [plane])
        let before = plane.geometry?.firstMaterial?.diffuse.contents as? UIImage
        var awards = 0
        c.onCollectCash = { value in
            #expect(value == 100)
            #expect((plane.geometry?.firstMaterial?.diffuse.contents as? UIImage) === before)
            awards += 1
        }
        c.advance()
        let renderer = SCNRenderer(device: nil, options: nil)
        for i in 1...100 { c.renderer(renderer, updateAtTime: Double(i) * 0.025); await Task.yield() }
        #expect(awards == 1)
        #expect(plane.geometry?.firstMaterial?.diffuse.contents is UIImage)
    }
}
