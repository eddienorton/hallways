//
//  ResidentMusic.swift
//  Hallways
//
//  Oct 22 (later) -- A BUILDING FULL OF MUSICAL PERSONALITIES.
//
//  Every active resident has a short instrumental signature (HallwaysianMusic).
//  This is the ONE place that decides when they are heard, so the building
//  sounds inhabited, not noisy:
//
//  WHEN A NEARBY RESIDENT IS HEARD (the ambient acknowledgment) -- checked on
//  BuildingLife's own 1 Hz tick (no timer of its own, no scene walk):
//    * the musical identities are on, the player isn't muted, and no story is
//      under way (an escort, a guided route, the meeting, the office desk,
//      THE BOX, an eviction; nor before admission);
//    * the building has been musically quiet for a while: after ANY signature
//      (an ambient one, a follow greeting or check-in, a Hallwaysian's hello)
//      nothing more for its own length plus 9-18 s (varied every time);
//    * then, each second, only a 30% chance of anything at all (so it never
//      ticks like a clock);
//    * candidates: residents on the player's floor, in view of the building
//      (rendered, not guiding), within 8 m, joined to the player by a short
//      walk (CritterAudio.isOpen: never just near through a wall, never one in
//      the cab while the player is out of it), not already making a sound,
//      and rested -- 75-150 s since it last played (varied each time);
//    * the one chosen is the nearest, doubled if the player is walking toward
//      it, with a little chance mixed in. One at a time, always.
//    * arriving on a floor: a few seconds' hush first (the elevator's own cues).
//
//  FOLLOWING (a continuing companion): the tap's greeting is its signature (the
//  body's come-hither plays it). Then, while the follow lasts, a check-in every
//  30-45 s (varied) -- only if the building's musical hush has passed, it's on
//  this floor in the open within 14 m and isn't making another sound; if not,
//  it simply waits and tries again 4-9 s later (never forced). Following ends:
//  the check-ins end.
//
//  Off (Settings > Musical greetings): none of this; every original voice.
//

import Foundation
import QuartzCore
import SceneKit
import simd

@MainActor
final class ResidentMusicConductor {
    static let shared = ResidentMusicConductor()

    // MARK: Tunables (seconds, metres)

    /// After any signature: musical quiet for its own length plus this.
    static let hush: ClosedRange<Double> = 9...18
    /// A resident heard ambiently rests this long before it may be again.
    static let rest: ClosedRange<Double> = 75...150
    /// Each second, once the hush is over: the chance anything plays at all.
    static let chance: Double = 0.3
    /// Ambient: residents this near (and in the open) only.
    static let hearing: Float = 8
    /// Following: check-ins this often...
    static let checkIn: ClosedRange<Double> = 30...45
    /// ...and when one can't play just then, it tries again this much later.
    static let retry: ClosedRange<Double> = 4...9
    /// Following: the followed one is heard this far away (in the open).
    static let followHearing: Float = 14
    /// A new floor: this hush first (the car's chime, the doors).
    static let arrivalHush: ClosedRange<Double> = 4...8

    // MARK: State

    private var hushUntil: CFTimeInterval = 0
    private var restUntil: [String: CFTimeInterval] = [:]
    /// Oct 22 (morning): when each one's music last began (its greeting, goodbye, check-in...).
    private var startedAt: [String: CFTimeInterval] = [:]
    private var lastDistance: [String: Float] = [:]
    private var followed: String?
    private var nextCheckIn: CFTimeInterval = 0
    private var floor: Int?

    // MARK: Asked by others

    /// A story, a guided route, the player's own silence: no resident music now.
    static var storyQuiet: Bool {
        GuidedJourney.trip != nil || CharacterLead.activeGuidedRoute != nil || ConferenceMeeting.isActive
            || OfficeComputer.shared.isActive || BonzoEviction.isActive || BoxReveal.isRunning || Admission.isPending
            || HallwaysAudio.shared.isMuted || HallwaysAudio.shared.isSuppressed
            || MusicLab.isActive                                  // Oct 24: the Music Lab is playing -- no other music
    }

    /// May a resident's own (unscheduled) musical hello play now? (A Hallwaysian
    /// greeting the player who comes close: one at a time, like everything else.)
    /// Oct 22 (morning): and not one that has just played (a goodbye, a check-in).
    func mayGreet(_ id: String? = nil, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        !Self.storyQuiet && now >= hushUntil && id.map { now >= (restUntil[$0] ?? 0) } ?? true
    }

