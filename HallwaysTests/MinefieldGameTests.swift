import Foundation
import Testing
@testable import Hallways

/// Oct 7 -- Minefield (office computer) rules. Field: 5 x 9, 8 mines.
struct MinefieldGameTests {
    private func i(_ r: Int, _ c: Int) -> Int { MinefieldGame.index(row: r, column: c) }

    @Test func firstRevealLaysExactlyEightMinesAwayFromTheTapAndItsNeighbours() {
        for seed in UInt64(1)...200 {
            var rng = SeededRNG(seed: seed)
            var g = MinefieldGame()
            let tap = Int(seed % UInt64(MinefieldGame.cellCount))
            let outcome = g.reveal(tap, rng: &rng)
            #expect(g.mines.count == MinefieldGame.mineCount)
            #expect(!g.mines.contains(tap))
            #expect(MinefieldGame.neighbours(of: tap).allSatisfy { !g.mines.contains($0) })
            if case .boom = outcome { Issue.record("first tap exploded (seed \(seed))") }
            #expect(g.cells[tap] == .revealed)
            #expect(g.count(tap) == 0)                     // so the opening always floods
        }
    }

    @Test func neighbourCounts() {
        let g = MinefieldGame(mines: [i(0, 0), i(0, 2), i(1, 1)])
        #expect(g.count(i(0, 1)) == 3)
        #expect(g.count(i(1, 0)) == 2)
        #expect(g.count(i(2, 2)) == 1)
        #expect(g.count(i(4, 8)) == 0)
        #expect(MinefieldGame.neighbours(of: i(0, 0)).count == 3)
        #expect(MinefieldGame.neighbours(of: i(2, 4)).count == 8)
    }

    @Test func zeroRegionFloodsAndStopsAtNumbers() {
        var rng = SeededRNG(seed: 1)
        // One mine in the far corner: tapping the opposite corner opens everything else.
        var g = MinefieldGame(mines: [i(0, 0)])
        _ = g.reveal(i(4, 8), rng: &rng)
        #expect(g.phase == .won)
        #expect(g.cells.filter { $0 == .revealed }.count == MinefieldGame.cellCount - 1)
        // A number doesn't spread: a cell touching a mine opens alone.
        var h = MinefieldGame(mines: [i(0, 0), i(4, 8)])
        if case .opened(let cells) = h.reveal(i(1, 1), rng: &rng) { #expect(cells == [i(1, 1)]) } else { Issue.record("expected a single open") }
    }

    @Test func flagsToggleAndProtectTheCell() {
        var rng = SeededRNG(seed: 2)
        var g = MinefieldGame(mines: [i(0, 0)])
        let toggleFlag49 = g.toggleFlag(i(0, 0))
        #expect(toggleFlag49)
        #expect(g.cells[i(0, 0)] == .flagged)
        #expect(g.minesLeft == MinefieldGame.mineCount - 1)
        #expect(g.reveal(i(0, 0), rng: &rng) == .nothing)  // flagged: a tap can't reveal it
        #expect(g.phase == .playing)
        let toggleFlag54 = g.toggleFlag(i(0, 0))
        #expect(toggleFlag54)
        #expect(g.cells[i(0, 0)] == .hidden)
    }

    @Test func mineEndsTheRound() {
        var rng = SeededRNG(seed: 3)
        var g = MinefieldGame(mines: [i(2, 2)])
        #expect(g.reveal(i(2, 2), rng: &rng) == .boom(i(2, 2)))
        #expect(g.phase == .lost)
        #expect(g.exploded == i(2, 2))
        #expect(g.reveal(i(4, 8), rng: &rng) == .nothing)  // nothing more once lost
        let toggleFlag65 = g.toggleFlag(i(4, 8))
        #expect(!toggleFlag65)
    }

    @Test func winWhenEverySafeCellIsOpenFlagsOrNot() {
        var rng = SeededRNG(seed: 4)
        var g = MinefieldGame(mines: [i(0, 0), i(0, 8)])
        _ = g.reveal(i(4, 4), rng: &rng)
        #expect(g.phase == .won)
    }

    @Test func chordOpensTheRestWhenFlagsMatch() {
        var rng = SeededRNG(seed: 5)
        var g = MinefieldGame(mines: [i(0, 0), i(4, 8)])
        _ = g.reveal(i(1, 1), rng: &rng)                  // a "1"
        #expect(g.chord(i(1, 1)) == .nothing)             // flags don't match yet
        g.toggleFlag(i(0, 0))
        switch g.chord(i(1, 1)) {
        case .opened(let cells), .won(let cells): #expect(!cells.isEmpty)
        default: Issue.record("expected the chord to open cells")
        }
        #expect(g.cells[i(1, 2)] == .revealed && g.cells[i(0, 0)] == .flagged)
    }

    @Test func aFreshGameIsReadyAndBlank() {
        let g = MinefieldGame()
        #expect(g.phase == .ready)
        #expect(g.mines.isEmpty)
        #expect(g.cells.allSatisfy { $0 == .hidden })
        #expect(g.minesLeft == MinefieldGame.mineCount)
    }
}
