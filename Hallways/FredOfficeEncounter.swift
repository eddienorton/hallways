import SceneKit
import UIKit

/// Oct 5 -- THE FRED ENCOUNTER (performance only; no handoff yet).
///
/// After the ID, Fred works at his enormous desk, perched on his binder
/// booster. When the player reaches the desk spot -- (13,9), facing south --
/// he notices, double-takes, recognises them, switches off his banker's lamp
/// (that is all the packing he does), hops down, trots round the east end of
/// the desk and reports for duty in front of the player. Then he simply
/// stands there.
///
/// Deliberately NOT here: the TinCanRat driver, the companion camera,
/// prologue.completed, Posse, following. It is one choreographed SCNAction
/// sequence on the office's static Noodle model (its named parts: body, legs,
/// ears, tail), plus his own small synthesised tin-can sounds.
///
/// Once per office build (= per visit / per launch): see `performedFor`.
enum FredOfficeEncounter {
    /// The player's landing pose for it: centre of (13,9), facing the desk,
    /// a little forward (about 2.9 m from the desk's front edge).
    static let landing = WallFace(coord: GridCoordinate(row: 13, col: 9), direction: .south)
    static let landingStandOff: Double = 0.3
    static let landingKind = "fredDesk"
    private static var floor: Int { AdministrationReception.floor }
    private static let deskTopY: Float = 0.772                      // makeOfficeDesk: H + 0.002
    private static weak var performedFor: SCNNode?
    /// Oct 5 (Fred joins): the performance has finished on this Fred -- he is
    /// standing in front of the player, waiting for the pet.
    private static weak var readyToPet: SCNNode?
    /// The pet has happened on this Fred (the handoff is under way).
    private static weak var petted: SCNNode?
    /// Oct 6 (Follow me prototype): he is inviting / leading the player
    /// (CharacterLead). Taps on him while leading are NOT swallowed -- they
    /// fall through to ordinary navigation (tapping him = going to him).
    private static weak var leading: SCNNode?
    private static var activeLead: CharacterLead?

    private static var occupant: SCNNode? {
        AdministrationReception.officeNode?.childNode(withName: AdministrationReception.officeOccupantName, recursively: false)
    }

    /// Fred is at his desk and hasn't performed yet on this office build.
    static var isAvailable: Bool {
        guard Admission.isCompleted, !Admission.isPrologueCompleted, let fred = occupant else { return false }
        return performedFor !== fred
    }

    /// He is mid-performance (taps on him are swallowed).
    static var isPerforming: Bool {
        guard let fred = occupant else { return false }
        return performedFor === fred && readyToPet !== fred && leading !== fred
    }

    /// Reported for duty and not yet petted.
    static var canPet: Bool {
        guard let fred = occupant else { return false }
        return readyToPet === fred && petted !== fred
    }

    /// Fred himself (not his desk or chair).
    static func isFred(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let current = n {
            if current.name == AdministrationReception.officeOccupantName { return true }
            n = current.parent
        }
        return false
    }

    /// Taps on Fred himself or his desk/chair/booster start (or land toward) it.
    static func owns(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let current = n {
            if current.name == AdministrationReception.officeOccupantName || current.name == "administrationOfficeDesk"
                || current.name == "administrationOfficeChair" || current.name == "administrationOfficeBooster" { return true }
            n = current.parent
        }
        return false
    }

