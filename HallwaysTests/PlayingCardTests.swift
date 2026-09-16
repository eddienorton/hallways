import Testing
@testable import Hallways

/// Deck-construction/fairness tests for Floor 10's PlayingCard/
/// PlayingCardDeck -- see HigherLowerGameTests.swift for the pure
/// Higher/Lower outcome logic that consumes these types.
struct PlayingCardTests {
    @Test func standardDeckHasExactlyFiftyTwoCards() {
        #expect(PlayingCardDeck.standard52().count == 52)
    }

    @Test func standardDeckHasExactlyFourSuits() {
        let suits = Set(PlayingCardDeck.standard52().map(\.suit))
        #expect(suits.count == 4)
        #expect(suits == Set(Suit.allCases))
    }

    @Test func standardDeckHasExactlyThirteenRanks() {
        let ranks = Set(PlayingCardDeck.standard52().map(\.rank))
        #expect(ranks.count == 13)
        #expect(ranks == Set(Rank.allCases))
    }

    @Test func everyCardInTheStandardDeckIsUnique() {
        let cards = PlayingCardDeck.standard52()
        #expect(Set(cards.map(\.id)).count == cards.count)
    }

    @Test func shuffledDeckIsStillAFullStandardFiftyTwo() {
        var rng = SeededRNG(seed: 7)
        let deck = PlayingCardDeck(shuffledUsing: &rng)
        #expect(deck.remainingCount == 52)
        #expect(Set(deck.cards.map(\.id)) == Set(PlayingCardDeck.standard52().map(\.id)))
    }

    @Test func drawingRemovesCardsFromTheRemainingDeck() {
        var rng = SeededRNG(seed: 42)
        var deck = PlayingCardDeck(shuffledUsing: &rng)
        let first = deck.draw()
        #expect(first != nil)
        #expect(deck.remainingCount == 51)
        #expect(!deck.cards.contains(where: { $0.id == first!.id }))
    }

    @Test func drawingAllFiftyTwoCardsProducesNoDuplicatesAndThenNil() {
        var rng = SeededRNG(seed: 99)
        var deck = PlayingCardDeck(shuffledUsing: &rng)
        var drawn: [PlayingCard] = []
        while let card = deck.draw() {
            drawn.append(card)
        }
        #expect(drawn.count == 52)
        #expect(Set(drawn.map(\.id)).count == 52)
        #expect(deck.isEmpty)
        #expect(deck.draw() == nil)
    }

    @Test func displayNamesForFaceCardsAndAceAreLettersNotNumbers() {
        #expect(Rank.jack.displayName == "J")
        #expect(Rank.queen.displayName == "Q")
        #expect(Rank.king.displayName == "K")
        #expect(Rank.ace.displayName == "A")
        #expect(Rank.two.displayName == "2")
        #expect(Rank.ten.displayName == "10")
    }

    @Test func aceIsTheHighestRawValue() {
        #expect(Rank.ace.rawValue > Rank.king.rawValue)
        #expect(Rank.allCases.map(\.rawValue).max() == Rank.ace.rawValue)
    }
}
