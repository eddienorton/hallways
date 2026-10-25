import SceneKit
import UIKit
import AVFoundation                 // Oct 12: the Telephone voice audition's sample player
import simd

/// Oct 12 -- THE GREAT CASTING PASS: rounds three and four of the Floor 3
/// conference-room audition (ConferenceAudition). Yesterday's forgotten
/// technology; each face comes out of the object's own mechanism.
///
/// ROUND FIVE (Oct 12 refinement; the default now): "the character must read
/// before the mechanism does." The four winners -- Telephone (head), Stove,
/// Mailbox, Television -- exactly as in round three, with the revised
/// View-Master (AuditionViewMaster2) and THE CAMERA (the
/// vintage camera itself: eyes in its silver top plate, the lens for a mouth
/// that zooms to look closer, a small flashcube for a hat; it takes pictures).
///
/// ROUND THREE (`-HallwaysAuditionRound 3`):
///   THE TELEPHONE   (at the head, on the table) a heavy black rotary desk
///                   set. Its eyes are the cradle plungers; its great brow is
///                   the handset (it lifts with interest, tilts in doubt, and
///                   -- rarely -- comes right up and is slammed down: the
///                   whole table flinches); its mouth is the dial's centre
///                   card; it dials while it thinks. Pompous, measured.
///   THE VIEW-MASTER every blink is a slide change: the lever clicks, the
///                   reel on its head turns a frame and its irises come up a
///                   new colour. A dreamer.
///   (THE ROLODEX    retired Oct 19, Stage A; its place keeps an empty chair.)
///   THE FLASHCUBE   on its little Instamatic: one eye a side, quarter turns
///                   between them; startled, it flashes (softly) and that
///                   side is spent; one side came burned out.
///   THE TELEVISION  a glowing face on the screen; the rabbit ears are its
///                   brows; a change of channel is a burst of static.
///   + the Stove and the Mailbox (benchmarks, from round two).
///
/// ROUND FOUR (`-HallwaysAuditionRound 4`):
///   THE LP          (on the table at the head) its face is on the label; it
///                   hides in its sleeve, turns when happy, spins when it laughs.
///   THE ROAD MAP    unfolds as it explains, refolds -- not always correctly.
///   THE DYMO        (experimental) its letter wheel clicks round while it
///                   thinks; it talks by squeezing out red tape.
///   THE VACUUM      revised: no ring, little feet (AuditionVacuum2).
///   + the Accordion, Juanita (standing) and Mr. Tinky.
///
/// Mr. Tinky's ALTERNATE body for the audition only:
/// `-HallwaysAuditionTinkyBody canister` (a 35mm film canister; his tin-can
/// original everywhere else, always).
///
/// Models: CharacterModels/Hallwaysians/scripts/audition3.py, audition4.py.
extension ConferenceAudition {

    /// `-HallwaysAuditionTinkyBody canister`: Mr. Tinky in a film canister
    /// (auditions only). Any other value (or none): his original tin can.
    nonisolated static var tinkyCanister: Bool {
        UserDefaults.standard.string(forKey: "HallwaysAuditionTinkyBody") == "canister"
    }

    /// Mr. Tinky's body for the auditions (rounds two and four).
    static func auditionTinkyBody() -> SCNNode? {
        guard tinkyCanister else { return HallwaysianTinky.makeBody() }
        guard let model = HallwaysianModel.load("MrTinkyCanister", required: HallwaysianTinky.requiredNodes),
              let template = model.childNode(withName: "tinCanRatBody", recursively: true) else {
            diag("audition.missing", ["model": "MrTinkyCanister"])
            return HallwaysianTinky.makeBody()
        }
        let body = template.clone()
        for (i, side) in [(0, Float(-1)), (1, Float(1))] {
            body.childNode(withName: "tinCanRatEar\(i)", recursively: true)?.eulerAngles = SCNVector3(Float.pi / 2, 0, side * 0.35)
        }
        return body
    }

    // MARK: Places

    /// A side place's holder (ConferenceRoom's chair order), on an armless
    /// visitor chair pulled back and swivelled toward the foot -- exactly as
    /// round two; `booster` puts a booster stack on the seat first.
    private static func seat(_ i: Int, in room: SCNNode, layout: MeetingLayout, forward: Float, booster: Bool = false) -> SCNNode {
        let t = layout.table
        let side = ConferenceRoom.tableWidth / 2 + 0.42 + pullBack
        let rows: [Float] = [-1.75, 0, 1.75]
        let west = i % 2 == 0
        let x = west ? t.x - side : t.x + side
        let yaw = west ? Float(Direction.west.yaw) - (swivel[i] ?? 0) : Float(Direction.east.yaw) + (swivel[i] ?? 0)
        let p = SCNVector3(x, 0, t.y + rows[i / 2])
        let chair = AdministrationReception.makeVisitorChair()
        chair.name = "auditionChair\(i)"
        chair.position = p
        chair.eulerAngles.y = yaw
        room.addChildNode(chair)
        let holder = SCNNode()
        holder.position = SCNVector3(p.x + sin(yaw) * forward, visitorSeatTop, p.z + cos(yaw) * forward)
        holder.eulerAngles.y = yaw
        room.addChildNode(holder)
        if booster {
            holder.addChildNode(AdministrationReception.makeBoosterStack())
            let lifted = SCNNode()
            lifted.position = SCNVector3(0, AdministrationReception.boosterHeight, 0)
            holder.addChildNode(lifted)
            return lifted
        }
        return holder
    }

    /// The head of the table, on the table top, facing down the table.
    private static func headOfTable(in room: SCNNode, layout: MeetingLayout) -> SCNNode {
        let holder = SCNNode()
        holder.position = SCNVector3(layout.table.x, ConferenceRoom.tableTopHeight, layout.table.y - 2.2)
        room.addChildNode(holder)
        return holder
    }

    /// Loads one character onto `holder`; nil (and the holder removed) if missing.
    private static func load(_ resource: String, prefix: String, on holder: SCNNode, scale: Float, required: [String])
        -> (SCNNode, AuditionActor.Rig)? {
        guard let model = HallwaysianModel.load(resource, required: required)?.clone() else {
            diag("audition.missing", ["model": resource]); holder.removeFromParentNode(); return nil
        }
        model.scale = SCNVector3(scale, scale, scale)
        holder.addChildNode(model)
        return (model, AuditionActor.rig(model, prefix: prefix))
    }

    private static func extras(_ names: [String], in model: SCNNode, rig: inout AuditionActor.Rig) {
        for name in names {
            if let x = model.childNode(withName: name, recursively: true) { rig.extras[name] = (x, x.position, x.eulerAngles) }
        }
    }

    /// The first material (anywhere in the model) whose name contains `key`.
    private static func material(_ key: String, in model: SCNNode) -> SCNMaterial? {
        var found: SCNMaterial?
        model.enumerateHierarchy { node, stop in
            for m in node.geometry?.materials ?? [] where (m.name ?? "").contains(key) {
                found = m; stop.pointee = true; return
            }
        }
        return found
    }

