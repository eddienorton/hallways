//
//  ContentView.swift
//  Hallways
//
//  Prototype 1: one hallway, one camera, one finger. The only job of this
//  screen is to answer "does moving through this feel good?" — everything
//  else (maze, photos, objective) is deliberately not here yet.
//

import SwiftUI
import SceneKit
import Combine
import UIKit

/// Tiny bridge so the SwiftUI Reset button can tell the SceneKit side
/// (living inside a UIViewRepresentable) to snap back to the start.
final class HallwayRuntime: ObservableObject {
    @Published var resetToken = 0
    func requestReset() { resetToken += 1 }
}

/// The wall-texture "arsenal" — one shared choice so the cycle button
/// and the SceneKit side (which owns the actual material) stay in sync.
final class WallThemeStore: ObservableObject {
    @Published var current: HallwayTheme = .brick
    func cycle() { current = current.next }
}

/// makeUIView is where the maze's TapNavigationController actually gets
/// built (it needs the camera node the scene builder creates), which is
/// too late for a plain @StateObject in ContentView — this bridges that
/// gap so SwiftUI can still put up the choice buttons once it exists.
final class NavigationBridge: ObservableObject {
    @Published var controller: TapNavigationController?

    // Eddie, Sept 8: "it just abruptly flashes and youre in the
    // hallway" -- no curtain, no reopening beat. Root cause: the old
    // ElevatorCurtainOverlay watched controller.floorTransitionRequested,
    // but was only ever mounted `if let navController = navBridge.
    // controller`, and onReachedEnd (below) set that same
    // floorTransitionRequested AND nulled navBridge.controller in the
    // same synchronous tick -- so SwiftUI's very first render of the
    // transition already had controller == nil, the overlay never got
    // mounted with the new event, and its onChange never fired at all.
    // This property lives here instead, on the one object that
    // actually survives the controller swap, so the curtain can watch
    // something that doesn't get pulled out from under it mid-animation.
    @Published var floorTransitionRequested: TapNavigationController.FloorTransitionEvent?

    // Eddie, Sept 8: wants the curtain's closed-door look to be
    // the SAME color/lighting as the real 3D doors, pixel for
    // pixel, not a hand-tuned approximation. Set once per ride,
    // right before the SCNView's scene gets torn down for the
    // next floor (see onReachedEnd in HallwaySceneView.makeUIView)
    // -- a real snapshot of exactly what was on screen at that
    // instant, dimmed lighting and all.
    @Published var doorSnapshot: UIImage?
}

/// Captures moneyHUD's actual on-screen frame (see moneyHUD's own
/// .background(GeometryReader...) below) so the cash celebration can
/// animate flying toward the REAL total number instead of a guessed
/// fixed point -- correct on any device size, orientation, or future
/// HUD layout change. Written once per layout pass by moneyHUD, read
/// once via .onPreferenceChange on the outer ZStack.
private struct MoneyHUDFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// One "temporary" falling trash can -- Eddie, Sept 9: "when you pick
/// up the trash, the sound occurs but the trash just disappears. we
/// need some kind of visual feed back. do something temporary and ill
/// try to figure out something... maybe little spinning trash cans."
/// Deliberately simple/placeholder per Eddie's own framing, unlike the
/// cash celebration above -- just a small burst of these tumbling down
/// past the screen. Values are randomized fresh per pickup (see
/// ContentView's onChange(of: mazeStore.lastTrashPickup)) so a run of
/// pickups doesn't look identical every time.
private struct FallingTrashPiece: Identifiable {
    let id = UUID()
    let artwork: TrashPickupArtwork
    let xFraction: CGFloat // 0...1 across the screen width
    let delay: Double      // slight stagger so they don't all drop in lockstep
    let duration: Double
    let spins: Double      // full 360s over the fall
    let scale: CGFloat
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var tuning = TuningParams()
    @StateObject private var runtime = HallwayRuntime()
    @StateObject private var mazeStore = MazeStore()
    @StateObject private var navBridge = NavigationBridge()
    @StateObject private var themeStore = WallThemeStore()
    @State private var showGridEditor = false
    // Only resynced when the grid editor closes (not live on every paint
    // stroke) — see the .id() below and the fullScreenCover's onDismiss.
    @State private var sceneVersion = 0

    // Eddie, Sept 7: "we want the intro screen (probably the building
    // with some text instruction on it, copyright, etc)." A one-time
    // full-screen gate shown on launch, dismissed with a tap -- same
    // "own @State overlay with a completion closure" shape as the grid
    // editor's fullScreenCover, just simpler (no navigation stack, just
    // fades out). True on every launch (not @AppStorage-remembered like
    // hasSeenNavGestureHint) since this is the title screen, not a
    // one-time tutorial hint.
    @State private var showIntroScreen = true

    // A one-time "tap to walk, swipe to turn" hint, gone the moment
    // it's shown once and never seen again after that -- the tradeoff
    // for having no on-screen buttons at all (Eddie, Sept 6: "the
    // tap/swipe is soo perfect why have the buttons? ... can we get
    // away with none"). Buttons are self-documenting; gestures aren't,
    // so this teaches it once instead of leaving a permanent D-pad
    // around just so newcomers can find the controls.
    @AppStorage("hasSeenNavGestureHint") private var hasSeenNavGestureHint = false
    @State private var showNavGestureHint = false

    // The cash "earth-shattering graphic" -- Eddie, Sept 6: grabbing
    // money should ring up with a dazzling animation and a ka-ching
    // sound, not just silently tick the HUD number over. Amount is
    // read straight off MazeStore.lastCashPickup (see the .onChange
    // below); nil hides the celebration entirely.
    @State private var cashCelebrationAmount: Int? = nil
    // A quick scale-bounce on the money HUD itself, timed to land
    // alongside the celebration so the flying "+$100" and the number
    // actually changing read as the same moment, not two unrelated
    // things.
    @State private var moneyHUDPulse = false
    /// moneyHUD's live on-screen frame, in the SAME (global) coordinate
    /// space cashCelebrationView measures itself in -- see
    /// MoneyHUDFramePreferenceKey above. .zero until the first layout
    /// pass reports it (there's a brief window before that where a
    /// celebration would have nowhere real to fly to -- see
    /// cashCelebrationView's own fallback for that case).
    @State private var moneyHUDFrame: CGRect = .zero
    /// False while the "+$100" is still hanging large and centered,
    /// true once it's animating (shrinking + traveling) toward
    /// moneyHUDFrame -- Eddie, Sept 7: "close in the amount animating
    /// by moving towards the big fat total number." Driven by the
    /// staged DispatchQueue sequence in the lastCashPickup onChange
    /// below, same pattern moneyHUDPulse already uses.
    @State private var cashCelebrationFlying = false

