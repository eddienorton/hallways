import SwiftUI
import Combine

// Oct 7 -- PAPER JAM on the office computer: the falling-block game.
//
// Layout for the ~482 x 204 game area -- a game-controller shape around the
// well, so no button ever sits on the board and nothing needs aiming:
//
//   [ score  level  rows ]   [  8 x 14  ]   [ next   New run ]
//   [  <     v     >     ]   [   well   ]   [  turn   DROP   ]
//
// Left hand moves (hold < or > to keep sliding, hold v to fall faster);
// right hand turns and drops. Every control acts on touch-DOWN (no waiting
// for the finger to lift) and is a big, separate block; the well itself
// takes no input. All of it lives on the monitor's own surface, so nothing
// leaks into the room.
//
// Time only passes while the game is on screen: the session's clock ticks
// from the view, and stops the moment the view goes away; on return there's
// a short beat before the piece starts falling again. Session: retained by
// OfficeComputer.games.

final class PaperJamSession: ObservableObject {
    /// Best score this app run (no disk).
    static var bestScore = 0
    static let lockDelay = 0.5
    static let maxLockResets = 12

    @Published private(set) var game: PaperJamGame
    @Published private(set) var flashRows: [Int] = []
    @Published private(set) var callout: String?
    @Published var confirmingNew = false

    private var rng = SystemRandomNumberGenerator()
    private var fallTimer = 0.0
    private var lockTimer = 0.0
    private var lockResets = 0
    private var dangerTimer = 0.0
    private var lastTick: Date?
    private var resumeAt: Date?
    private var visible = false
    private var calloutToken = 0

    init() {
        var r = SystemRandomNumberGenerator()
        game = PaperJamGame(rng: &r)
        PaperJamSound.warmUp()
        PaperJamSound.play(.newRun)
    }

    var inProgress: Bool { !game.isOver && (game.score > 0 || game.lines > 0) }

    // MARK: Clock (only while visible)

    func appeared() {
        visible = true
        lastTick = nil
        resumeAt = Date().addingTimeInterval(0.6)               // a beat to get your bearings
    }

    func disappeared() {
        visible = false
        lastTick = nil
    }

    /// Frozen this frame (e.g. the "?" card is up): no time passes, and play
    /// resumes after the same short beat as returning to the game.
    func hold() {
        lastTick = nil
        resumeAt = Date().addingTimeInterval(0.5)
    }

    func tick(now: Date = Date()) {
        defer { lastTick = now }
        guard visible, let last = lastTick, !game.isOver, flashRows.isEmpty, game.current != nil else { return }
        if let r = resumeAt, now < r { return }
        resumeAt = nil
        let dt = min(now.timeIntervalSince(last), 0.1)
        if game.isGrounded {
            lockTimer += dt
            if lockTimer >= Self.lockDelay { lockNow() }
        } else {
            lockTimer = 0
            fallTimer += dt
            let interval = game.gravityInterval
            while fallTimer >= interval {
                fallTimer -= interval
                if !game.stepDown() { break }
            }
        }
        if game.stackFraction >= 0.7 {
            dangerTimer += dt
            if dangerTimer >= 1.2 { dangerTimer = 0; PaperJamSound.play(.danger) }
        } else {
            dangerTimer = 0
        }
    }

    // MARK: Controls

    func move(_ dc: Int) {
        guard playable, game.move(by: dc) else { return }
        PaperJamSound.play(.move)
        groundedNudge()
    }

    func rotate() {
        guard playable, game.rotate() else { return }
        PaperJamSound.play(.rotate)
        groundedNudge()
    }

    func softDrop() {
        guard playable else { return }
        if game.stepDown(soft: true) {
            fallTimer = 0
            PaperJamSound.play(.soft)
        }
    }

    func hardDrop() {
        guard playable else { return }
        game.hardDrop()
        PaperJamSound.play(.drop)
        afterLock(alreadyPlayedLock: true)
    }

    private var playable: Bool { visible && !game.isOver && flashRows.isEmpty && game.current != nil }

    /// Moving or turning a resting piece gives it a little more time (a few times).
    private func groundedNudge() {
        if game.isGrounded, lockResets < Self.maxLockResets {
            lockTimer = 0
            lockResets += 1
        }
    }

    private func lockNow() {
        game.lock()
        afterLock(alreadyPlayedLock: false)
    }

