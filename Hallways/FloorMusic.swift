//
//  FloorMusic.swift
//  Hallways
//
//  Oct 25 -- WHICH PIECE EACH FLOOR'S WALKING BAND PLAYS.
//
//  Only the walking band (WalkingBand.swift: residents following the player, playing on their Music Lab
//  instruments) uses this. With nobody musical following, every floor keeps the living orchestra
//  (LivingOrchestra.swift), exactly as before. The Music Lab's own composition choice is separate and
//  never changes this table.
//
//  Neighbouring floors have different characters; a piece used twice is used far apart. Change a floor's
//  piece by changing its line (ids are the Music Lab compositions': MusicLabCatalog.all). A floor not
//  listed falls back to the Lab's last-chosen piece.
//

nonisolated enum FloorMusic {
    /// Oct 25 (PP 2, seven floors): a temporary, valid map for the building in use (1-7). Not the studios'
    /// soundtrack -- that is still to be designed. Rock Shuffle has no floor of its own meanwhile. Floors
    /// 8-16 (out of use: ActiveBuilding) keep their earlier lines, unused until those floors return.
    static let assignments: [Int: String] = [
        1: "night-porter",        // Lobby: soul-jazz blues
        2: "velvet-hour",         // Administration: bossa nova, warm and easy
        3: "minuet",              // Office / Conference: minuet and trio
        4: "clockwork",           // Recording A: funk
        5: "midnight-express",    // Recording B: swing
        6: "after-hours",         // Musical Maze: the dreamy, mysterious waltz
        7: "bossa-nova",          // Record Gallery: Rua das Lâmpadas
        // out of use (8-16), as before:
        8: "bossa-nova",
        9: "night-porter",
        10: "minuet",
        11: "clockwork",
        12: "velvet-hour",
        13: "after-hours",
        14: "rock-shuffle",
        15: "midnight-express",
        16: "bossa-nova",
    ]

    static func composition(for floor: Int) -> String? { assignments[floor] }
}
