import SwiftUI
import Combine

/// Drives one Floor 14 Connect Four playthrough -- turns, the
/// computer's move timing, and the piece-drop animation (Eddie, Sept
/// 14). Same shape as HangmanViewModel: the game begins the instant
/// the terminal activates, no separate START tap. Calls back into
/// TapNavigationController exactly once via onWin, and -- matching
/// every other terminal's pacing fix -- never auto-dismisses a
/// result. Both the win and loss/draw screens stay up exactly until
/// the player taps.
///
/// Product intent (Eddie): "We are not trying to prove that the
/// player is an expert Connect Four strategist... Connect Four should
/// simply feel like Connect Four." This view model is deliberately
/// thin -- one Combine-free state machine (ConnectFourGame) plus the
/// AI's move choice (ConnectFourAI), nothing else. "THE GAME IS REAL.
/// FAILURE IS CHEAP": the computer is never secretly forced to lose,
/// but a loss or draw resets straight into a fresh board with no
/// penalty and no lingering screen.
@MainActor
final class ConnectFourViewModel: ObservableObject {
    @Published private(set) var game = ConnectFourGame()
    /// The column (0..<7) whose piece is currently animating from the
    /// top of the board down to its resting row -- nil once the drop
    /// has settled. Only ever one column animates at a time (both
    /// player and computer drops fully settle before the next move is
    /// accepted), so a single optional is enough.
    @Published private(set) var droppingColumn: Int?
    /// True for the one frame the dropping piece is still "at the
    /// top" -- see animateDrop(column:piece:). The overlay uses this
    /// to render the falling piece above the board before the
    /// animated settle begins.
    @Published private(set) var dropAtTop = false
    /// Which piece is currently dropping, so the overlay can render
    /// the correct fill/outline treatment while it's still in flight
    /// (before ConnectFourGame's own board array has it).
    private(set) var droppingPiece: ConnectFourPiece?

    /// Fired exactly once, the instant the PLAYER taps through a WIN
    /// result screen -- ConnectFourOverlay wires this to
    /// TapNavigationController.completeConnectFourTerminal(at:).
    var onWin: (() -> Void)?

    private var rng = SystemRandomNumberGenerator()
    /// Invalidates any in-flight scheduled closure (the drop-settle
    /// animation tick, the computer's move beat) after a cancel/retry/
    /// deinit -- same guard pattern used by every other overlay's
    /// asyncAfter/async scheduling (see SimonOverlay/HigherLowerOverlay).
    private var moveToken = UUID()

    /// Eddie: "quick, satisfying... not slow enough to interrupt
    /// play." The piece-drop settle animation.
    static let dropDuration = 0.22
    /// Eddie: "allow a short natural beat" before the computer moves --
    /// "do not introduce long artificial thinking delays."
    static let computerThinkDelay = 0.45

    var statusText: String {
        switch game.phase {
        case .playerTurn:
            return "YOUR TURN"
        case .computerTurn:
            return "BUILDING'S TURN"
        case .playerWon:
            return "YOU WIN\n\nASSESSMENT PASSED\n\nELEVATOR ACCESS GRANTED."
        case .computerWon:
            return "THE BUILDING WINS"
        case .draw:
            return "DRAW"
        }
    }

    /// Eddie: "Tap a column or a generous hit area... no dragging, no
    /// aiming." A no-op outside .playerTurn, mid-drop, or onto a full
    /// column -- a stray double-tap can never double-move or land a
    /// piece on top of an animation still in flight.
    func columnTapped(_ column: Int) {
        guard game.phase == .playerTurn, droppingColumn == nil else { return }
        guard let row = game.playerDrop(column: column) else { return }
        animateDrop(column: column, row: row, piece: .player)
    }

