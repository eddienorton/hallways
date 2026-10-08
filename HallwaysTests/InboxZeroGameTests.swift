import Foundation
import Testing
@testable import Hallways

/// Oct 7 -- Inbox Zero (office computer fixed shooter) rules.
/// Field 120 x 100, y grows downward. Most tests freeze the formation with a
/// long intro (introTimer) so only the thing under test moves.
struct InboxZeroGameTests {
    private let frame = 1.0 / 60

    /// Step the game in 60 Hz frames for up to `seconds`, stopping early once
    /// `until` matches an event. Returns every event seen.
    @discardableResult
    private func run(_ g: inout InboxGame, seconds: Double, move: Int = 0, fire: Bool = false,
                     until: (InboxEvent) -> Bool = { _ in false }) -> [InboxEvent] {
        var rng = SeededRNG(seed: 7)
        var all: [InboxEvent] = []
        var t = 0.0
        while t < seconds {
            let ev = g.update(dt: frame, move: move, fire: fire, rng: &rng)
            all += ev
            if ev.contains(where: until) { break }
            t += frame
        }
        return all
    }

    private func frozen(wave: Int = 1) -> InboxGame {
        var g = InboxGame(wave: wave)
        g.introTimer = 1_000
        g.fireTimer = 1_000
        g.urgentTimer = 1_000
        return g
    }

    private func columnX(_ g: InboxGame, _ c: Int) -> Double { g.formationX + Double(c) * InboxGame.spacingX }

    // MARK: Movement

    @Test func horizontalMovementAndBoundaries() {
        var g = frozen()
        let x0 = g.playerX
        run(&g, seconds: 0.5, move: 1)
        #expect(g.playerX > x0 + 25 && g.playerX < x0 + 35)
        run(&g, seconds: 5, move: 1)
        #expect(g.playerX == InboxGame.playerMaxX)                    // right edge holds
        run(&g, seconds: 5, move: -1)
        #expect(g.playerX == InboxGame.playerMinX)                    // left edge holds
        let x1 = g.playerX
        run(&g, seconds: 0.5, move: 0)
        #expect(g.playerX == x1)                                      // no input, no drift
    }

    // MARK: Firing

    @Test func firingHasACooldownAndAtMostTwoReplies() {
        var g = frozen()
        let fired1 = g.fire()
        #expect(fired1)
        let fired2 = g.fire()
        #expect(!fired2)                                            // still cooling down
        g.cooldown = 0
        let fired3 = g.fire()
        #expect(fired3)
        g.cooldown = 0
        let fired4 = g.fire()
        #expect(!fired4)                                            // two already in flight
        #expect(g.shots.count == InboxGame.maxShots)
    }

    @Test func holdingFireRepliesWheneverTheTrayIsReady() {
        var g = frozen()
        g.playerX = InboxGame.playerMaxX                              // clear of every envelope
        let events = run(&g, seconds: 1.0, fire: true)
        let fired = events.filter { $0 == .fired }.count
        #expect(fired >= 3 && fired <= Int(1.0 / InboxGame.fireCooldown) + 1)
    }

    @Test func repliesTravelUpAndAMissResetsTheStreak() {
        var g = frozen()
        g.playerX = InboxGame.playerMaxX                              // nothing above to hit
        g.streak = 4
        let fired5 = g.fire()
        #expect(fired5)
        let y0 = g.shots[0].y
        run(&g, seconds: 0.1)
        #expect(g.shots.count == 1 && g.shots[0].y < y0 - 10)         // moving up, fast
        let events = run(&g, seconds: 2, until: { if case .missed = $0 { return true }; return false })
        #expect(events.contains(.missed(streakLost: 4)))
        #expect(g.streak == 0 && g.shots.isEmpty)
    }

    // MARK: Hits

