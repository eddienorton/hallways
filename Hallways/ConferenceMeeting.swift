import SceneKit
import UIKit
import simd

/// Oct 11 -- EPISODE 3, SCENE 2: THE STAFF MEETING (Floor 3 Conference Room).
///
/// DIRECTOR'S PASS (Oct 11, evening): a directed scene, not a crowd of
/// independent animation systems. The characters are scripted; the player
/// is not. One timeline (`MeetingScript`) drives every beat; the room's
/// `MeetingMood` carries the current beat to each attendee's tick, so a
/// stage change silences incidental chatter and wandering everywhere at
/// once while the scripted gestures, the boss and the projector go on.
///
///   BEFORE      a lively room: murmurs one at a time (a shared
///               conversation turn -- never a din), glances, the odd laugh.
///   SIT         the player's place is the west side, middle chair -- by
///               the doors, facing the boss and the screen. Chatter goes on
///               for a couple of seconds more.
///   ORDER       the boss (the stepladder in the red tie) rocks back and
///               BANGS the table twice. Everyone stops and turns to him.
///               One excitable stapler gets a last chirp out; the boss
///               turns and looks at it; it shrinks. Then real silence.
///   SPEECH      a few words of Hallenese. Nobody else makes a sound: a nod
///               here and there, one exchanged glance.
///   PROJECTOR   he turns and gestures at the screen; the lights come down;
///               he starts the projector; THE HALLWAYS COMPANY. He steps
///               aside, everyone watches the screen, and the room waits --
///               quietly. Chatter never comes back.
///
/// The scene's timeline is separate from the player's camera: sitting
/// starts it (for now), but standing up, walking about or leaving the room
/// never stops it (only leaving the floor does). Seated, a drag turns the
/// head (within limits); STAND, or a tap, gets up.
///
/// STATE (StoryBeats): `satBeat`, `projectorBeat`. Assembled whenever the
/// staff-meeting story is under way (MeetingProcession.isDue / isDone).
/// Projector on -> later builds have it on, lights dimmed, the boss aside,
/// everyone waiting; the scene doesn't replay. Interrupted before the
/// projector came on -> it plays again the next time the player sits. A
/// save made while seated restores the player standing beside the table.
/// DEBUG: Settings > Replay Conference Meeting (`debugReplay`) resets just
/// this room for another take -- nothing saved is touched.
///
/// HALLENESE ONLY: synthesised voices, looks, hops and leans.
enum ConferenceMeeting {
    static let satBeat = "meeting.staff1.playerSat"
    static let projectorBeat = "meeting.staff1.projectorOn"

    /// The meeting is set up once the staff-meeting story is under way.
    static var isAssembled: Bool { MeetingProcession.isDue || MeetingProcession.isDone }
    static var projectorIsOn: Bool { StoryBeats.shared.has(projectorBeat) }

    /// Shared with every attendee's tick (thread-safe).
    static let mood = MeetingMood()
    private(set) static var layout: MeetingLayout?
    static weak var controller: TapNavigationController?

    enum Phase: String { case standing, sittingDown, seated, standingUp }
    private(set) static var phase: Phase = .standing
    static var isActive: Bool { phase != .standing }

    /// Where USE at the empty chair is offered: the player's side of the room.
    static let sitCells: Set<GridCoordinate> = [GridCoordinate(row: 5, col: 9), ConferenceRoom.entryCell, GridCoordinate(row: 7, col: 9)]
    /// Seated eye height above the floor's top surface, and a slight look up.
    static let seatedEye: Float = 1.17
    static let seatedPitchMeeting: Double = 0.07
    /// The audition: level, a touch down (faces at the table, not the ceiling).
    static var seatedPitch: Double { ConferenceAudition.enabled ? -0.03 : seatedPitchMeeting }
    /// The audition's seated lens: a little longer than walking's 75 degrees,
    /// so faces at the table read on a portrait phone (pinch for closer still).
    static let seatedFOV: CGFloat = 55
    private static var walkingFOV: CGFloat?
    /// Seated, how far the head turns either way from straight at the boss.
    static let lookLimit: Double = 1.2

    private static var installed = false
    private static var generation = 0          // this floor build (glide completions check it)
    private static var sceneGeneration = 0     // the scene's timeline (a replay cancels it alone)
    private static var introRunning = false
    private static var replayArmed = false
    private static var lightsDimmed = false
    private static var dimmedLights: [(SCNLight, CGFloat)] = []
    private static var dimmedMaterials: [(SCNMaterial, CGFloat)] = []
    private static var lookBaseYaw: Double = 0
    private static var lookBasePitch: Double = 0                 // Oct 12: (the show may have tilted the view up)
    private(set) static weak var room: SCNNode?
    private static weak var playerChair: SCNNode?
    private static weak var projector: SCNNode?
    private static weak var beam: SCNNode?
    private(set) static weak var projection: SCNNode?            // (Oct 12: THE BIG REVEAL puts its show on it)
    private static var lens: SCNMaterial?
    private static var led: SCNMaterial?

    // MARK: Floor lifecycle (MeetingProcession / ContentView)

    static func attach(controller: TapNavigationController) {
        if self.controller !== controller { forceStand(reason: "newController") }
        self.controller = controller
    }

    /// Floor 3 just built (from MeetingProcession.installFloor, which owns the
    /// habitat). Dresses the room and seats the meeting's own attendees.
    static func installFloor(scene: SCNScene, habitat: Habitat, cellSize: Float, playerCell: GridCoordinate?) {
        generation += 1
        sceneGeneration += 1
        installed = false
        introRunning = false
        lightsDimmed = false
        dimmedLights = []
        dimmedMaterials = []
        phase = .standing
        controller?.isSeatedInMeeting = false
        seatedThisVisit = false
        guard isAssembled || ConferenceAudition.enabled else { layout = nil; return }
        guard let room = scene.rootNode.childNode(withName: "conferenceRoom", recursively: false) else {
            layout = nil
            diag("meeting.noRoom", [:])
            return
        }
        let layout = MeetingLayout(cellSize: cellSize)
        self.layout = layout
        self.room = room
        MeetingVoices.prepare()
        MeetingErrand.prepareSounds()
        let on = projectorIsOn && !replayArmed && !ConferenceAudition.enabled
        mood.reset(to: on ? .waiting : .gathering)
        mood.setPlayer(inRoom: playerCell.map { ConferenceRoom.roomCells.contains($0) } ?? false)
        lastCell = playerCell

        dressRoom(room, layout: layout)
        // Oct 11 (late): the cast audition takes the room instead of the
        // meeting's attendees, boss and scene (which stay intact, unused).
        if ConferenceAudition.enabled {
            // Oct 12 (event history): who is in the room is the player's story
            // so far (TheBoxMeeting) -- empty before the invitation and after
            // THE BOX; waiting to arrive one by one in between.
            switch TheBoxMeeting.presenceForBuild(playerCell: playerCell) {
            case .none:
                ConferenceAudition.uninstall()
            case .waiting:
                ConferenceAudition.install(into: room, layout: layout, camera: controller?.cameraNode)
                ConferenceAudition.setAllAbsent()
            case .seated:
                ConferenceAudition.install(into: room, layout: layout, camera: controller?.cameraNode)
            }
            BoxReveal.installFloor(room: room, layout: layout)               // Oct 12: THE BIG REVEAL (BoxReveal.swift)
            installed = true
            diag("meeting.installed", ["mode": "audition", "playerCell": playerCell.map { "\($0)" } ?? "none"])
            return
        }
        // The colleagues already there (east side) and the boss (head).
        // (Oct 19, Stage A: the small Clacker at place 5 is retired; that place stays empty.)
        spawn(.frog, chair: 1, seed: 1, layout: layout, habitat: habitat, scene: scene)
        spawn(.pottle, chair: 3, seed: 3, layout: layout, habitat: habitat, scene: scene)
        spawnBoss(aside: on, layout: layout, habitat: habitat, scene: scene)
        if on {
            setProjector(on: true, animated: false)
            dimLights(animated: false)
        }
        installed = true
        diag("meeting.installed", ["projectorOn": on, "sat": StoryBeats.shared.has(satBeat), "replayArmed": replayArmed,
                                   "procession": MeetingProcession.isDone, "playerCell": playerCell.map { "\($0)" } ?? "none"])
    }

    static func leaveFloor() {
        BoxReveal.stop(reason: "leftFloor")                                   // Oct 12
        TheBoxMeeting.floorLeft()                                             // Oct 12
        generation += 1
        sceneGeneration += 1
        installed = false
        introRunning = false
        layout = nil
        forceStand(reason: "leftFloor")
    }

    /// The scene/controller is being replaced (or Start Over): no camera move.
    static func forceStand(reason: String) {
        guard phase != .standing || controller?.isSeatedInMeeting == true else { return }
        CameraMagnifier.shared.reset(animated: false)
        if let camera = controller?.cameraNode { restoreLens(camera, duration: 0) }
        controller?.cameraNode.removeAction(forKey: "meetingSit")
        controller?.cameraNode.removeAction(forKey: "meetingStand")
        controller?.isSeatedInMeeting = false
        phase = .standing
        mood.setPlayer(seated: false)
        diag("meeting.forceStand", ["reason": reason])
    }

    static func playerCellChanged(_ cell: GridCoordinate) {
        mood.setPlayer(inRoom: ConferenceRoom.roomCells.contains(cell))
        if !ConferenceRoom.roomCells.contains(cell) { BoxReveal.stop(reason: "leftRoom") }   // Oct 12: ends gracefully
        // Oct 12 (playtest): the meeting over and the player gone out -- the attendees go too.
        if !ConferenceRoom.roomCells.contains(cell) { BoxReveal.playerLeftRoom() }
        defer { lastCell = cell }
        if !ConferenceRoom.roomCells.contains(cell) { seatedThisVisit = false }
        // Oct 11 (late, the audition): walking in through the glass doors
        // takes the player straight to their chair -- no hunting for it.
        if ConferenceAudition.enabled, installed, ConferenceAudition.isInstalled, phase == .standing,
           lastCell == ConferenceRoom.doorCell, ConferenceRoom.roomCells.contains(cell) {
            requestAutoSit(reason: "enteredRoom")                       // (Oct 12: only with a meeting here)
        }
        if ConferenceAudition.enabled, installed { TheBoxMeeting.playerCellChanged(cell) }   // Oct 12: the cast arrive
    }

    // MARK: Smart WALK to the chair (the audition)

    private static var lastCell: GridCoordinate?
    /// Sat down at least once since coming into the room: after getting up,
    /// WALK walks again (out of the room, say).
    private static var seatedThisVisit = false
    private static var autoSitGeneration = 0

