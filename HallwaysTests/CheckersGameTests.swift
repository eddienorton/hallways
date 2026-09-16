import Testing
@testable import Hallways

/// Pure state-transition tests for Floor 15's Checkers -- no timers,
/// no waiting, since CheckersGame itself owns none of the computer's
/// move timing/animation (the SwiftUI overlay's view model owns
/// that). See CheckersTerminalTests.swift for the mission-completion/
/// elevator-lock integration.
///
/// Several fixtures below replay an exact, specific sequence of moves
/// from the standard starting position rather than constructing a
/// board by hand -- CheckersBoard only ever exposes the standard 12-
/// per-side setup through its public initializer, so reaching a
/// particular capture/multi-jump/king position means actually playing
/// legal moves to get there. Every such sequence was independently
/// verified move-by-move against a standalone Python re-implementation
/// of this exact file's rules (board setup, mandatory capture,
/// multi-jump continuation, promotion, win detection) before being
/// transcribed here, the same technique used for Connect Four's own
/// draw-sequence fixture.
struct CheckersGameTests {
    // Eddie's required test: "initial board setup."
    @Test func initialBoardHas12PiecesPerSideOnTheDarkSquares() {
        let board = CheckersBoard()
        let playerCoords = board.squaresOccupied(by: .player)
        let computerCoords = board.squaresOccupied(by: .computer)
        #expect(playerCoords.count == 12)
        #expect(computerCoords.count == 12)
        #expect((playerCoords + computerCoords).allSatisfy { CheckersBoard.isPlayable($0) })
        // Player occupies rows 0-2, computer rows 5-7, middle two rows empty.
        #expect(playerCoords.allSatisfy { $0.row <= 2 })
        #expect(computerCoords.allSatisfy { $0.row >= 5 })
        #expect(board.piece(at: CheckersCoordinate(col: 1, row: 0)) == CheckersPiece(side: .player))
        #expect(board.piece(at: CheckersCoordinate(col: 0, row: 5)) == CheckersPiece(side: .computer))
        #expect(board.piece(at: CheckersCoordinate(col: 0, row: 3)) == nil)
        #expect(board.piece(at: CheckersCoordinate(col: 1, row: 4)) == nil)
        // No piece starts as a king.
        #expect((playerCoords + computerCoords).allSatisfy { !(board.piece(at: $0)?.isKing ?? true) })
    }

    @Test func initialStateIsPlayerTurnWithNoForcedContinuation() {
        let game = CheckersGame()
        #expect(game.phase == .playerTurn)
        #expect(game.mustContinueFrom == nil)
        #expect(!game.legalMovesForCurrentTurn.isEmpty)
    }

    // Eddie's required test: "legal normal moves."
    @Test func aSimpleForwardDiagonalMoveIntoAnEmptySquareSucceeds() {
        var game = CheckersGame()
        let from = CheckersCoordinate(col: 1, row: 2)
        let to = CheckersCoordinate(col: 0, row: 3)
        let move = CheckersMove(from: from, to: to, captured: nil)
        #expect(game.legalMovesForCurrentTurn.contains(move))
        let applied = game.playerMove(move)
        #expect(applied)
        #expect(game.board.piece(at: from) == nil)
        #expect(game.board.piece(at: to) == CheckersPiece(side: .player))
        #expect(game.phase == .computerTurn)
    }

    // Eddie's required test: "illegal moves."
    @Test func aNonDiagonalMoveIsRejectedAndChangesNothing() {
        var game = CheckersGame()
        let from = CheckersCoordinate(col: 1, row: 0)
        let bogus = CheckersMove(from: from, to: CheckersCoordinate(col: 1, row: 1), captured: nil)
        #expect(!game.legalMovesForCurrentTurn.contains(bogus))
        let applied = game.playerMove(bogus)
        #expect(!applied)
        #expect(game.board.piece(at: from) == CheckersPiece(side: .player))
        #expect(game.phase == .playerTurn)
    }

    @Test func playerMoveIsANoOpDuringTheComputersTurn() {
        var game = CheckersGame()
        game.playerMove(CheckersMove(from: CheckersCoordinate(col: 1, row: 2), to: CheckersCoordinate(col: 0, row: 3), captured: nil))
        #expect(game.phase == .computerTurn)
        let anyComputerMove = game.legalMovesForCurrentTurn.first!
        let result = game.playerMove(anyComputerMove)
        #expect(!result)
    }

