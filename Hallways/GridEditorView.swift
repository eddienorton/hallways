//
//  GridEditorView.swift
//  Hallways
//
//  A full-screen grid of tappable cells that doubles as the maze editor:
//  drag across cells to paint them open, drag across open cells to erase
//  them back to white. Whatever's painted here is exactly what
//  HallwayScene.build(fromMaze:) turns into the first-person space — same
//  data, two views. Per-cell color was tried and dropped (made the 3D
//  hallway look dark and blocky), so open cells are all one simple color
//  here now — the shape is the only thing this screen communicates.
//
//  Redesigned per Eddie's request: every control used to live in three
//  overlays sitting ON TOP of the grid (dismiss X top-right, floor nav
//  top-center, undo/trash/object-picker top-left), covering a chunk of
//  it. They're now real layout siblings in a bottom control bar instead
//  — body is just VStack { gridArea; controlBar }, nothing overlaps the
//  grid at all. Same pass also replaced the grid's old dynamically
//  growing/shrinking size (it expanded — and shrank every cell — the
//  moment you painted near the current edge) with a fixed 15x20 grid,
//  which was the actual root fix, not just a cosmetic one: see the
//  columns/rows doc comment below for why that also kills the old
//  "diagonal trail of tiny disconnected rooms" bug outright rather than
//  working around it.
//

import SwiftUI
import Combine

/// UI-only presentation details for each object kind, kept here rather
/// than on ObjectKind itself since that enum lives in MazeStore.swift
/// as part of the data model and shouldn't need to know about SwiftUI
/// Colors, SF Symbol names, or emoji.
private extension ObjectKind {
    /// Heart and star predate the Font-Awesome-icon pipeline and already
    /// had hand-picked SF Symbols, so they keep using those here (nil
    /// for every other kind). The 6 icons pulled in via SVGPathParser
    /// don't have a vetted SF Symbol counterpart — guessing a symbol
    /// name for "ice cream" or "baby carriage" risks referencing one
    /// that doesn't exist or looks nothing like the 3D piece — so they
    /// use a plain emoji instead (see editorEmoji below). objectGlyph(_:)
    /// is what picks between the two paths.
    var editorFilledIconName: String? {
        switch self {
        case .heart: return "heart.fill"
        case .star: return "star.fill"
        default: return nil
        }
    }
    var editorOutlineIconName: String? {
        switch self {
        case .heart: return "heart"
        case .star: return "star"
        default: return nil
        }
    }
    /// Only meaningful for the 6 kinds without an SF Symbol pair above;
    /// unused (and left blank) for heart/star.
    var editorEmoji: String {
        switch self {
        case .heart, .star: return ""
        case .iceCream: return "🍦"
        case .appleWhole: return "🍎"
        case .babyCarriage: return "🚼"
        case .snowman: return "⛄"
        case .personBiking: return "🚴"
        case .cakeCandles: return "🎂"
        case .trashCan: return "🗑️"
        case .cash100: return "💵"
        case .envelope: return "✉️"
        case .key: return "🔑"
        case .paintBucket: return "🪣"
        }
    }
    var editorColor: Color {
        switch self {
        case .heart: return .red
        case .star: return .orange
        case .iceCream: return .pink
        case .appleWhole: return .red
        case .babyCarriage: return .blue
        case .snowman: return Color(white: 0.8)
        case .personBiking: return .green
        case .cakeCandles: return .orange
        case .trashCan: return Color(white: 0.55)
        case .cash100: return Color(red: 0.8, green: 0.6, blue: 0.1)
        case .envelope: return Color(red: 0.55, green: 0.42, blue: 0.22)
        case .key: return .yellow
        case .paintBucket: return .blue
        }
    }
}

/// Which placement-tool family the editor's lower bar currently shows
/// (Suzanimator pass, Sept 19). Purely presentational routing -- it does
/// NOT replace objectKindToPlace / destinationKindToPlace /
/// exitDirectionToPlace and friends; those @State vars stay the source of
/// truth that paint(at:) reads. selectedTool is kept in sync with whatever
/// placement mode is active by every placement button and selectTool(_:).
private enum EditorTool: String, CaseIterable, Identifiable {
    case walls
    case delete
    case pickup
    case chute
    case exit
    case map
    case picture
    case mirror
    case door
    case windowRoom
    case light
    case photoBooth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .delete: return "Delete"
        case .walls: return "Pencil"
        case .pickup: return "Pickup / Object"
        case .chute: return "Chute / Destination"
        case .exit: return "Exit Sign"
        case .map: return "Floor Map"
        case .picture: return "Picture"
        case .mirror: return "Mirror"
        case .door: return "Door"
        case .windowRoom: return "Window Room"
        case .light: return "Light"
        case .photoBooth: return "Photo Booth"
        }
    }

    var iconName: String {
        switch self {
        case .delete: return "trash"
        case .walls: return "pencil"
        case .pickup: return "cube.fill"
        case .chute: return "arrow.down.square.fill"
        case .exit: return "location.north.fill"
        case .map: return "map.fill"
        case .picture: return "photo.fill"
        case .mirror: return "person.crop.rectangle"
        case .door: return "door.left.hand.closed"
        case .windowRoom: return "macwindow"
        case .light: return "lightbulb.fill"
        case .photoBooth: return "camera.fill"
        }
    }
}

/// Which EXISTING physical light source the Light tool paints
/// (Suzanimator lighting pass, Sept 19). Every case maps to a real
/// runtime source -- nothing invented here: ceiling is the omni fixture
/// hung from the ceiling slab, fire is the animated flame + omni glow.
/// Both sit centered in their cell (no wall to mount on), so this is a
/// plain enum with no direction axis, exactly like the previous single
/// "spotlight" on/off toggle.
fileprivate enum EditorLightType: String, CaseIterable, Identifiable {
    case ceiling
    case fluorescent
    case wall
    case picture
    case fire

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fluorescent: return "Fluorescent"
        case .ceiling: return "Ceiling"
        case .wall: return "Wall Light"
        case .fire: return "Fire"
        case .picture: return "Picture Light"
        }
    }

    var iconName: String {
        switch self {
        case .fluorescent: return "light.panel.fill"
        case .ceiling: return "lightbulb.fill"
        case .wall: return "lamp.table.fill"
        case .fire: return "flame.fill"
        case .picture: return "photo.fill"
        }
    }

    /// Sept 21 (1-10 brightness expansion): the Floor Editor's brightness
    /// picker range is per-kind now (ceiling/fluorescent go to 10, the
    /// rest stay at 5) -- this is the one place EditorLightType maps to
    /// the shared AuthoredLightKind range, so the picker doesn't need its
    /// own copy of which kinds got the wider range.
    var authoredKind: AuthoredLightKind {
        switch self {
        case .fluorescent: return .fluorescent
        case .ceiling: return .ceiling
        case .wall: return .wall
        case .fire: return .fire
        case .picture: return .picture
        }
    }
}

/// Authoring controls only: retained for this process, never saved as floor data.
private final class SuzanimatorSession: ObservableObject {
    static let shared = SuzanimatorSession()
    @Published var objectKindToPlace: ObjectKind? = nil
    @Published var destinationKindToPlace: ObjectKind? = nil
    @Published var exitDirectionToPlace: Direction? = nil
    @Published var floorMapDirectionToPlace: Direction? = nil
    @Published var pictureDirectionToPlace: Direction? = nil
    @Published var mirrorDirectionToPlace: Direction? = nil
    @Published var wallLightDirectionToPlace: Direction? = nil
    @Published var doorDirectionToPlace: Direction? = nil
    @Published var windowRoomDirectionToPlace: Direction? = nil
    @Published var mailRoomToPlace: Int? = nil
    @Published var lightTypeToPlace: EditorLightType? = nil
    @Published var selectedTool: EditorTool = .walls
    @Published var pictureLightDirection: Direction? = nil
    @Published var fluorescentOrientation: FluorescentOrientation = .northSouth
    /// Auto-orientation is the default for a freshly ADDED fluorescent;
    /// once the user pinches the Floor Editor's Orientation picker, that
    /// explicit choice wins and the corridor's own axis is only used as
    /// the initial default (and on cells with no clear axis at all).
    @Published var fluorescentOrientationExplicit = false
    @Published var brightnessToPlace = 3
    @Published var photoBoothDirectionToPlace: Direction? = nil
    @Published var photoBoothExpressionToPlace: PhotoBoothExpression = .smile
    @Published var pictureSizeToPlace: PictureSize = .standard
}

/// SwiftUI owns the modal presentation on both iPhone and iPad; no
/// unanchored UIKit popover is presented from a global/root controller.
private struct BuildingJSONShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct CellDeletionRequest: Identifiable {
    let id = UUID()
    let floorID: Int
    let coord: GridCoordinate
    let items: [EditorCellContent]
}

private struct CellDeletionSheet: View {
    let request: CellDeletionRequest
    let onDelete: (Set<EditorContentKind>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDeletions: Set<EditorContentKind> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(request.items) { item in
                    if request.items.count == 1 {
                        Text(item.title)
                    } else {
                        Button {
                            if selectedDeletions.contains(item.id) {
                                selectedDeletions.remove(item.id)
                            } else {
                                selectedDeletions.insert(item.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: selectedDeletions.contains(item.id) ? "checkmark.square.fill" : "square")
                                Text(item.title)
                                Spacer()
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedDeletions.contains(item.id) ? .isSelected : [])
                    }
                }
            }
            .navigationTitle(request.items.count == 1 ? "Delete Item?" : "Delete Cell Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.items.count == 1 ? "Delete" : "Delete Selected", role: .destructive) {
                        let chosen = request.items.count == 1 ? Set(request.items.map(\.id)) : selectedDeletions
                        onDelete(chosen)
                        dismiss()
                    }
                    .disabled(request.items.count > 1 && selectedDeletions.isEmpty)
                }
            }
        }
    }
}

struct GridEditorView: View {
    @ObservedObject private var session = SuzanimatorSession.shared
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var mazeStore: MazeStore
    /// Where the player currently is in the 3D maze, if that's even
    /// running (nil for the empty-maze fallback prototype) — a snapshot
    /// taken at the moment this screen opens, not live-updated, since
    /// the 3D view is paused underneath while this is up anyway.
    var youAreHere: GridCoordinate? = nil
    /// Which way you're facing at that cell, so the marker can show an
    /// arrow instead of just a box — nil draws no arrow (e.g. no 3D
    /// session running yet).
    var youAreHereFacing: Direction? = nil
    /// Which floor youAreHere/youAreHereFacing actually belong to (a
    /// snapshot from when this screen opened, same as those two) — the
    /// floor-nav chevrons below let you browse to a DIFFERENT floor
    /// while this is open, and without this check the player's marker
    /// would keep showing on whatever floor you've since navigated to,
    /// which isn't where they actually are. nil when there's no 3D
    /// session running yet (matches youAreHere's own nil case).
    var youAreHereMazeID: Int? = nil

    private let openColor = Color(red: 0.55, green: 0.62, blue: 0.7)

