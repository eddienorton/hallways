import Foundation

/// Floor 15's embedded mini-game -- CHECKERS (Eddie, Sept 14), the new
/// top floor after Connect Four (Floor 14).
///
/// Product intent (Eddie): "The player should walk up to the terminal,
/// recognize CHECKERS immediately, and begin playing with little or
/// no instruction... Do NOT reinvent Checkers merely to make it
/// unique." Standard American/English checkers: 8x8 board, 12 pieces
/// per side on the dark squares, ordinary pieces move/capture
/// diagonally forward only, kings move/capture diagonally in any
/// direction, mandatory captures, multi-jump, win by elimination or
/// by leaving the opponent with no legal move.
///
/// Pure game STATE only, no SwiftUI/timer/RNG of its own -- same
/// shape as ConnectFourGame: the SwiftUI overlay
/// (CheckersOverlay.swift) owns the computer's move timing/animation
/// and calls into this file with plain, fully deterministic state
/// transitions that are all testable without any real waiting.
nonisolated enum CheckersSide: String, Codable, Sendable {
    case player, computer

    var opposite: CheckersSide { self == .player ? .computer : .player }
}

nonisolated struct CheckersCoordinate: Equatable, Hashable, Sendable {
    let col: Int
    let row: Int // 0 = the player's home edge, 7 = the computer's home edge -- matches CheckersBoard's forward-direction convention below.
}

nonisolated struct CheckersPiece: Equatable, Sendable {
    let side: CheckersSide
    var isKing: Bool = false
}

/// One legal move -- a plain (non-capture) diagonal step when `captured`
/// is nil, or a diagonal jump removing the piece at `captured` when it
/// isn't. CheckersGame only ever accepts moves drawn from its own
/// legalMovesForCurrentTurn, so equality here is exactly the check
/// that lets a caller "pick one of the offered moves" rather than
/// having to reconstruct and re-validate one by hand.
nonisolated struct CheckersMove: Equatable, Sendable {
    let from: CheckersCoordinate
    let to: CheckersCoordinate
    let captured: CheckersCoordinate?

    var isCapture: Bool { captured != nil }
}

