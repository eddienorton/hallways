//
//  LivingOrchestra.swift
//  Hallways
//
//  Oct 24 -- THE LIVING ORCHESTRA (prototype 1).
//
//  One continuous orchestral loop -- "The Living Office" arranged for the game
//  (Music/LivingOrchestra-loop/arrange_loop.py) -- in which every critter on
//  the player's floor plays a part, louder the nearer it is. Walking has
//  nothing to do with it: standing, sitting, waiting at the doors, following,
//  being followed or held by its menu, a critter on this floor plays.
//
//  THE MUSIC: five stems of exactly the same length (Hallways/LivingOrchestra/
//  orchestra-*.caf, bundled by the synced folder; Apple Lossless, 44.1 kHz,
//  42 bars at 116 bpm, ~86.9 s),
//  each already wrapped round its own loop point (rendered twice, the second
//  pass kept), started together at one host time and kept going by queueing
//  each stem's next pass back to back -- so they share one clock for as long as
//  the engine runs, and loop without a gap or a click.
//
//    foundation  always, at a constant level: double bass, pizzicato, light
//                percussion and a soft core melody that carries every passage
//                (so the tune is whole with nobody near).
//    clarinet / bassoon / flute   one critter each (`assignments`).
//    ensemble    French horn: shared by every other critter on the floor.
//
//  THE MIX: four times a second, every character in CharacterRegistry.all
//  whose body is in the scene (this floor's) is a member; its part's target
//  gain comes from its distance to the player (`Tuning`: full within
//  `nearRadius`, easing to `minGain` at `farRadius` and beyond -- still faintly
//  there anywhere on the floor). A part with several members takes the
//  loudest of them, plus a little for each extra one (`crowdBonus`), never
//  more than `maxGain`: a crowd is richer, never louder than one critter beside
//  you. Ten times a second each part's gain glides toward its target
//  (`response`): no steps, no clicks. Nothing is ever restarted by anyone's
//  movement; a part with nobody here simply glides to silence. In the cab, only
//  the foundation (the floor is left behind); the next floor's members come in
//  as it's built.
//
//  QUIET: Mute and Settings (HallwaysAudio) and any story under way
//  (ResidentMusicConductor.storyQuiet: onboarding, an escort, the meeting,
//  THE BOX...) bring the whole orchestra down smoothly; it comes back the same
//  way. While it's on, the walking music (ResidentWalkingMusic) is silent.
//  Greetings, goodbyes, check-ins and LISTEN still play their signatures as
//  before (over the orchestra, in their own time -- not yet reconciled).
//
//  ITS OWN ENGINE: an AVAudioEngine of its own (not SceneKit's) -- nothing in
//  the 3D view's audio is touched. Started once; files streamed from disk (no
//  whole-file buffers in memory); after an interruption, an engine
//  configuration change or a return to the foreground it's started again,
//  from the top of the loop.
//
//  Off (everything as before, the walking music back): `-HallwaysLivingOrchestra NO`.
//

import AVFAudio
import Foundation
import QuartzCore
import SceneKit
import UIKit
import simd

// MARK: - What plays, and who plays it

nonisolated enum OrchestraPart: String, CaseIterable, Sendable {
    case foundation, clarinet, bassoon, flute, ensemble

    /// Its stem's file name (Hallways/LivingOrchestra/<name>.caf, bundled at the top level).
    var fileName: String { "orchestra-\(rawValue)" }
}

