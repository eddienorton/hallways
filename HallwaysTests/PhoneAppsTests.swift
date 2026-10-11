import Foundation
import Testing
@testable import Hallways

/// Oct 8 -- the phone's first apps: the shared data behind them.
@MainActor
struct PhoneAppsTests {
    @Test func hallChatNoticesArriveOnceAndAreReadByThread() {
        let storage = ThrowawayStorage()                 // never the player's real HallChat
        let chat = storage.chat()
        let withPhoneCount = ChatCatalog.messages.filter { $0.delivery == .withPhone }.count
        #expect(chat.activeThreads.isEmpty && chat.unreadCount == 0)
        chat.deliverDue()
        #expect(chat.activeThreads.count == ChatCatalog.threads.count)
        #expect(chat.unreadCount == withPhoneCount)
        let admin = chat.messages(in: "chat.administration")
        #expect(admin.map(\.id) == ["chat.admin.welcome", "chat.admin.number"])     // in order
        chat.markThreadRead("chat.administration")
        #expect(chat.unreadCount(in: "chat.administration") == 0)
        #expect(chat.unreadCount == withPhoneCount - 2)
        chat.deliverDue()                                                          // idempotent
        #expect(chat.messages(in: "chat.administration").count == 2)
        #expect(chat.unreadCount(in: "chat.administration") == 0)
        // A relaunch (a fresh store on the same storage) keeps both.
        let relaunched = storage.chat()
        #expect(relaunched.messages(in: "chat.administration").count == 2)
        #expect(relaunched.unreadCount(in: "chat.administration") == 0)
    }

    /// Oct 8 (Phase 1 B): event-only texts never arrive by themselves.
    @Test func eventOnlyTextsNeverArriveWithThePhone() {
        let storage = ThrowawayStorage()
        let fixture = AuthoredChatMessage(id: "chat.test.eventOnly", thread: "chat.administration",
                                          text: "Event only.", order: 99, delivery: .byEvent)
        let chat = ChatStore(defaults: storage.defaults, history: storage.history,
                             catalog: ChatCatalog.messages + [fixture])
        chat.deliverDue()
        chat.deliverDue()
        #expect(!chat.isDelivered(fixture.id))
        #expect(!chat.messages(in: "chat.administration").contains { $0.id == fixture.id })
        // Every existing notice still arrives exactly as before.
        for m in ChatCatalog.messages { #expect(chat.isDelivered(m.id)) }
        // Only an explicit delivery brings it -- once.
        #expect(chat.deliver(fixture.id))
        #expect(!chat.deliver(fixture.id))
        #expect(chat.messages(in: "chat.administration").filter { $0.id == fixture.id }.count == 1)
    }

    /// Every notice authored before Phase 1 keeps arriving with the phone.
    @Test func existingNoticesStillArriveWithThePhone() {
        for m in ChatCatalog.messages { #expect(m.delivery == .withPhone) }
    }

    @Test func hallChatCarriesOnlyTheBuildingsDepartments() {
        #expect(Set(ChatCatalog.threads.map(\.title)) == ["Administration", "IT Services", "Facilities"])
        for m in ChatCatalog.messages { #expect(ChatCatalog.thread(m.thread) != nil) }
    }

    @Test func theDirectoryListsOnlyWhatIsEstablished() {
        let ids = Set(DirectoryCatalog.entries.map(\.id))
        #expect(ids == ["dir.you", "dir.administration", "dir.juanita", "dir.facilities", "dir.it", "dir.recreation"])
        // Unknown stays unknown: no invented floors for departments the building hasn't placed.
        #expect(DirectoryCatalog.entry("dir.facilities")?.floor == nil)
        #expect(DirectoryCatalog.entry("dir.administration")?.floor == "Floor 2")
    }

    @Test func floorNames() {
        #expect(BuildingFloors.name(1) == "Lobby")
        #expect(BuildingFloors.name(7) == "Floor 7")
        #expect(BuildingFloors.note(2) == "Administration")
    }
}
