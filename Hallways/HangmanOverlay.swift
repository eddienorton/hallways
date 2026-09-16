import SwiftUI
import Combine

/// Drives one Floor 12 Hangman playthrough -- word selection and
/// guesses (Eddie, Sept 14). Same shape as HigherLowerViewModel: the
/// game begins the instant the terminal activates, no separate START
/// tap -- Eddie's own framing shows the blanks and alphabet
/// immediately, and there is no timer/urgency here that a deliberate
/// "not yet" gate would be protecting the player from (contrast
/// Simon/Whack-A-Mole, which both needed one). Calls back into
/// TapNavigationController exactly once via onWin, and -- matching
/// every other terminal's pacing fix -- never auto-dismisses a
/// result. Both the success and failure screens stay up exactly until
/// the player taps.
///
/// Product intent (Eddie): "We are trying to trigger recognition and
/// nostalgia... Do not reinvent Hangman... Hangman should simply feel
/// like Hangman." This view model is deliberately thin -- word
/// selection (HangmanWordPicker) plus one Combine-free state machine
/// (HangmanGame), nothing else. "THE GAME IS REAL. FAILURE IS CHEAP":
/// guesses are never rigged, but a loss resets straight into a fresh
/// word with no penalty and no lingering "ready" screen.
@MainActor
final class HangmanViewModel: ObservableObject {
    @Published private(set) var game = HangmanGame()

    /// Fired exactly once, the instant the PLAYER taps through a
    /// SUCCESS result screen -- HangmanOverlay wires this to
    /// TapNavigationController.completeHangmanTerminal(at:).
    var onWin: (() -> Void)?

    private var rng = SystemRandomNumberGenerator()
    /// The word just played -- passed to HangmanWordPicker on RETRY so
    /// Eddie's "select another word if reasonably possible" never
    /// repeats the same word twice in a row.
    private var lastWord: String?

    init() {
        let word = HangmanWordPicker.pickWord(using: &rng)
        game.start(word: word)
        lastWord = word
    }

    var statusText: String {
        switch game.phase {
        case .ready:
            return "" // unreachable in practice -- init() always starts the game immediately
        case .playing:
            return "GUESS THE WORD"
        case .success:
            return "WORD: SOLVED\n\nELEVATOR ACCESS GRANTED."
        case .failure:
            return "THE WORD WAS \(game.word)"
        }
    }

    func guessLetter(_ letter: Character) {
        game.guess(letter)
    }

    /// TAP TO CONTINUE (success) fires onWin?(). TAP TO RETRY
    /// (failure) -- Eddie: "Losing should be painless and RETRY
    /// immediate" -- picks a fresh word (excluding the one just
    /// played) and starts right back up; nothing lingers on a "ready"
    /// screen and no state carries over.
    func continueAfterResult() {
        switch game.phase {
        case .success:
            onWin?()
        case .failure:
            let word = HangmanWordPicker.pickWord(excluding: lastWord, using: &rng)
            game.reset()
            game.start(word: word)
            lastWord = word
        case .ready, .playing:
            break
        }
    }
}

/// Presented over the 3D scene the instant the player approaches and
/// faces Floor 12's terminal (see
/// TapNavigationController.activateHangmanTerminal) -- same "dark
/// scrim + centered panel, green-on-black terminal" visual language as
/// every other floor's terminal.
struct HangmanOverlayHost: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        if let coord = controller.activeHangmanTerminal {
            HangmanOverlay(controller: controller, coord: coord)
        }
    }
}

