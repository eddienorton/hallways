import Testing
import SceneKit
@testable import Hallways

// Sept 22 (wall-face authoring expansion): focused regression coverage for
// Objectives 2-4 -- a cell can now hold an independent Picture on more than
// one of its solid walls, with independent size, explicit image selection,
// and Picture Light. (row: 4, col: 0) on floor 2 is the SAME "ordinary
// dead-end wall" coordinate HallwaysTests/DecoratorModeTests already rely on
// for their own single-picture coverage; it happens to expose three solid,
// otherwise-unclaimed faces (north/south/west), which is what makes it
// useful here -- two of them each carry an independent Picture below.
@MainActor
struct WallFaceMultiPictureTests {
    private let coord = GridCoordinate(row: 4, col: 0)

    @Test func twoPicturesOnDifferentFacesOfSameCellCoexist() {
        let store = MazeStore()
        store.switchTo(id: 2)
        #expect(store.canPlacePicture(.west, at: coord))
        #expect(store.canPlacePicture(.north, at: coord))

        store.placePicture(.west, at: coord, size: .standard)
        // Objective 3's core requirement: a Picture on one face must not
        // disable Add Picture on another available face of the same cell.
        #expect(store.canPlacePicture(.north, at: coord))
        store.placePicture(.north, at: coord, size: .fullLength)

        #expect(store.hasPicture(.west, at: coord))
        #expect(store.hasPicture(.north, at: coord))
        #expect(store.pictureSize(direction: .west, at: coord) == .standard)
        #expect(store.pictureSize(direction: .north, at: coord) == .fullLength)
        // Same-face conflict is still correctly refused.
        #expect(!store.canPlacePicture(.west, at: coord))
    }

    @Test func deletingOnePictureLeavesTheOtherIntact() {
        let store = MazeStore()
        store.switchTo(id: 2)
        store.placePicture(.west, at: coord, size: .standard)
        store.placePicture(.north, at: coord, size: .poster)
        store.removePicture(.west, at: coord)
        #expect(!store.hasPicture(.west, at: coord))
        #expect(store.hasPicture(.north, at: coord))
        #expect(store.pictureSize(direction: .north, at: coord) == .poster)
        // The vacated face is legal again.
        #expect(store.canPlacePicture(.west, at: coord))
    }

    @Test func explicitImageSelectionsAreIndependentPerFace() {
        let store = MazeStore()
        store.switchTo(id: 2)
        store.placePicture(.west, at: coord)
        store.placePicture(.north, at: coord)
        store.setPictureImageSelection(.builtIn("IMG_1"), direction: .west, at: coord)
        store.setPictureImageSelection(.cameraRoll("abc123"), direction: .north, at: coord)
        #expect(store.pictureImageSelections[WallFace(coord: coord, direction: .west)] == .builtIn("IMG_1"))
        #expect(store.pictureImageSelections[WallFace(coord: coord, direction: .north)] == .cameraRoll("abc123"))

        // Deleting one Picture clears only its own explicit selection.
        store.removePicture(.west, at: coord)
        #expect(store.pictureImageSelections[WallFace(coord: coord, direction: .west)] == nil)
        #expect(store.pictureImageSelections[WallFace(coord: coord, direction: .north)] == .cameraRoll("abc123"))
    }

    @Test func pictureLightsAreIndependentPerFace() {
        let store = MazeStore()
        store.switchTo(id: 2)
        store.placePicture(.west, at: coord)
        store.placePicture(.north, at: coord)

        store.placePictureLight(.west, at: coord, brightness: 2)
        #expect(store.pictureLights.contains(WallFace(coord: coord, direction: .west)))
        #expect(!store.pictureLights.contains(WallFace(coord: coord, direction: .north)))
        #expect(store.lightBrightnessLevel(.picture, direction: .west, at: coord) == 2)

        store.placePictureLight(.north, at: coord, brightness: 5)
        // Re-authoring the north face's light must not disturb the west face's.
        #expect(store.lightBrightnessLevel(.picture, direction: .west, at: coord) == 2)
        #expect(store.lightBrightnessLevel(.picture, direction: .north, at: coord) == 5)

        store.removePictureLight(.west, at: coord)
        #expect(!store.pictureLights.contains(WallFace(coord: coord, direction: .west)))
        #expect(store.pictureLights.contains(WallFace(coord: coord, direction: .north)))
    }

