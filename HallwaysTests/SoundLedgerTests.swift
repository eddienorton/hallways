import Foundation
import Testing
@testable import Hallways

/// Oct 19 -- THE AUDIO CRASH: who owns a playing critter sound (SoundLedger,
/// the logic behind PlayingSounds). A stand-in for SCNAudioPlayer + node: no
/// SceneKit, no audio engine. What matters: the ledger holds every sound from
/// its start until `grace` after it is retired, detaches it once (only if
/// still attached), tolerates a finish that comes twice, late or never, and
/// counts each sound in and out exactly once.
@MainActor
struct SoundLedgerTests {
    /// A playing sound: whether its node still lists it, how often it was detached.
    final class FakeSound {
        var attached = true
        var detaches = 0
    }

    private func ledger(_ events: Box) -> SoundLedger<FakeSound> {
        let l = SoundLedger<FakeSound>(grace: 3, detach: { s in s.attached = false; s.detaches += 1 },
                                       isAttached: { s in s.attached })
        l.onEvent = { event, id, _, why in events.list.append("\(event) \(id) \(why)") }
        return l
    }
    final class Box { var list: [String] = [] }

    @Test func aFinishedSoundIsDetachedOnceAndReleasedOnlyAfterItsGrace() {
        let events = Box()
        let l = ledger(events)
        var sound: FakeSound? = FakeSound()
        weak var watch = sound
        let id = l.register(sound!, label: "pottle rustle", maxAge: 30, now: 0)
        sound = nil
        #expect(watch != nil)                                  // (the ledger owns it, not its node)
        l.finished(id, now: 1)
        #expect(watch?.detaches == 1)
        #expect(l.liveCount == 0)
        l.purge(now: 2)
        #expect(watch != nil)                                  // (still held: a callback may still be running)
        l.purge(now: 4.1)
        #expect(watch == nil)                                  // (released after the grace, no sooner)
        #expect(l.holdingCount == 0)
    }

    @Test func aDuplicateOrLateFinishChangesNothing() {
        let events = Box()
        let l = ledger(events)
        let s = FakeSound()
        let id = l.register(s, label: "dog woof", maxAge: 30, now: 0)
        l.finished(id, now: 1)
        l.finished(id, now: 1.1)                                // (twice)
        #expect(s.detaches == 1)
        #expect(events.list.filter { $0.hasPrefix("retired") }.count == 1)
        #expect(events.list.contains { $0.hasPrefix("finishedAfterRetire \(id)") })
        l.finished(999, now: 2)                                 // (never registered)
        #expect(events.list.contains { $0.hasPrefix("finishedUnknown 999") })
        #expect(l.liveCount == 0)
    }

    /// The crash's case: its body is taken down (removeAllAudioPlayers, a floor
    /// change, boarding) while it is still sounding. The ledger keeps it alive
    /// through the finish SceneKit sends for the stop, and never detaches twice.
    @Test func aSoundRemovedUnderItIsHeldThroughItsLateCallback() {
        let events = Box()
        let l = ledger(events)
        var sound: FakeSound? = FakeSound()
        weak var watch = sound
        let id = l.register(sound!, label: "clacker call", maxAge: 30, now: 0)
        sound!.attached = false                                 // (someone else removed it from its node)
        sound = nil
        l.sweep(now: 0.5)
        #expect(l.liveCount == 0)
        #expect(watch != nil)                                   // (retired, still held)
        #expect(watch?.detaches == 0)                           // (it wasn't attached: not detached again)
        l.finished(id, now: 1.0)                                // (SceneKit's finish for the stop, late)
        #expect(watch != nil)
        l.sweep(now: 4)
        #expect(watch == nil)
    }

    @Test func aSoundWhoseFinishNeverComesIsRetiredWhenOverdue() {
        let events = Box()
        let l = ledger(events)
        let s = FakeSound()
        _ = l.register(s, label: "cat meow", maxAge: 30, now: 0)
        l.sweep(now: 10)
        #expect(l.liveCount == 1)                               // (still playing, attached)
        l.sweep(now: 31)
        #expect(l.liveCount == 0)
        #expect(s.detaches == 1)
        #expect(events.list.contains { $0.contains("overdue") })
        // A looping sound (no age limit) stays until it's removed or finishes.
        let loop = FakeSound()
        _ = l.register(loop, label: "hum", maxAge: nil, now: 0)
        l.sweep(now: 500)
        #expect(l.liveCount == 1)
    }

    /// Many sounds at once (a crowd at the elevator), finishing in any order:
    /// every one counted in and out once, nothing left behind.
    @Test func manySoundsNoneLeftBehind() {
        let events = Box()
        let l = ledger(events)
        var ids: [Int] = []
        var sounds: [FakeSound] = []
        for i in 0..<50 {
            let s = FakeSound()
            sounds.append(s)
            ids.append(l.register(s, label: "step \(i)", maxAge: 30, now: Double(i) * 0.1))
        }
        for (k, id) in ids.enumerated().reversed() where k % 2 == 0 { l.finished(id, now: 6) }
        for s in sounds.enumerated() where s.offset % 2 == 1 { s.element.attached = false }      // (their body went)
        l.sweep(now: 6)
        #expect(l.liveCount == 0)
        #expect(sounds.allSatisfy { $0.detaches <= 1 })
        #expect(events.list.filter { $0.hasPrefix("created") }.count == 50)
        #expect(events.list.filter { $0.hasPrefix("retired") }.count == 50)
        l.purge(now: 10)
        #expect(l.holdingCount == 0)
    }
}
