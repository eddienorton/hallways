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
                // Sept 26 ("Keep This Picture"): promotes whatever
                // random pick is CURRENTLY showing into the same
                // persisted, specific state Choose Photo/Choose
                // Hallways Art/Random Photo/Random Hallways Art all
                // already leave behind -- reusing setPictureImageSelection
                // itself rather than a parallel persistence path.
                // Enabled only when this face has no explicit selection
                // yet (mazeStore.pictureImageSelections[face] == nil --
                // an already-selected picture has nothing to promote,
                // Keep would be a no-op) AND mazeStore.currentPictureIdentity
                // actually knows what's showing (populated by
                // HallwayScene.build's reportPictureIdentity closure --
                // absent for the one honest gap this can't safely
                // promote, see that closure's own doc comment).
                // SwiftUI's confirmationDialog has no per-row `.disabled`,
                // so an unavailable Keep is left out of the menu
                // entirely rather than shown disabled.
                if mazeStore.pictureImageSelections[face] == nil, let identity = mazeStore.currentPictureIdentity[face] {
                    Button("Keep This Picture") {
                        controller.cancelPictureMenu()
                        mazeStore.setPictureImageSelection(identity, direction: face.direction, at: face.coord)
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

/// BUG 2 fix (manual-mode elevator Change Picture), Sept 26: presented
/// when the player taps an elevator poster (back or side wall) while
/// riding the elevator with full camera control -- see
/// TapNavigationController.activeElevatorPictureMenu and
/// ContentView's handleTap. Same zero-size "OverlayHost" shape as
/// PictureChangeMenuHost above, reusing its exact same four actions
/// and the exact same SystemPhotoPicker/HallwaysArtPicker sheets, so
/// the supported image sources (Hallways-provided art and camera-roll
/// choices) and the picker UI itself are identical either way.
///
/// The one real difference: an elevator poster has no WallFace/
/// mazeStore identity to route through, and deliberately must not get
/// one -- elevator pictures stay off-limits to Decorator/Designer
/// authoring. Every action below calls
/// controller.applyElevatorPosterImage(_:to:) directly instead of
/// mazeStore.setPictureImageSelection(...): a live, in-place SCNMaterial
/// swap on the poster actually tapped, no mazeStore write, no scene
/// rebuild, no camera change. The chosen image still survives this
/// same ride's own stop/arrival/door-opening for free -- see that
/// method's own doc comment.
struct ElevatorPictureChangeMenuHost: View {
    @ObservedObject var controller: TapNavigationController
    // Sept 26 ("Keep This Picture"): the ONE reason this view now
    // holds a MazeStore reference at all -- every OTHER action here
    // still calls controller.applyElevatorPosterImage(_:to:) directly,
    // exactly as ephemeral/ungoverned by mazeStore as this struct's own
    // doc comment above describes. Reporting a picked identity into
    // mazeStore.currentElevatorBackIdentity/currentElevatorSideIdentity
    // is NOT a persistence write (see those properties' own doc
    // comment on MazeStore) -- it is the same scratch "what's currently
    // showing" bookkeeping HallwayScene.build's own reportElevator...
    // closures do on every floor build, just also updated here so Keep
    // becomes available right after an explicit Play-mode choice, not
    // only after a fresh floor build. The actual persisting write Keep
    // performs below (setElevatorBackArtwork/setElevatorSideArtwork) is
    // the one and only place this view crosses into real,
    // Decorate-shared persistence, and only on the player's own explicit
    // "Keep This Picture" tap.
    let mazeStore: MazeStore

    @State private var pickerTarget: TapNavigationController.ElevatorPosterTarget?
    @State private var showSystemPhotoPicker = false
    @State private var showHallwaysArtPicker = false

    private func reportIdentity(_ selection: PictureImageSelection, for target: TapNavigationController.ElevatorPosterTarget) {
        switch target {
        case .back: mazeStore.reportCurrentElevatorBackIdentity(selection)
        case .side: mazeStore.reportCurrentElevatorSideIdentity(selection)
        case .sideRight: mazeStore.reportCurrentElevatorSideRightIdentity(selection)
        }
    }

    /// Sept 26 ("Keep This Picture"): mirrors PictureChangeMenuHost's
    /// own enable check -- no persisted authored choice yet for this
    /// poster (elevatorCabDecoration.backArtwork/sideArtwork == nil,
    /// the elevator-poster equivalent of pictureImageSelections[face]
    /// == nil) AND a known current identity to promote.
    private func currentIdentity(for target: TapNavigationController.ElevatorPosterTarget) -> PictureImageSelection? {
        switch target {
        case .back:
            guard mazeStore.elevatorCabDecoration.backArtwork == nil else { return nil }
            return mazeStore.currentElevatorBackIdentity
        case .side:
            guard mazeStore.elevatorCabDecoration.sideArtwork == nil else { return nil }
            return mazeStore.currentElevatorSideIdentity
        case .sideRight:
            guard mazeStore.elevatorCabDecoration.sideRightArtwork == nil else { return nil }
            return mazeStore.currentElevatorSideRightIdentity
        }
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .confirmationDialog("Change Picture", isPresented: Binding(
                get: { controller.activeElevatorPictureMenu != nil },
                set: { isPresented in
                    if !isPresented { controller.cancelElevatorPictureMenu() }
                }
            ), titleVisibility: .visible, presenting: controller.activeElevatorPictureMenu) { target in
                Button("Random Photo") {
                    controller.cancelElevatorPictureMenu()
                    PhotoRollProvider.shared.randomImageWithIdentifier(caller: "Elevator Change Picture: Random Photo") { identifier, image in
                        if let image {
                            controller.applyElevatorPosterImage(image, to: target)
                        }
                        if let identifier { reportIdentity(.cameraRoll(identifier), for: target) }
                    }
                }
                Button("Choose Photo…") {
                    controller.cancelElevatorPictureMenu()
                    pickerTarget = target
                    showSystemPhotoPicker = true
                }
                Button("Choose Hallways Art…") {
                    controller.cancelElevatorPictureMenu()
                    pickerTarget = target
                    showHallwaysArtPicker = true
                }
                Button("Random Hallways Art") {
                    controller.cancelElevatorPictureMenu()
                    if let name = HallwayScene.pictureAssetNames.randomElement(), let image = HallwayScene.namedPictureImage(name) {
                        controller.applyElevatorPosterImage(image, to: target)
                        reportIdentity(.builtIn(name), for: target)
                    }
                }
                // Sept 26 ("Keep This Picture"): promotes the poster's
                // CURRENTLY showing image into the same authored,
                // Decorate-shared persistence Decorate mode's own Keep
                // uses -- setElevatorBackArtwork/setElevatorSideArtwork,
                // not a Play-mode-only mechanism. Product intent is that
                // Keep means "stay until I explicitly change it," which
                // is inherently a persistence decision even when pressed
                // from Play mode -- unlike every other action in this
                // menu, which stays exactly as ephemeral as this
                // struct's own doc comment describes.
                if let identity = currentIdentity(for: target) {
                    Button("Keep This Picture") {
                        controller.cancelElevatorPictureMenu()
                        switch target {
                        case .back: mazeStore.setElevatorBackArtwork(identity)
                        case .side: mazeStore.setElevatorSideArtwork(identity)
                        case .sideRight: mazeStore.setElevatorSideRightArtwork(identity)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    controller.cancelElevatorPictureMenu()
                }
            }
            .sheet(isPresented: $showSystemPhotoPicker) {
                SystemPhotoPicker { identifier in
                    if let identifier, let target = pickerTarget {
                        PhotoRollProvider.shared.image(forIdentifier: identifier, caller: "Elevator Change Picture: Choose Photo") { image in
                            if let image {
                                controller.applyElevatorPosterImage(image, to: target)
                            }
                        }
                        reportIdentity(.cameraRoll(identifier), for: target)
                    }
                    pickerTarget = nil
                }
            }
            .sheet(isPresented: $showHallwaysArtPicker) {
                HallwaysArtPicker { name in
                    if let name, let target = pickerTarget, let image = HallwayScene.namedPictureImage(name) {
                        controller.applyElevatorPosterImage(image, to: target)
                        reportIdentity(.builtIn(name), for: target)
                    }
                    pickerTarget = nil
                }
            }
    }
}
