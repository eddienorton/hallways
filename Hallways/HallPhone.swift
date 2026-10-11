import SwiftUI
import UIKit
import AVFoundation
import Combine

// Oct 8 -- THE PLAYER'S PHONE (Stage 1: the physical phone only).
//
// WE ARE NOT OPENING A PHONE UI. WE ARE SIMULATING HOLDING AND USING A
// PHYSICAL PHONE WHILE CONTINUING TO EXIST IN THE HALLWAYS WORLD.
//
// `lift` is how high / close the player is holding their phone right now:
//   0 = held low in the right hand (bottom-right, where the old mini-map was)
//   1 = held up near the face, big and readable
// The finger moves it (1:1, no animation while dragging) and, on release,
// the phone simply STAYS where the hand left it -- there is no "up" or
// "down" to snap to. Only a phone pulled past either end springs back to it.
// Position, size, lean and screen brightness all derive from `lift`.
//
// What the phone SHOWS (`screen`, notifications) is separate from where it
// is held: moving the phone never resets it.
//
// The phone and the world are both live at once:
//   - a touch ON the phone is the phone's: a TAP operates whatever is under
//     the finger (once the phone is held high enough to read; below that a
//     tap nudges it); a DRAG that starts anywhere on the phone -- screen,
//     notification, bezel -- moves the phone, at every lift;
//   - a touch anywhere else is an ordinary Hallways touch -- the phone's
//     touch area is only where the phone is, so nothing else is covered.
// Nothing the phone does stops the player or the world.
//
// The apps (Building GPS, HallChat, Mail, Directory) are in PhoneApps.swift.
// Notifications are presented here; messages are delivered by
// BuildingDispatch. DEBUG: press and hold the phone still for 0.6 s to have
// Dispatch send the staff-meeting test mail.
// Deliberately NOT here: calls, a clock, scheduling, an assistant.

/// A notification on the phone's screen: presentation only. The message it
/// announces already lives in its own store (Mail, later HallChat).
nonisolated struct PhoneNotification: Identifiable, Equatable, Sendable {
    /// Where tapping the notification takes the player.
    enum Opens: Equatable, Sendable {
        case mail(String)
        /// Oct 8 (Phase 1 C): a HallChat thread (by thread ID).
        case chat(String)
    }
    let id: UUID
    let source: String
    let title: String
    var opens: Opens? = nil
}

/// What the phone's screen is showing. Owned here and never reset by moving
/// the phone (each app's own place is kept in PhoneApps).
enum PhoneScreen: Equatable {
    case home, buildingGPS, hallChat, mail, directory
}

final class HallPhone: ObservableObject {
    static let shared = HallPhone()

    enum Hold: Equatable {
        case resting        // wherever the hand left it
        case held           // a finger is moving it
        case settling       // springing back inside 0...1 after being pulled past an end
    }

    /// How high the phone is held: 0 low ... 1 at the face.
    @Published private(set) var lift: CGFloat = 0
    @Published private(set) var hold: Hold = .resting
    @Published private(set) var screen: PhoneScreen = .home
    @Published private(set) var notifications: [PhoneNotification] = []
    @Published private(set) var screenLit = false
    /// Animation counters for the small physical reactions (whole numbers at rest).
    @Published private(set) var buzzes: CGFloat = 0
    @Published private(set) var nudges: CGFloat = 0

    /// Held high enough to read: the screen takes touches (for its app).
    static let readableLift: CGFloat = 0.35
    var screenInteractive: Bool { hold == .resting && lift >= Self.readableLift }

    /// The end of a drag that moved the phone is never also a tap on its content.
    private(set) var lastReleaseAt = Date.distantPast
    var acceptsContentTap: Bool { screenInteractive && Date().timeIntervalSince(lastReleaseAt) > 0.3 }

    /// Content on the screen (Building GPS's map, while zoomed in or being
    /// pinched) has taken the current touch for itself: it doesn't move the phone.
    private(set) var contentClaimsTouch = false
    func claimTouchForContent() { if hold != .held { contentClaimsTouch = true } }
    func endContentClaim() { contentClaimsTouch = false }

    /// Open an app, or go Home. Where the phone is held is untouched.
    func open(_ app: PhoneScreen) {
        screen = app
        if app != .home { PhoneApps.shared.refreshDeliveries() }
    }
    var unreadCount: Int { notifications.count }

    private var token = 0
    private var litToken = 0
    private let buzzHaptic = UIImpactFeedbackGenerator(style: .rigid)

