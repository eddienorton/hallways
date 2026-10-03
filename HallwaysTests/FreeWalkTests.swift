import Testing
import SceneKit
import Combine
@testable import Hallways

/// Sept 29 FREE-WALK EXPERIMENT: continuous player X/Z inside the
/// grid-authored building.
@MainActor
struct FreeWalkTests {
    private let cs = 3.52
    /// The Free Walk body clearance under test (pass #6).
    private let margin = FreeWalkGeometry.playerClearance
    // An east-west corridor, row 5, cols 5...9. Start (5,6) facing east.
    private let start = GridCoordinate(row: 5, col: 6)

    private func makeController(extraCells: Set<GridCoordinate> = [], free: Bool = true, yawOffset: Double = 0,
                                bathroomDoors: [GridCoordinate: Direction] = [:],
                                missionSigns: [GridCoordinate: Direction] = [:]) -> TapNavigationController {
        let camera = SCNNode()
        camera.position = SCNVector3(Float(Double(start.col) * cs), 1.6, Float(Double(start.row) * cs))
        camera.eulerAngles = SCNVector3(0, Float(Direction.east.yaw + yawOffset), 0)
        let cells = Set((5...9).map { GridCoordinate(row: 5, col: $0) }).union(extraCells)
        let controller = TapNavigationController(cameraNode: camera, scene: SCNScene(), cells: cells, cellSize: CGFloat(cs),
            startCell: start, startFacing: .east, endCell: GridCoordinate(row: 5, col: 5), floorNumber: 2,
            missionSigns: missionSigns, bathroomDoors: bathroomDoors)
        controller.freeWalkEnabled = free
        // These tests pin the raw held-steering mapping/behaviour; the
        // Sept 30 turn-rate limit has its own tests (heldTurnRate...).
        controller.heldWalkTurnRateLimit = .infinity
        return controller
    }

