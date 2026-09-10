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
    // Fourth Hallway Activity, Sept 7: the Mail Mission -- "grabbing a
    // floating envelope somewhere and putting it in the mail chute on
    // a wall somewhere... mail is just like trash." Deliver-anywhere,
    // carry-and-drop, exactly like trashCan (see depositIfPresent's
    // own "no matching required" doc comment) -- just a different
    // kind and a different chute label (see missionLegendLabel below).
    case envelope
    case key
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
        case .envelope: return "✉️"
        case .key: return "🔑"
        }
    }
}

/// The word the wall map's legend uses for this floor's mission item
/// (e.g. the green "Trash" row) -- Eddie, Sept 7: "for floor one it
/// will be 'trash' cause thats what u need to do for that level."
/// Driven off missionObjectKind itself rather than typed per floor, so
/// every floor using a given kind gets a consistent legend word for
/// free.
extension ObjectKind {
    var missionLegendLabel: String {
        switch self {
        case .trashCan: return "Trash"
        case .envelope: return "Mail"
        case .key: return "Keys"
        default: return rawValue.capitalized
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

/// One placed Floor Mission sign, as persisted: which cell it's
/// mounted at and which wall it hangs on -- exactly the same shape as
/// FloorMapPlacement above. Manually placed in GridEditorView (Eddie,
/// Sept 7: "just add it to the thingies on the map/edit view so i can
/// put mission statement banners wherever i want... much simpler
/// (just like the wall maps)"), same "editor decides where, build()
/// just draws it" split every other manually-placed fixture uses. The
/// mission's actual TEXT (heading/body) and which ObjectKind it
/// requires live on MazeRecord itself, not here -- this struct is
/// only ever "which cell, which wall," same division floor maps use
/// between placement (many, per-cell) and content (one baked texture,
/// shared by every placed sign on the floor).
private struct MissionSignPlacement: Codable {
    var coord: GridCoordinate
    var direction: Direction
}

/// One placed decorative Picture, as persisted: which cell it's mounted
/// at and which wall it hangs on -- exactly the same shape as
/// FloorMapPlacement/MissionSignPlacement. Manually placed in
/// GridEditorView (Eddie, Sept 9: "make the picture appear as a
/// picture on the wall (like we do to the mission and maps)"), same
/// "editor decides where, build() just draws it" split every other
/// manually-placed fixture uses. Deliberately does NOT store which
/// image -- pictures are aesthetic only, so HallwayScene.build(fromMaze:)
/// grabs a random one from the bundled Pictures folder every time this
/// floor is built, rather than baking one fixed choice in here.
private struct PicturePlacement: Codable {
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
    /// Which of this floor's cells hold a manually-placed Floor
    /// Mission sign, and which wall each one hangs on. Same
    /// decodeIfPresent-or-empty treatment, no legacy shape to
    /// migrate.
    var missionSigns: [MissionSignPlacement]
    /// Which of this floor's cells hold a manually-placed decorative
    /// Picture, and which wall each one hangs on. Same
    /// decodeIfPresent-or-empty treatment, no legacy shape to migrate.
    var pictures: [PicturePlacement]
    var mirrors: [PicturePlacement] = []
    var roomDoors: [RoomDoorPlacement] = []
    var itemRooms: [RoomAssignment] = []
    var picturesUseCameraRoll: Bool = false
    /// This floor's mission -- a big heading ("1st Floor") and a
    /// mission paragraph ("collect all the trash and put it in the
    /// trash chute"), typed in via GridEditorView's mission-editor
    /// sheet rather than hard-coded per floor (Eddie, Sept 7: "you
    /// could put a button to pop open a text input field so you could
    /// type the paragraph in it"). Empty string, not optional -- an
    /// unauthored floor just shows a blank sign if one's placed, same
    /// as an unauthored destination kind would.
    var missionHeading: String
    /// See missionHeading above.
    var missionBody: String
    /// Which ObjectKind completes this floor's mission -- nil means no
    /// mission gate at all (the elevator behaves exactly as before).
    /// Floor 1 reuses the existing trash/chute mechanic wholesale
    /// (Eddie, Sept 7: "since we already have the trash pretty much
    /// in there, lets make it the first floors mission"): set this to
    /// .trashCan and TapNavigationController.isMissionComplete
    /// requires every placed trash can to be both picked up AND
    /// delivered before openElevator() will run.
    var missionObjectKind: ObjectKind?
}

extension MazeRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case mirrors, id, cells, nextMazeID, objects, objectCells, destinations, exitSigns, floorMaps, spotlights, missionSigns, pictures, picturesUseCameraRoll, missionHeading, missionBody, missionObjectKind, roomDoors, itemRooms, mailAddresses
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
        missionSigns = try container.decodeIfPresent([MissionSignPlacement].self, forKey: .missionSigns) ?? []
        mirrors = try container.decodeIfPresent([PicturePlacement].self, forKey: .mirrors) ?? []
        pictures = try container.decodeIfPresent([PicturePlacement].self, forKey: .pictures) ?? []
        roomDoors = try container.decodeIfPresent([RoomDoorPlacement].self, forKey: .roomDoors) ?? []
        itemRooms = try container.decodeIfPresent([RoomAssignment].self, forKey: .itemRooms)
            ?? container.decodeIfPresent([RoomAssignment].self, forKey: .mailAddresses) ?? []
        picturesUseCameraRoll = try container.decodeIfPresent(Bool.self, forKey: .picturesUseCameraRoll) ?? false
        missionHeading = try container.decodeIfPresent(String.self, forKey: .missionHeading) ?? ""
        missionBody = try container.decodeIfPresent(String.self, forKey: .missionBody) ?? ""
        missionObjectKind = try container.decodeIfPresent(ObjectKind.self, forKey: .missionObjectKind)
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
        try container.encode(missionSigns, forKey: .missionSigns)
        try container.encode(mirrors, forKey: .mirrors)
        try container.encode(pictures, forKey: .pictures)
        try container.encode(roomDoors, forKey: .roomDoors)
        try container.encode(itemRooms, forKey: .itemRooms)
        try container.encode(picturesUseCameraRoll, forKey: .picturesUseCameraRoll)
        try container.encode(missionHeading, forKey: .missionHeading)
        try container.encode(missionBody, forKey: .missionBody)
        try container.encodeIfPresent(missionObjectKind, forKey: .missionObjectKind)
    }
}

/// Thin load/save wrapper around a single mazes.json in Documents.
/// Kept separate from MazeStore itself so the "how it's stored" concern
/// (file I/O, JSON shape) doesn't tangle with "what's currently loaded
/// and being edited/played" (MazeStore's actual job).
private enum MazeLibrary {
    // Every build starts with the same floor library shipped in the app.
    // Editor saves are a backup/export aid only; they never override the bundle.
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mazes.json")
    }

