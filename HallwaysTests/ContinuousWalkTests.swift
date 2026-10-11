import Testing
import SceneKit
@testable import Hallways

/// Oct 10 experiment: LEFT | WALK/STOP | RIGHT continuous walking with
/// queued turns (TapNavigationController "CONTINUOUS WALK & QUEUED TURNS").
///
/// Map (rows down, cols right), corridor row 5 from col 5 to col 12:
///
///        (4,8)          (4,11)        <- north openings  (LEFT when facing east)
///   5 ... 6  7  8  9  10  11  12      <- the corridor
///                    (6,10)           <- south opening   (RIGHT when facing east)
///                    (7,10)              dead-ends at (7,10)
@MainActor
@Suite(.serialized)
struct ContinuousWalkTests {
    private let cs = 3.52
    private let start = GridCoordinate(row: 5, col: 6)

    private func makeController(startX: Double? = nil) -> TapNavigationController {
        let camera = SCNNode()
        camera.position = SCNVector3(Float(startX ?? Double(start.col) * cs), 1.6, Float(Double(start.row) * cs))
        camera.eulerAngles = SCNVector3(0, Float(Direction.east.yaw), 0)
        var cells = Set((5...12).map { GridCoordinate(row: 5, col: $0) })
        cells.formUnion([GridCoordinate(row: 4, col: 8), GridCoordinate(row: 4, col: 11),
                         GridCoordinate(row: 6, col: 10), GridCoordinate(row: 7, col: 10)])
        let controller = TapNavigationController(cameraNode: camera, scene: SCNScene(), cells: cells, cellSize: CGFloat(cs),
            startCell: start, startFacing: .east, endCell: GridCoordinate(row: 5, col: 5), floorNumber: 3)
        controller.freeWalkEnabled = true
        // Oct 10: these cover the walk/queue/arc mechanics on a corridor with
        // side branches; Smart WALK's decision stops have their own tests
        // (ContextualNavigationTests).
        controller.smartWalkDecisionStopsOn = false
        return controller
    }

