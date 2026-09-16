import Foundation

/// Floor 8's second embedded mini-game -- the classic THREE-CUP SHELL
/// GAME (Eddie, Sept 13, right after confirming Floor 7's Tic-Tac-Toe
/// is "FUCKING PERFECT" on-device: "Shell Game should be the second
/// clean implementation"). Pure game logic only, no SceneKit, no
/// SwiftUI -- same shape as TicTacToeGame.swift, its own file, not a
/// shared mini-game framework.
///
/// Eddie's own words, non-negotiable: "The shell game must be
/// logically honest. Choose the ball's starting cup BEFORE the
/// shuffle. Then perform REAL cup swaps. Maintain the actual
/// identity/location of the ball-containing cup throughout every
/// swap... At the end there must be ONE objectively correct cup
/// determined entirely by the actual swap sequence the player
/// watched." ShellGameRound below is the entire honesty guarantee:
/// cupAtSlot is the ONE piece of state that both the on-screen
/// animation (ShellGameOverlay swaps cups by driving straight off
/// this same array -- see its performSwaps) and winningSlot below
/// read, so there is no separate "visual" copy that could ever be
/// nudged out of sync with the "real" one. Nothing here ever re-rolls
/// or reassigns ballCupID after init, and nothing ever sets
/// cupAtSlot directly -- swap(_:_:) is the only mutator, and it is a
/// literal, honest swap of two array elements.
nonisolated struct ShellGameRound: Equatable {
    /// Which CUP -- by fixed identity 0...2, not by table position --
    /// the ball started under. Chosen once, before any swap, and
    /// never touched again.
    let ballCupID: Int

    /// cupAtSlot[slot] = the identity of whichever cup currently sits
    /// in that visible table position. Begins as the identity
    /// permutation (cup 0 at slot 0, cup 1 at slot 1, cup 2 at slot
    /// 2) -- true both here and on screen before the first swap.
    private(set) var cupAtSlot: [Int]

    init(ballCupID: Int) {
        precondition((0..<3).contains(ballCupID), "ShellGame always has exactly 3 cups, indices 0...2")
        self.ballCupID = ballCupID
        self.cupAtSlot = [0, 1, 2]
    }

    /// The only way cupAtSlot ever changes: two cups actually trade
    /// places. A no-op (but harmless) if slotA == slotB or either
    /// index is out of range -- a stray call should never crash a
    /// live shuffle.
    mutating func swap(_ slotA: Int, _ slotB: Int) {
        guard cupAtSlot.indices.contains(slotA), cupAtSlot.indices.contains(slotB), slotA != slotB else { return }
        cupAtSlot.swapAt(slotA, slotB)
    }

    /// Derived every time from cupAtSlot, never cached or set
    /// directly -- "the ONE objectively correct cup based entirely on
    /// the swaps the player just watched." Force-unwrap is safe:
    /// cupAtSlot is always a permutation of 0...2 (init sets it, swap
    /// only ever exchanges two of its existing elements), and
    /// ballCupID is always one of those three values.
    var winningSlot: Int {
        cupAtSlot.firstIndex(of: ballCupID)!
    }
}

/// One step of a shuffle: which two table slots trade places, and how
/// long that swap's animation takes -- pacing lives right on the step
/// so ShellGameOverlay just plays the list back, it doesn't have to
/// re-derive "how far into the shuffle are we."
nonisolated struct ShellGameSwapStep: Equatable {
    let slotA: Int
    let slotB: Int
    let duration: TimeInterval
}

/// Builds the shuffle sequence -- separate from ShellGameRound itself
/// so the honesty-critical type above stays trivially small and has
/// nothing to do with pacing/randomness at all.
nonisolated enum ShellGameShuffle {
    /// Eddie: "something approximately in the neighborhood of 6-10
    /// swaps is probably sufficient for the first implementation."
    /// Each step picks two distinct random slots -- genuinely random,
    /// not just "looks random" -- and the CALLER (ShellGameViewModel)
    /// is what actually applies each step to the live ShellGameRound,
    /// one at a time, in order; this function only decides the plan.
    static func plan<G: RandomNumberGenerator>(swapCount: Int = 8, using rng: inout G) -> [ShellGameSwapStep] {
        guard swapCount > 0 else { return [] }
        var steps: [ShellGameSwapStep] = []
        steps.reserveCapacity(swapCount)
        for i in 0..<swapCount {
            let a = Int.random(in: 0..<3, using: &rng)
            var b = Int.random(in: 0..<3, using: &rng)
            while b == a { b = Int.random(in: 0..<3, using: &rng) }
            let progress = swapCount > 1 ? Double(i) / Double(swapCount - 1) : 1
            steps.append(ShellGameSwapStep(slotA: a, slotB: b, duration: duration(atProgress: progress)))
        }
        return steps
    }

    /// Slow (0.85s/swap) at the start, fast (0.16s/swap) by the end --
    /// Eddie: "start slowly enough that the player can genuinely
    /// follow... gradually increase the speed... by the end, it can
    /// become genuinely difficult to track." The "I've got it... I've
    /// got it... OH SHIT" acceleration is this one linear ramp.
    private static func duration(atProgress progress: Double) -> TimeInterval {
        let start = 0.85, end = 0.16
        return start + (end - start) * progress
    }
}
