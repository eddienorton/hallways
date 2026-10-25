//
//  StemLab.swift
//  Hallways
//
//  Oct 25 (PP 5 recovery) -- THE TRACKS LAB, restored as the Music Lab's default: the Oct 24 Level-3 Music Lab
//  (Rollback/2026-10-24-before-lab-layers/MusicLab.swift) unchanged except for its type names (MusicLab ->
//  StemLab, LabComposition -> StemComposition, LabDeck -> StemDeck, MusicLabControls/Musicians ->
//  StemLabControls/Musicians), so it lives beside the arranger lab (MusicLab.swift). It plays the Hallways
//  Originals' own audio stems (lab-*.json + their loop and performance stems, bundled): one composition, its
//  full arrangement, each track switched on or off, any combination -- nothing re-arranged.
//  The Directory shows it by default (BuildingLifeApp: TRACKS); ARRANGER switches to the arranger lab.
//
//  ---- the original header (Oct 24) ----
//
//  Oct 24 -- THE MUSIC LAB (phase 1): live mixing of one composition's
//  musicians, in Building Life > Directory (StemLabControls + StemLabMusicians).
//
//  THE QUESTION: can a small band of Hallwaysians make music worth hearing
//  again? The lab plays one composition's musicians -- each its own stem --
//  and lets the player switch any of them in or out while it plays.
//
//  ONE TIMELINE: every musician's stem plays ALL the time, sample-locked to
//  the others (one audio engine, every player started at the same host time,
//  each loop pass queued straight after the last -- LivingOrchestra's proven
//  scheme). Switching a musician off only fades its volume to zero; on again,
//  it fades up from wherever the music is. Nothing restarts, nothing can drift.
//
//    LOOP          the composition's loop stems, looped seamlessly (each pass
//                  is exactly `loopFrames` long -- the manifest says so, so a
//                  container's padding can never open a gap at the loop point)
//    PERFORMANCE   the finished arrangement's stems, once, start to end; the
//                  musicians' switches are suspended; at its end, stopped.
//
//  A COMPOSITION is data: a JSON manifest in the bundle named "lab-*.json"
//  (title, genre, tempo, metre, loop length, and per musician its name,
//  instrument, colour, loop stem and performance stem). Nothing here knows any
//  piece's length, bars, instruments or how many musicians it has.
//
//  Oct 24 (Level 3) -- A COMPRESSED-LOOP EXPERIMENT (one piece only): a manifest may say
//  "loopStartFrame": the loop's stems are then AAC, padded with the loop's own end before it and its
//  start after it; each pass plays loopFrames from loopStartFrame. Without it -- every lossless loop,
//  the Waltz and Going Up! included -- loopStart is 0 and playback is exactly as before.
//
//  Oct 24 (Level 2) -- THE CATALOG: every bundled manifest is on the shelf,
//  ordered by its "order" (then file name). Only the manifests are read at
//  launch (a kilobyte each); a composition's stems are opened -- streamed from
//  disk by AVAudioFile, never loaded whole -- only when it plays, and released
//  when it stops. Choosing another piece (select) fades out whatever is playing
//  and puts the new piece's musicians on the stand, stopped; each piece keeps
//  the musicians you last had switched on. Adding a composition = adding its
//  manifest and stems to the bundle. ALL OFF switches every musician off but
//  keeps the music's clock running (silently), so a band can be built up one
//  musician at a time, from nothing, on one timeline.
//
//  Oct 24 -- EXCLUSIVE AUDIO: while the Directory is on screen the lab has the
//  audio focus (directoryOpened / directoryClosed): HallwaysAudio's temporary
//  silence "musicLab" -- the one mechanism Mute and Settings already use --
//  silences the 3D view's engine (critters, voices, doors, the elevator), every
//  managed player (footsteps, chimes, ambience, the phone, games) and, through
//  storyQuiet, the orchestra, walking music and greetings. Nothing is stopped or
//  rebuilt; lifted, everything is audible again as it was.
//
//  WHILE IT PLAYS (`StemLab.isActive`): the hallways' own music is quiet --
//  ResidentMusicConductor.storyQuiet includes it, so the living orchestra and
//  the walking music glide out and no check-in plays; a critter's musical
//  greeting gives way to its ordinary sound (or, where it had none, silence). Everything else (critters, voices,
//  doors, the elevator) is untouched. Mute silences the lab too. Audio-off
//  (Diagnostics) keeps it off. Stopped -- or the Directory closed -- and the
//  hallways' music returns on its own.
//
//  Its own engine, started only while it plays (nothing runs when stopped).
//

