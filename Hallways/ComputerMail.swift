import SwiftUI
import Combine

// Oct 7 -- G. MAIL (the office computer's first app).
//
// Mail is information, not a leash: nothing here opens itself, nothing
// demands a reply, nothing stops the player leaving the desk.
//
// Architecture for authored mail:
//   - `MailCatalog.all` is the authored library: every message the building
//     can ever send, each with a DURABLE ID ("mail.it.workstation"), sender,
//     subject, body (may use {employeeNumber}) and a delivery rule.
//   - `MailStore` is the player's persisted mailbox state: which authored
//     IDs have been delivered (and when), and which have been read.
//   - Delivery rules: `.atFirstLogin` messages arrive the first time the
//     player sits at the computer (stamped a little earlier that morning, as
//     if they had been waiting); `.byEvent` messages are delivered only when
//     game code calls `MailStore.shared.deliver(id)` -- the hook a future
//     story/scheduler will use. Nothing calls it yet.

nonisolated enum MailDelivery: Sendable {
    /// Waiting in the inbox at the first login, stamped `minutesEarlier` before it.
    case atFirstLogin(minutesEarlier: Int)
    /// Delivered only by an explicit `MailStore.deliver(_:)` call.
    case byEvent
}

nonisolated struct AuthoredMail: Sendable {
    let id: String
    let sender: String
    let senderAddress: String
    let subject: String
    let body: String
    let delivery: MailDelivery
}

/// One message as the inbox shows it (authored text resolved, delivery time known).
nonisolated struct MailMessage: Identifiable, Sendable, Equatable {
    let id: String
    let sender: String
    let senderAddress: String
    let subject: String
    let body: String
    let date: Date
}

enum MailCatalog {
    static let all: [AuthoredMail] = [
        AuthoredMail(
            id: "mail.admin.welcome",
            sender: "Administration",
            senderAddress: "administration@hallways.internal",
            subject: "Welcome to Hallways",
            body: """
            Welcome aboard.

            Your employee number is {employeeNumber}. It is printed on your ID and on your office door. Please keep your ID with you while you are in the building.

            Your office is on Floor 3. It is yours.

            If you have any questions, Administration is on Floor 2.

            Administration
            """,
            delivery: .atFirstLogin(minutesEarlier: 96)),
        AuthoredMail(
            id: "mail.facilities.office",
            sender: "Facilities",
            senderAddress: "facilities@hallways.internal",
            subject: "Your office",
            body: """
            Your office has been prepared: desk, chair, visitor's chair, desk lamp, filing cabinet, shelf and coat rack.

            The nail on the wall beside the door is rated for one framed picture.

            Please report anything that is broken, missing, or making a noise it shouldn't.

            Facilities
            """,
            delivery: .atFirstLogin(minutesEarlier: 81)),
        AuthoredMail(
            id: "mail.it.workstation",
            sender: "IT Services",
            senderAddress: "it.services@hallways.internal",
            subject: "Your workstation",
            body: """
            This workstation has been set up for employee {employeeNumber}.

            Installed: Mail, Games.

            Work applications are provisioned by your department. They will appear on your desktop when they are ready.

            IT Services
            """,
            delivery: .atFirstLogin(minutesEarlier: 43)),
        AuthoredMail(
            id: "mail.recreation.games",
            sender: "Recreation Committee",
            senderAddress: "recreation@hallways.internal",
            subject: "Games on your workstation",
            body: """
            Hello and welcome.

            Every workstation in the building includes a Games collection, available from your desktop. It is there for breaks.

            The collection is maintained by the Recreation Committee and may change from time to time.

            Recreation Committee
            """,
            delivery: .atFirstLogin(minutesEarlier: 17)),
        // Oct 8 (Episode 3, Dispatch test): delivered ONLY when BuildingDispatch
        // sends it (today: the DEBUG test trigger). Never at first login.
        AuthoredMail(
            id: BuildingDispatch.staffMeetingTestMailID,
            sender: "Administration",
            senderAddress: "administration@hallways.internal",
            subject: "New Employee Staff Meeting",
            body: """
            Welcome to the Hallways Building.

            All new employees are invited to attend a staff meeting.
            Further details will follow.
            """,
            delivery: .byEvent)
    ]

    static func authored(_ id: String) -> AuthoredMail? { all.first { $0.id == id } }
}

final class MailStore: ObservableObject {
    static let shared = MailStore()

    private static let deliveredKey = "mail.delivered"       // [id: delivery date] as JSON
    private static let readKey = "mail.read"                 // [id]

