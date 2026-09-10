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
    private weak var ambientLight: SCNLight?
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
    /// Fired alongside SoundEffects.playTrashPickup() below -- purely
    /// for ContentView's temporary visual feedback (Eddie, Sept 9).
    /// Not used for scoring or state; MazeStore.markTrashPickup() just
    /// records the event for the onChange to pick up.
    var onCollectTrash: (() -> Void)?
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
    /// Which ObjectKind completes THIS floor's mission, or nil for a
    /// floor with no mission gate at all -- see isMissionComplete's own
    /// doc comment for the full completion rule. Floor 1 sets this to
    /// .trashCan (Eddie, Sept 7: "since we already have the trash
    /// pretty much in there, lets make it the first floors mission").
    private let missionObjectKind: ObjectKind?
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
    @Published private(set) var carriedMail: [CarriedRoomItem] = []
    private let roomDoors: [GridCoordinate: RoomDoorPlacement]
    private let itemRooms: [GridCoordinate: Int]
    private var deliveredMail: Set<GridCoordinate> = []

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
    /// Lock navigation during an open/drop/close cycle; reset invalidates
    /// callbacks from the old cycle. Chutes remain reusable afterward.
    @Published private(set) var chuteInUse = false
    private var chuteRunID = UUID()
    private var elevatorWarningNode: SCNNode?

    /// The elevator's 2 door panels and which wall they're mounted on
    /// -- all nil for the empty-maze fallback prototype and for a
    /// floor so small its start and end cells are the same (nothing to
    /// reach). Unlike destinations, there's only ever ONE elevator per
    /// floor, so no coordinate-keyed dictionary is needed.
    private let elevatorLeftDoor: SCNNode?
    private let elevatorRightDoor: SCNNode?
    private let elevatorMountDirection: Direction?
    /// The ride's floor-indicator row, Sept 7 -- Eddie: "we have the
    /// buttons on the wall, and the button thats lit up is the next
    /// floor above us." Redesigned the same day, after actually
    /// watching it play out, into "just a small row of numbers along
    /// the top" -- one digit per floor, lit for whichever floor is
    /// current or the ride's destination. Comes straight from
    /// HallwayScene's addElevatorDoor, empty for the same floors
    /// elevatorLeftDoor etc are nil for.
    private let elevatorButtonNodes: [Int: SCNNode]
    /// This floor's own number and which floor riding the elevator
    /// leads to -- mazeIDs double as floor numbers (see MazeStore's
    /// floorCount), so these are just mazeStore.currentMazeID/
    /// nextMazeID at the moment this controller got built.
    private let floorNumber: Int
    private let nextFloorNumber: Int?
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
    var canGoForward: Bool { !isAnimating && !isDragRotating && !elevatorInUse && !chuteInUse && openDirections.contains(facing) }
    var canRotate: Bool { !isAnimating && !isDragRotating && !elevatorInUse && !chuteInUse }

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

    /// Every cell the (one, fixed) Floor Mission sign is mounted at --
    /// same role as floorMapCoords just above, except there's only
    /// ever one entry now that MazeStore forces the sign onto its own
    /// fixed missionCoordinate cell. Eddie, Sept 7: "we need to stop at
    /// every wall object... i noticed this with the mission banner."
    private let missionSignCoords: Set<GridCoordinate>
    /// Same "already stood here once, don't force another stop" role
    /// as viewedFloorMapCoords, for the mission sign.
    private var viewedMissionSignCoords: Set<GridCoordinate> = []

    /// Every cell a decorative picture or mirror is mounted at -- same role as
    /// floorMapCoords/missionSignCoords above. Eddie, Sept 9: pictures
    /// are aesthetic only ("nothing that has to be solved - just
    /// looked at"), but still need a forced pause -- "you will have to
    /// force a pause by a picture so we can stop and see it."
    private let pictureCoords: Set<GridCoordinate>

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

    init(cameraNode: SCNNode, scene: SCNScene, cells: Set<GridCoordinate>, cellSize: CGFloat, startCell: GridCoordinate, startFacing: Direction, endCell: GridCoordinate, objects: [GridCoordinate: ObjectKind] = [:], objectNodes: [GridCoordinate: SCNNode] = [:], destinations: [GridCoordinate: ObjectKind] = [:], destinationNodes: [GridCoordinate: SCNNode] = [:], elevatorLeftDoor: SCNNode? = nil, elevatorRightDoor: SCNNode? = nil, elevatorMountDirection: Direction? = nil, elevatorButtonNodes: [Int: SCNNode] = [:], floorNumber: Int = 1, nextFloorNumber: Int? = nil, exitSignNodes: [GridCoordinate: SCNNode] = [:], exitSigns: [GridCoordinate: Direction] = [:], floorMaps: [GridCoordinate: Direction] = [:], floorMapPlaneNodes: [SCNNode] = [], missionSigns: [GridCoordinate: Direction] = [:], pictures: [GridCoordinate: Direction] = [:], mirrors: [GridCoordinate: Direction] = [:], roomDoors: [GridCoordinate: RoomDoorPlacement] = [:], itemRooms: [GridCoordinate: Int] = [:], missionObjectKind: ObjectKind? = nil) {
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
        self.roomDoors = roomDoors
        self.itemRooms = itemRooms
        self.objectKinds = objects
        self.objectNodes = objectNodes
        self.missionObjectKind = missionObjectKind
        self.destinationKinds = destinations
        self.destinationNodes = destinationNodes
        self.destinationClosedPositions = destinationNodes.mapValues { $0.position }
        self.elevatorLeftDoor = elevatorLeftDoor
        self.elevatorRightDoor = elevatorRightDoor
        self.elevatorMountDirection = elevatorMountDirection
        self.elevatorLeftClosedPosition = elevatorLeftDoor?.position
        self.elevatorRightClosedPosition = elevatorRightDoor?.position
        self.elevatorButtonNodes = elevatorButtonNodes
        self.floorNumber = floorNumber
        self.nextFloorNumber = nextFloorNumber
        self.exitSignNodes = exitSignNodes
        self.exitSignDirections = exitSigns
        self.floorMapCoords = Set(floorMaps.keys)
        self.missionSignCoords = Set(missionSigns.keys)
        self.pictureCoords = Set(pictures.keys).union(mirrors.keys)
        self.floorMapPlaneNodes = floorMapPlaneNodes
        self.mapMaxRow = cells.map { $0.row }.max() ?? 0
        self.mapMaxCol = cells.map { $0.col }.max() ?? 0
        exitSignNodes.values.forEach { $0.isHidden = true }

        let foundLight = cameraNode.childNodes.compactMap { $0.light }.first { $0.type == .omni }
        self.headlampLight = foundLight
        // The ambient light lives on the scene root (HallwayScene.build),
        // not the camera -- flat and angle-independent by design, which
        // is exactly why playElevatorRide leans on it below.
        self.ambientLight = scene.rootNode.childNodes.compactMap { $0.light }.first { $0.type == .ambient }
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

    /// One tick of held walking. Use the existing pivot/glide animations;
    /// never queue a walk after the pivot, so releasing cancels continuation.
    func advanceWhileHeld() {
        guard canRotate else { return }
        if canGoForward {
            advance()
            return
        }
        let turns = [facing.left, facing.right].filter { openDirections.contains($0) }
        // A genuine L has the passage behind us plus one side exit.
        // A T has two side exits; a dead end offers only a U-turn.
        guard openDirections.contains(facing.opposite), turns.count == 1 else { return }
        navLog("held walk turning at \(currentCell) from \(facing) toward \(turns[0])")
        rotate(toward: turns[0])
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
            // Cash used to be excluded here on purpose (instant-absorb,
            // keep walking) -- Eddie, Sept 6: grabbing money should
            // pause you in the celebration, same as every other pickup
            // and the wall map/chute, not sweep the payoff past you
            // mid-glide. So this is now genuinely "anything not yet
            // collected," carried or not.
            if let kind = objectKinds[coord], !collectedCoords.contains(coord) {
                return true // would pick up (or absorb, for cash) something new -- worth stopping for
            }
            if destinationKinds[coord] != nil {
                return true // an unopened chute -- worth stopping for whether or not you're carrying anything, so there's always a chance to tap the door
            }
            if floorMapCoords.contains(coord) {
                return true // Stop at wall maps on every pass.
            }
            if missionSignCoords.contains(coord), !viewedMissionSignCoords.contains(coord) {
                return true // the Floor Mission sign, first pass this run
            }
            if roomDoors[coord] != nil { return true }
            if pictureCoords.contains(coord) {
                return true // Stop at pictures and mirrors on every pass, including return trips.
            }
            return false
        }), stopIndex < steps.count - 1 {
            runSteps = Array(steps[0...stopIndex])
            let stopCoord = runSteps.last!.cell
            if let kind = objectKinds[stopCoord], !collectedCoords.contains(stopCoord) {
                runOutcome = .pickedUpObject
            } else if destinationKinds[stopCoord] != nil {
                runOutcome = .delivered
            } else if floorMapCoords.contains(stopCoord) {
                runOutcome = .viewedMap
            } else if missionSignCoords.contains(stopCoord), !viewedMissionSignCoords.contains(stopCoord) {
                runOutcome = .viewedMissionSign
            } else if roomDoors[stopCoord] != nil {
                runOutcome = .viewedRoomDoor
            } else {
                runOutcome = .viewedPicture
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
        // Eddie, Sept 9: "use 'walking.mp3' for normal walking down
        // hallway. so its only when there is forward movement."
        // .translate is entered ONLY from here (reset() also sets it,
        // but straight back to a standstill, no glide) -- every pivot
        // (rotate()/endDragRotate()) always sets standaloneRotation
        // and never falls through to .translate, so this is genuinely
        // forward movement only, never a turn in place.
        SoundEffects.startWalking()
    }

    /// Back up one open cell without turning the camera around.
    func stepBackward() {
        guard canRotate, openDirections.contains(facing.opposite) else { return }
        let delta = facing.opposite.delta
        let target = GridCoordinate(row: currentCell.row + delta.row, col: currentCell.col + delta.col)
        animationSteps = [NavigationStep(cell: target, heading: facing)]
        animationIndex = 0
        pendingOutcome = target == endCell ? .reachedEnd : .steppedBackward
        segmentStart = cameraNode.position
        segmentTarget = worldPosition(for: target)
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
        SoundEffects.stopWalking()
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

        carriedMail.removeAll()
        deliveredMail.removeAll()
        chuteRunID = UUID()
        chuteInUse = false
        elevatorWarningNode?.removeFromParentNode()
        elevatorWarningNode = nil
        for (coord, door) in destinationNodes {
            door.removeAllActions()
            if let closed = destinationClosedPositions[coord] { door.position = closed }
            if let interior = door.parent?.childNode(withName: "chuteInterior", recursively: false) {
                interior.childNodes.filter { $0.name == "fallingDelivery" }.forEach {
                    $0.removeAllActions()
                    $0.removeFromParentNode()
                }
            }
        }

        if !viewedFloorMapCoords.isEmpty {
            navLog("reset() forgetting \(viewedFloorMapCoords.count) viewed floor map(s)")
            viewedFloorMapCoords.removeAll()
        }

        if !viewedMissionSignCoords.isEmpty {
            navLog("reset() forgetting \(viewedMissionSignCoords.count) viewed mission sign(s)")
            viewedMissionSignCoords.removeAll()
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
            cameraNode.removeAllActions()
            // Snap the floor-indicator row back to resting: this
            // floor's own digit lit, every other floor (including
            // whatever got lit mid-ride as the next stop) dimmed.
            let litColor = UIColor(red: 1.0, green: 0.78, blue: 0.2, alpha: 1)
            elevatorButtonNodes.forEach { floor, node in
                node.geometry?.firstMaterial?.emission.contents = floor == floorNumber ? litColor : UIColor(white: 0.05, alpha: 1)
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
        defer { refreshFloorMapTexture() }
        guard let kind = objectKinds[coord], !collectedCoords.contains(coord) else { return }
        if kind == .envelope {
            guard let room = itemRooms[coord], roomDoors.values.contains(where: { $0.roomNumber == room }) else {
                showMessage("This letter needs a valid room address in the editor.")
                return
            }
            carriedMail.append(CarriedRoomItem(id: coord, roomNumber: room))
            SoundEffects.playMailPickup()
        }
        collectedCoords.insert(coord)
        objectNodes[coord]?.removeFromParentNode()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let value = kind.cashValue {
            // Cash: instant absorb, straight into the running total,
            // never added to the carried list -- no HUD strip icon, no
            // elevator gate, nothing left to deliver.
            navLog("collected cash $\(value) at \(coord)")
            SoundEffects.playCashPickup()
            onCollectCash?(value)
        } else if kind != .envelope {
            collectedObjects.append(kind)
            navLog("collected \(kind) at \(coord) -- total carried: \(collectedObjects.count)")
            // Eddie, Sept 9: enclosed 2 pickup sounds specifically for
            // trash ("a few sounds associated with picking up and
            // throwing out the trash") -- SoundEffects picks randomly
            // between them each call, so a run of several pickups in a
            // row doesn't play the identical sound every time. Other
            // carried kinds (envelope, heart, star, ...) stay silent
            // here for now, same as before -- these 2 assets are
            // trash-specific, not a generic pickup sound.
            if kind == .trashCan {
                SoundEffects.playTrashPickup()
                onCollectTrash?()
            }
        }
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
    /// DOES stop the walk dead at an unviewed map's cell, same
    /// mechanism that stops it at an uncollected object or an unopened
    /// chute. Originally paired with a transientMessage ("You check
    /// the wall map") the instant a cell was newly marked viewed, same
    /// pattern as the chute's empty-handed case -- since removed
    /// (Eddie, Sept 6: "get rid of the 'You check the wall map'") now
    /// that tapping the map itself blows it up full-screen, which is
    /// its own unmistakable feedback that something happened; the text
    /// line was redundant with that, or beat it there and then felt
    /// like a non sequitur once the map didn't actually open. Still
    /// tracks viewedFloorMapCoords -- that set is what advance()'s scan
    /// above checks to decide whether THIS map still needs to force a
    /// stop, independent of whatever feedback (if any) accompanies it.
    private func markFloorMapViewedIfPresent(at coord: GridCoordinate) {
        guard floorMapCoords.contains(coord) else { return }
        guard !viewedFloorMapCoords.contains(coord) else { return }
        viewedFloorMapCoords.insert(coord)
    }

    /// Same shape as markFloorMapViewedIfPresent, for the Floor Mission
    /// sign.
    private func markMissionSignViewedIfPresent(at coord: GridCoordinate) {
        guard missionSignCoords.contains(coord) else { return }
        guard !viewedMissionSignCoords.contains(coord) else { return }
        viewedMissionSignCoords.insert(coord)
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
        guard coord == currentCell, !isAnimating, !isDragRotating, !chuteInUse, !elevatorInUse else { return }
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
    func pinchForward() {
        guard canRotate else { return }
        if currentCell == endCell, facing == elevatorMountDirection {
            openElevator()
        } else {
            advance()
        }
    }

    func roomDoorCoordinate(for node: SCNNode) -> GridCoordinate? {
        var candidate: SCNNode? = node
        while let current = candidate {
            if let name = current.name, name.hasPrefix("roomDoor_"),
               let number = Int(name.dropFirst("roomDoor_".count)) {
                return roomDoors.first { $0.value.roomNumber == number }?.key
            }
            candidate = current.parent
        }
        return nil
    }

    func deliverMail(at coord: GridCoordinate) {
        guard canRotate, coord == currentCell, let door = roomDoors[coord], facing == door.direction else { return }
        let matching = carriedMail.filter { $0.roomNumber == door.roomNumber }
        guard !matching.isEmpty else {
            showMessage("No mail for Room \(door.roomNumber).")
            return
        }
        let ids = Set(matching.map(\.id))
        carriedMail.removeAll { ids.contains($0.id) }
        deliveredMail.formUnion(ids)
        SoundEffects.playMailDelivery()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage(isMissionComplete ? "All mail delivered! Return to the elevator." : "Delivered to Room \(door.roomNumber).")
        if let roomNode = scene?.rootNode.childNode(withName: "roomDoor_\(door.roomNumber)", recursively: true) {
            let letter = HallwayScene.makeEnvelopeNode(roomNumber: door.roomNumber, width: 0.28, spinning: false)
            letter.position = SCNVector3(0, 1.05, 0.65)
            roomNode.addChildNode(letter)
            letter.runAction(.sequence([
                .group([.move(to: SCNVector3(0, 1.05, 0.1), duration: 0.65), .customAction(duration: 0.65) { node, elapsed in node.scale.y = 1 - Float(elapsed / 0.65) * 0.9 }]),
                .fadeOut(duration: 0.1), .removeFromParentNode()
            ]))
        }
        refreshFloorMapTexture()
    }

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
        let missionItemCells = objectKinds.filter { $0.value == missionObjectKind && !collectedCoords.contains($0.key) }.map { $0.key }
        let missionDestinationCells = destinationKinds.filter { $0.value == missionObjectKind }.map { $0.key }
        let image = HallwayScene.makeFloorMapTexture(cells: cells, end: endCell, maxRow: mapMaxRow, maxCol: mapMaxCol, playerAt: currentCell, missionItemCells: missionItemCells, missionDestinationCells: missionDestinationCells, roomDoors: roomDoors, itemRooms: itemRooms)
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
    /// True when this floor either has no mission set at all
    /// (missionObjectKind is nil -- every floor until missions are
    /// actually authored) or every object of that kind has been both
    /// picked up AND delivered. "Delivered" specifically means gone
    /// from collectedObjects (the live FIFO carry queue), not merely
    /// picked up -- since nothing enforces a carry limit
    /// (collectObjectIfPresent's collectedObjects.append(kind) is
    /// unconditional), a kind sitting in collectedCoords but STILL
    /// present in collectedObjects means it's been picked up but not
    /// yet dropped in a chute, so the mission isn't done. Eddie, Sept
    /// 7: "you have to do that in order for the elevator to let you
    /// get in and go to the next floor."
    var isMissionComplete: Bool {
        guard let kind = missionObjectKind else { return true }
        let requiredCoords = objectKinds.filter { $0.value == kind }.keys
        if kind == .envelope { return requiredCoords.allSatisfy { deliveredMail.contains($0) } }
        guard requiredCoords.allSatisfy({ collectedCoords.contains($0) }) else { return false }
        return !collectedObjects.contains(kind)
    }

    /// Fired the instant openElevator() rejects a tap because
    /// isMissionComplete is false -- ContentView's ElevatorAlarmOverlay
    /// watches this (not transientMessage, which only a nested
    /// @ObservedObject view ever sees anyway) to strobe the whole
    /// screen red. Carries its own id so two rejections in a row (Eddie
    /// tapping the doors twice while still short) still count as two
    /// distinct events, same reason MazeStore.CashPickupEvent does.
    struct ElevatorRejectionEvent: Equatable {
        let id = UUID()
    }
    @Published private(set) var elevatorRejected: ElevatorRejectionEvent?

    /// One "the ride is done, swap the floor now" event -- watched by
    /// ContentView's ElevatorCurtainOverlay, which shows itself already
    /// fully closed (a seamless continuation of the just-closed 3D
    /// doors) the instant this fires, then slides open a beat later
    /// once the actual floor swap (called right alongside this, see
    /// playElevatorRide) has settled in behind it. Same "own id so two
    /// in a row still count as two events" shape as every other event
    /// on this controller.
    struct FloorTransitionEvent: Equatable {
        let id = UUID()
    }
    @Published private(set) var floorTransitionRequested: FloorTransitionEvent?

    func openElevator() {
        guard currentCell == endCell, !elevatorInUse, !chuteInUse,
              let leftDoor = elevatorLeftDoor, let rightDoor = elevatorRightDoor,
              let direction = elevatorMountDirection else { return }
        guard isMissionComplete else {
            // .error instead of the old .warning -- Eddie, Sept 7:
            // "make them feel shitty." Paired with a siren
            // (SoundEffects.playAlarm) and a full-screen red strobe
            // (elevatorRejected, watched by ElevatorAlarmOverlay) --
            // the gray transientMessage capsule stays too, so there's
            // still a plain-English reason on screen once the alarm
            // itself settles down.
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showElevatorMissionWarning()
            elevatorRejected = ElevatorRejectionEvent()
            return
        }
        elevatorWarningNode?.removeFromParentNode()
        elevatorWarningNode = nil
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
        // Which way "forward, into the shaft" is -- same (row, col)
        // delta driving every normal walking step (see worldPosition),
        // just used here for a scripted dolly instead of a tapped one.
        let forwardX = CGFloat(direction.delta.col)
        let forwardZ = CGFloat(direction.delta.row)
        let slide: CGFloat = 0.8

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        navLog("elevator: opening")
        // Slowed down across the board, Sept 5: "slow down the opening
        // and closing of the elevator doors" -- slide duration 0.6->1.3
        // (open and close both) and the open-dwell 0.9->1.6 to stay
        // proportional, so the whole sequence reads more like a real
        // elevator taking its time rather than a quick blip.
        let elevatorSlideDuration: TimeInterval = 1.6
        let elevatorDwell: TimeInterval = 2.0
        let openLeft = SCNAction.moveBy(x: -slide * alongWallX, y: 0, z: -slide * alongWallZ, duration: elevatorSlideDuration)
        let openRight = SCNAction.moveBy(x: slide * alongWallX, y: 0, z: slide * alongWallZ, duration: elevatorSlideDuration)
        openLeft.timingMode = .easeInEaseOut
        openRight.timingMode = .easeInEaseOut
        SoundEffects.playElevatorArrival()
        let arrivalDelay = SoundEffects.elevatorDoorOpeningDelay
        leftDoor.runAction(.sequence([.wait(duration: arrivalDelay), openLeft]))
        rightDoor.runAction(.sequence([.wait(duration: arrivalDelay), openRight])) { [weak self] in
            // Eddie, Sept 7: "you step into the elevator, then the box
            // youre in automatically spins 180 degrees in your view...
            // then the animation showing the floor change, then the
            // doors open" -- no player input at all, purely scripted
            // ("why burden them with another cmd for a benefit thats
            // so tiny"). Only plays when there's actually a next floor
            // AND its panel got built; an unlinked last floor falls
            // back to the original plain open/dwell/close below, same
            // as before this ride existed, since there's nowhere to go.
            guard let self else { return }
            if let next = self.nextFloorNumber,
               let targetButton = self.elevatorButtonNodes[next] {
                DispatchQueue.main.async {
                    self.playElevatorRide(leftDoor: leftDoor, rightDoor: rightDoor, alongWallX: alongWallX, alongWallZ: alongWallZ, forwardX: forwardX, forwardZ: forwardZ, slide: slide, elevatorSlideDuration: elevatorSlideDuration, targetButton: targetButton, next: next)
                }
            } else {
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
    }

    /// The ride itself, Sept 7 -- a step forward into the shaft, an
    /// automatic 180 spin (no player input at all), the same doors
    /// closing now that they're dead ahead again, the panel lighting
    /// up to show which floor's next, and finally a hand-off to
    /// ContentView's screen-space curtain (floorTransitionRequested)
    /// for the "doors reopening" beat -- the 3D doors/camera/scene
    /// this whole ride just used all get thrown away and rebuilt fresh
    /// the moment the floor actually swaps, so there's no way to keep
    /// animating THIS SAME set of doors reopening across that boundary.
    private func playElevatorRide(leftDoor: SCNNode, rightDoor: SCNNode, alongWallX: CGFloat, alongWallZ: CGFloat, forwardX: CGFloat, forwardZ: CGFloat, slide: CGFloat, elevatorSlideDuration: TimeInterval, targetButton: SCNNode, next: Int) {
        // Eddie, Sept 9: "use elevator-music" -- for the ride itself,
        // not the initial door-open (that's its own one-shot, right
        // above in openElevator()). Stopped explicitly below rather
        // than left to loop/finish on its own, so it never plays on
        // into the next floor once the ride hands off to the curtain.
        SoundEffects.playElevatorMusic()
        // Eddie, Sept 8, after several rounds of tuning individual
        // beats (dolly distance, a separate post-dolly "clear the
        // doorway" nudge, when to close the doors) kept surfacing new
        // side effects of each other: "so that 2nd zoom isnt
        // necessary, and the pivot shows walls it shouldnt... the
        // closed doors should already be there instead of appearing
        // after you finish the 180 pivot." Collapsed back down to the
        // simplest version that can possibly work: ONE dolly, straight
        // to a spot solidly inside the shaft, THEN a pure in-place
        // rotation with no camera movement at all -- nothing left to
        // choreograph around. The doors close during the back-wall
        // dwell, off-screen (you're facing the photo, not them), so
        // by the time the rotation finishes they're already shut and
        // waiting, not popping in afterward.
        //
        // The 1.8 dolly distance is the shaft's own dead center (doors
        // at 1.6, back wall at 2.0) -- the maximum possible clearance
        // from the doorway's open edge in either direction, so the
        // full 180 has that same margin on every side rather than
        // relying on a second, separately-timed step to reach it.
        // Ending this close to the photo also means the doors/frame/
        // handrail (the reflective, physically-based materials) are
        // back inside the headlamp's point-blank blowout radius for
        // the whole dwell, not just the tail end.
        //
        // Eddie, Sept 8, next report: "you can see the pic on the
        // back wall... but a 1/2 sec after the elev doors open, the
        // wall behind the pic turns black for some reason. THEN it
        // zooms." Dimming applied here, at the very top of the
        // function, fires during the 0.5-second pause below, before
        // the dolly has even started moving -- so the very first
        // thing that happens is a static frame going dim for no
        // visible reason, and only after that does the zoom begin.
        // Moved down into the same instant the dolly itself starts
        // (right before runAction(dolly) below) instead, so any
        // change in the shaft's lighting happens as part of the zoom
        // already being in motion, not as its own unexplained beat
        // beforehand.
        let originalHeadlampIntensity = headlampLight?.intensity
        let originalAmbientIntensity = ambientLight?.intensity
        func restoreShaftLighting() {
            if let originalHeadlampIntensity { headlampLight?.intensity = originalHeadlampIntensity }
            if let originalAmbientIntensity { ambientLight?.intensity = originalAmbientIntensity }
        }

        // Eddie, Sept 8: "its still zooming in just as much to
        // that back wall - and all walls as its turning to the
        // doors." 1.8 was dead-center of the OLD 0.4-deep shaft --
        // 1.6 (door plane) + 0.2. HallwayScene's elevatorShaftDepth
        // is now 1.6 (a roughly square car), so dead-center moves
        // out to 1.6 + 0.8 = 2.4 -- same 0.2-margin-on-both-sides
        // rule that avoids the brick-during-pivot bug, just against
        // the new, deeper shaft. This is what actually backs the
        // camera off the photo AND the doors (dead-center means the
        // distance to both is identical) -- resizing the photo
        // itself didn't touch the zoom because the zoom was always
        // about how close the camera's fixed resting spot was.
        let dollyDistance: CGFloat = 2.4
        // 1.73s instead of the old 1.3s -- same travel speed as before
        // (distance grew from 1.8 to 2.4 along with the deeper shaft;
        // duration grows with it so the dolly still feels like the
        // same motion, not a rushed longer trip).
        let dolly = SCNAction.move(by: SCNVector3(Float(forwardX * dollyDistance), 0, Float(forwardZ * dollyDistance)), duration: 1.73)
        dolly.timingMode = .easeInEaseOut
        let rotate = SCNAction.rotateBy(x: 0, y: .pi, z: 0, duration: 1.3)
        rotate.timingMode = .easeInEaseOut

        func closeDoorsNow() {
            navLog("elevator: closing (ride)")
            // Eddie, Sept 8, looking at the doors-closed frame:
            // "you can totally get rid of the 2 1 (floor numbers)
            // at the top of the elevator... its perfect just with
            // the doors taking the whole screen then opening. get
            // rid of the numbers completely." This was the one
            // call that ever revealed them (HallwayScene still
            // builds the digit nodes, just permanently at opacity
            // 0 now that nothing turns them back on).
            let closeLeft = SCNAction.moveBy(x: slide * alongWallX, y: 0, z: slide * alongWallZ, duration: elevatorSlideDuration)
            let closeRight = SCNAction.moveBy(x: -slide * alongWallX, y: 0, z: -slide * alongWallZ, duration: elevatorSlideDuration)
            closeLeft.timingMode = .easeInEaseOut
            closeRight.timingMode = .easeInEaseOut
            leftDoor.runAction(closeLeft)
            rightDoor.runAction(closeRight)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            // Eddie, Sept 8: "just before the backwall zooms in,
            // that back wall turns a really dark gray. whats
            // happening? are you changing the color or is that just
            // a lighting issue?" Lighting, not color -- the panel's
            // own material (makeElevatorShaftMaterial) never changes,
            // only how much light is landing on it. What made it
            // visible as its own beat was the instant, un-animated
            // jump from 30 to 3: a hard cut a viewer's eye catches
            // even at the same moment the dolly starts. Wrapping it
            // in an SCNTransaction ramps it over the same half-
            // second the dolly takes to ease into motion, so it
            // reads as the shaft's lighting settling as the ride
            // begins, not a switch flipping.
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            // Eddie, Sept 8: "a moment before the doors slide
            // open, the elevator doors turn this color - no
            // lighting - and no line between the 2 doors." That's
            // the final closed-doors dwell, right before the
            // curtain (styled to look like the same doors) takes
            // over. The old 3/170 split cut the headlamp to 1/10th
            // of normal while pushing ambient ABOVE the hallway's
            // own normal level (110) -- ambient has no direction,
            // so with the headlamp cut that hard, ambient was
            // providing nearly all the light, and flat/undirected
            // light can't reveal a surface's own shading or the
            // thin shadowed gap between the 2 door panels -- reads
            // as one flat, unlit-looking color. 10/130 keeps the
            // headlamp a real, visible contributor (still well
            // under its normal 30, avoiding the original blowout)
            // while pulling ambient back down closer to normal, so
            // the doors keep some real shading and their seam line
            // even during the dimmed ride. Safe to loosen now that
            // the deeper shaft (elevatorShaftDepth 1.6) also backs
            // the camera 4x further from these doors than when 3/
            // 170 was first tuned.
            self.headlampLight?.intensity = 10
            self.ambientLight?.intensity = 130
            SCNTransaction.commit()
            self.cameraNode.runAction(dolly) { [weak self] in
                guard let self else { return }
                // Doors start closing here, the instant you're facing
                // the back wall -- elevatorSlideDuration (1.6s) fits
                // comfortably inside the 2-second dwell below, so
                // they're done well before the pivot even starts, let
                // alone finishes.
                closeDoorsNow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    self.cameraNode.runAction(rotate) { [weak self] in
                        guard let self else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            guard let self else { return }
                            navLog("elevator: ride done -- requesting floor transition")
                            // Eddie, Sept 8: "i guess you need to
                            // keep tweaking until you nail the same
                            // exact lighting conditions?" Not
                            // tweaking -- a real bug. onReachedEnd
                            // (ContentView's HallwaySceneView) is
                            // what takes the snapshot the curtain
                            // shows, but restoreShaftLighting() was
                            // running BEFORE it, resetting the
                            // headlamp/ambient back to full
                            // brightness first -- so the snapshot
                            // was capturing the doors freshly
                            // RE-LIT, not the dimmed look the
                            // player had just been staring at. That
                            // was the whole difference between the
                            // 2 screenshots: a real, wrong pixel
                            // capture, not a lighting mismatch to
                            // chase down by hand. Snapshot first
                            // (via onReachedEnd), THEN restore --
                            // the scene's about to be torn down for
                            // the next floor regardless, so nothing
                            // else depends on the old order.
                            self.floorTransitionRequested = FloorTransitionEvent()
                            self.onReachedEnd?()
                            SoundEffects.stopElevatorMusic()
                            restoreShaftLighting()
                        }
                    }
                }
            }
        }
    }

    /// Shifts the lit floor-indicator digit from this floor to the
    /// next one -- purely cosmetic, mirrors a real elevator panel
    /// lighting up your destination as you ride. targetButton came
    /// straight from HallwayScene's addElevatorDoor; the current
    /// floor's own digit (already lit at build time) is looked up via
    /// floorNumber and dimmed back down the same way.
    private func lightElevatorPanel(targetButton: SCNNode, next: Int) {
        // Eddie, Sept 8: "the numbers still appear at the top of the
        // back wall. get rid of them." HallwayScene now builds every
        // digit node hidden (opacity 0) so none of them are visible
        // during the step-in/back-wall beat -- this is the one place
        // they need to become visible again, right as the ride turns
        // to face the doors and the current floor's digit is about to
        // hand off to the next one.
        elevatorButtonNodes.values.forEach { $0.opacity = 1 }
        let litColor = UIColor(red: 1.0, green: 0.78, blue: 0.2, alpha: 1)
        elevatorButtonNodes[floorNumber]?.geometry?.firstMaterial?.emission.contents = UIColor(white: 0.05, alpha: 1)
        targetButton.geometry?.firstMaterial?.emission.contents = litColor
    }

    /// Open even when empty, empty the carried load into the shaft, and
    /// close after a 2.5-second dwell. Preserve the existing any-chute rule.
    private func depositIfPresent(at coord: GridCoordinate) {
        guard !chuteInUse, let kind = destinationKinds[coord],
              let door = destinationNodes[coord],
              let closed = destinationClosedPositions[coord],
              let interior = door.parent?.childNode(withName: "chuteInterior", recursively: false),
              let template = interior.childNode(withName: "deliveryTemplate", recursively: false) else { return }
        chuteInUse = true
        chuteRunID = UUID()
        let runID = chuteRunID
        let slideDuration = 0.65
        let openPause = 2.5
        if kind == .trashCan { SoundEffects.playTrashChute() }
        let open = SCNAction.move(to: SCNVector3(closed.x, closed.y + 0.66, closed.z), duration: slideDuration)
        let close = SCNAction.move(to: closed, duration: slideDuration)
        open.timingMode = .easeInEaseOut
        close.timingMode = .easeInEaseOut
        door.runAction(.sequence([
            open,
            .run { [weak self, weak interior, weak template] _ in
                DispatchQueue.main.async {
                    guard let self, self.chuteRunID == runID, let interior, let template else { return }
                    let count = self.collectedObjects.count
                    self.collectedObjects.removeAll()
                    // One opening empties the carried load. Bound visual particles
                    // while still accounting for every delivered item.
                    let visibleCount = min(count, 12)
                    for index in 0..<visibleCount {
                        let item = template.clone()
                        item.name = "fallingDelivery"
                        item.isHidden = false
                        item.opacity = 1
                        item.position.x += Float.random(in: -0.12...0.12)
                        interior.addChildNode(item)
                        let stagger = visibleCount > 1 ? Double(index) * 0.65 / Double(visibleCount - 1) : 0
                        let fall = SCNAction.moveBy(x: 0, y: -4.5, z: -0.12, duration: 1.15)
                        fall.timingMode = .easeIn
                        item.runAction(.sequence([
                            .wait(duration: 0.2 + stagger),
                            .group([fall, .rotateBy(x: 0.4, y: 1.5, z: 0.3, duration: 1.15),
                                    .sequence([.wait(duration: 0.75), .fadeOut(duration: 0.4)])]),
                            .removeFromParentNode()
                        ]))
                    }
                    if count > 0 { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                    navLog("chute opened at \(coord): dropped \(count) \(kind), carried=\(self.collectedObjects.count), missionComplete=\(self.isMissionComplete)")
                    // Basement impact audio can be added when its recording is supplied.
                }
            },
            .wait(duration: openPause),
            .run { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.chuteRunID == runID else { return }
                    if kind == .trashCan { SoundEffects.playTrashChute() }
                }
            },
            close,
            .run { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.chuteRunID == runID else { return }
                    self.chuteInUse = false
                    navLog("chute closed at \(coord); ready to reuse")
                }
            }
        ]), forKey: "chuteCycle")
    }

    /// A lit notice attached to the elevator's world position, not the HUD.
    private func showElevatorMissionWarning() {
        guard let scene, let left = elevatorLeftDoor, let right = elevatorRightDoor,
              let direction = elevatorMountDirection, let kind = missionObjectKind else { return }
        let remaining = objectKinds.filter { $0.value == kind && !collectedCoords.contains($0.key) }.count
        let carried = kind == .envelope ? carriedMail.count : collectedObjects.filter { $0 == kind }.count
        let message = "ELEVATOR LOCKED\n\(kind.missionLegendLabel): \(remaining) left to collect\n\(carried) still to drop off"
        let size = CGSize(width: 900, height: 360)
        let texture = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.22, green: 0.015, blue: 0.01, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemRed.setStroke()
            let border = UIBezierPath(rect: CGRect(x: 8, y: 8, width: 884, height: 344))
            border.lineWidth = 12
            border.stroke()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = 14
            (message as NSString).draw(in: CGRect(x: 28, y: 42, width: 844, height: 290), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 56),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ])
        }
        let material = SCNMaterial()
        material.diffuse.contents = texture
        material.lightingModel = .constant
        let plane = SCNPlane(width: 1.35, height: 0.54)
        plane.materials = [material]
        let notice = SCNNode(geometry: plane)
        notice.position = SCNVector3((left.position.x + right.position.x) / 2 - Float(direction.delta.col) * 0.1,
                                     left.position.y + 0.15,
                                     (left.position.z + right.position.z) / 2 - Float(direction.delta.row) * 0.1)
        notice.eulerAngles = left.eulerAngles
        elevatorWarningNode?.removeFromParentNode()
        elevatorWarningNode = notice
        scene.rootNode.addChildNode(notice)
        notice.runAction(.sequence([
            .repeat(.sequence([.fadeOpacity(to: 0.65, duration: 0.22), .fadeIn(duration: 0.22)]), count: 3),
            .wait(duration: 4), .fadeOut(duration: 0.5), .removeFromParentNode()
        ]))
        navLog("elevator locked: uncollected=\(remaining), carried=\(carried), kind=\(kind)")
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
                        self.markMissionSignViewedIfPresent(at: newCell)
                        navLog("arrived at \(newCell) facing \(newFacing) -- mid-run")
                    }
                } else {
                    let outcome = pendingOutcome
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.isAnimating = false
                        SoundEffects.stopWalking()
                        // facing before currentCell -- see round-9 note
                        // above setExitSignNeon's relative-label logic.
                        self.facing = newFacing
                        self.currentCell = newCell
                        self.collectObjectIfPresent(at: newCell)
                        self.markFloorMapViewedIfPresent(at: newCell)
                        self.markMissionSignViewedIfPresent(at: newCell)
                        navLog("walk finished at \(newCell) facing \(newFacing), outcome=\(outcome)")
                        // Eddie, Sept 6: wanted a cue the moment the
                        // walk locks into an intersection (a real fork
                        // or a forced turn -- .intersection covers
                        // both, see walkToNextDecision). Sound tried
                        // first, then pulled the same day -- it hits
                        // often enough (every fork, every bend) that it
                        // got annoying fast; a haptic alone reads as
                        // "locked in" without wearing out its welcome.
                        // Deliberately NOT fired for .pickedUpObject/
                        // .delivered/.viewedMap even though those also
                        // stop the walk -- those already get their own
                        // haptic elsewhere (collectObjectIfPresent,
                        // depositIfPresent), this is specifically the
                        // "you now have a direction to choose" cue.
                        if case .intersection = outcome {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
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
