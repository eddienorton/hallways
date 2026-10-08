import Foundation

// Oct 7 -- INBOX ZERO (office computer): the fixed shooter.
// Pure rules, no SwiftUI, no timers, no persistence. The session drives time
// through update(dt:), so the game simply does not advance while nobody is
// looking at it.
//
// A formation of envelopes marches back and forth across the top of the
// field, dropping a row every time it reaches a side. You are the out-tray
// along the bottom: slide left and right and fire replies upward. Each reply
// that lands answers (removes) an envelope. Envelopes drop "!" demands at
// you; a reply can also knock a "!" out of the air. Answer every envelope and
// you reach inbox zero -- the next wave arrives a little lower, a little
// faster, a little pushier. Lose all three trays ("Out of office.") or let
// the envelopes reach the line above you ("Inbox full.") and the run is over.
//
// Accuracy matters: hits in a row build a streak (x2 at 5, x3 at 10, x4 at
// 20); a reply that flies off the top answers nothing and resets it.
//
// Field units: 120 wide x 100 tall, (0,0) top-left, y grows downward.

nonisolated struct InboxShot: Equatable, Sendable {
    var x: Double
    var y: Double
}

nonisolated struct InboxEnvelope: Equatable, Sendable {
    let row: Int               // 0 = top of the formation
    let column: Int
    var alive = true
}

/// The red URGENT envelope that occasionally crosses above the formation.
nonisolated struct InboxUrgent: Equatable, Sendable {
    var x: Double
    var direction: Double      // +1 moving right, -1 moving left
}

nonisolated enum InboxEnding: Equatable, Sendable {
    case inboxFull             // the formation reached the line
    case outOfOffice           // no trays left
}

/// What happened during one update, for the session's sound and effects.
nonisolated enum InboxEvent: Equatable, Sendable {
    case fired
    case answered(row: Int, x: Double, y: Double, points: Int, streak: Int)
    case blocked(x: Double, y: Double)                 // a reply knocked out a "!"
    case missed(streakLost: Int)                       // a reply left the top
    case urgentArrived
    case urgentAnswered(x: Double, y: Double, points: Int)
    case urgentGone
    case step(Int)                                     // formation stepped sideways (parity)
    case descended
    case enemyFired
    case playerHit(livesLeft: Int)
    case waveCleared(bonus: Int, nextWave: Int)
    case gameOver(InboxEnding)
}

