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
    // Real Font Awesome (free, solid style) icons pulled in via
    // SVGPathParser instead of hand-drawn/computed paths, pinned to
    // Font Awesome 6.7.2 for reproducibility -- see HallwayScene's
    // makeIconNode and each icon's own path-data constant.
    case iceCream
    case appleWhole
    case babyCarriage
    case snowman
    case personBiking
    case cakeCandles
    // The first "Hallway Activity" (Eddie's own term, Sept 5): trash
    // you pick up and dump at ANY destination, no matching required --
    // see TapNavigationController's depositIfPresent. The editor
    // (GridEditorView) now only ever places this one kind, both as the
    // pickup object and as what a destination cell is configured to
    // "accept" (that stored kind is otherwise unused by delivery now).
    case trashCan
    // Second Hallway Activity (Eddie, Sept 5): cash you walk into and
    // absorb instantly -- no carrying, no elevator gate, no delivery.
    // Its dollar value lives on cashValue (below); picking it up adds
    // straight to MazeStore.moneyTotal, a running total for the whole
    // building/run (deliberately NOT reset per floor, unlike the
    // objects/destinations/undo state switchTo() swaps out). This is
    // the mechanic Eddie described as "very likely be the whole point
    // of the game" -- floor = age bracket, final total = simulated
    // retirement savings. Starting with one denomination to prove the
    // mechanic out before adding more ($500, $1000, ...), same
    // add-a-case pattern as every other kind.
    case cash100
}

/// Non-nil only for cash kinds -- the dollar amount that gets added to
/// MazeStore.moneyTotal on pickup. This is also how
/// TapNavigationController tells "instant-absorb cash" apart from
/// "carry it, deliver it later" trash: everything else stays nil.
extension ObjectKind {
    var cashValue: Int? {
        switch self {
        case .cash100: return 100
        default: return nil
        }
    }
}

