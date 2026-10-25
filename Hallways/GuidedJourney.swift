//
//  GuidedJourney.swift
//  Hallways
//
//  Oct 6 -- "PLAYER FOLLOWS CHARACTER" ACROSS FLOORS (prototype: the
//  orientation trip, Administration -> Floor 3).
//
//  The relationship is a STATE of the journey, not of the character: a
//  guide (any node CharacterLead can drive), the floor it is leading from,
//  the floor it is leading to, a destination there, and a stage. While a
//  journey is on:
//
//    leading   the guide leads on the source floor (CharacterLead).
//    boarding  the player stepped into the elevator; the guide slips into
//              the cab ahead of them and stands by the doors, still on duty.
//              The ride's floor is chosen for the player (guidedAutoFloor:
//              the same real button press admission uses).
//    riding    that floor was chosen; its scene is built WITH the guide
//              standing in the cab (and without the ordinary companion).
//    guiding   the arrival doors open: the guide goes out first, turns,
//              looks back, and leads on through the destination floor.
//    goodbye   (Oct 6) the destination is the PLAYER'S OFFICE: the guide
//              holds the door, waits for them to come in, crosses to the
//              desk, switches their banker's lamp ON (he switched his own
//              off to start this), indicates the desk, lowers his flag,
//              and acknowledges them. Then he goes.
//    departing he walks back to the elevator on his own -- not waiting for
//              anyone -- and rides away. Onboarding (the prologue) is
//              complete the moment he steps out of the office; from then on
//              the cast authority keeps him home at Orientation.
//
//  In memory, plus (Oct 12) the escort's phase once it is under way on the
//  destination floor (ResumeState.escort). A relaunch before that arrival
//  resumes in Administration (prologue unfinished) and the office encounter
//  starts it again; a relaunch after it resumes on the destination floor,
//  still quiet, with the guide put back with the player (resumeEscortIfSaved)
//  -- leading on to the office, or the goodbye. The prologue completes only
//  when he leaves the office, as always.
//  Choosing a different floor ends the journey.
//
//  Oct 24 -- TINKY IS THE FIRST "FOLLOW" LESSON. The escort now runs on the
//  game's own FOLLOW (CritterFollow), not a walk of its own:
//
//    awaitingFollow  his introduction is over: he steps back, a small FOLLOW
//              sign floats over him, and he waits (one impatient nudge after
//              ~20 s, no more). Tap him: his card offers FOLLOW -- the same
//              card and FOLLOW every critter has (TinkyEscortPresentation makes
//              him one of the floor's followable presentations while he leads).
//    leading   FOLLOW chosen: "follow me!", and he leads. He owns his route and
//              destination; FOLLOW owns the player's walk (his leads no longer
//              steer WALK through guidedRoute). At every stop he goes on ONLY
//              while he is being followed (CharacterLead.mayProceed): FOLLOW
//              interrupted (a tap elsewhere, steering by hand), he waits where
//              he is, the sign comes back, and FOLLOW again carries on.
//    callingCar at the elevator he presses the hall button himself (the touch
//              residents press it with); the call stands for the player, and
//              FOLLOW walks them to the doors -- they board together (he slips
//              in as they step in, as before). Floor 3 is pressed for them; the
//              ride is the short scripted one; out first on Floor 3, and FOLLOW
//              steps the player out after him and on to the office. The goodbye
//              ends the following.
//  The end of the introduction (FOLLOW available) is the house band's cue
//  (onAvailableForFollow: no music yet -- see Music/JuanitaSings-auditions/
//  STORY-BEATS.md).
//

import SceneKit
import UIKit
import simd

enum GuidedJourney {
    enum Stage: String { case awaitingFollow, leading, callingCar, boarding, riding, guiding, goodbye, departing }

    struct Trip {
        var fromFloor: Int
        var toFloor: Int
        var stage: Stage
    }

    private(set) static var trip: Trip?
    private static weak var guide: SCNNode?
    private static var performer: FredLeadPerformer?
    private static var lead: CharacterLead?
    private static var petted = false
    /// Oct 6: the goodbye's "you're all set" moment -- a pat is welcome then.
    private static var petWindowOpen = false

    // Set by ContentView on every floor build.
    /// The lead engine's view of the current floor.
    static var context: CharacterLead.Context?
    /// The current floor's elevator doorway (centre, outward unit), world x/z.
    static var doorwayFrame: (() -> (center: SIMD2<Float>, outward: SIMD2<Float>)?)?
    /// Oct 6: run the current floor's elevator doors for a departing
    /// character (TapNavigationController.runCharacterElevatorDeparture).
    /// `boarding` is called with the doors open and must call its `done`.
    static var characterElevatorDeparture: ((_ boarding: @escaping (@escaping () -> Void) -> Void,
                                             _ completion: @escaping () -> Void) -> Bool)?

    static let guideName = "guidedJourneyGuide"

    // MARK: Oct 24 -- FOLLOW (the escort runs on the game's own FOLLOW)

    /// The guide's resident id (Tinky's): what CritterFollow follows.
    static var guideID: String { CharacterRegistry.tinkyID }
    static func isGuideID(_ id: String?) -> Bool { id == guideID }
    /// The stages in which he can be followed (and is a followable presentation).
    static let followableStages: Set<Stage> = [.awaitingFollow, .leading, .callingCar, .boarding, .riding, .guiding]
    /// He is being followed right now.
    static var isFollowed: Bool { CritterFollow.targetID == guideID }
    /// His body while he can be followed, in a scene (nil otherwise).
    static var followableBody: SCNNode? {
        guard let t = trip, followableStages.contains(t.stage), let g = guide, g.parent != nil,
              sceneRoot(of: g) === CharacterRegistry.sceneRoot else { return nil }      // (in the scene shown now)
        return g
    }
    static var followablePosition: SIMD2<Float>? {
        guard followableBody != nil else { return nil }
        return performer?.groundPosition
    }
    /// FOLLOW's walk goes to the elevator's doors (he has called the car), not to him.
    static var followGoesToElevator: Bool { trip?.stage == .callingCar }
    /// While boarding or riding, FOLLOW leaves the player to the cab.
    static var followWaitsInCab: Bool { trip?.stage == .boarding || trip?.stage == .riding }
    /// Out of the arrived cab, past the doors: the player may step out after him.
    static var guideHasLeftCab: Bool {
        guard trip?.stage == .guiding, let p = performer?.groundPosition, let frame = doorwayFrame?() else { return false }
        return simd_dot(p - frame.center, frame.outward) > 1.0                   // (clear of the doorway first)
    }
    /// The house band's cue (Oct 24 story beats): his introduction is over and FOLLOW
    /// is offered. Nothing is attached yet (no music in this pass).
    static var onAvailableForFollow: (() -> Void)?
    /// Starts his first lead (FredOfficeEncounter's "follow me") once FOLLOW is chosen.
    private static var startLeading: (() -> Void)?
    private static var nudgeToken = 0
    /// (The escort itself is ending the following: no sign, no nudge.)
    private static var endingFollow = false
    private static func endFollowing(_ reason: String) {
        guard isFollowed else { return }
        endingFollow = true
        CritterFollow.stop(reason: reason)
        endingFollow = false
    }
    static let nudgeAfter: TimeInterval = 20
    private static let signName = "tinkyFollowSign"