    /// Fixed at 15 columns by 15 rows -- Eddie's building-wide reset
    /// (round 2): the master coordinate space is now a square 15x15,
    /// down from the original 15x20. Being a plain, non-@State
    /// constant is what actually eliminates a whole class of bug: the
    /// old, pre-fixed-grid code recomputed columns/rows from the
    /// maze's own painted bounds on every mazeStore mutation, including
    /// mid-drag, so painting a cell near the edge could resize the grid
    /// underneath the very finger stroke that caused it — a
    /// still-unmoved finger would suddenly land on a totally different
    /// cell once the grid reflowed. With a fixed size there's nothing
    /// left to recompute: cellSize below still adapts to whatever
    /// screen space is actually available, but columns/rows themselves
    /// never move again. Valid coordinates are rows 0-14, cols 0-14 --
    /// the building's fixed elevatorCoordinate (10,7) sits well inside
    /// that on every floor.
    private let columns = 15
    private let rows = 15

    // The first cell touched in a drag decides whether the whole stroke
    // paints or erases; every cell the finger crosses afterward follows
    // that same mode. A tap is just a one-cell drag, so this handles both.
    @State private var paintMode = true
    @State private var gridZoom: CGFloat = 1
    @State private var gridOffset = CGSize.zero
    @State private var zoomStart: CGFloat? = nil
    @State private var panStart: CGSize? = nil
    @State private var pinchCentroid: CGPoint? = nil
    @State private var transformingGrid = false
    @State private var pendingGridPoints: [CGPoint] = []
    @State private var deletionRequest: CellDeletionRequest? = nil
    @State private var sharedJSONURL: URL?
    @State private var showJSONShareSheet = false
    @State private var jsonShareError: String?

    /// Two different things a drag can do to a cell now: paint/erase
    /// walls (nil, the default), or place/remove a specific kind of
    /// object on an already-open cell. One toggle button per ObjectKind
    /// in the bottom bar switches which, mutually exclusive with each
    /// other and with wall painting; the drag gesture itself is
    /// unchanged either way, just branches on this.
    private var objectKindToPlace: ObjectKind? {
        get { session.objectKindToPlace }
        nonmutating set { session.objectKindToPlace = newValue }
    }
    /// Same idea, for placing a DESTINATION on a cell instead of a
    /// critter -- mutually exclusive with objectKindToPlace (and with
    /// wall painting): picking a destination kind clears any active
    /// critter kind and vice versa, so there's only ever one placement
    /// mode active at a time.
    private var destinationKindToPlace: ObjectKind? {
        get { session.destinationKindToPlace }
        nonmutating set { session.destinationKindToPlace = newValue }
    }
    /// Same idea again, for placing an Exit Sign -- mutually exclusive
    /// with the other two placement modes and with wall painting.
    /// Eddie, Sept 5 (round 5): "let me lay the exit signs down
    /// manually... doing it auto in the code comes up with funky
    /// layouts where theres a bunch of exits in a row" -- so
    /// HallwayScene.build(fromMaze:) no longer decides placement OR
    /// direction; this screen does both. There's no separate "kind"
    /// to pick (an Exit Sign is always the same fixture), so the 4
    /// direction toggle buttons below double as both the mode switch
    /// AND the direction picker: whichever one is active is also the
    /// direction the next placed/repointed sign gets.
    private var exitDirectionToPlace: Direction? {
        get { session.exitDirectionToPlace }
        nonmutating set { session.exitDirectionToPlace = newValue }
    }
    /// Same idea once more, for placing a "You Are Here" floor map --
    /// mutually exclusive with all 3 other placement modes and with
    /// wall painting. Eddie, Sept 5: "let me control that and put maps
    /// wherever i want" -- HallwayScene.build(fromMaze:) no longer
    /// auto-mounts one at `start`, this screen picks both the cell and
    /// the wall now, same split as Exit Signs above. Unlike an Exit
    /// Sign, the wall a map hangs on has to actually BE a wall --
    /// paint(at:) checks that before ever calling placeFloorMap.
    private var floorMapDirectionToPlace: Direction? {
        get { session.floorMapDirectionToPlace }
        nonmutating set { session.floorMapDirectionToPlace = newValue }
    }
    /// Same idea once more, for placing a decorative Picture --
    /// mutually exclusive with every other placement mode and with
    /// wall painting. Eddie, Sept 9: "make the picture appear as a
    /// picture on the wall (like we do to the mission and maps)" --
    /// same "editor picks the cell AND the wall" split as Exit Signs/
    /// floor maps, and same wall-required check as floor maps (nothing
    /// to hang a picture on across an open doorway). Unlike either of
    /// those, no image is picked here -- HallwayScene.build(fromMaze:)
    /// grabs a random one from the bundled Pictures folder at build
    /// time, so this screen only ever decides where, never which photo.
    private var pictureDirectionToPlace: Direction? {
        get { session.pictureDirectionToPlace }
        nonmutating set { session.pictureDirectionToPlace = newValue }
    }
    private var mirrorDirectionToPlace: Direction? {
        get { session.mirrorDirectionToPlace }
        nonmutating set { session.mirrorDirectionToPlace = newValue }
    }
    private var wallLightDirectionToPlace: Direction? {
        get { session.wallLightDirectionToPlace }
        nonmutating set { session.wallLightDirectionToPlace = newValue }
    }
    private var photoBoothDirectionToPlace: Direction? {
        get { session.photoBoothDirectionToPlace }
        nonmutating set { session.photoBoothDirectionToPlace = newValue }
    }
    private var photoBoothExpressionToPlace: PhotoBoothExpression {
        get { session.photoBoothExpressionToPlace }
        nonmutating set { session.photoBoothExpressionToPlace = newValue }
    }
    private var pictureSizeToPlace: PictureSize {
        get { session.pictureSizeToPlace }
        nonmutating set { session.pictureSizeToPlace = newValue }
    }
    private var doorDirectionToPlace: Direction? {
        get { session.doorDirectionToPlace }
        nonmutating set { session.doorDirectionToPlace = newValue }
    }
    /// Which wall a NEW Window Room door will be placed on next tap
    /// -- same shape as doorDirectionToPlace (a whole extra
    /// generalized Room abstraction wasn't warranted for one new
    /// fixture, so this is its own small parallel tool, mirroring
    /// the door tool's own UI/state pattern instead).
    private var windowRoomDirectionToPlace: Direction? {
        get { session.windowRoomDirectionToPlace }
        nonmutating set { session.windowRoomDirectionToPlace = newValue }
    }
    private var mailRoomToPlace: Int? {
        get { session.mailRoomToPlace }
        nonmutating set { session.mailRoomToPlace = newValue }
    }
    /// Arming state for the Light tool (Suzanimator lighting pass,
    /// Sept 19): WHICH existing physical light source the next tap will
    /// place. Mutually exclusive with every other placement mode and
    /// with wall painting, exactly like the single ceiling-spotlight
    /// toggle it replaces (Eddie, Sept 6: "how difficult to have a
    /// spotlight that we could place on the ceiling of a box?"). Neither
    /// fire nor a ceiling light mounts on a wall, so there's no
    /// direction to pick -- this stays a plain on/off arming toggle.
    private var lightTypeToPlace: EditorLightType? {
        get { session.lightTypeToPlace }
        nonmutating set { session.lightTypeToPlace = newValue }
    }
    /// Which tool family the lower bar currently shows (see EditorTool).
    /// Derived UI, not a placement mode -- paint(at:) keeps reading only
    /// the real per-mode @State vars above; every placement button and
    /// selectTool(_:) keep selectedTool in sync with those.
    private var selectedTool: EditorTool {
        get { session.selectedTool }
        nonmutating set { session.selectedTool = newValue }
    }
    /// Same idea once more, for placing a Floor Mission sign --
    /// mutually exclusive with all 5 other placement modes and with
    /// Drives the mission-editor sheet -- the "pop open a text input
    /// field" Eddie asked for, rather than hard-coding mission text
    /// per floor in an array.
    @State private var showMissionEditor = false
    /// Local drafts, seeded from mazeStore.missionHeading/missionBody
    /// when the sheet opens and written back via setMissionText only
    /// on Save -- so backing out with Cancel genuinely discards
    /// in-progress typing instead of live-editing the real value on
    /// every keystroke.
    @State private var missionHeadingDraft = ""
    @State private var missionBodyDraft = ""

    /// Drives the Floor Surfaces sheet -- same "draft, write back only
    /// on Save" shape as the mission editor above, so Cancel discards
    /// in-progress picker changes instead of live-editing the real
    /// value with every tap.
    @State private var showSurfaceEditor = false
    @State private var wallTextureDraft: String? = nil
    @State private var floorTextureDraft: String? = nil
    @State private var ceilingTextureDraft: String? = nil

    /// Drives the RESET confirmation dialog -- a lightweight native
    /// action sheet (same "ask before doing the destructive thing"
    /// idea as Clear's reliance on Undo, but RESET also discards a
    /// SAVEd local override, which Undo alone can't bring back once
    /// the editor's moved on, so this gets an explicit confirm instead).
    @State private var showResetConfirmation = false

    // MARK: - Fixed grid + independently scrolling controls (Sept 19,
    // 3rd usability pass)
    //
    // Replaces BOTH earlier passes' attempts at making room for the
    // controls (a free-floating drag-anywhere tray, then a sliding
    // bottom drawer) -- Eddie, after device-testing the drawer: "we
    // are solving a problem we do not need to solve." The layout is
    // now the simplest possible two-region stack: the grid is a
    // fixed-size square pinned at the top (it never scrolls, never
    // moves), and controlBar -- completely untouched, same as every
    // prior pass -- sits directly below it in its own independent
    // ScrollView. No open/closed state, no offsets, no drag gesture,
    // no snapping animation, nothing to manage: scrolling the controls
    // can't move the grid because they're just two ordinary sibling
    // views in a VStack, not an overlay of any kind.

