//
//  ResidentWalkingMusic.swift
//  Hallways
//
//  Oct 23 -- EVERY CRITTER WALKS TO ITS OWN TUNE.
//
//  Oct 23 (afternoon) -- CONTINUOUS BUT QUIET. (The "occasional flourish" pass
//  lost the sense of a building alive around you; this keeps it, softly.) While a
//  critter walks, its own signature (HallwaysianMusic -- the very file its
//  greetings play) plays phrase after phrase, at 15% of its music's loudness for
//  the NEAREST walker in earshot; the next two nearer ones less (55%, 35% of
//  that), a fourth only as a whisper (8%), anyone further back not at all. Twice a
//  second (not per frame) the walkers in earshot are ranked by nearness -- the one
//  already heard keeps its place against a close newcomer -- and each one's
//  presence GLIDES toward its rank's (40% of the way each time), while each
//  phrase's loudness follows its distance fade and presence smoothly: approaching,
//  receding, overtaking, dropping out -- no pumping, no cuts. One stopping, or held
//  by its menu: its phrase fades out in 0.4 s.
//  One mechanism for everyone -- no critter is named here:
//
//    WHO     every character in CharacterRegistry.all (the Directory's own list:
//            the roaming residents, the Hallwaysians, the meeting's cast, the
//            Chair, the Butterfly, the Pottle, Tinky, Juanita -- and anyone added
//            there later) that has a signature. One without a signature is
//            never given another sound (it's said once in the diagnostics).
//
//    WALKING its body's own position, four times a second: moving across the
//            floor (>= 0.2 m/s) for half a second -> walking; still for 0.75 s ->
//            not. (Corners, door pushes, a walk re-planned mid-way: no gap that
//            long -- and a phrase is never begun by a route update anyway.
//            Turning on the spot, gestures, a body set down somewhere new: not walking.)
//            Whatever moves it -- its own wandering, being followed (FOLLOW),
//            following the player (FOLLOW ME), a story's walk -- the same rule.
//
//    HEARD   through CritterAudio exactly like its music (positional, the distance
//            fade, walls, the cab rule, Mute) at 15% x its presence on its own
//            player's mixer (`walkingShare`) -- relative to that critter's own
//            music, whatever that is. A phrase begins only within 8 m in the open
//            (CritterAudio.isOpen, the same test its other music uses).
//
//    QUIET   identities off (Settings > Musical greetings); Mute; any story under
//            way (ResidentMusicConductor.storyQuiet -- the escort, the meeting,
//            THE BOX...); and while its own greeting, goodbye, check-in or LISTEN
//            is sounding (those cut a walking phrase off, and it waits for them).
//            Walking phrases never count as the building's "music played" -- they
//            don't hush or delay anyone's greeting.
//
//  With the identities on, the walking sounds a few residents had of their own
//  (the Chair's wooden shuffles, the Pottle's tocks) are quiet: this is their
//  walking sound now. Identities off: those come back, and this is silent.
//
//  Cost: four times a second, one position read per registered character in the
//  scene (its body's ground position, or its node's model position -- never a
//  presentation read); twice a second, while anyone walks, one player-position
//  read and a little arithmetic per walker; the open-air test once per phrase.
//

import AVFAudio
import Foundation
import QuartzCore
import SceneKit
import simd

@MainActor
final class ResidentWalkingMusic {
    static let shared = ResidentWalkingMusic()

    // MARK: Tunables

    /// Of the critter's own music loudness (before distance and walls), for the
    /// NEAREST walker. Oct 23 (later): 0.5 -> 0.25 (occasional) -> 0.15 (continuous again).
    static let walkingShare: Float = 0.15
    static let interval: TimeInterval = 0.25
    /// Moving at least this fast (m/s, across the floor) counts as a step.
    static let movingSpeed: Float = 0.2
    /// One sample further than this (metres) is a body set down, not a step.
    static let jump: Float = 1.5
    static let startAfter: CFTimeInterval = 0.5
    static let stopAfter: CFTimeInterval = 0.75
    /// Heard within this (metres, in the open).
    static let hearing: Float = 8
    /// Oct 23 (later): presence by nearness among the walkers in earshot -- the
    /// nearest, the 2nd, the 3rd; the 4th only as a whisper. No more than that play.
    static let presence: [Float] = [1, 0.55, 0.35, 0.08]
    /// The walker already heard keeps its place against a newcomer this much nearer (metres).
    static let keepPlace: Float = 1
    /// Loudness follows distance and rank smoothly: this share of the way, twice a second.
    static let glide: Float = 0.4
    /// How often presence and loudness are re-worked (seconds) -- not every frame.
    static let mixEvery: CFTimeInterval = 0.5
    /// Continuous: a breath between one phrase and the next (seconds).
    static let breath: ClosedRange<Double> = 0.3...0.8
    /// A newcomer's first phrase begins within this (so a group isn't in unison).
    static let firstAfter: ClosedRange<Double> = 0...1.2
    static let fadeOut: Double = 0.4

