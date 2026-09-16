import Testing
import SceneKit
@testable import Hallways

/// Mission-completion/elevator-lock integration for Floor 14's
/// Connect Four terminal -- same shape as HangmanTerminalTests.swift/
/// SimonTerminalTests.swift/FiveCardDrawTerminalTests.swift/
/// HigherLowerTerminalTests.swift/RockPaperScissorsTerminalTests.swift/
/// ShellGameTerminalTests.swift/TicTacToeTerminalTests.swift. See
/// ConnectFourGameTests.swift for the pure board/turn/AI logic.
@MainActor
struct ConnectFourTerminalTests {
    @Test func floor14HasExactlyOneConnectFourTerminal() {
        let store = MazeStore()
        store.switchTo(id: 14)
        #expect(store.connectFourTerminals.count == 1)
    }

    // Eddie: "Floor 14 can remain the current top floor with
    // nextMazeID null." Do not renumber floors.
    @Test func floor14RemainsTheTopFloorWithNoNextFloor() {
        let store = MazeStore()
        store.switchTo(id: 14)
        #expect(store.nextMazeID == nil)
    }

    @Test func elevatorStaysLockedUntilThePlayerWins() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            connectFourTerminals: [cell: .north])
        #expect(!controller.isMissionComplete)
        controller.activateConnectFourTerminal(at: cell)
        #expect(controller.activeConnectFourTerminal == cell)
        controller.completeConnectFourTerminal(at: cell)
        #expect(controller.connectFourWon)
        #expect(controller.isMissionComplete)
    }

    // "No lives. No penalties... immediate RETRY with a fresh board."
    // A computer win or a draw (or simply not having won yet) must
    // never flip isMissionComplete on its own -- completeConnectFour
    // Terminal is only ever called by the view model once the player
    // has actually won and tapped through the result, so this
    // documents that not having won yet never completes the mission
    // and always allows an immediate retry.
    @Test func notHavingWonYetNeverCompletesTheMissionAndAllowsRetry() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            connectFourTerminals: [cell: .north])
        controller.activateConnectFourTerminal(at: cell)
        controller.cancelConnectFourTerminal()
        #expect(controller.activeConnectFourTerminal == nil)
        #expect(!controller.isMissionComplete)
        #expect(controller.connectFourTerminalAtCurrentCell == cell)
    }

    @Test func swipeCancelsUnfinishedTerminalAndAllowsTurning() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            connectFourTerminals: [cell: .north])
        controller.activateConnectFourTerminal(at: cell)
        controller.beginDragRotate()
        #expect(controller.activeConnectFourTerminal == nil)
        controller.endDragRotate(fraction: 1)
        #expect(controller.isAnimating)
    }

    @Test func facingTheWrongWayNeverActivatesTheTerminal() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .south, endCell: cell,
            connectFourTerminals: [cell: .north])
        #expect(controller.connectFourTerminalAtCurrentCell == nil)
        controller.activateConnectFourTerminal(at: cell)
        #expect(controller.activeConnectFourTerminal == nil)
    }

    @Test func resetClearsAWinBackToLocked() {
        let cell = GridCoordinate(row: 0, col: 0)
        let node = HallwayScene.makeConnectFourTerminalNode(at: cell, direction: .north, cellSize: 3.2)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            connectFourTerminals: [cell: .north], connectFourTerminalNodes: [cell: node])
        controller.activateConnectFourTerminal(at: cell)
        controller.completeConnectFourTerminal(at: cell)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
        #expect(!controller.connectFourWon)
    }

    @Test func missionCompletionIsOneWay() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            connectFourTerminals: [cell: .north])
        controller.activateConnectFourTerminal(at: cell)
        controller.completeConnectFourTerminal(at: cell)
        #expect(controller.connectFourWon)
        // A second activation attempt after already having won must
        // never reopen the terminal or touch the win flag again.
        controller.activateConnectFourTerminal(at: cell)
        #expect(controller.activeConnectFourTerminal == nil)
        #expect(controller.connectFourWon)
    }

    @Test func aFloorWithNoTerminalIsUnaffected() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell)
        #expect(controller.isMissionComplete)
        #expect(controller.connectFourTerminalAtCurrentCell == nil)
    }
}
