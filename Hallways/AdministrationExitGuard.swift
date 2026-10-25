import SceneKit
import simd

/// Oct 9 -- JUANITA KEEPS THE NEW EMPLOYEE IN ADMINISTRATION until Tinky
/// has taken them in hand.
///
/// The onboarding order (existing state only, nothing new persisted):
///   1. the ID from the kiosk ............... Admission.isCompleted
///   2. Tinky in his office ("follow me") ... GuidedJourney.trip != nil
///   3. Tinky leads them out to Floor 3 ..... (the journey)
/// Between 1 and 2 the way out is closed by a PERSON, not by the doors.
/// Oct 9 (Juanita 2.0): when the visitor ACCEPTS their ID photo (the card is
/// ~2.5 s from coming out) she comes out from behind the counter (round its
/// north end, never through it) and waits BESIDE the doorway -- the exit
/// still open. When the card is taken she steps into the doorway, just
/// inside the Double Glass doors, facing into the room; the boundary closes
/// with that step, never before she is there. (A player glides ~7 m/s and
/// she walks; leaving at the card itself could not get her there first.)
/// While she is
/// there the boundary she stands in is closed to the player exactly like a
/// wall (TapNavigationController.characterBlockedEdges -- grid steps, tap
/// walks and the free walk all honour it), whatever the doors are doing:
/// the doors themselves open and close as always. Walking up to her, bumping
/// into her or tapping her gets a gesture back toward the office --
/// impatient, impatient, exasperated once, then only a silent, stern point.
///
/// She stays there whatever the visitor does -- reception, the desk, the
/// kiosk, Tinky's anteroom or office, for as long as they like. Oct 9 (no
/// loophole): going into Tinky's office does NOT release her; only the
/// story does. She leaves the doorway the moment Tinky's escort begins
/// (FredOfficeEncounter.beginFollowMe -> GuidedJourney.begin, which makes
/// GuidedJourney.trip non-nil, then calls `release`), or once the prologue
/// is complete -- and the exit is open again the instant she leaves it, so
/// she never stands in his way or leaves an invisible wall behind.
///
/// In memory only: every Floor 2 build starts her at the counter (or, while
/// the rule is in force and the visitor is inside, straight in the doorway).
enum AdministrationExitGuard {
    /// The exit: the Double Glass doors between the vestibule and reception.
    static let exitDoor = AdministrationReception.vestibule              // (10,7)
    /// The room cell just inside those doors.
    static let insideCell = GridCoordinate(row: 10, col: 8)
    /// The boundary she stands in: insideCell's west side (the doorway).
    static let exitEdge = TapNavigationController.BlockedEdge(cell: insideCell, direction: .west)
    /// Reception's public side -- where she keeps the exit.
    static let receptionCells: Set<GridCoordinate> = {
        var cells: Set<GridCoordinate> = []
        for row in 9...11 { for col in 8...10 { cells.insert(GridCoordinate(row: row, col: col)) } }
        return cells.subtracting(AdministrationReception.staffCells)
    }()
    /// Tinky's anteroom and office. (Oct 9: being here does NOT release her.)
    static let retreatCells: Set<GridCoordinate> = AdministrationReception.officeCells
        .union([AdministrationReception.officeAnteroom])

    /// Oct 9 (Juanita 2.0): `standingBy` = beside the doorway, NOT in it
    /// (the exit is open) -- where she waits from the moment the visitor
    /// accepts their ID photo until the card is taken.
    enum Post: String { case atDesk, goingOut, standingBy, blocking, goingBack }
    private(set) static var post: Post = .atDesk
    /// Gestures she has made at the visitor since the ID (this build).
    private(set) static var attempts = 0
    /// Is the exit closed to the player right now (mirrors what was pushed
    /// to the navigation through `setExitBlocked`)?
    private(set) static var isExitBlocked = false
    /// Floor 2's navigation: close/open the exit boundary (ContentView).
    static var setExitBlocked: ((Bool) -> Void)?

    /// Oct 9 (conversational distance): the circle round her the player's
    /// eyes never enter (centre x/z, radius m), or nil. Floor 2's navigation
    /// (ContentView) turns it into a FreeWalkGeometry keep-out.
    static var setKeepOut: (((center: SIMD2<Float>, radius: Float)?) -> Void)?
    private(set) static var keepOut: (center: SIMD2<Float>, radius: Float)?
    /// On guard: the player stops this far from her -- her face, both arms
    /// and the doors behind her stay in view; never inside her.
    static let conversationDistance: Float = 1.9
    /// Standing by (exit still open): just enough that nobody walks through her.
    static let personalSpace: Float = 0.9

    /// Away from the counter (walking, or standing in the exit): the desk
    /// is unattended.
    static var isAway: Bool { post != .atDesk }

