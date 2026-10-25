import Foundation
import SwiftUI
import Testing
@testable import Hallways

/// Oct 21 -- the Building Life tray (the phone retired). Its sizes: the tray
/// follows the finger 1:1, stays exactly where it is let go, is put away only
/// when let go near the bottom, never goes under the home indicator or past
/// the top safe area, and reopens at the height it was last left.
struct BuildingLifeTrayTests {
    /// An iPhone 15/16 in portrait: 393 x 852, 59 top, 34 bottom.
    private let m = BuildingLifeTrayMetrics(size: CGSize(width: 393, height: 852), top: 59, bottom: 34)

    @Test func itsRangeRespectsTheSafeAreas() {
        #expect(m.minOpen == 34 + BuildingLifeTrayMetrics.bandHeight)       // collapsed: just the grab band, above the safe area
        #expect(m.maxOpen == 852 - 59 - BuildingLifeTrayMetrics.topGap)      // nearly full screen
        #expect(m.clamped(2000) == m.maxOpen)
        #expect(m.clamped(0) == m.minOpen)
    }

    @Test func itFollowsTheFingerOneToOne() {
        let start: CGFloat = 300
        for dy in [CGFloat(-120), -40, 0, 25, 150] {
            #expect(m.dragged(from: start, dy: dy) == start - dy)
        }
        #expect(m.dragged(from: start, dy: -5000) == m.maxOpen)              // (never past the top)
        #expect(m.dragged(from: start, dy: 5000) == m.minOpen)               // (never under the home indicator)
    }

    @Test func letGoItStaysWhereItIsOrIsPutAwayNearTheBottom() {
        for h in [CGFloat(200), 333.5, 512, m.maxOpen] {
            #expect(m.released(at: h) == h)                                   // no snapping up or down
        }
        #expect(m.released(at: m.minOpen) == nil)
        #expect(m.released(at: m.minOpen + BuildingLifeTrayMetrics.collapseSlack) == nil)
        #expect(m.released(at: m.minOpen + BuildingLifeTrayMetrics.collapseSlack + 1) != nil)
    }

    @Test func itReopensAtTheHeightItWasLastLeft() {
        for h in [CGFloat(180), 420, m.maxOpen] {
            #expect(abs(m.height(forShare: m.share(of: h)) - h) < 0.001)
        }
        // A share saved on one screen still fits another (rotation, a different phone).
        let landscape = BuildingLifeTrayMetrics(size: CGSize(width: 852, height: 393), top: 0, bottom: 21)
        let h = landscape.height(forShare: m.share(of: 500))
        #expect(h >= landscape.minOpen && h <= landscape.maxOpen)
    }

    /// Oct 21 (night): the handle's touch area never reaches into the bottom
    /// safe area (the home-indicator gesture zone), collapsed or open, and the
    /// HUD row (gear, centre button, tool tray) sits above the collapsed edge.
    @MainActor
    @Test func theHandleIsAboveTheHomeIndicatorAndBelowTheHUD() {
        for metrics in [m, BuildingLifeTrayMetrics(size: CGSize(width: 852, height: 393), top: 0, bottom: 21)] {
            for visible in [metrics.minOpen, metrics.minOpen + 100, metrics.maxOpen] {
                let area = metrics.handleArea(visible: visible)
                #expect(area.maxY <= metrics.height - metrics.bottom + 0.001)
                #expect(area.width == metrics.width)                          // (full width)
                #expect(area.height >= 24)
            }
        }
        #expect(ContinuousWalkControls.bottomPadding >= BuildingLifeTrayMetrics.bandHeight)
    }

