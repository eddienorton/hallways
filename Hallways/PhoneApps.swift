import SwiftUI
import UIKit
import Combine

// Oct 8 -- THE PHONE'S FIRST APPS: Building GPS, HallChat, Mail, Directory.
//
// Oct 21: the phone is retired from the screen. Mail and HallChat are shown in
// the Building Life tray's Messages (BuildingLifeTray.swift); Building GPS, the
// staff Directory, Contacts and the Home screen are not reachable for now --
// their code and data are kept so any of them can be given a place again.
//
// The phone and the office computer are two physical interfaces to ONE
// Hallways information environment. Nothing here is a phone-only universe:
//   - Mail on the phone IS the office computer's mailbox (MailStore.shared):
//     the same messages, the same read state, the same history facts.
//   - HallChat's conversations live in ChatStore (catalog + persisted
//     delivered/read state, the Mail pattern), not in phone UI code.
//   - Directory entries live in DirectoryCatalog, plain data.
//   - Building GPS draws floors with the existing floor-map renderer
//     (HallwayScene.makeFloorMapTexture): the live floor through the
//     controller (exactly what the old mini-map showed), any other floor
//     from its stored plan (MazeStore.floorPlan) -- never loading it.
// Any of these can later appear on the computer by reading the same stores.
//
// Each app keeps its own place (PhoneApps) for the life of the app run:
// lowering the phone, switching apps, going Home -- nothing resets it.
//
// TOUCH GRAMMAR (unchanged from the physical phone): a TAP operates what is
// under the finger (only once the phone is held high enough to read, and
// never as the end of a drag); a DRAG anywhere moves the phone. The one
// exception is Building GPS's map: while it is ZOOMED IN, a drag on the map
// pans the map, and a pinch on it always zooms -- at normal size, a drag on
// the map moves the phone like anywhere else (see HallPhone.claimTouchForContent).
//
// Critters speak Hallenese, not English: nothing here gives a critter a
// voice. HallChat carries only the building's written institutional notices.

// MARK: - Taps on phone content

extension View {
    /// A tap on an app's content. (Oct 21: the phone is retired -- these apps now
    /// sit in the Building Life tray, where only the tray's handle resizes it, so
    /// a tap is simply a tap. It used to wait until the phone was held up high
    /// enough to read, and ignore the end of a drag that moved the phone.)
    func phoneTap(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle()).onTapGesture { action() }
    }
}

// MARK: - App state (kept while the app runs)

final class PhoneApps: ObservableObject {
    static let shared = PhoneApps()

    // Building GPS
    /// The floor being looked at; nil = whichever floor the player is on.
    @Published var gpsFloor: Int?
    @Published var gpsZoom: CGFloat = 1
    @Published var gpsPan: CGSize = .zero
    var gpsZoomBase: CGFloat = 1
    var gpsPanBase: CGSize = .zero
    // HallChat / Mail / Directory: the open item (nil = the list).
    @Published var chatThread: String?
    @Published var mailMessage: String?
    @Published var directoryEntry: String?
    /// Oct 18: Contacts' open entry (nil = the list).
    @Published var contactEntry: String?
    // Oct 19: Building Life -- open flat (full-screen) or not; its tab; the floor looked at closely.
    @Published var buildingLifeOpen = false
    @Published var buildingLifeTab = 0
    @Published var buildingLifeFloor: Int?

    private var planImages: [String: UIImage] = [:]
    private var liveKey: String?
    private var liveImage: UIImage?

    private init() {}

    /// Mail and HallChat messages that are due (both arrive once the player
    /// is an admitted employee). Called whenever the phone is taken hold of
    /// and when an app opens.
    func refreshDeliveries() {
        guard Admission.isCompleted else { return }
        MailStore.shared.deliverInitialIfNeeded()
        ChatStore.shared.deliverDue()
        BuildingDispatch.evaluate(reason: "phone")           // Oct 8 (Phase 1): anything the story now sends
    }

    /// Open mail `id` on the phone: exactly what the computer does when a
    /// message is opened -- mark it read in the shared store and record the
    /// fact (on the floor the player is on).
    func showMail(_ id: String, floor: Int, mail: MailStore = .shared, history: PlayerHistory = .shared) {
        mailMessage = id
        mail.markRead(id)
        history.record(.mailMessageRead, subject: id, floor: floor, detail: ["device": "phone"])
    }

    /// Oct 17: the side (in cells) of the square grid every Building GPS map is
    /// drawn on -- the building's 15, or more if any floor reaches past
    /// column/row 14 (Floor 5 does). One size for every floor: one scale.
    private var gpsGridKey: Int?
    private var gpsGridValue = 15
    func gpsGridSize(_ store: MazeStore) -> Int {
        if gpsGridKey == store.version { return gpsGridValue }
        var extent = 15
        for id in store.buildingFloorIDs {
            guard let plan = store.floorPlan(id: id) else { continue }
            for c in plan.cells { extent = max(extent, c.row + 1, c.col + 1) }
        }
        gpsGridKey = store.version
        gpsGridValue = extent
        return extent
    }

    func resetGPSView() {
        gpsZoom = 1; gpsZoomBase = 1
        gpsPan = .zero; gpsPanBase = .zero
    }

