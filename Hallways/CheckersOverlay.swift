import SwiftUI
import Combine

/// Drives one Floor 15 Checkers playthrough -- selection, moves, the
/// computer's move timing, and mandatory-capture/multi-jump UX
/// (Eddie, Sept 14). Same shape as ConnectFourViewModel: the game
/// begins the instant the terminal activates, no separate START tap.
/// Calls back into TapNavigationController exactly once via onWin,
/// and never auto-dismisses a result -- both the win and loss screens
/// stay up exactly until the player taps.
///
/// Product intent (Eddie): "The player should walk up to the terminal,
/// recognize CHECKERS immediately, and begin playing with little or
/// no instruction... The interface itself should remind them" of the
/// rules -- selectable pieces, legal destinations, and the
/// mandatory-capture piece(s) are all just READ off
/// CheckersGame.legalMovesForCurrentTurn (see selectableCoordinates/
/// destinationCoordinates below), so there is no separate rules-
/// enforcement duplicated in the view. "THE GAME IS REAL. FAILURE IS
/// CHEAP": the computer is never secretly forced to lose, but a loss
/// resets straight into a fresh board with no penalty.
///
/// Eddie's Floor 14 lesson, applied directly here: a tap must never be
/// able to race a still-settling move. `isSettling` mirrors
/// ConnectFourViewModel's droppingColumn guard -- continueAfterResult()
/// (and every square tap) is a no-op while it's true, so the board is
/// always fully "frozen" before any result screen can be acted on.
/// A completed computer move, kept around just long enough for
/// CheckersOverlay to draw a brief highlight on both squares --
/// Equatable purely so SwiftUI's own view-diffing behaves predictably
/// (not compared anywhere in this file's own logic).
struct CheckersMoveHighlight: Equatable {
    let from: CheckersCoordinate
    let to: CheckersCoordinate
}

@MainActor
final class CheckersViewModel: ObservableObject {
    @Published private(set) var game = CheckersGame()
    @Published private(set) var selectedCoordinate: CheckersCoordinate?
    /// True for the brief window right after any move (chiefly so a
    /// captured piece's fade-out has time to play) during which no new
    /// tap -- including TAP TO CONTINUE/RETRY -- can be acted on.
    @Published private(set) var isSettling = false
    /// The piece captured by the move just made, if any -- the overlay
    /// fades this square out rather than having it vanish instantly.
    @Published private(set) var fadingCapture: CheckersCoordinate?
    /// The computer's most recently completed move, highlighted briefly
    /// so the player can actually see what changed -- Eddie: "the
    /// computer move currently happens too quickly for the player to
    /// easily see what changed... highlight for about 1.5-2.0 seconds."
    /// Kept on its own timer (separate from isSettling/captureFadeDuration)
    /// specifically so it stays visible past the capture-fade window --
    /// the destination square must still read as "this is what moved"
    /// even after a captured piece has faded away and been removed.
    @Published private(set) var computerMoveHighlight: CheckersMoveHighlight?

    /// Fired exactly once, the instant the PLAYER taps through a WIN
    /// result screen -- CheckersOverlay wires this to
    /// TapNavigationController.completeCheckersTerminal(at:).
    var onWin: (() -> Void)?

    private var rng = SystemRandomNumberGenerator()
    private var moveToken = UUID()
    private var highlightToken = UUID()

    /// Eddie: "Keep computer thinking delay short" -- same figure
    /// Connect Four used for its own short natural beat.
    static let computerThinkDelay = 0.45
    /// How long a captured piece's fade-out plays before the board is
    /// considered settled again.
    static let captureFadeDuration = 0.22
    /// Eddie, round 3: 1.75s still wasn't obvious enough on the actual
    /// phone -- "keep that acknowledgement visible for a FULL 3.0
    /// SECONDS... the player should be able to look away momentarily,
    /// look back, and immediately understand."
    static let computerMoveHighlightDuration = 3.0

    var statusText: String {
        switch game.phase {
        case .playerTurn:
            return game.mustContinueFrom != nil ? "CONTINUE YOUR JUMP" : "YOUR TURN"
        case .computerTurn:
            return "BUILDING'S TURN"
        case .playerWon:
            return "YOU WIN\n\nASSESSMENT PASSED\n\nELEVATOR ACCESS GRANTED."
        case .computerWon:
            return "THE BUILDING WINS"
        }
    }

