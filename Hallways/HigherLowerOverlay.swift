import SwiftUI
import Combine

/// Drives one Floor 10 session -- the deck, the current/revealed
/// cards, and the streak (Eddie, Sept 13). Same shape as
/// RockPaperScissorsViewModel: dumb about anything outside the game
/// itself, calls back into TapNavigationController exactly once via
/// onWin.
///
/// The honesty guarantee: chooseGuess(_:) draws the next card from
/// the deck FIRST, then evaluates the already-drawn rank against the
/// player's guess -- there is no path where the player's choice
/// influences which card comes off the deck.
///
/// Eddie, Sept 13 (pacing fix): every result -- correct, wrong, push,
/// or the streak-of-3 win -- is now PLAYER-PACED. There is no auto-
/// advance timer anymore; the result stays on screen exactly until
/// the player taps "TAP TO CONTINUE" (continueFromResult()), and only
/// then does the win case fire onWin?().
@MainActor
final class HigherLowerViewModel: ObservableObject {
    enum Phase {
        case waitingForGuess
        case revealed(HigherLowerResult)
        case won
    }

    @Published private(set) var currentCard: PlayingCard
    @Published private(set) var revealedCard: PlayingCard?
    @Published private(set) var phase: Phase = .waitingForGuess
    @Published private(set) var streak = HigherLowerStreak()
    @Published private(set) var statusText = "HIGHER OR LOWER?"

    /// Fired exactly once, the instant the PLAYER taps through the
    /// streak-of-3 win screen -- HigherLowerOverlay wires this to
    /// TapNavigationController.completeHigherLowerTerminal(at:).
    var onWin: (() -> Void)?

    private var deck: PlayingCardDeck
    private var rng = SystemRandomNumberGenerator()

    init() {
        deck = PlayingCardDeck(shuffledUsing: &rng)
        // A freshly shuffled standard deck always has 52 cards, so
        // this can never actually be nil.
        currentCard = deck.draw()!
    }

    /// HIGHER/LOWER/Step Away are only shown in this phase -- a
    /// result (revealed or won) hides them and shows "TAP TO
    /// CONTINUE" instead. See HigherLowerOverlay.canChoose usage.
    var canChoose: Bool {
        if case .waitingForGuess = phase { return true }
        return false
    }

    func chooseGuess(_ guess: HigherLowerGuess) {
        guard case .waitingForGuess = phase else { return }
        if deck.isEmpty {
            // All 52 cards seen this session -- reshuffle a fresh
            // honest deck rather than dead-ending the player mid-streak.
            deck = PlayingCardDeck(shuffledUsing: &rng)
        }
        guard let next = deck.draw() else { return } // unreachable: just ensured non-empty

        let result = HigherLowerGame.evaluate(current: currentCard.rank, next: next.rank, guess: guess)
        revealedCard = next
        streak.apply(result)

        switch result {
        case .push:
            statusText = "PUSH\nSTREAK UNCHANGED"
        case .correct:
            statusText = "CORRECT\nSTREAK: \(streak.count) / \(HigherLowerStreak.target)"
        case .wrong:
            statusText = "WRONG\nSTREAK RESET"
        }

        if streak.isComplete {
            // Eddie, Sept 13: "DO NOT auto-dismiss after a timer." The
            // win screen sits here, untouched, until the player taps
            // continueFromResult() -- that's what actually fires
            // onWin?(), not reaching streak 3 by itself.
            statusText = "CORRECT\n\n3 IN A ROW\n\nELEVATOR ACCESS GRANTED."
            phase = .won
        } else {
            phase = .revealed(result)
        }
    }

