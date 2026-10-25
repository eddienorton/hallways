import Foundation
import Testing
@testable import Hallways

/// Oct 19 -- STAGE A, THE FINAL CAST: Clacker, Little Clacker, Dog, Cat and
/// Little Pottle are retired for good. Nothing registers them any more, and a
/// save made before the cleanup loses them safely: their resident records go
/// at load (so the elevator never books them a trip) and their Contacts
/// entries and portraits go too. Everyone else in the save is untouched.
@MainActor
struct CastCleanupTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let retired = ["clacker.1", "clacker.2", "dog.1", "cat.1", "pottle.2"]

    @Test func theRetiredAreRegisteredNowhere() {
        #expect(Set(ResidentRoster.retiredIDs) == Set(retired))
        #expect(ResidentRoster.profiles.map(\.id) == ["pottle.1"])
        for id in retired {
            #expect(ResidentRoster.profile(id) == nil)
            #expect(CharacterRegistry.identity(id) == nil)
        }
        let names = CharacterRegistry.all.map(\.name)
        for name in ["Clacker", "Little Clacker", "Dog", "Cat", "Little Pottle", "Rolodex", "Dottie", "Nan", "Elwood"] {
            #expect(!names.contains(name))
        }
    }

    /// An old save with retired residents in it: they're dropped at load, the
    /// survivors keep their records exactly, and the save is rewritten without them.
    @Test func retiredResidentsAreDroppedFromAnOldSave() throws {
        let storage = ThrowawayStorage()
        let chair = try #require(RoamingChairKind().newcomers(now: t0).first)
        var saved: [Resident] = [chair]
        for id in retired {
            saved.append(Resident(id: id, kind: "critter.\(id.split(separator: ".")[0])", floor: 5,
                                  cell: GridCoordinate(row: 10, col: 6), since: t0, dwell: 30))
        }
        storage.defaults.set(try JSONEncoder().encode(saved), forKey: BuildingLife.storageKey)

        let life = BuildingLife(defaults: storage.defaults, persists: true, kinds: [RoamingChairKind()])
        #expect(life.residentIDs == [chair.id])
        for id in retired { #expect(life.resident(id) == nil) }
        #expect(life.resident(chair.id)?.since == chair.since)

        let data = try #require(storage.defaults.data(forKey: BuildingLife.storageKey))
        let rewritten = try JSONDecoder().decode([Resident].self, from: data)
        #expect(rewritten.map(\.id) == [chair.id])
    }

    /// An old save that met retired characters: no phantom contacts, their
    /// portraits deleted, the rest kept in the order they were met.
    @Test func retiredContactsAreDroppedFromAnOldSave() throws {
        let storage = ThrowawayStorage()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("contacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var met: [String: Date] = ["pottle.1": t0.addingTimeInterval(10)]
        for (i, id) in retired.enumerated() {
            met[id] = t0.addingTimeInterval(Double(i))
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("\(id).png"))
        }
        storage.defaults.set(try JSONEncoder().encode(met), forKey: ContactsStore.storageKey)

        let contacts = ContactsStore(defaults: storage.defaults, persists: true, portraitDirectory: dir)
        #expect(contacts.contacts.map(\.id) == ["pottle.1"])
        #expect(contacts.hasMet("pottle.1"))
        for id in retired {
            #expect(!contacts.hasMet(id))
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).png").path))
        }
        let data = try #require(storage.defaults.data(forKey: ContactsStore.storageKey))
        let rewritten = try JSONDecoder().decode([String: Date].self, from: data)
        #expect(Set(rewritten.keys) == ["pottle.1"])
        // A retired id can never be met again.
        #expect(!contacts.meet("dog.1"))
    }

    /// The classic staff meeting's excitable one is the Frog now (seed 1), not
    /// the retired Clacker (seed 0).
    @Test func theClassicMeetingsExcitableOneIsTheFrog() {
        #expect(MeetingScript.excitableSeed == 1)
    }
}