    /// The live floor the player is on (the old mini-map's full map), redrawn
    /// only when the player's cell or facing changes.
    func liveFloorImage(_ c: TapNavigationController, gridSize: Int = 15) -> UIImage {
        let key = "\(ObjectIdentifier(c).hashValue)|\(c.currentCell.row),\(c.currentCell.col)|\(c.facing)|\(gridSize)"
        if key == liveKey, let image = liveImage { return image }
        let image = c.currentFloorMapImage(includeWallObjectIndicators: true, gridSize: gridSize)
        liveKey = key
        liveImage = image
        return image
    }

    /// Another floor, from its stored plan. No one is drawn on it: the
    /// player's position is only known on the floor they are on.
    func planImage(_ plan: BuildingFloorPlan, version: Int, gridSize: Int = 15) -> UIImage {
        let key = "\(plan.id)|\(version)|\(gridSize)"
        if let image = planImages[key] { return image }
        let image = HallwayScene.makeFloorMapTexture(
            cells: plan.cells, end: plan.elevator,
            playerAt: GridCoordinate(row: -100, col: -100),          // off the map: nobody is here
            roomDoors: plan.roomDoors, bathroomDoors: plan.bathroomDoors,
            wallObjectFaces: plan.wallObjectFaces, doorFaces: plan.doorFaces, exitSignFaces: plan.exitSignFaces,
            gridSize: gridSize)
        planImages[key] = image
        return image
    }

    func resetForNewPlayer() {
        gpsFloor = nil
        resetGPSView()
        chatThread = nil
        mailMessage = nil
        directoryEntry = nil
        contactEntry = nil
        buildingLifeOpen = false
        buildingLifeTab = 0
        buildingLifeFloor = nil
        planImages = [:]
        liveKey = nil
        liveImage = nil
    }
}

// MARK: - Building data (read-only views of what MazeStore already holds)

/// One floor's stored plan, as Building GPS draws it (see MazeStore.floorPlan).
struct BuildingFloorPlan {
    let id: Int
    let cells: Set<GridCoordinate>
    let elevator: GridCoordinate
    let roomDoors: [GridCoordinate: RoomDoorPlacement]
    let bathroomDoors: [GridCoordinate: Direction]
    let wallObjectFaces: Set<WallFace>
    let doorFaces: Set<WallFace>
    let exitSignFaces: Set<WallFace>
}

enum BuildingFloors {
    static func name(_ id: Int) -> String { id == 1 ? "Lobby" : "Floor \(id)" }
    /// What the building has established about a floor (nothing invented).
    static func note(_ id: Int) -> String? {
        if id == Admission.administrationFloor { return "Administration" }
        if id == PlayerOffice.floor && Admission.isCompleted { return "Your office" }
        return nil
    }
}

// MARK: - HallChat data

nonisolated struct ChatThreadInfo: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
}

/// Oct 8 (Phase 1): how an authored HallChat message reaches the player --
/// the same idea as MailDelivery.
nonisolated enum ChatDelivery: Sendable, Equatable {
    /// Arrives with the phone, once the player is an admitted employee
    /// (ChatStore.deliverDue). Every notice before Phase 1 is this.
    case withPhone
    /// Arrives ONLY when BuildingDispatch.sendChat sends it -- never by itself.
    case byEvent
}

nonisolated struct AuthoredChatMessage: Sendable {
    let id: String
    let thread: String
    /// May use {employeeNumber}.
    let text: String
    /// Keeps the messages of one `.withPhone` delivery in sequence.
    let order: Int
    var delivery: ChatDelivery = .withPhone
}

nonisolated struct ChatMessage: Identifiable, Sendable, Equatable {
    let id: String
    let thread: String
    let text: String
    let date: Date
}

/// The building's written institutional notices. Departments only: critters
/// never write.
enum ChatCatalog {
    static let threads: [ChatThreadInfo] = [
        ChatThreadInfo(id: "chat.administration", title: "Administration", symbol: "building.columns.fill"),
        ChatThreadInfo(id: "chat.it", title: "IT Services", symbol: "wifi"),
        ChatThreadInfo(id: "chat.facilities", title: "Facilities", symbol: "wrench.and.screwdriver.fill"),
    ]

    static let messages: [AuthoredChatMessage] = [
        AuthoredChatMessage(id: "chat.admin.welcome", thread: "chat.administration",
                            text: "Welcome to the building. This is HallChat, the building's internal messaging.", order: 0),
        AuthoredChatMessage(id: "chat.admin.number", thread: "chat.administration",
                            text: "Your employee number is {employeeNumber}. Administration is on Floor 2 if you need anything.", order: 1),
        AuthoredChatMessage(id: "chat.it.phone", thread: "chat.it",
                            text: "Your phone is now on the building network. Building GPS, HallChat, Mail and Directory are ready to use.", order: 2),
        AuthoredChatMessage(id: "chat.facilities.office", thread: "chat.facilities",
                            text: "Your office on Floor 3 is ready. If anything there is broken, missing, or making a noise it shouldn't, please let Facilities know.", order: 3),
    ]

    static func thread(_ id: String) -> ChatThreadInfo? { threads.first { $0.id == id } }
    static func message(_ id: String) -> AuthoredChatMessage? { messages.first { $0.id == id } }
}

