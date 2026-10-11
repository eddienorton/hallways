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
    /// Oct 8 (Phase 1 F): the REAL staff-meeting invitation. Sent once, after
    /// admission is complete (see `rules`). Waits unread until the player
    /// chooses to open it; reading it is not accepting anything.
    static let staffMeetingInvitationMailID = "mail.admin.staffMeeting.invitation"
    /// The story beat recorded when the invitation is sent.
    static let staffMeetingInvitedBeat = "invite.staffMeeting.sent"

    /// Send authored mail `id` to the player. False (and nothing happens) if
    /// there is no such mail or it has already been delivered: nothing is
    /// ever sent twice.
    @discardableResult
    static func sendMail(_ id: String, at date: Date = Date(), mail store: MailStore = .shared,
                         phone: HallPhone = .shared, history: PlayerHistory = .shared) -> Bool {
        guard MailCatalog.authored(id) != nil, store.message(id) == nil else {
            diag("dispatch.skipped", ["channel": "mail", "id": id])
            return false
        }
        store.deliver(id, at: date)
        guard let mail = store.message(id) else { return false }
        history.record(HistoryEventKind("dispatch.delivered"), subject: id, detail: ["channel": "mail"], at: date)
        phone.notify(source: mail.sender, title: mail.subject, opens: .mail(id))
        return true
    }

    /// Oct 8 (Phase 1 C): send authored HallChat message `id` (normally a
    /// `.byEvent` one) to the player. False (and nothing happens) if there is
    /// no such message or it has already arrived: nothing is ever sent twice,
    /// including across relaunches (ChatStore persists what arrived).
    /// The phone announces it with a notification that opens its thread.
    @discardableResult
    static func sendChat(_ id: String, at date: Date = Date(), chat store: ChatStore = .shared,
                         phone: HallPhone = .shared, history: PlayerHistory = .shared) -> Bool {
        guard let authored = store.catalog.first(where: { $0.id == id }),
              let thread = ChatCatalog.thread(authored.thread),
              store.deliver(id, at: date) else {
            diag("dispatch.skipped", ["channel": "chat", "id": id])
            return false
        }
        let text = store.messages(in: thread.id).first { $0.id == id }?.text ?? authored.text
        history.record(HistoryEventKind("dispatch.delivered"), subject: id, detail: ["channel": "chat"], at: date)
        phone.notify(source: thread.title, title: text, opens: .chat(thread.id))
        return true
    }

    // MARK: Oct 8 (Phase 1 E) -- deciding what to send, and when

    /// Everything a rule may look at. Injected, so evaluation is
    /// deterministic: tests pass their own time, state and throwaway stores.
    struct Context {
        var now: Date
        var admissionCompleted: Bool
        var mail: MailStore
        var chat: ChatStore
        var phone: HallPhone
        var history: PlayerHistory
        var beats: StoryBeats

        /// The real game: real stores, the real admission flag.
        static func live(now: Date = Date()) -> Context {
            Context(now: now, admissionCompleted: Admission.isCompleted, mail: .shared, chat: .shared,
                    phone: .shared, history: .shared, beats: .shared)
        }
    }

    /// One thing the building does once: when `isDue`, `fire` runs and
    /// `firedBeat` is recorded, so it never runs again (not on the next
    /// evaluation, not after a relaunch).
    struct Rule {
        let id: String
        let firedBeat: String
        let isDue: (Context) -> Bool
        let fire: (Context) -> Void
    }

    /// The building's communications rules, checked in order.
    /// Phase 1: only the staff-meeting invitation. (No meeting, no follow-up
    /// text, and app-closed time is never treated as anything -- Phase 2.)
    static let rules: [Rule] = [
        Rule(id: "invite.staffMeeting", firedBeat: staffMeetingInvitedBeat,
             isDue: { $0.admissionCompleted },
             fire: { c in
                 _ = sendMail(staffMeetingInvitationMailID, at: c.now, mail: c.mail, phone: c.phone, history: c.history)
             }),
    ]

    /// Check every rule once, now. Called at natural gameplay moments
    /// (entering the building, returning to the app, arriving on a floor,
    /// taking the phone out, sitting at the computer) -- never on a timer.
    /// Returns the ids of the rules that fired.
    @discardableResult
    static func evaluate(_ context: Context, rules: [Rule] = BuildingDispatch.rules, reason: String = "") -> [String] {
        var fired: [String] = []
        for rule in rules where !context.beats.has(rule.firedBeat) && rule.isDue(context) {
            rule.fire(context)
            context.beats.record(rule.firedBeat, at: context.now)
            fired.append(rule.id)
        }
        if !fired.isEmpty { diag("dispatch.evaluate", ["reason": reason, "fired": fired.joined(separator: ",")]) }
        return fired
    }

    /// The game's entry point: the live context at the current time.
    @discardableResult
    static func evaluate(reason: String) -> [String] {
        evaluate(.live(), reason: reason)
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
