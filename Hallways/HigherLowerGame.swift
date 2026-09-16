import Foundation

/// Floor 10's embedded mini-game -- HIGHER / LOWER (Eddie, Sept 13),
/// the fourth of these after Tic-Tac-Toe, the Shell Game, and Rock
/// Paper Scissors. Pure game logic only, no SceneKit/SwiftUI -- same
/// shape as TicTacToeGame.swift/ShellGame.swift/RockPaperScissors.swift,
/// its own file, not a shared mini-game framework.
nonisolated enum HigherLowerGuess: Sendable {
    case higher
    case lower
}

nonisolated enum HigherLowerResult: Equatable, Sendable {
    case correct
    case wrong
    case push // same rank as the current card -- neither a hit nor a miss.
}

/// Eddie: "Do NOT choose the next card after seeing the player's
/// HIGHER/LOWER selection in order to manufacture an outcome." This
/// function takes no part in choosing the next card at all -- by the
/// time it's called, both ranks already exist (the current card, and
/// whatever PlayingCardDeck.draw() honestly produced); it only
/// compares them.
nonisolated enum HigherLowerGame {
    static func evaluate(current: Rank, next: Rank, guess: HigherLowerGuess) -> HigherLowerResult {
        if next.rawValue == current.rawValue { return .push }
        switch guess {
        case .higher: return next.rawValue > current.rawValue ? .correct : .wrong
        case .lower: return next.rawValue < current.rawValue ? .correct : .wrong
        }
    }
}

/// Eddie: "Require 3 CORRECT GUESSES IN A ROW." A push leaves the
/// streak untouched (neither progress nor a setback); a wrong guess
/// resets it to zero; a correct guess advances it, and 3 completes
/// the floor's mission.
nonisolated struct HigherLowerStreak: Equatable, Sendable {
    static let target = 3

    private(set) var count = 0

    var isComplete: Bool { count >= Self.target }

    mutating func apply(_ result: HigherLowerResult) {
        switch result {
        case .correct: count += 1
        case .wrong: count = 0
        case .push: break
        }
    }
}