/// The player's HallChat state: which notices have arrived (and when) and
/// which have been read. Persisted like MailStore; shared by any device.
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    private static let deliveredKey = "hallchat.delivered"
    private static let readKey = "hallchat.read"

    @Published private(set) var delivered: [String: Date] = [:]
    @Published private(set) var read: Set<String> = []

    /// Oct 8: where this state is saved, and the ledger reads are recorded in.
    /// The app's store (`shared`) uses the real ones; tests pass throwaways.
    private let defaults: UserDefaults
    private let history: PlayerHistory
    /// The authored messages this store can deliver (the app: ChatCatalog;
    /// tests may add their own `.byEvent` fixtures without authoring story text).
    let catalog: [AuthoredChatMessage]

    init(defaults: UserDefaults = .standard, history: PlayerHistory = .shared,
         catalog: [AuthoredChatMessage] = ChatCatalog.messages) {
        self.defaults = defaults
        self.history = history
        self.catalog = catalog
        if let data = defaults.data(forKey: Self.deliveredKey),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            delivered = map
        }
        read = Set(defaults.stringArray(forKey: Self.readKey) ?? [])
    }

    /// Every `.withPhone` notice not here yet arrives now (in order).
    /// `.byEvent` messages never arrive here -- only through Dispatch.
    func deliverDue(now: Date = Date()) {
        var changed = false
        for m in catalog where delivered[m.id] == nil && m.delivery == .withPhone {
            delivered[m.id] = now.addingTimeInterval(Double(m.order))
            changed = true
        }
        if changed { save(); diag("hallchat.delivered", ["count": delivered.count]) }
    }

    /// The hook for authored, event-driven notices (BuildingDispatch.sendChat).
    /// Idempotent: true only the first time `id` arrives.
    @discardableResult
    func deliver(_ id: String, at date: Date = Date()) -> Bool {
        guard catalog.contains(where: { $0.id == id }), delivered[id] == nil else { return false }
        delivered[id] = date
        save()
        diag("hallchat.delivered", ["id": id])
        return true
    }

    func isDelivered(_ id: String) -> Bool { delivered[id] != nil }

    func messages(in thread: String) -> [ChatMessage] {
        catalog.compactMap { a -> ChatMessage? in
            guard a.thread == thread, let date = delivered[a.id] else { return nil }
            return ChatMessage(id: a.id, thread: a.thread,
                               text: a.text.replacingOccurrences(of: "{employeeNumber}", with: EmployeeID.number ?? "(pending)"),
                               date: date)
        }
        .sorted { $0.date < $1.date }
    }

    /// Threads with at least one message, most recent first.
    var activeThreads: [ChatThreadInfo] {
        ChatCatalog.threads
            .filter { !messages(in: $0.id).isEmpty }
            .sorted { (messages(in: $0.id).last?.date ?? .distantPast) > (messages(in: $1.id).last?.date ?? .distantPast) }
    }

    func unreadCount(in thread: String) -> Int { messages(in: thread).filter { !read.contains($0.id) }.count }
    var unreadCount: Int { delivered.keys.filter { !read.contains($0) }.count }

    func markThreadRead(_ thread: String) {
        let ids = messages(in: thread).map(\.id).filter { !read.contains($0) }
        guard !ids.isEmpty else { return }
        read.formUnion(ids)
        save()
        history.record(HistoryEventKind("hallchat.thread.read"), subject: thread, detail: ["count": "\(ids.count)"])
    }

    private func save() {
        if let data = try? JSONEncoder().encode(delivered) { defaults.set(data, forKey: Self.deliveredKey) }
        defaults.set(Array(read).sorted(), forKey: Self.readKey)
    }

    /// DEV (New Player reset): nothing has arrived yet.
    func resetForNewPlayer() {
        delivered = [:]
        read = []
        defaults.removeObject(forKey: Self.deliveredKey)
        defaults.removeObject(forKey: Self.readKey)
    }
}

// MARK: - Directory data

nonisolated struct DirectoryEntry: Identifiable, Sendable {
    enum Kind: Sendable { case you, person, department }
    let id: String
    let kind: Kind
    let name: String
    let role: String
    /// nil = not established (shown as "Not listed").
    let floor: String?
    let location: String?
    let contact: String?
}

/// Only the people and departments the building has actually established.
enum DirectoryCatalog {
    static var entries: [DirectoryEntry] {
        let admitted = Admission.isCompleted
        return [
            DirectoryEntry(id: "dir.you", kind: .you, name: "You",
                           role: EmployeeID.number.map { "Employee \($0)" } ?? "New employee (number pending)",
                           floor: admitted ? BuildingFloors.name(PlayerOffice.floor) : nil,
                           location: admitted ? "Your office" : nil, contact: nil),
            DirectoryEntry(id: "dir.administration", kind: .department, name: "Administration",
                           role: "Reception and employee ID cards", floor: BuildingFloors.name(Admission.administrationFloor),
                           location: "Administration", contact: "administration@hallways.internal"),
            DirectoryEntry(id: "dir.juanita", kind: .person, name: "Juanita",
                           role: "Administrator, reception", floor: BuildingFloors.name(Admission.administrationFloor),
                           location: "Administration", contact: nil),
            DirectoryEntry(id: "dir.facilities", kind: .department, name: "Facilities",
                           role: "Offices, fixtures and repairs", floor: nil, location: nil,
                           contact: "facilities@hallways.internal"),
            DirectoryEntry(id: "dir.it", kind: .department, name: "IT Services",
                           role: "Workstations", floor: nil, location: nil,
                           contact: "it.services@hallways.internal"),
            DirectoryEntry(id: "dir.recreation", kind: .department, name: "Recreation Committee",
                           role: "The Games collection", floor: nil, location: nil,
                           contact: "recreation@hallways.internal"),
        ]
    }

