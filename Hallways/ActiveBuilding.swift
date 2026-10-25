//
//  ActiveBuilding.swift
//  Hallways
//
//  Oct 23 -- THE TEN-FLOOR EXPERIMENT (reversible).
//
//  Does the same population, concentrated into fewer floors, make the building
//  feel livelier? While this runs the building is floors 1-10. Floors 11-16 are
//  NOT deleted or changed in any way -- their layouts and decorations stay in
//  the floor library (and DefaultMazes.json) exactly as they are; they are only
//  out of use:
//
//    - the elevator offers 1-10 only (the cab's panel, the hall buttons, the
//      dispatcher's reachable floors), and a floor's "next floor" link that
//      points above 10 leads to the lobby instead;
//    - Building Life (Activity, Directory, Map) lists 1-10;
//    - residents never go above 10: a liking for floor 11-16 counts, meanwhile,
//      for a stand-in floor below (standIns) -- the same residents, the same
//      weights, only folded down; one whose record was above 10 is set down at
//      its stand-in floor's elevator landing, and goes on from there;
//    - tasks above 10 aren't offered (their floor has no plan meanwhile);
//    - a launch never resumes above 10 (the ordinary launch instead).
//
//  RESTORE ALL SIXTEEN: set `experimentTopFloor` below to 16 and rebuild. (To
//  compare without editing code: the scheme's launch argument
//  `-HallwaysActiveFloors 16` -- it applies while it's in the scheme.) Nothing
//  has to be undone: the floors were never touched, and the residents simply
//  start liking 11-16 again on their next decisions. (The unit tests always see
//  the whole building.)
//

import Foundation

nonisolated enum ActiveBuilding {
    /// The experiment's top floor. 16: the whole building.
    static let experimentTopFloor = 10

    /// A launch argument overrides it while it's in the scheme: `-HallwaysActiveFloors 16`.
    static let defaultsKey = "HallwaysActiveFloors"

    /// The highest floor in use right now.
    static var topFloor: Int {
        if underTests { return Int.max }                    // (the unit tests describe the whole building)
        let v = UserDefaults.standard.integer(forKey: defaultsKey)
        return v > 0 ? v : experimentTopFloor
    }

    private static let underTests = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func isActive(_ floor: Int) -> Bool { floor >= 1 && floor <= topFloor }

    /// While a floor is out of use, its residents (and any liking for it) are on
    /// this floor instead -- the residents' own floors, spread so no one floor
    /// takes them all. (Floors 9 and 10 aren't stand-ins: no resident lives there
    /// today, and whether they have rooms for them is the map's to say.)
    static let standIns: [Int: Int] = [11: 5, 12: 6, 13: 7, 14: 8, 15: 4, 16: 6]

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