    /// Internal (not private) only so tests can use their own phone; the app uses `shared`.
    init() {}

    // MARK: Holding the phone

    /// A finger has taken hold of the phone.
    @discardableResult
    func beginGrab() -> Bool {
        guard hold != .held else { return false }
        token += 1                                        // a spring still finishing is superseded
        hold = .held
        diag("phone.grab", ["lift": Double(lift)])
        PhoneApps.shared.refreshDeliveries()              // taking the phone out: anything due has arrived
        return true
    }

    /// The finger moved: the phone is exactly here (no animation).
    func drag(to newLift: CGFloat) {
        guard hold == .held else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { lift = newLift }
    }

    /// The finger let go: the phone stays where it is. Only if it was pulled
    /// past either end does it spring back to that end.
    func release() {
        guard hold == .held else { return }
        lastReleaseAt = Date()
        let kept = min(max(lift, 0), 1)
        if abs(kept - lift) > 0.0001 {
            moveTo(kept)
        } else {
            hold = .resting
        }
        diag("phone.rest", ["lift": Double(kept)])
    }

    /// Spring to `target` (used only for the end stops and accessibility).
    private func moveTo(_ target: CGFloat) {
        hold = .settling
        token += 1
        let t = token
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 190, damping: 24)) {
            lift = target
        } completion: { [weak self] in
            self?.finishMove(t)
        }
        // Belt and braces: never stay "settling" because a completion went missing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.finishMove(t) }
    }

    private func finishMove(_ t: Int) {
        guard t == token, hold == .settling else { return }
        hold = .resting
    }

    /// Accessibility: hold the phone up / put it down without a drag.
    func accessibilityMove(up: Bool) {
        guard hold != .held else { return }
        moveTo(up ? 1 : 0)
    }

    /// A plain tap on the phone's frame: it moves a little, up and back.
    func nudge() {
        guard hold == .resting else { return }
        withAnimation(.easeOut(duration: 0.42)) { nudges += 1 }
    }

    /// The phone can't be shown right now (the opening screen, decorating, a
    /// reset): straight back to low, no animation.
    func forceLow(reason: String) {
        guard hold != .resting || lift != 0 else { return }
        token += 1
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { lift = 0 }
        hold = .resting
        diag("phone.forceLow", ["reason": reason])
    }

    /// DEV New Player reset: a fresh phone (nothing waiting on it).
    func resetForNewPlayer() {
        forceLow(reason: "newPlayerReset")
        notifications = []
        screen = .home
        screenLit = false
        ChatStore.shared.resetForNewPlayer()
        PhoneApps.shared.resetForNewPlayer()
    }

    // MARK: Notifications

    /// How long an ignored notification stays on the screen. The message
    /// itself stays where it was delivered (and unread) regardless.
    static let notificationLifetime: TimeInterval = 12

    /// Something arrived (see BuildingDispatch): the phone sounds, buzzes in
    /// place, lights its screen and shows a compact notification -- wherever
    /// it is held. It is never raised, moved or opened by this.
    func notify(source: String, title: String, opens: PhoneNotification.Opens? = nil) {
        let note = PhoneNotification(id: UUID(), source: source, title: title, opens: opens)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { notifications.insert(note, at: 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.notificationLifetime) { [weak self] in self?.dismiss(note.id) }
        HallPhoneSound.playNotification()
        buzzHaptic.prepare()
        buzzHaptic.impactOccurred(intensity: 0.7)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.buzzHaptic.impactOccurred(intensity: 0.5) }
        withAnimation(.linear(duration: 0.55)) { buzzes += 1 }
        litToken += 1
        let t = litToken
        withAnimation(.easeOut(duration: 0.15)) { screenLit = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.litToken == t else { return }
            withAnimation(.easeIn(duration: 0.8)) { self.screenLit = false }
        }
        diag("phone.notification", ["source": source, "title": title, "showing": notifications.count])
    }

    /// A notification goes away (tapped, or its time is up).
    func dismiss(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) { notifications.removeAll { $0.id == id } }
    }
}

// MARK: - Sound

/// The notification sound: two soft glassy notes, a fifth apart. Our own,
/// synthesised like every other Hallways sound.
@MainActor
enum HallPhoneSound {
    private static var data: Data?
    private static var player: AVAudioPlayer?