    private static weak var standIn: SCNNode?
    private static var cellSize: Float = 3.52
    private static var deskPosition = SCNVector3Zero
    private static var deskYaw: Float = 0
    private static var lastGestureAt: CFTimeInterval = -.infinity
    private static var playerCell: GridCoordinate?
    static let walkKey = "exitGuardWalk"
    static let walkSpeed: Float = 2.4                                     // m/s: brisk, not running
    /// Walking up to her again within this long doesn't earn another gesture.
    static let gestureCooldown: CFTimeInterval = 4.0

    /// Is the rule in force? After the ID, before Tinky takes over.
    static func isEnforcing(admitted: Bool = Admission.isCompleted,
                            prologueDone: Bool = Admission.isPrologueCompleted,
                            journeyUnderway: Bool = GuidedJourney.trip.map { $0.stage != .awaitingFollow } ?? false) -> Bool {
        // (Oct 24: while Tinky waits to be followed, she still keeps the exit -- the player
        // may look round Administration, but leaves it with him.)
        admitted && !prologueDone && !journeyUnderway
    }

    /// Floor 2 build: she starts at her post, the exit open. ContentView
    /// then wires `setExitBlocked` and calls `sync(playerCell:)`.
    static func install(standIn node: SCNNode, cellSize s: Float) {
        standIn = node
        cellSize = s
        deskPosition = node.position
        deskYaw = node.eulerAngles.y
        post = .atDesk
        attempts = 0
        isExitBlocked = false
        keepOut = nil
        lastGestureAt = -.infinity
        playerCell = nil
        AdministrationReception.setStanding(false, on: node, duration: 0)   // a fresh build: at the counter
    }

    // MARK: Where she stands, and how she gets there (world x/z)

    /// Standing in the exit: centred on the doorway, 0.95 m inside it --
    /// clear of the leaves' swing (they open into the room, 0.95 m each),
    /// and closer to the doors than the player can ever get to that
    /// boundary (FreeWalkGeometry.playerClearance).
    static func blockingSpot(cellSize s: Float) -> SIMD2<Float> {
        SIMD2<Float>((Float(insideCell.col) - 0.5) * s + 0.95, Float(insideCell.row) * s)
    }

    /// Desk, round the counter's north end, across the public side, then
    /// down the north side of the entry cell into the doorway -- never
    /// through the counter.
    static func route(cellSize s: Float, desk: SIMD2<Float>) -> [SIMD2<Float>] {
        let counterNorthEnd = Float(AdministrationReception.counterRow) * s - 1.7 - 0.6   // counter is 3.4 m long
        let spot = blockingSpot(cellSize: s)
        return [
            desk,
            SIMD2<Float>(desk.x, counterNorthEnd),                                        // out from behind the counter
            SIMD2<Float>(Float(AdministrationReception.publicCol) * s - 0.4, counterNorthEnd),
            standbySpot(cellSize: s),                                                     // beside the doorway
            spot,                                                                         // in the doorway
        ]
    }

    /// Oct 9 (Juanita 2.0): standing by -- 1.2 m north of the doorway's
    /// centre, beside it rather than in it: the boundary stays open (a
    /// visitor without an ID may still leave), and stepping across into
    /// the doorway is a single 1.2 m step (half a second).
    static func standbySpot(cellSize s: Float) -> SIMD2<Float> {
        let spot = blockingSpot(cellSize: s)
        return SIMD2<Float>(spot.x, spot.y - 1.2)
    }

    // MARK: Hooks

    /// Right after Floor 2's navigation is wired: if the rule is in force
    /// and the visitor is inside, she is already in the doorway.
    static func sync(playerCell: GridCoordinate) {
        self.playerCell = playerCell
        guard let node = standIn, node.parent != nil else { applyBlock(false); return }
        guard isEnforcing(), receptionCells.union(retreatCells).contains(playerCell) else { applyBlock(false); return }
        let spot = blockingSpot(cellSize: cellSize)
        node.removeAction(forKey: walkKey)
        node.position = SCNVector3(spot.x, node.position.y, spot.y)
        node.eulerAngles.y = Float(Direction.west.yaw)                     // facing into the room
        AdministrationReception.setStanding(true, on: node, duration: 0)    // arms at her sides
        post = .blocking
        applyBlock(true)
        diag("juanita.exit.stationed", ["cell": "\(playerCell.row),\(playerCell.col)"])
    }

    /// Oct 9 (Juanita 2.0): the visitor tapped ACCEPT on their ID photo
    /// (AdministrationIDTerminal). The card is ~2.5 s away; she comes out
    /// from behind the counter now and waits BESIDE the doorway. Nothing is
    /// blocked yet -- without the card the visitor is still free to leave.
    static func photoAccepted(admitted: Bool = Admission.isCompleted,
                              prologueDone: Bool = Admission.isPrologueCompleted) {
        guard standIn?.parent != nil, !admitted, !prologueDone else { return }
        if post == .atDesk || post == .goingBack { goOut() }
    }

