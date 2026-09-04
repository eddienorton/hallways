//
//  MazeStore.swift
//  Hallways
//
//  The single source of truth for the CURRENTLY LOADED maze/floor: which
//  grid cells are "open" (walkable). GridEditorView paints into this; the
//  3D scene (HallwayScene.build(fromMaze:)) is generated straight from
//  it. Same data, two views — a flat, instantly-editable map and the
//  first-person space built from exactly what it says.
//
//  Multi-floor support: the app is really a building, one hand-authored
//  maze per floor, identified by id == the floor number (Eddie: "itll
//  let us build them and save them under an id which is simply the
//  floor number... 1 thru whatever"). MazeStore only ever holds ONE
//  floor's cells live at a time (everything above — the editor, the 3D
//  scene builder — is unaware multiple floors even exist); switchTo(id:)
//  is what swaps which floor is currently loaded, persisting whichever
//  one you're leaving first. Reaching a maze's end cell in 3D calls
//  advanceToNextMaze(), which is just switchTo(id: nextMazeID) — the
//  same mechanism the grid editor's floor-nav chevrons use to let you
//  hop between floors to edit them. Deliberately NOT hardcoded to always
//  advance by exactly one floor: nextMazeID is per-maze, ordinary data,
//  not a computed "+1" — Eddie's explicit ask, so a floor can eventually
//  point somewhere other than "the next sequential number" without any
//  code changing, only the authored data.
//
//  Persisted to a single mazes.json in the app's Documents directory —
//  one JSON array of {id, cells, nextMazeID, objects} records, loaded
//  whole and kept in memory as `library`, written back out on every
//  save(). Plenty small for hand-authored mazes; revisit only if that
//  ever stops being true.
//
//  Per-cell random color was tried and dropped — it made the hallway look
//  dark and blocky instead of like a hallway. Back to one consistent
//  look (the original brick/dark material) in 3D, one simple color in 2D.
//

import Foundation
import Combine
import SwiftUI

struct GridCoordinate: Hashable, Codable {
    let row: Int
    let col: Int
}

/// Which kind of pick-up-able object sits on a cell. Adding a new kind
/// is meant to stay cheap — a new case here, a new make*Node(size:) in
/// HallwayScene, one new case in that switch — no new per-object data
/// model or persistence work, which was the whole point of Eddie's
/// "checkers-style simple rule" pitch: variety should come from more
/// shapes, not more code paths.
enum ObjectKind: String, Codable, CaseIterable {
    case heart
    case star
}

/// One placed object, as persisted: which cell it's on and which kind
/// it is.
private struct ObjectPlacement: Codable {
    var coord: GridCoordinate
    var kind: ObjectKind
}

/// One floor's worth of maze data, exactly as persisted. `cells` is an
/// array (not a Set) purely because that's what JSONEncoder/Decoder
/// round-trip cleanly — MazeStore converts to/from Set on load/save.
private struct MazeRecord {
    var id: Int
    var cells: [GridCoordinate]
    var nextMazeID: Int?
    /// Which of this floor's cells hold an object, and which kind.
    var objects: [ObjectPlacement]
}

it doesnt entirely make extension MazeRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case id, cells, nextMazeID, objects, objectCells
    }

    // Hand-written so older mazes.json shapes still load cleanly
    // instead of failing to decode outright:
    //  - a file saved before objects existed at all (Eddie's floors 1
    //    and 2 from the multi-floor testing round) has neither key —
    //    both decodeIfPresent calls come back nil, objects ends up [].
    //  - a file saved by the very first object-placement slice (heart
    //    only, no ObjectKind yet) has the OLD key "objectCells": a
    //    plain [GridCoordinate] array with no kind attached — every
    //    entry there was a heart, since heart was the only kind that
    //    existed, so it's read as one ObjectPlacement(kind: .heart)
    //    per coordinate.
    //  - a file saved by this version has the new "objects" key
    //    (coord + kind together) and is read directly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        cells = try container.decode([GridCoordinate].self, forKey: .cells)
        nextMazeID = try container.decodeIfPresent(Int.self, forKey: .nextMazeID)
        if let placements = try container.decodeIfPresent([ObjectPlacement].self, forKey: .objects) {
            objects = placements
        } else if let legacyHeartCells = try container.decodeIfPresent([GridCoordinate].self, forKey: .objectCells) {
            objects = legacyHeartCells.map { ObjectPlacement(coord: $0, kind: .heart) }
        } else {
            objects = []
        }
    }

    // Writing this by hand too: CodingKeys carries an extra
    // "objectCells" case (the old on-disk key, needed above so a
    // legacy save still decodes) that has no matching stored
    // property — Swift's automatic Encodable synthesis requires every
    // CodingKeys case to correspond 1:1 with a stored property, so
    // that extra case silently disables the synthesized encode(to:)
    // entirely (the "does not conform to protocol 'Encodable'" error).
    // This only ever writes the CURRENT shape — "objectCells" is a
    // read-only legacy key, never written back out.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cells, forKey: .cells)
        try container.encodeIfPresent(nextMazeID, forKey: .nextMazeID)
        try container.encode(objects, forKey: .objects)
    }
}