    static func playNotification() {
        let d = data ?? BobbinSound.wav(render())
        data = d
        guard let p = try? AVAudioPlayer(data: d) else { return }
        p.volume = 0.9
        HallwaysAudio.shared.manage(p)               // Oct 8: the mute switch
        p.prepareToPlay()
        p.play()
        player = p
    }

    private static func render() -> [Float] {
        let rate = Float(BobbinSound.rate)
        func note(_ f: Float, _ seconds: Float, decay: Float) -> [Float] {
            let n = Int(seconds * rate)
            return (0..<n).map { i in
                let t = Float(i) / rate
                let s = sin(2 * .pi * f * t) + 0.28 * sin(2 * .pi * 2 * f * t) * exp(-t / 0.08)
                    + 0.12 * sin(2 * .pi * 3.01 * f * t) * exp(-t / 0.03)
                return s * exp(-t / decay) * min(1, t / 0.004) * min(1, (seconds - t) / 0.02)
            }
        }
        var out = [Float](repeating: 0, count: Int(0.9 * rate))
        func mix(_ part: [Float], at seconds: Float, gain: Float) {
            let o = Int(seconds * rate)
            for (i, v) in part.enumerated() where o + i < out.count { out[o + i] += v * gain }
        }
        mix(note(1174.66, 0.6, decay: 0.16), at: 0, gain: 0.8)
        mix(note(1760.0, 0.75, decay: 0.22), at: 0.11, gain: 0.8)
        let peak = out.map { abs($0) }.max() ?? 1
        return out.map { $0 / peak * 0.3 }
    }
}

// MARK: - Layout (one path from low to the face)

struct HallPhoneLayout: Equatable {
    static let aspect: CGFloat = 0.47              // width / height
    static let lowWidth: CGFloat = 40
    static let lowTilt: CGFloat = 32 * .pi / 180   // leaning away while held low (drawn as foreshortening)
    static let lowRoll: CGFloat = 10 * .pi / 180   // a casual angle in the RIGHT hand
    static let screenCanvasWidth: CGFloat = 320    // the screen is laid out at this width, then scaled
    /// The margin around the phone (in screen points) where a finger can take hold of it.
    static let gripMargin: CGFloat = 16

    let raisedWidth: CGFloat
    let raisedCenter: CGPoint
    let restCenter: CGPoint

    var raisedHeight: CGFloat { raisedWidth / Self.aspect }
    var lowScale: CGFloat { Self.lowWidth / raisedWidth }
    var travel: CGFloat { max(1, restCenter.y - raisedCenter.y) }

    init(size: CGSize, insets: EdgeInsets) {
        let w = max(120, min(size.width * 0.84, size.height * 0.92 * Self.aspect))
        raisedWidth = w
        let h = w / Self.aspect
        let lowH = Self.lowWidth / Self.aspect
        // Low: held in the right hand, bottom-right (the old mini-map's corner).
        let rest = CGPoint(x: size.width - insets.trailing - 26 - Self.lowWidth / 2,
                           y: size.height - insets.bottom - 46 - lowH / 2)
        restCenter = rest
        // At the face: a touch right of centre (right hand), its bottom tenth
        // past the bottom edge (held, not floating). Landscape: kept clearly
        // above the low position.
        raisedCenter = CGPoint(x: size.width * 0.52, y: min(size.height - h * 0.9 + h / 2, rest.y - 100))
    }

    private var control: CGPoint {
        CGPoint(x: restCenter.x + (raisedCenter.x - restCenter.x) * 0.2,
                y: restCenter.y + (raisedCenter.y - restCenter.y) * 0.8)
    }

    /// The phone's centre at `lift` (rises first, then swings in; past 0 or 1
    /// it keeps going along the end tangent, for rubber-banding).
    func center(at lift: CGFloat) -> CGPoint {
        let q = min(max(lift, 0), 1)
        let a = (1 - q) * (1 - q), b = 2 * (1 - q) * q, c = q * q
        var x = a * restCenter.x + b * control.x + c * raisedCenter.x
        var y = a * restCenter.y + b * control.y + c * raisedCenter.y
        if lift > 1 { x += (lift - 1) * (raisedCenter.x - control.x); y += (lift - 1) * (raisedCenter.y - control.y) }
        if lift < 0 { x += lift * (control.x - restCenter.x); y += lift * (control.y - restCenter.y) }
        return CGPoint(x: x, y: y)
    }

