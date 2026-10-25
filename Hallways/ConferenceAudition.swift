import SceneKit
import UIKit
import simd

/// Oct 11 (late) -- THE CAST AUDITION (Floor 3 Conference Room).
///
/// Oct 12: ROUNDS THREE (now the default) and FOUR -- yesterday's technology
/// (the Telephone, View-Master, Flashcube, Television; the LP, Road
/// Map, Dymo, revised Vacuum): see ConferenceAuditionRounds.swift.
/// Oct 12 (refinement): ROUND FIVE, the default -- the winners plus the revised
/// View-Master and the new Camera. `-HallwaysAuditionRound 1 | 2 | 3 | 4 | 5`.
/// (Oct 19, Stage A: the Rolodex, in rounds three and five, is retired for good.)
///
/// ROUND TWO (`-HallwaysAuditionRound 2`):
///
///   THE SAFE        (at the head, on the table) a small, very heavy green
///                   iron safe on brass paws. Its right eye looks out through
///                   the combination dial like a monocle on a watch chain; its
///                   brass T-handle is a moustache; its mouth is the deposit
///                   slot. Says little, slowly, closing with a clunk; when it
///                   speaks the table nods. Its dial turns, in clicks, while
///                   it thinks.
///   THE STOVE       a pot-bellied cast-iron stove: scowling iron brows, a
///                   knob of a nose, the firebox door for a mouth (the grate
///                   its teeth, the coals glowing behind). Grumbles; smoke
///                   puffs from its pipe.
///   THE MAILBOX     a stout blue mailbox on four short legs; the slot flap
///                   is its mouth; its red flag goes up when there's news.
///                   Chatters, leans in to listen, tittering.
///   THE ACCORDION   upright, red lacquer and pearl; its keyboard is a
///                   drooping jaw, its straps are arms, and it breathes with
///                   its bellows -- and sighs, greatly. Wheezy, melancholy.
///   THE VACUUM      a mint canister on casters with a corrugated trunk,
///                   dust-bag ears and enormous eyes. Coos; sniffs at whoever
///                   is talking; its ears flap when it's delighted.
///   + Juanita (standing in the north-west place) and Mr. Tinky (on a booster).
///
/// Visibility: the cast sit on armless visitor chairs set back from the
/// table and swivelled toward the player at the foot (who sits back a little
/// with a slightly longer seated lens, ConferenceMeeting.seatedFOV); a drag
/// turns the head across the table, a pinch looks closer (CameraMagnifier).
///
/// ROUND ONE:
///
/// Before the meeting, the boss or the story: the principal cast. Juanita
/// and Mr. Tinky take their places around the conference table with five
/// newcomers -- auditions, not commitments:
///
///   THE COMMODORE   an old copper diving helmet on its breastplate. Porthole
///                   eyes with brass shutter lids, riveted strap brows, and a
///                   hinged faceplate for a mouth (its grille: teeth).
///   THE CRANE       a folded-paper crane, blue on top as origami paper is;
///                   quick bird tilts, a hinged paper beak, wings that lift.
///   THE PROSCENIUM  a toy theatre that looks back: a face in the dark of its
///                   little stage, velvet curtains it draws when shy.
///   THE CLOCHE      a small cloud kept under a glass bell jar.
///   ASPIC           a ruby jelly on a cake stand, cherry on top; wobbles.
///
/// Models: CharacterModels/Hallwaysians/scripts/audition.py (the same kit
/// and export contract as Juanita and Mr. Tinky) -> Audition*.usdz.
///
/// Seating (ConferenceRoom's chair order): Juanita stands at the head;
/// Commodore 0, Crane 1, Proscenium 2, Cloche 3, Aspic 4, Tinky 5 (on a
/// booster); the player at the foot (7), looking up the table at everyone.
/// Entering the room seats the player (ConferenceMeeting.playerCellChanged /
/// interceptWalk); a drag looks around; STAND gets up.
///
/// Life: blinking, looking at one another and at the player, small brow and
/// mouth expressions, and restrained Hallenese -- one speaker at a time with
/// pauses between; the others turn to listen and now and then react. No
/// wandering, no meeting, no story.
///
/// OFF: launch with `-HallwaysMeetingClassic YES` -> the staff meeting as before.
enum ConferenceAudition {
    nonisolated static var enabled: Bool { !UserDefaults.standard.bool(forKey: "HallwaysMeetingClassic") }

    static let room = AuditionRoom()
    private static var actors: [AuditionActor] = []

    /// Which audition: 5 (Oct 12, refinement: the four winners with the
    /// revised View-Master and the Camera) unless launched with
    /// `-HallwaysAuditionRound 1`, `2`, `3` or `4` (earlier rounds are kept).
    nonisolated static var round: Int {
        let r = UserDefaults.standard.integer(forKey: "HallwaysAuditionRound")
        return (1...5).contains(r) ? r : 5
    }

    typealias Cast = (String, SCNNode, AuditionActor.Rig, AuditionStyle, [AuditionClip])

    static func install(into room: SCNNode, layout: MeetingLayout, camera: SCNNode?) {
        actors = []
        members = []
        self.room.reset(camera: camera)
        AuditionVoices.prepare()
        let cast: [Cast]
        switch round {
        case 1: cast = castRoundOne(room)
        case 2: cast = castRoundTwo(room, layout: layout)
        case 3: cast = castRoundThree(room, layout: layout)                    // ConferenceAuditionRounds.swift
        case 4: cast = castRoundFour(room, layout: layout)
        default: cast = castRoundFive(room, layout: layout)
        }
        start(cast)
    }

    // MARK: Round one (Oct 11, late): Commodore, Crane, Proscenium, Cloche, Aspic

    private static func castRoundOne(_ room: SCNNode) -> [Cast] {
        func chair(_ i: Int) -> SCNNode? { room.childNode(withName: "conferenceRoomChair\(i)", recursively: false) }
        var cast: [Cast] = []

        // The newcomers, each on its chair's seat.
        let newcomers: [(String, String, Int, Float, AuditionStyle, [AuditionClip], [String])] = [
            ("AuditionCommodore", "comm", 0, 1.0, .commodore, AuditionVoices.commodore, ["commHead", "commMouth", "commEyeL", "commPupilL"]),
            ("AuditionCrane", "crane", 1, 1.5, .crane, AuditionVoices.crane, ["craneHead", "craneMouth", "craneEyeL", "craneWingL"]),
            ("AuditionProscenium", "proc", 2, 1.15, .proscenium, AuditionVoices.proscenium, ["procHead", "procMouth", "procCurtainL"]),
            ("AuditionCloche", "cloche", 3, 1.25, .cloche, AuditionVoices.cloche, ["clocheHead", "clocheMouth", "clocheEyeL"]),
            ("AuditionAspic", "aspic", 4, 1.3, .aspic, AuditionVoices.aspic, ["aspicHead", "aspicMouth", "aspicEyeL"]),
        ]
        for (resource, prefix, index, scale, style, voices, required) in newcomers {
            guard let seat = chair(index), let model = HallwaysianModel.load(resource, required: required)?.clone() else {
                diag("audition.missing", ["model": resource]); continue
            }
            tuneGlass(model)
            model.scale = SCNVector3(scale, scale, scale)
            let holder = placeOnSeat(seat, in: room, lift: 0)
            holder.addChildNode(model)
            cast.append((resource, holder, AuditionActor.rig(model, prefix: prefix), style, voices))
        }
        // Mr. Tinky, on a booster on chair 5.
        if let seat = chair(5), let body = HallwaysianTinky.makeBody() {
            let holder = placeOnSeat(seat, in: room, lift: 0)
            let booster = AdministrationReception.makeBoosterStack()
            holder.addChildNode(booster)
            let tinky = SCNNode()
            tinky.name = "auditionTinky"
            tinky.position = SCNVector3(0, AdministrationReception.boosterHeight, 0)
            tinky.eulerAngles.y = .pi                      // he faces -Z
            tinky.scale = SCNVector3(2, 2, 2)
            tinky.addChildNode(body)
            holder.addChildNode(tinky)
            cast.append(("MrTinky", tinky, AuditionActor.rig(tinky, prefix: "tinCanRat"), .tinky, AuditionVoices.tinky))
        } else {
            diag("audition.missing", ["model": "MrTinky"])
        }
        // Juanita, standing at the head of the table (her chair put away).
        if let head = chair(6), HallwaysianJuanita.isEnabled, let model = HallwaysianJuanita.makeNode() {
            head.isHidden = true
            let holder = SCNNode()
            holder.name = "auditionJuanita"
            holder.position = SCNVector3(head.position.x, 0, head.position.z - 0.12)
            holder.eulerAngles.y = head.eulerAngles.y      // the head chair faces down the table
            holder.addChildNode(model)
            room.addChildNode(holder)
            cast.append(("Juanita", holder, AuditionActor.rig(model, prefix: "admin"), .juanita, AuditionVoices.juanita))
        } else {
            diag("audition.missing", ["model": "Juanita"])
        }

        return cast
    }

    // MARK: Round two (Oct 11, late night): the Safe (at the head), the Stove,
    // the Mailbox, the Accordion, the Vacuum -- with Juanita and Mr. Tinky.

    /// Each side place (ConferenceRoom's chair order) swivelled toward the
    /// foot, where the player sits -- so a turn of the head finds each face,
    /// not a chair back. Nearer places turn further.
    static let swivel: [Int: Float] = [0: 0.61, 1: 0.61, 2: 0.79, 3: 0.79, 4: 0.96, 5: 0.96]
    /// The cast's chairs stand a little back from the table (room to sit big).
    static let pullBack: Float = 0.3
    /// The seat top of AdministrationReception's armless visitor chair.
    static let visitorSeatTop: Float = 0.50

    private static func castRoundTwo(_ room: SCNNode, layout: MeetingLayout) -> [Cast] {
        // The office chairs at the sides and the head go; armless wooden
        // visitor chairs (no high backs in the way) take the cast.
        for i in 0...6 { room.childNode(withName: "conferenceRoomChair\(i)", recursively: false)?.isHidden = true }
        let t = layout.table
        let side = ConferenceRoom.tableWidth / 2 + 0.42 + pullBack
        let rows: [Float] = [-1.75, 0, 1.75]
        func pose(_ i: Int) -> (SCNVector3, Float) {
            let west = i % 2 == 0
            let x = west ? t.x - side : t.x + side
            let yaw = west ? Float(Direction.west.yaw) - (swivel[i] ?? 0) : Float(Direction.east.yaw) + (swivel[i] ?? 0)
            return (SCNVector3(x, 0, t.y + rows[i / 2]), yaw)
        }
        func holderOnChair(_ i: Int, forward: Float) -> SCNNode {
            let (p, yaw) = pose(i)
            let chair = AdministrationReception.makeVisitorChair()
            chair.name = "auditionChair\(i)"
            chair.position = p
            chair.eulerAngles.y = yaw
            room.addChildNode(chair)
            let holder = SCNNode()
            holder.position = SCNVector3(p.x + sin(yaw) * forward, visitorSeatTop, p.z + cos(yaw) * forward)
            holder.eulerAngles.y = yaw
            room.addChildNode(holder)
            return holder
        }
        var cast: [Cast] = []
        func newcomer(_ resource: String, _ prefix: String, _ holder: SCNNode, scale: Float, style: AuditionStyle,
                      voices: [AuditionClip], required: [String]) {
            guard let model = HallwaysianModel.load(resource, required: required)?.clone() else {
                diag("audition.missing", ["model": resource]); holder.removeFromParentNode(); return
            }
            model.scale = SCNVector3(scale, scale, scale)
            holder.addChildNode(model)
            var rig = AuditionActor.rig(model, prefix: prefix)
            if prefix == "stove" { dressStove(model, rig: &rig) }
            cast.append((resource, holder, rig, style, voices))
        }
        // The Safe: on the table at its head, facing down the table.
        let safeHolder = SCNNode()
        safeHolder.position = SCNVector3(t.x, ConferenceRoom.tableTopHeight, t.y - 2.2)
        room.addChildNode(safeHolder)
        newcomer("AuditionSafe", "safe", safeHolder, scale: 1.3, style: .safe, voices: AuditionVoices.safe,
                 required: ["safeHead", "safeMouth", "safeEyeL", "safeEyeR", "safeDial"])
        // Juanita, standing in the first west place (she's too tall to sit).
        if HallwaysianJuanita.isEnabled, let model = HallwaysianJuanita.makeNode() {
            let (p, yaw) = pose(0)
            let holder = SCNNode()
            holder.name = "auditionJuanita"
            holder.position = SCNVector3(p.x + 0.12, 0, p.z)
            holder.eulerAngles.y = yaw
            holder.addChildNode(model)
            room.addChildNode(holder)
            cast.append(("Juanita", holder, AuditionActor.rig(model, prefix: "admin"), .juanita, AuditionVoices.juanita))
        } else {
            diag("audition.missing", ["model": "Juanita"])
        }
        newcomer("AuditionStove", "stove", holderOnChair(1, forward: 0.13), scale: 1.3, style: .stove, voices: AuditionVoices.stove,
                 required: ["stoveHead", "stoveMouth", "stoveEyeL", "stovePipeTop"])
        newcomer("AuditionMailbox", "mail", holderOnChair(2, forward: 0.08), scale: 1.45, style: .mailbox, voices: AuditionVoices.mailbox,
                 required: ["mailHead", "mailMouth", "mailEyeL", "mailFlag"])
        newcomer("AuditionAccordion", "acc", holderOnChair(3, forward: 0.05), scale: 1.5, style: .accordion, voices: AuditionVoices.accordion,
                 required: ["accHead", "accMouth", "accEyeL", "accBellows"])
        newcomer("AuditionVacuum", "vac", holderOnChair(4, forward: 0.06), scale: 1.6, style: .vacuum, voices: AuditionVoices.vacuum,
                 required: ["vacHead", "vacMouth", "vacEyeL", "vacTrunk1", "vacTrunk2", "vacTrunk3"])
        // Mr. Tinky, on the booster on place 5's chair (his film-canister
        // body with -HallwaysAuditionTinkyBody canister; audition only).
        if let body = auditionTinkyBody() {
            let holder = holderOnChair(5, forward: 0.05)
            holder.addChildNode(AdministrationReception.makeBoosterStack())
            let tinky = SCNNode()
            tinky.name = "auditionTinky"
            tinky.position = SCNVector3(0, AdministrationReception.boosterHeight, 0)
            tinky.eulerAngles.y = .pi                      // he faces -Z
            tinky.scale = SCNVector3(2, 2, 2)
            tinky.addChildNode(body)
            holder.addChildNode(tinky)
            cast.append(("MrTinky", tinky, AuditionActor.rig(tinky, prefix: "tinCanRat"), .tinky, AuditionVoices.tinky))
        } else {
            diag("audition.missing", ["model": "MrTinky"])
        }
        return cast
    }