private struct HangmanOverlay: View {
    @ObservedObject var controller: TapNavigationController
    let coord: GridCoordinate
    @StateObject private var viewModel = HangmanViewModel()

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { handleSurfaceTap() }
            VStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text("BUILDING CHALLENGE")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.green.opacity(0.85))
                    Text("WORD ASSESSMENT")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                }
                HangmanFigureShape(wrongGuessCount: viewModel.game.wrongGuessCount)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: 110, height: 130)
                    .accessibilityIdentifier("hangmanFigure")
                wordBlanks
                Text(viewModel.statusText)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 34)
                    .accessibilityIdentifier("hangmanStatus")
                if showAlphabet {
                    alphabetGrid
                    // Eddie's own established rule (carried over from
                    // Rock Paper Scissors/Simon): "Step Away" is only
                    // useful while the player is still choosing --
                    // once a result is up it stays up until tapped,
                    // so the button would just be visual noise sitting
                    // over a screen that's about to change on its own.
                    Button("Step Away") { controller.cancelHangmanTerminal() }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 120, minHeight: 42)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .accessibilityIdentifier("stepAwayFromHangmanButton")
                } else {
                    actionArea
                }
            }
            .padding(20)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.5), lineWidth: 2))
            .padding(24)
            .contentShape(Rectangle())
            .onTapGesture { handleSurfaceTap() }
        }
        .accessibilityAction(.escape) { controller.cancelHangmanTerminal() }
        .onAppear { viewModel.onWin = { controller.completeHangmanTerminal(at: coord) } }
    }

    /// The alphabet (and Step Away) are shown only while a guess is
    /// still meaningful; hidden the instant a result is up, same as
    /// every other terminal's choice-controls-hide-on-result rule.
    private var showAlphabet: Bool {
        viewModel.game.phase == .playing
    }

    private var wordBlanks: some View {
        HStack(spacing: 10) {
            ForEach(0..<HangmanGame.wordLength, id: \.self) { index in
                let letter = viewModel.game.revealedWord[index]
                Text(letter.map(String.init) ?? "_")
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(width: 26)
            }
        }
        .accessibilityIdentifier("hangmanWordBlanks")
    }

    /// Eddie, Floor 12 polish: "Change ONLY the keyboard layout to a
    /// standard familiar QWERTY arrangement... Adjust spacing/
    /// centering as necessary so it looks clean and all keys remain
    /// large and easy to tap." Three staggered rows (10/9/7 keys) --
    /// SwiftUI's default center alignment on the outer VStack gives
    /// the familiar QWERTY "staircase" look for free, with no manual
    /// per-row offsets needed.
    private static let qwertyRow1: [Character] = Array("QWERTYUIOP")
    private static let qwertyRow2: [Character] = Array("ASDFGHJKL")
    private static let qwertyRow3: [Character] = Array("ZXCVBNM")

    private var alphabetGrid: some View {
        VStack(spacing: 8) {
            qwertyRow(HangmanOverlay.qwertyRow1)
            qwertyRow(HangmanOverlay.qwertyRow2)
            qwertyRow(HangmanOverlay.qwertyRow3)
        }
        .frame(maxWidth: 360)
    }

    private func qwertyRow(_ letters: [Character]) -> some View {
        HStack(spacing: 6) {
            ForEach(letters, id: \.self) { letter in
                letterButton(letter)
            }
        }
    }

    /// Eddie: "Used letters should visibly become unavailable/dimmed."
    private func letterButton(_ letter: Character) -> some View {
        let guessed = viewModel.game.guessedLetters.contains(letter)
        return Button {
            viewModel.guessLetter(letter)
        } label: {
            Text(String(letter))
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(guessed ? Color.green.opacity(0.25) : .green)
                .frame(width: 32)
                .frame(minHeight: 42)
                .background(Color.white.opacity(guessed ? 0.02 : 0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(guessed ? 0.15 : 0.5), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(guessed || viewModel.game.phase != .playing)
        .accessibilityIdentifier("hangmanLetter_\(letter)")
    }

    /// Eddie: "On loss, reveal the word and provide an immediate
    /// RETRY... Do NOT auto-dismiss." Same player-paced result
    /// contract as every other terminal.
    @ViewBuilder
    private var actionArea: some View {
        switch viewModel.game.phase {
        case .success, .failure:
            Button {
                viewModel.continueAfterResult()
            } label: {
                Text(viewModel.game.phase == .success ? "TAP TO CONTINUE" : "TAP TO RETRY")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(minWidth: 220, minHeight: 50)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.5), lineWidth: 2))
            }
            .accessibilityIdentifier("hangmanContinueButton")
        case .ready, .playing:
            EmptyView()
        }
    }

    /// Mirrors SimonOverlay/WhackAMoleOverlay's handleSurfaceTap: once
    /// a result is showing, a tap anywhere on the terminal surface
    /// continues, same as the dedicated button.
    private func handleSurfaceTap() {
        guard viewModel.game.phase == .success || viewModel.game.phase == .failure else { return }
        viewModel.continueAfterResult()
    }
}

/// Classic Hangman line art -- Eddie: "The Hangman drawing should be
/// simple green line art on black." The gallows (base, upright, beam,
/// rope) are always fully drawn since they carry no information about
/// guesses; each wrong guess then reveals one more part of the figure,
/// in the traditional order (head, body, left arm, right arm, left
/// leg, right leg) -- exactly 6 parts, one per wrong guess, so the
/// drawing finishes exactly on the losing guess (Eddie: "Allow 6 wrong
/// guesses before losing").
private struct HangmanFigureShape: Shape {
    let wrongGuessCount: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        // Gallows -- always fully drawn.
        let baseY = h * 0.95
        path.move(to: CGPoint(x: w * 0.06, y: baseY))
        path.addLine(to: CGPoint(x: w * 0.56, y: baseY))
        path.move(to: CGPoint(x: w * 0.2, y: baseY))
        path.addLine(to: CGPoint(x: w * 0.2, y: h * 0.05))
        path.addLine(to: CGPoint(x: w * 0.68, y: h * 0.05))
        path.addLine(to: CGPoint(x: w * 0.68, y: h * 0.18))

        guard wrongGuessCount >= 1 else { return path }
        // Head.
        let headRadius = w * 0.09
        let headCenter = CGPoint(x: w * 0.68, y: h * 0.18 + headRadius)
        path.addEllipse(in: CGRect(x: headCenter.x - headRadius, y: headCenter.y - headRadius,
                                    width: headRadius * 2, height: headRadius * 2))

        guard wrongGuessCount >= 2 else { return path }
        // Body.
        path.move(to: CGPoint(x: w * 0.68, y: headCenter.y + headRadius))
        path.addLine(to: CGPoint(x: w * 0.68, y: h * 0.62))

        guard wrongGuessCount >= 3 else { return path }
        // Left arm.
        path.move(to: CGPoint(x: w * 0.68, y: h * 0.42))
        path.addLine(to: CGPoint(x: w * 0.54, y: h * 0.52))

        guard wrongGuessCount >= 4 else { return path }
        // Right arm.
        path.move(to: CGPoint(x: w * 0.68, y: h * 0.42))
        path.addLine(to: CGPoint(x: w * 0.82, y: h * 0.52))

        guard wrongGuessCount >= 5 else { return path }
        // Left leg.
        path.move(to: CGPoint(x: w * 0.68, y: h * 0.62))
        path.addLine(to: CGPoint(x: w * 0.56, y: h * 0.8))

        guard wrongGuessCount >= 6 else { return path }
        // Right leg.
        path.move(to: CGPoint(x: w * 0.68, y: h * 0.62))
        path.addLine(to: CGPoint(x: w * 0.8, y: h * 0.8))

        return path
    }
}
