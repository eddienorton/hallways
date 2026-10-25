//
//  MusicLab.swift
//  Hallways
//
//  Oct 24 (instrument-independent compositions) -- THE MUSIC LAB. Claudette composes the music ahead of
//  time; Hallways arranges and performs it with whichever Hallwaysians the player switches on.
//
//  The composition owns the music and an ORDERED STACK OF LAYERS; the player owns the instruments:
//    COMPOSITIONS  bundled templates (comp-<id>.json, "hallways-composition/1"): tempo, meter, key, chords,
//                  sections, musical PARTS -- notes (beat, length, pitch, velocity, articulation) or, for a
//                  groove, rhythmic hits -- and "layers", the order parts are handed out (Night Porter:
//                  bass line, groove, chords, held chords, melody, answers, harmony, low harmony). When a
//                  layer plays is only its notes' own timing; its place in the stack never moves it.
//                  A template names no instrument and no resident. MusicLabCatalog lists them by genre.
//    THE ARRANGEMENT  (MusicLab, below) by ACTIVATION ORDER: the next musician switched on takes the lowest
//                  vacant layer, whatever its instrument, and keeps it until switched off (or CLEAR, or another
//                  composition chosen). Switching one off frees its layer; nobody else moves. Once every layer
//                  is taken, musicians switched on wait, and the first waiting takes the next layer freed.
//    PERFORMANCE   lab-arranger.js (bundled; JavaScriptCore on this device, no network, no AI) decides only
//                  HOW an instrument plays the layer it was handed: octave fitting, the chord notes it can
//                  sound, legato / swells / rolls / ringing; a drum on a pitched layer plays its rhythm, a
//                  pitched instrument on the groove plays its kick and snare on chord roots -- each shown
//                  in the musician's row. BandEngine: one AVAudioUnitSampler per playing musician, loaded with
//                  its instrument's SoundFont (band-<instrument>.sf2), fed note events on the shared clock.
//                  Singers: AVAudioPlayerNode playing a layer's prerendered Hallenese
//                  (band-voice-<voice>-<composition>-<part>.caf: ALAC, sample-exact, one loop long), bar by
//                  bar on the same clock -- only for layers prerendered for that voice; otherwise "can't be sung yet".
//
//  TIME: one clock. The performance starts at a host time; bar n begins n * beatsPerBar beats later and
//  plays the template's bar n (Oct 25: the four compositions are whole pieces, "loop": false -- after the last
//  bar and a 2 s ring-out the piece has finished and the lab returns to ready; a looping template would play
//  bar n mod its length). The arranger is asked for a bar
//  ~1.5 s before it starts; its notes wait in `pending` and go to their sampler ~60 ms ahead, stamped with
//  the sample time they must sound at. A singer's bars are queued back to back on its player.
//
//  JOINING / LEAVING: switched ON, a musician plays its layer from the next bar planned (its sampler
//  loads meanwhile), at that bar's place in the composition -- notes already sounding are not caught
//  mid-way; switched OFF, its waiting notes are dropped, its sounding notes released (the instrument's own
//  release), a singer faded out. Nobody else changes. The music never restarts. PLAY starts at bar 1.
//
//  AUDITION (Oct 25): the speaker beside each instrumental resident plays its instrument alone -- a 3-5 s
//  signature phrase (band-auditions.json, note data) in the instrument's natural register, on its own
//  sampler with the same SoundFont, into its own mixer. It switches nobody on and touches no layer; a playing
//  band carries on, ducked, and comes back up. (A composition may move an instrument out of its natural
//  register -- the audition shows what the instrument itself sounds like.)
//
//  AUDIO FOCUS (kept): while the Directory is open the lab has the focus -- every other Hallways sound is
//  silenced (HallwaysAudio's "musicLab" suppression), playing or not; closed, the band stops and everything
//  is restored. Mute silences the band. While it plays (`isActive`) the residents' own music stays quiet.
//
//  (The five Level-3 songs' stems are no longer played. Their sources -- the Python scores and MIDI in
//  Music/HallwaysOriginals -- are kept as composition material; Night Porter is the first converted.)
//

import AudioToolbox
import AVFAudio
import Combine
import Foundation
import JavaScriptCore
import QuartzCore
import SwiftUI

// MARK: - The roster: every resident's permanent instrument

nonisolated enum BandInstruments {
    /// Instrument id -> what the lab calls it.
    static let labels: [String: String] = [
        "drums": "Drums", "percussion": "Congas & percussion", "upright_bass": "Upright bass", "electric_bass": "Electric bass",
        "tuba": "Tuba", "piano": "Piano", "electric_piano": "Electric piano", "organ": "Organ", "nylon_guitar": "Nylon guitar",
        "electric_guitar": "Electric guitar", "marimba": "Marimba", "vibraphone": "Vibraphone", "glockenspiel": "Glockenspiel",
        "harp": "Harp", "violin": "Violin", "cello": "Cello", "flute": "Flute", "clarinet": "Clarinet", "french_horn": "French horn",
        "trumpet": "Trumpet", "trombone": "Trombone", "tenor_sax": "Tenor sax", "harmonica": "Harmonica",
        "soprano": "Soprano voice", "alto": "Alto voice", "tenor": "Tenor voice", "bass_voice": "Bass voice",
    ]
    /// Singers (their sound is prerendered parts, not a SoundFont) -> the voice's file name.
    static let voices: [String: String] = ["soprano": "soprano", "alto": "alto", "tenor": "tenor", "bass_voice": "bass"]
    /// Resident id -> instrument (proposed Oct 24; one each, following their greeting signatures where they have one).
    static let byResident: [String: String] = [
        "jeff": "drums", "hw.clunk": "percussion", "chair.1": "upright_bass", "hw.scope": "electric_bass", "hw.bigfellow": "tuba",
        "hw.feddy": "piano", "hw.mitts": "electric_piano", "cast.stove": "organ", "hw.lanky": "nylon_guitar",
        "hw.lopsy": "electric_guitar", "hw.sister": "marimba", "cast.camera": "vibraphone", "hw.tiny": "glockenspiel",
        "hw.auntie": "harp", "hw.stilts": "violin", "hw.oldgent": "cello", "butterfly": "flute", "pottle.1": "clarinet",
        "hw.owl": "french_horn", "hw.topper": "trumpet", "cast.mailbox": "trombone", "cast.telephone": "tenor_sax",
        "cast.viewmaster": "harmonica", "juanita": "soprano", "hw.pear": "alto", "cast.television": "tenor", "hw.barrel": "bass_voice",
    ]
    /// The list's order: rhythm, keys, guitars, mallets, strings, winds, brass, voices.
    static let order: [String] = ["drums", "percussion", "upright_bass", "electric_bass", "tuba", "piano", "electric_piano", "organ",
                                  "nylon_guitar", "electric_guitar", "marimba", "vibraphone", "glockenspiel", "harp", "violin", "cello",
                                  "flute", "clarinet", "harmonica", "tenor_sax", "french_horn", "trumpet", "trombone",
                                  "soprano", "alto", "tenor", "bass_voice"]
    /// Where each sits left-right (-1...1).
    static func pan(_ instrument: String) -> Float {
        let table: [String: Float] = ["drums": 0, "percussion": 0.45, "upright_bass": 0, "electric_bass": 0, "tuba": -0.1, "piano": -0.3,
                                      "electric_piano": -0.35, "organ": -0.25, "nylon_guitar": 0.35, "electric_guitar": 0.4, "marimba": 0.3,
                                      "vibraphone": 0.3, "glockenspiel": 0.5, "harp": -0.45, "violin": -0.2, "cello": 0.25, "flute": 0.2,
                                      "clarinet": -0.15, "harmonica": 0.1, "tenor_sax": 0.15, "french_horn": -0.35, "trumpet": 0.2,
                                      "trombone": -0.2, "soprano": 0.05, "alto": -0.05, "tenor": 0.05, "bass_voice": -0.05]
        return table[instrument] ?? 0
    }
}

