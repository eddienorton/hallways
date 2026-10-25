import Foundation
import QuartzCore
import Testing
@testable import Hallways

/// Oct 22 -- MUSICAL IDENTITIES (first audition): six Hallwaysians, new display
/// names only (IDs untouched), each with a short instrumental signature; one
/// switch; and the Big Shot out of normal play.
@MainActor
struct HallwaysianMusicTests {
    @Test func theSixAreExistingHallwaysiansWithNewDisplayNamesOnly() {
        let expected = ["hw.feddy": "Benny", "hw.sister": "Cecilia", "hw.lanky": "Jolene",
                        "hw.stilts": "Eileen", "hw.scope": "Gloria", "hw.lopsy": "Layla"]
        #expect(HallwaysianMusic.songNamed.count == 6)
        for s in HallwaysianMusic.songNamed {
            #expect(expected[s.id] == s.newName)
            let persona = HallwaysianCast.persona(s.id)
            #expect(persona != nil)                                   // (an existing ID, unchanged)
            #expect(persona?.name == s.oldName)                       // (the persona itself keeps its name)
        }
        // Nobody else is renamed (Oct 22, later: everyone else has a signature, but keeps its name).
        for p in HallwaysianCast.all where expected[p.id] == nil {
            #expect(HallwaysianMusic.displayName(p.id, original: p.name) == p.name)
            #expect(HallwaysianMusic.signature(p.id)?.newName == nil)
        }
    }

