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
    /// Oct 25 (PP 8, the mud fix): this scene's drawn camera pose and elevator door, captured once per
    /// rendered frame (renderer(_:didRenderScene:atTime:)) so main-thread timers needn't wait on SceneKit's
    /// scene lock to read them. One per controller: a new scene never sees the old one's values.
    let presentationSnapshot = PresentationSnapshot()
    private let cells: Set<GridCoordinate>
    private let cellSize: CGFloat
    private let endCell: GridCoordinate
    /// Seeded from the camera HallwayScene built (PlayerHeight's eye
    /// height); changed live by setEyeHeight(_:) when Your Height changes.
    private(set) var eyeHeight: Float
    /// Units/sec while animating between cell centers.
    private let travelSpeed: Double = 6.0
    /// Oct 20 ("automatic walking feels a little too fast"): every AUTOMATIC walk
    /// -- a tap walk (and the glides a tap on a door or a desk makes), the
    /// continuous walk (following a critter, a Smart Tap walk) and the latched
    /// walk with no finger on it -- goes at 0.8 of its old pace. Not changed: the
    /// hand-held walk and drags, the elevator (its threshold walk and rides),
    /// residents, turning and looking, and an escort's walk (Mr. Tinky's, and GO
    /// to his desk after the ID: their pacing stays exactly as it was).
    static let autoWalkSpeedScale: Double = 0.8
    /// The continuous walk's pace factor: the escort's own walk is left as it was.
    static func continuousWalkPaceScale(escorting: Bool) -> Double { escorting ? 1 : autoWalkSpeedScale }
    /// A tap walk's speed (m/s).
    var autoWalkSpeed: Double { travelSpeed * Self.autoWalkSpeedScale }
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
    /// Oct 7: the player's cell just changed (Administration: leaving the
    /// counter stops Juanita's patience timer).
    var onCellChanged: ((GridCoordinate) -> Void)?
    /// Oct 24 (onboarding polish): the player's heading changed (after a turn settles).
    var onFacingChanged: ((Direction) -> Void)?
    /// Oct 11: the PLAYER opened a Room Entrance door (tap or WALK) -- not a character.
    var onRoomEntranceDoorOpened: ((GridCoordinate) -> Void)?
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
    /// Oct 5 (elevator staging): fired the moment a valid floor button is
    /// pressed, so the destination floor can be built during the ride.
    var onElevatorDestinationChosen: ((Int) -> Void)?
    /// Oct 24 (onboarding polish): the floor the building is about to press for the
    /// player (Admission's first ride), known ~2 s before the press -- so it can
    /// start being prepared early for the shorter ride.
    var onElevatorDestinationForeseen: ((Int) -> Void)?
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
            diag("nav.cell", ["cell": currentCell, "from": oldValue, "facing": facing])   // Oct 8 flight recorder
            onCellChanged?(currentCell)
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
            diag("nav.facing", ["facing": facing, "from": oldValue, "cell": currentCell])   // Oct 8 flight recorder
            refreshFloorMapTexture()
            onFacingChanged?(facing)
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
    private var ticTacToeTerminalNodes: [GridCoordinate: SCNNode]
    private var ticTacToeDirections: [GridCoordinate: Direction]
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
    private var shellGameStationNodes: [GridCoordinate: SCNNode]
    private var shellGameDirections: [GridCoordinate: Direction]
    /// Non-nil while the shell-game overlay is on screen -- same shape
    /// as activeTicTacToeTerminal.
    @Published private(set) var activeShellGameTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER taps the correct cup -- see
    /// isMissionComplete. Same one-Bool shape as ticTacToeWon.
    @Published private(set) var shellGameWon = false { didSet { refreshElevatorMissionSign() } }
    private var rockPaperScissorsTerminalNodes: [GridCoordinate: SCNNode]
    private var rockPaperScissorsDirections: [GridCoordinate: Direction]
    /// Non-nil while the Rock Paper Scissors overlay is on screen --
    /// same shape as activeShellGameTerminal.
    @Published private(set) var activeRockPaperScissorsTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER's move beats the computer's --
    /// see isMissionComplete. Same one-Bool shape as shellGameWon.
    @Published private(set) var rockPaperScissorsWon = false { didSet { refreshElevatorMissionSign() } }
    private var higherLowerTerminalNodes: [GridCoordinate: SCNNode]
    private var higherLowerDirections: [GridCoordinate: Direction]
    /// Non-nil while the Higher/Lower overlay is on screen -- same
    /// shape as activeRockPaperScissorsTerminal.
    @Published private(set) var activeHigherLowerTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER reaches a 3-correct streak --
    /// see isMissionComplete. Same one-Bool shape as rockPaperScissorsWon.
    @Published private(set) var higherLowerWon = false { didSet { refreshElevatorMissionSign() } }
    private var fiveCardDrawTerminalNodes: [GridCoordinate: SCNNode]
    private var fiveCardDrawDirections: [GridCoordinate: Direction]
    /// Non-nil while the Five-Card Draw overlay is on screen -- same
    /// shape as activeHigherLowerTerminal.
    @Published private(set) var activeFiveCardDrawTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER's final hand qualifies (pair
    /// or better) -- see isMissionComplete. Same one-Bool shape as
    /// higherLowerWon.
    @Published private(set) var fiveCardDrawWon = false { didSet { refreshElevatorMissionSign() } }
    private var simonTerminalNodes: [GridCoordinate: SCNNode]
    private var simonDirections: [GridCoordinate: Direction]
    /// Non-nil while the Simon overlay is on screen -- same shape as
    /// activeWhackAMoleTerminal.
    @Published private(set) var activeSimonTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER completes the length-5
    /// sequence -- see isMissionComplete. Same one-Bool shape as
    /// whackAMoleWon.
    @Published private(set) var simonWon = false { didSet { refreshElevatorMissionSign() } }
    private var hangmanTerminalNodes: [GridCoordinate: SCNNode]
    private var hangmanDirections: [GridCoordinate: Direction]
    /// Non-nil while the Hangman overlay is on screen -- same shape
    /// as activeSimonTerminal.
    @Published private(set) var activeHangmanTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER reveals the whole word -- see
    /// isMissionComplete. Same one-Bool shape as simonWon.
    @Published private(set) var hangmanWon = false { didSet { refreshElevatorMissionSign() } }
    private var connectFourTerminalNodes: [GridCoordinate: SCNNode]
    private var connectFourDirections: [GridCoordinate: Direction]
    /// Non-nil while the Connect Four overlay is on screen -- same
    /// shape as activeHangmanTerminal.
    @Published private(set) var activeConnectFourTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER wins a game -- see
    /// isMissionComplete. Same one-Bool shape as hangmanWon.
    @Published private(set) var connectFourWon = false { didSet { refreshElevatorMissionSign() } }
    private var checkersTerminalNodes: [GridCoordinate: SCNNode]
    private var checkersDirections: [GridCoordinate: Direction]
    /// Non-nil while the Checkers overlay is on screen -- same
    /// shape as activeConnectFourTerminal.
    @Published private(set) var activeCheckersTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER wins a game -- see
    /// isMissionComplete. Same one-Bool shape as connectFourWon.
    @Published private(set) var checkersWon = false { didSet { refreshElevatorMissionSign() } }
    private var woidleTerminalNodes: [GridCoordinate: SCNNode]
    private var woidleDirections: [GridCoordinate: Direction]
    /// Non-nil while the Woidle overlay is on screen -- same shape as
    /// activeCheckersTerminal.
    @Published private(set) var activeWoidleTerminal: GridCoordinate?
    /// Set once, the instant the PLAYER wins a game -- see
    /// isMissionComplete. Same one-Bool shape as checkersWon.
    @Published private(set) var woidleWon = false { didSet { refreshElevatorMissionSign() } }
    private(set) var extinguisherRestingTransforms: [GridCoordinate: (position: SCNVector3, eulerAngles: SCNVector3, scale: SCNVector3)]
    private var extinguishedFireCoords: Set<GridCoordinate> = [] {
        didSet {
            refreshElevatorMissionSign()
            // Oct 11 (resume): a fire put out stays out -- across floors and relaunches.
            if !decorateModeEnabled {
                ResumeState.markConsumed(.fire, floor: floorNumber, coords: extinguishedFireCoords.subtracting(oldValue))
            }
        }
    }
    @Published private(set) var carryingExtinguisher = false
    // (Oct 16 II: what is SEEN in hand is ToolBelt's -- holdHallwayExtinguisher /
    // dropHallwayExtinguisher. The old separate camera-attached node is gone.)
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
    private var collectedCoords: Set<GridCoordinate> = [] {
        didSet {
            refreshElevatorMissionSign()
            // Oct 11 (resume): a collected object stays collected -- across floors and relaunches.
            if !decorateModeEnabled {
                ResumeState.markConsumed(.object, floor: floorNumber, coords: collectedCoords.subtracting(oldValue))
            }
        }
    }
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
    @Published private(set) var openRoomEntranceDoors: Set<GridCoordinate> = [] {
        didSet { if openRoomEntranceDoors != oldValue { publishAcousticDoors() } }
    }

    /// Oct 9 (closed-door sound): tell the critter/building sound model which
    /// Room Entrance doors are shut right now (a door held open for show by a
    /// character counts as open -- the opening is real). Called on every
    /// change and once per floor install.
    func publishAcousticDoors() {
        let shut = roomEntranceDoors.filter { !openRoomEntranceDoors.contains($0.key) && !cosmeticallyOpenRoomEntranceDoors.contains($0.key) }
        CritterAudio.setClosedDoors(shut.map { (row: $0.key.row, col: $0.key.col, dRow: $0.value.delta.row, dCol: $0.value.delta.col) })
    }

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
    /// Oct 7: the open cab came from boarding here, not from a ride's arrival.
    private var elevatorBoardedDoorsOpen = false
    private var arrivalExitPermitted = false
    var canStartElevatorExit: Bool { elevatorAwaitingEntryDirection != nil && arrivalExitPermitted && !elevatorInUse }
    var canReenterArrivedElevator: Bool {
        arrivedElevatorDoorOpen && elevatorAwaitingEntryDirection == nil &&
        currentCell == endCell && facing == elevatorMountDirection
    }
    private var forwardConnectionIsOpen: Bool {
        // Oct 4: inside the just-arrived cab, the way out is always the way
        // out -- whatever the heading; the walk-out turns gracefully to it.
        if let exit = elevatorAwaitingEntryDirection { return arrivalExitPermitted && (Self.interactiveElevator || facing == exit) }
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
    var diagnosticElevatorDragAccepted: Bool { isDraggingElevatorCamera }
    /// Dedicated SCNAction key for the ride's automatic 180 spin --
    /// letting beginElevatorCameraDrag() cancel JUST this action via
    /// removeAction(forKey:) (which does NOT fire that action's
    /// completion handler) without ever touching the ride's forward
    /// dolly, an unrelated position action that can still be
    /// in-flight on this same cameraNode this early in the ride.
    private static let elevatorAutoSpinActionKey = "elevatorAutoSpin"
    /// Oct 2 (yaw-normalization experiment): the carry-in's straighten-up
    /// turn. Own key so a manual camera grab cancels it, exactly like the
    /// auto-spin, without touching the position carry-in.
    private static let elevatorEntryAlignActionKey = "elevatorEntryAlign"

    // MARK: - Oct 4: the elevator is transportation (button panel)
    //
    // Enter -> doors close -> ONE combined turn-and-glide (like a picture
    // approach) to a square-on view of the cab's control panel -> WAITING,
    // stationary, for as long as it takes (free look allowed) -> tap a
    // floor button -> short beat -> TRAVELING -> arrive on THAT floor.

    /// false restores the old automatic "next floor" ride exactly.
    static let interactiveElevator = true
    /// TUNE: seconds for the combined pivot + glide to the panel view
    /// (the old back-wall dwell + automatic 180 was 2.0 + 4.75 s).
    static let elevatorPanelApproachDuration: TimeInterval = 1.6
    /// Deliberate, visible correction after an imprecise panel tap.
    static let elevatorPanelAssistDuration: TimeInterval = 2.8
    /// Oct 7: no longer used -- arrival doors stay open until the rider
    /// steps out or chooses a floor. Kept for reference only.
    static let elevatorArrivalDoorOpenDwell: TimeInterval = 8.0
    private static let elevatorArrivalDwellKey = "elevatorArrivalDwell"
    private var elevatorLookRevision = 0
    /// TUNE: the beat between a button press and the car starting to move.
    static let elevatorDepartBeat: TimeInterval = 0.1
    /// TUNE: closest the panel view stands (metres); farther if needed to
    /// fit the whole panel in frame.
    static let elevatorPanelMinViewDistance: Float = 1.2
    private static let elevatorPanelApproachActionKey = "elevatorPanelApproach"
    /// TUNE: seconds for the turn-and-glide that lines the player up square
    /// on the doorway (elevator cell centre, facing in) right after the tap,
    /// while the doors open. Must stay under the doors' opening time (~1.7 s)
    /// so it lands before the walk into the cab begins.
    static let elevatorEntryAlignDuration: TimeInterval = 1.0
    private static let elevatorEntryGlideActionKey = "elevatorEntryGlide"
    /// Oct 6: at arrival (the ding), a smooth turn to face the opening doors.
    private static let elevatorArrivalFaceDoorsActionKey = "elevatorArrivalFaceDoors"
    static let elevatorArrivalFaceDoorsDuration: TimeInterval = 1.4
    /// Oct 6: true while the player's look/pan gesture is down (set by
    /// ContentView's coordinator) -- an arrival never starts turning the
    /// camera out from under a finger.
    /// Returns a description of the player's touch gesture in progress
    /// right now (nil = no finger mid-gesture).
    var activeTouchGesture: (() -> String?)?
    /// Readable cadence: the destination number lands leadIn + ElevatorTiming.ride(floors:) after travel starts.
    /// This schedules digits only; there is no separate travel/arrival timer.
    static let elevatorIndicatorLeadIn: TimeInterval = 0.5
    static let elevatorIndicatorCountingSpan: TimeInterval = 4.5
    /// Oct 24 (onboarding polish): the first ride, Lobby -> Administration, which
    /// the building presses for the player (admissionAutoFloor): from the press to
    /// the destination number (the hand-off) in the depart beat + this, ~2.5 s
    /// (was 0.1 + 0.5 + ElevatorTiming.ride(1) = ~7.5 s with "1" showing). Only
    /// that ride: the escort's and the player's own rides keep their timing; the
    /// doors, chime, indicator and arrival hand-off are the same as ever.
    static let admissionRideSeconds: TimeInterval = 2.4
    // Oct 24 (later): the escort's ride (Tinky's, Floor 2 -> 3, guidedAutoFloor)
    // uses the same short pace. Both are the building's own one-floor rides; any
    // other scripted ride keeps the ordinary timing unless it is named here.

    /// Oct 18 (open the building): the car's one timing (ElevatorTiming -- the same
    /// as residents' rides, the hall signs and the scheduler): 35% slower than the
    /// old fixed 4.5 s count, and longer for a longer run. (Was: leadIn +
    /// elevatorIndicatorCountingSpan * step / steps.)
    static func elevatorIndicatorStepDelay(step: Int, steps: Int) -> TimeInterval {
        elevatorIndicatorLeadIn + ElevatorTiming.passing(step: step, of: max(1, steps))
    }
    private static let elevatorRecentreActionKey = "elevatorRecentre"
    /// Oct 18 (open the building): this floor's elevator surround (the shaft's
    /// sounds come from here), nil before a floor is built.
    var elevatorExteriorNode: SCNNode? { scene?.rootNode.childNode(withName: "elevatorExteriorFrame", recursively: true) }

    /// Floors that exist (set by ContentView); a button for any other number
    /// just clicks.
    var elevatorReachableFloors: Set<Int> = []
    /// Oct 5 (Admission): set by ContentView in the lobby while admission is
    /// pending -- the floor the building chooses for this trip (the normal
    /// button press + departure path does the rest). nil = the player chooses.
    var admissionAutoFloor: Int?
    /// Oct 6 (guided journey): a floor someone else chooses for this ride --
    /// asked live when the car starts waiting (nil = the player chooses).
    var guidedAutoFloor: (() -> Int?)?
    /// Oct 6 (guided journey): the player has just been accepted into the
    /// elevator here (doors about to open for boarding).
    var onElevatorBoarding: (() -> Void)?
    /// Oct 6 (guided journey): a controlled arrival's doors start opening.
    var onArrivalDoorsOpening: (() -> Void)?
    /// The floor chosen on the panel this ride (nil = old next-floor ride).
    private(set) var elevatorDestinationFloor: Int?
    /// WAITING: doors shut, stationary, panel live.
    private(set) var isElevatorWaitingForFloor = false
    /// This ride's cab centre (for the panel view pose and the arrival offset).
    private var elevatorCabCenter: SCNVector3?
    /// Where the player stood at the end of the ride, relative to the doors
    /// (x: along = into the cab, y: across), for the destination cab.
    private(set) var elevatorArrivalOffset: SIMD2<Double>?
    /// TUNE: the exit/re-entry walk through the doorway turns to face its
    /// way out WHILE walking; it is never quicker than this many seconds per
    /// quarter turn of heading it has to make up.
    static let elevatorThresholdTurnSecondsPerQuarter: TimeInterval = 0.45
    /// Starts TRAVELING to a floor (set while WAITING, consumed once).
    private var elevatorDepart: ((Int) -> Void)?

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
            if isBlockedByCharacter(from: currentCell, direction: d) { return false }
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
    /// Oct 9 (Juanita in the doorway): a boundary a CHARACTER is standing in.
    /// Closed to the player exactly like a wall -- grid steps, tap walks and
    /// the free walk (which reads openRunLength) all stop at it -- whatever
    /// state any door there is in. Keyed by the cell and the side it's on;
    /// both sides of the boundary are honoured.
    struct BlockedEdge: Hashable {
        let cell: GridCoordinate
        let direction: Direction
    }
    var characterBlockedEdges: Set<BlockedEdge> = [] {
        didSet {
            guard characterBlockedEdges != oldValue else { return }
            diag("nav.characterBlock", ["edges": characterBlockedEdges.count])
            // A free walk/drag in progress holds its own geometry snapshot.
            if freeWalkGeometry != nil { freeWalkGeometry = makeFreeWalkGeometry() }
        }
    }
    /// The player walked into a character standing in a boundary (a grid
    /// step refused by characterBlockedEdges, or -- Oct 9 -- a free walk
    /// stopped by a character keep-out) -- the character reacts; no wall
    /// thump, a person isn't a wall.
    var onCharacterBlockBump: (() -> Void)?

    /// Oct 9 (conversational distance): circles around characters the free
    /// walk (taps, holds, drags, wall-composition glides) never enters.
    var characterKeepOuts: [FreeWalkGeometry.KeepOut] = [] {
        didSet {
            guard characterKeepOuts != oldValue else { return }
            diag("nav.characterKeepOut", ["count": characterKeepOuts.count,
                                          "radius": characterKeepOuts.first.map { $0.radius }])
            if freeWalkGeometry != nil { freeWalkGeometry = makeFreeWalkGeometry() }
        }
    }

    /// `point` moved straight along `retreat` (a unit floor direction) until
    /// it is clear of every character keep-out (+5 cm) -- where a
    /// wall-composition glide (e.g. facing the guarded doors) ends instead
    /// of inside someone. Unchanged when already clear.
    func pointClearOfCharacters(_ point: SCNVector3, retreat: (x: Double, z: Double)) -> SCNVector3 {
        var p = (x: Double(point.x), z: Double(point.z))
        for k in characterKeepOuts {
            let r = k.radius + 0.05
            let ox = p.x - k.x, oz = p.z - k.z
            guard (ox * ox + oz * oz).squareRoot() < r else { continue }
            // |o + t*u| = r, t > 0.
            let b = ox * retreat.x + oz * retreat.z
            let c = ox * ox + oz * oz - r * r
            let t = -b + (b * b - c).squareRoot()
            p = (p.x + retreat.x * t, p.z + retreat.z * t)
        }
        return SCNVector3(Float(p.x), point.y, Float(p.z))
    }

    /// Does the straight segment from (x, z) by (dx, dz) come within a
    /// character keep-out? (A walk aimed into or past a character.)
    private func segmentMeetsCharacter(x: Double, z: Double, dx: Double, dz: Double) -> Bool {
        for k in characterKeepOuts {
            let len2 = dx * dx + dz * dz
            let t = len2 > 1e-12 ? max(0, min(1, ((k.x - x) * dx + (k.z - z) * dz) / len2)) : 0
            let cx = x + dx * t - k.x, cz = z + dz * t - k.z
            if (cx * cx + cz * cz).squareRoot() < k.radius + 0.02 { return true }
        }
        return false
    }

    func isBlockedByCharacter(from cell: GridCoordinate, direction: Direction) -> Bool {
        guard !characterBlockedEdges.isEmpty else { return false }
        if characterBlockedEdges.contains(BlockedEdge(cell: cell, direction: direction)) { return true }
        let n = GridCoordinate(row: cell.row + direction.delta.row, col: cell.col + direction.delta.col)
        return characterBlockedEdges.contains(BlockedEdge(cell: n, direction: direction.opposite))
    }

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
            if isBlockedByCharacter(from: cell, direction: direction) { break }
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
    /// Oct 7 (F): true from the moment the player starts sitting down at the
    /// office computer until they are standing again where they were
    /// (OfficeComputer drives the camera meanwhile). Blocks walking/turning.
    var isSeatedAtComputer = false
    /// Oct 11 (the staff meeting): true from the moment the player starts
    /// sitting down at the conference table until they are standing again
    /// (ConferenceMeeting drives the camera meanwhile). Blocks walking/turning.
    var isSeatedInMeeting = false

    /// Oct 11 (the staff meeting): ConferenceMeeting's stand-up glide has
    /// brought the camera out beside the table to `position` facing `yaw`.
    /// Same settle as getting up from the office computer.
    func finishStandingFromMeeting(at position: SCNVector3, yaw: Double) {
        cameraNode.position = SCNVector3(position.x, eyeHeight, position.z)
        cameraNode.eulerAngles = SCNVector3(0, Float(yaw), 0)
        let cell = FreeWalkGeometry.containingCell(x: Double(position.x), z: Double(position.z), cellSize: Double(cellSize))
        if cells.contains(cell) {
            applyArrival(cell: cell, heading: nearestCardinal(toYaw: yaw))
        } else {
            diag("meeting.stand.cellMismatch", ["cell": cell, "kept": currentCell])
        }
        isSeatedInMeeting = false
        diag("meeting.stood", ["cell": currentCell, "facing": facing, "yaw": yaw])
    }

    /// Oct 7 (F, getting up): the player has stood up from the office
    /// computer and OfficeComputer's glide has brought the camera round the
    /// desk to `position` facing `yaw`. Settle exactly there at standing eye
    /// height, adopt the cell that contains it (and the nearest cardinal
    /// facing) as if a walk had ended there, and hand movement back.
    func finishStandingFromComputer(at position: SCNVector3, yaw: Double) {
        cameraNode.position = SCNVector3(position.x, eyeHeight, position.z)
        cameraNode.eulerAngles = SCNVector3(0, Float(yaw), 0)
        let cell = FreeWalkGeometry.containingCell(x: Double(position.x), z: Double(position.z), cellSize: Double(cellSize))
        if cells.contains(cell) {
            applyArrival(cell: cell, heading: nearestCardinal(toYaw: yaw))
        } else {
            diag("computer.stand.cellMismatch", ["cell": cell, "kept": currentCell])
        }
        isSeatedAtComputer = false
        diag("computer.stood", ["cell": currentCell, "facing": facing, "yaw": yaw])
    }

    var canRotate: Bool { !isSeatedAtComputer && !isSeatedInMeeting && activePictureMenu == nil && activePhotoBooth == nil && activeTicTacToeTerminal == nil && activeShellGameTerminal == nil && activeRockPaperScissorsTerminal == nil && activeHigherLowerTerminal == nil && activeFiveCardDrawTerminal == nil && activeSimonTerminal == nil && activeHangmanTerminal == nil && activeConnectFourTerminal == nil && activeCheckersTerminal == nil && activeWoidleTerminal == nil && !isAnimating && !isDragRotating && !isDragMoving && !elevatorInUse && !chuteInUse && !extinguisherPickupInProgress && extinguishingFireCoords.isEmpty && !evictionLocked }

    private enum SegmentPhase {
        case pivot      // rotating in place, position unchanged
        case translate  // moving forward, facing already locked in
        case awaitingTurnCommit // render finished; main-thread state update pending
        case scriptedWalkOut // SceneKit action owns translation, not the grid renderer
        case freeMove   // FREE-WALK EXPERIMENT: continuous X/Z along the camera's yaw (see freeWalkEnabled)
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
    /// Oct 10: duration of the pivot currently started by rotate(toward:)
    /// (standaloneRotation only) -- gestures keep pivotDuration; the HUD's
    /// LEFT/RIGHT pass a slower, body-turn duration.
    private var standalonePivotDuration: Double = 0.18

    // MARK: - Free look (Sept 28 experiment: DISCRETE POSITION, CONTINUOUS VISION)
    //
    // When true, a normal horizontal drag leaves the camera wherever the
    // finger releases it (no snap to a cardinal), with no one-gesture
    // quarter-turn limit. Logical `facing` still becomes the NEAREST
    // cardinal to the camera's yaw -- through the existing turn-completion
    // path, so its side effects (booth/terminal auto-open etc.) still run
    // -- and every movement entry point straightens the camera to
    // `facing.yaw` right before moving (alignCameraToFacingBeforeTranslate
    // / beginDragMove). This is the principle elevator arrival already
    // uses (arbitrary yaw + nearest-cardinal facing + straighten before
    // the walk-out), applied to ordinary navigation. Set false to restore
    // the old snap-to-cardinal behavior exactly.
    var freeLookEnabled = true
    private static let freeLookAlignActionKey = "freeLookAlign"

    // MARK: - Magnetic cardinal snap (Oct 3 EXPERIMENT)
    //
    // Free look stays fully freeform WHILE the finger is down. On release,
    // if the camera has turned at least threshold + dead zone (30 + 0 = 30
    // degrees; first device pass at 45 + 5 was too weak) away from the
    // cardinal it started nearest to, the existing standalone .pivot phase
    // finishes the turn to the cardinal it was turning toward: the nearest
    // cardinal to the release yaw, or -- below 45 degrees, where that is
    // still the starting one -- the next cardinal in the turn direction
    // (pivotDuration, smoothstep) -- the same pivot a legacy snapped turn
    // uses. Smaller looks are left exactly where the finger released them.
    // Set false to restore pure free-look release exactly.
    var magneticSnapEnabled = true
    private let magneticSnapThresholdDegrees: Double = 30
    private let magneticSnapDeadZoneDegrees: Double = 0

    // MARK: - Snap intent: dwell gate (Oct 4 EXPERIMENT)
    //
    // Decides WHETHER a free-look release may magnetic-snap at all; the
    // threshold/cardinal logic above still decides WHERE. If the finger
    // settled horizontally for at least noSnapDwellThreshold before lifting,
    // the release keeps the exact heading (no snap). A prompt release while
    // still moving runs the magnetic snap unchanged.
    // Tuning constant for device testing:
    private let noSnapDwellThreshold: TimeInterval = 0.050
    // Fingertip-jitter deadband, in quarter-turn fraction units (the same
    // units updateDragRotate receives). 2.5 pt of horizontal finger travel
    // at the 140 pt-per-90-degree look distance (~1.6 degrees). Movement is
    // measured from an anchor, not frame to frame, so noise that wanders
    // around a held point never counts; only leaving the deadband does.
    private let noSnapJitterFraction: Double = 2.5 / 140
    private var snapDwellAnchorFraction: Double = 0
    private var lastMeaningfulHorizontalMoveTime: TimeInterval = 0

    /// Records horizontal movement for the dwell gate: only a move of more
    /// than noSnapJitterFraction from the last anchor counts as meaningful.
    private func noteHorizontalFraction(_ fraction: Double, at now: TimeInterval) {
        if abs(fraction - snapDwellAnchorFraction) > noSnapJitterFraction {
            snapDwellAnchorFraction = fraction
            lastMeaningfulHorizontalMoveTime = now
        }
    }

    /// The cardinal direction whose yaw is closest to `yaw` (ties resolve
    /// deterministically by Direction.allCases order).
    private func nearestCardinal(toYaw yaw: Double) -> Direction {
        Direction.allCases.min { a, b in
            abs(shortestDelta(from: yaw, to: a.yaw)) < abs(shortestDelta(from: yaw, to: b.yaw))
        } ?? facing
    }

    /// Free look: if the camera isn't looking along `facing`, turn the
    /// already-queued translate into a short pivot to `facing.yaw` first.
    /// The existing non-standalone .pivot case falls straight through to
    /// .translate when it finishes, so this reuses the ordinary walk
    /// machinery -- no second movement implementation. Call only after the
    /// walk's segment/steps are set up and just before it starts.
    private func alignCameraToFacingBeforeTranslate() {
        guard freeLookEnabled else { return }
        let yaw = Double(cameraNode.eulerAngles.y)
        let delta = shortestDelta(from: yaw, to: facing.yaw)
        guard abs(delta) > 0.001 else { return }
        standaloneRotation = false
        pivotStartYaw = yaw
        pivotTargetYaw = yaw + delta
        segmentProgress = 0
        phase = .pivot
    }
    // MARK: - FREE-WALK EXPERIMENT (Sept 29)
    //
    // DISCRETE BUILDING, CONTINUOUS PLAYER. With freeWalkEnabled, an
    // ordinary tap walks one cellSize along the camera's ACTUAL yaw and
    // stops at the exact resulting X/Z; a long press walks continuously
    // along the camera's yaw and stops dead on release. Nothing recenters
    // the player. The authored grid is untouched: physical position ->
    // containing cell -> currentCell (through the ordinary applyArrival),
    // never the other way round. Collision is the BUILDING only (walls,
    // closed doors, missing cells) -- see FreeWalkGeometry. Furniture and
    // props are deliberately ignored. The old grid path is untouched and
    // runs whenever this is false, and for every non-player-controlled
    // walk (ceremonial, mission arrival, elevator, scout/pinch, Decorate
    // holds).
    //
    // Off by default on a bare controller (so every existing navigation
    // test exercises the old path unchanged); ContentView switches it on
    // for the app from `freeWalkExperimentOn`.
    static let freeWalkExperimentOn = true
    var freeWalkEnabled = false

    /// The building's walkable space, snapshotted on the main thread when a
    /// free movement starts (door state included) so the render thread
    /// never reads live door sets.
    private var freeWalkGeometry: FreeWalkGeometry?
    /// Render-side containing cell during a free movement -- the one place
    /// that decides "entered a new cell", so arrival fires exactly once.
    private var freeWalkCell = GridCoordinate(row: 0, col: 0)
    private var freeMoveHeld = false
    /// FREE-WALK vertical-pan / pinch scrub in progress (see beginDragMove).
    private var freeDragMoveActive = false
    private var freeDragBaseYaw: Double = 0
    /// Horizontal unit travel direction of the free scrub: camera forward,
    /// or (pinch, pass #5) the direction under the pinch point.
    private var freeDragDirection: (x: Double, z: Double) = (0, -1)
    private var freeTapDuration: Double = 0.5
    private(set) var freeWalkFootstepsOn = false
    /// How many times free-walk footsteps have (re)started -- one per walk,
    /// plus one per resume after wall contact. Steering never adds one.
    private(set) var freeWalkFootstepStarts = 0

    /// The current building, as FreeWalkGeometry sees it (cells + every
    /// open boundary, from the same openRunLength legality the grid walks use).
    func makeFreeWalkGeometry(blockingActiveFires: Bool = true) -> FreeWalkGeometry {
        let perf = PerfMonitor.begin("geometry.build"); defer { PerfMonitor.end(perf) }   // Oct 21: measurement only
        // Oct 4 FREDDY SLICE: a still-burning fire's cell is closed to free
        // walking exactly like a shut door (the grid walk already refused to
        // enter it; the free walk had no fire rule at all). Out = open again.
        let burning: Set<GridCoordinate> = blockingActiveFires ? fireCoords.subtracting(extinguishedFireCoords) : []
        var open: Set<FreeWalkGeometry.Edge> = []
        for cell in cells {
            for direction in Direction.allCases where openRunLength(from: cell, direction: direction, limit: 1) == 1 {
                if !burning.isEmpty {
                    let next = GridCoordinate(row: cell.row + direction.delta.row, col: cell.col + direction.delta.col)
                    if burning.contains(cell) || burning.contains(next) { continue }
                }
                open.insert(FreeWalkGeometry.Edge(cell: cell, direction: direction))
            }
        }
        var geometry = FreeWalkGeometry(cells: cells, openEdges: open, cellSize: Double(cellSize))
        geometry.keepOuts = characterKeepOuts                          // Oct 9: Juanita's conversational distance
        return geometry
    }

    // MARK: Oct 16 -- BONZO'S EVICTION: the controller's side (BonzoEviction drives)
    //
    // While evictionLocked the player has no say: canRotate is false (every
    // walk, turn, glide and HUD action refuses), the gesture handlers return
    // early (ContentView), and no resume point is saved. The scripted parts use
    // the controller's own elevator: put down on the landing, openElevator(),
    // the building presses LOBBY (guidedAutoFloor), the ordinary arrival.

    /// Set by BonzoEviction only.
    var evictionLocked = false

    /// Why the Big Shot may NOT grab the player right now (nil = he may).
    func evictionRefusal() -> String? {
        if decorateModeEnabled { return "decorate" }
        if isSeatedAtComputer || isSeatedInMeeting { return "seated" }
        if elevatorInUse || elevatorAwaitingEntryDirection != nil || isElevatorWaitingForFloor || arrivedElevatorDoorOpen {
            return "elevator"
        }
        if chuteInUse || extinguisherPickupInProgress || !extinguishingFireCoords.isEmpty { return "busy" }
        if activePictureMenu != nil || activePhotoBooth != nil || activeTicTacToeTerminal != nil || activeShellGameTerminal != nil
            || activeRockPaperScissorsTerminal != nil || activeHigherLowerTerminal != nil || activeFiveCardDrawTerminal != nil
            || activeSimonTerminal != nil || activeHangmanTerminal != nil || activeConnectFourTerminal != nil
            || activeCheckersTerminal != nil || activeWoidleTerminal != nil { return "interaction" }
        if pendingWallInteraction != nil { return "approach" }
        if isAnimating && phase != .freeMove { return "moving" }          // (a step, turn or glide still under way)
        if characterUsingElevator { return "elevatorBusy" }
        if !elevatorReachableFloors.contains(1) || elevatorDoorwayFrame() == nil || elevatorMountDirection == nil { return "noLobbyRide" }
        return nil
    }

    /// The grab: every movement of the player's stops where it is.
    func evictionStopMovement() {
        stopWalkLatch(reason: "eviction")
        stopContinuousWalk(reason: "eviction")
        if isFreeTapWalking { stopFreeTapWalk() }
        setWalkingHeld(false)
        cancelPendingWallInteraction("eviction")
    }

    /// This floor's elevator landing (cell centre, x/z) and the way out of the cab (unit, x/z).
    func evictionLanding() -> (center: SIMD2<Float>, outward: SIMD2<Float>, cell: GridCoordinate)? {
        guard let frame = elevatorDoorwayFrame() else { return nil }
        let p = worldPosition(for: endCell)
        return (SIMD2<Float>(p.x, p.z), frame.outward, endCell)
    }

    /// Floor 1: the walk from the elevator landing to the entrance -- cell
    /// centres along the shortest open way (doors and walls as the player's own
    /// walk has them), and the heading that faces the entrance doors.
    func evictionRouteToEntrance() -> (points: [SIMD2<Float>], entranceHeading: SIMD2<Float>)? {
        let g = makeFreeWalkGeometry()
        var previous: [GridCoordinate: GridCoordinate] = [endCell: endCell]
        var queue = [endCell]
        var i = 0
        while i < queue.count, previous[startCell] == nil {
            let c = queue[i]; i += 1
            for d in Direction.allCases where g.openEdges.contains(FreeWalkGeometry.Edge(cell: c, direction: d)) {
                let n = GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
                if previous[n] == nil { previous[n] = c; queue.append(n) }
            }
        }
        guard previous[startCell] != nil else { return nil }
        var cells = [startCell]
        while let last = cells.last, last != endCell, let p = previous[last] { cells.append(p) }
        cells.reverse()
        let points = cells.map { c -> SIMD2<Float> in let w = worldPosition(for: c); return SIMD2<Float>(w.x, w.z) }
        let out = startFacing.opposite
        return (points, SIMD2<Float>(Float(out.delta.col), Float(out.delta.row)))
    }

    /// The lobby: the player is out of the cab (carried) -- forget the arrival's
    /// in-the-cab state, so the street's reset puts them at the entrance, not
    /// back at the elevator landing.
    func evictionLeftCab() {
        elevatorAwaitingEntryDirection = nil
        elevatorEntryCellCenterPosition = nil
    }

    /// An eviction that couldn't go on: whatever the controller thought, the
    /// player is where the camera is now -- that cell, the nearest compass
    /// facing, out of any cab state, on legal floor (else that cell's centre).
    func evictionResync() {
        evictionLeftCab()
        cameraNode.removeAllActions()
        let g = makeFreeWalkGeometry()
        let p = cameraNode.position
        var cell = g.containingCell(x: Double(p.x), z: Double(p.z), previous: currentCell)
        if !cells.contains(cell) { cell = currentCell }
        if !g.isLegal(x: Double(p.x), z: Double(p.z)) {
            let c = worldPosition(for: cell)
            cameraNode.position = SCNVector3(c.x, eyeHeight, c.z)
        } else {
            cameraNode.position = SCNVector3(p.x, eyeHeight, p.z)
        }
        let yaw = Double(cameraNode.eulerAngles.y)
        cameraNode.eulerAngles = SCNVector3(0, Float(yaw), 0)
        isAnimating = false
        if phase == .freeMove { phase = .translate }
        currentCell = cell
        facing = nearestCardinal(toYaw: yaw)
        diag("bonzo.resync", ["cell": cell, "facing": "\(facing)"])
    }

    /// Put down on the landing, square to the doors -- then the doors open
    /// (openElevator: all its own checks). False = the elevator refused.
    func evictionBoard() -> Bool {
        guard let mount = elevatorMountDirection else { return false }
        cameraNode.removeAllActions()
        let p = worldPosition(for: endCell)
        let yaw = Double(cameraNode.eulerAngles.y)
        cameraNode.position = SCNVector3(p.x, eyeHeight, p.z)
        cameraNode.eulerAngles = SCNVector3(0, Float(yaw + shortestDelta(from: yaw, to: mount.yaw)), 0)
        isAnimating = false
        if phase == .freeMove { phase = .translate }
        currentCell = endCell
        facing = mount
        openElevator()
        return elevatorInUse
    }

    // MARK: Oct 16 -- WALK LATCH (the one minimal tap-to-walk experiment)
    //
    // The ordinary held walk (long-press) is the steering wheel and the
    // accelerator. The latch only lets it keep going with no finger down: a
    // tap on empty scene starts the held walk latched; with no finger it
    // walks straight on at its pace; any touch-and-drag (or long-press) IS the
    // ordinary held walk again -- same steering, same throttle, same speeds --
    // and lifting the finger goes back to walking on; a tap stops it. Nothing
    // about steering, speed, collision or GO changes. Off: `-HallwaysNoWalkLatch YES`
    // (and with `-HallwaysClassicControls YES`).

    static var walkLatchOn: Bool { SmartTap.isOn && !UserDefaults.standard.bool(forKey: "HallwaysNoWalkLatch") }
    /// Written on main, read by the render loop (the walkingHeld convention).
    private(set) var walkLatched = false
    /// A turn still to finish after the finger lifted (render loop).
    private var latchTurnTarget: Double?
    private var latchStall: Double = 0
    /// Oct 16 (Bonzo PP, Part 1): the latched walk's cruising pace, as a share of
    /// the held walk's (about 13 % slower). Render loop only (latchPaceScale).
    /// (Floor 4 PP: 0.87 was still too quick -- another ~17 % off: 0.72.)
    static let walkLatchPace: Double = 0.72
    private var latchPaceScale: Double = 1

    /// A latched walk is running (finger down or not).
    var isWalkLatched: Bool { walkLatched && freeMoveHeld && isAnimating && phase == .freeMove }

    /// Oct 20 (night): a tap this far off the view's own heading (horizontal
    /// bearing to the tapped point) is not "walk on" but "go over there".
    static let latchAheadTolerance: Double = 15 * .pi / 180

    /// The tap lands roughly straight ahead of the view (nil bearing: ahead).
    func tapAimsAhead(_ direction: (x: Double, z: Double)?) -> Bool {
        Self.aimsAhead(direction, yaw: Double(cameraNode.eulerAngles.y))
    }

    /// Pure (tests): `direction` (x, z, unit) within latchAheadTolerance of `yaw`'s forward.
    static func aimsAhead(_ direction: (x: Double, z: Double)?, yaw: Double) -> Bool {
        guard let d = direction else { return true }
        let bearing = atan2(-d.x, -d.z)                                   // (yaw h faces (-sin h, -cos h))
        let off = atan2(sin(bearing - yaw), cos(bearing - yaw))
        return abs(off) <= latchAheadTolerance
    }

    /// Tap on empty scene, standing still: the held walk, latched. False =
    /// it can't start right now (the tap is the ordinary tap it always was).
    func startWalkLatch() -> Bool {
        guard Self.walkLatchOn, !walkLatched, !walkingHeld, continuousWalkState == .stopped, canRotate,
              freeWalkApplies(held: true) else { return false }
        walkLatched = true
        latchTurnTarget = nil
        latchStall = 0
        heldDistance = 0
        beginFreeHeldWalk()
        guard freeMoveHeld, isAnimating, phase == .freeMove else {
            walkLatched = false
            return false
        }
        diag("walkLatch.start", ["cell": currentCell, "yaw": Double(cameraNode.eulerAngles.y)])
        scheduleWalkLatchWatch()
        return true
    }

    /// While latched with no finger down: anything that takes movement away
    /// (an interaction opening, the elevator, a seat, a script, Decorate) ends it.
    private func scheduleWalkLatchWatch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isWalkLatched else { return }
            if !self.walkingHeld, let reason = self.continuousWalkBlockReason {
                self.stopWalkLatch(reason: reason)
                return
            }
            self.scheduleWalkLatchWatch()
        }
    }

    /// Tap while latched: stop. With no finger down the walk ends where it is
    /// on the next frame (exactly as letting go of a long-press always did).
    func stopWalkLatch(reason: String) {
        guard walkLatched else { return }
        walkLatched = false
        latchTurnTarget = nil
        diag("walkLatch.stop", ["reason": reason, "cell": currentCell])
    }

    /// A fast horizontal swipe on a latched walk: the standing swipe's own
    /// quarter-turn snap -- the next compass direction that way -- finished
    /// by the walk at the held walk's turn rate.
    func latchFlickTurn(left: Bool) {
        guard isWalkLatched, !walkingHeld else { return }
        // The next compass direction that way from where the view is now (at least 10 degrees on).
        let current = Double(cameraNode.eulerAngles.y)
        let deltas = Direction.allCases.map { shortestDelta(from: current, to: $0.yaw) }
        let ahead = deltas.filter { left ? $0 > 0.17 : $0 < -0.17 }
        guard let delta = left ? ahead.min() : ahead.max() else { return }
        latchTurnTarget = current + delta
        diag("walkLatch.flick", ["left": left, "degrees": Int((delta * 180 / .pi).rounded())])
    }

    /// Whether a player-controlled walk takes the free path right now.
    /// Excluded: the elevator entry/exit states (their scripted walks
    /// assume the cell center) and, for holds, Decorate's one-step cap.
    private func freeWalkApplies(held: Bool) -> Bool {
        freeWalkEnabled && elevatorAwaitingEntryDirection == nil && !canReenterArrivedElevator
            && !(held && decorateModeEnabled)
    }

    /// Where a free tap would end: one cellSize along the camera's yaw,
    /// cut short by the building.
    func freeWalkTapTarget() -> SCNVector3 {
        let geometry = makeFreeWalkGeometry()
        let start = cameraNode.position
        let forward = FreeWalkGeometry.forward(yaw: Double(cameraNode.eulerAngles.y))
        return geometry.slideEndpoint(from: SCNVector3(start.x, eyeHeight, start.z),
                                      dx: forward.x * Double(cellSize), dz: forward.z * Double(cellSize))
    }

    /// The resolved (wall-slid) path of a free tap, and its cumulative
    /// arc length -- the tap glides along THIS, never along a chord.
    private var freeTapPath: [SCNVector3] = []
    private var freeTapArc: [Double] = []
    private var freeTapSegment = 0

    private func freeTapPosition(atDistance d: Double) -> SCNVector3 {
        guard freeTapPath.count > 1 else { return freeTapPath.first ?? cameraNode.position }
        while freeTapSegment < freeTapArc.count - 2, freeTapArc[freeTapSegment + 1] < d { freeTapSegment += 1 }
        let a = freeTapPath[freeTapSegment], b = freeTapPath[freeTapSegment + 1]
        let l0 = freeTapArc[freeTapSegment], l1 = freeTapArc[freeTapSegment + 1]
        let f = Float(l1 > l0 ? min(1, max(0, (d - l0) / (l1 - l0))) : 1)
        return SCNVector3(a.x + (b.x - a.x) * f, eyeHeight, a.z + (b.z - a.z) * f)
    }

    /// TAP WHERE YOU WANT TO GO (Sept 30): the view turns toward the tapped
    /// bearing over the same eased curve as the one-cell glide. Arbitrary
    /// yaw -- exactly the bearing tapped, never a cardinal.
    private var freeTapStartYaw: Double = 0
    private var freeTapEndYaw: Double = 0

    /// The yaw whose camera forward is `direction`, expressed as the
    /// nearest equivalent of `current` (so the turn is the short way).
    static func yaw(facing direction: (x: Double, z: Double), near current: Double) -> Double {
        let raw = atan2(-direction.x, -direction.z)   // inverse of FreeWalkGeometry.forward
        var delta = (raw - current).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi } else if delta <= -.pi { delta += 2 * .pi }
        return current + delta
    }

    // MARK: TAP A PLACE -> GO THERE / TAP AGAIN -> STOP (Sept 30)
    //
    // A destination tap requests its real horizontal distance (not one
    // cell) through the same slidePath. Up to one cell it glides exactly
    // like the old tap; longer walks run at plain travelSpeed with a short
    // ease in/out (freeTapRamp) instead of one long smoothstep, and the
    // view turn keeps the one-cell timescale however long the walk is.
    // While such a walk runs, any tap requests a stop, applied by the
    // render loop on its next frame, right where the player is.

    /// Ease in/out time at each end of a longer-than-one-cell tap walk.
    static let freeTapRamp: Double = 0.3
    private var freeTapRampTime: Double = 0          // 0 = the old one-cell smoothstep
    private var freeTapTurnDuration: Double = 0
    private var freeTapStopRequested = false
    private(set) var freeTapWalkActive = false {
        didSet { if !freeTapWalkActive { tapWalkDestination = nil } }
    }
    /// Oct 3 TIN CAN RAT (read-only observation, nothing here reads it):
    /// where the accepted tap-to-walk is headed, while that walk is active.
    nonisolated(unsafe) private(set) var tapWalkDestination: SCNVector3?

    /// True while a navigation-tap walk is under way (the next tap stops it).
    /// Oct 2 (auto-walk -> hold handoff): a finger that goes down and stays
    /// down -- still OR dragging -- during a running tap-to-point walk takes
    /// it over as the ordinary held walk (see takeOverFreeTapWalkForHold).
    var tapWalkCanBeTakenOverByHold: Bool { isFreeTapWalking && freeWalkApplies(held: true) }
    var isFreeTapWalking: Bool { freeTapWalkActive && isAnimating && !freeMoveHeld && (phase == .freeMove || phase == .awaitingTurnCommit) }

    /// Tap-to-stop: the walk ends where it is on the next frame -- current
    /// position and yaw kept, no snap, no THUD.
    func stopFreeTapWalk() {
        guard isFreeTapWalking else { return }
        cancelPendingWallInteraction("tap to stop")
        freeTapStopRequested = true
        navLog("free walk tap: stop requested")
    }

    /// A tap walk's timing (pure; Oct 20 -- moved here unchanged from
    /// beginFreeWalkTap, its speed now passed in): how long it takes, its ramp
    /// (0: the old one-cell smoothstep), and how long its turn takes.
    static func tapWalkTiming(distance: Double, cellSize: Double, speed: Double, approach: Bool,
                              turnAcrossWholeGlide: Bool) -> (duration: Double, ramp: Double, turn: Double) {
        let oneCell = cellSize / speed
        if distance > cellSize + 1e-6 {
            let duration = distance / speed + freeTapRamp
            // Oct 2: a wall-composition glide (only) turns across the whole
            // approach, so it never arrives side-on and crabs into place.
            return (duration, freeTapRamp, turnAcrossWholeGlide ? duration : oneCell)
        }
        // exactly the old tap glide
        var duration = distance / speed
        if approach { duration = max(duration, oneCell) }   // approach: always a full, unhurried turn
        return (duration, 0, duration)
    }

    /// Distance along a tap walk after `elapsed` seconds: constant speed
    /// `v`, eased over `ramp` seconds at each end, total length `length`.
    static func tapWalkDistance(elapsed e: Double, length: Double, speed v: Double, ramp a: Double) -> Double {
        let total = length / v + a
        if e <= 0 { return 0 }
        if e >= total { return length }
        if e < a { return v * e * e / (2 * a) }
        if e > total - a { return length - v * (total - e) * (total - e) / (2 * a) }
        return v * (e - a / 2)
    }

    // MARK: Oct 1 (tap-to-approach floor interactables)
    //
    // A tapped floor object that is collected by a deliberate tap from the
    // adjacent cell (ObjectKind.requiresTapToCollect: trash can, paint
    // bucket -- NOT hanging pickups, which you walk through) must not be
    // walked INTO. The tap keeps the ordinary point-to-walk line -- straight
    // from the player toward the object's actual world position -- and is
    // simply shortened by one cell, finishing facing along that same line.

    /// The approach walk for a tap on the object at `coord`, or nil when
    /// this tap should stay an ordinary destination walk.
    func tapApproach(toObjectAt coord: GridCoordinate) -> (direction: (x: Double, z: Double)?, distance: Double, finalYaw: Double)? {
        guard let kind = objectKinds[coord], kind.requiresTapToCollect, !collectedCoords.contains(coord) else { return nil }
        let target = objectNodes[coord].map { (x: Double($0.worldPosition.x), z: Double($0.worldPosition.z)) }
            ?? (x: Double(coord.col) * Double(cellSize), z: Double(coord.row) * Double(cellSize))
        let player = (x: Double(cameraNode.position.x), z: Double(cameraNode.position.z))
        return Self.approachAlongLine(from: player, to: target, standOff: Double(cellSize), currentYaw: Double(cameraNode.eulerAngles.y))
    }

    /// Fire uses the same interruptible straight-line walk as floor pickups.
    func tapApproach(toFireAt coord: GridCoordinate) -> (direction: (x: Double, z: Double)?, distance: Double, finalYaw: Double)? {
        guard fireCoords.contains(coord), !extinguishedFireCoords.contains(coord),
              let fire = fireNodes[coord], fire.parent != nil else { return nil }
        let player = cameraNode.worldPosition, target = fire.worldPosition
        return Self.approachAlongLine(from: (Double(player.x), Double(player.z)),
            to: (Double(target.x), Double(target.z)), standOff: Double(cellSize), currentYaw: Double(cameraNode.eulerAngles.y))
    }

    /// Same direction as walking straight at `target`, distance shortened by
    /// `standOff` (never negative), finishing facing the target. Already
    /// within the stand-off: no travel, just face it.
    static func approachAlongLine(from player: (x: Double, z: Double), to target: (x: Double, z: Double), standOff: Double, currentYaw: Double)
        -> (direction: (x: Double, z: Double)?, distance: Double, finalYaw: Double) {
        let dx = target.x - player.x, dz = target.z - player.z
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 1e-6 else { return (nil, 0, currentYaw) }
        let direction = (x: dx / length, z: dz / length)
        return (direction, max(0, length - standOff), atan2(-direction.x, -direction.z))
    }

    // MARK: Oct 2 -- WALL INTERACTIONS (one shared mechanism)
    //
    // Free Walk is free; a deliberate tap on a wall object asks Hallways to
    // put you where that object is used. Every tappable Play-mode wall
    // object resolves, from a hit-tested node, to ONE WallInteractionTarget:
    //
    //   kind    -- diagnostics label
    //   face    -- the cell to stand at the center of + the wall to face
    //   action  -- the object's EXISTING tap action, run only on arrival
    //              (nil for passive objects: viewing IS the interaction)
    //
    // The shared machinery (forgiving targeting in ContentView, then
    // composeWallInteraction -> beginWallComposition -> the ordinary Free
    // Walk tap glide, then the pending action) is the same for all of them.
    // A NEW wall object only needs a case in wallInteractionTarget(for:)
    // (and, if its anchor node isn't recognizable there, isWallInteractionAnchor).

    struct WallInteractionTarget {
        let kind: String
        let face: WallFace
        let action: (() -> Void)?
        /// Identity for de-duplication / ambiguity (several nodes of one
        /// object resolve to the same target).
        var key: String { "\(kind)@\(face.coord.row),\(face.coord.col)" }
        var objectWorld: SCNVector3?
    }

    enum WallInteraction: String {
        case photoBooth, ticTacToe, shellGame, rockPaperScissors, higherLower, fiveCardDraw,
             simon, hangman, connectFour, checkers, woidle
    }

    /// The wall a fixture of `kind` at `coord` is mounted on -- nil when it
    /// isn't there or its interaction is no longer available (won/completed).
    private func wallInteractionDirection(_ kind: WallInteraction, at coord: GridCoordinate) -> Direction? {
        switch kind {
        case .photoBooth:
            return photoBoothExpressions[coord] != nil && !completedPhotoBooths.contains(coord) ? photoBoothDirections[coord] : nil
        case .ticTacToe: return ticTacToeWon ? nil : ticTacToeDirections[coord]
        case .shellGame: return shellGameWon ? nil : shellGameDirections[coord]
        case .rockPaperScissors: return rockPaperScissorsWon ? nil : rockPaperScissorsDirections[coord]
        case .higherLower: return higherLowerWon ? nil : higherLowerDirections[coord]
        case .fiveCardDraw: return fiveCardDrawWon ? nil : fiveCardDrawDirections[coord]
        case .simon: return simonWon ? nil : simonDirections[coord]
        case .hangman: return hangmanWon ? nil : hangmanDirections[coord]
        case .connectFour: return connectFourWon ? nil : connectFourDirections[coord]
        case .checkers: return checkersWon ? nil : checkersDirections[coord]
        case .woidle: return woidleWon ? nil : woidleDirections[coord]
        }
    }

    /// Hit-test node -> fixture coordinate + that fixture's EXISTING activate.
    private var fixtureResolvers: [(kind: WallInteraction, coordinate: (SCNNode) -> GridCoordinate?, activate: (GridCoordinate) -> Void)] {
        [
            (.photoBooth, { [unowned self] in self.photoBoothCoordinate(for: $0) }, { [weak self] in self?.activatePhotoBooth(at: $0) }),
            (.ticTacToe, { [unowned self] in self.ticTacToeTerminalCoordinate(for: $0) }, { [weak self] in self?.activateTicTacToeTerminal(at: $0) }),
            (.shellGame, { [unowned self] in self.shellGameTerminalCoordinate(for: $0) }, { [weak self] in self?.activateShellGameTerminal(at: $0) }),
            (.rockPaperScissors, { [unowned self] in self.rockPaperScissorsTerminalCoordinate(for: $0) }, { [weak self] in self?.activateRockPaperScissorsTerminal(at: $0) }),
            (.higherLower, { [unowned self] in self.higherLowerTerminalCoordinate(for: $0) }, { [weak self] in self?.activateHigherLowerTerminal(at: $0) }),
            (.fiveCardDraw, { [unowned self] in self.fiveCardDrawTerminalCoordinate(for: $0) }, { [weak self] in self?.activateFiveCardDrawTerminal(at: $0) }),
            (.simon, { [unowned self] in self.simonTerminalCoordinate(for: $0) }, { [weak self] in self?.activateSimonTerminal(at: $0) }),
            (.hangman, { [unowned self] in self.hangmanTerminalCoordinate(for: $0) }, { [weak self] in self?.activateHangmanTerminal(at: $0) }),
            (.connectFour, { [unowned self] in self.connectFourTerminalCoordinate(for: $0) }, { [weak self] in self?.activateConnectFourTerminal(at: $0) }),
            (.checkers, { [unowned self] in self.checkersTerminalCoordinate(for: $0) }, { [weak self] in self?.activateCheckersTerminal(at: $0) }),
            (.woidle, { [unowned self] in self.woidleTerminalCoordinate(for: $0) }, { [weak self] in self?.activateWoidleTerminal(at: $0) }),
        ]
    }

    /// The nearest-cardinal wall a node sits on, relative to a cell center
    /// -- read from the RENDERED node's world position (used where the
    /// controller has no stored direction, e.g. the trash chute).
    private func mountDirection(of node: SCNNode, in coord: GridCoordinate) -> Direction {
        let p = node.worldPosition, c = worldPosition(for: coord)
        let dx = Double(p.x - c.x), dz = Double(p.z - c.z)
        if abs(dx) > abs(dz) { return dx > 0 ? .east : .west }
        return dz > 0 ? .south : .north
    }

    /// A door between `coord` and its neighbour that way: stand on whichever
    /// side the player is nearer (both are legal operating spots for the
    /// existing door code), facing the door.
    private func twoSidedDoorFace(at coord: GridCoordinate, direction: Direction) -> WallFace {
        let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
        guard cells.contains(neighbor) else { return WallFace(coord: coord, direction: direction) }
        let p = cameraNode.position
        func d2(_ c: GridCoordinate) -> Float {
            let w = worldPosition(for: c); return (w.x - p.x) * (w.x - p.x) + (w.z - p.z) * (w.z - p.z)
        }
        return d2(neighbor) < d2(coord) ? WallFace(coord: neighbor, direction: direction.opposite)
                                         : WallFace(coord: coord, direction: direction)
    }

    /// THE taxonomy: any hit-tested node -> the wall interaction it belongs
    /// to, or nil (not a wall object, or one with nothing available now --
    /// open door, won game, busy chute -- which keeps its old tap behavior).
    func wallInteractionTarget(for node: SCNNode) -> WallInteractionTarget? {
        // Oct 8: the Floor 1 lobby mirror -- a hardcoded fixture, untagged and
        // absent from `mirrors`, so it matched nothing here and its tap became
        // an ordinary walk that ended facing the tap's diagonal bearing.
        // Passive (no action), like a picture: the standard square landing.
        if floorNumber == 1, let mirror = Self.lobbyMirrorRoot(of: node) {
            return WallInteractionTarget(kind: "lobbyMirror", face: HallwayScene.lobbyMirrorFace,
                                         action: nil, objectWorld: mirror.worldPosition)
        }
        // Passive: pictures, mission plaques, wall floor maps.
        if let passive = Self.passiveWallObject(for: node) {
            let direction: Direction?
            switch passive.kind {
            case .picture:
                direction = passive.direction.flatMap { pictureFaces.contains(WallFace(coord: passive.coord, direction: $0)) ? $0 : nil }
            case .missionSign: direction = missionSignDirections[passive.coord]
            case .floorMap: direction = floorMapDirections[passive.coord]
            }
            guard let direction else { return nil }
            return WallInteractionTarget(kind: passive.kind.rawValue, face: WallFace(coord: passive.coord, direction: direction),
                                         action: nil, objectWorld: passive.objectWorld)
        }
        // Wall fixtures: photo booth + game terminals.
        for resolver in fixtureResolvers {
            if let coord = resolver.coordinate(node) {
                guard let direction = wallInteractionDirection(resolver.kind, at: coord) else { return nil }
                let activate = resolver.activate
                return WallInteractionTarget(kind: resolver.kind.rawValue, face: WallFace(coord: coord, direction: direction),
                                             action: { activate(coord) })
            }
        }
        // Trash chute (destination cubby door).
        var walk: SCNNode? = node
        while let candidate = walk {
            if let coord = destinationNodes.first(where: { $0.value === candidate })?.key {
                guard destinationKinds[coord] != nil, !chuteInUse else { return nil }
                return WallInteractionTarget(kind: "trashChute", face: WallFace(coord: coord, direction: mountDirection(of: candidate, in: coord)),
                                             action: { [weak self] in self?.openDestinationDoor(at: coord) })
            }
            walk = candidate.parent
        }
        // Swing doors (either side).
        if let coord = bathroomDoorCoordinate(for: node) {
            guard let direction = bathroomDoors[coord], !openBathroomDoors.contains(coord) else { return nil }
            return WallInteractionTarget(kind: "bathroomDoor", face: twoSidedDoorFace(at: coord, direction: direction),
                                         action: { [weak self] in self?.openBathroomDoor(at: coord) })
        }
        if let coord = windowRoomDoorCoordinate(for: node) {
            guard let direction = windowRooms[coord]?.direction, !openWindowRoomDoors.contains(coord) else { return nil }
            return WallInteractionTarget(kind: "windowRoomDoor", face: twoSidedDoorFace(at: coord, direction: direction),
                                         action: { [weak self] in self?.openWindowRoomDoor(at: coord) })
        }
        if let coord = roomEntranceDoorCoordinate(for: node) ?? Self.taggedCoord(of: node, kind: .roomEntranceDoor) {
            // Oct 9 (Juanita on guard): a tap on the doors she guards is an
            // attempt to leave -- no glide, no door; she answers it.
            if let direction = roomEntranceDoors[coord], roomEntranceDoorGuarded?(coord) == true {
                return WallInteractionTarget(kind: Self.guardedDoorKind, face: twoSidedDoorFace(at: coord, direction: direction),
                                             action: { [weak self] in self?.guardedRoomEntranceDoorTapped(coord) })
            }
            guard let direction = roomEntranceDoors[coord], !openRoomEntranceDoors.contains(coord) else { return nil }
            return WallInteractionTarget(kind: "roomEntranceDoor", face: twoSidedDoorFace(at: coord, direction: direction),
                                         action: { [weak self] in self?.openRoomEntranceDoor(at: coord) })
        }
        // Numbered room door (mail slot / knock): operated from its own cell.
        if let coord = roomDoorCoordinate(for: node) ?? Self.taggedCoord(of: node, kind: .roomDoor) {
            guard let door = roomDoors[coord] else { return nil }
            return WallInteractionTarget(kind: "roomDoor", face: WallFace(coord: coord, direction: door.direction),
                                         action: { [weak self] in self?.interactWithRoomDoor(at: coord) })
        }
        // Wall-mounted fire extinguisher.
        if let coord = extinguisherCoordinate(for: node) {
            guard let direction = extinguisherCoords[coord], !carryingExtinguisher, !extinguisherPickupInProgress,
                  !pickedUpExtinguisherCoords.contains(coord), extinguisherNodes[coord]?.parent != nil else { return nil }
            return WallInteractionTarget(kind: "extinguisher", face: WallFace(coord: coord, direction: direction),
                                         action: { [weak self] in _ = self?.pickUpExtinguisher(at: coord) })
        }
        return nil
    }

    private static func lobbyMirrorRoot(of node: SCNNode) -> SCNNode? {
        var current: SCNNode? = node
        while let candidate = current {
            if candidate.name == HallwayScene.lobbyMirrorNodeName { return candidate }
            current = candidate.parent
        }
        return nil
    }

    private static func taggedCoord(of node: SCNNode, kind: DecoratorTarget.Kind) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let target = DecoratorTarget.read(candidate) { return target.kind == kind ? target.coord : nil }
            current = candidate.parent
        }
        return nil
    }

    /// Cheap per-node test used to collect forgiving-targeting candidates:
    /// the top node of each wall object (its tag / name / chute door).
    func isWallInteractionAnchor(_ node: SCNNode) -> Bool {
        if let target = DecoratorTarget.read(node), target.coord != nil {
            switch target.kind {
            case .picture, .missionSign, .floorMap, .photoBooth, .game, .roomDoor, .roomEntranceDoor, .extinguisher: return true
            default: break
            }
        }
        if let name = node.name, name.hasPrefix("bathroomDoor_") || name.hasPrefix("windowRoomDoor_") { return true }
        if floorNumber == 1, node.name == HallwayScene.lobbyMirrorNodeName { return true }   // Oct 8
        return destinationNodes.values.contains { $0 === node }
    }

    /// The interaction waiting for its alignment glide to finish.
    private var pendingWallInteraction: (kind: String, targetYaw: Double, run: (() -> Void)?)?

    private func cancelPendingWallInteraction(_ reason: String) {
        guard let pending = pendingWallInteraction else { return }
        pendingWallInteraction = nil
        diag("wallInteraction.align.cancel", ["kind": pending.kind, "reason": reason,
                                              "pendingActionCancelled": pending.run != nil])
    }

    /// Compose the target's pose, then run its action (if any) on arrival.
    /// Returns false -- caller keeps its old tap behavior -- in Decorate,
    /// grid navigation, while input is locked, or if the glide can't start.
    /// No distance limit: a recognized tap is intent.
    func composeWallInteraction(_ target: WallInteractionTarget) -> Bool {
        // Oct 9: guarded doors -- consumed right here, BEFORE any glide or
        // door animation: the player stays where they are, she reacts.
        if target.kind == Self.guardedDoorKind, !decorateModeEnabled {
            diag("wallInteraction.guardedDoor", ["coord": target.face.coord])
            target.action?()
            return true
        }
        guard !decorateModeEnabled, freeWalkApplies(held: false), canRotate else {
            diag("wallInteraction.declined", ["kind": target.kind, "coord": target.face.coord,
                                              "reason": "not applicable (decorate/grid/locked)"])
            return false
        }
        var check: (yaw: Double, error: Double)?
        if let objectWorld = target.objectWorld {
            let pose = worldPosition(for: target.face.coord)
            let ox = Double(objectWorld.x - pose.x), oz = Double(objectWorld.z - pose.z)
            if (ox * ox + oz * oz) > 1e-6 {
                let lookAt = atan2(-ox, -oz)
                check = (lookAt, shortestDelta(from: target.face.direction.yaw, to: lookAt))
            }
        }
        return beginWallComposition(kind: target.kind, face: target.face, then: target.action,
                                    extra: ["coord": target.face.coord, "direction": target.face.direction,
                                            "hasAction": target.action != nil,
                                            "geometricYaw": check?.yaw, "geometricYawError": check?.error])
    }

    /// Kept for the "standing in the fixture's cell" taps in handleTap
    /// (games/booth opened by any tap there, unchanged): same shared path.
    func composeWallView(_ kind: WallInteraction, at coord: GridCoordinate, then interact: @escaping () -> Void) {
        guard let direction = wallInteractionDirection(kind, at: coord),
              composeWallInteraction(WallInteractionTarget(kind: kind.rawValue, face: WallFace(coord: coord, direction: direction),
                                                           action: interact))
        else {
            interact()
            return
        }
    }

    enum PassiveWallObject: String { case picture, missionSign, floorMap }

    /// The passive wall object a hit-tested node belongs to (walks up to the
    /// frame's DecoratorTarget tag). Grid objects only.
    static func passiveWallObject(for node: SCNNode) -> (kind: PassiveWallObject, coord: GridCoordinate, direction: Direction?, objectWorld: SCNVector3)? {
        var current: SCNNode? = node
        while let candidate = current {
            if let target = DecoratorTarget.read(candidate), let coord = target.coord {
                switch target.kind {
                case .picture: return (.picture, coord, target.direction, candidate.worldPosition)
                case .missionSign: return (.missionSign, coord, target.direction, candidate.worldPosition)
                case .floorMap: return (.floorMap, coord, target.direction, candidate.worldPosition)
                default: return nil
                }
            }
            current = candidate.parent
        }
        return nil
    }

    /// Oct 5 (Administration): landing spots on this floor (set by
    /// ContentView; empty elsewhere) -- the reception desk and the ID-photo
    /// terminal. A free walk that comes to rest in a spot's cell while
    /// heading toward what it faces (within 75 degrees, no finger down) is
    /// finished by the ordinary wall-interaction landing
    /// (beginWallComposition): a smooth glide that turns across the glide
    /// to face it. `standOff` moves the pose along the facing direction
    /// from the cell centre (negative = farther back). `onLanded` runs once
    /// the glide has COMPLETED, uninterrupted; it never moves the player.
    struct LandingSpot {
        let kind: String
        let face: WallFace
        let standOff: Double
        let onLanded: () -> Void
        /// Oct 5 (Fred's office): nil = always; otherwise the spot only
        /// draws/lands the player while this returns true.
        var isAvailable: (() -> Bool)? = nil
        /// Oct 6 (polish): an ordinary tap walk heading into this spot's
        /// cell, toward what it faces, ENDS at the spot's distance instead of
        /// walking in closer and then being glided back out to it.
        var capsApproach = false
    }
    var landingSpots: [LandingSpot] = []

    private func landingPosition(_ spot: LandingSpot) -> SCNVector3 {
        let c = worldPosition(for: spot.face.coord)
        return SCNVector3(c.x + Float(Double(spot.face.direction.delta.col) * spot.standOff), c.y,
                          c.z + Float(Double(spot.face.direction.delta.row) * spot.standOff))
    }

    /// True while the player stands in `kind`'s landed pose (near its
    /// position, facing it) and isn't moving.
    func isInLandingPose(_ kind: String) -> Bool {
        guard let spot = landingSpots.first(where: { $0.kind == kind }), currentCell == spot.face.coord, !isAnimating else { return false }
        let here = cameraNode.position, target = landingPosition(spot)
        let off = hypot(Double(target.x - here.x), Double(target.z - here.z))
        let yaw = Double(cameraNode.eulerAngles.y)
        return off < 0.35 && abs(shortestDelta(from: yaw, to: spot.face.direction.yaw)) < 25 * .pi / 180
    }

    /// Oct 6 (polish): if this straight walk would cross a capped landing
    /// spot's pose plane (the line through its landing position, square to
    /// what it faces) inside that spot's cell while heading toward it, the
    /// distance to that plane -- so the walk simply stops where the
    /// conversation happens. nil = no cap.
    private func approachCap(from start: SCNVector3, forward: (x: Double, z: Double), requested: Double) -> Double? {
        for spot in landingSpots where spot.capsApproach && (spot.isAvailable?() ?? true) {
            let d = (x: Double(spot.face.direction.delta.col), z: Double(spot.face.direction.delta.row))
            let along = forward.x * d.x + forward.z * d.z
            guard along > cos(75 * Double.pi / 180) else { continue }       // heading toward what it faces
            let pose = landingPosition(spot)
            let t = ((Double(pose.x) - Double(start.x)) * d.x + (Double(pose.z) - Double(start.z)) * d.z) / along
            guard t > 0.05, t < requested else { continue }
            let px = Double(start.x) + forward.x * t, pz = Double(start.z) + forward.z * t
            let cell = GridCoordinate(row: Int((pz / Double(cellSize)).rounded()), col: Int((px / Double(cellSize)).rounded()))
            guard cell == spot.face.coord else { continue }
            return t
        }
        return nil
    }

    /// Called once a free walk has stopped on its own (no pending wall
    /// interaction): lands at a spot whose cell it ended in, if heading
    /// roughly toward it -- turning away and stepping off never pulls you back.
    private func landAtSpotIfApproaching() {
        guard !walkingHeld, canRotate else { return }
        let yaw = Double(cameraNode.eulerAngles.y)
        guard let spot = landingSpots.first(where: { ($0.isAvailable?() ?? true) && currentCell == $0.face.coord
            && abs(shortestDelta(from: yaw, to: $0.face.direction.yaw)) < 75 * .pi / 180 }) else { return }
        beginLanding(kind: spot.kind)
    }

    /// The landing itself (also used directly, e.g. a tap on the ID terminal
    /// from across the room). Returns true if the glide started or the
    /// player was already in the pose.
    @discardableResult
    func beginLanding(kind: String) -> Bool {
        guard let spot = landingSpots.first(where: { $0.kind == kind && ($0.isAvailable?() ?? true) }), canRotate else { return false }
        let yaw = Double(cameraNode.eulerAngles.y)
        let here = cameraNode.position
        let target = landingPosition(spot)
        let off = hypot(Double(target.x - here.x), Double(target.z - here.z))
        guard off > 0.03 || abs(shortestDelta(from: yaw, to: spot.face.direction.yaw)) > 0.02 else {
            spot.onLanded()                               // already exactly in the pose
            return true
        }
        diag("administration.landing", ["kind": kind, "from": String(format: "(%.2f, %.2f)", here.x, here.z),
                                        "yaw": yaw, "off": off])
        let onLanded = spot.onLanded
        return beginWallComposition(kind: kind, face: spot.face, at: target, then: { onLanded() })
    }

    /// The one shared pose: `face.coord`'s cell center looking along
    /// `face.direction` (every wall object is mounted centered on its cell's
    /// wall, half a cell out; Direction.yaw looks that way -- the same
    /// convention every activate guard checks). Returns true when handled
    /// (glide started, or already in pose and the action ran).
    @discardableResult
    private func beginWallComposition(kind: String, face: WallFace, at position: SCNVector3? = nil, then interact: (() -> Void)?,
                                      extra: [String: Any?] = [:]) -> Bool {
        // Oct 9: never compose INTO a character (e.g. facing the doors she
        // guards): stop short, backed off from the face, outside her circle.
        let back = face.direction.opposite.delta
        let target = pointClearOfCharacters(position ?? worldPosition(for: face.coord),
                                            retreat: (Double(back.col), Double(back.row)))
        let targetYaw = face.direction.yaw
        let start = cameraNode.position
        let startYaw = Double(cameraNode.eulerAngles.y)
        let dx = Double(target.x - start.x), dz = Double(target.z - start.z)
        let distance = (dx * dx + dz * dz).squareRoot()
        let yawError = abs(shortestDelta(from: startYaw, to: targetYaw))
        if distance < 0.03 && yawError < 0.02 {           // already there: no glide
            if let interact { diag("wallInteraction.action.invoked", ["kind": kind, "note": "already in pose"]); interact() }
            return true
        }
        let extraText = extra.sorted { $0.key < $1.key }.map { "\($0.key)=\(DiagnosticRecorder.render($0.value))" }.joined(separator: " ")
        diag("wallInteraction.align.start", ["kind": kind,
             "from": String(format: "(%.3f, %.3f)", start.x, start.z),
             "to": String(format: "(%.3f, %.3f)", target.x, target.z),
             "startYaw": startYaw, "targetYaw": targetYaw, "detail": (extraText.isEmpty ? nil : extraText) as String?])
        beginFreeWalkTap(travelDirection: distance > 1e-6 ? (dx / distance, dz / distance) : nil,
                         travelDistance: distance, finalYaw: targetYaw, turnAcrossWholeGlide: true)
        guard freeTapWalkActive else {
            diag("wallInteraction.align.cancel", ["kind": kind, "reason": "glide could not start"])
            return false
        }
        pendingWallInteraction = (kind, targetYaw, interact)
        return true
    }

    /// Oct 8 flight recorder: ONE line of the player's state and everything
    /// around it -- periodic, at each floor install and just before a report
    /// is shared (see DiagnosticRecorder.snapshotProvider). Reads only.
    func diagStateSnapshot(_ reason: String) {
        let perf = PerfMonitor.begin("diag.snapshot"); defer { PerfMonitor.end(perf) }    // Oct 21: measurement only
        let p = cameraNode.position
        // Oct 9 (heating investigation): render rate, thermal state and the
        // floor's light census -- measurement only.
        RenderHealth.shared.startWatching()
        // Oct 21: timed on its own; skipped (nodes=-1) with -HallwaysPerfNoCensus YES.
        let census: (nodes: Int, lights: Int, byKind: String)
        if PerfSwitches.noCensus {
            census = (-1, -1, "skipped(PerfNoCensus)")
        } else {
            let c = PerfMonitor.begin("diag.census")
            census = RenderHealth.census(scene?.rootNode)
            PerfMonitor.end(c)
        }
        diag("snapshot.render", [
            "reason": reason,
            "floor": floorNumber,
            "fps": String(format: "%.1f", RenderHealth.shared.sampleFPS()),
            "fpsSetting": RenderHealth.testFramesPerSecond.map { "\($0)" } ?? "default",
            "audio": AudioHealth.shared.summary(),
            "thermal": RenderHealth.thermal,
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "nodes": census.nodes,
            "lights": census.lights,
            "lightsByKind": census.byKind,
            "audioSilent": HallwaysAudio.shared.isMuted || HallwaysAudio.shared.isSuppressed
        ])
        diag("snapshot.state", [
            "reason": reason,
            "floor": floorNumber,
            "cell": currentCell,
            "facing": facing,
            "pos": String(format: "%.2f,%.2f", p.x, p.z),
            "yaw": Double(cameraNode.eulerAngles.y),
            "phase": "\(phase)",
            "animating": isAnimating,
            "tapWalking": isFreeTapWalking,
            "heldWalk": walkingHeld,
            "dragRotate": isDragRotating,
            "dragMove": isDragMoving,
            "blockers": diagCanRotateBlockers,
            "elevatorInUse": elevatorInUse,
            "elevatorRide": isElevatorRideInProgress,
            "elevatorWaiting": isElevatorWaitingForFloor,
            "seated": isSeatedAtComputer,
            "seatedInMeeting": isSeatedInMeeting,
            "phoneLift": Double(HallPhone.shared.lift),
            "phoneScreen": "\(HallPhone.shared.screen)",
            "journey": GuidedJourney.trip.map { "\($0.stage)" } ?? "none",
            "posse": Posse.diagSummary
        ])
    }

    /// Oct 2 flight recorder: which canRotate condition is blocking (reads only).
    var diagCanRotateBlockers: String {
        var b: [String] = []
        if isAnimating { b.append("animating") }
        if evictionLocked { b.append("evictionLocked") }                   // (Oct 16)
        if isDragRotating { b.append("dragRotating") }
        if isSeatedAtComputer { b.append("seatedAtComputer") }
        if isSeatedInMeeting { b.append("seatedInMeeting") }
        if isDragMoving { b.append("dragMoving") }
        if elevatorInUse { b.append("elevatorInUse") }
        if chuteInUse { b.append("chuteInUse") }
        if extinguisherPickupInProgress { b.append("extinguisherPickup") }
        if !extinguishingFireCoords.isEmpty { b.append("extinguishing") }
        if activePictureMenu != nil { b.append("pictureMenu") }
        if activePhotoBooth != nil { b.append("photoBooth") }
        if activeTicTacToeTerminal != nil || activeShellGameTerminal != nil || activeRockPaperScissorsTerminal != nil
            || activeHigherLowerTerminal != nil || activeFiveCardDrawTerminal != nil || activeSimonTerminal != nil
            || activeHangmanTerminal != nil || activeConnectFourTerminal != nil || activeCheckersTerminal != nil
            || activeWoidleTerminal != nil { b.append("gameTerminal") }
        return b.isEmpty ? "none" : b.joined(separator: ",")
    }

    private func beginFreeWalkTap(travelDirection: (x: Double, z: Double)? = nil, travelDistance: Double? = nil, finalYaw: Double? = nil,
                                  turnAcrossWholeGlide: Bool = false) {
        cancelPendingWallInteraction("superseded by another tap walk")
        guard canRotate else {
            diag("tapWalk.rejected", ["reason": "canRotate false", "blockers": diagCanRotateBlockers])
            return
        }
        let start = cameraNode.position
        let startYaw = Double(cameraNode.eulerAngles.y)
        // Tapped (essentially) where the player already stands: nothing to do.
        if finalYaw == nil, let travelDistance, travelDistance < 0.05 {
            navLog("free walk tap: destination under the player (\(String(format: "%.3f", travelDistance)) m), ignored")
            diag("tapWalk.rejected", ["reason": "destination under player", "distance": travelDistance])
            return
        }
        var requested = finalYaw != nil && (travelDistance ?? 0) < 0.05 ? 0 : (travelDistance ?? Double(cellSize))
        let forward = travelDirection ?? FreeWalkGeometry.forward(yaw: startYaw)
        if finalYaw == nil, !turnAcrossWholeGlide, let capped = approachCap(from: start, forward: forward, requested: requested) {
            navLog("free walk tap: capped at the interaction distance (\(String(format: "%.2f", requested)) -> \(String(format: "%.2f", capped)) m)")
            requested = capped
        }
        let path = makeFreeWalkGeometry().slidePath(from: SCNVector3(start.x, eyeHeight, start.z),
                                                    dx: forward.x * requested, dz: forward.z * requested)
        // Oct 9: a plain tap aimed into or past a character on guard is an
        // attempt to push past her -- she reacts (her own cooldown applies).
        if finalYaw == nil, !characterKeepOuts.isEmpty,
           segmentMeetsCharacter(x: Double(start.x), z: Double(start.z), dx: forward.x * requested, dz: forward.z * requested) {
            onCharacterBlockBump?()
        }
        var arc: [Double] = [0]
        for i in 1..<max(1, path.count) {
            arc.append(arc[i - 1] + Double(hypotf(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z)))
        }
        let target = path.last ?? start
        let distance = arc.last ?? 0
        // THUD only when the building leaves (essentially) nothing of the
        // request (under 5 cm) -- a useful slide along the wall is a step,
        // not a crash; a sub-5 cm creep is treated as the crash it feels like.
        guard distance > 0.05 || finalYaw != nil else {
            SoundEffects.playHitWall()
            navLog("free walk tap blocked at \(start) yaw=\(cameraNode.eulerAngles.y)")
            diag("tapWalk.rejected", ["reason": "blocked by wall", "cell": currentCell])
            return
        }
        cameraNode.removeAction(forKey: Self.freeLookAlignActionKey)
        freeWalkGeometry = makeFreeWalkGeometry()
        freeWalkCell = currentCell
        freeMoveHeld = false
        continuousRun = false
        segmentStart = start
        segmentTarget = target
        freeTapPath = path
        freeTapArc = arc
        freeTapSegment = 0
        freeTapStartYaw = startYaw
        freeTapEndYaw = finalYaw.map { Self.yaw(facing: FreeWalkGeometry.forward(yaw: $0), near: startYaw) }
            ?? travelDirection.map { Self.yaw(facing: $0, near: startYaw) } ?? startYaw
        segmentProgress = 0
        // (Oct 20: at the automatic walks' pace -- autoWalkSpeedScale)
        let timing = Self.tapWalkTiming(distance: distance, cellSize: Double(cellSize), speed: autoWalkSpeed,
                                        approach: finalYaw != nil, turnAcrossWholeGlide: turnAcrossWholeGlide)
        freeTapRampTime = timing.ramp
        freeTapDuration = timing.duration
        freeTapTurnDuration = timing.turn
        let walks = distance > 0.05
        freeTapStopRequested = false
        if cruiseActive || continuousWalkState != .stopped { stopContinuousWalk(reason: "tapWalk") }
        freeTapWalkActive = true
        tapWalkDestination = target
        movementPace = 1
        SoundEffects.setWalkingPace(1)
        phase = .freeMove
        isAnimating = true
        if walks {                                 // a turn-in-place approach is silent
            freeWalkFootstepsOn = true
            freeWalkFootstepsReverse = false
            freeWalkFootstepStarts += 1
            SoundEffects.startWalking()
        }
        navLog("free walk tap from \(start) to \(target) (\(String(format: "%.2f", distance)) m)")
        diag("tapWalk.accepted", ["distance": distance, "turnOnly": !walks, "cell": currentCell])
    }

    /// Oct 2 (auto-walk -> long-press handoff): converts a running tap-to-
    /// point walk into the ORDINARY free held walk, in place -- same
    /// position, same yaw, still moving (phase stays .freeMove, isAnimating
    /// stays true, footsteps keep their current state), so the next frame
    /// simply runs the existing held branch. The tap walk's destination,
    /// eased path, pending turn and stop request are discarded, so nothing
    /// can resume or snap to it later. Only while the tap walk is genuinely
    /// mid-move (.freeMove): if it is already finishing (.awaitingTurnCommit,
    /// its main-thread completion queued), returns false and the hold's
    /// next tick starts a normal held walk once that completes.
    @discardableResult
    func takeOverFreeTapWalkForHold() -> Bool {
        guard walkingHeld, isFreeTapWalking, phase == .freeMove, freeWalkApplies(held: true) else { return false }
        cancelPendingWallInteraction("hold/drag takeover")
        manualFootstepsFromAutoWalk = true
        freeTapStopRequested = false
        freeTapWalkActive = false
        freeTapPath = []
        freeTapArc = []
        freeTapSegment = 0
        freeTapEndYaw = Double(cameraNode.eulerAngles.y)
        freeTapStartYaw = freeTapEndYaw
        segmentTarget = cameraNode.position
        freeMoveHeld = true
        continuousRun = true
        heldSteeringActive = false        // first held update pins the steering origin here (no jump)
        heldThrottle = 1
        heldDistance = 0
        navLog("free walk tap taken over by a hold at \(cameraNode.position) yaw=\(cameraNode.eulerAngles.y)")
        return true
    }

    /// Oct 2 (auto-walk -> pinch handoff): ends a running tap-to-point walk
    /// at once, IN PLACE (this position, this yaw; no glide, no snap), and
    /// discards its destination/path/stop request, so the ordinary pinch
    /// (beginDragMove) can begin from here on this same call. Synchronous on
    /// purpose: canRotate must be true before beginDragMove's guard. Same
    /// end state finishFreeMove's completion leaves (stopped, .translate,
    /// facing = nearest cardinal). Only while the walk is genuinely mid-move.
    @discardableResult
    func takeOverFreeTapWalkForPinch() -> Bool {
        guard isFreeTapWalking, phase == .freeMove, freeWalkApplies(held: false) else { return false }
        cancelPendingWallInteraction("pinch takeover")
        manualFootstepsFromAutoWalk = true
        freeTapStopRequested = false
        freeTapWalkActive = false
        freeTapPath = []
        freeTapArc = []
        freeTapSegment = 0
        freeTapEndYaw = Double(cameraNode.eulerAngles.y)
        freeTapStartYaw = freeTapEndYaw
        segmentTarget = cameraNode.position
        isAnimating = false
        phase = .translate
        freeWalkFootstepsOn = false
        freeWalkFootstepsReverse = false
        SoundEffects.stopWalking()
        movementPace = 1
        SoundEffects.setWalkingPace(1)
        let heading = nearestCardinal(toYaw: Double(cameraNode.eulerAngles.y))
        if facing != heading { facing = heading }
        navLog("free walk tap taken over by a pinch at \(cameraNode.position) yaw=\(cameraNode.eulerAngles.y)")
        return true
    }

    private func beginFreeHeldWalk() {
        guard canRotate else { return }
        if cruiseActive || continuousWalkState != .stopped { stopContinuousWalk(reason: "holdWalk") }
        cameraNode.removeAction(forKey: Self.freeLookAlignActionKey)
        freeWalkGeometry = makeFreeWalkGeometry()
        freeWalkCell = currentCell
        freeMoveHeld = true
        continuousRun = true
        heldSteeringActive = false
        heldThrottle = 1
        latchPaceScale = 1                                          // (Oct 16: a new walk starts at full pace)
        phase = .freeMove
        isAnimating = true
        // Oct 2 (final audio rule): a hold started from standing is silent.
        manualFootstepsFromAutoWalk = false
        freeWalkFootstepsOn = false
        freeWalkFootstepsReverse = false
        navLog("free walk hold began at \(cameraNode.position)")
    }

    /// Render thread: after moving, notice a new containing cell and hand
    /// it to the ordinary arrival path (pickups, doors closing behind,
    /// map, viewed flags) -- once per cell entered.
    private func freeWalkTrackCell(_ position: SCNVector3) {
        guard let geometry = freeWalkGeometry else { return }
        let cell = geometry.containingCell(x: Double(position.x), z: Double(position.z), previous: freeWalkCell)
        guard cell != freeWalkCell else { return }
        freeWalkCell = cell
        let heading = nearestCardinal(toYaw: Double(cameraNode.eulerAngles.y))
        DispatchQueue.main.async { [weak self] in
            self?.applyNavigationUpdate { [weak self] in
                guard let self else { return }
                self.applyArrival(cell: cell, heading: heading)
                self.markFloorMapViewedIfPresent(at: cell)
                self.markMissionSignViewedIfPresent(at: cell)
                navLog("free walk entered \(cell)")
            }
        }
    }

    /// Render thread: the movement is over, exactly where it is.
    private func finishFreeMove() {
        phase = .awaitingTurnCommit
        let heading = nearestCardinal(toYaw: Double(cameraNode.eulerAngles.y))
        let position = cameraNode.position
        DispatchQueue.main.async { [weak self] in
            self?.applyNavigationUpdate { [weak self] in
                guard let self else { return }
                self.isAnimating = false
                self.freeMoveHeld = false
                if self.walkLatched, !self.walkingHeld { self.heldDistance = 0 }   // (Oct 16: the latch's pace ends with it)
                self.walkLatched = false                            // (Oct 16: any end of the walk ends the latch)
                self.latchTurnTarget = nil
                self.heldSteeringActive = false
                self.freeTapWalkActive = false
                self.freeWalkFootstepsOn = false
                self.freeWalkFootstepsReverse = false
                SoundEffects.stopWalking()
                if self.facing != heading { self.facing = heading }
                if !self.walkingHeld {
                    self.movementPace = 1
                    SoundEffects.setWalkingPace(1)
                }
                self.phase = .translate
                navLog("free walk stopped at \(position) in \(self.currentCell) facing \(self.facing)")
                // Oct 2 wall-interaction experiment: the glide ended on its
                // own (every takeover/stop cleared this first) -- now the
                // fixture's ordinary activate runs, with its own guards.
                if let pending = self.pendingWallInteraction {
                    self.pendingWallInteraction = nil
                    let finalYaw = Double(self.cameraNode.eulerAngles.y)
                    diag("wallInteraction.align.complete", ["kind": pending.kind,
                         "at": String(format: "(%.3f, %.3f)", position.x, position.z),
                         "yaw": finalYaw, "yawError": self.shortestDelta(from: finalYaw, to: pending.targetYaw),
                         "facing": "\(self.facing)", "cell": self.currentCell])
                    if let run = pending.run {
                        diag("wallInteraction.action.invoked", ["kind": pending.kind])
                        run()
                    }
                } else if !self.landingSpots.isEmpty {
                    // Oct 5: a walk that just stopped in front of the
                    // reception counter gets the landing (next main turn,
                    // outside this navigation update).
                    DispatchQueue.main.async { [weak self] in self?.landAtSpotIfApproaching() }
                }
                // Oct 20 (night): stopped right up at the closed elevator -- a step back
                // to where its sign, doors and call buttons are all in view (after any
                // landing above has had its turn: one that started wins).
                DispatchQueue.main.async { [weak self] in self?.settleAtElevatorViewIfNeeded() }
            }
        }
    }

    /// Oct 22 (morning): following a critter, the player's walk spends much of
    /// its time creeping behind it at the following gap -- and the footstep loop,
    /// which never plays slower than an ordinary stride (SoundEffects.setWalkingPace
    /// floors it at 1), ticked on at a full stride all through it; with the
    /// critter walking just ahead, those steps read as the critter's.
    /// Oct 22 (stability pass): even at a normal pace they still read as the
    /// critter's (the player walks behind it in step), so while actively
    /// following a critter the player's own steps are SILENT. They come back the
    /// moment following ends (any other walk sets them as always). Escorts and
    /// every other walk are exactly as before; no speed changes.
    private func cruiseFootstepsWanted(moved: Double, dt: Double) -> Bool {
        guard moved > 0.0005 else { return false }
        return !cruiseGuidance.leaderBeside
    }

    /// Footsteps on/off, and (Oct 2) forward or backward loop while on. A
    /// direction change while moving swaps loops once; holding a direction
    /// never restarts it. Backing up through the stop band goes silent first.
    private func setFreeWalkFootsteps(_ on: Bool, reverse: Bool = false) {
        guard on != freeWalkFootstepsOn || (on && reverse != freeWalkFootstepsReverse) else { return }
        if on && !freeWalkFootstepsOn { freeWalkFootstepStarts += 1 }
        freeWalkFootstepsOn = on
        if on { freeWalkFootstepsReverse = reverse }
        DispatchQueue.main.async { on ? SoundEffects.startWalking(reverse: reverse) : SoundEffects.stopWalking() }
    }
    /// Oct 2: true while the free-walk footsteps are the backward loop.
    private(set) var freeWalkFootstepsReverse = false
    /// Oct 2 (final audio rule): walking sound belongs to tap-to-destination
    /// auto-walk. Manual movement is silent -- EXCEPT the one gesture (hold/pan
    /// or pinch) that took ownership of a running auto-walk, which keeps
    /// directional footsteps until it ends. Set ONLY by the two takeovers;
    /// cleared when that gesture ends (setWalkingHeld(false), endDragMove) and
    /// by any manual gesture that starts from standing, so it never leaks.
    private(set) var manualFootstepsFromAutoWalk = false

    // MARK: - FREE-WALK held steering (Sept 29, polish pass #1)
    //
    // HOLD = WALK. SAME HELD FINGER LEFT/RIGHT = STEER. LIFT = STOP.
    // The long press that started the free held walk owns the touch (the
    // Free Look pan can't recognize once it has) and keeps delivering
    // .changed locations -- the same stream legacy HeldEndpointLook uses.
    // Horizontal displacement from where the finger was when steering
    // began turns the camera with Free Look's exact math
    // (pointsPerQuarterTurn points = 90 degrees, finger right = positive
    // yaw = turn left, unclamped). The .freeMove loop already samples the
    // camera yaw every frame, so the path simply curves. No snap, no turn
    // event, no pause. A wall-blocked hold is still a held walk, so
    // steering away lets the next frame's step become legal and walking
    // resumes on its own.

    private(set) var heldSteeringActive = false
    private var heldSteeringOriginX: Double = 0
    private var heldSteeringOriginY: Double?
    private var heldSteeringOriginYaw: Double = 0
    private var heldSteeringPointsPerQuarterTurn: Double = 140

    // MARK: FREE-WALK held-walk TURN-RATE LIMIT (Sept 30 experiment)
    //
    // The finger sets a TARGET yaw (same 230 pt = 90 deg mapping as before).
    // While the held walk is translating (throttle != 0, even if a wall is
    // blocking it) the actual yaw moves toward that target by at most
    // heldWalkMaxTurnRate * dt per frame -- a big finger excursion becomes
    // an arc, not an instant 90-degree swerve. A RATE limit only: no angle
    // clamp, no snapping, no momentum (the target is followed exactly,
    // never overshot; bring the finger back and the turn stops). Stationary
    // (neutral throttle) turning keeps the old immediate response.
    // Unwrapped yaw on purpose: +270 deg of finger means +270 deg of turn.

    /// THE TUNING NUMBER: max held-walk yaw rate while moving, rad/s.
    /// .pi = 180 deg/s (90 deg in 0.5 s).
    static let heldWalkMaxTurnRate: Double = .pi
    /// The limit actually applied (tests set .infinity to check the raw mapping).
    var heldWalkTurnRateLimit: Double = TapNavigationController.heldWalkMaxTurnRate
    /// Yaw the finger is asking for / yaw the held walk has actually reached.
    private(set) var heldSteeringTargetYaw: Double = 0
    private var heldSteeringYaw: Double = 0

    /// Move `current` toward `target` by at most `maxStep` (radians, >= 0).
    /// Linear in unwrapped yaw -- never takes a "shortest way round".
    static func rateLimitedYaw(current: Double, target: Double, maxStep: Double) -> Double {
        let delta = target - current
        guard abs(delta) > maxStep else { return target }
        return current + (delta > 0 ? maxStep : -maxStep)
    }

    /// Per-frame step from the .freeMove loop.
    private func stepHeldSteering(dt: Double, translating: Bool) {
        guard heldSteeringActive, heldSteeringYaw != heldSteeringTargetYaw else { return }
        let maxStep = translating ? heldWalkTurnRateLimit * dt : .infinity
        heldSteeringYaw = Self.rateLimitedYaw(current: heldSteeringYaw, target: heldSteeringTargetYaw, maxStep: maxStep)
        cameraNode.eulerAngles = SCNVector3(0, Float(heldSteeringYaw), 0)
    }

    // MARK: FREE-WALK unified held navigation (polish pass #2)
    //
    // X = TURN and Y = MOVE, at the same time, for the whole life of the
    // held touch -- no axis lock, no modes. Y is a throttle measured from
    // the same activation origin as X (UIKit y: positive = finger moved
    // DOWN, matching the existing "drag down = forward" convention):
    //   finger at origin (or below)  -> +1, today's hold-to-walk
    //   ~60 pt UP from origin        -> 0, stand still (turn in place)
    //   ~120 pt UP from origin       -> -1, back up at walking pace
    // proportional in between, with a small dead band around the stop
    // point. Translation is signed along the camera's ACTUAL yaw.

    /// Signed translation throttle, -1...1, read by the .freeMove loop.
    private(set) var heldThrottle: Double = 1
    static let heldStopOffset: Double = 60   // pt of upward travel from origin to reach "stopped"
    static let heldThrottleDeadZone: Double = 12

    /// Throttle for a vertical finger offset from the held origin
    /// (positive = finger moved down).
    static func throttle(forVerticalOffset dy: Double) -> Double {
        let s = dy + heldStopOffset // 60 at the origin, 0 at the stop point
        guard abs(s) > heldThrottleDeadZone else { return 0 }
        let t = (abs(s) - heldThrottleDeadZone) / (heldStopOffset - heldThrottleDeadZone)
        return max(-1, min(1, s > 0 ? t : -t))
    }

    /// The held finger's location, both axes. The first call once a free
    /// held walk is running only records the origin (this location + the
    /// current yaw); nothing moves or turns. Later calls set yaw from X
    /// (Free Look math) and the translation throttle from Y.
    func updateHeldNavigation(fingerX: Double, fingerY: Double?, pointsPerQuarterTurn: Double) {
        updateHeldWalkSteering(fingerX: fingerX, pointsPerQuarterTurn: pointsPerQuarterTurn)
        guard heldSteeringActive, let fingerY else { return }
        guard let originY = heldSteeringOriginY else {
            heldSteeringOriginY = fingerY
            return
        }
        heldThrottle = Self.throttle(forVerticalOffset: fingerY - originY)
    }

    /// True while a free held walk is running (moving or wall-blocked).
    var freeHeldWalkActive: Bool { freeMoveHeld && walkingHeld && isAnimating && phase == .freeMove }

    /// Feed the held finger's x. The first call once a free held walk is
    /// running only records the origin (this finger x + the current yaw),
    /// so pre-recognition drift never turns the camera. Later calls set
    /// yaw = originYaw + (x - originX) / pointsPerQuarterTurn * pi/2.
    /// No-op outside a free held walk (legacy holds keep HeldEndpointLook).
    func updateHeldWalkSteering(fingerX: Double, pointsPerQuarterTurn: Double) {
        guard freeHeldWalkActive, pointsPerQuarterTurn > 0 else { return }
        guard heldSteeringActive else {
            heldSteeringActive = true
            heldSteeringOriginX = fingerX
            heldSteeringOriginY = nil
            heldSteeringOriginYaw = Double(cameraNode.eulerAngles.y)
            heldSteeringTargetYaw = heldSteeringOriginYaw
            heldSteeringYaw = heldSteeringOriginYaw
            heldSteeringPointsPerQuarterTurn = pointsPerQuarterTurn
            navLog("free walk steering origin x=\(String(format: "%.1f", fingerX)) yaw=\(String(format: "%.3f", heldSteeringOriginYaw))")
            return
        }
        let fraction = (fingerX - heldSteeringOriginX) / heldSteeringPointsPerQuarterTurn
        heldSteeringTargetYaw = heldSteeringOriginYaw + fraction * .pi / 2
        // Standing still (neutral throttle), or no limit (.infinity = the old
        // behaviour): turn immediately. Moving: the .freeMove loop turns
        // toward the target at the limited rate.
        if heldThrottle == 0 || !heldWalkTurnRateLimit.isFinite { stepHeldSteering(dt: 0, translating: false) }
    }

    // MARK: - CONTINUOUS WALK & QUEUED TURNS (Oct 10 experiment)
    //
    // Three HUD buttons: LEFT | WALK/STOP | RIGHT (ContinuousWalkControls).
    // WALK starts ONE renderer-driven free movement (the same .freeMove phase,
    // FreeWalkGeometry, slideEndpoint collision, keep-outs, cell tracking and
    // arrivals every other free walk uses) that keeps going on its own until
    // STOP, a dead end, a block, or anything that takes movement away. While
    // walking, LEFT/RIGHT queue a turn (last press wins; the same arrow again
    // cancels) that executes at the next opening on that side STILL AHEAD of
    // the player, as one continuous quarter-circle arc that starts `radius`
    // before the crossing's centre and ends on the new corridor's centreline.
    // Stopped, LEFT/RIGHT are the ordinary 90-degree pivot (rotate(toward:)).
    // Any touch gesture on the scene stops the walk first (ContentView).

    /// Master switch for the experiment (hides the buttons when false).
    static let continuousWalkExperimentOn = true

    enum ContinuousWalkTurn: Equatable { case left, right }
    enum ContinuousWalkState: Equatable {
        case stopped
        case walking
        case walkingQueued(ContinuousWalkTurn)
    }
    /// What the HUD shows. Main thread only.
    @Published private(set) var continuousWalkState: ContinuousWalkState = .stopped

    /// Max deceleration toward a stop / a turn's entry speed (scene units/s^2).
    static let cruiseBrake: Double = 10
    /// Acceleration from standing / out of a turn.
    static let cruiseAccel: Double = 8
    /// THE TUNING NUMBER (Oct 10 addendum): seconds per 90 degrees for a
    /// HUD LEFT/RIGHT pivot, eased in and out. Queued walking turns use the
    /// same time for their corner arc (the walk slows to whatever speed
    /// covers the arc in this time), so both read as one body turn.
    static var pivotTurnDuration: Double = 0.30
    /// Corner-arc speed for a given radius: the arc takes pivotTurnDuration.
    static func cruiseTurnSpeed(radius: Double) -> Double {
        radius * .pi / 2 / max(0.05, pivotTurnDuration)
    }
    /// A LEFT/RIGHT pressed while a HUD pivot is still turning: runs when it
    /// finishes (last press wins). Never two rotations at once.
    private var pendingHUDPivot: ContinuousWalkTurn?
    /// True from a HUD pivot's start until its main-thread completion.
    private var hudPivotInFlight = false
    /// Preferred corner radius (clamped to the legal corridor band).
    static let cruiseTurnRadius: Double = 0.5

    // MARK: Smart WALK (Oct 10, playthrough refinements)
    /// TUNING SWITCH: WALK stops at a hallway decision -- a cell offering a
    /// genuine choice (straight plus a side branch, or both sides) -- just
    /// short of its mouth, where the openings are still in view. WALK again
    /// goes straight on; LEFT/RIGHT there walk on and take that way with the
    /// usual smooth corner (no stop-pivot-go).
    var smartWalkDecisionStopsOn = true
    /// TUNING: how far short of the decision's mouth (its near edge) the
    /// walk stops, metres. 0 = right at the mouth.
    static var smartWalkDecisionStopShort: Double = 0.4
    /// Oct 11 (escort pacing): while a character escorts the player, WALK
    /// keeps at least this far (metres, camera to the character's centre)
    /// behind it -- braking smoothly to it on the ordinary braking curve and
    /// picking up again as the guide moves on. Never overtakes, never pushes.
    static let escortFollowGap: Double = 1.7
    /// Oct 11: the held landing pitch (holdLandingPitch) -- which pose holds it.
    var landingPitchKind: String?
    var landingPitchGeneration = 0
    /// Where the last decision stop left the player, and its decision cell.
    private var cruiseDecisionStop: (cell: GridCoordinate, x: Float, z: Float)?
    /// Cells that are not decisions for this walk: where it started, and the
    /// decision it was just stopped for (WALK again = go on through it).
    private var cruiseDecisionSkip: Set<GridCoordinate> = []
    /// (Unused since the stop moved short of the mouth; kept false.)
    private var cruiseWalkAfterPivot = false
    /// The cell the walk started in: never a decision (or a landing) for
    /// this walk -- that's where the player just chose to go on from.
    private var cruiseStartCell: GridCoordinate?
    /// Main-thread snapshot for the render-thread walk (swapped under
    /// cruiseGeometryLock, like the geometry): an active escort's route
    /// (cell -> the way it goes on) and the landing spots that cap a walk
    /// (the existing LandingSpot.capsApproach -- conversation distance).
    private struct CruiseGuidance {
        var routeOnward: [GridCoordinate: Direction]? = nil
        /// Oct 11: the escorting character's ground position (x, z), while escorting.
        var leader: (x: Double, z: Double)? = nil
        var landingCaps: [(cell: GridCoordinate, face: Direction, x: Double, z: Double)] = []
        /// Oct 20: the walk's pace factor (automatic walks 0.8; an escort's walk 1 -- as it was).
        var paceScale: Double = TapNavigationController.autoWalkSpeedScale
        /// Oct 20 (follow smoothness): the following gap holds with the critter
        /// anywhere in front or to the side (round a corner) -- not only dead
        /// ahead -- so the walk never sprints at a corner and brakes hard after it.
        /// Following a critter only; an escort's walk keeps its own rule.
        var leaderBeside = false
    }
    private var cruiseGuidance = CruiseGuidance()
    private var cruisePendingGuidance: CruiseGuidance?

    /// Main thread: what the walk should know about escorts and landings now.
    private func makeCruiseGuidance() -> CruiseGuidance {
        let perf = PerfMonitor.begin("cruise.guidance"); defer { PerfMonitor.end(perf) }  // Oct 21: measurement only
        var guidance = CruiseGuidance()
        // (Oct 13: with no escort under way, GO's own route to Tinky's desk after the ID -- adminGoRoute.)
        let adminRoute = adminGoRoute.flatMap { $0.contains(currentCell) ? $0 : nil }   // (only while still on it)
        if let route = CharacterLead.activeGuidedRoute ?? adminRoute, route.count >= 2 {
            var onward: [GridCoordinate: Direction] = [:]
            for i in 0..<(route.count - 1) {
                let a = route[i], b = route[i + 1]
                if let d = Direction.allCases.first(where: { $0.delta.row == b.row - a.row && $0.delta.col == b.col - a.col }) {
                    onward[a] = d
                }
            }
            guidance.routeOnward = onward
            if let p = CharacterLead.activeGuidePosition { guidance.leader = (Double(p.x), Double(p.y)) }
            guidance.paceScale = Self.continuousWalkPaceScale(escorting: true)       // (Oct 20: the escort's pacing, untouched)
        } else if let follow = followGuidance?(), follow.route.count >= 2 {
            // Oct 20 (following a critter): the same escort walk -- its way, kept
            // a following gap behind it (CritterFollow.swift supplies both).
            var onward: [GridCoordinate: Direction] = [:]
            for i in 0..<(follow.route.count - 1) {
                let a = follow.route[i], b = follow.route[i + 1]
                if let d = Direction.allCases.first(where: { $0.delta.row == b.row - a.row && $0.delta.col == b.col - a.col }) {
                    onward[a] = d
                }
            }
            guidance.routeOnward = onward
            if let p = follow.leader { guidance.leader = (Double(p.x), Double(p.y)) }
            guidance.leaderBeside = true
        }
        for spot in landingSpots where spot.capsApproach && (spot.isAvailable?() ?? true) {
            let p = landingPosition(spot)
            guidance.landingCaps.append((spot.face.coord, spot.face.direction, Double(p.x), Double(p.z)))
        }
        // Oct 21: the walk toward Tinky stops in the anteroom (the centre of its cell).
        if adminWalk == .towardTinky, adminRoute != nil {
            let stop = Self.towardTinkyStop
            guidance.landingCaps.append((stop.coord, stop.direction, Double(stop.coord.col) * Double(cellSize),
                                         Double(stop.coord.row) * Double(cellSize)))
        }
        return guidance
    }

    /// Does the following gap hold the walk back (pure)? The leader ahead along
    /// the walk's direction `f` -- or, `beside` (following a critter), anywhere up
    /// to well round to the side (within about 115 degrees of straight ahead):
    /// round a corner from the player it still sets the pace. Behind: no.
    static func leaderHolds(along f: (x: Double, z: Double), dx: Double, dz: Double, beside: Bool) -> Bool {
        let dot = dx * f.x + dz * f.z
        if dot > 0 { return true }
        guard beside else { return false }
        return dot > -0.42 * hypot(dx, dz)
    }

    /// Render thread: distance ahead to a capped landing spot's pose on this
    /// heading (walking toward what it faces, on its line), if any.
    private func cruiseLandingCap(x: Double, z: Double, heading: Direction, cellSize: Double) -> Double? {
        let f = Self.unit(heading)
        var best: Double?
        for cap in cruiseGuidance.landingCaps where cap.face == heading && cap.cell != cruiseStartCell {
            let t = (cap.x - x) * f.x + (cap.z - z) * f.z
            let lateral = abs((cap.x - x) * f.z - (cap.z - z) * f.x)
            guard t > -0.05, lateral < cellSize / 2 else { continue }
            best = min(best ?? .infinity, max(0, t))
        }
        return best
    }

    /// Main thread, after a decision stop: remember it; a turn pressed too
    /// late to take as a corner is taken now, as a pivot and walk on.
    private func continuousWalkDecisionStop(cell: GridCoordinate, late: ContinuousWalkTurn?) {
        let p = cameraNode.position
        cruiseDecisionStop = (cell, p.x, p.z)
        diag("cruise.decision", ["cell": currentCell, "decision": cell, "facing": "\(facing)", "late": late.map { "\($0)" } ?? "-"])
        if let late { continuousWalkTurnTapped(late) }
    }

    private struct CruiseArc {
        let centerX: Double, centerZ: Double
        let headX: Double, headZ: Double      // old heading (unit)
        let sideX: Double, sideZ: Double      // new heading (unit)
        let radius: Double
        let startYaw: Double, endYaw: Double
        let endHeading: Direction
        let serial: Int
        /// Oct 12: a wide automatic corner's own pace (and an eased view); nil = the queued-turn rule.
        var speed: Double? = nil
        /// Oct 13: a SMOOTH corner's own path (nil = the quarter circle above).
        var smooth: SmoothTurn? = nil
        var route = false                     // Oct 13: an escort's turn (the guide's gap applies in it)
        var travelled: Double = 0
        var stall: Double = 0
        var length: Double { smooth?.length ?? radius * .pi / 2 }
        // Oct 13 (diagnostics): what the corner actually did.
        var elapsed: Double = 0
        var movedSum: Double = 0
        var peakRate: Double = 0
        var lastYaw: Double? = nil
        var segment = 0
    }

    // Written on main, read by the render loop (same convention as walkingHeld).
    private var cruiseActive = false
    private var cruiseSession = 0
    /// Oct 21: cruise watch passes (only for -HallwaysPerfSlowCruiseRebuild).
    private var cruiseWatchPasses = 0
    private var cruiseRequest: (turn: ContinuousWalkTurn, serial: Int)?
    private var cruiseRequestSerial = 0
    // Render-loop state.
    private var cruiseConsumedSerial = -1
    private var cruiseHeadingYaw: Double = 0
    private var cruiseArc: CruiseArc?
    private var cruiseSpeed: Double = 0
    private var cruiseDistance: Double = 0
    private var cruiseStall: Double = 0
    private var cruiseBumped = false
    private let cruiseGeometryLock = NSLock()
    private var cruisePendingGeometry: FreeWalkGeometry?

    // MARK: Oct 10 -- CONTEXTUAL NAVIGATION (the center button + assistance)
    //
    // Automate the obvious, preserve the choices. While walking, a closed
    // ordinary door ahead is opened with its own existing door code (never a
    // guarded, intercepted or blocked one), the elevator ahead is boarded with
    // openElevator() (its own guards and feedback), and a dead-end with exactly
    // one way on is rounded like a queued turn. Stopped, the center button
    // offers the one existing interaction in front of the player (OPEN, TAKE,
    // USE, PLAY...), run through the same handler a tap would use. Priority:
    // scripts/restrictions > STOP > explicit turns > interactions > assistance.

    /// A closed door at the end of the straight run ahead (render side).
    enum CruiseDoor: Equatable {
        case roomEntrance(GridCoordinate), bathroom(GridCoordinate), windowRoom(GridCoordinate)
    }
    /// The door this walk already asked to open (once per door per walk).
    private var cruiseDoorRequested: CruiseDoor?
    /// Walk clock (render) and the moment until which a just-opened doorway is
    /// taken at door speed, so the leaf is clear before the player gets there.
    private var cruiseClock: Double = 0
    private var cruiseDoorSlowUntil: Double = 0
    /// Lead (beyond braking distance) at which a door ahead is asked to open.
    static let cruiseDoorLead: Double = 1.5
    /// Speed through a doorway that has only just begun to swing open.
    static let cruiseDoorSpeed: Double = 3.5
    /// The fast walk: the pace a sustained walk picks up after three cells (x the
    /// normal walking speed, which is unchanged). Oct 19: 1.5 -> 1.35 (10% slower).
    static let fastWalkPace: Double = 1.35
    /// The classic held tap-walk's fast pace (after two cells). Oct 19: 1.6 -> 1.44 (10% slower).
    static let fastWalkPaceClassic: Double = 1.44
    /// Run when the walk ends in front of something that refused it (e.g. the
    /// guarded Administration doors: Juanita's existing reaction).
    private var cruiseStopReaction: (() -> Void)?
    /// WALK pressed while the player can't move YET (stepping out of the cab,
    /// a walk or turn finishing): the walk starts the moment movement frees up.
    private var cruiseStartDeadline: Date?
    static let cruiseStartWaitLimit: TimeInterval = 8
    /// After STOP, the center button ignores taps this long, so a double tap
    /// can never turn into OPEN/TAKE/USE.
    static let hudStopToActionGuard: TimeInterval = 0.45
    private var hudInteractionArmedAt: Date = .distantPast
    /// How far (radians) the view may be off its cardinal facing for the
    /// thing in front to count as "in front".
    static let hudFacingTolerance: Double = 35 * .pi / 180
    /// The scene view (the office computer's seat needs it). Set by ContentView.
    weak var hudSceneView: SCNView?
    /// Elevator-cab LEFT/RIGHT pivot in flight (same look the pan drives).
    private var elevatorHUDPivotRunning = false
    static let elevatorHUDPivotActionKey = "hudElevatorPivot"

    /// Why a continuous walk can't run right now (nil = it can).
    private var continuousWalkBlockReason: String? {
        if isSeatedAtComputer { return "seatedAtComputer" }
        if isSeatedInMeeting { return "seatedInMeeting" }
        if activePictureMenu != nil || activePhotoBooth != nil || activeTicTacToeTerminal != nil || activeShellGameTerminal != nil
            || activeRockPaperScissorsTerminal != nil || activeHigherLowerTerminal != nil || activeFiveCardDrawTerminal != nil
            || activeSimonTerminal != nil || activeHangmanTerminal != nil || activeConnectFourTerminal != nil
            || activeCheckersTerminal != nil || activeWoidleTerminal != nil { return "interactionOpen" }
        if elevatorInUse || isElevatorRideInProgress { return "elevator" }
        if chuteInUse { return "chute" }
        if extinguisherPickupInProgress || !extinguishingFireCoords.isEmpty { return "fireScript" }
        if isDragRotating || isDragMoving || walkingHeld { return "gesture" }
        if pendingWallInteraction != nil { return "wallInteraction" }
        if !freeWalkApplies(held: true) { return "freeWalkUnavailable" }
        return nil
    }

    /// WALK / STOP.
    func continuousWalkButtonTapped() {
        if continuousWalkState == .stopped { startContinuousWalk() } else { stopContinuousWalk(reason: "stopButton") }
    }

    /// What the center button offers right now.
    enum HUDCenter: Equatable {
        case walk, stop, action(String), unavailable
        var label: String {
            switch self {
            case .walk, .unavailable: return "GO"                // Oct 12: the WALK button now reads GO (display only)
            case .stop: return "STOP"
            case .action(let label): return label
            }
        }
    }

    var hudCenter: HUDCenter {
        if continuousWalkState != .stopped { return .stop }               // STOP always wins
        if elevatorAwaitingEntryDirection != nil { return .walk }        // in the cab: WALK steps out
        if isElevatorRideInProgress || isElevatorWaitingForFloor { return .unavailable }
        if let target = contextualTarget() { return .action(target.label) }
        if let reason = continuousWalkBlockReason, reason != "wallInteraction", reason != "gesture" { return .unavailable }
        return .walk
    }

    /// The center button. STOP never does anything but stop.
    func hudCenterTapped() {
        let center = hudCenter
        switch center {
        case .stop:
            stopContinuousWalk(reason: "stopButton")
            hudInteractionArmedAt = Date().addingTimeInterval(Self.hudStopToActionGuard)
        case .walk:
            startContinuousWalk()
        case .action(let label):
            guard Date() >= hudInteractionArmedAt, let target = contextualTarget(), target.label == label else {
                diag("hud.actionIgnored", ["label": label, "reason": "justStopped or changed"])
                return
            }
            diag("hud.action", ["label": label, "kind": target.kind, "cell": currentCell, "facing": "\(facing)"])
            target.perform()
            objectWillChange.send()
        case .unavailable:
            diag("hud.centerIgnored", ["blocked": continuousWalkBlockReason ?? "elevator"])
        }
    }

    struct HUDTarget {
        let label: String
        let kind: String
        let perform: () -> Void
    }

    /// The single existing interaction directly in front of a stationary
    /// player, judged by the same rules its tap uses (cell, facing, range,
    /// availability), or nil. Never a guess between several.
    func contextualTarget() -> HUDTarget? {
        // Oct 12: THE BOX's REPLAY, offered for a few seconds after a tap on the projection screen.
        if floorNumber == ConferenceRoom.floor, let replay = BoxReveal.replayTarget() { return replay }
        // Oct 12 (the room remembers): during a REPLAY of THE BOX, SKIP.
        if floorNumber == ConferenceRoom.floor, let skip = BoxReveal.skipTarget() { return skip }
        // Oct 11 (the staff meeting): seated at the conference table, the one
        // thing on offer is getting up again.
        if isSeatedInMeeting { return ConferenceMeeting.standTarget() }
        guard !decorateModeEnabled, canRotate else { return nil }
        let yaw = Double(cameraNode.eulerAngles.y)
        // Oct 11 (the staff meeting): the empty chair at the foot of the
        // conference table, judged by the look at the chair itself (from the
        // doorway cell it lies on a diagonal, so not by the cardinal facing).
        if let target = ConferenceMeeting.sitTarget(controller: self, cell: currentCell, yaw: yaw) { return target }
        guard abs(shortestDelta(from: yaw, to: facing.yaw)) < Self.hudFacingTolerance else { return nil }
        let cell = currentCell, f = facing
        // The elevator (its call/board path, or stepping back into an open cab).
        if cell == endCell, f == elevatorMountDirection, elevatorLeftDoor != nil {
            if canReenterArrivedElevator {
                return HUDTarget(label: "ENTER", kind: "elevatorReenter") { [weak self] in self?.advance(source: "HUD_ENTER") }
            }
            if !elevatorInUse, !chuteInUse, !characterUsingElevator || characterCycleJoinable, elevatorAwaitingEntryDirection == nil,
               elevatorLeftDoor?.action(forKey: "arrivalCloseBehind") == nil,
               isMissionComplete || !Self.missionGatesElevator, nextFloorNumber != floorNumber {
                return HUDTarget(label: "OPEN", kind: "elevator") { [weak self] in self?.openElevator() }
            }
            return nil
        }
        // A closed door in front (never a guarded one: trying it is her cue).
        if let door = closedDoor(from: cell, direction: f) {
            switch door {
            case .roomEntrance(let coord):
                guard roomEntranceDoorGuarded?(coord) != true else { return nil }
                return HUDTarget(label: "OPEN", kind: "roomEntranceDoor") { [weak self] in self?.openRoomEntranceDoor(at: coord) }
            case .bathroom(let coord):
                return HUDTarget(label: "OPEN", kind: "bathroomDoor") { [weak self] in self?.openBathroomDoor(at: coord) }
            case .windowRoom(let coord):
                return HUDTarget(label: "OPEN", kind: "windowRoomDoor") { [weak self] in self?.openWindowRoomDoor(at: coord) }
            }
        }
        // A numbered room door (mail slot / knock).
        if let door = roomDoors[cell], door.direction == f {
            return HUDTarget(label: door.isDecorative ? "KNOCK" : "MAIL", kind: "roomDoor") { [weak self] in
                self?.interactWithRoomDoor(at: cell)
            }
        }
        // A wall fixture: photo booth or game terminal (still available).
        for resolver in fixtureResolvers where wallInteractionDirection(resolver.kind, at: cell) == f {
            let kind = resolver.kind, activate = resolver.activate
            return HUDTarget(label: kind == .photoBooth ? "PHOTO" : "PLAY", kind: kind.rawValue) { [weak self] in
                self?.composeWallView(kind, at: cell) { activate(cell) }
            }
        }
        // Oct 11: carrying an extinguisher back to the empty bracket it came
        // from -- hang it up again (it is otherwise carried until the floor
        // is left; an accidental TAKE had no way back).
        if carryingExtinguisher, extinguishingFireCoords.isEmpty, !extinguisherPickupInProgress,
           pickedUpExtinguisherCoords.contains(cell), extinguisherCoords[cell] == f {
            return HUDTarget(label: "RETURN", kind: "extinguisherReturn") { [weak self] in _ = self?.returnExtinguisher(at: cell) }
        }
        // The wall extinguisher.
        if let coord = extinguisherAtCurrentCell {
            return HUDTarget(label: "TAKE", kind: "extinguisher") { [weak self] in _ = self?.pickUpExtinguisher(at: coord) }
        }
        let ahead = GridCoordinate(row: cell.row + f.delta.row, col: cell.col + f.delta.col)
        // A live fire, only with the extinguisher in hand (Oct 16: or one from Supplies).
        if carryingExtinguisher || ToolBelt.carries(.extinguisher) {
            for coord in [cell, ahead] where fireCoords.contains(coord) && !extinguishedFireCoords.contains(coord) && canReachFire(at: coord) {
                return HUDTarget(label: "SPRAY", kind: "fire") { [weak self] in _ = self?.extinguishFire(at: coord) }
            }
        }
        // A floor pickup (trash can, paint bucket) in the next cell.
        if let kind = objectKinds[ahead], kind.requiresTapToCollect, !collectedCoords.contains(ahead) {
            return HUDTarget(label: "TAKE", kind: "pickup") { [weak self] in _ = self?.collectByTap(at: ahead) }
        }
        // The player's office computer, from inside the office, facing the desk.
        // Oct 11 (USE fix): offered only when sitting down would actually be
        // accepted -- sitDown also refuses while Mr. Tinky is still doing his
        // goodbye at the desk (GuidedJourney.isPerformingInOffice), and USE
        // used to stay lit then and do nothing at all.
        if floorNumber == PlayerOffice.floor, OfficeComputer.shared.phase == .off, let view = hudSceneView,
           PlayerOffice.officeCells.subtracting(PlayerOffice.deskBayCells).contains(cell),
           OfficeComputer.shared.canSitDown(controller: self, view: view) {
            let desk = PlayerOffice.deskCenter, p = cameraNode.position
            let toDesk = atan2(-Double(desk.x - p.x), -Double(desk.y - p.z))
            if abs(shortestDelta(from: yaw, to: toDesk)) < Self.hudFacingTolerance + 10 * .pi / 180 {
                return HUDTarget(label: "USE", kind: "officeComputer") { [weak self, weak view] in
                    guard let self, let view else { return }
                    _ = OfficeComputer.shared.sitDown(controller: self, view: view)
                }
            }
        }
        return nil
    }

    /// The closed door (if any) across the edge `cell` -> `direction`.
    private func closedDoor(from cell: GridCoordinate, direction: Direction) -> CruiseDoor? {
        if let anchor = roomEntranceDoorAnchor(from: cell, direction: direction), !openRoomEntranceDoors.contains(anchor) {
            return .roomEntrance(anchor)
        }
        if let anchor = bathroomDoorAnchor(from: cell, direction: direction), !openBathroomDoors.contains(anchor) {
            return .bathroom(anchor)
        }
        if let anchor = windowRoomDoorAnchor(from: cell, direction: direction), !openWindowRoomDoors.contains(anchor) {
            return .windowRoom(anchor)
        }
        return nil
    }

    /// Main thread: the walk is closing on a closed door. Ordinary doors open
    /// through their own swing code; a guarded door stays shut (her reaction
    /// plays when the walk stops at it); an intercept (someone answering)
    /// behaves exactly as for a tap.
    private func continuousWalkReachedDoor(_ door: CruiseDoor, session: Int) {
        guard cruiseActive, cruiseSession == session else { return }
        var result = "opened"
        switch door {
        case .roomEntrance(let coord):
            if roomEntranceDoorGuarded?(coord) == true {
                result = "guarded"
                cruiseStopReaction = { [weak self] in self?.guardedRoomEntranceDoorTapped(coord) }
            } else if let intercept = roomEntranceDoorIntercept, intercept(coord) {
                result = "intercepted"
                diag("roomEntranceDoor.intercepted", ["row": coord.row, "col": coord.col])
            } else {
                swingRoomEntranceDoorOpen(at: coord)
            }
        case .bathroom(let coord):
            swingBathroomDoorOpen(at: coord)
        case .windowRoom(let coord):
            swingWindowRoomDoorOpen(at: coord)
        }
        diag("cruise.door", ["door": "\(door)", "result": result])
        guard result == "opened" else { return }
        let fresh = makeFreeWalkGeometry()
        cruiseGeometryLock.lock()
        cruisePendingGeometry = fresh
        cruiseGeometryLock.unlock()
    }

    /// Main thread: the walk has stopped square in front of the elevator.
    private func continuousWalkBoardElevator() {
        guard currentCell == endCell, facing == elevatorMountDirection else {
            diag("cruise.elevator", ["result": "notInFront", "cell": currentCell, "facing": "\(facing)"])
            return
        }
        diag("cruise.elevator", ["result": canReenterArrivedElevator ? "reenter" : "open"])
        if canReenterArrivedElevator { advance(source: "HUD_ENTER") } else { openElevator() }
    }

    /// LEFT/RIGHT in the elevator: the same free look the pan gesture drives
    /// (beginElevatorCameraDrag/endElevatorCameraDrag), as a 90-degree turn.
    private func elevatorHUDPivot(_ turn: ContinuousWalkTurn) {
        if elevatorHUDPivotRunning { pendingHUDPivot = turn; return }
        beginElevatorCameraDrag()
        elevatorHUDPivotRunning = true
        let start = Double(cameraNode.eulerAngles.y)
        let base = start + shortestDelta(from: start, to: nearestCardinal(toYaw: start).yaw)
        let target = base + (turn == .left ? .pi / 2 : -.pi / 2)
        let duration = max(0.12, Self.pivotTurnDuration * abs(target - start) / (.pi / 2))
        let spin = SCNAction.customAction(duration: duration) { node, elapsed in
            let t = min(1, Double(elapsed) / duration)
            node.eulerAngles = SCNVector3(0, Float(start + (target - start) * t * t * (3 - 2 * t)), 0)
        }
        diag("cruise.elevatorPivot", ["turn": "\(turn)"])
        cameraNode.runAction(spin, forKey: Self.elevatorHUDPivotActionKey) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.elevatorHUDPivotRunning else { return }
                self.cameraNode.eulerAngles = SCNVector3(0, Float(target), 0)
                self.elevatorHUDPivotRunning = false
                self.endElevatorCameraDrag()
                if let next = self.pendingHUDPivot {
                    self.pendingHUDPivot = nil
                    self.continuousWalkTurnTapped(next)
                }
            }
        }
    }

    /// LEFT / RIGHT.
    func continuousWalkTurnTapped(_ turn: ContinuousWalkTurn) {
        // Oct 12 (seated look): at the office computer LEFT/RIGHT turn the head.
        if isSeatedAtComputer {
            OfficeComputer.shared.turn(left: turn == .left)
            return
        }
        switch continuousWalkState {
        case .stopped:
            // In the elevator: the cab's own free look, as a quarter turn.
            if isElevatorRideInProgress {
                elevatorHUDPivot(turn)
                return
            }
            // Stationary: the ordinary quarter-turn pivot; nothing queued.
            // Mid-pivot: remember this press; it runs when the turn completes.
            if isAnimating, hudPivotInFlight {
                pendingHUDPivot = turn
                diag("cruise.pivotQueued", ["turn": "\(turn)"])
                return
            }
            let target = turn == .left ? facing.left : facing.right
            // Smart WALK: stopped short of a decision, LEFT/RIGHT toward a way
            // that is open there = walk on and take it (the queued-turn corner).
            if let stop = cruiseDecisionStop,
               hypotf(cameraNode.position.x - stop.x, cameraNode.position.z - stop.z) < 0.3,
               makeFreeWalkGeometry().openEdges.contains(FreeWalkGeometry.Edge(cell: stop.cell, direction: target)) {
                diag("cruise.decisionTurn", ["turn": "\(turn)", "toward": "\(target)", "decision": stop.cell])
                startContinuousWalk()
                if continuousWalkState != .stopped { queueContinuousWalkTurn(turn); return }
                // (Oct 12: GO found no clear way from here -- the press is an ordinary pivot instead.)
                guard continuousWalkBlockReason == nil, canRotate else { return }
            }
            cruiseDecisionStop = nil
            diag("cruise.pivot", ["turn": "\(turn)", "from": "\(facing)", "to": "\(target)"])
            CruiseCornerNote.shared.post("PIVOT on the spot -- standing still, not at a junction stop")   // (Oct 13 diagnostics)
            rotate(toward: target, durationPerQuarterTurn: Self.pivotTurnDuration)
            hudPivotInFlight = isAnimating && phase == .pivot
        case .walking:
            queueContinuousWalkTurn(turn)
        case .walkingQueued(let pending):
            if pending == turn {
                cruiseRequestSerial += 1
                cruiseRequest = nil
                continuousWalkState = .walking
                diag("cruise.turnCancelled", ["turn": "\(turn)"])
            } else {
                queueContinuousWalkTurn(turn)   // last press wins
            }
        }
    }

    private func queueContinuousWalkTurn(_ turn: ContinuousWalkTurn) {
        cruiseRequestSerial += 1
        cruiseRequest = (turn, cruiseRequestSerial)
        continuousWalkState = .walkingQueued(turn)
        diag("cruise.turnQueued", ["turn": "\(turn)", "cell": currentCell, "facing": "\(facing)"])
    }

    func startContinuousWalk() {
        guard Self.continuousWalkExperimentOn, continuousWalkState == .stopped else { return }
        if isWalkLatched { stopWalkLatch(reason: "go") }            // (Oct 16: GO takes over from a latched walk)
        // Oct 11 (late, the cast audition): in the conference room, before
        // the player has sat down, WALK takes them to their chair.
        if ConferenceMeeting.interceptWalk(controller: self) { return }
        pendingHUDPivot = nil
        // A running tap walk ends in place first (same takeover a pinch uses).
        if isFreeTapWalking { takeOverFreeTapWalkForPinch() }
        cruiseRequestSerial += 1
        cruiseRequest = nil
        cruiseStopReaction = nil
        if continuousWalkBlockReason == nil, canRotate {
            beginContinuousWalkMovement()
            return
        }
        // Oct 10 (Floor 2 report): WALK in the arrived cab used to do nothing.
        // Not free YET (in the cab, a walk/turn/glide finishing): show STOP and
        // start the walk the moment movement is the player's again.
        guard continuousWalkCanWaitToStart else {
            diag("cruise.refused", ["reason": continuousWalkBlockReason ?? "busy", "phase": "\(phase)"])
            return
        }
        cruiseSession += 1
        cruiseStartDeadline = Date().addingTimeInterval(Self.cruiseStartWaitLimit)
        continuousWalkState = .walking
        diag("cruise.startPending", ["inCab": elevatorAwaitingEntryDirection != nil, "blocked": continuousWalkBlockReason ?? "busy"])
        scheduleContinuousWalkStartPoll(session: cruiseSession)
    }

    /// Waiting is only for states that end by themselves: the arrived/boarded
    /// cab (WALK steps out) or a walk/turn/composition glide finishing.
    private var continuousWalkCanWaitToStart: Bool {
        if elevatorAwaitingEntryDirection != nil { return true }
        guard let reason = continuousWalkBlockReason else { return true }
        return reason == "wallInteraction"
    }

    private func scheduleContinuousWalkStartPoll(session: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.cruiseSession == session, !self.cruiseActive,
                  self.continuousWalkState != .stopped, let deadline = self.cruiseStartDeadline else { return }
            if Date() > deadline {
                self.stopContinuousWalk(reason: "startTimedOut")
                return
            }
            if self.elevatorAwaitingEntryDirection != nil {
                // Step out through the existing walk-out (what a tap through
                // the doorway does), then walk on from the landing.
                if self.canStartElevatorExit, !self.isAnimating {
                    diag("cruise.exitCab")
                    self.advance(source: "HUD_EXIT")
                }
                self.scheduleContinuousWalkStartPoll(session: session)
                return
            }
            if self.continuousWalkBlockReason == nil, self.canRotate {
                self.beginContinuousWalkMovement(preservingRequest: true)
                return
            }
            guard self.continuousWalkCanWaitToStart else {
                self.stopContinuousWalk(reason: "startBlocked:" + (self.continuousWalkBlockReason ?? "?"))
                return
            }
            self.scheduleContinuousWalkStartPoll(session: session)
        }
    }

    /// The walk itself (movement is free right now).
    private func beginContinuousWalkMovement(preservingRequest: Bool = false) {
        cruiseStartDeadline = nil
        freeWalkGeometry = makeFreeWalkGeometry()
        let position = cameraNode.position
        freeWalkCell = freeWalkGeometry?.containingCell(x: Double(position.x), z: Double(position.z), previous: currentCell) ?? currentCell
        // Oct 12 (playtest: GO at an angle to a wall only nudged the view a few
        // degrees, again and again): which way GO goes is decided HERE, from the
        // corridor around the player -- not just the nearest compass direction
        // of the camera, which can be the wall itself.
        let startYaw = Double(cameraNode.eulerAngles.y)
        adminGoRoute = makeAdminGoRoute()                            // Oct 13: after the ID, GO goes to Tinky
        guard let startHeading = continuousWalkStartHeading(yaw: startYaw) else {
            if continuousWalkState != .stopped { continuousWalkState = .stopped }
            return                                                  // (any settle glide in flight finishes as it was)
        }
        cameraNode.removeAction(forKey: Self.freeLookAlignActionKey)
        freeMoveHeld = false
        freeTapWalkActive = false
        manualFootstepsFromAutoWalk = false
        cruiseSession += 1
        if preservingRequest, cruiseRequest != nil {
            cruiseConsumedSerial = -1                      // a turn queued while waiting stays live
        } else {
            cruiseRequestSerial += 1
            cruiseRequest = nil
            cruiseConsumedSerial = cruiseRequestSerial
        }
        cruiseArc = nil
        cruiseSpeed = 0
        cruiseDistance = 0
        cruiseStall = 0
        cruiseBumped = false
        var skip: Set<GridCoordinate> = [freeWalkCell]
        if let stop = cruiseDecisionStop,
           hypotf(cameraNode.position.x - stop.x, cameraNode.position.z - stop.z) < 0.3 { skip.insert(stop.cell) }
        cruiseDecisionSkip = skip
        cruiseDecisionStop = nil
        cruiseWalkAfterPivot = false
        cruiseStartCell = freeWalkCell
        cruiseGuidance = makeCruiseGuidance()
        cruiseGeometryLock.lock()
        cruisePendingGuidance = nil
        cruiseGeometryLock.unlock()
        cruiseDoorRequested = nil
        cruiseClock = 0
        cruiseGentleUntil = 0                                       // (Oct 13)
        smoothVeto = nil
        cruiseDoorSlowUntil = 0
        cruiseStopReaction = nil
        let yaw = startYaw
        cruiseHeadingYaw = yaw + shortestDelta(from: yaw, to: startHeading.yaw)
        if abs(cruiseHeadingYaw - yaw) > Self.cruiseAlignInPlace {   // (Oct 13 diagnostics)
            CruiseCornerNote.shared.post("PIVOT -- GO turning onto the corridor before walking")
        }
        lastCruiseHeading = startHeading
        cruiseActive = true
        phase = .freeMove
        isAnimating = true
        if let request = cruiseRequest, cruiseConsumedSerial == -1 {
            continuousWalkState = .walkingQueued(request.turn)
        } else {
            continuousWalkState = .walking
        }
        diag("cruise.start", ["cell": currentCell, "heading": "\(startHeading)", "viewHeading": "\(nearestCardinal(toYaw: yaw))"])
        scheduleContinuousWalkWatch(session: cruiseSession)
    }

    // MARK: Oct 13 -- GO after the ID card (Administration, Floor 2)
    //
    // Once the card has been taken (Admission.isCompleted) and before Tinky's
    // part of the prologue (his desk encounter still to come, no journey yet),
    // GO from the reception floor walks the player to him: the room's own
    // route finder (CharacterLead.route, the one the characters use) gives the
    // cells from here to the spot in front of his desk; the walk follows it as
    // it follows an escort's route (its corners, the office door opened by the
    // walk's own door handling), turning the player round first if they face
    // the kiosk; it ends on his desk's landing (capsApproach), which starts
    // his encounter exactly as walking up to him does. Anything else: nil, GO
    // as before.
    private var adminGoRoute: [GridCoordinate]?

    // MARK: Oct 15 -- Smart Tap entry points (ContentView's tap handler)

    /// Smart Tap: walk to Tinky's desk along the room's route (the GO
    /// behaviour above), when that route exists right now. True = walking.
    func smartTapWalkToTinky() -> Bool {
        guard continuousWalkState == .stopped else { return false }
        cruiseDecisionStop = nil                                    // (an explicit request: no old junction stop applies)
        guard makeAdminGoRoute() != nil else { return false }
        startContinuousWalk()
        return continuousWalkState != .stopped
    }

    /// Smart Tap: follow the escorting character (the escort walk WALK used
    /// to start: his route, his pace, never overtaking). True = walking.
    func smartTapFollowGuide() -> Bool {
        guard continuousWalkState == .stopped, CharacterLead.activeGuidedRoute != nil else { return false }
        startContinuousWalk()
        return continuousWalkState != .stopped
    }

    // MARK: Oct 20 -- following a critter (CritterFollow.swift)

    /// While a critter is followed: the way to it from here (cells) and where it
    /// stands (nil: heading for the elevator after it). Read on the main thread.
    var followGuidance: (() -> (route: [GridCoordinate], leader: SIMD2<Float>?)?)?

    /// The walk the escort uses, toward the followed critter. True = walking.
    func startFollowWalk() -> Bool {
        guard continuousWalkState == .stopped, followGuidance?() != nil else { return false }
        startContinuousWalk()
        return continuousWalkState != .stopped
    }

    /// The player is steering by hand (a tap walk, a held or latched walk, a drag):
    /// following lets go.
    var playerIsSteering: Bool {
        isFreeTapWalking || freeMoveHeld || walkingHeld || isWalkLatched || isDragMoving        // (looking around is not steering)
    }

    /// The direction the walk is going now (while walking). Oct 20 (later): the
    /// walk's OWN heading (set as it starts, updated at each corner) -- not the
    /// camera, which lags behind while the walk turns onto its way.
    var walkHeading: Direction {
        if cruiseActive, let h = lastCruiseHeading { return h }
        return nearestCardinal(toYaw: Double(cameraNode.eulerAngles.y))
    }

    /// In the cab with the doors open: the panel's button for `floor`, pressed
    /// as a tap on it would be -- the ID reader and all. True: departing.
    @discardableResult
    func pressElevatorFloorForFollow(_ floor: Int) -> Bool {
        guard elevatorDoorsOpenIdle, floor != floorNumber, elevatorReachableFloors.contains(floor),
              let cap = scene?.rootNode.childNode(withName: "elevatorControlButton_\(floor)", recursively: true) else { return false }
        cap.removeAction(forKey: "press")
        cap.runAction(.sequence([.moveBy(x: 0, y: 0, z: 0.006, duration: 0.06),
                                 .moveBy(x: 0, y: 0, z: -0.006, duration: 0.14)]), forKey: "press")
        ElevatorRideSound.click(on: cameraNode)
        guard readEmployeeID(forFloor: floor, doors: "open") else { return false }      // (refused: as a tap would be)
        let lit = HallwayScene.ElevatorButtonLook.selected()          // Oct 25: the one shared look
        cap.geometry?.materials = [lit]
        cameraNode.removeAction(forKey: Self.elevatorPanelApproachActionKey)
        diag("elevator.button.pressed", ["from": floorNumber, "to": floor, "doors": "open", "by": "follow"])
        RocketElevator.markDeparture(from: floorNumber, to: floor)
        closeWhenDoorwayClear(departTo: floor)
        return true
    }

    /// Out of an arrived cab (the doors open) -- the same walk out a tap makes. True: stepping out.
    @discardableResult
    func stepOutOfElevatorForFollow() -> Bool {
        guard canStartElevatorExit, !isAnimating, elevatorAwaitingEntryDirection != nil else { return false }
        performElevatorEntryWalkOut()
        return true
    }

    /// Oct 15 (direct interactions): a tap on the elevator's doors or call
    /// panel from down the hall -- glide into the elevator's cell (the same
    /// collision-slid glide a tap on any door makes), then exactly what a tap
    /// there does: step back into an arrived cab, or open the doors (all of
    /// openElevator's own checks: mission, ID, busy). A glide cut short
    /// (round a corner) just ends there -- the elevator refuses, nothing else.
    /// Oct 22 (hall call): then what a tap there does now -- `button` (+1 up, -1
    /// down) pressed: that call; the doors: the call buttons framed (no call).
    func approachElevatorAndOpen(button: Int? = nil) -> Bool {
        guard currentCell != endCell, let mount = elevatorMountDirection, canRotate, !elevatorInUse else { return false }
        let c = worldPosition(for: endCell)
        return beginWallComposition(kind: "elevatorApproach", face: WallFace(coord: endCell, direction: mount),
                                    at: SCNVector3(c.x, cameraNode.position.y, c.z)) { [weak self] in
            guard let self else { return }
            self.tapElevatorExterior(button: button)
        }
    }

    /// Oct 15: glide to `position`, turning to `yaw` on the way (the short way
    /// round), then run `interact` -- the door/kiosk landing's own glide, for
    /// a pose that isn't square to a wall (the office filing cabinet).
    @discardableResult
    func approachPose(kind: String, position: SCNVector3, yaw: Double, then interact: @escaping () -> Void) -> Bool {
        guard canRotate else { return false }
        let start = cameraNode.position
        let startYaw = Double(cameraNode.eulerAngles.y)
        let targetYaw = startYaw + shortestDelta(from: startYaw, to: yaw)
        let dx = Double(position.x - start.x), dz = Double(position.z - start.z)
        let distance = (dx * dx + dz * dz).squareRoot()
        if distance < 0.05 && abs(targetYaw - startYaw) < 0.05 { interact(); return true }
        beginFreeWalkTap(travelDirection: distance > 1e-6 ? (dx / distance, dz / distance) : nil,
                         travelDistance: distance, finalYaw: targetYaw, turnAcrossWholeGlide: true)
        guard freeTapWalkActive else { return false }
        pendingWallInteraction = (kind, targetYaw, interact)
        return true
    }

    /// Where the landing `kind` would put the player (nil: no such spot now).
    func landingSpotPosition(_ kind: String) -> SCNVector3? {
        guard let spot = landingSpots.first(where: { $0.kind == kind && ($0.isAvailable?() ?? true) }) else { return nil }
        return landingPosition(spot)
    }

    private func makeAdminGoRoute() -> [GridCoordinate]? {
        // Oct 21 (one tap, one walk): an Administration walk asked for by a tap or the card.
        if let walk = adminWalk { return makeAdminWalkRoute(walk) }
        guard cruiseDecisionStop == nil,                            // (a LEFT/RIGHT from a junction stop is the player's)
              currentFloorNumber == AdministrationReception.floor, Admission.isCompleted, !Admission.isPrologueCompleted,
              GuidedJourney.trip == nil, CharacterLead.activeGuidedRoute == nil, FredOfficeEncounter.isAvailable else { return nil }
        let goal = FredOfficeEncounter.landing.coord
        let here = currentCell
        let area = AdministrationExitGuard.receptionCells.union([AdministrationReception.officeDoorCell, AdministrationReception.officeAnteroom])
        guard here != goal, area.contains(here), let context = FredLead.context ?? GuidedJourney.context,
              let route = CharacterLead.route(from: here, to: goal, cells: context.cells, doors: context.doors), route.count >= 2 else {
            return nil
        }
        diag("cruise.adminRoute", ["from": here, "to": goal, "cells": route.count])
        // Oct 19: no on-screen "to Tinky's desk (n cells)" any more -- the route is
        // unchanged; the distance stays in the diagnostics line above.

        return route
    }

    // MARK: Oct 21 -- ONE TAP, ONE WALK (Administration)
    //
    // Two walks the onboarding needs, both the continuous walk on a room route
    // (the admin GO route's own machinery: the arrived cab stepped out of, the
    // glass or office door opened by the walk's own door handling, the corners
    // smooth, stopped exactly on a capped pose, any tap or drag stops it and
    // nothing ever resumes it):
    //   .toJuanita     a tap on the Administration glass doors from the elevator
    //                  or the vestibule (before the ID) -- out of the cab, through
    //                  the doors as they open, and on to her counter's pose (the
    //                  receptionDesk landing: capsApproach -- the walk stops ON it;
    //                  her greeting runs as for any arrival there).
    //   .towardTinky   1.5 s after the ID card is taken (the player still at the
    //                  kiosk, untouched): round, through the office door, and stop
    //                  in the anteroom with Tinky ahead at his desk -- never his
    //                  desk landing (that's the player's next tap).
    enum AdminWalk: Equatable { case toJuanita, towardTinky }
    private(set) var adminWalk: AdminWalk?
    /// The pending card-taken walk's token (a newer request, or any input, voids it).
    private var adminWalkToken = 0
    /// Where the walk toward Tinky stops: the anteroom, facing his office.
    static let towardTinkyStop = WallFace(coord: AdministrationReception.officeAnteroom, direction: .south)

    private func makeAdminWalkRoute(_ walk: AdminWalk) -> [GridCoordinate]? {
        guard currentFloorNumber == AdministrationReception.floor, GuidedJourney.trip == nil, CharacterLead.activeGuidedRoute == nil,
              let context = FredLead.context ?? GuidedJourney.context else { return nil }
        let goal: GridCoordinate
        let area: Set<GridCoordinate>
        switch walk {
        case .toJuanita:
            guard !Admission.isCompleted else { return nil }
            goal = AdministrationReception.deskLanding.coord
            area = AdministrationExitGuard.receptionCells.union([endCell, GridCoordinate(row: endCell.row, col: endCell.col + 1)])
        case .towardTinky:
            guard Admission.isCompleted, !Admission.isPrologueCompleted, FredOfficeEncounter.isAvailable else { return nil }
            goal = Self.towardTinkyStop.coord
            area = AdministrationExitGuard.receptionCells.union([AdministrationReception.officeDoorCell])
        }
        let here = currentCell
        guard here != goal, area.contains(here),
              let route = CharacterLead.route(from: here, to: goal, cells: context.cells, doors: context.doors), route.count >= 2 else {
            return nil
        }
        diag("cruise.adminWalkRoute", ["walk": "\(walk)", "from": here, "to": goal, "cells": route.count])
        return route
    }

    /// A tap on the Administration glass doors from the elevator side: the whole
    /// way to Juanita, in one walk. True: walking (or about to: stepping out of the cab first).
    @discardableResult
    func startAdminWalk(_ walk: AdminWalk) -> Bool {
        guard continuousWalkState == .stopped, !isAnimating || elevatorAwaitingEntryDirection != nil else { return false }
        adminWalkToken += 1
        adminWalk = walk
        cruiseDecisionStop = nil                                    // (an explicit request: no old junction stop applies)
        guard makeAdminWalkRoute(walk) != nil || (walk == .toJuanita && elevatorAwaitingEntryDirection != nil) else {
            adminWalk = nil
            return false
        }
        startContinuousWalk()
        if continuousWalkState == .stopped { adminWalk = nil; return false }
        diag("adminWalk.start", ["walk": "\(walk)", "cell": currentCell, "inCab": elevatorAwaitingEntryDirection != nil])
        return true
    }

    /// The ID card was just taken: in `delay` seconds -- if the player is still
    /// standing at the kiosk, hands off -- round and on toward Tinky's office.
    func scheduleWalkTowardTinky(after delay: TimeInterval) {
        adminWalkToken += 1
        let token = adminWalkToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.adminWalkToken == token else { return }
            guard self.currentFloorNumber == AdministrationReception.floor, Admission.isCompleted, !Admission.isPrologueCompleted,
                  FredOfficeEncounter.isAvailable, GuidedJourney.trip == nil,
                  self.isInLandingPose(AdministrationIDTerminal.landingKind),       // (still there: no step, no turn meanwhile)
                  !self.isAnimating, self.continuousWalkState == .stopped, self.activeTouchGesture?() == nil else {
                diag("adminWalk.towardTinky.skipped", ["cell": self.currentCell])
                return
            }
            self.startAdminWalk(.towardTinky)
        }
    }

    /// Is there a capped landing pose (Juanita's counter...) along `direction`
    /// within `distance` of where the player stands? (A tap that way then walks to
    /// it and stops on it -- never past it and back.)
    func cappedLandingAhead(direction: (x: Double, z: Double)?, distance: Double?) -> Bool {
        guard let direction, let distance else { return false }
        return approachCap(from: cameraNode.position, forward: direction, requested: distance + 0.5) != nil
    }

    /// Oct 12 (playtest): the way the last walk went (its start, or the
    /// corridor a corner turned into) -- "recent travel" for GO's choice.
    private var lastCruiseHeading: Direction?
    /// Oct 12: a walk that starts this far (radians) off its corridor turns
    /// on the spot first, then walks (never a slide along a wall).
    static let cruiseAlignInPlace: Double = 0.45
    /// Oct 12: two side corridors whose angles from the view differ by less
    /// than this are a genuine tie (the view square on to the wall).
    static let cruiseHeadingTie: Double = 15 * .pi / 180

    /// Oct 12 (playtest: GO angled at a wall). Which way GO walks, from the
    /// view and the walkable ways out of the player's cell:
    ///  - the compass direction nearest the view, when that way is open (as before);
    ///  - else (the view is on a wall), the side corridor nearest the view:
    ///    one open side -> that one; both -> the one the view leans to; a
    ///    genuine tie (the view square on to the wall) -> the way the player
    ///    was last walking, if it is one of them; otherwise no walk at all
    ///    (nil -- GO does nothing; LEFT/RIGHT or a swipe choose).
    ///  - no side open either (a real dead end ahead): as before (the walk
    ///    finds the dead end and stops).
    /// Never the way back behind the player.
    private func continuousWalkStartHeading(yaw: Double) -> Direction? {
        let viewHeading = nearestCardinal(toYaw: yaw)
        guard let g = freeWalkGeometry else { return viewHeading }
        let cell = freeWalkCell
        // Oct 13: GO's route to Tinky's desk (after the ID): its first step,
        // whichever way the player happens to face -- turning round if need be.
        if let route = adminGoRoute, let i = route.firstIndex(of: cell), i + 1 < route.count {
            let next = route[i + 1]
            if let d = Direction.allCases.first(where: { $0.delta.row == next.row - cell.row && $0.delta.col == next.col - cell.col }) {
                diag("cruise.heading", ["cell": cell, "view": "\(viewHeading)", "chosen": "\(d)", "why": "adminRouteToTinky"])
                return d
            }
        }
        // Oct 20 (following a critter): its way from here, whichever way the
        // player faces -- turning round if need be (as GO's route to Tinky).
        if CharacterLead.activeGuidedRoute == nil, let route = followGuidance?()?.route,
           let i = route.firstIndex(of: cell), i + 1 < route.count {
            let next = route[i + 1]
            if let d = Direction.allCases.first(where: { $0.delta.row == next.row - cell.row && $0.delta.col == next.col - cell.col }) {
                diag("cruise.heading", ["cell": cell, "view": "\(viewHeading)", "chosen": "\(d)", "why": "followingCritter"])
                return d
            }
        }
        func open(_ d: Direction) -> Bool { g.openEdges.contains(FreeWalkGeometry.Edge(cell: cell, direction: d)) }
        if open(viewHeading) { return viewHeading }
        let sides = [viewHeading.left, viewHeading.right].filter(open)
        // Following an escort: the way the guide's route goes on, if it is one of them.
        if let onward = makeCruiseGuidance().routeOnward?[cell], sides.contains(onward) {
            diag("cruise.heading", ["cell": cell, "view": "\(viewHeading)", "chosen": "\(onward)", "why": "escortRoute"])
            return onward
        }
        var choice: Direction?
        var why = ""
        switch sides.count {
        case 0:
            choice = viewHeading; why = "deadEnd"
        case 1:
            choice = sides[0]; why = "onlyWayOn"
        default:
            let a = abs(shortestDelta(from: yaw, to: sides[0].yaw)), b = abs(shortestDelta(from: yaw, to: sides[1].yaw))
            if abs(a - b) >= Self.cruiseHeadingTie {
                choice = a < b ? sides[0] : sides[1]; why = "viewLeans"
            } else if let last = lastCruiseHeading, sides.contains(last) {
                choice = last; why = "recentTravel"
            } else {
                choice = nil; why = "tie"
            }
        }
        diag("cruise.heading", ["cell": cell, "view": "\(viewHeading)", "chosen": choice.map { "\($0)" } ?? "none", "why": why,
                                "offBy": Int((abs(shortestDelta(from: yaw, to: (choice ?? viewHeading).yaw)) * 180 / .pi).rounded())])
        return choice
    }

    /// Ends the walk NOW, in place (main thread). A turn in progress settles
    /// onto its new cardinal heading over a short glide so the view never
    /// rests between corridors. Safe to call when nothing is running.
    func stopContinuousWalk(reason: String) {
        if reason != "stopButton" { pendingHUDPivot = nil }
        adminGoRoute = nil                                          // (Oct 13)
        if adminWalk != nil { diag("adminWalk.end", ["walk": "\(adminWalk!)", "why": reason]) }
        adminWalk = nil                                             // (Oct 21: never resumed)
        let wasActive = cruiseActive
        cruiseActive = false
        cruiseSession += 1
        cruiseRequestSerial += 1
        cruiseRequest = nil
        cruiseStartDeadline = nil
        cruiseStopReaction = nil
        if continuousWalkState != .stopped { continuousWalkState = .stopped }
        guard wasActive else { return }
        let arc = cruiseArc
        cruiseArc = nil
        cruiseSpeed = 0
        if phase == .freeMove, !freeMoveHeld, !freeTapWalkActive {
            isAnimating = false
            phase = .translate
            freeWalkFootstepsOn = false
            freeWalkFootstepsReverse = false
            SoundEffects.stopWalking()
            movementPace = 1
            SoundEffects.setWalkingPace(1)
            if let arc {
                CruiseCornerNote.shared.post("curve INTERRUPTED (\(reason))")    // (Oct 12 diagnostics)
                // Mid-corner: finish the rotation (position is already legal).
                // (Oct 12: a little longer for more of a wide corner still to turn.)
                // (Oct 13: stopped part way round a SMOOTH corner -- settle onto
                // whichever corridor the view is nearer, from where the body is.)
                let current = Double(cameraNode.eulerAngles.y)
                let settleHeading = arc.smooth != nil ? nearestCardinal(toYaw: current) : arc.endHeading
                let settleYaw = arc.smooth != nil ? current + shortestDelta(from: current, to: settleHeading.yaw) : arc.endYaw
                let left = abs(settleYaw - current)
                let settle = SCNAction.rotateTo(x: 0, y: CGFloat(settleYaw), z: 0, duration: 0.18 + 0.2 * min(1, left / (.pi / 2)),
                                                usesShortestUnitArc: true)
                settle.timingMode = .easeOut
                cameraNode.runAction(settle, forKey: Self.freeLookAlignActionKey)
                if facing != settleHeading { facing = settleHeading }
            } else {
                // Oct 12: stopped while still turning on the spot (GO from an angled
                // view): finish onto the corridor it chose, never left at an angle.
                let current = Double(cameraNode.eulerAngles.y)
                let heading = abs(cruiseHeadingYaw - current) > 0.02 ? nearestCardinal(toYaw: cruiseHeadingYaw)
                                                                     : nearestCardinal(toYaw: current)
                if abs(cruiseHeadingYaw - current) > 0.02 {
                    let settle = SCNAction.rotateTo(x: 0, y: CGFloat(current + shortestDelta(from: current, to: heading.yaw)), z: 0,
                                                    duration: 0.18, usesShortestUnitArc: true)
                    settle.timingMode = .easeOut
                    cameraNode.runAction(settle, forKey: Self.freeLookAlignActionKey)
                }
                if facing != heading { facing = heading }
            }
        }
        diag("cruise.stop", ["reason": reason, "cell": currentCell, "facing": "\(facing)", "midTurn": arc != nil])
    }

    /// Main-thread watchdog while walking: anything that takes movement away
    /// (elevator, interaction, script, gesture, computer...) ends the walk;
    /// doors and characters that change while walking are picked up here.
    private func scheduleContinuousWalkWatch(session: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.cruiseActive, self.cruiseSession == session else { return }
            if let reason = self.continuousWalkBlockReason {
                self.stopContinuousWalk(reason: reason)
                return
            }
            guard self.isAnimating, self.phase == .freeMove else {
                self.stopContinuousWalk(reason: "movementTakenOver")
                return
            }
            // Oct 21 (TEST ONLY, -HallwaysPerfSlowCruiseRebuild YES): rebuild once a
            // second instead of every pass. Off: every pass, exactly as before.
            self.cruiseWatchPasses += 1
            if !PerfSwitches.slowCruiseRebuild || self.cruiseWatchPasses % 7 == 0 {
                let fresh = self.makeFreeWalkGeometry()
                let guidance = self.makeCruiseGuidance()
                self.cruiseGeometryLock.lock()
                self.cruisePendingGeometry = fresh
                self.cruisePendingGuidance = guidance
                self.cruiseGeometryLock.unlock()
            }
            self.scheduleContinuousWalkWatch(session: session)
        }
    }

    /// Render thread: the walk ends by itself (dead end / blocked).
    private func endContinuousWalkFromRenderer(reason: String, then follow: (() -> Void)? = nil) {
        let session = cruiseSession
        cruiseActive = false
        cruiseArc = nil
        cruiseSpeed = 0
        finishFreeMove()
        // Queued after finishFreeMove's own main-thread completion, so the
        // player is stopped (isAnimating false, facing settled) when it runs.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.cruiseSession == session else { return }
            self.cruiseRequestSerial += 1
            self.cruiseRequest = nil
            if self.continuousWalkState != .stopped { self.continuousWalkState = .stopped }
            if self.adminWalk != nil { diag("adminWalk.end", ["walk": "\(self.adminWalk!)", "why": reason]) }
            self.adminWalk = nil                                    // (Oct 21: the walk is over -- arrived or stopped)
            self.adminGoRoute = nil
            diag("cruise.stop", ["reason": reason, "cell": self.currentCell, "facing": "\(self.facing)"])
            let reaction = follow ?? self.cruiseStopReaction
            self.cruiseStopReaction = nil
            reaction?()
        }
    }

    private static func unit(_ d: Direction) -> (x: Double, z: Double) {
        (Double(d.delta.col), Double(d.delta.row))
    }

    /// Distances (along `heading`, from `x,z`) to the end of the straight
    /// corridor ahead (stopped at wall clearance) and to the entry point of
    /// the first `side` opening whose entry point is still ahead.
    // MARK: Oct 12 -- WIDE AUTOMATIC CORNERS
    //
    // An AUTOMATIC corner (a corridor's only way on -- never a turn the player
    // queued, never a decision, never an escort's turn: the guide walks ~1.7 m
    // ahead and would be in the way of a wide arc) is walked as
    // a wider quarter circle at close to walking pace, instead of the tight
    // 0.34 m / 0.3 s whip the queued turns use:
    //   radius  up to cruiseAutoTurnRadius, and never more than the distance
    //           still ahead to the corner cell's centre (so a walk that starts
    //           close to a corner still takes it -- just tighter);
    //   speed   cruiseAutoTurnPaceFactor x the walking speed;
    //   view    eased along the arc (smoothstep), so turning in and out of the
    //           corner has no jolt in the rate of turn.
    // The whole arc lies inside the corner cell (radius < half a cell): from R
    // before its centre on the corridor's centreline to R along the new one.
    // Inside that cell its closed sides are never approached (the arc stays on
    // the open sides of both centrelines) and its distance from the inner
    // wall corner is >= sqrt(2h^2 - 2hR + R^2) >= h (h = half a cell = 1.76 m),
    // above the 1.4 m clearance -- and every step still goes through
    // slideEndpoint, the stall check and freeWalkTrackCell (cell events) as
    // before. Not widened (the old radius): a doorway on the way out, or the
    // elevator cell. A corner too close to widen fully gets what fits, and
    // never takes less than cruiseAutoTurnMinTime to turn.
    static let cruiseAutoTurnRadius: Double = 1.2
    static let cruiseAutoTurnPaceFactor: Double = 0.65
    static let cruiseAutoTurnMinTime: Double = 0.4

    /// Render thread: the radius for an automatic corner at `cell` turning to `side`,
    /// `base` metres ahead (to the cell's centre). `radius` = the tight one.
    private func autoCornerRadius(cell: GridCoordinate, side: Direction, base: Double, radius: Double) -> Double {
        // (Oct 12, curve diagnostics: why a corner stays tight is kept for the note.)
        guard let g = freeWalkGeometry else { autoCornerWhy = "no geometry"; return radius }
        guard base >= radius - 1e-6 else { autoCornerWhy = "too close to the corner to curve"; return radius }
        let wide = min(Self.cruiseAutoTurnRadius, g.cellSize / 2 - 0.3)
        guard wide > radius else { autoCornerWhy = "cells too small"; return radius }
        // Exclusions: doors on the way out, the elevator.
        if cell == endCell { autoCornerWhy = "elevator cell"; return radius }
        if roomEntranceDoorAnchor(from: cell, direction: side) != nil || bathroomDoorAnchor(from: cell, direction: side) != nil
            || windowRoomDoorAnchor(from: cell, direction: side) != nil { autoCornerWhy = "doorway on the way out"; return radius }
        let r = max(radius, min(wide, base))
        autoCornerWhy = r < wide - 0.01 ? String(format: "only %.2f m to the corner", base) : ""
        return r
    }
    /// Render thread (Oct 12 diagnostics): why the last automatic corner got the radius it did.
    private var autoCornerWhy = ""

    private struct CruiseScan {
        var stop: Double = .infinity       // distance to where the walk must stop
        var turn: Double?                  // distance to a corner's entry point
        var turnSide: Direction?
        var turnFromRequest = false        // queued by the player (else a forced L)
        var door: CruiseDoor?              // closed door ending the straight run
        var elevator = false               // the run ends square at the elevator
        var decision = false               // Smart WALK: `stop` is just short of a decision
        var decisionCell: GridCoordinate?
        var routeTurn = false              // the turn follows an escort's route
        var turnRadius: Double = 0         // Oct 12: the corner's radius (wide for automatic corners)
        var turnNote = ""                  // Oct 12 (diagnostics): why that radius
        var turnCell: GridCoordinate?      // Oct 13: the cell the corner turns in
        var smooth: SmoothTurn?            // Oct 13: the smooth path planned for it (nil = an arc)
    }

    // MARK: Oct 13 -- SMOOTH CORNERS ("make corner turns feel like walking")
    //
    // A corner the walk takes while MOVING -- an automatic L-corner, an escort's
    // turn, or a LEFT/RIGHT the player chose (while walking, or from a junction
    // stop) -- follows a curvature-continuous path instead of a quarter circle:
    // a quintic Bezier whose first three control points lie on the corridor
    // it leaves and last three on the one it joins. So the path
    //   - leaves the old corridor exactly along it, with zero curvature, and
    //     joins the new one the same way: the rate of turn grows from 0 and
    //     falls back to 0 (no jolt at either end);
    //   - begins up to 3 m before the corner cell's centre and ends up to 3 m
    //     down the new corridor (less when a corner or junction follows at
    //     once, or the player is closer than that);
    //   - and the view is the path's own tangent all the way -- it looks where
    //     it is going, never ahead to the destination heading.
    // The pace through it is steady: what keeps the turn rate at or under
    // smoothTurnMaxRate (~92 deg/s) at the tightest point, between
    // smoothTurnMinSpeed and the walking speed; the walk eases down to it
    // early (smoothTurnBrake, half the ordinary brake) and back up gently
    // after (smoothTurnExitAccel).
    // SAFETY: every point of the planned path (80 samples) must pass the
    // walk's own collision rule (FreeWalkGeometry.isLegal: the 1.4 m wall
    // clearance, the rounded inner corner, missing cells, closed doors, the
    // characters' keep-outs) or a shorter one is tried, and failing all of
    // them the corner is the old quarter circle. Every step along it still
    // goes through slideEndpoint, the stall check and freeWalkTrackCell (cell
    // events). Not smoothed: a doorway on the way out of the corner, the
    // elevator cell. (Model of an L-corner in these 3.52 m cells: entry 3 m ->
    // tightest radius 2.2 m, 3.6 m/s, 4.9 m path, 1.4 s.)
    struct SmoothTurn {
        var xs: [Double] = [], zs: [Double] = [], cum: [Double] = [], yaws: [Double] = []
        var length: Double = 0
        var minRadius: Double = .infinity
        var speed: Double = 0
        var entry: Double = 0
    }
    static let smoothTurnEntries: [Double] = [3.0, 2.6, 2.2, 1.8, 1.4]
    static let smoothTurnMaxRate: Double = 1.6           // rad/s at the tightest point
    static let smoothTurnMinSpeed: Double = 2.2
    static let smoothTurnBrake: Double = 5
    static let smoothTurnExitAccel: Double = 4
    /// After a smooth corner, the walk picks up its pace gently until then (walk clock).
    private var cruiseGentleUntil: Double = 0

    /// Render thread: a smooth path from (sx, sz) -- on the corridor along
    /// `heading`, before `cell`'s centre -- turning into `side`, or nil if it
    /// would not be legal everywhere.
    private func planSmoothTurn(_ g: FreeWalkGeometry, sx: Double, sz: Double, cell: GridCoordinate,
                                heading: Direction, side: Direction, startYaw: Double) -> SmoothTurn? {
        let u = Self.unit(heading), s = Self.unit(side)
        let cx = Double(cell.col) * g.cellSize, cz = Double(cell.row) * g.cellSize
        let dIn = -((sx - cx) * u.x + (sz - cz) * u.z)                // how far before the centre it starts
        guard dIn >= (Self.smoothTurnEntries.last ?? 1.4) - 0.05 else { return nil }
        // The new corridor must go straight on through the next cell (a plain
        // two-way passage, no door, not the elevator): the path ends up to 3 m
        // down it, and the walk's own look-ahead (junction stops, doors,
        // corners) takes over from there with room to spare. A junction,
        // corner or door right after the corner: no smooth path (the walk
        // must still see and stop for it) -- the quarter circle instead.
        let after = GridCoordinate(row: cell.row + side.delta.row, col: cell.col + side.delta.col)
        let afterOpen = Direction.allCases.filter { g.openEdges.contains(FreeWalkGeometry.Edge(cell: after, direction: $0)) }
        guard after != endCell, afterOpen.count == 2, afterOpen.contains(side), afterOpen.contains(side.opposite),
              roomEntranceDoorAnchor(from: after, direction: side) == nil, bathroomDoorAnchor(from: after, direction: side) == nil,
              windowRoomDoorAnchor(from: after, direction: side) == nil else {
            smoothWhy = "a junction, corner or door right after it"
            return nil
        }
        // A landing stop (a counter, a desk) on the curve's cells would be missed: not here.
        let before = GridCoordinate(row: cell.row - heading.delta.row, col: cell.col - heading.delta.col)
        if cruiseGuidance.landingCaps.contains(where: { [before, cell, after].contains($0.cell) }) {
            smoothWhy = "a stop point on the corner"
            return nil
        }
        // A doorway on the way INTO the corner cell, crossed while already turning: not here.
        if dIn > g.cellSize / 2,
           roomEntranceDoorAnchor(from: cell, direction: heading.opposite) != nil || bathroomDoorAnchor(from: cell, direction: heading.opposite) != nil
            || windowRoomDoorAnchor(from: cell, direction: heading.opposite) != nil {
            smoothWhy = "a doorway just before the corner"
            return nil
        }
        let dOut = min(dIn, Self.smoothTurnEntries.first ?? 3)
        let ex = cx + s.x * dOut, ez = cz + s.z * dOut
        let px: [Double] = [sx, sx + u.x * dIn / 3, sx + u.x * 2 * dIn / 3, ex - s.x * 2 * dOut / 3, ex - s.x * dOut / 3, ex]
        let pz: [Double] = [sz, sz + u.z * dIn / 3, sz + u.z * 2 * dIn / 3, ez - s.z * 2 * dOut / 3, ez - s.z * dOut / 3, ez]
        let binom: [Double] = [1, 5, 10, 10, 5, 1]
        let n = 80
        var t = SmoothTurn()
        t.entry = dIn
        for i in 0...n {
            let k = Double(i) / Double(n)
            var x = 0.0, z = 0.0
            for j in 0...5 {
                let w = binom[j] * pow(1 - k, Double(5 - j)) * pow(k, Double(j))
                x += w * px[j]; z += w * pz[j]
            }
            if i > 0, !g.isLegal(x: x, z: z) { return nil }
            t.xs.append(x); t.zs.append(z)
        }
        // Lengths, and the view: the path's own tangent (unwrapped from the start).
        t.cum = [0]
        for i in 1...n { t.cum.append(t.cum[i - 1] + hypot(t.xs[i] - t.xs[i - 1], t.zs[i] - t.zs[i - 1])) }
        t.length = t.cum[n]
        guard t.length > 0.5 else { return nil }
        var previous = Self.yaw(facing: (x: u.x, z: u.z), near: startYaw)
        let offset = startYaw - previous                             // the view's small misalignment at the start, faded out
        for i in 0...n {
            let a = max(0, i - 1), b = min(n, i + 1)
            let dir = i == 0 ? (x: u.x, z: u.z) : i == n ? (x: s.x, z: s.z) : (x: t.xs[b] - t.xs[a], z: t.zs[b] - t.zs[a])
            previous = Self.yaw(facing: dir, near: previous)
            t.yaws.append(previous + offset * max(0, 1 - t.cum[i] / (0.25 * t.length)))
        }
        for i in 1...n {
            let ds = t.cum[i] - t.cum[i - 1]
            if ds > 1e-6 { t.minRadius = min(t.minRadius, ds / max(1e-9, abs(t.yaws[i] - t.yaws[i - 1]))) }
        }
        t.speed = max(Self.smoothTurnMinSpeed, min(travelSpeed, Self.smoothTurnMaxRate * t.minRadius))
        return t
    }

    /// Render thread (diagnostics): why the last corner could not be smooth.
    private var smoothWhy = ""
    /// Render thread: a smooth corner whose path stopped fitting at its very start
    /// (someone stepped into it) -- this walk takes that corner the ordinary way.
    private var smoothVeto: (cell: GridCoordinate, side: Direction)?

    /// Looks down the corridor ahead (along `heading`, from `x,z`): where it
    /// ends, the first `side` opening whose entry point is still ahead, and
    /// what is at the end -- a closed door, the elevator, or a forced L-corner
    /// (exactly one way on, nothing queued for it).
    private func cruiseScan(_ g: FreeWalkGeometry, x: Double, z: Double, heading: Direction,
                            side: Direction?, radius: Double,
                            routeOnward: [GridCoordinate: Direction]? = nil, decisions: Bool = false) -> CruiseScan {
        let u = Self.unit(heading)
        var cell = freeWalkCell
        var base = -((x - Double(cell.col) * g.cellSize) * u.x + (z - Double(cell.row) * g.cellSize) * u.z)
        var result = CruiseScan()
        func open(_ c: GridCoordinate, _ d: Direction) -> Bool {
            g.openEdges.contains(FreeWalkGeometry.Edge(cell: c, direction: d))
        }
        // A side opening that is a BRANCH: open here but not from the cells
        // just before/after along the walk (so a room's open floor, or a
        // wide space, never reads as a choice).
        func isBranch(_ c: GridCoordinate, _ s: Direction) -> Bool {
            guard open(c, s) else { return false }
            let before = GridCoordinate(row: c.row - heading.delta.row, col: c.col - heading.delta.col)
            let after = GridCoordinate(row: c.row + heading.delta.row, col: c.col + heading.delta.col)
            return !open(before, s) && !open(after, s)
        }
        // Oct 13: the longest legal smooth corner at `c` into `s`, starting where it may.
        func smooth(_ c: GridCoordinate, _ s: Direction) -> (d: Double, path: SmoothTurn)? {
            if c == endCell { smoothWhy = "elevator cell"; return nil }
            if roomEntranceDoorAnchor(from: c, direction: s) != nil || bathroomDoorAnchor(from: c, direction: s) != nil
                || windowRoomDoorAnchor(from: c, direction: s) != nil { smoothWhy = "doorway on the way out"; return nil }
            if let veto = smoothVeto, veto.cell == c, veto.side == s { smoothWhy = "the curve was blocked at its start"; return nil }
            // Far off: not planned yet (it is, well before the walk need slow for it).
            if base - (Self.smoothTurnEntries.first ?? 3) > cruiseSpeed * cruiseSpeed / (2 * Self.smoothTurnBrake) + 2 {
                smoothWhy = "far ahead"; return nil
            }
            var tried = false
            smoothWhy = ""
            for entry in Self.smoothTurnEntries where entry <= base + 1e-6 {
                tried = true
                let sx = x + u.x * (base - entry), sz = z + u.z * (base - entry)
                if let path = planSmoothTurn(g, sx: sx, sz: sz, cell: c, heading: heading, side: s, startYaw: cruiseHeadingYaw) {
                    // Only if the walk can ease down to its pace in time (never a sudden drop).
                    guard cruiseSpeed * cruiseSpeed <= path.speed * path.speed + 2 * Self.cruiseBrake * (base - entry) + 0.5 else {
                        smoothWhy = "seen too late to ease into"; continue
                    }
                    return (base - entry, path)
                }
            }
            if !tried { smoothWhy = String(format: "only %.1f m to the corner", max(0, base)) }
            else if smoothWhy.isEmpty { smoothWhy = "no room for a curve here" }
            return nil
        }
        func take(_ c: GridCoordinate, _ s: Direction, fromRequest: Bool, route: Bool, tightRadius r: Double, note: String,
                  planned: (d: Double, path: SmoothTurn)?? = nil) -> Bool {
            if let sm = planned ?? smooth(c, s) {
                result.turn = max(0, sm.d); result.smooth = sm.path; result.turnRadius = sm.path.minRadius
            } else {
                let d = base - r
                guard d >= -1e-6 else { return false }
                result.turn = max(0, d); result.turnRadius = r
                result.turnNote = note.isEmpty ? smoothWhy : note
            }
            result.turnSide = s; result.turnFromRequest = fromRequest; result.routeTurn = route; result.turnCell = c
            return true
        }
        for _ in 0..<16 {
            if let side, result.turn == nil, g.openEdges.contains(FreeWalkGeometry.Edge(cell: cell, direction: side)) {
                _ = take(cell, side, fromRequest: true, route: false, tightRadius: radius, note: "")
            }
            // Follow the leader: where an escort's route turns, turn (an
            // explicit LEFT/RIGHT found above still wins).
            if result.turn == nil, let onward = routeOnward?[cell], onward == heading.left || onward == heading.right,
               open(cell, onward) {
                // (Oct 13: smooth too -- the walk's following-gap brake now also
                // works inside a smooth corner; failing that, the tight one.)
                _ = take(cell, onward, fromRequest: false, route: true, tightRadius: radius, note: "")
            }
            // Smart WALK: a genuine choice ahead -> stop on its centre. With a
            // turn queued, only where that turn exists (pressed too late to
            // corner: taken from the stop instead).
            let short = base - (g.cellSize / 2 + Self.smartWalkDecisionStopShort)
            if decisions, result.turn == nil, !cruiseDecisionSkip.contains(cell), short >= -0.01 {
                let branches = [heading.left, heading.right].filter { isBranch(cell, $0) }
                let straight = open(cell, heading)
                if (straight && !branches.isEmpty) || branches.count >= 2, side.map({ branches.contains($0) }) ?? true {
                    result.stop = max(0, short)
                    result.decision = true
                    result.decisionCell = cell
                    return result
                }
            }
            guard g.openEdges.contains(FreeWalkGeometry.Edge(cell: cell, direction: heading)) else {
                result.stop = max(0, base + g.cellSize / 2 - g.wallMargin)
                if cell == endCell, heading == elevatorMountDirection, elevatorLeftDoor != nil {
                    result.elevator = true
                    result.stop = max(0, base)                       // square in front of the doors
                } else if let door = closedDoor(from: cell, direction: heading) {
                    result.door = door
                } else if result.turn == nil {
                    // Only a CORRIDOR corner: the corner, the corridor it ends
                    // and the one it turns into are all plain two-way passage
                    // (never a room's open floor, where "the only way on" is
                    // just its wall -- following those would circle the room).
                    func openWays(_ c: GridCoordinate) -> Int {
                        Direction.allCases.filter { g.openEdges.contains(FreeWalkGeometry.Edge(cell: c, direction: $0)) }.count
                    }
                    let ways = [heading.left, heading.right].filter { g.openEdges.contains(FreeWalkGeometry.Edge(cell: cell, direction: $0)) }
                    let behind = GridCoordinate(row: cell.row - heading.delta.row, col: cell.col - heading.delta.col)
                    if ways.count == 1, openWays(cell) == 2, openWays(behind) <= 2,
                       openWays(GridCoordinate(row: cell.row + ways[0].delta.row, col: cell.col + ways[0].delta.col)) <= 2 {
                        // Oct 13: smooth first; else the Oct 12 wide circle, else tight.
                        let planned = smooth(cell, ways[0])
                        if planned == nil {
                            let why = smoothWhy
                            let r = autoCornerRadius(cell: cell, side: ways[0], base: base, radius: radius)
                            _ = take(cell, ways[0], fromRequest: false, route: false, tightRadius: r,
                                     note: why + (autoCornerWhy.isEmpty ? "" : "; " + autoCornerWhy), planned: .some(nil))
                        } else {
                            _ = take(cell, ways[0], fromRequest: false, route: false, tightRadius: radius, note: "", planned: .some(planned))
                        }
                    }
                }
                return result
            }
            cell = GridCoordinate(row: cell.row + heading.delta.row, col: cell.col + heading.delta.col)
            base += g.cellSize
        }
        return result
    }

    /// Render thread: one frame of the continuous walk.
    private func stepContinuousWalk(dt: Double) {
        cruiseGeometryLock.lock()
        if let fresh = cruisePendingGeometry { freeWalkGeometry = fresh; cruisePendingGeometry = nil }
        if let guidance = cruisePendingGuidance { cruiseGuidance = guidance; cruisePendingGuidance = nil }
        cruiseGeometryLock.unlock()
        guard let g = freeWalkGeometry else { endContinuousWalkFromRenderer(reason: "noGeometry"); return }
        cruiseClock += dt
        let position = cameraNode.position
        let px = Double(position.x), pz = Double(position.z)

        if var arc = cruiseArc, let path = arc.smooth {
            // ---- Oct 13: in a SMOOTH corner -- along the planned path at its steady
            // pace (eased to, never snapped), the view on the path's tangent.
            var target = path.speed * cruiseGuidance.paceScale                // (Oct 20: automatic walks at 0.8)
            if arc.route, let leader = cruiseGuidance.leader {        // following a guide round his turn: never close past the gap
                let lookYaw = Double(cameraNode.eulerAngles.y)
                if Self.leaderHolds(along: (-sin(lookYaw), -cos(lookYaw)), dx: leader.x - px, dz: leader.z - pz,
                                    beside: cruiseGuidance.leaderBeside) {   // (only while he is ahead -- a critter: or beside)
                    let room = max(0, hypot(leader.x - px, leader.z - pz) - Self.escortFollowGap)
                    target = min(target, (2 * Self.cruiseBrake * room).squareRoot())
                }
            }
            if cruiseSpeed < target { cruiseSpeed = min(target, cruiseSpeed + Self.cruiseAccel * dt) }
            else { cruiseSpeed = max(target, cruiseSpeed - Self.cruiseBrake * dt) }
            arc.travelled = min(path.length, arc.travelled + cruiseSpeed * dt)
            var i = arc.segment
            while i < path.cum.count - 2, path.cum[i + 1] < arc.travelled { i += 1 }
            arc.segment = i
            let span = max(1e-9, path.cum[i + 1] - path.cum[i])
            let f = min(1, max(0, (arc.travelled - path.cum[i]) / span))
            let tx = path.xs[i] + (path.xs[i + 1] - path.xs[i]) * f
            let tz = path.zs[i] + (path.zs[i + 1] - path.zs[i]) * f
            let yaw = path.yaws[i] + (path.yaws[i + 1] - path.yaws[i]) * f
            let next = g.slideEndpoint(from: SCNVector3(position.x, eyeHeight, position.z), dx: tx - px, dz: tz - pz)
            let moved = Double(hypotf(next.x - position.x, next.z - position.z))
            let wanted = hypot(tx - px, tz - pz)
            cameraNode.position = next
            cameraNode.eulerAngles = SCNVector3(0, Float(yaw), 0)
            freeWalkTrackCell(next)
            // (diagnostics: what it actually did)
            arc.elapsed += dt
            arc.movedSum += moved
            if let last = arc.lastYaw, dt > 0 { arc.peakRate = max(arc.peakRate, abs(yaw - last) / dt) }
            arc.lastYaw = yaw
            arc.stall = wanted > 0.001 && moved < wanted * 0.5 ? arc.stall + dt : 0
            if arc.stall > 0.12 {
                // Someone stands in the corner: stop, facing the way the path is going there.
                cruiseHeadingYaw = yaw
                cruiseArc = nil
                CruiseCornerNote.shared.post("smooth turn BLOCKED -- walk stopped")
                endContinuousWalkFromRenderer(reason: "blockedInTurn")
                return
            }
            if arc.travelled >= path.length - 1e-9 {
                cameraNode.eulerAngles = SCNVector3(0, Float(arc.endYaw), 0)
                cruiseHeadingYaw = arc.endYaw
                lastCruiseHeading = arc.endHeading
                cruiseArc = nil
                cruiseGentleUntil = cruiseClock + 1.0
                CruiseCornerNote.shared.post(String(format: "SMOOTH done  avg %.1f m/s  peak %.0f deg/s  %.1f s",
                                                    arc.movedSum / max(arc.elapsed, 1e-6), arc.peakRate * 180 / .pi, arc.elapsed))
                diag("cruise.smoothTurnDone", ["avgSpeed": (arc.movedSum / max(arc.elapsed, 1e-6) * 10).rounded() / 10,
                                               "peakDegPerSec": Int(arc.peakRate * 180 / .pi), "seconds": (arc.elapsed * 100).rounded() / 100])
                let serial = arc.serial, session = cruiseSession, heading = arc.endHeading
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.cruiseSession == session else { return }
                    if self.cruiseRequestSerial == serial, case .walkingQueued = self.continuousWalkState {
                        self.cruiseRequest = nil
                        self.continuousWalkState = .walking
                    }
                    diag("cruise.turnDone", ["cell": self.currentCell, "heading": "\(heading)"])
                }
            } else {
                cruiseArc = arc
            }
            cruiseDistance += moved
            setFreeWalkFootsteps(cruiseFootstepsWanted(moved: moved, dt: dt))
            SoundEffects.setWalkingPace(Float(max(0.6, min(1.5, cruiseSpeed / travelSpeed))))
            return
        }

        if var arc = cruiseArc {
            // ---- In the corner: follow the quarter circle at turn speed.
            // (Oct 20: a tight corner at the walk's pace; a wide one's own speed is already scaled)
            let turnSpeed = arc.speed ?? Self.cruiseTurnSpeed(radius: arc.radius) * cruiseGuidance.paceScale
            cruiseSpeed += (turnSpeed - cruiseSpeed) * (1 - exp(-dt / 0.08))
            let step = max(0.2, cruiseSpeed) * dt
            arc.travelled = min(arc.length, arc.travelled + step)
            let theta = arc.travelled / arc.radius
            let tx = arc.centerX - arc.radius * arc.sideX * cos(theta) + arc.radius * arc.headX * sin(theta)
            let tz = arc.centerZ - arc.radius * arc.sideZ * cos(theta) + arc.radius * arc.headZ * sin(theta)
            let next = g.slideEndpoint(from: SCNVector3(position.x, eyeHeight, position.z), dx: tx - px, dz: tz - pz)
            let moved = Double(hypotf(next.x - position.x, next.z - position.z))
            let wanted = hypot(tx - px, tz - pz)
            cameraNode.position = next
            let linear = arc.travelled / arc.length
            let f = arc.speed == nil ? linear : linear * linear * (3 - 2 * linear)   // (Oct 12: wide corners ease in and out)
            let yaw = arc.startYaw + (arc.endYaw - arc.startYaw) * f
            cameraNode.eulerAngles = SCNVector3(0, Float(yaw), 0)
            freeWalkTrackCell(next)
            arc.stall = wanted > 0.001 && moved < wanted * 0.5 ? arc.stall + dt : 0
            if arc.stall > 0.12 {
                // Something (a character) stands in the corner: finish facing
                // the new corridor and stop. Never forces through.
                cameraNode.eulerAngles = SCNVector3(0, Float(arc.endYaw), 0)
                cruiseHeadingYaw = arc.endYaw
                cruiseArc = nil
                CruiseCornerNote.shared.post("curve BLOCKED -- walk stopped")    // (Oct 12 diagnostics)
                endContinuousWalkFromRenderer(reason: "blockedInTurn")
                return
            }
            if arc.travelled >= arc.length - 1e-9 {
                cameraNode.eulerAngles = SCNVector3(0, Float(arc.endYaw), 0)
                cruiseHeadingYaw = arc.endYaw
                lastCruiseHeading = arc.endHeading                  // (Oct 12: recent travel)
                cruiseArc = nil
                let serial = arc.serial, session = cruiseSession, heading = arc.endHeading
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.cruiseSession == session else { return }
                    // Clear the lit arrow -- unless a NEW request came in meanwhile.
                    if self.cruiseRequestSerial == serial, case .walkingQueued = self.continuousWalkState {
                        self.cruiseRequest = nil
                        self.continuousWalkState = .walking
                    }
                    diag("cruise.turnDone", ["cell": self.currentCell, "heading": "\(heading)"])
                }
            } else {
                cruiseArc = arc
            }
            cruiseDistance += moved
            setFreeWalkFootsteps(cruiseFootstepsWanted(moved: moved, dt: dt))
            SoundEffects.setWalkingPace(Float(max(0.6, min(1.5, cruiseSpeed / travelSpeed))))
            return
        }

        // ---- Straight: hold the cardinal heading (gently re-aligning).
        var yaw = Double(cameraNode.eulerAngles.y)
        if yaw != cruiseHeadingYaw {
            yaw = Self.rateLimitedYaw(current: yaw, target: cruiseHeadingYaw, maxStep: Self.heldWalkMaxTurnRate * dt)
            cameraNode.eulerAngles = SCNVector3(0, Float(yaw), 0)
        }
        // Oct 12 (playtest): well off the corridor (GO from a view angled at a
        // wall) -- turn on the spot first, then walk.
        if abs(cruiseHeadingYaw - yaw) > Self.cruiseAlignInPlace {
            cruiseSpeed = 0
            setFreeWalkFootsteps(false)
            return
        }
        let heading = nearestCardinal(toYaw: cruiseHeadingYaw)
        var request: (turn: ContinuousWalkTurn, serial: Int)?
        if let r = cruiseRequest, r.serial != cruiseConsumedSerial { request = r }
        let side: Direction? = request.map { $0.turn == .left ? heading.left : heading.right }
        let band = g.cellSize / 2 - g.wallMargin - 0.02
        let radius = max(0.05, min(Self.cruiseTurnRadius, band))
        let routeOnward = cruiseGuidance.routeOnward
        var scan = cruiseScan(g, x: px, z: pz, heading: heading, side: side, radius: radius, routeOnward: routeOnward,
                              decisions: smartWalkDecisionStopsOn && routeOnward == nil)
        // A capped landing spot ahead (Juanita's counter, Tinky's desk): the
        // walk ends at its pose; the landing itself then runs as for a tap walk.
        var landing = false
        // It beats a forced corner (the cap lies before the corridor's end,
        // so that corner is the room's wall round it -- e.g. round behind
        // Tinky's desk); a turn the player queued still wins if it comes first.
        if let cap = cruiseLandingCap(x: px, z: pz, heading: heading, cellSize: g.cellSize), cap < scan.stop,
           !scan.turnFromRequest || (scan.turn.map({ cap < $0 }) ?? true) {
            scan.stop = cap
            scan.turn = nil
            scan.door = nil
            scan.elevator = false
            scan.decision = false
            scan.smooth = nil                                       // (Oct 13)
            landing = true
        }

        // Speed: sustained pace like a hold (1.5x after three cells), braking
        // for the corridor's end and for a queued corner's entry speed.
        // (Oct 20: an automatic walk's pace -- cruiseGuidance.paceScale, 0.8; an escort's, 1)
        let pace = cruiseGuidance.paceScale
        let sustained = travelSpeed * pace * (cruiseDistance >= 3 * g.cellSize ? Self.fastWalkPace : 1.0)
        var limit = min(sustained, (2 * Self.cruiseBrake * scan.stop).squareRoot())
        // (Oct 12: a wide automatic corner is entered at its own, walking-pace speed.)
        let wideCorner = scan.turn != nil && scan.smooth == nil && !scan.turnFromRequest && scan.turnRadius > radius + 1e-6
        let turnSpeed = pace * (scan.smooth.map { $0.speed }
            ?? (wideCorner ? min(travelSpeed * Self.cruiseAutoTurnPaceFactor, scan.turnRadius * .pi / 2 / Self.cruiseAutoTurnMinTime)
                           : Self.cruiseTurnSpeed(radius: scan.turn != nil && scan.turnRadius > 0 ? scan.turnRadius : radius)))
        // (Oct 13: a smooth corner is eased into from further out -- half the ordinary brake.)
        let cornerBrake = scan.smooth != nil ? Self.smoothTurnBrake : Self.cruiseBrake
        if let t = scan.turn { limit = min(limit, (turnSpeed * turnSpeed + 2 * cornerBrake * t).squareRoot()) }
        if cruiseClock < cruiseDoorSlowUntil { limit = min(limit, Self.cruiseDoorSpeed * pace) }
        // Oct 11 (escort pacing): following a guide, never close past the
        // following gap -- the walk slows behind him, stands while he waits,
        // and goes on as he does. Only while the guide is ahead of the player.
        if let leader = cruiseGuidance.leader {
            let f = Self.unit(heading)
            let dx = leader.x - px, dz = leader.z - pz
            if Self.leaderHolds(along: (f.x, f.z), dx: dx, dz: dz, beside: cruiseGuidance.leaderBeside) {
                let room = max(0, hypot(dx, dz) - Self.escortFollowGap)
                limit = min(limit, (2 * Self.cruiseBrake * room).squareRoot())
            }
        }
        // A closed door ahead: ask for it once, early enough to keep walking.
        if let door = scan.door, door != cruiseDoorRequested,
           scan.stop <= cruiseSpeed * cruiseSpeed / (2 * Self.cruiseBrake) + Self.cruiseDoorLead {
            cruiseDoorRequested = door
            cruiseDoorSlowUntil = cruiseClock + 0.9
            let session = cruiseSession
            DispatchQueue.main.async { [weak self] in self?.continuousWalkReachedDoor(door, session: session) }
        }
        // (Oct 13: out of a smooth corner the pace comes back gently.)
        let accel = cruiseClock < cruiseGentleUntil ? Self.smoothTurnExitAccel : Self.cruiseAccel
        if cruiseSpeed < limit { cruiseSpeed = min(limit, cruiseSpeed + accel * dt) } else { cruiseSpeed = limit }
        var step = cruiseSpeed * dt

        // The corner starts exactly at its entry point.
        var startTurn = false
        if let t = scan.turn, t <= step + 1e-6 { step = t; startTurn = true }
        // A decision / landing stop is arrived at exactly (never overshot
        // on a long frame) and ends the walk in the same frame.
        let arriving = !startTurn && (scan.decision || landing) && step >= scan.stop - 0.01
        if arriving { step = scan.stop }
        // At the corridor's end with nothing to turn into: stop here.
        if !startTurn, !arriving, scan.stop < 0.01 {
            if scan.elevator {
                endContinuousWalkFromRenderer(reason: "elevator") { [weak self] in self?.continuousWalkBoardElevator() }
            } else {
                endContinuousWalkFromRenderer(reason: "deadEnd")
            }
            return
        }

        let forward = FreeWalkGeometry.forward(yaw: yaw)
        let next = g.slideEndpoint(from: SCNVector3(position.x, eyeHeight, position.z), dx: forward.x * step, dz: forward.z * step)
        let moved = Double(hypotf(next.x - position.x, next.z - position.z))
        cameraNode.position = next
        cruiseDistance += moved
        freeWalkTrackCell(next)
        setFreeWalkFootsteps(cruiseFootstepsWanted(moved: moved, dt: dt))
        SoundEffects.setWalkingPace(Float(max(0.6, min(1.5, cruiseSpeed / travelSpeed))))

        if arriving {
            if landing {
                endContinuousWalkFromRenderer(reason: "landing")   // finishFreeMove -> landAtSpotIfApproaching
            } else {
                let late = request?.turn
                let cell = scan.decisionCell ?? freeWalkCell
                CruiseCornerNote.shared.post("STOP at a junction -- not an auto corner")   // (Oct 12 diagnostics)
                endContinuousWalkFromRenderer(reason: "decision") { [weak self] in self?.continuousWalkDecisionStop(cell: cell, late: late) }
            }
            return
        }

        if startTurn, let side = scan.turnSide {
            // A queued turn is consumed; a forced L-corner leaves any queued
            // request for a later opening untouched.
            var serial = -1
            if scan.turnFromRequest, let request { serial = request.serial }
            // (Oct 13: a request is consumed only once its corner actually starts.)
            func consume() { if scan.turnFromRequest, let request { cruiseConsumedSerial = request.serial } }
            if !scan.turnFromRequest { diag(scan.routeTurn ? "cruise.routeTurn" : "cruise.forcedTurn", ["toward": "\(side)"]) }
            let u = Self.unit(heading), s = Self.unit(side)
            let endYaw = Self.yaw(facing: (x: s.x, z: s.z), near: cruiseHeadingYaw)
            // Oct 13: a SMOOTH corner -- planned again from exactly here; if that
            // no longer fits (someone stepped into it), the quarter circle below.
            if scan.smooth != nil, let cell = scan.turnCell {
                if let path = planSmoothTurn(g, sx: Double(next.x), sz: Double(next.z), cell: cell, heading: heading, side: side, startYaw: yaw) {
                    var arc = CruiseArc(centerX: Double(next.x), centerZ: Double(next.z), headX: u.x, headZ: u.z, sideX: s.x, sideZ: s.z,
                                        radius: path.minRadius, startYaw: yaw, endYaw: endYaw, endHeading: side, serial: serial,
                                        speed: path.speed)
                    arc.smooth = path
                    arc.route = scan.routeTurn
                    consume()
                    smoothVeto = nil
                    cruiseArc = arc
                    let kind = scan.turnFromRequest ? "your LEFT/RIGHT" : scan.routeTurn ? "escort's route" : "corner"
                    CruiseCornerNote.shared.post(String(format: "SMOOTH turn  r>=%.1f m  %.1f m/s  %.1f s  (%@)",
                                                        path.minRadius, path.speed, path.length / path.speed, kind))
                    diag("cruise.smoothTurn", ["cell": "\(cell.row),\(cell.col)", "toward": "\(side)", "entry": (path.entry * 100).rounded() / 100,
                                               "minRadius": (path.minRadius * 100).rounded() / 100, "speed": (path.speed * 10).rounded() / 10,
                                               "length": (path.length * 100).rounded() / 100, "kind": kind, "entrySpeed": (cruiseSpeed * 10).rounded() / 10])
                    cruiseStall = 0
                    return
                }
                // Someone stepped into it: no smooth corner here this walk -- go
                // on straight; the scan offers this corner the ordinary way next frame.
                smoothVeto = (cell, side)
                diag("cruise.smoothVetoed", ["cell": "\(cell.row),\(cell.col)", "toward": "\(side)"])
                cruiseStall = 0
                return
            }
            consume()
            smoothVeto = nil
            let r = scan.turnRadius > 0 ? scan.turnRadius : radius
            cruiseArc = CruiseArc(centerX: Double(next.x) + r * s.x, centerZ: Double(next.z) + r * s.z,
                                  headX: u.x, headZ: u.z, sideX: s.x, sideZ: s.z, radius: r,
                                  startYaw: yaw, endYaw: endYaw, endHeading: side, serial: serial,
                                  speed: wideCorner ? turnSpeed : nil)
            if wideCorner { diag("cruise.wideCorner", ["radius": (r * 100).rounded() / 100, "speed": (turnSpeed * 10).rounded() / 10]) }
            // Oct 12 (developer diagnostics): which corner code ran, and why.
            let why: String
            if wideCorner { why = String(format: "WIDE curve  r %.2f m  %.1f m/s", r, turnSpeed) + (scan.turnNote.isEmpty ? "" : "  (\(scan.turnNote))") }
            else if scan.turnFromRequest { why = String(format: "TIGHT turn  r %.2f m  -- your LEFT/RIGHT: ", r) + scan.turnNote }
            else if scan.routeTurn { why = String(format: "TIGHT turn  r %.2f m  -- escort's route: ", r) + scan.turnNote }
            else { why = String(format: "TIGHT turn  r %.2f m  -- ", r) + (scan.turnNote.isEmpty ? "auto corner" : scan.turnNote) }
            CruiseCornerNote.shared.post(why)
            cruiseStall = 0
            return
        }

        // Blocked (a character, a misaligned slide into a wall): stop once,
        // never keep pushing. A character on guard gets her one reaction.
        if step > 0.001, moved < step * 0.3 {
            cruiseStall += dt
            if !characterKeepOuts.isEmpty, !cruiseBumped,
               segmentMeetsCharacter(x: Double(next.x), z: Double(next.z), dx: forward.x * 0.3, dz: forward.z * 0.3) {
                cruiseBumped = true
                DispatchQueue.main.async { [weak self] in self?.onCharacterBlockBump?() }
            }
            if cruiseStall > 0.12 { endContinuousWalkFromRenderer(reason: "blocked"); return }
        } else {
            cruiseStall = 0
        }
    }

    /// Oct 10: set by the lobby's ceremonial walk; consumed when it finishes.
    private var ceremonialElevatorAutoOpen = false
    static let ceremonialElevatorOpenDelay: TimeInterval = 0.6

    private func scheduleCeremonialElevatorOpen() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ceremonialElevatorOpenDelay) { [weak self] in
            guard let self, self.currentCell == self.endCell, self.canRotate, !self.elevatorInUse else {
                diag("ceremony.elevatorAutoOpen", ["result": "skipped"])
                return
            }
            diag("ceremony.elevatorAutoOpen", ["result": "opening"])
            self.openElevator()
        }
    }

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
    private var ticTacToeTerminalCoords: Set<GridCoordinate>
    private var shellGameStationCoords: Set<GridCoordinate>
    private var rockPaperScissorsTerminalCoords: Set<GridCoordinate>
    private var higherLowerTerminalCoords: Set<GridCoordinate>
    private var fiveCardDrawTerminalCoords: Set<GridCoordinate>
    private var simonTerminalCoords: Set<GridCoordinate>
    private var hangmanTerminalCoords: Set<GridCoordinate>
    private var connectFourTerminalCoords: Set<GridCoordinate>
    private var checkersTerminalCoords: Set<GridCoordinate>
    private var woidleTerminalCoords: Set<GridCoordinate>
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
        PerfMonitor.gauge("navControllers", +1)                            // Oct 21: live count (measurement)
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
        if !(isMissionComplete && !Self.missionGatesElevator) {   // Oct 4: no "return to the elevator" when it isn't gated
            showMessage(isMissionComplete ? "ID photo accepted! Return to the elevator." : (photoBoothMissionProgress ?? "Photo accepted."))
        }
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
            ToolBelt.dropHallwayExtinguisher(animated: false)
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

    /// Oct 1 (Decorator Games): a game placed live in Decorate joins the
    /// SAME bookkeeping a build-time one gets from init (direction for the
    /// face/lock-in checks, coord for the walk stop, node for the status
    /// screen), so tapping it runs the existing game with no rebuild.
    /// Oct 1 (game map markers): every cell holding a game fixture -- the
    /// same coord sets the walk-stop uses, so live Decorate adds/deletes
    /// (registerGame/unregisterGame) show on the map at once.
    private var gameMapCells: Set<GridCoordinate> {
        ticTacToeTerminalCoords.union(shellGameStationCoords).union(rockPaperScissorsTerminalCoords)
            .union(higherLowerTerminalCoords).union(fiveCardDrawTerminalCoords).union(simonTerminalCoords)
            .union(hangmanTerminalCoords).union(connectFourTerminalCoords).union(checkersTerminalCoords)
            .union(woidleTerminalCoords)
    }

    func registerGame(_ kind: GameFixtureKind, direction: Direction, node: SCNNode, at coord: GridCoordinate) {
        defer { refreshFloorMapTexture() }
        switch kind {
        case .ticTacToeTerminals:
            ticTacToeDirections[coord] = direction
            ticTacToeTerminalCoords.insert(coord)
            ticTacToeTerminalNodes[coord] = node
        case .shellGameStations:
            shellGameDirections[coord] = direction
            shellGameStationCoords.insert(coord)
            shellGameStationNodes[coord] = node
        case .rockPaperScissorsTerminals:
            rockPaperScissorsDirections[coord] = direction
            rockPaperScissorsTerminalCoords.insert(coord)
            rockPaperScissorsTerminalNodes[coord] = node
        case .higherLowerTerminals:
            higherLowerDirections[coord] = direction
            higherLowerTerminalCoords.insert(coord)
            higherLowerTerminalNodes[coord] = node
        case .fiveCardDrawTerminals:
            fiveCardDrawDirections[coord] = direction
            fiveCardDrawTerminalCoords.insert(coord)
            fiveCardDrawTerminalNodes[coord] = node
        case .hangmanTerminals:
            hangmanDirections[coord] = direction
            hangmanTerminalCoords.insert(coord)
            hangmanTerminalNodes[coord] = node
        case .simonTerminals:
            simonDirections[coord] = direction
            simonTerminalCoords.insert(coord)
            simonTerminalNodes[coord] = node
        case .connectFourTerminals:
            connectFourDirections[coord] = direction
            connectFourTerminalCoords.insert(coord)
            connectFourTerminalNodes[coord] = node
        case .checkersTerminals:
            checkersDirections[coord] = direction
            checkersTerminalCoords.insert(coord)
            checkersTerminalNodes[coord] = node
        case .woidleTerminals:
            woidleDirections[coord] = direction
            woidleTerminalCoords.insert(coord)
            woidleTerminalNodes[coord] = node
        }
    }

    /// Reverse of registerGame. Decorate can only select while no game
    /// is active (canRotate), so there is never a live session to end.
    func unregisterGame(_ kind: GameFixtureKind, at coord: GridCoordinate) {
        defer { refreshFloorMapTexture() }
        switch kind {
        case .ticTacToeTerminals:
            ticTacToeDirections.removeValue(forKey: coord)
            ticTacToeTerminalCoords.remove(coord)
            ticTacToeTerminalNodes.removeValue(forKey: coord)
        case .shellGameStations:
            shellGameDirections.removeValue(forKey: coord)
            shellGameStationCoords.remove(coord)
            shellGameStationNodes.removeValue(forKey: coord)
        case .rockPaperScissorsTerminals:
            rockPaperScissorsDirections.removeValue(forKey: coord)
            rockPaperScissorsTerminalCoords.remove(coord)
            rockPaperScissorsTerminalNodes.removeValue(forKey: coord)
        case .higherLowerTerminals:
            higherLowerDirections.removeValue(forKey: coord)
            higherLowerTerminalCoords.remove(coord)
            higherLowerTerminalNodes.removeValue(forKey: coord)
        case .fiveCardDrawTerminals:
            fiveCardDrawDirections.removeValue(forKey: coord)
            fiveCardDrawTerminalCoords.remove(coord)
            fiveCardDrawTerminalNodes.removeValue(forKey: coord)
        case .hangmanTerminals:
            hangmanDirections.removeValue(forKey: coord)
            hangmanTerminalCoords.remove(coord)
            hangmanTerminalNodes.removeValue(forKey: coord)
        case .simonTerminals:
            simonDirections.removeValue(forKey: coord)
            simonTerminalCoords.remove(coord)
            simonTerminalNodes.removeValue(forKey: coord)
        case .connectFourTerminals:
            connectFourDirections.removeValue(forKey: coord)
            connectFourTerminalCoords.remove(coord)
            connectFourTerminalNodes.removeValue(forKey: coord)
        case .checkersTerminals:
            checkersDirections.removeValue(forKey: coord)
            checkersTerminalCoords.remove(coord)
            checkersTerminalNodes.removeValue(forKey: coord)
        case .woidleTerminals:
            woidleDirections.removeValue(forKey: coord)
            woidleTerminalCoords.remove(coord)
            woidleTerminalNodes.removeValue(forKey: coord)
        }
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

    /// Sept 28 (Your Height): moves the viewpoint to a new eye height
    /// immediately, without a rebuild. Only Y changes -- the camera's X/Z,
    /// grid cell, facing and pitch are untouched -- and every stored
    /// position the controller later walks or snaps back to (drag origin,
    /// in-progress segment endpoints, the elevator threshold's hallway
    /// center) is lifted to the same Y so nothing drifts back to the old
    /// height.
    func setEyeHeight(_ height: Float) {
        guard height.isFinite, height > 0, height != eyeHeight else { return }
        eyeHeight = height
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        cameraNode.position.y = height
        SCNTransaction.commit()
        dragBasePosition.y = height
        segmentStart.y = height
        segmentTarget.y = height
        elevatorEntryCellCenterPosition?.y = height
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
    func rotate(toward direction: Direction, durationPerQuarterTurn: Double? = nil) {
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
        guard canRotate, !isElevatorRideInProgress, direction != facing else {
            navLog("rotate(toward: \(direction)) ignored -- canRotate=\(canRotate), facing=\(facing)")
            return
        }
        standaloneRotation = true
        pendingRotationTarget = direction
        phase = .pivot
        segmentProgress = 0
        pivotStartYaw = Double(cameraNode.eulerAngles.y)
        pivotTargetYaw = pivotStartYaw + shortestDelta(from: pivotStartYaw, to: direction.yaw)
        // Oct 10: gestures (no duration passed) keep the original quick pivot.
        // The HUD passes a per-90-degree time, scaled by the actual angle
        // (free look can leave the view a little off-cardinal).
        if let perQuarter = durationPerQuarterTurn {
            standalonePivotDuration = max(0.12, perQuarter * abs(pivotTargetYaw - pivotStartYaw) / (.pi / 2))
        } else {
            standalonePivotDuration = pivotDuration
        }
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
        guard canRotate, !isElevatorRideInProgress else {
            navLog("beginDragRotate() ignored -- canRotate=false")
            return
        }
        cameraNode.removeAction(forKey: Self.freeLookAlignActionKey)
        dragBaseYaw = Double(cameraNode.eulerAngles.y)
        isDragRotating = true
        snapDwellAnchorFraction = 0
        lastMeaningfulHorizontalMoveTime = ProcessInfo.processInfo.systemUptime
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
        noteHorizontalFraction(fraction, at: ProcessInfo.processInfo.systemUptime)
        // Free look: no one-gesture quarter-turn limit (same unclamped
        // math the elevator ride's updateElevatorCameraDrag uses).
        let clamped = freeLookEnabled ? fraction : max(-1, min(1, fraction))
        let scnT = FrameTiming.start()                                    // Oct 24: SceneKit wait (measurement only)
        cameraNode.eulerAngles = SCNVector3(0, Float(dragBaseYaw + clamped * .pi / 2), 0)
        FrameTiming.shared.record(.scnCamera, since: scnT)
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
        if freeLookEnabled {
            // Free look: the camera stays exactly where the finger left it.
            // Logical facing becomes the nearest cardinal to that yaw via
            // the SAME standalone-pivot completion a snapped turn uses --
            // just a zero-length pivot (start == target, already complete),
            // so it finishes on the next frame without moving the camera,
            // then runs the usual deferred facing update + booth/terminal
            // activation.
            // The release fraction is the finger's final position, which
            // updateDragRotate has normally already applied -- set it again
            // so the resting yaw always matches the release exactly. Flick
            // velocity is deliberately ignored: no momentum, no commit.
            let yaw = dragBaseYaw + fraction * .pi / 2
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            cameraNode.eulerAngles = SCNVector3(0, Float(yaw), 0)
            SCNTransaction.commit()
            let target = nearestCardinal(toYaw: yaw)
            logNavSync("FREE LOOK RELEASE — yaw=\(yaw) facing=\(target)")
            navLog("endDragRotate(free look) yaw=\(String(format: "%.3f", yaw)) -> facing=\(target)")
            standaloneRotation = true
            pendingRotationTarget = target
            phase = .pivot
            pivotStartYaw = yaw
            pivotTargetYaw = yaw
            segmentProgress = 1
            // Magnetic cardinal snap: a committed turn away from the
            // starting cardinal finishes at `target` exactly (animated by
            // the ordinary pivot); a smaller look keeps the zero-length pivot.
            // Dwell gate: a finger that settled before lifting keeps the
            // exact heading; only a prompt release reaches the snap below.
            let releaseTime = ProcessInfo.processInfo.systemUptime
            noteHorizontalFraction(fraction, at: releaseTime)
            let dwell = releaseTime - lastMeaningfulHorizontalMoveTime
            let settled = dwell >= noSnapDwellThreshold
            if magneticSnapEnabled && settled {
                navLog("endDragRotate(free look) dwell=\(String(format: "%.0f", dwell * 1000))ms -> settled, no snap")
            }
            if magneticSnapEnabled && !settled {
                let startCardinal = nearestCardinal(toYaw: dragBaseYaw)
                let signedTurn = shortestDelta(from: startCardinal.yaw, to: yaw)
                let turnedDegrees = abs(signedTurn) * 180 / .pi
                if turnedDegrees >= magneticSnapThresholdDegrees + magneticSnapDeadZoneDegrees {
                    // Below 45 degrees the nearest cardinal is still the
                    // starting one; the turn is toward the next one over
                    // (positive yaw = turning left, as in updateDragRotate).
                    let snapTarget = target != startCardinal ? target
                        : (signedTurn > 0 ? startCardinal.left : startCardinal.right)
                    pendingRotationTarget = snapTarget
                    pivotTargetYaw = yaw + shortestDelta(from: yaw, to: snapTarget.yaw)
                    segmentProgress = 0
                    navLog("endDragRotate(free look) magnetic snap from \(startCardinal) turned=\(String(format: "%.1f", turnedDegrees))deg -> \(snapTarget)")
                }
            }
            isAnimating = true
            return
        }
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

    // MARK: - FREE-WALK one-finger 2-D pan (polish pass #3)
    //
    // In Free Walk an ordinary one-finger pan (the finger moved before the
    // long press could recognize) has NO axis winner: for the whole life of
    // the touch, X is Free Look yaw and Y is forward/back travel, both at
    // once. X is absolute from touch-down with the existing Free Look math
    // (updateDragRotate: pointsPerQuarterTurn pt = 90 degrees, unclamped).
    // Y keeps the existing vertical-drag semantics -- positional, one cell
    // of travel per pointsPerCell pt, finger down = forward -- but applied
    // INCREMENTALLY along the camera's live yaw, so turning while moving
    // curves the path. Release is the ordinary Free Look release: exact
    // yaw, exact X/Z, logical facing = nearest cardinal. No align, no snap.

    private(set) var isFreePanning = false
    private var freePanLastDy: Double = 0
    private var freePanForwardTravel: Double = 0

    /// Starts a 2-D pan if Free Walk applies; false = use the legacy
    /// axis-locked pan instead.
    @discardableResult
    func beginFreePan() -> Bool {
        guard freeWalkApplies(held: false) else { return false }
        beginDragRotate() // menus/terminals cancelled, canRotate check, base yaw
        guard isDragRotating else { return false }
        freeWalkGeometry = makeFreeWalkGeometry()
        freeWalkCell = currentCell
        freePanLastDy = 0
        freePanForwardTravel = 0
        isFreePanning = true
        manualFootstepsFromAutoWalk = false // a pan from standing: silent
        freePanLastDx = 0
        resetPanFootstepWindow(at: ProcessInfo.processInfo.systemUptime)
        logNavSync("FREE PAN BEGIN")
        navLog("beginFreePan() at \(cameraNode.position) yaw=\(String(format: "%.3f", Double(cameraNode.eulerAngles.y)))")
        return true
    }

    /// `dx`/`dy`: the finger's total displacement from touch-down (UIKit
    /// points, dy positive = finger moved down = forward).
    func updateFreePan(dx: Double, dy: Double, pointsPerQuarterTurn: Double, pointsPerCell: Double) {
        guard isFreePanning, pointsPerQuarterTurn > 0, pointsPerCell > 0 else { return }
        let panT = FrameTiming.start()                                    // Oct 24: one swipe step (measurement only)
        defer { FrameTiming.shared.record(.pan, since: panT) }
        updateDragRotate(fraction: dx / pointsPerQuarterTurn)
        let fingerDy = dy - freePanLastDy
        let fingerDx = dx - freePanLastDx
        freePanLastDx = dx
        var step = (dy - freePanLastDy) / pointsPerCell * Double(cellSize)
        freePanLastDy = dy
        // DECORATE's one-cell forward cap, same as the drag-move scrub.
        if decorateModeEnabled, step > 0 {
            step = min(step, max(0, Double(cellSize) - freePanForwardTravel))
        }
        guard step != 0, let geometry = freeWalkGeometry else {
            updateFreePanFootsteps(fingerDx: fingerDx, fingerDy: fingerDy, forwardTravel: 0) // pivot only
            return
        }
        let readT = FrameTiming.start()                                   // Oct 24: SceneKit waits (measurement only)
        let forward = FreeWalkGeometry.forward(yaw: Double(cameraNode.eulerAngles.y))
        let position = cameraNode.position
        FrameTiming.shared.record(.scnCamera, since: readT)
        let next = geometry.slideEndpoint(from: position, dx: forward.x * step, dz: forward.z * step)
        let writeT = FrameTiming.start()
        cameraNode.position = next
        FrameTiming.shared.record(.scnCamera, since: writeT)
        let moved = Double(hypotf(next.x - position.x, next.z - position.z))
        freePanForwardTravel += step > 0 ? moved : -moved
        freeWalkTrackCell(next)
        // Oct 2: footsteps from the real forward-axis travel (see updateFreePanFootsteps).
        let travel = Double(next.x - position.x) * forward.x + Double(next.z - position.z) * forward.z
        updateFreePanFootsteps(fingerDx: fingerDx, fingerDy: fingerDy, forwardTravel: travel)
    }

    /// Finger lifted: keep the exact pose (the Free Look release).
    func endFreePan(dx: Double, pointsPerQuarterTurn: Double) {
        guard isFreePanning else { return }
        isFreePanning = false
        dragMoveFootstepToken &+= 1
        manualFootstepsFromAutoWalk = false
        setFreeWalkFootsteps(false)
        endDragRotate(fraction: dx / max(pointsPerQuarterTurn, 0.001), velocityFraction: 0)
        navLog("endFreePan() kept \(cameraNode.position) yaw=\(String(format: "%.3f", Double(cameraNode.eulerAngles.y)))")
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
    /// PINCH TOWARD THE POINT YOU ARE PINCHING (pass #5): the horizontal
    /// X/Z direction of the view ray through a screen point, from the two
    /// ends of that ray (SceneKit unprojectPoint at z 0 and 1). Height is
    /// dropped -- walking, not flying -- and for this yaw-only camera the
    /// result depends only on the point's screen X (screen Y changes the
    /// ray's pitch, not its heading). Screen center gives camera forward.
    static func horizontalDirection(near: SCNVector3, far: SCNVector3) -> (x: Double, z: Double)? {
        let dx = Double(far.x - near.x), dz = Double(far.z - near.z)
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 1e-6 else { return nil }
        return (dx / length, dz / length)
    }

    /// Free Walk scrub along an explicit horizontal direction (pinch). Same
    /// as beginDragMove() in every other respect; nil = camera forward.
    func beginDragMove(travelDirection: (x: Double, z: Double)?) {
        // Oct 2: a pinch during a tap-to-point walk takes ownership, exactly
        // like a hold does -- the walk ends right here and this pinch then
        // runs as if it began standing still.
        if !takeOverFreeTapWalkForPinch() { manualFootstepsFromAutoWalk = false } // standing pinch: silent
        pendingFreeDragDirection = travelDirection
        beginDragMove()
        pendingFreeDragDirection = nil
    }
    private var pendingFreeDragDirection: (x: Double, z: Double)?

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
        // FREE-WALK: scrub along the camera's ACTUAL yaw from the exact
        // current X/Z -- no align before, no settle-to-center after.
        if freeWalkApplies(held: false) {
            cameraNode.removeAction(forKey: Self.freeLookAlignActionKey)
            freeDragMoveActive = true
            freeDragBaseYaw = Double(cameraNode.eulerAngles.y)
            freeDragDirection = pendingFreeDragDirection ?? FreeWalkGeometry.forward(yaw: freeDragBaseYaw)
            freeWalkGeometry = makeFreeWalkGeometry()
            freeWalkCell = currentCell
            isDragMoving = true
            dragMoveFootstepPosition = cameraNode.position
            logNavSync("DRAG MOVE BEGIN (free)")
            navLog("beginDragMove(free) at \(cameraNode.position) yaw=\(String(format: "%.3f", freeDragBaseYaw))")
            return
        }
        freeDragMoveActive = false
        // Free look: the scrub moves along `facing`, so turn the camera to
        // face it. A short keyed rotate action, not the pivot phase: the
        // drag-move scrub only ever writes position, so the two run side
        // by side and the camera settles within ~0.18 s.
        if freeLookEnabled {
            let yaw = Double(cameraNode.eulerAngles.y)
            let delta = shortestDelta(from: yaw, to: facing.yaw)
            if abs(delta) > 0.001 {
                let align = SCNAction.rotateTo(x: 0, y: CGFloat(yaw + delta), z: 0, duration: pivotDuration)
                align.timingMode = .easeInEaseOut
                cameraNode.runAction(align, forKey: Self.freeLookAlignActionKey)
            }
        }
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
        if freeDragMoveActive, let geometry = freeWalkGeometry {
            let f = decorateModeEnabled ? min(fraction, 1) : fraction
            let forward = freeDragDirection
            let d = f * Double(cellSize)
            let next = geometry.slideEndpoint(from: dragBasePosition, dx: forward.x * d, dz: forward.z * d)
            cameraNode.position = next
            freeWalkTrackCell(next)
            updateDragMoveFootsteps(at: next)
            return
        }
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

    // Oct 2 (directional footsteps for the Free Walk scrub -- pinch and the
    // vertical drag-move; the one-finger free pan classifies its own, see
    // updateFreePanFootsteps below): the loop follows the ACTUAL body movement. Each
    // time the legal (post-collision) position has moved more than
    // dragMoveFootstepMinStep from the last sample, the sign of that motion
    // along the camera's facing picks forward/reverse (one swap per real
    // direction change; finger noise below the step never flips it). No
    // real movement for dragMoveFootstepIdle -- fingers still, or pressed
    // against a wall -- and the loop stops; release stops it too.
    private var dragMoveFootstepPosition = SCNVector3(0, 0, 0)
    private var dragMoveFootstepToken = 0
    static let dragMoveFootstepMinStep: Float = 0.004
    static let dragMoveFootstepIdle: TimeInterval = 0.2

    private func updateDragMoveFootsteps(at position: SCNVector3) {
        guard manualFootstepsFromAutoWalk else { return } // Oct 2: standing pinch is silent
        let dx = position.x - dragMoveFootstepPosition.x
        let dz = position.z - dragMoveFootstepPosition.z
        guard hypotf(dx, dz) > Self.dragMoveFootstepMinStep else { return }
        dragMoveFootstepPosition = position
        let forward = FreeWalkGeometry.forward(yaw: Double(cameraNode.eulerAngles.y))
        let reverse = Double(dx) * forward.x + Double(dz) * forward.z < 0
        setFreeWalkFootsteps(true, reverse: reverse)
        scheduleDragMoveFootstepIdleStop()
    }

    /// No further qualifying movement for dragMoveFootstepIdle: silence.
    private func scheduleDragMoveFootstepIdleStop() {
        dragMoveFootstepToken &+= 1
        let token = dragMoveFootstepToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.dragMoveFootstepIdle))
            guard let self, self.dragMoveFootstepToken == token, self.freeDragMoveActive || self.isFreePanning else { return }
            self.setFreeWalkFootsteps(false)
        }
    }

    // Oct 2 (pan pivot != walking): the one-finger Free Walk pan turns with
    // dx AND moves with dy at once, and a finger swiping sideways to pivot
    // always drifts a little vertically -- each point of dy is ~2.5 cm of real
    // translation. Footsteps mean TRANSLATIONAL walking, so the pan (only)
    // classifies over a short window instead of per 4 mm:
    //   - travel = the actual post-collision displacement projected on the
    //     camera's forward axis (signed: + forward loop, - reverse loop);
    //   - it must reach panFootstepMinTravel within panFootstepWindow
    //     (slow incidental drift never accumulates into a "walk");
    //   - and the finger's vertical motion in that window must be a real
    //     share of its horizontal motion (panFootstepStartRatio to start,
    //     the looser panFootstepKeepRatio to keep walking while steering).
    // Pure pivot (dy == 0) moves nothing and is silent; wall-blocked travel
    // projects to ~0 and goes silent after the usual idle delay.
    private var panFootstepWindowStart: TimeInterval = 0
    private var panFootstepTravel: Double = 0
    private var panFootstepFingerDx: Double = 0
    private var panFootstepFingerDy: Double = 0
    private var freePanLastDx: Double = 0
    static let panFootstepWindow: TimeInterval = 0.25
    static let panFootstepMinTravel: Double = 0.06      // m, ~2.4 pt of finger dy
    static let panFootstepStartRatio: Double = 0.35     // |dy| >= 0.35 |dx| (within ~70 deg of vertical)
    static let panFootstepKeepRatio: Double = 0.15

    private func resetPanFootstepWindow(at now: TimeInterval) {
        panFootstepWindowStart = now
        panFootstepTravel = 0
        panFootstepFingerDx = 0
        panFootstepFingerDy = 0
    }

    private func updateFreePanFootsteps(fingerDx: Double, fingerDy: Double, forwardTravel: Double) {
        guard manualFootstepsFromAutoWalk else { return } // Oct 2: standing pan is silent
        let now = ProcessInfo.processInfo.systemUptime
        if now - panFootstepWindowStart > Self.panFootstepWindow { resetPanFootstepWindow(at: now) }
        panFootstepFingerDx += abs(fingerDx)
        panFootstepFingerDy += abs(fingerDy)
        panFootstepTravel += forwardTravel
        let ratio = freeWalkFootstepsOn ? Self.panFootstepKeepRatio : Self.panFootstepStartRatio
        guard abs(panFootstepTravel) >= Self.panFootstepMinTravel,
              panFootstepFingerDy >= ratio * panFootstepFingerDx else { return }
        let reverse = panFootstepTravel < 0
        resetPanFootstepWindow(at: now)
        setFreeWalkFootsteps(true, reverse: reverse)
        scheduleDragMoveFootstepIdleStop()
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
        if freeDragMoveActive {
            // FREE-WALK: the scrub already put the body where the finger
            // left it. Stay exactly there: no flick projection, no glide to
            // a cell center, no yaw change. Cell entry already ran through
            // freeWalkTrackCell during the scrub.
            freeDragMoveActive = false
            dragMoveFootstepToken &+= 1
            manualFootstepsFromAutoWalk = false
            setFreeWalkFootsteps(false)
            logNavSync("DRAG MOVE RELEASE (free) — stays at \(cameraNode.position)")
            navLog("endDragMove(free) kept \(cameraNode.position) in \(currentCell) facing \(facing)")
            return
        }
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
        // Oct 16 (WALK LATCH): a finger lifting off a latched walk -- the turn it
        // was still asking for is finished, and the walk keeps its pace.
        if !held, walkLatched, heldSteeringActive, heldSteeringYaw != heldSteeringTargetYaw {
            latchTurnTarget = Double(cameraNode.eulerAngles.y) + (heldSteeringTargetYaw - heldSteeringYaw)
        }
        if held { latchTurnTarget = nil; latchStall = 0 }
        walkingHeld = held
        heldSteeringActive = false
        heldThrottle = 1
        if held {
            decorateHeldStepTaken = false
        } else {
            if !walkLatched { heldDistance = 0 }
            heldBlockedFireCoord = nil
            manualFootstepsFromAutoWalk = false // the takeover hold (if any) is over
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

    /// Returns true ONLY when this tick found the held walk at a genuine
    /// endpoint: idle, no forward connection, and not exactly one side
    /// exit to auto-turn into (i.e. a dead end, or two side exits that
    /// still wait for the player). Every other outcome -- walking,
    /// auto-turning an unambiguous L, busy animating, the DECORATE
    /// one-step cap, standing in a just-arrived elevator -- returns
    /// false, exactly as before this return value existed.
    @discardableResult
    func advanceWhileHeld() -> Bool {
        logNavAttempt(path: "HELD")
        // Oct 2 (auto-walk -> long-press handoff): a hold during a running
        // tap-to-point walk takes manual control at once instead of being
        // refused by canRotate below until the auto-walk ends.
        if takeOverFreeTapWalkForHold() { return false }
        guard canRotate else { return false }
        // FREE-WALK EXPERIMENT: one continuous renderer-driven walk for the
        // whole hold (never a chain of planned runs), so no stop cells, no
        // intersection stops, no L-turns and no endpoint state.
        if freeWalkApplies(held: true) {
            beginFreeHeldWalk()
            return false
        }
        // Sept 22 (DECORATE one-cell hold fix): once this hold gesture
        // has already taken its one legal step, ignore further HELD
        // ticks from the timer entirely -- no forward advance, no
        // auto-turn-at-corner below -- until the finger lifts and a new
        // hold begins (setWalkingHeld(true) clears the flag). PLAY mode
        // (decorateModeEnabled == false) never hits this guard.
        if decorateModeEnabled, decorateHeldStepTaken { return false }
        if canGoForward {
            advance(source: "HELD")
            if decorateModeEnabled { decorateHeldStepTaken = true }
            return false
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
        guard elevatorAwaitingEntryDirection == nil else { return false }
        let turns = [facing.left, facing.right].filter { openDirections.contains($0) }
        // Starting against a wall works just like arriving at one: exactly
        // one side exit is unambiguous, regardless of the passage behind us.
        // Two side exits wait for a swipe; never choose a U-turn automatically.
        guard turns.count == 1 else {
            navLog("held walk reached its endpoint at \(currentCell) facing \(facing) (side exits: \(turns))")
            return true
        }
        logNavSync("HELD FORCED TURN — about to turn toward \(turns[0])")
        navLog("held walk turning at \(currentCell) from \(facing) toward \(turns[0])")
        rotate(toward: turns[0])
        return false
    }

    // MARK: - Held-walk endpoint look (Sept 28)
    //
    // When a held walk reaches its endpoint (advanceWhileHeld() returns
    // true) the SAME finger keeps working: horizontal movement drives the
    // ordinary Free Look drag (beginDragRotate/updateDragRotate/
    // endDragRotate -- no second rotation system). The finger's position
    // at the stop becomes the new zero, so drift during the walk never
    // turns the camera. The walk itself is over: nothing here ever walks,
    // and a new walk needs a lift and a new gesture.

    /// True from the endpoint until the finger lifts (or a reset).
    private(set) var heldEndpointLookActive = false
    private var heldEndpointOriginX: Double = 0
    private var heldEndpointPointsPerQuarterTurn: Double = 140

    /// Enters endpoint look with `fingerX` as the horizontal origin and
    /// the camera's current yaw as the base. Ends the held walk (no more
    /// walking this gesture). Returns false if a look drag can't start.
    @discardableResult
    func beginHeldEndpointLook(fingerX: Double, pointsPerQuarterTurn: Double) -> Bool {
        guard !heldEndpointLookActive, pointsPerQuarterTurn > 0 else { return false }
        beginDragRotate()
        guard isDragRotating else { return false }
        heldEndpointLookActive = true
        heldEndpointOriginX = fingerX
        heldEndpointPointsPerQuarterTurn = pointsPerQuarterTurn
        setWalkingHeld(false)
        navLog("held endpoint look began at x=\(String(format: "%.1f", fingerX)) yaw=\(String(format: "%.3f", Double(cameraNode.eulerAngles.y)))")
        return true
    }

    /// Horizontal finger movement since the endpoint, as the same
    /// quarter-turn fraction an ordinary horizontal drag uses.
    private func heldEndpointFraction(_ fingerX: Double) -> Double {
        (fingerX - heldEndpointOriginX) / heldEndpointPointsPerQuarterTurn
    }

    func updateHeldEndpointLook(fingerX: Double) {
        guard heldEndpointLookActive else { return }
        updateDragRotate(fraction: heldEndpointFraction(fingerX))
    }

    /// Finger lifted: the ordinary Free Look release (camera stays at the
    /// final yaw, logical facing = nearest cardinal). No flick velocity.
    func endHeldEndpointLook(fingerX: Double) {
        guard heldEndpointLookActive else { return }
        heldEndpointLookActive = false
        endDragRotate(fraction: heldEndpointFraction(fingerX), velocityFraction: 0)
        navLog("held endpoint look ended")
    }

    /// The forward D-pad button (and a bare tap): walks from currentCell
    /// in whatever direction you're currently facing, all the way to
    /// the next real decision, dead end, or the target. `source` is
    /// purely diagnostic (see logNavAttempt above) -- defaults to "TAP"
    /// so every existing call site (the tap gesture, the D-pad button)
    /// is unaffected; advanceWhileHeld() is the only caller that passes
    /// "HELD", when its own forward check already succeeded.
    /// `travelDirection` (TAP WHERE YOU WANT TO GO, Sept 30): the horizontal
    /// bearing of the tapped screen point; nil = camera forward (as before).
    /// `travelDistance` (TAP A PLACE -> GO THERE, Sept 30): horizontal metres
    /// to the tapped world point; nil = the one-cell tap (fallback).
    /// `finalYaw` (Oct 1, tap-to-approach): the exact yaw to finish facing,
    /// turned to over the usual tap-turn time; nil = face the travel bearing.
    func advance(source: String = "TAP", travelDirection: (x: Double, z: Double)? = nil, travelDistance: Double? = nil, finalYaw: Double? = nil) {
        logNavAttempt(path: source)
        // FREE-WALK EXPERIMENT: an ordinary tap walks along the camera's
        // actual yaw instead of the cardinal grid planner below.
        if source == "TAP", freeWalkApplies(held: false) {
            beginFreeWalkTap(travelDirection: travelDirection, travelDistance: travelDistance, finalYaw: finalYaw)
            return
        }
        guard canGoForward else {
            if canRotate, isBlockedByCharacter(from: currentCell, direction: facing) {
                onCharacterBlockBump?()                                  // Oct 9: Juanita, not a wall
            } else if forwardIsBlockedByWall { SoundEffects.playHitWall() }
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
                if isBlockedByCharacter(from: previousCell, direction: step.heading) {
                    gatedSteps = Array(steps[0..<index])
                    gatedOutcome = .steppedForward
                    break
                }
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
            ceremonialElevatorAutoOpen = true
        }
        phase = .translate
        // Free look: straighten to `facing` first if looking elsewhere.
        alignCameraToFacingBeforeTranslate()
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
        // Free look: straighten to `facing` first (backing up keeps facing).
        alignCameraToFacingBeforeTranslate()
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
        stopContinuousWalk(reason: "reset")
        walkLatched = false                                         // (Oct 16)
        latchTurnTarget = nil
        setWalkingHeld(false)
        heldEndpointLookActive = false
        freeDragMoveActive = false
        isFreePanning = false
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
        if carryingExtinguisher { ToolBelt.dropHallwayExtinguisher(animated: false) }
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

        elevatorBoardedDoorsOpen = false
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
                    self.lastPickedExtinguisherCoord = coord        // (Oct 13: where a swipe puts it back)
                    self.refreshFloorMapTexture()
                    // Oct 16 (II): into a hand, through the tool system -- the one and only
                    // carried extinguisher (the old camera-attached copy is gone).
                    ToolBelt.holdHallwayExtinguisher()
                    self.carryingExtinguisher = true
                    self.extinguisherPickupInProgress = false
                    SoundEffects.playExtinguisherGrab()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.showBrief("Extinguisher ready. Tap a fire to put it out.", seconds: 4)   // (Oct 16: goes by itself)
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
        // Oct 16 (Supplies II): it takes a hand -- with two tools carried, the hands are full.
        if ToolBelt.isFull {
            Supplies.refuse(nil, controller: self)
            return true
        }
        collectExtinguisherIfPresent(at: coord)
        return extinguisherPickupInProgress
    }

    /// Oct 11: puts the carried extinguisher back on the empty bracket at
    /// `coord` (where it was taken from) -- the reverse of the pickup. Fires
    /// already out stay out; it can be taken again.
    @discardableResult
    func returnExtinguisher(at coord: GridCoordinate) -> Bool {
        guard canRotate, carryingExtinguisher, extinguishingFireCoords.isEmpty, !extinguisherPickupInProgress,
              pickedUpExtinguisherCoords.contains(coord), let wallNode = extinguisherNodes[coord] else { return false }
        ToolBelt.dropHallwayExtinguisher(animated: false)
        carryingExtinguisher = false
        pickedUpExtinguisherCoords.remove(coord)
        wallNode.removeAllActions()
        if let resting = extinguisherRestingTransforms[coord] {
            wallNode.position = resting.position
            wallNode.eulerAngles = resting.eulerAngles
            wallNode.scale = resting.scale
        }
        wallNode.opacity = 0
        if wallNode.parent == nil { scene?.rootNode.addChildNode(wallNode) }
        wallNode.runAction(.fadeIn(duration: 0.2))
        refreshFloorMapTexture()
        SoundEffects.playExtinguisherGrab()
        diag("extinguisher.returned", ["cell": coord])
        return true
    }

    // MARK: Oct 13 -- swipe the held extinguisher away (back to its bracket)

    private var lastPickedExtinguisherCoord: GridCoordinate?

    /// The held extinguisher's area on screen (its projected bounds, a little
    /// enlarged for a finger), or nil when nothing is held.
    func heldExtinguisherScreenRect(in view: SCNView) -> CGRect? {
        guard carryingExtinguisher else { return nil }
        // Oct 16 (II): held in a hand -- its drawn shape and its hand's corner.
        return ToolBelt.hallwayExtinguisherRect(in: view)
    }

    /// A swipe up that began on the held extinguisher: it goes back on the
    /// bracket it came from (wherever the player is) -- the same restoring
    /// RETURN does in front of the bracket. Fires already out stay out.
    @discardableResult
    func putAwayExtinguisher() -> Bool {
        guard carryingExtinguisher, extinguishingFireCoords.isEmpty, !extinguisherPickupInProgress,
              !isSeatedAtComputer, !isSeatedInMeeting, !isElevatorRideInProgress else { return false }
        let coord = lastPickedExtinguisherCoord.flatMap { pickedUpExtinguisherCoords.contains($0) ? $0 : nil }
            ?? pickedUpExtinguisherCoords.first(where: { extinguisherNodes[$0] != nil })
        ToolBelt.dropHallwayExtinguisher(animated: true)
        carryingExtinguisher = false
        // Oct 16 (II): never stuck in hand -- with no bracket to go back to (its
        // fixture was removed meanwhile), it still leaves the hand.
        guard let coord, let wallNode = extinguisherNodes[coord] else {
            diag("extinguisher.putAwayNoBracket", ["playerCell": currentCell])
            return true
        }
        pickedUpExtinguisherCoords.remove(coord)
        wallNode.removeAllActions()
        if let resting = extinguisherRestingTransforms[coord] {
            wallNode.position = resting.position
            wallNode.eulerAngles = resting.eulerAngles
            wallNode.scale = resting.scale
        }
        wallNode.opacity = 0
        if wallNode.parent == nil { scene?.rootNode.addChildNode(wallNode) }
        wallNode.runAction(.fadeIn(duration: 0.3))
        refreshFloorMapTexture()
        diag("extinguisher.putAway", ["cell": coord, "playerCell": currentCell])
        return true
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

    /// Preserve legacy nearby taps, and also reach a fire from its freeform
    /// stand-off pose. A small tolerance covers SceneKit float rounding.
    func canReachFire(at coord: GridCoordinate) -> Bool {
        if canReachFireFixture(at: coord) { return true }
        guard let fire = fireNodes[coord], fire.parent != nil else { return false }
        let player = cameraNode.worldPosition, target = fire.worldPosition
        let dx = Double(target.x - player.x), dz = Double(target.z - player.z)
        guard hypot(dx, dz) <= Double(cellSize) + 0.02 else { return false }
        // Test the physical line without requiring the player's whole body
        // to fit along the spray ray; closed walls/doors still block it.
        var geometry = makeFreeWalkGeometry(blockingActiveFires: false)   // the spray reaches into the fire's cell
        geometry.wallMargin = 0.05
        guard geometry.isLegal(x: Double(player.x), z: Double(player.z)) else { return false }
        let end = geometry.legalEndpoint(from: player, to: SCNVector3(target.x, player.y, target.z))
        return hypot(Double(end.x - target.x), Double(end.z - target.z)) < 0.02
    }

    /// Oct 4 FREDDY SLICE: a living extinguisher puts this fire out. The
    /// same flame knock-down and the same bookkeeping as a player spray
    /// (extinguishedFireCoords, floor map, "fire out" sound), but no player
    /// spray cone, no messages, no carried-extinguisher requirement, and it
    /// never pauses navigation (extinguishingFireCoords is left alone).
    @discardableResult
    func creatureExtinguishFire(at coord: GridCoordinate) -> Bool {
        guard fireCoords.contains(coord), !extinguishedFireCoords.contains(coord),
              !extinguishingFireCoords.contains(coord), !creatureExtinguishingFireCoords.contains(coord),
              let fire = fireNodes[coord], fire.parent != nil, !fire.isHidden else { return false }
        creatureExtinguishingFireCoords.insert(coord)
        let interactionID = fireInteractionID
        fire.removeAllActions()
        fire.runAction(.sequence([
            .group([
                .sequence([
                    .scale(to: 0.8, duration: 0.25), .scale(to: 0.6, duration: 0.22), .scale(to: 0.8, duration: 0.27),
                    .scale(to: 0.6, duration: 0.22), .scale(to: 0.4, duration: 0.25), .scale(to: 0.6, duration: 0.27),
                    .scale(to: 0.4, duration: 0.22), .scale(to: 0.8, duration: 0.41), .scale(to: 0.4, duration: 0.30),
                    .scale(to: 0.2, duration: 0.25), .scale(to: 0.4, duration: 0.22), .scale(to: 0.2, duration: 0.25)
                ]),
                .sequence([
                    .wait(duration: 0.25),
                    .fadeOpacity(to: 0.7, duration: 0.12),
                    .fadeIn(duration: 0.12),
                    .fadeOpacity(to: 0.35, duration: 0.18)
                ])
            ]),
            .group([.scale(to: 0.08, duration: 0.38), .fadeOut(duration: 0.38)]),
            .hide(),
            .run { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.creatureExtinguishingFireCoords.remove(coord)
                    guard self.fireInteractionID == interactionID else { return }
                    self.extinguishedFireCoords.insert(coord)
                    self.refreshFloorMapTexture()
                    SoundEffects.playFireExtinguished()
                    diag("fire.creatureExtinguished", ["row": coord.row, "col": coord.col])
                }
            }
        ]))
        return true
    }
    private var creatureExtinguishingFireCoords: Set<GridCoordinate> = []

    @discardableResult
    func extinguishFire(at coord: GridCoordinate) -> Bool {
        guard canRotate, canReachFire(at: coord),
              fireCoords.contains(coord), !extinguishedFireCoords.contains(coord),
              let fire = fireNodes[coord], fire.parent != nil else { return false }
        // Oct 16 (Supplies): a fire extinguisher from Supplies, carried, does exactly what a wall one does.
        guard carryingExtinguisher || ToolBelt.carries(.extinguisher) else {
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
        ToolBelt.extinguisherInUse(seconds: 3.4)                       // Oct 16 (V): tray -- the extinguisher is seen, spraying
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
                    if !(self.isMissionComplete && !Self.missionGatesElevator) {   // Oct 4: see photo booth
                        self.showMessage(self.isMissionComplete ? "All fires out! Return to the elevator." : "\(self.fireMissionProgress ?? "Fire extinguished.")")
                    }
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

    /// Oct 7 (I): the hallway call panel beside the elevator (its brass plate
    /// and both call buttons, every floor -- HallwayScene builds the same
    /// "elevatorExteriorCallPanel" into each floor's single elevator
    /// entrance). A tap on it is the same request as a tap on the doors, so
    /// ContentView routes both through the one exterior-door path. Before
    /// this, a panel hit matched nothing, fell through to an ordinary tap
    /// walk into the wall, and all the player got was the wall thump.
    func isElevatorCallPanel(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let current = n {
            if current.name == "elevatorExteriorCallPanel" { return true }
            if current.name == "elevatorExteriorFrame" { return false }
            n = current.parent
        }
        return false
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
        // Oct 25: the shared looks (HallwayScene.ElevatorButtonLook) -- this one keeps its softer glow.
        let normalMaterial = HallwayScene.ElevatorButtonLook.unselected()
        let activeMaterial = HallwayScene.ElevatorButtonLook.selected(glow: HallwayScene.ElevatorButtonLook.softGlow)

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
        guard canRotate, !openBathroomDoors.contains(coord), bathroomDoors[coord] != nil, isAdjacentToBathroomDoor(coord) else { return }
        swingBathroomDoorOpen(at: coord)
    }

    /// Oct 10: the swing itself, shared by a tap/OPEN at the door and a
    /// continuous walk arriving at it (its own guards stay with the caller).
    private func swingBathroomDoorOpen(at coord: GridCoordinate) {
        guard !openBathroomDoors.contains(coord), let doorDirection = bathroomDoors[coord] else { return }
        openBathroomDoors.insert(coord)
        if let hinge = scene?.rootNode.childNode(withName: "bathroomDoor_\(coord.row)_\(coord.col)", recursively: true) {
            let swing = SCNAction.rotateBy(x: 0, y: bathroomDoorSwingAngle(for: doorDirection), z: 0, duration: 0.5)
            swing.timingMode = .easeOut
            hinge.runAction(swing)
        }
        UISelectionFeedbackGenerator().selectionChanged()
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
        guard canRotate, !openWindowRoomDoors.contains(coord), windowRooms[coord] != nil, isAdjacentToWindowRoomDoor(coord) else { return }
        swingWindowRoomDoorOpen(at: coord)
    }

    /// Oct 10: shared swing (see swingBathroomDoorOpen).
    private func swingWindowRoomDoorOpen(at coord: GridCoordinate) {
        guard !openWindowRoomDoors.contains(coord), let doorDirection = windowRooms[coord]?.direction else { return }
        openWindowRoomDoors.insert(coord)
        if let hinge = scene?.rootNode.childNode(withName: "windowRoomDoor_\(coord.row)_\(coord.col)", recursively: true) {
            let swing = SCNAction.rotateBy(x: 0, y: bathroomDoorSwingAngle(for: doorDirection), z: 0, duration: 0.5)
            swing.timingMode = .easeOut
            hinge.runAction(swing)
        }
        UISelectionFeedbackGenerator().selectionChanged()
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
            // Oct 5: a Double Glass entrance's second leaf counts as the door too.
            if let name = current.name, let prefix = ["roomEntranceDoor_", "roomEntranceDoorPair_"].first(where: { name.hasPrefix($0) }) {
                let parts = name.dropFirst(prefix.count).split(separator: "_")
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
        // Oct 6 (Fredo, "kiosk first"): someone on the other side may answer
        // the door instead (FredDoorGuard). True = handled; nothing opens.
        // Oct 9: belt and braces -- whatever path reaches here, a guarded
        // door never opens for the player.
        if roomEntranceDoorGuarded?(coord) == true {
            guardedRoomEntranceDoorTapped(coord)
            return
        }
        if let intercept = roomEntranceDoorIntercept, intercept(coord) {
            diag("roomEntranceDoor.intercepted", ["row": coord.row, "col": coord.col])
            return
        }
        swingRoomEntranceDoorOpen(at: coord)
    }

    /// Oct 10: the swing itself, shared by the player's own open (above, after
    /// its guarded/intercept checks) and a continuous walk arriving at the
    /// door (continuousWalkReachedDoor runs the same two checks first).
    private func swingRoomEntranceDoorOpen(at coord: GridCoordinate) {
        guard !openRoomEntranceDoors.contains(coord), let doorDirection = roomEntranceDoors[coord] else { return }
        openRoomEntranceDoors.insert(coord)
        onRoomEntranceDoorOpened?(coord)                    // Oct 11 (MeetingProcession)
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
        // Oct 5: a Double Glass entrance's second leaf swings the mirror way.
        if let pair = scene?.rootNode.childNode(withName: "roomEntranceDoorPair_\(coord.row)_\(coord.col)", recursively: true) {
            let swing = SCNAction.rotateBy(x: 0, y: -bathroomDoorSwingAngle(for: doorDirection), z: 0, duration: 0.5)
            swing.timingMode = .easeOut
            pair.runAction(swing)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Oct 6 (Candy goes home): the doors cycle for a character on his own --
    /// the ding, the same open/close slide as boarding, `boarding` while they
    /// stand open (it must call its `done`), then they close and
    /// `completion` runs. The player can't board meanwhile; nothing else of
    /// the elevator (ride, cab, panel, camera) is involved. False if the car
    /// isn't idle with both doors shut.
    @discardableResult
    func runCharacterElevatorDeparture(who: String = "a character", purpose: CharacterElevatorPurpose = .other,
                                       resident: Bool = false,
                                       willOpen: (() -> Void)? = nil,
                                       boarding: @escaping (@escaping () -> Void) -> Void,
                                       completion: @escaping () -> Void) -> Bool {
        carOnItsWay = false
        guard !characterUsingElevator, !elevatorInUse, !chuteInUse, !arrivedElevatorDoorOpen,
              elevatorAwaitingEntryDirection == nil,
              let left = elevatorLeftDoor, let right = elevatorRightDoor, let direction = elevatorMountDirection,
              let leftClosed = elevatorLeftClosedPosition, let rightClosed = elevatorRightClosedPosition,
              left.action(forKey: "arrivalCloseBehind") == nil, right.action(forKey: "arrivalCloseBehind") == nil else {
            let reason = characterElevatorRefusal ?? "unknown"
            diag("elevator.character.refused", ["reason": reason])
            elevatorLog("character door cycle refused (\(who)): \(reason)")
            return false
        }
        // Oct 19 (one car): only with the actual car standing here. Elsewhere it's
        // called for this character and the cycle is refused for now ("the car is
        // on its way") -- the caller tries again, as for any busy elevator.
        if let gate = carGate, !gate(floorNumber, "script:" + who) {
            carOnItsWay = true
            diag("elevator.character.refused", ["reason": "the car is on its way"])
            elevatorLog("character door cycle for \(who): the car isn't here -- called it")
            return false
        }
        carOnItsWay = false
        let doorsWereShut = elevatorDoorsShut
        left.removeAction(forKey: Self.carDoorsActionKey)
        right.removeAction(forKey: Self.carDoorsActionKey)
        carDoorsTarget = nil
        characterUsingElevator = true
        // (Oct 19: carOnItsWay is reset at the top of every request)
        // Oct 18 (inter-floor life): what this cycle is, for the ELEVATOR panel and
        // the hall indicator -- a record of THIS cycle's own steps, nothing more.
        setCharacterElevatorPhase("chime, doors opening", who: who, purpose: purpose)
        // Oct 18 (building life): the cycle ends exactly once -- when the doors'
        // close finishes, or at the latest after characterElevatorLimit (a
        // scene that stopped running its actions -- behind the Grid Editor, say
        // -- must never leave the elevator held for good). On the watchdog the
        // doors are put back shut at once and `completion` runs; a scene that
        // is already gone (no controller) is left alone, as before.
        characterElevatorCycle += 1
        let cycle = characterElevatorCycle
        let state = CharacterElevatorCycleState()
        state.joinable = resident                              // (Oct 19: a resident's doors the player may step through)
        currentCharacterCycle = state
        let end: (String) -> Void = { [weak self] how in
            guard !state.ended, let self else { return }
            state.ended = true
            if self.characterElevatorCycle == cycle {
                self.characterUsingElevator = false
                self.setCharacterElevatorPhase(nil, who: nil, purpose: nil)
                self.answerQueuedPlayerCall()
            }
            diag(how == "closed" ? "elevator.character.closed" : how == "joined" ? "elevator.character.joined" : "elevator.character.watchdog", ["cycle": cycle])
            elevatorLog(how == "closed" ? "character door cycle \(cycle) closed"
                        : how == "joined" ? "character door cycle \(cycle) ended with the doors open: the player is getting in too"
                                        : "character door cycle \(cycle) WATCHDOG: doors snapped shut after \(Int(Self.characterElevatorLimit))s")
            completion()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.characterElevatorLimit) { [weak self] in
            guard !state.ended, self != nil else { return }
            if state.yielded { end("joined"); return }          // (the player's doors now: never snapped shut)
            left.removeAllActions()
            right.removeAllActions()
            left.position = leftClosed
            right.position = rightClosed
            end("watchdog")
        }
        let alongWallX: Float, alongWallZ: Float
        switch direction {
        case .north, .south: (alongWallX, alongWallZ) = (1, 0)
        case .east, .west: (alongWallX, alongWallZ) = (0, 1)
        }
        let slide: Float = 0.8
        let duration: TimeInterval = 1.6
        let leftOpen = SCNVector3(leftClosed.x - slide * alongWallX, leftClosed.y, leftClosed.z - slide * alongWallZ)
        let rightOpen = SCNVector3(rightClosed.x + slide * alongWallX, rightClosed.y, rightClosed.z + slide * alongWallZ)
        func move(_ node: SCNNode, _ to: SCNVector3) -> SCNAction {
            let a = SCNAction.move(to: to, duration: duration)
            a.timingMode = .easeInEaseOut
            return a
        }
        // Oct 9: a CHARACTER's elevator call is a building sound heard from
        // wherever the player is -- quieter with distance and behind walls or
        // a shut door. (The player's own rides keep calling
        // playElevatorArrival() at full volume.)
        var chimeGain: Float = 1
        if let frame = elevatorDoorwayFrame() {
            let outside = frame.center + frame.outward * Float(cellSize) * 0.5     // the elevator's hallway cell
            chimeGain = CritterAudio.buildingGain(at: SIMD3<Float>(outside.x, 1.5, outside.y))
        }
        if doorsWereShut { SoundEffects.playElevatorArrival(gain: chimeGain) }    // (Oct 19: the car's doors already open: it's here, no second chime)
        let delay = SCNAction.wait(duration: doorsWereShut ? SoundEffects.elevatorDoorOpeningDelay : 0)
        diag("elevator.character.opening", ["chimeGain": Double(chimeGain)])
        elevatorLog("character door cycle \(cycle) opening for \(who) on floor \(floorNumber) (chime gain \(String(format: "%.2f", chimeGain)))")
        LifeLog.event(who, "elevator.doorCycle", floor: floorNumber, ["cycle": cycle, "chimeGain": Double(chimeGain)])
        // Oct 19: whoever is coming out appears as the doors start to part (never popping in after).
        let parting = SCNAction.run { _ in DispatchQueue.main.async { if !state.ended { willOpen?() } } }
        left.runAction(.sequence([delay, parting, move(left, leftOpen)]))
        right.runAction(.sequence([delay, move(right, rightOpen)])) { [weak self] in
            DispatchQueue.main.async {
                guard !state.ended else { return }                   // (the watchdog already ended it)
                if !state.yielded { self?.setCharacterElevatorPhase(purpose.isArrival ? "doors open: \(who) stepping out" : "doors open: \(who) boarding",
                                                who: who, purpose: purpose) }
                boarding {
                    guard self != nil else { completion(); return }
                    guard !state.ended else { return }
                    if state.yielded { end("joined"); return }      // (Oct 19: the player has the doors: they close with their ride)
                    state.closing = true
                    self?.setCharacterElevatorPhase("doors closing", who: who, purpose: purpose)
                    left.runAction(move(left, leftClosed))
                    right.runAction(move(right, rightClosed)) {
                        DispatchQueue.main.async { end("closed") }
                    }
                }
            }
        }
        return true
    }
    /// Oct 6: true while a character's door cycle runs (the player can't board).
    private(set) var characterUsingElevator = false
    /// Oct 18 (inter-floor life): the running character door cycle -- who, what
    /// for, which of its steps, since when (nil: none running). Set only by
    /// runCharacterElevatorDeparture's own steps; read by the ELEVATOR panel.
    private(set) var characterElevatorCycleInfo: (who: String, purpose: CharacterElevatorPurpose, phase: String, since: Date)?
    /// Oct 18 (elevator life): the player tapped while a character had the doors:
    /// answered when that cycle ends (if within 20 s and they're still there).
    private(set) var playerCallPending = false
    private var playerCallAt: Date?

    private func answerQueuedPlayerCall() {
        guard playerCallPending else { return }
        playerCallPending = false
        guard let at = playerCallAt, Date().timeIntervalSince(at) < 20, currentCell == endCell else {
            elevatorLog("queued player call dropped (stale or the player walked away)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.characterUsingElevator, !self.elevatorInUse, self.currentCell == self.endCell else { return }
            elevatorLog("answering the queued player call")
            self.openElevator()
        }
    }

    /// Oct 18: what the hall's floor indicator was last set to (nil: as built).
    var hallIndicatorShown: (floor: Int, direction: Int)?
    var hallIndicatorLitMaterial: SCNMaterial?

    private func setCharacterElevatorPhase(_ phase: String?, who: String?, purpose: CharacterElevatorPurpose?) {
        if let phase, let who, let purpose {
            characterElevatorCycleInfo = (who, purpose, phase, Date())
            LifeLog.event(who, "elevator.phase", floor: floorNumber, ["phase": phase, "purpose": purpose.text])
        } else {
            characterElevatorCycleInfo = nil
        }
        // (Oct 19: the hall sign and the ELEVATOR panel follow the car, four times a second.)
    }
    /// Oct 18 (diagnostics): why runCharacterElevatorDeparture would refuse right
    /// now (nil: it wouldn't) -- the first of its conditions that fails.
    var characterElevatorRefusal: String? {
        if carOnItsWay { return "the car is on its way" }
        if characterUsingElevator { return "another character's door cycle is running" }
        if elevatorInUse { return "the player's elevator is in use" }
        if chuteInUse { return "the chute is in use" }
        if arrivedElevatorDoorOpen { return "the player's arrival doors are open" }
        if elevatorAwaitingEntryDirection != nil { return "the player is stepping in" }
        if elevatorLeftDoor == nil || elevatorRightDoor == nil || elevatorMountDirection == nil
            || elevatorLeftClosedPosition == nil || elevatorRightClosedPosition == nil { return "no elevator doors on this floor" }
        if elevatorLeftDoor?.action(forKey: "arrivalCloseBehind") != nil || elevatorRightDoor?.action(forKey: "arrivalCloseBehind") != nil {
            return "the doors are closing behind the player"
        }
        return nil
    }
    /// Oct 18: which character door cycle is current (the watchdog's guard).
    private var characterElevatorCycle = 0
    /// Oct 18: a character's door cycle is over by this long after it began,
    /// whatever SceneKit did (it normally takes about 4-8 s).
    static var characterElevatorLimit: TimeInterval = 20
    private final class CharacterElevatorCycleState {
        var ended = false
        /// Its doors have begun to close (too late for the player to join).
        var closing = false
        /// Oct 19: the player got in too: the doors are theirs now -- the cycle
        /// ends when its character is in (or out), without closing them.
        var yielded = false
        /// A resident's (not a scripted character's): the player may join it.
        var joinable = false
    }
    private var currentCharacterCycle: CharacterElevatorCycleState?

    /// Oct 19 (sharing the car): a resident's door cycle the player can step into
    /// -- running, its doors open or opening, not yet closing.
    var characterCycleJoinable: Bool {
        guard characterUsingElevator, let c = currentCharacterCycle else { return false }
        return !c.ended && !c.closing && !c.yielded && c.joinable
    }

    /// The player is boarding through a resident's open doors: the cycle lets
    /// them go (it won't close them, its watchdog won't snap them shut) and the
    /// elevator is the player's from here; the resident still gets in (or out).
    private func yieldCharacterCycleToPlayer() {
        guard let c = currentCharacterCycle, characterCycleJoinable else { return }
        c.yielded = true
        characterUsingElevator = false
        let who = characterElevatorCycleInfo?.who ?? "a resident"
        setCharacterElevatorPhase(nil, who: nil, purpose: nil)
        diag("elevator.character.joinedByPlayer", ["who": who])
        elevatorLog("character door cycle for \(who): the player is getting in too -- the doors stay open for them")
    }

    // MARK: Oct 19 -- the one car (ElevatorScheduler.swift)

    /// Is the car standing here for `who` ("player", "script:<name>")? True: its
    /// doors are theirs now. False: it isn't here -- it has been called instead.
    /// (nil: no building car -- a test's lone controller: as before.)
    var carGate: ((_ floor: Int, _ who: String) -> Bool)?
    /// The player's ride is setting off (from, to): the car runs with them.
    var onElevatorTravel: ((_ from: Int, _ to: Int) -> Void)?
    /// A character's door cycle was refused because the car was called instead.
    private(set) var carOnItsWay = false
    static let carDoorsActionKey = "carDoors"
    /// What the building's doors were last told to do here (nil: nothing yet / taken over).
    private var carDoorsTarget: Bool?

    /// The player is in the cab (boarding, waiting for a floor, riding, or
    /// standing in an arrived cab) -- not merely near it.
    var playerInCab: Bool {
        elevatorInUse || isElevatorWaitingForFloor || elevatorAwaitingEntryDirection != nil
    }

    /// The player is standing at this floor's elevator (its hallway cell).
    var playerAtElevatorCell: Bool { currentCell == endCell && !playerInCab }

    /// The doors closing behind the player after they stepped out are still moving.
    var doorsClosingBehindPlayer: Bool {
        elevatorLeftDoor?.action(forKey: "arrivalCloseBehind") != nil || elevatorRightDoor?.action(forKey: "arrivalCloseBehind") != nil
    }

    /// How far open the doors are as drawn now (0 shut .. 1 fully open).
    var elevatorDoorsOpenFraction: Double {
        guard let right = elevatorRightDoor, let rc = elevatorRightClosedPosition else { return 0 }
        let r: SCNVector3
        if let f = presentationSnapshot.fresh(), f.hasRightDoor {
            r = SCNVector3(f.rightDoor)                                    // Oct 25 (PP 8): the door as last drawn -- no scene-lock wait
        } else {
            let scnT = pthread_main_np() != 0 ? FrameTiming.start() : 0   // Oct 24: SceneKit wait, main only (measurement)
            r = right.presentation.position                                // (no fresh frame: before the first, or not rendering)
            FrameTiming.shared.record(.scnDoorFrac, since: scnT)
        }
        return min(1, max(0, Double(hypotf(r.x - rc.x, r.z - rc.z)) / 0.8))
    }

    /// Oct 25 (PP 8): the player camera as last drawn -- its presentation world position and yaw (Euler Y) --
    /// from the per-frame snapshot, with no wait on SceneKit's scene lock. No fresh frame (before this scene's
    /// first, or nothing rendering): read directly, exactly as the callers used to.
    func drawnPlayerPose() -> (position: SIMD3<Float>, yaw: Float) {
        if let f = presentationSnapshot.fresh() { return (f.cameraWorld, f.cameraYaw) }
        let scnT = FrameTiming.start()                                     // Oct 24: SceneKit wait (measurement only)
        let p = cameraNode.presentation
        let pose = (position: p.simdWorldPosition, yaw: p.eulerAngles.y)
        FrameTiming.shared.record(.scnPose, since: scnT)
        return pose
    }

    /// The building's doors are free to be the car's (nobody else's in play).
    var carDoorsAvailable: Bool {
        !elevatorInUse && !characterUsingElevator && !arrivedElevatorDoorOpen && elevatorAwaitingEntryDirection == nil
            && !isElevatorWaitingForFloor && !doorsClosingBehindPlayer && !chuteInUse
    }

    /// The car's own doors on this floor (it stopped here for someone else -- a
    /// resident in or out, a call): open (the arrival chime, then the slide) or
    /// shut. The same slide as every door cycle, to absolute positions, so a
    /// change of mind mid-slide simply turns round. Nothing while the player's
    /// or a character's doors are in play. Repeating an order already carried
    /// out does nothing.
    func runCarDoors(open: Bool) {
        guard carDoorsAvailable, let left = elevatorLeftDoor, let right = elevatorRightDoor, let direction = elevatorMountDirection,
              let leftClosed = elevatorLeftClosedPosition, let rightClosed = elevatorRightClosedPosition else { return }
        let moving = left.action(forKey: Self.carDoorsActionKey) != nil || right.action(forKey: Self.carDoorsActionKey) != nil
        if carDoorsTarget == open, moving { return }
        let fraction = elevatorDoorsOpenFraction
        if !moving, open ? fraction > 0.97 : fraction < 0.02 { carDoorsTarget = open; return }
        carDoorsTarget = open
        let ax: Float, az: Float
        switch direction {
        case .north, .south: (ax, az) = (1, 0)
        case .east, .west: (ax, az) = (0, 1)
        }
        let slide: Float = 0.8
        let leftTo = open ? SCNVector3(leftClosed.x - slide * ax, leftClosed.y, leftClosed.z - slide * az) : leftClosed
        let rightTo = open ? SCNVector3(rightClosed.x + slide * ax, rightClosed.y, rightClosed.z + slide * az) : rightClosed
        // (the remaining part of the slide, at the doors' one pace)
        let remaining = open ? 1 - fraction : fraction
        let duration = max(0.15, 1.6 * remaining)
        var wait: TimeInterval = 0
        if open, fraction < 0.02 {
            var gain: Float = 1
            if let frame = elevatorDoorwayFrame() {
                let outside = frame.center + frame.outward * Float(cellSize) * 0.5
                gain = CritterAudio.buildingGain(at: SIMD3<Float>(outside.x, 1.5, outside.y))
            }
            SoundEffects.playElevatorArrival(gain: gain)                    // (the car has arrived here: the chime)
            wait = SoundEffects.elevatorDoorOpeningDelay
        }
        func slideTo(_ p: SCNVector3) -> SCNAction {
            let a = SCNAction.move(to: p, duration: duration)
            a.timingMode = .easeInEaseOut
            return .sequence([.wait(duration: wait), a])
        }
        left.removeAction(forKey: Self.carDoorsActionKey)
        right.removeAction(forKey: Self.carDoorsActionKey)
        left.runAction(slideTo(leftTo), forKey: Self.carDoorsActionKey)
        right.runAction(slideTo(rightTo), forKey: Self.carDoorsActionKey)
        diag("elevator.carDoors", ["open": open, "floor": floorNumber])
    }

    // Oct 19 -- THE DOORS, HEARD: whatever moves them (the player's boarding and
    // arrival, the ride's close, the doors closing behind them, a resident's stop,
    // a character's cycle, the threshold swipe), the sound follows the doors'
    // own movement: the opening slide as they start to part, the closing slide as
    // they start to close, the clunk as they meet. Once per movement.
    private var doorMotion = ElevatorDoorMotion()
    private var doorSoundTimer: Timer?
    /// The doors as last heard (for the car to mirror the player's and a character's doors).
    var elevatorDoorPhase: ElevatorDoorMotion.Phase { doorMotion.phase }
    var elevatorDoorPhaseForCar: BuildingElevator.Doors { doorMotion.doors }
    /// The player is standing in an arrived (or boarded) cab with its doors open or opening.
    var arrivedElevatorDoorOpenForCar: Bool { arrivedElevatorDoorOpen }

    func enableDoorSounds() {
        guard doorSoundTimer == nil, elevatorRightDoor != nil else { return }
        doorMotion = ElevatorDoorMotion(fraction: elevatorDoorsOpenFraction)
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); PerfMonitor.gauge("doorSoundTimers", -1); return }
                self.sampleDoorSounds()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        doorSoundTimer = t
        PerfMonitor.gauge("doorSoundTimers", +1)                           // Oct 21: live count (measurement)
    }

    func disableDoorSounds() {
        if doorSoundTimer != nil { PerfMonitor.gauge("doorSoundTimers", -1) }
        doorSoundTimer?.invalidate()
        doorSoundTimer = nil
    }

    /// Oct 22 (stability pass): this floor's controller has just been replaced by
    /// the next floor's. Its 20 Hz door-sound timer only ever stopped when the
    /// controller itself went away -- and the diagnostics showed one replaced
    /// controller (and its timer) still alive for the rest of the session
    /// ("navControllers=2 doorSoundTimers=2" from the 7 -> 12 ride on), its
    /// timer sampling a scene no one could see 20 times a second. Now its
    /// periodic work stops the moment it's replaced, whatever still holds it;
    /// and if it's still alive 10 s later the flight recorder says so
    /// (leak.navController), so the holder can be found.
    private(set) var isRetired = false
    func retire() {
        guard !isRetired else { return }
        isRetired = true
        disableDoorSounds()
        let me = String(describing: ObjectIdentifier(self))
        diag("navController.retired", ["controller": me, "floor": floorNumber])
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            diag("leak.navController", ["controller": me, "floor": self.floorNumber,
                                        "note": "still alive 10 s after it was replaced"])
        }
    }

    private func sampleDoorSounds() {
        let perf = PerfMonitor.begin("doorSounds.sample"); defer { PerfMonitor.end(perf) }  // Oct 21: measurement only
        guard let node = elevatorExteriorNode ?? elevatorRightDoor, node.parent != nil || node === elevatorRightDoor else { return }
        for cue in doorMotion.update(fraction: elevatorDoorsOpenFraction, at: CACurrentMediaTime()) {
            ElevatorDoorSound.play(cue, on: elevatorRightDoor ?? node)
            diag("elevator.doorSound", ["cue": "\(cue)", "floor": floorNumber])
        }
    }

    /// Oct 19: both doors at their shut positions (as drawn now).
    var elevatorDoorsShut: Bool {
        guard let left = elevatorLeftDoor, let right = elevatorRightDoor,
              let lc = elevatorLeftClosedPosition, let rc = elevatorRightClosedPosition else { return true }
        let l = left.presentation.position, r = right.presentation.position
        return hypotf(l.x - lc.x, l.z - lc.z) < 0.03 && hypotf(r.x - rc.x, r.z - rc.z) < 0.03
    }

    /// Oct 6 (guided journey): the elevator doorway on this floor in world
    /// x/z -- the midpoint of the two doors' closed positions, and the unit
    /// direction out of the cab (the mount wall's opposite).
    func elevatorDoorwayFrame() -> (center: SIMD2<Float>, outward: SIMD2<Float>)? {
        guard let left = elevatorLeftDoor, let right = elevatorRightDoor, let mount = elevatorMountDirection,
              let leftClosed = elevatorLeftClosedPosition, let rightClosed = elevatorRightClosedPosition else { return nil }
        let l = left.parent?.convertPosition(leftClosed, to: nil) ?? leftClosed
        let r = right.parent?.convertPosition(rightClosed, to: nil) ?? rightClosed
        let out = mount.opposite
        return (SIMD2<Float>((l.x + r.x) / 2, (l.z + r.z) / 2), SIMD2<Float>(Float(out.delta.col), Float(out.delta.row)))
    }

    /// Oct 6 (Fredo): asked first whenever the player opens a Room Entrance
    /// door; returning true means a character handled it (nothing opens).
    var roomEntranceDoorIntercept: ((GridCoordinate) -> Bool)?

    /// Oct 9 (Juanita on guard): is this Room Entrance guarded by a
    /// character right now? A pure question (asked while resolving taps) --
    /// the answer comes from the guard's own state (AdministrationExitGuard).
    var roomEntranceDoorGuarded: ((GridCoordinate) -> Bool)?
    /// ...and what happens when the player tries those doors anyway.
    var onGuardedRoomEntranceDoorTap: ((GridCoordinate) -> Void)?
    static let guardedDoorKind = "roomEntranceDoorGuarded"

    /// A guarded door was tried: it does not open; the guard reacts.
    func guardedRoomEntranceDoorTapped(_ coord: GridCoordinate) {
        diag("roomEntranceDoor.guardedTap", ["row": coord.row, "col": coord.col])
        onGuardedRoomEntranceDoorTap?(coord)
    }

    /// Oct 9: a character shuts an open Room Entrance (Juanita taking her
    /// post) -- the ordinary close swing and sound, nothing else.
    func closeRoomEntranceDoorForCharacter(at coord: GridCoordinate) {
        guard openRoomEntranceDoors.contains(coord), !cosmeticallyOpenRoomEntranceDoors.contains(coord) else { return }
        closeRoomEntranceDoor(at: coord)
        diag("roomEntranceDoor.closedByCharacter", ["row": coord.row, "col": coord.col])
    }
    /// Doors a character is holding open for show only (never passable).
    private var cosmeticallyOpenRoomEntranceDoors: Set<GridCoordinate> = [] {
        didSet { if cosmeticallyOpenRoomEntranceDoors != oldValue { publishAcousticDoors() } }
    }

    /// Oct 6 (Fredo leads): a character pushes a Room Entrance door open for
    /// the player -- the same swing, sound and passability as the player's own
    /// open (no adjacency rule, no message), so it then closes behind the
    /// player exactly as usual.
    func openRoomEntranceDoorForCharacter(at coord: GridCoordinate) {
        guard !openRoomEntranceDoors.contains(coord), !cosmeticallyOpenRoomEntranceDoors.contains(coord),
              let doorDirection = roomEntranceDoors[coord] else { return }
        openRoomEntranceDoors.insert(coord)
        swingRoomEntranceDoorLeaves(at: coord, direction: doorDirection, opening: true)
        diag("roomEntranceDoor.openedByCharacter", ["row": coord.row, "col": coord.col])
    }

    /// Oct 6 (Fredo, "kiosk first"): swing a door open or shut for show only.
    /// An open here is never walkable: openDirections still sees it closed.
    func swingRoomEntranceDoorCosmetically(at coord: GridCoordinate, open: Bool) {
        guard !openRoomEntranceDoors.contains(coord), let doorDirection = roomEntranceDoors[coord],
              cosmeticallyOpenRoomEntranceDoors.contains(coord) != open else { return }
        if open { cosmeticallyOpenRoomEntranceDoors.insert(coord) } else { cosmeticallyOpenRoomEntranceDoors.remove(coord) }
        swingRoomEntranceDoorLeaves(at: coord, direction: doorDirection, opening: open)
    }

    private func swingRoomEntranceDoorLeaves(at coord: GridCoordinate, direction: Direction, opening: Bool) {
        if opening { SoundEffects.playRoomEntranceDoorOpen() } else { SoundEffects.playRoomEntranceDoorClose() }
        let angle = bathroomDoorSwingAngle(for: direction) * (opening ? 1 : -1)
        if let hinge = scene?.rootNode.childNode(withName: "roomEntranceDoor_\(coord.row)_\(coord.col)", recursively: true) {
            let swing = SCNAction.rotateBy(x: 0, y: angle, z: 0, duration: 0.5)
            swing.timingMode = opening ? .easeOut : .easeInEaseOut
            hinge.runAction(swing)
        }
        if let pair = scene?.rootNode.childNode(withName: "roomEntranceDoorPair_\(coord.row)_\(coord.col)", recursively: true) {
            let swing = SCNAction.rotateBy(x: 0, y: -angle, z: 0, duration: 0.5)
            swing.timingMode = opening ? .easeOut : .easeInEaseOut
            pair.runAction(swing)
        }
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
        if let pair = scene?.rootNode.childNode(withName: "roomEntranceDoorPair_\(coord.row)_\(coord.col)", recursively: true) {
            let swing = SCNAction.rotateBy(x: 0, y: bathroomDoorSwingAngle(for: doorDirection), z: 0, duration: 0.5)
            swing.timingMode = .easeOut
            pair.runAction(swing)
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
        if !(isMissionComplete && !Self.missionGatesElevator) {   // Oct 4: see photo booth
            showMessage(isMissionComplete ? "All mail delivered! Return to the elevator." : "Delivered to Room \(door.roomNumber).")
        }
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
    func currentFloorMapImage(backgroundOpacity: CGFloat = 1, simplified: Bool = false, includeWallObjectIndicators: Bool = false,
                              gridSize: Int = 15) -> UIImage {
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
        return HallwayScene.makeFloorMapTexture(cells: cells, end: endCell, playerAt: currentCell, facing: facing, headingYaw: Double(cameraNode.eulerAngles.y), missionItemCells: missionItemCells, missionDestinationCells: missionDestinationCells, fireCells: activeFireCells, extinguisherCells: Array(availableExtinguisherCells), photoBoothCells: Array(photoBoothCoords), gameCells: Array(gameMapCells), roomDoors: roomDoors, itemRooms: itemRooms, bathroomDoors: bathroomDoors, paintedCells: missionObjectKind == .paintBucket ? paintedCells : nil, backgroundOpacity: backgroundOpacity, simplified: simplified, wallObjectFaces: wallObjectFaces, doorFaces: doorFaces, exitSignFaces: exitSignFaces, gridSize: gridSize)
    }

    private var applyingArrival = false
    private func applyArrival(cell: GridCoordinate, heading: Direction) {
        applyingArrival = true
        facing = heading
        currentCell = cell
        collectObjectIfPresent(at: cell)
        applyingArrival = false
        refreshFloorMapTexture()
        saveResumePoint(reason: "cell")                    // Oct 11 (resume)
    }

    private func refreshFloorMapTexture() {
        guard !applyingArrival, !floorMapPlaneNodes.isEmpty else { return }
        let image = currentFloorMapImage(gridSize: HallwayScene.floorMapGridSize(for: cells))   // Oct 17: wall maps fit the whole floor
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
    /// Oct 4 (the game changed): the elevator is transportation, not a reward.
    /// false = mission state no longer refuses the elevator, no longer puts up
    /// the MISSION IN PROGRESS sign in front of its doors, and no longer walks
    /// an arriving player out toward the mission. Missions themselves (state,
    /// progress, boards, messages) are untouched. true restores the old gate.
    static let missionGatesElevator = false

    /// Oct 4: the wall mission plaques/boards are retired from the playable
    /// world. false = ContentView hands HallwayScene and this controller an
    /// empty missionSigns set (nothing built, no walk stops, no Noodle
    /// glances, no map markers). The authored data in MazeStore/JSON, the
    /// plaque code and artwork are untouched; true brings them back.
    static let missionPlaquesInWorld = false

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

    /// Cab look ownership spans boarding, travel, arrival, dwell, and closing.
    /// Arrival deliberately permits an explicit exit while retaining free look;
    /// the travel/closing lock (`elevatorInUse`) separately prevents walking.
    var isElevatorRideInProgress: Bool { elevatorInUse || elevatorAwaitingEntryDirection != nil }

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
        guard isElevatorRideInProgress else { return }
        // Oct 10: a finger takes over from a HUD cab pivot (and a HUD pivot
        // starting replaces nothing: it calls this before running its spin).
        cameraNode.removeAction(forKey: Self.elevatorHUDPivotActionKey)
        elevatorHUDPivotRunning = false
        elevatorLookRevision += 1
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
        cameraNode.removeAction(forKey: Self.elevatorEntryAlignActionKey)   // Oct 2: player beats the straighten-up turn too
        cameraNode.removeAction(forKey: Self.elevatorPanelApproachActionKey) // Oct 4: and the glide to the panel
        cameraNode.removeAction(forKey: Self.elevatorEntryGlideActionKey)    // Oct 4: and the entry line-up
        if cameraNode.action(forKey: Self.elevatorArrivalFaceDoorsActionKey) != nil {
            elevatorLog("arrival face-doors CANCELLED by look gesture at yaw=\(cameraNode.eulerAngles.y)")
        }
        cameraNode.removeAction(forKey: Self.elevatorArrivalFaceDoorsActionKey) // Oct 6: and the arrival turn to the doors
        if !playerHasTakenElevatorCameraControl { diag("elevator.manualCameraControlTaken") }
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
    /// Oct 8 (Floor 1 elevator return): an elevator arrival on a floor whose
    /// walk-in start is NOT its elevator cell (Floor 1: the front door).
    /// Puts the player in the elevator cell -- current cell, facing, camera
    /// -- so presentArrivalInsideElevator opens the cab where the cab is,
    /// exactly as on floors whose start already is the elevator. startCell
    /// is untouched (reset and the entrance-door tap still mean the door).
    func enterAtElevatorCell() {
        currentCell = endCell
        facing = startingFacing(at: endCell, cells: cells)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        let p = worldPosition(for: endCell)
        cameraNode.position = SCNVector3(p.x, cameraNode.position.y, p.z)
        cameraNode.eulerAngles = SCNVector3(0, Float(facing.yaw), 0)
        SCNTransaction.commit()
        diag("arrival.enterAtElevatorCell", ["floor": floorNumber, "cell": endCell, "start": startCell])
    }

    func presentArrivalInsideElevator(preservedYaw: Double?, offset: SIMD2<Double>? = nil) {
        guard let direction = elevatorMountDirection,
              let leftDoor = elevatorLeftDoor, let rightDoor = elevatorRightDoor,
              let leftClosed = elevatorLeftClosedPosition, let rightClosed = elevatorRightClosedPosition else {
            diag("arrival.presentInsideElevator.guardFailed", ["hasDirection": elevatorMountDirection != nil,
                  "hasDoors": elevatorLeftDoor != nil && elevatorRightDoor != nil,
                  "hasClosedPositions": elevatorLeftClosedPosition != nil && elevatorRightClosedPosition != nil])
            return
        }
        ElevatorCardReader.presentArrival(in: scene?.rootNode)              // Oct 9: still green from the trip

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
        arrivalExitPermitted = preservedYaw == nil
        // Suppress the sign atomically with cab placement, before arrival is
        // revealed. Mission updates must keep it absent until the exit ends.
        refreshElevatorMissionSign()
        elevatorEntryCellCenterPosition = cameraNode.position
        cameraNode.position = SCNVector3(
            cameraNode.position.x + Float(mountDeltaX * entryDistance),
            cameraNode.position.y,
            cameraNode.position.z + Float(mountDeltaZ * entryDistance))
        elevatorCabCenter = cameraNode.position
        // Oct 4: the interactive elevator keeps the player's spot in the cab
        // across the ride (relative to the doors), clamped inside the cab.
        if let offset {
            let limit = Double(cellSize) / 2 - 0.35
            let along = min(max(offset.x, -limit), limit), across = min(max(offset.y, -limit), limit)
            let fx = Double(direction.delta.col), fz = Double(direction.delta.row)
            cameraNode.position = SCNVector3(
                cameraNode.position.x + Float(along * fx - across * fz),
                cameraNode.position.y,
                cameraNode.position.z + Float(along * fz + across * fx))
        }
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
    /// Oct 15 (Rocket Elevator): this arrival's turn-to-the-doors time.
    private var arrivalFaceDoorsSeconds: TimeInterval = TapNavigationController.elevatorArrivalFaceDoorsDuration

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
        let rocketArrival = RocketElevator.consumeArrival()         // (Oct 15: consumed whatever happens next)
        guard arrivedElevatorDoorOpen, !controlledArrivalDoorsOpened else {
            elevatorLog("controlled arrival door-open skipped -- arrivedElevatorDoorOpen=\(arrivedElevatorDoorOpen) alreadyOpened=\(controlledArrivalDoorsOpened)")
            return
        }
        elevatorLog("controlled arrival doors opening")
        guard let leftDoor = elevatorLeftDoor, let rightDoor = elevatorRightDoor,
              let direction = elevatorMountDirection else {
            return
        }
        controlledArrivalDoorsOpened = true
        onArrivalDoorsOpening?()
        ElevatorCardReader.arrivalDoorsOpening(in: scene?.rootNode)         // Oct 9: trip over -> standby

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
        // (Oct 15, Rocket Elevator: a fast ride's doors open fast -- and the
        // way out is live the moment they're open.)
        let elevatorSlideDuration: TimeInterval = rocketArrival ? RocketElevator.doorOpen : RocketElevator.classicDoorSlide
        let openLeft = SCNAction.moveBy(x: -slide * alongWallX, y: 0, z: -slide * alongWallZ, duration: elevatorSlideDuration)
        let openRight = SCNAction.moveBy(x: slide * alongWallX, y: 0, z: slide * alongWallZ, duration: elevatorSlideDuration)
        openLeft.timingMode = .easeInEaseOut
        openRight.timingMode = .easeInEaseOut
        arrivalFaceDoorsSeconds = rocketArrival ? RocketElevator.faceDoors : Self.elevatorArrivalFaceDoorsDuration
        ElevatorArrivalTrace.shared.doorsScheduled(x: rightDoor.presentation.position.x, z: rightDoor.presentation.position.z)
        leftDoor.runAction(openLeft)
        rightDoor.runAction(openRight) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.arrivedElevatorDoorOpen, !self.elevatorInUse else { return }
                self.arrivalExitPermitted = true
                if rocketArrival { RocketElevator.markControlReturned(floor: self.floorNumber) }
            }
        }
        beginArrivalFaceDoors(direction: direction)
        // Oct 7 (Annette, Build 10): no dwell-and-close any more. The doors
        // stay open until the player steps out or picks another floor on the
        // panel (pressElevatorButton -> closeArrivalDoorsForContinuedRide).
        // The old 8 s auto-close sealed riders in a cab whose only way out
        // was the current-floor button.
    }

    /// Oct 6: called at the arrival ding (with the doors starting to open):
    /// unless the player's finger is on the screen, smoothly turn to face the
    /// doors -- the same yaw a passive arrival starts at. Rotation only; a
    /// new look gesture cancels it at once (beginElevatorCameraDrag) and
    /// takes over from wherever it got to; so does stepping out.
    private func beginArrivalFaceDoors(direction: Direction) {
        // Oct 6: elevatorLog (Xcode console + unified log + flight recorder),
        // not diag() -- diag() writes ONLY to the on-device flight-recorder
        // file, so it never appears in the console.
        //
        // Oct 6 (landing fix): "looking straight out" is a POSE, not just a
        // yaw. The button panel is mounted on the door wall itself, beside
        // the opening, and the controlled ride delivers the player square in
        // front of it -- already AT the door wall's outward yaw, just off to
        // one side. No yaw alone can look straight out of the doorway from
        // there (wall yaw = the panel; doorway bearing = the diagonal). So
        // the landing is: final yaw = the door wall's outward normal
        // (direction.opposite.yaw -- the same exit axis the threshold walk
        // and canGoForward use), and the camera eases sideways onto the
        // doorway's centreline (keeping its depth in the cab), both in one
        // smooth motion.
        let gesture = activeTouchGesture?()
        let startYaw = Double(cameraNode.eulerAngles.y)
        let targetYaw = direction.opposite.yaw
        let turn = shortestDelta(from: startYaw, to: targetYaw)
        let start = cameraNode.position
        let landing = elevatorDoorwayCentrelinePoint(from: start, exit: direction.opposite) ?? start
        let slide = hypot(Double(landing.x - start.x), Double(landing.z - start.z))
        var doorwayInfo = "doorway=unavailable"
        if let left = elevatorLeftDoor, let right = elevatorRightDoor,
           let leftClosed = elevatorLeftClosedPosition, let rightClosed = elevatorRightClosedPosition {
            let l = left.parent?.convertPosition(leftClosed, to: nil) ?? leftClosed
            let r = right.parent?.convertPosition(rightClosed, to: nil) ?? rightClosed
            let doorX = Double(l.x + r.x) / 2, doorZ = Double(l.z + r.z) / 2
            let bearing = atan2(-(doorX - Double(start.x)), -(doorZ - Double(start.z)))
            doorwayInfo = String(format: "cam=(%.2f,%.2f) doorway=(%.2f,%.2f) landing=(%.2f,%.2f) slide=%.2f bearing=%.3f",
                                 Double(start.x), Double(start.z), doorX, doorZ,
                                 Double(landing.x), Double(landing.z), slide, bearing)
        }
        elevatorLog(String(format: "arrival face-doors check: gesture=%@ dragging=%@ yaw=%.3f target=%.3f turn=%.3f %@",
                           gesture ?? "none", isDraggingElevatorCamera ? "yes" : "no", startYaw, targetYaw, turn, doorwayInfo))
        if isDraggingElevatorCamera || gesture != nil {
            elevatorLog("arrival face-doors SKIPPED -- player gesture active (\(gesture ?? "elevator drag"))")
            return
        }
        guard abs(turn) > 0.03 || slide > 0.05 else {
            elevatorLog("arrival face-doors SKIPPED -- already facing straight out of the doorway")
            return
        }
        let duration = arrivalFaceDoorsSeconds * max(0.5, min(1, max(abs(turn) / (.pi / 2), slide / 0.8)))
        let lookRevision = elevatorLookRevision
        var reportedFirstFrame = false
        let spin = SCNAction.customAction(duration: duration) { [weak self] node, elapsed in
            guard self?.elevatorLookRevision == lookRevision else { return }
            if !reportedFirstFrame {
                reportedFirstFrame = true
                DispatchQueue.main.async { elevatorLog("arrival face-doors turning (first frame)") }
            }
            let t = min(1, Double(elapsed) / duration)
            let eased = t * t * (3 - 2 * t)
            node.eulerAngles = SCNVector3(0, Float(startYaw + turn * eased), 0)
            node.position = SCNVector3(start.x + (landing.x - start.x) * Float(eased), start.y,
                                       start.z + (landing.z - start.z) * Float(eased))
        }
        let finished = SCNAction.run { node in
            let yaw = node.eulerAngles.y, p = node.position
            DispatchQueue.main.async {
                elevatorLog(String(format: "arrival face-doors DONE at yaw=%.3f pos=(%.2f,%.2f)", Double(yaw), Double(p.x), Double(p.z)))
            }
        }
        cameraNode.removeAction(forKey: Self.elevatorArrivalFaceDoorsActionKey)
        cameraNode.runAction(.sequence([spin, finished]), forKey: Self.elevatorArrivalFaceDoorsActionKey)
        elevatorLog(String(format: "arrival face-doors START turn=%.3f slide=%.2f duration=%.2f installed=%@", turn, slide, duration,
                           cameraNode.action(forKey: Self.elevatorArrivalFaceDoorsActionKey) != nil ? "yes" : "no"))
    }

    /// Oct 6: the point on the doorway's centreline (the line through the
    /// hallway cell centre along the exit axis -- the doorway is centred on
    /// that cell's wall) at the same depth as `point`. Inside the cab this is
    /// the "lined up with the opening" spot; nil when there is no exit target.
    private func elevatorDoorwayCentrelinePoint(from point: SCNVector3, exit: Direction) -> SCNVector3? {
        guard let centre = elevatorEntryCellCenterPosition else { return nil }
        let ux = Float(exit.delta.col), uz = Float(exit.delta.row)
        let along = (point.x - centre.x) * ux + (point.z - centre.z) * uz
        return SCNVector3(centre.x + ux * along, point.y, centre.z + uz * along)
    }

    /// Close while still aboard, then rearm the same physical panel without
    /// moving the camera or replaying boarding/panel presentation.
    private func closeArrivalDoorsForContinuedRide(departTo floor: Int? = nil) {
        guard arrivedElevatorDoorOpen, elevatorAwaitingEntryDirection != nil, !isAnimating,
              let left = elevatorLeftDoor, let right = elevatorRightDoor,
              let leftClosed = elevatorLeftClosedPosition,
              let rightClosed = elevatorRightClosedPosition, let cabCenter = elevatorCabCenter else { return }
        elevatorInUse = true // No walking through closing doors; free look remains live.
        arrivedElevatorDoorOpen = false
        elevatorBoardedDoorsOpen = false
        elevatorAwaitingEntryDirection = nil
        cameraNode.removeAction(forKey: Self.elevatorArrivalFaceDoorsActionKey)
        diag("elevator.openDoors.closing", ["floor": floorNumber, "departTo": floor])
        left.removeAllActions()
        right.removeAllActions()
        // (Oct 15, Rocket Elevator: a floor chosen by the player -- quick doors.)
        let closeSeconds = floor != nil && RocketElevator.isOn && elevatorCinematicAutoFloor == nil
            ? RocketElevator.doorClose : RocketElevator.classicDoorSlide
        let closeLeft = SCNAction.move(to: leftClosed, duration: closeSeconds)
        let closeRight = SCNAction.move(to: rightClosed, duration: closeSeconds)
        closeLeft.timingMode = .easeInEaseOut
        closeRight.timingMode = .easeInEaseOut
        left.runAction(closeLeft)
        right.runAction(closeRight) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.elevatorInUse else { return }
                self.beginElevatorWaiting(cabCenter: cabCenter, presentPanel: false, restoreLighting: {})
                // Oct 7: the floor chosen with the doors open departs now
                // that they are shut -- the same departure a sealed-cab
                // press makes.
                if let floor, self.isElevatorWaitingForFloor, let depart = self.elevatorDepart {
                    self.elevatorDepart = nil
                    diag("elevator.button.departAfterClose", ["from": self.floorNumber, "to": floor])
                    depart(floor)
                }
            }
        }
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

    /// `keepYaw` (Oct 19, elevator swipe): a BACKWARD crossing -- the player
    /// keeps looking where they look (backing in or out), no turn to the doorway.
    private func performElevatorThresholdWalk(to target: SCNVector3, entering: Bool, keepYaw: Bool = false) {
        // Only an explicit threshold crossing requests alignment. Looking during
        // this glide takes ownership of yaw; translation still finishes safely.
        elevatorRightDoor?.removeAction(forKey: Self.elevatorArrivalDwellKey)
        let direction = entering ? elevatorMountDirection : elevatorAwaitingEntryDirection
        let startYaw = Double(cameraNode.eulerAngles.y)
        let turn = keepYaw ? 0 : shortestDelta(from: startYaw, to: direction?.yaw ?? startYaw)
        let lookRevision = elevatorLookRevision
        if let direction, !keepYaw { facing = direction }
        let start = cameraNode.position
        // Oct 6 (exit through the opening): leaving an arrived cab from an
        // off-centre spot (e.g. in front of the panel, beside the doors) must
        // not cut straight across to the hallway cell -- that line passes
        // through the door wall. Route via the doorway's centreline at the
        // player's current depth first, then straight out along the exit
        // axis. Entering, and an already-centred exit, keep the single leg.
        let corner: SCNVector3? = {
            guard !entering, let exit = elevatorAwaitingEntryDirection,
                  let aligned = elevatorDoorwayCentrelinePoint(from: start, exit: exit),
                  hypot(Double(aligned.x - start.x), Double(aligned.z - start.z)) > 0.05 else { return nil }
            return aligned
        }()
        let firstLeg = corner.map { hypot(Double($0.x - start.x), Double($0.z - start.z)) } ?? 0
        let distance = corner.map { firstLeg + hypot(Double(target.x - $0.x), Double(target.z - $0.z)) }
            ?? hypot(Double(target.x - start.x), Double(target.z - start.z))
        if let corner {
            elevatorLog(String(format: "arrival exit via doorway centreline: from=(%.2f,%.2f) align=(%.2f,%.2f) to=(%.2f,%.2f)",
                               Double(start.x), Double(start.z), Double(corner.x), Double(corner.z),
                               Double(target.x), Double(target.z)))
        }
        let heldExit = walkingHeld
        if cameraNode.action(forKey: Self.elevatorArrivalFaceDoorsActionKey) != nil {
            elevatorLog("arrival face-doors CANCELLED by stepping out")
        }
        cameraNode.removeAction(forKey: Self.elevatorArrivalFaceDoorsActionKey)   // Oct 6: stepping out owns yaw
        cameraNode.removeAction(forKey: Self.elevatorPanelApproachActionKey)      // Oct 7: so does it over the open-cab panel glide
        movementPace = 1
        SoundEffects.setWalkingPace(1)
        phase = .scriptedWalkOut
        isAnimating = true
        // Same world-space speed and smoothstep as a normal single tap.
        // Held walking is linear, as in the grid renderer's continuousRun path.
        let duration = max(distance / travelSpeed,
                           abs(turn) / (.pi / 2) * Self.elevatorThresholdTurnSecondsPerQuarter)
        let move = SCNAction.customAction(duration: duration) { [weak self] node, elapsed in
            let t = min(1, Double(elapsed) / duration)
            if let corner, distance > 0 {
                let s = t * distance
                if s <= firstLeg {
                    let k = Float(firstLeg > 0 ? s / firstLeg : 1)
                    node.position = SCNVector3(start.x + (corner.x - start.x) * k, start.y,
                                               start.z + (corner.z - start.z) * k)
                } else {
                    let k = Float((s - firstLeg) / max(distance - firstLeg, 0.0001))
                    node.position = SCNVector3(corner.x + (target.x - corner.x) * k, start.y,
                                               corner.z + (target.z - corner.z) * k)
                }
            } else {
                node.position = SCNVector3(start.x + (target.x - start.x) * Float(t), start.y,
                                           start.z + (target.z - start.z) * Float(t))
            }
            if self?.elevatorLookRevision == lookRevision {
                node.eulerAngles = SCNVector3(0, Float(startYaw + turn * t), 0)
            }
        }
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
                    self.facing = self.nearestCardinal(toYaw: Double(self.cameraNode.eulerAngles.y))
                    self.isDraggingElevatorCamera = false
                    let wasArrival = self.arrivedElevatorDoorOpen && !self.elevatorBoardedDoorsOpen
                    if self.elevatorBoardedDoorsOpen {
                        // Oct 7: stepped back out without riding -- the
                        // boarding's ride music has nothing to accompany.
                        self.elevatorBoardedDoorsOpen = false
                        SoundEffects.stopElevatorMusic()
                        diag("elevator.boardedExit", ["floor": self.floorNumber])
                    }
                    self.closeArrivedElevatorAfterExit()
                    self.refreshElevatorMissionSign()
                    // Continue through the normal grid planner exactly once. The
                    // lobby ceremony and later returns to this cell are untouched.
                    if wasArrival, self.floorNumber != 1, Self.missionGatesElevator, !self.isMissionComplete {
                        self.advance(source: "MISSION_ARRIVAL")
                    }
                }
                navLog("performElevatorEntryWalkOut() finished -- ordinary navigation resumes")
            }
        }
    }

    // MARK: Oct 19 -- THE ELEVATOR THRESHOLD BY SWIPE
    //
    // The doorway between an open cab and its hallway cell is not a grid
    // edge: the cab is off the grid (the player inside is "at" the hallway
    // cell, offset into the cab), so neither the grid drag (openRunLength)
    // nor the free walk's wall geometry can carry a drag across it -- and,
    // inside, every pan was taken as cab look (isElevatorRideInProgress).
    // Only the tap reached the threshold walk. A vertical swipe now asks
    // here which crossing it would make (finger down = forward, up =
    // backward, along where the player is LOOKING), and makes it with the
    // same threshold walk the tap uses. Closed doors: no crossing.

    enum ElevatorThresholdCrossing: Equatable { case exit, enter }

    /// The doors are open to the hallway behind a player who has just stepped
    /// out: open, or still closing behind them (a step back reopens them).
    private var elevatorOpenBehindPlayer: Bool {
        arrivedElevatorDoorOpen
            || elevatorLeftDoor?.action(forKey: "arrivalCloseBehind") != nil
            || elevatorRightDoor?.action(forKey: "arrivalCloseBehind") != nil
    }

    /// Which crossing a vertical swipe would make right now (nil: none).
    /// `forward`: finger down (walk forward); false: finger up (walk backward).
    func elevatorThresholdCrossing(forward: Bool) -> ElevatorThresholdCrossing? {
        Self.thresholdCrossing(yaw: Double(cameraNode.eulerAngles.y), forward: forward,
                               insideExit: elevatorAwaitingEntryDirection, exitPermitted: canStartElevatorExit,
                               atElevatorCell: currentCell == endCell, mount: elevatorMountDirection,
                               doorsOpen: elevatorOpenBehindPlayer || mayBoardThroughCarDoors,   // (Oct 20: a resident's open doors too)
                               busy: isAnimating || elevatorInUse || chuteInUse || characterUsingElevator || evictionLocked
                                   || elevatorLeftClosedPosition == nil || elevatorRightClosedPosition == nil)
    }

    /// A swipe could cross the threshold one way or the other (outside: the
    /// pan then waits a few points to see which way it goes).
    var elevatorThresholdNearby: Bool {
        elevatorAwaitingEntryDirection == nil
            && (elevatorThresholdCrossing(forward: true) != nil || elevatorThresholdCrossing(forward: false) != nil)
    }

    /// The rule, pure (tests): walking where the player looks (forward) or
    /// away from it (backward), within 60 degrees of the way through the doorway.
    static func thresholdCrossing(yaw: Double, forward: Bool, insideExit: Direction?, exitPermitted: Bool,
                                              atElevatorCell: Bool, mount: Direction?, doorsOpen: Bool,
                                              busy: Bool) -> ElevatorThresholdCrossing? {
        guard !busy else { return nil }
        var travel = forward ? yaw : yaw + .pi
        travel = atan2(sin(travel), cos(travel))
        func within(_ d: Direction) -> Bool {
            let delta = atan2(sin(d.yaw - travel), cos(d.yaw - travel))
            return abs(delta) < .pi / 3
        }
        if let exit = insideExit {
            return exitPermitted && within(exit) ? .exit : nil
        }
        guard atElevatorCell, let mount, doorsOpen, within(mount) else { return nil }
        return .enter
    }

    /// The swipe's crossing, made at once (a flick, and the tests): out of the
    /// cab, or back into it. Same walk, speed and states as the tap's.
    @discardableResult
    func crossElevatorThreshold(forward: Bool) -> Bool {
        guard beginThresholdScrub(forward: forward) else { return false }
        endThresholdScrub(commit: true)
        return true
    }

    // Oct 19 (later): THE SWIPE IS CONTINUOUS. The finger walks the player
    // along the very path the threshold walk takes (in the cab: to the
    // doorway's centreline, then out to the hallway cell's centre; outside:
    // straight back into the cab), a cell per dragMoveDistance points, as a
    // hallway drag does. Released far enough (or flicked), the threshold walk
    // carries on FROM WHERE THE PLAYER IS -- no jump; short, a short glide
    // back to where the drag began.
    private struct ThresholdScrub {
        let crossing: ElevatorThresholdCrossing
        let forward: Bool
        let path: [SCNVector3]
        let length: Float
        let reopenedDoors: Bool
        /// Oct 20: stepping in through the car's doors, open for a resident (not the player's own).
        var viaCarDoors = false
    }
    private var thresholdScrub: ThresholdScrub?
    var isThresholdScrubbing: Bool { thresholdScrub != nil }

    /// Begins the scrub (false: no crossing here now -- the pan stays what it was).
    @discardableResult
    func beginThresholdScrub(forward: Bool) -> Bool {
        guard thresholdScrub == nil, let crossing = elevatorThresholdCrossing(forward: forward) else {
            diag("elevator.thresholdSwipe.refused", ["forward": forward, "cell": currentCell, "awaiting": elevatorAwaitingEntryDirection != nil,
                                                     "doorsOpen": elevatorOpenBehindPlayer, "elevatorInUse": elevatorInUse])
            return false
        }
        let start = cameraNode.position
        var path = [start]
        var reopened = false
        var viaCar = false
        switch crossing {
        case .exit:
            guard let exit = elevatorAwaitingEntryDirection, let centre = elevatorEntryCellCenterPosition else { return false }
            if let aligned = elevatorDoorwayCentrelinePoint(from: start, exit: exit),
               hypot(Double(aligned.x - start.x), Double(aligned.z - start.z)) > 0.05 { path.append(aligned) }
            path.append(centre)
            isDraggingElevatorCamera = false
        case .enter:
            guard let mount = elevatorMountDirection, let left = elevatorLeftDoor, let right = elevatorRightDoor,
                  let leftClosed = elevatorLeftClosedPosition, let rightClosed = elevatorRightClosedPosition else { return false }
            if !arrivedElevatorDoorOpen, !elevatorOpenBehindPlayer, mayBoardThroughCarDoors {
                // Oct 20 (sharing the car): the car's doors stand open here for a
                // resident -- the player steps in through them too. They stay the
                // car's (held open for the player) until the crossing is made.
                viaCar = true
                holdCarDoorway?(true)
            } else if !arrivedElevatorDoorOpen {
                // Closing behind the player: back to open, from wherever they are (a door's safety edge).
                let along: (x: Float, z: Float) = (mount == .north || mount == .south) ? (1, 0) : (0, 1)
                let slide: Float = 0.8
                left.removeAllActions()
                right.removeAllActions()
                let openLeft = SCNAction.move(to: SCNVector3(leftClosed.x - slide * along.x, leftClosed.y, leftClosed.z - slide * along.z), duration: 0.6)
                let openRight = SCNAction.move(to: SCNVector3(rightClosed.x + slide * along.x, rightClosed.y, rightClosed.z + slide * along.z), duration: 0.6)
                openLeft.timingMode = .easeInEaseOut
                openRight.timingMode = .easeInEaseOut
                left.runAction(openLeft)
                right.runAction(openRight)
                arrivedElevatorDoorOpen = true
                reopened = true
            }
            let c = worldPosition(for: endCell)
            let entry = SCNVector3(c.x, start.y, c.z)
            elevatorEntryCellCenterPosition = entry
            let distance = Float(HallwayScene.ElevatorGeometry(cellSize: cellSize).entryDistance)
            path.append(SCNVector3(entry.x + Float(mount.delta.col) * distance, entry.y, entry.z + Float(mount.delta.row) * distance))
        }
        var length: Float = 0
        for i in 1..<path.count { length += hypotf(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z) }
        stopContinuousWalk(reason: "thresholdSwipe")
        cameraNode.removeAction(forKey: Self.elevatorArrivalFaceDoorsActionKey)
        cameraNode.removeAction(forKey: Self.elevatorPanelApproachActionKey)
        thresholdScrub = ThresholdScrub(crossing: crossing, forward: forward, path: path, length: length, reopenedDoors: reopened,
                                        viaCarDoors: viaCar)
        phase = .scriptedWalkOut                         // (the finger owns the position; the grid renderer stays out)
        isAnimating = true                               // (no tap, turn or second walk meanwhile)
        diag("elevator.thresholdSwipe.began", ["crossing": crossing == .exit ? "exit" : "enter", "forward": forward,
                                               "metres": length, "reopenedDoors": reopened, "viaCarDoors": viaCar, "floor": floorNumber])
        return true
    }

    /// The finger's travel along the swipe, in cells (toward the crossing; never past its end).
    func updateThresholdScrub(cells: Double) {
        guard let scrub = thresholdScrub else { return }
        if scrub.viaCarDoors { holdCarDoorway?(true) }                       // (Oct 20: the car waits while the finger walks in)
        var d = max(0, min(Float(cells) * Float(cellSize), scrub.length * 0.97))
        var p = scrub.path[0]
        for i in 1..<scrub.path.count {
            let a = scrub.path[i - 1], b = scrub.path[i]
            let leg = hypotf(b.x - a.x, b.z - a.z)
            if d <= leg || i == scrub.path.count - 1 {
                let k = leg > 0 ? min(1, d / leg) : 1
                p = SCNVector3(a.x + (b.x - a.x) * k, a.y, a.z + (b.z - a.z) * k)
                break
            }
            d -= leg
        }
        cameraNode.position = p
    }

    /// Released: on through the doorway from here, or back to where it began.
    func endThresholdScrub(commit: Bool) {
        guard let scrub = thresholdScrub else { return }
        thresholdScrub = nil
        isAnimating = false
        phase = .translate
        // Oct 20 (sharing the car): in through a resident's open doors -- they become
        // the player's here (as a tap on them would make them). The car gone meanwhile
        // (or the floor refusing now): back out to where the swipe began, as if short.
        var commit = commit
        if scrub.viaCarDoors {
            if commit, !boardThroughCarDoors() {
                diag("elevator.thresholdSwipe.carGone", ["floor": floorNumber])
                commit = false
            }
            holdCarDoorway?(false)
        }
        if commit {
            diag("elevator.thresholdSwipe", ["crossing": scrub.crossing == .exit ? "exit" : "enter", "forward": scrub.forward, "floor": floorNumber])
            switch scrub.crossing {
            case .exit:
                if scrub.forward { performElevatorEntryWalkOut() }          // (exactly the tap's walk out, from here)
                else if let target = elevatorEntryCellCenterPosition { performElevatorThresholdWalk(to: target, entering: false, keepYaw: true) }
            case .enter:
                arrivalExitPermitted = true                                  // (inside again, the way out is live, as on arrival)
                performElevatorThresholdWalk(to: scrub.path[scrub.path.count - 1], entering: true, keepYaw: !scrub.forward)
                refreshElevatorMissionSign()
            }
            return
        }
        // Not far enough: a short glide back to where the drag began.
        diag("elevator.thresholdSwipe.cancelled", ["crossing": scrub.crossing == .exit ? "exit" : "enter"])
        let from = cameraNode.position, to = scrub.path[0]
        let back = Double(hypotf(to.x - from.x, to.z - from.z))
        phase = .scriptedWalkOut
        isAnimating = true
        let glide = SCNAction.move(to: to, duration: max(0.12, min(0.4, back / max(0.1, Double(travelSpeed)))))
        glide.timingMode = .easeOut
        cameraNode.runAction(glide, forKey: "elevatorThresholdGlideBack") { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isAnimating = false
                self.phase = .translate
                if scrub.crossing == .enter, scrub.reopenedDoors { self.closeArrivedElevatorAfterExit() }   // (still out: they close again)
            }
        }
    }

    /// The pan that turned out to be a threshold swipe lets go of the look it
    /// began (inside: the cab look), leaving the view where it is.
    func releasePanForElevatorThreshold() {
        isDraggingElevatorCamera = false               // (the view stays where it is: no snap)
    }

    // MARK: Oct 20 (night) -- STANDING AT A USEFUL DISTANCE FROM THE ELEVATOR
    //
    // iPhone: walked right up to the closed doors, the doors fill the screen --
    // the floor sign above them cut off, the call buttons off the right edge.
    // Free walk lets the eye come to 0.36 m past the elevator cell's centre:
    // 1.28 m from the frame's face, where the 75-degree (vertical) lens in a
    // portrait screen sees only +/-0.45 m across. The doors' frame, the sign
    // and the call panel span about 1.5 m and reach 2.7 m up.
    //
    // When a walk of any kind ENDS there (held, tap, latched -- the one place
    // every walk ends, finishFreeMove), facing the closed doors, the player
    // eases back (0.45 s, the view's yaw kept) to the point -- worked out from
    // the real parts of the elevator front in this scene, the camera's lens and
    // the screen's shape -- where all of it is in view: about 2.1 m from the
    // frame, a little toward the call panel, still in the elevator's cell (so
    // calling, the doors, boarding, swipes: all as ever). Once per visit to the
    // doors: walk up closer again and it stays where you put it. Never while a
    // finger is down, the doors are open (anyone's), the player is in or using
    // the elevator, a scene is scripted, or a critter is being followed.

    // MARK: Oct 22 -- CALLING THE CAR FROM THE HALL
    //
    // The doors are not a button: a tap on them turns and frames the call panel
    // (the elevator view point) -- no call, no sound. The panel's UP and DOWN are:
    // a press lights that button and makes the ordinary call (openElevator: the
    // car here opens its doors now; elsewhere it's called and the arrival
    // answers it -- chime, doors, all as before). While the call stands, the
    // button stays lit and further taps on the doors or a lit button do nothing
    // but frame. The buttons go out as the doors open for the player (or once no
    // call stands). Only the directions this floor has are shown: no DOWN in the
    // lobby, no UP on the top floor. (The cab's own panel is untouched.)

    /// The hall buttons lit: +1 up, -1 down.
    private(set) var hallCallLit: Set<Int> = []
    private var hallCallLitAt: Date?
    private var hallCallToken = 0
    private var hallButtonsConfigured = false
    /// Each button's own material (lit by its emission), and how it looks unlit.
    private var hallButtonMaterials: [Int: (material: SCNMaterial, emission: Any?, intensity: CGFloat)] = [:]

    /// The directions a call from this floor can go (pure).
    static func hallCallDirections(floor: Int, reachable: Set<Int>) -> Set<Int> {
        let others = reachable.subtracting([floor])
        guard !others.isEmpty else { return [1, -1] }
        var ways: Set<Int> = []
        if others.contains(where: { $0 > floor }) { ways.insert(1) }
        if others.contains(where: { $0 < floor }) { ways.insert(-1) }
        return ways
    }
    var hallCallDirections: Set<Int> { Self.hallCallDirections(floor: floorNumber, reachable: elevatorReachableFloors) }

    /// Which hall button the tap pressed (+1 up, -1 down), if it landed on the
    /// call panel (anywhere on it: its nearer button); nil -- the doors, or none.
    func hallCallButton(for hits: [SCNHitTestResult]) -> Int? {
        guard let hit = hits.first(where: { isElevatorDoor($0.node) || isElevatorCallPanel($0.node) }) else { return nil }
        var node: SCNNode? = hit.node
        while let n = node {
            if n.name == "elevatorExteriorUpButton" { return 1 }
            if n.name == "elevatorExteriorDownButton" { return -1 }
            if n.name == "elevatorExteriorCallPanel" {
                let local = n.convertPosition(hit.worldCoordinates, from: nil)
                let ways = hallCallDirections
                if ways.count == 1, let only = ways.first { return only }   // (one button: the whole panel is it)
                return local.y >= 0 ? 1 : -1
            }
            node = n.parent
        }
        return nil
    }

    /// A tap on the elevator from the hall, at its cell: board an arrived cab,
    /// join a resident's open doors, press a hall button, or (the doors) frame.
    func tapElevatorExterior(button: Int?) {
        if canReenterArrivedElevator { advance(); return }
        if carDoorsOpenHere { openElevator(); return }                // (in with a resident: every gate as before)
        if let button { pressHallCall(button) } else { frameHallCallButtons() }
    }

    /// UP or DOWN pressed: lit, and the ordinary call (once -- a lit call stands).
    func pressHallCall(_ way: Int) {
        configureHallButtonsIfNeeded()
        guard hallCallDirections.contains(way) else {
            diag("elevator.hallCall.unavailable", ["floor": floorNumber, "way": way])
            frameHallCallButtons()
            return
        }
        guard hallCallLit.isEmpty else {
            if !hallCallLit.contains(way) { setHallLamp(way, on: true) }     // (both ways wanted: both lit; the call stands)
            diag("elevator.hallCall.again", ["floor": floorNumber, "way": way, "lit": hallCallLit.sorted()])
            return
        }
        setHallLamp(way, on: true)
        diag("elevator.hallCall", ["floor": floorNumber, "way": way > 0 ? "up" : "down"])
        openElevator()
    }

    /// The doors tapped: turn and step to where the doors and the call panel are
    /// all in view (the elevator view point). No call, no sound.
    @discardableResult
    func frameHallCallButtons() -> Bool {
        configureHallButtonsIfNeeded()
        guard currentCell == endCell, let mount = elevatorMountDirection, canRotate, !elevatorInUse, !playerInCab,
              let pose = elevatorViewingPose() else {
            diag("elevator.frame.skipped", ["floor": floorNumber])
            return false
        }
        let here = cameraNode.position
        let target = makeFreeWalkGeometry().legalEndpoint(from: here, to: pose)
        let yaw = Double(cameraNode.eulerAngles.y) + shortestDelta(from: Double(cameraNode.eulerAngles.y), to: mount.yaw)
        diag("elevator.frame", ["floor": floorNumber, "lit": hallCallLit.sorted()])
        elevatorViewSettled = true                                     // (framed: no second settle this visit)
        return approachPose(kind: "elevatorFrame", position: target, yaw: yaw) {}
    }

    /// A call was made some other way (WALK, following, the ceremony): its button lit too.
    private func lightHallCallIfNone() {
        guard hallCallLit.isEmpty else { return }
        configureHallButtonsIfNeeded()
        let ways = hallCallDirections
        guard let way = ways.contains(1) ? 1 : ways.first else { return }
        setHallLamp(way, on: true)
    }

    /// The buttons go out (after at least a moment lit: it's seen).
    func clearHallCall(reason: String) {
        guard !hallCallLit.isEmpty else { return }
        hallCallToken += 1
        let token = hallCallToken
        let shown = hallCallLitAt.map { Date().timeIntervalSince($0) } ?? 1
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 0.6 - shown)) { [weak self] in
            guard let self, self.hallCallToken == token else { return }
            for way in self.hallCallLit { self.setHallLamp(way, on: false) }
            diag("elevator.hallCall.cleared", ["floor": self.floorNumber, "reason": reason])
        }
    }

    /// Four times a second (ElevatorBoard.present): with no call standing any more
    /// (the car came and went, the player walked off), the buttons go out.
    func syncHallCall(callStanding: Bool) {
        configureHallButtonsIfNeeded()
        guard !hallCallLit.isEmpty, !callStanding, !playerCallPending, !elevatorInUse else { return }
        if let at = hallCallLitAt, Date().timeIntervalSince(at) < 1.5 { return }
        clearHallCall(reason: "no call standing")
    }

    /// Oct 23 (critters call the car): a resident pressed this hall button -- or a
    /// resident's call from this floor stands (ElevatorBoard.present) -- so it's lit,
    /// exactly as the player's press lights it; it goes out as the player's does
    /// (syncHallCall: once no call stands).
    func showResidentHallCall(_ way: Int) {
        configureHallButtonsIfNeeded()
        guard hallCallDirections.contains(way), !hallCallLit.contains(way) else { return }
        setHallLamp(way, on: true)
        diag("elevator.hallCall.resident", ["floor": floorNumber, "way": way > 0 ? "up" : "down"])
    }

    /// Oct 24 (Tinky calls the car): a story guide pressed the hall button FOR the player
    /// (his escort, on FOLLOW). The player's own call, as their own press would make it:
    /// the car is called here (once its doors are open and the player is at them, in they
    /// go -- ElevatorBoard answers it, or FOLLOW's walk reaching the doors does), and the
    /// lamp lit. Already standing here: nothing to call -- the player's press at the doors
    /// (FOLLOW's walk makes it) opens them. Never moves the player itself.
    func callElevatorForEscort() {
        configureHallButtonsIfNeeded()
        if !BuildingLife.shared.car.isHere(floorNumber), let gate = carGate {
            _ = gate(floorNumber, "player")
        }
        lightHallCallIfNone()
        diag("elevator.called", ["floor": floorNumber, "by": "escort guide"])
    }

    /// Oct 23 (critters call the car): where this floor's hall button `way` is
    /// (world), for a resident to walk up to and press; nil -- no such button here.
    func hallCallButtonPoint(_ way: Int) -> SIMD3<Float>? {
        configureHallButtonsIfNeeded()
        guard hallCallDirections.contains(way), let root = scene?.rootNode,
              let panel = root.childNode(withName: "elevatorExteriorCallPanel", recursively: true) else { return nil }
        let node = panel.childNode(withName: way > 0 ? "elevatorExteriorUpButton" : "elevatorExteriorDownButton", recursively: false) ?? panel
        let p = node.worldPosition
        return SIMD3<Float>(p.x, p.y, p.z)
    }

    private func setHallLamp(_ way: Int, on: Bool) {
        configureHallButtonsIfNeeded()
        if on {
            hallCallLit.insert(way)
            hallCallLitAt = Date()
            hallCallToken += 1                                         // (a pending put-out is off)
        } else {
            hallCallLit.remove(way)
        }
        guard let m = hallButtonMaterials[way] else { return }
        if on {
            m.material.emission.contents = UIColor(red: 1, green: 0.78, blue: 0.4, alpha: 1)
            m.material.emission.intensity = 1
        } else {
            m.material.emission.contents = m.emission
            m.material.emission.intensity = m.intensity
        }
    }

    /// Once per floor: each hall button its own material (so one lights alone),
    /// and the buttons for directions this floor doesn't have hidden.
    private func configureHallButtonsIfNeeded() {
        guard !hallButtonsConfigured, let root = scene?.rootNode,
              let panel = root.childNode(withName: "elevatorExteriorCallPanel", recursively: true) else { return }
        hallButtonsConfigured = true
        let ways = hallCallDirections
        for (way, name) in [(1, "elevatorExteriorUpButton"), (-1, "elevatorExteriorDownButton")] {
            guard let button = panel.childNode(withName: name, recursively: false) else { continue }
            if let geometry = button.geometry?.copy() as? SCNGeometry, let material = geometry.firstMaterial?.copy() as? SCNMaterial {
                geometry.materials = [material]
                button.geometry = geometry
                hallButtonMaterials[way] = (material, material.emission.contents, material.emission.intensity)
            }
            if !ways.contains(way) {
                // This floor has no such direction: the button, its rim and its arrow aren't there.
                let y = button.position.y
                for n in panel.childNodes where abs(n.position.y - y) < 0.01 { n.isHidden = true }
            }
        }
        diag("elevator.hallButtons", ["floor": floorNumber, "ways": ways.sorted()])
    }

    /// Once per visit: settled already (reset on leaving the elevator's cell).
    private var elevatorViewSettled = false
    static let elevatorViewSettleSeconds: TimeInterval = 0.45
    /// Closer than the view point by more than this before a settle (no fuss over a few cm).
    static let elevatorViewSlack: Float = 0.15

    /// The framing distance (pure): how far from the elevator's front the eye must
    /// stand so the span across (`halfSpan` either side of where it looks) fits the
    /// screen's width and `rise` (top of the sign above the eye) fits under its top
    /// (`topShare` of the upper half usable: the status bar, the HUD).
    static func elevatorViewDistance(halfSpan: Float, rise: Float, verticalFOV degrees: Float, aspect: Float,
                                     topShare: Float = 0.8) -> Float {
        let tanV = tan(degrees * .pi / 360)
        let across = halfSpan / max(0.05, tanV * aspect)
        let up = rise / max(0.05, tanV * topShare)
        return max(across, up)
    }

    /// Where to stand (world): in front of this floor's elevator, the whole front in view.
    func elevatorViewingPose() -> SCNVector3? {
        guard let mount = elevatorMountDirection, let root = scene?.rootNode else { return nil }
        let centre = worldPosition(for: endCell)
        let out = SIMD2<Float>(-Float(mount.delta.col), -Float(mount.delta.row))      // from the doors toward the hall
        let side = SIMD2<Float>(out.y, -out.x)                                          // along the wall
        let names: Set<String> = ["elevatorExteriorJamb", "elevatorExteriorHeader", "elevatorExteriorDisplay", "elevatorExteriorCallPanel"]
        let parts = root.childNodes { n, _ in n.name.map { names.contains($0) } ?? false }
        guard !parts.isEmpty else { return nil }
        var sMin = Float.infinity, sMax = -Float.infinity, face = -Float.infinity, top = -Float.infinity
        for n in parts {
            let (lo, hi) = n.boundingBox
            for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] {
                let w = n.convertPosition(SCNVector3(x, y, z), to: nil)
                let p = SIMD2<Float>(w.x - centre.x, w.z - centre.z)
                sMin = min(sMin, simd_dot(p, side)); sMax = max(sMax, simd_dot(p, side))
                face = max(face, simd_dot(p, out)); top = max(top, w.y)
            } } }
        }
        let margin: Float = 0.06
        let halfSpan = (sMax - sMin) / 2 + margin
        let fov = Float(cameraNode.camera?.fieldOfView ?? 75)
        let bounds = hudSceneView?.bounds.size ?? CGSize(width: 390, height: 844)
        let aspect = Float(bounds.width / max(1, bounds.height))
        let d = Self.elevatorViewDistance(halfSpan: halfSpan, rise: top + 0.05 - eyeHeight, verticalFOV: fov, aspect: aspect)
        // In the elevator's own cell, inside where free walk may stand.
        let half = Float(cellSize) / 2
        let reach = max(0, half - Float(FreeWalkGeometry.playerClearance))
        let depth = min(face + d, half - 0.1)
        let across = max(-reach, min(reach, (sMin + sMax) / 2))
        let p = SIMD2<Float>(centre.x, centre.z) + out * depth + side * across
        return SCNVector3(p.x, cameraNode.position.y, p.y)
    }

    /// A walk just ended in the elevator's cell: ease back to the view point if it
    /// stopped right up at the closed doors, facing them (once per visit).
    private func settleAtElevatorViewIfNeeded() {
        guard currentCell == endCell else { elevatorViewSettled = false; return }
        guard !elevatorViewSettled, let mount = elevatorMountDirection, canRotate, !walkingHeld, !isThresholdScrubbing,
              !playerInCab, !elevatorInUse, !arrivedElevatorDoorOpen, !characterUsingElevator, elevatorDoorsShut, !carDoorsOpenHere,
              carDoorsTarget != true, continuousWalkState == .stopped, pendingWallInteraction == nil,
              activeTouchGesture?() == nil, CritterFollow.targetID == nil, GuidedJourney.trip == nil,
              CharacterLead.activeGuidedRoute == nil,
              abs(shortestDelta(from: Double(cameraNode.eulerAngles.y), to: mount.yaw)) < 40 * .pi / 180,
              let pose = elevatorViewingPose() else { return }
        let here = cameraNode.position
        let out = SIMD2<Float>(-Float(mount.delta.col), -Float(mount.delta.row))
        let centre = worldPosition(for: endCell)
        let depthHere = simd_dot(SIMD2<Float>(here.x - centre.x, here.z - centre.z), out)
        let depthPose = simd_dot(SIMD2<Float>(pose.x - centre.x, pose.z - centre.z), out)
        guard depthHere < depthPose - Self.elevatorViewSlack else { return }          // (already far enough back)
        elevatorViewSettled = true
        let target = makeFreeWalkGeometry().legalEndpoint(from: here, to: pose)
        diag("elevator.viewSettle", ["from": String(format: "%.2f", depthHere), "to": String(format: "%.2f", depthPose),
                                     "floor": floorNumber])
        phase = .scriptedWalkOut
        isAnimating = true
        let glide = SCNAction.move(to: target, duration: Self.elevatorViewSettleSeconds)
        glide.timingMode = .easeInEaseOut
        cameraNode.runAction(glide, forKey: "elevatorViewSettle") { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.phase == .scriptedWalkOut else { return }
                self.isAnimating = false
                self.phase = .translate
            }
        }
    }

    // MARK: Oct 20 -- IN THROUGH A RESIDENT'S OPEN DOORS
    //
    // iPhone: "when a critter is getting into the elevator, I cannot enter." The
    // car's doors opened for a resident are the BUILDING's doors (runCarDoors),
    // not the player's: the threshold swipe only knew the player's own open
    // doors (an arrived cab), and a tap could only board by landing ON a door
    // panel or the call panel -- slid aside, the panels are no longer under the
    // finger; the tap went into the cab and became an ordinary walk the cab's
    // walls stopped. Now both get in: the swipe crosses (boardThroughCarDoors),
    // and a tap through the open doorway is the same request as a tap on the
    // doors (openElevator) -- the ordinary boarding, every gate kept.

    /// The car stands here with its doors open (or opening) for someone else.
    /// (Most of the way open -- never walked through half-open panels.)
    var carDoorsOpenHere: Bool { carDoorsAvailable && carDoorsTarget == true && elevatorDoorsOpenFraction >= 0.6 }

    /// ...and the player may board through them now: at the doors, this floor's
    /// mission done, somewhere to go (openElevator's own gates).
    var mayBoardThroughCarDoors: Bool {
        carDoorsOpenHere && currentCell == endCell && (isMissionComplete || !Self.missionGatesElevator)
            && nextFloorNumber != floorNumber
    }

    /// Holds the car's doors open for the player crossing into it (ElevatorBoard).
    var holdCarDoorway: ((_ hold: Bool) -> Void)?

    /// A tap at the doors while they stand open for a resident, aimed through
    /// the doorway (within 50 degrees of straight in): board, as a tap on the
    /// doors does. True: taken (openElevator ran, with all its own checks).
    func boardThroughOpenCarDoorsByTap(direction: (x: Double, z: Double)?) -> Bool {
        guard mayBoardThroughCarDoors, let d = direction, let mount = elevatorMountDirection else { return false }
        guard Self.aimsThroughDoorway(direction: d, mount: mount) else { return false }
        diag("elevator.tapThroughCarDoors", ["floor": floorNumber])
        openElevator()
        return true
    }

    /// Pure (tests): a tap's horizontal direction aims in through doors on the `mount` wall.
    static func aimsThroughDoorway(direction d: (x: Double, z: Double), mount: Direction) -> Bool {
        let m = (x: Double(mount.delta.col), z: Double(mount.delta.row))
        return d.x * m.x + d.z * m.z >= cos(50 * Double.pi / 180)
    }

    /// The swipe has carried the player into the doorway of the car standing open
    /// for a resident: the doors are the player's now (the car's own gate --
    /// standing here: taken; gone: called instead, false), open the rest of the
    /// way, and the cab is the open, boarded cab an ordinary boarding leaves:
    /// residents still get in and out; a floor button closes them once the
    /// doorway is clear; a swipe or tap out steps out again.
    private func boardThroughCarDoors() -> Bool {
        guard currentCell == endCell, !elevatorInUse, !chuteInUse, !characterUsingElevator,
              isMissionComplete || !Self.missionGatesElevator,
              let left = elevatorLeftDoor, let right = elevatorRightDoor, let mount = elevatorMountDirection,
              let lc = elevatorLeftClosedPosition, let rc = elevatorRightClosedPosition else { return false }
        if let gate = carGate, !gate(floorNumber, "player") { return false }
        left.removeAction(forKey: Self.carDoorsActionKey)
        right.removeAction(forKey: Self.carDoorsActionKey)
        carDoorsTarget = nil
        let remaining = 1 - elevatorDoorsOpenFraction
        if remaining > 0.01 {
            let along: (x: Float, z: Float) = (mount == .north || mount == .south) ? (1, 0) : (0, 1)
            let slide: Float = 0.8
            let seconds = max(0.12, 0.5 * remaining)                         // (the last of it, quickly: the player is stepping in)
            let openLeft = SCNAction.move(to: SCNVector3(lc.x - slide * along.x, lc.y, lc.z - slide * along.z), duration: seconds)
            let openRight = SCNAction.move(to: SCNVector3(rc.x + slide * along.x, rc.y, rc.z + slide * along.z), duration: seconds)
            openLeft.timingMode = .easeInEaseOut
            openRight.timingMode = .easeInEaseOut
            left.runAction(openLeft)
            right.runAction(openRight)
        }
        let entry = worldPosition(for: endCell)
        let depth = Float(HallwayScene.ElevatorGeometry(cellSize: cellSize).entryDistance)
        elevatorCabCenter = SCNVector3(entry.x + Float(mount.delta.col) * depth, cameraNode.position.y,
                                       entry.z + Float(mount.delta.row) * depth)
        arrivedElevatorDoorOpen = true
        elevatorBoardedDoorsOpen = true
        controlledArrivalDoorsOpened = true      // already open: no second open
        playerHasTakenElevatorCameraControl = false
        refreshElevatorMissionSign()
        onElevatorBoarding?()                    // (as every boarding: whoever rides along is told)
        diag("elevator.boardedThroughCarDoors", ["floor": floorNumber])
        elevatorLog("player stepped into the car through a resident's open doors (swipe)")
        return true
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
        // Oct 2: flight recorder (logging only -- every guard unchanged).
        diag("elevator.tapped", ["floor": floorNumber, "next": nextFloorNumber, "atEndCell": currentCell == endCell,
                                 "elevatorInUse": elevatorInUse, "chuteInUse": chuteInUse,
                                 "awaitingEntryDirection": elevatorAwaitingEntryDirection != nil,
                                 "missionComplete": isMissionComplete])
        guard elevatorLeftDoor?.action(forKey: "arrivalCloseBehind") == nil,
              elevatorRightDoor?.action(forKey: "arrivalCloseBehind") == nil else {
            diag("elevator.refused", ["reason": "arrival doors still closing behind player"]); return
        }
        // Oct 6: someone else (Candy, going home) is using the doors right now.
        // Oct 19 (sharing the car): while a RESIDENT's doors are open (or opening)
        // the player gets in too -- the cycle hands the open doors over below,
        // once every other check has passed. Only a cycle already closing (or a
        // scripted character's) still queues the call.
        let joining = characterCycleJoinable
        guard !characterUsingElevator || joining else {
            // Oct 18 (elevator life): the call is kept -- when this cycle closes,
            // the doors open for the player (if they're still at them).
            playerCallPending = true
            playerCallAt = Date()
            UISelectionFeedbackGenerator().selectionChanged()
            diag("elevator.refused", ["reason": "a character is using the elevator", "callQueued": true])
            elevatorLog("player call queued behind \(characterElevatorCycleInfo?.who ?? "a character")'s door cycle")
            return
        }
        guard currentCell == endCell, !elevatorInUse, !chuteInUse, elevatorAwaitingEntryDirection == nil,
              let leftDoor = elevatorLeftDoor, let rightDoor = elevatorRightDoor,
              let direction = elevatorMountDirection else {
            diag("elevator.refused", ["reason": "not at elevator / elevator or chute busy / awaiting entry / no doors"]); return
        }
        // Oct 2, Build 6 fail-safe (root cause fixed in MazeLibrary.
        // repairProgression): never begin a ride whose destination is this
        // same floor -- it can't arrive, and used to strand the player
        // behind the curtain with elevatorInUse stuck true.
        if let next = nextFloorNumber, next == floorNumber {
            diag("elevator.refused", ["reason": "destination equals current floor", "floor": floorNumber, "next": next])
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        guard isMissionComplete || !Self.missionGatesElevator else {
            diag("elevator.refused", ["reason": "mission incomplete"])
            // Keep the existing rejection feedback. The persistent system
            // sign already explains the mission; no door-mounted notice.
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            SoundEffects.playWarningBuzz()
            refreshElevatorMissionSign()
            elevatorRejected = ElevatorRejectionEvent()
            return
        }
        // Oct 19 (one car): only the actual car, standing here. Elsewhere, this tap
        // calls it: it runs here, opens its doors, and -- if you're still at them --
        // this same boarding goes ahead then (ElevatorBoard answers the call).
        if let gate = carGate, !gate(floorNumber, "player") {
            // Oct 22 (hall call): the click and the tick for a fresh call only -- a
            // call already standing (its button lit) is simply still standing.
            let fresh = hallCallLit.isEmpty
            if fresh {
                UISelectionFeedbackGenerator().selectionChanged()
                ElevatorRideSound.click(on: cameraNode)
            }
            lightHallCallIfNone()
            diag("elevator.called", ["floor": floorNumber, "fresh": fresh])
            elevatorLog("player called the car to F\(floorNumber): it isn't here yet")
            return
        }
        // Oct 19 (one car): the car's doors already open (or opening) here for
        // someone else: the player steps in through them -- no second chime.
        let carDoorsOpen = !joining && (!elevatorDoorsShut || carDoorsTarget == true
            || leftDoor.action(forKey: Self.carDoorsActionKey) != nil)
        if carDoorsOpen {
            leftDoor.removeAction(forKey: Self.carDoorsActionKey)
            rightDoor.removeAction(forKey: Self.carDoorsActionKey)
            carDoorsTarget = nil
        }
        refreshElevatorMissionSign()
        if joining { yieldCharacterCycleToPlayer() }
        elevatorInUse = true
        diag("elevator.accepted", ["floor": floorNumber, "next": nextFloorNumber, "joinedResident": joining])
        clearHallCall(reason: "doors opening")                       // (Oct 22: the hall's call answered)
        onElevatorBoarding?()
        // Oct 4: from whatever angle the elevator was tapped, one combined
        // turn-and-glide to a square entry pose (this cell's centre, facing
        // into the cab) while the doors open -- the same motion language as
        // the panel approach.
        if Self.interactiveElevator, let mount = elevatorMountDirection {
            let center = worldPosition(for: endCell)
            let entry = SCNVector3(center.x, cameraNode.position.y, center.z)
            let startYaw = Double(cameraNode.eulerAngles.y)
            runTurnAndGlide(to: entry, yaw: startYaw + shortestDelta(from: startYaw, to: mount.yaw),
                            duration: Self.elevatorEntryAlignDuration, key: Self.elevatorEntryGlideActionKey)
            diag("elevator.entryAlign.start", ["duration": Self.elevatorEntryAlignDuration])
        }
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
        // Oct 19 (sharing the car): to the OPEN positions (absolute), so doors a
        // resident already opened simply stay open -- the same slide from shut.
        let openLeft: SCNAction, openRight: SCNAction
        if let lc = elevatorLeftClosedPosition, let rc = elevatorRightClosedPosition {
            let leftTarget = SCNVector3(lc.x - Float(slide * alongWallX), lc.y, lc.z - Float(slide * alongWallZ))
            // (already partly open: only the rest of the slide, at the same pace)
            let now = leftDoor.presentation.position
            let remaining = min(1, max(0, Double(hypotf(now.x - leftTarget.x, now.z - leftTarget.z)) / Double(slide)))
            let slideTime = joining || carDoorsOpen ? elevatorSlideDuration * remaining : elevatorSlideDuration
            openLeft = SCNAction.move(to: leftTarget, duration: slideTime)
            openRight = SCNAction.move(to: SCNVector3(rc.x + Float(slide * alongWallX), rc.y, rc.z + Float(slide * alongWallZ)), duration: slideTime)
        } else {
            openLeft = SCNAction.moveBy(x: -slide * alongWallX, y: 0, z: -slide * alongWallZ, duration: elevatorSlideDuration)
            openRight = SCNAction.moveBy(x: slide * alongWallX, y: 0, z: slide * alongWallZ, duration: elevatorSlideDuration)
        }
        openLeft.timingMode = .easeInEaseOut
        openRight.timingMode = .easeInEaseOut
        if !joining && !carDoorsOpen { SoundEffects.playElevatorArrival() }    // (joining open doors: no second chime)
        let arrivalDelay = joining || carDoorsOpen ? 0 : SoundEffects.elevatorDoorOpeningDelay
        leftDoor.runAction(.sequence([.wait(duration: arrivalDelay), openLeft]))
        diag("elevator.departureDoors.opening")
        rightDoor.runAction(.sequence([.wait(duration: arrivalDelay), openRight])) { [weak self] in
            diag("elevator.departureDoors.open")
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
            if Self.interactiveElevator,
               self.scene?.rootNode.childNode(withName: "elevatorControlPanel", recursively: true) != nil {
                DispatchQueue.main.async {
                    diag("elevator.rideStart", ["from": self.floorNumber, "mode": "interactive"])
                    self.playElevatorRide(leftDoor: leftDoor, rightDoor: rightDoor, alongWallX: alongWallX, alongWallZ: alongWallZ, forwardX: forwardX, forwardZ: forwardZ, slide: slide, elevatorSlideDuration: elevatorSlideDuration, targetButton: nil, next: nil)
                }
            } else if let next = self.nextFloorNumber,
               let targetButton = self.elevatorButtonNodes[next] {
                DispatchQueue.main.async {
                    diag("elevator.rideStart", ["from": self.floorNumber, "to": next])
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
                            diag("elevator.handoff.fired", ["mode": "passive-noNextButton"])
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
    private func playElevatorRide(leftDoor: SCNNode, rightDoor: SCNNode, alongWallX: CGFloat, alongWallZ: CGFloat, forwardX: CGFloat, forwardZ: CGFloat, slide: CGFloat, elevatorSlideDuration: TimeInterval, targetButton: SCNNode?, next: Int?) {
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
        // Oct 2 (centering experiment): the carry-in used to be a RELATIVE
        // move(by:) of entryDistance along the mount direction -- correct
        // only when the ride began at the elevator cell's center (always
        // true under grid navigation). Free Walk can commit from anywhere
        // in that cell (hugging a side wall, part-way forward), and the
        // relative move carried that offset straight into the cab. Now an
        // ABSOLUTE move(to:) to the canonical cab center -- the same point
        // presentArrivalInsideElevator places an arriving player at (cell
        // center + mount direction * entryDistance) -- with the same
        // duration and easing, so the correction rides inside the existing
        // motion. Height is the camera's own; yaw is not touched.
        let cellCenter = worldPosition(for: endCell)
        let cabCenterX = cellCenter.x + Float(forwardX * dollyDistance)
        let cabCenterZ = cellCenter.z + Float(forwardZ * dollyDistance)
        func makeCarryIn() -> SCNAction {
            let action = SCNAction.move(to: SCNVector3(cabCenterX, cameraNode.position.y, cabCenterZ),
                                        duration: elevatorGeometry.entryDuration)
            action.timingMode = .easeInEaseOut
            return action
        }
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
            diag("elevator.departureDoors.closing")
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
            // Completion is logging-only (Oct 2 flight recorder).
            rightDoor.runAction(closeRight) { diag("elevator.departureDoors.closed") }
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
            let carryStart = self.cameraNode.position
            // Oct 2 (yaw-normalization experiment): Free Walk can commit a
            // ride while looking well off the doors, and nothing before
            // this point straightens the view -- the later auto-turn is a
            // RELATIVE rotateBy(.pi), so an off-angle entry became an
            // equally off-angle door view on arrival. Alongside the
            // position carry-in (same start, duration and easing), turn the
            // short way to the canonical heading straight at the cab's back
            // wall: the mount direction's own yaw (the doors are on that
            // side of the elevator cell, the back wall beyond them). Keyed,
            // so a manual camera grab cancels it (beginElevatorCameraDrag)
            // and the player wins; skipped if they already took control.
            let startYaw = Double(self.cameraNode.eulerAngles.y)
            let backWallYaw = self.elevatorMountDirection?.yaw ?? startYaw
            let yawCorrection = self.shortestDelta(from: startYaw, to: backWallYaw)
            let manualBeforeCarryIn = self.playerHasTakenElevatorCameraControl
            diag("elevator.carryIn.start", ["from": String(format: "(%.3f, %.3f)", carryStart.x, carryStart.z),
                                            "cabCenter": String(format: "(%.3f, %.3f)", cabCenterX, cabCenterZ),
                                            "startYaw": startYaw, "backWallYaw": backWallYaw,
                                            "yawCorrection": yawCorrection, "manualAlready": manualBeforeCarryIn])
            self.cameraNode.removeAction(forKey: Self.elevatorEntryGlideActionKey)
            if !manualBeforeCarryIn, abs(yawCorrection) > 0.0001 {
                let align = SCNAction.rotateBy(x: 0, y: CGFloat(yawCorrection), z: 0, duration: elevatorGeometry.entryDuration)
                align.timingMode = .easeInEaseOut
                self.cameraNode.runAction(align, forKey: Self.elevatorEntryAlignActionKey)
            }
            self.cameraNode.runAction(makeCarryIn()) { [weak self] in
                guard let self else { diag("elevator.carryIn.done"); return }
                let end = self.cameraNode.presentation.position
                let endYaw = Double(self.cameraNode.presentation.eulerAngles.y)
                let manual = self.playerHasTakenElevatorCameraControl
                diag("elevator.carryIn.done", ["at": String(format: "(%.3f, %.3f)", end.x, end.z),
                                               "offCenter": Double(hypotf(end.x - cabCenterX, end.z - cabCenterZ)),
                                               "yaw": endYaw,
                                               "yawError": (manual ? nil : Optional(self.shortestDelta(from: endYaw, to: backWallYaw))) as Double?,
                                               "manualControlTaken": manual])
                // Oct 7 (Annette, Build 10): an ordinary boarding no longer
                // seals the cab. The doors stay open, the player is turned
                // to the panel, and only a floor choice closes them. The
                // building's own rides (Admission, the guided escort) keep
                // the original close-and-auto-press sequence exactly.
                if next == nil, self.elevatorCinematicAutoFloor == nil {
                    let cabCenter = SCNVector3(cabCenterX, self.cameraNode.position.y, cabCenterZ)
                    DispatchQueue.main.async { [weak self] in
                        self?.settleBoardedCabDoorsOpen(cabCenter: cabCenter, restoreLighting: restoreShaftLighting)
                    }
                    return
                }
                // Doors start closing here, the instant you're facing
                // the back wall -- elevatorSlideDuration (1.6s) fits
                // comfortably inside the 2-second dwell below, so
                // they're done well before the pivot even starts, let
                // alone finishes.
                closeDoorsNow()
                if next == nil {
                    // Oct 4 interactive elevator: once the doors are shut, glide
                    // to the panel and wait for a button (see beginElevatorWaiting).
                    let cabCenter = SCNVector3(cabCenterX, self.cameraNode.position.y, cabCenterZ)
                    DispatchQueue.main.asyncAfter(deadline: .now() + elevatorSlideDuration) { [weak self] in
                        self?.beginElevatorWaiting(cabCenter: cabCenter, restoreLighting: restoreShaftLighting)
                    }
                    return
                }
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
                        diag("elevator.autoTurn.started")
                        self.cameraNode.runAction(rotate, forKey: Self.elevatorAutoSpinActionKey)
                    } else {
                        diag("elevator.autoTurn.skipped", ["reason": "player took camera control"])
                    }
                    diag("elevator.handoff.scheduled", ["inSeconds": rotate.duration + 0.3])
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
                        diag("elevator.handoff.fired", ["mode": self.playerHasTakenElevatorCameraControl ? "controlled" : "passive",
                                                        "from": self.floorNumber, "to": self.nextFloorNumber])
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

    // MARK: Oct 4 interactive elevator

    /// Doors are shut: one combined pivot + glide to a square-on view of the
    /// control panel, and the car WAITS (stationary, no timeout) for a button.
    private func beginElevatorWaiting(cabCenter: SCNVector3, presentPanel: Bool = true, restoreLighting: @escaping () -> Void) {
        guard elevatorInUse else { return }
        isElevatorWaitingForFloor = true
        elevatorDestinationFloor = nil
        elevatorCabCenter = cabCenter
        elevatorDepart = { [weak self] floor in self?.departElevator(to: floor, cabCenter: cabCenter, restoreLighting: restoreLighting) }
        diag("elevator.waiting", ["floor": floorNumber])
        // Oct 5 (Admission): on the first trip from the lobby the building
        // presses the button itself, a beat after the panel comes into view.
        if let auto = elevatorCinematicAutoFloor {
            if admissionAutoFloor == auto || guidedAutoFloor?() == auto {               // Oct 24: prepare it now (short ride)
                onElevatorDestinationForeseen?(auto)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.elevatorPanelApproachDuration + 0.4) { [weak self] in
                self?.autoPressElevatorButton(floor: auto)
            }
        }
        guard presentPanel else {
            diag("elevator.panelApproach.skipped", ["manual": playerHasTakenElevatorCameraControl])
            return
        }
        glideToElevatorPanel(cabCenter: cabCenter)
    }

    /// Oct 7: a floor the building chooses for this ride (Admission's first
    /// trip, the guided escort) -- those rides keep their scripted close and
    /// automatic press. nil = the player chooses.
    var elevatorCinematicAutoFloor: Int? {
        guard let auto = admissionAutoFloor ?? guidedAutoFloor?(),
              elevatorReachableFloors.contains(auto), auto != floorNumber else { return nil }
        return auto
    }

    /// Oct 7 (Annette, Build 10): an ordinary boarding ends here, in the same
    /// state an arrival leaves the cab in -- doors open, the way out live,
    /// nothing timed -- with the panel live too. Lighting returns to the
    /// arrival cab's (normal) level and the player is turned to the panel.
    private func settleBoardedCabDoorsOpen(cabCenter: SCNVector3, restoreLighting: () -> Void) {
        guard elevatorInUse, !isElevatorWaitingForFloor, elevatorDestinationFloor == nil,
              let mount = elevatorMountDirection else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        restoreLighting()
        SCNTransaction.commit()
        let entry = worldPosition(for: endCell)
        elevatorInUse = false
        elevatorCabCenter = cabCenter
        arrivedElevatorDoorOpen = true
        elevatorBoardedDoorsOpen = true
        controlledArrivalDoorsOpened = true      // already open: no second open
        arrivalExitPermitted = true
        elevatorAwaitingEntryDirection = mount.opposite
        elevatorEntryCellCenterPosition = SCNVector3(entry.x, cameraNode.position.y, entry.z)
        refreshElevatorMissionSign()
        diag("elevator.boarded.doorsOpen", ["floor": floorNumber])
        glideToElevatorPanel(cabCenter: cabCenter)
    }

    /// The panel approach (Oct 4), shared by the sealed cab and the open one.
    /// `requested` (Oct 8): the player asked for it (a tap on the panel
    /// wall) -- it runs even after they've taken the camera, cancels the
    /// arrival turn-to-doors, and does nothing when already square-on.
    /// Returns true if a glide started.
    @discardableResult
    private func glideToElevatorPanel(cabCenter: SCNVector3, requested: Bool = false) -> Bool {
        guard requested || !playerHasTakenElevatorCameraControl, let pose = elevatorPanelViewPose(cabCenter: cabCenter) else {
            diag("elevator.panelApproach.skipped", ["manual": playerHasTakenElevatorCameraControl])
            return false
        }
        let start = cameraNode.position
        let startYaw = Double(cameraNode.eulerAngles.y)
        // Turn the way that keeps the view pointed AWAY from the wall we are
        // gliding toward while it swings round (no near-wall picture sweep).
        var turn = shortestDelta(from: startYaw, to: pose.yaw)
        if abs(turn) > 2.4 {
            let other = turn > 0 ? turn - 2 * .pi : turn + 2 * .pi
            let lateral = (x: Double(pose.position.x - start.x), z: Double(pose.position.z - start.z))
            func midFacing(_ d: Double) -> Double {
                let y = startYaw + d / 2
                return -sin(y) * lateral.x - cos(y) * lateral.z     // forward . lateral
            }
            if midFacing(other) < midFacing(turn) { turn = other }
        }
        var duration = Self.elevatorPanelApproachDuration
        let target = pose.position
        if requested {
            let off = hypotf(target.x - start.x, target.z - start.z)
            guard off > 0.05 || abs(shortestDelta(from: startYaw, to: pose.yaw)) > 0.03 else {
                diag("elevator.panelAlign.skipped", ["reason": "already square-on"])
                return false
            }
            // Oct 8: a tapped alignment runs at the standard wall-object
            // landing's pace (beginWallComposition -> beginFreeWalkTap's
            // short approach: distance / travelSpeed, never under one cell's
            // worth, turn spread over the whole glide). The boarding glide
            // keeps its own unhurried 1.6 s.
            duration = max(Double(off) / travelSpeed, Double(cellSize) / travelSpeed)
            cameraNode.removeAction(forKey: Self.elevatorArrivalFaceDoorsActionKey)  // the tap owns the view now
        }
        runTurnAndGlide(to: target, yaw: startYaw + turn, duration: duration, key: Self.elevatorPanelApproachActionKey)
        diag("elevator.panelApproach.start", ["duration": duration, "turn": turn, "requested": requested,
                                              "to": String(format: "(%.3f, %.3f)", target.x, target.z)])
        return true
    }

    /// Oct 8: a doors-open tap that missed the buttons. On the panel plate,
    /// or on the door wall right around it (not the doors, not another
    /// wall): glide square-on to the panel -- the boarding glide, same pose.
    /// Never chooses a floor. Returns true when the tap was the panel's.
    private func alignToElevatorPanelFromOpenCab(hit: SCNHitTestResult, onPlate: Bool) -> Bool {
        guard let panel = scene?.rootNode.childNode(withName: "elevatorControlPanel", recursively: true) else { return false }
        if !onPlate {
            guard !isElevatorDoor(hit.node) else { return false }
            let p = panel.worldPosition, w = hit.worldCoordinates
            let (lo, hi) = panel.boundingBox
            let reach = max(hi.y - lo.y, hi.x - lo.x) / 2 + 0.35
            let n = panel.convertVector(SCNVector3(0, 0, -1), to: nil)
            let nl = max(hypotf(n.x, n.z), 0.0001)
            let offPlane = abs((w.x - p.x) * n.x / nl + (w.z - p.z) * n.z / nl)
            // The door wall only: beside/around the plate, in its plane.
            guard hypotf(w.x - p.x, w.z - p.z) < 0.6, abs(w.y - p.y) < reach, offPlane < 0.15 else { return false }
        }
        guard elevatorCinematicAutoFloor == nil, let cabCenter = elevatorCabCenter else {
            diag("elevator.panelAlign.skipped", ["reason": "scripted ride or no cab"])
            return true
        }
        let started = glideToElevatorPanel(cabCenter: cabCenter, requested: true)
        diag("elevator.panelAlign", ["on": onPlate ? "plate" : "wall", "started": started])
        return true
    }

    /// Oct 4: the elevator's one motion language (entry line-up, panel
    /// approach): turn and glide TOGETHER from the current pose to `target`,
    /// ending at absolute yaw `yaw` (pass start + the signed turn wanted).
    /// Both eased; the turn leads a touch and the glide catches up, so the
    /// path reads as one curved landing rather than turn-then-walk.
    private func runTurnAndGlide(to target: SCNVector3, yaw: Double, duration: TimeInterval, key: String) {
        let start = cameraNode.position
        let startYaw = Double(cameraNode.eulerAngles.y)
        let turn = yaw - startYaw
        func smooth(_ t: Double) -> Double { let c = min(1, max(0, t)); return c * c * (3 - 2 * c) }
        let glide = SCNAction.customAction(duration: duration) { node, elapsed in
            let t = Double(elapsed) / duration
            let r = smooth(t)
            let m = smooth((t - 0.08) / 0.92)
            node.eulerAngles = SCNVector3(0, Float(startYaw + turn * r), 0)
            node.position = SCNVector3(start.x + (target.x - start.x) * Float(m), start.y,
                                       start.z + (target.z - start.z) * Float(m))
        }
        cameraNode.removeAction(forKey: key)
        cameraNode.runAction(glide, forKey: key)
    }

    /// Oct 4: redraw the cab's floor indicator (direction: 1 up, -1 down, 0 none).
    private func setElevatorIndicator(floor: Int, direction: Int) {
        guard let face = scene?.rootNode.childNode(withName: "elevatorFloorIndicatorDisplay", recursively: true) else { return }
        face.geometry?.firstMaterial?.diffuse.contents = HallwayScene.elevatorIndicatorImage(floor: floor, direction: direction)
    }

    /// The final number must render before capturing the outgoing cab.
    /// Completion drives handoff directly, without a post-destination dwell.
    private func runElevatorIndicator(to destination: Int, rocket: Bool = false, fixedSeconds: TimeInterval? = nil,
                                      completion: @escaping () -> Void) {
        let origin = floorNumber
        let direction = destination > origin ? 1 : -1
        setElevatorIndicator(floor: origin, direction: direction)
        let steps = abs(destination - origin)
        guard steps > 0 else { completion(); return }
        for i in 1...steps {
            let at = fixedSeconds.map { $0 * Double(i) / Double(steps) }        // (Oct 24: Admission's first ride)
                ?? (rocket ? RocketElevator.indicatorStepDelay(step: i, steps: steps)
                           : Self.elevatorIndicatorStepDelay(step: i, steps: steps))
            let shown = origin + direction * i
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self else { return }
                if i == steps { ElevatorArrivalTrace.shared.begin(from: origin, to: destination) }
                self.setElevatorIndicator(floor: shown, direction: i == steps ? 0 : direction)
                if i == steps {
                    ElevatorArrivalTrace.shared.destinationNumberAssigned()
                    self.afterNextRenderedFrame(completion)
                }
            }
        }
    }

    /// Where to stand to see the whole panel square-on: in front of it along
    /// its interior-facing normal, far enough back to fit it in the frame,
    /// kept inside the cab.
    private func elevatorPanelViewPose(cabCenter: SCNVector3) -> (position: SCNVector3, yaw: Double)? {
        guard let plate = scene?.rootNode.childNode(withName: "elevatorControlPanel", recursively: true) else { return nil }
        let p = plate.worldPosition
        let n3 = plate.convertVector(SCNVector3(0, 0, -1), to: nil)     // proud toward the passenger
        let nl = (n3.x * n3.x + n3.z * n3.z).squareRoot()
        guard nl > 0.0001 else { return nil }
        let nx = n3.x / nl, nz = n3.z / nl
        let (lo, hi) = plate.boundingBox
        let halfHeight = (hi.y - lo.y) / 2
        let eyeY = cameraNode.position.y
        let fov = Float(cameraNode.camera?.fieldOfView ?? 60)
        let tanFull = tan(fov / 2 * .pi / 180)
        let tanHalf = tanFull * 0.88                                // a little margin
        // Oct 12 (stability): below eye level, keep the panel's lowest row
        // (LOBBY) clear of the bottom navigation row -- the camera stands a
        // little further back instead (no pitch/FOV change; cab only).
        var tanBelow = tanHalf
        if Self.continuousWalkExperimentOn, let view = hudSceneView, view.bounds.height > 0 {
            let halfH = Float(view.bounds.height) / 2
            let reserve = Float(view.safeAreaInsets.bottom + ContinuousWalkControls.bottomPadding
                                + ContinuousWalkControls.rowHeight) + 24
            tanBelow = min(tanHalf, tanFull * max(0.3, (halfH - reserve) / halfH))
        }
        var below = eyeY - (p.y - halfHeight), above = (p.y + halfHeight) - eyeY
        // Oct 25 (PP 2): the floor indicator above the plate is part of what must be in view.
        if let indicator = scene?.rootNode.childNode(withName: "elevatorFloorIndicator", recursively: true) {
            let (ilo, ihi) = indicator.boundingBox
            above = max(above, indicator.worldPosition.y + (ihi.y - ilo.y) / 2 - eyeY)
        }
        below = max(below, 0)
        var distance = max(Self.elevatorPanelMinViewDistance, below / tanBelow, above / tanHalf)
        let half = Float(cellSize) / 2 - 0.4                        // stay this far inside the cab walls
        distance = min(distance, Float(cellSize) - 0.45)
        var x = p.x + nx * distance, z = p.z + nz * distance
        x = min(max(x, cabCenter.x - half), cabCenter.x + half)
        z = min(max(z, cabCenter.z - half), cabCenter.z + half)
        return (SCNVector3(x, eyeY, z), Double(atan2(nx, nz)))
    }

    /// A tap while WAITING: the nearest thing under the finger decides. On
    /// the panel -> the nearest button within a finger's reach is pressed.
    /// Returns true when the tap was the panel's.
    func pressElevatorButton(hits: [SCNHitTestResult]) -> Bool {
        if elevatorDoorsOpenIdle { return pressElevatorButtonDoorsOpen(hits: hits) }
        guard isElevatorWaitingForFloor, elevatorInUse, let hit = hits.first else { return false }
        // Oct 7 (Annette, Build 10): a tap on the shut doors of a stationary
        // cab opens them onto this floor -- the same reopen the current
        // floor's button makes. Never once a trip is chosen or moving, and
        // never during the building's own scripted rides.
        if isElevatorDoor(hit.node) {
            if elevatorSameFloorReopenAllowed, elevatorCinematicAutoFloor == nil {
                diag("elevator.doorTap.reopen", ["floor": floorNumber])
                reopenElevatorDoorsAtCurrentFloor()
            } else {
                diag("elevator.doorTap.rejected", ["floor": floorNumber,
                                                   "destination": elevatorDestinationFloor,
                                                   "scripted": elevatorCinematicAutoFloor != nil])
            }
            return true
        }
        var node: SCNNode? = hit.node
        var plate: SCNNode?
        while let n = node {
            if n.name == "elevatorControlPanel" { plate = n; break }
            node = n.parent
        }
        guard let plate else {
            // Oct 4 "mind reading": a tap on the wall right around the panel
            // (the indicator, the liner) means "the controls" -- land square.
            if let panel = scene?.rootNode.childNode(withName: "elevatorControlPanel", recursively: true) {
                let p = panel.worldPosition, w = hit.worldCoordinates
                let (lo, hi) = panel.boundingBox
                let reach = max(hi.y - lo.y, hi.x - lo.x) / 2 + 0.35
                if hypotf(w.x - p.x, w.z - p.z) < 0.6, abs(w.y - p.y) < reach {
                    if elevatorPanelAssistAllowed {
                        landAtElevatorPanel(reason: "near panel")
                    } else {
                        diag("elevator.panelAssist.skipped", ["reason": "near panel", "doors": "not shut"])
                    }
                    return true
                }
            }
            return false
        }
        let local = plate.convertPosition(hit.worldCoordinates, from: nil)
        let prefix = "elevatorControlButton_"
        var best: (floor: Int, cap: SCNNode, distance: Float)?
        for child in plate.childNodes {
            guard let name = child.name, name.hasPrefix(prefix), let floor = Int(name.dropFirst(prefix.count)) else { continue }
            // Oct 8: measured in the cap's own proportions (LOBBY is a wider oval).
            let d = hypotf((child.position.x - local.x) / max(child.scale.x, 1), child.position.y - local.y)
            if best == nil || d < best!.distance { best = (floor, child, d) }
        }
        guard let best, best.distance < HallwayScene.ElevatorPanelMetrics.hitRadius else {   // on the plate, between buttons (Oct 25: was a fixed 0.085):
            if elevatorPanelAssistAllowed {
                landAtElevatorPanel(reason: "panel, no button")         // "the controls" -- land square
            } else {
                diag("elevator.panelAssist.skipped", ["reason": "panel, no button", "doors": "not shut"])
            }
            return true
        }
        cameraNode.removeAction(forKey: Self.elevatorPanelApproachActionKey)
        let cap = best.cap
        cap.removeAction(forKey: "press")
        cap.runAction(.sequence([.moveBy(x: 0, y: 0, z: 0.006, duration: 0.06),
                                 .moveBy(x: 0, y: 0, z: -0.006, duration: 0.14)]), forKey: "press")
        ElevatorRideSound.click(on: cameraNode)
        ToolBelt.elevatorButtonPressed(at: cap.worldPosition)         // Oct 16 (IV/V): a tool reaches for it (visual only)
        // Oct 5: idle, sealed cab + THIS floor's button = "open the doors".
        if best.floor == floorNumber, elevatorSameFloorReopenAllowed {
            reopenElevatorDoorsAtCurrentFloor()
            return true
        }
        guard best.floor != floorNumber, elevatorReachableFloors.contains(best.floor), let depart = elevatorDepart else {
            diag("elevator.button.inert", ["button": best.floor, "floor": floorNumber])
            return true
        }
        // Oct 9: the employee-ID reader (ElevatorCardReader). Refused: the
        // button doesn't light, the car stays put, departure stays armed.
        guard readEmployeeID(forFloor: best.floor, doors: "sealed") else { return true }
        // Light the chosen button (its own material copy -- the caps share one).
        let lit = HallwayScene.ElevatorButtonLook.selected()          // Oct 25: the one shared look
        cap.geometry?.materials = [lit]
        elevatorDepart = nil
        diag("elevator.button.pressed", ["from": floorNumber, "to": best.floor])
        depart(best.floor)
        return true
    }

    /// Oct 7 (Annette, Build 10): standing in a stationary cab with the doors
    /// fully open (after an arrival, a boarding, or a reopen) -- the panel is
    /// live and nothing is timed.
    var elevatorDoorsOpenIdle: Bool {
        canStartElevatorExit && arrivedElevatorDoorOpen && !isAnimating && !isElevatorWaitingForFloor
    }

    /// Oct 7: a panel tap with the doors open. Another floor's button lights
    /// and the doors close, then the normal departure runs
    /// (closeArrivalDoorsForContinuedRide(departTo:)). This floor's button
    /// only clicks -- the doors are already open. Anything that isn't the
    /// panel returns false (the doorway/interior tap rules decide).
    private func pressElevatorButtonDoorsOpen(hits: [SCNHitTestResult]) -> Bool {
        guard let hit = hits.first else { return false }
        var node: SCNNode? = hit.node
        var plate: SCNNode?
        while let n = node {
            if n.name == "elevatorControlPanel" { plate = n; break }
            node = n.parent
        }
        guard let plate else { return alignToElevatorPanelFromOpenCab(hit: hit, onPlate: false) }
        let local = plate.convertPosition(hit.worldCoordinates, from: nil)
        let prefix = "elevatorControlButton_"
        var best: (floor: Int, cap: SCNNode, distance: Float)?
        for child in plate.childNodes {
            guard let name = child.name, name.hasPrefix(prefix), let floor = Int(name.dropFirst(prefix.count)) else { continue }
            // Oct 8: measured in the cap's own proportions (LOBBY is a wider oval).
            let d = hypotf((child.position.x - local.x) / max(child.scale.x, 1), child.position.y - local.y)
            if best == nil || d < best!.distance { best = (floor, child, d) }
        }
        guard let best, best.distance < HallwayScene.ElevatorPanelMetrics.hitRadius else {   // (Oct 25: was a fixed 0.085)
            diag("elevator.button.missed", ["doors": "open"])
            return alignToElevatorPanelFromOpenCab(hit: hit, onPlate: true)
        }
        let cap = best.cap
        cap.removeAction(forKey: "press")
        cap.runAction(.sequence([.moveBy(x: 0, y: 0, z: 0.006, duration: 0.06),
                                 .moveBy(x: 0, y: 0, z: -0.006, duration: 0.14)]), forKey: "press")
        ElevatorRideSound.click(on: cameraNode)
        ToolBelt.elevatorButtonPressed(at: cap.worldPosition)         // Oct 16 (IV/V): a tool reaches for it (visual only)
        guard best.floor != floorNumber, elevatorReachableFloors.contains(best.floor) else {
            diag("elevator.button.inert", ["button": best.floor, "floor": floorNumber, "doors": "open"])
            return true
        }
        // Oct 9: the employee-ID reader. Refused: doors stay open, nothing moves.
        guard readEmployeeID(forFloor: best.floor, doors: "open") else { return true }
        let lit = HallwayScene.ElevatorButtonLook.selected()          // Oct 25: the one shared look
        cap.geometry?.materials = [lit]
        cameraNode.removeAction(forKey: Self.elevatorPanelApproachActionKey)
        diag("elevator.button.pressed", ["from": floorNumber, "to": best.floor, "doors": "open"])
        RocketElevator.markDeparture(from: floorNumber, to: best.floor)      // (Oct 15: selection -> control, measured)
        closeWhenDoorwayClear(departTo: best.floor)
        return true
    }

    /// Oct 19 (one car): someone (a resident) is walking through the doors right now.
    var doorwayBusy: (() -> Bool)?

    /// Oct 19 (one car): the doors never close on someone walking through them --
    /// the departure waits until the doorway is clear (at most 6 s).
    private func closeWhenDoorwayClear(departTo floor: Int, waited: TimeInterval = 0) {
        if waited < 6, doorwayBusy?() == true {
            if waited == 0 { diag("elevator.close.waitingForDoorway", ["floor": floorNumber]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.closeWhenDoorwayClear(departTo: floor, waited: waited + 0.25)
            }
            return
        }
        closeArrivalDoorsForContinuedRide(departTo: floor)
    }

    /// Oct 5 (open-door cab taps): inside the arrived cab with the doors
    /// open, a tap only means "walk out" when it goes THROUGH the doorway --
    /// its first real hit lies past the doors' closed plane, on the hallway
    /// side. Every cab-interior surface (walls, panel, buttons, posters,
    /// jambs, back wall) sits on the cab side of that plane, so it stays an
    /// in-cab tap. No hit at all also stays in the cab.
    func elevatorTapGoesThroughDoorway(hits: [SCNHitTestResult]) -> Bool {
        guard let exit = elevatorAwaitingEntryDirection,
              let left = elevatorLeftDoor, let right = elevatorRightDoor,
              let leftClosed = elevatorLeftClosedPosition,
              let rightClosed = elevatorRightClosedPosition,
              let hit = hits.first else { return false }
        let l = left.parent?.convertPosition(leftClosed, to: nil) ?? leftClosed
        let r = right.parent?.convertPosition(rightClosed, to: nil) ?? rightClosed
        let doorX = (l.x + r.x) / 2, doorZ = (l.z + r.z) / 2
        let w = hit.worldCoordinates
        let beyond = (w.x - doorX) * Float(exit.delta.col) + (w.z - doorZ) * Float(exit.delta.row)
        let through = beyond > 0.05
        diag("elevator.openDoorTap", ["through": through, "beyondDoorPlane": Double(beyond),
                                      "node": hit.node.name ?? "unnamed"])
        return through
    }

    /// Oct 5 (Admission): the same press a tap makes -- cap push, click, the
    /// button lights -- then the normal departure (elevatorDepart). Skipped
    /// if the car is no longer idle-waiting (e.g. the player pressed first).
    /// Oct 9 -- the cab's employee-ID reader, for a PLAYER's button press
    /// (automatic rides never come here). True = the trip may go: with an ID
    /// the lamp blinks green; a visitor riding to the Lobby/Administration
    /// gets no read at all. False = refused: a brief red blink and the
    /// denial beep -- nothing else changes, so repeated presses are harmless.
    private func readEmployeeID(forFloor floor: Int, doors: String) -> Bool {
        let hasID = Admission.isCompleted
        let root = scene?.rootNode
        guard ElevatorAccess.permits(floor, hasEmployeeID: hasID) else {
            ElevatorCardReader.tripAuthorized = false
            ElevatorCardReader.flash(granted: false, in: root)
            ElevatorCardReader.playDenied(on: cameraNode)
            diag("elevator.access.denied", ["from": floorNumber, "to": floor, "doors": doors])
            return false
        }
        // Oct 9: green the moment the floor is chosen, held for the whole trip
        // (the arriving cab picks it up -- ElevatorCardReader.tripAuthorized).
        ElevatorCardReader.tripAuthorized = hasID
        if hasID { ElevatorCardReader.showGranted(in: root) }
        diag("elevator.access.granted", ["from": floorNumber, "to": floor, "employeeID": hasID, "doors": doors])
        return true
    }

    private func autoPressElevatorButton(floor: Int) {
        guard isElevatorWaitingForFloor, elevatorInUse, elevatorDestinationFloor == nil,
              let depart = elevatorDepart else { return }
        if let cap = scene?.rootNode.childNode(withName: "elevatorControlButton_\(floor)", recursively: true) {
            cap.removeAction(forKey: "press")
            cap.runAction(.sequence([.moveBy(x: 0, y: 0, z: 0.006, duration: 0.06),
                                     .moveBy(x: 0, y: 0, z: -0.006, duration: 0.14)]), forKey: "press")
            let lit = HallwayScene.ElevatorButtonLook.selected()      // Oct 25: the one shared look
            cap.geometry?.materials = [lit]
        }
        ElevatorRideSound.click(on: cameraNode)
        // Oct 9: cosmetic only (automatic rides are never gated): an ID holder
        // riding sees their reader green like any authorized trip.
        ElevatorCardReader.tripAuthorized = Admission.isCompleted
        if Admission.isCompleted { ElevatorCardReader.showGranted(in: scene?.rootNode) }
        elevatorDepart = nil
        diag("elevator.button.autoPressed", ["from": floorNumber, "to": floor, "reason": "admission"])
        depart(floor)
    }

    /// Oct 5 (same-floor reopen): only an IDLE car -- WAITING, no destination
    /// chosen, departure still armed -- with both doors physically shut.
    /// departElevator clears isElevatorWaitingForFloor and elevatorDepart,
    /// so nothing here can fire once a trip has begun.
    private var elevatorSameFloorReopenAllowed: Bool {
        elevatorPanelAssistAllowed && elevatorDepart != nil && elevatorDestinationFloor == nil
    }

    /// Oct 5 (same-floor reopen): puts the cab into the exact state an
    /// arrival at this floor leaves it in (doors open, exit toward the
    /// hallway, panel live; Oct 7: no dwell-close) and opens the doors with
    /// the arrival's own door path. No ride, no rebuild, no camera change.
    private func reopenElevatorDoorsAtCurrentFloor() {
        guard let mount = elevatorMountDirection else { return }
        let entry = worldPosition(for: endCell)
        isElevatorWaitingForFloor = false
        elevatorDepart = nil
        elevatorDestinationFloor = nil
        elevatorInUse = false
        arrivedElevatorDoorOpen = true
        arrivalExitPermitted = false            // set by the doors' completion, as on arrival
        elevatorAwaitingEntryDirection = mount.opposite
        elevatorEntryCellCenterPosition = SCNVector3(entry.x, cameraNode.position.y, entry.z)
        refreshElevatorMissionSign()
        controlledArrivalDoorsOpened = false
        RocketElevator.rideIsRocket = false                         // (Oct 15: no ride -- classic doors)
        diag("elevator.sameFloorReopen", ["floor": floorNumber])
        playControlledArrivalDoorOpen()
    }

    /// Oct 5: the missed-button "land square at the panel" assist belongs only
    /// to a sealed cab -- WAITING for a floor with both doors physically at
    /// their closed positions (not opening, closing, or open at an arrival,
    /// and no exit available). Anything else: the miss moves nobody.
    private var elevatorPanelAssistAllowed: Bool {
        guard isElevatorWaitingForFloor, elevatorInUse, !arrivedElevatorDoorOpen,
              elevatorAwaitingEntryDirection == nil, !canStartElevatorExit,
              let left = elevatorLeftDoor, let right = elevatorRightDoor,
              let leftClosed = elevatorLeftClosedPosition,
              let rightClosed = elevatorRightClosedPosition else { return false }
        func isShut(_ door: SCNNode, _ closed: SCNVector3) -> Bool {
            let p = door.presentation.position
            return hypotf(p.x - closed.x, p.z - closed.z) < 0.03
        }
        return isShut(left, leftClosed) && isShut(right, rightClosed)
    }

    /// Oct 4: the same turn-and-glide landing as the automatic presentation,
    /// on demand (an imprecise tap at the controls). Skipped if already there.
    private func landAtElevatorPanel(reason: String) {
        guard elevatorPanelAssistAllowed, let cabCenter = elevatorCabCenter, let pose = elevatorPanelViewPose(cabCenter: cabCenter) else { return }
        let here = cameraNode.position
        let startYaw = Double(cameraNode.eulerAngles.y)
        let turn = shortestDelta(from: startYaw, to: pose.yaw)
        guard hypotf(pose.position.x - here.x, pose.position.z - here.z) > 0.05 || abs(turn) > 0.03 else { return }
        runTurnAndGlide(to: pose.position, yaw: startYaw + turn, duration: Self.elevatorPanelAssistDuration,
                        key: Self.elevatorPanelApproachActionKey)
        diag("elevator.panelLanding", ["reason": reason])
    }

    /// WAITING -> TRAVELING: a beat, the car starts (sound), then the same
    /// arrival hand-off as before, to the CHOSEN floor (ContentView reads
    /// elevatorDestinationFloor). Oct 4: the player is NOT moved or turned --
    /// they are standing in a moving car; free look stays theirs throughout.
    private func departElevator(to floor: Int, cabCenter: SCNVector3, restoreLighting: @escaping () -> Void) {
        elevatorDestinationFloor = floor
        isElevatorWaitingForFloor = false
        // Oct 15 (Rocket Elevator): a ride the PLAYER chose goes fast; the
        // building's own scripted rides (Admission, the escort) keep their pace.
        let rocket = RocketElevator.isOn && elevatorCinematicAutoFloor == nil
        RocketElevator.rideIsRocket = rocket
        RocketElevator.markDepartureIfStale(from: floorNumber, to: floor)
        // Oct 24 (onboarding polish): Admission's first ride is short (~2.5 s).
        // (read before onElevatorDestinationChosen below: it moves the escort to .riding, and
        // guidedAutoFloor is nil from then on)
        let admissionRide: TimeInterval? = !rocket && (admissionAutoFloor == floor || guidedAutoFloor?() == floor)
            ? Self.admissionRideSeconds : nil
        diag("elevator.staging.requested", ["to": floor, "rocket": rocket, "admissionRide": admissionRide != nil])
        onElevatorDestinationChosen?(floor)
        DispatchQueue.main.asyncAfter(deadline: .now() + (rocket ? RocketElevator.departBeat : Self.elevatorDepartBeat)) { [weak self] in
            guard let self else { return }
            diag("elevator.traveling", ["from": self.floorNumber, "to": floor])
            self.onElevatorTravel?(self.floorNumber, floor)                // (Oct 19: the one car runs now, with the player)
            ElevatorRideSound.startTravel(on: self.cameraNode)
            self.runElevatorIndicator(to: floor, rocket: rocket, fixedSeconds: admissionRide) { [weak self] in
                guard let self else { return }
                ElevatorRideSound.stopTravel(on: self.cameraNode)
                navLog("elevator: ride done -- requesting floor transition to \(floor)")
                diag("elevator.handoff.fired", ["mode": "interactive", "from": self.floorNumber, "to": floor])
                self.floorTransitionRequested = FloorTransitionEvent()
                // Always the heading-preserving hand-off: the view is wherever
                // the player left it (usually the panel), never snapped to the doors.
                let rawYaw = Double(self.cameraNode.eulerAngles.y)
                let sourceFacingDoorsYaw = self.elevatorMountDirection?.opposite.yaw ?? rawYaw
                // Where they stand, relative to the doors, for the destination cab.
                if let d = self.elevatorMountDirection {
                    let p = self.cameraNode.position
                    let fx = Double(d.delta.col), fz = Double(d.delta.row)
                    let dx = Double(p.x - cabCenter.x), dz = Double(p.z - cabCenter.z)
                    self.elevatorArrivalOffset = SIMD2(dx * fx + dz * fz, dx * -fz + dz * fx)
                }
                self.onElevatorArrivedControlled?(rawYaw - sourceFacingDoorsYaw)
                let traceLightingHop = ElevatorArrivalTrace.shared.beginPhase("departure.restoreLightingQueueHop")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    ElevatorArrivalTrace.shared.endPhase("departure.restoreLightingQueueHop", traceLightingHop)
                    let traceLighting = ElevatorArrivalTrace.shared.beginPhase("departure.restoreLighting")
                    restoreLighting()
                    ElevatorArrivalTrace.shared.endPhase("departure.restoreLighting", traceLighting)
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

    /// Oct 2 flight recorder: last mission-complete value logged (logging only).
    private var diagLastMissionComplete: Bool?

    private func refreshElevatorMissionSign() {
        let missionDone = isMissionComplete
        if diagLastMissionComplete != missionDone {
            diag(missionDone ? "mission.completed" : "mission.notComplete", ["floor": floorNumber])
            diagLastMissionComplete = missionDone
        }
        guard Self.missionGatesElevator, !arrivedElevatorDoorOpen, !isMissionComplete, let content = elevatorMissionWarningContent,
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

    /// Oct 16 (Supplies): the same one-line status, for the tool system.
    func showHint(_ text: String) { showMessage(text) }

    /// Oct 16 (Supplies II): a line that says what just happened and then goes
    /// by itself after `seconds` (transientMessage otherwise waits for the
    /// player to leave the cell -- in a big room that can be a long time).
    func showBrief(_ text: String, seconds: Double = 2.2) {
        showMessage(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.transientMessage == text else { return }
            self.transientMessage = nil
        }
    }

    /// Oct 16 (Supplies): a spray is under way (a carried extinguisher can't be sent back mid-spray).
    var isExtinguishing: Bool { !extinguishingFireCoords.isEmpty }

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
    private var appliedAspectMultiplier: Double = -1
    private func applyAspectCompensation(_ renderer: SCNSceneRenderer) {
        guard baseFogEnd > 0 || baseAttenEnd > 0 else { return }
        let viewport = renderer.currentViewport
        guard viewport.height > 0 else { return }
        let aspect = Double(viewport.width / viewport.height)
        let multiplier = min(1.6, max(1.0, 2.0 / max(aspect, 0.3)))
        // Oct 9 (heating): same values every frame unless the viewport
        // changes shape -- write them only when the multiplier changes,
        // instead of re-setting fog and the headlamp 60 times a second.
        guard multiplier != appliedAspectMultiplier else { return }
        appliedAspectMultiplier = multiplier

        if baseFogEnd > 0, let scene {
            scene.fogStartDistance = Self.convert(baseFogStart * multiplier)
            scene.fogEndDistance = Self.convert(baseFogEnd * multiplier)
        }
        if baseAttenEnd > 0, let headlampLight {
            headlampLight.attenuationStartDistance = Self.convert(baseAttenStart * multiplier)
            headlampLight.attenuationEndDistance = Self.convert(baseAttenEnd * multiplier)
        }
    }

    // Main-thread preparation arms this; SceneKit consumes it after rendering.
    // Keep the render-thread exchange separate from the main-thread UI callback.
    private let arrivalFrameLock = NSLock()
    private var arrivalFrameCompletion: (() -> Void)?

    func afterNextRenderedFrame(_ completion: @escaping () -> Void) {
        arrivalFrameLock.lock()
        arrivalFrameCompletion = completion
        arrivalFrameLock.unlock()
    }

    deinit {
        PerfMonitor.gauge("navControllers", -1)                           // Oct 21: live count (measurement)
        diag("navController.freed", ["controller": String(describing: ObjectIdentifier(self))])   // Oct 22 (stability pass)
    }

    /// Oct 24 (FrameTiming, measurement only): the start of render.callbackSpan.
    func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        FrameTiming.shared.rendererWillRender()
    }

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        FrameTiming.shared.rendererDidRender()                            // Oct 24: callback spans (measurement only)
        // Oct 25 (PP 8, the mud fix): the frame just drawn -- the camera and the elevator door as presented --
        // published for the main thread's timers (this thread holds SceneKit's scene lock already: no wait).
        let drawnCamera = cameraNode.presentation
        presentationSnapshot.publish(cameraWorld: drawnCamera.simdWorldPosition, cameraYaw: drawnCamera.eulerAngles.y,
                                     rightDoor: elevatorRightDoor?.presentation.simdPosition, at: CACurrentMediaTime())
        RenderHealth.shared.frameRendered()                               // Oct 9: measurement only
        PerfMonitor.shared.frameRendered()                                // Oct 21: frame gaps (measurement only)
        if renderer.currentViewport.width > 0, renderer.currentViewport.height > 0 {
            let door = elevatorRightDoor?.presentation.position
            ElevatorArrivalTrace.shared.rendered(self, scene: scene, doorPosition: door.map { ($0.x, $0.z) })
            arrivalFrameLock.lock()
            let completion = arrivalFrameCompletion
            arrivalFrameCompletion = nil
            arrivalFrameLock.unlock()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
        #if DEBUG
        if let buildNumber = pendingPresentationCheckBuildNumber {
            pendingPresentationCheckBuildNumber = nil
            LightingDeterminismCheck.runPresentationCheck(scene: scene, floor: floorNumber, buildNumber: buildNumber, checkpoint: "FIRST-RENDERED-FRAME")
        }
        #endif
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        FrameTiming.shared.rendererUpdate()                               // Oct 24: frame stamps (measurement only)
        defer { lastTime = time }
        // Oct 21 (slowdown hunt, measurement only): this update's cost, and while
        // walking, how far the camera actually moved for the time step used.
        let perf = PerfMonitor.begin("render.update")
        let rawStep = lastTime > 0 ? time - lastTime : 0
        let walkFrom: SCNVector3? = PerfMonitor.enabled && isAnimating && phase == .freeMove ? cameraNode.position : nil
        defer {
            PerfMonitor.end(perf)
            if let walkFrom, rawStep > 0 {
                let p = cameraNode.position
                let kind: PerfMonitor.WalkKind = cruiseActive ? .cruise : (freeMoveHeld ? .held : .tap)
                PerfMonitor.shared.walkFrame(kind, metres: Double(hypotf(p.x - walkFrom.x, p.z - walkFrom.z)),
                                             step: min(rawStep, 1.0 / 20.0), raw: rawStep)
            }
        }
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

        case .freeMove:
            // Oct 10: the continuous walk (WALK button) owns this movement.
            if cruiseActive { stepContinuousWalk(dt: dt); return }
            guard let geometry = freeWalkGeometry else { finishFreeMove(); return }
            if freeMoveHeld {
                // Released: stop right here. No completion, no snap.
                // (Oct 16 WALK LATCH: unless the walk is latched -- then it goes
                // straight on at its pace with no finger down, until a tap.)
                guard walkingHeld || walkLatched else { finishFreeMove(); return }
                let latchedNoFinger = !walkingHeld
                if latchedNoFinger, let target = latchTurnTarget {
                    // The rest of a turn the finger asked for (a flick's quarter turn), at the held walk's own rate.
                    let yaw = Self.rateLimitedYaw(current: Double(cameraNode.eulerAngles.y), target: target,
                                                  maxStep: heldWalkTurnRateLimit.isFinite ? heldWalkTurnRateLimit * dt : .infinity)
                    cameraNode.eulerAngles = SCNVector3(0, Float(yaw), 0)
                    if yaw == target, latchTurnTarget == target { latchTurnTarget = nil }
                }
                // Signed Y throttle (see updateHeldNavigation): stopping or
                // backing up ends a "sustained forward" run, so the
                // 3-cell -> 1.5x acceleration starts over.
                let throttle = heldThrottle
                if throttle <= 0 { heldDistance = 0 }
                let targetPace = throttle > 0 && heldDistance >= 3 * Double(cellSize) ? Self.fastWalkPace : 1.0
                movementPace += (targetPace - movementPace) * (1 - exp(-dt / 0.3))
                SoundEffects.setWalkingPace(Float(movementPace))
                // Turn toward the finger's target yaw, rate-limited while moving.
                stepHeldSteering(dt: dt, translating: throttle != 0)
                // Heading sampled every frame from the camera itself.
                let forward = FreeWalkGeometry.forward(yaw: Double(cameraNode.eulerAngles.y))
                // Oct 16 (Bonzo PP, Part 1): the latched walk, no finger down, cruises a
                // little slower (WALK LATCH pace); a finger on it is the held walk, at full pace.
                // Eased both ways, so taking or letting go never jolts.
                // (Oct 20: the latched walk is an automatic walk -- at autoWalkSpeedScale of its old pace)
                latchPaceScale += ((latchedNoFinger ? Self.walkLatchPace * Self.autoWalkSpeedScale : 1) - latchPaceScale) * (1 - exp(-dt / 0.35))
                let step = travelSpeed * movementPace * throttle * dt * latchPaceScale
                let position = cameraNode.position
                let next = geometry.slideEndpoint(from: SCNVector3(position.x, eyeHeight, position.z),
                                                  dx: forward.x * step, dz: forward.z * step)
                let moved = Double(hypotf(next.x - position.x, next.z - position.z))
                cameraNode.position = next
                if throttle > 0 { heldDistance += moved }
                // Oct 16 (WALK LATCH): no finger down and walked into a wall (or someone) --
                // the latched walk ends there, as letting go always did.
                if latchedNoFinger {
                    latchStall = step > 0.0005 && moved < step * 0.15 ? latchStall + dt : 0
                    if latchStall > 0.4 {
                        latchStall = 0
                        finishFreeMove()
                        return
                    }
                }
                // Oct 9: holding into a character on guard -- she reacts.
                if throttle > 0, !characterKeepOuts.isEmpty, moved < step * 0.5,
                   segmentMeetsCharacter(x: Double(next.x), z: Double(next.z), dx: forward.x * 0.3, dz: forward.z * 0.3) {
                    onCharacterBlockBump?()
                }
                // Footsteps whenever this hold is actually moving (Oct 3
                // stabilization: a long-press walk from standing is no longer
                // silent); silent while stopped or pressed against a wall.
                setFreeWalkFootsteps(moved > 0.0005, reverse: throttle < 0)
                freeWalkTrackCell(next)
            } else {
                // Oct 10: only a live tap walk drives this branch (a movement
                // just stopped in place from the main thread must not replay
                // a stale tap path on a frame already in flight).
                guard freeTapWalkActive else { return }
                // Tap-to-stop: end right here -- this position, this yaw.
                if freeTapStopRequested {
                    freeTapStopRequested = false
                    finishFreeMove()
                    break
                }
                segmentProgress += dt / max(freeTapDuration, 0.001)
                let t = min(1.0, segmentProgress)
                let length = freeTapArc.last ?? 0
                let travelled: Double
                if freeTapRampTime > 0 {
                    travelled = Self.tapWalkDistance(elapsed: t * freeTapDuration, length: length,
                                                     speed: travelSpeed * Self.autoWalkSpeedScale, ramp: freeTapRampTime)   // (Oct 20: as timed)
                } else {
                    travelled = t * t * (3 - 2 * t) * length
                }
                let position = t >= 1.0 ? segmentTarget : freeTapPosition(atDistance: travelled)
                cameraNode.position = position
                if freeTapEndYaw != freeTapStartYaw { // tapped off-centre: turn toward it
                    let u = min(1.0, t * freeTapDuration / max(freeTapTurnDuration, 0.001))
                    let turn = u * u * (3 - 2 * u)
                    let yaw = u >= 1.0 ? freeTapEndYaw : freeTapStartYaw + (freeTapEndYaw - freeTapStartYaw) * turn
                    cameraNode.eulerAngles = SCNVector3(0, Float(yaw), 0)
                }
                freeWalkTrackCell(position)
                if t >= 1.0 { finishFreeMove() }
            }

        case .pivot:
            segmentProgress += dt / (standaloneRotation ? standalonePivotDuration : pivotDuration)
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
                            // Oct 10: a LEFT/RIGHT pressed during this pivot
                            // runs now, after it -- never overlapping it.
                            self.hudPivotInFlight = false
                            let walkOn = self.cruiseWalkAfterPivot
                            self.cruiseWalkAfterPivot = false
                            if let next = self.pendingHUDPivot {
                                self.pendingHUDPivot = nil
                                self.continuousWalkTurnTapped(next)
                            } else if walkOn {
                                self.startContinuousWalk()      // Smart WALK: turned at a decision -- go
                            }
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
            let targetPace = walkingHeld && heldDistance >= 2 * Double(cellSize) ? Self.fastWalkPaceClassic : 1.0
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
                            // Oct 10 (contextual navigation): the lobby's
                            // ceremonial walk no longer waits for a tap at the
                            // elevator -- the doors open on their own and the
                            // ordinary boarding sequence continues.
                            if self.ceremonialElevatorAutoOpen {
                                self.ceremonialElevatorAutoOpen = false
                                if newCell == self.endCell { self.scheduleCeremonialElevatorOpen() }
                            }
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

// MARK: - Oct 18 (inter-floor life): the elevator, as diagnostics see it

/// What a character's door cycle is for (the panel and the hall indicator).
enum CharacterElevatorPurpose: Equatable {
    /// It is leaving this floor, for `to` (nil: unknown).
    case departure(to: Int?)
    /// It is stepping out here, having come from `from` (nil: unknown).
    case arrival(from: Int?)
    /// Anything else (an escort, someone going home).
    case other

    var isArrival: Bool { if case .arrival = self { return true } else { return false } }
    var text: String {
        switch self {
        case .departure(let to): return "departure" + (to.map { " for F\($0)" } ?? "")
        case .arrival(let from): return "arrival" + (from.map { " from F\($0)" } ?? "")
        case .other: return "door cycle"
        }
    }
}

extension TapNavigationController {
    /// The floor this controller's scene is (its elevator's floor).
    var elevatorFloor: Int { floorNumber }

    /// What the PLAYER's elevator machinery is doing right now, from its own
    /// flags (nil: the player isn't using it). Words only -- no new state.
    var playerElevatorState: String? {
        if elevatorAwaitingEntryDirection != nil {
            return arrivedElevatorDoorOpen ? "player arrived: in the cab, doors open" : "player arrived: in the cab"
        }
        if isElevatorWaitingForFloor { return "player in the cab, doors shut, choosing a floor" }
        if elevatorInUse {
            return elevatorDestinationFloor.map { "player's ride under way (to F\($0))" } ?? "player boarding / riding"
        }
        if arrivedElevatorDoorOpen { return "player's cab standing open" }
        if elevatorLeftDoor?.action(forKey: "arrivalCloseBehind") != nil || elevatorRightDoor?.action(forKey: "arrivalCloseBehind") != nil {
            return "doors closing behind the player"
        }
        return nil
    }

    /// Why a tap on the doors (openElevator) would be refused right now -- the
    /// same checks, in the same order (nil: it would be accepted).
    var playerElevatorRefusal: String? {
        if elevatorLeftDoor?.action(forKey: "arrivalCloseBehind") != nil || elevatorRightDoor?.action(forKey: "arrivalCloseBehind") != nil {
            return "the doors are still closing behind you"
        }
        if !characterCycleJoinable {                     // (Oct 19: a resident's open doors: the player gets in too)
            if let c = characterElevatorCycleInfo { return "\(c.who) is using it (\(c.phase))" }
            if characterUsingElevator { return "a character is using it" }
        }
        if elevatorInUse { return "your ride is under way" }
        if chuteInUse { return "the chute is in use" }
        if elevatorAwaitingEntryDirection != nil { return "you're in the cab: step out (or press a floor)" }
        if elevatorLeftDoor == nil || elevatorRightDoor == nil || elevatorMountDirection == nil { return "no elevator on this floor" }
        if let next = nextFloorNumber, next == floorNumber { return "no other floor to go to" }
        if !(isMissionComplete || !Self.missionGatesElevator) { return "this floor's mission isn't done" }
        if currentCell != endCell { return "walk up to the doors" }
        return nil
    }

    /// Oct 18: the hall's floor indicator (the display over the doors, outside):
    /// `floor` with the arrow for `direction` (1 up, -1 down) lit and the other
    /// dimmed; nil puts it back exactly as built (this floor, both arrows lit).
    func showHallIndicator(floor: Int?, direction: Int) {
        let wanted: (floor: Int, direction: Int)? = floor.map { ($0, direction) }
        if wanted?.floor == hallIndicatorShown?.floor, wanted?.direction == hallIndicatorShown?.direction { return }
        guard let root = scene?.rootNode,
              let readout = root.childNode(withName: "elevatorExteriorFloorNumber", recursively: true),
              let text = readout.geometry as? SCNText else { return }
        let up = root.childNode(withName: "elevatorExteriorUpArrow", recursively: true)
        let down = root.childNode(withName: "elevatorExteriorDownArrow", recursively: true)
        if hallIndicatorLitMaterial == nil { hallIndicatorLitMaterial = up?.geometry?.firstMaterial }
        hallIndicatorShown = wanted
        let shown = "\(wanted?.floor ?? floorNumber)"
        if (text.string as? String) != shown {
            text.string = shown
            let (lo, hi) = text.boundingBox
            let k = readout.scale.x
            readout.position = SCNVector3(-(lo.x + hi.x) * k / 2, -(lo.y + hi.y) * k / 2, 0.001)
        }
        let dim = SCNMaterial()
        dim.diffuse.contents = UIColor(red: 0.22, green: 0.12, blue: 0.03, alpha: 1)
        dim.lightingModel = .constant
        if let lit = hallIndicatorLitMaterial {
            // Oct 18 (elevator life): only the way the car is going is lit; a car
            // standing still lights neither. (nil -- nothing known -- is as built.)
            guard let d = wanted?.direction else {
                up?.geometry?.materials = [lit]
                down?.geometry?.materials = [lit]
                return
            }
            up?.geometry?.materials = [d > 0 ? lit : dim]
            down?.geometry?.materials = [d < 0 ? lit : dim]
        }
    }
}

// MARK: - FREE-WALK EXPERIMENT geometry (Sept 29)

/// The building's walkable floor for free (non-centered) walking, derived
/// from the authored grid: a point is legal when its containing cell is an
/// open cell and it keeps `wallMargin` clear of every CLOSED side of that
/// cell (a wall, a missing neighbour, or a closed door -- `openEdges`) and
/// of the wall corner where two open sides meet a missing diagonal cell.
/// Same idea as HallwayScene's walkableRects (which keep their own 0.4 m inset
/// for the legacy free-roam path), but door-aware, with its own body clearance
/// (playerClearance). No furniture, no props, no physics.
struct FreeWalkGeometry {
    struct Edge: Hashable {
        let cell: GridCoordinate
        let direction: Direction
    }

    let cells: Set<GridCoordinate>
    let openEdges: Set<Edge>
    let cellSize: Double
    /// EDDIE HAS A BODY (polish pass #6): minimum distance from the player's
    /// X/Z (= the camera, the eyes) to the logical cell boundary of any
    /// closed side. Wall panels are 0.1 m boxes CENTRED on that boundary,
    /// so the visible wallpaper is 0.05 m nearer: eye-to-wallpaper
    /// clearance = playerClearance - 0.05 (was 0.4 -> 0.35 m, now 0.45 m).
    static let playerClearance: Double = 1.4
    var wallMargin: Double = FreeWalkGeometry.playerClearance
    /// A position must be this far into a neighbouring cell before the
    /// containing cell changes (kills flip-flopping on a boundary line).
    var hysteresis: Double = 0.05
    /// Collision sampling step along a movement segment.
    var sampleStep: Double = 0.02

    /// Oct 9 (Juanita in the doorway): a circle around a CHARACTER the
    /// player's eyes may not enter -- a conversational distance, so the
    /// camera never reaches her body. Unlike walls it is never "slid into":
    /// a player already inside one (she arrived next to them) may only move
    /// AWAY from its centre, never closer.
    struct KeepOut: Hashable {
        let x: Double
        let z: Double
        let radius: Double
    }
    var keepOuts: [KeepOut] = []

    func insideKeepOut(x: Double, z: Double) -> Bool {
        keepOuts.contains { k in ((x - k.x) * (x - k.x) + (z - k.z) * (z - k.z)).squareRoot() < k.radius }
    }

    /// The keep-out rule for one step: entering is refused; inside, only
    /// steps that do not get closer to the centre.
    private func keepOutAllows(fromX: Double, fromZ: Double, toX: Double, toZ: Double) -> Bool {
        for k in keepOuts {
            let to = ((toX - k.x) * (toX - k.x) + (toZ - k.z) * (toZ - k.z)).squareRoot()
            guard to < k.radius else { continue }
            let from = ((fromX - k.x) * (fromX - k.x) + (fromZ - k.z) * (fromZ - k.z)).squareRoot()
            if to < from - 1e-9 { return false }
        }
        return true
    }

    /// One movement step: walls exactly as before, plus the keep-outs.
    func canStep(fromX: Double, fromZ: Double, toX: Double, toZ: Double) -> Bool {
        isWallLegal(x: toX, z: toZ) && keepOutAllows(fromX: fromX, fromZ: fromZ, toX: toX, toZ: toZ)
    }

    /// Camera forward on the floor plane for a SceneKit yaw (0 = north = -z,
    /// +pi/2 = west), matching Direction.yaw.
    static func forward(yaw: Double) -> (x: Double, z: Double) {
        (-sin(yaw), -cos(yaw))
    }

    /// The grid cell whose square contains (x, z). The ONE implementation.
    static func containingCell(x: Double, z: Double, cellSize: Double) -> GridCoordinate {
        GridCoordinate(row: Int((z / cellSize).rounded()), col: Int((x / cellSize).rounded()))
    }

    /// Containing cell, but staying in `previous` until the point is
    /// `hysteresis` beyond its edge.
    func containingCell(x: Double, z: Double, previous: GridCoordinate?) -> GridCoordinate {
        if let previous {
            let half = cellSize / 2 + hysteresis
            if abs(x - Double(previous.col) * cellSize) <= half, abs(z - Double(previous.row) * cellSize) <= half {
                return previous
            }
        }
        return Self.containingCell(x: x, z: z, cellSize: cellSize)
    }

    /// A position the player may occupy: walls and every keep-out.
    func isLegal(x: Double, z: Double) -> Bool {
        isWallLegal(x: x, z: z) && !insideKeepOut(x: x, z: z)
    }

    /// The building alone (cells, closed sides, corners) -- the rule
    /// isLegal was before keep-outs existed.
    func isWallLegal(x: Double, z: Double) -> Bool {
        let cell = Self.containingCell(x: x, z: z, cellSize: cellSize)
        guard cells.contains(cell) else { return false }
        let dx = x - Double(cell.col) * cellSize
        let dz = z - Double(cell.row) * cellSize
        let limit = cellSize / 2 - wallMargin
        func isOpen(_ d: Direction) -> Bool { openEdges.contains(Edge(cell: cell, direction: d)) }
        if dx > limit, !isOpen(.east) { return false }
        if dx < -limit, !isOpen(.west) { return false }
        if dz > limit, !isOpen(.south) { return false }
        if dz < -limit, !isOpen(.north) { return false }
        // Inner wall corner: both sides open but the diagonal cell isn't.
        // ROUNDED CORNER (Sept 30): the body keeps wallMargin from the corner
        // POINT itself (a round body's clearance), instead of from a square
        // that stuck out ~0.21 m further on the diagonal. Wall faces and
        // every other clearance are unchanged; only that square tip is legal.
        if abs(dx) > limit, abs(dz) > limit {
            let diagonal = GridCoordinate(row: cell.row + (dz > 0 ? 1 : -1), col: cell.col + (dx > 0 ? 1 : -1))
            if !cells.contains(diagonal) {
                let px = cellSize / 2 - abs(dx), pz = cellSize / 2 - abs(dz)
                if px * px + pz * pz < wallMargin * wallMargin { return false }
            }
        }
        return true
    }

    /// The wall corner point (x, z) whose rounded clearance covers (x, z):
    /// the point is in the corner zone of its cell, both of those sides are
    /// open and the diagonal cell is missing. nil everywhere else.
    func innerCornerPost(x: Double, z: Double) -> (x: Double, z: Double)? {
        let cell = Self.containingCell(x: x, z: z, cellSize: cellSize)
        guard cells.contains(cell) else { return nil }
        let dx = x - Double(cell.col) * cellSize
        let dz = z - Double(cell.row) * cellSize
        let limit = cellSize / 2 - wallMargin
        guard abs(dx) > limit, abs(dz) > limit else { return nil }
        let sx = dx > 0 ? 1 : -1, sz = dz > 0 ? 1 : -1
        guard openEdges.contains(Edge(cell: cell, direction: sx > 0 ? .east : .west)),
              openEdges.contains(Edge(cell: cell, direction: sz > 0 ? .south : .north)),
              !cells.contains(GridCoordinate(row: cell.row + sz, col: cell.col + sx)) else { return nil }
        return (Double(cell.col) * cellSize + Double(sx) * cellSize / 2,
                Double(cell.row) * cellSize + Double(sz) * cellSize / 2)
    }

    /// CORNER SLIDE (Sept 30): a sub-step blocked by a rounded wall corner
    /// keeps its component along the corner's tangent (the same "drop only
    /// the into-wall part" rule as a straight wall, where the tangent simply
    /// is the X or Z axis). Never longer than the request, never changes
    /// yaw, never chooses a hallway; nil (-> the old X/Z rule) when there is
    /// no corner, no tangential part (dead-on) or the result isn't legal.
    func cornerSlideStep(x: Double, z: Double, sx: Double, sz: Double) -> (dx: Double, dz: Double)? {
        guard let post = innerCornerPost(x: x + sx, z: z + sz) else { return nil }
        let nx = x - post.x, nz = z - post.z
        let d = (nx * nx + nz * nz).squareRoot()
        guard d > 1e-9 else { return nil }
        let tx = -nz / d, tz = nx / d
        let along = sx * tx + sz * tz
        guard abs(along) > 1e-9 else { return nil }
        let step = (dx: tx * along, dz: tz * along)
        return isLegal(x: x + step.dx, z: z + step.dz) ? step : nil
    }

    /// Walks the straight segment from `start` toward `end` and returns the
    /// last legal point before the building blocks it (or `end`). Never
    /// redirects, never slides. A start that is already outside the legal
    /// floor (e.g. left there by a scripted move) only has to stay inside
    /// open cells, so the player can never be trapped.
    /// WALL SLIDING (polish pass #4). Walks the requested displacement in
    /// sampleStep sub-steps. A sub-step the building allows is taken as is.
    /// A blocked one keeps only its X or its Z component -- whichever is
    /// still legal (the larger one if both are, e.g. rubbing a corner post)
    /// -- and drops the component that would enter the building. Neither
    /// legal: stop there (dead-on wall, corner). Uses isLegal, so walls,
    /// missing cells, closed doors and the 0.4 m margin stay exactly as
    /// solid as before; it only ever DROPS part of the request, never
    /// redirects, turns, or looks ahead. A start already off the legal
    /// floor (left by a scripted move) keeps the old straight-line rule.
    /// Returns every position visited, start first.
    func slidePath(from start: SCNVector3, dx: Double, dz: Double) -> [SCNVector3] {
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 0 else { return [start] }
        guard isWallLegal(x: Double(start.x), z: Double(start.z)) else {
            let end = SCNVector3(start.x + Float(dx), start.y, start.z + Float(dz))
            return [start, legalEndpoint(from: start, to: end)]
        }
        let count = max(1, Int((length / sampleStep).rounded(.up)))
        let sx = dx / Double(count), sz = dz / Double(count)
        var x = Double(start.x), z = Double(start.z)
        var path = [start]
        for _ in 0..<count {
            if canStep(fromX: x, fromZ: z, toX: x + sx, toZ: z + sz) {
                x += sx; z += sz
            } else if let corner = cornerSlideStep(x: x, z: z, sx: sx, sz: sz) {
                x += corner.dx; z += corner.dz
            } else {
                let xOK = abs(sx) > 1e-9 && canStep(fromX: x, fromZ: z, toX: x + sx, toZ: z)
                let zOK = abs(sz) > 1e-9 && canStep(fromX: x, fromZ: z, toX: x, toZ: z + sz)
                if xOK, !zOK || abs(sx) >= abs(sz) { x += sx }
                else if zOK { z += sz }
                else { break }
            }
            path.append(SCNVector3(Float(x), start.y, Float(z)))
        }
        return path
    }

    /// Where a requested displacement ends after wall sliding.
    func slideEndpoint(from start: SCNVector3, dx: Double, dz: Double) -> SCNVector3 {
        slidePath(from: start, dx: dx, dz: dz).last ?? start
    }

    func legalEndpoint(from start: SCNVector3, to end: SCNVector3) -> SCNVector3 {
        let dx = Double(end.x - start.x), dz = Double(end.z - start.z)
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 0 else { return start }
        let strict = isWallLegal(x: Double(start.x), z: Double(start.z))
        let count = max(1, Int((length / sampleStep).rounded(.up)))
        var last = start
        for i in 1...count {
            let f = Double(i) / Double(count)
            let x = Double(start.x) + dx * f, z = Double(start.z) + dz * f
            // Oct 9: keep-outs hold in both modes (never closer to a character).
            let keep = keepOutAllows(fromX: Double(last.x), fromZ: Double(last.z), toX: x, toZ: z)
            let ok = keep && (strict ? isWallLegal(x: x, z: z)
                                     : cells.contains(Self.containingCell(x: x, z: z, cellSize: cellSize)))
            guard ok else { return last }
            last = SCNVector3(Float(x), end.y, Float(z))
        }
        return end
    }
}

// MARK: - Oct 11 -- RESUME (see ResumeState)

extension TapNavigationController {
    /// Saves where the player is: this floor, the camera's exact free-walk
    /// x/z and yaw. Not a place to come back to is never saved as such:
    ///   seated at (or sitting down at / getting up from) the office
    ///   computer -> the spot getting up leads to, standing, facing the door;
    ///   still in an arrived elevator cab -> just outside its doors, facing out;
    ///   riding / the doors cycling / Decorate -> nothing (the last point stands).
    func saveResumePoint(reason: String) {
        guard ResumeState.isRecording, !decorateModeEnabled, !evictionLocked, !BonzoEviction.isActive else { return }   // (Oct 16: never mid-eviction)
        // Oct 11 (the staff meeting): seated at the conference table -> saved
        // standing beside it (the same safe spot getting up ends on); a
        // relaunch never resumes inside the chair.
        if isSeatedInMeeting {
            guard floorNumber == ConferenceRoom.floor, let spot = ConferenceMeeting.standUpSpot else { return }
            ResumeState.save(.init(floor: floorNumber, x: spot.position.x, z: spot.position.y, yaw: Float(spot.yaw)),
                             reason: reason + ".meetingSeat")
            return
        }
        if OfficeComputer.shared.isActive {
            guard floorNumber == PlayerOffice.floor else { return }
            let spot = PlayerOffice.standUpSpot
            ResumeState.save(.init(floor: floorNumber, x: spot.position.x, z: spot.position.y, yaw: Float(spot.yaw)),
                             reason: reason + ".seated")
            return
        }
        if let out = elevatorAwaitingEntryDirection {
            let p = worldPosition(for: endCell)
            ResumeState.save(.init(floor: floorNumber, x: p.x, z: p.z, yaw: Float(out.yaw)), reason: reason + ".cab")
            return
        }
        guard !elevatorInUse, !isElevatorWaitingForFloor else { return }
        let p = cameraNode.position
        ResumeState.save(.init(floor: floorNumber, x: p.x, z: p.z, yaw: cameraNode.eulerAngles.y), reason: reason)
    }

    /// Places the player at a saved point on this just-built floor: the exact
    /// spot while it is still legal walking floor (layouts and characters may
    /// have changed since); else the centre of its cell; else the elevator
    /// landing. Exact yaw either way (free look). Nothing is triggered --
    /// no arrival pickups, no landings, no story beats. Returns the cell.
    @discardableResult
    func resume(at point: ResumeState.Point) -> GridCoordinate {
        let geometry = makeFreeWalkGeometry()
        var position = SCNVector3(point.x, cameraNode.position.y, point.z)
        var cell = geometry.containingCell(x: Double(point.x), z: Double(point.z), previous: nil)
        var how = "exact"
        if !cells.contains(cell) || !geometry.isLegal(x: Double(point.x), z: Double(point.z)) {
            if !cells.contains(cell) { cell = endCell; how = "elevatorLanding" } else { how = "cellCentre" }
            let c = worldPosition(for: cell)
            position = SCNVector3(c.x, position.y, c.z)
        }
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        cameraNode.position = position
        cameraNode.eulerAngles = SCNVector3(0, point.yaw, 0)
        SCNTransaction.commit()
        currentCell = cell
        facing = nearestCardinal(toYaw: Double(point.yaw))
        diag("resume.placed", ["floor": floorNumber, "cell": cell, "how": how,
                               "pos": String(format: "%.2f,%.2f", position.x, position.z)])
        return cell
    }
}

// MARK: - Oct 11 -- a held landing pitch (the ID terminal's card reveal)

extension TapNavigationController {
    static let landingPitchActionKey = "landingPitch"

    /// Tilts the view to `pitch` (radians, negative = down) while the player
    /// stays in landing `kind`'s pose; the moment they leave it (any walk,
    /// turn or drag), the view eases back to level. Only the pitch moves --
    /// never position or yaw -- and nothing else in the game uses pitch on
    /// this floor (the office computer's seated pitch is Floor 3's own).
    func holdLandingPitch(_ pitch: Float, whileIn kind: String) {
        landingPitchGeneration += 1
        let generation = landingPitchGeneration
        landingPitchKind = kind
        animatePitch(to: pitch, duration: 0.5)
        watchLandingPitch(generation)
    }

    private func watchLandingPitch(_ generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, generation == self.landingPitchGeneration, let kind = self.landingPitchKind else { return }
            if self.isInLandingPose(kind) { self.watchLandingPitch(generation); return }
            self.landingPitchKind = nil
            self.animatePitch(to: 0, duration: 0.25)
        }
    }

    /// Eases ONLY the pitch (other code may set yaw meanwhile -- untouched).
    private func animatePitch(to target: Float, duration: Double) {
        let start = cameraNode.eulerAngles.x
        cameraNode.removeAction(forKey: Self.landingPitchActionKey)
        guard abs(target - start) > 0.0005 else { return }
        let ease = SCNAction.customAction(duration: duration) { node, elapsed in
            let u = Float(min(1, Double(elapsed) / duration))
            node.eulerAngles.x = start + (target - start) * (u * u * (3 - 2 * u))
        }
        cameraNode.runAction(ease, forKey: Self.landingPitchActionKey)
    }
}


/// Oct 12 (developer diagnostics, temporary): what the continuous walk's last
/// corner did -- WIDE curve (radius), TIGHT turn (and why), a junction stop,
/// or a curve interrupted/blocked. Shown for a few seconds above the HUD row
/// in developer builds (ContinuousWalkControls) and logged as
/// `cruise.cornerNote`. Written on the render thread, read on main.
nonisolated final class CruiseCornerNote: @unchecked Sendable {
    static let shared = CruiseCornerNote()
    private let lock = NSLock()
    private var text = ""
    private var at: CFTimeInterval = 0

    func post(_ note: String) {
        lock.withLock { text = note; at = CACurrentMediaTime() }
        diag("cruise.cornerNote", ["note": note])
        #if DEBUG
        print("[Nav] \(note)")                                     // (Oct 19: the console, not the screen)
        #endif
    }

    /// Oct 19: the notes show on screen only when asked for -- launch argument
    /// `-HallwaysNavNotes YES` (DEBUG builds). Normal play never shows them.
    static var showsOnScreen: Bool { UserDefaults.standard.bool(forKey: "HallwaysNavNotes") }

    /// The last note, if it is recent.
    func recent(within seconds: Double = 4) -> String? {
        lock.withLock { CACurrentMediaTime() - at < seconds ? text : nil }
    }
}


// MARK: - Oct 15 -- the Smart Tap + Rocket Elevator experiment (switches, tuning, logging)

/// SMART TAP: the GO / STOP / LEFT / RIGHT buttons are hidden (their code is
/// untouched); taps do the navigating. The HUD's centre button still appears
/// when it offers an interaction (OPEN, USE, PHOTO, STAND, SKIP...).
/// Contextual taps (ContentView.handleTap): Juanita mid-directions, the area
/// round the ID kiosk, Tinky while he escorts, Tinky's desk from reception.
/// Revert: launch with `-HallwaysClassicControls YES`.
enum SmartTap {
    static var isOn: Bool { !UserDefaults.standard.bool(forKey: "HallwaysClassicControls") }
    /// Oct 15: HUD actions that are taps on the thing itself under Smart Tap
    /// (doors, the elevator, the office computer, the meeting chair).
    static let hiddenActionLabels: Set<String> = ["OPEN", "USE", "ENTER"]
    /// A tap whose floor/wall point lands within this of the ID kiosk's
    /// standing spot is a tap on the kiosk (while the ID is still to do).
    static let kioskReach: Float = 1.9
    /// A tap landing within this of the escorting character is a tap on him.
    static let guideReach: Float = 1.0

    /// DEBUG builds only: one line per Smart Tap decision.
    static func log(_ decision: String, _ fields: KeyValuePairs<String, Any?> = [:]) {
        #if DEBUG
        var text = "smartTap " + decision
        for (k, v) in fields { text += " \(k)=\(v.map { "\($0)" } ?? "nil")" }
        diag("smartTap", ["decision": text])
        #endif
    }
}

/// ROCKET ELEVATOR: rides the player chooses run on these timings; the
/// building's scripted rides (the first trip from the lobby, the escort to
/// Floor 3) keep the classic ones. Revert: `-HallwaysClassicElevator YES`.
/// Classic, from a floor chosen with the doors open: doors close 1.6 s,
/// beat 0.1 s, floor counter 0.5 + 4.5 s, [floor rebuild], doors open 1.6 s
/// = 8.3 s + rebuild. Rocket: 0.35 + 0.05 + 0.05 + 0.45 + [rebuild] + 0.45
/// = 1.35 s + rebuild.
enum RocketElevator {
    static var isOn: Bool { !UserDefaults.standard.bool(forKey: "HallwaysClassicElevator") }
    static let classicDoorSlide: TimeInterval = 1.6
    static let doorClose: TimeInterval = 0.35
    static let departBeat: TimeInterval = 0.05
    static let indicatorLeadIn: TimeInterval = 0.05
    static let indicatorCountingSpan: TimeInterval = 0.45
    static let doorOpen: TimeInterval = 0.45
    static let faceDoors: TimeInterval = 0.45

    /// Oct 16 (Bonzo PP, Part 2): every floor passed shows for this long (readable:
    /// 3, 4, 5 ...), so a long trip takes longer -- the doors stay shut until the
    /// last number is up (the indicator's own completion hands the ride off).
    static let indicatorSecondsPerFloor: TimeInterval = 0.3

    static func indicatorStepDelay(step: Int, steps: Int) -> TimeInterval {
        // (was: the whole count squeezed into indicatorCountingSpan, however many floors)
        indicatorLeadIn + indicatorSecondsPerFloor * Double(step)
    }

    /// Set at each departure; read (once) by the DESTINATION floor's new
    /// controller when its doors open.
    static var rideIsRocket = false
    static func consumeArrival() -> Bool {
        defer { rideIsRocket = false }
        return rideIsRocket
    }

    // (diagnostics: selection -> control, measured)
    private static var departedAt: CFTimeInterval = 0
    private static var trip = ""
    static func markDeparture(from: Int, to: Int) {
        departedAt = CACurrentMediaTime()
        trip = "\(from)->\(to)"
    }
    static func markDepartureIfStale(from: Int, to: Int) {
        if CACurrentMediaTime() - departedAt > 3 { markDeparture(from: from, to: to) }
    }
    static func markControlReturned(floor: Int) {
        let seconds = CACurrentMediaTime() - departedAt
        diag("elevator.rocket.controlReturned", ["trip": trip, "seconds": (seconds * 100).rounded() / 100])
    }
}
