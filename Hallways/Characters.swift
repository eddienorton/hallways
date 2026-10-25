//
//  Characters.swift
//  Hallways
//
//  Oct 18 (contacts) -- WHO LIVES HERE: one registry of the building's
//  characters, and the player's Contacts (the ones they've met).
//
//  CharacterRegistry  each character once: its name, a line about it, how it
//                     sounds (its own game sounds, by name -- the very files
//                     its body plays), what to draw if no portrait yet, and how
//                     to find its body in the scene the player is in. A new
//                     critter joins Contacts by adding an entry here: no app code.
//  ContactsStore      who the player has met (and when), and each one's portrait
//                     -- drawn from its real body, the moment they meet. Met =
//                     its body within a few metres of the player. Kept in normal
//                     play (UserDefaults "contacts.met", portraits as PNGs);
//                     in a developer test mode nothing is written, so test
//                     encounters never become the player's discoveries.
//  ContactPortrait    a picture of a body: a clone of its node, still, lit,
//                     rendered offscreen once.
//
//  Contacts shows; it never calls, summons, messages or tracks anyone.
//

import SceneKit
import SwiftUI
import UIKit      // (UIImage, pngData, UIColor -- member import visibility is on)
import Combine    // (ObservableObject / @Published -- member import visibility is on)
import AVFAudio
import Metal

struct CharacterIdentity: Identifiable {
    let id: String
    let name: String
    let blurb: String
    /// Drawn until there's a portrait (an SF Symbol) and its colour.
    let symbol: String
    let tint: Color
    /// Its sound, as heard in the game: synthesised sounds by name, each at a
    /// time (seconds) -- played plainly, wherever it is.
    let preview: [(sound: String, at: Double)]
    /// Make sure those sounds exist (their files are rendered on first use).
    let prepareSounds: () -> Void
    /// Its body in the scene the player is in, if it's there.
    let body: () -> SCNNode?
    /// Oct 19: met only at a story moment (the game calls ContactsStore.meet
    /// itself) -- never by standing near its body, which could happen through
    /// a wall or before the two have actually met.
    var metByEventOnly = false
}

enum CharacterRegistry {
    /// The scene the player is in (FloorPresenter sets it).
    static weak var sceneRoot: SCNNode?

    private static func resident(_ id: String) -> () -> SCNNode? {
        { BuildingLife.shared.presentations.first { $0.residentID == id }?.bodyNode }
    }

    private static func inScene(_ node: SCNNode) -> Bool {
        guard let root = sceneRoot else { return false }
        var n: SCNNode? = node
        while let c = n { if c === root { return true }; n = c.parent }
        return false
    }

    static let all: [CharacterIdentity] = [
        CharacterIdentity(id: RoamingChairKind.id, name: "Chair",
                          blurb: "A wooden office chair with a mind of its own. Wanders from room to room and takes the elevator.",
                          symbol: "chair.fill", tint: Color(red: 0.45, green: 0.28, blue: 0.16),
                          preview: [("chair-softcreak-0", 0), ("chair-shuffle-1", 0.55), ("chair-shuffle-3", 1.15), ("chair-swivel", 1.7)],
                          prepareSounds: { _ = ResidentVoice.chairCreaks; _ = ResidentVoice.chairShuffles; _ = ResidentVoice.chairSwivel },
                          body: CharacterRegistry.resident(RoamingChairKind.id)),
        CharacterIdentity(id: Butterfly.id, name: "Butterfly",
                          blurb: "Violet wings, glowing gold eyes. She seems to know what's wrong in the building.",
                          symbol: "sparkles", tint: Color(red: 0.42, green: 0.2, blue: 0.62),
                          preview: [("butterfly-chirp2", 0), ("butterfly-wings-0", 0.5), ("butterfly-chirp", 1.0)],
                          prepareSounds: { _ = ButterflySound.chirp2; _ = ButterflySound.chirp; _ = ResidentVoice.butterflyWings },
                          body: CharacterRegistry.resident(Butterfly.id)),
        // Oct 19: this is Mr. Tinky (the id stays "jeff" -- the cast's id -- so a save
        // that has already met him keeps him, portrait and all, under the right name).
        CharacterIdentity(id: CritterID.jeff.rawValue, name: "Tinky",
                          blurb: "Mr. Tinky, a small tin-can fellow from Administration. Curious about everything.",
                          symbol: "cylinder.fill", tint: Color(red: 0.55, green: 0.58, blue: 0.62),
                          preview: [("fred-v1-query", 0), ("fred-v1-happy", 0.6)],
                          prepareSounds: { _ = FredSound.query; _ = FredSound.happy },
                          body: { CritterTags.bodies(of: .jeff).first { $0.parent != nil && CharacterRegistry.inScene($0) } },
                          metByEventOnly: true),                    // (Oct 19: when he first speaks to you -- FredOfficeEncounter)
        // Oct 19: Juanita, the Administrator -- met when she first greets you at the
        // Floor 2 counter (AdministrationReception.greet), before the ID card.
        CharacterIdentity(id: CharacterRegistry.juanitaID, name: "Juanita",
                          blurb: "The Administrator on Floor 2. She'll point you the right way -- the first few times.",
                          symbol: "person.text.rectangle.fill", tint: Color(red: 0.2, green: 0.45, blue: 0.55),
                          preview: [("admin-greet-v2", 0)],
                          prepareSounds: { _ = AdministratorVoice.greeting },
                          body: { CharacterRegistry.sceneRoot?.childNode(withName: AdministrationReception.standInNodeName, recursively: true) },
                          metByEventOnly: true),
        // Oct 18 (open the building): the building's other residents (ResidentCritters.swift) --
        // each met like the others: its body near the player, on whatever floor.
        // (Oct 19, Stage A: Clacker, Little Clacker, Little Pottle, Dog and Cat retired.)
        CharacterIdentity(id: "pottle.1", name: "Pottle",
                          blurb: "A potted plant on pencil legs. Slow, patient, fond of light and water.",
                          symbol: "leaf.fill", tint: Color(red: 0.25, green: 0.55, blue: 0.25),
                          preview: [("pottle-rustle-0", 0), ("pottle-rustle-2", 0.7)],
                          prepareSounds: { _ = Pottle.rustles },
                          body: CharacterRegistry.resident("pottle.1")),
    ] + HallwaysianCast.identities                 // Oct 19: the six Hallwaysians (HallwaysianResidents.swift)
      + CastResidents.identities                   // Oct 21: the meeting's cast in the building (ResidentCast.swift)