    /// His introduction is over: he waits to be followed (nothing saved yet -- a
    /// relaunch now simply meets him at his desk again, as before).
    static func awaitFollow(guide node: SCNNode, fromFloor: Int, toFloor: Int, startLeading start: @escaping () -> Void) {
        trip = Trip(fromFloor: fromFloor, toFloor: toFloor, stage: .awaitingFollow)
        guide = node
        performer = FredLeadPerformer(node: node)
        lead?.cancel(); lead = nil
        petted = false
        petWindowOpen = false
        startLeading = start
        log("awaitingFollow", ["from": fromFloor, "to": toFloor])
        diag("tinky.availableForFollow", ["floor": fromFloor])
        onAvailableForFollow?()
        ElevatorBoard.controller?.showBrief("Tap Tinky, then FOLLOW", seconds: 3.0)
        refreshSign()
        scheduleNudge()
    }

    /// FOLLOW was chosen on him (CritterFollow.tapped).
    static func followSelected() {
        nudgeToken += 1
        refreshSign()
        guard let t = trip else { return }
        log("followSelected", [:])
        if t.stage == .awaitingFollow, let start = startLeading {
            startLeading = nil
            start()                                       // (his "follow me!", then GuidedJourney.begin)
        }
    }

    /// FOLLOW on him ended (a tap elsewhere, steering by hand, unfollowed...): he waits;
    /// the sign comes back, and once -- after a while -- he nudges.
    static func followStopped(reason: String) {
        guard !endingFollow, let t = trip, followableStages.contains(t.stage) else { return }
        log("followStopped", ["why": reason])
        refreshSign()
        if reason != "rode away without him" { scheduleNudge() }       // (no hint on a floor he isn't on)
    }

    /// Chosen: the critter-style acknowledgement (his own "follow me" plays when he sets off).
    static func acknowledgeFollower() {
        guard let t = trip, t.stage != .awaitingFollow, let performer, !performer.isGesturing else { return }
        performer.call()
    }

