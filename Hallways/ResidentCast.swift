//
//  ResidentCast.swift
//  Hallways
//
//  Oct 21 (late) -- ONE POPULATION. The story's characters join the building's
//  residents (BuildingLife): one record each, one identity across Building
//  Life, the halls, the elevator and their scripted scenes. No second movement
//  system: a roaming character is a ResidentKind + RoamPresentation like any
//  other; what differs is only its MOVEMENT POLICY, which is data, not identity:
//
//    free roaming        the ordinary critters (their kinds, unchanged)
//    restricted roaming  the conference-room cast: the shared Roam, but only on
//                        the floors its RoamStyle lists (never 2 or 3)
//    stationed           Juanita and Tinky: always at their posts on Floor 2,
//                        except while a story trip moves them (Tinky's escort)
//
//  STORY SCENES OVERRIDE ROAMING (the reservation): while THE BOX meeting is on
//  -- from the invitation until it is done, and while the cast is in the room
//  for a replay -- a cast member's record is held at its place in the Floor 3
//  conference room: it makes no decisions, is called by no car, and gets no
//  roaming body anywhere. The meeting's own figure of it (ConferenceAudition,
//  unchanged: its timing, seats, interjections, replay) is the only one seen.
//  Afterwards it stays there until the player is off Floor 3 (the cast leave the
//  room with the meeting), then goes back to roaming from there. A roaming body
//  already on the player's floor when the meeting is called simply carries on
//  until that floor is left -- it can never be on Floor 3 (not one of its
//  floors), so the two are never in view at once.
//
//  Stationed characters have no roaming body: their scripted scenes on Floor 2
//  (AdministrationReception, FredOfficeEncounter, the escort) are their figures.
//
//  Members (Oct 22: all six): the Mailbox, Telephone, View-Master, Stove,
//  Camera and Television -- each its meeting model, voice and habits, its own
//  gait (CastGait), its own floors among 4-7 and its own arrival time.
//
//  Cost: nothing per frame unless its body is on the player's floor (then one
//  walk action while it walks, like the chair). No timers. Its 3D model is
//  loaded once (HallwaysianModel's cache) and cloned only when a body is made.
//

import SceneKit
import SwiftUI
import UIKit
import simd

// MARK: - Movement policy

/// How a resident may move -- independent of who it is.
enum ResidentMovementPolicy: Equatable {
    case freeRoaming
    /// The shared Roam, but only on these floors.
    case restricted(floors: Set<Int>)
    /// At its post, except while a story trip has it.
    case stationed(ResidentPlace)
}

// MARK: - The meeting's cast, as residents

/// How its mouth moves with its voice (the meeting's own mouths).
enum CastMouth {
    /// Hinged (radians, fully open): the Mailbox, the Stove.
    case hinge(Float)
    /// Stretched open (AuditionStyle.Mouth.scale): the Telephone, View-Master, Television.
    case stretch
    /// An aperture opening evenly (the Camera's lens-mouth).
    case aperture
}

/// A part that moves while it talks, or in a small idle beat -- and back.
struct CastPartMove {
    let node: String
    var rotate = SCNVector3Zero
    var move = SCNVector3Zero
}

/// Its way of getting about (no legs to speak of): a hop per stride, a side-to-side
/// roll, a forward lean while it goes, at its own pace.
struct CastGait {
    var speed: Float
    var hop: Float
    var stride: Float
    var roll: Float = 0.05
    var lean: Float = 0
}

struct CastMember {
    /// Its resident id (its one identity everywhere).
    let id: String
    /// The meeting's name for its figure (ConferenceAudition.Member.name).
    let actorName: String
    let name: String
    let blurb: String
    let symbol: String
    let tint: Color
    /// Its 3D model (the meeting's own asset), the joints it must have, its size.
    let model: String
    let required: [String]
    let scale: Float
    /// Its mouth and how it moves.
    let mouth: String
    let mouthStyle: CastMouth
    /// While it talks: these parts move (and come back).
    var talkMoves: [CastPartMove] = []
    /// Now and then, standing about: one of these (and back), maybe with a sound.
    var idleMoves: [CastPartMove] = []
    var idleSound: (() -> [AuditionClip])? = nil
    /// Its voice (the meeting's Hallenese) -- the same clips, the same files.
    let voices: () -> [AuditionClip]
    let preview: [(sound: String, at: Double)]
    let gait: CastGait
    /// Where it may roam (restricted: never 2 or 3), how long it stays, how often it changes floor.
    let floors: [Int: Double]
    let stay: ClosedRange<Double>
    let changeFloor: Double
    let taste: [String: Double]
    /// In at the lobby entrance this long after the building opens (a new game),
    /// or after it is first known (a save where the building is already open).
    let arrivalDelay: TimeInterval
    let joinDelay: TimeInterval
    /// Its materials as the meeting dresses them (the Stove's coals, the TV's
    /// glow) -- the very values the meeting sets on the shared materials.
    var dress: ((SCNNode) -> Void)? = nil

