//
//  TapNavigationController.swift
//  Hallways
//
//  The D-pad model: forward/back/left/right are always the controls.
//  Forward walks the maze graph (MazeNavigation) from wherever you're
//  currently facing, auto-continuing through any cell that only has one
//  viable way to keep going, until it hits a real decision, a dead end,
//  or the target — same walk-to-decision engine as before. Left/right
//  are pure rotation in place — no movement, just spins you to face a
//  new compass direction — so picking a direction at an intersection is
//  now "turn until you're facing it, then hit forward" instead of a
//  bank of per-choice buttons. Back turns you around in place — the
//  same pivot as left/right, just a 180 instead of a 90 — and then
//  waits for a forward tap like any other turn, instead of
//  auto-walking you back the way you came.
//
//  Threading note: renderer(_:updateAtTime:) is called by SceneKit on
//  its own rendering thread, not the main thread. Every @Published
//  property here is UI-observed (SwiftUI's D-pad, the 2D editor's "you
//  are here" marker), and SwiftUI requires those to be set on the main
//  thread — setting them from the render thread was silently failing to
//  reach the UI and spamming the console with "Publishing changes from
//  background threads" warnings. Fixed by keeping the render thread's
//  own turn-by-turn bookkeeping in plain local values and only ever
//  writing the @Published properties inside a DispatchQueue.main.async
//  block.
//
//  Also does the portrait/landscape light-range fix: SCNCamera's
//  default vertical FOV is fixed, so a tall/narrow portrait viewport
//  shows a narrower horizontal slice than landscape does, which reads
//  as "less lit hallway visible" even though the underlying light is
//  identical. Rather than fight the FOV itself (chasing a matching
//  horizontal FOV blows portrait out to a fisheye), this scales the
//  headlamp's falloff distance and the scene's fog distances up when
//  the live viewport is narrow, so portrait shows proportionally the
//  same amount of lit hallway as landscape does. Recomputed every frame
//  from renderer.currentViewport since the device can rotate mid-walk.
//

import SceneKit
import Combine

final class TapNavigationController: NSObject, SCNSceneRendererDelegate, ObservableObject {
    let cameraNode: SCNNode
    private let cells: Set<GridCoordinate>
    private let cellSize: CGFloat
    private let endCell: GridCoordinate
    private let eyeHeight: Float
    /// Units/sec while animating between cell centers.
    private let travelSpeed: Double = 6.0

    // Aspect-compensated lighting (see header note above).
    private weak var scene: SCNScene?
    private weak var headlampLight: SCNLight?
    private var baseFogStart: Double = 0
    private var baseFogEnd: Double = 0
    private var baseAttenStart: Double = 0
    private var baseAttenEnd: Double = 0

    @Published private(set) var isAnimating = false
    @Published private(set) var reachedEnd = false
    /// Fired (main thread) the moment reachedEnd flips true — this is
    /// the hook the multi-floor transition hangs off of. Not @Published
    /// itself, just a plain callback set once at construction time;
    /// nothing here needs to observe it, only react to it. Left nil (a
    /// no-op) for the empty-maze fallback prototype, which has no
    /// floors to advance to.
    var onReachedEnd: (() -> Void)?
    /// True while a finger is actively dragging a left/right turn —
    /// distinct from isAnimating, which is the TIMED pivot/translate
    /// animation state. A live drag drives the camera's yaw directly,
    /// one-to-one with the finger, with no timer involved until the
    /// finger lifts and it either completes or springs back (at which
    /// point isAnimating takes over for that short settle animation).
    @Published private(set) var isDragRotating = false
    private var dragBaseYaw: Double = 0

    private let startCell: GridCoordinate
    private let startFacing: Direction
    /// The cell you're standing in right now — exposed so the 2D grid
    /// editor can show a "you are here" marker when you jump back to it.
    @Published private(set) var currentCell: GridCoordinate
    /// The heading you're currently facing/just arrived with — drives
    /// which D-pad buttons are enabled (forward is only lit up when
    /// this direction is actually open from currentCell) and how the 2D
    /// marker's arrow is drawn.
    @Published private(set) var facing: Direction

