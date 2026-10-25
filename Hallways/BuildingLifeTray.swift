//
//  BuildingLifeTray.swift
//  Hallways
//
//  Oct 21 -- RETIRE THE PHONE, INTRODUCE THE BUILDING LIFE TRAY.
//
//  The in-game phone is gone from the screen. Building Life lives in a plain
//  bottom tray over the live world:
//
//   - Collapsed (Oct 21, night: was a small tab bottom-right, whose drags could
//     start in the home-indicator zone and move the whole app instead): a
//     thin, full-width edge of the tray along the bottom with a centred grab
//     handle. Its touch area -- the grab band -- lies wholly ABOVE the bottom
//     safe area (the home-indicator gesture zone); the strip under it is only
//     drawn. The HUD row (gear, centre button, tool tray) sits just above the
//     band (ContinuousWalkControls.bottomPadding). Only the handle shows.
//   - Drag the band up or down: the tray follows the finger 1:1 and STAYS
//     where it is let go -- no snapping, the principle of the old adjustable
//     map and the phone. Let go near the bottom and it settles back to the
//     edge. A tap on the collapsed band opens it to the last height; a tap on
//     the open band puts it away. Dragging never waits on a tap.
//   - Only the band resizes it. Everything inside is Building Life's own
//     (Activity, Directory, a floor's plan). Everything outside the tray is
//     the hallway, exactly as before: the tray is an overlay; the SceneKit
//     view is never resized, rebuilt or paused by it.
//   - Oct 21 (later): NO MESSAGING here. The unread count, the envelope, the
//     Mail / HallChat screens, the message notices and the DEBUG hold-to-send
//     test mail are gone from the tray. Mail and HallChat (code and data) are
//     kept but unreachable for players; HallPhone no longer sounds, buzzes or
//     lights for a message (HallPhone.presentsNotifications). The building's
//     own story sending (BuildingDispatch -- the staff-meeting invitation that
//     the conference meeting waits on) is untouched; only the tray's extra
//     "anything due?" checks are gone.

//  Oct 23 -- THE BUILDING BUTTON. The collapsed bottom edge no longer takes
//  touches (its drags began beside the system's home gesture: unreliable, and
//  sometimes the app-switcher instead). A round BUILDING button (bottom-right, on
//  the Settings gear's line) is the way in now, and the tray's handle:
//   - tap: open fully (tap again: put away) -- the tab and its contents as they were;
//   - drag (past a 10 pt slop, so a tap never moves it): the tray follows the
//     finger 1:1 within its limits; let go and it settles open or away (by where
//     it's heading -- a flick counts), smoothly;
//   - it rides with the tray, just above its top edge at the right -- and once the
//     tray is nearly full height it stops below the status bar, sitting over the
//     open tray's empty top-right corner (beside "Building Life", above the tabs).
//  The OPEN tray's top band is as it was (drag to resize and leave it there; tap
//  to put it away): it's nowhere near the home gesture.
//
//  Oct 24 -- HIDDEN WHEN PUT AWAY. The closed tray no longer shows at all (no
//  edge, no handle): put away, it slides fully below the screen, and nothing of
//  it covers the world. BUILDING still opens it (a tap: fully; dragging the
//  button up: it follows the finger, then settles open or away); the open tray's
//  band still drags it down and away. The BUILDING button and the Settings gear
//  sit lower, in the bottom corners (cornerBottom above the safe area, so clear
//  of the home indicator's gesture); open, the button still rides just above the
//  tray's top edge. (No bottom-edge swipe: that was retired on Oct 23 -- it
//  fought the system's home gesture.)
//
//  Cost: no timers of its own. Building Life's 2 Hz refresh runs only while
//  its content is in the tray (as it did while the full-screen panel was
//  open); collapsed, nothing runs. During a drag only the tray's offset
//  changes -- its content is laid out once when the drag starts and once when
//  it ends, never per frame.
//

import SwiftUI
import UIKit
import Combine

/// Where the tray's top edge is, in window points (+infinity: it covers
/// nothing). Read by the window-level magnifier pinch (CameraMagnifier) so a
/// pinch inside the tray is the tray's, never the camera's.
@MainActor
enum BuildingLifeTrayCover {
    // (see below: BuildingLifeTrayLayout, for SwiftUI controls that must clear it)
    static var top: CGFloat = .infinity
}

