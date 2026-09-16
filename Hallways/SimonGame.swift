import Foundation

/// Floor 13's embedded mini-game -- SIMON / MEMORY ASSESSMENT (Eddie,
/// Sept 13), the seventh of these after Tic-Tac-Toe, the Shell Game,
/// Rock Paper Scissors, Higher/Lower, Five-Card Draw, and Whack-A-
/// Mole. Pure game STATE only, no SceneKit/SwiftUI, no timer/Task/RNG
/// of its own -- the SwiftUI overlay (SimonOverlay.swift) owns the
/// wall-clock playback-flash scheduling and calls into this struct
/// with plain, fully deterministic state transitions (start(sequence:),
/// startInputPhase(), tap(_:), reset()) that are all testable without
/// any real waiting.
///
/// Eddie: "Generate the sequence fairly/randomly. Do not rig the
/// sequence based on player performance." -- the whole 5-item
/// sequence is generated ONCE, up front (see SimonSequenceGenerator,
/// below), and never touched again; each round only grows how much of
/// that fixed sequence is being tested (currentRoundLength), exactly
/// like real Simon.
nonisolated struct SimonGame {
    enum Phase: Equatable {
        case ready
        /// The Building is flashing the sequence (read-only for the
        /// player -- SimonOverlay disables every quadrant button while
        /// phase == .playback).
        case playback
        /// Playback finished; the player is now expected to reproduce
        /// sequence[0..<currentRoundLength] one tap at a time.
        case input
        case success
        case failure
    }

    /// Eddie: "Complete a sequence length of 5 to pass Floor 13."
    static let targetLength = 5
    /// "A CIRCLE divided into exactly FOUR equal pie/quadrant pieces."
    static let quadrantCount = 4

    private(set) var phase: Phase = .ready
    /// The fixed, fully-generated 5-item sequence for this playthrough
    /// -- set once by start(sequence:), never mutated afterward.
    private(set) var sequence: [Int] = []
    /// How many items of `sequence` the current round tests (1...5).
    private(set) var currentRoundLength = 0
    /// How many of those items the player has correctly repeated so
    /// far THIS round -- reset to 0 at the start of every round's
    /// input phase.
    private(set) var inputIndex = 0

    /// Eddie: "The game must NOT begin automatically merely because
    /// the terminal activates" -- only reachable from .ready, and only
    /// with a properly-sized sequence (SimonOverlay always supplies
    /// exactly `targetLength` items via SimonSequenceGenerator).
    mutating func start(sequence: [Int]) {
        guard phase == .ready, sequence.count == Self.targetLength else { return }
        self.sequence = sequence
        currentRoundLength = 1
        inputIndex = 0
        phase = .playback
    }

    /// Called by the overlay once it has finished flashing
    /// sequence[0..<currentRoundLength] for this round. A no-op if the
    /// round already ended (e.g. the player somehow tapped through a
    /// stray callback before this fired) so a late playback-finished
    /// callback can never re-open input after success/failure.
    mutating func startInputPhase() {
        guard phase == .playback else { return }
        inputIndex = 0
        phase = .input
    }

    /// Eddie: classic Simon -- compare each tap immediately against
    /// the corresponding expected sequence item. Only accepted while
    /// phase == .input, so no scoring is possible during playback, or
    /// after success/failure has already fired.
    mutating func tap(_ quadrant: Int) {
        guard phase == .input, inputIndex < currentRoundLength else { return }
        guard sequence[inputIndex] == quadrant else {
            phase = .failure
            return
        }
        inputIndex += 1
        guard inputIndex == currentRoundLength else { return } // correct so far, round continues
        if currentRoundLength == Self.targetLength {
            phase = .success
        } else {
            // Eddie: "advance to next round -- replay the sequence from
            // the beginning with one additional item." The SAME fixed
            // `sequence` just gets one more item tested; nothing here
            // regenerates or reorders it.
            currentRoundLength += 1
            inputIndex = 0
            phase = .playback
        }
    }

    /// Eddie: "Tapping retry should reset cleanly to the READY / START
    /// state... No lives. No money penalty. No global state damage."
    mutating func reset() {
        phase = .ready
        sequence = []
        currentRoundLength = 0
        inputIndex = 0
    }
}

/// Eddie: "Generate the sequence fairly/randomly." A small, pure,
/// testable generator -- always returns exactly `targetLength` values,
/// each a valid 0..<4 quadrant identity. Consecutive repeats are legal
/// (real Simon behavior) and never filtered out.
nonisolated enum SimonSequenceGenerator {
    static func makeSequence<G: RandomNumberGenerator>(using rng: inout G) -> [Int] {
        (0..<SimonGame.targetLength).map { _ in Int.random(in: 0..<SimonGame.quadrantCount, using: &rng) }
    }
}