    static func begin() {
        guard isAvailable, let fred = occupant, let office = AdministrationReception.officeNode,
              let body = fred.childNode(withName: "tinCanRatBody", recursively: true) else {
            diag("fred.encounter.skipped", ["available": isAvailable])
            return
        }
        performedFor = fred
        Cast.setJeff(.performing, body: fred, "desk encounter")
        let s = AdministrationReception.officeCellSize
        let desk = AdministrationReception.officeDeskCenter
        let lampNode = office.childNode(withName: "administrationOfficeLamp", recursively: true)
        let lamp = lampNode.map { office.convertPosition($0.worldPosition, from: nil) } ?? SCNVector3(desk.x + 0.67, deskTopY, desk.z + 0.18)
        let player = SCNVector3(Float(landing.coord.col) * s, 0, Float(landing.coord.row) * s + Float(landingStandOff))

        // The marks (office-local; y = height above the floor surface).
        let start = fred.position
        let onDesk = SCNVector3(start.x, deskTopY, desk.z + 0.28)
        let toLamp = normalized(SCNVector3(lamp.x - onDesk.x, 0, lamp.z - onDesk.z))
        let atLamp = SCNVector3(lamp.x - toLamp.x * 0.3, deskTopY, lamp.z - toLamp.z * 0.3)
        // Along the desk's back edge, behind the lamp, to its back-east corner.
        let behindLamp = SCNVector3(atLamp.x, deskTopY, desk.z + 0.38)
        let corner = SCNVector3(desk.x + 0.95 - 0.1, deskTopY, desk.z + 0.38)
        let landed = SCNVector3(desk.x + 0.95 + 0.42, 0, desk.z + 0.5)
        let alongside = SCNVector3(landed.x, 0, desk.z - 0.45 - 0.6)
        let report = SCNVector3(player.x, 0, player.z + 1.9)        // ~ the companion's lead position
        diag("fred.encounter.begin", ["start": describe(start), "lamp": describe(lamp), "report": describe(report)])

        // Stop working.
        body.removeAction(forKey: "officeFredWorking")
        let tail = fred.childNode(withName: "tinCanRatTail", recursively: true)
        tail?.removeAction(forKey: "officeFredTail")
        let ears = (0..<2).compactMap { fred.childNode(withName: "tinCanRatEar\($0)", recursively: true) }
        let legs = (0..<4).compactMap { fred.childNode(withName: "tinCanRatLeg\($0)", recursively: true) }
        let steps = TinCanRatSound.stepSources()
        let restBodyY = body.position.y

        func tilt(_ x: CGFloat, _ d: Double) -> SCNAction {
            let a = SCNAction.rotateTo(x: x, y: 0, z: 0, duration: d, usesShortestUnitArc: true)
            a.timingMode = .easeInEaseOut
            return SCNAction.run { _ in body.runAction(a) }
        }
        func face(_ to: SCNVector3, from: SCNVector3, _ d: Double) -> SCNAction {
            let a = SCNAction.rotateTo(x: 0, y: CGFloat(heading(from, to)), z: 0, duration: d, usesShortestUnitArc: true)
            a.timingMode = .easeInEaseOut
            return a
        }
        func trot(_ duration: Double) -> SCNAction {
            .run { _ in
                let half = 0.09
                let cycles = max(1, Int((duration / (2 * half)).rounded()))
                for (i, leg) in legs.enumerated() {
                    let sign: CGFloat = (i == 0 || i == 3) ? 1 : -1
                    let swing = SCNAction.sequence([.rotateTo(x: 0.6 * sign, y: 0, z: 0, duration: half),
                                                    .rotateTo(x: -0.6 * sign, y: 0, z: 0, duration: half)])
                    leg.runAction(.sequence([.repeat(swing, count: cycles), .rotateTo(x: 0, y: 0, z: 0, duration: 0.08)]))
                }
                var footfalls: [SCNAction] = []
                for _ in 0..<(cycles * 2) {
                    footfalls.append(.run { node in
                        if let step = steps.randomElement() { CritterAudio.play(step, on: node) }
                    })
                    footfalls.append(.wait(duration: half))
                }
                fred.runAction(.sequence(footfalls))
            }
        }
        func walk(_ to: SCNVector3, _ d: Double) -> SCNAction {
            let move = SCNAction.move(to: to, duration: d)
            move.timingMode = .easeInEaseOut
            return .group([move, trot(d)])
        }
        func say(_ source: SCNAudioSource?) -> SCNAction {
            .run { node in if let source { CritterAudio.play(source, on: node) } }
        }
        func ear(_ i: Int, up: CGFloat, _ d: Double) -> SCNAction? {
            guard i < ears.count else { return nil }
            let side: CGFloat = i == 0 ? -1 : 1
            return .rotateTo(x: .pi / 2 + up * 0.6, y: 0, z: side * (0.35 + up), duration: d, usesShortestUnitArc: true)
        }

        var beats: [SCNAction] = []
        // 1-2. NOTICE: an ear twitches; he lifts his attention to the player. "tink?"
        beats.append(.run { _ in
            if let twitch = ear(0, up: 0.5, 0.09), let back = ear(0, up: 0, 0.12) { ears.first?.runAction(.sequence([twitch, back])) }
        })
        beats.append(.wait(duration: 0.3))
        beats.append(.group([face(player, from: start, 0.45), tilt(0.1, 0.45),
                             .sequence([.wait(duration: 0.22), say(FredSound.query)])]))
        // Oct 10 (playthrough): every hold below trimmed -- he sat too long
        // before the hop. Same beats, same order, same jump.
        beats.append(.wait(duration: 0.3))
        // 3. DOUBLE TAKE: papers, you, papers, you. Hold.
        beats += [tilt(-0.32, 0.16), .wait(duration: 0.24), tilt(0.1, 0.16), .wait(duration: 0.26),
                  tilt(-0.32, 0.12), .wait(duration: 0.18), tilt(0.12, 0.12), .wait(duration: 0.4)]
        // 4. RECOGNITION: ears up, tail stiff, a little lift. A two-note tin sound.
        beats.append(.run { _ in
            for i in 0..<ears.count {
                if let up = ear(i, up: 0.45, 0.12), let down = ear(i, up: 0, 0.3) {
                    ears[i].runAction(.sequence([up, .wait(duration: 0.55), down]))
                }
            }
            tail?.runAction(.sequence([.rotateTo(x: -0.35, y: 0, z: 0, duration: 0.1), .wait(duration: 0.6),
                                       .rotateTo(x: 0, y: 0, z: 0, duration: 0.3)]))
            body.runAction(.sequence([.moveBy(x: 0, y: 0.012, z: 0, duration: 0.12), .moveBy(x: 0, y: -0.012, z: 0, duration: 0.2)]))
        })
        beats.append(say(FredSound.realize))
        beats.append(.wait(duration: 0.45))
        // 5. END OF WORKDAY: onto the desk (the top binder skids), to the lamp, nose-bump, CLICK, dark.
        beats.append(.group([tilt(0, 0.2), face(onDesk, from: start, 0.25)]))
        beats.append(.run { _ in
            AdministrationReception.officeNode?.childNode(withName: AdministrationReception.boosterTopName, recursively: true)?
                .runAction(.group([.rotateBy(x: 0, y: 0.3, z: 0, duration: 0.2), .moveBy(x: 0.025, y: 0, z: 0.03, duration: 0.2)]))
        })
        beats.append(walk(onDesk, 0.5))
        beats.append(face(atLamp, from: onDesk, 0.22))
        beats.append(walk(atLamp, 0.32))
        let bumpTo = SCNVector3(atLamp.x + toLamp.x * 0.07, deskTopY, atLamp.z + toLamp.z * 0.07)
        beats.append(.move(to: bumpTo, duration: 0.09))
        beats.append(.run { _ in
            switchOffLamp(lampNode)
        })
        beats.append(say(FredSound.click))
        beats.append(.move(to: atLamp, duration: 0.16))
        beats.append(.wait(duration: 0.35))                          // a moment with the dark lamp
        // 6. DISMOUNT: from the desk's back-east corner (the lamp is out of reach
        // from the booster, so he crossed onto the desk): peer down, wobble, HOP
        // down to the floor east of his chair.
        beats.append(walk(behindLamp, 0.22))                         // a little sidestep back from it
        beats.append(face(corner, from: behindLamp, 0.25))
        beats.append(walk(corner, 0.3))
        beats.append(.rotateTo(x: 0, y: CGFloat(heading(corner, landed)), z: 0, duration: 0.18, usesShortestUnitArc: true))
        beats.append(tilt(-0.38, 0.22))
        beats.append(.wait(duration: 0.14))
        let wobbleH = CGFloat(heading(corner, landed))
        beats.append(.sequence([.rotateTo(x: 0, y: wobbleH, z: 0.07, duration: 0.08), .rotateTo(x: 0, y: wobbleH, z: -0.07, duration: 0.1),
                                .rotateTo(x: 0, y: wobbleH, z: 0.05, duration: 0.09), .rotateTo(x: 0, y: wobbleH, z: 0, duration: 0.08)]))
        beats.append(.wait(duration: 0.12))
        beats.append(.group([tilt(0, 0.12), hop(from: corner, to: landed, apex: 0.25, duration: 0.42)]))
        beats.append(say(FredSound.tonk))
        beats.append(.run { _ in
            for (i, leg) in legs.enumerated() {
                let sign: CGFloat = (i == 0 || i == 3) ? 1 : -1
                leg.runAction(.sequence([.rotateTo(x: 0.45 * sign, y: 0, z: 0, duration: 0.05),
                                         .rotateTo(x: 0, y: 0, z: 0, duration: 0.22)]))
            }
            body.runAction(.sequence([.move(to: SCNVector3(0, restBodyY - 0.035, 0), duration: 0.06),
                                      .move(to: SCNVector3(0, restBodyY, 0), duration: 0.22)]))
        })
        beats.append(.sequence([.rotateTo(x: 0, y: wobbleH, z: 0.05, duration: 0.1), .rotateTo(x: 0, y: wobbleH, z: -0.03, duration: 0.1),
                                .rotateTo(x: 0, y: wobbleH, z: 0, duration: 0.1)]))
        beats.append(.wait(duration: 0.25))
        // 7. AROUND THE DESK: north past the lamp end, then in toward the player.
        beats.append(face(alongside, from: landed, 0.22))
        beats.append(walk(alongside, 0.75))
        beats.append(face(report, from: alongside, 0.18))
        beats.append(walk(report, 0.45))
        // 8. REPORTING FOR DUTY: face the player, look up, "mrp", a tail wag. Stand there.
        beats.append(face(player, from: report, 0.25))
        beats.append(tilt(0.22, 0.2))
        beats.append(say(FredSound.mrp))
        beats.append(.run { _ in
            tail?.runAction(.sequence([.rotateTo(x: 0, y: 0.4, z: 0, duration: 0.1), .rotateTo(x: 0, y: -0.4, z: 0, duration: 0.14),
                                       .rotateTo(x: 0, y: 0.3, z: 0, duration: 0.12), .rotateTo(x: 0, y: 0, z: 0, duration: 0.12)]))
        })
        beats.append(.wait(duration: 0.6))
        beats.append(tilt(0, 0.3))
        beats.append(.run { node in
            let p = node.position
            diag("fred.encounter.done", ["at": describe(p)])
            DispatchQueue.main.async { MainActor.assumeIsolated { beginFollowMe(node) } }
        })
        let performance = SCNAction.sequence(beats)
        diag("fred.encounter.timing", ["seconds": (performance.duration * 10).rounded() / 10])
        fred.runAction(performance, forKey: "fredEncounter")
    }

