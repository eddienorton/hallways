//
//  VoiceLab.swift
//  Hallways
//
//  Oct 25 (PP 6) -- MUSICAL CRITTER VOICES, first audition: the Music Lab's VOICES mode.
//
//  ONE QUESTION: does a short recorded critter voice, placed in time with the original Night Shift Waltz
//  (and, optionally, sung on the notes of its chords), make the music more enjoyable? A listening
//  experiment only -- nothing here touches the hallways' music or the followers.
//
//  THE BACKING: the TRACKS lab's own engine (StemLab / StemDeck) playing the Night Shift Waltz's four
//  original loop stems, all on, unchanged. The voice is one more player node on that same engine
//  (StemDeck.addCompanion), started at the same instant as the stems -- so its sample clock IS the
//  song's: frame 0 = bar 1, beat 1 of the loop; one bar = 3 beats x 0.5 s = 66 150 frames at 44.1 kHz;
//  one pass of the loop = 48 bars = 3 175 200 frames (lab-nightshift.json). No timers decide WHEN a voice
//  sounds: a 50 ms poll only looks 0.35 s ahead and hands the player buffers stamped with their exact
//  sample time on that clock (VoiceTrack.pump) -- the timing is the audio clock's, it cannot drift.
//
//  THE VOICES: any "voice-*.wav" (or .aif/.caf/.m4a) in the app bundle -- the Hallways/Voices folder.
//  The file name is everything: "voice-<name>-<note>.wav" (voice-doo-A3.wav) says the recording is sung on
//  that note; "voice-<name>.wav" (voice-baby.wav): no stable pitch (spoken). Replace a file with your own
//  recording under the same name -- or add a new one -- and the lab offers it; no code change. See
//  Voices/ABOUT-VOICES.md.
//
//  PITCH: Hallways/MusicLab/voices-nightshift.json -- the chord of each of the loop's 48 bars and its
//  chord tones, taken from the composition's own source (original1.py: PROG_A / PROG_B / PROG_A and its
//  voicing table) and checked against the bass MIDI. Each voice event takes a chord tone of ITS bar --
//  root, third, fifth, third, in turn -- the one nearest the recording's own note (at most 6 semitones
//  down, 5 up). Shifted offline when a sample is chosen (VoiceRender): "keep length" (AVAudioUnitTimePitch)
//  or "tape" (AVAudioUnitVarispeed: higher is shorter, as a sped-up tape). A recording without a note is
//  treated as if sung on A3 (the song's tonic): its shifts move its inflection, they can't make it sing.
//
//  Every voice is trimmed to under one bar (min interval: two bars) -- events never overlap or pile up.
//

import AVFAudio
import Combine
import Foundation
import QuartzCore
import SwiftUI

// MARK: - The recordings (bundle files, by name)

nonisolated struct VoiceSample: Sendable, Identifiable, Equatable {
    /// The file name ("voice-doo-A3.wav").
    let id: String
    /// "doo"
    let name: String
    /// The note it was sung on (MIDI; C4 = 60), from the file name. Nil: spoken / no stable pitch.
    let note: Int?
    let url: URL

    static let extensions = ["wav", "aif", "aiff", "caf", "m4a"]

    /// "voice-doo-A3.wav" -> ("doo", 57); "voice-baby.wav" -> ("baby", nil); not "voice-*": nil.
    static func parse(_ fileName: String) -> (name: String, note: Int?)? {
        let ns = fileName as NSString
        guard extensions.contains(ns.pathExtension.lowercased()) else { return nil }
        let stem = ns.deletingPathExtension
        guard stem.hasPrefix("voice-") else { return nil }
        let rest = String(stem.dropFirst("voice-".count))
        guard !rest.isEmpty else { return nil }
        if let dash = rest.lastIndex(of: "-"), let n = midiNote(String(rest[rest.index(after: dash)...])) {
            let name = String(rest[..<dash])
            if !name.isEmpty { return (name, n) }
        }
        return (rest, nil)
    }

    /// "A3" -> 57, "C#4" / "Cs4" -> 61, "Bb2" -> 46 (C4 = 60). Nil: not a note name.
    static func midiNote(_ s: String) -> Int? {
        var chars = Array(s)
        let steps: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let first = chars.first, let base = steps[first] else { return nil }
        chars.removeFirst()
        var pc = base
        if let a = chars.first, a == "#" || a == "s" || a == "b" {
            pc += a == "b" ? -1 : 1
            chars.removeFirst()
        }
        guard !chars.isEmpty, let octave = Int(String(chars)), (0...8).contains(octave) else { return nil }
        return 12 * (octave + 1) + pc
    }

    static func noteName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        return names[((midi % 12) + 12) % 12] + "\(midi / 12 - 1)"
    }

    /// "doo · A3" / "baby · spoken"
    var label: String { "\(name) · " + (note.map(Self.noteName) ?? "spoken") }

    /// Every voice recording in the app bundle (top level, or a "Voices" folder), by file name.
    static func bundled() -> [VoiceSample] {
        var seen = Set<String>()
        var out: [VoiceSample] = []
        for sub in [nil, "Voices"] as [String?] {
            for ext in extensions {
                for url in Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: sub) ?? [] {
                    let file = url.lastPathComponent
                    guard let p = parse(file), seen.insert(file).inserted else { continue }
                    out.append(VoiceSample(id: file, name: p.name, note: p.note, url: url))
                }
            }
        }
        return out.sorted { $0.id < $1.id }
    }
}

