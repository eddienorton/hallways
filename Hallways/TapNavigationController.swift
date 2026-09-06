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
import UIKit

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
    /// Fired (main thread) once the elevator's doors have visually
    /// closed again -- the hook the multi-floor transition hangs off
    /// of (see openElevator()). Not @Published itself, just a plain
    /// callback set once at construction time; nothing here needs to
    /// observe it, only react to it. Left nil (a no-op) for the
    /// empty-maze fallback prototype, which has no floors to advance
    /// to. Used to fire off a `reachedEnd` published flag flipping
    /// true instead, back when reaching the elevator's cell was a
    /// one-way "you're done with this floor" event -- gone now that
    /// start and end are the same cell and the elevator's just another
    /// fixture you walk up to whenever (Eddie, Sept 5: "the elevator
    /// becomes just another activity"); this doc comment is what's
    /// left of that history.
    var onReachedEnd: (() -> Void)?
    /// Fired (main thread, same as onReachedEnd) the instant a cash
    /// object is absorbed, with its dollar value -- ContentView wires
    /// this straight to MazeStore.addMoney(_:). Kept as a callback
    /// rather than a direct MazeStore reference so this class stays
    /// decoupled from persistence, same reasoning as onReachedEnd.
    var onCollectCash: ((Int) -> Void)?
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
    /// Also drives updateExitSignHighlight() below: Eddie, Sept 5
    /// (round 2), reported that an Exit Sign one cell short of the
    /// intersection it's mounted at reads as "turn now" when the real
    /// instruction only applies once you're actually standing there.
    /// This didSet is how exactly one sign -- the one at wherever
    /// currentCell just became -- gets promoted to the bright/enlarged
    /// "neon" look while every other sign (including the one just
    /// left) stays dim.
    @Published private(set) var currentCell: GridCoordinate {
        didSet {
            guard oldValue != currentCell else { return }
            updateExitSignHighlight()
            // "it informs you of something that just happened, then
            // its gone once you leave" (Eddie, Sept 5) -- leaving IS
            // currentCell changing, so that's the one place this needs
            // to clear. No timer, nothing else has to remember to do
            // this.
            if transientMessage != nil {
                transientMessage = nil
            }
            refreshFloorMapTexture()
        }
    }
    /// A short one-line status message, on screen only for as long as
    /// it's true -- e.g. tapping an empty chute's door with nothing to
    /// throw out. ContentView's NavigationOverlay reads this straight
    /// off the controller (same @ObservedObject pattern the D-pad and
    /// collected-strip already use) and renders it with the exact same
    /// label() capsule "Dead end"/"You made it!" already use, rather
    /// than a new floating 3D object -- one line of text doesn't need
    /// its own rendering technique. Cleared automatically by
    /// currentCell's didSet above.
    @Published private(set) var transientMessage: String?
    /// The heading you're currently facing/just arrived with — drives
    /// which D-pad buttons are enabled (forward is only lit up when
    /// this direction is actually open from currentCell) and how the 2D
    /// marker's arrow is drawn.
    @Published private(set) var facing: Direction

    /// Which cell holds which object, as of scene-build time -- an
    /// immutable snapshot, same idea as `cells`. objectNodes pairs each
    /// of those coordinates with the actual 3D node
    /// HallwayScene.build(fromMaze:) built for it, so pickup knows both
    /// WHAT to add to the carried list and WHICH node to hide.
    private let objectKinds: [GridCoordinate: ObjectKind]
    private let objectNodes: [GridCoordinate: SCNNode]
    /// Which of objectKinds' coordinates have been picked up this run --
    /// doubles as the "already collected?" check so walking back over an
    /// empty cell doesn't re-collect it. Cleared by reset(), which also
    /// re-adds each named node back into the scene, so Reset genuinely
    /// starts the floor over instead of leaving already-picked-up
    /// objects permanently missing.
    private var collectedCoords: Set<GridCoordinate> = []
    /// Every object picked up this run, oldest first -- what the HUD
    /// strip in ContentView actually displays.
    @Published private(set) var collectedObjects: [ObjectKind] = []

    /// The deposit half of the mechanic -- same shape as objectKinds/
    /// objectNodes above, but destinationNodes points at the metal
    /// SHUTTER node each one built (HallwayScene.build(fromMaze:)
    /// already decided which wall it's mounted on and what's hidden
    /// behind it; this class only ever animates that one node).
    private let destinationKinds: [GridCoordinate: ObjectKind]
    private let destinationNodes: [GridCoordinate: SCNNode]
    /// Each destination shutter's shut position, captured once at
    /// init so reset() can snap it straight back there regardless of
    /// how far an in-progress slide animation had gotten.
    private let destinationClosedPositions: [GridCoordinate: SCNVector3]
    /// Which destinations have actually been opened this run -- the
    /// "already delivered, don't re-trigger" check, mirroring
    /// collectedCoords.
    private var deliveredCoords: Set<GridCoordinate> = []

    /// The elevator's 2 door panels and which wall they're mounted on
    /// -- all nil for the empty-maze fallback prototype and for a
    /// floor so small its start and end cells are the same (nothing to
    /// reach). Unlike destinations, there's only ever ONE elevator per
    /// floor, so no coordinate-keyed dictionary is needed.
    private let elevatorLeftDoor: SCNNode?
    private let elevatorRightDoor: SCNNode?
    private let elevatorMountDirection: Direction?
    /// Each door panel's shut position, captured once at init -- same
    /// idea as destinationClosedPositions above, so reset() can snap
    /// both panels straight back regardless of how far an in-progress
    /// open/close animation had gotten. Sept 6 bug fix: with the doors
    /// now taking ~4s total to open/dwell/close, hitting Reset mid-
    /// sequence used to leave them stranded wherever they were AND
    /// leave elevatorInUse stuck true, softlocking that elevator until
    /// the floor was rebuilt some other way.
    private let elevatorLeftClosedPosition: SCNVector3?
    private let elevatorRightClosedPosition: SCNVector3?
    /// Guards the open -> dwell -> close -> advance sequence against a
    /// second tap re-triggering it while it's already mid-flight.
    private var elevatorInUse = false

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

    // Used to also require !reachedEnd -- back when arriving at the
    // elevator's cell was a one-way "you're done here" event that
    // permanently locked out further movement (and hid the D-pad
    // entirely, see NavigationOverlay). That's exactly backwards now
    // that the elevator's just another fixture you can walk up to
    // and away from freely (Eddie, Sept 5: "if you want to ride the
    // elevator all day... feel free"). !elevatorInUse is the real
    // remaining concern -- don't let the player walk off mid-slide
    // while the doors are actually open/animating.
    var canGoForward: Bool { !isAnimating && !isDragRotating && !elevatorInUse && openDirections.contains(facing) }
    var canRotate: Bool { !isAnimating && !isDragRotating && !elevatorInUse }

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

    /// Every Exit Sign built for this floor, keyed by the intersection
    /// cell it's mounted at -- HallwayScene.build(fromMaze:) already
    /// computed placement/direction once at build time; this is just
    /// the lookup table so this controller can react to the player's
    /// OWN position without duplicating any of that topology logic.
    private let exitSignNodes: [GridCoordinate: SCNNode]
    /// Each sign's own compass-facing direction, straight from
    /// mazeStore.exitSigns -- kept here (not just baked into the node)
    /// so this controller can recompute a label relative to the
    /// player's CURRENT facing every time a sign goes neon, rather
    /// than trusting whatever string HallwayScene happened to build
    /// the node with (which is only ever a placeholder -- see
    /// HallwayScene.makeExitSignNode's doc comment).
    private let exitSignDirections: [GridCoordinate: Direction]
    /// Whichever Exit Sign is currently neon, if any -- at most one at
    /// a time, matching "there's only one cell you're actually
    /// standing in."
    private var neonExitSignCell: GridCoordinate?

    /// Every cell a "You Are Here" map is mounted at, straight from
    /// mazeStore.floorMaps -- just the coordinates, since advance()'s
    /// stop check and viewedFloorMapCoords below only ever need "is
    /// there one here," never which wall it's on (HallwayScene already
    /// built the node; this controller only decides whether walking
    /// through is worth stopping for).
    private let floorMapCoords: Set<GridCoordinate>
    /// Which floor-map cells you've actually arrived at and stood in
    /// front of this run -- same "already handled, don't re-trigger"
    /// role as collectedCoords/deliveredCoords, except nothing ever
    /// gets consumed here (the map stays up forever), so this is what
    /// keeps a map you've already seen once from force-stopping the
    /// walk every single time you pass it again. Cleared by reset(),
    /// same as the other two.
    private var viewedFloorMapCoords: Set<GridCoordinate> = []

    /// Every "You Are Here" map's picture plane for this floor, straight
    /// from HallwayScene.build(fromMaze:)'s own floorMapPlaneNodes --
    /// used two ways: isFloorMapNode(_:) below matches a tapped node
    /// against this list (Eddie, Sept 6: "when you tap the wall map,
    /// let it blow up"), and refreshFloorMapTexture() pushes a freshly
    /// redrawn image (with the red "you are here" dot moved to
    /// wherever currentCell just became) onto every one of them, so
    /// several maps placed around one floor all stay in sync rather
    /// than only the one you happened to build first.
    private let floorMapPlaneNodes: [SCNNode]
    /// This floor's own bounds, computed once here exactly the way
    /// HallwayScene.build(fromMaze:) computes them for the SAME
    /// purpose -- sizing/positioning makeFloorMapTexture's canvas.
    /// Needed here because refreshFloorMapTexture() has to call that
    /// same function again later, with a new playerAt, and can't reach
    /// back into a value HallwayScene only computed for its own
    /// one-time build.
    private let mapMaxRow: Int
    private let mapMaxCol: Int
    /// Drives ContentView's full-screen "blown up" map view -- Eddie,
    /// Sept 6: "when you tap the wall map, let it blow up and show what
    /// we show on the map editor screen... then tap anywhere to shrink
    /// it back to the wall size." Not private(set): ContentView's own
    /// tap-anywhere-to-dismiss gesture on that overlay sets this back
    /// to false directly, same as any other simple UI toggle -- there's
    /// no extra bookkeeping a dedicated close method would need to do.
    @Published var floorMapOverlayVisible = false

    init(cameraNode: SCNNode, scene: SCNScene, cells: Set<GridCoordinate>, cellSize: CGFloat, startCell: GridCoordinate, startFacing: Direction, endCell: GridCoordinate, objects: [GridCoordinate: ObjectKind] = [:], objectNodes: [GridCoordinate: SCNNode] = [:], destinations: [GridCoordinate: ObjectKind] = [:], destinationNodes: [GridCoordinate: SCNNode] = [:], elevatorLeftDoor: SCNNode? = nil, elevatorRightDoor: SCNNode? = nil, elevatorMountDirection: Direction? = nil, exitSignNodes: [GridCoordinate: SCNNode] = [:], exitSigns: [GridCoordinate: Direction] = [:], floorMaps: [GridCoordinate: Direction] = [:], floorMapPlaneNodes: [SCNNode] = []) {
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
        self.objectKinds = objects
        self.objectNodes = objectNodes
        self.destinationKinds = destinations
        self.destinationNodes = destinationNodes
        self.destinationClosedPositions = destinationNodes.mapValues { $0.position }
        self.elevatorLeftDoor = elevatorLeftDoor
        self.elevatorRightDoor = elevatorRightDoor
        self.elevatorMountDirection = elevatorMountDirection
        self.elevatorLeftClosedPosition = elevatorLeftDoor?.position
        self.elevatorRightClosedPosition = elevatorRightDoor?.position
        self.exitSignNodes = exitSignNodes
        self.exitSignDirections = exitSigns
        self.floorMapCoords = Set(floorMaps.keys)
        self.floorMapPlaneNodes = floorMapPlaneNodes
        self.mapMaxRow = cells.map { $0.row }.max() ?? 0
        self.mapMaxCol = cells.map { $0.col }.max() ?? 0
        exitSignNodes.values.forEach { $0.isHidden = true }

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
        // didSet never fires for an initializer's own first assignment
        // to currentCell above, so this covers the (rare, but real)
        // case where startCell itself happens to be an Exit Sign cell.
        updateExitSignHighlight()
    }

    /// Shows whichever Exit Sign sits at currentCell (bright/enlarged
    /// "neon" look) and hides everything else, including whichever
    /// sign was showing a moment ago. Round 6 (Eddie, Sept 5): a dim
    /// sign left visible down the hallway read as if it might belong
    /// to whichever box the player was CURRENTLY standing in, even
    /// when that box had no sign of its own -- confusing with sparse,
    /// manually-placed signs where most boxes have none at all. Fully
    /// hiding every sign except the current cell's own removes that
    /// ambiguity: seeing a sign at all now means it's telling YOU
    /// something, full stop.
    private func updateExitSignHighlight() {
        if let previous = neonExitSignCell, previous != currentCell {
            setExitSignNeon(at: previous, neon: false)
        }
        if exitSignNodes[currentCell] != nil {
            setExitSignNeon(at: currentCell, neon: true)
            neonExitSignCell = currentCell
        } else {
            neonExitSignCell = nil
        }
    }

    /// Turns a sign's fixed compass direction into the glyph that's
    /// actually correct for THIS arrival. Eddie, Sept 5, round 9: "it
    /// should be pointing right, not left" -- the old label was picked
    /// from the sign's compass direction alone ("west" always rendered
    /// "< EXIT"), which is only correct if you always arrive facing
    /// north. Comparing against the player's actual current `facing`
    /// with the same left/right vocabulary the D-pad itself uses makes
    /// "turn left"/"turn right"/"straight ahead" mean what they say
    /// from wherever the player is actually standing.
    private static func relativeExitLabel(pointing direction: Direction, facing: Direction) -> String {
        if direction == facing {
            return "EXIT ^"
        } else if direction == facing.left {
            return "< EXIT"
        } else if direction == facing.right {
            return "EXIT >"
        } else {
            // Sign points back the way we came -- shouldn't normally
            // happen (an Exit Sign sits on an open side, and we just
            // walked in through one), but "^" is the least-wrong
            // fallback if it ever does.
            return "EXIT ^"
        }
    }

    private func setExitSignNeon(at coord: GridCoordinate, neon: Bool) {
        guard let sign = exitSignNodes[coord],
              let textNode = sign.childNodes.first,
              let text = textNode.geometry as? SCNText,
              let material = text.firstMaterial else { return }
        sign.isHidden = !neon
        if neon, let direction = exitSignDirections[coord] {
            // Changing the string moves the bounding box, so pivot and
            // scale both have to be recomputed from it every time --
            // the same math HallwayScene.makeExitSignNode used to set
            // them up the first time, just re-run here on demand.
            text.string = Self.relativeExitLabel(pointing: direction, facing: facing)
        }
        let (minBound, maxBound) = text.boundingBox
        let textWidth = maxBound.x - minBound.x
        let textHeight = maxBound.y - minBound.y
        textNode.pivot = SCNMatrix4MakeTranslation(minBound.x + textWidth / 2, minBound.y + textHeight / 2, 0)
        let baseScale = textHeight > 0 ? Float(cellSize * HallwayScene.exitSignBaseSizeFactor) / textHeight : 1
        if neon {
            material.diffuse.contents = HallwayScene.exitSignNeonDiffuse
            material.emission.contents = HallwayScene.exitSignNeonEmission
            let m = HallwayScene.exitSignNeonScaleMultiplier
            textNode.scale = SCNVector3(baseScale * m, baseScale * m, baseScale * m)
        } else {
            material.diffuse.contents = HallwayScene.exitSignDimDiffuse
            material.emission.contents = HallwayScene.exitSignDimEmission
            textNode.scale = SCNVector3(baseScale, baseScale, baseScale)
        }
    }

    private func worldPosition(for coord: GridCoordinate) -> SCNVector3 {
        SCNVector3(Float(coord.col) * Float(cellSize), eyeHeight, Float(coord.row) * Float(cellSize))
    }

    /// Rotate in place to face a new compass direction — the left/right
    /// D-pad buttons. Pure pivot, no movement, and doesn't touch
    /// currentCell/history at all.
    func rotate(toward direction: Direction) {
        guard canRotate, direction != facing else {
            navLog("rotate(toward: \(direction)) ignored -- canRotate=\(canRotate), facing=\(facing)")
            return
        }
        standaloneRotation = true
        pendingRotationTarget = direction
        phase = .pivot
        segmentProgress = 0
        pivotStartYaw = Double(cameraNode.eulerAngles.y)
        pivotTargetYaw = pivotStartYaw + shortestDelta(from: pivotStartYaw, to: direction.yaw)
        isAnimating = true
        navLog("rotate(toward: \(direction)) started from facing=\(facing)")
    }

    /// Begins a drag-controlled turn (a pan gesture, not a button tap):
    /// the finger now drives the camera's yaw directly until it lifts.
    /// Refuses if a walk/rotate/another drag is already in progress.
    func beginDragRotate() {
        guard canRotate else {
            navLog("beginDragRotate() ignored -- canRotate=false")
            return
        }
        dragBaseYaw = Double(cameraNode.eulerAngles.y)
        isDragRotating = true
        navLog("beginDragRotate() started")
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
        navLog("endDragRotate(fraction: \(String(format: "%.2f", fraction))) committing=\(committing) target=\(target)")

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
        guard canGoForward else {
            navLog("advance() ignored -- canGoForward=false (isAnimating=\(isAnimating), isDragRotating=\(isDragRotating), elevatorInUse=\(elevatorInUse), facing=\(facing), open=\(openDirections))")
            return
        }

        let (steps, outcome) = walkToNextDecision(from: currentCell, heading: facing, cells: cells, end: endCell)
        guard !steps.isEmpty else {
            navLog("advance() from \(currentCell) facing \(facing) produced zero steps")
            return
        }

        // If this run would sweep past an uncollected object's cell, an
        // unopened chute, or an unseen floor map without that being the
        // natural end of the run anyway (a fork, forced turn, dead end,
        // or the target), truncate right there instead -- same "hand
        // control back" treatment as a fork or forced turn, so none of
        // these ever get silently swept past mid-glide with no chance
        // to stop and act. This kind of awareness lives here, not in
        // walkToNextDecision, which only knows maze topology, never
        // objects/destinations/maps. Eddie: "yes. have it stop," Sept 5
        // (objects); "stop whether you have trash or not" and "stop
        // when we hit a box with a map," also Sept 5 (chutes/maps --
        // chutes used to only stop when `!collectedObjects.isEmpty`,
        // which is exactly why an empty-handed pass used to just walk
        // by with no chance to even find out there was nothing to
        // deliver).
        var runSteps = steps
        var runOutcome = outcome
        if let stopIndex = steps.firstIndex(where: { step in
            let coord = step.cell
            if let kind = objectKinds[coord], kind.cashValue == nil, !collectedCoords.contains(coord) {
                return true // would pick up something you have to carry -- worth stopping for
            }
            if destinationKinds[coord] != nil, !deliveredCoords.contains(coord) {
                return true // an unopened chute -- worth stopping for whether or not you're carrying anything, so there's always a chance to tap the door
            }
            if floorMapCoords.contains(coord), !viewedFloorMapCoords.contains(coord) {
                return true // a "You Are Here" map you haven't stood in front of yet
            }
            return false
        }), stopIndex < steps.count - 1 {
            runSteps = Array(steps[0...stopIndex])
            let stopCoord = runSteps.last!.cell
            if let kind = objectKinds[stopCoord], kind.cashValue == nil, !collectedCoords.contains(stopCoord) {
                runOutcome = .pickedUpObject
            } else if destinationKinds[stopCoord] != nil, !deliveredCoords.contains(stopCoord) {
                runOutcome = .delivered
            } else {
                runOutcome = .viewedMap
            }
        }

        let stepList = runSteps.map { "\($0.cell) via \($0.heading)" }.joined(separator: ", ")
        navLog("advance() from \(currentCell) facing \(facing) queued \(runSteps.count) step(s): [\(stepList)] outcome=\(runOutcome)")

        animationSteps = runSteps
        animationIndex = 0
        pendingOutcome = runOutcome
        // Every queued step shares the heading you're already facing --
        // walkToNextDecision only ever continues past the first step on
        // a dead-straight pass-through (a forced turn or fork always
        // ends the queue there) -- so the whole run is one continuous
        // glide, never a mid-walk pivot. segmentTarget is the FINAL
        // cell of the run, not just the next one, so easing only slows
        // down at the true start/end instead of resetting to a
        // standstill at every cell boundary in between. Per-cell
        // arrival (position/facing/pickup/logging) still fires exactly
        // when the glide visually crosses each boundary -- see the
        // .translate case below. Eddie: "smooth the whole way," Sept 5.
        segmentStart = cameraNode.position
        segmentTarget = worldPosition(for: runSteps.last!.cell)
        segmentProgress = 0
        phase = .translate
        isAnimating = true
    }

    /// Snap straight back to the start, fully stopped. Wired to the same
    /// on-screen Reset button as the free-roam prototype. Also undoes
    /// every pickup made this run: each collected node goes back into
    /// the scene at its original position (safe because HallwayScene
    /// builds every object as a direct child of a root node with an
    /// identity transform, so re-adding straight to scene.rootNode lands
    /// it exactly where it started) and the collected-so-far bookkeeping
    /// clears, so Reset genuinely restarts the floor rather than leaving
    /// already-gobbled objects permanently missing.
    func reset() {
        isAnimating = false
        isDragRotating = false
        transientMessage = nil
        currentCell = startCell
        facing = startFacing
        phase = .translate
        lastTime = 0
        standaloneRotation = false
        cameraNode.position = worldPosition(for: startCell)
        cameraNode.eulerAngles = SCNVector3(0, Float(startFacing.yaw), 0)

        if !collectedCoords.isEmpty {
            navLog("reset() restoring \(collectedCoords.count) collected object(s)")
            for coord in collectedCoords {
                if let node = objectNodes[coord] {
                    scene?.rootNode.addChildNode(node)
                }
            }
            collectedCoords.removeAll()
            collectedObjects.removeAll()
        }

        if !deliveredCoords.isEmpty {
            navLog("reset() re-closing \(deliveredCoords.count) delivered destination(s)")
            for coord in deliveredCoords {
                destinationNodes[coord]?.removeAllActions()
                if let closed = destinationClosedPositions[coord] {
                    destinationNodes[coord]?.position = closed
                }
            }
            deliveredCoords.removeAll()
        }

        if !viewedFloorMapCoords.isEmpty {
            navLog("reset() forgetting \(viewedFloorMapCoords.count) viewed floor map(s)")
            viewedFloorMapCoords.removeAll()
        }

        if elevatorInUse {
            navLog("reset() snapping elevator doors shut mid-animation")
            elevatorLeftDoor?.removeAllActions()
            elevatorRightDoor?.removeAllActions()
            if let closed = elevatorLeftClosedPosition {
                elevatorLeftDoor?.position = closed
            }
            if let closed = elevatorRightClosedPosition {
                elevatorRightDoor?.position = closed
            }
            elevatorInUse = false
        }
    }

    /// Called whenever a walk lands on a cell -- both mid-walk and on the
    /// final step. If that cell has an object that hasn't been picked up
    /// yet, this is the pick-up moment: hide the node, record it as
    /// collected (for both the "already got this one" check and the HUD
    /// strip in ContentView), and fire an immediate confirmation haptic.
    /// This is also the exact spot a pickup sound effect will play once
    /// there are sound assets to play -- deliberately left as a plain
    /// comment rather than a stub, since there's nothing meaningful to
    /// call yet.
    private func collectObjectIfPresent(at coord: GridCoordinate) {
        guard let kind = objectKinds[coord], !collectedCoords.contains(coord) else { return }
        collectedCoords.insert(coord)
        objectNodes[coord]?.removeFromParentNode()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let value = kind.cashValue {
            // Cash: instant absorb, straight into the running total,
            // never added to the carried list -- no HUD strip icon, no
            // elevator gate, nothing left to deliver.
            navLog("collected cash $\(value) at \(coord)")
            onCollectCash?(value)
        } else {
            collectedObjects.append(kind)
            navLog("collected \(kind) at \(coord) -- total carried: \(collectedObjects.count)")
        }
        // TODO(sound): play a pickup sound effect here once Eddie has
        // sound assets in the project (a distinct "cha-ching" for
        // cash vs. whatever trash gets).
    }

    /// Called alongside collectObjectIfPresent at every cell a walk
    /// actually arrives at (mid-run and final step both) -- marks a
    /// floor-map cell as seen once you've genuinely stood in front of
    /// it, not just when advance() decided to stop there. Doing it here
    /// rather than inline in advance()'s truncation scan means hitting
    /// Reset mid-walk can never mark a map "viewed" that the walk was
    /// only ever queued to reach, never actually did.
    ///
    /// Eddie, Sept 6: "it just blows by maps on the wall. can you make
    /// it stop" -- advance()'s truncation scan (see its own comment)
    /// already DOES stop the walk dead at an unviewed map's cell, same
    /// mechanism that stops it at an uncollected object or an unopened
    /// chute. The difference is those two have something visible happen
    /// right after the stop (the object disappears into the HUD, the
    /// chute's door slides up, or -- empty-handed -- a message says so)
    /// -- a floor map had nothing: the walk genuinely halted, but
    /// nothing on screen said so, so a real stop read exactly like no
    /// stop at all. Same fix as the chute's empty-handed case: a
    /// transientMessage the instant this cell is newly marked viewed
    /// (guarded so a LATER pass through an already-seen map — which
    /// advance() no longer even stops for — doesn't re-show it).
    private func markFloorMapViewedIfPresent(at coord: GridCoordinate) {
        guard floorMapCoords.contains(coord) else { return }
        guard !viewedFloorMapCoords.contains(coord) else { return }
        viewedFloorMapCoords.insert(coord)
        showMessage("You check the wall map")
    }

    /// Maps a hit-tested SceneKit node back to the destination cell it
    /// belongs to, if any -- lets ContentView's Coordinator tell "tapped
    /// the steel door" apart from "tapped anywhere else, just walk
    /// forward" without this controller needing to know anything about
    /// gestures or hit-testing itself.
    func destinationCoordinate(for node: SCNNode) -> GridCoordinate? {
        destinationNodes.first(where: { $0.value === node })?.key
    }

    /// The ONLY way a destination door actually opens now -- a real tap
    /// on the shutter, and only when `coord` is the cell you're
    /// physically standing in right now (a door glimpsed further down
    /// the hall does nothing if tapped). Eddie, Sept 5: "i think it
    /// should wait for you to tap the steel door before it slides up."
    /// Arriving at any unopened chute still stops the walk there (see
    /// advance()'s truncation scan), whether or not you're carrying
    /// anything, so there's always something to tap -- it just no
    /// longer opens itself, and now tells you plainly if there was
    /// never anything to deposit (see depositIfPresent's own comment).
    func openDestinationDoor(at coord: GridCoordinate) {
        guard coord == currentCell else { return }
        depositIfPresent(at: coord)
    }

    /// Lets ContentView's Coordinator tell "tapped one of the
    /// elevator's 2 door panels" apart from "tapped anywhere else,
    /// just walk forward" -- same idea as destinationCoordinate(for:),
    /// just a plain membership check since there's only ever one
    /// elevator per floor rather than a dictionary of them.
    func isElevatorDoor(_ node: SCNNode) -> Bool {
        node === elevatorLeftDoor || node === elevatorRightDoor
    }

    /// Lets ContentView's Coordinator tell "tapped one of the wall-
    /// mounted 'You Are Here' map pictures" apart from "tapped anywhere
    /// else, just walk forward" -- same membership-check idea as
    /// isElevatorDoor above, just against every plane rather than a
    /// fixed pair, since a floor can have more than one map placed on
    /// it. Eddie, Sept 6: "when you tap the wall map, let it blow up."
    func isFloorMapNode(_ node: SCNNode) -> Bool {
        floorMapPlaneNodes.contains(where: { $0 === node })
    }

    /// Redraws the "You Are Here" wall map's texture with the red
    /// player dot moved to wherever currentCell just became, and pushes
    /// it onto every placed map plane on this floor at once (there can
    /// be more than one, all showing the same layout). Called from
    /// currentCell's own didSet, so this stays correct through every
    /// way that value can change -- walking, Reset, arriving via the
    /// elevator -- without each of those needing its own explicit
    /// refresh call. A no-op cost-wise on a floor with no maps placed
    /// at all (floorMapPlaneNodes empty, nothing to loop over) beyond
    /// the one throwaway image HallwayScene.build(fromMaze:) already
    /// skips generating in that case.
    private func refreshFloorMapTexture() {
        guard !floorMapPlaneNodes.isEmpty else { return }
        let image = HallwayScene.makeFloorMapTexture(cells: cells, end: endCell, maxRow: mapMaxRow, maxCol: mapMaxCol, playerAt: currentCell)
        for plane in floorMapPlaneNodes {
            plane.geometry?.materials.first?.diffuse.contents = image
        }
    }

    /// The elevator's full open -> dwell -> close -> actually-advance
    /// sequence, kicked off by a real tap on either door panel while
    /// standing at the end cell. Doesn't switch floors itself -- that
    /// still happens through onReachedEnd, only called once the doors
    /// have visually closed again, so reaching the next floor reads as
    /// "the doors close behind you" rather than an instant teleport.
    /// Eddie, Sept 5: "the 2 vertical sliding doors that open and
    /// close."
    ///
    /// Used to also require the old `reachedEnd` flag (only ever true
    /// once per run, the FIRST time a walk finished by arriving here)
    /// -- which is exactly why "i tapped them and nothing happened"
    /// (Eddie, Sept 5) on a fresh spawn: start and end are the same
    /// fixed cell now, so you're standing right at the doors before
    /// you've ever "arrived" anywhere by walking. Checking your actual
    /// current position instead means the doors work the instant
    /// you're standing in front of them, spawn included, any time,
    /// exactly the "just another activity" the elevator's supposed to
    /// be now.
    func openElevator() {
        guard currentCell == endCell, !elevatorInUse,
              let leftDoor = elevatorLeftDoor, let rightDoor = elevatorRightDoor,
              let direction = elevatorMountDirection else { return }
        elevatorInUse = true

        // Which world axis the 2 panels actually slide along -- must
        // match HallwayScene's own elevatorPanelWidth (0.8) exactly,
        // since that's the geometry these panels were actually built
        // with; sliding by anything else would either stop short of
        // fully clearing the opening or overshoot past the wall.
        let alongWallX: CGFloat
        let alongWallZ: CGFloat
        switch direction {
        case .north, .south: (alongWallX, alongWallZ) = (1, 0)
        case .east, .west: (alongWallX, alongWallZ) = (0, 1)
        }
        let slide: CGFloat = 0.8

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        navLog("elevator: opening")
        // Slowed down across the board, Sept 5: "slow down the opening
        // and closing of the elevator doors" -- slide duration 0.6->1.3
        // (open and close both) and the open-dwell 0.9->1.6 to stay
        // proportional, so the whole sequence reads more like a real
        // elevator taking its time rather than a quick blip.
        let elevatorSlideDuration: TimeInterval = 1.3
        let elevatorDwell: TimeInterval = 1.6
        let openLeft = SCNAction.moveBy(x: -slide * alongWallX, y: 0, z: -slide * alongWallZ, duration: elevatorSlideDuration)
        let openRight = SCNAction.moveBy(x: slide * alongWallX, y: 0, z: slide * alongWallZ, duration: elevatorSlideDuration)
        openLeft.timingMode = .easeInEaseOut
        openRight.timingMode = .easeInEaseOut
        leftDoor.runAction(openLeft)
        rightDoor.runAction(openRight) {
            // A brief dwell with the doors open (like actually
            // stepping in) before they close again and the floor
            // underneath finally switches. SCNAction completion
            // handlers can fire off the main thread, so everything
            // here goes through a main-thread dispatch.
            DispatchQueue.main.asyncAfter(deadline: .now() + elevatorDwell) {
                navLog("elevator: closing")
                let closeLeft = SCNAction.moveBy(x: slide * alongWallX, y: 0, z: slide * alongWallZ, duration: elevatorSlideDuration)
                let closeRight = SCNAction.moveBy(x: -slide * alongWallX, y: 0, z: -slide * alongWallZ, duration: elevatorSlideDuration)
                closeLeft.timingMode = .easeInEaseOut
                closeRight.timingMode = .easeInEaseOut
                leftDoor.runAction(closeLeft)
                rightDoor.runAction(closeRight) { [weak self] in
                    DispatchQueue.main.async {
                        navLog("elevator: closed -- advancing floor")
                        self?.onReachedEnd?()
                    }
                }
            }
        }
    }

    /// The actual deposit logic, called only from openDestinationDoor
    /// above (a real tap on the door). If this cell holds a destination
    /// that hasn't been opened yet AND you're carrying anything at all,
    /// this is the deposit moment: the shutter slides up (visual
    /// confirmation), the oldest thing you're carrying comes off the
    /// list, and an immediate haptic marks it -- no matching required,
    /// any chute takes any trash. Eddie, Sept 5, on why matching went
    /// away: "let them dump their garbage anywhere. that whole having
    /// to match puts undo stress on the game." Tapping an unopened
    /// chute with NOTHING carried used to just silently do nothing --
    /// same Sept 5 round: "if you have no trash and you try to open it,
    /// you need a message" -- so that case now puts up a transientMessage
    /// instead of quietly staying shut.
    private func depositIfPresent(at coord: GridCoordinate) {
        guard destinationKinds[coord] != nil, !deliveredCoords.contains(coord) else { return }
        guard !collectedObjects.isEmpty else {
            showMessage("You have no trash to throw out")
            return
        }
        let kind = collectedObjects.removeFirst()
        deliveredCoords.insert(coord)
        if let door = destinationNodes[coord] {
            let slideUp = SCNAction.moveBy(x: 0, y: 0.66, z: 0, duration: 0.65) // was 0.7 -- Eddie, Sept 5: slides up too far, wants it ~36px shorter so it slightly overlaps the container instead of clearing it with a gap above
            slideUp.timingMode = .easeInEaseOut
            door.runAction(slideUp)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        navLog("delivered \(kind) at \(coord) -- still carrying: \(collectedObjects.count)")
        // TODO(sound): play a "delivered" sound effect here once Eddie
        // has sound assets in the project.
    }

    /// Puts a short status line up on screen -- see transientMessage's
    /// own doc comment for the full "how does this ever go away" story.
    /// Only ever called from spots that already know a real event just
    /// happened (right now: tapping an empty chute); not a generic
    /// logging hook.
    private func showMessage(_ text: String) {
        transientMessage = text
        navLog("message: \(text)")
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
                    self?.updateExitSignHighlight()
                    navLog("rotate complete -- now facing \(newFacing)")
                }
                return
            }

            phase = .translate
            segmentProgress = 0

        case .translate:
            // One continuous glide across the WHOLE queued run (set up
            // in advance()), not a series of per-cell segments --
            // duration scales with the full run length, so easing only
            // slows down at the true start/end of the run instead of
            // resetting to a standstill at every cell boundary along
            // the way. Eddie: "smooth the whole way," Sept 5.
            let segmentDuration = Double(cellSize) * Double(animationSteps.count) / travelSpeed
            segmentProgress += dt / max(segmentDuration, 0.001)
            let t = min(1.0, segmentProgress)
            let eased = t * t * (3 - 2 * t) // smoothstep — gentle start/stop for the whole run

            cameraNode.position = SCNVector3(
                segmentStart.x + Float(eased) * (segmentTarget.x - segmentStart.x),
                eyeHeight,
                segmentStart.z + Float(eased) * (segmentTarget.z - segmentStart.z)
            )

            // Fire each cell's arrival side effects (position/facing
            // bookkeeping, pickup, logging) the moment the continuous
            // glide visually crosses that cell's boundary. `eased` IS
            // the fraction of the whole run's distance covered so far
            // (position above is a straight lerp on it), so this stays
            // correct regardless of frame rate -- the while loop catches
            // up if one slow frame crosses more than one cell boundary.
            while animationIndex < animationSteps.count,
                  eased >= Double(animationIndex + 1) / Double(animationSteps.count) {
                let step = animationSteps[animationIndex]
                let newCell = step.cell
                let newFacing = step.heading
                let isFinalStep = animationIndex == animationSteps.count - 1
                animationIndex += 1

                if !isFinalStep {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        // facing before currentCell -- see round-9 note
                        // above setExitSignNeon's relative-label logic.
                        self.facing = newFacing
                        self.currentCell = newCell
                        self.collectObjectIfPresent(at: newCell)
                        self.markFloorMapViewedIfPresent(at: newCell)
                        navLog("arrived at \(newCell) facing \(newFacing) -- mid-run")
                    }
                } else {
                    let outcome = pendingOutcome
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.isAnimating = false
                        // facing before currentCell -- see round-9 note
                        // above setExitSignNeon's relative-label logic.
                        self.facing = newFacing
                        self.currentCell = newCell
                        self.collectObjectIfPresent(at: newCell)
                        self.markFloorMapViewedIfPresent(at: newCell)
                        navLog("walk finished at \(newCell) facing \(newFacing), outcome=\(outcome)")
                        // .reachedEnd used to also flip a published
                        // `reachedEnd` flag here -- gone along with the
                        // flag itself (see canGoForward/canRotate and
                        // openElevator()'s own comments): the outcome
                        // still does its real job of stopping the walk
                        // AT the elevator's cell instead of sweeping
                        // past it (that's walkToNextDecision's doing,
                        // untouched), there's just nothing left to set
                        // once it gets here.
                    }
                }
            }

            guard t >= 1.0 else { return }
            cameraNode.position = segmentTarget
        }
    }
}
