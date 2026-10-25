import Foundation
import Testing
import SceneKit
@testable import Hallways

/// Oct 20 -- AUTOMATIC WALKING AT 0.8 (a tap walk, the continuous walk --
/// following a critter --, the latched walk with no finger on it); the escort's
/// walk (Mr. Tinky's, GO to his desk) kept exactly as it was. And each critter's
/// come-hither, by temperament.
@MainActor
struct AutoWalkPaceTests {
    @Test func automaticWalksGoAtEightTenthsAndTheEscortIsUntouched() {
        typealias C = TapNavigationController
        #expect(C.autoWalkSpeedScale == 0.8)
        #expect(C.continuousWalkPaceScale(escorting: false) == 0.8)
        #expect(C.continuousWalkPaceScale(escorting: true) == 1)          // (Tinky's onboarding escort: as it was)
    }

    @Test func aTapWalkTakesAQuarterLongerOnItsWay() {
        typealias C = TapNavigationController
        // Three cells (9.6 m): the old 6 m/s took 1.6 s + the ramp; now 4.8 m/s -> 2.0 s + the ramp.
        let old = C.tapWalkTiming(distance: 9.6, cellSize: 3.2, speed: 6, approach: false, turnAcrossWholeGlide: false)
        let now = C.tapWalkTiming(distance: 9.6, cellSize: 3.2, speed: 6 * C.autoWalkSpeedScale, approach: false, turnAcrossWholeGlide: false)
        #expect(abs(old.duration - (1.6 + C.freeTapRamp)) < 1e-9)
        #expect(abs(now.duration - (2.0 + C.freeTapRamp)) < 1e-9)
        #expect(abs((now.duration - now.ramp) / (old.duration - old.ramp) - 1.25) < 1e-9)
        // A short tap (within a cell) keeps its old shape: no ramp, a smoothstep, its turn as long as it.
        let short = C.tapWalkTiming(distance: 1.2, cellSize: 3.2, speed: 4.8, approach: false, turnAcrossWholeGlide: false)
        #expect(short.ramp == 0 && abs(short.duration - 0.25) < 1e-9 && short.turn == short.duration)
        // An approach (a door, a desk) always turns unhurriedly: at least one cell's time.
        let approach = C.tapWalkTiming(distance: 0.5, cellSize: 3.2, speed: 4.8, approach: true, turnAcrossWholeGlide: false)
        #expect(abs(approach.duration - 3.2 / 4.8) < 1e-9)
    }

    @Test func theFollowWalkCoversLessGroundThanBeforeButStillArrives() async {
        // A long corridor, the critter far ahead: 1.5 s of the follow walk.
        let cells = Set((0...30).map { GridCoordinate(row: 0, col: $0) })
        let c = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: cells, cellSize: 3.2,
                                        startCell: GridCoordinate(row: 0, col: 0), startFacing: .east,
                                        endCell: GridCoordinate(row: 0, col: 30), floorNumber: 4)
        c.followGuidance = { (route: (0...30).map { GridCoordinate(row: 0, col: $0) }, leader: SIMD2<Float>(30 * 3.2, 0)) }
        #expect(c.startFollowWalk())
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        for _ in 0..<60 {
            time += 0.025
            c.renderer(renderer, updateAtTime: time)
            try? await Task.sleep(for: .milliseconds(2))
        }
        let x = Double(c.cameraNode.position.x)
        #expect(x > 0.5)                                                       // walking
        #expect(x < 1.5 * 6 * TapNavigationController.autoWalkSpeedScale + 0.3)    // under the new 4.8 m/s (the old 6 m/s could reach 9 m)
        c.stopContinuousWalk(reason: "test")
    }

    @Test func eachHallwaysianBeckonsInItsOwnWay() {
        let byID = Dictionary(uniqueKeysWithValues: HallwaysianCast.all.map { ($0.id, $0.acknowledgment.name) })
        #expect(byID["hw.tiny"] == HallwaysianGesture.jig.name)              // the bouncy ones: a little jig
        #expect(byID["hw.pear"] == HallwaysianGesture.jig.name)
        #expect(byID["hw.sister"] == HallwaysianGesture.bow.name)            // the warm and the courtly: a small bow
        #expect(byID["hw.oldgent"] == HallwaysianGesture.bow.name)
        #expect(byID["hw.feddy"] == HallwaysianGesture.beckon.name)          // everyone else: a beckoning hand
        #expect(Set(byID.values).count == 3)
        for g in [HallwaysianGesture.beckon, .jig, .bow] { #expect(g.duration > 1 && g.duration < 2.5) }   // brief
    }
}
