import SwiftUI
import Combine

/// Drives one Floor 8 shell-game session -- ball placement, the
/// shuffle, and the tap-to-guess reveal (Eddie, Sept 13, right after
/// Floor 7's Tic-Tac-Toe). Same shape as TicTacToeViewModel: dumb
/// about anything outside the game itself, calls back into
/// TapNavigationController exactly once via onWin.
///
/// The entire "no cheating" guarantee lives in ShellGame.swift's
/// ShellGameRound, not here -- this view model only ever reads
/// round.cupAtSlot / round.winningSlot and mutates the SAME round via
/// round.swap(_:_:); it never tracks the ball's location any other
/// way, so the on-screen cups and the win check can never disagree.
@MainActor
final class ShellGameViewModel: ObservableObject {
    enum Phase {
        case placingBall
        case shuffling
        case waitingForTap
        case revealedCorrect
        case revealedWrong
    }

    @Published private(set) var phase: Phase = .placingBall
    /// cupAtSlot[slot] = cup identity at that table position -- copied
    /// straight from `round` after every change, never computed any
    /// other way. Driving the view's per-cup offsets off this array
    /// (see ShellGameOverlay.xOffset) is what makes the cups visibly
    /// swap places rather than merely relabeling themselves.
    @Published private(set) var cupAtSlot: [Int] = [0, 1, 2]
    @Published private(set) var statusText = ""
    /// Which table slots are currently shown lifted (revealing
    /// whatever's underneath) -- the ball's starting cup during the
    /// initial "remember this" beat, the player's own tapped cup on a
    /// guess, and (only on a wrong guess, per Eddie: "optionally...
    /// also reveal which cup actually contains the ball") the true
    /// cup a beat later.
    @Published private(set) var liftedSlots: Set<Int> = []
    @Published private(set) var ballCupID = 0

    /// Fired exactly once, the instant the player taps the correct
    /// cup -- ShellGameOverlay wires this to
    /// TapNavigationController.completeShellGameTerminal(at:).
    var onWin: (() -> Void)?

    private var rng = SystemRandomNumberGenerator()
    private var round: ShellGameRound
    /// Invalidates any in-flight asyncAfter chain from a previous
    /// round/reveal the moment a new one begins, so a stray old timer
    /// can never fire after the game has already moved on.
    private var runToken = UUID()

    init() {
        let ball = Int.random(in: 0..<3)
        ballCupID = ball
        round = ShellGameRound(ballCupID: ball)
        beginRound(reusing: round)
    }

    var canTap: Bool { phase == .waitingForTap }

    func cupTapped(_ slot: Int) {
        guard phase == .waitingForTap else { return }
        let token = UUID()
        runToken = token
        liftedSlots = [slot]
        if slot == round.winningSlot {
            phase = .revealedCorrect
            statusText = "GOT IT!\nAPTITUDE: EXCEPTIONAL"
            onWin?()
            // No reset scheduled here -- TapNavigationController takes
            // over from here exactly like completeTicTacToeTerminal:
            // it dismisses this whole overlay a beat later, so there
            // is nothing for this view model to clean up itself.
        } else {
            phase = .revealedWrong
            statusText = "EMPTY.\nRESETTING\u{2026}"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.runToken == token else { return }
                self.liftedSlots.insert(self.round.winningSlot)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                guard let self, self.runToken == token else { return }
                self.beginNewRound()
            }
        }
    }

    private func beginNewRound() {
        let ball = Int.random(in: 0..<3)
        ballCupID = ball
        round = ShellGameRound(ballCupID: ball)
        beginRound(reusing: round)
    }

    /// Ball-placement beat, then the shuffle, then waiting for a tap --
    /// `round` must already be freshly constructed (ballCupID just
    /// chosen, cupAtSlot at the identity permutation) before this runs.
    private func beginRound(reusing freshRound: ShellGameRound) {
        cupAtSlot = freshRound.cupAtSlot
        phase = .placingBall
        // Eddie: "the animation clearly shows the ball being placed
        // underneath one of the three cups" -- show that cup lifted,
        // ball visible, before anything else happens.
        liftedSlots = [freshRound.winningSlot]
        statusText = "REMEMBER THIS CUP\u{2026}"
        let token = UUID()
        runToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.runToken == token else { return }
            self.liftedSlots = [] // cup lowers, hiding the ball again
            self.statusText = "HERE WE GO\u{2026}"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.runToken == token else { return }
                self.phase = .shuffling
                self.statusText = "WATCH CLOSELY\u{2026}"
                let steps = ShellGameShuffle.plan(using: &self.rng)
                self.performSwaps(steps, index: 0, token: token)
            }
        }
    }

    /// Plays back one swap step at a time -- each step both mutates
    /// `round` (the single source of truth winningSlot reads) and
    /// publishes the resulting cupAtSlot inside withAnimation, so the
    /// cups visibly slide to their new positions in sync with the
    /// exact same swap the final answer is based on.
    private func performSwaps(_ steps: [ShellGameSwapStep], index: Int, token: UUID) {
        guard runToken == token else { return }
        guard index < steps.count else {
            phase = .waitingForTap
            statusText = "PICK A CUP"
            return
        }
        let step = steps[index]
        round.swap(step.slotA, step.slotB)
        withAnimation(.easeInOut(duration: step.duration)) {
            cupAtSlot = round.cupAtSlot
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step.duration) { [weak self] in
            self?.performSwaps(steps, index: index + 1, token: token)
        }
    }
}