    static func entry(_ id: String) -> DirectoryEntry? { entries.first { $0.id == id } }
}

// MARK: - Screen pieces

enum PhoneStyle {
    static let paper = Color(red: 0.97, green: 0.97, blue: 0.95)
    static let ink = Color(red: 0.13, green: 0.15, blue: 0.19)
    static let inkSoft = Color(red: 0.42, green: 0.45, blue: 0.5)
    static let rule = Color(red: 0.86, green: 0.87, blue: 0.88)
    static let gps = Color(red: 0.16, green: 0.58, blue: 0.56)
    static let chat = Color(red: 0.93, green: 0.58, blue: 0.2)
    static let mail = Color(red: 0.2, green: 0.5, blue: 0.9)
    static let directory = Color(red: 0.62, green: 0.38, blue: 0.78)
    static let contacts = Color(red: 0.86, green: 0.42, blue: 0.36)
    static let buildingLife = Color(red: 0.23, green: 0.52, blue: 0.36)
    /// Space kept under an app's content. (Oct 21: was 96 -- the phone's bottom
    /// tenth sat in the player's hand, past the screen edge. In the tray the
    /// bottom is the tray's own, above the home indicator.)
    static let handClearance: CGFloat = 16
}

/// The bar across the top of every app: back on the left, title centred.
struct PhoneTopBar: View {
    let title: String
    var back: String? = nil
    var tint: Color = PhoneStyle.ink
    var onBack: () -> Void = {}

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(PhoneStyle.ink)
            HStack {
                if let back {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                        Text(back).font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(tint)
                    .padding(.vertical, 8).padding(.trailing, 12)
                    .phoneTap(onBack)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(PhoneStyle.rule).frame(height: 1) }
    }
}

private struct UnreadBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Color(red: 0.92, green: 0.36, blue: 0.3), in: Capsule())
    }
}

// MARK: - Home

/// A familiar smartphone home screen, in Hallways' own style: small
/// rounded-square icons with their names beneath, four to a row, on the
/// wallpaper -- with room for more apps. Laid out on the screen's fixed
/// 320-wide canvas (HallPhoneLayout.screenCanvasWidth), so it fits the
/// phone's display at every lift and in either orientation.
struct PhoneHomeScreen: View {
    @ObservedObject var phone: HallPhone
    @ObservedObject private var mail = MailStore.shared
    @ObservedObject private var chat = ChatStore.shared

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: 4)

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Self.columns, spacing: 18) {
                appIcon(.buildingGPS, "Building GPS", art: .gps, unread: 0)
                appIcon(.hallChat, "HallChat", art: .chat, unread: chat.unreadCount)
                appIcon(.mail, "Mail", art: .mail, unread: mail.unreadCount)
                appIcon(.directory, "Directory", art: .directory, unread: 0)
                appIcon(.contacts, "Contacts", art: .contacts, unread: 0)
                appIcon(.buildingLife, "Building Life", art: .buildingLife, unread: 0)
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, PhoneStyle.handClearance)
    }

    private func appIcon(_ app: PhoneScreen, _ name: String, art: PhoneAppIcon.Art, unread: Int) -> some View {
        VStack(spacing: 5) {
            PhoneAppIcon(art: art)
                .frame(width: 58, height: 58)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 21, minHeight: 21)
                            .background(Color(red: 0.92, green: 0.3, blue: 0.26), in: Capsule())
                            .offset(x: 7, y: -7)
                    }
                }
            Text(name)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .phoneTap { phone.open(app) }
    }
}

// MARK: - Notifications on the screen

/// Compact notifications across the top of whatever the phone is showing.
/// Tapping one opens what it announces (for mail: Mail, with that message
/// open and read); ignored, it goes away by itself after a while
/// (HallPhone.notificationLifetime) -- the message stays in its app.
struct PhoneNotificationBanners: View {
    @ObservedObject var phone: HallPhone
    let mazeStore: MazeStore

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(phone.notifications.prefix(2))) { note in banner(note) }
        }
        .padding(.horizontal, 10)
        .padding(.top, 38)
    }

    private func banner(_ note: PhoneNotification) -> some View {
        HStack(spacing: 10) {
            PhoneAppIcon(art: { () -> PhoneAppIcon.Art in if case .chat = note.opens { return .chat } else { return .mail } }()).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(note.source).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text(note.title).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 4)
            Text("now").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(red: 0.1, green: 0.12, blue: 0.17).opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        .transition(.move(edge: .top).combined(with: .opacity))
        .phoneTap {
            phone.dismiss(note.id)
            switch note.opens {
            case .mail(let id):
                PhoneApps.shared.showMail(id, floor: mazeStore.currentMazeID)
                phone.open(.mail)
            case .chat(let thread):
                // The thread view marks itself read when it appears.
                PhoneApps.shared.chatThread = thread
                phone.open(.hallChat)
            case nil:
                break
            }
        }
    }
}