// MARK: - The song's harmony (voices-nightshift.json)

nonisolated struct VoiceHarmony: Decodable, Sendable {
    nonisolated struct Bar: Decodable, Sendable, Equatable {
        let chord: String
        /// Pitch classes (C = 0), in order of preference: root, third, fifth, then the voicing's others.
        let tones: [Int]
    }
    let format: String
    let composition: String
    let beatsPerBar: Int
    let bars: [Bar]

    static func decode(_ data: Data) -> VoiceHarmony? {
        guard let h = try? JSONDecoder().decode(VoiceHarmony.self, from: data), h.format == "hallways-voice-harmony/1",
              !h.bars.isEmpty, h.bars.allSatisfy({ !$0.tones.isEmpty && $0.tones.allSatisfy { (0..<12).contains($0) } }) else {
            return nil
        }
        return h
    }

    static func bundled(_ file: String) -> VoiceHarmony? {
        guard let url = Bundle.main.url(forResource: file, withExtension: "json")
                ?? Bundle.main.url(forResource: file, withExtension: "json", subdirectory: "MusicLab"),
              let data = try? Data(contentsOf: url) else {
            diag("voiceLab.harmonyMissing", ["file": file])
            return nil
        }
        guard let h = decode(data) else {
            diag("voiceLab.harmonyUnreadable", ["file": file])
            return nil
        }
        return h
    }
}

// MARK: - When and on what note (pure: the tests' subject)

nonisolated enum VoicePlan {
    nonisolated struct Event: Sendable, Equatable {
        /// 0-based, in the loop.
        let bar: Int
        /// 0-based beat of the bar.
        let beat: Int
        /// Where it sounds in one pass of the loop (frames from the loop's first frame).
        let frame: Int64
        /// Semitones from the recording (0: as recorded).
        let shift: Int
        /// The note sung (nil: a spoken recording -- only its shift is known).
        let note: Int?
        let chord: String
    }

    /// Which chord tone each event takes, in turn: root, third, fifth, third.
    static let roles = [0, 1, 2, 1]
    /// The shift range (semitones): at most a tritone down, a fourth up.
    static let range = -6...5
    /// A recording without a note is placed as if on A3 -- the song's tonic.
    static let referenceNote = 57

    /// One event every `interval` bars (from bar 1), on `beat` (0-based), through one pass of the loop.
    static func events(bars: [VoiceHarmony.Bar], loopBars: Int, interval: Int, beat: Int, pitched: Bool,
                       source: Int?, barFrames: Int64, beatFrames: Int64) -> [Event] {
        guard interval > 0, loopBars > 0, barFrames > 0 else { return [] }
        let ref = source ?? referenceNote
        let usable = pitched && bars.count == loopBars
        var out: [Event] = []
        var i = 0
        for bar in stride(from: 0, to: loopBars, by: interval) {
            let chord = bar < bars.count ? bars[bar].chord : ""
            var shift = 0
            if usable { shift = target(tones: bars[bar].tones, role: roles[i % roles.count], source: ref) - ref }
            out.append(Event(bar: bar, beat: beat, frame: Int64(bar) * barFrames + Int64(beat) * beatFrames,
                             shift: shift, note: source.map { $0 + shift }, chord: chord))
            i += 1
        }
        return out
    }

    /// The note of pitch class tones[role] nearest `source`, within `range` of it.
    static func target(tones: [Int], role: Int, source: Int) -> Int {
        guard !tones.isEmpty else { return source }
        let pc = tones[min(max(0, role), tones.count - 1)]
        var up = ((pc - source) % 12 + 12) % 12
        if up > range.upperBound { up -= 12 }
        return source + up
    }
}

