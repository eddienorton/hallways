import Foundation

// Oct 7 -- PAPER JAM (office computer): the falling-block game.
// Pure rules, no SwiftUI, no timers, no persistence. Time (gravity, lock
// delay) is driven from outside by the session, so the game simply does not
// advance while nobody is looking at it.
//
// The well is 8 wide x 14 tall -- narrower and shorter than the classic
// 10 x 20 so each block can be big enough to read on the tiny monitor (and an
// 8-wide row is quicker to complete: a gentler, more casual game). The seven
// four-block pieces, dealt from a shuffled "bag" of all seven so no piece is
// ever starved for long. Full rows clear (two-phase, so the view can flash
// them before they go); level rises every 8 rows; top-out ends the run.

nonisolated enum PaperJamKind: Int, CaseIterable, Sendable {
    case i, o, t, s, z, j, l

    /// Spawn shape in its bounding box (row, column), rotation 0.
    var shape: [(Int, Int)] {
        switch self {
        case .i: return [(1, 0), (1, 1), (1, 2), (1, 3)]
        case .o: return [(0, 0), (0, 1), (1, 0), (1, 1)]
        case .t: return [(0, 1), (1, 0), (1, 1), (1, 2)]
        case .s: return [(0, 1), (0, 2), (1, 0), (1, 1)]
        case .z: return [(0, 0), (0, 1), (1, 1), (1, 2)]
        case .j: return [(0, 0), (1, 0), (1, 1), (1, 2)]
        case .l: return [(0, 2), (1, 0), (1, 1), (1, 2)]
        }
    }

    var boxSize: Int {
        switch self {
        case .i: return 4
        case .o: return 2
        default: return 3
        }
    }
}

nonisolated struct PaperJamPiece: Equatable, Sendable {
    let kind: PaperJamKind
    var rotation: Int          // 0...3, clockwise quarter turns
    var row: Int               // bounding box top-left in the well
    var column: Int

    /// The four cells this piece covers, in well coordinates.
    var cells: [(row: Int, column: Int)] {
        let n = kind.boxSize
        return kind.shape.map { cell in
            var (r, c) = cell
            for _ in 0..<(rotation % 4) { (r, c) = (c, n - 1 - r) }     // rotate clockwise in the box
            return (row + r, column + c)
        }
    }

    static func == (a: PaperJamPiece, b: PaperJamPiece) -> Bool {
        a.kind == b.kind && a.rotation % 4 == b.rotation % 4 && a.row == b.row && a.column == b.column
    }
}

