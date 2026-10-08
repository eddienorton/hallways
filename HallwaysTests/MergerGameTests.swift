import Foundation
import Testing
@testable import Hallways

/// Oct 7 -- Merger (office computer number-merging game) rules.
struct MergerGameTests {
    /// Moves without spawning noise: compare boards ignoring the one new tile.
    private func moved(_ values: [[Int]], _ d: MergerDirection) -> (grid: [[Int]], move: MergerMove, game: MergerGame) {
        var g = MergerGame(values: values)
        var rng = SeededRNG(seed: 1)
        let m = g.move(d, rng: &rng)
        var grid = g.grid
        if let s = m.spawned { grid[s.row][s.column] = 0 }
        return (grid, m, g)
    }

    @Test func equalNeighboursMergeAndScore() {
        let r = moved([[2, 2, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], .left)
        #expect(r.grid[0] == [4, 0, 0, 0])
        #expect(r.move.merges == [4])
        #expect(r.game.score == 4)
    }

    @Test func aTileMergesAtMostOncePerMove() {
        #expect(moved([[2, 2, 2, 2], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], .left).grid[0] == [4, 4, 0, 0])
        #expect(moved([[2, 2, 2, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], .left).grid[0] == [4, 2, 0, 0])
        #expect(moved([[2, 2, 2, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], .right).grid[0] == [0, 0, 2, 4])
        #expect(moved([[4, 4, 8, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], .left).grid[0] == [8, 8, 0, 0])   // the new 8 doesn't merge again
    }

    @Test func slidingWithoutMerging() {
        let r = moved([[0, 2, 0, 4], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], .left)
        #expect(r.grid[0] == [2, 4, 0, 0])
        #expect(r.move.moved && r.move.merges.isEmpty)
        let up = moved([[0, 0, 0, 0], [0, 0, 0, 0], [8, 0, 0, 0], [8, 0, 0, 2]], .up)
        #expect(up.grid.map { $0[0] } == [16, 0, 0, 0])
        #expect(up.grid[0][3] == 2)
    }

    @Test func aMoveThatChangesNothingDoesNothingAndSpawnsNothing() {
        var g = MergerGame(values: [[2, 4, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]])
        var rng = SeededRNG(seed: 2)
        let m = g.move(.left, rng: &rng)
        #expect(!m.moved && m.spawned == nil)
        #expect(g.tiles.count == 2 && g.moves == 0)
    }

    @Test func everyRealMoveSpawnsOneTwoOrFourInAnEmptyCell() {
        var fours = 0
        for seed in UInt64(1)...300 {
            var g = MergerGame(values: [[2, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]])
            var rng = SeededRNG(seed: seed)
            let m = g.move(.right, rng: &rng)
            guard let s = m.spawned else { Issue.record("no spawn"); continue }
            #expect(s.value == 2 || s.value == 4)
            #expect(!(s.row == 0 && s.column == 3))           // not on the moved tile
            #expect(g.tiles.count == 2)
            if s.value == 4 { fours += 1 }
        }
        #expect(fours > 5 && fours < 80)                      // about 1 in 10
        var rng = SeededRNG(seed: 9)
        let fresh = MergerGame(rng: &rng)
        #expect(fresh.tiles.count == 2)
    }

    @Test func fullBoardWithNoMatchesIsOver() {
        let stuck = MergerGame(values: [[2, 4, 2, 4], [4, 2, 4, 2], [2, 4, 2, 4], [4, 2, 4, 2]])
        #expect(stuck.isOver)
        let full = MergerGame(values: [[2, 4, 2, 4], [4, 2, 4, 2], [2, 4, 2, 4], [4, 2, 4, 4]])
        #expect(!full.isOver)                                 // one pair left to merge
        let vertical = MergerGame(values: [[2, 4, 2, 4], [4, 2, 4, 2], [2, 4, 2, 8], [4, 2, 4, 8]])
        #expect(!vertical.isOver)
    }

    @Test func highestTileAndScoreAccumulate() {
        var g = MergerGame(values: [[64, 64, 0, 0], [32, 32, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]])
        var rng = SeededRNG(seed: 3)
        let m = g.move(.left, rng: &rng)
        #expect(Set(m.merges) == [128, 64])
        #expect(g.score == 192)
        #expect(g.highestTile == 128)
        #expect(m.grown.count == 2)
    }
}
