import Foundation
import Testing
@testable import Hallways

/// Oct 7 -- Paper Jam (office computer falling-block game) rules.
/// Well: 8 wide x 14 tall, row 0 at the top. Test boards list the BOTTOM rows.
struct PaperJamGameTests {
    private func piece(_ k: PaperJamKind, row: Int = 0, column: Int = 2, rotation: Int = 0) -> PaperJamPiece {
        PaperJamPiece(kind: k, rotation: rotation, row: row, column: column)
    }

    @Test func horizontalMovementAndWalls() {
        var g = PaperJamGame(rows: [], current: piece(.o, column: 0))
        #expect(!g.move(by: -1))                                      // left wall
        #expect(g.move(by: 1))
        #expect(g.current?.column == 1)
        g = PaperJamGame(rows: [], current: piece(.o, column: PaperJamGame.width - 2))
        #expect(!g.move(by: 1))                                       // right wall
    }

    @Test func movementBlockedByTheStack() {
        // O piece resting on the floor at columns 2-3; a block at column 4 on the bottom row.
        var g = PaperJamGame(rows: ["....#..."], current: piece(.o, row: PaperJamGame.height - 2, column: 2))
        #expect(!g.move(by: 1))
        #expect(g.move(by: -1))
    }

    @Test func rotationTurnsAndKicksOffWalls() {
        var g = PaperJamGame(rows: [], current: piece(.t, row: 3, column: 2))
        #expect(g.rotate())
        #expect(g.current?.rotation == 1)
        // A vertical I against the right wall: turning flat must nudge it back inside.
        var h = PaperJamGame(rows: [], current: piece(.i, row: 3, column: PaperJamGame.width - 3, rotation: 1))
        #expect(h.current.map { h.fits($0) } == true)
        #expect(h.rotate())
        #expect(h.current!.cells.allSatisfy { $0.column >= 0 && $0.column < PaperJamGame.width })
        // O never turns.
        var o = PaperJamGame(rows: [], current: piece(.o))
        #expect(!o.rotate())
    }

    @Test func fallingLandingAndLocking() {
        var g = PaperJamGame(rows: [], current: piece(.o, row: PaperJamGame.height - 3))
        #expect(g.stepDown())
        #expect(g.isGrounded)
        #expect(!g.stepDown())
        g.lock()
        #expect(g.current == nil)
        #expect(g.board[PaperJamGame.height - 1][2] == .o && g.board[PaperJamGame.height - 2][3] == .o)
        #expect(g.pendingClear.isEmpty)
        var rng = SeededRNG(seed: 1)
        g.finishClear(rng: &rng)
        #expect(g.current != nil)                                     // the next piece spawned
        #expect(g.current?.kind == .o)                                // the waiting "next" became current
    }

    @Test func aCompletedRowClears() {
        // Bottom row full except columns 2-3; an O drops into the gap.
        var g = PaperJamGame(rows: ["##..####"], current: piece(.o, row: 0, column: 2))
        g.hardDrop()
        #expect(g.pendingClear == [PaperJamGame.height - 1])
        var rng = SeededRNG(seed: 2)
        #expect(g.finishClear(rng: &rng) == 1)
        #expect(g.lines == 1)
        // What's left is the O's top half, now on the bottom row.
        #expect(g.board[PaperJamGame.height - 1].compactMap { $0 }.count == 2)
    }

    @Test func multipleRowsClearTogetherAndScoreMore() {
        var g = PaperJamGame(rows: ["##..####", "##..####"], current: piece(.o, row: 0, column: 2))
        let dropped = g.hardDrop()
        #expect(g.pendingClear.count == 2)
        var rng = SeededRNG(seed: 3)
        #expect(g.finishClear(rng: &rng) == 2)
        #expect(g.lines == 2)
        #expect(g.score == 2 * dropped + PaperJamGame.clearPoints[2] * 1)
        #expect(g.board.allSatisfy { row in row.allSatisfy { $0 == nil } })
    }

    @Test func softAndHardDropScore() {
        var g = PaperJamGame(rows: [], current: piece(.o))
        g.stepDown(soft: true)
        #expect(g.score == 1)
        let d = g.hardDrop()
        #expect(g.score == 1 + 2 * d)
    }

    @Test func spawnUsesTheBagAndShowsNext() {
        var rng = SeededRNG(seed: 4)
        var g = PaperJamGame(rng: &rng)
        var seen: [PaperJamKind] = [g.current!.kind]
        for _ in 0..<6 {
            g.hardDrop()
            g.finishClear(rng: &rng)
            guard let k = g.current?.kind else { break }
            seen.append(k)
        }
        #expect(Set(seen).count == 7)                                 // first seven pieces: one of each
    }

    @Test func toppingOutEndsTheRun() {
        // Everything but the top row is full in columns 2-5 -> nowhere for a new piece.
        let blocked = Array(repeating: "..####..", count: PaperJamGame.height - 1)
        var g = PaperJamGame(rows: blocked, current: piece(.o, row: 0, column: 0))
        g.hardDrop()
        var rng = SeededRNG(seed: 5)
        g.finishClear(rng: &rng)
        #expect(g.isOver)
        #expect(g.current == nil)
    }

    @Test func levelAndSpeedProgression() {
        var g = PaperJamGame(rows: [], current: nil)
        #expect(g.level == 1)
        #expect(abs(g.gravityInterval - 0.85) < 0.0001)
        // Clear 8 rows' worth of single lines.
        for _ in 0..<PaperJamGame.linesPerLevel {
            g = PaperJamGame(rows: ["##..####"], current: PaperJamPiece(kind: .o, rotation: 0, row: 0, column: 2))
                .withLines(g.lines)
            g.hardDrop()
            var rng = SeededRNG(seed: 6)
            g.finishClear(rng: &rng)
        }
        #expect(g.level == 2)
        #expect(g.gravityInterval < 0.85)
    }
}

private extension PaperJamGame {
    /// Test helper: the same setup, with a lines count carried over.
    func withLines(_ n: Int) -> PaperJamGame {
        var copy = self
        copy.setLinesForTesting(n)
        return copy
    }
}