    // The trash-pickup placeholder visual (see FallingTrashPiece above)
    // -- an empty array hides it entirely. Fresh values generated per
    // pickup in the lastTrashPickup onChange below.
    @State private var fallingTrashCans: [FallingTrashPiece] = []
    /// False right after fallingTrashCans is populated (icons sitting
    /// at their pre-fall position), true once the fall itself should
    /// animate -- same "set state, then flip a bool a beat later so
    /// SwiftUI actually animates the transition" pattern
    /// cashCelebrationFlying uses.
    @State private var trashCansFalling = false

    // Cash total, always on screen -- Eddie: "a big fast total that
    // appears on the screen somewhere." Gold to match the 3D cash
    // pieces themselves; same dark-capsule treatment as the
    // collected-trash HUD strip so the two read as the same UI family.
    private var moneyHUD: some View {
        HStack(spacing: 6) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 24, weight: .bold))
            // Eddie, Sept 7: "the total... isnt big fat now but will
            // be -- thats the entire game so we want the total
            // prominant." Bumped from 18pt/.bold up to 30pt/.heavy --
            // the single biggest piece of text on screen now, on
            // purpose.
            Text("\(mazeStore.moneyTotal)")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.3))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.7), in: Capsule())
        .scaleEffect(moneyHUDPulse ? 1.3 : 1.0)
        // Reports this capsule's real on-screen frame up to
        // moneyHUDFrame (global coordinates, same space
        // cashCelebrationView measures itself in) every time it moves
        // or resizes -- what the flying "+$100" actually flies TO.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: MoneyHUDFramePreferenceKey.self, value: geo.frame(in: .global))
            }
        )
    }

    /// The celebration itself: a soft gold radial flash behind
    /// everything (light, not a flat tint) plus a big "+$<amount>"
    /// that pops in oversized and settles/fades -- first pass at
    /// "dazzling," easy to retune (size, duration, color) once Eddie's
    /// actually seen it land on-device. Non-interactive and drawn above
    /// the nav gesture hint (zIndex 3) so it's never mistaken for
    /// something tappable and never gets hidden behind anything else
    /// currently on screen.
    @ViewBuilder
    private func cashCelebrationView(amount: Int) -> some View {
        // Eddie, Sept 7: the flash-and-fade-in-place version was
        // "actually stunning... i would just like to close in the
        // amount animating by moving towards the big fat total
        // number." GeometryReader gives this its own full-screen local
        // coordinate space (matching .global here, since this sits
        // directly in the root ZStack with no offsetting ancestor --
        // same assumption moneyHUD's own frame-reporting background
        // relies on) so "center" and moneyHUDFrame's target point are
        // directly comparable without any conversion math.
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // Falls back to a fixed top-left-ish point on the (rare,
            // first-ever-pickup) chance a celebration fires before
            // moneyHUD's own GeometryReader has reported a real frame
            // yet -- better than flying to (0, 0) and vanishing into
            // the corner.
            let landingYNudge: CGFloat = 10
            let target: CGPoint = moneyHUDFrame == .zero
                ? CGPoint(x: 70, y: 70 + landingYNudge)
                : CGPoint(x: moneyHUDFrame.midX, y: moneyHUDFrame.midY + landingYNudge)

            ZStack {
                RadialGradient(
                    colors: [Color(red: 1.0, green: 0.84, blue: 0.3).opacity(0.55), .clear],
                    center: .center, startRadius: 0, endRadius: 420
                )
                .opacity(cashCelebrationFlying ? 0 : 1)

                Text("+$\(amount)")
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.3))
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .scaleEffect(cashCelebrationFlying ? 0.32 : 1)
                    .opacity(cashCelebrationFlying ? 0.35 : 1)
                    .position(x: cashCelebrationFlying ? target.x : center.x,
                              y: cashCelebrationFlying ? target.y : center.y)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .transition(.asymmetric(
            insertion: .scale(scale: 1.6).combined(with: .opacity),
            removal: .opacity
        ))
        .zIndex(3)
    }

    /// The trash-pickup placeholder itself: a handful of "trash.fill"
    /// icons tumble in from random points near the top, spin, and fall
    /// past the bottom of the screen, fading out as they go. Purely
    /// presentational (no state ever reads back from this), and
    /// intentionally simple -- Eddie's explicitly planning to replace
    /// it ("ill try to figure out something") once there's something
    /// on screen to react to at all.
    @ViewBuilder
    private var trashCelebrationView: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(fallingTrashCans) { can in
                    can.artwork.image
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44 * can.scale, height: 44 * can.scale)
                        .foregroundStyle(can.artwork.color)
                        .shadow(color: .black.opacity(0.45), radius: 3)
                        .rotationEffect(.degrees(trashCansFalling ? 360 * can.spins : 0))
                        .position(
                            x: geo.size.width * can.xFraction,
                            y: trashCansFalling ? geo.size.height + 60 : -60
                        )
                        .opacity(trashCansFalling ? 0 : 1)
                        .animation(.easeIn(duration: can.duration).delay(can.delay), value: trashCansFalling)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .zIndex(2.5) // above the nav gesture hint, below the cash celebration -- doesn't really matter since they'd rarely overlap, just keeping the same "later in the list = higher" convention
    }

    private var navGestureHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 32, weight: .semibold))
            Text("Tap to walk. Swipe to turn.\nHold to keep walking.")
                .multilineTextAlignment(.center)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
    }

    var body: some View {
        ZStack {
            HallwaySceneView(tuning: tuning, runtime: runtime, mazeStore: mazeStore, navBridge: navBridge, themeStore: themeStore, cameraEnabled: scenePhase == .active && !showGridEditor && !showIntroScreen)
                .id(sceneVersion)
                .ignoresSafeArea()

            if let navController = navBridge.controller {
                NavigationOverlay(controller: navController)
            }

            // Unconditional, unlike the overlays above -- it has to
            // keep existing (and keep its own @State) straight through
            // the moment navBridge.controller goes nil and comes back
            // as a different instance, or the reopening animation it's
            // in the middle of gets torn down along with the old
            // controller. See NavigationBridge.floorTransitionRequested.
            ElevatorCurtainOverlay(navBridge: navBridge)

            if showNavGestureHint {
                navGestureHint
                    .transition(.opacity)
                    .allowsHitTesting(false) // a hint, not a button -- must never eat the very tap/swipe it's explaining
                    .zIndex(2)
            }

            if let amount = cashCelebrationAmount {
                cashCelebrationView(amount: amount)
            }

            if !fallingTrashCans.isEmpty {
                trashCelebrationView
            }

            // Drawn last so zIndex alone (not ZStack ordering) is what
            // guarantees it sits above literally everything else,
            // including the money celebration and both alarm/map
            // overlays above.
            if showIntroScreen {
                IntroScreenView {
                    withAnimation(.easeOut(duration: 0.5)) {
                        showIntroScreen = false
                    }
                    if mazeStore.currentMazeID == 1 {
                        navBridge.controller?.advance()
                    }
                }
                .transition(.opacity)
                .zIndex(10)
            }

            VStack {
                HStack {
                    moneyHUD
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            mazeStore.switchTo(id: 1)
                            runtime.requestReset()
                            withAnimation(.easeOut(duration: 0.3)) {
                                showIntroScreen = true
                            }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        Button {
                            showGridEditor = true
                        } label: {
                            // A folded-map icon, not a grid icon — this is how a
                            // player should think of this screen: a map they
                            // check, not "the editor." (Still called
                            // GridEditorView internally, since that name
                            // describes what the code does, not what a player
                            // calls it — only the player-facing icon changed.)
                            Image(systemName: "map")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                }
                Spacer()
            }
            .padding()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // The other half of moneyHUD's own .background(GeometryReader
        // ... .preference(...)) above -- this is what actually turns
        // "moneyHUD reported its frame" into moneyHUDFrame being set,
        // so cashCelebrationView has somewhere real to fly to.
        .onPreferenceChange(MoneyHUDFramePreferenceKey.self) { frame in
            moneyHUDFrame = frame
        }
        .fullScreenCover(isPresented: $showGridEditor, onDismiss: {
            // Draw -> dismiss -> walk it: the 3D view only rebuilds now,
            // from whatever's currently painted, not mid-drag. But only
            // if the maze actually changed — nulling navBridge.controller
            // unconditionally here was a real bug: open the 2D editor
            // just to look, change nothing, and dismiss, and
            // mazeStore.version equals sceneVersion already, so .id()
            // never changes, HallwaySceneView is never rebuilt, and
            // nothing ever runs makeUIView again to reassign
            // navBridge.controller — it was nulled out and stayed nil
            // for good, taking the D-pad with it. Skipping the
            // nil+rebuild entirely when nothing changed leaves the
            // existing controller (and the D-pad observing it) exactly
            // as it was, no gap at all.
            mazeStore.save()
            if mazeStore.version != sceneVersion {
                navBridge.controller = nil
                sceneVersion = mazeStore.version
            }
        }) {
            GridEditorView(mazeStore: mazeStore, youAreHere: navBridge.controller?.currentCell, youAreHereFacing: navBridge.controller?.facing, youAreHereMazeID: navBridge.controller != nil ? mazeStore.currentMazeID : nil)
        }
        // A floor switch (reaching an elevator/end cell in 3D, or
        // navigating floors inside the grid editor) needs the 3D scene
        // rebuilt immediately, not just whenever the editor next closes
        // — unlike a plain cell edit, which the onDismiss check above
        // already handles. currentMazeID only ever changes on an actual
        // switch, never on a paint stroke, so watching it alone can't
        // misfire mid-edit. Doesn't null navBridge.controller itself —
        // a switch triggered from actual gameplay (reaching an end
        // cell) already does that explicitly, right where it needs to
        // for the "You made it!" flash to avoid; a switch triggered
        // from inside the grid editor is happening behind a
        // fullScreenCover the player can't see anyway, so there's
        // nothing to hide.
        .onChange(of: mazeStore.currentMazeID) { _ in
            sceneVersion = mazeStore.version
        }
        .onAppear {
            guard !hasSeenNavGestureHint else { return }
            hasSeenNavGestureHint = true
            withAnimation { showNavGestureHint = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                withAnimation { showNavGestureHint = false }
            }
        }
        // Fires once per real cash pickup (see MazeStore.addMoney) --
        // pops the celebration in, pulses the HUD number a beat later
        // (so it reads as "that flying total just landed here"), then
        // fades the celebration back out. Purely presentational: never
        // touches moneyTotal itself.
        .onChange(of: mazeStore.lastCashPickup) { newValue in
            guard let event = newValue else { return }
            cashCelebrationFlying = false
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                cashCelebrationAmount = event.amount
            }
            // Hangs large and centered for a beat first (long enough to
            // actually read the amount) before flying toward the total
            // -- see cashCelebrationView's own comment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeIn(duration: 0.35)) {
                    cashCelebrationFlying = true
                }
            }
            // Timed to land right as the flight arrives (0.35 + 0.35 =
            // 0.7) so the HUD's own bounce reads as "that's the exact
            // moment it landed," not a separate, unrelated pulse.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.68) {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.4)) {
                    moneyHUDPulse = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        moneyHUDPulse = false
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                withAnimation(.easeOut(duration: 0.15)) {
                    cashCelebrationAmount = nil
                }
            }
        }
        // Fires once per real trash pickup (see
        // TapNavigationController.collectObjectIfPresent's
        // onCollectTrash call and MazeStore.markTrashPickup) -- pops
        // in a small burst of falling trash-can icons, then clears
        // itself out once the longest possible fall has finished.
        // Same "temporary placeholder" framing as the sound effects
        // themselves -- Eddie's planning his own replacement.
        .onChange(of: mazeStore.lastTrashPickup) { newValue in
            guard newValue != nil else { return }
            trashCansFalling = false
            let artwork = TrashPickupArtwork.allCases
            fallingTrashCans = (0..<30).map { index in
                FallingTrashPiece(
                    artwork: artwork[index % artwork.count],
                    xFraction: (CGFloat(index) + CGFloat.random(in: 0.15...0.85)) / 30,
                    delay: Double.random(in: 0...0.55),
                    duration: Double.random(in: 1.5...2.0),
                    spins: Double.random(in: 1.5...3.0),
                    scale: CGFloat.random(in: 0.7...1.3)
                )
            }
            // One runloop tick later, same as cashCelebrationFlying
            // above, so the .animation modifier actually has a "from"
            // state (the pre-fall position set just above) to animate
            // away from instead of snapping straight to the end.
            DispatchQueue.main.async {
                trashCansFalling = true
            }
            // An earlier pickup's cleanup must not erase a newer burst.
            let cleanupDelay = fallingTrashCans.map { $0.duration + $0.delay }.max()! + 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + cleanupDelay) {
                guard mazeStore.lastTrashPickup == newValue else { return }
                fallingTrashCans = []
                trashCansFalling = false
            }
        }
    }
}

