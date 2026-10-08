import SwiftUI
import Combine

// Oct 7 -- H. GAMES on the office computer.
//
// THE GAMES PORTAL (Oct 7 foundation pass): these are games on an
// employee's computer, not challenges. Nothing to beat, nothing unlocked, no
// judgement; a finished game simply stays on screen until the PLAYER starts
// another (Play again / New game) or goes back to All games. Leaving a game
// only hides it: its live state is retained in memory (OfficeComputer.games)
// and reopening resumes it; New game / Play again start over. Nothing is
// saved to disk. Player History records only open/close/duration (OfficeComputer).
//
// Current computer games reuse the floor terminals' view models and pure
// logic unchanged (TicTacToeViewModel, FiveCardDrawViewModel [Video Poker],
// ConnectFourViewModel, HangmanViewModel); only the presentation is the
// computer's own, and the view models' `onWin` (the floors' elevator unlock)
// is left unset. The one computer-only switch in a shared view model is
// TicTacToeViewModel.autoResetsAfterLossOrDraw (floor default unchanged).
//
// Every game lives under ONE window title bar (AppWindow: All games / title /
// New game / close) and must work comfortably at monitor scale -- no
// microscopic cells or precision taps.

enum ComputerGameID: String, CaseIterable, Identifiable {
    // Oct 7 (Games portal): Rock Paper Scissors and Higher or Lower are no
    // longer in the computer collection (their floor terminals and engines are
    // untouched; their old history IDs "game.rockPaperScissors" /
    // "game.higherLower" remain valid in stored History).
    // Oct 7: Five-Card Draw became Video Poker (new durable history ID
    // "game.videoPoker"; old "game.fiveCardDraw" records stay valid).
    case woidle, solitaire, videoPoker, letterhead, minefield, merger, paperJam, inboxZero, fragile, ticTacToe, connectFour, hangman
    var id: String { rawValue }
    /// Durable ID used in Player History.
    var historyID: String { "game.\(rawValue)" }

    var title: String {
        switch self {
        case .woidle: return "Woidle"
        case .solitaire: return "Solitaire"
        case .ticTacToe: return "Tic-Tac-Toe"
        case .videoPoker: return "Video Poker"
        case .letterhead: return "Letterhead"
        case .minefield: return "Minefield"
        case .merger: return "Merger"
        case .paperJam: return "Paper Jam"
        case .inboxZero: return "Inbox Zero"
        case .fragile: return "Fragile"
        case .connectFour: return "Connect Four"
        case .hangman: return "Hangman"
        }
    }
    var blurb: String {
        switch self {
        case .woidle: return "Five letters, six tries."
        case .solitaire: return "Klondike, draw one."
        case .ticTacToe: return "Three in a row."
        case .videoPoker: return "Hold, draw, see what you made."
        case .letterhead: return "Six letters. 75 seconds."
        case .minefield: return "Clear it without a bang."
        case .merger: return "Slide. Match. Double."
        case .paperJam: return "Stack it. Clear it. Don't jam."
        case .inboxZero: return "Answer everything. Reach zero."
        case .fragile: return "Bubble wrap. Go on."
        case .connectFour: return "Four in a line, any direction."
        case .hangman: return "Five letters, six chances."
        }
    }
    var symbol: String {
        switch self {
        case .woidle: return "character.textbox"
        case .solitaire: return "suit.club.fill"
        case .ticTacToe: return "number"
        case .videoPoker: return "suit.spade.fill"
        case .letterhead: return "character.cursor.ibeam"
        case .minefield: return "flag.fill"
        case .merger: return "square.grid.2x2.fill"
        case .paperJam: return "square.stack.3d.down.right.fill"
        case .inboxZero: return "tray.and.arrow.up.fill"
        case .fragile: return "bubbles.and.sparkles.fill"
        case .connectFour: return "circle.grid.3x3.fill"
        case .hangman: return "textformat.abc"
        }
    }
    /// Oct 7 -- HOW TO PLAY: 2-4 short lines for someone who has never seen
    /// the game, shown on demand by the title bar's "?" (never automatically).
    /// Empty = no "?" for that game.
    var help: [String] {
        switch self {
        case .woidle:
            return ["Guess the hidden five-letter word in six tries.",
                    "Green: right letter, right spot.",
                    "Gold: in the word, but in another spot. Grey: not in the word."]
        case .solitaire:
            return ["Goal: get every card onto the four piles at the right, Ace up to King, one suit each.",
                    "In the columns, stack downward in alternating colours (red 6 on black 7). Only a King fills an empty column.",
                    "Tap a card to pick it up, then tap where it goes. Tap the deck for more cards."]
        case .videoPoker:
            return ["You get five cards. Tap the ones you want to keep: they say HOLD.",
                    "Tap Draw: every card you didn't hold is replaced, once.",
                    "A pair of Jacks or better wins. The strip above the cards lists the winning hands."]
        case .letterhead:
            return ["Make as many words as you can from the six letters before the clock runs out.",
                    "Tap letters to spell a word (3 to 6 letters), then tap Enter.",
                    "Longer words score more. Every rack hides at least one six-letter word."]
        case .minefield:
            return ["Tap a square to uncover it. If it's a mine, the round is over.",
                    "A number tells how many mines touch that square: ALL eight squares around it, including the diagonals.",
                    "Long-press a square (or switch to Flag) to mark a mine. Uncover every safe square to win."]
        case .merger:
            return ["Swipe or use the arrows to move all tiles.",
                    "Matching numbers merge: 2 + 2 \u{2192} 4.",
                    "Each successful move adds a new tile.",
                    "Keep merging. Don't run out of moves."]
        case .paperJam:
            return ["Blocks fall into the well. Use < and > to slide them, the curved arrow to turn them.",
                    "Fill a row all the way across and it disappears. Clear more rows at once for more points.",
                    "Hold the down arrow to fall faster, or tap Drop to drop it straight down.",
                    "If the stack reaches the top, the paper jams and the run is over."]
        case .inboxZero:
            return ["Envelopes march back and forth above you, dropping lower each time they reach a side.",
                    "Slide your tray with < and >. Tap or hold Fire to send replies up: each hit answers an envelope.",
                    "Dodge the falling ! marks (or shoot them down). Get hit three times and you're out of office.",
                    "Answer them all to reach inbox zero. If they reach the dotted line, your inbox is full."]
        case .fragile:
            return ["Drag your finger across the sheet to pop lots at once.",
                    "Pop every bubble and a fresh sheet comes off the roll."]
        case .ticTacToe:
            return ["You are \u{2715}, the computer is \u{25CB}. Take turns tapping a square.",
                    "Get three in a row (across, down or diagonally) to win."]
        case .connectFour:
            return ["Tap a column to drop your red piece. It falls to the lowest empty space.",
                    "Get four of your pieces in a line (across, up and down, or diagonally) before the computer does."]
        case .hangman:
            return ["Guess the hidden word one letter at a time.",
                    "Each wrong letter adds to the drawing. Six wrong letters and the round is over."]
        }
    }

