import Testing
import SceneKit
@testable import Hallways

/// Mission-completion/elevator-lock integration for Floor 16's Woidle
/// terminal -- same shape as CheckersTerminalTests.swift/
/// ConnectFourTerminalTests.swift/HangmanTerminalTests.swift/
/// SimonTerminalTests.swift/FiveCardDrawTerminalTests.swift/
/// HigherLowerTerminalTests.swift/RockPaperScissorsTerminalTests.swift/
/// ShellGameTerminalTests.swift/TicTacToeTerminalTests.swift. See
/// WoidleGameTests.swift for the pure word-deduction logic.
@MainActor
struct WoidleTerminalTests {
    @Test func floor16HasExactlyOneWoidleTerminal() {
        let store = MazeStore()
        store.switchTo(id: 16)
        #expect(store.woidleTerminals.count == 1)
    }

    // Eddie: "Floor 16 becomes the new top floor." Do not renumber
    // floors, and Floor 16 itself has no next floor yet.
    @Test func floor16RemainsTheTopFloorWithNoNextFloor() {
        let store = MazeStore()
        store.switchTo(id: 16)
        #expect(store.nextMazeID == nil)
    }

    // Eddie's required test: "Floor 15 correctly progresses to
    // Floor 16." Do NOT renumber or redesign Floors 1-15 -- only
    // Floor 15's nextMazeID should have changed, from nil to 16.
    @Test func floor15CorrectlyProgressesToFloor16() {
        let store = MazeStore()
        store.switchTo(id: 15)
        #expect(store.nextMazeID == 16)
    }

    @Test func elevatorStaysLockedUntilThePlayerWins() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            woidleTerminals: [cell: .north])
        #expect(!controller.isMissionComplete)
        controller.activateWoidleTerminal(at: cell)
        #expect(controller.activeWoidleTerminal == cell)
        controller.completeWoidleTerminal(at: cell)
        #expect(controller.woidleWon)
        #expect(controller.isMissionComplete)
    }

    // "No lives. No penalties... immediate RETRY with a fresh puzzle."
    // Not having won yet must never flip isMissionComplete on its
    // own -- completeWoidleTerminal is only ever called by the view
    // model once the player has actually won and tapped through the
    // result, so this documents that not having won yet never
    // completes the mission and always allows an immediate retry.
    @Test func notHavingWonYetNeverCompletesTheMissionAndAllowsRetry() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            woidleTerminals: [cell: .north])
        controller.activateWoidleTerminal(at: cell)
        controller.cancelWoidleTerminal()
        #expect(controller.activeWoidleTerminal == nil)
        #expect(!controller.isMissionComplete)
        #expect(controller.woidleTerminalAtCurrentCell == cell)
    }

    @Test func swipeCancelsUnfinishedTerminalAndAllowsTurning() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            woidleTerminals: [cell: .north])
        controller.activateWoidleTerminal(at: cell)
        controller.beginDragRotate()
        #expect(controller.activeWoidleTerminal == nil)
        controller.endDragRotate(fraction: 1)
        #expect(controller.isAnimating)
    }

    @Test func facingTheWrongWayNeverActivatesTheTerminal() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            woidleTerminals: [cell: .north])
        #expect(controller.woidleTerminalAtCurrentCell == nil)
        controller.activateWoidleTerminal(at: cell)
        #expect(controller.activeWoidleTerminal == nil)
    }

    @Test func resetClearsAWinBackToLocked() {
        let cell = GridCoordinate(row: 0, col: 0)
        let node = HallwayScene.makeWoidleTerminalNode(at: cell, direction: .north, cellSize: 3.2)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            woidleTerminals: [cell: .north], woidleTerminalNodes: [cell: node])
        controller.activateWoidleTerminal(at: cell)
        controller.completeWoidleTerminal(at: cell)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
        #expect(!controller.woidleWon)
    }

    @Test func missionCompletionIsOneWay() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            woidleTerminals: [cell: .north])
        controller.activateWoidleTerminal(at: cell)
        controller.completeWoidleTerminal(at: cell)
        #expect(controller.woidleWon)
        // A second activation attempt after already having won must
        // never reopen the terminal or touch the win flag again.
        controller.activateWoidleTerminal(at: cell)
        #expect(controller.activeWoidleTerminal == nil)
        #expect(controller.woidleWon)
    }

    @Test func aFloorWithNoTerminalIsUnaffected() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell)
        #expect(controller.isMissionComplete)
        #expect(controller.woidleTerminalAtCurrentCell == nil)
    }

    // Eddie: "If player leaves terminal mid-game, cancel/reset cleanly
    // without penalty." Stepping away and coming back to face the
    // terminal again must be able to activate it a second time.
    @Test func cancellingAndReactivatingWorksRepeatedly() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            woidleTerminals: [cell: .north])
        controller.activateWoidleTerminal(at: cell)
        controller.cancelWoidleTerminal()
        controller.activateWoidleTerminal(at: cell)
        #expect(controller.activeWoidleTerminal == cell)
        #expect(!controller.woidleWon)
    }
}
