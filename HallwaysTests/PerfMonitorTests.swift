import Foundation
import Testing
@testable import Hallways

/// Oct 21 -- the slowdown hunt's measurements (PerfMonitor). Measurement only:
/// these check the bookkeeping -- sections aggregate, history stays bounded, the
/// report carries what was measured, an episode is recognised -- not gameplay.
@MainActor
struct PerfMonitorTests {
    @Test func aSecondIsBadOnlyPastItsThresholds() {
        var s = PerfMonitor.Second()
        #expect(!s.isBad)
        s.mainBusyPct = 69; s.mainLongestMs = 249; s.frameGapMaxMs = 249; s.watchdogLateMs = 249
        #expect(!s.isBad)
        s.mainBusyPct = 70
        #expect(s.isBad)
        var stuck = PerfMonitor.Second()
        stuck.mainStuckMs = 300
        stuck.mainStuckIn = "life.tick"
        #expect(stuck.isBad)
        #expect(stuck.line.contains("STUCK 300ms@life.tick"))
    }

    @Test func sectionsAreTimedAndReportedByName() {
        guard PerfMonitor.enabled else { return }                       // (Release test runs: off)
        for _ in 0..<3 {
            let t = PerfMonitor.begin("test.section")
            usleep(2_000)
            PerfMonitor.end(t)
        }
        PerfMonitor.gauge("testGauge", +2)
        PerfMonitor.gauge("testGauge", -1)
        let report = PerfMonitor.shared.report()
        #expect(report.contains("PERFORMANCE"))
        #expect(report.contains("test.section 3"))                      // (since launch: name count total max)
        #expect(report.contains("testGauge=1"))
        PerfMonitor.gauge("testGauge", -1)
    }

    @Test func historyIsBounded() {
        guard PerfMonitor.enabled else { return }
        for _ in 0..<(PerfMonitor.historySeconds + 5) { PerfMonitor.shared.closeSecondForTests() }
        #expect(PerfMonitor.shared.historyCountForTests == PerfMonitor.historySeconds)
    }

    @Test func aWalkFrameRecordsMetresAndClamps() {
        var s = PerfMonitor.Second()
        s.walkMetres = [1.2, 0, 0]
        s.walkStepSeconds = 0.8
        s.walkRawSeconds = 1.0
        s.walkClamps = 4
        #expect(s.line.contains("walk c1.20"))
        #expect(s.line.contains("clamp 4"))
    }

    @Test func experimentSwitchesAreOffUnlessAsked() {
        // (the test scheme sets none of them)
        #expect(PerfSwitches.activeList.isEmpty)
    }
}