    @Test func aReplyAnswersTheLowestEnvelopeInItsPath() {
        var g = frozen()
        g.playerX = columnX(g, 2)
        let fired6 = g.fire()
        #expect(fired6)
        let events = run(&g, seconds: 2, until: { if case .answered = $0 { return true }; return false })
        #expect(events.contains { if case .answered(row: 2, _, _, points: 10, streak: 1) = $0 { return true }; return false })
        #expect(g.score == 10)
        #expect(g.envelopes.first { $0.row == 2 && $0.column == 2 }?.alive == false)
        #expect(g.envelopes.first { $0.row == 1 && $0.column == 2 }?.alive == true)
        #expect(g.remaining == g.total - 1)
        #expect(g.shots.isEmpty)
    }

    @Test func rowsAreWorthMoreHigherUp() {
        #expect(InboxGame.points(row: 0, rows: 3) == 30)
        #expect(InboxGame.points(row: 1, rows: 3) == 20)
        #expect(InboxGame.points(row: 2, rows: 3) == 10)
        #expect(InboxGame.points(row: 2, rows: 4) == 20)
        #expect(InboxGame.points(row: 3, rows: 4) == 10)
    }

    @Test func hitsInARowBuildAMultiplier() {
        #expect(InboxGame.multiplier(streak: 0) == 1)
        #expect(InboxGame.multiplier(streak: 4) == 1)
        #expect(InboxGame.multiplier(streak: 5) == 2)
        #expect(InboxGame.multiplier(streak: 10) == 3)
        #expect(InboxGame.multiplier(streak: 20) == 4)
        #expect(InboxGame.multiplier(streak: 99) == 4)
        var g = frozen()
        g.streak = 4                                                  // this hit makes five
        g.playerX = columnX(g, 0)
        g.fire()
        run(&g, seconds: 2, until: { if case .answered = $0 { return true }; return false })
        #expect(g.streak == 5)
        #expect(g.score == 20)                                        // 10 x2
    }

    @Test func aReplyKnocksAFallingDemandOutOfTheAir() {
        var g = frozen()
        g.playerX = InboxGame.playerMaxX
        g.clips = [InboxShot(x: InboxGame.playerMaxX, y: 50)]
        g.fire()
        let events = run(&g, seconds: 1, until: { if case .blocked = $0 { return true }; return false })
        #expect(events.contains { if case .blocked = $0 { return true }; return false })
        #expect(g.clips.isEmpty && g.shots.isEmpty)
    }

    @Test func urgentArrivesAndIsWorthAlot() {
        var g = InboxGame()
        g.introTimer = 0
        g.fireTimer = 1_000
        g.urgentTimer = 0
        var rng = SeededRNG(seed: 3)
        let events = g.update(dt: frame, move: 0, fire: false, rng: &rng)
        #expect(events.contains(.urgentArrived))
        #expect(g.urgent != nil && g.urgentsThisWave == 1)
        // Freeze it overhead and answer it.
        g.introTimer = 1_000
        g.keepOnly([(row: 0, column: 0)])                             // nothing else in the way
        g.urgent = InboxUrgent(x: InboxGame.playerMaxX, direction: 1)
        g.playerX = InboxGame.playerMaxX
        g.fire()
        let hit = run(&g, seconds: 2, until: { if case .urgentAnswered = $0 { return true }; return false })
        #expect(hit.contains { if case .urgentAnswered(_, _, points: InboxGame.urgentPoints) = $0 { return true }; return false })
        #expect(g.urgent == nil)
        #expect(g.score == InboxGame.urgentPoints)
    }

    // MARK: Formation