    @Test func computerMoveIsANoOpDuringThePlayersTurn() {
        var game = CheckersGame()
        #expect(game.phase == .playerTurn)
        let anyPlayerMove = game.legalMovesForCurrentTurn.first!
        let result = game.computerMove(anyPlayerMove)
        #expect(!result)
        #expect(game.phase == .playerTurn)
    }

    // Eddie's required tests: "captures" and "captured-piece removal."
    // Moves 0-7 of the verified fixture: a routine opening followed by
    // a player capture (move 6) and an immediate computer recapture
    // (move 7) -- both jumped pieces are confirmed removed from the
    // board at the moment of capture.
    @Test func aCaptureRemovesTheJumpedPieceAndLandsBeyondIt() {
        var game = CheckersGame()
        #expect(game.playerMove(CheckersMove(from: c(5, 2), to: c(4, 3), captured: nil)))
        #expect(game.computerMove(CheckersMove(from: c(0, 5), to: c(1, 4), captured: nil)))
        #expect(game.playerMove(CheckersMove(from: c(4, 1), to: c(5, 2), captured: nil)))
        #expect(game.computerMove(CheckersMove(from: c(1, 6), to: c(0, 5), captured: nil)))
        #expect(game.playerMove(CheckersMove(from: c(3, 0), to: c(4, 1), captured: nil)))
        #expect(game.computerMove(CheckersMove(from: c(6, 5), to: c(5, 4), captured: nil)))

        // Move 6: player jumps (4,3) over (5,4) landing at (6,5).
        let capture = CheckersMove(from: c(4, 3), to: c(6, 5), captured: c(5, 4))
        #expect(game.legalMovesForCurrentTurn.contains(capture))
        #expect(game.playerMove(capture))
        #expect(game.board.piece(at: c(5, 4)) == nil, "the jumped computer piece must be removed")
        #expect(game.board.piece(at: c(6, 5)) == CheckersPiece(side: .player))
        #expect(game.board.piece(at: c(4, 3)) == nil)

        // Move 7: computer immediately recaptures, jumping (7,6) over
        // the piece that just landed at (6,5), removing it in turn.
        let recapture = CheckersMove(from: c(7, 6), to: c(5, 4), captured: c(6, 5))
        #expect(game.legalMovesForCurrentTurn.contains(recapture))
        #expect(game.computerMove(recapture))
        #expect(game.board.piece(at: c(6, 5)) == nil, "the recaptured player piece must be removed")
        #expect(game.board.piece(at: c(5, 4)) == CheckersPiece(side: .computer))
        #expect(game.phase == .playerTurn)
    }

    // Eddie's required test: "mandatory capture behavior." Reached
    // from the same opening as above, but stopping one move earlier:
    // at this exact position the player has four different ordinary
    // (non-capturing) moves available on OTHER pieces, plus exactly
    // one capture -- and legalMovesForCurrentTurn must contain ONLY
    // the capture, per Eddie's "use standard mandatory captures."
    @Test func aCaptureIsMandatoryEvenWhenOtherOrdinaryMovesExist() {
        var game = CheckersGame()
        #expect(game.playerMove(CheckersMove(from: c(5, 2), to: c(4, 3), captured: nil)))
        #expect(game.computerMove(CheckersMove(from: c(0, 5), to: c(1, 4), captured: nil)))
        #expect(game.playerMove(CheckersMove(from: c(4, 1), to: c(5, 2), captured: nil)))
        #expect(game.computerMove(CheckersMove(from: c(1, 6), to: c(0, 5), captured: nil)))
        #expect(game.playerMove(CheckersMove(from: c(3, 0), to: c(4, 1), captured: nil)))
        #expect(game.computerMove(CheckersMove(from: c(6, 5), to: c(5, 4), captured: nil)))

        #expect(game.phase == .playerTurn)
        let legal = game.legalMovesForCurrentTurn
        #expect(legal.count == 1)
        #expect(legal.allSatisfy(\.isCapture))
        #expect(legal.first == CheckersMove(from: c(4, 3), to: c(6, 5), captured: c(5, 4)))

        // Confirm this wasn't simply the ONLY legal-looking move --
        // several ordinary diagonal moves exist on other pieces and
        // are excluded purely by the mandatory-capture rule.
        let ordinaryElsewhere = CheckersMove(from: c(7, 2), to: c(6, 3), captured: nil)
        #expect(!legal.contains(ordinaryElsewhere))
        #expect(!game.playerMove(ordinaryElsewhere))
    }