    // MARK: Follow me (Oct 6 prototype)

    /// Instead of waiting to be petted, he says "follow me!" and leads the
    /// player through Administration (FredLead / CharacterLead). PROTOTYPE:
    /// the lead ends at the elevator nook; there, the existing pet still
    /// completes the prologue so the story gates stay coherent.
    private static func beginFollowMe(_ fred: SCNNode) {
        guard fred.parent != nil else { return }
        activeLead?.cancel()
        let lead = FredLead.startFollowMe(fred: fred) {
            diag("fred.lead.arrived", ["journey": GuidedJourney.trip != nil])
            // Oct 6: on the orientation trip the nook is not the end -- he
            // waits there for the elevator. (No journey: the old pet here.)
            if GuidedJourney.trip == nil { readyToPet = fred }
        }
        if let lead {
            leading = fred
            activeLead = lead
            Cast.setJeff(.leading, body: fred, "follow me")
            // Oct 6 (orientation trip): this lead continues by elevator.
            GuidedJourney.begin(guide: fred, lead: lead, fromFloor: floor,
                                toFloor: FredLead.orientationFloor)
            AdministrationExitGuard.release(reason: "Tinky is leading")      // Oct 9: she never blocks his way
        } else {
            readyToPet = fred                                        // not wired: the old behaviour
        }
    }