/// Oct 22 -- where the COLLAPSED tray's top edge is, measured up from the
/// bottom of the screen's safe area (what SwiftUI overlays pad from): the
/// tray's real band and safe-area geometry, published by the tray itself, so a
/// bottom control can sit above it (DECORATE). Until the tray has measured,
/// the band's own height (where it is on every current iPhone).
final class BuildingLifeTrayLayout: ObservableObject {
    static let shared = BuildingLifeTrayLayout()
    @Published private(set) var collapsedTop: CGFloat = BuildingLifeTrayMetrics.bandHeight

    func update(collapsedTop value: CGFloat) {
        let v = max(0, value)
        guard abs(v - collapsedTop) > 0.5 else { return }
        collapsedTop = v
        diag("tray.collapsedTop", ["aboveSafeBottom": Double(v)])
    }
}

/// The tray's sizes (pure; tested).
nonisolated struct BuildingLifeTrayMetrics: Equatable {
    /// The grab band: the collapsed edge's height above the bottom safe area,
    /// and the open tray's top strip. All of it is the handle's touch area.
    /// (Oct 21, later: 26 -> 34, a more generous touch target -- full width.)
    static let bandHeight: CGFloat = 34
    /// The least room kept under the band for the system's bottom-edge gesture,
    /// even where the screen reports no bottom inset (home-button iPhones:
    /// Control Center; or an inset that wasn't read).
    static let minimumBottom: CGFloat = 16
    /// A saved open height outside this share of the range is not trusted.
    static let validShares: ClosedRange<Double> = 0.1...1
    /// Let go within this of the bottom: put away.
    static let collapseSlack: CGFloat = 36
    /// Gap left above the open tray at its tallest (the world still shows a sliver).
    static let topGap: CGFloat = 6

    let width: CGFloat
    let height: CGFloat
    let top: CGFloat
    let bottom: CGFloat

    init(size: CGSize, top: CGFloat, bottom: CGFloat) {
        width = size.width
        height = size.height
        self.top = top
        self.bottom = max(bottom, Self.minimumBottom)
    }

    /// Oct 21 (later) -- THE TRAY COULD BE LOST: drawn edge-to-edge (ignoring the
    /// safe area), the tray's own geometry may report NO bottom inset, which put
    /// the collapsed band inside the home-indicator zone, where it can't be
    /// grabbed. The bottom used is the largest of what the view reports and what
    /// the window reports (and never less than minimumBottom).
    static func safeBottom(reported: CGFloat, window: CGFloat) -> CGFloat {
        max(reported, window, minimumBottom)
    }

    /// A saved share (UserDefaults) made safe: anything missing, not a number,
    /// or so low the tray would open as good as closed -> the default half.
    static func validShare(_ saved: Double) -> Double {
        saved.isFinite && validShares.contains(saved) ? saved : 0.5
    }

    /// The collapsed edge: just the grab band, above the bottom safe area.
    var minOpen: CGFloat { bottom + Self.bandHeight }

    /// Where the handle takes touches at `visible` (screen points): the band,
    /// full width -- never inside the bottom safe area.
    func handleArea(visible: CGFloat) -> CGRect {
        CGRect(x: 0, y: height - clamped(visible), width: width, height: Self.bandHeight)
    }
    /// Nearly full screen (below the top safe area).
    var maxOpen: CGFloat { max(minOpen + 120, height - top - Self.topGap) }

    func clamped(_ visible: CGFloat) -> CGFloat { min(max(visible, minOpen), maxOpen) }

    /// The tray's visible height after a finger that took hold at `start` moved `dy` (down = +).
    func dragged(from start: CGFloat, dy: CGFloat) -> CGFloat { clamped(start - dy) }

    /// Let go at `visible`: put away (nil) near the bottom, else stays exactly there.
    func released(at visible: CGFloat) -> CGFloat? {
        visible <= minOpen + Self.collapseSlack ? nil : clamped(visible)
    }

    /// The tray's last open height as a share of the tallest (saved), back to points.
    func height(forShare share: Double) -> CGFloat {
        clamped(minOpen + (maxOpen - minOpen) * CGFloat(min(max(share, 0), 1)))
    }
    /// Oct 23 (BUILDING button): let go of the button heading for `predicted`:
    /// open fully past halfway, else put away (nil).
    func snapped(predicted: CGFloat) -> CGFloat? {
        clamped(predicted) >= (minOpen + maxOpen) / 2 ? maxOpen : nil
    }

    /// Oct 23 (BUILDING button): its size, its inset from the right edge, and the
    /// least room kept above it (under the status bar).
    static let buttonSize: CGFloat = 56
    static let buttonInset: CGFloat = 20
    static let buttonTopMargin: CGFloat = 8
    /// A finger must move this far on the button before it drags (a tap never does).
    static let buttonSlop: CGFloat = 10
    /// Oct 24: the corner buttons' (Settings gear, BUILDING) bottom edge above the
    /// bottom safe area -- low in the corners, clear of the home-indicator gesture.
    static let cornerBottom: CGFloat = 10

    /// Oct 24: while the tray is out, how much higher the button rides than its
    /// corner line, so it stays just above the tray's top edge (put away: 0).
    func buttonLift(gearLine: CGFloat) -> CGFloat { max(0, minOpen + 4 - gearLine) }

    /// Oct 23: the button's top (screen points from the top) with the tray at
    /// `visible`: collapsed, on the gear's line (`gearLine`: its bottom above the
    /// screen's bottom); rising 1:1 with the tray; never closer to the top than
    /// the safe area plus a margin.
    func buttonTop(visible: CGFloat, gearLine: CGFloat, lift: CGFloat = 0) -> CGFloat {
        let bottomAbove = gearLine + lift + (clamped(visible) - minOpen)
        return max(height - bottomAbove - Self.buttonSize, top + Self.buttonTopMargin)
    }

    func share(of visible: CGFloat) -> Double {
        Double((clamped(visible) - minOpen) / max(1, maxOpen - minOpen))
    }
}

