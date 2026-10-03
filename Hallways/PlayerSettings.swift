import SwiftUI
import Combine

enum PlayerFeet: String, CaseIterable, Identifiable {
    case man, highHeels
    static let preferenceKey = "player.feet"
    static var current: PlayerFeet {
        PlayerFeet(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .man
    }
    var id: String { rawValue }
    var title: String { self == .man ? "Man" : "High Heels" }
    var graphic: String { self == .man ? "👞" : "👠" }
    var filename: String { walkingFilename(reverse: false) }
    /// Oct 2: forward and backward footstep loops for these feet.
    func walkingFilename(reverse: Bool) -> String {
        switch (self, reverse) {
        case (.man, false): return "walk-man.mp3"
        case (.man, true): return "walk-man-reverse.mp3"
        case (.highHeels, false): return "walk-high-heels.mp3"
        case (.highHeels, true): return "walk-high-heels-reverse.mp3"
        }
    }
}

/// Sept 28 (Your Height): the player's real-world height, which sets the
/// first-person eye height. User preference data (AppStorage/UserDefaults),
/// never floor data. Stored canonically as whole inches -- the Settings
/// Stepper moves one inch at a time -- and converted to a camera Y with
/// one deliberately simple rule: eye height = height x 0.93.
///
/// This is the ONE authoritative source of the player's eye height:
/// HallwayScene reads `currentEyeHeight` when it creates the gameplay
/// camera, and ContentView pushes changes live into
/// TapNavigationController.setEyeHeight(_:). Nothing else hard-codes the
/// old 1.6 m camera Y.
enum PlayerHeight {
    static let preferenceKey = "player.heightInches"
    static let eyeHeightRatio = 0.93
    static let minimumInches = 48 // 4' 0"
    static let maximumInches = 84 // 7' 0"
    /// 1.60 m (the long-standing camera Y) / 0.93 = 1.720 m = 67.7" --
    /// rounded to the nearest whole inch, 68" (5' 8"), whose eye height
    /// is 1.606 m: today's viewpoint to within 6 mm.
    static let defaultInches = 68

    static func clamped(_ inches: Int) -> Int {
        min(maximumInches, max(minimumInches, inches))
    }

    /// The stored height, or the default when nothing (or something that
    /// isn't a number) was ever saved; out-of-range values are clamped.
    static func inches(in defaults: UserDefaults = .standard) -> Int {
        guard let number = defaults.object(forKey: preferenceKey) as? NSNumber else { return defaultInches }
        let value = number.doubleValue
        guard value.isFinite else { return defaultInches }
        return clamped(Int(value.rounded()))
    }

    static func eyeHeight(forInches inches: Int) -> Float {
        Float(Double(clamped(inches)) * 0.0254 * eyeHeightRatio)
    }

    static var currentEyeHeight: Float { eyeHeight(forInches: inches()) }

    /// "5' 8"" -- the friendly U.S. display the Settings row shows.
    static func displayString(forInches inches: Int) -> String {
        let value = clamped(inches)
        return "\(value / 12)' \(value % 12)\""
    }
}

struct PlayerSettingsButton: View {
    // Sept 27 (Reset All Floors to Defaults): threaded down to
    // PlayerSettingsSheet, the same way GridEditorView already passes
    // its own mazeStore down to the views under it -- this Settings
    // sheet had no store reference before, since PICK YOUR FEET is
    // pure AppStorage.
    @ObservedObject var store: MazeStore
    @State private var showingSettings = false
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Settings")
                Spacer()
            }
        }
        .padding(.leading, 20)
        .padding(.bottom, 28)
        .sheet(isPresented: $showingSettings) { PlayerSettingsSheet(store: store) }
    }
}