    /// Eddie: "Make selectable/legal pieces visually obvious." Reads
    /// straight off CheckersGame's own legal-move list, so this is
    /// already narrowed to just the mandatory-capturing piece(s) when a
    /// capture is available, or to the single piece mid multi-jump --
    /// no separate mandatory-capture logic lives in the view.
    var selectableCoordinates: Set<CheckersCoordinate> {
        guard game.phase == .playerTurn, !isSettling else { return [] }
        return Set(game.legalMovesForCurrentTurn.map { $0.from })
    }

    /// Eddie: "After selecting a piece, make its legal destination
    /// square(s) obvious."
    var destinationCoordinates: Set<CheckersCoordinate> {
        guard let from = selectedCoordinate else { return [] }
        return Set(game.legalMovesForCurrentTurn.filter { $0.from == from }.map { $0.to })
    }

    init() {
        autoSelectIfForced()
    }

    /// Eddie: "Tap piece, tap destination... Tapping an illegal piece/
    /// square should simply do nothing... no punishment and no modal
    /// explanation." A tap either completes a move for the already-
    /// selected piece, switches the selection to a different
    /// selectable piece, or -- for anything else -- is a silent no-op.
    func squareTapped(_ coord: CheckersCoordinate) {
        guard game.phase == .playerTurn, !isSettling else { return }
        if let from = selectedCoordinate,
           let move = game.legalMovesForCurrentTurn.first(where: { $0.from == from && $0.to == coord }) {
            perform(move, side: .player)
            return
        }
        guard selectableCoordinates.contains(coord) else { return }
        selectedCoordinate = coord
    }

    /// Applies one move for `side`, fading out any captured piece, and
    /// -- once settled -- either continues into the next leg of a
    /// multi-jump, hands off to the computer, or (for the computer's
    /// own move) hands back to the player.
    private func perform(_ move: CheckersMove, side: CheckersSide) {
        moveToken = UUID()
        let token = moveToken
        isSettling = true
        selectedCoordinate = nil
        fadingCapture = move.captured
        _ = side == .player ? game.playerMove(move) : game.computerMove(move)
        if side == .computer {
            // Eddie: highlight FROM and TO so the move reads clearly --
            // a fresh token per leg so a multi-jump's final landing
            // square is what actually stays lit for the full duration,
            // rather than an earlier leg's timer clearing it early.
            highlightToken = UUID()
            let hToken = highlightToken
            computerMoveHighlight = CheckersMoveHighlight(from: move.from, to: move.to)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.computerMoveHighlightDuration) { [weak self] in
                guard let self, self.highlightToken == hToken else { return }
                self.computerMoveHighlight = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureFadeDuration) { [weak self] in
            guard let self, self.moveToken == token else { return }
            self.isSettling = false
            self.fadingCapture = nil
            self.autoSelectIfForced()
            self.afterMoveSettled()
        }
    }

    /// Mid multi-jump (or when a mandatory capture leaves exactly one
    /// legal piece), only one piece can move -- pre-select it so the
    /// player can go straight to tapping the next landing square.
    private func autoSelectIfForced() {
        guard game.phase == .playerTurn else {
            selectedCoordinate = nil
            return
        }
        let froms = Set(game.legalMovesForCurrentTurn.map { $0.from })
        selectedCoordinate = froms.count == 1 ? froms.first : nil
    }

    private func afterMoveSettled() {
        guard game.phase == .computerTurn else { return }
        scheduleComputerMove()
    }

    /// Eddie: "Keep computer thinking delay short." A single short
    /// delay per leg -- including each leg of the computer's own
    /// multi-jump -- then CheckersAI picks a real (non-rigged,
    /// non-minimax) move from the currently-legal set.
    private func scheduleComputerMove() {
        moveToken = UUID()
        let token = moveToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.computerThinkDelay) { [weak self] in
            guard let self, self.moveToken == token, self.game.phase == .computerTurn else { return }
            guard let move = CheckersAI.chooseMove(game: self.game, using: &self.rng) else { return }
            self.perform(move, side: .computer)
        }
    }

    /// TAP TO CONTINUE (win) fires onWin?(). TAP TO RETRY (loss) --
    /// Eddie: "retry starts fresh... no lives, money loss, punishment,
    /// or dead end" -- resets straight back to a clean board and the
    /// player's turn.
    func continueAfterResult() {
        guard !isSettling else { return }
        switch game.phase {
        case .playerWon:
            onWin?()
        case .computerWon:
            moveToken = UUID()
            isSettling = false
            fadingCapture = nil
            selectedCoordinate = nil
            highlightToken = UUID()
            computerMoveHighlight = nil
            game.reset()
        case .playerTurn, .computerTurn:
            break
        }
    }
}