    var policy: ResidentMovementPolicy { .restricted(floors: Set(floors.keys)) }
}

enum CastResidents {
    /// The meeting's cast that live in the building: all six, each on its own --
    /// floors 4-7 at different weights, arriving one at a time.
    static let members: [CastMember] = [
        // The Mailbox (Oct 21: the first; unchanged).
        CastMember(id: "cast.mailbox", actorName: "AuditionMailbox", name: "Mailbox",
                   blurb: "A blue mailbox with a flag that shoots up whenever there's news. Sits in on Floor 3's meetings.",
                   symbol: "envelope.fill", tint: Color(red: 0.18, green: 0.36, blue: 0.72),
                   model: "AuditionMailbox", required: ["mailHead", "mailMouth", "mailEyeL", "mailFlag"], scale: 1.45,
                   mouth: "mailMouth", mouthStyle: .hinge(0.7),
                   talkMoves: [CastPartMove(node: "mailFlag", rotate: SCNVector3(Float.pi / 2, 0, 0))],
                   voices: { AuditionVoices.mailbox },
                   preview: [("aud2-mail-0", 0), ("aud2-mail-2", 0.9)],
                   gait: CastGait(speed: 0.55, hop: 0.035, stride: 0.34),
                   floors: [4: 1, 5: 1, 6: 1.5, 7: 1], stay: 50...150, changeFloor: 0.35,
                   taste: ["Mail": 3, "Copy": 2, "Break": 1.5, "Conference": 1.5],
                   arrivalDelay: 320, joinDelay: 90),
        // The rotary Telephone, the presenter: slow and stately, a low glide; the
        // receiver lifts and tips back as it speaks (and, idle, twitches as if to answer).
        CastMember(id: "cast.telephone", actorName: "AuditionTelephone", name: "Telephone",
                   blurb: "A black rotary telephone who presents at Floor 3's meetings. Takes itself very seriously.",
                   symbol: "phone.fill", tint: Color(red: 0.16, green: 0.16, blue: 0.18),
                   model: "AuditionTelephone", required: ["telHead", "telMouth", "telEyeL", "telDial", "telHandset"], scale: 2.1,
                   mouth: "telMouth", mouthStyle: .stretch,
                   talkMoves: [CastPartMove(node: "telHandset", rotate: SCNVector3(-0.45, 0, 0), move: SCNVector3(0, 0.06, 0))],
                   idleMoves: [CastPartMove(node: "telHandset", move: SCNVector3(0, 0.03, 0))],
                   voices: { AuditionVoices.telephone },
                   preview: [("aud3-tel-0", 0), ("aud3-tel-2", 1.4)],
                   gait: CastGait(speed: 0.4, hop: 0.012, stride: 0.24, roll: 0.025, lean: 0.03),
                   floors: [4: 1.5, 5: 1, 6: 0.5, 7: 1], stay: 90...240, changeFloor: 0.25,
                   taste: ["Conference": 3, "Office": 2, "Desks": 1.5],
                   arrivalDelay: 410, joinDelay: 150),
        // The View-Master: small and quick, light bouncy hops; every word a slide change.
        CastMember(id: "cast.viewmaster", actorName: "AuditionViewMaster2", name: "View-Master",
                   blurb: "A red View-Master, always clicking on to the next slide. Notices everything.",
                   symbol: "binoculars.fill", tint: Color(red: 0.78, green: 0.14, blue: 0.14),
                   model: "AuditionViewMaster2", required: ["vm2Head", "vm2Mouth", "vm2EyeL", "vm2Reel", "vm2Lever"], scale: 1.25,
                   mouth: "vm2Mouth", mouthStyle: .stretch,
                   talkMoves: [CastPartMove(node: "vm2Lever", rotate: SCNVector3(0.5, 0, 0))],
                   idleMoves: [CastPartMove(node: "vm2Reel", rotate: SCNVector3(0, 0, -2 * Float.pi / 14)),
                               CastPartMove(node: "vm2Lever", rotate: SCNVector3(0.5, 0, 0))],
                   voices: { AuditionVoices.viewmaster },
                   preview: [("aud3-vm-0", 0), ("aud3-vm-2", 0.9)],
                   gait: CastGait(speed: 0.7, hop: 0.06, stride: 0.26, roll: 0.02),
                   floors: [4: 1, 5: 1.5, 6: 1, 7: 1.5], stay: 30...100, changeFloor: 0.5,
                   taste: ["Aquarium": 3, "Window": 2, "Break": 1.5],
                   arrivalDelay: 500, joinDelay: 210),
        // The Potbelly Stove: heavy -- barely leaves the ground, rocks side to side;
        // its coals glow as in the meeting.
        CastMember(id: "cast.stove", actorName: "AuditionStove", name: "Stove",
                   blurb: "A cast-iron potbelly stove with a warm glow and a short temper. Grumbles in meetings.",
                   symbol: "flame.fill", tint: Color(red: 0.32, green: 0.24, blue: 0.22),
                   model: "AuditionStove", required: ["stoveHead", "stoveMouth", "stoveEyeL", "stovePipeTop"], scale: 1.3,
                   mouth: "stoveMouth", mouthStyle: .hinge(0.6),
                   idleMoves: [CastPartMove(node: "stoveHead", move: SCNVector3(0, 0.012, 0))],
                   voices: { AuditionVoices.stove },
                   preview: [("aud2-stove-0", 0), ("aud2-stove-2", 1.1)],
                   gait: CastGait(speed: 0.32, hop: 0.006, stride: 0.42, roll: 0.09),
                   floors: [4: 1, 5: 1, 6: 1.5, 7: 0.5], stay: 120...300, changeFloor: 0.2,
                   taste: ["Break": 2.5, "Kitchen": 3, "Seating": 1.5],
                   arrivalDelay: 590, joinDelay: 270,
                   dress: { model in
                       model.enumerateHierarchy { node, _ in
                           for m in node.geometry?.materials ?? [] where (m.name ?? "").contains("stoveCoals") {
                               m.emission.contents = UIColor(red: 1, green: 0.42, blue: 0.08, alpha: 1)
                               m.emission.intensity = 0.8
                           }
                       }
                   }),
        // The Camera (with its flashcube): a brisk little scuttle; its lens-mouth
        // opens with its voice; idle, the shutter clicks and the lever winds on.
        // (No flash light while roaming: one more light per floor isn't worth it.)
        CastMember(id: "cast.camera", actorName: "AuditionCamera", name: "Camera",
                   blurb: "A boxy camera wearing a flashcube for a hat. Takes your picture when you least expect it.",
                   symbol: "camera.fill", tint: Color(red: 0.36, green: 0.36, blue: 0.4),
                   model: "AuditionCamera", required: ["camHead", "camMouth", "camEyeL", "camLens", "camLever"], scale: 1.25,
                   mouth: "camMouth", mouthStyle: .aperture,
                   talkMoves: [CastPartMove(node: "camLens", move: SCNVector3(0, 0, 0.012))],
                   idleMoves: [CastPartMove(node: "camLever", rotate: SCNVector3(0, -0.9, 0))],
                   idleSound: { AuditionVoices.cameraShutter },
                   voices: { AuditionVoices.camera },
                   preview: [("aud5-cam-0", 0), ("aud5-cam-1", 0.9)],
                   gait: CastGait(speed: 0.75, hop: 0.02, stride: 0.18, roll: 0.03, lean: 0.05),
                   floors: [4: 1.5, 5: 1, 6: 1, 7: 1.5], stay: 40...120, changeFloor: 0.45,
                   taste: ["Aquarium": 2, "Window": 2.5, "Break": 1],
                   arrivalDelay: 680, joinDelay: 330),
        // The Television: a stiff waddle on its little legs; rabbit-ear antennae
        // wave as it talks; idle, it changes channel.
        CastMember(id: "cast.television", actorName: "AuditionTelevision", name: "Television",
                   blurb: "A wood-cabinet television with rabbit ears. Its picture flickers when it's surprised.",
                   symbol: "tv.fill", tint: Color(red: 0.45, green: 0.3, blue: 0.18),
                   model: "AuditionTelevision", required: ["tvHead", "tvMouth", "tvEyeL", "tvPupilL", "tvAntL", "tvAntR"], scale: 1.25,
                   mouth: "tvMouth", mouthStyle: .stretch,
                   talkMoves: [CastPartMove(node: "tvAntL", rotate: SCNVector3(0, 0, 0.22)),
                               CastPartMove(node: "tvAntR", rotate: SCNVector3(0, 0, -0.22))],
                   idleMoves: [CastPartMove(node: "tvKnob0", rotate: SCNVector3(0, 0, -Float.pi / 6)),
                               CastPartMove(node: "tvAntL", rotate: SCNVector3(0, 0, 0.5))],
                   voices: { AuditionVoices.television },
                   preview: [("aud3-tv-0", 0), ("aud3-tv-2", 0.9)],
                   gait: CastGait(speed: 0.45, hop: 0.015, stride: 0.3, roll: 0.1),
                   floors: [4: 0.5, 5: 1.5, 6: 1, 7: 1], stay: 70...200, changeFloor: 0.3,
                   taste: ["Seating": 2.5, "Break": 2, "Conference": 1],
                   arrivalDelay: 770, joinDelay: 390,
                   dress: { model in
                       model.enumerateHierarchy { node, _ in
                           for m in node.geometry?.materials ?? [] {
                               let name = m.name ?? ""
                               if name.contains("tvGlow") {
                                   m.emission.contents = UIColor(red: 0.85, green: 0.95, blue: 0.9, alpha: 1)
                                   m.emission.intensity = 0.9
                               } else if name.contains("tvScreenFace") {
                                   m.emission.contents = UIColor(red: 0.12, green: 0.2, blue: 0.18, alpha: 1)
                                   m.emission.intensity = 0.5
                               }
                           }
                       }
                   }),
    ]

