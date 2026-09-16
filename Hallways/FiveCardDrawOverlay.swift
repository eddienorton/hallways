import SwiftUI
import Combine

/// Drives one Floor 11 hand -- the deal, the hold toggles, the one
/// draw, and the resulting category (Eddie, Sept 13). Same shape as
/// HigherLowerViewModel: dumb about anything outside the game itself,
/// calls back into TapNavigationController exactly once via onWin,
/// and -- following the same pacing fix Floor 10 just got -- never
/// auto-advances on a timer. The result (pass or fail) stays on
/// screen exactly until the player taps TAP TO CONTINUE / TAP TO
/// RETRY.
@MainActor
final class FiveCardDrawViewModel: ObservableObject {
    @Published private(set) var game: FiveCardDrawGame
    private var rng = SystemRandomNumberGenerator()

    /// Fired exactly once, the instant the PLAYER taps through a
    /// PASSING result screen -- FiveCardDrawOverlay wires this to
    /// TapNavigationController.completeFiveCardDrawTerminal(at:).
    var onWin: (() -> Void)?

    init() {
        game = FiveCardDrawGame(rng: &rng)
    }

    var hasDrawn: Bool { game.hasDrawn }
    var qualifies: Bool { game.qualifies }

    /// Eddie: extremely light explanation before the deal ("BUILDING
    /// CHALLENGE / FIVE-CARD DRAW / PAIR OR BETTER" lives in the view
    /// itself, not here); once drawn, the category name plus a plain
    /// pass/fail line, matching the FLOOR 10 RESULT SCREEN examples.
    var statusText: String {
        guard game.hasDrawn else { return "TAP CARDS TO HOLD, THEN DRAW" }
        return game.qualifies
            ? "\(game.category.displayName)\n\nTEST PASSED\n\nELEVATOR ACCESS GRANTED."
            : "\(game.category.displayName)\n\nNOT GOOD ENOUGH"
    }

    func toggleHold(at index: Int) {
        game.toggleHold(at: index)
    }

    func draw() {
        game.draw()
    }

    /// TAP TO CONTINUE (qualifying hand) fires onWin?(), same
    /// dismiss-on-tap contract as Higher/Lower's continueFromResult().
    /// TAP TO RETRY (High Card) -- Eddie: "No lives. No punishment...
    /// allow immediate retry" -- just deals a brand-new hand off a
    /// freshly shuffled deck; nothing about the failed hand carries
    /// over.
    func continueAfterResult() {
        guard game.hasDrawn else { return }
        if game.qualifies {
            onWin?()
        } else {
            game = FiveCardDrawGame(rng: &rng)
        }
    }
}

/// Presented over the 3D scene the instant the player approaches and
/// faces Floor 11's terminal (see
/// TapNavigationController.activateFiveCardDrawTerminal) -- same
/// "dark scrim + centered panel, green-on-black terminal" visual
/// language as Floors 7-10. Five cards, tap a card to toggle HOLD
/// (green outline + a slight lift + a HOLD label), DRAW replaces
/// every unheld card once, then the result is player-paced exactly
/// like Floor 10's Higher/Lower.
struct FiveCardDrawOverlayHost: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        if let coord = controller.activeFiveCardDrawTerminal {
            FiveCardDrawOverlay(controller: controller, coord: coord)
        }
    }
}

private struct FiveCardDrawOverlay: View {
    @ObservedObject var controller: TapNavigationController
    let coord: GridCoordinate
    @StateObject private var viewModel = FiveCardDrawViewModel()

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { handleSurfaceTap() }
            VStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text("BUILDING CHALLENGE")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.green.opacity(0.85))
                    Text("FIVE-CARD DRAW")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                    Text("PAIR OR BETTER")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.green.opacity(0.6))
                }
                handRow
                Text(viewModel.statusText)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 60)
                    .accessibilityIdentifier("fiveCardDrawStatus")
                if viewModel.hasDrawn {
                    // Eddie, Sept 13: "Stay there until player taps." No
                    // auto-advance -- same pacing rule as Floor 10.
                    Button {
                        viewModel.continueAfterResult()
                    } label: {
                        Text(viewModel.qualifies ? "TAP TO CONTINUE" : "TAP TO RETRY")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                            .frame(minWidth: 220, minHeight: 50)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.5), lineWidth: 2))
                    }
                    .accessibilityIdentifier("fiveCardDrawContinueButton")
                } else {
                    Button {
                        viewModel.draw()
                    } label: {
                        Text("DRAW")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                            .frame(minWidth: 140, minHeight: 50)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.5), lineWidth: 2))
                    }
                    .accessibilityIdentifier("fiveCardDrawButton")
                    Button("Step Away") { controller.cancelFiveCardDrawTerminal() }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 120, minHeight: 42)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .accessibilityIdentifier("stepAwayFromFiveCardDrawButton")
                }
            }
            .padding(24)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.5), lineWidth: 2))
            .padding(28)
            .contentShape(Rectangle())
            .onTapGesture { handleSurfaceTap() }
        }
        .accessibilityAction(.escape) { controller.cancelFiveCardDrawTerminal() }
        .onAppear { viewModel.onWin = { controller.completeFiveCardDrawTerminal(at: coord) } }
    }

    /// Mirrors HigherLowerOverlay's handleSurfaceTap: once a result is
    /// showing, a tap anywhere on the terminal surface continues,
    /// same as the dedicated button. While still holding/choosing, a
    /// background tap does nothing -- Step Away stays an explicit,
    /// deliberate button rather than an easy-to-brush accidental exit.
    private func handleSurfaceTap() {
        guard viewModel.hasDrawn else { return }
        viewModel.continueAfterResult()
    }

    private var handRow: some View {
        HStack(spacing: 10) {
            ForEach(Array(viewModel.game.hand.indices), id: \.self) { index in
                cardSlot(at: index)
            }
        }
    }

    /// Eddie: "Held card should be visually obvious... green outline,
    /// slight vertical lift, HOLD label... Avoid elaborate animation."
    /// Disabled entirely once hasDrawn -- holds only ever matter
    /// before the one draw.
    @ViewBuilder
    private func cardSlot(at index: Int) -> some View {
        let isHeld = viewModel.game.held[index]
        Button {
            viewModel.toggleHold(at: index)
        } label: {
            VStack(spacing: 4) {
                PlayingCardView(card: viewModel.game.hand[index])
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isHeld ? Color.green : Color.clear, lineWidth: 3)
                    )
                    .offset(y: isHeld ? -8 : 0)
                Text(isHeld ? "HOLD" : " ")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.hasDrawn)
        .accessibilityIdentifier("fiveCardDrawCard_\(index)")
    }
}
