import Foundation

// Oct 7 -- SOLITAIRE (Klondike, draw one) for the office computer's Games.
// Pure rules only: no SwiftUI, no Hallways progression, no persistence.
// Cards reuse the shared PlayingCard / PlayingCardDeck model (PlayingCard.swift).

nonisolated struct SolitaireCard: Equatable, Identifiable, Sendable {
    let card: PlayingCard
    var faceUp: Bool
    var id: String { card.id }
}

nonisolated enum SolitairePile: Hashable, Sendable {
    case stock
    case waste
    case tableau(Int)
    case foundation(Int)
}

/// A picked-up card (or tableau run): `index` is where it starts in its pile.
nonisolated struct SolitaireSelection: Equatable, Sendable {
    let pile: SolitairePile
    let index: Int
}

nonisolated struct SolitaireGame: Equatable, Sendable {
    static let tableauCount = 7
    static let foundationCount = 4

    private(set) var stock: [SolitaireCard] = []          // last = top (face down)
    private(set) var waste: [SolitaireCard] = []          // last = top (face up)
    private(set) var tableau: [[SolitaireCard]] = Array(repeating: [], count: tableauCount)
    private(set) var foundations: [[SolitaireCard]] = Array(repeating: [], count: foundationCount)

    /// Standard deal: column i gets i + 1 cards, only the last face up; the
    /// remaining 24 form the stock.
    init<G: RandomNumberGenerator>(rng: inout G) {
        var deck = PlayingCardDeck(shuffledUsing: &rng).cards
        for column in 0..<Self.tableauCount {
            for row in 0...column {
                let card = deck.removeLast()
                tableau[column].append(SolitaireCard(card: card, faceUp: row == column))
            }
        }
        stock = deck.map { SolitaireCard(card: $0, faceUp: false) }
    }

    /// A fixed layout (tests).
    init(stock: [SolitaireCard], waste: [SolitaireCard], tableau: [[SolitaireCard]], foundations: [[SolitaireCard]]) {
        self.stock = stock
        self.waste = waste
        self.tableau = tableau
        self.foundations = foundations
    }

    // MARK: Card facts

    /// Ace low: A = 1 ... K = 13.
    static func value(_ rank: Rank) -> Int { rank == .ace ? 1 : rank.rawValue }
    static func isRed(_ suit: Suit) -> Bool { suit == .hearts || suit == .diamonds }

    var isWon: Bool { foundations.allSatisfy { $0.count == 13 } }

    func cards(in pile: SolitairePile) -> [SolitaireCard] {
        switch pile {
        case .stock: return stock
        case .waste: return waste
        case .tableau(let i): return tableau.indices.contains(i) ? tableau[i] : []
        case .foundation(let i): return foundations.indices.contains(i) ? foundations[i] : []
        }
    }

    /// The cards a selection would carry.
    func moving(_ selection: SolitaireSelection) -> [SolitaireCard] {
        let pile = cards(in: selection.pile)
        guard pile.indices.contains(selection.index) else { return [] }
        return Array(pile[selection.index...])
    }

    // MARK: Selecting

    /// Can the card at `index` of `pile` be picked up? Waste / foundation:
    /// only the top card. Tableau: any face-up card whose run down to the
    /// bottom alternates colour and descends by one.
    func canSelect(_ pile: SolitairePile, index: Int) -> Bool {
        let cards = cards(in: pile)
        guard cards.indices.contains(index), cards[index].faceUp else { return false }
        switch pile {
        case .stock: return false
        case .waste, .foundation: return index == cards.count - 1
        case .tableau: return Self.isRun(Array(cards[index...]))
        }
    }

    static func isRun(_ run: [SolitaireCard]) -> Bool {
        guard let first = run.first, first.faceUp else { return false }
        for (a, b) in zip(run, run.dropFirst()) {
            guard b.faceUp, isRed(a.card.suit) != isRed(b.card.suit),
                  value(b.card.rank) == value(a.card.rank) - 1 else { return false }
        }
        return true
    }

    // MARK: Moving

    func canMove(_ selection: SolitaireSelection, to destination: SolitairePile) -> Bool {
        guard selection.pile != destination, canSelect(selection.pile, index: selection.index) else { return false }
        let run = moving(selection)
        guard let first = run.first else { return false }
        switch destination {
        case .stock, .waste:
            return false
        case .foundation(let i):
            if case .foundation = selection.pile { return false }        // no shuffling between foundations
            guard run.count == 1, foundations.indices.contains(i) else { return false }
            guard let top = foundations[i].last else { return Self.value(first.card.rank) == 1 }
            return top.card.suit == first.card.suit && Self.value(first.card.rank) == Self.value(top.card.rank) + 1
        case .tableau(let i):
            guard tableau.indices.contains(i) else { return false }
            guard let top = tableau[i].last else { return first.card.rank == .king }
            return top.faceUp && Self.isRed(top.card.suit) != Self.isRed(first.card.suit)
                && Self.value(first.card.rank) == Self.value(top.card.rank) - 1
        }
    }

    /// Performs a legal move (false = illegal, nothing changed). A tableau
    /// card left face down on top is turned up.
    @discardableResult
    mutating func move(_ selection: SolitaireSelection, to destination: SolitairePile) -> Bool {
        guard canMove(selection, to: destination) else { return false }
        let run = moving(selection)
        switch selection.pile {
        case .waste: waste.removeLast(run.count)
        case .foundation(let i): foundations[i].removeLast(run.count)
        case .tableau(let i):
            tableau[i].removeLast(run.count)
            if let last = tableau[i].indices.last, !tableau[i][last].faceUp { tableau[i][last].faceUp = true }
        case .stock: return false
        }
        switch destination {
        case .foundation(let i): foundations[i].append(contentsOf: run)
        case .tableau(let i): tableau[i].append(contentsOf: run)
        case .stock, .waste: return false
        }
        return true
    }

    /// The foundation a single card can go to now, if any (its suit's pile,
    /// or the first empty pile for an ace).
    func foundationTarget(for selection: SolitaireSelection) -> Int? {
        guard moving(selection).count == 1 else { return nil }
        return foundations.indices.first { canMove(selection, to: .foundation($0)) }
    }

    // MARK: Stock (draw one)

    /// Tap on the stock: turn one card onto the waste; with the stock empty,
    /// turn the whole waste back over into a new stock (unlimited passes).
    /// False = nothing to do (both empty).
    @discardableResult
    mutating func tapStock() -> Bool {
        if var card = stock.popLast() {
            card.faceUp = true
            waste.append(card)
            return true
        }
        guard !waste.isEmpty else { return false }
        stock = waste.reversed().map { SolitaireCard(card: $0.card, faceUp: false) }
        waste = []
        return true
    }
}
