import Testing
@testable import Hallways

/// Pure state-transition tests for Floor 13's Simon / Memory
/// Assessment -- no timers, no waiting, since SimonGame itself owns
/// none of the playback-flash scheduling (the SwiftUI overlay's view
/// model owns the wall-clock side). See SimonTerminalTests.swift for
/// the mission-completion/elevator-lock integration.
struct SimonGameTests {
    @Test func initialStateIsReady() {
        let game = SimonGame()
        #expect(game.phase == .ready)
        #expect(game.sequence.isEmpty)
        #expect(game.currentRoundLength == 0)
    }

    @Test func startCreatesAndUsesAValidSequence() {
        var rng = SeededRNG(seed: 1)
        let sequence = SimonSequenceGenerator.makeSequence(using: &rng)
        var game = SimonGame()
        game.start(sequence: sequence)
        #expect(game.phase == .playback)
        #expect(game.sequence == sequence)
    }

    @Test func generatedValuesAreOnlyAmongFourValidQuadrantIdentities() {
        var rng = SeededRNG(seed: 2)
        for _ in 0..<100 {
            let sequence = SimonSequenceGenerator.makeSequence(using: &rng)
            #expect(sequence.count == SimonGame.targetLength)
            for value in sequence {
                #expect((0..<SimonGame.quadrantCount).contains(value))
            }
        }
    }

    @Test func firstRoundExpectsLengthOne() {
        var game = SimonGame()
        game.start(sequence: [0, 1, 2, 3, 0])
        #expect(game.currentRoundLength == 1)
    }

    @Test func correctTapAdvancesAppropriately() {
        var game = SimonGame()
        game.start(sequence: [2, 1, 3, 0, 2])
        game.startInputPhase()
        #expect(game.phase == .input)
        game.tap(2) // correct -- completes round 1 (length 1)
        #expect(game.phase == .playback) // advanced into round 2's playback
        #expect(game.currentRoundLength == 2)
    }

    @Test func correctCompletionAdvancesSequenceLengthOneThroughFive() {
        let sequence = [1, 3, 0, 2, 1]
        var game = SimonGame()
        game.start(sequence: sequence)
        for round in 1...4 {
            #expect(game.currentRoundLength == round)
            game.startInputPhase()
            for i in 0..<round {
                game.tap(sequence[i])
            }
            #expect(game.currentRoundLength == round + 1)
            #expect(game.phase == .playback)
        }
        // Final round: length 5.
        #expect(game.currentRoundLength == 5)
        game.startInputPhase()
        for i in 0..<4 {
            game.tap(sequence[i])
            #expect(game.phase == .input) // not done yet
        }
        game.tap(sequence[4])
        #expect(game.phase == .success)
    }

    @Test func existingSequencePrefixIsPreservedAsRoundsGrow() {
        let sequence = [3, 3, 1, 0, 2]
        var game = SimonGame()
        game.start(sequence: sequence)
        game.startInputPhase()
        game.tap(sequence[0])
        #expect(game.sequence == sequence) // untouched -- same fixed sequence
        game.startInputPhase()
        game.tap(sequence[0])
        game.tap(sequence[1])
        #expect(game.sequence == sequence)
    }

    @Test func incorrectTapImmediatelyFails() {
        var game = SimonGame()
        game.start(sequence: [0, 1, 2, 3, 0])
        game.startInputPhase()
        game.tap(3) // wrong -- sequence[0] is 0
        #expect(game.phase == .failure)
    }

    @Test func noFurtherScoringOrInputAfterFailure() {
        var game = SimonGame()
        game.start(sequence: [0, 1, 2, 3, 0])
        game.startInputPhase()
        game.tap(3) // fails immediately
        #expect(game.phase == .failure)
        game.tap(0) // no-op: phase is no longer .input
        #expect(game.phase == .failure)
        #expect(game.inputIndex == 0)
    }

    @Test func retryResetReturnsToReady() {
        var game = SimonGame()
        game.start(sequence: [0, 1, 2, 3, 0])
        game.startInputPhase()
        game.tap(3) // fails
        #expect(game.phase == .failure)
        game.reset()
        #expect(game.phase == .ready)
        #expect(game.sequence.isEmpty)
        #expect(game.currentRoundLength == 0)
    }

    @Test func successOnlyAfterCorrectlyCompletingLengthFive() {
        let sequence = [0, 1, 2, 3, 1]
        var game = SimonGame()
        game.start(sequence: sequence)
        for round in 1..<5 {
            game.startInputPhase()
            for i in 0..<round { game.tap(sequence[i]) }
            #expect(game.phase != .success)
        }
        game.startInputPhase()
        for i in 0..<4 { game.tap(sequence[i]) }
        #expect(game.phase != .success) // fourth tap only, fifth still pending
        game.tap(sequence[4])
        #expect(game.phase == .success)
    }

    @Test func noFurtherInputAfterSuccess() {
        let sequence = [0, 0, 0, 0, 0]
        var game = SimonGame()
        game.start(sequence: sequence)
        for round in 1...5 {
            game.startInputPhase()
            for _ in 0..<round { game.tap(0) }
        }
        #expect(game.phase == .success)
        game.tap(0) // no-op: phase is no longer .input
        #expect(game.phase == .success)
    }

    @Test func consecutiveIdenticalQuadrantValuesAreLegal() {
        // "1, 1" back to back -- Eddie: "Consecutive identical
        // quadrants are allowed if that naturally occurs. That is
        // legitimate Simon behavior."
        var game = SimonGame()
        game.start(sequence: [1, 1, 2, 3, 0])
        game.startInputPhase()
        game.tap(1) // round 1 complete
        #expect(game.phase == .playback)
        #expect(game.currentRoundLength == 2)
        game.startInputPhase()
        game.tap(1)
        game.tap(1) // round 2 complete -- both taps against the repeated value
        #expect(game.phase == .playback)
        #expect(game.currentRoundLength == 3)
    }

    @Test func startIsANoOpOnceAlreadyPlaying() {
        var game = SimonGame()
        game.start(sequence: [0, 1, 2, 3, 0])
        game.start(sequence: [3, 3, 3, 3, 3]) // no-op: phase is no longer .ready
        #expect(game.sequence == [0, 1, 2, 3, 0])
    }

    @Test func startRejectsAWronglySizedSequence() {
        var game = SimonGame()
        game.start(sequence: [0, 1, 2]) // too short
        #expect(game.phase == .ready)
        #expect(game.sequence.isEmpty)
    }

    @Test func aFreshGameNeverCarriesOverPriorRoundState() {
        // Mirrors WhackAMoleGameTests' equivalent check: a brand new
        // SimonGame() is always a clean .ready slate regardless of
        // what any other instance did -- this is exactly the
        // model-level guarantee that makes stale/cancelled overlay
        // playback callbacks harmless: a fresh game (or a reset one)
        // never inherits another run's sequence/round state.
        var gameA = SimonGame()
        gameA.start(sequence: [0, 1, 2, 3, 0])
        gameA.startInputPhase()
        gameA.tap(0)

        let gameB = SimonGame()
        #expect(gameB.phase == .ready)
        #expect(gameB.sequence.isEmpty)
        #expect(gameB.currentRoundLength == 0)
    }
}
