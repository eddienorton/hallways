import Testing
@testable import Hallways

/// Pure state-transition tests for Floor 14's Connect Four -- no
/// timers, no waiting, since ConnectFourGame itself owns none of the
/// computer's move timing/animation (the SwiftUI overlay's view model
/// owns that). See ConnectFourTerminalTests.swift for the mission-
/// completion/elevator-lock integration.
struct ConnectFourGameTests {
    @Test func initialStateIsPlayerTurnWithAnEmptyBoard() {
        let game = ConnectFourGame()
        #expect(game.phase == .playerTurn)
        #expect(game.board.legalColumns.count == ConnectFourBoard.columnCount)
        #expect(game.winningLine.isEmpty)
    }

    // Eddie: "Piece automatically occupies the lowest available
    // position in that column." Gravity is structural in
    // ConnectFourBoard (see its own doc comment), but this documents
    // the observable behavior through the whole-game API: repeated
    // drops into the same column stack upward from row 0.
    @Test func gravityStacksPiecesFromTheBottomOfAColumn() {
        var game = ConnectFourGame()
        let firstRow = game.playerDrop(column: 3)
        #expect(firstRow == 0)
        #expect(game.board.piece(atColumn: 3, row: 0) == .player)
        game.computerDrop(column: 3)
        #expect(game.board.piece(atColumn: 3, row: 1) == .computer)
    }

    // Eddie: "Player and computer alternate turns."
    @Test func turnsAlternateAfterEachSuccessfulDrop() {
        var game = ConnectFourGame()
        #expect(game.phase == .playerTurn)
        game.playerDrop(column: 0)
        #expect(game.phase == .computerTurn)
        game.computerDrop(column: 1)
        #expect(game.phase == .playerTurn)
    }

    @Test func playerDropIsANoOpDuringTheComputersTurn() {
        var game = ConnectFourGame()
        game.playerDrop(column: 0) // now computerTurn
        let result = game.playerDrop(column: 1)
        #expect(result == nil)
        #expect(game.board.piece(atColumn: 1, row: 0) == nil)
    }

    @Test func computerDropIsANoOpDuringThePlayersTurn() {
        var game = ConnectFourGame()
        let result = game.computerDrop(column: 0)
        #expect(result == nil)
        #expect(game.board.piece(atColumn: 0, row: 0) == nil)
    }

    // Eddie's required test: "full-column rejection."
    @Test func aFullColumnRejectsFurtherDrops() {
        var board = ConnectFourBoard()
        for _ in 0..<ConnectFourBoard.rowCount {
            board.drop(.player, inColumn: 2)
        }
        #expect(board.isColumnFull(2))
        let result = board.drop(.computer, inColumn: 2)
        #expect(result == nil)
        #expect(board.columns[2].count == ConnectFourBoard.rowCount)
    }

    @Test func fullColumnRejectionAtTheWholeGameLevelDoesNotChangeTurn() {
        var game = ConnectFourGame()
        // Fill column 0 with alternating drops (6 total -- 3 each --
        // so the column fills without a win and it's back to the
        // player's turn), then confirm a 7th drop attempt is rejected
        // and doesn't flip the turn.
        for _ in 0..<3 {
            game.playerDrop(column: 0)
            game.computerDrop(column: 0)
        }
        #expect(game.board.isColumnFull(0))
        #expect(game.phase == .playerTurn)
        let result = game.playerDrop(column: 0)
        #expect(result == nil)
        #expect(game.phase == .playerTurn)
    }

    // Eddie's required test: "horizontal win detection."
    @Test func horizontalFourInARowWins() {
        var game = ConnectFourGame()
        // Player: columns 0,1,2,3 on the bottom row. Computer plays
        // elsewhere (column 5) each time so it never blocks.
        game.playerDrop(column: 0)
        game.computerDrop(column: 5)
        game.playerDrop(column: 1)
        game.computerDrop(column: 5)
        game.playerDrop(column: 2)
        game.computerDrop(column: 6)
        game.playerDrop(column: 3)
        #expect(game.phase == .playerWon)
        #expect(game.winningLine.count == 4)
        let columns = Set(game.winningLine.map(\.column))
        #expect(columns == Set([0, 1, 2, 3]))
    }

    // Eddie's required test: "vertical win detection."
    @Test func verticalFourInARowWins() {
        var game = ConnectFourGame()
        for _ in 0..<3 {
            game.playerDrop(column: 4)
            game.computerDrop(column: 0)
        }
        #expect(game.phase == .playerTurn)
        game.playerDrop(column: 4)
        #expect(game.phase == .playerWon)
        #expect(game.winningLine.count == 4)
        #expect(game.winningLine.allSatisfy { $0.column == 4 })
    }

