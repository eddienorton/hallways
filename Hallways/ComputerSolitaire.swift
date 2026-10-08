import SwiftUI
import Combine

// Oct 7 -- SOLITAIRE on the office computer (Klondike, draw one).
//
// A real game on the employee's workstation: no Hallways reward, no floor
// link, no persistence. Rules live in SolitaireGame.swift (pure); this is the
// presentation, designed for the monitor's short, wide game area (~482 x 204):
//
//   [stock]   [ 7 tableau columns, cards ~51 x 70 ]   [F]
//   [waste]                                          [F]
//   (count)                                          [F]
//                                                    [F]
//
// Foundations are a slim column of four smaller piles (only their top card
// matters), which buys the tableau the widest cards the width allows.
//
// Touch: tap to pick up, tap to put down -- no dragging.
//   - Tap the deck: deal one card to the waste (empty deck: turn the waste over).
//   - Tap a face-up card (waste top, a tableau card heading a valid run, a
//     foundation top) to pick it up; it lifts and gets a gold outline.
//   - With a card picked up, the next tap is first tried as where it should
//     go (a column -- any card in it, or the space below -- an empty slot or a
//     foundation). Legal -> it moves. Illegal but the tapped card can itself
//     be picked up -> that card is picked up instead. Otherwise a small shake
//     and the original stays picked up.
//   - Tap the picked-up card AGAIN to send it to its foundation if it can go;
//     otherwise that tap just puts it back.
// Hit areas: every card's whole painted face, and each column's full height.

enum SolitairePalette {
    static let felt = Color(red: 0.11, green: 0.36, blue: 0.33)
    static let feltDeep = Color(red: 0.07, green: 0.25, blue: 0.24)
    static let red = Color(red: 0.8, green: 0.13, blue: 0.17)
    static let black = Color(red: 0.08, green: 0.1, blue: 0.14)
    static let selection = Color(red: 1.0, green: 0.78, blue: 0.2)
    static let slot = Color.white.opacity(0.28)
    static let backTop = Color(red: 0.2, green: 0.36, blue: 0.78)
    static let backBottom = Color(red: 0.12, green: 0.22, blue: 0.55)
}

/// One Solitaire game in progress (kept while the app runs; see ComputerGameStore).
final class SolitaireSession: ObservableObject {
    @Published var game: SolitaireGame
    @Published var selection: SolitaireSelection?

    init() {
        var rng = SystemRandomNumberGenerator()
        game = SolitaireGame(rng: &rng)
    }
}

struct SolitaireComputerGame: View {
    let restart: () -> Void
    /// The live deal + what's picked up, retained by OfficeComputer.games.
    @ObservedObject var session: SolitaireSession

    init(restart: @escaping () -> Void, session: SolitaireSession) {
        self.restart = restart
        _session = ObservedObject(wrappedValue: session)
    }
    private var game: SolitaireGame {
        get { session.game }
        nonmutating set { session.game = newValue }
    }
    private var selection: SolitaireSelection? {
        get { session.selection }
        nonmutating set { session.selection = newValue }
    }
    @State private var shakes: CGFloat = 0

    private static let gap: CGFloat = 4
    private static let sideGap: CGFloat = 8
    private static let aspect: CGFloat = 1.38