    // Eddie's required test: "multiple jumps" (and, along the way,
    // "king promotion" -- the second leg of this exact chain lands on
    // the computer's far row). Continues the fixture above.
    @Test func aMultiJumpContinuesTheSameTurnAndCanEndInPromotion() {
        var game = CheckersGame()
        let opening: [(CheckersCoordinate, CheckersCoordinate, CheckersCoordinate?, CheckersSide)] = [
            (c(5, 2), c(4, 3), nil, .player),
            (c(0, 5), c(1, 4), nil, .computer),
            (c(4, 1), c(5, 2), nil, .player),
            (c(1, 6), c(0, 5), nil, .computer),
            (c(3, 0), c(4, 1), nil, .player),
            (c(6, 5), c(5, 4), nil, .computer),
            (c(4, 3), c(6, 5), c(5, 4), .player),
            (c(7, 6), c(5, 4), c(6, 5), .computer),
            (c(1, 2), c(2, 3), nil, .player),
            (c(2, 5), c(3, 4), nil, .computer),
            (c(7, 2), c(6, 3), nil, .player),
        ]
        for (from, to, captured, side) in opening {
            let move = CheckersMove(from: from, to: to, captured: captured)
            let applied = side == .player ? game.playerMove(move) : game.computerMove(move)
            #expect(applied, "setup move \(from)->\(to) should have been legal")
        }

        #expect(game.phase == .computerTurn)
        #expect(game.mustContinueFrom == nil)

        // First leg: computer jumps (3,4) over (2,3) landing at (1,2).
        let firstLeg = CheckersMove(from: c(3, 4), to: c(1, 2), captured: c(2, 3))
        #expect(game.legalMovesForCurrentTurn.contains(firstLeg))
        #expect(game.computerMove(firstLeg))
        // The turn does not pass -- another capture is available from
        // the square just landed on, so the SAME side must continue.
        #expect(game.phase == .computerTurn)
        #expect(game.mustContinueFrom == c(1, 2))
        #expect(game.legalMovesForCurrentTurn.allSatisfy { $0.from == c(1, 2) })

        // Second leg: (1,2) jumps over (2,1) landing at (3,0) -- the
        // computer's far row, so this also promotes the piece to king.
        let secondLeg = CheckersMove(from: c(1, 2), to: c(3, 0), captured: c(2, 1))
        #expect(game.legalMovesForCurrentTurn.contains(secondLeg))
        #expect(game.computerMove(secondLeg))
        #expect(game.board.piece(at: c(2, 1)) == nil, "both jumped pieces must be removed")
        #expect(game.board.piece(at: c(2, 3)) == nil)

        // Eddie's required test: "king promotion."
        let promoted = game.board.piece(at: c(3, 0))
        #expect(promoted?.side == .computer)
        #expect(promoted?.isKing == true)

        // The multi-jump chain is over (no further capture from (3,0)
        // right now) and the turn correctly passes back to the player.
        #expect(game.mustContinueFrom == nil)
        #expect(game.phase == .playerTurn)
    }