    /// Oct 21 (later): the tray could be lost under the home indicator. The
    /// bottom it keeps clear is never less than the window's inset (even when its
    /// own edge-to-edge geometry reports none), nor than a minimum.
    @Test func theCollapsedHandleCanAlwaysBeGrabbedAgain() {
        // Its geometry reports no inset; the window says 34: the band sits above 34.
        let bottom = BuildingLifeTrayMetrics.safeBottom(reported: 0, window: 34)
        #expect(bottom == 34)
        let lost = BuildingLifeTrayMetrics(size: CGSize(width: 393, height: 852), top: 59, bottom: bottom)
        #expect(lost.handleArea(visible: lost.minOpen).maxY <= 852 - 34 + 0.001)
        // Neither reports one (a home-button phone, or nothing read yet): still a minimum.
        #expect(BuildingLifeTrayMetrics.safeBottom(reported: 0, window: 0) == BuildingLifeTrayMetrics.minimumBottom)
        #expect(BuildingLifeTrayMetrics(size: CGSize(width: 375, height: 667), top: 0, bottom: 0).bottom
                == BuildingLifeTrayMetrics.minimumBottom)
        // Dragged down as far as a finger can: it stops at the collapsed band, never lower.
        #expect(lost.dragged(from: lost.maxOpen, dy: 10_000) == lost.minOpen)
        // A generous target, full width.
        #expect(BuildingLifeTrayMetrics.bandHeight >= 34)
    }

    @Test func aBadSavedHeightIsReplacedWithTheDefault() {
        #expect(BuildingLifeTrayMetrics.validShare(0) == 0.5)                // (never saved)
        #expect(BuildingLifeTrayMetrics.validShare(.nan) == 0.5)
        #expect(BuildingLifeTrayMetrics.validShare(-3) == 0.5)
        #expect(BuildingLifeTrayMetrics.validShare(0.02) == 0.5)             // (would open as good as closed)
        #expect(BuildingLifeTrayMetrics.validShare(7) == 0.5)
        #expect(BuildingLifeTrayMetrics.validShare(0.7) == 0.7)
    }

    /// Oct 22 (URGENT): with the tray collapsed every bottom control is above its
    /// top edge -- DECORATE (above the gear, wherever the tray's top really is),
    /// the gear, the GO / LEFT / RIGHT row and the tool tray.
    @MainActor
    @Test func bottomControlsClearTheCollapsedTray() {
        for trayTop in [BuildingLifeTrayMetrics.bandHeight, BuildingLifeTrayMetrics.bandHeight + 16, 120] {
            #expect(DecoratorOverlay.decorateBottom(collapsedTrayTop: trayTop) >= trayTop + 8)
        }
        let collapsedTop = BuildingLifeTrayMetrics.bandHeight                         // (34 pt above the safe-area bottom)
        #expect(ContinuousWalkControls.bottomPadding > collapsedTop)                  // the gear and the walk row
        #expect(ToolTrayView.alignedWithGear > collapsedTop)                           // the tool tray
        #expect(DecoratorOverlay.decorateBottom(collapsedTrayTop: collapsedTop) >= ContinuousWalkControls.bottomPadding + 56)
    }
    /// Oct 23 -- the BUILDING button: collapsed on the Settings gear's line, rising
    /// 1:1 with the tray, never under the status bar; let go, it settles open or away.
    /// Oct 24: put away (tray hidden), low in the corner above the home indicator;
    /// out, lifted to ride just above the tray's top edge.
    @MainActor
    @Test func theBuildingButtonRidesWithTheTray() {
        let gearLine = 34 + BuildingLifeTrayMetrics.cornerBottom                     // (the gear's bottom above the screen's bottom)
        let size = BuildingLifeTrayMetrics.buttonSize
        let collapsed = m.buttonTop(visible: m.minOpen, gearLine: gearLine)
        #expect(collapsed == 852 - gearLine - size)                                  // beside the gear, the same line
        #expect(collapsed + size <= 852 - 34)                                         // above the home indicator
        let lift = m.buttonLift(gearLine: gearLine)
        #expect(m.buttonTop(visible: m.minOpen, gearLine: gearLine, lift: lift) + size <= 852 - m.minOpen)   // out: above the tray's top
        let low = m.buttonTop(visible: m.minOpen, gearLine: gearLine, lift: lift)
        let raised = m.buttonTop(visible: m.minOpen + 200, gearLine: gearLine, lift: lift)
        #expect(low - raised == 200)                                                 // 1:1 with the tray
        #expect(m.buttonTop(visible: m.maxOpen, gearLine: gearLine, lift: lift) == 59 + BuildingLifeTrayMetrics.buttonTopMargin)   // reachable, under the status bar
        let mid = (m.minOpen + m.maxOpen) / 2
        #expect(m.snapped(predicted: mid + 1) == m.maxOpen)
        #expect(m.snapped(predicted: mid - 1) == nil)
        #expect(m.snapped(predicted: 5000) == m.maxOpen && m.snapped(predicted: -5000) == nil)
    }
}
