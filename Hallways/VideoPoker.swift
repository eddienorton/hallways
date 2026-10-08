import Foundation

// Oct 7 -- VIDEO POKER (office computer), Jacks or Better.
// The game itself is the existing five-card draw machinery, reused unchanged:
// FiveCardDrawGame (deal five from a shuffled 52, toggle holds, one draw
// replaces every unheld card) and the general PokerHandEvaluator (category,
// with A-2-3-4-5 and 10-J-Q-K-A straights). This file is the Jacks-or-Better
// RESULT layer on top: royal split out of straight flush; a pair counts only
// if it is jacks, queens, kings or aces; anything less is no win.
// The familiar relative pay values are shown as a reference ladder only --
// no credits, bets, balance or payouts.

nonisolated enum VideoPokerHand: Int, CaseIterable, Equatable, Sendable {
    case nothing = 0
    case jacksOrBetter, twoPair, threeOfAKind, straight, flush, fullHouse, fourOfAKind, straightFlush, royalFlush

    /// The pay-table ladder, lowest win first.
    static let payTable: [VideoPokerHand] = [.jacksOrBetter, .twoPair, .threeOfAKind, .straight, .flush,
                                             .fullHouse, .fourOfAKind, .straightFlush, .royalFlush]

    static func of(_ hand: [PlayingCard]) -> VideoPokerHand {
        switch PokerHandEvaluator.evaluate(hand) {
        case .straightFlush:
            // Ten through ace of one suit (the ace-low straight flush,
            // A-2-3-4-5, has no king, so it is never royal).
            return Set(hand.map(\.rank)) == [.ten, .jack, .queen, .king, .ace] ? .royalFlush : .straightFlush
        case .fourOfAKind: return .fourOfAKind
        case .fullHouse: return .fullHouse
        case .flush: return .flush
        case .straight: return .straight
        case .threeOfAKind: return .threeOfAKind
        case .twoPair: return .twoPair
        case .onePair:
            let counts = Dictionary(grouping: hand, by: \.rank).mapValues(\.count)
            guard let paired = counts.first(where: { $0.value == 2 })?.key else { return .nothing }
            return paired.rawValue >= Rank.jack.rawValue ? .jacksOrBetter : .nothing   // ace = 14
        case .highCard: return .nothing
        }
    }

    var isWin: Bool { self != .nothing }

    /// The familiar relative value (reference only).
    var value: Int {
        switch self {
        case .nothing: return 0
        case .jacksOrBetter: return 1
        case .twoPair: return 2
        case .threeOfAKind: return 3
        case .straight: return 4
        case .flush: return 6
        case .fullHouse: return 9
        case .fourOfAKind: return 25
        case .straightFlush: return 50
        case .royalFlush: return 250
        }
    }

    /// The announcement.
    var name: String {
        switch self {
        case .nothing: return "NO WIN"
        case .jacksOrBetter: return "JACKS OR BETTER"
        case .twoPair: return "TWO PAIR"
        case .threeOfAKind: return "THREE OF A KIND"
        case .straight: return "STRAIGHT"
        case .flush: return "FLUSH"
        case .fullHouse: return "FULL HOUSE"
        case .fourOfAKind: return "FOUR OF A KIND"
        case .straightFlush: return "STRAIGHT FLUSH"
        case .royalFlush: return "ROYAL FLUSH"
        }
    }

    /// The pay-table ladder label.
    var shortName: String {
        switch self {
        case .nothing: return ""
        case .jacksOrBetter: return "JACKS+"
        case .twoPair: return "2 PAIR"
        case .threeOfAKind: return "3 KIND"
        case .straight: return "STRAIGHT"
        case .flush: return "FLUSH"
        case .fullHouse: return "FULL HSE"
        case .fourOfAKind: return "4 KIND"
        case .straightFlush: return "STR FLUSH"
        case .royalFlush: return "ROYAL"
        }
    }
}