    // MARK: State

    private struct Walker {
        var last: SIMD2<Float>
        var movingSince: CFTimeInterval?
        var stillSince: CFTimeInterval?
        var walking = false
    }
    private struct Phrase {
        weak var node: SCNNode?
        weak var player: SCNAudioPlayer?
        let endsAt: CFTimeInterval
        /// Its loudness as CritterAudio began it (distance, walls, Mute, its presence then)...
        let startVolume: Float
        /// ...the distance fade and presence that went into that.
        let startFade: Float
        let startPresence: Float
        /// Oct 25: the hallway's music level (WalkingBand.ambience) when it began.
        let startAmbience: Float
    }
    private var walkers: [String: Walker] = [:]
    /// Phrases sounding now (one per critter at most).
    private var sounding: [String: Phrase] = [:]
    /// When each critter's next phrase may begin.
    private var nextPhrase: [String: CFTimeInterval] = [:]
    /// Its presence now (gliding toward its rank's), and where it was last heard from.
    private var presence: [String: Float] = [:]
    private var target: [String: Float] = [:]
    private var distance: [String: Float] = [:]
    private var lastMix: CFTimeInterval = 0
    private var reportedNoSignature: Set<String> = []
    private var timer: Timer?

    /// Started by the building's tick (ResidentMusicConductor.tick); runs on its own, 4 Hz.
    func ensureRunning() {
        guard timer == nil, !AudioDiagnostics.audioOff else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { ResidentWalkingMusic.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Is this critter walking now (for diagnostics and tests)?
    func isWalking(_ id: String) -> Bool { walkers[id]?.walking ?? false }

    // MARK: The tick

    private func tick() {
        let perf = PerfMonitor.begin("music.walking"); defer { PerfMonitor.end(perf) }
        let now = CACurrentMediaTime()
        // 1. Who is walking: every registered character's body in the scene.
        var bodies: [String: SCNNode] = [:]
        var presented: [String: ResidentPresentation] = [:]
        for p in BuildingLife.shared.presentations { presented[p.residentID] = p }
        for c in CharacterRegistry.all {
            guard let node = c.body(), node.parent != nil else {
                walkers[c.id] = nil
                continue
            }
            bodies[c.id] = node
            // Where it stands: its resident body's own ground position when it is one (some
            // bodies walk a part of themselves, not their root), else its node's.
            let p: SIMD2<Float>
            if let at = presented[c.id]?.bodyPosition {
                p = at
            } else {
                let w = node.worldPosition
                p = SIMD2<Float>(w.x, w.z)
            }
            var k = walkers[c.id] ?? Walker(last: p)
            let step = simd_distance(p, k.last)
            k.last = p
            let moving = step < Self.jump && step / Float(Self.interval) >= Self.movingSpeed
            if moving {
                k.stillSince = nil
                if k.movingSince == nil { k.movingSince = now }
            } else {
                k.movingSince = nil
                if k.stillSince == nil { k.stillSince = now }
            }
            if !k.walking, let s = k.movingSince, now - s >= Self.startAfter {
                k.walking = true
                if HallwaysianMusic.signature(c.id) == nil, !reportedNoSignature.contains(c.id) {
                    reportedNoSignature.insert(c.id)
                    diag("music.walking.noSignature", ["who": c.id, "note": "walks with no musical identity: no walking sound"])
                }
            }
            if k.walking, let s = k.stillSince, now - s >= Self.stopAfter { k.walking = false }
            if presented[c.id]?.isHeld == true { k.walking = false; k.movingSince = nil }   // Oct 23 (menu pause): at once
            walkers[c.id] = k
        }
        // 2. Allowed at all? (Off, Mute, a story: anything sounding fades.)
        // Oct 24: and never while the living orchestra plays (LivingOrchestra) -- the two don't compete.
        let allowed = HallwaysianMusic.isOn && !ResidentMusicConductor.storyQuiet && !LivingOrchestra.shared.isActive
        guard allowed else {
            for id in Array(sounding.keys) { fade(id, why: "quiet (identities off, Mute, or a story)") }
            presence = [:]
            target = [:]
            return
        }
        // 3. Twice a second: who is in earshot, ranked by nearness (the one already
        //    heard keeps its place against a close tie), each one's presence gliding
        //    toward its rank's, and each phrase's loudness following -- no jumps.
        if now - lastMix >= Self.mixEvery {
            lastMix = now
            mix()
        }
        // 4. Each walker with presence: phrase after phrase while it walks.
        for id in Array(sounding.keys) where walkers[id]?.walking != true || WalkingBand.shared.isPlaying(id) {
            fade(id, why: WalkingBand.shared.isPlaying(id) ? "playing in the walking band" : "stopped walking")
        }
        for (id, t) in target where t > 0 {
            guard walkers[id]?.walking == true, let node = bodies[id] else { continue }
            if WalkingBand.shared.isPlaying(id) { continue }               // Oct 25: its instrument is in the walking band instead
            if let phrase = sounding[id] {
                guard now >= phrase.endsAt else { continue }                      // (still sounding)
                sounding[id] = nil
                nextPhrase[id] = now + Double.random(in: Self.breath)
                continue
            }
            guard let due = nextPhrase[id] else {
                nextPhrase[id] = now + Double.random(in: Self.firstAfter)
                continue
            }
            guard now >= due else { continue }
            // Its own music (a greeting, goodbye, check-in, LISTEN) is sounding: it waits.
            if ResidentMusicConductor.shared.isSounding(id, now: now) {
                nextPhrase[id] = now + 0.5
                continue
            }
            guard CritterAudio.isOpen(to: node, within: Self.hearing), let source = HallwaysianMusic.source(id) else {
                nextPhrase[id] = now + 1                                            // (through a wall, or its file not ready yet)
                continue
            }
            let p = max(0.02, presence[id] ?? 0)
            let fadeNow = CritterAudio.fadeGain(distance[id] ?? 0)
            let ambience = WalkingBand.shared.ambience                       // Oct 25: ducked while the walking band plays
            let player = CritterAudio.start(source, on: node, scale: Self.walkingShare * p * ambience)
            nextPhrase[id] = now + HallwaysianMusic.duration(id)
            guard let player else { continue }
            let v = (player.audioNode as? AVAudioMixing)?.volume ?? 0
            sounding[id] = Phrase(node: node, player: player, endsAt: now + HallwaysianMusic.duration(id),
                                  startVolume: v, startFade: max(0.05, fadeNow), startPresence: p, startAmbience: max(0.05, ambience))
        }
        // Gone from earshot (or no longer walking) and faded to nothing: forgotten.
        for (id, p) in presence where p < 0.01 && (target[id] ?? 0) == 0 {
            presence[id] = nil
            nextPhrase[id] = nil
            fade(id, why: "out of earshot")
        }
    }

    /// Presence and loudness, twice a second (one player position read; no scene work).
    private func mix() {
        var ranked: [(id: String, d: Float)] = []
        let anyone = !sounding.isEmpty || !presence.isEmpty || walkers.contains { $0.value.walking }
        if anyone, let ear = BuildingLife.shared.playerPosition() {
            for (id, k) in walkers where k.walking && HallwaysianMusic.signature(id) != nil {
                let d = simd_distance(k.last, ear)
                distance[id] = d
                guard d <= Self.hearing else { continue }
                ranked.append((id, d - (sounding[id] != nil ? Self.keepPlace : 0)))
            }
        }
        ranked.sort { $0.d < $1.d }
        target = [:]
        for (i, r) in ranked.prefix(Self.presence.count).enumerated() { target[r.id] = Self.presence[i] }
        // Glide each presence toward its target (a newcomer rises from nothing).
        for id in Set(presence.keys).union(target.keys) {
            let current = presence[id] ?? 0, goal = target[id] ?? 0
            presence[id] = current + (goal - current) * Self.glide
        }
        // Each phrase sounding: its loudness from how it began, scaled by how its
        // distance fade and its presence have changed since.
        for (id, phrase) in sounding {
            guard let player = phrase.player, let mixer = player.audioNode as? AVAudioMixing else { continue }
            let fadeNow = CritterAudio.fadeGain(distance[id] ?? .greatestFiniteMagnitude)
            let ratio = (fadeNow / phrase.startFade) * ((presence[id] ?? 0) / phrase.startPresence)
                * (WalkingBand.shared.ambience / phrase.startAmbience)             // Oct 25: the walking band's duck, glided
            mixer.volume = min(phrase.startVolume * ratio, Self.walkingShare)       // (never above the nearest's share)
        }
    }

    /// Its walking phrase ends: faded out (never cut), whatever the reason.
    private func fade(_ id: String, why: String) {
        guard let phrase = sounding.removeValue(forKey: id) else { return }
        if why != "phrase over" { LifeLog.event(id, "music.walking.ended", ["why": why]) }
        guard let node = phrase.node, let player = phrase.player,
              node.audioPlayers.contains(where: { $0 === player }) else { return }
        let from = (player.audioNode as? AVAudioMixing)?.volume ?? 0
        let steps = 8
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOut * Double(i) / Double(steps)) { [weak node, weak player] in
                guard let node, let player, node.audioPlayers.contains(where: { $0 === player }) else { return }
                if i == steps {
                    node.removeAudioPlayer(player)                               // (main thread, like every removal)
                } else {
                    (player.audioNode as? AVAudioMixing)?.volume = from * (1 - Float(i) / Float(steps))
                }
            }
        }
    }
}