/// Hallways' own app icon artwork: a rounded tile with its own gradient
/// and a small composed picture -- not anyone else's icons.
struct PhoneAppIcon: View {
    enum Art { case gps, chat, mail, directory, contacts, buildingLife }
    let art: Art

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.24, style: .circular)
                    .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: s * 0.24, style: .circular)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                picture(s)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }

    private var colors: [Color] {
        switch art {
        case .gps: return [Color(red: 0.24, green: 0.72, blue: 0.68), Color(red: 0.1, green: 0.45, blue: 0.47)]
        case .chat: return [Color(red: 0.99, green: 0.7, blue: 0.32), Color(red: 0.88, green: 0.46, blue: 0.14)]
        case .mail: return [Color(red: 0.36, green: 0.64, blue: 0.98), Color(red: 0.15, green: 0.4, blue: 0.82)]
        case .directory: return [Color(red: 0.74, green: 0.52, blue: 0.9), Color(red: 0.48, green: 0.28, blue: 0.68)]
        case .contacts: return [Color(red: 0.98, green: 0.6, blue: 0.48), Color(red: 0.8, green: 0.32, blue: 0.3)]
        case .buildingLife: return [Color(red: 0.38, green: 0.72, blue: 0.5), Color(red: 0.15, green: 0.42, blue: 0.3)]
        }
    }

    @ViewBuilder
    private func picture(_ s: CGFloat) -> some View {
        switch art {
        case .gps:
            // A little floor plan with a "you" arrow on it.
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: s * 0.2, y: s * 0.32)); p.addLine(to: CGPoint(x: s * 0.8, y: s * 0.32))
                    p.move(to: CGPoint(x: s * 0.5, y: s * 0.32)); p.addLine(to: CGPoint(x: s * 0.5, y: s * 0.8))
                    p.move(to: CGPoint(x: s * 0.2, y: s * 0.32)); p.addLine(to: CGPoint(x: s * 0.2, y: s * 0.62))
                    p.move(to: CGPoint(x: s * 0.5, y: s * 0.62)); p.addLine(to: CGPoint(x: s * 0.8, y: s * 0.62))
                }
                .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: s * 0.09, lineCap: .round))
                Image(systemName: "location.north.fill")
                    .font(.system(size: s * 0.3, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: s * 0.0, y: s * 0.06)
            }
        case .chat:
            ZStack {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: s * 0.36, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .offset(x: -s * 0.1, y: -s * 0.07)
                Image(systemName: "bubble.right.fill")
                    .font(.system(size: s * 0.36, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: s * 0.1, y: s * 0.09)
            }
        case .mail:
            Image(systemName: "envelope.fill")
                .font(.system(size: s * 0.4, weight: .semibold))
                .foregroundStyle(.white)
        case .directory:
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.06)
                    .fill(Color.white)
                    .frame(width: s * 0.56, height: s * 0.44)
                Image(systemName: "person.fill")
                    .font(.system(size: s * 0.2, weight: .bold))
                    .foregroundStyle(colors[1])
                    .offset(x: -s * 0.12)
                VStack(alignment: .leading, spacing: s * 0.05) {
                    Capsule().frame(width: s * 0.16, height: s * 0.04)
                    Capsule().frame(width: s * 0.12, height: s * 0.04)
                }
                .foregroundStyle(colors[1].opacity(0.6))
                .offset(x: s * 0.12)
            }
        case .buildingLife:
            // A little building in section: floors, and a few residents on them.
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.04).fill(Color.white.opacity(0.92)).frame(width: s * 0.46, height: s * 0.6)
                VStack(spacing: s * 0.09) {
                    ForEach(0..<4, id: \.self) { _ in Rectangle().fill(colors[1].opacity(0.35)).frame(width: s * 0.46, height: s * 0.025) }
                }
                Circle().fill(colors[1]).frame(width: s * 0.08).offset(x: -s * 0.1, y: -s * 0.15)
                Circle().fill(Color(red: 0.95, green: 0.55, blue: 0.2)).frame(width: s * 0.08).offset(x: s * 0.08, y: s * 0.02)
                Circle().fill(colors[1]).frame(width: s * 0.08).offset(x: -s * 0.03, y: s * 0.19)
            }
        case .contacts:
            // A round face (no mouth: critters don't talk) with a little sound wave.
            ZStack {
                Circle().fill(Color.white).frame(width: s * 0.44, height: s * 0.44).offset(x: -s * 0.07)
                HStack(spacing: s * 0.07) {
                    Circle().frame(width: s * 0.07, height: s * 0.07)
                    Circle().frame(width: s * 0.07, height: s * 0.07)
                }
                .foregroundStyle(colors[1])
                .offset(x: -s * 0.07, y: -s * 0.03)
                Image(systemName: "wave.3.right")
                    .font(.system(size: s * 0.18, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: s * 0.24)
            }
        }
    }
}

// MARK: - Building GPS

struct BuildingGPSApp: View {
    let phone: HallPhone                                  // not observed: moving the phone never redraws the app
    @ObservedObject var navBridge: NavigationBridge
    @ObservedObject var mazeStore: MazeStore
    @ObservedObject private var apps = PhoneApps.shared

    private let side: CGFloat = 296

