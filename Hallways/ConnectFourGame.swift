import Foundation

/// Floor 14's embedded mini-game -- CONNECT FOUR (Eddie, Sept 14),
/// replacing the removed Skee-Ball in the same Floor 14 slot.
///
/// Product intent (Eddie): "The primary emotional goal is recognition
/// and reminiscence... We are not trying to prove that the player is
/// an expert Connect Four strategist... Do not reinvent Connect Four."
/// This is the classic game, nothing more: standard 7x6 board, gravity
/// drop, four in a row (horizontal/vertical/diagonal) wins.
///
/// Pure game STATE only, no SwiftUI/timer/RNG of its own -- the
/// SwiftUI overlay (ConnectFourOverlay.swift) owns the computer's
/// move timing/animation and calls into this struct with plain, fully
/// deterministic state transitions (playerDrop(column:),
/// computerDrop(column:), reset()) that are all testable without any
/// real waiting. Same shape as SimonGame/HangmanGame -- a small,
/// honest state machine, no hidden framework.
nonisolated enum ConnectFourPiece: String, Codable, Sendable {
    case player, computer
}

nonisolated struct ConnectFourCoordinate: Equatable, Hashable, Sendable {
    let column: Int
    let row: Int // 0 = bottom row, matching gravity -- a piece's row only ever increases as more pieces stack in that column.
}

/// A plain 7x6 board stored as one stack per column (index 0 = bottom
/// of that column) -- gravity is structural, not a rule that has to be
/// separately enforced: dropping a piece can only ever append to a
/// column's stack, which IS "the lowest available position."
nonisolated struct ConnectFourBoard: Equatable, Sendable {
    static let columnCount = 7
    static let rowCount = 6

    private(set) var columns: [[ConnectFourPiece]]

    init() {
        columns = Array(repeating: [], count: Self.columnCount)
    }

    func isColumnFull(_ column: Int) -> Bool {
        guard columns.indices.contains(column) else { return true }
        return columns[column].count >= Self.rowCount
    }

    /// Eddie: "Player selects a COLUMN. Piece automatically occupies
    /// the lowest available position." Every column that isn't
    /// already stacked to the top.
    var legalColumns: [Int] {
        (0..<Self.columnCount).filter { !isColumnFull($0) }
    }

    var isFull: Bool { legalColumns.isEmpty }

    /// Only legal moves are into an in-range, non-full column --
    /// returns nil (no-op) rather than trapping on an illegal
    /// request, since a stray double-tap from the UI should never
    /// crash the game. Returns the row the piece landed in on
    /// success.
    @discardableResult
    mutating func drop(_ piece: ConnectFourPiece, inColumn column: Int) -> Int? {
        guard columns.indices.contains(column), !isColumnFull(column) else { return nil }
        columns[column].append(piece)
        return columns[column].count - 1
    }

    func piece(atColumn column: Int, row: Int) -> ConnectFourPiece? {
        guard columns.indices.contains(column), row >= 0, row < columns[column].count else { return nil }
        return columns[column][row]
    }

    /// The 4 contiguous coordinates of a winning line for `piece`, if
    /// any exists -- checks all four directions (horizontal, vertical,
    /// both diagonals) from every occupied cell. Only one direction
    /// vector is needed per axis (not both signs) because scanning
    /// from every starting cell already covers a line from either end.
    func winningLine(for piece: ConnectFourPiece) -> [ConnectFourCoordinate] {
        let directions = [(dc: 1, dr: 0), (dc: 0, dr: 1), (dc: 1, dr: 1), (dc: 1, dr: -1)]
        for col in 0..<Self.columnCount {
            for row in 0..<Self.rowCount {
                guard self.piece(atColumn: col, row: row) == piece else { continue }
                for direction in directions {
                    var line = [ConnectFourCoordinate(column: col, row: row)]
                    for step in 1..<4 {
                        let c = col + direction.dc * step
                        let r = row + direction.dr * step
                        guard self.piece(atColumn: c, row: r) == piece else { break }
                        line.append(ConnectFourCoordinate(column: c, row: r))
                    }
                    if line.count == 4 { return line }
                }
            }
        }
        return []
    }

    /// Simulates dropping `piece` into `column` (without mutating
    /// self) and reports whether that would immediately complete a
    /// line -- the AI's entire "can I win / must I block" honesty
    /// guarantee: it evaluates a real trial drop on a copy of the
    /// actual board, never a shortcut heuristic that could be wrong.
    func wouldWin(_ piece: ConnectFourPiece, column: Int) -> Bool {
        guard !isColumnFull(column) else { return false }
        var trial = self
        trial.drop(piece, inColumn: column)
        return !trial.winningLine(for: piece).isEmpty
    }
}

