import Testing
import SceneKit
@testable import Hallways

@MainActor
struct FireApproachTests {
    private let cs = 3.52
    private func fixture(blockCorner: Bool = false) -> (TapNavigationController, SCNNode, GridCoordinate) {
        let scene = SCNScene(), camera = SCNNode(), fire = SCNNode()
        let coord = GridCoordinate(row: 3, col: 3)
        fire.position = SCNVector3(3 * cs + 0.2, 0, 3 * cs - 0.15)
        scene.rootNode.addChildNode(fire)
        camera.position = SCNVector3(cs, 1.6, cs)
        var cells = Set((0...5).flatMap { row in (0...5).map { GridCoordinate(row: row, col: $0) } })
        if blockCorner { cells.remove(GridCoordinate(row: 2, col: 3)); cells.remove(GridCoordinate(row: 3, col: 2)) }
        let c = TapNavigationController(cameraNode: camera, scene: scene, cells: cells, cellSize: CGFloat(cs),
            startCell: GridCoordinate(row: 1, col: 1), startFacing: .north,
            endCell: GridCoordinate(row: 0, col: 0), floorNumber: 2, fires: [coord], fireNodes: [coord: fire])
        c.freeWalkEnabled = true
        return (c, fire, coord)
    }
    @Test func distantFireUsesActualPositionAndStopsOneCellShort() throws {
        let (c, fire, coord) = fixture()
        #expect(!c.canReachFire(at: coord))
        let a = try #require(c.tapApproach(toFireAt: coord)), d = try #require(a.direction)
        let p = c.cameraNode.worldPosition, t = fire.worldPosition
        let length = hypot(Double(t.x - p.x), Double(t.z - p.z))
        #expect(abs(a.distance - (length - cs)) < 0.00001)
        #expect(abs(d.x - Double(t.x - p.x) / length) < 0.00001)
        #expect(abs(d.z - Double(t.z - p.z) / length) < 0.00001)
        #expect(abs(a.finalYaw - atan2(-d.x, -d.z)) < 0.00001)
        c.cameraNode.position = SCNVector3(Double(p.x) + d.x * a.distance, 1.6, Double(p.z) + d.z * a.distance)
        #expect(c.canReachFire(at: coord))
        #expect(try #require(c.tapApproach(toFireAt: coord)).distance < 0.00001)
    }
    @Test func arbitraryAnglesReachWithoutCardinalFacing() {
        let (c, fire, coord) = fixture()
        for angle in [0.2, 0.7, 1.3, 2.4, 3.8, 5.7] {
            c.cameraNode.position = SCNVector3(Double(fire.position.x) + cos(angle) * cs, 1.6,
                Double(fire.position.z) + sin(angle) * cs)
            #expect(c.canReachFire(at: coord))
            c.cameraNode.position = SCNVector3(Double(fire.position.x) + cos(angle) * (cs + 0.1), 1.6,
                Double(fire.position.z) + sin(angle) * (cs + 0.1))
            #expect(!c.canReachFire(at: coord))
        }
    }
    @Test func freeformReachDoesNotCrossClosedCorner() {
        let (c, _, coord) = fixture(blockCorner: true)
        c.cameraNode.position = SCNVector3(2.35 * cs, 1.6, 2.35 * cs)
        #expect(!c.canReachFire(at: coord))
    }
    @Test func legacySameCellReachRemainsAvailable() {
        let (c, _, _) = fixture()
        #expect(c.canReachFire(at: c.currentCell))
    }
    @Test func removedFireHasNoApproach() {
        let (c, fire, coord) = fixture()
        fire.removeFromParentNode()
        #expect(c.tapApproach(toFireAt: coord) == nil)
    }
}
