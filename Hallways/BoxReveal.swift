import SceneKit
import Combine
import Metal
import UIKit
import simd

/// Oct 12 -- THE BIG REVEAL: "The Hallways Corporation Presents THE BOX".
/// (Rewritten the same day after the first device test: see PICTURE below.)
///
/// A product launch in the Floor 3 conference room, round five's cast in
/// their places, the Rotary Telephone presenting. The corporation means to
/// demonstrate a product. Harold has other ideas -- not many, but his own:
///
///   ORDER       the Telephone slams his receiver; the room goes quiet (the
///               Mailbox gets one chirp out and is looked at); proud words.
///   DARK        lights down, the receiver raised to the screen, the
///               projector clicks on: THE HALLWAYS CORPORATION / Proudly
///               Presents ... THE BOX / The World's Most Human-Like AI
///               Companion Yet!  The camera glides up the table to just
///               behind the presenter.
///   PRODUCT     a dark stage; Harold -- the real Black Box, asleep -- turns
///               slowly under a key light and two rim lights and stops
///               facing us.
///   1 OBEDIENCE "Demonstration 1: Obedience." The Telephone commands. Harold
///               sleeps on. He commands again, louder. Nothing. (The Mailbox
///               giggles.) He SLAMS the receiver -- Harold jumps awake, looks
///               out at the room, and smiles as if nothing happened.
///   2 CURIOSITY "Demonstration 2: Curiosity." A firefly wanders onto the
///               stage. Harold watches -- then simply LIFTS OFF his pedestal
///               and floats after it (nobody said he could fly). It darts at
///               his face; he startles; it settles on his head; he goes shy
///               and pleased, eyes turned up at it. He floats back down.
///   3 CREATIVITY "Demonstration 3: Creativity." The firefly lifts away. He
///               thinks (the Camera's flash goes off, of course, right then),
///               composes and dances Harold's own first tune, and bows.
///   THE CHOICE  "Thank you." -- the corporation is done. Harold is not: he
///               rises and floats right up to the lens, his face filling the
///               screen, looks at YOU, and bows -- to you. Then he pushes the
///               corporation's own end card on from the wings himself, peeks
///               round its edge, and is gone. THE BOX / From The Hallways
///               Corporation. The room reacts (the Stove, grudgingly), the
///               camera returns to the chair, the lights come up.
///
/// PICTURE: Harold's stage is a small SceneKit scene of its own, rendered by
/// an SCNRenderer straight into a Metal texture (sRGB) ~30 times a second;
/// that texture is the projection's material (constant lighting, so exactly
/// what was rendered). The slides are plain images drawn into that same
/// stage, in front of its camera. (The first version drew the screen with
/// SpriteKit -- on the device it came out washed-out white, never advanced
/// past the title and never showed the 3D box.) When the show ends the
/// renderer stops and the screen holds a still end card.
///
/// CAMERA: seated and hands-off, the view eases (no cuts) to the presenter,
/// then up the table to just behind him, where the screen fills the phone's
/// width; back to the chair at the end. Any drag or pinch puts the camera
/// straight back in the chair and the show stops steering it; STAND does the
/// same first. Leaving the room ends the show (lights up, end card).
///
/// STATE: StoryBeats `reveal.theBox.shown` (recorded once THE BOX is on the
/// screen). Replay: `-HallwaysReplayBoxReveal YES`, or DEBUG Settings >
/// Replay Conference Meeting. `-HallwaysNoBoxReveal YES` turns it off.
/// `-HallwaysRevealFlipY YES` if the picture ever comes out upside down.
enum BoxReveal {
    static let shownBeat = "reveal.theBox.shown"
    static var isEnabled: Bool {
        ConferenceAudition.enabled && ConferenceAudition.round == 5 && !UserDefaults.standard.bool(forKey: "HallwaysNoBoxReveal")
    }
    private static var replayLaunch: Bool { UserDefaults.standard.bool(forKey: "HallwaysReplayBoxReveal") }
    /// A replay has been asked for and not yet begun.
    static var isReplayArmed: Bool { replayArmed }
    /// This run is a replay (not the meeting's own presentation).
    private static var runIsReplay = false
    /// Oct 12 (playtest): this run is the meeting's own presentation -- its
    /// completion is recorded (at the end card).
    private static var runCompletesMeeting = false

    // This floor build.
    private static weak var room: SCNNode?
    private static var layout: MeetingLayout?
    private static var generation = 0
    private static var playedThisBuild = false
    private static var replayArmed = false
    private(set) static var isRunning = false
    private static var lightsDown = false
    private static var stage: RevealStage?
    private static var projector: RevealProjector?
    private static weak var soundAnchor: SCNNode?
    private static var endedNormally = false

    // Camera.
    private static var cameraYielded = false             // the player took the camera: the show stops steering it
    private static var seatLocal: SCNVector3?            // the chair (camera-parent space), captured as the show begins
    private static var dollied = false                   // the camera is away from the chair (up the table)

    // MARK: Replay from the room (Oct 12, later; playtest fixes Oct 12)
    //
    // Once THE BOX has been shown, a tap on the room's presentation equipment
    // -- the screen or the projector -- REPLAYS it: the player is taken to
    // their chair if standing; then (the room empty) the view fades to black
    // and back with everyone seated (the curtain, below), and THE BOX
    // plays from its start (projector off, lights up). During a replay
    // the HUD's centre button is SKIP for the whole show. Story progress,
    // saves and position are untouched; nothing is recorded again.
    // (Was: the tap only offered REPLAY on the HUD for 8 s -- easily missed.)

    private static var replayOfferedUntil: CFTimeInterval = 0

    static var canReplay: Bool {
        isEnabled && !isRunning && !staging && !curtainBusy && !emergencyActive && StoryBeats.shared.has(shownBeat) && room?.parent != nil
    }

    // MARK: Oct 13 -- THE EMERGENCY (an experiment; deliberately unexplained)
    //
    // Part way through Harold's own tune (Demonstration 3), the first time the
    // meeting's presentation plays: a building alarm, the projector cut to
    // black, the show stopped dead -- music, slides, cues, camera moves, the
    // ending: every pending callback is stale from that instant (the show's
    // `generation`). The room goes dark but for a steady red (no flashing,
    // no strobe: one quick swell in, a slow fade out). After ~9 s the alarm
    // stops, the red fades, the room lights come back. Nothing is said or
    // shown; nothing resumes. The player is in their chair, free to stand.
    //
    // State: `meeting.theBox.emergency` and the meeting's own
    // `meeting.theBox.done` are recorded AS it begins -- so it happens once,
    // and a quit/relaunch at any moment finds the meeting over: an empty,
    // normally lit room (the red light and the alarm belong to the room node,
    // gone with the floor). The cast stay seated until the player walks out
    // (then they leave, as after any finished meeting). REPLAY (tap the
    // screen) plays the original, uninterrupted presentation, as before.
    // Off: `-HallwaysNoEmergency YES`, or delete the `at(Self.emergencyAt)`
    // line in begin().
    static let emergencyBeat = "meeting.theBox.emergency"
    static let emergencyAt: Double = 55.2                       // show seconds (Harold's tune began at 49.2)
    static let emergencySeconds: Double = 9.0
    static var emergencyEnabled: Bool { !UserDefaults.standard.bool(forKey: "HallwaysNoEmergency") }
    private(set) static var emergencyActive = false
    private static var emergencyToken = 0

    private static func emergency(gen: Int) {
        guard gen == generation, isRunning, let room else { return }
        _ = StoryBeats.shared.record(emergencyBeat, at: Date())
        TheBoxMeeting.presentationCompleted()                       // the meeting is over (it never reaches its end)
        diag("emergency.begin", ["run": runSerial])
        // 1. The presentation stops dead.
        generation += 1                                             // every show cue, the bow watch, the ending: stale
        isRunning = false
        projector?.stop()
        projector = nil
        stage?.brain.shutdown(reason: "emergency")                  // Harold's music stops
        stage = nil
        soundAnchor?.removeFromParentNode()
        ConferenceAudition.room.setShow(false, focus: nil)
        ConferenceAudition.room.hold(emergencySeconds + 6)         // nobody chats through it
        ConferenceMeeting.setProjector(on: false, animated: false) // the picture: gone
        if dollied { returnCameraToSeat() }                         // back in the chair (a cut)
        dollied = false
        endedNormally = false
        ConferenceMeeting.controller?.objectWillChange.send()       // (HUD: SKIP off, STAND on)
        for m in ConferenceAudition.members {                       // heads up, everyone
            ConferenceAudition.room.cue(m.id, .react(1), delay: 0.25 + 0.12 * Double(m.id))
        }
        // 2. Dark, and red.
        emergencyActive = true
        emergencyToken += 1
        let token = emergencyToken
        ConferenceMeeting.restoreLights(duration: 0)               // (from the show's dimness...)
        ConferenceMeeting.dimLights(animated: false, level: 0.06)   // (...to nearly dark, the same frame)
        lightsDown = true
        let red = UIColor(red: 1, green: 0.08, blue: 0.04, alpha: 1)
        let wash = SCNNode()
        wash.name = "emergencyLight"
        let omni = SCNLight()
        omni.type = .omni
        omni.color = red
        omni.intensity = 0
        omni.attenuationStartDistance = 2
        omni.attenuationEndDistance = 9
        wash.light = omni
        if let layout { wash.position = SCNVector3(layout.table.x, 2.6, layout.table.y) }
        room.addChildNode(wash)
        let glow = SCNNode()
        glow.name = "emergencyAmbient"
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = red
        ambient.intensity = 0
        glow.light = ambient
        room.addChildNode(glow)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.6                      // one swell in -- never a flash
        omni.intensity = 1600
        ambient.intensity = 160                                     // (ambient: the whole floor glows faintly red too)
        SCNTransaction.commit()
        // 3. The alarm (through the scene's audio: Mute applies).
        let siren = SCNNode()
        siren.name = "emergencyAlarm"
        room.addChildNode(siren)
        if let source = EmergencySound.alarm { siren.addAudioPlayer(SCNAudioPlayer(source: source)) }
        // 4. ...and then quiet.
        DispatchQueue.main.asyncAfter(deadline: .now() + emergencySeconds) {
            guard token == emergencyToken else { return }
            siren.removeAllAudioPlayers()
            siren.removeFromParentNode()
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 2.5
            omni.intensity = 0
            ambient.intensity = 0
            SCNTransaction.commit()
            if self.room === room, !isRunning {
                ConferenceMeeting.restoreLights(duration: 2.5)
                lightsDown = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                wash.removeFromParentNode()
                glow.removeFromParentNode()
                if token == emergencyToken { emergencyActive = false }
                diag("emergency.over", [:])
            }
            diag("emergency.alarmStopped", [:])
        }
    }

    /// The room's presentation equipment: the screen, its frame, the picture
    /// on it -- or (Oct 12, the room remembers) the projector itself.
    static func isScreen(_ node: SCNNode) -> Bool {
        isProjectionScreen(node) || isNamed(node, "meetingProjector")
    }

    /// The screen, its frame or the picture on it (where Harold appears).
    static func isProjectionScreen(_ node: SCNNode) -> Bool {
        isNamed(node, "meetingScreen") || isNamed(node, "meetingProjection")
    }

    private static func isNamed(_ node: SCNNode, _ name: String) -> Bool {
        var n: SCNNode? = node
        while let current = n {
            if current.name == name { return true }
            n = current.parent
        }
        return false
    }

    /// A tap on the screen or the projector: THE BOX again.
    static func replayFromEquipment() {
        guard canReplay else {
            diag("reveal.replayRefused", ["enabled": isEnabled, "running": isRunning, "shown": StoryBeats.shared.has(shownBeat),
                                          "room": room?.parent != nil])
            return
        }
        startReplayFromRoom()
    }

    /// (The old 8-second HUD offer; nothing sets it any more -- kept so the
    /// HUD's contextual check stays as it was.)
    static func replayTarget() -> TapNavigationController.HUDTarget? {
        guard canReplay, CACurrentMediaTime() < replayOfferedUntil else { return nil }
        return TapNavigationController.HUDTarget(label: "REPLAY", kind: "boxReplay") { startReplayFromRoom() }
    }

