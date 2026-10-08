import Foundation
import Testing
@testable import Hallways

/// Oct 8 -- Episode 3: Dispatch's first pipeline (mail -> shared MailStore ->
/// phone notification).
@MainActor
struct BuildingDispatchTests {
    private let id = BuildingDispatch.staffMeetingTestMailID

    @Test func theTestMailIsAuthoredAndNeverAutomatic() {
        let mail = MailCatalog.authored(id)
        #expect(mail?.sender == "Administration")
        #expect(mail?.subject == "New Employee Staff Meeting")
        if case .byEvent = mail?.delivery {} else { Issue.record("must be delivered only by Dispatch") }
        // First login delivers the welcome mail, never this one.
        MailStore.shared.resetForNewPlayer()
        MailStore.shared.deliverInitialIfNeeded()
        #expect(MailStore.shared.message(id) == nil)
        MailStore.shared.resetForNewPlayer()
    }

    @Test func dispatchDeliversToTheSharedMailboxAndNotifiesThePhone() {
        let mail = MailStore.shared, phone = HallPhone.shared
        mail.resetForNewPlayer()
        phone.resetForNewPlayer()
        let liftBefore = phone.lift, screenBefore = phone.screen

        let sent = BuildingDispatch.sendMail(id)
        #expect(sent)
        // Delivered: in the same mailbox the office computer reads, unread.
        #expect(mail.message(id)?.subject == "New Employee Staff Meeting")
        #expect(!mail.isRead(id) && mail.unreadCount == 1)
        // Announced: one notification that opens this mail.
        #expect(phone.notifications.count == 1)
        #expect(phone.notifications.first?.source == "Administration")
        #expect(phone.notifications.first?.title == "New Employee Staff Meeting")
        #expect(phone.notifications.first?.opens == .mail(id))
        // The phone itself is not moved, opened or switched.
        #expect(phone.lift == liftBefore && phone.screen == screenBefore && phone.hold == .resting)

        // Nothing is sent twice.
        let again = BuildingDispatch.sendMail(id)
        #expect(!again)
        #expect(mail.inbox.filter { $0.id == id }.count == 1)
        #expect(phone.notifications.count == 1)

        // Opening it (what tapping the notification does) reads it, everywhere.
        PhoneApps.shared.showMail(id, floor: 3)
        #expect(mail.isRead(id) && mail.unreadCount == 0)
        #expect(PhoneApps.shared.mailMessage == id)

        mail.resetForNewPlayer()
        phone.resetForNewPlayer()
    }

    @Test func unknownMailIsNotSent() {
        let sent = BuildingDispatch.sendMail("mail.does.not.exist")
        #expect(!sent)
    }
}