    var body: some View {
        GeometryReader { geo in
            let H = geo.size.height
            let fh = (H - 3 * Self.gap) / 4
            let fw = fh / Self.aspect
            let w = min((geo.size.width - fw - 2 * Self.sideGap - 6 * Self.gap) / 8, 64)
            let h = min(w * Self.aspect, H * 0.47)
            ZStack {
                LinearGradient(colors: [SolitairePalette.felt, SolitairePalette.feltDeep], startPoint: .top, endPoint: .bottom)
                HStack(alignment: .top, spacing: Self.sideGap) {
                    VStack(spacing: 6) {
                        stockView(w: w, h: h)
                        wasteView(w: w, h: h)
                        Text(game.stock.isEmpty ? (game.waste.isEmpty ? "" : "turn over") : "\(game.stock.count) left")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(width: w)
                    HStack(alignment: .top, spacing: Self.gap) {
                        ForEach(0..<SolitaireGame.tableauCount, id: \.self) { c in column(c, w: w, h: h, height: H) }
                    }
                    VStack(spacing: Self.gap) {
                        ForEach(0..<SolitaireGame.foundationCount, id: \.self) { f in foundationView(f, w: fw, h: fh) }
                    }
                }
                .padding(.vertical, 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if game.isWon { winOverlay }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: Piles

    private func stockView(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            if game.stock.isEmpty {
                slot(w: w, h: h)
                if !game.waste.isEmpty {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: w * 0.38, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else {
                SolitaireCardFace(card: nil, w: w, h: h)
            }
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .onTapGesture { tapStock() }
    }

    private func wasteView(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            slot(w: w, h: h)
            if let top = game.waste.last {
                card(top, w: w, h: h, selected: selection?.pile == .waste)
                    .onTapGesture { tapCard(.waste, index: game.waste.count - 1) }
            }
        }
        .frame(width: w, height: h)
    }

    private func foundationView(_ f: Int, w: CGFloat, h: CGFloat) -> some View {
        let pile = game.foundations[f]
        return ZStack {
            slot(w: w, h: h)
            Text("A").font(.system(size: w * 0.42, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.3))
            if let top = pile.last {
                card(top, w: w, h: h, selected: selection?.pile == .foundation(f))
            }
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .onTapGesture {
            if pile.isEmpty { tapEmpty(.foundation(f)) } else { tapCard(.foundation(f), index: pile.count - 1) }
        }
    }

    private func column(_ c: Int, w: CGFloat, h: CGFloat, height: CGFloat) -> some View {
        let cards = game.tableau[c]
        let ys = offsets(cards, h: h, height: height)
        return ZStack(alignment: .top) {
            // The whole column is a destination (and the empty slot for a king).
            Color.white.opacity(0.001)
                .frame(width: w, height: height)
                .contentShape(Rectangle())
                .onTapGesture { cards.isEmpty ? tapEmpty(.tableau(c)) : tapCard(.tableau(c), index: cards.count - 1) }
            if cards.isEmpty {
                // Painted only: taps fall through to the column's full-height target.
                slot(w: w, h: h).allowsHitTesting(false)
                Text("K").font(.system(size: w * 0.34, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.3))
                    .frame(width: w, height: h)
                    .allowsHitTesting(false)
            }
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, item in
                let selected = selection?.pile == .tableau(c) && i >= (selection?.index ?? .max)
                card(item, w: w, h: h, selected: selected)
                    .offset(y: ys[i])
                    .modifier(ShakeEffect(travel: 4, animatableData: selected ? shakes : 0))
                    .onTapGesture { tapCard(.tableau(c), index: i) }
            }
        }
        .frame(width: w, height: height, alignment: .top)
    }

    /// Vertical positions in a column: face-down cards show a 7-unit sliver,
    /// face-up cards a 19-unit band (rank + suit); both squeeze only when the
    /// column would otherwise run off the bottom.
    private func offsets(_ cards: [SolitaireCard], h: CGFloat, height: CGFloat) -> [CGFloat] {
        let down = cards.filter { !$0.faceUp }.count
        let up = cards.count - down
        var downStep: CGFloat = 7, upStep: CGFloat = 19
        let room = height - h
        if CGFloat(down) * downStep + CGFloat(max(up - 1, 0)) * upStep > room {
            downStep = 4
            upStep = max(8, min(19, (room - CGFloat(down) * downStep) / CGFloat(max(up - 1, 1))))
        }
        var y: CGFloat = 0
        return cards.map { card in
            defer { y += card.faceUp ? upStep : downStep }
            return y
        }
    }

    private func card(_ item: SolitaireCard, w: CGFloat, h: CGFloat, selected: Bool) -> some View {
        SolitaireCardFace(card: item.faceUp ? item.card : nil, w: w, h: h)
            .overlay(RoundedRectangle(cornerRadius: w * 0.1, style: .continuous)
                .stroke(SolitairePalette.selection, lineWidth: selected ? 3 : 0))
            .offset(y: selected ? -3 : 0)
            .contentShape(Rectangle())
    }

    private func slot(w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: w * 0.1, style: .continuous)
            .stroke(SolitairePalette.slot, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .frame(width: w, height: h)
    }

    private var winOverlay: some View {
        VStack(spacing: 10) {
            Text("All 52 home.").font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            Text("Nicely played.").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
            BigButton(title: "Play again", color: GamePalette.win, action: restart)
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // MARK: Taps

    private func tapStock() {
        guard !game.isWon else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            selection = nil
            game.tapStock()
        }
    }

    /// One two-tap rule (Oct 7, second physical-play revision). Destination
    /// intent always comes FIRST; only a failed move may become a re-pick:
    ///   NO SELECTION:     tap a pick-up-able card  -> select it (and its run).
    ///   SELECTION ACTIVE: tap the selected card    -> send home if it can go, else put back;
    ///                     tap anything else:
    ///                       1. legal destination for the selection -> MOVE;
    ///                       2. else the tapped card is itself pick-up-able -> SWITCH to it (no shake);
    ///                       3. else -> shake, keep the selection.
    /// Empty columns/foundations come through tapEmpty (they can never be a
    /// source), so an illegal tap there is always step 3.
    private func tapCard(_ pile: SolitairePile, index: Int) {
        guard !game.isWon else { return }
        guard let picked = selection else {
            if game.canSelect(pile, index: index) { select(pile, index) }
            return
        }
        if picked.pile == pile && picked.index == index {
            // The selected card again: home if it can go, otherwise put it back.
            if case .foundation = picked.pile {
                withAnimation(.easeOut(duration: 0.12)) { selection = nil }
            } else if let f = game.foundationTarget(for: picked) {
                perform(picked, to: .foundation(f))
            } else {
                withAnimation(.easeOut(duration: 0.12)) { selection = nil }
            }
            return
        }
        if game.canMove(picked, to: pile) {
            perform(picked, to: pile)                       // 1. destination first
        } else if game.canSelect(pile, index: index) {
            select(pile, index)                             // 2. it's another playable card: re-pick
        } else {
            reject()                                        // 3. neither
        }
    }

    private func select(_ pile: SolitairePile, _ index: Int) {
        withAnimation(.easeOut(duration: 0.12)) { selection = SolitaireSelection(pile: pile, index: index) }
    }

    /// The selection's destination attempt (a tapped card, column, slot or foundation).
    private func attemptMove(_ picked: SolitaireSelection, to destination: SolitairePile) {
        if game.canMove(picked, to: destination) { perform(picked, to: destination) } else { reject() }
    }

    private func tapEmpty(_ pile: SolitairePile) {
        guard !game.isWon, let picked = selection else { return }
        attemptMove(picked, to: pile)
    }

    private func perform(_ picked: SolitaireSelection, to destination: SolitairePile) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            game.move(picked, to: destination)
            selection = nil
        }
    }

    private func reject() {
        withAnimation(.linear(duration: 0.3)) { shakes += 1 }
    }
}

/// One card at monitor scale: what matters first is rank, suit and red/black
/// (a bold index across the top, readable in a 19-unit band), then a large
/// suit in the open face. Face down: a plain Hallways-blue back.
private struct SolitaireCardFace: View {
    let card: PlayingCard?
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let card {
                let ink = SolitaireGame.isRed(card.suit) ? SolitairePalette.red : SolitairePalette.black
                RoundedRectangle(cornerRadius: w * 0.1, style: .continuous).fill(Color.white)
                RoundedRectangle(cornerRadius: w * 0.1, style: .continuous).stroke(Color.black.opacity(0.25), lineWidth: 0.75)
                HStack(spacing: 1) {
                    Text(card.rank.displayName).font(.system(size: w * 0.33, weight: .heavy, design: .rounded))
                    Text(card.suit.symbol).font(.system(size: w * 0.3, weight: .bold))
                }
                .foregroundStyle(ink)
                .padding(.leading, w * 0.07)
                .padding(.top, w * 0.02)
                Text(card.suit.symbol).font(.system(size: w * 0.62))
                    .foregroundStyle(ink)
                    .frame(width: w, height: h)
                    .offset(y: h * 0.12)
            } else {
                RoundedRectangle(cornerRadius: w * 0.1, style: .continuous)
                    .fill(LinearGradient(colors: [SolitairePalette.backTop, SolitairePalette.backBottom],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: w * 0.07, style: .continuous)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1.2)
                    .padding(w * 0.08)
                RoundedRectangle(cornerRadius: w * 0.1, style: .continuous).stroke(Color.black.opacity(0.3), lineWidth: 0.75)
            }
        }
        .frame(width: w, height: h)
        .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
    }
}
