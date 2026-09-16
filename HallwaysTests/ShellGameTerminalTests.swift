import Testing
import SceneKit
@testable import Hallways

/// Mission-completion/elevator-lock integration for Floor 8's
/// shell-game station -- same shape as TicTacToeTerminalTests.swift.
/// See ShellGameTests.swift for the pure cup/swap honesty logic.
@MainActor
struct ShellGameTerminalTests {
    @Test func floor8HasExactlyOneShellGameStation() {
        let store = MazeStore()
        store.switchTo(id: 8)
        #expect(store.shellGameStations.count == 1)
    }

    @Test func elevatorStaysLockedUntilThePlayerWins() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            shellGameStations: [cell: .north])
        #expect(!controller.isMissionComplete)
        controller.activateShellGameTerminal(at: cell)
        #expect(controller.activeShellGameTerminal == cell)
        controller.completeShellGameTerminal(at: cell)
        #expect(controller.shellGameWon)
        #expect(controller.isMissionComplete)
    }

    // "NO lives, NO punishment, NO permanent failure" -- Eddie, Sept
    // 13. Stepping away without finishing must never flip
    // isMissionComplete, and standing right there facing it still
    // offers an immediate retry.
    @Test func steppingAwayNeverCompletesTheMissionAndAllowsRetry() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            shellGameStations: [cell: .north])
        controller.activateShellGameTerminal(at: cell)
        controller.cancelShellGameTerminal()
        #expect(controller.activeShellGameTerminal == nil)
        #expect(!controller.isMissionComplete)
        #expect(controller.shellGameTerminalAtCurrentCell == cell)
    }

    @Test func swipeCancelsUnfinishedStationAndAllowsTurning() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            shellGameStations: [cell: .north])
        controller.activateShellGameTerminal(at: cell)
        controller.beginDragRotate()
        #expect(controller.activeShellGameTerminal == nil)
        controller.endDragRotate(fraction: 1)
        #expect(controller.isAnimating)
    }

    @Test func facingTheWrongWayNeverActivatesTheStation() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            shellGameStations: [cell: .north])
        #expect(controller.shellGameTerminalAtCurrentCell == nil)
        controller.activateShellGameTerminal(at: cell)
        #expect(controller.activeShellGameTerminal == nil)
    }

    @Test func resetClearsAWinBackToLocked() {
        let cell = GridCoordinate(row: 0, col: 0)
        let node = HallwayScene.makeShellGameStationNode(at: cell, direction: .north, cellSize: 3.2)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            shellGameStations: [cell: .north], shellGameStationNodes: [cell: node])
        controller.activateShellGameTerminal(at: cell)
        controller.completeShellGameTerminal(at: cell)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
        #expect(!controller.shellGameWon)
    }

    @Test func aFloorWithNoStationIsUnaffected() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell)
        #expect(controller.isMissionComplete)
        #expect(controller.shellGameTerminalAtCurrentCell == nil)
    }
}