    static func member(_ id: String) -> CastMember? { members.first { $0.id == id } }
    static var kinds: [ResidentKind] { members.map { CastResidentKind($0) } }

    /// Their Contacts / Building Life entries. Its body is its roaming body, or its
    /// figure in the meeting while it's in the room (the same character).
    static var identities: [CharacterIdentity] {
        members.map { m in
            CharacterIdentity(id: m.id, name: m.name, blurb: m.blurb, symbol: m.symbol, tint: m.tint,
                              preview: m.preview, prepareSounds: { _ = m.voices() },
                              body: {
                                  if let b = BuildingLife.shared.presentations.first(where: { $0.residentID == m.id })?.bodyNode { return b }
                                  guard let f = ConferenceAudition.members.first(where: { $0.name == m.actorName }),
                                        !f.model.isHidden, f.model.parent != nil else { return nil }
                                  return f.model
                              })
        }
    }

    // MARK: The reservation (the meeting)

    /// What a held record says (and how a held record is recognised).
    static let reservedWhy = "reserved: the Floor 3 meeting"

    /// THE BOX meeting has the cast: invited and not yet done, or the cast in the
    /// room right now (a replay) on the floor the player is on.
    static var meetingHoldsCast: Bool {
        switch TheBoxMeeting.state {
        case .available, .gathering, .assembled: return true
        case .notInvited, .completed:
            return ConferenceAudition.isInstalled && BuildingLife.shared.currentFloor == ConferenceRoom.floor
        }
    }

