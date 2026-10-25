//
//  FloorSoundtrack.swift
//  Hallways
//
//  Oct 25 (PP 7) -- FLOOR SOUNDTRACKS AND MUSICAL FOLLOWERS (an audition).
//
//  On the floors listed in floor-soundtracks.json (4-7 for now), the floor's music is a Hallways Originals
//  song -- its own recorded loop stems, the TRACKS lab's engine (StemDeck), round and round -- instead of
//  the living orchestra. It plays whether or not anybody follows.
//
//  THE ARRANGEMENT (SoundtrackLineup.make -- pure, tested):
//    * the song's BASELINE tracks always play (the data's "baseline"; nothing is ever deleted -- a track
//      not in it is simply silent until someone plays it);
//    * each follower (FOLLOW ME order) whose INSTRUMENT (BandInstruments.byResident -- one identity per
//      resident, the same on every floor) may play a track not already sounding takes the first such track
//      (the data's "parts": track -> instruments). Never doubled; a baseline track is never added twice;
//    * every other follower SINGS: its own recorded voice (Hallways/Voices -- the same voice for that
//      resident everywhere; SoundtrackVoices.voice), on the song's own clock.
//  A follower joining or leaving changes the arrangement at the next bar line, faded over a bar
//  (`fadeBars`); the song never restarts for it.
//
//  THE VOICES (ChoirPlan -- pure, tested): the loop is cut into SLOTS (`slotBars` bars, at `beat`: the
//  song's own meter and tempo, from its manifest). One voice at most per slot -- never two at once. One
//  singer: every `soloEvery`-th slot. Several: every slot, in turns (slot 1 the first follower's, slot 2
//  the next's...). Each sings a note of the chord sounding at its slot (the song's harmony map: root,
//  third, fifth, third in turn, nearest its recording's own note, 6 semitones down to 5 up -- PP 6's
//  rule), or as recorded where a song has no harmony map. Every voice is shorter than a slot (cut under
//  1.45 s; the shortest slot is 2.37 s): nothing piles up, nothing hangs. All the voices share one player
//  node on the song's engine, scheduled at exact sample times on the stems' own clock (ChoirTrack).
//
//  THE REST OF THE HALLWAYS' MUSIC on these floors: the living orchestra is silent (LivingOrchestra), the
//  walking band doesn't play (WalkingBand), nor the walking music (ResidentWalkingMusic), nor the
//  residents' signature music -- ambient, check-ins, the follow greeting and goodbye (ResidentMusic). Floors
//  1-3 (not listed): everything exactly as before.
//
//  QUIET: Mute, Settings, the Music Lab (the Directory open: its audio focus) and any story under way
//  (ResidentMusicConductor.storyQuiet) bring it down smoothly; its clock keeps going. A new floor: this
//  song fades out (`floorFadeSeconds`), the next floor's starts from its top a moment after arrival.
//
//  OFF (everything exactly as before PP 7): launch with `-HallwaysFloorSoundtracks NO`.
//

import AVFAudio
import Foundation
import QuartzCore

// MARK: - The data (floor-soundtracks.json)

nonisolated struct SoundtrackConfig: Decodable, Sendable {
    nonisolated struct VoiceRule: Decodable, Sendable, Equatable {
        /// A slot every this many bars...
        let slotBars: Int
        /// ...on this beat of its first bar (0-based).
        let beat: Int
        /// One singer alone: every this-many-th slot.
        let soloEvery: Int
    }
    nonisolated struct Song: Decodable, Sendable {
        /// Track (part) ids always playing.
        let baseline: [String]
        /// Track id -> the Hallwaysian instruments that may play it (in preference order; none: nobody).
        let parts: [String: [String]]
        /// The song's chord map (a bundled song-harmony-*.json, without extension); nil: voices as recorded.
        let harmony: String?
        let voice: VoiceRule
    }
    let format: String
    /// The song's level against the rest of the game (the living orchestra plays at 0.5).
    let level: Double
    /// The voices' level against the song's tracks.
    let voiceLevel: Double
    /// A track joining or leaving: faded over this many bars, from the next bar line.
    let fadeBars: Double
    /// A new floor: the old song fades out over this (seconds).
    let floorFadeSeconds: Double
    /// "keepLength" or "tape" (PP 6's two ways of shifting a voice).
    let pitchMethod: String?
    /// Floor number (as text) -> composition id (a lab-*.json manifest's id).
    let floors: [String: String]
    let songs: [String: Song]
    /// Resident id -> voice file name: overrides the deterministic choice (SoundtrackVoices.voice).
    let voices: [String: String]?

    static func decode(_ data: Data) -> SoundtrackConfig? {
        guard let c = try? JSONDecoder().decode(SoundtrackConfig.self, from: data),
              c.format == "hallways-floor-soundtracks/1" else { return nil }
        return c
    }

    static func bundled() -> SoundtrackConfig? {
        guard let url = BandAssets.url("floor-soundtracks", "json"), let data = try? Data(contentsOf: url) else {
            diag("soundtrack.configMissing", [:])
            return nil
        }
        guard let c = decode(data) else {
            diag("soundtrack.configUnreadable", [:])
            return nil
        }
        return c
    }

    func song(forFloor floor: Int?) -> String? {
        guard let floor else { return nil }
        return floors[String(floor)]
    }

    var method: VoiceRender.Method { pitchMethod == "tape" ? .tape : .keepLength }
}

