import Testing
import SceneKit
@testable import Hallways

/// Mission-completion/elevator-lock integration for Floor 10's
/// Higher/Lower terminal -- same shape as
/// RockPaperScissorsTerminalTests.swift/ShellGameTerminalTests.swift/
/// TicTacToeTerminalTests.swift. See HigherLowerGameTests.swift for
/// the pure evaluate()/streak logic.
@MainActor
struct HigherLowerTerminalTests {
    @Test func floor10HasExactlyOneHigherLowerTerminal() {
        let store = MazeStore()
        store.switchTo(id: 10)
        #expect(store.higherLowerTerminals.count == 1)
    }

    @Test func elevatorStaysLockedUntilThePlayerWins() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            higherLowerTerminals: [cell: .north])
        #expect(!controller.isMissionComplete)
        controller.activateHigherLowerTerminal(at: cell)
        #expect(controller.activeHigherLowerTerminal == cell)
        controller.completeHigherLowerTerminal(at: cell)
        #expect(controller.higherLowerWon)
        #expect(controller.isMissionComplete)
    }

    // "No lives. No penalty. No permanent failure. No dead end." --
    // Eddie, Sept 13 (carried over from the Rock Paper Scissors
    // terminal). A wrong guess or a push must never flip
    // isMissionComplete, and completeHigherLowerTerminal is only ever
    // called by the view model once the streak actually reaches 3, so
    // this documents that not having reached the streak yet never
    // completes the mission and always allows an immediate retry.
    @Test func notHavingReachedTheStreakYetNeverCompletesTheMissionAndAllowsRetry() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            higherLowerTerminals: [cell: .north])
        controller.activateHigherLowerTerminal(at: cell)
        controller.cancelHigherLowerTerminal()
        #expect(controller.activeHigherLowerTerminal == nil)
        #expect(!controller.isMissionComplete)
        #expect(controller.higherLowerTerminalAtCurrentCell == cell)
    }

    @Test func swipeCancelsUnfinishedTerminalAndAllowsTurning() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            higherLowerTerminals: [cell: .north])
        controller.activateHigherLowerTerminal(at: cell)
        controller.beginDragRotate()
        #expect(controller.activeHigherLowerTerminal == nil)
        controller.endDragRotate(fraction: 1)
        #expect(controller.isAnimating)
    }

    @Test func facingTheWrongWayNeverActivatesTheTerminal() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            higherLowerTerminals: [cell: .north])
        #expect(controller.higherLowerTerminalAtCurrentCell == nil)
        controller.activateHigherLowerTerminal(at: cell)
        #expect(controller.activeHigherLowerTerminal == nil)
    }

    @Test func resetClearsAWinBackToLocked() {
        let cell = GridCoordinate(row: 0, col: 0)
        let node = HallwayScene.makeHigherLowerTerminalNode(at: cell, direction: .north, cellSize: 3.2)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            higherLowerTerminals: [cell: .north], higherLowerTerminalNodes: [cell: node])
        controller.activateHigherLowerTerminal(at: cell)
        controller.completeHigherLowerTerminal(at: cell)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
        #expect(!controller.higherLowerWon)
    }

    @Test func aFloorWithNoTerminalIsUnaffected() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell)
        #expect(controller.isMissionComplete)
        #expect(controller.higherLowerTerminalAtCurrentCell == nil)
    }
}
