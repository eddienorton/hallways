import SwiftUI
import SceneKit
import UIKit
import Combine

// Oct 7 -- F. THE OFFICE COMPUTER (Floor 3, the player's desk).
//
// THIS IS A PHYSICAL DESKTOP COMPUTER (Oct 7, after the first phone test).
// Tapping the workstation (computer, desk or desk chair) from inside the
// office sits the player down: the camera glides round the desk into the
// chair, far enough back that the whole monitor fits with room around it.
// The desktop is simply ON the monitor -- a SwiftUI surface laid exactly over
// the 3D screen's projected rectangle. No zoom, no full-device takeover: the
// office stays visible around it.
//
// COMPUTER CONTROLS AFFECT THE COMPUTER. PHYSICAL-WORLD ACTIONS AFFECT THE
// PHYSICAL WORLD. Nothing on the screen moves the player. A tap on the room
// outside the monitor means "get up": the session ends, the camera rises out
// of the chair, goes round the open end of the desk and stops out in the
// room facing the door; then ordinary navigation resumes.
//
// The player is never kept here, nothing opens by itself, and nothing about
// the desk locks the rest of the building.
//
// Not a general OS: one app at a time, filling the screen; no windows to
// drag or resize. Apps are registered in `ComputerApps.all` (see
// ComputerAppID / ComputerAppInfo) -- Mail and Games now; Work later plugs
// in by adding an entry and a view.

/// The palette of the Hallways workstation (its own, unbranded look).
enum HallwaysOS {
    static let wallpaperTop = Color(red: 0.10, green: 0.15, blue: 0.25)
    static let wallpaperMid = Color(red: 0.17, green: 0.30, blue: 0.38)
    static let wallpaperBottom = Color(red: 0.11, green: 0.17, blue: 0.24)
    static let bezel = Color(red: 0.13, green: 0.14, blue: 0.16)
    static let taskbar = Color(red: 0.07, green: 0.09, blue: 0.13).opacity(0.86)
    static let paper = Color(red: 0.97, green: 0.97, blue: 0.95)
    static let ink = Color(red: 0.13, green: 0.15, blue: 0.19)
    static let inkSoft = Color(red: 0.42, green: 0.45, blue: 0.5)
    static let rule = Color(red: 0.86, green: 0.87, blue: 0.88)
    static let mailBlue = Color(red: 0.2, green: 0.5, blue: 0.9)
    static let gamesCoral = Color(red: 0.95, green: 0.45, blue: 0.3)
    static let workSlate = Color(red: 0.47, green: 0.52, blue: 0.58)
    static let brand = Color(red: 0.93, green: 0.73, blue: 0.3)
}

// MARK: - App model

enum ComputerAppID: String, CaseIterable, Identifiable {
    case mail, games, work
    var id: String { rawValue }
}

struct ComputerAppInfo: Identifiable {
    let id: ComputerAppID
    let title: String
    let symbol: String
    let tint: Color
    /// False = a placeholder icon (shown, not openable yet).
    let isAvailable: Bool
    let caption: String?
}

enum ComputerApps {
    static let all: [ComputerAppInfo] = [
        ComputerAppInfo(id: .mail, title: "Mail", symbol: "envelope.fill", tint: HallwaysOS.mailBlue, isAvailable: true, caption: nil),
        ComputerAppInfo(id: .games, title: "Games", symbol: "gamecontroller.fill", tint: HallwaysOS.gamesCoral, isAvailable: true, caption: nil),
        // Placeholder only: Work apps are provisioned later (not in this pass).
        ComputerAppInfo(id: .work, title: "Work", symbol: "folder.fill", tint: HallwaysOS.workSlate, isAvailable: false,
                        caption: "Not yet provisioned")
    ]
    static func info(_ id: ComputerAppID) -> ComputerAppInfo { all.first { $0.id == id }! }
}

// MARK: - Session controller

final class OfficeComputer: ObservableObject {
    static let shared = OfficeComputer()

