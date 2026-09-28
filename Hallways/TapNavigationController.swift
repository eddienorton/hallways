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
    /// Fired (main thread, same as onReachedEnd) INSTEAD of it, at the
    /// exact same scheduled arrival moment, when the player took
    /// camera control during this ride (playerHasTakenElevatorCameraControl).
    /// Carries the camera's exact current yaw (radians) at that instant.
    /// Eddie, Sept 16 (manual elevator exit, 2nd pass): the FIRST
    /// attempt at this deferred the actual floor advance until a
    /// second, separate "tap the doors again" gesture, and reopened
    /// the OLD (about-to-be-abandoned) floor's own doors -- confirmed
    /// broken by physical testing on two counts (the curtain showing
    /// whatever the arbitrary camera was facing instead of real doors,
    /// and "exiting" just walking back into the SAME old floor, since
    /// the destination never actually became real). This callback
    /// fixes both by doing exactly what onReachedEnd does, on the
    /// exact same schedule -- ContentView wires it to advance
    /// mazeStore to the real destination floor immediately, same as
    /// a passive ride, just carrying the preserved yaw along so the
    /// brand-new destination floor's camera can be put back to it
    /// (see TapNavigationController.presentArrivalInsideElevator(preservedYaw:))
    /// instead of the normal default spawn facing. There is no
    /// separate "deferred second half" anymore -- once the destination
    /// floor is loaded, getting out of the elevator is just ordinary
    /// tap/long-press navigation, the same as everywhere else in
    /// Hallways.
    var onElevatorArrivedControlled: ((Double) -> Void)?
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
    /// Positional counterpart of isDragRotating/dragBaseYaw above --
    /// see beginDragMove()'s own comment for the full design. Kept as
    /// entirely separate state (never reuses isDragRotating/dragBaseYaw)
    /// so the two drag modes can never be conflated, and so canGoForward/
    /// canRotate can gate on either independently.
    @Published private(set) var isDragMoving = false
    private var dragMoveFacing: Direction = .north
    private var dragBaseCell = GridCoordinate(row: 0, col: 0)
    private var dragBasePosition = SCNVector3Zero
    // How many consecutive open cells lie ahead/behind dragBaseCell
    // along dragMoveFacing/.opposite -- computed ONCE at beginDragMove(),
    // not just a single adjacent-cell boolean, so a single finger-down
    // gesture can scrub continuously across multiple connected cells
    // (Eddie: "drag forward 3.5 cells, reverse... one continuous
    // positional scrub") instead of stopping dead at the first cell
    // boundary. Real topology (walls/doors) is still the only thing
    // that bounds these -- see openRunLength(from:direction:).
    private var dragMoveMaxForwardCells = 0
    private var dragMoveMaxBackwardCells = 0

    private let startCell: GridCoordinate
    private let startFacing: Direction
    /// The cell you're standing in right now — exposed so the 2D grid
    /// editor can show a "you are here" marker when you jump back to it.
    @Published private(set) var currentCell: GridCoordinate {
        didSet {
            guard oldValue != currentCell else { return }
            // "it informs you of something that just happened, then
            // its gone once you leave" (Eddie, Sept 5) -- leaving IS
            // currentCell changing, so that's the one place this needs
            // to clear. No timer, nothing else has to remember to do
            // this.
            if transientMessage != nil {
                transientMessage = nil
            }
            refreshFloorMapTexture()
            // Eddie, Sept 14 (round 3): "close behind the player" --
            // every step through the maze already lands here exactly
            // once per single-cell move (applyArrival sets currentCell
            // one step at a time even mid-glide -- see its own call
            // site), so this is the one real "you just crossed a
            // boundary" event to hang the close on, deliberately NOT a
            // timer (Eddie: "the player may open the door and stand
            // there looking at it before walking through").
            closeBathroomDoorIfJustCrossed(from: oldValue, to: currentCell)
            closeWindowRoomDoorIfJustCrossed(from: oldValue, to: currentCell)
            closeRoomEntranceDoorIfJustCrossed(from: oldValue, to: currentCell)
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
    @Published private(set) var facing: Direction {
        didSet {
            guard oldValue != facing else { return }
            refreshFloorMapTexture()
        }
    }

    /// Which cell holds which object, as of scene-build time -- an
    /// immutable snapshot, same idea as `cells`. objectNodes pairs each
    /// of those coordinates with the actual 3D node
    /// HallwayScene.build(fromMaze:) built for it, so pickup knows both
    /// WHAT to add to the carried list and WHICH node to hide.
    private var objectKinds: [GridCoordinate: ObjectKind] { didSet { refreshElevatorMissionSign() } }
    private var objectNodes: [GridCoordinate: SCNNode]
    /// Which ObjectKind completes THIS floor's mission, or nil for a
    /// floor with no mission gate at all -- see isMissionComplete's own
    /// doc comment for the full completion rule. Floor 1 sets this to
    /// .trashCan (Eddie, Sept 7: "since we already have the trash
    /// pretty much in there, lets make it the first floors mission").
    private let missionObjectKind: ObjectKind?
    /// Sept 25 (Designer wall/floor authoring, live ADD): the fire and
    /// extinguisher and photo-booth coordinate/node/expression tables are
    /// private(set) var (was private let) so DecoratorState-authored
    /// objects can be registered into the running navigation state and
    /// join this floor's mission exactly like DefaultMazes.json-authored
    /// ones. See registerFire/unregisterFire, registerExtinguisher/
    /// unregisterExtinguisher, registerPhotoBooth/unregisterPhotoBooth.
    private(set) var fireCoords: Set<GridCoordinate> { didSet { refreshElevatorMissionSign() } }
    private(set) var fireNodes: [GridCoordinate: SCNNode]
    private(set) var extinguisherCoords: [GridCoordinate: Direction]
    private(set) var extinguisherNodes: [GridCoordinate: SCNNode]
    private(set) var photoBoothNodes: [GridCoordinate: SCNNode]
    private(set) var photoBoothDirections: [GridCoordinate: Direction]
    private(set) var photoBoothExpressions: [GridCoordinate: PhotoBoothExpression] { didSet { refreshElevatorMissionSign() } }
    private var completedPhotoBooths: Set<GridCoordinate> = [] { didSet { refreshElevatorMissionSign() } }
    @Published private(set) var activePhotoBooth: GridCoordinate?
    @Published private(set) var photoBoothCompletionImage: UIImage?
    @Published private(set) var photoBoothCameraState: String?
    private let ticTacToeTerminalNodes: [GridCoordinate: SCNNode]
    private let ticTacToeDirections: [GridCoordinate: Direction]
    /// Non-nil while the aptitude-test overlay is on screen -- same
    /// shape as activePhotoBooth/handheldMapVisible.
    /// The Picture (coord in `pictures`) the player just tapped while
    /// standing at/against it, if any -- drives ContentView's "Change
    /// Picture" confirmationDialog. Same one-active-thing-at-a-time
    /// shape as activeTicTacToeTerminal, but there is no persisted
    /// board state to hold here: the menu itself is stateless, and the
    /// actual mutation happens in MazeStore, not here (Sept 20).
    /// Sept 22 (wall-face authoring expansion): WallFace, not just
    /// GridCoordinate -- a cell can now hold two Pictures, so the menu
    /// must remember WHICH wall face it's for, not just which cell.
    @Published var activePictureMenu: WallFace?
    /// BUG 2 fix (manual-mode elevator Change Picture), Sept 26: which
    /// elevator poster the player just tapped while riding with full
    /// camera control -- same one-active-thing-at-a-time shape as
    /// activePictureMenu just above, but deliberately NOT a WallFace:
    /// the elevator interior has no grid cell/facing of its own, and
    /// this is never routed through mazeStore (elevator pictures stay
    /// off-limits to Decorator/Designer authoring -- see
    /// applyElevatorPosterImage(_:to:) below).
    @Published var activeElevatorPictureMenu: ElevatorPosterTarget?
    @Published private(set) var activeTicTacToeTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER wins a round -- see
    /// isMissionComplete. At most one terminal per floor for now, so
    /// (unlike completedPhotoBooths) a single Bool is enough; a fresh
    /// TapNavigationController is built per floor load anyway, so this
    /// never needs resetting mid-floor except by the dev reset() below.
    @Published private(set) var ticTacToeWon = false { didSet { refreshElevatorMissionSign() } }
    private let shellGameStationNodes: [GridCoordinate: SCNNode]
    private let shellGameDirections: [GridCoordinate: Direction]
    /// Non-nil while the shell-game overlay is on screen -- same shape
    /// as activeTicTacToeTerminal.
    @Published private(set) var activeShellGameTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER taps the correct cup -- see
    /// isMissionComplete. Same one-Bool shape as ticTacToeWon.
    @Published private(set) var shellGameWon = false { didSet { refreshElevatorMissionSign() } }
    private let rockPaperScissorsTerminalNodes: [GridCoordinate: SCNNode]
    private let rockPaperScissorsDirections: [GridCoordinate: Direction]
    /// Non-nil while the Rock Paper Scissors overlay is on screen --
    /// same shape as activeShellGameTerminal.
    @Published private(set) var activeRockPaperScissorsTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER's move beats the computer's --
    /// see isMissionComplete. Same one-Bool shape as shellGameWon.
    @Published private(set) var rockPaperScissorsWon = false { didSet { refreshElevatorMissionSign() } }
    private let higherLowerTerminalNodes: [GridCoordinate: SCNNode]
    private let higherLowerDirections: [GridCoordinate: Direction]
    /// Non-nil while the Higher/Lower overlay is on screen -- same
    /// shape as activeRockPaperScissorsTerminal.
    @Published private(set) var activeHigherLowerTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER reaches a 3-correct streak --
    /// see isMissionComplete. Same one-Bool shape as rockPaperScissorsWon.
    @Published private(set) var higherLowerWon = false { didSet { refreshElevatorMissionSign() } }
    private let fiveCardDrawTerminalNodes: [GridCoordinate: SCNNode]
    private let fiveCardDrawDirections: [GridCoordinate: Direction]
    /// Non-nil while the Five-Card Draw overlay is on screen -- same
    /// shape as activeHigherLowerTerminal.
    @Published private(set) var activeFiveCardDrawTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER's final hand qualifies (pair
    /// or better) -- see isMissionComplete. Same one-Bool shape as
    /// higherLowerWon.
    @Published private(set) var fiveCardDrawWon = false { didSet { refreshElevatorMissionSign() } }
    private let simonTerminalNodes: [GridCoordinate: SCNNode]
    private let simonDirections: [GridCoordinate: Direction]
    /// Non-nil while the Simon overlay is on screen -- same shape as
    /// activeWhackAMoleTerminal.
    @Published private(set) var activeSimonTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER completes the length-5
    /// sequence -- see isMissionComplete. Same one-Bool shape as
    /// whackAMoleWon.
    @Published private(set) var simonWon = false { didSet { refreshElevatorMissionSign() } }
    private let hangmanTerminalNodes: [GridCoordinate: SCNNode]
    private let hangmanDirections: [GridCoordinate: Direction]
    /// Non-nil while the Hangman overlay is on screen -- same shape
    /// as activeSimonTerminal.
    @Published private(set) var activeHangmanTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER reveals the whole word -- see
    /// isMissionComplete. Same one-Bool shape as simonWon.
    @Published private(set) var hangmanWon = false { didSet { refreshElevatorMissionSign() } }
    private let connectFourTerminalNodes: [GridCoordinate: SCNNode]
    private let connectFourDirections: [GridCoordinate: Direction]
    /// Non-nil while the Connect Four overlay is on screen -- same
    /// shape as activeHangmanTerminal.
    @Published private(set) var activeConnectFourTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER wins a game -- see
    /// isMissionComplete. Same one-Bool shape as hangmanWon.
    @Published private(set) var connectFourWon = false { didSet { refreshElevatorMissionSign() } }
    private let checkersTerminalNodes: [GridCoordinate: SCNNode]
    private let checkersDirections: [GridCoordinate: Direction]
    /// Non-nil while the Checkers overlay is on screen -- same
    /// shape as activeConnectFourTerminal.
    @Published private(set) var activeCheckersTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER wins a game -- see
    /// isMissionComplete. Same one-Bool shape as connectFourWon.
    @Published private(set) var checkersWon = false { didSet { refreshElevatorMissionSign() } }
    private let woidleTerminalNodes: [GridCoordinate: SCNNode]
    private let woidleDirections: [GridCoordinate: Direction]
    /// Non-nil while the Woidle overlay is on screen -- same shape as
    /// activeCheckersTerminal.
    @Published private(set) var activeWoidleTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER wins a game -- see
    /// isMissionComplete. Same one-Bool shape as checkersWon.
    @Published private(set) var woidleWon = false { didSet { refreshElevatorMissionSign() } }
    private(set) var extinguisherRestingTransforms: [GridCoordinate: (position: SCNVector3, eulerAngles: SCNVector3, scale: SCNVector3)]
    private var extinguishedFireCoords: Set<GridCoordinate> = [] { didSet { refreshElevatorMissionSign() } }
    @Published private(set) var carryingExtinguisher = false
    private var carriedExtinguisherNode: SCNNode?
    private var extinguisherPickupInProgress = false
    private var pickedUpExtinguisherCoords: Set<GridCoordinate> = []
    private var extinguishingFireCoords: Set<GridCoordinate> = []
    private var fireInteractionID = UUID()
    /// Which of objectKinds' coordinates have been picked up this run --
    /// doubles as the "already collected?" check so walking back over an
    /// empty cell doesn't re-collect it. Cleared by reset(), which also
    /// re-adds each named node back into the scene, so Reset genuinely
    /// starts the floor over instead of leaving already-picked-up
    /// objects permanently missing.
    private var collectedCoords: Set<GridCoordinate> = [] { didSet { refreshElevatorMissionSign() } }
    /// Sept 21 (DECORATE one-cell movement): mirrors DecoratorState's
    /// `enabled` flag, kept in sync by ContentView's HallwaySceneView
    /// (see its updateUIView wiring block) rather than importing
    /// DecoratorState itself here. advance() reads this alone to cap a
    /// queued walk to a single cell -- no other DECORATE awareness
    /// exists in this controller. Defaults false so a navigation
    /// controller created/used before that wiring runs behaves exactly
    /// as before (full multi-cell PLAY-mode walking).
    var decorateModeEnabled = false {
        didSet {
            guard decorateModeEnabled, !oldValue else { return }
            // Mode is synchronized from updateUIView; defer published session
            // cleanup until that SwiftUI update finishes.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.decorateModeEnabled else { return }
                self.cancelPhotoBooth()
            }
        }
    }
    /// Sept 21 (present-once-then-allow-pass): the pickup object
    /// coordinate advance() most recently stopped one cell short of --
    /// see that function's own doc comment for the full Choice A/B
    /// shape. Cleared on rotate()/stepBackward()/reset() so a fresh
    /// approach (after turning away or backing up) presents the object
    /// again instead of silently reusing a stale "already declined."
    private var presentedPickupCoord: GridCoordinate? = nil
    @Published private(set) var paintedCells: Set<GridCoordinate> = [] { didSet { refreshElevatorMissionSign() } }
    @Published private(set) var hasPaintBucket = false { didSet { refreshElevatorMissionSign() } }
    private var wallPainter: WallPainter?
    var paintProgress: String? {
        missionObjectKind == .paintBucket ? "Painted \(paintedCells.count)/\(cells.count)" : nil
    }

    func updatePaintBase(for material: SCNMaterial) { wallPainter?.updateBase(for: material) }

    private func paintIfCarryingBucket(at coord: GridCoordinate) {
        guard missionObjectKind == .paintBucket, hasPaintBucket, paintedCells.insert(coord).inserted else { return }
        wallPainter?.paint(coord)
        SoundEffects.playPaintSplat()
        if paintedCells == cells { showMessage("Every hallway is painted! Return to the elevator.") }
    }

    /// Every object picked up this run, oldest first -- what the HUD
    /// strip in ContentView actually displays.
    @Published private(set) var collectedObjects: [ObjectKind] = [] { didSet { refreshElevatorMissionSign() } }
    @Published private(set) var carriedMail: [CarriedRoomItem] = [] { didSet { refreshElevatorMissionSign() } }
    // Both HUD maps observe the controller; wall maps refresh at registration.
    @Published private var roomDoors: [GridCoordinate: RoomDoorPlacement]
    private let itemRooms: [GridCoordinate: Int]
    private var deliveredMail: Set<GridCoordinate> = [] { didSet { refreshElevatorMissionSign() } }
    /// The building's first real bathroom door(s) -- coord is the
    /// hallway-side cell the door is mounted in, direction is which
    /// wall (matches MazeStore.bathroomDoors exactly). See
    /// openDirections/bathroomDoorAnchor(from:direction:) below for
    /// how this actually gates movement.
    private let bathroomDoors: [GridCoordinate: Direction]
    /// Which bathroom doors (keyed by the same coord as bathroomDoors
    /// above) have been swung open this session. Eddie, Sept 14: "An
    /// open door can remain open" -- no auto-close, so this only ever
    /// grows.
    @Published private(set) var openBathroomDoors: Set<GridCoordinate> = []
    /// The building's Window Room door(s) -- same coord/keying
    /// convention as bathroomDoors, but the value is the whole
    /// WindowRoomPlacement (direction is inside it) since this class
    /// also needs to resolve the door's hinge node by the SAME
    /// "windowRoomDoor_<row>_<col>" name HallwayScene gave it.
    private let windowRooms: [GridCoordinate: WindowRoomPlacement]
    /// Which Window Room doors have been swung open this session --
    /// same "no auto-close, only ever grows" policy as
    /// openBathroomDoors, since this is the exact same swinging-door
    /// interaction model reused, not a new one.
    @Published private(set) var openWindowRoomDoors: Set<GridCoordinate> = []
    /// Sept 27 (first generic-room-door authoring pass): a fully
    /// operable, ordinary interior room door between two ALREADY-OPEN
    /// cells -- same key convention as bathroomDoors/windowRooms
    /// (coord is the hallway-side cell it's mounted in, direction is
    /// which wall), and the exact same swinging-door interaction
    /// model, reused rather than reinvented. Deliberately distinct
    /// from roomDoors (the office/mail door, decorative, unaffected).
    /// Sept 27 (Decorator Room Entrance authoring): widened from `let`
    /// to `var` -- same reason roomDoors/objectKinds/objectNodes were --
    /// so registerRoomEntranceDoor/unregisterRoomEntranceDoor below can
    /// keep this copy in sync with a door placed or deleted live via
    /// Decorator, with no floor rebuild required.
    private var roomEntranceDoors: [GridCoordinate: Direction]
    /// Which Room Entrance doors have been swung open this session --
    /// same "only ever grows, closeRoomEntranceDoorIfJustCrossed does
    /// the actual closing" policy as openBathroomDoors/
    /// openWindowRoomDoors.
    @Published private(set) var openRoomEntranceDoors: Set<GridCoordinate> = []

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
    private var elevatorMissionSign: ElevatorMissionWarningSign?

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
    var currentFloorNumber: Int { floorNumber }
    var floorLabel: String { floorNumber == 1 ? "LOBBY" : "FLOOR \(floorNumber)" }
    var handheldMapTitle: String { "Map of Floor \(floorNumber)" }
    private let floorNumber: Int
    private let nextFloorNumber: Int?
    // Eddie, Sept 16 (Floor 1 intro walk, once -- bug fix): a `var`,
    // not just an init-time `let`, because ContentView flips this live
    // the moment the ceremonial walk is dispatched (see ContentView's
    // IntroScreenView onEnter closure) -- requestReturnToOpening's
    // reset() reuses this SAME controller instance rather than
    // reconstructing it, so an init-only constant would stay stale at
    // its original value for the rest of this instance's life.
    //
    // Eddie, Sept 17: the ceremonial walk is no longer one-time, so
    // this no longer gates anything below (see isCeremonialEntrance) --
    // still set from ContentView for the same reasons above, just no
    // longer read for that purpose. Kept rather than removed; a
    // separate future task covers real resume/persistence state.
    var hasCompletedInitialEntrance: Bool
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
    /// Eddie, Sept 16 (remove automatic step-out): non-nil from the
    /// moment a destination floor's build presents the player standing
    /// inside the just-arrived elevator (see presentArrivalInsideElevator
    /// below) until they actually walk out -- for BOTH passive and
    /// player-controlled rides now, never just controlled ones. Its
    /// value is the ONE direction that counts as "forward, out through
    /// the doorway" while this is set -- every other direction is
    /// illegal to walk (even ones openDirections would otherwise call
    /// open, since the camera is still physically offset inside the
    /// cab, not yet at the real cell center) until performElevatorEntryWalkOut()
    /// finishes and clears this back to nil. Turning is completely
    /// unaffected -- the player can look anywhere while this is set.
    private(set) var elevatorAwaitingEntryDirection: Direction? = nil
    /// The real hallway cell-center position performElevatorEntryWalkOut()
    /// animates back to -- captured once, in presentArrivalInsideElevator,
    /// before the camera gets offset into the cab.
    private var elevatorEntryCellCenterPosition: SCNVector3? = nil
    private var arrivedElevatorDoorOpen = false
    var canReenterArrivedElevator: Bool {
        arrivedElevatorDoorOpen && elevatorAwaitingEntryDirection == nil &&
        currentCell == endCell && facing == elevatorMountDirection
    }
    private var forwardConnectionIsOpen: Bool {
        if let exit = elevatorAwaitingEntryDirection { return facing == exit }
        return canReenterArrivedElevator || openDirections.contains(facing)
    }

    #if DEBUG
    // Sept 22 (Eddie: presentation-vs-model investigation). Set once,
    // from ContentView.swift's makeUIView, immediately after this
    // controller is constructed during a Floor-2 rebuild -- the
    // LIGHTBUILD number for THAT rebuild (see LightingDeterminismCheck.
    // swift), or nil for every other floor. Consumed (reset to nil) the
    // very first time renderer(_:didRenderScene:atTime:) fires after
    // that, so exactly one presentation-state capture happens per
    // rebuild, taken at the earliest point SceneKit has actually
    // finished drawing a frame with this scene -- the earliest point
    // `.presentation` is guaranteed to reflect what was truly
    // rendered, as opposed to the EARLY/POST/NEXT-RUNLOOP model-state
    // checkpoints in ContentView.swift, none of which follow an actual
    // render pass.
    var pendingPresentationCheckBuildNumber: Int? = nil
    #endif
    /// True once the player has manually steered the camera during
    /// the CURRENT elevator ride (see beginElevatorCameraDrag()
    /// below) -- playElevatorRide checks this right before it would
    /// otherwise run its automatic 180-degree spin, and skips that
    /// action (while still firing arrival at the exact same
    /// scheduled wall-clock time -- see that function's own comment)
    /// once this is true. Reset to false the instant a NEW ride
    /// begins (openElevator(), right where elevatorInUse itself
    /// flips true), so the next passive ride gets the normal
    /// automatic spin again.
    private(set) var playerHasTakenElevatorCameraControl = false
    /// Baseline yaw an elevator-camera drag started from -- same role
    /// as dragBaseYaw above, tracked separately so this freeform look
    /// (continuous, never snaps to a cardinal facing on release --
    /// see beginElevatorCameraDrag()) never touches dragBaseYaw/
    /// isDragRotating or any of the grid-navigation state
    /// beginDragRotate/updateDragRotate/endDragRotate drive.
    private var elevatorCameraDragBaseYaw: Double = 0
    private var isDraggingElevatorCamera = false
    /// Dedicated SCNAction key for the ride's automatic 180 spin --
    /// letting beginElevatorCameraDrag() cancel JUST this action via
    /// removeAction(forKey:) (which does NOT fire that action's
    /// completion handler) without ever touching the ride's forward
    /// dolly, an unrelated position action that can still be
    /// in-flight on this same cameraNode this early in the ride.
    private static let elevatorAutoSpinActionKey = "elevatorAutoSpin"

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
            guard cells.contains(n) else { return false }
            if let anchor = bathroomDoorAnchor(from: currentCell, direction: d), !openBathroomDoors.contains(anchor) {
                return false
            }
            if let anchor = windowRoomDoorAnchor(from: currentCell, direction: d), !openWindowRoomDoors.contains(anchor) {
                return false
            }
            if let anchor = roomEntranceDoorAnchor(from: currentCell, direction: d), !openRoomEntranceDoors.contains(anchor) {
                return false
            }
            return true
        })
    }

    /// If there's a bathroom door on the boundary between `from` and
    /// its neighbor in `direction` (defined from either side -- a door
    /// placed at (10,3) facing .west blocks both (10,3)->west AND
    /// (10,2)->east, same physical door either way), returns the ONE
    /// coordinate MazeStore.bathroomDoors actually keys it by (always
    /// the hallway-side cell it was authored on) -- that's the key
    /// openBathroomDoors tracks, and the same key openBathroomDoor(at:)
    /// and bathroomDoorCoordinate(for:) use. Returns nil when this
    /// boundary has no door at all, i.e. ordinary open passage.
    private func bathroomDoorAnchor(from: GridCoordinate, direction: Direction) -> GridCoordinate? {
        if bathroomDoors[from] == direction { return from }
        let neighbor = GridCoordinate(row: from.row + direction.delta.row, col: from.col + direction.delta.col)
        if bathroomDoors[neighbor] == direction.opposite { return neighbor }
        return nil
    }

    /// Same resolution bathroomDoorAnchor does, for a Window Room
    /// door -- windowRooms' value is a whole WindowRoomPlacement
    /// rather than a bare Direction, so this compares `.direction`.
    private func windowRoomDoorAnchor(from: GridCoordinate, direction: Direction) -> GridCoordinate? {
        if windowRooms[from]?.direction == direction { return from }
        let neighbor = GridCoordinate(row: from.row + direction.delta.row, col: from.col + direction.delta.col)
        if windowRooms[neighbor]?.direction == direction.opposite { return neighbor }
        return nil
    }

    /// Same resolution bathroomDoorAnchor/windowRoomDoorAnchor do, for
    /// a Room Entrance door.
    private func roomEntranceDoorAnchor(from: GridCoordinate, direction: Direction) -> GridCoordinate? {
        if roomEntranceDoors[from] == direction { return from }
        let neighbor = GridCoordinate(row: from.row + direction.delta.row, col: from.col + direction.delta.col)
        if roomEntranceDoors[neighbor] == direction.opposite { return neighbor }
        return nil
    }

    /// How many consecutive cells, starting at `from` and walking one
    /// step at a time in `direction`, are legally open -- the exact
    /// same per-step legality openDirections checks (maze-cell
    /// membership plus bathroom/window-room door state), just
    /// generalized to an arbitrary starting cell and repeated in a
    /// straight line instead of stopping after one step. Used by
    /// beginDragMove() to compute the full scrub range up front, so a
    /// vertical drag can move continuously across several open cells
    /// without inventing a second legality/collision representation.
    /// `limit` is only a sanity bound against a pathological maze; no
    /// real hallway is anywhere near that long in one straight run.
    private func openRunLength(from: GridCoordinate, direction: Direction, limit: Int = 64) -> Int {
        var count = 0
        var cell = from
        while count < limit {
            let n = GridCoordinate(row: cell.row + direction.delta.row, col: cell.col + direction.delta.col)
            guard cells.contains(n) else { break }
            if let anchor = bathroomDoorAnchor(from: cell, direction: direction), !openBathroomDoors.contains(anchor) { break }
            if let anchor = windowRoomDoorAnchor(from: cell, direction: direction), !openWindowRoomDoors.contains(anchor) { break }
            if let anchor = roomEntranceDoorAnchor(from: cell, direction: direction), !openRoomEntranceDoors.contains(anchor) { break }
            count += 1
            cell = n
        }
        return count
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
    var canGoForward: Bool { activePictureMenu == nil && activePhotoBooth == nil && activeTicTacToeTerminal == nil && activeShellGameTerminal == nil && activeRockPaperScissorsTerminal == nil && activeHigherLowerTerminal == nil && activeFiveCardDrawTerminal == nil && activeSimonTerminal == nil && activeHangmanTerminal == nil && activeConnectFourTerminal == nil && activeCheckersTerminal == nil && activeWoidleTerminal == nil && !isAnimating && !isDragRotating && !isDragMoving && !elevatorInUse && !chuteInUse && !extinguisherPickupInProgress && extinguishingFireCoords.isEmpty && forwardConnectionIsOpen }
    var canRotate: Bool { activePictureMenu == nil && activePhotoBooth == nil && activeTicTacToeTerminal == nil && activeShellGameTerminal == nil && activeRockPaperScissorsTerminal == nil && activeHigherLowerTerminal == nil && activeFiveCardDrawTerminal == nil && activeSimonTerminal == nil && activeHangmanTerminal == nil && activeConnectFourTerminal == nil && activeCheckersTerminal == nil && activeWoidleTerminal == nil && !isAnimating && !isDragRotating && !isDragMoving && !elevatorInUse && !chuteInUse && !extinguisherPickupInProgress && extinguishingFireCoords.isEmpty }

    private enum SegmentPhase {
        case pivot      // rotating in place, position unchanged
        case translate  // moving forward, facing already locked in
        case awaitingTurnCommit // render finished; main-thread state update pending
        case scriptedWalkOut // SceneKit action owns translation, not the grid renderer
    }

    private var animationSteps: [NavigationStep] = []
    private var animationIndex = 0
    private var pendingOutcome: NavigationOutcome = .deadEnd
    private var phase: SegmentPhase = .translate
    private var segmentStart = SCNVector3Zero
    private var segmentTarget = SCNVector3Zero
    private var segmentProgress: Double = 0
    // One-shot .translate duration multiplier -- 1.0 for every normal
    // glide (advance()'s walks, stepBackward()). endDragMove() sets
    // this to 0.6 right before starting its release/settle glide (Eddie,
    // Sept 17: "speed up ONLY that final vertical-drag release snap...
    // about 60% of its current duration"), and the .translate case's
    // own final-step completion resets it back to 1.0 immediately after,
    // so the speedup can never leak into a later, unrelated glide.
    private var translateDurationScale: Double = 1.0
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

    /// Every cell a "You Are Here" map is mounted at, straight from
    /// mazeStore.floorMaps -- just the coordinates, since advance()'s
    /// stop check and viewedFloorMapCoords below only ever need "is
    /// there one here," never which wall it's on (HallwayScene already
    /// built the node; this controller only decides whether walking
    /// through is worth stopping for).
    private let floorMapCoords: Set<GridCoordinate>
    /// Coord -> mounted-wall direction, straight from the same
    /// mazeStore.floorMaps dictionary floorMapCoords above is built
    /// from -- retained (Sept 27, wall-object map indicators) so the
    /// popup map can draw a wall-face bar for it. Floor maps are only
    /// ever placed via the 2D Grid Editor (no live 3D-Decorator add/
    /// remove exists for them -- see DecoratorMode.swift), so any
    /// change already forces a full floor rebuild that reconstructs
    /// this controller fresh; no register/unregister needed here.
    private let floorMapDirections: [GridCoordinate: Direction]
    private(set) var photoBoothCoords: Set<GridCoordinate>
    private let ticTacToeTerminalCoords: Set<GridCoordinate>
    private let shellGameStationCoords: Set<GridCoordinate>
    private let rockPaperScissorsTerminalCoords: Set<GridCoordinate>
    private let higherLowerTerminalCoords: Set<GridCoordinate>
    private let fiveCardDrawTerminalCoords: Set<GridCoordinate>
    private let simonTerminalCoords: Set<GridCoordinate>
    private let hangmanTerminalCoords: Set<GridCoordinate>
    private let connectFourTerminalCoords: Set<GridCoordinate>
    private let checkersTerminalCoords: Set<GridCoordinate>
    private let woidleTerminalCoords: Set<GridCoordinate>
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
    /// Same idea as floorMapDirections just above, for the (at most
    /// one) Floor Mission sign -- retained straight from the
    /// mazeStore.missionSigns dictionary missionSignCoords is built
    /// from, for the same Sept 27 wall-object map indicator.
    private let missionSignDirections: [GridCoordinate: Direction]
    /// Same "already stood here once, don't force another stop" role
    /// as viewedFloorMapCoords, for the mission sign.
    private var viewedMissionSignCoords: Set<GridCoordinate> = []

    /// Sept 28 (EXIT sign map markers): coord -> authored WORLD
    /// direction straight off mazeStore.exitSigns, the exact same
    /// dictionary HallwayScene.build(fromMaze:) already reads to build
    /// the real ceiling fixture (see makeExitSignNode) -- no second
    /// direction concept invented for the popup map's arrow. Unlike
    /// floorMapDirections/missionSignDirections above (2D Grid Editor
    /// only), Exit Signs DO have a live 3D-Decorator add/re-point/
    /// delete path (DecoratorState.addExitSignAtCurrentCell/
    /// changeExitSignDirection/deleteExitSign), so this is `var`, not
    /// `let` -- registerExitSign/unregisterExitSign below (same
    /// register/unregister shape as roomEntranceDoors) keep it current
    /// without a full floor rebuild.
    ///
    /// Sept 28 (live map sync fix): also `@Published`, unlike
    /// roomEntranceDoors/pictureFaces/mirrorFaces above -- physical
    /// testing showed a live Decorator add wasn't reaching the popup
    /// Play map (HandheldMapOverlay's `@ObservedObject var controller`)
    /// until the floor was reloaded, even though this dictionary itself
    /// was already correct the instant registerExitSign ran. The data
    /// was right; nothing told SwiftUI to redraw the already-visible
    /// map with it. `@Published` is this class's own existing mechanism
    /// for exactly that -- HandheldMapOverlay already subscribes to
    /// this object's objectWillChange via @ObservedObject, so marking
    /// the one property the popup map's EXIT arrow actually reads is
    /// the minimal, targeted fix: no new data store, no forced broad
    /// refresh, no renderer change.
    @Published private var exitSignDirections: [GridCoordinate: Direction]

    /// Every cell a decorative picture or mirror is mounted at -- same role as
    /// floorMapCoords/missionSignCoords above. Eddie, Sept 9: pictures
    /// are aesthetic only ("nothing that has to be solved - just
    /// looked at"), but still need a forced pause -- "you will have to
    /// force a pause by a picture so we can stop and see it."
    // Sept 21 (3D Decorator wall authoring): `var`, not `let` --
    // registerPicture(_:at:) below needs to add a live Decorator-added
    // Picture into this same bookkeeping after this controller already
    // exists, so the ordinary in-world "walk up, force a pause, Change
    // Picture" behavior works on it immediately too, with no rebuild.
    private var pictureCoords: Set<GridCoordinate>

    /// Coord -> mounted-wall direction for ordinary framed pictures
    /// ONLY (never mirrors) -- pictureCoords just above deliberately
    /// unions pictures with mirrors for the "force a pause" walk-stop,
    /// but the Change Picture menu (Sept 20) must never trigger for a
    /// mirror, per Eddie's spec ("bathroom/lobby mirrors must NOT
    /// trigger this menu"). Backs pictureAtCurrentCell/
    /// activatePictureMenu below. NOTE: `pictures`, the init parameter
    /// with the same shape, is NOT itself a stored property -- it only
    /// lives for the duration of init, which is why this exists as its
    /// own retained copy rather than reusing that name directly.
    /// Sept 22 (wall-face authoring expansion): renamed from
    /// pictureDirections ([GridCoordinate: Direction]) -- a coordinate
    /// alone can no longer say "which wall" a Picture is on once a
    /// cell can hold more than one. Every usage below now checks a
    /// specific WallFace instead of comparing a stored Direction to
    /// `facing`.
    private var pictureFaces: Set<WallFace>
    /// Coord+direction for every Mirror -- same WallFace shape as
    /// pictureFaces above, kept separately because a mirror must
    /// never join pictureFaces (that set drives the Change Picture
    /// menu, which a mirror must never offer -- see pictureFaces'
    /// own doc comment). Added Sept 27 purely so the popup map's new
    /// wall-object indicator has a direction to draw for mirrors too;
    /// nothing here changes mirror gameplay behavior. Kept in sync by
    /// registerMirror/unregisterMirror below, the same live-add path
    /// pictureCoords already used for mirrors.
    private var mirrorFaces: Set<WallFace>

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
    /// Drives ContentView's full-screen "blown up" map view -- Eddie,
    /// Sept 6: "when you tap the wall map, let it blow up and show what
    /// we show on the map editor screen... then tap anywhere to shrink
    /// it back to the wall size." Not private(set): ContentView's own
    /// tap-anywhere-to-dismiss gesture on that overlay sets this back
    /// to false directly, same as any other simple UI toggle -- there's
    /// no extra bookkeeping a dedicated close method would need to do.
    @Published var floorMapOverlayVisible = false

    @Published private(set) var handheldMapVisible = false
    /// Cancels the coordinator's held-walk timer when the map opens.
    var onHandheldMapOpened: (() -> Void)?

    var canOpenHandheldMap: Bool {
        !elevatorInUse && !chuteInUse && activePhotoBooth == nil && activeTicTacToeTerminal == nil &&
        activeShellGameTerminal == nil && activeRockPaperScissorsTerminal == nil &&
        activeHigherLowerTerminal == nil &&
        activeFiveCardDrawTerminal == nil &&
        activeSimonTerminal == nil &&
        activeHangmanTerminal == nil &&
        activeConnectFourTerminal == nil &&
        activeCheckersTerminal == nil &&
        activeWoidleTerminal == nil &&
        !extinguisherPickupInProgress && extinguishingFireCoords.isEmpty
    }

    func openHandheldMap() {
        guard !handheldMapVisible, canOpenHandheldMap else { return }
        logNavSync("MAP OPEN — before overlay")
        // A two-finger interaction may open the map during a drag. Preserve
        // the camera position and settle back to the committed heading on close.
        if isDragRotating { endDragRotate(fraction: 0) }
        if isDragMoving { endDragMove(fraction: 0) }
        // Sept 14 (Eddie, round 2): the slide-up transition on
        // HandheldMapOverlay's card wasn't actually animating on-device --
        // a transition on a conditional view only animates if the state
        // change that inserts/removes it happens inside an animation
        // transaction. That transaction now lives at the actual call
        // sites in HandheldMapViews.swift (withAnimation wrapping each
        // controller.openHandheldMap()/closeHandheldMap() call) instead
        // of here -- this file has no SwiftUI dependency anywhere else
        // (SceneKit/Combine/UIKit only, see imports at top), and
        // withAnimation's transaction is thread-local, so wrapping the
        // call from the SwiftUI layer still animates this same
        // synchronous assignment without pulling SwiftUI into the
        // controller.
        handheldMapVisible = true
        onHandheldMapOpened?()
    }

    func closeHandheldMap() {
        guard handheldMapVisible else { return }
        logNavSync("MAP CLOSE — before overlay dismissal")
        handheldMapVisible = false
    }

    /// A renderer callback may already be queued when the map opens. Keep
    /// its arrival/mission effects paused too, then deliver them once on close.
    private func applyNavigationUpdate(_ update: @escaping () -> Void) {
        update()
    }

    init(cameraNode: SCNNode, scene: SCNScene, cells: Set<GridCoordinate>, cellSize: CGFloat, startCell: GridCoordinate, startFacing: Direction, endCell: GridCoordinate, objects: [GridCoordinate: ObjectKind] = [:], objectNodes: [GridCoordinate: SCNNode] = [:], destinations: [GridCoordinate: ObjectKind] = [:], destinationNodes: [GridCoordinate: SCNNode] = [:], elevatorLeftDoor: SCNNode? = nil, elevatorRightDoor: SCNNode? = nil, elevatorMountDirection: Direction? = nil, elevatorButtonNodes: [Int: SCNNode] = [:], floorNumber: Int = 1, nextFloorNumber: Int? = nil, floorMaps: [GridCoordinate: Direction] = [:], floorMapPlaneNodes: [SCNNode] = [], missionSigns: [GridCoordinate: Direction] = [:], exitSigns: [GridCoordinate: Direction] = [:], pictures: Set<WallFace> = [], mirrors: [GridCoordinate: Direction] = [:], fires: Set<GridCoordinate> = [], fireNodes: [GridCoordinate: SCNNode] = [:], extinguishers: [GridCoordinate: Direction] = [:], extinguisherNodes: [GridCoordinate: SCNNode] = [:], photoBooths: [GridCoordinate: (direction: Direction, expression: PhotoBoothExpression)] = [:], photoBoothNodes: [GridCoordinate: SCNNode] = [:], ticTacToeTerminals: [GridCoordinate: Direction] = [:], ticTacToeTerminalNodes: [GridCoordinate: SCNNode] = [:], shellGameStations: [GridCoordinate: Direction] = [:], shellGameStationNodes: [GridCoordinate: SCNNode] = [:], rockPaperScissorsTerminals: [GridCoordinate: Direction] = [:], rockPaperScissorsTerminalNodes: [GridCoordinate: SCNNode] = [:], higherLowerTerminals: [GridCoordinate: Direction] = [:], higherLowerTerminalNodes: [GridCoordinate: SCNNode] = [:], fiveCardDrawTerminals: [GridCoordinate: Direction] = [:], fiveCardDrawTerminalNodes: [GridCoordinate: SCNNode] = [:], simonTerminals: [GridCoordinate: Direction] = [:], simonTerminalNodes: [GridCoordinate: SCNNode] = [:], hangmanTerminals: [GridCoordinate: Direction] = [:], hangmanTerminalNodes: [GridCoordinate: SCNNode] = [:], connectFourTerminals: [GridCoordinate: Direction] = [:], connectFourTerminalNodes: [GridCoordinate: SCNNode] = [:], checkersTerminals: [GridCoordinate: Direction] = [:], checkersTerminalNodes: [GridCoordinate: SCNNode] = [:], woidleTerminals: [GridCoordinate: Direction] = [:], woidleTerminalNodes: [GridCoordinate: SCNNode] = [:], roomDoors: [GridCoordinate: RoomDoorPlacement] = [:], itemRooms: [GridCoordinate: Int] = [:], bathroomDoors: [GridCoordinate: Direction] = [:], windowRooms: [GridCoordinate: WindowRoomPlacement] = [:], roomEntranceDoors: [GridCoordinate: Direction] = [:], missionObjectKind: ObjectKind? = nil, hasCompletedInitialEntrance: Bool = false) {
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
        self.bathroomDoors = bathroomDoors
        self.windowRooms = windowRooms
        self.roomEntranceDoors = roomEntranceDoors
        self.objectKinds = objects
        self.objectNodes = objectNodes
        self.missionObjectKind = missionObjectKind
        self.fireCoords = fires
        self.fireNodes = fireNodes
        self.extinguisherCoords = extinguishers
        self.extinguisherNodes = extinguisherNodes
        self.photoBoothNodes = photoBoothNodes
        self.photoBoothDirections = photoBooths.mapValues(\.direction)
        self.photoBoothExpressions = photoBooths.mapValues(\.expression)
        self.ticTacToeTerminalNodes = ticTacToeTerminalNodes
        self.ticTacToeDirections = ticTacToeTerminals
        self.shellGameStationNodes = shellGameStationNodes
        self.shellGameDirections = shellGameStations
        self.rockPaperScissorsTerminalNodes = rockPaperScissorsTerminalNodes
        self.rockPaperScissorsDirections = rockPaperScissorsTerminals
        self.higherLowerTerminalNodes = higherLowerTerminalNodes
        self.higherLowerDirections = higherLowerTerminals
        self.fiveCardDrawTerminalNodes = fiveCardDrawTerminalNodes
        self.fiveCardDrawDirections = fiveCardDrawTerminals
        self.simonTerminalNodes = simonTerminalNodes
        self.simonDirections = simonTerminals
        self.hangmanTerminalNodes = hangmanTerminalNodes
        self.hangmanDirections = hangmanTerminals
        self.connectFourTerminalNodes = connectFourTerminalNodes
        self.connectFourDirections = connectFourTerminals
        self.checkersTerminalNodes = checkersTerminalNodes
        self.checkersDirections = checkersTerminals
        self.woidleTerminalNodes = woidleTerminalNodes
        self.woidleDirections = woidleTerminals
        self.extinguisherRestingTransforms = extinguisherNodes.mapValues {
            (position: $0.position, eulerAngles: $0.eulerAngles, scale: $0.scale)
        }
        self.wallPainter = missionObjectKind == .paintBucket ? WallPainter(scene: scene) : nil
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
        self.hasCompletedInitialEntrance = hasCompletedInitialEntrance
        self.floorMapCoords = Set(floorMaps.keys)
        self.floorMapDirections = floorMaps
        self.photoBoothCoords = Set(photoBooths.keys)
        self.ticTacToeTerminalCoords = Set(ticTacToeTerminals.keys)
        self.shellGameStationCoords = Set(shellGameStations.keys)
        self.rockPaperScissorsTerminalCoords = Set(rockPaperScissorsTerminals.keys)
        self.higherLowerTerminalCoords = Set(higherLowerTerminals.keys)
        self.fiveCardDrawTerminalCoords = Set(fiveCardDrawTerminals.keys)
        self.simonTerminalCoords = Set(simonTerminals.keys)
        self.hangmanTerminalCoords = Set(hangmanTerminals.keys)
        self.connectFourTerminalCoords = Set(connectFourTerminals.keys)
        self.checkersTerminalCoords = Set(checkersTerminals.keys)
        self.woidleTerminalCoords = Set(woidleTerminals.keys)
        self.missionSignCoords = Set(missionSigns.keys)
        self.missionSignDirections = missionSigns
        self.exitSignDirections = exitSigns
        self.pictureCoords = Set(pictures.map(\.coord)).union(mirrors.keys)
        self.pictureFaces = pictures
        self.mirrorFaces = Set(mirrors.map { WallFace(coord: $0.key, direction: $0.value) })
        self.floorMapPlaneNodes = floorMapPlaneNodes

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
        refreshElevatorMissionSign()
    }

    var fireMissionProgress: String? {
        guard !fireCoords.isEmpty else { return nil }
        return "Fires remaining: \(fireCoords.subtracting(extinguishedFireCoords).count)"
    }

    var photoBoothMissionProgress: String? {
        guard !photoBoothExpressions.isEmpty else { return nil }
        return "Photos complete: \(completedPhotoBooths.count)/\(photoBoothExpressions.count)"
    }

    var activePhotoBoothPrompt: String? {
        activePhotoBooth.flatMap { photoBoothExpressions[$0]?.prompt }
    }

    func activatePhotoBooth(at coord: GridCoordinate) {
        guard !decorateModeEnabled, activePhotoBooth == nil, canRotate, coord == currentCell, photoBoothDirections[coord] == facing, photoBoothExpressions[coord] != nil, !completedPhotoBooths.contains(coord) else { return }
        navLog("photo booth activating at \(coord), facing \(facing)")
        activePhotoBooth = coord
        photoBoothCameraState = "starting"
        if let booth = photoBoothNodes[coord] {
            HallwayScene.setPhotoBoothStatus("STARTING CAMERA...", on: booth)
            // TEMP DIAGNOSTIC (Eddie, Sept 13, round 2): both the real
            // readout and the giant magenta panel were reported
            // invisible on device, so this proves/disproves scene
            // attachment and framing at the exact moment you'd be
            // looking at the booth -- world positions (not local), an
            // ancestor-walk isHidden/opacity check (a parent could be
            // hidden even if this node isn't), whether the node is
            // actually reachable from the live scene, and the camera's
            // own world position/distance so we can tell if the panel
            // is simply out of view (e.g. behind the camera, or absurdly
            // far/near) rather than never rendering at all.
            func hiddenChain(_ n: SCNNode) -> String {
                var chain: [String] = []
                var cur: SCNNode? = n
                while let node = cur {
                    chain.append("\(node.name ?? "?")[hidden=\(node.isHidden),opacity=\(node.opacity)]")
                    cur = node.parent
                }
                return chain.joined(separator: " <- ")
            }
            // FIX (Eddie, Sept 13): SCNNode has no `scene` property --
            // that was invalid and broke the build. The valid way to
            // check "is this node actually attached to the live scene"
            // is to walk its own parent chain and see whether it ever
            // reaches the scene's own rootNode (already held weakly on
            // this controller as `scene`).
            func isAttached(_ n: SCNNode) -> Bool {
                guard let root = scene?.rootNode else { return false }
                var cur: SCNNode? = n
                while let node = cur {
                    if node === root { return true }
                    cur = node.parent
                }
                return false
            }
            let readoutNode = booth.childNode(withName: "photoBoothReadout", recursively: true)
            navLog("PBDIAG activate booth=\(coord) boothInScene=\(isAttached(booth)) boothWorldPos=\(booth.worldPosition) cameraWorldPos=\(cameraNode.worldPosition)")
            if let readoutNode {
                navLog("PBDIAG readoutNode worldPos=\(readoutNode.worldPosition) inScene=\(isAttached(readoutNode)) materialContentsSet=\(readoutNode.geometry?.firstMaterial?.diffuse.contents != nil) chain=\(hiddenChain(readoutNode))")
            } else {
                navLog("PBDIAG readoutNode NOT FOUND on booth \(coord) -- childNode(withName:) failed")
            }
        }
    }

    func cancelPhotoBooth() {
        if let coord = activePhotoBooth, !completedPhotoBooths.contains(coord),
           let node = photoBoothNodes[coord], let prompt = photoBoothExpressions[coord]?.prompt {
            HallwayScene.resetPhotoBoothScreen(on: node, prompt: prompt)
        }
        activePhotoBooth = nil
        photoBoothCompletionImage = nil
        photoBoothCameraState = nil
    }

    func reportPhotoBoothError(_ message: String) {
        photoBoothCameraState = "error"
        showMessage(message)
        activePhotoBooth = nil
    }

    func reportPhotoBoothCameraLive(at coord: GridCoordinate) {
        guard activePhotoBooth == coord, !completedPhotoBooths.contains(coord) else { return }
        guard photoBoothCameraState != "live" && photoBoothCameraState != "face" else { return }
        photoBoothCameraState = "live"
        if let node = photoBoothNodes[coord], let prompt = photoBoothExpressions[coord]?.prompt {
            HallwayScene.setPhotoBoothStatus(prompt + "\nSWIPE TO STEP AWAY", on: node)
        }
    }

    func reportPhotoBoothFaceTracking(at coord: GridCoordinate) {
        guard activePhotoBooth == coord, !completedPhotoBooths.contains(coord) else { return }
        guard photoBoothCameraState != "face" else { return }
        if let node = photoBoothNodes[coord], let prompt = photoBoothExpressions[coord]?.prompt {
            HallwayScene.setPhotoBoothStatus(prompt + "\nSWIPE TO STEP AWAY", on: node)
        }
        photoBoothCameraState = "face"
    }

    // Eddie, Sept 13: "There was live on-screen text associated with
    // the face/facial-gesture feature that was working extremely
    // well. It responded essentially immediately as my facial
    // expression changed. That live text is no longer visible."
    // Traced this all the way through: the AR face session, the
    // blend-shape matching (PhotoBoothCameraView.Coordinator.session(
    // _:didUpdate anchors:) in ContentView.swift), and the in-scene
    // "photoBoothReadout" text plane (HallwayScene.makePhotoBoothNode/
    // setPhotoBoothStatus) are all still present, still wired up, and
    // still being called -- nothing is hidden, offscreen, covered, or
    // conditioned out. What's actually missing: reportPhotoBoothFaceTracking
    // above only ever WRITES that readout text once (guarded by
    // photoBoothCameraState != "face"), the very first frame a face is
    // seen -- every frame after that, session(_:didUpdate anchors:)
    // computes a fresh matched/consecutiveMatches reading from the
    // live blend shapes and then just throws it away without ever
    // reaching the screen, so the readout necessarily goes static right
    // when face-tracking starts, precisely the opposite of "live."
    // This whole feature landed in a single squash commit (994781a)
    // with no earlier git history to diff against, so I can't prove
    // byte-for-byte what the original live text said -- but this is
    // the same existing readout plane, the same existing per-frame
    // blend-shape signal, just finally reaching the screen every frame
    // instead of once. Nothing about the AR session, the capture flow,
    // the matching thresholds, or the 3-consecutive-frame capture rule
    // changes.
    func updatePhotoBoothLiveExpression(matched: Bool, holding: Int, at coord: GridCoordinate) {
        guard activePhotoBooth == coord, !completedPhotoBooths.contains(coord),
              photoBoothCameraState != "captured",
              let node = photoBoothNodes[coord], let prompt = photoBoothExpressions[coord]?.prompt else { return }
        let held = max(0, min(holding, 3))
        let dots = String(repeating: "\u{25CF}", count: held) + String(repeating: "\u{25CB}", count: 3 - held)
        let status = matched ? "\(prompt)\nHOLD IT... \(dots)" : "\(prompt)\nSWIPE TO STEP AWAY"
        HallwayScene.setPhotoBoothStatus(status, on: node)
    }

    func completePhotoBooth(at coord: GridCoordinate, image: UIImage) {
        guard activePhotoBooth == coord, !completedPhotoBooths.contains(coord), photoBoothExpressions[coord] != nil else { return }
        completedPhotoBooths.insert(coord)
        photoBoothCompletionImage = image
        photoBoothCameraState = "captured"
        SoundEffects.playCameraClick()
        if let booth = photoBoothNodes[coord] {
            HallwayScene.flashPhotoBoothScreen(on: booth)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                guard self.activePhotoBooth == coord, self.photoBoothCameraState == "captured", self.completedPhotoBooths.contains(coord) else { return }
                HallwayScene.setPhotoBoothImage(image, on: booth)
                HallwayScene.setPhotoBoothStatus("THANK YOU.\nID PHOTO ACCEPTED.", on: booth)
                self.activePhotoBooth = nil
                self.photoBoothCameraState = nil
            }
        } else {
            activePhotoBooth = nil
            photoBoothCameraState = nil
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage(isMissionComplete ? "ID photo accepted! Return to the elevator." : (photoBoothMissionProgress ?? "Photo accepted."))
    }

    func updatePhotoBoothLiveImage(_ image: UIImage, at coord: GridCoordinate) {
        guard activePhotoBooth == coord, !completedPhotoBooths.contains(coord), let booth = photoBoothNodes[coord] else { return }
        reportPhotoBoothCameraLive(at: coord)
        HallwayScene.setPhotoBoothLiveImage(image, on: booth)
    }

    func photoBoothCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let match = photoBoothNodes.first(where: { $0.value === candidate }) { return match.key }
            current = candidate.parent
        }
        return nil
    }

    var photoBoothAtCurrentCell: GridCoordinate? {
        guard photoBoothDirections[currentCell] == facing, photoBoothExpressions[currentCell] != nil,
              !completedPhotoBooths.contains(currentCell) else { return nil }
        return currentCell
    }

    // MARK: - Tic-Tac-Toe terminal (Floor 7's first embedded mini-game)
    //
    // Eddie, Sept 13: "the mission is a game" -- same "approach, face
    // it, it activates" shape as activatePhotoBooth above, but there's
    // no camera session here: the actual board lives in a SwiftUI
    // overlay (TicTacToeOverlay.swift) that appears the instant
    // activeTicTacToeTerminal goes non-nil and calls back into
    // completeTicTacToeTerminal the moment the player wins.

    func ticTacToeTerminalCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let match = ticTacToeTerminalNodes.first(where: { $0.value === candidate }) { return match.key }
            current = candidate.parent
        }
        return nil
    }

    /// True when the player is standing in a Picture's own cell,
    /// facing the wall it's mounted on -- same "standing at/against
    /// it" shape every mini-game terminal already uses for
    /// ticTacToeTerminalAtCurrentCell and friends, reused here rather
    /// than inventing a hit-test-on-the-3D-node approach (Sept 20).
    var pictureAtCurrentCell: GridCoordinate? {
        guard pictureFaces.contains(WallFace(coord: currentCell, direction: facing)) else { return nil }
        return currentCell
    }

    /// Opens the Change Picture menu for the Picture at `coord`, on the
    /// wall the player is currently facing -- same guard shape as
    /// activateTicTacToeTerminal, minus the terminal-specific
    /// canRotate/won checks a decorative picture has no equivalent of.
    func activatePictureMenu(at coord: GridCoordinate) {
        let face = WallFace(coord: coord, direction: facing)
        guard activePictureMenu == nil, coord == currentCell, pictureFaces.contains(face) else { return }
        activePictureMenu = face
    }

    /// Sept 21 (3D Decorator wall authoring): registers a Picture added
    /// live via Decorator (DecoratorState.addPicture) into the same
    /// bookkeeping every build-time Picture already has here, so the
    /// ordinary gameplay "walk up to it, force a pause, Change Picture"
    /// behavior works on it immediately -- no floor reload needed.
    func registerPicture(_ direction: Direction, at coord: GridCoordinate) {
        pictureCoords.insert(coord)
        pictureFaces.insert(WallFace(coord: coord, direction: direction))
    }

    /// Sept 21 (Picture Decorator complete pass, Goal 4): the reverse of
    /// registerPicture above -- after DecoratorState.deletePicture
    /// removes a live Picture, this removes it from the SAME
    /// bookkeeping, so walking up to that now-empty wall no longer
    /// offers the "Change Picture" menu.
    ///
    /// Sept 22 (wall-face authoring expansion): pictureCoords is now
    /// only cleared once NO face of this cell has a Picture left --
    /// with two Pictures possible per cell, deleting one must not blind
    /// the walk-stop logic to the other. Still safe to check only
    /// pictureFaces (never a mirror) because a coordinate can never
    /// hold both a Picture and a Mirror at once (MazeStore.
    /// canPlacePicture already requires mirrors[coord] != direction for
    /// every face, and vice versa).
    func unregisterPicture(_ direction: Direction, at coord: GridCoordinate) {
        pictureFaces.remove(WallFace(coord: coord, direction: direction))
        if !pictureFaces.contains(where: { $0.coord == coord }) {
            pictureCoords.remove(coord)
        }
    }

    /// Sept 25 (Designer wall authoring, live Mirror ADD). Mirrors already
    /// force a navigation pause on every pass, exactly like Pictures --
    /// the build-time call site (init) puts them in `pictureCoords` via
    /// `Set(pictures.map(\.coord)).union(mirrors.keys)`. A live-added
    /// mirror must join pictureCoords the same way so walking up to it
    /// stops the walk. It deliberately does NOT join `pictureFaces`
    /// (init:910 comment) -- that set drives the "Change Picture" menu,
    /// and a mirror must never offer it.
    func registerMirror(_ direction: Direction, at coord: GridCoordinate) {
        pictureCoords.insert(coord)
        // Sept 27 (wall-object map indicators): mirrorFaces retains the
        // direction alongside pictureCoords' plain membership, purely so
        // the popup map can draw the new wall-face bar for a live-added
        // mirror too -- does not join pictureFaces (see mirrorFaces' own
        // doc comment), so the Change Picture menu behavior is untouched.
        mirrorFaces.insert(WallFace(coord: coord, direction: direction))
    }

    /// Reverse of registerMirror above. Only clears `coord` from
    /// pictureCoords when no Picture face remains on that cell -- the
    /// coord can never hold both, but the mirror might have been deleted
    /// while a Picture sits on another wall of the same cell.
    func unregisterMirror(_ direction: Direction, at coord: GridCoordinate) {
        mirrorFaces.remove(WallFace(coord: coord, direction: direction))
        if !pictureFaces.contains(where: { $0.coord == coord }) {
            pictureCoords.remove(coord)
        }
    }

    /// Register live authoring with the same door data used after a rebuild.
    func registerRoomDoor(_ door: RoomDoorPlacement) {
        roomDoors[door.coord] = door
        refreshFloorMapTexture()
    }

    /// Sept 27 (Decorator delete-staleness fix): the reverse of a
    /// decorative room door's authoring -- DecoratorState.deleteRoomDoor
    /// already removes the SCNNode and MazeStore's persisted placement,
    /// but had no way to clear THIS controller's own roomDoors copy,
    /// which the live floor-map texture (currentFloorMapImage) and every
    /// walk-stop/knock/deliverMail gate below read directly. Without
    /// this, a deleted door kept blocking walks and kept drawing on the
    /// map until the floor was fully rebuilt. roomDoors was widened from
    /// `let` to `var` above to allow this, same as objectKinds/
    /// objectNodes were for registerFloorObject's sake.
    func unregisterRoomDoor(at coord: GridCoordinate) {
        roomDoors.removeValue(forKey: coord)
        refreshFloorMapTexture()
    }

    /// Sept 25 (Designer authoring, live Fire ADD). Registers a fire
    /// placed live via Decorator (Floor menu) into the same bookkeeping
    /// build-time fires already have, so it is extinguishable with a
    /// picked-up extinguisher AND counted toward the floor's fire
    /// mission (isMissionComplete: extinguishedFireCoords == fireCoords).
    func registerFire(at coord: GridCoordinate, node: SCNNode) {
        fireCoords.insert(coord)
        fireNodes[coord] = node
        refreshFloorMapTexture()
    }

    /// Reverse of registerFire above. If the fire had already been put
    /// out, it drops out of extinguishedFireCoords too, so the mission
    /// equality (extinguishedFireCoords == fireCoords) still holds after
    /// the deletion.
    func unregisterFire(at coord: GridCoordinate) {
        fireCoords.remove(coord)
        fireNodes.removeValue(forKey: coord)
        extinguishedFireCoords.remove(coord)
        refreshFloorMapTexture()
    }

    /// Sept 25 (Designer wall authoring, live Extinguisher ADD).
    /// Registers an extinguisher placed live via Decorator (Wall chooser)
    /// so collectExtinguisherIfPresent (:3007 guards extinguisherCoords
    /// and extinguisherNodes) can pick it up immediately, and stores its
    /// resting transform so reset() and the carry/drop animation restore
    /// it exactly like build-time extinguishers.
    func registerExtinguisher(_ direction: Direction, node: SCNNode, at coord: GridCoordinate) {
        extinguisherCoords[coord] = direction
        extinguisherNodes[coord] = node
        extinguisherRestingTransforms[coord] = (position: node.position, eulerAngles: node.eulerAngles, scale: node.scale)
        refreshFloorMapTexture()
    }

    /// Reverse of registerExtinguisher above. If the player was carrying
    /// this very extinguisher (pickedUpExtinguisherCoords), it also drops
    /// the carry -- the item no longer exists, so the held node must come
    /// down with it.
    func unregisterExtinguisher(at coord: GridCoordinate) {
        extinguisherCoords.removeValue(forKey: coord)
        extinguisherNodes.removeValue(forKey: coord)
        extinguisherRestingTransforms.removeValue(forKey: coord)
        pickedUpExtinguisherCoords.remove(coord)
        if carryingExtinguisher {
            carriedExtinguisherNode?.removeFromParentNode()
            carriedExtinguisherNode = nil
            carryingExtinguisher = false
        }
        extinguishingFireCoords.remove(coord)
        refreshFloorMapTexture()
    }

    /// Sept 25 (Designer wall authoring, live Photo Booth ADD). Registers
    /// a booth placed live via Decorator (Wall chooser) into every table
    /// build-time booths already have -- photoBoothCoords (walk-stop +
    /// floor-map texture) and Directions/Expressions/Nodes (activation at
    /// activatePhotoBooth :966 guards all three) -- so the player can use
    /// it immediately and the floor's photo-booth mission count
    /// (completedPhotoBooths == Set(photoBoothExpressions.keys)) includes
    /// it (Eddie, Sept 25: new mission objects join the real mission).
    func registerPhotoBooth(_ direction: Direction, expression: PhotoBoothExpression, node: SCNNode, at coord: GridCoordinate) {
        photoBoothCoords.insert(coord)
        photoBoothDirections[coord] = direction
        photoBoothExpressions[coord] = expression
        photoBoothNodes[coord] = node
    }

    /// Reverse of registerPhotoBooth above. If the booth was already
    /// completed it drops out of completedPhotoBooths to keep the mission
    /// equality (completedPhotoBooths == Set(photoBoothExpressions.keys))
    /// true after deletion, and an in-flight session is cancelled.
    func unregisterPhotoBooth(at coord: GridCoordinate) {
        photoBoothCoords.remove(coord)
        photoBoothDirections.removeValue(forKey: coord)
        photoBoothExpressions.removeValue(forKey: coord)
        photoBoothNodes.removeValue(forKey: coord)
        completedPhotoBooths.remove(coord)
        if activePhotoBooth == coord {
            activePhotoBooth = nil
            photoBoothCameraState = nil
        }
    }

    /// Stepping away or dismissing without choosing anything -- same
    /// "cancel, don't punish" shape as cancelTicTacToeTerminal.
    func cancelPictureMenu() {
        activePictureMenu = nil
    }

    /// BUG 2 fix, Sept 26: same "cancel, don't punish" shape as
    /// cancelPictureMenu just above.
    func cancelElevatorPictureMenu() {
        activeElevatorPictureMenu = nil
    }

    var ticTacToeTerminalAtCurrentCell: GridCoordinate? {
        guard ticTacToeDirections[currentCell] == facing, !ticTacToeWon else { return nil }
        return currentCell
    }

    func activateTicTacToeTerminal(at coord: GridCoordinate) {
        guard activeTicTacToeTerminal == nil, canRotate, coord == currentCell,
              ticTacToeDirections[coord] == facing, !ticTacToeWon else { return }
        activeTicTacToeTerminal = coord
    }

    /// Stepping away without finishing -- swiping/turning while the
    /// overlay is up calls this first (see rotate/beginDragRotate
    /// below), same "cancel, don't punish" idea as cancelPhotoBooth.
    /// The overlay's own board state is thrown away (a fresh
    /// TicTacToeViewModel next time), which is fine -- Eddie never
    /// asked for progress to persist between visits, only that a
    /// LOSS or DRAW never blocks retrying.
    func cancelTicTacToeTerminal() {
        activeTicTacToeTerminal = nil
    }

    /// Called by TicTacToeOverlay's view model the instant the PLAYER
    /// completes a winning line. One-way gate, same shape as
    /// completePhotoBooth: sets the permanent ticTacToeWon flag
    /// (checked by isMissionComplete), updates the in-world screen
    /// text, and dismisses the overlay itself a beat later instead of
    /// instantly, so "APTITUDE: EXCEPTIONAL" is actually readable.
    func completeTicTacToeTerminal(at coord: GridCoordinate) {
        guard activeTicTacToeTerminal == coord, !ticTacToeWon else { return }
        ticTacToeWon = true
        if let node = ticTacToeTerminalNodes[coord] {
            HallwayScene.setTicTacToeTerminalStatus("APTITUDE: EXCEPTIONAL\nTEST PASSED\n\nELEVATOR ACCESS GRANTED.", on: node)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage("Aptitude test passed! Return to the elevator.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.activeTicTacToeTerminal == coord else { return }
            self.activeTicTacToeTerminal = nil
        }
    }

    // MARK: - Shell-game station (Floor 8's second embedded mini-game)
    //
    // Eddie, Sept 13, right after confirming Floor 7's Tic-Tac-Toe is
    // "FUCKING PERFECT" on-device: "Shell Game should be the second
    // clean implementation." Identical shape to the Tic-Tac-Toe
    // terminal block just above -- approach, face it, it activates;
    // the cups/ball/shuffle live in ShellGameOverlay.swift, this
    // controller only owns activation + the one-way win gate.

    func shellGameTerminalCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let match = shellGameStationNodes.first(where: { $0.value === candidate }) { return match.key }
            current = candidate.parent
        }
        return nil
    }

    var shellGameTerminalAtCurrentCell: GridCoordinate? {
        guard shellGameDirections[currentCell] == facing, !shellGameWon else { return nil }
        return currentCell
    }

    func activateShellGameTerminal(at coord: GridCoordinate) {
        guard activeShellGameTerminal == nil, canRotate, coord == currentCell,
              shellGameDirections[coord] == facing, !shellGameWon else { return }
        activeShellGameTerminal = coord
    }

    /// Stepping away without finishing -- same "cancel, don't punish"
    /// idea as cancelTicTacToeTerminal. The overlay's own round state
    /// is thrown away (a fresh ShellGameViewModel next time), which is
    /// fine -- nothing about a loss/draw ever needs to persist between
    /// visits, only that it never blocks retrying.
    func cancelShellGameTerminal() {
        activeShellGameTerminal = nil
    }

    /// Called by ShellGameOverlay's view model the instant the PLAYER
    /// taps the correct cup. One-way gate, same shape as
    /// completeTicTacToeTerminal: sets the permanent shellGameWon flag
    /// (checked by isMissionComplete), updates the in-world screen
    /// text, and dismisses the overlay itself a beat later so the
    /// reveal is actually readable.
    func completeShellGameTerminal(at coord: GridCoordinate) {
        guard activeShellGameTerminal == coord, !shellGameWon else { return }
        shellGameWon = true
        if let node = shellGameStationNodes[coord] {
            HallwayScene.setShellGameStationStatus("YOU FOUND IT.\n\nELEVATOR ACCESS GRANTED.", on: node)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage("Found the ball! Return to the elevator.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.activeShellGameTerminal == coord else { return }
            self.activeShellGameTerminal = nil
        }
    }

    // MARK: - Rock Paper Scissors terminal (Floor 9's third embedded mini-game)
    //
    // Eddie, Sept 13: the third embedded game, after Tic-Tac-Toe and
    // the Shell Game. Identical shape to both blocks just above --
    // approach, face it, it activates; the choices/reveal live in
    // RockPaperScissorsOverlay.swift, this controller only owns
    // activation + the one-way win gate.

    func rockPaperScissorsTerminalCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let match = rockPaperScissorsTerminalNodes.first(where: { $0.value === candidate }) { return match.key }
            current = candidate.parent
        }
        return nil
    }

    var rockPaperScissorsTerminalAtCurrentCell: GridCoordinate? {
        guard rockPaperScissorsDirections[currentCell] == facing, !rockPaperScissorsWon else { return nil }
        return currentCell
    }

    func activateRockPaperScissorsTerminal(at coord: GridCoordinate) {
        guard activeRockPaperScissorsTerminal == nil, canRotate, coord == currentCell,
              rockPaperScissorsDirections[coord] == facing, !rockPaperScissorsWon else { return }
        activeRockPaperScissorsTerminal = coord
    }

    /// Stepping away without finishing -- same "cancel, don't punish"
    /// idea as cancelShellGameTerminal. The overlay's own round state
    /// is thrown away (a fresh RockPaperScissorsViewModel next time),
    /// which is fine -- a loss or tie never needs to persist between
    /// visits, only that it never blocks retrying.
    func cancelRockPaperScissorsTerminal() {
        activeRockPaperScissorsTerminal = nil
    }

    /// Called by RockPaperScissorsOverlay's view model the instant the
    /// PLAYER's move beats the computer's. One-way gate, same shape as
    /// completeShellGameTerminal: sets the permanent
    /// rockPaperScissorsWon flag (checked by isMissionComplete),
    /// updates the in-world screen text, and dismisses the overlay
    /// itself a beat later so the result is actually readable.
    func completeRockPaperScissorsTerminal(at coord: GridCoordinate) {
        guard activeRockPaperScissorsTerminal == coord, !rockPaperScissorsWon else { return }
        rockPaperScissorsWon = true
        if let node = rockPaperScissorsTerminalNodes[coord] {
            HallwayScene.setRockPaperScissorsTerminalStatus("YOU WIN.\n\nELEVATOR ACCESS GRANTED.", on: node)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage("You beat the building! Return to the elevator.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.activeRockPaperScissorsTerminal == coord else { return }
            self.activeRockPaperScissorsTerminal = nil
        }
    }


    // MARK: - Higher/Lower terminal (Floor 10's fourth embedded mini-game)
    //
    // Eddie, Sept 13: the fourth embedded game, after Tic-Tac-Toe, the
    // Shell Game, and Rock Paper Scissors. Identical shape to the three
    // blocks just above -- approach, face it, it activates; the
    // card/streak logic lives in HigherLowerOverlay.swift, this
    // controller only owns activation + the one-way win gate.

    func higherLowerTerminalCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let match = higherLowerTerminalNodes.first(where: { $0.value === candidate }) { return match.key }
            current = candidate.parent
        }
        return nil
    }

    var higherLowerTerminalAtCurrentCell: GridCoordinate? {
        guard higherLowerDirections[currentCell] == facing, !higherLowerWon else { return nil }
        return currentCell
    }

    func activateHigherLowerTerminal(at coord: GridCoordinate) {
        guard activeHigherLowerTerminal == nil, canRotate, coord == currentCell,
              higherLowerDirections[coord] == facing, !higherLowerWon else { return }
        activeHigherLowerTerminal = coord
    }

    /// Stepping away without finishing -- same "cancel, don't punish"
    /// idea as cancelRockPaperScissorsTerminal. The overlay's own
    /// streak state is thrown away (a fresh HigherLowerViewModel next
    /// time), which is fine -- a partial streak never needs to persist
    /// between visits, only that it never blocks retrying.
    func cancelHigherLowerTerminal() {
        activeHigherLowerTerminal = nil
    }

    /// Called by HigherLowerOverlay's view model the instant the
    /// PLAYER taps through the streak-of-3 win screen. One-way gate,
    /// same shape as completeRockPaperScissorsTerminal, but Eddie,
    /// Sept 13 (pacing fix): "DO NOT auto-dismiss after a timer" --
    /// by the time this is called the player has already read the
    /// result at their own pace and tapped TAP TO CONTINUE, so it
    /// sets the permanent higherLowerWon flag (checked by
    /// isMissionComplete), updates the in-world screen text, and
    /// dismisses the overlay right away rather than on a delay.
    func completeHigherLowerTerminal(at coord: GridCoordinate) {
        guard activeHigherLowerTerminal == coord, !higherLowerWon else { return }
        higherLowerWon = true
        if let node = higherLowerTerminalNodes[coord] {
            HallwayScene.setHigherLowerTerminalStatus("3 IN A ROW.\n\nELEVATOR ACCESS GRANTED.", on: node)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage("You beat the building! Return to the elevator.")
        activeHigherLowerTerminal = nil
    }

    // MARK: - Five-Card Draw terminal (Floor 11's fifth embedded mini-game)
    //
    // Eddie, Sept 13: the fifth embedded game, after Tic-Tac-Toe, the
    // Shell Game, Rock Paper Scissors, and Higher/Lower. Identical
    // shape to the four blocks just above -- approach, face it, it
    // activates; the deal/hold/draw/hand-evaluation logic lives in
    // FiveCardDrawOverlay.swift, this controller only owns activation
    // + the one-way win gate.

    func fiveCardDrawTerminalCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let match = fiveCardDrawTerminalNodes.first(where: { $0.value === candidate }) { return match.key }
            current = candidate.parent
        }
        return nil
    }

    var fiveCardDrawTerminalAtCurrentCell: GridCoordinate? {
        guard fiveCardDrawDirections[currentCell] == facing, !fiveCardDrawWon else { return nil }
        return currentCell
    }

    func activateFiveCardDrawTerminal(at coord: GridCoordinate) {
        guard activeFiveCardDrawTerminal == nil, canRotate, coord == currentCell,
              fiveCardDrawDirections[coord] == facing, !fiveCardDrawWon else { return }
        activeFiveCardDrawTerminal = coord
    }

    /// Stepping away without finishing -- same "cancel, don't punish"
    /// idea as cancelHigherLowerTerminal. The overlay's own hand
    /// (dealt cards, holds, whether it's drawn yet) is thrown away (a
    /// fresh FiveCardDrawViewModel next time), which is fine -- an
    /// unfinished or failed hand never needs to persist between
    /// visits, only that it never blocks retrying.
    func cancelFiveCardDrawTerminal() {
        activeFiveCardDrawTerminal = nil
    }

    /// Called by FiveCardDrawOverlay's view model the instant the
    /// PLAYER taps through a QUALIFYING (pair or better) result
    /// screen. One-way gate, same shape as completeHigherLowerTerminal
    /// -- by the time this is called the player has already read the
    /// result at their own pace and tapped TAP TO CONTINUE, so it sets
    /// the permanent fiveCardDrawWon flag (checked by
    /// isMissionComplete), updates the in-world screen text, and
    /// dismisses the overlay right away rather than on a delay.
    func completeFiveCardDrawTerminal(at coord: GridCoordinate) {
        guard activeFiveCardDrawTerminal == coord, !fiveCardDrawWon else { return }
        fiveCardDrawWon = true
        if let node = fiveCardDrawTerminalNodes[coord] {
            HallwayScene.setFiveCardDrawTerminalStatus("TEST PASSED.\n\nELEVATOR ACCESS GRANTED.", on: node)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage("You beat the building! Return to the elevator.")
        activeFiveCardDrawTerminal = nil
    }

    // MARK: - Simon terminal (Floor 13's seventh embedded mini-game)
    //
    // Eddie, Sept 13: the seventh embedded game, after Tic-Tac-Toe,
    // the Shell Game, Rock Paper Scissors, Higher/Lower, Five-Card
    // Draw, and Whack-A-Mole. Identical shape to the six blocks just
    // above -- approach, face it, it activates; the sequence-
    // generation/playback/tap logic lives in SimonOverlay.swift, this
    // controller only owns activation + the one-way win gate.

    func simonTerminalCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let match = simonTerminalNodes.first(where: { $0.value === candidate }) { return match.key }
            current = candidate.parent
        }
        return nil
    }

    var simonTerminalAtCurrentCell: GridCoordinate? {
        guard simonDirections[currentCell] == facing, !simonWon else { return nil }
        return currentCell
    }

    func activateSimonTerminal(at coord: GridCoordinate) {
        guard activeSimonTerminal == nil, canRotate, coord == currentCell,
              simonDirections[coord] == facing, !simonWon else { return }
        activeSimonTerminal = coord
    }

    /// Stepping away without finishing -- same "cancel, don't punish"
    /// idea as cancelWhackAMoleTerminal. The overlay's own round state
    /// (how far into the sequence the player got, whether a playback
    /// flash is even running) is thrown away (a fresh SimonViewModel
    /// next time, with its own timers invalidated on deinit -- see
    /// that file's runToken), which is fine -- an unfinished or
    /// failed attempt never needs to persist between visits, only
    /// that it never blocks retrying.
    func cancelSimonTerminal() {
        activeSimonTerminal = nil
    }

    /// Called by SimonOverlay's view model the instant the PLAYER
    /// taps through a SUCCESS (length-5 sequence completed) result
    /// screen. One-way gate, same shape as completeWhackAMoleTerminal
    /// -- by the time this is called the player has already read the
    /// result at their own pace and tapped TAP TO CONTINUE, so it sets
    /// the permanent simonWon flag (checked by isMissionComplete),
    /// updates the in-world screen text, and dismisses the overlay
    /// right away rather than on a delay.
    func completeSimonTerminal(at coord: GridCoordinate) {
        guard activeSimonTerminal == coord, !simonWon else { return }
        simonWon = true
        if let node = simonTerminalNodes[coord] {
            HallwayScene.setSimonTerminalStatus("MEMORY: EXCEPTIONAL.\n\nELEVATOR ACCESS GRANTED.", on: node)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage("You beat the building! Return to the elevator.")
        activeSimonTerminal = nil
    }

    // MARK: - Hangman terminal (Floor 12's embedded mini-game)
    //
    // Eddie, Sept 14: replaces the removed Whack-A-Mole in the same
    // Floor 12 slot -- a familiar, low-difficulty recognition game
    // rather than a dexterity challenge. Identical shape to every
    // other terminal above -- approach, face it, it activates; the
    // word bank/guess/reveal logic lives in HangmanOverlay.swift, this
    // controller only owns activation + the one-way win gate.

    func hangmanTerminalCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let match = hangmanTerminalNodes.first(where: { $0.value === candidate }) { return match.key }
            current = candidate.parent
        }
        return nil
    }

    var hangmanTerminalAtCurrentCell: GridCoordinate? {
        guard hangmanDirections[currentCell] == facing, !hangmanWon else { return nil }
        return currentCell
    }

    func activateHangmanTerminal(at coord: GridCoordinate) {
        guard activeHangmanTerminal == nil, canRotate, coord == currentCell,
              hangmanDirections[coord] == facing, !hangmanWon else { return }
        activeHangmanTerminal = coord
    }

    /// Stepping away without finishing -- same "cancel, don't punish"
    /// idea as cancelSimonTerminal. The overlay's own round state (the
    /// current word, which letters have been guessed) is thrown away
    /// (a fresh HangmanViewModel next time), which is fine -- an
    /// unfinished or failed word never needs to persist between
    /// visits, only that it never blocks retrying.
    func cancelHangmanTerminal() {
        activeHangmanTerminal = nil
    }

    /// Called by HangmanOverlay's view model the instant the PLAYER
    /// taps through a SUCCESS (whole word revealed) result screen.
    /// One-way gate, same shape as completeSimonTerminal -- by the
    /// time this is called the player has already read the result at
    /// their own pace and tapped TAP TO CONTINUE, so it sets the
    /// permanent hangmanWon flag (checked by isMissionComplete),
    /// updates the in-world screen text, and dismisses the overlay
    /// right away rather than on a delay.
    func completeHangmanTerminal(at coord: GridCoordinate) {
        guard activeHangmanTerminal == coord, !hangmanWon else { return }
        hangmanWon = true
        if let node = hangmanTerminalNodes[coord] {
            HallwayScene.setHangmanTerminalStatus("WORD: SOLVED.\n\nELEVATOR ACCESS GRANTED.", on: node)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage("You beat the building! Return to the elevator.")
        activeHangmanTerminal = nil
    }

    // MARK: - Connect Four terminal (Floor 14's embedded mini-game)
    //
    // Eddie, Sept 14: replaces the removed Skee-Ball in the same
    // Floor 14 slot -- a familiar, low-difficulty recognition game
    // rather than a dexterity challenge. Identical shape to every
    // other terminal above -- approach, face it, it activates; the
    // board/turn/AI logic lives in ConnectFourOverlay.swift, this
    // controller only owns activation + the one-way win gate.

    func connectFourTerminalCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let match = connectFourTerminalNodes.first(where: { $0.value === candidate }) { return match.key }
            current = candidate.parent
        }
        return nil
    }

    var connectFourTerminalAtCurrentCell: GridCoordinate? {
        guard connectFourDirections[currentCell] == facing, !connectFourWon else { return nil }
        return currentCell
    }

    func activateConnectFourTerminal(at coord: GridCoordinate) {
        guard activeConnectFourTerminal == nil, canRotate, coord == currentCell,
              connectFourDirections[coord] == facing, !connectFourWon else { return }
        activeConnectFourTerminal = coord
    }

    /// Stepping away without finishing -- same "cancel, don't punish"
    /// idea as cancelHangmanTerminal. The overlay's own round state
    /// (the board, whose turn it is) is thrown away (a fresh
    /// ConnectFourViewModel next time), which is fine -- an unfinished
    /// or lost game never needs to persist between visits, only that
    /// it never blocks retrying.
    func cancelConnectFourTerminal() {
        activeConnectFourTerminal = nil
    }

    /// Called by ConnectFourOverlay's view model the instant the
    /// PLAYER taps through a WIN result screen. One-way gate, same
    /// shape as completeHangmanTerminal -- by the time this is called
    /// the player has already read the result at their own pace and
    /// tapped TAP TO CONTINUE, so it sets the permanent connectFourWon
    /// flag (checked by isMissionComplete), updates the in-world
    /// screen text, and dismisses the overlay right away rather than
    /// on a delay.
    func completeConnectFourTerminal(at coord: GridCoordinate) {
        guard activeConnectFourTerminal == coord, !connectFourWon else { return }
        connectFourWon = true
        if let node = connectFourTerminalNodes[coord] {
            HallwayScene.setConnectFourTerminalStatus("CONNECT FOUR: WON.\n\nELEVATOR ACCESS GRANTED.", on: node)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage("You beat the building! Return to the elevator.")
        activeConnectFourTerminal = nil
    }

    // Floor 15's Checkers terminal -- same shape as the Connect Four
    // cluster right above; board/turn/AI logic lives in
    // CheckersOverlay.swift, this controller only owns activation +
    // the one-way win gate.

    func checkersTerminalCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let match = checkersTerminalNodes.first(where: { $0.value === candidate }) { return match.key }
            current = candidate.parent
        }
        return nil
    }

    var checkersTerminalAtCurrentCell: GridCoordinate? {
        guard checkersDirections[currentCell] == facing, !checkersWon else { return nil }
        return currentCell
    }

    func activateCheckersTerminal(at coord: GridCoordinate) {
        guard activeCheckersTerminal == nil, canRotate, coord == currentCell,
              checkersDirections[coord] == facing, !checkersWon else { return }
        activeCheckersTerminal = coord
    }

    /// Stepping away without finishing -- same "cancel, don't punish"
    /// idea as cancelConnectFourTerminal. The overlay's own round state
    /// (the board, whose turn it is) is thrown away (a fresh
    /// CheckersViewModel next time), which is fine -- an unfinished
    /// or lost game never needs to persist between visits, only that
    /// it never blocks retrying.
    func cancelCheckersTerminal() {
        activeCheckersTerminal = nil
    }

    /// Called by CheckersOverlay's view model the instant the
    /// PLAYER taps through a WIN result screen. One-way gate, same
    /// shape as completeConnectFourTerminal -- by the time this is
    /// called the player has already read the result at their own
    /// pace and tapped TAP TO CONTINUE, so it sets the permanent
    /// checkersWon flag (checked by isMissionComplete), updates the
    /// in-world screen text, and dismisses the overlay right away
    /// rather than on a delay.
    func completeCheckersTerminal(at coord: GridCoordinate) {
        guard activeCheckersTerminal == coord, !checkersWon else { return }
        checkersWon = true
        if let node = checkersTerminalNodes[coord] {
            HallwayScene.setCheckersTerminalStatus("CHECKERS: WON.\n\nELEVATOR ACCESS GRANTED.", on: node)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage("You beat the building! Return to the elevator.")
        activeCheckersTerminal = nil
    }

    // Floor 16's Woidle terminal -- same shape as the Checkers
    // cluster right above; board/keyboard/word logic lives in
    // WoidleOverlay.swift, this controller only owns activation +
    // the one-way win gate.

    func woidleTerminalCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let match = woidleTerminalNodes.first(where: { $0.value === candidate }) { return match.key }
            current = candidate.parent
        }
        return nil
    }

    var woidleTerminalAtCurrentCell: GridCoordinate? {
        guard woidleDirections[currentCell] == facing, !woidleWon else { return nil }
        return currentCell
    }

    func activateWoidleTerminal(at coord: GridCoordinate) {
        guard activeWoidleTerminal == nil, canRotate, coord == currentCell,
              woidleDirections[coord] == facing, !woidleWon else { return }
        activeWoidleTerminal = coord
    }

    /// Stepping away without finishing -- same "cancel, don't punish"
    /// idea as cancelCheckersTerminal. The overlay's own round state
    /// (the board, the typed row) is thrown away (a fresh
    /// WoidleViewModel next time), which is fine -- an unfinished or
    /// lost puzzle never needs to persist between visits, only that
    /// it never blocks retrying.
    func cancelWoidleTerminal() {
        activeWoidleTerminal = nil
    }

    /// Called by WoidleOverlay's view model the instant the PLAYER
    /// taps through a WIN result screen. One-way gate, same shape as
    /// completeCheckersTerminal -- by the time this is called the
    /// player has already read the result at their own pace and
    /// tapped TAP TO CONTINUE, so it sets the permanent woidleWon flag
    /// (checked by isMissionComplete), updates the in-world screen
    /// text, and dismisses the overlay right away rather than on a
    /// delay.
    func completeWoidleTerminal(at coord: GridCoordinate) {
        guard activeWoidleTerminal == coord, !woidleWon else { return }
        woidleWon = true
        if let node = woidleTerminalNodes[coord] {
            HallwayScene.setWoidleTerminalStatus("WORD ASSESSMENT: PASSED.\n\nELEVATOR ACCESS GRANTED.", on: node)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage("You beat the building! Return to the elevator.")
        activeWoidleTerminal = nil
    }

    private func worldPosition(for coord: GridCoordinate) -> SCNVector3 {
        SCNVector3(Float(coord.col) * Float(cellSize), eyeHeight, Float(coord.row) * Float(cellSize))
    }

    // TEMP NAVSYNC DIAGNOSTIC (Eddie, Sept 13):
    // Compare the maze's logical cell/facing with both the camera node's model
    // transform and SceneKit's presentation transform. This deliberately changes
    // NO navigation behavior; it only tells us whether the map/navigation state
    // and what the player is actually seeing have drifted apart.
    private func logNavSync(_ event: String) {
        let expectedLocal = worldPosition(for: currentCell)
        let actualLocal = cameraNode.position
        let presentationLocal = cameraNode.presentation.position

        // cameraNode.position is expressed in its parent's coordinate space.
        // Convert the expected cell center through that same parent so the world
        // comparison remains valid even if the camera ever stops being a direct
        // child of an identity-transformed node.
        let expectedWorld = cameraNode.parent?.convertPosition(expectedLocal, to: nil) ?? expectedLocal
        let actualWorld = cameraNode.worldPosition
        let presentationWorld = cameraNode.presentation.worldPosition

        let localDX = actualLocal.x - expectedLocal.x
        let localDZ = actualLocal.z - expectedLocal.z
        let worldDX = actualWorld.x - expectedWorld.x
        let worldDZ = actualWorld.z - expectedWorld.z

        let safeCellSize = max(Float(cellSize), 0.0001)
        let localCellDX = localDX / safeCellSize
        let localCellDZ = localDZ / safeCellSize

        let actualYaw = Double(cameraNode.eulerAngles.y)
        let presentationYaw = Double(cameraNode.presentation.eulerAngles.y)
        let expectedYaw = facing.yaw
        let yawDelta = shortestDelta(from: actualYaw, to: expectedYaw)

        func v(_ p: SCNVector3) -> String {
            String(format: "(%.3f, %.3f, %.3f)", p.x, p.y, p.z)
        }

        navLog("""
        [NAVSYNC] \(event)
          logical: floor=\(floorNumber) cell=\(currentCell) facing=\(facing) open=\(openDirections)
          expectedLocal=\(v(expectedLocal))
          cameraLocal=\(v(actualLocal)) delta=(\(String(format: "%.3f", localDX)), \(String(format: "%.3f", localDZ))) deltaCells=(\(String(format: "%.3f", localCellDX)), \(String(format: "%.3f", localCellDZ)))
          presentationLocal=\(v(presentationLocal))
          expectedWorld=\(v(expectedWorld))
          cameraWorld=\(v(actualWorld)) worldDelta=(\(String(format: "%.3f", worldDX)), \(String(format: "%.3f", worldDZ)))
          presentationWorld=\(v(presentationWorld))
          yaw expected=\(String(format: "%.3f", expectedYaw)) model=\(String(format: "%.3f", actualYaw)) presentation=\(String(format: "%.3f", presentationYaw)) deltaToExpected=\(String(format: "%.3f", yawDelta))
          state: isAnimating=\(isAnimating) isDragRotating=\(isDragRotating) phase=\(phase) standaloneRotation=\(standaloneRotation) walkingHeld=\(walkingHeld) mapVisible=\(handheldMapVisible)
        """)
    }

    /// Rotate in place to face a new compass direction — the left/right
    /// D-pad buttons. Pure pivot, no movement, and doesn't touch
    /// currentCell/history at all.
    func rotate(toward direction: Direction) {
        if activePictureMenu != nil { cancelPictureMenu() }
        if activePhotoBooth != nil, photoBoothCameraState != "captured" { cancelPhotoBooth() }
        if activeTicTacToeTerminal != nil { cancelTicTacToeTerminal() }
        if activeShellGameTerminal != nil { cancelShellGameTerminal() }
        if activeRockPaperScissorsTerminal != nil { cancelRockPaperScissorsTerminal() }
        if activeHigherLowerTerminal != nil { cancelHigherLowerTerminal() }
        if activeFiveCardDrawTerminal != nil { cancelFiveCardDrawTerminal() }
        if activeSimonTerminal != nil { cancelSimonTerminal() }
        if activeHangmanTerminal != nil { cancelHangmanTerminal() }
        if activeConnectFourTerminal != nil { cancelConnectFourTerminal() }
        if activeCheckersTerminal != nil { cancelCheckersTerminal() }
        if activeWoidleTerminal != nil { cancelWoidleTerminal() }
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
        if activePictureMenu != nil { cancelPictureMenu() }
        if activePhotoBooth != nil, photoBoothCameraState != "captured" { cancelPhotoBooth() }
        if activeTicTacToeTerminal != nil { cancelTicTacToeTerminal() }
        if activeShellGameTerminal != nil { cancelShellGameTerminal() }
        if activeRockPaperScissorsTerminal != nil { cancelRockPaperScissorsTerminal() }
        if activeHigherLowerTerminal != nil { cancelHigherLowerTerminal() }
        if activeFiveCardDrawTerminal != nil { cancelFiveCardDrawTerminal() }
        if activeSimonTerminal != nil { cancelSimonTerminal() }
        if activeHangmanTerminal != nil { cancelHangmanTerminal() }
        if activeConnectFourTerminal != nil { cancelConnectFourTerminal() }
        if activeCheckersTerminal != nil { cancelCheckersTerminal() }
        if activeWoidleTerminal != nil { cancelWoidleTerminal() }
        guard canRotate else {
            navLog("beginDragRotate() ignored -- canRotate=false")
            return
        }
        dragBaseYaw = Double(cameraNode.eulerAngles.y)
        isDragRotating = true
        logNavSync("DRAG TURN BEGIN")
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

    // Eddie, Sept 13: was a flat 50% threshold -- "the positional
    // commit threshold much lower than 50%." Named here (rather than
    // inline) so both feel constants for the release decision below
    // live together and can be retuned as a pair after a device pass.
    // Both are expressed as fractions of the same 90-degree turn
    // updateDragRotate already uses (dragRotateDistance's worth of
    // drag == 1.0), so they stay directly comparable to `fraction`.
    private let turnCommitFraction: Double = 0.30
    // How many seconds of the release's own flick speed get credited
    // toward the position when predicting where the drag was headed --
    // the same idea as a scroll view predicting its settling offset.
    // This is what lets a short, fast flick commit a turn it never
    // physically reached: "the velocity makes the intention completely
    // obvious" even over "perhaps half an inch." At the default 0.30
    // commit threshold this works out to roughly a 350 pts/sec flick
    // (dragRotateDistance's 140pt turn * 0.30 / 0.12s) committing on
    // its own regardless of how little the finger actually traveled.
    private let turnFlickProjectionSeconds: Double = 0.12
    // Below this much real drag, trust the flick's own direction for
    // which way to turn instead of the (near-meaningless) sign of a
    // near-zero position -- purely a sign-disambiguation guard, not a
    // reject-the-gesture dead zone (the projection formula below
    // already handles rejecting genuinely accidental nudges on its own).
    private let turnMinimumSignFraction: Double = 0.03

    /// Call when the finger lifts. Turning uses both displacement and
    /// flick intent: `velocityFraction` is the release velocity in the
    /// same units as `fraction` (a full 90-degree turn's worth of drag
    /// per second), so a short, fast swipe can still commit even if it
    /// never crosses the normal positional threshold on its own -- see
    /// turnFlickProjectionSeconds above. The commit threshold itself is
    /// intentionally well below the old 50%: once the player has
    /// visually turned far enough around a corner, snapping all the way
    /// back feels contrary to the gesture even when released slowly.
    /// Either way, this animates ONLY the remaining angle from wherever
    /// updateDragRotate left the camera to the chosen facing -- it does
    /// not restart a full 90-degree turn, exactly as before.
    func endDragRotate(fraction: Double, velocityFraction: Double = 0) {
        guard isDragRotating else { return }
        isDragRotating = false
        let clamped = max(-1, min(1, fraction))
        let absFraction = abs(clamped)
        let projectedFraction = absFraction + abs(velocityFraction) * turnFlickProjectionSeconds
        let committing = projectedFraction >= turnCommitFraction
        // Direction: trust the actual drag position whenever there's
        // been any real motion to read a sign from; only a near-zero-
        // distance pure flick falls back to the flick's own direction.
        let signSource = absFraction >= turnMinimumSignFraction ? clamped : velocityFraction
        let target: Direction = committing ? (signSource > 0 ? facing.left : facing.right) : facing
        logNavSync("DRAG TURN RELEASE — target=\(target) committing=\(committing)")
        navLog("endDragRotate(fraction: \(String(format: "%.2f", fraction)), velocityFraction: \(String(format: "%.2f", velocityFraction)), projected: \(String(format: "%.2f", projectedFraction))) committing=\(committing) target=\(target)")

        standaloneRotation = true
        pendingRotationTarget = target
        phase = .pivot
        segmentProgress = 0
        pivotStartYaw = Double(cameraNode.eulerAngles.y)
        // On release, animate only from the current dragged yaw to the
        // chosen snapped facing. Do not restart a full 90-degree turn.
        pivotTargetYaw = pivotStartYaw + shortestDelta(from: pivotStartYaw, to: target.yaw)
        isAnimating = true
    }

    /// Silently cancels an in-flight horizontal drag-rotate that a
    /// vertical drag is about to take over, WITHOUT going through
    /// endDragRotate()'s normal commit/pivot-settle path. That matters
    /// because endDragRotate() always sets isAnimating = true (even
    /// when nothing commits, so it can glide the last bit of visual yaw
    /// back to a resting facing) -- exactly right for a real finger-up
    /// release, but wrong for an axis handoff mid-gesture: canRotate
    /// requires !isAnimating, so beginDragMove() called right after
    /// endDragRotate() would refuse to start every single time,
    /// deterministically, before the pivot-settle animation even had a
    /// chance to finish. (This is the bug behind "vertical drag does
    /// nothing" -- see handlePanRotate's axis-lock branch in
    /// ContentView.swift, which now calls this instead of
    /// endDragRotate(fraction: 0).) Axis-lock fires this early in a
    /// gesture, so the drag has barely nudged the yaw at all -- there's
    /// nothing worth animating back, just snap it.
    func cancelDragRotateForAxisHandoff() {
        guard isDragRotating else { return }
        isDragRotating = false
        cameraNode.eulerAngles = SCNVector3(0, Float(dragBaseYaw), 0)
        navLog("cancelDragRotateForAxisHandoff() -- yaw snapped back to dragBaseYaw for vertical handoff")
    }

    /// Positional counterpart of beginDragRotate() -- a vertical drag
    /// scrubs the player's POSITION along whatever direction they're
    /// currently facing, instead of scrubbing their orientation. Facing
    /// itself is frozen for the whole gesture (captured here, never
    /// re-read from `facing` again until the drag ends) so the player
    /// can never be spun by a vertical drag, matching Eddie's spec:
    /// "Preserve the player's facing direction throughout vertical
    /// movement and snapping."
    ///
    /// The full scrub range (how many open cells lie ahead/behind) is
    /// computed ONCE here via openRunLength -- the exact same
    /// maze-cell/door topology openDirections uses, just walked
    /// repeatedly in a straight line -- rather than only checking the
    /// single adjacent cell. That's what lets a single finger-down drag
    /// scrub continuously across several connected cells: Eddie, Sept
    /// 17 ("drag forward 3.5 cells, reverse while still holding, drag
    /// backward 2 cells -- that should be one continuous positional
    /// scrub"). Refuses under the same conditions as beginDragRotate
    /// (canRotate), plus elevatorAwaitingEntryDirection: that state is a
    /// narrow, controller-owned camera offset mid elevator-entry-walk,
    /// not a real grid cell, so dragging through it isn't meaningful --
    /// rotation is unaffected by it (canRotate alone), but a manual
    /// position drag is refused entirely until it clears.
    func beginDragMove() {
        if activePictureMenu != nil { cancelPictureMenu() }
        if activePhotoBooth != nil, photoBoothCameraState != "captured" { cancelPhotoBooth() }
        if activeTicTacToeTerminal != nil { cancelTicTacToeTerminal() }
        if activeShellGameTerminal != nil { cancelShellGameTerminal() }
        if activeRockPaperScissorsTerminal != nil { cancelRockPaperScissorsTerminal() }
        if activeHigherLowerTerminal != nil { cancelHigherLowerTerminal() }
        if activeFiveCardDrawTerminal != nil { cancelFiveCardDrawTerminal() }
        if activeSimonTerminal != nil { cancelSimonTerminal() }
        if activeHangmanTerminal != nil { cancelHangmanTerminal() }
        if activeConnectFourTerminal != nil { cancelConnectFourTerminal() }
        if activeCheckersTerminal != nil { cancelCheckersTerminal() }
        if activeWoidleTerminal != nil { cancelWoidleTerminal() }
        guard canRotate, elevatorAwaitingEntryDirection == nil else {
            navLog("beginDragMove() ignored -- canRotate=\(canRotate) elevatorAwaitingEntryDirection=\(String(describing: elevatorAwaitingEntryDirection))")
            return
        }
        dragMoveFacing = facing
        dragBaseCell = currentCell
        dragBasePosition = cameraNode.position
        dragMoveMaxForwardCells = openRunLength(from: dragBaseCell, direction: dragMoveFacing)
        dragMoveMaxBackwardCells = openRunLength(from: dragBaseCell, direction: dragMoveFacing.opposite)
        isDragMoving = true
        logNavSync("DRAG MOVE BEGIN")
        navLog("beginDragMove() started facing=\(dragMoveFacing) maxForwardCells=\(dragMoveMaxForwardCells) maxBackwardCells=\(dragMoveMaxBackwardCells)")
    }

    /// Call continuously while the finger moves. `fraction` is how far
    /// through one full cell the drag currently represents -- positive
    /// = forward (the direction dragMoveFacing points), matching
    /// Eddie's spec ("drag DOWN = move FORWARD"), and NOT clamped to
    /// +/-1 the way it was originally: it's clamped to
    /// -dragMoveMaxBackwardCells...dragMoveMaxForwardCells, so the
    /// camera can glide continuously across every open cell in the
    /// pre-computed run, only stopping at a genuine wall/door/dead-end
    /// boundary -- never at an ordinary cell boundary in between. This
    /// is deliberately NOT a sequence of discrete one-cell animations:
    /// it's one direct, continuous position write per frame, exactly
    /// like updateDragRotate's continuous yaw write, just summed over
    /// however many cells of travel the drag currently represents.
    // Sept 22 (DECORATE one-cell drag/pinch fix): the real root cause
    // of DECORATE still marching multiple cells after the earlier HELD-
    // timer fix -- this continuous drag-move path (driven by a vertical
    // pan once handlePanRotate's axis lock picks it, AND by handlePinch,
    // which routes pinch in/out through this exact same trio) computes
    // its own multi-cell distance directly from how far the finger
    // physically moved, entirely independent of advance()/
    // advanceWhileHeld() and their decorateModeEnabled caps -- so a
    // single continuous drag or pinch (one physical gesture, start to
    // finish) could already queue and glide through several cells,
    // finishing the glide well after the finger lifted, which is
    // exactly "I press once and it marches on its own." Capping
    // maxForward here (the live preview) AND in endDragMove below (the
    // committed distance) to the same 1-cell ceiling keeps what's
    // dragged on screen and what actually gets walked in sync -- doing
    // it in just one of the two would either preview a multi-cell glide
    // that then snaps back on release, or commit further than what was
    // shown. maxBackward is untouched -- the reported bug and Eddie's
    // spec are both about forward movement only.
    func updateDragMove(fraction: Double) {
        guard isDragMoving else { return }
        let maxForward = decorateModeEnabled ? min(Double(dragMoveMaxForwardCells), 1) : Double(dragMoveMaxForwardCells)
        let maxBackward = Double(dragMoveMaxBackwardCells)
        let clamped = max(-maxBackward, min(maxForward, fraction))
        let delta = dragMoveFacing.delta
        // Same row/col -> world X/Z convention worldPosition(for:) uses
        // (col -> X, row -> Z) -- reused directly rather than
        // reinventing the axis mapping.
        cameraNode.position = SCNVector3(
            dragBasePosition.x + Float(clamped) * Float(delta.col) * Float(cellSize),
            dragBasePosition.y,
            dragBasePosition.z + Float(clamped) * Float(delta.row) * Float(cellSize)
        )
    }

    // Named separately from turnCommitFraction/turnFlickProjectionSeconds/
    // turnMinimumSignFraction above so positional-drag feel can be tuned
    // independently of turn feel, even though "same interaction
    // philosophy" (Eddie's spec) means they start out at matching values.
    private let moveCommitFraction: Double = 0.30
    private let moveFlickProjectionSeconds: Double = 0.12
    private let moveMinimumSignFraction: Double = 0.03

    /// Call when the finger lifts. Same commit/projection logic as
    /// endDragRotate (a short, fast flick can commit further than the
    /// finger physically dragged), generalized from "one cell or none"
    /// to "however many whole cells the (position + flick-projected)
    /// distance represents, plus one more if the leftover fraction past
    /// the last whole cell clears moveCommitFraction" -- the same
    /// 30%-of-a-cell threshold as before, now applied only to that
    /// final partial cell, since every FULLY crossed cell during the
    /// drag itself is already unambiguous. Always clamped to the same
    /// -dragMoveMaxBackwardCells...dragMoveMaxForwardCells range
    /// beginDragMove() computed, so release can never land somewhere
    /// openRunLength didn't already verify was open -- the player is
    /// never left between legal positions, and never ends up past a
    /// real wall/door boundary.
    ///
    /// Reuses the exact same .translate glide advance()/stepBackward()
    /// already use (animationSteps/segmentStart/segmentTarget/phase) --
    /// just with a full multi-cell animationSteps chain when the
    /// release lands more than one cell away, instead of always a
    /// single step -- so arrival handling (currentCell/facing update,
    /// floor map/mission sign viewing per intermediate cell, terminal
    /// activation at the final cell) is the real, single navigation
    /// completion path already used everywhere else, not a second one
    /// invented for drags. Note: unlike a normal advance() run, this
    /// does not truncate early on an uncollected object/unopened chute/
    /// unviewed floor map the way walkToNextDecision-driven walks do --
    /// same scope as stepBackward(), which doesn't either.
    func endDragMove(fraction: Double, velocityFraction: Double = 0) {
        guard isDragMoving else { return }
        isDragMoving = false
        // Sept 22 (DECORATE one-cell drag/pinch fix): same cap as
        // updateDragMove's maxForward above, applied to the committed
        // distance too -- see that function's comment for why both
        // need it. projectedClamped below can now never exceed 1 cell
        // forward in DECORATE, so the whole-cells/remainder math that
        // follows naturally commits to at most 1 step; the final
        // dragMoveMaxForwardCells safety clamp further down is
        // unaffected (still >= 1 whenever a drag was even allowed to
        // begin, since beginDragMove() already required canGoForward).
        let maxForward = decorateModeEnabled ? min(Double(dragMoveMaxForwardCells), 1) : Double(dragMoveMaxForwardCells)
        let maxBackward = Double(dragMoveMaxBackwardCells)
        let clamped = max(-maxBackward, min(maxForward, fraction))
        let projected = clamped + velocityFraction * moveFlickProjectionSeconds
        let projectedClamped = max(-maxBackward, min(maxForward, projected))

        let wholeCells = Int(projectedClamped.rounded(.towardZero))
        let remainder = abs(projectedClamped) - Double(abs(wholeCells))
        var steps = wholeCells
        if remainder >= moveCommitFraction {
            steps += projectedClamped >= 0 ? 1 : -1
        }
        steps = max(-dragMoveMaxBackwardCells, min(dragMoveMaxForwardCells, steps))

        var targetCell = dragBaseCell
        var steppedPath: [NavigationStep] = []
        if steps != 0 {
            let stepDirection = steps > 0 ? dragMoveFacing : dragMoveFacing.opposite
            var cell = dragBaseCell
            for _ in 0..<abs(steps) {
                cell = GridCoordinate(row: cell.row + stepDirection.delta.row, col: cell.col + stepDirection.delta.col)
                steppedPath.append(NavigationStep(cell: cell, heading: dragMoveFacing))
            }
            targetCell = cell
        }

        let outcome: NavigationOutcome
        if targetCell == endCell {
            outcome = .reachedEnd
        } else if steps > 0 {
            outcome = .steppedForward
        } else {
            // steps < 0, or steps == 0 (settled back to dragBaseCell) --
            // steppedBackward already covers "not a real decision
            // point" for the zero-movement case, same as it always has.
            outcome = .steppedBackward
        }
        logNavSync("DRAG MOVE RELEASE — target=\(targetCell) steps=\(steps)")
        navLog("endDragMove(fraction: \(String(format: "%.2f", fraction)), velocityFraction: \(String(format: "%.2f", velocityFraction)), projected: \(String(format: "%.2f", projectedClamped))) steps=\(steps) target=\(targetCell) outcome=\(outcome)")

        animationSteps = steppedPath.isEmpty ? [NavigationStep(cell: dragBaseCell, heading: dragMoveFacing)] : steppedPath
        animationIndex = 0
        pendingOutcome = outcome
        segmentStart = cameraNode.position
        segmentTarget = worldPosition(for: targetCell)
        segmentProgress = 0
        // Eddie, Sept 17: speed up ONLY this release/settle glide, to
        // about 60% of its normal duration -- see translateDurationScale's
        // own comment. Reset back to 1.0 automatically once this glide's
        // final step completes, so no other .translate glide is affected.
        translateDurationScale = 0.6
        phase = .translate
        isAnimating = true
        if targetCell != dragBaseCell { SoundEffects.startWalking() }
    }

    /// One tick of held walking. Use the existing pivot/glide animations;
    /// never queue a walk after the pivot, so releasing cancels continuation.
    private var walkingHeld = false
    private var continuousRun = false
    private var heldDistance: Double = 0
    private(set) var movementPace: Double = 1
    // Sept 22 (DECORATE one-cell hold fix): advance()'s own
    // decorateModeEnabled cap (see its "DECORATE one-cell movement"
    // comment below) already limits any SINGLE advance() call to one
    // grid cell -- but handleLongPressForward's hold timer in
    // ContentView.swift calls advanceWhileHeld() again every 0.12s for
    // as long as the finger stays down, regardless of mode, so a held
    // press in DECORATE was still walking multiple cells one at a time,
    // just via repeated one-cell hops instead of one big queued run.
    // This flag caps advanceWhileHeld() itself to a single forward step
    // per hold gesture when DECORATE is on -- reset the moment a new
    // hold begins (setWalkingHeld(true)) so the very next press is
    // never starved by a previous one. PLAY mode never reads this flag,
    // so its existing hold-to-walk behavior is untouched.
    private var decorateHeldStepTaken = false

    /// Sept 27 (Floor 5 active-fire movement blocker, no.mp3): which
    /// active-fire cell the player has already been told "no" about
    /// during the CURRENT continuous hold, or nil if none yet -- lets
    /// the fire-adjacent back-off in advance() (see its own comment)
    /// play the sound once per blocked encounter instead of once per
    /// 0.12s advanceWhileHeld() tick for as long as the finger stays
    /// down against the same fire. Reset on release (below), exactly
    /// per Eddie's "after the player releases and makes a NEW attempt
    /// ... it may play again" -- a plain discrete tap/D-pad press never
    /// consults this at all (see advance()'s own source-based check),
    /// so separate taps always replay the sound regardless of this flag.
    private var heldBlockedFireCoord: GridCoordinate?

    func setWalkingHeld(_ held: Bool) {
        walkingHeld = held
        if held {
            decorateHeldStepTaken = false
        } else {
            heldDistance = 0
            heldBlockedFireCoord = nil
        }
        if !isAnimating {
            movementPace = 1
            SoundEffects.setWalkingPace(1)
        }
    }

    /// Only an idle, unblocked control state can represent an attempted wall move.
    var forwardIsBlockedByWall: Bool { canRotate && !forwardConnectionIsOpen }

    // Eddie, Sept 13: reported tap-forward playing the wall-thump from
    // a spot (Floor 2, elevator -> mission sign; also seen earlier on
    // Floor 5) where a following long-press then appears to get
    // through and turn. Traced both paths in detail -- advanceWhileHeld's
    // auto-turn-at-an-unambiguous-corner is a real, intentional, already-
    // shipped feature (2136fce, 3b760e2) that advance() (tap) deliberately
    // does not have, and canGoForward/canRotate/openDirections are the
    // exact same computed properties both paths read, recomputed fresh
    // from the maze each call -- no separate/duplicated logic, no cache
    // to go stale, and the renderer's own facing/isAnimating updates
    // apply atomically together on every animated step, so no async
    // window was found where one path could see stale facing the other
    // doesn't. Nothing here proves a concrete root cause yet, so per
    // Eddie: "If you still cannot prove the cause, DO NOT GUESS.
    // Instead, add narrowly targeted diagnostic logging." One line per
    // call, prefixed [NAVDIAG] so it's easy to grep for in Xcode's
    // console, tagged by which input path triggered it -- see the
    // report for exactly what to capture on the next repro.
    private func logNavAttempt(path: String) {
        logNavSync("\(path) INPUT")
        let candidate = GridCoordinate(row: currentCell.row + facing.delta.row, col: currentCell.col + facing.delta.col)
        navLog("[NAVDIAG] path=\(path) cell=\(currentCell) facing=\(facing) cameraYaw=\(String(format: "%.3f", Double(cameraNode.eulerAngles.y))) candidate=\(candidate) candidateOpen=\(cells.contains(candidate)) open=\(openDirections) canGoForward=\(canGoForward) canRotate=\(canRotate) isAnimating=\(isAnimating) isDragRotating=\(isDragRotating) elevatorInUse=\(elevatorInUse) chuteInUse=\(chuteInUse) extinguisherPickupInProgress=\(extinguisherPickupInProgress) extinguishingFires=\(extinguishingFireCoords) handheldMapVisible=\(handheldMapVisible) activePhotoBooth=\(String(describing: activePhotoBooth)) walkingHeld=\(walkingHeld) standaloneRotation=\(standaloneRotation) phase=\(phase)")
    }

    func advanceWhileHeld() {
        logNavAttempt(path: "HELD")
        guard canRotate else { return }
        // Sept 22 (DECORATE one-cell hold fix): once this hold gesture
        // has already taken its one legal step, ignore further HELD
        // ticks from the timer entirely -- no forward advance, no
        // auto-turn-at-corner below -- until the finger lifts and a new
        // hold begins (setWalkingHeld(true) clears the flag). PLAY mode
        // (decorateModeEnabled == false) never hits this guard.
        if decorateModeEnabled, decorateHeldStepTaken { return }
        if canGoForward {
            advance(source: "HELD")
            if decorateModeEnabled { decorateHeldStepTaken = true }
            return
        }
        // Eddie, Sept 16 (remove automatic step-out): no auto-turn
        // fallback while still standing inside the just-arrived
        // elevator -- openDirections describes the REAL hallway cell
        // this hasn't been walked back into yet, not what's actually
        // around the camera right now, so picking a turn from it here
        // would spin the player toward a direction with nothing to do
        // with the cab they're still standing in. Finding the doorway
        // is manual-only until performElevatorEntryWalkOut() clears
        // this.
        guard elevatorAwaitingEntryDirection == nil else { return }
        let turns = [facing.left, facing.right].filter { openDirections.contains($0) }
        // Starting against a wall works just like arriving at one: exactly
        // one side exit is unambiguous, regardless of the passage behind us.
        // Two side exits wait for a swipe; never choose a U-turn automatically.
        guard turns.count == 1 else { return }
        logNavSync("HELD FORCED TURN — about to turn toward \(turns[0])")
        navLog("held walk turning at \(currentCell) from \(facing) toward \(turns[0])")
        rotate(toward: turns[0])
    }

    /// The forward D-pad button (and a bare tap): walks from currentCell
    /// in whatever direction you're currently facing, all the way to
    /// the next real decision, dead end, or the target. `source` is
    /// purely diagnostic (see logNavAttempt above) -- defaults to "TAP"
    /// so every existing call site (the tap gesture, the D-pad button)
    /// is unaffected; advanceWhileHeld() is the only caller that passes
    /// "HELD", when its own forward check already succeeded.
    func advance(source: String = "TAP") {
        logNavAttempt(path: source)
        guard canGoForward else {
            if forwardIsBlockedByWall { SoundEffects.playHitWall() }
            navLog("advance() ignored -- canGoForward=false (isAnimating=\(isAnimating), isDragRotating=\(isDragRotating), elevatorInUse=\(elevatorInUse), facing=\(facing), open=\(openDirections))")
            return
        }

        // Eddie, Sept 16 (remove automatic step-out): canGoForward's
        // own gating above already guarantees facing == elevatorAwaitingEntryDirection
        // here whenever this is non-nil -- the ONE legal forward move
        // while still standing inside the just-arrived elevator is
        // walking straight out through the doorway, back to the real
        // hallway cell center. Not a normal walkToNextDecision() grid
        // step (currentCell never actually changes -- the player was
        // logically always standing at this cell, just physically
        // offset into the cab) -- see performElevatorEntryWalkOut().
        if canReenterArrivedElevator, let center = elevatorEntryCellCenterPosition,
           let direction = elevatorMountDirection {
            let distance = Float(HallwayScene.ElevatorGeometry(cellSize: cellSize).entryDistance)
            let target = SCNVector3(center.x + Float(direction.delta.col) * distance, center.y,
                                    center.z + Float(direction.delta.row) * distance)
            performElevatorThresholdWalk(to: target, entering: true)
            return
        }
        if elevatorAwaitingEntryDirection != nil {
            navLog("advance() walking out of the elevator, facing \(facing)")
            performElevatorEntryWalkOut()
            return
        }

        if !walkingHeld {
            movementPace = 1
            SoundEffects.setWalkingPace(1)
        }
        continuousRun = walkingHeld && source != "MISSION_ARRIVAL"
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
        // Eddie, Sept 16 (fix -- was direction-based, wrongly):
        // identifies the ONE call that performs the automatic
        // front-door-to-elevator opening walk, not "any northbound
        // walk before the flag flips." ContentView marks that single
        // call with source: "CEREMONIAL".
        //
        // Eddie, Sept 17: dropped the "&& !hasCompletedInitialEntrance"
        // belt-and-suspenders clause that used to sit here -- the
        // ceremonial walk (and its suppression of the picture/mirror
        // stops below) is no longer one-time, and that clause would
        // now silently defeat suppression on every entrance after the
        // first, since hasCompletedInitialEntrance is set true right
        // after that first walk and never reset. source == "CEREMONIAL"
        // alone already identifies the single call this needs to catch
        // (see the comment above), so it's the whole condition now.
        let isCeremonialEntrance = source == "CEREMONIAL"
        // Sept 27 (Room Entrance navigation-gating fix): walkToNextDecision
        // (MazeNavigation.swift) computes this straight-line run from
        // GRID TOPOLOGY ALONE (plain `cells` membership) -- it has no
        // concept of bathroomDoors/windowRooms/roomEntranceDoors, open
        // or closed, at all. openDirections/openRunLength (single-step
        // legality, and beginDragMove's own separate scrub-range
        // calculation) already gate correctly on all three door
        // families, but THIS is the one place that turns
        // walkToNextDecision's raw topology-only steps into the queued
        // multi-cell runSteps that every tap-forward AND held/
        // long-press walk actually executes (handleLongPressForward
        // just calls this same advance(source: "HELD") on a repeating
        // timer -- not a separate movement system), and until now
        // nothing here ever consulted door state either.
        //
        // This gap has always existed for every swinging-door family,
        // build-time-authored or live-Decorator-authored alike -- it
        // never surfaced for bathroom/Window Room doors only because
        // every existing bathroom/window room is a side room reached
        // by turning off a straight hallway, and turning is ALREADY a
        // fork/forced-turn stop under walkToNextDecision's own
        // topology rules, so those walks always stopped one cell short
        // of the door for unrelated reasons before this gap could ever
        // matter. A Room Entrance placed in-line across an ordinary
        // straight hallway connection -- exactly Eddie's own test
        // scenario, and exactly what "hallway cell -> door -> one
        // ordinary cell" is meant to look like -- is a dead-straight
        // pass-through by topology alone, so walkToNextDecision swept
        // right through it. Single-step-adjacent taps into a closed
        // Room Entrance were never affected -- canGoForward's own
        // forwardConnectionIsOpen already reads openDirections, which
        // already gates correctly -- only a multi-cell run could ever
        // sweep past the boundary mid-glide.
        //
        // Walks `steps` (not runSteps -- there's nothing to build on
        // yet) looking for the FIRST transition that crosses a closed
        // Room Entrance boundary, using the exact same anchor/open-set
        // check openDirections/openRunLength already use for a single
        // step, just generalized across the whole queued run. Truncates
        // there -- never entering the far cell -- and reuses
        // .steppedForward for the outcome: Eddie, "it is simply a
        // closed door," no popup, no special sound, the same neutral
        // outcome a manual one-cell step already uses. If the very
        // first step is already gated, gatedSteps comes back empty
        // (defensive only -- canGoForward's own gate above already
        // catches this ordinary case first, with the same "hit wall"
        // thump any solid wall gets, never a fire-style "no" sound).
        var gatedSteps = steps
        var gatedOutcome = outcome
        do {
            var previousCell = currentCell
            for (index, step) in steps.enumerated() {
                if let anchor = roomEntranceDoorAnchor(from: previousCell, direction: step.heading), !openRoomEntranceDoors.contains(anchor) {
                    gatedSteps = Array(steps[0..<index])
                    gatedOutcome = .steppedForward
                    break
                }
                previousCell = step.cell
            }
        }
        guard !gatedSteps.isEmpty else {
            navLog("advance() from \(currentCell) facing \(facing) -- already one cell short of a closed Room Entrance, nothing to walk")
            return
        }

        var runSteps = gatedSteps
        var runOutcome = gatedOutcome
        if let stopIndex = gatedSteps.firstIndex(where: { step in
            let coord = step.cell
            // Sept 27 (Money is no longer a movement stop): reverses
            // Eddie's own Sept 6 decision below, for Money ONLY -- "Money
            // must NOT be a movement stop... RUN THROUGH MONEY -> COLLECT
            // -> KEEP GOING." kind.cashValue(onFloor:) is the exact
            // existing "is this Money" predicate this file already uses
            // elsewhere (performPickup's instant-absorb branch, cashValue's
            // own doc comment) -- nil for every kind but cash, so this
            // doesn't touch envelope/key/heart/star/any other hanging
            // pickup, which all still stop the walk exactly as before.
            // Money's own collection is untouched: applyArrival's
            // collectObjectIfPresent(at:) still fires for every cell the
            // glide crosses, mid-run steps included (see its own call
            // site), so a Money cell excluded from stopIndex here still
            // gets collected at the exact moment the player passes
            // through it -- this only stops IT from truncating/ending the
            // queued walk early.
            //
            // Cash used to be excluded here on purpose (instant-absorb,
            // keep walking) -- Eddie, Sept 6: grabbing money should
            // pause you in the celebration, same as every other pickup
            // and the wall map/chute, not sweep the payoff past you
            // mid-glide. So this is now genuinely "anything not yet
            // collected," carried or not.
            // Sept 24 (held-walk bypass): a held walk never truncates for
            // a tap-to-collect object -- it can only be collected by a
            // deliberate tap, which can't happen mid-hold, so the glide
            // passes straight over it (that IS the Sept 21 "Choice B: walk
            // past" outcome), keeping the segment unbroken. Cash used to
            // be deliberately still a stop even so (Sept 6/Sept 25) --
            // superseded by the Sept 27 comment above, for cash only.
            // Sept 25: that last line now holds for every hanging pickup,
            // not just cash -- hangsFromCeiling kinds (mail included)
            // auto-collect on arrival, so they stop the walk too.
            if let kind = objectKinds[coord], !collectedCoords.contains(coord),
               kind.cashValue(onFloor: floorNumber) == nil,
               !(walkingHeld && kind.requiresTapToCollect) {
                return true
            }
            if extinguisherCoords[coord] != nil, !carryingExtinguisher {
                return true
            }
            if fireCoords.contains(coord), !extinguishedFireCoords.contains(coord) {
                return true
            }
            if destinationKinds[coord] != nil {
                return true // an unopened chute -- worth stopping for whether or not you're carrying anything, so there's always a chance to tap the door
            }
            if floorMapCoords.contains(coord), !walkingHeld {
                return true // Stop at wall maps on every pass -- held walking glides over them (you can't read a map mid-hold).
            }
            if missionSignCoords.contains(coord), !viewedMissionSignCoords.contains(coord) {
                return true // the Floor Mission sign, first pass this run
            }
            // Sept 24 (room-door knock interaction): ALL room doors stop
            // the walk -- functional mail doors AND decorative/
            // architectural doors alike. The earlier decorative-door
            // authoring pass briefly made decorative doors glide-through
            // (empty-wall locomotion); Eddie closed that: a door is a
            // door is a door -- every room door is a genuine stop, so
            // there is always a real "tap the visible door" moment
            // stopped beside it, whether the door carries a room
            // number's mail game or is Floor 2 architectural dressing.
            if roomDoors[coord] != nil { return true }
            // Floor 1's decorative lobby pairs are at rows 11 and 13.
            // Always stop beside them -- in EITHER direction, on EVERY
            // walk -- except during the one call that performs the
            // automatic front-door-to-elevator opening walk itself (see
            // isCeremonialEntrance above). Eddie, Sept 16: "Hallways
            // introduces itself once... The suppression is NOT based on
            // direction... It applies ONLY to that single automatic
            // traversal." Every other walk, in both directions, stops
            // normally -- including a later northbound walk toward the
            // elevator, which used to be silently exempted forever.
            if floorNumber == 1, coord.col == 7, [11, 13].contains(coord.row) {
                // Diagnostic only, no behavior change -- Eddie, Sept 17:
                // pinning down why a suppression that should apply here
                // isn't. Prints every value the decision depends on at
                // the exact moment this cell is evaluated.
                navLog("[ENTRANCE-DIAG] lobby cell \(coord) source=\(source) hasCompletedInitialEntrance=\(hasCompletedInitialEntrance) floorNumber=\(floorNumber) heading=\(step.heading) isCeremonialEntrance=\(isCeremonialEntrance)")
                if !isCeremonialEntrance { return true }
            }
            if pictureCoords.contains(coord) {
                // Sept 24: held walking never stops for a picture/mirror --
                // nothing to act on mid-hold, so the glide stays unbroken.
                // Tap walking keeps its per-pass stop on every floor.
                return !walkingHeld && (floorNumber != 1 || !isCeremonialEntrance)
            }
            if photoBoothCoords.contains(coord), !completedPhotoBooths.contains(coord) {
                return true
            }
            if ticTacToeTerminalCoords.contains(coord), !ticTacToeWon {
                return true
            }
            if shellGameStationCoords.contains(coord), !shellGameWon {
                return true
            }
            if rockPaperScissorsTerminalCoords.contains(coord), !rockPaperScissorsWon {
                return true
            }
            if higherLowerTerminalCoords.contains(coord), !higherLowerWon {
                return true
            }
            if fiveCardDrawTerminalCoords.contains(coord), !fiveCardDrawWon {
                return true
            }
            if simonTerminalCoords.contains(coord), !simonWon {
                return true
            }
            if hangmanTerminalCoords.contains(coord), !hangmanWon {
                return true
            }
            if connectFourTerminalCoords.contains(coord), !connectFourWon {
                return true
            }
            if checkersTerminalCoords.contains(coord), !checkersWon {
                return true
            }
            if woidleTerminalCoords.contains(coord), !woidleWon {
                return true
            }
            return false
        }), stopIndex < gatedSteps.count - 1 {
            runSteps = Array(gatedSteps[0...stopIndex])
            let stopCoord = runSteps.last!.cell
            if let kind = objectKinds[stopCoord], !collectedCoords.contains(stopCoord) {
                runOutcome = .pickedUpObject
            } else if (extinguisherCoords[stopCoord] != nil && !carryingExtinguisher) ||
                        (fireCoords.contains(stopCoord) && !extinguishedFireCoords.contains(stopCoord)) {
                runOutcome = .fire
            } else if destinationKinds[stopCoord] != nil {
                runOutcome = .delivered
            } else if floorMapCoords.contains(stopCoord) {
                runOutcome = .viewedMap
            } else if missionSignCoords.contains(stopCoord), !viewedMissionSignCoords.contains(stopCoord) {
                runOutcome = .viewedMissionSign
            } else if roomDoors[stopCoord] != nil {
                runOutcome = .viewedRoomDoor
            } else if photoBoothCoords.contains(stopCoord) {
                runOutcome = .viewedPicture
            } else {
                runOutcome = .viewedPicture
            }
        }

        if source == "MISSION_ARRIVAL" {
            runSteps = Array(runSteps.prefix(1))
            runOutcome = .steppedForward
        }

        // Sept 21 (stop-before-tap-pickup-object): whatever produced
        // runSteps above -- an early truncation from the stopIndex scan,
        // OR the untouched natural end of the walk (dead end/fork/
        // destination), which that scan's own `stopIndex < gatedSteps.count - 1`
        // guard deliberately does NOT cover -- if the walk's last step
        // would land ON an uncollected object that now requires a
        // deliberate tap (everything that does NOT hang -- trash can
        // and paint bucket -- see ObjectKind.requiresTapToCollect),
        // back off one cell instead of
        // entering it. Because the player was traveling toward that
        // cell, this leaves them facing it -- PLAYER -> OBJECT -- ready
        // for isWithinTapRange/collectByTap. Checked as a single
        // post-processing step against runSteps.last, rather than
        // reworked into the stopIndex math above, so both cases (early
        // truncation and natural end) are handled uniformly without
        // duplicating the scan. Cash is untouched here:
        // kind.requiresTapToCollect is false for cash100, so it keeps
        // its existing walk-into-instant-absorb behavior exactly as
        // before -- and Sept 25, the same now holds for every hanging
        // pickup (mail included), which auto-collect on arrival. Pictures/wall displays are untouched too -- they're
        // never in objectKinds, so this check never fires for them.
        //
        // Sept 21 (present-once-then-allow-pass -- fixes the "pickup
        // object becomes a locked door" bug Eddie found on device): the
        // FIRST time a walk stops short of a given object, presentedPickupCoord
        // remembers that coordinate. If the very next advance() call's
        // walk would ALSO stop at that exact same coordinate -- i.e. the
        // player tapped forward again without collecting it or turning
        // away -- that is Choice B: a deliberate decision to walk past
        // rather than collect. This one time, skip the back-off (the
        // existing stopIndex truncation above already caps the walk at
        // the object's own cell, never beyond it -- same "hand control
        // back, wait for the next tap" idiom every other stop in this
        // function already uses), consume the flag, and mark it
        // .steppedForward (a plain manual step -- nothing was picked
        // up, so .pickedUpObject would be misleading here). Choice A
        // (tapping the physical object) never goes through advance() at
        // all -- it's collectByTap, entirely separate -- so it's
        // unaffected by any of this. Cleared on rotate()/stepBackward()/
        // reset() so turning away or backing up re-presents the object
        // fresh rather than leaving a stale "already declined" memory.
        // Sept 24 (held-walk bypass): the present-once back-off exists so a TAP
        // that would otherwise land on an uncollected object stops one short
        // to present it. A held walk performs no presentation (the stop scan
        // above already lets it glide over these), so backing off mid-hold
        // would just re-introduce the stall at every object.
        if let lastCoord = runSteps.last?.cell, let kind = objectKinds[lastCoord],
           !collectedCoords.contains(lastCoord), kind.requiresTapToCollect,
           !walkingHeld, source != "MISSION_ARRIVAL" {
            if presentedPickupCoord == lastCoord {
                presentedPickupCoord = nil
                runOutcome = .steppedForward
            } else {
                presentedPickupCoord = lastCoord
                runSteps.removeLast()
                guard !runSteps.isEmpty else {
                    navLog("advance() from \(currentCell) facing \(facing) -- already one cell short of pickup object at \(lastCoord), nothing to walk")
                    return
                }
            }
        } else {
            presentedPickupCoord = nil
        }

        // Sept 27 (fire adjacent/tap model): an active (unextinguished)
        // fire moves onto the same adjacent-stop idea as the
        // requiresTapToCollect back-off just above, but as a permanent
        // hard block, not present-once-then-allow-pass -- an active
        // fire must never be entered at all (Eddie: "the player must
        // NOT enter the active fire cell"), so there is no walk-past
        // exception and no walkingHeld bypass either: fire already
        // stopped a held walk dead at its own cell (see the stopIndex
        // scan above, which -- unlike the requiresTapToCollect check
        // right before it -- has no `!walkingHeld` clause), this just
        // moves that same stop one cell earlier so the player is never
        // standing IN it, held walk or tap walk alike. Checked as its
        // own post-processing step against runSteps.last, same reason
        // the trash-can block above is: covers both the early-truncation
        // case (stopIndex scan above already set runOutcome = .fire) and
        // the natural-end case (a fire cell that happens to BE the walk's
        // natural dead end/fork), uniformly, without duplicating the
        // scan. Extinguishing itself is untouched -- extinguishFire's
        // existing canReachFireFixture already reaches one cell ahead,
        // so a direct tap on the visible fire node (or a plain forward
        // tap once truly adjacent, via activeFireAtCurrentCell) still
        // performs the exact same extinguish action as before; only
        // where the approaching WALK stops has changed.
        if let lastCoord = runSteps.last?.cell, fireCoords.contains(lastCoord),
           !extinguishedFireCoords.contains(lastCoord) {
            runSteps.removeLast()
            guard !runSteps.isEmpty else {
                // Sept 27 (Floor 5 active-fire movement blocker,
                // no.mp3): this is the narrowest authoritative point an
                // attempted forward move into an ACTIVE fire is
                // rejected -- currentCell was already exactly one cell
                // short (the walk this call planned had nothing before
                // the fire to fall back to), so this is a genuine
                // blocked ATTEMPT, not merely arriving adjacent (that
                // case falls through below instead, with a non-empty
                // runSteps and no sound). A held gesture (source ==
                // "HELD") re-enters this exact branch every ~0.12s tick
                // for as long as the finger stays down and blocked --
                // heldBlockedFireCoord suppresses every repeat after the
                // first for THIS coordinate, cleared on release (see
                // setWalkingHeld) so a later new hold attempt plays
                // again. A discrete tap/D-pad press (any other source)
                // never consults that flag, so separate deliberate
                // attempts always replay it, per Eddie's spec.
                if source == "HELD" {
                    if heldBlockedFireCoord != lastCoord {
                        heldBlockedFireCoord = lastCoord
                        SoundEffects.playNo()
                    }
                } else {
                    SoundEffects.playNo()
                }
                navLog("advance() from \(currentCell) facing \(facing) -- already one cell short of active fire at \(lastCoord), nothing to walk")
                return
            }
        }

        // Sept 21 (DECORATE one-cell movement): DECORATE never
        // auto-walks -- a single forward tap advances at most one grid
        // cell, however many steps walkToNextDecision (and the trim
        // just above) would otherwise have queued, so Eddie can stop
        // exactly one cell short of whatever he's about to decorate
        // (a ceiling light, a picture, anything ahead) without a
        // "Current Cell" concept or new UI. Reuses .steppedForward --
        // the existing outcome for a manual one-cell hop (endDragMove's
        // drag-commit case) -- so this doesn't fire the .intersection-only
        // "you now have a direction to choose" haptic, and doesn't
        // invent a new outcome case. Turning/vertical scout/object
        // selection/ADD/SETTINGS/DELETE/inspectors are all untouched --
        // this is the one place DECORATE constrains the shared
        // movement planner, not a parallel navigation system. When OFF,
        // decorateModeEnabled is false and this is a no-op; PLAY mode's
        // multi-cell walking (and the trim above) is exactly as before.
        if decorateModeEnabled, runSteps.count > 1 {
            runSteps = Array(runSteps.prefix(1))
            runOutcome = .steppedForward
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
        // Floor 1 polish pass (Sept 21): the ceremonial front-door ->
        // elevator walk only -- reuses the exact same self-resetting
        // translateDurationScale multiplier the drag-move settle glide
        // already uses (see its own Sept 17 comment just above in this
        // file), just the other direction (slower, not faster). Scoped
        // to isCeremonialEntrance alone, so ordinary walking speed
        // (travelSpeed) and every other glide are untouched -- this
        // one queued run divides its duration by 1.7 less, i.e. takes
        // ~1.7x as long, then the .translate case's own existing
        // "reset to 1.0 once this glide's final step completes" logic
        // (unconditional, not conditioned on this flag) puts it right
        // back to normal for the very next walk. Eddie: "noticeably
        // slower so the opening reveal has time to breathe."
        if isCeremonialEntrance {
            translateDurationScale = 1.7
        }
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
        setWalkingHeld(false)
        continuousRun = false
        // Sept 21 (present-once-then-allow-pass): backing away from a
        // just-presented object shouldn't silently count as declining
        // it -- see presentedPickupCoord's own doc comment.
        presentedPickupCoord = nil
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
        defer { refreshElevatorMissionSign() }
        setWalkingHeld(false)
        movementPace = 1
        SoundEffects.setWalkingPace(1)
        handheldMapVisible = false
        paintedCells.removeAll()
        hasPaintBucket = false
        wallPainter?.reset()
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
        carriedExtinguisherNode?.removeFromParentNode()
        carriedExtinguisherNode = nil
        carryingExtinguisher = false
        completedPhotoBooths.removeAll()
        activePhotoBooth = nil
        photoBoothCompletionImage = nil
        photoBoothCameraState = nil
        for (coord, node) in photoBoothNodes {
            if let prompt = photoBoothExpressions[coord]?.prompt {
                HallwayScene.resetPhotoBoothScreen(on: node, prompt: prompt)
            }
        }
        ticTacToeWon = false
        activeTicTacToeTerminal = nil
        for node in ticTacToeTerminalNodes.values {
            HallwayScene.resetTicTacToeTerminalScreen(on: node)
        }
        shellGameWon = false
        activeShellGameTerminal = nil
        for node in shellGameStationNodes.values {
            HallwayScene.resetShellGameStationScreen(on: node)
        }
        rockPaperScissorsWon = false
        activeRockPaperScissorsTerminal = nil
        for node in rockPaperScissorsTerminalNodes.values {
            HallwayScene.resetRockPaperScissorsTerminalScreen(on: node)
        }
        higherLowerWon = false
        activeHigherLowerTerminal = nil
        for node in higherLowerTerminalNodes.values {
            HallwayScene.resetHigherLowerTerminalScreen(on: node)
        }
        fiveCardDrawWon = false
        activeFiveCardDrawTerminal = nil
        for node in fiveCardDrawTerminalNodes.values {
            HallwayScene.resetFiveCardDrawTerminalScreen(on: node)
        }
        simonWon = false
        activeSimonTerminal = nil
        for node in simonTerminalNodes.values {
            HallwayScene.resetSimonTerminalScreen(on: node)
        }
        hangmanWon = false
        activeHangmanTerminal = nil
        for node in hangmanTerminalNodes.values {
            HallwayScene.resetHangmanTerminalScreen(on: node)
        }
        connectFourWon = false
        activeConnectFourTerminal = nil
        for node in connectFourTerminalNodes.values {
            HallwayScene.resetConnectFourTerminalScreen(on: node)
        }
        checkersWon = false
        activeCheckersTerminal = nil
        for node in checkersTerminalNodes.values {
            HallwayScene.resetCheckersTerminalScreen(on: node)
        }
        woidleWon = false
        activeWoidleTerminal = nil
        for node in woidleTerminalNodes.values {
            HallwayScene.resetWoidleTerminalScreen(on: node)
        }
        fireInteractionID = UUID()
        if !fireCoords.isEmpty { SoundEffects.stopExtinguisherSpray() }
        pickedUpExtinguisherCoords.removeAll()
        extinguishingFireCoords.removeAll()
        extinguisherPickupInProgress = false
        extinguishedFireCoords.removeAll()
        fireNodes.values.forEach {
            $0.removeAllActions()
            $0.isHidden = false
            $0.opacity = 1
            $0.scale = SCNVector3(1, 1, 1)
            $0.runAction(.repeatForever(.sequence([
                .group([.rotateBy(x: 0, y: 0.16, z: 0, duration: 0.22), .scale(to: 1.08, duration: 0.22)]),
                .group([.rotateBy(x: 0, y: -0.16, z: 0, duration: 0.22), .scale(to: 0.94, duration: 0.22)])
            ])), forKey: "fireAnimation")
        }
        extinguisherNodes.forEach { coord, node in
            node.removeAllActions()
            if let resting = extinguisherRestingTransforms[coord] {
                node.position = resting.position
                node.eulerAngles = resting.eulerAngles
                node.scale = resting.scale
            }
            node.opacity = 1
            scene?.rootNode.addChildNode(node)
        }

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
        presentedPickupCoord = nil

        carriedMail.removeAll()
        deliveredMail.removeAll()
        chuteRunID = UUID()
        chuteInUse = false
        refreshElevatorMissionSign()
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

        if elevatorAwaitingEntryDirection != nil {
            navLog("reset() cancelling an in-progress elevator entry, snapping to the cell center")
            cameraNode.removeAllActions()
            if let target = elevatorEntryCellCenterPosition {
                cameraNode.position = target
            }
            elevatorAwaitingEntryDirection = nil
            elevatorEntryCellCenterPosition = nil
        }

        if arrivedElevatorDoorOpen {
            cameraNode.removeAction(forKey: "elevatorManualWalkOut")
            elevatorLeftDoor?.position = elevatorLeftClosedPosition ?? SCNVector3Zero
            elevatorRightDoor?.position = elevatorRightClosedPosition ?? SCNVector3Zero
            arrivedElevatorDoorOpen = false
            elevatorEntryCellCenterPosition = nil
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

    /// The actual pickup: kind-specific side effects (mail's room
    /// check, paint bucket's flag), collectedCoords/objectNodes
    /// bookkeeping, the confirmation haptic, and cash/trash's own
    /// sound+callback branches -- unchanged from before Sept 21
    /// (deliberate tap-to-pick-up), just pulled out of
    /// collectObjectIfPresent's body so BOTH entry points below (cell
    /// arrival, for cash; a direct tap, for everything else -- see
    /// ObjectKind.requiresTapToCollect) can share it. This is
    /// deliberately the only place that does the actual collecting --
    /// it doesn't re-decide WHETHER this pickup should count (that's
    /// each caller's own job), only WHAT happens once it does.
    private func performPickup(kind: ObjectKind, at coord: GridCoordinate) {
        if kind == .envelope {
            // Sept 24 (decorative room doors): a letter is only pickable
            // when SOME mailable (functional) door carries its address.
            // A decorative door's number can never become a deliverable
            // address, so a legacy/hand-authored letter mistakenly
            // addressed to one is refused here rather than picked up and
            // stranded forever in the carry list by a door that will
            // never accept it.
            guard let room = itemRooms[coord], roomDoors.values.contains(where: { !$0.isDecorative && $0.roomNumber == room }) else {
                showMessage("This letter needs a valid room address in the editor.")
                return
            }
            carriedMail.append(CarriedRoomItem(id: coord, roomNumber: room))
            SoundEffects.playMailPickup()
        }
        if kind == .paintBucket {
            hasPaintBucket = true
            showMessage("Blue paint ready. Walk through every hallway; maps show your progress.")
        }
        collectedCoords.insert(coord)
        objectNodes[coord]?.removeFromParentNode()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let value = kind.cashValue(onFloor: floorNumber) {
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

    /// Called whenever a walk lands on a cell -- both mid-walk and on
    /// the final step. Sept 21 (deliberate tap-to-pick-up): this is now
    /// ONLY the arrival-triggers-collection path for kinds that don't
    /// require a tap -- cash (ObjectKind.requiresTapToCollect ==
    /// false), which keeps its original "walk into it, instantly
    /// absorbed" design untouched; Sept 25, every hanging pickup joins
    /// it (see hangsFromCeiling), so walked-through mail/envelopes and
    /// the other spinning kinds auto-collect exactly like cash. Every
    /// other kind's actual pickup now
    /// happens through collectByTap below instead; simply walking onto
    /// their cell here is a no-op for the pickup itself, but
    /// paintIfCarryingBucket/refreshFloorMapTexture (unrelated to
    /// picking THIS cell's object up) still run on every arrival
    /// exactly as before, via the same defer.
    private func collectObjectIfPresent(at coord: GridCoordinate) {
        defer {
            paintIfCarryingBucket(at: coord)
            refreshFloorMapTexture()
        }
        guard let kind = objectKinds[coord], !collectedCoords.contains(coord), !kind.requiresTapToCollect else { return }
        // In Decorate, money remains an authored object even when walked through.
        guard !(decorateModeEnabled && kind == .cash100) else { return }
        performPickup(kind: kind, at: coord)
    }

    /// Sept 21 (facing-aware pickup revision -- supersedes this
    /// function's original Chebyshev-distance version from earlier the
    /// same day): true only when `coord` is the SINGLE cardinal cell
    /// directly in front of the player's current facing --
    /// PLAYER -> OBJECT, nothing else. Eddie, after seeing Floor Object
    /// placement on device: no diagonal pickup, no pickup of an object
    /// behind the player, no pickup merely because an object is beside
    /// the player -- the player must turn to face it first. Unlike
    /// canReachFireFixture just below in this file, deliberately does
    /// NOT accept `coord == currentCell` -- standing ON the object's
    /// cell is not "one cell ahead," and normal walking no longer ever
    /// enters a tap-required object's cell anyway (see advance()'s
    /// post-processing trim). Pure grid-coordinate math -- no
    /// wall/reachability awareness, same as canReachFireFixture itself.
    private func isWithinTapRange(of coord: GridCoordinate) -> Bool {
        let delta = facing.delta
        return coord == GridCoordinate(row: currentCell.row + delta.row, col: currentCell.col + delta.col)
    }

    /// Maps a hit-tested SceneKit node back to the object's cell, if
    /// any -- same "walk node.parent looking for an identity match"
    /// shape fireCoordinate/extinguisherCoordinate use further down in
    /// this file. Matches on the object's own root node or its real
    /// visible parts (e.g. the trash can's SCNCone/SCNTube/SCNCylinder
    /// body), since objectNodes stores exactly the root
    /// HallwayScene.build(fromMaze:) parents to the scene.
    ///
    /// Sept 21 (gameplay hit-area fix): deliberately does NOT match
    /// through makeDecoratorHitProxy -- that child is a generously
    /// sized (cellSize * 0.9) invisible floor plate meant for easy
    /// DECORATE *selection* (DecoratorState.select(at:in:), which walks
    /// this exact same node.parent shape and is untouched by this
    /// guard). On device, tapping almost anywhere on the floor near a
    /// trash can -- well beyond its visible geometry -- was triggering
    /// gameplay pickup through that same oversized proxy. Rejecting a
    /// hit that lands ON the proxy itself (never on a deeper descendant
    /// -- it's a leaf node) forces gameplay pickup to require an actual
    /// tap on the object's own visible geometry, while leaving DECORATE
    /// selection exactly as forgiving as it already was.
    func objectCoordinate(for node: SCNNode) -> GridCoordinate? {
        if node.name == "decoratorHitProxy" || node.name == "hangingPickupString" { return nil }
        var candidate: SCNNode? = node
        while let current = candidate {
            if let match = objectNodes.first(where: { $0.value === current }) {
                return match.key
            }
            candidate = current.parent
        }
        return nil
    }

    /// Sept 21 (Floor Object current-cell authoring): registers a Floor
    /// Object added live via Decorator (DecoratorState.addFloorObject)
    /// into the SAME objectKinds/objectNodes bookkeeping every
    /// build-time object already has here -- same shape registerPicture
    /// just above uses for pictureCoords/pictureFaces -- so
    /// ordinary gameplay pickup (isWithinTapRange/collectByTap,
    /// objectCoordinate above) and the stop-before/present-once-then-
    /// pass walk logic in advance() both see it immediately, no floor
    /// reload needed. objectKinds/objectNodes were changed from `let`
    /// to `var` to allow this.
    func registerFloorObject(_ kind: ObjectKind, at coord: GridCoordinate, node: SCNNode) {
        objectKinds[coord] = kind
        objectNodes[coord] = node
    }

    /// Sept 27 (Decorator delete-staleness fix): the reverse of
    /// registerFloorObject above. DecoratorState.deleteFloorObject
    /// already removes the SCNNode and MazeStore's persisted placement,
    /// but never removed the entry from objectKinds/objectNodes here --
    /// so a deleted Trash Can/Envelope/Paint Bucket kept counting toward
    /// mission progress (objectKinds still non-nil for its coord) and
    /// kept drawing on the live floor map (currentFloorMapImage reads
    /// objectKinds directly) until the floor was fully rebuilt. Also
    /// drops the coord from collectedCoords so a deleted-after-collected
    /// object can't leave a stale entry behind either.
    func unregisterFloorObject(at coord: GridCoordinate) {
        objectKinds.removeValue(forKey: coord)
        objectNodes.removeValue(forKey: coord)
        collectedCoords.remove(coord)
        refreshFloorMapTexture()
    }

    /// Sept 21 (deliberate tap-to-pick-up): the tap-driven counterpart
    /// of collectObjectIfPresent's cell-arrival path, for every kind
    /// that requires a tap (everything except cash). Called from
    /// ContentView's Coordinator.handleTap when a hit-test lands on a
    /// pickup-able object's own node -- see that call site's own
    /// comment for why DECORATE mode can never reach this. canRotate
    /// mirrors pickUpExtinguisher/extinguishFire's own precondition
    /// (no menu/terminal open, not mid-animation, etc.); isWithinTapRange
    /// is the "within one grid cell" rule. Delegates the actual pickup
    /// to performPickup, unchanged -- this function's only job is
    /// deciding WHETHER a tap counts, never what happens once it does.
    @discardableResult
    func collectByTap(at coord: GridCoordinate) -> Bool {
        guard canRotate, let kind = objectKinds[coord], kind.requiresTapToCollect,
              !collectedCoords.contains(coord), isWithinTapRange(of: coord) else { return false }
        performPickup(kind: kind, at: coord)
        refreshFloorMapTexture()
        return true
    }

    private func collectExtinguisherIfPresent(at coord: GridCoordinate) {
        guard extinguisherCoords[coord] != nil,
              !carryingExtinguisher,
              !extinguisherPickupInProgress,
              let wallNode = extinguisherNodes[coord] else { return }
        extinguisherPickupInProgress = true
        let interactionID = fireInteractionID
        wallNode.removeAllActions()
        wallNode.runAction(.sequence([
            .group([
                .moveBy(x: 0, y: 0.04, z: 0.28, duration: 0.24),
                .rotateBy(x: 0, y: 0, z: -.pi / 8, duration: 0.24),
                .scale(to: 1.08, duration: 0.24)
            ]),
            .fadeOut(duration: 0.12),
            .run { [weak self, weak wallNode] _ in
                DispatchQueue.main.async {
                    guard let self, self.fireInteractionID == interactionID else { return }
                    wallNode?.removeFromParentNode()
                    self.pickedUpExtinguisherCoords.insert(coord)
                    self.refreshFloorMapTexture()
                    let carried = HallwayScene.makeCarriedFireExtinguisherNode()
                    self.cameraNode.addChildNode(carried)
                    self.carriedExtinguisherNode = carried
                    self.carryingExtinguisher = true
                    self.extinguisherPickupInProgress = false
                    SoundEffects.playExtinguisherGrab()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.showMessage("Extinguisher ready. Tap a fire to put it out.")
                }
            }
        ]), forKey: "extinguisherPickup")
    }

    /// A visible fixture is reachable in this cell or the open cell directly ahead.
    /// Distant hits must fall through to walking instead of swallowing the tap.
    private func canReachFireFixture(at coord: GridCoordinate) -> Bool {
        if coord == currentCell { return true }
        let delta = facing.delta
        return cells.contains(coord) && coord == GridCoordinate(row: currentCell.row + delta.row, col: currentCell.col + delta.col)
    }

    @discardableResult
    func pickUpExtinguisher(at coord: GridCoordinate) -> Bool {
        guard canRotate, canReachFireFixture(at: coord), !carryingExtinguisher,
              !pickedUpExtinguisherCoords.contains(coord),
              extinguisherNodes[coord]?.parent != nil else { return false }
        collectExtinguisherIfPresent(at: coord)
        return extinguisherPickupInProgress
    }

    var extinguisherAtCurrentCell: GridCoordinate? {
        guard !carryingExtinguisher, !extinguisherPickupInProgress,
              !pickedUpExtinguisherCoords.contains(currentCell),
              extinguisherCoords[currentCell] == facing,
              extinguisherNodes[currentCell]?.parent != nil else { return nil }
        return currentCell
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

    /// Sept 12: lets ContentView's handleTap tell "actually standing at a
    /// wall map" apart from "a wall map is just visible down the hall" --
    /// same "AtCurrentCell" shape as extinguisherAtCurrentCell/
    /// activeFireAtCurrentCell/photoBoothAtCurrentCell above. Without this,
    /// a tap whose hit-test happened to land on a map mounted on the wall
    /// beyond the very next open cell was being swallowed as "wall maps
    /// are read in place, no-op" before ever reaching advance() -- even
    /// though the player hadn't actually arrived at that cell yet.
    var floorMapAtCurrentCell: Bool { floorMapCoords.contains(currentCell) }

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

    func fireCoordinate(for node: SCNNode) -> GridCoordinate? {
        var candidate: SCNNode? = node
        while let current = candidate {
            if let match = fireNodes.first(where: { $0.value === current }) {
                return match.key
            }
            candidate = current.parent
        }
        return nil
    }

    func extinguisherCoordinate(for node: SCNNode) -> GridCoordinate? {
        var candidate: SCNNode? = node
        while let current = candidate {
            if let match = extinguisherNodes.first(where: { $0.value === current }) {
                return match.key
            }
            candidate = current.parent
        }
        return nil
    }

    var activeFireAtCurrentCell: GridCoordinate? {
        guard fireCoords.contains(currentCell),
              !extinguishedFireCoords.contains(currentCell) else { return nil }
        return currentCell
    }

    @discardableResult
    func extinguishFire(at coord: GridCoordinate) -> Bool {
        guard canRotate, canReachFireFixture(at: coord),
              fireCoords.contains(coord), !extinguishedFireCoords.contains(coord),
              let fire = fireNodes[coord], fire.parent != nil else { return false }
        guard carryingExtinguisher else {
            // Sept 27 (Floor 5 active-fire bare-tap response, ouch.mp3):
            // the narrowest point a deliberate TAP on a reachable ACTIVE
            // fire is confirmed while NOT carrying the extinguisher --
            // every guard above already proved canRotate/canReachFireFixture/
            // fireCoords.contains(coord)/not-yet-extinguished/a live fire
            // node, so this branch means exactly "you touched a real,
            // still-burning fire with no protection." Distinct from
            // no.mp3, which lives entirely in advance()'s movement-block
            // path and never reaches this function at all. No other
            // state changes here (unchanged): fire stays active, no
            // mission/animation/extinguisher-sound side effects, same
            // showMessage as before.
            SoundEffects.playOuch()
            showMessage("Pick up a wall extinguisher first.")
            return true
        }
        extinguishingFireCoords.insert(coord)
        let interactionID = fireInteractionID
        let spray = SCNNode(geometry: SCNCone(topRadius: 0.01, bottomRadius: 0.16, height: 0.6))
        let sprayMaterial = SCNMaterial()
        sprayMaterial.diffuse.contents = UIColor(white: 0.85, alpha: 0.7)
        sprayMaterial.emission.contents = UIColor(white: 0.55, alpha: 0.4)
        sprayMaterial.lightingModel = .constant
        sprayMaterial.transparency = 0.8
        spray.geometry?.materials = [sprayMaterial]
        spray.position = cameraNode.position
        spray.position.y -= 0.22
        spray.eulerAngles = cameraNode.eulerAngles
        spray.scale = SCNVector3(0.15, 0.15, 0.15)
        scene?.rootNode.addChildNode(spray)
        SoundEffects.playExtinguisherSpray()
        fire.removeAllActions()
        fire.runAction(.sequence([
            .group([
                .sequence([
                    // Sept 27 (fight-back extinguish choreography): the
                    // flame no longer just shrinks monotonically -- it's
                    // knocked down, flares back several times, and makes
                    // one deliberately bigger late comeback before finally
                    // losing for good. Same mechanism as before (a plain
                    // SCNAction .sequence of absolute .scale(to:duration:)
                    // calls), same scale targets/choreography as originally
                    // implemented -- ONLY the per-step durations changed
                    // (Sept 27, timing pass): stretched by a constant
                    // ~1.367x factor so the full visual sequence (this
                    // scale sub-sequence + the final collapse group below)
                    // now totals ~3.5s instead of the original ~2.56s,
                    // matching the ~4.0s extinguisher spray audio (which
                    // starts at the same tap and is untouched here) with
                    // about half a second of spray continuing after the
                    // flame is already gone. Levels are proportional to
                    // the node's existing natural full-size scale (1.0 ==
                    // the untouched "level 5" the fire is already authored
                    // at): level 4 = 0.8, level 3 = 0.6, level 2 = 0.4,
                    // level 1 = 0.2 -- exactly n/5 of the original full
                    // scale, nothing invented, unchanged from before. Level
                    // 0 (vanish) is still the existing final .group below
                    // (scale to 0.08 + fadeOut, duration stretched by the
                    // same factor) -- so this sequence only ever walks the
                    // flame down to level 1 and hands off to that same
                    // original collapse. Eddie's progression (unchanged):
                    // 5 -> 4 -> 3 -> 4 -> 3 -> 2 -> 3 -> 2 -> 4 -> 2 -> 1
                    // -> 2 -> 1 -> (0, via the untouched-in-shape final
                    // group). The 2 -> 4 step (one-last-serious-attempt)
                    // still gets the longest single duration (now 0.41s,
                    // was 0.30s) so it reads as the one noticeable late
                    // comeback rather than blending into the smaller
                    // flickers around it.
                    .scale(to: 0.8, duration: 0.25),  // 5 -> 4
                    .scale(to: 0.6, duration: 0.22),  // 4 -> 3
                    .scale(to: 0.8, duration: 0.27),  // 3 -> 4 (flare back)
                    .scale(to: 0.6, duration: 0.22),  // 4 -> 3
                    .scale(to: 0.4, duration: 0.25),  // 3 -> 2
                    .scale(to: 0.6, duration: 0.27),  // 2 -> 3 (flare back)
                    .scale(to: 0.4, duration: 0.22),  // 3 -> 2
                    .scale(to: 0.8, duration: 0.41),  // 2 -> 4 (the noticeable late comeback)
                    .scale(to: 0.4, duration: 0.30),  // 4 -> 2 (receding from the comeback)
                    .scale(to: 0.2, duration: 0.25),  // 2 -> 1
                    .scale(to: 0.4, duration: 0.22),  // 1 -> 2 (last small flicker)
                    .scale(to: 0.2, duration: 0.25)   // 2 -> 1, weakening for good before the final collapse below
                ]),
                .sequence([
                    .wait(duration: 0.25),
                    .fadeOpacity(to: 0.7, duration: 0.12),
                    .fadeIn(duration: 0.12),
                    .fadeOpacity(to: 0.35, duration: 0.18)
                ])
            ]),
            .group([.scale(to: 0.08, duration: 0.38), .fadeOut(duration: 0.38)]),  // Sept 27 timing pass: 0.28 -> 0.38 (same ~1.367x stretch, same targets)
            .hide(),
            .run { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.fireInteractionID == interactionID else { return }
                    self.extinguishingFireCoords.remove(coord)
                    self.extinguishedFireCoords.insert(coord)
                    self.refreshFloorMapTexture()
                    SoundEffects.playFireExtinguished()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.showMessage(self.isMissionComplete ? "All fires out! Return to the elevator." : "\(self.fireMissionProgress ?? "Fire extinguished.")")
                }
            }
        ]))
        spray.runAction(.sequence([
            .group([
                .scale(to: 1.15, duration: 0.35),
                .fadeOpacity(to: 0.9, duration: 0.12)
            ]),
            .wait(duration: 0.18),
            .fadeOut(duration: 0.3),
            .removeFromParentNode()
        ]))
        let smoke = SCNSphere(radius: 0.08)
        let smokeMaterial = SCNMaterial()
        smokeMaterial.diffuse.contents = UIColor(white: 0.7, alpha: 0.3)
        smokeMaterial.emission.contents = UIColor(white: 0.35, alpha: 0.15)
        smokeMaterial.lightingModel = .constant
        smokeMaterial.transparency = 0.35
        smoke.materials = [smokeMaterial]
        let smokeNode = SCNNode(geometry: smoke)
        smokeNode.position = fire.presentation.position
        scene?.rootNode.addChildNode(smokeNode)
        smokeNode.runAction(.sequence([
            .wait(duration: 0.45),
            .group([
                .moveBy(x: 0, y: 0.32, z: 0, duration: 0.55),
                .scale(to: 2.4, duration: 0.55),
                .fadeOut(duration: 0.55)
            ]),
            .removeFromParentNode()
        ]))
        return true
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

    /// BUG 2 fix (manual-mode elevator Change Picture), Sept 26:
    /// which elevator poster -- if either -- a tapped 3D node belongs
    /// to. Named nodes are the exact same ones addElevatorDoor builds
    /// (elevatorBackImage/elevatorBackPhoto for the back wall,
    /// elevatorSideImage/elevatorSidePhoto for the side wall) and
    /// elevatorArtwork(in:) already reads by these same names at
    /// arrival -- walking up to the frame's parent covers a tap that
    /// lands on the frame border rather than the photo plane itself,
    /// same "hit-test can land on either" shape as any other framed
    /// object here.
    enum ElevatorPosterTarget: Equatable {
        case back
        case side
        // Sept 26 (third elevator poster, right wall): .side above is
        // the ORIGINAL single side poster -- kept as-is, unrenamed, so
        // every existing switch over this enum stays untouched. This
        // is the new, second lateral wall.
        case sideRight
    }

    func elevatorPosterTarget(for node: SCNNode) -> ElevatorPosterTarget? {
        var current: SCNNode? = node
        while let n = current {
            switch n.name {
            case "elevatorBackImage", "elevatorBackPhoto":
                return .back
            case "elevatorSideImage", "elevatorSidePhoto":
                return .side
            case "elevatorSideRightImage", "elevatorSideRightPhoto":
                return .sideRight
            default:
                break
            }
            current = n.parent
        }
        return nil
    }

    /// Sept 26 (elevator control-panel tap-to-light, visual only):
    /// which floor -- if any -- a tapped node belongs to on the new
    /// interior control panel, plus a reference to that panel's own
    /// "elevatorControlPanel" plate node so the caller can find this
    /// floor's sibling buttons. Same parent-walk pattern as
    /// elevatorPosterTarget(for:) just above; recognizes a tap
    /// landing on either the button cap (addElevatorDoor names it
    /// "elevatorControlButton_N") or its digit label
    /// ("elevatorControlButtonLabel_N"), and only returns non-nil once
    /// the walk actually reaches the enclosing plate, so a
    /// coincidentally-named node elsewhere can never match.
    func elevatorControlButtonHit(for node: SCNNode) -> (plate: SCNNode, floor: Int)? {
        var floor: Int?
        var current: SCNNode? = node
        while let n = current {
            if floor == nil, let name = n.name {
                if name.hasPrefix("elevatorControlButton_"), let f = Int(name.dropFirst("elevatorControlButton_".count)) {
                    floor = f
                } else if name.hasPrefix("elevatorControlButtonLabel_"), let f = Int(name.dropFirst("elevatorControlButtonLabel_".count)) {
                    floor = f
                }
            }
            if n.name == "elevatorControlPanel", let floor {
                return (n, floor)
            }
            current = n.parent
        }
        return nil
    }

    /// Sept 26 (elevator control-panel tap-to-light, visual only):
    /// relights exactly one button -- purely a material swap on the
    /// existing cap nodes addElevatorDoor already built. No new
    /// stored/persisted state: every cap is simply reset to the
    /// ordinary metal look and the tapped one alone gets the gold
    /// look, the same two material recipes addElevatorDoor uses for
    /// the build-time current-floor indication. This never touches
    /// navigation, ride state, or floor destination -- see the call
    /// site's own comment for why that's guaranteed.
    func setElevatorControlButtonLit(plate: SCNNode, floor: Int) {
        let normalMaterial = SCNMaterial()
        normalMaterial.diffuse.contents = UIColor(white: 0.82, alpha: 1)
        normalMaterial.lightingModel = .physicallyBased
        normalMaterial.metalness.contents = 0.6
        normalMaterial.roughness.contents = 0.3

        let activeMaterial = normalMaterial.copy() as! SCNMaterial
        activeMaterial.diffuse.contents = UIColor(red: 1.0, green: 0.82, blue: 0.35, alpha: 1)
        activeMaterial.emission.contents = UIColor(red: 0.5, green: 0.32, blue: 0.05, alpha: 1)

        let targetName = "elevatorControlButton_\(floor)"
        for node in plate.childNodes where node.name?.hasPrefix("elevatorControlButton_") == true {
            node.geometry?.materials = [node.name == targetName ? activeMaterial : normalMaterial]
        }
    }

    // Eddie, Sept 16 (tap the inside of the Floor 1 entrance doors to
    // return to the opening screen): floorOneEntranceBack (HallwayScene.
    // swift's floorNumber == 1 branch) is a single static plane, not a
    // dictionary of per-coordinate objects, so the same plain-name-check
    // shape as isElevatorDoor above is all this needs -- no new stored
    // node reference required, the name set on the node at construction
    // time is already the identity.
    func isEntranceDoor(_ node: SCNNode) -> Bool {
        node.name == "floorOneEntranceBack"
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

    /// Same node-name/walk-the-parent-chain pattern as roomDoorCoordinate
    /// just above, for the bathroom door's hinge node (named
    /// "bathroomDoor_<row>_<col>" by makeBathroomDoorPanel).
    func bathroomDoorCoordinate(for node: SCNNode) -> GridCoordinate? {
        var candidate: SCNNode? = node
        while let current = candidate {
            if let name = current.name, name.hasPrefix("bathroomDoor_") {
                let parts = name.dropFirst("bathroomDoor_".count).split(separator: "_")
                if parts.count == 2, let row = Int(parts[0]), let col = Int(parts[1]) {
                    return GridCoordinate(row: row, col: col)
                }
            }
            candidate = current.parent
        }
        return nil
    }

    /// Eddie, Sept 14 (round 3): "the door's visual state and
    /// traversal state should remain synchronized." True by
    /// construction -- this is the ONLY thing that decides "are you
    /// standing somewhere that makes this door interactable," and both
    /// openBathroomDoor and closeBathroomDoor below gate on it before
    /// touching openBathroomDoors, so there's one source of truth for
    /// "who can act on this door right now," not two copies that could
    /// drift. Works from EITHER side of the doorway -- coord is always
    /// the anchor bathroomDoors is keyed by (the hallway-side cell),
    /// but round 3 added the ability to open/close it from the room
    /// side too (walking BATHROOM -> HALLWAY), which the original
    /// round-2 "coord == currentCell" guard never accounted for since
    /// the door never used to close, so tapping it from inside was
    /// never actually reachable before now.
    func isAdjacentToBathroomDoor(_ coord: GridCoordinate) -> Bool {
        guard let doorDirection = bathroomDoors[coord] else { return false }
        let neighbor = GridCoordinate(row: coord.row + doorDirection.delta.row, col: coord.col + doorDirection.delta.col)
        return (currentCell == coord && facing == doorDirection) || (currentCell == neighbor && facing == doorDirection.opposite)
    }

    /// The swing's sign, worked out analytically per direction from
    /// makeBathroomDoorPanel's own per-direction hinge placement (which
    /// way the panel's hinge-relative local axis actually points once
    /// rotated) so the door swings AWAY from the hallway cell, into the
    /// room, rather than through the wall. Shared by openBathroomDoor
    /// (forward) and closeBathroomDoor (the exact same rotation negated)
    /// so the two can never drift out of sync with each other.
    private func bathroomDoorSwingAngle(for direction: Direction) -> CGFloat {
        let sign: CGFloat
        switch direction {
        case .north, .east: sign = 1
        case .south, .west: sign = -1
        }
        return sign * (100 * .pi / 180)
    }

    /// Tapping the closed bathroom door swings it open -- same "must be
    /// standing at the right cell, facing the right wall" guard shape as
    /// deliverMail above (isAdjacentToBathroomDoor, now valid from
    /// either side of the doorway). Once open, ordinary grid navigation
    /// (via openDirections' bathroomDoorAnchor check) handles walking
    /// through it -- no special-case camera choreography, per Eddie's
    /// own instruction to prefer that if ordinary grid navigation can
    /// do it. Preserved exactly as it was in round 2 -- Eddie, round 3:
    /// "Preserve the existing bathroom-door OPENING animation."
    func openBathroomDoor(at coord: GridCoordinate) {
        guard canRotate, !openBathroomDoors.contains(coord), let doorDirection = bathroomDoors[coord], isAdjacentToBathroomDoor(coord) else { return }
        openBathroomDoors.insert(coord)
        if let hinge = scene?.rootNode.childNode(withName: "bathroomDoor_\(coord.row)_\(coord.col)", recursively: true) {
            let swing = SCNAction.rotateBy(x: 0, y: bathroomDoorSwingAngle(for: doorDirection), z: 0, duration: 0.5)
            swing.timingMode = .easeOut
            hinge.runAction(swing)
        }
        UISelectionFeedbackGenerator().selectionChanged()
        showMessage("The door swings open.")
    }

    /// Eddie, Sept 14 (round 3): "close behind the player." The exact
    /// reverse of openBathroomDoor's own rotation (bathroomDoorSwingAngle
    /// negated) so it reads as the same physical hinge swinging back,
    /// not a redesigned animation. Only ever called from
    /// closeBathroomDoorIfJustCrossed below, itself only ever fired by
    /// currentCell's didSet -- i.e. only once the glide has actually,
    /// visibly carried the player across the doorway, never a timer.
    private func closeBathroomDoor(at coord: GridCoordinate) {
        guard openBathroomDoors.contains(coord), let doorDirection = bathroomDoors[coord] else { return }
        openBathroomDoors.remove(coord)
        if let hinge = scene?.rootNode.childNode(withName: "bathroomDoor_\(coord.row)_\(coord.col)", recursively: true) {
            let swing = SCNAction.rotateBy(x: 0, y: -bathroomDoorSwingAngle(for: doorDirection), z: 0, duration: 0.5)
            swing.timingMode = .easeOut
            hinge.runAction(swing)
        }
    }

    /// currentCell's didSet hands this exactly one single-cell step
    /// (from -> to, always adjacent -- applyArrival sets currentCell one
    /// grid step at a time even mid-glide). If that step actually
    /// crossed an OPEN bathroom doorway -- in EITHER direction, hallway
    /// side or room side, same as isAdjacentToBathroomDoor above --
    /// close it behind them. bathroomDoorAnchor already knows how to
    /// resolve either side of a boundary back to the one coordinate
    /// bathroomDoors/openBathroomDoors actually key by, so this reuses
    /// it rather than re-deriving that mapping a second way.
    private func closeBathroomDoorIfJustCrossed(from: GridCoordinate, to: GridCoordinate) {
        let dr = to.row - from.row
        let dc = to.col - from.col
        guard let direction = Direction.allCases.first(where: { $0.delta.row == dr && $0.delta.col == dc }) else { return }
        guard let anchor = bathroomDoorAnchor(from: from, direction: direction), openBathroomDoors.contains(anchor) else { return }
        closeBathroomDoor(at: anchor)
    }

    /// Same node-name/walk-the-parent-chain resolution as
    /// bathroomDoorCoordinate, for a Window Room door's own
    /// "windowRoomDoor_<row>_<col>" hinge name (see HallwayScene's
    /// windowRooms build loop, which passes that exact
    /// hingeNamePrefix into makeBathroomDoorPanel).
    func windowRoomDoorCoordinate(for node: SCNNode) -> GridCoordinate? {
        var candidate: SCNNode? = node
        while let current = candidate {
            if let name = current.name, name.hasPrefix("windowRoomDoor_") {
                let parts = name.dropFirst("windowRoomDoor_".count).split(separator: "_")
                if parts.count == 2, let row = Int(parts[0]), let col = Int(parts[1]) {
                    return GridCoordinate(row: row, col: col)
                }
            }
            candidate = current.parent
        }
        return nil
    }

    /// Same "one source of truth for who can act on this door right
    /// now, valid from either side" shape as isAdjacentToBathroomDoor
    /// -- deliberately not a shared helper across the two door kinds
    /// (Eddie's own instruction was to reuse the bathroom door's
    /// interaction model, not to build a generalized one), but
    /// mirrors it exactly so the two can't drift apart in practice.
    func isAdjacentToWindowRoomDoor(_ coord: GridCoordinate) -> Bool {
        guard let doorDirection = windowRooms[coord]?.direction else { return false }
        let neighbor = GridCoordinate(row: coord.row + doorDirection.delta.row, col: coord.col + doorDirection.delta.col)
        return (currentCell == coord && facing == doorDirection) || (currentCell == neighbor && facing == doorDirection.opposite)
    }

    /// Tapping the closed Window Room door swings it open -- same
    /// guard shape, same reused bathroomDoorSwingAngle math (any
    /// hinged door in this building swings the same analytical way),
    /// and once open, the same ordinary-grid-navigation walk-through
    /// (via openDirections' windowRoomDoorAnchor check) as a bathroom
    /// door -- "reusing the Bathroom Room's proven interaction model
    /// exactly," per Eddie, Sept 15.
    func openWindowRoomDoor(at coord: GridCoordinate) {
        guard canRotate, !openWindowRoomDoors.contains(coord), let doorDirection = windowRooms[coord]?.direction, isAdjacentToWindowRoomDoor(coord) else { return }
        openWindowRoomDoors.insert(coord)
        if let hinge = scene?.rootNode.childNode(withName: "windowRoomDoor_\(coord.row)_\(coord.col)", recursively: true) {
            let swing = SCNAction.rotateBy(x: 0, y: bathroomDoorSwingAngle(for: doorDirection), z: 0, duration: 0.5)
            swing.timingMode = .easeOut
            hinge.runAction(swing)
        }
        UISelectionFeedbackGenerator().selectionChanged()
        showMessage("The door swings open.")
    }

    /// The exact reverse of openWindowRoomDoor's own rotation, only
    /// ever called from closeWindowRoomDoorIfJustCrossed below --
    /// same "close behind the player, never a timer" policy as a
    /// bathroom door.
    private func closeWindowRoomDoor(at coord: GridCoordinate) {
        guard openWindowRoomDoors.contains(coord), let doorDirection = windowRooms[coord]?.direction else { return }
        openWindowRoomDoors.remove(coord)
        if let hinge = scene?.rootNode.childNode(withName: "windowRoomDoor_\(coord.row)_\(coord.col)", recursively: true) {
            let swing = SCNAction.rotateBy(x: 0, y: -bathroomDoorSwingAngle(for: doorDirection), z: 0, duration: 0.5)
            swing.timingMode = .easeOut
            hinge.runAction(swing)
        }
    }

    /// Same single-step-crossing close-behind-the-player trigger as
    /// closeBathroomDoorIfJustCrossed, resolved through
    /// windowRoomDoorAnchor instead.
    private func closeWindowRoomDoorIfJustCrossed(from: GridCoordinate, to: GridCoordinate) {
        let dr = to.row - from.row
        let dc = to.col - from.col
        guard let direction = Direction.allCases.first(where: { $0.delta.row == dr && $0.delta.col == dc }) else { return }
        guard let anchor = windowRoomDoorAnchor(from: from, direction: direction), openWindowRoomDoors.contains(anchor) else { return }
        closeWindowRoomDoor(at: anchor)
    }

    /// Sept 27 (first generic-room-door authoring pass): same node-
    /// name/walk-the-parent-chain resolution as bathroomDoorCoordinate/
    /// windowRoomDoorCoordinate, for a Room Entrance door's own
    /// "roomEntranceDoor_<row>_<col>" hinge name (see HallwayScene's
    /// roomEntranceDoors build loop, which passes that exact
    /// hingeNamePrefix into makeBathroomDoorPanel).
    func roomEntranceDoorCoordinate(for node: SCNNode) -> GridCoordinate? {
        var candidate: SCNNode? = node
        while let current = candidate {
            if let name = current.name, name.hasPrefix("roomEntranceDoor_") {
                let parts = name.dropFirst("roomEntranceDoor_".count).split(separator: "_")
                if parts.count == 2, let row = Int(parts[0]), let col = Int(parts[1]) {
                    return GridCoordinate(row: row, col: col)
                }
            }
            candidate = current.parent
        }
        return nil
    }

    /// Same "one source of truth for who can act on this door right
    /// now, valid from either side" shape as isAdjacentToBathroomDoor/
    /// isAdjacentToWindowRoomDoor.
    func isAdjacentToRoomEntranceDoor(_ coord: GridCoordinate) -> Bool {
        guard let doorDirection = roomEntranceDoors[coord] else { return false }
        let neighbor = GridCoordinate(row: coord.row + doorDirection.delta.row, col: coord.col + doorDirection.delta.col)
        return (currentCell == coord && facing == doorDirection) || (currentCell == neighbor && facing == doorDirection.opposite)
    }

    /// Tapping the closed Room Entrance door swings it open -- same
    /// guard shape, same reused bathroomDoorSwingAngle math (any
    /// hinged door in this building swings the same analytical way),
    /// and once open, the same ordinary-grid-navigation walk-through
    /// (via openDirections' roomEntranceDoorAnchor check) as a
    /// bathroom/Window Room door -- reusing that proven interaction
    /// model exactly, per Eddie's own instruction not to invent a
    /// second one.
    func openRoomEntranceDoor(at coord: GridCoordinate) {
        guard canRotate, !openRoomEntranceDoors.contains(coord), let doorDirection = roomEntranceDoors[coord], isAdjacentToRoomEntranceDoor(coord) else { return }
        openRoomEntranceDoors.insert(coord)
        // Sept 27 (Room Entrance open sound): fires exactly once per
        // real open transition -- this guard above already refuses to
        // re-enter while the door is already open, so there is no
        // separate dedup needed here.
        SoundEffects.playRoomEntranceDoorOpen()
        if let hinge = scene?.rootNode.childNode(withName: "roomEntranceDoor_\(coord.row)_\(coord.col)", recursively: true) {
            let swing = SCNAction.rotateBy(x: 0, y: bathroomDoorSwingAngle(for: doorDirection), z: 0, duration: 0.5)
            swing.timingMode = .easeOut
            hinge.runAction(swing)
        }
        UISelectionFeedbackGenerator().selectionChanged()
        showMessage("The door swings open.")
    }

    /// The exact reverse of openRoomEntranceDoor's own rotation, only
    /// ever called from closeRoomEntranceDoorIfJustCrossed below --
    /// same "close behind the player, never a timer" policy as a
    /// bathroom/Window Room door.
    private func closeRoomEntranceDoor(at coord: GridCoordinate) {
        guard openRoomEntranceDoors.contains(coord), let doorDirection = roomEntranceDoors[coord] else { return }
        openRoomEntranceDoors.remove(coord)
        // Sept 27 (Room Entrance close sound): this function only
        // ever runs from closeRoomEntranceDoorIfJustCrossed, which
        // itself already requires the door to be open (openRoomEntranceDoors.contains(anchor))
        // before calling here -- so this fires exactly once per real
        // automatic-close transition, never on a bare tap.
        SoundEffects.playRoomEntranceDoorClose()
        if let hinge = scene?.rootNode.childNode(withName: "roomEntranceDoor_\(coord.row)_\(coord.col)", recursively: true) {
            let swing = SCNAction.rotateBy(x: 0, y: -bathroomDoorSwingAngle(for: doorDirection), z: 0, duration: 0.5)
            swing.timingMode = .easeOut
            hinge.runAction(swing)
        }
    }

    /// Same single-step-crossing close-behind-the-player trigger as
    /// closeBathroomDoorIfJustCrossed/closeWindowRoomDoorIfJustCrossed,
    /// resolved through roomEntranceDoorAnchor instead.
    private func closeRoomEntranceDoorIfJustCrossed(from: GridCoordinate, to: GridCoordinate) {
        let dr = to.row - from.row
        let dc = to.col - from.col
        guard let direction = Direction.allCases.first(where: { $0.delta.row == dr && $0.delta.col == dc }) else { return }
        guard let anchor = roomEntranceDoorAnchor(from: from, direction: direction), openRoomEntranceDoors.contains(anchor) else { return }
        closeRoomEntranceDoor(at: anchor)
    }

    /// Sept 27 (Decorator Room Entrance authoring, live ADD). Registers
    /// a Room Entrance door placed live via Decorator ("+" -> Door
    /// Entry) into THIS controller's own roomEntranceDoors copy -- the
    /// same dictionary openDirections/openRunLength (movement gating),
    /// isAdjacentToRoomEntranceDoor/openRoomEntranceDoor (tap-to-open,
    /// from either side), and currentFloorMapImage's doorFaces (the
    /// popup map's red door-face indicator) all read directly. Same
    /// "widen the stored copy from `let` to `var` to allow this" shape
    /// as registerFloorObject/registerFire before it.
    func registerRoomEntranceDoor(_ direction: Direction, at coord: GridCoordinate) {
        roomEntranceDoors[coord] = direction
        refreshFloorMapTexture()
    }

    /// Reverse of registerRoomEntranceDoor above -- DecoratorState.
    /// deleteRoomEntranceDoor already removes the live SCNNodes (frame
    /// + hinge) and MazeStore's persisted placement, but had no way to
    /// clear this controller's own copy, which would otherwise keep
    /// blocking movement through the now-doorless boundary and keep
    /// drawing the red indicator on the map until the floor was fully
    /// rebuilt -- same staleness bug unregisterRoomDoor/unregisterFire
    /// were already written to avoid for their own kinds. Also drops
    /// the coordinate from openRoomEntranceDoors: with the door gone,
    /// there is nothing left to be "open" or "closed".
    func unregisterRoomEntranceDoor(at coord: GridCoordinate) {
        roomEntranceDoors.removeValue(forKey: coord)
        openRoomEntranceDoors.remove(coord)
        refreshFloorMapTexture()
    }

    /// Sept 28 (EXIT sign map markers, live add/re-point). Same
    /// register/unregister shape as registerRoomEntranceDoor/
    /// unregisterRoomEntranceDoor just above -- DecoratorState.
    /// addExitSignAtCurrentCell/changeExitSignDirection call this
    /// (through registerLiveExitSign) so the popup map's new EXIT
    /// arrow (currentFloorMapImage's exitSignFaces) reflects a live
    /// add or a live re-point immediately, with no floor rebuild.
    /// Re-registering the same coord with a new direction (the
    /// re-point case) just overwrites the dictionary entry -- exactly
    /// what a re-point needs, no separate "update" entry point.
    func registerExitSign(_ direction: Direction, at coord: GridCoordinate) {
        exitSignDirections[coord] = direction
        refreshFloorMapTexture()
    }

    /// Reverse of registerExitSign above -- DecoratorState.deleteExitSign
    /// already removes the live SCNNode and MazeStore's persisted
    /// placement, but had no way to clear this controller's own copy,
    /// which would otherwise keep drawing the arrow on the popup map
    /// until the floor was fully rebuilt -- same staleness bug
    /// unregisterRoomEntranceDoor above was already written to avoid.
    func unregisterExitSign(at coord: GridCoordinate) {
        exitSignDirections.removeValue(forKey: coord)
        refreshFloorMapTexture()
    }

    func deliverMail(at coord: GridCoordinate) {
        // Sept 24 (decorative room doors): a decorative door never
        // accepts mail and never shows ANY delivery message -- not even
        // "No mail for Room X" -- so the guard below drops it silently
        // before the existing message/delivery flow can run.
        guard canRotate, coord == currentCell, let door = roomDoors[coord], facing == door.direction, !door.isDecorative else { return }
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

    /// Sept 24 (room-door knock interaction): a normal-gameplay tap on a
    /// room door's visible geometry routes here from ContentView.handleTap.
    /// Mail-slot/doorknob region-splitting does not exist yet in the new
    /// portrait (see the Sept 24 report), so this pass keeps one
    /// whole-door behavior per door kind:
    ///  - FUNCTIONAL door: unchanged -- deliverMail(at:) (delivery, or the
    ///    existing "No mail for Room N." flow). Specialized-action-wins is
    ///    effectively still in force for these because there is no
    ///    separately-identifiable mail-slot region to subdivide them by;
    ///    knocking them lands with that region-splitting follow-up.
    ///  - DECORATIVE door (Floor 2): the whole visible door surface is the
    ///    knock surface -- no mail slot, no knob-open, no enter behavior
    ///    exist for them (entirely by construction: deliverMail's own
    ///    guard refuses them), so a tap anywhere on the door calls
    ///    SoundEffects.playKnock(), the audio ladder (soft -> medium ->
    ///    hard, >5s reset) exactly as implemented and verified.
    /// The guards here mirror the existing door branches in handleTap:
    /// stopped at the door's own cell (coord == currentCell), facing it
    /// head-on (facing == door.direction), and not mid-animation
    /// (canRotate). One call site, one routing decision, one sound --
    /// no duplicate firing through overlapping gesture paths.
    func interactWithRoomDoor(at coord: GridCoordinate) {
        guard canRotate, coord == currentCell, let door = roomDoors[coord], facing == door.direction else { return }
        if door.isDecorative {
            SoundEffects.playKnock()
        } else {
            deliverMail(at: coord)
        }
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
    // Sept 27 (wall-object map indicators): includeWallObjectIndicators
    // defaults to false so refreshFloorMapTexture()'s own call below
    // (which feeds the in-scene "You Are Here" wall-mounted map plane
    // texture) is completely unaffected -- only HandheldMapViews'
    // popup mini/full map cards pass true. This is the SAME shared
    // makeFloorMapTexture the wall-mounted map already used before this
    // change (Eddie's spec calls this out explicitly: reuse the
    // existing renderer/data, and flag rather than silently broaden
    // the effect if it's shared) -- gating behind this one parameter,
    // rather than forking a parallel render path, keeps it that one
    // shared function while still scoping the new visible effect to
    // only the popup, per Eddie's "do not casually change another map
    // UI as collateral damage."
    func currentFloorMapImage(backgroundOpacity: CGFloat = 1, simplified: Bool = false, includeWallObjectIndicators: Bool = false) -> UIImage {
        let missionItemCells = objectKinds.filter { $0.value == missionObjectKind && !collectedCoords.contains($0.key) }.map { $0.key }
        let missionDestinationCells = destinationKinds.filter { $0.value == missionObjectKind }.map { $0.key }
        // Sept 27 (Floor 5 fire/extinguisher map markers): same
        // "still needs attention" filter shape as missionItemCells --
        // an extinguished fire or a picked-up extinguisher drops out
        // immediately, exactly like a collected mission item does.
        let activeFireCells = Array(fireCoords.subtracting(extinguishedFireCoords))
        let availableExtinguisherCells = extinguisherCoords.keys.filter { !pickedUpExtinguisherCoords.contains($0) }
        // Sept 27 (wall-object map indicators): the authoritative
        // coord+direction data for all four supported wall-mounted
        // kinds -- Pictures (pictureFaces) and Mirrors (mirrorFaces)
        // already carry live Decorator adds/deletes via
        // register/unregisterPicture and register/unregisterMirror;
        // Floor Mission signs and Floor Maps have no live-add path at
        // all (2D Grid Editor only), so floorMapDirections/
        // missionSignDirections are always exactly what this floor was
        // built or rebuilt with. A Set<WallFace> naturally collapses
        // two supported kinds that happen to share one face down to a
        // single entry -- no explicit dedup needed.
        let wallObjectFaces: Set<WallFace> = includeWallObjectIndicators
            ? pictureFaces
                .union(mirrorFaces)
                .union(missionSignDirections.map { WallFace(coord: $0.key, direction: $0.value) })
                .union(floorMapDirections.map { WallFace(coord: $0.key, direction: $0.value) })
            : []
        // Sept 27 (door map indicators): same opt-in gate as the black
        // wall-object indicators above, reusing the SAME authoritative
        // roomDoors dictionary already threaded into this function
        // (RoomDoorPlacement.coord + .direction) rather than deriving
        // anything new from SceneKit. roomDoors already carries every
        // live delete via unregisterRoomDoor, so this stays current on
        // each render exactly like the black indicators do; a Set
        // naturally collapses any duplicate coord+face entries to one.
        // Sept 27 (first generic-room-door authoring pass): a Room
        // Entrance door reads as the same red wall-face bar as an
        // office/mail door on this popup map -- the map's door
        // indicator has always deliberately meant just "a door is
        // here," not which kind (same reasoning as the black
        // indicators never distinguishing Picture/Mirror/Mission
        // sign/Floor map) -- so it's unioned into the SAME doorFaces
        // set rather than inventing a second indicator. bathroomDoors/
        // windowRooms are NOT added here -- they never participated in
        // this indicator before this change, and this pass doesn't
        // alter that.
        let doorFaces: Set<WallFace> = includeWallObjectIndicators
            ? Set(roomDoors.map { WallFace(coord: $0.key, direction: $0.value.direction) })
                .union(roomEntranceDoors.map { WallFace(coord: $0.key, direction: $0.value) })
            : []
        // Sept 28 (EXIT sign map markers): same opt-in gate as the
        // black wall-object indicators and red door bars above, reusing
        // exitSignDirections -- the authoritative coord+direction data
        // straight off mazeStore.exitSigns -- rather than deriving
        // anything new from SceneKit.
        let exitSignFaces: Set<WallFace> = includeWallObjectIndicators
            ? Set(exitSignDirections.map { WallFace(coord: $0.key, direction: $0.value) })
            : []
        return HallwayScene.makeFloorMapTexture(cells: cells, end: endCell, playerAt: currentCell, facing: facing, missionItemCells: missionItemCells, missionDestinationCells: missionDestinationCells, fireCells: activeFireCells, extinguisherCells: Array(availableExtinguisherCells), photoBoothCells: Array(photoBoothCoords), roomDoors: roomDoors, itemRooms: itemRooms, bathroomDoors: bathroomDoors, paintedCells: missionObjectKind == .paintBucket ? paintedCells : nil, backgroundOpacity: backgroundOpacity, simplified: simplified, wallObjectFaces: wallObjectFaces, doorFaces: doorFaces, exitSignFaces: exitSignFaces)
    }

    private var applyingArrival = false
    private func applyArrival(cell: GridCoordinate, heading: Direction) {
        applyingArrival = true
        facing = heading
        currentCell = cell
        collectObjectIfPresent(at: cell)
        applyingArrival = false
        refreshFloorMapTexture()
    }

    private func refreshFloorMapTexture() {
        guard !applyingArrival, !floorMapPlaneNodes.isEmpty else { return }
        let image = currentFloorMapImage()
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
        if !fireCoords.isEmpty {
            return extinguishedFireCoords == fireCoords
        }
        if !photoBoothExpressions.isEmpty {
            return completedPhotoBooths == Set(photoBoothExpressions.keys)
        }
        // Floor 7's aptitude-test terminal -- Eddie, Sept 13: "the
        // mission completes when the player wins." Same one-branch-
        // per-mission-type shape as fire/photo booth above; no
        // parallel progression system, this IS isMissionComplete.
        if !ticTacToeDirections.isEmpty {
            return ticTacToeWon
        }
        // Floor 8's shell-game station -- Eddie, Sept 13: same
        // one-branch-per-mission-type shape as the aptitude test
        // right above; no parallel progression system here either.
        if !shellGameDirections.isEmpty {
            return shellGameWon
        }
        // Floor 9's Rock Paper Scissors terminal -- same one-branch-
        // per-mission-type shape as the two mini-games right above.
        if !rockPaperScissorsDirections.isEmpty {
            return rockPaperScissorsWon
        }
        // Floor 10's Higher/Lower terminal -- same one-branch-per-
        // mission-type shape as the three mini-games above.
        if !higherLowerDirections.isEmpty {
            return higherLowerWon
        }
        // Floor 11's Five-Card Draw terminal -- same one-branch-per-
        // mission-type shape as the four mini-games above.
        if !fiveCardDrawDirections.isEmpty {
            return fiveCardDrawWon
        }
        // Floor 13's Simon terminal -- same one-branch-per-mission-
        // type shape as the six mini-games above.
        if !simonDirections.isEmpty {
            return simonWon
        }
        // Floor 12's Hangman terminal -- same one-branch-per-mission-
        // type shape as the games above.
        if !hangmanDirections.isEmpty {
            return hangmanWon
        }
        // Floor 14's Connect Four terminal -- same one-branch-per-
        // mission-type shape as the games above.
        if !connectFourDirections.isEmpty {
            return connectFourWon
        }
        // Floor 15's Checkers terminal -- same one-branch-per-
        // mission-type shape as the games above.
        if !checkersDirections.isEmpty {
            return checkersWon
        }
        // Floor 16's Woidle terminal -- same one-branch-per-
        // mission-type shape as the games above.
        if !woidleDirections.isEmpty {
            return woidleWon
        }
        guard let kind = missionObjectKind else { return true }
        if kind == .paintBucket { return hasPaintBucket && paintedCells == cells }
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

    /// Sept 12: lets ContentView's handleTap tell "actually standing at
    /// the elevator" apart from "the elevator doors are just visible down
    /// the hall" -- same currentCell == endCell test openElevator() below
    /// already uses as its own real guard, and the same test
    /// pinchForward() already uses to choose between opening the elevator
    /// and just walking forward. Without this, a tap whose hit-test
    /// happened to land on a door panel visible beyond the very next open
    /// cell was calling openElevator() (which silently no-ops when not at
    /// endCell yet) and then unconditionally returning -- swallowing a tap
    /// that should have walked one legal cell forward instead.
    var elevatorAtCurrentCell: Bool { currentCell == endCell }

    // Eddie, Sept 16: same "must actually be standing there, not just
    // see it down a straight hallway" guard elevatorAtCurrentCell uses
    // just above -- Floor 1 is one unbroken line of cells, so
    // floorOneEntranceBack (mounted behind startCell) can hit-test as
    // visible from anywhere in the hallway once the player turns to
    // face it, well before they've actually walked back to it.
    var entranceDoorAtCurrentCell: Bool { currentCell == startCell }

    /// True from the moment the elevator doors begin opening
    /// (openElevator(), below) until this ride's floor actually
    /// advances (or a hard reset()) -- the same flag canGoForward/
    /// canRotate already gate on internally. Exposed read-only so
    /// ContentView's pan-gesture handler can tell "we're mid-ride"
    /// from ordinary hallway walking without duplicating any state
    /// here -- see beginElevatorCameraDrag() below and
    /// handlePanRotate in ContentView.swift.
    var isElevatorRideInProgress: Bool { elevatorInUse }

    /// Begins player-driven camera look during an active elevator
    /// ride -- the pan gesture's equivalent of beginDragRotate(), but
    /// deliberately a SEPARATE function: beginDragRotate/
    /// updateDragRotate/endDragRotate always commit to one of the 4
    /// cardinal facings on release (a grid-navigation concept), where
    /// an elevator interior isn't on the grid at all and the player
    /// needs to be able to end up looking at an arbitrary in-between
    /// angle (a corner, the rear wall) and just stay there. Reuses
    /// the SAME translation/dragRotateDistance math ContentView's
    /// handlePanRotate already computes for the normal gesture, just
    /// applied to this separate, unsnapped state instead. No-ops
    /// outside an active ride.
    func beginElevatorCameraDrag() {
        guard elevatorInUse else { return }
        // Eddie: "the moment intentional player steering begins, the
        // current automatic camera rotation must yield... do not let
        // auto-spin fight the player's gesture." Cancels ONLY the
        // auto-spin action (its own dedicated key, above) if it
        // happens to be mid-flight right now. Deliberately NOT
        // removeAllActions() here -- that would also cancel the
        // ride's forward dolly if the player grabs the screen this
        // early (a real position action, still possibly in flight),
        // and with it the completion chain that closes the doors and
        // schedules the rest of the ride, softlocking it. Cancelling
        // a keyed action does not fire its completion handler, which
        // is fine here: arrival no longer depends on the auto-spin's
        // completion firing at all -- see playElevatorRide's own
        // comment on the separate, decoupled wait that replaced it.
        cameraNode.removeAction(forKey: Self.elevatorAutoSpinActionKey)
        playerHasTakenElevatorCameraControl = true
        elevatorCameraDragBaseYaw = Double(cameraNode.eulerAngles.y)
        isDraggingElevatorCamera = true
    }

    /// Call continuously while the finger moves during an elevator
    /// ride. Same fraction-to-yaw math as updateDragRotate, but
    /// deliberately NOT clamped to a quarter turn -- the player needs
    /// to reach the rear wall (a half turn) and arbitrary in-between
    /// angles, not just the 4 cardinal facings a hallway limits them
    /// to.
    func updateElevatorCameraDrag(fraction: Double) {
        guard isDraggingElevatorCamera else { return }
        cameraNode.eulerAngles = SCNVector3(0, Float(elevatorCameraDragBaseYaw + fraction * .pi / 2), 0)
    }

    /// Ending ride free-look only releases the gesture. Do not start a grid
    /// animation or snap: the ride owns translation and preserves the chosen yaw.
    func endElevatorCameraDrag() {
        guard isDraggingElevatorCamera else { return }
        isDraggingElevatorCamera = false
        navLog("endElevatorCameraDrag() preserving yaw=\(cameraNode.eulerAngles.y)")
    }

    /// BUG 2 fix (manual-mode elevator Change Picture), Sept 26: live,
    /// in-place update for the poster the player just tapped and
    /// picked a new image for via ElevatorPictureChangeMenuHost. Finds
    /// the SAME node, by the SAME fixed name, elevatorArtwork(in:)
    /// already reads at arrival -- so this never needs its own
    /// persistence: the instant this ride ends (passive or
    /// controlled), the EXISTING arrival handoff captures whatever
    /// this material is currently showing, right along with any
    /// picture the player never touched. Uses HallwayScene's own
    /// elevatorPosterPhoto(_:) so a manually chosen photo gets the
    /// exact same crop/letterbox treatment a random one already does
    /// -- no new image-processing code. Deliberately writes straight
    /// to the material, not through mazeStore: this must never become
    /// a per-floor, Decorator/Designer-authorable selection. Camera,
    /// ride timing, and the auto-pivot are all untouched by this call.
    func applyElevatorPosterImage(_ image: UIImage, to target: ElevatorPosterTarget) {
        guard let material = elevatorPosterMaterial(for: target) else { return }
        material.diffuse.contents = HallwayScene.elevatorPosterPhoto(image)
    }

    private func elevatorPosterMaterial(for target: ElevatorPosterTarget) -> SCNMaterial? {
        let nodeName: String
        switch target {
        case .back: nodeName = "elevatorBackImage"
        case .side: nodeName = "elevatorSideImage"
        case .sideRight: nodeName = "elevatorSideRightImage"
        }
        return scene?.rootNode.childNode(withName: nodeName, recursively: true)?.geometry?.firstMaterial
    }

    /// Called once by ContentView, immediately after it builds EVERY
    /// destination floor reached via the elevator -- a passive ride
    /// and a player-controlled ride alike (see onReachedEnd /
    /// onElevatorArrivedControlled and NavigationBridge.
    /// pendingElevatorArrival/pendingArrivalYaw in ContentView.swift),
    /// never for an ordinary non-elevator floor load. Eddie, Sept 16
    /// (remove automatic step-out): physical testing rejected the
    /// idea that arrival should ever automatically move the player
    /// through the doors, for EITHER kind of ride -- Hallways' own
    /// control rule is that swipe/turn never causes forward movement,
    /// and tap/long-press is the only thing allowed to. This puts
    /// every arrival into ONE canonical state: standing inside the
    /// destination elevator's cab, offset ElevatorGeometry.entryDistance
    /// beyond the hallway wall along elevatorMountDirection -- the
    /// exact same interior position the ride's own forward dolly used
    /// back on the OLD floor -- with the destination's own real doors
    /// already open at their correct physical location, and
    /// elevatorAwaitingEntryDirection set so canGoForward/advance()
    /// only accept ONE legal forward move from here: walking straight
    /// back out to the real cell center (performElevatorEntryWalkOut()
    /// below). preservedYaw nil means a passive ride -- present the
    /// natural "already facing the doors" orientation
    /// (elevatorMountDirection.opposite.yaw), the same direction the
    /// old floor's own automatic spin ends up facing before a normal
    /// ride's doors open.
    ///
    /// Sept 26 (camera-heading coordinate-space fix): a non-nil
    /// preservedYaw is NOT a raw world angle anymore -- it's the
    /// controlled ride's exact camera heading at arrival, expressed as
    /// an offset RELATIVE TO the source floor's own "facing the doors"
    /// baseline (see the capture site in playElevatorRide's arrival
    /// block). Re-adding it to THIS (destination) floor's own baseline
    /// below reproduces the player's actual chosen heading exactly,
    /// even when the 2 floors' elevators are mounted on different
    /// compass walls -- using it as a raw absolute angle instead (the
    /// old behavior) silently rotated the arrival by whatever constant
    /// compass offset separated the 2 mount directions, physically
    /// verified as a consistent one-wall (~90 degree) shift. Applied
    /// with no snap/animation either way -- this runs while the
    /// arrival curtain still fully covers the screen, so nothing here
    /// is ever visibly snapping into place. `facing` is snapped to the
    /// nearest cardinal to whichever yaw was used, purely for internal
    /// bookkeeping (which direction tap/long-press-forward moves) --
    /// the SAME snap-to-nearest-cardinal every ordinary swipe-to-turn
    /// already commits to on release (see endDragRotate), just done
    /// here once, up front, silently. The camera's own visual yaw is
    /// always left at the exact value used, never snapped.
    func presentArrivalInsideElevator(preservedYaw: Double?) {
        guard let direction = elevatorMountDirection,
              let leftDoor = elevatorLeftDoor, let rightDoor = elevatorRightDoor,
              let leftClosed = elevatorLeftClosedPosition, let rightClosed = elevatorRightClosedPosition else {
            return
        }

        // Eddie, Sept 16 (atomic arrival presentation): every property
        // set below is animatable, and SceneKit implicitly animates
        // ANY change to an animatable property over its own default
        // duration UNLESS that's explicitly turned off -- with it left
        // on, this whole method's camera reposition/re-orient (from
        // whatever HallwayScene.build's own default spawn -- cell
        // center, facing south -- just set moments earlier) played out
        // as a real, visible several-frames-long interpolation: a fly
        // toward the nearest wall, a snap-rotate at the end, ANY
        // lighting artifact a too-close pass by a surface produced
        // along the way (physical testing showed exactly this: a
        // black frame, a zoom into brick, a blown-out white frame,
        // then a sudden rotate). SCNTransaction.disableActions makes
        // every assignment in this block instantaneous instead -- no
        // interpolation, no intermediate frame, ever. Also see
        // NavigationBridge.arrivalSceneReady in ContentView.swift,
        // which now keeps the arrival curtain fully closed until AFTER
        // this method has already run to completion, so even a slow
        // first-time floor build can never be exposed through it.
        SCNTransaction.begin()
        SCNTransaction.disableActions = true

        // Sept 26 (camera-heading coordinate-space fix): preservedYaw
        // is now a yaw RELATIVE to "facing the doors" (see its capture
        // site in playElevatorRide's arrival block above), not a raw
        // absolute world angle -- nil (passive ride) still means
        // exactly "facing the doors," now spelled as a zero offset from
        // this SAME destination floor's own baseline instead of a
        // borrowed one from wherever the ride started.
        let yaw = direction.opposite.yaw + (preservedYaw ?? 0)
        cameraNode.eulerAngles = SCNVector3(0, Float(yaw), 0)
        facing = Direction.allCases.min { a, b in
            abs(shortestDelta(from: yaw, to: a.yaw)) < abs(shortestDelta(from: yaw, to: b.yaw))
        } ?? facing

        let elevatorGeometry = HallwayScene.ElevatorGeometry(cellSize: cellSize)
        let entryDistance = elevatorGeometry.entryDistance
        let mountDeltaX = CGFloat(direction.delta.col)
        let mountDeltaZ = CGFloat(direction.delta.row)
        arrivedElevatorDoorOpen = true
        // Suppress the sign atomically with cab placement, before arrival is
        // revealed. Mission updates must keep it absent until the exit ends.
        refreshElevatorMissionSign()
        elevatorEntryCellCenterPosition = cameraNode.position
        cameraNode.position = SCNVector3(
            cameraNode.position.x + Float(mountDeltaX * entryDistance),
            cameraNode.position.y,
            cameraNode.position.z + Float(mountDeltaZ * entryDistance))
        elevatorAwaitingEntryDirection = direction.opposite

        // Eddie, Sept 16 (spatially-truthful controlled arrival): a
        // PASSIVE arrival keeps this exact instant-open -- proven
        // correct, and the camera yaw set above is always dead-on the
        // real doorway for a passive ride, so there's nothing to look
        // spatially wrong from. A CONTROLLED arrival leaves the real
        // doors CLOSED here instead: the camera could be facing
        // anywhere, so instantly moving doors nobody can currently
        // verify are even in frame is invisible bookkeeping that
        // would contradict what's about to be revealed. ContentView's
        // curtain calls playControlledArrivalDoorOpen() (below) the
        // instant it starts revealing a controlled arrival, which is
        // what actually animates these same doors open for real, at
        // their real 3D location -- see that method's own comment.
        if preservedYaw == nil {
            let alongWallX: CGFloat
            let alongWallZ: CGFloat
            switch direction {
            case .north, .south: (alongWallX, alongWallZ) = (1, 0)
            case .east, .west: (alongWallX, alongWallZ) = (0, 1)
            }
            let slide: CGFloat = 0.8
            leftDoor.position = SCNVector3(
                leftClosed.x - Float(slide * alongWallX),
                leftClosed.y,
                leftClosed.z - Float(slide * alongWallZ))
            rightDoor.position = SCNVector3(
                rightClosed.x + Float(slide * alongWallX),
                rightClosed.y,
                rightClosed.z + Float(slide * alongWallZ))
        }

        SCNTransaction.commit()

    }

    /// Visual-only response to the existing arrival-opening presentation.
    /// The action belongs to the destination light, never the camera or doors.
    func playArrivalLightWash(openingDuration: TimeInterval) {
        guard arrivedElevatorDoorOpen,
              let node = scene?.rootNode.childNode(withName: "elevatorExteriorWarmWash", recursively: true),
              let light = node.light else { return }
        func ramp(from start: CGFloat, to end: CGFloat, duration: TimeInterval) -> SCNAction {
            SCNAction.customAction(duration: duration) { node, elapsed in
                let t = min(1, elapsed / CGFloat(duration))
                let eased = t * t * (3 - 2 * t)
                node.light?.intensity = start + (end - start) * eased
            }
        }
        node.runAction(.sequence([
            ramp(from: light.intensity, to: 70, duration: openingDuration),
            ramp(from: 70, to: 26, duration: 1.5),
            .run { $0.light?.intensity = 26 }
        ]), forKey: "elevatorArrivalLightWash")
    }

    /// Guards playControlledArrivalDoorOpen() below against firing
    /// twice for the same arrival.
    private var controlledArrivalDoorsOpened = false

    /// Eddie, Sept 16 (spatially-truthful controlled arrival): called
    /// once by ContentView's ElevatorCurtainOverlay, the instant it
    /// starts revealing a CONTROLLED arrival (never for a passive
    /// one -- see arrivalWasControlled in ContentView.swift). A
    /// passive arrival's doors were already moved to their open
    /// position, instantly, inside presentArrivalInsideElevator --
    /// safe there because that arrival's camera yaw is always dead-on
    /// the real doorway. A controlled arrival's camera can be facing
    /// anywhere, so presentArrivalInsideElevator deliberately left
    /// these same doors CLOSED (see its own comment) -- this is what
    /// actually opens them, for real, animating the real 3D door
    /// nodes at their real physical location using the EXACT same
    /// slide distance/duration/easing openElevator() already uses to
    /// open boarding doors, so the destination doors open the same
    /// way any doors in this game ever do. Being real geometry
    /// instead of a screen-space effect, this reads correctly from
    /// whatever angle the player's camera actually happens to be at
    /// -- dead ahead, a partial corner view, or entirely offscreen if
    /// they're looking the other way -- with no dependency on the
    /// camera being centered on them at all.
    func playControlledArrivalDoorOpen() {
        guard arrivedElevatorDoorOpen, !controlledArrivalDoorsOpened else { return }
        guard let leftDoor = elevatorLeftDoor, let rightDoor = elevatorRightDoor,
              let direction = elevatorMountDirection else {
            return
        }
        controlledArrivalDoorsOpened = true

        let alongWallX: CGFloat
        let alongWallZ: CGFloat
        switch direction {
        case .north, .south: (alongWallX, alongWallZ) = (1, 0)
        case .east, .west: (alongWallX, alongWallZ) = (0, 1)
        }
        // Same constants as openElevator()'s own boarding-door open,
        // on purpose -- Eddie: "if the current normal Hallways
        // turn/snap animation can be reused safely, prefer
        // consistency." Doors should open the same way everywhere.
        let slide: CGFloat = 0.8
        let elevatorSlideDuration: TimeInterval = 1.6
        let openLeft = SCNAction.moveBy(x: -slide * alongWallX, y: 0, z: -slide * alongWallZ, duration: elevatorSlideDuration)
        let openRight = SCNAction.moveBy(x: slide * alongWallX, y: 0, z: slide * alongWallZ, duration: elevatorSlideDuration)
        openLeft.timingMode = .easeInEaseOut
        openRight.timingMode = .easeInEaseOut
        leftDoor.runAction(openLeft)
        rightDoor.runAction(openRight)
    }

    /// The ONE legal forward move while elevatorAwaitingEntryDirection
    /// is set -- called from advance() once its own canGoForward guard
    /// has already confirmed facing matches that direction. Animates
    /// straight back to the real hallway cell center captured in
    /// presentArrivalInsideElevator (a plain move(to:), not a relative
    /// offset, so there's no float-drift risk of ending up slightly
    /// off-center) using normal walking speed and tap/held easing, then clears the awaiting-entry
    /// state so canGoForward/openDirections govern ordinary movement
    /// again from here on, exactly like every other floor.
    private func performElevatorEntryWalkOut() {
        guard let target = elevatorEntryCellCenterPosition else {
            elevatorAwaitingEntryDirection = nil
            return
        }
        performElevatorThresholdWalk(to: target, entering: false)
    }

    private func performElevatorThresholdWalk(to target: SCNVector3, entering: Bool) {
        // Eddie, Sept 16 (unified release-snap / no persistent
        // mismatch): a controlled arrival can still be sitting at its
        // raw preserved (non-cardinal) camera yaw right up until the
        // player's first fresh swipe-release -- see
        // presentArrivalInsideElevator's own comment and
        // endElevatorCameraDrag() above. If a tap/hold arrives FIRST,
        // instead, this is the one place that matters: the instant
        // before a scripted walk (out through the doorway, or back
        // in) actually starts moving. Snapping the visual yaw to
        // `facing`'s exact cardinal here, instantly (no implicit
        // animation, same SCNTransaction.disableActions technique as
        // presentArrivalInsideElevator), guarantees the player is
        // never seen walking a straight cardinal line while visually
        // facing an arbitrary angle -- "movement = east" and "visual
        // yaw = east" can never disagree. A no-op for a passive
        // arrival or anyone who already swiped-and-released, since
        // the camera's already sitting exactly there.
        let targetYaw = Float(facing.yaw)
        if abs(cameraNode.eulerAngles.y - targetYaw) > 0.001 {
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            cameraNode.eulerAngles = SCNVector3(0, targetYaw, 0)
            SCNTransaction.commit()
        }
        let start = cameraNode.position
        let distance = hypot(Double(target.x - start.x), Double(target.z - start.z))
        let heldExit = walkingHeld
        movementPace = 1
        SoundEffects.setWalkingPace(1)
        phase = .scriptedWalkOut
        isAnimating = true
        // Same world-space speed and smoothstep as a normal single tap.
        // Held walking is linear, as in the grid renderer's continuousRun path.
        let move = SCNAction.move(to: target, duration: distance / travelSpeed)
        move.timingFunction = { t in heldExit ? t : t * t * (3 - 2 * t) }
        SoundEffects.startWalking()
        cameraNode.runAction(move, forKey: "elevatorManualWalkOut") { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                SoundEffects.stopWalking()
                if heldExit && self.walkingHeld { self.heldDistance += distance }
                self.elevatorAwaitingEntryDirection = entering ? self.elevatorMountDirection?.opposite : nil
                self.isAnimating = false
                self.phase = .translate
                if !entering {
                    let wasArrival = self.arrivedElevatorDoorOpen
                    self.closeArrivedElevatorAfterExit()
                    self.refreshElevatorMissionSign()
                    // Continue through the normal grid planner exactly once. The
                    // lobby ceremony and later returns to this cell are untouched.
                    if wasArrival, self.floorNumber != 1, !self.isMissionComplete {
                        self.advance(source: "MISSION_ARRIVAL")
                    }
                }
                navLog("performElevatorEntryWalkOut() finished -- ordinary navigation resumes")
            }
        }
    }

    /// Reaching the hallway center completes arrival: retire its temporary
    /// connection and close behind the player. Subsequent visits use the normal
    /// mission-gated boarding path, not the arrival-only threshold path.
    private func closeArrivedElevatorAfterExit() {
        guard arrivedElevatorDoorOpen,
              let left = elevatorLeftDoor, let right = elevatorRightDoor,
              let leftClosed = elevatorLeftClosedPosition,
              let rightClosed = elevatorRightClosedPosition else { return }
        arrivedElevatorDoorOpen = false
        elevatorEntryCellCenterPosition = nil
        // Controlled arrival may still be opening when a quick exit finishes.
        // Cancel that motion and close from the current pose to absolute targets.
        left.removeAllActions()
        right.removeAllActions()
        let closeLeft = SCNAction.move(to: leftClosed, duration: 1.6)
        let closeRight = SCNAction.move(to: rightClosed, duration: 1.6)
        closeLeft.timingMode = .easeInEaseOut
        closeRight.timingMode = .easeInEaseOut
        left.runAction(closeLeft, forKey: "arrivalCloseBehind")
        right.runAction(closeRight, forKey: "arrivalCloseBehind")
    }

    func openElevator() {
        guard elevatorLeftDoor?.action(forKey: "arrivalCloseBehind") == nil,
              elevatorRightDoor?.action(forKey: "arrivalCloseBehind") == nil else { return }
        guard currentCell == endCell, !elevatorInUse, !chuteInUse, elevatorAwaitingEntryDirection == nil,
              let leftDoor = elevatorLeftDoor, let rightDoor = elevatorRightDoor,
              let direction = elevatorMountDirection else { return }
        guard isMissionComplete else {
            // Keep the existing rejection feedback. The persistent system
            // sign already explains the mission; no door-mounted notice.
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            SoundEffects.playWarningBuzz()
            refreshElevatorMissionSign()
            elevatorRejected = ElevatorRejectionEvent()
            return
        }
        refreshElevatorMissionSign()
        elevatorInUse = true
        // Eddie, Sept 15 (elevator camera control): a fresh ride
        // starts with auto-spin back in play by default -- only a
        // beginElevatorCameraDrag() call during THIS ride flips it
        // back off. Without this reset, a player who took control on
        // one ride would silently suppress the automatic spin on
        // every ride after it too.
        playerHasTakenElevatorCameraControl = false

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

        // Derive the cab center from the same geometry used to build it.
        // Scale duration with distance to preserve the existing entry speed/easing.
        let elevatorGeometry = HallwayScene.ElevatorGeometry(cellSize: cellSize)
        let dollyDistance = elevatorGeometry.entryDistance
        let dolly = SCNAction.move(by: SCNVector3(Float(forwardX * dollyDistance), 0, Float(forwardZ * dollyDistance)), duration: elevatorGeometry.entryDuration)
        dolly.timingMode = .easeInEaseOut
        // Eddie, Sept 12: "Slow ONLY that turnaround animation by
        // approximately 25%... determine the current duration and
        // increase it by approximately 25%, rather than replacing the
        // animation." Was 2.6 -- 2.6 * 1.25 = 3.25.
        // Eddie, Sept 13, follow-up: "Please add 1.5 seconds to the
        // full rotation duration: 3.25s -> 4.75s. Change only the
        // rotation duration itself." 3.25 + 1.5 = 4.75. Nothing else
        // here is keyed to this specific number: closeDoorsNow()
        // already ran during the fixed 2.0s dwell before this action
        // even starts, and the floor-transition handoff below waits
        // on rotate's own completion callback (a fixed 0.3s after
        // whatever duration this action actually takes -- see that
        // dwell's own comment below for why it was shortened from the
        // original 1.0s), so slowing just this one number is enough
        // -- no other timing to rebalance. Final facing direction is
        // still the same .pi turn, just slower to get there.
        // Eddie, Sept 15 (elevator camera control) addendum: "the
        // floor-transition handoff below waits on rotate's own
        // completion callback" above is no longer literally true --
        // it now waits on a plain asyncAfter(rotate.duration + 0.3)
        // instead, so arrival still fires at that exact same total
        // offset whether the spin plays in full, gets cut short by
        // the player taking camera control, or never starts at all.
        // See playElevatorRide's own comment further down for why.
        let rotate = SCNAction.rotateBy(x: 0, y: .pi, z: 0, duration: 4.75)
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
                    // Eddie, Sept 15 (elevator camera control): only
                    // play the automatic 180 spin if the player
                    // hasn't already grabbed the camera during this
                    // ride (see beginElevatorCameraDrag()). Runs
                    // under its own dedicated action key so a LATER
                    // beginElevatorCameraDrag() call -- the player
                    // grabbing the screen mid-spin -- can cancel just
                    // this one action without ever touching the dolly
                    // above (long since finished; dolly and rotate
                    // are strictly sequential, never concurrent).
                    if !self.playerHasTakenElevatorCameraControl {
                        self.cameraNode.runAction(rotate, forKey: Self.elevatorAutoSpinActionKey)
                    }
                    // Eddie, Sept 12, 2nd follow-up: "after the 180-
                    // degree turn completes, I now sit looking at the
                    // closed elevator doors for noticeably too long
                    // before the doors begin opening... shorten that
                    // dead pause substantially so the sequence feels
                    // continuous." Was a flat 1.0s of pure dead time
                    // (nothing on screen changes -- doors already
                    // closed, camera already still) between the
                    // pivot's own completion and floorTransitionRequested
                    // even firing, on top of the curtain's own further
                    // 0.2s + elevatorDoorOpeningDelay (0.08s) before it
                    // starts sliding open (see ElevatorCurtainOverlay
                    // in ContentView.swift) -- 1.28s of dead air in
                    // total. 0.3s here is just enough of a beat to
                    // read as an intentional pause ("we've arrived")
                    // rather than a stall, cutting the dead time to
                    // 0.58s total without touching that separate
                    // curtain-side timing at all. Safe with respect
                    // to the relit-flash fix just below: restoreShaftLighting()
                    // is still deferred a further 0.1s AFTER
                    // floorTransitionRequested fires (unchanged), so
                    // their relative order -- curtain covers the
                    // screen, THEN the old shaft relights -- holds no
                    // matter how long this outer dwell is.
                    //
                    // Eddie, Sept 15 (elevator camera control): this
                    // used to be scheduled from INSIDE rotate's own
                    // SCNAction completion handler (a fixed 0.3s after
                    // whatever duration that action actually took).
                    // Combined into one plain wait of rotate.duration
                    // + 0.3 instead, so arrival fires at the exact
                    // same total offset from this point whether the
                    // spin played in full, got cancelled mid-flight by
                    // the player taking camera control, or never
                    // started at all -- "player camera control must
                    // not affect elevator timing."
                    DispatchQueue.main.asyncAfter(deadline: .now() + rotate.duration + 0.3) { [weak self] in
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
                        // (via onReachedEnd), THEN restore.
                        self.floorTransitionRequested = FloorTransitionEvent()
                        // Eddie, Sept 15 (elevator camera control --
                        // manual exit): a passive ride still fires
                        // onReachedEnd here exactly as it always did
                        // -- unchanged. A ride the player took camera
                        // control on instead fires
                        // onElevatorArrivedControlled(yaw:) -- the
                        // SAME doorSnapshot/floorTransitionRequested/
                        // controller=nil/advanceToNextMaze() sequence
                        // onReachedEnd itself performs (arrival sound,
                        // Muzak-stop, curtain-open, and the real floor
                        // advance all still happen right here, on
                        // schedule, exactly like a passive ride), just
                        // carrying the camera's current preserved yaw
                        // along so the brand-new destination floor's
                        // controller can restore it (see
                        // presentArrivalInsideElevator(preservedYaw:) above) instead
                        // of spawning at the normal default facing.
                        //
                        // Sept 26 (camera-heading coordinate-space fix):
                        // this USED to hand off cameraNode.eulerAngles.y
                        // verbatim -- a raw yaw in THIS (source) floor's
                        // own world space, which is only meaningful
                        // relative to THIS floor's own elevatorMountDirection
                        // (a different floor's elevator can be mounted on
                        // a different compass wall entirely). Applied
                        // as-is on the destination camera, whose world
                        // space is anchored to a DIFFERENT
                        // elevatorMountDirection, that raw value silently
                        // added/subtracted whatever constant compass
                        // offset separates the 2 floors' elevators --
                        // physically verified as a consistent one-wall
                        // (~90 degree) rotation. Converting to a yaw
                        // RELATIVE to this floor's own "facing the doors"
                        // baseline (elevatorMountDirection.opposite.yaw --
                        // the same reference presentArrivalInsideElevator
                        // already uses for the passive/default case) makes
                        // the handoff coordinate-space-agnostic: whatever
                        // this baseline-relative offset is, reapplying it
                        // to the DESTINATION's own baseline (see
                        // presentArrivalInsideElevator below) preserves
                        // the player's actual chosen heading exactly, at
                        // any arbitrary (non-cardinal) angle, regardless
                        // of how the 2 floors' elevators are compass-mounted.
                        if self.playerHasTakenElevatorCameraControl {
                            let rawYaw = Double(self.cameraNode.eulerAngles.y)
                            let sourceFacingDoorsYaw = self.elevatorMountDirection?.opposite.yaw ?? rawYaw
                            let relativeYaw = rawYaw - sourceFacingDoorsYaw
                            self.onElevatorArrivedControlled?(relativeYaw)
                        } else {
                            self.onReachedEnd?()
                        }
                        // Sept 14 (Eddie): elevator music now keeps
                        // playing through this whole closed-door pause
                        // instead of cutting off right here -- the
                        // stop call moved to the moment the doors
                        // actually start opening, in ContentView.swift's
                        // ElevatorCurtainOverlay
                        // (onChange(of: floorTransitionRequested)),
                        // right before its
                        // withAnimation { openFraction = 1 }.
                        // Eddie, Sept 12: "before the doors begin
                        // opening, the view changes/glitches" --
                        // a real second bug in this same spot.
                        // "the scene's about to be torn down for
                        // the next floor regardless" (this
                        // comment's own prior claim, just above)
                        // turned out to be wrong: onReachedEnd
                        // only mutates @Published state
                        // (navBridge.controller = nil,
                        // mazeStore.advanceToNextMaze(), which
                        // flips mazeStore.currentMazeID) --
                        // SwiftUI doesn't actually tear down and
                        // rebuild HallwaySceneView (via its
                        // .id(sceneVersion)) until ITS OWN next
                        // render pass reacts to that, which is
                        // not instant. This OLD scene's SCNView
                        // keeps right on rendering, live, for at
                        // least that long -- so restoreShaftLighting()
                        // running immediately, right here,
                        // snapped the STILL-VISIBLE old shaft
                        // back to full brightness for a frame or
                        // more before the curtain (a separate
                        // SwiftUI overlay reacting to
                        // navBridge.floorTransitionRequested,
                        // also not necessarily composited the
                        // instant it's set) actually covered it
                        // -- a real, briefly-visible relit flash
                        // of the OLD, about-to-be-replaced shaft,
                        // not a camera/transform/poster glitch.
                        // Deferring the restore past that window
                        // (well under the curtain's own first
                        // visible beat, so nothing about the
                        // curtain/arrival timing changes) means
                        // it only ever happens once the curtain
                        // is already covering the screen.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
        if kind == .trashCan { SoundEffects.playTrashChuteOpen() }
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
                    if kind == .trashCan { SoundEffects.playTrashChuteClose() }
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

    /// Wording belongs to gameplay; the renderer only receives semantic content.
    private var elevatorMissionWarningContent: ElevatorMissionWarningSign.Content? {
        let instruction: String
        var status: String?
        if !fireCoords.isEmpty {
            instruction = "Please extinguish all fires before using the elevator."
            status = fireMissionProgress
        } else if !photoBoothExpressions.isEmpty {
            instruction = "Please take your employee ID photo before using the elevator."
            status = photoBoothMissionProgress
        } else if !ticTacToeDirections.isEmpty {
            instruction = "EMPLOYEE APTITUDE TEST REQUIRED. FIND THE TERMINAL AND PASS THE TEST BEFORE USING THE ELEVATOR."
        } else if !shellGameDirections.isEmpty {
            instruction = "FIND THE BALL BEFORE USING THE ELEVATOR. THE SHELL GAME IS DOWN THE HALL."
        } else if !rockPaperScissorsDirections.isEmpty {
            instruction = "BEAT THE BUILDING AT ROCK PAPER SCISSORS BEFORE USING THE ELEVATOR."
        } else if !higherLowerDirections.isEmpty {
            instruction = "GET 3 CORRECT GUESSES IN A ROW BEFORE USING THE ELEVATOR."
        } else if !fiveCardDrawDirections.isEmpty {
            instruction = "MAKE A QUALIFYING POKER HAND (PAIR OR BETTER) BEFORE USING THE ELEVATOR."
        } else if !simonDirections.isEmpty {
            instruction = "PASS THE BUILDING'S MEMORY TEST BEFORE USING THE ELEVATOR."
        } else if !hangmanDirections.isEmpty {
            instruction = "SOLVE THE WORD BEFORE USING THE ELEVATOR."
        } else if !connectFourDirections.isEmpty {
            instruction = "WIN A GAME OF CONNECT FOUR BEFORE USING THE ELEVATOR."
        } else if !checkersDirections.isEmpty {
            instruction = "WIN A GAME OF CHECKERS BEFORE USING THE ELEVATOR."
        } else if !woidleDirections.isEmpty {
            instruction = "PASS THE WORD ASSESSMENT BEFORE USING THE ELEVATOR."
        } else if let kind = missionObjectKind {
            let remaining = objectKinds.filter { $0.value == kind && !collectedCoords.contains($0.key) }.count
            let carried = kind == .envelope ? carriedMail.count : collectedObjects.filter { $0 == kind }.count
            if kind == .paintBucket {
                instruction = "Paint every hallway before using the elevator."
                status = "\(cells.count - paintedCells.count) hallway cells need paint. \(hasPaintBucket ? "Check the wall maps." : "Find the blue paint bucket.")"
            } else {
                instruction = "Collect and deliver all \(kind.missionLegendLabel.lowercased()) before using the elevator."
                status = "\(remaining) left to collect. \(carried) still to drop off."
            }
        } else {
            return nil
        }
        return .init(headline: "MISSION IN PROGRESS", instruction: instruction, status: status)
    }

    private func refreshElevatorMissionSign() {
        guard !arrivedElevatorDoorOpen, !isMissionComplete, let content = elevatorMissionWarningContent,
              let scene, let left = elevatorLeftDoor, let right = elevatorRightDoor,
              let leftClosed = elevatorLeftClosedPosition, let rightClosed = elevatorRightClosedPosition,
              let direction = elevatorMountDirection else {
            elevatorMissionSign?.node.removeFromParentNode()
            elevatorMissionSign = nil
            return
        }
        let sign = elevatorMissionSign ?? ElevatorMissionWarningSign()
        sign.place(left: left.parent?.convertPosition(leftClosed, to: scene.rootNode) ?? leftClosed,
                   right: right.parent?.convertPosition(rightClosed, to: scene.rootNode) ?? rightClosed,
                   direction: direction, cellSize: cellSize)
        sign.update(content)
        if sign.node.parent == nil { scene.rootNode.addChildNode(sign.node) }
        elevatorMissionSign = sign
    }

    func isElevatorMissionSign(_ node: SCNNode) -> Bool {
        var candidate: SCNNode? = node
        while let current = candidate {
            if current === elevatorMissionSign?.node { return true }
            candidate = current.parent
        }
        return false
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

    #if DEBUG
    // Sept 22 (Eddie: presentation-vs-model investigation). A SEPARATE
    // delegate callback from updateAtTime below (SCNSceneRendererDelegate
    // allows implementing any subset) -- didRenderScene fires AFTER
    // SceneKit has drawn a frame, so `scene`'s nodes' `.presentation`
    // values here are guaranteed to reflect what was actually put on
    // screen for that frame, not an intermediate or not-yet-applied
    // value. Fires every frame; the pendingPresentationCheckBuildNumber
    // guard above makes sure this only ever DOES anything on the first
    // frame after a Floor-2 rebuild, once.
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard let buildNumber = pendingPresentationCheckBuildNumber else { return }
        pendingPresentationCheckBuildNumber = nil
        LightingDeterminismCheck.runPresentationCheck(scene: scene, floor: floorNumber, buildNumber: buildNumber, checkpoint: "FIRST-RENDERED-FRAME")
    }
    #endif

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        defer { lastTime = time }
        applyAspectCompensation(renderer)

        // Round 7 (Eddie): the handheld map used to pause the whole
        // scene by returning here -- "the map should behave like a
        // physical map being held up while the player continues
        // walking" removes that pause entirely. This callback (and the
        // HERE-marker refresh inside applyArrival, further down) now
        // keeps running exactly the same whether or not the map is
        // visible.
        guard lastTime > 0 else { return }
        let dt = min(time - lastTime, 1.0 / 20.0)
        guard dt > 0, isAnimating else { return }

        switch phase {
        case .awaitingTurnCommit, .scriptedWalkOut:
            return

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
                // Stop render-side progression before queueing the main-thread
                // completion. Otherwise another frame can fall through into
                // .translate and replay the previous walk from segmentStart.
                phase = .awaitingTurnCommit
                standaloneRotation = false
                let newFacing = pendingRotationTarget
                DispatchQueue.main.async { [weak self] in
                    self?.applyNavigationUpdate { [weak self] in
                        self?.facing = newFacing
                        // Sept 21 (present-once-then-allow-pass): a turn
                        // re-presents whatever's ahead fresh next time --
                        // see presentedPickupCoord's own doc comment.
                        self?.presentedPickupCoord = nil
                        self?.isAnimating = false
                        if let self {
                            self.activatePhotoBooth(at: self.currentCell)
                            self.activateTicTacToeTerminal(at: self.currentCell)
                            self.activateShellGameTerminal(at: self.currentCell)
                            self.activateRockPaperScissorsTerminal(at: self.currentCell)
                            self.activateHigherLowerTerminal(at: self.currentCell)
                            self.activateFiveCardDrawTerminal(at: self.currentCell)
                            self.activateSimonTerminal(at: self.currentCell)
                            self.activateHangmanTerminal(at: self.currentCell)
                            self.activateConnectFourTerminal(at: self.currentCell)
                            self.activateCheckersTerminal(at: self.currentCell)
                            self.activateWoidleTerminal(at: self.currentCell)
                            self.logNavSync("TURN COMPLETE")
                        }
                        navLog("rotate complete -- now facing \(newFacing)")
                    }
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
            let segmentDuration = Double(cellSize) * Double(animationSteps.count) / travelSpeed * translateDurationScale
            let targetPace = walkingHeld && heldDistance >= 2 * Double(cellSize) ? 1.6 : 1.0
            movementPace += (targetPace - movementPace) * (1 - exp(-dt / 0.3))
            SoundEffects.setWalkingPace(Float(movementPace))
            let previousProgress = min(1.0, segmentProgress)
            segmentProgress += dt * movementPace / max(segmentDuration, 0.001)
            let t = min(1.0, segmentProgress)
            let eased = continuousRun ? t : t * t * (3 - 2 * t)
            let previousEased = continuousRun ? previousProgress : previousProgress * previousProgress * (3 - 2 * previousProgress)
            if walkingHeld { heldDistance += (eased - previousEased) * Double(cellSize) * Double(animationSteps.count) }

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
                        self?.applyNavigationUpdate { [weak self] in
                            guard let self else { return }
                            // facing before currentCell -- arrival order matters
                            self.applyArrival(cell: newCell, heading: newFacing)
                            self.markFloorMapViewedIfPresent(at: newCell)
                            self.markMissionSignViewedIfPresent(at: newCell)
                            self.logNavSync("MID-RUN ARRIVAL")
                            navLog("arrived at \(newCell) facing \(newFacing) -- mid-run")
                        }
                    }
                } else {
                    let outcome = pendingOutcome
                    DispatchQueue.main.async { [weak self] in
                        self?.applyNavigationUpdate { [weak self] in
                            guard let self else { return }
                            self.isAnimating = false
                            self.translateDurationScale = 1.0
                            SoundEffects.stopWalking()
                            // facing before currentCell -- arrival order matters
                            self.applyArrival(cell: newCell, heading: newFacing)
                            self.markFloorMapViewedIfPresent(at: newCell)
                            self.markMissionSignViewedIfPresent(at: newCell)
                            self.activatePhotoBooth(at: newCell)
                            self.activateTicTacToeTerminal(at: newCell)
                            self.activateShellGameTerminal(at: newCell)
                            self.activateRockPaperScissorsTerminal(at: newCell)
                            self.activateHigherLowerTerminal(at: newCell)
                            self.activateFiveCardDrawTerminal(at: newCell)
                            self.activateSimonTerminal(at: newCell)
                            self.activateHangmanTerminal(at: newCell)
                            self.activateConnectFourTerminal(at: newCell)
                            self.activateCheckersTerminal(at: newCell)
                            self.activateWoidleTerminal(at: newCell)
                            self.logNavSync("WALK FINISHED — outcome=\(outcome)")
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
            }

            guard t >= 1.0 else { return }
            cameraNode.position = segmentTarget
        }
    }
}