import AVFAudio
import Combine
import Foundation
import QuartzCore
import SwiftUI

// MARK: - A composition (data)

nonisolated struct StemComposition: Decodable, Sendable {
    nonisolated struct Part: Decodable, Sendable, Identifiable {
        let id: String
        let musician: String
        let instrument: String
        /// "#RRGGBB"
        let color: String
        /// Bundle file names (with extension).
        let loop: String
        let performance: String
    }
    let id: String
    let title: String
    let subtitle: String?
    /// "Swing", "Jazz waltz"... (optional).
    let genre: String?
    /// The catalog's order (optional; lower first, then by file name).
    let order: Int?
    let bpm: Double
    let beatsPerBar: Int
    /// The loop's exact length in sample frames (at `sampleRate`).
    let loopFrames: Int64
    /// Oct 24 (compression experiment, optional): where the loop starts inside its stem files. A compressed
    /// (AAC) loop stem carries a few thousand frames of the loop's own end before it and of its start after
    /// it, so a decoder's priming or padding can never land inside the loop. Absent (every lossless loop): 0.
    let loopStartFrame: Int64?
    let sampleRate: Double
    let parts: [Part]

    var loopSeconds: Double { Double(loopFrames) / sampleRate }
    var barSeconds: Double { 60 / bpm * Double(beatsPerBar) }
    var loopBars: Int { max(1, Int((loopSeconds / barSeconds).rounded())) }

    /// "Swing · 8 musicians"
    var caption: String {
        let who = parts.count == 1 ? "1 musician" : "\(parts.count) musicians"
        guard let g = genre, !g.isEmpty else { return who }
        return "\(g) · \(who)"
    }

    /// The catalog: every "lab-*.json" manifest in the app bundle (manifests only -- no audio),
    /// by `order`, then file name; a repeated composition id keeps the first.
    static func bundled() -> [StemComposition] {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("lab-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var seen = Set<String>()
        let all: [StemComposition] = urls.compactMap { url in
            do {
                let c = try JSONDecoder().decode(StemComposition.self, from: Data(contentsOf: url))
                guard Set(c.parts.map(\.id)).count == c.parts.count, !c.parts.isEmpty, c.loopFrames > 0 else {
                    diag("musicLab.manifestInvalid", ["file": url.lastPathComponent, "why": "no parts, a repeated part id, or no loop length"])
                    return nil
                }
                guard seen.insert(c.id).inserted else {
                    diag("musicLab.manifestInvalid", ["file": url.lastPathComponent, "why": "composition id \(c.id) already in the catalog"])
                    return nil
                }
                return c
            } catch {
                diag("musicLab.manifestUnreadable", ["file": url.lastPathComponent, "error": "\(error)"])
                return nil
            }
        }
        // (stable: equal orders keep the file-name order)
        return all.enumerated().sorted { a, b in
            let oa = a.element.order ?? Int.max, ob = b.element.order ?? Int.max
            return oa != ob ? oa < ob : a.offset < b.offset
        }.map(\.element)
    }

    static func url(_ file: String) -> URL? {
        let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "StemLab")
    }
}

// MARK: - The stems' engine (no UI; AVFoundation's threads drive the scheduling)

