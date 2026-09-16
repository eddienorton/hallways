import SwiftUI
import Combine

/// Drives one Floor 16 Woidle playthrough -- answer selection, typed
/// input, and submitted guesses (Eddie, Sept 14). Same shape as
/// HangmanViewModel: the game begins the instant the terminal
/// activates, no separate START tap. Calls back into
/// TapNavigationController exactly once via onWin, and -- matching
/// every other terminal's pacing fix -- never auto-dismisses a
/// result. Both the WIN and LOSS screens stay up exactly until the
/// player taps.
///
/// Product intent (Eddie): "This should evoke the familiar five-letter
/// word deduction game immediately without copying branded visual
/// design... Do not over-explain it. Do not reinvent the rules to
/// make it 'ours.'" This view model is deliberately thin -- answer
/// selection (WoidleAnswerPicker) plus one dependency-free state
/// machine (WoidleGame), nothing else.
@MainActor
final class WoidleViewModel: ObservableObject {
    @Published private(set) var game = WoidleGame()

    /// Fired exactly once, the instant the PLAYER taps through a WIN
    /// result screen -- WoidleOverlay wires this to
    /// TapNavigationController.completeWoidleTerminal(at:).
    var onWin: (() -> Void)?

    private var rng = SystemRandomNumberGenerator()
    /// The answer just played -- passed to WoidleAnswerPicker on
    /// RETRY so Eddie's "avoid repeating the same answer if
    /// practical" never repeats the same word twice in a row.
    private var lastAnswer: String?

    init() {
        let answer = WoidleAnswerPicker.pickAnswer(using: &rng)
        game.start(answer: answer)
        lastAnswer = answer
    }

    var statusText: String {
        if let reason = game.lastRejectionReason {
            return reason
        }
        switch game.phase {
        case .playing:
            return "GUESS THE WORD"
        case .won:
            return "YOU WIN\n\nWORD ASSESSMENT PASSED\n\nELEVATOR ACCESS GRANTED."
        case .lost:
            return "ANSWER: \(game.answer)"
        }
    }

    func typeLetter(_ letter: Character) {
        game.typeLetter(letter)
    }

    func deleteLetter() {
        game.deleteLetter()
    }

    func submitGuess() {
        game.submit { WoidleWordBank.isAllowed($0) }
    }

    /// TAP TO CONTINUE (won) fires onWin?(). TAP TO RETRY (lost) --
    /// Eddie: "Failure has no lives, money penalty, or dead end...
    /// retry starts a fresh puzzle" -- picks a fresh answer (excluding
    /// the one just played) and starts right back up; nothing lingers
    /// on a stale board and no state carries over.
    func continueAfterResult() {
        switch game.phase {
        case .won:
            onWin?()
        case .lost:
            let answer = WoidleAnswerPicker.pickAnswer(excluding: lastAnswer, using: &rng)
            game.reset()
            game.start(answer: answer)
            lastAnswer = answer
        case .playing:
            break
        }
    }
}

/// Presented over the 3D scene the instant the player approaches and
/// faces Floor 16's terminal (see
/// TapNavigationController.activateWoidleTerminal) -- same "dark
/// scrim + centered panel, green-on-black terminal" visual language as
/// every other floor's terminal.
struct WoidleOverlayHost: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        if let coord = controller.activeWoidleTerminal {
            WoidleOverlay(controller: controller, coord: coord)
        }
    }
}

private struct WoidleOverlay: View {
    @ObservedObject var controller: TapNavigationController
    let coord: GridCoordinate
    @StateObject private var viewModel = WoidleViewModel()

    // Eddie: "Hallways black/green terminal aesthetic. Do NOT mimic
    // the branded Wordle beige/white webpage." Three full-opacity,
    // non-blended colors (same "solid fill, not a low-opacity tint"
    // fix Floor 15's checkerboard needed) so the three evaluated
    // states stay "immediately distinguishable on an actual iPhone"
    // -- separated in both brightness AND saturation, not just a
    // grid-line-brightness nudge.
    private static let emptyTileFill = Color(red: 5.0 / 255.0, green: 8.0 / 255.0, blue: 6.0 / 255.0)
    private static let absentTileFill = Color(red: 58.0 / 255.0, green: 62.0 / 255.0, blue: 58.0 / 255.0)
    private static let presentTileFill = Color(red: 86.0 / 255.0, green: 138.0 / 255.0, blue: 98.0 / 255.0)
    private static let correctTileFill = Color(red: 40.0 / 255.0, green: 214.0 / 255.0, blue: 100.0 / 255.0)
    private static let typedTileBorder = Color(red: 150.0 / 255.0, green: 170.0 / 255.0, blue: 155.0 / 255.0)

