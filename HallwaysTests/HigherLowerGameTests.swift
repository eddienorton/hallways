import Testing
@testable import Hallways

/// Pure game-logic tests for Floor 10's Higher/Lower -- the
/// current-vs-next comparison and the 3-in-a-row streak tracker. See
/// PlayingCardTests.swift for the deck itself and
/// HigherLowerTerminalTests.swift for the mission-completion/
/// elevator-lock integration.
struct HigherLowerGameTests {
    @Test func twoVsThreeHigherSucceeds() {
        #expect(HigherLowerGame.evaluate(current: .two, next: .three, guess: .higher) == .correct)
    }

    @Test func threeVsTwoLowerSucceeds() {
        #expect(HigherLowerGame.evaluate(current: .three, next: .two, guess: .lower) == .correct)
    }

    @Test func kingVsAceHigherSucceeds() {
        // Confirms ace-high: an ace beats a king going "higher."
        #expect(HigherLowerGame.evaluate(current: .king, next: .ace, guess: .higher) == .correct)
    }

    @Test func aceVsKingLowerSucceeds() {
        // Same fact from the other direction: a king is lower than an ace.
        #expect(HigherLowerGame.evaluate(current: .ace, next: .king, guess: .lower) == .correct)
    }

    @Test func sameRankIsAlwaysAPushRegardlessOfGuess() {
        #expect(HigherLowerGame.evaluate(current: .seven, next: .seven, guess: .higher) == .push)
        #expect(HigherLowerGame.evaluate(current: .seven, next: .seven, guess: .lower) == .push)
    }

    @Test func guessingTheWrongDirectionIsWrong() {
        #expect(HigherLowerGame.evaluate(current: .two, next: .three, guess: .lower) == .wrong)
        #expect(HigherLowerGame.evaluate(current: .three, next: .two, guess: .higher) == .wrong)
    }

    @Test func everyNonEqualPairResolvesToExactlyOneCorrectGuessDirection() {
        for current in Rank.allCases {
            for next in Rank.allCases where next != current {
                let higher = HigherLowerGame.evaluate(current: current, next: next, guess: .higher)
                let lower = HigherLowerGame.evaluate(current: current, next: next, guess: .lower)
                // Never both correct, never both wrong -- exactly one guess wins.
                #expect((higher == .correct) != (lower == .correct))
                #expect(higher != .push)
                #expect(lower != .push)
            }
        }
    }

    @Test func streakStartsAtZeroAndIsNotComplete() {
        let streak = HigherLowerStreak()
        #expect(streak.count == 0)
        #expect(!streak.isComplete)
    }

    @Test func correctResultsIncrementTheStreak() {
        var streak = HigherLowerStreak()
        streak.apply(.correct)
        #expect(streak.count == 1)
        streak.apply(.correct)
        #expect(streak.count == 2)
    }

    @Test func wrongResultResetsTheStreakToZero() {
        var streak = HigherLowerStreak()
        streak.apply(.correct)
        streak.apply(.correct)
        streak.apply(.wrong)
        #expect(streak.count == 0)
    }

    @Test func pushLeavesTheStreakUnchanged() {
        var streak = HigherLowerStreak()
        streak.apply(.correct)
        streak.apply(.push)
        #expect(streak.count == 1)
    }

    @Test func threeCorrectInARowCompletesTheStreak() {
        var streak = HigherLowerStreak()
        streak.apply(.correct)
        streak.apply(.correct)
        #expect(!streak.isComplete)
        streak.apply(.correct)
        #expect(streak.isComplete)
        #expect(streak.count == 3)
    }

    @Test func aWrongGuessAfterTwoCorrectDoesNotCarryOverPartialCredit() {
        var streak = HigherLowerStreak()
        streak.apply(.correct)
        streak.apply(.correct)
        streak.apply(.wrong)
        streak.apply(.correct)
        streak.apply(.correct)
        #expect(!streak.isComplete) // back to only 2 in a row, not 4 total
        streak.apply(.correct)
        #expect(streak.isComplete)
    }
}
