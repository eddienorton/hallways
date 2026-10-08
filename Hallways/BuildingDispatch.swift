import Foundation

// Oct 8 -- DISPATCH (Episode 3, first pass): the Hallways Building's central
// communications coordinator. Everything the building sends the player goes
// through here.
//
// This pass proves ONE pipeline, end to end:
//   1. DELIVERY: an authored message is delivered into the store it belongs
//      to -- for mail, the shared MailStore (the same mailbox the office
//      computer reads: same persistence, same unread state).
//   2. PRESENTATION: the player's phone is told something arrived (sound,
//      screen lights, a compact notification). The phone stays wherever it is
//      held; nothing is raised, opened or interrupted.
// Delivery never depends on presentation: the message is in the mailbox
// whether or not anyone sees the notification.
//
// Later (not now): HallChat deliveries (ChatStore.deliver + the same
// announce), and the decisions about WHAT to send and WHEN (episode
// progress, Player History, relationships...). Those decisions belong here,
// in front of `sendMail`, not in the stores or on the phone.

enum BuildingDispatch {
    /// The Episode 3 pipeline test: "New Employee Staff Meeting". Not the real
    /// invitation -- no time, place or meeting is established by it.
    static let staffMeetingTestMailID = "mail.admin.staffMeeting.test"

    /// Send authored mail `id` to the player. False (and nothing happens) if
    /// there is no such mail or it has already been delivered: nothing is
    /// ever sent twice.
    @discardableResult
    static func sendMail(_ id: String, at date: Date = Date()) -> Bool {
        guard MailCatalog.authored(id) != nil, MailStore.shared.message(id) == nil else {
            diag("dispatch.skipped", ["channel": "mail", "id": id])
            return false
        }
        MailStore.shared.deliver(id, at: date)
        guard let mail = MailStore.shared.message(id) else { return false }
        PlayerHistory.shared.record(HistoryEventKind("dispatch.delivered"), subject: id, detail: ["channel": "mail"])
        HallPhone.shared.notify(source: mail.sender, title: mail.subject, opens: .mail(id))
        return true
    }

    #if DEBUG
    /// DEV ONLY (press and hold the phone still for 0.6 s): send the staff
    /// meeting test mail. Repeatable: a previous copy is taken back first, so
    /// it arrives again, unread. Never compiled into TestFlight/App Store builds.
    static func devSendStaffMeetingTest() {
        MailStore.shared.devWithdraw(staffMeetingTestMailID)
        sendMail(staffMeetingTestMailID)
    }
    #endif
}
