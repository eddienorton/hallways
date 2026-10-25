//
//  HallwaysianMusic.swift
//  Hallways
//
//  Oct 22 -- MUSICAL IDENTITIES, FIRST AUDITION (an experiment; reversible).
//
//  Six Hallwaysians take names from famous songs, and each greets with a short
//  INSTRUMENTAL signature (piano, marimba, plucked strings, electric piano,
//  bells) instead of its Hallenese hello. Everything else about them -- ID,
//  saves, following, arrivals, walking -- is untouched.
//
//  THE SIGNATURES ARE ORIGINAL. The songs are under copyright, so none of them
//  transcribes its song's hook. Each borrows only the song's FEEL (tempo,
//  groove, instrument colour, phrasing) and is written to suit the character's
//  look and personality. They are not meant to be recognisable as the songs.
//
//  Oct 22 (later) -- EVERY ACTIVE CHARACTER now has one (the other ten
//  Hallwaysians, the Chair, the Butterfly, the Pottle, the meeting's six,
//  Tinky and Juanita), keeping their own names; when they're heard is decided
//  in ONE place, ResidentMusicConductor (ResidentMusic.swift). Every file is
//  rendered in the background at launch (prepareAll) -- never on the main
//  thread; a signature whose file isn't ready yet simply isn't played (its
//  original sound is, where it has one).
//
//  ONE SWITCH: Settings > "Musical Identities (audition)", or the launch
//  argument `-HallwaysMusicalIdentities NO`. Off: the six greet with their
//  original Hallenese hellos and (from the next launch) wear their old names.
//  Remove the experiment: delete this file and ResidentMusic.swift, and the
//  lines marked "Oct 22 (musical identities)" / "Oct 22 (musical building)".
//

import Foundation
import SceneKit

