import Testing
import SceneKit
@testable import Hallways

/// Mission-completion/elevator-lock integration for Floor 15's
/// Checkers terminal -- same shape as ConnectFourTerminalTests.swift/
/// HangmanTerminalTests.swift/SimonTerminalTests.swift/
/// FiveCardDrawTerminalTests.swift/HigherLowerTerminalTests.swift/
/// RockPaperScissorsTerminalTests.swift/ShellGameTerminalTests.swift/
/// TicTacToeTerminalTests.swift. See CheckersGameTests.swift for the
/// pure board/turn/AI logic.
@MainActor
struct CheckersTerminalTests {
    @Test func floor15HasExactlyOneCheckersTerminal() {
        let store = MazeStore()
        store.switchTo(id: 15)
        #expect(store.checkersTerminals.count == 1)
    }

    // Eddie: "Floor 15 becomes the new top floor." Do not renumber
    // floors, and Floor 15 itself has no next floor yet.
    @Test func floor15RemainsTheTopFloorWithNoNextFloor() {
        let store = MazeStore()
        store.switchTo(id: 15)
        #expect(store.nextMazeID == nil)
    }

    // Eddie's required test: "Floor 14 correctly progresses to
    // Floor 15." Do NOT renumber or redesign Floors 1-14 -- only
    // Floor 14's nextMazeID should have changed, from nil to 15.
    @Test func floor14CorrectlyProgressesToFloor15() {
        let store = MazeStore()
        store.switchTo(id: 14)
        #expect(store.nextMazeID == 15)
    }

    @Test func elevatorStaysLockedUntilThePlayerWins() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            checkersTerminals: [cell: .north])
        #expect(!controller.isMissionComplete)
        controller.activateCheckersTerminal(at: cell)
        #expect(controller.activeCheckersTerminal == cell)
        controller.completeCheckersTerminal(at: cell)
        #expect(controller.checkersWon)
        #expect(controller.isMissionComplete)
    }

    // "No lives. No penalties... immediate RETRY with a fresh board."
    // A computer win (or simply not having won yet) must never flip
    // isMissionComplete on its own -- completeCheckersTerminal is only
    // ever called by the view model once the player has actually won
    // and tapped through the result, so this documents that not
    // having won yet never completes the mission and always allows an
    // immediate retry.
    @Test func notHavingWonYetNeverCompletesTheMissionAndAllowsRetry() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            checkersTerminals: [cell: .north])
        controller.activateCheckersTerminal(at: cell)
        controller.cancelCheckersTerminal()
        #expect(controller.activeCheckersTerminal == nil)
        #expect(!controller.isMissionComplete)
        #expect(controller.checkersTerminalAtCurrentCell == cell)
    }

    @Test func swipeCancelsUnfinishedTerminalAndAllowsTurning() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            checkersTerminals: [cell: .north])
        controller.activateCheckersTerminal(at: cell)
        controller.beginDragRotate()
        #expect(controller.activeCheckersTerminal == nil)
        controller.endDragRotate(fraction: 1)
        #expect(controller.isAnimating)
    }

    @Test func facingTheWrongWayNeverActivatesTheTerminal() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            checkersTerminals: [cell: .north])
        #expect(controller.checkersTerminalAtCurrentCell == nil)
        controller.activateCheckersTerminal(at: cell)
        #expect(controller.activeCheckersTerminal == nil)
    }

    @Test func resetClearsAWinBackToLocked() {
        let cell = GridCoordinate(row: 0, col: 0)
        let node = HallwayScene.makeCheckersTerminalNode(at: cell, direction: .north, cellSize: 3.2)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            checkersTerminals: [cell: .north], checkersTerminalNodes: [cell: node])
        controller.activateCheckersTerminal(at: cell)
        controller.completeCheckersTerminal(at: cell)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
        #expect(!controller.checkersWon)
    }

    @Test func missionCompletionIsOneWay() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            checkersTerminals: [cell: .north])
        controller.activateCheckersTerminal(at: cell)
        controller.completeCheckersTerminal(at: cell)
        #expect(controller.checkersWon)
        // A second activation attempt after already having won must
        // never reopen the terminal or touch the win flag again.
        controller.activateCheckersTerminal(at: cell)
        #expect(controller.activeCheckersTerminal == nil)
        #expect(controller.checkersWon)
    }

    @Test func aFloorWithNoTerminalIsUnaffected() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell)
        #expect(controller.isMissionComplete)
        #expect(controller.checkersTerminalAtCurrentCell == nil)
    }

    // Eddie: "If player leaves terminal mid-game, cancel/reset cleanly
    // without penalty." Stepping away and coming back to face the
    // terminal again must be able to activate it a second time.
    @Test func cancellingAndReactivatingWorksRepeatedly() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            checkersTerminals: [cell: .north])
        controller.activateCheckersTerminal(at: cell)
        controller.cancelCheckersTerminal()
        controller.activateCheckersTerminal(at: cell)
        #expect(controller.activeCheckersTerminal == cell)
        #expect(!controller.checkersWon)
    }
}
