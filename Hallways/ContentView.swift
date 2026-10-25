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
    /// Oct 5 (dev New Player reset): rebuild the current floor's scene even
    /// though its maze data did not change (so floor gates re-evaluate).
    @Published var rebuildToken = 0
    func requestSceneRebuild() { rebuildToken += 1 }
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
    @Published var controller: TapNavigationController? {
        didSet {
            // Oct 2: flight recorder only (DiagnosticRecorder).
            if (oldValue == nil) != (controller == nil) || oldValue !== controller {
                diag(controller == nil ? "bridge.controllerCleared" : "bridge.controllerPublished",
                     ["floor": controller?.currentFloorNumber, "arrivalReadyToOpen": arrivalReadyToOpen])
            }
        }
    }

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
    @Published var floorTransitionRequested: TapNavigationController.FloorTransitionEvent? {
        didSet { diag("bridge.floorTransitionRequested", ["set": floorTransitionRequested != nil]) }
    }

    // Eddie, Sept 8: wants the curtain's closed-door look to be
    // the SAME color/lighting as the real 3D doors, pixel for
    // pixel, not a hand-tuned approximation. Set once per ride,
    // right before the SCNView's scene gets torn down for the
    // next floor (see onReachedEnd in HallwaySceneView.makeUIView)
    // -- a real snapshot of exactly what was on screen at that
    // instant, dimmed lighting and all.
    @Published var doorSnapshot: UIImage?
    /// Controlled arrivals reveal on a prepared destination frame, independently of doors.
    @Published var controlledArrivalFrameReady = false
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
    @Published var pendingElevatorArrival = false {
        didSet { if oldValue != pendingElevatorArrival { diag("bridge.pendingElevatorArrival", ["value": pendingElevatorArrival]) } }
    }
    /// Oct 4 (interactive elevator): where in the cab the player was standing
    /// when the ride ended, relative to the doors (along = into the cab,
    /// across), so the destination cab presents them on the same spot.
    var pendingArrivalOffset: SIMD2<Double>?

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
    @Published var arrivalSceneReady = false {
        didSet {
            if oldValue != arrivalSceneReady {
                diag("bridge.arrivalSceneReady", ["value": arrivalSceneReady, "controllerPresent": controller != nil,
                                                  "arrivalReadyToOpen": arrivalReadyToOpen])
            }
        }
    }

    /// Oct 2 (beta: Carol, "elevator doors closed, then froze"): the arrival
    /// curtain may open only once the DESTINATION controller is published as
    /// well -- for a player-controlled ride it is what opens the real 3D
    /// doors (playControlledArrivalDoorOpen). makeUIView sets
    /// arrivalSceneReady synchronously but publishes `controller` one main-
    /// queue hop later; when the floor build outlasted the curtain's first
    /// poll, an already-queued poll ran in between, found the scene "ready"
    /// and `controller` still nil, and the doors were never opened.
    var arrivalReadyToOpen: Bool { arrivalSceneReady && controller != nil }

    /// Oct 2, second Carol report (PASSIVE ride, music kept playing behind a
    /// closed curtain): the controller requirement above is only needed by a
    /// CONTROLLED arrival (its real doors are opened through the controller).
    /// A passive arrival's doors are already open from
    /// presentArrivalInsideElevator, so it needs the scene only. Either way
    /// the curtain never waits longer than `arrivalCurtainTimeout`.
    enum ArrivalCurtainDecision: Equatable { case wait, open, openAfterTimeout }
    static let arrivalCurtainTimeout: TimeInterval = 3
    static func arrivalCurtainDecision(controlled: Bool, sceneReady: Bool, controllerReady: Bool,
                                       elapsed: TimeInterval) -> ArrivalCurtainDecision {
        let ready = controlled ? (sceneReady && controllerReady) : sceneReady
        if ready { return .open }
        return elapsed >= arrivalCurtainTimeout ? .openAfterTimeout : .wait
    }

    /// A controlled arrival's door-open request that could not be delivered
    /// yet (timeout fired before the destination controller was published).
    /// Plain storage, not @Published: nothing renders from it. Delivered by
    /// makeUIView the moment it publishes the controller; reset when a new
    /// ride begins, so it can never leak into a later arrival.
    var pendingControlledDoorOpen = false
    /// Oct 2: one compact line of the arrival-relevant bridge state, for
    /// the flight recorder at dangerous moments. Reads only.
    func diagSnapshot(_ label: String) {
        diag("snapshot." + label, [
            "pendingElevatorArrival": pendingElevatorArrival,
            "arrivalSceneReady": arrivalSceneReady,
            "controllerPresent": controller != nil,
            "controllerFloor": controller?.currentFloorNumber,
            "arrivalReadyToOpen": arrivalReadyToOpen,
            "arrivalWasControlled": arrivalWasControlled,
            "pendingControlledDoorOpen": pendingControlledDoorOpen,
            "floorTransitionRequested": floorTransitionRequested != nil,
            "snapshotPresent": doorSnapshot != nil
        ])
    }

    func deliverControlledArrivalDoorOpen() {
        diag("arrival.controlledDoorOpenRequested", ["controllerPresent": controller != nil])
        guard let controller else {
            pendingControlledDoorOpen = true
            elevatorLog("controlled door-open deferred -- destination controller not published yet")
            return
        }
        pendingControlledDoorOpen = false
        elevatorLog("controlled door-open delivered (floor \(controller.currentFloorNumber))")
        controller.playControlledArrivalDoorOpen()
    }

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

/// Oct 8: speaker on / speaker off for all of Hallways' own audio
/// (HallwaysAudio). Same chip style as its neighbours.
struct HallwaysMuteButton: View {
    @ObservedObject private var audio = HallwaysAudio.shared

    var body: some View {
        Button {
            audio.toggle()
        } label: {
            Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 20)       // both glyphs, same footprint
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(audio.isMuted ? "Sound off" : "Sound on")
        .accessibilityHint("Mutes or restores all Hallways sound")
    }
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
    /// Oct 8: the Debug HUD's START OVER confirmation (Settings has its own).
    @State private var showStartOverConfirmation = false

    // Eddie, Sept 7: "we want the intro screen (probably the building
    // with some text instruction on it, copyright, etc)." A one-time
    // full-screen gate shown on launch, dismissed with a tap -- same
    // "own @State overlay with a completion closure" shape as the grid
    // editor's fullScreenCover, just simpler (no navigation stack, just
    // fades out). True on every launch (not @AppStorage-remembered like
    // hasSeenNavGestureHint) since this is the title screen, not a
    // one-time tutorial hint.
    // Oct 5: not when relaunching mid-prologue -- that resumes in
    // Administration (Admission.resumesInAdministration / MazeStore init).
    // Oct 11 (resume): nor when reopening at the player's saved spot (ResumeState).
    @State private var showIntroScreen = !(Admission.resumesInAdministration || ResumeState.resumesAtSavedPoint)

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
    // Sept 28 (Your Height): observed here only to push a changed height
    // into the live camera -- see PlayerHeight and the .onChange below.
    @AppStorage(PlayerHeight.preferenceKey) private var playerHeightInches = PlayerHeight.defaultInches

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
    /// Oct 4: false = no money total and no mission/inventory pill on screen.
    static let showsLegacyHUD = false
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

    /// Oct 8 -- START OVER (Debug AND Release). The shared story reset
    /// (StartOver.clearStoryProgress), then the ContentView half: this
    /// view's own copies of the onboarding flags, back to Floor 1, a scene
    /// rebuild (so the onboarding gates re-evaluate) and the exterior
    /// opening screen -- ready for the original entrance sequence. Called
    /// from Settings > Start Over and the Debug workshop's Start Over.
    private func startOver(source: String) {
        navLog("[LIGHTBUILD] rebuild trigger: Start Over (\(source)) -- leaving floor \(mazeStore.currentMazeID), switching to floor 1")
        clearStoryState(source: source)
        mazeStore.switchTo(id: 1)
        runtime.requestReset()
        runtime.requestSceneRebuild()
        withAnimation(.easeOut(duration: 0.3)) {
            showIntroScreen = true
        }
    }

    /// The story reset itself plus this view's in-memory mirrors of it.
    private func clearStoryState(source: String) {
        StartOver.clearStoryProgress(source: source)
        mazeStore.resetMoneyForNewEmployee()                // a new employee starts with $0
        hasCompletedInitialEntrance = false                 // @AppStorage mirror
        navBridge.controller?.hasCompletedInitialEntrance = false
        hasSeenNavGestureHint = false                       // @AppStorage mirror
    }

    #if DEBUG
    /// Oct 8 -- DEV: RETURN TO LOBBY. Back to Floor 1's start without
    /// touching the story. No exterior screen.
    private func devReturnToLobby() {
        navLog("[LIGHTBUILD] rebuild trigger: dev Return to Lobby -- leaving floor \(mazeStore.currentMazeID), switching to floor 1")
        diag("dev.returnToLobby", ["fromFloor": mazeStore.currentMazeID])
        mazeStore.switchTo(id: 1)
        runtime.requestReset()
    }

    /// Oct 5 -- DEV: FAST ADMINISTRATION TEST. The shared Start Over story
    /// reset, then straight onto Floor 2 through the existing dev floor jump
    /// (its normal start position), rebuilt fresh even if already there --
    /// no exterior, lobby or elevator ride. Called from the grid editor's
    /// Jump to Floor menu.
    private func jumpToAdministrationAsNewEmployee() {
        clearStoryState(source: "devFastAdministration")
        if showIntroScreen {
            SoundEffects.stopStreetAudio()
            showIntroScreen = false
        }
        mazeStore.devJump(to: Admission.administrationFloor)
        runtime.requestReset()
        runtime.requestSceneRebuild()
        diag("dev.fastAdministration", ["floor": Admission.administrationFloor])
    }
    #endif

    var body: some View {
        let traceBody = ElevatorArrivalTrace.shared.beginPhase("ContentView.body", "floor=\(mazeStore.currentMazeID) version=\(mazeStore.version)")
        defer { ElevatorArrivalTrace.shared.endPhase("ContentView.body", traceBody) }
        return ZStack {
            HallwaySceneView(tuning: tuning, runtime: runtime, mazeStore: mazeStore, navBridge: navBridge, themeStore: themeStore, decorator: decorator, mirrorComments: mirrorComments, cameraEnabled: scenePhase == .active && !showGridEditor && !showIntroScreen, hasCompletedInitialEntrance: hasCompletedInitialEntrance)
                .ignoresSafeArea()
                .transaction { transaction in
                    if navBridge.arrivalWasControlled && !navBridge.controlledArrivalFrameReady {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                // Eddie, Sept 16 (entrance-door tap -> opening screen):
                // same 3 actions the existing Reset button already
                // performs below (switch to floor 1 -- a no-op here
                // since we're already there --, request a navigation
                // reset, fade the intro screen back in), just triggered
                // by NavigationBridge's one-shot flag instead of a
                // button tap. No new opening/exterior state or
                // transition -- this reuses exactly what's already
                // there.
                // Sept 28 (Your Height): a changed height moves the current
                // camera immediately (no rebuild); new builds read the same
                // preference when they create their camera.
                .onChange(of: playerHeightInches) { _, _ in
                    navBridge.controller?.setEyeHeight(PlayerHeight.currentEyeHeight)
                }
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
                    // Oct 5 (clean onboarding): outside = street ambience only.
                    CritterAudio.setSuppressed(shown, reason: shown ? "opening screen up" : "entered building")
                    // Oct 8 (Phone & Communications, Phase 1): a natural moment
                    // for the building to send what the story now calls for.
                    if !shown { BuildingDispatch.evaluate(reason: "enteredBuilding") }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Oct 11 (resume): leaving the app -- remember exactly where.
                    // (Oct 16: outside -- the street screen -- is not a place to resume inside the building.)
                    if phase != .active, !showIntroScreen { navBridge.controller?.saveResumePoint(reason: "background") }
                    // Oct 8 (Phase 1): back in the app, inside the building.
                    // Only what is due NOW; app-closed time means nothing yet.
                    if phase == .active && !showIntroScreen { BuildingDispatch.evaluate(reason: "appActive") }
                    // Oct 18 (building life): residents catch up on the time away (and are saved on leaving).
                    if phase == .active { BuildingLife.shared.appBecameActive() } else { BuildingLife.shared.appResigned() }
                }
                // Cold launch: showIntroScreen already starts true, so
                // the onChange above can't fire -- start the street
                // loop here instead (harmless double-start if both fire,
                // since startStreetAudio rewinds to 0 anyway).
                .onAppear {
                    if showIntroScreen { SoundEffects.startStreetAudio() }
                    CritterAudio.setSuppressed(showIntroScreen, reason: "launch")
                    diag("admission.launchState", ["entrance": UserDefaults.standard.bool(forKey: Admission.initialEntranceKey),
                                                   "prologue": Admission.isPrologueCompleted,
                                                   "resumesInAdministration": !showIntroScreen,
                                                   "completed": Admission.isCompleted,
                                                   "employeeNumber": EmployeeID.number ?? "none"])
                }

            if let navController = navBridge.controller {
                NavigationOverlay(controller: navController)
                // Oct 10 experiment: LEFT | WALK/STOP | RIGHT.
                if TapNavigationController.continuousWalkExperimentOn && !showIntroScreen {
                    ContinuousWalkControls(controller: navController)
                        .zIndex(12)
                }
                // Oct 16 (V): the tool tray (audition; ToolBelt.Presentation). Only its own
                // strip takes touches; it steps aside while seated and at the elevator panel.
                if !showIntroScreen && !decorator.enabled {
                    ToolTrayView(controller: navController)
                        .zIndex(13)
                }
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
                // Oct 7 (F): the office computer's screen (Floor 3).
                OfficeComputerOverlayHost()
                    .zIndex(40)
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
                // never changes mazeStore.version, and so never rebuilds
                // the scene or moves the player. See PictureChangeMenuHost's
                // own doc comment.
                PictureChangeMenuHost(controller: navController, mazeStore: mazeStore)
                // BUG 2 fix (manual-mode elevator Change Picture), Sept
                // 26: same "zero-size host, own confirmationDialog"
                // shape as PictureChangeMenuHost just above, but keyed
                // on activeElevatorPictureMenu instead of
                // activePictureMenu -- see that view's own doc comment.
                ElevatorPictureChangeMenuHost(controller: navController, mazeStore: mazeStore)
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
                // Oct 8 (Developer/Release separation): the Decorator is a
                // developer-workshop tool, never a player feature -- the
                // DECORATE pill and + ADD menu don't exist in Release.
                if !showIntroScreen && BuildMode.developerTools {
                    DecoratorOverlay(state: decorator, store: mazeStore)
                        .zIndex(36)
                        // Sept 28: re-render the Decorator's "+" menu
                        // availability as the player moves -- see
                        // DecoratorState.observedPlayerCell.
                        .onReceive(navController.$currentCell) { decorator.playerCellDidChange($0) }
                        .onReceive(navController.$facing) { decorator.playerFacingDidChange($0) }
                    // Oct 8: the player mini-map (HandheldMapOverlay) is retired
                    // from the HUD -- the phone's Building GPS will take its place.
                    // Its view code, HandheldMapGeometry (still used by the floor
                    // pill and DECORATE layout), the controller's handheld-map API
                    // and the floor-map renderer are all kept for that.
                }
                PlayerSettingsButton(store: mazeStore, onStartOver: { startOver(source: "settings") })
            }

            // Unconditional, unlike the overlays above -- it has to
            // keep existing (and keep its own @State) straight through
            // the moment navBridge.controller goes nil and comes back
            // as a different instance, or the reopening animation it's
            // in the middle of gets torn down along with the old
            // controller. See NavigationBridge.floorTransitionRequested.
            ElevatorCurtainOverlay(navBridge: navBridge)

            // Oct 21 -- the phone is retired: Building Life's bottom tray (see
            // BuildingLifeTray.swift) in the place the phone's host had --
            // outside the controller-dependent overlays so it survives
            // floor/controller replacement; above the gameplay overlays, but it
            // only ever covers its tab or the tray itself -- every other touch
            // still reaches Hallways. Put away while decorating, as the phone was.
            if !showIntroScreen && !decorator.enabled {
                BuildingLifeTray(navBridge: navBridge, mazeStore: mazeStore)
                    .zIndex(45)
                // Oct 23 -- a tapped critter's menu (CritterMenu.swift): only its card
                // takes touches; under the tray, so an opened tray is never covered.
                CritterMenuOverlay()
                    .zIndex(44)
            }

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
                        // Oct 5: hasCompletedInitialEntrance is no longer
                        // written here (at the front door); it becomes true
                        // when Administration is first reached (installScene),
                        // and it now drives the mid-prologue launch resume.
                        navBridge.controller?.advance(source: "CEREMONIAL")
                    }
                }
                // Oct 24: the speaker button on the street screen too (the
                // street traffic plays here). The same button as the HUD's,
                // top right inside the safe area; an overlay above the
                // screen, so its tap never reaches "tap anywhere to enter".
                .overlay(alignment: .topTrailing) {
                    HallwaysMuteButton()
                        .padding()
                }
                .transition(.opacity)
                .zIndex(10)
            }