/// Status overlay: the collected-objects strip, a transient message
/// line, and a "Dead end" label when you've backed into one. Used to
/// also hold the D-pad (forward/left/right/back buttons) -- removed
/// entirely, Eddie, Sept 6: "the tap/swipe is soo perfect why have the
/// buttons? ... can we get away with none." Tap-to-walk, drag-to-turn,
/// swipe-down/two-finger-tap-to-turn-around (all wired in
/// HallwaySceneView's Coordinator) already cover every move the D-pad
/// did, so the buttons were pure redundancy once the gestures worked. A
/// separate view (rather than folding this into ContentView) because it
/// needs @ObservedObject on the controller directly — a nested
/// @Published inside NavigationBridge's own @Published wouldn't
/// otherwise trigger a re-render on its own.
private struct NavigationOverlay: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        VStack {
            if !controller.collectedObjects.isEmpty || !controller.carriedMail.isEmpty {
                collectedStrip
                    .padding(.top, 12)
            }
            Spacer()
            // A short, transient status line -- "nothing to throw out"
            // and whatever else comes along later -- reusing the exact
            // same dark-capsule label() this VStack already uses for
            // "Dead end"/"You made it!" rather than inventing a second
            // presentation for what's really the same kind of thing:
            // one line of text, on screen only while it's true. The
            // controller itself clears transientMessage the moment
            // currentCell changes, so this just shows whatever's there
            // -- no timer, no dismiss logic here at all. Eddie, Sept 5:
            // "it informs you of something that just happened, then
            // its gone once you leave."
            if let message = controller.transientMessage {
                label(message, systemImage: "exclamationmark.bubble.fill")
                    .transition(.opacity)
            }
        }
        // Used to be the D-pad's own .padding(.bottom, 40) keeping it
        // clear of the very bottom edge/home-indicator area -- kept
        // here, smaller, now that a status capsule (not a big button
        // cluster) is whatever ends up at the bottom of this VStack.
        .padding(.bottom, 24)
        .animation(.easeInOut(duration: 0.2), value: controller.transientMessage)
    }

    // What you're currently carrying -- first slice of the pick-up
    // mechanic: walking into an object removes it from the hallway and
    // adds it here, oldest first. No delivery/matching logic yet -- this
    // is purely "gobble it, show you have it," same "just enough to feel
    // it out" scoping as the very first heart placement.
    private var collectedStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(controller.collectedObjects.enumerated()), id: \.offset) { _, kind in
                    Text(kind.displayEmoji).font(.system(size: 22))
                }
                ForEach(controller.carriedMail) { letter in
                    Label("Rm \(letter.roomNumber)", systemImage: "envelope.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.brown.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black.opacity(0.7), in: Capsule())
        .padding(.top, 65)
        .padding(.horizontal, 12)
    }

    private func label(_ text: String, systemImage: String) -> some View {
        // A solid dark backing, not .ultraThinMaterial — a dead end
        // puts the camera right up against close walls, which can read
        // as a near-white wash of light, and a translucent blur
        // background over that goes nearly invisible right when you
        // most need to see this.
        Label(text, systemImage: systemImage)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.7), in: Capsule())
            .padding(.bottom, 12)
    }
}

