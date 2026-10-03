import Testing
import SceneKit
import UIKit
import Combine
@testable import Hallways

/// Oct 1 (usability pass): relative wall selection, continuous map heading,
/// tap-to-approach floor interactables.
@MainActor
@Suite(.serialized)
struct UsabilityPassTests {
    private let cs = 3.52

    // MARK: Front / Left / Right / Back

    @Test func wallSidesMapFromTheCurrentFacing() {
        typealias Side = DecoratorState.WallSide
        #expect(Side.allCases == [.front, .left, .right, .back])
        for facing in Direction.allCases {
            #expect(Side.front.direction(facing: facing) == facing)
            #expect(Side.left.direction(facing: facing) == facing.left)
            #expect(Side.right.direction(facing: facing) == facing.right)
            #expect(Side.back.direction(facing: facing) == facing.opposite)
            #expect(Set(Side.allCases.map { $0.direction(facing: facing) }) == Set(Direction.allCases))
        }
        #expect(Side.left.direction(facing: .north) == .west)
        #expect(Side.back.direction(facing: .east) == .west)
        #expect(Side.allCases.map(\.title) == ["Front", "Left", "Right", "Back"])
    }

    @Test func onlyEligibleWallsOfTheCurrentCellAreOffered() throws {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mazes.json")
        let backup = try? Data(contentsOf: url)
        defer { if let backup { try? backup.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) } }
        let store = MazeStore()
        store.switchTo(id: 3)
        let state = DecoratorState()
        state.enabled = true
        state.attach(scene: SCNScene(), store: store)
        var checked = 0
        for coord in store.cells.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }).prefix(40) {
            for facing in Direction.allCases {
                state.currentPlayerCell = { coord }
                state.currentPlayerFacing = { facing }
                let offered = state.eligibleWallSidesAtCurrentCell()
                let expected = DecoratorState.WallSide.allCases.filter { store.canPlacePicture($0.direction(facing: facing), at: coord) }
                #expect(offered == expected)
                checked += offered.count
            }
        }
        #expect(checked > 0)
    }

    @Test func turningInPlaceRepublishesSoTheWallMenuRecomputes() {
        let state = DecoratorState()
        var fired = 0
        let token = state.objectWillChange.sink { fired += 1 }
        state.playerFacingDidChange(.east)
        state.playerFacingDidChange(.east)       // no-op when unchanged
        state.playerFacingDidChange(.north)
        #expect(fired == 2)
        #expect(state.observedPlayerFacing == .north)
        token.cancel()
    }

    // MARK: Map marker heading

    @Test func mapArrowFollowsTheActualYawContinuously() {
        // Without a yaw: the old cardinal angles.
        #expect(HallwayScene.floorMapArrowAngle(facing: .east, headingYaw: nil) == .pi / 2)
        // With one: the exact heading, never snapped.
        for degrees in [0.0, 17, 44, 46, 90, 133, 180, -62] {
            let yaw = degrees * .pi / 180
            let angle = Double(HallwayScene.floorMapArrowAngle(facing: .north, headingYaw: yaw))
            #expect(abs(angle + yaw) < 1e-9)
        }
        // Convention check against the cardinal table: yaw of west (+pi/2) points screen-left.
        #expect(abs(Double(HallwayScene.floorMapArrowAngle(facing: .north, headingYaw: Direction.west.yaw)) - Double(HallwayScene.floorMapArrowAngle(facing: .west, headingYaw: nil))) < 1e-9)
        #expect(abs(Double(HallwayScene.floorMapArrowAngle(facing: .north, headingYaw: Direction.east.yaw)) - Double(HallwayScene.floorMapArrowAngle(facing: .east, headingYaw: nil))) < 1e-9)
        // Two headings 30 degrees apart in the same cardinal draw differently.
        let a = HallwayScene.makeFloorMapTexture(cells: [GridCoordinate(row: 1, col: 1)], end: GridCoordinate(row: 1, col: 1), playerAt: GridCoordinate(row: 1, col: 1), facing: .north, headingYaw: 0.25).pngData()
        let b = HallwayScene.makeFloorMapTexture(cells: [GridCoordinate(row: 1, col: 1)], end: GridCoordinate(row: 1, col: 1), playerAt: GridCoordinate(row: 1, col: 1), facing: .north, headingYaw: -0.25).pngData()
        #expect(a != b)
    }

    // MARK: Tap-to-approach

    private final class Clock { var time = 1.0 }
    private let clock = Clock()
    private func settle(_ c: TapNavigationController, frames: Int) async {
        let renderer = SCNRenderer(device: nil, options: nil)
        for _ in 0..<frames {
            clock.time += 1.0 / 60
            c.renderer(renderer, updateAtTime: clock.time)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    /// Corridor row 5, cols 3...10, player at col 3 facing east, object at col 9.
    private func corridor(object kind: ObjectKind) -> TapNavigationController {
        let cells = Set((3...10).map { GridCoordinate(row: 5, col: $0) })
        let camera = SCNNode()
        camera.position = SCNVector3(Float(3 * cs), 1.6, Float(5 * cs))
        camera.eulerAngles = SCNVector3(0, Float(Direction.east.yaw), 0)
        let objectCell = GridCoordinate(row: 5, col: 9)
        let objectNode = SCNNode()
        objectNode.position = SCNVector3(Float(9 * cs), 0.3, Float(5 * cs))
        let c = TapNavigationController(cameraNode: camera, scene: SCNScene(), cells: cells, cellSize: CGFloat(cs),
            startCell: GridCoordinate(row: 5, col: 3), startFacing: .east, endCell: GridCoordinate(row: 5, col: 3),
            objects: [objectCell: kind], objectNodes: [objectCell: objectNode], floorNumber: 2)
        c.freeWalkEnabled = true
        return c
    }

    @Test func approachKeepsTheTapLineAndStopsOneCellShort() {
        // Straight on: same line, one cell short, facing it.
        let straight = TapNavigationController.approachAlongLine(from: (0, 0), to: (10, 0), standOff: cs, currentYaw: 1)
        #expect(abs(straight.distance - (10 - cs)) < 1e-9)
        #expect(abs(straight.direction!.x - 1) < 1e-9 && abs(straight.direction!.z) < 1e-9)
        #expect(abs(straight.finalYaw - Direction.east.yaw) < 1e-9)
        // Diagonal: the diagonal is preserved exactly (no snap to an axis).
        let diag = TapNavigationController.approachAlongLine(from: (0, 0), to: (8, 6), standOff: cs, currentYaw: 0)
        #expect(abs(diag.distance - (10 - cs)) < 1e-9)
        #expect(abs(diag.direction!.x - 0.8) < 1e-9 && abs(diag.direction!.z - 0.6) < 1e-9)
        let facing = FreeWalkGeometry.forward(yaw: diag.finalYaw)
        #expect(abs(facing.x - 0.8) < 1e-9 && abs(facing.z - 0.6) < 1e-9)
        // Already closer than a cell: no travel, still turn to face it.
        let close = TapNavigationController.approachAlongLine(from: (0, 0), to: (0, -1), standOff: cs, currentYaw: 2)
        #expect(close.distance == 0)
        #expect(abs(close.finalYaw - Direction.north.yaw) < 1e-9)
    }

    @Test func diagonalTapOnTrashFollowsTheSameDiagonalAndStopsShort() async throws {
        let c = corridor(object: .trashCan)
        c.cameraNode.position = SCNVector3(Float(3 * cs), 1.6, Float(5 * cs + 1.0)) // off-centre start
        let approach = try #require(c.tapApproach(toObjectAt: GridCoordinate(row: 5, col: 9)))
        let p0 = c.cameraNode.position
        c.advance(travelDirection: approach.direction, travelDistance: approach.distance, finalYaw: approach.finalYaw)
        await settle(c, frames: 240)
        let p1 = c.cameraNode.position
        let moved = (x: Double(p1.x - p0.x), z: Double(p1.z - p0.z))
        let len = (moved.x * moved.x + moved.z * moved.z).squareRoot()
        #expect(abs(moved.x / len - approach.direction!.x) < 0.01 && abs(moved.z / len - approach.direction!.z) < 0.01) // same line
        let left = hypot(Double(9 * cs) - Double(p1.x), Double(5 * cs) - Double(p1.z))
        #expect(abs(left - cs) < 0.05)                                  // one cell short
        #expect(c.currentCell == GridCoordinate(row: 5, col: 8))
    }

    @Test func tappingDistantTrashStopsBesideItFacingItAndItCanBePickedUp() async throws {
        let c = corridor(object: .trashCan)
        let trash = GridCoordinate(row: 5, col: 9)
        let approach = try #require(c.tapApproach(toObjectAt: trash))
        #expect(abs(approach.distance - 5 * cs) < 1e-6)            // the tap line, shortened by one cell
        c.advance(travelDirection: approach.direction, travelDistance: approach.distance, finalYaw: approach.finalYaw)
        await settle(c, frames: 240)
        #expect(!c.isAnimating)
        #expect(c.currentCell == GridCoordinate(row: 5, col: 8))
        #expect(c.facing == .east)
        #expect(abs(Double(c.cameraNode.eulerAngles.y) - Direction.east.yaw) < 1e-5)
        #expect(c.collectByTap(at: trash))                          // the existing pickup now works
    }

    @Test func approachFromTheSideTurnsToFaceTheObject() async throws {
        let c = corridor(object: .paintBucket)
        // Player already beside it but looking away (north).
        c.cameraNode.position = SCNVector3(Float(8 * cs), 1.6, Float(5 * cs))
        c.cameraNode.eulerAngles = SCNVector3(0, Float(Direction.north.yaw), 0)
        let approach = try #require(c.tapApproach(toObjectAt: GridCoordinate(row: 5, col: 9)))
        c.advance(travelDirection: approach.direction, travelDistance: approach.distance, finalYaw: approach.finalYaw)
        #expect(c.isAnimating)                                      // turns in place, not ignored
        await settle(c, frames: 90)
        #expect(abs(Double(c.cameraNode.eulerAngles.y) - Direction.east.yaw) < 1e-5)
        #expect(c.facing == .east)
    }

    @Test func ordinaryTapsAndWalkThroughPickupsAreUnchanged() async throws {
        // Hanging cash is collected by walking through it: no approach.
        let cash = corridor(object: .cash100)
        #expect(cash.tapApproach(toObjectAt: GridCoordinate(row: 5, col: 9)) == nil)
        // A tap on an empty cell is no object at all.
        let c = corridor(object: .trashCan)
        #expect(c.tapApproach(toObjectAt: GridCoordinate(row: 5, col: 6)) == nil)
        // Ordinary destination walk still ends IN the tapped cell.
        c.advance(travelDirection: FreeWalkGeometry.forward(yaw: Direction.east.yaw), travelDistance: 3 * cs)
        await settle(c, frames: 180)
        #expect(c.currentCell == GridCoordinate(row: 5, col: 6))
    }

    // MARK: Auto-walk -> long-press handoff (Oct 2)

    private func roomController() -> TapNavigationController {
        let cells = Set((2...8).flatMap { r in (2...14).map { GridCoordinate(row: r, col: $0) } })
        let camera = SCNNode()
        camera.position = SCNVector3(Float(3 * cs), 1.6, Float(5 * cs))
        camera.eulerAngles = SCNVector3(0, Float(Direction.east.yaw), 0)
        let c = TapNavigationController(cameraNode: camera, scene: SCNScene(), cells: cells, cellSize: CGFloat(cs),
            startCell: GridCoordinate(row: 5, col: 3), startFacing: .east, endCell: GridCoordinate(row: 5, col: 3), floorNumber: 2)
        c.freeWalkEnabled = true
        c.heldWalkTurnRateLimit = .infinity
        return c
    }

    @Test func holdDuringAutoWalkTakesOverWithoutStoppingAndTheOldTargetNeverResumes() async {
        let c = roomController()
        let oldTargetX = Double(3 * cs + 2 * cs)
        c.advance(travelDirection: (1, 0), travelDistance: 2 * cs)
        await settle(c, frames: 15)
        #expect(c.isFreeTapWalking)
        let before = c.cameraNode.position
        // Long-press .began: setWalkingHeld(true) then the first heldWalkTick.
        c.setWalkingHeld(true)
        #expect(c.advanceWhileHeld() == false)
        #expect(!c.isFreeTapWalking)
        #expect(c.freeHeldWalkActive)                                   // the ordinary held walk, now
        #expect(c.isAnimating)                                          // no artificial stop
        #expect(SCNVector3EqualToVector3(c.cameraNode.position, before)) // no snap
        c.updateHeldNavigation(fingerX: 200, fingerY: 400, pointsPerQuarterTurn: 140) // pins the steering origin
        await settle(c, frames: 90)
        #expect(Double(c.cameraNode.position.x) > oldTargetX + 0.5)       // kept walking past the old destination
        // Steering works exactly as an ordinary hold.
        let yaw0 = Double(c.cameraNode.eulerAngles.y)
        c.updateHeldNavigation(fingerX: 270, fingerY: 400, pointsPerQuarterTurn: 140)
        #expect(abs(Double(c.cameraNode.eulerAngles.y) - (yaw0 + .pi / 4)) < 1e-5)
        // A tap now is NOT the auto-walk stop (no auto-walk to stop).
        #expect(!c.isFreeTapWalking)
        // Release: stops right there; the old tap walk never resumes.
        c.setWalkingHeld(false)
        await settle(c, frames: 3)
        #expect(!c.isAnimating)
        let stopped = c.cameraNode.position
        await settle(c, frames: 60)
        #expect(SCNVector3EqualToVector3(c.cameraNode.position, stopped))
    }

    @Test func tapStillStopsAnAutoWalkAndAHoldWithoutAutoWalkIsUnchanged() async {
        let c = roomController()
        c.advance(travelDirection: (1, 0), travelDistance: 3 * cs)
        await settle(c, frames: 10)
        c.stopFreeTapWalk()
        await settle(c, frames: 2)
        #expect(!c.isAnimating)
        // Not auto-walking: the handoff does nothing and the hold starts normally.
        c.setWalkingHeld(true)
        #expect(!c.takeOverFreeTapWalkForHold())
        #expect(c.advanceWhileHeld() == false)
        #expect(c.freeHeldWalkActive)
        c.setWalkingHeld(false)
        await settle(c, frames: 3)
        #expect(!c.isAnimating)
    }

    // MARK: Interaction (Oct 2): the drag/hold is routed into the SAME held walk

    /// Case C: finger down + immediate drag during an auto-walk. The pan's
    /// .began is the takeover; its movement steers; release stops for good.
    @Test func dragDuringAutoWalkBecomesTheHeldWalkSteersAndReleaseStops() async {
        let c = roomController()
        let coordinator = HallwaySceneView.Coordinator()
        coordinator.navigationController = c
        let oldTargetX = Double(3 * cs + 2 * cs)
        c.advance(travelDirection: (1, 0), travelDistance: 2 * cs)
        await settle(c, frames: 15)
        #expect(c.isFreeTapWalking)
        let before = c.cameraNode.position
        // Pan .began (~10 pt into the drag).
        #expect(coordinator.panBeganShouldTakeOverAutoWalk())
        #expect(coordinator.panIsHoldTakeover)
        coordinator.beginHold(at: CGPoint(x: 200, y: 400)) { nil }
        #expect(!c.isFreeTapWalking)
        #expect(c.freeHeldWalkActive)
        #expect(SCNVector3EqualToVector3(c.cameraNode.position, before))   // no snap, no stop
        // Pan .changed: the finger keeps moving -> ordinary held steering.
        let yaw0 = Double(c.cameraNode.eulerAngles.y)
        coordinator.updateHold(at: CGPoint(x: 260, y: 400))
        #expect(Double(c.cameraNode.eulerAngles.y) > yaw0 + 0.05)
        coordinator.updateHold(at: CGPoint(x: 200, y: 400))              // back to straight
        await settle(c, frames: 90)
        #expect(Double(c.cameraNode.position.x) > oldTargetX + 0.5)       // past the old destination
        // Pan .ended: stop right there; the old destination never resumes.
        coordinator.panEndedHoldTakeover(at: CGPoint(x: 200, y: 400))
        #expect(!coordinator.panIsHoldTakeover)
        await settle(c, frames: 3)
        #expect(!c.isAnimating)
        let stopped = c.cameraNode.position
        await settle(c, frames: 60)
        #expect(SCNVector3EqualToVector3(c.cameraNode.position, stopped))
        #expect(!c.isFreeTapWalking)
    }

    /// Case B: finger down and still -> the long-press's .began calls the
    /// same beginHold; the auto-walk becomes the held walk.
    @Test func stillHoldDuringAutoWalkTakesOverThroughTheSharedHold() async {
        let c = roomController()
        let coordinator = HallwaySceneView.Coordinator()
        coordinator.navigationController = c
        c.advance(travelDirection: (1, 0), travelDistance: 3 * cs)
        await settle(c, frames: 15)
        #expect(c.isFreeTapWalking)
        coordinator.beginHold(at: CGPoint(x: 200, y: 400)) { nil }
        #expect(c.freeHeldWalkActive)
        #expect(!c.isFreeTapWalking)
        coordinator.endHold(at: CGPoint(x: 200, y: 400))
        await settle(c, frames: 3)
        #expect(!c.isAnimating)
    }

    /// Not auto-walking: a pan is the ordinary free look / drag turn (never
    /// routed into the hold), and an ordinary long-press hold is unchanged.
    @Test func normalPanAndHoldAreUnchangedWhenNotAutoWalking() async {
        let c = roomController()
        let coordinator = HallwaySceneView.Coordinator()
        coordinator.navigationController = c
        #expect(!c.tapWalkCanBeTakenOverByHold)
        #expect(!coordinator.panBeganShouldTakeOverAutoWalk())
        #expect(!coordinator.panIsHoldTakeover)
        coordinator.beginHold(at: CGPoint(x: 200, y: 400)) { nil }
        #expect(c.freeHeldWalkActive)
        coordinator.endHold(at: CGPoint(x: 200, y: 400))
        await settle(c, frames: 3)
        #expect(!c.isAnimating)
        // And after a tap-stopped auto-walk, the pan is back to free look.
        c.advance(travelDirection: (1, 0), travelDistance: 3 * cs)
        await settle(c, frames: 10)
        c.stopFreeTapWalk()
        await settle(c, frames: 3)
        #expect(!coordinator.panBeganShouldTakeOverAutoWalk())
    }

    // MARK: Directional walking audio (Oct 2)

    @Test func footstepFilesMapByFeetAndDirection() {
        #expect(PlayerFeet.man.walkingFilename(reverse: false) == "walk-man.mp3")
        #expect(PlayerFeet.man.walkingFilename(reverse: true) == "walk-man-reverse.mp3")
        #expect(PlayerFeet.highHeels.walkingFilename(reverse: false) == "walk-high-heels.mp3")
        #expect(PlayerFeet.highHeels.walkingFilename(reverse: true) == "walk-high-heels-reverse.mp3")
        #expect(PlayerFeet.highHeels.filename == "walk-high-heels.mp3")       // old "heigh" spelling gone
        for feet in PlayerFeet.allCases { for reverse in [false, true] {
            #expect(!feet.walkingFilename(reverse: reverse).contains("heigh-"))
        } }
    }


    // MARK: Pinch during auto-walk (Oct 2): same ownership rule as the hold

    /// Starts a tap walk east and lets it get going.
    private func autoWalking() async -> TapNavigationController {
        let c = roomController()
        c.advance(travelDirection: (1, 0), travelDistance: 4 * cs)
        await settle(c, frames: 15)
        return c
    }

    @Test func pinchDuringAutoWalkTakesOverInPlaceAndTheOldDestinationNeverResumes() async {
        let c = await autoWalking()
        #expect(c.isFreeTapWalking)
        let before = c.cameraNode.position
        c.beginDragMove(travelDirection: nil)                            // pinch .began
        #expect(!c.isFreeTapWalking)                                      // destination/path abandoned
        #expect(c.isDragMoving)                                           // the ordinary pinch is running
        #expect(SCNVector3EqualToVector3(c.cameraNode.position, before))  // no jump at takeover
        await settle(c, frames: 30)                                       // auto-walk frames would move us
        #expect(SCNVector3EqualToVector3(c.cameraNode.position, before))  // ...but nothing else owns the body
        c.updateDragMove(fraction: 0.5)                                   // ordinary pinch: half a cell
        #expect(abs(Double(c.cameraNode.position.x - before.x) - 0.5 * cs) < 1e-3)
        let pinched = c.cameraNode.position
        c.endDragMove(fraction: 0.5)                                      // release: stays exactly there
        #expect(SCNVector3EqualToVector3(c.cameraNode.position, pinched))
        await settle(c, frames: 90)
        #expect(SCNVector3EqualToVector3(c.cameraNode.position, pinched)) // old destination never resumes
        #expect(!c.isAnimating)
        #expect(!c.isFreeTapWalking)
    }

    @Test func takeoverPinchMovesExactlyLikeAStandingPinchAndCollisionStillRules() async {
        let standing = roomController()
        let s0 = standing.cameraNode.position
        standing.beginDragMove(travelDirection: nil)
        standing.updateDragMove(fraction: 0.7)
        let standingMove = standing.cameraNode.position.x - s0.x
        standing.endDragMove(fraction: 0.7)

        let c = await autoWalking()
        let t0 = c.cameraNode.position
        c.beginDragMove(travelDirection: nil)
        c.updateDragMove(fraction: 0.7)
        #expect(abs((c.cameraNode.position.x - t0.x) - standingMove) < 1e-4) // same pinch semantics
        // Pinch far past the east wall: the existing guardrails keep it inside.
        c.updateDragMove(fraction: 40)
        #expect(Double(c.cameraNode.position.x) < 14.5 * cs)
        c.endDragMove(fraction: 40)
        #expect(Double(c.cameraNode.position.x) < 14.5 * cs)
    }

    @Test func pinchAndHoldTakeoversDoNotDisturbEachOther() async {
        // Not auto-walking: the pinch takeover is a no-op.
        let idle = roomController()
        #expect(!idle.takeOverFreeTapWalkForPinch())
        // Auto-walking: the hold takeover is unchanged (still the held walk).
        let c = await autoWalking()
        c.setWalkingHeld(true)
        #expect(c.advanceWhileHeld() == false)
        #expect(c.freeHeldWalkActive)
        #expect(!c.takeOverFreeTapWalkForPinch())                         // nothing left to take over
        c.setWalkingHeld(false)
        await settle(c, frames: 3)
        #expect(!c.isAnimating)
    }








    // MARK: Pan footsteps = translation, not pivot (Oct 2)

    private func panning() -> TapNavigationController {
        let c = roomController()
        #expect(c.beginFreePan())
        return c
    }
    private func pan(_ c: TapNavigationController, _ dx: Double, _ dy: Double) {
        c.updateFreePan(dx: dx, dy: dy, pointsPerQuarterTurn: 140, pointsPerCell: 140)
    }
    /// Drags from (dx0, dy0) to (dx1, dy1) in `steps` even updates.
    private func drag(_ c: TapNavigationController, from a: (Double, Double), to b: (Double, Double), steps: Int = 12) {
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            pan(c, a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
        }
    }

    @Test func purePivotIsSilent() async {
        let c = panning()
        drag(c, from: (0, 0), to: (140, 0))
        await settle(c, frames: 1)
        #expect(!c.freeWalkFootstepsOn)
        drag(c, from: (140, 0), to: (-60, 0))
        await settle(c, frames: 1)
        #expect(!c.freeWalkFootstepsOn)
        c.endFreePan(dx: -60, pointsPerQuarterTurn: 140)
    }

    @Test func pivotWithIncidentalVerticalDriftIsSilent() async {
        let c = panning()
        let start = c.cameraNode.position
        drag(c, from: (0, 0), to: (140, 6))          // sideways swipe, finger drifts 6 pt down
        await settle(c, frames: 1)
        #expect(hypotf(c.cameraNode.position.x - start.x, c.cameraNode.position.z - start.z) > 0.1) // it DID translate a bit
        #expect(!c.freeWalkFootstepsOn)                                    // ...but that's a pivot
        drag(c, from: (140, 6), to: (20, 2))          // back the other way, drifting up
        await settle(c, frames: 1)
        #expect(!c.freeWalkFootstepsOn)
        c.endFreePan(dx: 20, pointsPerQuarterTurn: 140)
    }




    // MARK: Final walking-audio rule (Oct 2): sound belongs to auto-walk.
    // Manual movement is silent, except the one gesture that took over a
    // running auto-walk (directional, until that gesture ends).

    @Test func tapAutoWalkPlaysForwardFootsteps() async {
        let c = await autoWalking()
        #expect(c.isFreeTapWalking)
        #expect(c.freeWalkFootstepsOn)
        #expect(!c.freeWalkFootstepsReverse)
        #expect(!SoundEffects.walkingReverse)
        #expect(!c.manualFootstepsFromAutoWalk)
    }

    /// Asserts a standing pinch, hold and pan, forward and backward, are all silent.
    private func expectStandingManualMovementIsSilent(_ c: TapNavigationController) async {
        let coordinator = HallwaySceneView.Coordinator()
        coordinator.navigationController = c
        let starts = c.freeWalkFootstepStarts
        // Pinch forward, then backward.
        var p = c.cameraNode.position
        c.beginDragMove(travelDirection: nil)
        #expect(!c.manualFootstepsFromAutoWalk)
        c.updateDragMove(fraction: 0.4)
        #expect(c.cameraNode.position.x > p.x + 0.5)                      // it really moved
        c.updateDragMove(fraction: -0.2)
        await settle(c, frames: 1)
        #expect(!c.freeWalkFootstepsOn)
        c.endDragMove(fraction: -0.2)
        // Hold forward, then backward.
        p = c.cameraNode.position
        coordinator.beginHold(at: CGPoint(x: 200, y: 400)) { nil }
        #expect(c.freeHeldWalkActive)
        #expect(!c.manualFootstepsFromAutoWalk)
        await settle(c, frames: 8)
        #expect(hypotf(c.cameraNode.position.x - p.x, c.cameraNode.position.z - p.z) > 0.3)
        #expect(!c.freeWalkFootstepsOn)
        coordinator.updateHold(at: CGPoint(x: 200, y: 400 - 130))
        await settle(c, frames: 5)
        #expect(!c.freeWalkFootstepsOn)
        coordinator.endHold(at: CGPoint(x: 200, y: 270))
        await settle(c, frames: 3)
        // Pan (one-finger drag) forward, backward, and pivot.
        #expect(!coordinator.panBeganShouldTakeOverAutoWalk())
        #expect(c.beginFreePan())
        drag(c, from: (0, 0), to: (0, 40))
        drag(c, from: (0, 40), to: (0, -10))
        drag(c, from: (0, -10), to: (120, -10))
        await settle(c, frames: 1)
        #expect(!c.freeWalkFootstepsOn)
        c.endFreePan(dx: 120, pointsPerQuarterTurn: 140)
        await settle(c, frames: 1)
        #expect(!c.freeWalkFootstepsOn)
        #expect(c.freeWalkFootstepStarts == starts)                         // no loop ever started
    }

    @Test func standingPinchHoldAndPanAreSilentForwardAndBackward() async {
        await expectStandingManualMovementIsSilent(roomController())
    }

    @Test func pinchTakeoverHasDirectionalFootstepsUntilItEnds() async {
        let c = await autoWalking()
        c.beginDragMove(travelDirection: nil)                              // takeover
        #expect(!c.isFreeTapWalking)
        #expect(c.manualFootstepsFromAutoWalk)
        #expect(!c.freeWalkFootstepsOn)                                     // no travel yet: silent
        c.updateDragMove(fraction: 0.3)                                     // forward travel
        await settle(c, frames: 1)
        #expect(c.freeWalkFootstepsOn)
        #expect(!c.freeWalkFootstepsReverse)
        #expect(!SoundEffects.walkingReverse)
        c.updateDragMove(fraction: -0.2)                                    // backward travel
        await settle(c, frames: 1)
        #expect(c.freeWalkFootstepsOn)
        #expect(c.freeWalkFootstepsReverse)
        #expect(SoundEffects.walkingReverse)                                // the reverse loop
        let released = c.cameraNode.position
        c.endDragMove(fraction: -0.2)                                       // gesture ends
        await settle(c, frames: 1)
        #expect(!c.freeWalkFootstepsOn)
        #expect(!c.manualFootstepsFromAutoWalk)
        await settle(c, frames: 60)
        #expect(SCNVector3EqualToVector3(c.cameraNode.position, released))   // destination never resumes
        await expectStandingManualMovementIsSilent(c)                       // #13: no leak
    }

    @Test func holdTakeoverHasDirectionalFootstepsUntilItEnds() async {
        let c = await autoWalking()
        let coordinator = HallwaySceneView.Coordinator()
        coordinator.navigationController = c
        #expect(coordinator.panBeganShouldTakeOverAutoWalk())               // the drag is the hold
        coordinator.beginHold(at: CGPoint(x: 200, y: 400)) { nil }
        #expect(c.freeHeldWalkActive)
        #expect(c.manualFootstepsFromAutoWalk)
        await settle(c, frames: 5)                                          // forward travel
        #expect(c.freeWalkFootstepsOn)
        #expect(!c.freeWalkFootstepsReverse)
        coordinator.updateHold(at: CGPoint(x: 200, y: 400 - 130))           // backward travel
        await settle(c, frames: 5)
        #expect(c.freeWalkFootstepsOn)
        #expect(c.freeWalkFootstepsReverse)
        #expect(SoundEffects.walkingReverse)
        coordinator.updateHold(at: CGPoint(x: 260, y: 400 - 60))            // neutral + pivot: no travel
        await settle(c, frames: 5)
        #expect(!c.freeWalkFootstepsOn)
        coordinator.updateHold(at: CGPoint(x: 260, y: 400))                 // forward again
        await settle(c, frames: 5)
        #expect(c.freeWalkFootstepsOn)
        #expect(!c.freeWalkFootstepsReverse)
        coordinator.panEndedHoldTakeover(at: CGPoint(x: 260, y: 400))       // gesture ends
        await settle(c, frames: 3)
        #expect(!c.freeWalkFootstepsOn)
        #expect(!c.manualFootstepsFromAutoWalk)
        #expect(!c.isAnimating)
        let released = c.cameraNode.position
        await settle(c, frames: 60)
        #expect(SCNVector3EqualToVector3(c.cameraNode.position, released))   // destination never resumes
        await expectStandingManualMovementIsSilent(c)                       // #13: no leak
    }

    // MARK: No plaque-specific pinch (Oct 2)
    //
    // handlePinch used to hit-test the pinch point and, on a mission plaque,
    // swallow the whole gesture to scale the plaque. That branch is gone:
    // every pinch now reaches the room pinch. Drive the REAL handler.

    private final class FakePinch: UIPinchGestureRecognizer {
        var fakeState: UIGestureRecognizer.State = .began
        var fakeScale: CGFloat = 1
        override var state: UIGestureRecognizer.State {
            get { fakeState }
            set { fakeState = newValue }
        }
        override var scale: CGFloat {
            get { fakeScale }
            set { fakeScale = newValue }
        }
        override var velocity: CGFloat { 0 }
    }

    @Test func pinchHandlerAlwaysRoutesToTheRoomPinch() async {
        let c = roomController()
        let coordinator = HallwaySceneView.Coordinator()
        coordinator.navigationController = c
        let pinch = FakePinch()
        let start = c.cameraNode.position
        pinch.fakeState = .began
        coordinator.handlePinch(pinch)
        #expect(c.isDragMoving)                                            // the room pinch owns it
        pinch.fakeState = .changed
        pinch.fakeScale = 1.2                                              // pinch toward: +0.5 cell
        coordinator.handlePinch(pinch)
        #expect(abs(Double(c.cameraNode.position.x - start.x) - 0.5 * cs) < 1e-3) // physically closer
        pinch.fakeScale = 0.9                                              // pinch away: -0.25 cell
        coordinator.handlePinch(pinch)
        #expect(abs(Double(c.cameraNode.position.x - start.x) + 0.25 * cs) < 1e-3) // farther
        pinch.fakeScale = 30                                               // far past the east wall
        coordinator.handlePinch(pinch)
        #expect(Double(c.cameraNode.position.x) < 14.5 * cs)               // collision still rules
        let held = c.cameraNode.position
        pinch.fakeState = .ended
        coordinator.handlePinch(pinch)
        #expect(!c.isDragMoving)
        #expect(SCNVector3EqualToVector3(c.cameraNode.position, held))     // release: no snap
        await settle(c, frames: 30)
        #expect(SCNVector3EqualToVector3(c.cameraNode.position, held))
    }

    // MARK: Play-mode pictures never disable tap-to-walk (Oct 2)

    @Test func pictureOnTheFacedWallOfTheCurrentCellDoesNotSuppressATap() async {
        let cells = Set((2...8).flatMap { r in (2...14).map { GridCoordinate(row: r, col: $0) } })
        let camera = SCNNode()
        camera.position = SCNVector3(Float(3 * cs), 1.6, Float(5 * cs))
        camera.eulerAngles = SCNVector3(0, Float(Direction.east.yaw), 0)
        let start = GridCoordinate(row: 5, col: 3)
        let c = TapNavigationController(cameraNode: camera, scene: SCNScene(), cells: cells, cellSize: CGFloat(cs),
            startCell: start, startFacing: .east, endCell: start,
            floorNumber: 2, pictures: [WallFace(coord: start, direction: .east)])
        c.freeWalkEnabled = true
        #expect(c.pictureAtCurrentCell == start)              // the state that used to eat every tap
        let coordinator = HallwaySceneView.Coordinator()
        coordinator.navigationController = c
        coordinator.handleTap(UITapGestureRecognizer())       // ordinary Play tap
        #expect(c.isFreeTapWalking)                           // it walks
        let before = c.cameraNode.position
        await settle(c, frames: 30)
        #expect(c.cameraNode.position.x > before.x + 0.5)
    }
}
