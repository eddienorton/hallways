import SwiftUI

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
        .sheet(isPresented: $showingSettings) { PlayerSettingsSheet() }
    }
}

private struct PlayerSettingsSheet: View {
    @AppStorage(PlayerFeet.preferenceKey) private var selectedFeet = PlayerFeet.man.rawValue
    @Environment(\.dismiss) private var dismiss
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
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