    /// Every compass direction that's actually walkable from
    /// currentCell right now, computed fresh from the maze data rather
    /// than stored — so it's always correct after a rotate (which
    /// changes facing but not currentCell) without any extra
    /// bookkeeping. Includes the way you came from, since turning
    /// around (the D-pad's back button) and then walking is exactly
    /// how you retrace your steps now — there's no separate "reverse"
    /// concept left to special-case.
    var openDirections: Set<Direction> {
        Set(Direction.allCases.filter { d in
            let n = GridCoordinate(row: currentCell.row + d.delta.row, col: currentCell.col + d.delta.col)
            return cells.contains(n)
        })
    }

    /// A true dead end — only one way in or out of this cell at all —
    /// vs. just "can't go forward from here right now" (which can also
    /// happen mid-turn at an intersection you haven't rotated through
    /// yet). The maze's own start is structurally identical to a dead
    /// end (a corridor's end cell has exactly one exit whether that
    /// corridor happens to be where you spawn or where you got stuck),
    /// so without excluding startCell here, "Dead end" was showing on
    /// the very first frame of every game before you'd taken a single
    /// step — excluded so the label only ever means "you walked into
    /// one," never "this is where you started." (HallwayScene's own
    /// per-cell dead-end detection for the photo-cap wall treatment is
    /// separate and intentionally NOT excluded — the start cell's one
    /// solid wall should still get the full-picture treatment same as
    /// any other dead end, this exclusion is purely about the label.)
    var isAtDeadEnd: Bool { openDirections.count == 1 && currentCell != startCell }

    var canGoForward: Bool { !isAnimating && !isDragRotating && !reachedEnd && openDirections.contains(facing) }
    var canRotate: Bool { !isAnimating && !isDragRotating && !reachedEnd }

    private enum SegmentPhase {
        case pivot      // rotating in place, position unchanged
        case translate  // moving forward, facing already locked in
    }

    private var animationSteps: [NavigationStep] = []
    private var animationIndex = 0
    private var pendingOutcome: NavigationOutcome = .deadEnd
    private var phase: SegmentPhase = .translate
    private var segmentStart = SCNVector3Zero
    private var segmentTarget = SCNVector3Zero
    private var segmentProgress: Double = 0
    private var pivotStartYaw: Double = 0
    private var pivotTargetYaw: Double = 0
    private let pivotDuration: Double = 0.18
    private var lastTime: TimeInterval = 0

    // A standalone rotate (left/right button, not part of a forward
    // walk) plays the exact same pivot animation as a mid-walk turn,
    // just without a translate phase after it — this flag tells
    // renderer(updateAtTime:) which ending to use.
    private var standaloneRotation = false
    private var pendingRotationTarget: Direction = .north

    init(cameraNode: SCNNode, scene: SCNScene, cells: Set<GridCoordinate>, cellSize: CGFloat, startCell: GridCoordinate, startFacing: Direction, endCell: GridCoordinate) {
        self.cameraNode = cameraNode
        self.scene = scene
        self.cells = cells
        self.cellSize = cellSize
        self.startCell = startCell
        self.startFacing = startFacing
        self.currentCell = startCell
        self.facing = startFacing
        self.endCell = endCell
        self.eyeHeight = cameraNode.position.y

        let foundLight = cameraNode.childNodes.compactMap { $0.light }.first { $0.type == .omni }
        self.headlampLight = foundLight
        // SceneKit declares these distance properties inconsistently
        // (CGFloat in some spots, Double in others, depending on SDK
        // vintage) — Self.doubleValue/.convert below read and write
        // through a generic BinaryFloatingPoint bridge so this compiles
        // correctly no matter which one the installed SDK actually uses.
        self.baseFogStart = Self.doubleValue(scene.fogStartDistance)
        self.baseFogEnd = Self.doubleValue(scene.fogEndDistance)
        self.baseAttenStart = foundLight.map { Self.doubleValue($0.attenuationStartDistance) } ?? 0
        self.baseAttenEnd = foundLight.map { Self.doubleValue($0.attenuationEndDistance) } ?? 0

        super.init()
    }

    private func worldPosition(for coord: GridCoordinate) -> SCNVector3 {
        SCNVector3(Float(coord.col) * Float(cellSize), eyeHeight, Float(coord.row) * Float(cellSize))
    }

    /// Rotate in place to face a new compass direction — the left/right
    /// D-pad buttons. Pure pivot, no movement, and doesn't touch
    /// currentCell/history at all.
    func rotate(toward direction: Direction) {
        guard canRotate, direction != facing else { return }
        standaloneRotation = true
        pendingRotationTarget = direction
        phase = .pivot
        segmentProgress = 0
        pivotStartYaw = Double(cameraNode.eulerAngles.y)
        pivotTargetYaw = pivotStartYaw + shortestDelta(from: pivotStartYaw, to: direction.yaw)
        isAnimating = true
    }

