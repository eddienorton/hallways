import Foundation

/// Floor 7's first embedded mini-game -- "EMPLOYEE APTITUDE TEST /
/// TIC-TAC-TOE" (Eddie, Sept 13). Pure game logic only: no SceneKit,
/// no SwiftUI. Kept in its own file, deliberately NOT a generalized
/// "mini-game framework" -- Eddie: "just make Tic-Tac-Toe cleanly
/// enough that we learn what the embedded-game experience should feel
/// like," "DO NOT build a generalized framework for hypothetical
/// future games."
nonisolated enum TicTacToeMark: String, Codable, Sendable {
    case x, o
}

/// A plain 3x3 board, indices 0...8 left-to-right/top-to-bottom (same
/// convention as any tic-tac-toe reference layout: 0 1 2 / 3 4 5 / 6 7 8).
nonisolated struct TicTacToeBoard: Equatable, Sendable {
    private(set) var cells: [TicTacToeMark?]

    init(cells: [TicTacToeMark?] = Array(repeating: nil, count: 9)) {
        precondition(cells.count == 9, "TicTacToeBoard is always a 3x3 grid")
        self.cells = cells
    }

    static let lines: [[Int]] = [
        [0, 1, 2], [3, 4, 5], [6, 7, 8], // rows
        [0, 3, 6], [1, 4, 7], [2, 5, 8], // columns
        [0, 4, 8], [2, 4, 6]             // diagonals
    ]

    var isFull: Bool { !cells.contains(nil) }
    var emptyIndices: [Int] { cells.indices.filter { cells[$0] == nil } }
    var marksPlaced: Int { 9 - emptyIndices.count }

    /// nil until a line is fully one mark.
    func winner() -> TicTacToeMark? {
        for line in Self.lines {
            let marks = line.map { cells[$0] }
            if let first = marks[0], marks.allSatisfy({ $0 == first }) { return first }
        }
        return nil
    }

    var isGameOver: Bool { winner() != nil || isFull }

    /// Only legal moves are onto an empty, in-range square -- returns
    /// false (no-op) rather than trapping on an illegal request, since
    /// a stray double-tap from the UI should never crash the game.
    @discardableResult
    mutating func place(_ mark: TicTacToeMark, at index: Int) -> Bool {
        guard cells.indices.contains(index), cells[index] == nil else { return false }
        cells[index] = mark
        return true
    }

    /// Every empty square that would immediately complete a line for `mark`.
    func winningMoves(for mark: TicTacToeMark) -> [Int] {
        emptyIndices.filter { index in
            var trial = self
            trial.cells[index] = mark
            return trial.winner() == mark
        }
    }
}

/// A tiny deterministic xorshift64* generator conforming to
/// RandomNumberGenerator -- exists purely so tests can drive
/// TicTacToeAI.chooseMove reproducibly (a real device build can just
/// pass SystemRandomNumberGenerator()). Not cryptographic, not meant
/// to be -- this is a board game's "which reasonable-looking move do
/// we pick" seed, nothing security-sensitive.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// The "building is conspiring to let the employee pass" computer
/// player (Eddie, Sept 13). Deliberately NOT minimax -- see each
/// rule's own comment for which part of the spec it implements.
nonisolated enum TicTacToeAI {
    /// Eddie: "the computer can become subtly more generous as the
    /// board develops" -- i.e. LESS likely to block the player's
    /// threats the further the game goes, so a slow, patient player
    /// gets more room, not less. Early on it still blocks fairly
    /// often so the very first move or two don't look suspiciously
    /// weak ("should appear plausible enough at first").
    static func blockProbability(marksPlaced: Int) -> Double {
        switch marksPlaced {
        case 0...2: return 0.75
        case 3...4: return 0.55
        case 5...6: return 0.35
        default: return 0.15
        }
    }

    /// Picks the computer's next move. Returns nil only when the
    /// board already has no empty square (caller should have checked
    /// isGameOver first). Generic over the RNG type (rather than
    /// `inout RandomNumberGenerator`) so callers can pass a concrete
    /// generator -- SystemRandomNumberGenerator in the real game,
    /// SeededRNG in tests -- with no existential-conformance ambiguity.
    static func chooseMove<G: RandomNumberGenerator>(board: TicTacToeBoard, computer: TicTacToeMark, player: TicTacToeMark,
                           using rng: inout G) -> Int? {
        let empty = board.emptyIndices
        guard !empty.isEmpty else { return nil }

        // Rule 1 -- "avoid winning if another legal non-winning move
        // exists": this is the actual "let the employee pass" joke,
        // and it's an absolute rule, not a probability. Only when the
        // ONLY empty squares left are winning ones is the computer
        // forced to take one.
        let winningForComputer = Set(board.winningMoves(for: computer))
        var candidates = empty.filter { !winningForComputer.contains($0) }
        if candidates.isEmpty { candidates = empty }

        // Rule 2 -- "do not aggressively prevent the player's
        // eventual win": block the player's immediate threat only
        // some of the time, per blockProbability above, instead of
        // the flawless block a real opponent would always make.
        let playerThreats = board.winningMoves(for: player)
        if let threat = playerThreats.first, candidates.contains(threat) {
            let shouldBlock = Double.random(in: 0..<1, using: &rng) < blockProbability(marksPlaced: board.marksPlaced)
            if shouldBlock { return threat }
            candidates.removeAll { $0 == threat }
            if candidates.isEmpty { return threat } // no alternative left -- block anyway
        }

        // Rule 3 -- "occasionally make reasonable-looking moves":
        // prefer center, then corners, then edges (a normal-looking
        // opening/mid-game shape), each group shuffled so it doesn't
        // play identically every time.
        let center = 4, corners = [0, 2, 6, 8], edges = [1, 3, 5, 7]
        for group in [[center], corners, edges] {
            let available = group.filter { candidates.contains($0) }
            if let choice = available.shuffled(using: &rng).first { return choice }
        }
        return candidates.shuffled(using: &rng).first
    }
}