    /// The ID was just taken (AdministrationIDTerminal): she steps into the
    /// doorway -- from beside it if she is already there, else as soon as
    /// she gets there.
    static func visitorAdmitted(enforcing: Bool = isEnforcing()) {
        guard standIn?.parent != nil, enforcing else { return }
        switch post {
        case .standingBy: stepIn()
        case .atDesk, .goingBack: goOut()
        case .goingOut, .blocking: break          // on her way (she steps in on arrival) / already there
        }
    }

    /// The visitor moved (ContentView's onCellChanged on Floor 2).
    static func playerCellChanged(_ cell: GridCoordinate, enforcing: Bool = isEnforcing(),
                                  admitted: Bool = Admission.isCompleted) {
        guard standIn?.parent != nil else { return }
        playerCell = cell
        if !enforcing {
            if !admitted {
                // Before the ID: standing by is only a courtesy. If the
                // visitor leaves Administration without their card, so does
                // she -- back to the counter.
                let inside = receptionCells.contains(cell) || retreatCells.contains(cell)
                if !inside, post == .standingBy || post == .goingOut { goBack(reason: "left without the ID") }
                return
            }
            if post != .atDesk { goBack(reason: "released") }
            return
        }
        // Oct 9 (no loophole): wherever the visitor is inside Administration
        // -- reception or Tinky's office -- she keeps (or takes) the exit.
        // Only the story (isEnforcing false / `release`) sends her back.
        guard receptionCells.contains(cell) || retreatCells.contains(cell) else { return }
        if post == .atDesk || post == .goingBack {
            goOut()                                          // beside the doorway, then into it
        } else if post == .standingBy {
            stepIn()
        } else if cell == insideCell, post == .blocking {
            gesture(reason: "approached")
        }
    }

    /// Oct 9: does she guard this door right now? THE answer for the doors
    /// (TapNavigationController.roomEntranceDoorGuarded): the exit doors,
    /// from the moment she steps into the doorway until she leaves it --
    /// the same state that closes the doorway. Beside the doors, or after
    /// Tinky's escort begins: no.
    static func guardsDoor(_ coord: GridCoordinate) -> Bool {
        coord == exitDoor && isExitBlocked
    }

    /// Oct 9: the visitor tried the doors she guards -- an attempt to
    /// leave: her next reaction in the sequence (cooldown as always).
    static func doorTried() {
        guard post == .blocking else { return }
        gesture(reason: "doorTapped")
    }

    /// The visitor walked into her (a grid step refused at the exit).
    static func bumped() {
        guard post == .blocking else { return }
        gesture(reason: "bumped")
    }

    /// The visitor tapped her while she was away from the counter.
    static func tapped() {
        if post == .blocking {
            gesture(reason: "tapped", ignoreCooldown: true)
        } else {
            diag("juanita.exit.tapIgnored", ["post": post.rawValue])
        }
    }

    /// Tinky has the visitor now: she steps aside, back to the counter.
    static func release(reason: String) {
        guard post != .atDesk else { applyBlock(false); return }
        goBack(reason: reason)
    }

    // MARK: Behaviour

    /// Impatient, impatient, then exasperated once, then only a silent, stern
    /// point -- restrained, never a flood.
    static func refusal(forAttempt n: Int) -> (mood: AdministrationReception.Mood, silent: Bool) {
        switch n {
        case ...2: return (.impatient, false)
        case 3: return (.exasperated, false)
        default: return (.impatient, true)
        }
    }

    private static func gesture(reason: String, ignoreCooldown: Bool = false) {
        guard let node = standIn, post == .blocking else { return }
        let now = CACurrentMediaTime()
        guard ignoreCooldown || now - lastGestureAt >= gestureCooldown else { return }
        let r = refusal(forAttempt: attempts + 1)
        guard AdministrationReception.performExitRefusal(r.mood, silent: r.silent, on: node) else { return }
        attempts += 1
        lastGestureAt = now
        diag("juanita.exit.insists", ["attempt": attempts, "mood": "\(r.mood)", "silent": r.silent, "reason": reason])
    }

    private static func applyBlock(_ blocked: Bool) {
        guard blocked != isExitBlocked else { return }
        isExitBlocked = blocked
        setExitBlocked?(blocked)
        applyKeepOut(blocked ? (blockingSpot(cellSize: cellSize), conversationDistance) : nil)
        diag("juanita.exit.block", ["closed": blocked])
    }

    private static func applyKeepOut(_ k: (center: SIMD2<Float>, radius: Float)?) {
        keepOut = k
        setKeepOut?(k)
    }