    func scale(at lift: CGFloat) -> CGFloat { max(0.05, lowScale + (1 - lowScale) * lift) }
    /// Vertical foreshortening of the lean (1 = facing the player squarely).
    func lean(at lift: CGFloat) -> CGFloat { cos(Self.lowTilt * (1 - min(max(lift, 0), 1))) }
    func roll(at lift: CGFloat) -> CGFloat { Self.lowRoll * (1 - min(max(lift, 0), 1)) }

    /// The lift that puts the phone under a finger that has moved `dy` points
    /// (down = +) since it took hold at `startLift`. Beyond either end it
    /// resists (rubber band).
    func lift(from startLift: CGFloat, dy: CGFloat) -> CGFloat {
        let desired = center(at: min(max(startLift, 0), 1)).y + dy
        let y0 = center(at: 0).y, y1 = center(at: 1).y
        if desired >= y0 { return -min(0.12, (desired - y0) / travel * 0.3) }
        if desired <= y1 { return 1 + min(0.12, (y1 - desired) / travel * 0.3) }
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if center(at: mid).y > desired { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}

// MARK: - Effects

/// A notification's buzz: a quick rattle in place that dies away.
private struct PhoneBuzzEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        let f = animatableData - floor(animatableData)
        guard f > 0.0001 else { return ProjectionTransform(.identity) }
        let decay = 1 - f
        let angle = sin(f * .pi * 14) * 0.09 * decay
        let dx = sin(f * .pi * 22) * 10 * decay
        let t = CGAffineTransform(translationX: size.width / 2 + dx, y: size.height / 2)
            .rotated(by: angle)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(t)
    }
}

/// The plain-tap nudge: the phone lifts a little and drops back.
private struct PhoneNudgeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        let f = animatableData - floor(animatableData)
        guard f > 0.0001 else { return ProjectionTransform(.identity) }
        let bump = sin(f * .pi)
        return ProjectionTransform(CGAffineTransform(translationX: -3 * bump, y: -16 * bump))
    }
}

// MARK: - Host

/// The phone over the live world: in ContentView's ZStack outside the
/// controller-dependent overlays, so it survives floor/controller changes.
/// It covers nothing but the phone: everywhere else, touches reach Hallways.
struct HallPhoneOverlayHost: View {
    @ObservedObject var decorator: DecoratorState
    /// For Building GPS: the live floor (controller) and the building's floors.
    let navBridge: NavigationBridge
    let mazeStore: MazeStore
    @ObservedObject private var phone = HallPhone.shared

    /// The touch currently moving the phone (nil = none yet).
    @State private var grabStartY: CGFloat?
    @State private var grabStartLift: CGFloat = 0
    /// Per-touch bookkeeping (tap / dev long-press / drag).
    @State private var touchMoved = false
    @State private var devFired = false
    @State private var devToken = 0
    @State private var devPending = false
    @GestureState private var touching = false

    private static let space = "hallPhone"

    /// The phone is a thing the player is holding: it stays with them through
    /// walks, rides, sitting down at the computer and getting up again. Only
    /// the authoring Decorator puts it away.
    private var available: Bool { !decorator.enabled }

