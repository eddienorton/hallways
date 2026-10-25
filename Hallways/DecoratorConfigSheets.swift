import SwiftUI
import ImageIO
import Combine
import PhotosUI
import CryptoKit

// MARK: - Oct 17 -- the decorating kit (remembered surface selections)
//
// The surfaces last chosen for a cell -- walls, floor, ceiling, each on its
// own -- kept so the next cell can be done in a tap or two. It is ONLY a
// memory of choices: it never changes a cell by itself, and it is shown
// apart from what the current cell actually has. The names are the same
// texture identifiers the cell-surface overrides store (nil there = "Use
// Floor Default"); applying writes through the same override path, as one
// undo step, saved the normal way. Kept across launches (UserDefaults).

struct SurfaceKit: Codable, Equatable {
    enum Choice: Codable, Equatable {
        case floorDefault
        case texture(String)
        /// As a cell override: nil = follow the floor's default.
        var overrideName: String? { if case .texture(let n) = self { return n }; return nil }
    }
    var wall: Choice?
    var floor: Choice?
    var ceiling: Choice?
    /// Which remembered surfaces "Apply" uses (each can be left out).
    var useWall = true
    var useFloor = true
    var useCeiling = true

    subscript(_ s: CellSurfaceKind) -> Choice? {
        get { switch s { case .wall: return wall; case .floor: return floor; case .ceiling: return ceiling } }
        set { switch s { case .wall: wall = newValue; case .floor: floor = newValue; case .ceiling: ceiling = newValue } }
    }
    func uses(_ s: CellSurfaceKind) -> Bool {
        switch s { case .wall: return useWall; case .floor: return useFloor; case .ceiling: return useCeiling }
    }
    mutating func setUses(_ s: CellSurfaceKind, _ on: Bool) {
        switch s { case .wall: useWall = on; case .floor: useFloor = on; case .ceiling: useCeiling = on }
    }
    /// What "Apply" would write: each remembered, included surface and its override value.
    var applicable: [(CellSurfaceKind, String?)] {
        [CellSurfaceKind.wall, .floor, .ceiling].compactMap { s in
            guard uses(s), let c = self[s] else { return nil }
            return (s, c.overrideName)
        }
    }
}

final class SurfaceKitStore: ObservableObject {
    static let shared = SurfaceKitStore()
    nonisolated static let key = "decorator.surfaceKit.v1"
    @Published var kit: SurfaceKit {
        didSet {
            guard kit != oldValue, let data = try? JSONEncoder().encode(kit) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
    private init() {
        kit = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(SurfaceKit.self, from: $0) } ?? SurfaceKit()
    }
    /// A surface choice just applied to a cell: remembered for those surfaces.
    func remember(_ name: String?, for surfaces: [CellSurfaceKind]) {
        var k = kit
        let choice: SurfaceKit.Choice = name.map { SurfaceKit.Choice.texture($0) } ?? .floorDefault
        for s in surfaces { k[s] = choice; k.setUses(s, true) }
        kit = k
    }
    /// A My Photos texture was removed: the kit stops offering it.
    func forget(_ name: String) {
        var k = kit
        for s in [CellSurfaceKind.wall, .floor, .ceiling] where k[s] == .texture(name) { k[s] = nil }
        kit = k
    }
    /// The kit becomes exactly what `coord` has now (all three surfaces).
    func copy(from coord: GridCoordinate, store: MazeStore) {
        var k = kit
        for s in [CellSurfaceKind.wall, .floor, .ceiling] {
            let choice: SurfaceKit.Choice = store.cellSurfaceTexture(s, at: coord).map { SurfaceKit.Choice.texture($0) } ?? .floorDefault
            k[s] = choice
            k.setUses(s, true)
        }
        kit = k
    }
}

// Sept 27 (Decorator Surfaces + Auto Lights config): the config sheets
// behind the "+" menu's "Surfaces" and "Auto Lights" entries. Split into
// their own file the same way PictureChangeMenu.swift already split the
// Picture picker sheets out of DecoratorMode.swift/ContentView.swift --
// keeps these two already very large files' own diffs small.

/// "+" -> Surfaces' first screen: which of Walls/Floor/Ceiling a texture
/// tap in the next screen should apply to. One, two, or all three may be
/// checked; "Choose Surface" is disabled until at least one is.
///
/// isPresented is threaded down (not @Environment(\.dismiss)) because
/// SurfaceTexturePicker below is reached by NavigationLink PUSH inside
/// the SAME sheet, not a second .sheet -- dismiss() from a pushed view
/// only pops back to this screen, it does not close the sheet. Passing
/// the actual @State bool that controls the .sheet(isPresented:) all the
/// way down lets both this screen's Cancel and the picker's Done close
/// the whole sheet directly, unambiguously, from either screen.
/// Oct 18: where the Surfaces editor applies a texture.
enum SurfaceScope: String, CaseIterable, Identifiable {
    case floor = "Entire Floor", area = "Connected Area", cell = "This Cell"
    var id: String { rawValue }
    /// More cells than this asks before filling.
    static let confirmAbove = 30
}

struct DecoratorSurfacesSheet: View {
    @ObservedObject var store: MazeStore
    /// Oct 1 (Surfaces "This Cell"): supplies the current cell and the
    /// cell-override edit.
    @ObservedObject var state: DecoratorState
    @Binding var isPresented: Bool
    /// Oct 18: where a chosen texture goes -- the whole floor's default (the
    /// original behaviour), the connected area you're standing in, or just
    /// your cell. Remembered between openings.
    @AppStorage("decorator.surfaceScope.v1") private var scopeRaw = SurfaceScope.area.rawValue

    @State private var includeWalls = false
    @State private var includeFloor = false
    @State private var includeCeiling = false
    // Oct 17: the decorating kit (remembered choices), and swatches for it.
    @ObservedObject private var kits = SurfaceKitStore.shared
    @State private var swatches = SurfaceThumbnailCache()

