import SwiftUI
import Combine

// Oct 7 -- MERGER on the office computer (the number-merging game).
//
// Layout (~482 x 204): the 4 x 4 board on the left (204 square, tiles ~46),
// and on the right: score, best tile, this-session best, New board -- and a
// big arrow pad. Input is either: SWIPE on the board (it lives inside the
// monitor's own surface, so it never reaches the room's gestures), or tap
// the arrows (for precise, unhurried play on a small screen).
//
// Pressure is shown, not told: the board's frame warms from slate to amber
// to red as free cells run out. Merges pop; a merge of 128 or more also puts
// its number briefly over the board. New board asks for a second tap while
// a run is in progress, so a good run is never lost to one stray touch.
// Session: MergerSession, retained by OfficeComputer.games.

final class MergerSession: ObservableObject {
    /// Best score / best tile this app run (no disk).
    static var bestScore = 0
    static var bestTile = 0

    @Published private(set) var game: MergerGame
    /// tile id -> how many times it has grown (drives the pop).
    @Published private(set) var pops: [Int: Int] = [:]
    @Published private(set) var banner: Int?
    @Published var confirmingNew = false
    private var rng = SystemRandomNumberGenerator()
    private var bannerToken = 0

    init() {
        var r = SystemRandomNumberGenerator()
        game = MergerGame(rng: &r)
        MergerSound.play(.newBoard)
    }

    var inProgress: Bool { game.moves > 0 && !game.isOver }

    func move(_ direction: MergerDirection) {
        guard !game.isOver else { return }
        confirmingNew = false
        var next = game
        let result = next.move(direction, rng: &rng)
        guard result.moved else { MergerSound.play(.bump); return }
        withAnimation(.easeOut(duration: 0.12)) { game = next }
        for id in result.grown { pops[id, default: 0] += 1 }
        if let biggest = result.merges.max() {
            MergerSound.play(.merge(biggest, extra: result.merges.count - 1))
            if biggest >= 128 { showBanner(biggest) }
        } else {
            MergerSound.play(.slide)
        }
        Self.bestScore = max(Self.bestScore, game.score)
        Self.bestTile = max(Self.bestTile, game.highestTile)
        if game.isOver {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MergerSound.play(.over) }
        }
    }

    private func showBanner(_ value: Int) {
        bannerToken += 1
        let token = bannerToken
        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { banner = value }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.bannerToken == token else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.banner = nil }
        }
    }
}

enum MergerPalette {
    static let board = Color(red: 0.26, green: 0.3, blue: 0.38)
    static let cell = Color.white.opacity(0.12)
    static let warn = Color(red: 0.86, green: 0.58, blue: 0.12)
    static let danger = Color(red: 0.82, green: 0.24, blue: 0.22)
    static let accent = Color(red: 0.2, green: 0.55, blue: 0.62)

    /// Cool paper blues for the small values, warming to gold, orange, red,
    /// magenta and violet as they grow.
    static func tile(_ v: Int) -> Color {
        switch v {
        case 2: return Color(red: 0.93, green: 0.92, blue: 0.89)
        case 4: return Color(red: 0.86, green: 0.9, blue: 0.95)
        case 8: return Color(red: 0.62, green: 0.77, blue: 0.91)
        case 16: return Color(red: 0.44, green: 0.66, blue: 0.86)
        case 32: return Color(red: 0.31, green: 0.56, blue: 0.82)
        case 64: return Color(red: 0.24, green: 0.44, blue: 0.72)
        case 128: return Color(red: 0.95, green: 0.76, blue: 0.31)
        case 256: return Color(red: 0.95, green: 0.62, blue: 0.3)
        case 512: return Color(red: 0.91, green: 0.45, blue: 0.23)
        case 1024: return Color(red: 0.85, green: 0.33, blue: 0.31)
        case 2048: return Color(red: 0.7, green: 0.23, blue: 0.48)
        default: return Color(red: 0.42, green: 0.18, blue: 0.64)
        }
    }

    static func ink(_ v: Int) -> Color { v <= 4 ? Color(red: 0.22, green: 0.24, blue: 0.3) : .white }
}

struct MergerComputerGame: View {
    let restart: () -> Void
    @ObservedObject var session: MergerSession

    init(restart: @escaping () -> Void, session: MergerSession) {
        self.restart = restart
        _session = ObservedObject(wrappedValue: session)
    }