nonisolated final class StemDeck: @unchecked Sendable {
    enum Mode { case loop, performance }

    let mode: Mode
    private let engine = AVAudioEngine()
    private var players: [String: AVAudioPlayerNode] = [:]
    private var files: [String: AVAudioFile] = [:]
    private let order: [String]
    private let lock = NSLock()
    private var generation = 0
    /// Frames played per pass (loop) or in all (performance) -- the same for every stem.
    private(set) var frames: AVAudioFramePosition = 0
    private(set) var sampleRate: Double = 44100
    /// Where each loop pass starts in the stem files (the manifest's loopStartFrame; 0 for lossless loops).
    private var loopStart: AVAudioFramePosition = 0
    /// Oct 25 (PP 6, VOICES): other players on this engine (VoiceLab's voice), started at the stems' own
    /// instant -- their sample timeline is the stems': frame 0 = the loop's first frame. None: as before.
    private var companions: [AVAudioPlayerNode] = []

    /// Opens every musician's stem for `mode`. Nil: a stem is missing or unreadable.
    init?(composition c: StemComposition, mode: Mode, volumes: [String: Float]) {
        self.mode = mode
        order = c.parts.map(\.id)
        var shortest: AVAudioFramePosition = .max
        var rate = c.sampleRate
        for part in c.parts {
            let name = mode == .loop ? part.loop : part.performance
            guard let url = StemComposition.url(name), let file = try? AVAudioFile(forReading: url) else {
                diag("musicLab.stemMissing", ["file": name])
                return nil
            }
            if abs(file.processingFormat.sampleRate - c.sampleRate) > 0.5 {
                diag("musicLab.sampleRateMismatch", ["file": name, "file Hz": file.processingFormat.sampleRate, "manifest Hz": c.sampleRate])
                return nil
            }
            files[part.id] = file
            shortest = min(shortest, file.length)
            rate = file.processingFormat.sampleRate
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            node.volume = volumes[part.id] ?? 0
            players[part.id] = node
        }
        sampleRate = rate
        // The loop: exactly its stated length (never a container's padding); the performance: all of the shortest.
        loopStart = mode == .loop ? max(0, AVAudioFramePosition(c.loopStartFrame ?? 0)) : 0
        frames = mode == .loop ? min(shortest - loopStart, AVAudioFramePosition(c.loopFrames)) : shortest
        if mode == .loop, c.loopStartFrame != nil {
            diag("musicLab.paddedLoop", ["composition": c.id, "fileFrames": shortest, "loopStart": loopStart,
                                         "loopFrames": c.loopFrames, "playing": frames])
        }
        guard frames > 0 else { return nil }
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
    }

    /// Every stem from its start, together. `finished` (performance only): called once, at its end.
    func start(finished: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()
        for p in players.values { p.stop() }
        for p in companions { p.stop() }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            diag("musicLab.engineFailed", ["error": "\(error)"])
            return false
        }
        switch mode {
        case .loop:
            for id in order {                                    // two passes queued; each, taken up, queues another
                queue(id, gen: gen)
                queue(id, gen: gen)
            }
        case .performance:
            for (i, id) in order.enumerated() {
                guard let node = players[id], let file = files[id] else { continue }
                node.scheduleSegment(file, startingFrame: 0, frameCount: AVAudioFrameCount(frames), at: nil,
                                     completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard i == 0, let self else { return }
                    self.lock.lock()
                    let current = self.generation
                    self.lock.unlock()
                    if current == gen { finished() }
                }
            }
        }
        let at = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.12))
        for id in order { players[id]?.play(at: at) }
        for p in companions { p.play(at: at) }
        return true
    }

    /// Oct 25 (PP 6): one more player on this engine, into its mixer (so the lab's master fade and Mute
    /// apply to it); started with the stems by start(), stopped by stop(). Attach before start().
    func addCompanion(_ node: AVAudioPlayerNode, format: AVAudioFormat) {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        companions.append(node)
    }

    private func queue(_ id: String, gen: Int) {
        guard let node = players[id], let file = files[id] else { return }
        node.scheduleSegment(file, startingFrame: loopStart, frameCount: AVAudioFrameCount(frames), at: nil,
                             completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation
            self.lock.unlock()
            guard current == gen else { return }                     // (stopped: no more)
            self.queue(id, gen: gen)
        }
    }

    func stop() {
        lock.lock()
        generation += 1
        lock.unlock()
        for p in players.values { p.stop() }
        for p in companions { p.stop() }
        engine.stop()
    }

    var engineObject: AVAudioEngine { engine }
    func setVolume(_ id: String, _ v: Float) { players[id]?.volume = v }
    func setMaster(_ v: Float) { engine.mainMixerNode.outputVolume = v }
    var master: Float { engine.mainMixerNode.outputVolume }

    /// Seconds played since the start (all stems share it); nil before the first render.
    var playedSeconds: Double? {
        guard let id = order.first, let node = players[id], let t = node.lastRenderTime,
              let pt = node.playerTime(forNodeTime: t), pt.sampleTime >= 0 else { return nil }
        return Double(pt.sampleTime) / pt.sampleRate
    }
}