    // MARK: The pet -- "okay, little buddy, let's go"

    /// The player's one acknowledgement: a happy little shimmy (ears up, a
    /// bounce, a wiggle, a fast tail wag, a purring trill). It completes the
    /// prologue, then the office Fred hands off to the real companion right
    /// where he stands.
    static func pet() {
        guard canPet, let fred = occupant, let body = fred.childNode(withName: "tinCanRatBody", recursively: true) else { return }
        petted = fred
        activeLead?.cancel()
        activeLead = nil
        Admission.isPrologueCompleted = true                         // Fred and I became a pair
        diag("fred.pet", ["prologueCompleted": Admission.isPrologueCompleted])
        if let happy = FredSound.happy { CritterAudio.play(happy, on: fred) }
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
        for i in 0..<2 {
            guard let ear = fred.childNode(withName: "tinCanRatEar\(i)", recursively: true) else { continue }
            let side: CGFloat = i == 0 ? -1 : 1
            ear.runAction(.sequence([.rotateTo(x: .pi / 2 + 0.27, y: 0, z: side * 0.8, duration: 0.1, usesShortestUnitArc: true),
                                     .wait(duration: 0.45),
                                     .rotateTo(x: .pi / 2, y: 0, z: side * 0.35, duration: 0.25, usesShortestUnitArc: true)]))
        }
        if let tail = fred.childNode(withName: "tinCanRatTail", recursively: true) {
            var wag: [SCNAction] = []
            for k in 0..<5 { wag.append(.rotateTo(x: -0.2, y: k % 2 == 0 ? 0.5 : -0.5, z: 0, duration: 0.08)) }
            wag.append(.rotateTo(x: 0, y: 0, z: 0, duration: 0.15))
            tail.runAction(.sequence(wag))
        }
        // Oct 6 (Cast: one Jeff): the SAME body goes on as the companion. The
        // driver is attached now, held while the shimmy plays, and released
        // when it has settled (the old handoff moment) -- same spot, same
        // heading, no second body.
        if Cast.bond(fred, holdFor: 0.85) {
            diag("fred.joined", ["body": "same"])
        } else {
            diag("fred.join.unavailable", [:])                       // stays as the office model this visit
        }
    }