/// The whole-game state machine on top of ConnectFourBoard -- turn
/// order, win/draw detection, and the one-way mission gate all live
/// here so HangmanGame- and SimonGame-style overlays can stay thin.
nonisolated struct ConnectFourGame: Equatable {
    enum Phase: Equatable {
        case playerTurn
        case computerTurn
        case playerWon
        case computerWon
        case draw
    }

    private(set) var board = ConnectFourBoard()
    private(set) var phase: Phase = .playerTurn
    /// Non-empty only during .playerWon/.computerWon -- the 4
    /// coordinates the overlay highlights. Eddie: "make the winning
    /// four visually apparent if straightforward to implement."
    private(set) var winningLine: [ConnectFourCoordinate] = []

    /// Eddie: "Player and computer alternate turns." A no-op outside
    /// .playerTurn, or onto a full column, so a stray tap can never
    /// double-move or land a piece twice.
    @discardableResult
    mutating func playerDrop(column: Int) -> Int? {
        guard phase == .playerTurn else { return nil }
        guard let row = board.drop(.player, inColumn: column) else { return nil }
        resolveAfterMove(lastPiece: .player)
        return row
    }

    /// Same shape as playerDrop(column:), only reachable during
    /// .computerTurn -- ConnectFourOverlay calls this with whatever
    /// column ConnectFourAI.chooseMove(_:) picked.
    @discardableResult
    mutating func computerDrop(column: Int) -> Int? {
        guard phase == .computerTurn else { return nil }
        guard let row = board.drop(.computer, inColumn: column) else { return nil }
        resolveAfterMove(lastPiece: .computer)
        return row
    }

    /// Eddie: "First player to make 4 contiguous pieces... wins. A
    /// completely full board with no winner is a draw." Checked in
    /// that order -- a move that both completes a line AND fills the
    /// board is a win, never a draw.
    private mutating func resolveAfterMove(lastPiece: ConnectFourPiece) {
        let line = board.winningLine(for: lastPiece)
        if !line.isEmpty {
            winningLine = line
            phase = lastPiece == .player ? .playerWon : .computerWon
            return
        }
        if board.isFull {
            phase = .draw
            return
        }
        phase = lastPiece == .player ? .computerTurn : .playerTurn
    }

    /// Eddie: "Failure offers an immediate RETRY with a fresh board...
    /// No lives. No penalties." A brand new board and a fresh player
    /// turn -- nothing carries over from the previous game.
    mutating func reset() {
        board = ConnectFourBoard()
        phase = .playerTurn
        winningLine = []
    }
}

/// Eddie: "The computer must play a REAL game... but do NOT build a
/// deep/minimax/expert opponent." A small, testable, deliberately
/// shallow heuristic -- exactly the three-rule shape Eddie specified,
/// nothing more:
///   1. Take an immediate win if one exists.
///   2. Usually (not always) block the player's immediate win.
///   3. Otherwise pick among legal columns with a preference toward
///      the center, plus randomness.
/// Generic over the RNG type (same pattern as TicTacToeAI), so tests
/// can supply SeededRNG and a real device build passes
/// SystemRandomNumberGenerator.
nonisolated enum ConnectFourAI {
    /// Eddie: "usually block" -- not a flawless block, so the player
    /// can occasionally slip a threat through and isn't playing a
    /// perfect opponent, but not so leaky that a win never feels
    /// earned either.
    static let blockChance = 0.85
    /// Eddie: "give some preference to central columns." Ordered by
    /// distance from the true center of a 7-wide board (column 3).
    static let columnsByCentrality: [Int] = [3, 2, 4, 1, 5, 0, 6]

    /// Picks the computer's next move. Returns nil only when the
    /// board already has no legal column (caller should have checked
    /// isFull/phase first).
    static func chooseMove<G: RandomNumberGenerator>(board: ConnectFourBoard, using rng: inout G) -> Int? {
        let legal = board.legalColumns
        guard !legal.isEmpty else { return nil }

        // Rule 1 -- take an immediate win if available. Declining a
        // free win would read as an obviously rigged loss, which is
        // exactly what Eddie's "the game is real" rule forbids just
        // as much as a rigged win would be.
        if let winning = legal.first(where: { board.wouldWin(.computer, column: $0) }) {
            return winning
        }

        // Rule 2 -- usually block the player's immediate win.
        if let threat = legal.first(where: { board.wouldWin(.player, column: $0) }) {
            if Double.random(in: 0..<1, using: &rng) < blockChance {
                return threat
            }
        }

        // Rule 3 -- simple strategy plus randomness: most of the time
        // pick from the more-central half of the legal columns,
        // otherwise pick from every legal column -- keeps the
        // computer's play recognizable (favors the middle, like a
        // reasonable casual opponent would) without ever being fully
        // predictable, and with no minimax/deep search involved.
        let ranked = columnsByCentrality.filter { legal.contains($0) }
        let preferCentral = Double.random(in: 0..<1, using: &rng) < 0.7
        if preferCentral {
            let topCount = max(1, (ranked.count + 1) / 2)
            if let choice = ranked.prefix(topCount).randomElement(using: &rng) { return choice }
        }
        return legal.randomElement(using: &rng)
    }
}
