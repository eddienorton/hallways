import Testing
import SceneKit
@testable import Hallways

/// Oct 19 -- the player and residents share the car; the player's tap and a
/// character's door cycle go through THE car (here: the doors; elsewhere: called).
@MainActor
struct ElevatorSharingTests {
    /// A one-cell floor standing at its elevator (doors to the east), F2 -> F3.
    private func controller() -> (TapNavigationController, SCNNode, SCNNode) {
        let cell = GridCoordinate(row: 0, col: 0)
        let left = SCNNode(), right = SCNNode()
        left.position = SCNVector3(1.6, 1.2, -0.4)
        right.position = SCNVector3(1.6, 1.2, 0.4)
        let c = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: [cell], cellSize: 3.2,
                                        startCell: cell, startFacing: .east, endCell: cell,
                                        elevatorLeftDoor: left, elevatorRightDoor: right, elevatorMountDirection: .east,
                                        floorNumber: 2, nextFloorNumber: 3)
        return (c, left, right)
    }

    @Test func aResidentsDoorCycleCanBeJoined() {
        let (c, _, _) = controller()
        #expect(c.elevatorDoorsShut)
        let ok = c.runCharacterElevatorDeparture(who: "feddy", purpose: .departure(to: 5), resident: true,
                                                 boarding: { done in done() }, completion: {})
        #expect(ok)
        #expect(c.characterUsingElevator)
        #expect(c.characterCycleJoinable)
        #expect(c.playerElevatorRefusal == nil)            // (the doors are a resident's: the player may get in too)
    }

    @Test func aScriptedCharactersCycleStillQueuesThePlayer() {
        let (c, _, _) = controller()
        let ok = c.runCharacterElevatorDeparture(who: "tinky (escort)", boarding: { done in done() }, completion: {})
        #expect(ok)
        #expect(!c.characterCycleJoinable)
        #expect(c.playerElevatorRefusal != nil)
        c.openElevator()
        #expect(c.playerCallPending)                       // (queued, as before)
        #expect(!c.isElevatorRideInProgress)
    }

    @Test func thePlayerGetsInWhileAResidentBoards() {
        let (c, _, _) = controller()
        var completed = 0
        _ = c.runCharacterElevatorDeparture(who: "feddy", purpose: .departure(to: 5), resident: true,
                                            boarding: { _ in }, completion: { completed += 1 })
        c.openElevator()
        #expect(c.isElevatorRideInProgress)                         // the player's ride has begun
        #expect(!c.characterUsingElevator)                 // the resident's cycle let the doors go
        #expect(!c.playerCallPending)
        #expect(!c.characterCycleJoinable)
        #expect(completed == 0)                            // (the resident's cycle ends once it is in)
    }

    // MARK: Oct 19 (one car): the player's tap asks the car

    @Test func aTapWithTheCarElsewhereCallsItAndOpensNothing() {
        let (c, _, right) = controller()
        var asked: [(Int, String)] = []
        c.carGate = { floor, who in asked.append((floor, who)); return false }     // (the car is elsewhere)
        let closedX = right.position.x
        c.openElevator()
        #expect(asked.count == 1 && asked[0].0 == 2 && asked[0].1 == "player")
        #expect(!c.isElevatorRideInProgress)                              // (no boarding: the car isn't here)
        #expect(right.position.x == closedX && right.actionKeys.isEmpty)  // (no doors open onto an empty shaft)
    }

    @Test func aTapWithTheCarHereBoardsAsBefore() {
        let (c, _, _) = controller()
        c.carGate = { _, _ in true }                                       // (the car is standing here)
        c.openElevator()
        #expect(c.isElevatorRideInProgress)
    }

    @Test func aCharactersCycleWaitsForTheCar() {
        let (c, _, _) = controller()
        c.carGate = { _, who in who.hasPrefix("script:") ? false : true }
        let ok = c.runCharacterElevatorDeparture(who: "butterfly", boarding: { done in done() }, completion: {})
        #expect(!ok)
        #expect(c.carOnItsWay)
        #expect(c.characterElevatorRefusal == "the car is on its way")
        #expect(!c.characterUsingElevator)
    }
}