// MARK: - Preparing a recording (off the main thread; offline rendering only, nothing heard)

/// The prepared recording: one buffer per shift (semitones). Read-only once made.
nonisolated struct VoiceBuffers: @unchecked Sendable {
    let byShift: [Int: AVAudioPCMBuffer]
    static let empty = VoiceBuffers(byShift: [:])
}

nonisolated enum VoiceRender {
    enum Method: String, CaseIterable, Sendable {
        /// AVAudioUnitTimePitch: the same length at every pitch (a phase vocoder: a little smear).
        case keepLength
        /// AVAudioUnitVarispeed: like a tape played faster or slower -- higher is shorter (and brighter).
        case tape
    }

    /// The recording at `sampleRate`, mono 32-bit float (any channel count / rate / file type in).
    static func load(_ url: URL, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let inFormat = file.processingFormat
        guard let raw = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: raw) } catch { return nil }
        if inFormat == target { return raw }
        guard let conv = AVAudioConverter(from: inFormat, to: target) else { return nil }
        conv.downmix = true
        let capacity = AVAudioFrameCount(Double(raw.frameLength) * sampleRate / inFormat.sampleRate) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let feed = Feed(raw)
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, outStatus in
            guard let b = feed.take() else { outStatus.pointee = .endOfStream; return nil }
            outStatus.pointee = .haveData
            return b
        }
        guard status != .error, out.frameLength > 0 else {
            diag("voiceLab.convertFailed", ["file": url.lastPathComponent, "error": error.map { "\($0)" }])
            return nil
        }
        return out
    }

    /// (the converter's input, handed over once)
    private final class Feed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ b: AVAudioPCMBuffer) { buffer = b }
        func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
    }

    /// The recording ready to play: its leading silence trimmed (so it starts ON the beat), at every
    /// shift in `shifts`, each no longer than `maxSeconds` (a short fade at its end).
    static func prepare(_ url: URL, sampleRate: Double, method: Method, shifts: ClosedRange<Int>, maxSeconds: Double) -> [Int: AVAudioPCMBuffer] {
        guard let loaded = load(url, sampleRate: sampleRate) else { return [:] }
        let maxFrames = AVAudioFrameCount(max(0.05, maxSeconds) * sampleRate)
        // (trimmed before shifting too: the shifter sees only the sound itself)
        guard let source = finish(loaded, maxFrames: AVAudioFrameCount(4 * sampleRate)) else { return [:] }
        var out: [Int: AVAudioPCMBuffer] = [:]
        for s in shifts {
            let b = s == 0 ? source : shifted(source, semitones: s, method: method)
            // Trimmed again after shifting: the shifter's own latency is leading silence, removed the same way.
            if let b, let done = finish(b, maxFrames: maxFrames) { out[s] = done }
        }
        return out
    }

    /// `src` shifted by `semitones`, rendered offline (an engine in manual rendering mode: no audio
    /// hardware, nothing heard, finished before it returns).
    static func shifted(_ src: AVAudioPCMBuffer, semitones: Int, method: Method) -> AVAudioPCMBuffer? {
        let format = src.format
        let ratio = pow(2, Double(semitones) / 12)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let unit: AVAudioUnit
        switch method {
        case .keepLength:
            let tp = AVAudioUnitTimePitch()
            tp.pitch = Float(semitones * 100)                      // (cents)
            unit = tp
        case .tape:
            let v = AVAudioUnitVarispeed()
            v.rate = Float(ratio)
            unit = v
        }
        engine.attach(player)
        engine.attach(unit)
        engine.connect(player, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try engine.start()
        } catch {
            diag("voiceLab.renderFailed", ["error": "\(error)"])
            return nil
        }
        defer {
            player.stop()
            engine.stop()
        }
        player.scheduleBuffer(src, at: nil, options: [], completionHandler: nil)
        player.play()
        let length = method == .tape ? Double(src.frameLength) / ratio : Double(src.frameLength)
        let total = AVAudioFrameCount(length + 0.3 * format.sampleRate)          // (+ room for the latency)
        guard let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: total),
              let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096),
              let dst = out.floatChannelData?[0] else { return nil }
        while out.frameLength < total {
            let n = min(4096, total - out.frameLength)
            guard let status = try? engine.renderOffline(n, to: chunk), status == .success,
                  let s = chunk.floatChannelData?[0], chunk.frameLength > 0 else { break }
            let at = Int(out.frameLength), count = Int(chunk.frameLength)
            for i in 0..<count { dst[at + i] = s[i] }
            out.frameLength += chunk.frameLength
        }
        return out.frameLength > 0 ? out : nil
    }

    /// Leading silence (below 1% of the peak) off, at most `maxFrames` long, 1 ms in and 15 ms out.
    static func finish(_ b: AVAudioPCMBuffer, maxFrames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let x = b.floatChannelData?[0], b.frameLength > 0 else { return nil }
        let n = Int(b.frameLength)
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(x[i])) }
        guard peak > 0 else { return nil }
        let rate = b.format.sampleRate
        var start = 0
        while start < n, abs(x[start]) < peak * 0.01 { start += 1 }
        start = max(0, start - Int(0.002 * rate))
        var end = n
        while end > start, abs(x[end - 1]) < peak * 0.001 { end -= 1 }
        let count = min(end - start, Int(maxFrames))
        guard count > 0, let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: AVAudioFrameCount(count)),
              let y = out.floatChannelData?[0] else { return nil }
        for i in 0..<count { y[i] = x[start + i] }
        let fadeIn = min(count, Int(0.001 * rate)), fadeOut = min(count, Int(0.015 * rate))
        for i in 0..<fadeIn { y[i] *= Float(i) / Float(fadeIn) }
        for i in 0..<fadeOut { y[count - 1 - i] *= Float(i) / Float(fadeOut) }
        out.frameLength = AVAudioFrameCount(count)
        return out
    }
}

