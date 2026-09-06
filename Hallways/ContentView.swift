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
}

struct ContentView: View {
    @StateObject private var tuning = TuningParams()
    @StateObject private var runtime = HallwayRuntime()
    @StateObject private var mazeStore = MazeStore()
    @StateObject private var navBridge = NavigationBridge()
    @StateObject private var themeStore = WallThemeStore()
    @State private var showTuning = false // sliders are dev-only clutter now that the maze is the default experience
    @State private var showGridEditor = false
    // Only resynced when the grid editor closes (not live on every paint
    // stroke) — see the .id() below and the fullScreenCover's onDismiss.
    @State private var sceneVersion = 0

    // Cash total, always on screen -- Eddie: "a big fast total that
    // appears on the screen somewhere." Gold to match the 3D cash
    // pieces themselves; same dark-capsule treatment as the
    // collected-trash HUD strip so the two read as the same UI family.
    private var moneyHUD: some View {
        HStack(spacing: 4) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 16, weight: .bold))
            Text("\(mazeStore.moneyTotal)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
        }
        .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.3))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.7), in: Capsule())
    }

    var body: some View {
        ZStack {
            HallwaySceneView(tuning: tuning, runtime: runtime, mazeStore: mazeStore, navBridge: navBridge, themeStore: themeStore)
                .id(sceneVersion)
                .ignoresSafeArea()

            if let navController = navBridge.controller {
                NavigationOverlay(controller: navController)

                if navController.floorMapOverlayVisible {
                    FloorMapOverlayView(mazeStore: mazeStore, youAreHere: navController.currentCell, youAreHereFacing: navController.facing, onDismiss: {
                        withAnimation { navController.floorMapOverlayVisible = false }
                    })
                    .transition(.scale(scale: 0.05).combined(with: .opacity))
                    .zIndex(1)
                }
            }

            VStack {
                HStack {
                    moneyHUD
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 8) {
                            Button {
                                runtime.requestReset()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            Button {
                                withAnimation { showTuning.toggle() }
                            } label: {
                                Image(systemName: "slider.horizontal.3")
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
                            Button {
                                themeStore.cycle()
                            } label: {
                                Image(systemName: "paintpalette.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                        }
                        Text(themeStore.current.label)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                        if showTuning {
                            TuningPanel(tuning: tuning)
                        }
                    }
                }
                Spacer()
            }
            .padding()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
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
    }
}

/// The always-visible D-pad: forward/left/right/back, each one dimmed
/// (but still shown) whenever that move isn't currently possible, plus
/// a small "Dead end" label above it when you've backed into one, and a
/// finish message at the target. A separate view (rather than folding
/// this into ContentView) because it needs @ObservedObject on the
/// controller directly — a nested @Published inside NavigationBridge's
/// own @Published wouldn't otherwise trigger a re-render on its own.
private struct NavigationOverlay: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        VStack {
            if !controller.collectedObjects.isEmpty {
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
            // Used to swap this whole area for a permanent "You made
            // it!" banner (dpad and all) the first time a walk ended
            // by arriving at the elevator's cell -- fine back when
            // that was a one-way "you're done with this floor" event,
            // wrong now that it's the same fixed cell every floor
            // spawns you at and the elevator's just another fixture
            // you can walk up to, use, or walk away from at will
            // (Eddie, Sept 5: "the elevator becomes just another
            // activity"). The D-pad stays up unconditionally now --
            // TapNavigationController.canGoForward/canRotate handle
            // the one real constraint left (don't walk off while the
            // doors are actually mid-animation) on their own.
            if controller.isAtDeadEnd {
                label("Dead end", systemImage: "exclamationmark.triangle.fill")
            }
            dpad
                .padding(.bottom, 40)
        }
        .animation(.easeInOut(duration: 0.2), value: controller.transientMessage)
    }

    // What you're currently carrying -- first slice of the pick-up
    // mechanic: walking into an object removes it from the hallway and
    // adds it here, oldest first. No delivery/matching logic yet -- this
    // is purely "gobble it, show you have it," same "just enough to feel
    // it out" scoping as the very first heart placement.
    private var collectedStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(controller.collectedObjects.enumerated()), id: \.offset) { _, kind in
                Text(kind.displayEmoji)
                    .font(.system(size: 22))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.7), in: Capsule())
    }

    // Forward/left/right/back, always laid out the same way — only
    // enabled/dimmed state changes cell to cell. Left/right/back all
    // just spin you in place (no walking) — back is a full 180 instead
    // of a 90 — and forward is the only thing that ever actually
    // walks, committing to whatever direction you're currently facing.
    // Swiping (wired in HallwaySceneView's Coordinator) does the exact
    // same three things as left/right/back, for anyone who'd rather not
    // reach for the buttons.
    private var dpad: some View {
        VStack(spacing: 10) {
            dpadButton("arrow.up", enabled: controller.canGoForward) {
                controller.advance()
            }
            HStack(spacing: 10) {
                dpadButton("arrow.turn.up.left", enabled: controller.canRotate) {
                    controller.rotate(toward: controller.facing.left)
                }
                dpadButton("arrow.uturn.down", enabled: controller.canRotate) {
                    controller.rotate(toward: controller.facing.opposite)
                }
                dpadButton("arrow.turn.up.right", enabled: controller.canRotate) {
                    controller.rotate(toward: controller.facing.right)
                }
            }
        }
    }

    private func dpadButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        // The dark circle background stays at the SAME opacity whether
        // enabled or not — only the icon dims. A washed-out or very
        // dark hallway (near-black scene background) was making a
        // dimmed circle-and-all read as "the controls just vanished";
        // keeping the circle's presence constant means there's always
        // a visible shape on screen, with only the icon's brightness
        // telling you whether that button currently does anything.
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(enabled ? .white : .white.opacity(0.35))
                .frame(width: 52, height: 52)
                .background(Color.black.opacity(0.75), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1.5))
        }
        .disabled(!enabled)
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