/// Eddie, Sept 7: "we want red flashing lights, sirens... make them
/// feel shitty" the moment the elevator refuses you for an unfinished
/// mission. Same "separate @ObservedObject-holding view" reason as
/// NavigationOverlay and FloorMapOverlayHost just above/below --
/// ContentView.body itself never sees TapNavigationController's own
/// @Published properties change, only navBridge.controller's identity.
/// The siren (SoundEffects.playAlarm) and the haptic both already fire
/// from openElevator() itself, right where elevatorRejected is set --
/// this view's only job is the strobe.
private struct ElevatorAlarmOverlay: View {
    @ObservedObject var controller: TapNavigationController
    @State private var flashOn = false

    var body: some View {
        Color.red
            .opacity(flashOn ? 0.5 : 0)
            .ignoresSafeArea()
            .allowsHitTesting(false) // an alarm, not a button -- must never eat a tap meant for the doors
            .onChange(of: controller.elevatorRejected) { event in
                guard event != nil else { return }
                // 4 on/off cycles, fast -- reads as an alarm strobe,
                // not a slow fade like the cash celebration's flash.
                let strobeDuration = 0.12
                for i in 0..<8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * strobeDuration) {
                        withAnimation(.linear(duration: strobeDuration * 0.7)) {
                            flashOn = (i % 2 == 0)
                        }
                    }
                }
            }
    }
}

private struct ElevatorCurtainOverlay: View {
    @ObservedObject var navBridge: NavigationBridge
    @State private var openFraction: CGFloat = 0 // 0 = fully closed, 1 = fully slid apart
    @State private var visible = false

    // Eddie, Sept 8: "can the metallic color be retained during
    // the open? ... when the doors are shut, you cant even see a
    // dividing line." This curtain was always a flat, single
    // SwiftUI Color per panel -- fine as a screen-covering
    // transition, but it can never show the shine the REAL 3D
    // elevator doors have (that material is actually lit; this is
    // a plain 2D overlay with no lighting at all), and with 2
    // identical flat colors meeting at zero gap, there was nothing
    // to read as a seam when closed. A gradient fakes a metallic
    // sheen (a lighter streak with darker brass to either side,
    // same idea as a real brushed-metal photo), and a thin dark
    // seam strip along each panel's own inner edge gives the
    // closed state a visible dividing line for the first time,
    // sliding apart naturally as the panels themselves do.
    // Eddie, Sept 8, next report: "looks like 2 pipes." A
    // horizontal gradient with a bright band centered in each
    // panel reads as a rounded cylinder, not a flat door -- and
    // with both panels using the identical pattern, that's 2
    // identical cylinders side by side. Switched to vertical
    // (top -> bottom): brighter near the top like it's catching
    // overhead light, darker toward the floor, same on both
    // panels. A flat surface lit from above doesn't create the
    // rounded-tube illusion the way a left-right bright streak
    // does, while still reading as metal rather than one flat
    // solid color.
    private var doorGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.64, green: 0.50, blue: 0.27),
                Color(red: 0.55, green: 0.42, blue: 0.22),
                Color(red: 0.43, green: 0.32, blue: 0.16),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // Eddie, Sept 8, next report: "the same exact color/lighting
    // has to be on the doors when theyre opening as when theyre
    // closing." The gradient above was always an approximation --
    // it has no idea what the headlamp's current dimmed intensity
    // is, what angle the pivot ended at, or which wall the
    // elevator is mounted on. navBridge.doorSnapshot (set right
    // before the old scene tears down -- see onReachedEnd in
    // HallwaySceneView.makeUIView) is a real capture of the exact
    // pixels the player was just looking at, so when it's there,
    // each panel shows its own half of that SAME image instead of
    // a guess at it -- cropped by laying the image out at the
    // curtain's full width, then clipping it down to a half-width
    // frame anchored to the correct side. The gradient stays as a
    // fallback for the rare case no snapshot exists yet.
    private func doorPanel(fullWidth: CGFloat, halfWidth: CGFloat, height: CGFloat, snapshot: UIImage?, cropAlignment: Alignment, seamAtTrailingEdge: Bool) -> some View {
        ZStack(alignment: seamAtTrailingEdge ? .trailing : .leading) {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .frame(width: fullWidth, height: height)
                    .frame(width: halfWidth, alignment: cropAlignment)
                    .clipped()
            } else {
                doorGradient
            }
            Color.black.opacity(0.55)
                .frame(width: 2)
        }
        .frame(width: halfWidth, height: height)
    }

    var body: some View {
        GeometryReader { geo in
            if visible {
                HStack(spacing: 0) {
                    doorPanel(fullWidth: geo.size.width, halfWidth: geo.size.width / 2, height: geo.size.height, snapshot: navBridge.doorSnapshot, cropAlignment: .leading, seamAtTrailingEdge: true)
                        .offset(x: -geo.size.width / 2 * openFraction)
                    doorPanel(fullWidth: geo.size.width, halfWidth: geo.size.width / 2, height: geo.size.height, snapshot: navBridge.doorSnapshot, cropAlignment: .trailing, seamAtTrailingEdge: false)
                        .offset(x: geo.size.width / 2 * openFraction)
                }
                .allowsHitTesting(false)
            }
        }
        // Measure the same full-screen bounds as the SceneKit snapshot.
        // Ignoring safe areas only inside the reader left uncovered bands.
        .ignoresSafeArea()
        .zIndex(9)
        .onChange(of: navBridge.floorTransitionRequested) { event in
            guard event != nil else { return }
            openFraction = 0
            visible = true
            // A brief beat so mazeStore.advanceToNextMaze() (called by
            // the controller right alongside this same event) actually
            // swaps in and settles behind this fully-closed curtain
            // before it starts sliding open -- otherwise the open
            // animation would start revealing a stale frame of the OLD
            // floor for an instant.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                SoundEffects.playElevatorArrival()
                DispatchQueue.main.asyncAfter(deadline: .now() + SoundEffects.elevatorDoorOpeningDelay) {
                    withAnimation(.easeInOut(duration: 1.0)) {
                        openFraction = 1
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                        visible = false
                    }
                }
            }
        }
    }
}