// MARK: - The voice on the song's clock (one per backing deck; its node lives on the deck's engine)

nonisolated final class VoiceTrack: @unchecked Sendable {
    let node = AVAudioPlayerNode()
    let format: AVAudioFormat
    let sampleRate: Double
    /// One pass of the loop (frames) -- the stems' own.
    let loopFrames: Int64

    private let lock = NSLock()
    private var events: [VoicePlan.Event] = []
    private var buffers = VoiceBuffers.empty
    private var on = false
    /// Everything before this frame (the player's timeline = the stems') has been considered.
    private var scheduledTo: Int64 = 0
    private var timer: DispatchSourceTimer?

    private static let queue = DispatchQueue(label: "hallways.voiceLab.schedule", qos: .userInitiated)
    /// Look this far ahead (s) every `poll` (s); never schedule closer than `lead` (s) to now.
    static let horizon = 0.35, poll = 0.05, lead = 0.03

    init?(sampleRate: Double, loopFrames: Int64) {
        guard loopFrames > 0, let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        format = f
        self.sampleRate = sampleRate
        self.loopFrames = loopFrames
    }

    deinit { timer?.cancel() }

    func set(events e: [VoicePlan.Event]) { lock.withLock { events = e } }
    func set(buffers b: VoiceBuffers) { lock.withLock { buffers = b } }
    func set(on o: Bool) { lock.withLock { on = o } }

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

    /// The events due in the next `horizon`, each scheduled at its exact frame on the player's timeline.
    private func pump() {
        guard let render = node.lastRenderTime, render.isSampleTimeValid,
              let now = node.playerTime(forNodeTime: render) else { return }      // (not started yet / stopped)
        lock.lock()
        let from = max(scheduledTo, now.sampleTime + Int64(Self.lead * sampleRate))
        let to = now.sampleTime + Int64(Self.horizon * sampleRate)
        guard to > from else { lock.unlock(); return }
        scheduledTo = to                                                // (off: the window passes unused)
        let due = on ? events : []
        let bufs = buffers.byShift
        lock.unlock()
        guard !due.isEmpty else { return }
        for at in Self.frames(of: due, loopFrames: loopFrames, from: from, to: to) {
            guard let b = bufs[at.shift] ?? bufs[0] else { continue }
            node.scheduleBuffer(b, at: AVAudioTime(sampleTime: at.frame, atRate: sampleRate), options: [], completionHandler: nil)
        }
    }

    /// The events falling in [from, to) of the endless loop: (absolute frame, shift), in time order.
    static func frames(of events: [VoicePlan.Event], loopFrames: Int64, from: Int64, to: Int64) -> [(frame: Int64, shift: Int)] {
        guard loopFrames > 0, to > from else { return [] }
        var out: [(frame: Int64, shift: Int)] = []
        var pass = max(0, from / loopFrames)
        while pass * loopFrames < to {
            for e in events {
                let at = pass * loopFrames + e.frame
                if at >= from && at < to { out.append((at, e.shift)) }
            }
            pass += 1
        }
        return out.sorted { $0.frame < $1.frame }
    }
}

