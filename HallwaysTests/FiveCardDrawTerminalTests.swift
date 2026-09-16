import Testing
import SceneKit
@testable import Hallways

/// Mission-completion/elevator-lock integration for Floor 11's
/// Five-Card Draw terminal -- same shape as
/// HigherLowerTerminalTests.swift/RockPaperScissorsTerminalTests.swift/
/// ShellGameTerminalTests.swift/TicTacToeTerminalTests.swift. See
/// PokerHandEvaluatorTests.swift/FiveCardDrawGameTests.swift for the
/// pure hand-strength and deal/hold/draw logic.
@MainActor
struct FiveCardDrawTerminalTests {
    @Test func floor11HasExactlyOneFiveCardDrawTerminal() {
        let store = MazeStore()
        store.switchTo(id: 11)
        #expect(store.fiveCardDrawTerminals.count == 1)
    }

    @Test func elevatorStaysLockedUntilThePlayerWins() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            fiveCardDrawTerminals: [cell: .north])
        #expect(!controller.isMissionComplete)
        controller.activateFiveCardDrawTerminal(at: cell)
        #expect(controller.activeFiveCardDrawTerminal == cell)
        controller.completeFiveCardDrawTerminal(at: cell)
        #expect(controller.fiveCardDrawWon)
        #expect(controller.isMissionComplete)
    }

    // "No lives. No punishment... No dead end." -- Eddie, Sept 13
    // (carried over from every earlier terminal). A High Card result
    // must never flip isMissionComplete on its own, and
    // completeFiveCardDrawTerminal is only ever called by the view
    // model once a qualifying (pair or better) hand has actually been
    // drawn and the player has tapped through it, so this documents
    // that not having won yet never completes the mission and always
    // allows an immediate retry.
    @Test func notHavingWonYetNeverCompletesTheMissionAndAllowsRetry() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            fiveCardDrawTerminals: [cell: .north])
        controller.activateFiveCardDrawTerminal(at: cell)
        controller.cancelFiveCardDrawTerminal()
        #expect(controller.activeFiveCardDrawTerminal == nil)
        #expect(!controller.isMissionComplete)
        #expect(controller.fiveCardDrawTerminalAtCurrentCell == cell)
    }

    @Test func swipeCancelsUnfinishedTerminalAndAllowsTurning() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            fiveCardDrawTerminals: [cell: .north])
        controller.activateFiveCardDrawTerminal(at: cell)
        controller.beginDragRotate()
        #expect(controller.activeFiveCardDrawTerminal == nil)
        controller.endDragRotate(fraction: 1)
        #expect(controller.isAnimating)
    }

    @Test func facingTheWrongWayNeverActivatesTheTerminal() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            fiveCardDrawTerminals: [cell: .north])
        #expect(controller.fiveCardDrawTerminalAtCurrentCell == nil)
        controller.activateFiveCardDrawTerminal(at: cell)
        #expect(controller.activeFiveCardDrawTerminal == nil)
    }

    @Test func resetClearsAWinBackToLocked() {
        let cell = GridCoordinate(row: 0, col: 0)
        let node = HallwayScene.makeFiveCardDrawTerminalNode(at: cell, direction: .north, cellSize: 3.2)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            fiveCardDrawTerminals: [cell: .north], fiveCardDrawTerminalNodes: [cell: node])
        controller.activateFiveCardDrawTerminal(at: cell)
        controller.completeFiveCardDrawTerminal(at: cell)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
        #expect(!controller.fiveCardDrawWon)
    }

    @Test func aFloorWithNoTerminalIsUnaffected() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell)
        #expect(controller.isMissionComplete)
        #expect(controller.fiveCardDrawTerminalAtCurrentCell == nil)
    }
}
