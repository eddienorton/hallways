import SwiftUI
import UIKit

/// Layout for the two-state gameplay map (Sept 24 redesign -- the
/// draggable park/raise paper model is gone, replaced by a compact
/// mini-map that taps open into a larger full map).
///
/// SIMPLIFIED GEOMETRY, per Eddie's spec: the whole layout hangs off
/// ONE anchor -- the map's bottom-right corner. It is derived from the
/// persistent "FLOOR N" HUD pill (which ContentView's NavigationOverlay
/// renders with the identical `hudPillToSafeGap` constant), so:
///
///   1. the pill has one fixed rect and never moves;
///   2. the map's bottom-right corner is derived from that pill --
///      "1 above the pill" is true for BOTH states because they share
///      the same corner;
///   3. the mini-map and the full map are the SAME anchored rectangle
///      at two different sizes;
///   4. the zoom is a pure scale about `.bottomTrailing` between those
///      two sizes -- no destination rect, no separate Y math, nothing
///      to interpolate toward. The corner stays nailed to one screen
///      coordinate for every frame.
struct HandheldMapGeometry {
    /// Mini-map footprint -- square, because the floor map is drawn on
    /// GridEditorView's permanent 15x15 building grid.
    static let miniSize: CGFloat = 52
    /// The map's right-side clearance from the phone's rounded corner,
    /// measured past the safe-area inset. This alone fixes the map's
    /// horizontal position (anchor.x). Unchanged from the prior pass.
    static let miniMapRightClearance: CGFloat = 26
    /// The "FLOOR N" pill's own clearance above the safe visible bottom
    /// edge -- NavigationOverlay pads with exactly this value, so the
    /// pill position the map keys off is the pill position that renders.
    static let hudPillToSafeGap: CGFloat = 8
    /// Gap between the bottom of the map (mini OR full) and the top of
    /// the "FLOOR N" pill.
    static let mapToHudPillGap: CGFloat = 8
    /// Height of the "FLOOR N" pill: its 13pt bold text line height
    /// plus the pill's 5pt vertical padding -- derived from the real
    /// font metrics rather than a magic screen number.
    static var hudPillHeight: CGFloat {
        UIFont.systemFont(ofSize: 13, weight: .bold).lineHeight + 10
    }

    let viewport: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat

    /// Full-map image edge. Modestly reduced from the old 320 cap by
    /// ~2 points per cell for the 15-cell grid (the Sept 24 tuning
    /// pass), regardless of which constraint actually binds.
    var imageSize: CGFloat {
        let biggest = min(320, viewport.width - 24, viewport.height - topInset - 80)
        return max(1, biggest - 30)
    }
    /// The full card (no title bar): map only, plus its margins -- the
    /// 12pt bottom margin that replaced the title strip's footprint.
    var paperSize: CGSize { CGSize(width: imageSize + 24, height: imageSize + 12) }
    /// Flexer 1 -- THE ONE FIXED FLOOR-PILL RECT.
    /// Bottom edge 8pt ("hudPillToSafeGap") above the safe visible
    /// bottom. X is handled by NavigationOverlay (centered); this rect
    /// exists to anchor the map's vertical slot.
    var pillRect: CGRect {
        CGRect(x: 0, y: viewport.height - bottomInset - Self.hudPillToSafeGap - Self.hudPillHeight,
               width: viewport.width, height: Self.hudPillHeight)
    }
    /// Anchor 2 -- THE MAP'S BOTTOM-RIGHT CORNER, the single source of
    /// truth for minimized, full and every in-between frame.
    /// Fixed in x by the right clearance, fixed in y at 8pt above the
    /// pill's top. Neither end of the zoom animates toward anywhere
    /// else: this coordinate simply never moves.
    var mapBottomRight: CGPoint {
        CGPoint(x: viewport.width - Self.miniMapRightClearance,
                y: pillRect.minY - Self.mapToHudPillGap)
    }
    /// The mini-map's rect -- bottom-right corner == the anchor.
    var miniRect: CGRect {
        CGRect(x: mapBottomRight.x - Self.miniSize, y: mapBottomRight.y - Self.miniSize,
               width: Self.miniSize, height: Self.miniSize)
    }
    /// The full map's rect -- bottom-right corner == the SAME anchor.
    /// Grows up and left from it, never centered, never higher.
    var fullRect: CGRect {
        CGRect(x: mapBottomRight.x - paperSize.width, y: mapBottomRight.y - paperSize.height,
               width: paperSize.width, height: paperSize.height)
    }
    /// Center points for the two cards' explicit `.position(...)`.
    var miniCenter: CGPoint { CGPoint(x: miniRect.midX, y: miniRect.midY) }
    var fullCenter: CGPoint { CGPoint(x: fullRect.midX, y: fullRect.midY) }
    /// The zoom factor between the two sizes: maps the full card's
    /// width onto the mini-map's width. Because both cards share the
    /// anchored bottom-right corner, scaling the full card by this
    /// about `.bottomTrailing` makes its footprint exactly equal the
    /// mini-map's -- so the mini/full swap has ZERO positional jump.
    var miniScale: CGFloat { Self.miniSize / paperSize.width }
}

