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
    /// Oct 8: Settings > Start Over (ContentView owns the actual reset).
    var onStartOver: () -> Void = {}
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
        .padding(.bottom, BuildingLifeTrayMetrics.cornerBottom)   // Oct 24: low in the corner (was the HUD row's line, Oct 10)
        .sheet(isPresented: $showingSettings) {
            PlayerSettingsSheet(store: store, onStartOver: onStartOver)
                // Oct 9: the game goes quiet while Settings is up (not Mute:
                // the player's Mute setting is untouched) and resumes after.
                .onAppear { HallwaysAudio.shared.setSuppressed(true, reason: "settings") }
                .onDisappear { HallwaysAudio.shared.setSuppressed(false, reason: "settings") }
        }
    }
}

private struct PlayerSettingsSheet: View {
    @ObservedObject var store: MazeStore
    var onStartOver: () -> Void
    // Oct 8 (Start Over): confirmation gate -- only Confirm starts over.
    @State private var showingStartOverConfirmation = false
    @AppStorage(PlayerFeet.preferenceKey) private var selectedFeet = PlayerFeet.man.rawValue
    // Sept 28 (Your Height): see PlayerHeight. ContentView observes the
    // same key and moves the live camera as this changes.
    @AppStorage(PlayerHeight.preferenceKey) private var heightInches = PlayerHeight.defaultInches
    @Environment(\.dismiss) private var dismiss
    // Sept 27 (Reset All Floors to Defaults): destructive confirmation
    // gate, same idea as GridEditorView's own Reset Floor alert --
    // only Confirm actually calls into MazeStore.
    @State private var showingResetAllFloorsConfirmation = false
    /// Oct 12: the Telephone voice audition (developer tools only; temporary).
    @AppStorage(TelephoneVoice.defaultsKey) private var telephoneVoice = TelephoneVoice.original.rawValue
    /// Oct 22 (musical identities): on unless switched off (HallwaysianMusic.isOn).
    @AppStorage(HallwaysianMusic.defaultsKey) private var musicalIdentities = true
    // Oct 24 (mud hunt): the diagnostic audio-off mode (AudioDiagnostics), from the next launch.
    @AppStorage(AudioDiagnostics.audioOffKey) private var audioOffNextLaunch = false
    // Oct 2: Share Diagnostics (see DiagnosticRecorder).
    @State private var diagnosticsShare: DiagnosticsShareItem?
    // Oct 16 (V): the tool presentation audition.
    @ObservedObject private var toolTray = ToolTray.shared
    @State private var toolSwitchRefusal: String?          // Oct 16 (VI): why Two Hands was refused (shown as an alert)
    @State private var preparingDiagnostics = false

    /// (Built here, not inside `body`: the long string expressions there were too much for the type checker.)
    private var markSlowdownFooter: String {
        let base = "Developer: notes this moment in the performance history included in Share Diagnostics."
        let active = PerfSwitches.activeList
        guard !active.isEmpty else { return base }
        return base + " EXPERIMENTS ON: " + active.joined(separator: ", ") + "."
    }