nonisolated struct PaperJamGame: Sendable {
    static let width = 8
    static let height = 14
    static let linesPerLevel = 8
    /// Points for clearing 1, 2, 3, 4 rows at once (times the level).
    static let clearPoints = [0, 100, 300, 500, 800]

    /// row 0 = top. nil = empty.
    private(set) var board: [[PaperJamKind?]]
    private(set) var current: PaperJamPiece?
    private(set) var next: PaperJamKind
    private var bag: [PaperJamKind] = []
    private(set) var score = 0
    private(set) var lines = 0
    private(set) var isOver = false
    /// Full rows waiting to be cleared (between lock and finishClear).
    private(set) var pendingClear: [Int] = []

    var level: Int { 1 + lines / Self.linesPerLevel }

    /// Seconds per one-row fall at this level: 0.85 s at level 1, 12% faster
    /// each level, never faster than 0.12 s.
    var gravityInterval: Double { max(0.12, 0.85 * pow(0.88, Double(level - 1))) }

    init<G: RandomNumberGenerator>(rng: inout G) {
        board = Array(repeating: Array(repeating: nil, count: Self.width), count: Self.height)
        next = .t
        bag = []
        next = draw(rng: &rng)
        spawn(rng: &rng)
    }

    /// A fixed setup (tests). `board` rows are strings: "." empty, any other char filled.
    init(rows: [String], current: PaperJamPiece?, next: PaperJamKind = .o) {
        board = Array(repeating: Array(repeating: nil, count: Self.width), count: Self.height)
        let offset = Self.height - rows.count
        for (k, line) in rows.enumerated() {
            for (c, ch) in line.enumerated() where ch != "." && c < Self.width { board[offset + k][c] = .o }
        }
        self.current = current
        self.next = next
    }

    // MARK: Collision

    func fits(_ piece: PaperJamPiece) -> Bool {
        piece.cells.allSatisfy { cell in
            cell.column >= 0 && cell.column < Self.width && cell.row < Self.height
                && (cell.row < 0 || board[cell.row][cell.column] == nil)
        }
    }

    var isGrounded: Bool {
        guard var p = current else { return false }
        p.row += 1
        return !fits(p)
    }

    /// Where the current piece would land (the ghost).
    var ghost: PaperJamPiece? {
        guard var p = current else { return nil }
        while true {
            var down = p
            down.row += 1
            if !fits(down) { return p }
            p = down
        }
    }

    // MARK: Moves

    @discardableResult
    mutating func move(by dc: Int) -> Bool {
        guard !isOver, var p = current else { return false }
        p.column += dc
        guard fits(p) else { return false }
        current = p
        return true
    }

    /// Clockwise turn. If it doesn't fit in place, try nudging it sideways
    /// (1, then 2 cells) and then up one -- so turning against a wall or the
    /// stack "just works" instead of silently refusing.
    @discardableResult
    mutating func rotate() -> Bool {
        guard !isOver, let p = current, p.kind != .o else { return false }
        var turned = p
        turned.rotation = (p.rotation + 1) % 4
        for (dr, dc) in [(0, 0), (0, -1), (0, 1), (0, -2), (0, 2), (-1, 0), (-1, -1), (-1, 1)] {
            var candidate = turned
            candidate.row += dr
            candidate.column += dc
            if fits(candidate) {
                current = candidate
                return true
            }
        }
        return false
    }

    /// Gravity / soft drop: one row down. False = it can't (it's resting).
    @discardableResult
    mutating func stepDown(soft: Bool = false) -> Bool {
        guard !isOver, var p = current else { return false }
        p.row += 1
        guard fits(p) else { return false }
        current = p
        if soft { score += 1 }
        return true
    }

    /// Straight down and lock. Returns rows dropped.
    @discardableResult
    mutating func hardDrop() -> Int {
        var dropped = 0
        while stepDown() { dropped += 1 }
        score += 2 * dropped
        lock()
        return dropped
    }

    /// Fix the current piece into the well. Full rows become pendingClear
    /// (call finishClear to remove them); with none, the next piece spawns
    /// at once (pass rng via finishClear / spawn).
    mutating func lock() {
        guard !isOver, let p = current else { return }
        for cell in p.cells where cell.row >= 0 { board[cell.row][cell.column] = p.kind }
        current = nil
        if p.cells.contains(where: { $0.row < 0 }) {           // locked above the top
            isOver = true
            return
        }
        pendingClear = (0..<Self.height).filter { r in board[r].allSatisfy { $0 != nil } }
    }

    /// Removes the pending full rows (scoring them) and spawns the next piece.
    /// Returns how many rows were cleared.
    @discardableResult
    mutating func finishClear<G: RandomNumberGenerator>(rng: inout G) -> Int {
        guard !isOver, current == nil else { return 0 }
        let cleared = pendingClear.count
        if cleared > 0 {
            let full = Set(pendingClear)
            let kept = board.enumerated().filter { !full.contains($0.offset) }.map(\.element)
            board = Array(repeating: Array(repeating: nil, count: Self.width), count: cleared) + kept
            score += Self.clearPoints[min(cleared, 4)] * level        // the level the rows were cleared at
            lines += cleared
            pendingClear = []
        }
        spawn(rng: &rng)
        return cleared
    }

    /// Stack height as a fraction of the well (for the danger cue).
    var stackFraction: Double {
        guard let top = board.firstIndex(where: { row in row.contains { $0 != nil } }) else { return 0 }
        return Double(Self.height - top) / Double(Self.height)
    }

    /// Tests only: start from a given rows-cleared count (for level tests).
    mutating func setLinesForTesting(_ n: Int) { lines = n }

    // MARK: Spawning

    private mutating func draw<G: RandomNumberGenerator>(rng: inout G) -> PaperJamKind {
        if bag.isEmpty { bag = PaperJamKind.allCases.shuffled(using: &rng) }
        return bag.removeLast()
    }

    /// The waiting piece enters at the top centre; if it can't, the run is over.
    private mutating func spawn<G: RandomNumberGenerator>(rng: inout G) {
        let kind = next
        next = draw(rng: &rng)
        let piece = PaperJamPiece(kind: kind, rotation: 0, row: kind == .i ? -1 : 0,
                                  column: (Self.width - kind.boxSize) / 2)
        if fits(piece) {
            current = piece
        } else {
            current = nil
            isOver = true
        }
    }
}