// MARK: - A song's chords (song-harmony-*.json; chords may change within a bar)

nonisolated struct SongHarmony: Decodable, Sendable {
    nonisolated struct Change: Decodable, Sendable, Equatable {
        /// Where in the bar it starts (beats from its downbeat).
        let beat: Double
        let chord: String
        /// Pitch classes (C = 0): root, third, fifth, then the rest.
        let tones: [Int]
    }
    let format: String
    let composition: String
    let beatsPerBar: Int
    /// One list of changes per bar of the loop.
    let bars: [[Change]]

    /// The chord sounding at `beat` of `bar` (0-based): the bar's last change at or before it.
    func chord(bar: Int, beat: Double) -> Change? {
        guard bars.indices.contains(bar) else { return nil }
        return bars[bar].last { $0.beat <= beat + 1e-6 } ?? bars[bar].first
    }

    static func decode(_ data: Data) -> SongHarmony? {
        guard let h = try? JSONDecoder().decode(SongHarmony.self, from: data), h.format == "hallways-song-harmony/1",
              !h.bars.isEmpty,
              h.bars.allSatisfy({ !$0.isEmpty && $0.allSatisfy { !$0.tones.isEmpty && $0.tones.allSatisfy { (0..<12).contains($0) } } }) else {
            return nil
        }
        return h
    }

    static func bundled(_ file: String) -> SongHarmony? {
        guard let url = BandAssets.url(file, "json"), let data = try? Data(contentsOf: url) else {
            diag("soundtrack.harmonyMissing", ["file": file])
            return nil
        }
        guard let h = decode(data) else {
            diag("soundtrack.harmonyUnreadable", ["file": file])
            return nil
        }
        return h
    }
}

// MARK: - Who plays what (pure)

nonisolated struct SoundtrackLineup: Sendable, Equatable {
    /// Track ids sounding: the baseline and the followers' tracks.
    var sounding: Set<String> = []
    /// Track id -> the follower playing it.
    var players: [String: String] = [:]
    /// The followers singing, in FOLLOW ME order.
    var singers: [String] = []

    /// `partIDs`: the song's tracks in its manifest's order (a track the data doesn't know stays silent).
    static func make(partIDs: [String], song: SoundtrackConfig.Song, followers: [String],
                     instrument: (String) -> String?) -> SoundtrackLineup {
        var l = SoundtrackLineup()
        let known = Set(partIDs)
        for p in song.baseline where known.contains(p) { l.sounding.insert(p) }
        for who in followers where !l.players.values.contains(who) && !l.singers.contains(who) {
            if let inst = instrument(who),
               let p = partIDs.first(where: { !l.sounding.contains($0) && (song.parts[$0] ?? []).contains(inst) }) {
                l.sounding.insert(p)
                l.players[p] = who
            } else {
                l.singers.append(who)
            }
        }
        return l
    }
}

// MARK: - Each resident's voice (deterministic)

nonisolated enum SoundtrackVoices {
    /// A resident's voice: the data's override, else one of the bundled voices chosen by its id (FNV-1a --
    /// the same on every launch and device). Adding or removing a voice file can change the choices;
    /// pin one with the data's "voices".
    static func voice(for id: String, samples: [VoiceSample], overrides: [String: String]) -> VoiceSample? {
        if let f = overrides[id], let s = samples.first(where: { $0.id == f }) { return s }
        guard !samples.isEmpty else { return nil }
        return samples[Int(fnv1a(id) % UInt64(samples.count))]
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }
}