/// A plain 8x8 board storing only the occupied dark squares. Eddie:
/// "8x8 checkerboard, 12 pieces per side, pieces occupy dark squares."
/// Player pieces start on the 3 rows nearest row 0 and advance toward
/// row 7; computer pieces start on the 3 rows nearest row 7 and
/// advance toward row 0 -- reaching the FAR row for that side promotes
/// to king.
nonisolated struct CheckersBoard: Equatable, Sendable {
    static let size = 8

    private(set) var squares: [CheckersCoordinate: CheckersPiece]

    init() {
        squares = [:]
        for row in 0..<3 {
            for col in 0..<Self.size {
                let coord = CheckersCoordinate(col: col, row: row)
                guard Self.isPlayable(coord) else { continue }
                squares[coord] = CheckersPiece(side: .player)
            }
        }
        for row in (Self.size - 3)..<Self.size {
            for col in 0..<Self.size {
                let coord = CheckersCoordinate(col: col, row: row)
                guard Self.isPlayable(coord) else { continue }
                squares[coord] = CheckersPiece(side: .computer)
            }
        }
    }

    /// The dark/playable squares -- the only squares any piece ever
    /// occupies or moves to. Odd col+row, an arbitrary but
    /// self-consistent choice (this file never depends on which
    /// physical board corner is "dark").
    static func isPlayable(_ coord: CheckersCoordinate) -> Bool {
        (coord.col + coord.row) % 2 == 1
    }

    static func isOnBoard(_ coord: CheckersCoordinate) -> Bool {
        coord.col >= 0 && coord.col < size && coord.row >= 0 && coord.row < size
    }

    /// Eddie: "ordinary pieces move diagonally forward one square...
    /// kings can move/capture diagonally forward or backward." Player
    /// forward is +row, computer forward is -row.
    static func forwardRowDelta(for side: CheckersSide) -> Int { side == .player ? 1 : -1 }

    private static let allDiagonals: [(dc: Int, dr: Int)] = [(-1, 1), (1, 1), (-1, -1), (1, -1)]

    private static func legalDiagonals(for piece: CheckersPiece) -> [(dc: Int, dr: Int)] {
        if piece.isKing { return allDiagonals }
        let dr = forwardRowDelta(for: piece.side)
        return allDiagonals.filter { $0.dr == dr }
    }

    func piece(at coord: CheckersCoordinate) -> CheckersPiece? { squares[coord] }

    func squaresOccupied(by side: CheckersSide) -> [CheckersCoordinate] {
        squares.compactMap { $0.value.side == side ? $0.key : nil }
    }

    /// Every simple (non-capture) one-square diagonal move available
    /// to the piece at `from`, if any.
    func simpleMoves(from: CheckersCoordinate) -> [CheckersMove] {
        guard let piece = piece(at: from) else { return [] }
        var moves: [CheckersMove] = []
        for direction in Self.legalDiagonals(for: piece) {
            let to = CheckersCoordinate(col: from.col + direction.dc, row: from.row + direction.dr)
            guard Self.isOnBoard(to), squares[to] == nil else { continue }
            moves.append(CheckersMove(from: from, to: to, captured: nil))
        }
        return moves
    }

    /// Every single-jump capture available to the piece at `from` --
    /// one square diagonally over an adjacent opposing piece, landing
    /// on the empty square immediately beyond. Eddie: "Captures are
    /// diagonal jumps over an opposing piece into an empty square.
    /// Captured piece is removed."
    func captureMoves(from: CheckersCoordinate) -> [CheckersMove] {
        guard let piece = piece(at: from) else { return [] }
        var moves: [CheckersMove] = []
        for direction in Self.legalDiagonals(for: piece) {
            let over = CheckersCoordinate(col: from.col + direction.dc, row: from.row + direction.dr)
            let to = CheckersCoordinate(col: from.col + direction.dc * 2, row: from.row + direction.dr * 2)
            guard Self.isOnBoard(to), squares[to] == nil,
                  let overPiece = squares[over], overPiece.side != piece.side else { continue }
            moves.append(CheckersMove(from: from, to: to, captured: over))
        }
        return moves
    }

    /// All legal moves for `side`, honoring mandatory capture -- Eddie:
    /// "Use standard mandatory captures... If a capture is available,
    /// the UI should naturally guide the player toward the legal
    /// capturing piece." If ANY piece of this side has a capture
    /// available, only capture moves are legal; otherwise every simple
    /// move is legal.
    func legalMoves(for side: CheckersSide) -> [CheckersMove] {
        let ownCoords = squaresOccupied(by: side)
        let captures = ownCoords.flatMap { captureMoves(from: $0) }
        if !captures.isEmpty { return captures }
        return ownCoords.flatMap { simpleMoves(from: $0) }
    }

    /// Applies `move` -- removes a captured piece if any, promotes to
    /// king on reaching the far row. Trusts the caller to have already
    /// validated legality (CheckersGame is the layer that enforces
    /// turn order/legality; the board itself just applies).
    mutating func apply(_ move: CheckersMove) {
        guard var piece = squares.removeValue(forKey: move.from) else { return }
        if let captured = move.captured { squares.removeValue(forKey: captured) }
        let farRow = piece.side == .player ? Self.size - 1 : 0
        if move.to.row == farRow { piece.isKing = true }
        squares[move.to] = piece
    }
}

/// The whole-game state machine on top of CheckersBoard -- turn order,
/// mandatory capture, multi-jump continuation, and win detection all
/// live here so a HangmanGame/ConnectFourGame-style overlay can stay
/// thin.
nonisolated struct CheckersGame: Equatable {
    enum Phase: Equatable {
        case playerTurn
        case computerTurn
        case playerWon
        case computerWon
    }

    private(set) var board = CheckersBoard()
    private(set) var phase: Phase = .playerTurn
    /// Non-nil only mid multi-jump: the one piece that must continue
    /// capturing before the turn can end. Eddie: "Support multiple
    /// jumps in the same turn when available."
    private(set) var mustContinueFrom: CheckersCoordinate?

    private var sideToMove: CheckersSide? {
        switch phase {
        case .playerTurn: return .player
        case .computerTurn: return .computer
        case .playerWon, .computerWon: return nil
        }
    }

    /// The legal moves for whichever side's turn it is right now --
    /// narrowed to just the continuing piece's further captures during
    /// a multi-jump. This is the single source of truth both the
    /// overlay (for highlighting selectable pieces/destinations) and
    /// CheckersAI read from.
    var legalMovesForCurrentTurn: [CheckersMove] {
        guard let side = sideToMove else { return [] }
        if let from = mustContinueFrom { return board.captureMoves(from: from) }
        return board.legalMoves(for: side)
    }

    @discardableResult
    private mutating func makeMove(_ move: CheckersMove, side: CheckersSide) -> Bool {
        guard sideToMove == side, legalMovesForCurrentTurn.contains(move) else { return false }
        board.apply(move)
        if move.isCapture, !board.captureMoves(from: move.to).isEmpty {
            mustContinueFrom = move.to
            return true
        }
        mustContinueFrom = nil
        resolveAfterMove(movedSide: side)
        return true
    }

    /// A no-op (returns false) unless it's actually the player's turn
    /// and `move` is currently legal -- a stray/duplicate tap can never
    /// double-move or play an illegal move.
    @discardableResult
    mutating func playerMove(_ move: CheckersMove) -> Bool { makeMove(move, side: .player) }

    @discardableResult
    mutating func computerMove(_ move: CheckersMove) -> Bool { makeMove(move, side: .computer) }

    /// Eddie: "Player wins by eliminating all computer pieces or
    /// leaving the computer with no legal move. Computer wins under
    /// the equivalent condition." Both conditions collapse to the same
    /// check: the side about to move next has zero legal moves (a side
    /// with zero pieces trivially has zero legal moves too).
    private mutating func resolveAfterMove(movedSide: CheckersSide) {
        let next = movedSide.opposite
        phase = next == .player ? .playerTurn : .computerTurn
        if board.legalMoves(for: next).isEmpty {
            phase = movedSide == .player ? .playerWon : .computerWon
        }
    }

    /// Eddie: "retry starts fresh... no lives, money loss, punishment,
    /// or dead end." A brand new board and a fresh player turn.
    mutating func reset() {
        board = CheckersBoard()
        phase = .playerTurn
        mustContinueFrom = nil
    }
}

