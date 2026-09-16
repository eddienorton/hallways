import SwiftUI
import Combine

/// Drives one Floor 9 round -- the computer's move, the player's tap,
/// and the simultaneous reveal (Eddie, Sept 13). Same shape as
/// TicTacToeViewModel/ShellGameViewModel: dumb about anything outside
/// the round itself, calls back into TapNavigationController exactly
/// once via onWin.
///
/// The honesty guarantee: computerMove is chosen ONCE, in beginRound,
/// the instant a round starts -- before the player has touched
/// anything. choose(_:) only ever READS that already-decided value
/// (via RPSGame.outcome) and never re-picks or adjusts it, so there
/// is no path from "see the player's move" back to "change the
/// computer's answer."
@MainActor
final class RockPaperScissorsViewModel: ObservableObject {
    enum Phase {
        case waitingForChoice
        case revealed
    }

    @Published private(set) var phase: Phase = .waitingForChoice
    @Published private(set) var statusText = "CHOOSE YOUR MOVE"
    /// Chosen the instant a round begins (see beginRound) -- fixed
    /// and hidden from the player until choose(_:) reveals it. Never
    /// reassigned in response to the player's own choice.
    private(set) var computerMove: RPSMove

    /// Fired exactly once, the instant the player's move beats the
    /// computer's -- RockPaperScissorsOverlay wires this to
    /// TapNavigationController.completeRockPaperScissorsTerminal(at:).
    var onWin: (() -> Void)?

    private var rng = SystemRandomNumberGenerator()
    /// Invalidates a stray reset timer from a previous round the
    /// moment a new one begins, same role as ShellGameViewModel's.
    private var runToken = UUID()

    init() {
        computerMove = RPSGame.randomMove(using: &rng)
    }

    var canChoose: Bool { phase == .waitingForChoice }

    func choose(_ move: RPSMove) {
        guard phase == .waitingForChoice else { return }
        let token = UUID()
        runToken = token
        let result = RPSGame.outcome(player: move, computer: computerMove)
        phase = .revealed
        let resultLine: String
        switch result {
        case .playerWins: resultLine = "YOU WIN"
        case .computerWins: resultLine = "BUILDING WINS"
        case .tie: resultLine = "TIE"
        }
        statusText = "YOU: \(move.displayName)\nBUILDING: \(computerMove.displayName)\n\n\(resultLine)"
        switch result {
        case .playerWins:
            // No reset scheduled here -- TapNavigationController takes
            // over from here exactly like completeTicTacToeTerminal/
            // completeShellGameTerminal: it dismisses this whole
            // overlay a beat later, so there is nothing for this view
            // model to clean up itself.
            onWin?()
        case .computerWins, .tie:
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, self.runToken == token else { return }
                self.beginRound()
            }
        }
    }

    private func beginRound() {
        computerMove = RPSGame.randomMove(using: &rng)
        phase = .waitingForChoice
        statusText = "CHOOSE YOUR MOVE"
    }
}

/// Presented over the 3D scene the instant the player approaches and
/// faces Floor 9's terminal (see
/// TapNavigationController.activateRockPaperScissorsTerminal) --
/// identical "dark scrim + centered panel, tap scrim or a button to
/// step away" shape as TicTacToeOverlay/ShellGameOverlay.
struct RockPaperScissorsOverlayHost: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        if let coord = controller.activeRockPaperScissorsTerminal {
            RockPaperScissorsOverlay(controller: controller, coord: coord)
        }
    }
}

private struct RockPaperScissorsOverlay: View {
    @ObservedObject var controller: TapNavigationController
    let coord: GridCoordinate
    @StateObject private var game = RockPaperScissorsViewModel()

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { controller.cancelRockPaperScissorsTerminal() }
            VStack(spacing: 18) {
                VStack(spacing: 2) {
                    Text("BUILDING CHALLENGE")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.green.opacity(0.85))
                    Text("ROCK  PAPER  SCISSORS")
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                }
                Text(game.statusText)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 70)
                    .accessibilityIdentifier("rpsStatus")
                if game.canChoose {
                    choices
                    // Eddie, Sept 13: "Step Away" is only useful while
                    // the player is still choosing -- once a round has
                    // resolved (win, loss, or tie) the result display
                    // is temporary and self-dismissing/self-resetting,
                    // so the button would just be visual noise sitting
                    // over a screen that's about to change on its own.
                    Button("Step Away") { controller.cancelRockPaperScissorsTerminal() }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 120, minHeight: 42)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .accessibilityIdentifier("stepAwayFromRockPaperScissorsButton")
                }
            }
            .padding(24)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.5), lineWidth: 2))
            .padding(28)
        }
        .accessibilityAction(.escape) { controller.cancelRockPaperScissorsTerminal() }
        .onAppear { game.onWin = { controller.completeRockPaperScissorsTerminal(at: coord) } }
    }

    private var choices: some View {
        HStack(spacing: 10) {
            ForEach(RPSMove.allCases, id: \.self) { move in
                Button {
                    game.choose(move)
                } label: {
                    Text(move.displayName)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(width: 82, height: 54)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.5), lineWidth: 2))
                }
                .accessibilityIdentifier("rpsChoice_\(move.rawValue)")
            }
        }
    }
}
