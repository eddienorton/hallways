import Foundation
import SceneKit
import Testing
import simd
@testable import Hallways

/// Oct 19 -- THE HALLWAYSIANS (Feddy): the species' body and motor, and
/// Feddy's audition script. No scene is shown; the audition view isn't built.
@MainActor
struct HallwaysianTests {
    private func noNaN(_ p: HallwaysianPose) -> Bool { p.values.allSatisfy { $0.isFinite } }

    // MARK: The motor

    @Test func legIKPutsTheAnkleWhereAsked() {
        let a: Float = 0.17, b: Float = 0.175
        for (f, h) in [(Float(0), Float(0.34)), (0.08, 0.32), (-0.07, 0.31), (0.0, 0.28), (0.12, 0.27)] {
            let ik = HallwaysianMotor.legIK(thigh: a, shin: b, forward: f, down: h)
            let fx = a * sin(ik.hip) + b * sin(ik.hip + ik.knee)
            let fy = a * cos(ik.hip) + b * cos(ik.hip + ik.knee)
            #expect(abs(fx - f) < 0.002 && abs(fy - h) < 0.002)
            #expect(ik.knee <= 0.0001)                                   // (knees only ever bend backward)
        }
        // out of reach: straight, pointing at it
        let far = HallwaysianMotor.legIK(thigh: a, shin: b, forward: 0, down: 0.5)
        #expect(abs(far.knee) < 0.06 && abs(far.hip) < 0.06)
    }

    @Test func everyChannelSettlesOnItsTarget() {
        var m = HallwaysianMotor(genome: .feddy)
        var o = HallwaysianOverlay()
        o.gaze = .ahead
        o.blinks = false
        o.saccades = false
        o.targets = [.smile: 1, .needle: -0.8, .shPitchR: 1.2, .elbowL: 1.5, .headRoll: 0.3, .lid: 0.6]
        for _ in 0..<(60 * 4) { _ = m.update(dt: 1.0 / 60, overlay: o, camera: SIMD3(0, 1.2, 3)) }
        #expect(noNaN(m.pose))
        for (c, v) in o.targets { #expect(abs(m.pose[c] - v) < 0.02, "\(c)") }
    }

    @Test func heWalksToTheMarkAndStopsThere() {
        var m = HallwaysianMotor(genome: .feddy)
        m.place(x: 0, z: 0, yaw: .pi)
        m.walk(to: SIMD2(1.4, 0), face: .pi)
        var steps = 0
        var o = HallwaysianOverlay()
        o.gaze = .ahead
        for _ in 0..<(60 * 8) {
            steps += m.update(dt: 1.0 / 60, overlay: o, camera: SIMD3(0, 1.2, 3)).count
        }
        #expect(noNaN(m.pose))
        #expect(abs(m.pose[.x] - 1.4) < 0.03 && abs(m.pose[.z]) < 0.03)
        #expect(abs(HallwaysianMotor.wrap(m.pose[.yaw] - .pi)) < 0.05)
        #expect(!m.isBusy)
        #expect(steps >= 4)                                              // (it took steps, and said so)
        // standing again: both feet flat under him (ankles undo hip + knee)
        #expect(abs(m.pose[.hipPitchL] + m.pose[.kneeL] + m.pose[.ankleL]) < 0.01)
    }

    @Test func theSameRandomSequenceEveryTime() {
        var a = HallwaysianRandom(seed: 7), b = HallwaysianRandom(seed: 7)
        for _ in 0..<20 { #expect(a.next() == b.next()) }
        var c = HallwaysianRandom(seed: 7)
        for _ in 0..<200 { let u = c.unit(); #expect(u >= 0 && u < 1) }
    }

    // MARK: The body

    /// The body's extent, from its geometry (in the root's space).
    private func bounds(_ root: SCNNode) -> (SIMD3<Float>, SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        root.enumerateHierarchy { node, _ in
            guard let g = node.geometry, node.name != "hwContactShadow" else { return }
            let (a, b) = g.boundingBox
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let p = root.simdConvertPosition(node.simdConvertPosition(SIMD3(x, y, z), to: nil), from: nil)
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            } } }
        }
        return (lo, hi)
    }

