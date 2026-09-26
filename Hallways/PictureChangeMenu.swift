import SwiftUI
import PhotosUI

// Sept 20: the two picker sheets behind the Change Picture menu's
// "Choose Photo…" and "Choose Hallways Art…" actions (ContentView).
// Split into their own file rather than added inline to the already
// very large ContentView.swift, to keep this addition small and
// easy to isolate/revert.

/// "Choose Photo…" -- wraps PHPickerViewController rather than driving
/// PHPhotoLibrary's own authorization/UIImagePickerController flow
/// ourselves: PHPickerViewController is Apple's out-of-process picker,
/// so it needs no photo-library permission prompt of its own, and it
/// hands back a PHPickerResult.assetIdentifier so the chosen photo can
/// be looked up again on every future rebuild (persisted as a
/// PictureImageSelection.cameraRoll(identifier) via
/// PhotoRollProvider.image(forIdentifier:) -- the same lookup "Random
/// Photo" already relies on for its own identifier).
struct SystemPhotoPicker: UIViewControllerRepresentable {
    /// Called once with the chosen asset's local identifier, or nil if
    /// the picker was dismissed without choosing anything.
    var onPick: (String?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (String?) -> Void
        init(onPick: @escaping (String?) -> Void) {
            self.onPick = onPick
        }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onPick(results.first?.assetIdentifier)
        }
    }
}

/// "Choose Hallways Art…" -- a grid of the same bundled images
/// HallwayScene.pictureAssetNames already draws its own random
/// selection from, so tapping one here just gives that one picture an
/// explicit (not random) choice going forward. Same NavigationStack +
/// toolbar shape as PlayerSettingsSheet (PlayerSettings.swift).
struct HallwaysArtPicker: View {
    var onPick: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(HallwayScene.pictureAssetNames, id: \.self) { name in
                        Button {
                            onPick(name)
                            dismiss()
                        } label: {
                            thumbnail(for: name)
                        }
                        .accessibilityLabel("Hallways Art")
                    }
                }
                .padding()
            }
            .navigationTitle("Hallways Art")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onPick(nil)
                        dismiss()
                    }
                }
            }
        }
    }

    // Same 0.6 x 0.85 portrait aspect the in-scene picture frame uses
    // (HallwayScene.framedPhoto), so thumbnails read as a preview of
    // how each one will actually look mounted on the wall.
    @ViewBuilder
    private func thumbnail(for name: String) -> some View {
        let width: CGFloat = 100
        let height: CGFloat = width * 0.85 / 0.6
        if let image = HallwayScene.namedPictureImage(name) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()
                .cornerRadius(6)
        } else {
            Color.gray.opacity(0.3)
                .frame(width: width, height: height)
                .cornerRadius(6)
        }
    }
}


/// Presented the instant the player taps an ordinary framed picture
/// they're standing at and facing (see
/// TapNavigationController.activatePictureMenu) -- same
/// @ObservedObject-holding "OverlayHost" shape every other in-world
/// menu here uses (TicTacToeOverlayHost, ShellGameOverlayHost,
/// PhotoBoothOverlayHost, ...): a plain confirmationDialog attached
/// straight to ContentView's own body, reading
/// navBridge.controller?.activePictureMenu from a Binding, silently
/// never re-presented because ContentView doesn't hold that controller
/// as an @ObservedObject -- only navBridge itself (whose own
/// @Published var controller only refires SwiftUI when the CONTROLLER
/// REFERENCE changes, not when a property inside it mutates). Holding
/// `controller` here as @ObservedObject is what actually subscribes to
/// activePictureMenu's own changes.
///
/// A confirmationDialog/sheet chain needs some real view in the
/// hierarchy to attach to; a zero-size Color.clear (same idea
/// PhotoBoothOverlayHost's own 1x1 opacity-0.01 view uses) keeps this
/// invisible and non-hit-testable while still hosting the
/// presentation.
struct PictureChangeMenuHost: View {
    @ObservedObject var controller: TapNavigationController
    let mazeStore: MazeStore

