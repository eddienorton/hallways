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
    static let assignments: [Int: String] = [
        1: "night-porter",        // the lobby: soul-jazz blues
        2: "velvet-hour",         // bossa nova, warm and easy
        3: "minuet",              // minuet and trio
        4: "clockwork",           // funk, mechanical
        5: "after-hours",         // lights out: the dreamy, mysterious waltz
        6: "rock-shuffle",        // boogie shuffle
        7: "midnight-express",    // swing
        8: "bossa-nova",          // Rua das Lâmpadas
        9: "night-porter",        // (again, eight floors from the lobby)
        10: "minuet",             // (again, seven floors from the 3rd)
        11: "clockwork",
        12: "velvet-hour",
        13: "after-hours",
        14: "rock-shuffle",
        15: "midnight-express",
        16: "bossa-nova",
    ]

    static func composition(for floor: Int) -> String? { assignments[floor] }
}
