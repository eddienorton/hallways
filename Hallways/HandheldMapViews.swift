import SwiftUI

/// The gameplay map is separate from the developer's map editor.
struct HandheldMapButton: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    controller.openHandheldMap()
                } label: {
                    Image(systemName: "map")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(!controller.canOpenHandheldMap)
                .accessibilityLabel("Show floor map")
                .accessibilityIdentifier("handheldMapButton")
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 28)
    }
}

struct HandheldMapOverlay: View {
    @ObservedObject var controller: TapNavigationController

    var body: some View {
        if controller.handheldMapVisible {
            ZStack {
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .onTapGesture { controller.closeHandheldMap() }
                VStack(spacing: 14) {
                    Text(controller.floorLabel)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Image(uiImage: controller.currentFloorMapImage())
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 340, maxHeight: 460)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.35), lineWidth: 2))
                        .accessibilityLabel("Floor map with your location and facing, elevator, and mission markers")
                        .onTapGesture { controller.closeHandheldMap() }
                    Button("Close") { controller.closeHandheldMap() }
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 100, minHeight: 48)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .accessibilityIdentifier("closeHandheldMapButton")
                }
                .padding(20)
            }
            .accessibilityAction(.escape) { controller.closeHandheldMap() }
        }
    }
}
