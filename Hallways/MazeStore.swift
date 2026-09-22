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

struct FirePlacement: Codable, Hashable {
    var coord: GridCoordinate
}

struct ExtinguisherPlacement: Codable, Hashable {
    var coord: GridCoordinate
    var direction: Direction
}

enum PhotoBoothExpression: String, Codable, Hashable {
    case smile
    case mouthOpen
    case eyebrowsRaised

    var prompt: String {
        switch self {
        case .smile: return "PLEASE SMILE"
        case .mouthOpen: return "OPEN YOUR MOUTH"
        case .eyebrowsRaised: return "RAISE YOUR EYEBROWS"
        }
    }
}

/// Sept 21 (Picture Size): a persisted, per-Picture authored size.
/// Picture stays ONE object type -- this is metadata on it, exactly
/// like PhotoBoothExpression is metadata on a Photo Booth, not a
/// family of separate object kinds. Only the four FRAME-BASED sizes
/// exist so far; Mural is deliberately not a case here yet -- recon
/// (Sept 21) found it needs a structurally different wall-filling
/// render path (no frame, no reserved-gap-behind-a-backing-panel
/// shape the other four share), so it stays a future addition rather
/// than a half-built case here.
enum PictureSize: String, Codable, Hashable, CaseIterable {
    case small, standard, poster, fullLength

    /// Multiplies HallwayScene.addPictureNode's existing `scale`
    /// parameter -- already used, at 1.4, for the 3 hardcoded Floor-1
    /// lobby photos, so this is the SAME mechanism, not a new one.
    /// .standard is exactly 1 -- by construction it reproduces
    /// today's ordinary picture dimensions bit-for-bit, satisfying
    /// "existing pictures with no stored size decode as Standard and
    /// look exactly as before." The other three were chosen by hand
    /// against the base 0.6 x 0.85 panel and the 3.0 wallHeight /
    /// 1.65 frame-center precedent (see addPictureNode's own doc
    /// comment on the reserved-footprint mechanism this enables):
    /// .fullLength=2.6 keeps a comfortable ~0.2 unit clearance to the
    /// ceiling and ~0.5 to the floor at every wall this game builds
    /// (wallHeight is a single global constant), so it reads as
    /// "near floor-to-ceiling" without ever literally intersecting
    /// either. Report these to Eddie for on-device tuning -- they're
    /// a reasoned starting point, not load-bearing precision.
    var scale: CGFloat {
        switch self {
        case .small: return 0.65
        case .standard: return 1.0
        case .poster: return 1.8
        case .fullLength: return 2.6
        }
    }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Standard"
        case .poster: return "Poster"
        case .fullLength: return "Full Length"
        }
    }
}

/// A Floor Object's authored position across the usable width of its
/// hallway cell -- LEFT/CENTER/RIGHT, relative to that object's OWN
/// authored axis (FluorescentOrientation, reused rather than inventing
/// a parallel two-way enum -- see FloorObjectPlacement below), never
/// absolute world compass direction. First pass (Sept 21): trash cans
/// only. See HallwayScene.trashCanFloorOffset for the exact world-
/// position math and the LEFT/RIGHT side convention.
enum FloorPosition: String, Codable, CaseIterable {
    case left, center, right

    var title: String {
        switch self {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }
}

/// One Floor Object's authored placement: LEFT/CENTER/RIGHT across the
/// hallway, plus which axis (north-south or east-west hallway) "across"
/// means for it -- corners/intersections are ambiguous to infer from
/// maze topology alone, so this is authored explicitly (3D Decorator)
/// and stored, not derived. Defaults (.center, .northSouth) reproduce
/// a trash can's PRE-Floor-Object appearance exactly -- centered in its
/// cell -- so any trash can placed before this pass, or any other
/// ObjectKind that never gets a placement entry, decodes and draws
/// identically to before. See ObjectPlacement's own floorPosition/
/// floorOrientation fields for how this persists.
struct FloorObjectPlacement: Equatable {
    var position: FloorPosition = .center
    var orientation: FluorescentOrientation = .northSouth
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
    case paintBucket
}

/// Non-nil only for cash kinds -- the dollar amount that gets added to
/// MazeStore.moneyTotal on pickup. This is also how
/// TapNavigationController tells "instant-absorb cash" apart from
/// "carry it, deliver it later" trash: everything else stays nil.
extension ObjectKind {
    /// Denominations start at $100 on Floor 2; the introductory lobby has no cash.
    func cashValue(onFloor floor: Int) -> Int? { cashValue.map { $0 * max(0, floor - 1) } }

    var cashValue: Int? {
        switch self {
        case .cash100: return 100
        default: return nil
        }
    }
}

/// Sept 21 (deliberate tap-to-pick-up): which kinds still auto-collect
/// the instant the player's cell arrives at theirs, versus which now
/// require the player to be within one grid cell AND tap the actual
/// physical node -- see TapNavigationController.collectByTap/
/// isWithinTapRange. Cash is the one deliberate exception: "cash you
/// walk into and absorb instantly -- no carrying, no elevator gate, no
/// delivery" is Eddie's own design for it (see cashValue's own doc
/// comment above), a materially different interaction from every other
/// kind, so it keeps the old arrival-triggers-collection behavior
/// completely unchanged. Everything else -- trash, mail, keys, paint
/// buckets, and the older heart/star/iceCream/... kinds that share the
/// exact same generic collection path even though GridEditorView no
/// longer places them -- now requires a deliberate tap.
extension ObjectKind {
    var requiresTapToCollect: Bool { self != .cash100 }
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
        case .paintBucket: return "🪣"
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
        case .paintBucket: return "Paint"
        default: return rawValue.capitalized
        }
    }
}