    /// Whether the shared title bar offers "New game". Video Poker's own
    /// NEW HAND button already is that, so it would be a redundant second one.
    var showsTitleBarNewGame: Bool { self != .videoPoker && self != .minefield && self != .merger && self != .paperJam && self != .inboxZero && self != .fragile }   // each has its own always-visible button

    var tint: Color {
        switch self {
        case .woidle: return WoidlePalette.correct
        case .solitaire: return SolitairePalette.felt
        case .ticTacToe: return Color(red: 0.36, green: 0.42, blue: 0.95)
        case .videoPoker: return Color(red: 0.82, green: 0.24, blue: 0.36)
        case .letterhead: return LetterheadPalette.ink
        case .minefield: return MinefieldPalette.flag
        case .merger: return MergerPalette.accent
        case .paperJam: return PaperJamPalette.accent
        case .inboxZero: return InboxZeroPalette.accent
        case .fragile: return FragilePalette.accent
        case .connectFour: return Color(red: 0.18, green: 0.5, blue: 0.9)
        case .hangman: return Color(red: 0.6, green: 0.38, blue: 0.85)
        }
    }
}

enum GamePalette {
    static let you = Color(red: 0.93, green: 0.32, blue: 0.36)          // the player's pieces
    static let them = Color(red: 0.98, green: 0.75, blue: 0.2)          // the computer's pieces
    static let win = Color(red: 0.16, green: 0.66, blue: 0.4)
    static let lose = Color(red: 0.86, green: 0.3, blue: 0.3)
    static let neutral = Color(red: 0.42, green: 0.47, blue: 0.55)
    static let turn = Color(red: 0.25, green: 0.5, blue: 0.92)
}

// MARK: - The Games app (launcher + one game at a time)

struct GamesAppView: View {
    @ObservedObject var computer: OfficeComputer

    var body: some View {
        if let game = computer.openGame {
            GameShell(computer: computer, game: game)
                .transition(.opacity)
        } else {
            launcher
        }
    }