    // Eddie's required test: "king backward movement." Reuses the
    // exact position reached above, where (3,0) is a freshly-promoted
    // computer king -- its home/forward direction is toward row 0, so
    // a move toward row 1 is strictly backward, and only a king may
    // take it.
    @Test func aKingMayMoveBackwardTowardItsOwnStartingEdge() {
        var game = CheckersGame()
        let moves: [(CheckersCoordinate, CheckersCoordinate, CheckersCoordinate?, CheckersSide)] = [
            (c(5, 2), c(4, 3), nil, .player),
            (c(0, 5), c(1, 4), nil, .computer),
            (c(4, 1), c(5, 2), nil, .player),
            (c(1, 6), c(0, 5), nil, .computer),
            (c(3, 0), c(4, 1), nil, .player),
            (c(6, 5), c(5, 4), nil, .computer),
            (c(4, 3), c(6, 5), c(5, 4), .player),
            (c(7, 6), c(5, 4), c(6, 5), .computer),
            (c(1, 2), c(2, 3), nil, .player),
            (c(2, 5), c(3, 4), nil, .computer),
            (c(7, 2), c(6, 3), nil, .player),
            (c(3, 4), c(1, 2), c(2, 3), .computer),
            (c(1, 2), c(3, 0), c(2, 1), .computer),
        ]
        for (from, to, captured, side) in moves {
            let move = CheckersMove(from: from, to: to, captured: captured)
            let applied = side == .player ? game.playerMove(move) : game.computerMove(move)
            #expect(applied)
        }

        let king = c(3, 0)
        #expect(game.board.piece(at: king) == CheckersPiece(side: .computer, isKing: true))
        // Backward for the computer (whose forward delta is -1) means
        // increasing row -- (3,0) -> (2,1) is exactly that.
        let backwardMoves = game.board.simpleMoves(from: king)
        #expect(backwardMoves.contains(CheckersMove(from: king, to: c(2, 1), captured: nil)))
        #expect(backwardMoves.allSatisfy { $0.to.row > king.row })
    }

    // Eddie's required test: "win/no-legal-move detection." A full
    // 33-ply game played out from the standard opening (verified
    // externally move-by-move, respecting mandatory capture and
    // multi-jump at every step) that ends with the player fully
    // eliminated -- CheckersGame must recognize this the instant it
    // happens, purely as a side effect of the normal move sequence.
    @Test func aSideWithNoPiecesAndNoLegalMovesLosesImmediately() {
        var game = CheckersGame()
        let moves: [(Int, Int, Int, Int, Int?, Int?, CheckersSide)] = [
            (5, 2, 4, 3, nil, nil, .player),
            (0, 5, 1, 4, nil, nil, .computer),
            (4, 1, 5, 2, nil, nil, .player),
            (1, 6, 0, 5, nil, nil, .computer),
            (3, 0, 4, 1, nil, nil, .player),
            (6, 5, 5, 4, nil, nil, .computer),
            (4, 3, 6, 5, 5, 4, .player),
            (7, 6, 5, 4, 6, 5, .computer),
            (1, 2, 2, 3, nil, nil, .player),
            (2, 5, 3, 4, nil, nil, .computer),
            (7, 2, 6, 3, nil, nil, .player),
            (3, 4, 1, 2, 2, 3, .computer),
            (1, 2, 3, 0, 2, 1, .computer),
            (3, 2, 4, 3, nil, nil, .player),
            (5, 4, 7, 2, 6, 3, .computer),
            (5, 2, 6, 3, nil, nil, .player),
            (3, 0, 5, 2, 4, 1, .computer),
            (5, 2, 7, 4, 6, 3, .computer),
            (4, 3, 3, 4, nil, nil, .player),
            (4, 5, 2, 3, 3, 4, .computer),
            (5, 0, 4, 1, nil, nil, .player),
            (7, 2, 5, 0, 6, 1, .computer),
            (5, 0, 3, 2, 4, 1, .computer),
            (1, 0, 2, 1, nil, nil, .player),
            (3, 2, 1, 0, 2, 1, .computer),
            (7, 0, 6, 1, nil, nil, .player),
            (2, 7, 1, 6, nil, nil, .computer),
            (6, 1, 7, 2, nil, nil, .player),
            (5, 6, 6, 5, nil, nil, .computer),
            (0, 1, 1, 2, nil, nil, .player),
            (2, 3, 0, 1, 1, 2, .computer),
            (7, 2, 6, 3, nil, nil, .player),
            (7, 4, 5, 2, 6, 3, .computer),
        ]
        for (index, entry) in moves.enumerated() {
            let (fc, fr, tc, tr, cc, cr, side) = entry
            let captured = (cc != nil && cr != nil) ? CheckersCoordinate(col: cc!, row: cr!) : nil
            let move = CheckersMove(from: c(fc, fr), to: c(tc, tr), captured: captured)
            let applied = side == .player ? game.playerMove(move) : game.computerMove(move)
            #expect(applied, "move \(index) (\(fc),\(fr))->(\(tc),\(tr)) should have been legal")
        }

        #expect(game.phase == .computerWon)
        #expect(game.board.squaresOccupied(by: .player).isEmpty)
        #expect(game.board.legalMoves(for: .player).isEmpty)
    }