            VStack {
                // Oct 3 (Build 8): variable-width inventory must never move
                // the fixed controls. Money + the Reset/Map buttons keep
                // their natural size at higher layout priority; the
                // inventory pill gets whatever width is left and scrolls
                // inside it when it can't fit (see CarriedItemsPill). The
                // row as a whole can therefore never exceed the screen --
                // it used to, because the pill was .fixedSize(), and an
                // overflowing HStack spills off BOTH edges.
                HStack(spacing: 8) {
                    // Oct 10: the FLOOR N pill lives here now, top-left (it
                    // used to sit at the bottom centre, where the walk
                    // buttons are). The top row is inside the safe area, so
                    // it stays below the status bar / Dynamic Island.
                    if let controller = navBridge.controller, !showIntroScreen {
                        Text(controller.floorLabel)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.62), in: Capsule())
                            .fixedSize()
                            .layoutPriority(2)
                            .accessibilityIdentifier("gameplayFloorLabel")
                    }
                    // Oct 4: the old money total and mission/inventory progress
                    // pill are retired from the screen (the game is no longer
                    // economy/mission driven). Their state is untouched;
                    // ContentView.showsLegacyHUD = true brings both back.
                    if Self.showsLegacyHUD {
                        moneyHUD
                            .fixedSize()
                            .layoutPriority(2)
                    }
                    // Sept 26 (intro-HUD leak fix): mission-progress
                    // pills (e.g. "Painted 0/51") must not render on the
                    // intro screen either -- same gate as DecoratorOverlay/
                    // HandheldMapOverlay above.
                    if Self.showsLegacyHUD, let controller = navBridge.controller, !showIntroScreen {
                        CarriedItemsPill(controller: controller)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        // Oct 8: the permanent player control. The labeled
                        // controls beside it are the Debug workshop's.
                        HallwaysMuteButton()
                        // Oct 8 (Developer/Release separation): three distinct,
                        // labeled developer actions -- no single ambiguous Reset.
                        //   START OVER  the shared story reset (same as Settings)
                        //   LOBBY       back to Floor 1, story untouched
                        //   DEV MAP     the grid editor: floor transport + editing
                        // None of them exist in Release.
                        #if DEBUG
                        if BuildMode.developerTools {
                            DevHUDButton(systemImage: "arrow.counterclockwise", caption: "START OVER") {
                                showStartOverConfirmation = true
                            }
                            .alert(StartOver.confirmationTitle, isPresented: $showStartOverConfirmation) {
                                Button("Cancel", role: .cancel) {}
                                Button(StartOver.confirmButtonTitle, role: .destructive) { startOver(source: "devHUD") }
                            } message: {
                                Text(StartOver.confirmationMessage)
                            }
                            DevHUDButton(systemImage: "arrow.down.to.line", caption: "LOBBY") {
                                devReturnToLobby()
                            }
                            DevHUDButton(systemImage: "map", caption: "DEV MAP") {
                                showGridEditor = true
                            }
                        }
                        #endif
                    }
                    .fixedSize()
                    .layoutPriority(2)
                }
                Spacer()
            }
            .padding()
            // Oct 18 (DEBUG): the residents' live readout in the controlled test
            // (-HallwaysLifeTest N) or with -HallwaysLifePanel YES. Never in Release.
            if LifePanel.enabled && !showIntroScreen {
                LifeTestOverlay()
                    .zIndex(9000)
            }
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
            // Release: the grid editor / floor transport is unreachable.
            if showing && !BuildMode.developerTools { showGridEditor = false; return }
            if showing { decorator.enabled = false }
        }
        .fullScreenCover(isPresented: $showGridEditor, onDismiss: {
            // Draw -> dismiss -> walk it: the 3D scene only rebuilds now,
            // from whatever is currently painted, not mid-drag.
            //
            // Oct 5 (persistent SCNView): nothing to do here beyond
            // saving. mazeStore.version already changed while the editor
            // was up, and HallwaySceneView.updateUIView watches exactly
            // that -- it installs the new scene into the SAME mounted
            // TouchTrackingSCNView on the next main-loop turn. This
            // handler used to null navBridge.controller and bump the old
            // sceneVersion state to force SwiftUI's .id() to tear the view
            // down; that state is gone, and the controller is republished by
            // installScene itself, so nulling it here would only punch a
            // hole in the D-pad (the very bug the old version-compare
            // guard was working around).
            mazeStore.save()
        }) {
            GridEditorView(mazeStore: mazeStore, themeStore: themeStore, youAreHere: navBridge.controller?.currentCell, youAreHereFacing: navBridge.controller?.facing, youAreHereMazeID: navBridge.controller != nil ? mazeStore.currentMazeID : nil,
                           youAreHereSpot: navBridge.controller.map { CGPoint(x: CGFloat($0.cameraNode.position.x) / mazeStore.cellSize,
                                                                              y: CGFloat($0.cameraNode.position.z) / mazeStore.cellSize) },
                           youAreHereYaw: navBridge.controller.map { Double($0.cameraNode.eulerAngles.y) },
                           devNewEmployeeAtAdministration: {
                               #if DEBUG
                               jumpToAdministrationAsNewEmployee()
                               #endif
                           })
        }
        // Oct 5 (persistent SCNView): this used to bump a sceneVersion
        // @State whose .id() modifier destroyed and rebuilt the whole
        // TouchTrackingSCNView on every floor switch — the elevator
        // handoff's white/slide artifacts came from that teardown. The
        // rebuild is now driven entirely by mazeStore.version, watched in
        // HallwaySceneView.updateUIView, so this observer is logging only.
        // It deliberately does NOT null navBridge.controller: installScene
        // republishes it, and a nil window here would flicker the D-pad.
        .onChange(of: mazeStore.currentMazeID) { _ in
            let traceChange = ElevatorArrivalTrace.shared.beginPhase("ContentView.floorOnChange")
            defer { ElevatorArrivalTrace.shared.endPhase("ContentView.floorOnChange", traceChange) }
            diag("scene.floorChanged", ["floor": mazeStore.currentMazeID, "mazeVersion": mazeStore.version])
            // Oct 8 (Phase 1): arriving on a floor is a natural moment to check.
            if !showIntroScreen { BuildingDispatch.evaluate(reason: "floorArrival") }
            navLog("[PERSISTENTVIEW] floor changed -> \(mazeStore.currentMazeID), mazeStore.version \(mazeStore.version) -- the mounted TouchTrackingSCNView keeps its gestures; only its scene/controller contents are reinstalled")
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
    @ObservedObject private var toolTray = ToolTray.shared             // Oct 16 (V): the status line sits above the tray

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
            // Oct 10 (continuous walk): the FLOOR N pill moved to the top-left
            // of the top HUD row (ContentView, FloorLabelPill); this line keeps
            // the status message clear of the WALK/LEFT/RIGHT row below it.
            if TapNavigationController.continuousWalkExperimentOn {
                Color.clear.frame(height: ContinuousWalkControls.rowHeight + ContinuousWalkControls.bottomPadding + 10)
            }
            if toolTray.isShowing {                                             // (Oct 19: no gap for an empty, hidden tray)
                Color.clear.frame(height: ToolTrayView.slot + 12 + 8)      // (the tray's own strip)
            }
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
        .offset(y: HandheldMapGeometry.floorPillOffsetY)
      
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
            // Oct 3 (Build 8): natural width when it fits the space the top
            // row leaves it; otherwise the same chips scroll horizontally
            // inside the same capsule. Never wider than that space, so the
            // fixed Reset/Map controls stay put however much is carried.
            ViewThatFits(in: .horizontal) {
                chips
                ScrollView(.horizontal, showsIndicators: false) { chips }
                    .fixedSize(horizontal: false, vertical: true) // never grow taller than the chips
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.7), in: Capsule())
            .clipShape(Capsule())
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(Array(controller.collectedObjects.enumerated()), id: \.offset) { _, kind in
                Text(kind.displayEmoji).font(.system(size: 22))
            }
            if let progress = controller.paintProgress {
                Text(progress).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            if controller.carryingExtinguisher {
                // Oct 3 (Build 8): emoji only -- no "Extinguisher" label.
                Text("🧯")
                    .font(.system(size: 17, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Fire extinguisher")
            }
            ForEach(controller.carriedMail) { letter in
                // Sept 26: room number only. Oct 3 (Build 8): envelope icon
                // removed too -- the brown chip already says "mail".
                Text("\(letter.roomNumber)")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.brown.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Mail for room \(letter.roomNumber)")
            }
        }
        .fixedSize()
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
        let traceBody = ElevatorArrivalTrace.shared.beginPhase("curtain.body")
        defer { ElevatorArrivalTrace.shared.endPhase("curtain.body", traceBody) }
        return GeometryReader { geo in
            if navBridge.arrivalWasControlled {
                // Driven by handoff state itself: cover the identity replacement,
                // even before the event's onChange has set local `visible`.
                if !navBridge.controlledArrivalFrameReady, let snapshot = navBridge.doorSnapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .onAppear { ElevatorArrivalTrace.shared.event("snapshot.swiftUIAppeared") }
                        .onDisappear { ElevatorArrivalTrace.shared.event("snapshot.swiftUIDisappeared") }
                }
            } else if visible {
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
        .allowsHitTesting(false)
        .transaction { transaction in
            if navBridge.arrivalWasControlled {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onChange(of: navBridge.controlledArrivalFrameReady) { ready in
            guard ready, navBridge.arrivalWasControlled, navBridge.arrivalSceneReady,
                  navBridge.controller != nil else { return }
            // Readiness, not a timer, starts the real arrival choreography.
            ElevatorArrivalTrace.shared.event("ding.triggered")
            diag("curtain.arrivalDing")
            SoundEffects.playElevatorArrival()
            SoundEffects.stopElevatorMusic()
            navBridge.controller?.playArrivalLightWash(openingDuration: RocketElevator.rideIsRocket ? RocketElevator.doorOpen : 1.6)
            navBridge.deliverControlledArrivalDoorOpen()
            visible = false
        }
        .onChange(of: navBridge.floorTransitionRequested) { event in
            let traceChange = ElevatorArrivalTrace.shared.beginPhase("curtain.transitionOnChange")
            defer { ElevatorArrivalTrace.shared.endPhase("curtain.transitionOnChange", traceChange) }
            guard event != nil else { return }
            openFraction = 0
            visible = true
            diag("curtain.shown", ["controlled": navBridge.arrivalWasControlled, "snapshotPresent": navBridge.doorSnapshot != nil])
            if navBridge.arrivalWasControlled { return }
            // A brief beat so mazeStore.advanceToNextMaze() (called by
            // the controller right alongside this same event) actually
            // swaps in and settles behind this fully-closed curtain
            // before it starts sliding open -- otherwise the open
            // animation would start revealing a stale frame of the OLD
            // floor for an instant.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                diag("curtain.arrivalDing")
                SoundEffects.playElevatorArrival()
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
                    let waitStarted = Date()
                    let controlled = navBridge.arrivalWasControlled
                    elevatorLog("arrival curtain waiting -- \(controlled ? "controlled" : "passive") arrival")
                    navBridge.diagSnapshot("curtainWaitBegin")
                    // Flight recorder only: a poll line on any state change
                    // or every ~0.5 s of waiting -- never every 30 ms poll.
                    var lastPollLog = Date.distantPast
                    var lastPollState = ""
                    func openWhenSceneReady() {
                        let decision = NavigationBridge.arrivalCurtainDecision(
                            controlled: controlled,
                            sceneReady: navBridge.arrivalSceneReady,
                            controllerReady: navBridge.controller != nil,
                            elapsed: Date().timeIntervalSince(waitStarted))
                        let pollState = "\(navBridge.arrivalSceneReady)/\(navBridge.controller != nil)/\(decision)"
                        if pollState != lastPollState || Date().timeIntervalSince(lastPollLog) >= 0.5 {
                            lastPollLog = Date()
                            lastPollState = pollState
                            diag("curtain.poll", ["elapsed": Date().timeIntervalSince(waitStarted), "decision": "\(decision)",
                                                  "sceneReady": navBridge.arrivalSceneReady,
                                                  "controllerPresent": navBridge.controller != nil, "controlled": controlled])
                        }
                        // A timeout must not open the real doors behind a still-frozen
                        // controlled bridge. Reveal the first frame before opening them.
                        if decision == .wait || (controlled && !navBridge.controlledArrivalFrameReady) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                                openWhenSceneReady()
                            }
                            return
                        }
                        if decision == .openAfterTimeout {
                            // Fail OPEN: never leave the player behind the curtain.
                            elevatorLog("arrival curtain TIMEOUT after \(NavigationBridge.arrivalCurtainTimeout)s -- opening anyway (controlled=\(controlled), sceneReady=\(navBridge.arrivalSceneReady), controller=\(navBridge.controller != nil))")
                        } else {
                            elevatorLog("arrival curtain released normally after \(String(format: "%.2f", Date().timeIntervalSince(waitStarted)))s (controlled=\(controlled), controller=\(navBridge.controller != nil))")
                        }
                        // Sept 14 (Eddie): "keep the elevator music playing
                        // continuously while the doors remain closed... stop
                        // it at the moment the doors START to open." Moved
                        // here from TapNavigationController.playElevatorRide
                        // (previously stopped right after the 180 pivot) --
                        // this is the exact instant the doors begin sliding
                        // apart, right after the existing arrival ding-dong
                        // above; that ding-dong's own timing is untouched.
                        navBridge.diagSnapshot("curtainRelease")
                        SoundEffects.stopElevatorMusic()
                        navBridge.controller?.playArrivalLightWash(openingDuration: controlled ? 1.6 : 1.0)
                        // Eddie, Sept 16 (spatially-truthful controlled
                        // arrival): the instant this fade starts
                        // revealing a controlled arrival, tell the
                        // (brand new, already-built) destination
                        // controller to actually animate its real 3D
                        // doors open -- see playControlledArrivalDoorOpen()'s
                        // own comment. No-op for a passive arrival,
                        // whose doors were already opened, instantly,
                        // back in presentArrivalInsideElevator.
                        // Oct 2: delivered now if the controller exists (always,
                        // on the normal path), otherwise deferred to the moment
                        // makeUIView publishes it -- never silently dropped.
                        if controlled {
                            navBridge.deliverControlledArrivalDoorOpen()
                        }
                        withAnimation(.easeInOut(duration: 1.0)) {
                            openFraction = 1
                        }
                        diag("curtain.openingStarted")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                            visible = false
                            diag("curtain.hidden", ["note": "arrival complete"])
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
/// Oct 5 (elevator staging): one destination floor prepared during an
/// elevator ride -- built and GPU-prepared, but never presented, until
/// installScene activates it at arrival.
final class StagedElevatorDestination {
    let floor: Int
    let content: MazeStore.FloorContent
    let pressedAt = Date()
    var build: HallwayScene.MazeBuildResult?
    var livingWorld: LivingWorld.StagedFloor?
    var prepareFinished = false
    var prepareSucceeded = false
    var cancelled = false
    /// Oct 24 (onboarding polish): started before the press (Admission's first ride).
    var foreseen = false
    /// Picture-identity reports from the staged scene (some arrive later,
    /// from Photos). Its own object so the scene's closures never retain
    /// this staging (or, through it, the scene itself).
    let reports: StagedPictureIdentityReports
    private var completionWaiters: [() -> Void] = []

    init(floor: Int, content: MazeStore.FloorContent, mazeStore: MazeStore) {
        self.floor = floor
        self.content = content
        self.reports = StagedPictureIdentityReports(mazeStore: mazeStore)
    }

    var isComplete: Bool { build != nil && livingWorld != nil && prepareFinished }

    func ms(since date: Date) -> Int { Int((Date().timeIntervalSince(date) * 1000).rounded()) }

    /// Arrival (after switchTo): replays the buffered reports onto the store.
    func activate() { reports.activate() }

    func whenComplete(_ action: @escaping () -> Void) {
        if isComplete { action() } else { completionWaiters.append(action) }
    }

    func markComplete() {
        let waiters = completionWaiters
        completionWaiters = []
        waiters.forEach { $0() }
    }
}

/// MazeStore picture-identity reports made while a staged floor is built.
/// Held until arrival so the live source floor's published identities are
/// not overwritten mid-ride; after arrival they pass straight through.
final class StagedPictureIdentityReports {
    private weak var mazeStore: MazeStore?
    private var activated = false
    private var pending: [(MazeStore) -> Void] = []

    init(mazeStore: MazeStore) { self.mazeStore = mazeStore }

    func report(_ apply: @escaping (MazeStore) -> Void) {
        if activated, let mazeStore { apply(mazeStore) } else if !activated { pending.append(apply) }
    }

    func activate() {
        activated = true
        let replay = pending
        pending = []
        if let mazeStore { replay.forEach { $0(mazeStore) } }
    }
}

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
        let traceMake = ElevatorArrivalTrace.shared.beginPhase("SCNView.makeUIView")
        defer { ElevatorArrivalTrace.shared.endPhase("SCNView.makeUIView", traceMake) }
        let view = TouchTrackingSCNView()
        context.coordinator.lastBuiltMazeVersion = mazeStore.version
        installScene(in: view, context: context)
        return view
    }

    // Oct 5 (elevator staging): "let the elevator ride pay for the loading
    // time." Runs when a valid floor button is pressed. Builds the destination
    // floor's scene, floor glow and LivingWorld population into a NEW,
    // not-yet-presented SCNScene, then has SceneKit prepare it in the
    // background -- all while the source cab stays the live, interactive
    // world (view.scene, pointOfView, delegate, navController, LivingWorld's
    // live lists, Posse/Freddy and every published bridge value untouched).
    // Main-thread work is split into separate main-queue turns so touches and
    // frames get through between the chunks. installScene consumes the
    // result at arrival (see takeStagedElevatorDestination).
    private func stageElevatorDestination(floor: Int, view: TouchTrackingSCNView, coordinator: Coordinator) {
        coordinator.stagedElevatorDestination?.cancelled = true
        coordinator.stagedElevatorDestination = nil
        guard floor != mazeStore.currentMazeID,
              let content = mazeStore.stagedFloorContent(id: floor),
              let ends = content.startAndEnd else {
            diag("elevator.staging.skipped", ["to": floor, "from": mazeStore.currentMazeID])
            return
        }
        let staged = StagedElevatorDestination(floor: floor, content: content, mazeStore: mazeStore)
        coordinator.stagedElevatorDestination = staged
        // Captured now: the cab's artwork is the same at press and at arrival.
        let sourceArtwork = view.scene.map { HallwayScene.elevatorArtwork(in: $0) } ?? [:]
        let theme = themeStore.current
        let cellSize = mazeStore.cellSize
        let wallHeight = mazeStore.wallHeight
        let totalFloors = mazeStore.floorCount
        let cabDecoration = mazeStore.elevatorCabDecoration
        diag("elevator.staging.begin", ["to": floor])
        func stillWanted(_ coordinator: Coordinator?) -> Bool {
            guard let coordinator else { return false }
            return coordinator.stagedElevatorDestination === staged && !staged.cancelled
        }
        // Chunk 1 (one main turn later, after the press has rendered):
        // HallwayScene construction -- materials, static objects, pictures --
        // plus this floor's floor-glow sequences.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak view, weak coordinator] in
            guard view != nil, stillWanted(coordinator) else { return }
            let c = staged.content
            let start = ends.start
            let end = ends.end
            let worldMissionSigns = TapNavigationController.missionPlaquesInWorld ? c.missionSigns : [:]
            let buildStarted = Date()
            let reports = staged.reports
            let result = HallwayScene.build(fromMaze: c.cells, cellSize: cellSize, wallHeight: wallHeight, objects: c.objects, destinations: c.destinations, exitSigns: c.exitSigns, floorMaps: c.floorMaps, spotlights: c.spotlights, missionSigns: worldMissionSigns, pictures: c.pictures, mirrors: c.mirrors, wallLights: c.wallLights, bathroomDoors: c.bathroomDoors, windowRooms: c.windowRooms, roomEntranceDoors: c.roomEntranceDoors, fires: c.fires, extinguishers: c.extinguishers, photoBooths: c.photoBooths, ticTacToeTerminals: c.ticTacToeTerminals, shellGameStations: c.shellGameStations, rockPaperScissorsTerminals: c.rockPaperScissorsTerminals, higherLowerTerminals: c.higherLowerTerminals, fiveCardDrawTerminals: c.fiveCardDrawTerminals, simonTerminals: c.simonTerminals, hangmanTerminals: c.hangmanTerminals, connectFourTerminals: c.connectFourTerminals, checkersTerminals: c.checkersTerminals, woidleTerminals: c.woidleTerminals, picturesUseCameraRoll: c.picturesUseCameraRoll, roomDoors: c.roomDoors, itemRooms: c.itemRooms, missionHeading: c.missionHeading, missionBody: c.missionBody, missionObjectKind: c.missionObjectKind, floorNumber: floor, totalFloors: totalFloors, playerStart: start, playerEnd: end, theme: theme, wallTexture: c.wallTexture, floorTexture: c.floorTexture, ceilingTexture: c.ceilingTexture, elevatorArtwork: sourceArtwork, fluorescentLights: c.fluorescentLights, ceilingVisibleFixture: c.ceilingVisibleFixture, pictureLights: c.pictureLights, lightBrightness: c.lightBrightness, pictureImageSelections: c.pictureImageSelections, elevatorCabDecoration: cabDecoration, floorObjectPlacements: c.floorObjectPlacements, tables: c.tables, desks: c.desks, waterCoolers: c.waterCoolers, officeChairs: c.officeChairs, floorLamps: c.floorLamps, aquariums: c.aquariums, filingCabinets: c.filingCabinets, cellSurfaces: c.cellSurfaces, clocks: c.clocks, reportPictureIdentity: { face, selection in reports.report { $0.reportCurrentPictureIdentity(selection, at: face) } }, reportElevatorBackIdentity: { selection in reports.report { $0.reportCurrentElevatorBackIdentity(selection) } }, reportElevatorSideIdentity: { selection in reports.report { $0.reportCurrentElevatorSideIdentity(selection) } }, reportElevatorSideRightIdentity: { selection in reports.report { $0.reportCurrentElevatorSideRightIdentity(selection) } })
            HallwayScene.installFloorGlowSequences(c.floorGlowSequences, cells: c.cells, root: result.scene.rootNode)
            if floor == AdministrationReception.floor {
                AdministrationReception.install(into: result.scene.rootNode, cellSize: cellSize, cells: c.cells)
            }
            if floor == PlayerOffice.floor {                               // Oct 6: the player's office
                PlayerOffice.install(into: result.scene.rootNode, cellSize: cellSize, cells: c.cells)
            }
            if floor == ConferenceRoom.floor {                             // Oct 8: the conference room
                ConferenceRoom.install(into: result.scene.rootNode, cellSize: cellSize, cells: c.cells)
            }
            if floor == SuppliesShowroom.floor {                           // Oct 16: Floor 4, SUPPLIES
                SuppliesShowroom.install(into: result.scene.rootNode, cellSize: cellSize, cells: c.cells)
            }
            if floor == FloorFiveBlackout.floor {                          // Oct 16 (VIII): Floor 5, LIGHTS OUT
                FloorFiveBlackout.install(into: result.scene.rootNode, cellSize: cellSize, cells: c.cells)
            }
            staged.build = result
            diag("elevator.staging.sceneBuilt", ["to": floor, "chunkMs": staged.ms(since: buildStarted), "sincePressMs": staged.ms(since: staged.pressedAt)])
            // Chunk 2: the LivingWorld population (Menagerie + Bobbins) into
            // the staged scene, kept off LivingWorld's live lists.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak view, weak coordinator] in
                guard let view, stillWanted(coordinator) else { return }
                let livingStarted = Date()
                let scene = result.scene
                let cameraNode = result.cameraNode
                var bobbinDoors: [(GridCoordinate, Direction)] = c.bathroomDoors.map { ($0.key, $0.value) }
                bobbinDoors += c.windowRooms.map { ($0.key, $0.value.direction) }
                bobbinDoors += c.roomEntranceDoors.map { ($0.key, $0.value.direction) }
                var dweezilLit = Set(c.fluorescentLights.keys)
                dweezilLit.formUnion(c.spotlights)
                var dweezilBusy = Set(c.objects.keys)
                dweezilBusy.formUnion(c.destinations.keys)
                dweezilBusy.formUnion(c.roomDoors.keys)
                dweezilBusy.formUnion(c.fires)
                dweezilBusy.formUnion(c.extinguishers.keys)
                dweezilBusy.formUnion(c.photoBooths.keys)
                dweezilBusy.formUnion(c.mirrors.keys)
                dweezilBusy.formUnion(c.floorMaps.keys)
                dweezilBusy.formUnion(c.missionSigns.keys)
                dweezilBusy.formUnion(c.pictures.keys.map { $0.coord })
                for games in [c.ticTacToeTerminals, c.shellGameStations, c.rockPaperScissorsTerminals,
                              c.higherLowerTerminals, c.fiveCardDrawTerminals, c.simonTerminals,
                              c.hangmanTerminals, c.connectFourTerminals, c.checkersTerminals,
                              c.woidleTerminals] {
                    dweezilBusy.formUnion(games.keys)
                }
                // Oct 11 (the staff meeting): the conference room is a directed
                // scene -- the floor's free-roaming population stays out of it.
                // Oct 12: ...and the player's own office is theirs (Harold's) -- no roaming population in it.
                let livingCells = floor == ConferenceRoom.floor
                    ? c.cells.subtracting(ConferenceRoom.roomCells).subtracting(PlayerOffice.officeCells) : c.cells
                let livingCellSize = cellSize
                // Oct 5 (Admission): no Bobbin in Administration during admission.
                let holdBobbins = Admission.isPending && floor == Admission.administrationFloor
                // Oct 5 (clean onboarding): no living population at all on a quiet onboarding floor.
                let quietDestination = Admission.isCritterFree(floor: floor)
                staged.livingWorld = LivingWorld.stageFloor { [weak view, weak scene, weak cameraNode] in
                    guard let view, let scene, let cameraNode, !quietDestination else { return }
                    let dweezilCage = Menagerie.install(in: view, scene: scene, playerCamera: cameraNode, cells: livingCells,
                                                        cellSize: livingCellSize, doors: bobbinDoors, litCells: dweezilLit,
                                                        busyCells: dweezilBusy, floor: floor)          // Oct 16: (the Big Shot's floor)
                    var bobbinCells = livingCells
                    if let dweezilCage { bobbinCells.remove(dweezilCage) }
                    if !holdBobbins {
                        Bobbin.install(in: view, scene: scene, playerCamera: cameraNode, cells: bobbinCells,
                                       cellSize: livingCellSize, doors: bobbinDoors)
                    }
                }
                diag("elevator.staging.livingWorld", ["to": floor, "chunkMs": staged.ms(since: livingStarted), "sincePressMs": staged.ms(since: staged.pressedAt)])
                // Chunk 3: SceneKit GPU preparation of the NOT-presented staged
                // scene, on SceneKit's own background queue. Nothing mutates
                // the staged scene again until this completes.
                let prepareStarted = Date()
                view.prepare([scene]) { prepared in
                    DispatchQueue.main.async {
                        staged.prepareFinished = true
                        staged.prepareSucceeded = prepared
                        diag("elevator.staging.complete", ["to": floor, "prepared": prepared,
                                                           "prepareMs": staged.ms(since: prepareStarted),
                                                           "sincePressMs": staged.ms(since: staged.pressedAt)])
                        staged.markComplete()
                    }
                }
            }
        }
    }

    // Oct 5: floor changes no longer replace the UIKit/SceneKit view.
    // The TouchTrackingSCNView and its gesture recognizers stay mounted; only
    // the SceneKit scene/controller contents are rebuilt in place.
    private func installScene(in view: TouchTrackingSCNView, context: Context) {
        let tracePhase = ElevatorArrivalTrace.shared.beginPhase("scene.install")
        defer { ElevatorArrivalTrace.shared.endPhase("scene.install", tracePhase) }
        let controlledArrival = navBridge.pendingElevatorArrival && navBridge.pendingArrivalYaw != nil
        let arrivalEvent = navBridge.floorTransitionRequested
        // Oct 17 (Decorate teleport fix): a Decorate edit that changes the floor's
        // data (adding a Picture, a light, a surface...) bumps mazeStore.version,
        // which rebuilds this floor -- and a rebuild starts the player at the
        // floor's spawn (on Floors 2+, the elevator). For a same-floor rebuild
        // while decorating, keep the player's exact spot and yaw, put back below
        // through the SAME resume(at:) a relaunch uses. Never for an elevator
        // arrival, a floor switch, or the forced (dev reset) rebuild.
        let keptDecoratePose: ResumeState.Point? = {
            guard decorator.enabled, !navBridge.pendingElevatorArrival, !context.coordinator.forcedRebuild,
                  let old = context.coordinator.navigationController,
                  old.currentFloorNumber == mazeStore.currentMazeID else { return nil }
            let p = old.cameraNode.position
            return ResumeState.Point(floor: mazeStore.currentMazeID, x: p.x, z: p.z, yaw: old.cameraNode.eulerAngles.y)
        }()
        context.coordinator.forcedRebuild = false
        // Oct 2: flight recorder (logging only).
        DiagnosticRecorder.shared.floor = mazeStore.currentMazeID
        let diagBuildStarted = Date()
        diag("scene.makeUIView.begin", ["floor": mazeStore.currentMazeID, "pendingElevatorArrival": navBridge.pendingElevatorArrival,
                                        "cellsEmpty": mazeStore.cells.isEmpty])

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
            navLog("[LIGHTBUILD #\(lightBuildNumber)] BEGIN scene install floor=\(mazeStore.currentMazeID) pendingElevatorArrival=\(navBridge.pendingElevatorArrival) -- a brand-new scene + navigation controller are constructed for this rebuild and installed into the mounted TouchTrackingSCNView (which keeps its gesture recognizers; see the [PERSISTENTVIEW] lines for WHY this rebuild started)")
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
            let start = mazeStore.startCoordinate ?? GridCoordinate(row: 0, col: 0)
            let end = mazeStore.endCoordinate ?? start
            // Oct 11 (resume): what the player already collected / put out on
            // this floor stays gone (ResumeState). The authored floor data in
            // MazeStore -- and mazes.json -- is never touched.
            let liveObjects = ResumeState.unconsumed(objects: mazeStore.objects, floor: mazeStore.currentMazeID)
            let liveFires = ResumeState.unconsumed(fires: mazeStore.fires, floor: mazeStore.currentMazeID)
            // Oct 4: player-facing mission plaques are retired from the playable
            // world (data kept; TapNavigationController.missionPlaquesInWorld).
            let worldMissionSigns = TapNavigationController.missionPlaquesInWorld ? mazeStore.missionSigns : [:]
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
            ElevatorArrivalTrace.shared.event("HallwayScene.build.begin")
            // Oct 5 (elevator staging): a ride's destination arrives already built and prepared.
            let stagedArrival = context.coordinator.takeStagedElevatorDestination(for: mazeStore.currentMazeID, arriving: navBridge.pendingElevatorArrival)
            let hallwaySceneBuildResult: HallwayScene.MazeBuildResult
            if let stagedArrival, let stagedBuild = stagedArrival.build {
                hallwaySceneBuildResult = stagedBuild
                stagedArrival.activate()
                ElevatorArrivalTrace.shared.event("HallwayScene.build.staged", "sincePressMs=\(stagedArrival.ms(since: stagedArrival.pressedAt))")
            } else {
                hallwaySceneBuildResult = HallwayScene.build(fromMaze: mazeStore.cells, cellSize: mazeStore.cellSize, wallHeight: mazeStore.wallHeight, objects: liveObjects, destinations: mazeStore.destinations, exitSigns: mazeStore.exitSigns, floorMaps: mazeStore.floorMaps, spotlights: mazeStore.spotlights, missionSigns: worldMissionSigns, pictures: mazeStore.pictures, mirrors: mazeStore.mirrors, wallLights: mazeStore.wallLights, bathroomDoors: mazeStore.bathroomDoors, windowRooms: mazeStore.windowRooms, roomEntranceDoors: mazeStore.roomEntranceDoors, fires: liveFires, extinguishers: mazeStore.extinguishers, photoBooths: mazeStore.photoBooths, ticTacToeTerminals: mazeStore.ticTacToeTerminals, shellGameStations: mazeStore.shellGameStations, rockPaperScissorsTerminals: mazeStore.rockPaperScissorsTerminals, higherLowerTerminals: mazeStore.higherLowerTerminals, fiveCardDrawTerminals: mazeStore.fiveCardDrawTerminals, simonTerminals: mazeStore.simonTerminals, hangmanTerminals: mazeStore.hangmanTerminals, connectFourTerminals: mazeStore.connectFourTerminals, checkersTerminals: mazeStore.checkersTerminals, woidleTerminals: mazeStore.woidleTerminals, picturesUseCameraRoll: mazeStore.picturesUseCameraRoll, roomDoors: mazeStore.roomDoors, itemRooms: mazeStore.itemRooms, missionHeading: mazeStore.missionHeading, missionBody: mazeStore.missionBody, missionObjectKind: mazeStore.missionObjectKind, floorNumber: mazeStore.currentMazeID, totalFloors: mazeStore.floorCount, playerStart: start, playerEnd: end, theme: themeStore.current, wallTexture: mazeStore.wallTexture, floorTexture: mazeStore.floorTexture, ceilingTexture: mazeStore.ceilingTexture, elevatorArtwork: navBridge.pendingElevatorArrival ? navBridge.pendingElevatorArtwork : [:], fluorescentLights: mazeStore.fluorescentLights, ceilingVisibleFixture: mazeStore.ceilingVisibleFixture, pictureLights: mazeStore.pictureLights, lightBrightness: mazeStore.lightBrightness, pictureImageSelections: mazeStore.pictureImageSelections, elevatorCabDecoration: mazeStore.elevatorCabDecoration, floorObjectPlacements: mazeStore.floorObjectPlacements, tables: mazeStore.tables, desks: mazeStore.desks, waterCoolers: mazeStore.waterCoolers, officeChairs: mazeStore.officeChairs, floorLamps: mazeStore.floorLamps, aquariums: mazeStore.aquariums, filingCabinets: mazeStore.filingCabinets, cellSurfaces: mazeStore.cellSurfaces, clocks: mazeStore.clocks, reportPictureIdentity: { [weak mazeStore] face, selection in mazeStore?.reportCurrentPictureIdentity(selection, at: face) }, reportElevatorBackIdentity: { [weak mazeStore] selection in mazeStore?.reportCurrentElevatorBackIdentity(selection) }, reportElevatorSideIdentity: { [weak mazeStore] selection in mazeStore?.reportCurrentElevatorSideIdentity(selection) }, reportElevatorSideRightIdentity: { [weak mazeStore] selection in mazeStore?.reportCurrentElevatorSideRightIdentity(selection) })
            }
            ElevatorArrivalTrace.shared.event("HallwayScene.build.end")
            navBridge.pendingElevatorArtwork = [:]
            let (scene, cameraNode, _, wallMaterials, floorMaterial, ceilingMaterial, objectNodes, destinationNodes, fireNodes, extinguisherNodes, photoBoothNodes, ticTacToeTerminalNodes, shellGameStationNodes, rockPaperScissorsTerminalNodes, higherLowerTerminalNodes, fiveCardDrawTerminalNodes, simonTerminalNodes, hangmanTerminalNodes, connectFourTerminalNodes, checkersTerminalNodes, woidleTerminalNodes, elevatorDoors, _, floorMapPlaneNodes, pictureMaterials) = hallwaySceneBuildResult
            // Oct 8 (Floor 1 elevator return): an elevator arrival enters at
            // the elevator. `start` stays the floor's own spawn for the BUILD
            // (on Floor 1 it also places the front doors' inside face), but
            // the player -- camera, current cell, followers -- starts at the
            // elevator cell, exactly as on every other floor (where the two
            // are the same cell). Before this, a lobby return opened the cab
            // around the front-door cell, so the doors, the exit walk and the
            // turn-to-doors all pointed at the entrance.
            let playerStart = mazeStore.spawnCoordinate(arrivingByElevator: navBridge.pendingElevatorArrival) ?? start
            let playerFacing = playerStart == start ? facing : startingFacing(at: playerStart, cells: mazeStore.cells)
            if playerStart != start {
                SCNTransaction.begin()
                SCNTransaction.disableActions = true
                cameraNode.position = SCNVector3(Float(CGFloat(playerStart.col) * mazeStore.cellSize), cameraNode.position.y,
                                                 Float(CGFloat(playerStart.row) * mazeStore.cellSize))
                cameraNode.eulerAngles = SCNVector3(0, Float(playerFacing.yaw), 0)
                SCNTransaction.commit()
                diag("arrival.spawnAtElevator", ["floor": mazeStore.currentMazeID, "spawn": playerStart, "floorStart": start])
            }
            // Oct 17 (Decorate camera-jump fix): a Decorate edit's rebuild -- the new
            // camera takes the kept pose NOW, before the scene is handed to the view
            // just below. (SceneKit draws on its own loop: with the pose applied only
            // at resume(at:), much later in this install, a frame or two showed the
            // floor's spawn view first.) resume(at:) still runs later, as before, for
            // the controller's cell/facing and its legality fallback.
            if let kept = keptDecoratePose {
                SCNTransaction.begin()
                SCNTransaction.disableActions = true
                cameraNode.position = SCNVector3(kept.x, cameraNode.position.y, kept.z)
                cameraNode.eulerAngles = SCNVector3(0, kept.yaw, 0)
                SCNTransaction.commit()
            }
            if controlledArrival { ElevatorArrivalTrace.shared.registerScene(scene) }
            ElevatorArrivalTrace.shared.event("SCNView.sceneAssign.begin")
            view.scene = scene
            ElevatorArrivalTrace.shared.event("SCNView.sceneAssign.end")
            let traceFloorGlow = ElevatorArrivalTrace.shared.beginPhase("install.pointOfViewAndFloorGlow")
            view.pointOfView = cameraNode
            // Oct 5: critter audio is a proximity sense (and silent from inside the cab).
            CritterAudio.beginFloor(view: view, listener: cameraNode,
                                    doors: elevatorDoors.map { (left: $0.left, right: $0.right) },
                                    hallwayCell: SIMD2<Float>(Float(CGFloat(end.col) * mazeStore.cellSize), Float(CGFloat(end.row) * mazeStore.cellSize)),
                                    cellSize: mazeStore.cellSize,
                                    walkableCells: mazeStore.cells.map { (row: $0.row, col: $0.col) })
            // Oct 3 EXPERIMENT 1: this floor's authored floor-glow sequences
            // (none on most floors -- then this installs nothing).
            if stagedArrival == nil {
                HallwayScene.installFloorGlowSequences(mazeStore.floorGlowSequences, cells: mazeStore.cells, root: scene.rootNode)
                if mazeStore.currentMazeID == AdministrationReception.floor {
                    AdministrationReception.install(into: scene.rootNode, cellSize: mazeStore.cellSize, cells: mazeStore.cells)
                }
                if mazeStore.currentMazeID == PlayerOffice.floor {          // Oct 6: the player's office
                    PlayerOffice.install(into: scene.rootNode, cellSize: mazeStore.cellSize, cells: mazeStore.cells)
                }
                if mazeStore.currentMazeID == ConferenceRoom.floor {        // Oct 8: the conference room
                    ConferenceRoom.install(into: scene.rootNode, cellSize: mazeStore.cellSize, cells: mazeStore.cells)
                }
                if mazeStore.currentMazeID == SuppliesShowroom.floor {      // Oct 16: Floor 4, SUPPLIES
                    SuppliesShowroom.install(into: scene.rootNode, cellSize: mazeStore.cellSize, cells: mazeStore.cells)
                }
                if mazeStore.currentMazeID == FloorFiveBlackout.floor {     // Oct 16 (VIII): Floor 5, LIGHTS OUT
                    FloorFiveBlackout.install(into: scene.rootNode, cellSize: mazeStore.cellSize, cells: mazeStore.cells)
                }
            }
            ElevatorArrivalTrace.shared.endPhase("install.pointOfViewAndFloorGlow", traceFloorGlow)
            // Oct 3 TIN CAN RAT prototype 1: read-only visual follower +
            // companion camera (three-finger tap toggles). See TinCanRat.swift.
            // Habitat pass: wall things Noodle may occasionally glance at.
            let traceNoodleInputs = ElevatorArrivalTrace.shared.beginPhase("install.noodleInputs")
            var noodleWallThings: [(GridCoordinate, Direction)] = mazeStore.pictures.keys.map { ($0.coord, $0.direction) }
            noodleWallThings += mazeStore.floorMaps.map { ($0.key, $0.value) }
            noodleWallThings += worldMissionSigns.map { ($0.key, $0.value) }
            noodleWallThings += mazeStore.mirrors.map { ($0.key, $0.value) }
            ElevatorArrivalTrace.shared.endPhase("install.noodleInputs", traceNoodleInputs)
            let traceNoodle = ElevatorArrivalTrace.shared.beginPhase("install.TinCanRat")
            // Oct 5 (Admission): Administration's entrance is the player's
            // alone during admission -- no Noodle (first-person view) there.
            let admissionAtAdministration = Admission.isPending && mazeStore.currentMazeID == Admission.administrationFloor
            // Oct 5 (clean onboarding): the first lobby is held back too (and
            // everything below keys off this) -- see Admission.isQuietOnboarding.
            let onboardingQuiet = Admission.isQuietOnboarding(floor: mazeStore.currentMazeID)
            // Oct 5: Administration never gets the ambient population (see Admission.isCritterFree).
            let critterFree = Admission.isCritterFree(floor: mazeStore.currentMazeID)
            // Oct 5: reaching Administration completes the initial entrance
            // (independent of admission and of the prologue).
            if mazeStore.currentMazeID == Admission.administrationFloor,
               !UserDefaults.standard.bool(forKey: Admission.initialEntranceKey) {
                UserDefaults.standard.set(true, forKey: Admission.initialEntranceKey)
                diag("onboarding.initialEntranceCompleted", ["floor": mazeStore.currentMazeID])
            }
            diag("onboarding.floorGate", ["floor": mazeStore.currentMazeID, "admissionPending": Admission.isPending,
                                          "quiet": onboardingQuiet, "staged": stagedArrival != nil])
            // Oct 6 (Cast stage 2): ONE authority decides what Jeff is doing on
            // this floor. Only "hanging" installs the companion here; his door,
            // desk and journey-guide bodies are placed by the office build and
            // GuidedJourney, which ask the same authority.
            let jeffPlacement = Cast.jeffPlacement(floor: mazeStore.currentMazeID)
            if onboardingQuiet {
                SoundEffects.humanFootstepsSuppressed = false
                diag("admission.noodleHeldBack", ["floor": mazeStore.currentMazeID])
            }
            if jeffPlacement == .hanging {
                let jeff = TinCanRat.install(in: view, scene: scene, playerCamera: cameraNode, cells: mazeStore.cells, cellSize: mazeStore.cellSize,
                                             wallThings: noodleWallThings, arrivingInsideCab: controlledArrival)
                Cast.setJeff(.hanging, body: jeff, "floor \(mazeStore.currentMazeID) install")
            } else {
                diag("cast.companionNotInstalled", ["floor": mazeStore.currentMazeID, "placement": jeffPlacement.rawValue])
            }
            ElevatorArrivalTrace.shared.endPhase("install.TinCanRat", traceNoodle)
            // Oct 3 FIRST AUTONOMOUS CRITTER (Bobbin): roams on its own; reads the
            // floor topology (doors count as closed to it). See Bobbin.swift.
            let tracePopulationInputs = ElevatorArrivalTrace.shared.beginPhase("install.populationInputs")
            var bobbinDoors: [(GridCoordinate, Direction)] = mazeStore.bathroomDoors.map { ($0.key, $0.value) }
            bobbinDoors += mazeStore.windowRooms.map { ($0.key, $0.value.direction) }
            bobbinDoors += mazeStore.roomEntranceDoors.map { ($0.key, $0.value.direction) }
            // Oct 3 DWEEZIL PASS: the living-object cast (and maybe an enclosure).
            // Placed first so the Bobbins can be kept out of a closed cage's cell.
            var dweezilLit = Set(mazeStore.fluorescentLights.keys)
            dweezilLit.formUnion(mazeStore.spotlights)
            var dweezilBusy = Set(mazeStore.objects.keys)
            dweezilBusy.formUnion(mazeStore.destinations.keys)
            dweezilBusy.formUnion(mazeStore.roomDoors.keys)
            dweezilBusy.formUnion(mazeStore.fires)
            dweezilBusy.formUnion(mazeStore.extinguishers.keys)
            dweezilBusy.formUnion(mazeStore.photoBooths.keys)
            dweezilBusy.formUnion(mazeStore.mirrors.keys)
            dweezilBusy.formUnion(mazeStore.floorMaps.keys)
            dweezilBusy.formUnion(mazeStore.missionSigns.keys)
            dweezilBusy.formUnion(mazeStore.pictures.keys.map { $0.coord })
            for games in [mazeStore.ticTacToeTerminals, mazeStore.shellGameStations, mazeStore.rockPaperScissorsTerminals,
                          mazeStore.higherLowerTerminals, mazeStore.fiveCardDrawTerminals, mazeStore.simonTerminals,
                          mazeStore.hangmanTerminals, mazeStore.connectFourTerminals, mazeStore.checkersTerminals,
                          mazeStore.woidleTerminals] {
                dweezilBusy.formUnion(games.keys)
            }
            // Oct 4 DIAGNOSTIC (LivingWorldDiagnostic.swift): the same two installs,
            // handed to the in-app population control, which runs them now and
            // again whenever the population is changed on this floor.
            // Oct 11 (the staff meeting): the conference room is a directed
            // scene -- the floor's free-roaming population stays out of it.
            // Oct 12: ...and the player's own office is theirs (Harold's) -- no roaming population in it.
            let livingCells = mazeStore.currentMazeID == ConferenceRoom.floor
                ? mazeStore.cells.subtracting(ConferenceRoom.roomCells).subtracting(PlayerOffice.officeCells) : mazeStore.cells
            let livingCellSize = mazeStore.cellSize
            ElevatorArrivalTrace.shared.endPhase("install.populationInputs", tracePopulationInputs)
            let traceLivingWorld = ElevatorArrivalTrace.shared.beginPhase("install.LivingWorld")
            if let stagedLiving = stagedArrival?.livingWorld {
                LivingWorld.activateStaged(stagedLiving, view: view)
            } else {
            LivingWorld.beginFloor(view: view) { [weak view, weak scene, weak cameraNode] in
            guard let view, let scene, let cameraNode, !critterFree else { return }
            let dweezilCage = Menagerie.install(in: view, scene: scene, playerCamera: cameraNode, cells: livingCells,
                                                cellSize: livingCellSize, doors: bobbinDoors, litCells: dweezilLit,
                                                busyCells: dweezilBusy, floor: mazeStore.currentMazeID)   // Oct 16
            var bobbinCells = livingCells
            if let dweezilCage { bobbinCells.remove(dweezilCage) }
            let traceBobbin = ElevatorArrivalTrace.shared.beginPhase("install.Bobbin")
            // Oct 5 (Admission): no Bobbin in Administration during admission.
            if !admissionAtAdministration {
                Bobbin.install(in: view, scene: scene, playerCamera: cameraNode, cells: bobbinCells,
                               cellSize: livingCellSize, doors: bobbinDoors)
            }
            ElevatorArrivalTrace.shared.endPhase("install.Bobbin", traceBobbin)
            }
            }
            ElevatorArrivalTrace.shared.endPhase("install.LivingWorld", traceLivingWorld)
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
            // Sept 26 (Decorate-mode elevator pictures): same
            // "baseline matches what THIS build already rendered"
            // reasoning as lastPictureImageSelections just above --
            // this build's HallwayScene.addElevatorDoor already
            // consulted mazeStore.elevatorCabDecoration.backArtwork/
            // sideArtwork itself, so priming these to the CURRENT
            // values (not nil) stops updateUIView's own diff-watcher
            // below from redundantly re-fetching/re-applying the very
            // artwork this build just rendered correctly.
            context.coordinator.lastElevatorBackArtwork = mazeStore.elevatorCabDecoration.backArtwork
            context.coordinator.lastElevatorSideArtwork = mazeStore.elevatorCabDecoration.sideArtwork
            context.coordinator.lastElevatorSideRightArtwork = mazeStore.elevatorCabDecoration.sideRightArtwork
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
                    let traceShaft = ElevatorArrivalTrace.shared.beginPhase("install.shaftPrepare")
                    defer { ElevatorArrivalTrace.shared.endPhase("install.shaftPrepare", traceShaft) }
                    diag("scene.shaftPrepare.begin")
                    _ = view.prepare(shaftNodes)
                    diag("scene.shaftPrepare.end")
                }
            }
            let traceNavCreate = ElevatorArrivalTrace.shared.beginPhase("install.navigationController")
            // Oct 5 (Administration): the staff side of reception is seen, not walked.
            var navigationCells = mazeStore.currentMazeID == AdministrationReception.floor
                ? mazeStore.cells.subtracting(AdministrationReception.staffCells)
                    .subtracting(AdministrationReception.officeDeskBayCells) : mazeStore.cells
            // Oct 6: the player's desk bay is seen, not walked (like Candy's).
            if mazeStore.currentMazeID == PlayerOffice.floor { navigationCells.subtract(PlayerOffice.deskBayCells) }
            // Oct 8: the conference table bay is seen, not walked.
            if mazeStore.currentMazeID == ConferenceRoom.floor { navigationCells.subtract(ConferenceRoom.tableBayCells) }
            // Oct 7 (F): a new controller/scene replaces the one the office
            // computer was seated in -- close the computer without a camera move.
            OfficeComputer.shared.forceClose(reason: "sceneRebuilt")
            ConferenceMeeting.forceStand(reason: "sceneRebuilt")          // Oct 11: same for the meeting chair
            let navController = TapNavigationController(cameraNode: cameraNode, scene: scene, cells: navigationCells, cellSize: mazeStore.cellSize, startCell: start, startFacing: facing, endCell: end, objects: liveObjects, objectNodes: objectNodes, destinations: mazeStore.destinations, destinationNodes: destinationNodes, elevatorLeftDoor: elevatorDoors?.left, elevatorRightDoor: elevatorDoors?.right, elevatorMountDirection: elevatorDoors?.direction, elevatorButtonNodes: elevatorDoors?.buttonNodes ?? [:], floorNumber: mazeStore.currentMazeID, nextFloorNumber: mazeStore.nextMazeID, floorMaps: mazeStore.floorMaps, floorMapPlaneNodes: floorMapPlaneNodes, missionSigns: worldMissionSigns, exitSigns: mazeStore.exitSigns, pictures: Set(mazeStore.pictures.keys), mirrors: mazeStore.mirrors, fires: liveFires, fireNodes: fireNodes, extinguishers: mazeStore.extinguishers, extinguisherNodes: extinguisherNodes, photoBooths: mazeStore.photoBooths, photoBoothNodes: photoBoothNodes, ticTacToeTerminals: mazeStore.ticTacToeTerminals, ticTacToeTerminalNodes: ticTacToeTerminalNodes, shellGameStations: mazeStore.shellGameStations, shellGameStationNodes: shellGameStationNodes, rockPaperScissorsTerminals: mazeStore.rockPaperScissorsTerminals, rockPaperScissorsTerminalNodes: rockPaperScissorsTerminalNodes, higherLowerTerminals: mazeStore.higherLowerTerminals, higherLowerTerminalNodes: higherLowerTerminalNodes, fiveCardDrawTerminals: mazeStore.fiveCardDrawTerminals, fiveCardDrawTerminalNodes: fiveCardDrawTerminalNodes, simonTerminals: mazeStore.simonTerminals, simonTerminalNodes: simonTerminalNodes, hangmanTerminals: mazeStore.hangmanTerminals, hangmanTerminalNodes: hangmanTerminalNodes, connectFourTerminals: mazeStore.connectFourTerminals, connectFourTerminalNodes: connectFourTerminalNodes, checkersTerminals: mazeStore.checkersTerminals, checkersTerminalNodes: checkersTerminalNodes, woidleTerminals: mazeStore.woidleTerminals, woidleTerminalNodes: woidleTerminalNodes, roomDoors: mazeStore.roomDoors, itemRooms: mazeStore.itemRooms, bathroomDoors: mazeStore.bathroomDoors, windowRooms: mazeStore.windowRooms, roomEntranceDoors: mazeStore.roomEntranceDoors.mapValues { $0.direction }, missionObjectKind: mazeStore.missionObjectKind, hasCompletedInitialEntrance: hasCompletedInitialEntrance)
            ElevatorArrivalTrace.shared.endPhase("install.navigationController", traceNavCreate)
            // Oct 9: this floor's shut doors into the critter/building sound model.
            navController.publishAcousticDoors()
            // Oct 3 TIN CAN RAT 1.1: he watches (read-only) where an accepted tap walk is headed.
            TinCanRat.observeTapWalk(in: scene) { [weak navController] in navController?.tapWalkDestination }
            // Sept 29 FREE-WALK EXPERIMENT: player-controlled taps/holds walk
            // along the camera's actual yaw and stop at any X/Z. Flip
            // TapNavigationController.freeWalkExperimentOn to false to get the
            // grid-centered navigation back exactly.
            navController.freeWalkEnabled = TapNavigationController.freeWalkExperimentOn
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
            let traceArrivalPose = ElevatorArrivalTrace.shared.beginPhase("install.arrivalPositioning")
            if navBridge.pendingElevatorArrival {
                let preservedYaw = navBridge.pendingArrivalYaw
                navBridge.pendingElevatorArrival = false
                navBridge.pendingArrivalYaw = nil
                diag("arrival.presentInsideElevator.begin", ["controlled": preservedYaw != nil])
                let preservedOffset = navBridge.pendingArrivalOffset
                navBridge.pendingArrivalOffset = nil
                // Oct 8: on Floor 1 the walk-in start is the front door, not
                // the elevator -- stand the player in the elevator cell first.
                // (startCell stays the front door: reset and the entrance-door
                // "back outside" tap keep their meaning.)
                if playerStart != start { navController.enterAtElevatorCell() }
                navController.presentArrivalInsideElevator(preservedYaw: preservedYaw, offset: preservedOffset)
                diag("arrival.presentInsideElevator.end")
                elevatorLog("destination scene ready -- floor \(mazeStore.currentMazeID), \(preservedYaw == nil ? "passive" : "controlled")")
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
                // Controlled arrival waits for preparation and an actual rendered frame.
                navBridge.arrivalSceneReady = !controlledArrival
            }
            ElevatorArrivalTrace.shared.endPhase("install.arrivalPositioning", traceArrivalPose)
            // Oct 11 (resume): the first build of the floor the app reopened on
            // puts the player back where they left off (exact spot and yaw, or
            // the nearest sensible place). Followers start around that spot.
            var posseStart = playerStart
            if let point = ResumeState.takePlacement(forFloor: mazeStore.currentMazeID) {
                posseStart = navController.resume(at: point)
            } else if let point = keptDecoratePose {             // Oct 17: a Decorate edit's rebuild -- stay put
                posseStart = navController.resume(at: point)
                diag("decorator.rebuildKeptPose", ["floor": point.floor])
            }
            navController.saveResumePoint(reason: "floorBuilt")
            // Oct 16 (Supplies): the tools carried come along -- in hand on this floor's
            // camera, or at heel from where the player now stands (after the arrival
            // pose and any resume placement above).
            ToolBelt.attach(camera: cameraNode, view: view, controller: navController,
                            cells: mazeStore.cells, cellSize: mazeStore.cellSize,
                            doorCells: Set(mazeStore.roomEntranceDoors.keys).union(mazeStore.bathroomDoors.keys).union(mazeStore.windowRooms.keys))
            LightCensus.schedule(scene: scene, floor: mazeStore.currentMazeID)   // Oct 12 (stability): diagnostics only
            // Oct 4 FREDDY SLICE (Posse.swift / Freddy.swift): followers and the
            // critters you can recruit, placed now that the arrival pose (inside
            // the elevator cab after a ride) is final. A follower's skill can put
            // out this floor's fires through the controller's own fire state.
            let tracePosse = ElevatorArrivalTrace.shared.beginPhase("install.Posse")
            Posse.installFloor(view: view, scene: scene, playerCamera: cameraNode, floor: mazeStore.currentMazeID,
                               cells: mazeStore.cells, cellSize: mazeStore.cellSize, start: posseStart, end: end,
                               fires: fireNodes, allowFirstMeetings: !admissionAtAdministration
                                   && mazeStore.currentMazeID != Admission.administrationFloor,
                               allowMembers: !onboardingQuiet) { [weak navController] coord in
                navController?.creatureExtinguishFire(at: coord) ?? false
            }
            ElevatorArrivalTrace.shared.endPhase("install.Posse", tracePosse)
            // Oct 16 (III): the immortal extinguisher -- no unclaimed extinguisher may ride
            // on the camera; and (TEMPORARY) a census of every extinguisher-like node,
            // now and once the followers have placed themselves.
            ExtinguisherCensus.sweepCameraOrphans(camera: cameraNode)
            ExtinguisherCensus.run("built", root: scene.rootNode, camera: cameraNode, controller: navController, floor: mazeStore.currentMazeID)
            let censusFloor = mazeStore.currentMazeID
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak scene, weak cameraNode, weak navController] in
                guard let scene, let cameraNode else { return }
                ExtinguisherCensus.sweepCameraOrphans(camera: cameraNode)
                ExtinguisherCensus.run("built+3s", root: scene.rootNode, camera: cameraNode, controller: navController, floor: censusFloor)
            }
            // Oct 11 (Episode 3): the staff-meeting procession and the
            // conference room's life (Floor 3 only; see MeetingProcession).
            BlackBox.attach(camera: cameraNode)                                 // Oct 12: the Black Box watches the player
            if mazeStore.currentMazeID == MeetingProcession.floor {
                ConferenceMeeting.attach(controller: navController)          // Oct 11: the staff meeting
                MeetingProcession.installFloor(
                    scene: scene, playerCamera: cameraNode, cells: mazeStore.cells, cellSize: Float(mazeStore.cellSize),
                    doors: mazeStore.roomEntranceDoors.mapValues { $0.direction },
                    hooks: .init(openDoor: { [weak navController] c in navController?.openRoomEntranceDoorForCharacter(at: c) },
                                 closeDoor: { [weak navController] c in navController?.closeRoomEntranceDoorForCharacter(at: c) },
                                 isDoorOpen: { [weak navController] c in navController?.openRoomEntranceDoors.contains(c) ?? false },
                                 playerCell: { [weak navController] in navController?.currentCell }))
                let priorCellChanged = navController.onCellChanged
                navController.onCellChanged = { cell in
                    priorCellChanged?(cell)
                    MeetingProcession.playerCellChanged(cell)
                    ConferenceMeeting.playerCellChanged(cell)
                }
                navController.onRoomEntranceDoorOpened = { coord in MeetingProcession.roomDoorOpened(coord) }
            } else {
                MeetingProcession.leaveFloor()
            }
            let traceWiring = ElevatorArrivalTrace.shared.beginPhase("install.controllerAndGestureWiring")
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
            // Oct 4 interactive elevator: the floors the panel can reach.
            navController.elevatorReachableFloors = mazeStore.floorIDs
            // Oct 6: the arrival turn-to-doors yields to a finger already down --
            // read LIVE from UIKit (a continuous recognizer mid-gesture), never a
            // remembered flag: the elevator handoff resets the recognizers
            // (cancelElevatorHandoffInput), which can end a gesture without its
            // .ended/.cancelled callback, and a stale flag then blocked every turn.
            navController.activeTouchGesture = { [weak coordinator = context.coordinator] in
                coordinator?.activeTouchGestureDescription()
            }
            // Oct 8 (Juanita diagnostics): Floor 2's admission/prologue state at
            // install, and the otherwise-silent case where the reception can't
            // be wired because the floor's layout no longer matches.
            if mazeStore.currentMazeID == AdministrationReception.floor {
                let receptionFits = AdministrationReception.expectedCells.isSubset(of: mazeStore.cells)
                diag("juanita.floorState", ["admission": Admission.isCompleted,
                                            "prologue": Admission.isPrologueCompleted,
                                            "target": AdministrationReception.directionsTarget?.rawValue ?? "none",
                                            "hasEmployeeID": EmployeeID.number != nil,
                                            "receptionWired": receptionFits])
                if !receptionFits {
                    diag("juanita.noResponse", ["reason": "floorLayoutMismatch"])
                }
            }
            // Oct 5 (Administration): the visitor's position at the reception counter.
            if mazeStore.currentMazeID == AdministrationReception.floor,
               AdministrationReception.expectedCells.isSubset(of: mazeStore.cells) {
                // Oct 7: Juanita's patience runs only while the visitor stays
                // at the counter (the desk landing's cell).
                AdministrationReception.isVisitorAtDesk = { [weak navController] in
                    navController?.currentCell == AdministrationReception.deskLanding.coord
                }
                navController.onCellChanged = { cell in
                    if cell != AdministrationReception.deskLanding.coord {
                        AdministrationReception.cancelPatienceTimer()
                    }
                    // Oct 24 (onboarding polish): walking away from the kiosk with
                    // the finished card still out takes it (as a tap would).
                    if cell != AdministrationReception.photoStationCell,
                       AdministrationIDTerminal.current?.isCardWaiting == true {
                        AdministrationIDTerminal.current?.takeWaitingCard(via: "walkedAway")
                    }
                    AdministrationExitGuard.playerCellChanged(cell)          // Oct 9: Juanita keeps the exit
                }
                // Oct 24 (onboarding polish): turning away from the kiosk (a quarter
                // turn or more, once it settles) with the card out takes it too.
                navController.onFacingChanged = { [weak navController] facing in
                    guard let navController,
                          navController.currentCell == AdministrationReception.photoStationCell,
                          facing != AdministrationReception.terminalLanding.direction,
                          AdministrationIDTerminal.current?.isCardWaiting == true else { return }
                    AdministrationIDTerminal.current?.takeWaitingCard(via: "turnedAway")
                }
                // Oct 21: the card taken -- 1.5 s later, round and on toward Tinky's office.
                AdministrationIDTerminal.onCardTaken = { [weak navController] in
                    navController?.scheduleWalkTowardTinky(after: 1.5)
                }
                navController.landingSpots = [
                    // After the desk landing, the Administrator acknowledges you
                    // and points to the ID terminal (once per visit).
                    .init(kind: "receptionDesk", face: AdministrationReception.deskLanding,
                          standOff: AdministrationReception.deskStandOff,
                          onLanded: { [weak scene] in
                              guard let scene else { return }
                              // First landing this visit: the greeting; later
                              // landings only perform if she was tapped.
                              AdministrationReception.landedAtDesk(in: scene.rootNode)
                          },
                          // Oct 6 (polish): walking up to her stops at the
                          // conversation distance -- no glide back out.
                          capsApproach: true),
                    // The ID-photo terminal's own landing: squarely in front of the screen.
                    .init(kind: AdministrationIDTerminal.landingKind, face: AdministrationReception.terminalLanding,
                          standOff: AdministrationReception.terminalStandOff,
                          onLanded: { [weak navController] in
                              diag("idTerminal.landed", [:])
                              // Oct 11: a gentle look down at the kiosk (card reveal).
                              navController?.holdLandingPitch(AdministrationReception.terminalPitch,
                                                              whileIn: AdministrationIDTerminal.landingKind)
                          },
                          // Oct 24 (GO toward the kiosk wall): once the ID is issued the
                          // kiosk no longer pulls a walk that ends near it onto its spot
                          // (leaving Tinky's office faces the player straight at it).
                          isAvailable: { !Admission.isCompleted || AdministrationIDTerminal.current?.isCardWaiting == true }),
                    // Oct 5 (Fred encounter): in front of Fred's desk, facing it --
                    // only while he is there and hasn't performed yet this visit.
                    .init(kind: FredOfficeEncounter.landingKind, face: FredOfficeEncounter.landing,
                          standOff: FredOfficeEncounter.landingStandOff,
                          onLanded: { FredOfficeEncounter.begin() },
                          isAvailable: { FredOfficeEncounter.isAvailable },
                          // Oct 10 (Smart WALK): walking up to his desk stops
                          // here, in front of it -- never on round behind it.
                          capsApproach: true)
                ]
                // Oct 6 (Fredo: "kiosk first" / "follow me" prototype): the lead
                // engine's view of this floor -- where he may walk (everything but
                // the staff side of the counter), the doors, and the player.
                FredLead.context = CharacterLead.Context(
                    cells: mazeStore.cells.subtracting(AdministrationReception.staffCells),
                    doors: mazeStore.roomEntranceDoors.mapValues { $0.direction },
                    cellSize: Float(mazeStore.cellSize),
                    playerPose: { [weak cameraNode] in
                        guard let cameraNode else { return nil }
                        let scnT = FrameTiming.start()                        // Oct 24: SceneKit wait (measurement only)
                        let p = cameraNode.presentation.worldPosition
                        let yaw = cameraNode.presentation.eulerAngles.y
                        FrameTiming.shared.record(.scnPose, since: scnT)
                        return (position: SIMD2<Float>(p.x, p.z), yaw: yaw)
                    },
                    isDoorOpen: { [weak navController] coord in navController?.openRoomEntranceDoors.contains(coord) ?? false },
                    openDoor: { [weak navController] coord in navController?.openRoomEntranceDoorForCharacter(at: coord) })
                FredLead.swingDoorCosmetically = { [weak navController] coord, open in
                    navController?.swingRoomEntranceDoorCosmetically(at: coord, open: open)
                }
                navController.roomEntranceDoorIntercept = { coord in FredDoorGuard.intercept(coord) }
                // Oct 9 (Juanita in the doorway): while she stands in the exit,
                // its boundary is closed to the player like a wall -- the doors
                // themselves open and close as always.
                AdministrationExitGuard.setExitBlocked = { [weak navController] blocked in
                    guard let navController else { return }
                    if blocked {
                        // Oct 9: taking her post she pulls the doors to (if open).
                        navController.closeRoomEntranceDoorForCharacter(at: AdministrationExitGuard.exitDoor)
                        navController.characterBlockedEdges.insert(AdministrationExitGuard.exitEdge)
                    } else {
                        navController.characterBlockedEdges.remove(AdministrationExitGuard.exitEdge)
                    }
                }
                navController.onCharacterBlockBump = { AdministrationExitGuard.bumped() }
                // Oct 9: the exit doors she guards don't open; trying them is an attempt to leave.
                navController.roomEntranceDoorGuarded = { AdministrationExitGuard.guardsDoor($0) }
                navController.onGuardedRoomEntranceDoorTap = { _ in AdministrationExitGuard.doorTried() }
                // Oct 9: her conversational distance -- the free walk stops
                // short of her instead of gliding the camera into her.
                AdministrationExitGuard.setKeepOut = { [weak navController] k in
                    navController?.characterKeepOuts = k.map {
                        [FreeWalkGeometry.KeepOut(x: Double($0.center.x), z: Double($0.center.y), radius: Double($0.radius))]
                    } ?? []
                }
                AdministrationExitGuard.sync(playerCell: navController.currentCell)
            }
            // Oct 6 (guided journey -- player follows character across floors):
            // every floor tells the journey about itself; on the destination
            // floor of a journey the guide is placed in the arriving cab.
            do {
                let floor = mazeStore.currentMazeID
                GuidedJourney.context = (floor == AdministrationReception.floor ? FredLead.context : nil) ?? CharacterLead.Context(
                    cells: mazeStore.cells,
                    doors: mazeStore.roomEntranceDoors.mapValues { $0.direction },
                    cellSize: Float(mazeStore.cellSize),
                    playerPose: { [weak cameraNode] in
                        guard let cameraNode else { return nil }
                        let scnT = FrameTiming.start()                        // Oct 24: SceneKit wait (measurement only)
                        let p = cameraNode.presentation.worldPosition
                        let yaw = cameraNode.presentation.eulerAngles.y
                        FrameTiming.shared.record(.scnPose, since: scnT)
                        return (position: SIMD2<Float>(p.x, p.z), yaw: yaw)
                    },
                    isDoorOpen: { [weak navController] coord in navController?.openRoomEntranceDoors.contains(coord) ?? false },
                    openDoor: { [weak navController] coord in navController?.openRoomEntranceDoorForCharacter(at: coord) })
                GuidedJourney.doorwayFrame = { [weak navController] in navController?.elevatorDoorwayFrame() }
                // Oct 6: Candy's ride home -- the doors cycle for him alone.
                GuidedJourney.characterElevatorDeparture = { [weak navController] boarding, completion in
                    navController?.runCharacterElevatorDeparture(who: "tinky (escort)", boarding: boarding, completion: completion) ?? false
                }
                // Oct 6 (Cast stage 3): the pet's handoff on ANY floor -- the
                // companion driver takes over the body Jeff is already in
                // (office model or journey guide), held until the pet's shimmy
                // ends, first person kept. Replaces the two old "remove that
                // body, install a new companion" closures.
                let companionWallThings = noodleWallThings
                Cast.adoptAsHanging = { [weak view, weak scene, weak cameraNode, weak navController, mazeStore] body in
                    guard let view, let scene, let cameraNode, view.scene === scene else { return false }
                    TinCanRat.install(in: view, scene: scene, playerCamera: cameraNode, cells: mazeStore.cells,
                                      cellSize: mazeStore.cellSize, wallThings: companionWallThings,
                                      usesCompanionCamera: false, existingBody: body, held: true)
                    TinCanRat.observeTapWalk(rat: body) { [weak navController] in navController?.tapWalkDestination }
                    return true
                }
                // (Oct 22: the Big Shot's eviction ride no longer wired in -- he is retired.)
                navController.guidedAutoFloor = { GuidedJourney.autoFloor(from: floor) }
                navController.onElevatorBoarding = {
                    GuidedJourney.playerBoarding(floor: floor)
                    FloorPresenter.playerBoarding()                              // Oct 17: an informant boards with them (Oct 18: any resident)
                }
                navController.onArrivalDoorsOpening = { [weak navController] in
                    GuidedJourney.arrivalDoorsOpening(floor: floor)
                    FloorPresenter.arrivalDoorsOpening()                         // Oct 17: out of the cab first (Oct 18: any resident)
                    // Oct 12 (stability): the arrival is committed at once (just outside the doors).
                    if GuidedJourney.trip?.stage == .guiding { navController?.saveResumePoint(reason: "orientationArrived") }
                }
                GuidedJourney.installGuideIfArriving(in: scene.rootNode, floor: floor)
                // (Oct 22: BonzoEviction's floor hooks removed -- the Big Shot is retired and can
                // no longer be placed anywhere; see Menagerie.install.)
                // Oct 12 (escort resume): quit mid-escort -> he's put back with the player.
                GuidedJourney.resumeEscortIfSaved(in: scene.rootNode, floor: floor)
                // Oct 17 (informants): the butterfly's life on this floor, if she's here
                // (or on her way -- by the elevator -- to a player on a dark Floor 5).
                // Oct 18 (building life): every resident's presentation on this floor --
                // the butterfly and the roaming chair -- their records kept by BuildingLife.
                FloorPresenter.floorBuilt(floor: floor, root: scene.rootNode, camera: cameraNode, controller: navController,
                                          context: GuidedJourney.context,
                                          plans: { [weak store = mazeStore] in store?.floorPlan(for: $0) })
                // Oct 6 (Cast): exactly one Jeff (or none) in this scene; one summary line.
                Cast.floorBuilt(floor, root: scene.rootNode)
            }
            // Oct 5 (Admission): the first trip from the lobby goes to Administration.
            navController.admissionAutoFloor = (mazeStore.currentMazeID == 1 && Admission.isPending)
                ? Admission.administrationFloor : nil
            // Oct 5 (elevator staging): a valid floor press starts preparing it.
            navController.onElevatorDestinationChosen = { [weak view, weak coordinator = context.coordinator] floor in
                GuidedJourney.destinationChosen(floor)                     // Oct 6: before the destination is staged
                guard let view, let coordinator else { return }
                // Oct 24 (onboarding polish): Admission's floor already being prepared
                // since the panel came into view -- keep it (its ride is short).
                if let early = coordinator.stagedElevatorDestination, early.foreseen, early.floor == floor, !early.cancelled {
                    diag("elevator.staging.keptForeseen", ["to": floor, "complete": early.isComplete])
                    return
                }
                stageElevatorDestination(floor: floor, view: view, coordinator: coordinator)
            }
            navController.onElevatorDestinationForeseen = { [weak view, weak coordinator = context.coordinator] floor in
                guard let view, let coordinator else { return }
                stageElevatorDestination(floor: floor, view: view, coordinator: coordinator)
                coordinator.stagedElevatorDestination?.foreseen = true
                diag("elevator.staging.foreseen", ["to": floor])
            }
            navController.onReachedEnd = { [weak view, weak navController, mazeStore, navBridge] in
                // Oct 4: a floor chosen on the cab's panel wins over the old linked "next".
                let destination = navController?.elevatorDestinationFloor
                guard destination != nil || mazeStore.nextMazeID != nil else { return }
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
                navBridge.doorSnapshot = nil // persistent SCNView remains live; no static blindfold
                navBridge.pendingElevatorArtwork = view?.scene.map { HallwayScene.elevatorArtwork(in: $0) } ?? [:]
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
                navBridge.pendingControlledDoorOpen = false
                elevatorLog("ride complete (passive) -- leaving floor \(mazeStore.currentMazeID) for \(mazeStore.nextMazeID ?? -1)")
                navBridge.diagSnapshot("handoffBeforeAdvance")
                if let destination { mazeStore.switchTo(id: destination) } else { mazeStore.advanceToNextMaze() }
                diag("elevator.advanceToNextMaze.returned", ["nowFloor": mazeStore.currentMazeID])
            }
            // Preserve the outgoing full frame only until the destination has rendered.
            // The bridge does not participate in the subsequent door animation.
            navController.onElevatorArrivedControlled = { [weak view, weak navController, weak coordinator = context.coordinator, mazeStore, navBridge] yaw in
                let destination = navController?.elevatorDestinationFloor
                navBridge.pendingArrivalOffset = navController?.elevatorArrivalOffset
                // A stationary closed-cab mask covers synchronous activation and
                // GPU preparation. It disappears without animation at readiness.
                ElevatorArrivalTrace.shared.event("handoff.begin")
                coordinator?.cancelElevatorHandoffInput(in: view)
                ElevatorArrivalTrace.shared.event("snapshot.capture.begin")
                navBridge.doorSnapshot = view?.snapshot()
                ElevatorArrivalTrace.shared.event("snapshot.capture.end", "imagePresent=\(navBridge.doorSnapshot != nil)")
                navBridge.controlledArrivalFrameReady = false
                diag("controlledArrival.liveHandoff", [
                    "snapshotPresent": navBridge.doorSnapshot != nil,
                    "viewAttached": view?.window != nil,
                    "viewBounds": String(describing: view?.bounds ?? .zero),
                    "scenePresent": view?.scene != nil,
                    "floor": mazeStore.currentMazeID
                ])
                let traceBridge = ElevatorArrivalTrace.shared.beginPhase("handoff.bridgePublication")
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
                navBridge.pendingControlledDoorOpen = false
                ElevatorArrivalTrace.shared.endPhase("handoff.bridgePublication", traceBridge)
                elevatorLog("ride complete (controlled) -- leaving floor \(mazeStore.currentMazeID) for \(mazeStore.nextMazeID ?? -1)")
                navBridge.diagSnapshot("handoffBeforeAdvance")
                ElevatorArrivalTrace.shared.event("floorSwitch.begin")
                if let destination { mazeStore.switchTo(id: destination) } else { mazeStore.advanceToNextMaze() }
                ElevatorArrivalTrace.shared.event("floorSwitch.end")
                diag("elevator.advanceToNextMaze.returned", ["nowFloor": mazeStore.currentMazeID])
                ElevatorArrivalTrace.shared.event("handoff.callbackReturning")
            }
            if controlledArrival { ElevatorArrivalTrace.shared.registerDestination(navController) }
            view.delegate = navController
            let traceReplaceController = ElevatorArrivalTrace.shared.beginPhase("install.replaceCoordinatorController")
            // Oct 22 (stability pass): the floor being replaced stops its periodic work now
            // (its door-sound timer), whatever may still hold it -- see TapNavigationController.retire.
            if let old = context.coordinator.navigationController, old !== navController { old.retire() }
            context.coordinator.navigationController = navController
            navController.hudSceneView = view   // Oct 10: the HUD's USE (office computer) needs the view
            ElevatorArrivalTrace.shared.endPhase("install.replaceCoordinatorController", traceReplaceController)
            context.coordinator.navBridge = navBridge
            navController.onHandheldMapOpened = { [weak coordinator = context.coordinator] in
                coordinator?.cancelHeldWalkForMap()
            }

            if !context.coordinator.didInstallPersistentGestures {
                context.coordinator.didInstallPersistentGestures = true
                // Oct 8 flight recorder: state snapshots (periodic / before a
                // shared report) read whichever floor's controller is current.
                DiagnosticRecorder.shared.snapshotProvider = { [weak coordinator = context.coordinator] reason in
                    coordinator?.navigationController?.diagStateSnapshot(reason)
                }
                let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
                view.addGestureRecognizer(tap)
                // Oct 22 (evening, sticky controls): measurement only -- how late each touch reaches the app.
                if PerfMonitor.enabled { view.addGestureRecognizer(InputLagProbe()) }

                // 2-finger tap = turn around (180), mirroring the D-pad's
                // back button — still just a turn, needs a forward tap after
                // to actually walk.
                let twoFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerTap))
                twoFingerTap.numberOfTouchesRequired = 2
                view.addGestureRecognizer(twoFingerTap)

                // Oct 3 TIN CAN RAT prototype 1: temporary A/B control.
                // Oct 8: a testing shortcut -- Debug workshop only.
                if BuildMode.developerTools {
                    let threeFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleThreeFingerTap(_:)))
                    threeFingerTap.numberOfTouchesRequired = 3
                    view.addGestureRecognizer(threeFingerTap)
                }

                // Left/right turning is drag-controlled, not a discrete
                // flick: dragging pivots the camera live, one-to-one with
                // the finger, up to a full 90 degrees; letting go past the
                // halfway point (45 degrees) completes the turn, short of
                // it springs back to facing forward. Swipe down is still a
                // discrete flick = turn around, same as the D-pad's back button.
                let panRotate = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePanRotate))
                panRotate.maximumNumberOfTouches = 1
                // Oct 2 (auto-walk -> hold handoff): while a tap-to-point walk is
                // running, this pan does not free-look -- a finger that drags is
                // the hold taking over (see handlePanRotate / beginHold).
                view.addGestureRecognizer(panRotate)
                context.coordinator.lookPanRecognizer = panRotate

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
                context.coordinator.holdRecognizer = longPressForward

                let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
                view.addGestureRecognizer(pinch)
                twoFingerTap.require(toFail: pinch)
            }

            ElevatorArrivalTrace.shared.endPhase("install.controllerAndGestureWiring", traceWiring)
            // @StateObject updates need to land on the next runloop tick,
            // not synchronously inside makeUIView.
            let tracePublishHop = ElevatorArrivalTrace.shared.beginPhase("controller.publishQueueHop")
            DispatchQueue.main.async {
                ElevatorArrivalTrace.shared.endPhase("controller.publishQueueHop", tracePublishHop)
                let tracePublish = ElevatorArrivalTrace.shared.beginPhase("controller.publish")
                diag("scene.publishControllerHop", ["floor": navController.currentFloorNumber])
                navBridge.controller = navController
                navController.diagStateSnapshot("floorInstalled")              // Oct 8 flight recorder
                if navBridge.arrivalSceneReady || navBridge.pendingControlledDoorOpen {
                    elevatorLog("destination controller published -- floor \(navController.currentFloorNumber)")
                }
                // Oct 2: a controlled door-open the curtain could not deliver
                // (timeout before this publish) is delivered right here.
                if navBridge.pendingControlledDoorOpen {
                    navBridge.deliverControlledArrivalDoorOpen()
                }
                navBridge.scenePrepared = false
                ElevatorArrivalTrace.shared.endPhase("controller.publish", tracePublish)
                // Main-queue half of the readiness path (prepare finished).
                let afterPrepareOnMain: (Bool) -> Void = { prepared in
                    ElevatorArrivalTrace.shared.event("prepare.mainCallback")
                    guard navBridge.controller === navController, prepared else { return }
                    navBridge.scenePrepared = true
                    if controlledArrival {
                        // Keep the closed-cab mask until preparation completes and
                        // two destination frames render in the mounted persistent view.
                        func waitForPresentedArrivalFrame(_ renderedFrames: Int) {
                            navController.afterNextRenderedFrame { [weak view, weak navController] in
                                DispatchQueue.main.async {
                                    guard let view, let navController,
                                          navBridge.controller === navController,
                                          navBridge.floorTransitionRequested == arrivalEvent else { return }

                                    let frameCount = renderedFrames + 1
                                    ElevatorArrivalTrace.shared.event("readiness.postPrepareFrame", "count=\(frameCount) attached=\(view.window != nil) bounds=\(view.bounds)")
                                    let isPresented = view.window != nil &&
                                        view.bounds.width > 0 && view.bounds.height > 0

                                    guard isPresented && frameCount >= 2 else {
                                        waitForPresentedArrivalFrame(frameCount)
                                        return
                                    }

                                    ElevatorArrivalTrace.shared.event("readiness.releasable")
                                    var transaction = Transaction()
                                    transaction.disablesAnimations = true
                                    withTransaction(transaction) {
                                        navBridge.arrivalSceneReady = true
                                        navBridge.controlledArrivalFrameReady = true
                                        navBridge.doorSnapshot = nil
                                        ElevatorArrivalTrace.shared.event("snapshot.stateRemoved")
                                    }
                                    diag("arrival.controlledFrameRevealed", [
                                        "floor": navController.currentFloorNumber,
                                        "viewInWindow": true,
                                        "renderedFrames": frameCount
                                    ])
                                }
                            }
                        }
                        waitForPresentedArrivalFrame(0)
                    }
                }
                // Oct 5 (elevator staging): the staged scene was already
                // GPU-prepared during the ride -- go straight to the
                // rendered-frame readiness gate instead of preparing again.
                if stagedArrival?.prepareSucceeded == true {
                    ElevatorArrivalTrace.shared.event("prepare.skipped", "staged=true")
                    afterPrepareOnMain(true)
                } else {
                    ElevatorArrivalTrace.shared.event("prepare.begin")
                    view.prepare([scene]) { prepared in
                        ElevatorArrivalTrace.shared.event("prepare.completion", "success=\(prepared)")
                        diag("scene.prepareFinished")
                        DispatchQueue.main.async {
                            afterPrepareOnMain(prepared)
                        }
                    }
                }

                // Arrival setup is complete. Remain in the cab until an explicit
                // tap/hold; the former delayed advance also triggered manual walk-out.

            }
        }

        let traceViewConfig = ElevatorArrivalTrace.shared.beginPhase("install.viewConfiguration")
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = false // our own touch/tap handling must be the only thing driving the camera
        view.isPlaying = true
        view.rendersContinuously = true
        // Oct 9 (30 FPS experiment): only when the launch argument asks for it.
        if let fps = RenderHealth.testFramesPerSecond {
            view.preferredFramesPerSecond = fps
            diag("render.fpsSetting", ["preferredFramesPerSecond": fps])
        }
        // Oct 24 (FrameTiming, measurement only): the run's conditions for the report.
        FrameTiming.shared.noteConditions(
            preferredFPS: view.preferredFramesPerSecond,
            fpsArgument: RenderHealth.testFramesPerSecond,
            screenMaxFPS: view.window?.windowScene?.screen.maximumFramesPerSecond
                ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.maximumFramesPerSecond }.first)
        HallwaysAudio.shared.attach(engine: view.audioEngine)   // Oct 8: the mute switch covers SceneKit audio
        StickyProbe.watch(engine: view.audioEngine)             // Oct 22 (evening): measurement only -- is it running?

        ElevatorArrivalTrace.shared.endPhase("install.viewConfiguration", traceViewConfig)
        let traceMirrors = ElevatorArrivalTrace.shared.beginPhase("install.mirrors")
        // Oct 8 (Cool Hallways): the outgoing floor's mirror camera never
        // survives into the new floor. Before this, a floor WITHOUT mirrors
        // kept the previous floor's camera alive (only a mirror floor
        // replaced it), so updateUIView kept it capturing for nothing.
        if let previous = context.coordinator.mirrorCamera {
            previous.setActive(false)
            context.coordinator.mirrorCamera = nil
            diag("mirror.camera.floorTeardown", ["floor": mazeStore.currentMazeID])
        }
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
                    surfaces.append(MirrorSurfaceTarget(material: material, aspect: aspect,
                                                        placement: MirrorPlacement(surface: node)))
                }
            }
            if !surfaces.isEmpty {
                let camera = MirrorCamera(surfaces: surfaces, comments: mirrorComments)
                camera.playerPose = Self.mirrorPlayerPose(context.coordinator)
                context.coordinator.mirrorCamera = camera
                camera.setActive(cameraEnabled)
            }
        }
        ElevatorArrivalTrace.shared.endPhase("install.mirrors", traceMirrors)
        context.coordinator.lastResetToken = runtime.resetToken
        context.coordinator.lastRebuildToken = runtime.rebuildToken
        context.coordinator.lastTheme = themeStore.current
        context.coordinator.lastWallTexture = mazeStore.wallTexture
        context.coordinator.lastFloorTexture = mazeStore.floorTexture
        context.coordinator.lastCeilingTexture = mazeStore.ceilingTexture
        context.coordinator.lastCellSurfaces = mazeStore.cellSurfaces
        context.coordinator.decorator = decorator
        let traceDecorator = ElevatorArrivalTrace.shared.beginPhase("install.DecoratorAttach")
        decorator.attach(scene: view.scene, store: mazeStore)
        ElevatorArrivalTrace.shared.endPhase("install.DecoratorAttach", traceDecorator)
        let traceDecoratorWiring = ElevatorArrivalTrace.shared.beginPhase("install.decoratorWiring")
        decorator.canEditCab = { [weak coordinator = context.coordinator] in
            coordinator?.navigationController?.canRotate == true
        }
        decorator.isPlayerInElevatorCab = { [weak coordinator = context.coordinator] in
            coordinator?.navigationController?.elevatorAwaitingEntryDirection != nil
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
            // Sept 26 (live-Decorator wall-backfill bug fix): this used
            // to omit wallTexture entirely, which defaults to nil in
            // effectiveWallImageName -- always resolving the plain
            // per-floor/theme DEFAULT (e.g. Floor 3's brick) regardless
            // of whatever override is actually in effect (e.g. an
            // explicit "wood-walnut" override), so any wall panel a
            // live Decorator action rebuilt (adding a picture, a door,
            // an empty wall) came out in the wrong, default material
            // instead of matching the walls already on screen. A full
            // scene rebuild was unaffected because HallwayScene.build
            // (fromMaze:...) always passes the real override (see its
            // ContentView call site) -- only this live, no-rebuild path
            // was missing it.
            return HallwayScene.effectiveWallImageName(floorNumber: coordinator.currentFloorNumber, theme: coordinator.lastTheme, wallTexture: coordinator.lastWallTexture)
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
        // Sept 27 (Decorator delete-staleness fix): reverse of
        // registerFloorObject just above, and unregisterRoomDoor right
        // below -- both route deletion through TapNavigationController's
        // own unregister counterparts so the live floor map and
        // navigation/mission state drop a deleted object or door
        // immediately, same shape as unregisterMirror/unregisterLiveFire/
        // unregisterLiveExtinguisher/unregisterLivePhotoBooth further
        // down already do for their own kinds.
        decorator.unregisterFloorObject = { [weak coordinator = context.coordinator] coord in
            coordinator?.navigationController?.unregisterFloorObject(at: coord)
        }
        decorator.registerRoomDoor = { [weak coordinator = context.coordinator] door in
            coordinator?.navigationController?.registerRoomDoor(door)
        }
        decorator.unregisterRoomDoor = { [weak coordinator = context.coordinator] coord in
            coordinator?.navigationController?.unregisterRoomDoor(at: coord)
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
        decorator.registerMirrorSurface = { [weak coordinator = context.coordinator, weak view] material, aspect in
            guard let coordinator else { return }
            // Sept 25 (Designer wall authoring): on a floor whose build
            // started with NO mirrors (makeUIView's surfaces scan found
            // none, so coordinator.mirrorCamera was never created), a
            // live-added mirror still needs the live feed -- create the
            // camera lazily here. updateUIView's ongoing
            // mirrorCamera?.setActive(cameraEnabled) pass picks it up on
            // the very next update, so its active state is always right.
            if coordinator.mirrorCamera == nil {
                let camera = MirrorCamera(surfaces: [], comments: mirrorComments)
                camera.playerPose = Self.mirrorPlayerPose(coordinator)
                coordinator.mirrorCamera = camera
            }
            // Oct 8: where the new glass is (one lookup, at authoring time).
            var placement: MirrorPlacement?
            view?.scene?.rootNode.enumerateChildNodes { node, stop in
                if node.name == "mirrorSurface", node.geometry?.firstMaterial === material {
                    placement = MirrorPlacement(surface: node)
                    stop.pointee = true
                }
            }
            coordinator.mirrorCamera?.addSurface(material, aspect: aspect, placement: placement)
        }
        decorator.unregisterMirrorSurface = { [weak coordinator = context.coordinator] material in
            coordinator?.mirrorCamera?.removeSurface(material)
        }
        decorator.registerMirror = { [weak coordinator = context.coordinator] coord, direction in
            coordinator?.navigationController?.registerMirror(direction, at: coord)
        }
        decorator.unregisterMirror = { [weak coordinator = context.coordinator] coord, direction in
            coordinator?.navigationController?.unregisterMirror(direction, at: coord)
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
        // Oct 1 (Decorator Games): same routing for the ten game fixtures.
        decorator.registerLiveGame = { [weak coordinator = context.coordinator] kind, direction, coord, node in
            coordinator?.navigationController?.registerGame(kind, direction: direction, node: node, at: coord)
        }
        decorator.unregisterLiveGame = { [weak coordinator = context.coordinator] kind, coord in
            coordinator?.navigationController?.unregisterGame(kind, at: coord)
        }
        // Sept 27 (Decorator Room Entrance authoring): same
        // register/unregister routing as the mirror/fire/extinguisher/
        // photo-booth pairs just above -- DecoratorState.
        // addRoomEntranceDoorAtCurrentCell/deleteRoomEntranceDoor never
        // touch TapNavigationController directly, only through these.
        decorator.registerLiveRoomEntranceDoor = { [weak coordinator = context.coordinator] direction, coord in
            coordinator?.navigationController?.registerRoomEntranceDoor(direction, at: coord)
        }
        decorator.unregisterLiveRoomEntranceDoor = { [weak coordinator = context.coordinator] coord in
            coordinator?.navigationController?.unregisterRoomEntranceDoor(at: coord)
        }
        // Sept 28 (EXIT sign map markers): same register/unregister
        // routing as roomEntranceDoor just above -- DecoratorState.
        // addExitSignAtCurrentCell/changeExitSignDirection/
        // deleteExitSign never touch TapNavigationController directly,
        // only through these.
        decorator.registerLiveExitSign = { [weak coordinator = context.coordinator] direction, coord in
            coordinator?.navigationController?.registerExitSign(direction, at: coord)
        }
        decorator.unregisterLiveExitSign = { [weak coordinator = context.coordinator] coord in
            coordinator?.navigationController?.unregisterExitSign(at: coord)
        }
        // Sept 28 (picture content moved to Decorator): Decorator's
        // Picture panel "Content..." button routes through here rather
        // than holding a TapNavigationController reference itself --
        // setting activePictureMenu is exactly what Play mode's own
        // tap-a-picture path used to do (TapNavigationController.
        // activatePictureMenu), so this opens the SAME existing Change
        // Picture menu (PictureChangeMenuHost), unconditionally mounted
        // in this view's body regardless of Decorator/Play mode.
        decorator.presentPictureChangeMenu = { [weak coordinator = context.coordinator] face in
            coordinator?.navigationController?.activePictureMenu = face
        }

        ElevatorArrivalTrace.shared.endPhase("install.decoratorWiring", traceDecoratorWiring)
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

        diag("scene.makeUIView.end", ["floor": mazeStore.currentMazeID, "seconds": Date().timeIntervalSince(diagBuildStarted),
                                      "arrivalSceneReady": navBridge.arrivalSceneReady])
    }

    func updateUIView(_ uiView: TouchTrackingSCNView, context: Context) {
        let tracePhase = ElevatorArrivalTrace.shared.beginPhase("updateUIView", "floor=\(mazeStore.currentMazeID) requestedVersion=\(mazeStore.version) installedVersion=\(context.coordinator.lastBuiltMazeVersion) scheduled=\(context.coordinator.sceneInstallScheduled)")
        defer { ElevatorArrivalTrace.shared.endPhase("updateUIView", tracePhase) }
        // Floor/model changes used to be implemented with a .id(sceneVersion)
        // modifier, which destroyed this SCNView (and its gesture
        // recognizers) and built a brand-new one. Now the view stays
        // mounted and only its scene/controller contents are reinstalled,
        // one main-loop turn later so the SwiftUI update that carried the
        // new mazeStore.version has fully settled first. sceneInstallScheduled
        // collapses repeated updateUIView passes (and the onChange that
        // rides along with a floor switch) into exactly one install.
        // makeUIView sets lastBuiltMazeVersion, so the very first
        // updateUIView after launch never double-builds.
        // Oct 5 (dev New Player reset): force one reinstall of the current floor.
        if context.coordinator.lastRebuildToken != runtime.rebuildToken {
            context.coordinator.lastRebuildToken = runtime.rebuildToken
            context.coordinator.lastBuiltMazeVersion = Int.min
            context.coordinator.forcedRebuild = true           // (Oct 17: a fresh start, never a kept Decorate pose)
        }
        if context.coordinator.lastBuiltMazeVersion != mazeStore.version,
           !context.coordinator.sceneInstallScheduled {
            context.coordinator.sceneInstallScheduled = true
            let requestedVersion = mazeStore.version
            let traceHop = ElevatorArrivalTrace.shared.beginPhase("reinstall.queueHop", "requestedVersion=\(requestedVersion) installedVersion=\(context.coordinator.lastBuiltMazeVersion)")
            DispatchQueue.main.async {
                ElevatorArrivalTrace.shared.endPhase("reinstall.queueHop", traceHop)
                context.coordinator.sceneInstallScheduled = false
                guard context.coordinator.lastBuiltMazeVersion != requestedVersion else { return }
                context.coordinator.lastBuiltMazeVersion = requestedVersion
                // Oct 5 (elevator staging): if the ride's staged destination is
                // still finishing, finish only that (bounded), then activate it.
                if navBridge.pendingElevatorArrival,
                   let staged = context.coordinator.stagedElevatorDestination,
                   staged.floor == mazeStore.currentMazeID, !staged.cancelled, !staged.isComplete {
                    var installed = false
                    let waitStarted = Date()
                    let install = {
                        guard !installed else { return }
                        installed = true
                        guard context.coordinator.lastBuiltMazeVersion == requestedVersion else { return }
                        diag("elevator.staging.arrivalWaitEnded", ["to": staged.floor, "waitMs": staged.ms(since: waitStarted),
                                                                    "complete": staged.isComplete])
                        installScene(in: uiView, context: context)
                    }
                    diag("elevator.staging.arrivalWaiting", ["to": staged.floor, "sincePressMs": staged.ms(since: staged.pressedAt)])
                    staged.whenComplete(install)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard !installed else { return }
                        staged.cancelled = true   // fall back to a normal install
                        install()
                    }
                } else {
                    installScene(in: uiView, context: context)
                }
            }
        }

        // These materials/controllers belong to the outgoing scene until the
        // queued install finishes. Applying destination edits here does work
        // that the imminent build discards, and can repaint the live old cab.
        guard context.coordinator.lastBuiltMazeVersion == mazeStore.version,
              !context.coordinator.sceneInstallScheduled else {
            ElevatorArrivalTrace.shared.event("updateUIView.outgoingSyncSkipped")
            return
        }

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
        let traceCameraReset = ElevatorArrivalTrace.shared.beginPhase("updateUIView.cameraAndReset")
        context.coordinator.navigationController?.decorateModeEnabled = decorator.enabled
        context.coordinator.mirrorCamera?.setActive(cameraEnabled)
        context.coordinator.mirrorCamera?.setExpressionAnalysisEnabled(cameraEnabled && mirrorComments.looking)
        HallwaysAudio.shared.attach(engine: uiView.audioEngine)   // Oct 8: re-assert mute (cheap; no-op if set)
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
        ElevatorArrivalTrace.shared.endPhase("updateUIView.cameraAndReset", traceCameraReset)
        // Sept 27 (Decorator Surfaces): widened from a lastTheme-only
        // diff to also watch wallTexture/floorTexture/ceilingTexture --
        // Decorator's new Surfaces picker changes those three directly,
        // live, with no mazeStore.version bump (same "swap the retained
        // material's contents in place" mechanism the theme button
        // already uses, per applyTheme's own updated doc comment). Any
        // one of the four changing re-applies through the SAME call, so
        // there's exactly one place that decides what's effective.
        let traceSurfaceSync = ElevatorArrivalTrace.shared.beginPhase("updateUIView.surfaceSync")
        if context.coordinator.lastTheme != themeStore.current
            || context.coordinator.lastWallTexture != mazeStore.wallTexture
            || context.coordinator.lastFloorTexture != mazeStore.floorTexture
            || context.coordinator.lastCeilingTexture != mazeStore.ceilingTexture
            || context.coordinator.lastCellSurfaces != mazeStore.cellSurfaces {
            context.coordinator.lastTheme = themeStore.current
            context.coordinator.lastWallTexture = mazeStore.wallTexture
            context.coordinator.lastFloorTexture = mazeStore.floorTexture
            context.coordinator.lastCeilingTexture = mazeStore.ceilingTexture
            context.coordinator.lastCellSurfaces = mazeStore.cellSurfaces
            context.coordinator.applyTheme(themeStore.current, wallTexture: mazeStore.wallTexture, floorTexture: mazeStore.floorTexture, ceilingTexture: mazeStore.ceilingTexture, cellSurfaces: mazeStore.cellSurfaces, root: uiView.scene?.rootNode)
        }

        ElevatorArrivalTrace.shared.endPhase("updateUIView.surfaceSync", traceSurfaceSync)
        // Sept 20 (picture-teleport fix): the in-gameplay Change
        // Picture menu (PictureChangeMenuHost) mutates
        // mazeStore.pictureImageSelections directly, with NO
        // mazeStore.version bump -- same "swap the retained material's
        // contents in place, no scene rebuild" mechanism applyTheme
        // just above already uses for the theme button, so the player
        // is never moved. Only the coord(s) whose selection actually
        // changed since the last pass get re-applied; everything else
        // (including the picture(s) already correct from the initial
        // build) is left alone.
        let tracePictureSync = ElevatorArrivalTrace.shared.beginPhase("updateUIView.pictureSync")
        if context.coordinator.lastPictureImageSelections != mazeStore.pictureImageSelections {
            let previous = context.coordinator.lastPictureImageSelections
            let current = mazeStore.pictureImageSelections
            context.coordinator.lastPictureImageSelections = current
            for (face, selection) in current {
                guard previous[face] != selection, let material = context.coordinator.pictureMaterials[face] else { continue }
                context.coordinator.applyLivePictureSelection(selection, to: material)
            }
        }

        ElevatorArrivalTrace.shared.endPhase("updateUIView.pictureSync", tracePictureSync)
        // Sept 26 (Decorate-mode elevator pictures): the elevator-
        // poster counterpart to the pictureImageSelections diff just
        // above -- Decorate mode's new Image section
        // (DecoratorOverlay's .elevatorPosterSurface branch) mutates
        // mazeStore.elevatorCabDecoration.backArtwork/sideArtwork
        // directly (via setElevatorBackArtwork/setElevatorSideArtwork),
        // with no mazeStore.version bump, so the live SceneKit material has
        // to be swapped here the same "no rebuild, player never moved"
        // way. Reuses TapNavigationController.applyElevatorPosterImage
        // (the SAME method Play mode's own in-ride Change Picture menu
        // calls) purely as the material-write mechanism -- this is
        // still the only place that DECIDES to persist an elevator
        // poster choice; Play mode's own calls to that method remain
        // exactly as ephemeral/unpersisted as its doc comment says.
        let traceArtwork = ElevatorArrivalTrace.shared.beginPhase("updateUIView.cabArtworkSync")
        if context.coordinator.lastElevatorBackArtwork != mazeStore.elevatorCabDecoration.backArtwork {
            context.coordinator.lastElevatorBackArtwork = mazeStore.elevatorCabDecoration.backArtwork
            if let selection = mazeStore.elevatorCabDecoration.backArtwork {
                context.coordinator.resolvePictureImage(selection, floorNumber: mazeStore.currentMazeID) { [weak navigationController = context.coordinator.navigationController] image in
                    guard let image, let navigationController else { return }
                    navigationController.applyElevatorPosterImage(image, to: .back)
                }
            }
        }
        if context.coordinator.lastElevatorSideArtwork != mazeStore.elevatorCabDecoration.sideArtwork {
            context.coordinator.lastElevatorSideArtwork = mazeStore.elevatorCabDecoration.sideArtwork
            if let selection = mazeStore.elevatorCabDecoration.sideArtwork {
                context.coordinator.resolvePictureImage(selection, floorNumber: mazeStore.currentMazeID) { [weak navigationController = context.coordinator.navigationController] image in
                    guard let image, let navigationController else { return }
                    navigationController.applyElevatorPosterImage(image, to: .side)
                }
            }
        }
        // Sept 26 (third elevator poster, right wall): same live-swap
        // diff as the back/side blocks just above.
        if context.coordinator.lastElevatorSideRightArtwork != mazeStore.elevatorCabDecoration.sideRightArtwork {
            context.coordinator.lastElevatorSideRightArtwork = mazeStore.elevatorCabDecoration.sideRightArtwork
            if let selection = mazeStore.elevatorCabDecoration.sideRightArtwork {
                context.coordinator.resolvePictureImage(selection, floorNumber: mazeStore.currentMazeID) { [weak navigationController = context.coordinator.navigationController] image in
                    guard let image, let navigationController else { return }
                    navigationController.applyElevatorPosterImage(image, to: .sideRight)
                }
            }
        }

        ElevatorArrivalTrace.shared.endPhase("updateUIView.cabArtworkSync", traceArtwork)
    }

    /// Oct 8 (Cool Hallways): the player's floor position and heading for
    /// MirrorCamera's demand checks (a read of the camera node; no raycast).
    static func mirrorPlayerPose(_ coordinator: Coordinator) -> () -> (position: SIMD2<Float>, yaw: Float)? {
        { [weak coordinator] in
            guard let camera = coordinator?.navigationController?.cameraNode.presentation else { return nil }
            let p = camera.worldPosition
            return (SIMD2<Float>(p.x, p.z), camera.eulerAngles.y)
        }
    }

    static func dismantleUIView(_ uiView: TouchTrackingSCNView, coordinator: Coordinator) {
        let traceDismantle = ElevatorArrivalTrace.shared.beginPhase("SCNView.dismantleUIView")
        defer { ElevatorArrivalTrace.shared.endPhase("SCNView.dismantleUIView", traceDismantle) }
        coordinator.mirrorCamera?.setActive(false)
        uiView.delegate = nil
        uiView.isPlaying = false
    }

    final class Coordinator: NSObject {
        // Persistent-SCNView floor-swap bookkeeping.
        var lastBuiltMazeVersion: Int = -1
        /// Oct 17: the next install is the forced (dev reset) rebuild.
        var forcedRebuild = false
        var sceneInstallScheduled = false
        var didInstallPersistentGestures = false
        /// Oct 5 (elevator staging): the destination floor being prepared
        /// during the current ride (see stageElevatorDestination).
        var stagedElevatorDestination: StagedElevatorDestination?

        /// Arrival: hands over the staged destination when it is complete
        /// and belongs to the floor now being installed; otherwise nil (the
        /// install builds normally). A stale or mismatched staging is dropped.
        func takeStagedElevatorDestination(for floor: Int, arriving: Bool) -> StagedElevatorDestination? {
            guard let staged = stagedElevatorDestination else { return nil }
            if staged.floor != floor && !arriving { return nil } // unrelated rebuild of the source floor
            stagedElevatorDestination = nil
            guard arriving, staged.floor == floor, !staged.cancelled, staged.isComplete else {
                staged.cancelled = true
                diag("elevator.staging.discarded", ["staged": staged.floor, "installing": floor,
                                                    "arriving": arriving, "complete": staged.isComplete])
                return nil
            }
            return staged
        }
        /// Oct 4: false = a Play-mode tap on an elevator poster no longer opens
        /// the change-photo menu (picture content belongs to Decorate).
        static let elevatorPosterMenuInPlay = false
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
        var lastRebuildToken = 0
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
        // Sept 26 (Decorate-mode elevator pictures): the elevator-
        // poster counterpart to lastPictureImageSelections above --
        // the baseline updateUIView diffs mazeStore.elevatorCabDecoration.
        // backArtwork/sideArtwork against, so only a surface whose
        // authored choice actually changed gets re-resolved/re-applied.
        var lastElevatorBackArtwork: PictureImageSelection?
        var lastElevatorSideArtwork: PictureImageSelection?
        var lastElevatorSideRightArtwork: PictureImageSelection?
        // Sept 14 (Eddie): so applyTheme() below can tell Floor 1 (the
        // lobby) apart from every other floor when it re-picks the
        // floor image -- mirrors mazeStore.currentMazeID, the same
        // floor/maze identifier HallwayScene.build(fromMaze:) is
        // already called with.
        var currentFloorNumber: Int = 1
        var lastTheme: HallwayTheme = .brick
        // Sept 26 (live-Decorator wall-backfill bug): the per-floor
        // WALL override from the Floor Editor's "Floor Surfaces" sheet
        // (mazeStore.wallTexture -- nil means no override, back to the
        // plain per-floor/theme default). Tracked here the same way
        // lastTheme is, and for the same reason: a live in-Decorator
        // wall rebuild (adding a picture, a door, an empty-wall panel)
        // needs "the wall image actually baked into the CURRENT scene,"
        // not a fresh from-scratch default lookup.
        // Sept 27 (Decorator Surfaces): a wallTexture/floorTexture/
        // ceilingTexture change USED to only ever happen through the
        // Floor Editor's Save (which forces a full scene rebuild -- see
        // the sheet's onDismiss version check), so this comment used to
        // say no updateUIView diff/apply path was needed. Decorator's
        // new Surfaces picker changes these three properties directly,
        // live, with NO rebuild -- so now, like lastTheme, all three
        // need an explicit diff in updateUIView (see applyTheme's own
        // updated doc comment) that reapplies materials in place.
        var lastWallTexture: String? = nil
        var lastFloorTexture: String? = nil
        var lastCeilingTexture: String? = nil
        /// Oct 1 (cell-surface overrides): diffed like the three above.
        var lastCellSurfaces: [GridCoordinate: CellSurfaceOverride] = [:]


        // Drag-controlled left/right turning: how many points of
        // horizontal drag equal one full 90-degree turn. Purely a feel
        // constant — smaller means a shorter drag commits a turn,
        // larger means a longer, more deliberate one.
        private let dragRotateDistance: CGFloat = 140

        // Sept 30 A/B experiment: HELD-WALK steering only (the free held
        // walk's X = turn). Points of horizontal finger travel per 90
        // degrees while walking; was dragRotateDistance (140). Ordinary
        // Free Look / pan and held-endpoint look keep dragRotateDistance.
        private let heldWalkSteerDistance: CGFloat = 230

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
        // Oct 19 (elevator threshold by swipe): the axis an in-cab pan locked
        // to (vertical = a swipe out through the doors); outside, a pan near an
        // open cab waits for the axis before it starts; and a pan claimed as a
        // threshold swipe. See TapNavigationController.elevatorThresholdCrossing.
        private var elevatorPanAxis: PanDragAxis?
        private var thresholdPanPending = false
        private var thresholdPanClaimed = false
        /// A threshold swipe commits past this fraction of dragMoveDistance, or this flick speed (fractions/s).
        static let thresholdSwipeCommit: Double = 0.12
        static let thresholdSwipeFlick: Double = 0.6

        /// The direction a claimed threshold swipe was claimed in (true: finger down).
        private var thresholdSwipeForward = true

        /// Claims the pan as a threshold swipe: the camera follows the finger from now on.
        private func claimThresholdSwipe(_ controller: TapNavigationController, translation: CGPoint) -> Bool {
            let forward = translation.y > 0
            guard controller.beginThresholdScrub(forward: forward) else { return false }
            thresholdSwipeForward = forward
            controller.updateThresholdScrub(cells: thresholdSwipeCells(translation))
            return true
        }

        /// How far (cells) the finger has walked the player toward the crossing -- a hallway drag's own scale.
        private func thresholdSwipeCells(_ translation: CGPoint) -> Double {
            let f = Double(translation.y / dragMoveDistance)
            return max(0, thresholdSwipeForward ? f : -f)
        }

        /// Released: on through the doorway if it went far or fast enough (and wasn't reversed), else back.
        private func finishThresholdSwipe(_ controller: TapNavigationController, translation: CGPoint, velocity: CGPoint) {
            let f = thresholdSwipeCells(translation)
            let v = Double(velocity.y / dragMoveDistance) * (thresholdSwipeForward ? 1 : -1)
            let committed = v > -Self.thresholdSwipeFlick && (f >= Self.thresholdSwipeCommit || v >= Self.thresholdSwipeFlick)
            navLog("threshold swipe ended forward=\(thresholdSwipeForward) cells=\(String(format: "%.2f", f)) velocity=\(String(format: "%.2f", v)) committed=\(committed)")
            controller.endThresholdScrub(commit: committed)
        }

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

        // Ticks while a long-press-forward is held -- see
        // handleLongPressForward below. nil whenever nothing's held.
        private var forwardHoldTimer: Timer?

        func cancelElevatorHandoffInput(in view: UIView?) {
            cancelHeldWalkForMap()
            panIsHoldTakeover = false
            // Cancel pending tap/press recognition before replacing its controller.
            for recognizer in view?.gestureRecognizers ?? [] {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
        }

        /// Oct 8 flight recorder: the begin and end of a continuous gesture
        /// (never its per-frame changes), with where the player was.
        func diagGesture(_ name: String, _ gesture: UIGestureRecognizer) {
            let state: String
            switch gesture.state {
            case .began: state = "began"
            case .ended: state = "ended"
            case .cancelled: state = "cancelled"
            case .failed: state = "failed"
            default: return
            }
            let c = navigationController
            diag("gesture." + name, ["state": state, "cell": c?.currentCell, "facing": c?.facing,
                                     "tapWalking": c?.isFreeTapWalking, "ride": c?.isElevatorRideInProgress])
        }

        func cancelHeldWalkForMap() {
            navigationController?.stopWalkLatch(reason: "cancelHeld")     // Oct 16 (walk latch)
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
        /// Oct 12: seated look -- this drag turns the head (not the zoomed lens's pan).
        private var seatedLookPan = false

        /// Oct 12: the tap landed on the player's office workstation (computer,
        /// desk or chair), on the office floor, outside Decorate -- the same
        /// test the sit-down tap below uses.
        func officeWorkstationTapped(_ gesture: UITapGestureRecognizer, controller: TapNavigationController) -> Bool {
            guard decorator?.enabled != true, controller.currentFloorNumber == PlayerOffice.floor,
                  let view = gesture.view as? SCNView,
                  let hit = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                              options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                        .ignoreHiddenNodes: true])).first else { return false }
            return PlayerOffice.isWorkstation(hit.node)
        }

        /// Oct 15: the office filing cabinet -- at it (in its pose): toggle the
        /// top drawer; elsewhere in the office: glide over, then open it.
        func useOfficeCabinet(controller: TapNavigationController) {
            guard let pose = PlayerOffice.cabinetStandPose(eyeY: controller.cameraNode.position.y) else { return }
            let here = controller.cameraNode.position
            if hypotf(here.x - pose.position.x, here.z - pose.position.z) < 0.6 {
                PlayerOffice.toggleCabinetDrawer()
                SmartTap.log("interaction", ["target": "cabinet", "via": "here"])
                return
            }
            let approached = controller.approachPose(kind: "officeCabinet", position: pose.position, yaw: pose.yaw) {
                if !PlayerOffice.cabinetDrawerOpen { PlayerOffice.toggleCabinetDrawer() }
            }
            SmartTap.log(approached ? "direct" : "directRefused", ["target": "cabinet", "via": "approach"])
        }

        /// Oct 15: after getting up from the desk -- once the stand-up glide is
        /// over and movement is free (up to 4 s) -- the cabinet.
        func useOfficeCabinetWhenStanding(controller: TapNavigationController, waited: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak controller] in
                guard let self, let controller, controller.currentFloorNumber == PlayerOffice.floor else { return }
                if OfficeComputer.shared.phase == .off, controller.canRotate {
                    self.useOfficeCabinet(controller: controller)
                } else if waited < 4 {
                    self.useOfficeCabinetWhenStanding(controller: controller, waited: waited + 0.1)
                } else {
                    diag("office.cabinet.gaveUp", ["blockers": controller.diagCanRotateBlockers])
                }
            }
        }

        /// Oct 25: does a tap at `point` land on a resident (CritterTapTarget's own rule)?
        static func tapIsOnResident(_ point: CGPoint, in view: SCNView, controller: TapNavigationController) -> Bool {
            if case .resident = CritterTapTarget.resolve(at: point, in: view, controller: controller) { return true }
            return false
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            MudProbe.shared.handled("tap", mayWalk: true)                    // Oct 24 (mud probe): measurement only
            guard let controller = navigationController else {
                diag("tap.ignored", ["reason": "no navigation controller"])
                return
            }
            // Oct 16 (Bonzo's eviction): in his grip, the player has no say.
            if controller.evictionLocked {
                diag("tap.ignored", ["reason": "bonzo eviction"])
                return
            }
            // Oct 2 flight recorder: one compact line per tap (human-rate).
            diag("tap.received", ["cell": controller.currentCell, "rideInProgress": controller.isElevatorRideInProgress,
                                  "freeTapWalking": controller.isFreeTapWalking])
            // Oct 20 (follow a critter): a tap on a roaming resident follows it (again:
            // stops; another: switches) -- ahead of the walk's brake below, so the
            // second tap on it works while walking after it. Any other tap while
            // following ends the following and goes on as an ordinary tap.
            // Oct 25 (elevator tap fix): standing in the stopped cab with its doors fully open, a tap that lands
            // on a critter seen through the doorway opens its menu too (it used to fall through to the walk out:
            // this whole test was skipped for any "ride in progress", which the arrival dwell still is). Only a
            // tap that resolves to a resident is taken here (CritterTapTarget: solid things -- the cab's walls,
            // shut doors -- hide what's behind them); any other tap in the cab goes on exactly as before.
            let cabDoorsOpen = controller.isElevatorRideInProgress && controller.elevatorDoorsOpenIdle
            if decorator?.enabled != true, !controller.isElevatorRideInProgress || cabDoorsOpen, let view = gesture.view as? SCNView,
               !cabDoorsOpen || Self.tapIsOnResident(gesture.location(in: view), in: view, controller: controller),
               CritterFollow.handleTap(at: gesture.location(in: view), in: view, controller: controller) {
                diag("tap.consumed", ["by": "follow a critter", "following": CritterFollow.targetID ?? "nobody"])
                return
            }
            // TAP AGAIN -> STOP (Sept 30): while a navigation-tap walk is under
            // way the whole screen is a brake -- ahead of every interaction
            // below, and it never starts a new walk in the same tap.
            if controller.isFreeTapWalking {
                // Oct 12: a tap on the office computer from inside the office
                // still means "sit down" -- the walk stops, then the seat.
                if officeWorkstationTapped(gesture, controller: controller), let view = gesture.view as? SCNView,
                   OfficeComputer.shared.sitDownWhenSettled(controller: controller, view: view) {
                    diag("tap.consumed", ["by": "office computer (while walking)"])
                    return
                }
                controller.stopFreeTapWalk()
                diag("tap.stoppedFreeTapWalk")
                SmartTap.log("interrupt", ["walk": "tap", "moving": true])          // Oct 15
                return
            }
            // Oct 16 (WALK LATCH): same brake for the latched walk -- the tap only stops it.
            if controller.isWalkLatched {
                controller.stopWalkLatch(reason: "tap")
                controller.stopContinuousWalk(reason: "tap")                // (nothing of GO left waiting either)
                if officeWorkstationTapped(gesture, controller: controller), let view = gesture.view as? SCNView,
                   OfficeComputer.shared.sitDownWhenSettled(controller: controller, view: view) {
                    diag("tap.consumed", ["by": "office computer (while walking)"])
                    return
                }
                SmartTap.log("interrupt", ["walk": "latch", "moving": true])
                return
            }
            // Oct 10 (continuous walk): same brake for the WALK-button walk.
            if controller.continuousWalkState != .stopped {
                if officeWorkstationTapped(gesture, controller: controller), let view = gesture.view as? SCNView,
                   OfficeComputer.shared.sitDownWhenSettled(controller: controller, view: view) {      // Oct 12
                    diag("tap.consumed", ["by": "office computer (while walking)"])
                    return
                }
                controller.stopContinuousWalk(reason: "tap")
                SmartTap.log("interrupt", ["walk": "auto", "moving": true])         // Oct 15
                return
            }
            // Oct 7 (F, physical monitor): seated at the office computer, the
            // monitor's own screen (a SwiftUI surface laid exactly over the
            // 3D screen) takes taps inside it. A tap that reaches the world
            // here landed OUTSIDE it: that is the player getting up from the
            // desk -- never a walk to the tapped spot. A tap on the computer
            // hardware itself (bezel, stand, keyboard) belongs to the computer
            // and does nothing. During the sit/stand glides taps are ignored.
            if OfficeComputer.shared.isActive {
                if OfficeComputer.shared.phase == .on, let view = gesture.view as? SCNView {
                    let hit = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.closest.rawValue,
                                                                              .ignoreHiddenNodes: true]).first
                    if let hit, BlackBox.owns(hit.node) {
                        // Oct 12: the Black Box on the desk -- play (or stop); the player stays seated.
                        BlackBox.tapped(playerCell: controller.currentCell)
                        diag("tap.consumed", ["by": "black box (seated)"])
                    } else if let hit, PlayerOffice.isDeskPhoto(hit.node) {
                        // Oct 7: seated only -- the desk photo gets a new random
                        // camera-roll photo; the player stays put, the computer
                        // is untouched.
                        PlayerOffice.changeDeskPhoto()
                        diag("tap.consumed", ["by": "desk photo (new photo)"])
                    } else if SmartTap.isOn, let hit, PlayerOffice.isCabinet(hit.node) {
                        // Oct 15: the filing cabinet -- up from the desk, over to it, the drawer.
                        OfficeComputer.shared.getUp()
                        useOfficeCabinetWhenStanding(controller: controller, waited: 0)
                        diag("tap.consumed", ["by": "filing cabinet (from the desk)"])
                    } else if !OfficeComputer.shared.isFacingComputer,
                              !SmartTap.isOn || (hit.map { PlayerOffice.isComputerHardware($0.node) } ?? false) {
                        // Oct 12 (seated look): looking away, a tap on the room
                        // turns back to the monitor; facing it, the room means get up.
                        // Oct 12: on one of the desktop's buttons? Turn back, then press it.
                        // (Oct 15, Smart Tap: only a tap ON the computer turns back to it --
                        // a tap on the room, looking away, is getting up, as facing it.)
                        OfficeComputer.shared.tapWhileTurned(windowPoint: view.convert(gesture.location(in: view), to: nil))
                        diag("tap.consumed", ["by": "face the computer", "hit": hit?.node.name ?? "nothing"])
                    } else if OfficeComputer.shared.isFacingComputer, let hit, PlayerOffice.isComputerHardware(hit.node) {
                        diag("tap.consumed", ["by": "office computer hardware"])
                    } else {
                        OfficeComputer.shared.getUp()
                        diag("tap.consumed", ["by": "get up from desk", "hit": hit?.node.name ?? "nothing"])
                    }
                } else {
                    diag("tap.ignored", ["reason": "office computer transition"])
                }
                return
            }
            // Oct 11 (the staff meeting): seated at the conference table, a tap
            // in the world is getting up -- as at the office desk. During the
            // sit/stand glides taps are ignored.
            if ConferenceMeeting.isActive {
                // Oct 12 (the room remembers): seated, a tap that lands on a cast
                // member is theirs (MeetingConversation) -- never STAND; while
                // THE BOX is on, a tap on the screen is Harold's.
                if ConferenceMeeting.phase == .seated, ConferenceAudition.isInstalled, let view = gesture.view as? SCNView,
                   let hit = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                             .ignoreHiddenNodes: true])
                    .first(where: { $0.node.name != "meetingProjectorBeam" }) {
                    if let member = ConferenceAudition.member(for: hit.node) {
                        MeetingConversation.tapped(member)
                        diag("tap.consumed", ["by": "meeting character", "who": member.name])
                        return
                    }
                    if BoxReveal.isRunning, BoxReveal.isProjectionScreen(hit.node) {
                        BoxReveal.haroldTapped()
                        diag("tap.consumed", ["by": "Harold (on the screen)"])
                        return
                    }
                }
                // Oct 12: seated, a tap on the screen or the projector REPLAYS THE BOX (once it has been shown).
                // (Resume-state fix: or starts a meeting that is ready; and it NEVER
                // stands the player up -- it used to whenever there was nothing to replay.)
                if ConferenceMeeting.phase == .seated, let view = gesture.view as? SCNView,
                   let hit = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                             .ignoreHiddenNodes: true])
                    .first(where: { $0.node.name != "meetingProjectorBeam" }),        // (looked through, never hit)
                   BoxReveal.isScreen(hit.node), BoxReveal.equipmentTapped(seated: true) {
                    diag("tap.consumed", ["by": "presentation equipment (seated)"])
                    return
                }
                if ConferenceMeeting.phase == .seated {
                    ConferenceMeeting.standUp(reason: "tap")
                    diag("tap.consumed", ["by": "get up from the meeting"])
                } else {
                    diag("tap.ignored", ["reason": "meeting seat transition"])
                }
                return
            }
            // Oct 16 (Supplies): a tap on something carried (in a hand, or a
            // follower in view) is about that thing -- a little lift or hop, no
            // words -- never a walk. On Floor 4 a tap whose nearest surface is a
            // tool (or its marked place) takes it (or, if it's out, sends it
            // back). Both ahead of everything below.
            if decorator?.enabled != true, let view = gesture.view as? SCNView {
                let point = gesture.location(in: view)
                // (a tap: the drawn shape only -- the hand corners stay open for taps on the room)
                // Oct 16 (VI): at the elevator panel every tap is the panel's, never a carried tool's.
                let atPanel = controller.isElevatorWaitingForFloor || controller.isElevatorRideInProgress || controller.elevatorDoorsOpenIdle
                if !atPanel, let tool = ToolBelt.tool(at: point, in: view, generous: false) {
                    Supplies.carriedTapped(tool)
                    diag("tap.consumed", ["by": "carried tool", "tool": tool.rawValue])
                    return
                }
                if !atPanel, controller.carryingExtinguisher, let rect = ToolBelt.hallwayExtinguisherRect(in: view, generous: false), rect.contains(point) {
                    diag("tap.consumed", ["by": "held wall extinguisher"])
                    return
                }
                // Oct 16 (VIII): Floor 5's breaker panel -- a tap on it opens it,
                // resets the tripped breaker, or (out of reach) walks up to it.
                if !atPanel, controller.currentFloorNumber == FloorFiveBlackout.floor {
                    let hits = Posse.navigationHits(view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                                  .ignoreHiddenNodes: true]))
                        .filter { !ToolBelt.owns($0.node) }
                    if FloorFiveBlackout.handleTap(hits: hits, controller: controller) {
                        diag("tap.consumed", ["by": "floor 5 breaker panel"])
                        return
                    }
                }
                // Oct 16 (IV): Supplies is a dense room -- a tap there is about what it
                // touches. A tool (or its marked place) is interacted with; anything
                // else that isn't floor (shelf, pegboard, bench, wall, a box) is NOT a
                // walk into it: the player walks toward it only as far as a
                // comfortable 1.7 m short of it, or, already that close, stays put.
                // Bare floor taps fall through to ordinary tap-to-walk below.
                if controller.currentFloorNumber == SuppliesShowroom.floor, !controller.isElevatorRideInProgress,
                   !controller.isElevatorWaitingForFloor {
                    let hits = Posse.navigationHits(view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                                  .ignoreHiddenNodes: true]))
                        .filter { !ToolBelt.owns($0.node) }
                    let eye = controller.cameraNode.worldPosition
                    if let tool = SuppliesShowroom.toolTarget(hits: hits, point: point, view: view, eye: eye) {
                        Supplies.toolTapped(tool, controller: controller)
                        diag("tap.consumed", ["by": "supply tool", "tool": tool.rawValue])
                        return
                    }
                    if let first = hits.first, SuppliesShowroom.containsXZ(first.worldCoordinates, margin: 0.3),
                       !(first.worldNormal.y > 0.6 && first.worldCoordinates.y < 0.12) {
                        let dx = Double(first.worldCoordinates.x - eye.x), dz = Double(first.worldCoordinates.z - eye.z)
                        let d = (dx * dx + dz * dz).squareRoot()
                        let walk = d - 1.7
                        if walk > 0.35, d > 1e-6 {
                            controller.advance(travelDirection: (dx / d, dz / d), travelDistance: walk)
                            diag("tap.consumed", ["by": "supplies surface (approach, stops short)", "walk": walk])
                        } else {
                            diag("tap.consumed", ["by": "supplies surface (already close: stay)"])
                        }
                        return
                    }
                }
            }
            // Oct 4 interactive elevator: while the car WAITS, a tap on the
            // control panel presses the nearest floor button (a following
            // posse member in front is looked past, as everywhere).
            if controller.isElevatorWaitingForFloor, let view = gesture.view as? SCNView {
                let hits = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                             options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true]))
                if controller.pressElevatorButton(hits: hits) {
                    diag("tap.consumed", ["by": "elevator panel"])
                    return
                }
            }
            // Oct 6 (polish): while the finished ID card is out and waiting at
            // the kiosk (and the player is still at the kiosk), ANY tap takes
            // it. Only in that one state; every other tap is untouched.
            if decorator?.enabled != true, let terminal = AdministrationIDTerminal.current, terminal.isCardWaiting,
               controller.currentCell == AdministrationReception.photoStationCell {
                terminal.takeWaitingCard()
                diag("tap.consumed", ["by": "id card (anywhere)"])
                return
            }
            if let view = gesture.view as? SCNView, controller.canRotate,
               decorator?.select(at: gesture.location(in: view), in: view) == true {
                diag("tap.consumed", ["by": "decorator selection"])
                return
            }
            // Oct 4 FREDDY: a tap that lands on a posse member (Freddy) engages
            // him -- not following: he follows -- and is NOT also a tap-walk.
            if let view = gesture.view as? SCNView, Posse.handleTap(in: view, at: gesture.location(in: view)) {
                diag("tap.consumed", ["by": "posse member"])
                return
            }
            // Oct 5 (open-door cab taps): standing in the arrived cab with the
            // doors open, only a tap THROUGH the doorway onto the hallway is an
            // exit. A tap on any cab-interior surface (walls, panel, an actual
            // button) stays in the cab -- free look/swivel only, no walk.
            // Oct 5 (Administration): a tap on the Administrator goes straight
            // through the reception desk landing (one glide to the visitor's
            // pose -- never the generic close-in approach), then she gives the
            // directions again, with visit-local, fraying patience.
            if decorator?.enabled != true, let view = gesture.view as? SCNView,
               controller.landingSpots.contains(where: { $0.kind == "receptionDesk" }),
               let hit = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                           options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                     .ignoreHiddenNodes: true])).first,
               AdministrationReception.isAdministrator(hit.node) {
                // Oct 9: she's out in the doorway (or on her way) -- no glide
                // to an empty counter; she answers where she stands.
                if AdministrationExitGuard.isAway {
                    AdministrationExitGuard.tapped()
                    diag("tap.consumed", ["by": "administrator (in the exit)"])
                    return
                }
                // Oct 15 (Smart Tap): tapped WHILE she is giving directions (her
                // greeting/point -- taps used to be ignored then) = "OK, going":
                // to the kiosk before the ID, to Tinky's desk after it.
                if SmartTap.isOn, AdministrationReception.isGivingDirections,
                   let target = AdministrationReception.directionsTarget {
                    var accepted = false
                    switch target {
                    case .kiosk:
                        accepted = !Admission.isCompleted && AdministrationIDTerminal.current != nil
                            && controller.beginLanding(kind: AdministrationIDTerminal.landingKind)
                    case .office:
                        accepted = controller.smartTapWalkToTinky()
                    }
                    SmartTap.log(accepted ? "contextual" : "contextualRefused",
                                 ["trigger": "juanitaPointing", "to": target.rawValue, "moving": false])
                    if accepted {
                        diag("tap.consumed", ["by": "administrator's directions (accepted)"])
                        return
                    }
                }
                AdministrationReception.directionsRequested = true
                if controller.isInLandingPose("receptionDesk"), let root = view.scene?.rootNode {
                    diag("juanita.tapped", ["atCounter": true])
                    AdministrationReception.landedAtDesk(in: root)
                } else if !controller.beginLanding(kind: "receptionDesk") {
                    AdministrationReception.directionsRequested = false
                    diag("juanita.ignored", ["reason": "counterLandingRefused", "cell": "\(controller.currentCell)"])
                } else {
                    diag("juanita.tapped", ["atCounter": false, "action": "landingToCounter"])
                }
                diag("tap.consumed", ["by": "administrator"])
                return
            }
            // Oct 12 (the Black Box): a tap on the little black cube on the
            // office desk, from inside the office, is for it -- it plays (or
            // stops) -- never a sit-down or a walk. From outside: ordinary tap.
            if decorator?.enabled != true, controller.currentFloorNumber == PlayerOffice.floor,
               let view = gesture.view as? SCNView,
               let hit = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                           options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                     .ignoreHiddenNodes: true])).first,
               BlackBox.owns(hit.node), BlackBox.tapped(playerCell: controller.currentCell) {
                diag("tap.consumed", ["by": "black box"])
                return
            }
            // Oct 15 (direct interactions): the office filing cabinet, from inside
            // the office -- over to it (unless already there), and the top drawer
            // opens; tapped again, it shuts.
            if SmartTap.isOn, decorator?.enabled != true, controller.currentFloorNumber == PlayerOffice.floor,
               PlayerOffice.officeCells.contains(controller.currentCell), let view = gesture.view as? SCNView,
               let hit = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                           options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                     .ignoreHiddenNodes: true])).first,
               PlayerOffice.isCabinet(hit.node) {
                useOfficeCabinet(controller: controller)
                diag("tap.consumed", ["by": "filing cabinet"])
                return
            }
            // Oct 7 (F): the player's office computer. A tap on the computer,
            // its desk or its chair from inside the office sits the player
            // down (OfficeComputer). From anywhere else it is an ordinary tap.
            if decorator?.enabled != true, controller.currentFloorNumber == PlayerOffice.floor,
               let view = gesture.view as? SCNView,
               let hit = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                           options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                     .ignoreHiddenNodes: true])).first,
               PlayerOffice.isWorkstation(hit.node),
               OfficeComputer.shared.sitDownWhenSettled(controller: controller, view: view) {      // Oct 12: once settled
                diag("tap.consumed", ["by": "office computer"])
                return
            }
            // Oct 11 (the staff meeting): a tap on the empty chair at the foot
            // of the conference table, from the player's side of the room,
            // sits the player down (same as USE). Anywhere else: ordinary tap.
            if decorator?.enabled != true, controller.currentFloorNumber == ConferenceRoom.floor,
               let view = gesture.view as? SCNView,
               let hit = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                           options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                     .ignoreHiddenNodes: true])).first,
               ConferenceMeeting.isEmptyChair(hit.node),
               ConferenceMeeting.sit(controller: controller, source: "tap") {
                diag("tap.consumed", ["by": "meeting chair"])
                return
            }
            // Oct 12 (the room remembers): standing in the conference room, a tap
            // that lands on a cast member (nearest thing under the finger) is
            // theirs -- never a walk. Empty space still walks.
            if decorator?.enabled != true, controller.currentFloorNumber == ConferenceRoom.floor,
               ConferenceRoom.roomCells.contains(controller.currentCell), ConferenceAudition.isInstalled,
               let view = gesture.view as? SCNView,
               let hit = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                         .ignoreHiddenNodes: true])
                .first(where: { $0.node.name != "meetingProjectorBeam" }) {
                if let member = ConferenceAudition.member(for: hit.node) {
                    MeetingConversation.tapped(member)
                    diag("tap.consumed", ["by": "meeting character", "who": member.name])
                    return
                }
                if BoxReveal.isRunning, BoxReveal.isProjectionScreen(hit.node) {
                    BoxReveal.haroldTapped()
                    diag("tap.consumed", ["by": "Harold (on the screen)"])
                    return
                }
            }
            // Oct 12: standing in the conference room, a tap on the screen or projector REPLAYS THE BOX.
            if decorator?.enabled != true, controller.currentFloorNumber == ConferenceRoom.floor,
               ConferenceRoom.roomCells.contains(controller.currentCell),
               let view = gesture.view as? SCNView,
               let hit = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                         .ignoreHiddenNodes: true])
                .first(where: { $0.node.name != "meetingProjectorBeam" }),            // (looked through, never hit)
               BoxReveal.isScreen(hit.node), BoxReveal.equipmentTapped(seated: false) {   // (resume-state fix: or starts a ready meeting)
                diag("tap.consumed", ["by": "presentation equipment (standing)"])
                return
            }
            // Oct 5 (Administration ID terminal): a tap on the terminal from
            // anywhere lands you squarely in front of it; once there, taps on
            // its screen press its machine buttons.
            if decorator?.enabled != true, let view = gesture.view as? SCNView,
               let hit = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                           options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                     .ignoreHiddenNodes: true])).first,
               AdministrationIDTerminal.owns(hit.node),
               // Oct 24: after the ID is issued, a tap toward the kiosk is an ordinary
               // tap walk (it used to land the player at the kiosk from anywhere).
               !Admission.isCompleted || controller.isInLandingPose(AdministrationIDTerminal.landingKind) {
                if controller.isInLandingPose(AdministrationIDTerminal.landingKind) {
                    AdministrationIDTerminal.current?.handleTap(on: hit)
                } else {
                    controller.beginLanding(kind: AdministrationIDTerminal.landingKind)
                }
                diag("tap.consumed", ["by": "id terminal"])
                return
            }
            // Oct 5 (Fred joins): once he has reported for duty, a tap on Fred pets
            // him -- the handshake that completes the prologue. Taps on him while
            // he is still performing are swallowed (no walking into the scene).
            if decorator?.enabled != true, FredOfficeEncounter.canPet || FredOfficeEncounter.isPerforming,
               let view = gesture.view as? SCNView,
               let hit = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                           options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                     .ignoreHiddenNodes: true])).first,
               FredOfficeEncounter.isFred(hit.node) {
                if FredOfficeEncounter.canPet { FredOfficeEncounter.pet() }
                diag("tap.consumed", ["by": "fred (pet)"])
                return
            }
            // Oct 6 (guided journey, PROTOTYPE): at the end of the trip, a tap on
            // the guide is the existing pet (completes the prologue; he joins).
            // While he is still leading, taps on him fall through (= go to him).
            if decorator?.enabled != true, GuidedJourney.canPet, let view = gesture.view as? SCNView,
               let hit = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                           options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                     .ignoreHiddenNodes: true])).first,
               GuidedJourney.isGuide(hit.node) {
                GuidedJourney.pet()
                diag("tap.consumed", ["by": "guide (pet)"])
                return
            }
            // Oct 5 (Fred encounter): a tap on Fred or his desk/chair -- while he is
            // waiting -- lands you in front of the desk (or starts it if already there).
            if decorator?.enabled != true, FredOfficeEncounter.isAvailable, let view = gesture.view as? SCNView,
               let hit = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                           options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                     .ignoreHiddenNodes: true])).first,
               FredOfficeEncounter.owns(hit.node) {
                if controller.isInLandingPose(FredOfficeEncounter.landingKind) {
                    FredOfficeEncounter.begin()
                } else if SmartTap.isOn, !AdministrationReception.officeCells.contains(controller.currentCell),
                          controller.smartTapWalkToTinky() {
                    // Oct 15 (Smart Tap): from reception, his route (through his door).
                    SmartTap.log("direct", ["target": "tinkyDesk", "via": "route", "moving": false])
                } else {
                    controller.beginLanding(kind: FredOfficeEncounter.landingKind)
                }
                diag("tap.consumed", ["by": "fred"])
                return
            }
            // Oct 21 (one tap, one walk): the Administration glass doors tapped from the
            // elevator side, before the ID -- out of the cab if need be, through the doors
            // as they open, all the way to Juanita's counter. (Used to be: the cab's step
            // out and nothing more, then the doors, then her -- three taps.)
            if decorator?.enabled != true, controller.currentFloorNumber == AdministrationReception.floor, !Admission.isCompleted,
               let view = gesture.view as? SCNView,
               Posse.navigationHits(view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                                        .ignoreHiddenNodes: true]))
                   .prefix(3).contains(where: { controller.roomEntranceDoorCoordinate(for: $0.node) == AdministrationReception.entranceDoorCell }),
               controller.startAdminWalk(.toJuanita) {
                SmartTap.log("direct", ["target": "juanita", "via": "glassDoors", "moving": false])
                diag("tap.consumed", ["by": "administration doors: the walk to Juanita"])
                return
            }
            if controller.canStartElevatorExit, let view = gesture.view as? SCNView {
                let hits = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                             options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true]))
                // Oct 7 (Annette, Build 10): the panel is live with the doors
                // open -- another floor closes them and departs.
                if controller.pressElevatorButton(hits: hits) {
                    diag("tap.consumed", ["by": "elevator panel (doors open)"])
                    return
                }
                if !controller.elevatorTapGoesThroughDoorway(hits: hits) {
                    diag("tap.consumed", ["by": "elevator cab interior (doors open)"])
                    return
                }
            }
            // Oct 15 (Smart Tap): while a character escorts the player, a tap ON
            // him (on him, or within a step of where he stands) = follow him --
            // the escort walk the WALK button used to start: his route, his
            // pace, never overtaking him. Any other tap is an ordinary one.
            if SmartTap.isOn, decorator?.enabled != true, let guide = CharacterLead.activeGuidePosition,
               let view = gesture.view as? SCNView,
               let hit = Posse.navigationHits(view.hitTest(gesture.location(in: view),
                                                           options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                     .ignoreHiddenNodes: true])).first,
               // on him (his body, within half a metre), or on the floor right at him --
               // never a door, panel or wall that happens to be beside him
               hypotf(hit.worldCoordinates.x - guide.x, hit.worldCoordinates.z - guide.y) < (hit.worldNormal.y > 0.7 ? SmartTap.guideReach : 0.5) {
                let following = controller.smartTapFollowGuide()
                SmartTap.log(following ? "contextual" : "contextualRefused", ["trigger": "tapOnGuide", "moving": false])
                if following {
                    diag("tap.consumed", ["by": "escort (follow)"])
                    return
                }
            }
            // Oct 2: the Play-mode picture early-return that used to sit
            // here is gone. It keyed on (current cell, facing) -- not on
            // what was tapped -- so in Free Walk a picture on the wall your
            // nearest-cardinal facing pointed at silently killed EVERY tap
            // on screen. Pictures stay inert in Play: nothing below acts on
            // a picture hit, and content editing lives in Decorate.
            if let coord = controller.photoBoothAtCurrentCell {
                controller.composeWallView(.photoBooth, at: coord) { controller.activatePhotoBooth(at: coord) }
                return
            }
            if let coord = controller.ticTacToeTerminalAtCurrentCell {
                controller.composeWallView(.ticTacToe, at: coord) { controller.activateTicTacToeTerminal(at: coord) }
                return
            }
            if let coord = controller.shellGameTerminalAtCurrentCell {
                controller.composeWallView(.shellGame, at: coord) { controller.activateShellGameTerminal(at: coord) }
                return
            }
            if let coord = controller.rockPaperScissorsTerminalAtCurrentCell {
                controller.composeWallView(.rockPaperScissors, at: coord) { controller.activateRockPaperScissorsTerminal(at: coord) }
                return
            }
            if let coord = controller.higherLowerTerminalAtCurrentCell {
                controller.composeWallView(.higherLower, at: coord) { controller.activateHigherLowerTerminal(at: coord) }
                return
            }
            if let coord = controller.fiveCardDrawTerminalAtCurrentCell {
                controller.composeWallView(.fiveCardDraw, at: coord) { controller.activateFiveCardDrawTerminal(at: coord) }
                return
            }
            if let coord = controller.simonTerminalAtCurrentCell {
                controller.composeWallView(.simon, at: coord) { controller.activateSimonTerminal(at: coord) }
                return
            }
            if let coord = controller.hangmanTerminalAtCurrentCell {
                controller.composeWallView(.hangman, at: coord) { controller.activateHangmanTerminal(at: coord) }
                return
            }
            if let coord = controller.connectFourTerminalAtCurrentCell {
                controller.composeWallView(.connectFour, at: coord) { controller.activateConnectFourTerminal(at: coord) }
                return
            }
            if let coord = controller.checkersTerminalAtCurrentCell {
                controller.composeWallView(.checkers, at: coord) { controller.activateCheckersTerminal(at: coord) }
                return
            }
            if let coord = controller.woidleTerminalAtCurrentCell {
                controller.composeWallView(.woidle, at: coord) { controller.activateWoidleTerminal(at: coord) }
                return
            }
            if let view = gesture.view as? SCNView {
                let location = gesture.location(in: view)
                // Oct 4: the same closest hit as before, looking past a following
                // posse member (Posse.navigationHits) -- e.g. Freddy standing in
                // front of the elevator doors.
                let hits = Array(Posse.navigationHits(view.hitTest(location, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])).prefix(1))
                // BUG 2 fix (manual-mode elevator Change Picture), Sept
                // 26: gated to the one state this is meant for -- the
                // player is mid-ride AND has already taken full camera
                // control (playerHasTakenElevatorCameraControl) -- so an
                // ordinary hallway tap (this same view, any other time)
                // is completely unaffected. Checked before every other
                // hit-test below so a tap landing on a poster can never
                // fall through to advance() the way it silently did
                // before this fix (there was no route into Change
                // Picture for the elevator at all -- see
                // TapNavigationController.activeElevatorPictureMenu).
                // Sept 26 (elevator control-panel tap-to-light, visual
                // only): checked first, ahead of the poster check just
                // below, so a tap on the new interior control panel
                // always takes precedence over ordinary wall-thump
                // handling -- exact same gating (mid-ride, manual
                // camera control already taken) as the poster check,
                // since that is the only state the panel is ever
                // visible/reachable in. Purely a local material swap:
                // no ride, floor, or navigation state is touched.
                if !TapNavigationController.interactiveElevator,   // Oct 4: superseded by the real panel (pressElevatorButton)
                   controller.isElevatorRideInProgress, controller.playerHasTakenElevatorCameraControl,
                   let hit = hits.compactMap({ controller.elevatorControlButtonHit(for: $0.node) }).first {
                    navLog("tap hit elevator control button floor=\(hit.floor)")
                    controller.setElevatorControlButtonLit(plate: hit.plate, floor: hit.floor)
                    return
                }
                // Oct 4: picture CONTENT is a Decorate-mode thing now -- no
                // change-photo menu from a Play-mode tap on an elevator poster.
                if Self.elevatorPosterMenuInPlay,
                   controller.isElevatorRideInProgress, controller.playerHasTakenElevatorCameraControl,
                   let target = hits.compactMap({ controller.elevatorPosterTarget(for: $0.node) }).first {
                    navLog("tap hit elevator poster (\(target)) in manual-control mode")
                    controller.activeElevatorPictureMenu = target
                    return
                }
                // Sept 28 (Floor Lamp): in Play, a tap whose NEAREST hit is
                // a floor lamp switches it on/off and consumes the tap (no
                // walking). Nearest-only, so a lamp can't be switched
                // through a wall. Decorate mode never reaches here for a
                // lamp -- DecoratorState.select above claims the tap first
                // -- and is excluded explicitly as well.
                if decorator?.enabled != true,
                   let nearest = hits.first,
                   let lampCoord = HallwayScene.floorLampCoordinate(for: nearest.node),
                   decorator?.toggleFloorLamp(at: lampCoord) == true {
                    navLog("tap toggled floor lamp at \(lampCoord)")
                    return
                }
                // Sept 28 (Aquarium): in Play, a tap whose NEAREST hit is an
                // aquarium is simply consumed -- no walk, no dialog, no
                // pickup. It's scenery to look at. (Decorate mode claims the
                // tap earlier via DecoratorState.select.)
                if decorator?.enabled != true,
                   let nearest = hits.first,
                   let aquariumCoord = HallwayScene.aquariumCoordinate(for: nearest.node) {
                    navLog("tap hit aquarium at \(aquariumCoord) -- consumed, no walk")
                    return
                }
                // Sept 28 (Filing Cabinet): in Play, a tap whose NEAREST hit
                // is a drawer (any part of it) opens/closes that drawer; a
                // tap on the carcass does nothing. Either way the tap is
                // consumed -- no walk, no pickup, no dialog. Resolved purely
                // by scene-graph ancestry, so any viewing angle works.
                // Decorate mode claims the tap earlier (DecoratorState.select
                // selects the whole cabinet) and is excluded here as well.
                if decorator?.enabled != true,
                   let nearest = hits.first,
                   let cabinetHit = HallwayScene.filingCabinetHit(for: nearest.node) {
                    if let drawer = cabinetHit.drawerIndex {
                        decorator?.tapFilingCabinetDrawer(drawer, at: cabinetHit.coord)
                        navLog("tap filing cabinet drawer \(drawer) at \(cabinetHit.coord)")
                    } else {
                        navLog("tap hit filing cabinet body at \(cabinetHit.coord) -- consumed, no walk")
                    }
                    return
                }
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
                // Oct 2 (WALL INTERACTIONS, Play only): a tap whose first real
                // surface belongs to ANY tappable wall object (picture, plaque,
                // map, door, chute, game, booth, extinguisher -- see
                // TapNavigationController.wallInteractionTarget) glides to that
                // object's pose and, on arrival, runs its existing action.
                // Falls through to the old per-object branches below whenever
                // composition declines (Decorate, grid, locked) or the object
                // has nothing available right now (open door, won game).
                if decorator?.enabled != true,
                   let exact = exactWallHit(at: location, in: view, controller: controller) {
                    diag("wallTarget.exactHit", ["kind": exact.target.kind, "coord": exact.target.face.coord,
                                                 "direction": exact.target.face.direction, "node": exact.hitNodeName,
                                                 "tap": Self.pointText(location)])
                    if controller.composeWallInteraction(exact.target) {
                        navLog("tap on \(exact.target.kind) at \(exact.target.face.coord) -- composing interaction pose")
                        return
                    }
                }
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
                if let roomEntranceDoorCoord = hits.compactMap({ controller.roomEntranceDoorCoordinate(for: $0.node) }).first,
                   controller.isAdjacentToRoomEntranceDoor(roomEntranceDoorCoord) {
                    navLog("tap hit room entrance door at \(roomEntranceDoorCoord)")
                    controller.openRoomEntranceDoor(at: roomEntranceDoorCoord)
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
                    controller.composeWallView(.photoBooth, at: coord) { controller.activatePhotoBooth(at: coord) }
                    return
                }
                if let coord = hits.compactMap({ controller.ticTacToeTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.composeWallView(.ticTacToe, at: coord) { controller.activateTicTacToeTerminal(at: coord) }
                    return
                }
                if let coord = hits.compactMap({ controller.shellGameTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.composeWallView(.shellGame, at: coord) { controller.activateShellGameTerminal(at: coord) }
                    return
                }
                if let coord = hits.compactMap({ controller.rockPaperScissorsTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.composeWallView(.rockPaperScissors, at: coord) { controller.activateRockPaperScissorsTerminal(at: coord) }
                    return
                }
                if let coord = hits.compactMap({ controller.higherLowerTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.composeWallView(.higherLower, at: coord) { controller.activateHigherLowerTerminal(at: coord) }
                    return
                }
                if let coord = hits.compactMap({ controller.fiveCardDrawTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.composeWallView(.fiveCardDraw, at: coord) { controller.activateFiveCardDrawTerminal(at: coord) }
                    return
                }
                if let coord = hits.compactMap({ controller.simonTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.composeWallView(.simon, at: coord) { controller.activateSimonTerminal(at: coord) }
                    return
                }
                if let coord = hits.compactMap({ controller.hangmanTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.composeWallView(.hangman, at: coord) { controller.activateHangmanTerminal(at: coord) }
                    return
                }
                if let coord = hits.compactMap({ controller.connectFourTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.composeWallView(.connectFour, at: coord) { controller.activateConnectFourTerminal(at: coord) }
                    return
                }
                if let coord = hits.compactMap({ controller.checkersTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.composeWallView(.checkers, at: coord) { controller.activateCheckersTerminal(at: coord) }
                    return
                }
                if let coord = hits.compactMap({ controller.woidleTerminalCoordinate(for: $0.node) }).first,
                   coord == controller.currentCell {
                    controller.composeWallView(.woidle, at: coord) { controller.activateWoidleTerminal(at: coord) }
                    return
                }
                if hits.contains(where: { controller.isElevatorMissionSign($0.node) }), controller.elevatorAtCurrentCell {
                    controller.openElevator()
                    return
                }
                // Oct 22 (hall call): the doors frame the call panel (no call, no
                // sound); the panel's UP / DOWN make the call and light up. An
                // arrived cab and a resident's open doors: in, as before.
                // (Oct 7: the doors and the panel were one shared request.)
                if hits.contains(where: { controller.isElevatorDoor($0.node) || controller.isElevatorCallPanel($0.node) }),
                   controller.elevatorAtCurrentCell {
                    let button = controller.hallCallButton(for: hits)
                    navLog("tap hit elevator door / call panel (button \(button.map { "\($0)" } ?? "none"))")
                    diag("tap.elevatorExterior", ["callPanel": button != nil, "button": button])
                    controller.tapElevatorExterior(button: button)
                    return
                }
                // Oct 20 (sharing the car): its doors stand open here for a resident --
                // slid aside, they aren't under the finger: a tap in through the open
                // doorway is the same request as a tap on them (openElevator, every gate).
                if decorator?.enabled != true, controller.mayBoardThroughCarDoors {
                    let near = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 0))
                    let far = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 1))
                    if controller.boardThroughOpenCarDoorsByTap(direction: TapNavigationController.horizontalDirection(near: near, far: far)) {
                        diag("tap.consumed", ["by": "elevator (through a resident's open doors)"])
                        return
                    }
                }
                // Oct 15 (direct interactions -- no OPEN button): the elevator's
                // doors or call panel tapped from down the hall: go to it, and open.
                if SmartTap.isOn, decorator?.enabled != true, !controller.elevatorAtCurrentCell,
                   hits.contains(where: { controller.isElevatorDoor($0.node) || controller.isElevatorCallPanel($0.node) }),
                   controller.approachElevatorAndOpen(button: controller.hallCallButton(for: hits)) {
                    SmartTap.log("direct", ["target": "elevator", "via": "approach", "moving": false])
                    return
                }
                if hits.contains(where: { controller.isEntranceDoor($0.node) }), controller.entranceDoorAtCurrentCell {
                    navLog("tap hit floor 1 entrance doors (inside) -- returning to opening screen")
                    navBridge?.requestReturnToOpening = true
                    return
                }
                if hits.contains(where: { controller.isFloorMapNode($0.node) }), controller.floorMapAtCurrentCell {
                    // Wall maps never pop up. (Oct 2: a nearby tap ON the map is
                    // composed into a viewing pose above; this keeps the old
                    // read-in-place no-op whenever that declines.)
                    return
                }
            }
            // TAP WHERE YOU WANT TO GO (Sept 30): a navigation tap walks one
            // cell toward the horizontal bearing of the tapped screen point
            // (same unprojection as pinch). Every interaction above still
            // consumes its tap first; nil falls back to camera forward.
            // TAP A PLACE -> GO THERE (Sept 30): the closest visible geometry
            // under the finger gives the destination; its horizontal X/Z
            // distance from the player is how far to walk. No hit -> the
            // ray bearing alone and the old one-cell tap.
            var direction: (x: Double, z: Double)?
            var distance: Double?
            if let view = gesture.view as? SCNView {
                let point = gesture.location(in: view)
                let near = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
                let far = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
                direction = TapNavigationController.horizontalDirection(near: near, far: far)
                // Oct 1 (tap-to-approach, hit-test fix): look for a tap-to-collect
                // floor object (trash can, paint bucket) along the WHOLE ray,
                // nearest first, skipping only the invisible Decorate-selection
                // floor plate each one carries (decoratorHitProxy, raised to
                // mid-can height and cellSize*0.9 wide, so it sat in front of
                // the lower part of the can and swallowed those taps) and the
                // hanging-pickup cord. The first REAL surface decides: the can
                // itself -> approach; anything else (floor, wall) -> ordinary.
                if decorator?.enabled != true {
                    let allHits = Posse.navigationHits(view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true]))
                    if let firstReal = allHits.first(where: { $0.node.name != "decoratorHitProxy" && $0.node.name != "hangingPickupString" }),
                       let fireCoord = controller.fireCoordinate(for: firstReal.node),
                       let approach = controller.tapApproach(toFireAt: fireCoord) {
                        controller.advance(travelDirection: approach.direction, travelDistance: approach.distance, finalYaw: approach.finalYaw)
                        return
                    }
                    if let firstReal = allHits.first(where: { $0.node.name != "decoratorHitProxy" && $0.node.name != "hangingPickupString" }),
                       let objectCoord = controller.objectCoordinate(for: firstReal.node),
                       let approach = controller.tapApproach(toObjectAt: objectCoord) {
                        navLog("tap on floor object at \(objectCoord): approach \(String(format: "%.2f", approach.distance)) m along the tap line")
                        controller.advance(travelDirection: approach.direction, travelDistance: approach.distance, finalYaw: approach.finalYaw)
                        return
                    }
                }
                // Oct 2 (forgiving wall-object targeting): every exact handler
                // above has declined, so this tap is about to become an
                // ordinary walk. If it landed within a finger's width of a
                // VISIBLE tappable wall object on screen, treat it as a tap on
                // that object instead.
                if decorator?.enabled != true,
                   let assisted = assistedWallHit(at: point, in: view, controller: controller),
                   controller.composeWallInteraction(assisted) {
                    navLog("assisted tap on \(assisted.kind) at \(assisted.face.coord) -- composing interaction pose")
                    return
                }
                // Oct 15 (Smart Tap): the ID still to do, a tap that lands on the
                // floor or wall right round the kiosk (within kioskReach of where
                // one stands to use it) is a tap on the kiosk: the same landing.
                if SmartTap.isOn, decorator?.enabled != true, controller.currentFloorNumber == AdministrationReception.floor,
                   !Admission.isCompleted, AdministrationIDTerminal.current != nil,
                   !controller.isInLandingPose(AdministrationIDTerminal.landingKind),
                   let stand = controller.landingSpotPosition(AdministrationIDTerminal.landingKind),
                   let hit = Posse.navigationHits(view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                                .ignoreHiddenNodes: true])).first,
                   hypotf(hit.worldCoordinates.x - stand.x, hit.worldCoordinates.z - stand.z) < SmartTap.kioskReach,
                   // (only approaching from outside that area -- never a step away from the kiosk)
                   hypotf(controller.cameraNode.position.x - stand.x, controller.cameraNode.position.z - stand.z) > SmartTap.kioskReach,
                   controller.beginLanding(kind: AdministrationIDTerminal.landingKind) {
                    SmartTap.log("direct", ["target": "idKiosk", "via": "nearKiosk", "moving": false])
                    return
                }
                if let hit = Posse.navigationHits(view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                                .ignoreHiddenNodes: true])).first {
                    let eye = controller.cameraNode.worldPosition, spot = hit.worldCoordinates
                    let dx = Double(spot.x - eye.x), dz = Double(spot.z - eye.z)
                    let d = (dx * dx + dz * dz).squareRoot()
                    distance = d
                    if d > 1e-6 { direction = (dx / d, dz / d) }
                }
            }
            // Oct 16 (WALK LATCH): a tap on nothing in particular starts the
            // ordinary held walk, latched -- it keeps going with no finger down.
            // Where it can't start (Decorate, the cab, a glide finishing...): as before.
            // Oct 20 (night, "leaving Tinky's office, a tap sends me across the room"):
            // the latch walks the way the VIEW faces -- it never knew where the tap
            // was. A tap well off to the side (the office doors, beside the view)
            // started a walk straight ahead that slid along the walls until it met
            // one head on. Only a tap roughly ahead latches now; one off to the side
            // is the tap-a-place walk below: turn toward the tapped spot, go there.
            // Oct 21: and never when a capped pose (Juanita's counter) lies along the tap: the
            // tap-a-place walk below stops ON it -- the latch ran on to the counter's wall
            // clearance and the landing then glided the player back (the "too close, then back").
            if decorator?.enabled != true, controller.tapAimsAhead(direction),
               !controller.cappedLandingAhead(direction: direction, distance: distance), controller.startWalkLatch() {
                SmartTap.log("walk", ["target": "latch", "moving": false])
                return
            }
            navLog("tap, travel direction=\(String(describing: direction)) distance=\(String(describing: distance))")
            SmartTap.log("direct", ["target": "point", "distance": distance.map { (($0 * 10).rounded() / 10) }, "moving": false])   // Oct 15
            controller.advance(travelDirection: direction, travelDistance: distance)
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
            if gesture.state == .began { pinchBlockedByEviction = navigationController?.evictionLocked == true }  // Oct 16
            if pinchBlockedByEviction || (navigationController?.evictionLocked == true && gesture.state == .changed) { return }
            // Oct 11: seated at the conference table a pinch is the lens
            // (the window-level pinch, CameraMagnifierGestures) -- never a walk.
            if ConferenceMeeting.isActive { return }
            if OfficeComputer.shared.isActive {
                // Oct 7: seated at the office computer -- a pinch never walks.
                // Oct 11: a pinch on the room around the monitor looks closer
                // (CameraMagnifier, same as a pinch on the monitor itself).
                guard CameraMagnifier.applies, let view = gesture.view else { return }
                let computer = OfficeComputer.shared
                switch gesture.state {
                case .began: computer.pinchBegan(windowPoint: view.convert(gesture.location(in: view), to: nil), source: "room")
                case .changed: computer.pinchChanged(scale: Double(gesture.scale), source: "room")
                case .ended, .cancelled, .failed: computer.pinchEnded(scale: Double(gesture.scale), source: "room")
                default: break
                }
                return
            }
            diagGesture("pinch", gesture)
            guard let controller = navigationController else { return }
            if gesture.state == .began { controller.stopContinuousWalk(reason: "pinch") }   // Oct 10: gestures take over
            let fraction = (Double(gesture.scale) - 1.0) / pinchScalePerCell
            let velocityFraction = Double(gesture.velocity) / pinchScalePerCell
            switch gesture.state {
            case .began:
                // No object has its own pinch: a pinch over a picture OR a
                // mission plaque (plaque scaling removed Oct 2) is ordinary
                // spatial navigation, exactly like a pinch over the wall
                // beside it -- walk closer to see it better.
                // Pass #5: walk toward WHERE the pinch is -- the horizontal
                // heading of the view ray under the pinch centroid at
                // .began (held for the whole gesture so finger wobble can't
                // steer it). Only the Free Walk scrub reads it; legacy
                // ignores it. Scale still means how far / which way.
                var direction: (x: Double, z: Double)?
                if let view = gesture.view as? SCNView {
                    let point = gesture.location(in: view)
                    let near = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
                    let far = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
                    direction = TapNavigationController.horizontalDirection(near: near, far: far)
                }
                navLog("pinch began, travel direction=\(String(describing: direction))")
                controller.beginDragMove(travelDirection: direction)
            case .changed:
                controller.updateDragMove(fraction: fraction)
            case .ended, .cancelled, .failed:
                navLog("pinch ended, fraction=\(String(format: "%.2f", fraction)), velocityFraction=\(String(format: "%.2f", velocityFraction))")
                controller.endDragMove(fraction: fraction, velocityFraction: velocityFraction)
            default:
                break
            }
        }

        /// Oct 3 TIN CAN RAT prototype 1: first-person <-> companion + rat.
        @objc func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
            guard BuildMode.developerTools else { return }
            if OfficeComputer.shared.isActive { return }   // Oct 7: seated at the office computer -- only taps (get up) reach the world
            guard let view = gesture.view as? SCNView else { return }
            TinCanRat.toggle(in: view)
        }

        @objc func handleTwoFingerTap() {
            if navigationController?.evictionLocked == true { return }   // Oct 16
            if OfficeComputer.shared.isActive { return }   // Oct 7: seated at the office computer -- only taps (get up) reach the world
            navLog("two-finger tap (turn around)")
            diag("gesture.twoFingerTap", ["cell": navigationController?.currentCell, "facing": navigationController?.facing])
            guard let controller = navigationController else { return }
            controller.stopContinuousWalk(reason: "turnAround")   // Oct 10
            controller.rotate(toward: controller.facing.opposite)
        }

        @objc func handlePanRotate(_ gesture: UIPanGestureRecognizer) {
            // Oct 16 (Bonzo's eviction): no new drag while he has the player (one already
            // under way when he grabbed still gets its ending, so nothing is left half-done).
            if gesture.state == .began { MudProbe.shared.handled("swipe", mayWalk: false) }   // Oct 24 (mud probe): measurement only
            if gesture.state == .began { panBlockedByEviction = navigationController?.evictionLocked == true }
            if panBlockedByEviction || (navigationController?.evictionLocked == true && gesture.state == .changed) { return }
            if OfficeComputer.shared.isActive {
                // Oct 7: seated at the office computer -- a drag never turns or walks.
                // Oct 11: while zoomed in, one finger dragging the room around
                // the monitor pans the magnified view (CameraMagnifier).
                // Oct 12 (seated look): not zoomed, a drag turns the head instead.
                guard let view = gesture.view else { return }
                let computer = OfficeComputer.shared
                if gesture.state == .began { seatedLookPan = !CameraMagnifier.shared.isZoomed }
                if seatedLookPan {
                    switch gesture.state {
                    case .began: computer.lookBegan()
                    case .changed: computer.lookChanged(translation: gesture.translation(in: view))
                    case .ended, .cancelled, .failed: computer.lookEnded()
                    default: break
                    }
                    return
                }
                switch gesture.state {
                case .began: computer.roomPanBegan()
                case .changed: computer.roomPanChanged(translation: gesture.translation(in: view))
                case .ended, .cancelled, .failed: computer.roomPanEnded()
                default: break
                }
                return
            }
            // Oct 11 (the staff meeting): seated at the conference table, a drag
            // only turns the head (within limits) -- never a walk or a turn of
            // the body. During the sit/stand glides it does nothing.
            if ConferenceMeeting.isActive {
                guard let view = gesture.view else { return }
                switch gesture.state {
                case .began: ConferenceMeeting.lookBegan()
                case .changed: ConferenceMeeting.lookChanged(translation: gesture.translation(in: view))
                case .ended, .cancelled, .failed: ConferenceMeeting.lookEnded()   // Oct 11: or the zoomed lens's pan
                default: break
                }
                return
            }
            diagGesture("pan", gesture)
            guard let controller = navigationController, let view = gesture.view else { return }
            // Oct 16 (Supplies): SWIPE A TOOL UP to send it back. Only a drag that
            // BEGINS on a carried tool (or the held wall extinguisher) AND sets off
            // upward is claimed -- a sideways drag from the same spot still turns,
            // and every other drag turns and walks exactly as before.
            if gesture.state == .began { toolSwipe = nil; memberSwipe = nil }   // (never a stale claim from a drag whose end went elsewhere)
            let setsOffUp: Bool = {
                let t = gesture.translation(in: view)
                if t.x == 0 && t.y == 0 { let v = gesture.velocity(in: view); return v.y < 0 && -v.y > abs(v.x) * 0.8 }
                return t.y < 0 && -t.y > abs(t.x) * 0.8
            }()
            if gesture.state == .began, setsOffUp, let scn = view as? SCNView, !controller.isElevatorRideInProgress {
                let start = CGPoint(x: gesture.location(in: view).x - gesture.translation(in: view).x,
                                    y: gesture.location(in: view).y - gesture.translation(in: view).y)
                if let tool = ToolBelt.tool(at: start, in: scn) {
                    toolSwipe = (tool, start)
                } else if controller.carryingExtinguisher, let rect = controller.heldExtinguisherScreenRect(in: scn), rect.contains(start) {
                    toolSwipe = (nil, start)
                }
                if let claimed = toolSwipe {
                    diag("supplies.swipeBegan", ["tool": claimed.tool?.rawValue ?? "wallExtinguisher"])
                    return
                }
                if let member = Posse.followingMember(at: start, in: scn) {
                    memberSwipe = member
                    diag("posse.swipeBegan", ["member": member.memberID])
                    return
                }
            }
            if let member = memberSwipe {
                switch gesture.state {
                case .ended:
                    memberSwipe = nil
                    let t = gesture.translation(in: view), v = gesture.velocity(in: view)
                    if (t.y < -Self.toolSwipeMinimumRise || v.y < -500) && abs(t.y) > abs(t.x) { Posse.dismiss(member) }
                case .cancelled, .failed:
                    memberSwipe = nil
                default: break
                }
                return
            }
            if let claimed = toolSwipe {
                switch gesture.state {
                case .ended:
                    toolSwipe = nil
                    let t = gesture.translation(in: view), v = gesture.velocity(in: view)
                    let upward = (t.y < -Self.toolSwipeMinimumRise || v.y < -500) && abs(t.y) > abs(t.x)
                    guard upward else { diag("supplies.swipeNotUp", ["dx": Double(t.x), "dy": Double(t.y)]); return }
                    if let tool = claimed.tool {
                        if !Supplies.release(tool, controller: controller) { diag("supplies.swipeDeclined", ["tool": tool.rawValue]) }
                    } else if !controller.putAwayExtinguisher() {
                        diag("extinguisher.swipeDeclined", [:])
                    }
                case .cancelled, .failed:
                    toolSwipe = nil
                default: break
                }
                return                                                    // never a turn or a walk
            }
            if gesture.state == .began { controller.stopContinuousWalk(reason: "pan") }   // Oct 10: gestures take over
            let tracePan = ElevatorArrivalTrace.shared.samplePan(changed: gesture.state == .changed)
            let before = controller.cameraNode.eulerAngles
            if tracePan { ElevatorArrivalTrace.shared.event("pan.callback", "state=\(gesture.state.rawValue) controller=\(ObjectIdentifier(controller))") }
            defer {
                if tracePan {
                    let after = controller.cameraNode.eulerAngles
                    ElevatorArrivalTrace.shared.event("pan.result", "state=\(gesture.state.rawValue) controller=\(ObjectIdentifier(controller)) elevator=\(controller.isElevatorRideInProgress) acceptedDrag=\(controller.diagnosticElevatorDragAccepted) yaw=\(before.y)->\(after.y) pitch=\(before.x)->\(after.x) snapshotGateVisible=\(navBridge?.arrivalWasControlled == true && navBridge?.controlledArrivalFrameReady == false && navBridge?.doorSnapshot != nil)")
                }
            }
            // Oct 2 (auto-walk -> hold handoff): a drag that starts while a
            // tap-to-point walk is running is the hold taking control -- routed
            // whole (began/changed/ended) into the shared hold, never free look.
            if gesture.state == .began, panBeganShouldTakeOverAutoWalk() {
                beginHold(at: gesture.location(in: view)) { [weak gesture] in gesture?.location(in: gesture?.view) }
                return
            }
            if panIsHoldTakeover {
                switch gesture.state {
                case .changed: updateHold(at: gesture.location(in: view))
                case .ended, .cancelled, .failed:
                    let latched = controller.isWalkLatched
                    panEndedHoldTakeover(at: gesture.location(in: view))
                    // Oct 16 (WALK LATCH): a fast horizontal swipe keeps the standing
                    // swipe's quarter-turn snap (same 30-degree / prompt-release rule).
                    let t = gesture.translation(in: view), v = gesture.velocity(in: view)
                    if latched, gesture.state == .ended, abs(t.x) > abs(t.y) * 1.2,
                       Double(abs(t.x) / dragRotateDistance) * 90 >= 30, abs(v.x) >= Self.latchFlickSpeed {
                        controller.latchFlickTurn(left: t.x > 0)
                    }
                default: break
                }
                return
            }
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
                // Oct 19 (elevator swipe): in the open cab, a VERTICAL pan is a
                // swipe through the doors (down = forward, up = backward) when
                // the way the player looks allows one; otherwise, and always
                // sideways, it's the cab look as before.
                switch gesture.state {
                case .began:
                    elevatorPanAxis = nil
                    navLog("pan rotate began (elevator camera)")
                    controller.beginElevatorCameraDrag()
                case .changed:
                    if elevatorPanAxis == nil, max(abs(translation.x), abs(translation.y)) >= dragAxisLockDistance {
                        if abs(translation.y) > abs(translation.x),
                           controller.elevatorThresholdCrossing(forward: translation.y > 0) != nil {
                            controller.releasePanForElevatorThreshold()
                            if claimThresholdSwipe(controller, translation: translation) {
                                elevatorPanAxis = .vertical
                                navLog("pan in the cab committed to a threshold swipe")
                            } else {
                                elevatorPanAxis = .horizontal
                                controller.beginElevatorCameraDrag()
                            }
                        } else {
                            elevatorPanAxis = .horizontal
                        }
                    }
                    if elevatorPanAxis == .vertical {
                        controller.updateThresholdScrub(cells: thresholdSwipeCells(translation))
                    } else {
                        controller.updateElevatorCameraDrag(fraction: fraction)
                    }
                case .ended, .cancelled, .failed:
                    if elevatorPanAxis == .vertical {
                        if gesture.state == .ended { finishThresholdSwipe(controller, translation: translation, velocity: velocity) }
                        else { controller.endThresholdScrub(commit: false) }
                    } else {
                        navLog("pan rotate ended (elevator camera)")
                        controller.endElevatorCameraDrag()
                    }
                    elevatorPanAxis = nil
                default:
                    break
                }
                return
            }
            // Oct 19 (elevator swipe): just outside a cab whose doors are open
            // (or closing behind the player), a pan waits until it has a
            // direction: a vertical one toward the cab is a swipe back through
            // the doors; anything else starts the ordinary pan right then.
            if gesture.state == .began {
                thresholdPanClaimed = false
                thresholdPanPending = controller.elevatorThresholdNearby
                if thresholdPanPending { return }
            }
            if thresholdPanClaimed {
                switch gesture.state {
                case .changed: controller.updateThresholdScrub(cells: thresholdSwipeCells(translation))
                case .ended: finishThresholdSwipe(controller, translation: translation, velocity: velocity); thresholdPanClaimed = false
                case .cancelled, .failed: controller.endThresholdScrub(commit: false); thresholdPanClaimed = false
                default: break
                }
                return
            }
            if thresholdPanPending {
                guard gesture.state == .changed else { thresholdPanPending = false; return }    // (a touch that never moved)
                guard max(abs(translation.x), abs(translation.y)) >= dragAxisLockDistance else { return }
                thresholdPanPending = false
                if abs(translation.y) > abs(translation.x), claimThresholdSwipe(controller, translation: translation) {
                    thresholdPanClaimed = true
                    navLog("pan at the open cab committed to a threshold swipe")
                    return
                }
                // Not a crossing: the ordinary pan, from here (the code below sees .changed).
                if !controller.beginFreePan() {
                    lockedPanAxis = nil
                    controller.beginDragRotate()
                }
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
            // FREE-WALK (polish pass #3): no axis winner. X = turn and
            // Y = move for the whole touch -- see beginFreePan() in
            // TapNavigationController.swift. Falls through to the legacy
            // axis-locked drag below when Free Walk doesn't apply.
            if gesture.state == .began, controller.beginFreePan() {
                navLog("pan began (free 2-D)")
                controller.updateFreePan(dx: Double(translation.x), dy: Double(translation.y),
                                         pointsPerQuarterTurn: Double(dragRotateDistance), pointsPerCell: Double(dragMoveDistance))
                return
            }
            if gesture.state != .began, controller.isFreePanning {
                switch gesture.state {
                case .changed:
                    controller.updateFreePan(dx: Double(translation.x), dy: Double(translation.y),
                                             pointsPerQuarterTurn: Double(dragRotateDistance), pointsPerCell: Double(dragMoveDistance))
                case .ended, .cancelled, .failed:
                    navLog("pan ended (free 2-D)")
                    controller.updateFreePan(dx: Double(translation.x), dy: Double(translation.y),
                                             pointsPerQuarterTurn: Double(dragRotateDistance), pointsPerCell: Double(dragMoveDistance))
                    controller.endFreePan(dx: Double(translation.x), pointsPerQuarterTurn: Double(dragRotateDistance))
                default:
                    break
                }
                return
            }
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
            if navigationController?.evictionLocked == true { return }   // Oct 16
            if OfficeComputer.shared.isActive { return }   // Oct 7: seated at the office computer -- only taps (get up) reach the world
            navLog("swipe down (turn around)")
            diag("gesture.swipeDown", ["cell": navigationController?.currentCell, "facing": navigationController?.facing])
            guard let controller = navigationController else { return }
            controller.stopContinuousWalk(reason: "turnAround")   // Oct 10
            controller.rotate(toward: controller.facing.opposite)
        }

        // Poll only while held. The controller advances straight or pivots
        // around an unambiguous L; a blocked T still waits for a choice.
        // Release stops polling, including during a corner's pivot.
        /// Oct 14: this press began on the held extinguisher (hold to put it away).
        private var extinguisherPress: (start: CGPoint, token: Int)?
        private var extinguisherPressToken = 0
        private var extinguisherPressClaimed = false            // this whole gesture belongs to the extinguisher
        static let extinguisherPutAwayHold: Double = 0.5        // seconds from touch-down
        static let extinguisherPressSlop: CGFloat = 14          // points the finger may drift
        // Oct 16 (Supplies): a drag that BEGAN on a carried tool (or on the held
        // wall extinguisher) belongs to it: released going up, it is sent back.
        private var toolSwipe: (tool: SupplyTool?, start: CGPoint)?
        /// Oct 16 (III): a drag that began on a FOLLOWING posse member (Freddy).
        private var memberSwipe: PosseMember?
        static let toolSwipeMinimumRise: CGFloat = 40

        @objc func handleLongPressForward(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { MudProbe.shared.handled("hold", mayWalk: true) }   // Oct 24 (mud probe): measurement only
            if gesture.state == .began { holdBlockedByEviction = navigationController?.evictionLocked == true }   // Oct 16
            if holdBlockedByEviction || (navigationController?.evictionLocked == true && gesture.state == .changed) { return }
            if OfficeComputer.shared.isActive { return }   // Oct 7: seated at the office computer -- only taps (get up) reach the world
            // Oct 14: a press-and-hold that BEGINS on the held fire extinguisher
            // is for it: still held ~0.5 s after touch-down (this recognizer
            // fires at 0.35 s), it goes back to its bracket. Never a held walk.
            // A tap, or a long-press anywhere else, is untouched.
            if gesture.state == .began, let controller = navigationController, !ConferenceMeeting.isActive,
               let view = gesture.view as? SCNView, let tool = ToolBelt.tool(at: gesture.location(in: view), in: view) {
                extinguisherPressToken += 1
                let token = extinguisherPressToken
                extinguisherPress = (gesture.location(in: view), token)
                extinguisherPressClaimed = true
                diag("supplies.pressBegan", ["tool": tool.rawValue])
                let wait = max(0, Self.extinguisherPutAwayHold - gesture.minimumPressDuration)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak controller] in
                    guard let self, let controller, self.extinguisherPress?.token == token else { return }
                    self.extinguisherPress = nil
                    if !Supplies.release(tool, controller: controller) { diag("supplies.pressDeclined", ["tool": tool.rawValue]) }
                }
                return
            }
            if gesture.state == .began, let controller = navigationController, controller.carryingExtinguisher,
               !ConferenceMeeting.isActive, !controller.isElevatorRideInProgress, let view = gesture.view as? SCNView,
               let rect = controller.heldExtinguisherScreenRect(in: view), rect.contains(gesture.location(in: view)) {
                extinguisherPressToken += 1
                let token = extinguisherPressToken
                extinguisherPress = (gesture.location(in: view), token)
                extinguisherPressClaimed = true
                diag("extinguisher.pressBegan", [:])
                let wait = max(0, Self.extinguisherPutAwayHold - gesture.minimumPressDuration)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak controller] in
                    guard let self, let controller, self.extinguisherPress?.token == token else { return }
                    self.extinguisherPress = nil
                    if !controller.putAwayExtinguisher() { diag("extinguisher.pressDeclined", [:]) }
                }
                return
            }
            // Oct 16 (III): press and hold a FOLLOWING posse member (Freddy) -- he stays here.
            if gesture.state == .began, navigationController?.evictionLocked != true, !ConferenceMeeting.isActive,
               navigationController?.isElevatorRideInProgress != true,
               let view = gesture.view as? SCNView, let member = Posse.followingMember(at: gesture.location(in: view), in: view) {
                extinguisherPressToken += 1
                let token = extinguisherPressToken
                extinguisherPress = (gesture.location(in: view), token)
                extinguisherPressClaimed = true
                diag("posse.pressBegan", ["member": member.memberID])
                let wait = max(0, Self.extinguisherPutAwayHold - gesture.minimumPressDuration)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self, self.extinguisherPress?.token == token else { return }
                    self.extinguisherPress = nil
                    Posse.dismiss(member)
                }
                return
            }
            if extinguisherPressClaimed {
                switch gesture.state {
                case .changed:
                    let p = gesture.location(in: gesture.view)
                    if let press = extinguisherPress, hypot(p.x - press.start.x, p.y - press.start.y) > Self.extinguisherPressSlop {
                        extinguisherPress = nil                           // moved off: not a hold
                        diag("extinguisher.pressMoved", [:])
                    }
                case .ended, .cancelled, .failed:
                    extinguisherPress = nil                               // (let go too soon: nothing)
                    extinguisherPressClaimed = false
                default: break
                }
                return                                                    // never a held walk
            }
            diagGesture("hold", gesture)
            switch gesture.state {
            case .began:
                navLog("long-press forward began")
                navigationController?.stopContinuousWalk(reason: "hold")   // Oct 10: gestures take over
                beginHold(at: gesture.location(in: gesture.view)) { [weak gesture] in gesture?.location(in: gesture?.view) }
            case .changed:
                updateHold(at: gesture.location(in: gesture.view))
            case .ended, .cancelled, .failed:
                navLog("long-press forward ended")
                endHold(at: gesture.location(in: gesture.view))
            default:
                break
            }
        }

        // MARK: Shared hold (Oct 2, auto-walk -> hold handoff)
        //
        // The ONE held-walk input path. Two recognizers feed it:
        //  - the long-press (finger down and still for 0.35 s), always;
        //  - the one-finger pan, but ONLY when it begins during a running
        //    tap-to-point walk (finger down and dragging) -- see handlePanRotate.
        // Either way the controller sees exactly what a long-press has always
        // sent: setWalkingHeld(true) + held ticks, then x/y updates for
        // steering, then setWalkingHeld(false) on release. The first tick
        // (advanceWhileHeld) is what converts a running tap walk into the
        // ordinary held walk (takeOverFreeTapWalkForHold).

        /// Finger down: start (or take over into) the held walk. `currentLocation`
        /// is polled by the repeating tick for the finger's live position.
        func beginHold(at location: CGPoint, currentLocation: @escaping @MainActor () -> CGPoint?) {
            // A hold begun behind closed doors must never become a later exit.
            if let controller = navigationController,
               controller.isElevatorRideInProgress && !controller.canStartElevatorExit { return }
            navigationController?.setWalkingHeld(true)
            forwardHoldTimer?.invalidate()
            forwardHoldTimer = nil
            if heldWalkTick(at: location) { return } // already at an endpoint: look only
            let timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                guard let self, let point = currentLocation() else { return }
                self.heldWalkTick(at: point)
            }
            RunLoop.main.add(timer, forMode: .common)
            forwardHoldTimer = timer
        }

        /// Finger moved while held: the existing held steering, nothing new.
        func updateHold(at location: CGPoint) {
            let fingerX = Double(location.x)
            // Legacy: only does anything once the held walk has reached
            // its endpoint (the controller ignores it otherwise).
            navigationController?.updateHeldEndpointLook(fingerX: fingerX)
            // Free walk: the same held finger drives BOTH axes at once --
            // X turns, Y is the forward/stop/backward throttle (no-op otherwise).
            navigationController?.updateHeldNavigation(fingerX: fingerX, fingerY: Double(location.y), pointsPerQuarterTurn: Double(heldWalkSteerDistance))
        }

        /// Finger up: stop right there (the old tap destination is long gone).
        func endHold(at location: CGPoint) {
            navigationController?.endHeldEndpointLook(fingerX: Double(location.x))
            navigationController?.setWalkingHeld(false)
            forwardHoldTimer?.invalidate()
            forwardHoldTimer = nil
        }

        /// True while the current one-finger pan is acting as the hold that
        /// took over a tap-to-point walk (decided once, at the pan's .began).
        private(set) var panIsHoldTakeover = false
        /// Oct 16 (Bonzo's eviction): this gesture began while he had the player -- ignored whole.
        private var panBlockedByEviction = false
        private var holdBlockedByEviction = false
        private var pinchBlockedByEviction = false
        /// ...and how fast (pt/s) a swipe must still be moving when it lifts to snap a quarter turn.
        static let latchFlickSpeed: CGFloat = 250
        /// Oct 6: our own continuous touch recognizers (look/drag and hold),
        /// read LIVE at an elevator arrival: is a finger mid-gesture now?
        weak var lookPanRecognizer: UIPanGestureRecognizer?
        weak var holdRecognizer: UILongPressGestureRecognizer?
        func activeTouchGestureDescription() -> String? {
            let candidates: [(String, UIGestureRecognizer?)] = [("pan", lookPanRecognizer), ("hold", holdRecognizer)]
            for (name, recognizer) in candidates {
                guard let recognizer, recognizer.isEnabled else { continue }
                if recognizer.state == .began || recognizer.state == .changed {
                    return "\(name):\(recognizer.state == .began ? "began" : "changed")"
                }
            }
            return nil
        }

        /// Pan .began: during a running tap walk the drag IS the hold (case C:
        /// finger down + immediate drag). Everywhere else returns false and
        /// the pan is the ordinary free look / drag turn, unchanged.
        // MARK: Oct 2 -- forgiving wall-object targeting (every tappable wall
        // object: see TapNavigationController.wallInteractionTarget)
        //
        // Before: the Play tap took SceneKit's single closest hit and walked
        // up from it. A small/distant frame is only a few points wide, so a
        // tap just beside it hit the wall (or the untagged backfill panel
        // behind the frame) and fell through to an ordinary tap walk.

        /// Hit-test results with the invisible Decorate floor plates and
        /// hanging-pickup cords removed (same skip list the floor-object
        /// approach uses) -- the first REAL surface along the ray.
        private func firstRealHit(at point: CGPoint, in view: SCNView) -> SCNHitTestResult? {
            Posse.navigationHits(view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true]))
                .first { $0.node.name != "decoratorHitProxy" && $0.node.name != "hangingPickupString" }
        }

        /// The tap's first real surface belongs to a tappable wall object.
        func exactWallHit(at point: CGPoint, in view: SCNView, controller: TapNavigationController)
            -> (target: TapNavigationController.WallInteractionTarget, hitNodeName: String)? {
            guard let hit = firstRealHit(at: point, in: view),
                  let target = controller.wallInteractionTarget(for: hit.node) else { return nil }
            return (target, hit.node.name ?? "unnamed")
        }

        /// Minimum on-screen target per axis (Apple's 44 pt touch minimum),
        /// plus a fixed 12 pt finger margin around objects already bigger.
        static let wallTargetMinimumPoints: CGFloat = 44
        static let wallTargetMarginPoints: CGFloat = 12
        /// Two candidates whose distances from the tap differ by less than
        /// this are ambiguous -- no guess.
        static let wallTargetAmbiguityPoints: CGFloat = 8

        static func pointText(_ p: CGPoint) -> String { String(format: "(%.0f, %.0f)", p.x, p.y) }

        /// A tap that missed every object near a visible wall object. Each
        /// wall-interaction anchor's bounding box is projected to screen; its
        /// touch target is that rect grown to >= 44 pt per axis (and by
        /// >= 12 pt). A candidate counts only if a hit-test at the nearest
        /// point INSIDE its real projected rect resolves to that same
        /// interaction -- i.e. it's actually visible there, not behind a wall
        /// or corner -- and it currently has something available.
        func assistedWallHit(at point: CGPoint, in view: SCNView, controller: TapNavigationController)
            -> TapNavigationController.WallInteractionTarget? {
            guard let root = view.scene?.rootNode else { return nil }
            let realHit = firstRealHit(at: point, in: view)
            var anchors: [SCNNode] = []
            root.enumerateChildNodes { node, _ in
                if controller.isWallInteractionAnchor(node) { anchors.append(node) }
            }
            var best: [String: (target: TapNavigationController.WallInteractionTarget, distance: CGFloat, rect: CGRect)] = [:]
            for anchor in anchors {
                guard let anchorTarget = controller.wallInteractionTarget(for: anchor) else { continue }
                let (lo, hi) = anchor.boundingBox
                var minX = CGFloat.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
                var inFront = true
                for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] {
                    let p = view.projectPoint(anchor.convertPosition(SCNVector3(x, y, z), to: nil))
                    if p.z <= 0 || p.z >= 1 { inFront = false }
                    minX = min(minX, CGFloat(p.x)); maxX = max(maxX, CGFloat(p.x))
                    minY = min(minY, CGFloat(p.y)); maxY = max(maxY, CGFloat(p.y))
                } } }
                guard inFront, maxX > minX, maxY > minY else { continue }
                let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                guard rect.intersects(view.bounds) else { continue }
                let growX = max(Self.wallTargetMarginPoints, (Self.wallTargetMinimumPoints - rect.width) / 2)
                let growY = max(Self.wallTargetMarginPoints, (Self.wallTargetMinimumPoints - rect.height) / 2)
                guard rect.insetBy(dx: -growX, dy: -growY).contains(point) else { continue }
                let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
                let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
                let distance = (dx * dx + dy * dy).squareRoot()
                // Visibility probe: nearest point inside the anchor's rect,
                // pulled slightly inward so it lands on the object, not its rim.
                let inner = rect.insetBy(dx: min(4, rect.width / 4), dy: min(4, rect.height / 4))
                let probe = CGPoint(x: min(max(point.x, inner.minX), inner.maxX), y: min(max(point.y, inner.minY), inner.maxY))
                guard let probeHit = firstRealHit(at: probe, in: view),
                      let probeTarget = controller.wallInteractionTarget(for: probeHit.node),
                      probeTarget.key == anchorTarget.key else { continue }
                if let existing = best[anchorTarget.key], existing.distance <= distance { continue }
                best[anchorTarget.key] = (probeTarget, distance, rect)
            }
            let ranked = best.values.sorted { $0.distance < $1.distance }
            guard let first = ranked.first else {
                diag("wallTarget.miss", ["tap": Self.pointText(point), "hitNode": realHit?.node.name ?? "nothing",
                                         "anchors": anchors.count])
                return nil
            }
            if ranked.count > 1, first.distance > 0, ranked[1].distance - first.distance < Self.wallTargetAmbiguityPoints {
                diag("wallTarget.miss", ["tap": Self.pointText(point), "hitNode": realHit?.node.name ?? "nothing",
                                         "reason": "ambiguous between \(first.target.key) and \(ranked[1].target.key)"])
                return nil
            }
            diag("wallTarget.assistedHit", ["kind": first.target.kind, "coord": first.target.face.coord,
                                            "direction": first.target.face.direction,
                                            "tap": Self.pointText(point), "hitNode": realHit?.node.name ?? "nothing",
                                            "rect": String(format: "(%.0f, %.0f, %.0f x %.0f)", first.rect.minX, first.rect.minY, first.rect.width, first.rect.height),
                                            "distancePt": Double(first.distance)])
            return first.target
        }

        func panBeganShouldTakeOverAutoWalk() -> Bool {
            guard let controller = navigationController else { return false }
            // (Oct 16: a drag on the latched walk is the hold too -- at once, no long-press wait.)
            panIsHoldTakeover = controller.tapWalkCanBeTakenOverByHold || controller.isWalkLatched
            return panIsHoldTakeover
        }

        func panEndedHoldTakeover(at location: CGPoint) {
            panIsHoldTakeover = false
            endHold(at: location)
        }

        /// Sept 28 (held-walk endpoint look): one held-walk poll. When the
        /// controller reports the walk has reached its endpoint, the same
        /// finger switches to Free Look -- its CURRENT x becomes the new
        /// horizontal zero (walk drift never turns the camera) -- and the
        /// poll stops for good: this gesture never walks again. Returns
        /// true once endpoint look has begun.
        @discardableResult
        private func heldWalkTick(at location: CGPoint) -> Bool {
            let perf = PerfMonitor.begin("input.heldWalkTick"); defer { PerfMonitor.end(perf) }   // Oct 21: measurement only (PerfMonitor)
            let fingerX = Double(location.x)
            guard let controller = navigationController else { return false }
            guard controller.advanceWhileHeld(),
                  controller.beginHeldEndpointLook(fingerX: fingerX, pointsPerQuarterTurn: Double(dragRotateDistance)) else {
                // Free walk: the tick that starts the held walk also pins
                // the held-navigation origin to THIS finger x/y (no jump).
                controller.updateHeldNavigation(fingerX: fingerX, fingerY: Double(location.y), pointsPerQuarterTurn: Double(heldWalkSteerDistance))
                return false
            }
            forwardHoldTimer?.invalidate()
            forwardHoldTimer = nil
            return true
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
            case .lobbyDefault(let name):
                let image = HallwayScene.lobbyPictureImage(name)
                material.diffuse.contents = HallwayScene.framedPhoto(image ?? HallwayScene.mirrorPlaceholder("Photo unavailable"))
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

        /// Sept 26 (Decorate-mode elevator pictures): the elevator-
        /// poster counterpart to applyLivePictureSelection just above
        /// -- same switch/resolution, but hands back a raw UIImage via
        /// completion instead of writing straight into a material, and
        /// does NOT frame it (HallwayScene.framedPhoto is an ordinary
        /// wall Picture's own frame; TapNavigationController.
        /// applyElevatorPosterImage already applies HallwayScene.
        /// elevatorPosterPhoto's own poster-specific crop/letterbox).
        func resolvePictureImage(_ selection: PictureImageSelection, floorNumber: Int, completion: @escaping (UIImage?) -> Void) {
            switch selection {
            case .lobbyDefault(let name):
                completion(HallwayScene.lobbyPictureImage(name))
            case .builtIn(let name):
                completion(HallwayScene.namedPictureImage(name))
            case .cameraRoll(let identifier):
                PhotoRollProvider.shared.image(forIdentifier: identifier, caller: "floor \(floorNumber) elevator-poster live-update", completion: completion)
            }
        }

        // Sept 27 (Decorator Surfaces, explicit-override fix): this
        // used to compute each surface's effective image with its OWN
        // inline per-floor switch (Floor 1 -> lobby-wall/floor1/
        // lobby-ceiling, Floor 2 -> wood-walnut/floor-carpet1/
        // ceiling-pattern, else -> theme.xImageName) -- a real gap,
        // since that inline logic never consulted wallTexture/
        // floorTexture/ceilingTexture at all: cycling the theme button
        // while an explicit Decorator-authored surface override was
        // active silently clobbered it back to the bare default. Now
        // routed through HallwayScene.effectiveWallImageName/
        // effectiveFloorImageName/effectiveCeilingImageName -- the SAME
        // shared resolvers the Floor Editor's "resolves to" footer and
        // the live Decorator wall-backfill fix already use -- which
        // check the explicit override FIRST and only fall through to
        // the identical per-floor/theme table this inline code used to
        // duplicate. Passing nil (no override) reproduces the exact
        // old behavior; this is a pure refactor for that case, an
        // actual bug fix only when an override is set.
        /// Oct 1 (cell-surface overrides): floor-wide defaults now skip the
        /// wall pieces of cells with their own wall override (those get the
        /// override instead), and cell floor/ceiling panels point at either
        /// their override material or the shared default -- so a floor-wide
        /// change never overwrites a local override, and removing one
        /// inherits the CURRENT default.
        func applyTheme(_ theme: HallwayTheme, wallTexture: String?, floorTexture: String?, ceilingTexture: String?, cellSurfaces: [GridCoordinate: CellSurfaceOverride] = [:], root: SCNNode? = nil) {
            let tracePhase = ElevatorArrivalTrace.shared.beginPhase("theme.apply", "materialFloor=\(currentFloorNumber) wallMaterialCount=\(wallMaterials.count)")
            defer { ElevatorArrivalTrace.shared.endPhase("theme.apply", tracePhase) }
            if theme == .myPhotos {
                applyPhotoRollTheme()
                if let root {
                    HallwayScene.applyCellFloorCeilingOverrides(in: root, cellSurfaces: cellSurfaces, floorDefault: floorMaterial, ceilingDefault: ceilingMaterial)
                }
                return
            }
            let traceWalls = ElevatorArrivalTrace.shared.beginPhase("theme.wallMaterials")
            let effectiveWallImageName = HallwayScene.effectiveWallImageName(floorNumber: currentFloorNumber, theme: theme, wallTexture: wallTexture)
            let wallOverrides = root.map { HallwayScene.cellWallOverrideMaterials(in: $0, cellSurfaces: cellSurfaces) } ?? []
            let overridden = Set(wallOverrides.map { ObjectIdentifier($0.material) })
            for material in wallMaterials where !overridden.contains(ObjectIdentifier(material)) {
                applySurface(material, imageName: effectiveWallImageName, fallbackColor: HallwayScene.wallFallbackColor)
            }
            for (material, imageName) in wallOverrides {
                applySurface(material, imageName: imageName, fallbackColor: HallwayScene.wallFallbackColor)
            }
            ElevatorArrivalTrace.shared.endPhase("theme.wallMaterials", traceWalls)
            let traceFloorCeiling = ElevatorArrivalTrace.shared.beginPhase("theme.floorCeilingMaterials")
            let effectiveFloorImageName = HallwayScene.effectiveFloorImageName(floorNumber: currentFloorNumber, theme: theme, floorTexture: floorTexture)
            applySurface(floorMaterial, imageName: effectiveFloorImageName, fallbackColor: HallwayScene.floorFallbackColor)
            let effectiveCeilingImageName = HallwayScene.effectiveCeilingImageName(floorNumber: currentFloorNumber, theme: theme, ceilingTexture: ceilingTexture)
            applySurface(ceilingMaterial, imageName: effectiveCeilingImageName, fallbackColor: HallwayScene.ceilingFallbackColor)
            ElevatorArrivalTrace.shared.endPhase("theme.floorCeilingMaterials", traceFloorCeiling)
            if let root {
                HallwayScene.applyCellFloorCeilingOverrides(in: root, cellSurfaces: cellSurfaces, floorDefault: floorMaterial, ceilingDefault: ceilingMaterial)
            }
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
                // Oct 18: "SxT", optionally "@UxV" -- the pattern phase that lines a
                // strip up with the wall around it (HallwayScene.wallRepeatName).
                let spec = name.dropFirst("wallRepeat:".count).split(separator: "@")
                let parts = spec.first.map { $0.split(separator: "x") } ?? []
                if parts.count == 2, let s = Float(parts[0]), let t = Float(parts[1]) {
                    var m = SCNMatrix4MakeScale(s, t, 1)
                    if spec.count == 2 {
                        let offset = spec[1].split(separator: "x")
                        if offset.count == 2, let u = Float(offset[0]), let v = Float(offset[1]) {
                            m.m41 = u
                            m.m42 = v
                        }
                    }
                    return m
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
            PhotoRollProvider.shared.randomImages(count: materials.count, caller: "My Photos walls/ceiling") { [weak self] index, _, image in
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

#if DEBUG
/// Oct 8: one labeled Debug-workshop HUD control (icon + caption), so each
/// developer action says what it does. Debug builds only.
private struct DevHUDButton: View {
    let systemImage: String
    let caption: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(caption)
                    .font(.system(size: 8, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel(caption.capitalized)
    }
}
#endif
