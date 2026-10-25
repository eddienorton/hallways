import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 19 -- CONTACTS: Mr. Tinky under his own name (his saved id unchanged),
/// and Juanita -- both met at a story moment (her first greeting, his first
/// words), never by standing near them.
@MainActor
struct ContactsDiscoveryTests {
    private func store(_ storage: ThrowawayStorage, persists: Bool, dir: URL) -> ContactsStore {
        ContactsStore(defaults: storage.defaults, persists: persists, portraitDirectory: dir)
    }
    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("contacts-\(UUID().uuidString)") }

    @Test func tinkyIsTinkyAndThereIsNoJeff() throws {
        let names = CharacterRegistry.all.map(\.name)
        #expect(!names.contains("Jeff"))
        #expect(names.filter { $0 == "Tinky" }.count == 1)
        let tinky = try #require(CharacterRegistry.identity(CharacterRegistry.tinkyID))
        #expect(tinky.name == "Tinky")
        #expect(CharacterRegistry.tinkyID == "jeff")                               // (his saved id: old saves keep him)
        let juanita = try #require(CharacterRegistry.identity(CharacterRegistry.juanitaID))
        #expect(juanita.name == "Juanita")
        #expect(tinky.metByEventOnly && juanita.metByEventOnly)
    }

    /// A save that had already met him as "Jeff" shows him as Tinky -- one entry, nothing lost.
    @Test func anOldSavesJeffIsShownAsTinky() {
        let storage = ThrowawayStorage(), d = dir()
        let old = store(storage, persists: true, dir: d)
        #expect(old.meet("jeff"))
        let again = store(storage, persists: true, dir: d)
        #expect(again.contacts.map(\.name) == ["Tinky"])
        #expect(!again.meet(CharacterRegistry.tinkyID))                             // (no duplicate)
    }

    /// Standing beside her (or him, through a wall) is not meeting them; the event is.
    @Test func nearnessNeverMeetsThemTheStoryMomentDoes() {
        let storage = ThrowawayStorage(), d = dir()
        let root = SCNNode()
        let juanita = SCNNode()
        juanita.name = AdministrationReception.standInNodeName
        root.addChildNode(juanita)
        let previous = CharacterRegistry.sceneRoot
        CharacterRegistry.sceneRoot = root
        defer { CharacterRegistry.sceneRoot = previous }
        let contacts = store(storage, persists: true, dir: d)
        contacts.check(player: SIMD2<Float>(0.5, 0.5))                              // (right beside her body)
        #expect(!contacts.hasMet(CharacterRegistry.juanitaID))
        // Her greeting: met, once, and kept across a relaunch -- with Tinky after him speaking.
        #expect(contacts.meet(CharacterRegistry.juanitaID, at: Date(timeIntervalSince1970: 100)))
        #expect(!contacts.meet(CharacterRegistry.juanitaID, at: Date(timeIntervalSince1970: 150)))
        #expect(contacts.meet(CharacterRegistry.tinkyID, at: Date(timeIntervalSince1970: 200)))
        let relaunched = store(storage, persists: true, dir: d)
        #expect(relaunched.contacts.map(\.name) == ["Juanita", "Tinky"])
    }
}