    /// WALK pressed in the room before the player has sat down this visit
    /// (e.g. a resume inside the room): it takes them to their chair.
    /// True = handled; the walk doesn't start.
    static func interceptWalk(controller: TapNavigationController) -> Bool {
        guard ConferenceAudition.enabled, installed, ConferenceAudition.isInstalled, phase == .standing, !seatedThisVisit,
              controller.currentFloorNumber == ConferenceRoom.floor, sitCells.contains(controller.currentCell) else { return false }
        self.controller = controller
        requestAutoSit(reason: "walk")
        return true
    }

    // MARK: Oct 12 -- THE BOX meeting (TheBoxMeeting)

    /// The cast come in through the glass doors.
    static func openGlassDoorsForArrivals() {
        controller?.openRoomEntranceDoorForCharacter(at: ConferenceRoom.doorCell)
    }

    /// ...and the doors close behind the last of them (never on the player in the doorway).
    static func closeGlassDoorsAfterArrivals() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard let c = controller, c.currentFloorNumber == ConferenceRoom.floor,
                  c.currentCell != ConferenceRoom.doorCell, c.currentCell != ConferenceRoom.entryCell else { return }
            c.closeRoomEntranceDoorForCharacter(at: ConferenceRoom.doorCell)
        }
    }

    /// REPLAY in an empty room (THE BOX's meeting is over): the cast, in their places, for the show.
    /// Invited while Floor 3 was already built: the cast, in place but unseen, ready to arrive.
    static func installCastWaiting() {
        guard installed, let room, let layout, ConferenceAudition.enabled, !ConferenceAudition.isInstalled else { return }
        ConferenceAudition.install(into: room, layout: layout, camera: controller?.cameraNode)
        ConferenceAudition.setAllAbsent()
        diag("theBoxMeeting.castWaiting", [:])
    }

    static func installCastForReplay() {
        guard installed, let room, let layout, ConferenceAudition.enabled else { return }
        // A replay of a meeting that was on but not yet gathered: they're all here now
        // (no arrivals to come after it).
        if TheBoxMeeting.state == .available || TheBoxMeeting.state == .gathering {
            _ = StoryBeats.shared.record(TheBoxMeeting.gatheringBeat, at: Date())
            _ = StoryBeats.shared.record(TheBoxMeeting.gatheredBeat, at: Date())
        }
        if ConferenceAudition.isInstalled {
            TheBoxMeeting.cancelArrivals()                       // (still on their way in: simply here)
            ConferenceAudition.allPresent()
        } else {
            ConferenceAudition.install(into: room, layout: layout, camera: controller?.cameraNode)
        }
        diag("theBoxMeeting.castForReplay", [:])
    }

    /// Oct 12: REPLAY pressed while standing in the room -- to the chair (the show starts there).
    static func sitForReplay() {
        guard phase == .standing, installed, let c = controller, ConferenceRoom.roomCells.contains(c.currentCell) else { return }
        requestAutoSit(reason: "replay")
    }

    /// Stops whatever walk is under way and, once the player is standing
    /// still, sits them down (the same glide as USE).
    private static func requestAutoSit(reason: String) {
        guard let controller else { return }
        autoSitGeneration += 1
        let gen = autoSitGeneration
        if controller.continuousWalkState != .stopped { controller.stopContinuousWalk(reason: "meetingSeat") }
        controller.stopWalkLatch(reason: "meetingSeat")                   // Oct 16 (walk latch)
        if controller.isFreeTapWalking { controller.stopFreeTapWalk() }
        diag("meeting.autoSit.requested", ["reason": reason, "cell": controller.currentCell])
        func attempt(_ n: Int) {
            guard gen == autoSitGeneration, phase == .standing, installed, let c = self.controller else { return }
            if c.canRotate, sitCells.contains(c.currentCell) {
                sit(controller: c, source: "smartWalk")
                return
            }
            guard n < 40 else {
                diag("meeting.autoSit.gaveUp", ["cell": c.currentCell, "blockers": c.diagCanRotateBlockers])
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attempt(n + 1) }
        }
        attempt(0)
    }

    // MARK: Developer replay (Settings, DEBUG builds only)

    /// Puts just this room back to before the boss calls the meeting to
    /// order -- projector off, lights up, the boss back at the head, chatter
    /// -- and plays the scene again: at once if the player is seated, else
    /// the next time they sit (on Floor 3 now, or on its next build). Saved
    /// story beats, the player's position, mail, missions: all untouched.
    static func debugReplay() {
        guard BuildMode.developerTools else { return }
        if ConferenceAudition.enabled && BoxReveal.isEnabled { BoxReveal.replay(); return }         // Oct 12: the audition room's show is THE BIG REVEAL
        replayArmed = true
        diag("meeting.debugReplay", ["installed": installed, "phase": phase.rawValue])
        guard installed else { return }
        sceneGeneration += 1                     // cancels a scene in progress
        introRunning = false
        setProjector(on: false, animated: false)
        restoreLights()
        mood.set(.gathering)
        if phase == .seated {
            replayArmed = false
            beginScene()
        } else if phase == .standing {
            inviteChair(animated: true)
        }
    }

    // MARK: Sitting down and standing up

    /// Where getting up ends (and where a save made while seated restores):
    /// in the doorway cell beside the player's chair, facing the screen.
    static var standUpSpot: (position: SIMD2<Float>, yaw: Double)? {
        guard let layout else { return nil }
        let s = layout.cellSize
        let spot = MeetingLayout.playerChair == 7 ? SIMD2<Float>(9 * s + 0.3, 7 * s - 0.1) : SIMD2<Float>(9 * s + 0.3, 6 * s + 0.3)
        let d = layout.screen - spot
        return (spot, Double(atan2(-d.x, -d.y)))
    }

    /// The HUD's USE, standing in the room looking at the empty chair.
    static func sitTarget(controller: TapNavigationController, cell: GridCoordinate, yaw: Double) -> TapNavigationController.HUDTarget? {
        guard installed, phase == .standing, let layout, controller.currentFloorNumber == ConferenceRoom.floor,
              sitCells.contains(cell) else { return nil }
        let p = controller.cameraNode.position
        let d = layout.seat - SIMD2<Float>(p.x, p.z)
        guard simd_length(d) < 4.6 else { return nil }
        let toChair = Double(atan2(-d.x, -d.y))
        guard abs(angle(from: yaw, to: toChair)) < 40 * .pi / 180 else { return nil }
        return TapNavigationController.HUDTarget(label: "USE", kind: "meetingChair") { [weak controller] in
            guard let controller else { return }
            sit(controller: controller, source: "hud")
        }
    }

    /// Seated: the center button gets the player up.
    static func standTarget() -> TapNavigationController.HUDTarget? {
        guard phase == .seated else { return nil }
        return TapNavigationController.HUDTarget(label: "STAND", kind: "meetingStand") { standUp(reason: "hud") }
    }

    /// A tap on the empty chair (its node or any part of it).
    static func isEmptyChair(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let current = n {
            if current.name == "conferenceRoomChair\(MeetingLayout.playerChair)" { return true }
            n = current.parent
        }
        return false
    }

    @discardableResult
    static func sit(controller: TapNavigationController, source: String) -> Bool {
        guard phase == .standing else { return false }
        guard installed, let layout, room?.parent != nil, controller.currentFloorNumber == ConferenceRoom.floor else {
            diag("meeting.sit.declined", ["reason": "no meeting here", "source": source])
            return false
        }
        guard sitCells.contains(controller.currentCell) else {
            diag("meeting.sit.declined", ["reason": "not beside the table", "cell": controller.currentCell, "source": source])
            return false
        }
        guard controller.canRotate else {
            diag("meeting.sit.declined", ["reason": "busy", "blockers": controller.diagCanRotateBlockers, "source": source])
            return false
        }
        self.controller = controller
        controller.isSeatedInMeeting = true
        phase = .sittingDown
        let camera = controller.cameraNode
        let start = camera.presentation.worldPosition
        let seat = seatWorld(layout)
        // Beside the chair first (its south side, clear of its back), then
        // down into it.
        let a = aislePoint(layout)
        let aisle = SCNVector3(a.x, start.y, a.y)
        var world = [start]
        if hypotf(start.x - aisle.x, start.z - aisle.z) > 0.3 { world.append(aisle) }
        world.append(seat)
        let path = world.map { local($0, camera) }
        var actions: [SCNAction] = []
        for i in 1..<path.count {
            let last = i == path.count - 1
            actions.append(glide(from: path[i - 1], to: path[i], yaw: last ? seatYaw(layout) : heading(path[i - 1], path[i]),
                                 pitch: last ? seatedPitch : 0, legs: path.count - 1, index: i))
        }
        actions.append(.wait(duration: 0.1))
        let total = actions.reduce(0) { $0 + $1.duration }
        squareChair(duration: total)
        if ConferenceAudition.enabled, let lens = camera.camera {
            walkingFOV = lens.fieldOfView
            SCNTransaction.begin()
            SCNTransaction.animationDuration = total
            lens.fieldOfView = seatedFOV
            SCNTransaction.commit()
        }
        let gen = generation
        diag("meeting.sit.begin", ["from": controller.currentCell, "legs": path.count - 1, "source": source])
        camera.runAction(.sequence(actions), forKey: "meetingSit") {
            DispatchQueue.main.async { seated(gen) }
        }
        return true
    }

    private static func seated(_ gen: Int) {
        guard gen == generation, phase == .sittingDown else { return }
        phase = .seated
        _ = StoryBeats.shared.record(satBeat, at: Date())
        mood.setPlayer(seated: true)
        diag("meeting.seated", ["projectorOn": projectorIsOn, "introRunning": introRunning, "replayArmed": replayArmed])
        seatedThisVisit = true
        if ConferenceAudition.enabled {
            ConferenceAudition.playerSat()                  // the cast has a look at the newcomer
            BoxReveal.playerSat()                           // Oct 12: ...and the show begins (once)
            return
        }
        if introRunning || (projectorIsOn && !replayArmed) {
            mood.nod()                                  // welcome back: a nod, nothing replays
        } else {
            replayArmed = false
            beginScene()
        }
    }

    static func standUp(reason: String) {
        guard phase == .seated, let controller, let layout, let spot = standUpSpot else { return }
        BoxReveal.returnCameraToSeat()                           // Oct 12: from the show's closer view, back to the chair first
        BoxReveal.playerStood()                                  // Oct 12 (resume-state fix): a start pending from sitting is off
        phase = .standingUp
        CameraMagnifier.shared.reset(animated: false)            // back to the seated 1x view first
        let camera = controller.cameraNode
        restoreLens(camera, duration: 1.2)
        let eye = controller.eyeHeight
        // (Oct 12: the show may just have put the camera back in the chair -- the model value is current)
        let seatAt = BoxReveal.isRunning ? camera.worldPosition : camera.presentation.worldPosition
        let route = [SCNVector3(seatAt.x, eye, seatAt.z),
                     SCNVector3(aislePoint(layout).x, eye, aislePoint(layout).y),
                     SCNVector3(spot.position.x, eye, spot.position.y)].map { local($0, camera) }
        let rise = SCNAction.group([.move(to: route[0], duration: 0.6),
                                    .rotateTo(x: 0, y: CGFloat(camera.eulerAngles.y), z: 0, duration: 0.6, usesShortestUnitArc: true)])
        rise.timingMode = .easeInEaseOut
        let out = glide(from: route[0], to: route[1], yaw: heading(route[0], route[1]), pitch: 0, legs: 2, index: 1, minimum: 0.5)
        let away = glide(from: route[1], to: route[2], yaw: spot.yaw, pitch: 0, legs: 2, index: 2, minimum: 0.8)
        let gen = generation
        diag("meeting.stand.begin", ["reason": reason])
        camera.runAction(.sequence([.wait(duration: 0.1), rise, out, away]), forKey: "meetingStand") {
            DispatchQueue.main.async { finishStanding(gen) }
        }
    }

    private static func finishStanding(_ gen: Int) {
        guard gen == generation, phase == .standingUp, let spot = standUpSpot else { return }
        if let controller {
            controller.cameraNode.removeAction(forKey: "meetingStand")
            controller.finishStandingFromMeeting(at: local(SCNVector3(spot.position.x, 0, spot.position.y), controller.cameraNode),
                                                 yaw: spot.yaw)
        }
        phase = .standing
        mood.setPlayer(seated: false)
        inviteChair(animated: true)
    }

    private static func restoreLens(_ camera: SCNNode, duration: Double) {
        guard let fov = walkingFOV, let lens = camera.camera else { return }
        walkingFOV = nil
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        lens.fieldOfView = fov
        SCNTransaction.commit()
    }

    // MARK: Seated: turning the head (a drag; never a walk), and a closer look

    /// The camera lens (CameraMagnifier) applies while seated here.
    static var magnifierApplies: Bool { phase == .seated }
    private static var panningLens = false

    static func lookBegan() {
        guard phase == .seated, let controller else { return }
        BoxReveal.playerTookCamera()                                         // Oct 12: the show's framing yields
        // Zoomed in (a pinch): one finger pans the magnified view instead.
        panningLens = CameraMagnifier.shared.isZoomed && CameraMagnifier.shared.panBegan(source: "meetingPan")
        if !panningLens {
            lookBaseYaw = Double(controller.cameraNode.eulerAngles.y)
            lookBasePitch = Double(controller.cameraNode.eulerAngles.x)
        }
    }

    static func lookEnded() {
        if panningLens { CameraMagnifier.shared.panEnded(source: "meetingPan") }
        panningLens = false
    }

    /// `translation` in points: x turns the head, the same scale and sense as
    /// the ordinary drag-to-turn (140 pt = a quarter turn; drag right turns left).
    static func lookChanged(translation: CGPoint) {
        if panningLens { CameraMagnifier.shared.panChanged(source: "meetingPan", translation: translation); return }
        let translationX = translation.x
        guard phase == .seated, let controller, let layout else { return }
        let centre = seatYaw(layout)
        let wanted = lookBaseYaw + Double(translationX / 140) * .pi / 2
        let limit = ConferenceAudition.enabled ? 1.6 : lookLimit          // the audition: see everyone round the table
        let yaw = centre + max(-limit, min(limit, angle(from: centre, to: wanted)))
        // Oct 12: from a tilted (presentation) view, the pitch settles back as the head turns.
        let settle = min(1, abs(Double(translationX)) / 140)
        let pitch = lookBasePitch + (seatedPitch - lookBasePitch) * settle
        controller.cameraNode.eulerAngles = SCNVector3(Float(pitch), Float(yaw), 0)
    }

    /// Beside the player's chair, clear of its back and of the next places:
    /// the foot is reached round the table's open (south-west) corner; the
    /// side chair from its south side.
    private static func aislePoint(_ layout: MeetingLayout) -> SIMD2<Float> {
        MeetingLayout.playerChair == 7 ? SIMD2<Float>(layout.seat.x - 1.3, layout.seat.y + 0.15)
                                       : SIMD2<Float>(layout.seat.x - 0.15, layout.seat.y + 0.75)
    }

    /// The window-level pinch (CameraMagnifierGestures) while seated here.
    static func pinchBegan(windowPoint: CGPoint, source: String) {
        guard phase == .seated, let controller, let view = controller.hudSceneView else { return }
        BoxReveal.playerTookCamera()                                         // Oct 12
        CameraMagnifier.shared.onViewChanged = nil
        CameraMagnifier.shared.begin(source: source, at: view.convert(windowPoint, from: nil), camera: controller.cameraNode,
                                     view: view, takeover: true)
    }

    static func pinchMoved(windowPoint: CGPoint, scale: Double, source: String) {
        guard let view = controller?.hudSceneView else { return }
        CameraMagnifier.shared.update(source: source, scale: scale, at: view.convert(windowPoint, from: nil))
    }

    private static func seatWorld(_ layout: MeetingLayout) -> SCNVector3 {
        SCNVector3(layout.seat.x, ConferenceRoom.floorTopY + seatedEye, layout.seat.y)
    }

    /// From the side of the table, turned toward the head: the boss and the
    /// screen both in view (wherever he stands).
    /// Oct 12: the seated view's resting yaw (THE BIG REVEAL returns to it).
    static var seatedViewYaw: Double? { layout.map { seatYaw($0) } }

    private static func seatYaw(_ layout: MeetingLayout) -> Double {
        if MeetingLayout.playerChair == 7 {                         // the foot: straight up the table
            let d = SIMD2<Float>(layout.table.x, layout.head.y) - layout.seat
            return Double(atan2(-d.x, -d.y))
        }
        let d = SIMD2<Float>(layout.table.x + 0.15, layout.screen.y + 0.6) - layout.seat
        return Double(atan2(-d.x, -d.y))
    }

    private static func local(_ world: SCNVector3, _ camera: SCNNode) -> SCNVector3 {
        camera.parent?.convertPosition(world, from: nil) ?? world
    }

    private static func heading(_ a: SCNVector3, _ b: SCNVector3) -> Double {
        Double(atan2(-(b.x - a.x), -(b.z - a.z)))
    }

    private static func angle(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }

    private static func glide(from a: SCNVector3, to b: SCNVector3, yaw: Double, pitch: Double, legs: Int, index: Int,
                              minimum: Double = 0.45) -> SCNAction {
        let d = Double(sqrtf((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) + (b.z - a.z) * (b.z - a.z)))
        let t = max(minimum, d / 1.7)
        let step = SCNAction.group([.move(to: b, duration: t),
                                    .rotateTo(x: CGFloat(pitch), y: CGFloat(yaw), z: 0, duration: t, usesShortestUnitArc: true)])
        step.timingMode = legs == 1 ? .easeInEaseOut : (index == 1 ? .easeIn : (index == legs ? .easeOut : .linear))
        return step
    }

    // MARK: The scene (one timeline; the attendees and the boss follow it)

    private static func beginScene() {
        introRunning = true
        sceneGeneration += 1
        let gen = sceneGeneration
        let S = MeetingScript.self
        diag("meeting.scene.begin", [:])
        var t = S.chatterAfterSitting                                // the chatter goes on a moment...
        after(t, gen) { mood.set(.order) }                           // ...BANG, BANG: order
        for bang in S.bangs { after(t + bang, gen) { shakeTable() } }
        t += S.orderLength                                           // the chirp, the look, the silence
        after(t, gen) { mood.set(.speech) }                          // a few words
        t += S.speechLength + 0.5
        after(t, gen) { mood.set(.projector) }                       // he gestures at the screen...
        after(t + S.dimAt, gen) { dimLights(animated: true) }        // ...the lights come down...
        after(t + S.projectorAt, gen) {                              // ...he starts the projector
            setProjector(on: true, animated: true)
            if StoryBeats.shared.record(projectorBeat, at: Date()) { diag("meeting.projector.on", [:]) }
        }
        after(t + S.projectorStageLength, gen) {                     // and the room waits, quietly
            mood.set(.waiting)
            introRunning = false
            diag("meeting.scene.waiting", [:])
        }
    }

    private static func after(_ seconds: Double, _ gen: Int, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard gen == sceneGeneration else { return }
            work()
        }
    }

    /// The table jumps a little under the boss's bang.
    private static func shakeTable() {
        guard let table = room?.childNode(withName: "conferenceRoomTable", recursively: false) else { return }
        let up = SCNAction.moveBy(x: 0, y: 0.012, z: 0, duration: 0.035)
        let down = SCNAction.moveBy(x: 0, y: -0.012, z: 0, duration: 0.07)
        down.timingMode = .easeIn
        table.runAction(.sequence([up, down]), forKey: "meetingBang")
    }

    // MARK: Lights and projector

    /// Modestly: the room's own ceiling fixtures to ~60% (restorable).
    static func dimLights(animated: Bool, level: CGFloat = 0.6, duration: Double = 1.8) {
        guard !lightsDimmed, let layout, let root = room?.parent else { return }
        lightsDimmed = true
        let s = layout.cellSize
        let xs = (8.5 * s)...(10.5 * s), zs = (4.5 * s)...(7.5 * s)
        let fixtures = root.childNodes.filter { $0.name == "authored_fluorescent" && xs.contains($0.position.x) && zs.contains($0.position.z) }
        var lights: [(SCNLight, CGFloat)] = []
        var materials: [(SCNMaterial, CGFloat)] = []
        for fixture in fixtures {
            fixture.enumerateHierarchy { n, _ in
                if let light = n.light { lights.append((light, light.intensity)) }
                for m in n.geometry?.materials ?? [] { materials.append((m, m.emission.intensity)) }
            }
        }
        dimmedLights = lights
        dimmedMaterials = materials
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? duration : 0
        for (light, intensity) in lights { light.intensity = intensity * level }
        for (material, _) in materials { material.emission.intensity = 0.5 * level / 0.6 }
        SCNTransaction.commit()
        diag("meeting.lightsDimmed", ["fixtures": fixtures.count, "animated": animated])
    }

    static func restoreLights(duration: Double = 0.6) {
        guard lightsDimmed else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        for (light, intensity) in dimmedLights { light.intensity = intensity }
        for (material, intensity) in dimmedMaterials { material.emission.intensity = intensity }
        SCNTransaction.commit()
        dimmedLights = []
        dimmedMaterials = []
        lightsDimmed = false
    }

    static func setProjector(on: Bool, animated: Bool) {
        guard let beam, let projection else { return }
        let green = UIColor(red: 0.2, green: 1, blue: 0.35, alpha: 1)
        let standby = UIColor(red: 0.9, green: 0.25, blue: 0.1, alpha: 1)
        guard on else {
            beam.removeAllActions()
            projection.removeAllActions()
            beam.opacity = 0
            projection.opacity = 0
            lens?.emission.intensity = 0
            led?.diffuse.contents = standby
            return
        }
        led?.diffuse.contents = green
        // Oct 12: for testing the washout -- `-HallwaysNoProjectorBeam YES` keeps the beam off.
        let beamOn: CGFloat = UserDefaults.standard.bool(forKey: "HallwaysNoProjectorBeam") ? 0 : 1
        guard animated else {
            lens?.emission.intensity = 1
            beam.opacity = beamOn
            projection.opacity = 1
            return
        }
        if let projector, let click = MeetingVoices.click { CritterAudio.play(click, on: projector) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if let projector, let whirr = MeetingVoices.whirr { CritterAudio.play(whirr, on: projector) }
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        lens?.emission.intensity = 1
        SCNTransaction.commit()
        beam.runAction(.sequence([.wait(duration: 0.1), .fadeOpacity(to: 0.7 * beamOn, duration: 0.06), .fadeOpacity(to: 0.1 * beamOn, duration: 0.07),
                                  .fadeOpacity(to: 0.85 * beamOn, duration: 0.05), .wait(duration: 0.12), .fadeOpacity(to: beamOn, duration: 0.4)]))
        projection.runAction(.sequence([.wait(duration: 0.15), .fadeOpacity(to: 0.6, duration: 0.06), .fadeOpacity(to: 0.05, duration: 0.08),
                                        .fadeOpacity(to: 0.9, duration: 0.06), .wait(duration: 0.1), .fadeOpacity(to: 1, duration: 0.6)]))
    }

    // MARK: Dressing the room

    private static func dressRoom(_ room: SCNNode, layout: MeetingLayout) {
        let s = layout.cellSize
        let northZ = 4.5 * s
        // The whiteboard moves west along the wall; the screen takes the
        // middle of the wall over the head of the table.
        if let board = room.childNode(withName: "conferenceRoomBoard", recursively: false) {
            board.position.x = 8.5 * s + 1.3
        }
        // Places taken by a critter standing on the floor (and the boss's)
        // have no chair.
        for i in MeetingLayout.chairlessPlaces {
            room.childNode(withName: "conferenceRoomChair\(i)", recursively: false)?.isHidden = true
        }
        playerChair = room.childNode(withName: "conferenceRoomChair\(MeetingLayout.playerChair)", recursively: false)
        inviteChair(animated: false)

        let screenWidth: Float = 2.4, screenHeight: Float = 1.35, screenCentreY: Float = 1.85
        let (screen, projection) = makeScreen(width: screenWidth, height: screenHeight, centreY: screenCentreY)
        screen.position = SCNVector3(layout.table.x, 0, northZ)
        room.addChildNode(screen)
        self.projection = projection

        let (unit, lens, led, lensPoint) = makeProjector()
        unit.position = SCNVector3(layout.projector.x, 0, layout.projector.y)
        room.addChildNode(unit)
        projector = unit
        self.lens = lens
        self.led = led

        // The beam: from the lens to the four corners of the picture.
        let apex = SCNVector3(layout.projector.x + lensPoint.x, lensPoint.y, layout.projector.y + lensPoint.z)
        let z = northZ + 0.105
        let x0 = layout.table.x - screenWidth / 2, x1 = layout.table.x + screenWidth / 2
        let y0 = screenCentreY - screenHeight / 2, y1 = screenCentreY + screenHeight / 2
        let beam = makeBeam(apex: apex, corners: [SCNVector3(x0, y1, z), SCNVector3(x1, y1, z), SCNVector3(x1, y0, z), SCNVector3(x0, y0, z)])
        room.addChildNode(beam)
        self.beam = beam
    }

    /// The empty chair: pulled out from the table and swivelled toward the
    /// doors -- the obvious empty place.
    private static func inviteChair(animated: Bool) {
        guard let chair = playerChair, let layout else { return }
        let foot = MeetingLayout.playerChair == 7
        let toward = simd_normalize(foot ? SIMD2<Float>(-0.45, -0.89) : SIMD2<Float>(-0.5, 0.87))
        let p = foot ? SCNVector3(layout.seat.x - 0.1, chair.position.y, layout.seat.y + 0.12)
                     : SCNVector3(layout.seat.x - 0.22, chair.position.y, layout.seat.y + 0.08)
        let yaw = atan2(toward.x, toward.y)
        if animated {
            let a = SCNAction.group([.move(to: p, duration: 0.5), .rotateTo(x: 0, y: CGFloat(yaw), z: 0, duration: 0.5, usesShortestUnitArc: true)])
            a.timingMode = .easeInEaseOut
            chair.runAction(a, forKey: "meetingChair")
        } else {
            chair.position = p
            chair.eulerAngles = SCNVector3(0, yaw, 0)
        }
    }

    /// Squared to the table again as the player sits.
    private static func squareChair(duration: Double) {
        guard let chair = playerChair, let layout else { return }
        let p = SCNVector3(layout.seat.x, chair.position.y, layout.seat.y)
        let a = SCNAction.group([.move(to: p, duration: duration * 0.8),
                                 .rotateTo(x: 0, y: CGFloat(MeetingLayout.playerChair == 7 ? Direction.south.yaw : Direction.west.yaw), z: 0,
                                           duration: duration * 0.8, usesShortestUnitArc: true)])
        a.timingMode = .easeInEaseOut
        chair.runAction(a, forKey: "meetingChair")
    }

    /// A pull-down projection screen hung in front of the north wall. Origin
    /// on the floor at the wall; faces +Z. Returns it and the (dark until the
    /// projector is on) projected picture.
    private static func makeScreen(width: Float, height: Float, centreY: Float) -> (SCNNode, SCNNode) {
        let root = SCNNode()
        root.name = "meetingScreen"
        let casing = AdministrationReception.material(UIColor(white: 0.18, alpha: 1), metal: 0.5, rough: 0.4)
        let fabric = AdministrationReception.material(UIColor(white: 0.9, alpha: 1), rough: 0.95)
        let border = AdministrationReception.material(UIColor(white: 0.06, alpha: 1), rough: 0.9)
        let top = centreY + height / 2
        // The roller case and its two wall brackets.
        let roller = SCNNode(geometry: SCNCylinder(radius: 0.055, height: CGFloat(width + 0.2)))
        roller.geometry?.materials = [casing]
        roller.eulerAngles.z = .pi / 2
        roller.position = SCNVector3(0, top + 0.17, 0.09)
        root.addChildNode(roller)
        for side: Float in [-1, 1] {
            AdministrationReception.box(0.05, 0.1, 0.09, casing, side * (width / 2 + 0.08), top + 0.17, 0.045, in: root, chamfer: 0.006)
        }
        // The sheet: black border, white field; a weighted hem and a pull cord.
        let back = SCNNode(geometry: SCNPlane(width: CGFloat(width + 0.08), height: CGFloat(height + 0.22)))
        back.geometry?.materials = [border]
        back.position = SCNVector3(0, centreY + 0.05, 0.098)
        root.addChildNode(back)
        let sheet = SCNNode(geometry: SCNPlane(width: CGFloat(width), height: CGFloat(height)))
        sheet.geometry?.materials = [fabric]
        sheet.position = SCNVector3(0, centreY, 0.1)
        root.addChildNode(sheet)
        AdministrationReception.box(CGFloat(width + 0.1), 0.025, 0.025, casing, 0, centreY - height / 2 - 0.125, 0.1, in: root, chamfer: 0.006)
        let cord = SCNNode(geometry: SCNCylinder(radius: 0.004, height: 0.16))
        cord.geometry?.materials = [casing]
        cord.position = SCNVector3(0, centreY - height / 2 - 0.22, 0.1)
        root.addChildNode(cord)
        // The projected picture: a self-lit plane just in front of the sheet.
        let picture = SCNNode(geometry: SCNPlane(width: CGFloat(width), height: CGFloat(height)))
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = titleCard()
        m.diffuse.mipFilter = .linear                 // crisp lettering from the far end of the table
        m.diffuse.maxAnisotropy = 8
        m.isDoubleSided = false
        picture.geometry?.materials = [m]
        picture.position = SCNVector3(0, centreY, 0.103)
        picture.castsShadow = false
        picture.opacity = 0
        picture.name = "meetingProjection"
        root.addChildNode(picture)
        return (root, picture)
    }

    /// A ceiling-mounted projector, lens toward the screen (north, -Z).
    /// Origin on the floor below it. Returns the unit, the lens and status
    /// light materials, and the lens's front point (unit-local).
    private static func makeProjector() -> (SCNNode, SCNMaterial, SCNMaterial, SCNVector3) {
        let root = SCNNode()
        root.name = "meetingProjector"
        let plastic = AdministrationReception.material(UIColor(white: 0.86, alpha: 1), rough: 0.5)
        let dark = AdministrationReception.material(UIColor(white: 0.14, alpha: 1), metal: 0.4, rough: 0.4)
        let ceiling: Float = 2.95, bodyY: Float = 2.52
        AdministrationReception.box(0.16, 0.015, 0.16, dark, 0, ceiling - 0.008, 0, in: root, chamfer: 0.003)   // ceiling plate
        let rod = SCNNode(geometry: SCNCylinder(radius: 0.016, height: CGFloat(ceiling - bodyY - 0.06)))
        rod.geometry?.materials = [dark]
        rod.position = SCNVector3(0, (ceiling + bodyY + 0.06) / 2, 0)
        root.addChildNode(rod)
        AdministrationReception.box(0.34, 0.12, 0.28, plastic, 0, bodyY, 0, in: root, chamfer: 0.02)            // the body
        for i in 0..<4 {                                                                                         // side vents
            AdministrationReception.box(0.004, 0.06, 0.016, dark, -0.171, bodyY, -0.06 + Float(i) * 0.04, in: root, chamfer: 0.001)
        }
        let lensGlass = SCNMaterial()
        lensGlass.lightingModel = .physicallyBased
        lensGlass.diffuse.contents = UIColor(white: 0.05, alpha: 1)
        lensGlass.roughness.contents = 0.1
        lensGlass.emission.contents = UIColor(red: 1, green: 0.97, blue: 0.88, alpha: 1)
        lensGlass.emission.intensity = 0
        let barrel = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 0.05))
        barrel.geometry?.materials = [dark]
        barrel.eulerAngles.x = .pi / 2
        barrel.position = SCNVector3(0.08, bodyY - 0.005, -0.16)
        root.addChildNode(barrel)
        let glass = SCNNode(geometry: SCNCylinder(radius: 0.038, height: 0.004))
        glass.geometry?.materials = [lensGlass]
        glass.eulerAngles.x = .pi / 2
        glass.position = SCNVector3(0.08, bodyY - 0.005, -0.186)
        root.addChildNode(glass)
        let ledMat = SCNMaterial()
        ledMat.lightingModel = .constant
        ledMat.diffuse.contents = UIColor(red: 0.9, green: 0.25, blue: 0.1, alpha: 1)        // standby
        let ledNode = SCNNode(geometry: SCNSphere(radius: 0.008))
        ledNode.geometry?.materials = [ledMat]
        ledNode.position = SCNVector3(-0.1, bodyY + 0.02, 0.141)                             // on the back, toward the table's foot
        root.addChildNode(ledNode)
        return (root, lensGlass, ledMat, SCNVector3(0.08, bodyY - 0.005, -0.19))
    }

    private static func makeBeam(apex: SCNVector3, corners: [SCNVector3]) -> SCNNode {
        let source = SCNGeometrySource(vertices: [apex] + corners)
        let indices: [Int32] = [0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 1]
        let geometry = SCNGeometry(sources: [source], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let m = SCNMaterial()
        m.lightingModel = .constant
        // Oct 12 (washout fix): additive blending ADDS this colour to whatever is behind
        // the beam -- including the screen, seen through its two faces -- and the 0.06
        // transparency evidently didn't scale it down: on the device the beam was a
        // bright white sheet over the picture. So the haze is in the colour itself
        // (~3.5% per face, premultiplied), whatever the blend does with alpha.
        m.diffuse.contents = UIColor(red: 0.035, green: 0.034, blue: 0.031, alpha: 1)
        m.transparency = 1
        m.blendMode = .add
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        geometry.materials = [m]
        let node = SCNNode(geometry: geometry)
        node.name = "meetingProjectorBeam"
        node.castsShadow = false
        node.opacity = 0
        node.renderingOrder = 10
        return node
    }

    /// The title card: the company's name and nothing else.
    private static func titleCard() -> UIImage {
        let size = CGSize(width: 1920, height: 1080)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.16, green: 0.2, blue: 0.28, alpha: 1).cgColor,
                          UIColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                cg.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: size.width * 0.62,
                                      options: [.drawsAfterEndLocation])
            }
            let cream = UIColor(red: 0.96, green: 0.93, blue: 0.84, alpha: 1)
            let gold = UIColor(red: 0.82, green: 0.68, blue: 0.38, alpha: 1)
            cg.setStrokeColor(cream.withAlphaComponent(0.18).cgColor)
            cg.setLineWidth(3)
            cg.stroke(CGRect(x: 70, y: 70, width: size.width - 140, height: size.height - 140))
            func draw(_ text: String, size points: CGFloat, weight: UIFont.Weight, kern: CGFloat, color: UIColor, centreY: CGFloat,
                      maxWidth: CGFloat = 1640) {
                var font = UIFont.systemFont(ofSize: points, weight: weight)
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
                var measured = (text as NSString).size(withAttributes: attributes)
                if measured.width > maxWidth {
                    font = UIFont.systemFont(ofSize: points * maxWidth / measured.width, weight: weight)
                    attributes[.font] = font
                    measured = (text as NSString).size(withAttributes: attributes)
                }
                (text as NSString).draw(at: CGPoint(x: (size.width - measured.width) / 2 + kern / 2, y: centreY - measured.height / 2),
                                        withAttributes: attributes)
            }
            draw("THE", size: 92, weight: .semibold, kern: 34, color: cream.withAlphaComponent(0.85), centreY: 318)
            draw("HALLWAYS", size: 270, weight: .heavy, kern: 14, color: cream, centreY: 532)
            cg.setFillColor(gold.cgColor)
            cg.fill(CGRect(x: size.width / 2 - 260, y: 690, width: 520, height: 5))
            draw("COMPANY", size: 116, weight: .semibold, kern: 44, color: cream.withAlphaComponent(0.92), centreY: 795)
        }
    }

    // MARK: The attendees this file owns (east side + the boss)

    private enum Body { case frog, pottle }

    private static func spawn(_ body: Body, chair: Int, seed: Int, layout: MeetingLayout, habitat: Habitat, scene: SCNScene) {
        let key = HabitatGraph.key(row: ConferenceRoom.entryCell.row, col: ConferenceRoom.entryCell.col)
        let shadow = Menagerie.shadowImage()
        let made: (Critter, SCNNode)
        switch body {
        case .frog: made = Frog.make(habitat: habitat, cell: key, shadow: shadow)
        case .pottle: made = Pottle.make(habitat: habitat, cell: key, shadow: shadow, scale: 0.95)
        }
        let (critter, node) = made
        let seat = layout.place(chair)
        let pose = addPose(to: critter)
        let attendee = MeetingAttendee(place: seat, layout: layout, mood: mood, pose: pose, seed: seed)
        settle(critter, node, at: seat, errand: MeetingSeatErrand(attendee: attendee), habitat: habitat, scene: scene)
    }

    private static func spawnBoss(aside: Bool, layout: MeetingLayout, habitat: Habitat, scene: SCNScene) {
        let key = HabitatGraph.key(row: ConferenceRoom.entryCell.row, col: ConferenceRoom.entryCell.col)
        let (critter, node) = Ladder.make(habitat: habitat, cell: key, shadow: Menagerie.shadowImage())
        node.name = "meetingBoss"
        node.scale = SCNVector3(1.15, 1.15, 1.15)
        dressBoss(node)
        let pose = addPose(to: critter)
        let errand = MeetingBossErrand(layout: layout, mood: mood, pose: pose, standingAside: aside)
        let spot = aside ? layout.aside : layout.head
        let head = MeetingPlace(chair: 6, spot: spot, approach: spot, height: 0, facing: aside ? layout.seat : layout.table)
        settle(critter, node, at: head, errand: errand, habitat: habitat, scene: scene)
    }

    private static func settle(_ critter: Critter, _ node: SCNNode, at place: MeetingPlace, errand: CritterErrand,
                               habitat: Habitat, scene: SCNScene) {
        critter.pos = place.spot
        critter.freePoint = place.spot
        critter.lift = place.height
        critter.heading = atan2(-(place.facing.x - place.spot.x), -(place.facing.y - place.spot.y))
        critter.wantSpeed = 0
        critter.errand = errand
        node.position = SCNVector3(place.spot.x, place.height, place.spot.y)
        node.eulerAngles = SCNVector3(0, critter.heading, 0)
        node.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }
        scene.rootNode.addChildNode(node)
        habitat.add(critter)
        node.runAction(.repeatForever(critter.tickAction()), forKey: "critterTick")
    }

    /// A red necktie on the boss's cap (the ladder's top step).
    private static func dressBoss(_ node: SCNNode) {
        guard let cap = node.childNode(withName: "cap", recursively: true) else { return }
        let red = Critter.mat(UIColor(red: 0.6, green: 0.05, blue: 0.07, alpha: 1), rough: 0.45)
        let gold = Critter.mat(UIColor(red: 0.85, green: 0.68, blue: 0.3, alpha: 1), metal: 0.3, rough: 0.4)
        Critter.part(SCNBox(width: 0.05, height: 0.045, length: 0.03, chamferRadius: 0.008), red, in: cap, at: SCNVector3(0, -0.035, -0.15))
        let blade = Critter.part(SCNBox(width: 0.062, height: 0.3, length: 0.012, chamferRadius: 0.004), red, in: cap,
                                 at: SCNVector3(0, -0.205, -0.165), euler: SCNVector3(0.06, 0, 0))
        for y: Float in [0.06, -0.02, -0.1] {
            Critter.part(SCNBox(width: 0.064, height: 0.01, length: 0.004, chamferRadius: 0.001), gold, in: blade,
                         at: SCNVector3(0, y, -0.007), euler: SCNVector3(0, 0, 0.5))
        }
        Critter.part(SCNBox(width: 0.044, height: 0.044, length: 0.012, chamferRadius: 0.003), red, in: cap,
                     at: SCNVector3(0, -0.355, -0.174), euler: SCNVector3(0.06, 0, .pi / 4))
    }

    /// Slips a pose node between a critter's root and its body, so the
    /// meeting can lean and tilt the whole creature (bows, nods, shifting in
    /// its seat) without touching its own gait/animation, which keeps
    /// driving the body underneath. Nil for a body with no separate root.
    static func addPose(to critter: Critter) -> SCNNode? {
        let body = critter.body
        guard let parent = body.parent, body !== critter.node else { return nil }
        if parent.name == "meetingPose" { return parent }
        let pose = SCNNode()
        pose.name = "meetingPose"
        parent.addChildNode(pose)
        body.removeFromParentNode()
        pose.addChildNode(body)
        return pose
    }
}

