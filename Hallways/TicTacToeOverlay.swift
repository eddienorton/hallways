import SwiftUI
import Combine

/// Drives one Floor 7 aptitude-test session: board state, whose turn
/// it is, and the "computer responds after a short natural delay"
/// pacing (Eddie, Sept 13). Deliberately dumb about anything outside
/// the board itself -- TapNavigationController owns the actual
/// mission-complete/elevator-unlock state (see completeTicTacToeTerminal),
/// this just calls back into it once via onWin.
@MainActor
final class TicTacToeViewModel: ObservableObject {
    @Published private(set) var board = TicTacToeBoard()
    @Published private(set) var status = "YOUR MOVE"
    @Published private(set) var isComputerTurn = false
    @Published private(set) var isGameOver = false
    /// Fired exactly once, the instant the PLAYER completes a winning
    /// line -- TicTacToeOverlay wires this to
    /// TapNavigationController.completeTicTacToeTerminal(at:).
    var onWin: (() -> Void)?
    private var rng = SystemRandomNumberGenerator()

    func canTap(_ index: Int) -> Bool {
        !isComputerTurn && !isGameOver && board.cells.indices.contains(index) && board.cells[index] == nil
    }

    /// Player is always X and always moves first -- simplest possible
    /// shape for a first pass (Eddie: KISS), and it means the player
    /// always gets the opening-move advantage every single attempt.
    func playerTapped(_ index: Int) {
        guard canTap(index), board.place(.x, at: index) else { return }
        SoundEffects.playTicTacToeX()
        if board.winner() == .x {
            isGameOver = true
            status = "APTITUDE: EXCEPTIONAL\nTEST PASSED"
            SoundEffects.playTicTacToeWin()
            onWin?()
            return
        }
        if board.isFull {
            handleDraw()
            return
        }
        isComputerTurn = true
        status = "COMPUTER THINKING\u{2026}"
        // "a SHORT natural delay rather than instantaneously" -- Eddie,
        // Sept 13. A small random range so it doesn't feel metronomic.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.55...0.95)) { [weak self] in
            self?.computerMove()
        }
    }

    private func computerMove() {
        guard !isGameOver else { return }
        guard let index = TicTacToeAI.chooseMove(board: board, computer: .o, player: .x, using: &rng) else {
            handleDraw() // no empty squares left and no move chosen -- board is full
            return
        }
        board.place(.o, at: index)
        SoundEffects.playTicTacToeO()
        if board.winner() == .o {
            // "if the player loses anyway, simply allow retry... No
            // punishment... reset the board... let them immediately
            // try again." No text ever says the computer let anything
            // slide -- see TicTacToeAI's own comments for why this
            // should be rare in the first place.
            isGameOver = true
            status = "NOT THIS TIME.\nRESETTING\u{2026}"
            SoundEffects.playTicTacToeLose()
            scheduleReset()
            return
        }
        if board.isFull {
            handleDraw()
            return
        }
        isComputerTurn = false
        status = "YOUR MOVE"
    }

    private func handleDraw() {
        isGameOver = true
        status = "DRAW. HR WILL BE IN TOUCH.\nRESETTING\u{2026}"
        SoundEffects.playTicTacToeLose()
        scheduleReset()
    }

    private func scheduleReset() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.isGameOver else { return }
            self.board = TicTacToeBoard()
            self.isComputerTurn = false
            self.isGameOver = false
            self.status = "YOUR MOVE"
        }
    }
}

/// Presented over the 3D scene the instant the player approaches and
/// faces Floor 7's aptitude-test terminal (see
/// TapNavigationController.activateTicTacToeTerminal) -- same "dark
/// scrim + centered panel, tap scrim or a button to step away" shape
/// HandheldMapOverlay already uses, not a generic full-screen white
/// view (Eddie: "the game should feel like an object/computer INSIDE
/// Hallways").
struct TicTacToeOverlayHost: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        if let coord = controller.activeTicTacToeTerminal {
            TicTacToeOverlay(controller: controller, coord: coord)
        }
    }
}

private struct TicTacToeOverlay: View {
    @ObservedObject var controller: TapNavigationController
    let coord: GridCoordinate
    @StateObject private var game = TicTacToeViewModel()

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { controller.cancelTicTacToeTerminal() }
            VStack(spacing: 18) {
                VStack(spacing: 2) {
                    Text("EMPLOYEE APTITUDE TEST")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.green.opacity(0.85))
                    Text("TIC-TAC-TOE")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                }
                board
                Text(game.status)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 40)
                    .accessibilityIdentifier("ticTacToeStatus")
                Button("Step Away") { controller.cancelTicTacToeTerminal() }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 120, minHeight: 42)
                    .background(Color.black.opacity(0.5), in: Capsule())
                    .accessibilityIdentifier("stepAwayFromTicTacToeButton")
            }
            .padding(24)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.5), lineWidth: 2))
            .padding(28)
        }
        .accessibilityAction(.escape) { controller.cancelTicTacToeTerminal() }
        .onAppear { game.onWin = { controller.completeTicTacToeTerminal(at: coord) } }
    }

    private var board: some View {
        VStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { col in
                        let index = row * 3 + col
                        Button {
                            game.playerTapped(index)
                        } label: {
                            Text(game.board.cells[index].map { $0 == .x ? "X" : "O" } ?? "")
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .foregroundStyle(game.board.cells[index] == .x ? Color.white : Color.green)
                                .frame(width: 64, height: 64)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.35), lineWidth: 1))
                        }
                        .disabled(!game.canTap(index))
                        .accessibilityIdentifier("ticTacToeCell_\(index)")
                    }
                }
            }
        }
    }
}
