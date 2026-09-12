import SwiftUI
import SceneKit
import Combine

//
//  DevPatternTester.swift
//  Hallways (Hallways-Texture-Test copy only)
//
//  Eddie, Sept 12: a disposable, DEV-ONLY bundled-pattern tester so he
//  can go outside and try seamless JPG/PNG patterns on walls/floor/
//  ceiling. Explicitly NOT a rebuild of the earlier Photos-import dev
//  lab (DevSurfaceLab/DevImportedTexture) -- no picker, no imported-
//  texture persistence, no donor architecture. This is new, small, and
//  fully isolated:
//    - Never touches WallTheme.swift / WallThemeStore / applyTheme.
//    - Never writes to MazeStore / mazes.json / UserDefaults -- quitting
//      the app forgets every choice made here.
//    - Never resets the maze, player position, money, objects, mission
//      progress, or navigation -- it only ever reassigns a material's
//      diffuse contents, exactly like the existing theme system already
//      does for its own live material swaps.
//    - Never touches scene lighting.
//    - Reapplies ONLY when the (pattern, target, tileSize) triple
//      actually changes (see HallwaySceneView.Coordinator's
//      lastDevPattern guard) -- an ordinary gameplay/UI state change
//      can never trigger a reapply, same guard shape as lastTheme
//      already uses for the real theme system.
//

/// Which surfaces a selected pattern applies to.
enum DevPatternTarget: String, CaseIterable, Identifiable {
    case walls, floor, ceiling, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .walls: return "Walls"
        case .floor: return "Floor"
        case .ceiling: return "Ceiling"
        case .all: return "All Surfaces"
        }
    }
}

/// How many times the pattern repeats across a surface -- bigger
/// repeatCount = more, smaller tiles; 1 = the pattern spans the whole
/// surface once. Same idea as the real theme system's default 2x2
/// wall repeat (see ContentView.Coordinator.repeatTransform), just
/// with more steps since this tool exists specifically to compare
/// tile sizes.
enum DevPatternTileSize: String, CaseIterable, Identifiable {
    case small, medium, large, huge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .huge: return "Huge"
        }
    }
    var repeatCount: Float {
        switch self {
        case .small: return 8
        case .medium: return 4
        case .large: return 2
        case .huge: return 1
        }
    }
}

/// One in-memory cache, keyed by bundle filename (no extension) --
/// Eddie's explicit ask: "cache the bundled pattern images rather than
/// repeatedly loading them from disk." Picking the same pattern again,
/// or just changing target/tile size (which reapplies the same
/// image), never re-reads or re-decodes the file.
enum DevPatternImageCache {
    private static var images: [String: UIImage] = [:]

    static func image(named name: String) -> UIImage? {
        if let cached = images[name] { return cached }
        let candidateExtensions = ["jpg", "jpeg", "png"]
        for ext in candidateExtensions {
            if let path = Bundle.main.path(forResource: name, ofType: ext),
               let image = UIImage(contentsOfFile: path) {
                images[name] = image
                return image
            }
        }
        return nil
    }
}

/// Every bundled dev-pattern file, discovered once by scanning the app
/// bundle for the "DevPattern_" prefix -- so dropping more images into
/// the project's DevPatterns folder (same "just drop it in, no other
/// changes needed" convention the Audio/ folder already uses) is the
/// only step needed to add more; nothing here has to be hand-listed.
enum DevPatternLibrary {
    static let names: [String] = {
        let exts = ["jpg", "jpeg", "png"]
        var found: Set<String> = []
        for ext in exts {
            for path in Bundle.main.paths(forResourcesOfType: ext, inDirectory: nil) {
                let base = (path as NSString).lastPathComponent as NSString
                let name = base.deletingPathExtension
                if name.hasPrefix("DevPattern_") { found.insert(name) }
            }
        }
        return found.sorted()
    }()

    static func displayName(for name: String) -> String {
        name.replacingOccurrences(of: "DevPattern_", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }
}

/// Plain in-memory selection state. Deliberately just an
/// ObservableObject with no persistence anywhere -- see this file's
/// header. nil selectedPattern means "off" -- Coordinator.
/// applyDevPattern(_:...) re-runs the normal theme in that case, so
/// this is fully reversible without restarting the app.
final class DevPatternStore: ObservableObject {
    @Published var selectedPattern: String?
    @Published var target: DevPatternTarget = .walls
    @Published var tileSize: DevPatternTileSize = .medium
}

/// Small floating button, bottom-leading (the existing handheld map
/// button already owns bottom-trailing) -- opens the selector sheet.
/// Self-contained: owns its own sheet presentation state so wiring it
/// into ContentView's ZStack is a one-line add.
struct DevPatternButton: View {
    @ObservedObject var store: DevPatternStore
    @State private var showingSelector = false

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Button {
                    showingSelector = true
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Dev pattern tester")
                .accessibilityIdentifier("devPatternButton")
                Spacer()
            }
        }
        .padding(.leading, 20)
        .padding(.bottom, 28)
        .sheet(isPresented: $showingSelector) {
            DevPatternSelectorSheet(store: store)
        }
    }
}

/// The selector: target + tile size pickers, then a plain list of
/// bundled patterns. Tapping a pattern applies it immediately (same
/// "changes take effect live" feel as the theme cycle button) --
/// there's no separate Apply step because DevPatternStore's own
/// @Published changes ARE the trigger (see Coordinator.updateUIView's
/// guard). Stays open after a tap so patterns/targets/sizes can be
/// compared quickly -- exactly the "go outside and experiment" use
/// case this exists for.
struct DevPatternSelectorSheet: View {
    @ObservedObject var store: DevPatternStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("Apply To") {
                    Picker("Target", selection: $store.target) {
                        ForEach(DevPatternTarget.allCases) { target in
                            Text(target.label).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Tile Size") {
                    Picker("Tile Size", selection: $store.tileSize) {
                        ForEach(DevPatternTileSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Patterns") {
                    Button {
                        store.selectedPattern = nil
                    } label: {
                        HStack {
                            Text("None (restore normal theme)")
                            Spacer()
                            if store.selectedPattern == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    if DevPatternLibrary.names.isEmpty {
                        Text("No bundled patterns found yet — drop DevPattern_*.jpg/png files into the project.")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    } else {
                        ForEach(DevPatternLibrary.names, id: \.self) { name in
                            Button {
                                store.selectedPattern = name
                            } label: {
                                HStack {
                                    Text(DevPatternLibrary.displayName(for: name))
                                    Spacer()
                                    if store.selectedPattern == name {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Dev: Pattern Tester")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
