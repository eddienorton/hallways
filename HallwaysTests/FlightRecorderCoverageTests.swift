import Foundation
import Testing
@testable import Hallways

/// Oct 8: the flight recorder's state snapshots and follower summary.
@MainActor
struct FlightRecorderCoverageTests {
    private func tempRecorder() -> DiagnosticRecorder {
        DiagnosticRecorder(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("FlightRecorderCoverageTests-\(UUID().uuidString)", isDirectory: true),
                           sessionID: "SNAP")
    }

    @Test func aSnapshotGoesThroughTheInstalledProviderIntoTheLog() {
        let recorder = tempRecorder()
        recorder.snapshot("share")                       // no scene installed yet: nothing, no crash
        recorder.snapshotProvider = { reason in recorder.record("snapshot.state", ["reason": reason, "cell": "3,7"]) }
        recorder.snapshot("share")
        recorder.flush()
        let text = (try? String(contentsOf: recorder.currentURL, encoding: .utf8)) ?? ""
        #expect(text.contains("snapshot.state reason=share cell=3,7"))
        #expect(text.components(separatedBy: "snapshot.state").count == 2)   // exactly one
    }

    @Test func thePosseSummaryNamesEveryRecordAndItsFollowState() {
        let saved = Posse.records
        defer { Posse.records = saved }
        var record = Posse.Record()
        record.following = true
        record.met = true
        record.homeFloor = 3
        Posse.records = ["freddy": record]
        #expect(Posse.diagSummary.contains("freddy.record:following,met=true,home=F3"))
        Posse.records = [:]
        #expect(!Posse.diagSummary.contains(".record:"))
    }
}