    /// Oct 12 (the room remembers): during a REPLAY, the HUD's centre button
    /// is SKIP -- the show ends at once and the room goes back to how the
    /// meeting left it. (Never offered on the meeting's own presentation.)
    static func skipTarget() -> TapNavigationController.HUDTarget? {
        guard isRunning, runIsReplay else { return nil }
        return TapNavigationController.HUDTarget(label: "SKIP", kind: "boxSkip") { stop(reason: "skip") }
    }

    /// A replay over (finished, skipped or exited) in a meeting that is long
    /// done: the room empties again, as it is on every visit since the meeting.
    private static func emptyRoomIfMeetingOver() {
        guard runIsReplay else { return }
        runIsReplay = false
        emptyRoom(reason: "replayOver")
    }

    /// Oct 12 (playtest): the meeting is over and the player has walked out of
    /// the room (the same floor build -- before, the cast stayed seated until
    /// the floor was rebuilt): the attendees have gone back to their desks.
    static func playerLeftRoom() {
        // (Oct 12, pass 3: a replay asked for -- or staged -- but never begun goes too.)
        if replayArmed, !isRunning, TheBoxMeeting.state == .completed {
            if staging { cancelStaging(reason: "leftRoom") }
            replayArmed = false
        }
        guard isEnabled, !isRunning, !replayArmed, TheBoxMeeting.state == .completed, ConferenceAudition.isInstalled,
              ConferenceAudition.members.first?.model.action(forKey: "castLeaves") == nil else { return }   // (not already leaving)
        emptyRoom(reason: "meetingOverPlayerLeft")
    }

    /// The projector goes off and the cast leave (a short fade): the room is
    /// empty and quiet, its own chairs back round the table.
    private static func emptyRoom(reason: String) {
        guard let room else { return }
        // (Oct 12, pass 3) In the chair: behind the curtain -- the view fades
        // out, the cast leave and the projector goes off unseen, it fades in.
        if ConferenceMeeting.phase == .seated, let curtain = makeCurtain(title: false) {
            curtainBusy = true
            curtain.runAction(.fadeIn(duration: 0.45))
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if gen == generation, !isRunning, !replayArmed, self.room === room {
                    ConferenceMeeting.setProjector(on: false, animated: false)
                    ConferenceAudition.dismissCast(from: room)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { if curtainNode === curtain { liftCurtain(0.6) } }
            diag("reveal.roomEmptied", ["reason": reason, "curtain": true])
            return
        }
        ConferenceMeeting.setProjector(on: false, animated: true)
        for m in ConferenceAudition.members {
            m.model.runAction(.fadeOut(duration: 0.8), forKey: "castLeaves")
        }
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard gen == generation, !isRunning, !replayArmed, self.room === room else {
                if replayArmed, self.room === room, !isRunning {
                    // (a replay asked for while they were leaving: they go all the
                    // same -- the replay seats them again behind the curtain)
                    ConferenceAudition.dismissCast(from: room)
                } else {
                    for m in ConferenceAudition.members { m.model.removeAction(forKey: "castLeaves"); m.model.opacity = 1 }
                }
                return
            }
            ConferenceAudition.dismissCast(from: room)
        }
        diag("reveal.roomEmptied", ["reason": reason])
    }

    // MARK: Oct 12 (pass 3) -- the curtain: a fade to black in front of the player's eyes
    //
    // A REPLAY is staged like revisiting a scene, never a pop-in: the view
    // fades to black, "THE BOX -- Presentation Replay" comes up, the cast are
    // put in their places while nothing can be seen, and the room fades back
    // in with everyone seated; THE BOX begins a moment later. When a replay
    // ends (or is skipped) with the player in their chair, the same curtain
    // covers the cast leaving and the projector going off. (The table's
    // "tap the screen" card of the previous pass is gone.)

    private static weak var curtainNode: SCNNode?
    private static var staging = false              // a replay is being set up behind the curtain
    private static var stageToken = 0
    private static var curtainBusy = false          // a curtain transition is under way

    /// A black card (and, if asked, the replay title) filling the player's
    /// view, just in front of the lens; transparent to start with.
    private static func makeCurtain(title: Bool) -> SCNNode? {
        guard let cameraNode = ConferenceMeeting.controller?.cameraNode, let lens = cameraNode.camera else { return nil }
        curtainNode?.removeFromParentNode()
        let d = Float(max(lens.zNear * 3, 0.06))
        let bounds = ConferenceMeeting.controller?.hudSceneView?.bounds.size ?? CGSize(width: 390, height: 844)
        let aspect = Float(max(0.2, bounds.width / max(1, bounds.height)))
        let t = Float(tan(lens.fieldOfView * .pi / 360))
        let halfW: Float, halfH: Float
        if lens.projectionDirection == .horizontal { halfW = d * t; halfH = halfW / aspect } else { halfH = d * t; halfW = halfH * aspect }
        let root = SCNNode()
        root.name = "revealCurtain"
        func card(_ w: Float, _ h: Float, _ contents: Any, order: Int) -> SCNNode {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = contents
            m.readsFromDepthBuffer = false
            m.writesToDepthBuffer = false
            let n = SCNNode(geometry: SCNPlane(width: CGFloat(w), height: CGFloat(h)))
            n.geometry?.materials = [m]
            n.position = SCNVector3(0, 0, -d)
            n.renderingOrder = order
            n.castsShadow = false
            return n
        }
        root.addChildNode(card(halfW * 3, halfH * 3, UIColor.black, order: 9000))
        if title {
            let w = halfW * 1.7
            let words = card(w, w * Float(RevealSlides.replayTitle.size.height / RevealSlides.replayTitle.size.width),
                             RevealSlides.replayTitle, order: 9001)
            words.name = "revealCurtainTitle"
            words.opacity = 0
            root.addChildNode(words)
        }
        root.opacity = 0
        cameraNode.addChildNode(root)
        curtainNode = root
        return root
    }

    /// Fades the curtain away and removes it.
    private static func liftCurtain(_ seconds: Double) {
        guard let node = curtainNode else { curtainBusy = false; return }
        node.removeAllActions()
        node.runAction(.sequence([.fadeOut(duration: seconds), .removeFromParentNode()]))
        curtainNode = nil
        curtainBusy = false
    }

    /// The cast all in their places (no one arriving, no one leaving).
    private static var castAssembled: Bool {
        ConferenceAudition.isInstalled && !TheBoxMeeting.arriving
            && ConferenceAudition.members.allSatisfy { ConferenceAudition.room.isPresent($0.id) && $0.model.action(forKey: "castLeaves") == nil }
    }

    /// REPLAY, seated, with the room empty: fade out, seat everyone, fade in, begin.
    private static func stageReplay() {
        guard let curtain = makeCurtain(title: true) else {
            // (no camera to hang it on -- as before: seat them and begin)
            ConferenceMeeting.installCastForReplay()
            ConferenceAudition.room.hold(4)
            scheduleBegin(after: 3.2, trigger: "replayUnstaged")
            return
        }
        staging = true
        curtainBusy = true
        stageToken += 1
        let token = stageToken
        diag("reveal.replay.staging", [:])
        curtain.runAction(.fadeIn(duration: 0.5))
        curtain.childNode(withName: "revealCurtainTitle", recursively: false)?
            .runAction(.sequence([.wait(duration: 0.55), .fadeIn(duration: 0.35), .wait(duration: 1.2), .fadeOut(duration: 0.3)]))
        func at(_ t: Double, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { if token == stageToken { work() } }
        }
        at(0.6) {
            ConferenceMeeting.installCastForReplay()                // everyone in their places, unseen
            ConferenceAudition.room.hold(6)                         // ...and quiet until THE BOX begins
        }
        at(2.45) { liftCurtain(0.6) }                               // the room again, everyone seated
        at(3.4) {
            staging = false
            guard ConferenceMeeting.phase == .seated, !isRunning, replayArmed else {
                diag("reveal.replay.stagedNotSeated", [:])         // (stood up meanwhile: it begins when they sit)
                return
            }
            begin(trigger: "replayStaged")
        }
    }

    /// Staging interrupted (left the floor or the room): no curtain left behind.
    private static func cancelStaging(reason: String) {
        stageToken += 1
        staging = false
        liftCurtain(0.25)
        diag("reveal.replay.stagingCancelled", ["reason": reason])
    }

    /// THE BOX after the player's 3.2 s look at the room (the meeting's own way in).
    private static func scheduleBegin(after seconds: Double, trigger: String) {
        let gen = generation
        beginToken += 1                                             // (Oct 12: replaces any start still pending)
        let token = beginToken
        pendingBegin = true
        diag("reveal.startScheduled", ["trigger": trigger, "in": seconds, "token": token, "state": TheBoxMeeting.state.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if token == beginToken { pendingBegin = false }
            guard token == beginToken, gen == generation, !isRunning, ConferenceMeeting.phase == .seated else {
                diag("reveal.startStale", ["trigger": trigger, "token": token, "current": beginToken,
                                           "running": isRunning, "seated": ConferenceMeeting.phase == .seated])
                return
            }
            begin(trigger: trigger)
        }
    }

    // MARK: Oct 12 (resume-state fix) -- starts that can't outlive their moment

    /// A start scheduled by sitting down is only good while the player stays
    /// in that chair: standing, leaving the room or the floor cancels it.
    private static var beginToken = 0
    private static var pendingBegin = false
    /// Every presentation run gets a number (diagnostics: overlapping runs).
    private static var runSerial = 0

    private static func cancelPendingBegin(_ reason: String) {
        guard pendingBegin else { return }
        beginToken += 1
        pendingBegin = false
        diag("reveal.startCancelled", ["reason": reason])
    }

    /// ConferenceMeeting.standUp.
    static func playerStood() { cancelPendingBegin("stood") }

    /// Oct 12 (resume-state fix): a tap on the screen or the projector, seated
    /// or standing in the room. Returns true when the tap is used up here.
    ///  - THE BOX has been shown and nothing is playing: REPLAY (as before).
    ///  - The meeting is assembled and hasn't been shown (e.g. a resumed save
    ///    where the cast have just sat down): the tap STARTS it -- seated, now;
    ///    standing, the player is taken to their chair and it starts there.
    ///  - Otherwise (the cast still arriving, nothing to show, a show already
    ///    on): seated, the tap is swallowed -- a tap on the screen never stands
    ///    the player up; standing, it is an ordinary tap.
    static func equipmentTapped(seated: Bool) -> Bool {
        if canReplay {
            diag("reveal.screenTap", ["action": "replay", "seated": seated])
            startReplayFromRoom()
            return true
        }
        let state = TheBoxMeeting.state
        if isEnabled, !isRunning, !staging, !curtainBusy, !playedThisBuild, state == .assembled, !TheBoxMeeting.arriving {
            diag("reveal.screenTap", ["action": "startMeeting", "seated": seated])
            if seated {
                ConferenceAudition.room.hold(1.2)
                scheduleBegin(after: 0.8, trigger: "screenTap")
            } else {
                ConferenceMeeting.sitForReplay()                    // to the chair; sitting starts it (playerSat)
            }
            return true
        }
        diag("reveal.screenTap", ["action": "none", "seated": seated, "state": state.rawValue, "arriving": TheBoxMeeting.arriving,
                                  "running": isRunning, "played": playedThisBuild])
        return seated
    }

    // MARK: Oct 12 -- interruptions during THE BOX
    //
    // The presentation keeps its own timeline (nothing is cut or moved). It has
    // two quiet stretches where nobody is presenting: the turntable (THE BOX
    // revealed, Harold asleep in his box) and Harold's own tune. There a tap
    // on a character lets them speak up (MeetingConversation); elsewhere the
    // show has the floor. Harold, on the screen, answers a tap on the
    // turntable -- once -- by waking with a start and a blush (the product
    // switching itself on early); any other time the presenter gives the
    // player a look.

    private static var showStartedAt: CFTimeInterval = 0
    private static var haroldInterrupted = false
    private static var endingStarted = false

    private static var quietStretch: Int? {
        guard isRunning else { return nil }
        let t = CACurrentMediaTime() - showStartedAt
        if t >= 20.0 && t < 26.5 { return 0 }                       // the turntable
        if t >= Show.musicQuietFrom, !endingStarted, stage?.brain.isBusy == true { return 1 }   // Harold's tune
        return nil
    }

    static var interjectionWindowOpen: Bool { quietStretch != nil }

    /// A tap on the screen while THE BOX is on.
    static func haroldTapped() {
        guard isRunning, let stage else { return }
        let telephone = ConferenceAudition.actorID("AuditionTelephone")
        if quietStretch == 0, !haroldInterrupted {
            haroldInterrupted = true
            let gen = generation
            stage.brain.command(.wake)                               // somebody's poking the screen!
            stage.brain.command(.surprise)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if gen == generation { stage.brain.command(.blush) } }
            if let telephone {
                ConferenceAudition.room.cue(telephone, .look(-1, 1.8))   // the presenter: was that you?
                ConferenceAudition.room.cue(telephone, .react(3), delay: 0.3)
            }
            if let mail = ConferenceAudition.actorID("AuditionMailbox") { ConferenceAudition.room.cue(mail, .laugh, delay: 1.6) }
            diag("reveal.harold.interrupted", [:])
        } else if let telephone {
            ConferenceAudition.room.cue(telephone, .look(-1, 1.2))       // not now
            ConferenceAudition.room.cue(telephone, .react(3), delay: 0.2)
            diag("reveal.harold.tapped", ["quiet": quietStretch ?? -1])
        }
    }

