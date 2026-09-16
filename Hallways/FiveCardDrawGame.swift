import Foundation

/// Floor 11's embedded mini-game -- FIVE-CARD DRAW, ONE HAND ONLY
/// (Eddie, Sept 13), the fifth of these after Tic-Tac-Toe, the Shell
/// Game, Rock Paper Scissors, and Higher/Lower. Pure game logic only,
/// no SceneKit/SwiftUI -- same shape as
/// ShellGame.swift/RockPaperScissors.swift/HigherLowerGame.swift, its
/// own file, not a shared mini-game framework. Reuses
/// PlayingCard/PlayingCardDeck from Floor 10 rather than a second
/// card model, and PokerHandEvaluator for hand strength -- this file
/// only owns the deal/hold/draw-once mechanics.
///
/// Eddie: "No opponent. No betting... Do not manipulate the draw
/// based on which cards player held. The game is real." draw()
/// simply pulls each unheld slot's replacement off the same shuffled
/// deck, in deck order -- nothing here ever looks at what a discarded
/// card was before choosing its replacement.
nonisolated struct FiveCardDrawGame {
    private(set) var deck: PlayingCardDeck
    private(set) var hand: [PlayingCard]
    private(set) var held: [Bool]
    private(set) var hasDrawn = false

    /// Deals a fresh five-card hand off a newly shuffled standard
    /// 52-card deck -- always enough cards for the deal (5) and every
    /// possible replacement (up to 5 more), so nothing here ever needs
    /// to reshuffle mid-hand the way Floor 10's long-running streak
    /// occasionally does.
    init<G: RandomNumberGenerator>(rng: inout G) {
        var freshDeck = PlayingCardDeck(shuffledUsing: &rng)
        hand = (0..<5).map { _ in freshDeck.draw()! }
        held = Array(repeating: false, count: 5)
        deck = freshDeck
    }

    var category: PokerHandCategory { PokerHandEvaluator.evaluate(hand) }
    var qualifies: Bool { category.qualifiesForFloor11 }

    /// Eddie: "The player may hold: none, one, several, all five."
    /// Only meaningful before the one draw -- the "ONE draw only"
    /// rule is enforced here, in the model, not just by hiding a
    /// button in the overlay.
    mutating func toggleHold(at index: Int) {
        guard !hasDrawn, hand.indices.contains(index) else { return }
        held[index].toggle()
    }

    /// Eddie: "Every unheld card is discarded and replaced from the
    /// SAME remaining deck... If all five are held and player presses
    /// DRAW, evaluate that same hand." A second call is a no-op --
    /// exactly one draw per hand, matching hasDrawn's own name.
    mutating func draw() {
        guard !hasDrawn else { return }
        hasDrawn = true
        for index in hand.indices where !held[index] {
            guard let next = deck.draw() else { continue } // unreachable: 47+ cards always remain
            hand[index] = next
        }
    }
}