    var body: some View {
        NavigationStack {
            Form {
                if let cell = state.cellForSurfaceEditing() {
                    kitSection(cell)
                }
                Section {
                    Toggle("Walls", isOn: $includeWalls)
                    Toggle("Floor", isOn: $includeFloor)
                    Toggle("Ceiling", isOn: $includeCeiling)
                } header: {
                    Text("Apply To")
                } footer: {
                    Text("Choose one, two, or all three, then pick a texture to apply it to every one you checked.")
                }
                let here = state.cellForSurfaceEditing()
                let area = here == nil ? nil : state.connectedAreaForSurfaceEditing()
                // (no cell to stand in -- e.g. inside the elevator: only the whole floor)
                let scope = here == nil ? SurfaceScope.floor : (SurfaceScope(rawValue: scopeRaw) ?? .area)
                Section {
                    Picker("Apply In", selection: $scopeRaw) {
                        ForEach(SurfaceScope.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(here == nil)
                } footer: {
                    switch scope {
                    case .floor:
                        Text("Changes the whole floor's default. Cells with their own setting keep it.")
                    case .area:
                        Text("\(area?.count ?? 0) cell\((area?.count ?? 0) == 1 ? "" : "s") -- everywhere you can reach from here without passing a wall or a doorway. Their own settings for the chosen surfaces are replaced.")
                    case .cell:
                        Text("Only the cell you're standing in changes. \"Use Floor Default\" makes it follow the floor again.")
                    }
                }
                Section {
                    NavigationLink {
                        SurfaceTexturePicker(
                            applyWalls: includeWalls,
                            applyFloor: includeFloor,
                            applyCeiling: includeCeiling,
                            store: store,
                            isPresented: $isPresented,
                            cell: scope == .cell ? here : nil,
                            area: scope == .area ? area : nil,
                            state: state
                        )
                    } label: {
                        Text("Choose Surface")
                    }
                    .disabled(!(includeWalls || includeFloor || includeCeiling))
                }
            }
            .navigationTitle("Surfaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }

    // MARK: Oct 17 -- reuse

    private static let kinds: [(CellSurfaceKind, String)] = [(.wall, "Walls"), (.floor, "Floor"), (.ceiling, "Ceiling")]

    /// A small swatch for an override value (nil = the floor's default).
    @ViewBuilder
    private func swatch(_ name: String?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if let name, let image = swatches.thumbnail(for: name, maxPixelSize: 96) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(name == nil ? "Floor\nDefault" : "?").font(.system(size: 9, weight: .semibold)).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .background(Color(white: 0.9))
        .clipShape(shape)
        .overlay(shape.stroke(Color.secondary.opacity(0.4), lineWidth: 1))
    }

    @ViewBuilder
    private func kitSection(_ cell: GridCoordinate) -> some View {
        Section {
            // What this cell actually has now -- never changed by opening this.
            HStack(spacing: 10) {
                Text("This cell now").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                ForEach(Self.kinds, id: \.1) { item in
                    VStack(spacing: 2) {
                        swatch(store.cellSurfaceTexture(item.0, at: cell))
                        Text(item.1).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            // The remembered choices, each included or not.
            ForEach(Self.kinds, id: \.1) { item in
                if let choice = kits.kit[item.0] {
                    Toggle(isOn: Binding(get: { kits.kit.uses(item.0) }, set: { on in kits.kit.setUses(item.0, on) })) {
                        HStack(spacing: 10) {
                            swatch(choice.overrideName)
                            Text(item.1)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        swatch(nil).opacity(0.25)
                        Text("\(item.1): nothing remembered yet").foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                if state.applySurfaceKit(at: cell) { isPresented = false }
            } label: {
                Label("Apply to This Cell", systemImage: "paintbrush.fill")
            }
            .disabled(!state.surfaceKitWouldChange(cell))
            // Oct 17: clears this cell's own wall/floor/ceiling overrides (nil = the
            // floor's default, so it keeps following later default changes) -- the
            // same path as "Use Floor Default": one Undo step, saved, live. The
            // remembered kit and its switches are left alone; the sheet stays open
            // so "This cell now" shows the result.
            Button {
                state.setCellSurfaces(nil, for: CellSurfaceKind.allCases, at: cell)
                diag("decorator.cellSurfacesReset", ["row": cell.row, "col": cell.col])
            } label: {
                Label("Reset This Cell to Floor Defaults", systemImage: "arrow.uturn.backward")
            }
            .disabled(CellSurfaceKind.allCases.allSatisfy { store.cellSurfaceTexture($0, at: cell) == nil })
            Button {
                kits.copy(from: cell, store: store)
            } label: {
                Label("Copy This Cell's Surfaces", systemImage: "eyedropper")
            }
        } header: {
            Text("Reuse")
        } footer: {
            Text("Your last surface choices are remembered. Apply them here (switch any off to leave that surface alone), or copy this cell's surfaces to use elsewhere. Tip: \"+\" \u{2192} \"Apply Surface Kit\" does it without opening this.")
        }
    }
}

/// Sept 27 (physical-test fix, Problem 1 -- Surfaces picker memory):
/// a tiny, VIEW-SCOPED thumbnail cache. It exists only as long as one
/// SurfaceTexturePicker instance does (held in that view's own @State),
/// so dismissing the picker deallocates it -- and every decoded
/// thumbnail bitmap in it -- with no eviction policy needed.
///
/// Deliberately does NOT call HallwayScene.resolveThemeImage: that
/// function's UIImage(contentsOfFile:) decodes the source at its
/// FULL resolution (several bundled textures are ~1920x1920, ~14+MB
/// once decoded as RGBA), which is exactly what a grid showing 90+ of
/// them at once -- regardless of the on-screen swatch being only
/// 100pt -- turned into the physical EXC_RESOURCE/RESOURCE_TYPE_MEMORY
/// termination during testing. resizable().frame() only changes
/// DISPLAY size; it does nothing to how many pixels got decoded.
/// downsampledThumbnail below uses ImageIO's thumbnail-generation
/// entry point instead, which decodes straight to a small bitmap and
/// never creates the source's full-resolution pixel buffer at all.
/// The SceneKit material path (resolveThemeImage, called from
/// applyTheme/makeSurfaceMaterial) is completely untouched by this --
/// walls/floor/ceiling still load at full quality, same as always.
final class SurfaceThumbnailCache {
    private var cache: [String: UIImage] = [:]

    /// Downsampled, cached decode of one hallway texture, capped at
    /// maxPixelSize on its longest side. Cached by name alone (every
    /// current caller passes the same maxPixelSize; keying by
    /// name+size would be a one-line change if that ever stops being
    /// true) -- a plain dictionary, not NSCache, because this whole
    /// object's lifetime already bounds it (see this class's own doc
    /// comment above).
    func thumbnail(for name: String, maxPixelSize: CGFloat) -> UIImage? {
        if let cached = cache[name] { return cached }
        guard let image = Self.downsampledThumbnail(named: name, maxPixelSize: maxPixelSize) else { return nil }
        cache[name] = image
        return image
    }

    /// The standard ImageIO downsample-on-decode recipe: creating the
    /// CGImageSource with kCGImageSourceShouldCache=false keeps IT from
    /// retaining a full decode, and asking for a thumbnail with
    /// kCGImageSourceCreateThumbnailFromImageAlways=true (needed since
    /// none of these bundled files carry an embedded EXIF thumbnail)
    /// makes ImageIO decode directly to a bitmap no larger than
    /// maxPixelSize -- never materializing the source's native
    /// resolution in memory at all.
    private static func downsampledThumbnail(named name: String, maxPixelSize: CGFloat) -> UIImage? {
        guard let url = locateHallwayTextureURL(name) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgThumbnail)
    }

    /// Same hallway-subdirectory-then-flat-bundle-root lookup order
    /// HallwayScene.resolveThemeImage itself uses -- but hands back
    /// the file URL instead of a decoded image, since this cache does
    /// its OWN downsampled decode from that URL and must never forward
    /// to resolveThemeImage's full-resolution one.
    private static func locateHallwayTextureURL(_ name: String) -> URL? {
        if let mine = MyTextures.storedURL(name) { return mine }                 // Oct 17: My Photos
        let subdirectory = "hallway"
        for ext in ["jpg", "png", "jpeg", "webp"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
        }
        for ext in ["jpg", "png", "jpeg", "webp"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}

/// The visual texture browser -- adapted from HallwaysArtPicker
/// (PictureChangeMenu.swift)'s exact grid shape, for hallway surface
/// textures instead of wall pictures: same LazyVGrid(.adaptive), same
/// button-per-thumbnail construction. Differences from that picker,
/// all straight from Eddie's spec: (1) a leading "Default" tile
/// mapping to nil through the exact same MazeStore setters the Floor
/// Editor's own Wall/Floor/Ceiling pickers already use for "no
/// override" -- same Default, same effective-surface resolution, no
/// parallel concept; (2) Sept 27 (single-tap picker UX): this picker
/// is fundamentally single-selection, so tapping a texture APPLIES IT
/// IMMEDIATELY and immediately closes the whole sheet -- no
/// checkmark-then-Done step. (Superseding an earlier version of this
/// comment/behavior that kept the sheet open after a tap for "rapid
/// visual auditioning" -- Eddie, later: "one tap = choose + apply +
/// close.") The remaining toolbar action is Cancel, which dismisses
/// WITHOUT applying anything; (3) Sept 27 (physical-test fix, Problem
/// 2): the currently-applied choice is shown selected (border +
/// checkmark) when the picker FIRST opens, computed once from
/// whichever of Walls/Floor/Ceiling are checked -- there is no
/// lingering "selected" mode after a tap, since the sheet closes right
/// away.
struct SurfaceTexturePicker: View {
    let applyWalls: Bool
    let applyFloor: Bool
    let applyCeiling: Bool
    @ObservedObject var store: MazeStore
    @Binding var isPresented: Bool
    /// Oct 1 (Surfaces "This Cell"): nil = whole floor (unchanged); a coord
    /// = that cell's overrides, and the Default tile reads "Use Floor Default".
    let cell: GridCoordinate?
    /// Oct 18 (Connected-Area fill): non-nil = every cell of this area (the
    /// checked surfaces' overrides), as one edit.
    let area: Set<GridCoordinate>?
    let state: DecoratorState?
    @Environment(\.dismiss) private var dismiss
    /// Oct 18: a big area fill waiting for "Fill N Cells" (the chosen texture; nil = Default).
    @State private var areaConfirm: AreaChoice?
    private struct AreaChoice: Identifiable {
        let id = UUID()
        let name: String?
    }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]
    private let swatchSize: CGFloat = 100

    /// Sept 27 (Problem 2, selected-state feedback): mirrors either a
    /// specific texture name or the Default choice. nil means "no
    /// single tile is authoritative right now" (the checked targets'
    /// current selections disagree) -- never "nothing has been picked
    /// yet," since Default itself is a represented state.
    private enum SurfaceSelectionState: Equatable {
        case texture(String)
        case defaultTexture
    }

    // Sept 27 (Problem 1 fix): view-scoped, see SurfaceThumbnailCache's
    // own doc comment above for why this is the right lifetime for it.
    @State private var thumbnailCache = SurfaceThumbnailCache()
    @State private var selectedTexture: SurfaceSelectionState?
    // Oct 17 (My Photos)
    @ObservedObject private var myTextures = MyTextureLibrary.shared
    @State private var photoItem: PhotosPickerItem?
    @State private var cropJob: TextureCropJob?
    @State private var importing = false
    @State private var importError: String?
    /// Oct 17 (deletion rules): a photo cleared for deletion (confirm), or why one can't be.
    @State private var removal: String?
    @State private var removalUndoNote = false
    @State private var blockedMessage: String?
    @State private var blockedTitle = "This Photo Is in Use"
    /// Oct 17: photos the building names but this device doesn't have, and the one being replaced.
    @State private var missing: [String] = []
    @State private var replacing: String?
    @State private var showReplacePicker = false
    @State private var replaceItem: PhotosPickerItem?
    /// A saved crop to apply once the crop screen has fully closed (or why it failed).
    @State private var pendingApply: String?
    @State private var pendingError: String?

    init(applyWalls: Bool, applyFloor: Bool, applyCeiling: Bool, store: MazeStore, isPresented: Binding<Bool>,
         cell: GridCoordinate? = nil, area: Set<GridCoordinate>? = nil, state: DecoratorState? = nil) {
        self.applyWalls = applyWalls
        self.applyFloor = applyFloor
        self.applyCeiling = applyCeiling
        self.store = store
        self._isPresented = isPresented
        self.cell = cell
        self.area = area
        self.state = state
        self._selectedTexture = State(initialValue: Self.initialSelection(applyWalls: applyWalls, applyFloor: applyFloor, applyCeiling: applyCeiling, store: store, cell: cell, area: area))
    }

    /// Oct 1: the checked targets as cell-surface kinds.
    static func surfaces(walls: Bool, floor: Bool, ceiling: Bool) -> [CellSurfaceKind] {
        (walls ? [.wall] : []) + (floor ? [.floor] : []) + (ceiling ? [.ceiling] : [])
    }

    /// Oct 1: the ONE apply path for both scopes. cell == nil is exactly the
    /// pre-existing whole-floor behavior; a cell writes only the checked
    /// targets' overrides for that cell (nil = Use Floor Default removes them).
    static func applyChoice(_ name: String?, walls: Bool, floor: Bool, ceiling: Bool,
                            cell: GridCoordinate?, area: Set<GridCoordinate>? = nil, store: MazeStore, state: DecoratorState?) {
        if let area {                                                   // Oct 18: the whole connected area, one edit
            let kinds = surfaces(walls: walls, floor: floor, ceiling: ceiling)
            state?.setAreaSurfaces(name, for: kinds, cells: area)
            SurfaceKitStore.shared.remember(name, for: kinds)
            return
        }
        if let cell {
            let kinds = surfaces(walls: walls, floor: floor, ceiling: ceiling)
            state?.setCellSurfaces(name, for: kinds, at: cell)
            SurfaceKitStore.shared.remember(name, for: kinds)          // Oct 17: for the next cell
            return
        }
        if walls { store.setWallTexture(name) }
        if floor { store.setFloorTexture(name) }
        if ceiling { store.setCeilingTexture(name) }
        store.saveCurrentFloorAsOverride()
    }

    /// Sept 27 (mixed Walls/Floor/Ceiling initial state): reads
    /// store.wallTexture/floorTexture/ceilingTexture -- the exact same
    /// properties every setter below writes -- for only the CHECKED
    /// targets, and pre-selects a tile only when every one of them
    /// currently agrees: all the same explicit texture -> that
    /// texture; all nil -> Default; anything mixed -> nothing
    /// pre-selected, per Eddie's spec exactly.
    private static func initialSelection(applyWalls: Bool, applyFloor: Bool, applyCeiling: Bool, store: MazeStore, cell: GridCoordinate? = nil,
                                         area: Set<GridCoordinate>? = nil) -> SurfaceSelectionState? {
        var values: [String?] = []
        if let area {                                                   // Oct 18: every cell of the area, every checked surface
            let kinds = surfaces(walls: applyWalls, floor: applyFloor, ceiling: applyCeiling)
            values = area.flatMap { c in kinds.map { store.cellSurfaceTexture($0, at: c) } }
        } else if let cell {
            values = surfaces(walls: applyWalls, floor: applyFloor, ceiling: applyCeiling).map { store.cellSurfaceTexture($0, at: cell) }
        } else {
            if applyWalls { values.append(store.wallTexture) }
            if applyFloor { values.append(store.floorTexture) }
            if applyCeiling { values.append(store.ceilingTexture) }
        }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first.map { .texture($0) } ?? .defaultTexture
    }

    // Sept 27 (live surface-update fix): setWallTexture/setFloorTexture/
    // setCeilingTexture are the EXACT same MazeStore setters the Floor
    // Editor's "Floor Surfaces" sheet already calls on Save -- no
    // parallel persistence, same guard-same-value/version-bump/Default-
    // is-nil behavior. What's new is that nothing here waits for a
    // sheet dismiss or a scene rebuild: ContentView's Coordinator now
    // diffs these three properties on every updateUIView pass (see its
    // applyTheme doc comment) and reapplies materials in place the
    // instant they change, the same "swap the retained material's
    // contents, no rebuild" mechanism the theme button has always used
    // -- so this fires live, keeps the player exactly where they are,
    // and touches no navigation/mission state.
    private func apply(_ name: String?, confirmed: Bool = false) {
        // Oct 18 (Connected-Area fill): one edit for the whole area -- asked first
        // when it's big -- then back to Surfaces (not closed), so the next surface
        // is a toggle and a tap away.
        if let area {
            if area.count > SurfaceScope.confirmAbove, !confirmed {
                areaConfirm = AreaChoice(name: name)
                return
            }
            areaConfirm = nil
            Self.applyChoice(name, walls: applyWalls, floor: applyFloor, ceiling: applyCeiling, cell: nil, area: area, store: store, state: state)
            selectedTexture = name.map { .texture($0) } ?? .defaultTexture
            dismiss()
            return
        }
        // Sept 27 (single-tap picker UX): the picker is fundamentally
        // single-selection, so a tap is the commitment -- apply then
        // close immediately, no separate Done step. isPresented is the
        // SAME @State bool that controls the outer sheet (see this
        // file's own doc comment on SurfaceTexturePicker above), so
        // setting it false here closes the whole Surfaces sheet, not
        // just this pushed screen.
        Self.applyChoice(name, walls: applyWalls, floor: applyFloor, ceiling: applyCeiling, cell: cell, store: store, state: state)
        selectedTexture = name.map { .texture($0) } ?? .defaultTexture
        isPresented = false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Oct 17: My Photos -- import (and crop) a picture, or reuse one.
                Text("My Photos").font(.headline)
                LazyVGrid(columns: columns, spacing: 12) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        importTile
                    }
                    .disabled(importing)
                    .accessibilityLabel("Import a photo")
                    // Oct 17: a photo the building uses whose file isn't on this device --
                    // tap to supply a picture for it (every surface using it gets it back).
                    ForEach(missing, id: \.self) { name in
                        Button {
                            replacing = name
                            showReplacePicker = true
                        } label: {
                            missingTile
                        }
                        .disabled(importing)
                        .accessibilityLabel("Missing photo -- replace it")
                    }
                    ForEach(myTextures.ids, id: \.self) { name in
                        Button {
                            apply(name)
                        } label: {
                            thumbnail(for: name, selected: selectedTexture == .texture(name))
                        }
                        // Oct 17 (long-press fix): the menu always has its item. An EMPTY
                        // context menu (it used to be empty for a photo shipped inside the
                        // app) means SwiftUI attaches no menu at all -- and the long-press
                        // then ends as a plain tap on the Button, applying the photo.
                        // requestRemoval explains when a photo can't be deleted.
                        .contextMenu {
                            Button(role: .destructive) {
                                requestRemoval(name)
                            } label: { Label("Remove from My Photos", systemImage: "trash") }
                        }
                        .accessibilityLabel("My photo")
                    }
                }
                Text("Built-in").font(.headline).padding(.top, 6)
                LazyVGrid(columns: columns, spacing: 12) {
                    Button {
                        apply(nil)
                    } label: {
                        defaultTile(selected: selectedTexture == .defaultTexture)
                    }
                    .accessibilityLabel(cell == nil && area == nil ? "Default" : "Use Floor Default")

                    ForEach(HallwayScene.availableHallwayTextureNames().filter { !MyTextures.isUserTexture($0) }, id: \.self) { name in
                        Button {
                            apply(name)
                        } label: {
                            thumbnail(for: name, selected: selectedTexture == .texture(name))
                        }
                        .accessibilityLabel(Text(name))
                    }
                }
            }
            .padding()
        }
        .onChange(of: photoItem) { _, item in
            if item != nil { replacing = nil }            // (an ordinary import, not a replacement)
            importPhoto(item)
        }
        .onChange(of: replaceItem) { _, item in importPhoto(item) }
        .photosPicker(isPresented: $showReplacePicker, selection: $replaceItem, matching: .images)
        .onAppear {
            MyPhotoUsage.settleRetired(store: store)      // (legacy Retired folder, once)
            findMissing()
        }
        .fullScreenCover(item: $cropJob, onDismiss: {
            // (only now -- the crop screen fully gone -- apply it, or say what went wrong)
            if let name = pendingApply { pendingApply = nil; apply(name) }
            if let message = pendingError { pendingError = nil; importError = message }
        }) { job in
            TextureCropView(image: job.image, saving: importing, onCancel: { replacing = nil; cropJob = nil }, onSave: { rect, seamless in saveCrop(job.image, rect, seamless) })
        }
        .alert("Couldn't Use That Picture", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("Delete This Photo?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Delete", role: .destructive) {
                if let name = removal { deleteUnused(name) }
                removal = nil
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("It isn't used anywhere in the building. It will be removed from My Photos and deleted from this iPhone."
                 + (removalUndoNote ? " Undo steps on this floor that used it will be cleared." : ""))
        }
        .alert(blockedTitle, isPresented: Binding(get: { blockedMessage != nil }, set: { if !$0 { blockedMessage = nil } })) {
            Button("OK", role: .cancel) { blockedMessage = nil }
        } message: {
            Text(blockedMessage ?? "")
        }
        .navigationTitle(area != nil ? "Choose Surface — Connected Area" : cell == nil ? "Choose Surface" : "Choose Surface — This Cell")
        .alert("Fill \(area?.count ?? 0) Cells?", isPresented: Binding(get: { areaConfirm != nil }, set: { if !$0 { areaConfirm = nil } })) {
            Button("Fill \(area?.count ?? 0) Cells") { [choice = areaConfirm] in
                if let choice { apply(choice.name, confirmed: true) }   // (captured now: the alert may clear areaConfirm first)
            }
            Button("Cancel", role: .cancel) { areaConfirm = nil }
        } message: {
            Text("Every cell you can reach from here without passing a wall or a doorway. One Undo puts them all back.")
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Sept 27 (single-tap picker UX): this is no longer a
            // "make a selection, then confirm" control -- every tile
            // tap above already applies and closes immediately, so the
            // only thing this toolbar button can do is close WITHOUT
            // applying anything, i.e. Cancel, not Done.
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { isPresented = false }
            }
        }
    }

    private func defaultTile(selected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.25))
            Text(cell == nil && area == nil ? "Default" : "Use Floor Default")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: swatchSize, height: swatchSize)
        .overlay(selectionOverlay(selected))
    }

    // MARK: Oct 17 -- My Photos

    private var importTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15))
            if importing {
                ProgressView()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 26))
                    Text("Import Photo").font(.caption)
                }
                .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: swatchSize, height: swatchSize)
    }

    /// In use anywhere that matters -> refuse and say where; otherwise confirm.
    private func requestRemoval(_ name: String) {
        let r = MyPhotoUsage.report(for: name, store: store)
        guard myTextures.canRemove(name) else {
            // Shipped inside the app (the project's textures folder): nothing on
            // this iPhone to delete.
            var text = "This photo is built into Hallways (it's in the project's textures folder), so it can't be deleted here."
            if !r.building.isEmpty {
                text += "\n\nIt's used on:\n" + r.building.prefix(10).map { "\u{2022} \($0)" }.joined(separator: "\n")
                    + (r.building.count > 10 ? "\n\u{2026}and \(r.building.count - 10) more" : "")
            }
            blockedTitle = "Built Into the App"
            blockedMessage = text
            diag("myPhotos.deleteBlocked", ["id": name, "shipped": true, "uses": r.building.count])
            return
        }
        blockedTitle = "This Photo Is in Use"
        if r.isNeeded {
            blockedMessage = MyPhotoUsage.blockedMessage(r)
            diag("myPhotos.deleteBlocked", ["id": name, "uses": r.building.count, "startOver": r.startOver.count, "checkFailed": r.checkFailed])
        } else {
            removalUndoNote = r.inUndo
            removal = name
        }
    }

    /// Checked again at the moment of deleting; then the JPEG is really deleted.
    private func deleteUnused(_ name: String) {
        let r = MyPhotoUsage.report(for: name, store: store)
        guard !r.isNeeded else {
            blockedTitle = "This Photo Is in Use"
            blockedMessage = MyPhotoUsage.blockedMessage(r)
            return
        }
        let droppedUndo = store.dropUndoHistory(mentioning: name)     // (so Undo can't bring it back)
        MyTextures.remove(name)
        SurfaceKitStore.shared.forget(name)
        HallwayScene.forgetThemeImage(name)
        myTextures.reload()
        diag("myPhotos.deleted", ["id": name, "undoStepsDropped": droppedUndo])
    }

    private var missingTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.18))
            RoundedRectangle(cornerRadius: 6).stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22))
                Text("Missing\nTap to replace").font(.caption2).multilineTextAlignment(.center)
            }
            .foregroundStyle(Color.orange)
        }
        .frame(width: swatchSize, height: swatchSize)
    }

    /// Photos the building names that this device has nowhere (collection,
    /// retired, or shipped in the app).
    private func findMissing() {
        guard let json = store.exportLibraryJSON() else { return }
        missing = MyTextures.references(in: json).filter { MyTextures.storedURL($0) == nil && MyTextures.bundledURL($0) == nil }
        if !missing.isEmpty { diag("myPhotos.missing", ["ids": missing.joined(separator: ","), "device": MyTextures.inventory()]) }
    }

    /// The chosen picture, decoded small and upright (off the main thread), then to the crop screen.
    private func importPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        importing = true
        Task {
            defer {
                importing = false
                photoItem = nil
                replaceItem = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    importError = "That picture couldn't be read."
                    return
                }
                let image = await Task.detached(priority: .userInitiated) {
                    MyTextures.downsample(data, maxSide: MyTextures.importPixels)
                }.value
                guard let image else {
                    importError = "That picture couldn't be opened."
                    return
                }
                cropJob = TextureCropJob(image: image)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    /// The crop made into a texture (off the main thread), kept, and applied like any other.
    /// Oct 17: `seamless` -- the Make Seamless version of exactly this crop, when that's
    /// the one chosen; it is saved instead (same JPEG settings, same naming).
    private func saveCrop(_ image: UIImage, _ rect: CGRect, _ seamless: UIImage?) {
        guard !importing else { return }
        importing = true                                  // (the crop screen shows it's saving)
        let target = replacing                            // (replacing a missing photo: keep its name)
        replacing = nil
        Task {
            let id = await Task.detached(priority: .userInitiated) { () -> String? in
                let encoded: Data?
                if let seamless {
                    encoded = seamless.jpegData(compressionQuality: MyTextures.jpegQuality)
                } else {
                    encoded = MyTextures.renderJPEG(image, crop: rect)
                }
                guard let data = encoded else { return nil }
                if let target {
                    do { try MyTextures.save(jpeg: data, as: target); return target } catch { return nil }
                }
                return try? MyTextures.save(jpeg: data)
            }.value
            if let target, id == target {
                HallwayScene.forgetThemeImage(target)
                missing.removeAll { $0 == target }
                diag("myPhotos.replacedMissing", ["id": target])
            }
            importing = false
            if let id {
                myTextures.reload()
                diag("myPhotos.imported", ["id": id])
                // (a replacement restores the surfaces already using it; the selected surface is left alone)
                if id != target { pendingApply = id }
            } else {
                pendingError = "The picture couldn't be saved."
            }
            cropJob = nil                                 // (then onDismiss applies it)
        }
    }

    // Same "existing catalog, no filenames shown" reuse as
    // HallwaysArtPicker's own thumbnail(for:) -- just backed by
    // thumbnailCache's downsampled decode instead of a full-resolution
    // one (see SurfaceThumbnailCache's doc comment: this is the
    // Problem 1 fix). Square, not HallwaysArtPicker's 0.6x0.85
    // picture-frame aspect -- these are tileable surface swatches, not
    // framed photos. maxPixelSize is swatchSize's own point size times
    // 3, matching a 3x/Pro-display device exactly -- plenty sharp on
    // 2x devices too, and still trivially small (a few hundred KB) next
    // to a full-resolution decode.
    @ViewBuilder
    private func thumbnail(for name: String, selected: Bool) -> some View {
        if let image = thumbnailCache.thumbnail(for: name, maxPixelSize: swatchSize * 3) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: swatchSize, height: swatchSize)
                .clipped()
                .cornerRadius(6)
                .overlay(selectionOverlay(selected))
        } else {
            Color.gray.opacity(0.3)
                .frame(width: swatchSize, height: swatchSize)
                .cornerRadius(6)
                .overlay(selectionOverlay(selected))
        }
    }

    /// Sept 27 (Problem 2): a visible border plus a checkmark badge --
    /// both, not just one, for clarity since filenames intentionally
    /// aren't shown. Purely a function of the Equatable
    /// SurfaceSelectionState comparisons done at each call site above;
    /// nothing here re-derives anything from MazeStore.
    @ViewBuilder
    private func selectionOverlay(_ selected: Bool) -> some View {
        if selected {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 3)
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.system(size: 22))
                    .shadow(radius: 1)
                    .padding(4)
            }
        }
    }
}