    private static func startReplayFromRoom() {
        replayOfferedUntil = 0
        diag("reveal.replayFromRoom", ["seated": ConferenceMeeting.phase == .seated])
        replay()                                                    // back to the start; plays when seated
        if ConferenceMeeting.phase == .standing { ConferenceMeeting.sitForReplay() }
    }

    // MARK: Lifecycle (ConferenceMeeting)

    static func installFloor(room: SCNNode, layout: MeetingLayout) {
        cancelPendingBegin("floorBuilt")                            // (Oct 12, resume-state fix)
        if emergencyActive { emergencyToken += 1; emergencyActive = false }   // (Oct 13: gone with the old room)
        diag("reveal.floorState", ["state": TheBoxMeeting.state.rawValue, "shown": StoryBeats.shared.has(shownBeat),
                                   "replayArmed": replayArmed, "running": isRunning])
        cleanup(visible: false)
        if staging { cancelStaging(reason: "floorBuilt") }
        curtainNode?.removeFromParentNode()
        curtainNode = nil
        curtainBusy = false
        self.room = room
        self.layout = layout
        playedThisBuild = false
        guard isEnabled else { return }
        // (Oct 12, the room remembers: once THE BOX's meeting is over, the
        // projector is off on every later visit -- the room is quiet.)
        if !replayLaunch && TheBoxMeeting.state == .completed {
            ConferenceMeeting.setProjector(on: false, animated: false)
        }
    }

    static func playerSat() {
        guard isEnabled, !isRunning, !playedThisBuild, !staging else { return }
        // Oct 12 (event history): the meeting decides -- everyone has arrived and
        // THE BOX hasn't been completed yet (TheBoxMeeting); or an explicit replay.
        guard replayLaunch || replayArmed || TheBoxMeeting.showMayStart else { return }
        // Oct 12 (pass 3): a replay into an empty (or emptying) room is staged
        // behind the curtain -- never a pop-in.
        // (Oct 12, resume-state fix: and ANY replay of a meeting that is over --
        // even with the cast still in the room from it -- the same way.)
        if replayArmed && (!castAssembled || TheBoxMeeting.state == .completed) { stageReplay(); return }
        // (Oct 12, pass 3: nobody starts a remark of their own in the settle --
        // it used to run on into the presenter's opening bang.)
        ConferenceAudition.room.hold(3.4)
        scheduleBegin(after: 3.2, trigger: replayArmed ? "replaySat" : "playerSat")   // the room has a look at the newcomer, settles
    }

    static func replay() {
        guard !emergencyActive else { diag("reveal.replayRefused", ["reason": "emergency"]); return }   // (Oct 13)
        diag("reveal.replay", ["running": isRunning])
        stop(reason: "replay")
        replayArmed = true
        playedThisBuild = false
        ConferenceMeeting.setProjector(on: false, animated: false)
        // Oct 12 (pass 3): a cast already there (or arriving) is simply all
        // seated now; an empty room is staged when the player is in the chair.
        if ConferenceAudition.isInstalled && ConferenceAudition.members.first?.model.action(forKey: "castLeaves") == nil {
            ConferenceMeeting.installCastForReplay()
        }
        if ConferenceMeeting.phase == .seated { playerSat() }
    }

    static func stop(reason: String) {
        if reason != "replay" { cancelPendingBegin(reason) }        // (Oct 12, resume-state fix)
        if staging && reason != "replay" { cancelStaging(reason: reason) }
        guard isRunning else { return }
        diag("reveal.stopped", ["reason": reason])
        cleanup(visible: reason != "leftFloor")
        // Oct 12: a replay skipped or walked out of -- the room as the meeting left it.
        if reason != "replay" && reason != "leftFloor" { emptyRoomIfMeetingOver() }
    }

    /// Any drag or pinch while seated: the camera is the player's again, in the chair.
    static func playerTookCamera() {
        guard isRunning, !cameraYielded else { return }
        cameraYielded = true
        if dollied { returnCameraToSeat(); return }               // a cut back to the chair, the player's view
        guard let cameraNode = ConferenceMeeting.controller?.cameraNode else { return }
        // A framing move in flight: stop it where it is, and give the lens back.
        if !cameraNode.animationKeys.isEmpty {
            let shown = cameraNode.presentation
            cameraNode.removeAllAnimations()
            cameraNode.eulerAngles = shown.eulerAngles
        }
        cameraNode.camera?.removeAllAnimations()
        if !CameraMagnifier.shared.isZoomed { cameraNode.camera?.fieldOfView = ConferenceMeeting.seatedFOV }
    }

    /// STAND, or a touch, while the camera is up the table: straight back to the chair (a cut).
    static func returnCameraToSeat() {
        guard let cameraNode = ConferenceMeeting.controller?.cameraNode else { return }
        if isRunning {
            cameraYielded = true                                    // (STAND / a touch: the show stops steering)
            if !dollied, !cameraNode.animationKeys.isEmpty {
                let shown = cameraNode.presentation
                cameraNode.removeAllAnimations()
                cameraNode.eulerAngles = shown.eulerAngles
            }
        }
        guard dollied, let seatLocal else { return }
        dollied = false
        cameraNode.removeAllAnimations()
        cameraNode.camera?.removeAllAnimations()
        cameraNode.position = seatLocal
        let yaw = ConferenceMeeting.seatedViewYaw ?? Double(cameraNode.eulerAngles.y)
        cameraNode.eulerAngles = SCNVector3(Float(ConferenceMeeting.seatedPitch), Float(yaw), 0)
        cameraNode.camera?.fieldOfView = ConferenceMeeting.seatedFOV
        diag("reveal.camera.backToSeat", [:])
    }

    private static func cleanup(visible: Bool) {
        generation += 1
        let wasRunning = isRunning
        isRunning = false
        projector?.stop()
        projector = nil
        stage?.brain.shutdown(reason: "revealEnded")
        stage = nil
        if wasRunning { ConferenceMeeting.controller?.objectWillChange.send() }   // (Oct 12: SKIP off the HUD)
        soundAnchor?.removeFromParentNode()
        ConferenceAudition.room.setShow(false, focus: nil)
        if wasRunning {
            putEndCardOnScreen()
            if StoryBeats.shared.has(shownBeat) {
                if visible { ConferenceMeeting.setProjector(on: true, animated: false) }
            } else {
                ConferenceMeeting.setProjector(on: false, animated: false)
                playedThisBuild = false                             // stopped before THE BOX appeared: as if never begun
            }
        }
        if visible {
            if lightsDown { ConferenceMeeting.restoreLights(duration: 1.2) }
            if wasRunning && !endedNormally {
                if dollied { returnCameraToSeat() } else { frame(.room, duration: 1.6) }
            }
        }
        dollied = false
        lightsDown = false
        endedNormally = false
    }

    // MARK: The show