/// Same reason NavigationOverlay exists as its own struct just above:
/// ContentView.body reads `navBridge.controller` (a plain optional
/// reference), which only re-renders when THAT reference itself
/// changes -- not when a @Published property inside the controller it
/// points to changes. Eddie tapped a wall map, the "[Nav] tap hit wall
/// map" log fired (floorMapOverlayVisible really was set to true), but
/// nothing appeared on screen -- ContentView never got told to
/// recompute. Wrapping the check in its own @ObservedObject-holding
/// view fixes it the same way NavigationOverlay already does for
/// transientMessage/collectedObjects/etc.
private struct FloorMapOverlayHost: View {
    @ObservedObject var controller: TapNavigationController
    let mazeStore: MazeStore

    var body: some View {
        Group {
            if controller.floorMapOverlayVisible {
                FloorMapOverlayView(mazeStore: mazeStore, youAreHere: controller.currentCell, youAreHereFacing: controller.facing, onDismiss: {
                    withAnimation { controller.floorMapOverlayVisible = false }
                })
                .transition(.scale(scale: 0.05).combined(with: .opacity))
                .zIndex(1)
            }
        }
    }
}

/// Sept 7: "we want the intro screen (probably the building with some
/// text instruction on it, copyright, etc - i will take a pic of the
/// building we'll use but for now i can give you a temp pic)." Loads
/// BuildingIntro.png the same bundled-file way WallTheme's textures do
/// (Bundle.main.path(forResource:ofType:) -> UIImage(contentsOfFile:))
/// rather than through Assets.xcassets, so swapping in Eddie's real
/// building photo later is just replacing this one file in the project
/// folder -- no asset catalog entry to touch.
private struct IntroScreenView: View {
    let onEnter: () -> Void

    private var buildingImage: UIImage? {
        guard let path = Bundle.main.path(forResource: "BuildingIntro", ofType: "png") else { return nil }
        return UIImage(contentsOfFile: path)
    }