/// Eddie: "REAL GAME. FAILURE IS CHEAP... competent enough to feel
/// like an opponent, but this is not a Checkers engine demonstration.
/// Do NOT build deep/minimax tournament AI." A one-ply heuristic
/// scorer plus randomness -- no search tree, no look-ahead beyond the
/// position immediately after the candidate move.
nonisolated enum CheckersAI {
    /// Picks the computer's next move from CheckersGame's own
    /// legalMovesForCurrentTurn (already narrowed to captures-only
    /// when a capture is mandatory, and to the single continuing piece
    /// mid multi-jump) -- this never has to separately re-derive
    /// either rule.
    static func chooseMove<G: RandomNumberGenerator>(game: CheckersGame, using rng: inout G) -> CheckersMove? {
        let moves = game.legalMovesForCurrentTurn
        guard !moves.isEmpty else { return nil }
        if moves.count == 1 { return moves[0] }

        // Eddie: "allow imperfect decisions" -- a per-move random jitter
        // on top of the heuristic score keeps the computer from always
        // playing the single "best" option, without ever considering
        // an illegal one.
        let scored = moves.map { move in
            (move: move, score: score(move, in: game.board) + Double.random(in: 0..<0.9, using: &rng))
        }
        return scored.max(by: { $0.score < $1.score })?.move
    }

    /// Simple, explainable heuristics -- Eddie: "take legal captures,
    /// generally avoid obviously giving pieces away, value
    /// advancement/kings, modest preference for useful positioning."
    private static func score(_ move: CheckersMove, in board: CheckersBoard) -> Double {
        var trial = board
        trial.apply(move)
        var value = 0.0

        if let captured = move.captured, let capturedPiece = board.piece(at: captured) {
            value += capturedPiece.isKing ? 5 : 3
        }

        // Don't obviously hang the piece that just moved -- checked
        // one ply deep only (is there an immediate player recapture on
        // the landing square right now), never a deeper search.
        if let landed = trial.piece(at: move.to), wouldBeRecaptured(move.to, side: .computer, board: trial) {
            value -= landed.isKing ? 4 : 2.5
        }

        if let piece = trial.piece(at: move.to) {
            if piece.isKing {
                value += 2
            } else {
                // Computer advances toward row 0 -- fewer rows left is better.
                value += Double(CheckersBoard.size - 1 - move.to.row) * 0.15
            }
            // "Modest preference for useful positioning" -- central columns
            // over the edges, where a piece has fewer directions to be
            // trapped from.
            value += Double(3 - abs(move.to.col - 3)) * 0.05
        }

        return value
    }

    /// True if the opposing side has an immediate capture landing on
    /// `coord` -- i.e. a piece dropped there would be hanging.
    private static func wouldBeRecaptured(_ coord: CheckersCoordinate, side: CheckersSide, board: CheckersBoard) -> Bool {
        let opponent = side.opposite
        return board.squaresOccupied(by: opponent).contains { origin in
            board.captureMoves(from: origin).contains { $0.captured == coord }
        }
    }
}
