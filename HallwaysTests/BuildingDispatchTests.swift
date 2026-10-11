import Foundation
import Testing
@testable import Hallways

/// Oct 8 -- Episode 3: Dispatch's first pipeline (mail -> shared MailStore ->
/// phone notification). Every test uses throwaway storage (TestStorage.swift)
/// and its own phone: the player's real mailbox, history and phone are never
/// touched.
@MainActor
struct BuildingDispatchTests {
    private let id = BuildingDispatch.staffMeetingTestMailID

    @Test func theTestMailIsAuthoredAndNeverAutomatic() {
        let mail = MailCatalog.authored(id)
        #expect(mail?.sender == "Administration")
        #expect(mail?.subject == "New Employee Staff Meeting")
        if case .byEvent = mail?.delivery {} else { Issue.record("must be delivered only by Dispatch") }
        // First login delivers the welcome mail, never this one.
        let storage = ThrowawayStorage()
        let store = storage.mail()
        store.deliverInitialIfNeeded()
        #expect(store.message(id) == nil)
    }

    @Test func dispatchDeliversToTheSharedMailboxAndNotifiesThePhone() {
        let storage = ThrowawayStorage()
        let mail = storage.mail(), phone = HallPhone()
        let liftBefore = phone.lift, screenBefore = phone.screen

        let sent = BuildingDispatch.sendMail(id, mail: mail, phone: phone, history: storage.history)
        #expect(sent)
        // Delivered: in the mailbox the office computer reads, unread.
        #expect(mail.message(id)?.subject == "New Employee Staff Meeting")
        #expect(!mail.isRead(id) && mail.unreadCount == 1)
        // Announced: one notification that opens this mail.
        #expect(phone.notifications.count == 1)
        #expect(phone.notifications.first?.source == "Administration")
        #expect(phone.notifications.first?.title == "New Employee Staff Meeting")
        #expect(phone.notifications.first?.opens == .mail(id))
        // The phone itself is not moved, opened or switched.
        #expect(phone.lift == liftBefore && phone.screen == screenBefore && phone.hold == .resting)
        // Recorded as a fact.
        #expect(storage.history.events(of: HistoryEventKind("dispatch.delivered")).map(\.subject) == [id])

        // Nothing is sent twice.
        let again = BuildingDispatch.sendMail(id, mail: mail, phone: phone, history: storage.history)
        #expect(!again)
        #expect(mail.inbox.filter { $0.id == id }.count == 1)
        #expect(phone.notifications.count == 1)

        // A relaunch (a fresh store on the same storage) still has it, once, unread.
        let relaunched = storage.mail()
        #expect(relaunched.message(id) != nil && !relaunched.isRead(id))
        #expect(!BuildingDispatch.sendMail(id, mail: relaunched, phone: phone, history: storage.history))

        // Opening it (what tapping the notification does) reads it.
        let apps = PhoneApps.shared
        let openBefore = apps.mailMessage
        apps.showMail(id, floor: 3, mail: mail, history: storage.history)
        #expect(mail.isRead(id) && mail.unreadCount == 0)
        #expect(apps.mailMessage == id)
        apps.mailMessage = openBefore
    }

    @Test func unknownMailIsNotSent() {
        let storage = ThrowawayStorage()
        let sent = BuildingDispatch.sendMail("mail.does.not.exist", mail: storage.mail(), phone: HallPhone(), history: storage.history)
        #expect(!sent)
    }

    @Test func communicationsTestsNeverTouchTheRealStores() {
        let before = RealCommunicationsSnapshot.take()
        let storage = ThrowawayStorage()
        let mail = storage.mail(), chat = storage.chat()
        mail.deliverInitialIfNeeded()
        _ = BuildingDispatch.sendMail(id, mail: mail, phone: HallPhone(), history: storage.history)
        mail.markRead(id)
        chat.deliverDue()
        chat.markThreadRead("chat.administration")
        mail.resetForNewPlayer()
        chat.resetForNewPlayer()
        #expect(RealCommunicationsSnapshot.take() == before)
    }
}

/// Oct 8 (Phase 1 C): HallChat through Dispatch -- delivered once, announced
/// once, and the notification opens the thread.
@MainActor
struct BuildingDispatchChatTests {
    private let fixture = AuthoredChatMessage(id: "chat.test.dispatch", thread: "chat.facilities",
                                              text: "Employee {employeeNumber}, test notice.", order: 99, delivery: .byEvent)

    private func store(_ storage: ThrowawayStorage) -> ChatStore {
        ChatStore(defaults: storage.defaults, history: storage.history, catalog: ChatCatalog.messages + [fixture])
    }

    @Test func sendChatDeliversOnceAndOpensTheThread() {
        let storage = ThrowawayStorage()
        let chat = store(storage), phone = HallPhone()
        #expect(BuildingDispatch.sendChat(fixture.id, chat: chat, phone: phone, history: storage.history))
        #expect(chat.isDelivered(fixture.id) && chat.unreadCount(in: "chat.facilities") == 1)
        #expect(phone.notifications.count == 1)
        #expect(phone.notifications.first?.source == "Facilities")
        #expect(phone.notifications.first?.opens == .chat("chat.facilities"))
        #expect(phone.notifications.first?.title.contains("{employeeNumber}") == false)
        #expect(storage.history.events(of: HistoryEventKind("dispatch.delivered")).map(\.subject) == [fixture.id])

        // No repeats: again now, or after a relaunch.
        #expect(!BuildingDispatch.sendChat(fixture.id, chat: chat, phone: phone, history: storage.history))
        let relaunched = store(storage)
        #expect(!BuildingDispatch.sendChat(fixture.id, chat: relaunched, phone: phone, history: storage.history))
        #expect(phone.notifications.count == 1)
        #expect(relaunched.messages(in: "chat.facilities").filter { $0.id == fixture.id }.count == 1)
    }

