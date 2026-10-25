import Foundation

/// Oct 11 -- RESUME: Hallways reopens where the player left off.
///
/// Three small persisted facts (UserDefaults, survive app updates; cleared
/// only by Start Over):
///   resume.point.v1     the player's floor, exact free-walk position (x, z)
///                       and yaw -- written on every cell entered, on floor
///                       arrival and when the app goes to the background
///                       (TapNavigationController.saveResumePoint).
///   resume.consumed.v1  cash / pickups collected and fires put out, per
///                       floor -- left out of every later build of that
///                       floor, so nothing is ever resurrected.
///   (money: MazeStore.moneyTotal, key resume.money.v1; Freddy: Posse.records,
///   key resume.posse.v1 -- each saved where it lives.)
///
/// Launch rule (MazeStore init + ContentView): once the player has made the
/// entrance, a saved point is resumed on its floor -- no street screen, no
/// lobby ceremony, no elevator. The one exception keeps the existing
/// onboarding fallback: with the prologue unfinished, only an Administration
/// point is resumed; anywhere else (e.g. mid Tinky trip) starts the unfinished
/// sequence again from Administration, exactly as before.
///
/// `isRecording` is switched on by the app at launch (ContentView). Off by
/// default, so unit tests that build controllers, collect objects or change
/// Posse records never write into the device's real save data.
enum ResumeState {
    nonisolated static let pointKey = "resume.point.v1"
    nonisolated static let consumedKey = "resume.consumed.v1"
    nonisolated static let moneyKey = "resume.money.v1"
    nonisolated static let posseKey = "resume.posse.v1"
    /// Oct 12 (escort resume): the orientation escort under way on its
    /// destination floor -- see "the orientation escort, persisted" below.
    nonisolated static let escortKey = "resume.escort.v1"
    /// Oct 12 (stability pass, superseded the same day by escortKey): kept
    /// only so Start Over clears it from devices that ran that build.
    nonisolated static let orientationArrivedKey = "resume.orientationArrived.v1"
    /// Every key Start Over clears.
    nonisolated static let allKeys = [pointKey, consumedKey, moneyKey, posseKey, escortKey, orientationArrivedKey,
                                          ToolBelt.carriedKey,   // Oct 16: the tools carried from Supplies
                                          FloorFiveBlackout.restoredKey,   // Oct 16 (VIII): Floor 5's lights (Start Over: dark again)
                                          FloorFiveBlackout.circuitsKey,   // Oct 17: Floor 5's eight circuits (Start Over: all off)
                                          Butterfly.lifeKey,               // Oct 17: the butterfly's whereabouts and memory
                                          BuildingLife.storageKey,         // Oct 18: every resident's record (the butterfly's now too)
                                          TaskRegistry.storageKey]         // Oct 20: the twenty tasks (Start Over: a fresh set)

    static var isRecording = false

    /// True inside a unit-test run (the host app launches too): resume stays
    /// off there, so tests never read or write the real save data.
    static var runningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    struct Point: Codable, Equatable {
        var floor: Int
        var x: Float
        var z: Float
        var yaw: Float
    }

    // MARK: The point

    static var point: Point? {
        guard let data = UserDefaults.standard.data(forKey: pointKey) else { return nil }
        return try? JSONDecoder().decode(Point.self, from: data)
    }

    static func save(_ p: Point, reason: String) {
        guard isRecording, p.x.isFinite, p.z.isFinite, p.yaw.isFinite else { return }
        guard p != lastSaved, let data = try? JSONEncoder().encode(p) else { return }
        UserDefaults.standard.set(data, forKey: pointKey)
        if reason != "cell" { diag("resume.saved", ["reason": reason, "floor": p.floor]) }
        lastSaved = p
    }
    private static var lastSaved: Point?

