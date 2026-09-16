import SwiftUI
import Combine

/// Drives one Floor 13 playthrough -- sequence generation, playback
/// flashing, and tap-acknowledgment, on top of the pure SimonGame
/// state (Eddie, Sept 13). Same shape as the other six view models:
/// dumb about anything outside the game itself, calls back into
/// TapNavigationController exactly once via onWin, and -- matching
/// the pacing fix Floors 10-12 already got -- never auto-dismisses a
/// result. Both the success and failure screens stay up exactly
/// until the player taps.
///
/// All wall-clock timing lives here, not in SimonGame, and not
/// anywhere global -- same "keep timer/game timing local to the
/// game" rule as WhackAMoleViewModel, except Simon has NO round timer
/// at all (Eddie: "Do NOT use a countdown timer... the challenge is
/// memory/pattern reproduction, not speed"). The only scheduled work
/// here is the playback flash sequence (one quadrant at a time, with
/// readable gaps) and a brief tap-acknowledgment blink -- both guarded
/// by the same runToken idea as WhackAMoleViewModel: the instant the
/// round ends (success or failure) or this view model is deallocated
/// (the overlay disappeared, e.g. Step Away), runToken changes and
/// every [weak self] closure that fires afterward is a harmless no-op.
/// Nothing here ever leaves an orphan flash running or lets a stale
/// callback mutate a fresh game.
@MainActor
final class SimonViewModel: ObservableObject {
    @Published private(set) var game = SimonGame()
    /// Which quadrant (0..<4) the BUILDING is currently flashing during
    /// playback, if any.
    @Published private(set) var flashingQuadrant: Int?
    /// Which quadrant the PLAYER just tapped, for a brief bright-green
    /// acknowledgment -- Eddie: "provide an immediate brief bright-
    /// green visual response so the tap feels acknowledged."
    @Published private(set) var tappedQuadrant: Int?

    /// Fired exactly once, the instant the PLAYER taps through a
    /// SUCCESS result screen -- SimonOverlay wires this to
    /// TapNavigationController.completeSimonTerminal(at:).
    var onWin: (() -> Void)?

    private var rng = SystemRandomNumberGenerator()
    private var runToken = UUID()

    private static let flashOnDuration: TimeInterval = 0.55
    private static let flashGapDuration: TimeInterval = 0.25
    private static let playbackToInputGap: TimeInterval = 0.35
    private static let roundAdvanceBeat: TimeInterval = 0.55
    // Eddie, Sept 13, round 2: on-device the player's own tap
    // acknowledgment blinked so briefly it was barely visible --
    // raised from 0.18s to 0.30s so it's clearly readable. Building
    // playback timing (flashOnDuration/flashGapDuration/
    // playbackToInputGap/roundAdvanceBeat) is untouched; SimonGame's
    // own tap(_:) evaluation is still immediate -- this only extends
    // how long the UI shows the acknowledgment before clearing it.
    private static let tapFlashDuration: TimeInterval = 0.30

    var statusText: String {
        switch game.phase {
        case .ready:
            return "WATCH THE PATTERN"
        case .playback:
            return "ROUND \(game.currentRoundLength) / \(SimonGame.targetLength)\n\nWATCH..."
        case .input:
            return "ROUND \(game.currentRoundLength) / \(SimonGame.targetLength)\n\nYOUR TURN"
        case .success:
            return "MEMORY: EXCEPTIONAL\n\nTEST PASSED\n\nELEVATOR ACCESS GRANTED."
        case .failure:
            return "MEMORY: INSUFFICIENT"
        }
    }

    /// Eddie: "The player must explicitly tap START... The game must
    /// NOT begin automatically merely because the terminal activates."
    func start() {
        guard game.phase == .ready else { return }
        let sequence = SimonSequenceGenerator.makeSequence(using: &rng)
        game.start(sequence: sequence)
        let token = UUID()
        runToken = token
        beginPlaybackRound(token: token)
    }

