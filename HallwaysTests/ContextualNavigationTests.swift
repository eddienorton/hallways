import Testing
import SceneKit
import Combine
import Foundation
@testable import Hallways

/// Oct 10: the contextual center button and walking assistance
/// (TapNavigationController "CONTEXTUAL NAVIGATION"). Corridor row 5 from
/// col 5, player starts at (5,6) facing east; each test adds what it needs.
@MainActor
@Suite(.serialized)
struct ContextualNavigationTests {
    private let cs = 3.52
    private let start = GridCoordinate(row: 5, col: 6)

    private func makeController(lastCol: Int = 9, extra: Set<GridCoordinate> = [],
                                bathroomDoors: [GridCoordinate: Direction] = [:],
                                roomEntranceDoors: [GridCoordinate: Direction] = [:],
                                startCol: Int? = nil, startX: Double? = nil) -> TapNavigationController {
        let camera = SCNNode()
        camera.position = SCNVector3(Float(startX ?? Double(startCol ?? start.col) * cs), 1.6, Float(Double(start.row) * cs))
        camera.eulerAngles = SCNVector3(0, Float(Direction.east.yaw), 0)
        let cells = Set((5...lastCol).map { GridCoordinate(row: 5, col: $0) }).union(extra)
        let startCell = GridCoordinate(row: 5, col: startCol ?? start.col)
        let controller = TapNavigationController(cameraNode: camera, scene: SCNScene(), cells: cells, cellSize: CGFloat(cs),
            startCell: startCell, startFacing: .east, endCell: GridCoordinate(row: 5, col: 5), floorNumber: 3,
            bathroomDoors: bathroomDoors, roomEntranceDoors: roomEntranceDoors)
        controller.freeWalkEnabled = true
        return controller
    }

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
    private func settleUntilStopped(_ c: TapNavigationController, cap: Int = 900) async {
        for _ in 0..<cap {
            await settle(c, frames: 1)
            if c.continuousWalkState == .stopped && !c.isAnimating { return }
        }
    }
    private func x(_ c: TapNavigationController) -> Double { Double(c.cameraNode.position.x) }
    private func z(_ c: TapNavigationController) -> Double { Double(c.cameraNode.position.z) }

    // 11. A forced L-corner (dead end, one way on) is rounded and the walk goes on.
    @Test func forcedLCornerTurnsAndContinues() async {
        let c = makeController(extra: [GridCoordinate(row: 6, col: 9), GridCoordinate(row: 7, col: 9)])
        c.hudCenterTapped()
        #expect(c.continuousWalkState == .walking)
        await settleUntilStopped(c)
        #expect(c.facing == .south)
        #expect(c.currentCell == GridCoordinate(row: 7, col: 9))
        #expect(abs(x(c) - 9 * cs) < 0.02)                  // on the new corridor's centreline
    }

    // 12. A T (both sides open, nothing queued) keeps the player's choice: stop.
    @Test func tIntersectionStopsForAChoice() async {
        let c = makeController(extra: [GridCoordinate(row: 4, col: 9), GridCoordinate(row: 6, col: 9)])
        c.hudCenterTapped()
        await settleUntilStopped(c)
        #expect(c.facing == .east)
        // Oct 10 (Smart WALK): stopped just short of the T's mouth, in view of both ways.
        #expect(abs(x(c) - (9 * cs - cs / 2 - TapNavigationController.smartWalkDecisionStopShort)) < 0.05)
        #expect(c.hudCenter == .walk)
    }

    // Oct 10 (Smart WALK). A crossing with straight on: the walk stops on the
    // crossing cell's centre; WALK again carries straight on.
    @Test func smartWalkStopsAtACrossingAndWalkAgainGoesStraight() async {
        let c = makeController(lastCol: 11, extra: [GridCoordinate(row: 4, col: 8), GridCoordinate(row: 6, col: 8)])
        c.hudCenterTapped()
        await settleUntilStopped(c)
        #expect(abs(x(c) - (8 * cs - cs / 2 - TapNavigationController.smartWalkDecisionStopShort)) < 0.05)
        #expect(c.facing == .east)                           // just short of the crossing's mouth
        c.hudCenterTapped()
        await settleUntilStopped(c)
        #expect(c.currentCell == GridCoordinate(row: 5, col: 11))
    }

    // Oct 10 (Smart WALK). At a decision stop, LEFT = walk on and corner that way.
    @Test func smartWalkTurnAtADecisionWalksOn() async {
        let c = makeController(lastCol: 11, extra: [GridCoordinate(row: 4, col: 8), GridCoordinate(row: 3, col: 8),
                                                    GridCoordinate(row: 6, col: 8)])
        c.hudCenterTapped()
        await settleUntilStopped(c)
        #expect(c.continuousWalkState == .stopped)
        c.continuousWalkTurnTapped(.left)                    // walk on, corner north
        #expect(c.continuousWalkState == .walkingQueued(.left))
        await settleUntilStopped(c)
        #expect(c.facing == .north)
        #expect(c.currentCell == GridCoordinate(row: 3, col: 8))
    }

