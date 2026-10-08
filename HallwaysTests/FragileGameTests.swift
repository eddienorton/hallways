import Foundation
import Testing
@testable import Hallways

/// Oct 7 -- Fragile (office computer bubble-wrap toy) rules.
/// Sheet: 9 x 4 bubbles, hex-packed; geometry in pitch units.
struct FragileGameTests {
    @Test func aFreshSheetIsFullAndUnpopped() {
        let g = FragileGame()
        #expect(g.bubbles.count == FragileGame.count && FragileGame.count == 36)
        #expect(g.remaining == 36 && !g.isCleared)
        #expect(g.totalPopped == 0 && g.sheet == 1)
    }

    @Test func pressingABubblePopsIt() {
        var g = FragileGame()
        let r = g.press(10, at: 0)
        #expect(r == .popped(index: 10, run: 1, stubborn: false, sheetCleared: false))
        #expect(g.bubbles[10].popped)
        #expect(g.remaining == 35 && g.totalPopped == 1)
    }

    @Test func aPoppedBubbleCannotPopAgain() {
        var g = FragileGame()
        _ = g.press(3, at: 0)
        let r1 = g.press(3, at: 0.5)
        #expect(r1 == .nothing)
        let r2 = g.press(3, at: 5)
        #expect(r2 == .nothing)
        #expect(g.totalPopped == 1)
        let below = g.press(-1, at: 0), beyond = g.press(FragileGame.count, at: 0)
        #expect(below == .nothing && beyond == .nothing)
    }

    @Test func aStubbornBubbleNeedsTwoPresses() {
        var g = FragileGame(stubbornAt: [5])
        let r3 = g.press(5, at: 0)
        #expect(r3 == .squished(index: 5))
        #expect(!g.bubbles[5].popped && g.totalPopped == 0)
        let r4 = g.press(5, at: 1)
        #expect(r4 == .popped(index: 5, run: 1, stubborn: true, sheetCleared: false))
        let r5 = g.press(5, at: 2)
        #expect(r5 == .nothing)
    }

    @Test func quickPopsMakeARunAndAPauseEndsIt() {
        var g = FragileGame()
        var runs: [Int] = []
        for (k, t) in [0.0, 0.1, 0.2, 0.5, 1.2, 1.3].enumerated() {
            if case .popped(_, let run, _, _) = g.press(k, at: t) { runs.append(run) }
        }
        // 0.2 -> 0.5 is within the gap; 0.5 -> 1.2 is not.
        #expect(runs == [1, 2, 3, 4, 1, 2])
    }

    @Test func aSquishDoesNotBreakOrExtendARun() {
        var g = FragileGame(stubbornAt: [1])
        _ = g.press(0, at: 0)
        let r6 = g.press(1, at: 0.1)
        #expect(r6 == .squished(index: 1))
        if case .popped(_, let run, _, _) = g.press(2, at: 0.2) { #expect(run == 2) } else { Issue.record("expected a pop") }
    }

    @Test func poppingTheLastBubbleClearsTheSheet() {
        var g = FragileGame()
        var last: FragilePress = .nothing
        for i in 0..<FragileGame.count { last = g.press(i, at: Double(i)) }
        #expect(last == .popped(index: FragileGame.count - 1, run: 1, stubborn: false, sheetCleared: true))
        #expect(g.isCleared && g.totalPopped == 36)
    }

    @Test func aNewSheetOnlyComesOnceTheOldOneIsDone() {
        var g = FragileGame()
        var rng = SeededRNG(seed: 4)
        _ = g.press(0, at: 0)
        let skipped = g.nextSheet(rng: &rng)
        #expect(!skipped)                                             // can't skip a half-popped sheet
        #expect(g.sheet == 1 && g.remaining == 35)
        for i in 1..<FragileGame.count { _ = g.press(i, at: 10 + Double(i)) }
        let pulled = g.nextSheet(rng: &rng)
        #expect(pulled)
        #expect(g.sheet == 2 && g.remaining == 36 && !g.isCleared)
        #expect(g.totalPopped == 36)                                  // the tally carries over
        if case .popped(_, let run, _, _) = g.press(0, at: 47) { #expect(run == 1) }   // no run across sheets
    }

    @Test func sheetsHaveAtMostTwoStubbornBubbles() {
        var rng = SeededRNG(seed: 99)
        var sawNone = false, sawOne = false
        for _ in 0..<200 {
            let n = FragileGame.stubbornCount(rng: &rng)
            #expect((0...2).contains(n))
            if n == 0 { sawNone = true }
            if n == 1 { sawOne = true }
            let sheet = FragileGame.makeSheet(stubborn: n, rng: &rng)
            #expect(sheet.filter(\.stubborn).count == n)
            #expect(sheet.allSatisfy { $0.pressesLeft == ($0.stubborn ? 2 : 1) })
        }
        #expect(sawNone && sawOne)
    }

    @Test func theFirstSheetIsPlainWrap() {
        var rng = SeededRNG(seed: 5)
        #expect(FragileGame(rng: &rng).wrap == .clear)
    }

    @Test func touchesFindTheBubbleUnderTheFinger() {
        for i in 0..<FragileGame.count {
            let c = FragileGame.center(of: i)
            #expect(FragileGame.index(atX: c.x, y: c.y) == i)
            #expect(FragileGame.index(atX: c.x + 0.3, y: c.y - 0.25) == i)   // a sloppy thumb still counts
        }
        // Odd rows sit half a bubble to the right.
        #expect(FragileGame.center(of: FragileGame.columns).x == FragileGame.center(of: 0).x + 0.5)
        // Off the sheet: nothing.
        #expect(FragileGame.index(atX: -2, y: 0.5) == nil)
        #expect(FragileGame.index(atX: 4, y: 40) == nil)
        #expect(FragileGame.index(atX: 4, y: -40) == nil)
    }

    @MainActor
    @Test func theHalfPoppedSheetIsKeptWhileTheComputerIsAway() {
        let store = ComputerGameStore()
        let first = store.model(for: .fragile) { FragileSession() }
        first.press(7)
        let again = store.model(for: .fragile) { FragileSession() }
        #expect(again === first)
        #expect(again.game.bubbles[7].popped || again.game.bubbles[7].stubborn)
        #expect(again.game.totalPopped == first.game.totalPopped)
    }
}
