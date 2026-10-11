import Testing
@testable import Hallways

/// Oct 8 -- Start Over. NON-DESTRUCTIVE by design: these tests never call
/// StartOver.clearStoryProgress (it works on the app's real UserDefaults
/// and files, and would wipe the live story state on the test device).
/// They pin WHICH keys the shared reset clears and which it must never touch.
@MainActor
struct StartOverTests {
    @Test func clearsEveryStoryKey() {
        let cleared = Set(StartOver.clearedDefaultsKeys)
        for key in ["admission.completed", "prologue.completed", "hasCompletedInitialEntrance",
                    "hasSeenNavGestureHint", "admission.employeeNumber",
                    "mail.delivered", "mail.read", "hallchat.delivered", "hallchat.read",
                    "story.beats"] {
            #expect(cleared.contains(key), "Start Over must clear \(key)")
        }
    }

    @Test func neverTouchesPreferencesLayoutsOrDecorations() {
        let cleared = Set(StartOver.clearedDefaultsKeys)
        for key in [PlayerFeet.preferenceKey, PlayerHeight.preferenceKey, HallwaysAudio.mutedKey,
                    "maze.savedFloorOverrideIDs", ElevatorCabDecoration.storageKey,
                    PlayerOffice.deskPhotoKey, "dev.lastJumpedFloorID", "dev.startOnLastFloor"] {
            #expect(!cleared.contains(key), "Start Over must keep \(key)")
        }
    }

    @Test func confirmationWording() {
        #expect(StartOver.confirmationMessage == "Begin again as a new employee? Your settings and building decorations will be kept.")
    }
}