struct BandMember: Identifiable {
    let id: String
    let name: String
    let instrument: String
    let label: String
    let tint: Color
}

nonisolated enum BandAssets {
    /// A bundled file (flat, or in a "MusicLab" folder).
    static func url(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "MusicLab")
    }
}

// MARK: - The compositions

enum LabGenre: String, CaseIterable, Identifiable {
    case blues, jazz, rock, classical
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct LabComposition: Identifiable, Equatable {
    let id: String
    let genre: LabGenre
    let title: String
    let blurb: String
    /// The template's bundled file (comp-<id>.json).
    var file: String { "comp-\(id)" }
}

enum MusicLabCatalog {
    /// Every composition written so far. Stage A (Oct 25): one per genre -- Night Porter and Rua das Lâmpadas
    /// converted from the Hallways Originals, Rock Shuffle and Minuet new. Oct 25 (later): four more, new --
    /// Midnight Express (swing), The Velvet Hour (bossa nova), Clockwork (funk, under Rock), After Hours (waltz,
    /// under Classical). Each blurb names its style first. (Which floor plays which: FloorMusic.swift.)
    static let all: [LabComposition] = [
        LabComposition(id: "night-porter", genre: .blues, title: "Night Porter",
                       blurb: "Soul-jazz blues in G · about 2:50 · 8 layers"),
        LabComposition(id: "bossa-nova", genre: .jazz, title: "Rua das Lâmpadas",
                       blurb: "Bossa nova in D · about 2:20 · 7 layers"),
        LabComposition(id: "rock-shuffle", genre: .rock, title: "Rock Shuffle",
                       blurb: "Boogie shuffle in A · about 2:10 · 6 layers"),
        LabComposition(id: "minuet", genre: .classical, title: "Minuet and Trio",
                       blurb: "A courtly dance in G, 3/4 · about 2:25 · 5 layers"),
        LabComposition(id: "midnight-express", genre: .jazz, title: "Midnight Express",
                       blurb: "Swing in B♭, up-tempo · about 2:30 · 7 layers"),
        LabComposition(id: "velvet-hour", genre: .jazz, title: "The Velvet Hour",
                       blurb: "Bossa nova in F · about 2:50 · 6 layers"),
        LabComposition(id: "clockwork", genre: .rock, title: "Clockwork",
                       blurb: "Funk in E · about 2:25 · 8 layers"),
        LabComposition(id: "after-hours", genre: .classical, title: "After Hours",
                       blurb: "Waltz in D minor, 3/4 · about 2:20 · 7 layers"),
    ]
    /// The composition's layer stack, in order (names from its template's "layers").
    static func layers(_ c: LabComposition) -> [String] {
        guard let u = BandAssets.url(c.file, "json"), let data = try? Data(contentsOf: u),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["layers"] as? [[String: Any]] else { return [] }
        return list.map { ($0["name"] as? String) ?? "?" }
    }

