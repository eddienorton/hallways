import SwiftUI
import Combine

// Oct 7 -- INBOX ZERO on the office computer: the fixed shooter.
//
// Layout for the ~482 x 204 game area -- the same game-controller shape as
// Paper Jam, so no control ever sits on the field and nothing needs aiming:
//
//   [ score  wave  trays ]   [   field   ]   [ New run   streak ]
//   [     <       >      ]   [ 120 x 100 ]   [       FIRE       ]
//
// Left hand steers (hold < or > to keep sliding); right hand fires (tap for
// one reply, hold to keep replying whenever the tray is ready). Every control
// acts on touch-DOWN and is a big separate block; the field takes no input.
// All of it lives on the monitor's own surface, so nothing leaks into the room.
//
// Time only passes while the game is on screen (and the app is active): the
// session's clock ticks from the view and stops the moment the view goes
// away or the "?" card is up; on return there's a short beat before anything
// moves. Session: retained by OfficeComputer.games.

struct InboxParticle {
    var x: Double, y: Double, vx: Double, vy: Double
    var born: Double
    var life: Double
    var size: Double
    var color: Color
}

struct InboxPopup {
    var x: Double, y: Double
    var text: String
    var born: Double
    var color: Color
    var big: Bool
}

struct InboxCallout: Equatable {
    var title: String
    var subtitle: String?
    var until: Double
}

final class InboxZeroSession: ObservableObject {
    /// Best score this app run (no disk).
    static var bestScore = 0

    @Published private(set) var game = InboxGame()
    @Published private(set) var clock = 0.0                   // game time: stops whenever the game does
    @Published private(set) var particles: [InboxParticle] = []
    @Published private(set) var popups: [InboxPopup] = []
    @Published private(set) var callout: InboxCallout?
    @Published private(set) var hitFlashAt: Double?
    @Published private(set) var clearFlashAt: Double?
    @Published private(set) var shakes: CGFloat = 0
    @Published private(set) var newBest = false
    @Published var confirmingNew = false

    var leftHeld = false
    var rightHeld = false
    var fireHeld = false

    private var rng = SystemRandomNumberGenerator()
    private var lastTick: Date?
    private var resumeAt: Date?
    private var visible = false
    private var urgentPing = 0.0

    init() {
        InboxZeroSound.warmUp()
        InboxZeroSound.play(.newRun)
    }

    var inProgress: Bool { !game.isOver && (game.score > 0 || game.wave > 1) }

    // MARK: Clock (only while visible)

    func appeared() {
        visible = true
        lastTick = nil
        resumeAt = Date().addingTimeInterval(0.6)               // a beat to get your bearings
    }

    func disappeared() {
        visible = false
        lastTick = nil
        releaseAll()
    }

    /// Frozen this frame (e.g. the "?" card is up): no time passes, and play
    /// resumes after a short beat.
    func hold() {
        lastTick = nil
        resumeAt = Date().addingTimeInterval(0.5)
    }

    func releaseAll() {
        leftHeld = false
        rightHeld = false
        fireHeld = false
    }

    func tick(now: Date = Date()) {
        defer { lastTick = now }
        guard visible, let last = lastTick else { return }
        if let r = resumeAt, now < r { return }
        resumeAt = nil
        let dt = min(now.timeIntervalSince(last), 0.1)
        guard dt > 0 else { return }
        clock += dt
        if !game.isOver {
            let move = (rightHeld ? 1 : 0) - (leftHeld ? 1 : 0)
            let events = game.update(dt: dt, move: move, fire: fireHeld, rng: &rng)
            handle(events)
            if game.urgent != nil {
                urgentPing += dt
                if urgentPing >= 0.55 { urgentPing = 0; InboxZeroSound.play(.urgentPing) }
            } else {
                urgentPing = 0
            }
        }
        particles.removeAll { clock - $0.born > $0.life }
        popups.removeAll { clock - $0.born > 0.75 }
        if let c = callout, clock > c.until { withAnimation(.easeIn(duration: 0.2)) { callout = nil } }
    }

    // MARK: Controls

    /// Fire the moment the button goes down (no waiting for the next frame).
    func firePressed() {
        fireHeld = true
        guard visible, resumeAt == nil, !game.isOver else { return }
        if game.fire() { InboxZeroSound.play(.fire) }
    }

    // MARK: Events -> sound and effects