    @Test func multiplePicturesSurviveFloorSwitchAndExport() throws {
        let store = MazeStore()
        store.switchTo(id: 2)
        store.placePicture(.west, at: coord, size: .standard)
        store.placePicture(.north, at: coord, size: .fullLength)
        store.setPictureImageSelection(.builtIn("IMG_1"), direction: .west, at: coord)

        store.switchTo(id: 3)
        store.switchTo(id: 2)

        #expect(store.hasPicture(.west, at: coord))
        #expect(store.hasPicture(.north, at: coord))
        #expect(store.pictureSize(direction: .west, at: coord) == .standard)
        #expect(store.pictureSize(direction: .north, at: coord) == .fullLength)
        #expect(store.pictureImageSelections[WallFace(coord: coord, direction: .west)] == .builtIn("IMG_1"))

        let json = try #require(store.exportLibraryJSON()?.data(using: .utf8))
        let floors = try #require(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let exported = try #require(floors.first { $0["id"] as? Int == 2 })
        let pics = try #require(exported["pictures"] as? [[String: Any]])
        let atCoord = pics.filter { item in
            let placed = item["coord"] as? [String: Int]
            return placed?["row"] == 4 && placed?["col"] == 0
        }
        #expect(atCoord.count == 2)
        #expect(Set(atCoord.compactMap { $0["direction"] as? String }) == ["west", "north"])
    }

    @Test func hallwaySceneBuildsOnePictureFrameNodePerFace() {
        let store = MazeStore()
        store.switchTo(id: 2)
        store.placePicture(.west, at: coord, size: .standard)
        store.placePicture(.north, at: coord, size: .standard)
        let scene = HallwayScene.build(fromMaze: store.cells, cellSize: store.cellSize, wallHeight: store.wallHeight,
            pictures: store.pictures, floorNumber: store.currentMazeID,
            pictureImageSelections: store.pictureImageSelections).scene
        var frames: Set<Direction> = []
        scene.rootNode.enumerateChildNodes { node, _ in
            if let target = DecoratorTarget.read(node), target.kind == .picture, target.coord == coord, let direction = target.direction {
                frames.insert(direction)
            }
        }
        #expect(frames == [.west, .north])
    }

    // Objective 3's own example: "west picture + east map YES if both faces
    // exist" -- generalized here to north/west since those are the two free
    // faces at this coordinate. A Floor Map on one face must not block (or
    // be blocked by) a Picture on a DIFFERENT face of the same cell.
    @Test func floorMapAndPictureCoexistOnDifferentFacesOfSameCell() {
        let store = MazeStore()
        store.switchTo(id: 2)
        store.placeFloorMap(.north, at: coord)
        #expect(store.canPlacePicture(.west, at: coord))
        store.placePicture(.west, at: coord)
        #expect(store.hasPicture(.west, at: coord))
        #expect(store.floorMapDirection(at: coord) == .north)
        // The Floor Map's own face is still correctly refused for a Picture.
        #expect(!store.canPlacePicture(.north, at: coord))
    }

    // DecoratorTarget carries its own `direction` for `.picture` now (Sept
    // 22) -- two Pictures tagged at the same coord must resolve to distinct,
    // independently equatable targets, so Decorator selection never
    // conflates them.
    @Test func pictureDecoratorTargetsAtSameCoordDifferByDirection() {
        let a = DecoratorTarget(floor: 2, coord: coord, kind: .picture, direction: .west)
        let b = DecoratorTarget(floor: 2, coord: coord, kind: .picture, direction: .north)
        #expect(a != b)
        #expect(a == DecoratorTarget(floor: 2, coord: coord, kind: .picture, direction: .west))
    }
}