    /// Its place while held: in the conference room (Building Life shows it there).
    static let meetingCell: GridCoordinate =
        ConferenceRoom.roomCells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.first ?? ConferenceRoom.entryCell

    /// Held now? (the meeting has it, or it hasn't left the room since -- the
    /// player still on Floor 3).
    static func isHeld(_ r: Resident) -> Bool {
        meetingHoldsCast || (r.why == reservedWhy && BuildingLife.shared.currentFloor == ConferenceRoom.floor)
    }

    /// The record held at the meeting (idempotent: unchanged once there, so no save every tick).
    static func hold(_ r: inout Resident, now: Date) {
        let car = BuildingLife.shared.car
        if car.callOf(r.id) != nil { car.cancelCall(r.id) }
        guard r.floor != ConferenceRoom.floor || r.cell != meetingCell || r.leg != nil || r.why != reservedWhy else { return }
        LifeLog.event(r.id, "reserved", floor: ConferenceRoom.floor, ["by": "THE BOX meeting", "was": "F\(r.floor) \(LifeLog.cell(r.cell))"])
        r.floor = ConferenceRoom.floor
        r.cell = meetingCell
        r.leg = nil
        r.since = now
        r.dwell = 60
        r.why = reservedWhy
        r.room = nil
        r.roomName = "Conference Room"
    }
}

/// One cast member's kind: restricted roaming, held by the meeting.
final class CastResidentKind: ResidentKind {
    let member: CastMember
    let kind: String
    let abilities: Set<ResidentAbility> = [.walk, .rideElevator]

    init(_ member: CastMember) {
        self.member = member
        kind = member.id
    }

    var normalStyle: RoamStyle {
        var s = RoamStyle(floors: member.floors, stay: member.stay, speed: member.gait.speed, changeFloorChance: member.changeFloor)
        s.roomTaste = member.taste
        return s
    }
    var fastStyle: RoamStyle {
        var s = normalStyle
        s.stay = 8...15
        s.changeFloorChance = max(0.5, member.changeFloor)
        return s
    }
    var style: RoamStyle { BuildingLife.pacing(normal: normalStyle, fast: fastStyle) }

    func newcomers(now: Date) -> [Resident] {
        [Resident(id: member.id, kind: kind, floor: ResidentPolicy.lobbyFloor, cell: nil,
                  since: now.addingTimeInterval(member.joinDelay), dwell: 0)]
    }

    func advance(_ r: inout Resident, to now: Date, plans: (Int) -> FloorPlan?) {
        // In the car right now: the ride finishes first (the car owns it until it's out).
        let riding = BuildingLife.shared.car.rider(r.id) != nil
        if CastResidents.isHeld(r), !riding {
            CastResidents.hold(&r, now: now)
            return
        }
        if r.why == CastResidents.reservedWhy {
            // The meeting is over and the player off Floor 3: its own life again, from the room.
            r.since = now
            r.dwell = 0
            r.why = "the meeting is over"
            LifeLog.event(r.id, "released", floor: r.floor, ["by": "THE BOX meeting"])
        }
        if ResidentRoster.holdArrival(&r, delay: member.arrivalDelay, open: ResidentPolicy.buildingOpen, now: now) { return }
        Roam.advance(&r, style: style, abilities: abilities, plans: plans, to: now)
    }