/// A simple emoji-only glyph per kind, for spots that just need a
/// quick recognizable icon without pulling in GridEditorView's own
/// SF-Symbol-pair-plus-color styling (which is deliberately private to
/// that file's editor toolbar) -- right now that's the in-game
/// collected-items HUD. Every kind renders here even heart/star, which
/// have their own SF Symbols elsewhere, since a HUD strip reads better
/// as one consistent glyph style than a mix of two.
extension ObjectKind {
    var displayEmoji: String {
        switch self {
        case .heart: return "❤️"
        case .star: return "⭐"
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
}

/// One placed object, as persisted: which cell it's on and which kind
/// it is.
private struct ObjectPlacement: Codable {
    var coord: GridCoordinate
    var kind: ObjectKind
}

/// One placed Exit Sign, as persisted: which cell it's mounted at and
/// which way it points. Manually placed in GridEditorView now (Eddie,
/// Sept 5, round 5: "let me lay the exit signs down manually... doing
/// it auto in the code comes up with funky layouts where theres a
/// bunch of exits in a row") -- HallwayScene.build(fromMaze:) no
/// longer computes placement or direction itself, it just draws
/// exactly what's in this dictionary, the same "editor decides where,
/// build() just draws it" split objects/destinations already use.
private struct ExitSignPlacement: Codable {
    var coord: GridCoordinate
    var direction: Direction
}

/// One placed "You Are Here" floor map, as persisted: which cell it's
/// mounted at and which wall it hangs on. Manually placed in
/// GridEditorView now (Eddie, Sept 5: "let me control that and put
/// maps wherever i want") -- same "editor decides where, build() just
/// draws it" split as ExitSignPlacement above. Unlike an Exit Sign,
/// the wall a floor map mounts on has to actually BE a wall (nothing
/// to hang a picture on across an open doorway), which
/// HallwayScene.build(fromMaze:) and GridEditorView's paint(at:) both
/// check for at their own layer -- this struct itself just stores
/// whatever was placed, same as ExitSignPlacement does.
private struct FloorMapPlacement: Codable {
    var coord: GridCoordinate
    var direction: Direction
}

// spotlights themselves need no struct -- a plain [GridCoordinate], same
// as `cells` -- since a ceiling light has no direction/kind of its own
// (Eddie, Sept 6: "how difficult to have a spotlight that we could
// place on the ceiling of a box"), it's just on or off per cell.

/// One floor's worth of maze data, exactly as persisted. `cells` is an
/// array (not a Set) purely because that's what JSONEncoder/Decoder
/// round-trip cleanly — MazeStore converts to/from Set on load/save.
private struct MazeRecord {
    var id: Int
    var cells: [GridCoordinate]
    var nextMazeID: Int?
    /// Which of this floor's cells hold an object, and which kind.
    var objects: [ObjectPlacement]
    /// Which of this floor's cells have a destination mounted on one of
    /// their walls, and which kind of critter each one accepts. Brand
    /// new alongside destinations themselves -- no legacy on-disk shape
    /// to migrate from, so this one's just decodeIfPresent-or-empty.
    var destinations: [ObjectPlacement]
    /// Which of this floor's cells hold a manually-placed Exit Sign,
    /// and which way each one points. Brand new, same
    /// decodeIfPresent-or-empty treatment as destinations above -- no
    /// legacy on-disk shape to migrate from.
    var exitSigns: [ExitSignPlacement]
    /// Which of this floor's cells hold a manually-placed "You Are
    /// Here" floor map, and which wall each one hangs on. Same
    /// decodeIfPresent-or-empty treatment, no legacy shape to migrate.
    var floorMaps: [FloorMapPlacement]
    /// Which of this floor's cells hold a manually-placed ceiling
    /// spotlight. Same decodeIfPresent-or-empty treatment, no legacy
    /// shape to migrate.
    var spotlights: [GridCoordinate]
}

extension MazeRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case id, cells, nextMazeID, objects, objectCells, destinations, exitSigns, floorMaps, spotlights
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
        destinations = try container.decodeIfPresent([ObjectPlacement].self, forKey: .destinations) ?? []
        exitSigns = try container.decodeIfPresent([ExitSignPlacement].self, forKey: .exitSigns) ?? []
        floorMaps = try container.decodeIfPresent([FloorMapPlacement].self, forKey: .floorMaps) ?? []
        spotlights = try container.decodeIfPresent([GridCoordinate].self, forKey: .spotlights) ?? []
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
        try container.encode(destinations, forKey: .destinations)
        try container.encode(exitSigns, forKey: .exitSigns)
        try container.encode(floorMaps, forKey: .floorMaps)
        try container.encode(spotlights, forKey: .spotlights)
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
    /// The one elevator for the entire building -- same physical
    /// (row, col) on EVERY floor, not derived from that floor's own
    /// shape. Eddie, Sept 5: "if you want to imagine the physical
    /// makeup of this building, each floor would be a grid in a
    /// different position... doesnt make sense for a building whose
    /// outside should basically be a box. so... one elevator, one
    /// coord. that is the starting point and ending point for all
    /// floors." A plain static constant, not per-floor data -- "im
    /// picturing the building metadata to end up in static blocks
    /// right in the code (no host needed for that part)."
    ///
    /// Nothing enforces that a given floor's hand-drawn hallway
    /// actually routes through this cell -- deliberately, per Eddie,
    /// Sept 5: "i dont care about imposing rules and error messages in
    /// the map editor... i dont do that [break it]." If a floor's
    /// `cells` genuinely doesn't include this coordinate, that floor
    /// spawns you somewhere with no walkable geometry and no open
    /// neighbor to walk toward -- a real, silent dead end on his end,
    /// not a crash, just worth knowing the failure mode looks like
    /// that rather than an error message.
    static let elevatorCoordinate = GridCoordinate(row: 10, col: 7)

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

    /// Cells whose wall carries a destination -- the deposit half of
    /// the pick-up/deliver mechanic. Manually placed in GridEditorView
    /// like objects are; HallwayScene.build(fromMaze:) picks which
    /// solid wall of the cell to actually mount it on (never chosen
    /// here -- this is just "which cell, which kind").
    @Published private(set) var destinations: [GridCoordinate: ObjectKind]

    /// Cells on the current floor holding a manually-placed Exit Sign,
    /// and which way each one points -- placed the same way objects/
    /// destinations are (GridEditorView toggles + paint), not computed
    /// by HallwayScene.build(fromMaze:) anymore. Eddie, Sept 5, round
    /// 5: the auto-placed version "comes up with funky layouts where
    /// theres a bunch of exits in a row."
    @Published private(set) var exitSigns: [GridCoordinate: Direction]

    /// Cells on the current floor holding a manually-placed "You Are
    /// Here" floor map, and which wall each one hangs on -- placed the
    /// same way Exit Signs are (GridEditorView toggles + paint), not
    /// auto-mounted at `start` by HallwayScene.build(fromMaze:)
    /// anymore. Eddie, Sept 5: "let me control that and put maps
    /// wherever i want."
    @Published private(set) var floorMaps: [GridCoordinate: Direction]

    /// Cells on the current floor holding a manually-placed ceiling
    /// spotlight -- placed the same way Exit Signs/floor maps are
    /// (GridEditorView toggle + paint), drawn by
    /// HallwayScene.build(fromMaze:) as a real SCNLight aimed straight
    /// down, not a decal or prop. No direction of its own (it hangs
    /// dead-center in the ceiling, not on a wall), so unlike floorMaps
    /// this is just a Set, same shape as `objects`/`cells` themselves.
    /// Eddie, Sept 6: "how difficult to have a spotlight that we could
    /// place on the ceiling of a box?"
    @Published private(set) var spotlights: Set<GridCoordinate>

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

    /// Running total of all cash absorbed this run, across every floor
    /// -- deliberately NOT part of any per-floor state (cells/objects/
    /// destinations/undo all get swapped out by switchTo(); this
    /// doesn't). Not yet persisted to disk, so it resets if the app is
    /// force-quit mid-run — acceptable for now since there's no broader
    /// "save game" system yet either; revisit once one exists.
    @Published private(set) var moneyTotal = 0

    /// Called by TapNavigationController the instant a cash object is
    /// walked into (see collectObjectIfPresent) -- the only way
    /// moneyTotal ever changes.
    func addMoney(_ amount: Int) {
        moneyTotal += amount
    }

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
            destinations = Dictionary(uniqueKeysWithValues: (loaded[firstID]?.destinations ?? []).map { ($0.coord, $0.kind) })
            exitSigns = Dictionary(uniqueKeysWithValues: (loaded[firstID]?.exitSigns ?? []).map { ($0.coord, $0.direction) })
            floorMaps = Dictionary(uniqueKeysWithValues: (loaded[firstID]?.floorMaps ?? []).map { ($0.coord, $0.direction) })
            spotlights = Set(loaded[firstID]?.spotlights ?? [])
        } else {
            // Nothing on disk yet — first-ever launch. Seed floor 1
            // with the starter maze and write it out immediately so
            // this branch is never hit again on this device.
            let starter = MazeRecord(id: 1, cells: Array(Self.starterMaze), nextMazeID: nil, objects: [], destinations: [], exitSigns: [], floorMaps: [], spotlights: [])
            library = [1: starter]
            currentMazeID = 1
            cells = Self.starterMaze
            nextMazeID = nil
            objects = [:]
            destinations = [:]
            exitSigns = [:]
            floorMaps = [:]
            spotlights = []
            MazeLibrary.saveAll(library)
        }
    }

    /// The cell the camera spawns in when you walk the maze -- the
    /// building's one fixed elevatorCoordinate (see its own doc
    /// comment), not derived from this floor's own shape anymore.
    /// Same rule HallwayScene.build(fromMaze:) uses to place the
    /// camera, so this always matches where you actually land in 3D.
    /// nil only when the floor is genuinely empty (nothing drawn at
    /// all yet) -- an actual maze on a real floor always resolves
    /// here, whether or not that floor's hallway happens to reach it.
    var startCoordinate: GridCoordinate? {
        cells.isEmpty ? nil : Self.elevatorCoordinate
    }

    /// You get off the elevator, and you're standing right where you
    /// need to get back to for the next one -- Eddie, Sept 5: "when
    /// you arrive at a level, you get off the elevator, and youre
    /// right at the point you need to get to to get to the next
    /// level." Literally the same cell as startCoordinate now, not a
    /// second derived point -- kept as its own property (rather than
    /// deleting it and using startCoordinate everywhere) purely so
    /// call sites can keep saying "start" or "end," whichever reads
    /// clearer in context, without it meaning anything different.
    var endCoordinate: GridCoordinate? {
        startCoordinate
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

    func hasDestination(_ coord: GridCoordinate) -> Bool {
        destinations[coord] != nil
    }

    func destination(at coord: GridCoordinate) -> ObjectKind? {
        destinations[coord]
    }

    func hasExitSign(_ coord: GridCoordinate) -> Bool {
        exitSigns[coord] != nil
    }

    func exitSignDirection(at coord: GridCoordinate) -> Direction? {
        exitSigns[coord]
    }

    func hasFloorMap(_ coord: GridCoordinate) -> Bool {
        floorMaps[coord] != nil
    }

    func floorMapDirection(at coord: GridCoordinate) -> Direction? {
        floorMaps[coord]
    }

    func hasSpotlight(_ coord: GridCoordinate) -> Bool {
        spotlights.contains(coord)
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

    /// Places a destination of `kind` on `coord` (same open-cell-only
    /// rule as placeObject) -- which wall it actually ends up mounted
    /// on is HallwayScene.build(fromMaze:)'s call, not this one's.
    func placeDestination(_ kind: ObjectKind, at coord: GridCoordinate) {
        guard cells.contains(coord) else { return }
        destinations[coord] = kind
        version += 1
    }

    func removeDestination(at coord: GridCoordinate) {
        guard destinations[coord] != nil else { return }
        destinations[coord] = nil
        version += 1
    }

    /// Places (or repoints, if one's already there) an Exit Sign at
    /// `coord`, aimed `direction` -- same open-cell-only rule as
    /// objects/destinations. GridEditorView's 4 direction toggles call
    /// this; HallwayScene.build(fromMaze:) just draws whatever's here
    /// now, no placement logic of its own.
    func placeExitSign(_ direction: Direction, at coord: GridCoordinate) {
        guard cells.contains(coord) else { return }
        exitSigns[coord] = direction
        version += 1
    }

    func removeExitSign(at coord: GridCoordinate) {
        guard exitSigns[coord] != nil else { return }
        exitSigns[coord] = nil
        version += 1
    }

    /// Places (or repoints) a "You Are Here" floor map at `coord`,
    /// hung on `direction`'s wall -- same open-cell-only rule as
    /// objects/destinations/exit signs. WHETHER `direction` is
    /// actually a solid wall to hang it on isn't checked here (same
    /// division of labor as placeExitSign not checking its direction
    /// is open) -- GridEditorView's paint(at:) checks before ever
    /// calling this, and HallwayScene.build(fromMaze:) skips drawing
    /// one that isn't, so a stale save from before a wall was knocked
    /// down just quietly doesn't render instead of drawing floating in
    /// midair.
    func placeFloorMap(_ direction: Direction, at coord: GridCoordinate) {
        guard cells.contains(coord) else { return }
        floorMaps[coord] = direction
        version += 1
    }

    func removeFloorMap(at coord: GridCoordinate) {
        guard floorMaps[coord] != nil else { return }
        floorMaps[coord] = nil
        version += 1
    }

    /// Places a ceiling spotlight at `coord` -- same open-cell-only rule
    /// as everything else. No direction to pick (it hangs dead-center),
    /// so unlike placeFloorMap this is just on/off.
    func placeSpotlight(at coord: GridCoordinate) {
        guard cells.contains(coord) else { return }
        spotlights.insert(coord)
        version += 1
    }

    func removeSpotlight(at coord: GridCoordinate) {
        guard spotlights.contains(coord) else { return }
        spotlights.remove(coord)
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
        destinations.removeValue(forKey: coord)
        exitSigns.removeValue(forKey: coord)
        floorMaps.removeValue(forKey: coord)
        spotlights.remove(coord)
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
        let destinationPlacements = destinations.map { ObjectPlacement(coord: $0.key, kind: $0.value) }
        let exitSignPlacements = exitSigns.map { ExitSignPlacement(coord: $0.key, direction: $0.value) }
        let floorMapPlacements = floorMaps.map { FloorMapPlacement(coord: $0.key, direction: $0.value) }
        library[currentMazeID] = MazeRecord(id: currentMazeID, cells: Array(cells), nextMazeID: nextMazeID, objects: placements, destinations: destinationPlacements, exitSigns: exitSignPlacements, floorMaps: floorMapPlacements, spotlights: Array(spotlights))
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
            destinations = Dictionary(uniqueKeysWithValues: record.destinations.map { ($0.coord, $0.kind) })
            exitSigns = Dictionary(uniqueKeysWithValues: record.exitSigns.map { ($0.coord, $0.direction) })
            floorMaps = Dictionary(uniqueKeysWithValues: record.floorMaps.map { ($0.coord, $0.direction) })
            spotlights = Set(record.spotlights)
        } else {
            cells = []
            nextMazeID = nil
            objects = [:]
            destinations = [:]
            exitSigns = [:]
            floorMaps = [:]
            spotlights = []
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

    private var undoStack: [(cells: Set<GridCoordinate>, objects: [GridCoordinate: ObjectKind], destinations: [GridCoordinate: ObjectKind], exitSigns: [GridCoordinate: Direction], floorMaps: [GridCoordinate: Direction], spotlights: Set<GridCoordinate>)] = []
    private let maxUndoDepth = 30

    /// Snapshots the current maze so a later undo() can restore it.
    /// Call once before a batch of edits (a whole drag stroke, or
    /// Clear) rather than per-cell, so Undo reverts a whole gesture at
    /// once instead of one cell at a time. Captures cells AND objects
    /// together so undo works correctly no matter which mode (wall
    /// painting or object placing) the stroke was in.
    func snapshotForUndo() {
        undoStack.append((cells: cells, objects: objects, destinations: destinations, exitSigns: exitSigns, floorMaps: floorMaps, spotlights: spotlights))
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst()
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        cells = previous.cells
        objects = previous.objects
        destinations = previous.destinations
        exitSigns = previous.exitSigns
        floorMaps = previous.floorMaps
        spotlights = previous.spotlights
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
        destinations = [:]
        exitSigns = [:]
        floorMaps = [:]
        spotlights = []
        version += 1
    }
}
