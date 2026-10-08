import SwiftUI
import Combine

// Oct 7 -- MINEFIELD on the office computer.
//
// A 5 x 9 field with 8 mines -- sized for fingertips on the tiny monitor
// (cells ~37 units, ~25 pt on a portrait iPhone), not a desktop grid.
// Layout (~482 x 204): the field on the left, a slim status column on the
// right: mines left, the clock, the Reveal / Flag switch, New field.
//
// Touch: a tap REVEALS (or, on an opened number whose flags are all placed,
// opens the rest of its neighbours). Flagging is never a guess:
//   - a long press on a cell always plants / lifts a flag, in either mode;
//   - the Flag switch makes plain taps flag instead -- and while it's on, the
//     whole field gets an orange frame, so the mode is never in doubt.
// A flagged cell can't be revealed by a tap (lift the flag first).
//
// The clock counts only time spent with the game open: it starts at the
// first reveal, pauses whenever the game's screen goes away, resumes on
// return, and stops at a win or a bang. Best time is kept for this run of
// the app only. Session: the whole field lives in MinefieldSession,
// retained by OfficeComputer.games.

final class MinefieldSession: ObservableObject {
    /// Best winning time for this field size, this app run (no disk).
    static var bestTime: TimeInterval?

    @Published private(set) var game = MinefieldGame()
    @Published var flagMode = false
    /// The latest flood, cell -> order opened (drives the ripple).
    @Published private(set) var ripple: [Int: Int] = [:]
    @Published private(set) var winTime: TimeInterval?
    @Published private(set) var newBest = false

    private var accumulated: TimeInterval = 0
    private var runningSince: Date?
    private var visible = false
    private var rng = SystemRandomNumberGenerator()

    init() {
        MinefieldSound.play(.newField)
        MinefieldSound.prepare(.boom)
        MinefieldSound.prepare(.win)
    }

    // MARK: Clock (active play time only)

    func elapsed(at now: Date = Date()) -> TimeInterval {
        accumulated + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    func appeared(now: Date = Date()) {
        visible = true
        if game.phase == .playing, runningSince == nil { runningSince = now }
    }

    func disappeared(now: Date = Date()) {
        visible = false
        stopClock(now: now)
    }

    private func stopClock(now: Date = Date()) {
        if let since = runningSince { accumulated += now.timeIntervalSince(since) }
        runningSince = nil
    }

    // MARK: Play

    func tap(_ i: Int) {
        guard !game.isOver else { return }
        if flagMode { flag(i); return }
        switch game.cells[i] {
        case .flagged: return                                       // protected: lift the flag first
        case .hidden: handle(game.reveal(i, rng: &rng))
        case .revealed: handle(game.chord(i))
        }
    }

    /// Long press: always a flag, never a reveal.
    func flag(_ i: Int) {
        guard !game.isOver, game.cells[i] != .revealed else { return }
        let planting = game.cells[i] == .hidden
        guard game.toggleFlag(i) else { return }
        MinefieldSound.play(planting ? .flag : .unflag)
    }

    private func handle(_ outcome: MinefieldGame.Outcome) {
        if game.phase != .ready, runningSince == nil, visible, !game.isOver { runningSince = Date() }
        switch outcome {
        case .nothing:
            return
        case .opened(let cells):
            ripple = Dictionary(uniqueKeysWithValues: cells.enumerated().map { ($0.element, $0.offset) })
            MinefieldSound.play(cells.count == 1 ? .reveal : .cascade(cells.count))
        case .won(let cells):
            ripple = Dictionary(uniqueKeysWithValues: cells.enumerated().map { ($0.element, $0.offset) })
            if cells.count > 1 { MinefieldSound.play(.cascade(cells.count)) } else { MinefieldSound.play(.reveal) }
            finish(won: true)
        case .boom:
            ripple = [:]
            finish(won: false)
        }
    }

    private func finish(won: Bool) {
        // A game finished in the very first tap never started the clock.
        if runningSince == nil, accumulated == 0 { runningSince = Date() }
        stopClock()
        if won {
            let t = accumulated
            winTime = t
            if Self.bestTime.map({ t < $0 }) ?? true {
                newBest = Self.bestTime != nil
                Self.bestTime = t
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MinefieldSound.play(.win) }
        } else {
            MinefieldSound.play(.boom)
        }
    }
}

enum MinefieldPalette {
    static let hiddenTop = Color(red: 0.4, green: 0.5, blue: 0.66)
    static let hiddenBottom = Color(red: 0.29, green: 0.37, blue: 0.52)
    static let open = Color(red: 0.95, green: 0.95, blue: 0.92)
    static let flag = Color(red: 0.95, green: 0.42, blue: 0.12)
    static let boom = Color(red: 0.88, green: 0.2, blue: 0.2)
    static let frame = Color(red: 0.16, green: 0.2, blue: 0.28)

    static func number(_ n: Int) -> Color {
        switch n {
        case 1: return Color(red: 0.12, green: 0.38, blue: 0.85)
        case 2: return Color(red: 0.1, green: 0.55, blue: 0.25)
        case 3: return Color(red: 0.85, green: 0.18, blue: 0.18)
        case 4: return Color(red: 0.2, green: 0.15, blue: 0.6)
        case 5: return Color(red: 0.55, green: 0.12, blue: 0.12)
        case 6: return Color(red: 0.05, green: 0.5, blue: 0.55)
        case 7: return Color(red: 0.1, green: 0.1, blue: 0.12)
        default: return Color(red: 0.45, green: 0.45, blue: 0.5)
        }
    }
}

/// An original mine mark: a dark ball with eight short spikes and a glint.
private struct MineGlyph: View {
    var color: Color = Color(red: 0.12, green: 0.13, blue: 0.16)
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                ForEach(0..<8, id: \.self) { k in
                    Capsule().fill(color).frame(width: s * 0.1, height: s * 0.86)
                        .rotationEffect(.degrees(Double(k) * 22.5))
                }
                Circle().fill(color).frame(width: s * 0.58, height: s * 0.58)
                Circle().fill(Color.white.opacity(0.85)).frame(width: s * 0.14, height: s * 0.14)
                    .offset(x: -s * 0.1, y: -s * 0.1)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

struct MinefieldComputerGame: View {
    let restart: () -> Void
    @ObservedObject var session: MinefieldSession

