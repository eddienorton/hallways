import Foundation

// Oct 7 -- MERGER (office computer): the number-merging game.
// Pure rules -- no SwiftUI, no persistence.
//
// A 4 x 4 board. Every move slides ALL tiles as far as they go in one
// direction; two equal tiles that meet become one tile of double the value
// (each tile merges at most once per move). After any move that changes the
// board a new tile appears in a random empty cell: a 2, or (1 in 10) a 4.
// The run ends when the board is full and no two neighbours match.
// Score: the value of every tile a merge creates (the familiar rule).

nonisolated struct MergerTile: Identifiable, Equatable, Sendable {
    let id: Int
    var value: Int
    var row: Int
    var column: Int
}

nonisolated enum MergerDirection: CaseIterable, Sendable { case up, down, left, right }

nonisolated struct MergerMove: Equatable, Sendable {
    var moved = false
    /// Values created by merges this move (e.g. [8, 4]).
    var merges: [Int] = []
    /// Ids of the tiles that grew this move (for the pop).
    var grown: [Int] = []
    var spawned: MergerTile?
}

nonisolated struct MergerGame: Equatable, Sendable {
    static let size = 4
    static let fourChance = 0.1

    private(set) var tiles: [MergerTile] = []
    private(set) var score = 0
    private(set) var moves = 0
    private var nextID = 0

    init<G: RandomNumberGenerator>(rng: inout G) {
        spawn(rng: &rng)
        spawn(rng: &rng)
    }

    /// A fixed board (tests).
    init(values: [[Int]]) {
        for (r, row) in values.enumerated() {
            for (c, v) in row.enumerated() where v > 0 {
                tiles.append(MergerTile(id: nextID, value: v, row: r, column: c))
                nextID += 1
            }
        }
    }

    // MARK: Reading the board

    func tile(row: Int, column: Int) -> MergerTile? { tiles.first { $0.row == row && $0.column == column } }

    /// The board as values (0 = empty), row by row.
    var grid: [[Int]] {
        var g = Array(repeating: Array(repeating: 0, count: Self.size), count: Self.size)
        for t in tiles { g[t.row][t.column] = t.value }
        return g
    }

    var emptyCells: [(row: Int, column: Int)] {
        let g = grid
        var out: [(Int, Int)] = []
        for r in 0..<Self.size { for c in 0..<Self.size where g[r][c] == 0 { out.append((r, c)) } }
        return out
    }

    var highestTile: Int { tiles.map(\.value).max() ?? 0 }

    /// Any legal move left?
    var canMove: Bool {
        if !emptyCells.isEmpty { return true }
        let g = grid
        for r in 0..<Self.size {
            for c in 0..<Self.size {
                if c + 1 < Self.size, g[r][c] == g[r][c + 1] { return true }
                if r + 1 < Self.size, g[r][c] == g[r + 1][c] { return true }
            }
        }
        return false
    }

    var isOver: Bool { !canMove }

    // MARK: Moving

    /// Slide everything one way. Nothing happens (and nothing spawns) if no
    /// tile can move or merge that way.
    mutating func move<G: RandomNumberGenerator>(_ direction: MergerDirection, rng: inout G) -> MergerMove {
        var result = MergerMove()
        var survivors: [MergerTile] = []
        for line in 0..<Self.size {
            // The tiles of this row/column, nearest the leading edge first.
            let lineTiles = tiles.filter { direction == .left || direction == .right ? $0.row == line : $0.column == line }
                .sorted { a, b in
                    switch direction {
                    case .left: return a.column < b.column
                    case .right: return a.column > b.column
                    case .up: return a.row < b.row
                    case .down: return a.row > b.row
                    }
                }
            var placed: [MergerTile] = []
            var mergedHere: Set<Int> = []                       // ids already merged this move
            for var t in lineTiles {
                if var last = placed.last, last.value == t.value, !mergedHere.contains(last.id) {
                    last.value *= 2
                    placed[placed.count - 1] = last
                    mergedHere.insert(last.id)
                    result.merges.append(last.value)
                    result.grown.append(last.id)
                    score += last.value
                    continue                                    // t is absorbed
                }
                let slot = placed.count
                switch direction {
                case .left: t.column = slot
                case .right: t.column = Self.size - 1 - slot
                case .up: t.row = slot
                case .down: t.row = Self.size - 1 - slot
                }
                placed.append(t)
            }
            survivors += placed
        }
        let before = Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, $0) })
        result.moved = survivors.count != tiles.count || survivors.contains { before[$0.id] != $0 }
        guard result.moved else { return result }
        tiles = survivors
        moves += 1
        result.spawned = spawn(rng: &rng)
        return result
    }

    /// A new 2 (or, 1 in 10, a 4) in a random empty cell.
    @discardableResult
    mutating func spawn<G: RandomNumberGenerator>(rng: inout G) -> MergerTile? {
        guard let cell = emptyCells.randomElement(using: &rng) else { return nil }
        let value = Double.random(in: 0..<1, using: &rng) < Self.fourChance ? 4 : 2
        let t = MergerTile(id: nextID, value: value, row: cell.row, column: cell.column)
        nextID += 1
        tiles.append(t)
        return t
    }
}