    /// The Stove's coals glow (self-lit), and three puffs of smoke wait at
    /// the top of its pipe.
    static func dressStove(_ model: SCNNode, rig: inout AuditionActor.Rig) {
        var coals: SCNMaterial?
        model.enumerateHierarchy { node, _ in
            for m in node.geometry?.materials ?? [] where (m.name ?? "").contains("stoveCoals") {
                m.emission.contents = UIColor(red: 1, green: 0.42, blue: 0.08, alpha: 1)
                m.emission.intensity = 0.8
                coals = m
            }
        }
        rig.glow = coals
        guard let top = model.childNode(withName: "stovePipeTop", recursively: true) else { return }
        for _ in 0..<3 {
            let puff = SCNNode(geometry: SCNSphere(radius: 0.045))
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(white: 0.72, alpha: 1)
            m.roughness.contents = 1
            puff.geometry?.materials = [m]
            puff.opacity = 0
            puff.castsShadow = false
            top.addChildNode(puff)
            rig.puffs.append(puff)
        }
    }

    // MARK: Everyone in place: faces known, lives started

    private static func start(_ cast: [Cast]) {
        // Where everyone's face is (for looking at one another).
        var faces: [SIMD3<Float>] = []
        for (_, holder, rig, _, _) in cast {
            if let eyes = rig.eyes.first {
                let p = eyes.worldPosition
                faces.append(SIMD3<Float>(p.x, p.y, p.z))
            } else {
                let p = (rig.head ?? holder).worldPosition
                faces.append(SIMD3<Float>(p.x, p.y + (rig.head == nil ? 0.3 : 0.08), p.z))
            }
        }
        self.room.setFaces(faces)
        self.room.setLeader(cast.firstIndex { $0.3.isLeader } ?? -1)
        for (i, (name, holder, rig, style, voices)) in cast.enumerated() {
            let actor = AuditionActor(id: i, name: name, holder: holder, rig: rig, style: style, voices: voices,
                                      laughs: name == "AuditionTelephone" ? TelephoneVoice.selected.laugh   // Oct 12: the voice audition
                                                                          : (AuditionVoices.laughs[name] ?? []), room: self.room)
            actors.append(actor)
            holder.runAction(.repeatForever(actor.tickAction()), forKey: "auditionLife")
            // Oct 12: the model on the holder is what walks in (THE BOX meeting).
            if let model = holder.childNodes.first(where: { !$0.childNodes.isEmpty || $0.geometry != nil }) {
                members.append(Member(id: i, name: name, holder: holder, model: model, voices: voices))
            }
        }
        diag("audition.installed", ["cast": cast.map { $0.0 }.joined(separator: ",")])
    }

    static func playerSat() { room.playerSat() }

    // MARK: Oct 12 -- THE BOX meeting: the cast can arrive one by one

    /// This build's cast: id, asset name, the holder (their place) and the
    /// model on it (what walks in), and their voices.
    struct Member {
        let id: Int
        let name: String
        let holder: SCNNode
        let model: SCNNode
        let voices: [AuditionClip]
    }
    private(set) static var members: [Member] = []
    static var isInstalled: Bool { !members.isEmpty && members.first?.holder.parent != nil }

    /// No cast in the room at all this build (THE BOX meeting not on, or over).
    static func uninstall() {
        actors = []
        members = []
        room.reset(camera: nil)
    }

    /// Everyone out of the room (models hidden, no life) until they arrive.
    static func setAllAbsent() {
        for m in members {
            room.setPresent(m.id, false)
            m.model.isHidden = true
        }
    }

    static func allPresent() { for m in members { arrived(m.id) } }

    /// Oct 12: the cast member whose body this node is part of (the character
    /// itself -- not its chair or booster), if they're in the room.
    static func member(for node: SCNNode) -> Member? {
        var n: SCNNode? = node
        while let current = n {
            if let m = members.first(where: { $0.model === current }) {
                return room.isPresent(m.id) && !m.model.isHidden ? m : nil
            }
            n = current.parent
        }
        return nil
    }

    /// Oct 12 (THE BOX replay over): the cast leaves -- their places and the
    /// audition chairs go, the room's own chairs come back; the room is empty.
    static func dismissCast(from room: SCNNode) {
        for m in members {
            var top: SCNNode = m.holder
            while let p = top.parent, p !== room { top = p }
            if top.parent === room { top.removeFromParentNode() }
        }
        for i in 0...6 { room.childNode(withName: "auditionChair\(i)", recursively: false)?.removeFromParentNode() }
        for i in 0...5 { room.childNode(withName: "conferenceRoomChair\(i)", recursively: false)?.isHidden = false }
        uninstall()
        diag("audition.castDismissed", [:])
    }

    /// One member is in their place: visible, and alive.
    static func arrived(_ id: Int) {
        guard let m = members.first(where: { $0.id == id }) else { return }
        m.model.isHidden = false
        room.setPresent(id, true)
    }

    /// Oct 12 (THE BIG REVEAL): a cast member's id in this build, by asset name.
    static func actorID(_ name: String) -> Int? { actors.first { $0.name == name }?.id }

    /// A holder on a chair's seat top, facing the way the chair faces, a
    /// little forward of the chair's back.
    private static func placeOnSeat(_ seat: SCNNode, in room: SCNNode, lift: Float) -> SCNNode {
        let holder = SCNNode()
        let yaw = seat.eulerAngles.y
        holder.position = SCNVector3(seat.position.x + sin(yaw) * 0.05, 0.515 + lift, seat.position.z + cos(yaw) * 0.05)
        holder.eulerAngles.y = yaw
        room.addChildNode(holder)
        return holder
    }

    /// Glass reads as glass: the bell jar, the cake stand; the jelly lets a
    /// little light through.
    static func tuneGlass(_ model: SCNNode) {
        model.enumerateHierarchy { node, _ in
            for m in node.geometry?.materials ?? [] {
                let name = m.name ?? ""
                if name.contains("Glass") {
                    m.transparency = 0.22
                    m.transparencyMode = .dualLayer
                    m.isDoubleSided = true
                    m.writesToDepthBuffer = false
                    m.roughness.contents = 0.05
                    node.renderingOrder = 5
                } else if name.contains("aspicJelly") {
                    m.transparency = 0.86
                    m.transparencyMode = .dualLayer
                }
            }
        }
    }
}

// MARK: - The room's conversation (render threads read; one lock)

nonisolated final class AuditionRoom: @unchecked Sendable {
    private let lock = NSLock()
    private var faces: [SIMD3<Float>] = []
    private weak var camera: SCNNode?
    private var speaker = -1
    private var speakingUntil: CFTimeInterval = 0
    private var nextTurnAt: CFTimeInterval = 0
    private var lastSpeaker = -1
    private var lastEnded: CFTimeInterval = 0
    private var sat = 0
    private var leaderID = -1

    private var slamTime: CFTimeInterval = 0
    /// Oct 12: the telephone slams its receiver down -- everyone flinches.
    func slam(_ now: CFTimeInterval) { lock.withLock { slamTime = now } }
    var lastSlam: CFTimeInterval { lock.withLock { slamTime } }

    func setLeader(_ id: Int) { lock.withLock { leaderID = id } }
    var leader: Int { lock.withLock { leaderID } }

    // Oct 12 (THE BOX meeting): cast members not (yet) in the room.
    private var absent: Set<Int> = []
    func setPresent(_ id: Int, _ present: Bool) { lock.withLock { if present { absent.remove(id) } else { absent.insert(id) } } }
    func isPresent(_ id: Int) -> Bool { lock.withLock { !absent.contains(id) } }

    func reset(camera: SCNNode?) {
        lock.withLock {
            absent = []
            self.camera = camera
            faces = []
            speaker = -1
            nextTurnAt = CACurrentMediaTime() + 2.5
            sat = 0
        }
    }
    func setFaces(_ f: [SIMD3<Float>]) { lock.withLock { faces = f } }
    func face(_ i: Int) -> SIMD3<Float>? { lock.withLock { faces.indices.contains(i) ? faces[i] : nil } }
    var count: Int { lock.withLock { faces.count } }
    var playerEye: SIMD3<Float>? {
        let cam = lock.withLock { camera }
        guard let cam else { return nil }
        let p = cam.presentation.worldPosition
        return SIMD3<Float>(p.x, p.y, p.z)
    }
    func playerSat() { lock.withLock { sat += 1 } }
    var satCount: Int { lock.withLock { sat } }

    /// Who is talking now (if anyone).
    func currentSpeaker(_ now: CFTimeInterval) -> Int? {
        lock.withLock { now < speakingUntil ? speaker : nil }
    }
    /// The last phrase that ended: who, and when.
    var lastPhrase: (speaker: Int, ended: CFTimeInterval) { lock.withLock { (lastSpeaker, lastEnded) } }

    /// One voice at a time, with a real pause between phrases.
    // MARK: Oct 12 -- THE BIG REVEAL: while the show runs, the cast is directed

    private var showing = false
    private var focusPoint: SIMD3<Float>?
    private var pendingCues: [Int: [(at: CFTimeInterval, cue: AuditionCue)]] = [:]

    /// The show is on (no idle chatter, no random glances): everyone watches
    /// `focus` (the screen) unless the speaker or a cue says otherwise.
    func setShow(_ on: Bool, focus: SIMD3<Float>?) {
        lock.withLock {
            showing = on
            focusPoint = focus
            if !on { pendingCues = [:]; nextTurnAt = CACurrentMediaTime() + 3 }
        }
    }
    var show: (on: Bool, focus: SIMD3<Float>?) { lock.withLock { (showing, focusPoint) } }
    /// A direction for cast member `id`, `delay` seconds from now.
    func cue(_ id: Int, _ cue: AuditionCue, delay: Double = 0) {
        lock.withLock { pendingCues[id, default: []].append((CACurrentMediaTime() + delay, cue)) }
    }
    /// The directions now due for `id` (render thread).
    func dueCues(_ id: Int, now: CFTimeInterval) -> [AuditionCue] {
        lock.withLock {
            guard let list = pendingCues[id], !list.isEmpty else { return [] }
            let due = list.filter { $0.at <= now }.map(\.cue)
            if !due.isEmpty { pendingCues[id] = list.filter { $0.at > now } }
            return due
        }
    }
    /// A directed phrase: it has the floor, whatever the turn-taking says.
    func takeFloor(_ id: Int, length: Double, now: CFTimeInterval) {
        lock.withLock {
            speaker = id
            speakingUntil = now + length
            lastSpeaker = id
            lastEnded = now + length
            nextTurnAt = max(nextTurnAt, now + length + 1.5)
        }
    }

    /// Oct 12 (conversation): nobody starts a turn of their own for a while
    /// (a directed exchange has the floor).
    func hold(_ seconds: Double) {
        let now = CACurrentMediaTime()
        lock.withLock { nextTurnAt = max(nextTurnAt, now + seconds) }
    }

    func claimTurn(_ id: Int, length: Double, now: CFTimeInterval) -> Bool {
        lock.withLock {
            guard !absent.contains(id), now >= nextTurnAt, now >= speakingUntil else { return false }
            speaker = id
            speakingUntil = now + length
            lastSpeaker = id
            lastEnded = now + length
            nextTurnAt = now + length + Double.random(in: 2.6...6.5)
            return true
        }
    }
}

// MARK: - Oct 12: a direction for one cast member (THE BIG REVEAL)

nonisolated enum AuditionCue: Sendable {
    case speak(Int)              // one of its own phrases (index into its voices)
    case laugh                   // its laugh
    case react(Int)              // 0 nod, 1 brows up (startled), 2 smile, 3 doubt, 4 delight
    case look(Int, Double)       // at cast member n (-1 the player, -2 the screen) for so many seconds
    case gesture(Double)         // the Telephone: the receiver raised toward the screen, for so long
    case slam                    // the Telephone: receiver up -- and down
    case snap                    // the Camera: a picture
    case fiddle                  // the Television: adjusts its rabbit ears
}

// MARK: - How each one behaves

