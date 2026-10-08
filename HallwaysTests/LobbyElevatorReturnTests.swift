import Testing
import SceneKit
@testable import Hallways

/// Oct 8: returning to Floor 1 by elevator enters at the lobby elevator,
/// like any other floor; the first visit's walk-in start is untouched.
@MainActor
@Suite(.serialized)
struct LobbyElevatorReturnTests {
    private func withIsolatedPersistence(_ body: () throws -> Void) rethrows {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mazes.json")
        let backup = try? Data(contentsOf: url)
        let key = "maze.savedFloorOverrideIDs"
        let oldOverrides = UserDefaults.standard.object(forKey: key)
        defer {
            if let backup { try? backup.write(to: url, options: .atomic) }
            else { try? FileManager.default.removeItem(at: url) }
            if let oldOverrides { UserDefaults.standard.set(oldOverrides, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try body()
    }

    @Test func floorOneSpawnsAtTheDoorOnFootAndAtTheElevatorByElevator() throws {
        try withIsolatedPersistence {
            let store = MazeStore()
            // Floor 2 -> 1 -> 2 -> 1: every lobby return is the same.
            for floor in [2, 1, 2, 1] {
                store.switchTo(id: floor)
                let walkIn = try #require(store.spawnCoordinate(arrivingByElevator: false))
                let byElevator = try #require(store.spawnCoordinate(arrivingByElevator: true))
                #expect(walkIn == store.startCoordinate)                  // first visit: unchanged
                #expect(byElevator == store.endCoordinate)                // return: the elevator
                if floor == 1 {
                    #expect(byElevator == MazeStore.elevatorCoordinate)
                    #expect(walkIn != byElevator)                         // the case that was wrong
                } else {
                    #expect(walkIn == byElevator)                         // other floors: no change at all
                }
            }
        }
    }

    /// A lobby-shaped corridor: elevator at the north end (10,7), the front
    /// door four cells south (14,7).
    private func lobby() -> (TapNavigationController, SCNNode) {
        let cells = Set((10...14).map { GridCoordinate(row: $0, col: 7) })
        let scene = SCNScene(), camera = SCNNode(), left = SCNNode(), right = SCNNode()
        let door = GridCoordinate(row: 14, col: 7), elevator = GridCoordinate(row: 10, col: 7)
        camera.position = SCNVector3(7 * 3.2, 1.6, 14 * 3.2)              // the build's spawn: the front door
        left.position = SCNVector3(7 * 3.2 - 0.24, 1.3, 10 * 3.2 - 1.6)
        right.position = SCNVector3(7 * 3.2 + 0.24, 1.3, 10 * 3.2 - 1.6)
        [camera, left, right].forEach { scene.rootNode.addChildNode($0) }
        let nav = TapNavigationController(cameraNode: camera, scene: scene, cells: cells, cellSize: 3.2,
            startCell: door, startFacing: .north, endCell: elevator,
            elevatorLeftDoor: left, elevatorRightDoor: right, elevatorMountDirection: .north, floorNumber: 1)
        return (nav, camera)
    }

    @Test func aLobbyReturnOpensTheCabAtTheElevatorFacingDownTheHall() {
        let (nav, camera) = lobby()
        nav.enterAtElevatorCell()
        #expect(nav.currentCell == GridCoordinate(row: 10, col: 7))
        nav.presentArrivalInsideElevator(preservedYaw: nil)
        let depth = Float(HallwayScene.ElevatorGeometry(cellSize: 3.2).entryDistance)
        #expect(abs(camera.position.x - 7 * 3.2) < 0.001)
        #expect(abs(camera.position.z - (10 * 3.2 - depth)) < 0.001)        // inside the lobby cab
        #expect(nav.elevatorAwaitingEntryDirection == .south)              // way out: down the hall
        #expect(abs(Double(camera.eulerAngles.y) - Direction.south.yaw) < 0.001)
        #expect(!nav.entranceDoorAtCurrentCell)                            // not at the front door
    }

    @Test func withoutTheFixTheCabWouldOpenAtTheFrontDoor() {
        let (nav, camera) = lobby()
        nav.presentArrivalInsideElevator(preservedYaw: nil)               // old order: no enterAtElevatorCell
        #expect(camera.position.z > 12 * 3.2)                              // ...beside the entrance
    }

    @Test func theFrontDoorStillMeansTheFrontDoorAfterAReturn() {
        let (nav, camera) = lobby()
        nav.enterAtElevatorCell()
        nav.presentArrivalInsideElevator(preservedYaw: nil)
        nav.reset()                                                         // e.g. back out to the opening
        #expect(nav.currentCell == GridCoordinate(row: 14, col: 7))
        #expect(nav.entranceDoorAtCurrentCell)
        #expect(abs(camera.position.z - 14 * 3.2) < 0.001)
    }
}