/// "+" -> Auto Lights' config sheet -- Spacing + Brightness + Generate,
/// deliberately nothing else (no randomization, fixture styles, color
/// temperature, offsets, directions, or edge controls, per Eddie's
/// explicit "for now this should remain SPACING + BRIGHTNESS + GENERATE"
/// instruction). Defaults reproduce today's exact prior behavior
/// (spacing 4, brightness 10) if Generate is tapped without touching
/// either control.
struct AutoLightsConfigSheet: View {
    @ObservedObject var state: DecoratorState
    @Environment(\.dismiss) private var dismiss

    @State private var spacing: Int = 4
    @State private var brightness: Int = 10

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Spacing", selection: $spacing) {
                        Text("Every 2 cells").tag(2)
                        Text("Every 3 cells").tag(3)
                        Text("Every 4 cells").tag(4)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Spacing")
                } footer: {
                    // Exact semantics, verified in code (autoLightsCurrentFloor's
                    // hallwayWalkOrder loop): a fixture lands every Nth cell in a
                    // stable walk of this floor's open cells, starting with the
                    // very first cell of each connected area -- so "Every 4
                    // cells" means exactly 3 unlit cells between fixtures, not 4.
                    Text("A fixture is placed every \(spacing) cells along the hallway.")
                }
                Section {
                    Stepper("Brightness: \(brightness)", value: $brightness, in: 0...12)
                } header: {
                    Text("Brightness")
                } footer: {
                    Text("Applies to every fixture this generates (valid range 0–12).")
                }
                Section {
                    Button("Generate Auto Lights") {
                        state.autoLightsCurrentFloor(spacing: spacing, brightness: brightness)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Auto Lights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}


/// Sept 27 (door cosmetics pass): the selected Room Entrance's
/// "Texture" control -- same overall shape as SurfaceTexturePicker
/// above (LazyVGrid, a leading Default tile, checkmark+border
/// feedback) scoped to the ONE selected door instead of Walls/Floor/
/// Ceiling. Sept 27 (single-tap picker UX): a tile tap applies AND
/// immediately closes this sheet -- no separate Done step; the
/// remaining toolbar action is Cancel, which closes without applying
/// anything. Reuses the SAME
/// SurfaceThumbnailCache downsampled-decode path -- Eddie, Sept 27:
/// "DO NOT introduce another full-resolution thumbnail grid." Applying
/// goes through DecoratorState.setRoomEntranceDoorTexture, which
/// persists AND rebuilds this one door's live leaf node in place (see
/// its own doc comment in DecoratorMode.swift) -- no floor rebuild, no
/// player movement, no camera reset. Presented directly as a .sheet
/// (not pushed via NavigationLink like SurfaceTexturePicker is), so
/// unlike that one this wraps itself in its own NavigationStack.
struct RoomEntranceDoorTexturePicker: View {
    @ObservedObject var state: DecoratorState
    @Binding var isPresented: Bool

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]
    private let swatchSize: CGFloat = 100

    @State private var thumbnailCache = SurfaceThumbnailCache()
    @State private var selectedTexture: String?
    @State private var isDefaultSelected: Bool

    init(state: DecoratorState, isPresented: Binding<Bool>) {
        self.state = state
        self._isPresented = isPresented
        let current = state.currentRoomEntranceDoorTexture()
        self._selectedTexture = State(initialValue: current)
        self._isDefaultSelected = State(initialValue: current == nil)
    }

    private func apply(_ name: String?) {
        // Sept 27 (single-tap picker UX): same "tap is the commitment"
        // change as SurfaceTexturePicker.apply above -- apply then
        // close this sheet immediately, no separate Done step.
        state.setRoomEntranceDoorTexture(name)
        selectedTexture = name
        isDefaultSelected = name == nil
        isPresented = false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    Button {
                        apply(nil)
                    } label: {
                        defaultTile(selected: isDefaultSelected)
                    }
                    .accessibilityLabel("Default")

                    ForEach(HallwayScene.availableHallwayTextureNames(), id: \.self) { name in
                        Button {
                            apply(name)
                        } label: {
                            thumbnail(for: name, selected: !isDefaultSelected && selectedTexture == name)
                        }
                        .accessibilityLabel(Text(name))
                    }
                }
                .padding()
            }
            .navigationTitle("Door Texture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Sept 27 (single-tap picker UX): same reasoning as
                // SurfaceTexturePicker's own toolbar above -- every
                // tile tap already applies and closes, so this can
                // only close WITHOUT applying, i.e. Cancel.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }

    private func defaultTile(selected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.25))
            Text("Default")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: swatchSize, height: swatchSize)
        .overlay(selectionOverlay(selected))
    }

    @ViewBuilder
    private func thumbnail(for name: String, selected: Bool) -> some View {
        if let image = thumbnailCache.thumbnail(for: name, maxPixelSize: swatchSize * 3) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: swatchSize, height: swatchSize)
                .clipped()
                .cornerRadius(6)
                .overlay(selectionOverlay(selected))
        } else {
            Color.gray.opacity(0.3)
                .frame(width: swatchSize, height: swatchSize)
                .cornerRadius(6)
                .overlay(selectionOverlay(selected))
        }
    }

    @ViewBuilder
    private func selectionOverlay(_ selected: Bool) -> some View {
        if selected {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 3)
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.system(size: 22))
                    .shadow(radius: 1)
                    .padding(4)
            }
        }
    }
}

