import Testing
@testable import Hallways

/// Pure game-logic tests for Floor 9's Rock Paper Scissors -- all 9
/// player/computer combinations, plus a sanity check that
/// randomMove(using:) only ever produces one of the three real moves.
/// See RockPaperScissorsTerminalTests.swift for the mission-
/// completion/elevator-lock integration.
struct RockPaperScissorsTests {
    @Test func rockVsRockIsATie() {
        #expect(RPSGame.outcome(player: .rock, computer: .rock) == .tie)
    }

    @Test func rockVsPaperIsAPlayerLoss() {
        #expect(RPSGame.outcome(player: .rock, computer: .paper) == .computerWins)
    }

    @Test func rockVsScissorsIsAPlayerWin() {
        #expect(RPSGame.outcome(player: .rock, computer: .scissors) == .playerWins)
    }

    @Test func paperVsRockIsAPlayerWin() {
        #expect(RPSGame.outcome(player: .paper, computer: .rock) == .playerWins)
    }

    @Test func paperVsPaperIsATie() {
        #expect(RPSGame.outcome(player: .paper, computer: .paper) == .tie)
    }

    @Test func paperVsScissorsIsAPlayerLoss() {
        #expect(RPSGame.outcome(player: .paper, computer: .scissors) == .computerWins)
    }

    @Test func scissorsVsRockIsAPlayerLoss() {
        #expect(RPSGame.outcome(player: .scissors, computer: .rock) == .computerWins)
    }

    @Test func scissorsVsPaperIsAPlayerWin() {
        #expect(RPSGame.outcome(player: .scissors, computer: .paper) == .playerWins)
    }

    @Test func scissorsVsScissorsIsATie() {
        #expect(RPSGame.outcome(player: .scissors, computer: .scissors) == .tie)
    }

    /// Every same-move pairing is a tie, every other pairing is a win
    /// for exactly one side -- confirms the outcome table has no gaps
    /// and no pairing resolves to both a win and a loss depending on
    /// argument order in some inconsistent way.
    @Test func everyPairingIsConsistentAndExhaustive() {
        for player in RPSMove.allCases {
            for computer in RPSMove.allCases {
                let forward = RPSGame.outcome(player: player, computer: computer)
                let reversed = RPSGame.outcome(player: computer, computer: player)
                if player == computer {
                    #expect(forward == .tie)
                    #expect(reversed == .tie)
                } else {
                    // Swapping who's "player" flips a win into a loss and vice versa.
                    #expect((forward == .playerWins && reversed == .computerWins) ||
                            (forward == .computerWins && reversed == .playerWins))
                }
            }
        }
    }

    @Test func randomMoveAlwaysProducesOneOfTheThreeRealMoves() {
        var rng = SeededRNG(seed: 123)
        for _ in 0..<50 {
            let move = RPSGame.randomMove(using: &rng)
            #expect(RPSMove.allCases.contains(move))
        }
    }

    @Test func displayNameIsTheUppercasedMoveName() {
        #expect(RPSMove.rock.displayName == "ROCK")
        #expect(RPSMove.paper.displayName == "PAPER")
        #expect(RPSMove.scissors.displayName == "SCISSORS")
    }
}