/// Bridges SceneKit into SwiftUI: builds the hallway scene once, wires the
/// camera to a MovementController driven by raw touches on the SCNView.
struct HallwaySceneView: UIViewRepresentable {
    @ObservedObject var tuning: TuningParams
    @ObservedObject var runtime: HallwayRuntime
    @ObservedObject var mazeStore: MazeStore
    @ObservedObject var navBridge: NavigationBridge
    @ObservedObject var themeStore: WallThemeStore

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
            let (scene, cameraNode, _, wallMaterials, floorMaterial, ceilingMaterial, deadEndCapMaterials, objectNodes, destinationNodes, elevatorDoors, exitSignNodes, floorMapPlaneNodes) = HallwayScene.build(fromMaze: mazeStore.cells, cellSize: mazeStore.cellSize, wallHeight: mazeStore.wallHeight, objects: mazeStore.objects, destinations: mazeStore.destinations, exitSigns: mazeStore.exitSigns, floorMaps: mazeStore.floorMaps, spotlights: mazeStore.spotlights, theme: themeStore.current)
            view.scene = scene
            view.pointOfView = cameraNode
            context.coordinator.wallMaterials = wallMaterials
            context.coordinator.floorMaterial = floorMaterial
            context.coordinator.ceilingMaterial = ceilingMaterial
            context.coordinator.deadEndCapMaterials = deadEndCapMaterials