    private func handle(_ events: [InboxEvent]) {
        for event in events {
            switch event {
            case .fired:
                InboxZeroSound.play(.fire)
            case .answered(let row, let x, let y, let points, let streak):
                InboxZeroSound.play(.hit(min(streak - 1, InboxZeroSound.hitLevels)))
                burst(x: x, y: y, color: InboxZeroPalette.envelope(row: row, rows: game.rowCount), count: 7, speed: 26)
                let mult = InboxGame.multiplier(streak: streak)
                if mult > InboxGame.multiplier(streak: streak - 1) {
                    popups.append(InboxPopup(x: x, y: y - 4, text: "\u{00D7}\(mult)!", born: clock, color: InboxZeroPalette.gold, big: true))
                } else if mult > 1 {
                    popups.append(InboxPopup(x: x, y: y - 4, text: "+\(points)", born: clock, color: .white, big: false))
                }
            case .blocked(let x, let y):
                InboxZeroSound.play(.tink)
                burst(x: x, y: y, color: InboxZeroPalette.demand, count: 4, speed: 18)
            case .missed(let lost):
                if lost >= 5 { InboxZeroSound.play(.streakLost) }
            case .urgentArrived:
                urgentPing = 0
                InboxZeroSound.play(.urgentPing)
            case .urgentAnswered(let x, let y, let points):
                InboxZeroSound.play(.urgentHit)
                burst(x: x, y: y, color: InboxZeroPalette.urgent, count: 12, speed: 34)
                burst(x: x, y: y, color: InboxZeroPalette.gold, count: 6, speed: 22)
                popups.append(InboxPopup(x: x, y: y + 6, text: "+\(points)", born: clock, color: InboxZeroPalette.gold, big: true))
            case .urgentGone:
                break
            case .step(let p):
                InboxZeroSound.play(.step(p))
            case .descended:
                InboxZeroSound.play(.descend)
            case .enemyFired:
                InboxZeroSound.play(.enemyFire)
            case .playerHit:
                InboxZeroSound.play(.playerHit)
                burst(x: game.playerX, y: InboxGame.playerY, color: InboxZeroPalette.tray, count: 10, speed: 30)
                hitFlashAt = clock
                withAnimation(.linear(duration: 0.35)) { shakes += 1 }
            case .waveCleared(let bonus, _):
                InboxZeroSound.play(.waveClear)
                clearFlashAt = clock
                show("Inbox zero!", "+\(bonus)", for: 1.0)
            case .gameOver:
                newBest = game.score > Self.bestScore && game.score > 0
                Self.bestScore = max(Self.bestScore, game.score)
                releaseAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { InboxZeroSound.play(.over) }
            }
        }
    }

    private func burst(x: Double, y: Double, color: Color, count: Int, speed: Double) {
        for k in 0..<count {
            let a = Double(k) / Double(count) * 2 * .pi + Double.random(in: -0.3...0.3)
            let v = speed * Double.random(in: 0.6...1.2)
            particles.append(InboxParticle(x: x, y: y, vx: cos(a) * v, vy: sin(a) * v - 10, born: clock,
                                           life: Double.random(in: 0.35...0.55), size: Double.random(in: 1.4...2.4), color: color))
        }
    }

    private func show(_ title: String, _ subtitle: String?, for seconds: Double) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) {
            callout = InboxCallout(title: title, subtitle: subtitle, until: clock + seconds)
        }
    }
}

enum InboxZeroPalette {
    static let field = Color(red: 0.10, green: 0.13, blue: 0.20)
    static let fieldLow = Color(red: 0.13, green: 0.17, blue: 0.26)
    static let frame = Color(red: 0.32, green: 0.36, blue: 0.44)
    static let danger = Color(red: 0.88, green: 0.27, blue: 0.24)
    static let control = Color(red: 0.28, green: 0.34, blue: 0.46)
    static let accent = Color(red: 0.2, green: 0.62, blue: 0.62)
    static let tray = Color(red: 0.42, green: 0.86, blue: 0.78)
    static let reply = Color(red: 0.88, green: 1.0, blue: 0.96)
    static let demand = Color(red: 1.0, green: 0.62, blue: 0.22)
    static let urgent = Color(red: 0.93, green: 0.28, blue: 0.26)
    static let gold = Color(red: 1.0, green: 0.83, blue: 0.35)

