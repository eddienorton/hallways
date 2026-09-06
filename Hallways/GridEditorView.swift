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
        }
    }
}

struct GridEditorView: View {
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

    /// Fixed at 15 columns by 20 rows — Eddie's own ask, replacing the
    /// old grid that silently grew (and shrank every cell) whenever you
    /// painted near its current edge. Being a plain, non-@State
    /// constant is what actually eliminates that whole class of bug: the
    /// old code recomputed columns/rows from the maze's own painted
    /// bounds on every mazeStore mutation, including mid-drag, so
    /// painting a cell near the edge could resize the grid underneath
    /// the very finger stroke that caused it — a still-unmoved finger
    /// would suddenly land on a totally different cell once the grid
    /// reflowed. With a fixed size there's nothing left to recompute:
    /// cellSize below still adapts to whatever screen space is actually
    /// available, but columns/rows themselves never move again.
    private let columns = 15
    private let rows = 20

    // The first cell touched in a drag decides whether the whole stroke
    // paints or erases; every cell the finger crosses afterward follows
    // that same mode. A tap is just a one-cell drag, so this handles both.
    @State private var paintMode = true
    @State private var dragActive = false
    /// Two different things a drag can do to a cell now: paint/erase
    /// walls (nil, the default), or place/remove a specific kind of
    /// object on an already-open cell. One toggle button per ObjectKind
    /// in the bottom bar switches which, mutually exclusive with each
    /// other and with wall painting; the drag gesture itself is
    /// unchanged either way, just branches on this.
    @State private var objectKindToPlace: ObjectKind? = nil
    /// Same idea, for placing a DESTINATION on a cell instead of a
    /// critter -- mutually exclusive with objectKindToPlace (and with
    /// wall painting): picking a destination kind clears any active
    /// critter kind and vice versa, so there's only ever one placement
    /// mode active at a time.
    @State private var destinationKindToPlace: ObjectKind? = nil
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
    @State private var exitDirectionToPlace: Direction? = nil
    /// Same idea once more, for placing a "You Are Here" floor map --
    /// mutually exclusive with all 3 other placement modes and with
    /// wall painting. Eddie, Sept 5: "let me control that and put maps
    /// wherever i want" -- HallwayScene.build(fromMaze:) no longer
    /// auto-mounts one at `start`, this screen picks both the cell and
    /// the wall now, same split as Exit Signs above. Unlike an Exit
    /// Sign, the wall a map hangs on has to actually BE a wall --
    /// paint(at:) checks that before ever calling placeFloorMap.
    @State private var floorMapDirectionToPlace: Direction? = nil
    /// Same idea once more, for placing a ceiling spotlight -- mutually
    /// exclusive with all 4 other placement modes and with wall
    /// painting. Eddie, Sept 6: "how difficult to have a spotlight that
    /// we could place on the ceiling of a box?" No direction to pick
    /// (it hangs dead-center in the ceiling), so this is a plain on/off
    /// toggle like the Chute one, not a 4-direction row like Exit/Map.
    @State private var placingSpotlight = false

    var body: some View {
        VStack(spacing: 0) {
            gridArea
            controlBar
        }
        .statusBarHidden()
    }