            let start = mazeStore.startCoordinate ?? GridCoordinate(row: 0, col: 0)
            let end = mazeStore.endCoordinate ?? start
            let facing = startingFacing(at: start, cells: mazeStore.cells)
            let navController = TapNavigationController(cameraNode: cameraNode, scene: scene, cells: mazeStore.cells, cellSize: mazeStore.cellSize, startCell: start, startFacing: facing, endCell: end, objects: mazeStore.objects, objectNodes: objectNodes, destinations: mazeStore.destinations, destinationNodes: destinationNodes, elevatorLeftDoor: elevatorDoors?.left, elevatorRightDoor: elevatorDoors?.right, elevatorMountDirection: elevatorDoors?.direction, exitSignNodes: exitSignNodes, exitSigns: mazeStore.exitSigns, floorMaps: mazeStore.floorMaps, floorMapPlaneNodes: floorMapPlaneNodes)
            navController.onCollectCash = { [mazeStore] amount in
                mazeStore.addMoney(amount)
            }
            // Fires once the elevator's own open -> dwell -> close
            // sequence finishes (see TapNavigationController.
            // openElevator()) -- moves on to whatever floor this one's
            // linked to (see MazeStore.advanceToNextMaze). Nulling the
            // controller first avoids a stale "You made it!" flash
            // from the about-to-be-replaced scene — same idea as the
            // grid editor's onDismiss fix.
            navController.onReachedEnd = { [mazeStore, navBridge] in
                guard mazeStore.nextMazeID != nil else { return }
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
            view.addGestureRecognizer(panRotate)

            let swipeDown = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipeDown))
            swipeDown.direction = .down
            view.addGestureRecognizer(swipeDown)

            // @StateObject updates need to land on the next runloop tick,
            // not synchronously inside makeUIView.
            DispatchQueue.main.async {
                navBridge.controller = navController
            }
        }

        view.backgroundColor = .black
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = false // our own touch/tap handling must be the only thing driving the camera
        view.isPlaying = true
        view.rendersContinuously = true

        context.coordinator.lastResetToken = runtime.resetToken
        context.coordinator.lastTheme = themeStore.current
        return view
    }

    func updateUIView(_ uiView: TouchTrackingSCNView, context: Context) {
        if context.coordinator.lastResetToken != runtime.resetToken {
            context.coordinator.lastResetToken = runtime.resetToken
            context.coordinator.movementController?.reset()
            context.coordinator.navigationController?.reset()
        }
        if context.coordinator.lastTheme != themeStore.current {
            context.coordinator.lastTheme = themeStore.current
            context.coordinator.applyTheme(themeStore.current)
        }
    }

    final class Coordinator: NSObject {
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
        /// One per true dead end, same "own material per node" idea as
        /// wallMaterials — each dead end can show a different photo.
        /// Kept in their own array (not folded into wallMaterials)
        /// because they want the opposite texture treatment (clamped/
        /// untiled, unlit) even under the bundled themes. See
        /// HallwayScene.makeDeadEndCapMaterial.
        var deadEndCapMaterials: [SCNMaterial] = []
        var lastTheme: HallwayTheme = .brick

        // Drag-controlled left/right turning: how many points of
        // horizontal drag equal one full 90-degree turn. Purely a feel
        // constant — smaller means a shorter drag commits a turn,
        // larger means a longer, more deliberate one.
        private let dragRotateDistance: CGFloat = 140

        // A tap anywhere on screen still means "walk forward" (the
        // D-pad's forward button does the exact same thing) -- EXCEPT
        // when the tap actually lands on a destination's steel shutter
        // right in front of you, in which case it's the door asking to
        // be opened instead. Eddie, Sept 5: "i think it should wait for
        // you to tap the steel door before it slides up."
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let controller = navigationController else { return }
            if let view = gesture.view as? SCNView {
                let location = gesture.location(in: view)
                let hits = view.hitTest(location, options: nil)
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
                    navLog("tap hit wall map")
                    withAnimation { controller.floorMapOverlayVisible = true }
                    return
                }
            }
            navLog("tap")
            controller.advance()
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
            for material in deadEndCapMaterials {
                applyDeadEndCap(material, imageName: theme.wallImageName, fallbackColor: HallwayScene.wallFallbackColor)
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

        /// Same idea as applySurface, but keeps the clamp/untiled,
        /// full-picture look a dead-end cap wants instead of the tiled
        /// look every other surface gets.
        private func applyDeadEndCap(_ material: SCNMaterial?, imageName: String?, fallbackColor: UIColor) {
            guard let material else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            if let image = HallwayScene.resolveThemeImage(imageName) {
                material.diffuse.contents = image
                material.diffuse.wrapS = .clamp
                material.diffuse.wrapT = .clamp
                material.diffuse.contentsTransform = SCNMatrix4Identity
            } else {
                material.diffuse.contents = fallbackColor
            }
            SCNTransaction.commit()
        }

        /// My Photos — pulls camera-roll photos live (async, permission-
        /// gated) instead of a bundled jpg: a different photo on EACH
        /// wall segment and dead-end cap (cycling through however many
        /// came back if there are more walls than photos — see
        /// PhotoRollProvider.maxPoolSize), plus one more for the
        /// ceiling. One photo per surface (no tiling — this is a
        /// picture, not a pattern). Leaves whatever's currently showing
        /// alone if access is denied or there are no photos, rather
        /// than flashing to a blank fallback color.
        private func applyPhotoRollTheme() {
            let needed = wallMaterials.count + deadEndCapMaterials.count + 1
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
                for material in self.deadEndCapMaterials { apply(material) }
                if let ceilingMaterial = self.ceilingMaterial { apply(ceilingMaterial) }

                SCNTransaction.commit()
            }
        }
    }
}

#Preview {
    ContentView()
}