    private var game: MergerGame { session.game }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.height, geo.size.width * 0.46)
            HStack(spacing: 12) {
                board(side: side)
                    .frame(width: side, height: side)
                sidePanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Board

    private var frameColor: Color {
        if game.isOver { return MergerPalette.danger }
        switch game.emptyCells.count {
        case ...1: return MergerPalette.danger
        case 2...3: return MergerPalette.warn
        default: return MergerPalette.board
        }
    }

    private func board(side: CGFloat) -> some View {
        let gap: CGFloat = 5
        let n = CGFloat(MergerGame.size)
        let tile = (side - gap * (n + 1)) / n
        func center(_ i: Int) -> CGFloat { gap + tile / 2 + CGFloat(i) * (tile + gap) }
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MergerPalette.board)
            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(frameColor, lineWidth: 4)
                .animation(.easeOut(duration: 0.3), value: frameColor)
            ForEach(0..<MergerGame.size * MergerGame.size, id: \.self) { k in
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MergerPalette.cell)
                    .frame(width: tile, height: tile)
                    .position(x: center(k % MergerGame.size), y: center(k / MergerGame.size))
            }
            ForEach(game.tiles) { t in
                tileView(t, size: tile)
                    .position(x: center(t.column), y: center(t.row))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                    .zIndex(Double(t.value))
            }
            if let b = session.banner {
                Text("\(b)!")
                    .font(.system(size: side * 0.24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: MergerPalette.tile(b), radius: 8)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 2)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(10_000)
            }
            if game.isOver {
                VStack(spacing: 4) {
                    Text("Boxed in").font(.system(size: 22, weight: .black, design: .rounded)).foregroundStyle(.white)
                    Text("\(game.score)").font(.system(size: 18, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .zIndex(10_001)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 10).onEnded { value in
            let dx = value.translation.width, dy = value.translation.height
            guard max(abs(dx), abs(dy)) >= 16 else { return }
            if abs(dx) > abs(dy) { session.move(dx > 0 ? .right : .left) } else { session.move(dy > 0 ? .down : .up) }
        })
    }

    private func tileView(_ t: MergerTile, size: CGFloat) -> some View {
        let digits = String(t.value).count
        return Text("\(t.value)")
            .font(.system(size: size * (digits <= 2 ? 0.5 : digits == 3 ? 0.4 : 0.31), weight: .black, design: .rounded))
            .foregroundStyle(MergerPalette.ink(t.value))
            .frame(width: size, height: size)
            .background(MergerPalette.tile(t.value), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1.5)
            .keyframeAnimator(initialValue: 1.0, trigger: session.pops[t.id] ?? 0) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(1.18, duration: 0.09)
                    SpringKeyframe(1.0, duration: 0.16)
                }
            }
    }

    // MARK: Side panel

    private var sidePanel: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                stat("Score", "\(game.score)")
                HStack(spacing: 8) {
                    Text("Top").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                    Text("\(game.highestTile)")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(MergerPalette.ink(game.highestTile))
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(MergerPalette.tile(game.highestTile), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text("Best \(MergerSession.bestScore)  \u{00B7}  \(MergerSession.bestTile)")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                newBoardButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            arrowPad
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
            Text(value).font(.system(size: 26, weight: .black, design: .rounded).monospacedDigit()).foregroundStyle(HallwaysOS.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    /// One tap starts over when there's nothing to lose; during a run it asks
    /// for a second tap (no dialog -- the button itself changes for 3 s).
    private var newBoardButton: some View {
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
            Text(confirming ? "Tap again" : "New board")
                .font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(confirming ? MergerPalette.danger : (game.isOver ? GamePalette.turn : MergerPalette.board),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var arrowPad: some View {
        let b: CGFloat = 46
        return VStack(spacing: 4) {
            arrow(.up, "arrowtriangle.up.fill", b)
            HStack(spacing: 4) {
                arrow(.left, "arrowtriangle.left.fill", b)
                Color.clear.frame(width: b, height: b)
                arrow(.right, "arrowtriangle.right.fill", b)
            }
            arrow(.down, "arrowtriangle.down.fill", b)
        }
    }

    private func arrow(_ d: MergerDirection, _ icon: String, _ b: CGFloat) -> some View {
        Button { session.move(d) } label: {
            Image(systemName: icon).font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: b, height: b)
                .background(game.isOver ? MergerPalette.board.opacity(0.4) : MergerPalette.accent,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