struct BuildingLifeTray: View {
    let navBridge: NavigationBridge
    let mazeStore: MazeStore

    /// The open tray's visible height (from the screen's bottom edge); nil = put away.
    @State private var shown: CGFloat?
    /// The height the content is laid out for (changes only when a drag ends,
    /// never during one or during an animation).
    @State private var laidOut: CGFloat = 0
    /// While a finger moves the tray: its visible height.
    @State private var dragHeight: CGFloat?
    @State private var dragStart: CGFloat = 0
    @State private var touchMoved = false
    /// Oct 23: the drag under way is the BUILDING button's (it settles open or away).
    @State private var dragFromButton = false
    @State private var predicted: CGFloat?
    @State private var closeToken = 0
    /// Oct 24: sliding out of sight (put away, or about to come up): drawn below the screen.
    @State private var sinking = false
    @GestureState private var touching = false
    /// The window's safe-area insets, read when the tray appears and when the
    /// screen's size changes (rotation) -- never per frame.
    @State private var window: UIEdgeInsets = .zero

    private static let shareKey = "buildingLifeTray.openShare"
    private static var savedShare: Double {
        BuildingLifeTrayMetrics.validShare(UserDefaults.standard.double(forKey: shareKey))
    }

    /// The window's own safe-area insets (UIKit; the key window of this app).
    private static var windowInsets: UIEdgeInsets {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.safeAreaInsets ?? .zero
    }

