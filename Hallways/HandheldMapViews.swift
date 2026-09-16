import SwiftUI

/// The gameplay map is separate from the developer's map editor.
struct HandheldMapButton: View {
    @ObservedObject var controller: TapNavigationController

    /// Round 7 (Eddie): "MAP BUTTON = toggle map open/closed... the
    /// only intended open/close control." Used to always call
    /// openHandheldMap() -- fine back when the card itself closed on
    /// tap, but now that the card is inert (see HandheldMapOverlay
    /// below), this button is the ONLY way in or out, so it has to
    /// flip both directions. Disabling only blocks OPENING (elevator/
    /// terminal/etc. busy) -- closing must always be possible once the
    /// map is up, so it's never gated behind canOpenHandheldMap (which
    /// doesn't itself know about handheldMapVisible).
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    if controller.handheldMapVisible {
                        controller.closeHandheldMap()
                    } else {
                        controller.openHandheldMap()
                    }
                } label: {
                    Image(systemName: "map")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(!controller.handheldMapVisible && !controller.canOpenHandheldMap)
                .accessibilityLabel(controller.handheldMapVisible ? "Hide floor map" : "Show floor map")
                .accessibilityIdentifier("handheldMapButton")
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 28)
    }
}

struct HandheldMapOverlay: View {
    @ObservedObject var controller: TapNavigationController

    /// Sept 14 (Eddie): "raise a physical map in front of yourself."
    /// controller.handheldMapVisible, currentFloorMapImage() (the same
    /// live, already-updating wall-map texture), floorLabel, and the
    /// open/close calls are all untouched -- this struct only changes
    /// HOW that state is presented. Positioned via a plain,
    /// continuously-animatable .offset(y:) -- 0 when open,
    /// cardHiddenOffset (well below the screen) when closed -- driven
    /// by a single .animation(.easeOut(duration: 0.28), value:
    /// controller.handheldMapVisible) at the bottom of this body, so
    /// the slide stays fast and responds identically whether
    /// HandheldMapButton or a tap on the sheet itself triggered it.
    private var cardHiddenOffset: CGFloat { 1000 }

    /// Round 6/8 (Eddie, on-device): hit-testing is scoped to the
    /// SHEET's own bounds only, never the whole screen. The scrim
    /// (blur+dim) below is .allowsHitTesting(false) -- visible but
    /// inert -- and the positioning wrapper around the sheet carries no
    /// hit-testing of its own (an empty Spacer area isn't hit-testable
    /// by default, so nothing further is needed there; round 8 found
    /// and removed an unnecessary, actively-harmful
    /// .allowsHitTesting(false) that used to sit on that wrapper and
    /// was silently swallowing every touch meant for the sheet -- see
    /// that round's own notes if this file has them). The sheet itself
    /// carries .contentShape(Rectangle()) + .allowsHitTesting(
    /// controller.handheldMapVisible), which is what makes it catch
    /// EVERY touch/drag that starts on it -- so a swipe there can never
    /// leak through to 3D navigation underneath -- plus a plain
    /// .onTapGesture that closes the map. A real drag never fires a tap
    /// gesture (touch-down/up have to land in nearly the same spot), so
    /// panning on the sheet is absorbed without accidentally closing
    /// it. Taps/swipes anywhere outside the sheet's own bounds fall
    /// straight through to the scene below, unchanged.
    ///
    /// Round 2 (Eddie, building-wide 15x15 reset): the map's own
    /// coordinate canvas is now a fixed SQUARE -- HallwayScene.
    /// makeFloorMapTexture draws the full 15x15 building grid on every
    /// floor, not a per-floor occupied-bounds crop (see
    /// TapNavigationController.currentFloorMapImage() /
    /// HallwayScene.build(fromMaze:)) -- so this presentation is
    /// redrawn to match it: a compact, roughly-square sheet instead of
    /// the old tall card tuned for a non-square image, a sharp/small
    /// corner radius and a warm off-white paper tone instead of the
    /// rounded gray UI-card look, and less empty space below the map
    /// before the screen edge. Eddie, explicit: "NOT a road map... NO
    /// FOLDS... NO fold lines... NO accordion-map treatment" -- this
    /// reads as a clean printed floor plan, nothing folded or aged
    /// about it. No new drawing beyond a flat paper tone, a hairline
    /// border, and one restrained drop shadow for a little physical
    /// lift off the scene behind it -- deliberately not over-designed.
    private let paperTone = Color(red: 0.975, green: 0.965, blue: 0.94)
    private let paperCornerRadius: CGFloat = 5
    private let paperSize: CGFloat = 320

    var body: some View {
        ZStack {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                    .opacity(0.45)
                Color.black.opacity(0.12)
            }
            .ignoresSafeArea()
            .opacity(controller.handheldMapVisible ? 1 : 0)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    Text(controller.floorLabel)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.3))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    Image(uiImage: controller.currentFloorMapImage())
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: paperSize, height: paperSize)
                        .padding(.bottom, 12)
                        .accessibilityLabel("Floor map with your location and facing, elevator, and mission markers")
                }
                .frame(width: paperSize + 24)
                .background(paperTone)
                .clipShape(RoundedRectangle(cornerRadius: paperCornerRadius))
                .overlay(RoundedRectangle(cornerRadius: paperCornerRadius).stroke(Color.black.opacity(0.22), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: -2)
                .padding(.bottom, 22)
                .contentShape(Rectangle())
                .onTapGesture { controller.closeHandheldMap() }
                .allowsHitTesting(controller.handheldMapVisible)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .bottom)
            .offset(y: controller.handheldMapVisible ? 0 : cardHiddenOffset)
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.28), value: controller.handheldMapVisible)
        .accessibilityAction(.escape) { controller.closeHandheldMap() }
    }
}