    var body: some View {
        ZStack {
            if let buildingImage {
                Image(uiImage: buildingImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            // Darkens the photo so the white title/instructions/copyright
            // stay readable over whatever building photo ends up here,
            // temp or final.
            LinearGradient(
                colors: [Color.black.opacity(0.15), Color.black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack {
                Spacer()
                Text("HALLWAYS")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 10)
                Spacer().frame(height: 12)
                Text("Tap to walk. Swipe to turn.\nFind your way through every floor.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 32)
                Spacer().frame(height: 36)
                Text("Tap anywhere to enter")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer().frame(height: 28)
                Text("© 2026 Edward Brayman. All rights reserved.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onEnter()
        }
    }
}

/// Bridges SceneKit into SwiftUI: builds the hallway scene once, wires the
/// camera to a MovementController driven by raw touches on the SCNView.
struct HallwaySceneView: UIViewRepresentable {
    @ObservedObject var tuning: TuningParams
    @ObservedObject var runtime: HallwayRuntime
    @ObservedObject var mazeStore: MazeStore
    @ObservedObject var navBridge: NavigationBridge
    @ObservedObject var themeStore: WallThemeStore

    var cameraEnabled: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> TouchTrackingSCNView {
        let view = TouchTrackingSCNView()

        if mazeStore.cells.isEmpty {
            // Nothing drawn in the grid editor yet — fall back to the
            // hand-built L-shaped prototype, free-roam controls
            // unchanged, so there's still something to walk into on
            // first launch.
            let (scene, cameraNode, walkableRects, wallMaterial, floorMaterial, ceilingMaterial) = HallwayScene.build(config: HallwayScene.Config(), theme: themeStore.current)
            view.scene = scene
            view.pointOfView = cameraNode

            let controller = MovementController(cameraNode: cameraNode, tuning: tuning)
            controller.touchView = view
            controller.walkableRects = walkableRects
            view.delegate = controller
            context.coordinator.movementController = controller
            context.coordinator.wallMaterials = [wallMaterial]
            context.coordinator.floorMaterial = floorMaterial
            context.coordinator.ceilingMaterial = ceilingMaterial
        } else {
            // A maze is drawn — tap-to-advance between intersections,
            // no hold-and-steer at all.
            let start = mazeStore.startCoordinate ?? GridCoordinate(row: 0, col: 0)
            let end = mazeStore.endCoordinate ?? start
            let facing = startingFacing(at: start, cells: mazeStore.cells)
            let (scene, cameraNode, _, wallMaterials, floorMaterial, ceilingMaterial, objectNodes, destinationNodes, elevatorDoors, exitSignNodes, floorMapPlaneNodes) = HallwayScene.build(fromMaze: mazeStore.cells, cellSize: mazeStore.cellSize, wallHeight: mazeStore.wallHeight, objects: mazeStore.objects, destinations: mazeStore.destinations, exitSigns: mazeStore.exitSigns, floorMaps: mazeStore.floorMaps, spotlights: mazeStore.spotlights, missionSigns: mazeStore.missionSigns, pictures: mazeStore.pictures, mirrors: mazeStore.mirrors, picturesUseCameraRoll: mazeStore.picturesUseCameraRoll, roomDoors: mazeStore.roomDoors, itemRooms: mazeStore.itemRooms, missionHeading: mazeStore.missionHeading, missionBody: mazeStore.missionBody, missionObjectKind: mazeStore.missionObjectKind, floorNumber: mazeStore.currentMazeID, totalFloors: mazeStore.floorCount, playerStart: start, playerEnd: end, theme: themeStore.current)
            view.scene = scene
            view.pointOfView = cameraNode
            context.coordinator.wallMaterials = wallMaterials
            context.coordinator.floorMaterial = floorMaterial
            context.coordinator.ceilingMaterial = ceilingMaterial
            // Eddie, Sept 9: "tapping the elevator doors that
            // first time sometimes takes a while." The shaft's
            // interior -- back wall, side panels, the building
            // photo, handrails -- sits behind the closed doors
            // and is never actually drawn until the first open,
            // which is exactly when SceneKit is forced to
            // compile those materials' shaders and upload the
            // photo's texture to the GPU for the first time --
            // real work, landing right at the one moment it's
            // most noticeable. prepare(_:shouldAbortBlock:) is
            // SceneKit's own API for exactly this: do that same
            // work on a background queue right now, off the main
            // thread, while the player is still walking toward
            // the doors, so there's nothing left to compile by
            // the time they actually tap. Harmless to call again
            // on floors whose shaft looks identical to one
            // already-warmed -- SceneKit just finds the compiled
            // shader already cached and returns immediately.
            if let elevatorDoors {
                // Xcode: "Incorrect argument label in call" -- there is
                // no separate async, completion-handler-based prepare
                // overload on SCNSceneRenderer despite how that reads.
                // The one real entry point is the synchronous
                // prepare(_:shouldAbortBlock:) -> Bool, which happily
                // takes a single object OR a collection of them
                // (recursing into each) via its `Any` parameter -- so
                // the array literal itself is fine, just not paired
                // with a completion handler. Since it's synchronous
                // (and can take a moment -- that's the whole point,
                // doing the work before the player's first tap rather
                // than during it), it goes on a background queue here
                // instead of running straight on the main thread.
                let shaftNodes: [Any] = [elevatorDoors.left, elevatorDoors.right, elevatorDoors.shaft]
                DispatchQueue.global(qos: .utility).async { [weak view] in
                    guard let view else { return }
                    _ = view.prepare(shaftNodes)
                }
            }
            let navController = TapNavigationController(cameraNode: cameraNode, scene: scene, cells: mazeStore.cells, cellSize: mazeStore.cellSize, startCell: start, startFacing: facing, endCell: end, objects: mazeStore.objects, objectNodes: objectNodes, destinations: mazeStore.destinations, destinationNodes: destinationNodes, elevatorLeftDoor: elevatorDoors?.left, elevatorRightDoor: elevatorDoors?.right, elevatorMountDirection: elevatorDoors?.direction, elevatorButtonNodes: elevatorDoors?.buttonNodes ?? [:], floorNumber: mazeStore.currentMazeID, nextFloorNumber: mazeStore.nextMazeID, exitSignNodes: exitSignNodes, exitSigns: mazeStore.exitSigns, floorMaps: mazeStore.floorMaps, floorMapPlaneNodes: floorMapPlaneNodes, missionSigns: mazeStore.missionSigns, pictures: mazeStore.pictures, mirrors: mazeStore.mirrors, roomDoors: mazeStore.roomDoors, itemRooms: mazeStore.itemRooms, missionObjectKind: mazeStore.missionObjectKind)
            navController.onCollectCash = { [mazeStore] amount in
                mazeStore.addMoney(amount)
            }
            navController.onCollectTrash = { [mazeStore] in
                mazeStore.markTrashPickup()
            }
            // Fires once the elevator's own open -> dwell -> close
            // sequence finishes (see TapNavigationController.
            // openElevator()) -- moves on to whatever floor this one's
            // linked to (see MazeStore.advanceToNextMaze). Nulling the
            // controller first avoids a stale "You made it!" flash
            // from the about-to-be-replaced scene — same idea as the
            // grid editor's onDismiss fix.
            navController.onReachedEnd = { [weak view, mazeStore, navBridge] in
                guard mazeStore.nextMazeID != nil else { return }
                // Eddie, Sept 8: "the same exact color/lighting has
                // to be on the doors when theyre opening as when
                // theyre closing." The curtain's gradient was
                // always a hand-tuned APPROXIMATION of the real 3D
                // doors -- it has no idea what the headlamp's
                // current dimmed intensity is, what angle the pivot
                // actually ended at, or which wall the elevator is
                // mounted on, so it could only ever be "close,"
                // never identical. A real screen-accurate snapshot
                // sidesteps all of that -- taken the instant before
                // this SCNView's scene gets torn down and rebuilt
                // for the next floor, it's the literal pixels the
                // player was just looking at, not a guess at them.
                navBridge.doorSnapshot = view?.snapshot()
                // Fired on navBridge itself, not read off the outgoing
                // controller -- see NavigationBridge.floorTransitionRequested.
                navBridge.floorTransitionRequested = TapNavigationController.FloorTransitionEvent()
                navBridge.controller = nil
                mazeStore.advanceToNextMaze()
            }
            view.delegate = navController
            context.coordinator.navigationController = navController

            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
            view.addGestureRecognizer(tap)

            // 2-finger tap = turn around (180), mirroring the D-pad's
            // back button — still just a turn, needs a forward tap after
            // to actually walk.
            let twoFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerTap))
            twoFingerTap.numberOfTouchesRequired = 2
            view.addGestureRecognizer(twoFingerTap)

            // Left/right turning is drag-controlled, not a discrete
            // flick: dragging pivots the camera live, one-to-one with
            // the finger, up to a full 90 degrees; letting go past the
            // halfway point (45 degrees) completes the turn, short of
            // it springs back to facing forward. Swipe down is still a
            // discrete flick = turn around, same as the D-pad's back button.
            let panRotate = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePanRotate))
            panRotate.maximumNumberOfTouches = 1
            view.addGestureRecognizer(panRotate)

            let swipeDown = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipeDown))
            swipeDown.direction = .down
            view.addGestureRecognizer(swipeDown)

            // Hold-to-keep-walking, Eddie, Sept 6: "longpress to keep
            // moving forward - you may have a little delay for each
            // box so it doesnt go to fast." Deliberately NOT its own
            // movement system -- see handleLongPressForward below, it
            // just auto-repeats the exact same advance() a real tap
            // already calls, so it inherits every stop condition
            // (forks, pickups, chutes, maps, dead ends) for free
            // instead of needing its own copy of that logic. A quick
            // tap still resolves as a tap -- UITapGestureRecognizer's
            // own timing fails on its own once the touch is held past
            // it, so the two don't need any explicit priority wiring.
            let longPressForward = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPressForward(_:)))
            longPressForward.minimumPressDuration = 0.35
            view.addGestureRecognizer(longPressForward)