    private static func readMaps(at url: URL) -> [Int: MazeRecord]? {
        do {
            let records = try JSONDecoder().decode([MazeRecord].self, from: Data(contentsOf: url))
            guard !records.isEmpty, Set(records.map { $0.id }).count == records.count else {
                print("[Maps] Ignoring empty library or duplicate floor IDs in \(url.lastPathComponent)")
                return nil
            }
            return Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        } catch {
            print("[Maps] Could not load \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    static func loadAll() -> [Int: MazeRecord] {
        guard let url = Bundle.main.url(forResource: "DefaultMazes", withExtension: "json"),
              let bundled = readMaps(at: url) else { return [:] }
        print("[Maps] Loaded \(bundled.count) bundled floors")
        return bundled
    }

    static func saveAll(_ library: [Int: MazeRecord]) {
        let records = library.values.sorted { $0.id < $1.id }
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[Maps] Could not save edited floors: \(error)")
        }
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

    /// The one other cell every floor always has, no matter what --
    /// one step south of the elevator. startingFacing(at:cells:) checks
    /// south first, so walking off the elevator always faces this cell,
    /// and its far (south) wall is where the mission sign always hangs
    /// -- "the mission thing is on the wall in front of you," every
    /// floor, automatically. Eddie, Sept 7.
    static let missionCoordinate = GridCoordinate(row: elevatorCoordinate.row + 1, col: elevatorCoordinate.col)

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

    /// Cells on the current floor holding a manually-placed Floor
    /// Mission sign, and which wall each one hangs on -- placed the
    /// same way Exit Signs/floor maps are (GridEditorView toggles +
    /// paint). Eddie, Sept 7: "just add it to the thingies on the
    /// map/edit view so i can put mission statement banners wherever
    /// i want."
    @Published private(set) var missionSigns: [GridCoordinate: Direction]

    /// Cells on the current floor holding a manually-placed decorative
    /// Picture, and which wall each one hangs on -- placed the same way
    /// Exit Signs/floor maps are (GridEditorView toggle + paint). Eddie,
    /// Sept 9: purely aesthetic ("nothing that has to be solved - just
    /// looked at"), unlike every other wall fixture here -- see
    /// PicturePlacement's own doc comment for why no image is stored.
    @Published private(set) var mirrors: [GridCoordinate: Direction] = [:]
    @Published private(set) var pictures: [GridCoordinate: Direction]
    @Published private(set) var roomDoors: [GridCoordinate: RoomDoorPlacement] = [:]
    @Published private(set) var itemRooms: [GridCoordinate: Int] = [:]
    @Published private(set) var picturesUseCameraRoll = false

    /// This floor's mission heading/paragraph and which ObjectKind
    /// completes it -- see MazeRecord's own doc comments for the full
    /// story. Scalars, not cell-keyed, same shape as nextMazeID:
    /// there's exactly one mission per floor, however many sign
    /// placements happen to display it.
    @Published private(set) var missionHeading: String
    @Published private(set) var missionBody: String
    @Published private(set) var missionObjectKind: ObjectKind?

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

    /// How many floors exist right now -- mazeIDs double as floor
    /// numbers (see GridEditorView's stepNextMazeID), so this is just
    /// the highest one in the library, never below whatever's
    /// currently loaded. Eddie, Sept 7: "lets say we go with 5 floors
    /// for now" for the elevator ride's button panel -- this is what
    /// makes that panel always match however many floors actually
    /// exist instead of a number hardcoded here.
    var floorCount: Int {
        max(library.keys.max() ?? 1, currentMazeID)
    }

    /// Running total of all cash absorbed this run, across every floor
    /// -- deliberately NOT part of any per-floor state (cells/objects/
    /// destinations/undo all get swapped out by switchTo(); this
    /// doesn't). Not yet persisted to disk, so it resets if the app is
    /// force-quit mid-run — acceptable for now since there's no broader
    /// "save game" system yet either; revisit once one exists.
    @Published private(set) var moneyTotal = 0

    /// One "a cash pickup just happened" event -- purely for
    /// ContentView's screen-space celebration (gold flash, a flying
    /// "+$100", a HUD pulse), kept entirely separate from moneyTotal
    /// itself so the running total stays the single source of truth
    /// for the actual score. Carries its own id so two consecutive
    /// pickups of the identical amount still count as two distinct
    /// events -- without it, SwiftUI's onChange would see two equal
    /// values back to back and silently fire only once.
    struct CashPickupEvent: Equatable {
        let amount: Int
        let id = UUID()
    }
    @Published private(set) var lastCashPickup: CashPickupEvent?

    /// Called by TapNavigationController the instant a cash object is
    /// walked into (see collectObjectIfPresent) -- the only way
    /// moneyTotal ever changes.
    func addMoney(_ amount: Int) {
        moneyTotal += amount
        lastCashPickup = CashPickupEvent(amount: amount)
    }

    /// One "a trash can was just picked up" event -- purely for
    /// ContentView's temporary screen-space visual (Eddie, Sept 9:
    /// "the sound occurs but the trash just disappears. we need some
    /// kind of visual feedback. do something temporary and ill try to
    /// figure out something... maybe little spinning trash cans").
    /// Same id-per-event trick as CashPickupEvent so back-to-back
    /// pickups each still fire their own onChange.
    struct TrashPickupEvent: Equatable {
        let id = UUID()
    }
    @Published private(set) var lastTrashPickup: TrashPickupEvent?

    /// Called by TapNavigationController the instant a trash can is
    /// walked into (see collectObjectIfPresent's onCollectTrash call).
    func markTrashPickup() {
        lastTrashPickup = TrashPickupEvent()
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
            missionSigns = Dictionary(uniqueKeysWithValues: (loaded[firstID]?.missionSigns ?? []).map { ($0.coord, $0.direction) })
            mirrors = Dictionary(uniqueKeysWithValues: (loaded[firstID]?.mirrors ?? []).map { ($0.coord, $0.direction) })
            pictures = Dictionary(uniqueKeysWithValues: (loaded[firstID]?.pictures ?? []).map { ($0.coord, $0.direction) })
            roomDoors = Dictionary(uniqueKeysWithValues: (loaded[firstID]?.roomDoors ?? []).map { ($0.coord, $0) })
            itemRooms = Dictionary(uniqueKeysWithValues: (loaded[firstID]?.itemRooms ?? []).map { ($0.coord, $0.roomNumber) })
            picturesUseCameraRoll = loaded[firstID]?.picturesUseCameraRoll ?? false
            missionHeading = loaded[firstID]?.missionHeading ?? ""
            missionBody = loaded[firstID]?.missionBody ?? ""
            missionObjectKind = loaded[firstID]?.missionObjectKind
        } else {
            // Nothing on disk yet — first-ever launch. Seed floor 1
            // with just the forced elevator+mission cells (same as
            // clear() below) and write it out immediately so this
            // branch is never hit again on this device.
            let starter = MazeRecord(id: 1, cells: [Self.elevatorCoordinate, Self.missionCoordinate], nextMazeID: nil, objects: [], destinations: [], exitSigns: [], floorMaps: [], spotlights: [], missionSigns: [MissionSignPlacement(coord: Self.missionCoordinate, direction: .south)], pictures: [], missionHeading: "", missionBody: "", missionObjectKind: nil)
            library = [1: starter]
            currentMazeID = 1
            cells = [Self.elevatorCoordinate, Self.missionCoordinate]
            nextMazeID = nil
            objects = [:]
            destinations = [:]
            exitSigns = [:]
            floorMaps = [:]
            spotlights = []
            missionSigns = [Self.missionCoordinate: .south]
            pictures = [:]
            mirrors = [:]
            roomDoors = [:]
            itemRooms = [:]
            picturesUseCameraRoll = false
            missionHeading = ""
            missionBody = ""
            missionObjectKind = nil
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
        guard !cells.isEmpty else { return nil }
        return currentMazeID == 1 ? floorOneEntryCoordinate : Self.elevatorCoordinate
    }

    /// You get off the elevator, and you're standing right where you
    /// need to get back to for the next one -- Eddie, Sept 5: "when
    /// you arrive at a level, you get off the elevator, and youre
    /// right at the point you need to get to to get to the next
    /// level." Always the building's fixed elevatorCoordinate, full
    /// stop -- unlike startCoordinate, this one does NOT change for
    /// floor 1 (Eddie, Sept 7): you still walk TO the elevator and
    /// ride it up from there, it's only where you START floor 1
    /// that's different.
    var endCoordinate: GridCoordinate? {
        cells.isEmpty ? nil : Self.elevatorCoordinate
    }

    /// Floor 1 only: the far end of its straight entry hallway --
    /// found by walking away from the elevator cell through whichever
    /// neighbor is open and isn't where you just came from, repeated
    /// until there's nowhere further to go. Eddie's floor 1 is "one
    /// hallway... 3 cubes long" with no branches, so there's always
    /// exactly one way to keep walking at each step -- this derives
    /// the spawn point from whatever shape actually gets drawn in the
    /// editor rather than needing its own stored/placed coordinate,
    /// so the hallway can be lengthened or shortened later with no
    /// code changes. Falls back to elevatorCoordinate itself if
    /// there's nowhere to walk at all yet (a floor 1 that's just the
    /// bare elevator cell, nothing else drawn).
    private var floorOneEntryCoordinate: GridCoordinate {
        var current = Self.elevatorCoordinate
        var previous: GridCoordinate? = nil
        while true {
            let neighbors = [
                GridCoordinate(row: current.row - 1, col: current.col),
                GridCoordinate(row: current.row + 1, col: current.col),
                GridCoordinate(row: current.row, col: current.col - 1),
                GridCoordinate(row: current.row, col: current.col + 1),
            ]
            guard let next = neighbors.first(where: { cells.contains($0) && $0 != previous }) else {
                return current
            }
            previous = current
            current = next
        }
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

    func hasMissionSign(_ coord: GridCoordinate) -> Bool {
        missionSigns[coord] != nil
    }

    func missionSignDirection(at coord: GridCoordinate) -> Direction? {
        missionSigns[coord]
    }

    func hasPicture(_ coord: GridCoordinate) -> Bool {
        pictures[coord] != nil
    }

    func pictureDirection(at coord: GridCoordinate) -> Direction? {
        pictures[coord]
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
        if kind == .envelope || kind == .key {
            assignUnassignedRoomItems()
        } else {
            itemRooms[coord] = nil
        }
        version += 1
    }

    func removeObject(at coord: GridCoordinate) {
        guard objects[coord] != nil else { return }
        objects[coord] = nil
        itemRooms[coord] = nil
        version += 1
    }

    /// Places a destination of `kind` on `coord` (same open-cell-only
    /// rule as placeObject) -- which wall it actually ends up mounted
    /// on is HallwayScene.build(fromMaze:)'s call, not this one's.
    func placeDestination(_ kind: ObjectKind, at coord: GridCoordinate) {
        guard roomDoors[coord] == nil, mirrors[coord] == nil, cells.contains(coord) else { return }
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
        guard roomDoors[coord] == nil, mirrors[coord] == nil, cells.contains(coord) else { return }
        floorMaps[coord] = direction
        version += 1
    }

    func removeFloorMap(at coord: GridCoordinate) {
        guard floorMaps[coord] != nil else { return }
        floorMaps[coord] = nil
        version += 1
    }

    /// Places (or repoints) a decorative Picture at `coord`, hung on
    /// `direction`'s wall -- same rules as placeFloorMap above (open
    /// cell, direction not checked to actually be a wall here, that's
    /// GridEditorView's job).
    func setPicturesUseCameraRoll(_ enabled: Bool) {
        guard picturesUseCameraRoll != enabled else { return }
        snapshotForUndo()
        picturesUseCameraRoll = enabled
        version += 1
        save()
    }

    var roomNumbers: [Int] { roomDoors.values.map(\.roomNumber).sorted() }

    func placeRoomDoor(_ direction: Direction, at coord: GridCoordinate) {
        let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
        guard cells.contains(coord), !cells.contains(neighbor),
              coord != Self.elevatorCoordinate, coord != Self.missionCoordinate,
              floorMaps[coord] == nil, pictures[coord] == nil, mirrors[coord] == nil, destinations[coord] == nil else { return }
        let number = roomDoors[coord]?.roomNumber ?? (max(roomNumbers.max() ?? (currentMazeID * 100), itemRooms.values.max() ?? (currentMazeID * 100)) + 1)
        roomDoors[coord] = RoomDoorPlacement(coord: coord, direction: direction, roomNumber: number, cashReward: roomDoors[coord]?.cashReward ?? (missionObjectKind == .key ? 100 : nil))
        assignUnassignedRoomItems()
        version += 1
    }

    func removeRoomDoor(at coord: GridCoordinate) {
        guard roomDoors.removeValue(forKey: coord) != nil else { return }
        version += 1
    }

    func setItemRoom(_ room: Int, at coord: GridCoordinate) {
        guard (objects[coord] == .envelope || objects[coord] == .key), roomNumbers.contains(room) else { return }
        itemRooms[coord] = room
        version += 1
    }

    func setRoomReward(_ amount: Int, at coord: GridCoordinate) {
        guard roomDoors[coord] != nil else { return }
        roomDoors[coord]?.cashReward = max(0, amount)
        version += 1
    }

    private func assignUnassignedRoomItems() {
        let rooms = roomNumbers
        guard !rooms.isEmpty else { return }
        let unaddressed = objects.keys.filter { (objects[$0] == .envelope || objects[$0] == .key) && itemRooms[$0] == nil }
            .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        for coord in unaddressed {
            let room = rooms.min { a, b in
                let aCount = itemRooms.values.filter { $0 == a }.count
                let bCount = itemRooms.values.filter { $0 == b }.count
                return aCount == bCount ? a < b : aCount < bCount
            }!
            itemRooms[coord] = room
        }
    }

    func mirrorDirection(at coord: GridCoordinate) -> Direction? { mirrors[coord] }

    func canPlaceMirror(_ direction: Direction, at coord: GridCoordinate) -> Bool {
        let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
        return cells.contains(coord) && !cells.contains(neighbor) &&
            coord != Self.elevatorCoordinate && roomDoors[coord] == nil &&
            pictures[coord] == nil && floorMaps[coord] == nil && destinations[coord] == nil &&
            missionSigns[coord] != direction
    }

    func placeMirror(_ direction: Direction, at coord: GridCoordinate) {
        guard canPlaceMirror(direction, at: coord) else { return }
        mirrors[coord] = direction
        version += 1
    }

    func removeMirror(at coord: GridCoordinate) {
        guard mirrors.removeValue(forKey: coord) != nil else { return }
        version += 1
    }

    func placePicture(_ direction: Direction, at coord: GridCoordinate) {
        guard roomDoors[coord] == nil, mirrors[coord] == nil, cells.contains(coord) else { return }
        pictures[coord] = direction
        version += 1
    }

    func removePicture(at coord: GridCoordinate) {
        guard pictures[coord] != nil else { return }
        pictures[coord] = nil
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
        missionSigns.removeValue(forKey: coord)
        pictures.removeValue(forKey: coord)
        mirrors.removeValue(forKey: coord)
        roomDoors.removeValue(forKey: coord)
        itemRooms.removeValue(forKey: coord)
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

    /// Sets this floor's mission heading + paragraph, typed in via
    /// GridEditorView's mission-editor sheet. Unlike setNextMazeID
    /// this DOES bump version (not just save()) -- the mission text
    /// gets baked into the actual wall-sign texture in 3D
    /// (HallwayScene.makeMissionSignTexture), so a rebuild needs to
    /// know something changed, same as any other edit made while the
    /// grid editor is open. Persisting to disk still waits for the
    /// editor to close (ContentView's dismiss-triggered save()), same
    /// as every other cell-level edit.
    func setMissionText(heading: String, body: String) {
        guard heading != missionHeading || body != missionBody else { return }
        missionHeading = heading
        missionBody = body
        version += 1
    }

    /// Sets which ObjectKind completes this floor's mission (nil means
    /// no gate at all). Floor 1 reuses the trash/chute mechanic --
    /// see MazeRecord.missionObjectKind's own doc comment.
    func setMissionObjectKind(_ kind: ObjectKind?) {
        guard kind != missionObjectKind else { return }
        missionObjectKind = kind
        version += 1
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
        let missionSignPlacements = missionSigns.map { MissionSignPlacement(coord: $0.key, direction: $0.value) }
        let picturePlacements = pictures.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        library[currentMazeID] = MazeRecord(id: currentMazeID, cells: Array(cells), nextMazeID: nextMazeID, objects: placements, destinations: destinationPlacements, exitSigns: exitSignPlacements, floorMaps: floorMapPlacements, spotlights: Array(spotlights), missionSigns: missionSignPlacements, pictures: picturePlacements, mirrors: mirrors.map { PicturePlacement(coord: $0.key, direction: $0.value) }, roomDoors: Array(roomDoors.values), itemRooms: itemRooms.map { RoomAssignment(coord: $0.key, roomNumber: $0.value) }, picturesUseCameraRoll: picturesUseCameraRoll, missionHeading: missionHeading, missionBody: missionBody, missionObjectKind: missionObjectKind)
        MazeLibrary.saveAll(library)
    }

    /// Eddie, Sept 8: "the output from that map save button should be
    /// either in swift sytax... ready to just be copy/pasted into the
    /// code, or if you prefer, some other format that allows the
    /// transition from it to being saved in the code." Going with
    /// JSON, not hand-written Swift literals -- MazeRecord is already
    /// Codable, this is the exact format the app itself already uses
    /// for local persistence (see MazeLibrary below), and it avoids
    /// the transcription risk of a large hand-typed Swift struct
    /// literal (a floor's cells array alone can run into the hundreds
    /// of entries). Flushes the in-progress floor first, same as
    /// save(), so the export always matches whatever's currently
    /// drawn. This JSON is meant to be pasted straight into a chat
    /// with Claude, who turns it into a bundled seed/default maze set
    /// shipped with the app -- decoded through the identical
    /// JSONDecoder path MazeLibrary.loadAll() already uses.
    func exportLibraryJSON() -> String? {
        save()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let records = library.values.sorted { $0.id < $1.id }
        guard let data = try? encoder.encode(records) else { return nil }
        return String(data: data, encoding: .utf8)
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
            missionSigns = Dictionary(uniqueKeysWithValues: record.missionSigns.map { ($0.coord, $0.direction) })
            mirrors = Dictionary(uniqueKeysWithValues: record.mirrors.map { ($0.coord, $0.direction) })
            pictures = Dictionary(uniqueKeysWithValues: record.pictures.map { ($0.coord, $0.direction) })
            roomDoors = Dictionary(uniqueKeysWithValues: record.roomDoors.map { ($0.coord, $0) })
            itemRooms = Dictionary(uniqueKeysWithValues: record.itemRooms.map { ($0.coord, $0.roomNumber) })
            picturesUseCameraRoll = record.picturesUseCameraRoll
            missionHeading = record.missionHeading
            missionBody = record.missionBody
            missionObjectKind = record.missionObjectKind
        } else {
            // Same "keep the elevator+mission cells" fix clear() just got
            // -- this is the other place a floor starts out "empty."
            cells = [Self.elevatorCoordinate, Self.missionCoordinate]
            nextMazeID = nil
            objects = [:]
            destinations = [:]
            exitSigns = [:]
            floorMaps = [:]
            spotlights = []
            missionSigns = [Self.missionCoordinate: .south]
            pictures = [:]
            mirrors = [:]
            roomDoors = [:]
            itemRooms = [:]
            picturesUseCameraRoll = false
            missionHeading = ""
            missionBody = ""
            missionObjectKind = nil
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

    private var undoStack: [(cells: Set<GridCoordinate>, objects: [GridCoordinate: ObjectKind], destinations: [GridCoordinate: ObjectKind], exitSigns: [GridCoordinate: Direction], floorMaps: [GridCoordinate: Direction], spotlights: Set<GridCoordinate>, missionSigns: [GridCoordinate: Direction], pictures: [GridCoordinate: Direction], mirrors: [GridCoordinate: Direction], picturesUseCameraRoll: Bool, roomDoors: [GridCoordinate: RoomDoorPlacement], itemRooms: [GridCoordinate: Int])] = []
    private let maxUndoDepth = 30

    /// Snapshots the current maze so a later undo() can restore it.
    /// Call once before a batch of edits (a whole drag stroke, or
    /// Clear) rather than per-cell, so Undo reverts a whole gesture at
    /// once instead of one cell at a time. Captures cells AND objects
    /// together so undo works correctly no matter which mode (wall
    /// painting or object placing) the stroke was in.
    func snapshotForUndo() {
        undoStack.append((cells: cells, objects: objects, destinations: destinations, exitSigns: exitSigns, floorMaps: floorMaps, spotlights: spotlights, missionSigns: missionSigns, pictures: pictures, mirrors: mirrors, picturesUseCameraRoll: picturesUseCameraRoll, roomDoors: roomDoors, itemRooms: itemRooms))
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
        missionSigns = previous.missionSigns
        pictures = previous.pictures
        mirrors = previous.mirrors
        roomDoors = previous.roomDoors
        itemRooms = previous.itemRooms
        picturesUseCameraRoll = previous.picturesUseCameraRoll
        version += 1
    }

    /// Wipes the whole maze — walls and objects both. Undoable like
    /// any other edit — snapshots first, so a stray tap on Clear isn't
    /// a disaster.
    func clear() {
        guard !cells.isEmpty else { return }
        snapshotForUndo()
        // Just the elevator + mission cells, not truly empty -- the
        // elevator has nowhere to be drawn once cells is empty (see
        // startCoordinate's doc comment), so a real "wipe everything"
        // clear would delete the elevator right along with the maze.
        // Eddie, Sept 7: "after clear it should be there" -- and per
        // his follow-up the same day, Clear (like a fresh floor) always
        // re-seeds the mission cell right along with the elevator, so
        // every floor keeps the same forced elevator/mission layout.
        cells = [Self.elevatorCoordinate, Self.missionCoordinate]
        objects = [:]
        destinations = [:]
        exitSigns = [:]
        floorMaps = [:]
        spotlights = []
        missionSigns = [Self.missionCoordinate: .south]
        pictures = [:]
        mirrors = [:]
        roomDoors = [:]
        itemRooms = [:]
        version += 1
    }
}