    /// Once, ~20 s into a wait with nobody following: a little impatient urge and the hint again.
    private static func scheduleNudge() {
        nudgeToken += 1
        let token = nudgeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + nudgeAfter) {
            guard token == nudgeToken, let t = trip,
                  t.stage == .awaitingFollow || t.stage == .leading || t.stage == .callingCar || t.stage == .guiding,
                  !isFollowed, followableBody != nil, let performer, !performer.isGesturing,
                  let player = context?.playerPose()?.position
                    ?? FredLead.context?.playerPose()?.position else { return }
            log("nudge", [:])
            performer.urge(player: player, onward: nil) {}
            ElevatorBoard.controller?.showBrief("Tap Tinky, then FOLLOW", seconds: 2.4)
        }
    }

    /// The FOLLOW sign over him: shown while he can be followed and isn't, and he isn't busy at the car.
    static func refreshSign() {
        let show: Bool = {
            guard let t = trip, !isFollowed else { return false }
            return t.stage == .awaitingFollow || t.stage == .leading || t.stage == .callingCar || t.stage == .guiding
        }()
        guard let g = guide else { return }
        let existing = g.childNode(withName: signName, recursively: false)
        if show, existing == nil {
            g.addChildNode(makeSign(on: g))
        } else if !show, let existing {
            existing.removeFromParentNode()
        }
    }

    private static func makeSign(on g: SCNNode) -> SCNNode {
        let size = CGSize(width: 300, height: 104)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            UIColor(white: 0, alpha: 0.72).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).fill()
            UIColor(white: 1, alpha: 0.85).setStroke()
            let ring = UIBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerRadius: rect.height / 2 - 3)
            ring.lineWidth = 4
            ring.stroke()
            let text = NSAttributedString(string: "FOLLOW", attributes: [
                .font: UIFont.systemFont(ofSize: 50, weight: .heavy), .foregroundColor: UIColor.white, .kern: 2.0])
            let t = text.size()
            text.draw(at: CGPoint(x: (size.width - t.width) / 2, y: (size.height - t.height) / 2))
        }
        let plane = SCNPlane(width: 0.36, height: 0.125)
        let m = SCNMaterial()
        m.diffuse.contents = image
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let sign = SCNNode(geometry: plane)
        sign.name = signName
        let (lo, hi) = g.boundingBox
        let scale = max(0.001, g.scale.y)
        sign.scale = SCNVector3(1 / g.scale.x, 1 / scale, 1 / g.scale.z)
        sign.position = SCNVector3(0, hi.y + 0.16 / scale, (lo.z + hi.z) / 2)
        sign.constraints = [SCNBillboardConstraint()]
        sign.renderingOrder = 50
        let bob = SCNAction.sequence([.moveBy(x: 0, y: CGFloat(0.03 / scale), z: 0, duration: 0.9),
                                      .moveBy(x: 0, y: CGFloat(-0.03 / scale), z: 0, duration: 0.9)])
        bob.timingMode = .easeInEaseOut
        sign.runAction(.repeatForever(bob))
        return sign
    }

    /// At the elevator (the nook's stop released with the player there): he presses the
    /// hall button himself; the call stands for the player, and FOLLOW walks them in.
    private static func callCar() {
        guard var t = trip, t.stage == .leading, let performer, let c = ElevatorBoard.controller,
              c.elevatorFloor == t.fromFloor else { return }
        t.stage = .callingCar
        trip = t
        lead?.cancel(); lead = nil                       // (its last stop is done: no more looking round from it)
        refreshSign()
        let way = t.toFloor > t.fromFloor ? 1 : -1
        log("callingCar", ["way": way > 0 ? "up" : "down"])
        Cast.setJeff(.leading, body: guide, "calling the elevator")
        guard let b = c.hallCallButtonPoint(way), let frame = doorwayFrame?() else {
            c.callElevatorForEscort()
            return
        }
        let button = SIMD2<Float>(b.x, b.z)
        let stand = button + frame.outward * 0.6                       // in front of it, on the hall side
        let doorsHeading = FredLeadPerformer.heading(-frame.outward)
        performer.travel([stand]) {
            performer.touch(button, contact: {
                c.showResidentHallCall(way)
                c.callElevatorForEscort()
                log("callButton.pressed", [:])
            }, then: {
                performer.face(doorsHeading)
                if let p = context?.playerPose()?.position ?? FredLead.context?.playerPose()?.position {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { performer.look(at: p, 0.3) {} }
                }
            })
        }
    }

    // MARK: Begin (the source floor's lead has started)

    static func begin(guide node: SCNNode, lead sourceLead: CharacterLead, fromFloor: Int, toFloor: Int) {
        guard let performer = sourceLead.performer as? FredLeadPerformer else { return }
        trip = Trip(fromFloor: fromFloor, toFloor: toFloor, stage: .leading)
        guide = node
        self.performer = performer
        lead = sourceLead
        petted = false
        petWindowOpen = false
        startLeading = nil
        // Oct 24 (FOLLOW): on only while followed; at the nook (its final stop waits for
        // the player) he calls the car himself.
        sourceLead.mayProceed = { isFollowed }
        sourceLead.onFinalRelease = { callCar() }
        refreshSign()
        if !isFollowed { scheduleNudge() }                      // (resumed after a relaunch: not followed yet)
        log("begin", ["from": fromFloor, "to": toFloor])
        // Oct 12 (escort resume): the journey is persisted from its first step.
        ResumeState.saveEscort(.init(fromFloor: fromFloor, toFloor: toFloor, stage: Stage.leading.rawValue))
    }

    /// Oct 12 (escort resume): set at app launch, BEFORE the first floor is
    /// built: a saved escort still in its first phase, on the floor the app
    /// reopens on, is under way again in memory -- so that floor builds for
    /// it (Administration's exit isn't held, his desk is empty: he is out
    /// leading; see Cast.jeffPlacement). Its guide is put back by
    /// resumeEscortIfSaved once the floor is built.
    static func prepareForLaunch() {
        guard ResumeState.isRecording, trip == nil, let saved = ResumeState.savedEscort, saved.stage == Stage.leading.rawValue,
              let point = ResumeState.point, point.floor == saved.fromFloor,
              ResumeState.escortPending(onFloor: point.floor) != nil else { return }
        trip = Trip(fromFloor: saved.fromFloor, toFloor: saved.toFloor, stage: .leading)
        log("resume.prepared", ["from": saved.fromFloor, "to": saved.toFloor])
    }

    /// Cast: he is out leading from `floor` (his desk there is empty).
    static func leadsFrom(floor: Int) -> Bool {
        guard let t = trip else { return false }
        return t.fromFloor == floor && t.stage == .leading
    }

    /// The floor this ride goes to, chosen for the player (nil = theirs to choose).
    static func autoFloor(from floor: Int) -> Int? {
        // Oct 24: only once he is really taking the player (he called the car, they boarded
        // with him) -- a player who goes to the elevator without him chooses their own floor.
        guard let trip, trip.fromFloor == floor, trip.stage == .callingCar || trip.stage == .boarding else { return nil }
        return trip.toFloor
    }

    /// The destination floor is being built with the guide in its cab --
    /// not the ordinary companion.
    static func guidesOn(floor: Int) -> Bool {
        guard let trip else { return false }
        return trip.toFloor == floor && trip.stage == .riding
    }

    // MARK: Boarding (source floor)

    static func playerBoarding(floor: Int) {
        guard var t = trip, t.fromFloor == floor, t.stage == .leading || t.stage == .callingCar else { return }
        guard let node = guide, node.parent != nil, let performer, let frame = doorwayFrame?(),
              let root = sceneRoot(of: node) else {
            log("boarding.noGuide", [:]); end(); return
        }
        // Oct 24: he boards with the player only from beside the doors (he called the car,
        // or is waiting at them). Far off (FOLLOW was dropped on the way): the player rides
        // alone -- their own floor -- and he waits; the escort is still owed.
        if t.stage == .leading, let at = performer.groundPosition, simd_distance(at, frame.center) > 4.5 {
            log("boarding.withoutGuide", ["guideDistance": Int(simd_distance(at, frame.center))])
            return
        }
        t.stage = .boarding
        trip = t
        lead?.cancel(); lead = nil
        refreshSign()
        // Out of the office's space into the scene's, same spot on the floor.
        let world = node.presentation.worldPosition
        let heading = node.presentation.eulerAngles.y
        node.removeAllActions()
        node.removeFromParentNode()
        node.position = SCNVector3(world.x, 0, world.z)
        node.eulerAngles = SCNVector3(0, heading, 0)
        root.addChildNode(node)
        Cast.setJeff(.journeyGuide, body: node, "boarding the elevator ahead of the player")
        let (spot, faceOut) = cabSpot(frame: frame, root: root)
        let u = frame.outward, c = frame.center
        // He slips in as soon as the gap is wide enough for a tin can.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            performer.beginLeading()
            performer.travel([c + u * 0.6, c - u * 0.45, spot]) {
                performer.face(faceOut)
                log("boarding.inCab", [:])
            }
        }
        log("boarding", ["floor": floor])
    }

    /// A floor was chosen in the cab. The journey's floor -> ride on;
    /// anything else -> the journey ends (the player has taken over).
    static func destinationChosen(_ floor: Int) {
        // Oct 12: the player rides away from the destination floor mid-escort
        // (or mid-goodbye). The escort is still owed: it stays saved, and he is
        // put back with them when they return (resumeEscortIfSaved) -- not left
        // to vanish when the old floor's scene happens to be freed.
        if let t = trip, t.stage == .guiding || t.stage == .goodbye, floor != t.toFloor {
            lead?.cancel(); lead = nil
            performance += 1
            guide?.removeFromParentNode()
            Cast.setJeff(.absent, body: nil, "the player left the floor mid-escort")
            log("leftMidEscort", ["to": floor])
            end(clearSaved: false)
            return
        }
        guard var t = trip, t.stage == .boarding else { return }
        if floor == t.toFloor {
            t.stage = .riding
            trip = t
            log("riding", ["to": floor])
        } else {
            log("diverted", ["to": floor])
            end()
        }
    }

    // MARK: Arrival (destination floor)

    /// While the destination scene is installed: the guide, in the cab.
    static func installGuideIfArriving(in root: SCNNode, floor: Int) {
        guard Cast.jeffPlacement(floor: floor) == .journeyGuide, let frame = doorwayFrame?() else { return }   // Oct 6: the cast authority
        let node = Cast.makeJeffBody()                              // the one Jeff factory
        node.name = guideName
        let (spot, faceOut) = cabSpot(frame: frame, root: root)
        node.position = SCNVector3(spot.x, 0, spot.y)
        node.eulerAngles.y = faceOut
        root.addChildNode(node)
        guide = node
        let performer = FredLeadPerformer(node: node)
        performer.beginLeading()                                    // still on duty: tail up
        self.performer = performer
        log("arrival.guideInCab", ["floor": floor])
        Cast.setJeff(.journeyGuide, body: node, "in the arriving cab, floor \(floor)")
    }

    /// The arrival doors start opening: out first, look back, lead on --
    /// to the player's office (PlayerOffice), through its door.
    static func arrivalDoorsOpening(floor: Int) {
        guard var t = trip, t.stage == .riding, t.toFloor == floor else { return }
        guard let performer, let context, let frame = doorwayFrame?() else { log("arrival.unavailable", [:]); end(); return }
        let s = context.cellSize
        func cell(_ p: SIMD2<Float>) -> GridCoordinate { GridCoordinate(row: Int((p.y / s).rounded()), col: Int((p.x / s).rounded())) }
        func center(_ c: GridCoordinate) -> SIMD2<Float> { SIMD2<Float>(Float(c.col) * s, Float(c.row) * s) }
        let u = frame.outward, c = frame.center
        let landing = cell(c + u * (s * 0.5))                     // the hallway cell outside the doors
        guard floor == PlayerOffice.floor, PlayerOffice.officeNode?.parent != nil,
              let route = CharacterLead.route(from: landing, to: PlayerOffice.entryCell, cells: context.cells, doors: context.doors),
              route.count >= 2 else {
            log("arrival.noRoute", ["floor": floor]); end(); return
        }
        t.stage = .guiding
        trip = t
        refreshSign()                                    // (Oct 24: followed on from Floor 2 -- no sign)
        // Oct 12 (escort resume): the escort is under way on this floor -- saved,
        // so a relaunch from here on resumes it here (not in Administration).
        ResumeState.saveEscort(.init(fromFloor: t.fromFloor, toFloor: floor, stage: Stage.guiding.rawValue))
        var steps = officeEscortSteps(route: route, context: context)
        // Out through the doors, then a first look back just outside them.
        let outside = center(landing) + u * 0.9
        let firstWay = route.count > 1 ? center(route[1]) - center(route[0]) : u
        steps.insert(contentsOf: [
            .travel([c - u * 0.3, c + u * 0.6, outside]),
            .stop(CharacterLead.Stop(point: outside, onward: simd_normalize(firstWay), release: 2.6, cell: landing))
        ], at: 0)
        let lead = CharacterLead(performer: performer, context: context, steps: steps)
        lead.name = "orientation.floor\(floor)"
        // Oct 24: FOLLOW drives the player (no guidedRoute); he goes on only while followed.
        lead.mayProceed = { isFollowed }
        lead.onFinalRelease = { goodbye() }
        // Oct 9: his body left the scene mid-lead (a rebuild, a floor change):
        // the journey can't go on, so it ends instead of staying `guiding`.
        lead.onLost = { abandon(reason: "guide left the scene while guiding") }
        self.lead = lead
        log("arrival.leading", ["route": route.map { "\($0.row),\($0.col)" }.joined(separator: " "), "steps": steps.count])
        Cast.setJeff(.leading, body: guide, "out of the cab first, floor \(floor)")
        // Doors are 1.6 s to open; he goes when there's room.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { lead.start() }
    }

    /// The escort to the office along `route` (ending at its entry cell):
    /// waits at the junctions at the mouth of the right branch, pauses on the
    /// long corridors only if you fall behind, holds the office door open and
    /// waits just inside it, beside it, until you come in.
    private static func officeEscortSteps(route: [GridCoordinate], context: CharacterLead.Context) -> [CharacterLead.Step] {
        var steps = CharacterLead.plan(route: route, context: context, finalPoint: PlayerOffice.welcomeSpot,
                                       decisionInset: -0.6, decisionRelease: 2.2, paceEvery: 3)
        if case .some(.stop(var last)) = steps.last {
            last.waitsForPlayer = true
            last.release = 2.0
            // Oct 9 (stuck-guide fix): "until you come in" means IN THE OFFICE.
            // The 2 m radius alone missed a player who had already walked on
            // past him to the far side of the 2 x 2 office (> 2 m from both
            // him and his spot): he waited and called forever, the journey
            // stayed `guiding`, and the computer stayed locked.
            last.releaseCells = PlayerOffice.officeCells
            steps[steps.count - 1] = .stop(last)
        }
        return steps
    }

    // MARK: Oct 12 -- resuming an escort after a relaunch

    /// Every floor build (after the office and the journey's floor context
    /// are in place): an escort saved on this floor (ResumeState) whose guide
    /// isn't here -- the app was quit mid-escort, or the floor was rebuilt --
    /// is picked up again. The floor is still quiet (the prologue isn't
    /// complete), the player is at their saved spot; he appears a little
    /// ahead of them on the way to the office, looks back and leads on.
    /// Already in the office: he is just inside the door, and the goodbye
    /// plays (the lamp is built OFF on every build, so it plays whole).
    static func resumeEscortIfSaved(in root: SCNNode, floor: Int) {
        // Oct 24: a wait for FOLLOW whose Tinky isn't in this freshly built scene (the floor
        // was rebuilt) is over -- he is back at his desk and his introduction is there again.
        if let t = trip, t.stage == .awaitingFollow, !(guide.map { $0.parent != nil && sceneRoot(of: $0) === root } ?? false) {
            log("awaitingFollow.lostOnRebuild", ["floor": floor])
            end(clearSaved: false)
        }
        // Oct 12: still in its first phase, on the floor it set out from.
        if let saved = ResumeState.escortPending(onFloor: floor), saved.stage == Stage.leading.rawValue,
           saved.fromFloor == floor, floor != saved.toFloor {
            resumeLeadingIfNeeded(in: root, floor: floor, saved: saved)
            return
        }
        guard let saved = ResumeState.escortPending(onFloor: floor), floor == PlayerOffice.floor else { return }
        if let t = trip {
            // In memory and alive in this very scene: nothing to resume.
            guard t.stage == .guiding || t.stage == .goodbye else { return }
            if let g = guide, g.parent != nil, sceneRoot(of: g) === root { return }
            lead?.cancel(); lead = nil                      // (first: its onLost must not end the journey)
            performance += 1                                // a goodbye in flight stops where it is
            guide?.removeFromParentNode()
            trip = nil
            performer = nil
            log("resume.replacingLostGuide", [:])
        }
        let gen = Self.resumeGeneration + 1
        Self.resumeGeneration = gen
        // A moment for the restored camera pose to settle into the scene.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard gen == Self.resumeGeneration, trip == nil, ResumeState.escortPending(onFloor: floor) != nil else { return }
            startResumedEscort(in: root, floor: floor, saved: saved)
        }
    }
    private static var resumeGeneration = 0
    /// The goodbye performance in flight; a superseded one (the guide was
    /// replaced, the journey ended) stops at its next step.
    private static var performance = 0

    /// Just inside the office door -- or, if the player is standing right
    /// there, a metre further in (never on top of them).
    private static func welcomeSpot(clearOf player: SIMD2<Float>, cellSize s: Float) -> SIMD2<Float> {
        let spot = PlayerOffice.welcomeSpot
        guard simd_distance(spot, player) < 0.8 else { return spot }
        let middle = PlayerOffice.officeCells.reduce(SIMD2<Float>(0, 0)) {
            $0 + SIMD2<Float>(Float($1.col) * s, Float($1.row) * s)
        } / Float(PlayerOffice.officeCells.count)
        let away = simd_length(middle - spot) > 0.01 ? simd_normalize(middle - spot) : SIMD2<Float>(0, 1)
        return spot + away * 1.0
    }

    // Oct 12 -- the first phase: "follow me", out of Administration to the elevator.

    private static func resumeLeadingIfNeeded(in root: SCNNode, floor: Int, saved: ResumeState.Escort) {
        // Only an escort under way (prepared at launch, or live) is put back;
        // a floor built without one (its desk Tinky and exit rule already in
        // place) means it can't be: forget it -- the encounter is there again.
        guard let t = trip else { ResumeState.clearEscort(reason: "floorBuiltWithoutJourney"); return }
        guard t.stage == .leading, t.fromFloor == floor else { return }     // boarding / riding: live, leave it be
        if let g = guide, g.parent != nil, sceneRoot(of: g) === root { return }   // alive in this scene
        lead?.cancel(); lead = nil                          // (first: its onLost must not end anything)
        guide?.removeFromParentNode()
        performer = nil
        let gen = Self.resumeGeneration + 1
        Self.resumeGeneration = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard gen == Self.resumeGeneration, ResumeState.escortPending(onFloor: floor) != nil,
                  trip == nil || (trip?.stage == .leading && guide?.parent == nil) else { return }
            startResumedLeading(in: root, floor: floor, saved: saved)
        }
    }

    /// He stands a little ahead of the player on the way to the elevator
    /// nook (never on the far side of a door from them), looks back, and
    /// leads on exactly as "follow me" does; at the nook he waits for the
    /// elevator and the journey goes on as ever (boarding, the ride, Floor 3).
    private static func startResumedLeading(in root: SCNNode, floor: Int, saved: ResumeState.Escort) {
        guard let context = FredLead.context ?? self.context,
              AdministrationReception.officeNode.map({ sceneRoot(of: $0) === root }) == true,
              let pose = context.playerPose() else {
            log("resume.leading.unavailable", ["floor": floor]); abandonResumedLeading(); return
        }
        let s = context.cellSize
        func center(_ c: GridCoordinate) -> SIMD2<Float> { SIMD2<Float>(Float(c.col) * s, Float(c.row) * s) }
        let player = pose.position
        let playerCell = cell(of: player, size: s)
        let end = FredLead.endCell
        // As FredLead.startFollowMe: to one side of the nook, facing the elevator doors.
        let finalPoint = SIMD2<Float>(Float(end.col) * s, Float(end.row) * s - 0.9)
        let doorsPoint = SIMD2<Float>((Float(end.col) - 0.5) * s, Float(end.row) * s)
        let finalHeading = FredLeadPerformer.heading(doorsPoint - finalPoint)
        guard context.cells.contains(playerCell),
              let way = CharacterLead.route(from: playerCell, to: end, cells: context.cells, doors: context.doors) else {
            log("resume.leading.noRoute", ["playerCell": "\(playerCell.row),\(playerCell.col)"])
            abandonResumedLeading(playerCell: playerCell)
            return
        }
        // The first cell along the way clear of the player, short of any door.
        var ahead: GridCoordinate?
        if way.count >= 2 {
            for i in 1..<way.count {
                let a = way[i - 1], b = way[i]
                if let d = Direction.allCases.first(where: { $0.delta.row == b.row - a.row && $0.delta.col == b.col - a.col }),
                   CharacterLead.doorAnchor(a, d, context.doors) != nil { break }
                if simd_distance(center(b), player) >= 1.4 { ahead = b; break }
            }
        }
        let spot: SIMD2<Float>
        var steps: [CharacterLead.Step]
        var route: [GridCoordinate]? = way
        if let a = ahead, a != end, let onward = CharacterLead.route(from: a, to: end, cells: context.cells, doors: context.doors),
           onward.count >= 2 {
            spot = center(a)
            steps = CharacterLead.plan(route: onward, context: context, finalPoint: finalPoint, finalHeading: finalHeading)
            let firstWay = center(onward[1]) - center(onward[0])
            steps.insert(.stop(CharacterLead.Stop(point: spot, onward: simd_normalize(firstWay), release: 2.6, cell: a)), at: 0)
        } else if way.count >= 2, ahead == nil {
            // A door just ahead (or no room): beside the player, on their side of it.
            let toward = center(way[1]) - player
            let d = simd_length(toward) > 0.01 ? simd_normalize(toward) : SIMD2<Float>(0, -1)
            let side = SIMD2<Float>(-d.y, d.x)
            let a = player + side, b = player - side
            spot = simd_distance(a, center(playerCell)) < simd_distance(b, center(playerCell)) ? a : b
            steps = CharacterLead.plan(route: way, context: context, finalPoint: finalPoint, finalHeading: finalHeading)
            steps.insert(.stop(CharacterLead.Stop(point: spot, onward: simd_normalize(center(way[1]) - center(way[0])),
                                                  release: 2.6, cell: playerCell)), at: 0)
        } else {
            // At the nook already: he's beside it, facing the doors, waiting with them.
            spot = simd_distance(finalPoint, player) < 0.8 ? finalPoint + SIMD2<Float>(0, -0.8) : finalPoint
            steps = [.stop(CharacterLead.Stop(point: spot, onward: nil, isFinal: true, finalHeading: finalHeading, cell: end))]
            route = nil
        }
        let node = Cast.makeJeffBody()                              // the one Jeff factory
        node.name = guideName
        node.position = SCNVector3(spot.x, 0, spot.y)
        node.eulerAngles.y = FredLeadPerformer.heading(player - spot)           // looking back at them
        root.addChildNode(node)
        let performer = FredLeadPerformer(node: node)
        performer.beginLeading()                                    // the flag up: on duty
        // Oct 24: at the nook the final stop waits for the player (then he calls the car).
        if case .some(.stop(var last)) = steps.last, last.isFinal {
            last.waitsForPlayer = true
            steps[steps.count - 1] = .stop(last)
        }
        _ = route
        let lead = CharacterLead(performer: performer, context: context, steps: steps)
        lead.name = "followMe.resumed"
        lead.onFinish = { diag("fred.lead.arrived", ["journey": true, "resumed": true]) }
        trip = nil
        begin(guide: node, lead: lead, fromFloor: floor, toFloor: saved.toFloor)
        Cast.setJeff(.leading, body: node, "resumed: follow me, floor \(floor)")
        AdministrationExitGuard.release(reason: "Tinky is leading (resumed)")
        log("resume.leading", ["playerCell": "\(playerCell.row),\(playerCell.col)", "steps": steps.count,
                               "ahead": ahead.map { "\($0.row),\($0.col)" } ?? "none"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { lead.start() }
    }

    /// The resumed first phase can't go on: back to Administration as it was
    /// before "follow me" (his desk, the exit rule; the encounter again).
    private static func abandonResumedLeading(playerCell: GridCoordinate? = nil) {
        trip = nil
        ResumeState.clearEscort(reason: "resumeLeadingFailed")
        AdministrationReception.installOfficeOccupantIfDue()
        if let playerCell { AdministrationExitGuard.sync(playerCell: playerCell) }
        Cast.jeffActivity("resume failed: back at his desk")
    }

    private static func startResumedEscort(in root: SCNNode, floor: Int, saved: ResumeState.Escort) {
        guard let context, PlayerOffice.officeNode.map({ sceneRoot(of: $0) === root }) == true,
              let pose = context.playerPose() else {
            log("resume.unavailable", ["floor": floor]); return          // (kept saved: tried again next launch)
        }
        let s = context.cellSize
        func center(_ c: GridCoordinate) -> SIMD2<Float> { SIMD2<Float>(Float(c.col) * s, Float(c.row) * s) }
        let player = pose.position
        var playerCell = cell(of: player, size: s)
        // Oct 12: just arrived by elevator (still in the cab, off the grid): from the landing.
        if !context.cells.contains(playerCell), let frame = doorwayFrame?() {
            playerCell = cell(of: frame.center + frame.outward * (s * 0.5), size: s)
        }
        let node = Cast.makeJeffBody()                              // the one Jeff factory
        node.name = guideName
        let performer = FredLeadPerformer(node: node)
        trip = Trip(fromFloor: saved.fromFloor, toFloor: floor, stage: .guiding)
        guide = node
        self.performer = performer
        petted = false
        petWindowOpen = false

        // Already in the office: the goodbye, from just inside the door.
        if PlayerOffice.officeCells.contains(playerCell) || saved.stage == Stage.goodbye.rawValue {
            let spot = welcomeSpot(clearOf: player, cellSize: s)
            node.position = SCNVector3(spot.x, 0, spot.y)
            node.eulerAngles.y = FredLeadPerformer.heading(player - spot)
            root.addChildNode(node)
            performer.beginLeading()
            Cast.setJeff(.waitingAtJourneyEnd, body: node, "resumed: in the office")
            log("resume.goodbye", ["playerCell": "\(playerCell.row),\(playerCell.col)"])
            if PlayerOffice.officeCells.contains(playerCell) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { if trip != nil, guide === node { goodbye() } }
            } else {
                // (saved mid-goodbye, but the player isn't in the office) -- he waits for them to come in.
                startLead(steps: [.stop(CharacterLead.Stop(point: spot, onward: nil, isFinal: true, release: 2.0,
                                                           waitsForPlayer: true, cell: PlayerOffice.entryCell,
                                                           releaseCells: PlayerOffice.officeCells))],
                          route: nil, context: context, floor: floor)
            }
            return
        }

        // On the way: he stands one cell further along the way to the office.
        guard let way = CharacterLead.route(from: playerCell, to: PlayerOffice.entryCell, cells: context.cells, doors: context.doors),
              way.count >= 2 else {
            node.removeFromParentNode()
            log("resume.noRoute", ["playerCell": "\(playerCell.row),\(playerCell.col)"])
            end(clearSaved: false)                                  // (kept saved: tried again next launch)
            return
        }
        // The first cell along the way that is clear of the player (not the office itself).
        let ahead = way.dropFirst().first { !PlayerOffice.officeCells.contains($0) && simd_distance(center($0), player) >= 1.4 }
        let startCell = ahead ?? PlayerOffice.entryCell
        // Right at the office door: he waits inside it for them.
        let atDoor = ahead == nil
        let spot = atDoor ? welcomeSpot(clearOf: player, cellSize: s) : center(startCell)
        node.position = SCNVector3(spot.x, 0, spot.y)
        node.eulerAngles.y = FredLeadPerformer.heading(player - spot)           // looking back at them
        root.addChildNode(node)
        performer.beginLeading()                                    // on duty: tail up
        var steps: [CharacterLead.Step]
        var route: [GridCoordinate]? = nil
        if atDoor {
            steps = [.stop(CharacterLead.Stop(point: spot, onward: nil, isFinal: true, release: 2.0,
                                              waitsForPlayer: true, cell: PlayerOffice.entryCell,
                                              releaseCells: PlayerOffice.officeCells))]
        } else if let onward = CharacterLead.route(from: startCell, to: PlayerOffice.entryCell, cells: context.cells, doors: context.doors),
                  onward.count >= 2 {
            route = Array(way)
            steps = officeEscortSteps(route: onward, context: context)
            let firstWay = center(onward[1]) - center(onward[0])
            // First: a look back, waiting for them where he stands.
            steps.insert(.stop(CharacterLead.Stop(point: spot, onward: simd_normalize(firstWay), release: 2.6, cell: startCell)), at: 0)
        } else {
            node.removeFromParentNode()
            log("resume.noRoute", ["from": "\(startCell.row),\(startCell.col)"])
            end(clearSaved: false)
            return
        }
        Cast.setJeff(.leading, body: node, "resumed: leading to the office, floor \(floor)")
        ResumeState.saveEscort(.init(fromFloor: saved.fromFloor, toFloor: floor, stage: Stage.guiding.rawValue))
        log("resume.leading", ["playerCell": "\(playerCell.row),\(playerCell.col)", "from": "\(startCell.row),\(startCell.col)",
                               "steps": steps.count])
        startLead(steps: steps, route: route, context: context, floor: floor)
    }

    private static func startLead(steps: [CharacterLead.Step], route: [GridCoordinate]?, context: CharacterLead.Context, floor: Int) {
        guard let performer else { return }
        let lead = CharacterLead(performer: performer, context: context, steps: steps)
        lead.name = "orientation.floor\(floor).resumed"
        _ = route                                    // (Oct 24: FOLLOW drives the player -- no guidedRoute)
        lead.mayProceed = { isFollowed }
        lead.onFinalRelease = { goodbye() }
        refreshSign()
        if !isFollowed { scheduleNudge() }
        lead.onLost = { abandon(reason: "guide left the scene while guiding") }
        self.lead = lead
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { lead.start() }
    }

    // MARK: The goodbye (in the player's office)

    /// You're here. This is yours. You're all set. I'm going.
    private static func goodbye() {
        lead?.cancel(); lead = nil
        // Oct 24: you're here -- the following is over (he isn't leading any more).
        if isFollowed {
            endFollowing("arrived at your office")
            ElevatorBoard.controller?.stopContinuousWalk(reason: "escort arrived")
        }
        nudgeToken += 1
        guide?.childNode(withName: signName, recursively: false)?.removeFromParentNode()
        guard var t = trip, let performer, let context, let lampWorld = PlayerOffice.lampWorld else {
            log("goodbye.unavailable", [:]); depart(); return
        }
        t.stage = .goodbye
        trip = t
        ResumeState.saveEscort(.init(fromFloor: t.fromFloor, toFloor: t.toFloor, stage: Stage.goodbye.rawValue))   // Oct 12
        performance += 1
        let token = performance                       // Oct 12: superseded -> it stops (see `performance`)
        goodbyeStartedAt = CACurrentMediaTime()
        Cast.setJeff(.waitingAtJourneyEnd, body: guide, "the player is in their office")
        func player() -> SIMD2<Float> { context.playerPose()?.position ?? PlayerOffice.doorCenter }
        let lamp = SIMD2<Float>(lampWorld.x, lampWorld.z)
        let desk = PlayerOffice.deskCenter
        let topY = PlayerOffice.deskTopWorldY
        let frontZ = PlayerOffice.deskFrontZ
        let towardCentre: Float = desk.x < lamp.x ? -1 : 1
        let below = SIMD2<Float>(lamp.x + towardCentre * 0.15, frontZ - 0.45)       // on the floor at the desk's front
        let onDesk = SIMD3<Float>(lamp.x + towardCentre * 0.32, topY, frontZ + 0.2)  // on the desk, beside the lamp
        let deskSpot = SIMD2<Float>(desk.x, desk.y)                                    // the middle of the desk
        let down = SIMD3<Float>(lamp.x + towardCentre * 0.5, 0, frontZ - 0.55)         // back on the floor
        log("goodbye", [:])
        performer.depart()
        // 1. To the desk, up onto it.
        performer.travel([below]) {
            performer.hop(to: onDesk, apex: 0.3, duration: 0.42) {
                // 2. "This is yours": the lamp ON.
                performer.touch(lamp, contact: { PlayerOffice.setLamp(on: true) }, then: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        // Guiding is over: the flag comes down; he looks at you.
                        performer.settle(facing: FredLeadPerformer.heading(player() - SIMD2<Float>(onDesk.x, onDesk.z)))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            // The desk: two little taps on it, then you again.
                            performer.touch(deskSpot, contact: {}, then: {
                                performer.touch(deskSpot, contact: {}, then: {
                                    performer.look(at: player(), 0.3) {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                            performer.hop(to: down, apex: 0.2, duration: 0.4) { if token == performance { acknowledge() } }
                                        }
                                    }
                                })
                            })
                        }
                    }
                })
            }
        }
    }

    /// 3. "You're all set": he comes to you, bows his head, wags. A pat is
    /// welcome (a happy shimmy -- he does NOT join you).
    private static func acknowledge() {
        let token = performance
        guard let performer, let context else { leaveOffice(); return }
        let p = context.playerPose()?.position ?? PlayerOffice.doorCenter
        let here = performer.groundPosition ?? p
        let toward = simd_length(here - p) > 0.01 ? simd_normalize(here - p) : SIMD2<Float>(0, 1)
        var spot = p + toward * 1.5
        if !PlayerOffice.officeCells.contains(cell(of: spot, size: context.cellSize)) { spot = here }
        performer.travel([spot]) {
            petWindowOpen = true
            performer.bow(to: context.playerPose()?.position ?? p) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    guard token == performance else { return }
                    if petted { DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { if token == performance { leaveOffice() } } } else { leaveOffice() }
                }
            }
        }
    }

    /// 4. "I'm going": two steps back, a pause, out of the door, one last look.
    private static func leaveOffice() {
        let token = performance
        petWindowOpen = false
        guard var t = trip, let performer, let context else { depart(); return }
        t.stage = .departing
        trip = t
        func player() -> SIMD2<Float> { context.playerPose()?.position ?? PlayerOffice.doorCenter }
        let door = PlayerOffice.doorCenter
        let inside = door + SIMD2<Float>(0, 1.0)
        let outside = door - SIMD2<Float>(0, 0.75)
        performer.stepBack(from: player()) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                performer.travel(aroundPlayer([inside], from: performer.groundPosition, player: player())) {
                    let goOut = {
                        performer.travel([outside]) {
                            // The last look back.
                            performer.look(at: player(), 0.35) {
                                guard token == performance else { return }
                                // Onboarding is over the moment he leaves your office.
                                Admission.isPrologueCompleted = true
                                log("orientationComplete", ["prologueCompleted": true])
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { depart() }
                            }
                        }
                    }
                    if context.isDoorOpen(PlayerOffice.doorCell) {
                        goOut()
                    } else {
                        performer.touch(door, contact: { context.openDoor(PlayerOffice.doorCell) }, then: {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { goOut() }
                        })
                    }
                }
            }
        }
    }

    // MARK: Departure -- back to the elevator alone, and away

    private static func depart() {
        guard let performer, let context, let node = guide, node.parent != nil else {
            if !Admission.isPrologueCompleted { Admission.isPrologueCompleted = true }
            Cast.setJeff(.absent, body: nil, "home at Orientation")
            end(); return
        }
        if var t = trip { t.stage = .departing; trip = t }
        if !Admission.isPrologueCompleted { Admission.isPrologueCompleted = true }
        Cast.setJeff(.travelling, body: node, "walking back to the elevator on his own")
        let s = context.cellSize
        let here = performer.groundPosition ?? PlayerOffice.doorCenter
        guard let frame = doorwayFrame?() else { vanish(); return }
        let nook = cell(of: frame.center + frame.outward * (s * 0.5), size: s)
        guard let route = CharacterLead.route(from: cell(of: here, size: s), to: nook, cells: context.cells, doors: context.doors),
              route.count >= 2 else { vanish(); return }
        // The ordinary route plan, minus every stop: he waits for no one.
        var steps = CharacterLead.plan(route: route, context: context).filter {
            if case .stop = $0 { return false }
            return true
        }
        steps.append(.run { boardElevator() })
        let lead = CharacterLead(performer: performer, context: context, steps: steps)
        lead.name = "candy.home"
        self.lead = lead
        log("departing", ["route": route.map { "\($0.row),\($0.col)" }.joined(separator: " ")])
        lead.start()
    }

    /// At the elevator: if it's free, the doors open for him, he steps in,
    /// they close -- and he's gone. (Heard from the office: the ding.)
    private static func boardElevator() {
        lead?.cancel(); lead = nil
        guard let performer, let node = guide, let frame = doorwayFrame?(), let root = sceneRoot(of: node) else { vanish(); return }
        let u = frame.outward, c = frame.center
        let (spot, faceOut) = cabSpot(frame: frame, root: root)
        let started = characterElevatorDeparture?({ done in
            performer.travel([c + u * 0.6, c - u * 0.45, spot]) {
                performer.face(faceOut)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done() }
            }
        }, {
            node.removeFromParentNode()
            Cast.setJeff(.absent, body: nil, "rode the elevator home to Orientation")
            end()
        }) ?? false
        if started {
            log("boardingElevator", [:])
        } else {
            vanish()                                                 // the elevator is busy: he simply goes
        }
    }

    private static func vanish() {
        guide?.removeFromParentNode()
        Cast.setJeff(.absent, body: nil, "went home to Orientation")
        end()
    }

    // MARK: The pat (during the goodbye only; no joining)

    static var canPet: Bool { trip?.stage == .goodbye && petWindowOpen && !petted && guide?.parent != nil }

    static func isGuide(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let current = n {
            if current === guide { return true }
            n = current.parent
        }
        return false
    }

    static func pet() {
        guard canPet, let performer else { return }
        petted = true
        performer.petShimmy()
        log("pat", [:])
    }

    // MARK: Helpers

    // MARK: Oct 9 -- an interrupted journey never locks the office

    /// When the goodbye began (it takes ~15 s; see goodbyeLimit).
    private static var goodbyeStartedAt: CFTimeInterval = 0
    /// A goodbye still running after this long has lost an animation
    /// completion somewhere: it is finished for him.
    static let goodbyeLimit: CFTimeInterval = 60

    /// Is the guide still performing in the office -- the only reason the
    /// office computer waits? Checked when the player taps the computer.
    /// A journey that can no longer finish (his body is gone from the scene,
    /// or the goodbye has stalled) is wrapped up here instead of blocking.
    static func isPerformingInOffice(now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard let t = trip, t.stage == .guiding || t.stage == .goodbye else { return false }
        guard guide?.parent != nil, performer?.groundPosition != nil else {
            abandon(reason: "guide not in the scene")
            return false
        }
        if t.stage == .goodbye, now - goodbyeStartedAt > goodbyeLimit {
            log("goodbye.stalled", ["seconds": Int(now - goodbyeStartedAt)])
            // He had already shown the player their office: onboarding is done.
            if !Admission.isPrologueCompleted { Admission.isPrologueCompleted = true }
            vanish()
            return false
        }
        return true
    }

    /// The journey can't go on: end it (onboarding stays as it was -- an
    /// unfinished prologue resumes in Administration, as after a relaunch).
    private static func abandon(reason: String) {
        guard let t = trip else { return }
        log("abandoned", ["reason": reason, "from": t.stage.rawValue])
        guide?.removeFromParentNode()
        Cast.setJeff(.absent, body: nil, "journey abandoned: \(reason)")
        end()
    }

    /// `clearSaved`: the journey is over for good (diverted, abandoned, done,
    /// Start Over) -- any saved escort goes too (Oct 12).
    static func end(clearSaved: Bool = true) {
        if clearSaved, trip != nil { ResumeState.clearEscort(reason: "journeyEnded") }
        // Oct 24: no sign, no nudge, no pending "follow me"; following him ends with him.
        guide?.childNode(withName: signName, recursively: false)?.removeFromParentNode()
        nudgeToken += 1
        startLeading = nil
        endFollowing("the escort ended")
        resumeGeneration += 1
        performance += 1
        lead?.cancel(); lead = nil
        trip = nil
        performer = nil
        petWindowOpen = false
        log("end", [:])
    }

    /// Inside the cab, by the doors, on the side away from the button panel.
    private static func cabSpot(frame: (center: SIMD2<Float>, outward: SIMD2<Float>), root: SCNNode) -> (SIMD2<Float>, Float) {
        let u = frame.outward
        let lateral = SIMD2<Float>(-u.y, u.x)
        var side: Float = 1
        if let panel = root.childNode(withName: "elevatorControlPanel", recursively: true) {
            let p = panel.worldPosition
            side = simd_dot(SIMD2<Float>(p.x, p.z) - frame.center, lateral) > 0 ? -1 : 1
        }
        let spot = frame.center - u * 0.75 + lateral * (side * 0.75)
        return (spot, FredLeadPerformer.heading(u))
    }

    private static func cell(of p: SIMD2<Float>, size s: Float) -> GridCoordinate {
        GridCoordinate(row: Int((p.y / s).rounded()), col: Int((p.x / s).rounded()))
    }

    /// Never walk through the player: a leg that would pass within 0.8 m of
    /// them goes round, on the side nearer the room's middle.
    private static func aroundPlayer(_ path: [SIMD2<Float>], from start: SIMD2<Float>?, player: SIMD2<Float>) -> [SIMD2<Float>] {
        guard var from = start else { return path }
        var out: [SIMD2<Float>] = []
        for to in path {
            let d = to - from
            let len2 = simd_length_squared(d)
            if len2 > 0.0001 {
                let t = max(0, min(1, simd_dot(player - from, d) / len2))
                let closest = from + d * t
                if t > 0.02, t < 0.98, simd_distance(closest, player) < 0.8 {
                    let dir = d / len2.squareRoot()
                    let left = SIMD2<Float>(-dir.y, dir.x)
                    let a = player + left * 0.95, b = player - left * 0.95
                    let middle = SIMD2<Float>(12.5 * PlayerOffice.cellSize, 8.5 * PlayerOffice.cellSize)
                    out.append(simd_distance(a, middle) < simd_distance(b, middle) ? a : b)
                }
            }
            out.append(to)
            from = to
        }
        return out
    }

    private static func sceneRoot(of node: SCNNode) -> SCNNode? {
        var n = node
        while let p = n.parent { n = p }
        return n === node ? nil : n
    }

    private static func log(_ event: String, _ fields: [String: Any]) {
        var line = "[Guide] \(event)"
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) { line += " \(k)=\(v)" }
        if let trip { line += " stage=\(trip.stage.rawValue)" }
        elevatorLog(line)
    }
}

