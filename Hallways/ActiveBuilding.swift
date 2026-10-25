//
//  ActiveBuilding.swift
//  Hallways
//
//  Oct 23 -- THE TEN-FLOOR EXPERIMENT (reversible).
//  Oct 25 -- SEVEN FLOORS (PP 2, the musical redesign): the building in use is
//  1 Lobby, 2 Administration, 3 Office / Conference, 4 Recording A, 5 Recording B,
//  6 Musical Maze, 7 Record Gallery. (4-7 keep their old layouts until they are
//  rebuilt.) Everything below is the same mechanism with the top floor at 7.
//
//  Does the same population, concentrated into fewer floors, make the building
//  feel livelier? While this runs the building is floors 1-7. Floors 8-16 are
//  NOT deleted or changed in any way -- their layouts and decorations stay in
//  the floor library (and DefaultMazes.json) exactly as they are; they are only
//  out of use:
//
//    - the elevator offers 1-7 only (the cab's panel, the hall buttons, the
//      dispatcher's reachable floors), and a floor's "next floor" link that
//      points above 7 leads to the lobby instead;
//    - Building Life (Activity, Directory, Map) lists 1-7;
//    - residents never go above 7: a liking for floor 8-16 counts, meanwhile,
//      for a stand-in floor below (standIns) -- the same residents, the same
//      weights, only folded down; one whose record was above 10 is set down at
//      its stand-in floor's elevator landing, and goes on from there;
//    - tasks above 7 aren't offered (their floor has no plan meanwhile);
//    - a launch never resumes above 7 (the ordinary launch instead, with the
//      street intro -- ResumeState.resumesAtSavedPoint; the ID, the prologue and
//      everything else saved are kept).
//
//  RESTORE ALL SIXTEEN: set `experimentTopFloor` below to 16 and rebuild. (To
//  compare without editing code: the scheme's launch argument
//  `-HallwaysActiveFloors 16` -- it applies while it's in the scheme.) Nothing
//  has to be undone: the floors were never touched, and the residents simply
//  start liking 8-16 again on their next decisions. (The unit tests always see
//  the whole building, unless a test sets `testTopFloor`.)
//

import Foundation

nonisolated enum ActiveBuilding {
    /// The top floor in use. 16: the whole building. (Oct 23: 10; Oct 25: 7.)
    static let experimentTopFloor = 7

    /// A launch argument overrides it while it's in the scheme: `-HallwaysActiveFloors 16`.
    static let defaultsKey = "HallwaysActiveFloors"

    /// The highest floor in use right now.
    static var topFloor: Int {
        if let t = testTopFloor { return t }                // (a test describing the building in use)
        if underTests { return Int.max }                    // (the unit tests describe the whole building)
        let v = UserDefaults.standard.integer(forKey: defaultsKey)
        return v > 0 ? v : experimentTopFloor
    }

    /// Tests only: the top floor as a test wants it (nil: the whole building, as always under tests).
    nonisolated(unsafe) static var testTopFloor: Int?

    private static let underTests = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func isActive(_ floor: Int) -> Bool { floor >= 1 && floor <= topFloor }

    /// While a floor is out of use, its residents (and any liking for it) are on
    /// this floor instead -- spread so no one floor takes them all. Oct 25 (seven
    /// floors): every floor out of use has its own stand-in among the floors
    /// residents live on (4-7; 1-3 are the lobby, Administration and the office
    /// floor), weighted by size -- 6 (110 cells) takes three, 7 (74) three, 5 (59)
    /// two, 4 (11 cells) one; before, 8-10 had none and fell back to 5. (Oct 23:
    /// [11: 5, 12: 6, 13: 7, 14: 8, 15: 4, 16: 6].)
    static let standIns: [Int: Int] = [8: 6, 9: 7, 10: 5, 11: 5, 12: 6, 13: 7, 14: 7, 15: 4, 16: 6]

    static func standIn(for floor: Int) -> Int {
        guard !isActive(floor) else { return floor }
        if let f = standIns[floor], isActive(f) { return f }
        return min(topFloor, 5)
    }

    /// A resident's floor weights with every floor out of use folded onto its stand-in.
    static func fold(_ floors: [Int: Double]) -> [Int: Double] {
        guard floors.keys.contains(where: { !isActive($0) }) else { return floors }
        var out: [Int: Double] = [:]
        for (f, w) in floors { out[standIn(for: f), default: 0] += w }
        return out
    }
}
