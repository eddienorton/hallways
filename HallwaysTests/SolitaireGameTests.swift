import Foundation
import Testing
@testable import Hallways

/// Oct 7 -- pure rules tests for the office computer's Solitaire
/// (Klondike, draw one). The same scenarios were run against a standalone
/// Python mirror of SolitaireGame before being transcribed here.
struct SolitaireGameTests {
    private func c(_ rank: Rank, _ suit: Suit, up: Bool = true) -> SolitaireCard {
        SolitaireCard(card: PlayingCard(rank: rank, suit: suit), faceUp: up)
    }
    private func empty7() -> [[SolitaireCard]] { Array(repeating: [], count: 7) }
    private func empty4() -> [[SolitaireCard]] { Array(repeating: [], count: 4) }

    @Test func initialDealIsSevenColumnsTwentyEightCardsTwentyFourStock() {
        var rng = SeededRNG(seed: 42)
        let game = SolitaireGame(rng: &rng)
        #expect(game.tableau.map(\.count) == [1, 2, 3, 4, 5, 6, 7])
        for column in game.tableau {
            #expect(column.last?.faceUp == true)
            #expect(column.dropLast().allSatisfy { !$0.faceUp })
        }
        #expect(game.stock.count == 24)
        #expect(game.stock.allSatisfy { !$0.faceUp })
        #expect(game.waste.isEmpty)
        let all = game.stock.map(\.id) + game.tableau.flatMap { $0.map(\.id) }
        #expect(Set(all).count == 52)
    }

    @Test func stockDealsOneThenRecyclesWasteInOrder() {
        var game = SolitaireGame(stock: [c(.two, .clubs, up: false), c(.three, .hearts, up: false)],
                                 waste: [], tableau: empty7(), foundations: empty4())
        let tapStock33 = game.tapStock()
        #expect(tapStock33)
        #expect(game.waste.map(\.card.rank) == [.three])
        #expect(game.waste.last?.faceUp == true)
        let tapStock36 = game.tapStock()
        #expect(tapStock36)
        #expect(game.waste.map(\.card.rank) == [.three, .two])
        #expect(game.stock.isEmpty)
        let tapStock39 = game.tapStock()
        #expect(tapStock39)                                   // recycle
        #expect(game.waste.isEmpty)
        #expect(game.stock.count == 2 && game.stock.allSatisfy { !$0.faceUp })
        let tapStock42 = game.tapStock()
        #expect(tapStock42)                                   // same order again
        #expect(game.waste.map(\.card.rank) == [.three])
        var empty = SolitaireGame(stock: [], waste: [], tableau: empty7(), foundations: empty4())
        let tapStock45 = empty.tapStock()
        #expect(!tapStock45)
    }

    @Test func singleAndRunTableauMovesAndReveal() {
        var t = empty7()
        t[0] = [c(.nine, .clubs, up: false), c(.eight, .hearts), c(.seven, .spades)]
        t[1] = [c(.nine, .spades)]
        var game = SolitaireGame(stock: [], waste: [], tableau: t, foundations: empty4())
        // 8H-7S run onto 9S.
        #expect(game.canSelect(.tableau(0), index: 1))
        #expect(!game.canSelect(.tableau(0), index: 0))           // face down
        let move56 = game.move(SolitaireSelection(pile: .tableau(0), index: 1), to: .tableau(1))
        #expect(move56)
        #expect(game.tableau[1].map(\.card.rank) == [.nine, .eight, .seven])
        #expect(game.tableau[0].count == 1 && game.tableau[0][0].faceUp)   // revealed
        // Illegal: same colour.
        #expect(!game.canMove(SolitaireSelection(pile: .tableau(0), index: 0), to: .tableau(1)))
    }

    @Test func kingOnlyToEmptyColumn() {
        var t = empty7()
        t[0] = [c(.king, .hearts)]
        t[1] = [c(.queen, .spades)]
        var game = SolitaireGame(stock: [], waste: [], tableau: t, foundations: empty4())
        #expect(!game.canMove(SolitaireSelection(pile: .tableau(1), index: 0), to: .tableau(2)))
        let move69 = game.move(SolitaireSelection(pile: .tableau(0), index: 0), to: .tableau(2))
        #expect(move69)
        #expect(game.tableau[2].first?.card.rank == .king)
    }

    @Test func foundationsBuildUpBySuitFromAce() {
        var game = SolitaireGame(stock: [], waste: [c(.two, .hearts), c(.ace, .hearts)],
                                 tableau: empty7(), foundations: empty4())
        let top = SolitaireSelection(pile: .waste, index: 1)
        #expect(game.foundationTarget(for: top) == 0)
        let move78 = game.move(top, to: .foundation(0))
        #expect(move78)
        let two = SolitaireSelection(pile: .waste, index: 0)
        #expect(!game.canMove(two, to: .foundation(1)))           // empty pile needs an ace
        let move81 = game.move(two, to: .foundation(0))
        #expect(move81)
        #expect(game.foundations[0].count == 2)
        // No foundation-to-foundation shuffling.
        #expect(!game.canMove(SolitaireSelection(pile: .foundation(0), index: 1), to: .foundation(1)))
    }

    @Test func onlyTheTopCardGoesToAFoundation() {
        var t = empty7()
        t[0] = [c(.two, .spades), c(.ace, .hearts)]
        var f = empty4()
        f[0] = [c(.ace, .spades)]
        let game = SolitaireGame(stock: [], waste: [], tableau: t, foundations: f)
        #expect(game.canSelect(.tableau(0), index: 0))            // 2S-AH is a valid run to pick up...
        #expect(!game.canMove(SolitaireSelection(pile: .tableau(0), index: 0), to: .foundation(0)))   // ...but two cards can't go home
        #expect(game.canMove(SolitaireSelection(pile: .tableau(0), index: 1), to: .foundation(1)))    // the ace alone can
    }

    @Test func winDetection() {
        let suits: [Suit] = [.spades, .hearts, .diamonds, .clubs]
        let full = suits.map { suit in Rank.allCases.map { c($0, suit) } }
        let game = SolitaireGame(stock: [], waste: [], tableau: empty7(), foundations: full)
        #expect(game.isWon)
        let notYet = SolitaireGame(stock: [], waste: [], tableau: empty7(), foundations: empty4())
        #expect(!notYet.isWon)
    }
}