    /// Two-phase animation trick (see class doc for why): set
    /// droppingColumn/dropAtTop synchronously so the piece renders "at
    /// the top" this frame, then on the very next runloop tick flip
    /// dropAtTop to false inside withAnimation so SwiftUI actually
    /// observes and animates the transition rather than coalescing
    /// both mutations into a single, silent jump.
    private func animateDrop(column: Int, row: Int, piece: ConnectFourPiece) {
        moveToken = UUID()
        let token = moveToken
        droppingPiece = piece
        droppingColumn = column
        dropAtTop = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.moveToken == token else { return }
            withAnimation(.easeIn(duration: Self.dropDuration)) {
                self.dropAtTop = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropDuration) { [weak self] in
                guard let self, self.moveToken == token else { return }
                self.droppingColumn = nil
                self.droppingPiece = nil
                self.afterMoveSettled()
            }
        }
    }

    /// Called once the drop's settle animation has finished (for
    /// either the player's or the computer's move). Advances into the
    /// computer's turn after the player's move, or hands control back
    /// after the computer's.
    private func afterMoveSettled() {
        guard game.phase == .computerTurn else { return }
        scheduleComputerMove()
    }

    /// Eddie: "After the player drops a piece... allow a short
    /// natural beat, computer makes its move, return control
    /// promptly." A single short delay, then ConnectFourAI picks a
    /// real (non-rigged, non-minimax) column and the same drop
    /// animation plays for the computer's piece.
    private func scheduleComputerMove() {
        moveToken = UUID()
        let token = moveToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.computerThinkDelay) { [weak self] in
            guard let self, self.moveToken == token, self.game.phase == .computerTurn else { return }
            guard let column = ConnectFourAI.chooseMove(board: self.game.board, using: &self.rng),
                  let row = self.game.computerDrop(column: column) else { return }
            self.animateDrop(column: column, row: row, piece: .computer)
        }
    }

    /// TAP TO CONTINUE (win) fires onWin?(). TAP TO RETRY (loss/draw)
    /// -- Eddie: "No lives. No penalties... immediate RETRY with a
    /// fresh board" -- resets straight back to a clean board and the
    /// player's turn; nothing lingers and no state carries over.
    func continueAfterResult() {
        // Do not allow TAP TO CONTINUE/RETRY (or a surface tap) to
        // advance anything until the winning/losing drop has fully
        // settled -- the board must visually finish before the result
        // can be acted on.
        guard droppingColumn == nil else { return }
        switch game.phase {
        case .playerWon:
            onWin?()
        case .computerWon, .draw:
            moveToken = UUID()
            droppingColumn = nil
            droppingPiece = nil
            dropAtTop = false
            game.reset()
        case .playerTurn, .computerTurn:
            break
        }
    }
}

/// Presented over the 3D scene the instant the player approaches and
/// faces Floor 14's terminal (see
/// TapNavigationController.activateConnectFourTerminal) -- same "dark
/// scrim + centered panel, green-on-black terminal" visual language as
/// every other floor's terminal.
struct ConnectFourOverlayHost: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        if let coord = controller.activeConnectFourTerminal {
            ConnectFourOverlay(controller: controller, coord: coord)
        }
    }
}

