import SwiftUI
import ImageIO

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
struct DecoratorSurfacesSheet: View {
    @ObservedObject var store: MazeStore
    /// Oct 1 (Surfaces "This Cell"): supplies the current cell and the
    /// cell-override edit.
    @ObservedObject var state: DecoratorState
    @Binding var isPresented: Bool
    /// Oct 1: off = the whole floor (unchanged behavior); on = only the
    /// player's current cell, via the cell-surface overrides.
    @State private var thisCell = false

    @State private var includeWalls = false
    @State private var includeFloor = false
    @State private var includeCeiling = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Walls", isOn: $includeWalls)
                    Toggle("Floor", isOn: $includeFloor)
                    Toggle("Ceiling", isOn: $includeCeiling)
                } header: {
                    Text("Apply To")
                } footer: {
                    Text("Choose one, two, or all three, then pick a texture to apply it to every one you checked.")
                }
                Section {
                    Toggle("This Cell", isOn: $thisCell)
                        .disabled(state.cellForSurfaceEditing() == nil)
                } footer: {
                    Text(thisCell
                         ? "Only the cell you're standing in changes. \"Use Floor Default\" makes it follow the floor again."
                         : "Off: changes the whole floor.")
                }
                Section {
                    NavigationLink {
                        SurfaceTexturePicker(
                            applyWalls: includeWalls,
                            applyFloor: includeFloor,
                            applyCeiling: includeCeiling,
                            store: store,
                            isPresented: $isPresented,
                            cell: thisCell ? state.cellForSurfaceEditing() : nil,
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
    let state: DecoratorState?

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

    init(applyWalls: Bool, applyFloor: Bool, applyCeiling: Bool, store: MazeStore, isPresented: Binding<Bool>,
         cell: GridCoordinate? = nil, state: DecoratorState? = nil) {
        self.applyWalls = applyWalls
        self.applyFloor = applyFloor
        self.applyCeiling = applyCeiling
        self.store = store
        self._isPresented = isPresented
        self.cell = cell
        self.state = state
        self._selectedTexture = State(initialValue: Self.initialSelection(applyWalls: applyWalls, applyFloor: applyFloor, applyCeiling: applyCeiling, store: store, cell: cell))
    }

    /// Oct 1: the checked targets as cell-surface kinds.
    static func surfaces(walls: Bool, floor: Bool, ceiling: Bool) -> [CellSurfaceKind] {
        (walls ? [.wall] : []) + (floor ? [.floor] : []) + (ceiling ? [.ceiling] : [])
    }

    /// Oct 1: the ONE apply path for both scopes. cell == nil is exactly the
    /// pre-existing whole-floor behavior; a cell writes only the checked
    /// targets' overrides for that cell (nil = Use Floor Default removes them).
    static func applyChoice(_ name: String?, walls: Bool, floor: Bool, ceiling: Bool,
                            cell: GridCoordinate?, store: MazeStore, state: DecoratorState?) {
        if let cell {
            state?.setCellSurfaces(name, for: surfaces(walls: walls, floor: floor, ceiling: ceiling), at: cell)
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
    private static func initialSelection(applyWalls: Bool, applyFloor: Bool, applyCeiling: Bool, store: MazeStore, cell: GridCoordinate? = nil) -> SurfaceSelectionState? {
        var values: [String?] = []
        if let cell {
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
    private func apply(_ name: String?) {
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
            LazyVGrid(columns: columns, spacing: 12) {
                Button {
                    apply(nil)
                } label: {
                    defaultTile(selected: selectedTexture == .defaultTexture)
                }
                .accessibilityLabel(cell == nil ? "Default" : "Use Floor Default")

                ForEach(HallwayScene.availableHallwayTextureNames(), id: \.self) { name in
                    Button {
                        apply(name)
                    } label: {
                        thumbnail(for: name, selected: selectedTexture == .texture(name))
                    }
                    .accessibilityLabel(Text(name))
                }
            }
            .padding()
        }
        .navigationTitle(cell == nil ? "Choose Surface" : "Choose Surface — This Cell")
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
            Text(cell == nil ? "Default" : "Use Floor Default")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: swatchSize, height: swatchSize)
        .overlay(selectionOverlay(selected))
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
