import SwiftUI

/// A small, reusable, rendered-in-code playing card -- no image
/// assets (Eddie: "Do NOT require external playing-card image
/// assets... rank + suit is sufficient"). Deliberately plain and
/// monochrome-green rather than conventional red/black suit coloring,
/// to match the same terminal aesthetic as Tic-Tac-Toe's board and
/// the Shell Game's cups rather than looking like a bolted-on card
/// app. Kept separate from PlayingCard.swift (which stays pure model,
/// no SwiftUI) since Eddie expects playing cards to come up again
/// later.
struct PlayingCardView: View {
    /// nil renders a face-down placeholder (a plain "?") -- used for
    /// the not-yet-revealed next card in Higher/Lower.
    let card: PlayingCard?

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.black)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.6), lineWidth: 2))
            .overlay(content)
            .frame(width: 64, height: 92)
    }

    @ViewBuilder
    private var content: some View {
        if let card {
            VStack(spacing: 4) {
                Text(card.rank.displayName)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                Text(card.suit.symbol)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.green)
        } else {
            Text("?")
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.green.opacity(0.35))
        }
    }
}