    @Published private(set) var delivered: [String: Date] = [:]
    @Published private(set) var read: Set<String> = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.deliveredKey),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            delivered = map
        }
        read = Set(UserDefaults.standard.stringArray(forKey: Self.readKey) ?? [])
    }

    /// The inbox, newest first.
    var inbox: [MailMessage] {
        delivered.compactMap { id, date in message(id, date: date) }.sorted { $0.date > $1.date }
    }

    var unreadCount: Int { delivered.keys.filter { !read.contains($0) }.count }

    func isRead(_ id: String) -> Bool { read.contains(id) }

    func message(_ id: String) -> MailMessage? {
        guard let date = delivered[id] else { return nil }
        return message(id, date: date)
    }

    private func message(_ id: String, date: Date) -> MailMessage? {
        guard let a = MailCatalog.authored(id) else { return nil }
        return MailMessage(id: a.id, sender: a.sender, senderAddress: a.senderAddress, subject: a.subject,
                           body: a.body.replacingOccurrences(of: "{employeeNumber}", with: EmployeeID.number ?? "(pending)"),
                           date: date)
    }

    /// First login: everything authored `.atFirstLogin` that isn't here yet.
    func deliverInitialIfNeeded(now: Date = Date()) {
        var changed = false
        for a in MailCatalog.all where delivered[a.id] == nil {
            if case .atFirstLogin(let minutes) = a.delivery {
                delivered[a.id] = now.addingTimeInterval(-Double(minutes) * 60)
                changed = true
            }
        }
        if changed { save(); diag("mail.deliveredInitial", ["count": delivered.count]) }
    }

    /// The hook for authored, event-driven mail (future story beats). Idempotent.
    func deliver(_ id: String, at date: Date = Date()) {
        guard MailCatalog.authored(id) != nil, delivered[id] == nil else { return }
        delivered[id] = date
        save()
        diag("mail.delivered", ["id": id])
    }

    func markRead(_ id: String) {
        guard delivered[id] != nil, !read.contains(id) else { return }
        read.insert(id)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(delivered) { UserDefaults.standard.set(data, forKey: Self.deliveredKey) }
        UserDefaults.standard.set(Array(read).sorted(), forKey: Self.readKey)
    }

    #if DEBUG
    /// DEV (Dispatch test trigger): take one delivered message back out, so
    /// the same test can be sent -- and arrive unread -- again.
    func devWithdraw(_ id: String) {
        guard delivered[id] != nil else { return }
        delivered[id] = nil
        read.remove(id)
        save()
    }
    #endif

    /// DEV (New Player reset): an empty mailbox until the next first login.
    func resetForNewPlayer() {
        delivered = [:]
        read = []
        UserDefaults.standard.removeObject(forKey: Self.deliveredKey)
        UserDefaults.standard.removeObject(forKey: Self.readKey)
    }
}

// MARK: - The Mail app

struct MailAppView: View {
    @ObservedObject var computer: OfficeComputer
    @ObservedObject private var store = MailStore.shared
    @State private var selected: String?

    var body: some View {
        GeometryReader { geo in
            // On the monitor (a landscape screen) the inbox and the open
            // message sit side by side.
            if geo.size.width > 440 {
                HStack(spacing: 0) {
                    list.frame(width: min(210, geo.size.width * 0.42))
                    Rectangle().fill(HallwaysOS.rule).frame(width: 1)
                    if let id = selected, let m = store.message(id) {
                        detail(m, showsBack: false)
                    } else {
                        placeholder
                    }
                }
            } else if let id = selected, let m = store.message(id) {
                detail(m, showsBack: true)
            } else {
                list
            }
        }
        .background(HallwaysOS.paper)
    }

    private func open(_ id: String) {
        selected = id
        store.markRead(id)
        computer.recordMailRead(id)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inbox").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(HallwaysOS.ink)
                Spacer()
                Text(store.unreadCount == 0 ? "All read" : "\(store.unreadCount) unread")
                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Rectangle().fill(HallwaysOS.rule).frame(height: 1)
            if store.inbox.isEmpty {
                Spacer()
                Text("No messages").font(.system(size: 15, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.inbox) { m in
                            Button { open(m.id) } label: { row(m) }
                                .buttonStyle(.plain)
                            Rectangle().fill(HallwaysOS.rule).frame(height: 1).padding(.leading, 30)
                        }
                    }
                }
            }
        }
    }

    private func row(_ m: MailMessage) -> some View {
        let unread = !store.isRead(m.id)
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(unread ? HallwaysOS.mailBlue : Color.clear).frame(width: 9, height: 9).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(m.sender).font(.system(size: 15, weight: unread ? .bold : .medium, design: .rounded))
                        .foregroundStyle(HallwaysOS.ink).lineLimit(1)
                    Spacer()
                    Text(Self.shortTime(m.date)).font(.system(size: 12, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                }
                Text(m.subject).font(.system(size: 14, weight: unread ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(HallwaysOS.ink).lineLimit(1)
                Text(m.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 13, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft).lineLimit(2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(selected == m.id ? HallwaysOS.mailBlue.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }

    private func detail(_ m: MailMessage, showsBack: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsBack {
                Button { selected = nil } label: {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Inbox") }
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(HallwaysOS.mailBlue)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(HallwaysOS.rule).frame(height: 1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(m.subject).font(.system(size: 21, weight: .bold, design: .rounded)).foregroundStyle(HallwaysOS.ink)
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            Circle().fill(HallwaysOS.mailBlue.opacity(0.18))
                            Text(String(m.sender.prefix(1))).font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(HallwaysOS.mailBlue)
                        }
                        .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.sender).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(HallwaysOS.ink)
                            Text(m.senderAddress).font(.system(size: 12, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                            Text("To: \(EmployeeID.number ?? "you")").font(.system(size: 12, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                        }
                        Spacer()
                        Text(m.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
                    }
                    Rectangle().fill(HallwaysOS.rule).frame(height: 1)
                    Text(m.body).font(.system(size: 16, design: .rounded)).foregroundStyle(HallwaysOS.ink)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope.open").font(.system(size: 34)).foregroundStyle(HallwaysOS.inkSoft.opacity(0.6))
            Text("Select a message").font(.system(size: 15, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func shortTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}
