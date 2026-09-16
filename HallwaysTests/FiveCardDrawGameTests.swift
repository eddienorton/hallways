import Testing
@testable import Hallways

/// Deal/hold/draw-once mechanics tests for Floor 11's Five-Card Draw.
/// See PokerHandEvaluatorTests.swift for hand-strength categorization
/// and FiveCardDrawTerminalTests.swift for the mission-completion/
/// elevator-lock integration.
struct FiveCardDrawGameTests {
    @Test func initialHandHasFiveUniqueCards() {
        var rng = SeededRNG(seed: 11)
        let game = FiveCardDrawGame(rng: &rng)
        #expect(game.hand.count == 5)
        #expect(Set(game.hand.map(\.id)).count == 5)
    }

    @Test func initialHeldStateIsAllFalse() {
        var rng = SeededRNG(seed: 12)
        let game = FiveCardDrawGame(rng: &rng)
        #expect(game.held == [false, false, false, false, false])
        #expect(!game.hasDrawn)
    }

    @Test func replacementCardsComeFromTheRemainingDeckNotDuplicatesOfTheHand() {
        var rng = SeededRNG(seed: 13)
        var game = FiveCardDrawGame(rng: &rng)
        let originalHandIDs = Set(game.hand.map(\.id))
        let remainingBeforeDraw = game.deck.remainingCount
        game.draw()
        // Every unheld card was replaced, so the deck shrank by exactly
        // the number of unheld slots (5, since nothing was held here).
        #expect(game.deck.remainingCount == remainingBeforeDraw - 5)
        // No replacement card can be one that was already in the
        // original hand -- it came from what was left of the same deck.
        #expect(Set(game.hand.map(\.id)).isDisjoint(with: originalHandIDs))
    }

    @Test func noDuplicateCardAppearsAcrossTheFinalHand() {
        var rng = SeededRNG(seed: 14)
        var game = FiveCardDrawGame(rng: &rng)
        game.toggleHold(at: 0)
        game.toggleHold(at: 2)
        game.draw()
        #expect(Set(game.hand.map(\.id)).count == 5)
    }

    @Test func heldCardsRemainUnchangedAfterDraw() {
        var rng = SeededRNG(seed: 15)
        var game = FiveCardDrawGame(rng: &rng)
        game.toggleHold(at: 1)
        game.toggleHold(at: 3)
        let heldCardsBefore = [game.hand[1], game.hand[3]]
        game.draw()
        #expect(game.hand[1] == heldCardsBefore[0])
        #expect(game.hand[3] == heldCardsBefore[1])
    }

    @Test func unheldCardsAreReplaced() {
        var rng = SeededRNG(seed: 16)
        var game = FiveCardDrawGame(rng: &rng)
        let originalHand = game.hand
        game.toggleHold(at: 1)
        game.toggleHold(at: 3)
        game.draw()
        #expect(game.hand[0] != originalHand[0])
        #expect(game.hand[2] != originalHand[2])
        #expect(game.hand[4] != originalHand[4])
    }

    @Test func holdingZeroCardsReplacesAllFive() {
        var rng = SeededRNG(seed: 17)
        var game = FiveCardDrawGame(rng: &rng)
        let originalHandIDs = Set(game.hand.map(\.id))
        game.draw()
        #expect(Set(game.hand.map(\.id)).isDisjoint(with: originalHandIDs))
    }

    @Test func holdingAllFiveCardsReplacesNone() {
        var rng = SeededRNG(seed: 18)
        var game = FiveCardDrawGame(rng: &rng)
        for index in 0..<5 { game.toggleHold(at: index) }
        let originalHand = game.hand
        game.draw()
        #expect(game.hand == originalHand)
        #expect(game.hasDrawn)
    }

    @Test func onlyOneDrawIsAllowedPerHand() {
        var rng = SeededRNG(seed: 19)
        var game = FiveCardDrawGame(rng: &rng)
        game.draw()
        let handAfterFirstDraw = game.hand
        let remainingAfterFirstDraw = game.deck.remainingCount
        game.draw() // second call must be a no-op
        #expect(game.hand == handAfterFirstDraw)
        #expect(game.deck.remainingCount == remainingAfterFirstDraw)
    }

    @Test func toggleHoldDoesNothingAfterTheDrawHasHappened() {
        var rng = SeededRNG(seed: 20)
        var game = FiveCardDrawGame(rng: &rng)
        game.draw()
        let handAfterDraw = game.hand
        game.toggleHold(at: 0)
        #expect(game.held[0] == false) // still untouched -- too late to hold
        #expect(game.hand == handAfterDraw)
    }

    @Test func aFreshGameNeverCarriesOverPriorHandState() {
        // Eddie: "Reset/new-game behavior should not accidentally
        // preserve incomplete hand state." Each FiveCardDrawGame
        // instance is its own clean slate -- confirmed by dealing two
        // independent games and checking neither's hasDrawn/held state
        // leaks into the other.
        var rngA = SeededRNG(seed: 21)
        var gameA = FiveCardDrawGame(rng: &rngA)
        gameA.toggleHold(at: 0)
        gameA.draw()

        var rngB = SeededRNG(seed: 22)
        let gameB = FiveCardDrawGame(rng: &rngB)
        #expect(!gameB.hasDrawn)
        #expect(gameB.held == [false, false, false, false, false])
    }
}