    /// Oct 16 (Bonzo's eviction): the player is OUTSIDE the building now -- no
    /// point to resume at, so the next launch opens on the street. Progress
    /// (consumed items, money, the story's own flags) is untouched.
    static func clearPoint(reason: String) {
        guard isRecording else { return }
        UserDefaults.standard.removeObject(forKey: pointKey)
        lastSaved = nil
        diag("resume.pointCleared", ["reason": reason])
    }

    /// The floor a launch should open on, or nil for the ordinary launch.
    static func launchFloor(available: Set<Int>) -> Int? {
        let d = UserDefaults.standard
        guard isRecording, d.bool(forKey: Admission.initialEntranceKey), let p = point, available.contains(p.floor) else { return nil }
        // Prologue unfinished: Administration -- or the floor an escort is under way on.
        if !d.bool(forKey: Admission.prologueCompletedKey), p.floor != Admission.administrationFloor,
           escortPending(onFloor: p.floor) == nil { return nil }
        return p.floor
    }

    /// Will this launch resume at the saved point? (ContentView: no street screen.)
    static var resumesAtSavedPoint: Bool {
        let d = UserDefaults.standard
        guard isRecording, d.bool(forKey: Admission.initialEntranceKey), let p = point else { return false }
        return d.bool(forKey: Admission.prologueCompletedKey) || p.floor == Admission.administrationFloor
            || escortPending(onFloor: p.floor) != nil
    }

    /// Set by MazeStore at launch; taken (once) by the first build of that floor.
    static var pendingPlacement: Point?
    static func takePlacement(forFloor floor: Int) -> Point? {
        guard let p = pendingPlacement, p.floor == floor else { return nil }
        pendingPlacement = nil
        return p
    }

    // MARK: Oct 12 (escort resume) -- the orientation escort, persisted
    //
    // Phases (stage): "leading" -- from "follow me" in Administration out to
    // the elevator, into the cab and up (the ride itself is never a place to
    // resume: the last point saved is outside the doors, on whichever floor
    // was last built); "guiding" -- out of the cab on the destination floor
    // to the office; "goodbye" -- in the office.
    //
    // Arriving on Floor 3 with the guide is NOT the end of onboarding: the
    // escort to the office and the goodbye are still to come, and the floor
    // stays quiet (no ordinary critters) until he has said goodbye (prologue
    // complete). The escort's phase is saved here (resume.escort.v1) when it
    // starts on the destination floor and when the goodbye begins; it is
    // cleared when the prologue completes or the journey ends. A relaunch with
    // an escort saved resumes at the saved Floor 3 point (not Administration),
    // and GuidedJourney.resumeEscortIfSaved puts the guide back with the
    // player -- leading on, or the goodbye in the office.

    struct Escort: Codable, Equatable {
        var fromFloor: Int
        var toFloor: Int
        var stage: String           // "leading" | "guiding" | "goodbye"
    }

    static var savedEscort: Escort? {
        guard let data = UserDefaults.standard.data(forKey: escortKey) else { return nil }
        return try? JSONDecoder().decode(Escort.self, from: data)
    }

    /// GuidedJourney: the escort is under way on its destination floor (or its goodbye began).
    static func saveEscort(_ e: Escort) {
        guard isRecording, e != savedEscort, let data = try? JSONEncoder().encode(e) else { return }
        UserDefaults.standard.set(data, forKey: escortKey)
        diag("resume.escortSaved", ["from": e.fromFloor, "to": e.toFloor, "stage": e.stage])
    }

    /// The escort is over (the prologue completed, the journey ended, or Start Over).
    nonisolated static func clearEscort(reason: String) {
        guard UserDefaults.standard.object(forKey: escortKey) != nil else { return }
        UserDefaults.standard.removeObject(forKey: escortKey)
        diag("resume.escortCleared", ["reason": reason])
    }