    var body: some View {
        GeometryReader { geo in
            let layout = HallPhoneLayout(size: geo.size, insets: geo.safeAreaInsets)
            let up = min(max(phone.lift, 0), 1)
            ZStack(alignment: .topLeading) {
                // The world dims a little as the phone comes close -- seen,
                // never touched: it takes no touches at all.
                Color.black.opacity(0.18 * up)
                    .allowsHitTesting(false)
                if available {
                    phoneObject(layout: layout)
                    if phone.unreadCount > 0 && phone.lift < 0.15 {
                        badge.position(x: layout.restCenter.x - 18,
                                       y: layout.restCenter.y - HallPhoneLayout.lowWidth / HallPhoneLayout.aspect / 2 + 4)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: Self.space)
            .onChange(of: touching) { _, isTouching in
                // A touch the system cancelled (no onEnded): never leave the
                // phone held. Deferred a turn so a real release always gets
                // there first.
                if !isTouching { DispatchQueue.main.async { finishTouch() } }
            }
        }
        .ignoresSafeArea()
        .onDisappear { phone.forceLow(reason: "host removed") }
        .onChange(of: available) { _, isAvailable in
            if !isAvailable { phone.forceLow(reason: "phone unavailable") }
        }
    }

    // MARK: The phone

    /// The phone at its current lift. Placed with plain scale / rotation /
    /// position (affine), so a touch lands exactly where the phone is drawn.
    private func phoneObject(layout: HallPhoneLayout) -> some View {
        let lift = phone.lift
        let w = layout.raisedWidth, h = layout.raisedHeight
        let s = layout.scale(at: lift)
        let margin = HallPhoneLayout.gripMargin / s          // constant on screen, whatever the size
        return ZStack {
            // The phone's touch area: the whole phone plus a small margin.
            RoundedRectangle(cornerRadius: w * 0.13 + margin, style: .continuous)
                .fill(Color.white.opacity(0.001))
                .frame(width: w + 2 * margin, height: h + 2 * margin)
            HallPhoneBody(phone: phone, width: w, navBridge: navBridge, mazeStore: mazeStore)
                .modifier(PhoneBuzzEffect(animatableData: phone.buzzes))
        }
        .frame(width: w + 2 * margin, height: h + 2 * margin)
        // THE WHOLE PHONE IS THE GRAB SURFACE: this gesture sees every touch
        // on the phone, wherever it lands (screen, notification, bezel), at
        // every lift -- alongside, not instead of, whatever is under the
        // finger. Moved = the phone is being moved; not moved = a tap, which
        // the content under the finger handles.
        .simultaneousGesture(phoneTouch(layout: layout))
        .scaleEffect(x: s, y: s * layout.lean(at: lift))
        .rotationEffect(.radians(Double(layout.roll(at: lift))))
        .position(layout.center(at: lift))
        .modifier(PhoneNudgeEffect(animatableData: phone.nudges))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(phone.unreadCount > 0 ? "Your phone, \(phone.unreadCount) new" : "Your phone")
        .accessibilityAction(named: "Hold phone up") { phone.accessibilityMove(up: true) }
        .accessibilityAction(named: "Hold phone low") { phone.accessibilityMove(up: false) }
    }

    private var badge: some View {
        Text("\(phone.unreadCount)")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color(red: 0.92, green: 0.36, blue: 0.3), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
            .allowsHitTesting(false)
    }

    // MARK: Touching the phone's grip: tap = nudge, hold still = (DEBUG) test
    // notification, drag = move the phone

    private func phoneTouch(layout: HallPhoneLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($touching) { _, state, _ in state = true }
            .onChanged { v in touchChanged(v, layout: layout) }
            .onEnded { _ in touchEnded() }
    }

    private func touchChanged(_ v: DragGesture.Value, layout: HallPhoneLayout) {
        if grabStartY == nil && !touchMoved && !devPending && !devFired {
            #if DEBUG
            // DEV: hold the phone still for 0.6 s = Dispatch sends the staff
            // meeting test mail (Episode 3 pipeline test).
            devPending = true
            devToken += 1
            let t = devToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard devToken == t, devPending, !touchMoved else { return }
                devPending = false
                devFired = true
                BuildingDispatch.devSendStaffMeetingTest()
            }
            #endif
        }
        if !touchMoved, hypot(v.translation.width, v.translation.height) > 6 {
            touchMoved = true
            devPending = false
        }
        guard touchMoved, !devFired else { return }
        if grabStartY == nil {
            guard !phone.contentClaimsTouch else { return }   // the map is panning/zooming with this touch
            guard phone.beginGrab() else { return }
            grabStartY = v.startLocation.y
            grabStartLift = phone.lift
        }
        guard let start = grabStartY else { return }
        phone.drag(to: layout.lift(from: grabStartLift, dy: v.location.y - start))
    }

    private func touchEnded() {
        // A tap on a phone held too low to read nudges it; once it can be
        // read, a tap belongs to what is on the screen.
        if grabStartY == nil, !touchMoved, !devFired, !phone.screenInteractive { phone.nudge() }
        finishTouch()
    }

    private func finishTouch() {
        if grabStartY != nil { phone.release() }
        phone.endContentClaim()
        grabStartY = nil
        touchMoved = false
        devFired = false
        devPending = false
        devToken += 1
    }
}

// MARK: - The phone itself

/// The physical phone: our own plain design -- a dark slab, a thin rim, a
/// small camera dot in the top bezel, two side keys. Drawn at its raised
/// size; the host scales and places it for the current lift.
private struct HallPhoneBody: View {
    @ObservedObject var phone: HallPhone
    let width: CGFloat
    let navBridge: NavigationBridge
    let mazeStore: MazeStore