            let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
            view.addGestureRecognizer(pinch)
            twoFingerTap.require(toFail: pinch)

            // @StateObject updates need to land on the next runloop tick,
            // not synchronously inside makeUIView.
            DispatchQueue.main.async {
                navBridge.controller = navController

                // Eddie, Sept 8, 13-screenshot elevator pass, the very
                // last item: "when you are off the elevator and in the
                // cube adjacent to the cube that holds the mission
                // text, you have to tap to move closer... automate the
                // one step into the next box." Every floor reached via
                // the elevator starts you at MazeStore.elevatorCoordinate
                // with the Floor Mission sign one cell away at
                // missionCoordinate (elevatorCoordinate.row + 1) --
                // currentMazeID == 1 is the one floor that's the
                // exception, entered on foot from the intro walk-in at
                // floorOneEntryCoordinate instead, so it's excluded
                // here rather than auto-walking someone forward before
                // they've even taken a real step. advance() is the
                // exact same call a tap already makes, so it inherits
                // every stop condition (mission sign included) for
                // free -- it's called here rather than from inside the
                // elevator ride itself because this is the one place
                // that runs once the NEW floor's own controller (not
                // the old one the ride played out on) actually exists.
                // Eddie, Sept 8: "after you pivot, and the
                // elevator doors proceed to open, you start moving
                // closer to the mission sign cube AS the door is
                // opening. it should be sequential." This runs on
                // the very next runloop tick after
                // floorTransitionRequested fires, but
                // ElevatorCurtainOverlay opens as the arrival chime sounds.
                // Match the full reveal duration
                // so walking starts only after the doors are open.
                if mazeStore.currentMazeID != 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + SoundEffects.elevatorRevealDuration) { [weak navController] in
                        navController?.advance()
                    }
                }
            }
        }

        view.backgroundColor = .black
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = false // our own touch/tap handling must be the only thing driving the camera
        view.isPlaying = true
        view.rendersContinuously = true

        if let scene = view.scene {
            var surfaces: [SCNMaterial] = []
            scene.rootNode.enumerateChildNodes { node, _ in
                if node.name == "mirrorSurface", let material = node.geometry?.firstMaterial { surfaces.append(material) }
            }
            if !surfaces.isEmpty {
                context.coordinator.mirrorCamera = MirrorCamera(materials: surfaces)
                context.coordinator.mirrorCamera?.setActive(cameraEnabled)
            }
        }
        context.coordinator.lastResetToken = runtime.resetToken
        context.coordinator.lastTheme = themeStore.current
        return view
    }

    func updateUIView(_ uiView: TouchTrackingSCNView, context: Context) {
        context.coordinator.mirrorCamera?.setActive(cameraEnabled)
        if context.coordinator.lastResetToken != runtime.resetToken {
            context.coordinator.lastResetToken = runtime.resetToken
            // Eddie, Sept 8: reset() mutates a good double-digit count
            // of @Published properties on TapNavigationController in
            // one go (transientMessage, collectedObjects,
            // viewedFloorMapCoords, elevatorInUse, ...) -- doing that
            // SYNCHRONOUSLY, from inside updateUIView, is SwiftUI
            // state mutating during a view update pass, which is
            // exactly what "Publishing changes from within view
            // updates is not allowed" is warning about -- matches the
            // flakiness/freeze seen right after mashing the new reset
            // button a few times in a row. Deferring to the next
            // runloop tick is the standard fix for this, same idea
            // already used for navBridge.controller in makeUIView
            // below.
            DispatchQueue.main.async {
                context.coordinator.movementController?.reset()
                context.coordinator.navigationController?.reset()
            }
        }
        if context.coordinator.lastTheme != themeStore.current {
            context.coordinator.lastTheme = themeStore.current
            context.coordinator.applyTheme(themeStore.current)
        }
    }

    static func dismantleUIView(_ uiView: TouchTrackingSCNView, coordinator: Coordinator) {
        coordinator.mirrorCamera?.setActive(false)
        uiView.delegate = nil
        uiView.isPlaying = false
    }

    final class Coordinator: NSObject {
        var mirrorCamera: MirrorCamera?
        var movementController: MovementController?
        var navigationController: TapNavigationController?
        var lastResetToken = 0
        /// Swapping a material's texture in place (no scene rebuild) is
        /// what lets the theme button change the hallway's look
        /// instantly without resetting position or navigation state.
        /// Floor/ceiling are still one material shared by every cell of
        /// that kind. Walls are one material PER SEGMENT (not shared)
        /// so My Photos can put a different picture on each — see
        /// HallwayScene.build(fromMaze:). The bundled tiled themes
        /// (brick, cave, etc.) still put the SAME image on every wall
        /// entry, so nothing looks different for those.
        var wallMaterials: [SCNMaterial] = []
        var floorMaterial: SCNMaterial?
        var ceilingMaterial: SCNMaterial?
        var lastTheme: HallwayTheme = .brick

        // Drag-controlled left/right turning: how many points of
        // horizontal drag equal one full 90-degree turn. Purely a feel
        // constant — smaller means a shorter drag commits a turn,
        // larger means a longer, more deliberate one.
        private let dragRotateDistance: CGFloat = 140

        // Ticks while a long-press-forward is held -- see
        // handleLongPressForward below. nil whenever nothing's held.
        private var forwardHoldTimer: Timer?

        deinit {
            forwardHoldTimer?.invalidate()
        }

        // A tap anywhere on screen still means "walk forward" --
        // EXCEPT when the tap actually lands on a destination's steel shutter
        // right in front of you, in which case it's the door asking to
        // be opened instead. Eddie, Sept 5: "i think it should wait for
        // you to tap the steel door before it slides up."
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let controller = navigationController else { return }
            if let view = gesture.view as? SCNView {
                let location = gesture.location(in: view)
                let hits = view.hitTest(location, options: nil)
                if let roomCoord = hits.compactMap({ controller.roomDoorCoordinate(for: $0.node) }).first {
                    controller.deliverMail(at: roomCoord)
                    return
                }
                if let doorCoord = hits.compactMap({ controller.destinationCoordinate(for: $0.node) }).first {
                    navLog("tap hit destination door at \(doorCoord)")
                    controller.openDestinationDoor(at: doorCoord)
                    return
                }
                if hits.contains(where: { controller.isElevatorDoor($0.node) }) {
                    navLog("tap hit elevator door")
                    controller.openElevator()
                    return
                }
                if hits.contains(where: { controller.isFloorMapNode($0.node) }) {
                    return // Wall maps are read in place; no pop-up or movement.
                }
            }
            navLog("tap")
            controller.advance()
        }

        // One move per completed pinch, with a dead zone for accidental motion.
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .ended else { return }
            if gesture.scale >= 1.15 {
                navigationController?.pinchForward()
            } else if gesture.scale <= 0.85 {
                navigationController?.stepBackward()
            }
        }

        @objc func handleTwoFingerTap() {
            navLog("two-finger tap (turn around)")
            guard let controller = navigationController else { return }
            controller.rotate(toward: controller.facing.opposite)
        }

        @objc func handlePanRotate(_ gesture: UIPanGestureRecognizer) {
            guard let controller = navigationController, let view = gesture.view else { return }
            // Positive translation.x (finger moving left-to-right) is
            // "swipe right," which Eddie's spec pivots LEFT — matches
            // Direction's yaw convention where turning left is always
            // a positive angle change regardless of current facing.
            let fraction = Double(gesture.translation(in: view).x / dragRotateDistance)
            switch gesture.state {
            case .began:
                navLog("pan rotate began")
                controller.beginDragRotate()
            case .changed:
                controller.updateDragRotate(fraction: fraction)
            case .ended, .cancelled, .failed:
                navLog("pan rotate ended, fraction=\(String(format: "%.2f", fraction))")
                controller.endDragRotate(fraction: fraction)
            default:
                break
            }
        }

        @objc func handleSwipeDown() {
            navLog("swipe down (turn around)")
            guard let controller = navigationController else { return }
            controller.rotate(toward: controller.facing.opposite)
        }

        // Poll only while held. The controller advances straight or pivots
        // around an unambiguous L; a blocked T still waits for a choice.
        // Release stops polling, including during a corner's pivot.
        @objc func handleLongPressForward(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                navLog("long-press forward began")
                navigationController?.advanceWhileHeld()
                forwardHoldTimer?.invalidate()
                let timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    self?.navigationController?.advanceWhileHeld()
                }
                RunLoop.main.add(timer, forMode: .common)
                forwardHoldTimer = timer
            case .ended, .cancelled, .failed:
                navLog("long-press forward ended")
                forwardHoldTimer?.invalidate()
                forwardHoldTimer = nil
            default:
                break
            }
        }

        func applyTheme(_ theme: HallwayTheme) {
            if theme == .myPhotos {
                applyPhotoRollTheme()
                return
            }
            for material in wallMaterials {
                applySurface(material, imageName: theme.wallImageName, fallbackColor: HallwayScene.wallFallbackColor)
            }
            applySurface(floorMaterial, imageName: theme.floorImageName, fallbackColor: HallwayScene.floorFallbackColor)
            applySurface(ceilingMaterial, imageName: theme.ceilingImageName, fallbackColor: HallwayScene.ceilingFallbackColor)
        }

        /// A nil imageName (or a missing file) reverts that surface to
        /// its flat fallback color — not just "leave it alone" — so
        /// cycling away from a themed surface (e.g. paisley's ceiling)
        /// back to a theme that doesn't texture it actually clears the
        /// old texture instead of leaving it stuck.
        private func applySurface(_ material: SCNMaterial?, imageName: String?, fallbackColor: UIColor) {
            guard let material else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            if let image = HallwayScene.resolveThemeImage(imageName) {
                material.diffuse.contents = image
                material.diffuse.wrapS = .repeat
                if HallwayScene.isProceduralGradientImage(imageName) {
                    // Same reasoning as HallwayScene's makeSurfaceMaterial:
                    // a smooth gradient shouldn't tile vertically the way
                    // a photo does, or it visibly seams partway up.
                    material.diffuse.wrapT = .clamp
                    material.diffuse.contentsTransform = SCNMatrix4MakeScale(2, 1, 1)
                } else {
                    material.diffuse.wrapT = .repeat
                    material.diffuse.contentsTransform = repeatTransform(for: material)
                }
            } else {
                material.diffuse.contents = fallbackColor
                material.diffuse.contentsTransform = SCNMatrix4Identity
            }
            SCNTransaction.commit()
        }

        /// Most wallMaterials want the standard flat 2x2 tile repeat --
        /// but a floor map's (and a destination chute's) door-frame
        /// border strips (see HallwayScene's addDoorFrame/
        /// stripMaterial) are built at all sorts of smaller physical
        /// sizes and need their OWN, smaller repeat count to keep
        /// brick size constant instead of cramming a full wall's worth
        /// of tiling into a much smaller strip -- exactly the "more
        /// bricks per sq in" Eddie flagged, Sept 5, comparing a wall
        /// with a floor map against an ordinary one. HallwayScene
        /// stashes that scale in the material's own `name` (nothing
        /// else on SCNMaterial holds arbitrary per-instance data)
        /// precisely so a theme cycle can put it straight back instead
        /// of clobbering it with the generic 2x2 every other wall uses.
        private func repeatTransform(for material: SCNMaterial) -> SCNMatrix4 {
            if let name = material.name, name.hasPrefix("wallRepeat:") {
                let parts = name.dropFirst("wallRepeat:".count).split(separator: "x")
                if parts.count == 2, let s = Float(parts[0]), let t = Float(parts[1]) {
                    return SCNMatrix4MakeScale(s, t, 1)
                }
            }
            return SCNMatrix4MakeScale(2, 2, 1)
        }

        /// My Photos — pulls camera-roll photos live (async, permission-
        /// gated) instead of a bundled jpg: a different photo on EACH
        /// wall segment (cycling through however many came back if
        /// there are more walls than photos — see
        /// PhotoRollProvider.maxPoolSize), plus one more for the
        /// ceiling. One photo per surface (no tiling — this is a
        /// picture, not a pattern). Leaves whatever's currently showing
        /// alone if access is denied or there are no photos, rather
        /// than flashing to a blank fallback color.
        private func applyPhotoRollTheme() {
            let needed = wallMaterials.count + 1
            PhotoRollProvider.shared.recentImages(count: needed) { [weak self] images in
                guard let self, !images.isEmpty else { return }
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.3

                var nextIndex = 0
                func nextImage() -> UIImage {
                    let image = images[nextIndex % images.count]
                    nextIndex += 1
                    return image
                }
                func apply(_ material: SCNMaterial) {
                    material.diffuse.contents = nextImage()
                    material.diffuse.wrapS = .clamp
                    material.diffuse.wrapT = .clamp
                    material.diffuse.contentsTransform = SCNMatrix4Identity
                }

                for material in self.wallMaterials { apply(material) }
                if let ceilingMaterial = self.ceilingMaterial { apply(ceilingMaterial) }

                SCNTransaction.commit()
            }
        }
    }
}

#Preview {
    ContentView()
}
