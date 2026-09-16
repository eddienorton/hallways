import Foundation

/// Floor 11's hand-strength categories, worst to lowest raw value.
/// Eddie, Sept 13: "No need for complicated tie-breaking because
/// there is no opponent. We only need to identify the hand category."
/// A Royal Flush is simply classified as a straightFlush, per Eddie's
/// explicit "if that keeps implementation simpler."
nonisolated enum PokerHandCategory: Int, CaseIterable, Equatable, Sendable {
    case highCard
    case onePair
    case twoPair
    case threeOfAKind
    case straight
    case flush
    case fullHouse
    case fourOfAKind
    case straightFlush

    var displayName: String {
        switch self {
        case .highCard: return "HIGH CARD"
        case .onePair: return "ONE PAIR"
        case .twoPair: return "TWO PAIR"
        case .threeOfAKind: return "THREE OF A KIND"
        case .straight: return "STRAIGHT"
        case .flush: return "FLUSH"
        case .fullHouse: return "FULL HOUSE"
        case .fourOfAKind: return "FOUR OF A KIND"
        case .straightFlush: return "STRAIGHT FLUSH"
        }
    }

    /// Eddie: "PAIR OR BETTER passes the floor... High Card only =
    /// FAIL." The one rule Floor 11's mission gate actually needs.
    var qualifiesForFloor11: Bool { self != .highCard }
}

/// Pure hand-strength evaluator for Floor 11's Five-Card Draw -- no
/// SceneKit/SwiftUI, no opponent/betting concepts, just "what category
/// is this exact five-card hand." Reuses PlayingCard/Rank from Floor
/// 10 rather than a second card model.
nonisolated enum PokerHandEvaluator {
    static func evaluate(_ hand: [PlayingCard]) -> PokerHandCategory {
        precondition(hand.count == 5, "Five-card draw always evaluates exactly five cards")

        let ranks = hand.map(\.rank.rawValue).sorted()
        let rankCounts = Dictionary(grouping: hand, by: \.rank.rawValue).mapValues(\.count)
        let counts = rankCounts.values.sorted(by: >)
        let isFlush = Set(hand.map(\.suit)).count == 1
        let straight = isStraight(sortedRanks: ranks)

        if straight, isFlush { return .straightFlush }
        if counts == [4, 1] { return .fourOfAKind }
        if counts == [3, 2] { return .fullHouse }
        if isFlush { return .flush }
        if straight { return .straight }
        if counts == [3, 1, 1] { return .threeOfAKind }
        if counts == [2, 2, 1] { return .twoPair }
        if counts == [2, 1, 1, 1] { return .onePair }
        return .highCard
    }

    /// Eddie: "Ace high: 10 J Q K A must work. Ace low: A 2 3 4 5 must
    /// also work." Five distinct raw values spanning exactly 4 apart
    /// are necessarily consecutive (min, min+1, ... min+4) -- that
    /// single check covers every normal run, ace-high included, since
    /// Rank.ace's raw value (14) is already the top of the range. The
    /// ace-low wheel is the one legitimate exception, checked
    /// explicitly by its exact sorted-rank shape so a hand like
    /// K-A-2-3-4 (sorted [2, 3, 4, 13, 14], span 12) is correctly
    /// rejected as NOT a straight.
    private static func isStraight(sortedRanks: [Int]) -> Bool {
        guard Set(sortedRanks).count == 5 else { return false }
        if sortedRanks.last! - sortedRanks.first! == 4 { return true }
        if sortedRanks == [2, 3, 4, 5, 14] { return true } // A-2-3-4-5, ace playing low
        return false
    }
}