    // MARK: Helpers

    private static func switchOffLamp(_ lamp: SCNNode?) {
        guard let lamp else { return }
        lamp.childNode(withName: "administrationOfficeLampLight", recursively: true)?.light?.intensity = 0
        if let shade = lamp.childNode(withName: "administrationOfficeLampShade", recursively: true) {
            shade.geometry?.firstMaterial?.emission.contents = UIColor.black
        }
        lamp.runAction(.sequence([.rotateBy(x: 0, y: 0, z: 0.07, duration: 0.06), .rotateBy(x: 0, y: 0, z: -0.11, duration: 0.1),
                                  .rotateBy(x: 0, y: 0, z: 0.04, duration: 0.1)]))
        diag("fred.encounter.lampOff", [:])
    }

    /// A parabolic hop between two marks (no physics).
    private static func hop(from a: SCNVector3, to b: SCNVector3, apex: Float, duration: Double) -> SCNAction {
        .customAction(duration: duration) { node, elapsed in
            let u = Float(min(1, max(0, elapsed / CGFloat(duration))))
            node.position = SCNVector3(a.x + (b.x - a.x) * u,
                                       a.y + (b.y - a.y) * u + 4 * apex * u * (1 - u),
                                       a.z + (b.z - a.z) * u)
        }
    }