    static func compositions(_ g: LabGenre) -> [LabComposition] {
        all.filter { $0.genre == g && BandAssets.url($0.file, "json") != nil }
    }
}

/// A musician switched on, with the layer of the composition's stack it holds (nil: waiting -- every layer is taken).
nonisolated struct LabSeat: Sendable {
    let who: String
    let instrument: String
    let layer: Int?
}

/// An instrument's audition: a short signature phrase in its natural register (band-auditions.json:
/// {instrument: {bpm, notes: [[beat, beats, midi, velocity]], seconds}}). Note data, not audio; written to be
/// reusable later as the residents' own signatures.
nonisolated struct LabPhrase: Sendable {
    struct Note: Sendable { let t: Double; let dur: Double; let pitch: Int; let vel: Int }
    let bpm: Double
    let notes: [Note]
    let seconds: Double

    static func load() -> [String: LabPhrase] {
        guard let u = BandAssets.url("band-auditions", "json"), let data = try? Data(contentsOf: u),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        var out: [String: LabPhrase] = [:]
        for (inst, p) in obj {
            guard let bpm = (p["bpm"] as? NSNumber)?.doubleValue, let list = p["notes"] as? [[NSNumber]] else { continue }
            let notes = list.compactMap { a -> Note? in
                a.count >= 4 ? Note(t: a[0].doubleValue, dur: a[1].doubleValue, pitch: a[2].intValue, vel: a[3].intValue) : nil
            }
            out[inst] = LabPhrase(bpm: bpm, notes: notes, seconds: (p["seconds"] as? NSNumber)?.doubleValue ?? 5)
        }
        return out
    }
}

// MARK: - The performer (lab-arranger.js, in JavaScriptCore; used only on the engine's queue)

nonisolated struct BandEvent: Decodable, Sendable {
    let who: String
    let type: String
    let t: Double
    let dur: Double?
    let pitch: Int?
    let vel: Int?
    let cc: Int?
    let value: Int?
    let part: String?
    let loopBar: Int?
}

nonisolated struct BandBar: Decodable, Sendable {
    let bar: Int
    let loopBar: Int
    let section: String
    let chord: String
    let roles: [String: String]
    let levels: [String: Double]
    let events: [BandEvent]
}

nonisolated final class BandArranger {
    private let context: JSContext
    let compositionID: String
    let bpm: Double
    let beatsPerBar: Int
    let bars: Int
    /// A loop plays forever; a whole piece (the template's "loop": false) plays once and ends.
    let loops: Bool

    init?(composition: String) {
        guard let ctx = JSContext(), let js = BandAssets.url("lab-arranger", "js"),
              let src = try? String(contentsOf: js, encoding: .utf8),
              let tu = BandAssets.url("comp-\(composition)", "json"), let template = try? String(contentsOf: tu, encoding: .utf8) else {
            diag("band.arrangerMissing", ["composition": composition])
            return nil
        }
        ctx.exceptionHandler = { _, ex in diag("band.jsError", ["error": ex?.toString() ?? "?"]) }
        ctx.evaluateScript(src)
        let instruments = BandAssets.url("band-instruments", "json").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "{}"
        var voices = "{}"
        if let u = BandAssets.url("band-voices", "json"), let data = try? Data(contentsOf: u),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let parts = obj["parts"],
           let pd = try? JSONSerialization.data(withJSONObject: parts), let s = String(data: pd, encoding: .utf8) {
            voices = s
        }
        ctx.evaluateScript("Lab.configure({ instruments: \(instruments), voices: \(voices) })")
        let info = ctx.evaluateScript("JSON.stringify(Lab.load(\(template)))")?.toString() ?? "{}"
        let obj = (try? JSONSerialization.jsonObject(with: Data(info.utf8))) as? [String: Any]
        guard let b = obj?["bpm"] as? Double, let bars = obj?["bars"] as? Int, bars > 0 else {
            diag("band.templateUnreadable", ["composition": composition, "info": info])
            return nil
        }
        compositionID = composition
        bpm = b
        beatsPerBar = (obj?["beatsPerBar"] as? Int) ?? 4
        self.bars = bars
        loops = (obj?["loop"] as? Bool) ?? true
        context = ctx
    }

    func setLineup(_ lineup: [LabSeat]) {
        let list: [[String: Any]] = lineup.map { ["who": $0.who, "instrument": $0.instrument, "layer": $0.layer.map { $0 as Any } ?? NSNull()] }
        guard let data = try? JSONSerialization.data(withJSONObject: list), let json = String(data: data, encoding: .utf8) else { return }
        context.evaluateScript("Lab.setLineup(\(json))")
    }

    /// Oct 25 (the walking band): a whole piece plays round and round (its last bar, then its first).
    func setRepeat(_ on: Bool) {
        context.evaluateScript("Lab.setRepeat(\(on ? "true" : "false"))")
    }

    func plan(bar: Int) -> BandBar? {
        guard let s = context.evaluateScript("JSON.stringify(Lab.planBar(\(bar)))")?.toString() else { return nil }
        do {
            return try JSONDecoder().decode(BandBar.self, from: Data(s.utf8))
        } catch {
            diag("band.planUnreadable", ["bar": bar, "error": "\(error)"])
            return nil
        }
    }
}

// MARK: - The engine (performance; its own serial queue)

nonisolated final class BandEngine: @unchecked Sendable {
    /// What the UI shows (read under the lock).
    struct Snapshot {
        var playing = false
        var bar = 0
        var loopBar = 0
        var bars = 0
        var section = ""
        var chord = ""
        var roles: [String: String] = [:]
        /// A whole piece (not a loop) has played to its end.
        var finished = false
    }

    private let queue = DispatchQueue(label: "hallways.band.engine", qos: .userInteractive)
    private let loadQueue = DispatchQueue(label: "hallways.band.load", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let bandMix = AVAudioMixerNode()
    private let reverb = AVAudioUnitReverb()
    private let limiter: AVAudioUnitEffect
    private var arranger: BandArranger?
    private var graphReady = false

    private final class Unit {
        let who: String
        let instrument: String
        /// The instrument's level, evened out (dB; a sampler's masterGain, a singer's volume).
        var trim: Float = 0
        var sampler: AVAudioUnitSampler?
        var player: AVAudioPlayerNode?
        var ready = false
        /// The engine run (see `engineRun`) its SoundFont was loaded under; a sampler from an earlier run is reloaded.
        var loadedRun = -1
        var loading = false
        /// Called (on the engine's queue) when its SoundFont has (re)loaded.
        var onReady: (() -> Void)?
        var on = false
        var sounding: [UInt8: Int] = [:]
        /// A singer: the last bar queued on its player (the next one follows it seamlessly), and from which part.
        var lastSung: Int?
        var lastPart: String?
        init(who: String, instrument: String) { self.who = who; self.instrument = instrument }
    }
    private var units: [String: Unit] = [:]
    /// Counts the engine's starts. A sampler that loaded its SoundFont under an earlier start is reloaded before
    /// it plays again: an AVAudioUnitSampler can come back from an engine stop / start with its instrument gone,
    /// playing the sampler's built-in test tone instead.
    private var engineRun = 0
    /// Oct 25 (the walking band): this performance repeats its piece instead of finishing.
    private var repeats = false
    /// The audio engine is running (read from the main actor by the walking band, to notice an interruption).
    var isEngineRunning: Bool { engine.isRunning }

    private enum Kind {
        case on(UInt8, UInt8), off(UInt8), cc(UInt8, UInt8), volume(Float)
    }
    private struct Pending {
        let host: UInt64
        let who: String
        let kind: Kind
    }
    private var pending: [Pending] = []
    private var timer: DispatchSourceTimer?
    private var startHost: UInt64 = 0
    private var nextBar = 0
    private var plans: [Int: BandBar] = [:]
    private var loudness: [String: Float] = [:]
    private var partCache: [String: AVAudioPCMBuffer] = [:]
    private var lateEvents = 0

    // auditions: an instrument's own phrase (band-auditions.json), on its own sampler and mixer
    private let auditionMix = AVAudioMixerNode()
    /// Where the band and the auditions meet, before the shared reverb and limiter.
    private let labMix = AVAudioMixerNode()
    private var auditionUnits: [String: Unit] = [:]
    private var auditionPending: [Pending] = []
    private var auditionTimer: DispatchSourceTimer?
    private var auditionEnd: UInt64 = 0
    private var auditionInstrument: String?
    private var phrases: [String: LabPhrase] = [:]
    private var master: Float = 0
    private var duck: Float = 1
    /// The band's level under an audition (it keeps playing, quietly).
    static let auditionDuck: Float = 0.18

    private let lock = NSLock()
    private var snap = Snapshot()
    var snapshot: Snapshot { lock.withLock { snap } }

    /// Lead level (dBFS RMS, before the limiter's +8 dB) every instrument is evened out to; the arranger's
    /// per-bar levels (melody 0, answers -3, chords -7, ...) sit on top.
    static let reference: Float = -24
    static let makeUp: Float = 8
    static let planAhead: Double = 1.5
    /// After a whole piece's last bar: its final notes' release and the reverb's tail.
    static let ringOut: Double = 2.0
    static let dispatchAhead: Double = 0.06

    init() {
        var d = AudioComponentDescription()
        d.componentType = kAudioUnitType_Effect
        d.componentSubType = kAudioUnitSubType_PeakLimiter
        d.componentManufacturer = kAudioUnitManufacturer_Apple
        limiter = AVAudioUnitEffect(audioComponentDescription: d)
        // instrument loudness (measured when the SoundFonts were built) and the voices' levels
        if let u = BandAssets.url("band-instruments", "json"), let data = try? Data(contentsOf: u),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (k, v) in obj { if let l = v["loudnessDb"] as? Double { loudness[k] = Float(l) } }
        }
        if let u = BandAssets.url("band-voices", "json"), let data = try? Data(contentsOf: u),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let lv = obj["levels"] as? [String: Double] {
            for (k, v) in lv { loudness[k] = Float(v) }
        }
        phrases = LabPhrase.load()
    }

    // MARK: Graph

    private func buildGraph() {
        guard !graphReady else { return }
        engine.attach(bandMix)
        engine.attach(reverb)
        engine.attach(limiter)
        engine.attach(auditionMix)
        engine.attach(labMix)
        // Oct 25 fix: the reverb has ONE input. Connecting the audition mixer to it as well broke the band
        // mixer's connection, leaving every band unit with no path to the output -- the singers' players then
        // threw "player started when in a disconnected state". Both mixers now meet in labMix (two input
        // buses) and labMix alone feeds the reverb.
        engine.connect(bandMix, to: labMix, fromBus: 0, toBus: 0, format: nil)
        engine.connect(auditionMix, to: labMix, fromBus: 0, toBus: 1, format: nil)
        engine.connect(labMix, to: reverb, format: nil)
        engine.connect(reverb, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)
        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = 14
        AudioUnitSetParameter(limiter.audioUnit, AudioUnitParameterID(kLimiterParam_PreGain), kAudioUnitScope_Global, 0, Self.makeUp, 0)
        bandMix.outputVolume = 0
        auditionMix.outputVolume = 0
        graphReady = true
    }

    private func unit(for who: String, instrument: String) -> Unit {
        if let u = units[who] { return u }
        let u = Unit(who: who, instrument: instrument)
        units[who] = u
        // each instrument evened out to the reference: a sampler by its masterGain (up to +12 dB),
        // a singer (parts normalized at build time, so louder than the reference) by its volume
        let norm = Self.reference - (loudness[instrument] ?? -30)
        u.trim = max(-40, min(12, norm))
        if let voice = BandInstruments.voices[instrument] {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
            engine.connect(p, to: bandMix, format: fmt)
            p.pan = BandInstruments.pan(instrument)
            u.trim = min(0, u.trim)
            p.volume = 0
            u.player = p
            if engine.isRunning { p.play() }
            u.ready = true
            diag("band.unit", ["who": who, "voice": voice])
        } else {
            attachSampler(u, to: bandMix, pan: BandInstruments.pan(instrument), gain: u.trim)
        }
        return u
    }

    /// A sampler for a unit -- the band's and the auditions' alike: attached, connected to `mix`, then its
    /// instrument's SoundFont loaded (program 0, the default melodic bank).
    private func attachSampler(_ u: Unit, to mix: AVAudioMixerNode, pan: Float, gain: Float) {
        let s = AVAudioUnitSampler()
        engine.attach(s)
        engine.connect(s, to: mix, format: nil)
        s.pan = pan
        s.masterGain = gain
        u.sampler = s
        loadSoundFont(u)
    }

    /// (Re)load a unit's SoundFont off the engine's queue; it plays nothing (`ready` false) until done.
    private func loadSoundFont(_ u: Unit) {
        guard let s = u.sampler, !u.loading else { return }
        u.ready = false
        u.loading = true
        let instrument = u.instrument, who = u.who
        loadQueue.async { [weak self] in
            var ok = false
            if let url = BandAssets.url("band-\(instrument)", "sf2") {
                do {
                    try s.loadSoundBankInstrument(at: url, program: 0, bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                  bankLSB: UInt8(kAUSampler_DefaultBankLSB))
                    ok = true
                } catch {
                    diag("band.soundfontFailed", ["instrument": instrument, "error": "\(error)"])
                }
            } else {
                diag("band.soundfontMissing", ["instrument": instrument])
            }
            self?.queue.async { [weak self] in
                guard let self else { return }
                u.loading = false
                guard ok else { return }
                u.ready = true
                u.loadedRun = self.engineRun
                diag("band.unit", ["who": who, "instrument": instrument, "engineRun": self.engineRun, "engineRunning": self.engine.isRunning])
                let f = u.onReady
                u.onReady = nil
                f?()
            }
        }
    }

    /// Start the engine if it is stopped; after a (re)start, every sampler loaded under an earlier run reloads.
    private func startEngine() -> Bool {
        do {
            engine.prepare()
            if !engine.isRunning {
                try engine.start()
                engineRun += 1
                for u in Array(units.values) + Array(auditionUnits.values) where u.sampler != nil && u.loadedRun != engineRun {
                    if u.ready { loadSoundFont(u) }
                }
            }
            return true
        } catch {
            diag("band.engineFailed", ["error": "\(error)"])
            return false
        }
    }

    // MARK: Control (any thread -> the engine's queue)

    func setLineup(_ lineup: [LabSeat]) {
        queue.async { [self] in
            let ids = Set(lineup.map(\.who))
            for (who, u) in units where u.on && !ids.contains(who) { leave(u) }
            if snap.playing {
                for m in lineup { unit(for: m.who, instrument: m.instrument).on = true }
            }
            arranger?.setLineup(lineup)
            diag("band.lineup", ["on": lineup.map(\.who).joined(separator: ",")])
        }
    }

    func start(composition: String, lineup: [LabSeat], repeats: Bool = false) {
        queue.async { [self] in
            if arranger?.compositionID != composition { arranger = BandArranger(composition: composition) }
            guard let arranger else { return }
            timer?.cancel(); timer = nil                                    // (a start while running: one clock only)
            buildGraph()
            // Oct 25 (stuck-note fix): a (re)start drops every pending event -- the note-offs of notes already
            // sounding included -- so those notes are released here first; a musician left out is silenced
            // as well as switched off (it was only switched off, and its sounding notes never ended).
            for u in units.values where !u.sounding.isEmpty { silence(u) }
            let ids = Set(lineup.map(\.who))
            for u in units.values where !ids.contains(u.who) { u.on = false }
            for m in lineup { unit(for: m.who, instrument: m.instrument).on = true }
            self.repeats = repeats
            arranger.setRepeat(repeats)
            guard startEngine() else { return }
            for u in units.values { u.player?.play(); u.lastSung = nil; u.lastPart = nil }
            arranger.setLineup(lineup)
            pending = []
            plans = [:]
            nextBar = 0
            lateEvents = 0
            startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.5)
            lock.withLock { snap = Snapshot(playing: true, bars: arranger.bars) }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            diag("band.start", ["composition": composition, "bpm": arranger.bpm, "on": lineup.map(\.who).joined(separator: ",")])
        }
    }