/// Presented over the 3D scene the instant the player approaches and
/// faces Floor 15's terminal (see
/// TapNavigationController.activateCheckersTerminal) -- same "dark
/// scrim + centered panel, green-on-black terminal" visual language as
/// every other floor's terminal.
struct CheckersOverlayHost: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        if let coord = controller.activeCheckersTerminal {
            CheckersOverlay(controller: controller, coord: coord)
        }
    }
}

private struct CheckersOverlay: View {
    @ObservedObject var controller: TapNavigationController
    let coord: GridCoordinate
    @StateObject private var viewModel = CheckersViewModel()
    @State private var highlightPulseOpacity: Double = 0.75

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { handleSurfaceTap() }
            VStack(spacing: 10) {
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
                    .accessibilityIdentifier("checkersStatus")
                if isResultShowing {
                    actionArea
                } else {
                    // Eddie's own established rule (carried over from
                    // Connect Four/Hangman/Simon): "Step Away" is only
                    // useful while the game is still in progress --
                    // once a result is up it stays up until tapped.
                    Button("Step Away") { controller.cancelCheckersTerminal() }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 120, minHeight: 42)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .accessibilityIdentifier("stepAwayFromCheckersButton")
                }
            }
            .padding(16)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.5), lineWidth: 2))
            .padding(20)
            .contentShape(Rectangle())
            .onTapGesture { handleSurfaceTap() }
        }
        .accessibilityAction(.escape) { controller.cancelCheckersTerminal() }
        .onAppear { viewModel.onWin = { controller.completeCheckersTerminal(at: coord) } }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                highlightPulseOpacity = 1.0
            }
        }
    }

    private var isResultShowing: Bool {
        viewModel.game.phase == .playerWon || viewModel.game.phase == .computerWon
    }

    /// Eddie: "Zero precision challenge. Generous hit targets... Do
    /// not make the board so dark that the player has to strain to
    /// understand it." Row 0 (the player's home edge) renders at the
    /// bottom, matching how a player would sit at a physical board.
    private var boardView: some View {
        let squareSize: CGFloat = 32
        return VStack(spacing: 0) {
            ForEach((0..<CheckersBoard.size).reversed(), id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<CheckersBoard.size, id: \.self) { col in
                        squareView(coord: CheckersCoordinate(col: col, row: row), size: squareSize)
                    }
                }
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.35), lineWidth: 1.5))
    }

    @ViewBuilder
    private func squareView(coord: CheckersCoordinate, size: CGFloat) -> some View {
        let playable = CheckersBoard.isPlayable(coord)
        let piece = viewModel.game.board.piece(at: coord)
        let isSelected = viewModel.selectedCoordinate == coord
        let isDestination = viewModel.destinationCoordinates.contains(coord)
        let isSelectable = viewModel.selectableCoordinates.contains(coord)
        let isFadingCapture = viewModel.fadingCapture == coord
        let isComputerMoveHighlight = viewModel.computerMoveHighlight?.from == coord
            || viewModel.computerMoveHighlight?.to == coord

        Button {
            viewModel.squareTapped(coord)
        } label: {
            ZStack {
                Rectangle()
                    .fill(squareFill(playable: playable))
                if playable {
                    Rectangle()
                        .fill(squareOverlayTint(isDestination: isDestination, isSelectable: isSelectable))
                    Rectangle()
                        .stroke(squareBorder(isSelected: isSelected, isDestination: isDestination, isSelectable: isSelectable),
                                lineWidth: isSelected ? 2.5 : (isDestination || isSelectable ? 1.5 : 1))
                }
                if let piece {
                    pieceView(piece: piece, size: size * 0.8, highlighted: isSelected)
                        .opacity(isFadingCapture ? 0 : 1)
                }
                if isDestination {
                    Circle()
                        .fill(Color.green.opacity(0.55))
                        .frame(width: size * 0.26, height: size * 0.26)
                }
                // Eddie, round 3: "the existing highlight is not doing
                // the job perceptually... make it substantially more
                // conspicuous... a strong white/light-gray border or
                // glow." Drawn on the square itself (not tied to
                // whether a piece currently occupies it), so the
                // destination stays obvious even once a captured piece
                // has finished fading out. A thick, near-full-opacity
                // border plus an actual glow (via .shadow) rather than
                // the earlier thin, more-transparent ring.
                if isComputerMoveHighlight {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.white.opacity(highlightPulseOpacity), lineWidth: 4.5)
                        .padding(1.5)
                        .shadow(color: Color.white.opacity(0.9 * highlightPulseOpacity), radius: 3)
                        .shadow(color: Color.white.opacity(0.7 * highlightPulseOpacity), radius: 8)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // "Generous hit targets" -- every playable square is its own
        // full-size tap target, not just the piece glyph within it.
        .disabled(!playable || (!isSelectable && !isDestination))
        .accessibilityIdentifier("checkersSquare_\(coord.col)_\(coord.row)")
    }

    /// Eddie, round 2: the first fix (a low-opacity gray-green tint
    /// over black) still read as "a black rectangle with faint grid
    /// lines" on an actual OLED iPhone -- not a checkerboard. This is
    /// a real high-contrast checkerboard instead: non-playable squares
    /// are essentially true black, playable squares are a solid,
    /// clearly-visible muted gray-green, full opacity, no blending
    /// with the black background. The alternating FILLS are what must
    /// read as a checkerboard at a glance -- grid lines (squareBorder,
    /// below) and the green legal-move wash (squareOverlayTint, below)
    /// both stay strictly secondary to this.
    private static let blackSquareFill = Color(red: 5.0 / 255.0, green: 8.0 / 255.0, blue: 6.0 / 255.0)
    private static let graySquareFill = Color(red: 70.0 / 255.0, green: 82.0 / 255.0, blue: 74.0 / 255.0)

    private func squareFill(playable: Bool) -> Color {
        playable ? Self.graySquareFill : Self.blackSquareFill
    }

    /// A translucent green wash layered ON TOP of the checkerboard
    /// fill above -- this is purely the legal-move/selectable-piece
    /// cue (meaningful gameplay feedback, per Eddie's "preserve
    /// selection/legal-move feedback"), never something that competes
    /// with or replaces the checkerboard pattern itself.
    private func squareOverlayTint(isDestination: Bool, isSelectable: Bool) -> Color {
        if isDestination { return Color.green.opacity(0.30) }
        if isSelectable { return Color.green.opacity(0.16) }
        return Color.clear
    }

    private func squareBorder(isSelected: Bool, isDestination: Bool, isSelectable: Bool) -> Color {
        if isSelected { return Color.white.opacity(0.85) }
        if isDestination { return Color.green.opacity(0.75) }
        if isSelectable { return Color.green.opacity(0.55) }
        return Color(red: 0.62, green: 0.68, blue: 0.62).opacity(0.35)
    }

    /// Eddie: "Clearly distinguish player pieces, computer pieces,
    /// selected piece, legal destinations, and kings... Do not rely on
    /// tiny details to distinguish kings. A king should be obvious." A
    /// crown glyph on top of the piece -- the traditional checkers
    /// king marker -- reads unmistakably at a glance, on either color.
    private func pieceView(piece: CheckersPiece, size: CGFloat, highlighted: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(ringColor(for: piece), lineWidth: piece.side == .computer ? 2.5 : 1)
                .background(Circle().fill(fillColor(for: piece)))
            if piece.isKing {
                Image(systemName: "crown.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(piece.side == .player ? Color.black.opacity(0.8) : Color.white.opacity(0.95))
            }
            Circle()
                .stroke(Color.white.opacity(0.85), lineWidth: 2.5)
                .opacity(highlighted ? 1 : 0)
                .padding(-2)
        }
        .frame(width: size, height: size)
    }

    private func fillColor(for piece: CheckersPiece) -> Color {
        piece.side == .player ? Color.green : Color.green.opacity(0.18)
    }

    private func ringColor(for piece: CheckersPiece) -> Color {
        piece.side == .player ? Color.green : Color.green.opacity(0.85)
    }

    /// Eddie: "clearly acknowledge victory... show something
    /// consistent with the successful Floor 14 pattern... TAP TO
    /// CONTINUE / TAP TO RETRY." Same player-paced result contract as
    /// every other terminal -- do NOT auto-dismiss, and (per the Floor
    /// 14 fix) never actionable until the board has settled.
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
        .accessibilityIdentifier("checkersContinueButton")
    }

    /// Mirrors ConnectFourOverlay/HangmanOverlay's handleSurfaceTap:
    /// once a result is showing, a tap anywhere on the terminal surface
    /// continues, same as the dedicated button.
    private func handleSurfaceTap() {
        guard isResultShowing else { return }
        viewModel.continueAfterResult()
    }
}
