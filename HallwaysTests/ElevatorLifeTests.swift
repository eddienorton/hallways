import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 18 -- ELEVATOR LIFE, RESIDENT AUDIO, CONTACTS: the hall sign showing the
/// one car, the critter-sound fade as a navigation cue, what AudioWatch
/// reports, and Contacts (met, saved -- or not, in a test). Pure data.
@MainActor
struct ElevatorLifeTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    // (Oct 19, elevator overhaul: the car's own tests -- requests, runs, doors,
    // riders, the player, saving -- are in ElevatorCarTests and ElevatorJourneyTests.)

    @Test func theHallSignShowsTheCar() {
        func pair(_ x: (floor: Int, direction: Int)?) -> [Int]? { x.map { [$0.floor, $0.direction] } }
        let car = BuildingElevator()
        car.placeIfNeeded(at: 4, now: t0)
        car.call("chair.1", at: 9, to: 2, now: t0)
        car.advance(to: at(0.2))
        let p = car.position(now: at(0.2))
        // Where THE car is, and which way: the same position every floor's sign reads.
        #expect(pair(ElevatorBoard.indicator(floor: 5, playerUsing: false, car: p)) == [p!.floor, 1])
        // The player in the cab: their own ride's sign, as built.
        #expect(ElevatorBoard.indicator(floor: 5, playerUsing: true, car: p) == nil)
    }

    // MARK: Sound as a way to find things

    @Test func critterSoundFadesContinuouslyWithDistance() {
        #expect(!CritterAudio.obviousFadeSteps)
        #expect(CritterAudio.fadeGain(0.5) == 1)
        #expect(CritterAudio.fadeGain(CritterAudio.silentDistance) == 0)
        var last: Float = 1.01
        for d in stride(from: Float(1.0), through: CritterAudio.silentDistance, by: 0.5) {
            let g = CritterAudio.fadeGain(d)
            #expect(g < last)                                            // every step away: quieter
            last = g
        }
        // Walls muffle, they don't silence.
        #expect(CritterAudio.oneWallGain > CritterAudio.wallsGain && CritterAudio.wallsGain > 0)
    }

    @Test func audioWatchSaysWhoAndHowLoud() throws {
        AudioWatch.reset()
        let source = try #require(ResidentVoice.chairShuffles.first)
        #expect(SoundCatalog.name(of: source) == "chair-shuffle-0")
        AudioWatch.heard(critter: "residentChair", source: source, outcome: "clear", gain: 0.3, distance: 4, now: 100)
        AudioWatch.heard(critter: "residentChair", source: source, outcome: "clear", gain: 0.35, distance: 3.5, now: 100.6)
        let lines = AudioWatch.summary(8, now: 101)
        #expect(lines.count == 1)
        #expect(lines[0].contains("residentChair") && lines[0].contains("chair-shuffle-0") && lines[0].contains("x2"))
        #expect(AudioWatch.nearness(3, now: 101) > 0.4)
        #expect(AudioWatch.nearness(3, now: 110) == 0)                  // nothing heard lately: no pulse
        AudioWatch.reset()
    }

    // MARK: Contacts

    @Test func contactsAreKeptInPlayButNotInATest() throws {
        let storage = ThrowawayStorage()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("contacts-test-\(UUID().uuidString)")
        let test = ContactsStore(defaults: storage.defaults, persists: false, portraitDirectory: dir)
        #expect(test.meet(RoamingChairKind.id, at: t0))
        #expect(test.hasMet(RoamingChairKind.id))
        #expect(storage.defaults.data(forKey: ContactsStore.storageKey) == nil)       // a test encounter: nothing saved
        let play = ContactsStore(defaults: storage.defaults, persists: true, portraitDirectory: dir)
        #expect(play.meet(Butterfly.id, at: t0))
        #expect(!play.meet(Butterfly.id, at: at(5)))                                  // once
        #expect(!play.meet("nobody", at: t0))                                          // only registered characters
        let again = ContactsStore(defaults: storage.defaults, persists: true, portraitDirectory: dir)
        #expect(again.contacts.map(\.id) == [Butterfly.id])
        again.resetForNewPlayer()
        #expect(again.contacts.isEmpty)
    }

    @Test func everyCharacterHasANameAndASound() {
        let ids = CharacterRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains(RoamingChairKind.id) && ids.contains(Butterfly.id))
        for c in CharacterRegistry.all {
            #expect(!c.name.isEmpty && !c.blurb.isEmpty && !c.preview.isEmpty)
            c.prepareSounds()
            for p in c.preview { #expect(FileManager.default.fileExists(atPath: SoundCatalog.url(p.sound).path)) }
        }
    }
}