    /// Everything stops: notes released, the band faded, the engine stopped after the fade.
    func stop(release: Bool) {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            pending = []
            for u in units.values { silence(u) }
            lock.withLock { snap.playing = false }
            diag("band.stop", ["late": lateEvents])
            if release { endAudition() }
            queue.asyncAfter(deadline: .now() + 0.6) { [self] in
                guard timer == nil, auditionTimer == nil else { return }
                engine.stop()
                if release {
                    for u in units.values {
                        if let s = u.sampler { engine.detach(s) }
                        if let p = u.player { engine.detach(p) }
                    }
                    for u in auditionUnits.values { if let s = u.sampler { engine.detach(s) } }
                    units = [:]
                    auditionUnits = [:]
                    partCache = [:]
                }
            }
        }
    }

    /// The band's overall level (0 silences: Mute, a Settings suppression).
    func setMaster(_ v: Float) {
        queue.async { [self] in
            master = v
            applyLevels()
        }
    }

    /// The band at master x duck (ducked under an audition); auditions at master.
    private func applyLevels() {
        bandMix.outputVolume = master * duck
        auditionMix.outputVolume = master
    }

    // MARK: The clock

    private func host(bar: Int, beat: Double = 0) -> UInt64 {
        guard let a = arranger else { return startHost }
        let seconds = (Double(bar * a.beatsPerBar) + beat) * 60 / a.bpm
        return startHost + AVAudioTime.hostTime(forSeconds: seconds)
    }

    private func tick() {
        guard let arranger else { return }
        let now = mach_absolute_time()
        // plan the bars about to begin (a whole piece: up to its last bar)
        while host(bar: nextBar) < now + AVAudioTime.hostTime(forSeconds: Self.planAhead), arranger.loops || repeats || nextBar < arranger.bars {
            plan(nextBar, arranger)
            nextBar += 1
        }
        // a whole piece: once its last bar and a moment of ring-out have passed (every note off), it has finished
        if !arranger.loops, !repeats, pending.isEmpty, now > host(bar: arranger.bars) + AVAudioTime.hostTime(forSeconds: Self.ringOut) {
            if !snap.finished {
                lock.withLock { snap.finished = true }
                diag("band.finished", ["bars": arranger.bars, "late": lateEvents])
            }
        }
        // hand the due notes to their instruments
        let horizon = now + AVAudioTime.hostTime(forSeconds: Self.dispatchAhead)
        var i = 0
        while i < pending.count, pending[i].host <= horizon {
            dispatch(pending[i], now: now)
            i += 1
        }
        if i > 0 { pending.removeFirst(i) }
        // where the music is (for the UI)
        let secs = now > startHost ? AVAudioTime.seconds(forHostTime: now - startHost) : 0
        let barNow = Int(secs * arranger.bpm / 60) / arranger.beatsPerBar
        if let p = plans[barNow] {
            lock.withLock { snap.bar = barNow; snap.loopBar = p.loopBar; snap.section = p.section; snap.chord = p.chord; snap.roles = p.roles }
        }
        plans = plans.filter { $0.key >= barNow - 1 }
    }

    private func plan(_ n: Int, _ arranger: BandArranger) {
        guard let p = arranger.plan(bar: n) else { return }
        plans[n] = p
        let barHost = host(bar: n)
        let spb = 60 / arranger.bpm
        var add: [Pending] = []
        // each musician's level for its part this bar (a sampler: CC7, 40 log10 law; a singer: its volume)
        for (who, level) in p.levels {
            guard let u = units[who], u.on else { continue }
            if u.sampler != nil {
                let v = UInt8(max(1, min(127, 127 * pow(10, level / 40))))
                add.append(Pending(host: barHost, who: who, kind: .cc(7, v)))
            } else if u.player != nil {
                add.append(Pending(host: barHost, who: who, kind: .volume(level <= -59 ? 0 : pow(10, (u.trim + Float(level)) / 20))))
            }
        }
        var sang = Set<String>()
        for e in p.events {
            guard let u = units[e.who], u.on else { continue }
            let at = barHost + AVAudioTime.hostTime(forSeconds: max(0, e.t) * spb)
            switch e.type {
            case "note":
                guard let pitch = e.pitch, let vel = e.vel, let dur = e.dur else { continue }
                let p8 = UInt8(max(0, min(127, pitch))), v8 = UInt8(max(1, min(127, vel)))
                add.append(Pending(host: at, who: e.who, kind: .on(p8, v8)))
                add.append(Pending(host: at + AVAudioTime.hostTime(forSeconds: max(0.03, dur) * spb), who: e.who, kind: .off(p8)))
            case "cc":
                guard let cc = e.cc, let value = e.value else { continue }
                add.append(Pending(host: at, who: e.who, kind: .cc(UInt8(cc), UInt8(max(0, min(127, value))))))
            case "sing":
                guard let part = e.part, let lb = e.loopBar else { continue }
                sing(u, part: part, loopBar: lb, bar: n, at: barHost, arranger: arranger)
                sang.insert(e.who)
            default:
                continue
            }
        }
        // a singer with nothing to sing this bar: its queue ends here (it starts afresh at a host time next time)
        for u in units.values where u.player != nil && !sang.contains(u.who) { u.lastSung = nil }
        pending.append(contentsOf: add)
        pending.sort { $0.host < $1.host }
        if p.loopBar == 0 {
            diag("band.loop", ["bar": n, "roles": p.roles.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "),
                               "late": lateEvents])
        }
    }

    private func dispatch(_ e: Pending, now: UInt64) {
        guard let u = units[e.who], u.on, u.ready else { return }
        send(e, to: u)
    }

    /// One event to a unit's sampler (stamped with the sample time it must sound at) or player.
    private func send(_ e: Pending, to u: Unit) {
        if case .volume(let v) = e.kind {
            u.player?.volume = v
            return
        }
        guard let s = u.sampler else { return }
        let block = s.auAudioUnit.scheduleMIDIEventBlock
        var when = AUEventSampleTimeImmediate
        if let last = s.lastRenderTime, last.isSampleTimeValid, last.isHostTimeValid {
            let dt = AVAudioTime.seconds(forHostTime: e.host) - AVAudioTime.seconds(forHostTime: last.hostTime)
            let target = Double(last.sampleTime) + dt * last.sampleRate
            if target > Double(last.sampleTime) { when = AUEventSampleTime(target) } else { lateEvents += 1 }
        }
        var bytes: [UInt8]
        switch e.kind {
        case .on(let p, let v):
            bytes = [0x90, p, v]
            u.sounding[p, default: 0] += 1
        case .off(let p):
            bytes = [0x80, p, 0]
            if let c = u.sounding[p] { u.sounding[p] = c > 1 ? c - 1 : nil }
        case .cc(let c, let v):
            bytes = [0xB0, c, v]
        case .volume:
            return
        }
        if let block {
            bytes.withUnsafeBufferPointer { b in block(when, 0, 3, b.baseAddress!) }
        } else {
            switch e.kind {
            case .on(let p, let v): s.startNote(p, withVelocity: v, onChannel: 0)
            case .off(let p): s.stopNote(p, onChannel: 0)
            case .cc(let c, let v): s.sendController(c, withValue: v, onChannel: 0)
            case .volume: break
            }
        }
    }

    // MARK: Singers

    /// Queue one bar of a singer's prerendered part: frames [loopBar * F, (loopBar + 1) * F) of its loop.
    /// Consecutive bars follow each other on the player sample-exactly; the first after a gap starts at its bar's host time.
    private func sing(_ u: Unit, part: String, loopBar: Int, bar: Int, at host: UInt64, arranger: BandArranger) {
        guard let p = u.player, let voice = BandInstruments.voices[u.instrument] else { return }
        let name = "band-voice-\(voice)-\(arranger.compositionID)-\(part)"
        var whole = partCache[name]
        if whole == nil, let url = BandAssets.url(name, "caf"), let file = try? AVAudioFile(forReading: url),
           let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) {
            try? file.read(into: b)
            whole = b
            partCache[name] = b
        }
        guard let whole, let src = whole.floatChannelData else { diag("band.partMissing", ["part": name]); return }
        let sr = whole.format.sampleRate
        let F = Int((Double(arranger.beatsPerBar) * 60 / arranger.bpm * sr).rounded())
        let start = loopBar * F
        guard start < Int(whole.frameLength), let slice = AVAudioPCMBuffer(pcmFormat: whole.format, frameCapacity: AVAudioFrameCount(F)),
              let dst = slice.floatChannelData else { return }
        let count = min(F, Int(whole.frameLength) - start)
        slice.frameLength = AVAudioFrameCount(F)
        let changed = u.lastPart != part || u.lastSung != bar - 1
        for c in 0..<Int(whole.format.channelCount) {
            dst[c].update(from: src[c] + start, count: count)
            if count < F { (dst[c] + count).update(repeating: 0, count: F - count) }
            if changed {          // a fresh start (or another part): 5 ms fade in, no click
                let k = min(F, Int(sr * 0.005))
                for i in 0..<k { dst[c][i] *= Float(i) / Float(k) }
            }
        }
        if !p.isPlaying, engine.isRunning { p.play() }
        if u.lastSung == bar - 1 {
            p.scheduleBuffer(slice, completionHandler: nil)                       // right after the previous bar
        } else {
            p.scheduleBuffer(slice, at: AVAudioTime(hostTime: host), options: [], completionHandler: nil)
        }
        u.lastSung = bar
        u.lastPart = part
    }

    // MARK: Auditions

    /// Seconds an instrument's audition lasts (0: it has none -- the singers).
    func auditionSeconds(_ instrument: String) -> Double { phrases[instrument]?.seconds ?? 0 }

    /// Play an instrument's audition phrase now: its own sampler (the same SoundFont, the same sampler as in a
    /// composition) at its natural register, at the reference level, centred. Nobody is switched on and no
    /// layer is touched; if the band is playing it carries on, ducked, and comes back up after.
    func audition(_ instrument: String) {
        queue.async { [self] in
            guard let phrase = phrases[instrument] else { return }
            buildGraph()
            guard startEngine() else { return }
            endAudition()                                           // (one at a time)
            let u: Unit
            if let a = auditionUnits[instrument] {
                u = a
            } else {
                u = Unit(who: "audition:\(instrument)", instrument: instrument)
                u.trim = max(-40, min(12, Self.reference - (loudness[instrument] ?? -30)))
                auditionUnits[instrument] = u
                attachSampler(u, to: auditionMix, pan: 0, gain: u.trim + Self.auditionLift)   // (exactly as the band's)
            }
            u.on = true
            auditionInstrument = instrument
            if snap.playing { duck = Self.auditionDuck; applyLevels() }
            if u.ready, u.loadedRun == engineRun {
                scheduleAudition(phrase, unit: u)
            } else {
                // still loading (or loaded under an earlier engine run): play when its SoundFont is in
                u.onReady = { [weak self] in
                    if self?.auditionInstrument == instrument { self?.scheduleAudition(phrase, unit: u) }
                }
                if !u.loading { loadSoundFont(u) }
            }
            diag("band.audition", ["instrument": instrument, "duringBand": snap.playing])
        }
    }

    /// Auditions sit a little above a composition's melody level (they are heard alone).
    static let auditionLift: Float = 2

    private func scheduleAudition(_ phrase: LabPhrase, unit u: Unit) {
        let start = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.12)
        let spb = 60 / phrase.bpm
        auditionPending = []
        for n in phrase.notes {
            let at = start + AVAudioTime.hostTime(forSeconds: n.t * spb)
            let p8 = UInt8(max(0, min(127, n.pitch))), v8 = UInt8(max(1, min(127, n.vel)))
            auditionPending.append(Pending(host: at, who: u.who, kind: .on(p8, v8)))
            auditionPending.append(Pending(host: at + AVAudioTime.hostTime(forSeconds: max(0.03, n.dur) * spb), who: u.who, kind: .off(p8)))
        }
        auditionPending.sort { $0.host < $1.host }
        auditionEnd = start + AVAudioTime.hostTime(forSeconds: phrase.seconds)
        auditionTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.auditionTick() }
        t.resume()
        auditionTimer = t
    }

    private func auditionTick() {
        let now = mach_absolute_time()
        let horizon = now + AVAudioTime.hostTime(forSeconds: Self.dispatchAhead)
        var i = 0
        while i < auditionPending.count, auditionPending[i].host <= horizon {
            if let inst = auditionInstrument, let u = auditionUnits[inst], u.ready { send(auditionPending[i], to: u) }
            i += 1
        }
        if i > 0 { auditionPending.removeFirst(i) }
        if auditionPending.isEmpty, now >= auditionEnd { endAudition() }
    }

    /// The audition is over (or cut short): its notes released, the band back up. The engine keeps running
    /// while the Directory is open (no stop / start between auditions); closing the Directory stops it.
    private func endAudition() {
        auditionTimer?.cancel(); auditionTimer = nil
        auditionPending = []
        if let inst = auditionInstrument, let u = auditionUnits[inst] { silence(u); u.on = false }
        auditionInstrument = nil
        if duck != 1 { duck = 1; applyLevels() }
    }

    // MARK: Leaving

    private func leave(_ u: Unit) {
        u.on = false
        pending.removeAll { $0.who == u.who }
        silence(u)
        diag("band.leave", ["who": u.who])
    }

    /// Release every sounding note (the instrument's own release); fade a singer out.
    private func silence(_ u: Unit) {
        if let s = u.sampler {
            let held = Array(u.sounding.keys)
            for p in held { s.stopNote(p, onChannel: 0) }
            u.sounding = [:]
            s.sendController(64, withValue: 0, onChannel: 0)
            // Oct 25 (stuck-note fix): a note-on is handed to the sampler up to `dispatchAhead` early, stamped
            // to sound a moment later; an immediate stop comes BEFORE it, and that note then never ends (its
            // note-off was dropped with the pending events). The same notes are stopped again once that
            // moment has certainly passed.
            if !held.isEmpty {
                queue.asyncAfter(deadline: .now() + Self.dispatchAhead + 0.05) {
                    guard s.engine != nil else { return }                                    // (let go meanwhile)
                    for p in held where u.sounding[p] == nil { s.stopNote(p, onChannel: 0) }   // (not one played again since)
                }
            }
        }
        u.lastSung = nil
        u.lastPart = nil
        if let p = u.player, p.isPlaying {
            let start = p.volume
            for k in 1...10 {
                queue.asyncAfter(deadline: .now() + .milliseconds(25 * k)) { p.volume = start * Float(10 - k) / 10 }
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(270)) { [weak self] in
                p.stop()                                          // (drops the bars still queued)
                if let self, self.engine.isRunning, self.timer != nil { p.play() }
            }
        }
    }

    var engineObject: AVAudioEngine { engine }
}