    /// The node itself or its first descendant that carries geometry.
    private static func geometryNode(_ node: SCNNode) -> SCNNode? {
        if node.geometry != nil { return node }
        for c in node.childNodes { if let g = geometryNode(c) { return g } }
        return nil
    }

    // MARK: Round three

    static func castRoundThree(_ room: SCNNode, layout: MeetingLayout) -> [Cast] {
        for i in 0...6 { room.childNode(withName: "conferenceRoomChair\(i)", recursively: false)?.isHidden = true }
        var cast: [Cast] = []
        // The Telephone, on the table at the head.
        if let loaded = load("AuditionTelephone", prefix: "tel", on: headOfTable(in: room, layout: layout), scale: 2.1,
                                    required: ["telHead", "telMouth", "telEyeL", "telDial", "telHandset"]) {
            let model = loaded.0, rig0 = loaded.1
            var rig = rig0
            extras(["telDial", "telHandset"], in: model, rig: &rig)
            cast.append(("AuditionTelephone", model.parent ?? model, rig, .telephone, AuditionVoices.telephone))
        }
        if let loaded = load("AuditionViewMaster", prefix: "vm", on: seat(0, in: room, layout: layout, forward: 0.06, booster: true),
                                    scale: 1.45, required: ["vmHead", "vmMouth", "vmEyeL", "vmReel", "vmLever"]) {
            let model = loaded.0, rig0 = loaded.1
            var rig = rig0
            extras(["vmReel", "vmLever"], in: model, rig: &rig)
            // Each eye gets its own iris material (they change colour at every blink).
            for key in ["vmIrisL", "vmIrisR"] {
                if let n = model.childNode(withName: key, recursively: true), let g = geometryNode(n),
                   let geo = g.geometry?.copy() as? SCNGeometry, let m = geo.firstMaterial?.copy() as? SCNMaterial {
                    geo.materials = [m]
                    g.geometry = geo
                    rig.materials[key] = m
                }
            }
            tuneGlass(model)
            cast.append(("AuditionViewMaster", model.parent ?? model, rig, .viewmaster, AuditionVoices.viewmaster))
        }
        if let loaded = load("AuditionStove", prefix: "stove", on: seat(1, in: room, layout: layout, forward: 0.13), scale: 1.3,
                                    required: ["stoveHead", "stoveMouth", "stoveEyeL", "stovePipeTop"]) {
            let model = loaded.0, rig0 = loaded.1
            var rig = rig0
            dressStove(model, rig: &rig)
            cast.append(("AuditionStove", model.parent ?? model, rig, .stove, AuditionVoices.stove))
        }
        // (Oct 19, Stage A: the Rolodex retired -- its place keeps an empty chair.)
        _ = seat(2, in: room, layout: layout, forward: 0.06)
        if let loaded = load("AuditionMailbox", prefix: "mail", on: seat(3, in: room, layout: layout, forward: 0.08), scale: 1.45,
                                    required: ["mailHead", "mailMouth", "mailEyeL", "mailFlag"]) {
            let model = loaded.0, rig0 = loaded.1
            cast.append(("AuditionMailbox", model.parent ?? model, rig0, .mailbox, AuditionVoices.mailbox))
        }
        if let loaded = load("AuditionFlashcube", prefix: "flash", on: seat(4, in: room, layout: layout, forward: 0.06, booster: true),
                                    scale: 1.6, required: ["flashHead", "flashMouth", "flashLid0", "flashPupil0", "flashLid3"]) {
            let model = loaded.0, rig0 = loaded.1
            var rig = rig0
            extras((0..<4).flatMap { ["flashLid\($0)", "flashPupil\($0)"] }, in: model, rig: &rig)
            for k in 0..<4 {
                // each bulb its own material (they burn out one by one; the shared asset never changes)
                if let n = model.childNode(withName: "bulb\(k)", recursively: true), let g = geometryNode(n),
                   let geo = g.geometry?.copy() as? SCNGeometry, let m = geo.firstMaterial?.copy() as? SCNMaterial {
                    geo.materials = [m]
                    g.geometry = geo
                    rig.materials["flashBulb\(k)"] = m
                    rig.materialRest["flashBulb\(k)"] = UIColor(red: 0.85, green: 0.92, blue: 1, alpha: 1)
                    m.diffuse.contents = UIColor(red: 0.85, green: 0.92, blue: 1, alpha: 1)
                    m.emission.contents = UIColor.black
                }
            }
            // The side that came burned out.
            rig.materials["flashBulb3"]?.diffuse.contents = UIColor(red: 0.16, green: 0.2, blue: 0.3, alpha: 1)
            // The flash itself: a small, soft, brief light.
            let flash = SCNLight()
            flash.type = .omni
            flash.color = UIColor(red: 1, green: 0.97, blue: 0.9, alpha: 1)
            flash.intensity = 0
            flash.attenuationStartDistance = 0.2
            flash.attenuationEndDistance = 2.2
            let ln = SCNNode()
            ln.light = flash
            ln.position = SCNVector3(0, 0.23, 0.16)                  // in front of the cube, whichever side is showing
            (rig.head?.parent ?? model).addChildNode(ln)
            rig.light = flash
            tuneGlass(model)
            cast.append(("AuditionFlashcube", model.parent ?? model, rig, .flashcube, AuditionVoices.flashcube))
        }
        if let loaded = load("AuditionTelevision", prefix: "tv", on: seat(5, in: room, layout: layout, forward: 0.05), scale: 1.25,
                                    required: ["tvHead", "tvMouth", "tvEyeL", "tvPupilL", "tvAntL", "tvAntR"]) {
            let model = loaded.0, rig0 = loaded.1
            var rig = rig0
            extras(["tvAntL", "tvAntR", "tvKnob0", "tvKnob1"], in: model, rig: &rig)
            if let glow = material("tvGlow", in: model) {
                glow.emission.contents = UIColor(red: 0.85, green: 0.95, blue: 0.9, alpha: 1)
                glow.emission.intensity = 0.9
                rig.materials["tvGlow"] = glow
            }
            if let screen = material("tvScreenFace", in: model) {
                screen.emission.contents = UIColor(red: 0.12, green: 0.2, blue: 0.18, alpha: 1)
                screen.emission.intensity = 0.5
            }
            if let head = rig.head { rig.overlay = makeStatic(on: head) }
            cast.append(("AuditionTelevision", model.parent ?? model, rig, .television, AuditionVoices.television))
        }
        return cast
    }

    // MARK: Round five (Oct 12, refinement): the four winners as benchmarks,
    // with the revised View-Master and the Camera. (Oct 19, Stage A: the
    // revised Rolodex, once at place 0, is retired; its chair stays, empty.)

