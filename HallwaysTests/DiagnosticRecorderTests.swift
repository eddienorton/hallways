import Foundation
import Testing
@testable import Hallways

/// Oct 2: the persistent flight recorder (DiagnosticRecorder) -- local file,
/// survives relaunch, bounded, shareable, and never able to hurt gameplay.
struct DiagnosticRecorderTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticRecorderTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func contents(_ recorder: DiagnosticRecorder) -> String {
        recorder.flush()
        let previous = (try? String(contentsOf: recorder.previousURL, encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: recorder.currentURL, encoding: .utf8)) ?? ""
        return previous + current
    }

    @Test func eventsArePersistedToDisk() {
        let dir = tempDirectory()
        let recorder = DiagnosticRecorder(directory: dir, sessionID: "AAAA")
        recorder.floor = 2
        recorder.record("elevator.accepted", ["next": 3, "controlled": false])
        let text = contents(recorder)
        #expect(text.contains("S=AAAA"))
        #expect(text.contains("F2 elevator.accepted next=3 controlled=false"))
    }

    @Test func aNewSessionKeepsThePreviousSessionsEvents() {
        let dir = tempDirectory()
        let first = DiagnosticRecorder(directory: dir, sessionID: "FIRST")
        first.startSession()
        first.record("curtain.poll", ["decision": "wait"])
        first.flush()
        // "Relaunch": a brand-new recorder on the same directory.
        let second = DiagnosticRecorder(directory: dir, sessionID: "SECOND")
        second.startSession()
        second.record("app.lifecycle", ["phase": "active"])
        let text = contents(second)
        #expect(text.contains("SESSION START FIRST"))
        #expect(text.contains("curtain.poll decision=wait"))
        #expect(text.contains("SESSION START SECOND"))
        #expect(text.range(of: "SESSION START FIRST")!.lowerBound < text.range(of: "SESSION START SECOND")!.lowerBound)
    }

    @Test func sessionStartNotesAnUncleanPreviousExit() {
        let dir = tempDirectory()
        let first = DiagnosticRecorder(directory: dir, sessionID: "ONE")
        first.startSession()
        first.noteLifecycle("active")       // ...then force quit: no "background"
        first.flush()
        let second = DiagnosticRecorder(directory: dir, sessionID: "TWO")
        second.startSession()
        #expect(contents(second).contains("previousSessionEndedInForeground=true"))
    }

    @Test func theLogIsBoundedByRolling() {
        let dir = tempDirectory()
        let recorder = DiagnosticRecorder(directory: dir, maxBytes: 4_000, sessionID: "ROLL")
        for i in 0..<500 { recorder.record("tap.received", ["i": i]) }
        recorder.flush()
        let current = (try? Data(contentsOf: recorder.currentURL).count) ?? 0
        let previous = (try? Data(contentsOf: recorder.previousURL).count) ?? 0
        #expect(current <= 4_000 + 300)
        #expect(previous <= 4_000 + 300)
        // Newest events always survive.
        #expect(contents(recorder).contains("i=499"))
    }

    @Test func aShareSnapshotContainsPriorEvents() throws {
        let dir = tempDirectory()
        let recorder = DiagnosticRecorder(directory: dir, sessionID: "SHARE")
        recorder.startSession()
        recorder.record("curtain.arrivalDing")
        let url = try #require(recorder.makeShareSnapshotNow())
        #expect(url.lastPathComponent.hasPrefix("Hallways-Diagnostics-"))
        #expect(url.pathExtension == "txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("SESSION START SHARE"))
        #expect(text.contains("curtain.arrivalDing"))
        // Logging continues after the snapshot is taken.
        recorder.record("after.share")
        #expect(contents(recorder).contains("after.share"))
    }

    @Test func anUnwritableLocationFailsSilently() {
        // A regular FILE where the directory should be: nothing can be created.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        let recorder = DiagnosticRecorder(directory: blocker.appendingPathComponent("Diagnostics"), sessionID: "FAIL")
        recorder.startSession()
        recorder.record("elevator.accepted")
        recorder.noteLifecycle("active")
        recorder.flush()                    // no crash, no throw
        #expect(!FileManager.default.fileExists(atPath: recorder.currentURL.path))
    }

    @Test @MainActor func arrivalDecisionDoesNotDependOnLogging() {
        // Gameplay decisions are pure and read no recorder state.
        #expect(NavigationBridge.arrivalCurtainDecision(controlled: false, sceneReady: true, controllerReady: false, elapsed: 0) == .open)
        #expect(NavigationBridge.arrivalCurtainDecision(controlled: true, sceneReady: false, controllerReady: false, elapsed: 3.1) == .openAfterTimeout)
        let bridge = NavigationBridge()
        bridge.arrivalSceneReady = true      // didSet logs; value is still just stored
        #expect(bridge.arrivalSceneReady)
        #expect(!bridge.arrivalReadyToOpen)
    }

    @Test func valuesRenderCompactly() {
        #expect(DiagnosticRecorder.render(nil) == "nil")
        #expect(DiagnosticRecorder.render(Optional<Int>.none) == "nil")
        #expect(DiagnosticRecorder.render(Optional(3)) == "3")
        #expect(DiagnosticRecorder.render(1.5) == "1.500")
        #expect(DiagnosticRecorder.render("two words") == "\"two words\"")
    }
}
