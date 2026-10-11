//
//  FredLead.swift
//  Hallways
//
//  Oct 6 -- FREDO SAYS THINGS WITHOUT WORDS (prototype).
//
//  Two messages, one body language:
//
//  - "NOT YET -- KIOSK FIRST" (FredDoorGuard). Before the ID, Fredo is
//    behind his office door. Open it and he is standing right there: ears
//    up, a questioning "tink?", then a firm head-shake with a two-note
//    "nuh-uh" and a stamp. Then his tail goes up like a tour guide's flag,
//    he slips out past you, pulls the door shut behind him and leads you
//    across reception to the ID kiosk, where he taps it and looks back at
//    you until you come. Then a satisfied "mrp", and he goes back inside.
//
//  - "FOLLOW ME" (FredLead.startFollowMe). After his desk performance he
//    looks up at you, raises the flag, gives the come-along call, does two
//    excited hops -- and leads: out of the office, across reception to the
//    glass doors, through the vestibule, to the elevator. At every stop he
//    looks back, glances the way he means to go, calls now and then, and
//    goes on as you come close (CharacterLead does the deciding).
//
//  Both use the office model (TinCanRatModel, a plain SCNNode), not the
//  TinCanRat driver: the driver only knows how to run ahead of the player.
//

import SceneKit
import simd

// MARK: - Shared hooks (set by ContentView for each Floor 2 build)

enum FredLead {
    /// The lead engine's view of Administration (cells, doors, player).
    static var context: CharacterLead.Context?
    /// Swing a Room Entrance door for show only (never passable).
    static var swingDoorCosmetically: ((GridCoordinate, Bool) -> Void)?
    /// PROTOTYPE endpoint: the elevator nook. He waits there.
    static let endCell = GridCoordinate(row: 10, col: 6)
    /// Oct 6 (orientation trip): from the nook he takes the player on by
    /// elevator to their office floor, and to their office.
    static var orientationFloor: Int { PlayerOffice.floor }

    /// The "follow me" invitation, then the lead to the elevator nook.
    /// Returns nil (and does nothing) if the floor isn't wired for it.
    static func startFollowMe(fred: SCNNode, onDone: @escaping () -> Void) -> CharacterLead? {
        guard let context else { diag("fred.lead.unavailable", ["reason": "no context"]); return nil }
        let s = context.cellSize
        let performer = FredLeadPerformer(node: fred)
        guard let here = performer.groundPosition else { return nil }
        func cell(_ p: SIMD2<Float>) -> GridCoordinate { GridCoordinate(row: Int((p.y / s).rounded()), col: Int((p.x / s).rounded())) }
        let player = context.playerPose()?.position ?? here
        let startCell = context.cells.contains(cell(here)) ? cell(here) : cell(player)
        guard let route = CharacterLead.route(from: startCell, to: endCell, cells: context.cells, doors: context.doors) else {
            diag("fred.lead.unavailable", ["reason": "no route", "fromRow": startCell.row, "fromCol": startCell.col])
            return nil
        }
        // He ends to one side of the nook, facing the elevator doors (west wall).
        let finalPoint = SIMD2<Float>(Float(endCell.col) * s, Float(endCell.row) * s - 0.9)
        let doors = SIMD2<Float>((Float(endCell.col) - 0.5) * s, Float(endCell.row) * s)
        let steps = CharacterLead.plan(route: route, context: context, finalPoint: finalPoint,
                                       finalHeading: FredLeadPerformer.heading(doors - finalPoint))
        let lead = CharacterLead(performer: performer, context: context, steps: steps)
        lead.name = "followMe"
        lead.guidedRoute = route                     // Oct 10: WALK follows him
        lead.onFinish = onDone
        // The first place he heads for = the direction of "this way".
        var firstTarget = finalPoint
        for step in steps { if case .travel(let path) = step, let p = path.first { firstTarget = p; break } }
        diag("fred.lead.plan", ["cells": route.map { "\($0.row),\($0.col)" }.joined(separator: " "),
                                "steps": steps.count])
        performer.invite(player: player, way: firstTarget - here) { lead.start() }
        return lead
    }
}

// MARK: - "Not yet -- kiosk first"

enum FredDoorGuard {
    static let nodeName = "administrationOfficeDoorGuard"
    /// The office door's anchor: the south wall of (11,9).
    static let officeDoor = GridCoordinate(row: 11, col: 9)
    static let kioskCell = GridCoordinate(row: 9, col: 9)
    private static weak var guardNode: SCNNode?
    private static var performer: FredLeadPerformer?
    private static var lead: CharacterLead?
    /// Out of the office (refusing, leading, going home).
    private static var busy = false
    private static var retireWhenHome = false