    static func castRoundFive(_ room: SCNNode, layout: MeetingLayout) -> [Cast] {
        for i in 0...6 { room.childNode(withName: "conferenceRoomChair\(i)", recursively: false)?.isHidden = true }
        var cast: [Cast] = []
        // The four winners, exactly as in round three.
        if let loaded = load("AuditionTelephone", prefix: "tel", on: headOfTable(in: room, layout: layout), scale: 2.1,
                             required: ["telHead", "telMouth", "telEyeL", "telDial", "telHandset"]) {
            let model = loaded.0
            var rig = loaded.1
            extras(["telDial", "telHandset"], in: model, rig: &rig)
            cast.append(("AuditionTelephone", model.parent ?? model, rig, .telephone, AuditionVoices.telephone))
        }
        // View-Master, revised: same mechanism (the slide-change blink), plain body.
        // (Nearest place on the player's left: the smallest face sits closest.)
        if let loaded = load("AuditionViewMaster2", prefix: "vm2", on: seat(4, in: room, layout: layout, forward: 0.06, booster: true),
                             scale: 1.25, required: ["vm2Head", "vm2Mouth", "vm2EyeL", "vm2Reel", "vm2Lever"]) {
            let model = loaded.0
            var rig = loaded.1
            for (from, to) in [("vm2Reel", "vmReel"), ("vm2Lever", "vmLever")] {
                if let x = model.childNode(withName: from, recursively: true) { rig.extras[to] = (x, x.position, x.eulerAngles) }
            }
            for (from, to) in [("vm2IrisL", "vmIrisL"), ("vm2IrisR", "vmIrisR")] {
                if let n = model.childNode(withName: from, recursively: true), let g = geometryNode(n),
                   let geo = g.geometry?.copy() as? SCNGeometry, let m = geo.firstMaterial?.copy() as? SCNMaterial {
                    geo.materials = [m]
                    g.geometry = geo
                    rig.materials[to] = m
                }
            }
            tuneGlass(model)
            cast.append(("AuditionViewMaster2", model.parent ?? model, rig, .viewmaster, AuditionVoices.viewmaster))
        }
        if let loaded = load("AuditionStove", prefix: "stove", on: seat(1, in: room, layout: layout, forward: 0.13), scale: 1.3,
                             required: ["stoveHead", "stoveMouth", "stoveEyeL", "stovePipeTop"]) {
            let model = loaded.0
            var rig = loaded.1
            dressStove(model, rig: &rig)
            cast.append(("AuditionStove", model.parent ?? model, rig, .stove, AuditionVoices.stove))
        }
        // (Oct 19, Stage A: the revised Rolodex retired -- its place keeps an
        // empty chair; nobody else moves.)
        _ = seat(0, in: room, layout: layout, forward: 0.06)
        if let loaded = load("AuditionMailbox", prefix: "mail", on: seat(3, in: room, layout: layout, forward: 0.08), scale: 1.45,
                             required: ["mailHead", "mailMouth", "mailEyeL", "mailFlag"]) {
            cast.append(("AuditionMailbox", loaded.0.parent ?? loaded.0, loaded.1, .mailbox, AuditionVoices.mailbox))
        }
        // The Camera: the camera itself is the character (the flashcube a small hat).
        if let loaded = load("AuditionCamera", prefix: "cam", on: seat(2, in: room, layout: layout, forward: 0.06, booster: true),
                             scale: 1.25, required: ["camHead", "camMouth", "camEyeL", "camLens", "camLever"]) {
            let model = loaded.0
            var rig = loaded.1
            extras(["camLens", "camLever"], in: model, rig: &rig)
            if let n = model.childNode(withName: "camBulbFront", recursively: true), let g = geometryNode(n),
               let geo = g.geometry?.copy() as? SCNGeometry, let m = geo.firstMaterial?.copy() as? SCNMaterial {
                geo.materials = [m]
                g.geometry = geo
                m.emission.contents = UIColor.black
                rig.materials["camBulb"] = m
            }
            let flash = SCNLight()
            flash.type = .omni
            flash.color = UIColor(red: 1, green: 0.97, blue: 0.9, alpha: 1)
            flash.intensity = 0
            flash.attenuationStartDistance = 0.2
            flash.attenuationEndDistance = 2.0
            let ln = SCNNode()
            ln.light = flash
            ln.position = SCNVector3(0.13, 0.32, 0.16)                 // in front of the little flashcube (camHead space)
            (rig.head ?? model).addChildNode(ln)
            rig.light = flash
            tuneGlass(model)
            cast.append(("AuditionCamera", model.parent ?? model, rig, .camera, AuditionVoices.camera))
        }
        if let loaded = load("AuditionTelevision", prefix: "tv", on: seat(5, in: room, layout: layout, forward: 0.05), scale: 1.25,
                             required: ["tvHead", "tvMouth", "tvEyeL", "tvPupilL", "tvAntL", "tvAntR"]) {
            let model = loaded.0
            var rig = loaded.1
            extras(["tvAntL", "tvAntR", "tvKnob0", "tvKnob1"], in: model, rig: &rig)
            if let glow = material("tvGlow", in: model) {
                glow.emission.contents = UIColor(red: 0.85, green: 0.95, blue: 0.9, alpha: 1)
                glow.emission.intensity = 0.9
                rig.materials["tvGlow"] = glow
            }
            if let screen = material("tvScreenFace", in: model) {
                screen.emission.contents = UIColor(red: 0.12, green: 0.2, blue: 0.18, alpha: 1)
                screen.emission.intensity = 0.5
            }
            if let head = rig.head { rig.overlay = makeStatic(on: head) }
            cast.append(("AuditionTelevision", model.parent ?? model, rig, .television, AuditionVoices.television))
        }
        return cast
    }