// MARK: - The room's geometry, as the attendees need it (values only)

nonisolated struct MeetingPlace: Sendable {
    let chair: Int
    /// Where it settles (x/z).
    let spot: SIMD2<Float>
    /// The floor point it walks to first (it climbs from there onto a
    /// chair seat or the table; or, on the floor, walks on to `spot`).
    let approach: SIMD2<Float>
    /// Its feet above the floor plane: 0, a chair seat, or the table top.
    let height: Float
    /// What it faces by default.
    let facing: SIMD2<Float>
}

nonisolated struct MeetingLayout: Sendable {
    /// ConferenceRoom's chair order: 0/2/4 west side (north to south),
    /// 1/3/5 east side, 6 the head (north), 7 the foot (south).
    /// The player's place: the west side, middle -- by the doors.
    /// (Oct 11, late) In the cast audition (ConferenceAudition) the player
    /// takes the foot (7), looking up the table at everyone.
    nonisolated static var playerChair: Int { ConferenceAudition.enabled ? 7 : 2 }
    /// Places with no chair: a critter (or the boss) stands there itself.
    /// The audition: only the head, where Juanita stands.
    nonisolated static var chairlessPlaces: [Int] { ConferenceAudition.enabled ? [6] : [4, 6, 7] }

    let cellSize: Float
    let table: SIMD2<Float>
    let head: SIMD2<Float>          // the boss's place
    let aside: SIMD2<Float>         // where he stands once the screen is on
    let screen: SIMD2<Float>        // the screen's centre (x/z, at the wall)
    let projector: SIMD2<Float>
    let seat: SIMD2<Float>          // the player's chair
    let door: SIMD2<Float>          // the glass doors
    private let places: [Int: MeetingPlace]

    @MainActor init(cellSize s: Float) {
        cellSize = s
        let t = ConferenceRoom.tableCenter == .zero ? SIMD2<Float>(10 * s + ConferenceRoom.tableOffsetX, 6 * s) : ConferenceRoom.tableCenter
        table = t
        let side = ConferenceRoom.tableWidth / 2 + 0.42
        let end = ConferenceRoom.tableLength / 2 + 0.42
        let rows: [Float] = [-1.75, 0, 1.75]
        func chair(_ i: Int) -> SIMD2<Float> {
            if i < 6 { return SIMD2<Float>(t.x + (i % 2 == 0 ? -side : side), t.y + rows[i / 2]) }
            return SIMD2<Float>(t.x, t.y + (i == 6 ? -end : end))
        }
        let seatTop = ConferenceRoom.floorTopY + 0.515
        let tableTop = ConferenceRoom.floorTopY + ConferenceRoom.tableTopHeight
        func across(_ i: Int) -> SIMD2<Float> { SIMD2<Float>(t.x + (i % 2 == 0 ? 3 : -3), chair(i).y) }
        func onTable(_ i: Int) -> SIMD2<Float> { SIMD2<Float>(t.x + (i % 2 == 0 ? -0.42 : 0.42), chair(i).y + 0.05) }
        places = [
            // West side (the procession's two, plus the player's chair, 2): the
            // Stalk stands in place 4. (Place 0, on the table, was the retired
            // Clacker's; Oct 19 it stays empty.)
            0: MeetingPlace(chair: 0, spot: onTable(0), approach: chair(0) + SIMD2<Float>(-0.3, 0.62), height: tableTop, facing: across(0)),
            4: MeetingPlace(chair: 4, spot: chair(4) + SIMD2<Float>(-0.12, 0), approach: chair(4) + SIMD2<Float>(-0.12, 0), height: 0, facing: across(4)),
            // The Chair takes the foot of the table, facing the boss.
            7: MeetingPlace(chair: 7, spot: chair(7), approach: SIMD2<Float>(t.x - 1.55, chair(7).y + 0.45), height: 0,
                            facing: SIMD2<Float>(t.x, t.y - 5)),
            // East side (already there): a Frog on the table, a Pottle on its
            // chair. (Place 5 was the retired small Clacker's; empty now.)
            1: MeetingPlace(chair: 1, spot: onTable(1), approach: chair(1), height: tableTop, facing: across(1)),
            3: MeetingPlace(chair: 3, spot: chair(3), approach: chair(3), height: seatTop, facing: across(3)),
            5: MeetingPlace(chair: 5, spot: onTable(5), approach: chair(5), height: tableTop, facing: across(5)),
        ]
        let northZ = 4.5 * s
        head = chair(6) + SIMD2<Float>(0, -0.15)
        aside = SIMD2<Float>(t.x + 0.8, head.y - 0.25)
        screen = SIMD2<Float>(t.x, northZ + 0.1)
        projector = SIMD2<Float>(t.x, t.y - 1.15)
        // The audition: the player's chair at the foot is pulled back from the
        // table a little -- sitting back to watch the cast.
        seat = chair(Self.playerChair) + (Self.playerChair == 7 ? SIMD2<Float>(0, 0.55) : .zero)
        door = SIMD2<Float>(8.5 * s, 6 * s)
    }

    func place(_ chair: Int) -> MeetingPlace { places[chair] ?? places[0]! }
    var allPlaces: [MeetingPlace] { Array(places.values) }
}

