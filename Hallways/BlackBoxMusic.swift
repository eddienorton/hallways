import Foundation

// MARK: - The Black Box's music (Oct 12)
//
// A small procedural composer and synthesizer. Each performance is a short
// original piece in one of four characters -- a bouncy pop tune, a waltz, a
// bossa nova, or a minor-key "spy" swing -- with a real melody (motif,
// sequence, half cadence, repeat, climax, cadence home), a bass line, a
// comping keyboard part, and light percussion, then rendered offline to a
// mono WAV that plays through SceneKit's positional audio (CritterAudio:
// Mute, Settings silence, distance and walls all apply as for any critter).
//
// Deterministic: the same seed always makes the same piece. Every random
// choice is an integer draw from the game's SplitMix64 generator, so the
// Python reference (CharacterModels/BlackBox/music/compose.py) produces the very
// same notes for a seed -- that is how the tunes were auditioned.
//
// Nothing here touches the main actor: compose() and render() run on a
// background queue while the box "thinks".

nonisolated enum BlackBoxMusic {
    static let sampleRate = 44_100

    nonisolated enum Style: String, CaseIterable, Sendable { case bounce, waltz, bossa, spy }
    nonisolated enum Kind: Sendable { case lead, keys, bass, drum }
    nonisolated enum Inst: String, Sendable {
        case square, whistle, marimba, bell, vibes, epiano, pluck, upright
        case kick, snare, hat, brush, click, rim
    }

    nonisolated struct Note: Sendable {
        var tick: Int
        var dur: Int
        var kind: Kind
        var inst: Inst
        var midi: Int
        var vel: Float
    }

    nonisolated struct TimedNote: Sendable {
        var start: Double
        var dur: Double
        var midi: Int
        var vel: Float
    }

    /// One composed piece. Bars: 0 = the count-in, 1...8 = the tune,
    /// 9 = the ending (a button or a little flourish). Ticks are sixteenths.
    nonisolated struct Piece: Sendable {
        var seed: UInt64
        var style: Style
        var meter: Int                 // beats per bar (4 or 3)
        var bpm: Int
        var swing: Int                 // percent of a beat for the off-beat eighth; 0 = straight
        var tonic: Int                 // melody tonic (MIDI)
        var lead: Inst
        var flourish: Bool             // waltz/bossa end on an arpeggio; the others on a hit
        var notes: [Note]
        var ticksPerBar: Int { 4 * meter }
        var secondsPerBeat: Double { 60.0 / Double(bpm) }

        /// Seconds from the start of the piece to grid `tick`.
        func time(ofTick tick: Int) -> Double {
            let beat = BlackBoxMusic.floorDiv(tick, 4)
            let sub = tick - beat * 4
            var frac = Double(sub) / 4.0
            if swing != 0 && sub == 2 { frac = Double(swing) / 100.0 }
            return (Double(beat) + frac) * secondsPerBeat
        }
        func barStart(_ bar: Int) -> Double { time(ofTick: bar * ticksPerBar) }
        /// The final hit / last downbeat (bar 9).
        var endingTime: Double { barStart(9) }
        /// When the music has fully stopped ringing (the WAV's length).
        var totalDuration: Double { barStart(9) + 3.0 }
        /// Melody notes as (start, duration, midi, velocity), in time order.
        var melodyNotes: [TimedNote] {
            var out: [TimedNote] = []
            for note in notes where note.kind == .lead {
                let start = time(ofTick: note.tick)
                out.append(TimedNote(start: start, dur: time(ofTick: note.tick + note.dur) - start, midi: note.midi, vel: note.vel))
            }
            out.sort { $0.start < $1.start }
            return out
        }
    }

    // MARK: Random (SplitMix64, identical to MenagerieSound.Rand)

    nonisolated struct Dice {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x2545F4914F6CDD1D }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
        mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
        mutating func weighted<T>(_ pairs: [(T, Int)]) -> T {
            let total = pairs.reduce(0) { $0 + $1.1 }
            var r = int(total)
            for (value, weight) in pairs {
                if r < weight { return value }
                r -= weight
            }
            return pairs[pairs.count - 1].0
        }
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
    }
    static func floorMod(_ a: Int, _ b: Int) -> Int { a - floorDiv(a, b) * b }

    // MARK: Theory tables

    static let major = [0, 2, 4, 5, 7, 9, 11]
    static let minor = [0, 2, 3, 5, 7, 8, 10]

    /// Chord name -> (bass pitch class, chord pitch classes), relative to the tonic.
    static let chords: [String: (bass: Int, pcs: [Int])] = [
        "I": (0, [0, 4, 7]), "ii": (2, [2, 5, 9]), "iii": (4, [4, 7, 11]), "IV": (5, [5, 9, 0]),
        "V": (7, [7, 11, 2]), "vi": (9, [9, 0, 4]), "V7": (7, [7, 11, 2, 5]), "III7": (4, [4, 8, 11, 2]),
        "VI7": (9, [9, 1, 4, 7]), "Imaj7": (0, [0, 4, 7, 11]), "ii7": (2, [2, 5, 9, 0]), "iii7": (4, [4, 7, 11, 2]),
        "IVmaj7": (5, [5, 9, 0, 4]), "iv6": (5, [5, 8, 0, 2]), "I6": (0, [0, 4, 7, 9]),
        "i": (0, [0, 3, 7]), "iM7": (11, [0, 3, 7, 11]), "i7": (10, [0, 3, 7, 10]), "i6": (9, [0, 3, 7, 9]),
        "iv": (5, [5, 8, 0]), "VI": (8, [8, 0, 3]), "iv7": (5, [5, 8, 0, 3]), "VImaj7": (8, [8, 0, 3, 7]),
    ]

    static let progressions: [Style: [[[String]]]] = [
        .bounce: [
            [["I"], ["vi"], ["IV"], ["V"], ["I"], ["vi"], ["ii", "V"], ["I"]],
            [["I"], ["IV"], ["I"], ["V"], ["I"], ["IV"], ["V"], ["I"]],
            [["I"], ["III7"], ["vi"], ["V"], ["IV"], ["I"], ["ii", "V"], ["I"]],
            [["I"], ["iii"], ["IV"], ["V"], ["vi"], ["IV"], ["ii", "V"], ["I"]],
        ],
        .waltz: [
            [["I"], ["IV"], ["I"], ["V7"], ["I"], ["IV"], ["V7"], ["I"]],
            [["I"], ["vi"], ["ii"], ["V7"], ["I"], ["III7"], ["ii"], ["V7"]],
            [["I"], ["I"], ["V7"], ["V7"], ["V7"], ["V7"], ["I"], ["I"]],
        ],
        .bossa: [
            [["Imaj7"], ["VI7"], ["ii7"], ["V7"], ["Imaj7"], ["VI7"], ["ii7", "V7"], ["Imaj7"]],
            [["Imaj7"], ["IVmaj7"], ["iii7"], ["VI7"], ["ii7"], ["iv6"], ["ii7", "V7"], ["Imaj7"]],
            [["Imaj7"], ["ii7"], ["iii7"], ["V7"], ["IVmaj7"], ["iv6"], ["iii7", "VI7"], ["ii7", "V7"]],
        ],
        .spy: [
            [["i"], ["iM7"], ["i7"], ["i6"], ["iv"], ["VI"], ["V7"], ["i"]],
            [["i"], ["iv"], ["i"], ["V7"], ["VI"], ["iv"], ["V7"], ["i"]],
            [["i"], ["VI"], ["iv7"], ["V7"], ["i"], ["VI"], ["iv", "V7"], ["i"]],
        ],
    ]

    nonisolated struct StyleSpec {
        var meter: Int
        var bpm: (Int, Int)
        var swing: Int
        var minor: Bool
        var leads: [Inst]
        var cells: [Character]
        var comp: [String]
        var bass: Inst
        var bassPattern: String
        var drums: String
    }

    static func spec(_ style: Style) -> StyleSpec {
        switch style {
        case .bounce:
            return StyleSpec(meter: 4, bpm: (112, 128), swing: 0, minor: false, leads: [.square, .marimba, .whistle],
                             cells: Array("acbfgi"), comp: ["offbeat", "push"], bass: .pluck, bassPattern: "pop", drums: "pop")
        case .waltz:
            return StyleSpec(meter: 3, bpm: (132, 150), swing: 0, minor: false, leads: [.bell, .whistle, .vibes],
                             cells: Array("abcdef"), comp: ["waltz"], bass: .upright, bassPattern: "waltz", drums: "none")
        case .bossa:
            return StyleSpec(meter: 4, bpm: (96, 108), swing: 0, minor: false, leads: [.whistle, .vibes, .marimba],
                             cells: Array("beidh"), comp: ["bossa"], bass: .upright, bassPattern: "bossa", drums: "bossa")
        case .spy:
            return StyleSpec(meter: 4, bpm: (118, 134), swing: 64, minor: true, leads: [.vibes, .square],
                             cells: Array("cfghb"), comp: ["spy"], bass: .upright, bassPattern: "walk", drums: "brush")
        }
    }

    static let majorKeys = [0, 2, 3, 5, 7, 9, 10]
    static let minorKeys = [9, 2, 4, 7, 0]

    typealias Cell = [(Int, Int)]                       // (tick, duration)
    static let cells4: [Character: Cell] = [
        "a": [(0, 4), (4, 4), (8, 4), (12, 4)],
        "b": [(0, 6), (6, 2), (8, 4), (12, 4)],
        "c": [(0, 2), (2, 2), (4, 4), (8, 2), (10, 2), (12, 4)],
        "d": [(0, 4), (4, 4), (8, 8)],
        "e": [(0, 6), (6, 6), (12, 4)],
        "f": [(0, 2), (2, 4), (6, 2), (8, 4), (12, 4)],
        "g": [(0, 4), (4, 2), (6, 2), (8, 4), (12, 2), (14, 2)],
        "h": [(2, 2), (4, 2), (6, 2), (8, 4), (12, 4)],
        "i": [(0, 6), (6, 2), (8, 6), (14, 2)],
    ]
    static let cells3: [Character: Cell] = [
        "a": [(0, 4), (4, 4), (8, 4)],
        "b": [(0, 6), (6, 2), (8, 4)],
        "c": [(0, 8), (8, 4)],
        "d": [(0, 4), (4, 2), (6, 2), (8, 4)],
        "e": [(0, 2), (2, 2), (4, 4), (8, 4)],
        "f": [(0, 4), (4, 8)],
    ]

    // MARK: Composer

    typealias MNote = (tick: Int, dur: Int, deg: Int)

    /// Compose one piece. `style` forces a style; otherwise one is drawn
    /// that differs from `previous`.
    static func compose(seed: UInt64, style forced: Style? = nil, previous: Style? = nil) -> Piece {
        var rng = Dice(seed: seed)
        let style: Style
        if let forced {
            style = forced
        } else {
            let order: [Style] = [.bounce, .waltz, .bossa, .spy]
            style = rng.pick(order.filter { $0 != previous })
        }
        let st = spec(style)
        let meter = st.meter
        let bpm = st.bpm.0 + rng.int(st.bpm.1 - st.bpm.0 + 1)
        let isMinor = st.minor
        let keypc = rng.pick(isMinor ? minorKeys : majorKeys)
        let tonic = 60 + keypc
        var bassTonic = keypc + 36
        if bassTonic < 40 { bassTonic += 12 }
        let lead = rng.pick(st.leads)
        let comp = rng.pick(st.comp)
        let prog = rng.pick(progressions[style]!)
        let scale = isMinor ? minor : major
        let T = 4 * meter
        let strongEvery = meter == 4 ? T / 2 : T
        var notes: [Note] = []

        func barTick(_ bar: Int, _ tick: Int) -> Int { bar * T + tick }
        func chordAt(_ bar: Int, _ tick: Int) -> String {
            let names = prog[bar - 1]
            if names.count == 1 || tick < T / 2 { return names[0] }
            return names[1]
        }
        func melodyPC(_ deg: Int, _ chord: String) -> Int {
            let octave = floorDiv(deg, 7)
            let i = deg - octave * 7
            let pc = floorMod(octave * 12 + scale[i], 12)
            if isMinor && pc == 10 && (chord == "V7" || chord == "V") { return 11 }  // harmonic minor's leading tone
            return pc
        }
        func degToMidi(_ deg: Int, _ chord: String) -> Int {
            tonic + floorDiv(deg, 7) * 12 + melodyPC(deg, chord)
        }
        func isChordTone(_ deg: Int, _ chord: String) -> Bool {
            chords[chord]!.pcs.contains(melodyPC(deg, chord))
        }
        /// Nearest chord tone; ties follow the melody's direction and avoid
        /// repeating the previous note. direction >= 9: climb (at or above).
        func snap(_ deg: Int, _ chord: String, _ prev: Int? = nil, _ direction: Int = 0) -> Int {
            let order: [Int]
            if direction >= 9 { order = [0, 1, 2, 3, -1, -2] }
            else if direction >= 0 { order = [0, 1, -1, 2, -2, 3, -3] }
            else { order = [0, -1, 1, -2, 2, -3, 3] }
            for d in order {
                let g = deg + d
                if !isChordTone(g, chord) { continue }
                if let prev, direction != 0, g == prev { continue }
                return g
            }
            return deg
        }
        let LO = -3, HI = 9, CAP = 7

        // ---- Melody
        let cells = meter == 4 ? cells4 : cells3
        let keys = st.cells
        let r1 = rng.pick(keys)
        var r2 = r1
        for _ in 0..<6 {
            r2 = rng.pick(keys)
            if r2 != r1 { break }
        }
        let r3 = rng.chance(50) ? r1 : rng.pick(keys)

        func contour(_ n: Int) -> [Int] {
            var steps: [Int] = []
            var prev = 0
            for _ in 0..<max(0, n - 1) {
                let s: Int
                if abs(prev) >= 2 {
                    s = prev > 0 ? -1 : 1                                 // after a leap, step back
                } else {
                    s = rng.weighted([(-1, 30), (1, 30), (-2, 10), (2, 13), (0, 4), (3, 5), (-3, 4)])
                }
                steps.append(s)
                prev = s
            }
            return steps
        }

        func realize(_ bar: Int, _ rhythm: Cell, _ start: Int, _ steps: [Int], snapWeak: Bool = true) -> [MNote] {
            let top = bar == 7 ? HI : CAP
            var degs = [start]
            for s in steps { degs.append(degs[degs.count - 1] + s) }
            while degs.max()! > top { degs = degs.map { $0 - 1 } }
            while degs.min()! < LO { degs = degs.map { $0 + 1 } }
            var out: [MNote] = []
            var prev: Int? = nil
            for i in 0..<min(rhythm.count, degs.count) {
                let (tick, dur) = rhythm[i]
                var d = degs[i]
                let ch = chordAt(bar, tick)
                let strong = tick % strongEvery == 0
                let onBeat = tick % 4 == 0
                let step = i == 0 ? 0 : steps[i - 1]
                if strong || dur >= 6 || (onBeat && snapWeak && rng.chance(55)) {
                    d = snap(d, ch, prev, step)
                }
                out.append((tick, dur, d))
                prev = d
            }
            return out
        }

        let s1 = rng.weighted([(4, 4), (2, 4), (0, 2), (7, 1)])
        let m1 = contour(cells[r1]!.count)
        let m2 = contour(cells[r2]!.count)
        var melody = [[MNote]](repeating: [], count: 9)
        melody[1] = realize(1, cells[r1]!, s1, m1)
        let last = melody[1][melody[1].count - 1].deg
        let s2 = last + rng.pick([-1, 1, 2, -2])
        melody[2] = realize(2, cells[r2]!, s2, m2)
        let shift = rng.pick([2, 1, -1, 3, 2])
        melody[3] = realize(3, cells[r1]!, s1 + shift, m1, snapWeak: false)

        // Bar 4: half cadence -- approach a chord tone of the dominant, hold it.
        let ch4 = chordAt(4, 0)
        let prev3 = melody[3][melody[3].count - 1].deg
        let target = snap(prev3 + rng.pick([-1, 1, -2, 0]), ch4)
        let cads4: [Cell] = [[(0, 4), (4, 4), (8, 8)], [(0, 12)], [(0, 8), (12, 2), (14, 2)]]
        let cads3: [Cell] = [[(0, 8), (8, 4)], [(0, 12)]]
        let cad: Cell = rng.pick(meter == 4 ? cads4 : cads3)
        if cad.count == 3 && cad[2].0 == 8 {
            let direction = rng.chance(60) ? 1 : -1
            melody[4] = [(0, 4, target + 2 * direction), (4, 4, target + direction), (8, 8, target)]
        } else if cad.count == 3 {
            let first = melody[1][0].deg
            melody[4] = [(0, 8, target), (12, 2, first - 2), (14, 2, first - 1)]
        } else if cad.count == 2 {
            melody[4] = [(0, 8, target), (8, 4, snap(target - 1, ch4))]
        } else {
            melody[4] = [(0, 12, target)]
        }
        // Bars 5-6: the antecedent again (re-fitted to the chords).
        melody[5] = melody[1].map { n -> MNote in (n.tick, n.dur, n.tick % strongEvery == 0 ? snap(n.deg, chordAt(5, n.tick)) : n.deg) }
        melody[6] = melody[2].map { n -> MNote in
            (n.tick, n.dur, (n.tick % strongEvery == 0 || n.dur >= 6) ? snap(n.deg, chordAt(6, n.tick)) : n.deg)
        }
        // Bar 7: the climax -- the motif, higher.
        var peakSoFar = Int.min
        for b in 1...6 { for n in melody[b] { peakSoFar = max(peakSoFar, n.deg) } }
        let climb = rng.pick([2, 3, 4])
        var m7 = realize(7, cells[r3]!, s1 + climb, r3 == r1 ? m1 : contour(cells[r3]!.count))
        let top = m7.map { $0.deg }.max()!
        let want = min(HI, peakSoFar + 1)
        if top < want {
            let lift = want - top
            m7 = m7.map { n -> MNote in
                (n.tick, n.dur, (n.dur >= 6 || n.tick % strongEvery == 0) ? snap(n.deg + lift, chordAt(7, n.tick), nil, 9) : n.deg + lift)
            }
        }
        melody[7] = m7
        // Bar 8: home.
        let lastg = melody[7][melody[7].count - 1].deg
        let home = lastg >= 4 ? 7 : 0
        let tonicNames: Set<String> = ["I", "Imaj7", "i"]
        let endsOnTonic = tonicNames.contains(prog[7][0])
        melody[8] = endsOnTonic ? [(0, T, home)] : [(0, T, snap(lastg, chordAt(8, 0)))]

        var pickup = rng.chance(40)
        if pickup {
            let first = melody[1][0]
            if first.tick == 0 {
                melody[0] = rng.chance(50) ? [(T - 2, 2, first.deg - 1)] : [(T - 4, 2, first.deg - 2), (T - 2, 2, first.deg - 1)]
            } else {
                pickup = false
            }
        }

        for bar in 0...8 {
            for n in melody[bar] {
                let ch = bar >= 1 ? chordAt(bar, n.tick) : prog[0][0]
                let accent: Float = n.tick == 0 ? 1.0 : (n.tick % 4 == 0 ? 0.92 : 0.84)
                let vel = 0.9 * accent * Float(92 + rng.int(9)) / 100
                notes.append(Note(tick: barTick(bar, n.tick), dur: n.dur, kind: .lead, inst: lead, midi: degToMidi(n.deg, ch), vel: vel))
            }
        }

        // ---- Ending
        let flourish = style == .waltz || style == .bossa
        let homeChord = isMinor ? "i" : "I"
        if flourish {
            let arp = endsOnTonic ? [2, 4, 7, 9] : [0, 2, 4, 7]
            for (k, g) in arp.enumerated() {
                notes.append(Note(tick: barTick(9, 2 * k), dur: k < 3 ? 2 : 10, kind: .lead, inst: lead,
                                  midi: degToMidi(g, homeChord), vel: 0.62 + 0.05 * Float(k)))
            }
        } else {
            notes.append(Note(tick: barTick(9, 0), dur: 3, kind: .lead, inst: lead, midi: degToMidi(7, homeChord), vel: 0.95))
        }

        // ---- Bass
        func bassNote(_ pc: Int) -> Int {
            var m = bassTonic + pc
            while m > bassTonic + 7 { m -= 12 }
            return m
        }
        let lineCliche: Set<String> = ["iM7", "i7", "i6"]
        for bar in 1...8 {
            let names = prog[bar - 1]
            for half in 0..<(names.count == 2 ? 2 : 1) {
                let name = names[half]
                let chord = chords[name]!
                let root = bassNote(chord.bass)
                var fifth = lineCliche.contains(name) ? bassNote(7) : bassNote((chord.pcs[0] + 7) % 12)
                if fifth > root { fifth -= 12 }
                let nxt = bar < 8 ? prog[bar][0] : prog[0][0]
                let nroot = bassNote(chords[nxt]!.bass)
                let span = names.count == 1 ? T : T / 2
                let base = half * (T / 2)
                if bar == 8 {
                    notes.append(Note(tick: barTick(bar, base), dur: span, kind: .bass, inst: st.bass, midi: root, vel: 0.95))
                    continue
                }
                let pat: [(Int, Int, Int, Float)]
                switch st.bassPattern {
                case "pop":
                    pat = [(0, 4, root, 1.0), (6, 2, root, 0.7), (8, 4, fifth + 12 - root < 9 ? fifth + 12 : fifth, 0.85),
                           (12, 2, root, 0.75), (14, 2, nroot + (nroot < root ? 1 : -1), 0.7)]
                case "waltz":
                    pat = [(0, 4, bar % 2 == 1 ? root : fifth, 1.0)]
                case "bossa":
                    pat = [(0, 6, root, 1.0), (6, 2, fifth, 0.7), (8, 6, fifth, 0.85), (14, 2, root, 0.6)]
                default:                                                  // walking (spy)
                    var third = bassNote(chord.pcs[1])
                    if third < root { third += 12 }
                    let approach = nroot + (rng.chance(50) ? 1 : -1)
                    let second = rng.chance(50) ? third : fifth + 12
                    pat = [(0, 3, root, 1.0), (4, 3, second, 0.8), (8, 3, fifth + 12, 0.85), (12, 3, approach, 0.8)]
                }
                for (tick, dur, m, v) in pat {
                    if span < T && tick >= span { continue }
                    notes.append(Note(tick: barTick(bar, base + tick), dur: dur, kind: .bass, inst: st.bass, midi: m, vel: v))
                }
            }
        }
        notes.append(Note(tick: barTick(9, 0), dur: flourish ? 12 : 4, kind: .bass, inst: st.bass, midi: bassNote(0), vel: 1.0))

        // ---- Keys
        var center = Double(tonic - 10)
        func voicing(_ name: String) -> [Int] {
            var out: [Int] = []
            for pc in chords[name]!.pcs {
                let base = tonic - 12 + (pc % 12) - (tonic % 12)
                var best: Int? = nil
                for k in -2...2 {
                    let m = base + 12 * k
                    if best == nil || abs(Double(m) - center) < abs(Double(best!) - center) { best = m }
                }
                out.append(best!)
            }
            out = Array(Set(out)).sorted()
            center = (Double(out.reduce(0, +)) / Double(out.count)) * 0.5 + Double(tonic - 10) * 0.5
            return out
        }
        let compPatterns: [String: Cell] = [
            "offbeat": [(2, 2), (6, 2), (10, 2), (14, 2)],
            "push": [(0, 6), (6, 6), (12, 4)],
            "waltz": [(4, 3), (8, 3)],
            "bossaA": [(0, 3), (6, 3), (12, 2)],
            "bossaB": [(2, 3), (8, 3), (12, 3)],
            "spy": [(4, 2), (12, 2)],
        ]
        let keysInst: Inst = style == .waltz ? .bell : .epiano
        for bar in 1...8 {
            if bar == 8 {
                let names = prog[7]
                let span = T / names.count
                for (half, name) in names.enumerated() {
                    for m in voicing(name) {
                        notes.append(Note(tick: barTick(bar, half * span), dur: span, kind: .keys, inst: keysInst, midi: m, vel: 0.75))
                    }
                }
                continue
            }
            let pat = comp == "bossa" ? compPatterns[bar % 2 == 1 ? "bossaA" : "bossaB"]! : compPatterns[comp]!
            var voiced: [String: [Int]] = [:]
            for (tick, dur) in pat {
                let name = chordAt(bar, tick)
                if voiced[name] == nil { voiced[name] = voicing(name) }
                let accent: Float = tick % 4 == 0 ? 0.8 : 0.7
                for m in voiced[name]! {
                    notes.append(Note(tick: barTick(bar, tick), dur: dur, kind: .keys, inst: keysInst, midi: m, vel: accent))
                }
            }
        }
        let finalName = isMinor ? "i" : (style == .bossa ? "Imaj7" : "I")
        for m in voicing(finalName) {
            notes.append(Note(tick: barTick(9, 0), dur: flourish ? 12 : 4, kind: .keys, inst: keysInst, midi: m, vel: 0.8))
        }

        // ---- Drums. The count-in: the box taps the beats (a pickup replaces the last tap).
        func hit(_ bar: Int, _ tick: Int, _ inst: Inst, _ vel: Float) {
            notes.append(Note(tick: barTick(bar, tick), dur: 1, kind: .drum, inst: inst, midi: 0, vel: vel))
        }
        for beat in 0..<meter where !(pickup && beat == meter - 1) {
            hit(0, beat * 4, .click, beat == 0 ? 0.9 : 0.7)
        }
        for bar in 1...8 {
            switch st.drums {
            case "pop":
                hit(bar, 0, .kick, 1.0); hit(bar, 8, .kick, 1.0)
                if bar % 2 == 0 { hit(bar, 10, .kick, 0.7) }
                hit(bar, 4, .snare, 0.9); hit(bar, 12, .snare, 0.9)
                for tick in stride(from: 0, to: 16, by: 2) { hit(bar, tick, .hat, tick % 4 == 2 ? 0.8 : 0.5) }
            case "bossa":
                for tick in [0, 6, 8, 14] { hit(bar, tick, .kick, tick % 8 != 0 ? 0.55 : 0.7) }
                for tick in (bar % 2 == 1 ? [0, 6, 12] : [4, 10]) { hit(bar, tick, .rim, 0.8) }
                for tick in stride(from: 0, to: 16, by: 2) { hit(bar, tick, .hat, 0.45) }
            case "brush":
                hit(bar, 0, .kick, 0.6)
                hit(bar, 4, .brush, 0.9); hit(bar, 12, .brush, 0.9)
                for tick in [0, 4, 6, 8, 12, 14] { hit(bar, tick, .hat, tick % 4 != 0 ? 0.55 : 0.4) }
            default:
                break
            }
        }
        if !flourish {
            hit(9, 0, .kick, 1.0)
            hit(9, 0, .snare, 1.0)
        }
        return Piece(seed: seed, style: style, meter: meter, bpm: bpm, swing: st.swing, tonic: tonic, lead: lead,
                     flourish: flourish, notes: notes)
    }

    // MARK: Synthesizer

    private static let sr = Float(sampleRate)
    private static let twoPi = Float.pi * 2

    static func mtof(_ m: Int) -> Float { 440 * powf(2, Float(m - 69) / 12) }

    /// A tiny deterministic noise source (white, -1...1).
    private nonisolated struct NoiseSource {
        var dice: Dice
        mutating func white() -> Float { Float(dice.next() >> 40) / Float(1 << 23) - 1 }
    }

    @inline(__always) private static func gate(_ t: Float, _ dur: Float, _ rel: Float) -> Float {
        t <= dur ? 1 : max(0, 1 - (t - dur) / rel)
    }
    @inline(__always) private static func attack(_ t: Float, _ a: Float) -> Float { min(1, t / a) }

    /// One pitched note, unscaled by the mix level.
    private static func voice(_ inst: Inst, midi: Int, dur: Float, vel: Float, noise: inout NoiseSource) -> [Float] {
        let f = mtof(midi)
        switch inst {
        case .square:
            let rel: Float = 0.07
            let n = Int((dur + rel) * sr)
            var out = [Float](repeating: 0, count: n)
            var ph: Float = 0
            let harmonics = [1, 3, 5, 7, 9].filter { Float($0) * f <= 14_000 }
            for i in 0..<n {
                let t = Float(i) / sr
                let vib = 1 + 0.0045 * sinf(twoPi * 5.5 * t) * min(1, max(0, (t - 0.12) / 0.2))
                ph += twoPi * f * vib / sr
                if ph > 1_000 { ph -= twoPi * 159 }
                var y: Float = 0
                for h in harmonics { y += sinf(Float(h) * ph) / Float(h) * expf(-Float(h - 1) / 4) }
                let env = attack(t, 0.006) * (0.55 + 0.45 * expf(-t / 0.12)) * gate(t, dur, rel)
                out[i] = y * env * 0.75 * vel
            }
            return out
        case .whistle:
            let rel: Float = 0.09
            let n = Int((dur + rel) * sr)
            var out = [Float](repeating: 0, count: n)
            var ph: Float = 0
            var breath: Float = 0
            for i in 0..<n {
                let t = Float(i) / sr
                let vib = 1 + 0.006 * sinf(twoPi * 5.2 * t) * min(1, max(0, (t - 0.15) / 0.25))
                ph += twoPi * f * vib / sr
                if ph > 1_000 { ph -= twoPi * 159 }
                breath += 0.25 * (noise.white() - breath)
                var y = sinf(ph) + 0.12 * sinf(2 * ph) + 0.03 * sinf(3 * ph)
                y += breath * 0.12 * expf(-t / 0.08)
                let env = attack(t, 0.03) * (0.85 + 0.15 * expf(-t / 0.1)) * gate(t, dur, rel)
                out[i] = y * env * 0.8 * vel
            }
            return out
        case .marimba:
            let n = Int(min(dur + 0.6, 1.4) * sr)
            var out = [Float](repeating: 0, count: n)
            let tau = min(0.6, max(0.18, 0.5 * powf(440 / f, 0.4)))
            for i in 0..<n {
                let t = Float(i) / sr
                let ph = twoPi * f * t
                let y = sinf(ph) + 0.22 * sinf(3.93 * ph) * expf(-t / 0.04) + 0.06 * sinf(9.2 * ph) * expf(-t / 0.012)
                out[i] = y * attack(t, 0.002) * expf(-t / tau) * 0.95 * vel
            }
            return out
        case .bell:
            let held = min(dur, 1.2)
            let n = Int((held + 0.9) * sr)
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Float(i) / sr
                let ph = twoPi * f * t
                let y = sinf(ph + 1.4 * expf(-t / 0.05) * sinf(4 * ph)) + 0.12 * sinf(2 * ph) * expf(-t / 0.3)
                out[i] = y * attack(t, 0.002) * expf(-t / 0.75) * gate(t, held + 0.6, 0.25) * 0.8 * vel
            }
            return out
        case .vibes:
            let n = Int((dur + 0.25 + 0.3) * sr)
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Float(i) / sr
                let ph = twoPi * f * t
                let y = sinf(ph) + 0.15 * sinf(4 * ph) * expf(-t / 0.3) + 0.05 * sinf(10 * ph) * expf(-t / 0.02)
                let trem = 1 + 0.28 * sinf(twoPi * 5.2 * t)
                out[i] = y * trem * attack(t, 0.002) * expf(-t / 1.3) * gate(t, dur + 0.3, 0.25) * 0.8 * vel
            }
            return out
        case .epiano:
            let rel: Float = 0.12
            let n = Int((dur + rel) * sr)
            var out = [Float](repeating: 0, count: n)
            let tau = 1.6 * powf(261.6 / f, 0.4)
            for i in 0..<n {
                let t = Float(i) / sr
                let ph = twoPi * f * t
                let index = 1.3 * expf(-t / 0.25) + 0.25
                let y = sinf(ph + index * sinf(ph)) + 0.08 * sinf(14 * ph) * expf(-t / 0.015)
                out[i] = y * attack(t, 0.003) * expf(-t / tau) * gate(t, dur, rel) * 0.5 * vel
            }
            return out
        case .pluck:
            let rel: Float = 0.06
            let n = Int((dur + rel) * sr)
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Float(i) / sr
                let ph = twoPi * f * t
                let y = sinf(ph) + 0.7 * sinf(2 * ph) * expf(-t / 0.3) + 0.35 * sinf(3 * ph) * expf(-t / 0.15)
                out[i] = y * attack(t, 0.004) * expf(-t / 0.6) * gate(t, dur, rel) * 0.9 * vel
            }
            return out
        case .upright:
            let rel: Float = 0.05
            let n = Int((dur + rel) * sr)
            var out = [Float](repeating: 0, count: n)
            var ph: Float = 0
            for i in 0..<n {
                let t = Float(i) / sr
                ph += twoPi * f * (1 + 0.012 * expf(-t / 0.04)) / sr
                let y = sinf(ph) + 0.55 * sinf(2 * ph) + 0.25 * sinf(3 * ph) * expf(-t / 0.12)
                out[i] = y * attack(t, 0.006) * expf(-t / 0.5) * gate(t, dur, rel) * 0.95 * vel
            }
            return out
        default:
            return drum(inst, vel: vel, noise: &noise)
        }
    }

    private static func drum(_ inst: Inst, vel: Float, noise: inout NoiseSource) -> [Float] {
        func buffer(_ seconds: Float) -> [Float] { [Float](repeating: 0, count: Int(seconds * sr)) }
        switch inst {
        case .kick:
            var out = buffer(0.35)
            var ph: Float = 0
            for i in 0..<out.count {
                let t = Float(i) / sr
                ph += twoPi * (58 + 90 * expf(-t / 0.025)) / sr
                out[i] = (sinf(ph) * expf(-t / 0.14) + 0.25 * sinf(twoPi * 1_800 * t) * expf(-t / 0.004)) * attack(t, 0.002) * vel
            }
            return out
        case .snare:
            var out = buffer(0.3)
            // Band-pass (RBJ, 1.5 kHz, Q 0.9) on white noise, plus a little body.
            let w0 = twoPi * 1_500 / sr
            let alpha = sinf(w0) / (2 * 0.9)
            let a0 = 1 + alpha
            let b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cosf(w0) / a0, a2 = (1 - alpha) / a0
            var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
            for i in 0..<out.count {
                let t = Float(i) / sr
                let x = noise.white()
                let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x; y2 = y1; y1 = y
                out[i] = (y * 0.9 * expf(-t / 0.08) + 0.4 * sinf(twoPi * 190 * t) * expf(-t / 0.05)) * vel
            }
            return out
        case .hat:
            var out = buffer(0.08)
            var prev: Float = 0
            for i in 0..<out.count {
                let t = Float(i) / sr
                let x = noise.white()
                out[i] = (x - prev) * 0.5 * expf(-t / 0.02) * vel
                prev = x
            }
            return out
        case .brush:
            var out = buffer(0.3)
            var acc: Float = 0
            for i in 0..<out.count {
                let t = Float(i) / sr
                acc += 0.3 * (noise.white() - acc)
                out[i] = acc * attack(t, 0.012) * expf(-t / 0.09) * 1.4 * vel
            }
            return out
        case .click:
            var out = buffer(0.1)
            for i in 0..<out.count {
                let t = Float(i) / sr
                out[i] = (sinf(twoPi * 1_250 * t) * expf(-t / 0.018) + 0.4 * sinf(twoPi * 2_900 * t) * expf(-t / 0.008)) * vel
            }
            return out
        case .rim:
            var out = buffer(0.08)
            for i in 0..<out.count {
                let t = Float(i) / sr
                out[i] = (sinf(twoPi * 1_650 * t) * expf(-t / 0.012) + 0.3 * noise.white() * expf(-t / 0.004)) * vel
            }
            return out
        default:
            return []
        }
    }

    private static func level(_ note: Note) -> Float {
        switch note.kind {
        case .lead: return 0.30
        case .keys: return 0.11
        case .bass: return 0.28
        case .drum:
            switch note.inst {
            case .kick: return 0.22
            case .snare: return 0.10
            case .hat: return 0.05
            case .brush: return 0.08
            case .click: return 0.20
            case .rim: return 0.10
            default: return 0.1
            }
        }
    }

    /// A small Schroeder room (four damped combs, two all-passes).
    private static func reverb(_ x: [Float], wet: Float = 0.16) -> [Float] {
        let n = x.count
        var sum = [Float](repeating: 0, count: n)
        for d in [1_116, 1_188, 1_277, 1_356] {
            var buf = [Float](repeating: 0, count: d)
            var idx = 0
            var filt: Float = 0
            for i in 0..<n {
                let o = buf[idx]
                filt = o * 0.75 + filt * 0.25
                buf[idx] = x[i] + filt * 0.78
                idx += 1; if idx == d { idx = 0 }
                sum[i] += o
            }
        }
        for d in [556, 441] {
            var buf = [Float](repeating: 0, count: d)
            var idx = 0
            for i in 0..<n {
                let b = buf[idx]
                let input = sum[i]
                buf[idx] = input + b * 0.5
                idx += 1; if idx == d { idx = 0 }
                sum[i] = -input + b
            }
        }
        var out = x
        for i in 0..<n { out[i] += sum[i] * wet * 0.25 }
        return out
    }

    /// Render a piece to mono samples (-1...1).
    static func render(_ piece: Piece) -> [Float] {
        let total = piece.totalDuration
        var buf = [Float](repeating: 0, count: Int(total * Double(sampleRate)))
        var noise = NoiseSource(dice: Dice(seed: piece.seed ^ 0x5EED))
        let fadeCount = Int(0.008 * sr)
        for note in piece.notes {
            let start = piece.time(ofTick: note.tick)
            var y: [Float]
            if note.kind == .drum {
                y = drum(note.inst, vel: note.vel, noise: &noise)
            } else {
                var dur = Float(piece.time(ofTick: note.tick + note.dur) - start)
                if note.kind == .bass { dur *= 0.9 } else if note.kind == .keys { dur *= 0.85 }
                y = voice(note.inst, midi: note.midi, dur: dur, vel: note.vel, noise: &noise)
            }
            guard !y.isEmpty else { continue }
            let gain = level(note)
            let k = min(y.count, fadeCount)
            for j in 0..<k { y[y.count - k + j] *= 1 - Float(j) / Float(max(1, k - 1)) }
            let offset = Int(start * Double(sampleRate))
            let count = min(y.count, buf.count - offset)
            if count <= 0 { continue }
            for j in 0..<count { buf[offset + j] += y[j] * gain }
        }
        // Phones can't play the deep sub-bass: a gentle 80 Hz high-pass keeps
        // the loudness for what they can play.
        let rc: Float = 1 / (twoPi * 80)
        let a = rc / (rc + 1 / sr)
        var prevX: Float = 0, prevY: Float = 0
        for i in 0..<buf.count {
            prevY = a * (prevY + buf[i] - prevX)
            prevX = buf[i]
            buf[i] = prevY
        }
        buf = reverb(buf)
        var peak: Float = 1e-9
        for v in buf { peak = max(peak, abs(v)) }
        let norm = 0.9 / peak
        let shape = tanhf(1.1)
        for i in 0..<buf.count { buf[i] = tanhf(buf[i] * norm * 1.1) / shape }
        return buf
    }

    /// Mono 16-bit PCM WAV.
    static func wavData(_ samples: [Float]) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count { pcm[i] = Int16(max(-1, min(1, samples[i])) * 32_000).littleEndian }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
