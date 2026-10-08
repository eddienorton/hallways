import Testing
import SceneKit
@testable import Hallways

/// Oct 7: Juanita (the Administrator) loses patience on her own while the
/// visitor stands at the counter -- the SAME escalation a poke drives.
/// Real time: her routines are timed against the wall clock.
@Suite(.serialized)
@MainActor
struct JuanitaPatienceTests {
    @MainActor private final class Fixture {
        let root = SCNNode()
        var atDesk = true
        private let savedIntervals = AdministrationReception.patienceIntervals
        private let savedAdmission = UserDefaults.standard.object(forKey: Admission.completedKey)
        private let savedPrologue = UserDefaults.standard.object(forKey: Admission.prologueCompletedKey)

        init(intervals: [TimeInterval]) {
            UserDefaults.standard.set(false, forKey: Admission.completedKey)          // target: the kiosk
            UserDefaults.standard.set(false, forKey: Admission.prologueCompletedKey)
            AdministrationReception.patienceIntervals = intervals
            AdministrationReception.directionsRequested = false
            AdministrationReception.install(into: root, cellSize: 3.2, cells: AdministrationReception.expectedCells)
            AdministrationReception.isVisitorAtDesk = { [unowned self] in self.atDesk }
        }

        func restore() {
            AdministrationReception.cancelPatienceTimer()
            AdministrationReception.isVisitorAtDesk = nil
            AdministrationReception.patienceIntervals = savedIntervals
            UserDefaults.standard.set(savedAdmission, forKey: Admission.completedKey)
            UserDefaults.standard.set(savedPrologue, forKey: Admission.prologueCompletedKey)
        }
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func wait(upTo seconds: Double, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { await wait(0.05) }
    }

    @Test func waitingAtTheCounterRunsTheWholeEscalationOnceAndStops() async {
        let f = Fixture(intervals: [0.2, 0.2, 0.2, 0.2])
        defer { f.restore() }
        AdministrationReception.landedAtDesk(in: f.root)              // The greeting, unchanged.
        #expect(AdministrationReception.patienceCount == 0)
        #expect(AdministrationReception.isPatienceTimerPending)
        var seen: [Int] = [0]
        await wait(upTo: 40) {
            let c = AdministrationReception.patienceCount
            if c != seen.last { seen.append(c) }
            return c >= 4
        }
        #expect(seen == [0, 1, 2, 3, 4])                              // One stage at a time, in order.
        #expect(!AdministrationReception.isPatienceTimerPending)      // Final stage: nothing more scheduled.
        await wait(5)
        #expect(AdministrationReception.patienceCount == 4)           // No loop.
        AdministrationReception.repeatDirections(in: f.root)          // A poke still gets the scream...
        #expect(AdministrationReception.patienceCount == 5)
        #expect(!AdministrationReception.isPatienceTimerPending)      // ...and no timer after it.
    }

    @Test func pokesAndTheTimerShareOneCountAndNeverOverlap() async {
        let f = Fixture(intervals: [0.2, 30, 0.2, 30])
        defer { f.restore() }
        AdministrationReception.landedAtDesk(in: f.root)
        AdministrationReception.repeatDirections(in: f.root)          // Mid-greeting: ignored.
        #expect(AdministrationReception.patienceCount == 0)
        await wait(upTo: 10) { AdministrationReception.patienceCount == 1 }   // Timer: stage 1.
        #expect(AdministrationReception.patienceCount == 1)
        AdministrationReception.repeatDirections(in: f.root)          // Mid-routine: ignored.
        #expect(AdministrationReception.patienceCount == 1)
        await wait(5)                                                 // Routine over; 30 s timer pending.
        #expect(AdministrationReception.patienceCount == 1)
        AdministrationReception.repeatDirections(in: f.root)          // A poke: the SAME count moves on.
        #expect(AdministrationReception.patienceCount == 2)
        // The poke restarted the clock with stage 2's interval (0.2 s after
        // its routine) -- the timer carries on from 2, not from 1.
        await wait(upTo: 6) { AdministrationReception.patienceCount == 3 }
        #expect(AdministrationReception.patienceCount == 3)
        await wait(4)
        #expect(AdministrationReception.patienceCount == 3)           // Next interval is 30 s.
    }

    @Test func walkingAwayStopsItAndReturningResumesFromTheSameStage() async {
        let f = Fixture(intervals: [0.2, 0.2, 0.2, 0.2])
        defer { f.restore() }
        AdministrationReception.landedAtDesk(in: f.root)
        f.atDesk = false                                              // Walks off during the greeting.
        await wait(6)
        #expect(AdministrationReception.patienceCount == 0)           // No invisible escalation.
        #expect(!AdministrationReception.isPatienceTimerPending)
        f.atDesk = true
        AdministrationReception.landedAtDesk(in: f.root)              // Back at the counter: no re-greeting...
        #expect(AdministrationReception.isPatienceTimerPending)       // ...the clock starts again.
        await wait(upTo: 3) { AdministrationReception.patienceCount == 1 }
        #expect(AdministrationReception.patienceCount == 1)
        // Leaving the counter cell cancels outright (ContentView's onCellChanged).
        AdministrationReception.cancelPatienceTimer()
        #expect(!AdministrationReception.isPatienceTimerPending)
        await wait(6)
        #expect(AdministrationReception.patienceCount == 1)
    }
}