// MARK: - The script: every beat's timing, shared by director and actors

nonisolated enum MeetingScript {
    /// The chatter goes on this long after the player sits.
    static let chatterAfterSitting: Double = 2.6
    // ORDER (from the stage's start)
    /// The boss's two bangs on the table.
    static let bangs: [Double] = [0.32, 0.64]
    /// The excitable one's last little chirp...
    static let lastChirp: Double = 1.25
    /// ...the boss's look at it...
    static let sternLookFrom: Double = 1.55
    static let sternLookTo: Double = 3.1
    /// ...and the silence until he speaks.
    static let orderLength: Double = 5.4
    /// Who the excitable one is (MeetingAttendee.seed): the Frog, on the table
    /// at place 1. (Oct 19, Stage A: was the procession's Clacker, seed 0 --
    /// retired.)
    static let excitableSeed = 1
    // SPEECH
    static let speechStarts: [Double] = [0, 1.9, 3.9]
    static let speechLength: Double = 5.6
    // PROJECTOR (from the stage's start)
    static let dimAt: Double = 0.7
    static let projectorAt: Double = 1.8
    static let stepAsideAt: Double = 3.0
    static let projectorStageLength: Double = 5.2
}

// MARK: - The room's mood (main thread writes, critter ticks read)

nonisolated final class MeetingMood: @unchecked Sendable {
    enum Stage: String { case gathering, order, speech, projector, waiting }
    struct Snapshot {
        var stage: Stage = .gathering
        var serial = 0
        var nods = 0
        var playerSeated = false
        var playerInRoom = false
        var boss: SIMD2<Float>?
    }
    private let lock = NSLock()
    private var state = Snapshot()
    private var nextVoiceAt: CFTimeInterval = 0

    var snapshot: Snapshot { lock.withLock { state } }
    func set(_ stage: Stage) { lock.withLock { state.stage = stage; state.serial += 1 } }
    func reset(to stage: Stage) { lock.withLock { state.stage = stage; state.serial += 1; state.playerSeated = false; state.boss = nil } }
    func nod() { lock.withLock { state.nods += 1 } }
    func setPlayer(seated: Bool) { lock.withLock { state.playerSeated = seated } }
    func setPlayer(inRoom: Bool) { lock.withLock { state.playerInRoom = inRoom } }
    func setBoss(_ p: SIMD2<Float>) { lock.withLock { state.boss = p } }

    /// The room's conversational turn: one voice at a time, with a gap --
    /// a lively room, never a din. True = this caller may speak now.
    func claimVoice(gap: Double) -> Bool {
        let now = CACurrentMediaTime()
        return lock.withLock {
            guard now >= nextVoiceAt else { return false }
            nextVoiceAt = now + gap
            return true
        }
    }
}