    static func identity(_ id: String) -> CharacterIdentity? { all.first { $0.id == id } }

    /// Oct 19: Juanita's contact id.
    static let juanitaID = "juanita"
    /// Oct 19: Tinky's contact id (the cast's id for him).
    static var tinkyID: String { CritterID.jeff.rawValue }
}

// MARK: - The player's contacts

final class ContactsStore: ObservableObject {
    static let shared = ContactsStore(defaults: .standard,
                                      persists: !ResumeState.runningUnderTests && BuildingLife.testMode == nil)

    static let storageKey = "contacts.met"
    /// Met: its body this close to the player (metres).
    static let meetingDistance: Float = 5.5

    @Published private(set) var met: [String: Date] = [:]
    private var portraits: [String: UIImage] = [:]               // (a cache: not published -- read while drawing)
    let persists: Bool
    private let defaults: UserDefaults
    private var players: [AVAudioPlayer] = []

    /// Where portraits are kept (tests pass their own).
    private let portraitDirectory: URL

    init(defaults: UserDefaults, persists: Bool, portraitDirectory: URL? = nil) {
        self.defaults = defaults
        self.persists = persists
        self.portraitDirectory = portraitDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Contacts")
        if let data = defaults.data(forKey: Self.storageKey), let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            met = map
        }
        purgeRetired()
    }

    /// Oct 19 (Stage A): characters retired from the cast for good. A save that
    /// met any of them drops the entry (and its portrait), so no phantom contact
    /// lingers. Anyone else unknown is left alone (it's simply never listed).
    static let retiredIDs: Set<String> = ResidentRoster.retiredIDs

    private func purgeRetired() {
        let gone = met.keys.filter { Self.retiredIDs.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone {
            met[id] = nil
            portraits[id] = nil
            if persists { try? FileManager.default.removeItem(at: portraitURL(id)) }
        }
        if persists, let data = try? JSONEncoder().encode(met) { defaults.set(data, forKey: Self.storageKey) }
        LifeLog.event("contacts", "contacts.retired.purged", ["ids": gone.sorted().joined(separator: ",")])
    }

    /// The met characters, in the order met.
    var contacts: [CharacterIdentity] {
        if Self.showsEveryone { return CharacterRegistry.all }      // (DEBUG display only: nobody is marked met)
        return CharacterRegistry.all.filter { met[$0.id] != nil }.sorted { (met[$0.id] ?? .distantPast) < (met[$1.id] ?? .distantPast) }
    }

    /// Oct 18 (open the building): a developer's view of everyone, unmet included
    /// (-HallwaysContactsShowAll YES, DEBUG builds only). Display only: it never
    /// marks anyone met and never writes a thing, so the player's own discoveries
    /// are untouched; the unmet show their symbol until really met.
    static var showsEveryone: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "HallwaysContactsShowAll")
        #else
        return false
        #endif
    }

    func hasMet(_ id: String) -> Bool { met[id] != nil }

    /// They've met (true the first time). `body`: its body now, for its portrait.
    @discardableResult
    func meet(_ id: String, at date: Date = Date(), body: SCNNode? = nil) -> Bool {
        guard met[id] == nil, CharacterRegistry.identity(id) != nil else { return false }
        met[id] = date
        if let body, let image = ContactPortrait.render(body) {
            portraits[id] = image
            if persists, let png = image.pngData() { try? png.write(to: portraitURL(id)) }
        }
        if persists, let data = try? JSONEncoder().encode(met) { defaults.set(data, forKey: Self.storageKey) }
        LifeLog.event(id, "contact.added", ["saved": persists, "portrait": portraits[id] != nil])
        return true
    }

    /// Once a second: anyone the player is close to now is met.
    func check(player: SIMD2<Float>?, now: Date = Date()) {
        guard let player else { return }
        for c in CharacterRegistry.all where met[c.id] == nil && !c.metByEventOnly {
            guard let node = c.body() else { continue }
            let p = node.worldPosition
            if simd_distance(SIMD2<Float>(p.x, p.z), player) <= Self.meetingDistance { meet(c.id, at: now, body: node) }
        }
    }

    func portrait(_ id: String) -> UIImage? {
        if let image = portraits[id] { return image }
        guard let data = try? Data(contentsOf: portraitURL(id)), let image = UIImage(data: data) else { return nil }
        portraits[id] = image
        return image
    }

    /// Its sound, plainly (not from where it is), through the game's Mute.
    func preview(_ id: String) {
        guard let c = CharacterRegistry.identity(id) else { return }
        c.prepareSounds()
        play(id, c.preview)
    }

    /// Oct 22 (musical identities): the Directory's Music / Original buttons.
    /// Oct 22 (later): every character with a signature. Its file is made in the
    /// background if it isn't there yet (never on the main thread), then it plays.
    func previewMusic(_ id: String) {
        guard HallwaysianMusic.signature(id) != nil else { return }
        players.forEach { $0.stop() }
        HallwaysianMusic.prepare(id) { [weak self] in
            self?.play(id, [(HallwaysianMusic.soundName(id), 0)], cutOff: true)
        }
    }

    /// Its original voice or sound: a Hallwaysian's Hallenese hello; a cast
    /// member's own first and last lines in the voice it has now (the Telephone's
    /// chosen voice -- so never silent); anyone else, its Directory sound as before.
    func previewOriginal(_ id: String) {
        if let p = HallwaysianCast.persona(id) {
            guard HallwaysianVoice.original(p) != nil else { return }
            play(id, [(HallwaysianVoice.soundName(id), 0)], cutOff: true)
        } else if let m = CastResidents.member(id) {
            let clips = m.voices()
            guard let first = clips.first else { return }
            var sounds: [(sound: String, at: Double)] = [(SoundCatalog.name(of: first.source), 0)]
            if clips.count > 1, let last = clips.last { sounds.append((SoundCatalog.name(of: last.source), first.duration + 0.25)) }
            play(id, sounds, cutOff: true)
        } else if let c = CharacterRegistry.identity(id) {
            c.prepareSounds()
            play(id, c.preview, cutOff: true)
        }
    }

    /// Sounds already rendered, each at its time. `cutOff`: a preview still playing
    /// stops first (Music and Original, compared back to back, never overlap).
    private func play(_ id: String, _ sounds: [(sound: String, at: Double)], cutOff: Bool = false) {
        if cutOff { players.forEach { $0.stop() } }
        players.removeAll { !$0.isPlaying }
        for (sound, at) in sounds {
            guard let player = try? AVAudioPlayer(contentsOf: SoundCatalog.url(sound)) else { continue }
            player.prepareToPlay()
            HallwaysAudio.shared.manage(player)
            players.append(player)
            player.play(atTime: player.deviceCurrentTime + at)
        }
        LifeLog.event(id, "contact.preview", ["sounds": sounds.map { $0.sound }.joined(separator: ",")])
        StickyProbe.note("Directory sound \(id)")                   // Oct 22 (evening): measurement only
    }

    private func portraitURL(_ id: String) -> URL {
        try? FileManager.default.createDirectory(at: portraitDirectory, withIntermediateDirectories: true)
        return portraitDirectory.appendingPathComponent("\(id).png")
    }

    /// Start Over: nobody met yet.
    func resetForNewPlayer() {
        for id in met.keys { try? FileManager.default.removeItem(at: portraitURL(id)) }
        met = [:]
        portraits = [:]
        defaults.removeObject(forKey: Self.storageKey)
    }
}