    /// The desktop is laid out once on this logical canvas (the 3D screen's
    /// own 0.55 x 0.32 aspect) and scaled onto the monitor, so it looks and
    /// lays out the same on every phone and iPad -- only bigger or smaller,
    /// like a real screen seen from a chair.
    static let canvas = CGSize(width: 500, height: 500 * CGFloat(PlayerOffice.screenSize.y / PlayerOffice.screenSize.x))

    enum Phase: Equatable { case off, sittingDown, on, standingUp }
    @Published private(set) var phase: Phase = .off
    /// The 3D screen's rectangle on the device (window points) while seated;
    /// the computer surface is laid exactly over it. nil until projected.
    @Published private(set) var screenRect: CGRect?
    /// nil = the desktop.
    @Published private(set) var openApp: ComputerAppID?
    /// The game being played inside Games (nil = the Games launcher).
    @Published private(set) var openGame: ComputerGameID?
    /// The open game's "?" card is up (never shown automatically).
    @Published var showingHelp = false
    /// Bumped by "New game" / "Play again": the open game starts over.
    @Published private(set) var gameRound = 0
    /// Oct 7 -- SESSION RETENTION: each computer game's live state, kept in
    /// memory for the life of the app process. Closing a game (×, All games,
    /// another app, getting up, a floor rebuild) only hides it; reopening
    /// shows exactly where it was left. Only New game / Play again (or a
    /// relaunch, or the dev New Player reset) starts a game over. Not saved
    /// to disk -- this is retention, not persistence.
    let games = ComputerGameStore()

    var isActive: Bool { phase != .off }