// MARK: - The lab (main actor: the UI's state, focus, Mute)

@MainActor
final class MusicLab: ObservableObject {
    static let shared = MusicLab()

    @Published private(set) var genre: LabGenre = .blues
    @Published private(set) var composition: LabComposition?
    @Published private(set) var playing = false
    /// The composition's layer stack (names, in order).
    @Published private(set) var layers: [String] = []
    /// Who holds each layer (nil: vacant). A musician keeps its layer until switched off or the arrangement is reset.
    @Published private(set) var slots: [String?] = []
    /// Switched on while every layer was taken, in the order they were switched on; the first gets the next layer freed.
    @Published private(set) var waiting: [String] = []
    @Published private(set) var status = ""
    /// The piece just played to its end (cleared by PLAY or another choice).
    @Published private(set) var finished = false
    @Published private(set) var roles: [String: String] = [:]
    /// The resident whose instrument is being auditioned now.
    @Published private(set) var auditioning: String?
    private var auditionToken = 0
    let members: [BandMember]

    /// While the band plays (any thread): the hallways' own music stays quiet.
    nonisolated static var isActive: Bool { activeLock.withLock { active } }
    nonisolated private static let activeLock = NSLock()
    nonisolated(unsafe) private static var active = false
    private static func setActive(_ on: Bool) { activeLock.withLock { active = on } }

