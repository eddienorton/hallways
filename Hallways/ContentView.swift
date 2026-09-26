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
import ARKit

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
    @Published var scenePrepared = false
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
    var pendingElevatorArtwork: [String: Any] = [:]

    // Eddie, Sept 16 (remove automatic step-out): true from the
    // instant EITHER kind of elevator ride arrives (set by onReachedEnd
    // for a passive ride, or onElevatorArrivedControlled for a
    // player-controlled one) until the very next HallwaySceneView
    // build -- the brand-new destination floor -- consumes and clears
    // it, once, by calling TapNavigationController.
    // presentArrivalInsideElevator(preservedYaw:). This is what tells
    // that build "this floor was just reached by elevator, present the
    // player standing inside it with the doors open" instead of the
    // normal default spawn. The one persistent object that survives
    // the full scene teardown/rebuild a floor change triggers, so it's
    // the only place this kind of one-shot, cross-rebuild handoff can
    // live.
    @Published var pendingElevatorArrival = false

    // Eddie, Sept 16 (tap the inside of the Floor 1 entrance doors to
    // return to the opening screen): set true by Coordinator.handleTap
    // when it hit-tests floorOneEntranceBack; consumed once by
    // ContentView's own onChange below, which does exactly what the
    // existing Reset button already does (switch to floor 1, request a
    // navigation reset, fade the intro screen back in) -- reusing that
    // same opening/exterior state and transition rather than building a
    // second one.
    @Published var requestReturnToOpening = false

    // Eddie, Sept 16 (atomic arrival presentation): true only once the
    // destination floor's own makeUIView build has fully run --
    // HallwayScene.build, TapNavigationController construction, AND
    // presentArrivalInsideElevator -- so its camera/doors are sitting
    // in the exact canonical arrival state, not still holding the raw
    // default spawn (cell center, facing south) that HallwayScene.build
    // always produces first. ElevatorCurtainOverlay's own open-the-
    // curtain trigger below now waits on this instead of firing on a
    // blind fixed delay -- see that onChange handler's own comment for
    // why a fixed delay alone let the curtain start sliding open, and
    // expose the not-yet-repositioned scene through its widening gap,
    // whenever SwiftUI's own async rebuild of the destination floor
    // hadn't caught up yet. Reset to false the instant a NEW arrival
    // begins (onReachedEnd / onElevatorArrivedControlled, alongside
    // pendingElevatorArrival), so a stale `true` left over from the
    // PREVIOUS floor's arrival can never let a later curtain skip the
    // wait.
    @Published var arrivalSceneReady = false

    // The camera's exact yaw (radians) at the instant a PLAYER-
    // CONTROLLED ride arrived -- nil for a passive ride, meaning
    // presentArrivalInsideElevator falls back to the natural "facing
    // the doors" default orientation instead. Consumed and cleared
    // alongside pendingElevatorArrival above, same one-shot handoff.
    @Published var pendingArrivalYaw: Double?

    // Eddie, Sept 16 (spatially-truthful controlled arrival): set
    // alongside pendingElevatorArrival by BOTH onReachedEnd (false)
    // and onElevatorArrivedControlled (true), and read afterward by
    // ElevatorCurtainOverlay to decide how to present this specific
    // arrival -- a passive one keeps the proven door-shaped
    // curtain/snapshot presentation (the camera's always dead-on the
    // real doorway for that path), while a controlled one uses a
    // plain, non-door-shaped fade instead and calls
    // TapNavigationController.playControlledArrivalDoorOpen() once it
    // starts revealing, so the real 3D doors animate open at their
    // real location instead of a screen-centered effect pretending to
    // be them. Not simply inferred from doorSnapshot == nil (which
    // happens to always be true for a controlled ride today) because
    // that's an incidental side effect of a DIFFERENT feature, not a
    // documented contract -- this is explicit.
    @Published var arrivalWasControlled = false
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
    @StateObject private var decorator = DecoratorState()
    @StateObject private var mirrorComments = MirrorCommentState()
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

    // Eddie, Sept 16 (Floor 1 intro walk, once): "Hallways introduces
    // itself once. After that, it assumes the player has learned the
    // lobby and trusts them to navigate it normally." Same @AppStorage
    // (persists across launches) shape as hasSeenNavGestureHint just
    // above.
    //
    // Eddie, Sept 17: no longer a one-time gate -- the ceremonial
    // front-door-to-elevator walk now happens on EVERY front-door
    // entrance, not just the first ever. This flag is still written
    // (see the IntroScreenView onEnter closure below) but nothing
    // reads it to decide whether the walk happens anymore. Left in
    // place rather than removed -- persisted first-run/resume state
    // is a separate future task, not part of this change.
    @AppStorage("hasCompletedInitialEntrance") private var hasCompletedInitialEntrance = false

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
            HallwaySceneView(tuning: tuning, runtime: runtime, mazeStore: mazeStore, navBridge: navBridge, themeStore: themeStore, decorator: decorator, mirrorComments: mirrorComments, cameraEnabled: scenePhase == .active && !showGridEditor && !showIntroScreen, hasCompletedInitialEntrance: hasCompletedInitialEntrance)
                .id(sceneVersion)
                .ignoresSafeArea()
                // Eddie, Sept 16 (entrance-door tap -> opening screen):
                // same 3 actions the existing Reset button already
                // performs below (switch to floor 1 -- a no-op here
                // since we're already there --, request a navigation
                // reset, fade the intro screen back in), just triggered
                // by NavigationBridge's one-shot flag instead of a
                // button tap. No new opening/exterior state or
                // transition -- this reuses exactly what's already
                // there.
                .onChange(of: navBridge.requestReturnToOpening) { _, value in
                    guard value else { return }
                    navBridge.requestReturnToOpening = false
                    navLog("[LIGHTBUILD] rebuild trigger: entrance-door tap (return to opening) -- leaving floor \(mazeStore.currentMazeID), switching to floor 1")
                    mazeStore.switchTo(id: 1)
                    runtime.requestReset()
                    withAnimation(.easeOut(duration: 0.3)) {
                        showIntroScreen = true
                    }
                }
                // Eddie, Sept 18: street/city ambience for the
                // building-exterior opening screen. Starts whenever the
                // intro is back up (cold launch -- handled by onAppear
                // below since showIntroScreen already starts true -- or
                // any return-to-opening: the Reset button or tapping
                // the inside of the entrance doors), and fades out in
                // the IntroScreenView onEnter closure below the moment
                // the player steps inside.
                .onChange(of: showIntroScreen) { _, shown in
                    if shown { SoundEffects.startStreetAudio() }
                }
                // Cold launch: showIntroScreen already starts true, so
                // the onChange above can't fire -- start the street
                // loop here instead (harmless double-start if both fire,
                // since startStreetAudio rewinds to 0 anyway).
                .onAppear {
                    if showIntroScreen { SoundEffects.startStreetAudio() }
                }

            if let navController = navBridge.controller {
                NavigationOverlay(controller: navController)
                MirrorCommentOverlay(controller: navController, state: mirrorComments, mirrors: mazeStore.mirrors,
                    gameplayActive: scenePhase == .active && !showGridEditor && !showIntroScreen)
                    .zIndex(10)
                HallwaySceneView.PhotoBoothOverlayHost(controller: navController)
                    .zIndex(20)
                TicTacToeOverlayHost(controller: navController)
                    .zIndex(25)
                ShellGameOverlayHost(controller: navController)
                    .zIndex(26)
                RockPaperScissorsOverlayHost(controller: navController)
                    .zIndex(27)
                HigherLowerOverlayHost(controller: navController)
                    .zIndex(28)
                FiveCardDrawOverlayHost(controller: navController)
                    .zIndex(29)
                SimonOverlayHost(controller: navController)
                    .zIndex(31)
                HangmanOverlayHost(controller: navController)
                    .zIndex(32)
                ConnectFourOverlayHost(controller: navController)
                    .zIndex(33)
                CheckersOverlayHost(controller: navController)
                    .zIndex(34)
                WoidleOverlayHost(controller: navController)
                    .zIndex(35)
                // Sept 20 (bugfix): moved here from a direct
                // .confirmationDialog/.sheet chain on ContentView's own
                // body, which read navBridge.controller?.activePictureMenu
                // in a Binding get: closure -- that never re-evaluated
                // when activePictureMenu changed, because ContentView
                // only holds `navBridge` (a NavigationBridge) as its
                // @StateObject; navBridge's own @Published var controller
                // only refires SwiftUI when the CONTROLLER REFERENCE
                // itself is reassigned, not when a @Published property
                // *inside* that controller mutates. Every other menu here
                // (TicTacToeOverlayHost, ShellGameOverlayHost, etc.) sidesteps
                // that by holding the controller as its OWN @ObservedObject,
                // which is exactly why tapping a picture did nothing: the
                // state was being set correctly, SwiftUI just never knew to
                // look again. PictureChangeMenuHost (PictureChangeMenu.swift)
                // follows that same @ObservedObject pattern.
                // Sept 20 (picture-teleport fix): no longer passed a
                // scene-resync closure -- a picture change updates its
                // material in place (see Coordinator.
                // applyLivePictureSelection, driven by updateUIView),
                // never touches sceneVersion, and so never rebuilds
                // the scene or moves the player. See PictureChangeMenuHost's
                // own doc comment.
                PictureChangeMenuHost(controller: navController, mazeStore: mazeStore)
                // Sept 26 (intro-HUD leak fix): DECORATE and the
                // handheld mini-map are gameplay/authoring controls
                // that must never appear while the intro screen is up.
                // This used to rely entirely on IntroScreenView's
                // zIndex painting over them, which silently broke once
                // later overlays (the card-game hosts, this pair)
                // picked zIndex values higher than the intro's --
                // gating them here, at the source, on showIntroScreen
                // itself means they are simply never built while the
                // intro is showing, independent of any zIndex. Grouped
                // in one condition since both belong to the same
                // "must not appear on the intro" set; PlayerSettingsButton
                // wasn't reported affected and isn't part of that set,
                // so it stays outside this gate, unchanged.
                if !showIntroScreen {
                    DecoratorOverlay(state: decorator, store: mazeStore)
                        .zIndex(36)
                    if mazeStore.currentMazeID != 1 {
                        HandheldMapOverlay(controller: navController)
                            .id(ObjectIdentifier(navController))
                            .zIndex(30)
                    }
                }
                PlayerSettingsButton()
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
                    IntroScreenView(sceneReady: navBridge.scenePrepared) {
                        // Eddie, Sept 18: the street ambience ends when
                        // the player enters the building and the
                        // entrance is behind them -- which is exactly
                        // this moment (intro dismissed, ceremonial walk
                        // begins); the door is a static fixture behind
                        // spawn, so there's no later "door closes"
                        // event to hang it on. 0.8s fade, then silence
                        // until the next opening screen.
                        SoundEffects.stopStreetAudio()
                        withAnimation(.easeOut(duration: 0.5)) {
                            showIntroScreen = false
                        }
                    if mazeStore.currentMazeID == 1 {
                        // The special uninterrupted intro walk -- Eddie,
                        // Sept 17: no longer first-entrance-only. EVERY
                        // front-door entrance (this IntroScreenView
                        // closing while on floor 1 -- cold launch,
                        // walking out the front doors and back in via
                        // NavigationBridge.requestReturnToOpening, or
                        // the dev Reset button) performs this same
                        // ceremonial walk, every time. Elevator arrivals
                        // never show this intro screen at all, so they
                        // stay completely untouched by this. The two
                        // hasCompletedInitialEntrance writes below no
                        // longer gate anything (see its declaration
                        // above) -- kept as-is since that persisted flag
                        // is a separate future resume/persistence task.
                        navBridge.controller?.advance(source: "CEREMONIAL")
                        hasCompletedInitialEntrance = true
                        navBridge.controller?.hasCompletedInitialEntrance = true
                    }
                }
                .transition(.opacity)
                .zIndex(10)
            }

            VStack {
                HStack(spacing: 8) {
                    moneyHUD
                    // Sept 26 (intro-HUD leak fix): mission-progress
                    // pills (e.g. "Painted 0/51") must not render on the
                    // intro screen either -- same gate as DecoratorOverlay/
                    // HandheldMapOverlay above.
                    if let controller = navBridge.controller, !showIntroScreen {
                        CarriedItemsPill(controller: controller)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            navLog("[LIGHTBUILD] rebuild trigger: Reset/\"Start From Beginning\" button pressed -- leaving floor \(mazeStore.currentMazeID), switching to floor 1")
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
        .onChange(of: showGridEditor) { showing in
            if showing { decorator.enabled = false }
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
                navLog("[LIGHTBUILD] rebuild trigger: Grid Editor dismissed with changes -- floor \(mazeStore.currentMazeID), sceneVersion \(sceneVersion)->\(mazeStore.version) -- this bump forces HallwaySceneView's .id() to change, which discards the current TouchTrackingSCNView + Coordinator and calls makeUIView fresh")
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
            navLog("[LIGHTBUILD] rebuild trigger: mazeStore.currentMazeID changed -> \(mazeStore.currentMazeID) (elevator arrival or grid-editor floor nav) -- sceneVersion \(sceneVersion)->\(mazeStore.version) -- this bump forces HallwaySceneView's .id() to change, which discards the current TouchTrackingSCNView + Coordinator and calls makeUIView fresh")
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

/// Status overlay: a transient message line, and a "Dead end" label
/// when you've backed into one, plus the FLOOR N pill at the bottom.
/// The carried-objects strip no longer lives here -- it moved up into
/// the top HUD row (see CarriedItemsPill), Sept 25. Used to
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
            Text(controller.floorLabel)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.62), in: Capsule())
                .padding(.top, 4)
                .accessibilityIdentifier("gameplayFloorLabel")
        }
        // Sept 24 pass per Eddie (accepted on device): this pill has
        // ONE fixed position -- bottom edge about 8pt above the
        // PHYSICAL bottom edge of the screen -- and it never moves for
        // map state. The outer ZStack here respects the safe area (only
        // the SceneKit view inside ignores it), so without the line
        // below this overlay's layout bottom was the safe-area bottom
        // and the pill floated ~34-42pt above the real screen edge
        // (the home-indicator inset riding under it). Ignoring the
        // bottom safe area makes the pill's frame reach the physical
        // bottom, so the 8pt padding below is measured from the actual
        // screen edge. Same shared constant as the map's anchor math,
        // which is untouched.
//        .ignoresSafeArea(edges: .bottom)
        .padding(.bottom, HandheldMapGeometry.hudPillToSafeGap)
        .offset(y: 30)
      
        .animation(.easeInOut(duration: 0.2), value: controller.transientMessage)
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

/// Sept 25 (HUD row fix): the carried/collected-objects pill that now
/// lives in the TOP HUD row, between the cash pill (left) and the
/// restart/map buttons (right). Moved here out of NavigationOverlay's
/// old top-of-overlay strip, which stretched almost full width thanks to
/// `.fixedSize(horizontal: false)` on a horizontal ScrollView and
/// overlapped the orange Decorate controls. This pill is wrapped in
/// `.fixedSize()` at the call site so it hugs its contents (a compact
/// black pill, internal padding included) instead of eating the whole
/// row. Same "separate @ObservedObject-holding view" reason as
/// NavigationOverlay: ContentView.body never sees TapNavigationController's
/// own @Published properties change, only navBridge.controller's identity.
private struct CarriedItemsPill: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        if !controller.collectedObjects.isEmpty || !controller.carriedMail.isEmpty || controller.paintProgress != nil || controller.carryingExtinguisher {
            HStack(spacing: 8) {
                ForEach(Array(controller.collectedObjects.enumerated()), id: \.offset) { _, kind in
                    Text(kind.displayEmoji).font(.system(size: 22))
                }
                if let progress = controller.paintProgress {
                    Text(progress).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
                if controller.carryingExtinguisher {
                    Label("Extinguisher", systemImage: "fire.extinguisher")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
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
            .background(Color.black.opacity(0.7), in: Capsule())
            .fixedSize()
        }
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
                if navBridge.arrivalWasControlled {
                    // Hold the actual outgoing view across scene construction.
                    // Never substitute door-colored artwork for a wall the player chose.
                    if let snapshot = navBridge.doorSnapshot {
                        Image(uiImage: snapshot)
                            .resizable()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .opacity(1 - openFraction)
                            .allowsHitTesting(false)
                    }
                } else {
                    HStack(spacing: 0) {
                        doorPanel(fullWidth: geo.size.width, halfWidth: geo.size.width / 2, height: geo.size.height, snapshot: navBridge.doorSnapshot, cropAlignment: .leading, seamAtTrailingEdge: true)
                            .offset(x: -geo.size.width / 2 * openFraction)
                        doorPanel(fullWidth: geo.size.width, halfWidth: geo.size.width / 2, height: geo.size.height, snapshot: navBridge.doorSnapshot, cropAlignment: .trailing, seamAtTrailingEdge: false)
                            .offset(x: geo.size.width / 2 * openFraction)
                    }
                    .allowsHitTesting(false)
                }
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
            // TEMPORARY DIAGNOSTIC (Eddie, Sept 16)
            navLog("[ARRIVALDIAG] curtain floorTransitionRequested received t=\(String(format: "%.4f", Date().timeIntervalSince1970)) -- curtain now FULLY CLOSED (openFraction=0, visible=true)")
            // A brief beat so mazeStore.advanceToNextMaze() (called by
            // the controller right alongside this same event) actually
            // swaps in and settles behind this fully-closed curtain
            // before it starts sliding open -- otherwise the open
            // animation would start revealing a stale frame of the OLD
            // floor for an instant.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                SoundEffects.playElevatorArrival()
                navLog("[ARRIVALDIAG] arrival sound played t=\(String(format: "%.4f", Date().timeIntervalSince1970))")
                DispatchQueue.main.asyncAfter(deadline: .now() + SoundEffects.elevatorDoorOpeningDelay) {
                    // Eddie, Sept 16 (atomic arrival presentation):
                    // this fixed 0.2s + elevatorDoorOpeningDelay beat
                    // was always just a GUESS at how long
                    // mazeStore.advanceToNextMaze() takes to actually
                    // swap in and settle -- true almost all the time,
                    // but physical testing caught the real exception:
                    // a first-time-built floor (uncompiled shaders/
                    // textures) can still be mid-construction when
                    // this fires, so the curtain started sliding open
                    // over a scene that hadn't reached its canonical
                    // arrival state yet -- a raw default camera pose,
                    // then whatever implicit animation carried it from
                    // there to the real one, visibly, through the
                    // widening gap. openWhenSceneReady() below still
                    // fires the arrival ding-dong and starts checking
                    // at this exact same instant (unchanged timing for
                    // the overwhelmingly common case where the
                    // destination floor was already ready), but no
                    // longer just assumes readiness -- it polls
                    // navBridge.arrivalSceneReady (set the instant
                    // presentArrivalInsideElevator actually finishes,
                    // see NavigationBridge.arrivalSceneReady) and only
                    // stops the music / starts the open animation once
                    // that's true, checking again on a short interval
                    // otherwise. The curtain stays fully closed for
                    // however much longer that takes -- nothing behind
                    // it is visible either way.
                    // TEMPORARY DIAGNOSTIC (Eddie, Sept 16): counts
                    // how many 0.03s polls it actually took, so the
                    // console shows whether the destination floor was
                    // already ready (pollCount stays 0) or the wait
                    // genuinely engaged (pollCount > 0).
                    var arrivalDiagPollCount = 0
                    func openWhenSceneReady() {
                        guard navBridge.arrivalSceneReady else {
                            if arrivalDiagPollCount == 0 {
                                navLog("[ARRIVALDIAG] curtain open gate NOT READY yet t=\(String(format: "%.4f", Date().timeIntervalSince1970)) -- polling")
                            }
                            arrivalDiagPollCount += 1
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                                openWhenSceneReady()
                            }
                            return
                        }
                        navLog("[ARRIVALDIAG] curtain open gate READY t=\(String(format: "%.4f", Date().timeIntervalSince1970)) pollCount=\(arrivalDiagPollCount) -- stopping music, starting open animation")
                        // Sept 14 (Eddie): "keep the elevator music playing
                        // continuously while the doors remain closed... stop
                        // it at the moment the doors START to open." Moved
                        // here from TapNavigationController.playElevatorRide
                        // (previously stopped right after the 180 pivot) --
                        // this is the exact instant the doors begin sliding
                        // apart, right after the existing arrival ding-dong
                        // above; that ding-dong's own timing is untouched.
                        SoundEffects.stopElevatorMusic()
                        navBridge.controller?.playArrivalLightWash(openingDuration: navBridge.arrivalWasControlled ? 1.6 : 1.0)
                        // Eddie, Sept 16 (spatially-truthful controlled
                        // arrival): the instant this fade starts
                        // revealing a controlled arrival, tell the
                        // (brand new, already-built) destination
                        // controller to actually animate its real 3D
                        // doors open -- see playControlledArrivalDoorOpen()'s
                        // own comment. No-op for a passive arrival,
                        // whose doors were already opened, instantly,
                        // back in presentArrivalInsideElevator.
                        if navBridge.arrivalWasControlled {
                            navBridge.controller?.playControlledArrivalDoorOpen()
                        }
                        withAnimation(.easeInOut(duration: 1.0)) {
                            openFraction = 1
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                            visible = false
                            navLog("[ARRIVALDIAG] curtain visible = false t=\(String(format: "%.4f", Date().timeIntervalSince1970)) -- transition presentation complete")
                        }
                    }
                    openWhenSceneReady()
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
/// BuildingIntro.jpg  the same bundled-file way WallTheme's textures do
/// (Bundle.main.path(forResource:ofType:) -> UIImage(contentsOfFile:))
/// rather than through Assets.xcassets, so swapping in Eddie's real
/// building photo later is just replacing this one file in the project
/// folder -- no asset catalog entry to touch.
private struct IntroScreenView: View {
    let sceneReady: Bool
    @State private var audioReady = false
    // Eddie, Sept 17 (startup permission gate v2): both resolved
    // locally, in sequence, by the .task below -- Photos first, then
    // Camera chained off its completion (PhotoRollProvider.
    // resolveAuthorization / MirrorCamera.resolveAuthorization).
    // "Resolved" means the user answered (or the OS already knew the
    // answer from a prior run); it does not mean granted.
    @State private var photosReady = false
    @State private var cameraReady = false
    @State private var entryRequested = false
    // Eddie, Sept 17: a second, independent guard used only by the tap
    // handler below -- see its comment for why this is deliberately
    // NOT folded into the same queue/auto-enter behavior `ready` gets.
    private var permissionsPreflightComplete: Bool { photosReady && cameraReady }
    private var ready: Bool { sceneReady && audioReady && permissionsPreflightComplete }
    let onEnter: () -> Void

    private var buildingImage: UIImage? {
        // Sept 26 (intro/lobby resource organization): BuildingIntro.jpg
        // now lives in Hallways-Assets/intro, a folder reference bundled
        // as the "intro" subdirectory -- the exact same mechanism
        // Hallways-Assets/textures/hallway already uses and that is
        // physically verified working. Tried first, then falls through
        // to the original flat lookup for resilience (same defensive
        // shape HallwayScene.resolveThemeImage already uses).
        if let url = Bundle.main.url(forResource: "BuildingIntro", withExtension: "jpg", subdirectory: "intro"),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        guard let path = Bundle.main.path(forResource: "BuildingIntro", ofType: "jpg") else { return nil }
        return UIImage(contentsOfFile: path)
    }

    var body: some View {
        ZStack {
            if let buildingImage {
                // Sept 14 fix: scaledToFill() alone has no explicit
                // .frame(), so its enlarged (overflowing) layout size
                // was being resolved through nested ZStack sizing
                // negotiation instead of a known, symmetric rect --
                // GeometryReader pins the image to the screen's exact
                // size so the crop is deterministically centered (the
                // source image's center always lands on the screen's
                // horizontal and vertical center), then .clipped()
                // trims the aspect-fill overflow to that same rect.
                GeometryReader { geo in
                    Image(uiImage: buildingImage)
                        .resizable()
                        .scaledToFill()
                        // Sept 14 optical nudge (Eddie): the centering
                        // math is correct, but the source artwork's own
                        // door seam/sign sit slightly right of the
                        // photo's true center -- offset is applied to
                        // the image BEFORE the frame that defines the
                        // clip rect, so it nudges the rendered artwork
                        // left within the still-centered, still-full-
                        // screen frame below, rather than moving that
                        // frame (or anything clipped=false-anchored to
                        // it) itself.
                        .offset(x: -8)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                        .clipped()
                }
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
                // Sept 14 (Eddie): dropped the redundant "HALLWAYS"
                // title text -- the new intro artwork already has the
                // building's HALLWAYS sign over the door, so this
                // white on-screen title was duplicating it.
                Text("Tap to walk. Swipe to turn. Drag up or down to scout the hallway. Head for the elevator.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 32)
                    .offset(y: 32)
                // Sept 14 (Eddie): +32pt here to push the enter
                // capsule and copyright (rigidly spaced below it) down
                // 32pt, without moving the instructional text above.
                Spacer().frame(height: 68)
                Text(ready ? "Tap anywhere to enter" : "Preparing your hallway…")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .offset(y: 24)
                Spacer().frame(height: 28)
                Text("© 2026 Edward Brayman. All rights reserved.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 24)
                    .offset(y: 24)
            }

            // Eddie, Sept 15 (opening-screen polish): the spinner used
            // to live INSIDE the VStack above, as a conditionally-
            // present child ("if !ready { ProgressView()... }"). That
            // VStack is bottom-anchored by a single leading Spacer(),
            // which absorbs whatever vertical space the VStack's fixed
            // content doesn't use -- so when the spinner mounted or
            // unmounted, it changed the VStack's total fixed-content
            // height, which changed how much space that Spacer
            // absorbed, which shifted every sibling below it
            // (instructional text, button, copyright) up or down. That's
            // the exact "instructional text is higher during loading"
            // jump Eddie reported. Moving the spinner here, as a direct
            // ZStack sibling of the VStack instead of a child inside it,
            // removes it from that layout computation entirely -- it no
            // longer affects the VStack's height or the Spacer's math at
            // all. The ZStack's own size is already pinned full-screen by
            // the background image/gradient, and ZStack centers its
            // children by default, so this renders as a true overlay
            // centered on the full screen, contributing zero layout
            // space to anything else. scaleEffect/transition/animation
            // are purely cosmetic (a brief fade) and don't change any of
            // the above.
            if !ready {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.3)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: ready)
            }
        }
        .contentShape(Rectangle())
        .task {
            await SoundEffects.prepareForGameplay()
            TrashPickupArtwork.prepareForGameplay()
            audioReady = true
        }
        // Eddie, Sept 17 (startup permission gate v2): Photos, then
        // Camera chained off ITS completion -- not simultaneous, not
        // triggered by the tap. Each resolveAuthorization call is a
        // no-op passthrough straight to its completion when the OS
        // already knows the answer from an earlier run (no prompt), so
        // an already-determined pair resolves near-instantly here.
        .task {
            PhotoRollProvider.resolveAuthorization {
                photosReady = true
                MirrorCamera.resolveAuthorization {
                    cameraReady = true
                }
            }
        }
        .onChange(of: ready) { _, value in
            if value && entryRequested { onEnter() }
        }
        .onTapGesture {
            // Eddie, Sept 17: independent of `ready` above on purpose --
            // a tap while either permission is still unresolved is
            // ignored outright, not queued. entryRequested only ever
            // gets set once both permissions are already known, so
            // onChange(of: ready) above can never auto-enter as a side
            // effect of a permission resolving late; the player has to
            // tap again once the preflight is actually done.
            guard permissionsPreflightComplete else { return }
            if ready { onEnter() } else { entryRequested = true }
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
    @ObservedObject var decorator: DecoratorState

    @ObservedObject var mirrorComments: MirrorCommentState
    var cameraEnabled: Bool = true
    var hasCompletedInitialEntrance: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    struct PhotoBoothOverlayHost: View {
        @ObservedObject var controller: TapNavigationController

        var body: some View {
            if let coord = controller.activePhotoBooth {
                PhotoBoothOverlay(controller: controller, coord: coord, prompt: controller.activePhotoBoothPrompt ?? "")
            }
        }
    }

    private struct PhotoBoothOverlay: View {
        @ObservedObject var controller: TapNavigationController
        let coord: GridCoordinate
        let prompt: String

        var body: some View {
            PhotoBoothCameraView(prompt: prompt, controller: controller, coord: coord)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
    }

    private struct PhotoBoothCameraView: UIViewRepresentable {
        let prompt: String
        let controller: TapNavigationController
        let coord: GridCoordinate

        func makeCoordinator() -> Coordinator {
            Coordinator(prompt: prompt, controller: controller, coord: coord)
        }

        func makeUIView(context: Context) -> UIView {
            let view = UIView(frame: .zero)
            guard ARFaceTrackingConfiguration.isSupported else {
                controller.reportPhotoBoothError("This photo station needs a TrueDepth front camera.")
                return view
            }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                context.coordinator.start()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        if granted { context.coordinator.start() }
                        else { controller.reportPhotoBoothError("Camera access is required for employee photo compliance.") }
                    }
                }
            default:
                controller.reportPhotoBoothError("Camera access is disabled. Enable it in Settings to use this station.")
            }
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {}

        static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
            coordinator.stop()
        }

        final class Coordinator: NSObject, ARSessionDelegate {
            let prompt: String
            let controller: TapNavigationController
            let coord: GridCoordinate
            let ciContext = CIContext()
            private let session = ARSession()
            var didCapture = false
            var consecutiveMatches = 0
            private var previewFrameInFlight = false
            private var lastPreviewTime: TimeInterval = 0
            private var stopped = false

            init(prompt: String, controller: TapNavigationController, coord: GridCoordinate) {
                self.prompt = prompt
                self.controller = controller
                self.coord = coord
            }

            func start() {
                guard !stopped, controller.activePhotoBooth == coord else { return }
                let configuration = ARFaceTrackingConfiguration()
                configuration.isLightEstimationEnabled = true
                session.delegateQueue = .main
                session.delegate = self
                session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                navLog("photo booth AR face session started at \(coord)")
            }

            func stop() {
                stopped = true
                session.pause()
                session.delegate = nil
            }

            func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
                guard !stopped, !didCapture, let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }
                controller.reportPhotoBoothFaceTracking(at: coord)
                let shapes = face.blendShapes
                let value: (ARFaceAnchor.BlendShapeLocation) -> Float = { location in
                    (shapes[location] as? NSNumber)?.floatValue ?? 0
                }
                let matched: Bool
                switch prompt {
                case "PLEASE SMILE":
                    matched = (value(.mouthSmileLeft) + value(.mouthSmileRight)) / 2 > 0.52
                case "OPEN YOUR MOUTH":
                    matched = value(.jawOpen) > 0.42
                default:
                    let brows = (value(.browInnerUp) + value(.browOuterUpLeft) + value(.browOuterUpRight)) / 3
                    matched = brows > 0.28
                }
                consecutiveMatches = matched ? consecutiveMatches + 1 : 0
                // Eddie, Sept 13: restores the booth's live on-screen
                // readout -- see updatePhotoBoothLiveExpression's own
                // comment in TapNavigationController.swift for the full
                // trace. This fires on every face-anchor update (i.e.
                // continuously while ARKit is tracking a face), driven
                // by the exact matched/consecutiveMatches values just
                // computed above -- no new detection logic, no changed
                // thresholds, just finally rendering what was already
                // being computed every frame.
                controller.updatePhotoBoothLiveExpression(matched: matched, holding: consecutiveMatches, at: coord)
                guard consecutiveMatches >= 3 else { return }
                guard let frame = session.currentFrame else { return }
                didCapture = true
                let image = image(from: frame)
                session.pause()
                controller.completePhotoBooth(at: coord, image: image)
            }

            func session(_ session: ARSession, didUpdate frame: ARFrame) {
                guard !stopped, !didCapture,
                      controller.activePhotoBooth == coord else { return }
                guard frame.timestamp - lastPreviewTime >= 0.1,
                      !previewFrameInFlight else { return }
                lastPreviewTime = frame.timestamp
                previewFrameInFlight = true
                let image = image(from: frame)
                controller.updatePhotoBoothLiveImage(image, at: coord)
                previewFrameInFlight = false
            }

            private func image(from frame: ARFrame) -> UIImage {
                let source = CIImage(cvPixelBuffer: frame.capturedImage)
                let sourceExtent = source.extent
                let outputSize = CGSize(width: 360, height: 640)
                let normalize = CGAffineTransform(
                    scaleX: 1 / sourceExtent.width,
                    y: 1 / sourceExtent.height
                ).translatedBy(x: -sourceExtent.minX, y: -sourceExtent.minY)
                let displayTransform = frame.displayTransform(
                    for: .portrait,
                    viewportSize: outputSize
                )
                let selfieTransform = CGAffineTransform(translationX: 1, y: 0)
                    .scaledBy(x: -1, y: 1)
                let uprightTransform = CGAffineTransform(translationX: 0, y: 1)
                    .scaledBy(x: 1, y: -1)
                var transformed = source
                    .transformed(by: normalize)
                    // Core Image has a bottom-left origin; AR display transforms use top-left.
                    .transformed(by: uprightTransform)
                    .transformed(by: displayTransform
                        .concatenating(selfieTransform)
                        .concatenating(uprightTransform))
                    .transformed(by: CGAffineTransform(scaleX: outputSize.width, y: outputSize.height))
                let transformedExtent = transformed.extent
                transformed = transformed.transformed(by: CGAffineTransform(
                    translationX: -transformedExtent.minX,
                    y: -transformedExtent.minY
                ))
                let outputExtent = transformed.extent
                guard let cgImage = ciContext.createCGImage(transformed, from: outputExtent) else {
                    return UIImage()
                }
                return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
            }
        }
    }

    func makeUIView(context: Context) -> TouchTrackingSCNView {
        let view = TouchTrackingSCNView()

        // Sept 22 (Eddie: in-process rebuild-lifecycle investigation).
        // Minted ONCE, right at the top of makeUIView, so every
        // checkpoint this SAME rebuild logs below (EARLY / POST /
        // NEXT-RUNLOOP) shares one [LIGHTBUILD #N] number, no matter
        // how deep into this function -- or how much later on the main
        // queue -- that checkpoint actually runs. nextBuildNumber() is
        // process-lifetime and monotonic (see LightingDeterminismCheck.
        // swift), so #1, #2, #3... are stable landmarks across however
        // many rebuilds happen in one run of the app, launch or not.
        // nil (not minted) for the empty-maze prototype branch and for
        // any floor other than 2, matching this tool's existing
        // Floor-2-only scope.
        #if DEBUG
        let lightBuildNumber: Int? = (mazeStore.currentMazeID == 2 && !mazeStore.cells.isEmpty) ? LightingDeterminismCheck.nextBuildNumber() : nil
        if let lightBuildNumber {
            navLog("[LIGHTBUILD #\(lightBuildNumber)] BEGIN makeUIView floor=\(mazeStore.currentMazeID) pendingElevatorArrival=\(navBridge.pendingElevatorArrival) -- a brand-new TouchTrackingSCNView + Coordinator are being constructed from scratch for this rebuild (SwiftUI's .id(sceneVersion) tears down the previous one entirely; see the [LIGHTBUILD] rebuild-trigger lines elsewhere in this file for WHY this rebuild started)")
        }
        #endif

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
            // TEMPORARY DIAGNOSTIC (Eddie, Sept 16 -- elevator arrival
            // visual-transition audit). Remove this whole block (every
            // line tagged [ARRIVALDIAG] in this file and
            // TapNavigationController.swift) once diagnosed.
            let arrivalDiagBuildStart = Date().timeIntervalSince1970
            navLog("[ARRIVALDIAG] makeUIView START t=\(String(format: "%.4f", arrivalDiagBuildStart)) buildingFloor=\(mazeStore.currentMazeID) pendingElevatorArrival=\(navBridge.pendingElevatorArrival) pendingArrivalYaw=\(String(describing: navBridge.pendingArrivalYaw))")
            let start = mazeStore.startCoordinate ?? GridCoordinate(row: 0, col: 0)
            let end = mazeStore.endCoordinate ?? start
            let facing = startingFacing(at: start, cells: mazeStore.cells)
            // Split into two statements (Eddie, Sept 15 build failure after
            // adding the Window Room parameter): Xcode reported "unable to
            // type-check this expression in reasonable time" on this call,
            // with cascading "extra argument"/dynamicMember-wrapper errors at
            // every position -- the classic Swift symptom of a single giant
            // expression that combines a huge (37-argument) function call
            // AND a 23-element tuple-destructuring pattern in one constraint
            // system, not an actual arity/label/type mistake (verified: every
            // label here matches HallwayScene.build(fromMaze:...)'s signature
            // 1:1, same order, no duplicates). Binding the call's result to a
            // single `let` first gives the type checker a fully concrete,
            // already-known type to destructure in a SEPARATE, trivial second
            // statement, instead of solving both at once. No behavior change --
            // same call, same arguments, same resulting bindings below.
            navLog("[ARRIVALDIAG] HallwayScene.build(fromMaze:) START t=\(String(format: "%.4f", Date().timeIntervalSince1970)) floorNumber=\(mazeStore.currentMazeID)")
            let hallwaySceneBuildResult = HallwayScene.build(fromMaze: mazeStore.cells, cellSize: mazeStore.cellSize, wallHeight: mazeStore.wallHeight, objects: mazeStore.objects, destinations: mazeStore.destinations, exitSigns: mazeStore.exitSigns, floorMaps: mazeStore.floorMaps, spotlights: mazeStore.spotlights, missionSigns: mazeStore.missionSigns, pictures: mazeStore.pictures, mirrors: mazeStore.mirrors, wallLights: mazeStore.wallLights, bathroomDoors: mazeStore.bathroomDoors, windowRooms: mazeStore.windowRooms, fires: mazeStore.fires, extinguishers: mazeStore.extinguishers, photoBooths: mazeStore.photoBooths, ticTacToeTerminals: mazeStore.ticTacToeTerminals, shellGameStations: mazeStore.shellGameStations, rockPaperScissorsTerminals: mazeStore.rockPaperScissorsTerminals, higherLowerTerminals: mazeStore.higherLowerTerminals, fiveCardDrawTerminals: mazeStore.fiveCardDrawTerminals, simonTerminals: mazeStore.simonTerminals, hangmanTerminals: mazeStore.hangmanTerminals, connectFourTerminals: mazeStore.connectFourTerminals, checkersTerminals: mazeStore.checkersTerminals, woidleTerminals: mazeStore.woidleTerminals, picturesUseCameraRoll: mazeStore.picturesUseCameraRoll, roomDoors: mazeStore.roomDoors, itemRooms: mazeStore.itemRooms, missionHeading: mazeStore.missionHeading, missionBody: mazeStore.missionBody, missionObjectKind: mazeStore.missionObjectKind, floorNumber: mazeStore.currentMazeID, totalFloors: mazeStore.floorCount, playerStart: start, playerEnd: end, theme: themeStore.current, wallTexture: mazeStore.wallTexture, floorTexture: mazeStore.floorTexture, ceilingTexture: mazeStore.ceilingTexture, elevatorArtwork: navBridge.pendingElevatorArrival ? navBridge.pendingElevatorArtwork : [:], fluorescentLights: mazeStore.fluorescentLights, ceilingVisibleFixture: mazeStore.ceilingVisibleFixture, pictureLights: mazeStore.pictureLights, lightBrightness: mazeStore.lightBrightness, pictureImageSelections: mazeStore.pictureImageSelections, elevatorCabDecoration: mazeStore.elevatorCabDecoration, floorObjectPlacements: mazeStore.floorObjectPlacements)
            navBridge.pendingElevatorArtwork = [:]
            let (scene, cameraNode, _, wallMaterials, floorMaterial, ceilingMaterial, objectNodes, destinationNodes, fireNodes, extinguisherNodes, photoBoothNodes, ticTacToeTerminalNodes, shellGameStationNodes, rockPaperScissorsTerminalNodes, higherLowerTerminalNodes, fiveCardDrawTerminalNodes, simonTerminalNodes, hangmanTerminalNodes, connectFourTerminalNodes, checkersTerminalNodes, woidleTerminalNodes, elevatorDoors, _, floorMapPlaneNodes, pictureMaterials) = hallwaySceneBuildResult
            navLog("[ARRIVALDIAG] HallwayScene.build(fromMaze:) END t=\(String(format: "%.4f", Date().timeIntervalSince1970)) elapsed=\(String(format: "%.4f", Date().timeIntervalSince1970 - arrivalDiagBuildStart))s raw-spawn cameraNode.position=\(cameraNode.position) cameraNode.eulerAngles=\(cameraNode.eulerAngles) elevatorDoors-present=\(elevatorDoors != nil)")
            view.scene = scene
            navLog("[ARRIVALDIAG] view.scene = scene assigned t=\(String(format: "%.4f", Date().timeIntervalSince1970))")
            view.pointOfView = cameraNode
            navLog("[ARRIVALDIAG] view.pointOfView = cameraNode assigned t=\(String(format: "%.4f", Date().timeIntervalSince1970)) cameraNode.position=\(cameraNode.position) cameraNode.eulerAngles=\(cameraNode.eulerAngles)")
            #if DEBUG
            // Sept 22 (Eddie): lighting-determinism instrumentation
            // (see LightingDeterminismCheck.swift) -- the scene is now
            // fully built AND attached to the view, so every
            // fluorescent fixture/light below is in its final,
            // as-rendered MODEL-space state. Floor-2-only per Eddie's
            // request; #if DEBUG-gated, zero effect on Release builds.
            // This is checkpoint 1 of 3 for this rebuild (EARLY) -- see
            // the POST checkpoint near the end of makeUIView and the
            // NEXT-RUNLOOP checkpoint scheduled on DispatchQueue.main
            // below for the other two. NOTE: this checkpoint captures
            // node.position/eulerAngles/rotation/transform (the MODEL),
            // not node.presentation -- if the actual GPU-rendered frame
            // ever diverges from the model (an uncommitted implicit
            // SceneKit animation, for instance), this checkpoint alone
            // cannot see it. Eddie: flagged in the report as a known
            // blind spot, not yet closed.
            if let lightBuildNumber {
                LightingDeterminismCheck.run(scene: scene, floor: mazeStore.currentMazeID, mazeStore: mazeStore, buildNumber: lightBuildNumber, checkpoint: "EARLY (view.scene + view.pointOfView just assigned)")
            }
            #endif
            context.coordinator.wallMaterials = wallMaterials
            context.coordinator.floorMaterial = floorMaterial
            context.coordinator.ceilingMaterial = ceilingMaterial
            context.coordinator.currentFloorNumber = mazeStore.currentMazeID
            // Sept 20 (picture-teleport fix): retained per-picture
            // materials + the selections state at the moment this
            // scene was built, so updateUIView below can tell "the
            // player changed a picture during gameplay" apart from "a
            // brand-new scene was just built with this selection
            // already baked in" and never double-applies the very
            // picture this build already rendered correctly.
            context.coordinator.pictureMaterials = pictureMaterials
            context.coordinator.lastPictureImageSelections = mazeStore.pictureImageSelections
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
            navLog("[ARRIVALDIAG] TapNavigationController(...) about to construct t=\(String(format: "%.4f", Date().timeIntervalSince1970)) cameraNode.position=\(cameraNode.position) cameraNode.eulerAngles=\(cameraNode.eulerAngles)")
            let navController = TapNavigationController(cameraNode: cameraNode, scene: scene, cells: mazeStore.cells, cellSize: mazeStore.cellSize, startCell: start, startFacing: facing, endCell: end, objects: mazeStore.objects, objectNodes: objectNodes, destinations: mazeStore.destinations, destinationNodes: destinationNodes, elevatorLeftDoor: elevatorDoors?.left, elevatorRightDoor: elevatorDoors?.right, elevatorMountDirection: elevatorDoors?.direction, elevatorButtonNodes: elevatorDoors?.buttonNodes ?? [:], floorNumber: mazeStore.currentMazeID, nextFloorNumber: mazeStore.nextMazeID, floorMaps: mazeStore.floorMaps, floorMapPlaneNodes: floorMapPlaneNodes, missionSigns: mazeStore.missionSigns, pictures: Set(mazeStore.pictures.keys), mirrors: mazeStore.mirrors, fires: mazeStore.fires, fireNodes: fireNodes, extinguishers: mazeStore.extinguishers, extinguisherNodes: extinguisherNodes, photoBooths: mazeStore.photoBooths, photoBoothNodes: photoBoothNodes, ticTacToeTerminals: mazeStore.ticTacToeTerminals, ticTacToeTerminalNodes: ticTacToeTerminalNodes, shellGameStations: mazeStore.shellGameStations, shellGameStationNodes: shellGameStationNodes, rockPaperScissorsTerminals: mazeStore.rockPaperScissorsTerminals, rockPaperScissorsTerminalNodes: rockPaperScissorsTerminalNodes, higherLowerTerminals: mazeStore.higherLowerTerminals, higherLowerTerminalNodes: higherLowerTerminalNodes, fiveCardDrawTerminals: mazeStore.fiveCardDrawTerminals, fiveCardDrawTerminalNodes: fiveCardDrawTerminalNodes, simonTerminals: mazeStore.simonTerminals, simonTerminalNodes: simonTerminalNodes, hangmanTerminals: mazeStore.hangmanTerminals, hangmanTerminalNodes: hangmanTerminalNodes, connectFourTerminals: mazeStore.connectFourTerminals, connectFourTerminalNodes: connectFourTerminalNodes, checkersTerminals: mazeStore.checkersTerminals, checkersTerminalNodes: checkersTerminalNodes, woidleTerminals: mazeStore.woidleTerminals, woidleTerminalNodes: woidleTerminalNodes, roomDoors: mazeStore.roomDoors, itemRooms: mazeStore.itemRooms, bathroomDoors: mazeStore.bathroomDoors, windowRooms: mazeStore.windowRooms, missionObjectKind: mazeStore.missionObjectKind, hasCompletedInitialEntrance: hasCompletedInitialEntrance)
            #if DEBUG
            // Sept 22 (Eddie: presentation-vs-model investigation).
            // Hands this rebuild's LIGHTBUILD number (nil unless this
            // is a Floor-2 rebuild) to the freshly-built navController,
            // which is already this view's SCNSceneRendererDelegate --
            // see its own renderer(_:didRenderScene:atTime:) for where
            // this actually fires, once, on the first frame SceneKit
            // truly renders for this scene.
            navController.pendingPresentationCheckBuildNumber = lightBuildNumber
            #endif
            // Eddie, Sept 16 (remove automatic step-out): this build
            // IS an elevator ride's destination floor -- passive or
            // player-controlled -- exactly when
            // navBridge.pendingElevatorArrival is true (set by
            // onReachedEnd or onElevatorArrivedControlled, just below,
            // on the PREVIOUS floor's own build). Consumed and cleared
            // here, once, so it can never leak into a later, unrelated
            // floor load. pendingArrivalYaw is only ever non-nil
            // alongside it, for a controlled ride -- nil means present
            // the normal passive "facing the doors" default instead.
            navLog("[ARRIVALDIAG] pendingElevatorArrival check t=\(String(format: "%.4f", Date().timeIntervalSince1970)) pendingElevatorArrival=\(navBridge.pendingElevatorArrival) pendingArrivalYaw=\(String(describing: navBridge.pendingArrivalYaw))")
            if navBridge.pendingElevatorArrival {
                let preservedYaw = navBridge.pendingArrivalYaw
                navBridge.pendingElevatorArrival = false
                navBridge.pendingArrivalYaw = nil
                navController.presentArrivalInsideElevator(preservedYaw: preservedYaw)
                // Eddie, Sept 16 (atomic arrival presentation): only
                // set once presentArrivalInsideElevator has fully run,
                // synchronously, right above -- by the time this line
                // executes the camera/doors are already sitting in
                // their final canonical arrival state (that call also
                // now disables implicit SceneKit actions on its own
                // property sets -- see its own comment -- so there's no
                // animation left in flight for the curtain to catch
                // mid-transition either). ElevatorCurtainOverlay's
                // onChange handler waits on this flag before it lets
                // openFraction start moving.
                navBridge.arrivalSceneReady = true
                navLog("[ARRIVALDIAG] arrivalSceneReady = true SET t=\(String(format: "%.4f", Date().timeIntervalSince1970)) makeUIView total elapsed=\(String(format: "%.4f", Date().timeIntervalSince1970 - arrivalDiagBuildStart))s")
            }
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
                // TEMPORARY DIAGNOSTIC (Eddie, Sept 16 -- elevator
                // arrival visual-transition audit)
                navLog("[ARRIVALDIAG] onReachedEnd (passive) START t=\(String(format: "%.4f", Date().timeIntervalSince1970)) currentMazeID=\(mazeStore.currentMazeID) nextMazeID=\(String(describing: mazeStore.nextMazeID))")
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
                navBridge.pendingElevatorArtwork = view?.scene.map { HallwayScene.elevatorArtwork(in: $0) } ?? [:]
                // TEMPORARY DIAGNOSTIC (Eddie, Sept 16)
                navLog("[ARRIVALDIAG] onReachedEnd doorSnapshot captured t=\(String(format: "%.4f", Date().timeIntervalSince1970)) snapshot=\(navBridge.doorSnapshot != nil ? "non-nil" : "NIL")")
                // Fired on navBridge itself, not read off the outgoing
                // controller -- see NavigationBridge.floorTransitionRequested.
                navBridge.floorTransitionRequested = TapNavigationController.FloorTransitionEvent()
                navBridge.controller = nil
                // Eddie, Sept 16 (remove automatic step-out): tells the
                // destination floor's own build to present the player
                // standing inside the just-arrived elevator, doors
                // open, rather than the normal default spawn -- see
                // NavigationBridge.pendingElevatorArrival. pendingArrivalYaw
                // stays nil here (a passive ride), so
                // presentArrivalInsideElevator uses its natural
                // "already facing the doors" orientation.
                navBridge.pendingElevatorArrival = true
                // Eddie, Sept 16 (atomic arrival presentation): this
                // arrival hasn't been presented yet -- cleared here so
                // a stale `true` left over from the LAST ride can never
                // let the curtain below skip its wait.
                navBridge.arrivalSceneReady = false
                // Eddie, Sept 16 (spatially-truthful controlled
                // arrival): a passive arrival -- see NavigationBridge.arrivalWasControlled.
                navBridge.arrivalWasControlled = false
                // TEMPORARY DIAGNOSTIC (Eddie, Sept 16)
                navLog("[ARRIVALDIAG] onReachedEnd calling advanceToNextMaze() t=\(String(format: "%.4f", Date().timeIntervalSince1970)) currentMazeID(before)=\(mazeStore.currentMazeID)")
                mazeStore.advanceToNextMaze()
                navLog("[ARRIVALDIAG] onReachedEnd advanceToNextMaze() returned t=\(String(format: "%.4f", Date().timeIntervalSince1970)) currentMazeID(after)=\(mazeStore.currentMazeID)")
            }
            // Controlled arrival keeps a full-frame snapshot (never split into doors)
            // while the destination is constructed with the same displayed artwork.
            navController.onElevatorArrivedControlled = { [weak view, mazeStore, navBridge] yaw in
                navBridge.doorSnapshot = view?.snapshot()
                navBridge.pendingElevatorArtwork = view?.scene.map { HallwayScene.elevatorArtwork(in: $0) } ?? [:]
                navBridge.floorTransitionRequested = TapNavigationController.FloorTransitionEvent()
                navBridge.controller = nil
                navBridge.pendingElevatorArrival = true
                navBridge.pendingArrivalYaw = yaw
                // Eddie, Sept 16 (atomic arrival presentation): same
                // reset as onReachedEnd above -- see that comment.
                navBridge.arrivalSceneReady = false
                // Eddie, Sept 16 (spatially-truthful controlled
                // arrival): a controlled arrival -- see
                // NavigationBridge.arrivalWasControlled.
                navBridge.arrivalWasControlled = true
                mazeStore.advanceToNextMaze()
            }
            view.delegate = navController
            context.coordinator.navigationController = navController
            context.coordinator.navBridge = navBridge
            navController.onHandheldMapOpened = { [weak coordinator = context.coordinator] in
                coordinator?.cancelHeldWalkForMap()
            }

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
                navBridge.scenePrepared = false
                view.prepare([scene]) { _ in
                    DispatchQueue.main.async {
                        guard navBridge.controller === navController else { return }
                        navBridge.scenePrepared = true
                    }
                }

                // Arrival setup is complete. Remain in the cab until an explicit
                // tap/hold; the former delayed advance also triggered manual walk-out.

            }
        }

        view.backgroundColor = .black
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = false // our own touch/tap handling must be the only thing driving the camera
        view.isPlaying = true
        view.rendersContinuously = true

        if let scene = view.scene {
            var surfaces: [MirrorSurfaceTarget] = []
            scene.rootNode.enumerateChildNodes { node, _ in
                if node.name == "mirrorSurface", let material = node.geometry?.firstMaterial {
                    // Eddie, Sept 16 (Floor 1 lobby mirror aspect-fill correction):
                    // pass each surface's true rendered aspect ratio (accounting for
                    // any ancestor node scale, e.g. the lobby mirror's scale.y = 2)
                    // so MirrorCamera can crop the live feed to match instead of
                    // letting SceneKit stretch it onto the scaled plane.
                    let aspect = HallwayScene.mirrorSurfaceAspect(of: node)
                    surfaces.append(MirrorSurfaceTarget(material: material, aspect: aspect))
                }
            }
            if !surfaces.isEmpty {
                context.coordinator.mirrorCamera = MirrorCamera(surfaces: surfaces, comments: mirrorComments)
                context.coordinator.mirrorCamera?.setActive(cameraEnabled)
            }
        }
        context.coordinator.lastResetToken = runtime.resetToken
        context.coordinator.lastTheme = themeStore.current
        context.coordinator.decorator = decorator
        decorator.attach(scene: view.scene, store: mazeStore)
        decorator.canEditCab = { [weak coordinator = context.coordinator] in
            coordinator?.navigationController?.canRotate == true
        }
        decorator.stopWalking = { [weak coordinator = context.coordinator] in
            coordinator?.cancelHeldWalkForMap()
        }
        // Sept 21 (3D Decorator wall authoring): wires DecoratorState's
        // two new live-Picture-ADD callbacks to this same Coordinator,
        // same weak-capture shape as canEditCab/stopWalking just above.
        // currentWallImageName reuses Coordinator's own already-tracked
        // currentFloorNumber/lastTheme rather than capturing mazeStore/
        // themeStore separately.
        decorator.currentWallImageName = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return nil }
            return HallwayScene.effectiveWallImageName(floorNumber: coordinator.currentFloorNumber, theme: coordinator.lastTheme)
        }
        decorator.registerAddedPicture = { [weak coordinator = context.coordinator] coord, direction, material, newWallMaterials in
            coordinator?.pictureMaterials[WallFace(coord: coord, direction: direction)] = material
            coordinator?.wallMaterials.append(contentsOf: newWallMaterials)
            coordinator?.navigationController?.registerPicture(direction, at: coord)
        }
        // Sept 21 (Picture Decorator complete pass): appendWallMaterials
        // is the same "new wall/backing/strip materials this Picture's
        // own construction created get repainted by a later theme
        // cycle too" step registerAddedPicture already does, reused by
        // a live Picture Size change and a live Delete (both of which
        // can create or need to re-create backfill materials but have
        // no picture-registration bookkeeping of their own to do
        // alongside it). unregisterPicture is deletePicture's own
        // reverse of registerAddedPicture.
        decorator.appendWallMaterials = { [weak coordinator = context.coordinator] newWallMaterials in
            coordinator?.wallMaterials.append(contentsOf: newWallMaterials)
        }
        decorator.unregisterPicture = { [weak coordinator = context.coordinator] coord, direction in
            coordinator?.pictureMaterials.removeValue(forKey: WallFace(coord: coord, direction: direction))
            coordinator?.navigationController?.unregisterPicture(direction, at: coord)
        }
        // Sept 21 (Floor Object current-cell authoring): same
        // weak-capture closure shape as every DecoratorState wiring
        // just above -- both read fresh state through `coordinator` at
        // CALL time (not at this assignment's own execution time), so
        // assigning them once here is exactly as safe as
        // canEditCab/registerAddedPicture already are, with no
        // per-update re-sync needed. currentPlayerCell answers "which
        // cell is the player standing in" for DecoratorState.
        // addFloorObject; registerFloorObject hands a newly live-added
        // object straight to TapNavigationController's own bookkeeping,
        // the same way registerAddedPicture already does for a live
        // Picture.
        decorator.currentPlayerCell = { [weak coordinator = context.coordinator] in
            coordinator?.navigationController?.currentCell
        }
        decorator.registerFloorObject = { [weak coordinator = context.coordinator] kind, coord, node in
            coordinator?.navigationController?.registerFloorObject(kind, at: coord, node: node)
        }
        // Sept 21 (current-cell Wall authoring): same shape as
        // currentPlayerCell just above -- DecoratorState.
        // selectWallAtCurrentCell reads this to translate the player's
        // OWN left/right into the absolute Direction its existing wall
        // machinery needs (Direction.left/right, not a new convention).
        decorator.currentPlayerFacing = { [weak coordinator = context.coordinator] in
            coordinator?.navigationController?.facing
        }
        // Sept 25 (Designer wall authoring, live mission-object ADD):
        // the mirror/extinguisher/photo-booth/fire registration closures
        // -- same weak-capture shape as registerAddedPicture above.
        // registerMirrorSurface/unregisterMirrorSurface talk to
        // Coordinator.mirrorCamera (nil-safe: the camera is only created
        // on floors that actually have mirrors); registerMirror/
        // unregisterMirror, registerLiveFire/unregisterLiveFire,
        // registerLiveExtinguisher/unregisterLiveExtinguisher and
        // registerLivePhotoBooth/unregisterLivePhotoBooth all route
        // through TapNavigationController's own register/unregister
        // counterparts so live-authored objects join the real mission
        // bookkeeping immediately (Eddie's Sept 25 direction).
        decorator.registerMirrorSurface = { [weak coordinator = context.coordinator] material, aspect in
            guard let coordinator else { return }
            // Sept 25 (Designer wall authoring): on a floor whose build
            // started with NO mirrors (makeUIView's surfaces scan found
            // none, so coordinator.mirrorCamera was never created), a
            // live-added mirror still needs the live feed -- create the
            // camera lazily here. updateUIView's ongoing
            // mirrorCamera?.setActive(cameraEnabled) pass picks it up on
            // the very next update, so its active state is always right.
            if coordinator.mirrorCamera == nil {
                coordinator.mirrorCamera = MirrorCamera(surfaces: [], comments: mirrorComments)
            }
            coordinator.mirrorCamera?.addSurface(material, aspect: aspect)
        }
        decorator.unregisterMirrorSurface = { [weak coordinator = context.coordinator] material in
            coordinator?.mirrorCamera?.removeSurface(material)
        }
        decorator.registerMirror = { [weak coordinator = context.coordinator] coord in
            coordinator?.navigationController?.registerMirror(at: coord)
        }
        decorator.unregisterMirror = { [weak coordinator = context.coordinator] coord in
            coordinator?.navigationController?.unregisterMirror(at: coord)
        }
        decorator.registerLiveFire = { [weak coordinator = context.coordinator] coord, node in
            coordinator?.navigationController?.registerFire(at: coord, node: node)
        }
        decorator.unregisterLiveFire = { [weak coordinator = context.coordinator] coord in
            coordinator?.navigationController?.unregisterFire(at: coord)
        }
        decorator.registerLiveExtinguisher = { [weak coordinator = context.coordinator] direction, coord, node in
            coordinator?.navigationController?.registerExtinguisher(direction, node: node, at: coord)
        }
        decorator.unregisterLiveExtinguisher = { [weak coordinator = context.coordinator] coord in
            coordinator?.navigationController?.unregisterExtinguisher(at: coord)
        }
        decorator.registerLivePhotoBooth = { [weak coordinator = context.coordinator] direction, coord, node in
            coordinator?.navigationController?.registerPhotoBooth(direction, expression: .smile, node: node, at: coord)
        }
        decorator.unregisterLivePhotoBooth = { [weak coordinator = context.coordinator] coord in
            coordinator?.navigationController?.unregisterPhotoBooth(at: coord)
        }

        // Sept 22 (Eddie: in-process rebuild-lifecycle investigation).
        // Checkpoint 2 of 3 (POST) -- makeUIView is fully done: the
        // TapNavigationController is built and installed as
        // view.delegate, every DecoratorState closure above is wired,
        // gesture recognizers are attached, decorator.attach(scene:
        // store:) has already run (a few lines above the block that
        // built navController -- see its own doc comment: it only sets
        // self.scene/self.store/floor, confirmed not to touch any
        // light). Comparing this against the EARLY checkpoint's
        // fingerprint answers: does anything makeUIView itself does,
        // AFTER attaching the scene to the view, go on to mutate a
        // fluorescent fixture or its Area-light children? (Suspects
        // ruled out by direct code reading so far: decorator.attach,
        // the closures assigned to navController.onReachedEnd/
        // onElevatorArrivedControlled -- registered here but not
        // EXECUTED until a future elevator ride, so irrelevant to
        // THIS rebuild's own POST state.)
        #if DEBUG
        if let lightBuildNumber, let scene = view.scene {
            LightingDeterminismCheck.run(scene: scene, floor: mazeStore.currentMazeID, mazeStore: mazeStore, buildNumber: lightBuildNumber, checkpoint: "POST (makeUIView about to return -- navController installed, Decorator attached, gestures wired)")
        }

        // Checkpoint 3 of 3 (NEXT-RUNLOOP) -- deliberately a SEPARATE
        // async hop from the existing "DispatchQueue.main.async {
        // navBridge.controller = navController; ...; view.prepare(...)
        // }" block a little further up (left completely untouched, per
        // Eddie's "do not remove useful existing diagnostics/behavior"
        // instruction) -- this schedules its own main-queue tick so it
        // runs strictly AFTER makeUIView returns AND after SwiftUI's
        // very next updateUIView pass has had a chance to run (theme
        // sync, resetToken check, picture-selection sync are all in
        // there -- see updateUIView below), which is exactly the
        // "async work / delayed DispatchQueue work completing after
        // the new scene is installed" category Eddie asked to be
        // covered. Re-checks mazeStore.currentMazeID == 2 at execution
        // time (not capture time), because by the time this tick
        // actually runs a FURTHER rebuild could already be underway --
        // if so this reports itself as skipped rather than silently
        // comparing the wrong floor's state.
        if let lightBuildNumber {
            let buildNumberForAsync = lightBuildNumber
            DispatchQueue.main.async { [weak view, mazeStore] in
                guard let view, let scene = view.scene, mazeStore.currentMazeID == 2 else {
                    navLog("[LIGHTBUILD #\(buildNumberForAsync)] NEXT-RUNLOOP checkpoint SKIPPED -- view deallocated or floor changed again before this main-queue tick ran")
                    return
                }
                LightingDeterminismCheck.run(scene: scene, floor: 2, mazeStore: mazeStore, buildNumber: buildNumberForAsync, checkpoint: "NEXT-RUNLOOP (one main-queue tick after makeUIView returned)")
            }
        }
        #endif

        return view
    }

    func updateUIView(_ uiView: TouchTrackingSCNView, context: Context) {
        // Sept 22 (DECORATE sync fix): relocated from makeUIView, which
        // only ever runs once (at initial scene build, when
        // decorator.enabled is always still false) -- that placement
        // was the actual reason every previous DECORATE one-cell-
        // movement fix stayed dead on device: decorateModeEnabled got
        // latched to false at construction and never updated again, no
        // matter how many times the DECORATE button was toggled
        // afterward. This is the one spot that genuinely runs on every
        // update pass, including every decorator.enabled toggle (an
        // @ObservedObject dependency), so the navigation controller's
        // movement planner now actually reflects the live mode.
        // navigationController is already non-nil here in steady state
        // (set once in makeUIView); optional chaining is defensive only.
        context.coordinator.navigationController?.decorateModeEnabled = decorator.enabled
        context.coordinator.mirrorCamera?.setActive(cameraEnabled)
        context.coordinator.mirrorCamera?.setExpressionAnalysisEnabled(cameraEnabled && mirrorComments.looking)
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

        // Sept 20 (picture-teleport fix): the in-gameplay Change
        // Picture menu (PictureChangeMenuHost) mutates
        // mazeStore.pictureImageSelections directly, with NO
        // sceneVersion bump -- same "swap the retained material's
        // contents in place, no scene rebuild" mechanism applyTheme
        // just above already uses for the theme button, so the player
        // is never moved. Only the coord(s) whose selection actually
        // changed since the last pass get re-applied; everything else
        // (including the picture(s) already correct from the initial
        // build) is left alone.
        if context.coordinator.lastPictureImageSelections != mazeStore.pictureImageSelections {
            let previous = context.coordinator.lastPictureImageSelections
            let current = mazeStore.pictureImageSelections
            context.coordinator.lastPictureImageSelections = current
            for (face, selection) in current {
                guard previous[face] != selection, let material = context.coordinator.pictureMaterials[face] else { continue }
                context.coordinator.applyLivePictureSelection(selection, to: material)
            }
        }

    }

    static func dismantleUIView(_ uiView: TouchTrackingSCNView, coordinator: Coordinator) {
        coordinator.mirrorCamera?.setActive(false)
        uiView.delegate = nil
        uiView.isPlaying = false
    }

    final class Coordinator: NSObject {
        weak var decorator: DecoratorState?
        var mirrorCamera: MirrorCamera?
        var movementController: MovementController?
        var navigationController: TapNavigationController?
        // Eddie, Sept 16 (entrance-door tap -> opening screen): the only
        // Coordinator property that reaches back into ContentView's own
        // NavigationBridge -- set once in makeUIView, same object
        // HallwaySceneView already holds as an @ObservedObject.
        weak var navBridge: NavigationBridge?
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
        // Sept 20 (picture-teleport fix): same "retained material,
        // swap its contents in place" idea as wallMaterials/
        // floorMaterial/ceilingMaterial just above, but per-picture --
        // lets a live in-gameplay Change Picture menu choice update
        // just that one wall's texture with no scene rebuild, so the
        // player is never moved. lastPictureImageSelections is the
        // baseline updateUIView diffs mazeStore.pictureImageSelections
        // against, so only the picture(s) that actually changed get
        // re-fetched/applied.
        var pictureMaterials: [WallFace: SCNMaterial] = [:]
        var lastPictureImageSelections: [WallFace: PictureImageSelection] = [:]
        // Sept 14 (Eddie): so applyTheme() below can tell Floor 1 (the
        // lobby) apart from every other floor when it re-picks the
        // floor image -- mirrors mazeStore.currentMazeID, the same
        // floor/maze identifier HallwayScene.build(fromMaze:) is
        // already called with.
        var currentFloorNumber: Int = 1
        var lastTheme: HallwayTheme = .brick


        // Drag-controlled left/right turning: how many points of
        // horizontal drag equal one full 90-degree turn. Purely a feel
        // constant — smaller means a shorter drag commits a turn,
        // larger means a longer, more deliberate one.
        private let dragRotateDistance: CGFloat = 140

        // Positional counterpart of dragRotateDistance -- how many
        // points of vertical drag equal one full grid cell of forward/
        // backward movement. Starts equal to dragRotateDistance (same
        // interaction philosophy, per Eddie's spec) but kept as its own
        // named constant so move feel can be retuned independently of
        // turn feel.
        private let dragMoveDistance: CGFloat = 140

        // Once a single finger-down pan gesture has moved far enough in
        // one direction to tell horizontal drag (turn) apart from
        // vertical drag (move), it commits to that axis for the rest of
        // the gesture -- see handlePanRotate below. Below this many
        // points of total movement, every pan still reads as the
        // existing horizontal turn drag, exactly as before this axis
        // existed, so ordinary left/right dragging is unchanged.
        private let dragAxisLockDistance: CGFloat = 10
        private enum PanDragAxis { case horizontal, vertical }
        private var lockedPanAxis: PanDragAxis?

        // Pinch counterpart of dragMoveDistance: how much UIPinchGesture
        // Recognizer's `scale` has to move away from 1.0 (its neutral,
        // fingers-unmoved value) to represent one full grid cell of
        // forward/backward travel. Pinch OUT (scale > 1) = forward,
        // pinch IN (scale < 1) = backward -- see handlePinch below,
        // which feeds this straight into the SAME beginDragMove/
        // updateDragMove/endDragMove machinery the one-finger vertical
        // drag uses, not a second locomotion model. 0.4 means spreading
        // (or pinching) your fingers to 1.4x (or 0.6x) their starting
        // distance apart is one cell -- an initial feel constant, easy
        // to retune independently of dragMoveDistance.
        private let pinchScalePerCell: Double = 0.4

        // Sept 24 (TOUCH/INSPECTION pass): temporary two-finger pinch-scale
        // on wall pictures -- same borrow-the-whole-gesture model the
        // mission plaque below uses, so the two inspectable wall fixtures
        // feel related. When a pinch begins ON a picture (see handlePinch),
        // this whole gesture scales just the picture's frame node; on
        // release it springs back to its authored size. Nothing is
        // persisted and navigation/editor state never hears about it. nil
        // whenever no picture is being pinched. Min kept at 0.6x; the max
        // was raised from the old 1.6x to 2.5x this pass so a user can
        // genuinely inspect a photograph rather than merely make it
        // somewhat larger -- 2.5x is the conservative end of Eddie's
        // 2.5-3.0 target, chosen to keep a magnified frame clear of
        // near-plane/camera clipping.
        private var pinchPictureFrame: SCNNode?
        private var pinchPictureBaseScale = SCNVector3(1, 1, 1)
        private let picturePinchMinScale: Double = 0.6
        private let picturePinchMaxScale: Double = 2.5

        // Sept 24 (TOUCH/INSPECTION pass): mission plaque counterpart of
        // the picture pinch just above -- same model, same useful range,
        // same spring-back. The WHOLE framed plaque assembly scales in
        // place: its frame node is tagged .missionSign (DecoratorTarget)
        // at build time and carries the plaque plane plus any picture
        // light as children, so scaling that one node enlarges the
        // complete plaque as a unit. It then snaps exactly back to the
        // authored scale on release. nil whenever no plaque is being
        // pinched.
        private var pinchPlaqueFrame: SCNNode?
        private var pinchPlaqueBaseScale = SCNVector3(1, 1, 1)
        private let plaquePinchMinScale: Double = 0.6
        private let plaquePinchMaxScale: Double = 2.5

        // Ticks while a long-press-forward is held -- see
        // handleLongPressForward below. nil whenever nothing's held.
        private var forwardHoldTimer: Timer?

        func cancelHeldWalkForMap() {
            navigationController?.setWalkingHeld(false)
            forwardHoldTimer?.invalidate()
            forwardHoldTimer = nil
        }

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
            if let view = gesture.view as? SCNView, controller.canRotate,
               decorator?.select(at: gesture.location(in: view), in: view) == true {
                return
            }
            if let coord = controller.pictureAtCurrentCell {
                controller.activatePictureMenu(at: coord)
                return
            }
            if let coord = controller.photoBoothAtCurrentCell {
                controller.activatePhotoBooth(at: coord)
                return
            }
            if let coord = controller.ticTacToeTerminalAtCurrentCell {
                controller.activateTicTacToeTerminal(at: coord)
                return
            }
            if let coord = controller.shellGameTerminalAtCurrentCell {
                controller.activateShellGameTerminal(at: coord)
                return
            }
            if let coord = controller.rockPaperScissorsTerminalAtCurrentCell {
                controller.activateRockPaperScissorsTerminal(at: coord)
                return
            }
            if let coord = controller.higherLowerTerminalAtCurrentCell {
                controller.activateHigherLowerTerminal(at: coord)
                return
            }
            if let coord = controller.fiveCardDrawTerminalAtCurrentCell {
                controller.activateFiveCardDrawTerminal(at: coord)
                return
            }
            if let coord = controller.simonTerminalAtCurrentCell {
                controller.activateSimonTerminal(at: coord)
                return
            }
            if let coord = controller.hangmanTerminalAtCurrentCell {
                controller.activateHangmanTerminal(at: coord)
                return
            }
            if let coord = controller.connectFourTerminalAtCurrentCell {
                controller.activateConnectFourTerminal(at: coord)
                return
            }
            if let coord = controller.checkersTerminalAtCurrentCell {
                controller.activateCheckersTerminal(at: coord)
                return
            }
            if let coord = controller.woidleTerminalAtCurrentCell {
                controller.activateWoidleTerminal(at: coord)
                return
            }
            if let view = gesture.view as? SCNView {
                let location = gesture.location(in: view)
                let hits = view.hitTest(location, options: nil)
                // Sept 12: each hit-test below can find its object's mesh
                // visible straight down the hall well before the player has
                // actually reached it -- e.g. the elevator, a chute, or a
                // wall map sitting on the wall just beyond the very next
                // open cube. Only treat the tap as "interact with that
                // object" when it's actually reachable right now, same
                // "distant hits fall through to walking" rule
                // canReachFireFixture already enforces for extinguishers/
                // fires just below. Without this, a tap meant to walk one
                // legal cell forward (into an open cell with a wall, or
                // another interactive object, immediately beyond it) was
                // being silently swallowed here instead of ever reaching
                // advance() -- held-walk never hit this because
                // advanceWhileHeld() goes straight to movement with no
                // hit-testing at all, which is why only tap was affected.
                if let bathroomDoorCoord = hits.compactMap({ controller.bathroomDoorCoordinate(for: $0.node) }).first,
                   controller.isAdjacentToBathroomDoor(bathroomDoorCoord) {
                    navLog("tap hit bathroom door at \(bathroomDoorCoord)")
                    controller.openBathroomDoor(at: bathroomDoorCoord)
                    return
                }
                if let windowRoomDoorCoord = hits.compactMap({ controller.windowRoomDoorCoordinate(for: $0.node) }).first,
                   controller.isAdjacentToWindowRoomDoor(windowRoomDoorCoord) {
                    navLog("tap hit window room door at \(windowRoomDoorCoord)")
                    controller.openWindowRoomDoor(at: windowRoomDoorCoord)
                    return
                }
                if let roomCoord = hits.compactMap({ controller.roomDoorCoordinate(for: $0.node) }).first,
                   roomCoord == controller.currentCell {
                    // Sept 24 (room-door knock interaction): routes by
                    // door kind -- functional doors keep the mail flow
                    // (delivery/"No mail"), decorative doors (Floor 2)
                    // play the knock ladder instead. One tap -> one
                    // routing decision -> one sound, then this branch
                    // returns so no later hit path can double-fire.
                    navLog("tap hit room door at \(roomCoord)")
                    controller.interactWithRoomDoor(at: roomCoord)
                    return
                }
                if let doorCoord = hits.compactMap({ controller.destinationCoordinate(for: $0.node) }).first,
                   doorCoord == controller.currentCell {
                    navLog("tap hit destination door at \(doorCoord)")
                    controller.openDestinationDoor(at: doorCoord)
                    return
                }
                // Sept 21 (deliberate tap-to-pick-up): decorator?.enabled
                // != true is belt-and-suspenders, not the only thing
                // keeping this out of DECORATE -- a tap that lands on a
                // trash can's node while decorating is already consumed
                // by the decorator?.select(...) branch at the very top
                // of this function (that trash can is tagged as a
                // .floorObject Decorator target -- see HallwayScene's
                // per-cell object placement loop), which returns before
                // execution ever reaches here. This extra check just
                // makes "trash must NEVER trigger gameplay pickup while
                // decorating" true unconditionally, not dependent on
                // select()'s own canRotate/exists() gating never having
                // an edge case that lets a tap fall through.
                if decorator?.enabled != true,
                   let coord = hits.compactMap({ controller.objectCoordinate(for: $0.node) }).first,
                   controller.collectByTap(at: coord) { return }
                if let coord = hits.compactMap({ controller.extinguisherCoordinate(for: $0.node) }).first,
                   controller.pickUpExtinguisher(at: coord) { return }
                if let coord = hits.compactMap({ controller.fireCoordinate(for: $0.node) }).first,
                   controller.extinguishFire(at: coord) { return }
                if let coord = controller.extinguisherAtCurrentCell,
                   controller.pickUpExtinguisher(at: coord) { return }
                if let coord = controller.activeFireAtCurrentCell,
                   controller.extinguishFire(at: coord) { return }
                if let coord = hits.compactMap({ controller.photoBoothCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.activatePhotoBooth(at: coord)
                    return
                }
                if let coord = hits.compactMap({ controller.ticTacToeTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.activateTicTacToeTerminal(at: coord)
                    return
                }
                if let coord = hits.compactMap({ controller.shellGameTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.activateShellGameTerminal(at: coord)
                    return
                }
                if let coord = hits.compactMap({ controller.rockPaperScissorsTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.activateRockPaperScissorsTerminal(at: coord)
                    return
                }
                if let coord = hits.compactMap({ controller.higherLowerTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.activateHigherLowerTerminal(at: coord)
                    return
                }
                if let coord = hits.compactMap({ controller.fiveCardDrawTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.activateFiveCardDrawTerminal(at: coord)
                    return
                }
                if let coord = hits.compactMap({ controller.simonTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.activateSimonTerminal(at: coord)
                    return
                }
                if let coord = hits.compactMap({ controller.hangmanTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.activateHangmanTerminal(at: coord)
                    return
                }
                if let coord = hits.compactMap({ controller.connectFourTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.activateConnectFourTerminal(at: coord)
                    return
                }
                if let coord = hits.compactMap({ controller.checkersTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.activateCheckersTerminal(at: coord)
                    return
                }
                if let coord = hits.compactMap({ controller.woidleTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.activateWoidleTerminal(at: coord)
                    return
                }
                if hits.contains(where: { controller.isElevatorDoor($0.node) }), controller.elevatorAtCurrentCell {
                    navLog("tap hit elevator door")
                    if controller.canReenterArrivedElevator {
                        controller.advance()
                    } else {
                        controller.openElevator()
                    }
                    return
                }
                if hits.contains(where: { controller.isEntranceDoor($0.node) }), controller.entranceDoorAtCurrentCell {
                    navLog("tap hit floor 1 entrance doors (inside) -- returning to opening screen")
                    navBridge?.requestReturnToOpening = true
                    return
                }
                if hits.contains(where: { controller.isFloorMapNode($0.node) }), controller.floorMapAtCurrentCell {
                    return // Wall maps are read in place; no pop-up or movement.
                }
            }
            navLog("tap")
            controller.advance()
        }

        // Eddie, Sept 17 (pinch continuity fix): was "wait for the
        // gesture to end, then look at the final scale and make one
        // discrete move" (pinchForward()/stepBackward(), each a single
        // legal cell). That's why movement used to wait for finger-up
        // instead of tracking the pinch live -- .began/.changed were
        // never handled at all. Rewired to drive the exact same
        // continuous-scrub machinery the one-finger vertical drag uses
        // (beginDragMove/updateDragMove/endDragMove in
        // TapNavigationController.swift) instead of a second locomotion
        // model: pinch OUT (scale > 1) = forward, pinch IN (scale < 1)
        // = backward, continuously, with the same reversal, topology
        // limits, and release settle/snap vertical drag already has.
        // Note: the old pinchForward() also auto-opened the elevator
        // when pinching forward while standing at the end facing it --
        // that shortcut isn't carried over here (endDragMove doesn't
        // know about the elevator), so for now reaching the elevator
        // via pinch stops there without opening it, same as walking up
        // to it without tapping the door. pinchForward() itself is left
        // in place, just unused, in case that shortcut should come back.
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let controller = navigationController else { return }
            let fraction = (Double(gesture.scale) - 1.0) / pinchScalePerCell
            let velocityFraction = Double(gesture.velocity) / pinchScalePerCell
            switch gesture.state {
            case .began:
                // Sept 24 (Finishing Pass): a pinch that starts on a real
                // picture borrows that WHOLE gesture to temporarily scale
                // just that one picture (no locomotion, no persisted
                // state). Every other pinch keeps the existing live-scrub
                // navigation below, entirely unchanged.
                if let frame = pictureFrameTouched(by: gesture),
                   decorator?.enabled != true {
                    pinchPictureFrame = frame
                    pinchPictureBaseScale = frame.scale
                    navLog("pinch began on picture, scaling in place")
                    return
                }
                if let frame = missionPlaqueFrameTouched(by: gesture),
                   decorator?.enabled != true {
                    pinchPlaqueFrame = frame
                    pinchPlaqueBaseScale = frame.scale
                    navLog("pinch began on mission plaque, scaling in place")
                    return
                }
                navLog("pinch began")
                controller.beginDragMove()
            case .changed:
                if let frame = pinchPictureFrame {
                    applyPicturePinch(gesture.scale, to: frame)
                    return
                }
                if let frame = pinchPlaqueFrame {
                    applyPlaquePinch(gesture.scale, to: frame)
                    return
                }
                controller.updateDragMove(fraction: fraction)
            case .ended, .cancelled, .failed:
                if let frame = pinchPictureFrame {
                    pinchPictureFrame = nil
                    navLog("pinch ended, picture scale=\(String(format: "%.2f", gesture.scale)) snaps back")
                    let base = pinchPictureBaseScale
                    let from = frame.scale
                    frame.removeAction(forKey: "picturePinch")
                    frame.runAction(SCNAction.customAction(duration: 0.3) { node, elapsed in
                        let t = min(elapsed / 0.3, 1)
                        let eased = Float(1 - pow(1 - t, 3))
                        let sx = from.x + (base.x - from.x) * eased
                        let sy = from.y + (base.y - from.y) * eased
                        let sz = from.z + (base.z - from.z) * eased
                        node.scale = SCNVector3(sx, sy, sz)
                    }, forKey: "picturePinch")
                    return
                }
                if let frame = pinchPlaqueFrame {
                    pinchPlaqueFrame = nil
                    navLog("pinch ended, plaque scale=\(String(format: "%.2f", gesture.scale)) snaps back")
                    let base = pinchPlaqueBaseScale
                    let from = frame.scale
                    frame.removeAction(forKey: "plaquePinch")
                    frame.runAction(SCNAction.customAction(duration: 0.3) { node, elapsed in
                        let t = min(elapsed / 0.3, 1)
                        let eased = Float(1 - pow(1 - t, 3))
                        let sx = from.x + (base.x - from.x) * eased
                        let sy = from.y + (base.y - from.y) * eased
                        let sz = from.z + (base.z - from.z) * eased
                        node.scale = SCNVector3(sx, sy, sz)
                    }, forKey: "plaquePinch")
                    return
                }
                navLog("pinch ended, fraction=\(String(format: "%.2f", fraction)), velocityFraction=\(String(format: "%.2f", velocityFraction))")
                controller.endDragMove(fraction: fraction, velocityFraction: velocityFraction)
            default:
                break
            }
        }

        // Sept 24 (Finishing Pass): walks the hit chain from a pinch's
        // touch point up to the Decorator-tagged picture frame and
        // returns it, else nil -- the same parent-chain read the tap
        // and editor paths use, and the picture frame node is exactly
        // the node tagged .picture at build time (HallwayScene
        // buildPictureNode's addPictureNode call site).
        private func pictureFrameTouched(by gesture: UIPinchGestureRecognizer) -> SCNNode? {
            guard let view = gesture.view as? SCNView,
                  let hit = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .ignoreHiddenNodes: true]).first else { return nil }
            var node: SCNNode? = hit.node
            while let current = node {
                if let target = DecoratorTarget.read(current), target.kind == .picture {
                    return current
                }
                node = current.parent
            }
            return nil
        }

        // Sept 24 (Finishing Pass): applies a clamped uniform scale to a
        // picture frame in place (frame pivot sits at the picture's own
        // center on the wall face, so it grows/shrinks centered and
        // stays attached to the wall -- no movement, no rebuild).
        private func applyPicturePinch(_ scale: CGFloat, to frame: SCNNode) {
            let clamped = CGFloat(min(max(Double(scale), picturePinchMinScale), picturePinchMaxScale))
            let base = pinchPictureBaseScale
            frame.scale = SCNVector3(base.x * Float(clamped), base.y * Float(clamped), base.z * Float(clamped))
        }

        // Sept 24 (TOUCH/INSPECTION pass): same parent-chain hit walk as
        // pictureFrameTouched just above, for the mission plaque. Returns
        // the wall-mounted frame node carrying the .missionSign
        // DecoratorTarget identity (HallwayScene.addMissionSignNode); the
        // plaque plane and any picture light ride as its children, so
        // scaling that node scales the complete visible plaque as one
        // object. nil when the pinch does not begin on an actual plaque,
        // so pinching bare wall keeps its normal meaning.
        private func missionPlaqueFrameTouched(by gesture: UIPinchGestureRecognizer) -> SCNNode? {
            guard let view = gesture.view as? SCNView,
                  let hit = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .ignoreHiddenNodes: true]).first else { return nil }
            var node: SCNNode? = hit.node
            while let current = node {
                if let target = DecoratorTarget.read(current), target.kind == .missionSign {
                    return current
                }
                node = current.parent
            }
            return nil
        }

        // Sept 24 (TOUCH/INSPECTION pass): clamped uniform scale for the
        // mission plaque -- the applyPicturePinch mirror. The frame
        // pivot sits at the assembly's own center on the wall face, so it
        // grows/shrinks centered in place and stays attached to the wall.
        private func applyPlaquePinch(_ scale: CGFloat, to frame: SCNNode) {
            let clamped = CGFloat(min(max(Double(scale), plaquePinchMinScale), plaquePinchMaxScale))
            let base = pinchPlaqueBaseScale
            frame.scale = SCNVector3(base.x * Float(clamped), base.y * Float(clamped), base.z * Float(clamped))
        }

        @objc func handleTwoFingerTap() {
            navLog("two-finger tap (turn around)")
            guard let controller = navigationController else { return }
            controller.rotate(toward: controller.facing.opposite)
        }

        @objc func handlePanRotate(_ gesture: UIPanGestureRecognizer) {
            guard let controller = navigationController, let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            let velocity = gesture.velocity(in: view)
            // Positive translation.x (finger moving left-to-right) is
            // "swipe right," which Eddie's spec pivots LEFT — matches
            // Direction's yaw convention where turning left is always
            // a positive angle change regardless of current facing.
            let fraction = Double(translation.x / dragRotateDistance)
            // Same normalization as `fraction` itself, just per second --
            // lets endDragRotate compare position and flick speed on the
            // same 90-degree-turn scale (see its own release-decision
            // comment in TapNavigationController.swift).
            let velocityFraction = Double(velocity.x / dragRotateDistance)
            // Positional counterpart of fraction/velocityFraction above:
            // drag DOWN = move FORWARD (Eddie's spec), and UIKit's
            // translation.y is already positive moving down, so this
            // needs no sign flip the way the horizontal fraction above
            // does for its left/right convention.
            let verticalFraction = Double(translation.y / dragMoveDistance)
            let verticalVelocityFraction = Double(velocity.y / dragMoveDistance)
            // Eddie, Sept 15 (elevator camera control): same gesture,
            // same fraction/dragRotateDistance math, routed to the
            // elevator's own freeform look instead of the grid-
            // navigation drag-turn while a ride is in progress -- see
            // beginElevatorCameraDrag()'s own comment in
            // TapNavigationController.swift for why these can't just
            // share beginDragRotate/updateDragRotate/endDragRotate
            // outright (that trio always commits to one of the 4
            // cardinal facings on release, which an elevator interior
            // -- off the grid entirely -- shouldn't). Vertical drag-move
            // doesn't apply here either -- an elevator interior is off
            // the grid, so there's no forward/backward cell to move
            // between.
            if controller.isElevatorRideInProgress {
                switch gesture.state {
                case .began:
                    navLog("pan rotate began (elevator camera)")
                    controller.beginElevatorCameraDrag()
                case .changed:
                    controller.updateElevatorCameraDrag(fraction: fraction)
                case .ended, .cancelled, .failed:
                    navLog("pan rotate ended (elevator camera)")
                    controller.endElevatorCameraDrag()
                default:
                    break
                }
                return
            }
            // Axis disambiguation: every pan starts out treated as the
            // existing horizontal turn-drag, exactly as before this
            // vertical mode existed (beginDragRotate() fires immediately
            // on .began, same as always). Only once the finger has moved
            // dragAxisLockDistance points in EITHER direction does this
            // decide, once, which axis actually owns the gesture -- if
            // vertical wins, the in-flight (and by construction still
            // tiny, since it hasn't crossed the lock distance yet)
            // horizontal drag is cleanly released with fraction: 0
            // (facing snaps back to whatever it already was -- no turn
            // commits) and beginDragMove() takes over instead. Once
            // locked, that axis keeps the rest of the gesture until
            // release, so a diagonal finger movement can never straddle
            // both a turn and a move in one interaction.
            switch gesture.state {
            case .began:
                lockedPanAxis = nil
                navLog("pan rotate began")
                controller.beginDragRotate()
            case .changed:
                if lockedPanAxis == nil {
                    let ax = abs(translation.x)
                    let ay = abs(translation.y)
                    if max(ax, ay) >= dragAxisLockDistance {
                        if ay > ax {
                            lockedPanAxis = .vertical
                            navLog("pan drag committed to vertical axis (move)")
                            controller.cancelDragRotateForAxisHandoff()
                            controller.beginDragMove()
                        } else {
                            lockedPanAxis = .horizontal
                            navLog("pan drag committed to horizontal axis (turn)")
                        }
                    }
                }
                if lockedPanAxis == .vertical {
                    controller.updateDragMove(fraction: verticalFraction)
                } else {
                    controller.updateDragRotate(fraction: fraction)
                }
            case .ended, .cancelled, .failed:
                if lockedPanAxis == .vertical {
                    navLog("pan drag ended (move), fraction=\(String(format: "%.2f", verticalFraction)), velocityFraction=\(String(format: "%.2f", verticalVelocityFraction))")
                    controller.endDragMove(fraction: verticalFraction, velocityFraction: verticalVelocityFraction)
                } else {
                    navLog("pan rotate ended, fraction=\(String(format: "%.2f", fraction)), velocityFraction=\(String(format: "%.2f", velocityFraction))")
                    controller.endDragRotate(fraction: fraction, velocityFraction: velocityFraction)
                }
                lockedPanAxis = nil
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
                navigationController?.setWalkingHeld(true)
                navigationController?.advanceWhileHeld()
                forwardHoldTimer?.invalidate()
                let timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.navigationController?.advanceWhileHeld()
                }
                RunLoop.main.add(timer, forMode: .common)
                forwardHoldTimer = timer
            case .ended, .cancelled, .failed:
                navLog("long-press forward ended")
                navigationController?.setWalkingHeld(false)
                forwardHoldTimer?.invalidate()
                forwardHoldTimer = nil
            default:
                break
            }
        }

        // Sept 20 (picture-teleport fix): updates ONE picture's already-
        // placed SCNMaterial in place -- called from updateUIView when
        // mazeStore.pictureImageSelections changes live during
        // gameplay (the Change Picture menu), never from a fresh
        // scene build (that path already applies the right image up
        // front in HallwayScene.build itself). Same two cases/same
        // fetch calls HallwayScene.build's own post-build async
        // application already uses for cameraRollMaterials/
        // explicitCameraRollMaterials, just re-run here on demand
        // instead of once at build time.
        func applyLivePictureSelection(_ selection: PictureImageSelection, to material: SCNMaterial) {
            switch selection {
            case .builtIn(let name):
                let image = HallwayScene.namedPictureImage(name)
                material.diffuse.contents = image.map { HallwayScene.framedPhoto($0) } ?? HallwayScene.mirrorPlaceholder("Photo unavailable")
            case .cameraRoll(let identifier):
                let floorNumber = currentFloorNumber
                PhotoRollProvider.shared.image(forIdentifier: identifier, caller: "floor \(floorNumber) hallway-picture live-update") { [weak material] image in
                    guard let material else { return }
                    material.diffuse.contents = image.map { HallwayScene.framedPhoto($0) } ?? HallwayScene.mirrorPlaceholder("Photo unavailable")
                }
            }
        }

        func applyTheme(_ theme: HallwayTheme) {
            if theme == .myPhotos {
                applyPhotoRollTheme()
                return
            }
            // Sept 15 fix (Eddie, lobby visual pass): same reasoning
            // as the Floor-1-floor fix right below -- this is the LAST
            // point anything writes wallMaterials'/ceilingMaterial's
            // diffuse.contents, on every theme cycle including the
            // first updateUIView pass right after the scene is built,
            // so it's the one place that has to know about Floor 1's
            // own lobby-wall/lobby-ceiling textures or it silently
            // overwrites them back to the current theme's. Floors
            // 2-16: exactly theme.wallImageName, unchanged.
            // Eddie, Sept 16 (Floor 2 visual pass): same per-floor
            // override shape as Floor 1's lobby-wall, so tapping the
            // theme button while on Floor 2 keeps showing the
            // experimental plaster wall instead of switching back to
            // brick/cave/etc. Floors 3-16: exactly theme.wallImageName,
            // unchanged.
            let effectiveWallImageName: String?
            switch currentFloorNumber {
            case 1: effectiveWallImageName = "lobby-wall"
            // Eddie, Sept 17 (Floor 2 visual pass v2): matches
            // HallwayScene.build(fromMaze:)'s own case 2 -- wood-oak.jpg
            // instead of the earlier procedural plaster, so a theme-
            // cycle tap while on Floor 2 doesn't clobber it back.
            case 2: effectiveWallImageName = "wood-walnut"
            default: effectiveWallImageName = theme.wallImageName
            }
            for material in wallMaterials {
                applySurface(material, imageName: effectiveWallImageName, fallbackColor: HallwayScene.wallFallbackColor)
            }
            // Sept 14 fix (Eddie): this is the LAST point anything
            // writes floorMaterial.diffuse.contents -- it runs on every
            // theme cycle, including the first updateUIView pass right
            // after the scene is built, so it's the one place that has
            // to know about Floor 1's special texture or it silently
            // overwrites it. currentFloorNumber is set in makeUIView
            // above, same "floorNumber" HallwayScene.build(fromMaze:)
            // itself already uses to pick floor1.png at construction --
            // this just makes the SAME choice again here, where it
            // actually sticks. Floors 2-19: exactly theme.floorImageName,
            // unchanged.
            let effectiveFloorImageName = currentFloorNumber == 1 ? "floor1" : (currentFloorNumber == 2 ? "floor-carpet1" : theme.floorImageName)
            applySurface(floorMaterial, imageName: effectiveFloorImageName, fallbackColor: HallwayScene.floorFallbackColor)
            let effectiveCeilingImageName = currentFloorNumber == 1 ? "lobby-ceiling" : (currentFloorNumber == 2 ? "ceiling-pattern" : theme.ceilingImageName)
            applySurface(ceilingMaterial, imageName: effectiveCeilingImageName, fallbackColor: HallwayScene.ceilingFallbackColor)
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
            navigationController?.updatePaintBase(for: material)
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

        /// One independent full-library selection per wall/ceiling material.
        /// There is no capped image pool to cycle across surfaces.
        private var photoThemeRequestID = UUID()
        private func applyPhotoRollTheme() {
            let materials = wallMaterials + [ceilingMaterial].compactMap { $0 }
            let requestID = UUID()
            photoThemeRequestID = requestID
            for material in materials {
                material.diffuse.contents = UIColor(white: 0.08, alpha: 1)
                navigationController?.updatePaintBase(for: material)
            }
            PhotoRollProvider.shared.randomImages(count: materials.count, caller: "My Photos walls/ceiling") { [weak self] index, image in
                guard let self, self.lastTheme == .myPhotos, self.photoThemeRequestID == requestID else { return }
                let material = materials[index]
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.3
                material.diffuse.contents = image ?? HallwayScene.mirrorPlaceholder("Photo unavailable")
                navLog("PHOTO-PATH-V1 APPLIED caller=My Photos walls/ceiling[\(index)] source=\(image == nil ? "UNAVAILABLE_PLACEHOLDER" : "PHOTOS")")
                material.diffuse.wrapS = .clamp
                material.diffuse.wrapT = .clamp
                material.diffuse.contentsTransform = SCNMatrix4Identity
                self.navigationController?.updatePaintBase(for: material)
                SCNTransaction.commit()
            }
        }
    }
}

#Preview {
    ContentView()
}