// MARK: - The lab (main actor: choices, the backing through StemLab, the readout)

@MainActor
final class VoiceLab: ObservableObject {
    static let shared = VoiceLab()

    /// The song under test (lab-nightshift.json's id) and its harmony file.
    static let compositionID = "night-shift-waltz"
    static let harmonyFile = "voices-nightshift"
    static let intervals = [2, 4, 8]
    private static let sampleKey = "voiceLab.sample"

    let samples: [VoiceSample]
    let harmony: VoiceHarmony?

    @Published private(set) var sampleID: String?
    /// Off at first: the first thing heard is the waltz as it is.
    @Published private(set) var voiceOn = false
    @Published private(set) var volume: Double = 0.7
    @Published private(set) var pitched = false
    @Published private(set) var method: VoiceRender.Method = .keepLength
    @Published private(set) var interval = 4
    /// 0-based (beat 1 = the downbeat).
    @Published private(set) var beat = 0
    @Published private(set) var preparing = false
    /// The chosen recording couldn't be read.
    @Published private(set) var unreadable = false
    /// The backing is playing with the voice track attached.
    @Published private(set) var playing = false
    /// "Bar 12 of 48 · Cmaj7"
    @Published private(set) var status = ""
    /// "Next: bar 13, beat 1 · Bm7b5 · B3 (+2)"
    @Published private(set) var next = ""

    private var buffers = VoiceBuffers.empty
    private var prepareToken = 0
    private var track: VoiceTrack?
    private var trackDeck: ObjectIdentifier?
    private var clock: Timer?
    /// TRACKS' own selection, given back when leaving VOICES.
    private var previousSelection: String?
    private var preview: (engine: AVAudioEngine, node: AVAudioPlayerNode)?
    private var previewToken = 0

    private static let renderQueue = DispatchQueue(label: "hallways.voiceLab.render", qos: .userInitiated)

    private init() {
        samples = VoiceSample.bundled()
        harmony = VoiceHarmony.bundled(Self.harmonyFile)
        let remembered = UserDefaults.standard.string(forKey: Self.sampleKey)
        sampleID = (samples.first { $0.id == remembered } ?? samples.first { $0.note != nil } ?? samples.first)?.id
        diag("voiceLab.catalog", ["samples": samples.map(\.id).joined(separator: ","),
                                  "harmonyBars": harmony?.bars.count ?? 0, "selected": sampleID ?? "-"])
    }

    var composition: StemComposition? { StemLab.shared.catalog.first { $0.id == Self.compositionID } }
    var sample: VoiceSample? { samples.first { $0.id == sampleID } }
    var isAvailable: Bool { composition != nil && StemLab.shared.isAvailable }
    /// A voice is ready to sound.
    var hasVoice: Bool { !buffers.byShift.isEmpty }
    var canPitch: Bool { harmony?.bars.count == composition?.loopBars }

    private static var silenced: Bool {
        HallwaysAudio.shared.isMuted || HallwaysAudio.shared.isSuppressed(otherThan: HallwaysAudio.musicLabFocus)
    }

    // MARK: Controls

    /// The complete original backing (all four stems), with the voice track riding on its clock.
    func play() {
        guard let c = composition, isAvailable else { return }
        let stems = StemLab.shared
        if stems.selectedID != c.id {
            if previousSelection == nil { previousSelection = stems.selectedID }
            stems.select(c.id)
        }
        stems.deckWillStart = { [weak self] deck, piece in self?.attach(deck, piece) }
        if sampleID != nil, buffers.byShift.isEmpty, !preparing { prepare() }
        if stems.state == .looping, playing { return }
        if stems.state != .stopped { stems.stop() }           // (another start: no voice on it -- restarted)
        stems.playAll()
        diag("voiceLab.play", settingsLog)
    }

    func stop() {
        StemLab.shared.stop()
        diag("voiceLab.stop", [:])
    }

    func selectSample(_ id: String) {
        guard id != sampleID, samples.contains(where: { $0.id == id }) else { return }
        sampleID = id
        UserDefaults.standard.set(id, forKey: Self.sampleKey)
        buffers = .empty
        track?.set(buffers: .empty)
        prepare()
        pushPlan()
        diag("voiceLab.sample", ["sample": id])
    }

    func setVoice(_ on: Bool) {
        voiceOn = on
        applyVoice()
        diag("voiceLab.voice", ["on": on, "bar": status])
    }