// MARK: - Oct 17 -- MY PHOTOS: the player's own surface textures
//
// Any picture from the photo library (PhotosPicker: no library permission
// needed -- only the chosen picture is handed over), cropped, kept, and used
// exactly like a built-in texture. A texture's identifier IS its name
// everywhere a built-in's name goes -- floor/cell surface overrides, the
// Surface Kit, undo, saves, exports: "mytex-" + 16 hex digits of its JPEG's
// content hash (so the same crop imported twice is one texture). The file is
// Documents/MyTextures/<id>.jpg; HallwayScene.resolveThemeImage loads and
// caches it like any other texture, and a missing file falls back to the
// surface's plain colour (never a broken material). An exported copy dropped
// into the project's hallway texture folder (Hallways-Assets/textures/hallway)
// makes the same name resolve from the app bundle -- the bundled default
// building keeps its photos.

/// Files only -- safe from any thread (imports decode and save off the main one).
nonisolated enum MyTextures {
    static let prefix = "mytex-"
    /// Saved textures are at most this many pixels on their longest side.
    static let maxPixels: CGFloat = 1024
    /// Pictures arrive decoded no larger than this (cropping works on it).
    static let importPixels: CGFloat = 2048

    static func isUserTexture(_ name: String) -> Bool { name.hasPrefix(prefix) }

    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("MyTextures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func fileURL(_ id: String) -> URL { folder.appendingPathComponent(id).appendingPathExtension("jpg") }
    /// LEGACY (Oct 17 build only): where "Remove" used to hide photos the building
    /// still used. Nothing new goes here; MyPhotoUsage.settleRetired() moves each
    /// one back (if anything needs it) or deletes it, then removes the folder.
    /// Never created by reading it.
    static var retiredFolder: URL { folder.appendingPathComponent("Retired", isDirectory: true) }
    static func retiredURL(_ id: String) -> URL { retiredFolder.appendingPathComponent(id).appendingPathExtension("jpg") }
    /// The player's own copy, if this name is one and it's on disk (in the
    /// collection -- or, until it's settled, the legacy Retired folder).
    static func storedURL(_ id: String) -> URL? {
        guard isUserTexture(id) else { return nil }
        for url in [fileURL(id), retiredURL(id)] where FileManager.default.fileExists(atPath: url.path) { return url }
        return nil
    }
    /// A copy shipped inside the app (an exported photo added to the project).
    static func bundledURL(_ id: String) -> URL? {
        guard isUserTexture(id) else { return nil }
        return Bundle.main.url(forResource: id, withExtension: "jpg", subdirectory: "hallway")
            ?? Bundle.main.url(forResource: id, withExtension: "jpg")              // (in case the build flattens the folder)
    }

    /// The collection, newest first.
    static func all() -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        let items = urls.filter { $0.pathExtension == "jpg" && $0.lastPathComponent.hasPrefix(prefix) }
            .map { url -> (id: String, date: Date) in
                (url.deletingPathExtension().lastPathComponent,
                 (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
            }
        return items.sorted { $0.date > $1.date }.map(\.id)
    }

    /// Keep a texture; its identifier comes from its content (same picture, same id).
    static func save(jpeg data: Data) throws -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let id = prefix + String(digest.prefix(16))
        let url = fileURL(id)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        return id
    }

    /// Permanently deletes this photo's JPEG (and any legacy retired copy).
    /// Callers check MyPhotoUsage first -- this does not.
    static func remove(_ id: String) {
        guard isUserTexture(id) else { return }
        try? FileManager.default.removeItem(at: fileURL(id))
        try? FileManager.default.removeItem(at: retiredURL(id))
    }

    // MARK: Legacy Retired folder (settled by MyPhotoUsage.settleRetired)

    static func retiredIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: retiredFolder.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) }.sorted()
    }
    /// Back into the collection. If the collection already has this name, that
    /// copy is the one everything loads (storedURL checks it first), so the
    /// retired duplicate goes. Returns false if the move failed (file left alone).
    @discardableResult
    static func restoreRetired(_ id: String) -> Bool {
        let from = retiredURL(id), to = fileURL(id)
        if FileManager.default.fileExists(atPath: to.path) {
            try? FileManager.default.removeItem(at: from)
            return true
        }
        do { try FileManager.default.moveItem(at: from, to: to); return true } catch { return false }
    }
    static func discardRetired(_ id: String) {
        try? FileManager.default.removeItem(at: retiredURL(id))
    }
    static func removeRetiredFolderIfEmpty() {
        let dir = retiredFolder
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" }
        if left.isEmpty { try? FileManager.default.removeItem(at: dir) }
    }

    /// Oct 17 (recovery): a picture stored under an existing name -- a building
    /// that names a photo whose file is gone gets its picture back, with no
    /// decoration touched. Always in the collection (any legacy retired copy goes).
    static func save(jpeg data: Data, as id: String) throws {
        guard isUserTexture(id) else { return }
        try data.write(to: fileURL(id), options: .atomic)
        try? FileManager.default.removeItem(at: retiredURL(id))
    }

    /// For diagnostics: what is actually on this device.
    static func inventory() -> String {
        func names(_ dir: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
        }
        return "collection=[\(names(folder).joined(separator: ","))] retired=[\(names(retiredFolder).joined(separator: ","))]"
    }

    /// Every My Photos name a building's JSON mentions.
    static func references(in json: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "mytex-[0-9a-f]{16}") else { return [] }
        let ns = json as NSString
        let found = re.matches(in: json, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        return Array(Set(found)).sorted()
    }

    /// A library picture, decoded straight down to at most `maxSide` pixels and
    /// turned upright (its orientation applied) -- never a full-size decode.
    static func downsample(_ data: Data, maxSide: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    static let jpegQuality: CGFloat = 0.88

    /// The cropped picture (pixel rect of an upright image), at most maxPixels, as JPEG.
    static func renderJPEG(_ image: UIImage, crop: CGRect) -> Data? {
        renderCrop(image, crop: crop)?.jpegData(compressionQuality: jpegQuality)
    }

    /// The cropped picture itself, at most maxPixels (Oct 17: shared by Save and
    /// Make Seamless, so both versions come from exactly the same pixels).
    static func renderCrop(_ image: UIImage, crop: CGRect) -> UIImage? {
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        let k = min(1, maxPixels / max(crop.width, crop.height))
        let size = CGSize(width: max(1, (crop.width * k).rounded()), height: max(1, (crop.height * k).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(x: -crop.minX * k, y: -crop.minY * k, width: image.size.width * k, height: image.size.height * k))
        }
    }
}

