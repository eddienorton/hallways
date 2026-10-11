import Foundation
import Testing
@testable import Hallways

/// Oct 8 (Phase 1 D): durable story beats. Throwaway storage only.
@MainActor
struct StoryBeatsTests {
    @Test func aBeatIsRecordedOnceWithItsFirstTime() {
        let storage = ThrowawayStorage()
        let beats = StoryBeats(defaults: storage.defaults)
        let t0 = Date(timeIntervalSince1970: 1_000_000), t1 = t0.addingTimeInterval(60)
        #expect(!beats.has("test.beat"))
        #expect(beats.record("test.beat", at: t0))
        #expect(!beats.record("test.beat", at: t1))          // never overwritten
        #expect(beats.time("test.beat") == t0)
    }

    @Test func beatsSurviveARelaunch() {
        let storage = ThrowawayStorage()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        StoryBeats(defaults: storage.defaults).record("test.beat", at: t0)
        let relaunched = StoryBeats(defaults: storage.defaults)
        #expect(relaunched.time("test.beat") == t0)
        #expect(!relaunched.record("test.beat", at: t0.addingTimeInterval(5)))
    }

    @Test func startOverClearsBeats() {
        let storage = ThrowawayStorage()
        let beats = StoryBeats(defaults: storage.defaults)
        beats.record("test.beat", at: Date(timeIntervalSince1970: 3_000_000))
        beats.resetForNewPlayer()
        #expect(!beats.has("test.beat"))
        #expect(!StoryBeats(defaults: storage.defaults).has("test.beat"))
        #expect(StartOver.clearedDefaultsKeys.contains(StoryBeats.storageKey))
    }
}