    /// Begins a drag-controlled turn (a pan gesture, not a button tap):
    /// the finger now drives the camera's yaw directly until it lifts.
    /// Refuses if a walk/rotate/another drag is already in progress.
    func beginDragRotate() {
        guard canRotate else { return }
        dragBaseYaw = Double(cameraNode.eulerAngles.y)
        isDragRotating = true
    }

    /// Call continuously while the finger moves. `fraction` is how far
    /// through a 90-degree turn the drag currently represents, already
    /// sign-corrected so positive = turning left (toward facing.left) —
    /// clamped to -1...1 so the camera can never spin past a quarter
    /// turn no matter how far the finger drags.
    func updateDragRotate(fraction: Double) {
        guard isDragRotating else { return }
        let clamped = max(-1, min(1, fraction))
        cameraNode.eulerAngles = SCNVector3(0, Float(dragBaseYaw + clamped * .pi / 2), 0)
    }

    /// Call when the finger lifts. Past the halfway point (45 degrees,
    /// |fraction| >= 0.5) the turn completes the rest of the way to a
    /// full 90; short of it, the camera springs back to the heading the
    /// drag started from. Either way this animates the remaining
    /// distance (reusing the same pivot machinery a tapped rotate()
    /// uses) rather than snapping.
    func endDragRotate(fraction: Double) {
        guard isDragRotating else { return }
        isDragRotating = false
        let clamped = max(-1, min(1, fraction))
        let committing = abs(clamped) >= 0.5
        let target: Direction = committing ? (clamped > 0 ? facing.left : facing.right) : facing

        standaloneRotation = true
        pendingRotationTarget = target
        phase = .pivot
        segmentProgress = 0
        pivotStartYaw = Double(cameraNode.eulerAngles.y)
        pivotTargetYaw = pivotStartYaw + shortestDelta(from: pivotStartYaw, to: target.yaw)
        isAnimating = true
    }

    /// The forward D-pad button (and a bare tap): walks from currentCell
    /// in whatever direction you're currently facing, all the way to
    /// the next real decision, dead end, or the target.
    func advance() {
        guard canGoForward else { return }

        let (steps, outcome) = walkToNextDecision(from: currentCell, heading: facing, cells: cells, end: endCell)
        guard !steps.isEmpty else { return }

        animationSteps = steps
        animationIndex = 0
        pendingOutcome = outcome
        beginSegment(steps[0], currentFacing: facing)
        isAnimating = true
    }

    /// Snap straight back to the start, fully stopped. Wired to the same
    /// on-screen Reset button as the free-roam prototype.
    func reset() {
        isAnimating = false
        isDragRotating = false
        reachedEnd = false
        currentCell = startCell
        facing = startFacing
        phase = .translate
        lastTime = 0
        standaloneRotation = false
        cameraNode.position = worldPosition(for: startCell)
        cameraNode.eulerAngles = SCNVector3(0, Float(startFacing.yaw), 0)
    }

    /// Shortest signed angle (radians, in (-pi, pi]) to get from `from`
    /// to `to` — used so a turn always rotates the short way and never
    /// whips around through a wraparound seam.
    private func shortestDelta(from: Double, to: Double) -> Double {
        var delta = to - from
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }

    private func beginSegment(_ step: NavigationStep, currentFacing: Direction) {
        segmentStart = cameraNode.position
        segmentTarget = worldPosition(for: step.cell)
        segmentProgress = 0

        if step.heading != currentFacing {
            // Turning — play a quick in-place pivot first, position held,
            // so the direction change actually reads as a turn instead of
            // an instant snap. Still only ever 90 degrees at a time; this
            // doesn't bring back free-angle steering, just animates the
            // fixed turn you already committed to.
            phase = .pivot
            pivotStartYaw = Double(cameraNode.eulerAngles.y)
            pivotTargetYaw = pivotStartYaw + shortestDelta(from: pivotStartYaw, to: step.heading.yaw)
        } else {
            // Already facing the right way (a plain pass-through) —
            // straight into the move, no pivot needed.
            phase = .translate
        }
    }

    /// Reads any SceneKit floating-point property (CGFloat or Double,
    /// whichever the SDK actually declares) into a plain Double for this
    /// class's own bookkeeping.
    private static func doubleValue<T: BinaryFloatingPoint>(_ value: T) -> Double {
        Double(value)
    }