    func present(_ id: String, on stage: FloorStage) -> ResidentPresentation? {
        guard Admission.isCompleted, !Admission.isQuietOnboarding(floor: stage.floor),
              let context = stage.context, let root = stage.root, let controller = stage.controller else { return nil }
        // Held by the meeting: no roaming body anywhere (the meeting's figure is the one).
        if let r = BuildingLife.shared.resident(id), CastResidents.isHeld(r) || r.why == CastResidents.reservedWhy { return nil }
        guard HallwaysianModel.load(member.model, required: member.required) != nil else {
            LifeLog.warn(id, "body.missingModel", ["model": member.model])
            return nil
        }
        let m = member
        return RoamPresentation(residentID: id, floor: stage.floor, root: root, controller: controller, context: context,
                                style: style, abilities: abilities) { CastResidentBody(member: m) }
    }

    func priorityNote(_ r: Resident, now: Date) -> String? {
        r.why == CastResidents.reservedWhy ? "at THE BOX meeting" : nil
    }
}

// MARK: - The body: its meeting model, getting about in its own way

final class CastResidentBody: RoamerBody {
    let root: SCNNode
    private let bob: SCNNode
    private let member: CastMember
    private let mouth: SCNNode?
    private let mouthRest: (euler: SCNVector3, scale: SCNVector3)
    /// The parts it moves (talking, idling), each with where it rests.
    private var parts: [String: (node: SCNNode, euler: SCNVector3, position: SCNVector3)] = [:]
    private let gait = ChairGait()
    /// Oct 22: its own feet stepping as it walks (CastFeet.swift); nil: the old glide.
    private let feet: CastFootRig?
    /// Oct 22 (later): its own legs -- the Telephone's two articulated ones (CastLegs),
    /// (evening) the Camera's walking tripod (CastTripod); nil: none.
    private let legs: CastWalkerRig?
    private var gesturing = false
    private var guidePace: Float?
    var diagnosticID: String