// MARK: - Portraits

enum ContactPortrait {
    /// The body, still and lit, from the front -- a clone, so the real one is untouched.
    static func render(_ body: SCNNode, size: CGFloat = 256) -> UIImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let clone = body.clone()
        clone.enumerateHierarchy { n, _ in
            n.removeAllActions()
            n.removeAllAudioPlayers()
            if n.name == "lifeTestMarker" { n.isHidden = true }
        }
        clone.position = SCNVector3Zero
        clone.eulerAngles = SCNVector3Zero                          // (facing -z, toward the camera below)
        clone.scale = SCNVector3(1, 1, 1)                           // (Oct 20: a 1.2x body framed as designed -- the sphere below is unscaled)
        let scene = SCNScene()
        scene.rootNode.addChildNode(clone)
        let (center, radius) = clone.boundingSphere
        let r = max(0.05, radius)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.camera?.zNear = 0.01
        camera.position = SCNVector3(center.x + r * 0.5, center.y + r * 0.35, center.z - r * 3.6)
        camera.look(at: center)
        scene.rootNode.addChildNode(camera)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 550
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 900
        key.position = SCNVector3(center.x + r, center.y + r * 2, center.z - r * 2)
        key.look(at: center)
        scene.rootNode.addChildNode(key)
        scene.background.contents = UIColor.clear
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
    }
}