/// Oct 17 (My Photos deletion rules): where a photo is needed. A photo the
/// building needs can't be deleted; one nothing needs is deleted for real.
///
/// "Needed" means any of:
///   - the CURRENT building (every floor, as exported -- MazeStore.exportLibraryJSON
///     saves the floor being edited first): floor-wide wall/floor/ceiling,
///     cell surface overrides, room entrance door textures;
///   - the bundled DefaultMazes.json, which Start Over / Reset Floor rebuild
///     from -- but only when the app doesn't ship its own copy of the photo.
/// This floor's Undo history is not a use (Undo isn't the building): deleting
/// drops the Undo steps that could put the photo back.
/// Any doubt (a building that can't be read, or a mention in a field not
/// listed above) counts as needed.
enum MyPhotoUsage {
    struct Report {
        var building: [String] = []
        var startOver: [String] = []
        var checkFailed = false
        var inUndo = false
        var isNeeded: Bool { checkFailed || !building.isEmpty || !startOver.isEmpty }
    }

    /// Readable places `id` is used in one building JSON; nil if it can't be read.
    /// (Decoding lives in MazeStore.swift, where the floor record type is.)
    static func places(of id: String, inLibraryJSON data: Data) -> [String]? {
        MazeStore.texturePlaces(id, inLibraryJSON: data)
    }