    // Oct 10 (Smart WALK). A turn queued early is taken without a stop.
    @Test func smartWalkQueuedTurnSkipsTheStop() async {
        let c = makeController(lastCol: 11, extra: [GridCoordinate(row: 4, col: 8), GridCoordinate(row: 6, col: 8),
                                                    GridCoordinate(row: 7, col: 8)])
        c.hudCenterTapped()
        c.continuousWalkTurnTapped(.right)                   // south
        await settleUntilStopped(c)
        #expect(c.facing == .south)
        #expect(c.currentCell == GridCoordinate(row: 7, col: 8))
    }

    // 13. An explicit queued turn beats the corner's own way on.
    @Test func queuedTurnTakesPrecedenceAtAT() async {
        let c = makeController(extra: [GridCoordinate(row: 4, col: 9), GridCoordinate(row: 6, col: 9)])
        c.hudCenterTapped()
        c.continuousWalkTurnTapped(.left)                    // north
        await settleUntilStopped(c)
        #expect(c.facing == .north)
        #expect(c.currentCell == GridCoordinate(row: 4, col: 9))
    }

    // 5. A closed ordinary door ahead opens on approach and is walked through.
    @Test func walkOpensAndTraversesAnOrdinaryDoor() async {
        let door = GridCoordinate(row: 5, col: 9)
        let c = makeController(lastCol: 11, bathroomDoors: [door: .east])
        var opened = false
        let token = c.$openBathroomDoors.sink { if $0.contains(door) { opened = true } }
        c.hudCenterTapped()
        await settleUntilStopped(c)
        #expect(opened)                                      // (it closes behind the player as usual)
        #expect(c.currentCell == GridCoordinate(row: 5, col: 11))
        token.cancel()
    }

    // 6 + 15. A guarded door is never opened by the walk; the guard's own
    // reaction plays once the walk has stopped in front of it.
    @Test func guardedDoorStaysShutAndTheGuardReacts() async {
        let door = GridCoordinate(row: 5, col: 9)
        let c = makeController(lastCol: 11, roomEntranceDoors: [door: .east])
        c.roomEntranceDoorGuarded = { $0 == door }
        var reactions = 0
        c.onGuardedRoomEntranceDoorTap = { _ in reactions += 1 }
        c.hudCenterTapped()
        await settleUntilStopped(c)
        await settle(c, frames: 3)
        #expect(!c.openRoomEntranceDoors.contains(door))
        #expect(c.currentCell == door)                      // stopped in front of it
        #expect(reactions == 1)
        #expect(c.hudCenter == .walk)                       // no OPEN offered on a guarded door
    }

    // 7 + 9. Standing at a closed door: OPEN, which runs the door's own open.
    @Test func centerOffersOpenAtAClosedDoor() async {
        let door = GridCoordinate(row: 5, col: 9)
        let c = makeController(lastCol: 10, bathroomDoors: [door: .east], startCol: 9)
        #expect(c.hudCenter == .action("OPEN"))
        c.hudCenterTapped()
        #expect(c.openBathroomDoors.contains(door))
        #expect(c.hudCenter == .walk)
    }

    // 10. STOP only stops -- a quick second tap can't become OPEN.
    @Test func stopNeverPerformsAnInteraction() async throws {
        // Someone answers this door (an intercept), so it is still shut when
        // the walk is stopped in front of it and the button offers OPEN.
        let door = GridCoordinate(row: 5, col: 9)
        let c = makeController(lastCol: 10, roomEntranceDoors: [door: .east], startCol: 9, startX: 9 * cs - 1.0)
        var answered = 0
        c.roomEntranceDoorIntercept = { _ in answered += 1; return true }
        c.hudCenterTapped()                                  // WALK (the door is asked once: answered)
        await settle(c, frames: 4)
        #expect(answered == 1)
        c.hudCenterTapped()                                  // STOP
        #expect(c.continuousWalkState == .stopped)
        #expect(c.hudCenter == .action("OPEN"))
        c.hudCenterTapped()                                  // a fast second tap: ignored
        #expect(answered == 1)
        try await Task.sleep(nanoseconds: 550_000_000)
        c.hudCenterTapped()                                  // a deliberate OPEN: the door's own open runs
        #expect(answered == 2)
    }

    // Floor 2 report: WALK pressed while the player isn't free yet (a turn
    // still finishing) waits and then walks, instead of doing nothing.
    @Test func walkPressedWhileBusyStartsWhenFree() async {
        let c = makeController()
        c.continuousWalkTurnTapped(.left)                    // face north...
        await settle(c, frames: 40)
        c.continuousWalkTurnTapped(.right)                   // ...and back east: a pivot is running
        await settle(c, frames: 2)
        c.hudCenterTapped()                                  // WALK while busy
        #expect(c.continuousWalkState == .walking)
        #expect(c.hudCenter == .stop)
        await settleUntilStopped(c)
        #expect(c.currentCell == GridCoordinate(row: 5, col: 9))
    }
}