    /// Eddie: "As the player taps: compare each tap immediately
    /// against the corresponding expected sequence item... provide an
    /// immediate brief bright-green visual response so the tap feels
    /// acknowledged." The acknowledgment flash always happens, whether
    /// the tap turns out right or wrong -- the RESULT (round continues
    /// / round advances / failure) is decided entirely by SimonGame.
    func tapQuadrant(_ quadrant: Int) {
        guard game.phase == .input else { return }
        let token = runToken
        tappedQuadrant = quadrant
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapFlashDuration) { [weak self] in
            guard let self, self.runToken == token else { return }
            if self.tappedQuadrant == quadrant { self.tappedQuadrant = nil }
        }
        game.tap(quadrant)
        switch game.phase {
        case .success, .failure:
            endRound()
        case .playback:
            // Eddie: "correct sequence -> brief beat -> next Building
            // playback." Same run, same token -- this is continuing
            // the current playthrough, not starting a new one.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.roundAdvanceBeat) { [weak self] in
                guard let self, self.runToken == token, self.game.phase == .playback else { return }
                self.beginPlaybackRound(token: token)
            }
        case .input, .ready:
            break // correct tap mid-round -- keep waiting for the next one
        }
    }

    /// TAP TO CONTINUE (success) fires onWin?(), same dismiss-on-tap
    /// contract as every other embedded game's pacing fix. TAP TO
    /// RETRY (failure) -- Eddie: "No lives. No money penalty. No
    /// global state damage" -- just resets back to the START screen;
    /// nothing auto-begins a new sequence.
    func continueAfterResult() {
        switch game.phase {
        case .success:
            onWin?()
        case .failure:
            endRound() // belt-and-suspenders: no stale playback survives a retry
            game.reset()
            flashingQuadrant = nil
            tappedQuadrant = nil
        case .ready, .playback, .input:
            break
        }
    }

    private func endRound() {
        runToken = UUID() // invalidates every in-flight playback-step/tap-flash closure below
    }

    /// Flashes sequence[0..<currentRoundLength] one item at a time,
    /// then hands off to SimonGame.startInputPhase() once the whole
    /// round has been shown. Eddie: "clear visual separation between
    /// flashes... pacing should be readable and pleasant, not
    /// frantic."
    private func beginPlaybackRound(token: UUID) {
        flashingQuadrant = nil
        playbackStep(token: token, index: 0)
    }

    private func playbackStep(token: UUID, index: Int) {
        guard runToken == token, game.phase == .playback else { return }
        guard index < game.currentRoundLength else {
            flashingQuadrant = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.playbackToInputGap) { [weak self] in
                guard let self, self.runToken == token, self.game.phase == .playback else { return }
                self.game.startInputPhase()
            }
            return
        }
        let quadrant = game.sequence[index]
        flashingQuadrant = quadrant
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashOnDuration) { [weak self] in
            guard let self, self.runToken == token else { return }
            self.flashingQuadrant = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashGapDuration) { [weak self] in
                guard let self, self.runToken == token, self.game.phase == .playback else { return }
                self.playbackStep(token: token, index: index + 1)
            }
        }
    }
}

/// Presented over the 3D scene the instant the player approaches and
/// faces Floor 13's terminal (see
/// TapNavigationController.activateSimonTerminal) -- same "dark scrim
/// + centered panel, green-on-black terminal" visual language as
/// Floors 7-12. Eddie: "The player should look at this terminal and
/// immediately think: 'Oh -- Simon.'" -- a circle split into exactly
/// four green-on-black pie pieces, nothing else.
struct SimonOverlayHost: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        if let coord = controller.activeSimonTerminal {
            SimonOverlay(controller: controller, coord: coord)
        }
    }
}