    private let engine = BandEngine()
    private var clock: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastMaster: Float = -1

    private init() {
        members = CharacterRegistry.all.compactMap { c -> BandMember? in
            guard let inst = BandInstruments.byResident[c.id] else { return nil }
            return BandMember(id: c.id, name: c.name, instrument: inst, label: BandInstruments.labels[inst] ?? inst, tint: c.tint)
        }.sorted { (BandInstruments.order.firstIndex(of: $0.instrument) ?? 99) < (BandInstruments.order.firstIndex(of: $1.instrument) ?? 99) }
        diag("band.roster", ["members": members.count, "unassigned": CharacterRegistry.all.filter { BandInstruments.byResident[$0.id] == nil }.map(\.id).joined(separator: ",")])
        // the composition last chosen (Oct 25: remembered -- the walking band plays it too)
        let saved = UserDefaults.standard.string(forKey: Self.lastCompositionKey)
        if let c = MusicLabCatalog.all.first(where: { $0.id == saved }), BandAssets.url(c.file, "json") != nil {
            genre = c.genre
            openComposition(c)
        } else {
            openComposition(MusicLabCatalog.compositions(.blues).first)
        }
    }

    private static let lastCompositionKey = "musicLab.lastComposition"
    private func remember() {
        if let c = composition { UserDefaults.standard.set(c.id, forKey: Self.lastCompositionKey) }
    }

    /// Oct 25: an audition from the hallways (LISTEN) with nothing else using the engine: stop it again
    /// (an idle engine isn't left running in the hallways; the next audition reloads and starts it).
    fileprivate func idleAfterAudition() {
        guard !directoryIsOpen, !playing, !WalkingBand.shared.isActive else { return }
        engine.stop(release: false)
    }

