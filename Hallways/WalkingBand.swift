//
//  WalkingBand.swift
//  Hallways
//
//  Oct 25 -- THE WALKING BAND (an experiment).
//
//  The residents following the player (FOLLOW ME -- FollowMe.ids, in the order they were asked) play the
//  composition of the player's floor (Oct 25: FloorMusic.swift; the Lab's last choice only for a floor
//  without one), on their Music Lab instruments, exactly as if the player had
//  switched them on in the Lab: the first follower takes the piece's Layer 1, the next the lowest free
//  layer, and so on; one that stops following frees its layer and nobody else moves (followers beyond the
//  last layer wait for one). The piece plays round and round (its last bar, then its first) while anyone
//  musical follows; when the last one goes it fades out and stops. A new floor (once arrived, and a second
//  after): this piece fades out, then the new floor's begins from its top -- never both at once -- with the
//  same followers on the same layers wherever the new piece has them.
//
//  ONE ENGINE: the Music Lab's own (MusicLab.shared's BandEngine: its samplers, SoundFonts, arranger and
//  shared clock), used only while the Lab itself isn't -- opening the Directory stops the walking band at
//  once (the Lab takes over; afterwards the band starts again from the top if followers are still there).
//  No recordings, no second clock. Its sound is not positional (the band is with the player).
//
//  WHO COUNTS: a follower with an INSTRUMENT in the Lab (BandInstruments.byResident). The singers (and
//  anyone without an instrument) keep their walking music as before -- the pieces aren't sung yet.
//
//  THE HALLWAY'S OWN MUSIC, KEPT: while the band plays, the walking music (ResidentWalkingMusic) and the
//  living orchestra (LivingOrchestra) are ducked smoothly to `ambienceDuck` (`ambience`, read by both) and
//  come back the same way after; a band member's own walking phrases don't play (no double-playing), and
//  the orchestra leaves it out of its mix. Greetings, goodbyes and check-ins are untouched.
//
//  QUIET: Mute, Settings' suppression and any story under way (ResidentMusicConductor.storyQuiet) bring the
//  band down (its clock keeps going) and back up.
//
//  LISTEN on a critter's card (CritterMenu): a short audition of its Music Lab instrument (the Lab's
//  audition) -- it recruits nobody and starts no piece.
//
//  OFF (everything exactly as before): launch with `-HallwaysWalkingBand NO`.
//

import Foundation
import QuartzCore

@MainActor
final class WalkingBand {
    static let shared = WalkingBand()