nonisolated struct MeetingGesture {
    var start: Double = -100
    var length: Double = 1
    var lean: Float = 0          // + leans back, - leans forward (a bow, a nod)
    var roll: Float = 0
    func value(at t: Double) -> (lean: Float, roll: Float) {
        let u = (t - start) / length
        guard u >= 0, u < 1 else { return (0, 0) }
        let k = Float(sin(.pi * u))
        return (lean * k, roll * k)
    }
}

nonisolated struct MeetingHop {
    var start: Double = -100
    var length: Double = 0.5
    var count: Double = 2
    var height: Float = 0
    func lift(at t: Double) -> Float {
        let u = t - start
        guard u >= 0, u < length else { return 0 }
        return height * abs(sin(Float(.pi * count * u / length)))
    }
}

// MARK: - An attendee in its place (any body; the procession's too)

/// Before the meeting: chatting (one voice at a time), glancing about.
/// From the bang on: silent, turned to the boss, sitting up; a nod or one
/// exchanged glance during the speech; eyes on the screen once it's lit.
nonisolated final class MeetingAttendee: @unchecked Sendable {
    let place: MeetingPlace
    let layout: MeetingLayout
    let mood: MeetingMood
    let pose: SCNNode?
    let seed: Int
    private var clock: Double = 0
    private var serial = -1
    private var stage: MeetingMood.Stage = .gathering
    private var stageClock: Double = 0
    private var nods = 0
    private var sawPlayerSit = false
    private var nextVoice: Double
    private var nextLook: Double
    private var look: SIMD2<Float>?
    private var gesture = MeetingGesture()
    private var hop = MeetingHop()
    private var cowerFrom: Double = -100
    private var done = Set<Int>()

    init(place: MeetingPlace, layout: MeetingLayout, mood: MeetingMood, pose: SCNNode?, seed: Int) {
        self.place = place
        self.layout = layout
        self.mood = mood
        self.pose = pose
        self.seed = seed
        nextVoice = Double.random(in: 1.5...7)
        nextLook = Double.random(in: 0.5...3)
        nods = mood.snapshot.nods
    }

    private func once(_ key: Int) -> Bool { done.insert(key).inserted }

    private func player(_ c: Critter) -> SIMD2<Float>? {
        c.habitat.playerCamera.map { let p = $0.presentation.worldPosition; return SIMD2<Float>(p.x, p.z) }
    }

    private func neighbour() -> SIMD2<Float> {
        layout.allPlaces.filter { $0.chair != place.chair }.randomElement()?.spot ?? layout.table
    }

    /// Runs in the critter's tick; returns its lift.
    func step(_ c: Critter, dt: Double) -> Float {
        clock += dt
        let m = mood.snapshot
        if m.serial != serial {
            serial = m.serial
            stage = m.stage
            stageClock = 0
            done.removeAll()
        } else {
            stageClock += dt
        }
        let boss = m.boss ?? layout.head
        let you = player(c)
        let t = stageClock
        let stagger = Double(seed % 6) * 0.06
        // In its place; still once there (no idle shuffling of gaits).
        c.freePoint = place.spot
        c.wantSpeed = simd_length(place.spot - c.pos) > 0.04 ? 0.45 : 0
        if m.nods != nods {                       // the player sat down again: some glance their way
            nods = m.nods
            if seed % 2 == 0 { look = you; nextLook = clock + 2.5 }
        }
        switch stage {
        case .gathering:
            if m.playerSeated, !sawPlayerSit {
                sawPlayerSit = true                // a newcomer: a glance or two
                if seed % 2 == 0 { look = you; nextLook = clock + Double.random(in: 1.2...2.2) }
            }
            if !m.playerSeated { sawPlayerSit = false }
            if clock >= nextLook {
                let r = Float.random(in: 0...1)
                if m.playerInRoom, !m.playerSeated, r < 0.3, let you { look = you }
                else if r < 0.7 { look = neighbour() }
                else if r < 0.85 { look = boss }
                else { look = layout.table }
                nextLook = clock + Double.random(in: 3...7)
                if Float.random(in: 0...1) < 0.15 {
                    gesture = MeetingGesture(start: clock, length: 1.6, lean: -0.06, roll: Float.random(in: -0.05...0.05))
                }
            }
            if clock >= nextVoice {
                if mood.claimVoice(gap: Double.random(in: 1.4...2.8)) {
                    if Float.random(in: 0...1) < 0.12 {
                        c.say(MeetingErrand.laugh, loud: false)
                        hop = MeetingHop(start: clock, length: 0.6, count: 3, height: 0.025)
                    } else {
                        c.say(MeetingErrand.murmurs.randomElement(), loud: false)
                    }
                    nextVoice = clock + Double.random(in: 5...11)
                } else {
                    nextVoice = clock + Double.random(in: 0.6...1.4)
                }
            }
        case .order:
            // The bang: everyone stops and turns to him; the ones on the
            // table jump with it; everyone sits up.
            if t > MeetingScript.bangs[0] + 0.05 + stagger { look = boss }
            if place.height > 0.7 {
                for (i, bang) in MeetingScript.bangs.enumerated() where t >= bang + 0.02 && once(i) {
                    hop = MeetingHop(start: clock, length: 0.16, count: 1, height: 0.022)
                }
            }
            if t > 0.5 + stagger, once(5) { gesture = MeetingGesture(start: clock, length: 1.2, lean: 0.05, roll: 0) }
            if seed == MeetingScript.excitableSeed {
                if t >= MeetingScript.lastChirp, once(6) {          // just one more little...
                    c.say(MeetingVoices.peep, loud: false)
                    hop = MeetingHop(start: clock, length: 0.3, count: 1, height: 0.03)
                }
                if t >= MeetingScript.sternLookFrom + 0.4, once(7) { cowerFrom = clock }   // ...the look. It shrinks.
            }
        case .speech:
            look = boss
            // A nod here and there; one exchanged glance. Nothing else.
            let nodAt: [Int: Double] = [4: 1.6, 3: 3.7, 1: 5.1]
            if let at = nodAt[seed], t >= at, once(1) { gesture = MeetingGesture(start: clock, length: 0.6, lean: -0.13, roll: 0) }
            // (Oct 19: the glance was the small Clacker's and the Pottle's; now the Frog's and the Pottle's.)
            if seed == 1, t >= 2.4, t < 3.5 { look = layout.place(3).spot }
            if seed == 3, t >= 2.6, t < 3.4 { look = layout.place(1).spot }
        case .projector:
            look = t < 0.3 + stagger ? boss : layout.screen          // they follow his gesture
            if t >= MeetingScript.projectorAt + 0.35 + stagger, once(1) {
                gesture = MeetingGesture(start: clock, length: 1.0, lean: 0.05, roll: 0)
            }
        case .waiting:
            if clock >= nextLook {
                look = Float.random(in: 0...1) < 0.78 ? layout.screen : boss
                nextLook = clock + Double.random(in: 8...14)
                if Float.random(in: 0...1) < 0.1 {
                    gesture = MeetingGesture(start: clock, length: 1.8, lean: Float.random(in: -0.04...0.03), roll: Float.random(in: -0.04...0.04))
                }
            }
        }
        c.lookAt = look
        let g = gesture.value(at: clock)
        var lean = g.lean + sin(Float(clock) * 0.9 + Float(seed)) * 0.008
        var size: Float = 1
        let cw = clock - cowerFrom
        if cw >= 0, cw < 3.0 {
            let k = Float(cw < 0.2 ? cw / 0.2 : (cw > 2.3 ? (3.0 - cw) / 0.7 : 1))
            lean += 0.1 * k
            size = 1 - 0.12 * k
        }
        pose?.eulerAngles = SCNVector3(lean, 0, g.roll)
        pose?.scale = SCNVector3(size, size, size)
        return place.height + hop.lift(at: clock)
    }
}