    private static func begin(trigger: String) {
        guard let room, let projection = ConferenceMeeting.projection, let material = projection.geometry?.firstMaterial else {
            diag("reveal.notReady", [:]); return
        }
        let stage = RevealStage()
        guard let device = ConferenceMeeting.controller?.hudSceneView?.device,
              let projector = RevealProjector(device: device, scene: stage.scene, camera: stage.camera) else {
            diag("reveal.noMetal", [:]); return                     // (nothing started; the room carries on)
        }
        // Oct 12 (playtest): a REPLAY is a run of a meeting that is already over
        // (SKIP; nothing recorded; the room empties after). A run asked for
        // while the meeting is still on (assembled) IS the meeting's show.
        let asked = replayArmed || replayLaunch
        runIsReplay = asked && TheBoxMeeting.state == .completed
        runCompletesMeeting = !asked || TheBoxMeeting.state == .assembled
        isRunning = true
        showStartedAt = CACurrentMediaTime()                        // (Oct 12: the quiet stretches)
        haroldInterrupted = false
        endingStarted = false
        ConferenceMeeting.controller?.objectWillChange.send()       // (Oct 12: SKIP on the HUD, replays)
        playedThisBuild = true
        replayArmed = false
        // (Oct 12: a show seen in part before starts from a dark screen, like any other.)
        ConferenceMeeting.setProjector(on: false, animated: false)
        cameraYielded = false
        dollied = false
        seatLocal = ConferenceMeeting.controller?.cameraNode.position
        generation += 1
        let gen = generation
        self.stage = stage
        self.projector = projector
        material.diffuse.contents = projector.texture
        material.diffuse.mipFilter = .none                          // a live picture has no mipmaps
        // Oct 12 (washout fix): the picture is opaque, whatever alpha the renderer leaves
        // in the texture -- never blended with the white sheet behind it.
        material.blendMode = .replace
        material.transparency = 1
        diag("reveal.screenMaterial", ["lighting": material.lightingModel.rawValue, "emission": "\(String(describing: material.emission.contents))",
                                       "projectionOpacity": Double(projection.opacity),
                                       "beamOff": UserDefaults.standard.bool(forKey: "HallwaysNoProjectorBeam")])
        material.diffuse.contentsTransform = UserDefaults.standard.bool(forKey: "HallwaysRevealFlipY")
            ? SCNMatrix4Translate(SCNMatrix4MakeScale(1, -1, 1), 0, 1, 0) : SCNMatrix4Identity
        projector.start()
        _ = EmergencySound.alarm                                    // (Oct 13: rendered now, not at the moment it's needed)
        // Make every slide now (not mid-dolly).
        _ = [RevealSlides.titleA, RevealSlides.titleB, RevealSlides.endCard, RevealSlides.demo1, RevealSlides.demo2,
             RevealSlides.demo3, RevealSlides.thankYou, RevealSlides.commandJump, RevealSlides.commandJumpLoud,
             RevealSlides.obedienceTick, RevealSlides.curiosityTick, RevealSlides.standBy, RevealSlides.doNotPress]
        // Harold's music comes from the projector (the room's sound system).
        if let unit = room.childNode(withName: "meetingProjector", recursively: false) {
            let sound = SCNNode()
            sound.name = "revealSound"
            sound.position = SCNVector3(0, 2.45, 0)
            unit.addChildNode(sound)
            soundAnchor = sound
            stage.brain.setAudioAnchor(sound)
        }
        let p = projection.worldPosition
        let focus = SIMD3<Float>(p.x, p.y, p.z)
        runSerial += 1
        diag("reveal.begin", ["run": runSerial, "trigger": trigger, "replay": runIsReplay, "completes": runCompletesMeeting,
                              "state": TheBoxMeeting.state.rawValue, "texture": "\(projector.texture.width)x\(projector.texture.height)"])

        func at(_ t: Double, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { if gen == generation { work() } }
        }
        func cue(_ who: String, _ c: AuditionCue, _ t: Double) {
            at(t) { if let id = ConferenceAudition.actorID(who) { ConferenceAudition.room.cue(id, c) } }
        }
        func id(_ who: String) -> Int { ConferenceAudition.actorID(who) ?? -1 }
        let tel = "AuditionTelephone", mail = "AuditionMailbox", stove = "AuditionStove", tv = "AuditionTelevision"
        let cam = "AuditionCamera", vm = "AuditionViewMaster2"     // (Oct 19, Stage A: the Rolodex retired)
        let brain = stage.brain

        // ---- ORDER
        at(0.0) { ConferenceAudition.room.setShow(true, focus: focus) }  // the room's own chatter stops
        cue(tel, .slam, 0.4)
        cue(mail, .laugh, 2.2)                                       // one last eager chirp...
        cue(tel, .look(id(mail), 2.2), 2.9)
        cue(mail, .react(3), 3.5)                                    // ...and a sheepish look back
        at(4.5) { frame(.presenter) }
        cue(tel, .speak(0), 5.3)                                     // a few proud words
        cue(tel, .speak(2), 6.8)
        // ---- DARK / TITLE
        at(8.6) {
            ConferenceMeeting.dimLights(animated: true, level: 0.32, duration: 2.4)
            lightsDown = true
        }
        cue(tel, .gesture(3.4), 9.4)                                 // the receiver raised toward the screen
        at(10.0) {
            stage.showSlide(RevealSlides.titleA, fade: 0)          // the first thing the lamp throws up
            ConferenceMeeting.setProjector(on: true, animated: true)
        }
        at(11.6) { frame(.stage, duration: 3.6) }                     // up the table, behind the presenter
        at(13.2) { stage.showSlide(RevealSlides.titleB, fade: 0.8) }
        cue(tel, .speak(1), 14.6)
        cue(tel, .gesture(3.6), 14.7)
        cue(tv, .fiddle, 17.2)                                       // a better picture, please
        // ---- PRODUCT
        at(19.6) {
            stage.hideSlide(fade: 1.4)
            stage.turntable(seconds: 8.5)
            _ = StoryBeats.shared.record(shownBeat, at: Date())     // from here on, it has been shown
        }
        cue(vm, .react(2), 22.0)
        at(26.6) { brain.command(.wake) }                            // the product switches itself on: eyes open, to the room
        cue(mail, .react(4), 27.2)
        // ---- 1. OBEDIENCE (Oct 12 playtest rework -- was "Wake." spoken at a
        // sleeping box: invisible cause, tiny effect). Now the command is
        // printed on the screen; Harold plainly refuses it twice (turns his
        // back; walks off); the presenter BANGS the table and he flies back
        // and JUMPS -- enormously, terrified. OBEDIENCE, ticked.
        at(28.6) { stage.caption(RevealSlides.demo1, hold: 2.4) }
        cue(tel, .speak(0), 29.2)                                    // the order
        cue(tel, .gesture(1.6), 29.3)
        at(29.4) { stage.command(RevealSlides.commandJump, hold: 1.5) }
        at(30.4) { stage.turnAway() }                                // he turns his back
        cue(mail, .laugh, 31.1)
        cue(tel, .speak(2), 32.0)                                    // louder
        cue(tel, .gesture(1.6), 32.1)
        at(32.1) { stage.command(RevealSlides.commandJumpLoud, hold: 1.3) }
        at(32.9) { stage.wanderOff() }                               // ...and walks off the stage
        cue(tv, .react(1), 33.3)
        cue(tel, .slam, 34.0)                                        // BANG
        at(34.15) { stage.frightJump(); brain.command(.surprise) }   // back like a shot -- and JUMPS
        at(35.3) { stage.command(RevealSlides.obedienceTick, hold: 1.6) }
        cue(stove, .react(3), 35.6)                                  // unimpressed
        cue(vm, .react(4), 35.9)
        // ---- 2. CURIOSITY (Oct 12 playtest rework -- was a tiny firefly, too
        // small to see from the table). A big red button: DO NOT PRESS. He
        // looks at it, at us, at it -- and presses it. The picture dies
        // (PLEASE STAND BY); when it returns he is back on his pedestal, the
        // button is gone, and he is very embarrassed. CURIOSITY, ticked.
        at(37.2) { stage.caption(RevealSlides.demo2, hold: 2.2); stage.showButton() }
        at(37.9) { brain.setLookNode(stage.buttonTop) }              // he's seen it
        at(38.7) { stage.edgeTowardButton() }
        at(40.0) { brain.setLookNode(nil) }                          // a look at the audience: may I?
        cue(tel, .react(3), 40.2)
        at(40.9) { brain.setLookNode(stage.buttonTop) }
        at(41.4) { stage.pressButton() }                             // he may not
        at(41.85) { stage.powerCut() }                               // the stage lights die...
        at(42.3) { stage.showSlide(RevealSlides.standBy, fade: 0) }  // ...and the picture
        cue(tel, .look(-2, 2.2), 42.3)                               // the presenter stares at his dead screen
        cue(tel, .react(1), 42.5)
        cue(tv, .fiddle, 42.6)                                       // the Television blames his reception
        cue(mail, .laugh, 43.0)
        cue(stove, .react(3), 43.4)
        at(44.0) { stage.restoreAfterButton(); brain.setLookNode(nil) }
        at(44.3) { stage.hideSlide(fade: 0.25) }
        at(44.8) { brain.command(.blush) }                           // ...innocent
        at(45.3) { stage.command(RevealSlides.curiosityTick, hold: 1.5) }
        cue(cam, .react(1), 45.5)                                   // (Oct 19: was the retired Rolodex's)
        // ---- 3. CREATIVITY (Harold's own first tune) -- as it was, 7.8 s earlier.
        at(46.8) { stage.caption(RevealSlides.demo3) }
        cue(tel, .speak(1), 47.8)                                    // "Perform."
        cue(tel, .gesture(2.0), 47.9)
        at(49.2) { brain.command(.compose(seed: 105, style: .bounce)) }
        cue(cam, .snap, 49.8)                                        // ...and the Camera takes a picture. Now.
        cue(tel, .look(id(cam), 1.9), 50.2)
        cue(tel, .react(3), 50.4)
        cue(mail, .react(4), 56.2)
        cue(tv, .fiddle, 60.2)
        cue(vm, .react(2), 63.2)
        at(54.2) { waitForTheBow(gen: gen, deadline: CACurrentMediaTime() + 45) }
        // Oct 13 (experiment): THE EMERGENCY -- six seconds into Harold's own
        // tune, the first time the meeting's own presentation plays. Never on
        // a replay; once per story. `-HallwaysNoEmergency YES` turns it off.
        if runCompletesMeeting, !runIsReplay, emergencyEnabled, !StoryBeats.shared.has(emergencyBeat) {
            at(Self.emergencyAt) { emergency(gen: gen) }
        }
    }

    /// Polls the projected Harold: once his piece (and bow) is over, the ending.
    private static func waitForTheBow(gen: Int, deadline: CFTimeInterval) {
        guard gen == generation, let stage else { return }
        if stage.brain.isBusy && CACurrentMediaTime() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitForTheBow(gen: gen, deadline: deadline) }
            return
        }
        ending(gen: gen, stage: stage)
    }

    private static func ending(gen: Int, stage: RevealStage) {
        func at(_ t: Double, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { if gen == generation { work() } }
        }
        func cue(_ who: String, _ c: AuditionCue, _ t: Double) {
            at(t) { if let id = ConferenceAudition.actorID(who) { ConferenceAudition.room.cue(id, c) } }
        }
        diag("reveal.ending", [:])
        endingStarted = true
        let brain = stage.brain
        // (his own bow, then a breath)
        at(2.6) { stage.caption(RevealSlides.thankYou, hold: 3.2) }
        cue("AuditionTelephone", .speak(1), 3.0)                    // the corporation's closing words
        cue("AuditionTelephone", .gesture(2.4), 3.1)
        // ---- THE CHOICE: to the lens, to YOU
        at(6.2) { stage.toTheLens(seconds: 1.8) }
        at(8.4) { brain.command(.bow) }                               // a little bow -- to you
        cue("AuditionMailbox", .react(4), 8.8)
        at(11.2) { stage.backFromTheLens(seconds: 1.4) }
        // ...and he brings on the end card himself.
        at(12.8) { stage.pushOnEndCard(seconds: 2.8) }
        cue("AuditionTelephone", .look(-2, 2.0), 13.0)             // the presenter stares at his own screen:
        cue("AuditionTelephone", .react(1), 13.4)                   // ...that wasn't in the script
        at(16.0) { stage.peekAndGo() }
        at(18.6) {
            stage.showSlide(RevealSlides.endCard, fade: 1.2)
            // Oct 12 (playtest): THE BOX is over once its end card is up -- the
            // meeting is recorded as done HERE (it used to be 13 s later, after the
            // lights came up: a player who got up and left at the end card never
            // had it recorded, and found everyone still there on the next visit).
            diag("reveal.completionPoint", ["counts": runCompletesMeeting, "replay": runIsReplay])
            if runCompletesMeeting { TheBoxMeeting.presentationCompleted() }
        }
        // The room.
        cue("AuditionStove", .speak(0), 19.6)                       // grudging...
        cue("AuditionStove", .react(0), 20.8)                       // ...a nod
        cue("AuditionMailbox", .laugh, 21.6)
        cue("AuditionViewMaster2", .react(4), 22.0)
        cue("AuditionCamera", .react(2), 22.4)                      // (Oct 19: was the retired Rolodex's)
        cue("AuditionTelevision", .react(2), 22.8)
        cue("AuditionTelephone", .speak(2), 23.6)                   // the final proud flourish
        cue("AuditionTelephone", .gesture(3.4), 23.7)
        at(23.6) { frame(.presenter, duration: 2.8) }               // back down the table to the chair
        at(28.0) {
            ConferenceMeeting.restoreLights(duration: 2.6)          // the lights come up
            lightsDown = false
            frame(.room, duration: 2.4)
            ConferenceAudition.room.setShow(false, focus: nil)      // everyone themselves again
        }
        at(31.5) {
            diag("reveal.finished", [:])
            // Oct 12: the meeting is over (persisted) -- unless this was a replay outside the meeting.
            if runCompletesMeeting { TheBoxMeeting.presentationCompleted() }   // (already recorded at the end card)
            endedNormally = true
            cleanup(visible: true)
            // Oct 12: a replay over -- the room empty again. (Resume-state fix:
            // and the meeting's OWN presentation too, once it has completed it --
            // the same fade and clear-up, instead of everyone staying seated
            // with the end card up until the player walked out.)
            diag("reveal.finishedCleanup", ["run": runSerial, "replay": runIsReplay, "state": TheBoxMeeting.state.rawValue])
            if runIsReplay { emptyRoomIfMeetingOver() }
            else if TheBoxMeeting.state == .completed { emptyRoom(reason: "meetingFinished") }
        }
    }

    // MARK: The screen when the show is over (a still card; nothing rendering)

    private static func putEndCardOnScreen() {
        guard let m = ConferenceMeeting.projection?.geometry?.firstMaterial else { return }
        m.diffuse.contents = RevealSlides.endCard
        m.diffuse.contentsTransform = SCNMatrix4Identity
        m.diffuse.mipFilter = .linear
        m.blendMode = .alpha                                         // (as built)
    }

    // MARK: Presentation framing (seated only; never fights the player)

    /// Oct 12: show times other code needs (seconds from the show's start).
    private enum Show {
        static let musicQuietFrom: Double = 50.5                    // Harold's tune is under way
    }

    enum Framing { case room, presenter, stage }

    static func frame(_ f: Framing, duration: Double = 2.4) {
        guard isRunning || f == .room, !cameraYielded, ConferenceMeeting.phase == .seated,
              let controller = ConferenceMeeting.controller, let projection = ConferenceMeeting.projection else { return }
        if CameraMagnifier.shared.isZoomed { return }
        let cameraNode = controller.cameraNode
        let sc = projection.worldPosition
        let seatWorld: SCNVector3 = {
            guard let seatLocal else { return cameraNode.presentation.worldPosition }
            return cameraNode.parent?.convertPosition(seatLocal, to: nil) ?? seatLocal
        }()
        var eye = seatWorld
        var yaw = ConferenceMeeting.seatedViewYaw ?? Double(cameraNode.eulerAngles.y)
        var pitch = ConferenceMeeting.seatedPitch
        var fov: CGFloat = ConferenceMeeting.seatedFOV
        let bounds = controller.hudSceneView?.bounds.size ?? CGSize(width: 390, height: 844)
        let aspect = Float(max(0.3, bounds.width / max(1, bounds.height)))
        func aim(at target: SCNVector3, width: Float) {
            let dx = target.x - eye.x, dy = target.y - eye.y, dz = target.z - eye.z
            let flat = max(0.5, sqrtf(dx * dx + dz * dz))
            yaw = Double(atan2f(-dx, -dz))
            pitch = Double(atan2f(dy, flat))
            let hfov = 2 * atanf((width / 2) / flat)
            let vfov = 2 * atanf(tanf(hfov / 2) / aspect) * 180 / .pi
            fov = CGFloat(max(28, min(70, vfov)))
        }
        switch f {
        case .room:
            break
        case .presenter:
            // From the chair: the Telephone at the head of the table and the screen above him.
            aim(at: SCNVector3(sc.x, sc.y - 0.45, sc.z + 1.6), width: 3.3)
        case .stage:
            // Up the table toward the screen, just behind the presenter, at a standing eye height:
            // the screen a little wider than the phone (Harold big), the Telephone below it.
            var toRoom = SIMD2<Float>(seatWorld.x - sc.x, seatWorld.z - sc.z)
            toRoom = simd_length(toRoom) > 0.01 ? simd_normalize(toRoom) : SIMD2<Float>(0, 1)
            let back: Float = 4.0
            eye = SCNVector3(sc.x + toRoom.x * back, ConferenceRoom.floorTopY + 1.55, sc.z + toRoom.y * back)
            aim(at: sc, width: 2.4 / 1.08)
        }
        let local = cameraNode.parent?.convertPosition(eye, from: nil) ?? eye
        dollied = f == .stage
        // the short way round
        let current = Double(cameraNode.eulerAngles.y)
        var d = (yaw - current).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cameraNode.position = local
        cameraNode.eulerAngles = SCNVector3(Float(pitch), Float(current + d), 0)
        cameraNode.camera?.fieldOfView = fov
        SCNTransaction.commit()
        diag("reveal.frame", ["framing": "\(f)"])
    }
}