    /// The television's static: a plane of grey noise over the screen,
    /// invisible until it changes channel or is startled.
    private static func makeStatic(on head: SCNNode) -> SCNNode {
        let w = 96, h = 72
        var bytes = [UInt8](repeating: 0, count: w * h)
        var rng = Rand(seed: 0x57A71C)
        for i in 0..<bytes.count { bytes[i] = UInt8(40 + Int(rng.unit() * 200)) }
        var image: UIImage?
        if let provider = CGDataProvider(data: Data(bytes) as CFData),
           let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            image = UIImage(cgImage: cg)
        }
        let plane = SCNPlane(width: 0.27, height: 0.205)
        plane.cornerRadius = 0.035
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image ?? UIColor.gray
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.name = "tvStatic"
        node.position = SCNVector3(-0.04, 0.205, 0.159)        // the screen, in front of the face (tvHead space)
        node.opacity = 0
        node.renderingOrder = 30
        node.castsShadow = false
        head.addChildNode(node)
        return node
    }

    // MARK: Round four

    static func castRoundFour(_ room: SCNNode, layout: MeetingLayout) -> [Cast] {
        for i in 0...6 { room.childNode(withName: "conferenceRoomChair\(i)", recursively: false)?.isHidden = true }
        var cast: [Cast] = []
        // The LP, standing on the table at the head.
        if let loaded = load("AuditionLP", prefix: "lp", on: headOfTable(in: room, layout: layout), scale: 1.6,
                                    required: ["lpHead", "lpDisc", "lpMouth", "lpEyeL", "lpPupilL"]) {
            let model = loaded.0, rig0 = loaded.1
            var rig = rig0
            extras(["lpDisc"], in: model, rig: &rig)
            cast.append(("AuditionLP", model.parent ?? model, rig, .lp, AuditionVoices.lp))
        }
        // Juanita, standing in the first west place (as in round two).
        if HallwaysianJuanita.isEnabled, let model = HallwaysianJuanita.makeNode() {
            let t = layout.table
            let x = t.x - (ConferenceRoom.tableWidth / 2 + 0.42 + pullBack)
            let yaw = Float(Direction.west.yaw) - (swivel[0] ?? 0)
            let holder = SCNNode()
            holder.name = "auditionJuanita"
            holder.position = SCNVector3(x + 0.12, 0, t.y - 1.75)
            holder.eulerAngles.y = yaw
            holder.addChildNode(model)
            room.addChildNode(holder)
            cast.append(("Juanita", holder, AuditionActor.rig(model, prefix: "admin"), .juanita, AuditionVoices.juanita))
        } else {
            diag("audition.missing", ["model": "Juanita"])
        }
        if let loaded = load("AuditionRoadMap", prefix: "map", on: seat(1, in: room, layout: layout, forward: 0.08, booster: true),
                                    scale: 1.5, required: ["mapHead", "mapMouth", "mapEyeL", "mapPanel1", "mapPanel5"]) {
            let model = loaded.0, rig0 = loaded.1
            var rig = rig0
            extras((1...5).map { "mapPanel\($0)" }, in: model, rig: &rig)
            // folded from the first frame
            for k in 1...5 {
                if let e = rig.extras["mapPanel\(k)"] { e.0.eulerAngles.y = e.2.y + (k % 2 == 1 ? 1 : -1) * (.pi - 0.06) }
            }
            cast.append(("AuditionRoadMap", model.parent ?? model, rig, .roadmap, AuditionVoices.roadmap))
        }
        if let loaded = load("AuditionVacuum2", prefix: "vac", on: seat(2, in: room, layout: layout, forward: 0.06), scale: 1.6,
                                    required: ["vacHead", "vacMouth", "vacEyeL", "vacTrunk1", "vacTrunk2", "vacTrunk3"]) {
            let model = loaded.0, rig0 = loaded.1
            cast.append(("AuditionVacuum2", model.parent ?? model, rig0, .vacuum, AuditionVoices.vacuum))
        }
        if let loaded = load("AuditionAccordion", prefix: "acc", on: seat(3, in: room, layout: layout, forward: 0.05), scale: 1.5,
                                    required: ["accHead", "accMouth", "accEyeL", "accBellows"]) {
            let model = loaded.0, rig0 = loaded.1
            cast.append(("AuditionAccordion", model.parent ?? model, rig0, .accordion, AuditionVoices.accordion))
        }
        if let loaded = load("AuditionDymo", prefix: "dymo", on: seat(4, in: room, layout: layout, forward: 0.06, booster: true),
                                    scale: 1.5, required: ["dymoHead", "dymoMouth", "dymoEyeL", "dymoWheel", "dymoHandle", "dymoTape"]) {
            let model = loaded.0, rig0 = loaded.1
            var rig = rig0
            extras(["dymoWheel", "dymoHandle", "dymoTape"], in: model, rig: &rig)
            cast.append(("AuditionDymo", model.parent ?? model, rig, .dymo, AuditionVoices.dymo))
        }
        // Mr. Tinky (original, or the film canister), on the booster on place 5.
        if let body = auditionTinkyBody() {
            let holder = seat(5, in: room, layout: layout, forward: 0.05, booster: true)
            let tinky = SCNNode()
            tinky.name = "auditionTinky"
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
}

// MARK: - Their voices (Hallenese; one each)

nonisolated extension AuditionVoices {
    /// Oct 12 (voice audition): the Telephone's voice is whichever one is
    /// chosen in Settings > Telephone Voice (TelephoneVoice) -- the original
    /// until someone picks another. Read when the cast is installed.
    static var telephone: [AuditionClip] { TelephoneVoice.selected.clips }

    /// The Telephone (ORIGINAL voice): a pompous baritone, measured, every
    /// phrase falling to a conclusion -- one of them announced with a short ring.
    static let telephoneOriginal: [AuditionClip] = [
        ("aud3-tel-0", [S(v: 1, s: 0.2, a: 130, b: 150, stop: true), S(v: 5, s: 0.16, a: 150, b: 140), S(v: 0, s: 0.36, a: 145, b: 110)]),
        ("aud3-tel-1", [S(v: 4, s: 0.14, a: 120, b: 135, stop: true), S(v: 1, s: 0.18, a: 140, b: 150), S(v: 5, s: 0.14, a: 148, b: 138, stop: true),
                        S(v: 0, s: 0.4, a: 140, b: 105)]),
        ("aud3-tel-2", [S(v: 0, s: 0.3, a: 150, b: 160), S(v: 1, s: 0.2, a: 155, b: 130, gap: 0.12), S(v: 4, s: 0.34, a: 132, b: 112)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.9) {
            var rng = Rand(seed: stableSeed(name))
            let voice = MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 0.86, breath: 0.1)
            guard name == "aud3-tel-1" else { return voice }
            var ring: [(at: Float, samples: [Float], gain: Float)] = []
            for k in 0..<6 {
                ring.append((at: Float(k) * 0.035, samples: MenagerieSound.strike([(1150, 0.04, 0.6), (2300, 0.03, 0.3)], seconds: 0.06, noise: 0.05, rng: &rng), gain: 0.35))
            }
            let bell = MenagerieSound.mix(ring)
            return MenagerieSound.mix([(at: 0, samples: bell, gain: 1), (at: 0.3, samples: voice, gain: 1)])
        }
    }
    static let telephoneLaugh: [AuditionClip] = [("aud3-tel-laugh", [S(v: 1, s: 0.12, a: 140, b: 132, stop: true), S(v: 1, s: 0.12, a: 134, b: 124, stop: true),
                                                                   S(v: 1, s: 0.18, a: 126, b: 110, stop: true)])].compactMap { name, syl in
        clip(name, volume: 0.8) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.09; return x }, seed: stableSeed(name), formantScale: 0.86, breath: 0.25) }
    }
    // MARK: Oct 12 -- THE TELEPHONE VOICE AUDITION (three candidates)
    //
    // Why the original reads as "Jabba": f0 105-160 Hz (low), formants scaled
    // down 14% (a big, dark body), syllables 0.14-0.4 s (slow), 3% jitter on a
    // low pitch (rasp), and only THREE fixed phrases, all with the same
    // falling contour, so his idle remarks keep coming round identically.
    // Each candidate: a different register, pace, timbre and melody; the same
    // three roles for the show's cues (0 = proud statement / the order,
    // 1 = the ring + announcement, 2 = the emphatic flourish) plus three more
    // remarks for the idle chatter (3 = a question, 4 = an impatient aside,
    // 5 = a pleased "indeed"), and its own laugh.

    private static func ring(_ name: String, strikes: Int, spacing: Float, pitch: Float, gain: Float) -> [Float] {
        var rng = Rand(seed: stableSeed(name + "-ring"))
        var parts: [(at: Float, samples: [Float], gain: Float)] = []
        for k in 0..<strikes {
            parts.append((at: Float(k) * spacing, samples: MenagerieSound.strike([(pitch, 0.04, 0.6), (pitch * 2, 0.03, 0.3)], seconds: 0.06,
                                                                                    noise: 0.05, rng: &rng), gain: gain))
        }
        return MenagerieSound.mix(parts)
    }

    /// Renders one candidate's phrases (index 1 announced by its ring).
    private static func candidate(_ prefix: String, _ phrases: [[S]], formantScale: Float, breath: Float, jitter: Float,
                                  openQuotient: Float, vibrato: Float, ring ringSpec: (Int, Float, Float, Float)) -> [AuditionClip] {
        phrases.enumerated().compactMap { (i, syl) -> AuditionClip? in
            let name = "\(prefix)-\(i)"
            return clip(name, volume: 0.9) {
                let voice = MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: formantScale, breath: breath,
                                                jitter: jitter, openQuotient: openQuotient, vibrato: vibrato)
                guard i == 1 else { return voice }
                let bell = ring(name, strikes: ringSpec.0, spacing: ringSpec.1, pitch: ringSpec.2, gain: ringSpec.3)
                return MenagerieSound.mix([(at: 0, samples: bell, gain: 1),
                                           (at: Float(bell.count) / MenagerieSound.rate + 0.06, samples: voice, gain: 1)])
            }
        }
    }

    private static func candidateLaugh(_ name: String, _ syl: [S], formantScale: Float, jitter: Float, openQuotient: Float) -> [AuditionClip] {
        [clip(name, volume: 0.8) {
            MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: formantScale, breath: 0.12, jitter: jitter, openQuotient: openQuotient)
        }].compactMap { $0 }
    }

    /// A -- RADIO EXECUTIVE: crisp mid-register (150-250 Hz), polished, a
    /// little theatrical; brisk syllables, a warm vibrato on the held ends.
    static let telephoneA: [AuditionClip] = candidate("aud5-telA", [
        [S(v: 0, s: 0.10, a: 170, b: 200, stop: true), S(v: 4, s: 0.09, a: 205, b: 215), S(v: 1, s: 0.16, a: 225, b: 190, gap: 0.07),
         S(v: 2, s: 0.08, a: 180, b: 186, stop: true), S(v: 5, s: 0.10, a: 190, b: 176), S(v: 0, s: 0.24, a: 186, b: 150)],
        [S(v: 2, s: 0.08, a: 180, b: 195, stop: true), S(v: 4, s: 0.09, a: 200, b: 215), S(v: 1, s: 0.12, a: 220, b: 236, stop: true),
         S(v: 0, s: 0.30, a: 242, b: 172)],
        [S(v: 5, s: 0.08, a: 190, b: 230, stop: true), S(v: 0, s: 0.14, a: 240, b: 252), S(v: 2, s: 0.08, a: 236, b: 220, stop: true),
         S(v: 1, s: 0.32, a: 250, b: 160)],
        [S(v: 4, s: 0.09, a: 170, b: 176), S(v: 1, s: 0.10, a: 180, b: 172, stop: true), S(v: 2, s: 0.24, a: 182, b: 242)],
        [S(v: 5, s: 0.07, a: 200, b: 190, stop: true), S(v: 5, s: 0.07, a: 196, b: 186, gap: 0.03, stop: true), S(v: 4, s: 0.12, a: 190, b: 160)],
        [S(v: 6, s: 0.12, a: 172, b: 190), S(v: 6, s: 0.18, a: 200, b: 165, gap: 0.04)],
    ], formantScale: 1.0, breath: 0.03, jitter: 0.008, openQuotient: 0.40, vibrato: 0.012, ring: (4, 0.04, 1250, 0.3))
    static let telephoneALaugh = candidateLaugh("aud5-telA-laugh", [S(v: 0, s: 0.07, a: 230, b: 240, gap: 0.06, stop: true),
                                                                   S(v: 0, s: 0.07, a: 226, b: 232, gap: 0.06, stop: true),
                                                                   S(v: 0, s: 0.11, a: 216, b: 188, stop: true)],
                                                formantScale: 1.0, jitter: 0.008, openQuotient: 0.40)

    /// B -- FAST-TALKING SALESMAN: bright and high (200-330 Hz), quick
    /// syllables run together, big jumps of emphasis, a sparkly double ring.
    static let telephoneB: [AuditionClip] = candidate("aud5-telB", [
        [S(v: 2, s: 0.06, a: 230, b: 262, gap: 0.025, stop: true), S(v: 4, s: 0.06, a: 266, b: 250, gap: 0.025),
         S(v: 0, s: 0.07, a: 256, b: 282, gap: 0.025, stop: true), S(v: 2, s: 0.06, a: 286, b: 270, gap: 0.025),
         S(v: 5, s: 0.07, a: 262, b: 282, gap: 0.025, stop: true), S(v: 1, s: 0.15, a: 300, b: 230)],
        [S(v: 0, s: 0.06, a: 240, b: 270, gap: 0.025, stop: true), S(v: 2, s: 0.06, a: 276, b: 292, gap: 0.025),
         S(v: 4, s: 0.07, a: 286, b: 300, gap: 0.025, stop: true), S(v: 0, s: 0.06, a: 300, b: 312, gap: 0.025), S(v: 1, s: 0.2, a: 322, b: 250)],
        [S(v: 2, s: 0.07, a: 262, b: 302, gap: 0.03, stop: true), S(v: 0, s: 0.10, a: 312, b: 332), S(v: 4, s: 0.06, a: 302, b: 280, gap: 0.025, stop: true),
         S(v: 2, s: 0.06, a: 290, b: 302, gap: 0.025), S(v: 0, s: 0.22, a: 322, b: 220)],
        [S(v: 4, s: 0.06, a: 240, b: 250, gap: 0.025), S(v: 2, s: 0.06, a: 250, b: 246, gap: 0.025, stop: true),
         S(v: 1, s: 0.07, a: 250, b: 262, gap: 0.025), S(v: 2, s: 0.16, a: 272, b: 332)],
        [S(v: 5, s: 0.05, a: 250, b: 240, gap: 0.02, stop: true), S(v: 4, s: 0.05, a: 246, b: 240, gap: 0.02),
         S(v: 2, s: 0.05, a: 240, b: 252, gap: 0.02, stop: true), S(v: 5, s: 0.10, a: 252, b: 210)],
        [S(v: 4, s: 0.06, a: 282, b: 300, gap: 0.03, stop: true), S(v: 2, s: 0.14, a: 302, b: 342)],
    ], formantScale: 1.1, breath: 0.02, jitter: 0.006, openQuotient: 0.34, vibrato: 0, ring: (6, 0.03, 1400, 0.32))
    static let telephoneBLaugh = candidateLaugh("aud5-telB-laugh", [S(v: 4, s: 0.05, a: 300, b: 322, gap: 0.04, stop: true),
                                                                   S(v: 4, s: 0.05, a: 310, b: 330, gap: 0.04, stop: true),
                                                                   S(v: 4, s: 0.05, a: 320, b: 340, gap: 0.04, stop: true),
                                                                   S(v: 2, s: 0.09, a: 340, b: 290, stop: true)],
                                                formantScale: 1.1, jitter: 0.006, openQuotient: 0.34)

    /// C -- DRY CORPORATE INTELLECTUAL: smooth (open, round pulse), a narrow
    /// 135-195 Hz range, unhurried but never slow, with deliberate little
    /// pauses before the last word; a single discreet ring.
    static let telephoneC: [AuditionClip] = candidate("aud5-telC", [
        [S(v: 1, s: 0.12, a: 165, b: 170), S(v: 4, s: 0.10, a: 172, b: 168, stop: true), S(v: 0, s: 0.14, a: 170, b: 160, gap: 0.17),
         S(v: 5, s: 0.10, a: 165, b: 162, stop: true), S(v: 1, s: 0.22, a: 160, b: 140)],
        [S(v: 2, s: 0.10, a: 160, b: 168, stop: true), S(v: 0, s: 0.14, a: 170, b: 175), S(v: 3, s: 0.12, a: 172, b: 165, gap: 0.18),
         S(v: 1, s: 0.26, a: 168, b: 138)],
        [S(v: 0, s: 0.12, a: 170, b: 192, stop: true), S(v: 4, s: 0.12, a: 194, b: 188), S(v: 1, s: 0.14, a: 186, b: 170, gap: 0.15),
         S(v: 5, s: 0.10, a: 165, b: 160, stop: true), S(v: 0, s: 0.26, a: 170, b: 134)],
        [S(v: 4, s: 0.10, a: 160, b: 162), S(v: 2, s: 0.10, a: 162, b: 160, stop: true), S(v: 1, s: 0.20, a: 160, b: 192)],
        [S(v: 6, s: 0.20, a: 170, b: 150, gap: 0.1), S(v: 5, s: 0.08, a: 155, b: 150, stop: true), S(v: 1, s: 0.16, a: 152, b: 140)],
        [S(v: 2, s: 0.08, a: 165, b: 160, stop: true), S(v: 4, s: 0.18, a: 165, b: 140)],
    ], formantScale: 1.02, breath: 0.05, jitter: 0.005, openQuotient: 0.52, vibrato: 0, ring: (2, 0.06, 1150, 0.22))
    static let telephoneCLaugh = candidateLaugh("aud5-telC-laugh", [S(v: 4, s: 0.06, a: 170, b: 165, gap: 0.1, stop: true),
                                                                   S(v: 4, s: 0.08, a: 165, b: 150, stop: true)],
                                                formantScale: 1.02, jitter: 0.005, openQuotient: 0.52)

    /// The receiver, slammed down: a bakelite bang and the bell's jangle.
    static let telephoneSlam: [AuditionClip] = [("aud3-tel-slam", 0)].compactMap { name, _ in
        clip(name, volume: 0.9) {
            var rng = Rand(seed: stableSeed(name))
            let bang = MenagerieSound.strike([(95, 0.08, 1), (240, 0.05, 0.5), (610, 0.02, 0.3)], seconds: 0.25, noise: 0.8, noiseDecay: 0.006, rng: &rng)
            let ding = MenagerieSound.strike([(1150, 0.35, 0.5), (2310, 0.2, 0.3), (3470, 0.1, 0.12)], seconds: 0.6, noise: 0.02, rng: &rng)
            return MenagerieSound.mix([(at: 0, samples: bang, gain: 1), (at: 0.01, samples: ding, gain: 0.35)])
        }
    }

    /// The View-Master: soft, breathy, wondering -- each phrase begins with the lever's click.
    static let viewmaster: [AuditionClip] = [
        ("aud3-vm-0", [S(v: 3, s: 0.3, a: 240, b: 290), S(v: 2, s: 0.36, a: 280, b: 250)]),
        ("aud3-vm-1", [S(v: 0, s: 0.2, a: 230, b: 260), S(v: 3, s: 0.22, a: 260, b: 300), S(v: 6, s: 0.34, a: 290, b: 240)]),
        ("aud3-vm-2", [S(v: 6, s: 0.42, a: 250, b: 310), S(v: 3, s: 0.3, a: 300, b: 260)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.6) {
            var rng = Rand(seed: stableSeed(name))
            let click = MenagerieSound.strike([(2900, 0.012, 0.6), (5200, 0.006, 0.3)], seconds: 0.03, noise: 0.4, rng: &rng)
            let voice = MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 1.1, breath: 0.35)
            return MenagerieSound.mix([(at: 0, samples: click, gain: 0.5), (at: 0.08, samples: voice, gain: 1)])
        }
    }
    static let viewmasterLaugh: [AuditionClip] = [("aud3-vm-laugh", [S(v: 3, s: 0.08, a: 280, b: 320), S(v: 3, s: 0.08, a: 300, b: 340), S(v: 3, s: 0.14, a: 320, b: 280)])].compactMap { name, syl in
        clip(name, volume: 0.55) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.06; return x }, seed: stableSeed(name), formantScale: 1.1, breath: 0.4) }
    }

    /// The Flashcube: a capacitor's rising whine, then a quick, jumpy little voice.
    static let flashcube: [AuditionClip] = [
        ("aud3-flash-0", [S(v: 2, s: 0.06, a: 420, b: 460, stop: true), S(v: 3, s: 0.06, a: 450, b: 440), S(v: 2, s: 0.1, a: 460, b: 500)]),
        ("aud3-flash-1", [S(v: 3, s: 0.05, a: 430, b: 450), S(v: 2, s: 0.05, a: 450, b: 470, stop: true), S(v: 3, s: 0.05, a: 470, b: 460),
                          S(v: 4, s: 0.12, a: 460, b: 400)]),
        ("aud3-flash-2", [S(v: 2, s: 0.08, a: 440, b: 480, stop: true), S(v: 2, s: 0.14, a: 480, b: 540)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.5) {
            let whine = MenagerieSound.sweep(1800, 5200, seconds: 0.32, wobble: 0.05)
            let voice = MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 1.45, breath: 0.05)
            return MenagerieSound.mix([(at: 0, samples: whine, gain: 0.07), (at: 0.28, samples: voice, gain: 1)])
        }
    }
    static let flashcubeLaugh: [AuditionClip] = [("aud3-flash-laugh", [S(v: 2, s: 0.04, a: 500, b: 520), S(v: 2, s: 0.04, a: 520, b: 540), S(v: 2, s: 0.08, a: 540, b: 480)])].compactMap { name, syl in
        clip(name, volume: 0.5) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.04; return x }, seed: stableSeed(name), formantScale: 1.45, breath: 0.1) }
    }

    /// The Television: a smooth announcer's swoop, over a faint hum and a crackle.
    static let television: [AuditionClip] = [
        ("aud3-tv-0", [S(v: 1, s: 0.2, a: 170, b: 220), S(v: 0, s: 0.18, a: 215, b: 200, stop: true), S(v: 5, s: 0.3, a: 205, b: 160)]),
        ("aud3-tv-1", [S(v: 4, s: 0.14, a: 190, b: 210, stop: true), S(v: 1, s: 0.24, a: 210, b: 240), S(v: 0, s: 0.3, a: 235, b: 170)]),
        ("aud3-tv-2", [S(v: 0, s: 0.16, a: 180, b: 200), S(v: 5, s: 0.14, a: 200, b: 190, stop: true), S(v: 1, s: 0.16, a: 195, b: 215), S(v: 0, s: 0.3, a: 210, b: 165)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.7) {
            var rng = Rand(seed: stableSeed(name))
            let voice = MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 1.0, breath: 0.08)
            let seconds = Float(voice.count) / MenagerieSound.rate
            let hum = MenagerieSound.sweep(120, 120, seconds: seconds, wobble: 0)
            let crackle = MenagerieSound.rustle(grains: 50, seconds: 0.1, grainLength: 0.002, rng: &rng)
            return MenagerieSound.mix([(at: 0, samples: crackle, gain: 0.3), (at: 0.06, samples: voice, gain: 1), (at: 0.06, samples: hum, gain: 0.05)])
        }
    }
    static let televisionLaugh: [AuditionClip] = [("aud3-tv-laugh", [S(v: 1, s: 0.1, a: 220, b: 200, stop: true), S(v: 1, s: 0.1, a: 210, b: 190, stop: true), S(v: 1, s: 0.16, a: 200, b: 170)])].compactMap { name, syl in
        clip(name, volume: 0.65) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.07; return x }, seed: stableSeed(name), formantScale: 1.0, breath: 0.2) }
    }

    /// The LP: a crooner's legato, with the soft crackle of the groove.
    static let lp: [AuditionClip] = [
        ("aud4-lp-0", [S(v: 0, s: 0.36, a: 150, b: 175), S(v: 1, s: 0.44, a: 172, b: 150)]),
        ("aud4-lp-1", [S(v: 3, s: 0.26, a: 160, b: 168), S(v: 0, s: 0.3, a: 170, b: 185), S(v: 1, s: 0.46, a: 182, b: 145)]),
        ("aud4-lp-2", [S(v: 6, s: 0.5, a: 145, b: 180), S(v: 0, s: 0.38, a: 178, b: 150)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.7) {
            var rng = Rand(seed: stableSeed(name))
            let voice = MeetingVoices.speak(syl, seed: stableSeed(name), formantScale: 0.95, breath: 0.22)
            let crackle = MenagerieSound.rustle(grains: 24, seconds: Float(voice.count) / MenagerieSound.rate + 0.2, grainLength: 0.0015, rng: &rng)
            return MenagerieSound.mix([(at: 0, samples: crackle, gain: 0.16), (at: 0.12, samples: voice, gain: 1)])
        }
    }
    static let lpLaugh: [AuditionClip] = [("aud4-lp-laugh", [S(v: 1, s: 0.14, a: 180, b: 165), S(v: 1, s: 0.14, a: 170, b: 155), S(v: 0, s: 0.22, a: 160, b: 140)])].compactMap { name, syl in
        clip(name, volume: 0.6) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.08; return x }, seed: stableSeed(name), formantScale: 0.95, breath: 0.3) }
    }

    /// The Road Map: crisp, quick, certain of itself -- with a crinkle of paper.
    static let roadmap: [AuditionClip] = [
        ("aud4-map-0", [S(v: 4, s: 0.07, a: 250, b: 270, stop: true), S(v: 2, s: 0.07, a: 270, b: 260), S(v: 4, s: 0.06, a: 265, b: 280, stop: true),
                        S(v: 0, s: 0.07, a: 280, b: 270), S(v: 2, s: 0.14, a: 275, b: 240)]),
        ("aud4-map-1", [S(v: 0, s: 0.08, a: 260, b: 280), S(v: 4, s: 0.06, a: 280, b: 270, stop: true), S(v: 2, s: 0.07, a: 270, b: 290),
                        S(v: 4, s: 0.06, a: 290, b: 280, stop: true), S(v: 0, s: 0.16, a: 285, b: 250)]),
        ("aud4-map-2", [S(v: 2, s: 0.1, a: 270, b: 300, stop: true), S(v: 4, s: 0.08, a: 300, b: 290), S(v: 0, s: 0.18, a: 295, b: 255)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.65) {
            var rng = Rand(seed: stableSeed(name))
            let crinkle = MenagerieSound.rustle(grains: 60, seconds: 0.18, grainLength: 0.004, rng: &rng)
            let voice = MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.03; return x }, seed: stableSeed(name), formantScale: 1.2, breath: 0.05)
            return MenagerieSound.mix([(at: 0, samples: crinkle, gain: 0.3), (at: 0.1, samples: voice, gain: 1)])
        }
    }
    static let roadmapLaugh: [AuditionClip] = [("aud4-map-laugh", [S(v: 4, s: 0.05, a: 300, b: 320), S(v: 4, s: 0.05, a: 310, b: 330), S(v: 4, s: 0.09, a: 320, b: 280)])].compactMap { name, syl in
        clip(name, volume: 0.6) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.05; return x }, seed: stableSeed(name), formantScale: 1.2, breath: 0.1) }
    }

    /// The Dymo: clipped syllables, each one punched out with a click.
    static let dymo: [AuditionClip] = [
        ("aud4-dymo-0", [S(v: 2, s: 0.06, a: 300, b: 300, stop: true), S(v: 4, s: 0.06, a: 310, b: 310, stop: true), S(v: 0, s: 0.08, a: 300, b: 290, stop: true)]),
        ("aud4-dymo-1", [S(v: 4, s: 0.05, a: 320, b: 320, stop: true), S(v: 2, s: 0.05, a: 300, b: 300, stop: true), S(v: 4, s: 0.05, a: 320, b: 320, stop: true),
                         S(v: 2, s: 0.09, a: 310, b: 280, stop: true)]),
        ("aud4-dymo-2", [S(v: 0, s: 0.07, a: 290, b: 300, stop: true), S(v: 0, s: 0.07, a: 300, b: 310, stop: true)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.6) {
            var rng = Rand(seed: stableSeed(name))
            let voice = MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.07; return x }, seed: stableSeed(name), formantScale: 1.3, breath: 0.04)
            var parts: [(at: Float, samples: [Float], gain: Float)] = [(at: 0, samples: voice, gain: 1)]
            var at: Float = 0
            for s in syl {
                parts.append((at: at, samples: MenagerieSound.strike([(2400, 0.01, 0.6), (4100, 0.006, 0.3)], seconds: 0.025, noise: 0.6, rng: &rng), gain: 0.4))
                at += s.s + 0.07
            }
            return MenagerieSound.mix(parts)
        }
    }
    static let dymoLaugh: [AuditionClip] = [("aud4-dymo-laugh", [S(v: 2, s: 0.04, a: 330, b: 330, stop: true), S(v: 2, s: 0.04, a: 340, b: 340, stop: true), S(v: 2, s: 0.06, a: 350, b: 320, stop: true)])].compactMap { name, syl in
        clip(name, volume: 0.55) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.05; return x }, seed: stableSeed(name), formantScale: 1.3, breath: 0.08) }
    }
    // MARK: Round five (Oct 12, refinement)

    /// The Camera: an eager, bouncy tourist of a voice -- "look at this!"
    static let camera: [AuditionClip] = [
        ("aud5-cam-0", [S(v: 2, s: 0.08, a: 280, b: 320, stop: true), S(v: 4, s: 0.07, a: 320, b: 300), S(v: 2, s: 0.16, a: 310, b: 360)]),
        ("aud5-cam-1", [S(v: 0, s: 0.07, a: 270, b: 290), S(v: 2, s: 0.06, a: 300, b: 320, stop: true), S(v: 4, s: 0.06, a: 320, b: 310),
                        S(v: 0, s: 0.16, a: 320, b: 280)]),
        ("aud5-cam-2", [S(v: 4, s: 0.1, a: 290, b: 340), S(v: 2, s: 0.08, a: 340, b: 330, stop: true), S(v: 0, s: 0.14, a: 330, b: 300)]),
    ].compactMap { name, syl in
        clip(name, volume: 0.6) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.04; return x }, seed: stableSeed(name), formantScale: 1.18, breath: 0.06) }
    }
    static let cameraLaugh: [AuditionClip] = [("aud5-cam-laugh", [S(v: 2, s: 0.05, a: 340, b: 360), S(v: 2, s: 0.05, a: 350, b: 370), S(v: 2, s: 0.05, a: 360, b: 380),
                                                                 S(v: 2, s: 0.09, a: 370, b: 330)])].compactMap { name, syl in
        clip(name, volume: 0.55) { MeetingVoices.speak(syl.map { var x = $0; x.gap = 0.04; return x }, seed: stableSeed(name), formantScale: 1.18, breath: 0.12) }
    }
    /// The shutter: a click, and the little whirr of the film winding on.
    static let cameraShutter: [AuditionClip] = [("aud5-cam-shutter", 0)].compactMap { name, _ in
        clip(name, volume: 0.5) {
            var rng = Rand(seed: stableSeed(name))
            let click = MenagerieSound.strike([(2600, 0.012, 0.7), (4400, 0.008, 0.4)], seconds: 0.04, noise: 0.7, noiseDecay: 0.004, rng: &rng)
            let clack = MenagerieSound.strike([(1700, 0.01, 0.5)], seconds: 0.03, noise: 0.5, rng: &rng)
            let whirr = MenagerieSound.sweep(420, 640, seconds: 0.45, wobble: 0.4)
            return MenagerieSound.mix([(at: 0, samples: click, gain: 1), (at: 0.06, samples: clack, gain: 0.7), (at: 0.38, samples: whirr, gain: 0.12)])
        }
    }
}