/// Presented over the 3D scene the instant the player approaches and
/// faces Floor 8's shell-game station (see
/// TapNavigationController.activateShellGameTerminal) -- identical
/// "dark scrim + centered panel, tap scrim or a button to step away"
/// shape as TicTacToeOverlay, Floor 7's proven pattern.
struct ShellGameOverlayHost: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        if let coord = controller.activeShellGameTerminal {
            ShellGameOverlay(controller: controller, coord: coord)
        }
    }
}

private struct ShellGameOverlay: View {
    @ObservedObject var controller: TapNavigationController
    let coord: GridCoordinate
    @StateObject private var game = ShellGameViewModel()

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { controller.cancelShellGameTerminal() }
            VStack(spacing: 18) {
                VStack(spacing: 2) {
                    Text("BREAK ROOM DIVERSION")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.green.opacity(0.85))
                    Text("THREE-CUP SHELL GAME")
                        .font(.system(size: 19, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                }
                table
                Text(game.statusText)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 40)
                    .accessibilityIdentifier("shellGameStatus")
                Button("Step Away") { controller.cancelShellGameTerminal() }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 120, minHeight: 42)
                    .background(Color.black.opacity(0.5), in: Capsule())
                    .accessibilityIdentifier("stepAwayFromShellGameButton")
            }
            .padding(24)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.5), lineWidth: 2))
            .padding(28)
        }
        .accessibilityAction(.escape) { controller.cancelShellGameTerminal() }
        .onAppear { game.onWin = { controller.completeShellGameTerminal(at: coord) } }
    }

    private var table: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { cupID in
                let slot = game.cupAtSlot.firstIndex(of: cupID) ?? cupID
                if cupID == game.ballCupID, game.liftedSlots.contains(slot) {
                    ShellGameBallView()
                        .offset(x: xOffset(slot), y: 16)
                }
                ShellGameCupView(lifted: game.liftedSlots.contains(slot))
                    .offset(x: xOffset(slot))
                    .onTapGesture { game.cupTapped(slot) }
                    .allowsHitTesting(game.canTap)
                    .accessibilityIdentifier("shellGameCup_\(slot)")
            }
        }
        .frame(height: 120)
    }

    private func xOffset(_ slot: Int) -> CGFloat {
        CGFloat(slot - 1) * 92
    }
}

/// A plain trapezoid, wide at the rim and narrow at the base -- just
/// enough to read as "a cup" without any decoration. Eddie: "do not
/// over-design it... NOT decoration."
private struct ShellGameCupShape: Shape {
    /// Eddie, Sept 13: the original silhouette read as an open bucket
    /// (wide opening at the top) instead of an inverted cup covering
    /// the ball. Flipped vertically -- narrow end at minY (top), wide
    /// rim at maxY (bottom) -- everything else about the shape
    /// (overall size, inset fraction) is unchanged.
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct ShellGameCupView: View {
    let lifted: Bool

    var body: some View {
        ShellGameCupShape()
            .fill(Color(white: 0.16))
            .overlay(ShellGameCupShape().stroke(Color.green.opacity(0.6), lineWidth: 2))
            .frame(width: 66, height: 58)
            .offset(y: lifted ? -48 : 0)
            .animation(.easeOut(duration: 0.25), value: lifted)
    }
}

private struct ShellGameBallView: View {
    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 22, height: 22)
    }
}