// MARK: - The picture: Harold's stage rendered into the screen's texture

/// An SCNRenderer drawing a scene into a Metal texture (~30 fps) for a
/// material. The texture is sRGB, so SceneKit reads back exactly the colours
/// that were rendered (no wash-out).
@MainActor
final class RevealProjector {
    let texture: MTLTexture
    private let depth: MTLTexture
    private let queue: MTLCommandQueue
    private let renderer: SCNRenderer
    private var link: CADisplayLink?
    private let ticker = RevealTicker()
    private var frames = 0
    private let inFlight = DispatchSemaphore(value: 2)      // never more than two frames queued on the GPU

    init?(device: MTLDevice, scene: SCNScene, camera: SCNNode, width: Int = 1280, height: Int = 720) {
        let colour = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        colour.usage = [.renderTarget, .shaderRead]
        colour.storageMode = .private
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: colour), let depth = device.makeTexture(descriptor: depthDescriptor),
              let queue = device.makeCommandQueue() else { return nil }
        self.texture = texture
        self.depth = depth
        self.queue = queue
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        renderer.isPlaying = true
    }

    func start() {
        guard link == nil else { return }
        ticker.onTick = { [weak self] in self?.renderFrame() }
        let link = CADisplayLink(target: ticker, selector: #selector(RevealTicker.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
        renderFrame()
    }

    func stop() {
        link?.invalidate()
        link = nil
        ticker.onTick = nil
        diag("reveal.projector.stopped", ["frames": frames])
    }

    private func renderFrame() {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let buffer = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let gate = inFlight
        buffer.addCompletedHandler { _ in gate.signal() }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        renderer.render(atTime: CACurrentMediaTime(), viewport: CGRect(x: 0, y: 0, width: texture.width, height: texture.height),
                        commandBuffer: buffer, passDescriptor: pass)
        buffer.commit()
        frames += 1
        if frames == 1 || frames == 90 { diag("reveal.projector.frame", ["n": frames]) }
    }
}

/// CADisplayLink's target (it needs an NSObject).
final class RevealTicker: NSObject {
    var onTick: (() -> Void)?
    @objc func tick() { MainActor.assumeIsolated { onTick?() } }
}

// MARK: - The stage: Harold's model and face, lit like a product launch

@MainActor
final class RevealStage {
    let scene = SCNScene()
    let camera = SCNNode()
    let rig = SCNNode()             // Harold's place on the stage: he flies by moving this
    let turn = SCNNode()            // the turntable (yaw only)
    let brain: BlackBoxBrain
    let firefly = SCNNode()
    private let slide = SCNNode()   // full-frame slide in front of the lens
    private let captionNode = SCNNode()
    private let card = SCNNode()    // the end card he pushes on
    // Oct 12 (playtest rework of demonstrations 1 and 2)
    private let commandNode = SCNNode()   // a lower-third card: the order, or the tick
    private let buttonRig = SCNNode()     // the big red button on its plinth (demo 2)
    let buttonTop = SCNNode()             // its dome: what he looks at, what he presses
    private var savedLights: [(SCNLight, CGFloat)] = []
    private static let lensFOV: CGFloat = 26
    private static let pedestalTop: Float = 0

    init() {
        let root = scene.rootNode
        scene.background.contents = UIColor.black
        // A soft glow behind, a dark glossy floor, a low pedestal.
        let back = SCNPlane(width: 5, height: 3)
        back.materials = [RevealStage.flat(RevealStage.glow(size: 512, inner: UIColor(red: 0.13, green: 0.16, blue: 0.26, alpha: 1),
                                                            outer: UIColor(red: 0.01, green: 0.01, blue: 0.02, alpha: 1)))]
        let backNode = SCNNode(geometry: back)
        backNode.position = SCNVector3(0, 0.6, -1.4)
        root.addChildNode(backNode)
        let floor = SCNPlane(width: 6, height: 6)
        let fm = SCNMaterial()
        fm.lightingModel = .physicallyBased
        fm.diffuse.contents = UIColor(white: 0.05, alpha: 1)
        fm.roughness.contents = 0.3
        fm.metalness.contents = 0.0
        floor.materials = [fm]
        let floorNode = SCNNode(geometry: floor)
        floorNode.eulerAngles.x = -.pi / 2
        floorNode.position.y = -0.03
        root.addChildNode(floorNode)
        let pedestal = SCNCylinder(radius: 0.25, height: 0.03)
        let pm = SCNMaterial()
        pm.lightingModel = .physicallyBased
        pm.diffuse.contents = UIColor(white: 0.12, alpha: 1)
        pm.roughness.contents = 0.25
        pm.metalness.contents = 0.6
        pedestal.materials = [pm]
        let pedestalNode = SCNNode(geometry: pedestal)
        pedestalNode.position.y = -0.015
        root.addChildNode(pedestalNode)

        // Light: a warm key, two cool rims (a black cube on black needs its edges), a little from above.
        func spot(_ pos: SCNVector3, _ color: UIColor, _ intensity: CGFloat, angle: CGFloat) {
            let l = SCNLight()
            l.type = .spot
            l.color = color
            l.intensity = intensity
            l.spotInnerAngle = angle * 0.5
            l.spotOuterAngle = angle
            let n = SCNNode()
            n.light = l
            n.position = pos
            n.look(at: SCNVector3(0, 0.15, 0))
            root.addChildNode(n)
        }
        spot(SCNVector3(0.75, 1.15, 1.05), UIColor(red: 1, green: 0.9, blue: 0.78, alpha: 1), 1500, angle: 40)
        spot(SCNVector3(-0.9, 0.7, -0.9), UIColor(red: 0.55, green: 0.7, blue: 1, alpha: 1), 1800, angle: 36)
        spot(SCNVector3(0.95, 0.55, -0.85), UIColor(red: 0.6, green: 0.75, blue: 1, alpha: 1), 1200, angle: 36)
        spot(SCNVector3(0, 1.6, 0.25), UIColor(white: 0.95, alpha: 1), 600, angle: 34)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 60
        let an = SCNNode()
        an.light = ambient
        root.addChildNode(an)

        // The lens: Harold large.
        let lens = SCNCamera()
        lens.fieldOfView = Self.lensFOV
        lens.zNear = 0.02
        lens.zFar = 20
        camera.camera = lens
        camera.position = SCNVector3(0, 0.2, 1.05)
        camera.look(at: SCNVector3(0, 0.17, 0))
        root.addChildNode(camera)

        // Harold: the real body and face, his own (presentation) life.
        brain = BlackBoxBrain(body: BlackBox.makeBody(), face: BlackBoxFace.build(), cellSize: 1, officeCells: [], presentation: true)
        root.addChildNode(rig)
        rig.addChildNode(turn)
        turn.eulerAngles.y = -2.0 * .pi - 0.6
        turn.addChildNode(brain.root)
        brain.setCamera(camera)
        brain.start()

        // A firefly.
        let fly = SCNSphere(radius: 0.008)
        fly.materials = [RevealStage.flat(UIColor(red: 1, green: 0.93, blue: 0.55, alpha: 1))]
        firefly.geometry = fly
        let glowLight = SCNLight()
        glowLight.type = .omni
        glowLight.color = UIColor(red: 1, green: 0.85, blue: 0.45, alpha: 1)
        glowLight.intensity = 80
        glowLight.attenuationStartDistance = 0.02
        glowLight.attenuationEndDistance = 0.4
        firefly.light = glowLight
        let halo = SCNNode(geometry: SCNPlane(width: 0.06, height: 0.06))
        let hm = RevealStage.flat(RevealStage.glow(size: 64, inner: UIColor(red: 1, green: 0.9, blue: 0.5, alpha: 0.9),
                                                   outer: UIColor(red: 1, green: 0.9, blue: 0.5, alpha: 0)))
        hm.blendMode = .add
        hm.writesToDepthBuffer = false
        halo.geometry?.materials = [hm]
        halo.constraints = [SCNBillboardConstraint()]
        firefly.addChildNode(halo)
        firefly.opacity = 0
        firefly.position = SCNVector3(-0.7, 0.35, 0.2)
        root.addChildNode(firefly)

        // The slides: full frame, in front of the lens, over everything.
        let h = 2 * 0.3 * tan(Self.lensFOV / 2 * .pi / 180)
        func overlay(_ node: SCNNode, distance: Float, order: Int) {
            node.geometry = SCNPlane(width: h * 16 / 9 * CGFloat(distance / 0.3), height: h * CGFloat(distance / 0.3))
            let m = RevealStage.flat(UIColor.clear)
            m.readsFromDepthBuffer = false
            m.writesToDepthBuffer = false
            m.isDoubleSided = false
            node.geometry?.materials = [m]
            node.position = SCNVector3(0, 0, -distance)
            node.renderingOrder = order
            node.opacity = 0
            camera.addChildNode(node)
        }
        overlay(slide, distance: 0.32, order: 100)
        overlay(captionNode, distance: 0.30, order: 101)
        overlay(commandNode, distance: 0.29, order: 102)

        // Oct 12: DO NOT PRESS (demonstration 2) -- off stage until wanted.
        let plinthMaterial = SCNMaterial()
        plinthMaterial.lightingModel = .physicallyBased
        plinthMaterial.diffuse.contents = UIColor(white: 0.22, alpha: 1)
        plinthMaterial.roughness.contents = 0.45
        plinthMaterial.metalness.contents = 0.3
        let plinth = SCNNode(geometry: SCNBox(width: 0.15, height: 0.13, length: 0.11, chamferRadius: 0.006))
        plinth.geometry?.materials = [plinthMaterial]
        plinth.position = SCNVector3(0, 0.065, 0)
        buttonRig.addChildNode(plinth)
        let label = SCNNode(geometry: SCNPlane(width: 0.14, height: 0.075))
        let lm = RevealStage.flat(RevealSlides.doNotPress)
        label.geometry?.materials = [lm]
        label.position = SCNVector3(0, 0.068, 0.0556)
        buttonRig.addChildNode(label)
        let dome = SCNSphere(radius: 0.045)
        let dm = SCNMaterial()
        dm.lightingModel = .physicallyBased
        dm.diffuse.contents = UIColor(red: 0.85, green: 0.06, blue: 0.05, alpha: 1)
        dm.emission.contents = UIColor(red: 0.45, green: 0.02, blue: 0.02, alpha: 1)   // it glows a little: it wants pressing
        dm.roughness.contents = 0.25
        dome.materials = [dm]
        buttonTop.geometry = dome
        buttonTop.scale = SCNVector3(1, 0.55, 1)
        buttonTop.position = SCNVector3(0, 0.13, 0)
        buttonRig.addChildNode(buttonTop)
        buttonRig.position = SCNVector3(-0.31, 0, 0.1)
        buttonRig.isHidden = true
        root.addChildNode(buttonRig)

        // The end card (a board on the stage, beside Harold's pedestal).
        card.geometry = SCNPlane(width: 0.64, height: 0.36)
        card.geometry?.materials = [RevealStage.flat(RevealSlides.endCard)]
        card.position = SCNVector3(1.4, 0.17, 0.05)
        card.isHidden = true
        root.addChildNode(card)
    }

