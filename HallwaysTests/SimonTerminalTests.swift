import Testing
import SceneKit
@testable import Hallways

/// Mission-completion/elevator-lock integration for Floor 13's Simon
/// terminal -- same shape as WhackAMoleTerminalTests.swift/
/// FiveCardDrawTerminalTests.swift/HigherLowerTerminalTests.swift/
/// RockPaperScissorsTerminalTests.swift/ShellGameTerminalTests.swift/
/// TicTacToeTerminalTests.swift. See SimonGameTests.swift for the
/// pure sequence/round/tap logic.
@MainActor
struct SimonTerminalTests {
    @Test func floor13HasExactlyOneSimonTerminal() {
        let store = MazeStore()
        store.switchTo(id: 13)
        #expect(store.simonTerminals.count == 1)
    }

    @Test func floor12NextMazeIDPointsToFloor13() {
        let store = MazeStore()
        store.switchTo(id: 12)
        #expect(store.nextMazeID == 13)
    }

    @Test func elevatorStaysLockedUntilThePlayerWins() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            simonTerminals: [cell: .north])
        #expect(!controller.isMissionComplete)
        controller.activateSimonTerminal(at: cell)
        #expect(controller.activeSimonTerminal == cell)
        controller.completeSimonTerminal(at: cell)
        #expect(controller.simonWon)
        #expect(controller.isMissionComplete)
    }

    // "No lives. No punishment... No global state damage." -- Eddie,
    // Sept 13 (carried over from every earlier terminal). Failing a
    // round (or simply not having won yet) must never flip
    // isMissionComplete on its own, and completeSimonTerminal is only
    // ever called by the view model once the player has actually
    // reproduced the length-5 sequence and tapped through the result,
    // so this documents that not having won yet never completes the
    // mission and always allows an immediate retry.
    @Test func notHavingWonYetNeverCompletesTheMissionAndAllowsRetry() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            simonTerminals: [cell: .north])
        controller.activateSimonTerminal(at: cell)
        controller.cancelSimonTerminal()
        #expect(controller.activeSimonTerminal == nil)
        #expect(!controller.isMissionComplete)
        #expect(controller.simonTerminalAtCurrentCell == cell)
    }

    @Test func swipeCancelsUnfinishedTerminalAndAllowsTurning() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            simonTerminals: [cell: .north])
        controller.activateSimonTerminal(at: cell)
        controller.beginDragRotate()
        #expect(controller.activeSimonTerminal == nil)
        controller.endDragRotate(fraction: 1)
        #expect(controller.isAnimating)
    }

    @Test func facingTheWrongWayNeverActivatesTheTerminal() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            simonTerminals: [cell: .north])
        #expect(controller.simonTerminalAtCurrentCell == nil)
        controller.activateSimonTerminal(at: cell)
        #expect(controller.activeSimonTerminal == nil)
    }

    @Test func resetClearsAWinBackToLocked() {
        let cell = GridCoordinate(row: 0, col: 0)
        let node = HallwayScene.makeSimonTerminalNode(at: cell, direction: .north, cellSize: 3.2)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            simonTerminals: [cell: .north], simonTerminalNodes: [cell: node])
        controller.activateSimonTerminal(at: cell)
        controller.completeSimonTerminal(at: cell)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
        #expect(!controller.simonWon)
    }

    @Test func missionCompletionIsOneWay() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            simonTerminals: [cell: .north])
        controller.activateSimonTerminal(at: cell)
        controller.completeSimonTerminal(at: cell)
        #expect(controller.simonWon)
        // A second activation attempt after already having won must
        // never reopen the terminal or touch the win flag again.
        controller.activateSimonTerminal(at: cell)
        #expect(controller.activeSimonTerminal == nil)
        #expect(controller.simonWon)
    }

    @Test func aFloorWithNoTerminalIsUnaffected() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell)
        #expect(controller.isMissionComplete)
        #expect(controller.simonTerminalAtCurrentCell == nil)
    }
}