    var body: some View {
        GeometryReader { geo in
            let m = BuildingLifeTrayMetrics(size: geo.size, top: max(geo.safeAreaInsets.top, window.top),
                                            bottom: BuildingLifeTrayMetrics.safeBottom(reported: geo.safeAreaInsets.bottom,
                                                                                       window: window.bottom))
            // Collapsed: the edge (the band only). The same view grows when dragged,
            // so the finger's gesture is never handed from one view to another.
            let collapsed = shown == nil && dragHeight == nil
            let visible = m.clamped(dragHeight ?? shown ?? m.minOpen)
            // Oct 24: put away (or sliding away), none of it is on the screen.
            let resting = collapsed || sinking
            let covered = resting ? 0 : visible
            // Oct 22: the collapsed top, above the safe-area bottom the HUD pads from.
            let collapsedTop = m.minOpen - max(geo.safeAreaInsets.bottom, window.bottom)
            // Oct 23: the BUILDING button, collapsed on the Settings gear's line
            // (Oct 24: both low in the bottom corners; out, it rides above the tray).
            let gearLine = max(geo.safeAreaInsets.bottom, window.bottom) + BuildingLifeTrayMetrics.cornerBottom
            ZStack(alignment: .topLeading) {
                sheet(m, visible: visible, collapsed: collapsed, resting: resting)
                buildingButton(m, top: m.buttonTop(visible: resting ? m.minOpen : visible, gearLine: gearLine,
                                                   lift: resting ? 0 : m.buttonLift(gearLine: gearLine)),
                               collapsed: collapsed)
            }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .onChange(of: geo.size) { _, _ in window = Self.windowInsets }
                .onChange(of: collapsedTop, initial: true) { _, top in BuildingLifeTrayLayout.shared.update(collapsedTop: top) }
                .onChange(of: covered, initial: true) { _, v in
                    BuildingLifeTrayCover.top = v > 0 ? geo.size.height - v : .infinity   // (Oct 24: away, it covers nothing)
                }
                .onChange(of: touching) { _, isTouching in
                    // (the window wasn't ready when the tray appeared: read it again)
                    if isTouching, window == .zero { window = Self.windowInsets }
                    // A touch the system cancelled (no onEnded): never leave the tray held.
                    if !isTouching { DispatchQueue.main.async { finishTouch(m) } }
                }
                .onAppear {
                    diag("tray.geometry", ["reportedBottom": Double(geo.safeAreaInsets.bottom), "usedBottom": Double(m.bottom),
                                           "screenHeight": Double(geo.size.height)])
                }
        }
        .ignoresSafeArea()
        .onAppear {
            let w = Self.windowInsets
            window = w
            DispatchQueue.main.async { window = Self.windowInsets }   // (once more, after the first layout)
            diag("tray.metrics", ["windowBottom": Double(w.bottom), "windowTop": Double(w.top),
                                  "band": Double(BuildingLifeTrayMetrics.bandHeight)])
        }
        .onDisappear { BuildingLifeTrayCover.top = .infinity }
    }

    // MARK: The sheet

    private func sheet(_ m: BuildingLifeTrayMetrics, visible: CGFloat, collapsed: Bool, resting: Bool) -> some View {
        // Laid out at full height and slid down: moving it never re-lays its content.
        // While a finger moves it the content is laid out as if fully open (its top
        // shows as the tray grows); when it rests, the content's bottom is lifted to
        // the visible bottom (above the home indicator) so lists scroll to their end.
        let hidden = dragHeight == nil ? m.maxOpen - m.clamped(laidOut) : 0
        return VStack(spacing: 0) {
            band(m, collapsed: collapsed)
            // Collapsed, no content at all (nothing refreshes); it is put in the
            // moment a drag starts, under the band that keeps the finger.
            Group {
                if collapsed {
                    Color.clear
                } else {
                    BuildingLifePanel(navBridge: navBridge, mazeStore: mazeStore, accessory: EmptyView())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.bottom, hidden + m.bottom)
        }
        .frame(width: m.width, height: m.maxOpen, alignment: .top)
        .background(PhoneStyle.paper.opacity(collapsed ? 0.94 : 1))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .offset(y: resting ? m.height + 4 : m.height - visible)              // (Oct 24: away, wholly below the screen)
    }

    /// The grab band across the tray's top (collapsed: all there is of it):
    /// drag to resize; tap to open (collapsed) or put away (open).
    private func band(_ m: BuildingLifeTrayMetrics, collapsed: Bool) -> some View {
        ZStack {
            Color.clear
            Capsule().fill(PhoneStyle.inkSoft.opacity(0.6)).frame(width: 44, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: BuildingLifeTrayMetrics.bandHeight)
        .contentShape(Rectangle())                                 // (the whole band, full width)
        .gesture(handle(m))
        // Oct 23: collapsed, the edge is only drawn -- the BUILDING button opens it
        // (no more drags beginning beside the home gesture).
        .allowsHitTesting(!collapsed)
        .accessibilityElement()
        .accessibilityLabel(collapsed ? "Building Life" : "Building Life tray handle")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if collapsed { open(m) } else { close(m) } }
    }

    /// Oct 23 -- the BUILDING button: tap to open fully / put away; drag to move
    /// the tray (the same handle machinery as the band).
    private func buildingButton(_ m: BuildingLifeTrayMetrics, top: CGFloat, collapsed: Bool) -> some View {
        Image(systemName: "building.2.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: BuildingLifeTrayMetrics.buttonSize, height: BuildingLifeTrayMetrics.buttonSize)
            .background(.ultraThinMaterial, in: Circle())
            // (open, it may sit over the tray's pale paper: a dark wash keeps the icon legible)
            .background(Circle().fill(Color.black.opacity(collapsed ? 0 : 0.45)))
            .contentShape(Circle())
            .gesture(handle(m, button: true))
            .offset(x: m.width - BuildingLifeTrayMetrics.buttonInset - BuildingLifeTrayMetrics.buttonSize, y: top)
            .accessibilityElement()
            .accessibilityLabel("Building")
            .accessibilityValue(collapsed ? "closed" : "open")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if shown == nil { open(m, fully: true) } else { close(m) } }
    }

    // MARK: Moving it

    /// The band's touch: drag = resize (1:1, stays where let go), tap = open /
    /// put away.
    /// Oct 23: `button` -- the BUILDING button's touch: a larger slop before it
    /// drags, a tap opens FULLY, and let go it settles open or away.
    private func handle(_ m: BuildingLifeTrayMetrics, button: Bool = false) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { v in
                if !touchMoved, hypot(v.translation.width, v.translation.height) > (button ? BuildingLifeTrayMetrics.buttonSlop : 6) {
                    touchMoved = true
                    dragFromButton = button
                    dragStart = shown.map { m.clamped($0) } ?? m.minOpen
                    closeToken += 1                                // (a put-away still finishing is superseded)
                    // Oct 24: from out of sight, the tray (and the button above it) come up
                    // to the finger smoothly rather than appearing under it.
                    let first = m.dragged(from: dragStart, dy: v.translation.height)
                    withAnimation(.easeOut(duration: 0.12)) {
                        sinking = false
                        dragHeight = first
                    }
                    return
                }
                guard touchMoved else { return }
                dragHeight = m.dragged(from: dragStart, dy: v.translation.height)
                if dragFromButton { predicted = m.dragged(from: dragStart, dy: v.predictedEndTranslation.height) }
            }
            .onEnded { v in
                if !touchMoved {
                    if shown == nil { open(m, fully: button) } else { close(m) }
                } else if dragFromButton {
                    predicted = m.dragged(from: dragStart, dy: v.predictedEndTranslation.height)
                }
                finishTouch(m)
            }
    }