    // MARK: Slides

    func showSlide(_ image: UIImage, fade: Double) {
        slide.geometry?.firstMaterial?.diffuse.contents = image
        slide.removeAllActions()
        slide.runAction(.fadeOpacity(to: 1, duration: fade))
    }

    func hideSlide(fade: Double) {
        slide.removeAllActions()
        slide.runAction(.fadeOpacity(to: 0, duration: fade))
    }

    /// A corporate caption band across the top of the picture for a while.
    func caption(_ image: UIImage, hold: Double = 3.6) {
        captionNode.removeAllActions()
        captionNode.geometry?.firstMaterial?.diffuse.contents = image
        captionNode.opacity = 0
        captionNode.runAction(.sequence([.fadeOpacity(to: 1, duration: 0.5), .wait(duration: hold), .fadeOpacity(to: 0, duration: 0.7)]))
    }

    /// Oct 12: a lower-third card (the order on screen; the tick after).
    func command(_ image: UIImage, hold: Double) {
        commandNode.removeAllActions()
        commandNode.geometry?.firstMaterial?.diffuse.contents = image
        commandNode.opacity = 0
        commandNode.runAction(.sequence([.fadeOpacity(to: 1, duration: 0.15), .wait(duration: hold), .fadeOpacity(to: 0, duration: 0.35)]))
    }

    // MARK: Oct 12 -- demonstration 1 (OBEDIENCE): he refuses, then JUMPS

    /// He turns his back on the order.
    func turnAway() {
        turn.removeAllActions()
        let away = SCNAction.rotateTo(x: 0, y: .pi, z: 0, duration: 0.45, usesShortestUnitArc: true)
        away.timingMode = .easeInEaseOut
        turn.runAction(away)
    }

    /// ...and walks off the stage, right, in little hops (back still turned).
    func wanderOff() {
        rig.removeAllActions()
        let hop = SCNAction.sequence([.moveBy(x: 0, y: 0.03, z: 0, duration: 0.11), .moveBy(x: 0, y: -0.03, z: 0, duration: 0.11)])
        let away = SCNAction.move(to: SCNVector3(0.78, 0, 0), duration: 0.9)
        away.timingMode = .easeIn
        rig.runAction(.group([away, .repeat(hop, count: 4)]))
    }

    /// BANG: back like a shot, spun round to face us, and a terrified jump --
    /// out of the top of the picture and down again.
    func frightJump() {
        turn.removeAllActions()
        turn.eulerAngles.y = 0
        rig.removeAllActions()
        let fly = SCNAction.move(to: SCNVector3(0, 0.24, 0), duration: 0.3)
        fly.timingMode = .easeOut
        let drop = SCNAction.move(to: SCNVector3(0, 0, 0), duration: 0.3)
        drop.timingMode = .easeIn
        rig.runAction(.sequence([fly, drop, .move(to: SCNVector3(0, 0.035, 0), duration: 0.1),
                                 .move(to: SCNVector3(0, 0, 0), duration: 0.1)]))
    }

    // MARK: Oct 12 -- demonstration 2 (CURIOSITY): DO NOT PRESS

    func showButton() {
        buttonRig.removeAllActions()
        buttonRig.isHidden = false
        buttonRig.scale = SCNVector3(0.01, 0.01, 0.01)
        let pop = SCNAction.scale(to: 1, duration: 0.35)
        pop.timingMode = .easeOut
        buttonRig.runAction(pop)
    }

    /// A little closer to it.
    func edgeTowardButton() {
        rig.removeAllActions()
        let go = SCNAction.move(to: SCNVector3(-0.07, 0, 0.03), duration: 1.0)
        go.timingMode = .easeInEaseOut
        rig.runAction(go)
    }

    /// He hops up and lands on it. The dome goes down.
    func pressButton() {
        rig.removeAllActions()
        let up = SCNAction.move(to: SCNVector3(-0.2, 0.28, 0.08), duration: 0.22)
        up.timingMode = .easeOut
        let land = SCNAction.move(to: SCNVector3(-0.31, 0.12, 0.1), duration: 0.16)
        land.timingMode = .easeIn
        rig.runAction(.sequence([up, land]))
        buttonTop.runAction(.sequence([.wait(duration: 0.36), .move(to: SCNVector3(0, 0.112, 0), duration: 0.05)]))
    }

    /// The stage lights die (the picture goes to STAND BY just after).
    func powerCut() {
        savedLights = []
        scene.rootNode.enumerateHierarchy { n, _ in
            guard let l = n.light, n !== self.firefly else { return }
            self.savedLights.append((l, l.intensity))
            l.intensity = 0
        }
    }

    /// While the picture is down: lights back, Harold on his pedestal facing
    /// us, the button gone -- nothing happened.
    func restoreAfterButton() {
        for (l, i) in savedLights { l.intensity = i }
        savedLights = []
        buttonRig.removeAllActions()
        buttonRig.isHidden = true
        rig.removeAllActions()
        rig.position = SCNVector3(0, 0, 0)
        turn.removeAllActions()
        turn.eulerAngles.y = 0
    }

    // MARK: Harold's moves (the rig; his face and body are the brain's)

    /// Turns slowly through several angles and stops facing the audience.
    func turntable(seconds: Double) {
        let spin = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: seconds, usesShortestUnitArc: false)
        spin.timingMode = .easeInEaseOut
        turn.runAction(spin)
    }

    func levitate() {
        rig.removeAllActions()
        let up = SCNAction.move(to: SCNVector3(0, 0.07, 0), duration: 1.4)
        up.timingMode = .easeInEaseOut
        rig.runAction(up)
        hover(on: true)
    }

    private func hover(on: Bool) {
        turn.removeAction(forKey: "hover")
        guard on else { turn.runAction(.move(to: SCNVector3(0, 0, 0), duration: 0.3)); return }
        let a = SCNAction.move(to: SCNVector3(0, 0.012, 0), duration: 0.9)
        a.timingMode = .easeInEaseOut
        let b = SCNAction.move(to: SCNVector3(0, -0.006, 0), duration: 0.9)
        b.timingMode = .easeInEaseOut
        turn.runAction(.repeatForever(.sequence([a, b])), forKey: "hover")
    }

    /// He drifts after the firefly, a little behind it (left, then right).
    func followFirefly(seconds: Double) {
        let s = seconds
        rig.removeAllActions()
        let a = SCNAction.move(to: SCNVector3(-0.2, 0.07, 0.05), duration: s * 0.45)
        a.timingMode = .easeInEaseOut
        let b = SCNAction.move(to: SCNVector3(0.16, 0.06, 0.08), duration: s * 0.55)
        b.timingMode = .easeInEaseOut
        rig.runAction(.sequence([a, b]))
    }

    func landOnPedestal() {
        rig.removeAllActions()
        let down = SCNAction.move(to: SCNVector3(0, 0, 0), duration: 1.6)
        down.timingMode = .easeInEaseOut
        rig.runAction(down)
        hover(on: false)
    }

    /// Up and forward until his face fills the picture: he looks at YOU.
    func toTheLens(seconds: Double) {
        rig.removeAllActions()
        let go = SCNAction.move(to: SCNVector3(0, 0.03, 0.62), duration: seconds)
        go.timingMode = .easeInEaseOut
        rig.runAction(go)
        hover(on: true)
    }

    func backFromTheLens(seconds: Double) {
        rig.removeAllActions()
        let go = SCNAction.move(to: SCNVector3(0.75, 0.06, 0.0), duration: seconds)      // off into the wings, right
        go.timingMode = .easeIn
        rig.runAction(go)
    }

    /// He brings the end card on from the wings, pushing it from behind its right edge.
    func pushOnEndCard(seconds: Double) {
        card.isHidden = false
        card.position = SCNVector3(1.15, 0.17, 0.05)
        rig.removeAllActions()
        rig.position = SCNVector3(1.15 + 0.32 + 0.16, 0.04, 0.0)
        let cardIn = SCNAction.move(to: SCNVector3(0, 0.17, 0.05), duration: seconds)
        cardIn.timingMode = .easeOut
        card.runAction(cardIn)
        let pushIn = SCNAction.move(to: SCNVector3(0.32 + 0.16, 0.04, 0.0), duration: seconds)
        pushIn.timingMode = .easeOut
        rig.runAction(pushIn)
    }

    /// A peek round the card's edge at the audience -- and he's gone behind it.
    func peekAndGo() {
        let peek = SCNAction.move(to: SCNVector3(0.44, 0.06, -0.05), duration: 0.6)
        peek.timingMode = .easeInEaseOut
        let hold = SCNAction.wait(duration: 1.0)
        let hide = SCNAction.move(to: SCNVector3(0.12, 0.04, -0.2), duration: 0.5)
        hide.timingMode = .easeIn
        rig.runAction(.sequence([peek, hold, hide]))
    }

    // MARK: The firefly

    func fireflyWander() {
        brain.setLookNode(firefly)
        firefly.removeAllActions()
        firefly.runAction(.sequence([
            .fadeOpacity(to: 1, duration: 0.5),
            .move(to: SCNVector3(-0.3, 0.33, 0.22), duration: 1.4),
            .move(to: SCNVector3(0.0, 0.34, 0.3), duration: 1.0),
            .move(to: SCNVector3(-0.32, 0.3, 0.15), duration: 1.4),
            .move(to: SCNVector3(-0.25, 0.26, 0.25), duration: 1.0),
            .move(to: SCNVector3(0.3, 0.3, 0.2), duration: 2.0),
            .move(to: SCNVector3(0.22, 0.22, 0.32), duration: 1.0),
        ]))
    }

    func fireflyDart() {
        firefly.removeAllActions()
        let at = rig.presentation.position
        let dart = SCNAction.move(to: SCNVector3(at.x, at.y + 0.17, at.z + 0.2), duration: 0.18)
        let back = SCNAction.move(to: SCNVector3(at.x - 0.12, min(0.34, at.y + 0.3), at.z + 0.1), duration: 0.5)
        back.timingMode = .easeOut
        firefly.runAction(.sequence([dart, back]))
    }

    /// It settles on his head (it rides with him now).
    func fireflyPerch() {
        firefly.removeAllActions()
        let worldNow = firefly.presentation.worldPosition
        firefly.removeFromParentNode()
        firefly.position = rig.convertPosition(worldNow, from: nil)
        rig.addChildNode(firefly)
        let land = SCNAction.move(to: SCNVector3(0.03, BlackBoxLayout.topY + 0.012, 0.03), duration: 0.8)
        land.timingMode = .easeOut
        firefly.runAction(land)
    }

    func fireflyLiftOff() {
        let worldNow = firefly.presentation.worldPosition
        firefly.removeAllActions()
        firefly.removeFromParentNode()
        firefly.position = worldNow
        scene.rootNode.addChildNode(firefly)
        brain.setLookNode(nil)                                      // eyes back on the audience
        // Up and round in slow loops above the stage while he plays, then away.
        let loop = SCNAction.sequence([
            .move(to: SCNVector3(-0.25, 0.36, 0.0), duration: 1.6),
            .move(to: SCNVector3(0.0, 0.38, -0.2), duration: 1.6),
            .move(to: SCNVector3(0.25, 0.36, 0.0), duration: 1.6),
            .move(to: SCNVector3(0.0, 0.33, 0.2), duration: 1.6),
        ])
        firefly.runAction(.sequence([.repeat(loop, count: 4), .group([.move(to: SCNVector3(-0.9, 0.6, 0.0), duration: 1.5),
                                                                      .fadeOpacity(to: 0, duration: 1.5)])]))
    }

    // MARK: Helpers

    static func flat(_ contents: Any) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = contents
        return m
    }

    static func glow(size: Int, inner: UIColor, outer: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            let colors = [inner.cgColor, outer.cgColor] as CFArray
            guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let c = CGPoint(x: size / 2, y: size / 2)
            ctx.cgContext.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) * 0.5,
                                             options: [.drawsAfterEndLocation])
        }
    }
}