// MARK: - When each voice sings, and on what note (pure)

nonisolated enum ChoirPlan {
    nonisolated struct Event: Sendable, Equatable {
        /// Which singer (index into the singers).
        let singer: Int
        /// 0-based bar and beat of the loop.
        let bar: Int
        let beat: Int
        /// Frames from the loop's first frame.
        let frame: Int64
        /// Semitones from the recording.
        let shift: Int
        /// The note sung (nil: a spoken recording -- only the shift is known).
        let note: Int?
        let chord: String
    }

    /// One pass of the loop. `notes`: each singer's recorded note (nil: spoken, placed as A3 -- PP 6).
    static func events(singers notes: [Int?], rule: SoundtrackConfig.VoiceRule, loopBars: Int, beatsPerBar: Int,
                       harmony: SongHarmony?, barFrames: Int64, beatFrames: Int64) -> [Event] {
        guard !notes.isEmpty, rule.slotBars > 0, loopBars > 0, barFrames > 0 else { return [] }
        let beat = min(max(0, rule.beat), max(0, beatsPerBar - 1))
        let usable = harmony.map { $0.bars.count == loopBars } ?? false
        var sung = [Int](repeating: 0, count: notes.count)
        var out: [Event] = []
        for (slot, bar) in stride(from: 0, to: loopBars, by: rule.slotBars).enumerated() {
            let who: Int
            if notes.count == 1 {
                guard slot % max(1, rule.soloEvery) == 0 else { continue }
                who = 0
            } else {
                who = slot % notes.count
            }
            let ref = notes[who] ?? VoicePlan.referenceNote
            var shift = 0
            var name = ""
            if usable, let c = harmony?.chord(bar: bar, beat: Double(beat)) {
                shift = VoicePlan.target(tones: c.tones, role: VoicePlan.roles[sung[who] % VoicePlan.roles.count], source: ref) - ref
                name = c.chord
            }
            sung[who] += 1
            out.append(Event(singer: who, bar: bar, beat: beat, frame: Int64(bar) * barFrames + Int64(beat) * beatFrames,
                             shift: shift, note: notes[who].map { $0 + shift }, chord: name))
        }
        return out
    }
}

// MARK: - The voices on the song's clock (one node on the song's engine; nonisolated)

/// Prepared voices: "<file>#<shift>" -> buffer. Read-only once made.
nonisolated struct ChoirBuffers: @unchecked Sendable {
    let byKey: [String: AVAudioPCMBuffer]
    static let empty = ChoirBuffers(byKey: [:])
    static func key(_ file: String, _ shift: Int) -> String { "\(file)#\(shift)" }
}

nonisolated final class ChoirTrack: @unchecked Sendable {
    nonisolated struct Cue: Sendable, Equatable {
        let frame: Int64
        let key: String
    }

    let node = AVAudioPlayerNode()
    let format: AVAudioFormat
    let sampleRate: Double
    let loopFrames: Int64

    private let lock = NSLock()
    private var cues: [Cue] = []
    private var buffers = ChoirBuffers.empty
    private var scheduledTo: Int64 = 0
    private var timer: DispatchSourceTimer?

    private static let queue = DispatchQueue(label: "hallways.soundtrack.choir", qos: .userInitiated)
    /// Look this far ahead (s) every `poll` (s); never closer than `lead` (s) to now (PP 6's figures).
    static let horizon = 0.35, poll = 0.05, lead = 0.03

    init?(sampleRate: Double, loopFrames: Int64) {
        guard loopFrames > 0, let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        format = f
        self.sampleRate = sampleRate
        self.loopFrames = loopFrames
    }

    deinit { timer?.cancel() }

    func set(cues c: [Cue]) { lock.withLock { cues = c } }
    func set(buffers b: ChoirBuffers) { lock.withLock { buffers = b } }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: Self.queue)
        t.schedule(deadline: .now(), repeating: Self.poll, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.pump() }
        lock.withLock {
            timer?.cancel()
            timer = t
        }
        t.resume()
    }

    func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    private func pump() {
        guard let render = node.lastRenderTime, render.isSampleTimeValid,
              let now = node.playerTime(forNodeTime: render) else { return }
        lock.lock()
        let from = max(scheduledTo, now.sampleTime + Int64(Self.lead * sampleRate))
        let to = now.sampleTime + Int64(Self.horizon * sampleRate)
        guard to > from else { lock.unlock(); return }
        scheduledTo = to
        let due = cues
        let bufs = buffers.byKey
        lock.unlock()
        for c in Self.due(due, loopFrames: loopFrames, from: from, to: to) {
            guard let b = bufs[c.key] else { continue }                       // (its voice still being prepared)
            node.scheduleBuffer(b, at: AVAudioTime(sampleTime: c.frame, atRate: sampleRate), options: [], completionHandler: nil)
        }
    }

    /// The cues falling in [from, to) of the endless loop, at their absolute frames, in time order.
    static func due(_ cues: [Cue], loopFrames: Int64, from: Int64, to: Int64) -> [Cue] {
        guard loopFrames > 0, to > from else { return [] }
        var out: [Cue] = []
        var pass = max(0, from / loopFrames)
        while pass * loopFrames < to {
            for c in cues {
                let at = pass * loopFrames + c.frame
                if at >= from && at < to { out.append(Cue(frame: at, key: c.key)) }
            }
            pass += 1
        }
        return out.sorted { $0.frame < $1.frame }
    }
}