    /// The inverse of doubleValue — converts back to whatever concrete
    /// type the assignment target actually needs. Swift infers T from
    /// the property being assigned into, so this adapts automatically
    /// instead of hardcoding a guess at SceneKit's declared type.
    private static func convert<T: BinaryFloatingPoint>(_ value: Double) -> T {
        T(value)
    }

    /// Scales the headlamp's falloff and the scene's fog distances by
    /// how narrow the live viewport is, every frame, so a portrait
    /// device shows proportionally as much lit hallway as landscape
    /// does. Landscape (aspect ~2.0) comes out to essentially a 1.0
    /// multiplier — untouched — while a typical portrait phone aspect
    /// (~0.46) clamps to the 1.6x ceiling rather than scaling all the
    /// way up, so it stays a brightness fix and never turns into
    /// infinite draw distance.
    private func applyAspectCompensation(_ renderer: SCNSceneRenderer) {
        guard baseFogEnd > 0 || baseAttenEnd > 0 else { return }
        let viewport = renderer.currentViewport
        guard viewport.height > 0 else { return }
        let aspect = Double(viewport.width / viewport.height)
        let multiplier = min(1.6, max(1.0, 2.0 / max(aspect, 0.3)))

        if baseFogEnd > 0, let scene {
            scene.fogStartDistance = Self.convert(baseFogStart * multiplier)
            scene.fogEndDistance = Self.convert(baseFogEnd * multiplier)
        }
        if baseAttenEnd > 0, let headlampLight {
            headlampLight.attenuationStartDistance = Self.convert(baseAttenStart * multiplier)
            headlampLight.attenuationEndDistance = Self.convert(baseAttenEnd * multiplier)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        defer { lastTime = time }
        applyAspectCompensation(renderer)
        guard lastTime > 0 else { return }
        let dt = min(time - lastTime, 1.0 / 20.0)
        guard dt > 0, isAnimating else { return }

        switch phase {
        case .pivot:
            segmentProgress += dt / pivotDuration
            let t = min(1.0, segmentProgress)
            let eased = t * t * (3 - 2 * t)
            let yaw = pivotStartYaw + eased * (pivotTargetYaw - pivotStartYaw)
            cameraNode.eulerAngles = SCNVector3(0, Float(yaw), 0)

            guard t >= 1.0 else { return }
            cameraNode.eulerAngles = SCNVector3(0, Float(pivotTargetYaw), 0)

            if standaloneRotation {
                // A left/right D-pad tap — done the moment the pivot
                // finishes, no translate phase follows.
                standaloneRotation = false
                let newFacing = pendingRotationTarget
                DispatchQueue.main.async { [weak self] in
                    self?.facing = newFacing
                    self?.isAnimating = false
                }
                return
            }

            phase = .translate
            segmentProgress = 0

        case .translate:
            let segmentDuration = Double(cellSize) / travelSpeed
            segmentProgress += dt / max(segmentDuration, 0.001)
            let t = min(1.0, segmentProgress)
            let eased = t * t * (3 - 2 * t) // smoothstep — gentle start/stop per cell

            cameraNode.position = SCNVector3(
                segmentStart.x + Float(eased) * (segmentTarget.x - segmentStart.x),
                eyeHeight,
                segmentStart.z + Float(eased) * (segmentTarget.z - segmentStart.z)
            )

            guard t >= 1.0 else { return }

            cameraNode.position = segmentTarget
            let finishedStep = animationSteps[animationIndex]
            let newCell = finishedStep.cell
            let newFacing = finishedStep.heading

            animationIndex += 1
            if animationIndex < animationSteps.count {
                // Mid-walk — more steps to go. Keep the render thread's
                // own turn logic on the local values it just computed
                // (never read back self.facing, which won't be updated
                // until the dispatch below actually runs on main).
                beginSegment(animationSteps[animationIndex], currentFacing: newFacing)
                DispatchQueue.main.async { [weak self] in
                    self?.currentCell = newCell
                    self?.facing = newFacing
                }
            } else {
                let outcome = pendingOutcome
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.currentCell = newCell
                    self.isAnimating = false
                    self.facing = newFacing
                    if case .reachedEnd = outcome {
                        self.reachedEnd = true
                        self.onReachedEnd?()
                    }
                }
            }
        }
    }
}