    var body: some View {
        let current = mazeStore.currentMazeID
        let floors = mazeStore.buildingFloorIDs
        let viewing = apps.gpsFloor ?? current
        let index = floors.firstIndex(of: viewing)
        VStack(spacing: 10) {
            PhoneTopBar(title: "Building GPS", back: "Home", tint: PhoneStyle.gps) { phone.open(.home) }
            HStack(spacing: 8) {
                stepButton("chevron.left", enabled: (index ?? 0) > 0) { if let i = index, i > 0 { show(floors[i - 1], current: current) } }
                VStack(spacing: 1) {
                    Text(BuildingFloors.name(viewing)).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(PhoneStyle.ink)
                    Text(BuildingFloors.note(viewing) ?? " ").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                }
                .frame(maxWidth: .infinity)
                stepButton("chevron.right", enabled: index.map { $0 < floors.count - 1 } ?? false) {
                    if let i = index, i < floors.count - 1 { show(floors[i + 1], current: current) }
                }
            }
            .padding(.horizontal, 12)
            statusLine(viewing: viewing, current: current)
            map(viewing: viewing, current: current)
            Text(apps.gpsZoom > 1.01 ? "Drag the map to look around. Pinch to zoom." : "Pinch the map to zoom in.")
                .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
            Spacer(minLength: 0)
        }
        .padding(.bottom, PhoneStyle.handClearance)
    }

    private func show(_ floor: Int, current: Int) {
        apps.gpsFloor = floor == current ? nil : floor
        apps.resetGPSView()
    }

    private func stepButton(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(enabled ? PhoneStyle.gps : PhoneStyle.rule)
            .frame(width: 44, height: 44)
            .background(PhoneStyle.gps.opacity(enabled ? 0.12 : 0.04), in: Circle())
            .phoneTap { if enabled { action() } }
    }

    @ViewBuilder
    private func statusLine(viewing: Int, current: Int) -> some View {
        if viewing == current {
            Label("You are on this floor", systemImage: "location.fill")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(PhoneStyle.gps)
                .frame(height: 30)
        } else {
            HStack(spacing: 8) {
                Text("You are on \(BuildingFloors.name(current))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                Text("Show my floor")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(PhoneStyle.gps, in: Capsule())
                    .phoneTap { show(current, current: current) }
            }
            .frame(height: 30)
        }
    }

    @ViewBuilder
    private func map(viewing: Int, current: Int) -> some View {
        let frame = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Group {
            if viewing == current {
                if let controller = navBridge.controller {
                    LiveFloorMap(controller: controller, apps: apps, gridSize: apps.gpsGridSize(mazeStore))
                } else {
                    Text("Locating...").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                }
            } else if let plan = mazeStore.floorPlan(id: viewing) {
                Image(uiImage: apps.planImage(plan, version: mazeStore.version, gridSize: apps.gpsGridSize(mazeStore)))
                    .resizable().interpolation(.high)
            } else {
                Text("No plan for this floor").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
            }
        }
        .frame(width: side, height: side)
        .scaleEffect(apps.gpsZoom)
        .offset(apps.gpsPan)
        .frame(width: side, height: side)
        .background(Color(white: 0.85))
        .clipShape(frame)
        .overlay(frame.stroke(viewing == current ? PhoneStyle.gps : PhoneStyle.rule, lineWidth: viewing == current ? 3 : 1.5))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                // Zoomed in, the map takes the drag (pan); at normal size it
                // leaves it alone, so the phone moves as everywhere else.
                guard apps.gpsZoom > 1.01, phone.screenInteractive || phone.contentClaimsTouch else { return }
                phone.claimTouchForContent()
                setPan(CGSize(width: apps.gpsPanBase.width + v.translation.width, height: apps.gpsPanBase.height + v.translation.height))
            }
            .onEnded { _ in
                apps.gpsPanBase = apps.gpsPan
                phone.endContentClaim()
            })
        .simultaneousGesture(MagnifyGesture()
            .onChanged { v in
                guard phone.screenInteractive || phone.contentClaimsTouch else { return }
                phone.claimTouchForContent()
                apps.gpsZoom = min(4, max(1, apps.gpsZoomBase * v.magnification))
                setPan(apps.gpsPan)
            }
            .onEnded { _ in
                apps.gpsZoomBase = apps.gpsZoom
                apps.gpsPanBase = apps.gpsPan
                phone.endContentClaim()
            })
    }

    /// Pan, kept so the map never slides out of its frame.
    private func setPan(_ pan: CGSize) {
        let limit = apps.gpsZoom <= 1.0001 ? 0 : side * (apps.gpsZoom - 1) / 2
        apps.gpsPan = CGSize(width: min(max(pan.width, -limit), limit), height: min(max(pan.height, -limit), limit))
    }
}

/// The floor the player is on, live: follows them as they move.
private struct LiveFloorMap: View {
    @ObservedObject var controller: TapNavigationController
    let apps: PhoneApps
    var gridSize: Int = 15
    var body: some View {
        Image(uiImage: apps.liveFloorImage(controller, gridSize: gridSize)).resizable().interpolation(.high)
    }
}

// MARK: - HallChat

struct HallChatApp: View {
    let phone: HallPhone                                  // not observed: moving the phone never redraws the app
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var apps = PhoneApps.shared