    init(member: CastMember) {
        self.member = member
        diagnosticID = member.id
        root = SCNNode()
        root.name = "resident.\(member.id)"
        bob = SCNNode()
        root.addChildNode(bob)
        // The meeting's own model (cached; a clone shares its geometry and materials --
        // only ever dressed with the meeting's own values: see CastMember.dress).
        let model = HallwaysianModel.load(member.model, required: member.required)?.clone() ?? SCNNode()
        member.dress?(model)
        model.scale = SCNVector3(member.scale, member.scale, member.scale)
        model.eulerAngles = SCNVector3(0, Float.pi, 0)          // (its face is +z; a resident's front is -z)
        bob.addChildNode(model)
        feet = CastFeet.isEnabled ? CastFeet.byMember[member.id].flatMap { CastFootRig(feet: $0, model: model, scale: member.scale) } : nil
        // Oct 22 (later): the Telephone stands on two articulated legs -- its body set on its
        // hips, the four rubber nubs they replace hidden (nothing else of the model changes).
        var rig: CastWalkerRig?
        var replaced: [String] = []
        if CastFeet.isEnabled, let spec = CastLegs.byMember[member.id] {
            rig = CastLegRig(spec, parent: bob)
            replaced = CastLegs.replaces[member.id] ?? []
        } else if CastFeet.isEnabled, let spec = CastTripod.byMember[member.id] {
            rig = CastTripodRig(spec, parent: bob)                         // (Oct 22, evening: the Camera's tripod)
            replaced = CastTripod.replaces[member.id] ?? []
        }
        if let rig {
            model.position.y = rig.bodyHeight
            for name in replaced { model.childNode(withName: name, recursively: true)?.isHidden = true }
        }
        legs = rig
        let m = model.childNode(withName: member.mouth, recursively: true)
        mouth = m
        mouthRest = (m?.eulerAngles ?? SCNVector3Zero, m?.scale ?? SCNVector3(1, 1, 1))
        for move in member.talkMoves + member.idleMoves where parts[move.node] == nil {
            if let n = model.childNode(withName: move.node, recursively: true) { parts[move.node] = (n, n.eulerAngles, n.position) }
        }
        root.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }
    }

    var speed: Float { guidePace ?? member.gait.speed }
    var heading: Float { gait.yaw }
    var isGesturing: Bool { gesturing }
    var isMoving: Bool { root.action(forKey: "move") != nil }
    var isStepping: Bool { false }
    var activitySpecies: ResidentActivities.Species { .chair }       // (furniture-ish tastes: visiting, inspecting)

    var groundPosition: SIMD2<Float>? {
        guard root.parent != nil else { return nil }
        return SIMD2<Float>(root.position.x, root.position.z)
    }
    private var here: SIMD2<Float> { groundPosition ?? SIMD2<Float>(root.position.x, root.position.z) }
    private static func heading(_ v: SIMD2<Float>) -> Float { atan2(-v.x, -v.y) }

    func setGuidePace(_ mps: Float?) { guidePace = mps.map { max($0, member.gait.speed) } }

    func place(at p: SIMD2<Float>, heading: Float) {
        halt()
        root.position = SCNVector3(p.x, 0, p.y)
        gait.yaw = ChairGait.wrap(heading)
        root.eulerAngles = SCNVector3(0, gait.yaw, 0)
    }

    func halt() {
        root.removeAction(forKey: "move")
        root.removeAction(forKey: "face")
        bob.position = SCNVector3Zero
        bob.eulerAngles = SCNVector3Zero
        feet?.settle()
        legs?.settle()
        gesturing = false
    }

    /// Turn to yaw `h` the short way round, from its own kept yaw (as the chair does).
    private func face(_ h: Float, duration: Double = 0.5) {
        root.removeAction(forKey: "face")
        let g = gait
        let from = g.yaw
        let delta = ChairGait.wrap(h - from)
        guard abs(delta) > 0.001 else { return }
        // Oct 22: a few small steps in place as it turns (its feet go round with it, not skate).
        let rig = feet, legRig = legs
        let steps = Float(max(1, (abs(delta) / 0.6).rounded()))
        let turn = SCNAction.customAction(duration: duration) { n, elapsed in
            let u = Float(min(1, elapsed / CGFloat(duration)))
            g.yaw = ChairGait.wrap(from + delta * u * u * (3 - 2 * u))
            n.eulerAngles = SCNVector3(0, g.yaw, 0)
            if n.action(forKey: "move") == nil {
                rig?.pose(phase: u * steps * .pi, amount: sin(.pi * u), bob: 0, reachScale: 0)
                legRig?.pose(phase: u * steps * .pi, amount: sin(.pi * u), bob: 0, reachScale: 0)
            }
        }
        root.runAction(turn, forKey: "face")
    }

    /// A part out to its move and back: out in `out` s, held `hold` s, back in `back` s.
    private func play(_ move: CastPartMove, out: Double, hold: Double, back: Double, key: String) {
        guard let p = parts[move.node] else { return }
        let restE = p.euler, restP = p.position
        let toE = SCNVector3(restE.x + move.rotate.x, restE.y + move.rotate.y, restE.z + move.rotate.z)
        let toP = SCNVector3(restP.x + move.move.x, restP.y + move.move.y, restP.z + move.move.z)
        func blend(_ a: SCNVector3, _ b: SCNVector3, _ u: Float) -> SCNVector3 {
            SCNVector3(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u, a.z + (b.z - a.z) * u)
        }
        let go = SCNAction.customAction(duration: out) { n, e in
            let u = Float(min(1, Double(e) / max(out, 0.001)))
            n.eulerAngles = blend(restE, toE, u)
            n.position = blend(restP, toP, u)
        }
        let come = SCNAction.customAction(duration: back) { n, e in
            let u = Float(min(1, Double(e) / max(back, 0.001)))
            n.eulerAngles = blend(toE, restE, u)
            n.position = blend(toP, restP, u)
        }
        p.node.removeAction(forKey: key)
        p.node.runAction(.sequence([go, .wait(duration: hold), come]), forKey: key)
    }

    // MARK: Its voice: the meeting's clips, its mouth (and its talking parts) moving with them

    func say() {
        guard root.parent != nil, let clip = member.voices().randomElement() else { return }
        CritterAudio.play(clip.source, on: root)
        let envelope = clip.envelope, rest = mouthRest, style = member.mouthStyle
        if let mouth, !envelope.isEmpty {
            mouth.removeAction(forKey: "talk")
            mouth.runAction(.customAction(duration: clip.duration) { n, e in
                let open = envelope[min(envelope.count - 1, Int(Double(e) / 0.02))]
                switch style {
                case .hinge(let full):
                    n.eulerAngles = SCNVector3(rest.euler.x + full * open, rest.euler.y, rest.euler.z)
                case .stretch:
                    n.scale = SCNVector3(rest.scale.x * (1 - open * 0.15), rest.scale.y * (1 + open * 2.2), rest.scale.z)
                case .aperture:
                    let k = min(2.6, 1 + 1.6 * open)
                    n.scale = SCNVector3(rest.scale.x * k, rest.scale.y * k, rest.scale.z)
                }
            }, forKey: "talk")
            DispatchQueue.main.asyncAfter(deadline: .now() + clip.duration + 0.05) { [weak mouth] in
                mouth?.eulerAngles = rest.euler
                mouth?.scale = rest.scale
            }
        }
        for move in member.talkMoves {                              // (the Mailbox's flag goes up: news!)
            play(move, out: 0.2, hold: clip.duration + 0.6, back: 0.35, key: "talk")
        }
    }

    // MARK: Getting about: a hop per stride, its own roll and lean -- and (Oct 22) its own feet stepping

    func travel(_ path: [SIMD2<Float>], then: @escaping () -> Void) {
        root.removeAction(forKey: "face")
        root.removeAction(forKey: "move")
        var points = [here]
        for p in path where simd_distance(p, points[points.count - 1]) > 0.05 { points.append(p) }
        guard points.count > 1 else { DispatchQueue.main.async { then() }; return }
        var cumulative: [Float] = [0]
        for i in 1..<points.count { cumulative.append(cumulative[i - 1] + simd_distance(points[i], points[i - 1])) }
        let total = cumulative[cumulative.count - 1]
        let duration = Double(total / speed) + 0.15
        let pts = points, cum = cumulative
        func point(at s: Float) -> SIMD2<Float> {
            var i = 0
            while i < cum.count - 2 && cum[i + 1] < s { i += 1 }
            let span = max(0.0001, cum[i + 1] - cum[i])
            let t = min(1, max(0, (s - cum[i]) / span))
            return pts[i] + (pts[i + 1] - pts[i]) * t
        }
        var lastElapsed: CGFloat = 0
        let g = gait, bobNode = bob, style = member.gait
        // Oct 22: on its feet -- the body's hop kept small (the View-Master still skips).
        let rig = feet, legRig = legs
        let hop = legRig != nil ? min(style.hop, CastFeet.walkingBob)
            : (rig.map { $0.feet.keepsHop ? style.hop : min(style.hop, CastFeet.walkingBob) } ?? style.hop)
        let stepLength = legRig?.stepLength ?? rig?.feet.step ?? style.stride
        let move = SCNAction.customAction(duration: duration) { n, elapsed in
            let u = Float(min(1, elapsed / CGFloat(duration)))
            let along = u * total
            let p = point(at: along)
            let ahead = point(at: min(total, along + 0.25)) - p
            let dt = Float(max(0, elapsed - lastElapsed))
            lastElapsed = elapsed
            if simd_length(ahead) > 0.01 {
                let dir = simd_normalize(ahead)
                let turn = ChairGait.wrap(atan2(-dir.x, -dir.y) - g.yaw)
                g.yaw = ChairGait.wrap(g.yaw + turn * min(1, dt * 6))
                n.eulerAngles = SCNVector3(0, g.yaw, 0)
            }
            n.position = SCNVector3(p.x, 0, p.y)
            // One hop per stride, its roll with it, its lean into the walk.
            let easing = min(1, min(along, total - along) / 0.2)
            // (on its feet: body and feet keep time with its own step; otherwise its stride, as before)
            let phase = along / stepLength * .pi
            let lift = abs(sin(phase)) * hop * easing
            bobNode.position.y = lift
            bobNode.eulerAngles = SCNVector3(-style.lean * easing, 0, sin(phase) * style.roll * easing)
            rig?.pose(phase: phase, amount: easing, bob: lift)               // (its feet, stepping with the distance it covers)
            legRig?.pose(phase: phase, amount: easing, bob: lift, reachScale: 1)   // (Oct 22, later: or its legs)
        }
        root.runAction(move, forKey: "move") { [weak self] in
            DispatchQueue.main.async {
                guard let self else { then(); return }
                self.bob.position = SCNVector3Zero
                self.bob.eulerAngles = SCNVector3Zero
                self.feet?.settle()                                          // (Oct 22: every foot back where it rests)
                self.legs?.settle()
                then()
            }
        }
    }

    /// A nudge at a door: up to it, a bump, back.
    func touch(_ point: SIMD2<Float>, contact: @escaping () -> Void, then: @escaping () -> Void) {
        let start = here
        let d = point - start
        let len = simd_length(d)
        let stop = len > 0.45 ? start + d * ((len - 0.4) / len) : start
        gesturing = true
        travel([stop]) { [weak self] in
            guard let self else { contact(); then(); return }
            let bump = SCNAction.rotateBy(x: -0.2, y: 0, z: 0, duration: 0.12)
            self.bob.runAction(.sequence([bump, bump.reversed()]))
            contact()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { then(); return }
                self.travel([start]) { [weak self] in
                    self?.gesturing = false
                    then()
                }
            }
        }
    }

    func watch(_ player: SIMD2<Float>) {
        guard !gesturing, !isMoving else { return }
        face(Self.heading(player - here))
    }

    func turn(toward p: SIMD2<Float>, duration: Double) {
        guard !isMoving else { return }
        face(Self.heading(p - here), duration: duration)
    }

    func pointOnward(_ onward: SIMD2<Float>, player: SIMD2<Float>) {}
    func call() { if !ResidentMusic.hushesVoices { say() } }                          // Oct 22 (stability pass): no Hallenese with the identities on
    func urge(player: SIMD2<Float>, onward: SIMD2<Float>?, then: @escaping () -> Void) { DispatchQueue.main.async { then() } }
    func arrive(player: SIMD2<Float>) {}
    func depart() {}
    func settle(facing heading: Float?) { if let heading { face(heading) } }

    /// Chosen to be followed: it looks round, says something (its parts with it), a little hop.
    func acknowledge(player: SIMD2<Float>?) {
        if let p = player, !isMoving { face(Self.heading(p - here), duration: 0.35) }
        if !ResidentMusic.greet(member.id, on: root) { say() }                          // Oct 22 (musical building): its signature
        guard !gesturing, !isMoving else { return }
        let hopUp = SCNAction.moveBy(x: 0, y: CGFloat(max(0.03, member.gait.hop * 1.5)), z: 0, duration: 0.12)
        hopUp.timingMode = .easeOut
        bob.runAction(.sequence([hopUp, hopUp.reversed(), hopUp, hopUp.reversed()]))
    }

    /// Staying put: now and then a word, a look round, a little hop in place, or
    /// its own small habit (the Telephone's receiver twitches, the View-Master clicks a slide,
    /// the Camera winds on, the TV changes channel).
    func idle() {
        guard !gesturing, !isMoving else { return }
        switch Int.random(in: 0..<5) {
        case 0:
            if !ResidentMusic.hushesVoices { say() }                          // Oct 22 (stability pass): its signature is its voice now
        case 1:
            face(gait.yaw + Float.random(in: -1.2...1.2), duration: 0.8)
        case 2:
            let hopUp = SCNAction.moveBy(x: 0, y: CGFloat(max(0.02, member.gait.hop * 1.4)), z: 0, duration: 0.14)
            hopUp.timingMode = .easeOut
            bob.runAction(.sequence([hopUp, hopUp.reversed()]))
        case 3:
            guard let move = member.idleMoves.randomElement() else { break }
            play(move, out: 0.35, hold: 0.4, back: 0.6, key: "idle")
            if let clip = member.idleSound?().first { CritterAudio.play(clip.source, on: root) }
        default:
            break
        }
    }
}

