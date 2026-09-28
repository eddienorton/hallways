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
    var filename: String { self == .man ? "walk-man.mp3" : "walk-heigh-heels.mp3" }
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
    @Environment(\.dismiss) private var dismiss
    // Sept 27 (Reset All Floors to Defaults): destructive confirmation
    // gate, same idea as GridEditorView's own Reset Floor alert --
    // only Confirm actually calls into MazeStore.
    @State private var showingResetAllFloorsConfirmation = false
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
