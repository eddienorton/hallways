import Testing
import SceneKit
@testable import Hallways

/// Sept 28 (Your Height): height preference -> first-person eye height.
struct PlayerHeightTests {
    private func freshDefaults() -> UserDefaults {
        let name = "PlayerHeightTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultReproducesTheOriginalViewpoint() {
        let defaults = freshDefaults()
        #expect(PlayerHeight.inches(in: defaults) == PlayerHeight.defaultInches)
        #expect(PlayerHeight.defaultInches == 68)
        #expect(abs(PlayerHeight.eyeHeight(forInches: PlayerHeight.defaultInches) - 1.60) < 0.01)
        #expect(PlayerHeight.displayString(forInches: 68) == "5' 8\"")
    }

    @Test func eyeHeightFollowsHeightMonotonicallyAndClamps() {
        var previous: Float = 0
        for inches in PlayerHeight.minimumInches...PlayerHeight.maximumInches {
            let eye = PlayerHeight.eyeHeight(forInches: inches)
            #expect(eye > previous)
            #expect(abs(eye - Float(Double(inches) * 0.0254 * 0.93)) < 0.0001)
            previous = eye
        }
        #expect(PlayerHeight.eyeHeight(forInches: 10) == PlayerHeight.eyeHeight(forInches: PlayerHeight.minimumInches))
        #expect(PlayerHeight.eyeHeight(forInches: 200) == PlayerHeight.eyeHeight(forInches: PlayerHeight.maximumInches))
        // Always above the floor and well below the 3.0 m ceiling.
        #expect(PlayerHeight.eyeHeight(forInches: PlayerHeight.minimumInches) > 1.0)
        #expect(PlayerHeight.eyeHeight(forInches: PlayerHeight.maximumInches) < 2.0)
        #expect(PlayerHeight.displayString(forInches: 48) == "4' 0\"")
        #expect(PlayerHeight.displayString(forInches: 84) == "7' 0\"")
    }

    @Test func persistedValuesSurviveAndBadValuesAreSafe() {
        let defaults = freshDefaults()
        defaults.set(74, forKey: PlayerHeight.preferenceKey)
        #expect(PlayerHeight.inches(in: defaults) == 74) // survives re-reading, as after relaunch
        defaults.set(5, forKey: PlayerHeight.preferenceKey)
        #expect(PlayerHeight.inches(in: defaults) == PlayerHeight.minimumInches)
        defaults.set(999, forKey: PlayerHeight.preferenceKey)
        #expect(PlayerHeight.inches(in: defaults) == PlayerHeight.maximumInches)
        defaults.set("tall", forKey: PlayerHeight.preferenceKey)
        #expect(PlayerHeight.inches(in: defaults) == PlayerHeight.defaultInches)
        defaults.set(Double.nan, forKey: PlayerHeight.preferenceKey)
        #expect(PlayerHeight.inches(in: defaults) == PlayerHeight.defaultInches)
    }

    @MainActor
    @Test func liveHeightChangeMovesOnlyTheCameraY() {
        let cells = Set((4...6).map { GridCoordinate(row: $0, col: 5) })
        let start = GridCoordinate(row: 5, col: 5)
        let result = HallwayScene.build(fromMaze: cells, cellSize: 3.52, wallHeight: 3,
                                        floorNumber: 2, playerStart: start, playerEnd: GridCoordinate(row: 6, col: 5))
        let controller = TapNavigationController(cameraNode: result.cameraNode, scene: result.scene,
            cells: cells, cellSize: 3.52, startCell: start, startFacing: .north, endCell: GridCoordinate(row: 6, col: 5))
        let before = result.cameraNode.position
        let yaw = result.cameraNode.eulerAngles
        let tall = PlayerHeight.eyeHeight(forInches: 76)
        controller.setEyeHeight(tall)
        #expect(controller.eyeHeight == tall)
        #expect(result.cameraNode.position.y == tall)
        #expect(result.cameraNode.position.x == before.x && result.cameraNode.position.z == before.z)
        #expect(SCNVector3EqualToVector3(result.cameraNode.eulerAngles, yaw))
        #expect(controller.currentCell == start)
    }
}