// MARK: - Stationed characters (Juanita, Tinky)

/// A character at its post: its record always there (Building Life shows it),
/// except while a story trip moves it. No roaming body -- its scripted scenes
/// are its figure -- and no decisions of its own.
final class StationedResidentKind: ResidentKind {
    let id: String
    let kind: String
    let abilities: Set<ResidentAbility> = []
    let station: ResidentPlace
    let duty: String
    /// A story trip under way: where it is instead (nil: at its post).
    let away: () -> ResidentPlace?
    /// Oct 24: its presence on a floor just built, if it has one (Tinky: followable
    /// while his escort runs -- TinkyEscortPresentation). nil: none, as before.
    let presenter: ((String) -> ResidentPresentation?)?

    init(id: String, station: ResidentPlace, duty: String, away: @escaping () -> ResidentPlace? = { nil },
         presenter: ((String) -> ResidentPresentation?)? = nil) {
        self.id = id
        kind = "stationed." + id
        self.station = station
        self.duty = duty
        self.away = away
        self.presenter = presenter
    }

    var policy: ResidentMovementPolicy { .stationed(station) }

    func newcomers(now: Date) -> [Resident] {
        var r = Resident(id: id, kind: kind, floor: station.floor, cell: station.cell, since: now, dwell: 3600)
        r.why = "stationed: " + duty
        return [r]
    }