    static func report(for id: String, store: MazeStore) -> Report {
        var report = Report()
        if let data = store.exportLibraryJSON()?.data(using: .utf8), let found = places(of: id, inLibraryJSON: data) {
            report.building = found
        } else {
            report.checkFailed = true
        }
        if MyTextures.bundledURL(id) == nil,
           let url = Bundle.main.url(forResource: "DefaultMazes", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            if let found = places(of: id, inLibraryJSON: data) { report.startOver = found } else { report.checkFailed = true }
        }
        report.inUndo = store.undoHistoryMentions(id)
        return report
    }

    /// The "can't delete" explanation.
    static func blockedMessage(_ r: Report) -> String {
        func bullets(_ list: [String]) -> String {
            let shown = list.prefix(10).map { "\u{2022} \($0)" }
            return (shown + (list.count > 10 ? ["\u{2026}and \(list.count - 10) more"] : [])).joined(separator: "\n")
        }
        var parts: [String] = []
        if r.building.count == 1 {
            parts.append("This photo is used on \(r.building[0]). Replace it there before deleting it.")
        } else if r.building.count > 1 {
            parts.append("This photo is used in \(r.building.count) places. Replace it in each before deleting it:\n\(bullets(r.building))")
        }
        if !r.startOver.isEmpty {
            parts.append("The app's built-in building (DefaultMazes.json \u{2014} what Start Over and Reset Floor rebuild from) also uses it, and the app has no copy of its own:\n\(bullets(r.startOver))\nDeleting it would leave those surfaces blank after a reset.")
        }
        if r.checkFailed {
            parts.append("Hallways couldn't read the building to check where this photo is used, so it wasn't deleted.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// One-time cleanup of the legacy Retired folder: each photo there goes back
    /// into My Photos if anything (building, Start Over building, or this floor's
    /// Undo) could need it, otherwise it's deleted. No surface is touched.
    static func settleRetired(store: MazeStore) {
        let ids = MyTextures.retiredIDs()
        for id in ids {
            let r = report(for: id, store: store)
            if r.isNeeded || r.inUndo {
                let ok = MyTextures.restoreRetired(id)
                diag("myPhotos.retiredRestored", ["id": id, "ok": ok, "uses": r.building.count + r.startOver.count, "undo": r.inUndo])
            } else {
                MyTextures.discardRetired(id)
                HallwayScene.forgetThemeImage(id)
                diag("myPhotos.retiredDeleted", ["id": id])
            }
        }
        MyTextures.removeRetiredFolderIfEmpty()
        if !ids.isEmpty { MyTextureLibrary.shared.reload() }
    }
}

/// The collection, for the pickers (refreshed after an import or a removal).
final class MyTextureLibrary: ObservableObject {
    static let shared = MyTextureLibrary()
    /// This device's own, newest first, then any shipped inside the app
    /// (exported photos added to the project).
    @Published private(set) var ids: [String] = MyTextureLibrary.collect()
    func reload() { ids = Self.collect() }
    private static func collect() -> [String] {
        let mine = MyTextures.all()
        let shipped = HallwayScene.availableHallwayTextureNames().filter { MyTextures.isUserTexture($0) && !mine.contains($0) }
        return mine + shipped
    }
    /// Only the device's own copies can be removed (a shipped one is part of the app).
    func canRemove(_ id: String) -> Bool { MyTextures.storedURL(id) != nil }
}

/// A picture waiting to be cropped.
struct TextureCropJob: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Crop a picture into a texture: Square (for repeating) or its Original
/// shape; pinch to zoom, drag to place; the white frame is exactly what is
/// kept, and the preview shows the result (square: as it repeats, 2 x 2).
/// The library photo itself is never touched -- this works on a copy.
struct TextureCropView: View {
    let image: UIImage                       // upright, at most MyTextures.importPixels
    var saving = false
    let onCancel: () -> Void
    /// The crop, in the image's pixels -- plus its Make Seamless version when that's
    /// the one showing (nil = save the crop as it is).
    let onSave: (CGRect, UIImage?) -> Void

    enum CropShape: String, CaseIterable, Identifiable {
        case square = "Square", original = "Original"
        var id: String { rawValue }
    }
    @State private var shape: CropShape = .square
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    /// How far the picture is moved, in its own pixels (+x shows more of its left).
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    /// Oct 17 (Make Seamless): the processed version of exactly one crop rect. Any
    /// change to the crop drops it (and any result still being made for an old one).
    @State private var seamless: (rect: CGRect, image: UIImage)?
    @State private var showSeamless = false
    @State private var processing = false
    @State private var seamlessFailed = false
    @State private var seamlessJob = 0

    /// The seamless picture, only while it's chosen AND made from the crop as it is now.
    private var seamlessShown: UIImage? {
        guard shape == .square, showSeamless, let s = seamless, s.rect == cropRect else { return nil }
        return s.image
    }

    private var iw: CGFloat { max(1, image.size.width) }
    private var ih: CGFloat { max(1, image.size.height) }
    /// The kept area's size in the picture's pixels.
    private var cropSize: CGSize {
        switch shape {
        case .square: let side = min(iw, ih) / zoom; return CGSize(width: side, height: side)
        case .original: return CGSize(width: iw / zoom, height: ih / zoom)
        }
    }
    private func clamped(_ p: CGSize) -> CGSize {
        let mx = max(0, (iw - cropSize.width) / 2), my = max(0, (ih - cropSize.height) / 2)
        return CGSize(width: min(mx, max(-mx, p.width)), height: min(my, max(-my, p.height)))
    }
    private var cropRect: CGRect {
        CGRect(x: iw / 2 - pan.width - cropSize.width / 2, y: ih / 2 - pan.height - cropSize.height / 2,
               width: cropSize.width, height: cropSize.height)
    }

    /// Where the whole picture lands in a space `size` across whose middle shows
    /// the crop at `k` points per picture pixel (the one placement both views use).
    private func pictureRect(in size: CGSize, k: CGFloat) -> CGRect {
        let w = iw * k, h = ih * k
        return CGRect(x: size.width / 2 - w / 2 + pan.width * k, y: size.height / 2 - h / 2 + pan.height * k, width: w, height: h)
    }

    /// The picture as seen through a window `size` points across showing exactly the crop.
    /// (Oct 17: drawn into a canvas of the window's own size -- never an oversized view.)
    private func window(_ size: CGSize) -> some View {
        let k = size.width / cropSize.width
        let rect = pictureRect(in: size, k: k)
        let shown = seamlessShown
        return Canvas { ctx, _ in
            if let shown {
                ctx.draw(Image(uiImage: shown), in: CGRect(origin: .zero, size: size))
            } else {
                ctx.draw(Image(uiImage: image), in: rect)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                GeometryReader { geo in
                    let avail = CGSize(width: max(1, geo.size.width - 32), height: max(1, geo.size.height - 32))
                    let aspect = cropSize.width / cropSize.height
                    let frame = aspect >= avail.width / max(1, avail.height)
                        ? CGSize(width: avail.width, height: avail.width / aspect)
                        : CGSize(width: avail.height * aspect, height: avail.height)
                    let k = frame.width / cropSize.width                      // points per picture pixel
                    let cropBox = CGRect(x: (geo.size.width - frame.width) / 2, y: (geo.size.height - frame.height) / 2,
                                         width: frame.width, height: frame.height)
                    let pictureBox = pictureRect(in: geo.size, k: k)
                    let shown = seamlessShown
                    // Oct 17 (artifact fix): picture, dimming and frame drawn together into ONE
                    // screen-sized canvas. (The picture used to be a view as big as the zoom made
                    // it -- thousands of pixels -- which the system draws in tiles; mid-pinch some
                    // tiles kept an old position under the dimming: the dark rectangles.)
                    Canvas { ctx, size in
                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                        ctx.draw(Image(uiImage: image), in: pictureBox)
                        if let shown { ctx.draw(Image(uiImage: shown), in: cropBox) }   // (Seamless chosen)
                        // Outside the kept area only: dimmed.
                        var outside = Path()
                        outside.addRect(CGRect(origin: .zero, size: size))
                        outside.addRect(cropBox)
                        ctx.fill(outside, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))
                        ctx.stroke(Path(cropBox), with: .color(.white), lineWidth: 2)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(DragGesture()
                        .onChanged { v in
                            pan = clamped(CGSize(width: panBase.width + v.translation.width / k, height: panBase.height + v.translation.height / k))
                        }
                        .onEnded { _ in panBase = pan })
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { v in
                            zoom = min(8, max(1, zoomBase * v.magnification))
                            pan = clamped(pan)
                        }
                        .onEnded { _ in
                            zoomBase = zoom
                            panBase = pan
                        })
                }
                HStack(alignment: .center, spacing: 16) {
                    VStack(spacing: 4) {
                        if shape == .square {
                            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                                GridRow { window(CGSize(width: 44, height: 44)); window(CGSize(width: 44, height: 44)) }
                                GridRow { window(CGSize(width: 44, height: 44)); window(CGSize(width: 44, height: 44)) }
                            }
                        } else {
                            window(CGSize(width: 88, height: 88 * cropSize.height / cropSize.width))
                        }
                        Text(shape == .square ? "Repeating" : "Result").font(.caption2).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Shape", selection: $shape) {
                            ForEach(CropShape.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Button("Reset") { reset() }
                        if shape == .square { seamlessControl }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .background(Color.black.ignoresSafeArea())                 // (opaque: nothing behind shows through)
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel).disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { onSave(cropRect, seamlessShown) }.bold().disabled(processing) }
                }
            }
            .onChange(of: shape) { _, _ in
                reset()
                invalidateSeamless()
            }
            .onChange(of: cropRect) { _, _ in invalidateSeamless() }   // (zoom, pan, shape, Reset)
        }
    }

    // MARK: Oct 17 -- Make Seamless

    @ViewBuilder
    private var seamlessControl: some View {
        if seamless != nil {
            Picker("Version", selection: $showSeamless) {
                Text("Original").tag(false)
                Text("Seamless").tag(true)
            }
            .pickerStyle(.segmented)
        } else if processing {
            HStack(spacing: 8) {
                ProgressView()
                Text("Making seamless\u{2026}").font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Button {
                makeSeamless()
            } label: {
                Label("Make Seamless", systemImage: "square.grid.2x2")
            }
            .disabled(saving)
            if seamlessFailed {
                Text("This crop couldn't be made seamless.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Off the main thread, from exactly the pixels Save would keep for this crop.
    private func makeSeamless() {
        guard shape == .square, !processing else { return }
        let rect = cropRect, picture = image
        seamlessJob += 1
        let token = seamlessJob
        processing = true
        seamlessFailed = false
        Task {
            let started = Date()
            let result = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let crop = MyTextures.renderCrop(picture, crop: rect) else { return nil }
                return SeamlessTexture.make(crop)
            }.value
            guard token == seamlessJob else { return }            // (the crop changed meanwhile: dropped)
            processing = false
            if let result {
                seamless = (rect, result)
                showSeamless = true
            } else {
                seamlessFailed = true
            }
            diag("myPhotos.seamless", ["ok": result != nil, "ms": Int(Date().timeIntervalSince(started) * 1000),
                                       "side": Int(result?.size.width ?? 0)])
        }
    }

    /// The crop changed: the old result no longer matches it.
    private func invalidateSeamless() {
        guard seamless != nil || processing || seamlessFailed else { return }
        seamless = nil
        showSeamless = false
        processing = false
        seamlessFailed = false
        seamlessJob += 1
    }

    private func reset() {
        zoom = 1; zoomBase = 1
        pan = .zero; panBase = .zero
    }
}

// MARK: - Oct 17: Make Seamless

/// Turns a square crop into a texture that repeats without visible seams -- on
/// the device, deterministic, nothing blurred: every join is a cut between two
/// real copies of the photo, placed where they already look alike.
///
///  1. Lighting flattened: a smooth (quadratic) brightness surface per channel is
///     divided out, so a phone photo's light falloff doesn't repeat as stripes.
///  2. The tile starts as the photo wrapped by half ("A"): its outer edges are the
///     photo's own continuous interior, so the tile's edges and corners always join.
///  3. A's seam cross through the middle is covered by copies that are continuous
///     there -- the photo wrapped vertically only ("B") on a vertical band, wrapped
///     horizontally only ("C") on a horizontal band, and the photo itself ("D") on a
///     centre box -- each joined along a minimum-difference path (colour plus edge
///     direction, so cuts prefer to follow mortar lines and grain), feathered over
///     a couple of pixels. B and C are continuous across the tile's wrap too, so the
///     bands reach the edges without making new seams.
/// Prototyped and checked in numpy on concrete, gravel, brick, stone, wood, carpet,
/// tiles and a high-contrast photo before this port (same parameters, same zones,
/// same tie-breaking). Strong regular structure (big bricks/blocks) can still show
/// an odd join -- the Original is always kept as the alternative.
nonisolated enum SeamlessTexture {
    /// Smaller crops don't leave room for the bands.
    static let minSide = 96

    /// The seamless version of a square picture (same size), or nil.
    static func make(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage, cg.width == cg.height, cg.width >= minSide else { return nil }
        let n = cg.width
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        let own = cg.colorSpace?.model == .rgb ? cg.colorSpace : nil
        guard let ctx = own.flatMap({ bitmap(n, $0) }) ?? srgb.flatMap({ bitmap(n, $0) }) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let bytes = data.bindMemory(to: UInt8.self, capacity: bpr * n)

        let count = n * n * 3
        let u = UnsafeMutablePointer<Float>.allocate(capacity: count)       // the photo
        let r = UnsafeMutablePointer<Float>.allocate(capacity: count)       // the tile
        defer {
            u.deallocate()
            r.deallocate()
        }
        for y in 0..<n {
            for x in 0..<n {
                let s = y * bpr + x * 4, d = (y * n + x) * 3
                u[d] = Float(bytes[s]) / 255
                u[d + 1] = Float(bytes[s + 1]) / 255
                u[d + 2] = Float(bytes[s + 2]) / 255
            }
        }

        flatten(u, n)
        build(r, u, n)

        for y in 0..<n {
            for x in 0..<n {
                let s = y * bpr + x * 4, d = (y * n + x) * 3
                for k in 0..<3 {
                    bytes[s + k] = UInt8(min(Float(255), max(Float(0), (r[d + k] * 255).rounded())))
                }
                bytes[s + 3] = 255
            }
        }
        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out, scale: 1, orientation: .up)
    }

    private static func bitmap(_ n: Int, _ space: CGColorSpace) -> CGContext? {
        CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    // MARK: Lighting

    /// Divides out a least-squares quadratic surface (1, x, y, x^2, y^2, xy) per
    /// channel, keeping the channel's average. Fitted on every `step`th pixel.
    private static func flatten(_ u: UnsafeMutablePointer<Float>, _ n: Int) {
        let step = max(2, n / 256)
        let scale = 2 / Double(n - 1)
        var b = [Double](repeating: 0, count: 6)
        func fill(_ x: Int, _ y: Int) {
            let fx = Double(x) * scale - 1, fy = Double(y) * scale - 1
            b[0] = 1; b[1] = fx; b[2] = fy; b[3] = fx * fx; b[4] = fy * fy; b[5] = fx * fy
        }
        for ch in 0..<3 {
            var ata = [Double](repeating: 0, count: 36)
            var atb = [Double](repeating: 0, count: 6)
            var sum = 0.0
            var samples = 0
            var y = 0
            while y < n {
                var x = 0
                while x < n {
                    fill(x, y)
                    let v = Double(u[(y * n + x) * 3 + ch])
                    for i in 0..<6 {
                        atb[i] += b[i] * v
                        for j in 0..<6 { ata[i * 6 + j] += b[i] * b[j] }
                    }
                    sum += v
                    samples += 1
                    x += step
                }
                y += step
            }
            guard samples > 0, let coef = solve6(ata, atb) else { continue }
            let mean = sum / Double(samples)
            let c0 = coef[0], c1 = coef[1], c2 = coef[2], c3 = coef[3], c4 = coef[4], c5 = coef[5]
            for y in 0..<n {
                let fy = Double(y) * scale - 1
                let rowPart = c0 + c2 * fy + c4 * fy * fy
                for x in 0..<n {
                    let fx = Double(x) * scale - 1
                    let fit = rowPart + (c1 + c3 * fx + c5 * fy) * fx
                    let ratio = min(2, max(0.5, mean / max(fit, 1e-3)))
                    let k = (y * n + x) * 3 + ch
                    u[k] = Float(min(1, max(0, Double(u[k]) * ratio)))
                }
            }
        }
    }

    /// 6 x 6 linear solve (partial pivoting); nil if singular.
    private static func solve6(_ a0: [Double], _ b0: [Double]) -> [Double]? {
        let n = 6
        var a = a0, b = b0
        for col in 0..<n {
            var p = col
            for row in (col + 1)..<n where abs(a[row * n + col]) > abs(a[p * n + col]) { p = row }
            guard abs(a[p * n + col]) > 1e-12 else { return nil }
            if p != col {
                for k in 0..<n { a.swapAt(p * n + k, col * n + k) }
                b.swapAt(p, col)
            }
            for row in (col + 1)..<n {
                let factor = a[row * n + col] / a[col * n + col]
                if factor == 0 { continue }
                for k in col..<n { a[row * n + k] -= factor * a[col * n + k] }
                b[row] -= factor * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = b[row]
            for k in (row + 1)..<n { s -= a[row * n + k] * x[k] }
            x[row] = s / a[row * n + row]
        }
        return x
    }

    // MARK: The tile

    private static func build(_ r: UnsafeMutablePointer<Float>, _ u: UnsafeMutablePointer<Float>, _ n: Int) {
        let c = n / 2
        let f = max(Float(2), Float(n) / 256)                // feather, pixels
        let fpix = Int(f.rounded(.up))
        let w = n / 4, m = max(4, n / 32)                    // band half-width; how far each cut stays from the seam
        let bw = n / 4, bh = n * 3 / 8                       // centre box half-width / half-height
        let zone = w - m

        // A: the photo wrapped by half.
        for y in 0..<n {
            for x in 0..<n {
                let d = (y * n + x) * 3, s = (((y + c) % n) * n + (x + c) % n) * 3
                r[d] = u[s]; r[d + 1] = u[s + 1]; r[d + 2] = u[s + 2]
            }
        }

        // B (wrapped vertically only) on a vertical band around x = c. One column per row.
        do {
            let eL = errors(rows: n, cols: zone, r, u, n, 0, c) { i, j in (c - w + j, i) }
            let eR = errors(rows: n, cols: zone, r, u, n, 0, c) { i, j in (c + m + j, i) }
            let left = cut(eL, rows: n, cols: zone, cyclic: true).map { $0 + c - w }
            let right = cut(eR, rows: n, cols: zone, cyclic: true).map { $0 + c + m }
            for y in 0..<n {
                for x in max(0, c - w - fpix)..<min(n, c + w + fpix + 1) {
                    blend(r, u, n, 0, c, x, y, ramp(Float(x - left[y]), f) * ramp(Float(right[y] - x), f))
                }
            }
        }

        // C (wrapped horizontally only) on a horizontal band around y = c. One row per column.
        do {
            let eT = errors(rows: n, cols: zone, r, u, n, c, 0) { i, j in (i, c - w + j) }
            let eB = errors(rows: n, cols: zone, r, u, n, c, 0) { i, j in (i, c + m + j) }
            let top = cut(eT, rows: n, cols: zone, cyclic: true).map { $0 + c - w }
            let bottom = cut(eB, rows: n, cols: zone, cyclic: true).map { $0 + c + m }
            for y in max(0, c - w - fpix)..<min(n, c + w + fpix + 1) {
                for x in 0..<n {
                    blend(r, u, n, c, 0, x, y, ramp(Float(y - top[x]), f) * ramp(Float(bottom[x] - y), f))
                }
            }
        }

        // D (the photo itself) on a centre box: covers C's break at x = c. Its top and
        // bottom cuts stay outside the horizontal band.
        do {
            let x0 = c - bw, y0 = c - bh
            let sideCols = bw - m, capRows = bh - w - fpix
            guard sideCols > 0, capRows > 0 else { return }
            let eL = errors(rows: 2 * bh, cols: sideCols, r, u, n, 0, 0) { i, j in (x0 + j, y0 + i) }
            let eR = errors(rows: 2 * bh, cols: sideCols, r, u, n, 0, 0) { i, j in (x0 + bw + m + j, y0 + i) }
            let eT = errors(rows: 2 * bw, cols: capRows, r, u, n, 0, 0) { i, j in (x0 + i, y0 + j) }
            let eB = errors(rows: 2 * bw, cols: capRows, r, u, n, 0, 0) { i, j in (x0 + i, y0 + bh + w + fpix + j) }
            let left = cut(eL, rows: 2 * bh, cols: sideCols, cyclic: false)
            let right = cut(eR, rows: 2 * bh, cols: sideCols, cyclic: false).map { $0 + bw + m }
            let top = cut(eT, rows: 2 * bw, cols: capRows, cyclic: false)
            let bottom = cut(eB, rows: 2 * bw, cols: capRows, cyclic: false).map { $0 + bh + w + fpix }
            for j in 0..<(2 * bh) {
                for i in 0..<(2 * bw) {
                    let across: Float = ramp(Float(i - left[j]), f) * ramp(Float(right[j] - i), f)
                    let down: Float = ramp(Float(j - top[i]), f) * ramp(Float(bottom[i] - j), f)
                    blend(r, u, n, 0, 0, x0 + i, y0 + j, across * down)
                }
            }
        }
    }

    private static func ramp(_ d: Float, _ f: Float) -> Float { min(1, max(0, d / f + 0.5)) }

    /// Mixes the photo wrapped by (ox, oy) into the tile at (x, y) by `a`.
    private static func blend(_ r: UnsafeMutablePointer<Float>, _ u: UnsafeMutablePointer<Float>, _ n: Int,
                              _ ox: Int, _ oy: Int, _ x: Int, _ y: Int, _ a: Float) {
        guard a > 0 else { return }
        let d = (y * n + x) * 3, s = (((y + oy) % n) * n + (x + ox) % n) * 3
        for k in 0..<3 { r[d + k] = r[d + k] * (1 - a) + u[s + k] * a }
    }

    /// Colour + 2 x edge-direction squared difference between the tile and the
    /// photo wrapped by (ox, oy), at (x, y); neighbours wrap at the edges.
    private static func difference(_ r: UnsafeMutablePointer<Float>, _ u: UnsafeMutablePointer<Float>, _ n: Int,
                                   _ ox: Int, _ oy: Int, _ x: Int, _ y: Int) -> Float {
        let x1 = x + 1 == n ? 0 : x + 1, y1 = y + 1 == n ? 0 : y + 1
        let sx = (x + ox) % n, sy = (y + oy) % n, sx1 = (x1 + ox) % n, sy1 = (y1 + oy) % n
        let r0 = (y * n + x) * 3, rx = (y * n + x1) * 3, ry = (y1 * n + x) * 3
        let s0 = (sy * n + sx) * 3, sxi = (sy * n + sx1) * 3, syi = (sy1 * n + sx) * 3
        var e: Float = 0
        for k in 0..<3 {
            let d = r[r0 + k] - u[s0 + k]
            let gx = (r[rx + k] - r[r0 + k]) - (u[sxi + k] - u[s0 + k])
            let gy = (r[ry + k] - r[r0 + k]) - (u[syi + k] - u[s0 + k])
            e += d * d + 2 * (gx * gx + gy * gy)
        }
        return e
    }

    /// A rows x cols difference grid; `at(row, col)` gives the tile pixel (x, y).
    private static func errors(rows: Int, cols: Int, _ r: UnsafeMutablePointer<Float>, _ u: UnsafeMutablePointer<Float>,
                               _ n: Int, _ ox: Int, _ oy: Int, _ at: (Int, Int) -> (Int, Int)) -> [Float] {
        var e = [Float](repeating: 0, count: rows * cols)
        for i in 0..<rows {
            for j in 0..<cols {
                let (x, y) = at(i, j)
                e[i * cols + j] = difference(r, u, n, ox, oy, x, y)
            }
        }
        return e
    }

    /// The cheapest path through the grid, one column per row, moving at most one
    /// column per row. `cyclic`: it must close on itself (last row within one
    /// column of the first) so it wraps across the tile's edge without a jump --
    /// a few well-spread cheap starting columns are tried. Ties: straight, then
    /// left, then right.
    private static func cut(_ e: [Float], rows: Int, cols: Int, cyclic: Bool) -> [Int] {
        var starts: [Int] = []
        if cyclic {
            let order = (0..<cols).sorted { e[$0] != e[$1] ? e[$0] < e[$1] : $0 < $1 }
            let gap = cols / 12
            for s in order where starts.allSatisfy({ abs(s - $0) > gap }) {
                starts.append(s)
                if starts.count == 6 { break }
            }
        } else {
            starts = [-1]                                    // (-1: any start)
        }
        var back = [Int8](repeating: 0, count: rows * cols)
        var cost = [Float](repeating: 0, count: cols)
        var next = [Float](repeating: 0, count: cols)
        var bestTotal = Float.infinity
        var bestPath = [Int](repeating: cols / 2, count: rows)
        for s in starts {
            for j in 0..<cols { cost[j] = (s < 0 || s == j) ? e[j] : .infinity }
            for i in 1..<rows {
                let rowBase = i * cols
                for j in 0..<cols {
                    var best = cost[j]
                    var step: Int8 = 0
                    if j > 0, cost[j - 1] < best { best = cost[j - 1]; step = -1 }
                    if j + 1 < cols, cost[j + 1] < best { best = cost[j + 1]; step = 1 }
                    next[j] = best + e[rowBase + j]
                    back[rowBase + j] = step
                }
                swap(&cost, &next)
            }
            var end = 0
            if s < 0 {
                for j in 1..<cols where cost[j] < cost[end] { end = j }
            } else {
                let lo = max(0, s - 1), hi = min(cols - 1, s + 1)
                end = lo
                for j in lo...hi where cost[j] < cost[end] { end = j }
            }
            if cost[end] < bestTotal {
                bestTotal = cost[end]
                var path = [Int](repeating: 0, count: rows)
                path[rows - 1] = end
                for i in stride(from: rows - 1, to: 0, by: -1) {
                    path[i - 1] = path[i] + Int(back[i * cols + path[i]])
                }
                bestPath = path
            }
        }
        return bestPath
    }
}