    /// Oct 22 (later): every active character has exactly one signature -- all
    /// sixteen Hallwaysians, the Chair, the Butterfly, the Pottle, the meeting's
    /// six, Tinky and Juanita -- and nobody else (not the retired Big Shot).
    @Test func everyActiveCharacterHasOneSignature() {
        var ids = Set(HallwaysianCast.ids)
        ids.formUnion(CastResidents.members.map(\.id))
        ids.formUnion(["chair.1", "butterfly", "pottle.1", CharacterRegistry.tinkyID, CharacterRegistry.juanitaID])
        #expect(ids.count == 27)
        #expect(Set(HallwaysianMusic.all.map(\.id)) == ids)
        #expect(HallwaysianMusic.all.count == ids.count)                    // (one each)
        for id in ids { #expect(CharacterRegistry.identity(id) != nil) }   // (each is in the Directory)
        // Distinct files; the six keep their first-audition files (Eileen's is unchanged).
        #expect(Set(HallwaysianMusic.all.map { HallwaysianMusic.soundName($0.id) }).count == ids.count)
        #expect(HallwaysianMusic.soundName("hw.stilts") == "hw-music-v1-hw-stilts")
    }

    @Test func theSwitchRestoresTheOriginalNames() {
        let key = HallwaysianMusic.defaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(false, forKey: key)
        #expect(!HallwaysianMusic.isOn)
        #expect(HallwaysianMusic.displayName("hw.feddy", original: "Feddy") == "Feddy")
        UserDefaults.standard.set(true, forKey: key)
        #expect(HallwaysianMusic.displayName("hw.feddy", original: "Feddy") == "Benny")
    }

    /// Each is short and gentle: never longer than three seconds, never silent,
    /// never clipping, and no two alike. The six song-named ones are real
    /// phrases (several onsets, uneven rhythm); the rest may be a note, a chord,
    /// two notes or a tiny phrase -- restraint.
    @Test func eachSignatureIsShortGentleAndItsOwn() {
        var fingerprints = Set<String>()
        for s in HallwaysianMusic.all {
            let x = HallwaysianMusic.render(s)
            let seconds = Float(x.count) / HallwaysianMusic.rate
            #expect(seconds <= 3.0)
            let peak = x.map { abs($0) }.max() ?? 0
            #expect(peak > 0.01)
            #expect(x.allSatisfy { $0.isFinite })
            let heard = (x.lastIndex { abs($0) > peak * 0.02 } ?? 0)
            let audible = Float(heard) / HallwaysianMusic.rate
            #expect(audible >= 0.4 && audible <= 3.0)
            #expect(HallwaysianMusic.duration(s.id) <= 3.0)
            if s.newName != nil {
                let onsets = Set(s.notes.map { $0.at }).sorted()
                #expect(onsets.count >= 5)
                let gaps = Set(zip(onsets, onsets.dropFirst()).map { Int((($1 - $0) * 100).rounded()) })
                #expect(gaps.count >= 2)
            } else {
                #expect(Set(s.notes.map { $0.at }).count <= 6)                  // (a few notes at most)
            }
            fingerprints.insert(s.notes.map { "\($0.inst)\($0.midi)\($0.at)" }.joined())
        }
        #expect(fingerprints.count == HallwaysianMusic.all.count)
    }

    /// The conductor: nearer is likelier, coming toward it likelier still.
    @Test func theConductorPrefersTheNearAndTheApproached() {
        #expect(ResidentMusicConductor.score(distance: 2, approaching: false) > ResidentMusicConductor.score(distance: 6, approaching: false))
        #expect(ResidentMusicConductor.score(distance: 5, approaching: true) > ResidentMusicConductor.score(distance: 5, approaching: false))
        #expect(ResidentMusicConductor.checkIn.lowerBound >= 30 && ResidentMusicConductor.checkIn.upperBound <= 45)
        #expect(ResidentMusicConductor.hush.lowerBound > 0)
        // After any signature, the building is musically quiet for a while.
        let conductor = ResidentMusicConductor.shared
        let t: CFTimeInterval = 1_000_000
        conductor.played("hw.owl", now: t)
        #expect(!conductor.mayGreet(now: t + 1))
        #expect(!conductor.mayGreet(now: t + HallwaysianMusic.duration("hw.owl") + ResidentMusicConductor.hush.lowerBound - 0.5))
    }

    /// Oct 22 (morning): the goodbye -- the same signature an octave lower: its
    /// own file, the same length and rhythm, about half the pitch.
    @Test func theGoodbyeIsTheSignatureAnOctaveDown() throws {
        let juanita = try #require(HallwaysianMusic.signature("juanita"))   // (a single bell: easy to measure)
        let hello = HallwaysianMusic.render(juanita)
        let bye = HallwaysianMusic.render(juanita, transpose: HallwaysianMusic.farewellTranspose)
        #expect(HallwaysianMusic.farewellTranspose == -12)
        #expect(hello.count == bye.count)                                    // (the same length: the same rhythm)
        func crossings(_ x: [Float]) -> Int { zip(x, x.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count }
        let ratio = Double(crossings(bye)) / Double(max(1, crossings(hello)))
        #expect(ratio > 0.4 && ratio < 0.6)                                  // (an octave: half the frequency)
        for s in HallwaysianMusic.all {
            #expect(HallwaysianMusic.soundName(s.id, low: true) != HallwaysianMusic.soundName(s.id))
            #expect(HallwaysianMusic.render(s, transpose: -12).allSatisfy { $0.isFinite })
        }
        // Eileen's greeting is untouched by any of this.
        #expect(HallwaysianMusic.soundName("hw.stilts") == "hw-music-v1-hw-stilts")
    }

    /// Oct 22 (morning): a resident's music still sounding blocks another of its own.
    @Test func noSecondSoundOnTopOfTheFirst() {
        let conductor = ResidentMusicConductor.shared
        let t: CFTimeInterval = 2_000_000
        conductor.played("cast.stove", now: t)
        #expect(conductor.isSounding("cast.stove", now: t + 0.5))
        #expect(!conductor.isSounding("cast.stove", now: t + HallwaysianMusic.duration("cast.stove") + 0.1))
        #expect(!conductor.isSounding("cast.mailbox", now: t + 0.5))
    }

    @Test func theBigShotIsOutOfNormalPlay() {
        #expect(UserDefaults.standard.object(forKey: "HallwaysBigShot") != nil || !BigShot.isEnabled)
    }
}
