import Testing
import SceneKit
@testable import Hallways

// Sept 26 ("Keep This Picture"): focused regression coverage for the new
// identity-tracking/promotion plumbing this feature added -- NOT a full
// re-test of picture placement/build (WallFaceMultiPictureTests and
// HallwaysTests already cover that). Two levels on purpose:
//   1. Pure MazeStore-level tests exercise exactly what a Keep button does
//      (report an identity, then promote it into the real persisted
//      selection) with no SceneKit/bundle/Photos dependency at all.
//   2. One HallwayScene.build-level test confirms the AUTHORED elevator
//      tier reports its already-known identity synchronously, regardless
//      of source (.cameraRoll here) -- deliberately avoiding the random
//      built-in/camera-roll fallback tiers, which need bundled image
//      resources or Photos library access this test target may not have.
@MainActor
struct KeepThisPictureTests {
    private func cabDefaults() -> UserDefaults {
        UserDefaults(suiteName: "KeepThisPictureTests.\(UUID().uuidString)")!
    }

    @Test func keepPromotesRandomPictureIdentityIntoPersistedSelection() {
        let store = MazeStore()
        store.switchTo(id: 2)
        let coord = GridCoordinate(row: 4, col: 0)
        store.placePicture(.west, at: coord)
        let face = WallFace(coord: coord, direction: .west)

        // Before any random pick is reported, or any explicit choice is
        // made, there is nothing for Keep to promote.
        #expect(store.pictureImageSelections[face] == nil)
        #expect(store.currentPictureIdentity[face] == nil)

        // Simulates HallwayScene.build's reportPictureIdentity closure
        // firing for this face's build-time random pick.
        store.reportCurrentPictureIdentity(.builtIn("IMG_1"), at: face)
        #expect(store.currentPictureIdentity[face] == .builtIn("IMG_1"))
        // Still nothing persisted yet -- reporting alone is scratch state,
        // never itself a selection.
        #expect(store.pictureImageSelections[face] == nil)

        // Simulates the "Keep This Picture" button itself.
        if let identity = store.currentPictureIdentity[face] {
            store.setPictureImageSelection(identity, direction: .west, at: coord)
        }
        #expect(store.pictureImageSelections[face] == .builtIn("IMG_1"))

        // Matches the Keep button's own enable check: once a face has an
        // explicit selection, Keep has nothing left to promote.
        #expect(store.pictureImageSelections[face] != nil)
    }

    @Test func keepPromotesRandomElevatorPosterIdentityIntoElevatorCabDecoration() {
        let prefs = cabDefaults()
        let store = MazeStore(cabDecorationDefaults: prefs, bundledElevatorCab: { nil })
        #expect(store.elevatorCabDecoration.backArtwork == nil)
        #expect(store.elevatorCabDecoration.sideArtwork == nil)

        // Simulates HallwayScene.build's reportElevatorBackIdentity/
        // reportElevatorSideIdentity closures firing for each poster's own
        // build-time random pick.
        store.reportCurrentElevatorBackIdentity(.cameraRoll("back-random-id"))
        store.reportCurrentElevatorSideIdentity(.builtIn("IMG_2"))
        #expect(store.currentElevatorBackIdentity == .cameraRoll("back-random-id"))
        #expect(store.currentElevatorSideIdentity == .builtIn("IMG_2"))
        // Reporting alone never persists -- elevatorCabDecoration is untouched.
        #expect(store.elevatorCabDecoration.backArtwork == nil)
        #expect(store.elevatorCabDecoration.sideArtwork == nil)

        // Simulates pressing "Keep This Picture" for the back poster only.
        if let identity = store.currentElevatorBackIdentity {
            store.setElevatorBackArtwork(identity)
        }
        #expect(store.elevatorCabDecoration.backArtwork == .cameraRoll("back-random-id"))
        // The side poster's own random pick is untouched by keeping the back one.
        #expect(store.elevatorCabDecoration.sideArtwork == nil)

        // Persists immediately (same "Cab mutations persist immediately"
        // semantics as every other elevatorCabDecoration write) -- survives
        // a fresh MazeStore instance reading the same UserDefaults.
        #expect(MazeStore(cabDecorationDefaults: prefs).elevatorCabDecoration.backArtwork == .cameraRoll("back-random-id"))
    }

    @Test func buildReportsAuthoredElevatorIdentitySynchronouslyRegardlessOfSource() {
        let a = GridCoordinate(row: 0, col: 0)
        let b = GridCoordinate(row: 1, col: 0)
        var reportedBack: PictureImageSelection?
        var reportedSide: PictureImageSelection?
        // .cameraRoll/.builtIn here are deliberately never actually
        // resolved to a real asset/bundle image -- the AUTHORED tier
        // reports its identity synchronously, before any image fetch, so
        // this needs no Photos access or bundled test resources.
        let authored = ElevatorCabDecoration(backArtwork: .cameraRoll("authored-back-id"),
                                             sideArtwork: .builtIn("authored-side-name"))
        _ = HallwayScene.build(fromMaze: [a, b], cellSize: 3.2, wallHeight: 3,
                               floorNumber: 2, playerStart: a, playerEnd: b,
                               elevatorCabDecoration: authored,
                               reportElevatorBackIdentity: { reportedBack = $0 },
                               reportElevatorSideIdentity: { reportedSide = $0 })
        #expect(reportedBack == .cameraRoll("authored-back-id"))
        #expect(reportedSide == .builtIn("authored-side-name"))
    }
}
