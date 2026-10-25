import Foundation
import Testing
import simd
@testable import Hallways

/// Oct 25 (PP 8) -- THE MUD FIX's frame snapshot: what it publishes, when a frame counts as "now", and that a
/// fresh scene never sees another's values. (Whether the mud is gone is the on-device Instruments re-test.)
struct PresentationSnapshotTests {
    @Test func nothingBeforeTheFirstFrame() {
        let s = PresentationSnapshot()
        #expect(s.fresh(now: 100) == nil)                                 // (callers then read SceneKit directly)
        #expect(!PresentationSnapshot.isFresh(.init(), now: 0))
    }

    @Test func theLastDrawnFrameIsReturnedWhileRecent() throws {
        let s = PresentationSnapshot()
        s.publish(cameraWorld: SIMD3(1, 1.6, 2), cameraYaw: 0.5, rightDoor: SIMD3(3, 0, 4), at: 10)
        let f = try #require(s.fresh(now: 10.1))
        #expect(f.cameraWorld == SIMD3(1, 1.6, 2) && f.cameraYaw == 0.5)
        #expect(f.hasRightDoor && f.rightDoor == SIMD3(3, 0, 4))
        #expect(f.count == 1 && f.time == 10)
        s.publish(cameraWorld: SIMD3(5, 1.6, 6), cameraYaw: -1, rightDoor: nil, at: 10.033)
        let g = try #require(s.fresh(now: 10.05))
        #expect(g.cameraWorld == SIMD3(5, 1.6, 6) && g.cameraYaw == -1 && g.count == 2)
        #expect(!g.hasRightDoor)                                          // (a floor without the car's doors)
    }

    @Test func anOldFrameIsIgnored() {
        let s = PresentationSnapshot()
        s.publish(cameraWorld: .zero, cameraYaw: 0, rightDoor: nil, at: 10)
        #expect(s.fresh(now: 10 + PresentationSnapshot.maxAge) != nil)
        #expect(s.fresh(now: 10 + PresentationSnapshot.maxAge + 0.001) == nil)   // (not rendering: read SceneKit)
        #expect(s.fresh(now: 9.9) == nil)                                 // (never a frame "from the future")
        #expect(PresentationSnapshot.maxAge < 0.5)
    }

    @Test func eachSceneHasItsOwnSnapshot() {
        let old = PresentationSnapshot(), new = PresentationSnapshot()
        old.publish(cameraWorld: SIMD3(9, 9, 9), cameraYaw: 1, rightDoor: SIMD3(1, 1, 1), at: 5)
        #expect(new.fresh(now: 5.01) == nil)                              // a new controller starts empty
        #expect(old.fresh(now: 5.01) != nil)
    }

    @Test func publishingFromAnotherThreadWhileReadingIsSafe() async {
        let s = PresentationSnapshot()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<2_000 {
                    let v = Float(i)
                    s.publish(cameraWorld: SIMD3(v, v, v), cameraYaw: v, rightDoor: SIMD3(v, 0, v), at: Double(i) * 0.001)
                }
            }
            group.addTask {
                for i in 0..<2_000 {
                    if let f = s.fresh(now: Double(i) * 0.001) {
                        // every frame read is whole: its values all come from one publish
                        #expect(f.cameraWorld.x == f.cameraYaw && f.rightDoor.x == f.cameraYaw)
                    }
                }
            }
        }
    }
}