    @Test func feddyIsBuiltWithEveryJointAndStandsOnTheFloor() throws {
        let body = HallwaysianBody(genome: .feddy)
        for name in ["hwPelvis", "hwTorso", "hwNeck", "hwHead", "hwFace", "hwEyeL", "hwEyeR", "hwLidUpperL", "hwLidLowerR",
                     "hwMouth", "hwShoulderL", "hwElbowR", "hwWristL", "hwHipR", "hwKneeL", "hwAnkleR"] {
            #expect(body.root.childNode(withName: name, recursively: true) != nil, "\(name)")
        }
        // Oct 19: no chest gauge any more (the species default), and no features he doesn't have.
        for name in ["hwGauge", "hwNeedle", "hwHair", "hwMoustache", "hwSkirt", "hwBrowL"] {
            #expect(body.root.childNode(withName: name, recursively: true) == nil, "\(name)")
        }
        let (lo, hi) = bounds(body.root)
        #expect(abs(lo.y) < 0.01)                                         // (feet on the floor, not in it)
        #expect(hi.y > 0.95 && hi.y < 1.25)                               // (about a metre tall)
        #expect(abs(hi.y - HallwaysianGenome.feddy.height) < 0.08)
    }

    @Test func anotherGenomeIsAnotherBody() {
        var tall = HallwaysianGenome.feddy
        tall.name = "Tall"
        tall.thigh *= 1.4; tall.shin *= 1.4; tall.neckLength *= 1.5
        tall.headRadii *= 0.85
        tall.gaugeRadius = 0
        let body = HallwaysianBody(genome: tall)
        #expect(body.root.childNode(withName: "hwGauge", recursively: true) == nil)
        let (lo, hi) = bounds(body.root)
        #expect(abs(lo.y) < 0.01)
        #expect(hi.y > HallwaysianGenome.feddy.height + 0.1)
        // and it moves like any other
        var m = HallwaysianMotor(genome: tall)
        for _ in 0..<120 { _ = m.update(dt: 1.0 / 60, overlay: HallwaysianOverlay(), camera: SIMD3(0, 1.5, 3)) }
        body.apply(m.pose)
        #expect(noNaN(m.pose))
    }

    @Test func theMouthBendsAndRounds() {
        let body = HallwaysianBody(genome: .feddy)
        let smile = body.mouthPoints(curve: 1, width: 1, round: 0)
        let frown = body.mouthPoints(curve: -1, width: 1, round: 0)
        let o = body.mouthPoints(curve: 0, width: 1, round: 1)
        #expect(smile.first!.y > smile[4].y)                             // corners up
        #expect(frown.first!.y < frown[4].y)                             // corners down
        #expect(simd_distance(o.first!, o.last!) < 0.004)                 // an "o" closes on itself
        for p in smile + frown + o { #expect(p.z < 0) }                   // all on the front of the face
    }

    // MARK: The audition

    @Test func theWholeAuditionPlaysAndComesRoundAgain() {
        var perf = FeddyPerformance(genome: .feddy)
        var heard: [FeddySound: Int] = [:]
        let camera = SIMD3<Float>(0, 1.6, 3)
        for _ in 0..<(60 * 61) {
            for s in perf.update(dt: 1.0 / 60, camera: camera) { heard[s, default: 0] += 1 }
            #expect(noNaN(perf.motor.pose))
        }
        #expect(heard[.click] == 1 && heard[.zap] == 1 && heard[.boing] == 1 && heard[.ding] == 1)
        #expect((heard[.step] ?? 0) >= 8)
        #expect(perf.clock < 2)                                           // (it looped)
        // every act begins at the place its script expects
        for (i, a) in FeddyScript.acts.enumerated() {
            perf.setMode(.act(i))
            #expect(abs(perf.motor.pose[.x] - a.place.x) < 0.001 && abs(perf.motor.pose[.z] - a.place.y) < 0.001)
            for _ in 0..<(60 * 3) { _ = perf.update(dt: 1.0 / 60, camera: camera) }
            #expect(noNaN(perf.motor.pose))
        }
        perf.setMode(.faces(nil))
        for _ in 0..<(60 * 20) { _ = perf.update(dt: 1.0 / 60, camera: camera) }
        #expect(noNaN(perf.motor.pose))
        #expect(FeddyScript.expressions.count == 7)
    }

    @Test func theAuditionIsOffUnlessAskedFor() {
        #expect(FeddyAudition.isRequested == UserDefaults.standard.bool(forKey: "HallwaysFeddyAudition"))
    }
}