/// One placed object, as persisted: which cell it's on and which kind
/// it is. floorPosition/floorOrientation (Sept 21, Floor Object
/// placement first pass) are additive and optional -- nil for every
/// entry written before this pass existed (and for every kind except
/// trash cans, this pass), and Swift's synthesized Decodable already
/// treats a missing key on an Optional property as nil rather than
/// failing, so older saved floors/overrides and the "destinations"
/// array (which reuses this same struct and never sets these two
/// fields) both keep decoding exactly as before. Both default to nil
/// in the memberwise init so every existing `ObjectPlacement(coord:
/// kind:)` call site keeps compiling unchanged.
private struct ObjectPlacement: Codable {
    var coord: GridCoordinate
    var kind: ObjectKind
    var floorPosition: FloorPosition? = nil
    var floorOrientation: FluorescentOrientation? = nil
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

/// Pictures' OWN dedicated wire struct (mirrors, wall lights, and every
/// other coord+direction-only placement keep using the plain
/// PicturePlacement above -- unaffected by this) -- exactly the same
/// "give it its own struct once it needs one more field" move as
/// PhotoBoothPlacement below. `size` is Optional purely for decoding:
/// Swift's synthesized Codable treats a missing key on an Optional
/// property as nil rather than throwing, so a floor saved before
/// Picture Size existed decodes every picture's `size` as nil with NO
/// custom init(from:)/migration code -- MazeStore's own load path then
/// reads that nil as .standard (see the `?? .standard` at every
/// pictures-loading call site). A newly-saved picture always encodes a
/// concrete size.
private struct PictureSizePlacement: Codable {
    var coord: GridCoordinate
    var direction: Direction
    var size: PictureSize?
}

/// An explicit image choice for one specific framed Picture, made
/// through the in-world "Change Picture" menu (Sept 20) when the
/// player taps a picture they're standing at. Absent for every
/// picture nobody has ever explicitly changed, which is exactly what
/// preserves PicturePlacement's original "grabs a random one every
/// time this floor is built" behavior everywhere else -- this is an
/// opt-in override on top of that, not a replacement for it.
enum PictureImageSelection: Codable, Equatable {
    /// One specific image from the bundled Hallways Art collection,
    /// named the same way HallwayScene.pictureAssetNames names it
    /// (e.g. "IMG_7416", no extension).
    case builtIn(String)
    /// One specific photo from the user's camera roll, by its
    /// PHAsset.localIdentifier.
    case cameraRoll(String)
}

private struct PictureSelectionPlacement: Codable {
    var coord: GridCoordinate
    var selection: PictureImageSelection
}

private struct PhotoBoothPlacement: Codable {
    var coord: GridCoordinate
    var direction: Direction
    var expression: PhotoBoothExpression
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
    /// Picture, which wall each one hangs on, and (Sept 21) which
    /// PictureSize it's authored at. Same decodeIfPresent-or-empty
    /// treatment, no legacy shape to migrate -- PictureSizePlacement's
    /// own doc comment covers how an old floor's missing `size` key
    /// resolves to Standard with no separate migration step.
    var pictures: [PictureSizePlacement]
    /// See PictureImageSelection's own doc comment. Empty for every
    /// floor authored before Sept 20 and for any picture nobody has
    /// explicitly changed since -- decodeIfPresent-or-empty, same as
    /// every other field added after pictures/mirrors first shipped.
    var pictureImageSelections: [PictureSelectionPlacement] = []
    var mirrors: [PicturePlacement] = []
    /// Which of this floor's cells hold a manually-placed "Wall Top
    /// Light" (Suzanimator lighting pass, Sept 19) -- the project's
    /// third editor-authorable physical light source, and the first
    /// one that mounts on a wall (the ceiling light and fire both sit
    /// centered in their cell). Same coord+direction shape as mirrors/
    /// pictures: coord is the cell the light hangs over, direction is
    /// which wall it mounts on. Same decodeIfPresent-or-empty
    /// treatment, no legacy on-disk shape to migrate.
    var fluorescentLights: [FluorescentPlacement] = []
    var pictureLights: [PicturePlacement] = []
    var wallLights: [PicturePlacement] = []
    var lightBrightness: [LightBrightness] = []
    /// The building's first real bathroom door (Eddie, Sept 14,
    /// round 2: "first real bathroom + real door + mirror"). Same
    /// coord+direction shape as mirrors/pictures -- a door has
    /// nothing per-instance to store beyond which cell/wall it's on,
    /// same as those. Unlike mirrors, this ALSO drives real gameplay
    /// (TapNavigationController gates movement through it), not just
    /// decoration -- but the data shape needed for that is identical.
    var bathroomDoors: [PicturePlacement] = []
    /// This floor's Window Room door(s) -- same coord+direction
    /// shape as bathroomDoors (same swinging-door interaction model
    /// -- see WindowRoomPlacement's own doc comment), plus which wall
    /// of the room beyond is the exterior window wall and which view
    /// asset it shows. Eddie, Sept 15: a perimeter room reached
    /// through "an ordinary door," reusing the bathroom door's proven
    /// interaction model exactly.
    var windowRooms: [WindowRoomPlacement] = []
    /// Floor 7's aptitude-test terminal (and any future floor's) --
    /// same coord+direction shape as mirrors/pictures, reused rather
    /// than a dedicated placement type since there's nothing else
    /// per-instance to store (Eddie, Sept 13: first embedded mini-game).
    var ticTacToeTerminals: [PicturePlacement] = []
    /// Floor 8's shell-game station (and any future floor's) -- same
    /// coord+direction shape as ticTacToeTerminals, reused for the
    /// same reason (Eddie, Sept 13: second embedded mini-game).
    var shellGameStations: [PicturePlacement] = []
    /// Floor 9's Rock Paper Scissors terminal (and any future floor's)
    /// -- same coord+direction shape as shellGameStations/
    /// ticTacToeTerminals (Eddie, Sept 13: third embedded mini-game).
    var rockPaperScissorsTerminals: [PicturePlacement] = []
    /// Floor 10's Higher/Lower terminal (and any future floor's) --
    /// same coord+direction shape as rockPaperScissorsTerminals
    /// (Eddie, Sept 13: fourth embedded mini-game).
    var higherLowerTerminals: [PicturePlacement] = []
    /// Floor 11's Five-Card Draw terminal (and any future floor's) --
    /// same coord+direction shape as higherLowerTerminals (Eddie,
    /// Sept 13: fifth embedded mini-game).
    var fiveCardDrawTerminals: [PicturePlacement] = []
    /// Floor 13's Simon terminal (and any future floor's) -- same
    /// coord+direction shape as whackAMoleTerminals (Eddie, Sept 13:
    /// seventh embedded mini-game).
    var simonTerminals: [PicturePlacement] = []
    /// Floor 12's Hangman terminal (and any future floor's) -- same
    /// coord+direction shape as simonTerminals (Eddie, Sept 14: the
    /// Building's first "familiar game, played straight" embedded
    /// mini-game, replacing the removed Whack-A-Mole in the same
    /// Floor 12 slot).
    var hangmanTerminals: [PicturePlacement] = []
    /// Floor 14's Connect Four terminal (and any future floor's)
    /// -- same coord+direction shape as hangmanTerminals (Eddie,
    /// Sept 14: the Building's next "familiar game, played
    /// straight" embedded mini-game, replacing the removed
    /// Skee-Ball in the same Floor 14 slot).
    var connectFourTerminals: [PicturePlacement] = []
    /// Floor 15's Checkers terminal (and any future floor's) --
    /// same coord+direction shape as connectFourTerminals (Eddie,
    /// Sept 14: the new top floor's "familiar game, played
    /// straight" embedded mini-game).
    var checkersTerminals: [PicturePlacement] = []
    /// Floor 16's Woidle terminal (and any future floor's) -- same
    /// coord+direction shape as checkersTerminals (Eddie, Sept 14:
    /// the five-letter word deduction assessment, working internal
    /// name "WOIDLE / WEIRDLE").
    var woidleTerminals: [PicturePlacement] = []
    var fires: [FirePlacement] = []
    var extinguishers: [ExtinguisherPlacement] = []
    var photoBooths: [PhotoBoothPlacement] = []
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
        case fluorescentLights, pictureLights, lightBrightness, pictureImageSelections, mirrors, wallLights, bathroomDoors, windowRooms, fires, extinguishers, photoBooths, ticTacToeTerminals, shellGameStations, rockPaperScissorsTerminals, higherLowerTerminals, fiveCardDrawTerminals, simonTerminals, hangmanTerminals, connectFourTerminals, checkersTerminals, woidleTerminals, id, cells, nextMazeID, objects, objectCells, destinations, exitSigns, floorMaps, spotlights, missionSigns, pictures, picturesUseCameraRoll, missionHeading, missionBody, missionObjectKind, roomDoors, itemRooms, mailAddresses
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
        lightBrightness = try container.decodeIfPresent([LightBrightness].self, forKey: .lightBrightness) ?? []
        fluorescentLights = try container.decodeIfPresent([FluorescentPlacement].self, forKey: .fluorescentLights) ?? []
        pictureLights = try container.decodeIfPresent([PicturePlacement].self, forKey: .pictureLights) ?? []
        wallLights = try container.decodeIfPresent([PicturePlacement].self, forKey: .wallLights) ?? []
        pictureImageSelections = try container.decodeIfPresent([PictureSelectionPlacement].self, forKey: .pictureImageSelections) ?? []
        bathroomDoors = try container.decodeIfPresent([PicturePlacement].self, forKey: .bathroomDoors) ?? []
        windowRooms = try container.decodeIfPresent([WindowRoomPlacement].self, forKey: .windowRooms) ?? []
        ticTacToeTerminals = try container.decodeIfPresent([PicturePlacement].self, forKey: .ticTacToeTerminals) ?? []
        shellGameStations = try container.decodeIfPresent([PicturePlacement].self, forKey: .shellGameStations) ?? []
        rockPaperScissorsTerminals = try container.decodeIfPresent([PicturePlacement].self, forKey: .rockPaperScissorsTerminals) ?? []
        higherLowerTerminals = try container.decodeIfPresent([PicturePlacement].self, forKey: .higherLowerTerminals) ?? []
        fiveCardDrawTerminals = try container.decodeIfPresent([PicturePlacement].self, forKey: .fiveCardDrawTerminals) ?? []
        simonTerminals = try container.decodeIfPresent([PicturePlacement].self, forKey: .simonTerminals) ?? []
        hangmanTerminals = try container.decodeIfPresent([PicturePlacement].self, forKey: .hangmanTerminals) ?? []
        connectFourTerminals = try container.decodeIfPresent([PicturePlacement].self, forKey: .connectFourTerminals) ?? []
        checkersTerminals = try container.decodeIfPresent([PicturePlacement].self, forKey: .checkersTerminals) ?? []
        woidleTerminals = try container.decodeIfPresent([PicturePlacement].self, forKey: .woidleTerminals) ?? []
        fires = try container.decodeIfPresent([FirePlacement].self, forKey: .fires) ?? []
        extinguishers = try container.decodeIfPresent([ExtinguisherPlacement].self, forKey: .extinguishers) ?? []
        photoBooths = try container.decodeIfPresent([PhotoBoothPlacement].self, forKey: .photoBooths) ?? []
        pictures = try container.decodeIfPresent([PictureSizePlacement].self, forKey: .pictures) ?? []
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
        try container.encode(fluorescentLights, forKey: .fluorescentLights)
        try container.encode(pictureLights, forKey: .pictureLights)
        try container.encode(wallLights, forKey: .wallLights)
        try container.encode(pictureImageSelections, forKey: .pictureImageSelections)
        try container.encode(lightBrightness, forKey: .lightBrightness)
        try container.encode(bathroomDoors, forKey: .bathroomDoors)
        try container.encode(windowRooms, forKey: .windowRooms)
        try container.encode(ticTacToeTerminals, forKey: .ticTacToeTerminals)
        try container.encode(shellGameStations, forKey: .shellGameStations)
        try container.encode(rockPaperScissorsTerminals, forKey: .rockPaperScissorsTerminals)
        try container.encode(higherLowerTerminals, forKey: .higherLowerTerminals)
        try container.encode(fiveCardDrawTerminals, forKey: .fiveCardDrawTerminals)
        try container.encode(simonTerminals, forKey: .simonTerminals)
        try container.encode(hangmanTerminals, forKey: .hangmanTerminals)
        try container.encode(connectFourTerminals, forKey: .connectFourTerminals)
        try container.encode(checkersTerminals, forKey: .checkersTerminals)
        try container.encode(woidleTerminals, forKey: .woidleTerminals)
        try container.encode(fires, forKey: .fires)
        try container.encode(extinguishers, forKey: .extinguishers)
        try container.encode(photoBooths, forKey: .photoBooths)
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
    // mazes.json in Documents was historically a backup/export aid only
    // (saveAll() below always wrote the WHOLE in-memory library to it on
    // every internal save(), which already fires continuously -- see
    // GridEditorView's .onChange(of: mazeStore.version) -- but loadAll()
    // never read it back in, so every relaunch reverted every floor to
    // the bundle regardless of what had been "saved").
    //
    // Floor Editor SAVE/RESET (Sept 19) changes this MINIMALLY: a floor's
    // entry in mazes.json is only allowed to override the bundle on load
    // if that floor's id is also in savedOverrideIDs() below -- i.e. the
    // user explicitly pressed SAVE on it at some point. Every other
    // floor keeps loading from the bundle exactly as before, even though
    // mazes.json may still (as always) contain stale snapshot data for
    // it from the ordinary continuous autosave. This is what makes SAVE
    // affect only the current floor, and what makes RESET's job just
    // "remove this one id from the override set" rather than needing to
    // touch mazes.json's contents at all.
    private static let savedOverrideIDsKey = "maze.savedFloorOverrideIDs"

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

    /// Floor ids the user has explicitly pressed SAVE on (see
    /// MazeStore.saveCurrentFloorAsOverride()). Only these ids' entries
    /// in mazes.json are allowed to override the bundled DefaultMazes.json
    /// on the next loadAll() -- kept in UserDefaults, the same lightweight
    /// mechanism this file already uses for the dev floor-jump memory
    /// above, rather than inventing a second on-disk file.
    static func savedOverrideIDs() -> Set<Int> {
        Set(UserDefaults.standard.array(forKey: savedOverrideIDsKey) as? [Int] ?? [])
    }

    private static func setSavedOverrideIDs(_ ids: Set<Int>) {
        UserDefaults.standard.set(Array(ids), forKey: savedOverrideIDsKey)
    }

    static func markSaved(_ id: Int) {
        setSavedOverrideIDs(savedOverrideIDs().union([id]))
    }

    static func clearSaved(_ id: Int) {
        setSavedOverrideIDs(savedOverrideIDs().subtracting([id]))
    }

    /// Bundled floors, with any explicitly-SAVEd floor's entry replaced
    /// by its local mazes.json version. Every id not in
    /// savedOverrideIDs() always comes straight from the bundle.
    static func loadAll() -> [Int: MazeRecord] {
        guard let url = Bundle.main.url(forResource: "DefaultMazes", withExtension: "json"),
              let bundled = readMaps(at: url) else { return [:] }
        print("[Maps] Loaded \(bundled.count) bundled floors")
        var merged = bundled
        let overrideIDs = savedOverrideIDs()
        if !overrideIDs.isEmpty, let localRecords = readMaps(at: fileURL) {
            for id in overrideIDs {
                if let localRecord = localRecords[id] {
                    merged[id] = localRecord
                }
            }
            print("[Maps] Applied \(overrideIDs.count) explicitly-saved local floor override(s)")
        }
        return merged
    }