    @Test func unknownChatIsNotSent() {
        let storage = ThrowawayStorage()
        let phone = HallPhone()
        #expect(!BuildingDispatch.sendChat("chat.does.not.exist", chat: store(storage), phone: phone, history: storage.history))
        #expect(phone.notifications.isEmpty)
    }
}

/// Oct 8 (Phase 1 E/F): deterministic evaluation and the staff-meeting
/// invitation. Time and state are injected; storage is throwaway.
@MainActor
struct BuildingDispatchEvaluateTests {
    private let invite = BuildingDispatch.staffMeetingInvitationMailID
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func context(_ storage: ThrowawayStorage, beats: StoryBeats, phone: HallPhone,
                         admitted: Bool, at now: Date) -> BuildingDispatch.Context {
        BuildingDispatch.Context(now: now, admissionCompleted: admitted, mail: storage.mail(), chat: storage.chat(),
                                 phone: phone, history: storage.history, beats: beats)
    }

    @Test func theInvitationIsAuthoredEventOnlyAndNeverAtFirstLogin() {
        let mail = MailCatalog.authored(invite)
        #expect(mail?.sender == "Administration")
        if case .byEvent = mail?.delivery {} else { Issue.record("the invitation must be sent only by Dispatch") }
        let storage = ThrowawayStorage()
        let store = storage.mail()
        store.deliverInitialIfNeeded()
        #expect(store.message(invite) == nil)
    }

    @Test func nothingIsSentBeforeAdmission() {
        let storage = ThrowawayStorage()
        let beats = StoryBeats(defaults: storage.defaults), phone = HallPhone()
        let fired = BuildingDispatch.evaluate(context(storage, beats: beats, phone: phone, admitted: false, at: t0))
        #expect(fired.isEmpty)
        #expect(storage.mail().message(invite) == nil)
        #expect(!beats.has(BuildingDispatch.staffMeetingInvitedBeat))
        #expect(phone.notifications.isEmpty)
    }

    @Test func afterAdmissionTheInvitationArrivesOnceAndWaitsUnread() {
        let storage = ThrowawayStorage()
        let beats = StoryBeats(defaults: storage.defaults), phone = HallPhone()
        let fired = BuildingDispatch.evaluate(context(storage, beats: beats, phone: phone, admitted: true, at: t0))
        #expect(fired == ["invite.staffMeeting"])
        let mail = storage.mail()
        #expect(mail.message(invite)?.date == t0)
        #expect(!mail.isRead(invite))
        #expect(beats.time(BuildingDispatch.staffMeetingInvitedBeat) == t0)
        #expect(phone.notifications.count == 1 && phone.notifications.first?.opens == .mail(invite))

        // Evaluated again -- later, and after a "relaunch" (fresh stores on the
        // same storage) -- nothing repeats, and it is still unread.
        let later = t0.addingTimeInterval(3600)
        #expect(BuildingDispatch.evaluate(context(storage, beats: beats, phone: phone, admitted: true, at: later)).isEmpty)
        let relaunchedBeats = StoryBeats(defaults: storage.defaults)
        #expect(BuildingDispatch.evaluate(context(storage, beats: relaunchedBeats, phone: phone, admitted: true, at: later)).isEmpty)
        #expect(phone.notifications.count == 1)
        #expect(storage.mail().inbox.filter { $0.id == invite }.count == 1)
        #expect(!storage.mail().isRead(invite))
    }

    @Test func readingTheInvitationAcceptsNothing() {
        let storage = ThrowawayStorage()
        let beats = StoryBeats(defaults: storage.defaults)
        BuildingDispatch.evaluate(context(storage, beats: beats, phone: HallPhone(), admitted: true, at: t0))
        storage.mail().markRead(invite)
        #expect(Set(beats.beats.keys) == [BuildingDispatch.staffMeetingInvitedBeat])
    }

    @Test func evaluationUsesOnlyTheInjectedTime() {
        let storage = ThrowawayStorage()
        let beats = StoryBeats(defaults: storage.defaults)
        let rule = BuildingDispatch.Rule(id: "test.rule", firedBeat: "test.fired",
                                         isDue: { $0.now >= Date(timeIntervalSince1970: 100) }, fire: { _ in })
        func at(_ t: TimeInterval) -> BuildingDispatch.Context {
            context(storage, beats: beats, phone: HallPhone(), admitted: true, at: Date(timeIntervalSince1970: t))
        }
        #expect(BuildingDispatch.evaluate(at(99), rules: [rule]).isEmpty)
        #expect(BuildingDispatch.evaluate(at(100), rules: [rule]) == ["test.rule"])
        #expect(BuildingDispatch.evaluate(at(500), rules: [rule]).isEmpty)
        #expect(beats.time("test.fired") == Date(timeIntervalSince1970: 100))
    }
}
