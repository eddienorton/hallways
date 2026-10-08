import Foundation

// Oct 7 -- LETTERHEAD (office computer): six letters, a clock, as many
// words as you can make. Pure round rules; no SwiftUI, no persistence.
//
// A round is built from a known six-letter base word (LetterheadRacks), so
// every rack is guaranteed to hold real words, including at least one that
// uses all six letters. The clock is a real deadline (a Date), not a counter
// in a view: walk away and it keeps running, as the building does.

nonisolated struct LetterheadTile: Identifiable, Equatable, Sendable {
    let id: Int
    let letter: Character
}

nonisolated enum LetterheadSubmit: Equatable, Sendable {
    case accepted(word: String, points: Int)
    case tooShort
    case duplicate(String)
    case notAWord(String)
    case timeUp
}

nonisolated struct LetterheadRound: Equatable, Sendable {
    static let duration: TimeInterval = 75
    static let minimumLength = 3

    let base: String                     // upper-case six-letter word
    let known: [String]                  // the rack's common words (reveal list)
    let tiles: [LetterheadTile]          // the six letters, by id
    private(set) var order: [Int]        // tile ids, in display order (shuffle)
    private(set) var current: [Int] = [] // tile ids, in the word being built
    private(set) var found: [String] = []
    let deadline: Date

    init<G: RandomNumberGenerator>(base: String, known: [String], now: Date = Date(), rng: inout G) {
        self.base = base.uppercased()
        self.known = known
        tiles = Array(self.base).enumerated().map { LetterheadTile(id: $0.offset, letter: $0.element) }
        var shuffled = tiles.map(\.id).shuffled(using: &rng)
        // Never show the base word itself, in order, as the starting rack.
        if shuffled == tiles.map(\.id) { shuffled.reverse() }
        order = shuffled
        deadline = now.addingTimeInterval(Self.duration)
    }

    /// A random rack from the frozen list.
    static func random<G: RandomNumberGenerator>(now: Date = Date(), excluding previous: String? = nil, rng: inout G) -> LetterheadRound {
        var base = LetterheadRacks.bases.randomElement(using: &rng) ?? "PLANET"
        if base == previous, LetterheadRacks.bases.count > 1 {
            base = LetterheadRacks.bases.filter { $0 != previous }.randomElement(using: &rng) ?? base
        }
        return LetterheadRound(base: base, known: LetterheadRacks.words(for: base), now: now, rng: &rng)
    }

    // MARK: Clock

    func remaining(at now: Date = Date()) -> TimeInterval { max(0, deadline.timeIntervalSince(now)) }
    func isOver(at now: Date = Date()) -> Bool { now >= deadline }

    // MARK: Building a word

    var currentWord: String { String(current.compactMap { id in tiles.first { $0.id == id }?.letter }) }
    func isUsed(_ tileID: Int) -> Bool { current.contains(tileID) }

    /// Tap a rack tile: it joins the word (each tile once -- so a letter can
    /// only be used as many times as it appears in the rack).
    @discardableResult
    mutating func tap(_ tileID: Int, now: Date = Date()) -> Bool {
        guard !isOver(at: now), tiles.contains(where: { $0.id == tileID }), !current.contains(tileID) else { return false }
        current.append(tileID)
        return true
    }

    @discardableResult
    mutating func backspace() -> Bool {
        guard !current.isEmpty else { return false }
        current.removeLast()
        return true
    }

    @discardableResult
    mutating func clear() -> Bool {
        guard !current.isEmpty else { return false }
        current.removeAll()
        return true
    }

    mutating func shuffle<G: RandomNumberGenerator>(using rng: inout G) {
        let before = order
        for _ in 0..<4 where order == before { order.shuffle(using: &rng) }
    }

    // MARK: Submitting

    /// Whether `word` can be spelled from this rack at all (letter counts).
    func canSpell(_ word: String) -> Bool {
        var counts: [Character: Int] = [:]
        for c in base { counts[c, default: 0] += 1 }
        for c in word.uppercased() {
            guard let n = counts[c], n > 0 else { return false }
            counts[c] = n - 1
        }
        return true
    }

    /// Submit the word being built. `isValid` is consulted only for words not
    /// in the rack's known list (the spell checker, for less common words).
    /// The built word is cleared on every outcome except tooShort/timeUp.
    mutating func submit(now: Date = Date(), isValid: (String) -> Bool) -> LetterheadSubmit {
        guard !isOver(at: now) else { return .timeUp }
        let word = currentWord
        guard word.count >= Self.minimumLength else { return .tooShort }
        defer { current.removeAll() }
        guard canSpell(word) else { return .notAWord(word) }        // unreachable via tiles; kept as a guard
        if found.contains(word) { return .duplicate(word) }
        guard known.contains(word) || isValid(word) else { return .notAWord(word) }
        found.append(word)
        return .accepted(word: word, points: Self.points(forLength: word.count))
    }

    // MARK: Scoring

    static func points(forLength n: Int) -> Int {
        switch n {
        case ..<3: return 0
        case 3: return 1
        case 4: return 2
        case 5: return 4
        default: return 8
        }
    }

    var score: Int { found.reduce(0) { $0 + Self.points(forLength: $1.count) } }
    var foundSixLetter: Bool { found.contains { $0.count == 6 } }

    /// Common words from the rack's list that weren't found, longest first.
    var missed: [String] {
        known.filter { !found.contains($0) }.sorted { ($0.count, $1) > ($1.count, $0) }
    }
    /// The six-letter words of the known list (the base, and any anagram).
    var sixLetterWords: [String] { known.filter { $0.count == 6 } }
}