    func setVolume(_ v: Double) {
        volume = min(1, max(0, v))
        applyVoice()
    }

    func setPitched(_ on: Bool) {
        pitched = on && canPitch
        pushPlan()
        diag("voiceLab.pitched", ["on": pitched])
    }

    func setMethod(_ m: VoiceRender.Method) {
        guard m != method else { return }
        method = m
        prepare()
        diag("voiceLab.method", ["method": m.rawValue])
    }

    func setInterval(_ bars: Int) {
        guard Self.intervals.contains(bars) else { return }
        interval = bars
        pushPlan()
        diag("voiceLab.interval", ["bars": bars])
    }

    func setBeat(_ b: Int) {
        guard let c = composition, (0..<c.beatsPerBar).contains(b) else { return }
        beat = b
        pushPlan()
        diag("voiceLab.beat", ["beat": b + 1])
    }

    /// The recording alone, as recorded (a small engine of its own, released a moment after).
    func audition() {
        guard let b = buffers.byShift[0], !Self.silenced, !AudioDiagnostics.audioOff else { return }
        SoundEffects.configureAudioSession(reason: "voiceLab")
        if preview == nil {
            let e = AVAudioEngine(), n = AVAudioPlayerNode()
            e.attach(n)
            e.connect(n, to: e.mainMixerNode, format: b.format)
            do { try e.start() } catch {
                diag("voiceLab.auditionFailed", ["error": "\(error)"])
                return
            }
            preview = (e, n)
        }
        guard let p = preview else { return }
        p.node.stop()
        p.node.volume = Float(max(volume, 0.2) * max(volume, 0.2))
        p.node.scheduleBuffer(b, at: nil, options: [], completionHandler: nil)
        p.node.play()
        previewToken += 1
        let token = previewToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(b.frameLength) / b.format.sampleRate + 0.6) { [weak self] in
            guard let self, self.previewToken == token else { return }
            self.stopPreview()
        }
    }

    /// The Music Lab switched to another mode: stopped, TRACKS given back its own selection.
    func leave() {
        StemLab.shared.deckWillStart = nil
        detach()
        stopPreview()
        if let p = previousSelection {
            previousSelection = nil
            StemLab.shared.select(p)
        }
    }

    func directoryClosed() { leave() }

    // MARK: The voice track

    /// StemLab is starting a deck: if it's the waltz, the voice rides on it.
    private func attach(_ deck: StemDeck, _ piece: StemComposition) {
        guard piece.id == Self.compositionID else { return }
        track?.stop()
        guard let t = VoiceTrack(sampleRate: deck.sampleRate, loopFrames: Int64(deck.frames)) else { return }
        deck.addCompanion(t.node, format: t.format)
        track = t
        trackDeck = ObjectIdentifier(deck)
        playing = true
        pushPlan()
        t.set(buffers: buffers)
        applyVoice()
        t.start()
        startClock()
        diag("voiceLab.attached", ["loopFrames": deck.frames, "rate": deck.sampleRate])
    }

    private func detach() {
        track?.stop()
        track = nil
        trackDeck = nil
        clock?.invalidate()
        clock = nil
        playing = false
        status = ""
        next = ""
    }

    private func applyVoice() {
        track?.node.volume = voiceOn ? Float(volume * volume) : 0
        track?.set(on: voiceOn && hasVoice)
    }

    private var plan: [VoicePlan.Event] {
        guard let c = composition else { return [] }
        return VoicePlan.events(bars: harmony?.bars ?? [], loopBars: c.loopBars, interval: interval, beat: beat,
                                pitched: pitched, source: sample?.note,
                                barFrames: Int64((c.barSeconds * c.sampleRate).rounded()),
                                beatFrames: Int64((60 / c.bpm * c.sampleRate).rounded()))
    }

    private func pushPlan() {
        track?.set(events: plan)
        refresh()
    }

    private func prepare() {
        guard let s = sample, let c = composition else { return }
        prepareToken += 1
        let token = prepareToken
        preparing = true
        unreadable = false
        let url = s.url, rate = c.sampleRate, m = method
        let maxSeconds = c.barSeconds - 0.05                         // (under one bar; the closest interval is two)
        Self.renderQueue.async {
            let made = VoiceBuffers(byShift: VoiceRender.prepare(url, sampleRate: rate, method: m,
                                                                 shifts: VoicePlan.range, maxSeconds: maxSeconds))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { VoiceLab.shared.prepared(made, token: token) }
            }
        }
    }

    private func prepared(_ b: VoiceBuffers, token: Int) {
        guard token == prepareToken else { return }
        preparing = false
        buffers = b
        unreadable = b.byShift[0] == nil
        track?.set(buffers: b)
        applyVoice()
        let length = b.byShift[0].map { Double($0.frameLength) / $0.format.sampleRate } ?? 0
        diag(unreadable ? "voiceLab.sampleUnreadable" : "voiceLab.prepared",
             ["sample": sampleID ?? "-", "shifts": b.byShift.count, "seconds": length, "method": method.rawValue])
    }

    private func stopPreview() {
        previewToken += 1
        preview?.node.stop()
        preview?.engine.stop()
        preview = nil
    }

    // MARK: Where the music is (4 a second, while playing)

    private func startClock() {
        clock?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { VoiceLab.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        clock = t                                              // (first tick in 0.25 s: StemLab is looping by then)
    }

    /// The clock's tick: the deck went (STOP, another piece, an interruption) -- the voice goes with it.
    private func tick() {
        guard playing else { return }
        let stems = StemLab.shared
        guard let deck = stems.currentDeck, ObjectIdentifier(deck) == trackDeck, stems.state == .looping else {
            detach()
            return
        }
        refresh()
    }

    /// The readout: where the music is, and the next voice.
    private func refresh() {
        guard playing, let deck = StemLab.shared.currentDeck, ObjectIdentifier(deck) == trackDeck, let c = composition,
              let played = deck.playedSeconds else { return }
        let loopSeconds = Double(deck.frames) / deck.sampleRate
        let inLoop = max(0, played.truncatingRemainder(dividingBy: loopSeconds))
        let bar = min(c.loopBars - 1, Int(inLoop / c.barSeconds))
        let chord = harmony.flatMap { bar < $0.bars.count ? $0.bars[bar].chord : nil }
        status = "Bar \(bar + 1) of \(c.loopBars)" + (chord.map { " · \($0)" } ?? "")
        guard voiceOn, hasVoice else {
            next = voiceOn ? (preparing ? "Preparing the voice…" : "No voice to play") : "Voice off -- the waltz as it is"
            return
        }
        let frame = Int64(inLoop * deck.sampleRate)
        let events = plan
        guard let e = events.first(where: { $0.frame > frame }) ?? events.first else { next = ""; return }
        var text = "Next: bar \(e.bar + 1), beat \(e.beat + 1)"
        if !e.chord.isEmpty { text += " · \(e.chord)" }
        if pitched {
            if let n = e.note { text += " · \(VoiceSample.noteName(n))" }
            text += e.shift == 0 ? " (as recorded)" : " (\(e.shift > 0 ? "+" : "")\(e.shift))"
        }
        next = text
    }

    private var settingsLog: KeyValuePairs<String, Any?> {
        ["sample": sampleID, "voice": voiceOn, "volume": volume, "pitched": pitched, "method": method.rawValue,
         "interval": interval, "beat": beat + 1]
    }
}

