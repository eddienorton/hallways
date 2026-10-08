import Foundation

// Oct 7 -- MINEFIELD (office computer). Pure rules, no SwiftUI, no persistence.
//
// One field, sized for the tiny monitor rather than a desktop: 5 rows x 9
// columns with 8 mines. Mines are laid only at the FIRST reveal, never on the
// tapped cell or any of its neighbours, so the opening tap always opens
// ground (usually a small region).

nonisolated struct MinefieldGame: Equatable, Sendable {
    static let rows = 5
    static let columns = 9
    static let mineCount = 8
    static var cellCount: Int { rows * columns }

    enum Phase: Equatable, Sendable { case ready, playing, won, lost }
    enum Cell: Equatable, Sendable { case hidden, flagged, revealed }

    /// What a reveal did -- the opened cells in flood (ripple) order.
    enum Outcome: Equatable, Sendable {
        case nothing
        case opened([Int])
        case won([Int])
        case boom(Int)
    }

    private(set) var phase: Phase = .ready
    private(set) var mines: Set<Int> = []
    private(set) var cells: [Cell] = Array(repeating: .hidden, count: MinefieldGame.cellCount)
    private(set) var exploded: Int?

    init() {}

    /// A fixed field (tests): mines already laid, play under way.
    init(mines: Set<Int>) {
        self.mines = mines
        phase = .playing
    }

    // MARK: Geometry

    static func index(row: Int, column: Int) -> Int { row * columns + column }
    static func position(_ i: Int) -> (row: Int, column: Int) { (i / columns, i % columns) }

    static func neighbours(of i: Int) -> [Int] {
        let (r, c) = position(i)
        var out: [Int] = []
        for dr in -1...1 {
            for dc in -1...1 where !(dr == 0 && dc == 0) {
                let rr = r + dr, cc = c + dc
                if rr >= 0, rr < rows, cc >= 0, cc < columns { out.append(index(row: rr, column: cc)) }
            }
        }
        return out
    }

    /// Mines touching cell `i`.
    func count(_ i: Int) -> Int { Self.neighbours(of: i).filter { mines.contains($0) }.count }

    var flagsPlaced: Int { cells.filter { $0 == .flagged }.count }
    var minesLeft: Int { Self.mineCount - flagsPlaced }
    var isOver: Bool { phase == .won || phase == .lost }
    private var safeCellsLeft: Int { cells.indices.filter { cells[$0] != .revealed && !mines.contains($0) }.count }

    // MARK: Moves

    /// Reveal a hidden, unflagged cell. The first reveal lays the mines.
    mutating func reveal<G: RandomNumberGenerator>(_ i: Int, rng: inout G) -> Outcome {
        guard !isOver, cells.indices.contains(i), cells[i] == .hidden else { return .nothing }
        if phase == .ready { layMines(avoiding: i, rng: &rng) }
        if mines.contains(i) {
            cells[i] = .revealed
            exploded = i
            phase = .lost
            return .boom(i)
        }
        let opened = flood(from: i)
        if safeCellsLeft == 0 {
            phase = .won
            return .won(opened)
        }
        return .opened(opened)
    }

    /// Tap on a revealed number whose flags already match it: open the rest
    /// of its neighbours (a flag in the wrong place can still go bang).
    mutating func chord(_ i: Int) -> Outcome {
        guard phase == .playing, cells[i] == .revealed else { return .nothing }
        let around = Self.neighbours(of: i)
        let n = count(i)
        guard n > 0, around.filter({ cells[$0] == .flagged }).count == n else { return .nothing }
        var opened: [Int] = []
        for j in around where cells[j] == .hidden {
            if mines.contains(j) {
                cells[j] = .revealed
                exploded = j
                phase = .lost
                return .boom(j)
            }
            opened += flood(from: j)
        }
        guard !opened.isEmpty else { return .nothing }
        if safeCellsLeft == 0 {
            phase = .won
            return .won(opened)
        }
        return .opened(opened)
    }

    /// Plant / lift a flag on a hidden cell. Flags never reveal anything.
    @discardableResult
    mutating func toggleFlag(_ i: Int) -> Bool {
        guard !isOver, cells.indices.contains(i) else { return false }
        switch cells[i] {
        case .hidden: cells[i] = .flagged
        case .flagged: cells[i] = .hidden
        case .revealed: return false
        }
        return true
    }

    // MARK: Internals

    private mutating func layMines<G: RandomNumberGenerator>(avoiding first: Int, rng: inout G) {
        let keepClear = Set([first] + Self.neighbours(of: first))
        let candidates = (0..<Self.cellCount).filter { !keepClear.contains($0) }
        mines = Set(candidates.shuffled(using: &rng).prefix(Self.mineCount))
        phase = .playing
    }

    /// Breadth-first open from `start`: zero cells spread to their
    /// neighbours; numbers stop the spread. Flagged cells stay flagged.
    private mutating func flood(from start: Int) -> [Int] {
        var opened: [Int] = []
        var queue = [start]
        var seen: Set<Int> = [start]
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            guard cells[i] == .hidden, !mines.contains(i) else { continue }
            cells[i] = .revealed
            opened.append(i)
            if count(i) == 0 {
                for j in Self.neighbours(of: i) where !seen.contains(j) && cells[j] == .hidden {
                    seen.insert(j)
                    queue.append(j)
                }
            }
        }
        return opened
    }
}
