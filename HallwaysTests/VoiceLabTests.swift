import Foundation
import Testing
@testable import Hallways

/// Oct 25 (PP 6) -- THE VOICES LAB: file names, the Night Shift Waltz's harmony data, and where and on what
/// note each voice falls. Data and arithmetic only: whether it sounds good is the listening test.
@MainActor
struct VoiceLabTests {
    private let barFrames: Int64 = 66_150          // 3 beats x 0.5 s x 44 100
    private let beatFrames: Int64 = 22_050
    private let loopFrames: Int64 = 3_175_200     // lab-nightshift.json: 48 bars

    private func parsed(_ file: String) -> String? {
        VoiceSample.parse(file).map { "\($0.name)|" + ($0.note.map(String.init) ?? "nil") }
    }

    @Test func fileNamesSayTheNameAndTheNote() {
        #expect(parsed("voice-doo-A3.wav") == "doo|57")
        #expect(parsed("voice-meep-E5.wav") == "meep|76")
        #expect(parsed("voice-bum-A2.WAV") == "bum|45")
        #expect(parsed("voice-baby.wav") == "baby|nil")
        #expect(parsed("voice-hey-you.wav") == "hey-you|nil")         // ("you" isn't a note)
        #expect(parsed("voice-la-C#4.aif") == "la|61")
        #expect(parsed("voice-la-Cs4.caf") == "la|61")
        #expect(parsed("voice-oh-Bb2.m4a") == "oh|46")
        #expect(VoiceSample.parse("voice-.wav") == nil)
        #expect(VoiceSample.parse("doo-A3.wav") == nil)
        #expect(VoiceSample.parse("voice-doo.mp3") == nil)
        #expect(VoiceSample.noteName(57) == "A3" && VoiceSample.noteName(60) == "C4" && VoiceSample.noteName(46) == "Bb2")
    }

    @Test func thePlaceholdersAreBundled() {
        let names = Set(VoiceSample.bundled().map(\.id))
        for f in ["voice-doo-A3.wav", "voice-meep-E5.wav", "voice-bum-A2.wav", "voice-baby.wav"] {
            #expect(names.contains(f), "\(f)")
        }
    }

    @Test func theHarmonyIsTheSongsOwnFortyEightBars() throws {
        let h = try #require(VoiceHarmony.bundled(VoiceLab.harmonyFile))
        let c = try #require(StemComposition.bundled().first { $0.id == VoiceLab.compositionID })
        #expect(h.composition == c.id && h.beatsPerBar == c.beatsPerBar)
        #expect(h.bars.count == c.loopBars && c.loopBars == 48)
        #expect(c.loopFrames == loopFrames && Int64((c.barSeconds * c.sampleRate).rounded()) == barFrames)
        // A (bars 1-16), B (17-32), A (33-48) -- original1.py's PROG_A / PROG_B
        #expect(h.bars[0].chord == "Am" && h.bars[3].chord == "E7" && h.bars[16].chord == "Fmaj7" && h.bars[32].chord == "Am")
        #expect(h.bars[0].tones.prefix(3) == [9, 0, 4])                                   // A C E
        #expect(h.bars[3].tones.prefix(3) == [4, 8, 11])                                  // E G# B
        for i in 0..<16 { #expect(h.bars[i] == h.bars[i + 32]) }
    }

    @Test func oneVoiceEveryFourBarsOnTheDownbeat() {
        let e = VoicePlan.events(bars: [], loopBars: 48, interval: 4, beat: 0, pitched: false, source: 57,
                                 barFrames: barFrames, beatFrames: beatFrames)
        #expect(e.count == 12)
        #expect(e.map(\.bar) == Array(stride(from: 0, to: 48, by: 4)))
        #expect(e.allSatisfy { $0.shift == 0 && $0.note == 57 && $0.frame == Int64($0.bar) * barFrames })
        let two = VoicePlan.events(bars: [], loopBars: 48, interval: 2, beat: 2, pitched: false, source: nil, barFrames: barFrames, beatFrames: beatFrames)
        #expect(two.count == 24 && two[1].frame == 2 * barFrames + 2 * beatFrames && two[1].note == nil)
        #expect(VoicePlan.events(bars: [], loopBars: 48, interval: 8, beat: 1, pitched: false, source: 57, barFrames: barFrames, beatFrames: beatFrames).count == 6)
    }

    @Test func pitchedVoicesSingTonesOfTheirBarsChordWithinAModestRange() throws {
        let h = try #require(VoiceHarmony.bundled(VoiceLab.harmonyFile))
        for source in [45, 57, 64, 76] {                                                 // A2 A3 E4 E5
            for interval in VoiceLab.intervals {
                let e = VoicePlan.events(bars: h.bars, loopBars: 48, interval: interval, beat: 0, pitched: true, source: source,
                                         barFrames: barFrames, beatFrames: beatFrames)
                for v in e {
                    let n = try #require(v.note)
                    #expect(VoicePlan.range.contains(v.shift))
                    #expect(h.bars[v.bar].tones.prefix(3).contains(((n % 12) + 12) % 12), "bar \(v.bar + 1) \(v.chord): \(n)")
                    #expect(v.chord == h.bars[v.bar].chord)
                }
            }
        }
        // A3 over bars 1, 5, 9, 13 (Am, Am, Dm7, Bm7b5): root, third, fifth, third -> A3, C4, A3, D4
        let e = VoicePlan.events(bars: h.bars, loopBars: 48, interval: 4, beat: 0, pitched: true, source: 57, barFrames: barFrames, beatFrames: beatFrames)
        #expect(e.prefix(4).map(\.note) == [57, 60, 57, 62])
        // the same every time (deterministic)
        #expect(e == VoicePlan.events(bars: h.bars, loopBars: 48, interval: 4, beat: 0, pitched: true, source: 57, barFrames: barFrames, beatFrames: beatFrames))
        // pitch off, or no harmony: as recorded
        let off = VoicePlan.events(bars: h.bars, loopBars: 48, interval: 4, beat: 0, pitched: false, source: 57, barFrames: barFrames, beatFrames: beatFrames)
        #expect(off.allSatisfy { $0.shift == 0 })
    }

    @Test func theScheduleFollowsTheEndlessLoopWithoutGapsOrRepeats() {
        let e = VoicePlan.events(bars: [], loopBars: 48, interval: 4, beat: 0, pitched: false, source: 57, barFrames: barFrames, beatFrames: beatFrames)
        // Polled in 0.35 s windows (as VoiceTrack does) across three passes: every event once, at its exact frame.
        var all: [Int64] = []
        var from: Int64 = 0
        let step: Int64 = 15_435
        while from < 3 * loopFrames {
            all += VoiceTrack.frames(of: e, loopFrames: loopFrames, from: from, to: from + step).map(\.frame)
            from += step
        }
        let expected = (0..<3).flatMap { p in e.map { Int64(p) * loopFrames + $0.frame } }
        #expect(all.filter { $0 < 3 * loopFrames } == expected)
    }
}