    // Eddie's required test: "both diagonal win directions" -- built
    // directly against ConnectFourBoard (no turn-order bookkeeping
    // needed) since the win-detection logic itself lives entirely on
    // the board, and ConnectFourGame.resolveAfterMove just asks the
    // board for the line. This is the authoritative diagonal coverage;
    // the two ConnectFourGame-level attempts above are superseded by
    // it (kept only as documentation of why whole-game diagonal setup
    // is fiddly -- board-level is the right place to test this).
    @Test func boardDetectsAscendingDiagonalWin() {
        var board = ConnectFourBoard()
        board.drop(.player, inColumn: 0)   // (0,0)
        board.drop(.computer, inColumn: 1) // (1,0)
        board.drop(.player, inColumn: 1)   // (1,1)
        board.drop(.computer, inColumn: 2) // (2,0)
        board.drop(.computer, inColumn: 2) // (2,1)
        board.drop(.player, inColumn: 2)   // (2,2)
        board.drop(.computer, inColumn: 3) // (3,0)
        board.drop(.computer, inColumn: 3) // (3,1)
        board.drop(.computer, inColumn: 3) // (3,2)
        board.drop(.player, inColumn: 3)   // (3,3)
        let line = board.winningLine(for: .player)
        #expect(line.count == 4)
        #expect(Set(line) == Set([
            ConnectFourCoordinate(column: 0, row: 0),
            ConnectFourCoordinate(column: 1, row: 1),
            ConnectFourCoordinate(column: 2, row: 2),
            ConnectFourCoordinate(column: 3, row: 3),
        ]))
    }

    @Test func boardDetectsDescendingDiagonalWin() {
        var board = ConnectFourBoard()
        // Descending (top-left to bottom-right): (0,3), (1,2), (2,1), (3,0).
        board.drop(.computer, inColumn: 0) // (0,0)
        board.drop(.computer, inColumn: 0) // (0,1)
        board.drop(.computer, inColumn: 0) // (0,2)
        board.drop(.player, inColumn: 0)   // (0,3)
        board.drop(.computer, inColumn: 1) // (1,0)
        board.drop(.computer, inColumn: 1) // (1,1)
        board.drop(.player, inColumn: 1)   // (1,2)
        board.drop(.computer, inColumn: 2) // (2,0)
        board.drop(.player, inColumn: 2)   // (2,1)
        board.drop(.player, inColumn: 3)   // (3,0)
        let line = board.winningLine(for: .player)
        #expect(line.count == 4)
        #expect(Set(line) == Set([
            ConnectFourCoordinate(column: 0, row: 3),
            ConnectFourCoordinate(column: 1, row: 2),
            ConnectFourCoordinate(column: 2, row: 1),
            ConnectFourCoordinate(column: 3, row: 0),
        ]))
    }

    // Eddie's required test: "draw/full-board behavior if practical."
    // This exact 42-move column sequence was verified externally (a
    // script driving the identical 4-direction win check move-by-move,
    // rejecting any move that would create a win at every step) to
    // fill the board completely with no four-in-a-row for either
    // side at any point -- not just at the end. Moves alternate
    // player (even indices), computer (odd indices), matching
    // ConnectFourGame's own turn order exactly.
    @Test func aFullBoardWithNoWinnerIsADraw() {
        let moves = [5, 3, 2, 3, 1, 5, 3, 1, 0, 1, 4, 1, 2, 5, 0, 5, 6, 6, 2, 0,
                     6, 0, 4, 2, 3, 0, 3, 4, 2, 3, 2, 6, 0, 4, 1, 1, 5, 4, 4, 5, 6, 6]
        #expect(moves.count == ConnectFourBoard.columnCount * ConnectFourBoard.rowCount)
        var game = ConnectFourGame()
        for (index, column) in moves.enumerated() {
            if index % 2 == 0 {
                let row = game.playerDrop(column: column)
                #expect(row != nil, "player move \(index) into column \(column) was rejected")
            } else {
                let row = game.computerDrop(column: column)
                #expect(row != nil, "computer move \(index) into column \(column) was rejected")
            }
            // No win should ever appear before the board is completely
            // full -- the sequence was chosen specifically to avoid
            // one at every intermediate step, not just the end.
            if index < moves.count - 1 {
                #expect(game.phase == (index % 2 == 0 ? .computerTurn : .playerTurn))
            }
        }
        #expect(game.phase == .draw)
        #expect(game.board.isFull)
        #expect(game.winningLine.isEmpty)
    }

    // Eddie: "Failure offers an immediate RETRY with a fresh board."
    @Test func resetReturnsToAFreshBoardAndPlayerTurn() {
        var game = ConnectFourGame()
        game.playerDrop(column: 0)
        game.computerDrop(column: 1)
        game.reset()
        #expect(game.phase == .playerTurn)
        #expect(game.board.legalColumns.count == ConnectFourBoard.columnCount)
        #expect(game.winningLine.isEmpty)
    }

    @Test func aFreshGameNeverCarriesOverPriorState() {
        var gameA = ConnectFourGame()
        gameA.playerDrop(column: 0)
        gameA.computerDrop(column: 1)

        let gameB = ConnectFourGame()
        #expect(gameB.phase == .playerTurn)
        #expect(gameB.board.legalColumns.count == ConnectFourBoard.columnCount)
    }
}