    private func afterLock(alreadyPlayedLock: Bool) {
        lockTimer = 0
        fallTimer = 0
        lockResets = 0
        if !alreadyPlayedLock { PaperJamSound.play(.lock) }
        if game.isOver { gameOver(); return }
        let rows = game.pendingClear
        if rows.isEmpty {
            game.finishClear(rng: &rng)
            if game.isOver { gameOver() }
            return
        }
        flashRows = rows
        PaperJamSound.play(.clear(rows.count))
        switch rows.count {
        case 2: show("Double!")
        case 3: show("Triple!")
        case 4...: show("Full ream!")
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self else { return }
            let levelBefore = self.game.level
            withAnimation(.easeOut(duration: 0.12)) {
                self.game.finishClear(rng: &self.rng)
                self.flashRows = []
            }
            if self.game.level > levelBefore { self.show("Level \(self.game.level)") }
            if self.game.isOver { self.gameOver() }
        }
    }

    private func gameOver() {
        Self.bestScore = max(Self.bestScore, game.score)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { PaperJamSound.play(.over) }
    }

    private func show(_ text: String) {
        calloutToken += 1
        let token = calloutToken
        withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) { callout = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.calloutToken == token else { return }
            withAnimation(.easeIn(duration: 0.2)) { self.callout = nil }
        }
    }
}

enum PaperJamPalette {
    static let well = Color(red: 0.12, green: 0.15, blue: 0.22)
    static let grid = Color.white.opacity(0.05)
    static let frame = Color(red: 0.32, green: 0.36, blue: 0.44)
    static let danger = Color(red: 0.86, green: 0.25, blue: 0.22)
    static let control = Color(red: 0.28, green: 0.34, blue: 0.46)
    static let accent = Color(red: 0.24, green: 0.52, blue: 0.78)

    /// Office-stationery colours, one per piece.
    static func color(_ kind: PaperJamKind) -> Color {
        switch kind {
        case .i: return Color(red: 0.36, green: 0.72, blue: 0.86)   // sky
        case .o: return Color(red: 0.93, green: 0.78, blue: 0.42)   // manila
        case .t: return Color(red: 0.66, green: 0.5, blue: 0.86)    // lilac
        case .s: return Color(red: 0.5, green: 0.8, blue: 0.56)     // mint
        case .z: return Color(red: 0.93, green: 0.48, blue: 0.44)   // coral
        case .j: return Color(red: 0.36, green: 0.48, blue: 0.86)   // ink blue
        case .l: return Color(red: 0.95, green: 0.6, blue: 0.3)     // amber
        }
    }
}

struct PaperJamComputerGame: View {
    let restart: () -> Void
    @ObservedObject var session: PaperJamSession

    init(restart: @escaping () -> Void, session: PaperJamSession) {
        self.restart = restart
        _session = ObservedObject(wrappedValue: session)
    }

    private var game: PaperJamGame { session.game }

