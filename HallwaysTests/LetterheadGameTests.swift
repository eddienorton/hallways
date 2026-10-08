import Foundation
import Testing
@testable import Hallways

/// Oct 7 -- Letterhead (office computer word game) round rules.
struct LetterheadGameTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func round(_ base: String, known: [String]) -> LetterheadRound {
        var rng = SeededRNG(seed: 9)
        return LetterheadRound(base: base, known: known, now: t0, rng: &rng)
    }

    /// Taps the rack tiles spelling `word` (first unused tile for each letter).
    private func spell(_ word: String, in r: inout LetterheadRound) {
        for ch in word {
            if let tile = r.tiles.first(where: { $0.letter == ch && !r.isUsed($0.id) }) { r.tap(tile.id, now: t0) }
        }
    }

    @Test func repeatedLettersCanBeUsedOnlyAsOftenAsTheyAppear() {
        var r = round("LETTER", known: ["LET", "TEE", "LETTER", "TREE"])
        #expect(r.canSpell("TREE"))
        #expect(r.canSpell("LETTER"))
        #expect(!r.canSpell("TEETEE"))                     // three E's, rack has two
        spell("LETTER", in: &r)
        #expect(r.currentWord == "LETTER")
        // Every tile is used: no further tap can add a seventh letter.
        #expect(!r.tap(r.tiles[0].id, now: t0))
    }

    @Test func eachTileOnlyOnceAndBackspaceFreesIt() {
        var r = round("PLANET", known: ["PLAN", "PLANET"])
        let p = r.tiles.first { $0.letter == "P" }!.id
        #expect(r.tap(p, now: t0))
        #expect(!r.tap(p, now: t0))
        #expect(r.backspace())
        #expect(r.tap(p, now: t0))
        #expect(r.clear() && r.currentWord.isEmpty)
    }

    @Test func scoringByLength() {
        #expect([3, 4, 5, 6].map(LetterheadRound.points(forLength:)) == [1, 2, 4, 8])
        var r = round("PLANET", known: ["ANT", "PLAN", "PLANT", "PLANET"])
        for w in ["ANT", "PLAN", "PLANT", "PLANET"] {
            spell(w, in: &r)
            _ = r.submit(now: t0) { _ in false }
        }
        #expect(r.score == 15)
        #expect(r.foundSixLetter)
        #expect(r.missed.isEmpty)
    }

    @Test func duplicateAndInvalidAndShortAreRejectedHarmlessly() {
        var r = round("PLANET", known: ["PLAN", "PLANET"])
        spell("PLAN", in: &r)
        #expect(r.submit(now: t0) { _ in false } == .accepted(word: "PLAN", points: 2))
        spell("PLAN", in: &r)
        #expect(r.submit(now: t0) { _ in false } == .duplicate("PLAN"))
        spell("NETP", in: &r)
        #expect(r.submit(now: t0) { _ in false } == .notAWord("NETP"))
        spell("PL", in: &r)
        #expect(r.submit(now: t0) { _ in false } == .tooShort)
        #expect(r.currentWord == "PL")                     // too short keeps what you typed
        #expect(r.found == ["PLAN"])
        #expect(r.score == 2)
    }

    @Test func wordsOutsideTheListAreCheckedByTheValidator() {
        var r = round("PLANET", known: ["PLAN"])
        spell("PELT", in: &r)
        #expect(r.submit(now: t0) { $0 == "PELT" } == .accepted(word: "PELT", points: 2))
    }

    @Test func timerIsARealDeadline() {
        var r = round("PLANET", known: ["PLAN"])
        #expect(r.remaining(at: t0) == LetterheadRound.duration)
        // Forty seconds pass (game closed, say): the clock kept running.
        #expect(r.remaining(at: t0.addingTimeInterval(40)) == LetterheadRound.duration - 40)
        let after = t0.addingTimeInterval(LetterheadRound.duration + 1)
        #expect(r.isOver(at: after))
        #expect(!r.tap(r.tiles[0].id, now: after))
        spell("PLAN", in: &r)                               // taps at t0, before the end
        #expect(r.submit(now: after) { _ in true } == .timeUp)
        #expect(r.found.isEmpty)
    }

    @Test func shuffleKeepsTheSameTilesAndTheBuiltWord() {
        var r = round("PLANET", known: ["PLAN"])
        spell("PLA", in: &r)
        var rng = SeededRNG(seed: 3)
        r.shuffle(using: &rng)
        #expect(Set(r.order) == Set(r.tiles.map(\.id)))
        #expect(r.currentWord == "PLA")
    }

    @Test func everyFrozenRackIsSixLettersAndContainsItsBase() {
        #expect(LetterheadRacks.bases.count >= 100)
        for base in LetterheadRacks.bases {
            #expect(base.count == 6)
            let words = LetterheadRacks.words(for: base)
            #expect(words.contains(base))
            #expect(words.count >= 14)
            let r = round(base, known: words)
            #expect(words.allSatisfy { r.canSpell($0) && (3...6).contains($0.count) })
        }
    }
}