/// The east side's errand: just being at the meeting.
nonisolated final class MeetingSeatErrand: CritterErrand, @unchecked Sendable {
    let attendee: MeetingAttendee
    init(attendee: MeetingAttendee) { self.attendee = attendee }
    override func step(_ critter: Critter, dt: Double, now: CFTimeInterval) {
        critter.lift = attendee.step(critter, dt: dt)
    }
}

// MARK: - The boss

nonisolated final class MeetingBossErrand: CritterErrand, @unchecked Sendable {
    /// The bang: (time in the order stage, lean) keyframes -- rock back,
    /// slam forward onto the table, again, settle.
    private static let bangPose: [(Double, Float)] = [(0, 0), (0.28, 0.2), (0.34, -0.32), (0.48, -0.1), (0.62, -0.32), (0.9, -0.05), (1.3, 0)]

    let layout: MeetingLayout
    let mood: MeetingMood
    let pose: SCNNode?
    private var spot: SIMD2<Float>
    private var clock: Double = 0
    private var serial = -1
    private var stage: MeetingMood.Stage = .gathering
    private var stageClock: Double = 0
    private var nods = 0
    private var nodAt: Double = -100
    private var look: SIMD2<Float>?
    private var nextLook = Double.random(in: 1...3)
    private var nextHum = Double.random(in: 10...18)
    private var wasInvited = false
    private var inviteAt: Double = -100
    private var inviteStep = 0
    private var gesture = MeetingGesture()
    private var hop = MeetingHop()
    private var done = Set<Int>()

    init(layout: MeetingLayout, mood: MeetingMood, pose: SCNNode?, standingAside: Bool) {
        self.layout = layout
        self.mood = mood
        self.pose = pose
        spot = standingAside ? layout.aside : layout.head
        nods = mood.snapshot.nods
    }

    private func once(_ key: Int) -> Bool { done.insert(key).inserted }

    private func player(_ c: Critter) -> SIMD2<Float>? {
        c.habitat.playerCamera.map { let p = $0.presentation.worldPosition; return SIMD2<Float>(p.x, p.z) }
    }

    private static func keyframed(_ frames: [(Double, Float)], at t: Double) -> Float {
        guard let last = frames.last, t < last.0 else { return frames.last?.1 ?? 0 }
        for i in 1..<frames.count where t < frames[i].0 {
            let (t0, v0) = frames[i - 1], (t1, v1) = frames[i]
            let u = Float((t - t0) / (t1 - t0))
            return v0 + (v1 - v0) * u
        }
        return last.1
    }

    override func step(_ c: Critter, dt: Double, now: CFTimeInterval) {
        clock += dt
        let m = mood.snapshot
        if m.serial != serial {
            serial = m.serial
            stage = m.stage
            stageClock = 0
            done.removeAll()
        } else {
            stageClock += dt
        }
        mood.setBoss(c.pos)
        let you = player(c) ?? layout.seat
        let t = stageClock
        let S = MeetingScript.self
        var talking = false
        var heldLean: Float?
        switch stage {
        case .gathering:
            spot = layout.head
            // The player comes in: he looks at them, calls once, and shows
            // them their chair. (Again only after a long while.)
            let standingInRoom = m.playerInRoom && !m.playerSeated
            if standingInRoom, !wasInvited || clock - inviteAt > 40 {
                inviteAt = clock + (wasInvited ? 0.4 : 0.9)
                inviteStep = 0
                wasInvited = true
            }
            if !m.playerInRoom { wasInvited = false }
            let it = clock - inviteAt
            if it >= 0, it < 4.2, standingInRoom {
                look = it < 1.4 ? you : (it < 2.8 ? layout.seat : you)
                if inviteStep == 0, it >= 0.15 {
                    c.say(MeetingVoices.invite, loud: false)
                    hop = MeetingHop(start: clock, length: 0.5, count: 2, height: 0.06)
                    inviteStep = 1
                }
                if inviteStep == 1, it >= 1.45 {
                    gesture = MeetingGesture(start: clock, length: 1.3, lean: -0.14, roll: 0)
                    inviteStep = 2
                }
            } else {
                if clock >= nextLook {
                    look = [layout.table, layout.place(0).spot, layout.place(3).spot, layout.door, layout.place(5).spot].randomElement()
                    nextLook = clock + Double.random(in: 4...7)
                }
                if clock >= nextHum {
                    if mood.claimVoice(gap: 2) { c.say(MeetingVoices.hum, loud: false) }
                    nextHum = clock + Double.random(in: 20...35)
                }
            }
        case .order:
            spot = layout.head
            // BANG, BANG -- then a look at the one who chirped -- then the room.
            heldLean = Self.keyframed(Self.bangPose, at: t)
            for (i, bang) in S.bangs.enumerated() where t >= bang && once(i) { c.say(MeetingVoices.gavel, loud: false) }
            if t < S.sternLookFrom { look = layout.table }
            else if t < S.sternLookTo {
                look = layout.place(S.excitableSeed).spot
                let u = (t - S.sternLookFrom) / (S.sternLookTo - S.sternLookFrom)
                heldLean = -0.1 * Float(sin(.pi * u))                  // leaning in, unamused
            } else { look = you }
        case .speech:
            spot = layout.head
            for (i, s) in S.speechStarts.enumerated() where t >= s && once(i) {
                if !MeetingVoices.speech.isEmpty { c.say(MeetingVoices.speech[i % MeetingVoices.speech.count], loud: false) }
                switch i {
                case 0: gesture = MeetingGesture(start: clock, length: 1.5, lean: -0.08, roll: 0.06)
                case 1: gesture = MeetingGesture(start: clock, length: 1.7, lean: -0.06, roll: -0.08)
                default: gesture = MeetingGesture(start: clock, length: 1.0, lean: -0.05, roll: 0.05)
                }
            }
            if t >= S.speechStarts[2] + 1.15, once(10) {                // the big finish
                hop = MeetingHop(start: clock, length: 0.45, count: 1, height: 0.09)
                gesture = MeetingGesture(start: clock, length: 0.9, lean: 0.1, roll: 0)
            }
            talking = t < S.speechLength - 0.3
            if t < S.speechStarts[1] { look = you }
            else if t < S.speechStarts[1] + 0.8 { look = layout.place(0).spot }
            else if t < S.speechStarts[2] { look = layout.place(3).spot }
            else { look = you }
        case .projector:
            // He turns and gestures at the screen; starts the projector; steps aside.
            if t < 0.2 { look = you }
            else if t < S.projectorAt - 0.4 { look = layout.screen }
            else if t < S.projectorAt + 0.3 { look = layout.projector }
            else { look = layout.screen }
            if t > 0.2, once(1) {
                c.say(MeetingVoices.aha, loud: false)
                gesture = MeetingGesture(start: clock, length: 1.4, lean: -0.18, roll: 0)
            }
            if t >= S.projectorAt - 0.15, once(2) {
                hop = MeetingHop(start: clock, length: 0.25, count: 1, height: 0.04)   // click
            }
            if t > S.stepAsideAt { spot = layout.aside }
            if t > S.stepAsideAt, simd_length(spot - c.pos) < 0.08 { look = you }
        case .waiting:
            spot = layout.aside
            if simd_length(spot - c.pos) < 0.08 {
                if clock >= nextLook {
                    let r = Float.random(in: 0...1)
                    look = r < 0.3 ? layout.screen : (r < 0.75 ? (m.playerSeated ? you : layout.table) : layout.table)
                    nextLook = clock + Double.random(in: 6...10)
                }
            } else {
                look = nil
            }
        }
        // Welcome back (the player sat down again later): a silent nod.
        if m.nods != nods {
            nods = m.nods
            nodAt = clock
            done.remove(20)
        }
        let since = clock - nodAt
        if since >= 0, since < 1.6 {
            look = you
            if since > 0.2, once(20) { gesture = MeetingGesture(start: clock, length: 0.8, lean: -0.15, roll: 0) }
        }
        c.freePoint = spot
        c.wantSpeed = simd_length(spot - c.pos) > 0.06 ? 0.6 : 0
        c.lookAt = look
        let g = gesture.value(at: clock)
        let sway = talking ? sin(Float(clock) * 4.2) * 0.035 : sin(Float(clock) * 0.7) * 0.01
        pose?.eulerAngles = SCNVector3(heldLean ?? g.lean, 0, g.roll + sway)
        c.lift = hop.lift(at: clock)
    }
}

