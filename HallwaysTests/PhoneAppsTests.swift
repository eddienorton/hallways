import Foundation
import Testing
@testable import Hallways

/// Oct 8 -- the phone's first apps: the shared data behind them.
@MainActor
struct PhoneAppsTests {
    @Test func hallChatNoticesArriveOnceAndAreReadByThread() {
        let chat = ChatStore.shared
        chat.resetForNewPlayer()
        #expect(chat.activeThreads.isEmpty && chat.unreadCount == 0)
        chat.deliverDue()
        #expect(chat.activeThreads.count == ChatCatalog.threads.count)
        #expect(chat.unreadCount == ChatCatalog.messages.count)
        let admin = chat.messages(in: "chat.administration")
        #expect(admin.map(\.id) == ["chat.admin.welcome", "chat.admin.number"])     // in order
        chat.markThreadRead("chat.administration")
        #expect(chat.unreadCount(in: "chat.administration") == 0)
        #expect(chat.unreadCount == ChatCatalog.messages.count - 2)
        chat.deliverDue()                                                          // idempotent
        #expect(chat.messages(in: "chat.administration").count == 2)
        #expect(chat.unreadCount(in: "chat.administration") == 0)
        chat.resetForNewPlayer()
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
