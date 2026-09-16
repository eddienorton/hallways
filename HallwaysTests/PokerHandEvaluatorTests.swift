import Testing
@testable import Hallways

/// Pure hand-strength tests for Floor 11's Five-Card Draw -- every
/// category, both legitimate straight shapes (ace-high and ace-low),
/// and a couple of "looks like a straight but isn't" traps. See
/// FiveCardDrawGameTests.swift for the deal/hold/draw mechanics that
/// produce the hands this evaluates.
struct PokerHandEvaluatorTests {
    private func card(_ rank: Rank, _ suit: Suit) -> PlayingCard {
        PlayingCard(rank: rank, suit: suit)
    }

    @Test func highCardWithNoPairsOrRunOrFlush() {
        let hand = [card(.two, .spades), card(.four, .hearts), card(.seven, .diamonds),
                    card(.nine, .clubs), card(.jack, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .highCard)
    }

    @Test func onePairIsDetected() {
        let hand = [card(.two, .spades), card(.two, .hearts), card(.seven, .diamonds),
                    card(.nine, .clubs), card(.jack, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .onePair)
    }

    @Test func twoPairIsDetected() {
        let hand = [card(.two, .spades), card(.two, .hearts), card(.seven, .diamonds),
                    card(.seven, .clubs), card(.jack, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .twoPair)
    }

    @Test func threeOfAKindIsDetected() {
        let hand = [card(.two, .spades), card(.two, .hearts), card(.two, .diamonds),
                    card(.nine, .clubs), card(.jack, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .threeOfAKind)
    }

    @Test func straightWithMixedSuitsIsDetected() {
        let hand = [card(.three, .spades), card(.four, .hearts), card(.five, .diamonds),
                    card(.six, .clubs), card(.seven, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .straight)
    }

    @Test func flushWithNonConsecutiveRanksIsDetected() {
        let hand = [card(.two, .spades), card(.five, .spades), card(.seven, .spades),
                    card(.nine, .spades), card(.jack, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .flush)
    }

    @Test func fullHouseIsDetected() {
        let hand = [card(.two, .spades), card(.two, .hearts), card(.two, .diamonds),
                    card(.nine, .clubs), card(.nine, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .fullHouse)
    }

    @Test func fourOfAKindIsDetected() {
        let hand = [card(.two, .spades), card(.two, .hearts), card(.two, .diamonds),
                    card(.two, .clubs), card(.nine, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .fourOfAKind)
    }

    @Test func straightFlushIsDetected() {
        let hand = [card(.three, .spades), card(.four, .spades), card(.five, .spades),
                    card(.six, .spades), card(.seven, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .straightFlush)
    }

    @Test func aceLowWheelStraightWorks() {
        // A-2-3-4-5, ace playing low -- mixed suits so it's a straight, not a straight flush.
        let hand = [card(.ace, .spades), card(.two, .hearts), card(.three, .diamonds),
                    card(.four, .clubs), card(.five, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .straight)
    }

    @Test func aceHighStraightWorks() {
        // 10-J-Q-K-A, ace playing high -- mixed suits.
        let hand = [card(.ten, .spades), card(.jack, .hearts), card(.queen, .diamonds),
                    card(.king, .clubs), card(.ace, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .straight)
    }

    @Test func royalFlushIsClassifiedAsStraightFlush() {
        // Eddie: "Royal Flush can simply be classified as Straight
        // Flush if that keeps implementation simpler." -- same suit,
        // 10 through Ace.
        let hand = [card(.ten, .hearts), card(.jack, .hearts), card(.queen, .hearts),
                    card(.king, .hearts), card(.ace, .hearts)]
        #expect(PokerHandEvaluator.evaluate(hand) == .straightFlush)
    }

    @Test func kingAceTwoThreeFourIsNotAFalseStraight() {
        // A wraparound like K-A-2-3-4 must NOT qualify as a straight --
        // ace is either high (10-J-Q-K-A) or low (A-2-3-4-5), never a
        // bridge between the two ends.
        let hand = [card(.king, .spades), card(.ace, .hearts), card(.two, .diamonds),
                    card(.three, .clubs), card(.four, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .highCard)
    }

    @Test func queenKingAceTwoThreeIsNotAFalseStraight() {
        // Another near-wraparound shape that must fail too.
        let hand = [card(.queen, .spades), card(.king, .hearts), card(.ace, .diamonds),
                    card(.two, .clubs), card(.three, .spades)]
        #expect(PokerHandEvaluator.evaluate(hand) == .highCard)
    }

    @Test func onlyOnePairOrBetterQualifiesForFloor11() {
        #expect(!PokerHandCategory.highCard.qualifiesForFloor11)
        for category in PokerHandCategory.allCases where category != .highCard {
            #expect(category.qualifiesForFloor11)
        }
    }

    @Test func categoriesAreOrderedWorstToBestByRawValue() {
        let ordered = PokerHandCategory.allCases
        #expect(ordered == [.highCard, .onePair, .twoPair, .threeOfAKind, .straight,
                             .flush, .fullHouse, .fourOfAKind, .straightFlush])
    }
}