nonisolated struct InboxGame: Sendable {
    // MARK: Field and pieces

    static let width = 120.0
    static let height = 100.0

    static let playerY = 91.0                  // centre of the tray
    static let playerHalfWidth = 6.0
    static let playerHalfHeight = 3.5
    static let playerSpeed = 62.0              // units/s (edge to edge in ~1.7 s)
    static let playerMinX = 7.0
    static let playerMaxX = 113.0

    static let columns = 6
    static let spacingX = 16.0
    static let spacingY = 12.0
    static let envelopeHalfWidth = 5.5
    static let envelopeHalfHeight = 4.0
    static let stepX = 2.0
    static let stepDown = 3.0
    static let sideMargin = 3.0
    /// An envelope's bottom edge reaching this line = inbox full.
    static let landingY = 84.0

    static let shotSpeed = 125.0
    static let maxShots = 2
    static let fireCooldown = 0.22
    static let shotHalfWidth = 0.9
    static let shotLength = 6.0

    static let clipHalfWidth = 1.5
    static let clipLength = 6.0

    static let urgentY = 6.0
    static let urgentSpeed = 28.0
    static let urgentHalfWidth = 6.5
    static let urgentHalfHeight = 4.5
    static let urgentPoints = 150
    static let urgentsPerWave = 2

    static let startingLives = 3
    static let waveIntro = 2.0                 // formation holds still while "Wave N" shows
    static let hitPause = 1.0                  // everything above you holds after you're hit
    static let invulnerableTime = 2.2

    // MARK: Per-wave tuning (gentle at first, steadily pushier)

    static func rows(wave: Int) -> Int { wave <= 1 ? 3 : 4 }
    static func startY(wave: Int) -> Double { 16 + Double(min(max(wave - 1, 0), 4)) * 3 }
    static func baseStepInterval(wave: Int) -> Double { max(0.22, 0.55 * pow(0.9, Double(max(wave - 1, 0)))) }
    static func maxClips(wave: Int) -> Int { min(3, 1 + wave / 2) }
    static func fireGap(wave: Int) -> Double { max(0.7, 2.0 * pow(0.88, Double(max(wave - 1, 0)))) }
    static func clipSpeed(wave: Int) -> Double { min(50, 32 + 3 * Double(max(wave - 1, 0))) }
    static func aimChance(wave: Int) -> Double { min(0.7, 0.35 + 0.07 * Double(max(wave - 1, 0))) }
    static func points(row: Int, rows: Int) -> Int { row == 0 ? 30 : (row == rows - 1 ? 10 : 20) }
    static func multiplier(streak: Int) -> Int { streak >= 20 ? 4 : streak >= 10 ? 3 : streak >= 5 ? 2 : 1 }
    static func waveBonus(wave: Int) -> Int { 100 * wave }

    // MARK: State

    var wave = 1
    var score = 0
    var lives = InboxGame.startingLives
    var streak = 0
    var ending: InboxEnding?
    var isOver: Bool { ending != nil }

    var playerX = InboxGame.width / 2
    var shots: [InboxShot] = []
    var clips: [InboxShot] = []                // the falling "!" demands
    var urgent: InboxUrgent?

    var envelopes: [InboxEnvelope] = []
    var rowCount = 3
    var formationX = 0.0                       // centre x of column 0
    var formationY = 0.0                       // centre y of row 0
    var direction = 1.0
    var stepTimer = 0.0
    var stepCount = 0

    var cooldown = 0.0
    var fireTimer = 0.0
    var urgentTimer = 0.0
    var urgentsThisWave = 0
    var introTimer = 0.0
    var pauseTimer = 0.0
    var invulnerable = 0.0

    init(wave: Int = 1) {
        self.wave = max(1, wave)
        setUpWave()
    }

    // MARK: Queries

    var remaining: Int { envelopes.reduce(0) { $0 + ($1.alive ? 1 : 0) } }
    var total: Int { envelopes.count }
    var multiplier: Int { Self.multiplier(streak: streak) }
    var isHolding: Bool { introTimer > 0 || pauseTimer > 0 }

    func center(of e: InboxEnvelope) -> (x: Double, y: Double) {
        (formationX + Double(e.column) * Self.spacingX, formationY + Double(e.row) * Self.spacingY)
    }

    /// Bottom edge of the lowest envelope still standing.
    var lowestBottom: Double? {
        guard let row = envelopes.filter(\.alive).map(\.row).max() else { return nil }
        return formationY + Double(row) * Self.spacingY + Self.envelopeHalfHeight
    }

    /// The envelopes are within a couple of drops of the line.
    var isInDanger: Bool {
        guard !isOver, let b = lowestBottom else { return false }
        return Self.landingY - b <= 3 * Self.stepDown + 0.01
    }

    var stepInterval: Double {
        let fraction = total == 0 ? 0 : Double(remaining) / Double(total)
        return Self.baseStepInterval(wave: wave) * (0.3 + 0.7 * fraction)
    }

    var canFire: Bool { !isOver && pauseTimer <= 0 && cooldown <= 0 && shots.count < Self.maxShots }

    // MARK: Actions

    /// Send a reply up from the tray. False if the tray isn't ready.
    @discardableResult
    mutating func fire() -> Bool {
        guard canFire else { return false }
        shots.append(InboxShot(x: playerX, y: Self.playerY - Self.playerHalfHeight - Self.shotLength / 2))
        cooldown = Self.fireCooldown
        return true
    }

    /// Advance the game by `dt` seconds. `move` is -1, 0 or +1; `fire` means
    /// the fire control is held (a reply goes out whenever the tray is ready).
    mutating func update<R: RandomNumberGenerator>(dt rawDt: Double, move: Int, fire wantsFire: Bool, rng: inout R) -> [InboxEvent] {
        guard !isOver else { return [] }
        let dt = max(0, min(rawDt, 0.1))
        var events: [InboxEvent] = []

        playerX = min(Self.playerMaxX, max(Self.playerMinX, playerX + Double(move.signum()) * Self.playerSpeed * dt))
        cooldown = max(0, cooldown - dt)
        invulnerable = max(0, invulnerable - dt)
        if wantsFire, fire() { events.append(.fired) }

        moveShots(dt, &events)
        if remaining == 0 {
            let bonus = Self.waveBonus(wave: wave)
            score += bonus
            wave += 1
            setUpWave()
            events.append(.waveCleared(bonus: bonus, nextWave: wave))
            return events
        }

        if introTimer > 0 {
            introTimer = max(0, introTimer - dt)
        } else if pauseTimer > 0 {
            pauseTimer = max(0, pauseTimer - dt)
        } else {
            advanceFormation(dt, &events)
            if isOver { return events }
            enemyFire(dt, &rng, &events)
            advanceUrgent(dt, &rng, &events)
        }
        moveClips(dt, &events)
        return events
    }

    /// Testing: leave only these envelopes standing.
    mutating func keepOnly(_ cells: [(row: Int, column: Int)]) {
        envelopes = envelopes.map { e in
            var e = e
            e.alive = cells.contains { $0.row == e.row && $0.column == e.column }
            return e
        }
    }

    // MARK: Wave

    private mutating func setUpWave() {
        rowCount = Self.rows(wave: wave)
        envelopes = (0..<rowCount).flatMap { r in (0..<Self.columns).map { c in InboxEnvelope(row: r, column: c) } }
        formationX = (Self.width - Double(Self.columns - 1) * Self.spacingX) / 2
        formationY = Self.startY(wave: wave)
        direction = 1
        stepTimer = 0
        stepCount = 0
        shots.removeAll()
        clips.removeAll()
        urgent = nil
        urgentsThisWave = 0
        introTimer = Self.waveIntro
        pauseTimer = 0
        fireTimer = wave == 1 ? 2.5 : 1.5
        urgentTimer = 13
    }

    // MARK: Replies (player shots)

    private mutating func moveShots(_ dt: Double, _ events: inout [InboxEvent]) {
        var kept: [InboxShot] = []
        for var shot in shots {
            // The span of field this reply sweeps through this frame (so a
            // fast reply can never skip over an envelope between frames).
            let sweptBottom = shot.y + Self.shotLength / 2
            shot.y -= Self.shotSpeed * dt
            let sweptTop = shot.y - Self.shotLength / 2

            // 1. A falling "!" in the way.
            if let k = clips.firstIndex(where: { c in
                abs(c.x - shot.x) <= Self.clipHalfWidth + Self.shotHalfWidth + 0.6
                    && c.y - Self.clipLength / 2 <= sweptBottom && c.y + Self.clipLength / 2 >= sweptTop
            }) {
                let c = clips.remove(at: k)
                events.append(.blocked(x: c.x, y: c.y))
                continue
            }

            // 2. The lowest envelope the reply passes through.
            var best: Int?
            var bestY = -Double.infinity
            for (i, e) in envelopes.enumerated() where e.alive {
                let p = center(of: e)
                guard abs(p.x - shot.x) <= Self.envelopeHalfWidth + Self.shotHalfWidth,
                      p.y - Self.envelopeHalfHeight <= sweptBottom, p.y + Self.envelopeHalfHeight >= sweptTop else { continue }
                if p.y > bestY { bestY = p.y; best = i }
            }
            if let i = best {
                envelopes[i].alive = false
                streak += 1
                let pts = Self.points(row: envelopes[i].row, rows: rowCount) * multiplier
                score += pts
                let p = center(of: envelopes[i])
                events.append(.answered(row: envelopes[i].row, x: p.x, y: p.y, points: pts, streak: streak))
                continue
            }

            // 3. The URGENT envelope.
            if let u = urgent,
               abs(u.x - shot.x) <= Self.urgentHalfWidth + Self.shotHalfWidth,
               Self.urgentY - Self.urgentHalfHeight <= sweptBottom, Self.urgentY + Self.urgentHalfHeight >= sweptTop {
                streak += 1
                let pts = Self.urgentPoints * multiplier
                score += pts
                urgent = nil
                events.append(.urgentAnswered(x: u.x, y: Self.urgentY, points: pts))
                continue
            }

            // 4. Off the top: a miss.
            if shot.y + Self.shotLength / 2 < 0 {
                let lost = streak
                streak = 0
                events.append(.missed(streakLost: lost))
                continue
            }
            kept.append(shot)
        }
        shots = kept
    }

    // MARK: Formation

    private mutating func advanceFormation(_ dt: Double, _ events: inout [InboxEvent]) {
        stepTimer += dt
        var steps = 0
        while stepTimer >= stepInterval, steps < 3, !isOver {
            stepTimer -= stepInterval
            step(&events)
            steps += 1
        }
    }

    /// One formation step: sideways, or -- at a side -- down a row and turn around.
    mutating func step(_ events: inout [InboxEvent]) {
        let xs = envelopes.filter(\.alive).map { center(of: $0).x }
        guard let minX = xs.min(), let maxX = xs.max() else { return }
        let nextMin = minX - Self.envelopeHalfWidth + direction * Self.stepX
        let nextMax = maxX + Self.envelopeHalfWidth + direction * Self.stepX
        if nextMin < Self.sideMargin || nextMax > Self.width - Self.sideMargin {
            formationY += Self.stepDown
            direction = -direction
            events.append(.descended)
            if let b = lowestBottom, b >= Self.landingY {
                ending = .inboxFull
                shots.removeAll()
                clips.removeAll()
                events.append(.gameOver(.inboxFull))
            }
        } else {
            formationX += direction * Self.stepX
            stepCount += 1
            events.append(.step(stepCount % 2))
        }
    }

    // MARK: "!" demands (enemy shots)

    private mutating func enemyFire<R: RandomNumberGenerator>(_ dt: Double, _ rng: inout R, _ events: inout [InboxEvent]) {
        fireTimer -= dt
        guard fireTimer <= 0 else { return }
        fireTimer = Self.fireGap(wave: wave) * Double.random(in: 0.7...1.3, using: &rng)
        guard clips.count < Self.maxClips(wave: wave) else { return }
        let aimed = Double.random(in: 0..<1, using: &rng) < Self.aimChance(wave: wave)
        guard let shooter = chooseShooter(aimed: aimed, rng: &rng) else { return }
        let p = center(of: shooter)
        clips.append(InboxShot(x: p.x, y: p.y + Self.envelopeHalfHeight + Self.clipLength / 2))
        events.append(.enemyFired)
    }

    /// The lowest standing envelope in a column: the one nearest the tray if
    /// `aimed`, otherwise in a random column.
    func chooseShooter<R: RandomNumberGenerator>(aimed: Bool, rng: inout R) -> InboxEnvelope? {
        let alive = envelopes.filter(\.alive)
        let columns = Array(Set(alive.map(\.column))).sorted()
        guard !columns.isEmpty else { return nil }
        let column: Int
        if aimed {
            column = columns.min { a, b in
                abs(formationX + Double(a) * Self.spacingX - playerX) < abs(formationX + Double(b) * Self.spacingX - playerX)
            }!
        } else {
            column = columns.randomElement(using: &rng)!
        }
        return alive.filter { $0.column == column }.max { $0.row < $1.row }
    }

    private mutating func moveClips(_ dt: Double, _ events: inout [InboxEvent]) {
        var kept: [InboxShot] = []
        let speed = Self.clipSpeed(wave: wave)
        var hit = false
        for var c in clips {
            let oldTop = c.y - Self.clipLength / 2
            c.y += speed * dt
            let bottom = c.y + Self.clipLength / 2
            if !hit, invulnerable <= 0,
               abs(c.x - playerX) <= Self.playerHalfWidth + Self.clipHalfWidth,
               oldTop <= Self.playerY + Self.playerHalfHeight, bottom >= Self.playerY - Self.playerHalfHeight {
                hit = true
                continue
            }
            if c.y - Self.clipLength / 2 > Self.height { continue }
            kept.append(c)
        }
        clips = kept
        if hit { playerHit(&events) }
    }

    private mutating func playerHit(_ events: inout [InboxEvent]) {
        lives -= 1
        streak = 0
        clips.removeAll()
        shots.removeAll()
        events.append(.playerHit(livesLeft: lives))
        if lives <= 0 {
            ending = .outOfOffice
            events.append(.gameOver(.outOfOffice))
        } else {
            pauseTimer = Self.hitPause
            invulnerable = Self.invulnerableTime
        }
    }

    // MARK: URGENT

    private mutating func advanceUrgent<R: RandomNumberGenerator>(_ dt: Double, _ rng: inout R, _ events: inout [InboxEvent]) {
        if var u = urgent {
            u.x += u.direction * Self.urgentSpeed * dt
            if u.x < -Self.urgentHalfWidth - 4 || u.x > Self.width + Self.urgentHalfWidth + 4 {
                urgent = nil
                events.append(.urgentGone)
            } else {
                urgent = u
            }
            return
        }
        urgentTimer -= dt
        guard urgentTimer <= 0 else { return }
        urgentTimer = Double.random(in: 14...22, using: &rng)
        guard urgentsThisWave < Self.urgentsPerWave, remaining >= 4 else { return }
        let fromLeft = Bool.random(using: &rng)
        urgent = InboxUrgent(x: fromLeft ? -Self.urgentHalfWidth : Self.width + Self.urgentHalfWidth, direction: fromLeft ? 1 : -1)
        urgentsThisWave += 1
        events.append(.urgentArrived)
    }
}