nonisolated struct AuditionStyle: Sendable {
    enum Mouth: Sendable { case none, hinge(Float), scale }
    enum Quirk: Sendable { case commodore, crane, proscenium, cloche, aspic, tinky, juanita, safe, stove, vacuum, accordion, mailbox
                           case telephone, viewmaster, flashcube, television, lp, roadmap, dymo
                           case camera }                // (Oct 19, Stage A: rolodex and rolodex2 retired)
    var quirk: Quirk
    var mouth: Mouth
    var facesMinusZ = false
    var headLimit: Float = 0.6          // radians either way
    var headShare: Float = 0.6          // how much of a look the head takes (the eyes do the rest)
    var turnRate: Float = 4
    var lidRest: Float = 0
    var lidClose: Float = 1.3
    var browLift: Float = 0.01          // model units
    var blink: ClosedRange<Double> = 2.5...6
    var talk: ClosedRange<Double> = 9...20
    var glance: ClosedRange<Double> = 2...5
    /// The one the others defer to (round two: the Safe; round three: the Telephone).
    var isLeader = false
    /// Pupils that slide across a flat face (printed, or on a screen) instead of turning.
    var pupilSlide: Float = 0

    // Round three (Oct 12).
    static let telephone = AuditionStyle(quirk: .telephone, mouth: .scale, headLimit: 0.3, headShare: 0.35, turnRate: 1.3,
                                         lidClose: 1.3, browLift: 0, blink: 3.5...8, talk: 18...36, glance: 3.5...7, isLeader: true)
    static let viewmaster = AuditionStyle(quirk: .viewmaster, mouth: .scale, headLimit: 0.45, headShare: 0.5, turnRate: 2.2,
                                          lidClose: 1.35, browLift: 0.01, blink: 2.5...6, talk: 12...24, glance: 3...7)
    static let flashcube = AuditionStyle(quirk: .flashcube, mouth: .scale, headLimit: 0.1, headShare: 0.1, turnRate: 4,
                                         blink: 2...5, talk: 10...22, glance: 1.5...3.5)
    static let television = AuditionStyle(quirk: .television, mouth: .scale, headLimit: 0.3, headShare: 0.35, turnRate: 2.5,
                                          browLift: 0, blink: 3...6, talk: 10...20, glance: 2...5, pupilSlide: 0.014)
    // Round five (Oct 12, refinement).
    static let camera = AuditionStyle(quirk: .camera, mouth: .none, headLimit: 0.45, headShare: 0.5, turnRate: 4,
                                      lidClose: 1.3, browLift: 0.01, blink: 2...5, talk: 10...20, glance: 1.5...4)
    // Round four.
    static let lp = AuditionStyle(quirk: .lp, mouth: .scale, headLimit: 0.3, headShare: 0.4, turnRate: 2,
                                  browLift: 0.004, blink: 3...6, talk: 14...28, glance: 3...6, pupilSlide: 0.005)
    static let roadmap = AuditionStyle(quirk: .roadmap, mouth: .scale, headLimit: 0.35, headShare: 0.5, turnRate: 3,
                                       browLift: 0.008, blink: 2.5...5, talk: 8...16, glance: 2...4, pupilSlide: 0.006)
    static let dymo = AuditionStyle(quirk: .dymo, mouth: .scale, headLimit: 0.5, headShare: 0.6, turnRate: 6,
                                    lidClose: 1.3, browLift: 0.006, blink: 2...4, talk: 9...18, glance: 1...2.5)

    // Round two.
    static let safe = AuditionStyle(quirk: .safe, mouth: .scale, headLimit: 0.35, headShare: 0.4, turnRate: 1.2,
                                    lidClose: 1.35, browLift: 0.012, blink: 4...9, talk: 24...45, glance: 4...8, isLeader: true)
    static let stove = AuditionStyle(quirk: .stove, mouth: .hinge(0.6), headLimit: 0.25, headShare: 0.3, turnRate: 2,
                                     lidClose: 0.95, browLift: 0.012, blink: 3...7, talk: 12...24, glance: 3...7)
    static let vacuum = AuditionStyle(quirk: .vacuum, mouth: .scale, headLimit: 0.5, headShare: 0.6, turnRate: 5,
                                      lidClose: 1.6, browLift: 0.01, blink: 1.8...4, talk: 11...22, glance: 1.2...3)
    static let accordion = AuditionStyle(quirk: .accordion, mouth: .hinge(0.45), headLimit: 0.3, headShare: 0.4, turnRate: 2.2,
                                         lidClose: 0.95, browLift: 0.01, blink: 3...6, talk: 14...28, glance: 3...6)
    static let mailbox = AuditionStyle(quirk: .mailbox, mouth: .hinge(0.7), headLimit: 0.35, headShare: 0.45, turnRate: 4.5,
                                       lidClose: 1.3, browLift: 0.014, blink: 2...4.5, talk: 7...15, glance: 1.5...3.5)

    static let commodore = AuditionStyle(quirk: .commodore, mouth: .hinge(-0.5), headLimit: 0.5, headShare: 0.5, turnRate: 2,
                                         lidClose: 1.4, browLift: 0.012, blink: 3...7, talk: 14...28, glance: 3...7)
    static let crane = AuditionStyle(quirk: .crane, mouth: .hinge(0.55), headLimit: 0.9, headShare: 0.75, turnRate: 9,
                                     lidClose: 1.35, browLift: 0.006, blink: 1.8...4.5, talk: 7...15, glance: 1.2...3)
    static let proscenium = AuditionStyle(quirk: .proscenium, mouth: .scale, headLimit: 0.12, headShare: 0.2, turnRate: 3,
                                          browLift: 0.012, blink: 3...6, talk: 8...17, glance: 2...5)
    static let cloche = AuditionStyle(quirk: .cloche, mouth: .scale, headLimit: 0.5, headShare: 0.55, turnRate: 2.5,
                                      lidClose: 1.25, browLift: 0.006, blink: 2.5...5.5, talk: 16...32, glance: 2.5...6)
    static let aspic = AuditionStyle(quirk: .aspic, mouth: .scale, headLimit: 0.3, headShare: 0.35, turnRate: 3,
                                     lidClose: 1.3, browLift: 0.008, blink: 2...5, talk: 10...22, glance: 2...5)
    static let tinky = AuditionStyle(quirk: .tinky, mouth: .none, facesMinusZ: true, headLimit: 0.7, headShare: 0.9, turnRate: 6,
                                     blink: 100...200, talk: 14...30, glance: 1.5...4)
    static let juanita = AuditionStyle(quirk: .juanita, mouth: .none, headLimit: 0.45, headShare: 0.55, turnRate: 2.5,
                                       blink: 3...6.5, talk: 22...40, glance: 3...6)
}

// MARK: - An actor at the table