    /// On unless switched off (`-HallwaysWalkingBand NO`).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "HallwaysWalkingBand") == nil || UserDefaults.standard.bool(forKey: "HallwaysWalkingBand")
    }

    struct Tuning {
        /// The band's level in the hallways (the Lab plays at 0.9).
        var level: Float = 0.55
        /// Seconds to come in / to fade away.
        var fadeIn: Double = 1.5
        var fadeOut: Double = 2.5
        /// The hallway's own music (walking music, the living orchestra) while the band plays: this share.
        var ambienceDuck: Float = 0.35
        /// Seconds for the hallway's music to go down / come back.
        var duckTime: Double = 1.5
    }
    static var tuning = Tuning()
    static let interval: TimeInterval = 0.1

    /// The followers playing now (FOLLOW ME order).
    private(set) var members: [String] = []
    /// Who holds each layer of the piece (nil: free); and followers waiting for a layer.
    private var slots: [String?] = []
    private var waiting: [String] = []
    private var compositionID: String?
    /// The engine is ours (started by the band, not yet stopped).
    private(set) var running = false
    private var level: Float = 0
    /// The hallway's own music level now (1: as ever; down to `ambienceDuck` while the band plays).
    private(set) var ambience: Float = 1
    private var timer: Timer?
    private var lastLineup = ""
    private var startedAt: CFTimeInterval = 0
    /// Oct 25 (floor music): the next floor's piece, waiting for this one to fade out.
    private var pendingComposition: LabComposition?
    private var seenFloor: Int?
    private var seenFloorAt: CFTimeInterval = 0
    /// A floor counts this long after the player has arrived on it (seconds).
    static let floorSettle: CFTimeInterval = 1.0

    /// The piece for a floor (FloorMusic), if its template is in the app.
    static func composition(for floor: Int?) -> LabComposition? {
        guard let floor, let id = FloorMusic.composition(for: floor) else { return nil }
        return MusicLabCatalog.all.first { $0.id == id && BandAssets.url($0.file, "json") != nil }
    }

    /// The band is playing (or fading) in the hallways.
    var isActive: Bool { running }
    /// This follower is playing in the band (its own walking music stays quiet).
    func isPlaying(_ id: String) -> Bool { running && members.contains(id) }

    /// From the building's tick (ResidentMusicConductor.tick): started once.
    func ensureRunning() {
        guard timer == nil, Self.isEnabled, !AudioDiagnostics.audioOff else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { WalkingBand.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        diag("walkingBand.ready", [:])
    }

    /// The Directory opened: the Lab takes the engine -- the band stops at once.
    func yieldToLab() {
        guard running else { return }
        MusicLab.shared.walkingBandStop()
        reset(why: "the Music Lab opened")
    }

    // MARK: Ten times a second

    private func tick() {
        let lab = MusicLab.shared
        let t = Self.tuning
        // who is following the player, with an instrument (not a voice)
        // Oct 25 (PP 7): on a floor with its own soundtrack (FloorSoundtrack) the followers play there instead
        let musical = FloorSoundtrack.shared.ownsFloor ? [] : FollowMe.ids.filter { id in
            guard let inst = BandInstruments.byResident[id] else { return false }
            return BandInstruments.voices[inst] == nil
        }
        if lab.isBusy {
            glideAmbience(to: 1)
            return
        }
        // a running band whose engine stopped under it (an interruption, a route change): from the top
        if running, CACurrentMediaTime() - startedAt > 3, !lab.walkingBandEngineRunning, !musical.isEmpty {
            diag("walkingBand.restart", ["why": "its engine stopped"])
            reset(why: "engine stopped")
        }
        // membership: lowest free layer for a newcomer; one leaving frees only its own
        if !musical.isEmpty || !running {
            seat(musical)
        }
        // Oct 25 (floor music): the piece is the FLOOR's (FloorMusic.swift), not the Lab's choice. A new floor
        // counts once the player has arrived on it (BuildingLife.currentFloor: set when the floor is built --
        // never by the car's indicator passing floors) and stayed a moment (`floorSettle`).
        let floorNow = BuildingLife.shared.currentFloor
        if floorNow != seenFloor { seenFloor = floorNow; seenFloorAt = CACurrentMediaTime() }
        if running, pendingComposition == nil, CACurrentMediaTime() - seenFloorAt >= Self.floorSettle,
           let wanted = Self.composition(for: floorNow), wanted.id != compositionID {
            pendingComposition = wanted                                   // (fade this one out; then the floor's from its top)
            diag("walkingBand.floorChange", ["floor": floorNow, "from": compositionID, "to": wanted.id])
        }
        if running, !musical.isEmpty, let next = pendingComposition, level <= 0.001 {
            // faded out: the new floor's piece, from its beginning, the same followers on the same layers where it has them
            compositionID = next.id
            pendingComposition = nil
            reseat(layers: MusicLabCatalog.layers(next).count, musical)
            lab.walkingBandStart(composition: next.id, lineup: lineup())
            lastLineup = lineupKey()
            startedAt = CACurrentMediaTime()
            diag("walkingBand.start", ["composition": next.id, "floor": floorNow, "seats": lineupKey(), "why": "a new floor"])
        }
        if !running, !musical.isEmpty, let c = Self.composition(for: floorNow) ?? lab.lastComposition {
            compositionID = c.id
            pendingComposition = nil
            slots = Array(repeating: nil, count: MusicLabCatalog.layers(c).count)
            waiting = []
            members = []
            seat(musical)
            level = 0
            lab.walkingBandLevel(0)
            lab.walkingBandStart(composition: c.id, lineup: lineup())
            lastLineup = lineupKey()
            running = true
            startedAt = CACurrentMediaTime()
            diag("walkingBand.start", ["composition": c.id, "floor": floorNow, "followers": musical.joined(separator: ",")])
        } else if running, pendingComposition == nil, !musical.isEmpty, lineupKey() != lastLineup {
            lab.walkingBandLineup(lineup())
            lastLineup = lineupKey()
            diag("walkingBand.lineup", ["seats": lineupKey()])
        }
        // the band's level: in, quiet, or fading away (the last follower gone: the band as it was, fading)
        let quiet = HallwaysAudio.shared.isMuted || HallwaysAudio.shared.isSuppressed || ResidentMusicConductor.storyQuiet
        let goal: Float = (running && !musical.isEmpty && !quiet && pendingComposition == nil) ? t.level : 0
        let rate = Float(Self.interval / (goal > level ? t.fadeIn : t.fadeOut)) * t.level
        level = goal > level ? min(goal, level + rate) : max(goal, level - rate)
        if running { lab.walkingBandLevel(level) }
        if running, musical.isEmpty, level <= 0.001 {
            lab.walkingBandStop()
            reset(why: "the last musical follower left")
        }
        glideAmbience(to: running && !musical.isEmpty ? t.ambienceDuck : 1)
    }

    /// A new piece with `layers` layers: each follower keeps its layer where the piece has it; the rest wait
    /// (in their order), then fill the free layers lowest first.
    private func reseat(layers: Int, _ musical: [String]) {
        var next = [String?](repeating: nil, count: layers)
        var over: [String] = []
        for (i, who) in slots.enumerated() {
            guard let who, musical.contains(who) else { continue }
            if i < layers { next[i] = who } else { over.append(who) }
        }
        var queue = over + waiting.filter { musical.contains($0) }
        for id in musical where !next.contains(id) && !queue.contains(id) { queue.append(id) }
        for i in next.indices where next[i] == nil && !queue.isEmpty { next[i] = queue.removeFirst() }
        slots = next
        waiting = queue
        members = musical
    }

    private func seat(_ musical: [String]) {
        guard !slots.isEmpty else { members = musical; return }
        // gone: free its layer (the first waiting takes it); nobody else moves
        for (i, who) in slots.enumerated() where who != nil && !musical.contains(who!) {
            slots[i] = waiting.isEmpty ? nil : waiting.removeFirst()
        }
        waiting.removeAll { !musical.contains($0) }
        // new: the lowest free layer, else wait
        for id in musical where !slots.contains(id) && !waiting.contains(id) {
            if let i = slots.firstIndex(where: { $0 == nil }) { slots[i] = id } else { waiting.append(id) }
        }
        members = musical
    }

    private func lineup() -> [LabSeat] {
        var out: [LabSeat] = []
        for (i, who) in slots.enumerated() {
            if let who, let inst = BandInstruments.byResident[who] { out.append(LabSeat(who: who, instrument: inst, layer: i)) }
        }
        for who in waiting {
            if let inst = BandInstruments.byResident[who] { out.append(LabSeat(who: who, instrument: inst, layer: nil)) }
        }
        return out
    }

    private func lineupKey() -> String {
        slots.enumerated().map { "\($0.offset + 1):\($0.element ?? "-")" }.joined(separator: " ") + (waiting.isEmpty ? "" : " waiting:" + waiting.joined(separator: ","))
    }

    private func reset(why: String) {
        diag("walkingBand.stop", ["why": why])
        running = false
        pendingComposition = nil
        members = []
        slots = []
        waiting = []
        level = 0
        lastLineup = ""
    }

    private func glideAmbience(to goal: Float) {
        let step = Float(Self.interval / Self.tuning.duckTime) * (1 - Self.tuning.ambienceDuck)
        ambience = goal > ambience ? min(goal, ambience + step) : max(goal, ambience - step)
    }
}