    /// Oct 22 (morning): its music (greeting or goodbye) is still sounding -- nothing
    /// more of its own on top of it (a quick follow / stop / follow never stacks).
    func isSounding(_ id: String, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard let t = startedAt[id] else { return false }
        return now - t < HallwaysianMusic.duration(id)
    }

    /// A signature just began (from anywhere): the building's hush, its own rest,
    /// and -- if it's the one being followed -- the next check-in counts from now.
    func played(_ id: String, now: CFTimeInterval = CACurrentMediaTime()) {
        let length = HallwaysianMusic.duration(id)
        startedAt[id] = now
        hushUntil = max(hushUntil, now + length + Double.random(in: Self.hush))
        restUntil[id] = now + Double.random(in: Self.rest)
        if id == followed { nextCheckIn = now + Double.random(in: Self.checkIn) }
    }

    // MARK: The 1 Hz tick (BuildingLife.tick)

    func tick(life: BuildingLife) {
        guard !AudioDiagnostics.audioOff else { return }                 // Oct 24: audio-off (diagnostic) -- none of the residents' music
        ResidentWalkingMusic.shared.ensureRunning()                     // Oct 23: walking music (its own 4 Hz; it minds the switch itself)
        LivingOrchestra.shared.ensureRunning()                          // Oct 24: the living orchestra (prototype; its own engine and 10 Hz)
        WalkingBand.shared.ensureRunning()                              // Oct 25: the walking band (experiment; off: -HallwaysWalkingBand NO)
        guard HallwaysianMusic.isOn else { followed = nil; return }
        let perf = PerfMonitor.begin("music.tick"); defer { PerfMonitor.end(perf) }
        let now = CACurrentMediaTime()
        // Following: a new one counts its first check-in from now (its tap greeting is noted by itself).
        let target = CritterFollow.targetID
        if target != followed {
            followed = target
            nextCheckIn = now + Double.random(in: Self.checkIn)
        }
        if life.currentFloor != floor {
            floor = life.currentFloor
            hushUntil = max(hushUntil, now + Double.random(in: Self.arrivalHush))
            lastDistance = [:]
        }
        guard let player = life.playerPosition() else { return }
        // Who is near, and who is coming nearer (kept every tick: the approach needs a history).
        var near: [(p: ResidentPresentation, d: Float, approaching: Bool)] = []
        var seen: [String: Float] = [:]
        for p in life.presentations where p.isRendered {
            guard let at = p.bodyPosition else { continue }
            let d = simd_distance(at, player)
            seen[p.residentID] = d
            let approaching = (lastDistance[p.residentID].map { $0 - d } ?? 0) > 0.5
            near.append((p, d, approaching))
        }
        lastDistance = seen
        guard !Self.storyQuiet, now >= hushUntil else { return }
        // 1. The followed one's check-in.
        if let id = target, now >= nextCheckIn {
            if let n = near.first(where: { $0.p.residentID == id }),          // (guiding the player to a task, too)
               let body = n.p.bodyNode, n.d <= Self.followHearing, quiet(body),
               CritterAudio.isOpen(to: body, within: Self.followHearing), perform(id, on: body, why: "follow check-in", now: now) {
                return
            }
            nextCheckIn = now + Double.random(in: Self.retry)                    // (not now: a little later, never forced)
            return
        }
        // 2. Now and then, a nearby resident.
        guard Double.random(in: 0..<1) < Self.chance else { return }
        let ranked = near.compactMap { n -> (id: String, body: SCNNode, score: Double)? in
            let id = n.p.residentID
            guard id != target, !n.p.isGuiding, n.d <= Self.hearing, now >= (restUntil[id] ?? 0),
                  HallwaysianMusic.signature(id) != nil, HallwaysianMusic.isReady(id), let body = n.p.bodyNode else { return nil }
            return (id, body, Self.score(distance: n.d, approaching: n.approaching, jitter: Double.random(in: 0.75...1.25)))
        }.sorted { $0.score > $1.score }
        for c in ranked.prefix(3) where quiet(c.body) && CritterAudio.isOpen(to: c.body, within: Self.hearing) {
            if perform(c.id, on: c.body, why: "nearby", now: now) { return }
        }
    }