    private final class Clock { var time = 1.0 }
    private let clock = Clock()
    private func settle(_ controller: TapNavigationController, frames: Int) async {
        let renderer = SCNRenderer(device: nil, options: nil)
        for _ in 0..<frames {
            clock.time += 1.0 / 60
            controller.renderer(renderer, updateAtTime: clock.time)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }
    /// Frames until the walk is over (or the cap).
    private func settleUntilStopped(_ controller: TapNavigationController, cap: Int = 900) async {
        for _ in 0..<cap {
            await settle(controller, frames: 1)
            if controller.continuousWalkState == .stopped && !controller.isAnimating { return }
        }
    }
    private func x(_ c: TapNavigationController) -> Double { Double(c.cameraNode.position.x) }
    private func z(_ c: TapNavigationController) -> Double { Double(c.cameraNode.position.z) }

    // 1. WALK starts continuous forward movement (no finger involved).
    @Test func walkStartsContinuousMovement() async {
        let c = makeController()
        c.continuousWalkButtonTapped()
        #expect(c.continuousWalkState == .walking)
        #expect(c.isAnimating)
        await settle(c, frames: 20)
        let x1 = x(c)
        #expect(x1 > Double(start.col) * cs + 0.2)
        await settle(c, frames: 10)
        #expect(x(c) > x1)                       // still going on its own
        #expect(abs(z(c) - 5 * cs) < 1e-3)        // straight down the corridor
    }

    // 2. STOP halts at once, in place.
    @Test func stopHaltsImmediately() async {
        let c = makeController()
        c.continuousWalkButtonTapped()
        await settle(c, frames: 25)
        c.continuousWalkButtonTapped()
        #expect(c.continuousWalkState == .stopped)
        #expect(!c.isAnimating)
        let here = x(c)
        await settle(c, frames: 20)
        #expect(abs(x(c) - here) < 1e-6)
    }

    // 3. Stationary LEFT / RIGHT are clean 90-degree pivots, nothing queued.
    @Test func stationaryArrowsPivotNinetyDegrees() async {
        let c = makeController()
        c.continuousWalkTurnTapped(.left)
        #expect(c.continuousWalkState == .stopped)
        await settle(c, frames: 60)
        #expect(c.facing == .north)
        #expect(abs(Double(c.cameraNode.eulerAngles.y) - Direction.north.yaw) < 1e-4)
        c.continuousWalkTurnTapped(.right)
        await settle(c, frames: 60)
        #expect(c.facing == .east)
        c.continuousWalkTurnTapped(.right)
        await settle(c, frames: 60)
        #expect(c.facing == .south)
        #expect(!c.isAnimating)
        #expect(c.continuousWalkState == .stopped)
    }

    // Addendum: a HUD pivot is a ~0.30 s eased turn, not a snap, and a
    // second press during it runs afterwards instead of overlapping.
    @Test func hudPivotIsEasedAndPressesDuringItQueue() async {
        let c = makeController()
        let start = Double(c.cameraNode.eulerAngles.y)
        c.continuousWalkTurnTapped(.left)
        await settle(c, frames: 9)                      // ~0.15 s: mid-turn
        let mid = Double(c.cameraNode.eulerAngles.y) - start
        #expect(mid > 0.2 && mid < .pi / 2 - 0.2)       // genuinely in between
        c.continuousWalkTurnTapped(.left)               // pressed mid-turn
        await settle(c, frames: 60)
        #expect(c.facing == .west)                      // both turns, one after the other
        #expect(abs(Double(c.cameraNode.eulerAngles.y) - (start + .pi)) < 1e-4)
        #expect(!c.isAnimating)
    }

    // 4 + 5. A queued RIGHT skips col 8 (north only) and turns at col 10,
    // rounding the corner onto the new corridor's centreline.
    @Test func queuedTurnWaitsForTheFirstValidOpening() async {
        let c = makeController()
        c.continuousWalkButtonTapped()
        c.continuousWalkTurnTapped(.right)
        #expect(c.continuousWalkState == .walkingQueued(.right))
        var minZ = Double.infinity, maxXBeforeTurn = -Double.infinity
        var turnedAt: Double?
        for _ in 0..<900 {
            await settle(c, frames: 1)
            if turnedAt == nil, z(c) > 5 * cs + 0.01 { turnedAt = x(c) }
            if turnedAt == nil { maxXBeforeTurn = max(maxXBeforeTurn, x(c)) }
            minZ = min(minZ, z(c))
            if c.continuousWalkState == .stopped && !c.isAnimating { break }
        }
        #expect(minZ > 5 * cs - 1e-3)                  // never turned north at col 8
        #expect(turnedAt != nil)
        #expect(maxXBeforeTurn < 10 * cs)               // turn began before the crossing centre
        #expect(c.facing == .south)
        #expect(abs(x(c) - 10 * cs) < 0.02)             // ends on the new corridor's centreline
        #expect(c.currentCell == GridCoordinate(row: 7, col: 10))  // then on to the dead end
        #expect(c.continuousWalkState == .stopped)      // lit arrow cleared, WALK restored
    }

    // 6 + 7. Same arrow twice cancels; the opposite arrow replaces.
    @Test func lastPressWins() {
        let c = makeController()
        c.continuousWalkButtonTapped()
        c.continuousWalkTurnTapped(.left)
        #expect(c.continuousWalkState == .walkingQueued(.left))
        c.continuousWalkTurnTapped(.right)
        #expect(c.continuousWalkState == .walkingQueued(.right))
        c.continuousWalkTurnTapped(.right)
        #expect(c.continuousWalkState == .walking)
        c.continuousWalkTurnTapped(.left)
        c.continuousWalkTurnTapped(.left)
        #expect(c.continuousWalkState == .walking)
        c.stopContinuousWalk(reason: "test")
    }

    // 8. STOP cancels a pending turn.
    @Test func stopCancelsPendingTurn() async {
        let c = makeController()
        c.continuousWalkButtonTapped()
        c.continuousWalkTurnTapped(.right)
        await settle(c, frames: 5)
        c.continuousWalkButtonTapped()
        #expect(c.continuousWalkState == .stopped)
        // WALK again: the old request must not come back.
        c.continuousWalkButtonTapped()
        #expect(c.continuousWalkState == .walking)
        await settleUntilStopped(c)
        #expect(c.facing == .east)                      // never turned south at col 10
        #expect(c.currentCell == GridCoordinate(row: 5, col: 12))
    }

    // 9. A dead end stops safely at wall clearance, WALK restored, and a
    // fresh WALK into the wall doesn't push.
    @Test func deadEndStopsSafely() async {
        let c = makeController()
        c.continuousWalkButtonTapped()
        await settleUntilStopped(c)
        #expect(c.continuousWalkState == .stopped)
        #expect(!c.isAnimating)
        let wallStop = 12 * cs + cs / 2 - FreeWalkGeometry.playerClearance
        #expect(abs(x(c) - wallStop) < 0.05)
        c.continuousWalkButtonTapped()
        await settleUntilStopped(c, cap: 30)
        #expect(c.continuousWalkState == .stopped)
        #expect(x(c) <= wallStop + 1e-6)
    }

    // A turn is never taken at an opening already passed.
    @Test func neverTurnsIntoAPassedOpening() async {
        // Just past col 8's turn entry point (its centre minus the radius).
        let c = makeController(startX: 8 * cs + 0.05)
        c.continuousWalkButtonTapped()
        c.continuousWalkTurnTapped(.left)
        var turnedAt: Double?
        for _ in 0..<900 {
            await settle(c, frames: 1)
            if turnedAt == nil, z(c) < 5 * cs - 0.01 { turnedAt = x(c) }
            if c.continuousWalkState == .stopped && !c.isAnimating { break }
        }
        #expect(turnedAt != nil)
        #expect((turnedAt ?? 0) > 10 * cs)              // turned at col 11, not col 8
        #expect(c.facing == .north)
        #expect(abs(x(c) - 11 * cs) < 0.02)
    }

    // 10 (part). A reset (floor change / Start Over) clears all of it.
    @Test func resetClearsTheWalk() async {
        let c = makeController()
        c.continuousWalkButtonTapped()
        c.continuousWalkTurnTapped(.left)
        await settle(c, frames: 5)
        c.reset()
        #expect(c.continuousWalkState == .stopped)
        let here = x(c)
        await settle(c, frames: 10)
        #expect(abs(x(c) - here) < 1e-6)
    }

    // 11 (part). A gesture-driven walk takes over (tap walk start stops it).
    @Test func holdTakesOverFromTheWalk() async {
        let c = makeController()
        c.continuousWalkButtonTapped()
        await settle(c, frames: 5)
        c.stopContinuousWalk(reason: "hold")            // what every scene gesture does first
        c.setWalkingHeld(true)
        c.advanceWhileHeld()
        #expect(c.continuousWalkState == .stopped)
        #expect(c.isAnimating)                          // the ordinary held walk is running
        c.setWalkingHeld(false)
        await settle(c, frames: 5)
        #expect(!c.isAnimating)
    }
}
