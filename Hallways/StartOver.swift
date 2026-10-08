import Foundation

/// Oct 8 -- START OVER: the one shared story reset.
///
/// Begins again as a new employee: the next arrival is a first arrival.
/// Used by Settings > Start Over (Debug AND Release) and by the Debug
/// workshop's Start Over / New Employee at Administration controls -- there
/// is no second definition of "new player".
///
/// CLEARS (story / onboarding only):
///   admission.completed            Admission.isCompleted
///   prologue.completed             Admission.isPrologueCompleted
///   hasCompletedInitialEntrance    first front-door entrance
///   hasSeenNavGestureHint          first-arrival gesture hint
///   admission.employeeNumber       + Application Support portrait (EmployeeID.reset)
///   PlayerHistory.json             the fact ledger
///   mail.delivered / mail.read     office-computer mail
///   hallchat.delivered / hallchat.read   phone chat
///   tinCanRat.enabled              companion back to its fresh default
///   in memory: accepted ID photo, Posse records (Freddy met/following),
///   guided journey in flight, office computer session + games in
///   progress, phone screen/notifications, Juanita's pending patience.
///   (ContentView.clearStoryState also zeroes the in-memory money total.)
///
/// KEEPS (never touched here): player.feet, player.heightInches,
/// hallwaysAudio.muted, Documents/mazes.json + maze.savedFloorOverrideIDs
/// (floor layouts, overrides, decorations), Hallways.elevatorCabDecoration.v1,
/// playerOffice.deskPhotoIdentifier, diagnostic logs, dev.* workshop keys,
/// lighting-determinism debug keys.
///
/// Callers then return to Floor 1, rebuild the scene (so the onboarding
/// gates re-evaluate) and raise the exterior opening screen.
enum StartOver {
    /// The persisted story keys this operation clears (UserDefaults).
    static let clearedDefaultsKeys: [String] = [
        Admission.completedKey,
        Admission.prologueCompletedKey,
        Admission.initialEntranceKey,
        hasSeenNavGestureHintKey,
        EmployeeID.numberKey,
        "mail.delivered", "mail.read",
        "hallchat.delivered", "hallchat.read",
        TinCanRat.enabledKey,
    ]
    static let hasSeenNavGestureHintKey = "hasSeenNavGestureHint"

    static func clearStoryProgress(source: String) {
        let defaults = UserDefaults.standard
        let hadEmployeeID = EmployeeID.number != nil
        diag("story.startOver.begin", [
            "source": source,
            "admission": Admission.isCompleted,
            "prologue": Admission.isPrologueCompleted,
            "entrance": defaults.bool(forKey: Admission.initialEntranceKey),
            "hadEmployeeID": hadEmployeeID,
        ])
        Admission.isCompleted = false
        Admission.isPrologueCompleted = false
        defaults.set(false, forKey: Admission.initialEntranceKey)
        defaults.set(false, forKey: hasSeenNavGestureHintKey)
        EmployeeID.reset()                                  // number + saved Hallways portrait
        AdministrationIDTerminal.acceptedPhoto = nil
        Posse.records = [:]
        GuidedJourney.end()
        OfficeComputer.shared.forceClose(reason: "startOver")
        OfficeComputer.shared.discardAllGames()
        PlayerHistory.shared.resetForNewPlayer()
        MailStore.shared.resetForNewPlayer()
        HallPhone.shared.resetForNewPlayer()                // also ChatStore + PhoneApps
        AdministrationReception.resetForNewPlayer()
        defaults.removeObject(forKey: TinCanRat.enabledKey)
        diag("story.startOver.done", ["source": source])
    }
}

extension StartOver {
    static let confirmationTitle = "Start Over?"
    static let confirmationMessage = "Begin again as a new employee? Your settings and building decorations will be kept."
    static let confirmButtonTitle = "Start Over"
}
