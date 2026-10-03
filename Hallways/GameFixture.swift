import SceneKit

/// Oct 1 (Decorator Games): the ten existing wall-mounted game fixtures,
/// as ONE identity so the Decorator can place/select/delete any of them.
/// Deliberately not a new game architecture: each case just names the
/// game's EXISTING per-floor dictionary (MazeStore / DefaultMazes.json key
/// `<rawValue>`), its EXISTING scene factory, and its EXISTING
/// TapNavigationController bookkeeping. The building data says which game
/// is where; the app still knows how each game works.
enum GameFixtureKind: String, CaseIterable, Identifiable {
    case ticTacToeTerminals
    case shellGameStations
    case rockPaperScissorsTerminals
    case higherLowerTerminals
    case fiveCardDrawTerminals
    case hangmanTerminals
    case simonTerminals
    case connectFourTerminals
    case checkersTerminals
    case woidleTerminals

    var id: String { rawValue }

    /// Human-readable Decorator name.
    var title: String {
        switch self {
        case .ticTacToeTerminals: return "Tic-Tac-Toe"
        case .shellGameStations: return "Shell Game"
        case .rockPaperScissorsTerminals: return "Rock Paper Scissors"
        case .higherLowerTerminals: return "Hi/Lo"
        case .fiveCardDrawTerminals: return "Five-Card Draw"
        case .hangmanTerminals: return "Hangman"
        case .simonTerminals: return "Simon"
        case .connectFourTerminals: return "Connect Four"
        case .checkersTerminals: return "Checkers"
        case .woidleTerminals: return "Wordle"
        }
    }

    /// The existing generic-removal identity (MazeStore.deleteContent).
    var editorContentKind: EditorContentKind {
        switch self {
        case .ticTacToeTerminals: return .ticTacToeTerminals
        case .shellGameStations: return .shellGameStations
        case .rockPaperScissorsTerminals: return .rockPaperScissorsTerminals
        case .higherLowerTerminals: return .higherLowerTerminals
        case .fiveCardDrawTerminals: return .fiveCardDrawTerminals
        case .hangmanTerminals: return .hangmanTerminals
        case .simonTerminals: return .simonTerminals
        case .connectFourTerminals: return .connectFourTerminals
        case .checkersTerminals: return .checkersTerminals
        case .woidleTerminals: return .woidleTerminals
        }
    }

    /// The SAME node the floor build loop makes for this game.
    func makeNode(at coord: GridCoordinate, direction: Direction, cellSize: CGFloat) -> SCNNode {
        switch self {
        case .ticTacToeTerminals: return HallwayScene.makeTicTacToeTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .shellGameStations: return HallwayScene.makeShellGameStationNode(at: coord, direction: direction, cellSize: cellSize)
        case .rockPaperScissorsTerminals: return HallwayScene.makeRockPaperScissorsTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .higherLowerTerminals: return HallwayScene.makeHigherLowerTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .fiveCardDrawTerminals: return HallwayScene.makeFiveCardDrawTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .hangmanTerminals: return HallwayScene.makeHangmanTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .simonTerminals: return HallwayScene.makeSimonTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .connectFourTerminals: return HallwayScene.makeConnectFourTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .checkersTerminals: return HallwayScene.makeCheckersTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .woidleTerminals: return HallwayScene.makeWoidleTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        }
    }
}