    /// The finger let go (or the touch was cancelled): the tray stays where it is.
    private func finishTouch(_ m: BuildingLifeTrayMetrics) {
        if let v = dragHeight, dragFromButton {
            // Oct 23 (BUILDING button): from where the finger left it, smoothly open or away.
            let target = m.snapped(predicted: predicted ?? v)
            dragHeight = nil
            laidOut = target ?? v
            shown = v
            if let target {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.22)) { shown = target }
                }
                diag("tray.open", ["height": Double(target), "by": "button drag"])
            } else {
                close(m)
            }
        } else if let v = dragHeight {
            dragHeight = nil
            if let kept = m.released(at: v) {
                laidOut = kept
                shown = kept
                UserDefaults.standard.set(m.share(of: kept), forKey: Self.shareKey)
                diag("tray.rest", ["height": Double(kept), "share": m.share(of: kept)])
            } else {
                shown = v                                      // (Oct 24: from where it was let go,
                close(m)                                       //  it slides away, out of sight)
            }
        }
        touchMoved = false
        dragFromButton = false
        predicted = nil
    }

    /// Up to the height it was last left at (`fully`, Oct 23 -- the BUILDING button: all the way).
    private func open(_ m: BuildingLifeTrayMetrics, fully: Bool = false) {
        let target = fully ? m.maxOpen : m.height(forShare: Self.savedShare)
        closeToken += 1
        laidOut = target
        // Oct 24: laid out first, still below the screen; then up into view.
        sinking = true
        shown = m.minOpen
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                sinking = false
                shown = target
            }
        }
        diag("tray.open", ["height": Double(target)])
    }

    /// Down and away.
    private func close(_ m: BuildingLifeTrayMetrics) {
        closeToken += 1
        let t = closeToken
        withAnimation(.easeIn(duration: 0.2)) { sinking = true }          // (Oct 24: down out of sight)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard closeToken == t else { return }
            putAway()
        }
    }

    private func putAway() {
        shown = nil
        sinking = false
        diag("tray.away", [:])
    }
}