nonisolated final class AuditionActor: @unchecked Sendable {
    struct Rig {
        var head: SCNNode?
        var eyes: [SCNNode] = []
        var pupils: [(SCNNode, SCNVector3)] = []     // node, rest position
        var lids: [SCNNode] = []
        var brows: [(SCNNode, SCNVector3, Float)] = []   // node, rest position, side (+1 = its left)
        var mouth: SCNNode?
        var extras: [String: (SCNNode, SCNVector3, SCNVector3)] = [:]   // node, rest position, rest euler
        var glow: SCNMaterial?                       // the Stove's coals
        var puffs: [SCNNode] = []                    // the Stove's smoke
        // Oct 12 (rounds three and four).
        var materials: [String: SCNMaterial] = [:]   // bulbs, screen glow, irises
        var materialRest: [String: UIColor] = [:]
        var light: SCNLight?                         // the flashcube's flash
        var overlay: SCNNode?                        // the television's static
    }

    /// Finds the face rig by the asset's joint names.
    static func rig(_ model: SCNNode, prefix p: String) -> Rig {
        func n(_ name: String) -> SCNNode? { model.childNode(withName: name, recursively: true) }
        var rig = Rig()
        if p == "admin" {                                      // Juanita
            rig.head = n("adminHead")
            if let eyes = n("adminEyes") { rig.eyes = [eyes] }
            if let pupils = n("adminPupils") { rig.pupils = [(pupils, pupils.position)] }
            for name in ["juanitaNeck1", "juanitaNeck2"] { if let x = n(name) { rig.extras[name] = (x, x.position, x.eulerAngles) } }
            return rig
        }
        if p == "tinCanRat" {                                  // Mr. Tinky
            rig.head = n("tinCanRatBody")
            for name in ["tinCanRatEar0", "tinCanRatEar1", "tinCanRatTail"] { if let x = n(name) { rig.extras[name] = (x, x.position, x.eulerAngles) } }
            return rig
        }
        rig.head = n("\(p)Head")
        for s in ["L", "R"] {
            if let e = n("\(p)Eye\(s)") { rig.eyes.append(e) }
            if let x = n("\(p)Pupil\(s)") { rig.pupils.append((x, x.position)) }
            if let x = n("\(p)Lid\(s)") { rig.lids.append(x) }
            if let x = n("\(p)Brow\(s)") { rig.brows.append((x, x.position, s == "L" ? 1 : -1)) }
        }
        rig.mouth = n("\(p)Mouth")
        for name in ["craneWingL", "craneWingR", "craneNeck", "procCurtainL", "procCurtainR",
                     "safeDial", "safeHandle", "stovePipe", "vacTrunk1", "vacTrunk2", "vacTrunk3", "vacEarL", "vacEarR",
                     "accBellows", "accArmL", "accArmR", "mailFlag"] {
            if let x = n(name) { rig.extras[name] = (x, x.position, x.eulerAngles) }
        }
        return rig
    }

    let id: Int
    let name: String
    let holder: SCNNode
    let rig: Rig
    let style: AuditionStyle
    let voices: [AuditionClip]
    let laughs: [AuditionClip]
    let room: AuditionRoom
    private let toLocal: simd_float4x4
    private let headRestPos: SCNVector3
    private var dial: Float = 0
    private var wantDial: Float = 0
    private var flag: Float = 0
    private var sighAt: Double = -100
    private var sniffUntil: Double = -1
    private var puffAt: [Double] = []
    private var twitchAt: Double = -100
    private let headRest: SCNVector3
    private let headY: Float

    private var lastTime: CFTimeInterval = 0
    private var clock: Double = 0
    private var target: SIMD3<Float>?
    private var targetIsSpeaker = -2
    private var nextGlance: Double
    private var headYaw: Float = 0
    private var headPitch: Float = 0
    private var eyeYaw: Float = 0
    private var eyePitch: Float = 0
    private var nextBlink: Double
    private var blinkAt: Double = -10
    private var doubleBlink = false
    private var nextTalk: Double
    private var talking: AuditionClip?
    private var lastRemark: SCNAudioSource?        // Oct 12 (Telephone voice): its last remark of its own
    private var talkStart: Double = 0
    private var talkTarget: SIMD3<Float>?
    private var browRaise: Float = 0
    private var browTilt: Float = 0
    private var wantRaise: Float = 0
    private var wantTilt: Float = 0
    private var smile: Float = 0
    private var wantSmile: Float = 0
    private var reaction: (start: Double, kind: Int)?
    private var laughSoon = false
    private var seenPhraseEnd: CFTimeInterval = 0
    private var seenSat = 0
    private var satLookUntil: Double = -1
    private var energy: Float = 0                 // the jelly's wobble, the tail's wag
    private var quirkClock = Double.random(in: 2...6)
    private var quirkUntil: Double = -1
    private var tilt: Float = 0
    private var wantTiltHead: Float = 0
    // Oct 12: the mechanisms of rounds three and four.
    private var mech: Float = 0                   // a dial / a reel / the card drum / a letter wheel
    private var mechTarget: Float = 0
    private var eventAt: Double = -100            // a click, a flash, a slam, a spin
    private var eventKind = 0
    private var slamPlayed = false
    private var seenBlink: Double = -10
    private var seenSlam: CFTimeInterval = 0
    private var seenReaction: Double = -100
    private var turns = 0                         // the flashcube's quarter turns
    private var burned: [Bool] = [false, false, false, true]
    private var allBurnedAt: Double = -1
    private var sideYaw: Float = 0
    private var unfold: Float = 0
    private var foldError: (panel: Int, angle: Float, until: Double) = (0, 0, 0)
    private var discY: Float = 0
    private var spin: Float = 0
    private var staticUntil: Double = -1
    private var tape: Float = 0
    private var squeezed = false
    private var irisIndex = 0
    private var flashShown: Float = 0
    private var lastNod: Float = 0
    // Oct 12 (THE BIG REVEAL): directions.
    private var lookOverride: (who: Int, until: Double)?
    private var gestureUntil: Double = -1
    private var gestureStart: Double = -1
    private var forceSnap = false
    private var fiddleAt: Double = -100

    init(id: Int, name: String, holder: SCNNode, rig: Rig, style: AuditionStyle, voices: [AuditionClip], laughs: [AuditionClip] = [],
         room: AuditionRoom) {
        self.id = id
        self.name = name
        self.holder = holder
        self.rig = rig
        self.style = style
        self.voices = voices
        self.laughs = laughs
        self.room = room
        toLocal = simd_inverse(holder.simdWorldTransform)
        headRest = rig.head?.eulerAngles ?? SCNVector3Zero
        headRestPos = rig.head?.position ?? SCNVector3Zero
        if let anchor = rig.eyes.first ?? rig.head { headY = holder.convertPosition(anchor.worldPosition, from: nil).y } else { headY = 0.4 }
        puffAt = Array(repeating: -100, count: rig.puffs.count)
        nextGlance = Double.random(in: 0.5...3)
        nextBlink = Double.random(in: style.blink)
        nextTalk = Double.random(in: 3...(style.talk.lowerBound + 6))
        seenSat = room.satCount
        seenSlam = room.lastSlam
    }

    func tickAction() -> SCNAction {
        SCNAction.customAction(duration: 1) { _, _ in self.tick() }
    }

    // MARK: The beat

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(lastTime == 0 ? 1.0 / 60 : min(max(now - lastTime, 0), 1.0 / 20))
        lastTime = now
        guard dt > 0 else { return }
        // Oct 12 (THE BOX meeting): not here yet (still to arrive, or arriving) -- no life.
        guard room.isPresent(id) else { lastTime = 0; return }
        clock += Double(dt)
        let speaker = room.currentSpeaker(now)

        // The player just sat down: everyone has a look at the newcomer.
        let sat = room.satCount
        if sat != seenSat {
            seenSat = sat
            satLookUntil = clock + 0.3 * Double(id % 4) + Double.random(in: 2.2...3.4)
            wantRaise = 0.6
        }
        // Oct 12 (THE BIG REVEAL): the show's directions for this one.
        let show = room.show
        for cue in room.dueCues(id, now: now) {
            switch cue {
            case .speak(let i): if voices.indices.contains(i) { direct(voices[i], now: now) }
            case .laugh: if let clip = laughs.randomElement() ?? voices.first { direct(clip, now: now) }
            case .react(let k): reaction = (clock, k); if k == 4 || k == 2 { energy = max(energy, 0.7) }
            case .look(let who, let seconds): lookOverride = (who, clock + seconds)
            case .gesture(let seconds): gestureStart = clock; gestureUntil = clock + seconds
            case .slam: if style.quirk == .telephone { eventKind = 2; eventAt = clock; slamPlayed = false }
            case .snap: forceSnap = true
            case .fiddle: fiddleAt = clock
            }
        }
        // A phrase just ended: sometimes a reaction (silent, or the reply).
        let last = room.lastPhrase
        if last.ended != seenPhraseEnd, now >= last.ended, last.speaker >= 0 {
            seenPhraseEnd = last.ended
            let fromLeader = last.speaker == room.leader
            if !show.on, last.speaker != id, Float.random(in: 0...1) < (fromLeader ? 0.75 : 0.4) {
                // The leader has spoken: mostly nods and raised brows.
                let kind = fromLeader ? (Float.random(in: 0...1) < 0.6 ? 0 : 1) : Int.random(in: 0...4)
                reaction = (clock + Double.random(in: 0.1...0.6), kind)
                if kind == 4 { laughSoon = true }
            }
            if last.speaker != id, Float.random(in: 0...1) < 0.25 { nextTalk = min(nextTalk, clock + Double.random(in: 2.8...5)) }
        }

        // Oct 12: the receiver slammed down -- everyone flinches, brows up.
        let slam = room.lastSlam
        if slam != seenSlam {
            seenSlam = slam
            if style.quirk != .telephone { reaction = (clock + Double.random(in: 0.04...0.2), 1); energy = max(energy, 0.8) }
        }

        // Whom to look at.
        if let talking {
            if clock - talkStart > talking.duration + 0.2 { self.talking = nil; wantRaise = 0 }
        }
        if let o = lookOverride, clock < o.until {
            // a directed look
            if o.who == -1 { target = room.playerEye } else if o.who == -2 { target = show.focus } else { target = room.face(o.who) }
            targetIsSpeaker = -2
        } else if show.on, talking == nil {
            // the show: the presenter faces his audience; everyone else watches
            // whoever is speaking, or the screen
            lookOverride = nil
            if style.isLeader {
                target = room.playerEye
            } else if let s = speaker, s != id {
                target = room.face(s)
            } else {
                target = show.focus
            }
            targetIsSpeaker = -2
            nextGlance = clock + 2
        } else if talking != nil {
            target = talkTarget
        } else if clock < satLookUntil, let eye = room.playerEye {
            target = eye
        } else if let s = speaker, s != id {
            if targetIsSpeaker != s || target == nil { target = room.face(s); targetIsSpeaker = s; wantRaise = 0.25 }
        } else if clock >= nextGlance {
            nextGlance = clock + Double.random(in: style.glance)
            targetIsSpeaker = -2
            let r = Float.random(in: 0...1)
            let leader = room.leader
            if r < 0.22, let eye = room.playerEye { target = eye }
            else if r < 0.42, leader >= 0, leader != id, let face = room.face(leader) { target = face }   // they keep an eye on the boss
            else if r < 0.88, room.count > 1 {
                var other = Int.random(in: 0..<room.count)
                if other == id { other = (other + 1) % room.count }
                target = room.face(other)
            } else {
                target = nil                                       // down at the table / straight ahead
            }
            if Float.random(in: 0...1) < 0.3 { wantRaise = Float.random(in: 0.15...0.4) } else { wantRaise = 0 }
            wantTilt = 0
            wantSmile = 0
        }

        // A laugh (a reaction): only if the room is quiet enough for it.
        if laughSoon, talking == nil, let r = reaction, clock >= r.start {
            laughSoon = false
            if let clip = laughs.randomElement(), room.claimTurn(id, length: clip.duration, now: now) {
                talking = clip
                talkStart = clock
                talkTarget = target
                CritterAudio.play(clip.source, on: rig.head ?? holder)
                energy = 1
            } else {
                reaction = (r.start, 2)                                // a smile instead
            }
        }
        // Talking: a turn now and then (one voice in the room at a time).
        if talking == nil, clock >= nextTalk, !voices.isEmpty, !show.on {
            var clip = voices.randomElement()!
            // Oct 12 (Telephone voice): never the same remark twice running (the
            // Telephone only -- every other voice chooses exactly as before).
            if name == "AuditionTelephone", voices.count > 1, let last = lastRemark, clip.source === last,
               let i = voices.firstIndex(where: { $0.source === last }) {
                clip = voices[(i + 1 + Int.random(in: 0..<(voices.count - 1))) % voices.count]
            }
            if room.claimTurn(id, length: clip.duration, now: now) {
                if name == "AuditionTelephone" { lastRemark = clip.source }
                talking = clip
                talkStart = clock
                // To someone at the table, or to the newcomer now and then.
                if Float.random(in: 0...1) < 0.25, let eye = room.playerEye { talkTarget = eye }
                else if room.count > 1 {
                    var other = Int.random(in: 0..<room.count)
                    if other == id { other = (other + 1) % room.count }
                    talkTarget = room.face(other)
                }
                CritterAudio.play(clip.source, on: rig.head ?? holder)
                nextTalk = clock + clip.duration + Double.random(in: style.talk)
                energy = 1
            } else {
                nextTalk = clock + Double.random(in: 1...3)
            }
        }

        aim(dt: dt)
        face(dt: dt)
        quirk(dt: dt)
    }

    // MARK: Looking

    private func aim(dt: Float) {
        var yaw: Float = 0, pitch: Float = 0
        if let t = target {
            let l = toLocal * SIMD4<Float>(t.x, t.y, t.z, 1)
            let x = style.facesMinusZ ? -l.x : l.x
            let z = style.facesMinusZ ? -l.z : l.z
            yaw = atan2(x, z)
            pitch = atan2(l.y - headY, max(0.2, sqrt(x * x + z * z)))
        }
        yaw = max(-1.6, min(1.6, yaw))
        let wantHead = max(-style.headLimit, min(style.headLimit, yaw * style.headShare))
        let k = min(1, dt * style.turnRate)
        headYaw += (wantHead - headYaw) * k
        headPitch += (pitch * 0.35 - headPitch) * k
        let ke = min(1, dt * 14)                                    // eyes lead, quickly
        eyeYaw += (max(-0.55, min(0.55, yaw - headYaw)) - eyeYaw) * ke
        eyePitch += (max(-0.35, min(0.35, pitch - headPitch)) - eyePitch) * ke
    }

    // MARK: The face

    private func face(dt: Float) {
        // Reactions (silent): 0 a nod, 1 eyebrows up, 2 a smile, 3 one sceptical brow.
        var nod: Float = 0
        if let r = reaction {
            let u = clock - r.start
            if u >= 0 {
                switch r.kind {
                case 0: nod = 0.18 * Float(sin(.pi * min(1, u / 0.7)))
                case 1: wantRaise = 1
                case 2, 4: wantSmile = 1; wantRaise = max(wantRaise, 0.3)
                default: wantTilt = -0.6; wantRaise = 0.5
                }
                if style.quirk == .aspic || style.quirk == .tinky { energy = max(energy, 0.6) }
                if u > 1.8 { reaction = nil; wantRaise = 0; wantSmile = 0; wantTilt = 0 }
            }
        }
        lastNod = nod
        // Mouth: driven by the voice's own loudness.
        var open: Float = 0
        if let talking {
            let i = Int((clock - talkStart) / 0.02)
            if i >= 0, i < talking.envelope.count { open = talking.envelope[i] }
            wantRaise = max(wantRaise, open * 0.5)
        }
        let k = min(1, dt * 8)
        browRaise += (wantRaise - browRaise) * k
        browTilt += (wantTilt - browTilt) * k
        smile += (wantSmile - smile) * min(1, dt * 5)

        // Head.
        if let head = rig.head {
            let bob = style.quirk == .crane ? Float(sin(clock * 2.3)) * 0.02 : 0
            head.eulerAngles = SCNVector3(headRest.x - headPitch * (style.facesMinusZ ? -1 : 1) + nod + bob,
                                          headRest.y + headYaw, headRest.z + tilt)
        }
        // Eyes.
        for (pupil, rest) in rig.pupils {
            if style.quirk == .juanita {
                pupil.position = SCNVector3(rest.x + eyeYaw * 0.024, rest.y + eyePitch * 0.012, rest.z)
            } else if style.pupilSlide > 0 {
                pupil.position = SCNVector3(rest.x + eyeYaw * style.pupilSlide, rest.y + eyePitch * style.pupilSlide * 0.7, rest.z)
            } else {
                pupil.eulerAngles = SCNVector3(-eyePitch, eyeYaw, 0)
            }
        }
        // Blinks.
        if clock >= nextBlink {
            blinkAt = clock
            doubleBlink = Float.random(in: 0...1) < 0.18
            nextBlink = clock + Double.random(in: style.blink)
        }
        var shut: Float = 0
        let b = clock - blinkAt
        if b >= 0, b < 0.15 { shut = Float(sin(.pi * b / 0.15)) }
        else if doubleBlink, b >= 0.25, b < 0.4 { shut = Float(sin(.pi * (b - 0.25) / 0.15)) }
        let wide = browRaise * 0.25                                 // surprise opens the eyes a little
        if rig.lids.isEmpty {
            for e in rig.eyes { e.scale = SCNVector3(1, 1 - 0.88 * shut, 1) }
        } else {
            for lid in rig.lids {
                lid.eulerAngles.x = style.lidRest - wide + (style.lidClose - style.lidRest + wide) * shut
            }
        }
        // Brows.
        for (brow, rest, side) in rig.brows {
            let sceptic = side > 0 ? max(0, -browTilt) : 0          // one brow (its left) goes up
            brow.position = SCNVector3(rest.x, rest.y + style.browLift * (browRaise + sceptic * 0.8), rest.z)
            brow.eulerAngles.z = -side * browTilt * 0.35
        }
        // Mouth.
        if let mouth = rig.mouth {
            switch style.mouth {
            case .hinge(let full): mouth.eulerAngles.x = full * open
            case .scale: mouth.scale = SCNVector3(1 + smile * 0.3 - open * 0.15, 1 + open * 2.2 - smile * 0.25, 1)
            case .none: break
            }
        }
    }

    // MARK: Personal habits

    private func quirk(dt: Float) {
        energy = max(0, energy - dt * 0.6)
        let t = Float(clock)
        switch style.quirk {
        case .aspic:
            let w = 0.006 * sin(t * 3.1) + 0.035 * energy * sin(t * 17)
            rig.head?.scale = SCNVector3(1 + w, 1 - w * 1.4, 1 + w)
        case .cloche:
            // The cloud breathes, slowly, inside its jar.
            rig.head?.scale = SCNVector3(1 + 0.014 * sin(t * 0.9), 1 + 0.018 * sin(t * 0.9 + 1), 1 + 0.01 * sin(t * 0.7))
        case .crane:
            // Bird tilts: a quick cock of the head, held, now and then.
            if clock >= quirkClock {
                wantTiltHead = Float.random(in: 0...1) < 0.55 ? Float.random(in: -0.35...0.35) : 0
                quirkClock = clock + Double.random(in: 1.2...3.5)
            }
            tilt += (wantTiltHead - tilt) * min(1, dt * 12)
            let flap = talking != nil ? 0.18 + 0.12 * sin(t * 9) : 0.03 * sin(t * 1.1)
            for (name, side) in [("craneWingL", Float(1)), ("craneWingR", Float(-1))] {
                if let e = rig.extras[name] { e.0.eulerAngles = SCNVector3(e.2.x, e.2.y, e.2.z + side * flap) }
            }
        case .proscenium:
            // The curtains: drawn a little when it is shy, wide when it talks.
            if clock >= quirkClock {
                quirkUntil = Float.random(in: 0...1) < 0.35 ? clock + Double.random(in: 1.2...2.4) : clock
                quirkClock = clock + Double.random(in: 7...14)
            }
            let shy: Float = clock < quirkUntil ? 1 : 0
            let wide: Float = talking != nil ? 1 : 0
            tilt += (shy * 0.75 - wide * 0.15 - tilt) * min(1, dt * 4)
            for (name, side) in [("procCurtainL", Float(1)), ("procCurtainR", Float(-1))] {
                if let e = rig.extras[name] {
                    e.0.position = SCNVector3(e.1.x - side * 0.075 * tilt, e.1.y, e.1.z)
                }
            }
            if let head = rig.head { head.eulerAngles.z = 0 }
        case .commodore:
            // A slow harrumph: brows down, the faceplate rattles shut.
            if clock >= quirkClock {
                if talking == nil, Float.random(in: 0...1) < 0.4 { reaction = (clock, 3) }
                quirkClock = clock + Double.random(in: 9...16)
            }
            tilt = 0
        case .tinky:
            let wag = (0.12 + 0.6 * energy) * sin(t * (10 + 6 * energy))
            if let e = rig.extras["tinCanRatTail"] { e.0.eulerAngles = SCNVector3(e.2.x, e.2.y + wag, e.2.z) }
            let perk = 0.12 * browRaise + 0.05 * sin(t * 0.7)
            for (name, side) in [("tinCanRatEar0", Float(-1)), ("tinCanRatEar1", Float(1))] {
                if let e = rig.extras[name] { e.0.eulerAngles = SCNVector3(e.2.x - perk, e.2.y, e.2.z + side * 0.05 * sin(t * 1.7)) }
            }
            if clock >= quirkClock {
                wantTiltHead = Float.random(in: 0...1) < 0.4 ? Float.random(in: -0.25...0.25) : 0
                quirkClock = clock + Double.random(in: 2...5)
            }
            tilt += (wantTiltHead - tilt) * min(1, dt * 6)
            if talking != nil { energy = max(energy, 0.8) }
        case .safe:
            // Thinking: the combination dial turns a few clicks (the monocle
            // stays put); the brass moustache twitches; the iron box settles.
            if clock >= quirkClock {
                if talking == nil { wantDial += Float(Int.random(in: -6...6)) * (2 * .pi / 20) }
                if Float.random(in: 0...1) < 0.5 { twitchAt = clock }
                quirkClock = clock + Double.random(in: 5...11)
            }
            dial += (wantDial - dial) * min(1, dt * 3)
            let click = (dial / (2 * .pi / 20)).rounded() * (2 * .pi / 20)        // it moves in clicks
            if let e = rig.extras["safeDial"] { e.0.eulerAngles = SCNVector3(e.2.x, e.2.y, e.2.z + click) }
            let tw = clock - twitchAt
            let twitch: Float = tw >= 0 && tw < 0.5 ? 0.16 * sin(Float(tw) * 25) : 0
            if let e = rig.extras["safeHandle"] { e.0.eulerAngles = SCNVector3(e.2.x, e.2.y, e.2.z + twitch + (talking != nil ? 0.05 * sin(t * 9) : 0)) }
        case .stove:
            // The coals glow with its mood; it heaves; smoke when it grumbles.
            rig.glow?.emission.intensity = CGFloat(0.65 + 0.12 * sin(t * 2.3) + 0.5 * energy)
            rig.head?.scale = SCNVector3(1 + 0.012 * sin(t * 0.8), 1 + 0.018 * sin(t * 0.8), 1 + 0.012 * sin(t * 0.8))
            if talking != nil || reaction?.kind == 3, clock >= quirkClock, !puffAt.isEmpty {
                if let i = puffAt.firstIndex(where: { clock - $0 > 2.2 }) { puffAt[i] = clock }
                quirkClock = clock + Double.random(in: 0.5...1.0)
            }
            for (i, puff) in rig.puffs.enumerated() {
                let u = Float((clock - puffAt[i]) / 2.2)
                if u >= 0, u < 1 {
                    puff.position = SCNVector3(0.02 * sin(Float(i) * 2 + t), u * 0.28, u * 0.06)
                    let g = 1 + u * 1.6
                    puff.scale = SCNVector3(g, g, g)
                    puff.opacity = CGFloat(0.55 * (1 - u))
                } else {
                    puff.opacity = 0
                }
            }
            if let e = rig.extras["stovePipe"] { e.0.eulerAngles = SCNVector3(e.2.x, e.2.y, e.2.z + 0.03 * energy * sin(t * 11)) }
            if talking == nil, clock >= quirkClock, Float.random(in: 0...1) < 0.0006 { reaction = (clock, 3) }   // a grumble at nothing
        case .vacuum:
            // The trunk: swaying, sniffing toward whoever is talking, up when it talks.
            let s = room.currentSpeaker(CACurrentMediaTime())
            if let s, s != id, clock >= quirkClock { sniffUntil = clock + 0.8; quirkClock = clock + Double.random(in: 2...4) }
            let sniff: Float = clock < sniffUntil ? 0.09 * sin(t * 30) : 0
            let up: Float = talking != nil ? -0.3 : (s != nil && s != id ? -0.12 : 0)
            let names = ["vacTrunk1", "vacTrunk2", "vacTrunk3"]
            for (k, name) in names.enumerated() {
                guard let e = rig.extras[name] else { continue }
                let sway = (0.06 + 0.03 * Float(k)) * sin(t * 0.8 + Float(k) * 0.7)
                e.0.eulerAngles = SCNVector3(e.2.x + sway + up * (1 - Float(k) * 0.2) + (k == 2 ? sniff : 0), e.2.y, e.2.z)
            }
            let flap = 0.04 + 0.28 * energy
            for (name, side) in [("vacEarL", Float(1)), ("vacEarR", Float(-1))] {
                if let e = rig.extras[name] { e.0.eulerAngles = SCNVector3(e.2.x, e.2.y, e.2.z + side * flap * sin(t * 12)) }
            }
            if let r = reaction, r.kind == 1 || r.kind == 4 { energy = max(energy, 0.7) }
        case .accordion:
            // It breathes with its bellows; now and then a great sigh.
            if clock >= quirkClock {
                if talking == nil, Float.random(in: 0...1) < 0.45 { sighAt = clock }
                quirkClock = clock + Double.random(in: 12...22)
            }
            var b: Float = 1 + 0.045 * sin(t * 0.9)
            let sg = clock - sighAt
            if sg >= 0, sg < 3.2 {
                b += sg < 1.1 ? 0.22 * Float(sg / 1.1) : 0.22 - 0.38 * min(1, Float((sg - 1.1) / 1.4)) + (sg > 2.5 ? 0.16 * Float((sg - 2.5) / 0.7) : 0)
                wantTilt = sg < 2.5 ? 0.6 : 0                         // sad brows through it
            }
            if let talking {
                let i = Int((clock - talkStart) / 0.02)
                if i >= 0, i < talking.envelope.count { b += 0.12 * talking.envelope[i] }
            }
            if let e = rig.extras["accBellows"] { e.0.scale = SCNVector3(1, b, 1) }
            if let head = rig.head { head.position = SCNVector3(headRestPos.x, headRestPos.y + (b - 1) * 0.208, headRestPos.z) }
            for (name, side) in [("accArmL", Float(1)), ("accArmR", Float(-1))] {
                if let e = rig.extras[name] { e.0.eulerAngles = SCNVector3(e.2.x + 0.07 * sin(t * 1.1 + side), e.2.y, e.2.z) }
            }
        case .mailbox:
            // News! The flag goes up when it talks or something's just been said;
            // it leans in toward whoever is talking.
            let s = room.currentSpeaker(CACurrentMediaTime())
            let wantFlag: Float = (talking != nil || energy > 0.35) ? 1 : 0
            flag += (wantFlag - flag) * min(1, dt * 6)
            if let e = rig.extras["mailFlag"] { e.0.eulerAngles = SCNVector3(e.2.x + flag * (.pi / 2) + 0.05 * flag * sin(t * 14), e.2.y, e.2.z) }
            let lean: Float = (s != nil && s != id) ? (eyeYaw > 0 ? 0.07 : -0.07) : 0
            tilt += (lean - tilt) * min(1, dt * 3)
            if let r = reaction, clock - r.start < 0.2 { energy = max(energy, 0.6) }
        case .juanita:
            // Her neck rises a little with interest (and when she chimes in).
            let rise: Float = 0.035 * browRaise + (talking != nil ? 0.03 : 0)
            for name in ["juanitaNeck1", "juanitaNeck2"] {
                if let e = rig.extras[name] { e.0.position = SCNVector3(e.1.x, e.1.y + rise, e.1.z) }
            }
        // MARK: Oct 12 (refinement) -- round five
        case .camera:
            // The camera itself: it zooms to look closer at whoever is talking,
            // and now and then takes a picture -- click, a soft flash, the lever
            // wound on. (Startled or laughing: it might take one then too.)
            var snap = false
            let directed = room.show.on                                   // Oct 12: in the show, only when told
            if let k = reactionBegan(), k == 1 || k == 4, !directed, Float.random(in: 0...1) < 0.5 { snap = true }
            if clock >= quirkClock {
                if talking == nil, !directed, Float.random(in: 0...1) < 0.3 { snap = true }
                quirkClock = clock + Double.random(in: 12...24)
            }
            if forceSnap { snap = true; forceSnap = false }               // Oct 12: directed
            if snap, eventKind == 0 {
                eventKind = 1
                eventAt = clock
                nextBlink = min(nextBlink, clock)                          // it blinks as the shutter goes
                if let click = AuditionVoices.cameraShutter.first { CritterAudio.play(click.source, on: rig.head ?? holder) }
            }
            let u = Float(clock - eventAt)
            var flashLevel: Float = 0
            var wind: Float = 0
            if eventKind == 1 {
                flashLevel = u < 0.08 ? 1 : max(0, 1 - (u - 0.08) / 0.1)
                if u > 0.35 && u < 1.0 { wind = sin(.pi * (u - 0.35) / 0.65) }
                if u > 1.1 { eventKind = 0 }
            }
            if flashLevel > 0 || flashShown > 0 {
                rig.materials["camBulb"]?.emission.contents = UIColor(white: CGFloat(flashLevel), alpha: 1)
                rig.light?.intensity = CGFloat(180 * flashLevel)
                flashShown = flashLevel
            }
            if let e = rig.extras["camLever"] { e.0.eulerAngles = SCNVector3(e.2.x, e.2.y - 0.9 * wind, e.2.z) }
            let s = room.currentSpeaker(CACurrentMediaTime())
            var zoom: Float = 0.004 * sin(t * 0.7)
            if talking != nil { zoom = 0.012 + 0.01 * voiceLevel() }
            else if let s, s != id { zoom = 0.035 }
            mech += (zoom - mech) * min(1, dt * 4)
            // the barrel extends out of the body (stretched from its mount, never detached)
            if let e = rig.extras["camLens"] { e.0.scale = SCNVector3(1, 1, 1 + mech / 0.064) }
            // the aperture opens evenly with its voice
            let k = min(2.6, 1 + 1.6 * voiceLevel())
            rig.mouth?.scale = SCNVector3(k, k, 1)
        // MARK: Oct 12 -- round three
        case .telephone:
            // The dial: now and then it dials (round, then a whirr back);
            // rarely the receiver comes right up -- and is slammed down.
            if clock >= quirkClock, talking == nil, eventKind == 0 {
                let r = Float.random(in: 0...1)
                if r < 0.55, !room.show.on {                          // Oct 12: no idle dialling while presenting
                    mechTarget = Float.random(in: 0.9...2.6); eventKind = 1; eventAt = clock
                } else if r < 0.75, !room.show.on, let slam = AuditionVoices.telephoneSlam.first,
                          room.claimTurn(id, length: 1.2 + slam.duration, now: CACurrentMediaTime()) {
                    eventKind = 2; eventAt = clock; slamPlayed = false
                }
                quirkClock = clock + Double.random(in: 7...15)
            }
            let open = voiceLevel()
            if eventKind == 1 {
                let u = Float(clock - eventAt)
                if u < 0.45 { mech = mechTarget * (u / 0.45) } else { mech = max(0, mech - dt * 2.8); if mech <= 0 { eventKind = 0 } }
            } else {
                mech = max(0, mech - dt * 2.8)
                if talking != nil { mech = max(mech, 0.05 * open) }
            }
            if let e = rig.extras["telDial"] { e.0.rotation = SCNVector4(0, 0.8, 0.6, -mech) }
            var lift: Float = 0.022 * browRaise + 0.012 * open
            var roll: Float = -0.25 * browTilt
            var shake: Float = 0
            if eventKind == 2 {
                let u = Float(clock - eventAt)
                if u < 0.55 {
                    let e = u / 0.55
                    lift = 0.11 * e * e * (3 - 2 * e); roll = 0.18 * e
                } else if u < 1.0 {
                    lift = 0.11; roll = 0.18 + 0.03 * sin(u * 22)
                } else if u < 1.08 {
                    let e = (u - 1.0) / 0.08
                    lift = 0.11 * (1 - e); roll = 0.18 * (1 - e)
                } else {
                    lift = 0; roll = 0
                    if !slamPlayed {
                        slamPlayed = true
                        if let slam = AuditionVoices.telephoneSlam.first { CritterAudio.play(slam.source, on: rig.head ?? holder) }
                        room.slam(CACurrentMediaTime())
                    }
                    shake = u < 1.45 ? 0.006 * sin(u * 70) * (1.45 - u) / 0.37 : 0
                    if u > 1.8 { eventKind = 0 }
                }
            }
            // Oct 12: presenting -- the receiver raised and tipped back toward the screen behind him
            var tipBack: Float = 0
            if eventKind != 2, clock < gestureUntil {
                let g = Float(min(1, (gestureUntil - clock) / 0.4, (clock - gestureStart) / 0.4))
                lift = max(lift, 0.06 * max(0, min(1, g)))
                tipBack = -0.45 * max(0, min(1, g))
            }
            if let e = rig.extras["telHandset"] {
                e.0.position = SCNVector3(e.1.x, e.1.y + lift, e.1.z)
                e.0.eulerAngles = SCNVector3(e.2.x + tipBack, e.2.y, e.2.z + roll)
            }
            if let head = rig.head { head.position = SCNVector3(headRestPos.x, headRestPos.y + abs(shake), headRestPos.z) }
        case .viewmaster:
            // Every blink is a slide change: the lever clicks, the reel turns a
            // frame, and the irises come up a new colour. Delight: a run of clicks.
            if blinkAt != seenBlink, blinkAt > 0 {
                seenBlink = blinkAt
                eventAt = clock
                mechTarget += 2 * .pi / 14
                irisIndex += 1
                let palette: [UIColor] = [UIColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1), UIColor(red: 0.2, green: 0.6, blue: 0.25, alpha: 1),
                                          UIColor(red: 0.95, green: 0.6, blue: 0.15, alpha: 1), UIColor(red: 0.85, green: 0.2, blue: 0.35, alpha: 1),
                                          UIColor(red: 0.35, green: 0.3, blue: 0.8, alpha: 1), UIColor(red: 0.2, green: 0.7, blue: 0.75, alpha: 1)]
                for (k, key) in ["vmIrisL", "vmIrisR"].enumerated() {
                    rig.materials[key]?.diffuse.contents = palette[(irisIndex * 2 + k) % palette.count]
                }
            }
            if let k = reactionBegan(), k == 2 || k == 4 { quirkUntil = clock + 1.3 }
            if clock < quirkUntil, clock - blinkAt > 0.32 { nextBlink = min(nextBlink, clock) }
            mech += (mechTarget - mech) * min(1, dt * 16)
            if let e = rig.extras["vmReel"] { e.0.eulerAngles = SCNVector3(e.2.x, e.2.y, e.2.z - mech) }
            let u = Float(clock - eventAt)
            let press: Float = u >= 0 && u < 0.22 ? 0.5 * sin(.pi * u / 0.22) : 0
            if let e = rig.extras["vmLever"] { e.0.eulerAngles = SCNVector3(e.2.x + press, e.2.y, e.2.z) }
            tilt = 0.035 * sin(t * 0.55)                                   // a dreamer's slow sway
        case .flashcube:
            // One eye a side; a quarter turn shows another. A flash when it's
            // startled -- and that side is spent. One side came burned out.
            var flash = false
            if let k = reactionBegan() {
                if (k == 1 && Float.random(in: 0...1) < 0.5) || (k == 4 && Float.random(in: 0...1) < 0.3) { flash = true }
            }
            if clock >= quirkClock {
                if talking == nil, eventKind == 0 {
                    let r = Float.random(in: 0...1)
                    if r < 0.3 { flash = true } else if r < 0.55 { eventKind = 2; eventAt = clock }      // a nervous quarter turn
                }
                quirkClock = clock + Double.random(in: 9...20)
            }
            if flash, eventKind == 0 {
                eventKind = burned[turns % 4] ? 2 : 1
                eventAt = clock
            }
            let u = Float(clock - eventAt)
            var flashLevel: Float = 0
            if eventKind == 1 {
                flashLevel = u < 0.1 ? 1 : max(0, 1 - (u - 0.1) / 0.12)
                let side = turns % 4
                if u >= 0.1, !burned[side] {
                    burned[side] = true
                    rig.materials["flashBulb\(side)"]?.diffuse.contents = UIColor(red: 0.16, green: 0.2, blue: 0.3, alpha: 1)
                    if !burned.contains(false) { allBurnedAt = clock }
                }
                if u > 0.9 { eventKind = 2; eventAt = clock }                  // and it turns away, embarrassed
            } else if eventKind == 2 {
                var next = turns + 1
                for k in 1...4 where !burned[(turns + k) % 4] { next = turns + k; break }
                turns = next
                eventKind = 3
                eventAt = clock
            } else if eventKind == 3, u > 0.5 {
                eventKind = 0
            }
            if allBurnedAt > 0, clock - allBurnedAt > 40, talking == nil, eventKind == 0 {
                // a fresh cube (nobody mentions it)
                for k in 0..<3 {
                    burned[k] = false
                    if let c = rig.materialRest["flashBulb\(k)"] { rig.materials["flashBulb\(k)"]?.diffuse.contents = c }
                }
                allBurnedAt = -1
            }
            let front = turns % 4
            if flashLevel > 0 || flashShown > 0 {
                rig.materials["flashBulb\(front)"]?.emission.contents = UIColor(white: CGFloat(flashLevel), alpha: 1)
                rig.light?.intensity = CGFloat(220 * flashLevel)
                flashShown = flashLevel
            }
            sideYaw += (-Float(turns) * .pi / 2 - sideYaw) * min(1, dt * 12)
            if let head = rig.head {
                // pitch (nods) about the body's x, after the turn about y -- so
                // every side nods the same way
                let buzz: Float = talking != nil ? 0.03 * sin(t * 40) * voiceLevel() : 0
                let qPitch = simd_quatf(angle: headRest.x - headPitch + lastNod, axis: SIMD3<Float>(1, 0, 0))
                let qYaw = simd_quatf(angle: headRest.y + sideYaw + headYaw, axis: SIMD3<Float>(0, 1, 0))
                let qRoll = simd_quatf(angle: headRest.z + buzz, axis: SIMD3<Float>(0, 0, 1))
                head.simdOrientation = qPitch * qRoll * qYaw
            }
            let b = clock - blinkAt
            var shut: Float = 0
            if b >= 0, b < 0.15 { shut = Float(sin(.pi * b / 0.15)) }
            let restClose: [Float] = [0.1, 0.65, 0.35, 0.5]               // alert, sleepy, worried, burned out
            for k in 0..<4 {
                let a = Float(k) * .pi / 2
                let close = k == front ? restClose[k] + (1.3 - restClose[k]) * shut : restClose[k]
                if let e = rig.extras["flashLid\(k)"] { e.0.rotation = SCNVector4(cos(a), 0, -sin(a), close) }
                if k == front, let e = rig.extras["flashPupil\(k)"] {
                    let qYaw = simd_quatf(angle: eyeYaw * 0.6, axis: SIMD3<Float>(0, 1, 0))
                    let qPitch = simd_quatf(angle: -eyePitch * 0.6, axis: SIMD3<Float>(cos(a), 0, -sin(a)))
                    e.0.simdOrientation = qYaw * qPitch
                }
            }
        case .television:
            // Rabbit ears for brows (and for feelings); now and then a change of
            // channel -- the knob clicks, a burst of static. Startled: static.
            if let k = reactionBegan(), k == 1 || k == 3 { staticUntil = clock + 0.4 }
            if clock >= quirkClock {
                if talking == nil, Float.random(in: 0...1) < 0.4 { staticUntil = clock + 0.35; mechTarget += .pi / 6 }
                quirkClock = clock + Double.random(in: 12...26)
            }
            if talking != nil, talkStart != eventAt {
                eventAt = talkStart
                if Float.random(in: 0...1) < 0.3 { staticUntil = clock + 0.25 }
            }
            mech += (mechTarget - mech) * min(1, dt * 18)
            if let e = rig.extras["tvKnob0"] { e.0.eulerAngles = SCNVector3(e.2.x, e.2.y, e.2.z - mech) }
            let sceptic = max(0, -browTilt)
            let fu = Float(clock - fiddleAt)                                 // Oct 12: adjusting the ears for a better picture
            let fiddle: Float = fu >= 0 && fu < 1.6 ? sin(.pi * fu / 1.6) * (0.5 + 0.15 * sin(fu * 9)) : 0
            for (name, side) in [("tvAntL", Float(1)), ("tvAntR", Float(-1))] {
                guard let e = rig.extras[name] else { continue }
                var a = side * 0.22 * browRaise                              // up and in: interest
                a += side > 0 ? 0.5 * fiddle : -0.25 * fiddle
                if side > 0 { a -= 0.45 * sceptic }                          // one ear droops: doubt
                a += talking != nil ? side * 0.07 * sin(t * 7 + side) : side * 0.02 * sin(t * 0.8)
                e.0.eulerAngles = SCNVector3(e.2.x, e.2.y, e.2.z + a)
            }
            let noisy = clock < staticUntil
            if let o = rig.overlay {
                o.opacity = noisy ? 0.92 : 0
                if noisy {
                    o.geometry?.firstMaterial?.diffuse.contentsTransform = SCNMatrix4MakeTranslation(Float.random(in: 0...1), Float.random(in: 0...1), 0)
                }
            }
            rig.materials["tvGlow"]?.emission.intensity = CGFloat(noisy ? 0.2 : 0.9 + 0.06 * sin(t * 31))
        // MARK: Oct 12 -- round four
        case .lp:
            // Shy: it slides down into its sleeve (and peeks out again). Happy:
            // it turns; a laugh spins it right round. Doubt warps it back a little.
            if let k = reactionBegan() {
                if eventKind == 0, k == 4 || (k == 2 && Float.random(in: 0...1) < 0.4) { eventKind = 1; eventAt = clock }
                if k == 3 { quirkUntil = clock + Double.random(in: 1.2...2.2) }
            }
            if clock >= quirkClock {
                if talking == nil, Float.random(in: 0...1) < 0.3 { quirkUntil = clock + Double.random(in: 1.5...3) }
                quirkClock = clock + Double.random(in: 10...20)
            }
            let hide: Float = clock < quirkUntil ? -0.17 : 0
            discY += (hide - discY) * min(1, dt * (hide < 0 ? 5 : 2.5))
            var turn: Float = talking != nil ? 0.22 * sin(t * 2.2) : 0.04 * sin(t * 0.5)
            if eventKind == 1 {
                let u = Float(clock - eventAt) / 1.3
                if u < 1 { turn += 2 * .pi * u * u * (3 - 2 * u) } else { spin -= 2 * .pi; eventKind = 0 }
            }
            spin += (turn - spin) * min(1, dt * 10)
            if let e = rig.extras["lpDisc"] {
                e.0.position = SCNVector3(e.1.x, e.1.y + discY, e.1.z)
                e.0.eulerAngles = SCNVector3(e.2.x - 0.12 * max(0, -browTilt) + 0.02 * sin(t * 1.3), e.2.y, e.2.z + spin)
            }
        case .roadmap:
            // It explains (unfolding as it talks), now and then unfolds right
            // out, and refolds -- not always correctly; then it struggles.
            if clock >= quirkClock {
                if talking == nil, eventKind == 0, Float.random(in: 0...1) < 0.35 { eventKind = 1; eventAt = clock }
                quirkClock = clock + Double.random(in: 14...26)
            }
            var want: Float = talking != nil ? 0.38 + 0.12 * sin(t * 1.6) : 0
            if eventKind == 1 {
                let u = clock - eventAt
                want = u < 2.0 ? 0.7 : 0
                if u > 3.2 {
                    eventKind = 0
                    if Float.random(in: 0...1) < 0.5 { foldError = (Int.random(in: 1...5), Float.random(in: 0.5...1.0), clock + Double.random(in: 4...8)) }
                }
            }
            if let r = reaction, clock >= r.start, r.kind == 1 { want = max(want, 0.25) }
            unfold += (want - unfold) * min(1, dt * 2.5)
            var err: Float = 0
            if foldError.panel > 0 {
                if clock > foldError.until {
                    let k = Float(clock - foldError.until) / 0.8
                    err = foldError.angle * max(0, 1 - k) * (1 + 0.3 * sin(t * 18))
                    if k >= 1 { foldError = (0, 0, 0) }
                } else {
                    err = foldError.angle
                }
            }
            for k in 1...5 {
                guard let e = rig.extras["mapPanel\(k)"] else { continue }
                let dir: Float = k % 2 == 1 ? 1 : -1
                var a = dir * (.pi - 0.06) * (1 - unfold) + 0.02 * sin(t * 2 + Float(k))
                if k == foldError.panel { a -= dir * err }
                e.0.eulerAngles = SCNVector3(e.2.x, e.2.y + a, e.2.z)
            }
        case .dymo:
            // The letter wheel clicks round while it thinks; it talks by
            // squeezing its handle -- a little more red tape out each time.
            if clock >= quirkClock {
                if talking == nil { mechTarget += Float(Int.random(in: -5...5)) * (2 * .pi / 24) }
                quirkClock = clock + Double.random(in: 3...7)
            }
            mech += (mechTarget - mech) * min(1, dt * 5)
            let step = 2 * Float.pi / 24
            if let e = rig.extras["dymoWheel"] { e.0.eulerAngles = SCNVector3(e.2.x, e.2.y + (mech / step).rounded() * step, e.2.z) }
            let open = voiceLevel()
            if open > 0.55, !squeezed { squeezed = true; tape += 0.007; if tape > 0.07 { tape = 0 } }
            if open < 0.3 { squeezed = false }
            if let e = rig.extras["dymoHandle"] { e.0.eulerAngles = SCNVector3(e.2.x + 0.22 * open, e.2.y, e.2.z) }
            if let e = rig.extras["dymoTape"] { e.0.scale = SCNVector3(1, 1, (0.06 + tape) / 0.06) }   // the strip grows out of the slot
        }
    }

    /// Oct 12 (THE BIG REVEAL): a directed phrase -- spoken now, holding the floor.
    private func direct(_ clip: AuditionClip, now: CFTimeInterval) {
        room.takeFloor(id, length: clip.duration, now: now)
        talking = clip
        talkStart = clock
        talkTarget = style.isLeader ? room.playerEye : room.show.focus
        CritterAudio.play(clip.source, on: rig.head ?? holder)
        energy = 1
    }

    /// Oct 12: the voice's loudness right now (0 when silent).
    private func voiceLevel() -> Float {
        guard let talking else { return 0 }
        let i = Int((clock - talkStart) / 0.02)
        return i >= 0 && i < talking.envelope.count ? talking.envelope[i] : 0
    }

    /// Oct 12: a reaction that has just begun (reported once).
    private func reactionBegan() -> Int? {
        guard let r = reaction, clock >= r.start, r.start != seenReaction else { return nil }
        seenReaction = r.start
        return r.kind
    }
}