    /// Top row lilac (30), middle rows sky (20), bottom row manila (10).
    static func envelope(row: Int, rows: Int) -> Color {
        if row == 0 { return Color(red: 0.76, green: 0.64, blue: 0.97) }
        if row == rows - 1 { return Color(red: 0.97, green: 0.87, blue: 0.62) }
        return Color(red: 0.55, green: 0.8, blue: 0.97)
    }
}

struct InboxZeroComputerGame: View {
    let restart: () -> Void
    @ObservedObject var session: InboxZeroSession
    @Environment(\.scenePhase) private var scenePhase

    init(restart: @escaping () -> Void, session: InboxZeroSession) {
        self.restart = restart
        _session = ObservedObject(wrappedValue: session)
    }

    private var game: InboxGame { session.game }

    var body: some View {
        GeometryReader { geo in
            let fieldH = geo.size.height
            let fieldW = fieldH * CGFloat(InboxGame.width / InboxGame.height)
            let side = (geo.size.width - fieldW - 20) / 2
            HStack(spacing: 10) {
                leftPanel.frame(width: side, height: geo.size.height)
                field.frame(width: fieldW, height: fieldH)
                rightPanel.frame(width: side, height: geo.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { session.appeared() }
        .onDisappear { session.disappeared() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.appeared() } else { session.disappeared() }
        }
        .task {
            while !Task.isCancelled {
                if OfficeComputer.shared.showingHelp { session.hold() } else { session.tick() }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    // MARK: Field

    private var field: some View {
        ZStack {
            Canvas { ctx, size in draw(&ctx, size: size) }
            if let c = session.callout {
                calloutView(c.title, c.subtitle).transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if game.introTimer > 0, !game.isOver {
                calloutView("Wave \(game.wave)", nil).transition(.opacity)
            }
            if game.isOver { gameOverCard }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(game.isInDanger || game.isOver ? InboxZeroPalette.danger : InboxZeroPalette.frame, lineWidth: 3)
            .animation(.easeInOut(duration: 0.3), value: game.isInDanger))
        .modifier(ShakeEffect(travel: 5, animatableData: session.shakes))
    }

    private func calloutView(_ title: String, _ subtitle: String?) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: 20, weight: .black, design: .rounded)).foregroundStyle(.white)
            if let subtitle {
                Text(subtitle).font(.system(size: 14, weight: .heavy, design: .rounded).monospacedDigit()).foregroundStyle(InboxZeroPalette.gold)
            }
        }
        .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        .offset(y: 8)
        .allowsHitTesting(false)
    }

    private var gameOverCard: some View {
        VStack(spacing: 3) {
            Text(game.ending == .inboxFull ? "Inbox full." : "Out of office.")
                .font(.system(size: 19, weight: .black, design: .rounded)).foregroundStyle(.white)
            Text("\(game.score)").font(.system(size: 17, weight: .heavy, design: .rounded).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
            Text(session.newBest ? "New best!" : "Wave \(game.wave)")
                .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(session.newBest ? InboxZeroPalette.gold : .white.opacity(0.7))
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .allowsHitTesting(false)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let s = size.width / InboxGame.width
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        func rect(_ cx: Double, _ cy: Double, _ hw: Double, _ hh: Double) -> CGRect {
            CGRect(x: (cx - hw) * s, y: (cy - hh) * s, width: 2 * hw * s, height: 2 * hh * s)
        }
        let clock = session.clock

        // Desk-dark field.
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [InboxZeroPalette.field, InboxZeroPalette.fieldLow]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

        // The line the envelopes must not reach.
        var line = Path()
        line.move(to: pt(2, InboxGame.landingY))
        line.addLine(to: pt(InboxGame.width - 2, InboxGame.landingY))
        ctx.stroke(line, with: .color(game.isInDanger ? InboxZeroPalette.danger.opacity(0.75) : Color.white.opacity(0.14)),
                   style: StrokeStyle(lineWidth: max(1, 0.5 * s), dash: [3 * s, 2 * s]))

        // Envelopes. The flap flutters with every step of the march.
        let flap = game.stepCount % 2 == 0 ? 0.5 : 0.66
        for e in game.envelopes where e.alive {
            let c = game.center(of: e)
            let r = rect(c.x, c.y, InboxGame.envelopeHalfWidth, InboxGame.envelopeHalfHeight)
            ctx.fill(Path(roundedRect: r, cornerRadius: 1.2 * s), with: .color(InboxZeroPalette.envelope(row: e.row, rows: game.rowCount)))
            var v = Path()
            v.move(to: CGPoint(x: r.minX + 0.6 * s, y: r.minY + 0.6 * s))
            v.addLine(to: CGPoint(x: r.midX, y: r.minY + r.height * flap))
            v.addLine(to: CGPoint(x: r.maxX - 0.6 * s, y: r.minY + 0.6 * s))
            ctx.stroke(v, with: .color(Color.black.opacity(0.38)), style: StrokeStyle(lineWidth: max(1, 0.7 * s), lineCap: .round, lineJoin: .round))
        }

        // URGENT.
        if let u = game.urgent {
            let r = rect(u.x, InboxGame.urgentY, InboxGame.urgentHalfWidth, InboxGame.urgentHalfHeight)
            let pulse = 0.5 + 0.5 * sin(clock * 12)
            ctx.fill(Path(roundedRect: r.insetBy(dx: -1.2 * s, dy: -1.2 * s), cornerRadius: 2 * s), with: .color(InboxZeroPalette.urgent.opacity(0.25 * pulse)))
            ctx.fill(Path(roundedRect: r, cornerRadius: 1.4 * s), with: .color(InboxZeroPalette.urgent))
            drawBang(&ctx, x: u.x, y: InboxGame.urgentY, s: s, color: .white, scale: 1.05)
        }

        // "!" demands falling at you.
        for c in game.clips {
            ctx.fill(Path(roundedRect: rect(c.x, c.y, 2.4, 3.8), cornerRadius: 1.6 * s), with: .color(InboxZeroPalette.demand.opacity(0.22)))
            drawBang(&ctx, x: c.x, y: c.y, s: s, color: InboxZeroPalette.demand, scale: 1)
        }

        // Replies going up.
        for shot in game.shots {
            ctx.fill(Path(roundedRect: rect(shot.x, shot.y + 4, 0.7, 3), cornerRadius: 0.7 * s), with: .color(InboxZeroPalette.reply.opacity(0.22)))
            ctx.fill(Path(roundedRect: rect(shot.x, shot.y, InboxGame.shotHalfWidth, InboxGame.shotLength / 2), cornerRadius: 0.9 * s),
                     with: .color(InboxZeroPalette.reply))
        }

        // The tray (blinks while it's recovering from a hit).
        let blinkOff = game.invulnerable > 0 && Int(clock * 10) % 2 == 0
        if !(game.ending == .outOfOffice) {
            let x = game.playerX, y = InboxGame.playerY
            let alpha = blinkOff ? 0.3 : 1.0
            ctx.fill(Path(roundedRect: rect(x, y + 1, InboxGame.playerHalfWidth, 2.6), cornerRadius: 1.4 * s), with: .color(InboxZeroPalette.tray.opacity(alpha)))
            ctx.fill(Path(roundedRect: rect(x, y - 1.6, InboxGame.playerHalfWidth - 0.6, 0.6), cornerRadius: 0.6 * s), with: .color(Color.white.opacity(0.55 * alpha)))
            ctx.fill(Path(roundedRect: rect(x, y - 3, 1.8, 1.6), cornerRadius: 0.8 * s), with: .color(InboxZeroPalette.tray.opacity(alpha)))
            // ready light: lit when a reply can go out
            let ready = game.canFire
            ctx.fill(Path(ellipseIn: rect(x, y + 1, 1, 1)), with: .color(ready ? Color.white.opacity(0.9 * alpha) : Color.black.opacity(0.3 * alpha)))
        }

        // Paper scraps.
        for p in session.particles {
            let age = clock - p.born
            let k = max(0, 1 - age / p.life)
            let x = p.x + p.vx * age, y = p.y + p.vy * age + 30 * age * age
            ctx.fill(Path(rect(x, y, p.size / 2, p.size / 2)), with: .color(p.color.opacity(k)))
        }

        // Score popups.
        for p in session.popups {
            let age = clock - p.born
            let k = max(0, 1 - age / 0.75)
            let text = Text(p.text).font(.system(size: p.big ? 13 : 10, weight: .heavy, design: .rounded)).foregroundColor(p.color.opacity(k))
            ctx.draw(text, at: pt(p.x, p.y - 10 * age))
        }

        // Flashes: red when you're hit, white when the inbox empties.
        if let t = session.hitFlashAt, clock - t < 0.35 {
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(InboxZeroPalette.danger.opacity(0.35 * (1 - (clock - t) / 0.35))))
        }
        if let t = session.clearFlashAt, clock - t < 0.3 {
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.white.opacity(0.28 * (1 - (clock - t) / 0.3))))
        }
    }

    /// A bold "!": bar over dot, ~6 units tall.
    private func drawBang(_ ctx: inout GraphicsContext, x: Double, y: Double, s: CGFloat, color: Color, scale: Double) {
        let w = 1.25 * scale
        let bar = CGRect(x: (x - w) * s, y: (y - 3 * scale) * s, width: 2 * w * s, height: 3.6 * scale * s)
        ctx.fill(Path(roundedRect: bar, cornerRadius: w * s), with: .color(color))
        let dot = CGRect(x: (x - w) * s, y: (y + 1.3 * scale) * s, width: 2 * w * s, height: 2 * w * s)
        ctx.fill(Path(ellipseIn: dot), with: .color(color))
    }

    // MARK: Panels

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Score").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                Text("\(game.score)").font(.system(size: 22, weight: .black, design: .rounded).monospacedDigit()).foregroundStyle(HallwaysOS.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("Best \(max(InboxZeroSession.bestScore, game.score))")
                    .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
            }
            HStack(spacing: 4) {
                Text("Wave \(game.wave)").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                ForEach(0..<InboxGame.startingLives, id: \.self) { k in
                    trayIcon(lit: k < game.lives)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                HoldPad(icon: "arrowtriangle.left.fill") { down in session.leftHeld = down }
                HoldPad(icon: "arrowtriangle.right.fill") { down in session.rightHeld = down }
            }
            .frame(height: 76)
        }
    }

    private func trayIcon(lit: Bool) -> some View {
        let warn = game.lives == 1 && !game.isOver
        return VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1).frame(width: 4, height: 2.5)
            RoundedRectangle(cornerRadius: 2).frame(width: 13, height: 5)
        }
        .foregroundStyle(lit ? (warn ? InboxZeroPalette.danger : InboxZeroPalette.accent) : HallwaysOS.rule)
    }

    private var rightPanel: some View {
        VStack(spacing: 6) {
            newRunButton.frame(maxWidth: .infinity)
            streakBadge
            Spacer(minLength: 0)
            HoldPad(icon: "paperplane.fill", label: "Fire", tint: InboxZeroPalette.accent) { down in
                if down { session.firePressed() } else { session.fireHeld = false }
            }
            .frame(height: 76)
        }
    }

    private var streakBadge: some View {
        let mult = game.multiplier
        return HStack(spacing: 6) {
            Text("Streak \(game.streak)").font(.system(size: 13, weight: .heavy, design: .rounded).monospacedDigit()).foregroundStyle(HallwaysOS.inkSoft)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 2)
            Text("\u{00D7}\(mult)")
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(mult > 1 ? .white : HallwaysOS.inkSoft)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(mult > 1 ? InboxZeroPalette.accent : Color.clear, in: Capsule())
                .scaleEffect(mult > 1 ? 1.08 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: mult)
        }
    }

    private var newRunButton: some View {
        let confirming = session.confirmingNew
        return Button {
            if !session.inProgress || confirming {
                restart()
            } else {
                withAnimation(.easeOut(duration: 0.12)) { session.confirmingNew = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(.easeIn(duration: 0.2)) { session.confirmingNew = false }
                }
            }
        } label: {
            Text(confirming ? "Tap again" : "New run")
                .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(confirming ? InboxZeroPalette.danger : (game.isOver ? GamePalette.turn : InboxZeroPalette.control),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A big control block that reports down (the moment it's touched) and up.
/// Uses gesture state, so an interrupted touch always reports "up".
private struct HoldPad: View {
    let icon: String
    var label: String? = nil
    var tint: Color = InboxZeroPalette.control
    let changed: (Bool) -> Void

    @GestureState private var down = false

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 22, weight: .bold))
            if let label { Text(label).font(.system(size: 12, weight: .heavy, design: .rounded)) }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tint.opacity(down ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .scaleEffect(down ? 0.95 : 1)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).updating($down) { _, state, _ in state = true })
        .onChange(of: down) { _, isDown in changed(isDown) }
        .onDisappear { if down { changed(false) } }
    }
}