    /// The floor's definition exactly as shipped in DefaultMazes.json,
    /// ignoring any local override -- used by RESET. Separate from
    /// loadAll() (which returns the merged view every other call site
    /// wants) since RESET specifically needs the un-merged bundled copy.
    static func loadBundledRecord(id: Int) -> MazeRecord? {
        guard let url = Bundle.main.url(forResource: "DefaultMazes", withExtension: "json"),
              let bundled = readMaps(at: url) else { return nil }
        return bundled[id]
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
    #if DEBUG
    /// Dev-only floor-jump memory (Eddie, Sept 13: dev floor-jump
    /// tool). Read/written ONLY inside #if DEBUG -- never touched in
    /// a Release/App-Store build, so this has zero production effect.
    /// devLastJumpedFloorKey stores the most recent floor picked from
    /// the "Jump to Floor" dev menu; devStartOnLastFloorKey is the
    /// opt-in toggle ("Start on last dev floor," default OFF) that
    /// makes init() boot into that floor instead of the lowest-numbered
    /// one.
    static let devLastJumpedFloorKey = "dev.lastJumpedFloorID"
    static let devStartOnLastFloorKey = "dev.startOnLastFloor"
    #endif

    static let elevatorCoordinate = GridCoordinate(row: 10, col: 7)

    /// Originally Floor 2 ONLY (Sept 17); now every floor except Floor
    /// 1 (Sept 19, THE HALLWAYS CORE): the elevator sits one block west
    /// of the building's normal fixed elevatorCoordinate, so each
    /// floor's arrival nook can put the elevator on that cell's west
    /// wall (facing east) with the EXIT sign/floor map/mission plaque
    /// arranged around the fixed CORE -- see startCoordinate/
    /// endCoordinate below, the only two places this is read.
    static let floor2ElevatorCoordinate = GridCoordinate(row: elevatorCoordinate.row, col: elevatorCoordinate.col - 1)

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

    /// Each placed object's authored Floor Object placement (Sept 21,
    /// first pass -- trash cans only; see FloorObjectPlacement's own
    /// doc comment). A separate dict, not folded into `objects` itself,
    /// matching the existing "one dict per authored attribute" shape
    /// fluorescentLights/pictureLights/wallLights already use rather
    /// than widening ObjectKind's own value type -- most ObjectKinds
    /// don't have this property yet. A coordinate with no entry here
    /// reads as FloorObjectPlacement()'s default (center, north-south),
    /// via floorObjectPlacement(at:) below -- never read directly.
    @Published private(set) var floorObjectPlacements: [GridCoordinate: FloorObjectPlacement] = [:]

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
    /// Cells on the current floor holding a manually-placed "Wall Top
    /// Light" (Suzanimator lighting pass, Sept 19), and which wall each
    /// one mounts on -- the project's first wall-mounted physical light
    /// source (the ceiling light hangs dead-center over its cell, fire
    /// sits centered on the floor). Placed the same way pictures/mirrors
    /// are (GridEditorView light-type popup + direction row + paint).
    /// HallwayScene.build(fromMaze:) draws a visible fixture against that
    /// wall plus a real omni light, same as it already does for the
    /// ceiling light/fire.
    @Published private(set) var lightBrightness: [LightBrightness] = []
    @Published private(set) var fluorescentLights: [GridCoordinate: FluorescentOrientation] = [:]
    @Published private(set) var pictureLights: [GridCoordinate: Direction] = [:]
    @Published private(set) var wallLights: [GridCoordinate: Direction] = [:]
    /// This floor's bathroom door(s) -- coord is the hallway-side
    /// cell the door is mounted in, direction is which wall. See
    /// MazeRecord.bathroomDoors' own doc comment for why this reuses
    /// mirrors' PicturePlacement shape. TapNavigationController reads
    /// this (constructor-injected, same as mirrors/roomDoors/etc.) to
    /// decide which cell boundaries start closed.
    @Published private(set) var bathroomDoors: [GridCoordinate: Direction] = [:]
    /// This floor's Window Room door(s) -- coord is the hallway-side
    /// cell the door is mounted in (same key convention as
    /// bathroomDoors), plus which wall of the ROOM beyond is the
    /// exterior window wall and which view asset it shows. See
    /// WindowRoomPlacement's own doc comment.
    @Published private(set) var windowRooms: [GridCoordinate: WindowRoomPlacement] = [:]
    /// Floor 7's aptitude-test terminal (and any future floor's) --
    /// same coord+direction shape as mirrors, see MazeRecord's own doc
    /// comment. At most one per floor for now.
    @Published private(set) var ticTacToeTerminals: [GridCoordinate: Direction] = [:]
    /// Floor 8's shell-game station (and any future floor's) -- same
    /// coord+direction shape as ticTacToeTerminals, see MazeRecord's
    /// own doc comment. At most one per floor for now.
    @Published private(set) var shellGameStations: [GridCoordinate: Direction] = [:]
    /// Floor 9's Rock Paper Scissors terminal (and any future floor's)
    /// -- same coord+direction shape as shellGameStations, see
    /// MazeRecord's own doc comment. At most one per floor for now.
    @Published private(set) var rockPaperScissorsTerminals: [GridCoordinate: Direction] = [:]
    /// Floor 10's Higher/Lower terminal (and any future floor's) --
    /// same coord+direction shape as rockPaperScissorsTerminals, see
    /// MazeRecord's own doc comment. At most one per floor for now.
    @Published private(set) var higherLowerTerminals: [GridCoordinate: Direction] = [:]
    @Published private(set) var fiveCardDrawTerminals: [GridCoordinate: Direction] = [:]
    @Published private(set) var simonTerminals: [GridCoordinate: Direction] = [:]
    @Published private(set) var hangmanTerminals: [GridCoordinate: Direction] = [:]
    @Published private(set) var connectFourTerminals: [GridCoordinate: Direction] = [:]
    @Published private(set) var checkersTerminals: [GridCoordinate: Direction] = [:]
    @Published private(set) var woidleTerminals: [GridCoordinate: Direction] = [:]
    @Published private(set) var fires: Set<GridCoordinate> = []
    @Published private(set) var extinguishers: [GridCoordinate: Direction] = [:]
    @Published private(set) var photoBooths: [GridCoordinate: (direction: Direction, expression: PhotoBoothExpression)] = [:]
    /// Sept 21 (Picture Size): same tuple-value shape as photoBooths
    /// above -- size defaults to .standard wherever it's populated
    /// from persisted data (every load site does `size ?? .standard`),
    /// so nothing downstream ever sees a "missing" size.
    @Published private(set) var pictures: [GridCoordinate: (direction: Direction, size: PictureSize)]
    /// See PictureImageSelection's own doc comment -- an explicit
    /// per-picture image override, set only through the in-world
    /// "Change Picture" menu. A coord absent here just keeps picking
    /// something fresh every rebuild, exactly as before.
    @Published private(set) var pictureImageSelections: [GridCoordinate: PictureImageSelection] = [:]
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

    /// Shared cab decoration is deliberately outside MazeRecord / floor SAVE and RESET.
    @Published private(set) var elevatorCabDecoration: ElevatorCabDecoration
    private let cabDecorationDefaults: UserDefaults

    func setElevatorCabDecoration(_ decoration: ElevatorCabDecoration) {
        elevatorCabDecoration = decoration
        decoration.save(to: cabDecorationDefaults)
    }

    init(cabDecorationDefaults: UserDefaults = .standard) {
        self.cabDecorationDefaults = cabDecorationDefaults
        self.elevatorCabDecoration = ElevatorCabDecoration.load(from: cabDecorationDefaults)
        let loaded = MazeLibrary.loadAll()
        if let firstID = loaded.keys.min() {
            library = loaded
            var startID = firstID
            #if DEBUG
            // Dev-only override: if the "Start on last dev floor"
            // toggle is on and that floor still exists in what was
            // just loaded, boot straight into it instead of the
            // lowest-numbered floor. Default OFF, so normal launches
            // (and every Release build) are completely unaffected.
            if UserDefaults.standard.bool(forKey: Self.devStartOnLastFloorKey) {
                let lastID = UserDefaults.standard.integer(forKey: Self.devLastJumpedFloorKey)
                if loaded[lastID] != nil {
                    startID = lastID
                }
            }
            #endif
            currentMazeID = startID
            cells = Set(loaded[startID]?.cells ?? [])
            nextMazeID = loaded[startID]?.nextMazeID
            objects = Dictionary(uniqueKeysWithValues: (loaded[startID]?.objects ?? []).map { ($0.coord, $0.kind) })
            floorObjectPlacements = Dictionary(uniqueKeysWithValues: (loaded[startID]?.objects ?? []).filter { $0.kind == .trashCan }.map { ($0.coord, FloorObjectPlacement(position: $0.floorPosition ?? .center, orientation: $0.floorOrientation ?? .northSouth)) })
            destinations = Dictionary(uniqueKeysWithValues: (loaded[startID]?.destinations ?? []).map { ($0.coord, $0.kind) })
            exitSigns = Dictionary(uniqueKeysWithValues: (loaded[startID]?.exitSigns ?? []).map { ($0.coord, $0.direction) })
            floorMaps = Dictionary(uniqueKeysWithValues: (loaded[startID]?.floorMaps ?? []).map { ($0.coord, $0.direction) })
            spotlights = Set(loaded[startID]?.spotlights ?? [])
            lightBrightness = loaded[startID]?.lightBrightness ?? []
            missionSigns = Dictionary(uniqueKeysWithValues: (loaded[startID]?.missionSigns ?? []).map { ($0.coord, $0.direction) })
            mirrors = Dictionary(uniqueKeysWithValues: (loaded[startID]?.mirrors ?? []).map { ($0.coord, $0.direction) })
            fluorescentLights = Dictionary(uniqueKeysWithValues: (loaded[startID]?.fluorescentLights ?? []).map { ($0.coord, $0.orientation) })
            pictureLights = Dictionary(uniqueKeysWithValues: (loaded[startID]?.pictureLights ?? []).map { ($0.coord, $0.direction) })
            wallLights = Dictionary(uniqueKeysWithValues: (loaded[startID]?.wallLights ?? []).map { ($0.coord, $0.direction) })
            bathroomDoors = Dictionary(uniqueKeysWithValues: (loaded[startID]?.bathroomDoors ?? []).map { ($0.coord, $0.direction) })
            windowRooms = Dictionary(uniqueKeysWithValues: (loaded[startID]?.windowRooms ?? []).map { ($0.coord, $0) })
            ticTacToeTerminals = Dictionary(uniqueKeysWithValues: (loaded[startID]?.ticTacToeTerminals ?? []).map { ($0.coord, $0.direction) })
            shellGameStations = Dictionary(uniqueKeysWithValues: (loaded[startID]?.shellGameStations ?? []).map { ($0.coord, $0.direction) })
            rockPaperScissorsTerminals = Dictionary(uniqueKeysWithValues: (loaded[startID]?.rockPaperScissorsTerminals ?? []).map { ($0.coord, $0.direction) })
            higherLowerTerminals = Dictionary(uniqueKeysWithValues: (loaded[startID]?.higherLowerTerminals ?? []).map { ($0.coord, $0.direction) })
            fiveCardDrawTerminals = Dictionary(uniqueKeysWithValues: (loaded[startID]?.fiveCardDrawTerminals ?? []).map { ($0.coord, $0.direction) })
            simonTerminals = Dictionary(uniqueKeysWithValues: (loaded[startID]?.simonTerminals ?? []).map { ($0.coord, $0.direction) })
            hangmanTerminals = Dictionary(uniqueKeysWithValues: (loaded[startID]?.hangmanTerminals ?? []).map { ($0.coord, $0.direction) })
            connectFourTerminals = Dictionary(uniqueKeysWithValues: (loaded[startID]?.connectFourTerminals ?? []).map { ($0.coord, $0.direction) })
            checkersTerminals = Dictionary(uniqueKeysWithValues: (loaded[startID]?.checkersTerminals ?? []).map { ($0.coord, $0.direction) })
            woidleTerminals = Dictionary(uniqueKeysWithValues: (loaded[startID]?.woidleTerminals ?? []).map { ($0.coord, $0.direction) })
            pictures = Dictionary(uniqueKeysWithValues: (loaded[startID]?.pictures ?? []).map { ($0.coord, ($0.direction, $0.size ?? .standard)) })
            fires = Set((loaded[startID]?.fires ?? []).map(\.coord))
            extinguishers = Dictionary(uniqueKeysWithValues: (loaded[startID]?.extinguishers ?? []).map { ($0.coord, $0.direction) })
            photoBooths = Dictionary(uniqueKeysWithValues: (loaded[startID]?.photoBooths ?? []).map { ($0.coord, ($0.direction, $0.expression)) })
            roomDoors = Dictionary(uniqueKeysWithValues: (loaded[startID]?.roomDoors ?? []).map { ($0.coord, $0) })
            itemRooms = Dictionary(uniqueKeysWithValues: (loaded[startID]?.itemRooms ?? []).map { ($0.coord, $0.roomNumber) })
            picturesUseCameraRoll = loaded[startID]?.picturesUseCameraRoll ?? false
            missionHeading = loaded[startID]?.missionHeading ?? ""
            missionBody = loaded[startID]?.missionBody ?? ""
            missionObjectKind = loaded[startID]?.missionObjectKind
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
            floorObjectPlacements = [:]
            destinations = [:]
            exitSigns = [:]
            floorMaps = [:]
            spotlights = []
        fluorescentLights = [:]
        pictureLights = [:]
        lightBrightness = []
            missionSigns = [Self.missionCoordinate: .south]
            pictures = [:]
            pictureImageSelections = [:]
            mirrors = [:]
            wallLights = [:]
            windowRooms = [:]
            ticTacToeTerminals = [:]
            shellGameStations = [:]
            rockPaperScissorsTerminals = [:]
            higherLowerTerminals = [:]
            fiveCardDrawTerminals = [:]
            simonTerminals = [:]
            hangmanTerminals = [:]
            connectFourTerminals = [:]
            checkersTerminals = [:]
            woidleTerminals = [:]
            fires = []
            extinguishers = [:]
            photoBooths = [:]
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
        if currentMazeID == 1 { return floorOneEntryCoordinate }
        // THE HALLWAYS CORE (Sept 19): every floor 2 and up now shares
        // the same fixed arrival-area geometry Floor 3 proved out, so
        // this is no longer floor-2/floor-3-only -- floor 1 already
        // returned above, so everything reaching here just wants
        // floor2ElevatorCoordinate.
        return Self.floor2ElevatorCoordinate
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
        // THE HALLWAYS CORE (Sept 19): every floor 2 and up now shares
        // the same fixed arrival-area geometry Floor 3 proved out, so
        // this is no longer floor-2/floor-3-only.
        cells.isEmpty ? nil : (currentMazeID == 1 ? Self.elevatorCoordinate : Self.floor2ElevatorCoordinate)
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
        pictures[coord]?.direction
    }

    /// Defaults to .standard for a picture with no stored size (either
    /// legacy data, or simply never resized) -- same default the
    /// loading paths themselves already apply, kept here too so any
    /// caller asking directly gets the same answer.
    func pictureSize(at coord: GridCoordinate) -> PictureSize {
        pictures[coord]?.size ?? .standard
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
        // TEMPORARY DIAGNOSTIC (Eddie, Sept 20, object-placement trace) -- remove after root cause is found.
        NSLog("%@", "[PLACEDIAG] MazeStore.placeObject(\(kind), at: \(coord)) called; cells.contains(coord)=\(cells.contains(coord)); versionBefore=\(version)")
        guard cells.contains(coord) else {
            NSLog("%@", "[PLACEDIAG] MazeStore.placeObject: coord \(coord) NOT in cells -- REJECTED, nothing mutated")
            return
        }
        NSLog("%@", "[PLACEDIAG] OBJECTS BEFORE=\(objects)")
        objects[coord] = kind
        if kind == .envelope || kind == .key {
            assignUnassignedRoomItems()
        } else {
            itemRooms[coord] = nil
        }
        version += 1
        NSLog("%@", "[PLACEDIAG] MazeStore.placeObject: DONE -- objects[\(coord)]=\(String(describing: objects[coord])) versionAfter=\(version)")
    }

    func removeObject(at coord: GridCoordinate) {
        guard objects[coord] != nil else { return }
        objects[coord] = nil
        itemRooms[coord] = nil
        floorObjectPlacements[coord] = nil
        version += 1
    }

    /// A missing entry reads as FloorObjectPlacement()'s own default
    /// (center, north-south) -- see that struct's doc comment. Never
    /// read floorObjectPlacements[coord] directly; always through this.
    func floorObjectPlacement(at coord: GridCoordinate) -> FloorObjectPlacement {
        floorObjectPlacements[coord] ?? FloorObjectPlacement()
    }

    /// Sept 21 (Floor Object placement, first pass): the live-move
    /// counterpart of placeFluorescent/removeFluorescent just below in
    /// this file -- called from DecoratorState.changeFloorPosition/
    /// changeFloorOrientation only (guarded there to trash cans that
    /// already exist), so no cells/kind validation is repeated here.
    /// Bumps version like every other authored mutation, but this is
    /// safe against an unwanted scene rebuild while Decorator is open --
    /// see this method's own callers' doc comments for why (sceneVersion
    /// only reconciles with mazeStore.version at floor-switch or
    /// grid-editor-dismiss checkpoints, not continuously).
    func setFloorObjectPlacement(_ placement: FloorObjectPlacement, at coord: GridCoordinate) {
        floorObjectPlacements[coord] = placement
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

    /// Which direction(s) of `cell` are genuinely EXTERIOR --
    /// i.e. the building's own outer wall, not just "happens to be
    /// closed." A perimeter cell (row 0/14 or col 0/14) has exactly
    /// one exterior side, except at a building corner, which has two
    /// -- Eddie, Sept 15: "interior cells cannot have windows" (this
    /// building is fixed at 15x15, rows/cols 0-14), and a corner
    /// should pick ONE deterministic side rather than offer an
    /// elaborate corner-office UI. Priority order below (north,
    /// south, west, east) is that deterministic choice.
    func windowExteriorDirection(for cell: GridCoordinate) -> Direction? {
        var exteriorSides: [Direction] = []
        if cell.row == 0 { exteriorSides.append(.north) }
        if cell.row == 14 { exteriorSides.append(.south) }
        if cell.col == 0 { exteriorSides.append(.west) }
        if cell.col == 14 { exteriorSides.append(.east) }
        let priority: [Direction] = [.north, .south, .west, .east]
        return priority.first(where: exteriorSides.contains)
    }

    /// Places a Window Room door at `coord`, opening `direction` into
    /// the neighbor cell -- same physical swinging-door architecture
    /// as a bathroom door (TapNavigationController gates movement
    /// through it, same open/close treatment), but unlike every
    /// other placer here this is ALSO guarded on the NEIGHBOR's own
    /// geometry, not just coord's: the room beyond the door must
    /// already be an open cell AND sit on the building's perimeter,
    /// since that's what gives the window a genuine exterior wall to
    /// look out through. A neighbor that fails that check is a clean
    /// rejection (this just returns, same as every other placer's
    /// guard) -- never a silent repositioning to some other cell.
    func placeWindowRoom(_ direction: Direction, at coord: GridCoordinate) {
        let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
        guard cells.contains(coord), cells.contains(neighbor),
              coord != Self.elevatorCoordinate, coord != Self.missionCoordinate,
              bathroomDoors[coord] == nil, roomDoors[coord] == nil, mirrors[coord] == nil,
              floorMaps[coord] == nil, pictures[coord] == nil, destinations[coord] == nil,
              let windowDirection = windowExteriorDirection(for: neighbor) else { return }
        windowRooms[coord] = WindowRoomPlacement(coord: coord, direction: direction, windowDirection: windowDirection, viewAssetID: windowRooms[coord]?.viewAssetID ?? "nycPlaceholder")
        version += 1
    }

    func removeWindowRoom(at coord: GridCoordinate) {
        guard windowRooms.removeValue(forKey: coord) != nil else { return }
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

    func lightBrightnessLevel(_ kind: AuthoredLightKind, at coord: GridCoordinate) -> Int {
        LightBrightness.level(for: kind, at: coord, in: lightBrightness)
    }

    private func setLightBrightness(_ level: Int, kind: AuthoredLightKind, at coord: GridCoordinate) {
        lightBrightness.removeAll { $0.coord == coord && $0.kind == kind }
        let clamped = min(kind.levelRange.upperBound, max(kind.levelRange.lowerBound, level))
        lightBrightness.append(LightBrightness(coord: coord, kind: kind, level: clamped))
    }

    func wallLightDirection(at coord: GridCoordinate) -> Direction? { wallLights[coord] }

    func canPlaceWallLight(_ direction: Direction, at coord: GridCoordinate) -> Bool {
        let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
        return cells.contains(coord) && !cells.contains(neighbor) &&
            coord != Self.elevatorCoordinate && roomDoors[coord] == nil &&
            pictures[coord] == nil && floorMaps[coord] == nil && destinations[coord] == nil &&
            mirrors[coord] == nil && missionSigns[coord] != direction && wallLights[coord] == nil
    }

    func placeWallLight(_ direction: Direction, at coord: GridCoordinate, brightness: Int = 3) {
        guard wallLights[coord] == direction || canPlaceWallLight(direction, at: coord) else { return }
        wallLights[coord] = direction
        setLightBrightness(brightness, kind: .wall, at: coord)
        version += 1
    }

    func removeWallLight(at coord: GridCoordinate) {
        guard wallLights.removeValue(forKey: coord) != nil else { return }
        lightBrightness.removeAll { $0.coord == coord && $0.kind == .wall }
        version += 1
    }

    func photoBoothDirection(at coord: GridCoordinate) -> Direction? { photoBooths[coord]?.direction }

    func canPlacePhotoBooth(_ direction: Direction, at coord: GridCoordinate) -> Bool {
        let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
        return cells.contains(coord) && !cells.contains(neighbor) &&
            coord != Self.elevatorCoordinate && roomDoors[coord] == nil &&
            pictures[coord] == nil && floorMaps[coord] == nil && destinations[coord] == nil &&
            mirrors[coord] == nil && wallLights[coord] == nil && missionSigns[coord] != direction &&
            photoBooths[coord] == nil
    }

    /// Places a new booth, or re-authors the expression of the one already
    /// at `coord` when the direction is unchanged (mirrors the
    /// placeWallLight re-author bypass -- changing direction at an occupied
    /// coord requires removing and re-placing, same as wall lights).
    /// Deletion is already handled generically by deleteContent(_:at:).
    func placePhotoBooth(_ direction: Direction, expression: PhotoBoothExpression, at coord: GridCoordinate) {
        guard photoBooths[coord]?.direction == direction || canPlacePhotoBooth(direction, at: coord) else { return }
        photoBooths[coord] = (direction, expression)
        version += 1
    }

    /// Sept 21 (3D Decorator wall authoring, live Picture ADD). The
    /// full occupancy/legality check the OTHER wall-mounted types
    /// already have (canPlaceMirror/canPlaceWallLight/
    /// canPlacePhotoBooth) -- placePicture's own guard just below only
    /// ever checked roomDoors/mirrors/cells, which was enough for the
    /// Floor Editor's paint-a-legal-cell flow but not for a live
    /// Decorator wall tap, which must also refuse a wall that isn't
    /// actually solid or is already claimed by another wall-mounted
    /// object. This is additive -- existing Floor Editor Picture
    /// placement keeps calling placePicture's own guard, unchanged.
    func canPlacePicture(_ direction: Direction, at coord: GridCoordinate) -> Bool {
        let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
        return cells.contains(coord) && !cells.contains(neighbor) &&
            coord != Self.elevatorCoordinate && roomDoors[coord] == nil &&
            pictures[coord] == nil && floorMaps[coord] == nil && destinations[coord] == nil &&
            mirrors[coord] == nil && wallLights[coord] == nil && photoBooths[coord] == nil &&
            missionSigns[coord] != direction
    }

    /// `size` nil preserves whatever was already authored at this
    /// coord (defaulting to Standard for a genuinely new placement) --
    /// the Floor Editor's Picture tool passes an explicit size (same
    /// "re-author with whatever's currently selected" convention
    /// placeWallLight's `brightness` param already uses), while every
    /// other existing call site (tests, recovery) keeps working
    /// unchanged with the 2-argument form.
    func placePicture(_ direction: Direction, at coord: GridCoordinate, size: PictureSize? = nil) {
        NSLog("%@", "[PLACEDIAG] STORE PICTURE ENTER coord=\(coord) open=\(cells.contains(coord)) door=\(String(describing: roomDoors[coord])) mirror=\(String(describing: mirrors[coord])) before=\(String(describing: pictures[coord])) version=\(version)")
        guard roomDoors[coord] == nil, mirrors[coord] == nil, cells.contains(coord) else { return }
        let resolvedSize = size ?? pictures[coord]?.size ?? .standard
        pictures[coord] = (direction, resolvedSize)
        version += 1
        NSLog("%@", "[PLACEDIAG] STORE PICTURE AFTER=\(String(describing: pictures[coord])) version=\(version)")
    }

    func removePicture(at coord: GridCoordinate) {
        guard pictures[coord] != nil else { return }
        pictures[coord] = nil
        pictureImageSelections.removeValue(forKey: coord) // no picture left to have an explicit image choice
        version += 1
    }

    /// Sets (or, with nil, clears) an explicit image choice for the
    /// Picture at `coord`, made through the in-world "Change Picture"
    /// menu -- see PictureImageSelection's own doc comment. A picture
    /// must already be there; this never places one. Clearing reverts
    /// that one picture to the original "pick something fresh every
    /// rebuild" behavior.
    func setPictureImageSelection(_ selection: PictureImageSelection?, at coord: GridCoordinate) {
        guard pictures[coord] != nil else { return }
        pictureImageSelections[coord] = selection
        version += 1
    }

    /// Sets the authored Size (Small/Standard/Poster/Full Length -- see
    /// PictureSize's own doc comment) of the Picture already at
    /// `coord`. Same "must already be there, never places one" shape as
    /// setPictureImageSelection above -- this is Decorator's and the
    /// Floor Editor's shared entry point for changing a picture's size.
    func setPictureSize(_ size: PictureSize, at coord: GridCoordinate) {
        guard let existing = pictures[coord] else { return }
        pictures[coord] = (existing.direction, size)
        version += 1
    }

    /// Places a ceiling spotlight at `coord` -- same open-cell-only rule
    /// as everything else. No direction to pick (it hangs dead-center),
    /// so unlike placeFloorMap this is just on/off.
    func placeSpotlight(at coord: GridCoordinate, brightness: Int = 3) {
        guard cells.contains(coord) else { return }
        spotlights.insert(coord)
        setLightBrightness(brightness, kind: .ceiling, at: coord)
        version += 1
    }

    func removeSpotlight(at coord: GridCoordinate) {
        guard spotlights.contains(coord) else { return }
        spotlights.remove(coord)
        lightBrightness.removeAll { $0.coord == coord && $0.kind == .ceiling }
        version += 1
    }

    /// Places FIRE at `coord` -- the project's other existing physical
    /// light source (runtime: animated flame + real omni glow in
    /// HallwayScene.makeFireNode). Same open-cell-only, on/off shape as
    /// the ceiling light; `fires` has always been persisted and built,
    /// this just makes it authorable from the editor's Light tool.
    func placeFire(at coord: GridCoordinate, brightness: Int = 3) {
        guard cells.contains(coord) else { return }
        fires.insert(coord)
        setLightBrightness(brightness, kind: .fire, at: coord)
        version += 1
    }

    func removeFire(at coord: GridCoordinate) {
        guard fires.contains(coord) else { return }
        fires.remove(coord)
        lightBrightness.removeAll { $0.coord == coord && $0.kind == .fire }
        version += 1
    }

    func hasFire(_ coord: GridCoordinate) -> Bool {
        fires.contains(coord)
    }

    func setOpen(_ coord: GridCoordinate) {
        guard !cells.contains(coord) else { return }
        cells.insert(coord)
        version += 1
    }

    func setClosed(_ coord: GridCoordinate) {
        guard cells.contains(coord) else { return }
        cells.remove(coord)
        lightBrightness.removeAll { $0.coord == coord }
        objects.removeValue(forKey: coord) // a wall can't hold an object
        destinations.removeValue(forKey: coord)
        exitSigns.removeValue(forKey: coord)
        floorMaps.removeValue(forKey: coord)
        spotlights.remove(coord)
        fires.remove(coord)
        missionSigns.removeValue(forKey: coord)
        pictures.removeValue(forKey: coord)
        pictureImageSelections.removeValue(forKey: coord)
        mirrors.removeValue(forKey: coord)
        fluorescentLights.removeValue(forKey: coord)
        pictureLights.removeValue(forKey: coord)
        wallLights.removeValue(forKey: coord)
        roomDoors.removeValue(forKey: coord)
        itemRooms.removeValue(forKey: coord)
        windowRooms.removeValue(forKey: coord)
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
        // Sept 20 (autosave pass): was plain save() -- this doesn't
        // bump `version` (see setMissionText's own comment on why
        // not), so it never went through GridEditorView's version-
        // watching autosave at all, meaning this one editable
        // property was never marked as a local override the way
        // every other edit now is. saveCurrentFloorAsOverride() is
        // the same "flush + mark this floor as having a real local
        // override" call every other completed edit ends up making.
        saveCurrentFloorAsOverride()
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
    /// Set immediately before a `version` bump that comes from LOADING
    /// floor content rather than editing it (switchTo(id:) finishing a
    /// floor switch, resetCurrentFloorToDefault() restoring the
    /// bundled default) -- consumed by the very next autosave via
    /// autosaveAfterVersionChange(), regardless of how much later
    /// SwiftUI's onChange(of: version) actually fires relative to the
    /// synchronous function that set it. Every other version bump (an
    /// editor mutation, undo(), clear()) leaves this false, so the
    /// ordinary case still marks the edited floor as a persistent
    /// local override -- the same effect the old manual SAVE button
    /// used to require a separate tap for (Sept 20 autosave pass).
    private(set) var versionChangeIsFloorLoad = false

    /// Sept 20 (autosave pass): the single place that decides what a
    /// `version` change means for persistence, called from
    /// GridEditorView's `.onChange(of: mazeStore.version)`. A floor
    /// switch or a RESET already flagged their own version bump via
    /// versionChangeIsFloorLoad above -- for those, just flush to disk
    /// exactly as save() always has, and leave override status alone.
    /// Anything else reaching here is a real, completed edit (a paint
    /// stroke, an object placement/removal, undo, clear, a mission-text
    /// change, etc.) and gets the same treatment the old manual SAVE
    /// button gave: flush to disk AND mark this floor as a local
    /// override, so it's the copy that loads back on the next launch.
    func autosaveAfterVersionChange() {
        if versionChangeIsFloorLoad {
            versionChangeIsFloorLoad = false
            save()
        } else {
            saveCurrentFloorAsOverride()
        }
    }

    func save() {
        // Eddie, Sept 15 (2nd build failure after adding Window Room):
        // Swift's type checker timed out on the single giant
        // MazeRecord(...) call below when it combined ~20 inline
        // `.map { ... }` transformations with a large memberwise
        // initializer call. Precomputing every transformation as its
        // own named local (following the placements/destinationPlacements/
        // etc. pattern already used for the first few fields) gives the
        // compiler a series of small, concrete expressions instead of one
        // enormous constraint-solving problem. Purely a compiler-
        // complexity workaround -- the resulting MazeRecord's field
        // values are identical to before.
        let cellsArray = Array(cells)
        let spotlightsArray = Array(spotlights)
        let placements = objects.map { entry -> ObjectPlacement in
            guard entry.value == .trashCan, let placement = floorObjectPlacements[entry.key] else {
                return ObjectPlacement(coord: entry.key, kind: entry.value)
            }
            return ObjectPlacement(coord: entry.key, kind: entry.value, floorPosition: placement.position, floorOrientation: placement.orientation)
        }
        let destinationPlacements = destinations.map { ObjectPlacement(coord: $0.key, kind: $0.value) }
        let exitSignPlacements = exitSigns.map { ExitSignPlacement(coord: $0.key, direction: $0.value) }
        let floorMapPlacements = floorMaps.map { FloorMapPlacement(coord: $0.key, direction: $0.value) }
        let missionSignPlacements = missionSigns.map { MissionSignPlacement(coord: $0.key, direction: $0.value) }
        let picturePlacements = pictures.map { PictureSizePlacement(coord: $0.key, direction: $0.value.direction, size: $0.value.size) }
        let mirrorPlacements = mirrors.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        let wallLightPlacements = wallLights.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        // Eddie, Sept 15 (3rd pass): bathroomDoors was never actually
        // passed into MazeRecord(...) below -- it has a default value
        // ([]) in MazeRecord's own declaration, so the call compiled
        // fine without it, but that meant every save() silently wrote
        // bathroomDoors: [] to disk regardless of what was actually
        // placed, discarding it on the next load. Restored here, in
        // its correct declared position (right after mirrors, right
        // before windowRooms -- see MazeRecord's own field order) so
        // it round-trips the same way every other placement here
        // already does.
        let bathroomDoorPlacements = bathroomDoors.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        // windowRooms is placed here, immediately after
        // bathroomDoorPlacements, to match WindowRoomPlacement's
        // declared position in MazeRecord -- it was previously placed
        // next to roomDoors below, which put it out of the memberwise
        // initializer's required declaration order and was itself
        // contributing to the type-checker's failure, independent of
        // sheer expression size. See report for detail.
        let windowRoomPlacements = Array(windowRooms.values)
        let ticTacToeTerminalPlacements = ticTacToeTerminals.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        let shellGameStationPlacements = shellGameStations.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        let rockPaperScissorsTerminalPlacements = rockPaperScissorsTerminals.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        let higherLowerTerminalPlacements = higherLowerTerminals.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        let fiveCardDrawTerminalPlacements = fiveCardDrawTerminals.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        let simonTerminalPlacements = simonTerminals.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        let hangmanTerminalPlacements = hangmanTerminals.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        let connectFourTerminalPlacements = connectFourTerminals.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        let checkersTerminalPlacements = checkersTerminals.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        let woidleTerminalPlacements = woidleTerminals.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        let firePlacements = fires.map { FirePlacement(coord: $0) }
        let extinguisherPlacements = extinguishers.map { ExtinguisherPlacement(coord: $0.key, direction: $0.value) }
        let photoBoothPlacements = photoBooths.map { PhotoBoothPlacement(coord: $0.key, direction: $0.value.direction, expression: $0.value.expression) }
        let roomDoorPlacements = Array(roomDoors.values)
        let itemRoomPlacements = itemRooms.map { RoomAssignment(coord: $0.key, roomNumber: $0.value) }
        var record = MazeRecord(id: currentMazeID, cells: cellsArray, nextMazeID: nextMazeID, objects: placements, destinations: destinationPlacements, exitSigns: exitSignPlacements, floorMaps: floorMapPlacements, spotlights: spotlightsArray, missionSigns: missionSignPlacements, pictures: picturePlacements, mirrors: mirrorPlacements, wallLights: wallLightPlacements, bathroomDoors: bathroomDoorPlacements, windowRooms: windowRoomPlacements, ticTacToeTerminals: ticTacToeTerminalPlacements, shellGameStations: shellGameStationPlacements, rockPaperScissorsTerminals: rockPaperScissorsTerminalPlacements, higherLowerTerminals: higherLowerTerminalPlacements, fiveCardDrawTerminals: fiveCardDrawTerminalPlacements, simonTerminals: simonTerminalPlacements, hangmanTerminals: hangmanTerminalPlacements, connectFourTerminals: connectFourTerminalPlacements, checkersTerminals: checkersTerminalPlacements, woidleTerminals: woidleTerminalPlacements, fires: firePlacements, extinguishers: extinguisherPlacements, photoBooths: photoBoothPlacements, roomDoors: roomDoorPlacements, itemRooms: itemRoomPlacements, picturesUseCameraRoll: picturesUseCameraRoll, missionHeading: missionHeading, missionBody: missionBody, missionObjectKind: missionObjectKind)
        record.fluorescentLights = fluorescentLights.map { FluorescentPlacement(coord: $0.key, orientation: $0.value) }
        record.pictureLights = pictureLights.map { PicturePlacement(coord: $0.key, direction: $0.value) }
        record.lightBrightness = lightBrightness
        record.pictureImageSelections = pictureImageSelections.map { PictureSelectionPlacement(coord: $0.key, selection: $0.value) }
        library[currentMazeID] = record
        MazeLibrary.saveAll(library)
    }

    /// Marks the CURRENT floor's edited state as a persistent local
    /// override, the one thing MazeLibrary.loadAll() checks before
    /// letting mazes.json's copy of a floor win over the shipped
    /// bundle -- flushes the live state the same way save() always
    /// has, then records the override. Originally a manual Floor
    /// Editor SAVE button (Sept 19); as of Sept 20 this is called
    /// automatically by autosaveAfterVersionChange() after every real
    /// edit, so the button was removed -- this function itself is
    /// unchanged and still the one place that marks an override. Only
    /// ever touches currentMazeID's own entry -- every other floor's
    /// override status (or lack of one) is left exactly as it was.
    func saveCurrentFloorAsOverride() {
        save()
        MazeLibrary.markSaved(currentMazeID)
    }

    /// Floor Editor RESET button (Sept 19). Discards the CURRENT
    /// floor's local override (if any) and reloads it from the
    /// canonical, immutable DefaultMazes.json -- never touches that
    /// bundled file itself, never touches any other floor's cells,
    /// objects, or override status. Mirrors the field-by-field
    /// assignment switchTo(id:) already uses to bring a MazeRecord's
    /// values into the live @Published properties (duplicated rather
    /// than factored out, to avoid touching that already-verified,
    /// heavily-used code path for this addition).
    func resetCurrentFloorToDefault() {
        guard let record = MazeLibrary.loadBundledRecord(id: currentMazeID) else {
            print("[Maps] No bundled default exists for floor \(currentMazeID); reset ignored")
            return
        }
        snapshotForUndo() // same "make the destructive action undoable within this session" pattern clear() already uses, rather than a heavier confirmation flow
        cells = Set(record.cells)
        nextMazeID = record.nextMazeID
        objects = Dictionary(uniqueKeysWithValues: record.objects.map { ($0.coord, $0.kind) })
        floorObjectPlacements = Dictionary(uniqueKeysWithValues: record.objects.filter { $0.kind == .trashCan }.map { ($0.coord, FloorObjectPlacement(position: $0.floorPosition ?? .center, orientation: $0.floorOrientation ?? .northSouth)) })
        destinations = Dictionary(uniqueKeysWithValues: record.destinations.map { ($0.coord, $0.kind) })
        exitSigns = Dictionary(uniqueKeysWithValues: record.exitSigns.map { ($0.coord, $0.direction) })
        floorMaps = Dictionary(uniqueKeysWithValues: record.floorMaps.map { ($0.coord, $0.direction) })
        lightBrightness = record.lightBrightness
        spotlights = Set(record.spotlights)
        missionSigns = Dictionary(uniqueKeysWithValues: record.missionSigns.map { ($0.coord, $0.direction) })
        mirrors = Dictionary(uniqueKeysWithValues: record.mirrors.map { ($0.coord, $0.direction) })
            fluorescentLights = Dictionary(uniqueKeysWithValues: record.fluorescentLights.map { ($0.coord, $0.orientation) })
            pictureLights = Dictionary(uniqueKeysWithValues: record.pictureLights.map { ($0.coord, $0.direction) })
            wallLights = Dictionary(uniqueKeysWithValues: record.wallLights.map { ($0.coord, $0.direction) })
        bathroomDoors = Dictionary(uniqueKeysWithValues: record.bathroomDoors.map { ($0.coord, $0.direction) })
        windowRooms = Dictionary(uniqueKeysWithValues: record.windowRooms.map { ($0.coord, $0) })
        ticTacToeTerminals = Dictionary(uniqueKeysWithValues: record.ticTacToeTerminals.map { ($0.coord, $0.direction) })
        shellGameStations = Dictionary(uniqueKeysWithValues: record.shellGameStations.map { ($0.coord, $0.direction) })
        rockPaperScissorsTerminals = Dictionary(uniqueKeysWithValues: record.rockPaperScissorsTerminals.map { ($0.coord, $0.direction) })
        higherLowerTerminals = Dictionary(uniqueKeysWithValues: record.higherLowerTerminals.map { ($0.coord, $0.direction) })
        fiveCardDrawTerminals = Dictionary(uniqueKeysWithValues: record.fiveCardDrawTerminals.map { ($0.coord, $0.direction) })
        simonTerminals = Dictionary(uniqueKeysWithValues: record.simonTerminals.map { ($0.coord, $0.direction) })
        hangmanTerminals = Dictionary(uniqueKeysWithValues: record.hangmanTerminals.map { ($0.coord, $0.direction) })
        connectFourTerminals = Dictionary(uniqueKeysWithValues: record.connectFourTerminals.map { ($0.coord, $0.direction) })
        checkersTerminals = Dictionary(uniqueKeysWithValues: record.checkersTerminals.map { ($0.coord, $0.direction) })
        woidleTerminals = Dictionary(uniqueKeysWithValues: record.woidleTerminals.map { ($0.coord, $0.direction) })
        fires = Set(record.fires.map(\.coord))
        extinguishers = Dictionary(uniqueKeysWithValues: record.extinguishers.map { ($0.coord, $0.direction) })
        photoBooths = Dictionary(uniqueKeysWithValues: record.photoBooths.map { ($0.coord, ($0.direction, $0.expression)) })
        pictures = Dictionary(uniqueKeysWithValues: record.pictures.map { ($0.coord, ($0.direction, $0.size ?? .standard)) })
        pictureImageSelections = Dictionary(uniqueKeysWithValues: record.pictureImageSelections.map { ($0.coord, $0.selection) })
        roomDoors = Dictionary(uniqueKeysWithValues: record.roomDoors.map { ($0.coord, $0) })
        itemRooms = Dictionary(uniqueKeysWithValues: record.itemRooms.map { ($0.coord, $0.roomNumber) })
        picturesUseCameraRoll = record.picturesUseCameraRoll
        missionHeading = record.missionHeading
        missionBody = record.missionBody
        missionObjectKind = record.missionObjectKind
        // This version bump is RESET loading the bundled default back
        // in, not a user edit -- see versionChangeIsFloorLoad's own
        // comment. Without this, GridEditorView's autosave hook would
        // see the version change a moment later and immediately
        // re-mark this floor as having a local override again, right
        // after the clearSaved() below just removed that override --
        // silently undoing RESET the instant it finished.
        versionChangeIsFloorLoad = true
        version += 1
        MazeLibrary.clearSaved(currentMazeID)
        save() // re-derives the record from the now-reset live properties and writes it to mazes.json; harmless since this id is no longer in the override set, so loadAll() ignores it on next launch regardless
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
        // TEMPORARY DIAGNOSTIC (Eddie, Sept 16): save() is a
        // synchronous disk write -- timed here in case it's adding
        // real latency between arrival and the scene actually
        // swapping.
        let arrivalDiagSaveStart = Date().timeIntervalSince1970
        save()
        navLog("[ARRIVALDIAG] switchTo(id:) save() took \(String(format: "%.4f", Date().timeIntervalSince1970 - arrivalDiagSaveStart))s")
        currentMazeID = id
        if let record = library[id] {
            cells = Set(record.cells)
            nextMazeID = record.nextMazeID
            objects = Dictionary(uniqueKeysWithValues: record.objects.map { ($0.coord, $0.kind) })
            floorObjectPlacements = Dictionary(uniqueKeysWithValues: record.objects.filter { $0.kind == .trashCan }.map { ($0.coord, FloorObjectPlacement(position: $0.floorPosition ?? .center, orientation: $0.floorOrientation ?? .northSouth)) })
            destinations = Dictionary(uniqueKeysWithValues: record.destinations.map { ($0.coord, $0.kind) })
            exitSigns = Dictionary(uniqueKeysWithValues: record.exitSigns.map { ($0.coord, $0.direction) })
            floorMaps = Dictionary(uniqueKeysWithValues: record.floorMaps.map { ($0.coord, $0.direction) })
            lightBrightness = record.lightBrightness
        spotlights = Set(record.spotlights)
            missionSigns = Dictionary(uniqueKeysWithValues: record.missionSigns.map { ($0.coord, $0.direction) })
            mirrors = Dictionary(uniqueKeysWithValues: record.mirrors.map { ($0.coord, $0.direction) })
            fluorescentLights = Dictionary(uniqueKeysWithValues: record.fluorescentLights.map { ($0.coord, $0.orientation) })
            pictureLights = Dictionary(uniqueKeysWithValues: record.pictureLights.map { ($0.coord, $0.direction) })
            wallLights = Dictionary(uniqueKeysWithValues: record.wallLights.map { ($0.coord, $0.direction) })
            bathroomDoors = Dictionary(uniqueKeysWithValues: record.bathroomDoors.map { ($0.coord, $0.direction) })
            windowRooms = Dictionary(uniqueKeysWithValues: record.windowRooms.map { ($0.coord, $0) })
            ticTacToeTerminals = Dictionary(uniqueKeysWithValues: record.ticTacToeTerminals.map { ($0.coord, $0.direction) })
            shellGameStations = Dictionary(uniqueKeysWithValues: record.shellGameStations.map { ($0.coord, $0.direction) })
            rockPaperScissorsTerminals = Dictionary(uniqueKeysWithValues: record.rockPaperScissorsTerminals.map { ($0.coord, $0.direction) })
            higherLowerTerminals = Dictionary(uniqueKeysWithValues: record.higherLowerTerminals.map { ($0.coord, $0.direction) })
            fiveCardDrawTerminals = Dictionary(uniqueKeysWithValues: record.fiveCardDrawTerminals.map { ($0.coord, $0.direction) })
            simonTerminals = Dictionary(uniqueKeysWithValues: record.simonTerminals.map { ($0.coord, $0.direction) })
            hangmanTerminals = Dictionary(uniqueKeysWithValues: record.hangmanTerminals.map { ($0.coord, $0.direction) })
            connectFourTerminals = Dictionary(uniqueKeysWithValues: record.connectFourTerminals.map { ($0.coord, $0.direction) })
            checkersTerminals = Dictionary(uniqueKeysWithValues: record.checkersTerminals.map { ($0.coord, $0.direction) })
            woidleTerminals = Dictionary(uniqueKeysWithValues: record.woidleTerminals.map { ($0.coord, $0.direction) })
            fires = Set(record.fires.map(\.coord))
            extinguishers = Dictionary(uniqueKeysWithValues: record.extinguishers.map { ($0.coord, $0.direction) })
            photoBooths = Dictionary(uniqueKeysWithValues: record.photoBooths.map { ($0.coord, ($0.direction, $0.expression)) })
            pictures = Dictionary(uniqueKeysWithValues: record.pictures.map { ($0.coord, ($0.direction, $0.size ?? .standard)) })
            pictureImageSelections = Dictionary(uniqueKeysWithValues: record.pictureImageSelections.map { ($0.coord, $0.selection) })
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
            floorObjectPlacements = [:]
            destinations = [:]
            exitSigns = [:]
            floorMaps = [:]
            spotlights = []
        fluorescentLights = [:]
        pictureLights = [:]
        lightBrightness = []
            missionSigns = [Self.missionCoordinate: .south]
            pictures = [:]
            pictureImageSelections = [:]
            mirrors = [:]
            wallLights = [:]
            windowRooms = [:]
            ticTacToeTerminals = [:]
            shellGameStations = [:]
            rockPaperScissorsTerminals = [:]
            higherLowerTerminals = [:]
            fiveCardDrawTerminals = [:]
            simonTerminals = [:]
            hangmanTerminals = [:]
            connectFourTerminals = [:]
            checkersTerminals = [:]
            woidleTerminals = [:]
            fires = []
            extinguishers = [:]
            photoBooths = [:]
            roomDoors = [:]
            itemRooms = [:]
            picturesUseCameraRoll = false
            missionHeading = ""
            missionBody = ""
            missionObjectKind = nil
        }
        undoStack = [] // undo history is per-floor, doesn't carry across a switch
        // Same "this is a load, not an edit" flag resetCurrentFloorToDefault()
        // sets -- switching floors bumps version too (so the 3D scene
        // and any open editor UI both know to refresh), but merely
        // looking at a floor must never mark it as having a local
        // override. Actual edits made to the floor you're LEAVING were
        // already marked individually, in real time, as each one
        // happened -- see autosaveAfterVersionChange().
        versionChangeIsFloorLoad = true
        version += 1
    }

    #if DEBUG
    /// Dev-only: reuses switchTo(id:) -- the same canonical path the
    /// floor-nav chevrons and advanceToNextMaze() already use -- so a
    /// dev floor jump gets the exact same fresh-controller/fresh-mission
    /// behavior as any other floor change, with nothing duplicated.
    /// Also remembers `id` as the last-jumped-to floor so the optional
    /// "Start on last dev floor" launch override (see init()) has
    /// something to read. Compiled out entirely in Release builds.
    func devJump(to id: Int) {
        switchTo(id: id)
        UserDefaults.standard.set(id, forKey: Self.devLastJumpedFloorKey)
    }
    #endif

    /// Wired to TapNavigationController.onReachedEnd — walking into the
    /// current floor's end cell calls this. Does nothing if this floor
    /// isn't linked to another one yet, which is also exactly why a
    /// floor authored without a next-floor link just quietly stays on
    /// the existing "You made it!" screen instead of going anywhere.
    func advanceToNextMaze() {
        // TEMPORARY DIAGNOSTIC (Eddie, Sept 16 -- elevator arrival
        // visual-transition audit). Remove alongside every other
        // [ARRIVALDIAG]-tagged line in ContentView.swift and
        // TapNavigationController.swift once diagnosed.
        navLog("[ARRIVALDIAG] advanceToNextMaze() START t=\(String(format: "%.4f", Date().timeIntervalSince1970)) currentMazeID=\(currentMazeID) nextMazeID=\(String(describing: nextMazeID))")
        guard let next = nextMazeID else { return }
        switchTo(id: next)
        navLog("[ARRIVALDIAG] advanceToNextMaze() END t=\(String(format: "%.4f", Date().timeIntervalSince1970)) currentMazeID=\(currentMazeID)")
    }

    // MARK: - Undo / Clear

    private var undoStack: [(elevatorCabDecoration: ElevatorCabDecoration, fluorescentLights: [GridCoordinate: FluorescentOrientation], pictureLights: [GridCoordinate: Direction], additionalContent: EditorAdditionalUndoState, lightBrightness: [LightBrightness], cells: Set<GridCoordinate>, objects: [GridCoordinate: ObjectKind], destinations: [GridCoordinate: ObjectKind], exitSigns: [GridCoordinate: Direction], floorMaps: [GridCoordinate: Direction], spotlights: Set<GridCoordinate>, missionSigns: [GridCoordinate: Direction], pictures: [GridCoordinate: (direction: Direction, size: PictureSize)], mirrors: [GridCoordinate: Direction], wallLights: [GridCoordinate: Direction], picturesUseCameraRoll: Bool, roomDoors: [GridCoordinate: RoomDoorPlacement], itemRooms: [GridCoordinate: Int], windowRooms: [GridCoordinate: WindowRoomPlacement], fires: Set<GridCoordinate>, pictureImageSelections: [GridCoordinate: PictureImageSelection])] = []
    private let maxUndoDepth = 30

    /// Snapshots the current maze so a later undo() can restore it.
    /// Call once before a batch of edits (a whole drag stroke, or
    /// Clear) rather than per-cell, so Undo reverts a whole gesture at
    /// once instead of one cell at a time. Captures cells AND objects
    /// together so undo works correctly no matter which mode (wall
    /// painting or object placing) the stroke was in.
    func snapshotForUndo() {
        undoStack.append((elevatorCabDecoration: elevatorCabDecoration, fluorescentLights: fluorescentLights, pictureLights: pictureLights, additionalContent: EditorAdditionalUndoState(bathroomDoors: bathroomDoors, extinguishers: extinguishers, ticTacToeTerminals: ticTacToeTerminals, shellGameStations: shellGameStations, rockPaperScissorsTerminals: rockPaperScissorsTerminals, higherLowerTerminals: higherLowerTerminals, fiveCardDrawTerminals: fiveCardDrawTerminals, simonTerminals: simonTerminals, hangmanTerminals: hangmanTerminals, connectFourTerminals: connectFourTerminals, checkersTerminals: checkersTerminals, woidleTerminals: woidleTerminals, photoBooths: photoBooths), lightBrightness: lightBrightness, cells: cells, objects: objects, destinations: destinations, exitSigns: exitSigns, floorMaps: floorMaps, spotlights: spotlights, missionSigns: missionSigns, pictures: pictures, mirrors: mirrors, wallLights: wallLights, picturesUseCameraRoll: picturesUseCameraRoll, roomDoors: roomDoors, itemRooms: itemRooms, windowRooms: windowRooms, fires: fires, pictureImageSelections: pictureImageSelections))
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst()
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        setElevatorCabDecoration(previous.elevatorCabDecoration)
        cells = previous.cells
        bathroomDoors = previous.additionalContent.bathroomDoors
        extinguishers = previous.additionalContent.extinguishers
        ticTacToeTerminals = previous.additionalContent.ticTacToeTerminals
        shellGameStations = previous.additionalContent.shellGameStations
        rockPaperScissorsTerminals = previous.additionalContent.rockPaperScissorsTerminals
        higherLowerTerminals = previous.additionalContent.higherLowerTerminals
        fiveCardDrawTerminals = previous.additionalContent.fiveCardDrawTerminals
        simonTerminals = previous.additionalContent.simonTerminals
        hangmanTerminals = previous.additionalContent.hangmanTerminals
        connectFourTerminals = previous.additionalContent.connectFourTerminals
        checkersTerminals = previous.additionalContent.checkersTerminals
        woidleTerminals = previous.additionalContent.woidleTerminals
        photoBooths = previous.additionalContent.photoBooths
        objects = previous.objects
        destinations = previous.destinations
        exitSigns = previous.exitSigns
        floorMaps = previous.floorMaps
        spotlights = previous.spotlights
        lightBrightness = previous.lightBrightness
        missionSigns = previous.missionSigns
        pictures = previous.pictures
        pictureImageSelections = previous.pictureImageSelections
        mirrors = previous.mirrors
        fluorescentLights = previous.fluorescentLights
        pictureLights = previous.pictureLights
        wallLights = previous.wallLights
        roomDoors = previous.roomDoors
        windowRooms = previous.windowRooms
        itemRooms = previous.itemRooms
        fires = previous.fires
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
        floorObjectPlacements = [:]
        destinations = [:]
        exitSigns = [:]
        floorMaps = [:]
        spotlights = []
        fluorescentLights = [:]
        pictureLights = [:]
        lightBrightness = []
        missionSigns = [Self.missionCoordinate: .south]
        pictures = [:]
        pictureImageSelections = [:]
        mirrors = [:]
        windowRooms = [:]
        ticTacToeTerminals = [:]
        shellGameStations = [:]
        rockPaperScissorsTerminals = [:]
        higherLowerTerminals = [:]
        fiveCardDrawTerminals = [:]
        simonTerminals = [:]
        hangmanTerminals = [:]
        connectFourTerminals = [:]
        checkersTerminals = [:]
        woidleTerminals = [:]
        fires = []
        extinguishers = [:]
        photoBooths = [:]
        roomDoors = [:]
        itemRooms = [:]
        version += 1
    }
}

/// Actual authored content only; geometry and elevator state are never listed.
enum EditorContentKind: String, Hashable {
    case objects
    case destinations
    case exitSigns
    case floorMaps
    case pictures
    case mirrors
    case fluorescentLights
    case pictureLights
    case wallLights
    case missionSigns
    case bathroomDoors
    case extinguishers
    case ticTacToeTerminals
    case shellGameStations
    case rockPaperScissorsTerminals
    case higherLowerTerminals
    case fiveCardDrawTerminals
    case simonTerminals
    case hangmanTerminals
    case connectFourTerminals
    case checkersTerminals
    case woidleTerminals
    case spotlights
    case fires
    case roomDoors
    case windowRooms
    case photoBooths
}

struct EditorCellContent: Identifiable {
    let id: EditorContentKind
    let title: String
}

extension MazeStore {
    func removableContent(at coord: GridCoordinate) -> [EditorCellContent] {
        var result: [EditorCellContent] = []
        func add(_ kind: EditorContentKind, _ title: String) {
            result.append(EditorCellContent(id: kind, title: title))
        }
        func wall(_ name: String, _ direction: Direction) -> String {
            "\(name) — \(direction.rawValue.capitalized) Wall"
        }
        if let kind = objects[coord] {
            let names: [ObjectKind: String] = [.heart: "Heart", .star: "Star", .iceCream: "Ice Cream", .appleWhole: "Apple", .babyCarriage: "Baby Carriage", .snowman: "Snowman", .personBiking: "Cyclist", .cakeCandles: "Cake", .trashCan: "Trash Can", .envelope: "Envelope", .key: "Key", .paintBucket: "Paint Bucket"]
            let title = kind.cashValue(onFloor: currentMazeID).map { "Cash $\($0)" } ?? names[kind] ?? kind.rawValue
            add(.objects, title)
        }
        if let kind = destinations[coord] {
            add(.destinations, "Chute / Destination (\(kind.rawValue))")
        }
        if let direction = exitSigns[coord] { add(.exitSigns, wall("Exit Sign", direction)) }
        if let direction = floorMaps[coord] { add(.floorMaps, wall("Floor Map", direction)) }
        if let entry = pictures[coord] { add(.pictures, wall("Picture", entry.direction)) }
        if let direction = mirrors[coord] { add(.mirrors, wall("Mirror", direction)) }
        if let orientation = fluorescentLights[coord] { add(.fluorescentLights, "Fluorescent (\(orientation.title))") }
        if let direction = pictureLights[coord] { add(.pictureLights, wall("Picture Light", direction)) }
        if let direction = wallLights[coord] { add(.wallLights, wall("Wall Light", direction)) }
        if let direction = missionSigns[coord] { add(.missionSigns, wall("Mission Sign", direction)) }
        if let direction = bathroomDoors[coord] { add(.bathroomDoors, wall("Bathroom Door", direction)) }
        if let direction = extinguishers[coord] { add(.extinguishers, wall("Extinguisher", direction)) }
        if let direction = ticTacToeTerminals[coord] { add(.ticTacToeTerminals, wall("Tic Tac Toe", direction)) }
        if let direction = shellGameStations[coord] { add(.shellGameStations, wall("Shell Game", direction)) }
        if let direction = rockPaperScissorsTerminals[coord] { add(.rockPaperScissorsTerminals, wall("Rock Paper Scissors", direction)) }
        if let direction = higherLowerTerminals[coord] { add(.higherLowerTerminals, wall("Higher / Lower", direction)) }
        if let direction = fiveCardDrawTerminals[coord] { add(.fiveCardDrawTerminals, wall("Five Card Draw", direction)) }
        if let direction = simonTerminals[coord] { add(.simonTerminals, wall("Simon", direction)) }
        if let direction = hangmanTerminals[coord] { add(.hangmanTerminals, wall("Hangman", direction)) }
        if let direction = connectFourTerminals[coord] { add(.connectFourTerminals, wall("Connect Four", direction)) }
        if let direction = checkersTerminals[coord] { add(.checkersTerminals, wall("Checkers", direction)) }
        if let direction = woidleTerminals[coord] { add(.woidleTerminals, wall("Woidle", direction)) }
        if spotlights.contains(coord) { add(.spotlights, "Ceiling Light") }
        if fires.contains(coord) { add(.fires, "Fire") }
        if let door = roomDoors[coord] { add(.roomDoors, wall("Room Door \(door.roomNumber)", door.direction)) }
        if let room = windowRooms[coord] { add(.windowRooms, wall("Window Room", room.direction)) }
        if let booth = photoBooths[coord] { add(.photoBooths, wall("Photo Booth", booth.direction)) }
        return result
    }
}

private struct EditorAdditionalUndoState {
    let bathroomDoors: [GridCoordinate: Direction]
    let extinguishers: [GridCoordinate: Direction]
    let ticTacToeTerminals: [GridCoordinate: Direction]
    let shellGameStations: [GridCoordinate: Direction]
    let rockPaperScissorsTerminals: [GridCoordinate: Direction]
    let higherLowerTerminals: [GridCoordinate: Direction]
    let fiveCardDrawTerminals: [GridCoordinate: Direction]
    let simonTerminals: [GridCoordinate: Direction]
    let hangmanTerminals: [GridCoordinate: Direction]
    let connectFourTerminals: [GridCoordinate: Direction]
    let checkersTerminals: [GridCoordinate: Direction]
    let woidleTerminals: [GridCoordinate: Direction]
    let photoBooths: [GridCoordinate: (direction: Direction, expression: PhotoBoothExpression)]
}

extension MazeStore {
    /// Confirmation is one authored edit, even when several fixtures are removed.
    func deleteContent(_ selected: Set<EditorContentKind>, at coord: GridCoordinate) {
        let present = Set(removableContent(at: coord).map(\.id))
        let removal = selected.intersection(present)
        guard !removal.isEmpty else { return }
        snapshotForUndo()
        for kind in removal {
            switch kind {
            case .objects: removeObject(at: coord)
            case .destinations: removeDestination(at: coord)
            case .exitSigns: removeExitSign(at: coord)
            case .floorMaps: removeFloorMap(at: coord)
            case .pictures: removePicture(at: coord)
            case .mirrors: removeMirror(at: coord)
            case .fluorescentLights: removeFluorescent(at: coord)
            case .pictureLights: removePictureLight(at: coord)
            case .wallLights: removeWallLight(at: coord)
            case .spotlights: removeSpotlight(at: coord)
            case .fires: removeFire(at: coord)
            case .roomDoors: removeRoomDoor(at: coord)
            case .windowRooms: removeWindowRoom(at: coord)
            case .missionSigns: missionSigns.removeValue(forKey: coord)
            case .bathroomDoors: bathroomDoors.removeValue(forKey: coord)
            case .extinguishers: extinguishers.removeValue(forKey: coord)
            case .ticTacToeTerminals: ticTacToeTerminals.removeValue(forKey: coord)
            case .shellGameStations: shellGameStations.removeValue(forKey: coord)
            case .rockPaperScissorsTerminals: rockPaperScissorsTerminals.removeValue(forKey: coord)
            case .higherLowerTerminals: higherLowerTerminals.removeValue(forKey: coord)
            case .fiveCardDrawTerminals: fiveCardDrawTerminals.removeValue(forKey: coord)
            case .simonTerminals: simonTerminals.removeValue(forKey: coord)
            case .hangmanTerminals: hangmanTerminals.removeValue(forKey: coord)
            case .connectFourTerminals: connectFourTerminals.removeValue(forKey: coord)
            case .checkersTerminals: checkersTerminals.removeValue(forKey: coord)
            case .woidleTerminals: woidleTerminals.removeValue(forKey: coord)
            case .photoBooths: photoBooths.removeValue(forKey: coord)
            }
        }
        version += 1
    }
}

extension MazeStore {
    func canPlacePictureLight(_ direction: Direction, at coord: GridCoordinate) -> Bool {
        let neighbor = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
        guard cells.contains(coord) && !cells.contains(neighbor) else { return false }
        // Sept 22 (one authored wall-display fixture, Pictures + Mission
        // Statements + Maps): the SAME Picture Light -- one AuthoredLight
        // kind, one `pictureLights` dict, one 1-5 brightness range, one
        // `pictureLights` persistence key -- is independently authored on
        // any of the three wall displays. No new light kinds, no separate
        // mission/map brightness ranges; a photo, a mission statement, or
        // a floor map all hang the exact same existing fixture, sized to
        // their own panel. (Mirrors and every other display stay out of
        // scope, per Eddie's Sept 22 scoping.)
        let hasDisplay =
            pictures[coord]?.direction == direction ||
            missionSigns[coord] == direction ||
            floorMaps[coord] == direction
        return hasDisplay
    }

    func placePictureLight(_ direction: Direction, at coord: GridCoordinate, brightness: Int = 3) {
        guard canPlacePictureLight(direction, at: coord) else { return }
        pictureLights[coord] = direction
        setLightBrightness(brightness, kind: .picture, at: coord)
        version += 1
    }

    func removePictureLight(at coord: GridCoordinate) {
        guard pictureLights.removeValue(forKey: coord) != nil else { return }
        lightBrightness.removeAll { $0.coord == coord && $0.kind == .picture }
        version += 1
    }
}


extension MazeStore {
    func placeFluorescent(_ orientation: FluorescentOrientation, at coord: GridCoordinate, brightness: Int = 3) {
        guard cells.contains(coord) else { return }
        fluorescentLights[coord] = orientation
        setLightBrightness(brightness, kind: .fluorescent, at: coord)
        version += 1
    }

    func removeFluorescent(at coord: GridCoordinate) {
        guard fluorescentLights.removeValue(forKey: coord) != nil else { return }
        lightBrightness.removeAll { $0.coord == coord && $0.kind == .fluorescent }
        version += 1
    }
}
