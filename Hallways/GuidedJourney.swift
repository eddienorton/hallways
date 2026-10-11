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
//  In memory only. A relaunch mid-journey resumes in Administration
//  (prologue unfinished) and the office encounter starts it again.
//  Choosing a different floor ends the journey.
//

import SceneKit
import simd

enum GuidedJourney {
    enum Stage: String { case leading, boarding, riding, guiding, goodbye, departing }

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

    // MARK: Begin (the source floor's lead has started)

    static func begin(guide node: SCNNode, lead sourceLead: CharacterLead, fromFloor: Int, toFloor: Int) {
        guard let performer = sourceLead.performer as? FredLeadPerformer else { return }
        trip = Trip(fromFloor: fromFloor, toFloor: toFloor, stage: .leading)
        guide = node
        self.performer = performer
        lead = sourceLead
        petted = false
        petWindowOpen = false
        log("begin", ["from": fromFloor, "to": toFloor])
    }

    /// The floor this ride goes to, chosen for the player (nil = theirs to choose).
    static func autoFloor(from floor: Int) -> Int? {
        guard let trip, trip.fromFloor == floor, trip.stage == .leading || trip.stage == .boarding else { return nil }
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
        guard var t = trip, t.fromFloor == floor, t.stage == .leading else { return }
        guard let node = guide, node.parent != nil, let performer, let frame = doorwayFrame?(),
              let root = sceneRoot(of: node) else {
            log("boarding.noGuide", [:]); end(); return
        }
        t.stage = .boarding
        trip = t
        lead?.cancel(); lead = nil
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
        // Waits at the junctions at the mouth of the right branch, pauses on
        // the long corridors only if you fall behind, holds the office door
        // open and waits just inside it, beside it, until you come in.
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
        // Out through the doors, then a first look back just outside them.
        let outside = center(landing) + u * 0.9
        let firstWay = route.count > 1 ? center(route[1]) - center(route[0]) : u
        steps.insert(contentsOf: [
            .travel([c - u * 0.3, c + u * 0.6, outside]),
            .stop(CharacterLead.Stop(point: outside, onward: simd_normalize(firstWay), release: 2.6, cell: landing))
        ], at: 0)
        let lead = CharacterLead(performer: performer, context: context, steps: steps)
        lead.name = "orientation.floor\(floor)"
        lead.guidedRoute = route                     // Oct 10: WALK follows him
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

    // MARK: The goodbye (in the player's office)

    /// You're here. This is yours. You're all set. I'm going.
    private static func goodbye() {
        lead?.cancel(); lead = nil
        guard var t = trip, let performer, let context, let lampWorld = PlayerOffice.lampWorld else {
            log("goodbye.unavailable", [:]); depart(); return
        }
        t.stage = .goodbye
        trip = t
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
                                            performer.hop(to: down, apex: 0.2, duration: 0.4) { acknowledge() }
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
                    if petted { DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { leaveOffice() } } else { leaveOffice() }
                }
            }
        }
    }

    /// 4. "I'm going": two steps back, a pause, out of the door, one last look.
    private static func leaveOffice() {
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

    static func end() {
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