// MARK: - The lab (main actor: state, fades, isolation)

@MainActor
final class StemLab: ObservableObject {
    static let shared = StemLab()

    enum State: Equatable { case stopped, looping, performance }

    /// Every composition on the shelf (manifests only), in the catalog's order.
    let catalog: [StemComposition]
    /// The composition on the stand (its id; nil: none bundled).
    @Published private(set) var selectedID: String?
    /// The composition on the stand (nil: none bundled).
    var composition: StemComposition? { catalog.first { $0.id == selectedID } }
    @Published private(set) var state: State = .stopped
    /// The musicians switched on (in the loop).
    @Published private(set) var enabled: Set<String>
    /// "Bar 12 of 48" / "0:42 / 2:13" / "" (refreshed 4 times a second while playing).
    @Published private(set) var position = ""

    /// While the lab is playing (any thread): the hallways' own music stays quiet.
    nonisolated static var isActive: Bool { activeLock.withLock { active } }
    nonisolated private static let activeLock = NSLock()
    nonisolated(unsafe) private static var active = false
    private static func setActive(_ on: Bool) { activeLock.withLock { active = on } }

    /// The game's own silence: Mute (the speaker button) or a Settings suppression -- the lab too.
    private static var silenced: Bool {
        HallwaysAudio.shared.isMuted || HallwaysAudio.shared.isSuppressed(otherThan: HallwaysAudio.musicLabFocus)
    }

    /// A musician's switch fades this long (seconds); STOP fades the whole band this long.
    static let fade: Double = 0.25
    static let stopFade: Double = 0.3

    private var deck: StemDeck?
    /// Oct 25 (PP 6): the deck playing now (VoiceLab reads its clock).
    var currentDeck: StemDeck? { deck }
    /// Oct 25 (PP 6): called with each new deck just before it starts (VoiceLab adds its voice). Nil: as before.
    var deckWillStart: ((StemDeck, StemComposition) -> Void)?
    private var level: [String: Float] = [:]                 // each musician's volume now
    private var target: [String: Float] = [:]                // ... and where it's gliding
    private var masterLevel: Float = 0
    private var masterTarget: Float = 0
    private var fader: Timer?
    private var clock: Timer?
    private var lastStep = CACurrentMediaTime()
    private var stopToken = 0
    private var observers: [NSObjectProtocol] = []
    /// Each composition's musicians as last switched (a piece left and come back to is as you left it).
    private var enabledByComposition: [String: Set<String>] = [:]
    private static let selectedKey = "musicLab.selectedComposition"

    private init() {
        catalog = StemComposition.bundled()
        let remembered = UserDefaults.standard.string(forKey: Self.selectedKey)
        let first = catalog.first { $0.id == remembered } ?? catalog.first
        selectedID = first?.id
        enabled = Set(first?.parts.map(\.id) ?? [])
        if catalog.isEmpty { diag("musicLab.noComposition", [:]) }
        diag("musicLab.catalog", ["pieces": catalog.map(\.id).joined(separator: ","), "selected": selectedID ?? "-"])
    }

    var isAvailable: Bool { composition != nil && !AudioDiagnostics.audioOff }

    // MARK: Controls

    /// A musician's switch. In the loop: it fades out / back in where the music is.
    /// Stopped: switching one ON starts the loop with the musicians switched on.
    /// During the finished performance: suspended.
    func toggle(_ id: String) {
        guard state != .performance, isAvailable else { return }
        if enabled.contains(id) { enabled.remove(id) } else { enabled.insert(id) }
        diag("musicLab.toggle", ["who": id, "on": enabled.contains(id), "state": "\(state)", "bar": position])
        switch state {
        case .looping:
            target[id] = enabled.contains(id) ? 1 : 0
            startFader()
        case .stopped:
            // (switched on and off again within the fade: the pending start finds nobody, and stays stopped)
            if enabled.contains(id) { afterQuiet { if !self.enabled.isEmpty { self.startLoop() } } }
        case .performance:
            break
        }
    }

    /// Everyone on; the loop starts (or carries on, the missing ones fading in).
    func playAll() {
        guard let c = composition, isAvailable else { return }
        enabled = Set(c.parts.map(\.id))
        if state == .looping {
            for id in enabled { target[id] = 1 }
            startFader()
        } else {
            afterQuiet { self.startLoop() }
        }
    }