    /// Nearer is likelier; coming toward it, twice as likely (pure; tests).
    static func score(distance: Float, approaching: Bool, jitter: Double = 1) -> Double {
        let closeness = max(0.05, 1 - Double(distance) / Double(hearing))
        return closeness * (approaching ? 2 : 1) * jitter
    }

    /// It isn't sounding already (a footstep, a word, a door).
    private func quiet(_ body: SCNNode) -> Bool { body.audioPlayers.isEmpty }

    private func perform(_ id: String, on body: SCNNode, why: String, now: CFTimeInterval) -> Bool {
        guard let source = HallwaysianMusic.source(id) else { return false }
        CritterAudio.play(source, on: body)
        played(id, now: now)
        LifeLog.event(id, "music.played", ["why": why])
        StickyProbe.note("music \(id) (\(why))")                   // Oct 22 (evening): measurement only
        return true
    }
}

/// The residents' bodies ask here when their own sound would play.
@MainActor
enum ResidentMusic {
    /// Oct 22 (stability pass): with the musical identities on, residents don't
    /// speak Hallenese in ordinary life (idle words, come-along calls, the
    /// Pottle's murmurs) -- their signatures are their voices. (Story scenes,
    /// the meeting, Tinky and Juanita keep theirs; the Directory's Original
    /// buttons still play them.) Thread-safe (a defaults read).
    nonisolated static var hushesVoices: Bool { HallwaysianMusic.isOn }

    /// The follow come-hither: its signature instead of its own sound (true).
    /// With the identities on this ALWAYS answers true -- never Hallenese --
    /// even when its file isn't ready yet (then silent; the file is on its way).
    /// Oct 22 (stability pass): a greeting while its goodbye (or an earlier
    /// greeting) is still sounding cuts that one off and plays at once -- every
    /// deliberate tap is heard, and two of its own never stack.
    /// Off: false, and the body plays its original sound as before.
    static func greet(_ id: String, on node: SCNNode) -> Bool {
        guard HallwaysianMusic.isOn else { return false }
        guard !MusicLab.isActive else { return false }                   // Oct 24: the lab is playing -- its ordinary sound instead
        guard node.parent != nil, let source = HallwaysianMusic.source(id) else {
            LifeLog.event(id, "music.skipped", ["why": node.parent == nil ? "no body in the scene" : "its file isn't ready yet"])
            return true
        }
        let cut = stopMusic(on: node)
        CritterAudio.play(source, on: node)
        ResidentMusicConductor.shared.played(id)
        LifeLog.event(id, "music.played", ["why": "greeting", "cutOff": cut])
        StickyProbe.note("music \(id) (greeting)")
        return true
    }

    /// Oct 22 (morning): the player stopped following it on purpose -- its
    /// signature an octave lower, a musical goodbye, from where it is (the same
    /// spatial path, distance fade, walls and Mute). Oct 22 (stability pass):
    /// its greeting still sounding is cut off first (was: the goodbye was
    /// skipped -- the "silent taps"). Identities off: stopping stays silent.
    /// File not ready: silent (asked for in the background, never rendered here).
    static func farewell(_ id: String) {
        guard HallwaysianMusic.isOn else { return }
        guard !MusicLab.isActive else { return }                         // Oct 24: the lab is playing
        guard let node = BuildingLife.shared.presentations.first(where: { $0.residentID == id })?.bodyNode,
              let source = HallwaysianMusic.source(id, low: true) else {
            LifeLog.event(id, "music.skipped", ["why": "goodbye: no body here, or its file isn't ready yet"])
            return
        }
        let cut = stopMusic(on: node)
        CritterAudio.play(source, on: node)
        ResidentMusicConductor.shared.played(id)
        LifeLog.event(id, "music.played", ["why": "goodbye (an octave down)", "cutOff": cut])
        StickyProbe.note("music \(id) (goodbye)")
    }

    /// Its own signature (greeting or goodbye) still playing on its body: stopped
    /// (main thread, like every player removal). Returns how many.
    @discardableResult
    static func stopMusic(on node: SCNNode) -> Int {
        var n = 0
        for player in node.audioPlayers {
            guard let source = player.audioSource else { continue }
            let name = SoundCatalog.name(of: source)
            guard name.hasPrefix("hw-music-") || name.hasPrefix("music-v1-") else { continue }
            node.removeAudioPlayer(player)
            n += 1
        }
        return n
    }
}