enum OrchestraConfig {
    /// On unless switched off (`-HallwaysLivingOrchestra NO`).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "HallwaysLivingOrchestra") == nil || UserDefaults.standard.bool(forKey: "HallwaysLivingOrchestra")
    }

    /// Which critter plays which part -- by resident id (exact), or by an id
    /// prefix ending in "*" ("hw.*": every Hallwaysian). The first match wins.
    static let assignments: [(match: String, part: OrchestraPart)] = [
        ("hw.feddy", .flute),            // Benny: bright, peering -- the flute
        ("cast.mailbox", .clarinet),     // the Mailbox: the clarinet
        ("chair.1", .bassoon),           // the Chair: wooden, a little creaky -- the bassoon
    ]
    /// Everyone else on the floor shares this part.
    static let everyoneElse: OrchestraPart = .ensemble

    static func part(for id: String) -> OrchestraPart {
        for a in assignments {
            if a.match.hasSuffix("*") ? id.hasPrefix(String(a.match.dropLast())) : id == a.match { return a.part }
        }
        return everyoneElse
    }

    struct Tuning {
        /// Full gain within this (metres).
        var nearRadius: Float = 2.5
        /// At and beyond this, `minGain` (metres).
        var farRadius: Float = 16
        /// A member anywhere on the floor is at least this (0...1).
        var minGain: Float = 0.12
        var maxGain: Float = 1
        /// The fall-off's shape between near and far (1: linear; 2: falls faster at first).
        var curve: Float = 1.6
        /// Seconds for a gain to get most (63%) of the way to its target.
        var response: Double = 0.7
        /// A part with several members: + this for each extra one (of the loudest's gain).
        var crowdBonus: Float = 0.12
        /// The foundation's constant level (0...1).
        var foundationLevel: Float = 1
        /// The whole orchestra's level against the rest of the game's sound.
        var masterLevel: Float = 0.5
        /// How long Mute / a story / Settings take to bring it down or back (seconds).
        var masterResponse: Double = 0.5
    }
    static var tuning = Tuning()

    /// Its gain for a member `distance` metres from the player (pure; tests).
    static func gain(distance d: Float, tuning t: Tuning = tuning) -> Float {
        let span = max(0.01, t.farRadius - t.nearRadius)
        let x = min(1, max(0, (d - t.nearRadius) / span))
        let f = pow(1 - x, t.curve)
        return t.minGain + (t.maxGain - t.minGain) * f
    }

    /// A part's gain from its members' gains (pure; tests): the loudest, plus a
    /// little for each other one, never above maxGain; nobody: 0.
    static func partGain(_ members: [Float], tuning t: Tuning = tuning) -> Float {
        guard let top = members.max() else { return 0 }
        return min(t.maxGain, top * (1 + t.crowdBonus * Float(members.count - 1)))
    }
}

// MARK: - The player (one clock for every stem)

/// The engine, the stems' players, and their looping. Its scheduling runs on
/// AVFoundation's own threads (each pass queues the next), so it's not tied to
/// the main actor; gains are only set (thread-safe mixer parameters).
nonisolated final class OrchestraDeck: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var players: [OrchestraPart: AVAudioPlayerNode] = [:]
    private var files: [OrchestraPart: AVAudioFile] = [:]
    private let lock = NSLock()
    private var generation = 0
    private(set) var loopFrames: AVAudioFramePosition = 0
    private var startedAt: CFTimeInterval?

    private var sampleRate: Double = 44100

    /// Opens the stems (all must be there and the same length) and wires them up. Nil: not available.
    init?(foundationLevel: Float) {
        var length: AVAudioFramePosition?
        for part in OrchestraPart.allCases {
            guard let url = Bundle.main.url(forResource: part.fileName, withExtension: "caf")
                    ?? Bundle.main.url(forResource: part.fileName, withExtension: "caf", subdirectory: "LivingOrchestra"),
                  let file = try? AVAudioFile(forReading: url) else {
                diag("orchestra.missing", ["stem": part.fileName])
                return nil
            }
            if let l = length, l != file.length {
                diag("orchestra.lengthMismatch", ["stem": part.fileName, "frames": file.length, "expected": l])
                return nil
            }
            length = file.length
            files[part] = file
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            node.volume = part == .foundation ? foundationLevel : 0
            sampleRate = file.processingFormat.sampleRate
            players[part] = node
        }
        loopFrames = length ?? 0
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
    }

    var isRunning: Bool { engine.isRunning }

    /// Start (or start again) every stem from the top of the loop, together.
    func start() -> Bool {
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()
        for p in players.values { p.stop() }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            diag("orchestra.engineFailed", ["error": "\(error)"])
            return false
        }
        // Two passes queued on every stem; each pass, as it's taken up, queues another.
        for part in OrchestraPart.allCases {
            queue(part, gen: gen)
            queue(part, gen: gen)
        }
        let at = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.25))
        for p in players.values { p.play(at: at) }
        startedAt = CACurrentMediaTime() + 0.25
        diag("orchestra.started", ["loopSeconds": Double(loopFrames) / sampleRate, "stems": players.count])
        return true
    }

    private func queue(_ part: OrchestraPart, gen: Int) {
        guard let node = players[part], let file = files[part] else { return }
        node.scheduleSegment(file, startingFrame: 0, frameCount: AVAudioFrameCount(loopFrames), at: nil,
                             completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation
            self.lock.unlock()
            guard current == gen else { return }                          // (stopped or started afresh: no more)
            self.queue(part, gen: gen)
        }
    }

    func stop() {
        lock.lock()
        generation += 1
        lock.unlock()
        for p in players.values { p.stop() }
        engine.stop()
        startedAt = nil
    }

    func setGain(_ part: OrchestraPart, _ g: Float) { players[part]?.volume = g }
    func gain(_ part: OrchestraPart) -> Float { players[part]?.volume ?? 0 }
    func setMaster(_ v: Float) { engine.mainMixerNode.outputVolume = v }
    var master: Float { engine.mainMixerNode.outputVolume }

    /// Where the music is (bar 1-42, beat), for the diagnostics.
    func position(now: CFTimeInterval = CACurrentMediaTime()) -> (bar: Int, beat: Int)? {
        guard let t0 = startedAt, loopFrames > 0, now >= t0 else { return nil }
        let loop = Double(loopFrames) / sampleRate
        let beats = (now - t0).truncatingRemainder(dividingBy: loop) / (60.0 / 116)
        return (Int(beats / 4) + 1, Int(beats.truncatingRemainder(dividingBy: 4)) + 1)
    }
}

