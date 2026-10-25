import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 22 -- the cast walks on its own feet: the step cycle, and every cast
/// member's feet found in its model.
@MainActor
struct CastFeetTests {
    /// Stance: from `reach` ahead to `reach` behind, on the ground; swing: lifted,
    /// back to the front; continuous all the way round (no jumps).
    @Test func theStepCycleIsPlantedThenSwungAndContinuous() {
        let r: Float = 0.05, lift: Float = 0.02
        for duty: Float in [0.5, 0.55, 0.75] {
            let start = CastFeet.offset(phase: 0, reach: r, lift: lift, duty: duty)
            #expect(abs(start.forward - r) < 1e-5 && start.up == 0)
            // On the ground all through the stance, moving steadily back.
            let mid = CastFeet.offset(phase: 2 * .pi * duty * 0.5, reach: r, lift: lift, duty: duty)
            #expect(abs(mid.forward) < 1e-4 && mid.up == 0)
            // Lifted mid-swing.
            let swing = CastFeet.offset(phase: 2 * .pi * (duty + (1 - duty) / 2), reach: r, lift: lift, duty: duty)
            #expect(abs(swing.up - lift) < 1e-4)
            // Continuous: no step between neighbouring samples bigger than a small fraction.
            var last = CastFeet.offset(phase: 0, reach: r, lift: lift, duty: duty)
            for i in 1...720 {
                let o = CastFeet.offset(phase: Float(i) / 720 * 2 * .pi, reach: r, lift: lift, duty: duty)
                #expect(abs(o.forward - last.forward) < r * 0.05 && abs(o.up - last.up) < lift * 0.05)
                last = o
            }
        }
    }

