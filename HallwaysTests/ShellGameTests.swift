import Testing
@testable import Hallways

/// Pure game-logic tests for Floor 8's shell game -- and specifically
/// for the one rule Eddie called non-negotiable (Sept 13): "Choose
/// the ball's starting cup BEFORE the shuffle. Then perform REAL cup
/// swaps. Maintain the actual identity/location of the ball-containing
/// cup throughout every swap... there must be ONE objectively correct
/// cup determined entirely by the actual swap sequence the player
/// watched." Every test below hand-verifies winningSlot against a
/// swap sequence worked out independently (see the comment on each),
/// not against ShellGameRound's own implementation -- the whole point
/// is to catch this type ever disagreeing with honest bookkeeping.
struct ShellGameTests {
    @Test func freshRoundHasTheIdentityPermutationAndTheBallUnderItsOwnCup() {
        let round = ShellGameRound(ballCupID: 1)
        #expect(round.cupAtSlot == [0, 1, 2])
        #expect(round.winningSlot == 1) // cup 1 starts at slot 1
    }

    /// Ball starts under cup 0 (so at slot 0). Swaps: (0,2), (1,2), (0,1).
    /// Hand-worked-out by simulation, independent of ShellGameRound:
    ///   start           [0,1,2]  ball(cup0) at slot 0
    ///   swap(0,2)    -> [2,1,0]  ball(cup0) at slot 2
    ///   swap(1,2)    -> [2,0,1]  ball(cup0) at slot 1
    ///   swap(0,1)    -> [0,2,1]  ball(cup0) at slot 0
    @Test func aKnownSwapSequenceProducesTheDeterministicCorrectCup() {
        var round = ShellGameRound(ballCupID: 0)
        round.swap(0, 2)
        #expect(round.cupAtSlot == [2, 1, 0])
        #expect(round.winningSlot == 2)

        round.swap(1, 2)
        #expect(round.cupAtSlot == [2, 0, 1])
        #expect(round.winningSlot == 1)

        round.swap(0, 1)
        #expect(round.cupAtSlot == [0, 2, 1])
        #expect(round.winningSlot == 0)
    }

    /// A longer sequence, ball starting under cup 2, hand-verified the
    /// same way as above -- covers a swap touching the same slot pair
    /// twice in a row (swap(1,2) appears twice, non-adjacent) and the
    /// winning slot moving multiple times across the run.
    ///   start                [0,1,2]  ball(cup2) at slot 2
    ///   swap(0,1)         -> [1,0,2]  ball(cup2) at slot 2
    ///   swap(1,2)         -> [1,2,0]  ball(cup2) at slot 1
    ///   swap(0,2)         -> [0,2,1]  ball(cup2) at slot 1
    ///   swap(0,1)         -> [2,0,1]  ball(cup2) at slot 0
    ///   swap(1,2)         -> [2,1,0]  ball(cup2) at slot 0
    ///   swap(0,1)         -> [1,2,0]  ball(cup2) at slot 1
    @Test func aLongerKnownSequenceStillProducesTheDeterministicCorrectCup() {
        var round = ShellGameRound(ballCupID: 2)
        let steps: [(Int, Int)] = [(0, 1), (1, 2), (0, 2), (0, 1), (1, 2), (0, 1)]
        let expectedCupAtSlot: [[Int]] = [[1, 0, 2], [1, 2, 0], [0, 2, 1], [2, 0, 1], [2, 1, 0], [1, 2, 0]]
        let expectedWinningSlot = [2, 1, 1, 0, 0, 1]

        for (i, (a, b)) in steps.enumerated() {
            round.swap(a, b)
            #expect(round.cupAtSlot == expectedCupAtSlot[i])
            #expect(round.winningSlot == expectedWinningSlot[i])
        }
    }

    /// The ball's identity never changes, no matter how the cups move.
    @Test func ballCupIDNeverChangesAcrossSwaps() {
        var round = ShellGameRound(ballCupID: 1)
        for (a, b) in [(0, 1), (1, 2), (0, 2), (0, 1), (1, 2)] {
            round.swap(a, b)
            #expect(round.ballCupID == 1)
        }
    }

    /// A swap always keeps cupAtSlot a permutation of 0...2 -- if it
    /// ever didn't, winningSlot's force-unwrap would crash instead of
    /// silently lying, which is itself part of the honesty guarantee.
    @Test func cupAtSlotIsAlwaysAPermutationOfAllThreeCupsAfterAnySwap() {
        var round = ShellGameRound(ballCupID: 0)
        for (a, b) in [(0, 2), (1, 2), (0, 1), (2, 1), (0, 2), (1, 0)] {
            round.swap(a, b)
            #expect(Set(round.cupAtSlot) == Set([0, 1, 2]))
        }
    }

    /// Out-of-range or no-op swap requests never crash and never
    /// silently move a cup.
    @Test func outOfRangeOrIdenticalSwapRequestsAreIgnored() {
        var round = ShellGameRound(ballCupID: 0)
        round.swap(0, 0)
        #expect(round.cupAtSlot == [0, 1, 2])
        round.swap(-1, 2)
        #expect(round.cupAtSlot == [0, 1, 2])
        round.swap(0, 5)
        #expect(round.cupAtSlot == [0, 1, 2])
    }

    @Test func shuffleProducesTheRequestedSwapCount() {
        var rng = SeededRNG(seed: 42)
        let steps = ShellGameShuffle.plan(swapCount: 8, using: &rng)
        #expect(steps.count == 8)
    }

    @Test func shuffleSwapsAlwaysNameTwoDistinctValidSlots() {
        var rng = SeededRNG(seed: 7)
        let steps = ShellGameShuffle.plan(swapCount: 30, using: &rng)
        for step in steps {
            #expect((0..<3).contains(step.slotA))
            #expect((0..<3).contains(step.slotB))
            #expect(step.slotA != step.slotB)
        }
    }

    /// Eddie: "start slowly enough that the player can genuinely
    /// follow... gradually increase the speed." The first swap should
    /// take distinctly longer than the last.
    @Test func shuffleDurationAcceleratesFromFirstSwapToLast() throws {
        var rng = SeededRNG(seed: 99)
        let steps = ShellGameShuffle.plan(swapCount: 8, using: &rng)
        let first = try #require(steps.first)
        let last = try #require(steps.last)
        #expect(first.duration > last.duration)
        // Every step in between is non-increasing relative to the one before.
        for i in 1..<steps.count {
            #expect(steps[i].duration <= steps[i - 1].duration)
        }
    }

    @Test func zeroRequestedSwapsProducesAnEmptyPlan() {
        var rng = SeededRNG(seed: 1)
        let steps = ShellGameShuffle.plan(swapCount: 0, using: &rng)
        #expect(steps.isEmpty)
    }
}