    var body: some View {
        GeometryReader { geo in
            let cell = floor(geo.size.height / CGFloat(PaperJamGame.height) * 2) / 2
            let wellW = cell * CGFloat(PaperJamGame.width)
            let side = (geo.size.width - wellW - 20) / 2
            HStack(spacing: 10) {
                leftPanel.frame(width: side, height: geo.size.height)
                well(cell: cell).frame(width: wellW, height: cell * CGFloat(PaperJamGame.height))
                rightPanel.frame(width: side, height: geo.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { session.appeared() }
        .onDisappear { session.disappeared() }
        .task {
            while !Task.isCancelled {
                if OfficeComputer.shared.showingHelp { session.hold() } else { session.tick() }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    // MARK: Well

    private func well(cell: CGFloat) -> some View {
        let danger = !game.isOver && game.stackFraction >= 0.7
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(PaperJamPalette.well)
            // faint ruled grid
            ForEach(1..<PaperJamGame.width, id: \.self) { c in
                Rectangle().fill(PaperJamPalette.grid).frame(width: 1).offset(x: CGFloat(c) * cell)
            }
            ForEach(0..<PaperJamGame.height, id: \.self) { r in
                ForEach(0..<PaperJamGame.width, id: \.self) { c in
                    if let kind = game.board[r][c] { block(kind, cell: cell).offset(x: CGFloat(c) * cell, y: CGFloat(r) * cell) }
                }
            }
            if let ghost = game.ghost, ghost != game.current {
                ForEach(0..<4, id: \.self) { k in
                    let p = ghost.cells[k]
                    if p.row >= 0 {
                        RoundedRectangle(cornerRadius: cell * 0.18, style: .continuous)
                            .stroke(PaperJamPalette.color(ghost.kind).opacity(0.5), lineWidth: 1.2)
                            .frame(width: cell - 2, height: cell - 2)
                            .offset(x: CGFloat(p.column) * cell + 1, y: CGFloat(p.row) * cell + 1)
                    }
                }
            }
            if let piece = game.current {
                ForEach(0..<4, id: \.self) { k in
                    let p = piece.cells[k]
                    if p.row >= 0 { block(piece.kind, cell: cell).offset(x: CGFloat(p.column) * cell, y: CGFloat(p.row) * cell) }
                }
            }
            ForEach(session.flashRows, id: \.self) { r in
                Rectangle().fill(Color.white.opacity(0.85))
                    .frame(width: cell * CGFloat(PaperJamGame.width), height: cell)
                    .offset(y: CGFloat(r) * cell)
            }
            if let text = session.callout {
                Text(text)
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .frame(width: cell * CGFloat(PaperJamGame.width))
                    .offset(y: cell * 4)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if game.isOver {
                VStack(spacing: 4) {
                    Text("Paper jam.").font(.system(size: 17, weight: .black, design: .rounded)).foregroundStyle(.white)
                    Text("\(game.score)").font(.system(size: 16, weight: .heavy, design: .rounded).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                }
                .padding(8)
                .frame(width: cell * CGFloat(PaperJamGame.width))
                .background(Color.black.opacity(0.6))
                .offset(y: cell * 5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(danger || game.isOver ? PaperJamPalette.danger : PaperJamPalette.frame, lineWidth: 3)
            .animation(.easeInOut(duration: 0.3), value: danger))
    }

    private func block(_ kind: PaperJamKind, cell: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cell * 0.18, style: .continuous)
            .fill(PaperJamPalette.color(kind))
            .overlay(RoundedRectangle(cornerRadius: cell * 0.18, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)))
            .frame(width: cell - 1.5, height: cell - 1.5)
    }

    // MARK: Panels

    private var leftPanel: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                stat("Score", "\(game.score)")
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Level \(game.level)").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                    Text("Rows \(game.lines)").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                PressPad(icon: "arrowtriangle.left.fill", repeats: true) { session.move(-1) }
                PressPad(icon: "arrowtriangle.down.fill", repeats: true, interval: 0.05) { session.softDrop() }
                PressPad(icon: "arrowtriangle.right.fill", repeats: true) { session.move(1) }
            }
            .frame(height: 76)
        }
    }

    private var rightPanel: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                    nextPreview
                }
                Spacer(minLength: 4)
                newRunButton
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                PressPad(icon: "arrow.clockwise", repeats: false) { session.rotate() }
                PressPad(icon: "arrow.down.to.line", label: "Drop", repeats: false, tint: PaperJamPalette.accent) { session.hardDrop() }
            }
            .frame(height: 76)
        }
    }

    private var nextPreview: some View {
        let kind = game.next
        let c: CGFloat = 12
        let piece = PaperJamPiece(kind: kind, rotation: 0, row: 0, column: 0)
        let cells = piece.cells
        let minR = cells.map(\.row).min() ?? 0
        return ZStack(alignment: .topLeading) {
            ForEach(0..<4, id: \.self) { k in
                block(kind, cell: c).offset(x: CGFloat(cells[k].column) * c, y: CGFloat(cells[k].row - minR) * c)
            }
        }
        .frame(width: 4 * c, height: 2 * c, alignment: .topLeading)
        .padding(6)
        .background(PaperJamPalette.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                .padding(.horizontal, 10).frame(minWidth: 80, minHeight: 38)
                .background(confirming ? PaperJamPalette.danger : (game.isOver ? GamePalette.turn : PaperJamPalette.control),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
            Text(value).font(.system(size: 22, weight: .black, design: .rounded).monospacedDigit()).foregroundStyle(HallwaysOS.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text("Best \(max(PaperJamSession.bestScore, game.score))")
                .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
        }
    }
}

/// A big control block that acts the moment it's touched (not on lift), and
/// -- if `repeats` -- keeps acting while held: a short pause, then steadily.
private struct PressPad: View {
    let icon: String
    var label: String? = nil
    let repeats: Bool
    var interval: Double = 0.075
    var tint: Color = PaperJamPalette.control
    let action: () -> Void

    @State private var pressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 22, weight: .bold))
            if let label { Text(label).font(.system(size: 12, weight: .heavy, design: .rounded)) }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tint.opacity(pressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .scaleEffect(pressed ? 0.95 : 1)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressed else { return }
                pressed = true
                action()
                guard repeats else { return }
                repeatTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 170_000_000)
                    while !Task.isCancelled {
                        action()
                        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    }
                }
            }
            .onEnded { _ in
                pressed = false
                repeatTask?.cancel()
                repeatTask = nil
            })
        .onDisappear { repeatTask?.cancel() }
    }
}
