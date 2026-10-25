import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 20 (night) -- THE GUIDE'S BRISK PACE: leading the player to a task, a
/// critter walks at about 1.4 m/s, its legs matched (longer AND quicker steps,
/// so no sliding, no scurrying); the moment its guiding ends it is back to its
/// own leisurely pace. The player's follow walk keeps up, a natural gap behind.
@MainActor
struct GuidePaceTests {
    // MARK: The gait

    @Test func theGuidesStepIsLongerAndQuickerAndExactlyItsPace() {
        for pace: Float in [0.684, 0.72, 0.6] {                             // Feddy, Sister, the chair
            let g = GuidePace.gait(normalPace: pace)
            #expect(abs(pace * g.stride * g.cadence - GuidePace.speed) < 1e-4) // (the body's speed IS the legs' speed)
            #expect(g.stride > 1 && g.stride <= GuidePace.strideCap)
            #expect(g.cadence > 1 && g.cadence < 1.45)                          // (quicker, never frantic)
            #expect(g.stride > g.cadence)                                       // (mostly a longer step)
        }
        // Pottle (0.35, four times over): a longer tip of the pot, not a frantic one.
        let pot = GuidePace.gait(normalPace: 0.35, strideCap: GuidePace.pottleStrideCap)
        #expect(abs(0.35 * pot.stride * pot.cadence - GuidePace.speed) < 1e-4)
        #expect(pot.cadence < 1.6)
        // Already brisk: unchanged.
        let same = GuidePace.gait(normalPace: 2.0)
        #expect(same.stride == 1 && same.cadence == 1)
        #expect(GuidePace.speed == 1.4)
    }

    @Test func aHallwaysiansLegsKeepUpAndComeBack() {
        let persona = HallwaysianCast.feddy
        var motor = HallwaysianMotor(genome: persona.genome)
        let g = GuidePace.gait(normalPace: persona.pace)
        motor.setGait(stride: g.stride, cadence: g.cadence)
        #expect(abs(motor.stride * motor.cadence - GuidePace.speed) < 1e-4)
        // Walking a long way at the guide's gait: about 1.4 m/s once under way.
        motor.place(x: 0, z: 0, yaw: 0)
        motor.walk(to: SIMD2<Float>(0, -40))
        for _ in 0..<120 { _ = motor.update(dt: 1.0 / 60, overlay: HallwaysianOverlay(), camera: SIMD3(0, 1.5, 3)) }  // (2 s to get going)
        let z0 = motor.pose[.z]
        for _ in 0..<180 { _ = motor.update(dt: 1.0 / 60, overlay: HallwaysianOverlay(), camera: SIMD3(0, 1.5, 3)) }  // 3 s
        let mps = (z0 - motor.pose[.z]) / 3
        #expect(abs(mps - GuidePace.speed) < 0.1)
        // Its own gait again.
        motor.setGait(stride: 1, cadence: 1)
        #expect(motor.stride == persona.genome.stride && motor.cadence == persona.genome.cadence)
    }

    @Test func briskOnlyWhileGuidingThenItsOwnPaceAtOnce() {
        let context = CharacterLead.Context(cells: [], doors: [:], cellSize: 3.52, playerPose: { nil },
                                            isDoorOpen: { _ in true }, openDoor: { _ in })
        let feddy = HallwaysianResidentBody(persona: HallwaysianCast.feddy, context: context)
        #expect(abs(feddy.speed - HallwaysianCast.feddy.pace) < 1e-6)        // (leisurely on his own)
        feddy.setGuidePace(GuidePace.speed)
        #expect(feddy.speed == GuidePace.speed)
        feddy.setGuidePace(nil)
        #expect(abs(feddy.speed - HallwaysianCast.feddy.pace) < 1e-6)
        let chair = ChairResidentBody()
        #expect(chair.speed == ChairResidentBody.speed)
        chair.setGuidePace(GuidePace.speed)
        #expect(chair.speed == GuidePace.speed)
        chair.setGuidePace(nil)
        #expect(chair.speed == ChairResidentBody.speed)
    }

    // MARK: The player keeps up, a natural gap behind

    @Test func thePlayerKeepsUpWithABriskGuideANaturalGapBehind() async {
        let cells = Set((0...40).map { GridCoordinate(row: 0, col: $0) })
        let c = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: cells, cellSize: 3.2,
                                        startCell: GridCoordinate(row: 0, col: 0), startFacing: .east,
                                        endCell: GridCoordinate(row: 0, col: 40), floorNumber: 4)
        var leaderX: Float = 2.5                                               // (just ahead, walking east at 1.4 m/s)
        c.followGuidance = { [leaderX] in
            (route: (0...40).map { GridCoordinate(row: 0, col: $0) }, leader: SIMD2<Float>(leaderX, 0))
        }
        #expect(c.startFollowWalk())
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        var gaps: [Float] = []
        for k in 0..<(8 * 40) {                                                // (8 s, in real time: the walk reads the
                                                                               //  critter's place every 0.15 s of the clock)
            time += 0.025
            leaderX += GuidePace.speed * 0.025
            let lx = leaderX
            c.followGuidance = { (route: (0...40).map { GridCoordinate(row: 0, col: $0) }, leader: SIMD2<Float>(lx, 0)) }
            c.renderer(renderer, updateAtTime: time)
            try? await Task.sleep(for: .milliseconds(25))
            if k > 160 { gaps.append(lx - c.cameraNode.position.x) }          // (after 4 s)
        }
        let worst = gaps.max() ?? 99, least = gaps.min() ?? 0
        #expect(least >= Float(TapNavigationController.escortFollowGap) - 0.3)   // never on its heels
        #expect(worst <= Float(CritterFollow.closeEnough) + 1.0)                 // never left behind
        c.stopContinuousWalk(reason: "test")
    }
}