    private static let woidleRow1: [Character] = Array("QWERTYUIOP")
    private static let woidleRow2: [Character] = Array("ASDFGHJKL")
    private static let woidleRow3: [Character] = Array("ZXCVBNM")

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { handleSurfaceTap() }
            VStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text("BUILDING CHALLENGE")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.green.opacity(0.85))
                    Text("VERBAL ASSESSMENT")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                }
                board
                Text(viewModel.statusText)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 34)
                    .accessibilityIdentifier("woidleStatus")
                if showKeyboard {
                    keyboard
                    // Eddie's own established rule (carried over from
                    // Hangman/Rock Paper Scissors/Simon): "Step Away"
                    // is only useful while the player is still
                    // guessing -- once a result is up it stays up
                    // until tapped, so the button would just be
                    // visual noise sitting over a screen that's about
                    // to change on its own.
                    Button("Step Away") { controller.cancelWoidleTerminal() }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 120, minHeight: 42)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .accessibilityIdentifier("stepAwayFromWoidleButton")
                } else {
                    actionArea
                }
            }
            .padding(18)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.5), lineWidth: 2))
            .padding(24)
            .contentShape(Rectangle())
            .onTapGesture { handleSurfaceTap() }
        }
        .accessibilityAction(.escape) { controller.cancelWoidleTerminal() }
        .onAppear { viewModel.onWin = { controller.completeWoidleTerminal(at: coord) } }
    }

    /// The keyboard (and Step Away) are shown only while a guess is
    /// still meaningful; hidden the instant a result is up, same as
    /// every other terminal's choice-controls-hide-on-result rule.
    private var showKeyboard: Bool {
        viewModel.game.phase == .playing
    }

    private var board: some View {
        VStack(spacing: 6) {
            ForEach(0..<WoidleGame.maxGuesses, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<WoidleGame.wordLength, id: \.self) { col in
                        tileView(row: row, col: col)
                    }
                }
            }
        }
        .accessibilityIdentifier("woidleBoard")
    }

    private enum TileState {
        case empty, typed, absent, present, correct
    }

    private func tileContent(row: Int, col: Int) -> (letter: Character?, state: TileState) {
        let game = viewModel.game
        if row < game.guesses.count {
            let letters = Array(game.guesses[row])
            let results = game.evaluations[row]
            switch results[col] {
            case .correct: return (letters[col], .correct)
            case .present: return (letters[col], .present)
            case .absent: return (letters[col], .absent)
            }
        } else if row == game.guesses.count {
            let typed = Array(game.currentInput)
            if col < typed.count {
                return (typed[col], .typed)
            }
        }
        return (nil, .empty)
    }

    private func tileFill(_ state: TileState) -> Color {
        switch state {
        case .empty, .typed: return Self.emptyTileFill
        case .absent: return Self.absentTileFill
        case .present: return Self.presentTileFill
        case .correct: return Self.correctTileFill
        }
    }

    private func tileBorder(_ state: TileState) -> Color {
        switch state {
        case .empty: return Color.green.opacity(0.3)
        case .typed: return Self.typedTileBorder.opacity(0.9)
        case .absent, .present, .correct: return Color.black.opacity(0.3)
        }
    }

    private func tileView(row: Int, col: Int) -> some View {
        let content = tileContent(row: row, col: col)
        return RoundedRectangle(cornerRadius: 6)
            .fill(tileFill(content.state))
            .frame(width: 42, height: 42)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(tileBorder(content.state), lineWidth: content.state == .typed ? 2.5 : 2)
            )
            .overlay(
                Text(content.letter.map(String.init) ?? "")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(content.state == .absent ? Color.white.opacity(0.55) : Color.white)
            )
    }

    /// Eddie: "Include: A-Z, ENTER/SUBMIT, DELETE/BACKSPACE." Same
    /// three-row QWERTY layout as the Hangman polish, with ENTER and
    /// DELETE flanking the bottom row -- the familiar full-keyboard
    /// arrangement, not an alphabetical grid.
    private var keyboard: some View {
        VStack(spacing: 8) {
            keyRow(Self.woidleRow1)
            keyRow(Self.woidleRow2)
            HStack(spacing: 5) {
                enterKey
                ForEach(Self.woidleRow3, id: \.self) { letter in
                    keyButton(letter)
                }
                deleteKey
            }
        }
        .frame(maxWidth: 360)
    }

    private func keyRow(_ letters: [Character]) -> some View {
        HStack(spacing: 5) {
            ForEach(letters, id: \.self) { letter in
                keyButton(letter)
            }
        }
    }

    private func keyBackground(_ status: WoidleGame.KeyStatus) -> Color {
        switch status {
        case .unknown: return Color.white.opacity(0.06)
        case .absent: return Self.absentTileFill.opacity(0.7)
        case .present: return Self.presentTileFill
        case .correct: return Self.correctTileFill
        }
    }

    private func keyForeground(_ status: WoidleGame.KeyStatus) -> Color {
        switch status {
        case .unknown: return .green
        case .absent: return Color.green.opacity(0.3)
        case .present, .correct: return Color.black.opacity(0.85)
        }
    }

    private func keyBorder(_ status: WoidleGame.KeyStatus) -> Color {
        switch status {
        case .unknown: return Color.green.opacity(0.5)
        case .absent: return Color.green.opacity(0.15)
        case .present, .correct: return Color.black.opacity(0.3)
        }
    }

    /// Eddie: "letters proven absent become visually subdued... known
    /// present retain a meaningful state... confirmed correct should
    /// have strongest positive state."
    private func keyButton(_ letter: Character) -> some View {
        let status = viewModel.game.keyStatuses[letter] ?? .unknown
        return Button {
            viewModel.typeLetter(letter)
        } label: {
            Text(String(letter))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(keyForeground(status))
                .frame(width: 30)
                .frame(minHeight: 42)
                .background(keyBackground(status), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(keyBorder(status), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.game.phase != .playing)
        .accessibilityIdentifier("woidleKey_\(letter)")
    }

    private var enterKey: some View {
        Button {
            viewModel.submitGuess()
        } label: {
            Text("ENTER")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.green)
                .frame(width: 42)
                .frame(minHeight: 42)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.5), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.game.phase != .playing || viewModel.game.currentInput.count != WoidleGame.wordLength)
        .accessibilityIdentifier("woidleEnterKey")
    }

    private var deleteKey: some View {
        Button {
            viewModel.deleteLetter()
        } label: {
            Text("DEL")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.green)
                .frame(width: 38)
                .frame(minHeight: 42)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.5), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.game.phase != .playing || viewModel.game.currentInput.isEmpty)
        .accessibilityIdentifier("woidleDeleteKey")
    }

    /// Eddie: "preserve the completed board... clearly reveal...
    /// retry starts a fresh puzzle." Same player-paced result
    /// contract as every other terminal -- TAP TO CONTINUE/TAP TO
    /// RETRY never appears until the player has actually seen the
    /// finished board.
    @ViewBuilder
    private var actionArea: some View {
        switch viewModel.game.phase {
        case .won, .lost:
            Button {
                viewModel.continueAfterResult()
            } label: {
                Text(viewModel.game.phase == .won ? "TAP TO CONTINUE" : "TAP TO RETRY")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(minWidth: 220, minHeight: 50)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.5), lineWidth: 2))
            }
            .accessibilityIdentifier("woidleContinueButton")
        case .playing:
            EmptyView()
        }
    }

    /// Mirrors HangmanOverlay/SimonOverlay's handleSurfaceTap: once a
    /// result is showing, a tap anywhere on the terminal surface
    /// continues, same as the dedicated button.
    private func handleSurfaceTap() {
        guard viewModel.game.phase == .won || viewModel.game.phase == .lost else { return }
        viewModel.continueAfterResult()
    }
}