    /// Out from behind the counter to BESIDE the doorway. Nothing is
    /// blocked on the way: the doorway closes only when she is in it.
    private static func goOut() {
        guard let node = standIn else { return }
        AdministrationReception.cancelPatienceTimer()
        AdministrationReception.setStanding(true, on: node)                 // off the counter: arms down
        post = .goingOut
        let path = Array(route(cellSize: cellSize, desk: SIMD2<Float>(deskPosition.x, deskPosition.z)).dropLast())
        walk(node, along: Array(path[nearestIndex(of: node, in: path)...]),
             finalYaw: Float(Direction.west.yaw)) {                         // facing into the room (east)
            guard post == .goingOut else { return }
            post = .standingBy
            applyKeepOut((standbySpot(cellSize: cellSize), personalSpace))
            diag("juanita.exit.standingBy", ["admitted": Admission.isCompleted])
            if isEnforcing() { stepIn() }                                   // the card was taken on her way
        }
        diag("juanita.exit.goingOut", ["attempts": attempts])
    }

    /// From beside the doorway into it: the boundary is hers from this step
    /// (she is at the doorway's edge, body across the opening within half a
    /// second) -- never before she is physically there.
    private static func stepIn() {
        guard let node = standIn else { return }
        applyBlock(true)
        post = .goingOut
        walk(node, along: [blockingSpot(cellSize: cellSize)], finalYaw: Float(Direction.west.yaw)) {
            guard post == .goingOut else { return }
            post = .blocking
            diag("juanita.exit.blocking", ["attempts": attempts])
            if playerCell == insideCell { gesture(reason: "arrived") }     // they're right there
        }
        diag("juanita.exit.steppingIn", [:])
    }

    private static func goBack(reason: String) {
        applyBlock(false)                                                    // the exit is free the moment she leaves it
        applyKeepOut(nil)
        guard let node = standIn else { post = .atDesk; return }
        post = .goingBack
        let path = route(cellSize: cellSize, desk: SIMD2<Float>(deskPosition.x, deskPosition.z))
        let back = Array(path[...nearestIndex(of: node, in: path)].reversed())
        walk(node, along: back, finalYaw: deskYaw) {
            guard post == .goingBack else { return }
            node.position = deskPosition
            AdministrationReception.setStanding(false, on: node)            // forearms back on the counter
            post = .atDesk
            diag("juanita.exit.backAtDesk", ["reason": reason])
        }
        diag("juanita.exit.goingBack", ["reason": reason])
    }

    private static func nearestIndex(of node: SCNNode, in path: [SIMD2<Float>]) -> Int {
        let p = node.presentation.position
        let here = SIMD2<Float>(p.x, p.z)
        return path.indices.min { simd_distance(path[$0], here) < simd_distance(path[$1], here) } ?? 0
    }

    /// A brisk walk: turn toward each leg, glide along it, then turn
    /// to `finalYaw`. Interrupting (a new walk) just starts from where she is.
    private static func walk(_ node: SCNNode, along points: [SIMD2<Float>], finalYaw: Float, done: @escaping () -> Void) {
        node.removeAction(forKey: walkKey)
        var from = SIMD2<Float>(node.presentation.position.x, node.presentation.position.z)
        node.position = node.presentation.position
        node.eulerAngles = node.presentation.eulerAngles
        var steps: [SCNAction] = []
        for to in points {
            let d = to - from
            let length = simd_length(d)
            guard length > 0.05 else { continue }
            let yaw = atan2(d.x, d.y)                                       // local +Z along the leg
            let turn = SCNAction.rotateTo(x: 0, y: CGFloat(yaw), z: 0, duration: 0.18, usesShortestUnitArc: true)
            let duration = TimeInterval(length / walkSpeed)
            let move = SCNAction.move(to: SCNVector3(to.x, node.position.y, to.y), duration: duration)
            move.timingMode = .easeInEaseOut
            steps.append(turn)
            steps.append(move)
            from = to
        }
        steps.append(.rotateTo(x: 0, y: CGFloat(finalYaw), z: 0, duration: 0.3, usesShortestUnitArc: true))
        walkGeneration += 1
        let generation = walkGeneration
        pendingArrival = done
        node.runAction(.sequence(steps), forKey: walkKey) {
            DispatchQueue.main.async { arrive(generation) }
        }
    }

    private static var walkGeneration = 0
    private static var pendingArrival: (() -> Void)?

    private static func arrive(_ generation: Int) {
        guard generation == walkGeneration, let done = pendingArrival else { return }
        pendingArrival = nil
        done()
    }

    /// Tests only (no renderer runs SCNActions there): finish the walk in
    /// progress now, exactly as its completion would.
    static func finishWalkForTesting() {
        standIn?.removeAction(forKey: walkKey)
        arrive(walkGeneration)
    }
}
