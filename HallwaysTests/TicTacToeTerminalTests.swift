import Testing
import SceneKit
@testable import Hallways

/// Mission-completion/elevator-lock integration for Floor 7's
/// aptitude-test terminal -- same shape as PhotoBoothTests.swift.
/// See TicTacToeGameTests.swift for the pure board/AI logic.
@MainActor
struct TicTacToeTerminalTests {
    @Test func floor7HasExactlyOneAptitudeTestTerminal() {
        let store = MazeStore()
        store.switchTo(id: 7)
        #expect(store.ticTacToeTerminals.count == 1)
    }

    @Test func elevatorStaysLockedUntilThePlayerWins() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            ticTacToeTerminals: [cell: .north])
        #expect(!controller.isMissionComplete)
        controller.activateTicTacToeTerminal(at: cell)
        #expect(controller.activeTicTacToeTerminal == cell)
        controller.completeTicTacToeTerminal(at: cell)
        #expect(controller.ticTacToeWon)
        #expect(controller.isMissionComplete)
    }

    // "the mission must NEVER permanently block the player" -- Eddie,
    // Sept 13. Stepping away without finishing must never flip
    // isMissionComplete, and standing right there facing it still
    // offers an immediate retry.
    @Test func steppingAwayNeverCompletesTheMissionAndAllowsRetry() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            ticTacToeTerminals: [cell: .north])
        controller.activateTicTacToeTerminal(at: cell)
        controller.cancelTicTacToeTerminal()
        #expect(controller.activeTicTacToeTerminal == nil)
        #expect(!controller.isMissionComplete)
        #expect(controller.ticTacToeTerminalAtCurrentCell == cell)
    }

    @Test func swipeCancelsUnfinishedTerminalAndAllowsTurning() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            ticTacToeTerminals: [cell: .north])
        controller.activateTicTacToeTerminal(at: cell)
        controller.beginDragRotate()
        #expect(controller.activeTicTacToeTerminal == nil)
        controller.endDragRotate(fraction: 1)
        #expect(controller.isAnimating)
    }

    @Test func facingTheWrongWayNeverActivatesTheTerminal() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            ticTacToeTerminals: [cell: .north])
        #expect(controller.ticTacToeTerminalAtCurrentCell == nil)
        controller.activateTicTacToeTerminal(at: cell)
        #expect(controller.activeTicTacToeTerminal == nil)
    }

    @Test func resetClearsAWinBackToLocked() {
        let cell = GridCoordinate(row: 0, col: 0)
        let node = HallwayScene.makeTicTacToeTerminalNode(at: cell, direction: .north, cellSize: 3.2)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            ticTacToeTerminals: [cell: .north], ticTacToeTerminalNodes: [cell: node])
        controller.activateTicTacToeTerminal(at: cell)
        controller.completeTicTacToeTerminal(at: cell)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
        #expect(!controller.ticTacToeWon)
    }

    @Test func aFloorWithNoTerminalIsUnaffected() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell)
        #expect(controller.isMissionComplete)
        #expect(controller.ticTacToeTerminalAtCurrentCell == nil)
    }
}
