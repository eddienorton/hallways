import Foundation
import Testing
@testable import Hallways

/// Oct 25 (PP 7) -- FLOOR SOUNDTRACKS: the data (floor-soundtracks.json and the songs' chord maps), who plays
/// which track, who sings with which voice, and when the voices sing. Data and arithmetic only: whether it
/// sounds good is the walk-around listening test.
@MainActor
struct FloorSoundtrackTests {
    private func config() throws -> SoundtrackConfig { try #require(SoundtrackConfig.bundled()) }
    private func manifest(_ id: String) throws -> StemComposition { try #require(StemComposition.bundled().first { $0.id == id }) }
    private func lineup(_ song: String, _ followers: [String]) throws -> SoundtrackLineup {
        let s = try #require(try config().songs[song])
        return SoundtrackLineup.make(partIDs: try manifest(song).parts.map(\.id), song: s, followers: followers,
                                     instrument: { BandInstruments.byResident[$0] })
    }

    // MARK: The data

    @Test func floorsFourToSevenPlayTheirSongsAndOneToThreeDont() throws {
        let c = try config()
        #expect(c.song(forFloor: 4) == "going-up")
        #expect(c.song(forFloor: 5) == "night-shift-waltz")
        #expect(c.song(forFloor: 6) == "lantern-room")
        #expect(c.song(forFloor: 7) == "rua-das-lampadas")
        for f in [1, 2, 3] { #expect(c.song(forFloor: f) == nil, "floor \(f)") }
        #expect(c.song(forFloor: nil) == nil)
    }

    @Test func everySongsDataNamesItsRealTracksAndRealInstruments() throws {
        let c = try config()
        for (id, song) in c.songs {
            let m = try manifest(id)
            let tracks = Set(m.parts.map(\.id))
            #expect(!song.baseline.isEmpty && song.baseline.count < tracks.count, "\(id): a baseline, with tracks left for followers")
            #expect(Set(song.baseline).isSubset(of: tracks), "\(id) baseline")
            #expect(Set(song.parts.keys) == tracks, "\(id): every track listed (none forgotten, none invented)")
            for (_, insts) in song.parts { for i in insts { #expect(BandInstruments.labels[i] != nil, "\(id): \(i)") } }
            #expect(song.voice.slotBars > 0 && m.loopBars % song.voice.slotBars == 0, "\(id): slots fit the loop")
            #expect((0..<m.beatsPerBar).contains(song.voice.beat) && song.voice.soloEvery >= 1)
            // the slot is longer than the longest voice: nothing piles up
            #expect(Double(song.voice.slotBars) * m.barSeconds > FloorSoundtrack.maxVoiceSeconds + 0.5, "\(id)")
        }
    }

    @Test func everySongHasAChordMapForItsOwnLoop() throws {
        let c = try config()
        for (id, song) in c.songs {
            let m = try manifest(id)
            let h = try #require(song.harmony.flatMap { SongHarmony.bundled($0) }, "\(id)")
            #expect(h.composition == id && h.bars.count == m.loopBars && h.beatsPerBar == m.beatsPerBar, "\(id)")
        }
        // Going Up!: chords change on beat 3 -- the chord at a beat is the bar's last change at or before it
        let g = try #require(SongHarmony.bundled("song-harmony-goingup"))
        #expect(g.chord(bar: 0, beat: 0)?.chord == "Bb6" && g.chord(bar: 0, beat: 2)?.chord == "Gm7" && g.chord(bar: 0, beat: 3)?.chord == "Gm7")
        #expect(g.chord(bar: 16, beat: 0)?.chord == "D7")                                  // the bridge
        #expect(try #require(SongHarmony.bundled("song-harmony-lanternroom")).chord(bar: 0, beat: 0)?.tones.prefix(3) == [2, 5, 9])   // Dm
    }

    // MARK: Who plays what

    @Test func nobodyFollowingIsTheBaseline() throws {
        let c = try config()
        for id in c.songs.keys {
            let l = try lineup(id, [])
            #expect(l.sounding == Set(try #require(c.songs[id]).baseline) && l.players.isEmpty && l.singers.isEmpty, "\(id)")
        }
    }

    @Test func aFollowerWithAFreeTrackPlaysItOthersSing() throws {
        // Floor 4, Going Up!: the Mailbox (trombone) plays Chair's trombone track; the Camera its vibes; Pottle the clarinet
        let l = try lineup("going-up", ["cast.mailbox", "cast.camera", "pottle.1"])
        #expect(l.players == ["chair": "cast.mailbox", "camera": "cast.camera", "pottle": "pottle.1"])
        #expect(l.singers.isEmpty)
        // the Topper's trumpet track is in the baseline already: it sings (never a second trumpet)
        let t = try lineup("going-up", ["hw.topper"])
        #expect(t.players.isEmpty && t.singers == ["hw.topper"])
        // no instrument at all: sings
        #expect(try lineup("going-up", ["somebody.new"]).singers == ["somebody.new"])
    }

    @Test func neverDoubledTheFirstToComeTakesTheTrack() throws {
        // Floor 5: the kalimba & tin track -- the Sister's marimba first; then the Tiny's glockenspiel has nothing left: sings
        let l = try lineup("night-shift-waltz", ["hw.sister", "hw.tiny", "pottle.1"])
        #expect(l.players == ["tinky": "hw.sister"])
        #expect(l.singers == ["hw.tiny", "pottle.1"])                                        // (the clarinet is the baseline's)
        // Floor 7: the first singer takes the lead vocal, the second the harmony
        let r = try lineup("rua-das-lampadas", ["juanita", "hw.pear", "hw.barrel"])
        #expect(r.players == ["lead": "juanita", "harmony": "hw.pear"] && r.singers == ["hw.barrel"])
        for x in [l, r] {
            #expect(Set(x.players.values).count == x.players.count)
            #expect(Set(x.players.values).isDisjoint(with: x.singers))
        }
    }

    @Test func theSameFollowersOnTheNextFloor() throws {
        let followers = ["hw.stilts", "hw.oldgent", "cast.mailbox"]
        let five = try lineup("night-shift-waltz", followers), six = try lineup("lantern-room", followers)
        #expect(five.players.isEmpty && five.singers == followers)
        #expect(six.players == ["violin": "hw.stilts", "cellos": "hw.oldgent"] && six.singers == ["cast.mailbox"])
    }

    // MARK: Voices

    @Test func eachResidentAlwaysHasTheSameVoice() {
        let samples = VoiceSample.bundled()
        #expect(samples.count >= 4)
        for id in BandInstruments.byResident.keys {
            let a = SoundtrackVoices.voice(for: id, samples: samples, overrides: [:])
            #expect(a != nil && a == SoundtrackVoices.voice(for: id, samples: samples, overrides: [:]))
        }
        #expect(SoundtrackVoices.fnv1a("hw.owl") == SoundtrackVoices.fnv1a("hw.owl") && SoundtrackVoices.fnv1a("a") != SoundtrackVoices.fnv1a("b"))
        #expect(SoundtrackVoices.fnv1a("") == 0xcbf2_9ce4_8422_2325)                       // (FNV-1a's offset basis: no seed, same everywhere)
        // every placeholder voice is somebody's
        let used = Set(BandInstruments.byResident.keys.compactMap { SoundtrackVoices.voice(for: $0, samples: samples, overrides: [:])?.id })
        #expect(used.count == min(4, samples.count))
        // an override wins
        #expect(SoundtrackVoices.voice(for: "hw.owl", samples: samples, overrides: ["hw.owl": "voice-meep-E5.wav"])?.id == "voice-meep-E5.wav")
    }

    // MARK: When the voices sing

    private func plan(_ song: String, _ notes: [Int?]) throws -> (events: [ChoirPlan.Event], m: StemComposition, slot: Int64) {
        let c = try config()
        let s = try #require(c.songs[song])
        let m = try manifest(song)
        let barFrames = Int64((m.barSeconds * m.sampleRate).rounded())
        let e = ChoirPlan.events(singers: notes, rule: s.voice, loopBars: m.loopBars, beatsPerBar: m.beatsPerBar,
                                 harmony: s.harmony.flatMap { SongHarmony.bundled($0) }, barFrames: barFrames,
                                 beatFrames: Int64((60 / m.bpm * m.sampleRate).rounded()))
        return (e, m, barFrames * Int64(s.voice.slotBars))
    }

    @Test func oneSingerSingsEveryOtherSlotOnTheSongsOwnBars() throws {
        let (e, m, slot) = try plan("going-up", [57])
        #expect(e.count == m.loopBars / 2 / 2)                                              // 64 bars, 2-bar slots, every other
        #expect(e.allSatisfy { $0.singer == 0 && $0.bar % 4 == 0 && $0.frame == Int64($0.bar) * slot / 2 })
        #expect(Int64((m.barSeconds * m.sampleRate).rounded()) == 63_000)                  // 4 beats at 168 bpm, 44.1 kHz (64 bars = 4 032 000)
    }

    @Test func severalSingersTakeTurnsNeverTogether() throws {
        for song in ["going-up", "night-shift-waltz", "lantern-room", "rua-das-lampadas"] {
            let notes: [Int?] = [57, 76, 45, nil]
            let (e, m, slot) = try plan(song, notes)
            let frames = e.map(\.frame)
            #expect(Set(frames).count == frames.count, "\(song): one voice per slot")
            for (a, b) in zip(e, e.dropFirst()) {
                #expect(b.frame - a.frame >= slot, "\(song): a slot apart")
                #expect(a.singer != b.singer, "\(song): turns")
            }
            #expect(Double(slot) / m.sampleRate > FloorSoundtrack.maxVoiceSeconds, "\(song): every voice ends before the next")
            #expect(e.allSatisfy { $0.frame < m.loopFrames && VoicePlan.range.contains($0.shift) })
            // pitched voices sing a tone of the chord at their slot
            let h = try #require(try config().songs[song]?.harmony.flatMap { SongHarmony.bundled($0) })
            for v in e {
                guard let n = v.note else { continue }
                let c = try #require(h.chord(bar: v.bar, beat: Double(v.beat)))
                #expect(c.tones.prefix(3).contains(((n % 12) + 12) % 12), "\(song) bar \(v.bar + 1): \(n) over \(c.chord)")
            }
        }
    }

    @Test func noChordMapMeansVoicesAsRecorded() {
        let rule = SoundtrackConfig.VoiceRule(slotBars: 2, beat: 0, soloEvery: 2)
        let e = ChoirPlan.events(singers: [57, 64], rule: rule, loopBars: 16, beatsPerBar: 4, harmony: nil, barFrames: 1000, beatFrames: 250)
        #expect(e.count == 8 && e.allSatisfy { $0.shift == 0 && $0.chord.isEmpty })
        #expect(ChoirPlan.events(singers: [], rule: rule, loopBars: 16, beatsPerBar: 4, harmony: nil, barFrames: 1000, beatFrames: 250).isEmpty)
    }

    @Test func theCuesFollowTheEndlessLoopOnceEach() {
        let cues = [ChoirTrack.Cue(frame: 0, key: "a"), ChoirTrack.Cue(frame: 500, key: "b")]
        var got: [Int64] = []
        var from: Int64 = 0
        while from < 3000 {
            got += ChoirTrack.due(cues, loopFrames: 1000, from: from, to: from + 137).map(\.frame)
            from += 137
        }
        #expect(got.filter { $0 < 3000 } == [0, 500, 1000, 1500, 2000, 2500])
    }
}