    /// Every musician off. In the loop the music's clock keeps running, silently -- switch
    /// anyone on and they come in where the music is. Stopped: nothing starts (tap a musician).
    func allOff() {
        guard state != .performance, isAvailable else { return }
        enabled = []
        diag("musicLab.allOff", ["state": "\(state)", "bar": position])
        if state == .looping {
            for id in target.keys { target[id] = 0 }
            startFader()
        }
    }

    /// Another composition on the stand: whatever is playing fades out (the old piece's
    /// stems released at the end of the fade); the new piece's musicians appear, stopped,
    /// switched as they were last time (everyone, the first time).
    func select(_ id: String) {
        guard id != selectedID, let next = catalog.first(where: { $0.id == id }) else { return }
        if let current = selectedID { enabledByComposition[current] = enabled }
        stopToken += 1                                       // (a start still on its way for the old piece: cancelled)
        if deck != nil { stop() }
        selectedID = id
        enabled = enabledByComposition[id] ?? Set(next.parts.map(\.id))
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
        diag("musicLab.select", ["composition": id, "musicians": next.parts.count])
    }

    /// Everything stops (a short fade).
    func stop() {
        guard state != .stopped || deck != nil else { return }
        state = .stopped
        position = ""
        masterTarget = 0
        startFader()
        stopToken += 1
        let token = stopToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopFade + 0.05) { [weak self] in
            guard let self, self.stopToken == token, self.state == .stopped else { return }
            self.teardown()
        }
        diag("musicLab.stop", [:])
    }

    /// The finished arrangement, once through (the switches wait).
    func hearPerformance() {
        guard composition != nil, isAvailable else { return }
        afterQuiet {
            self.teardown()
            self.start(.performance)
        }
    }

    /// Run `then` once nothing is sounding: at once if stopped, else after STOP's short fade
    /// (never a cut mid-note when switching between the loop and the performance).
    private func afterQuiet(_ then: @escaping @MainActor () -> Void) {
        guard deck != nil else { then(); return }
        stop()
        let token = stopToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopFade + 0.1) { [weak self] in
            guard let self, self.stopToken == token else { return }
            then()
        }
    }

    /// Oct 24 (exclusive audio): the Directory is on screen -- the lab has the audio
    /// focus: every other Hallways sound is silenced (HallwaysAudio's suppression,
    /// the same one Settings uses), playing, paused or stopped.
    func directoryOpened() {
        HallwaysAudio.shared.setSuppressed(true, reason: HallwaysAudio.musicLabFocus)
    }

    /// The Directory went away: the lab stops with it, and the focus is given back
    /// (the hallways' sounds and music return, unless Mute or Settings say otherwise).
    func directoryClosed() {
        stopToken += 1                                       // (a switch still on its way, cancelled too)
        stop()
        HallwaysAudio.shared.setSuppressed(false, reason: HallwaysAudio.musicLabFocus)
    }

    // MARK: Playing

    private func startLoop() {
        teardown()
        start(.loop)
    }

    private func start(_ mode: StemDeck.Mode) {
        guard let c = composition else { return }
        SoundEffects.configureAudioSession(reason: "musicLab")
        let volumes = Dictionary(uniqueKeysWithValues: c.parts.map { ($0.id, Float(mode == .performance || enabled.contains($0.id) ? 1 : 0)) })
        guard let d = StemDeck(composition: c, mode: mode, volumes: volumes) else { return }
        level = volumes
        target = volumes
        deck = d
        stopToken += 1
        Self.setActive(true)
        deckWillStart?(d, c)
        let deckID = ObjectIdentifier(d)                     // (the end of THIS deck's performance only)
        let started = d.start {
            DispatchQueue.main.async { MainActor.assumeIsolated { StemLab.shared.performanceEnded(deckID) } }
        }
        guard started else { teardown(); return }
        masterLevel = 0
        masterTarget = Self.silenced ? 0 : 1
        d.setMaster(0)
        startFader()
        state = mode == .loop ? .looping : .performance
        observe(d)
        startClock()
        diag("musicLab.start", ["mode": mode == .loop ? "loop" : "performance", "on": enabled.sorted().joined(separator: ",")])
    }

    private func performanceEnded(_ deckID: ObjectIdentifier) {
        guard state == .performance, let d = deck, ObjectIdentifier(d) == deckID else { return }
        diag("musicLab.performanceEnded", [:])
        state = .stopped
        position = ""
        teardown()
    }

    /// Everything off and released; the hallways may sing again.
    private func teardown() {
        deck?.stop()
        deck = nil
        fader?.invalidate(); fader = nil
        clock?.invalidate(); clock = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        masterLevel = 0
        if state != .stopped { state = .stopped; position = "" }
        Self.setActive(false)
    }

    // MARK: Fades (60 a second, only while something is gliding)

    private func startFader() {
        guard fader == nil else { return }
        lastStep = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { StemLab.shared.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        fader = t
    }

    private func step() {
        guard let d = deck else { fader?.invalidate(); fader = nil; return }
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastStep))
        lastStep = now
        var moving = false
        let rate = dt / Float(Self.fade)
        for (id, goal) in target {
            let cur = level[id] ?? 0
            guard cur != goal else { continue }
            let next = goal > cur ? min(goal, cur + rate) : max(goal, cur - rate)
            level[id] = next
            d.setVolume(id, next * next)                                 // (squared: an even-sounding fade)
            moving = true
        }
        if masterLevel != masterTarget {
            let r = dt / Float(masterTarget < masterLevel && state == .stopped ? Self.stopFade : 0.12)
            masterLevel = masterTarget > masterLevel ? min(masterTarget, masterLevel + r) : max(masterTarget, masterLevel - r)
            d.setMaster(masterLevel)
            moving = true
        }
        if !moving { fader?.invalidate(); fader = nil }
    }

    // MARK: Where the music is; Mute; interruptions

    private func startClock() {
        clock?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { StemLab.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        clock = t
        tick()
    }

    private func tick() {
        guard let c = composition, let d = deck, state != .stopped else { return }
        // Mute (the game's speaker button) silences the lab too; un-muted, it comes back.
        let wanted: Float = Self.silenced ? 0 : 1
        if wanted != masterTarget { masterTarget = wanted; startFader() }
        guard let played = d.playedSeconds else { return }
        switch state {
        case .looping:
            let inLoop = played.truncatingRemainder(dividingBy: Double(d.frames) / d.sampleRate)
            position = "Bar \(Int(inLoop / c.barSeconds) + 1) of \(c.loopBars)"
        case .performance:
            let total = Double(d.frames) / d.sampleRate
            position = "\(Self.clock(min(played, total))) / \(Self.clock(total))"
        case .stopped:
            position = ""
        }
    }

    private static func clock(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }

    /// The engine was reconfigured (a route change) or the session interrupted: stopped, cleanly.
    private func observe(_ d: StemDeck) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: d.engineObject, queue: .main) { _ in
            MainActor.assumeIsolated {
                diag("musicLab.interrupted", ["why": "engine configuration change"])
                StemLab.shared.stopToken += 1
                StemLab.shared.teardown()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) } == .began
            MainActor.assumeIsolated {
                guard began else { return }
                diag("musicLab.interrupted", ["why": "audio session interruption"])
                StemLab.shared.stopToken += 1
                StemLab.shared.teardown()
            }
        })
    }
}