    // Sept 20 (picture-teleport fix): no scene-resync closure anymore.
    // Every action below only calls mazeStore.setPictureImageSelection()
    // + mazeStore.saveCurrentFloorAsOverride() -- setPictureImageSelection
    // publishes through mazeStore.pictureImageSelections, which
    // HallwaySceneView's Coordinator (an @ObservedObject observer of
    // mazeStore) picks up in its own updateUIView and applies straight
    // to that one picture's retained SCNMaterial in place, the same
    // "swap the material, no scene rebuild" mechanism the theme button
    // already uses. No sceneVersion bump, so HallwaySceneView's `.id()`
    // never changes, the scene/TapNavigationController are never torn
    // down and rebuilt, and the player is never moved.

    @State private var pictureSheetTarget: WallFace?
    @State private var showSystemPhotoPicker = false
    @State private var showHallwaysArtPicker = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            // Exactly the four actions Eddie specified: Random Photo,
            // Choose Photo…, Choose Hallways Art…, Random Hallways Art.
            // Deliberately no Copy/Share/Save/Delete/Crop/Edit. Each
            // action calls mazeStore.saveCurrentFloorAsOverride() itself
            // right after mutating the selection: this menu only ever
            // opens during live gameplay (never inside the grid editor),
            // so GridEditorView's own version-change autosave (which
            // only exists while that view is mounted) never fires for
            // it -- this is the floor-editor-scoped autosave from Goal 1
            // staying exactly that, plus this menu explicitly doing its
            // own save the same way the old manual SAVE button used to.
            .confirmationDialog("Change Picture", isPresented: Binding(
                get: { controller.activePictureMenu != nil },
                set: { isPresented in
                    if !isPresented { controller.cancelPictureMenu() }
                }
            ), titleVisibility: .visible, presenting: controller.activePictureMenu) { face in
                Button("Random Photo") {
                    controller.cancelPictureMenu()
                    PhotoRollProvider.shared.randomImageWithIdentifier(caller: "Change Picture: Random Photo") { identifier, _ in
                        if let identifier {
                            mazeStore.setPictureImageSelection(.cameraRoll(identifier), direction: face.direction, at: face.coord)
                            mazeStore.saveCurrentFloorAsOverride()
                        }
                    }
                }
                Button("Choose Photo…") {
                    controller.cancelPictureMenu()
                    pictureSheetTarget = face
                    showSystemPhotoPicker = true
                }
                Button("Choose Hallways Art…") {
                    controller.cancelPictureMenu()
                    pictureSheetTarget = face
                    showHallwaysArtPicker = true
                }
                Button("Random Hallways Art") {
                    controller.cancelPictureMenu()
                    if let name = HallwayScene.pictureAssetNames.randomElement() {
                        mazeStore.setPictureImageSelection(.builtIn(name), direction: face.direction, at: face.coord)
                        mazeStore.saveCurrentFloorAsOverride()
                    }
                }
                Button("Cancel", role: .cancel) {
                    controller.cancelPictureMenu()
                }
            }
            .sheet(isPresented: $showSystemPhotoPicker) {
                SystemPhotoPicker { identifier in
                    if let identifier, let face = pictureSheetTarget {
                        mazeStore.setPictureImageSelection(.cameraRoll(identifier), direction: face.direction, at: face.coord)
                        mazeStore.saveCurrentFloorAsOverride()
                    }
                    pictureSheetTarget = nil
                }
            }
            .sheet(isPresented: $showHallwaysArtPicker) {
                HallwaysArtPicker { name in
                    if let name, let face = pictureSheetTarget {
                        mazeStore.setPictureImageSelection(.builtIn(name), direction: face.direction, at: face.coord)
                        mazeStore.saveCurrentFloorAsOverride()
                    }
                    pictureSheetTarget = nil
                }
            }
    }
}