// MARK: - Hallenese, one voice each

nonisolated struct AuditionClip: @unchecked Sendable {
    let source: SCNAudioSource
    let envelope: [Float]        // loudness every 20 ms, 0...1 (drives the mouth)
    let duration: Double
}

nonisolated enum AuditionVoices {
    static func prepare() {
        switch ConferenceAudition.round {
        case 1: _ = (commodore, crane, proscenium, cloche, aspic)
        case 2: _ = (safe, stove, vacuum, accordion, mailbox, laughs)
        case 3: _ = (telephone, telephoneSlam, viewmaster, flashcube, television, stove, mailbox, laughs)   // Oct 12
        case 4: _ = (lp, roadmap, dymo, vacuum, accordion, laughs)
        default: _ = (telephone, telephoneSlam, viewmaster, camera, cameraShutter, television, stove, mailbox, laughs)
        }
        _ = (tinky, juanita)
    }

    // MARK: Round two

    /// Laughs, by cast name (used as a reaction when the room is quiet enough).
    static let laughs: [String: [AuditionClip]] = [
        "AuditionStove": stoveLaugh, "AuditionVacuum": vacuumLaugh, "AuditionAccordion": accordionLaugh,
        "AuditionMailbox": mailboxLaugh, "AuditionSafe": safeLaugh,
        // Oct 12: rounds three and four (ConferenceAuditionRounds.swift).
        "AuditionTelephone": telephoneLaugh, "AuditionViewMaster": viewmasterLaugh,
        "AuditionFlashcube": flashcubeLaugh, "AuditionTelevision": televisionLaugh, "AuditionLP": lpLaugh,
        "AuditionRoadMap": roadmapLaugh, "AuditionDymo": dymoLaugh, "AuditionVacuum2": vacuumLaugh,
        // Oct 12 (refinement): round five.
        "AuditionViewMaster2": viewmasterLaugh, "AuditionCamera": cameraLaugh,
    ]

    private static func iron(_ rng: inout Rand) -> [Float] {
        MenagerieSound.strike([(140, 0.12, 0.8), (310, 0.06, 0.4), (690, 0.03, 0.2)], seconds: 0.3, noise: 0.5, noiseDecay: 0.004, rng: &rng)
    }

    /// The Safe: few words, very low, gravelly -- each one closed with a clunk of iron.
    static let safe: [AuditionClip] = [
        ("aud2-safe-0", [S(v: 5, s: 0.16, a: 78, b: 74, stop: true), S(v: 1, s: 0.34, a: 82, b: 66)]),
        ("aud2-safe-1", [S(v: 1, s: 0.22, a: 76, b: 80), S(v: 0, s: 0.14, a: 84, b: 82, gap: 0.16, stop: true), S(v: 5, s: 0.3, a: 80, b: 64)]),
        ("aud2-safe-2", [S(v: 6, s: 0.3, a: 70, b: 66), S(v: 4, s: 0.18, a: 84, b: 78, stop: true), S(v: 1, s: 0.26, a: 76, b: 62)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.95) {
            var rng = Rand(seed: stableSeed(name))
            let voice = MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 0.78, breath: 0.24)
            return MenagerieSound.mix([(at: 0, samples: voice, gain: 1), (at: Float(voice.count) / MenagerieSound.rate + 0.04, samples: iron(&rng), gain: 0.45)])
        }
    }
    static let safeLaugh: [AuditionClip] = [("aud2-safe-laugh", [S(v: 1, s: 0.12, a: 78, b: 74, stop: true), S(v: 1, s: 0.14, a: 74, b: 66)])].compactMap { name, syl in
        clip(name, volume: 0.8) { MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 0.78, breath: 0.3) }
    }

    /// The Stove: a grumbling, rolling growl with a crackle of coals.
    static let stove: [AuditionClip] = [
        ("aud2-stove-0", [S(v: 5, s: 0.12, a: 96, b: 102), S(v: 1, s: 0.1, a: 104, b: 98, stop: true), S(v: 5, s: 0.1, a: 100, b: 106), S(v: 1, s: 0.22, a: 104, b: 86)]),
        ("aud2-stove-1", [S(v: 0, s: 0.14, a: 92, b: 100, stop: true), S(v: 5, s: 0.1, a: 102, b: 96), S(v: 1, s: 0.1, a: 98, b: 104), S(v: 5, s: 0.12, a: 100, b: 94, stop: true), S(v: 1, s: 0.26, a: 96, b: 80)]),
        ("aud2-stove-2", [S(v: 6, s: 0.3, a: 88, b: 84), S(v: 5, s: 0.12, a: 100, b: 108, stop: true), S(v: 1, s: 0.24, a: 102, b: 84)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.85) {
            var rng = Rand(seed: stableSeed(name))
            let voice = MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 0.88, breath: 0.18)
            let crackle = MenagerieSound.rustle(grains: 26, seconds: Float(voice.count) / MenagerieSound.rate, grainLength: 0.002, rng: &rng)
            return MenagerieSound.mix([(at: 0, samples: voice, gain: 1), (at: 0, samples: crackle, gain: 0.18)])
        }
    }
    static let stoveLaugh: [AuditionClip] = [("aud2-stove-laugh", [S(v: 4, s: 0.09, a: 104, b: 96, stop: true), S(v: 4, s: 0.09, a: 100, b: 92, stop: true), S(v: 4, s: 0.12, a: 96, b: 84, stop: true)])].compactMap { name, syl in
        clip(name, volume: 0.8) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.08; return x }, seed: stableSeed(name), formantScale: 0.88, breath: 0.3) }
    }

    /// The Vacuum: small, sweet, questioning coos -- and a little whoosh.
    static let vacuum: [AuditionClip] = [
        ("aud2-vac-0", [S(v: 3, s: 0.12, a: 380, b: 420), S(v: 2, s: 0.2, a: 430, b: 500)]),
        ("aud2-vac-1", [S(v: 2, s: 0.1, a: 420, b: 400), S(v: 3, s: 0.1, a: 380, b: 410), S(v: 2, s: 0.16, a: 420, b: 470)]),
        ("aud2-vac-2", [S(v: 3, s: 0.26, a: 360, b: 440), S(v: 6, s: 0.14, a: 420, b: 380)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.6) {
            var rng = Rand(seed: stableSeed(name))
            let whoosh = AnimalVoice.breathNoise(seconds: 0.25, centre: 1400, width: 1600, rng: &rng, env: { u in sin(.pi * u) })
            let voice = MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 1.35, breath: 0.12)
            return MenagerieSound.mix([(at: 0, samples: whoosh, gain: 0.3), (at: 0.12, samples: voice, gain: 1)])
        }
    }
    static let vacuumLaugh: [AuditionClip] = [("aud2-vac-laugh", [S(v: 2, s: 0.06, a: 480, b: 520), S(v: 2, s: 0.06, a: 500, b: 540), S(v: 2, s: 0.06, a: 520, b: 560), S(v: 2, s: 0.1, a: 540, b: 480)])].compactMap { name, syl in
        clip(name, volume: 0.6) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.05; return x }, seed: stableSeed(name), formantScale: 1.35, breath: 0.15) }
    }

    /// The Accordion: a wheezy, melancholy voice over a soft reed chord.
    static let accordion: [AuditionClip] = [
        ("aud2-acc-0", [S(v: 1, s: 0.34, a: 190, b: 172), S(v: 0, s: 0.42, a: 176, b: 150)]),
        ("aud2-acc-1", [S(v: 4, s: 0.2, a: 180, b: 186), S(v: 1, s: 0.3, a: 184, b: 166), S(v: 3, s: 0.36, a: 168, b: 146)]),
        ("aud2-acc-2", [S(v: 6, s: 0.4, a: 170, b: 160), S(v: 0, s: 0.34, a: 166, b: 140)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.65) {
            let voice = MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 1.0, breath: 0.32)
            let seconds = Float(voice.count) / MenagerieSound.rate
            let reedA = MenagerieSound.sweep(220, 218, seconds: seconds, wobble: 0.15)
            let reedB = MenagerieSound.sweep(261.6, 259, seconds: seconds, wobble: 0.15)
            return MenagerieSound.mix([(at: 0, samples: voice, gain: 1), (at: 0, samples: reedA, gain: 0.12), (at: 0, samples: reedB, gain: 0.1)])
        }
    }
    static let accordionLaugh: [AuditionClip] = [("aud2-acc-laugh", [S(v: 0, s: 0.12, a: 200, b: 180), S(v: 0, s: 0.12, a: 190, b: 170), S(v: 0, s: 0.2, a: 180, b: 150)])].compactMap { name, syl in
        clip(name, volume: 0.6) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.07; return x }, seed: stableSeed(name), formantScale: 1.0, breath: 0.5) }
    }

    /// The Mailbox: quick, chattering, conspiratorial -- a flap of paper in it.
    static let mailbox: [AuditionClip] = [
        ("aud2-mail-0", [S(v: 4, s: 0.06, a: 260, b: 280, stop: true), S(v: 2, s: 0.06, a: 290, b: 300), S(v: 0, s: 0.07, a: 300, b: 280, stop: true), S(v: 4, s: 0.06, a: 280, b: 300), S(v: 2, s: 0.12, a: 310, b: 340)]),
        ("aud2-mail-1", [S(v: 0, s: 0.07, a: 250, b: 270), S(v: 4, s: 0.06, a: 280, b: 270, stop: true), S(v: 2, s: 0.06, a: 290, b: 310), S(v: 3, s: 0.06, a: 300, b: 290, stop: true), S(v: 4, s: 0.07, a: 290, b: 300), S(v: 0, s: 0.14, a: 300, b: 250)]),
        ("aud2-mail-2", [S(v: 2, s: 0.08, a: 300, b: 330, stop: true), S(v: 2, s: 0.06, a: 320, b: 310), S(v: 4, s: 0.18, a: 300, b: 360)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.65) {
            var rng = Rand(seed: stableSeed(name))
            let flap = MenagerieSound.rustle(grains: 18, seconds: 0.08, grainLength: 0.003, rng: &rng)
            let voice = MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.03; return x }, seed: stableSeed(name), formantScale: 1.15, breath: 0.06)
            return MenagerieSound.mix([(at: 0, samples: flap, gain: 0.3), (at: 0.05, samples: voice, gain: 1)])
        }
    }
    static let mailboxLaugh: [AuditionClip] = [("aud2-mail-laugh", [S(v: 2, s: 0.05, a: 340, b: 360), S(v: 2, s: 0.05, a: 350, b: 370), S(v: 2, s: 0.05, a: 360, b: 380), S(v: 2, s: 0.05, a: 370, b: 390), S(v: 2, s: 0.08, a: 380, b: 340)])].compactMap { name, syl in
        clip(name, volume: 0.6) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.04; return x }, seed: stableSeed(name), formantScale: 1.15, breath: 0.12) }
    }

    /// Renders once, caches the WAV (MenagerieSound), and keeps the
    /// loudness envelope for the mouth.
    static func clip(_ name: String, volume: Float, _ render: () -> [Float]) -> AuditionClip? {
        let samples = MenagerieSound.normalized(render())
        guard !samples.isEmpty, let source = MenagerieSound.source(name, volume: volume, { samples }) else { return nil }
        let frame = max(1, Int(MenagerieSound.rate * 0.02))
        var envelope: [Float] = []
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + frame)
            var sum: Float = 0
            for k in i..<end { sum += samples[k] * samples[k] }
            envelope.append(sqrt(sum / Float(end - i)))
            i = end
        }
        let peak = max(envelope.max() ?? 1, 0.0001)
        envelope = envelope.map { min(1, $0 / peak * 1.25) }
        return AuditionClip(source: source, envelope: envelope, duration: Double(samples.count) / Double(MenagerieSound.rate))
    }

    typealias S = MeetingVoices.Syl

    /// The same seed every launch (String.hashValue is not).
    static func stableSeed(_ name: String) -> UInt64 { name.utf8.reduce(UInt64(1469598103)) { ($0 &* 1099511628211) ^ UInt64($1) } }

    /// The Commodore: deep, slow, a little hollow -- then a bubble or two.
    static let commodore: [AuditionClip] = [
        ("aud-comm-0", [S(v: 1, s: 0.22, a: 92, b: 88), S(v: 5, s: 0.18, a: 98, b: 104, stop: true), S(v: 1, s: 0.34, a: 108, b: 84)]),
        ("aud-comm-1", [S(v: 0, s: 0.16, a: 96, b: 100), S(v: 4, s: 0.2, a: 104, b: 98, gap: 0.12), S(v: 3, s: 0.38, a: 100, b: 80)]),
        ("aud-comm-2", [S(v: 5, s: 0.12, a: 90, b: 92, stop: true), S(v: 1, s: 0.3, a: 100, b: 118), S(v: 0, s: 0.2, a: 110, b: 96), S(v: 5, s: 0.26, a: 94, b: 82)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.85) {
            var rng = Rand(seed: UInt64(name.count * 977))
            let voice = MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 0.82, breath: 0.12)
            var bubbles: [(at: Float, samples: [Float], gain: Float)] = [(at: 0, samples: voice, gain: 1)]
            let end = Float(voice.count) / MenagerieSound.rate
            for k in 0..<3 {
                let f = rng.range(380, 620)
                bubbles.append((at: end + 0.05 + Float(k) * 0.09, samples: MenagerieSound.sweep(f, f * 1.6, seconds: 0.05, wobble: 0.3), gain: 0.25))
            }
            return MenagerieSound.mix(bubbles)
        }
    }

    /// The Crane: quick, crisp, paper-dry chirps.
    static let crane: [AuditionClip] = [
        ("aud-crane-0", [S(v: 2, s: 0.06, a: 620, b: 700, stop: true), S(v: 4, s: 0.07, a: 680, b: 640), S(v: 2, s: 0.05, a: 720, b: 760, stop: true), S(v: 0, s: 0.12, a: 700, b: 560)]),
        ("aud-crane-1", [S(v: 4, s: 0.05, a: 560, b: 600, stop: true), S(v: 2, s: 0.06, a: 640, b: 700, stop: true), S(v: 2, s: 0.06, a: 700, b: 760), S(v: 3, s: 0.1, a: 640, b: 820)]),
        ("aud-crane-2", [S(v: 0, s: 0.08, a: 600, b: 640, stop: true), S(v: 4, s: 0.05, a: 660, b: 640, gap: 0.1), S(v: 2, s: 0.05, a: 720, b: 700, stop: true), S(v: 2, s: 0.05, a: 700, b: 680, stop: true), S(v: 4, s: 0.11, a: 660, b: 520)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.6) {
            var rng = Rand(seed: UInt64(name.count * 131))
            let voice = MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 1.45, breath: 0.05)
            let rustle = MenagerieSound.rustle(grains: 30, seconds: 0.12, grainLength: 0.003, rng: &rng)
            return MenagerieSound.mix([(at: 0, samples: rustle, gain: 0.25), (at: 0.05, samples: voice, gain: 1)])
        }
    }

    /// The Proscenium: theatrical swoops.
    static let proscenium: [AuditionClip] = [
        ("aud-proc-0", [S(v: 1, s: 0.3, a: 150, b: 270), S(v: 0, s: 0.42, a: 280, b: 140)]),
        ("aud-proc-1", [S(v: 4, s: 0.16, a: 180, b: 200, stop: true), S(v: 0, s: 0.36, a: 220, b: 320, gap: 0.1), S(v: 1, s: 0.3, a: 260, b: 150)]),
        ("aud-proc-2", [S(v: 3, s: 0.24, a: 170, b: 150), S(v: 2, s: 0.16, a: 210, b: 240, stop: true), S(v: 0, s: 0.48, a: 300, b: 130)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.75) { MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 1.0, breath: 0.06) }
    }

    /// The Cloche: soft, breathy, high -- a voice through glass.
    static let cloche: [AuditionClip] = [
        ("aud-cloche-0", [S(v: 3, s: 0.24, a: 300, b: 330), S(v: 2, s: 0.3, a: 340, b: 290)]),
        ("aud-cloche-1", [S(v: 1, s: 0.18, a: 280, b: 300), S(v: 3, s: 0.16, a: 310, b: 320), S(v: 2, s: 0.28, a: 330, b: 360)]),
        ("aud-cloche-2", [S(v: 6, s: 0.4, a: 260, b: 300), S(v: 3, s: 0.26, a: 300, b: 270)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.5) { MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 1.25, breath: 0.4) }
    }

    /// Aspic: a wobbly, burbling little voice.
    static let aspic: [AuditionClip] = [
        ("aud-aspic-0", [S(v: 3, s: 0.08, a: 220, b: 260), S(v: 1, s: 0.08, a: 250, b: 210), S(v: 3, s: 0.08, a: 230, b: 270), S(v: 1, s: 0.14, a: 260, b: 200)]),
        ("aud-aspic-1", [S(v: 1, s: 0.09, a: 200, b: 240), S(v: 3, s: 0.07, a: 250, b: 220), S(v: 1, s: 0.07, a: 230, b: 260), S(v: 3, s: 0.07, a: 250, b: 220), S(v: 0, s: 0.16, a: 240, b: 300)]),
        ("aud-aspic-2", [S(v: 3, s: 0.12, a: 210, b: 250), S(v: 1, s: 0.08, a: 240, b: 200), S(v: 3, s: 0.18, a: 220, b: 180)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.6) { MeetingVoices.speak(syl.map { var s = $0; s.gap = 0.015; return s }, seed: stableSeed(name), formantScale: 1.1, breath: 0.08) }
    }

    /// Mr. Tinky: tin.
    static let tinky: [AuditionClip] = [("aud-tinky-0", 2), ("aud-tinky-1", 3), ("aud-tinky-2", 2)].compactMap { name, n in
        clip(name, volume: 0.55) {
            var rng = Rand(seed: UInt64(name.count * 17 + n))
            var parts: [(at: Float, samples: [Float], gain: Float)] = []
            for k in 0..<n {
                let f = rng.range(2600, 3400)
                parts.append((at: Float(k) * rng.range(0.11, 0.16), samples: MenagerieSound.strike([(f, 0.05, 0.6), (f * 1.52, 0.03, 0.3), (f * 2.3, 0.015, 0.15)],
                                                                                                    seconds: 0.12, noise: 0.2, rng: &rng), gain: 1 - Float(k) * 0.15))
            }
            return MenagerieSound.mix(parts)
        }
    }

    /// Juanita: her bell -- once, or twice.
    static let juanita: [AuditionClip] = [("aud-juanita-0", 1), ("aud-juanita-1", 2)].compactMap { name, n in
        clip(name, volume: 0.5) {
            var rng = Rand(seed: UInt64(name.count * 7 + n))
            var parts: [(at: Float, samples: [Float], gain: Float)] = []
            for k in 0..<n {
                parts.append((at: Float(k) * 0.22, samples: MenagerieSound.strike([(2093, 0.6, 0.6), (5230, 0.25, 0.25), (8370, 0.1, 0.1)],
                                                                                   seconds: 0.9, noise: 0.05, rng: &rng), gain: 1))
            }
            return MenagerieSound.mix(parts)
        }
    }
}