    // Eddie: "retry starts fresh... no lives, money loss, punishment,
    // or dead end."
    @Test func resetReturnsToAFreshStandardBoardAndPlayerTurn() {
        var game = CheckersGame()
        #expect(game.playerMove(CheckersMove(from: c(1, 2), to: c(0, 3), captured: nil)))
        #expect(game.computerMove(game.legalMovesForCurrentTurn.first!))
        game.reset()
        #expect(game.phase == .playerTurn)
        #expect(game.mustContinueFrom == nil)
        #expect(game == CheckersGame())
    }

    @Test func aFreshGameNeverCarriesOverPriorState() {
        var gameA = CheckersGame()
        gameA.playerMove(CheckersMove(from: c(1, 2), to: c(0, 3), captured: nil))

        let gameB = CheckersGame()
        #expect(gameB.phase == .playerTurn)
        #expect(gameB == CheckersGame())
    }

    private func c(_ col: Int, _ row: Int) -> CheckersCoordinate {
        CheckersCoordinate(col: col, row: row)
    }
}

/// AI-behavior tests -- Eddie: "competent enough to feel like an
/// opponent but NOT a Checkers engine demonstration... simple
/// heuristics plus randomness... allow imperfect decisions." Uses
/// SeededRNG (defined once in TicTacToeGame.swift and reused across
/// every game's tests).
struct CheckersAITests {
    // Eddie's required test: "computer returns only legal moves."
    @Test func chooseMoveAlwaysReturnsAMoveFromLegalMovesForCurrentTurn() {
        var game = CheckersGame()
        // Advance to the computer's turn.
        game.playerMove(CheckersMove(from: CheckersCoordinate(col: 1, row: 2), to: CheckersCoordinate(col: 0, row: 3), captured: nil))
        #expect(game.phase == .computerTurn)
        for seed: UInt64 in 0..<50 {
            var rng = SeededRNG(seed: seed + 1)
            guard let move = CheckersAI.chooseMove(game: game, using: &rng) else {
                Issue.record("chooseMove returned nil while legal moves existed")
                continue
            }
            #expect(game.legalMovesForCurrentTurn.contains(move))
        }
    }

    // When a multi-jump leaves exactly one legal continuation (a very
    // common mid-chain situation), the AI must deterministically take
    // it regardless of RNG seed -- there is nothing else it could
    // legally choose. Reaches that exact position via the same
    // verified fixture as the multi-jump test above.
    @Test func chooseMoveTakesTheOnlyLegalContinuationDuringAForcedMultiJump() {
        var game = CheckersGame()
        let setup: [(CheckersCoordinate, CheckersCoordinate, CheckersCoordinate?, CheckersSide)] = [
            (c(5, 2), c(4, 3), nil, .player),
            (c(0, 5), c(1, 4), nil, .computer),
            (c(4, 1), c(5, 2), nil, .player),
            (c(1, 6), c(0, 5), nil, .computer),
            (c(3, 0), c(4, 1), nil, .player),
            (c(6, 5), c(5, 4), nil, .computer),
            (c(4, 3), c(6, 5), c(5, 4), .player),
            (c(7, 6), c(5, 4), c(6, 5), .computer),
            (c(1, 2), c(2, 3), nil, .player),
            (c(2, 5), c(3, 4), nil, .computer),
            (c(7, 2), c(6, 3), nil, .player),
            (c(3, 4), c(1, 2), c(2, 3), .computer),
        ]
        for (from, to, captured, side) in setup {
            let move = CheckersMove(from: from, to: to, captured: captured)
            let applied = side == .player ? game.playerMove(move) : game.computerMove(move)
            #expect(applied)
        }
        #expect(game.mustContinueFrom == c(1, 2))
        #expect(game.legalMovesForCurrentTurn.count == 1)
        let expected = game.legalMovesForCurrentTurn.first!
        for seed: UInt64 in 0..<20 {
            var rng = SeededRNG(seed: seed + 500)
            #expect(CheckersAI.chooseMove(game: game, using: &rng) == expected)
        }
    }

    private func c(_ col: Int, _ row: Int) -> CheckersCoordinate {
        CheckersCoordinate(col: col, row: row)
    }
}