// MARK: - The Directory's BAND / MUSIC LAB
//
// Oct 24 (Level 2): two pieces. StemLabControls is fixed at the top of the
// Directory (never part of its sorted list): the composition selector, where the
// music is, PLAY ALL / ALL OFF / STOP and the finished performance -- always in
// reach. StemLabMusicians is the first thing in the Directory's scrolling list:
// the stand's musicians (four, eight, however many the piece has), two large
// tiles a row -- with eight it scrolls rather than shrinking anything.

struct StemLabControls: View {
    @ObservedObject private var lab = StemLab.shared

    var body: some View {
        if let c = lab.composition {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("BAND · MUSIC LAB")
                        .font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                    Spacer(minLength: 8)
                    Text(status)
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(PhoneStyle.inkSoft)
                        .lineLimit(1)
                }
                selector(current: c)
                HStack(spacing: 8) {
                    control("PLAY ALL", "play.fill", filled: true) { lab.playAll() }
                    control("ALL OFF", "circle.slash", filled: false) { lab.allOff() }
                        .disabled(lab.state == .performance || lab.enabled.isEmpty)
                        .opacity(lab.state == .performance || lab.enabled.isEmpty ? 0.45 : 1)
                    control("STOP", "stop.fill", filled: false) { lab.stop() }
                        .disabled(lab.state == .stopped)
                        .opacity(lab.state == .stopped ? 0.45 : 1)
                }
                control(lab.state == .performance ? "PLAYING FINISHED PERFORMANCE" : "HEAR FINISHED PERFORMANCE",
                        "music.note.list", filled: lab.state == .performance) { lab.hearPerformance() }
                    .disabled(lab.state == .performance)
                if !lab.isAvailable {
                    Text("Audio is off (Settings › Diagnostics).")
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PhoneStyle.rule, lineWidth: 1))
            .padding(.horizontal, 14)
        }
    }

    /// The shelf: one card per composition. Up to three share the width; more scroll sideways.
    @ViewBuilder
    private func selector(current: StemComposition) -> some View {
        if lab.catalog.count <= 3 {
            HStack(spacing: 8) {
                ForEach(lab.catalog, id: \.id) { piece in
                    card(piece, selected: piece.id == current.id).frame(maxWidth: .infinity)
                }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(lab.catalog, id: \.id) { piece in
                        card(piece, selected: piece.id == current.id).frame(width: 168)
                    }
                }
            }
        }
    }

    private func card(_ piece: StemComposition, selected: Bool) -> some View {
        Button { lab.select(piece.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(piece.title)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(piece.caption)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .opacity(0.8)
            }
            .foregroundStyle(selected ? .white : PhoneStyle.ink)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? PhoneStyle.ink : Color.white.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? PhoneStyle.ink : PhoneStyle.rule, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(piece.title), \(piece.caption)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var status: String {
        switch lab.state {
        case .stopped: return "Stopped"
        case .looping: return lab.position.isEmpty ? "Playing" : lab.position
        case .performance: return lab.position.isEmpty ? "Performance" : lab.position
        }
    }

    private func control(_ title: String, _ symbol: String, filled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(filled ? .white : PhoneStyle.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(filled ? PhoneStyle.ink : Color.black.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!lab.isAvailable)
    }
}

/// The stand: the selected composition's musicians, two tiles a row, each switch large enough
/// to hit without looking twice. Lives at the top of the Directory's scrolling list.
struct StemLabMusicians: View {
    @ObservedObject private var lab = StemLab.shared

    var body: some View {
        if let c = lab.composition {
            VStack(alignment: .leading, spacing: 8) {
                Text(hint)
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(c.parts) { part in
                        musician(part)
                    }
                }
            }
            .padding(.horizontal, 14)
            .id(c.id)                                          // (a new piece: fresh tiles, no cross-fade of the old)
        }
    }

    private var hint: String {
        switch lab.state {
        case .performance: return "The finished performance -- everyone plays. The switches wait until it ends."
        case .looping: return "Tap a musician to bring them in or out. The music keeps going."
        case .stopped:
            return lab.enabled.isEmpty ? "Tap a musician to start with just them."
                                       : "Tap PLAY ALL -- or ALL OFF, then build the band one musician at a time."
        }
    }

    private func musician(_ part: StemComposition.Part) -> some View {
        let on = lab.enabled.contains(part.id)
        let locked = lab.state == .performance
        let tint = StemLabControls.tint(part.color)
        return Button { lab.toggle(part.id) } label: {
            HStack(spacing: 10) {
                Circle().fill(on || locked ? tint : tint.opacity(0.25))
                    .frame(width: 34, height: 34)
                    .overlay(Text(String(part.musician.prefix(1))).font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text(part.musician).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(PhoneStyle.ink)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(part.instrument).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 2)
                Text(locked ? "—" : (on ? "ON" : "OFF"))
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(on && !locked ? .white : PhoneStyle.inkSoft)
                    .frame(width: 38, height: 22)
                    .background(Capsule().fill(on && !locked ? tint : Color.black.opacity(0.07)))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(on ? 0.9 : 0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on && !locked ? tint : PhoneStyle.rule, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked || !lab.isAvailable)
        .opacity(locked ? 0.6 : 1)
        .accessibilityLabel("\(part.musician), \(part.instrument)")
        .accessibilityValue(on ? "on" : "off")
    }
}

extension StemLabControls {
    /// "#RRGGBB" (anything else: grey).
    static func tint(_ hex: String) -> Color {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .gray }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