    var body: some View {
        let h = width / HallPhoneLayout.aspect
        let bezel = width * 0.035
        let corner = width * 0.13
        let screenW = width - 2 * bezel, screenH = h - 2 * bezel
        let scale = screenW / HallPhoneLayout.screenCanvasWidth
        let lift = min(max(phone.lift, 0), 1)
        // Low = the screen is a dim glow; up = fully readable. A notification lights it.
        let readable = min(1, 0.18 + 0.82 * smoothstep(0.15, 0.75, lift) + (phone.screenLit ? 0.55 : 0))
        return ZStack(alignment: .top) {
            // Body and rim take no touches: on the bezel a finger reaches the
            // frame band behind (moving the phone); only the screen is the app's.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.22)], startPoint: .top, endPoint: .bottom),
                              lineWidth: max(1.5, width * 0.008))
                .allowsHitTesting(false)
            HallPhoneScreen(phone: phone, navBridge: navBridge, mazeStore: mazeStore)
                .frame(width: HallPhoneLayout.screenCanvasWidth, height: screenH / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: screenW, height: screenH, alignment: .topLeading)
                .overlay(Color.black.opacity(1 - readable).allowsHitTesting(false))
                .clipShape(RoundedRectangle(cornerRadius: corner - bezel, style: .continuous))
                .contentShape(Rectangle())
                .padding(bezel)
            Circle()
                .fill(Color(white: 0.04))
                .overlay(Circle().stroke(Color(white: 0.3), lineWidth: 0.5))
                .frame(width: bezel * 0.55, height: bezel * 0.55)
                .padding(.top, bezel * 0.22)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: h)
        .overlay(alignment: .topTrailing) {
            VStack(spacing: width * 0.03) {
                Capsule().frame(width: 3, height: width * 0.16)
                Capsule().frame(width: 3, height: width * 0.09)
            }
            .foregroundStyle(Color(white: 0.3))
            .offset(x: 2.5, y: h * 0.18)
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 10)
    }

    private func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// The phone's screen: Home (wallpaper + app cards + notifications) or one
/// of the apps (PhoneApps.swift). Taps here belong to what is shown; a drag
/// that starts here moves the phone (the host's phone-wide gesture), except
/// on Building GPS's map while it is zoomed or pinched.
private struct HallPhoneScreen: View {
    @ObservedObject var phone: HallPhone
    let navBridge: NavigationBridge
    let mazeStore: MazeStore

    var body: some View {
        let home = phone.screen == .home
        ZStack(alignment: .top) {
            if home {
                // The wallpaper's decoration is an overlay, so it can never
                // widen the screen's layout (it used to: a 420-wide circle in
                // the stack made the 320-wide screen lay out at 420 and clip
                // both sides).
                LinearGradient(colors: [Color(red: 0.12, green: 0.15, blue: 0.3),
                                        Color(red: 0.1, green: 0.33, blue: 0.4),
                                        Color(red: 0.55, green: 0.4, blue: 0.32)],
                               startPoint: .top, endPoint: .bottom)
                    .overlay(alignment: .topLeading) {
                        Circle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 420, height: 420)
                            .offset(x: 120, y: 260)
                    }
                    .clipped()
            } else {
                PhoneStyle.paper
            }
            VStack(spacing: 0) {
                statusStrip(light: home)
                switch phone.screen {
                case .home: PhoneHomeScreen(phone: phone)
                case .buildingGPS: BuildingGPSApp(phone: phone, navBridge: navBridge, mazeStore: mazeStore)
                case .hallChat: HallChatApp(phone: phone)
                case .mail: PhoneMailApp(phone: phone, mazeStore: mazeStore)
                case .directory: DirectoryApp(phone: phone)
                }
            }
            // Notifications sit over whatever is on the screen.
            PhoneNotificationBanners(phone: phone, mazeStore: mazeStore)
        }
        .contentShape(Rectangle())
        .onTapGesture { }                                  // the screen keeps its taps
    }

    private func statusStrip(light: Bool) -> some View {
        HStack(spacing: 6) {
            Spacer()
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { k in
                    RoundedRectangle(cornerRadius: 1).frame(width: 3, height: 4 + CGFloat(k) * 2.5)
                }
            }
            RoundedRectangle(cornerRadius: 3)
                .stroke(lineWidth: 1.2)
                .frame(width: 22, height: 11)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).frame(width: 14, height: 7).padding(.leading, 2) }
        }
        .foregroundStyle(light ? Color.white.opacity(0.85) : PhoneStyle.ink.opacity(0.7))
        .padding(.top, 14)
        .padding(.horizontal, 20)
        .frame(height: 34)
    }
}
