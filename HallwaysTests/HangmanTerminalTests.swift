import Testing
import SceneKit
@testable import Hallways

/// Mission-completion/elevator-lock integration for Floor 12's Hangman
/// terminal -- same shape as SimonTerminalTests.swift/
/// FiveCardDrawTerminalTests.swift/HigherLowerTerminalTests.swift/
/// RockPaperScissorsTerminalTests.swift/ShellGameTerminalTests.swift/
/// TicTacToeTerminalTests.swift. See HangmanGameTests.swift for the
/// pure guess/reveal/word-bank logic.
@MainActor
struct HangmanTerminalTests {
    @Test func floor12HasExactlyOneHangmanTerminal() {
        let store = MazeStore()
        store.switchTo(id: 12)
        #expect(store.hangmanTerminals.count == 1)
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
            hangmanTerminals: [cell: .north])
        #expect(!controller.isMissionComplete)
        controller.activateHangmanTerminal(at: cell)
        #expect(controller.activeHangmanTerminal == cell)
        controller.completeHangmanTerminal(at: cell)
        #expect(controller.hangmanWon)
        #expect(controller.isMissionComplete)
    }

    // "No lives. No punishment... No global state damage." -- carried
    // over from every earlier terminal. Failing a word (or simply not
    // having won yet) must never flip isMissionComplete on its own,
    // and completeHangmanTerminal is only ever called by the view
    // model once the player has actually revealed the whole word and
    // tapped through the result, so this documents that not having
    // won yet never completes the mission and always allows an
    // immediate retry.
    @Test func notHavingWonYetNeverCompletesTheMissionAndAllowsRetry() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            hangmanTerminals: [cell: .north])
        controller.activateHangmanTerminal(at: cell)
        controller.cancelHangmanTerminal()
        #expect(controller.activeHangmanTerminal == nil)
        #expect(!controller.isMissionComplete)
        #expect(controller.hangmanTerminalAtCurrentCell == cell)
    }

    @Test func swipeCancelsUnfinishedTerminalAndAllowsTurning() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            hangmanTerminals: [cell: .north])
        controller.activateHangmanTerminal(at: cell)
        controller.beginDragRotate()
        #expect(controller.activeHangmanTerminal == nil)
        controller.endDragRotate(fraction: 1)
        #expect(controller.isAnimating)
    }

    @Test func facingTheWrongWayNeverActivatesTheTerminal() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            hangmanTerminals: [cell: .north])
        #expect(controller.hangmanTerminalAtCurrentCell == nil)
        controller.activateHangmanTerminal(at: cell)
        #expect(controller.activeHangmanTerminal == nil)
    }

    @Test func resetClearsAWinBackToLocked() {
        let cell = GridCoordinate(row: 0, col: 0)
        let node = HallwayScene.makeHangmanTerminalNode(at: cell, direction: .north, cellSize: 3.2)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            hangmanTerminals: [cell: .north], hangmanTerminalNodes: [cell: node])
        controller.activateHangmanTerminal(at: cell)
        controller.completeHangmanTerminal(at: cell)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
        #expect(!controller.hangmanWon)
    }

    @Test func missionCompletionIsOneWay() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            hangmanTerminals: [cell: .north])
        controller.activateHangmanTerminal(at: cell)
        controller.completeHangmanTerminal(at: cell)
        #expect(controller.hangmanWon)
        // A second activation attempt after already having won must
        // never reopen the terminal or touch the win flag again.
        controller.activateHangmanTerminal(at: cell)
        #expect(controller.activeHangmanTerminal == nil)
        #expect(controller.hangmanWon)
    }

    @Test func aFloorWithNoTerminalIsUnaffected() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell)
        #expect(controller.isMissionComplete)
        #expect(controller.hangmanTerminalAtCurrentCell == nil)
    }
}