    /// Just inside the door, 1.4 m back (clear of the leaf), facing it.
    private static func home(_ s: Float) -> SIMD2<Float> { SIMD2<Float>(9 * s, 11.5 * s + 1.4) }

    /// Before the ID: Fredo is in, behind his door. Every Floor 2 build
    /// (relaunch included). Office-local == world x/z.
    static func installIfDue(in office: SCNNode, s: Float) {
        guard Cast.jeffPlacement(floor: AdministrationReception.floor) == .doorGuard,     // Oct 6: the cast authority decides
              office.childNode(withName: nodeName, recursively: false) == nil else { return }
        lead?.cancel(); lead = nil; performer = nil
        busy = false; retireWhenHome = false
        let fred = Cast.makeJeffBody()                              // the one Jeff factory
        fred.name = nodeName
        let h = home(s)
        fred.position = SCNVector3(h.x, 0, h.y)
        fred.eulerAngles.y = 0                                      // facing the door (north)
        office.addChildNode(fred)
        guardNode = fred
        diag("fred.doorGuard.installed", [:])
        Cast.setJeff(.doorGuard, body: fred, "installed behind his office door")
    }

    /// He is out of the office right now (refusing, leading to the kiosk,
    /// or on his way home).
    static var isOut: Bool { busy && guardNode?.parent != nil }

    /// Oct 6 (Cast: one Jeff): the ID is done and Jeff goes back to his desk.
    /// If he's home, hand over THIS body (stopped, at rest) for the desk; if
    /// he's still out, nil -- he'll sit down when he gets home.
    static func surrenderBody() -> SCNNode? {
        guard let node = guardNode, node.parent != nil else { return nil }
        if busy { retireWhenHome = true; return nil }
        lead?.cancel(); lead = nil; performer = nil
        guardNode = nil
        retireWhenHome = false
        node.removeAllActions()
        node.enumerateChildNodes { child, _ in child.removeAllActions() }
        // Back to the model's rest pose (body, ears, tail, legs).
        if let body = node.childNode(withName: "tinCanRatBody", recursively: true) {
            body.position = SCNVector3(0, TinCanRatModel.bodyHeight, 0)
            body.eulerAngles = SCNVector3(0, 0, 0)
        }
        for i in 0..<2 {
            node.childNode(withName: "tinCanRatEar\(i)", recursively: true)?.eulerAngles =
                SCNVector3(Float.pi / 2, 0, (i == 0 ? -1 : 1) * 0.35)
        }
        node.childNode(withName: "tinCanRatTail", recursively: true)?.eulerAngles = SCNVector3(0, 0, 0)
        for i in 0..<4 { node.childNode(withName: "tinCanRatLeg\(i)", recursively: true)?.eulerAngles = SCNVector3(0, 0, 0) }
        diag("fred.doorGuard.toDesk", [:])
        return node
    }

    /// The player opened the office door. True = Fredo answered it.
    static func intercept(_ coord: GridCoordinate) -> Bool {
        guard coord == officeDoor, !Admission.isCompleted, let fred = guardNode, fred.parent != nil,
              FredLead.context != nil else { return false }
        if busy {
            // Already out showing you the way: "nuh-uh" from wherever he is.
            if let nope = FredSound.nope { CritterAudio.play(nope, on: fred) }
            return true
        }
        busy = true
        let performer = FredLeadPerformer(node: fred)
        self.performer = performer
        FredLead.swingDoorCosmetically?(officeDoor, true)
        diag("fred.doorGuard.refuse", [:])
        Cast.jeffActivity("answers the door -- not yet")
        performer.refuse { startKioskLead() }
        return true
    }

    private static func startKioskLead() {
        guard let context = FredLead.context, let performer else { busy = false; return }
        let s = context.cellSize
        let spot = SIMD2<Float>(9 * s - 0.8, 8.5 * s + 0.6)          // beside the kiosk, near the wall
        let touch = SIMD2<Float>(9 * s - 0.32, 8.5 * s + 0.35)       // the kiosk's flank
        performer.beginLeading()
        let steps: [CharacterLead.Step] = [
            // He pulls the door to behind him once he's through.
            .run { DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { FredLead.swingDoorCosmetically?(officeDoor, false) } },
            .travel([SIMD2<Float>(9 * s, 11.5 * s - 0.6), spot]),
            .stop(CharacterLead.Stop(point: spot, onward: nil, isFinal: true, finalHeading: nil, touchTarget: touch,
                                     release: 3.4, waitsForPlayer: true, cell: kioskCell))
        ]
        let lead = CharacterLead(performer: performer, context: context, steps: steps)
        lead.name = "kioskFirst"
        lead.onFinalRelease = { goHome() }
        self.lead = lead
        Cast.jeffActivity("leading to the kiosk")
        lead.start()
    }