    private weak var controller: TapNavigationController?
    private weak var view: SCNView?
    private var seatPosition: SCNVector3?               // camera-parent space
    private var sessionSpan: HistorySpan?
    private var appSpan: HistorySpan?
    private var gameSpan: HistorySpan?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendSpans() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeSpans() }
        })
    }

    // MARK: Sitting down

    /// The tap on the workstation: sit down if the player can (inside the
    /// office, free to move, Candy not mid-handoff). False = not handled
    /// (the tap falls through to an ordinary walk toward it).
    @discardableResult
    func sitDown(controller: TapNavigationController, view: SCNView) -> Bool {
        guard phase == .off else { return true }
        guard controller.currentFloorNumber == PlayerOffice.floor,
              PlayerOffice.officeCells.subtracting(PlayerOffice.deskBayCells).contains(controller.currentCell) else {
            diag("computer.sit.declined", ["reason": "not in the office", "cell": controller.currentCell])
            return false
        }
        guard controller.canRotate else {
            diag("computer.sit.declined", ["reason": "busy", "blockers": controller.diagCanRotateBlockers])
            return false
        }
        if GuidedJourney.isPerformingInOffice() {
            diag("computer.sit.declined", ["reason": "guide performing in the office",
                                           "stage": GuidedJourney.trip?.stage.rawValue ?? "none"])
            return false
        }
        guard let seat = seatedView(controller: controller, view: view) else {
            diag("computer.sit.declined", ["reason": "no workstation in scene"])
            return false
        }
        let camera = controller.cameraNode
        self.controller = controller
        self.view = view
        controller.isSeatedAtComputer = true
        phase = .sittingDown

        let startWorld = camera.presentation.worldPosition
        var worldPath: [SCNVector3] = [startWorld]
        if let waypoint = PlayerOffice.seatWaypoint(from: startWorld, to: seat.position) { worldPath.append(waypoint) }
        worldPath.append(seat.position)
        let path = worldPath.map { local($0, camera) }
        seatPosition = path.last

        var actions: [SCNAction] = []
        for i in 1..<path.count {
            let last = i == path.count - 1
            actions.append(glide(from: path[i - 1], to: path[i], yaw: last ? seat.yaw : Self.heading(from: path[i - 1], to: path[i]),
                                 pitch: last ? seat.pitch : 0, legs: path.count - 1, index: i))
        }
        actions.append(.wait(duration: 0.15))
        diag("computer.sit.begin", ["from": controller.currentCell, "legs": path.count - 1,
                                    "seat": String(format: "(%.2f, %.2f, %.2f)", seat.position.x, seat.position.y, seat.position.z),
                                    "view": NSCoder.string(for: view.bounds.size)])
        camera.runAction(.sequence(actions), forKey: "officeComputerSit") { [weak self] in
            DispatchQueue.main.async { self?.seated() }
        }
        return true
    }

    /// The seat for THIS view: the live camera's field of view and the
    /// view's current aspect decide how far back the chair sits.
    private func seatedView(controller: TapNavigationController, view: SCNView) -> (position: SCNVector3, yaw: Double, pitch: Double)? {
        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return nil }
        let aspect = Float(size.width / size.height)
        let fov = Float(controller.cameraNode.camera?.fieldOfView ?? 75) * .pi / 180
        let horizontal = controller.cameraNode.camera?.projectionDirection == .horizontal
        let tanH = horizontal ? tan(fov / 2) : tan(fov / 2) * aspect
        let tanV = horizontal ? tan(fov / 2) / aspect : tan(fov / 2)
        return PlayerOffice.seatedView(tanHalfH: tanH, tanHalfV: tanV)
    }

    private func local(_ world: SCNVector3, _ camera: SCNNode) -> SCNVector3 {
        camera.parent?.convertPosition(world, from: nil) ?? world
    }

    private func glide(from a: SCNVector3, to b: SCNVector3, yaw: Double, pitch: Double, legs: Int, index: Int,
                       minimum: Double = 0.45) -> SCNAction {
        let d = Double(sqrtf((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) + (b.z - a.z) * (b.z - a.z)))
        let t = max(minimum, d / 1.7)
        let step = SCNAction.group([.move(to: b, duration: t),
                                    .rotateTo(x: CGFloat(pitch), y: CGFloat(yaw), z: 0, duration: t, usesShortestUnitArc: true)])
        step.timingMode = legs == 1 ? .easeInEaseOut : (index == 1 ? .easeIn : (index == legs ? .easeOut : .linear))
        return step
    }

    private func seated() {
        guard phase == .sittingDown else { return }
        MailStore.shared.deliverInitialIfNeeded()
        BuildingDispatch.evaluate(reason: "computer")        // Oct 8 (Phase 1)
        sessionSpan = PlayerHistory.shared.begin(.computerSessionBegan, endKind: .computerSessionEnded,
                                                 subject: "computer.office", floor: PlayerOffice.floor)
        phase = .on
        projectScreenAfterNextFrame()
        diag("computer.on", [:])
    }

    // MARK: The screen's place on the device

    /// Projects the 3D screen plane's corners once the seated camera has
    /// rendered, and lays the computer surface over exactly that rectangle.
    private func projectScreenAfterNextFrame() {
        guard let controller else { return }
        controller.afterNextRenderedFrame { [weak self] in
            self?.projectScreen()
        }
        // Belt and braces (the one-shot frame hook is shared): project again
        // a moment later; projecting is idempotent.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.projectScreen()
        }
    }

    private func projectScreen() {
        guard phase == .on, let view,
              let screen = PlayerOffice.computer?.childNode(withName: "playerOfficeComputerScreen", recursively: true) else { return }
        let half = PlayerOffice.screenSize / 2
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
        for x in [-half.x, half.x] {
            for y in [-half.y, half.y] {
                let p = view.projectPoint(screen.presentation.convertPosition(SCNVector3(x, y, 0), to: nil))
                minX = min(minX, CGFloat(p.x)); maxX = max(maxX, CGFloat(p.x))
                minY = min(minY, CGFloat(p.y)); maxY = max(maxY, CGFloat(p.y))
            }
        }
        guard maxX > minX + 10, maxY > minY + 10 else { return }
        let rect = view.convert(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), to: nil)
        withAnimation(.easeOut(duration: screenRect == nil ? 0.35 : 0.2)) { screenRect = rect }
        diag("computer.screen.projected", ["rect": NSCoder.string(for: rect), "view": NSCoder.string(for: view.bounds.size)])
    }

    /// The device rotated / the view resized while seated: re-seat for the
    /// new aspect (the whole monitor still fits with room around it), then
    /// re-project.
    func viewLayoutChanged() {
        guard phase == .on, let controller, let view else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.phase == .on, let seat = self.seatedView(controller: controller, view: view) else { return }
            let camera = controller.cameraNode
            let position = self.local(seat.position, camera)
            self.seatPosition = position
            camera.position = position
            camera.eulerAngles = SCNVector3(Float(seat.pitch), Float(seat.yaw), 0)
            self.projectScreenAfterNextFrame()
        }
    }

    // MARK: Getting up (a tap on the room, outside the monitor)

    /// The player tapped the world around the monitor: they want to get up.
    /// The computer session ends, then the camera rises out of the chair,
    /// goes round the open (east) end of the desk and stops out in the room
    /// facing the door. Movement is handed back there; the next tap is
    /// ordinary navigation.
    func getUp() {
        guard phase == .on, let controller else { return }
        closeApp(reason: "gotUp")
        endSession(reason: "gotUp")
        withAnimation(.easeIn(duration: 0.18)) {
            phase = .standingUp
            screenRect = nil
        }
        let camera = controller.cameraNode
        let standY = controller.eyeHeight
        let spot = PlayerOffice.standUpSpot
        // World points of the route out, then camera-parent space.
        let seatWorld = camera.presentation.worldPosition
        let clearZ = min(seatWorld.z, PlayerOffice.deskCenter.y + 1.05)                   // not hugging the back wall
        let risen = SCNVector3(seatWorld.x + 0.25, standY, clearZ)                        // up and out of the chair
        let besideDesk = SCNVector3(PlayerOffice.deskCenter.x + 1.55, standY, clearZ)
        let out = SCNVector3(spot.position.x, standY, spot.position.y)
        let route = [risen, besideDesk, out].map { local($0, camera) }
        let rise = SCNAction.move(to: route[0], duration: 0.7)              // push back, stand up (still facing the desk)
        rise.timingMode = .easeInEaseOut
        let toSide = glide(from: route[0], to: route[1], yaw: Self.heading(from: route[0], to: route[1]), pitch: 0, legs: 2, index: 1,
                           minimum: 0.5)
        let toRoom = glide(from: route[1], to: route[2], yaw: spot.yaw, pitch: 0, legs: 2, index: 2, minimum: 0.9)
        diag("computer.getUp.begin", ["to": String(format: "(%.2f, %.2f)", spot.position.x, spot.position.y), "yaw": spot.yaw])
        camera.runAction(.sequence([.wait(duration: 0.15), rise, toSide, toRoom]), forKey: "officeComputerStand") { [weak self] in
            DispatchQueue.main.async { self?.finishStanding() }
        }
    }

    private func finishStanding() {
        guard phase == .standingUp else { return }
        let spot = PlayerOffice.standUpSpot
        if let controller {
            controller.cameraNode.removeAction(forKey: "officeComputerStand")
            let world = SCNVector3(spot.position.x, 0, spot.position.y)
            controller.finishStandingFromComputer(at: local(world, controller.cameraNode), yaw: spot.yaw)
        }
        resetState()
        diag("computer.off", [:])
    }

    /// The floor's scene is being rebuilt (or the controller replaced) while
    /// seated: close everything without any camera move.
    func forceClose(reason: String) {
        guard phase != .off else { return }
        closeApp(reason: reason)
        endSession(reason: reason)
        controller?.cameraNode.removeAction(forKey: "officeComputerSit")
        controller?.cameraNode.removeAction(forKey: "officeComputerStand")
        controller?.isSeatedAtComputer = false
        resetState()
        diag("computer.forceClosed", ["reason": reason])
    }

    private func resetState() {
        seatPosition = nil
        screenRect = nil
        controller = nil
        view = nil
        phase = .off
    }

    private static func heading(from a: SCNVector3, to b: SCNVector3) -> Double {
        atan2(-Double(b.x - a.x), -Double(b.z - a.z))
    }

    // MARK: Apps

    func open(_ app: ComputerAppID) {
        guard phase == .on, ComputerApps.info(app).isAvailable, openApp != app else { return }
        closeApp(reason: "switched")
        openApp = app
        switch app {
        case .mail: appSpan = PlayerHistory.shared.begin(.mailOpened, endKind: .mailClosed, subject: "app.mail", floor: PlayerOffice.floor)
        case .games: appSpan = PlayerHistory.shared.begin(.gamesOpened, endKind: .gamesClosed, subject: "app.games", floor: PlayerOffice.floor)
        case .work: break
        }
    }

    /// Back to the desktop.
    func closeApp(reason: String = "closed") {
        closeGame(reason: reason)
        if let span = appSpan { PlayerHistory.shared.end(span, detail: ["reason": reason]) }
        appSpan = nil
        openApp = nil
    }

    func recordMailRead(_ id: String) {
        PlayerHistory.shared.record(.mailMessageRead, subject: id, floor: PlayerOffice.floor)
    }

    func launch(_ game: ComputerGameID) {
        guard openApp == .games else { return }
        closeGame(reason: "switched")
        gameRound = 0
        showingHelp = false
        openGame = game
        gameSpan = PlayerHistory.shared.begin(.gameLaunched, endKind: .gameExited, subject: game.historyID, floor: PlayerOffice.floor)
    }

    /// Start the open game over (same play session -- History is not touched).
    func newGame() {
        guard let game = openGame else { return }
        games.discard(game)                              // the retained game is thrown away...
        gameRound += 1                                   // ...and the view rebuilt around a fresh one
    }

    /// DEV (New Player reset): a new hire starts with no games in progress.
    func discardAllGames() {
        games.discardAll()
        gameRound += 1
    }

    /// Back to the Games launcher.
    func closeGame(reason: String = "exited") {
        showingHelp = false
        if let span = gameSpan { PlayerHistory.shared.end(span, detail: ["reason": reason]) }
        gameSpan = nil
        openGame = nil
    }

    private func endSession(reason: String) {
        if let span = sessionSpan { PlayerHistory.shared.end(span, detail: ["reason": reason]) }
        sessionSpan = nil
    }

    // MARK: Backgrounding (the facts stay honest: time away is not time at the desk)

    private func suspendSpans() {
        guard phase == .on else { return }
        if let s = gameSpan { PlayerHistory.shared.end(s, detail: ["reason": "appBackgrounded"]) }
        if let s = appSpan { PlayerHistory.shared.end(s, detail: ["reason": "appBackgrounded"]) }
        if let s = sessionSpan { PlayerHistory.shared.end(s, detail: ["reason": "appBackgrounded"]) }
        gameSpan = nil; appSpan = nil; sessionSpan = nil
    }

    private func resumeSpans() {
        guard phase == .on, sessionSpan == nil else { return }
        let h = PlayerHistory.shared, f = PlayerOffice.floor
        sessionSpan = h.begin(.computerSessionBegan, endKind: .computerSessionEnded, subject: "computer.office", floor: f,
                              detail: ["reason": "appResumed"])
        switch openApp {
        case .mail?: appSpan = h.begin(.mailOpened, endKind: .mailClosed, subject: "app.mail", floor: f, detail: ["reason": "appResumed"])
        case .games?: appSpan = h.begin(.gamesOpened, endKind: .gamesClosed, subject: "app.games", floor: f, detail: ["reason": "appResumed"])
        default: break
        }
        if let game = openGame {
            gameSpan = h.begin(.gameLaunched, endKind: .gameExited, subject: game.historyID, floor: f, detail: ["reason": "appResumed"])
        }
    }
}