// MARK: - The Directory's VOICES mode
//
// VoiceLabControls is fixed at the top (like TRACKS'): the song, where it is, PLAY / STOP. VoiceLabPanel
// heads the scrolling list: the recording, AUDITION, VOICE on/off, volume, pitch, interval, beat.

struct VoiceLabControls: View {
    @ObservedObject private var lab = VoiceLab.shared
    @ObservedObject private var stems = StemLab.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("VOICES · MUSIC LAB")
                    .font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                Spacer(minLength: 8)
                Text(lab.playing ? (lab.status.isEmpty ? "Playing" : lab.status) : (stems.state == .stopped ? "Stopped" : "…"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(PhoneStyle.inkSoft)
                    .lineLimit(1)
            }
            if let c = lab.composition {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.system(size: 15, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                    Text("The original recording · all \(c.parts.count) musicians · 3/4, \(Int(c.bpm)) bpm")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.75).opacity(0.8)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PhoneStyle.ink))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSelected)
                HStack(spacing: 8) {
                    VoiceLabButton(title: "PLAY", symbol: "play.fill", filled: true) { lab.play() }
                        .disabled(!lab.isAvailable || lab.playing)
                        .opacity(lab.playing ? 0.45 : 1)
                    VoiceLabButton(title: "STOP", symbol: "stop.fill", filled: false) { lab.stop() }
                        .disabled(stems.state == .stopped)
                        .opacity(stems.state == .stopped ? 0.45 : 1)
                }
                if !lab.isAvailable {
                    Text("Audio is off (Settings › Diagnostics).")
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                }
            } else {
                Text("The Night Shift Waltz isn't in this build (lab-nightshift.json and its stems).")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PhoneStyle.rule, lineWidth: 1))
        .padding(.horizontal, 14)
    }
}

