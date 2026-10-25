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
    /// (Oct 12: kept in `placement`, which only the overlay host observes -- it
    /// changes every frame while turning, and nothing else needs redrawing then.)
    var screenRect: CGRect? {
        get { placement.rect }
        set { placement.rect = newValue }
    }
    let placement = MonitorPlacement()
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
    /// Oct 12 (seated look): the straight-on view of the monitor (camera
    /// yaw/pitch once seated), and the head's turn away from it.
    private var seatYaw: Double?
    private var seatPitch: Double = 0
    private var lookBaseYaw: Double = 0
    private var lookPanning = false
    /// The head's turn from the straight-on view, as last set by the player
    /// (+ = left). Kept as state, not read off the camera: the zoomed lens
    /// (CameraMagnifier) also aims the camera, and that is not "turned away".
    private var lookYaw: Double = 0 {
        didSet {
            let f = abs(lookYaw) < 0.04
            if f != facing { facing = f }
        }
    }
    private var sitQueue = 0
    /// Oct 12 (monitor polish): the monitor's four corners on the device
    /// (window points; top-left, top-right, bottom-right, bottom-left of the
    /// desktop as it reads), followed every frame while seated -- the desktop
    /// is drawn onto exactly that quad, at any angle. nil = not on screen.
    var screenQuad: [CGPoint]? { placement.quad }
    /// Looking straight at the monitor (published: the desktop takes touches only then).
    @Published private(set) var facing = true
    /// Desktop / taskbar buttons (canvas coordinates) -- a tap on one while
    /// looking away turns back to the monitor and then presses it.
    private var tapTargets: [String: (frame: CGRect, action: () -> Void)] = [:]
    private var follower: CADisplayLink?
    private let followTicker = OfficeComputerTicker()
    private var lastCameraTransform = SCNMatrix4Identity
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
        // Oct 12 (playtest: "the first SIT takes forever"): this used to REFUSE
        // the seat for as long as Mr. Tinky's escort was in its guiding/goodbye
        // stage -- his whole goodbye (desk, lamp, bow, ~15 s and up to 60 s),
        // with nothing to show the tap had been refused; it only worked once
        // he set off (stage .departing), and every later sit worked at once.
        // Sitting no longer waits for him: his goodbye simply goes on around
        // the seated player. (The call still wraps up a stalled journey.)
        if GuidedJourney.isPerformingInOffice() {
            diag("computer.sit.duringGuideGoodbye", ["stage": GuidedJourney.trip?.stage.rawValue ?? "none"])
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
        seatYaw = seat.yaw
        seatPitch = seat.pitch
        lookYaw = 0

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

    /// Oct 11 (USE fix): would `sitDown` accept right now? The same checks
    /// it makes, without starting anything -- so the HUD never offers a USE
    /// that is then silently refused (Mr. Tinky performing at the desk, or no
    /// workstation in this scene). Movement/busy is the caller's own check.
    func canSitDown(controller: TapNavigationController, view: SCNView) -> Bool {
        guard phase == .off else { return false }
        _ = GuidedJourney.isPerformingInOffice()                    // (wraps up a stalled journey; no longer a refusal -- Oct 12)
        return seatedView(controller: controller, view: view) != nil
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
        // Oct 12 (event history): the player's first time at their computer is an
        // event (once); a short while later it brings the meeting invitation.
        if StoryBeats.shared.record(BuildingDispatch.computerFirstUseBeat, at: Date()) {
            diag("story.computerFirstUse", [:])
        }
        BuildingDispatch.evaluate(reason: "computer")        // Oct 8 (Phase 1); Oct 12: also arms the invitation's pause
        sessionSpan = PlayerHistory.shared.begin(.computerSessionBegan, endKind: .computerSessionEnded,
                                                 subject: "computer.office", floor: PlayerOffice.floor)
        phase = .on
        projectScreenAfterNextFrame()
        startFollowing()
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

    private func projectScreen(animated: Bool = true) {
        guard phase == .on, let view,
              let screen = PlayerOffice.computer?.childNode(withName: "playerOfficeComputerScreen", recursively: true) else { return }
        let half = PlayerOffice.screenSize / 2
        // Oct 12: the four corners, in the desktop's reading order, so it can
        // be drawn onto the monitor at any angle (not just a straight-on rectangle).
        var corners: [CGPoint] = []
        var inView = true
        for (x, y) in [(-half.x, half.y), (half.x, half.y), (half.x, -half.y), (-half.x, -half.y)] {
            let p = view.projectPoint(screen.presentation.convertPosition(SCNVector3(x, y, 0), to: nil))
            if !(p.z > 0 && p.z < 1) { inView = false }
            corners.append(view.convert(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), to: nil))
        }
        // Whatever way the plane's axes run, the desktop reads left-to-right, top-down.
        if corners[1].x < corners[0].x { corners = [corners[1], corners[0], corners[3], corners[2]] }
        if corners[3].y < corners[0].y { corners = [corners[3], corners[2], corners[1], corners[0]] }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        guard inView, rect.width > 10, rect.height > 10, Self.homography(from: Self.canvas, to: corners) != nil else {
            if placement.visible { placement.visible = false }       // (looking right away from it: kept, hidden)
            return
        }
        // Only the first appearance animates (the projection itself can't be animated).
        guard animated, placement.rect == nil else { placement.set(rect: rect, quad: corners); return }
        withAnimation(.easeOut(duration: 0.35)) { placement.set(rect: rect, quad: corners) }
        diag("computer.screen.projected", ["rect": NSCoder.string(for: rect), "view": NSCoder.string(for: view.bounds.size)])
    }

    // MARK: Oct 11 -- pinch to look closer (CameraMagnifier)
    //
    // A pinch on the monitor (the SwiftUI screen) or on the room around it
    // zooms the whole 3D view; the screen surface follows the monitor's
    // projected rectangle, so it scales with everything else and every
    // control keeps working at any zoom.

    /// `windowPoint`: the pinch centre in window coordinates.
    func pinchBegan(windowPoint: CGPoint, source: String, takeover: Bool = false) {
        guard phase == .on, CameraMagnifier.applies, isFacingComputer, let controller, let view else { return }
        CameraMagnifier.shared.onViewChanged = { [weak self] in self?.projectScreen(animated: false) }
        CameraMagnifier.shared.begin(source: source, at: view.convert(windowPoint, from: nil), camera: controller.cameraNode,
                                     view: view, takeover: takeover)
    }

    /// Oct 11: the pinch's fingers moved -- zoom and pan together.
    func pinchMoved(windowPoint: CGPoint, scale: Double, source: String) {
        guard let view else { return }
        CameraMagnifier.shared.update(source: source, scale: scale, at: view.convert(windowPoint, from: nil))
    }

    /// Oct 11: one finger dragging the room around the monitor (only while zoomed).
    func roomPanBegan() {
        guard phase == .on, CameraMagnifier.applies else { return }
        CameraMagnifier.shared.panBegan(source: "roomPan")
    }

    func roomPanChanged(translation: CGPoint) {
        CameraMagnifier.shared.panChanged(source: "roomPan", translation: translation)
    }

    func roomPanEnded() {
        CameraMagnifier.shared.panEnded(source: "roomPan")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.projectScreen(animated: false) }
    }

    func pinchChanged(scale: Double, source: String) {
        CameraMagnifier.shared.update(source: source, scale: scale)
    }

    func pinchEnded(scale: Double, source: String) {
        CameraMagnifier.shared.end(source: source, scale: scale)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.projectScreen(animated: false) }
    }

    /// The device rotated / the view resized while seated: re-seat for the
    /// new aspect (the whole monitor still fits with room around it), then
    /// re-project.
    func viewLayoutChanged() {
        guard phase == .on, let controller, let view else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            CameraMagnifier.shared.reset(animated: false)          // Oct 11: re-seat from the 1x view
            guard let self, self.phase == .on, let seat = self.seatedView(controller: controller, view: view) else { return }
            let camera = controller.cameraNode
            let position = self.local(seat.position, camera)
            self.seatPosition = position
            self.seatYaw = seat.yaw
            self.seatPitch = seat.pitch
            self.lookYaw = 0
            camera.removeAction(forKey: "officeComputerLook")
            camera.position = position
            camera.eulerAngles = SCNVector3(Float(seat.pitch), Float(seat.yaw), 0)
            self.projectScreenAfterNextFrame()
        }
    }

    // MARK: Oct 12 -- looking around from the chair
    //
    // Seated, the head turns (a horizontal drag, or LEFT/RIGHT) up to
    // `lookLimit` either way from the straight-on view; the camera stays
    // exactly where the chair puts it. Turned away, the monitor's surface is
    // put away (it only belongs over the screen when facing it); a tap on the
    // room then turns back to the monitor (faceComputer) instead of getting
    // up. Facing it, everything is as before (a tap on the room gets up).

    static let lookLimit: Double = 1.25                    // ~72 degrees either way
    static let buttonTurn: Double = .pi / 4

    /// Seated and looking at the monitor (not turned away; zoomed counts as facing).
    var isFacingComputer: Bool { phase == .on && abs(lookYaw) < 0.04 }

    /// Pitch for a given turn: straight on, the seat's slight look down at
    /// the screen; turned away, level.
    private func pitch(forOffset d: Double) -> Double { seatPitch * max(0, 1 - abs(d) / 0.6) }


    /// A one-finger drag on the room (not zoomed in): the head turns.
    func lookBegan() {
        guard phase == .on, seatYaw != nil, let camera = controller?.cameraNode else { lookPanning = false; return }
        lookPanning = true
        camera.removeAction(forKey: "officeComputerLook")
        lookBaseYaw = lookYaw
    }

    func lookChanged(translation: CGPoint) {
        guard lookPanning, phase == .on, let seatYaw, let camera = controller?.cameraNode else { return }
        // The same scale and sense as the ordinary drag-to-turn (140 pt = a quarter turn).
        let d = max(-Self.lookLimit, min(Self.lookLimit, lookBaseYaw + Double(translation.x / 140) * .pi / 2))
        lookYaw = d
        camera.eulerAngles = SCNVector3(Float(pitch(forOffset: d)), Float(seatYaw + d), 0)
    }

    func lookEnded() {
        guard lookPanning else { return }
        lookPanning = false
        // Let go nearly straight on: settle onto the monitor.
        if phase == .on, abs(lookYaw) < 0.12 { faceComputer(duration: 0.2) }
    }

    /// LEFT / RIGHT while seated: an eighth of a turn each, within the limits.
    func turn(left: Bool) {
        guard phase == .on, let seatYaw, let camera = controller?.cameraNode, !CameraMagnifier.shared.isZoomed else { return }
        var d = lookYaw + (left ? Self.buttonTurn : -Self.buttonTurn)       // from where it is going (quick presses add up)
        d = max(-Self.lookLimit, min(Self.lookLimit, d))
        if abs(d) < 0.12 { faceComputer(); return }
        lookYaw = d
        let turn = SCNAction.rotateTo(x: CGFloat(pitch(forOffset: d)), y: CGFloat(seatYaw + d), z: 0, duration: 0.35,
                                      usesShortestUnitArc: true)
        turn.timingMode = .easeInEaseOut
        camera.runAction(turn, forKey: "officeComputerLook")
        diag("computer.look.turn", ["left": left, "offset": String(format: "%.2f", d)])
    }

    /// Back to the straight-on monitor view (no move, the chair stays put);
    /// the screen surface returns once it's there.
    func faceComputer(duration: Double = 0.45, then action: (() -> Void)? = nil) {
        guard phase == .on, let seatYaw, let camera = controller?.cameraNode else { return }
        lookYaw = 0
        let turn = SCNAction.rotateTo(x: CGFloat(seatPitch), y: CGFloat(seatYaw), z: 0, duration: duration, usesShortestUnitArc: true)
        turn.timingMode = .easeInEaseOut
        camera.runAction(turn, forKey: "officeComputerLook") { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.phase == .on else { return }
                self.projectScreenAfterNextFrame()
                if let action, self.facing { action() }
            }
        }
        diag("computer.look.faceComputer", ["then": action != nil])
    }

    // MARK: Oct 12 -- the desktop drawn onto the monitor at any angle

    /// Every frame while seated: if the camera moved (a turn, the lens), the
    /// quad follows the monitor.
    private func startFollowing() {
        guard follower == nil else { return }
        followTicker.onTick = { [weak self] in self?.followTick() }
        let link = CADisplayLink(target: followTicker, selector: #selector(OfficeComputerTicker.tick))
        link.add(to: .main, forMode: .common)
        follower = link
    }

    private func stopFollowing() {
        follower?.invalidate()
        follower = nil
        followTicker.onTick = nil
    }

    private func followTick() {
        guard phase == .on, let camera = controller?.cameraNode else { return }
        let t = camera.presentation.worldTransform
        let fov = camera.presentation.camera?.fieldOfView ?? 0
        if SCNMatrix4EqualToMatrix4(t, lastCameraTransform) && fov == lastFOV { return }
        lastCameraTransform = t
        lastFOV = fov
        projectScreen(animated: false)
    }
    private var lastFOV: CGFloat = 0

    /// The projective map from the desktop canvas onto `quad` (TL, TR, BR, BL),
    /// as a 3x3 (row-major a b c / d e f / g h 1), or nil if degenerate.
    static func homography(from canvas: CGSize, to quad: [CGPoint]) -> [Double]? {
        guard quad.count == 4, canvas.width > 0, canvas.height > 0 else { return nil }
        let x0 = Double(quad[0].x), y0 = Double(quad[0].y), x1 = Double(quad[1].x), y1 = Double(quad[1].y)
        let x2 = Double(quad[2].x), y2 = Double(quad[2].y), x3 = Double(quad[3].x), y3 = Double(quad[3].y)
        // Unit square (0,0) (1,0) (1,1) (0,1) -> TL TR BR BL (Heckbert).
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        var g = 0.0, h = 0.0
        if abs(dx3) > 1e-9 || abs(dy3) > 1e-9 {
            let den = dx1 * dy2 - dx2 * dy1
            guard abs(den) > 1e-9 else { return nil }
            g = (dx3 * dy2 - dx2 * dy3) / den
            h = (dx1 * dy3 - dx3 * dy1) / den
        }
        let a = x1 - x0 + g * x1, b = x3 - x0 + h * x3, c = x0
        let d = y1 - y0 + g * y1, e = y3 - y0 + h * y3, f = y0
        let w = Double(canvas.width), ht = Double(canvas.height)
        let m = [a / w, b / ht, c, d / w, e / ht, f, g / w, h / ht, 1.0]
        guard m.allSatisfy(\.isFinite) else { return nil }
        return m
    }

    /// The same map as a transform for SwiftUI's projectionEffect (row-vector convention).
    static func projection(from canvas: CGSize, to quad: [CGPoint]) -> CATransform3D {
        guard let m = homography(from: canvas, to: quad) else { return CATransform3DIdentity }
        var t = CATransform3DIdentity
        t.m11 = CGFloat(m[0]); t.m12 = CGFloat(m[3]); t.m13 = 0; t.m14 = CGFloat(m[6])
        t.m21 = CGFloat(m[1]); t.m22 = CGFloat(m[4]); t.m23 = 0; t.m24 = CGFloat(m[7])
        t.m31 = 0; t.m32 = 0; t.m33 = 1; t.m34 = 0
        t.m41 = CGFloat(m[2]); t.m42 = CGFloat(m[5]); t.m43 = 0; t.m44 = 1
        return t
    }

    /// Where a window point falls on the desktop canvas (nil: not on the monitor).
    func canvasPoint(forWindow p: CGPoint) -> CGPoint? {
        guard let quad = screenQuad, let m = Self.homography(from: Self.canvas, to: quad) else { return nil }
        // Inverse of the 3x3.
        let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        guard abs(det) > 1e-12 else { return nil }
        let inv = [A / det, -(b * i - c * h) / det, (b * f - c * e) / det,
                   B / det, (a * i - c * g) / det, -(a * f - c * d) / det,
                   C / det, -(a * h - b * g) / det, (a * e - b * d) / det]
        let x = Double(p.x), y = Double(p.y)
        let w = inv[6] * x + inv[7] * y + inv[8]
        guard abs(w) > 1e-9 else { return nil }
        let u = (inv[0] * x + inv[1] * y + inv[2]) / w, v = (inv[3] * x + inv[4] * y + inv[5]) / w
        guard u >= 0, v >= 0, u <= Double(Self.canvas.width), v <= Double(Self.canvas.height) else { return nil }
        return CGPoint(x: u, y: v)
    }

    /// The desktop's own buttons register where they are (canvas coordinates).
    func setTapTarget(_ key: String, frame: CGRect?, action: @escaping () -> Void) {
        if let frame { tapTargets[key] = (frame, action) } else { tapTargets[key] = nil }
    }

    /// A tap while looking away: back to the monitor -- and if it landed on
    /// one of the desktop's buttons, that button is pressed once facing it.
    func tapWhileTurned(windowPoint: CGPoint) {
        var press: (() -> Void)?
        if let p = canvasPoint(forWindow: windowPoint) {
            press = tapTargets.values.first(where: { $0.frame.contains(p) })?.action
        }
        diag("computer.look.tapWhileTurned", ["onMonitor": canvasPoint(forWindow: windowPoint) != nil, "press": press != nil])
        faceComputer(then: press)
    }

    // MARK: Oct 12 -- one deliberate tap seats the player

    /// A tap/USE on the workstation that arrived while the player was still
    /// moving (the end of a walk into the office, a pivot settling): the
    /// walk is stopped and the sit happens as soon as the player is still
    /// (within ~1.5 s) -- instead of the tap being spent as a brake and a
    /// second tap needed. True = taken care of.
    @discardableResult
    func sitDownWhenSettled(controller: TapNavigationController, view: SCNView) -> Bool {
        guard phase == .off else { return true }
        // Only worth waiting for in the office itself, on the way to stillness;
        // anything else is answered at once, exactly as before.
        let inOffice = controller.currentFloorNumber == PlayerOffice.floor
            && PlayerOffice.officeCells.subtracting(PlayerOffice.deskBayCells).contains(controller.currentCell)
        let moving = controller.isFreeTapWalking || controller.continuousWalkState != .stopped
            || controller.diagCanRotateBlockers.split(separator: ",").allSatisfy { ["animating", "dragRotating", "dragMoving"].contains(String($0)) }
        guard inOffice, !controller.canRotate || controller.isFreeTapWalking || controller.continuousWalkState != .stopped,
              moving else { return sitDown(controller: controller, view: view) }
        if controller.isFreeTapWalking { controller.stopFreeTapWalk() }
        controller.stopContinuousWalk(reason: "officeComputer")
        if controller.canRotate { return sitDown(controller: controller, view: view) }
        diag("computer.sit.queued", ["blockers": controller.diagCanRotateBlockers])
        let deadline = CACurrentMediaTime() + 1.5
        sitQueue += 1
        let token = sitQueue
        func attempt() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak controller, weak view] in
                guard let self, let controller, let view, self.phase == .off, token == self.sitQueue else { return }
                // A new walk since the tap: the player has changed their mind.
                if controller.isFreeTapWalking || controller.continuousWalkState != .stopped {
                    diag("computer.sit.queuedCancelled", [:]); return
                }
                if controller.canRotate {
                    if !self.sitDown(controller: controller, view: view) { diag("computer.sit.queuedDeclined", [:]) }
                } else if CACurrentMediaTime() < deadline {
                    attempt()
                } else {
                    diag("computer.sit.queuedTimedOut", ["blockers": controller.diagCanRotateBlockers])
                }
            }
        }
        attempt()
        return true
    }

    // MARK: Getting up (a tap on the room, outside the monitor)

    /// The player tapped the world around the monitor: they want to get up.
    /// The computer session ends, then the camera rises out of the chair,
    /// goes round the open (east) end of the desk and stops out in the room
    /// facing the door. Movement is handed back there; the next tap is
    /// ordinary navigation.
    func getUp() {
        guard phase == .on, let controller else { return }
        controller.cameraNode.removeAction(forKey: "officeComputerLook")    // Oct 12
        lookPanning = false
        CameraMagnifier.shared.reset(animated: true)               // Oct 11: back to the normal lens
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
        controller?.cameraNode.removeAction(forKey: "officeComputerLook")   // Oct 12
        controller?.cameraNode.removeAction(forKey: "officeComputerStand")
        controller?.isSeatedAtComputer = false
        CameraMagnifier.shared.reset(animated: false)              // Oct 11
        resetState()
        diag("computer.forceClosed", ["reason": reason])
    }

    private func resetState() {
        stopFollowing()
        tapTargets = [:]
        placement.set(rect: nil, quad: nil)
        seatPosition = nil
        seatYaw = nil
        lookYaw = 0
        lookPanning = false
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
/// Oct 12: where the monitor is on the device right now (observed by the overlay only).
final class MonitorPlacement: ObservableObject {
    @Published var rect: CGRect?
    @Published private(set) var quad: [CGPoint]?
    @Published var visible = true
    func set(rect: CGRect?, quad: [CGPoint]?) {
        self.rect = rect
        self.quad = quad
        if quad != nil, !visible { visible = true }
    }
}

/// CADisplayLink's target (it needs an NSObject).
final class OfficeComputerTicker: NSObject {
    var onTick: (() -> Void)?
    @objc func tick() { onTick?() }
}

struct OfficeComputerOverlayHost: View {
    @ObservedObject private var computer = OfficeComputer.shared
    @ObservedObject private var placement = OfficeComputer.shared.placement
    /// Oct 11: a pinch on the monitor is driving the camera magnifier.
    @State private var pinching = false
    /// Oct 12: a sideways drag begun on the monitor is turning the head.
    @State private var surfaceLook = false
    @State private var lookDecided = false
    @State private var lookFrom: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if computer.phase == .on, let quad = placement.quad, let rect = placement.rect, rect.width > 1 {
                    let canvas = OfficeComputer.canvas
                    let scale = rect.width / canvas.width
                    // Oct 12: drawn onto the monitor's own quad at any angle. Laid out exactly as
                    // before (scaled onto the monitor's bounding rectangle); the quad is a projection
                    // inside that -- the identity when facing it, so touches there are as they were.
                    let inCanvas = quad.map { CGPoint(x: ($0.x - rect.minX) / scale, y: ($0.y - rect.minY) / scale) }
                    ComputerScreen(computer: computer)
                        .frame(width: canvas.width, height: canvas.height)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .projectionEffect(ProjectionTransform(OfficeComputer.projection(from: canvas, to: inCanvas)))
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                        // Oct 11: pinch ON the monitor = look closer (the whole
                        // 3D view zooms; taps inside keep working, simultaneously).
                        .simultaneousGesture(
                            MagnifyGesture(minimumScaleDelta: 0.02)
                                .onChanged { value in
                                    if !pinching || !CameraMagnifier.shared.isDriving {
                                        pinching = true
                                        computer.pinchBegan(windowPoint: CGPoint(x: rect.minX + value.startAnchor.x * rect.width,
                                                                                 y: rect.minY + value.startAnchor.y * rect.height),
                                                            source: "monitor")
                                    }
                                    computer.pinchChanged(scale: Double(value.magnification), source: "monitor")
                                }
                                .onEnded { value in
                                    pinching = false
                                    computer.pinchEnded(scale: Double(value.magnification), source: "monitor")
                                }
                        )
                        // Oct 12: a sideways drag that starts ON the monitor turns the head too
                        // (the desktop has no sideways drags of its own; games keep theirs).
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 14, coordinateSpace: .global)
                                .onChanged { value in
                                    if !lookDecided {
                                        // Decided once, at the start: sideways = a look; anything else is the desktop's.
                                        lookDecided = true
                                        guard computer.openGame == nil, !pinching, !CameraMagnifier.shared.isZoomed,
                                              abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                                        surfaceLook = true
                                        lookFrom = value.translation.width
                                        computer.lookBegan()
                                    }
                                    guard surfaceLook else { return }
                                    computer.lookChanged(translation: CGPoint(x: value.translation.width - lookFrom, y: 0))
                                }
                                .onEnded { _ in
                                    if surfaceLook { computer.lookEnded() }
                                    surfaceLook = false
                                    lookDecided = false
                                }
                        )
                        .offset(x: rect.minX - origin.x, y: rect.minY - origin.y)
                        // Looking away, the desktop is seen, not touched: a tap there turns back to
                        // it (and presses what was tapped) -- handled with the room's taps.
                        .opacity(placement.visible ? 1 : 0)
                        .allowsHitTesting(surfaceLook || (computer.facing && placement.visible))
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onChange(of: geo.size) { _, _ in computer.viewLayoutChanged() }
            .onChange(of: computer.phase) { _, _ in                      // Oct 11
                pinching = false
                if surfaceLook { computer.lookEnded() }                 // Oct 12: never left mid-look
                surfaceLook = false
                lookDecided = false
            }
        }
        .ignoresSafeArea()
    }
}

/// Oct 12: registers a desktop button's place (canvas coordinates) with the
/// computer, so a tap on it while looking away can press it after turning back.
private struct TapTarget: ViewModifier {
    let computer: OfficeComputer
    let key: String
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ComputerScreen.space)) } action: { frame in
                computer.setTapTarget(key, frame: enabled ? frame : nil, action: action)
            }
            .onDisappear { computer.setTapTarget(key, frame: nil, action: {}) }
    }
}

private struct ComputerScreen: View {
    static let space = "officeComputerCanvas"
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
        .coordinateSpace(name: Self.space)
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
                .modifier(TapTarget(computer: computer, key: "icon.\(app.id.rawValue)", enabled: app.isAvailable) {
                    withAnimation(.easeOut(duration: 0.18)) { computer.open(app.id) }
                })
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
            .modifier(TapTarget(computer: computer, key: "taskbar.home", enabled: true) {
                withAnimation(.easeOut(duration: 0.18)) { computer.closeApp() }
            })
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
                .modifier(TapTarget(computer: computer, key: "taskbar.\(app.id.rawValue)", enabled: true) {
                    withAnimation(.easeOut(duration: 0.18)) { computer.open(app.id) }
                })
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