    /// Idempotent: unchanged while it stays put (so no save every tick).
    func advance(_ r: inout Resident, to now: Date, plans: (Int) -> FloorPlan?) {
        let trip = away()
        let p = trip ?? station
        let why = trip == nil ? "stationed: " + duty : "on a story errand"
        guard r.floor != p.floor || r.cell != p.cell || r.leg != nil || r.why != why else { return }
        r.floor = p.floor
        r.cell = p.cell
        r.leg = nil
        r.since = now
        r.dwell = 3600
        r.why = why
        LifeLog.event(id, trip == nil ? "stationed.atPost" : "stationed.away", floor: p.floor, ["cell": LifeLog.cell(p.cell)])
    }

    func present(_ id: String, on stage: FloorStage) -> ResidentPresentation? { presenter?(id) }

    func priorityNote(_ r: Resident, now: Date) -> String? { duty }
}

enum StationedResidents {
    static var kinds: [ResidentKind] {
        [StationedResidentKind(id: CharacterRegistry.juanitaID,
                               station: ResidentPlace(floor: Admission.administrationFloor, cell: AdministrationReception.deskLanding.coord),
                               duty: "Administration reception"),
         StationedResidentKind(id: CharacterRegistry.tinkyID,
                               station: ResidentPlace(floor: Admission.administrationFloor, cell: FredOfficeEncounter.landing.coord),
                               duty: "his office in Administration",
                               away: { tinkyTrip() },
                               presenter: { TinkyEscortPresentation(id: $0) })]       // Oct 24: followable on his escort
    }

    /// Tinky's escort (GuidedJourney): on the floor he's leading the player from,
    /// then the one he's taking them to -- at its elevator.
    private static func tinkyTrip() -> ResidentPlace? {
        guard let trip = GuidedJourney.trip, trip.stage != .awaitingFollow else { return nil }   // (Oct 24: waiting in his office)
        let floor: Int
        switch trip.stage {
        case .awaitingFollow, .leading, .callingCar, .boarding: floor = trip.fromFloor
        default: floor = trip.toFloor
        }
        guard let cell = BuildingLife.shared.plans(floor)?.elevator else { return nil }
        return ResidentPlace(floor: floor, cell: cell)
    }
}