    private var audioOffFooter: String {
        let base = "Turns off Hallways' audio processing entirely -- music, critter sounds, effects -- to help find the slowdown. "
            + "Not the same as the speaker button. Quit and relaunch to apply. "
        return base + (AudioDiagnostics.audioOff ? "Audio is OFF in this run." : "Audio is on in this run.")
    }

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
                        DiagnosticRecorder.shared.snapshot("share")     // Oct 8: the report ends with the state right now
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
                // Oct 21 (slowdown hunt): developer builds only -- a marker in the
                // performance history at the moment the game feels slow.
                if PerfMonitor.enabled {
                    Section {
                        Button("Mark Slowdown Now") {
                            PerfMonitor.shared.mark("user: slow now")
                        }
                        .frame(minHeight: 44)
                    } footer: {
                        Text(markSlowdownFooter)
                    }
                }
                // Oct 24 (mud hunt): audio switched OFF (not muted) for a whole run -- a
                // controlled experiment. Read once at launch: quit and relaunch to apply.
                Section {
                    Toggle("Audio off (next launch)", isOn: $audioOffNextLaunch)
                        .frame(minHeight: 44)
                } header: {
                    Text("DIAGNOSTICS")
                } footer: {
                    Text(audioOffFooter)
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
                // Oct 8 -- START OVER (Debug AND Release): begin again as a
                // new employee. Settings and building decorations are kept
                // (see StartOver).
                Section {
                    Button(role: .destructive) {
                        showingStartOverConfirmation = true
                    } label: {
                        Text("Start Over")
                    }
                    .alert(StartOver.confirmationTitle, isPresented: $showingStartOverConfirmation) {
                        Button("Cancel", role: .cancel) {}
                        Button(StartOver.confirmButtonTitle, role: .destructive) {
                            onStartOver()
                            dismiss()
                        }
                    } message: {
                        Text(StartOver.confirmationMessage)
                    }
                } footer: {
                    Text("Begin again as a new employee, from outside the building.")
                }
                // Oct 8 (Developer/Release separation): Debug workshop only.
                if BuildMode.developerTools {
                Section {
                    Button(role: .destructive) {
                        showingResetAllFloorsConfirmation = true
                    } label: {
                        Text("Reset All Floors to Defaults")
                    }
                } footer: {
                    Text("Replaces every customized floor with the current built-in defaults.")
                }
                // Oct 11: replay the Floor 3 staff meeting for timing passes.
                Section {
                    Button {
                        ConferenceMeeting.debugReplay()
                        dismiss()
                    } label: {
                        Text("Replay Conference Meeting")
                    }
                } footer: {
                    Text("Puts the Floor 3 meeting room back to before the boss calls the meeting to order. Sit down to play it again. Nothing saved changes.")
                }
                // Oct 16 (V): TOOL PRESENTATION (audition; see ToolBelt.Presentation).
                Section {
                    // (refused: the control stays on Tool Tray, and an alert says exactly why)
                    Picker("Show tools as", selection: Binding(
                        get: { toolTray.mode },
                        set: { toolSwitchRefusal = ToolBelt.setPresentation($0) })) {
                        Text("Tool Tray (4)").tag(ToolBelt.Presentation.tray)
                        Text("Two Hands (2)").tag(ToolBelt.Presentation.hands)
                    }
                    .pickerStyle(.segmented)
                    // Oct 16 (VI): what is carried, each with its own Return (home to Supplies, or its bracket).
                    ForEach(toolTray.items, id: \.self) { item in
                        HStack {
                            if let image = ToolIcons.image(item.tool) {
                                Image(uiImage: image).resizable().scaledToFit().frame(width: 30, height: 30)
                            }
                            Text(item.title)
                            Spacer()
                            Button("Return") { ToolBelt.returnFromMenu(item) }
                                .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("Tool Presentation (audition)")
                } footer: {
                    Text(toolTray.mode == .tray && ToolBelt.handsBlockedMessage != nil
                         ? "Carrying \(toolTray.items.count). \(ToolBelt.handsBlockedMessage ?? "")"
                         : "The same tools either way: switching never adds, drops or returns anything.")
                }
                .alert("Two Hands holds two tools", isPresented: Binding(
                    get: { toolSwitchRefusal != nil }, set: { if !$0 { toolSwitchRefusal = nil } })) {
                    Button("OK", role: .cancel) { toolSwitchRefusal = nil }
                } message: {
                    Text(toolSwitchRefusal ?? "")
                }
                // Oct 22 (musical identities): the six Hallwaysians' song names and signatures.
                Section {
                    Toggle("Musical greetings", isOn: $musicalIdentities)
                } header: {
                    Text("Musical Identities (audition)")
                } footer: {
                    Text("Every resident has a short instrumental signature: it greets you with it when you tap to follow, now and then when you're near (one at a time), and checks in every half-minute or so while you follow it. Benny, Cecilia, Jolene, Eileen, Gloria and Layla also wear song names. Off: every original voice and sound at once, no ambient music or check-ins, and the six's original names (Feddy, Sister, Lanky, Stilts, Scope, Lopsy) from the next launch. Compare Music and Original any time in Building Life > Directory.")
                }
                // Oct 12: THE TELEPHONE VOICE AUDITION (temporary; see TelephoneVoice).
                Section {
                    Picker("Voice", selection: $telephoneVoice) {
                        ForEach(TelephoneVoice.allCases) { voice in
                            Text(voice.title).tag(voice.rawValue)
                        }
                    }
                    Button("Play sample") {
                        (TelephoneVoice(rawValue: telephoneVoice) ?? .original).playSample()
                    }
                } header: {
                    Text("Telephone Voice (audition)")
                } footer: {
                    Text("Play sample: the same three presentation lines and a laugh. In the game the chosen voice is used the next time the meeting's cast is brought into the room -- a THE BOX replay into the empty room (tap the screen) or the next visit to Floor 3.")
                }
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
                    guard BuildMode.developerTools else { return }
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