// MARK: - The conductor (main actor, ten times a second)

@MainActor
final class FloorSoundtrack {
    static let shared = FloorSoundtrack()

    /// On unless switched off (`-HallwaysFloorSoundtracks NO`).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "HallwaysFloorSoundtracks") == nil || UserDefaults.standard.bool(forKey: "HallwaysFloorSoundtracks")
    }
    static let interval: TimeInterval = 0.1
    /// A new floor counts this long after arrival (seconds) -- as the walking band.
    static let floorSettle: CFTimeInterval = 1.0
    /// The longest a voice may be (s): under the shortest slot (2.37 s, The Lantern Room's one bar).
    static let maxVoiceSeconds: Double = 1.45

    let config: SoundtrackConfig?
    private let catalog: [StemComposition]
    private let samples: [VoiceSample]
    /// Songs that couldn't start (a stem missing): the floor keeps the living orchestra.
    private var unavailable = Set<String>()

    private var timer: Timer?
    private var deck: StemDeck?
    private var choir: ChoirTrack?
    private var songID: String?
    private var composition: StemComposition?
    private var harmony: SongHarmony?
    private var startedAt: CFTimeInterval = 0
    private var leaving = false
    private var retryAt: CFTimeInterval = 0
    private var seenFloor: Int?
    private var seenFloorAt: CFTimeInterval = 0

    private var master: Float = 0
    private var level: [String: Float] = [:]
    private var goal: [String: Float] = [:]
    /// A track's change waits for this point of the song's timeline (seconds played): the next bar line.
    private var changeAt: [String: Double] = [:]
    private var lineup = SoundtrackLineup()
    private var singerKey = ""

    /// Each voice file, prepared at every shift (shared across songs: they're all 44.1 kHz).
    private var ready: [String: VoiceBuffers] = [:]
    private var preparing = Set<String>()
    /// Voice files that couldn't be read (said once; that singer stays silent).
    private var unreadable = Set<String>()
    private static let renderQueue = DispatchQueue(label: "hallways.soundtrack.render", qos: .utility)

    private init() {
        config = SoundtrackConfig.bundled()
        catalog = StemComposition.bundled()
        samples = VoiceSample.bundled()
        diag("soundtrack.config", ["floors": config.map { $0.floors.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") } ?? "-",
                                   "voices": samples.map(\.id).joined(separator: ",")])
    }

    /// The song for `floor`, if this system plays one there (enabled, listed, its manifest bundled, startable).
    func song(forFloor floor: Int?) -> StemComposition? {
        guard Self.isEnabled, !AudioDiagnostics.audioOff, let c = config, let id = c.song(forFloor: floor),
              c.songs[id] != nil, !unavailable.contains(id) else { return nil }
        return catalog.first { $0.id == id }
    }

    /// The player's floor has a soundtrack: the orchestra, the walking band, the walking music and the
    /// residents' signature music stay out of it.
    var ownsFloor: Bool { song(forFloor: BuildingLife.shared.currentFloor) != nil }

    /// From the building's tick (ResidentMusicConductor.tick): started once.
    func ensureRunning() {
        guard timer == nil, Self.isEnabled, !AudioDiagnostics.audioOff, config != nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { FloorSoundtrack.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        diag("soundtrack.ready", [:])
    }

    // MARK: Ten times a second

    private func tick() {
        guard let cfg = config else { return }
        let now = CACurrentMediaTime()
        let floor = BuildingLife.shared.currentFloor
        if floor != seenFloor { seenFloor = floor; seenFloorAt = now }
        let wanted = song(forFloor: floor)

        // a new floor (or a floor without a soundtrack): this song fades out first
        if deck != nil, !leaving, wanted?.id != songID {
            leaving = true
            diag("soundtrack.leaving", ["song": songID, "floor": floor, "next": wanted?.id])
        }
        // the engine stopped under it (an interruption, a route change): released; started again shortly
        if let d = deck, !leaving, now - startedAt > 1.5, !d.engineObject.isRunning {
            diag("soundtrack.engineStopped", ["song": songID])
            teardown()
            retryAt = now + 2
        }
        if deck == nil, let w = wanted, now - seenFloorAt >= Self.floorSettle, now >= retryAt {
            start(w, cfg)
        }
        guard let d = deck, let c = composition, let rules = cfg.songs[c.id] else { return }

        // the level: in, quiet (Mute, Settings, the Lab, a story), or out (leaving)
        let quiet = ResidentMusicConductor.storyQuiet
        let target: Float = leaving || quiet ? 0 : Float(cfg.level)
        let seconds = leaving ? max(0.1, cfg.floorFadeSeconds) : 1.0
        let step = Float(Self.interval / seconds) * Float(max(cfg.level, 0.05))
        master = target > master ? min(target, master + step) : max(target, master - step)
        d.setMaster(master)
        if leaving, master <= 0.001 {
            teardown()
            return
        }

        // who plays what (changes at the next bar line, faded over `fadeBars`)
        let next = SoundtrackLineup.make(partIDs: c.parts.map(\.id), song: rules, followers: FollowMe.ids,
                                         instrument: { BandInstruments.byResident[$0] })
        let played = d.playedSeconds ?? 0
        if next != lineup {
            let bar = c.barSeconds
            let nextBar = (played / bar).rounded(.down) * bar + bar
            for p in c.parts.map(\.id) {
                let g: Float = next.sounding.contains(p) ? 1 : 0
                if g != goal[p] {
                    goal[p] = g
                    changeAt[p] = nextBar
                }
            }
            diag("soundtrack.lineup", ["song": c.id, "floor": floor, "at": String(format: "%.1f", played),
                                       "tracks": c.parts.map(\.id).filter { next.sounding.contains($0) }.joined(separator: ","),
                                       "players": next.players.sorted { $0.key < $1.key }.map { "\($0.value)=\($0.key)" }.joined(separator: " "),
                                       "singers": next.singers.map { "\($0)=\(voice(for: $0)?.name ?? "-")" }.joined(separator: " ")])
            lineup = next
        }
        let rate = Float(Self.interval / max(0.05, cfg.fadeBars * c.barSeconds))
        for (p, g) in goal {
            guard played >= (changeAt[p] ?? 0) else { continue }
            let cur = level[p] ?? 0
            guard cur != g else { continue }
            let v = g > cur ? min(g, cur + rate) : max(g, cur - rate)
            level[p] = v
            d.setVolume(p, v * v)                                          // (squared: an even-sounding fade, as the lab)
        }
        updateChoir(rules, cfg)
    }

    // MARK: Starting and stopping a song

    private func start(_ c: StemComposition, _ cfg: SoundtrackConfig) {
        guard let rules = cfg.songs[c.id] else { return }
        SoundEffects.configureAudioSession(reason: "soundtrack")
        let l = SoundtrackLineup.make(partIDs: c.parts.map(\.id), song: rules, followers: FollowMe.ids,
                                      instrument: { BandInstruments.byResident[$0] })
        let volumes = Dictionary(uniqueKeysWithValues: c.parts.map { ($0.id, Float(l.sounding.contains($0.id) ? 1 : 0)) })
        guard let d = StemDeck(composition: c, mode: .loop, volumes: volumes) else {
            unavailable.insert(c.id)                                       // (said once; the orchestra stays on that floor)
            diag("soundtrack.unavailable", ["song": c.id])
            return
        }
        let ch = ChoirTrack(sampleRate: d.sampleRate, loopFrames: Int64(d.frames))
        if let ch { d.addCompanion(ch.node, format: ch.format) }
        guard d.start(finished: {}) else {
            d.stop()
            retryAt = CACurrentMediaTime() + 2
            return
        }
        deck = d
        choir = ch
        songID = c.id
        composition = c
        harmony = rules.harmony.flatMap { SongHarmony.bundled($0) }
        if let h = harmony, h.bars.count != c.loopBars || h.beatsPerBar != c.beatsPerBar {
            diag("soundtrack.harmonyMismatch", ["song": c.id, "harmonyBars": h.bars.count, "loopBars": c.loopBars])
            harmony = nil                                                  // (voices as recorded: no guessing)
        }
        lineup = l
        level = volumes
        goal = volumes
        changeAt = [:]
        singerKey = ""
        master = 0
        d.setMaster(0)
        leaving = false
        startedAt = CACurrentMediaTime()
        ch?.node.volume = Float(cfg.voiceLevel)
        ch?.start()
        updateChoir(rules, cfg)
        diag("soundtrack.start", ["song": c.id, "floor": BuildingLife.shared.currentFloor, "bpm": c.bpm, "meter": c.beatsPerBar,
                                  "bars": c.loopBars, "harmony": harmony != nil,
                                  "tracks": c.parts.map(\.id).filter { l.sounding.contains($0) }.joined(separator: ","),
                                  "singers": l.singers.joined(separator: ",")])
    }

    private func teardown() {
        choir?.stop()
        deck?.stop()
        diag("soundtrack.stop", ["song": songID])
        choir = nil
        deck = nil
        songID = nil
        composition = nil
        harmony = nil
        leaving = false
        master = 0
        level = [:]
        goal = [:]
        changeAt = [:]
        lineup = SoundtrackLineup()
        singerKey = ""
    }

    // MARK: The voices

    private func voice(for id: String) -> VoiceSample? {
        SoundtrackVoices.voice(for: id, samples: samples, overrides: config?.voices ?? [:])
    }

    /// The singers changed (or a voice finished preparing): the cues for one pass of the loop, again.
    private func updateChoir(_ rules: SoundtrackConfig.Song, _ cfg: SoundtrackConfig) {
        guard let ch = choir, let c = composition else { return }
        let voices = lineup.singers.compactMap { id in voice(for: id).map { (id, $0) } }
        for (_, v) in voices where ready[v.id] == nil && !unreadable.contains(v.id) { prepare(v, cfg) }
        let key = voices.map { "\($0.0)=\($0.1.id)" }.joined(separator: ",") + "|" + voices.map { ready[$0.1.id] == nil ? "0" : "1" }.joined()
        guard key != singerKey else { return }
        singerKey = key
        let events = ChoirPlan.events(singers: voices.map { $0.1.note }, rule: rules.voice, loopBars: c.loopBars, beatsPerBar: c.beatsPerBar,
                                      harmony: harmony, barFrames: Int64((c.barSeconds * c.sampleRate).rounded()),
                                      beatFrames: Int64((60 / c.bpm * c.sampleRate).rounded()))
        ch.set(cues: events.map { ChoirTrack.Cue(frame: $0.frame, key: ChoirBuffers.key(voices[$0.singer].1.id, $0.shift)) })
        var all: [String: AVAudioPCMBuffer] = [:]
        for (_, v) in voices {
            for (shift, b) in ready[v.id]?.byShift ?? [:] { all[ChoirBuffers.key(v.id, shift)] = b }
        }
        ch.set(buffers: ChoirBuffers(byKey: all))
        if !voices.isEmpty {
            diag("soundtrack.choir", ["song": c.id, "singers": voices.map { "\($0.0)=\($0.1.name)" }.joined(separator: " "),
                                      "events": events.count, "ready": voices.filter { ready[$0.1.id] != nil }.count])
        }
    }

    private func prepare(_ v: VoiceSample, _ cfg: SoundtrackConfig) {
        guard !preparing.contains(v.id), let rate = composition?.sampleRate else { return }
        preparing.insert(v.id)
        let url = v.url, id = v.id, method = cfg.method, maxSeconds = Self.maxVoiceSeconds
        Self.renderQueue.async {
            let made = VoiceBuffers(byShift: VoiceRender.prepare(url, sampleRate: rate, method: method,
                                                                 shifts: VoicePlan.range, maxSeconds: maxSeconds))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { FloorSoundtrack.shared.voiceReady(id, made) }
            }
        }
    }

    private func voiceReady(_ id: String, _ b: VoiceBuffers) {
        preparing.remove(id)
        guard !b.byShift.isEmpty else {
            unreadable.insert(id)
            diag("soundtrack.voiceUnreadable", ["voice": id])
            return
        }
        ready[id] = b                                                   // (picked up on the next tick)
        diag("soundtrack.voicePrepared", ["voice": id, "shifts": b.byShift.count])
    }
}