/// Thin load/save wrapper around a single mazes.json in Documents.
/// Kept separate from MazeStore itself so the "how it's stored" concern
/// (file I/O, JSON shape) doesn't tangle with "what's currently loaded
/// and being edited/played" (MazeStore's actual job).
private enum MazeLibrary {
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mazes.json")
    }

    static func loadAll() -> [Int: MazeRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([MazeRecord].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    static func saveAll(_ library: [Int: MazeRecord]) {
        let records = library.values.sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

final class MazeStore: ObservableObject {
    // Hardcoded starter maze — only ever used to seed floor 1 the very
    // first time the app runs with no mazes.json on disk yet, so
    // launching still drops you straight into a real maze instead of
    // an empty grid. Once anything's been saved, this is never
    // consulted again. Shape: a cross with a long vertical hallway (the
    // main run, top to bottom) crossed by a shorter horizontal one
    // (left to right) — a real 4-way intersection where they meet (3
    // choices once you arrive), two dead-end arms off the horizontal,
    // and a start/end pair at the top and bottom of the long vertical
    // hallway.
    private static let starterMaze: Set<GridCoordinate> = {
        var cells: Set<GridCoordinate> = []
        let centerRow = 15
        let centerCol = 5
        let verticalArmLength = 15   // rows extending up/down from center — the long run
        let horizontalArmLength = 5  // cols extending left/right from center — the cross street
        for row in (centerRow - verticalArmLength)...(centerRow + verticalArmLength) {
            cells.insert(GridCoordinate(row: row, col: centerCol))
        }
        for col in (centerCol - horizontalArmLength)...(centerCol + horizontalArmLength) {
            cells.insert(GridCoordinate(row: centerRow, col: col))
        }
        return cells
    }()

    @Published private(set) var cells: Set<GridCoordinate>

    /// Cells on the current floor holding a pick-up-able object, and
    /// which kind each one is. Empty for now on every floor until
    /// placed via GridEditorView's object toggles — this is the first
    /// slice of the pick-up/deliver mechanic Eddie and Claude worked
    /// out (see the design notes): this pass only covers PLACING
    /// objects and seeing them in 3D, not carrying or delivering them
    /// yet.
    @Published private(set) var objects: [GridCoordinate: ObjectKind]

    /// Bumped on every edit AND on every floor switch. ContentView only
    /// re-reads this against sceneVersion when the grid editor is
    /// dismissed (not live on every paint stroke) so drawing stays
    /// smooth and the 3D scene doesn't rebuild mid-drag — see
    /// ContentView's fullScreenCover(onDismiss:). A floor switch is
    /// caught separately and immediately via currentMazeID (below),
    /// since that one's never supposed to wait for the editor to close.
    @Published private(set) var version = 0

    /// Which floor is currently loaded into `cells`. Changes ONLY on an
    /// actual floor switch (switchTo/advanceToNextMaze), never on a
    /// plain cell edit — so ContentView can watch this alone to know
    /// "the 3D scene needs to rebuild right now, don't wait for the
    /// editor to close," without that watch also firing on every paint
    /// stroke.
    @Published private(set) var currentMazeID: Int

    /// Which floor reaching this one's end cell leads to, or nil if
    /// this is (for now) the last floor / not linked up yet. Ordinary
    /// per-maze data, not a computed "+1" — see the file header.
    @Published private(set) var nextMazeID: Int?

    /// World-space size of one cell — matches the corridor width feel
    /// from Prototype 2, just squared off into rooms instead of a fixed
    /// hallway. Same for every floor for now.
    let cellSize: CGFloat = 3.2
    let wallHeight: CGFloat = 3.0

    private var library: [Int: MazeRecord]

    init() {
        let loaded = MazeLibrary.loadAll()
        if let firstID = loaded.keys.min() {
            library = loaded
            currentMazeID = firstID
            cells = Set(loaded[firstID]?.cells ?? [])
            nextMazeID = loaded[firstID]?.nextMazeID
            objects = Dictionary(uniqueKeysWithValues: (loaded[firstID]?.objects ?? []).map { ($0.coord, $0.kind) })
        } else {
            // Nothing on disk yet — first-ever launch. Seed floor 1
            // with the starter maze and write it out immediately so
            // this branch is never hit again on this device.
            let starter = MazeRecord(id: 1, cells: Array(Self.starterMaze), nextMazeID: nil, objects: [])
            library = [1: starter]
            currentMazeID = 1
            cells = Self.starterMaze
            nextMazeID = nil
            objects = [:]
            MazeLibrary.saveAll(library)
        }
    }

    /// The cell the camera spawns in when you walk the maze — the
    /// top-left-most open cell (lowest row, then lowest column). Same
    /// rule HallwayScene.build(fromMaze:) uses to place the camera, so
    /// this always matches where you actually land in 3D.
    var startCoordinate: GridCoordinate? {
        cells.min(by: { ($0.row, $0.col) < ($1.row, $1.col) })
    }

    /// The opposite corner of whatever's drawn — bottom-right-most open
    /// cell. There's no real "goal" gameplay yet beyond reaching it (and
    /// now, moving on to nextMazeID if one's set), just a marker so
    /// start and end are visible and consistent between the 2D and 3D
    /// views.
    var endCoordinate: GridCoordinate? {
        cells.max(by: { ($0.row, $0.col) < ($1.row, $1.col) })
    }

    func isOpen(_ coord: GridCoordinate) -> Bool {
        cells.contains(coord)
    }

    func hasObject(_ coord: GridCoordinate) -> Bool {
        objects[coord] != nil
    }

    func object(at coord: GridCoordinate) -> ObjectKind? {
        objects[coord]
    }

    /// Places `kind` on `coord` (only meaningful on an already-open
    /// cell — a wall can't hold anything), overwriting whatever was
    /// there before. Bumps version like any other edit, so the
    /// existing version-vs-sceneVersion rebuild check in ContentView
    /// picks it up the same way a wall edit does, no separate sync
    /// path needed.
    func placeObject(_ kind: ObjectKind, at coord: GridCoordinate) {
        guard cells.contains(coord) else { return }
        objects[coord] = kind
        version += 1
    }

    func removeObject(at coord: GridCoordinate) {
        guard objects[coord] != nil else { return }
        objects[coord] = nil
        version += 1
    }

    func setOpen(_ coord: GridCoordinate) {
        guard !cells.contains(coord) else { return }
        cells.insert(coord)
        version += 1
    }

    func setClosed(_ coord: GridCoordinate) {
        guard cells.contains(coord) else { return }
        cells.remove(coord)
        objects.removeValue(forKey: coord) // a wall can't hold an object
        version += 1
    }

    /// Points this floor's exit somewhere else (or nowhere, if delta
    /// carries it below floor 1 — see GridEditorView's stepper). Doesn't
    /// touch cells/version — the editor's grid geometry doesn't care
    /// about this — but does persist right away, since there's no
    /// "leaving the floor" moment to hang a save off of the way cell
    /// edits get one via the grid editor's dismiss.
    func setNextMazeID(_ id: Int?) {
        guard id != nextMazeID else { return }
        nextMazeID = id
        save()
    }

    /// Writes whatever's currently loaded (cells + nextMazeID + objects)
    /// back into the in-memory library and out to disk. Called whenever
    /// the grid editor closes, and internally by switchTo() before it
    /// loads a different floor in, so nothing painted is ever lost
    /// mid-session.
    func save() {
        let placements = objects.map { ObjectPlacement(coord: $0.key, kind: $0.value) }
        library[currentMazeID] = MazeRecord(id: currentMazeID, cells: Array(cells), nextMazeID: nextMazeID, objects: placements)
        MazeLibrary.saveAll(library)
    }

    /// Swaps which floor is currently loaded — persists whatever floor
    /// you're leaving first, then loads `id`'s cells in (or starts a
    /// brand-new, empty floor if `id` has never been painted on before).
    /// This is the ONE mechanism behind both the grid editor's floor-nav
    /// chevrons (editing a different floor) and advanceToNextMaze()
    /// (gameplay reaching an elevator/end cell) — same operation either
    /// way, just triggered from two different places.
    func switchTo(id: Int) {
        guard id != currentMazeID else { return }
        save()
        currentMazeID = id
        if let record = library[id] {
            cells = Set(record.cells)
            nextMazeID = record.nextMazeID
            objects = Dictionary(uniqueKeysWithValues: record.objects.map { ($0.coord, $0.kind) })
        } else {
            cells = []
            nextMazeID = nil
            objects = [:]
        }
        undoStack = [] // undo history is per-floor, doesn't carry across a switch
        version += 1
    }

    /// Wired to TapNavigationController.onReachedEnd — walking into the
    /// current floor's end cell calls this. Does nothing if this floor
    /// isn't linked to another one yet, which is also exactly why a
    /// floor authored without a next-floor link just quietly stays on
    /// the existing "You made it!" screen instead of going anywhere.
    func advanceToNextMaze() {
        guard let next = nextMazeID else { return }
        switchTo(id: next)
    }

    // MARK: - Undo / Clear

    private var undoStack: [(cells: Set<GridCoordinate>, objects: [GridCoordinate: ObjectKind])] = []
    private let maxUndoDepth = 30

    /// Snapshots the current maze so a later undo() can restore it.
    /// Call once before a batch of edits (a whole drag stroke, or
    /// Clear) rather than per-cell, so Undo reverts a whole gesture at
    /// once instead of one cell at a time. Captures cells AND objects
    /// together so undo works correctly no matter which mode (wall
    /// painting or object placing) the stroke was in.
    func snapshotForUndo() {
        undoStack.append((cells: cells, objects: objects))
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst()
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        cells = previous.cells
        objects = previous.objects
        version += 1
    }

    /// Wipes the whole maze — walls and objects both. Undoable like
    /// any other edit — snapshots first, so a stray tap on Clear isn't
    /// a disaster.
    func clear() {
        guard !cells.isEmpty else { return }
        snapshotForUndo()
        cells = []
        objects = [:]
        version += 1
    }
}
