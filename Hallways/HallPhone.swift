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
    case contacts                      // Oct 18: the characters the player has met
    case buildingLife                  // Oct 19: the residents, building-wide (BuildingLifeApp.swift)
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
    /// Oct 21 (later): messages are no longer presented to the player -- no
    /// sound, no buzz, no lit screen, nothing on the tray. The message itself is
    /// still delivered to its store by BuildingDispatch (Mail / HallChat data,
    /// and the story beats the staff meeting waits on); here it is only noted
    /// (the passing list, gone after its lifetime as before). Set true to bring
    /// the sound / haptic / animation back.
    static let presentsNotifications = false

    func notify(source: String, title: String, opens: PhoneNotification.Opens? = nil) {
        let note = PhoneNotification(id: UUID(), source: source, title: title, opens: opens)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.notificationLifetime) { [weak self] in self?.dismiss(note.id) }
        guard Self.presentsNotifications else {
            notifications.insert(note, at: 0)
            diag("phone.notification", ["source": source, "title": title, "presented": false])
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { notifications.insert(note, at: 0) }
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

// Oct 21 -- THE PHONE IS RETIRED FROM THE SCREEN. Its presentation (the host
// overlay, the drawn phone, its screen, the buzz/nudge effects and the blinking
// badge) is gone; Building Life and the messages now live in the bottom tray
// (BuildingLifeTray.swift). What stays here is the service the rest of the game
// uses: HallPhone's notifications (BuildingDispatch -> notify; Oct 21, later:
// noted only, not presented -- see presentsNotifications). Mail and HallChat
// are no longer shown in the tray either; their code and data are kept.
// HallPhoneLayout and the lift/grab API above are no longer drawn; they are
// kept only because HallPhoneTests and BuildingDispatchTests still exercise
// them -- remove them together with those tests.