    /// An escort still owed to the player on `floor` (prologue unfinished):
    /// its destination floor -- or, while it is still in its first phase
    /// ("leading": out of Administration to the elevator, boarding, riding),
    /// the floor it set out from.
    static func escortPending(onFloor floor: Int) -> Escort? {
        guard !UserDefaults.standard.bool(forKey: Admission.prologueCompletedKey), let e = savedEscort else { return nil }
        if e.toFloor == floor { return e }
        if e.stage == "leading", e.fromFloor == floor { return e }
        return nil
    }

    /// App launch: what was saved, and what the launch rule will do with it.
    static func logLaunchState() {
        let d = UserDefaults.standard
        let p = point
        var overrides: [String] = []
        #if DEBUG
        if d.bool(forKey: MazeStore.devStartOnLastFloorKey) { overrides.append("devStartOnLastFloor=\(d.integer(forKey: MazeStore.devLastJumpedFloorKey))") }
        #endif
        if d.bool(forKey: "HallwaysReplayBoxReveal") { overrides.append("replayBoxReveal") }
        diag("resume.launchState", [
            "recording": isRecording,
            "savedFloor": p.map { "\($0.floor)" } ?? "none",
            "savedX": p.map { String(format: "%.2f", $0.x) } ?? "-",
            "savedZ": p.map { String(format: "%.2f", $0.z) } ?? "-",
            "entrance": d.bool(forKey: Admission.initialEntranceKey),
            "admission": d.bool(forKey: Admission.completedKey),
            "prologue": d.bool(forKey: Admission.prologueCompletedKey),
            "escort": savedEscort.map { "\($0.stage)@\($0.toFloor)" } ?? "none",
            "resumesAtSavedPoint": resumesAtSavedPoint,
            "overrides": overrides.isEmpty ? "none" : overrides.joined(separator: ","),
        ])
    }

    // MARK: What has been used up

    enum Consumed: String { case object, fire }

    private static func key(_ kind: Consumed, _ floor: Int, _ c: GridCoordinate) -> String {
        "\(kind.rawValue):\(floor):\(c.row):\(c.col)"
    }
    private static var consumedCache: Set<String>?
    private static var consumed: Set<String> {
        if let cached = consumedCache { return cached }
        let loaded = Set(UserDefaults.standard.stringArray(forKey: consumedKey) ?? [])
        consumedCache = loaded
        return loaded
    }

    static func markConsumed(_ kind: Consumed, floor: Int, coords: Set<GridCoordinate>) {
        guard isRecording, !coords.isEmpty else { return }
        var set = consumed
        for c in coords { set.insert(key(kind, floor, c)) }
        consumedCache = set
        UserDefaults.standard.set(Array(set).sorted(), forKey: consumedKey)
        diag("resume.consumed", ["kind": kind.rawValue, "floor": floor, "count": coords.count])
    }

    static func unconsumed(objects: [GridCoordinate: ObjectKind], floor: Int) -> [GridCoordinate: ObjectKind] {
        guard isRecording else { return objects }
        let set = consumed
        return objects.filter { !set.contains(key(.object, floor, $0.key)) }
    }

    static func unconsumed(fires: Set<GridCoordinate>, floor: Int) -> Set<GridCoordinate> {
        guard isRecording else { return fires }
        let set = consumed
        return fires.filter { !set.contains(key(.fire, floor, $0)) }
    }

    // MARK: Start Over

    static func resetForNewPlayer() {
        clearEscort(reason: "startOver")
        for k in allKeys { UserDefaults.standard.removeObject(forKey: k) }
        ToolBelt.resetForNewPlayer()                        // Oct 16: every tool back in its case
        Butterfly.resetForNewPlayer()                       // Oct 17: the butterfly back in the break room, nothing remembered
        BuildingLife.shared.resetForNewPlayer()             // Oct 18: every resident starts afresh (butterfly, chair)
        TaskGuide.clear()                                   // Oct 20: nobody guiding...
        TaskRegistry.shared.reset()                         // ...and a fresh set of tasks with the next floor built
        consumedCache = nil
        lastSaved = nil
        pendingPlacement = nil
        diag("resume.reset", [:])
    }
}