    @Test func formationStepsSidewaysThenDropsAndTurnsAtAnEdge() {
        var g = InboxGame()
        var ev: [InboxEvent] = []
        let x0 = g.formationX, y0 = g.formationY
        g.step(&ev)
        #expect(g.formationX == x0 + InboxGame.stepX && g.formationY == y0)
        #expect(ev == [.step(1)])
        // Push it against the right edge: the next step is down, and it turns around.
        g.formationX = InboxGame.width - InboxGame.sideMargin - InboxGame.envelopeHalfWidth
            - Double(InboxGame.columns - 1) * InboxGame.spacingX - 1
        ev = []
        g.step(&ev)
        #expect(ev == [.descended])
        #expect(g.formationY == y0 + InboxGame.stepDown)
        #expect(g.direction == -1)
    }

    @Test func theEdgeUsesTheEnvelopesStillStanding() {
        var g = InboxGame()
        g.keepOnly([(row: 0, column: 0)])                             // only the leftmost column left
        g.formationX = 60
        var ev: [InboxEvent] = []
        g.step(&ev)                                                   // far from the right edge now
        #expect(ev == [.step(1)])
    }

    @Test func theMarchSpeedsUpAsEnvelopesAreAnswered() {
        var g = InboxGame()
        let full = g.stepInterval
        g.keepOnly([(row: 0, column: 0)])
        #expect(g.stepInterval < full * 0.5)
        #expect(InboxGame(wave: 2).stepInterval < InboxGame(wave: 1).stepInterval)
    }

    @Test func theFormationWaitsDuringTheWaveIntro() {
        var g = InboxGame()
        let x0 = g.formationX
        run(&g, seconds: InboxGame.waveIntro - 0.2)
        #expect(g.formationX == x0)
        run(&g, seconds: 1.5)
        #expect(g.formationX != x0)
    }

    // MARK: Demands and the tray

    @Test func demandsDropFromTheLowestEnvelopeNearestTheTray() {
        var g = InboxGame()
        g.playerX = columnX(g, 3)
        var rng = SeededRNG(seed: 1)
        let shooter = g.chooseShooter(aimed: true, rng: &rng)
        #expect(shooter?.column == 3 && shooter?.row == 2)
        g.keepOnly([(row: 0, column: 3)])
        #expect(g.chooseShooter(aimed: true, rng: &rng)?.row == 0)    // only the top one left in that column
    }

    @Test func enemyFireRespectsTheLimitOnScreen() {
        var g = InboxGame()
        g.introTimer = 0
        g.urgentTimer = 1_000
        g.fireTimer = 0
        g.clips = [InboxShot(x: 5, y: 10)]                            // wave 1 allows one at a time
        var rng = SeededRNG(seed: 9)
        var ev = g.update(dt: frame, move: 0, fire: false, rng: &rng)
        #expect(!ev.contains(.enemyFired))
        g.clips = []
        g.fireTimer = 0
        ev = g.update(dt: frame, move: 0, fire: false, rng: &rng)
        #expect(ev.contains(.enemyFired))
        #expect(g.clips.count == 1)
        #expect(g.fireTimer > 0)
    }

    @Test func aDemandHittingTheTrayCostsATrayAndPauses() {
        var g = frozen()
        g.streak = 7
        g.clips = [InboxShot(x: g.playerX, y: 75)]
        let events = run(&g, seconds: 1, until: { if case .playerHit = $0 { return true }; return false })
        #expect(events.contains(.playerHit(livesLeft: 2)))
        #expect(g.lives == 2 && g.streak == 0 && !g.isOver)
        #expect(g.clips.isEmpty && g.pauseTimer > 0 && g.invulnerable > 0)
        let fired7 = g.fire()
        #expect(!fired7)                                            // no replies while recovering
        // A second demand during the blink passes harmlessly.
        g.clips = [InboxShot(x: g.playerX, y: 80)]
        run(&g, seconds: 0.5)
        #expect(g.lives == 2)
    }

    @Test func aMissedDemandFallsAwayHarmlessly() {
        var g = frozen()
        g.playerX = InboxGame.playerMinX
        g.clips = [InboxShot(x: 100, y: 80)]
        run(&g, seconds: 1)
        #expect(g.clips.isEmpty && g.lives == InboxGame.startingLives)
    }