    /// Every cast member walks on its feet, and each foot named is in its model.
    @Test func everyCastMemberHasFeetInItsModel() throws {
        for m in CastResidents.members where CastLegs.byMember[m.id] == nil && CastTripod.byMember[m.id] == nil {   // (Telephone: legs; Camera: tripod)
            let feet = try #require(CastFeet.byMember[m.id])
            #expect(!feet.limbs.isEmpty)
            #expect(feet.lift > 0 && feet.lift <= 0.04 && feet.reach > 0 && feet.reach <= 0.1)    // (small: they complement)
            #expect(abs(feet.reach - feet.duty * feet.step) < 1e-6)                    // (planted: no sliding)
            guard let model = HallwaysianModel.load(m.model, required: m.required)?.clone() else { continue }
            for limb in feet.limbs {
                for name in limb.nodes { #expect(model.childNode(withName: name, recursively: true) != nil, "\(m.id): \(name)") }
            }
            let rig = try #require(CastFootRig(feet: feet, model: model, scale: m.scale))
            // A full step and back to rest: every part exactly where it began.
            let rests = rig.parts.map { $0.node.position }
            rig.pose(phase: 1.3, amount: 1, bob: 0.005)
            rig.settle()
            for (p, r) in zip(rig.parts, rests) {
                #expect(p.node.position.x == r.x && p.node.position.y == r.y && p.node.position.z == r.z)
            }
        }
    }

    /// Oct 22 (later): the Telephone -- two articulated legs (hip, knee, ankle, foot),
    /// standing with its knees a little bent, and the four nubs gone from its walk.
    @Test func theTelephoneWalksOnTwoArticulatedLegs() throws {
        #expect(CastFeet.byMember["cast.telephone"] == nil)                 // (no nub walk to fight the legs)
        let spec = try #require(CastLegs.byMember["cast.telephone"])
        let parent = SCNNode()
        let rig = CastLegRig(spec, parent: parent)
        #expect(rig.pairs.count == 2)
        for leg in rig.pairs {                                               // (every joint of the Hallwaysian layout)
            #expect(leg.hip.childNodes.contains { $0 === leg.knee })
            #expect(leg.knee.childNodes.contains { $0 === leg.ankle })
            #expect(!leg.ankle.childNodes.isEmpty)                           // (the foot)
        }
        func ankle(_ leg: CastLegRig.Leg) -> SIMD3<Float> { leg.ankle.simdConvertPosition(.zero, to: parent) }
        // Standing: ankles on the floor's ankle height, under the hips, knees bent.
        rig.settle()
        for leg in rig.pairs {
            #expect(abs(ankle(leg).y - spec.ankleHeight) < 0.003)
            #expect(abs(ankle(leg).z) < 0.003)
            #expect(leg.knee.eulerAngles.x < -0.1)                            // (a visible bend)
        }
        // Mid-stride: one foot lifted (the swing), the other planted.
        let swingPhase = 2 * Float.pi * (spec.duty + (1 - spec.duty) / 2)
        rig.pose(phase: swingPhase, amount: 1, bob: 0)
        let heights = rig.pairs.map { ankle($0).y }
        #expect(heights.contains { abs($0 - (spec.ankleHeight + spec.lift)) < 0.004 })
        #expect(heights.contains { abs($0 - spec.ankleHeight) < 0.003 })
        // The body bobs up 8 mm (the legs ride its bob node): the planted foot reaches
        // 8 mm further down, so in the world it stays on the floor.
        rig.pose(phase: 0.4, amount: 1, bob: 0.008)
        let planted = rig.pairs.map { ankle($0).y }.min() ?? 0
        #expect(abs(planted - (spec.ankleHeight - 0.008)) < 0.003)
    }

    /// Oct 22 (evening): the Camera on a walking tripod -- three legs, feet on the
    /// floor in a tripod stance; walking, one leg at a time lifts (its lower tube
    /// telescoping in) while the other two stay planted; the tubes always overlap.
    @Test func theCameraWalksOnATripod() throws {
        #expect(CastFeet.byMember["cast.camera"] == nil)                    // (no flat-feet walk to fight it)
        let spec = try #require(CastTripod.byMember["cast.camera"])
        let parent = SCNNode()
        let rig = CastTripodRig(spec, parent: parent)
        #expect(rig.legs.count == 3)
        #expect(spec.mountHeight > 0.6)                                      // (much taller than its old feet)
        func foot(_ leg: CastTripodRig.Leg) -> SIMD3<Float> { leg.foot.simdConvertPosition(.zero, to: parent) }
        func overlap(_ leg: CastTripodRig.Leg) -> Bool {                     // (the lower tube's top still inside the upper)
            let top = -leg.lower.simdPosition.y
            return top > 0.05 && top < spec.upperLength
        }
        rig.settle()
        for leg in rig.legs {
            let f = foot(leg)
            #expect(abs(f.y - spec.footRadiusBall) < 0.004)                  // (on the floor)
            #expect(abs(simd_length(SIMD2(f.x, f.z)) - spec.footRadius) < 0.01)
            #expect(overlap(leg))
        }
        // Mid-swing for the first leg: it alone is lifted.
        let swing = 2 * Float.pi * (spec.duty + (1 - spec.duty) / 2)
        rig.pose(phase: swing, amount: 1, bob: 0, reachScale: 1)
        let heights = rig.legs.map { foot($0).y }
        #expect(heights.filter { $0 > spec.footRadiusBall + spec.lift * 0.8 }.count == 1)
        #expect(heights.filter { abs($0 - spec.footRadiusBall) < 0.004 }.count == 2)
        for leg in rig.legs { #expect(overlap(leg)) }
        // A whole cycle: never more than one foot off the floor at once.
        for i in 0..<60 {
            rig.pose(phase: Float(i) / 60 * 2 * .pi, amount: 1, bob: 0, reachScale: 1)
            #expect(rig.legs.filter { foot($0).y > spec.footRadiusBall + 0.004 }.count <= 1)
        }
    }

    /// The IK reaches what it's asked to, knees forward.
    @Test func theLegIKReachesItsTarget() {
        let l1: Float = 0.11, l2: Float = 0.115
        for (f, d) in [(Float(0), Float(0.2)), (0.07, 0.2), (-0.07, 0.2), (0.02, 0.15)] {
            let a = CastLegs.solve(forward: f, down: d, thigh: l1, shin: l2)
            let reachedF = l1 * sin(a.hip) + l2 * sin(a.hip + a.knee)
            let reachedD = l1 * cos(a.hip) + l2 * cos(a.hip + a.knee)
            #expect(abs(reachedF - f) < 0.002 && abs(reachedD - d) < 0.002)
            #expect(abs(a.hip + a.knee + a.ankle) < 1e-5)                    // (the foot kept level)
            #expect(a.knee < 0)                                               // (knee bends the natural way)
        }
    }

    /// Only the View-Master keeps its bounce; the rest walk with a small bob.
    @Test func onlyTheViewMasterStillSkips() {
        #expect(CastFeet.byMember["cast.viewmaster"]?.keepsHop == true)
        for (id, f) in CastFeet.byMember where id != "cast.viewmaster" { #expect(!f.keepsHop) }
    }
}