    // MARK: The walking band (WalkingBand.swift) -- the same engine, when the Lab itself isn't using it

    /// The composition last chosen in the Lab.
    var lastComposition: LabComposition? { composition }
    /// The Directory (the Lab) is open, or the Lab is playing: the walking band keeps out of the way.
    var isBusy: Bool { playing || directoryIsOpen }
    private(set) var directoryIsOpen = false

    func walkingBandStart(composition: String, lineup: [LabSeat]) { engine.start(composition: composition, lineup: lineup, repeats: true) }
    func walkingBandLineup(_ lineup: [LabSeat]) { engine.setLineup(lineup) }
    func walkingBandLevel(_ v: Float) { engine.setMaster(v) }
    func walkingBandStop() { engine.stop(release: false) }
    var walkingBandEngineRunning: Bool { engine.isEngineRunning }

    var isAvailable: Bool { !AudioDiagnostics.audioOff }

    private static var silenced: Bool {
        HallwaysAudio.shared.isMuted || HallwaysAudio.shared.isSuppressed(otherThan: HallwaysAudio.musicLabFocus)
    }

    /// Everyone switched on, with the layer each holds.
    private var lineup: [LabSeat] {
        var out: [LabSeat] = []
        for (i, who) in slots.enumerated() {
            if let who, let m = members.first(where: { $0.id == who }) { out.append(LabSeat(who: who, instrument: m.instrument, layer: i)) }
        }
        for who in waiting {
            if let m = members.first(where: { $0.id == who }) { out.append(LabSeat(who: who, instrument: m.instrument, layer: nil)) }
        }
        return out
    }

    var onCount: Int { slots.compactMap { $0 }.count + waiting.count }
    func isOn(_ id: String) -> Bool { slots.contains(id) || waiting.contains(id) }
    /// "Layer 3 · Chords", "waiting", or nil (off).
    func layerLabel(_ id: String) -> String? {
        if let i = slots.firstIndex(of: id), i < layers.count { return "Layer \(i + 1) · \(layers[i])" }
        return waiting.contains(id) ? "waiting -- all \(layers.count) layers taken" : nil
    }
    /// What the next musician switched on will play.
    var nextLayer: String? {
        guard let i = slots.firstIndex(where: { $0 == nil }), i < layers.count else { return nil }
        return "Layer \(i + 1) · \(layers[i])"
    }

    // MARK: The arrangement (layers by activation order; saved per composition)

    private func openComposition(_ c: LabComposition?) {
        composition = c
        layers = c.map { MusicLabCatalog.layers($0) } ?? []
        slots = Array(repeating: nil, count: layers.count)
        waiting = []
        guard let c else { return }
        let d = UserDefaults.standard
        if let saved = d.array(forKey: "musicLab.layers.\(c.id)") as? [String], saved.count == layers.count {
            let known = Set(members.map(\.id))
            slots = saved.map { known.contains($0) ? $0 : nil }
            waiting = ((d.array(forKey: "musicLab.waiting.\(c.id)") as? [String]) ?? []).filter { known.contains($0) && !slots.contains($0) }
        }
    }

    private func save() {
        guard let c = composition else { return }
        UserDefaults.standard.set(slots.map { $0 ?? "" }, forKey: "musicLab.layers.\(c.id)")
        UserDefaults.standard.set(waiting, forKey: "musicLab.waiting.\(c.id)")
    }

    // MARK: Controls

    func choose(_ g: LabGenre) {
        guard !playing, g != genre else { return }
        genre = g
        openComposition(MusicLabCatalog.compositions(g).first)
        clearArrangement()
        remember()
    }

    /// Another composition: a fresh arrangement (its layers are not the old one's).
    func choose(_ c: LabComposition) {
        guard !playing, c != composition else { return }
        openComposition(c)
        clearArrangement()
        remember()
    }

    /// CLEAR: the music stops at once, every musician goes OFF, every layer (and the waiting list) is released.
    /// The genre and composition stay chosen. (STOP, by contrast, keeps the band and its layers.)
    func clear() {
        stop()
        clearArrangement()
    }

    private func clearArrangement() {
        finished = false
        slots = Array(repeating: nil, count: layers.count)
        waiting = []
        save()
        diag("band.clear", [:])
        if playing { engine.setLineup(lineup) }
    }

    /// ON: the lowest vacant layer (or wait for one). OFF: its layer is freed -- the first waiting musician takes it;
    /// nobody else moves.
    func toggle(_ id: String) {
        if let i = slots.firstIndex(of: id) {
            slots[i] = waiting.isEmpty ? nil : waiting.removeFirst()
        } else if let w = waiting.firstIndex(of: id) {
            waiting.remove(at: w)
        } else if let i = slots.firstIndex(where: { $0 == nil }) {
            slots[i] = id
        } else {
            waiting.append(id)
        }
        save()
        diag("band.toggle", ["who": id, "on": isOn(id), "layer": layerLabel(id) ?? "-", "playing": playing])
        if playing { engine.setLineup(lineup) }
    }

    func play() {
        guard !playing, isAvailable, let composition, !layers.isEmpty else { return }
        finished = false
        SoundEffects.configureAudioSession(reason: "musicLab")
        engine.start(composition: composition.id, lineup: lineup)
        playing = true
        Self.setActive(true)
        lastMaster = -1
        startClock()
        observe()
    }

    func stop() {
        guard playing else { return }
        engine.stop(release: false)
        playing = false
        Self.setActive(false)
        clock?.invalidate(); clock = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        status = ""
        roles = [:]
    }

    // MARK: Auditions

    /// Every instrumental resident has one (the singers don't: their voices are prerendered parts).
    func canAudition(_ m: BandMember) -> Bool { engine.auditionSeconds(m.instrument) > 0 }

    /// The resident's instrument alone: its signature phrase, its own register, the same SoundFont and sampler a
    /// composition uses. Nobody is switched on and no layer changes; a playing band ducks under it and comes back.
    func audition(_ m: BandMember) {
        let secs = engine.auditionSeconds(m.instrument)
        guard isAvailable, secs > 0 else { return }
        SoundEffects.configureAudioSession(reason: "musicLab")
        if !WalkingBand.shared.isActive { engine.setMaster(Self.silenced ? 0 : 0.9) }   // (the walking band sets its own level)
        engine.audition(m.instrument)
        auditioning = m.id
        auditionToken += 1
        let token = auditionToken
        DispatchQueue.main.asyncAfter(deadline: .now() + secs + 0.15) {
            MainActor.assumeIsolated {
                guard MusicLab.shared.auditionToken == token else { return }
                MusicLab.shared.auditioning = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {          // (after a slow first load's phrase, too)
                    MainActor.assumeIsolated {
                        if MusicLab.shared.auditionToken == token { MusicLab.shared.idleAfterAudition() }
                    }
                }
            }
        }
    }

    /// The Directory is on screen: the lab has the audio focus (every other Hallways sound silenced).
    func directoryOpened() {
        directoryIsOpen = true
        WalkingBand.shared.yieldToLab()                                 // (Oct 25: the walking band stops; the Lab has the engine)
        HallwaysAudio.shared.setSuppressed(true, reason: HallwaysAudio.musicLabFocus)
    }

    /// The Directory went away: the band stops (and lets its instruments go); the focus is given back.
    func directoryClosed() {
        stop()
        engine.stop(release: true)
        directoryIsOpen = false                                         // (the walking band may start again, from the top)
        HallwaysAudio.shared.setSuppressed(false, reason: HallwaysAudio.musicLabFocus)
    }