// MARK: - Hallenese (synthesised, like every critter voice)

nonisolated enum MeetingVoices {
    static func prepare() {
        _ = (invite, hum, aha, speech, peep, gavel, click, whirr)
    }

    /// Formants (Hz, bandwidth, gain) of a few vowel colours.
    private static let vowels: [[(Float, Float, Float)]] = [
        [(730, 90, 1), (1090, 110, 0.5), (2440, 170, 0.18)],     // 0 ah
        [(570, 80, 1), (840, 100, 0.55), (2410, 170, 0.12)],     // 1 oh
        [(300, 60, 1), (2200, 150, 0.35), (2950, 200, 0.15)],    // 2 ee
        [(320, 70, 1), (800, 90, 0.4), (2240, 170, 0.1)],        // 3 oo
        [(530, 80, 1), (1840, 130, 0.4), (2480, 180, 0.15)],     // 4 eh
        [(640, 90, 1), (1190, 110, 0.45), (2390, 170, 0.13)],    // 5 uh
        [(250, 50, 1), (1000, 120, 0.06), (2300, 200, 0.03)],    // 6 mm (hummed)
    ]

    struct Syl {
        let v: Int
        let s: Float
        let a: Float
        let b: Float
        var gap: Float = 0.05
        var stop = false
    }

    /// A run of syllables: each voiced with its pitch contour, gliding in
    /// from the vowel before; `stop` puts a small consonant tick in front.
    /// Oct 12 (Telephone voice audition): `jitter`, `openQuotient` (see
    /// AnimalVoice.voice) and `vibrato` (a slight 5.5 Hz pitch waver on
    /// syllables longer than 0.15 s) -- all defaulting to exactly what every
    /// existing voice used, so nothing else changes.
    static func speak(_ syllables: [Syl], seed: UInt64, formantScale: Float = 1, breath: Float = 0.06,
                      jitter: Float = 0.03, openQuotient: Float = 0.42, vibrato: Float = 0) -> [Float] {
        var rng = Rand(seed: seed)
        var parts: [(at: Float, samples: [Float], gain: Float)] = []
        var t: Float = 0
        for (i, s) in syllables.enumerated() {
            let previous = vowels[i > 0 ? syllables[i - 1].v : s.v], current = vowels[s.v]
            if s.stop {
                parts.append((at: t, samples: MenagerieSound.strike([(rng.range(1700, 2600), 0.006, 0.4)], seconds: 0.02, noise: 0.8,
                                                                    noiseDecay: 0.003, rng: &rng), gain: 0.3))
                t += 0.018
            }
            let waver = vibrato > 0 && s.s > 0.15 ? vibrato : 0
            let samples = AnimalVoice.voice(seconds: s.s, breath: breath, jitter: jitter, openQuotient: openQuotient, rng: &rng,
                                            f0: { u in (s.a + (s.b - s.a) * u) * (1 + waver * sin(2 * .pi * 5.5 * u * s.s)) },
                                            formants: { u in
                                                let k = min(1, u / 0.25)
                                                return zip(previous, current).map { pair -> (Float, Float, Float) in
                                                    let (p, c) = pair
                                                    return ((p.0 + (c.0 - p.0) * k) * formantScale, c.1, c.2)
                                                }
                                            },
                                            env: { u in min(1, u / 0.12) * min(1, (1 - u) / 0.28) })
            parts.append((at: t, samples: samples, gain: 1))
            t += s.s + s.gap
        }
        return MenagerieSound.mix(parts)
    }

    // The boss: a deep, wooden, unhurried voice.
    static let invite: SCNAudioSource? = MenagerieSound.source("mtg-boss-invite", volume: 0.9) {
        speak([Syl(v: 6, s: 0.16, a: 135, b: 130), Syl(v: 6, s: 0.32, a: 140, b: 205)], seed: 3102, formantScale: 0.92)
    }
    static let hum: SCNAudioSource? = MenagerieSound.source("mtg-boss-hum", volume: 0.5) {
        speak([Syl(v: 6, s: 0.55, a: 122, b: 104)], seed: 3104, formantScale: 0.92)
    }
    static let aha: SCNAudioSource? = MenagerieSound.source("mtg-boss-aha", volume: 0.85) {
        speak([Syl(v: 0, s: 0.1, a: 128, b: 126), Syl(v: 0, s: 0.18, a: 140, b: 175)], seed: 3105, formantScale: 0.92)
    }
    static let speech: [SCNAudioSource] = [
        MenagerieSound.source("mtg-boss-speech-0", volume: 1) {
            speak([Syl(v: 5, s: 0.13, a: 128, b: 126, stop: true), Syl(v: 4, s: 0.2, a: 140, b: 152), Syl(v: 1, s: 0.26, a: 150, b: 120, gap: 0.2),
                   Syl(v: 0, s: 0.15, a: 126, b: 130, stop: true), Syl(v: 2, s: 0.13, a: 136, b: 132), Syl(v: 1, s: 0.32, a: 142, b: 104)],
                  seed: 3111, formantScale: 0.92)
        },
        MenagerieSound.source("mtg-boss-speech-1", volume: 1) {
            speak([Syl(v: 0, s: 0.12, a: 122, b: 136), Syl(v: 0, s: 0.18, a: 152, b: 168, stop: true), Syl(v: 4, s: 0.14, a: 142, b: 140),
                   Syl(v: 3, s: 0.2, a: 132, b: 120, gap: 0.16), Syl(v: 5, s: 0.12, a: 126, b: 126, stop: true), Syl(v: 2, s: 0.22, a: 146, b: 172),
                   Syl(v: 1, s: 0.3, a: 160, b: 116)],
                  seed: 3112, formantScale: 0.92)
        },
        MenagerieSound.source("mtg-boss-speech-2", volume: 1) {
            speak([Syl(v: 1, s: 0.16, a: 116, b: 118), Syl(v: 4, s: 0.14, a: 126, b: 128, stop: true), Syl(v: 0, s: 0.2, a: 132, b: 130, gap: 0.14),
                   Syl(v: 5, s: 0.12, a: 120, b: 120), Syl(v: 2, s: 0.14, a: 136, b: 142, stop: true), Syl(v: 0, s: 0.46, a: 152, b: 218)],
                  seed: 3113, formantScale: 0.92)
        },
    ].compactMap { $0 }
    /// The bang: a heavy wooden THOCK on the table top.
    static let gavel: SCNAudioSource? = MenagerieSound.source("mtg-boss-gavel", volume: 1) {
        var rng = Rand(seed: 3141)
        let body = MenagerieSound.strike([(150, 0.11, 1), (330, 0.07, 0.55), (760, 0.03, 0.3), (1650, 0.012, 0.15)],
                                         seconds: 0.4, noise: 0.9, noiseDecay: 0.004, rng: &rng)
        let rattle = MenagerieSound.strike([(2400, 0.02, 0.2), (3900, 0.012, 0.1)], seconds: 0.08, noise: 0.3, rng: &rng)
        return MenagerieSound.mix([(at: 0, samples: body, gain: 1), (at: 0.05, samples: rattle, gain: 0.35)])
    }

    // The excitable one: one last tiny chirp.
    static let peep: SCNAudioSource? = MenagerieSound.source("mtg-peep", volume: 0.6) {
        MenagerieSound.mix([(at: 0, samples: MenagerieSound.sweep(1900, 2700, seconds: 0.07, wobble: 0.3, curve: 0.7), gain: 1),
                            (at: 0.09, samples: MenagerieSound.sweep(2500, 2300, seconds: 0.05, wobble: 0.2), gain: 0.6)])
    }

    // The projector: its switch, then the fan spinning up.
    static let click: SCNAudioSource? = MenagerieSound.source("mtg-projector-click", volume: 0.6) {
        var rng = Rand(seed: 3131)
        let a = MenagerieSound.strike([(1900, 0.012, 0.5), (4200, 0.006, 0.25)], seconds: 0.06, noise: 0.6, rng: &rng)
        let b = MenagerieSound.strike([(1500, 0.01, 0.4), (3600, 0.005, 0.2)], seconds: 0.05, noise: 0.5, rng: &rng)
        return MenagerieSound.mix([(at: 0, samples: a, gain: 1), (at: 0.09, samples: b, gain: 0.6)])
    }
    static let whirr: SCNAudioSource? = MenagerieSound.source("mtg-projector-whirr", volume: 0.35) {
        var rng = Rand(seed: 3132)
        let low = MenagerieSound.sweep(60, 160, seconds: 1.4, wobble: 0.25, curve: 0.5)
        let high = MenagerieSound.sweep(120, 330, seconds: 1.4, wobble: 0.2, curve: 0.5)
        let air = AnimalVoice.breathNoise(seconds: 1.4, centre: 900, width: 1200, rng: &rng, env: { u in min(1, u / 0.5) * min(1, (1 - u) / 0.3) })
        return MenagerieSound.mix([(at: 0, samples: low, gain: 1), (at: 0, samples: high, gain: 0.4), (at: 0, samples: air, gain: 0.3)])
    }
}
