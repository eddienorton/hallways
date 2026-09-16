import Foundation

/// The small amount of playing-card infrastructure Floor 10's
/// Higher/Lower actually needs (Eddie, Sept 13) -- a standard 52-card
/// deck, no jokers, no casino framework. Pure model only, no
/// SceneKit/SwiftUI; see PlayingCardView.swift for the reusable
/// SwiftUI rendering, kept in its own file on purpose so this one
/// stays presentation-free.
nonisolated enum Suit: String, CaseIterable, Codable, Sendable {
    case spades, hearts, diamonds, clubs

    var symbol: String {
        switch self {
        case .spades: return "\u{2660}"
        case .hearts: return "\u{2665}"
        case .diamonds: return "\u{2666}"
        case .clubs: return "\u{2663}"
        }
    }
}

/// Raw value is the card's ordering weight for Higher/Lower -- Eddie:
/// "2 < 3 < ... < K < A. ACE IS HIGH." No Comparable conformance is
/// declared; HigherLowerGame compares rawValue directly (see its own
/// doc comment) rather than relying on synthesis that doesn't exist
/// for this anyway.
nonisolated enum Rank: Int, CaseIterable, Codable, Sendable {
    case two = 2, three, four, five, six, seven, eight, nine, ten
    case jack = 11, queen, king, ace

    var displayName: String {
        switch self {
        case .jack: return "J"
        case .queen: return "Q"
        case .king: return "K"
        case .ace: return "A"
        default: return String(rawValue)
        }
    }
}

nonisolated struct PlayingCard: Equatable, Sendable, Identifiable {
    let rank: Rank
    let suit: Suit

    var id: String { "\(rank.rawValue)-\(suit.rawValue)" }
    var displayName: String { "\(rank.displayName)\(suit.symbol)" }
}

/// A standard 52-card deck (13 ranks x 4 suits), no jokers. Cards come
/// off the top honestly via draw() -- nothing here lets a caller peek
/// ahead or put a card back where it would change an outcome.
nonisolated struct PlayingCardDeck {
    private(set) var cards: [PlayingCard]

    /// A fresh, unshuffled standard deck -- every rank of every suit,
    /// exactly once.
    static func standard52() -> [PlayingCard] {
        Suit.allCases.flatMap { suit in Rank.allCases.map { PlayingCard(rank: $0, suit: suit) } }
    }

    init<G: RandomNumberGenerator>(shuffledUsing rng: inout G) {
        cards = Self.standard52().shuffled(using: &rng)
    }

    /// For tests -- an explicit, already-ordered set of cards rather
    /// than a shuffled standard deck.
    init(cards: [PlayingCard]) {
        self.cards = cards
    }

    var isEmpty: Bool { cards.isEmpty }
    var remainingCount: Int { cards.count }

    /// Removes and returns the top card, or nil if the deck is empty.
    @discardableResult
    mutating func draw() -> PlayingCard? {
        guard !cards.isEmpty else { return nil }
        return cards.removeFirst()
    }
}