// MARK: - Oct 12 -- THE TELEPHONE VOICE AUDITION (temporary; Settings, developer tools)
//
// Settings > Telephone Voice (developer tools only) picks which voice the
// Telephone speaks with -- ORIGINAL (the default; nothing changes until one is
// chosen), A, B or C -- and "Play sample" plays that voice's same three show
// lines (the statement, the ring + announcement, the flourish) and its laugh,
// right there. In the game the choice applies the next time the cast is put in
// the room: a REPLAY of THE BOX (tap the screen), or the next visit to Floor 3.
// To remove the audition: delete this enum's use in PlayerSettings and leave
// `AuditionVoices.telephone` on the voice you chose.
nonisolated enum TelephoneVoice: String, CaseIterable, Identifiable {
    case original, radioExecutive, salesman, intellectual
    static let defaultsKey = "HallwaysTelephoneVoice"
    var id: String { rawValue }

    static var selected: TelephoneVoice {
        TelephoneVoice(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .original
    }

    var title: String {
        switch self {
        case .original: return "Original"
        case .radioExecutive: return "A \u{2014} Radio Executive"
        case .salesman: return "B \u{2014} Fast-Talking Salesman"
        case .intellectual: return "C \u{2014} Dry Corporate Intellectual"
        }
    }

    var clips: [AuditionClip] {
        switch self {
        case .original: return AuditionVoices.telephoneOriginal
        case .radioExecutive: return AuditionVoices.telephoneA
        case .salesman: return AuditionVoices.telephoneB
        case .intellectual: return AuditionVoices.telephoneC
        }
    }

    var laugh: [AuditionClip] {
        switch self {
        case .original: return AuditionVoices.telephoneLaugh
        case .radioExecutive: return AuditionVoices.telephoneALaugh
        case .salesman: return AuditionVoices.telephoneBLaugh
        case .intellectual: return AuditionVoices.telephoneCLaugh
        }
    }

    /// The cached WAV names of the sample: the show's three lines, then the laugh.
    private var sampleFiles: [String] {
        switch self {
        case .original: return ["aud3-tel-0", "aud3-tel-1", "aud3-tel-2", "aud3-tel-laugh"]
        case .radioExecutive: return ["aud5-telA-0", "aud5-telA-1", "aud5-telA-2", "aud5-telA-laugh"]
        case .salesman: return ["aud5-telB-0", "aud5-telB-1", "aud5-telB-2", "aud5-telB-laugh"]
        case .intellectual: return ["aud5-telC-0", "aud5-telC-1", "aud5-telC-2", "aud5-telC-laugh"]
        }
    }

    @MainActor private static var samplePlayer: AVAudioPlayer?
    @MainActor private static var sampleToken = 0

    /// Plays this voice's sample (stops any sample already playing).
    @MainActor func playSample() {
        _ = (clips, laugh)                                          // renders (and caches) them if need be
        Self.sampleToken += 1
        let token = Self.sampleToken
        let urls = sampleFiles.map { FileManager.default.temporaryDirectory.appendingPathComponent("mng-v1-\($0).wav") }
        diag("telephoneVoice.sample", ["voice": rawValue])
        func play(_ i: Int) {
            guard token == Self.sampleToken, i < urls.count else { return }
            guard let player = try? AVAudioPlayer(contentsOf: urls[i]) else { play(i + 1); return }
            HallwaysAudio.shared.manage(player)                         // Oct 24: under Mute / the silences, like every player
            Self.samplePlayer = player
            player.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 0.55) { play(i + 1) }
        }
        Self.samplePlayer?.stop()
        play(0)
    }
}