    var body: some View {
        VStack(spacing: 0) {
            if let id = apps.chatThread, let info = ChatCatalog.thread(id) {
                PhoneTopBar(title: info.title, back: "HallChat", tint: PhoneStyle.chat) { apps.chatThread = nil }
                thread(info)
            } else {
                PhoneTopBar(title: "HallChat", back: "Back", tint: PhoneStyle.chat) { phone.open(.home) }   // (Oct 21: back to Building Life)
                list
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, PhoneStyle.handClearance)
    }

    @ViewBuilder
    private var list: some View {
        let threads = chat.activeThreads
        if threads.isEmpty {
            Text(Admission.isCompleted ? "No conversations yet." : "HallChat is for building employees.")
                .font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                .padding(.top, 60)
        } else {
            ForEach(threads) { info in
                let last = chat.messages(in: info.id).last
                let unread = chat.unreadCount(in: info.id)
                HStack(spacing: 12) {
                    avatar(info)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(info.title).font(.system(size: 16, weight: unread > 0 ? .bold : .semibold, design: .rounded))
                                .foregroundStyle(PhoneStyle.ink)
                            Spacer()
                            if let last { Text(MailAppView.shortTime(last.date)).font(.system(size: 12, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft) }
                        }
                        HStack(alignment: .top) {
                            Text(last?.text ?? "").font(.system(size: 14, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft).lineLimit(2)
                            Spacer(minLength: 4)
                            if unread > 0 { UnreadBadge(count: unread) }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .phoneTap {
                    apps.chatThread = info.id
                    chat.markThreadRead(info.id)
                }
                Rectangle().fill(PhoneStyle.rule).frame(height: 1).padding(.leading, 70)
            }
        }
    }

    private func avatar(_ info: ChatThreadInfo) -> some View {
        Image(systemName: info.symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(PhoneStyle.chat, in: Circle())
    }

    private func thread(_ info: ChatThreadInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(chat.messages(in: info.id)) { m in
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.text)
                        .font(.system(size: 16, design: .rounded))
                        .foregroundStyle(PhoneStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(PhoneStyle.chat.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text(m.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                        .padding(.leading, 6)
                }
                .frame(maxWidth: 270, alignment: .leading)
            }
            Text("Building notices from \(info.title).")
                .font(.system(size: 12, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
        .padding(14)
        .onAppear { chat.markThreadRead(info.id) }
    }
}

// MARK: - Mail (the office computer's mailbox)

struct PhoneMailApp: View {
    let phone: HallPhone                                  // not observed: moving the phone never redraws the app
    @ObservedObject var mazeStore: MazeStore
    @ObservedObject private var store = MailStore.shared
    @ObservedObject private var apps = PhoneApps.shared

    var body: some View {
        VStack(spacing: 0) {
            if let id = apps.mailMessage, let m = store.message(id) {
                PhoneTopBar(title: "Mail", back: "Inbox", tint: PhoneStyle.mail) { apps.mailMessage = nil }
                detail(m)
            } else {
                PhoneTopBar(title: "Mail", back: "Back", tint: PhoneStyle.mail) { phone.open(.home) }   // (Oct 21: back to Building Life)
                list
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, PhoneStyle.handClearance)
    }

    private func open(_ id: String) { apps.showMail(id, floor: mazeStore.currentMazeID) }

    @ViewBuilder
    private var list: some View {
        HStack {
            Text("Inbox").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(PhoneStyle.ink)
            Spacer()
            Text(store.unreadCount == 0 ? "All read" : "\(store.unreadCount) unread")
                .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        if store.inbox.isEmpty {
            Text(Admission.isCompleted ? "No messages" : "Your building mailbox opens once you are an employee.")
                .multilineTextAlignment(.center)
                .font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                .padding(.top, 50).padding(.horizontal, 20)
        } else {
            ForEach(store.inbox) { m in
                let unread = !store.isRead(m.id)
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(unread ? PhoneStyle.mail : Color.clear).frame(width: 9, height: 9).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(m.sender).font(.system(size: 15, weight: unread ? .bold : .medium, design: .rounded))
                                .foregroundStyle(PhoneStyle.ink).lineLimit(1)
                            Spacer()
                            Text(MailAppView.shortTime(m.date)).font(.system(size: 12, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                        }
                        Text(m.subject).font(.system(size: 14, weight: unread ? .semibold : .regular, design: .rounded))
                            .foregroundStyle(PhoneStyle.ink).lineLimit(1)
                        Text(MailCatalog.preview(m.body))
                            .font(.system(size: 13, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft).lineLimit(1)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .phoneTap { open(m.id) }
                Rectangle().fill(PhoneStyle.rule).frame(height: 1).padding(.leading, 31)
            }
        }
    }

    private func detail(_ m: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m.subject).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(PhoneStyle.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.sender).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(PhoneStyle.ink)
                Text(m.senderAddress).font(.system(size: 12, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                Text(m.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
            }
            Rectangle().fill(PhoneStyle.rule).frame(height: 1)
            Text(MailCatalog.display(m.body)).font(.system(size: 15, design: .rounded)).foregroundStyle(PhoneStyle.ink)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Directory

struct DirectoryApp: View {
    let phone: HallPhone                                  // not observed: moving the phone never redraws the app
    @ObservedObject private var apps = PhoneApps.shared

    var body: some View {
        VStack(spacing: 0) {
            if let id = apps.directoryEntry, let e = DirectoryCatalog.entry(id) {
                PhoneTopBar(title: "Directory", back: "Directory", tint: PhoneStyle.directory) { apps.directoryEntry = nil }
                detail(e)
            } else {
                PhoneTopBar(title: "Directory", back: "Home", tint: PhoneStyle.directory) { phone.open(.home) }
                ForEach(DirectoryCatalog.entries) { e in
                    HStack(spacing: 12) {
                        icon(e, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(PhoneStyle.ink)
                            Text([e.role, e.floor].compactMap { $0 }.joined(separator: " \u{00B7} "))
                                .font(.system(size: 13, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(PhoneStyle.rule)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .phoneTap { apps.directoryEntry = e.id }
                    Rectangle().fill(PhoneStyle.rule).frame(height: 1).padding(.leading, 66)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, PhoneStyle.handClearance)
    }

    private func icon(_ e: DirectoryEntry, size: CGFloat) -> some View {
        let symbol: String
        switch e.kind {
        case .you: symbol = "person.crop.circle.fill"
        case .person: symbol = "person.fill"
        case .department: symbol = "building.2.fill"
        }
        return Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(e.kind == .department ? PhoneStyle.directory : PhoneStyle.directory.opacity(0.7), in: Circle())
    }

    private func detail(_ e: DirectoryEntry) -> some View {
        VStack(spacing: 14) {
            icon(e, size: 72).padding(.top, 18)
            VStack(spacing: 3) {
                Text(e.name).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(PhoneStyle.ink)
                Text(e.role).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 0) {
                row("Floor", e.floor)
                row("Where", e.location)
                row("Contact", e.contact)
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(PhoneStyle.rule, lineWidth: 1))
            .padding(.horizontal, 14)
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                .frame(width: 70, alignment: .leading)
            Text(value ?? "Not listed").font(.system(size: 14, weight: value == nil ? .regular : .medium, design: .rounded))
                .foregroundStyle(value == nil ? PhoneStyle.inkSoft.opacity(0.7) : PhoneStyle.ink)
                .lineLimit(2).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(PhoneStyle.rule).frame(height: 1).padding(.leading, 14) }
    }
}


// MARK: - Contacts (Oct 18)

/// The characters the player has met (ContactsStore), each with its portrait,
/// a line about it, and its sound. Nothing else: no calling, no tracking.
struct ContactsApp: View {
    let phone: HallPhone                                  // not observed: moving the phone never redraws the app
    @ObservedObject private var apps = PhoneApps.shared
    @ObservedObject private var store = ContactsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if let id = apps.contactEntry, let c = CharacterRegistry.identity(id), store.hasMet(id) {
                PhoneTopBar(title: c.name, back: "Contacts", tint: PhoneStyle.contacts) { apps.contactEntry = nil }
                detail(c)
            } else {
                PhoneTopBar(title: "Contacts", back: "Home", tint: PhoneStyle.contacts) { phone.open(.home) }
                if store.contacts.isEmpty {
                    Text("No contacts yet.\nThe building's residents appear here as you meet them.")
                        .font(.system(size: 14, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                        .multilineTextAlignment(.center)
                        .padding(.top, 40).padding(.horizontal, 24)
                }
                ForEach(store.contacts) { c in
                    HStack(spacing: 12) {
                        portrait(c, size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(PhoneStyle.ink)
                            Text(c.blurb).font(.system(size: 12, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(PhoneStyle.rule)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .phoneTap { apps.contactEntry = c.id }
                    Rectangle().fill(PhoneStyle.rule).frame(height: 1).padding(.leading, 72)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, PhoneStyle.handClearance)
    }

    private func portrait(_ c: CharacterIdentity, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [c.tint.opacity(0.25), c.tint.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            if let image = store.portrait(c.id) {
                Image(uiImage: image).resizable().scaledToFit().padding(size * 0.04)
            } else {
                Image(systemName: c.symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
    }

    private func detail(_ c: CharacterIdentity) -> some View {
        VStack(spacing: 14) {
            portrait(c, size: 128).padding(.top, 16)
            Text(c.name).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(PhoneStyle.ink)
            Text(c.blurb).font(.system(size: 14, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                .multilineTextAlignment(.center).padding(.horizontal, 22)
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 15, weight: .bold))
                Text("Hear").font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(PhoneStyle.contacts, in: Capsule())
            .phoneTap { store.preview(c.id) }
            if let when = store.met[c.id] {
                Text("Met " + when.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft.opacity(0.8))
            }
        }
    }
}

/// Oct 18: a soft pulse in the phone's status strip while a critter is heard
/// nearby -- stronger the nearer (louder) it is; nothing when none is. It says
/// that something is close, never where. Off with -HallwaysPhoneProximity NO.
struct CritterProximityPulse: View {
    let light: Bool
    private var enabled: Bool { UserDefaults.standard.object(forKey: "HallwaysPhoneProximity") as? Bool ?? true }

    var body: some View {
        if enabled {
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                let level = CGFloat(AudioWatch.nearness())
                let beat = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * (2 + Double(level) * 5))
                ZStack {
                    Circle().stroke(lineWidth: 1.5).frame(width: 8 + 8 * level * CGFloat(beat), height: 8 + 8 * level * CGFloat(beat))
                        .opacity(Double(level) * 0.7)
                    Circle().frame(width: 5, height: 5).opacity(level > 0.02 ? 0.35 + 0.65 * Double(level) : 0)
                }
                .foregroundStyle(light ? Color.white : Color(red: 0.86, green: 0.42, blue: 0.36))
                .frame(width: 18, height: 18)
            }
        }
    }
}