    /// Noodle's heading convention: yaw h faces (-sin h, -cos h).
    private static func heading(_ from: SCNVector3, _ to: SCNVector3) -> Float {
        atan2(-(to.x - from.x), -(to.z - from.z))
    }

    private static func normalized(_ v: SCNVector3) -> SCNVector3 {
        let l = max(0.0001, (v.x * v.x + v.z * v.z).squareRoot())
        return SCNVector3(v.x / l, 0, v.z / l)
    }

    private static func describe(_ p: SCNVector3) -> String { String(format: "%.2f,%.2f,%.2f", p.x, p.y, p.z) }
}

// MARK: - Fred's sounds (tin-can creature/machine noises; no words)

nonisolated enum FredSound {
    private static func make(_ name: String, volume: Float, _ render: () -> [Float]) -> SCNAudioSource? {
        MenagerieSound.source("fred-v1-\(name)", volume: volume, render)
    }

    /// Inquisitive little rising "tink?".
    static let query: SCNAudioSource? = make("query", volume: 0.7) {
        var rng = MenagerieSound.Rand(seed: 801)
        let a = MenagerieSound.strike([(2600, 0.05, 1), (5200, 0.03, 0.35)], seconds: 0.12, noise: 0.2, rng: &rng)
        let b = MenagerieSound.strike([(3300, 0.07, 1), (6600, 0.04, 0.3)], seconds: 0.16, noise: 0.2, rng: &rng)
        return MenagerieSound.mix([(at: 0, samples: a, gain: 0.7), (at: 0.11, samples: b, gain: 1),
                                   (at: 0.1, samples: MenagerieSound.sweep(2600, 3600, seconds: 0.14), gain: 0.15)])
    }

    /// Realisation: two bright tin notes up a fifth, with a little spring.
    static let realize: SCNAudioSource? = make("realize", volume: 0.7) {
        var rng = MenagerieSound.Rand(seed: 802)
        let a = MenagerieSound.strike([(2200, 0.09, 1), (4400, 0.05, 0.3)], seconds: 0.2, noise: 0.15, rng: &rng)
        let b = MenagerieSound.strike([(3300, 0.12, 1), (6600, 0.06, 0.25)], seconds: 0.26, noise: 0.15, rng: &rng)
        return MenagerieSound.mix([(at: 0, samples: a, gain: 0.8), (at: 0.09, samples: b, gain: 1),
                                   (at: 0.02, samples: MenagerieSound.sweep(700, 1100, seconds: 0.2, wobble: 0.8), gain: 0.18)])
    }

    /// The banker's lamp switch.
    static let click: SCNAudioSource? = make("click", volume: 0.6) {
        var rng = MenagerieSound.Rand(seed: 803)
        return MenagerieSound.strike([(4200, 0.004, 1), (1500, 0.01, 0.5)], seconds: 0.05, noise: 0.8, rng: &rng)
    }

    /// Landing: a hollow tin-can TONK.
    static let tonk: SCNAudioSource? = make("tonk", volume: 0.85) {
        var rng = MenagerieSound.Rand(seed: 804)
        return MenagerieSound.strike([(380, 0.14, 1), (1050, 0.07, 0.55), (2300, 0.035, 0.3)], seconds: 0.32,
                                     noise: 0.5, noiseDecay: 0.004, rng: &rng)
    }

    /// The pet: a quick rising trill of tinks over a little tin purr.
    static let happy: SCNAudioSource? = make("happy", volume: 0.75) {
        var rng = MenagerieSound.Rand(seed: 806)
        let t1 = MenagerieSound.strike([(2400, 0.04, 1)], seconds: 0.08, rng: &rng)
        let t2 = MenagerieSound.strike([(2900, 0.04, 1)], seconds: 0.08, rng: &rng)
        let t3 = MenagerieSound.strike([(3500, 0.06, 1), (7000, 0.03, 0.25)], seconds: 0.12, rng: &rng)
        return MenagerieSound.mix([(at: 0, samples: MenagerieSound.sweep(180, 230, seconds: 0.4, wobble: 2.0), gain: 0.3),
                                   (at: 0.02, samples: t1, gain: 0.7), (at: 0.08, samples: t2, gain: 0.8),
                                   (at: 0.14, samples: t3, gain: 1)])
    }

    /// Oct 6 -- Hallenese, word one: COME ALONG. A light tin "tink", then a
    /// hollow "TONK" whose ring bends upward like a whistle -- "this way!".
    /// Always the same sound, only ever meaning that.
    static let comeAlong: SCNAudioSource? = make("comeAlong", volume: 0.8) {
        var rng = MenagerieSound.Rand(seed: 807)
        let tink = MenagerieSound.strike([(3000, 0.04, 1), (6000, 0.02, 0.3)], seconds: 0.09, noise: 0.2, rng: &rng)
        let tonk = MenagerieSound.strike([(520, 0.12, 1), (1300, 0.06, 0.4), (2600, 0.03, 0.2)], seconds: 0.3,
                                         noise: 0.35, noiseDecay: 0.003, rng: &rng)
        return MenagerieSound.mix([(at: 0, samples: tink, gain: 0.75), (at: 0.13, samples: tonk, gain: 1),
                                   (at: 0.15, samples: MenagerieSound.sweep(560, 1180, seconds: 0.24, wobble: 0.4, curve: 0.6), gain: 0.5)])
    }

    /// Oct 6 -- Hallenese, word two: NOT YET. Two dull tin notes stepping
    /// down ("nuh-uh"), the second one lower and a little rough.
    static let nope: SCNAudioSource? = make("nope", volume: 0.8) {
        var rng = MenagerieSound.Rand(seed: 808)
        let a = MenagerieSound.strike([(900, 0.07, 1), (1800, 0.03, 0.3)], seconds: 0.15, noise: 0.25, rng: &rng)
        let b = MenagerieSound.strike([(600, 0.09, 1), (1250, 0.04, 0.3)], seconds: 0.22, noise: 0.3, rng: &rng)
        return MenagerieSound.mix([(at: 0, samples: a, gain: 0.9), (at: 0, samples: MenagerieSound.sweep(720, 600, seconds: 0.12), gain: 0.35),
                                   (at: 0.2, samples: b, gain: 1),
                                   (at: 0.2, samples: MenagerieSound.sweep(520, 380, seconds: 0.18, wobble: 1.2), gain: 0.4)])
    }

    /// Oct 6: a quick bright "tik" -- "right, on we go".
    static let tick: SCNAudioSource? = make("tick", volume: 0.55) {
        var rng = MenagerieSound.Rand(seed: 809)
        return MenagerieSound.strike([(3600, 0.03, 1), (7200, 0.015, 0.25)], seconds: 0.07, noise: 0.15, rng: &rng)
    }

    /// Reporting for duty: a tiny "mrp" with a tin tick on the end.
    static let mrp: SCNAudioSource? = make("mrp", volume: 0.7) {
        var rng = MenagerieSound.Rand(seed: 805)
        let tick = MenagerieSound.strike([(2900, 0.03, 1)], seconds: 0.06, rng: &rng)
        return MenagerieSound.mix([(at: 0, samples: MenagerieSound.sweep(520, 410, seconds: 0.13, wobble: 0.6), gain: 0.8),
                                   (at: 0.1, samples: tick, gain: 0.3)])
    }
}