    /// The grid itself and nothing else — no controls drawn over any
    /// part of it anymore. cellSize is computed fresh from whatever
    /// space GeometryReader reports (so it also handles rotation with
    /// no extra plumbing), rather than tracked in @State — with columns
    /// and rows now fixed, there's no longer anything that needs
    /// freezing mid-drag the way the old cellSize @State did.
    private var gridArea: some View {
        GeometryReader { geo in
            let cellSize = min(geo.size.width / CGFloat(columns), geo.size.height / CGFloat(rows))
            let gridItems = Array(repeating: GridItem(.fixed(cellSize), spacing: 0), count: columns)

            // How far the grid's own top-left corner sits from geo's,
            // in whichever dimension ISN'T the constraining one --
            // real letterbox margin, not a rounding fudge. On iPhone
            // the fixed 15x20 ratio is close enough to the screen's
            // own tall, narrow shape that cellSize ends up width-
            // constrained and this is ~0 (no horizontal margin at
            // all). iPad's screen is much less tall relative to its
            // width, so cellSize goes height-constrained instead,
            // leaving real empty space on both left and right --
            // exactly the situation Eddie hit, Sept 5: "in the ipad
            // version... when you tap in a box it affects the box to
            // the right of it," never wrong on iPhone. The previous
            // code assumed attaching the gesture directly to the
            // LazyVGrid meant SwiftUI would report value.location
            // already adjusted for however it centered a smaller grid
            // inside a bigger GeometryReader -- true on iPhone (no
            // adjustment was ever needed there to look right), but not
            // reliably true once there's real horizontal letterboxing
            // to account for. Computing the margin explicitly and
            // subtracting it before ever dividing by cellSize doesn't
            // depend on that assumption at all.
            let gridWidth = cellSize * CGFloat(columns)
            let gridHeight = cellSize * CGFloat(rows)
            let offsetX = (geo.size.width - gridWidth) / 2
            let offsetY = (geo.size.height - gridHeight) / 2

            ZStack {
                Color.white.ignoresSafeArea(edges: .top)

                LazyVGrid(columns: gridItems, spacing: 0) {
                    ForEach(0..<(rows * columns), id: \.self) { index in
                        let coord = GridCoordinate(row: index / columns, col: index % columns)
                        cellView(coord, cellSize: cellSize)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                // Attached to the ZStack, not the LazyVGrid -- Color.white
                // above is what makes the ZStack itself fill geo's FULL
                // size unambiguously, so value.location here is reliably
                // relative to geo's own top-left corner, (0, 0), full
                // stop. offsetX/offsetY above are then subtracted before
                // ever dividing by cellSize, rather than assuming
                // SwiftUI already did that adjustment.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragActive {
                            mazeStore.snapshotForUndo()
                        }
                        let adjusted = CGPoint(x: value.location.x - offsetX, y: value.location.y - offsetY)
                        paint(at: adjusted, cellSize: cellSize, isStart: !dragActive)
                        dragActive = true
                    }
                    .onEnded { _ in
                        dragActive = false
                    }
            )
        }
        .ignoresSafeArea(edges: .top)
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
                // "You are here" — bright red, drawn under the S/E
                // labels so both can show if they ever land on the same
                // cell (fresh spawn, or standing right at the end
                // marker).
                if coord == youAreHere && youAreHereMazeID == mazeStore.currentMazeID {
                    Rectangle()
                        .fill(Color.red.opacity(0.55))
                        .overlay(Rectangle().stroke(Color.red, lineWidth: 3))
                    if let youAreHereFacing {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: cellSize * 0.5, weight: .heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 1.5)
                            .rotationEffect(.degrees(facingRotationDegrees(youAreHereFacing)))
                    }
                }
            }
            .overlay {
                if let kind = mazeStore.object(at: coord) {
                    // Eddie, Sept 5: the trash can was "sooooo faint" here
                    // -- same root cause as the ORIGINAL 3D-scene report
                    // from earlier tonight, just never fixed on this
                    // screen: the wastebasket emoji itself renders pale
                    // gray/silver, and openColor (this cell's own fill)
                    // is a medium slate-blue-gray -- two similar tones
                    // with almost no contrast, and emoji ignore
                    // foregroundStyle so there's no tint to fix. Same
                    // white backing chip the destination marker just
                    // below already uses for exactly this reason, just
                    // applied here too now.
                    objectGlyph(kind, active: true, size: cellSize * 0.45)
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
                            objectGlyph(kind, active: true, size: cellSize * 0.3)
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
                // "You Are Here" wall map -- bottom-right corner, the
                // one spot destination (top-right) and exit sign
                // (bottom-left) leave free.
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
                // Ceiling spotlight -- top-left corner, the one spot
                // destination (top-right), exit sign (bottom-left), and
                // floor map (bottom-right) leave free.
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
                if coord == mazeStore.startCoordinate {
                    Text("🛗")
                        .font(.system(size: cellSize * 0.55))
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                }
            }
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
                        mazeStore.switchTo(id: max(1, mazeStore.currentMazeID - 1))
                    }
                    Text("Floor \(mazeStore.currentMazeID)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                    floorNavButton("chevron.right") {
                        mazeStore.switchTo(id: mazeStore.currentMazeID + 1)
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

                Divider().frame(height: 28)

                // One toggle per object kind — tapping one turns
                // object-placing mode on for that kind (and off for any
                // other kind, and off for wall painting); tapping the
                // active one again goes back to wall painting. A
                // filled/colored glyph shows which mode (if any) is
                // active.
                Button {
                    objectKindToPlace = (objectKindToPlace == .trashCan) ? nil : .trashCan
                    if objectKindToPlace != nil { destinationKindToPlace = nil; exitDirectionToPlace = nil; floorMapDirectionToPlace = nil; placingSpotlight = false }
                } label: {
                    // Was green -- Eddie, Sept 5, twice now: "extremely
                    // difficult to see" against this same
                    // .ultraThinMaterial circle every other toggle sits
                    // on. White is what already reads fine everywhere
                    // else in this app on that exact material (see
                    // ContentView's own top-bar icon buttons), same fix
                    // already applied to the 3D trash can pickup itself.
                    Image(systemName: objectKindToPlace == .trashCan ? "trash.fill" : "trash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(objectKindToPlace == .trashCan ? Color.white : .black)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }

                // Second Hallway Activity, Sept 5: instant-absorb cash
                // -- same toggle mechanism as trash, just a different
                // ObjectKind, since MazeStore.objects already supports
                // placing any kind at any open cell with no new data
                // model needed.
                Button {
                    objectKindToPlace = (objectKindToPlace == .cash100) ? nil : .cash100
                    if objectKindToPlace != nil { destinationKindToPlace = nil; exitDirectionToPlace = nil; floorMapDirectionToPlace = nil; placingSpotlight = false }
                } label: {
                    Image(systemName: objectKindToPlace == .cash100 ? "dollarsign.circle.fill" : "dollarsign.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(objectKindToPlace == .cash100 ? Color(red: 0.8, green: 0.6, blue: 0.1) : .black)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }

            // Second row, same 8 kinds -- but placing THIS toggles
            // where a critter of that kind gets DELIVERED (a destination
            // mounted on one of the cell's walls, chosen automatically by
            // HallwayScene.build(fromMaze:)), not another critter to pick
            // up. Square badge instead of a circle so the two rows read
            // as different modes at a glance.
            HStack(spacing: 8) {
                Text("Chute:")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.6))
                Button {
                    destinationKindToPlace = (destinationKindToPlace == .trashCan) ? nil : .trashCan
                    if destinationKindToPlace != nil { objectKindToPlace = nil; exitDirectionToPlace = nil; floorMapDirectionToPlace = nil; placingSpotlight = false }
                } label: {
                    Image(systemName: destinationKindToPlace == .trashCan ? "arrow.down.square.fill" : "arrow.down.square")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(destinationKindToPlace == .trashCan ? Color.blue : .black)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }

            // Exit Sign placement -- manual now (see exitDirectionToPlace's
            // own doc comment). One button per direction; the active one
            // is both "placement mode is on" and "this is the direction
            // that gets placed," so picking a different direction while
            // already in placement mode just repoints future taps without
            // a separate on/off toggle to fuss with.
            HStack(spacing: 8) {
                Text("Exit:")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.6))
                ForEach(Direction.allCases, id: \.self) { direction in
                    Button {
                        exitDirectionToPlace = (exitDirectionToPlace == direction) ? nil : direction
                        if exitDirectionToPlace != nil { objectKindToPlace = nil; destinationKindToPlace = nil; floorMapDirectionToPlace = nil; placingSpotlight = false }
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

            // "You Are Here" wall map placement -- manually now (Eddie,
            // Sept 5: "let me control that and put maps wherever i
            // want"), same direction-toggle shape as Exit Signs just
            // above, blue instead of red so the two rows read as
            // different modes at a glance. Unlike an Exit Sign the wall
            // it hangs on has to actually BE a wall -- paint(at:) below
            // checks that before ever calling placeFloorMap.
            HStack(spacing: 8) {
                Text("Map:")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.6))
                ForEach(Direction.allCases, id: \.self) { direction in
                    Button {
                        floorMapDirectionToPlace = (floorMapDirectionToPlace == direction) ? nil : direction
                        if floorMapDirectionToPlace != nil { objectKindToPlace = nil; destinationKindToPlace = nil; exitDirectionToPlace = nil; placingSpotlight = false }
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

            // Ceiling spotlight placement (Eddie, Sept 6). Plain on/off
            // toggle, same shape as the Chute row above -- no direction
            // to pick since this hangs dead-center in the ceiling, not
            // on a wall.
            HStack(spacing: 8) {
                Text("Light:")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.6))
                Button {
                    placingSpotlight.toggle()
                    if placingSpotlight { objectKindToPlace = nil; destinationKindToPlace = nil; exitDirectionToPlace = nil; floorMapDirectionToPlace = nil }
                } label: {
                    Image(systemName: placingSpotlight ? "lightbulb.fill" : "lightbulb")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(placingSpotlight ? Color(red: 0.95, green: 0.75, blue: 0.15) : .black)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(white: 0.93))
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
        guard cellSize > 0 else { return }
        let col = Int(location.x / cellSize)
        let row = Int(location.y / cellSize)
        guard col >= 0, col < columns, row >= 0, row < rows else { return }
        let coord = GridCoordinate(row: row, col: col)

        if let kind = objectKindToPlace {
            // Objects only make sense on real hallway cells — dragging
            // across a wall cell in this mode just does nothing there.
            guard mazeStore.isOpen(coord) else { return }
            if isStart {
                // Starting on a cell that already holds exactly this
                // kind begins an erase stroke; anything else (empty, or
                // a different kind) begins a place-this-kind stroke.
                paintMode = mazeStore.object(at: coord) != kind
            }
            if paintMode {
                if mazeStore.object(at: coord) != kind {
                    mazeStore.placeObject(kind, at: coord)
                }
            } else {
                if mazeStore.object(at: coord) != nil {
                    mazeStore.removeObject(at: coord)
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

        if placingSpotlight {
            // Same open-cell-only, place-vs-erase shape as the Chute
            // toggle -- no direction/neighbor-wall check needed since a
            // ceiling light doesn't mount on anything.
            guard mazeStore.isOpen(coord) else { return }
            if isStart {
                paintMode = !mazeStore.hasSpotlight(coord)
            }
            if paintMode {
                if !mazeStore.hasSpotlight(coord) {
                    mazeStore.placeSpotlight(at: coord)
                }
            } else {
                if mazeStore.hasSpotlight(coord) {
                    mazeStore.removeSpotlight(at: coord)
                }
            }
            return
        }

        if isStart {
            paintMode = !mazeStore.isOpen(coord)
        }

        if paintMode {
            mazeStore.setOpen(coord)
        } else {
            mazeStore.setClosed(coord)
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
    // Same fixed 15x20 shape as GridEditorView -- this is a picture of
    // the SAME maze, not an independently-sized view.
    private let columns = 15
    private let rows = 20

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
                if coord == mazeStore.startCoordinate {
                    Text("🛗")
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