private struct ConnectFourOverlay: View {
    @ObservedObject var controller: TapNavigationController
    let coord: GridCoordinate
    @StateObject private var viewModel = ConnectFourViewModel()

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
                    Text("STRATEGY ASSESSMENT")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                }
                boardView
                Text(viewModel.statusText)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 34)
                    .accessibilityIdentifier("connectFourStatus")
                if isResultShowing {
                    actionArea
                } else {
                    // Eddie's own established rule (carried over from
                    // Hangman/Simon/Rock Paper Scissors): "Step Away"
                    // is only useful while the player is still
                    // choosing -- once a result is up it stays up
                    // until tapped.
                    Button("Step Away") { controller.cancelConnectFourTerminal() }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 120, minHeight: 42)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .accessibilityIdentifier("stepAwayFromConnectFourButton")
                }
            }
            .padding(18)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.5), lineWidth: 2))
            .padding(24)
            .contentShape(Rectangle())
            .onTapGesture { handleSurfaceTap() }
        }
        .accessibilityAction(.escape) { controller.cancelConnectFourTerminal() }
        .onAppear { viewModel.onWin = { controller.completeConnectFourTerminal(at: coord) } }
    }

    private var isResultShowing: Bool {
        viewModel.game.phase == .playerWon || viewModel.game.phase == .computerWon || viewModel.game.phase == .draw
    }

    /// Eddie: "Clean 7x6 board. Large circular piece positions."
    /// Each column is one full-height tap target -- "generous hit
    /// area... essentially ZERO dexterity requirement" -- stacked
    /// with its 6 slots so tapping anywhere in the column drops into
    /// it, not just a header button above the board.
    private var boardView: some View {
        let slotSize: CGFloat = 34
        let spacing: CGFloat = 6
        return HStack(spacing: spacing) {
            ForEach(0..<ConnectFourBoard.columnCount, id: \.self) { column in
                Button {
                    viewModel.columnTapped(column)
                } label: {
                    VStack(spacing: spacing) {
                        ForEach((0..<ConnectFourBoard.rowCount).reversed(), id: \.self) { row in
                            slotView(column: column, row: row, size: slotSize)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!columnIsTappable(column))
                .accessibilityIdentifier("connectFourColumn_\(column)")
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.35), lineWidth: 1.5))
    }

    private func columnIsTappable(_ column: Int) -> Bool {
        guard viewModel.game.phase == .playerTurn, viewModel.droppingColumn == nil else { return false }
        return !viewModel.game.board.isColumnFull(column)
    }

    /// One board slot. While a piece is actively dropping into this
    /// column, the top slot renders the in-flight piece at dropAtTop
    /// (above the board) or settled into its real destination row --
    /// everything else just reads straight from the board's settled
    /// state.
    @ViewBuilder
    private func slotView(column: Int, row: Int, size: CGFloat) -> some View {
        let settled = viewModel.game.board.piece(atColumn: column, row: row)
        let isWinning = viewModel.game.winningLine.contains(ConnectFourCoordinate(column: column, row: row))
        if viewModel.droppingColumn == column, isDroppingDestination(column: column, row: row) {
            pieceView(piece: viewModel.droppingPiece, size: size, highlighted: false)
                .offset(y: viewModel.dropAtTop ? -CGFloat(row + 1) * (size + 6) : 0)
        } else {
            pieceView(piece: settled, size: size, highlighted: isWinning)
        }
    }

    /// The dropping piece's eventual resting row is always the
    /// topmost currently-occupied row in that column once the game
    /// state has already recorded the drop (playerDrop/computerDrop
    /// return before the animation starts), so the highest occupied
    /// row IS the destination for the one column currently animating.
    private func isDroppingDestination(column: Int, row: Int) -> Bool {
        let occupied = viewModel.game.board.columns.indices.contains(column) ? viewModel.game.board.columns[column].count : 0
        return row == occupied - 1
    }

    /// Eddie: "Player pieces = bright/filled green discs. Computer
    /// pieces = green outlines or visibly dimmer/alternate green
    /// treatment." Empty slots are a faint hollow ring, same
    /// green-on-black language as everything else on this terminal.
    /// Eddie: "make the winning four visually apparent if
    /// straightforward" -- a winning piece gets a brighter white-green
    /// glow ring around it, still entirely green-on-black.
    private func pieceView(piece: ConnectFourPiece?, size: CGFloat, highlighted: Bool) -> some View {
        Circle()
            .strokeBorder(ringColor(for: piece), lineWidth: piece == .computer ? 2.5 : (piece == nil ? 1.5 : 1))
            .background(Circle().fill(fillColor(for: piece)))
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.85), lineWidth: 2.5)
                    .opacity(highlighted ? 1 : 0)
                    .padding(-2)
            )
            .frame(width: size, height: size)
    }

    private func fillColor(for piece: ConnectFourPiece?) -> Color {
        switch piece {
        case .player: return Color.green
        case .computer: return Color.green.opacity(0.18)
        case nil: return Color.white.opacity(0.03)
        }
    }

    private func ringColor(for piece: ConnectFourPiece?) -> Color {
        switch piece {
        case .player: return Color.green
        case .computer: return Color.green.opacity(0.85)
        // Eddie: empty positions were "extremely difficult to see" --
        // a subdued gray-green (distinct from the computer's dim
        // green so an empty slot never reads as an opponent piece),
        // substantially brighter than before, still clearly
        // subordinate to both piece colors.
        case nil: return Color(red: 0.62, green: 0.68, blue: 0.62).opacity(0.55)
        }
    }

    /// Eddie: "make the winning four visually apparent if
    /// straightforward to implement, offer TAP TO CONTINUE / TAP TO
    /// RETRY." Same player-paced result contract as every other
    /// terminal -- do NOT auto-dismiss.
    @ViewBuilder
    private var actionArea: some View {
        Button {
            viewModel.continueAfterResult()
        } label: {
            Text(viewModel.game.phase == .playerWon ? "TAP TO CONTINUE" : "TAP TO RETRY")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.green)
                .frame(minWidth: 220, minHeight: 50)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.5), lineWidth: 2))
        }
        .accessibilityIdentifier("connectFourContinueButton")
    }

    /// Mirrors HangmanOverlay/SimonOverlay's handleSurfaceTap: once a
    /// result is showing, a tap anywhere on the terminal surface
    /// continues, same as the dedicated button.
    private func handleSurfaceTap() {
        guard isResultShowing else { return }
        viewModel.continueAfterResult()
    }
}