// MARK: - The slides (plain images; text kept to the middle 80% -- the picture may run past the phone's edges)

@MainActor
enum RevealSlides {
    static let size = CGSize(width: 1600, height: 900)
    static let cream = UIColor(red: 0.97, green: 0.94, blue: 0.86, alpha: 1)
    static let gold = UIColor(red: 0.90, green: 0.74, blue: 0.40, alpha: 1)

    static let titleA = card(lines: [("THE HALLWAYS CORPORATION", "AvenirNext-DemiBold", 84, 8, cream, 360),
                                     ("Proudly Presents", "Georgia-Italic", 78, 1, gold, 500)])
    static let titleB = card(lines: [("THE HALLWAYS CORPORATION", "AvenirNext-DemiBold", 56, 6, cream.withAlphaComponent(0.85), 150),
                                     ("Proudly Presents", "Georgia-Italic", 54, 1, gold, 238),
                                     ("THE BOX", "AvenirNext-Heavy", 250, 12, cream, 450),
                                     ("The World\u{2019}s Most Human-Like", "AvenirNext-DemiBold", 70, 1, cream, 652),
                                     ("AI Companion Yet!", "AvenirNext-DemiBold", 70, 1, cream, 742)])
    static let endCard = card(lines: [("THE BOX", "AvenirNext-Heavy", 250, 12, cream, 400),
                                      ("From The Hallways Corporation", "Georgia-Italic", 80, 1, gold, 600)])
    static let demo1 = band("Demonstration 1: Obedience")
    static let demo2 = band("Demonstration 2: Curiosity")
    static let demo3 = band("Demonstration 3: Creativity")
    // Oct 12 (playtest rework of demonstrations 1 and 2): what the screen says.
    static let commandJump = lowerThird("\u{201C}JUMP.\u{201D}", color: cream, size: 120)
    static let commandJumpLoud = lowerThird("\u{201C}JUMP!!\u{201D}", color: UIColor(red: 1, green: 0.42, blue: 0.32, alpha: 1), size: 160)
    static let obedienceTick = lowerThird("OBEDIENCE  \u{2713}", color: gold, size: 104)
    static let curiosityTick = lowerThird("CURIOSITY  \u{2713}", color: gold, size: 104)
    static let standBy = colourBars("PLEASE STAND BY")
    /// Oct 12 (pass 3): over the black while a replay is set up (transparent elsewhere).
    static let replayTitle: UIImage = {
        let size = CGSize(width: 1600, height: 420)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            for (text, f, colour, y) in [("THE BOX", RevealSlides.font("AvenirNext-Heavy", 200), cream, 150.0),
                                         ("Presentation Replay", RevealSlides.font("Georgia-Italic", 86), gold, 330.0)] {
                let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: colour, .kern: 4]
                let m = (text as NSString).size(withAttributes: attrs)
                (text as NSString).draw(at: CGPoint(x: (size.width - m.width) / 2, y: CGFloat(y) - m.height / 2), withAttributes: attrs)
            }
        }
    }()
    static let doNotPress: UIImage = {
        let size = CGSize(width: 560, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor(red: 0.98, green: 0.80, blue: 0.10, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.08, alpha: 1).setFill()
            for k in stride(from: -300, to: 560, by: 60) {              // hazard stripes, top and bottom
                for y: CGFloat in [0, 262] {
                    let p = UIBezierPath()
                    p.move(to: CGPoint(x: CGFloat(k), y: y + 38)); p.addLine(to: CGPoint(x: CGFloat(k) + 30, y: y + 38))
                    p.addLine(to: CGPoint(x: CGFloat(k) + 68, y: y)); p.addLine(to: CGPoint(x: CGFloat(k) + 38, y: y)); p.close()
                    p.fill()
                }
            }
            for (text, y) in [("DO NOT", 112.0), ("PRESS", 200.0)] {
                let attrs: [NSAttributedString.Key: Any] = [.font: RevealSlides.font("AvenirNext-Heavy", 92), .foregroundColor: UIColor(white: 0.08, alpha: 1)]
                let m = (text as NSString).size(withAttributes: attrs)
                (text as NSString).draw(at: CGPoint(x: (size.width - m.width) / 2, y: CGFloat(y) - m.height / 2), withAttributes: attrs)
            }
        }
    }()
    static let thankYou = band("Thank you.")

    private static func font(_ name: String, _ size: CGFloat) -> UIFont {
        UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size, weight: .bold)
    }

    private static func draw(_ text: String, font f: UIFont, kern: CGFloat, color: UIColor, centreY: CGFloat, maxWidth: CGFloat) {
        var font = f
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        var m = (text as NSString).size(withAttributes: attrs)
        if m.width > maxWidth {
            font = font.withSize(font.pointSize * maxWidth / m.width)
            attrs[.font] = font
            m = (text as NSString).size(withAttributes: attrs)
        }
        (text as NSString).draw(at: CGPoint(x: (size.width - m.width) / 2 + kern / 2, y: centreY - m.height / 2), withAttributes: attrs)
    }

    /// A full slide: deep navy, a fine frame, the lines.
    private static func card(lines: [(String, String, CGFloat, CGFloat, UIColor, CGFloat)]) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(red: 0.10, green: 0.13, blue: 0.22, alpha: 1).cgColor,
                          UIColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 1).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                cg.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: size.width * 0.62,
                                      options: [.drawsAfterEndLocation])
            }
            cg.setStrokeColor(cream.withAlphaComponent(0.22).cgColor)
            cg.setLineWidth(3)
            cg.stroke(CGRect(x: 170, y: 60, width: size.width - 340, height: size.height - 120))
            for l in lines {
                draw(l.0, font: font(l.1, l.2), kern: l.3, color: l.4, centreY: l.5, maxWidth: size.width * 0.74)
            }
        }
    }

    /// Oct 12: a lower-third card (transparent elsewhere).
    private static func lowerThird(_ text: String, color: UIColor, size points: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let rect = CGRect(x: 0, y: size.height - 250, width: size.width, height: 190)
            ctx.cgContext.setFillColor(UIColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 0.85).cgColor)
            ctx.cgContext.fill(rect)
            draw(text, font: font("AvenirNext-Heavy", points), kern: 4, color: color, centreY: rect.midY, maxWidth: size.width * 0.8)
        }
    }

    /// Oct 12: the picture has died -- colour bars, a black box, the words.
    private static func colourBars(_ text: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let bars: [UIColor] = [UIColor(white: 0.75, alpha: 1), UIColor(red: 0.75, green: 0.75, blue: 0, alpha: 1),
                                   UIColor(red: 0, green: 0.75, blue: 0.75, alpha: 1), UIColor(red: 0, green: 0.75, blue: 0, alpha: 1),
                                   UIColor(red: 0.75, green: 0, blue: 0.75, alpha: 1), UIColor(red: 0.75, green: 0, blue: 0, alpha: 1),
                                   UIColor(red: 0, green: 0, blue: 0.75, alpha: 1)]
            let w = size.width / CGFloat(bars.count)
            for (i, c) in bars.enumerated() {
                c.setFill()
                cg.fill(CGRect(x: CGFloat(i) * w, y: 0, width: w + 1, height: size.height))
            }
            UIColor.black.setFill()
            let box = CGRect(x: 250, y: 330, width: size.width - 500, height: 240)
            cg.fill(box)
            draw(text, font: font("AvenirNext-Heavy", 120), kern: 6, color: .white, centreY: box.midY, maxWidth: box.width - 80)
        }
    }

    /// A caption band across the top (transparent elsewhere).
    private static func band(_ text: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let rect = CGRect(x: 0, y: 40, width: size.width, height: 130)
            ctx.cgContext.setFillColor(UIColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 0.82).cgColor)
            ctx.cgContext.fill(rect)
            ctx.cgContext.setFillColor(gold.cgColor)
            ctx.cgContext.fill(CGRect(x: size.width / 2 - 140, y: rect.maxY - 6, width: 280, height: 3))
            draw(text, font: font("AvenirNext-DemiBold", 74), kern: 1, color: cream, centreY: rect.midY - 4, maxWidth: size.width * 0.74)
        }
    }
}

// MARK: - TheBoxMeeting (Oct 12, event history)
// (Kept in this file -- not in TheBoxMeeting.swift -- because Xcode did not pick up
// that new file into the Hallways target: "Cannot find TheBoxMeeting in scope".)

/// Oct 12 -- THE BOX MEETING: the first storyline told the event-driven way.
///
/// The conference room is a LOCATION; what it shows is decided from the
/// player's history (StoryBeats -- the same persisted, record-once facts the
/// building already uses) each time Floor 3 is built or the player comes near:
///
///   not invited  (no `invite.staffMeeting.sent`)     the room is empty
///   available    (invited; nobody has come yet)      empty -- until the player
///                                                    approaches: then the cast
///                                                    arrive ONE BY ONE and take
///                                                    their places
///   gathering    (`meeting.theBox.gathering`)        arrivals under way; if
///                                                    the floor is left part way
///                                                    they are all seated on return
///   assembled    (`meeting.theBox.gathered`)         everyone in place; THE BOX
///                                                    starts when the player sits
///   completed    (`meeting.theBox.done`)             the room is empty again;
///                                                    REPLAY still shows THE BOX
///
/// The invitation itself: BuildingDispatch, 30 s after the player first sits
/// at their office computer (`computer.firstUse`). Nothing here reads a clock
/// time. Reading the invitation is not required.
///
/// Only with THE BOX's cast (BoxReveal.isEnabled: the audition, round five).
/// The classic meeting (`-HallwaysMeetingClassic YES`) and earlier audition
/// rounds keep their own behaviour. `-HallwaysReplayBoxReveal YES` (testing)
/// seats everyone at once.
enum TheBoxMeeting {
    static let gatheringBeat = "meeting.theBox.gathering"
    static let gatheredBeat = "meeting.theBox.gathered"
    static let doneBeat = "meeting.theBox.done"

    enum State: String { case notInvited, available, gathering, assembled, completed }

    static var state: State {
        let b = StoryBeats.shared
        if b.has(doneBeat) { return .completed }
        if !b.has(BuildingDispatch.staffMeetingInvitedBeat) { return .notInvited }
        if b.has(gatheredBeat) { return .assembled }
        if b.has(gatheringBeat) { return .gathering }
        return .available
    }

    private static var testLaunch: Bool { UserDefaults.standard.bool(forKey: "HallwaysReplayBoxReveal") }

    /// May THE BOX begin now (the player has sat down)? Replays are BoxReveal's own.
    static var showMayStart: Bool {
        guard BoxReveal.isEnabled else { return true }
        return testLaunch || (state == .assembled && !arriving)
    }

    // MARK: Floor 3 build (ConferenceMeeting.installFloor, audition mode)

    enum Presence: String { case none, waiting, seated }

