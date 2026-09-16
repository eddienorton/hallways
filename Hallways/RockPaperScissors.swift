import Foundation

/// Floor 9's embedded mini-game -- ROCK PAPER SCISSORS (Eddie, Sept
/// 13), the third of these after Tic-Tac-Toe (Floor 7) and the Shell
/// Game (Floor 8). Pure game logic only, no SceneKit/SwiftUI -- same
/// shape as TicTacToeGame.swift/ShellGame.swift, its own file, not a
/// shared mini-game framework.
nonisolated enum RPSMove: String, Codable, Sendable, CaseIterable {
    case rock, paper, scissors

    var displayName: String { rawValue.uppercased() }
}

nonisolated enum RPSOutcome: Equatable, Sendable {
    case playerWins
    case computerWins
    case tie
}

/// Eddie's own words: "Do NOT choose the computer move after seeing
/// the player's choice in order to manufacture a desired outcome."
/// The two functions below are the entire honesty guarantee:
/// randomMove(using:) takes no knowledge of the player's choice at
/// all -- there is nothing in its signature it COULD cheat with --
/// and outcome(player:computer:) is a pure function of two already-
/// decided moves, evaluated the same way regardless of which one
/// came from the player. Nothing here special-cases a result after
/// the fact (see RockPaperScissorsOverlay.swift: the computer's move
/// is chosen once, at the start of the round, before the player has
/// touched anything).
nonisolated enum RPSGame {
    /// rock beats scissors, scissors beats paper, paper beats rock;
    /// same move is always a tie.
    static func outcome(player: RPSMove, computer: RPSMove) -> RPSOutcome {
        if player == computer { return .tie }
        switch (player, computer) {
        case (.rock, .scissors), (.scissors, .paper), (.paper, .rock):
            return .playerWins
        default:
            return .computerWins
        }
    }

    static func randomMove<G: RandomNumberGenerator>(using rng: inout G) -> RPSMove {
        RPSMove.allCases.randomElement(using: &rng)!
    }
}