    private final class Clock { var time = 1.0 }
    private let clock = Clock()
    private func settle(_ controller: TapNavigationController, frames: Int = 90) async {
        let renderer = SCNRenderer(device: nil, options: nil)
        for _ in 0..<frames {
            clock.time += 1.0 / 60
            controller.renderer(renderer, updateAtTime: clock.time)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }
    private func pos(_ c: TapNavigationController) -> SCNVector3 { c.cameraNode.position }
    private func yaw(_ c: TapNavigationController) -> Double { Double(c.cameraNode.eulerAngles.y) }

    @Test func worldPositionMapsToItsContainingCell() {
        #expect(FreeWalkGeometry.containingCell(x: 12.731, z: 28.114, cellSize: cs) == GridCoordinate(row: 8, col: 4))
        #expect(FreeWalkGeometry.containingCell(x: 7 * cs + 1.75, z: 5 * cs - 1.75, cellSize: cs) == GridCoordinate(row: 5, col: 7))
        #expect(FreeWalkGeometry.containingCell(x: 7 * cs + 1.77, z: 5 * cs, cellSize: cs) == GridCoordinate(row: 5, col: 8))
        #expect(FreeWalkGeometry.containingCell(x: -1.9, z: 0, cellSize: cs) == GridCoordinate(row: 0, col: -1))
        // Hysteresis: just over the line stays in the previous cell; well over moves.
        let g = FreeWalkGeometry(cells: [], openEdges: [], cellSize: cs)
        let previous = GridCoordinate(row: 5, col: 7)
        #expect(g.containingCell(x: 7 * cs + cs / 2 + 0.02, z: 5 * cs, previous: previous) == previous)
        #expect(g.containingCell(x: 7 * cs + cs / 2 + 0.10, z: 5 * cs, previous: previous) == GridCoordinate(row: 5, col: 8))
    }

    @Test func yawGivesTheCameraForwardVector() {
        func close(_ a: (x: Double, z: Double), _ b: (x: Double, z: Double)) -> Bool { abs(a.x - b.x) < 1e-9 && abs(a.z - b.z) < 1e-9 }
        for d in Direction.allCases {
            #expect(close(FreeWalkGeometry.forward(yaw: d.yaw), (Double(d.delta.col), Double(d.delta.row))))
        }
        let a = 17 * Double.pi / 180 // 17 degrees left of north
        #expect(close(FreeWalkGeometry.forward(yaw: a), (-sin(a), -cos(a))))
    }

    @Test func tapWalksOneCellSizeAlongActualYawAndStaysOffCenter() async {
        let offset = 0.1 // ~5.7 degrees left of east
        let controller = makeController(yawOffset: offset)
        let yaw0 = yaw(controller)
        let start = pos(controller)
        var cells: [GridCoordinate] = []
        let token = controller.$currentCell.dropFirst().sink { cells.append($0) }
        controller.advance()
        #expect(controller.isAnimating)
        #expect(controller.cameraNode.action(forKey: "freeLookAlign") == nil)
        await settle(controller, frames: 3)
        #expect(abs(yaw(controller) - yaw0) < 1e-6) // no align-before-walk
        await settle(controller)
        #expect(!controller.isAnimating)
        let end = pos(controller)
        let f = FreeWalkGeometry.forward(yaw: yaw0)
        #expect(abs(Double(end.x - start.x) - f.x * cs) < 0.001)
        #expect(abs(Double(end.z - start.z) - f.z * cs) < 0.001)
        #expect(abs(Double(end.z) - 5 * cs) > 0.3) // genuinely off the center line
        #expect(abs(yaw(controller) - yaw0) < 1e-6)
        #expect(controller.currentCell == GridCoordinate(row: 5, col: 7))
        #expect(cells == [GridCoordinate(row: 5, col: 7)]) // arrival fired exactly once
        #expect(controller.facing == .east)

        // Stays put: more frames, no recentering.
        await settle(controller, frames: 30)
        #expect(SCNVector3EqualToVector3(pos(controller), end))

        // A second tap goes another cellSize from THERE.
        controller.advance()
        await settle(controller)
        let second = pos(controller)
        #expect(abs(Double(second.x - end.x) - f.x * cs) < 0.001)
        #expect(abs(Double(second.z - end.z) - f.z * cs) < 0.001)
        #expect(controller.currentCell == GridCoordinate(row: 5, col: 8))
        #expect(cells.count == 2)
        token.cancel()
    }

    @Test func theBuildingStopsTheBody() async {
        // Looking straight at the north wall: stop `margin` short of it.
        let controller = makeController(yawOffset: .pi / 2) // north
        let start = pos(controller)
        controller.advance()
        await settle(controller)
        let stopped = pos(controller)
        #expect(stopped.x == start.x)
        #expect(abs(Double(start.z - stopped.z) - (cs / 2 - margin)) < 0.03)
        #expect(controller.currentCell == self.start)
        controller.advance() // already against it: nothing moves
        #expect(!controller.isAnimating)
        await settle(controller)
        #expect(SCNVector3EqualToVector3(pos(controller), stopped))

        // A closed door between (5,7) and (5,8) blocks the corridor too.
        let doored = makeController(bathroomDoors: [GridCoordinate(row: 5, col: 7): .east])
        doored.advance()
        await settle(doored)
        doored.advance()
        await settle(doored)
        #expect(abs(Double(pos(doored).x) - (7 * cs + cs / 2 - margin)) < 0.03)
        #expect(doored.currentCell == GridCoordinate(row: 5, col: 7))

        // Inner wall corner of an L: two open sides, missing diagonal.
        let g = FreeWalkGeometry(cells: [GridCoordinate(row: 0, col: 0), GridCoordinate(row: 0, col: 1), GridCoordinate(row: 1, col: 0)],
            openEdges: [.init(cell: GridCoordinate(row: 0, col: 0), direction: .east), .init(cell: GridCoordinate(row: 0, col: 0), direction: .south)],
            cellSize: cs)
        #expect(g.isLegal(x: 1.7, z: 0))
        #expect(g.isLegal(x: 0, z: 1.7))
        #expect(!g.isLegal(x: 1.7, z: 1.7))
        #expect(!g.isLegal(x: -1.7, z: 0)) // west wall
    }

    @Test func holdWalksContinuouslyAndStopsExactlyOnRelease() async {
        // A T-junction at (5,7) and an unviewed mission sign at (5,7): both
        // old stop reasons. The held walk ignores them.
        let controller = makeController(extraCells: [GridCoordinate(row: 4, col: 7)], yawOffset: 0.05,
                                        missionSigns: [GridCoordinate(row: 5, col: 7): .south])
        let yaw0 = yaw(controller)
        controller.setWalkingHeld(true)
        #expect(controller.advanceWhileHeld() == false) // never the endpoint state in free mode
        #expect(controller.isAnimating)
        await settle(controller, frames: 80) // ~1.3 s at 6 m/s (+ held acceleration): ~8 m
        #expect(controller.isAnimating) // still walking: one continuous movement
        #expect(controller.currentCell.col >= 8) // straight through the old stop cell and the fork
        let beforeRelease = pos(controller)
        controller.setWalkingHeld(false)
        await settle(controller, frames: 2)
        #expect(!controller.isAnimating)
        let stopped = pos(controller)
        #expect(Double(stopped.x - beforeRelease.x) < 0.25) // at most a frame's travel after release
        await settle(controller, frames: 30)
        #expect(SCNVector3EqualToVector3(pos(controller), stopped)) // no completion, no snap
        let local = Double(stopped.x) / cs - Double(controller.currentCell.col)
        #expect(abs(local) > 0.01 || abs(Double(stopped.z) / cs - 5) > 0.01) // not a cell center
        #expect(abs(yaw(controller) - yaw0) < 1e-6)
        #expect(controller.facing == .east)
    }

    @Test func holdIntoAWallStandsStillUntilRelease() async {
        let controller = makeController(yawOffset: .pi / 2) // north wall
        controller.setWalkingHeld(true)
        controller.advanceWhileHeld()
        await settle(controller, frames: 60)
        #expect(controller.isAnimating)
        #expect(abs(Double(pos(controller).z) - (5 * cs - (cs / 2 - margin))) < 0.03)
        #expect(controller.currentCell == start)
        controller.setWalkingHeld(false)
        await settle(controller, frames: 3)
        #expect(!controller.isAnimating)
    }

    @Test func flagOffKeepsTheGridCenteredPath() async {
        let controller = makeController(free: false, yawOffset: 0.1)
        controller.advance()
        await settle(controller, frames: 240)
        // Old path: straightened to east, walked to the dead-end center.
        let center = SCNVector3(Float(9 * cs), 1.6, Float(5 * cs))
        #expect(abs(pos(controller).x - center.x) < 0.0001 && abs(pos(controller).z - center.z) < 0.0001)
        #expect(abs(yaw(controller) - Direction.east.yaw) < 0.0001)
        #expect(controller.currentCell == GridCoordinate(row: 5, col: 9))
    }

    // MARK: - Polish pass #1: TRUE HELD WALK + LIVE STEERING

    /// Free Look's convention: 140 pt of finger = 90 degrees, finger right = +yaw.
    private let ppq = 140.0
    private func expectedYaw(_ origin: Double, _ dx: Double) -> Double { origin + dx / ppq * .pi / 2 }
    /// Rows 3...7 x cols 5...12: an open room around the start cell.
    private var room: Set<GridCoordinate> {
        Set((3...7).flatMap { r in (5...12).map { GridCoordinate(row: r, col: $0) } })
    }

    @Test func heldSteeringStartsWithNoJumpAndMatchesFreeLook() async {
        let controller = makeController(yawOffset: 0.05)
        let yaw0 = yaw(controller)
        controller.setWalkingHeld(true)
        controller.advanceWhileHeld()
        #expect(controller.freeHeldWalkActive)
        // Finger has drifted to x=213 by the time the hold is recognized:
        // that becomes the origin, the camera does not move.
        controller.updateHeldWalkSteering(fingerX: 213, pointsPerQuarterTurn: ppq)
        #expect(controller.heldSteeringActive)
        #expect(abs(yaw(controller) - yaw0) < 1e-6)
        // Continuous, linear, unclamped, same sign as Free Look.
        for dx in [5.0, 35, 70, 140, 200, -20, -170, 0] {
            controller.updateHeldWalkSteering(fingerX: 213 + dx, pointsPerQuarterTurn: ppq)
            #expect(abs(yaw(controller) - expectedYaw(yaw0, dx)) < 1e-5)
        }
        // Ordinary Free Look drag for the same 35 pt lands on the same yaw.
        let look = makeController(yawOffset: 0.05)
        look.beginDragRotate()
        look.updateDragRotate(fraction: 35 / ppq)
        controller.updateHeldWalkSteering(fingerX: 213 + 35, pointsPerQuarterTurn: ppq)
        #expect(abs(yaw(look) - yaw(controller)) < 1e-5)
        look.endDragRotate(fraction: 35 / ppq)
        await settle(look, frames: 3)
        #expect(abs(yaw(look) - expectedYaw(yaw0, 35)) < 1e-5) // Free Look still no snap
        controller.setWalkingHeld(false)
        await settle(controller, frames: 3)
    }

    @Test func heldWalkCurvesWithLiveYawAndStopsExactlyOnRelease() async {
        let controller = makeController(extraCells: room)
        let yaw0 = yaw(controller)
        var cells: [GridCoordinate] = []
        let token = controller.$currentCell.dropFirst().sink { cells.append($0) }
        controller.setWalkingHeld(true)
        controller.advanceWhileHeld()
        controller.updateHeldWalkSteering(fingerX: 100, pointsPerQuarterTurn: ppq)
        await settle(controller, frames: 20)
        #expect(controller.isAnimating)
        // Steer 45 degrees left (east -> north-east) without lifting.
        controller.updateHeldWalkSteering(fingerX: 170, pointsPerQuarterTurn: ppq)
        let steered = expectedYaw(yaw0, 70)
        await settle(controller, frames: 2)
        let a = pos(controller)
        await settle(controller, frames: 10)
        let b = pos(controller)
        #expect(controller.isAnimating) // no pause, no new walk
        let dx = Double(b.x - a.x), dz = Double(b.z - a.z)
        let len = (dx * dx + dz * dz).squareRoot()
        let f = FreeWalkGeometry.forward(yaw: steered)
        #expect(len > 0.3)
        #expect(abs(dx / len - f.x) < 0.01 && abs(dz / len - f.z) < 0.01) // follows LIVE yaw
        #expect(abs(yaw(controller) - steered) < 1e-5) // no cardinal snap
        #expect(!controller.freeWalkFootstepsOn) // Oct 2: a hold from standing is silent
        #expect(controller.freeWalkFootstepStarts == 0) // Oct 2: a hold from standing is silent
        #expect(!cells.isEmpty) // crossed cells without stopping
        // Release: stop where we are, keep the exact yaw.
        controller.setWalkingHeld(false)
        await settle(controller, frames: 2)
        #expect(!controller.isAnimating)
        #expect(!controller.heldSteeringActive)
        let stopped = pos(controller)
        await settle(controller, frames: 30)
        #expect(SCNVector3EqualToVector3(pos(controller), stopped))
        #expect(abs(yaw(controller) - steered) < 1e-5)
        #expect(!controller.freeWalkFootstepsOn)
        token.cancel()
    }

    @Test func wallBlockedHoldSteersAwayAndResumesWithoutRelease() async {
        let controller = makeController(yawOffset: .pi / 2) // straight at the north wall
        controller.setWalkingHeld(true)
        controller.advanceWhileHeld()
        controller.updateHeldWalkSteering(fingerX: 0, pointsPerQuarterTurn: ppq)
        await settle(controller, frames: 60)
        let blocked = pos(controller)
        #expect(controller.freeHeldWalkActive) // held intent survives the wall
        #expect(!controller.freeWalkFootstepsOn) // silent (standing hold)
        #expect(controller.freeWalkFootstepStarts == 0) // Oct 2: a hold from standing is silent
        // Same finger slides left: yaw swings past east, away from the wall.
        controller.updateHeldWalkSteering(fingerX: -160, pointsPerQuarterTurn: ppq)
        await settle(controller, frames: 20)
        #expect(controller.isAnimating)
        #expect(Double(pos(controller).x - blocked.x) > 0.5) // walking again, eastward
        #expect(!controller.freeWalkFootstepsOn) // Oct 2: a hold from standing is silent
        #expect(controller.freeWalkFootstepStarts == 0) // Oct 2: a hold from standing is silent
        controller.setWalkingHeld(false)
        await settle(controller, frames: 3)
        #expect(!controller.isAnimating)
    }

    @Test func steeringOnlyAppliesToAFreeHeldWalk() async {
        // Tap: never steered.
        let tapped = makeController()
        let yawT = yaw(tapped)
        tapped.advance()
        tapped.updateHeldWalkSteering(fingerX: 0, pointsPerQuarterTurn: ppq)
        tapped.updateHeldWalkSteering(fingerX: 100, pointsPerQuarterTurn: ppq)
        #expect(!tapped.heldSteeringActive)
        #expect(abs(yaw(tapped) - yawT) < 1e-6)
        await settle(tapped)

        // Legacy hold (flag off): untouched; HeldEndpointLook still owns it.
        let legacy = makeController(free: false)
        let yawL = yaw(legacy)
        legacy.setWalkingHeld(true)
        legacy.advanceWhileHeld()
        legacy.updateHeldWalkSteering(fingerX: 0, pointsPerQuarterTurn: ppq)
        legacy.updateHeldWalkSteering(fingerX: 100, pointsPerQuarterTurn: ppq)
        #expect(!legacy.heldSteeringActive)
        #expect(abs(yaw(legacy) - yawL) < 1e-6)
        legacy.setWalkingHeld(false)
        await settle(legacy, frames: 240)

        // A fresh hold re-pins the origin: no jump carried over.
        let again = makeController(extraCells: room)
        again.setWalkingHeld(true)
        again.advanceWhileHeld()
        again.updateHeldWalkSteering(fingerX: 0, pointsPerQuarterTurn: ppq)
        again.updateHeldWalkSteering(fingerX: 50, pointsPerQuarterTurn: ppq)
        again.setWalkingHeld(false)
        await settle(again, frames: 3)
        let yawA = yaw(again)
        again.setWalkingHeld(true)
        again.advanceWhileHeld()
        again.updateHeldWalkSteering(fingerX: 300, pointsPerQuarterTurn: ppq)
        #expect(abs(yaw(again) - yawA) < 1e-6)
        again.setWalkingHeld(false)
        await settle(again, frames: 3)
    }

    // MARK: - Polish pass #2: UNIFIED HELD NAVIGATION (X = TURN, Y = MOVE)

    private func dot(_ a: SCNVector3, _ b: SCNVector3, _ f: (x: Double, z: Double)) -> Double {
        Double(b.x - a.x) * f.x + Double(b.z - a.z) * f.z
    }
    private func same(_ a: SCNVector3, _ b: SCNVector3, _ tol: Float = 1e-4) -> Bool {
        abs(a.x - b.x) < tol && abs(a.z - b.z) < tol
    }
    /// Off-center inside the start cell.
    private func offCenter(_ c: TapNavigationController) {
        c.cameraNode.position = SCNVector3(Float(6 * cs + 0.7), 1.6, Float(5 * cs - 0.5))
    }

    @Test func verticalThrottleMapping() {
        let t = TapNavigationController.throttle(forVerticalOffset:)
        #expect(t(0) == 1)       // hold still = walk forward (today's hold)
        #expect(t(80) == 1)      // finger further down: still full forward
        #expect(t(-60) == 0)     // ~60 pt up: stopped
        #expect(t(-52) == 0 && t(-68) == 0) // dead band around the stop
        #expect(t(-120) == -1)   // ~120 pt up: full backward
        #expect(t(-200) == -1)
        #expect(abs(t(-90) + 0.375) < 1e-9)
        #expect(abs(t(-30) - 0.375) < 1e-9)
        var last = 2.0
        for dy in stride(from: 100.0, through: -200, by: -5) { let v = t(dy); #expect(v <= last); last = v }
    }

    @Test func heldNavigationOriginHasNoJumpFromAnArbitraryPose() {
        let controller = makeController(yawOffset: 0.37)
        offCenter(controller)
        let p0 = pos(controller), yaw0 = yaw(controller)
        controller.setWalkingHeld(true)
        controller.advanceWhileHeld()
        // Finger drifted before recognition: its location is simply the origin.
        controller.updateHeldNavigation(fingerX: 231, fingerY: 407, pointsPerQuarterTurn: ppq)
        #expect(controller.heldSteeringActive)
        #expect(controller.heldThrottle == 1)
        #expect(SCNVector3EqualToVector3(pos(controller), p0))
        #expect(abs(yaw(controller) - yaw0) < 1e-6)
        controller.setWalkingHeld(false)
    }

    @Test func turnInPlaceThenBackUpAlongActualYaw() async {
        let controller = makeController(extraCells: room, yawOffset: 0.37)
        offCenter(controller)
        let p0 = pos(controller), yaw0 = yaw(controller)
        controller.setWalkingHeld(true)
        controller.advanceWhileHeld()
        controller.updateHeldNavigation(fingerX: 200, fingerY: 400, pointsPerQuarterTurn: ppq)
        // Neutral Y (60 pt up) + horizontal: turn in place, X/Z unchanged, silent.
        controller.updateHeldNavigation(fingerX: 270, fingerY: 340, pointsPerQuarterTurn: ppq)
        await settle(controller, frames: 30)
        #expect(same(pos(controller), p0))
        let turned = expectedYaw(yaw0, 70)
        #expect(abs(yaw(controller) - turned) < 1e-5)
        #expect(!controller.freeWalkFootstepsOn)
        #expect(controller.freeHeldWalkActive)
        // Backward only: opposite the ACTUAL yaw, yaw untouched (no pre-snap).
        let a = pos(controller)
        controller.updateHeldNavigation(fingerX: 270, fingerY: 280, pointsPerQuarterTurn: ppq)
        await settle(controller, frames: 15)
        let b = pos(controller)
        let f = FreeWalkGeometry.forward(yaw: turned)
        #expect(dot(a, b, f) < -0.5)
        let side = Double(b.x - a.x) * -f.z + Double(b.z - a.z) * f.x
        #expect(abs(side) < 0.01) // straight back, not along a cardinal
        #expect(abs(yaw(controller) - turned) < 1e-5)
        #expect(!controller.freeWalkFootstepsOn) // Oct 2: a hold from standing is silent
        // Release: no post-snap.
        controller.setWalkingHeld(false)
        await settle(controller, frames: 2)
        let stopped = pos(controller)
        await settle(controller, frames: 30)
        #expect(SCNVector3EqualToVector3(pos(controller), stopped))
        #expect(abs(yaw(controller) - turned) < 1e-5)
    }

    @Test func oneTouchForwardTurnNeutralSpinBackTurnWithoutLifting() async {
        let controller = makeController(extraCells: room, yawOffset: 0.3)
        offCenter(controller)
        let yaw0 = yaw(controller)
        var cells: [GridCoordinate] = []
        let token = controller.$currentCell.dropFirst().sink { cells.append($0) }
        controller.setWalkingHeld(true)
        controller.advanceWhileHeld()
        controller.updateHeldNavigation(fingerX: 200, fingerY: 400, pointsPerQuarterTurn: ppq)
        // Forward (hold still).
        var a = pos(controller)
        await settle(controller, frames: 12)
        #expect(dot(a, pos(controller), FreeWalkGeometry.forward(yaw: yaw0)) > 0.8)
        // Diagonal: turn while still moving -- path curves with live yaw.
        controller.updateHeldNavigation(fingerX: 250, fingerY: 400, pointsPerQuarterTurn: ppq)
        let y1 = expectedYaw(yaw0, 50)
        await settle(controller, frames: 2)
        a = pos(controller)
        await settle(controller, frames: 8)
        #expect(dot(a, pos(controller), FreeWalkGeometry.forward(yaw: y1)) > 0.5)
        #expect(abs(yaw(controller) - y1) < 1e-5)
        // Through neutral: stop, one continuous touch.
        controller.updateHeldNavigation(fingerX: 250, fingerY: 340, pointsPerQuarterTurn: ppq)
        await settle(controller, frames: 1)
        let parked = pos(controller)
        // Spin in place.
        controller.updateHeldNavigation(fingerX: 150, fingerY: 340, pointsPerQuarterTurn: ppq)
        await settle(controller, frames: 10)
        #expect(same(pos(controller), parked))
        let y2 = expectedYaw(yaw0, -50)
        #expect(abs(yaw(controller) - y2) < 1e-5)
        #expect(!controller.freeWalkFootstepsOn)
        // Backward, then turn again while backing.
        controller.updateHeldNavigation(fingerX: 150, fingerY: 270, pointsPerQuarterTurn: ppq)
        await settle(controller, frames: 8)
        #expect(dot(parked, pos(controller), FreeWalkGeometry.forward(yaw: y2)) < -0.3)
        controller.updateHeldNavigation(fingerX: 120, fingerY: 270, pointsPerQuarterTurn: ppq)
        await settle(controller, frames: 5)
        let y3 = expectedYaw(yaw0, -80)
        #expect(controller.freeHeldWalkActive) // still the same held session
        #expect(controller.freeWalkFootstepStarts == 0) // Oct 2: a hold from standing is silent
        #expect(!cells.isEmpty) // containing-cell bookkeeping ran
        controller.setWalkingHeld(false)
        await settle(controller, frames: 2)
        let stopped = pos(controller)
        await settle(controller, frames: 30)
        #expect(SCNVector3EqualToVector3(pos(controller), stopped))
        #expect(abs(yaw(controller) - y3) < 1e-5)
        let local = (Double(stopped.x) / cs - Double(controller.currentCell.col), Double(stopped.z) / cs - Double(controller.currentCell.row))
        #expect(abs(local.0) > 0.01 || abs(local.1) > 0.01) // never parked on a center
        token.cancel()
    }

    @Test func verticalDragAndPinchScrubKeepThePhysicalPose() async {
        // beginDragMove/updateDragMove/endDragMove is the trio behind both
        // the one-finger vertical pan and pinch in/out.
        let controller = makeController(extraCells: room, yawOffset: 0.37)
        offCenter(controller)
        let p0 = pos(controller), yaw0 = yaw(controller)
        controller.beginDragMove()
        #expect(controller.isDragMoving)
        #expect(controller.cameraNode.action(forKey: "freeLookAlign") == nil) // no pre-snap
        let f = FreeWalkGeometry.forward(yaw: yaw0)
        controller.updateDragMove(fraction: 0.4)
        #expect(abs(dot(p0, pos(controller), f) - 0.4 * cs) < 0.001)
        controller.updateDragMove(fraction: -0.3) // backward along actual yaw
        let back = pos(controller)
        #expect(abs(dot(p0, back, f) + 0.3 * cs) < 0.001)
        #expect(abs(yaw(controller) - yaw0) < 1e-6)
        controller.endDragMove(fraction: -0.3, velocityFraction: 6) // a flick changes nothing
        #expect(!controller.isDragMoving)
        await settle(controller, frames: 60)
        #expect(SCNVector3EqualToVector3(pos(controller), back)) // no post-snap
        #expect(abs(yaw(controller) - yaw0) < 1e-6)
    }

    @Test func flagOffDragMoveStillSettlesOnTheGrid() async {
        let controller = makeController(free: false)
        controller.beginDragMove()
        controller.updateDragMove(fraction: 0.5)
        controller.endDragMove(fraction: 0.5)
        await settle(controller, frames: 120)
        let center = SCNVector3(Float(7 * cs), 1.6, Float(5 * cs))
        #expect(same(pos(controller), center))
        #expect(controller.currentCell == GridCoordinate(row: 5, col: 7))
    }

    // MARK: - Polish pass #3: ordinary one-finger pan = one 2-D control

    private let ppc = 140.0 // dragMoveDistance: pt of vertical drag per cell
    private func pan(_ c: TapNavigationController, _ dx: Double, _ dy: Double) {
        c.updateFreePan(dx: dx, dy: dy, pointsPerQuarterTurn: ppq, pointsPerCell: ppc)
    }
    private func moved(_ a: SCNVector3, _ b: SCNVector3) -> Double { Double(hypotf(b.x - a.x, b.z - a.z)) }
    /// Unit direction of travel a -> b agrees with forward(yaw) * sign.
    private func along(_ a: SCNVector3, _ b: SCNVector3, yaw: Double, sign: Double) -> Bool {
        let d = moved(a, b), f = FreeWalkGeometry.forward(yaw: yaw)
        guard d > 1e-4 else { return false }
        return abs(Double(b.x - a.x) / d - sign * f.x) < 0.01 && abs(Double(b.z - a.z) / d - sign * f.z) < 0.01
    }

    @Test func verticalFirstPanKeepsTurningAvailable() {
        let c = makeController(extraCells: room, yawOffset: 0.37)
        offCenter(c)
        let yaw0 = yaw(c)
        #expect(c.beginFreePan())
        var a = pos(c)
        pan(c, 3, 70) // mostly vertical: half a cell forward
        #expect(along(a, pos(c), yaw: expectedYaw(yaw0, 3), sign: 1))
        #expect(abs(moved(a, pos(c)) - 0.5 * cs) < 0.001)
        a = pos(c)
        pan(c, 103, 70) // now pure X: yaw responds, no Y travel
        #expect(abs(yaw(c) - expectedYaw(yaw0, 103)) < 1e-5)
        #expect(SCNVector3EqualToVector3(pos(c), a))
        pan(c, 103, 140) // Y again: moves along the NEW yaw
        #expect(along(a, pos(c), yaw: expectedYaw(yaw0, 103), sign: 1))
        #expect(c.isFreePanning)
        c.endFreePan(dx: 103, pointsPerQuarterTurn: ppq)
    }

    @Test func horizontalFirstPanKeepsMovingAvailable() {
        let c = makeController(extraCells: room, yawOffset: 0.37)
        offCenter(c)
        let yaw0 = yaw(c)
        #expect(c.beginFreePan())
        pan(c, 90, 0)
        #expect(abs(yaw(c) - expectedYaw(yaw0, 90)) < 1e-5)
        let a = pos(c)
        pan(c, 90, 100)
        #expect(along(a, pos(c), yaw: expectedYaw(yaw0, 90), sign: 1))
        #expect(abs(moved(a, pos(c)) - 100 / ppc * cs) < 0.001)
        c.endFreePan(dx: 90, pointsPerQuarterTurn: ppq)
    }

    @Test func diagonalFromTheStartTurnsAndTranslates() {
        // origin (500,500) -> current (250,250): dx = dy = -250.
        let c = makeController(extraCells: room, yawOffset: 0.37)
        offCenter(c)
        let yaw0 = yaw(c), a = pos(c)
        #expect(c.beginFreePan())
        pan(c, -250, -250)
        let y = expectedYaw(yaw0, -250)
        #expect(abs(yaw(c) - y) < 1e-5)                    // turned
        #expect(moved(a, pos(c)) > 1)                        // AND moved (finger up = back)
        #expect(along(a, pos(c), yaw: y, sign: -1))
        c.endFreePan(dx: -250, pointsPerQuarterTurn: ppq)
    }

    @Test func panWalkWhilePivotingCurvesThenReversesAndReleasesInPlace() async {
        let c = makeController(extraCells: room, yawOffset: 0.2)
        offCenter(c)
        let yaw0 = yaw(c)
        var cells: [GridCoordinate] = []
        let token = c.$currentCell.dropFirst().sink { cells.append($0) }
        #expect(c.beginFreePan())
        // Forward + turning left: every increment follows the live yaw.
        var directions: [Double] = []
        for i in 1...10 {
            let a = pos(c)
            let dx = Double(i) * 8, dy = Double(i) * 14
            pan(c, dx, dy)
            #expect(along(a, pos(c), yaw: expectedYaw(yaw0, dx), sign: 1))
            directions.append(atan2(Double(pos(c).z - a.z), Double(pos(c).x - a.x)))
        }
        #expect(abs(directions.first! - directions.last!) > 0.4) // the path curved
        // Turn only (Y held), then backward + turning right, then forward again.
        let parked = pos(c)
        pan(c, 20, 140)
        #expect(SCNVector3EqualToVector3(pos(c), parked))
        for i in 1...5 {
            let a = pos(c)
            let dx = 20 - Double(i) * 10
            pan(c, dx, 140 - Double(i) * 12)
            #expect(along(a, pos(c), yaw: expectedYaw(yaw0, dx), sign: -1))
        }
        let a = pos(c)
        pan(c, -30, 110)
        #expect(along(a, pos(c), yaw: expectedYaw(yaw0, -30), sign: 1))
        #expect(!cells.isEmpty) // containing-cell bookkeeping ran, no recenter
        // Release: exact pose kept, logical facing = nearest cardinal.
        let finalPos = pos(c), finalYaw = expectedYaw(yaw0, -30)
        c.endFreePan(dx: -30, pointsPerQuarterTurn: ppq)
        #expect(!c.isFreePanning)
        await settle(c, frames: 30)
        #expect(SCNVector3EqualToVector3(pos(c), finalPos))
        #expect(abs(yaw(c) - finalYaw) < 1e-5)
        #expect(!c.isAnimating)
        token.cancel()
    }

    @Test func panTurnInPlaceAndWallStopsTheBody() {
        let c = makeController(yawOffset: .pi / 2) // corridor, north wall ahead
        #expect(c.beginFreePan())
        let a = pos(c)
        pan(c, 60, 0)
        pan(c, -40, 0)
        #expect(SCNVector3EqualToVector3(pos(c), a)) // turn only
        pan(c, 0, 0)
        pan(c, 0, 400) // ~3 cells "forward" into the wall: stopped by the building
        #expect(abs(Double(pos(c).z) - (5 * cs - (cs / 2 - margin))) < 0.03)
        c.endFreePan(dx: 0, pointsPerQuarterTurn: ppq)
    }

    @Test func flagOffPanStaysLegacy() {
        let c = makeController(free: false)
        #expect(!c.beginFreePan())
        #expect(!c.isFreePanning)
        #expect(!c.isDragRotating)
    }

    // MARK: - Polish pass #4: WALL SLIDING
    // Corridor row 5, cols 5...9. North wall: z >= 5cs - (cs/2 - margin).

    private var northLimit: Double { 5 * cs - (cs / 2 - margin) }
    private func at(_ x: Double, _ z: Double) -> SCNVector3 { SCNVector3(Float(x), 1.6, Float(z)) }

    @Test func slideLeavesOpenMovementUnchanged() {
        let g = makeController(extraCells: room).makeFreeWalkGeometry()
        let p = at(6 * cs, 5 * cs)
        let e = g.slideEndpoint(from: p, dx: 1.0, dz: -0.3)
        #expect(abs(Double(e.x - p.x) - 1.0) < 1e-4 && abs(Double(e.z - p.z) + 0.3) < 1e-4)
    }

    @Test func obliqueIntoAWallKeepsTheAlongWallPart() {
        let g = makeController().makeFreeWalkGeometry()
        let p = at(6 * cs, northLimit + 0.01) // 1 cm off the north wall
        for dx in [0.8, -0.8] { // both approach angles
            let e = g.slideEndpoint(from: p, dx: dx, dz: -0.2)
            #expect(abs(Double(e.x - p.x) - dx) < 1e-4)     // along-wall part survives
            #expect(Double(e.z) >= northLimit - 1e-6)         // never into the wall
            #expect(Double(e.z) <= Double(p.z))
        }
        // Dead on: nothing left.
        let dead = g.slideEndpoint(from: p, dx: 0, dz: -0.8)
        #expect(Double(hypotf(dead.x - p.x, dead.z - p.z)) < 0.02)
    }

    @Test func cornersStopAndDoorsStaySolid() {
        let g = makeController().makeFreeWalkGeometry()
        // North-east corner of the dead end at (5,9): both components blocked.
        let limit = cs / 2 - margin
        let p = at(9 * cs + limit - 0.01, northLimit + 0.01)
        let e = g.slideEndpoint(from: p, dx: 2, dz: -2)
        #expect(Double(hypotf(e.x - p.x, e.z - p.z)) < 0.03)
        #expect(g.isLegal(x: Double(e.x), z: Double(e.z)))

        // Closed door on (5,7) east: slide along it, never through it.
        let doored = makeController(bathroomDoors: [GridCoordinate(row: 5, col: 7): .east]).makeFreeWalkGeometry()
        let q = at(7 * cs + limit - 0.05, 5 * cs)
        let f = doored.slideEndpoint(from: q, dx: 0.8, dz: 0.3)
        #expect(Double(f.x) <= 7 * cs + limit + 1e-6)
        #expect(abs(Double(f.z - q.z) - 0.3) < 1e-4)
    }

    @Test func slideAlongAWallLeavesItAtAnOpening() {
        // Opening north at (4,7).
        let g = makeController(extraCells: [GridCoordinate(row: 4, col: 7)]).makeFreeWalkGeometry()
        let p = at(6 * cs, northLimit + 0.01)
        let path = g.slidePath(from: p, dx: 0.9 * cs, dz: -2.5)
        let e = path.last!
        #expect(FreeWalkGeometry.containingCell(x: Double(e.x), z: Double(e.z), cellSize: cs) == GridCoordinate(row: 4, col: 7))
        #expect(path.allSatisfy { g.isLegal(x: Double($0.x), z: Double($0.z)) }) // no tunnelling, ever
        for i in 1..<path.count { #expect(hypotf(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z) < 0.03) } // continuous
    }

    @Test func obliqueTapSlidesAlongTheWall() async {
        let c = makeController(yawOffset: .pi / 2 - .pi / 6) // 30 degrees east of north
        c.cameraNode.position = at(6 * cs, northLimit + 0.06)
        let p = pos(c), yaw0 = yaw(c)
        c.advance()
        #expect(c.isAnimating) // not a THUD
        await settle(c)
        #expect(!c.isAnimating)
        #expect(Double(pos(c).x - p.x) > 1.6)        // ~ cs * sin(30deg) along the wall
        #expect(Double(pos(c).z) >= northLimit - 1e-6)
        #expect(abs(yaw(c) - yaw0) < 1e-6)           // collision never turns the head
        // Dead on: stays a THUD (no animation).
        let d = makeController(yawOffset: .pi / 2)
        d.cameraNode.position = at(6 * cs, northLimit + 0.01)
        d.advance()
        #expect(!d.isAnimating)
    }

    @Test func heldWalkAndReverseSlideWithoutRestarting() async {
        let c = makeController(yawOffset: .pi / 2 - .pi / 6)
        c.cameraNode.position = at(6 * cs, northLimit + 0.3)
        let yaw0 = yaw(c)
        var cells: [GridCoordinate] = []
        let token = c.$currentCell.dropFirst().sink { cells.append($0) }
        c.setWalkingHeld(true)
        c.advanceWhileHeld()
        c.updateHeldNavigation(fingerX: 0, fingerY: 0, pointsPerQuarterTurn: ppq)
        await settle(c, frames: 50)
        #expect(Double(pos(c).z) >= northLimit - 1e-6)
        #expect(Double(pos(c).x) - 6 * cs > 2)        // kept going along the wall
        #expect(!c.freeWalkFootstepsOn) // Oct 2: a hold from standing is silent
        #expect(c.freeWalkFootstepStarts == 0) // Oct 2: a hold from standing is silent
        #expect(abs(yaw(c) - yaw0) < 1e-6)
        #expect(!cells.isEmpty)                       // slid into the next cell normally
        c.setWalkingHeld(false)
        await settle(c, frames: 3)
        token.cancel()

        // Reverse obliquely into the same wall: slides the other way.
        let r = makeController(yawOffset: .pi / 2 + .pi - .pi / 6) // facing south-west-ish
        r.cameraNode.position = at(7 * cs, northLimit + 0.3)
        let yawR = yaw(r)
        r.setWalkingHeld(true)
        r.advanceWhileHeld()
        r.updateHeldNavigation(fingerX: 0, fingerY: 0, pointsPerQuarterTurn: ppq)
        r.updateHeldNavigation(fingerX: 0, fingerY: -120, pointsPerQuarterTurn: ppq) // full backward
        let start = pos(r)
        await settle(r, frames: 40)
        #expect(Double(pos(r).x - start.x) > 0.8) // along-wall (+x) part of "backward"
        #expect(Double(pos(r).z) >= northLimit - 1e-6)
        #expect(abs(yaw(r) - yawR) < 1e-6)
        r.setWalkingHeld(false)
        await settle(r, frames: 3)
    }

    @Test func panSlidesWhileStillTurning() {
        let c = makeController(yawOffset: .pi / 2 - .pi / 6)
        c.cameraNode.position = at(6 * cs, northLimit + 0.02)
        let yaw0 = yaw(c), p = pos(c)
        #expect(c.beginFreePan())
        pan(c, 0, 140) // one cell of "forward", mostly into the wall
        #expect(Double(pos(c).x - p.x) > 1.6)
        #expect(Double(pos(c).z) >= northLimit - 1e-6)
        #expect(abs(yaw(c) - yaw0) < 1e-6)
        pan(c, 30, 180) // X still turns, Y still moves
        #expect(abs(yaw(c) - expectedYaw(yaw0, 30)) < 1e-5)
        #expect(Double(pos(c).z) >= northLimit - 1e-6)
        c.endFreePan(dx: 30, pointsPerQuarterTurn: ppq)
    }

    // MARK: - Polish pass #5: PINCH TOWARD THE POINT YOU ARE PINCHING

    /// Yaw whose forward vector is `d` (inverse of FreeWalkGeometry.forward).
    private func yawOf(_ d: (x: Double, z: Double)) -> Double { atan2(-d.x, -d.z) }

    @Test func pinchRayHeadingIgnoresHeight() {
        let d = TapNavigationController.horizontalDirection(near: SCNVector3(0, 1.6, 0), far: SCNVector3(3, -40, -3))!
        #expect(abs(d.x - 1 / 2.0.squareRoot()) < 1e-6 && abs(d.z + 1 / 2.0.squareRoot()) < 1e-6)
        #expect(TapNavigationController.horizontalDirection(near: SCNVector3(0, 1.6, 0), far: SCNVector3(0, -9, 0)) == nil)
    }

    /// Real SceneKit unprojection through a yaw-only camera, like the app's.
    @Test func pinchScreenPointGivesCenterLeftAndRightHeadings() {
        let scene = SCNScene()
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(10, 1.6, 20)
        camera.eulerAngles = SCNVector3(0, 0.3, 0)
        scene.rootNode.addChildNode(camera)
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.scene = scene
        view.pointOfView = camera
        func heading(_ x: CGFloat, _ y: CGFloat) -> (x: Double, z: Double) {
            let near = view.unprojectPoint(SCNVector3(Float(x), Float(y), 0))
            let far = view.unprojectPoint(SCNVector3(Float(x), Float(y), 1))
            return TapNavigationController.horizontalDirection(near: near, far: far)!
        }
        let center = heading(195, 422), left = heading(40, 422), right = heading(350, 422)
        #expect(abs(yawOf(center) - 0.3) < 1e-3)          // center = today's camera forward
        #expect(yawOf(left) > 0.3 + 0.1)                  // left of center heads left (+yaw)
        #expect(yawOf(right) < 0.3 - 0.1)                 // right heads right
        #expect(abs((yawOf(left) - 0.3) + (yawOf(right) - 0.3)) < 1e-3) // symmetric
        let high = heading(40, 100), low = heading(40, 780)
        #expect(abs(yawOf(high) - yawOf(left)) < 1e-3 && abs(yawOf(low) - yawOf(left)) < 1e-3) // screen Y: no effect
    }

    @Test func pinchScrubsAlongItsDirectionWithoutTurningOrFlying() async {
        let c = makeController(extraCells: room, yawOffset: 0.37)
        offCenter(c)
        let p0 = pos(c), yaw0 = yaw(c)
        let dir = FreeWalkGeometry.forward(yaw: yaw0 + 0.6) // a point well left of center
        c.beginDragMove(travelDirection: dir)
        #expect(c.cameraNode.action(forKey: "freeLookAlign") == nil)
        c.updateDragMove(fraction: 0.5)           // pinch out = forward, same scale math
        #expect(abs(Double(pos(c).x - p0.x) - dir.x * 0.5 * cs) < 1e-3)
        #expect(abs(Double(pos(c).z - p0.z) - dir.z * 0.5 * cs) < 1e-3)
        c.updateDragMove(fraction: -0.25)         // pinch in = backward along the same line
        let back = pos(c)
        #expect(abs(Double(back.x - p0.x) + dir.x * 0.25 * cs) < 1e-3)
        #expect(abs(Double(back.z - p0.z) + dir.z * 0.25 * cs) < 1e-3)
        #expect(back.y == p0.y)                   // never flies
        #expect(abs(yaw(c) - yaw0) < 1e-6)        // never turns the head
        c.endDragMove(fraction: -0.25, velocityFraction: 4)
        await settle(c, frames: 60)
        #expect(SCNVector3EqualToVector3(pos(c), back))
        #expect(abs(yaw(c) - yaw0) < 1e-6)

        // nil direction = camera forward (the old center behaviour).
        let d = makeController(extraCells: room, yawOffset: 0.37)
        offCenter(d)
        d.beginDragMove(travelDirection: nil)
        d.updateDragMove(fraction: 0.4)
        let f = FreeWalkGeometry.forward(yaw: yaw0)
        #expect(abs(Double(pos(d).x - p0.x) - f.x * 0.4 * cs) < 1e-3)
        d.endDragMove(fraction: 0.4)
    }

    @Test func offCenterPinchIntoAWallSlides() {
        let c = makeController() // looking east down the corridor
        c.cameraNode.position = at(6 * cs, northLimit + 0.02)
        let p = pos(c), yaw0 = yaw(c)
        let dir = FreeWalkGeometry.forward(yaw: yaw0 + .pi / 3) // pinch far left: toward the north wall
        c.beginDragMove(travelDirection: dir)
        c.updateDragMove(fraction: 1)
        #expect(Double(pos(c).x - p.x) > 1.6)             // along-wall part kept (Pass #4)
        #expect(Double(pos(c).z) >= northLimit - 1e-6)
        #expect(abs(yaw(c) - yaw0) < 1e-6)
        c.endDragMove(fraction: 1)
    }

    // MARK: - Polish pass #6: EDDIE HAS A BODY

    @Test func bodyClearanceKeepsTheEyesOffTheWallpaper() async {
        #expect(margin == 0.5)
        // Wall panels: 0.1 m boxes centred on the boundary -> visible face 0.05 m in.
        let eyeToWallpaper = margin - 0.05
        #expect(abs(eyeToWallpaper - 0.45) < 1e-9)
        let g = makeController().makeFreeWalkGeometry()
        #expect(g.wallMargin == margin)
        let boundary = 5 * cs - cs / 2 // north boundary line of row 5
        // Nothing legal inside the clearance; legal right at it.
        #expect(!g.isLegal(x: 6 * cs, z: boundary + margin - 0.001))
        #expect(g.isLegal(x: 6 * cs, z: boundary + margin + 0.001))

        // Dead-on tap stops at the clearance; peel away works at once; yaw untouched.
        let c = makeController(yawOffset: .pi / 2) // north
        let yaw0 = yaw(c)
        c.advance()
        await settle(c)
        #expect(abs(Double(pos(c).z) - (boundary + margin)) < 0.03)
        #expect(abs(yaw(c) - yaw0) < 1e-6)
        let atWall = pos(c)
        let away = g.slideEndpoint(from: atWall, dx: 0.3, dz: 0.3) // along + away from the wall
        #expect(abs(Double(away.x - atWall.x) - 0.3) < 1e-4 && abs(Double(away.z - atWall.z) - 0.3) < 1e-4)

        // Reverse, pan and pinch all stop at the same clearance.
        let r = makeController(yawOffset: -.pi / 2) // facing south: backing = north
        r.setWalkingHeld(true)
        r.advanceWhileHeld()
        r.updateHeldNavigation(fingerX: 0, fingerY: 0, pointsPerQuarterTurn: ppq)
        r.updateHeldNavigation(fingerX: 0, fingerY: -120, pointsPerQuarterTurn: ppq)
        await settle(r, frames: 40)
        #expect(abs(Double(pos(r).z) - (boundary + margin)) < 0.03)
        r.setWalkingHeld(false)
        await settle(r, frames: 3)

        let p = makeController(yawOffset: .pi / 2)
        #expect(p.beginFreePan())
        p.updateFreePan(dx: 0, dy: 400, pointsPerQuarterTurn: ppq, pointsPerCell: 140)
        #expect(abs(Double(pos(p).z) - (boundary + margin)) < 0.03)
        p.endFreePan(dx: 0, pointsPerQuarterTurn: ppq)

        let n = makeController()
        n.beginDragMove(travelDirection: (0, -1)) // pinch toward the north wall
        n.updateDragMove(fraction: 2)
        #expect(abs(Double(pos(n).z) - (boundary + margin)) < 0.03)
        n.endDragMove(fraction: 2)
    }

    @Test func bodyStillFitsThroughOpeningsAndDoorsStaySolid() {
        // Open side (5,7) -> (4,7): a full-cell opening, cs - 2*margin wide at the corner posts.
        let g = makeController(extraCells: [GridCoordinate(row: 4, col: 7)]).makeFreeWalkGeometry()
        let x = 7 * cs, start = at(x, 5 * cs)
        let through = g.slideEndpoint(from: start, dx: 0, dz: -cs)
        #expect(abs(Double(through.z) - 4 * cs) < 1e-4) // straight through, unobstructed
        for offset in [-(cs / 2 - margin) + 0.01, (cs / 2 - margin) - 0.01] { // hugging either post
            let e = g.slideEndpoint(from: at(x + offset, 5 * cs), dx: 0, dz: -cs)
            #expect(abs(Double(e.z) - 4 * cs) < 1e-4)
        }
        // Corner post: nothing legal within the (rounded, Sept 30) clearance
        // of the corner point, and a slide never enters it.
        let post = (x: x - cs / 2, z: 5 * cs - cs / 2)
        #expect(!g.isLegal(x: post.x + margin * 0.7, z: post.z + margin * 0.7)) // 0.99 * margin away
        let path = g.slidePath(from: at(6 * cs, 5 * cs - (cs / 2 - margin) + 0.01), dx: cs, dz: -cs)
        #expect(path.allSatisfy { g.isLegal(x: Double($0.x), z: Double($0.z)) })
        // Closed door: still solid at the new clearance.
        let doored = makeController(bathroomDoors: [GridCoordinate(row: 5, col: 7): .east]).makeFreeWalkGeometry()
        let d = doored.slideEndpoint(from: at(7 * cs, 5 * cs), dx: cs, dz: 0)
        #expect(abs(Double(d.x) - (7 * cs + cs / 2 - margin)) < 0.03)
    }

    // MARK: Rounded inner corners (Sept 30 experiment)

    /// The L at (0,0)/(0,1)/(1,0): the inner corner point is (cs/2, cs/2).
    private func lCorner() -> FreeWalkGeometry {
        FreeWalkGeometry(cells: [GridCoordinate(row: 0, col: 0), GridCoordinate(row: 0, col: 1), GridCoordinate(row: 1, col: 0)],
            openEdges: [.init(cell: GridCoordinate(row: 0, col: 0), direction: .east), .init(cell: GridCoordinate(row: 0, col: 0), direction: .south),
                        .init(cell: GridCoordinate(row: 0, col: 1), direction: .west), .init(cell: GridCoordinate(row: 1, col: 0), direction: .north)],
            cellSize: cs)
    }

    @Test func innerCornerClearanceIsRoundNotSquare() {
        let g = lCorner(), half = cs / 2, limit = cs / 2 - margin
        #expect(g.isLegal(x: limit + 0.02, z: limit + 0.02))                 // old square tip: now legal
        #expect(!g.isLegal(x: half - 0.34, z: half - 0.34))                 // 0.48 m from the corner point
        #expect(!g.isLegal(x: limit + 0.02, z: cs))                         // wall faces: clearance unchanged
        #expect(!g.isLegal(x: cs, z: limit + 0.02))
        #expect(g.isLegal(x: limit, z: cs) && g.isLegal(x: cs, z: limit))
        #expect(g.innerCornerPost(x: limit + 0.02, z: limit + 0.02).map { $0.x == half && $0.z == half } == true)
        #expect(g.innerCornerPost(x: 0, z: 0) == nil)
    }

    @Test func steeringAroundAnInsideCornerNoLongerCatches() {
        // Coming north up (1,0) hugging its east wall, just reaching the wall's
        // end, heading 80 degrees right (mostly into the corner): before, the
        // slide crawled north along the corner face at ~17% speed; now it
        // follows the rounded corner into (0,1) without ever entering it.
        let g = lCorner(), half = cs / 2, limit = cs / 2 - margin
        let start = SCNVector3(Float(limit), 0, Float(half - 0.05))
        let heading = 80.0 * .pi / 180
        let path = g.slidePath(from: start, dx: sin(heading) * 1.5, dz: -cos(heading) * 1.5)
        #expect(Double(path.last!.x) > half + 0.2)
        #expect(path.allSatisfy { g.isLegal(x: Double($0.x), z: Double($0.z)) })
        #expect(path.allSatisfy { hypot(Double($0.x) - half, Double($0.z) - half) >= margin - 1e-6 })
        for i in 1..<path.count { #expect(hypotf(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z) <= 0.0201) } // never faster
    }

    @Test func deadOnIntoTheCornerStillStops() {
        let g = lCorner(), half = cs / 2
        let start = SCNVector3(0.2, 0, 0.2)
        let d = hypot(half - 0.2, half - 0.2)
        let e = g.slideEndpoint(from: start, dx: (half - 0.2) / d * 2, dz: (half - 0.2) / d * 2)
        #expect(abs(hypot(Double(e.x) - half, Double(e.z) - half) - margin) < 0.03) // stopped at the clearance
    }

    // MARK: Held-walk turn-rate limit (Sept 30 experiment)

    @Test func heldTurnRateHelperLimitsOnlyTheRate() {
        let f = TapNavigationController.rateLimitedYaw
        #expect(f(1.0, 1.05, 0.1) == 1.05)                         // small request: reached at once
        #expect(abs(f(1.0, 2.5, 0.1) - 1.1) < 1e-12)              // large request: limited
        #expect(abs(f(1.0, -0.5, 0.1) - 0.9) < 1e-12)             // either direction
        var yaw = 0.0
        for _ in 0..<200 { yaw = f(yaw, 3 * .pi, 0.1) }           // 540 deg: reached, no angle clamp,
        #expect(yaw == 3 * .pi)                                    // no "shortest way round" wrap
        #expect(f(3.14, -3.14, 0.1) < 3.14)                       // unwrapped: turns the way the finger asked
        #expect(abs(f(2.0, 1.95, 0.1) - 1.95) < 1e-12)            // target pulled back: stops/reverses, no momentum
    }

    @Test func heldTurnRateArcsLargeInputWhileMovingAndNeverOvershoots() async {
        let controller = makeController(extraCells: room)
        controller.heldWalkTurnRateLimit = TapNavigationController.heldWalkMaxTurnRate
        let yaw0 = yaw(controller)
        controller.setWalkingHeld(true)
        controller.advanceWhileHeld()
        controller.updateHeldWalkSteering(fingerX: 100, pointsPerQuarterTurn: ppq)
        await settle(controller, frames: 5)
        // Sudden large excursion: 90 degrees requested at once.
        controller.updateHeldWalkSteering(fingerX: 100 + ppq, pointsPerQuarterTurn: ppq)
        #expect(abs(yaw(controller) - yaw0) < 1e-6)                // no instant swerve
        #expect(abs(controller.heldSteeringTargetYaw - expectedYaw(yaw0, ppq)) < 1e-9)
        await settle(controller, frames: 6)                        // 0.1 s
        let partial = yaw(controller) - yaw0
        #expect(partial > 0.05 && partial < TapNavigationController.heldWalkMaxTurnRate * 0.11)
        await settle(controller, frames: 40)                       // well past 0.5 s
        #expect(abs(yaw(controller) - expectedYaw(yaw0, ppq)) < 1e-5) // arrives, exactly, no overshoot
        // Change of mind: finger back to centre -> turn back, then stop there.
        controller.updateHeldWalkSteering(fingerX: 100, pointsPerQuarterTurn: ppq)
        await settle(controller, frames: 40)
        #expect(abs(yaw(controller) - yaw0) < 1e-5)
        let settled = yaw(controller)
        await settle(controller, frames: 10)
        #expect(yaw(controller) == settled)                        // no rotational momentum
        controller.setWalkingHeld(false)
        await settle(controller, frames: 3)
    }

    @Test func heldTurnRateDoesNotSlowTurningInPlace() async {
        let controller = makeController(extraCells: room)
        controller.heldWalkTurnRateLimit = TapNavigationController.heldWalkMaxTurnRate
        let yaw0 = yaw(controller)
        controller.setWalkingHeld(true)
        controller.advanceWhileHeld()
        controller.updateHeldNavigation(fingerX: 200, fingerY: 400, pointsPerQuarterTurn: ppq)
        controller.updateHeldNavigation(fingerX: 200, fingerY: 340, pointsPerQuarterTurn: ppq) // neutral: stopped
        #expect(controller.heldThrottle == 0)
        controller.updateHeldNavigation(fingerX: 200 + ppq, fingerY: 340, pointsPerQuarterTurn: ppq)
        #expect(abs(yaw(controller) - expectedYaw(yaw0, ppq)) < 1e-5) // immediate, as before
        controller.setWalkingHeld(false)
        await settle(controller, frames: 3)
    }

    // MARK: Tap where you want to go (Sept 30 experiment)

    @Test func tapBearingYawIsExactAndTurnsTheShortWay() {
        for y in [0.0, 0.3, -1.2, 2.9, -3.1] {
            let d = FreeWalkGeometry.forward(yaw: y)
            #expect(abs(TapNavigationController.yaw(facing: d, near: y) - y) < 1e-9)
        }
        // Across the +-pi seam: 3.0 -> the bearing of -3.0 is +0.28 rad, not -6.
        let r = TapNavigationController.yaw(facing: FreeWalkGeometry.forward(yaw: -3.0), near: 3.0)
        #expect(abs(r - (3.0 + (2 * .pi - 6.0))) < 1e-9)
        // Unwrapped current yaw (after many held turns) stays unwrapped.
        let u = TapNavigationController.yaw(facing: FreeWalkGeometry.forward(yaw: 0.2), near: 4 * .pi)
        #expect(abs(u - (4 * .pi + 0.2)) < 1e-9)
    }

    @Test func tapOffCentreWalksOneCellThatWayAndTurnsToIt() async {
        let controller = makeController(extraCells: room)
        let p0 = pos(controller), yaw0 = yaw(controller)
        let tapped = yaw0 - 37 * .pi / 180                         // 37 degrees right: arbitrary, not a cardinal
        controller.advance(travelDirection: FreeWalkGeometry.forward(yaw: tapped))
        await settle(controller, frames: 10)
        let midway = yaw(controller)
        #expect(midway < yaw0 && midway > tapped)                 // turning smoothly, not snapped
        await settle(controller, frames: 60)
        #expect(!controller.isAnimating)
        #expect(abs(yaw(controller) - tapped) < 1e-5)              // exactly the tapped bearing
        let p1 = pos(controller)
        let dx = Double(p1.x - p0.x), dz = Double(p1.z - p0.z)
        #expect(abs((dx * dx + dz * dz).squareRoot() - cs) < 0.02) // one cell, as before
        let f = FreeWalkGeometry.forward(yaw: tapped)
        #expect(abs(dx / cs - f.x) < 0.01 && abs(dz / cs - f.z) < 0.01) // along the tapped bearing
    }

    @Test func tapTowardAWallStillStopsAtTheWall() async {
        let controller = makeController()                          // one-row corridor, east-west
        let p0 = pos(controller), yaw0 = yaw(controller)
        let northish = yaw0 + 80 * .pi / 180                       // tap high on the left: nearly north
        controller.advance(travelDirection: FreeWalkGeometry.forward(yaw: northish))
        await settle(controller, frames: 70)
        let p1 = pos(controller)
        #expect(Double(p1.z) >= Double(p0.z) - (cs / 2 - margin) - 1e-4) // never through the north wall
        #expect(Double(p1.x) > Double(p0.x))                       // what's legal (the east part) survives
    }

    // MARK: Tap a place -> go there / tap again -> stop (Sept 30 experiment)

    @Test func tapWalkProfileIsNormalWalkingSpeedWithShortEases() {
        let v = 6.0, a = TapNavigationController.freeTapRamp, length = 20.0
        var last = 0.0, peak = 0.0
        for i in 1...400 {
            let e = Double(i) / 100
            let d = TapNavigationController.tapWalkDistance(elapsed: e, length: length, speed: v, ramp: a)
            #expect(d >= last - 1e-12)                            // never goes backwards
            peak = max(peak, (d - last) / 0.01)
            last = d
        }
        #expect(last == length)                                   // arrives exactly
        #expect(peak <= v + 1e-6)                                 // walking pace, not a cruise missile
        #expect(abs(TapNavigationController.tapWalkDistance(elapsed: length / v + a, length: length, speed: v, ramp: a) - length) < 1e-12)
    }

    @Test func destinationTapWalksTheRealDistanceAcrossCells() async {
        let controller = makeController(extraCells: room)
        let p0 = pos(controller), yaw0 = yaw(controller)
        let far = 3.2 * cs                                         // past one cell, not a multiple of it
        controller.advance(travelDirection: FreeWalkGeometry.forward(yaw: yaw0), travelDistance: far)
        await settle(controller, frames: 60)                       // 1 s in
        let mid = Double(pos(controller).x - p0.x)
        #expect(mid > 4.5 && mid < 6.0)                            // normal pace, still walking
        #expect(controller.isFreeTapWalking)
        await settle(controller, frames: 120)
        #expect(!controller.isAnimating)
        #expect(abs(Double(pos(controller).x - p0.x) - far) < 0.02) // exactly the requested distance
        #expect(controller.currentCell == GridCoordinate(row: 5, col: 9)) // cells tracked on the way
        // Short destination: short walk.
        let q0 = pos(controller)
        controller.advance(travelDirection: FreeWalkGeometry.forward(yaw: yaw0), travelDistance: 0.8)
        await settle(controller, frames: 60)
        #expect(abs(Double(pos(controller).x - q0.x) - 0.8) < 0.02)
    }

    @Test func longDestinationTurnFinishesEarlyAndBearingIsExact() async {
        let controller = makeController(extraCells: room)
        let yaw0 = yaw(controller)
        let bearing = yaw0 + 23 * .pi / 180
        controller.advance(travelDirection: FreeWalkGeometry.forward(yaw: bearing), travelDistance: 2.5 * cs)
        await settle(controller, frames: 40)                       // ~0.67 s of a ~1.8 s walk
        #expect(controller.isFreeTapWalking)
        #expect(abs(yaw(controller) - bearing) < 1e-5)             // turned on the tap timescale, exact bearing
        await settle(controller, frames: 120)
        #expect(abs(yaw(controller) - bearing) < 1e-5)
    }

    @Test func tapToStopLeavesPlayerExactlyWhereAndHowTheyWere() async {
        let controller = makeController(extraCells: room)
        let p0 = pos(controller), yaw0 = yaw(controller)
        let bearing = yaw0 - 60 * .pi / 180
        controller.advance(travelDirection: FreeWalkGeometry.forward(yaw: bearing), travelDistance: 3 * cs)
        await settle(controller, frames: 12)
        controller.stopFreeTapWalk()
        await settle(controller, frames: 1)                        // applied on the next frame
        let stopped = pos(controller), stoppedYaw = yaw(controller)
        await settle(controller, frames: 30)
        #expect(!controller.isAnimating && !controller.isFreeTapWalking)
        #expect(SCNVector3EqualToVector3(pos(controller), stopped)) // no snap to destination or grid
        #expect(yaw(controller) == stoppedYaw)                     // pending turn NOT finished
        #expect(stoppedYaw < yaw0 && stoppedYaw > bearing)
        let moved = hypot(Double(stopped.x - p0.x), Double(stopped.z - p0.z))
        #expect(moved > 0.05 && moved < 2)
        #expect(controller.currentCell == FreeWalkGeometry.containingCell(x: Double(stopped.x), z: Double(stopped.z), cellSize: cs)
                || controller.currentCell == start)
        // Next tap starts a new walk normally.
        controller.advance(travelDirection: FreeWalkGeometry.forward(yaw: yaw0), travelDistance: 1)
        #expect(controller.isFreeTapWalking)
        await settle(controller, frames: 60)
    }

    @Test func destinationUnderThePlayerDoesNothing() async {
        let controller = makeController()
        let p0 = pos(controller), yaw0 = yaw(controller)
        controller.advance(travelDirection: FreeWalkGeometry.forward(yaw: yaw0 + 1), travelDistance: 0.01)
        #expect(!controller.isAnimating)
        await settle(controller, frames: 10)
        #expect(SCNVector3EqualToVector3(pos(controller), p0))
        #expect(yaw(controller) == yaw0)                           // no spin, no NaN
    }

    @Test func longDestinationThroughAWallStopsAtClearance() async {
        let controller = makeController()                          // corridor row 5, cols 5...9
        let yaw0 = yaw(controller)
        controller.advance(travelDirection: FreeWalkGeometry.forward(yaw: yaw0), travelDistance: 40)
        await settle(controller, frames: 200)
        #expect(!controller.isAnimating)
        let x = Double(pos(controller).x)
        #expect(x <= 9 * cs + (cs / 2 - margin) + 1e-4)           // never through the end wall
        #expect(x > 9 * cs + (cs / 2 - margin) - 0.03)             // walked all the way to it
    }
}