// MARK: - Oct 12 -- THE MEETING CONVERSATION: tap a cast member, and they join in
//
// A tap on a character in the conference room (seated or standing; the tap
// is theirs, never a walk or STAND) starts a short EXCHANGE: they turn to the
// player and say their piece, and someone answers in character. Exchanges are
// authored data, played in order per character -- deterministic, never
// overlapping (one at a time; the room's own chatter waits), and never
// repeated: once a character has said everything, they just look at you and
// smile. Add a line by adding a Beat to `exchanges`.
//
// During THE BOX the show keeps the floor: a tap gets a quick, silent
// acknowledgement (a glance, a nod) -- except in the presentation's quiet
// stretches (BoxReveal.interjectionWindowOpen), where the character may speak
// up and the Telephone, presiding, gives them a look before the show goes on.
// Harold (the screen, while he's on it) answers being interrupted himself.
@MainActor
enum MeetingConversation {
    /// One moment of an exchange: `who` ("self" = the tapped character, or an
    /// asset name), what they do, `at` seconds after the tap.
    struct Beat {
        let who: String
        let cue: AuditionCue
        let at: Double
    }

    private static let tel = "AuditionTelephone", stove = "AuditionStove", mail = "AuditionMailbox"
    private static let tv = "AuditionTelevision", cam = "AuditionCamera", vm = "AuditionViewMaster2"
    // (Oct 19, Stage A: the Rolodex retired; its lines go, and its two parts in
    // others' exchanges pass to the View-Master and the Camera.)
    private static func id(_ name: String) -> Int { ConferenceAudition.actorID(name) ?? -1 }