// MARK: - The conductor (main actor: who's here, how near)

@MainActor
final class LivingOrchestra {
    static let shared = LivingOrchestra()

    private var deck: OrchestraDeck?
    private var unavailable = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var targets: [OrchestraPart: Float] = [:]
    private var gains: [OrchestraPart: Float] = [:]
    private var tickCount = 0
    private var lastMembers = ""
    private var lastReport: CFTimeInterval = 0
    private var restartPending = false

    static let interval: TimeInterval = 0.1

    var isActive: Bool { deck != nil && OrchestraConfig.isEnabled }
    /// Oct 24 (mud probe): its engine is running / its overall level now.
    var engineRunning: Bool { deck?.isRunning ?? false }
    var masterLevel: Float { deck?.master ?? 0 }

    // MARK: LISTEN (Oct 24, a temporary diagnostic): one critter's part alone

    /// While set: only this part sounds (at full), the foundation and the rest glide out --
    /// the same timeline throughout (gains only; nothing restarts).
    private var solo: (part: OrchestraPart, until: CFTimeInterval, who: String)?
    static let soloSeconds: Double = 10

    /// LISTEN on critter `id`: its part, alone, for a few seconds. Returns its part and
    /// whether that part is shared (the horn: everyone without a part of their own).
    @discardableResult
    func listen(to id: String, name: String) -> (part: OrchestraPart, shared: Bool)? {
        guard deck != nil else { return nil }
        let part = OrchestraConfig.part(for: id)
        let shared = part == OrchestraConfig.everyoneElse
        solo = (part, CACurrentMediaTime() + Self.soloSeconds, id)
        var at = "?"
        if let p = deck?.position() { at = "bar \(p.bar) beat \(p.beat)" }
        let before = String(format: "%.2f", gains[part] ?? 0)
        diag("orchestra.listen", ["who": id, "name": name, "part": part.rawValue, "shared": shared, "at": at, "gainBefore": before])
        // (and what it actually reached, once the glide has had time)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let deck = self.deck, let s = self.solo, s.who == id else { return }
            var parts: [String] = []
            for p in OrchestraPart.allCases { parts.append(p.rawValue + " " + String(format: "%.2f", deck.gain(p))) }
            let all = parts.joined(separator: ", ")
            let master = String(format: "%.2f", deck.master)
            diag("orchestra.listen.gains", ["who": id, "part": part.rawValue, "gains": all, "master": master])
        }
        return (part, shared)
    }

    /// From the building's tick (ResidentMusicConductor.tick): started once.
    func ensureRunning() {
        guard OrchestraConfig.isEnabled, !AudioDiagnostics.audioOff, deck == nil, !unavailable else { return }   // (Oct 24: + audio-off)
        guard let d = OrchestraDeck(foundationLevel: OrchestraConfig.tuning.foundationLevel) else {
            unavailable = true                                            // (stems missing: said once, the old music stays)
            return
        }
        deck = d
        SoundEffects.configureAudioSession(reason: "orchestra")
        guard d.start() else { return }
        for p in OrchestraPart.allCases where p != .foundation { gains[p] = 0 }
        observe()
        let t = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { LivingOrchestra.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Ten times a second

    private func tick() {
        guard let deck else { return }
        let perf = PerfMonitor.begin("orchestra.tick"); defer { PerfMonitor.end(perf) }
        tickCount += 1
        let t = OrchestraConfig.tuning
        // The whole orchestra: down for Mute, Settings, a story; up again after.
        let quiet = HallwaysAudio.shared.isMuted || HallwaysAudio.shared.isSuppressed || ResidentMusicConductor.storyQuiet
        let masterGoal: Float = quiet ? 0 : t.masterLevel * WalkingBand.shared.ambience   // (Oct 25: ducked under the walking band)
        let mk = Float(1 - exp(-Self.interval / t.masterResponse))
        let m = deck.master + (masterGoal - deck.master) * mk
        deck.setMaster(abs(m - masterGoal) < 0.002 ? masterGoal : m)
        // Who's here, and how near (four times a second... every third tick ~3.3 Hz).
        if tickCount % 3 == 1 { measure() }
        // Each part glides to its target (LISTEN: only its part, at full; the rest out).
        if let s = solo, CACurrentMediaTime() >= s.until {
            solo = nil
            diag("orchestra.listen.ended", ["who": s.who, "part": s.part.rawValue])
        }
        let k = Float(1 - exp(-Self.interval / t.response))
        for part in OrchestraPart.allCases {
            var goal = part == .foundation ? t.foundationLevel : (targets[part] ?? 0)
            if let s = solo { goal = part == s.part ? t.maxGain : 0 }
            var g = gains[part] ?? (part == .foundation ? t.foundationLevel : 0)
            g += (goal - g) * k
            if abs(g - goal) < 0.001 { g = goal }
            gains[part] = g
            deck.setGain(part, g)
        }
        if restartPending {
            restartPending = false
            _ = deck.start()
        }
    }

    /// Every critter whose body is in the scene (this floor), its distance, its part.
    private func measure() {
        var members: [OrchestraPart: [Float]] = [:]
        var who: [String] = []
        let inCab = ElevatorBoard.controller?.playerInCab ?? false
        if !inCab, let ear = BuildingLife.shared.playerPosition() {
            var presented: [String: ResidentPresentation] = [:]
            for p in BuildingLife.shared.presentations { presented[p.residentID] = p }
            for c in CharacterRegistry.all {
                guard let node = c.body(), node.parent != nil else { continue }
                if WalkingBand.shared.isPlaying(c.id) { continue }         // Oct 25: playing in the walking band instead
                let at: SIMD2<Float>
                if let p = presented[c.id]?.bodyPosition {
                    at = p
                } else {
                    let w = node.worldPosition
                    at = SIMD2<Float>(w.x, w.z)
                }
                let d = simd_distance(at, ear)
                let part = OrchestraConfig.part(for: c.id)
                members[part, default: []].append(OrchestraConfig.gain(distance: d))
                who.append("\(c.id)=\(part.rawValue)@\(Int(d.rounded()))m")
            }
        }
        for part in OrchestraPart.allCases where part != .foundation {
            targets[part] = OrchestraConfig.partGain(members[part] ?? [])
        }
        report(members: who.sorted())
    }

    /// The diagnostics: when who's here changes, and every 15 s.
    private func report(members: [String]) {
        let now = CACurrentMediaTime()
        let names = members.map { $0.components(separatedBy: "@").first ?? $0 }.joined(separator: ",")
        guard names != lastMembers || now - lastReport > 15, let deck else { return }
        lastMembers = names
        lastReport = now
        let pos = deck.position().map { "bar \($0.bar) beat \($0.beat)" } ?? "starting"
        diag("orchestra.mix", ["at": pos, "floor": BuildingLife.shared.currentFloor, "members": members.joined(separator: " "),
                               "gains": OrchestraPart.allCases.filter { $0 != .foundation }
                                   .map { "\($0.rawValue) \(String(format: "%.2f", gains[$0] ?? 0))->\(String(format: "%.2f", targets[$0] ?? 0))" }
                                   .joined(separator: ", "),
                               "master": String(format: "%.2f", deck.master)])
    }

    // MARK: Interruptions, the engine changing under it, back from the background

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let ended = raw.flatMap { AVAudioSession.InterruptionType(rawValue: $0) } == .ended
            guard ended else { return }
            MainActor.assumeIsolated { LivingOrchestra.shared.restart(why: "interruption ended") }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LivingOrchestra.shared.restartIfStopped(why: "engine configuration changed") }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LivingOrchestra.shared.restartIfStopped(why: "back in the app") }
        })
    }

    private func restartIfStopped(why: String) {
        guard let deck, !deck.isRunning else { return }
        restart(why: why)
    }

    private func restart(why: String) {
        guard deck != nil else { return }
        SoundEffects.configureAudioSession(reason: "orchestra restart")
        diag("orchestra.restart", ["why": why])
        restartPending = true                                            // (on the next tick, not inside the notification)
    }
}