private struct SimonOverlay: View {
    @ObservedObject var controller: TapNavigationController
    let coord: GridCoordinate
    @StateObject private var viewModel = SimonViewModel()

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
                    Text("MEMORY ASSESSMENT")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                }
                if showQuadrants {
                    quadrantsControl
                }
                Text(viewModel.statusText)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 40)
                    .accessibilityIdentifier("simonStatus")
                actionArea
            }
            .padding(24)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.5), lineWidth: 2))
            .padding(28)
            .contentShape(Rectangle())
            .onTapGesture { handleSurfaceTap() }
        }
        .accessibilityAction(.escape) { controller.cancelSimonTerminal() }
        .onAppear { viewModel.onWin = { controller.completeSimonTerminal(at: coord) } }
    }

    /// Eddie: "Initial ready state should show the four-part Simon
    /// control." Shown through .ready/.playback/.input; hidden once a
    /// result is up, same as WhackAMoleOverlay's grid.
    private var showQuadrants: Bool {
        switch viewModel.game.phase {
        case .ready, .playback, .input: return true
        case .success, .failure: return false
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch viewModel.game.phase {
        case .ready:
            VStack(spacing: 12) {
                Button {
                    viewModel.start()
                } label: {
                    Text("START")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(minWidth: 140, minHeight: 50)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.5), lineWidth: 2))
                }
                .accessibilityIdentifier("simonStartButton")
                Button("Step Away") { controller.cancelSimonTerminal() }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 120, minHeight: 42)
                    .background(Color.black.opacity(0.5), in: Capsule())
                    .accessibilityIdentifier("stepAwayFromSimonButton")
            }
        case .playback, .input:
            // Eddie: "hidden during Building playback... hidden while
            // player is entering sequence. The player should not
            // accidentally leave the game in the middle of the round."
            EmptyView()
        case .success, .failure:
            // Eddie: "Do NOT auto-dismiss... Remain indefinitely until
            // player taps." Step Away also hidden here, same as during
            // playback/input.
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
            .accessibilityIdentifier("simonContinueButton")
        }
    }

    /// Mirrors WhackAMoleOverlay/FiveCardDrawOverlay's
    /// handleSurfaceTap: once a result is showing, a tap anywhere on
    /// the terminal surface continues, same as the dedicated button.
    private func handleSurfaceTap() {
        guard viewModel.game.phase == .success || viewModel.game.phase == .failure else { return }
        viewModel.continueAfterResult()
    }

    private var quadrantsControl: some View {
        ZStack {
            ForEach(0..<SimonGame.quadrantCount, id: \.self) { index in
                quadrantButton(index)
            }
            Circle()
                .stroke(Color.green.opacity(0.5), lineWidth: 2)
                .allowsHitTesting(false)
        }
        .frame(width: 168, height: 168)
    }

    private func quadrantButton(_ index: Int) -> some View {
        let illuminated = viewModel.flashingQuadrant == index || viewModel.tappedQuadrant == index
        return Button {
            viewModel.tapQuadrant(index)
        } label: {
            SimonQuadrantShape(index: index)
                .fill(illuminated ? Color.green.opacity(0.85) : Color.green.opacity(0.1))
                .overlay(SimonQuadrantShape(index: index).stroke(Color.green.opacity(illuminated ? 1 : 0.4), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.game.phase != .input)
        .contentShape(SimonQuadrantShape(index: index))
        .accessibilityIdentifier("simonQuadrant_\(index)")
    }
}

/// One quarter of the classic Simon circle -- Eddie: "A CIRCLE divided
/// into exactly FOUR equal pie/quadrant pieces. NOT 6. NOT more.
/// FOUR." A plain SwiftUI pie-wedge Shape, no image assets, so
/// index 0...3 each get a stable, addressable identity (Eddie: "so we
/// can later attach four distinct tones during the dedicated audio
/// pass" -- no audio yet, this pass just needs the identity to exist).
private struct SimonQuadrantShape: Shape {
    let index: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let startAngle = Angle.degrees(Double(index) * 90 - 90)
        let endAngle = startAngle + Angle.degrees(90)
        path.move(to: center)
        path.addLine(to: CGPoint(x: center.x + radius * CGFloat(cos(startAngle.radians)),
                                  y: center.y + radius * CGFloat(sin(startAngle.radians))))
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.closeSubpath()
        return path
    }
}