    init(restart: @escaping () -> Void, session: MinefieldSession) {
        self.restart = restart
        _session = ObservedObject(wrappedValue: session)
    }

    private var game: MinefieldGame { session.game }
    private static let statusWidth: CGFloat = 112

    var body: some View {
        GeometryReader { geo in
            let boardW = geo.size.width - Self.statusWidth - 10
            let pitch = min(boardW / CGFloat(MinefieldGame.columns), (geo.size.height - 8) / CGFloat(MinefieldGame.rows))
            HStack(alignment: .center, spacing: 10) {
                field(pitch: pitch)
                    .frame(width: boardW, height: geo.size.height)
                statusColumn
                    .frame(width: Self.statusWidth, height: geo.size.height)
            }
        }
        .onAppear { session.appeared() }
        .onDisappear { session.disappeared() }
    }

    // MARK: Field

    private func field(pitch: CGFloat) -> some View {
        let tile = pitch - 3
        return VStack(spacing: 3) {
            ForEach(0..<MinefieldGame.rows, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(0..<MinefieldGame.columns, id: \.self) { c in
                        cell(MinefieldGame.index(row: r, column: c), size: tile)
                    }
                }
            }
        }
        .padding(4)
        .background(MinefieldPalette.frame, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(MinefieldPalette.flag, lineWidth: session.flagMode && !game.isOver ? 3 : 0))
    }

    private func cell(_ i: Int, size: CGFloat) -> some View {
        let state = game.cells[i]
        let isMine = game.mines.contains(i)
        let revealed = state == .revealed
        let showMine = isMine && (revealed || game.phase == .lost)
        let flagged = state == .flagged || (game.phase == .won && isMine)
        let wrongFlag = game.phase == .lost && state == .flagged && !isMine
        let n = revealed && !isMine ? game.count(i) : 0
        let delay = Double(min(session.ripple[i] ?? 0, 30)) * 0.018
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(LinearGradient(colors: [MinefieldPalette.hiddenTop, MinefieldPalette.hiddenBottom], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(game.exploded == i ? MinefieldPalette.boom : (showMine && !revealed ? MinefieldPalette.open.opacity(0.75) : MinefieldPalette.open))
                .opacity(revealed || (showMine && !flagged) ? 1 : 0)
                .animation(.easeOut(duration: 0.12).delay(delay), value: revealed)
            if n > 0 {
                Text("\(n)").font(.system(size: size * 0.62, weight: .black, design: .rounded))
                    .foregroundStyle(MinefieldPalette.number(n))
                    .transition(.opacity)
            }
            if showMine && !flagged {
                MineGlyph(color: game.exploded == i ? .white : Color(red: 0.12, green: 0.13, blue: 0.16))
                    .frame(width: size * 0.66, height: size * 0.66)
            }
            if flagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(MinefieldPalette.flag)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            }
            if wrongFlag {
                Image(systemName: "xmark").font(.system(size: size * 0.6, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        // Long press = flag (always); a quick tap = the mode's action.
        .gesture(LongPressGesture(minimumDuration: 0.4)
            .onEnded { _ in session.flag(i) }
            .exclusively(before: TapGesture().onEnded { session.tap(i) }))
    }

    // MARK: Status

    private var statusColumn: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                MineGlyph().frame(width: 20, height: 20)
                Text("\(game.minesLeft)")
                    .font(.system(size: 22, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(HallwaysOS.ink)
            }
            .frame(height: 26)
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                Text(Self.clock(session.winTime ?? session.elapsed(at: ctx.date)))
                    .font(.system(size: 20, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(HallwaysOS.inkSoft)
            }
            .frame(height: 24)
            Spacer(minLength: 0)
            switch game.phase {
            case .won:
                VStack(spacing: 2) {
                    Text("Cleared!").font(.system(size: 20, weight: .black, design: .rounded)).foregroundStyle(GamePalette.win)
                    if session.newBest {
                        Text("New best").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(GamePalette.win)
                    } else if let best = MinefieldSession.bestTime {
                        Text("Best \(Self.clock(best))").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                    }
                }
            case .lost:
                Text("Boom.").font(.system(size: 24, weight: .black, design: .rounded)).foregroundStyle(MinefieldPalette.boom)
            case .ready, .playing:
                VStack(spacing: 4) {
                    modeButton("Reveal", icon: "hand.tap.fill", on: !session.flagMode) { session.flagMode = false }
                    modeButton("Flag", icon: "flag.fill", on: session.flagMode) { session.flagMode = true }
                }
            }
            Spacer(minLength: 0)
            BigButton(title: "New field", color: game.isOver ? GamePalette.turn : MinefieldPalette.frame) { restart() }
        }
    }

    private func modeButton(_ title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        let tint = title == "Flag" ? MinefieldPalette.flag : MinefieldPalette.hiddenBottom
        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14, weight: .bold))
                Text(title).font(.system(size: 15, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(on ? Color.white : tint)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(on ? tint : Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(tint.opacity(on ? 0 : 0.5), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
