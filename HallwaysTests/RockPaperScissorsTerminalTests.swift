import Testing
import SceneKit
@testable import Hallways

/// Mission-completion/elevator-lock integration for Floor 9's Rock
/// Paper Scissors terminal -- same shape as ShellGameTerminalTests.swift/
/// TicTacToeTerminalTests.swift. See RockPaperScissorsTests.swift for
/// the pure outcome-table logic.
@MainActor
struct RockPaperScissorsTerminalTests {
    @Test func floor9HasExactlyOneRockPaperScissorsTerminal() {
        let store = MazeStore()
        store.switchTo(id: 9)
        #expect(store.rockPaperScissorsTerminals.count == 1)
    }

    @Test func elevatorStaysLockedUntilThePlayerWins() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            rockPaperScissorsTerminals: [cell: .north])
        #expect(!controller.isMissionComplete)
        controller.activateRockPaperScissorsTerminal(at: cell)
        #expect(controller.activeRockPaperScissorsTerminal == cell)
        controller.completeRockPaperScissorsTerminal(at: cell)
        #expect(controller.rockPaperScissorsWon)
        #expect(controller.isMissionComplete)
    }

    // "No lives. No penalty. No permanent failure. No dead end." --
    // Eddie, Sept 13. A computer win or a tie must never flip
    // isMissionComplete, and completeRockPaperScissorsTerminal is only
    // ever called by the view model on an actual player win, so this
    // documents that stepping away (or simply not having won yet)
    // never completes the mission and always allows an immediate
    // retry.
    @Test func notHavingWonYetNeverCompletesTheMissionAndAllowsRetry() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            rockPaperScissorsTerminals: [cell: .north])
        controller.activateRockPaperScissorsTerminal(at: cell)
        controller.cancelRockPaperScissorsTerminal()
        #expect(controller.activeRockPaperScissorsTerminal == nil)
        #expect(!controller.isMissionComplete)
        #expect(controller.rockPaperScissorsTerminalAtCurrentCell == cell)
    }

    @Test func swipeCancelsUnfinishedTerminalAndAllowsTurning() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            rockPaperScissorsTerminals: [cell: .north])
        controller.activateRockPaperScissorsTerminal(at: cell)
        controller.beginDragRotate()
        #expect(controller.activeRockPaperScissorsTerminal == nil)
        controller.endDragRotate(fraction: 1)
        #expect(controller.isAnimating)
    }

    @Test func facingTheWrongWayNeverActivatesTheTerminal() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            rockPaperScissorsTerminals: [cell: .north])
        #expect(controller.rockPaperScissorsTerminalAtCurrentCell == nil)
        controller.activateRockPaperScissorsTerminal(at: cell)
        #expect(controller.activeRockPaperScissorsTerminal == nil)
    }

    @Test func resetClearsAWinBackToLocked() {
        let cell = GridCoordinate(row: 0, col: 0)
        let node = HallwayScene.makeRockPaperScissorsTerminalNode(at: cell, direction: .north, cellSize: 3.2)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            rockPaperScissorsTerminals: [cell: .north], rockPaperScissorsTerminalNodes: [cell: node])
        controller.activateRockPaperScissorsTerminal(at: cell)
        controller.completeRockPaperScissorsTerminal(at: cell)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
        #expect(!controller.rockPaperScissorsWon)
    }

    @Test func aFloorWithNoTerminalIsUnaffected() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell)
        #expect(controller.isMissionComplete)
        #expect(controller.rockPaperScissorsTerminalAtCurrentCell == nil)
    }
}
