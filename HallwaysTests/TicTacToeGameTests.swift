import Testing
@testable import Hallways

/// Pure game-logic tests for Floor 7's first embedded mini-game --
/// board mechanics and the "building conspires to let the employee
/// pass" computer (Eddie, Sept 13). No SceneKit/SwiftUI here; see
/// TicTacToeTerminalTests.swift for the mission-completion/elevator-
/// lock integration.
struct TicTacToeGameTests {
    @Test func placingOnAnOccupiedOrOutOfRangeSquareIsRejected() {
        var board = TicTacToeBoard()
        #expect(board.place(.x, at: 0))
        #expect(!board.place(.o, at: 0)) // already occupied
        #expect(!board.place(.o, at: 9)) // out of range
        #expect(!board.place(.o, at: -1))
        #expect(board.cells[0] == .x)
    }

    @Test func winnerDetectsEveryLine() {
        for line in TicTacToeBoard.lines {
            var board = TicTacToeBoard()
            for index in line { board.place(.x, at: index) }
            #expect(board.winner() == .x)
        }
    }

    @Test func noWinnerOnEmptyOrMixedBoard() {
        #expect(TicTacToeBoard().winner() == nil)
        var board = TicTacToeBoard()
        board.place(.x, at: 0); board.place(.o, at: 1); board.place(.x, at: 2)
        #expect(board.winner() == nil)
    }

    @Test func fullBoardWithNoWinnerIsADrawNotAWin() {
        // X O X / X O O / O X X -- full, no line of 3, no winner.
        let marks: [TicTacToeMark] = [.x, .o, .x, .x, .o, .o, .o, .x, .x]
        var board = TicTacToeBoard()
        for (index, mark) in marks.enumerated() { board.place(mark, at: index) }
        #expect(board.isFull)
        #expect(board.winner() == nil)
        #expect(board.isGameOver)
    }

    @Test func winningMovesFindsTheCompletingSquare() {
        var board = TicTacToeBoard()
        board.place(.x, at: 0); board.place(.x, at: 1) // top row needs index 2
        #expect(board.winningMoves(for: .x) == [2])
        #expect(board.winningMoves(for: .o).isEmpty)
    }

    // "avoid winning if another legal non-winning move exists" --
    // Eddie's actual "the building is conspiring to let the employee
    // pass" rule. Computer (O) could complete the top row at index 2,
    // but plenty of other squares are open, so it must never do so --
    // checked across many seeds since the rest of the pick is random.
    @Test func aiNeverTakesAWinningMoveWhenALegalAlternativeExists() {
        var board = TicTacToeBoard()
        board.place(.o, at: 0); board.place(.o, at: 1)
        board.place(.x, at: 3); board.place(.x, at: 4)
        for seed: UInt64 in 1...200 {
            var rng = SeededRNG(seed: seed)
            let move = TicTacToeAI.chooseMove(board: board, computer: .o, player: .x, using: &rng)
            #expect(move != 2, "seed \(seed) took the winning square even though an alternative was open")
        }
    }

    // The one exception: if the ONLY empty square left happens to be
    // a winning one, the computer has no alternative and must take it
    // rather than return nil.
    @Test func aiIsForcedToWinWhenNoOtherSquareRemains() {
        // O at 0,1 (threatening the top row at 2); every other square
        // already filled with no pre-existing winner anywhere.
        let board = TicTacToeBoard(cells: [.o, .o, nil, .x, .x, .o, .o, .x, .x])
        var rng = SeededRNG(seed: 7)
        let move = TicTacToeAI.chooseMove(board: board, computer: .o, player: .x, using: &rng)
        #expect(move == 2)
    }

    @Test func aiAlwaysReturnsALegalMoveOnAPartialBoard() throws {
        var board = TicTacToeBoard()
        board.place(.x, at: 0)
        for seed: UInt64 in 1...50 {
            var rng = SeededRNG(seed: seed)
            let move = try #require(TicTacToeAI.chooseMove(board: board, computer: .o, player: .x, using: &rng))
            #expect(board.cells[move] == nil)
        }
    }

    @Test func aiReturnsNilOnAFullBoard() {
        let board = TicTacToeBoard(cells: [.x, .o, .x, .x, .o, .o, .o, .x, .x])
        var rng = SeededRNG(seed: 1)
        #expect(TicTacToeAI.chooseMove(board: board, computer: .o, player: .x, using: &rng) == nil)
    }

    // "subtly more generous as the board develops" -- Eddie, Sept 13.
    @Test func blockProbabilityDecreasesAsTheBoardFillsUp() {
        #expect(TicTacToeAI.blockProbability(marksPlaced: 0) > TicTacToeAI.blockProbability(marksPlaced: 4))
        #expect(TicTacToeAI.blockProbability(marksPlaced: 4) > TicTacToeAI.blockProbability(marksPlaced: 6))
        #expect(TicTacToeAI.blockProbability(marksPlaced: 6) > TicTacToeAI.blockProbability(marksPlaced: 8))
    }

    @Test func freshBoardHasNoMarksAndNineEmptySquares() {
        let board = TicTacToeBoard()
        #expect(board.emptyIndices.count == 9)
        #expect(board.marksPlaced == 0)
        #expect(!board.isFull)
        #expect(!board.isGameOver)
    }
}