    /// Who should be in the room as it is built.
    static func presenceForBuild(playerCell: GridCoordinate?) -> Presence {
        generation += 1
        arriving = false
        guard BoxReveal.isEnabled else { return .seated }                // other rounds: as they were
        if testLaunch || BoxReveal.isReplayArmed { return .seated }      // (testing; a replay asked for elsewhere)
        let s = state
        let result: Presence
        switch s {
        case .notInvited, .completed:
            result = .none
        case .gathering, .assembled:
            // Left part way through the arrivals: they all got here meanwhile.
            _ = StoryBeats.shared.record(gatheredBeat, at: Date())
            result = .seated
        case .available:
            if let c = playerCell, ConferenceRoom.roomCells.contains(c) {
                // Already in the room (a relaunch there): they are simply here.
                _ = StoryBeats.shared.record(gatheringBeat, at: Date())
                _ = StoryBeats.shared.record(gatheredBeat, at: Date())
                result = .seated
            } else {
                result = .waiting
            }
        }
        diag("theBoxMeeting.build", ["state": s.rawValue, "presence": result.rawValue])
        return result
    }

    // MARK: The arrivals

    private static var generation = 0
    private(set) static var arriving = false

    /// Where the player's approach starts the gathering: the corridor outside
    /// the glass doors, the doorway, the room itself.
    private static var approachCells: Set<GridCoordinate> {
        var c = ConferenceRoom.roomCells
        c.insert(ConferenceRoom.doorCell)
        let d = ConferenceRoom.doorCell
        for dr in -2...2 { c.insert(GridCoordinate(row: d.row + dr, col: d.col - 1)) }
        return c
    }

    /// ConferenceMeeting.playerCellChanged.
    static func playerCellChanged(_ cell: GridCoordinate) {
        guard BoxReveal.isEnabled, !arriving, state == .available, approachCells.contains(cell) else { return }
        // Invited while this floor was already built (the invitation follows the
        // office computer -- on this same floor): the cast is put in place, unseen, now.
        if !ConferenceAudition.isInstalled { ConferenceMeeting.installCastWaiting() }
        guard ConferenceAudition.isInstalled else { return }
        beginArrivals(playerCell: cell)
    }

    /// The order they come in: the eager first, the presenter last.
    /// (Oct 19, Stage A: the Rolodex, once second in, is retired.)
    private static let order = ["AuditionMailbox", "AuditionViewMaster2", "AuditionCamera",
                                "AuditionTelevision", "AuditionStove", "AuditionTelephone"]
    static let stagger: Double = 2.4
    static let walkSpeed: Float = 1.5

    private static func beginArrivals(playerCell: GridCoordinate) {
        guard let context = GuidedJourney.context else { diag("theBoxMeeting.noContext", [:]); return }
        _ = StoryBeats.shared.record(gatheringBeat, at: Date())
        arriving = true
        let gen = generation
        let s = context.cellSize
        func center(_ c: GridCoordinate) -> SIMD2<Float> { SIMD2<Float>(Float(c.col) * s, Float(c.row) * s) }
        // Where they come from: a corridor cell a few steps from the doors,
        // on the side away from the player (never out of the player's office).
        let door = ConferenceRoom.doorCell
        let blocked = ConferenceRoom.roomCells.union(PlayerOffice.officeCells)
        var dist: [GridCoordinate: Int] = [door: 0]
        var queue = [door]
        while !queue.isEmpty {
            let c = queue.removeFirst()
            for d in Direction.allCases {
                let n = GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
                guard context.cells.contains(n), !blocked.contains(n), dist[n] == nil,
                      CharacterLead.doorAnchor(c, d, context.doors) == nil else { continue }   // (never from behind another door)
                dist[n] = dist[c]! + 1
                queue.append(n)
            }
        }
        let player = center(playerCell)
        let candidates = dist.filter { (3...5).contains($0.value) }.map(\.key)
        let spawn = candidates.max { simd_distance(center($0), player) < simd_distance(center($1), player) } ?? door
        // The way from there to the doors (cell by cell), then into the room.
        var hallway: [GridCoordinate] = [spawn]
        var here = spawn
        while here != door, let step = dist[here], step > 0 {
            guard let next = Direction.allCases.map({ GridCoordinate(row: here.row + $0.delta.row, col: here.col + $0.delta.col) })
                    .first(where: { dist[$0] == step - 1 }) else { break }
            hallway.append(next)
            here = next
        }
        let members = order.compactMap { name in ConferenceAudition.members.first { $0.name == name } }
            + ConferenceAudition.members.filter { !order.contains($0.name) }
        diag("theBoxMeeting.arrivals", ["from": "\(spawn.row),\(spawn.col)", "count": members.count])
        ConferenceMeeting.openGlassDoorsForArrivals()
        remaining = members.count
        let way = hallway.map(center)
        for (i, m) in members.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * stagger) {
                guard gen == generation, m.holder.parent != nil else { return }
                walkIn(m, hallway: way, gen: gen)
            }
        }
    }

    /// One member: from the corridor, through the doors, round the table to their place, and up into it.
    private static var remaining = 0

    private static func walkIn(_ m: ConferenceAudition.Member, hallway: [SIMD2<Float>], gen: Int) {
        let floorY = ConferenceRoom.floorTopY
        let t = ConferenceRoom.tableCenter == .zero
            ? SIMD2<Float>(10 * PlayerOffice.cellSize + ConferenceRoom.tableOffsetX, 6 * PlayerOffice.cellSize) : ConferenceRoom.tableCenter
        let s = PlayerOffice.cellSize
        let entry = SIMD2<Float>(Float(ConferenceRoom.entryCell.col) * s - 0.7, Float(ConferenceRoom.entryCell.row) * s)
        let place = m.holder.worldPosition
        let side = ConferenceRoom.tableWidth / 2 + 0.42
        let westX = t.x - side - 0.85
        let eastX = min(t.x + side + 0.65, (Float(10) + 0.5) * s - 0.3)   // (the east aisle is narrow: keep off the wall)
        let northZ = t.y - ConferenceRoom.tableLength / 2 - 0.45
        var path: [SIMD2<Float>] = hallway + [entry]
        if place.x < t.x - 0.3 {                                     // the west side: along the aisle
            path.append(SIMD2<Float>(westX, place.z))
        } else if place.x > t.x + 0.3 {                              // the east side: round the head of the table
            path += [SIMD2<Float>(westX, northZ), SIMD2<Float>(eastX, northZ), SIMD2<Float>(eastX, place.z)]
        } else {                                                     // the head (the Telephone): to the end of the table
            path += [SIMD2<Float>(westX, northZ), SIMD2<Float>(place.x, northZ - 0.05)]
        }
        // Into the model's own space (it is a child of its place).
        let holder = m.holder, model = m.model
        func local(_ p: SIMD2<Float>, y: Float = floorY) -> SCNVector3 { holder.convertPosition(SCNVector3(p.x, y, p.y), from: nil) }
        let points = path.map { local($0) }
        model.removeAllActions()
        model.position = points[0]
        model.isHidden = false
        var steps: [SCNAction] = []
        var elapsed: Double = 0
        var voiceAt: Double?
        for k in 1..<points.count {
            let a = points[k - 1], b = points[k]
            let dx = b.x - a.x, dz = b.z - a.z
            let length = sqrtf(dx * dx + dz * dz)
            guard length > 0.02 else { continue }
            let face = SCNAction.rotateTo(x: 0, y: CGFloat(atan2f(dx, dz)), z: 0, duration: 0.18, usesShortestUnitArc: true)
            steps.append(face)
            elapsed += 0.18
            // A little bob per step: these characters have no legs to speak of.
            let n = max(1, Int(length / 0.34))
            let stepTime = Double(length / walkSpeed) / Double(n)
            for j in 1...n {
                let f = Float(j) / Float(n), g = (Float(j) - 0.5) / Float(n)
                let mid = SCNVector3(a.x + dx * g, a.y + 0.035, a.z + dz * g)
                let end = SCNVector3(a.x + dx * f, a.y, a.z + dz * f)
                steps.append(.move(to: mid, duration: stepTime * 0.5))
                steps.append(.move(to: end, duration: stepTime * 0.5))
            }
            elapsed += stepTime * Double(n)
            if k == hallway.count - 1 { voiceAt = elapsed }               // at the doors
        }
        // At the doors: they open for each in turn (the player may have let them
        // close behind them); a word on the way in.
        if let at = voiceAt {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at - 0.7)) {
                guard gen == generation else { return }
                ConferenceMeeting.openGlassDoorsForArrivals()
            }
            if let clip = m.voices.first {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    guard gen == generation, model.parent != nil else { return }
                    CritterAudio.play(clip.source, on: model)
                }
            }
        }
        // Up into the place (its own origin), turning to face the table.
        let last = points[points.count - 1]
        let apex = SCNVector3((last.x) * 0.5, max(last.y, 0) + 0.42, (last.z) * 0.5)   // (over a chair back)
        let up = SCNAction.move(to: apex, duration: 0.3)
        up.timingMode = .easeOut
        let down = SCNAction.move(to: SCNVector3(0, 0, 0), duration: 0.22)
        down.timingMode = .easeIn
        steps.append(.group([.sequence([up, down]), .rotateTo(x: 0, y: 0, z: 0, duration: 0.46, usesShortestUnitArc: true)]))
        model.runAction(.sequence(steps), forKey: "theBoxArrival") {
            DispatchQueue.main.async {
                guard gen == generation else { return }
                model.position = SCNVector3(0, 0, 0)
                model.eulerAngles = SCNVector3(0, 0, 0)
                ConferenceAudition.arrived(m.id)
                diag("theBoxMeeting.arrived", ["who": m.name])
                remaining -= 1
                if remaining <= 0 { assembled() }                     // (the last one actually in, whoever it is)
            }
        }
    }

    private static func assembled() {
        arriving = false
        _ = StoryBeats.shared.record(gatheredBeat, at: Date())
        diag("theBoxMeeting.assembled", [:])
        ConferenceMeeting.closeGlassDoorsAfterArrivals()
        // Already sitting there, waiting: THE BOX begins.
        if ConferenceMeeting.phase == .seated { BoxReveal.playerSat() }
    }

    /// Floor 3 left: anything still pending belongs to the old scene.
    static func floorLeft() {
        generation += 1
        arriving = false
    }

    /// A replay (or a rebuild) overtakes arrivals still under way: they stop where
    /// they are, back in their places.
    static func cancelArrivals() {
        generation += 1
        arriving = false
        for m in ConferenceAudition.members {
            m.model.removeAction(forKey: "theBoxArrival")
            m.model.position = SCNVector3(0, 0, 0)
            m.model.eulerAngles = SCNVector3(0, 0, 0)
        }
    }

    /// THE BOX ended properly (BoxReveal): the meeting is over for good.
    static func presentationCompleted() {
        guard BoxReveal.isEnabled else { return }
        if StoryBeats.shared.record(doneBeat, at: Date()) { diag("theBoxMeeting.completed", [:]) }
    }
}


// MARK: - Oct 13 -- the emergency alarm (synthesised once, cached like every Hallways sound)

/// A building evacuation "whoop": a horn-like tone (odd harmonics) sweeping
/// up from 500 to 1100 Hz over 0.9 s, seven times, ~9 s in all, with soft
/// edges (no click, no spike) and a gentle release. Non-positional: it is
/// the building's, not a thing in the room. Its level sits well under the
/// mixer's maximum; the player's Mute silences it like any scene sound.
nonisolated enum EmergencySound {
    static let alarm: SCNAudioSource? = {
        let s = MenagerieSound.source("emergency-alarm-v1", volume: 0.5) {
            let rate = MenagerieSound.rate
            var out: [Float] = []
            let whoop: Float = 0.9, gap: Float = 0.38
            for k in 0..<7 {
                let n = Int(whoop * rate)
                var phase: Float = 0
                let last = k == 6
                for i in 0..<n {
                    let u = Float(i) / Float(n)
                    let f = 500 * pow(2.2, u)                            // 500 -> 1100 Hz
                    phase += f / rate
                    let w = 2 * Float.pi * phase
                    let tone = sin(w) + 0.35 * sin(3 * w) + 0.18 * sin(5 * w)
                    let attack = min(1, Float(i) / (0.03 * rate))
                    let release = min(1, (1 - u) / (last ? 0.35 : 0.08))
                    out.append(tone * attack * release * 0.6)
                }
                if !last { out += [Float](repeating: 0, count: Int(gap * rate)) }
            }
            return out
        }
        s?.isPositional = false
        return s
    }()
}