    private static func goHome() {
        lead?.cancel(); lead = nil
        guard let performer, let s = FredLead.context?.cellSize else { busy = false; return }
        let player = FredLead.context?.playerPose()?.position
        diag("fred.doorGuard.goingHome", [:])
        performer.approve(player: player) {
            performer.travel([SIMD2<Float>(9 * s, 11.5 * s - 1.0)]) {
                FredLead.swingDoorCosmetically?(officeDoor, true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    performer.travel([home(s)]) {
                        performer.settle(facing: 0)
                        FredLead.swingDoorCosmetically?(officeDoor, false)
                        busy = false
                        diag("fred.doorGuard.home", [:])
                        Cast.jeffActivity("home behind his door")
                        // The ID was taken while he was out: now to his desk.
                        if retireWhenHome { AdministrationReception.installOfficeOccupantIfDue() }
                    }
                }
            }
        }
    }
}

// MARK: - Fredo's body for CharacterLead

final class FredLeadPerformer: LeadPerformer {
    private(set) weak var node: SCNNode?
    private weak var body: SCNNode?
    private weak var tail: SCNNode?
    private var ears: [SCNNode] = []
    private var legs: [SCNNode] = []
    private let steps = TinCanRatSound.stepSources()

    static let speed: Float = 2.5                    // m/s -- brisker than a walk
    static let flagX: CGFloat = -0.75                 // tail up: "I'm leading"
    private static let gestureKey = "leadGesture", travelKey = "leadTravel", faceKey = "leadFace"

    init(node: SCNNode) {
        self.node = node
        body = node.childNode(withName: "tinCanRatBody", recursively: true)
        tail = node.childNode(withName: "tinCanRatTail", recursively: true)
        ears = (0..<2).compactMap { node.childNode(withName: "tinCanRatEar\($0)", recursively: true) }
        legs = (0..<4).compactMap { node.childNode(withName: "tinCanRatLeg\($0)", recursively: true) }
    }

    // MARK: LeadPerformer

    var groundPosition: SIMD2<Float>? {
        guard let node, node.parent != nil else { return nil }
        let p = node.presentation.worldPosition
        return SIMD2<Float>(p.x, p.z)
    }

    var isGesturing: Bool {
        guard let node else { return false }
        return node.action(forKey: Self.gestureKey) != nil || node.action(forKey: Self.travelKey) != nil
    }

    func travel(_ path: [SIMD2<Float>], then: @escaping () -> Void) {
        guard let node else { then(); return }
        node.removeAction(forKey: Self.faceKey)
        node.removeAction(forKey: Self.gestureKey)
        var points = [here]
        for p in path.map({ local($0) }) where simd_distance(p, points[points.count - 1]) > 0.05 { points.append(p) }
        guard points.count > 1 else { DispatchQueue.main.async { then() }; return }
        var cumulative: [Float] = [0]
        for i in 1..<points.count { cumulative.append(cumulative[i - 1] + simd_distance(points[i], points[i - 1])) }
        let total = cumulative[cumulative.count - 1]
        let startHeading = node.eulerAngles.y
        let firstHeading = Self.heading(points[1] - points[0])
        let bigTurn = abs(Self.shortest(firstHeading - startHeading)) > 1.0
        let duration = Double(total / Self.speed) + 0.15
        var heading = bigTurn ? firstHeading : startHeading
        var lastElapsed: CGFloat = 0
        let move = SCNAction.customAction(duration: duration) { n, elapsed in
            let u = Float(min(1, elapsed / CGFloat(duration)))
            let eased = 0.35 * (u * u * (3 - 2 * u)) + 0.65 * u      // a brisk trot, soft at both ends
            func point(at s: Float) -> SIMD2<Float> {
                var i = 0
                while i < cumulative.count - 2 && cumulative[i + 1] < s { i += 1 }
                let span = max(0.0001, cumulative[i + 1] - cumulative[i])
                let t = min(1, max(0, (s - cumulative[i]) / span))
                return points[i] + (points[i + 1] - points[i]) * t
            }
            let along = eased * total
            let p = point(at: along)
            n.position = SCNVector3(p.x, n.position.y, p.y)
            let ahead = point(at: min(total, along + 0.35)) - p
            if simd_length(ahead) > 0.01 {
                let dt = Float(max(0, elapsed - lastElapsed))
                let target = atan2(-ahead.x, -ahead.y)
                var turn = target - heading
                while turn > .pi { turn -= 2 * .pi }
                while turn < -.pi { turn += 2 * .pi }
                heading += turn * min(1, dt * 11)
                n.eulerAngles.y = heading
            }
            lastElapsed = elapsed
        }
        let pre: SCNAction = bigTurn ? turn(to: firstHeading, 0.16) : .wait(duration: 0)
        node.runAction(.sequence([pre, .group([move, trot(duration)])]), forKey: Self.travelKey) {
            DispatchQueue.main.async { then() }
        }
    }