    var body: some View {
        GeometryReader { screenGeo in
            VStack(spacing: 0) {
                gridArea(width: screenGeo.size.width)

                ScrollView(.vertical, showsIndicators: true) {
                    controlBar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .statusBarHidden()
        .sheet(isPresented: $showJSONShareSheet, onDismiss: removeTemporaryJSONExport) {
            if let sharedJSONURL {
                BuildingJSONShareSheet(fileURL: sharedJSONURL)
            }
        }
        .alert("Unable to Share JSON", isPresented: Binding(
            get: { jsonShareError != nil },
            set: { if !$0 { jsonShareError = nil } }
        )) {
            Button("OK", role: .cancel) { jsonShareError = nil }
        } message: {
            Text(jsonShareError ?? "Please try again.")
        }
        .sheet(item: $deletionRequest) { request in
            CellDeletionSheet(request: request) { selected in
                guard request.floorID == mazeStore.currentMazeID else { return }
                mazeStore.deleteContent(selected, at: request.coord)
            }
        }
        .onChange(of: mazeStore.version) { newVersion in
            // TEMPORARY DIAGNOSTIC (Eddie, Sept 20, object-placement trace) -- remove after root cause is found.
            NSLog("%@", "[PLACEDIAG] onChange(version) fired: newVersion=\(newVersion) versionChangeIsFloorLoad=\(mazeStore.versionChangeIsFloorLoad) objects.count=\(mazeStore.objects.count) BEFORE autosave")
            // Sept 20 (autosave pass): every completed edit now
            // persists AND survives an app relaunch on its own --
            // see MazeStore.autosaveAfterVersionChange()'s own
            // comment for how it tells a real edit apart from merely
            // switching floors or resetting one to default. This
            // replaces the old plain mazeStore.save() here, which
            // kept in-progress work alive for the rest of the running
            // session but never survived quitting the app unless the
            // (now-removed) manual SAVE button was also tapped.
            mazeStore.autosaveAfterVersionChange()
            NSLog("%@", "[PLACEDIAG] onChange(version): objects.count=\(mazeStore.objects.count) AFTER autosave")
        }
        .sheet(isPresented: $showMissionEditor) {
            missionEditorSheet
        }
        .sheet(isPresented: $showSurfaceEditor) {
            surfaceEditorSheet
        }
        .confirmationDialog(
            "Reset Floor \(mazeStore.currentMazeID) to Default?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Floor \(mazeStore.currentMazeID)", role: .destructive) {
                mazeStore.resetCurrentFloorToDefault()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This discards Floor \(mazeStore.currentMazeID)'s saved local edits and reloads it from the bundled default. Other floors are not affected.")
        }
    }

    /// The grid itself and nothing else — no controls drawn over any
    /// part of it anymore, and (3rd usability pass) no longer wrapped
    /// in its own GeometryReader/ScrollView either: body's outer
    /// GeometryReader already knows the screen's own width, which
    /// is all a fixed-size square grid needs, so it's passed straight
    /// in. cellSize = width / 15 fills the available width edge to
    /// edge; since columns == rows == 15, gridHeight comes out equal
    /// to width -- a plain square, explicitly frame()'d to exactly
    /// that size so it never grows, shrinks, or scrolls regardless of
    /// what the controls below it do. Not wrapping this in
    /// .ignoresSafeArea keeps the earlier fix from the 2nd pass:
    /// body's GeometryReader reports its normal, safe-area-respecting
    /// size, so the grid (the VStack's first child) naturally starts
    /// right below the top safe area / Dynamic Island rather than
    /// running underneath it.
    private func gridArea(width: CGFloat) -> some View {
        let cellSize = width / CGFloat(columns)
        let gridItems = Array(repeating: GridItem(.fixed(cellSize), spacing: 0), count: columns)
        let gridHeight = cellSize * CGFloat(rows)

        NSLog("%@", "[PLACEDIAG] GRID RENDER floor=\(mazeStore.currentMazeID) version=\(mazeStore.version) tool=\(selectedTool.rawValue) object=\(String(describing: objectKindToPlace)) picture=\(String(describing: pictureDirectionToPlace)) objects=\(mazeStore.objects) pictures=\(mazeStore.pictures)")
        let grid = ZStack {
            Color.white
            LazyVGrid(columns: gridItems, spacing: 0) {
                ForEach(0..<(rows * columns), id: \.self) { index in
                    let coord = GridCoordinate(row: index / columns, col: index % columns)
                    cellView(coord, cellSize: cellSize)
                }
            }
        }
        .frame(width: width, height: gridHeight)
        return ZStack(alignment: .topLeading) {
            grid
                .scaleEffect(gridZoom, anchor: .topLeading)
                .offset(gridOffset)
        }
        .frame(width: width, height: gridHeight)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if value.translation == .zero {
                        pendingGridPoints = []
                        if zoomStart == nil && panStart == nil { transformingGrid = false }
                    }
                    guard !transformingGrid else { return }
                    pendingGridPoints.append(value.location)
                }
                .onEnded { value in
                    defer { pendingGridPoints = [] }
                    guard !transformingGrid else { return }
                    let points = pendingGridPoints.isEmpty ? [value.startLocation, value.location] : pendingGridPoints + [value.location]
                    commitGridStroke(points, width: width, cellSize: cellSize)
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    transformingGrid = true
                    pendingGridPoints = []
                    if zoomStart == nil { zoomStart = gridZoom }
                    let centroid = pinchCentroid ?? value.startLocation
                    let nextZoom = min(4, max(1, (zoomStart ?? 1) * value.magnification))
                    // screen = content * scale + offset. Preserve the content
                    // point currently underneath the actual two-finger centroid.
                    let ratio = nextZoom / gridZoom
                    let anchoredOffset = CGSize(
                        width: centroid.x - (centroid.x - gridOffset.width) * ratio,
                        height: centroid.y - (centroid.y - gridOffset.height) * ratio)
                    gridZoom = nextZoom
                    gridOffset = boundedGridOffset(anchoredOffset, width: width)
                }
                .onEnded { _ in
                    zoomStart = nil
                    if panStart == nil { pinchCentroid = nil }
                }
        )
        .gesture(EditorTwoFingerPan { translation, centroid, ended in
            transformingGrid = true
            pendingGridPoints = []
            pinchCentroid = centroid
            // Apply only the new pan delta; an absolute pan-start offset would
            // overwrite the translation correction made by simultaneous zoom.
            let previous = panStart ?? .zero
            gridOffset = boundedGridOffset(CGSize(width: gridOffset.width + translation.width - previous.width,
                                                  height: gridOffset.height + translation.height - previous.height), width: width)
            panStart = ended ? nil : translation
            if ended && zoomStart == nil { pinchCentroid = nil }
        })
    }

    private func boundedGridOffset(_ offset: CGSize, width: CGFloat) -> CGSize {
        let minimum = width * (1 - gridZoom)
        return CGSize(width: min(0, max(minimum, offset.width)),
                      height: min(0, max(minimum, offset.height)))
    }

    private func commitGridStroke(_ screenPoints: [CGPoint], width: CGFloat, cellSize: CGFloat) {
        // Wait for a completed one-finger stroke so the first finger of a
        // pinch/pan cannot accidentally modify floor data or create Undo entries.
        let points = screenPoints.map { CGPoint(x: ($0.x - gridOffset.width) / gridZoom,
                                                y: ($0.y - gridOffset.height) / gridZoom) }
        guard let first = points.first else { return }
        NSLog("%@", "[PLACEDIAG] NATIVE STROKE points=\(points.count) zoom=\(gridZoom) tool=\(selectedTool.rawValue)")
        if selectedTool == .delete {
            inspectForDeletion(at: first, cellSize: cellSize)
            return
        }
        mazeStore.snapshotForUndo()
        var visited: Set<GridCoordinate> = []
        var previous = first
        for to in points {
            let steps = max(1, Int(ceil(hypot(to.x - previous.x, to.y - previous.y) / (cellSize * 0.25))))
            for step in 1...steps {
                let fraction = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: previous.x + (to.x - previous.x) * fraction,
                                    y: previous.y + (to.y - previous.y) * fraction)
                guard point.x >= 0, point.y >= 0, point.x < width, point.y < width else { continue }
                let coord = GridCoordinate(row: Int(point.y / cellSize), col: Int(point.x / cellSize))
                guard visited.insert(coord).inserted else { continue }
                paint(at: point, cellSize: cellSize, isStart: visited.count == 1)
            }
            previous = to
        }
    }