/// Gameplay map only; the editor and its gestures are independent.
struct HandheldMapOverlay: View {
    @ObservedObject var controller: TapNavigationController
    @State private var expanded = false

    // Sept 24 (TOUCH/INSPECTION pass): expanded-map inspection zoom. The
    // outer card's geometry is untouched -- only the map CONTENT inside it
    // magnifies (scaleEffect) and pans (offset), clipped by the card's
    // shape. Zoom persists while the full map stays open; closing to the
    // mini-map resets both zoom and pan so the next open starts at a normal
    // 1.0x centered view. mapZoomBase/mapPanBase are the committed values
    // a gesture multiplies/adds onto, so each new pinch/drag continues
    // from the current view instead of resetting it.
    @State private var mapZoom: CGFloat = 1.0
    @State private var mapZoomBase: CGFloat = 1.0
    @State private var mapPan: CGSize = .zero
    @State private var mapPanBase: CGSize = .zero
    private let mapZoomMinScale: CGFloat = 1.0
    private let mapZoomMaxScale: CGFloat = 3.0
    private let paperTone = Color(red: 0.975, green: 0.965, blue: 0.94)

    var body: some View {
        GeometryReader { proxy in
            let geometry = HandheldMapGeometry(viewport: proxy.size,
                                               topInset: proxy.safeAreaInsets.top,
                                               bottomInset: proxy.safeAreaInsets.bottom)
            // Both map states are placed with explicit .position -- never
            // by a ZStack alignment. The outer .frame below defaults to
            // .center alignment, so any child that was instead anchored by
            // container alignment would collapse to its own size and then
            // get re-centered (the Sept 24 fix: the mini-map was dead-center
            // on device while the full map, which already used .position,
            // sat correctly).
            ZStack {
                if expanded {
                    // The full card is PLACED with its bottom-right corner
                    // on the anchor, so a plain ".bottomTrailing" scale is
                    // all the geometry needs: at scale `miniScale` its
                    // footprint is exactly the mini-map's rect, and the
                    // corner never leaves the anchor at any interpolated
                    // scale. The mini card fades beneath it (both occupy
                    // the same footprint at the very first frame), keeping
                    // the swap jump-free -- no destination-rect math at all.
                    fullMapCard(geometry: geometry)
                        .transition(.scale(scale: geometry.miniScale, anchor: .bottomTrailing).combined(with: .opacity))
                        .onTapGesture { collapse() }
                } else {
                    miniMapCard(geometry: geometry)
                        .transition(.opacity)
                        .onTapGesture { expand() }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onChange(of: controller.handheldMapVisible) { _, visible in
                // Any close (this view's tap or an external one, e.g. the
                // editor taking over) resets the inspection zoom/pan -- a
                // reopened map always starts at a normal 1.0x centered view.
                if !visible {
                    mapZoom = 1.0
                    mapZoomBase = 1.0
                    mapPan = .zero
                    mapPanBase = .zero
                }
                expanded = visible
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func expand() {
        guard controller.canOpenHandheldMap else { return }
        // The coordinator cancels its held-walk timer via
        // onHandheldMapOpened inside openHandheldMap; the slide/scale
        // animation must wrap that call here, in the SwiftUI layer
        // (see openHandheldMap's own comment about withAnimation).
        withAnimation(.easeOut(duration: 0.28)) {
            expanded = true
            controller.openHandheldMap()
        }
    }

    private func collapse() {
        // Closing the expanded map resets zoom AND pan so the next open
        // starts normal size (spec: no persistence beyond the current
        // open-map session). Reset inside the animation so the zoom eases
        // back to 1.0x as the card shrinks instead of popping mid-shrink.
        withAnimation(.easeOut(duration: 0.28)) {
            mapZoom = 1.0
            mapZoomBase = 1.0
            mapPan = .zero
            mapPanBase = .zero
            expanded = false
            controller.closeHandheldMap()
        }
    }

    private func miniMapCard(geometry: HandheldMapGeometry) -> some View {
        Image(uiImage: controller.currentFloorMapImage(backgroundOpacity: 0, simplified: true, includeWallObjectIndicators: true))
            .resizable()
            .interpolation(.medium)
            .frame(width: HandheldMapGeometry.miniSize, height: HandheldMapGeometry.miniSize)
            .background(paperTone.opacity(0.90))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.30), radius: 7, x: 0, y: 3)
            .contentShape(Rectangle())
            .position(geometry.miniCenter)
            .accessibilityIdentifier("handheldMiniMap")
            .accessibilityLabel("Floor map showing corridors and your location; tap to enlarge")
            .accessibilityAction(named: "Enlarge map") { expand() }
    }

    private func fullMapCard(geometry: HandheldMapGeometry) -> some View {
        Image(uiImage: controller.currentFloorMapImage(backgroundOpacity: 0, includeWallObjectIndicators: true))
            .resizable()
            .interpolation(.high)
            .frame(width: geometry.imageSize, height: geometry.imageSize)
            // TOUCH/INSPECTION pass: the CARD never moves -- only the map
            // content magnifies (scaleEffect about the image's own center)
            // and pans (offset), both within/over the fixed paper. The
            // card's clipShape further down clips magnified content to the
            // rounded paper, so zoomed-out-of-bounds cells simply hide.
            .scaleEffect(mapZoom)
            .offset(mapPan)
            .background(Color(white: 0.85).opacity(0.45))
            .padding(.bottom, 12)
            .frame(width: geometry.paperSize.width, height: geometry.paperSize.height)
            .background(paperTone.opacity(0.90))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.30), radius: 12, x: 0, y: 4)
            .contentShape(Rectangle())
            .position(geometry.fullCenter)
            .accessibilityIdentifier("handheldMapPaper")
            .accessibilityLabel("Floor map with your location and facing, elevator, and mission markers")
            .accessibilityAction(.escape) { collapse() }
            // Gesture composition (TOUCH/INSPECTION pass): simple tap closes
            // (below), while pinch and drag are simultaneous recognizers that
            // self-select by their own normal conditions -- a two-finger pinch
            // never satisfies the single-finger tap (map can't close by
            // pinching), a movement-free tap never satisfies the drag
            // (genuine taps still close), and a one-finger drag only pans the
            // zoomed content (clamped to zero at 1.0x). No timing hacks.
            .onTapGesture { collapse() }
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        mapZoom = min(max(mapZoomBase * value, mapZoomMinScale), mapZoomMaxScale)
                    }
                    .onEnded { value in
                        commitMapZoom(min(max(mapZoomBase * value, mapZoomMinScale), mapZoomMaxScale), imageSize: geometry.imageSize)
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        applyMapPan(translation: value.translation, imageSize: geometry.imageSize)
                    }
                    .onEnded { value in
                        applyMapPan(translation: value.translation, imageSize: geometry.imageSize)
                        mapPanBase = mapPan
                    }
            )
    }

    /// Pins the committed zoom after a pinch, then re-clamps any existing
    /// pan to the new zoom's travel limits (a smaller zoom allows less pan).
    private func commitMapZoom(_ zoom: CGFloat, imageSize: CGFloat) {
        mapZoomBase = zoom
        mapZoom = zoom
        let limit = mapPanLimit(zoom: zoom, imageSize: imageSize)
        mapPan = CGSize(width: min(max(mapPan.width, -limit), limit),
                        height: min(max(mapPan.height, -limit), limit))
        mapPanBase = mapPan
    }

    /// How far the zoomed map content may be dragged in either axis before
    /// its edge reaches the card's. Zero at 1.0x -- the default centered
    /// view has nothing to pan and panning does nothing.
    private func mapPanLimit(zoom: CGFloat, imageSize: CGFloat) -> CGFloat {
        zoom <= 1.0001 ? 0 : imageSize * (zoom - 1) / 2
    }

    /// Sets mapPan from the current drag, starting from the pan committed
    /// when the drag began (mapPanBase) so successive drags continue rather
    /// than snapping back, and clamped so content can never be lost.
    private func applyMapPan(translation: CGSize, imageSize: CGFloat) {
        let limit = mapPanLimit(zoom: mapZoom, imageSize: imageSize)
        let desired = CGSize(width: mapPanBase.width + translation.width,
                             height: mapPanBase.height + translation.height)
        mapPan = CGSize(width: min(max(desired.width, -limit), limit),
                        height: min(max(desired.height, -limit), limit))
    }
}