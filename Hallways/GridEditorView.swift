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

import SwiftUI

/// UI-only presentation details for each object kind, kept here rather
/// than on ObjectKind itself since that enum lives in MazeStore.swift
/// as part of the data model and shouldn't need to know about SwiftUI
/// Colors or SF Symbol names.
private extension ObjectKind {
    var editorFilledIconName: String {
        switch self {
        case .heart: return "heart.fill"
        case .star: return "star.fill"
        }
    }
    var editorOutlineIconName: String {
        switch self {
        case .heart: return "heart"
        case .star: return "star"
        }
    }
    var editorColor: Color {
        switch self {
        case .heart: return .red
        case .star: return .orange
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
    /// new floor-nav chevrons below let you browse to a DIFFERENT floor
    /// while this is open, and without this check the player's marker
    /// would keep showing on whatever floor you've since navigated to,
    /// which isn't where they actually are. nil when there's no 3D
    /// session running yet (matches youAreHere's own nil case).
    var youAreHereMazeID: Int? = nil

    private let targetCellSize: CGFloat = 50 // roughly icon-sized, comfortably tappable
    private let openColor = Color(red: 0.55, green: 0.62, blue: 0.7)

    // The first cell touched in a drag decides whether the whole stroke
    // paints or erases; every cell the finger crosses afterward follows
    // that same mode. A tap is just a one-cell drag, so this handles both.
    @State private var paintMode = true
    @State private var dragActive = false
    /// Two different things a drag can do to a cell now: paint/erase
    /// walls (nil, the default), or place/remove a specific kind of
    /// object on an already-open cell. Two toggle buttons below (one
    /// per ObjectKind) switch which, mutually exclusive with each other
    /// and with wall painting; the drag gesture itself is unchanged
    /// either way, just branches on this.
    @State private var objectKindToPlace: ObjectKind? = nil

    // Grid geometry used to be recomputed as plain `let`s inside the
    // GeometryReader closure, which re-runs on every single render —
    // including mid-drag, since every painted cell mutates mazeStore
    // and triggers one. Painting a cell near the current edge grows the
    // maze's bounds, which immediately shrank cellSize for the very
    // next .onChanged call of the SAME drag stroke — so a finger that
    // hadn't moved would suddenly map to a completely different, often
    // far-flung cell the instant the grid resized underneath it. That's
    // what was showing up as a diagonal trail of tiny disconnected
    // "rooms" the moment a stroke reached the border. Now geometry
    // lives in @State and is deliberately frozen for the whole stroke —
    // recomputed only once the finger lifts (or on first appear, a
    // rotation, or a Clear/Undo that changes the maze from outside a
    // drag) — so every touch during one continuous drag is always
    // interpreted against the same cell size it started with.
    @State private var columns = 1
    @State private var rows = 1
    @State private var cellSize: CGFloat = 50

    var body: some View {
        GeometryReader { geo in
            // Guard against the zero-size layout pass GeometryReader can
            // report before the real screen size settles (e.g. during a
            // fullScreenCover transition).
            let width = max(geo.size.width, targetCellSize)
            let height = max(geo.size.height, targetCellSize)
            let gridItems = Array(repeating: GridItem(.fixed(cellSize), spacing: 0), count: columns)

            ZStack {
                Color.white.ignoresSafeArea()

                LazyVGrid(columns: gridItems, spacing: 0) {
                    ForEach(0..<(rows * columns), id: \.self) { index in
                        let coord = GridCoordinate(row: index / columns, col: index % columns)
                        Rectangle()
                            .fill(mazeStore.isOpen(coord) ? openColor : Color.white)
                            .frame(width: cellSize, height: cellSize)
                            .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                            .overlay {
                                // "You are here" — bright red, drawn under
                                // the S/E labels so both can show if they
                                // ever land on the same cell (fresh spawn,
                                // or standing right at the end marker).
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
                                    Image(systemName: kind.editorFilledIconName)
                                        .font(.system(size: cellSize * 0.45))
                                        .foregroundStyle(kind.editorColor)
                                }
                            }
                            .overlay {
                                // S = where you spawn in 3D, E = the far
                                // marker (opposite corner) you'll see as a
                                // glowing ball once you're inside — same
                                // cells HallwayScene.build(fromMaze:) uses.
                                if coord == mazeStore.startCoordinate {
                                    Text("S")
                                        .font(.system(size: cellSize * 0.5, weight: .heavy, design: .rounded))
                                        .foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                                } else if coord == mazeStore.endCoordinate {
                                    Text("E")
                                        .font(.system(size: cellSize * 0.5, weight: .heavy, design: .rounded))
                                        .foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                                }
                            }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !dragActive {
                                mazeStore.snapshotForUndo()
                            }
                            paint(at: value.location, columns: columns, rows: rows, cellSize: cellSize, isStart: !dragActive)
                            dragActive = true
                        }
                        .onEnded { _ in
                            dragActive = false
                            recomputeGeometry(width: width, height: height)
                        }
                )
            }
            .onAppear {
                recomputeGeometry(width: width, height: height)
            }
            .onChange(of: mazeStore.version) { _ in
                // Ignored while a drag is live — see the @State doc
                // comment above. Catches Clear/Undo (which change the
                // maze from a button tap, not a drag) and any other
                // out-of-drag edit.
                if !dragActive {
                    recomputeGeometry(width: width, height: height)
                }
            }
            .onChange(of: geo.size) { _ in
                // Rotation / window resize — always safe to reflow
                // immediately since it can't happen mid-touch.
                recomputeGeometry(width: width, height: height)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
        }
        .overlay(alignment: .top) {
            // Which floor you're EDITING (independent of which floor
            // you're actually standing on in 3D, if any) plus where
            // this floor's end cell leads to. Reuses the exact same
            // MazeStore.switchTo(id:) the 3D side calls when you walk
            // into an elevator/end cell — editing floor N then N+1 is
            // literally the same operation as playing through them.
            VStack(spacing: 8) {
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
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 50)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 12) {
                Button {
                    mazeStore.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(mazeStore.canUndo ? .black : .gray)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(!mazeStore.canUndo)

                Button {
                    mazeStore.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }

                // One toggle per object kind — tapping one turns
                // object-placing mode on for that kind (and off for any
                // other kind, and off for wall painting); tapping the
                // active one again goes back to wall painting. Filled +
                // colored icon shows which mode (if any) is active.
                ForEach(ObjectKind.allCases, id: \.self) { kind in
                    Button {
                        objectKindToPlace = (objectKindToPlace == kind) ? nil : kind
                    } label: {
                        Image(systemName: objectKindToPlace == kind ? kind.editorFilledIconName : kind.editorOutlineIconName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(objectKindToPlace == kind ? kind.editorColor : .black)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
            }
            .padding()
        }
        .statusBarHidden()
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

    /// Recomputes columns/rows/cellSize to fit the maze's current
    /// bounds (or the screen, whichever needs more room) — the only
    /// place these three ever change. See the @State doc comment above
    /// for why this is never called mid-drag.
    private func recomputeGeometry(width: CGFloat, height: CGFloat) {
        let screenFillColumns = max(1, Int(width / targetCellSize))
        let screenFillRows = max(1, Int(height / targetCellSize))
        let mazeMaxRow = mazeStore.cells.map { $0.row }.max() ?? 0
        let mazeMaxCol = mazeStore.cells.map { $0.col }.max() ?? 0
        let newColumns = max(screenFillColumns, mazeMaxCol + 2)
        let newRows = max(screenFillRows, mazeMaxRow + 2)
        columns = newColumns
        rows = newRows
        cellSize = min(width / CGFloat(newColumns), height / CGFloat(newRows))
    }

    private func paint(at location: CGPoint, columns: Int, rows: Int, cellSize: CGFloat, isStart: Bool) {
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