    /// Called by the "TAP TO CONTINUE" tap -- the only thing that
    /// advances a result screen now. A revealed (non-winning) result
    /// moves the revealed card into place and reopens the HIGHER/
    /// LOWER choice; a won result fires onWin?(), handing dismissal
    /// over to TapNavigationController.completeHigherLowerTerminal(at:).
    /// No-op while still waitingForGuess (nothing to continue past).
    func continueFromResult() {
        switch phase {
        case .revealed:
            guard let next = revealedCard else { return }
            currentCard = next
            revealedCard = nil
            phase = .waitingForGuess
            statusText = "HIGHER OR LOWER?"
        case .won:
            onWin?()
        case .waitingForGuess:
            break
        }
    }
}

/// Presented over the 3D scene the instant the player approaches and
/// faces Floor 10's terminal (see
/// TapNavigationController.activateHigherLowerTerminal) -- identical
/// "dark scrim + centered panel" shape as the other three embedded
/// games. Eddie, Sept 13: while choosing, tapping the scrim steps
/// away (same as the other games); once a result is showing, tapping
/// ANYWHERE on the terminal/result surface -- scrim or panel, not
/// just the small "TAP TO CONTINUE" line -- continues instead.
struct HigherLowerOverlayHost: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        if let coord = controller.activeHigherLowerTerminal {
            HigherLowerOverlay(controller: controller, coord: coord)
        }
    }
}

private struct HigherLowerOverlay: View {
    @ObservedObject var controller: TapNavigationController
    let coord: GridCoordinate
    @StateObject private var game = HigherLowerViewModel()

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
                    Text("HIGHER / LOWER")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                }
                Text("STREAK: \(game.streak.count) / \(HigherLowerStreak.target)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.75))
                cards
                Text(game.statusText)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 50)
                    .accessibilityIdentifier("higherLowerStatus")
                if game.canChoose {
                    choices
                    Button("Step Away") { controller.cancelHigherLowerTerminal() }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 120, minHeight: 42)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .accessibilityIdentifier("stepAwayFromHigherLowerButton")
                } else {
                    // Eddie, Sept 13: "Leave this visible until player
                    // taps." A real, generously sized button -- not a
                    // tiny text target -- but the whole surface (see
                    // handleSurfaceTap/the .contentShape below) works too.
                    Button {
                        game.continueFromResult()
                    } label: {
                        Text("TAP TO CONTINUE")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                            .frame(minWidth: 220, minHeight: 50)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.5), lineWidth: 2))
                    }
                    .accessibilityIdentifier("higherLowerTapToContinue")
                }
            }
            .padding(24)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.5), lineWidth: 2))
            .padding(28)
            .contentShape(Rectangle())
            .onTapGesture { handleSurfaceTap() }
        }
        .accessibilityAction(.escape) { controller.cancelHigherLowerTerminal() }
        .onAppear { game.onWin = { controller.completeHigherLowerTerminal(at: coord) } }
    }

    /// Shared by the scrim and the panel: while still choosing, a tap
    /// anywhere outside an actual button steps away, same as always;
    /// once a result is on screen, a tap anywhere continues instead.
    /// Buttons (HIGHER/LOWER/Step Away/TAP TO CONTINUE) intercept
    /// their own taps before this ever fires, so there's no double-
    /// handling.
    private func handleSurfaceTap() {
        if game.canChoose {
            controller.cancelHigherLowerTerminal()
        } else {
            game.continueFromResult()
        }
    }

    private var cards: some View {
        HStack(spacing: 16) {
            PlayingCardView(card: game.currentCard)
                .accessibilityIdentifier("higherLowerCurrentCard")
            PlayingCardView(card: game.revealedCard)
                .accessibilityIdentifier("higherLowerRevealedCard")
        }
    }

    private var choices: some View {
        HStack(spacing: 12) {
            Button {
                game.chooseGuess(.higher)
            } label: {
                Text("HIGHER")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(width: 100, height: 50)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.5), lineWidth: 2))
            }
            .accessibilityIdentifier("higherLowerChoice_higher")
            Button {
                game.chooseGuess(.lower)
            } label: {
                Text("LOWER")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(width: 100, height: 50)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.5), lineWidth: 2))
            }
            .accessibilityIdentifier("higherLowerChoice_lower")
        }
    }
}