/// AI-behavior tests -- Eddie: "the computer must play a REAL
/// game... but do NOT build a deep/minimax/expert opponent," with an
/// exact 3-rule spec (take an available win, usually block, otherwise
/// prefer central columns with randomness). Uses SeededRNG (defined
/// once in TicTacToeGame.swift and reused across every game's tests).
struct ConnectFourAITests {
    // Eddie's required test: "computer returns only legal moves."
    @Test func chooseMoveNeverReturnsAFullColumn() {
        var board = ConnectFourBoard()
        for _ in 0..<ConnectFourBoard.rowCount {
            board.drop(.player, inColumn: 3)
        }
        var rng = SeededRNG(seed: 1)
        for _ in 0..<200 {
            let move = ConnectFourAI.chooseMove(board: board, using: &rng)
            #expect(move != 3)
            if let move { #expect(board.legalColumns.contains(move)) }
        }
    }

    @Test func chooseMoveReturnsNilOnlyWhenTheBoardIsFull() {
        var board = ConnectFourBoard()
        let pattern: [ConnectFourPiece] = [.player, .computer, .player, .computer, .player, .computer]
        for column in 0..<ConnectFourBoard.columnCount {
            for piece in pattern { board.drop(piece, inColumn: column) }
        }
        #expect(board.isFull)
        var rng = SeededRNG(seed: 2)
        #expect(ConnectFourAI.chooseMove(board: board, using: &rng) == nil)
    }

    // Rule 1: "If the computer has an immediate winning move, it can
    // take it." Deterministic -- always taken, regardless of RNG.
    @Test func chooseMoveAlwaysTakesAnImmediateWin() {
        var board = ConnectFourBoard()
        // Computer has three in a row on the bottom (columns 0,1,2) --
        // column 3 completes it.
        board.drop(.computer, inColumn: 0)
        board.drop(.computer, inColumn: 1)
        board.drop(.computer, inColumn: 2)
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            var rng = SeededRNG(seed: seed)
            let move = ConnectFourAI.chooseMove(board: board, using: &rng)
            #expect(move == 3)
        }
    }

    // Rule 2: "usually (not always) block." With blockChance == 0.85,
    // across many different seeds the computer should block the
    // overwhelming majority of the time, but the AI must remain
    // capable of choosing something else at least occasionally --
    // this test checks the aggregate rate lands in a sane band rather
    // than asserting every single seed blocks (which would make the
    // "usually" in Eddie's spec meaningless).
    @Test func chooseMoveUsuallyBlocksThePlayersImmediateWin() {
        var board = ConnectFourBoard()
        // Player has three in a row on the bottom (columns 0,1,2) --
        // column 3 would complete it, and no other column is a
        // computer win, so the AI's decision here isolates Rule 2.
        board.drop(.player, inColumn: 0)
        board.drop(.player, inColumn: 1)
        board.drop(.player, inColumn: 2)
        var blockedCount = 0
        let trials = 500
        for seed in 0..<UInt64(trials) {
            var rng = SeededRNG(seed: seed + 100)
            if ConnectFourAI.chooseMove(board: board, using: &rng) == 3 {
                blockedCount += 1
            }
        }
        let rate = Double(blockedCount) / Double(trials)
        // blockChance is 0.85 -- allow a wide band since Rule 3's
        // random fallback could itself occasionally also pick column
        // 3, but the rate must clearly reflect "usually", not
        // "always" or "rarely".
        #expect(rate > 0.6)
        #expect(rate < 1.0)
    }

    // Rule 4/6/7: "give some preference to central columns... do not
    // make it obviously suicidal either." On a fully empty board (no
    // win, no threat to block), the AI should favor the center over
    // many trials without ever going outside the legal range.
    @Test func chooseMoveOnAnEmptyBoardStaysWithinRangeAndFavorsCenter() {
        let board = ConnectFourBoard()
        var centerCount = 0
        let trials = 300
        for seed in 0..<UInt64(trials) {
            var rng = SeededRNG(seed: seed + 900)
            guard let move = ConnectFourAI.chooseMove(board: board, using: &rng) else {
                Issue.record("chooseMove returned nil on an empty board")
                continue
            }
            #expect((0..<ConnectFourBoard.columnCount).contains(move))
            if move == 3 { centerCount += 1 }
        }
        // Column 3 (dead center) should come up noticeably more than
        // 1/7th of the time (pure uniform chance) given the
        // centrality preference, without being deterministic.
        #expect(Double(centerCount) / Double(trials) > 1.0 / 7.0)
    }
}
