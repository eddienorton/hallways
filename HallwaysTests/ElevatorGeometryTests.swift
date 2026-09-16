import Testing
import SceneKit
@testable import Hallways

@MainActor
struct ElevatorGeometryTests {
    @Test func arrivalReusesBothDisplayedPosters() throws {
        let cell = GridCoordinate(row: 0, col: 0)
        let back = UIColor.red, side = UIColor.blue
        let original = HallwayScene.build(fromMaze: [cell], cellSize: 3.2, wallHeight: 3,
            playerStart: cell, playerEnd: cell,
            elevatorArtwork: ["elevatorBackImage": back, "elevatorSideImage": side])
        let captured = HallwayScene.elevatorArtwork(in: original.scene)
        #expect(captured.count == 2)
        let destination = HallwayScene.build(fromMaze: [cell], cellSize: 3.2, wallHeight: 3,
            floorNumber: 2, playerStart: cell, playerEnd: cell, elevatorArtwork: captured)
        let restored = HallwayScene.elevatorArtwork(in: destination.scene)
        #expect((restored["elevatorBackImage"] as? UIColor) === back)
        #expect((restored["elevatorSideImage"] as? UIColor) === side)
    }

    @Test func squareCabKeepsNarrowDoorsAndCenteredPosters() throws {
        let cell = GridCoordinate(row: 0, col: 0)
        let result = HallwayScene.build(fromMaze: [cell], cellSize: 3.2, wallHeight: 3,
                                       playerStart: cell, playerEnd: cell)
        let doors = try #require(result.elevatorDoors)
        let shaft = doors.shaft
        let back = try #require(shaft.childNode(withName: "elevatorCabBack", recursively: false))
        let side = try #require(shaft.childNode(withName: "elevatorCabLeft", recursively: false))
        #expect(abs(Double((back.geometry as! SCNBox).width) - 3.2) < 0.00001)
        #expect(abs(Double((side.geometry as! SCNBox).length) - 3.2) < 0.00001)
        #expect(abs(side.position.x + 1.6) < 0.00001)
        #expect((doors.left.geometry as? SCNBox)?.width == 0.48)
        #expect((doors.right.geometry as? SCNBox)?.width == 0.48)
        #expect(shaft.childNodes.allSatisfy { $0.name != "elevatorInteriorSurround" })
        #expect((doors.left.geometry as? SCNBox)?.height == 2.6)
        #expect(abs(doors.left.position.y - 1.3) < 0.00001)
        #expect(abs((3.2 - HallwayScene.ElevatorGeometry(cellSize: 3.2).doorWidth) / 2 - 1.12) < 0.00001)
        let backPhoto = try #require(shaft.childNode(withName: "elevatorBackPhoto", recursively: false))
        let sidePhoto = try #require(shaft.childNode(withName: "elevatorSidePhoto", recursively: false))
        #expect(abs(sidePhoto.position.z + 1.6) < 0.00001)
        #expect((backPhoto.geometry as? SCNBox)?.width == (sidePhoto.geometry as? SCNBox)?.width)
        #expect((backPhoto.geometry as? SCNBox)?.height == (sidePhoto.geometry as? SCNBox)?.height)
        #expect(abs((backPhoto.geometry as! SCNBox).width - 0.88) < 0.00001)
        #expect(abs((backPhoto.geometry as! SCNBox).height - (0.8 * 0.85 / 0.6 + 0.08)) < 0.00001)
        let geometry = HallwayScene.ElevatorGeometry(cellSize: 3.2)
        let delta = doors.direction.delta
        let cameraWorld = SCNVector3(Float(delta.col) * Float(geometry.entryDistance), 1.6,
                                     Float(delta.row) * Float(geometry.entryDistance))
        let cameraLocal = shaft.convertPosition(cameraWorld, from: nil)
        #expect(abs(cameraLocal.x) < 0.00001)
        #expect(abs(cameraLocal.z + 1.6) < 0.00001)
        #expect(abs(cameraLocal.y - 0.3) < 0.00001)
        #expect(abs(Double(geometry.entryDistance) / geometry.entryDuration - 2.4 / 1.73) < 0.00001)
    }
}
