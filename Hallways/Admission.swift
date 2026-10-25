import Foundation

/// Oct 5 -- ADMISSION (first shell). The player's very first visit to the
/// building is an admission: the lobby ceremony, then an elevator trip the
/// building itself sends to Administration (Floor 2). This is the one
/// persisted fact that tells admission apart from ordinary play. It is
/// deliberately separate from hasCompletedInitialEntrance, which only means
/// "has started a front-door lobby walk" and is set at every entrance.
///
/// Admission completes when the player takes their employee ID card from
/// the Administration kiosk (AdministrationIDTerminal.takeCard; the card's
/// number and Hallways portrait are kept by EmployeeID). The dev toggle in
/// the grid editor still flips it for testing.
enum Admission {
    static let completedKey = "admission.completed"
    /// The floor admission sends a new player to.
    static let administrationFloor = 2

    static var isCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: completedKey)
            diag("admission.completedChanged", ["completed": newValue])
        }
    }

    static var isPending: Bool { !isCompleted }

    /// Oct 5 -- THE PROLOGUE MILESTONE. Taking the ID card only means
    /// "admitted"; the prologue goes on (Juanita redirects you, Fred's
    /// office, Fred packs up and joins, you leave Administration). This is
    /// the one persisted fact that ends it and lets the building come alive.
    /// Nothing sets it yet -- the Fred-joins beat will. Dev toggle in the
    /// grid editor; cleared by the dev New Player resets.
    nonisolated static let prologueCompletedKey = "prologue.completed"

    /// Oct 5 -- the FIRST of the three independent milestones: the player
    /// has made the ceremonial entrance and first reached Administration.
    /// (Same key ContentView's @AppStorage uses.) Set when Floor 2 is first
    /// built for the player; never set by admission or the prologue.
    nonisolated static let initialEntranceKey = "hasCompletedInitialEntrance"

    /// Launch rule: entrance made but prologue unfinished -> the player
    /// belongs in Administration, so a relaunch resumes there (no exterior,
    /// no lobby ceremony, no elevator). Every other state launches as before.
    nonisolated static var resumesInAdministration: Bool {
        UserDefaults.standard.bool(forKey: initialEntranceKey)
            && !UserDefaults.standard.bool(forKey: prologueCompletedKey)
    }

    static var isPrologueCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: prologueCompletedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: prologueCompletedKey)
            // Oct 12 (escort resume): completed -> no escort is owed any more;
            // un-completed (Start Over, the dev toggle) -> start from scratch.
            ResumeState.clearEscort(reason: newValue ? "prologueCompleted" : "prologueReset")
            if !newValue { UserDefaults.standard.removeObject(forKey: ResumeState.orientationArrivedKey) }
            diag("prologue.completedChanged", ["completed": newValue])
        }
    }

    /// Oct 5 (clean onboarding): the stretch that must be free of critters,
    /// companions and critter audio -- the lobby (Floor 1, behind the opening
    /// screen too) and Administration (Floor 2) until the PROLOGUE is
    /// complete (not merely admission: Administration stays controlled after
    /// the ID is taken). No Noodle, no LivingWorld population, no Posse
    /// members there. Every other floor, and these two afterwards, are
    /// ordinary.
    static func isQuietOnboarding(floor: Int) -> Bool {
        // Oct 6: + the player's office floor -- its first visit (Candy's
        // delivery and goodbye) is quiet; it joins ordinary building life
        // once he has gone.
        !isPrologueCompleted && (floor == 1 || floor == administrationFloor || floor == PlayerOffice.floor)
    }

    /// Oct 5 (design decision): Administration is never a random-critter
    /// floor -- Juanita and Fred work there; no LivingWorld population
    /// (Menagerie/Bobbins) and no first meetings, before or after the
    /// prologue. Everywhere else this is just the quiet-onboarding rule.
    static func isCritterFree(floor: Int) -> Bool {
        floor == administrationFloor || isQuietOnboarding(floor: floor)
    }
}