struct VoiceLabPanel: View {
    @ObservedObject private var lab = VoiceLab.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if lab.samples.isEmpty {
                noRecordings
            } else {
                recordings
                HStack(spacing: 8) {
                    VoiceLabButton(title: "AUDITION", symbol: "speaker.wave.2.fill", filled: false) { lab.audition() }
                        .disabled(!lab.hasVoice)
                        .opacity(lab.hasVoice ? 1 : 0.45)
                    VoiceLabButton(title: lab.voiceOn ? "VOICE ON" : "VOICE OFF", symbol: lab.voiceOn ? "waveform" : "waveform.slash",
                                   filled: lab.voiceOn) { lab.setVoice(!lab.voiceOn) }
                        .disabled(!lab.hasVoice)
                        .opacity(lab.hasVoice ? 1 : 0.45)
                }
                if lab.unreadable {
                    note("This recording couldn't be read. Try a 16-bit or 24-bit WAV.")
                }
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(PhoneStyle.inkSoft)
                    Slider(value: Binding(get: { lab.volume }, set: { lab.setVolume($0) }), in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(PhoneStyle.inkSoft)
                }
                .disabled(!lab.hasVoice)
                row("EVERY") {
                    Picker("Interval", selection: Binding(get: { lab.interval }, set: { lab.setInterval($0) })) {
                        ForEach(VoiceLab.intervals, id: \.self) { Text("\($0) bars").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                row("ON") {
                    Picker("Beat", selection: Binding(get: { lab.beat }, set: { lab.setBeat($0) })) {
                        ForEach(0..<(lab.composition?.beatsPerBar ?? 3), id: \.self) { Text("Beat \($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Toggle(isOn: Binding(get: { lab.pitched }, set: { lab.setPitched($0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sing the chords").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(PhoneStyle.ink)
                        Text(lab.canPitch ? "Each voice on a note of its bar's chord" : "No harmony data for this song")
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                    }
                }
                .disabled(!lab.canPitch)
                if lab.pitched {
                    row("SHIFT") {
                        Picker("Pitch shift", selection: Binding(get: { lab.method }, set: { lab.setMethod($0) })) {
                            Text("Keep length").tag(VoiceRender.Method.keepLength)
                            Text("Tape speed").tag(VoiceRender.Method.tape)
                        }
                        .pickerStyle(.segmented)
                    }
                    if lab.sample?.note == nil {
                        note("This recording has no note in its name (spoken): it's shifted as if it were an A3 -- its inflection moves, it won't sing in tune.")
                    }
                }
                if !lab.next.isEmpty { note(lab.next) }
                note("Recordings: Hallways/Voices/voice-<name>-<note>.wav (e.g. voice-doo-A3.wav), or voice-<name>.wav if spoken. Replace one with your own under the same name.")
            }
        }
        .padding(.horizontal, 14)
    }

    private var recordings: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(lab.samples) { s in
                    let selected = s.id == lab.sampleID
                    Button { lab.selectSample(s.id) } label: {
                        HStack(spacing: 6) {
                            if selected && lab.preparing { ProgressView().controlSize(.mini) }
                            Text(s.label).font(.system(size: 14, weight: .heavy, design: .rounded)).lineLimit(1)
                        }
                        .foregroundStyle(selected ? .white : PhoneStyle.ink)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background(Capsule().fill(selected ? PhoneStyle.ink : Color.white.opacity(0.7)))
                        .overlay(Capsule().stroke(selected ? PhoneStyle.ink : PhoneStyle.rule, lineWidth: 1.5))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var noRecordings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No voice recordings in this build").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(PhoneStyle.ink)
            note("PLAY still plays the complete waltz. To add a voice: export a short mono WAV from Audacity (44.1 kHz, 16-bit, under one second), name it voice-<name>-<note>.wav -- e.g. voice-doo-A3.wav for a \"doo\" sung on A3, or voice-baby.wav if it's spoken -- put it in the project's Hallways/Voices folder, and build again.")
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                .frame(width: 44, alignment: .leading)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The lab's large button (the TRACKS lab's look).
struct VoiceLabButton: View {
    let title: String
    let symbol: String
    let filled: Bool
    let run: () -> Void

    var body: some View {
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
    }
}