nonisolated enum HallwaysianMusic {
    // MARK: The switch

    static let defaultsKey = "HallwaysMusicalIdentities"

    /// On unless switched off (Settings, or `-HallwaysMusicalIdentities NO`).
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) == nil ? true : UserDefaults.standard.bool(forKey: defaultsKey)
    }

    // MARK: Who has one

    struct Signature {
        let id: String
        /// A song name it wears while the experiment is on (nil: it keeps its own name).
        let newName: String?
        let oldName: String
        let inspiration: String
        /// What it plays, in words (for the report and Settings).
        let summary: String
        let notes: [Note]

        init(id: String, newName: String, oldName: String, inspiration: String, summary: String, notes: [Note]) {
            self.id = id; self.newName = newName; self.oldName = oldName; self.inspiration = inspiration
            self.summary = summary; self.notes = notes
        }

        /// Oct 22 (later): a resident keeping its own name -- a signature of its own, no song.
        init(id: String, name: String, summary: String, notes: [Note]) {
            self.id = id; self.newName = nil; self.oldName = name; self.inspiration = ""
            self.summary = summary; self.notes = notes
        }
    }

    /// The six song-named Hallwaysians (the first audition; untouched since).
    static let songNamed: [Signature] = [benny, cecilia, jolene, eileen, gloria, layla]

    /// Oct 22 (later): every active character -- the six, the other ten Hallwaysians,
    /// the Chair, the Butterfly, the Pottle, the meeting's six, Tinky and Juanita.
    /// (Not the Big Shot -- retired; not Harold -- he has his own music.)
    static let all: [Signature] = songNamed + otherHallwaysians + oddities + cast + story

    static func signature(_ id: String) -> Signature? { all.first { $0.id == id } }

    /// The name the player sees: the song name while the experiment is on (only the six have one).
    static func displayName(_ id: String, original: String) -> String {
        guard isOn, let name = signature(id)?.newName else { return original }
        return name
    }

    /// Its cached file's name (the six keep their first-audition files).
    /// `low` (Oct 22, morning): its goodbye -- the same signature an octave down.
    static func soundName(_ id: String, low: Bool = false) -> String {
        let slug = id.replacingOccurrences(of: ".", with: "-")
        return (id.hasPrefix("hw.") ? "hw-music-v1-\(slug)" : "music-v1-\(slug)") + (low ? "-low" : "")
    }

    /// Oct 22 (morning): the goodbye (stopping following) is the signature this far down.
    static let farewellTranspose: Float = -12

    /// Gentler than the hellos (0.55): these last longer.
    static let volume: Float = 0.42

    // MARK: Ready before it's needed (Oct 22, later: never rendered on the main thread)

    /// Its WAV, where MenagerieSound and SoundCatalog look for it.
    static func url(_ id: String, low: Bool = false) -> URL { SoundCatalog.url(soundName(id, low: low)) }

    /// Its file is there (rendered on an earlier launch, or by prepareAll).
    static func isReady(_ id: String, low: Bool = false) -> Bool { FileManager.default.fileExists(atPath: url(id, low: low).path) }

    /// One background queue renders every missing file, once per install -- in
    /// order, so a single preview asked for meanwhile simply waits its turn.
    private static let renderQueue = DispatchQueue(label: "hallways.music.render", qos: .utility)

    /// At launch (BuildingLife.start): every signature not yet on disk, in the background.
    static func prepareAll() {
        guard !AudioDiagnostics.audioOff else { return }                  // (Oct 24: audio-off -- nothing rendered)
        renderQueue.async {
            var made = 0
            for s in all {
                if !isReady(s.id) { renderFile(s); made += 1 }
            }
            // (then the goodbyes: the greetings matter first)
            for s in all where !isReady(s.id, low: true) {
                renderFile(s, low: true)
                made += 1
            }
            if made > 0 { diag("music.prepared", ["rendered": made, "of": all.count]) }
        }
    }

    /// One signature (rendered in the background if need be), then `then` on the main thread.
    static func prepare(_ id: String, low: Bool = false, then: @escaping @MainActor () -> Void) {
        renderQueue.async {
            if !isReady(id, low: low), let s = signature(id) { renderFile(s, low: low) }
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
    }

    /// Written whole, then moved into place (never a half-written file to load).
    private static func renderFile(_ s: Signature, low: Bool = false) {
        let data = BobbinSound.wav(MenagerieSound.normalized(render(s, transpose: low ? farewellTranspose : 0)))
        try? data.write(to: url(s.id, low: low), options: .atomic)
    }

    /// Its sound, loaded once -- only when its file is ready (otherwise nil, and
    /// the file is asked for in the background: never a render here).
    /// `low`: its goodbye (an octave down).
    @MainActor static func source(_ id: String, low: Bool = false) -> SCNAudioSource? {
        let key = soundName(id, low: low)
        if let s = loaded[key] { return s }
        guard let sig = signature(id) else { return nil }
        guard isReady(id, low: low) else {
            prepare(id, low: low) {}
            return nil
        }
        // (the file is there: this only loads it -- the render below never runs)
        let shift = low ? farewellTranspose : 0
        guard let s = MenagerieSound.source(key, volume: volume, { render(sig, transpose: shift) }) else { return nil }
        loaded[key] = s
        return s
    }
    @MainActor private static var loaded: [String: SCNAudioSource] = [:]

    /// How long it plays (seconds), from its notes.
    static func duration(_ id: String) -> Double {
        guard let s = signature(id) else { return 0 }
        return Double((s.notes.map { $0.at + $0.hold }.max() ?? 0) + 0.5)
    }

    // MARK: Instruments

    enum Instrument {
        case piano, marimba, nylon, steel, mandolin, bass, electricPiano, bell, woodblock
        /// Oct 22 (later): four more voices for the rest of the building.
        case vibes, kalimba, harp, celesta
    }

    struct Note {
        let inst: Instrument
        /// MIDI note numbers (several: a chord).
        let midi: [Float]
        /// Onset (s).
        let at: Float
        /// How long it is held before it's let go (s).
        let hold: Float
        /// 0...1.
        let vel: Float
        /// A slide up (or down) to this note, starting `slideAfter` s in, taking `slideTime` s.
        var slideTo: Float? = nil
        var slideAfter: Float = 0
        var slideTime: Float = 0.07

        init(_ inst: Instrument, _ midi: [Float], at: Float, hold: Float, vel: Float,
             slideTo: Float? = nil, slideAfter: Float = 0, slideTime: Float = 0.07) {
            self.inst = inst; self.midi = midi; self.at = at; self.hold = hold; self.vel = vel
            self.slideTo = slideTo; self.slideAfter = slideAfter; self.slideTime = slideTime
        }
    }

    // MARK: The signatures (MIDI: 60 = middle C)

    /// BENNY (was Feddy: big eyes, peers at blinking lights) -- *Bennie and the
    /// Jets*' glam, stomping piano feel: two heavy staccato chord stabs, a pause,
    /// then a curious little upward peek that lands on a bright held note, with
    /// a celesta-like bell glinting on top. Piano, G major, ~1.9 s.
    static let benny = Signature(
        id: "hw.feddy", newName: "Benny", oldName: "Feddy", inspiration: "Bennie and the Jets -- Elton John",
        summary: "Piano: two staccato G-major chord stabs (G3-B3-D4; the second accented, with low G2), a pause, then D5-G5 grace notes up to a held B5 over a soft G4-D5, a bell glint on B6. ~1.9 s.",
        notes: [
            Note(.piano, [55, 59, 62], at: 0.00, hold: 0.11, vel: 0.62),
            Note(.piano, [43, 55, 59, 62], at: 0.30, hold: 0.14, vel: 0.78),
            Note(.piano, [74], at: 0.80, hold: 0.07, vel: 0.45),
            Note(.piano, [79], at: 0.88, hold: 0.07, vel: 0.5),
            Note(.piano, [67, 74, 83], at: 0.97, hold: 0.75, vel: 0.6),
            Note(.bell, [95], at: 0.98, hold: 0.6, vel: 0.22),
        ])

    /// CECILIA (was Sister: coral, brisk and cheerful, says hello twice) -- the
    /// bright, skipping, percussive joy of *Cecilia*: a marimba phrase said twice,
    /// the second answering higher, over a soft woodblock. C major, ~1.9 s.
    static let cecilia = Signature(
        id: "hw.sister", newName: "Cecilia", oldName: "Sister", inspiration: "Cecilia -- Simon & Garfunkel",
        summary: "Marimba with woodblock: a skipping dotted call E5-C5-D5-G4 (long-short-medium-long), a breath, then the answer E5-C5-D5-G5 rising to a held C6; low C4/G3 underneath. ~1.9 s.",
        notes: [
            Note(.marimba, [76, 60], at: 0.00, hold: 0.16, vel: 0.65),
            Note(.marimba, [72], at: 0.18, hold: 0.06, vel: 0.45),
            Note(.marimba, [74], at: 0.25, hold: 0.14, vel: 0.55),
            Note(.marimba, [67, 55], at: 0.42, hold: 0.2, vel: 0.55),
            Note(.marimba, [76, 60], at: 0.78, hold: 0.16, vel: 0.65),
            Note(.marimba, [72], at: 0.96, hold: 0.06, vel: 0.45),
            Note(.marimba, [74], at: 1.03, hold: 0.12, vel: 0.55),
            Note(.marimba, [79], at: 1.18, hold: 0.1, vel: 0.6),
            Note(.marimba, [84, 72, 64], at: 1.30, hold: 0.5, vel: 0.7),
            Note(.woodblock, [0], at: 0.00, hold: 0.05, vel: 0.3),
            Note(.woodblock, [0], at: 0.42, hold: 0.05, vel: 0.25),
            Note(.woodblock, [0], at: 0.78, hold: 0.05, vel: 0.3),
            Note(.woodblock, [0], at: 1.18, hold: 0.05, vel: 0.25),
        ])

    /// JOLENE (was Lanky: olive, very tall, most of it neck; shy, looks sideways)
    /// -- the urgent, fingerpicked minor-key guitar of *Jolene*, kept shy: a quick
    /// rolling A-minor arpeggio climbing (the long neck), a hesitation, then a
    /// soft two-note sideways glance. Nylon-string guitar, ~1.9 s.
    static let jolene = Signature(
        id: "hw.lanky", newName: "Jolene", oldName: "Lanky", inspiration: "Jolene -- Dolly Parton",
        summary: "Nylon-string guitar, A minor, soft: a fast rising arpeggio A2-E3-A3-C4-E4-A4 (even 16ths, ~85 ms), a hesitation, then G4 and a let-ring E4 over a low A2. ~1.9 s.",
        notes: [
            Note(.nylon, [45], at: 0.000, hold: 1.0, vel: 0.5),
            Note(.nylon, [52], at: 0.085, hold: 0.9, vel: 0.42),
            Note(.nylon, [57], at: 0.170, hold: 0.8, vel: 0.44),
            Note(.nylon, [60], at: 0.255, hold: 0.7, vel: 0.46),
            Note(.nylon, [64], at: 0.340, hold: 0.6, vel: 0.48),
            Note(.nylon, [69], at: 0.425, hold: 0.35, vel: 0.5),
            Note(.nylon, [67], at: 0.72, hold: 0.16, vel: 0.4),
            Note(.nylon, [45, 64], at: 0.90, hold: 0.9, vel: 0.42),
        ])

    /// EILEEN (was Stilts: ivory, the tallest, nearly all leg, tiny head) -- the
    /// folk-fiddle lilt and speeding-up of *Come On Eileen*: a high, long-legged
    /// 6/8 jig figure (long-short, long-short) that quickens, ending on a shivering
    /// mandolin tremolo and a tiny bell for the tiny head. D major, ~2.0 s.
    static let eileen = Signature(
        id: "hw.stilts", newName: "Eileen", oldName: "Stilts", inspiration: "Come On Eileen -- Dexys Midnight Runners",
        summary: "Mandolin (plucked, high), D major, 6/8 lilt that speeds up: D5 (long) F#5 (short), A5 (long) B5 (short), A5 F#5, then A5 into a tremolo D6 (~0.55 s), a bell on D7, a soft D4-A4 under the start. ~2.0 s.",
        notes: [
            Note(.mandolin, [62, 69], at: 0.00, hold: 0.5, vel: 0.3),
            Note(.mandolin, [74], at: 0.00, hold: 0.26, vel: 0.55),
            Note(.mandolin, [78], at: 0.28, hold: 0.12, vel: 0.42),
            Note(.mandolin, [81], at: 0.41, hold: 0.22, vel: 0.55),
            Note(.mandolin, [83], at: 0.64, hold: 0.1, vel: 0.42),
            Note(.mandolin, [81], at: 0.75, hold: 0.18, vel: 0.5),
            Note(.mandolin, [78], at: 0.94, hold: 0.08, vel: 0.42),
            Note(.mandolin, [81], at: 1.03, hold: 0.08, vel: 0.48),
        ] + eileenTremolo + [
            Note(.bell, [98], at: 1.12, hold: 0.6, vel: 0.2),
        ])

    /// Eileen's last note, a mandolin tremolo on D6 (ten quick plucks, fading).
    static let eileenTremolo: [Note] = (0..<10).map { (i: Int) -> Note in
        let k = Float(i)
        return Note(.mandolin, [86], at: 1.12 + k * 0.055, hold: 0.06, vel: 0.5 - k * 0.03)
    }

    /// GLORIA (was Scope: fuchsia, eyes far apart, gets there head first) -- the
    /// driving early-80s dance pulse of *Gloria*: an octave-bouncing bass, an
    /// electric-piano chord that arrives a touch early (head first), then a lift
    /// from E minor to D major. Electric piano and plucked bass, ~1.9 s.
    static let gloria = Signature(
        id: "hw.scope", newName: "Gloria", oldName: "Scope", inspiration: "Gloria -- Laura Branigan",
        summary: "Plucked bass bouncing in octaves E2-E3-E2-E3 (even 8ths, 120 ms), an electric-piano E-minor chord (G4-B4-E5) pushed in early, a D5 pickup, then a held D-major chord (D4-F#4-A4-F#5) over a low D2. ~1.9 s.",
        notes: [
            Note(.bass, [40], at: 0.00, hold: 0.1, vel: 0.6),
            Note(.bass, [52], at: 0.12, hold: 0.1, vel: 0.5),
            Note(.bass, [40], at: 0.24, hold: 0.1, vel: 0.6),
            Note(.bass, [52], at: 0.36, hold: 0.1, vel: 0.5),
            Note(.electricPiano, [67, 71, 76], at: 0.42, hold: 0.28, vel: 0.6),
            Note(.bass, [40], at: 0.48, hold: 0.1, vel: 0.55),
            Note(.electricPiano, [74], at: 0.80, hold: 0.12, vel: 0.5),
            Note(.electricPiano, [62, 66, 69, 78], at: 0.95, hold: 0.7, vel: 0.62),
            Note(.bass, [38], at: 0.95, hold: 0.6, vel: 0.6),
        ])

    /// LAYLA (was Lopsy: sky blue, gloriously lopsided, hurries everywhere) -- the
    /// bluesy, yearning guitar of *Layla*, made lopsided and hurried: a limping
    /// minor-pentatonic lick with a slide up, a quick stumble, and a landing that
    /// a soft piano chord catches (a nod to the song's piano coda). E minor, ~1.9 s.
    static let layla = Signature(
        id: "hw.lopsy", newName: "Layla", oldName: "Lopsy", inspiration: "Layla -- Derek and the Dominos",
        summary: "Clean steel-string guitar, E minor pentatonic, lopsided timing: E4 (short) G4 (long), A4 sliding up to B4 (held), a quick stumble G4-A4, landing on E4 with a soft piano E3-B3-G4 chord underneath. ~1.9 s.",
        notes: [
            Note(.steel, [64], at: 0.00, hold: 0.09, vel: 0.55),
            Note(.steel, [67], at: 0.10, hold: 0.2, vel: 0.5),
            Note(.steel, [69], at: 0.32, hold: 0.36, vel: 0.6, slideTo: 71, slideAfter: 0.05, slideTime: 0.08),
            Note(.steel, [67], at: 0.80, hold: 0.06, vel: 0.45),
            Note(.steel, [69], at: 0.87, hold: 0.06, vel: 0.45),
            Note(.steel, [64], at: 0.95, hold: 0.8, vel: 0.55),
            Note(.piano, [52, 59, 67], at: 0.96, hold: 0.8, vel: 0.35),
        ])

    // MARK: Oct 22 (later) -- the rest of the building
    //
    // One musical language -- soft attacks, gentle registers, mostly major and
    // modal colours, nothing longer than about two seconds -- but each its own
    // timbre, pitch and rhythm. Restraint first: many are a single note, a
    // chord or two notes; only a few are tiny phrases. All original; none
    // borrows a song. (They keep their own names.)

    /// The other ten Hallwaysians.
    static let otherHallwaysians: [Signature] = [
        Signature(id: "hw.bigfellow", name: "Big Fellow",
                  summary: "Two notes, low marimba: a warm C3 (long) settling down a fifth to F2. Round and slow. ~1.6 s.",
                  notes: [Note(.marimba, [48], at: 0.0, hold: 0.4, vel: 0.7),
                          Note(.marimba, [41, 53], at: 0.42, hold: 0.6, vel: 0.65)]),
        Signature(id: "hw.oldgent", name: "Old Gent",
                  summary: "One chord, piano, low and slowly rolled (F2-C3-A3-E4, an F major seventh), held like a sigh. ~2 s.",
                  notes: [Note(.piano, [41], at: 0.0, hold: 1.3, vel: 0.4),
                          Note(.piano, [48], at: 0.07, hold: 1.2, vel: 0.36),
                          Note(.piano, [57], at: 0.15, hold: 1.1, vel: 0.36),
                          Note(.piano, [64], at: 0.24, hold: 1.0, vel: 0.34)]),
        Signature(id: "hw.tiny", name: "Tiny",
                  summary: "Two notes, celesta, very high and quick: a grace E6 flicking up to G6. Almost a blink. ~1 s.",
                  notes: [Note(.celesta, [88], at: 0.0, hold: 0.05, vel: 0.45),
                          Note(.celesta, [91], at: 0.07, hold: 0.3, vel: 0.6)]),
        Signature(id: "hw.barrel", name: "Barrel",
                  summary: "A tiny phrase, low marimba and woodblock: D3, D3 (short, short) then a hooped A3 (long) -- a barrel rolling to a stop. ~1.4 s.",
                  notes: [Note(.marimba, [50], at: 0.0, hold: 0.1, vel: 0.6),
                          Note(.woodblock, [0], at: 0.0, hold: 0.05, vel: 0.22),
                          Note(.marimba, [50], at: 0.16, hold: 0.1, vel: 0.5),
                          Note(.marimba, [57, 45], at: 0.36, hold: 0.5, vel: 0.62),
                          Note(.woodblock, [0], at: 0.36, hold: 0.05, vel: 0.18)]),
        Signature(id: "hw.owl", name: "Owl",
                  summary: "Two notes, vibraphone with its slow shimmer: A4 falling a minor third to F#4, both long -- a soft hoot. ~2 s.",
                  notes: [Note(.vibes, [69], at: 0.0, hold: 0.45, vel: 0.55),
                          Note(.vibes, [66], at: 0.55, hold: 0.8, vel: 0.5)]),
        Signature(id: "hw.auntie", name: "Auntie",
                  summary: "One gracious rolled chord, harp: Eb4-G4-Bb4-Eb5 swept upward, left to ring. ~2 s.",
                  notes: [Note(.harp, [63], at: 0.0, hold: 1.2, vel: 0.5),
                          Note(.harp, [67], at: 0.06, hold: 1.1, vel: 0.48),
                          Note(.harp, [70], at: 0.12, hold: 1.0, vel: 0.48),
                          Note(.harp, [75], at: 0.18, hold: 1.0, vel: 0.52)]),
        Signature(id: "hw.pear", name: "Pear",
                  summary: "A tiny lilting phrase, kalimba: F5 (short), A5 (long), G5 (short, falling back). ~1.4 s.",
                  notes: [Note(.kalimba, [77], at: 0.0, hold: 0.12, vel: 0.5),
                          Note(.kalimba, [81], at: 0.14, hold: 0.35, vel: 0.58),
                          Note(.kalimba, [79], at: 0.52, hold: 0.4, vel: 0.45)]),
        Signature(id: "hw.mitts", name: "Mitts",
                  summary: "One chord, electric piano, low and soft: a D minor ninth (D3-F3-A3-E4) -- big copper hands set down gently. ~1.8 s.",
                  notes: [Note(.electricPiano, [50, 53, 57, 64], at: 0.0, hold: 1.0, vel: 0.5)]),
        Signature(id: "hw.clunk", name: "Clunk",
                  summary: "A bouncing ball, marimba: G3, G4, G3, G4 -- each bounce sooner and softer (0.22, 0.16, 0.11 s apart). ~1.3 s.",
                  notes: [Note(.marimba, [55], at: 0.0, hold: 0.1, vel: 0.7),
                          Note(.marimba, [67], at: 0.22, hold: 0.08, vel: 0.55),
                          Note(.marimba, [55], at: 0.38, hold: 0.08, vel: 0.42),
                          Note(.marimba, [67], at: 0.49, hold: 0.3, vel: 0.32)]),
        Signature(id: "hw.topper", name: "Topper",
                  summary: "A tiny march, bells over woodblock: C5, C5 (short, short), G5 (long and proud). ~1.5 s.",
                  notes: [Note(.bell, [72], at: 0.0, hold: 0.1, vel: 0.45),
                          Note(.woodblock, [0], at: 0.0, hold: 0.05, vel: 0.2),
                          Note(.bell, [72], at: 0.2, hold: 0.1, vel: 0.4),
                          Note(.woodblock, [0], at: 0.2, hold: 0.05, vel: 0.16),
                          Note(.bell, [79], at: 0.4, hold: 0.6, vel: 0.55),
                          Note(.woodblock, [0], at: 0.4, hold: 0.05, vel: 0.2)]),
    ]

    /// The Chair, the Butterfly, the Pottle.
    static let oddities: [Signature] = [
        Signature(id: "chair.1", name: "Chair",
                  summary: "One note, wooden: a low marimba E2-E3 octave with a soft woodblock knock -- a warm wooden 'tock'. ~1.2 s.",
                  notes: [Note(.marimba, [40, 52], at: 0.0, hold: 0.4, vel: 0.6),
                          Note(.woodblock, [0], at: 0.0, hold: 0.05, vel: 0.18)]),
        Signature(id: "butterfly", name: "Butterfly",
                  summary: "A shimmer, celesta, very soft: four quick rising notes B5-D#6-F#6-B6, the last left to ring -- wings. ~1.4 s.",
                  notes: [Note(.celesta, [83], at: 0.0, hold: 0.06, vel: 0.35),
                          Note(.celesta, [87], at: 0.06, hold: 0.06, vel: 0.38),
                          Note(.celesta, [90], at: 0.12, hold: 0.06, vel: 0.4),
                          Note(.celesta, [95], at: 0.18, hold: 0.6, vel: 0.45)]),
        Signature(id: "pottle.1", name: "Pottle",
                  summary: "Two notes, kalimba: a little 'pip' D5 then 'pop' A4, short and earthy. ~1.1 s.",
                  notes: [Note(.kalimba, [74], at: 0.0, hold: 0.1, vel: 0.55),
                          Note(.kalimba, [69], at: 0.18, hold: 0.35, vel: 0.5)]),
    ]

    /// The meeting's six, in the building.
    static let cast: [Signature] = [
        Signature(id: "cast.telephone", name: "Telephone",
                  summary: "Two notes, a soft desk bell struck twice on E6 (short gap) -- a gentle ring-ring, never a real phone. ~1.4 s.",
                  notes: [Note(.bell, [88], at: 0.0, hold: 0.12, vel: 0.4),
                          Note(.bell, [88], at: 0.16, hold: 0.5, vel: 0.36)]),
        Signature(id: "cast.viewmaster", name: "View-Master",
                  summary: "Two clicks, each with a celesta note: (click) C6, (click) E6 -- slides advancing. ~1.1 s.",
                  notes: [Note(.woodblock, [0], at: 0.0, hold: 0.05, vel: 0.22),
                          Note(.celesta, [84], at: 0.01, hold: 0.15, vel: 0.45),
                          Note(.woodblock, [0], at: 0.3, hold: 0.05, vel: 0.22),
                          Note(.celesta, [88], at: 0.31, hold: 0.4, vel: 0.5)]),
        Signature(id: "cast.stove", name: "Stove",
                  summary: "One chord, vibraphone, low and glowing: C3-G3-E4, held and shimmering like coals. ~2 s.",
                  notes: [Note(.vibes, [48, 55, 64], at: 0.0, hold: 1.1, vel: 0.5)]),
        Signature(id: "cast.mailbox", name: "Mailbox",
                  summary: "Two notes, marimba, rising: G4 (short) up to D5 (long) -- the flag going up. ~1.2 s.",
                  notes: [Note(.marimba, [67], at: 0.0, hold: 0.1, vel: 0.5),
                          Note(.marimba, [74, 62], at: 0.14, hold: 0.45, vel: 0.6)]),
        Signature(id: "cast.camera", name: "Camera",
                  summary: "One note with a click: a woodblock 'shutter' and a bright mandolin A5, short. ~0.9 s.",
                  notes: [Note(.woodblock, [0], at: 0.0, hold: 0.05, vel: 0.25),
                          Note(.mandolin, [81], at: 0.02, hold: 0.4, vel: 0.5)]),
        Signature(id: "cast.television", name: "Television",
                  summary: "One chord, electric piano with a soft vibraphone top: Eb major seventh (Eb4-G4-Bb4-D5) -- a warm glow. ~1.8 s.",
                  notes: [Note(.electricPiano, [63, 67, 70], at: 0.0, hold: 0.9, vel: 0.45),
                          Note(.vibes, [74], at: 0.03, hold: 0.9, vel: 0.35)]),
    ]

    /// Tinky and Juanita: heard in the Directory only (their story scenes keep their own voices).
    static let story: [Signature] = [
        Signature(id: "jeff", name: "Tinky",
                  summary: "Two notes, kalimba (tin tines), jaunty: G4 (short) up a fourth to C5 (long) -- 'come along'. ~1.2 s.",
                  notes: [Note(.kalimba, [67], at: 0.0, hold: 0.1, vel: 0.55),
                          Note(.kalimba, [72], at: 0.16, hold: 0.45, vel: 0.62)]),
        Signature(id: "juanita", name: "Juanita",
                  summary: "One note, a reception desk bell: a single soft A5 'ding'. ~1.4 s.",
                  notes: [Note(.bell, [81], at: 0.0, hold: 0.8, vel: 0.5)]),
    ]

    // MARK: Rendering

    static var rate: Float { MenagerieSound.rate }

    static func hz(_ midi: Float) -> Float { 440 * pow(2, (midi - 69) / 12) }

    /// The whole signature: every note mixed, a gentle top end, a soft fade, at most 3 s.
    /// `transpose` (semitones; Oct 22, morning): every pitch moved together -- the
    /// same rhythm, instruments and touch (the goodbye: -12, an octave down).
    static func render(_ s: Signature, transpose: Float = 0) -> [Float] {
        let end = min(3.0, (s.notes.map { $0.at + $0.hold }.max() ?? 0) + 0.7)
        var out = [Float](repeating: 0, count: Int(end * rate))
        var rng = MenagerieSound.Rand(seed: UInt64(s.id.count) &* 104_729 &+ 17)
        let notes = transpose == 0 ? s.notes : s.notes.map { n in
            Note(n.inst, n.midi.map { $0 + transpose }, at: n.at, hold: n.hold, vel: n.vel,
                 slideTo: n.slideTo.map { $0 + transpose }, slideAfter: n.slideAfter, slideTime: n.slideTime)
        }
        for note in notes {
            for m in note.midi {
                let x = voice(note.inst, midi: m, note: note, rng: &rng)
                let start = Int(note.at * rate)
                let gain = note.vel / Float(max(1, note.midi.count)).squareRoot()
                for i in 0..<x.count where start + i < out.count { out[start + i] += x[i] * gain }
            }
        }
        // A gentle low-pass (nothing harsh) and a fade over the last 0.2 s.
        var lp: Float = 0
        let k: Float = 1 - exp(-2 * .pi * 5_500 / rate)
        let fade = Int(0.2 * rate)
        for i in out.indices {
            lp += (out[i] - lp) * k
            let left = out.count - i
            out[i] = lp * (left < fade ? Float(left) / Float(fade) : 1)
        }
        return out
    }

    /// One note on one instrument (its full ring, damped when let go).
    static func voice(_ inst: Instrument, midi: Float, note: Note, rng: inout MenagerieSound.Rand) -> [Float] {
        let f = hz(midi)
        switch inst {
        case .piano:
            // Slightly stretched partials, the upper ones dying first; a felt-soft hammer.
            let decay = 1.4 * pow(220 / f, 0.4)
            let partials: [(Float, Float, Float)] = (1...8).map { n in
                let nf = Float(n)
                return (f * nf * (1 + 0.0004 * nf * nf).squareRoot(), pow(nf, -1.4) * (n == 1 ? 1 : 0.6 + 0.4 * note.vel),
                        decay / (1 + 0.45 * (nf - 1)))
            }
            return additive(partials, hold: note.hold, release: 0.09, attack: 0.006, tail: 1.2, noise: 0.03, rng: &rng)
        case .marimba:
            let partials: [(Float, Float, Float)] = [(f, 1, 0.5 * pow(400 / f, 0.3)), (f * 3.93, 0.22, 0.09), (f * 9.2, 0.05, 0.025)]
            return additive(partials, hold: 10, release: 0.1, attack: 0.004, tail: 0.9, noise: 0.02, rng: &rng)
        case .nylon, .steel, .mandolin, .bass:
            // A plucked string: the spectrum of a string plucked near one end (softer for nylon and bass).
            let position: Float, bright: Float, decay: Float, count: Int
            switch inst {
            case .nylon: position = 0.18; bright = 2.2; decay = 1.6; count = 10
            case .steel: position = 0.12; bright = 1.7; decay = 1.8; count = 14
            case .mandolin: position = 0.1; bright = 1.6; decay = 0.7; count = 12
            default: position = 0.25; bright = 2.4; decay = 0.9; count = 6
            }
            let partials: [(Float, Float, Float)] = (1...count).map { n in
                let nf = Float(n)
                return (f * nf, abs(sin(.pi * nf * position)) / pow(nf, bright) * 3, decay / (1 + 0.3 * (nf - 1)))
            }
            let slide = note.slideTo.map { (ratio: hz($0) / f, after: note.slideAfter, time: note.slideTime) }
            return additive(partials, hold: note.hold, release: 0.07, attack: 0.003, tail: 1.1, noise: 0.015, slide: slide, rng: &rng)
        case .electricPiano:
            // A tine piano (two-operator FM): bright at the strike, mellowing.
            let n = Int((note.hold + 0.9) * rate)
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Float(i) / rate
                let index = 1.4 * exp(-t / 0.22) + 0.25
                let env = exp(-t / 1.3) * min(1, t / 0.005) * damp(t, hold: note.hold, release: 0.12)
                let w: Float = 2 * .pi * f * t
                let body: Float = sin(w + index * sin(w)) * env
                let tine: Float = 0.08 * sin(7 * w) * exp(-t / 0.05)
                out[i] = body + tine
            }
            return out
        case .bell:
            let partials: [(Float, Float, Float)] = [(f, 1, 1.1), (f * 2.76, 0.35, 0.4), (f * 5.4, 0.12, 0.15)]
            return additive(partials, hold: 10, release: 0.2, attack: 0.003, tail: 1.2, noise: 0, rng: &rng)
        case .woodblock:
            let partials: [(Float, Float, Float)] = [(1_150, 1, 0.035), (1_820, 0.4, 0.02)]
            return additive(partials, hold: 10, release: 0.05, attack: 0.002, tail: 0.15, noise: 0.15, rng: &rng)
        case .vibes:
            // Soft-mallet metal bars, with the vibraphone's slow shimmer.
            let partials: [(Float, Float, Float)] = [(f, 1, 1.6), (f * 4, 0.12, 0.3), (f * 10, 0.025, 0.06)]
            var x = additive(partials, hold: note.hold, release: 0.25, attack: 0.006, tail: 1.4, noise: 0, rng: &rng)
            for i in x.indices { x[i] *= 1 - 0.22 * (0.5 + 0.5 * sin(2 * .pi * 5.2 * Float(i) / rate)) }
            return x
        case .kalimba:
            // Thumb-plucked tines: a round tone, a quick bright overtone, a soft tick.
            let partials: [(Float, Float, Float)] = [(f, 1, 0.9 * pow(500 / f, 0.25)), (f * 5.95, 0.16, 0.06), (f * 2.01, 0.08, 0.25)]
            return additive(partials, hold: note.hold, release: 0.15, attack: 0.003, tail: 1.0, noise: 0.02, rng: &rng)
        case .harp:
            let partials: [(Float, Float, Float)] = (1...8).map { n in
                let nf = Float(n)
                return (f * nf, abs(sin(.pi * nf * 0.3)) / pow(nf, 1.9) * 3, 2.2 / (1 + 0.35 * (nf - 1)))
            }
            return additive(partials, hold: note.hold, release: 0.3, attack: 0.004, tail: 1.3, noise: 0.01, rng: &rng)
        case .celesta:
            let partials: [(Float, Float, Float)] = [(f, 1, 0.8), (f * 2, 0.22, 0.3), (f * 4, 0.06, 0.1)]
            return additive(partials, hold: note.hold, release: 0.2, attack: 0.004, tail: 0.9, noise: 0.008, rng: &rng)
        }
    }

    /// The let-go: full until `hold`, then a quick (but never clicking) fall.
    static func damp(_ t: Float, hold: Float, release: Float) -> Float {
        t <= hold ? 1 : exp(-(t - hold) / release)
    }

    /// Decaying partials (Hz, amplitude, decay s) with a soft attack, a release
    /// after `hold`, a whisper of strike noise, and an optional slide.
    static func additive(_ partials: [(Float, Float, Float)], hold: Float, release: Float, attack: Float, tail: Float,
                         noise: Float, slide: (ratio: Float, after: Float, time: Float)? = nil,
                         rng: inout MenagerieSound.Rand) -> [Float] {
        let length = min(hold, 3) + tail
        let n = Int(length * rate)
        var out = [Float](repeating: 0, count: n)
        let top = rate * 0.45
        for (freq, amp, decay) in partials where freq < top && amp > 0.0005 {
            var phase: Float = 0
            let fall = exp(-1 / (decay * rate))
            var level = amp
            for i in 0..<n {
                var fi = freq
                if let s = slide {
                    let t = Float(i) / rate
                    let u = min(1, max(0, (t - s.after) / s.time))
                    fi = freq * (1 + (s.ratio - 1) * (u * u * (3 - 2 * u)))
                }
                phase += 2 * .pi * fi / rate
                if phase > 2 * .pi { phase -= 2 * .pi }
                out[i] += sin(phase) * level
                level *= fall
                if level < 0.00001 { break }
            }
        }
        var lp: Float = 0
        for i in 0..<n {
            let t = Float(i) / rate
            if noise > 0, t < 0.02 {
                lp += ((rng.unit() * 2 - 1) - lp) * 0.3
                out[i] += lp * noise * exp(-t / 0.004)
            }
            out[i] *= min(1, t / attack) * damp(t, hold: hold, release: release)
        }
        return out
    }
}