    func touch(_ point: SIMD2<Float>, contact: @escaping () -> Void, then: @escaping () -> Void) {
        guard let node else { then(); return }
        let d = local(point) - here
        let distance = simd_length(d)
        guard distance > 0.01 else { contact(); then(); return }
        let dir = d / distance
        let lunge = max(0.05, min(0.6, distance - 0.25))
        let sound = lunge > 0.3 ? FredSound.tonk : FredSound.click
        let forward = SCNAction.moveBy(x: CGFloat(dir.x * lunge), y: 0, z: CGFloat(dir.y * lunge), duration: 0.13)
        forward.timingMode = .easeIn
        let back = SCNAction.moveBy(x: CGFloat(-dir.x * lunge), y: 0, z: CGFloat(-dir.y * lunge), duration: 0.24)
        back.timingMode = .easeOut
        let body = self.body
        node.removeAction(forKey: Self.faceKey)
        node.runAction(.sequence([
            turn(to: Self.heading(d), 0.16),
            .group([forward, trot(0.13)]),
            .run { _ in DispatchQueue.main.async { contact() } },
            say(sound),
            .run { [weak body] _ in
                body?.runAction(.sequence([.rotateTo(x: -0.12, y: 0, z: 0, duration: 0.05, usesShortestUnitArc: true),
                                           .rotateTo(x: 0, y: 0, z: 0, duration: 0.18, usesShortestUnitArc: true)]))
            },
            .group([back, trot(0.24)]),
            .wait(duration: 0.08)
        ]), forKey: Self.gestureKey) {
            DispatchQueue.main.async { then() }
        }
    }

    func watch(_ player: SIMD2<Float>) {
        guard let node, !isGesturing, node.action(forKey: Self.faceKey) == nil else { return }
        let h = headingTo(player)
        guard abs(Self.shortest(h - node.eulerAngles.y)) > 0.3 else { return }
        node.runAction(turn(to: h, 0.35), forKey: Self.faceKey)
    }

    func pointOnward(_ onward: SIMD2<Float>, player: SIMD2<Float>) {
        guard let node, simd_length(onward) > 0.001 else { return }
        let dir = simd_normalize(onward)
        let step = dir * 0.14
        let lean = SCNAction.moveBy(x: CGFloat(step.x), y: 0, z: CGFloat(step.y), duration: 0.12)
        let unlean = SCNAction.moveBy(x: CGFloat(-step.x), y: 0, z: CGFloat(-step.y), duration: 0.16)
        node.removeAction(forKey: Self.faceKey)
        node.runAction(.sequence([turn(to: Self.heading(dir), 0.2), .group([lean, trot(0.12)]), .wait(duration: 0.45),
                                  .group([unlean, trot(0.16)]), turn(to: headingTo(player), 0.28)]), forKey: Self.gestureKey)
        wag(count: 3)
    }

    func call() {
        guard let node else { return }
        if let source = FredSound.comeAlong { CritterAudio.play(source, on: node) }
        body?.runAction(.sequence([.moveBy(x: 0, y: 0.022, z: 0, duration: 0.08), .moveBy(x: 0, y: -0.022, z: 0, duration: 0.14)]),
                        forKey: "leadCallBounce")
        earsFlick()
        wag(count: 4)
    }