    // MARK: Where the music is; Mute

    private func startClock() {
        clock?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { MusicLab.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        clock = t
        tick()
    }

    private func tick() {
        guard playing else { return }
        let wanted: Float = Self.silenced ? 0 : 0.9
        if wanted != lastMaster { engine.setMaster(wanted); lastMaster = wanted }
        let s = engine.snapshot
        if s.finished {
            // the piece has ended: back to ready (the band and its layers kept, as after STOP)
            stop()
            finished = true
            return
        }
        if s.playing, s.bars > 0 {
            status = "\(s.section) · bar \(s.loopBar + 1) of \(s.bars)\(s.chord.isEmpty ? "" : " · " + s.chord)"
            if s.roles != roles { roles = s.roles }
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine.engineObject, queue: .main) { _ in
            MainActor.assumeIsolated {
                diag("band.interrupted", ["why": "engine configuration change"])
                MusicLab.shared.stop()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) } == .began
            MainActor.assumeIsolated {
                guard began else { return }
                diag("band.interrupted", ["why": "audio session interruption"])
                MusicLab.shared.stop()
            }
        })
    }
}

// MARK: - The Directory's MUSIC LAB

/// Fixed at the top of the Directory: genre, composition, PLAY/STOP, where the music is.
struct MusicLabControls: View {
    @ObservedObject private var lab = MusicLab.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("MUSIC LAB")
                    .font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                Spacer(minLength: 8)
                Text("\(lab.onCount) on")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(PhoneStyle.inkSoft)
            }
            HStack(spacing: 6) {
                ForEach(LabGenre.allCases) { g in
                    let count = MusicLabCatalog.compositions(g).count
                    Button { lab.choose(g) } label: {
                        VStack(spacing: 0) {
                            Text(g.title).font(.system(size: 13, weight: .heavy, design: .rounded))
                            Text(count == 0 ? "none yet" : "\(count)").font(.system(size: 9, weight: .bold, design: .rounded)).opacity(0.7)
                        }
                        .foregroundStyle(lab.genre == g ? .white : PhoneStyle.ink)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(lab.genre == g ? PhoneStyle.ink : Color.white.opacity(0.7)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(lab.playing)
                    .opacity(count == 0 && lab.genre != g ? 0.55 : 1)
                }
            }
            compositionPicker
            HStack(spacing: 8) {
                Button {
                    if lab.playing { lab.stop() } else { lab.play() }
                } label: {
                    Label(lab.playing ? "STOP" : "PLAY", systemImage: lab.playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(lab.playing ? Color(red: 0.75, green: 0.25, blue: 0.2) : PhoneStyle.ink))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!lab.isAvailable || (!lab.playing && lab.composition == nil))
                .opacity(!lab.playing && lab.composition == nil ? 0.4 : 1)
                // CLEAR: stop, everyone off, every layer free -- ready for a new band
                Button { lab.clear() } label: {
                    Label("CLEAR", systemImage: "xmark")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(PhoneStyle.ink)
                        .frame(minWidth: 104, minHeight: 46)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.85)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(PhoneStyle.ink.opacity(0.35), lineWidth: 1.2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!lab.playing && lab.onCount == 0)
                .opacity(!lab.playing && lab.onCount == 0 ? 0.4 : 1)
                .accessibilityHint("Stops the music and switches every musician off")
            }
            Text(statusLine)
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(PhoneStyle.inkSoft)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PhoneStyle.rule, lineWidth: 1))
        .padding(.horizontal, 14)
    }

    /// The genre's compositions (a menu); a genre with none says so -- no stand-ins.
    @ViewBuilder private var compositionPicker: some View {
        let list = MusicLabCatalog.compositions(lab.genre)
        HStack(spacing: 8) {
            Text("Composition").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
            Spacer(minLength: 4)
            if list.isEmpty {
                Text("No \(lab.genre.title.lowercased()) compositions yet")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
            } else {
                Menu {
                    ForEach(list) { c in
                        Button { lab.choose(c) } label: {
                            if lab.composition == c { Label(c.title, systemImage: "checkmark") } else { Text(c.title) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(lab.composition?.title ?? "Choose").font(.system(size: 14, weight: .heavy, design: .rounded))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(PhoneStyle.ink)
                    .padding(.horizontal, 10).frame(minHeight: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.8)))
                }
                .disabled(lab.playing)
            }
        }
    }

    private var statusLine: String {
        if !lab.isAvailable { return "Audio is off (Settings › Diagnostics)." }
        if lab.playing { return lab.status.isEmpty ? "Counting in…" : lab.status }
        guard let c = lab.composition else { return "Choose a genre with a composition." }
        if lab.onCount == 0 { return "Switch musicians on below, one layer each, then PLAY." }
        if lab.finished { return "The end! PLAY to hear \(c.title) again, or choose another piece." }
        return c.blurb
    }
}

/// Every resident, their instrument, the part they play now, ON/OFF -- the first thing in the Directory's list.
struct MusicLabMusicians: View {
    @ObservedObject private var lab = MusicLab.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(introLine)
                .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(lab.members) { m in row(m) }
        }
        .padding(.horizontal, 14)
    }

    /// The layer stack, and what the next musician switched on will play.
    private var introLine: String {
        guard !lab.layers.isEmpty else { return "This composition has no layers." }
        let stack = lab.layers.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: " · ")
        let next = lab.nextLayer.map { "Next one on plays \($0)." } ?? "Every layer is taken."
        return "Layers: \(stack). Each musician you switch on takes the next free layer, whatever their instrument. \(next)"
    }

    private func row(_ m: BandMember) -> some View {
        let on = lab.isOn(m.id)
        // the layer it holds; while playing, how it performs it (octave, top note, rhythm only, ...)
        let role = on ? ((lab.playing ? lab.roles[m.id] : nil) ?? lab.layerLabel(m.id)) : nil
        let hearing = lab.auditioning == m.id
        return HStack(spacing: 8) {
            // tap the row: ON / OFF
            Button { lab.toggle(m.id) } label: {
                HStack(spacing: 10) {
                    Circle().fill(on ? m.tint : m.tint.opacity(0.25))
                        .frame(width: 30, height: 30)
                        .overlay(Text(String(m.name.prefix(1))).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.name).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(PhoneStyle.ink).lineLimit(1)
                        Text(m.label).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft).lineLimit(1)
                        if let role {
                            Text(role).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(m.tint)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(m.tint.opacity(0.14)))
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(m.name), \(m.label)")
            .accessibilityValue(on ? "on" : "off")
            // AUDITION: the instrument alone, in its own register (not the composition's) -- nobody switched on
            if lab.canAudition(m) {
                Button { lab.audition(m) } label: {
                    Image(systemName: hearing ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(hearing ? .white : m.tint)
                        .frame(width: 36, height: 30)
                        .background(Capsule().fill(hearing ? m.tint : m.tint.opacity(0.12)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Audition \(m.name)'s \(m.label.lowercased())")
            }
            Button { lab.toggle(m.id) } label: {
                Text(on ? "ON" : "OFF")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(on ? .white : PhoneStyle.inkSoft)
                    .frame(width: 42, height: 24)
                    .background(Capsule().fill(on ? m.tint : Color.black.opacity(0.07)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(on ? 0.9 : 0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? m.tint : PhoneStyle.rule, lineWidth: 1.2))
        .disabled(!lab.isAvailable)
    }
}