// MARK: - Oct 24 -- Tinky as one of the floor's followable presentations

/// While his escort can be followed, Tinky is a presentation like any critter's:
/// the shared tap rule finds him (CritterTapTarget), his card opens (CritterMenu),
/// and FOLLOW follows him (CritterFollow) -- the same machinery, no copy of it.
/// Thin by design: it owns nothing. His body, route, stages and save stay
/// GuidedJourney's; outside the escort (or with no body here) it is simply not
/// rendered, so nothing else in the building sees him differently.
final class TinkyEscortPresentation: ResidentPresentation {
    let residentID: String
    init(id: String) { residentID = id }

    var holdsResident: Bool { false }
    var isRendered: Bool { GuidedJourney.followableBody != nil }
    var isGuiding: Bool { false }
    func tick(now: Date) {}
    func teardown() {}
    func playerBoarding() -> Bool { false }
    func arrivalDoorsOpening() {}
    var debugState: String { GuidedJourney.trip.map { "escort: \($0.stage.rawValue)" } ?? "at his post" }
    var bodyPosition: SIMD2<Float>? { GuidedJourney.followablePosition }
    var bodyNode: SCNNode? { GuidedJourney.followableBody }
    func acknowledgeFollower(player: SIMD2<Float>?) { GuidedJourney.acknowledgeFollower() }
}