    @ViewBuilder
    private func cellView(_ coord: GridCoordinate, cellSize: CGFloat) -> some View {
        Rectangle()
            .fill(mazeStore.isOpen(coord) ? openColor : Color.white)
            .frame(width: cellSize, height: cellSize)
            .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
            .overlay {
                // While a "Map:" direction is selected, tapping only
                // does something on a cell that's open AND actually has
                // a solid wall on that exact side (a map needs
                // something to hang on -- see placeFloorMap's doc
                // comment). That silently-does-nothing-most-places
                // behavior is exactly what read as "nothing happens" --
                // this lights up every cell/side combo that WOULD work
                // for the currently-selected direction, before any tap.
                if let direction = floorMapDirectionToPlace, mazeStore.isOpen(coord) {
                    let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
                    if !mazeStore.isOpen(neighbor) {
                        Rectangle()
                            .fill(Color.blue.opacity(0.35))
                            .overlay(Rectangle().stroke(Color.blue, lineWidth: 2))
                    }
                }
            }
            .overlay {
                if let direction = mirrorDirectionToPlace, mazeStore.canPlaceMirror(direction, at: coord) {
                    Rectangle()
                        .fill(Color.cyan.opacity(0.35))
                        .overlay(Rectangle().stroke(Color.cyan, lineWidth: 2))
                }
                if let direction = wallLightDirectionToPlace, mazeStore.canPlaceWallLight(direction, at: coord) {
                    Rectangle()
                        .fill(Color.orange.opacity(0.35))
                        .overlay(Rectangle().stroke(Color.orange, lineWidth: 2))
                }
                if let direction = photoBoothDirectionToPlace, mazeStore.canPlacePhotoBooth(direction, at: coord) {
                    Rectangle()
                        .fill(Color.cyan.opacity(0.35))
                        .overlay(Rectangle().stroke(Color.cyan, lineWidth: 2))
                }
            }
            .overlay {
                pictureLightCellOverlay(coord, cellSize: cellSize)
                // Same eligibility preview as the Map row above, for
                // Picture placement -- pink to match that toolbar row.
                if let direction = pictureDirectionToPlace, mazeStore.isOpen(coord) {
                    let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
                    if !mazeStore.isOpen(neighbor) {
                        Rectangle()
                            .fill(Color.pink.opacity(0.35))
                            .overlay(Rectangle().stroke(Color.pink, lineWidth: 2))
                    }
                }
            }
            
            .overlay { EditorSpatialMarkers(store: mazeStore, coord: coord, cellSize: cellSize) }
            .overlay { roomAndMailBadge(at: coord, cellSize: cellSize) }
            .overlay {
                // The building's one elevator -- MazeStore.startCoordinate
                // and .endCoordinate are always the same fixed cell now
                // (Eddie, Sept 5: "one elevator, one coord, that is the
                // starting point and ending point for all floors"), so
                // this used to be an if/else-if for 2 different marks
                // ("S"/spawn vs "E"/far corner) that can no longer ever
                // both be true, or even differ, at all -- one check, one
                // mark. Drawn here regardless of whether THIS floor's own
                // hallway actually reaches it -- nothing in this screen
                // enforces that (Eddie, Sept 5: "i dont care about
                // imposing rules and error messages in the map editor"),
                // so this is the one visual reminder of where it has to
                // connect to.
                // Eddie, Sept 8: this used to just mark
                // mazeStore.startCoordinate, back when the start and
                // the elevator were always literally the same cell --
                // floor 1 split them apart (Sept 7), and this screen
                // kept marking only the start (the dead end you walk
                // in from), leaving the ACTUAL elevator -- always the
                // fixed MazeStore.elevatorCoordinate, whether or not
                // this floor's drawing even reaches it -- completely
                // invisible here. That's almost certainly why floor
                // 1's hallway ended up not actually connected to the
                // elevator: there was no way to see where it even was
                // while drawing. Both show now, distinctly, whenever
                // they differ.
                if coord == MazeStore.elevatorCoordinate {
                    Text("🛗")
                        .font(.system(size: cellSize * 0.55))
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                }
                if coord == mazeStore.startCoordinate, coord != MazeStore.elevatorCoordinate {
                    Text("🚪")
                        .font(.system(size: cellSize * 0.55))
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                }
            }
            .overlay {
                // "You are here" — white circle + red directional arrow.
                // Deliberately the LAST overlay in the chain, so the
                // marker renders on top of every other marker that can
                // share its cell (elevator, start door, light, objects,
                // signs, badges) and stays clearly visible regardless.
                // No cell fill/highlight here: the cell keeps its normal
                // background; this is the marker alone.
                if coord == youAreHere && youAreHereMazeID == mazeStore.currentMazeID {
                    if let youAreHereFacing {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: cellSize * 0.5, weight: .heavy))
                            .foregroundStyle(Color.red)
                            .shadow(color: .black.opacity(0.6), radius: 1.5)
                            .rotationEffect(.degrees(facingRotationDegrees(youAreHereFacing)))
                            .padding(3)
                            .background(Color.white, in: Circle())
                            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                    }
                }
            }
    }

    @ViewBuilder
    private func roomAndMailBadge(at coord: GridCoordinate, cellSize: CGFloat) -> some View {
        if let direction = doorDirectionToPlace, mazeStore.isOpen(coord) {
            let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
            if !mazeStore.isOpen(neighbor), coord != MazeStore.elevatorCoordinate, coord != MazeStore.missionCoordinate,
               // Sept 22 (wall-face authoring expansion): face-specific, matching placeRoomDoor's own guard.
               mazeStore.floorMaps[coord] != direction, !mazeStore.hasPicture(direction, at: coord), mazeStore.mirrors[coord] != direction, mazeStore.destinations[coord] == nil {
                Rectangle().stroke(Color.brown, lineWidth: 3)
            }
        } else if let direction = windowRoomDirectionToPlace, mazeStore.isOpen(coord) {
            let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
            if mazeStore.isOpen(neighbor), mazeStore.windowExteriorDirection(for: neighbor) != nil, coord != MazeStore.elevatorCoordinate, coord != MazeStore.missionCoordinate {
                Rectangle().stroke(Color.blue, lineWidth: 3)
            }
        }
    }

    private func shareBuildingJSON() {
        guard let json = mazeStore.exportLibraryJSON() else {
            jsonShareError = "The building JSON could not be generated. Please try again."
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Hallways-Export-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("DefaultMazes.json")
            // Preserve the exact UTF-8 output COPY places on the clipboard.
            try Data(json.utf8).write(to: url, options: .atomic)
            sharedJSONURL = url
            showJSONShareSheet = true
        } catch {
            try? FileManager.default.removeItem(at: directory)
            jsonShareError = error.localizedDescription
        }
    }

    private func removeTemporaryJSONExport() {
        // Keep the file available throughout sharing, including destination UI.
        if let sharedJSONURL {
            try? FileManager.default.removeItem(at: sharedJSONURL.deletingLastPathComponent())
        }
        sharedJSONURL = nil
    }

    /// Every control that used to overlay the grid, now a normal
    /// bottom-anchored sibling in the VStack. Three rows: floor
    /// navigation (unchanged from before, just relocated), then a row
    /// mixing the three utility buttons with a horizontally-scrollable
    /// strip of all 8 object-kind toggles — "horiz scroll is fine" was
    /// Eddie's own call here rather than trying to cram 8 icons into a
    /// fixed-width row.
    private var controlBar: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                HStack(spacing: 14) {
                    floorNavButton("chevron.left") {
                        navigateFloor(to: max(1, mazeStore.currentMazeID - 1))
                    }
                    Text("Floor \(mazeStore.currentMazeID)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                    floorNavButton("chevron.right") {
                        navigateFloor(to: mazeStore.currentMazeID + 1)
                    }
                }
                HStack(spacing: 14) {
                    floorNavButton("minus.circle") {
                        stepNextMazeID(by: -1)
                    }
                    Text(mazeStore.nextMazeID.map { "Exit \u{2192} Floor \($0)" } ?? "Exit \u{2192} (none)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.7))
                    floorNavButton("plus.circle") {
                        stepNextMazeID(by: 1)
                    }
                }
            }

            #if DEBUG
            devFloorJumpRow
            #endif

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Button {
                    mazeStore.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(mazeStore.canUndo ? .black : .gray)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(!mazeStore.canUndo)

                Button {
                    mazeStore.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }

                // Eddie, Sept 8: export button for the "paste maps to
                // Claude, get back a static bundled version" workflow --
                // copies every floor drawn so far to the clipboard as
                // JSON, ready to paste into chat.
                Button {
                    if let json = mazeStore.exportLibraryJSON() {
                        UIPasteboard.general.string = json
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Button("SHARE JSON", action: shareBuildingJSON)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .background(.ultraThinMaterial, in: Capsule())

                // SAVE button removed (Sept 20 autosave pass): every
                // completed edit now persists itself automatically --
                // see MazeStore.autosaveAfterVersionChange() -- so the
                // manual "flush + mark as override" action this button
                // used to perform on demand now happens on its own
                // after every edit. saveCurrentFloorAsOverride() itself
                // is kept; autosave calls it now instead of this button.

                // RESET: discards this floor's saved local override (if
                // any) and reloads it from the bundled DefaultMazes.json
                // -- confirmed first since it can undo a SAVE, not just
                // in-session edits. See resetCurrentFloorToDefault()'s
                // own doc comment.
                Button {
                    showResetConfirmation = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }

            }

            HStack(spacing: 12) {
                Button { selectTool(.walls) } label: {
                    Label("Pencil", systemImage: "pencil")
                        .frame(minHeight: 44)
                        .padding(.horizontal, 12)
                        .background(selectedTool == .walls ? Color.orange.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityAddTraits(selectedTool == .walls ? .isSelected : [])
                Button { selectTool(.delete) } label: {
                    Label("Delete", systemImage: "trash")
                        .frame(minHeight: 44)
                        .padding(.horizontal, 12)
                        .background(selectedTool == .delete ? Color.red.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityAddTraits(selectedTool == .delete ? .isSelected : [])
            }
            toolSelector
            if selectedTool == .walls {
                HStack(spacing: 6) {
                    Image(systemName: "hand.draw.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.5))
                    Text("Wall paint: drag to open cells, drag across an open cell to erase it.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.black.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(selectedTool == .delete
                     ? "Tap a cell to choose which contents to delete. Floor geometry stays unchanged."
                     : "Tool stays active — tap more cells to place. Choose Pencil to edit floor geometry.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.black.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if selectedTool == .pickup {
                pickupControls
            }

            if selectedTool == .chute {
                chuteControls
            }

            // Exit Sign placement -- manual now (see exitDirectionToPlace's
            // own doc comment). One button per direction; the active one
            // is both "placement mode is on" and "this is the direction
            // that gets placed," so picking a different direction while
            // already in placement mode just repoints future taps without
            // a separate on/off toggle to fuss with.
            if selectedTool == .exit {
                HStack(spacing: 8) {
                    Text("Exit:")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.6))
                    ForEach(Direction.allCases, id: \.self) { direction in
                        Button {
                            let wasActive = exitDirectionToPlace == direction
                            clearPlacementModes()
                            exitDirectionToPlace = wasActive ? nil : direction
                            selectedTool = exitDirectionToPlace == nil ? .walls : .exit
                        } label: {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(exitDirectionToPlace == direction ? Color.red : .black)
                                .rotationEffect(.degrees(facingRotationDegrees(direction)))
                                .frame(width: 28, height: 28)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            // "You Are Here" wall map placement -- manually now (Eddie,
            // Sept 5: "let me control that and put maps wherever i
            // want"), same direction-toggle shape as Exit Signs just
            // above, blue instead of red so the two rows read as
            // different modes at a glance. Unlike an Exit Sign the wall
            // it hangs on has to actually BE a wall -- paint(at:) below
            // checks that before ever calling placeFloorMap.
            if selectedTool == .map {
                HStack(spacing: 8) {
                    Text("Map:")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.6))
                    ForEach(Direction.allCases, id: \.self) { direction in
                        Button {
                            let wasActive = floorMapDirectionToPlace == direction
                            clearPlacementModes()
                            floorMapDirectionToPlace = wasActive ? nil : direction
                            selectedTool = floorMapDirectionToPlace == nil ? .walls : .map
                        } label: {
                            Image(systemName: "map.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(floorMapDirectionToPlace == direction ? Color.blue : .black)
                                .rotationEffect(.degrees(facingRotationDegrees(direction)))
                                .frame(width: 28, height: 28)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            // Decorative Picture placement -- Eddie, Sept 9: "instead,
            // make the picture appear as a picture on the wall (like we
            // do to the mission and maps)... I will give you pictures
            // to put in a separate folder." Same 4-direction toggle
            // shape as the Map row just above (wall-required, same
            // place-vs-erase paint(at:) logic below), purple instead of
            // blue so the 2 rows read as different modes at a glance.
            // No kind/image to pick -- HallwayScene.build(fromMaze:)
            // grabs a random bundled photo at build time, this row only
            // ever decides where.
            if selectedTool == .picture {
                HStack(spacing: 8) {
                    Text("Picture:")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.6))
                    ForEach(Direction.allCases, id: \.self) { direction in
                        Button {
                            let wasActive = pictureDirectionToPlace == direction
                            clearPlacementModes()
                            pictureDirectionToPlace = wasActive ? nil : direction
                            selectedTool = pictureDirectionToPlace == nil ? .walls : .picture
                        } label: {
                            Image(systemName: "photo.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(pictureDirectionToPlace == direction ? Color.pink : .black)
                                .rotationEffect(.degrees(facingRotationDegrees(direction)))
                                .frame(width: 28, height: 28)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { mazeStore.picturesUseCameraRoll },
                        set: { mazeStore.setPicturesUseCameraRoll($0) }
                    )) {
                        Text(mazeStore.picturesUseCameraRoll ? "Camera roll" : "Folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .toggleStyle(.switch)
                    .tint(.pink)
                    .fixedSize()
                    .accessibilityLabel("Use camera roll for this floor's pictures")

                }
                // Picture Size (Sept 21) -- Small/Standard/Poster/Full
                // Length only; Mural is deliberately not offered here
                // yet (see PictureSize's own doc comment). Re-painting
                // an already-placed picture with a different size
                // selected here re-authors it in place, same
                // "whatever's currently selected wins" convention the
                // Light tool's brightnessControls already uses.
                HStack(spacing: 8) {
                    Text("Size:")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.6))
                    ForEach(PictureSize.allCases, id: \.self) { size in
                        Button {
                            session.pictureSizeToPlace = size
                        } label: {
                            Text(size.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(pictureSizeToPlace == size ? Color.pink : .black)
                                .frame(minWidth: 44, minHeight: 28)
                                .padding(.horizontal, 6)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .accessibilityLabel("Picture size \(size.displayName)")
                    }
                }
            }

            if selectedTool == .mirror {
                mirrorControls
            }

            if selectedTool == .light && lightTypeToPlace == .wall {
                wallLightControls
            }

            // Photo Booth placement (authoring only -- see MazeStore's
            // canPlacePhotoBooth/placePhotoBooth). Same two-stage shape as
            // the Light tool: a direction row picks the wall the booth
            // mounts on and activates the tool (mirrors mirrorControls'
            // toggle-button pattern), then, once active, a second row
            // picks which of the three EXISTING PhotoBoothExpression cases
            // the booth prompts for -- no new expressions added here.
            if selectedTool == .photoBooth {
                photoBoothControls
            }
            if selectedTool == .photoBooth {
                photoBoothExpressionControls
            }

            if selectedTool == .door {
                HStack(spacing: 8) {
                    Text("Door:")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.6))
                    ForEach(Direction.allCases, id: \.self) { direction in
                        Button {
                            let wasActive = doorDirectionToPlace == direction
                            clearPlacementModes()
                            doorDirectionToPlace = wasActive ? nil : direction
                            selectedTool = doorDirectionToPlace == nil ? .walls : .door
                        } label: {
                            Image(systemName: "door.left.hand.closed")
                                .foregroundStyle(doorDirectionToPlace == direction ? Color.brown : .black)
                                .rotationEffect(.degrees(facingRotationDegrees(direction)))
                                .frame(width: 28, height: 28)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .accessibilityLabel("Place door facing \(direction.rawValue)")
                    }
                }
            }

            // Window Room door placement (Eddie, Sept 15) -- same
            // per-direction toggle-button shape as the Door row just
            // above (deliberately: a Window Room door is the same
            // physical fixture as a bathroom/office door, just
            // leading somewhere different), reusing MazeStore's own
            // perimeter validation (placeWindowRoom silently no-ops
            // on an interior cell -- the preview outline above is
            // what actually surfaces that rejection to the person
            // painting, same as every other placement mode here).
            if selectedTool == .windowRoom {
                HStack(spacing: 8) {
                    Text("Window Room:")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.6))
                    ForEach(Direction.allCases, id: \.self) { direction in
                        Button {
                            let wasActive = windowRoomDirectionToPlace == direction
                            clearPlacementModes()
                            windowRoomDirectionToPlace = wasActive ? nil : direction
                            selectedTool = windowRoomDirectionToPlace == nil ? .walls : .windowRoom
                        } label: {
                            Image(systemName: "macwindow")
                                .foregroundStyle(windowRoomDirectionToPlace == direction ? Color.blue : .black)
                                .rotationEffect(.degrees(facingRotationDegrees(direction)))
                                .frame(width: 28, height: 28)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .accessibilityLabel("Place Window Room door facing \(direction.rawValue)")
                    }
                }
            }

            // Light source placement (Suzanimator lighting pass, Sept 19) --
            // pick WHICH existing physical light to paint, then tap
            // cells to place it. Only REAL runtime sources are listed:
            // ceiling (the omni fixture under the ceiling slab, the
            // original Sept 6 spotlight) and fire (the animated flame +
            // omni glow). Both sit centered in their cell, so there's
            // no direction axis -- the type choice IS the whole
            // configuration, per the What/How/Where editor rule.
            if selectedTool == .light {
                HStack(spacing: 8) {
                    Text("Light:")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.6))
                    ForEach(EditorLightType.allCases, id: \.self) { lightType in
                        Button {
                            let wasActive = lightTypeToPlace == lightType
                            clearPlacementModes()
                            lightTypeToPlace = wasActive ? nil : lightType
                            selectedTool = lightTypeToPlace == nil ? .walls : .light
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: lightType.iconName)
                                    .font(.system(size: 16, weight: .semibold))
                                Text(lightType.displayName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(lightTypeToPlace == lightType ? Color.orange : .black)
                            .frame(minWidth: 44, minHeight: 44)
                            .padding(.horizontal, 6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .accessibilityLabel("Place \(lightType.displayName) light")
                    }
                }
            }

            if selectedTool == .light && lightTypeToPlace == .fluorescent {
                Picker("Orientation", selection: $session.fluorescentOrientation) {
                    ForEach(FluorescentOrientation.allCases, id: \.self) { orientation in
                        Text(orientation.title).tag(orientation)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .onChange(of: session.fluorescentOrientation) { _ in
                    // The picker is the editor's explicit override: once
                    // touched, auto-orientation stops guiding this tool.
                    session.fluorescentOrientationExplicit = true
                }
            }

            if selectedTool == .light && lightTypeToPlace == .picture {
                pictureLightDirectionControls
            }

            if selectedTool == .light {
                brightnessControls
            }

            // Floor Mission sign -- Eddie, Sept 7: "you no longer have to
            // give me the control to place the mission statement in a
            // specific box... just follow the rule of one mission
            // statement per floor, and its always in front of the
            // elevator." MazeStore auto-seeds the one fixed mission
            // cell/wall on init and Clear, so all that's left here is
            // the pencil button that pops the mission-editor sheet for
            // typing the heading/mission body.
            HStack(spacing: 8) {
                Text("Mission:")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.6))
                Button {
                    missionHeadingDraft = mazeStore.missionHeading
                    missionBodyDraft = mazeStore.missionBody
                    showMissionEditor = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.purple)
                        .frame(width: 28, height: 28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }

            // Floor Surfaces -- Sept 26 (per-floor surface authoring):
            // structural floor authoring, same "belongs here, not the
            // live 3D Decorator" reasoning as the Mission row just
            // above, reusing its exact draft/sheet/pencil-button shape.
            HStack(spacing: 8) {
                Text("Surfaces:")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.6))
                Button {
                    wallTextureDraft = mazeStore.wallTexture
                    floorTextureDraft = mazeStore.floorTexture
                    ceilingTextureDraft = mazeStore.ceilingTexture
                    showSurfaceEditor = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.purple)
                        .frame(width: 28, height: 28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(white: 0.93))
    }

    #if DEBUG
    /// Dev-only floor-jump tool (Eddie, Sept 13): jump straight to any
    /// defined floor instead of tapping the chevrons N times or waiting
    /// through a heavy floor's intro. Compiled out of Release builds --
    /// this entire property (and its call site above) only exists in
    /// #if DEBUG, so it can never reach production/App-Store users even
    /// though GridEditorView itself is the same screen real players use
    /// as their in-game map.
    ///
    /// The action is exactly two calls: mazeStore.devJump(to:), which
    /// itself just wraps the canonical switchTo(id:) used by the chevrons
    /// and advanceToNextMaze() (so this floor lands in precisely the same
    /// fresh state a normal floor change would -- correct start/elevator
    /// position via startCoordinate, brand-new TapNavigationController so
    /// mission "Won" flags start false, all via ContentView's existing
    /// .onChange(of: mazeStore.currentMazeID)/.id(sceneVersion) rebuild --
    /// nothing new was built for any of that); then dismiss(), so the map
    /// screen closes and the 3D scene is what's on screen right after.
    private var devFloorJumpRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(1...mazeStore.floorCount, id: \.self) { floor in
                    Button("Floor \(floor)") {
                        mazeStore.devJump(to: floor)
                        dismiss()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hammer.fill")
                    Text("Jump to Floor")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 6))
            }

            Toggle(isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: MazeStore.devStartOnLastFloorKey) },
                set: { UserDefaults.standard.set($0, forKey: MazeStore.devStartOnLastFloorKey) }
            )) {
                Text("Start on last dev floor")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.black.opacity(0.6))
            }
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 4)
    }
    #endif

    private func inspectForDeletion(at location: CGPoint, cellSize: CGFloat) {
        let col = Int(location.x / cellSize)
        let row = Int(location.y / cellSize)
        guard col >= 0, col < columns, row >= 0, row < rows else { return }
        let coord = GridCoordinate(row: row, col: col)
        let items = mazeStore.removableContent(at: coord)
        guard !items.isEmpty else { return }
        deletionRequest = CellDeletionRequest(floorID: mazeStore.currentMazeID, coord: coord, items: items)
    }


    private var pictureLightDirectionControls: some View {
        HStack(spacing: 8) {
            Text("Direction:").font(.caption)
            ForEach([Direction.north, .east, .south, .west], id: \.self) { direction in
                Button {
                    session.pictureLightDirection = direction
                } label: {
                    Text(String(direction.rawValue.prefix(1)).uppercased())
                        .frame(width: 36, height: 36)
                        .foregroundStyle(session.pictureLightDirection == direction ? Color.orange : .primary)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .accessibilityLabel("Picture Light \(direction.rawValue)")
                .accessibilityAddTraits(session.pictureLightDirection == direction ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func pictureLightCellOverlay(_ coord: GridCoordinate, cellSize: CGFloat) -> some View {
        if selectedTool == .light, lightTypeToPlace == .picture,
           let direction = session.pictureLightDirection,
           mazeStore.canPlacePictureLight(direction, at: coord) {
            Rectangle().fill(Color.orange.opacity(0.3))
                .overlay(Rectangle().stroke(Color.orange, lineWidth: 2))
        }
    }


    private var brightnessControls: some View {
        // Sept 21 (0-10 brightness expansion): ceiling/fluorescent now
        // author over 0...10 (0 = OFF), wall/fire/picture stay at 1...5 --
        // the range shown here follows whichever light type is currently
        // selected (AuthoredLightKind.levelRange is the single source of
        // truth for that split; see LightBrightness.swift). No type picked
        // yet falls back to the original 1...5, same as before this change.
        let range = lightTypeToPlace?.authoredKind.levelRange ?? 1...5
        return HStack(spacing: 8) {
            Text("Brightness:")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.black.opacity(0.6))
            // 10-wide (ceiling/fluorescent) no longer reliably fits every
            // device width the way the original 5-wide row always did --
            // horizontal scroll keeps every level reachable without
            // changing how this looks anywhere it already fit.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(range), id: \.self) { level in
                        Button {
                            session.brightnessToPlace = level
                        } label: {
                            Text(String(level))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(session.brightnessToPlace == level ? Color.orange : .black)
                                .frame(width: 28, height: 28)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .accessibilityLabel("Brightness \(level)")
                        .accessibilityAddTraits(session.brightnessToPlace == level ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var wallLightControls: some View {
        HStack(spacing: 8) {
            Text("Direction:")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.black.opacity(0.6))
            ForEach([Direction.north, .east, .south, .west], id: \.self) { direction in
                Button {
                    clearPlacementModes()
                    wallLightDirectionToPlace = direction
                    lightTypeToPlace = .wall
                    selectedTool = .light
                } label: {
                    Text(String(direction.rawValue.prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(wallLightDirectionToPlace == direction ? Color.orange : .black)
                        .frame(width: 28, height: 28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .accessibilityLabel("Place wall light facing \(direction.rawValue)")
            }
        }
    }

    private var mirrorControls: some View {
        HStack(spacing: 8) {
            Text("Mirror:")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.black.opacity(0.6))
            ForEach(Direction.allCases, id: \.self) { direction in
                Button {
                    let wasActive = mirrorDirectionToPlace == direction
                    clearPlacementModes()
                    mirrorDirectionToPlace = wasActive ? nil : direction
                    selectedTool = mirrorDirectionToPlace == nil ? .walls : .mirror
                } label: {
                    Image(systemName: "person.crop.rectangle")
                        .foregroundStyle(mirrorDirectionToPlace == direction ? Color.cyan : .black)
                        .rotationEffect(.degrees(facingRotationDegrees(direction)))
                        .frame(width: 28, height: 28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .accessibilityLabel("Place mirror facing \(direction.rawValue)")
            }
        }
    }

    private var photoBoothControls: some View {
        HStack(spacing: 8) {
            Text("Photo Booth:")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.black.opacity(0.6))
            ForEach(Direction.allCases, id: \.self) { direction in
                Button {
                    let wasActive = photoBoothDirectionToPlace == direction
                    clearPlacementModes()
                    photoBoothDirectionToPlace = wasActive ? nil : direction
                    selectedTool = photoBoothDirectionToPlace == nil ? .walls : .photoBooth
                } label: {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(photoBoothDirectionToPlace == direction ? Color.cyan : .black)
                        .rotationEffect(.degrees(facingRotationDegrees(direction)))
                        .frame(width: 28, height: 28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .accessibilityLabel("Place photo booth facing \(direction.rawValue)")
            }
        }
    }

    /// Second-stage row, shown only once a direction has been picked above
    /// (same "pick what, then pick how" shape as the Light tool's type row
    /// + brightness row). Only the three EXISTING PhotoBoothExpression
    /// cases are offered -- this is authoring which existing prompt the
    /// booth uses, not adding new prompts.
    private var photoBoothExpressionControls: some View {
        HStack(spacing: 8) {
            Text("Expression:")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.black.opacity(0.6))
            ForEach([PhotoBoothExpression.smile, .mouthOpen, .eyebrowsRaised], id: \.self) { expression in
                Button {
                    photoBoothExpressionToPlace = expression
                } label: {
                    Text(photoBoothExpressionShortLabel(expression))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(photoBoothExpressionToPlace == expression ? Color.cyan : .black)
                        .frame(minWidth: 44, minHeight: 28)
                        .padding(.horizontal, 6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .accessibilityLabel("Photo booth expression \(expression.rawValue)")
            }
        }
    }

    private func photoBoothExpressionShortLabel(_ expression: PhotoBoothExpression) -> String {
        switch expression {
        case .smile: return "Smile"
        case .mouthOpen: return "Mouth Open"
        case .eyebrowsRaised: return "Eyebrows"
        }
    }

    /// The single tool switcher for the lower bar: a compact chip showing
    /// the current placement tool; tapping it opens a menu of every tool
    /// family. Picking a DIFFERENT tool clears any in-progress placement
    /// mode and shows that tool's panel; picking the same tool again is a
    /// no-op, so an active brush survives an accidental re-pick.
    private var toolSelector: some View {
        Menu {
            ForEach(EditorTool.allCases.filter { $0 != .walls && $0 != .delete }) { tool in
                Button {
                    selectTool(tool)
                } label: {
                    if tool == selectedTool {
                        Label(tool.displayName, systemImage: "checkmark")
                    } else {
                        Text(tool.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedTool.iconName)
                    .font(.system(size: 13, weight: .semibold))
                Text(selectedTool == .walls || selectedTool == .delete ? "Choose Object" : "Object: \(selectedTool.displayName)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.black.opacity(0.55), lineWidth: 1.5))
        }
    }

    /// Clears every placement mode at once -- the mutually-exclusive
    /// cascade each tool-toggle used to hand-roll inline. Still the same
    /// @State vars paint(at:) reads; selectedTool is synced separately by
    /// the callers so the two can never disagree.
    private func clearPlacementModes() {
        NSLog("%@", "[PLACEDIAG] CLEAR BRUSH tool=\(selectedTool.rawValue) object=\(String(describing: objectKindToPlace))")
        objectKindToPlace = nil
        destinationKindToPlace = nil
        exitDirectionToPlace = nil
        floorMapDirectionToPlace = nil
        pictureDirectionToPlace = nil
        mirrorDirectionToPlace = nil
        wallLightDirectionToPlace = nil
        doorDirectionToPlace = nil
        windowRoomDirectionToPlace = nil
        lightTypeToPlace = nil
        session.pictureLightDirection = nil
        photoBoothDirectionToPlace = nil
    }

    /// Switches which tool panel the lower bar shows. Moving to a
    /// different tool also clears any in-progress placement mode; picking
    /// the currently-visible tool does nothing, so a brush stays armed.
    private func selectTool(_ tool: EditorTool) {
        guard tool != selectedTool else { return }
        clearPlacementModes()
        selectedTool = tool
    }

    /// Pickup-object placement: the former trash/cash/envelope/Paint/Key
    /// toggles, consolidated under one tool. Envelope/Key additionally
    /// show the destination-room picker so a placed letter carries an
    /// address exactly as before.
    private var pickupControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    let wasActive = objectKindToPlace == .trashCan
                    clearPlacementModes()
                    objectKindToPlace = wasActive ? nil : .trashCan
                    selectedTool = objectKindToPlace == nil ? .walls : .pickup
                } label: {
                    Image(systemName: objectKindToPlace == .trashCan ? "trash.fill" : "trash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(objectKindToPlace == .trashCan ? Color.white : .black)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Button {
                    let wasActive = objectKindToPlace == .cash100
                    clearPlacementModes()
                    objectKindToPlace = wasActive ? nil : .cash100
                    selectedTool = objectKindToPlace == nil ? .walls : .pickup
                } label: {
                    Image(systemName: objectKindToPlace == .cash100 ? "dollarsign.circle.fill" : "dollarsign.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(objectKindToPlace == .cash100 ? Color(red: 0.8, green: 0.6, blue: 0.1) : .black)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Button {
                    let wasActive = objectKindToPlace == .envelope
                    clearPlacementModes()
                    objectKindToPlace = wasActive ? nil : .envelope
                    selectedTool = objectKindToPlace == nil ? .walls : .pickup
                } label: {
                    Image(systemName: objectKindToPlace == .envelope ? "envelope.fill" : "envelope")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(objectKindToPlace == .envelope ? Color.white : .black)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Button {
                    let wasActive = objectKindToPlace == .paintBucket
                    clearPlacementModes()
                    objectKindToPlace = wasActive ? nil : .paintBucket
                    selectedTool = objectKindToPlace == nil ? .walls : .pickup
                } label: {
                    Label("Paint", systemImage: "paintbrush.fill")
                        .foregroundStyle(objectKindToPlace == .paintBucket ? Color.blue : .black)
                }
                .accessibilityLabel("Place blue paint bucket")

                Button {
                    let wasActive = objectKindToPlace == .key
                    clearPlacementModes()
                    objectKindToPlace = wasActive ? nil : .key
                    selectedTool = objectKindToPlace == nil ? .walls : .pickup
                } label: {
                    Label("Key", systemImage: "key.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(objectKindToPlace == .key ? Color.orange : .black)
                }
            }

            if objectKindToPlace == .envelope || objectKindToPlace == .key {
                Picker("To room", selection: $session.mailRoomToPlace) {
                    Text("Auto address").tag(Int?.none)
                    // Sept 24 (decorative room doors): mailable rooms
                    // only -- a decorative door's number can never be
                    // written onto a letter (setItemRoom rejects it
                    // anyway; this keeps the picker honest about it).
                    ForEach(mazeStore.mailableRoomNumbers, id: \.self) { room in
                        Text("Rm \(room)").tag(Int?.some(room))
                    }
                }
                .frame(maxWidth: 280)
                .tint(.brown)
            }
        }
    }

    /// Delivery-chute placement: the former Chute row, consolidated under
    /// one tool -- place a surface a matching carried critter delivers
    /// onto.
    private var chuteControls: some View {
        HStack(spacing: 8) {
            Text("Chute:")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.black.opacity(0.6))
            Button {
                let wasActive = destinationKindToPlace == .trashCan
                clearPlacementModes()
                destinationKindToPlace = wasActive ? nil : .trashCan
                selectedTool = destinationKindToPlace == nil ? .walls : .chute
            } label: {
                Image(systemName: destinationKindToPlace == .trashCan ? "arrow.down.square.fill" : "arrow.down.square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(destinationKindToPlace == .trashCan ? Color.blue : .black)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            Button {
                let wasActive = destinationKindToPlace == .envelope
                clearPlacementModes()
                destinationKindToPlace = wasActive ? nil : .envelope
                selectedTool = destinationKindToPlace == nil ? .walls : .chute
            } label: {
                Image(systemName: destinationKindToPlace == .envelope ? "envelope.fill" : "envelope")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(destinationKindToPlace == .envelope ? Color(red: 0.55, green: 0.42, blue: 0.22) : .black)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Shared between the per-cell marker and the bottom-bar toggle
    /// buttons: heart/star render as their existing SF Symbol pair
    /// (filled when `active`, outline otherwise); every other kind
    /// renders as its emoji, dimmed a bit when not `active` so the
    /// toggle strip still shows which one (if any) is selected.
    @ViewBuilder
    private func objectGlyph(_ kind: ObjectKind, active: Bool, size: CGFloat) -> some View {
        if let filled = kind.editorFilledIconName, let outline = kind.editorOutlineIconName {
            Image(systemName: active ? filled : outline)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? kind.editorColor : .black)
        } else {
            Text(kind.editorEmoji)
                .font(.system(size: size))
                .opacity(active ? 1.0 : 0.55)
        }
    }

    // "location.north.fill" points up by default; row increases downward
    // (south) and col increases rightward (east) in grid coordinates, so
    // that's a 0-degree rotation baseline for north.
    private func facingRotationDegrees(_ direction: Direction) -> Double {
        switch direction {
        case .north: return 0
        case .east: return 90
        case .south: return 180
        case .west: return -90
        }
    }

    private func floorNavButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.black)
        }
    }

    /// Sept 22 (Start-on-Last-Dev-Floor, superseded fix): this used
    /// to write devLastJumpedFloorKey explicitly here, on the
    /// assumption these chevrons were the missing piece. They weren't
    /// the whole story -- advanceToNextMaze() (real gameplay elevator
    /// arrivals) called switchTo(id:) directly too and never wrote
    /// that key either, so the actual root cause was one level deeper.
    /// MazeStore.switchTo(id:) now writes devLastJumpedFloorKey itself
    /// (see its comment), since it's the one path every floor change
    /// already funnels through -- so this wrapper no longer needs its
    /// own copy of that write; it's kept only to route these chevrons
    /// through switchTo(id:) without also calling devJump(to:)'s
    /// dismiss-into-3D behavior, which these chevrons must NOT trigger
    /// (they're meant to keep you in the editor, browsing).
    private func navigateFloor(to id: Int) {
        mazeStore.switchTo(id: id)
    }

    /// Walks nextMazeID up or down by one floor — starting from the
    /// current floor's own number if nothing's set yet, so the first
    /// tap always proposes the next sequential floor (the common case),
    /// while still letting it land on anything else. Stepping below
    /// floor 1 clears it back to "no exit yet" rather than going
    /// negative.
    private func stepNextMazeID(by delta: Int) {
        let base = mazeStore.nextMazeID ?? mazeStore.currentMazeID
        let candidate = base + delta
        mazeStore.setNextMazeID(candidate >= 1 ? candidate : nil)
    }

    private func paint(at location: CGPoint, cellSize: CGFloat, isStart: Bool) {
        NSLog("%@", "[PLACEDIAG] PAINT ENTER point=\(location) isStart=\(isStart) tool=\(selectedTool.rawValue) object=\(String(describing: objectKindToPlace)) picture=\(String(describing: pictureDirectionToPlace)) door=\(String(describing: doorDirectionToPlace)) window=\(String(describing: windowRoomDirectionToPlace))")
        guard cellSize > 0 else { return }
        let col = Int(location.x / cellSize)
        let row = Int(location.y / cellSize)
        guard col >= 0, col < columns, row >= 0, row < rows else { return }
        let coord = GridCoordinate(row: row, col: col)

        if let direction = doorDirectionToPlace {
            guard mazeStore.isOpen(coord) else { return }
            if isStart { paintMode = mazeStore.roomDoors[coord]?.direction != direction }
            if paintMode {
                if mazeStore.roomDoors[coord]?.direction != direction { mazeStore.placeRoomDoor(direction, at: coord) }
            } else {
                mazeStore.removeRoomDoor(at: coord)
            }
            return
        }

        if let direction = windowRoomDirectionToPlace {
            guard mazeStore.isOpen(coord) else { return }
            if isStart { paintMode = mazeStore.windowRooms[coord]?.direction != direction }
            if paintMode {
                if mazeStore.windowRooms[coord]?.direction != direction { mazeStore.placeWindowRoom(direction, at: coord) }
            } else {
                mazeStore.removeWindowRoom(at: coord)
            }
            return
        }

        if let kind = objectKindToPlace {
            // TEMPORARY DIAGNOSTIC (Eddie, Sept 20, object-placement trace) -- remove after root cause is found.
            NSLog("%@", "[PLACEDIAG] paint(): objectKindToPlace branch ENTERED, kind=\(kind), coord=\(coord), isOpen=\(mazeStore.isOpen(coord)), isStart=\(isStart), currentObjectAtCoord=\(String(describing: mazeStore.object(at: coord)))")
            // Objects only make sense on real hallway cells — dragging
            // across a wall cell in this mode just does nothing there.
            guard mazeStore.isOpen(coord) else {
                NSLog("%@", "[PLACEDIAG] paint(): coord \(coord) is NOT open -- rejected, nothing placed")
                return
            }
            if isStart {
                // Starting on a cell that already holds exactly this
                // kind begins an erase stroke; anything else (empty, or
                // a different kind) begins a place-this-kind stroke.
                paintMode = mazeStore.object(at: coord) != kind || ((kind == .envelope || kind == .key) && mailRoomToPlace != nil && mazeStore.itemRooms[coord] != mailRoomToPlace)
            }
            NSLog("%@", "[PLACEDIAG] paint(): paintMode=\(paintMode) for coord=\(coord) kind=\(kind)")
            if paintMode {
                if mazeStore.object(at: coord) != kind {
                    mazeStore.placeObject(kind, at: coord)
                    NSLog("%@", "[PLACEDIAG] paint(): called mazeStore.placeObject(\(kind), at: \(coord)) -- now reads back as \(String(describing: mazeStore.object(at: coord)))")
                } else {
                    NSLog("%@", "[PLACEDIAG] paint(): SKIPPED placeObject because mazeStore.object(at: coord) already == kind")
                }
                if kind == .envelope || kind == .key, let room = mailRoomToPlace { mazeStore.setItemRoom(room, at: coord) }
            } else {
                if mazeStore.object(at: coord) != nil {
                    mazeStore.removeObject(at: coord)
                    NSLog("%@", "[PLACEDIAG] paint(): paintMode=false -- REMOVED object at \(coord)")
                }
            }
            return
        }

        if let kind = destinationKindToPlace {
            // Same open-cell-only rule as critters -- which wall it
            // actually ends up mounted on is HallwayScene.build(fromMaze:)'s
            // call, not this editor's.
            guard mazeStore.isOpen(coord) else { return }
            if isStart {
                paintMode = mazeStore.destination(at: coord) != kind
            }
            if paintMode {
                if mazeStore.destination(at: coord) != kind {
                    mazeStore.placeDestination(kind, at: coord)
                }
            } else {
                if mazeStore.destination(at: coord) != nil {
                    mazeStore.removeDestination(at: coord)
                }
            }
            return
        }

        if let direction = exitDirectionToPlace {
            // Same open-cell-only, place-vs-erase shape as objects and
            // destinations above: starting a stroke on a cell that
            // already points this exact direction erases it; starting
            // anywhere else (empty, or pointing a different direction)
            // places/repoints it to `direction`. That's what makes
            // tapping a DIFFERENT direction button and then tapping an
            // already-placed sign repoint it rather than erase it --
            // the stored direction no longer matches the active one.
            guard mazeStore.isOpen(coord) else { return }
            if isStart {
                paintMode = mazeStore.exitSignDirection(at: coord) != direction
            }
            if paintMode {
                if mazeStore.exitSignDirection(at: coord) != direction {
                    mazeStore.placeExitSign(direction, at: coord)
                }
            } else {
                if mazeStore.exitSignDirection(at: coord) != nil {
                    mazeStore.removeExitSign(at: coord)
                }
            }
            return
        }

        if let direction = floorMapDirectionToPlace {
            // Same open-cell, place-vs-erase shape as Exit Signs above
            // -- but a floor map hangs ON a wall, so it also needs the
            // neighbor in `direction` to actually be closed. Without
            // this check a map placed across an open doorway would
            // have nothing solid to mount on and HallwayScene.build(fromMaze:)
            // would just skip drawing it (see placeFloorMap's doc
            // comment), silently doing nothing -- better to refuse the
            // tap here than let Eddie place one that never shows up.
            guard mazeStore.isOpen(coord) else { return }
            let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
            guard !mazeStore.isOpen(neighbor) else { return }
            if isStart {
                paintMode = mazeStore.floorMapDirection(at: coord) != direction
            }
            if paintMode {
                if mazeStore.floorMapDirection(at: coord) != direction {
                    mazeStore.placeFloorMap(direction, at: coord)
                }
            } else {
                if mazeStore.floorMapDirection(at: coord) != nil {
                    mazeStore.removeFloorMap(at: coord)
                }
            }
            return
        }

        if let direction = mirrorDirectionToPlace {
            // Paint and erase mirrors on solid walls, just like pictures.
            guard mazeStore.isOpen(coord) else { return }
            let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
            guard !mazeStore.isOpen(neighbor) else { return }
            if isStart {
                paintMode = mazeStore.mirrorDirection(at: coord) != direction
            }
            if paintMode {
                if mazeStore.mirrorDirection(at: coord) != direction {
                    mazeStore.placeMirror(direction, at: coord)
                }
            } else {
                if mazeStore.mirrorDirection(at: coord) != nil {
                    mazeStore.removeMirror(at: coord)
                }
            }
            return
        }

        if let direction = wallLightDirectionToPlace {
            // Paint and erase wall-top lights on solid walls, exactly like
            // mirrors: the fixture hangs on the wall face, so the cell
            // must be open and the neighbor in `direction` must be solid.
            guard mazeStore.isOpen(coord) else { return }
            let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
            guard !mazeStore.isOpen(neighbor) else { return }
            if isStart {
                paintMode = (mazeStore.wallLightDirection(at: coord) != direction || mazeStore.lightBrightnessLevel(.wall, at: coord) != session.brightnessToPlace)
            }
            if paintMode {
                if (mazeStore.wallLightDirection(at: coord) != direction || mazeStore.lightBrightnessLevel(.wall, at: coord) != session.brightnessToPlace) {
                    mazeStore.placeWallLight(direction, at: coord, brightness: session.brightnessToPlace)
                }
            } else {
                if mazeStore.wallLightDirection(at: coord) != nil {
                    mazeStore.removeWallLight(at: coord)
                }
            }
            return
        }

        if let direction = photoBoothDirectionToPlace {
            // Paint and erase photo booths on solid walls, exactly like
            // wall lights above: the booth hangs on the wall face, so the
            // cell must be open and the neighbor in `direction` must be
            // solid. Re-authoring the expression at an already-placed
            // coord (direction unchanged) goes through placePhotoBooth's
            // own bypass; changing direction at an occupied coord is not
            // supported here, matching placeWallLight's own limitation.
            guard mazeStore.isOpen(coord) else { return }
            let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
            guard !mazeStore.isOpen(neighbor) else { return }
            if isStart {
                paintMode = (mazeStore.photoBoothDirection(at: coord) != direction || mazeStore.photoBooths[coord]?.expression != photoBoothExpressionToPlace)
            }
            if paintMode {
                if (mazeStore.photoBoothDirection(at: coord) != direction || mazeStore.photoBooths[coord]?.expression != photoBoothExpressionToPlace) {
                    mazeStore.placePhotoBooth(direction, expression: photoBoothExpressionToPlace, at: coord)
                }
            } else {
                if mazeStore.photoBoothDirection(at: coord) != nil {
                    mazeStore.deleteContent([.photoBooths], at: coord)
                }
            }
            return
        }

        if let direction = pictureDirectionToPlace {
            NSLog("%@", "[PLACEDIAG] PICTURE BRANCH coord=\(coord) direction=\(direction) open=\(mazeStore.isOpen(coord)) neighborOpen=\(mazeStore.isOpen(GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)))")
            // Same open-cell, place-vs-erase, wall-required shape as
            // floor maps above -- a picture hangs ON a wall too, so the
            // neighbor in `direction` has to actually be closed.
            guard mazeStore.isOpen(coord) else { return }
            let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
            guard !mazeStore.isOpen(neighbor) else { return }
            if isStart {
                // Sept 22 (wall-face authoring expansion): per-face now --
                // was "is THE picture at this coord pointed this way," now
                // "is there a picture on THIS specific face."
                paintMode = (!mazeStore.hasPicture(direction, at: coord) || mazeStore.pictureSize(direction: direction, at: coord) != pictureSizeToPlace)
            }
            if paintMode {
                if (!mazeStore.hasPicture(direction, at: coord) || mazeStore.pictureSize(direction: direction, at: coord) != pictureSizeToPlace) {
                    NSLog("%@", "[PLACEDIAG] CALL placePicture coord=\(coord) direction=\(direction)")
                    mazeStore.placePicture(direction, at: coord, size: pictureSizeToPlace)
                }
            } else {
                if mazeStore.hasPicture(direction, at: coord) {
                    mazeStore.removePicture(direction, at: coord)
                }
            }
            return
        }

        if let lightType = lightTypeToPlace {
            // Same open-cell-only, place-vs-erase shape as the Chute
            // toggle -- neither a ceiling light nor a fire mounts on a
            // wall, so there's no direction/neighbor check. Ceiling =
            // the existing omni fixture; fire = the existing flame +
            // omni glow (both persisted through the same fires/spotlights
            // fields the runtime already builds from).
            guard mazeStore.isOpen(coord) else { return }
            switch lightType {
            case .wall:
                return // The existing directional Wall Light placement branch above handles this.
            case .picture:
                guard let direction = session.pictureLightDirection,
                      mazeStore.canPlacePictureLight(direction, at: coord) else { return }
                mazeStore.placePictureLight(direction, at: coord, brightness: session.brightnessToPlace)
            case .fluorescent:
                // Auto-orientation: until the user explicitly pinches the
                // Orientation picker (fluorescentOrientationExplicit), a
                // just-add-to hallway cell's long axis is derived from the
                // corridor's own open sides (MazeStore.autoFluorescentOrientation),
                // so a freshly added fixture's two ends point at the two
                // hallway openings. Corners/junctions/dead ends return nil
                // and keep the picker orientation; a cell that already has
                // a fluorescent repaints with the picker orientation too.
                let auto = session.fluorescentOrientationExplicit
                    ? nil
                    : (mazeStore.fluorescentLights[coord] == nil
                       ? mazeStore.autoFluorescentOrientation(at: coord) : nil)
                let orientation = auto ?? session.fluorescentOrientation
                if isStart {
                    paintMode = mazeStore.fluorescentLights[coord] != orientation || mazeStore.lightBrightnessLevel(.fluorescent, at: coord) != session.brightnessToPlace
                }
                if paintMode {
                    mazeStore.placeFluorescent(orientation, at: coord, brightness: session.brightnessToPlace)
                } else {
                    mazeStore.removeFluorescent(at: coord)
                }
            case .ceiling:
                if isStart {
                    paintMode = (!mazeStore.hasSpotlight(coord) || mazeStore.lightBrightnessLevel(.ceiling, at: coord) != session.brightnessToPlace)
                }
                if paintMode {
                    if (!mazeStore.hasSpotlight(coord) || mazeStore.lightBrightnessLevel(.ceiling, at: coord) != session.brightnessToPlace) {
                        mazeStore.placeSpotlight(at: coord, brightness: session.brightnessToPlace)
                    }
                } else {
                    if mazeStore.hasSpotlight(coord) {
                        mazeStore.removeSpotlight(at: coord)
                    }
                }
            case .fire:
                if isStart {
                    paintMode = (!mazeStore.hasFire(coord) || mazeStore.lightBrightnessLevel(.fire, at: coord) != session.brightnessToPlace)
                }
                if paintMode {
                    if (!mazeStore.hasFire(coord) || mazeStore.lightBrightnessLevel(.fire, at: coord) != session.brightnessToPlace) {
                        mazeStore.placeFire(at: coord, brightness: session.brightnessToPlace)
                    }
                } else {
                    if mazeStore.hasFire(coord) {
                        mazeStore.removeFire(at: coord)
                    }
                }
            }
            return
        }

        guard selectedTool == .walls else { return }
        if isStart {
            paintMode = !mazeStore.isOpen(coord)
        }

        if paintMode {
            mazeStore.setOpen(coord)
        } else {
            mazeStore.setClosed(coord)
        }
    }

    /// The "pop open a text input field" Eddie asked for (Sept 7) --
    /// edits mazeStore.missionHeading/missionBody/missionObjectKind
    /// directly rather than hard-coding per-floor mission strings in an
    /// array, so any floor's mission can be authored right here in the
    /// editor. Drafts are local State, seeded on open and written back
    /// only on Save, so Cancel genuinely discards in-progress typing.
    private var missionEditorSheet: some View {
        NavigationView {
            Form {
                Section("Heading") {
                    TextField("e.g. 1st Floor", text: $missionHeadingDraft)
                }
                Section("Mission") {
                    TextEditor(text: $missionBodyDraft)
                        .frame(minHeight: 120)
                }
                Section("Completion") {
                    Picker("Requires delivering", selection: Binding(
                        get: { mazeStore.missionObjectKind },
                        set: { mazeStore.setMissionObjectKind($0) }
                    )) {
                        Text("Nothing").tag(ObjectKind?.none)
                        Text("Trash").tag(ObjectKind?.some(.trashCan))
                        Text("Mail").tag(ObjectKind?.some(.envelope))
                        Text("Keys & cash").tag(ObjectKind?.some(.key))
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Floor Mission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMissionEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        mazeStore.setMissionText(heading: missionHeadingDraft, body: missionBodyDraft)
                        showMissionEditor = false
                    }
                }
            }
        }
    }

    /// One independent picker per surface, each offering "Default"
    /// (nil -- clears the override, back to the existing Floor 1/
    /// Floor 2/theme fallback) plus every name HallwayScene.
    /// availableHallwayTextureNames() finds in the reusable library.
    /// Multiple floors picking the same name is exactly the point --
    /// this only ever writes a name string, never a file.
    private var surfaceEditorSheet: some View {
        let options = HallwayScene.availableHallwayTextureNames()
        return NavigationView {
            Form {
                Section("Wall") {
                    Picker("Wall texture", selection: $wallTextureDraft) {
                        Text("Default").tag(String?.none)
                        ForEach(options, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                }
                Section("Floor") {
                    Picker("Floor texture", selection: $floorTextureDraft) {
                        Text("Default").tag(String?.none)
                        ForEach(options, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                }
                Section("Ceiling") {
                    Picker("Ceiling texture", selection: $ceilingTextureDraft) {
                        Text("Default").tag(String?.none)
                        ForEach(options, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                }
            }
            .navigationTitle("Floor Surfaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSurfaceEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        mazeStore.setWallTexture(wallTextureDraft)
                        mazeStore.setFloorTexture(floorTextureDraft)
                        mazeStore.setCeilingTexture(ceilingTextureDraft)
                        showSurfaceEditor = false
                    }
                }
            }
        }
    }
}

#Preview {
    GridEditorView(mazeStore: MazeStore())
}

/// A full-screen, READ-ONLY look at the current floor's layout --
/// triggered by tapping the "You Are Here" map poster mounted on a wall
/// in the 3D scene. Eddie, Sept 6: "when you tap the wall map, let it
/// blow up and show what we show on the map editor screen... then tap
/// anywhere to shrink it back to the wall size." Deliberately NOT
/// GridEditorView itself reused directly -- that view's whole gridArea
/// is wired for drag-to-paint, which would let a mid-game glance at the
/// map accidentally punch a hole in a wall or drop an object. This
/// duplicates just the visual content of GridEditorView's cellView
/// (open/closed cells, the elevator, the you-are-here marker, and every
/// placed object/destination/exit-sign/floor-map/spotlight badge) with
/// no editing gesture anywhere -- any tap at all just calls onDismiss.
/// Lives in this file (rather than ContentView.swift) so it can reuse
/// GridEditorView.swift's own file-private ObjectKind styling
/// extensions (editorFilledIconName/editorEmoji/editorColor) instead of
/// duplicating those too.
struct FloorMapOverlayView: View {
    @ObservedObject var mazeStore: MazeStore
    let youAreHere: GridCoordinate
    let youAreHereFacing: Direction
    var onDismiss: () -> Void

    private let openColor = Color(red: 0.55, green: 0.62, blue: 0.7)
    // Same fixed 15x15 shape as GridEditorView (round 2: was 15x20) --
    // this is a picture of the SAME maze, not an independently-sized view.
    private let columns = 15
    private let rows = 15

    var body: some View {
        GeometryReader { geo in
            let cellSize = min(geo.size.width / CGFloat(columns), geo.size.height / CGFloat(rows))
            let gridItems = Array(repeating: GridItem(.fixed(cellSize), spacing: 0), count: columns)
            ZStack {
                Color.white
                LazyVGrid(columns: gridItems, spacing: 0) {
                    ForEach(0..<(rows * columns), id: \.self) { index in
                        let coord = GridCoordinate(row: index / columns, col: index % columns)
                        cellView(coord, cellSize: cellSize)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .statusBarHidden()
    }

    @ViewBuilder
    private func cellView(_ coord: GridCoordinate, cellSize: CGFloat) -> some View {
        Rectangle()
            .fill(mazeStore.isOpen(coord) ? openColor : Color.white)
            .frame(width: cellSize, height: cellSize)
            .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
            .overlay {
                if coord == youAreHere {
                    Rectangle()
                        .fill(Color.red.opacity(0.55))
                        .overlay(Rectangle().stroke(Color.red, lineWidth: 3))
                    Image(systemName: "location.north.fill")
                        .font(.system(size: cellSize * 0.5, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                        .rotationEffect(.degrees(facingRotationDegrees(youAreHereFacing)))
                }
            }
            .overlay {
                if let kind = mazeStore.object(at: coord) {
                    glyph(kind, size: cellSize * 0.45)
                        .padding(3)
                        .background(Color.white.opacity(0.85), in: Circle())
                        .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                }
            }
            .overlay {
                if let kind = mazeStore.destination(at: coord) {
                    VStack {
                        HStack {
                            Spacer()
                            glyph(kind, size: cellSize * 0.3)
                                .padding(2)
                                .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.4), lineWidth: 1))
                        }
                        Spacer()
                    }
                    .padding(3)
                }
            }
            .overlay {
                if let direction = mazeStore.exitSignDirection(at: coord) {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: cellSize * 0.32, weight: .heavy))
                                .foregroundStyle(Color.red)
                                .rotationEffect(.degrees(facingRotationDegrees(direction)))
                                .padding(2)
                                .background(Color.white.opacity(0.85), in: Circle())
                                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                            Spacer()
                        }
                    }
                    .padding(3)
                }
            }
            .overlay {
                if let direction = mazeStore.floorMapDirection(at: coord) {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "map.fill")
                                .font(.system(size: cellSize * 0.3, weight: .heavy))
                                .foregroundStyle(Color.blue)
                                .rotationEffect(.degrees(facingRotationDegrees(direction)))
                                .padding(2)
                                .background(Color.white.opacity(0.85), in: Circle())
                                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                        }
                    }
                    .padding(3)
                }
            }
            .overlay {
                if let direction = mazeStore.missionSignDirection(at: coord) {
                    Image(systemName: "signpost.right.fill")
                        .font(.system(size: cellSize * 0.32, weight: .heavy))
                        .foregroundStyle(Color.purple)
                        .rotationEffect(.degrees(facingRotationDegrees(direction)))
                        .padding(2)
                        .background(Color.white.opacity(0.85), in: Circle())
                        .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                }
            }
            .overlay {
                if mazeStore.hasSpotlight(coord) {
                    VStack {
                        HStack {
                            Image(systemName: "lightbulb.fill")
                                .font(.system(size: cellSize * 0.3, weight: .heavy))
                                .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.15))
                                .padding(2)
                                .background(Color.white.opacity(0.85), in: Circle())
                                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(3)
                }
            }
            .overlay {
                // Eddie, Sept 8: this used to just mark
                // mazeStore.startCoordinate, back when the start and
                // the elevator were always literally the same cell --
                // floor 1 split them apart (Sept 7), and this screen
                // kept marking only the start (the dead end you walk
                // in from), leaving the ACTUAL elevator -- always the
                // fixed MazeStore.elevatorCoordinate, whether or not
                // this floor's drawing even reaches it -- completely
                // invisible here. That's almost certainly why floor
                // 1's hallway ended up not actually connected to the
                // elevator: there was no way to see where it even was
                // while drawing. Both show now, distinctly, whenever
                // they differ.
                if coord == MazeStore.elevatorCoordinate {
                    Text("🛗")
                        .font(.system(size: cellSize * 0.55))
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                }
                if coord == mazeStore.startCoordinate, coord != MazeStore.elevatorCoordinate {
                    Text("🚪")
                        .font(.system(size: cellSize * 0.55))
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                }
            }
    }

    /// Always the "active"/filled look -- unlike GridEditorView's own
    /// objectGlyph (which also draws a dimmed toggle-button state),
    /// everything drawn here is something genuinely placed on the maze,
    /// never a mode picker.
    @ViewBuilder
    private func glyph(_ kind: ObjectKind, size: CGFloat) -> some View {
        if let filled = kind.editorFilledIconName {
            Image(systemName: filled)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(kind.editorColor)
        } else {
            Text(kind.editorEmoji)
                .font(.system(size: size))
        }
    }

    private func facingRotationDegrees(_ direction: Direction) -> Double {
        switch direction {
        case .north: return 0
        case .east: return 90
        case .south: return 180
        case .west: return -90
        }
    }
}