    /// Each character's exchanges, in the order they're used.
    private static var exchanges: [String: [[Beat]]] {
        [
            tel: [
                // A welcome -- and the screen, proudly.
                [Beat(who: "self", cue: .speak(0), at: 0.3), Beat(who: "self", cue: .gesture(1.6), at: 0.4),
                 Beat(who: mail, cue: .laugh, at: 2.0)],
                // Business: the Stove isn't convinced; the Telephone stares him down.
                [Beat(who: "self", cue: .speak(2), at: 0.3), Beat(who: stove, cue: .react(3), at: 1.6),
                 Beat(who: "self", cue: .look(id(stove), 2.0), at: 2.0), Beat(who: "self", cue: .react(3), at: 2.2)],
                // A confidence: the View-Master is delighted.
                [Beat(who: "self", cue: .speak(1), at: 0.3), Beat(who: vm, cue: .react(4), at: 1.5), Beat(who: vm, cue: .speak(0), at: 2.2)],
            ],
            stove: [
                // A grumble at the newcomer; the Mailbox can't help giggling.
                [Beat(who: "self", cue: .speak(0), at: 0.3), Beat(who: "self", cue: .react(3), at: 0.4),
                 Beat(who: mail, cue: .laugh, at: 1.8), Beat(who: "self", cue: .look(id(mail), 1.6), at: 2.4)],
                // A question for the chair -- the Telephone answers, firmly.
                [Beat(who: "self", cue: .speak(2), at: 0.3), Beat(who: "self", cue: .look(id(tel), 3.0), at: 1.2),
                 Beat(who: tel, cue: .speak(0), at: 1.9), Beat(who: "self", cue: .react(0), at: 3.2)],
                // Grudging: a nod for you.
                [Beat(who: "self", cue: .speak(1), at: 0.3), Beat(who: "self", cue: .react(0), at: 1.4)],
            ],
            mail: [
                // Delighted you're here.
                [Beat(who: "self", cue: .speak(0), at: 0.3), Beat(who: "self", cue: .react(4), at: 0.4),
                 Beat(who: vm, cue: .react(1), at: 1.6)],
                // Gossip -- the Stove disapproves.
                [Beat(who: "self", cue: .speak(2), at: 0.3), Beat(who: "self", cue: .look(id(stove), 1.5), at: 1.4),
                 Beat(who: stove, cue: .react(3), at: 1.8), Beat(who: "self", cue: .laugh, at: 2.6)],
                // Too excited to keep it in.
                [Beat(who: "self", cue: .speak(1), at: 0.3), Beat(who: tv, cue: .react(2), at: 1.5)],
            ],
            tv: [
                // A better picture for you (the antennae), then his say.
                [Beat(who: "self", cue: .fiddle, at: 0.2), Beat(who: "self", cue: .speak(0), at: 1.2),
                 Beat(who: cam, cue: .react(2), at: 2.6)],
                // A question for the Camera -- who answers with a picture.
                [Beat(who: "self", cue: .speak(1), at: 0.3), Beat(who: "self", cue: .look(id(cam), 2.0), at: 1.3),
                 Beat(who: cam, cue: .snap, at: 2.0), Beat(who: "self", cue: .react(1), at: 2.4)],
                [Beat(who: "self", cue: .speak(2), at: 0.3), Beat(who: "self", cue: .react(2), at: 1.4)],
            ],
            cam: [
                // Your picture, of course.
                [Beat(who: "self", cue: .snap, at: 0.4), Beat(who: "self", cue: .speak(0), at: 1.3),
                 Beat(who: tel, cue: .react(3), at: 2.4)],
                [Beat(who: "self", cue: .speak(1), at: 0.3), Beat(who: tv, cue: .react(4), at: 1.6)],
                [Beat(who: "self", cue: .speak(2), at: 0.3), Beat(who: "self", cue: .laugh, at: 1.6)],
            ],
            vm: [
                // A slide for you -- and another.
                [Beat(who: "self", cue: .speak(0), at: 0.3), Beat(who: "self", cue: .react(2), at: 1.2),
                 Beat(who: mail, cue: .react(4), at: 1.8)],
                [Beat(who: "self", cue: .speak(1), at: 0.3), Beat(who: "self", cue: .look(id(cam), 1.6), at: 1.3),
                 Beat(who: cam, cue: .speak(0), at: 1.9)],
                [Beat(who: "self", cue: .speak(2), at: 0.3), Beat(who: "self", cue: .react(4), at: 1.3)],
            ],
        ]
    }