private struct PlayerSettingsSheet: View {
    @ObservedObject var store: MazeStore
    @AppStorage(PlayerFeet.preferenceKey) private var selectedFeet = PlayerFeet.man.rawValue
    // Sept 28 (Your Height): see PlayerHeight. ContentView observes the
    // same key and moves the live camera as this changes.
    @AppStorage(PlayerHeight.preferenceKey) private var heightInches = PlayerHeight.defaultInches
    @Environment(\.dismiss) private var dismiss
    // Sept 27 (Reset All Floors to Defaults): destructive confirmation
    // gate, same idea as GridEditorView's own Reset Floor alert --
    // only Confirm actually calls into MazeStore.
    @State private var showingResetAllFloorsConfirmation = false
    // Oct 2: Share Diagnostics (see DiagnosticRecorder).
    @State private var diagnosticsShare: DiagnosticsShareItem?
    @State private var preparingDiagnostics = false
    var body: some View {
        NavigationStack {
            List {
                Section("PICK YOUR FEET") {
                    ForEach(PlayerFeet.allCases) { feet in
                        Button { selectedFeet = feet.rawValue } label: {
                            HStack(spacing: 16) {
                                Text(feet.graphic).font(.largeTitle)
                                Text(feet.title).foregroundStyle(.primary)
                                Spacer()
                                if (PlayerFeet(rawValue: selectedFeet) ?? .man) == feet {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                            .frame(minHeight: 52)
                        }
                        .accessibilityAddTraits((PlayerFeet(rawValue: selectedFeet) ?? .man) == feet ? .isSelected : [])
                    }
                }
                Section("YOUR HEIGHT") {
                    Stepper(value: Binding(
                        get: { PlayerHeight.clamped(heightInches) },
                        set: { heightInches = PlayerHeight.clamped($0) }),
                            in: PlayerHeight.minimumInches...PlayerHeight.maximumInches) {
                        HStack {
                            Text("Your Height")
                            Spacer()
                            Text(PlayerHeight.displayString(forInches: heightInches))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 44)
                }
                Section {
                    Button {
                        guard !preparingDiagnostics else { return }
                        preparingDiagnostics = true
                        diag("diagnostics.shareRequested")
                        DiagnosticRecorder.shared.makeShareSnapshot { url in
                            preparingDiagnostics = false
                            if let url { diagnosticsShare = DiagnosticsShareItem(url: url) }
                        }
                    } label: {
                        HStack {
                            Text("Share Diagnostics")
                            Spacer()
                            if preparingDiagnostics { ProgressView() }
                        }
                    }
                    .frame(minHeight: 44)
                } footer: {
                    Text("Sends Eddie a text log of what the game was doing, to help fix bugs. No photos or personal info.")
                }
                // Sept 27 (Designer/dev workflow): one global command
                // for "DefaultMazes.json changed on another device, and
                // this device still has local floor overrides from
                // before that" -- reuses MazeStore.resetAllFloorsToDefaults(),
                // which itself reuses the existing single-floor RESET
                // architecture rather than a second definition of
                // "default." Destructive role/styling, same visual
                // language as every other destructive row in this app
                // (GridEditorView's own Reset Floor button).
                Section {
                    Button(role: .destructive) {
                        showingResetAllFloorsConfirmation = true
                    } label: {
                        Text("Reset All Floors to Defaults")
                    }
                } footer: {
                    Text("Replaces every customized floor with the current built-in defaults.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $diagnosticsShare) { item in
                ActivityShareSheet(items: [item.url])
                    .ignoresSafeArea()
            }
            .alert("Reset All Floors?", isPresented: $showingResetAllFloorsConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset All Floors", role: .destructive) {
                    store.resetAllFloorsToDefaults()
                }
            } message: {
                Text("This will replace all customized floors with the current built-in defaults. This cannot be undone.")
            }
        }
    }
}

/// Oct 2: the file handed to the iOS share sheet by Share Diagnostics.
private struct DiagnosticsShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Standard iOS share sheet (Mail, Messages, AirDrop, Save to Files...).
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