    // MARK: Waves and endings

    @Test func answeringTheLastEnvelopeReachesInboxZero() {
        var g = frozen()
        g.keepOnly([(row: 2, column: 2)])
        g.playerX = columnX(g, 2)
        g.fire()
        let events = run(&g, seconds: 2, until: { if case .waveCleared = $0 { return true }; return false })
        #expect(events.contains(.waveCleared(bonus: InboxGame.waveBonus(wave: 1), nextWave: 2)))
        #expect(g.wave == 2)
        #expect(g.score == 10 + InboxGame.waveBonus(wave: 1))
        #expect(g.rowCount == 4 && g.remaining == 4 * InboxGame.columns)
        #expect(g.formationY == InboxGame.startY(wave: 2))
        #expect(g.introTimer == InboxGame.waveIntro)
        #expect(g.shots.isEmpty && g.clips.isEmpty && g.urgent == nil)
    }

    @Test func losingTheLastTrayEndsTheRun() {
        var g = frozen()
        g.lives = 1
        g.clips = [InboxShot(x: g.playerX, y: 80)]
        let events = run(&g, seconds: 1, until: { if case .gameOver = $0 { return true }; return false })
        #expect(events.contains(.gameOver(.outOfOffice)))
        #expect(g.isOver && g.ending == .outOfOffice && g.lives == 0)
        var rng = SeededRNG(seed: 2)
        let after = g.update(dt: 0.1, move: 1, fire: true, rng: &rng)
        #expect(after.isEmpty)                                        // nothing moves after
        let fired8 = g.fire()
        #expect(!fired8)
    }

    @Test func envelopesReachingTheLineFillTheInbox() {
        var g = InboxGame()
        // Lowest row 1 unit short of the line, pressed against the right edge.
        g.formationY = InboxGame.landingY - 1 - InboxGame.envelopeHalfHeight - Double(g.rowCount - 1) * InboxGame.spacingY
        g.formationX = InboxGame.width - InboxGame.sideMargin - InboxGame.envelopeHalfWidth
            - Double(InboxGame.columns - 1) * InboxGame.spacingX - 1
        #expect(g.isInDanger)
        var ev: [InboxEvent] = []
        g.step(&ev)
        #expect(ev == [.descended, .gameOver(.inboxFull)])
        #expect(g.ending == .inboxFull)
    }

    @Test func difficultyRisesGraduallyAndLevelsOff() {
        #expect(InboxGame.rows(wave: 1) == 3 && InboxGame.rows(wave: 2) == 4 && InboxGame.rows(wave: 9) == 4)
        for w in 1..<12 {
            #expect(InboxGame.baseStepInterval(wave: w + 1) <= InboxGame.baseStepInterval(wave: w))
            #expect(InboxGame.fireGap(wave: w + 1) <= InboxGame.fireGap(wave: w))
            #expect(InboxGame.clipSpeed(wave: w + 1) >= InboxGame.clipSpeed(wave: w))
            #expect(InboxGame.maxClips(wave: w + 1) >= InboxGame.maxClips(wave: w))
            #expect(InboxGame.startY(wave: w + 1) >= InboxGame.startY(wave: w))
            // no cliff: each wave's march is at most ~10% quicker than the last
            #expect(InboxGame.baseStepInterval(wave: w + 1) >= InboxGame.baseStepInterval(wave: w) * 0.89)
        }
        #expect(InboxGame.maxClips(wave: 1) == 1)
        #expect(InboxGame.maxClips(wave: 30) == 3)
        #expect(InboxGame.baseStepInterval(wave: 50) == 0.22)
        #expect(InboxGame.clipSpeed(wave: 50) == 50)
        #expect(InboxGame.startY(wave: 50) == InboxGame.startY(wave: 5))
        // even the latest wave starts with room to play
        let late = InboxGame(wave: 50)
        #expect(!late.isInDanger)
    }
}