    /// Exchanges used per character (this visit to the room).
    private static var used: [String: Int] = [:]
    private static var busyUntil: CFTimeInterval = 0
    private static var installedRoom: ObjectIdentifier?

    /// A new build of the room: everyone has everything to say again.
    private static func syncRoom() {
        let key = ConferenceAudition.members.first.map { ObjectIdentifier($0.holder) }
        if key != installedRoom { installedRoom = key; used = [:]; busyUntil = 0 }
    }

    /// A tap on a cast member. Always handled (the tap is theirs).
    static func tapped(_ member: ConferenceAudition.Member) {
        syncRoom()
        let now = CACurrentMediaTime()
        let room = ConferenceAudition.room
        // Someone's already speaking up (or the show has the floor): a glance, a nod.
        let duringShow = BoxReveal.isRunning || BoxReveal.emergencyActive   // (Oct 13: and through the alarm)
        if now < busyUntil || (duringShow && !BoxReveal.interjectionWindowOpen) {
            room.cue(member.id, .look(-1, 1.4))
            room.cue(member.id, .react(0), delay: 0.25)
            diag("meeting.conversation.acknowledged", ["who": member.name, "show": duringShow])
            return
        }
        let list = exchanges[member.name] ?? []
        let n = used[member.name] ?? 0
        guard n < list.count else {
            // Said everything there is to say: a look, a smile.
            room.cue(member.id, .look(-1, 1.6))
            room.cue(member.id, .react(2), delay: 0.3)
            diag("meeting.conversation.saidAll", ["who": member.name])
            return
        }
        used[member.name] = n + 1
        var beats = list[n]
        if duringShow {
            // In the show's quiet stretch: just their first line; the presiding
            // Telephone gives them a look, and the show goes on.
            beats = Array(beats.prefix { $0.who == "self" }.prefix(2))
            if member.name != tel {
                beats += [Beat(who: tel, cue: .look(member.id, 1.6), at: 1.5), Beat(who: tel, cue: .react(3), at: 1.7)]
            }
        }
        let length = (beats.map(\.at).max() ?? 0) + 2.0
        busyUntil = now + length
        room.hold(length)                                           // the room's own chatter waits
        room.cue(member.id, .look(-1, 1.8))                         // to you first
        for b in beats {
            let who = b.who == "self" ? member.id : id(b.who)
            guard who >= 0 else { continue }
            room.cue(who, b.cue, delay: b.at)
        }
        diag("meeting.conversation.exchange", ["who": member.name, "n": n, "show": duringShow])
    }
}
