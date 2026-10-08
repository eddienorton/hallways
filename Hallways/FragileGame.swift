import Foundation

// Oct 7 -- FRAGILE (office computer): the bubble-wrap fidget toy.
// Pure rules, no SwiftUI, no timers, no persistence.
//
// Something arrived in the mail, and it came with a sheet of bubble wrap.
// Pop it. Touch a bubble and it pops; drag across the sheet and you pop
// everything your finger runs over. Pops close together make a "run", and
// each pop in a run sounds a touch higher. Now and then a bubble is stubborn
// (just like the real thing): the first press only squishes it, the second
// one bangs. Pop the whole sheet and a fresh one is pulled off the roll.
//
// No score, no clock, no fail state: just a running tally of how much
// you've popped, which is its own quiet joke.
//
// The sheet is 9 bubbles across x 4 rows, packed like real bubble wrap (odd
// rows shifted half a bubble). Geometry is in "pitch" units: neighbouring
// bubble centres in a row are 1 apart.

nonisolated enum FragileWrap: Int, CaseIterable, Sendable {
    case clear             // most sheets
    case pink              // anti-static: a nice surprise
    case blue
}

nonisolated struct FragileBubble: Equatable, Sendable {
    /// Presses still needed: 1 for an ordinary bubble, 2 for a stubborn one; 0 = popped.
    var pressesLeft: Int
    let stubborn: Bool
    var popped: Bool { pressesLeft == 0 }
}

nonisolated enum FragilePress: Equatable, Sendable {
    /// Nothing happened (already flat, between bubbles, or between sheets).
    case nothing
    /// A stubborn bubble gave a little but held.
    case squished(index: Int)
    /// Popped. `run` counts quick pops in a row (1 = on its own).
    case popped(index: Int, run: Int, stubborn: Bool, sheetCleared: Bool)
}

nonisolated struct FragileGame: Sendable {
    static let columns = 9
    static let rows = 4
    static var count: Int { columns * rows }
    /// Pops closer together than this continue a run.
    static let runGap = 0.35
    /// The highest run step the sound climbs to.
    static let maxRunStep = 8

    private(set) var bubbles: [FragileBubble]
    private(set) var wrap: FragileWrap = .clear
    private(set) var sheet = 1
    /// Every bubble popped this session (all sheets).
    private(set) var totalPopped = 0
    private(set) var run = 0
    private var lastPop: Double?

    init<R: RandomNumberGenerator>(rng: inout R) {
        bubbles = Self.makeSheet(stubborn: Self.stubbornCount(rng: &rng), rng: &rng)
        wrap = .clear                                         // the first sheet is always plain wrap
    }

    /// Testing: a sheet with stubborn bubbles exactly at `stubborn`.
    init(stubbornAt stubborn: Set<Int> = []) {
        bubbles = (0..<Self.count).map { FragileBubble(pressesLeft: stubborn.contains($0) ? 2 : 1, stubborn: stubborn.contains($0)) }
    }

    var remaining: Int { bubbles.reduce(0) { $0 + ($1.popped ? 0 : 1) } }
    var isCleared: Bool { remaining == 0 }

    // MARK: Pressing

    /// Press bubble `index` at time `now` (seconds, any monotonic clock).
    mutating func press(_ index: Int, at now: Double) -> FragilePress {
        guard bubbles.indices.contains(index), !bubbles[index].popped else { return .nothing }
        bubbles[index].pressesLeft -= 1
        guard bubbles[index].popped else { return .squished(index: index) }
        if let last = lastPop, now - last <= Self.runGap { run += 1 } else { run = 1 }
        lastPop = now
        totalPopped += 1
        return .popped(index: index, run: run, stubborn: bubbles[index].stubborn, sheetCleared: isCleared)
    }

    /// Pull a fresh sheet off the roll (only once this one is fully popped).
    @discardableResult
    mutating func nextSheet<R: RandomNumberGenerator>(rng: inout R) -> Bool {
        guard isCleared else { return false }
        sheet += 1
        bubbles = Self.makeSheet(stubborn: Self.stubbornCount(rng: &rng), rng: &rng)
        let roll = Double.random(in: 0..<1, using: &rng)
        wrap = roll < 0.15 ? .pink : (roll < 0.3 ? .blue : .clear)
        run = 0
        lastPop = nil
        return true
    }

    /// Usually one stubborn bubble a sheet; sometimes none, sometimes two.
    static func stubbornCount<R: RandomNumberGenerator>(rng: inout R) -> Int {
        let roll = Double.random(in: 0..<1, using: &rng)
        return roll < 0.2 ? 0 : (roll < 0.85 ? 1 : 2)
    }

    static func makeSheet<R: RandomNumberGenerator>(stubborn: Int, rng: inout R) -> [FragileBubble] {
        let picks = Set(Array(0..<count).shuffled(using: &rng).prefix(max(0, min(stubborn, count))))
        return (0..<count).map { FragileBubble(pressesLeft: picks.contains($0) ? 2 : 1, stubborn: picks.contains($0)) }
    }

    // MARK: Geometry (pitch units)

    /// Vertical distance between rows (hexagonal packing).
    static let rowPitch = 0.866
    /// The sheet's size in pitch units: 9.5 across (odd rows shift half), rows stacked.
    static let sheetWidth = Double(columns) + 0.5
    static let sheetHeight = Double(rows - 1) * rowPitch + 1

    static func center(of index: Int) -> (x: Double, y: Double) {
        let r = index / columns, c = index % columns
        return (0.5 + Double(c) + (r % 2 == 1 ? 0.5 : 0), 0.5 + Double(r) * rowPitch)
    }

    /// The bubble under a point (pitch units), if the point is on one. Anything
    /// within 0.6 of a centre counts: generous, and with this packing the
    /// nearest centre is always the bubble you meant.
    static func index(atX x: Double, y: Double) -> Int? {
        var best: Int?
        var bestD = 0.6 * 0.6
        guard x.isFinite, y.isFinite else { return nil }
        let r0 = min(rows - 1, max(0, Int(((y - 0.5) / rowPitch).rounded())))
        for r in max(0, r0 - 1)...min(rows - 1, r0 + 1) {
            for c in 0..<columns {
                let i = r * columns + c
                let p = center(of: i)
                let d = (p.x - x) * (p.x - x) + (p.y - y) * (p.y - y)
                if d < bestD { bestD = d; best = i }
            }
        }
        return best
    }
}