    func urge(player: SIMD2<Float>, onward: SIMD2<Float>?, then: @escaping () -> Void) {
        guard let node else { then(); return }
        let toPlayer = headingTo(player)
        var seq: [SCNAction] = [
            turn(to: toPlayer, 0.2),
            .group([.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 0.5), hop(0.07, 0.5), trot(0.5)]),
            .run { [weak self] _ in DispatchQueue.main.async { self?.call() } },
            .wait(duration: 0.45)
        ]
        if let onward, simd_length(onward) > 0.001 {
            seq += [turn(to: Self.heading(onward), 0.22), .wait(duration: 0.5), turn(to: toPlayer, 0.25)]
        }
        seq.append(.wait(duration: 0.15))
        node.removeAction(forKey: Self.faceKey)
        node.runAction(.sequence(seq), forKey: Self.gestureKey) { DispatchQueue.main.async { then() } }
    }

    func arrive(player: SIMD2<Float>) {
        guard let node else { return }
        node.runAction(turn(to: headingTo(player), 0.3), forKey: Self.faceKey)
        wag(count: 2)
    }

    func depart() {
        guard let node else { return }
        if let source = FredSound.tick { CritterAudio.play(source, on: node) }
        body?.runAction(.sequence([.rotateTo(x: 0.15, y: 0, z: 0, duration: 0.08, usesShortestUnitArc: true),
                                   .rotateTo(x: 0, y: 0, z: 0, duration: 0.12, usesShortestUnitArc: true)]))
    }

    func settle(facing heading: Float?) {
        guard let node else { return }
        tail?.runAction(.rotateTo(x: 0, y: 0, z: 0, duration: 0.5, usesShortestUnitArc: true), forKey: "leadTail")
        for i in 0..<ears.count { if let rest = ear(i, up: 0, 0.4) { ears[i].runAction(rest) } }
        if let heading { node.runAction(turn(to: heading, 0.45), forKey: Self.faceKey) }
    }

    /// Turn to a heading without changing his body state (tail stays up).
    func face(_ heading: Float) {
        node?.runAction(turn(to: heading, 0.35), forKey: Self.faceKey)
    }

    // MARK: Oct 6 -- office goodbye moves

    /// Turn to look at a world point, then `then`.
    func look(at world: SIMD2<Float>, _ d: Double = 0.3, then: @escaping () -> Void) {
        guard let node else { then(); return }
        node.removeAction(forKey: Self.faceKey)
        node.runAction(turn(to: headingTo(world), d), forKey: Self.gestureKey) { DispatchQueue.main.async { then() } }
    }

    /// A springy arc hop to a world point (y = height above the scene's
    /// ground), facing where he jumps: a little crouch, the hop, a TONK landing.
    func hop(to world: SIMD3<Float>, apex: Float = 0.3, duration: Double = 0.42, then: @escaping () -> Void) {
        guard let node else { then(); return }
        let target = node.parent?.convertPosition(SCNVector3(world.x, world.y, world.z), from: nil)
            ?? SCNVector3(world.x, world.y, world.z)
        let a = node.position, b = target
        let body = self.body, legs = self.legs
        let heading = Self.heading(SIMD2<Float>(b.x - a.x, b.z - a.z))
        let top = max(a.y, b.y) + apex
        let arc = SCNAction.customAction(duration: duration) { n, elapsed in
            let u = Float(min(1, max(0, elapsed / CGFloat(duration))))
            // A parabola through a (u=0), the apex, and b (u=1).
            let y0 = a.y, y1 = b.y
            let k = (top - y0) - (y1 - y0) / 2
            let y = y0 + (y1 - y0) * u + 4 * k * u * (1 - u)
            n.position = SCNVector3(a.x + (b.x - a.x) * u, y, a.z + (b.z - a.z) * u)
        }
        node.removeAction(forKey: Self.faceKey)
        node.runAction(.sequence([
            turn(to: heading, 0.16),
            .run { _ in body?.runAction(.rotateTo(x: -0.22, y: 0, z: 0, duration: 0.14, usesShortestUnitArc: true)) },
            .wait(duration: 0.18),
            .run { _ in body?.runAction(.rotateTo(x: 0.12, y: 0, z: 0, duration: 0.12, usesShortestUnitArc: true)) },
            arc,
            say(FredSound.tonk),
            .run { _ in
                body?.runAction(.rotateTo(x: 0, y: 0, z: 0, duration: 0.18, usesShortestUnitArc: true))
                for (i, leg) in legs.enumerated() {
                    let sign: CGFloat = (i == 0 || i == 3) ? 1 : -1
                    leg.runAction(.sequence([.rotateTo(x: 0.45 * sign, y: 0, z: 0, duration: 0.05),
                                             .rotateTo(x: 0, y: 0, z: 0, duration: 0.22)]))
                }
            },
            .wait(duration: 0.25)
        ]), forKey: Self.gestureKey) { DispatchQueue.main.async { then() } }
    }

    /// "You're all set": face the player, a small "mrp", a little bow of the
    /// head, a warm wag.
    func bow(to player: SIMD2<Float>, then: @escaping () -> Void) {
        guard let node else { then(); return }
        let body = self.body
        node.removeAction(forKey: Self.faceKey)
        node.runAction(.sequence([
            turn(to: headingTo(player), 0.25),
            .run { _ in body?.runAction(.rotateTo(x: 0.18, y: 0, z: 0, duration: 0.18, usesShortestUnitArc: true)) },
            say(FredSound.mrp),
            .wait(duration: 0.45),
            .run { _ in body?.runAction(.sequence([.rotateTo(x: -0.28, y: 0, z: 0, duration: 0.25, usesShortestUnitArc: true),
                                                   .wait(duration: 0.35),
                                                   .rotateTo(x: 0, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true)])) },
            .run { [weak self] _ in DispatchQueue.main.async { self?.wag(count: 4) } },
            .wait(duration: 1.0)
        ]), forKey: Self.gestureKey) { DispatchQueue.main.async { then() } }
    }

    /// Two small steps backwards, still facing the player.
    func stepBack(from player: SIMD2<Float>, distance: Float = 0.35, then: @escaping () -> Void) {
        guard let node else { then(); return }
        let away = here - local(player)
        let dir = simd_length(away) > 0.01 ? simd_normalize(away) : SIMD2<Float>(0, 1)
        let step = SCNAction.moveBy(x: CGFloat(dir.x * distance), y: 0, z: CGFloat(dir.y * distance), duration: 0.55)
        step.timingMode = .easeInEaseOut
        node.removeAction(forKey: Self.faceKey)
        node.runAction(.group([step, trot(0.55)]), forKey: Self.gestureKey) { DispatchQueue.main.async { then() } }
    }

    /// Oct 6: the pet's happy shimmy (the same one FredOfficeEncounter.pet
    /// plays on the office model): trill, bounce, wiggle, ears, fast wag.
    func petShimmy() {
        guard let node, let body else { return }
        if let happy = FredSound.happy { CritterAudio.play(happy, on: node) }
        let restY = body.position.y
        body.runAction(.sequence([
            .group([.move(to: SCNVector3(0, restY + 0.02, 0), duration: 0.1),
                    .rotateTo(x: 0.18, y: 0, z: 0, duration: 0.1, usesShortestUnitArc: true)]),
            .rotateTo(x: 0.18, y: 0, z: 0.12, duration: 0.08, usesShortestUnitArc: true),
            .rotateTo(x: 0.18, y: 0, z: -0.12, duration: 0.1, usesShortestUnitArc: true),
            .rotateTo(x: 0.18, y: 0, z: 0.1, duration: 0.1, usesShortestUnitArc: true),
            .group([.move(to: SCNVector3(0, restY, 0), duration: 0.16),
                    .rotateTo(x: 0, y: 0, z: 0, duration: 0.16, usesShortestUnitArc: true)])
        ]))
        for i in 0..<ears.count {
            let side: CGFloat = i == 0 ? -1 : 1
            ears[i].runAction(.sequence([.rotateTo(x: .pi / 2 + 0.27, y: 0, z: side * 0.8, duration: 0.1, usesShortestUnitArc: true),
                                         .wait(duration: 0.45),
                                         .rotateTo(x: .pi / 2, y: 0, z: side * 0.35, duration: 0.25, usesShortestUnitArc: true)]))
        }
        if let tail {
            var wag: [SCNAction] = []
            for k in 0..<5 { wag.append(.rotateTo(x: -0.2, y: k % 2 == 0 ? 0.5 : -0.5, z: 0, duration: 0.08)) }
            wag.append(.rotateTo(x: 0, y: 0, z: 0, duration: 0.15))
            tail.runAction(.sequence(wag), forKey: "leadWag")
        }
    }

    // MARK: Fredo's own one-shots

    /// The body state of leading: tail up like a tour guide's flag, ears up.
    func beginLeading() {
        tail?.runAction(.rotateTo(x: Self.flagX, y: 0, z: 0, duration: 0.25, usesShortestUnitArc: true), forKey: "leadTail")
        for i in 0..<ears.count { if let up = ear(i, up: 0.35, 0.2) { ears[i].runAction(up) } }
    }

    /// "Follow me!" -- look up at you, flag up, the call, two excited hops,
    /// then (if the way isn't simply toward you) a look that way, back at
    /// you, and that way again. `then` = go.
    func invite(player: SIMD2<Float>, way: SIMD2<Float>, then: @escaping () -> Void) {
        guard let node else { then(); return }
        let body = self.body
        let toPlayer = headingTo(player)
        let toWay = Self.heading(way)
        var seq: [SCNAction] = [
            turn(to: toPlayer, 0.2),
            .run { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.body?.runAction(.sequence([.rotateTo(x: 0.22, y: 0, z: 0, duration: 0.18, usesShortestUnitArc: true),
                                                    .wait(duration: 0.9),
                                                    .rotateTo(x: 0, y: 0, z: 0, duration: 0.25, usesShortestUnitArc: true)]))
                    self.beginLeading()
                }
            },
            .wait(duration: 0.35),
            .run { [weak self] _ in DispatchQueue.main.async { self?.call() } },
            .wait(duration: 0.55),
            hop(0.06, 0.24), .wait(duration: 0.06), hop(0.06, 0.24),
            .wait(duration: 0.15)
        ]
        if abs(Self.shortest(toWay - toPlayer)) > 0.6 {
            seq += [turn(to: toWay, 0.18), .wait(duration: 0.4), turn(to: toPlayer, 0.2), .wait(duration: 0.2), turn(to: toWay, 0.15)]
        } else {
            // The way is past you: a little crouch-and-spring wind-up instead.
            seq.append(.run { [weak body] _ in
                body?.runAction(.sequence([.rotateTo(x: -0.14, y: 0, z: 0, duration: 0.16, usesShortestUnitArc: true),
                                           .rotateTo(x: 0, y: 0, z: 0, duration: 0.1, usesShortestUnitArc: true)]))
            })
            seq.append(.wait(duration: 0.26))
        }
        diag("fred.lead.invite", [:])
        node.runAction(.sequence(seq), forKey: Self.gestureKey) { DispatchQueue.main.async { then() } }
    }

    /// "Not yet." He was right behind the door: ears up and a "tink?" (yes,
    /// he knows you're there), then a firm head-shake with "nuh-uh", ears
    /// back, and a stamp of both front feet. Then the flag goes up.
    func refuse(then: @escaping () -> Void) {
        guard let node else { then(); return }
        let h = node.eulerAngles.y
        func yaw(_ dy: Float, _ d: Double) -> SCNAction {
            .rotateTo(x: 0, y: CGFloat(h + dy), z: 0, duration: d, usesShortestUnitArc: true)
        }
        let seq: [SCNAction] = [
            .wait(duration: 0.4),                                      // the door swings open
            .run { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    for i in 0..<self.ears.count { if let up = self.ear(i, up: 0.45, 0.1) { self.ears[i].runAction(up) } }
                    self.body?.runAction(.rotateTo(x: 0.2, y: 0, z: 0, duration: 0.15, usesShortestUnitArc: true))
                }
            },
            say(FredSound.query),
            .wait(duration: 0.65),
            .run { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    for i in 0..<self.ears.count { if let back = self.ear(i, up: -0.35, 0.12) { self.ears[i].runAction(back) } }
                    self.body?.runAction(.rotateTo(x: -0.06, y: 0, z: 0, duration: 0.12, usesShortestUnitArc: true))
                }
            },
            say(FredSound.nope),
            yaw(0.42, 0.07), yaw(-0.42, 0.1), yaw(0.34, 0.09), yaw(-0.3, 0.09), yaw(0, 0.08),
            stamp(0), .wait(duration: 0.12), stamp(1),
            .wait(duration: 0.5),
            .run { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.body?.runAction(.rotateTo(x: 0, y: 0, z: 0, duration: 0.15, usesShortestUnitArc: true))
                    self.beginLeading()
                }
            },
            .wait(duration: 0.3)
        ]
        node.runAction(.sequence(seq), forKey: Self.gestureKey) { DispatchQueue.main.async { then() } }
    }

    /// "Good." Face you, "mrp", a wag; the flag comes down.
    func approve(player: SIMD2<Float>?, then: @escaping () -> Void) {
        guard let node else { then(); return }
        var seq: [SCNAction] = []
        if let player { seq.append(turn(to: headingTo(player), 0.25)) }
        seq += [say(FredSound.mrp),
                .run { [weak self] _ in DispatchQueue.main.async { self?.wag(count: 5); self?.settle(facing: nil) } },
                .wait(duration: 0.7)]
        node.runAction(.sequence(seq), forKey: Self.gestureKey) { DispatchQueue.main.async { then() } }
    }

    // MARK: Helpers

    /// Noodle's heading convention: yaw h faces (-sin h, -cos h).
    static func heading(_ v: SIMD2<Float>) -> Float { atan2(-v.x, -v.y) }

    static func shortest(_ a: Float) -> Float {
        var d = a
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    private var here: SIMD2<Float> {
        guard let node else { return .zero }
        return SIMD2<Float>(node.position.x, node.position.z)
    }

    /// World (x, z) -> his parent's space (the office node: x/z identical).
    private func local(_ w: SIMD2<Float>) -> SIMD2<Float> {
        guard let parent = node?.parent else { return w }
        let p = parent.convertPosition(SCNVector3(w.x, 0, w.y), from: nil)
        return SIMD2<Float>(p.x, p.z)
    }

    private func headingTo(_ world: SIMD2<Float>) -> Float { Self.heading(local(world) - here) }

    private func turn(to h: Float, _ d: Double) -> SCNAction {
        let a = SCNAction.rotateTo(x: 0, y: CGFloat(h), z: 0, duration: d, usesShortestUnitArc: true)
        a.timingMode = .easeInEaseOut
        return a
    }

    private func say(_ source: SCNAudioSource?) -> SCNAction {
        .run { node in if let source { CritterAudio.play(source, on: node) } }
    }

    private func ear(_ i: Int, up: CGFloat, _ d: Double) -> SCNAction? {
        guard i < ears.count else { return nil }
        let side: CGFloat = i == 0 ? -1 : 1
        return .rotateTo(x: .pi / 2 + up * 0.6, y: 0, z: side * (0.35 + up), duration: d, usesShortestUnitArc: true)
    }

    private func earsFlick() {
        for i in 0..<ears.count {
            if let up = ear(i, up: 0.6, 0.08), let back = ear(i, up: 0.35, 0.2) { ears[i].runAction(.sequence([up, back])) }
        }
    }

    /// Tail wag that keeps the flag's height (whatever it is now).
    private func wag(count: Int) {
        guard let tail else { return }
        let x = CGFloat(tail.eulerAngles.x)
        var seq: [SCNAction] = []
        for k in 0..<count { seq.append(.rotateTo(x: x, y: k % 2 == 0 ? 0.4 : -0.4, z: 0, duration: 0.08)) }
        seq.append(.rotateTo(x: x, y: 0, z: 0, duration: 0.12))
        tail.runAction(.sequence(seq), forKey: "leadWag")
    }

    /// A little vertical hop of the whole creature.
    private func hop(_ height: CGFloat, _ d: Double) -> SCNAction {
        let up = SCNAction.moveBy(x: 0, y: height, z: 0, duration: d * 0.45)
        up.timingMode = .easeOut
        let down = SCNAction.moveBy(x: 0, y: -height, z: 0, duration: d * 0.55)
        down.timingMode = .easeIn
        return .sequence([up, down, say(steps.randomElement())])
    }

    private func stamp(_ leg: Int) -> SCNAction {
        .run { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, leg < self.legs.count else { return }
                self.legs[leg].runAction(.sequence([.rotateTo(x: -0.55, y: 0, z: 0, duration: 0.06),
                                                    .rotateTo(x: 0, y: 0, z: 0, duration: 0.07)]))
                if let step = self.steps.randomElement(), let n = self.node { CritterAudio.play(step, on: n) }
            }
        }
    }

    /// Leg swing + tin footfalls for `duration` (same gait as the desk performance).
    private func trot(_ duration: Double) -> SCNAction {
        let legs = self.legs, steps = self.steps
        return .run { node in
            let half = 0.09
            let cycles = max(1, Int((duration / (2 * half)).rounded()))
            for (i, leg) in legs.enumerated() {
                let sign: CGFloat = (i == 0 || i == 3) ? 1 : -1
                let swing = SCNAction.sequence([.rotateTo(x: 0.6 * sign, y: 0, z: 0, duration: half),
                                                .rotateTo(x: -0.6 * sign, y: 0, z: 0, duration: half)])
                leg.runAction(.sequence([.repeat(swing, count: cycles), .rotateTo(x: 0, y: 0, z: 0, duration: 0.08)]), forKey: "leadLegs")
            }
            var footfalls: [SCNAction] = []
            for _ in 0..<(cycles * 2) {
                footfalls.append(.run { n in
                    if let step = steps.randomElement() { CritterAudio.play(step, on: n) }
                })
                footfalls.append(.wait(duration: half))
            }
            node.runAction(.sequence(footfalls), forKey: "leadSteps")
        }
    }
}
