import Foundation
import Testing
@testable import Hallways

/// Oct 7 -- the office computer's Video Poker (Jacks or Better) result layer, on top of the
/// shared PokerHandEvaluator. Fixtures cover every category, with the
/// classic traps: ace-low and ace-high straights, flush vs straight flush,
/// royal vs straight flush, full house vs trips, two pair vs jacks-or-better,
/// and a pair of tens being no win.
struct VideoPokerHandTests {
    private func h(_ cards: (Rank, Suit)...) -> [PlayingCard] { cards.map { PlayingCard(rank: $0.0, suit: $0.1) } }

    @Test func royalFlush() {
        #expect(VideoPokerHand.of(h((.ace, .spades), (.king, .spades), (.queen, .spades), (.jack, .spades), (.ten, .spades))) == .royalFlush)
    }
    @Test func straightFlushIncludingAceLow() {
        #expect(VideoPokerHand.of(h((.nine, .hearts), (.king, .hearts), (.queen, .hearts), (.jack, .hearts), (.ten, .hearts))) == .straightFlush)
        #expect(VideoPokerHand.of(h((.ace, .clubs), (.two, .clubs), (.three, .clubs), (.four, .clubs), (.five, .clubs))) == .straightFlush)
    }
    @Test func fourOfAKind() {
        #expect(VideoPokerHand.of(h((.seven, .spades), (.seven, .hearts), (.seven, .diamonds), (.seven, .clubs), (.two, .spades))) == .fourOfAKind)
    }
    @Test func fullHouseNotTrips() {
        #expect(VideoPokerHand.of(h((.queen, .spades), (.queen, .hearts), (.queen, .clubs), (.four, .diamonds), (.four, .clubs))) == .fullHouse)
        #expect(VideoPokerHand.of(h((.queen, .spades), (.queen, .hearts), (.queen, .clubs), (.four, .diamonds), (.nine, .clubs))) == .threeOfAKind)
    }
    @Test func flushNotStraightFlush() {
        #expect(VideoPokerHand.of(h((.two, .diamonds), (.seven, .diamonds), (.nine, .diamonds), (.jack, .diamonds), (.king, .diamonds))) == .flush)
    }
    @Test func straightsAceHighAndAceLow() {
        #expect(VideoPokerHand.of(h((.ace, .spades), (.king, .hearts), (.queen, .clubs), (.jack, .diamonds), (.ten, .spades))) == .straight)
        #expect(VideoPokerHand.of(h((.ace, .spades), (.two, .hearts), (.three, .clubs), (.four, .diamonds), (.five, .spades))) == .straight)
        // No wrap-around: Q-K-A-2-3 is not a straight.
        #expect(VideoPokerHand.of(h((.queen, .spades), (.king, .hearts), (.ace, .clubs), (.two, .diamonds), (.three, .spades))) == .nothing)
    }
    @Test func twoPairVsJacksOrBetterVsNothing() {
        #expect(VideoPokerHand.of(h((.eight, .spades), (.eight, .hearts), (.three, .clubs), (.three, .diamonds), (.king, .spades))) == .twoPair)
        #expect(VideoPokerHand.of(h((.jack, .spades), (.jack, .hearts), (.three, .clubs), (.five, .diamonds), (.king, .spades))) == .jacksOrBetter)
        #expect(VideoPokerHand.of(h((.ace, .spades), (.ace, .hearts), (.three, .clubs), (.five, .diamonds), (.king, .spades))) == .jacksOrBetter)
        // Tens or lower: no win.
        #expect(VideoPokerHand.of(h((.ten, .spades), (.ten, .hearts), (.three, .clubs), (.five, .diamonds), (.king, .spades))) == .nothing)
        #expect(VideoPokerHand.of(h((.eight, .spades), (.jack, .hearts), (.three, .clubs), (.five, .diamonds), (.king, .spades))) == .nothing)
    }
    @Test func ladderNamesAndValues() {
        #expect(VideoPokerHand.payTable.map(\.value) == [1, 2, 3, 4, 6, 9, 25, 50, 250])
        #expect(VideoPokerHand.jacksOrBetter.name == "JACKS OR BETTER")
        #expect(VideoPokerHand.royalFlush.name == "ROYAL FLUSH")
        #expect(!VideoPokerHand.nothing.isWin && VideoPokerHand.jacksOrBetter.isWin)
    }
}