    private var launcher: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                ForEach(ComputerGameID.allCases) { game in
                    Button { withAnimation(.easeOut(duration: 0.18)) { computer.launch(game) } } label: { card(game) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("computerGame_\(game.rawValue)")
                }
            }
            .padding(10)
        }
    }

    private func card(_ game: ComputerGameID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: game.symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(game.tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(game.title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(HallwaysOS.ink)
            Text(game.blurb).font(.system(size: 12, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(game.tint.opacity(0.35), lineWidth: 1.5))
        .contentShape(Rectangle())
    }
}

/// One game, filling the Games window. Oct 7 (Games portal foundation): it
/// has no header of its own any more -- "All games", the game's name and
/// "New game" live in the window's title bar (see AppWindow) -- so every
/// game gets the full height under that one bar.
private struct GameShell: View {
    @ObservedObject var computer: OfficeComputer
    let game: ComputerGameID

    var body: some View {
        ZStack {
            LinearGradient(colors: [game.tint.opacity(0.10), game.tint.opacity(0.22)], startPoint: .top, endPoint: .bottom)
            view(for: game)
                .id(computer.gameRound)
                .padding(4)
            if computer.showingHelp, !game.help.isEmpty {
                HowToPlayCard(game: game) { withAnimation(.easeOut(duration: 0.15)) { computer.showingHelp = false } }
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func view(for game: ComputerGameID) -> some View {
        let restart = { computer.newGame() }
        let store = computer.games
        switch game {
        case .woidle: WoidleComputerGame(restart: restart, vm: store.model(for: .woidle) { WoidleViewModel() })
        case .solitaire: SolitaireComputerGame(restart: restart, session: store.model(for: .solitaire) { SolitaireSession() })
        case .paperJam: PaperJamComputerGame(restart: restart, session: store.model(for: .paperJam) { PaperJamSession() })
        case .inboxZero: InboxZeroComputerGame(restart: restart, session: store.model(for: .inboxZero) { InboxZeroSession() })
        case .fragile: FragileComputerGame(session: store.model(for: .fragile) { FragileSession() })   // no restart: sheets replace themselves
        case .merger: MergerComputerGame(restart: restart, session: store.model(for: .merger) { MergerSession() })
        case .minefield: MinefieldComputerGame(restart: restart, session: store.model(for: .minefield) { MinefieldSession() })
        case .letterhead: LetterheadComputerGame(restart: restart, session: store.model(for: .letterhead) { LetterheadSession() })
        case .ticTacToe:
            TicTacToeComputerGame(restart: restart, vm: store.model(for: .ticTacToe) {
                let vm = TicTacToeViewModel()
                vm.autoResetsAfterLossOrDraw = false     // the finished board stays until the player chooses
                return vm
            })
        case .videoPoker:
            VideoPokerComputerGame(restart: restart, vm: store.model(for: .videoPoker) {
                VideoPokerSound.play(.deal)                     // only when a NEW hand is dealt (not on resume)
                return FiveCardDrawViewModel()
            })
        case .connectFour: ConnectFourComputerGame(restart: restart, vm: store.model(for: .connectFour) { ConnectFourViewModel() })
        case .hangman: HangmanComputerGame(restart: restart, vm: store.model(for: .hangman) { HangmanViewModel() })
        }
    }
}

/// The "?" card: a compact how-to-play over the game. Tap Got it -- or
/// anywhere -- to put it away. The game underneath is untouched.
private struct HowToPlayCard: View {
    let game: ComputerGameID
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 5) {
                Text("How to play \(game.title)")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundStyle(game.tint)
                ForEach(Array(game.help.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(game.tint).frame(width: 5, height: 5).offset(y: -2)
                        Text(line)
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(HallwaysOS.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Spacer()
                    Button(action: dismiss) {
                        Text("Got it").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            .padding(.horizontal, 18).frame(height: 30)
                            .background(game.tint, in: Capsule())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .frame(maxWidth: 460)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .padding(8)
            .onTapGesture(perform: dismiss)
        }
    }
}

// MARK: - Shared bits
//
// Oct 7 (physical monitor): the games now live on the monitor's landscape
// screen (about 480 x 205 logical points of play area since the Oct 7
// portal-foundation pass), so each one is laid
// out side by side -- the board/cards on the left, the status and controls
// on the right. Same pieces, colours and behaviour as before.

struct StatusLine: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(color, in: Capsule())
            .animation(.easeOut(duration: 0.15), value: text)
    }
}

struct BigButton: View {
    let title: String
    let color: Color
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(minWidth: 104, minHeight: 42)
                .padding(.horizontal, 8)
                .background(color.opacity(enabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A colour playing card (white face, red hearts/diamonds, ink spades/clubs;
/// a patterned blue back when face down). The floors keep PlayingCardView.
private struct ColorCardView: View {
    let card: PlayingCard?
    var width: CGFloat = 70
    var body: some View {
        let h = width * 1.42
        ZStack {
            if let card {
                let red = card.suit == .hearts || card.suit == .diamonds
                let ink = red ? Color(red: 0.82, green: 0.16, blue: 0.2) : Color(red: 0.1, green: 0.12, blue: 0.16)
                RoundedRectangle(cornerRadius: width * 0.11, style: .continuous).fill(Color.white)
                VStack(alignment: .leading, spacing: 0) {
                    Text(card.rank.displayName).font(.system(size: width * 0.26, weight: .bold, design: .rounded))
                    Text(card.suit.symbol).font(.system(size: width * 0.2))
                    Spacer()
                }
                .foregroundStyle(ink)
                .padding(width * 0.08)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(card.suit.symbol).font(.system(size: width * 0.5)).foregroundStyle(ink).offset(y: width * 0.08)
            } else {
                RoundedRectangle(cornerRadius: width * 0.11, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.35, blue: 0.75), Color(red: 0.12, green: 0.22, blue: 0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: width * 0.08, style: .continuous)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
                    .padding(width * 0.07)
                Text("H").font(.system(size: width * 0.34, weight: .heavy, design: .serif)).foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(width: width, height: h)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
    }
}

private struct Caption: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 14, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft).multilineTextAlignment(.center)
    }
}

// MARK: - Woidle (WoidleViewModel)
//
// Oct 7 -- the first game produced for the portal. Reuses the floor's
// WoidleViewModel and pure WoidleGame logic unchanged (rules, word banks,
// UITextChecker validation, answer picker). Only presentation is new:
//   - the floor wording ("WORD ASSESSMENT PASSED / ELEVATOR ACCESS GRANTED")
//     and continueAfterResult()/onWin are never used here -- onWin stays nil,
//     and a finished game just stays up until Play again / New game, which
//     builds a fresh view model (fresh random answer);
//   - the familiar feedback colours (green #6AAA64 right spot, gold #C9B458
//     in the word, grey #787C7E not in it) on tiles, keys and legend;
//   - landscape layout for the monitor: the 6 x 5 board on the left, status
//     and a full keyboard on the right (keys as wide as the width allows,
//     taller than wide so the rows are easy to hit).
// No persistence and no daily word: a fresh random answer per game.

enum WoidlePalette {
    // Oct 7 (Eddie, after physical play): the familiar feedback colours.
    // Scoped to computer Woidle only (the floor terminal keeps its own look).
    static let correct = Color(red: 106 / 255, green: 170 / 255, blue: 100 / 255)   // #6AAA64 right spot
    static let present = Color(red: 201 / 255, green: 180 / 255, blue: 88 / 255)    // #C9B458 in the word
    static let absent = Color(red: 120 / 255, green: 124 / 255, blue: 126 / 255)    // #787C7E not in it
    static let tileEmpty = Color.white
    static let tileBorder = Color(red: 0.78, green: 0.8, blue: 0.84)
    static let tileTyping = Color(red: 0.2, green: 0.25, blue: 0.35)
}

/// Sideways shake for a rejected guess.
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 7
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 4), y: 0))
    }
}

private struct WoidleComputerGame: View {
    let restart: () -> Void
    @ObservedObject var vm: WoidleViewModel                 // retained by OfficeComputer.games
    @State private var shakes: CGFloat = 0
    private let rows: [[String]] = [
        "QWERTYUIOP".map { String($0) },
        "ASDFGHJKL".map { String($0) },
        ["ENTER"] + "ZXCVBNM".map { String($0) } + ["DEL"]
    ]
    private static let tileGap: CGFloat = 4
    private static let keyGap: CGFloat = 3

    private var status: (String, Color) {
        if let reason = vm.game.lastRejectionReason {
            return (reason == "NOT IN WORD LIST" ? "Not in the word list" : reason.capitalized, GamePalette.lose)
        }
        switch vm.game.phase {
        case .won:
            let n = vm.game.guesses.count
            return (n == 1 ? "First try!" : "Got it in \(n)!", GamePalette.win)
        case .lost:
            return ("The word was \(vm.game.answer)", GamePalette.lose)
        case .playing:
            return vm.game.guesses.isEmpty ? ("Guess the five-letter word", GamePalette.turn)
                                           : ("\(WoidleGame.maxGuesses - vm.game.guesses.count) tries left", GamePalette.turn)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let tile = min((geo.size.height - 5 * Self.tileGap) / CGFloat(WoidleGame.maxGuesses), 34)
            let boardWidth = tile * 5 + 4 * Self.tileGap
            let rightWidth = geo.size.width - boardWidth - 14
            let key = min((rightWidth - 9 * Self.keyGap) / 10, 34)
            let keyHeight = min(key * 1.45, (geo.size.height - 34 - 26 - 16 - 2 * Self.keyGap) / 3)
            HStack(spacing: 14) {
                board(tile: tile)
                VStack(spacing: 8) {
                    StatusLine(text: status.0, color: status.1)
                    if vm.game.phase == .playing {
                        HStack(spacing: 12) {
                            legend("Right spot", WoidlePalette.correct)
                            legend("In the word", WoidlePalette.present)
                        }
                        VStack(spacing: Self.keyGap) {
                            ForEach(0..<rows.count, id: \.self) { r in
                                HStack(spacing: Self.keyGap) {
                                    ForEach(rows[r], id: \.self) { label in keyButton(label, key: key, height: keyHeight) }
                                }
                            }
                        }
                    } else {
                        BigButton(title: "Play again", color: vm.game.phase == .won ? GamePalette.win : GamePalette.turn, action: restart)
                    }
                }
                .frame(width: rightWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Board

    private func board(tile: CGFloat) -> some View {
        VStack(spacing: Self.tileGap) {
            ForEach(0..<WoidleGame.maxGuesses, id: \.self) { row in
                let isCurrent = vm.game.phase == .playing && row == vm.game.guesses.count
                HStack(spacing: Self.tileGap) {
                    ForEach(0..<WoidleGame.wordLength, id: \.self) { col in tileView(row: row, col: col, size: tile) }
                }
                .modifier(ShakeEffect(animatableData: isCurrent ? shakes : 0))
            }
        }
    }

    private func tileView(row: Int, col: Int, size: CGFloat) -> some View {
        var letter = ""
        var fill = WoidlePalette.tileEmpty
        var ink = HallwaysOS.ink
        var border = WoidlePalette.tileBorder
        if row < vm.game.guesses.count {
            letter = String(Array(vm.game.guesses[row])[col])
            switch vm.game.evaluations[row][col] {
            case .correct: fill = WoidlePalette.correct
            case .present: fill = WoidlePalette.present
            case .absent: fill = WoidlePalette.absent
            }
            ink = .white
            border = .clear
        } else if row == vm.game.guesses.count, vm.game.phase == .playing {
            let typed = Array(vm.game.currentInput)
            if col < typed.count {
                letter = String(typed[col])
                border = WoidlePalette.tileTyping
            }
        }
        return Text(letter)
            .font(.system(size: size * 0.6, weight: .heavy, design: .rounded))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous).stroke(border, lineWidth: 2))
            .animation(.easeOut(duration: 0.22), value: fill)
    }

    // MARK: Keyboard

    private func keyButton(_ label: String, key: CGFloat, height: CGFloat) -> some View {
        let isAction = label.count > 1
        let width = isAction ? key * 1.5 + Self.keyGap / 2 : key
        var fill = Color.white
        var ink = HallwaysOS.ink
        if !isAction, let letter = label.first {
            switch vm.game.keyStatuses[letter] ?? .unknown {
            case .correct: fill = WoidlePalette.correct; ink = .white
            case .present: fill = WoidlePalette.present; ink = .white
            case .absent: fill = WoidlePalette.absent; ink = .white
            case .unknown: break
            }
        } else if label == "ENTER" {
            let ready = vm.game.currentInput.count == WoidleGame.wordLength
            fill = ready ? GamePalette.turn : Color(red: 0.86, green: 0.88, blue: 0.91)
            ink = ready ? .white : HallwaysOS.inkSoft
        } else {
            fill = Color(red: 0.86, green: 0.88, blue: 0.91)
        }
        return Button { press(label) } label: {
            Group {
                if label == "DEL" {
                    Image(systemName: "delete.left").font(.system(size: key * 0.55, weight: .semibold))
                } else {
                    Text(label == "ENTER" ? "Enter" : label)
                        .font(.system(size: isAction ? key * 0.45 : key * 0.58, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(ink)
            .frame(width: width, height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func press(_ label: String) {
        guard vm.game.phase == .playing else { return }
        switch label {
        case "ENTER":
            guard vm.game.currentInput.count == WoidleGame.wordLength else { return }
            vm.submitGuess()
            if vm.game.lastRejectionReason != nil {
                withAnimation(.linear(duration: 0.35)) { shakes += 1 }
            }
        case "DEL":
            vm.deleteLetter()
        default:
            if let letter = label.first { vm.typeLetter(letter) }
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 13, height: 13)
            Text(label).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
        }
    }
}

// MARK: - Tic-Tac-Toe (TicTacToeViewModel)

private struct TicTacToeComputerGame: View {
    let restart: () -> Void
    @ObservedObject var vm: TicTacToeViewModel              // retained by OfficeComputer.games

    private var winningLine: Set<Int> {
        for line in TicTacToeBoard.lines {
            if let mark = vm.board.cells[line[0]], line.allSatisfy({ vm.board.cells[$0] == mark }) { return Set(line) }
        }
        return []
    }

    private var status: (String, Color) {
        switch vm.board.winner() {
        case .x?: return ("You win!", GamePalette.win)
        case .o?: return ("The computer wins", GamePalette.lose)
        case nil:
            if vm.board.isFull { return ("Draw", GamePalette.neutral) }
            return vm.isComputerTurn ? ("Computer's move\u{2026}", GamePalette.them.opacity(0.95)) : ("Your move", GamePalette.turn)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.height, geo.size.width * 0.5, 240)
            HStack(spacing: 22) {
                VStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(0..<3, id: \.self) { col in cell(row * 3 + col, size: (side - 24) / 3) }
                        }
                    }
                }
                .padding(6)
                .background(Color(red: 0.2, green: 0.24, blue: 0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(spacing: 12) {
                    StatusLine(text: status.0, color: status.1)
                    Caption(text: "You are \u{2715} and go first.")
                    if vm.board.isGameOver {
                        BigButton(title: "Play again", color: vm.board.winner() == .x ? GamePalette.win : GamePalette.turn, action: restart)
                    }
                }
                .frame(minWidth: 150)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cell(_ index: Int, size: CGFloat) -> some View {
        let mark = vm.board.cells[index]
        let lit = winningLine.contains(index)
        return Button { vm.playerTapped(index) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lit ? Color.white : Color(red: 0.95, green: 0.95, blue: 0.97))
                if mark == .x {
                    Image(systemName: "xmark").font(.system(size: size * 0.46, weight: .heavy)).foregroundStyle(GamePalette.you)
                } else if mark == .o {
                    Image(systemName: "circle").font(.system(size: size * 0.46, weight: .heavy)).foregroundStyle(GamePalette.them)
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(lit ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        // Oct 7 (polish): not .disabled -- SwiftUI dims a disabled button, which
        // turned played squares a dark grey over the navy board and muddied
        // the X/O. Taps on played squares are already ignored (playerTapped
        // checks canTap), so the squares simply keep their light face.
        .allowsHitTesting(vm.canTap(index))
    }
}

// MARK: - Video Poker (FiveCardDrawViewModel) -- Jacks or Better
//
// Deal five, tap cards to HOLD, one DRAW, see the hand you made. The floor's
// five-card draw view model is reused as-is (its onWin and "pair or better"
// pass rule are never used here); the result is judged by VideoPokerHand
// (Jacks or Better) and announced with VideoPokerSound.
// Layout for the ~482 x 204 game area: one strip on top -- before the draw a
// compact two-row pay-table ladder, after it the hand announced big and loud
// -- with the one action button (Draw / New hand) at its right; below it five
// cards as big as the width allows (~87 x 124), each card + its HOLD tag one
// whole tap target. No credits, bets or balance: the ladder's numbers are the
// familiar relative values, for reference only.

private struct VideoPokerComputerGame: View {
    let restart: () -> Void
    @ObservedObject var vm: FiveCardDrawViewModel           // retained by OfficeComputer.games

    private var tint: Color { ComputerGameID.videoPoker.tint }
    private static let stripHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 8
            let w = min((geo.size.width - 4 * gap - 8) / 5, (geo.size.height - Self.stripHeight - 8 - 24 - 8) / 1.42, 96)
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    if vm.hasDrawn {
                        announcement(VideoPokerHand.of(vm.game.hand))
                        BigButton(title: "New hand", color: GamePalette.turn) { restart() }
                    } else {
                        payTable
                        BigButton(title: "Draw", color: tint) { draw() }
                    }
                }
                .frame(height: Self.stripHeight)
                HStack(spacing: gap) {
                    ForEach(Array(vm.game.hand.enumerated()), id: \.element.id) { i, card in
                        let held = vm.game.held.indices.contains(i) && vm.game.held[i]
                        Button { toggle(i) } label: {
                            VStack(spacing: 4) {
                                ColorCardView(card: card, width: w)
                                    .overlay(RoundedRectangle(cornerRadius: w * 0.11, style: .continuous)
                                        .fill(tint.opacity(held ? 0.10 : 0)))
                                    .overlay(RoundedRectangle(cornerRadius: w * 0.11, style: .continuous)
                                        .stroke(held ? tint : Color.clear, lineWidth: 3.5))
                                Text("HOLD")
                                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                                    .foregroundStyle(held ? Color.white : Color.clear)
                                    .padding(.horizontal, 10).frame(height: 20)
                                    .background(held ? tint : Color.clear, in: Capsule())
                            }
                            .offset(y: held && !vm.hasDrawn ? -6 : 0)
                            .animation(.easeOut(duration: 0.12), value: held)
                            .contentShape(Rectangle())          // the whole card + tag is the target
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!vm.hasDrawn)          // not .disabled: keeps the drawn hand at full contrast
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Strip

    /// Two rows of the ladder, lowest first: a reminder of what counts, not a betting table.
    private var payTable: some View {
        let rows = [Array(VideoPokerHand.payTable.prefix(5)), Array(VideoPokerHand.payTable.suffix(4))]
        return VStack(spacing: 2) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(rows[r], id: \.self) { hand in
                        HStack(spacing: 3) {
                            Text(hand.shortName).font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(HallwaysOS.ink.opacity(0.8))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                            Text("\(hand.value)").font(.system(size: 12, weight: .heavy, design: .rounded))
                                .foregroundStyle(Self.color(hand))
                        }
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// After the draw: the hand, big, in its tier's colour.
    private func announcement(_ hand: VideoPokerHand) -> some View {
        HStack(spacing: 10) {
            Text(hand.name)
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
            if hand.isWin {
                Text("\(hand.value)")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(Self.color(hand))
                    .padding(.horizontal, 9).frame(height: 30)
                    .background(Color.white, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hand.isWin ? Self.color(hand) : Color(red: 0.36, green: 0.39, blue: 0.44),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(hand.rawValue >= VideoPokerHand.fourOfAKind.rawValue ? 0.9 : 0), lineWidth: 2.5))
    }

    /// Tier colours, warming as the hands get rarer.
    static func color(_ hand: VideoPokerHand) -> Color {
        switch hand {
        case .nothing: return Color(red: 0.36, green: 0.39, blue: 0.44)
        case .jacksOrBetter: return Color(red: 0.16, green: 0.5, blue: 0.85)
        case .twoPair, .threeOfAKind: return Color(red: 0.12, green: 0.6, blue: 0.4)
        case .straight, .flush: return Color(red: 0.85, green: 0.6, blue: 0.08)
        case .fullHouse: return Color(red: 0.92, green: 0.42, blue: 0.1)
        case .fourOfAKind: return Color(red: 0.86, green: 0.18, blue: 0.3)
        case .straightFlush: return Color(red: 0.55, green: 0.25, blue: 0.85)
        case .royalFlush: return Color(red: 0.8, green: 0.15, blue: 0.6)
        }
    }

    // MARK: Actions + sound

    private func toggle(_ i: Int) {
        let wasHeld = vm.game.held.indices.contains(i) && vm.game.held[i]
        vm.toggleHold(at: i)
        VideoPokerSound.play(wasHeld ? .holdOff : .holdOn)
    }

    private func draw() {
        guard !vm.hasDrawn else { return }
        VideoPokerSound.play(.draw)
        vm.draw()
        let result = VideoPokerHand.of(vm.game.hand)
        VideoPokerSound.prepare(.result(result))               // rendered now, played as the cards land
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { VideoPokerSound.play(.result(result)) }
    }
}

// MARK: - Connect Four (ConnectFourViewModel)

private struct ConnectFourComputerGame: View {
    let restart: () -> Void
    @ObservedObject var vm: ConnectFourViewModel            // retained by OfficeComputer.games

    private var status: (String, Color) {
        switch vm.game.phase {
        case .playerTurn: return ("Your turn", GamePalette.turn)
        case .computerTurn: return ("Computer's turn\u{2026}", GamePalette.them.opacity(0.95))
        case .playerWon: return ("You win!", GamePalette.win)
        case .computerWon: return ("The computer wins", GamePalette.lose)
        case .draw: return ("Draw", GamePalette.neutral)
        }
    }

    private var isOver: Bool {
        switch vm.game.phase {
        case .playerWon, .computerWon, .draw: return vm.droppingColumn == nil
        default: return false
        }
    }

    var body: some View {
        GeometryReader { geo in
            let cols = ConnectFourBoard.columnCount, rows = ConnectFourBoard.rowCount
            let cell = min((geo.size.height - 12) / CGFloat(rows), (geo.size.width * 0.55 - 12) / CGFloat(cols), 40)
            HStack(spacing: 22) {
                ZStack {
                    VStack(spacing: 0) {
                        ForEach((0..<rows).reversed(), id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<cols, id: \.self) { col in slot(col: col, row: row, cell: cell) }
                            }
                        }
                    }
                    .padding(6)
                    .background(Color(red: 0.16, green: 0.38, blue: 0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    // Whole-column tap targets.
                    HStack(spacing: 0) {
                        ForEach(0..<cols, id: \.self) { col in
                            Color.white.opacity(0.001).frame(width: cell, height: cell * CGFloat(rows))
                                .contentShape(Rectangle())
                                .onTapGesture { vm.columnTapped(col) }
                        }
                    }
                }
                VStack(spacing: 12) {
                    StatusLine(text: status.0, color: status.1)
                    HStack(spacing: 12) {
                        legend("You", GamePalette.you)
                        legend("Computer", GamePalette.them)
                    }
                    if isOver { BigButton(title: "Play again", color: GamePalette.turn, action: restart) }
                }
                .frame(minWidth: 150)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func slot(col: Int, row: Int, cell: CGFloat) -> some View {
        let piece = vm.game.board.piece(atColumn: col, row: row)
        let isDropping = vm.droppingColumn == col && row == vm.game.board.columns[col].count - 1
        let lit = vm.game.winningLine.contains(ConnectFourCoordinate(column: col, row: row))
        return ZStack {
            Circle().fill(Color(red: 0.08, green: 0.16, blue: 0.36)).padding(cell * 0.09)
            if let piece {
                Circle().fill(piece == .player ? GamePalette.you : GamePalette.them)
                    .overlay(Circle().stroke(Color.white, lineWidth: lit ? 2.5 : 0))
                    .padding(cell * 0.09)
                    .offset(y: isDropping && vm.dropAtTop ? -cell * CGFloat(ConnectFourBoard.rowCount - row) : 0)
            }
        }
        .frame(width: cell, height: cell)
        .zIndex(isDropping ? 1 : 0)
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 13, height: 13)
            Text(label).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
        }
    }
}

// MARK: - Hangman (HangmanViewModel)

private struct HangmanComputerGame: View {
    let restart: () -> Void
    @ObservedObject var vm: HangmanViewModel                // retained by OfficeComputer.games
    private let rows = ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"]

    /// Oct 7 (polish): the keyboard is the repeated precision target, so it
    /// gets the space: the figure alone on the left, and the status, the
    /// word and SQUARE keys as large as the width/height allow on the right.
    private static let figureSide: CGFloat = 92
    private static let keyGap: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let rightWidth = geo.size.width - Self.figureSide - 12
            let key = min((rightWidth - 9 * Self.keyGap) / 10,
                          (geo.size.height - 34 - 40 - 12 - 2 * Self.keyGap) / 3,
                          40)
            HStack(spacing: 12) {
                HangmanFigure(wrong: vm.game.wrongGuessCount)
                    .frame(width: Self.figureSide, height: Self.figureSide)
                VStack(spacing: 6) {
                    switch vm.game.phase {
                    case .success: StatusLine(text: "Solved!", color: GamePalette.win)
                    case .failure: StatusLine(text: "The word was \(vm.game.word)", color: GamePalette.lose)
                    default: StatusLine(text: "\(HangmanGame.maxWrongGuesses - vm.game.wrongGuessCount) chances left", color: GamePalette.turn)
                    }
                    HStack(spacing: 6) {
                        ForEach(Array(vm.game.revealedWord.enumerated()), id: \.offset) { _, letter in
                            Text(letter.map { String($0) } ?? " ")
                                .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(HallwaysOS.ink)
                                .frame(width: 32, height: 40)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(Rectangle().fill(ComputerGameID.hangman.tint).frame(height: 3), alignment: .bottom)
                        }
                    }
                    if vm.game.phase == .playing {
                        VStack(spacing: Self.keyGap) {
                            ForEach(rows, id: \.self) { row in
                                HStack(spacing: Self.keyGap) {
                                    ForEach(Array(row), id: \.self) { letter in keyButton(letter, size: key) }
                                }
                            }
                        }
                    } else {
                        BigButton(title: "Play again", color: vm.game.phase == .success ? GamePalette.win : GamePalette.turn, action: restart)
                    }
                }
                .frame(width: rightWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func keyButton(_ letter: Character, size: CGFloat) -> some View {
        let tried = vm.game.guessedLetters.contains(letter)
        let hit = tried && vm.game.word.contains(letter)
        let fill: Color = !tried ? .white : (hit ? GamePalette.win : Color(red: 0.8, green: 0.81, blue: 0.84))
        return Button { vm.guessLetter(letter) } label: {
            Text(String(letter)).font(.system(size: size * 0.52, weight: .bold, design: .rounded))
                .foregroundStyle(tried ? (hit ? Color.white : HallwaysOS.inkSoft) : HallwaysOS.ink)
                .frame(width: size, height: size)
                .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(tried ? 0 : 0.12), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!tried)                      // not .disabled: the tried keys keep their own colours
    }
}

/// Gallows and figure, drawn in parts as wrong guesses accumulate (0...6).
private struct HangmanFigure: View {
    let wrong: Int
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var gallows = Path()
            gallows.move(to: CGPoint(x: w * 0.1, y: h * 0.95)); gallows.addLine(to: CGPoint(x: w * 0.6, y: h * 0.95))
            gallows.move(to: CGPoint(x: w * 0.25, y: h * 0.95)); gallows.addLine(to: CGPoint(x: w * 0.25, y: h * 0.05))
            gallows.addLine(to: CGPoint(x: w * 0.68, y: h * 0.05)); gallows.addLine(to: CGPoint(x: w * 0.68, y: h * 0.17))
            ctx.stroke(gallows, with: .color(Color(red: 0.45, green: 0.32, blue: 0.2)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            let cx = w * 0.68
            let neck = CGPoint(x: cx, y: h * 0.17 + w * 0.18), hip = CGPoint(x: cx, y: h * 0.62)
            let shoulder = CGPoint(x: cx, y: h * 0.45)
            var figure = Path()
            if wrong >= 1 { figure.addEllipse(in: CGRect(x: cx - w * 0.09, y: h * 0.17, width: w * 0.18, height: w * 0.18)) }
            let limbs: [(CGPoint, CGPoint)] = [
                (neck, hip),
                (shoulder, CGPoint(x: cx - w * 0.14, y: h * 0.36)),
                (shoulder, CGPoint(x: cx + w * 0.14, y: h * 0.36)),
                (hip, CGPoint(x: cx - w * 0.12, y: h * 0.82)),
                (hip, CGPoint(x: cx + w * 0.12, y: h * 0.82))
            ]
            for (i, limb) in limbs.enumerated() where wrong >= i + 2 {
                figure.move(to: limb.0)
                figure.addLine(to: limb.1)
            }
            ctx.stroke(figure, with: .color(ComputerGameID.hangman.tint), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        }
    }
}