// MARK: - The monitor surface

/// The computer's screen, laid exactly over the physical monitor's 3D screen
/// while seated. Only that rectangle is interactive; everything around it is
/// the room (the SCNView underneath), where a tap means "get up".
struct OfficeComputerOverlayHost: View {
    @ObservedObject private var computer = OfficeComputer.shared

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if computer.phase == .on, let rect = computer.screenRect {
                    let canvas = OfficeComputer.canvas
                    let scale = rect.width / canvas.width
                    ComputerScreen(computer: computer)
                        .frame(width: canvas.width, height: canvas.height)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        .offset(x: rect.minX - origin.x, y: rect.minY - origin.y)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onChange(of: geo.size) { _, _ in computer.viewLayoutChanged() }
        }
        .ignoresSafeArea()
    }
}

private struct ComputerScreen: View {
    @ObservedObject var computer: OfficeComputer
    @ObservedObject private var mail = MailStore.shared

    var body: some View {
        ZStack {
            LinearGradient(colors: [HallwaysOS.wallpaperTop, HallwaysOS.wallpaperMid, HallwaysOS.wallpaperBottom],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                taskbar
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let app = computer.openApp {
            AppWindow(computer: computer, app: ComputerApps.info(app)) {
                switch app {
                case .mail: MailAppView(computer: computer)
                case .games: GamesAppView(computer: computer)
                case .work: EmptyView()
                }
            }
            .padding(5)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        } else {
            desktop
        }
    }

    private var desktop: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ComputerApps.all) { app in
                Button { withAnimation(.easeOut(duration: 0.18)) { computer.open(app.id) } } label: {
                    DesktopIcon(app: app, badge: app.id == .mail ? mail.unreadCount : 0)
                }
                .buttonStyle(.plain)
                .disabled(!app.isAvailable)
                .accessibilityIdentifier("computerIcon_\(app.id.rawValue)")
            }
            Spacer()
        }
        .padding(.top, 16)
        .padding(.leading, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The taskbar: the building's mark (back to the desktop), the apps, the
    /// clock and the employee number. Computer controls only -- nothing here
    /// moves the player.
    private var taskbar: some View {
        // Oct 7 (polish): the app switching itself was always wired
        // (computer.open); the buttons were just tiny -- 30 x 24 canvas units,
        // about 20 x 16 points on a portrait iPhone, 8 units apart -- so taps
        // missed or landed on the neighbour (usually Mail). The tiles are a
        // touch bigger now and each sits in a full-height hit cell (46 x 34;
        // Home 44 x 34) that abuts the next one. Bar height unchanged.
        HStack(spacing: 0) {
            Button {
                diag("computer.taskbar", ["tap": "home"])
                withAnimation(.easeOut(duration: 0.18)) { computer.closeApp() }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(HallwaysOS.brand)
                    Text("H").font(.system(size: 16, weight: .heavy, design: .serif)).foregroundStyle(HallwaysOS.ink)
                }
                .frame(width: 28, height: 26)
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Desktop")
            ForEach(ComputerApps.all.filter(\.isAvailable)) { app in
                Button {
                    diag("computer.taskbar", ["tap": app.id.rawValue, "from": computer.openApp?.rawValue ?? "desktop"])
                    withAnimation(.easeOut(duration: 0.18)) { computer.open(app.id) }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: app.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 34, height: 26)
                            .background(app.tint.opacity(computer.openApp == app.id ? 1 : 0.55),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        if app.id == .mail, mail.unreadCount > 0 {
                            Circle().fill(Color.red).frame(width: 9, height: 9).offset(x: 3, y: -3)
                        }
                    }
                    .frame(width: 46, height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("computerTaskbar_\(app.id.rawValue)")
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    Text(ctx.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
                Text(EmployeeID.number ?? "").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.trailing, 8)
        }
        .frame(height: 34)
        .padding(.leading, 2)
        .background(HallwaysOS.taskbar)
    }
}

private struct DesktopIcon: View {
    let app: ComputerAppInfo
    let badge: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [app.tint.opacity(app.isAvailable ? 1 : 0.5), app.tint.opacity(app.isAvailable ? 0.75 : 0.35)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 58, height: 58)
                    .overlay(Image(systemName: app.symbol).font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white.opacity(app.isAvailable ? 1 : 0.6)))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                        .background(Color.red, in: Capsule())
                        .offset(x: 7, y: -7)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.title).font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(app.isAvailable ? 1 : 0.55))
                if let caption = app.caption {
                    Text(caption).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// One app, filling the screen above the taskbar: a title bar with its icon,
/// its name and a close button (back to the desktop). No dragging, no resizing.
private struct AppWindow<Content: View>: View {
    @ObservedObject var computer: OfficeComputer
    let app: ComputerAppInfo
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.horizontal, 2)
                .frame(height: Self.barHeight)
                .background(Color(red: 0.91, green: 0.92, blue: 0.93))
            Rectangle().fill(HallwaysOS.rule).frame(height: 1)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(HallwaysOS.paper)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    /// Oct 7 (Games portal foundation): ONE bar. Normally the app's icon,
    /// name and close; with a game open it becomes the game's bar -- "All
    /// games", the game's name, "New game" and close -- so a game has no
    /// second header eating its height.
    /// Oct 7 (polish): bigger type and glyphs, and every control's hit area
    /// is the full bar height (34) with generous width -- while the bar stays
    /// a single slim strip.
    @ViewBuilder
    private var titleBar: some View {
        if app.id == .games, let game = computer.openGame {
            HStack(spacing: 4) {
                Button { withAnimation(.easeOut(duration: 0.18)) { computer.closeGame() } } label: {
                    HStack(spacing: 3) { Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold)); Text("All games") }
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(game.tint)
                        .padding(.horizontal, 8)
                        .frame(minHeight: Self.barHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("computerAllGames")
                Spacer(minLength: 4)
                Text(game.title).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(HallwaysOS.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !game.help.isEmpty {
                    // Oct 7: how-to-play, for anyone who has never seen the game.
                    Button { withAnimation(.easeOut(duration: 0.15)) { computer.showingHelp.toggle() } } label: {
                        Image(systemName: computer.showingHelp ? "questionmark.circle.fill" : "questionmark.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(game.tint)
                            .frame(width: 36, height: Self.barHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("How to play")
                    .accessibilityIdentifier("computerGameHelp")
                }
                if game.showsTitleBarNewGame {
                    Button { computer.newGame() } label: {
                        Text("New game").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(game.tint, in: Capsule())
                            .padding(.horizontal, 4)
                            .frame(minHeight: Self.barHeight).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("computerNewGame")
                }
                closeButton
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: app.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(app.tint)
                    .padding(.leading, 8)
                Text(app.title).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(HallwaysOS.ink)
                Spacer()
                closeButton
            }
        }
    }

    private static var barHeight: CGFloat { 34 }          // computed: no stored statics in a generic type

    private var closeButton: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { computer.closeApp() } } label: {
            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(HallwaysOS.inkSoft)
                .frame(width: 30, height: 26)
                .background(HallwaysOS.rule.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(width: 42, height: Self.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("computerCloseApp")
    }
}

/// Oct 7 -- the computer's in-memory game sessions: one live model object per
/// game (a view model or a small session class), created on first open and
/// handed to the game's view on every open after that. Generic: any game
/// whose state lives in a class plugs in with `model(for:make:)`.
final class ComputerGameStore {
    private var models: [ComputerGameID: AnyObject] = [:]

    /// The retained model for `game`, made by `make` the first time.
    func model<Model: AnyObject>(for game: ComputerGameID, make: () -> Model) -> Model {
        if let existing = models[game] as? Model { return existing }
        let fresh = make()
        models[game] = fresh
        diag("computer.game.created", ["game": game.rawValue])
        return fresh
    }

    func discard(_ game: ComputerGameID) {
        models[game] = nil
        diag("computer.game.discarded", ["game": game.rawValue])
    }

    func discardAll() { models.removeAll() }
}
