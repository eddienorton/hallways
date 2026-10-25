//
//  CastFeet.swift
//  Hallways
//
//  Oct 22 -- THE CAST WALKS ON ITS FEET.
//
//  The meeting's six (in the building as residents) used to glide: one body
//  hop per stride, a roll and a lean -- their feet, which every one of their
//  models already has, never moved. Now, while a cast member walks, its OWN
//  feet (and legs, where the model has them) step: no new geometry, nothing
//  of its look changed -- the same parts, moving.
//
//    Telephone    (Oct 22, later) TWO ARTICULATED LEGS of its own -- see CastLegs below
//    View-Master  two flat feet, left-right -- and it still skips (it keeps its bounce)
//    Stove        three cabriole legs with ball feet: one at a time, heavy, slow
//    Mailbox      four post legs with feet, a diagonal trot (his look unchanged)
//    Camera       (Oct 22, evening) A WALKING TRIPOD of its own -- see CastTripod below
//    Television   four tapered legs with ferrules, a stiff diagonal waddle
//
//  HOW: the walk is already a per-frame SCNAction that knows how far along its
//  path it is (CastResidentBody.travel). The step cycle is DISTANCE-based --
//  one of its own steps of travel per half cycle -- so the steps quicken and
//  slow with the actual speed (a guide's pace included) and stop when it stops.
//  A foot in stance moves backward under the body exactly as fast as the body
//  moves forward (reach = duty x step: planted, no sliding); a foot in swing
//  lifts and comes forward. The body's roll and bob keep time with the feet. The body's old hop is kept small
//  for the ones that walk (the planted feet are held to the floor against it);
//  the View-Master keeps its full bounce (a skip). Easing at the start and end
//  of every walk; at the end every foot settles back exactly where it rests.
//  Turning on the spot: a few small steps in place (no skating round).
//
//  Cost: up to eight node positions per walking cast member per frame, set
//  from arrays prepared once per body -- no allocations, no new nodes.
//
//  Off (navigation untouched): `-HallwaysCritterFeet NO` -- the old glide.
//  Per character: remove its entry from `CastFeet.byMember`.
//

import Foundation
import SceneKit
import UIKit
import simd

nonisolated struct CastFeet: Sendable {
    /// One foot (or leg-and-foot): the model's node names moved together, and its place in the cycle.
    struct Limb: Sendable {
        let nodes: [String]
        /// Radians: where in the step cycle this one is (0 / pi: a pair alternating).
        let phase: Float
    }

    let limbs: [Limb]
    /// How high a swinging foot lifts (metres, in the world).
    let lift: Float
    /// Its own step: metres of travel per half cycle (one foot's -- or pair's -- step).
    let step: Float
    /// Share of the cycle a foot is on the ground (0.5: a walk/trot; more: heavier).
    let duty: Float
    /// How far a foot travels fore and aft of its rest (metres, each way) -- exactly
    /// what the body covers while that foot is down, so a planted foot never slides.
    var reach: Float { duty * step }
    /// Keep the body's own hop as it was (a skip) -- otherwise it's kept small.
    let keepsHop: Bool

    /// The most a walking body still bobs (metres) when it walks on its feet.
    static let walkingBob: Float = 0.008

    /// Off with `-HallwaysCritterFeet NO` (navigation is never affected).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "HallwaysCritterFeet") == nil || UserDefaults.standard.bool(forKey: "HallwaysCritterFeet")
    }

    static let byMember: [String: CastFeet] = [
        // (The Telephone: two articulated legs instead -- CastLegs below; its four nubs are hidden.)
        "cast.viewmaster": CastFeet(limbs: [Limb(nodes: ["foot"], phase: 0), Limb(nodes: ["foot_001"], phase: .pi)],
                                    lift: 0.03, step: 0.13, duty: 0.5, keepsHop: true),
        // One leg at a time, round the tripod; long on the ground.
        "cast.stove": CastFeet(limbs: [Limb(nodes: ["legM", "foot"], phase: 0),
                                       Limb(nodes: ["leg_001M", "foot_001"], phase: 2 * .pi / 3),
                                       Limb(nodes: ["leg_002M", "foot_002"], phase: 4 * .pi / 3)],
                               lift: 0.02, step: 0.12, duty: 0.75, keepsHop: false),
        "cast.mailbox": CastFeet(limbs: [Limb(nodes: ["leg", "foot"], phase: 0), Limb(nodes: ["leg_003", "foot_003"], phase: 0),
                                         Limb(nodes: ["leg_001", "foot_001"], phase: .pi), Limb(nodes: ["leg_002", "foot_002"], phase: .pi)],
                                 lift: 0.025, step: 0.14, duty: 0.55, keepsHop: false),
        // (The Camera: a walking tripod instead -- CastTripod below; its two flat feet are hidden.)
        "cast.television": CastFeet(limbs: [Limb(nodes: ["leg", "ferrule"], phase: 0), Limb(nodes: ["leg_003", "ferrule_003"], phase: 0),
                                            Limb(nodes: ["leg_001", "ferrule_001"], phase: .pi), Limb(nodes: ["leg_002", "ferrule_002"], phase: .pi)],
                                    lift: 0.02, step: 0.12, duty: 0.55, keepsHop: false),
    ]

    /// A foot's offset from its rest (metres, body frame: +forward, +up) at
    /// cycle position `phase` (radians, any value). Stance: from `reach` ahead
    /// to `reach` behind, on the ground. Swing: lifted, eased back to the front.
    static func offset(phase: Float, reach: Float, lift: Float, duty: Float) -> (forward: Float, up: Float) {
        let tau = 2 * Float.pi
        var c = phase.truncatingRemainder(dividingBy: tau)
        if c < 0 { c += tau }
        let stance = tau * min(0.95, max(0.05, duty))
        if c < stance {
            return (reach * (1 - 2 * c / stance), 0)
        }
        let s = (c - stance) / (tau - stance)
        let eased = s * s * (3 - 2 * s)
        return (-reach + 2 * reach * eased, lift * sin(.pi * s))
    }
}

/// The feet of one body, found once in its model (only the names that are there).
nonisolated final class CastFootRig: @unchecked Sendable {
    struct Part {
        let node: SCNNode
        let rest: SCNVector3
        let phase: Float
    }
    let feet: CastFeet
    let parts: [Part]
    /// Model units per metre (1 / the model's scale).
    let perMetre: Float
    /// Its model faces +z (its forward, in the model's own frame).
    let forwardSign: Float = 1

    init?(feet: CastFeet, model: SCNNode, scale: Float) {
        var parts: [Part] = []
        for limb in feet.limbs {
            for name in limb.nodes {
                guard let n = model.childNode(withName: name, recursively: true) else { continue }
                parts.append(Part(node: n, rest: n.position, phase: limb.phase))
            }
        }
        guard !parts.isEmpty, scale > 0 else { return nil }
        self.feet = feet
        self.parts = parts
        self.perMetre = 1 / scale
    }

    /// Every foot at cycle `phase`, scaled by `amount` (0 at rest ... 1 full step);
    /// `bob`: how high the body is lifted now (metres) -- planted feet are held
    /// down against it. `reachScale` 0: stepping in place (turning).
    func pose(phase: Float, amount: Float, bob: Float, reachScale: Float = 1) {
        let f = feet
        for p in parts {
            let o = CastFeet.offset(phase: phase + p.phase, reach: f.reach * reachScale, lift: f.lift, duty: f.duty)
            let up = (o.up * amount - (f.keepsHop ? 0 : bob)) * perMetre
            let forward = o.forward * amount * perMetre * forwardSign
            p.node.position = SCNVector3(p.rest.x, p.rest.y + up, p.rest.z + forward)
        }
    }

    /// Every foot exactly where it rests.
    func settle() {
        for p in parts { p.node.position = p.rest }
    }
}


// MARK: - Oct 22 (later): the Telephone's two articulated legs

/// Two legs built the Hallwaysians' way (HallwaysianSpecies: brass ball hip,
/// thigh rod, brass knee, tapering shin, ankle, rubber foot -- the same parts,
/// materials and joint layout), proportioned to the Telephone's Bakelite body
/// and walked with a two-bone IK: alternating steps, knees that bend, feet that
/// lift and land flat. Always there (standing still too); the body sits on them.
nonisolated struct CastLegs: Sendable {
    /// Metres (in the world).
    var thigh: Float = 0.13              // (Oct 22, evening: +18% -- was 0.11)
    var shin: Float = 0.136              // (Oct 22, evening: +18% -- was 0.115)
    var hipSpread: Float = 0.11        // each hip from the centre line
    var legRadius: Float = 0.011
    var shinTip: Float = 0.008
    var jointRadius: Float = 0.018
    var footLength: Float = 0.10
    var footWidth: Float = 0.05
    var footHeight: Float = 0.032
    /// Standing: the legs this share of their full length (knees a little bent, visibly).
    var standStraightness: Float = 0.9
    /// The step: metres of travel per half cycle; share of the cycle on the ground; foot lift.
    var step: Float = 0.165              // (Oct 22, evening: longer legs, longer steps -- was 0.14)
    var duty: Float = 0.55
    var lift: Float = 0.05
    var reach: Float { duty * step }
    /// Ankle height above the floor (the foot's sole on the floor).
    var ankleHeight: Float { footHeight * 0.9 }
    /// Hip height above the floor, standing.
    var hipHeight: Float { ankleHeight + standStraightness * (thigh + shin) }

    static let byMember: [String: CastLegs] = [
        "cast.telephone": CastLegs(),
    ]
    /// The model parts the legs replace (hidden).
    static let replaces: [String: [String]] = [
        "cast.telephone": ["foot", "foot_001", "foot_002", "foot_003"],
    ]

    /// Two-bone IK in the leg's own plane: hip pitch, knee bend, ankle (foot kept level),
    /// for an ankle `forward` metres ahead of the hip and `down` metres below it.
    /// Knees bend forward. Pure (tests).
    static func solve(forward: Float, down: Float, thigh l1: Float, shin l2: Float) -> (hip: Float, knee: Float, ankle: Float) {
        var d = (forward * forward + down * down).squareRoot()
        d = min(max(d, 0.3 * (l1 + l2)), 0.999 * (l1 + l2))
        let phi = atan2(forward, down)                                   // (0: straight down; + forward)
        let beta = acos(min(1, max(-1, (l1 * l1 + d * d - l2 * l2) / (2 * l1 * d))))
        let alpha = acos(min(1, max(-1, (l1 * l1 + l2 * l2 - d * d) / (2 * l1 * l2))))
        let hip = phi + beta                                             // (rotation about x: + swings the leg forward, -z)
        let knee = -(Float.pi - alpha)
        return (hip, knee, -(hip + knee))
    }
}

/// One body's pair of legs: built once, posed per frame (six angles, no allocations).
/// Oct 22 (evening): a body's own legs (the Telephone's two, the Camera's tripod) --
/// what CastResidentBody drives while it walks and turns.
nonisolated protocol CastWalkerRig: AnyObject {
    /// Metres of travel per half cycle.
    var stepLength: Float { get }
    /// How high the body sits on them (its model is set this far up).
    var bodyHeight: Float { get }
    func pose(phase: Float, amount: Float, bob: Float, reachScale: Float)
    func settle()
}

nonisolated final class CastLegRig: CastWalkerRig, @unchecked Sendable {
    struct Leg {
        let hip: SCNNode, knee: SCNNode, ankle: SCNNode
        let phase: Float
    }
    let legs: CastLegs
    let root: SCNNode
    private(set) var pairs: [Leg] = []

    /// Built under `parent` (the body's bobbing node; metres; front is -z).
    init(_ legs: CastLegs, parent: SCNNode) {
        self.legs = legs
        let g = HallwaysianGenome(name: "TelephoneLegs")                 // (the species' own palette: brass, rods, rubber)
        func material(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.5) -> SCNMaterial {   // (as HallwaysianBody.material)
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color
            m.metalness.contents = metal
            m.roughness.contents = rough
            return m
        }
        let trim = material(g.trim, metal: g.trimMetalness, rough: g.trimRoughness)
        let limb = material(g.limb, metal: 0.3, rough: 0.4)
        let rubber = material(UIColor(white: 0.08, alpha: 1), rough: 0.8)   // (black rubber, to the Bakelite)
        root = SCNNode()
        root.name = "castLegs"
        root.simdPosition = SIMD3(0, legs.hipHeight, 0)
        parent.addChildNode(root)
        func part(_ geo: SCNGeometry, _ m: SCNMaterial, _ p: SCNNode, _ at: SIMD3<Float> = .zero) -> SCNNode {
            geo.materials = [m]
            let n = SCNNode(geometry: geo)
            n.simdPosition = at
            p.addChildNode(n)
            return n
        }
        func pivot(_ p: SCNNode, _ at: SIMD3<Float>, _ name: String) -> SCNNode {
            let n = SCNNode()
            n.name = name
            n.simdPosition = at
            p.addChildNode(n)
            return n
        }
        for (i, side) in [Float(-1), 1].enumerated() {
            let hip = pivot(root, SIMD3(side * legs.hipSpread, 0, 0), side < 0 ? "telHipL" : "telHipR")
            _ = part(SCNSphere(radius: CGFloat(legs.jointRadius)), trim, hip)
            _ = part(SCNCylinder(radius: CGFloat(legs.legRadius), height: CGFloat(legs.thigh)), limb, hip, SIMD3(0, -legs.thigh / 2, 0))
            let knee = pivot(hip, SIMD3(0, -legs.thigh, 0), side < 0 ? "telKneeL" : "telKneeR")
            _ = part(SCNSphere(radius: CGFloat(legs.jointRadius * 0.8)), trim, knee)
            _ = part(SCNCone(topRadius: CGFloat(legs.legRadius), bottomRadius: CGFloat(legs.shinTip), height: CGFloat(legs.shin)),
                     limb, knee, SIMD3(0, -legs.shin / 2, 0))
            let ankle = pivot(knee, SIMD3(0, -legs.shin, 0), side < 0 ? "telAnkleL" : "telAnkleR")
            let foot = part(SCNSphere(radius: 1), rubber, ankle, SIMD3(0, -legs.footHeight * 0.45, -legs.footLength * 0.3))
            foot.simdScale = SIMD3(legs.footWidth / 2, legs.footHeight / 2 * 1.1, legs.footLength / 2)
            pairs.append(Leg(hip: hip, knee: knee, ankle: ankle, phase: i == 0 ? 0 : .pi))
        }
        settle()
    }

    /// Both legs at cycle `phase`, `amount` of a full step (0: standing); `bob`: how
    /// high the body is lifted now (the planted foot stays on the floor); `reachScale`
    /// 0: stepping in place (turning).
    func pose(phase: Float, amount: Float, bob: Float, reachScale: Float = 1) {
        let l = legs
        for leg in pairs {
            let o = CastFeet.offset(phase: phase + leg.phase, reach: l.reach * reachScale, lift: l.lift, duty: l.duty)
            let down = l.hipHeight + bob - l.ankleHeight - o.up * amount
            let a = CastLegs.solve(forward: o.forward * amount, down: down, thigh: l.thigh, shin: l.shin)
            leg.hip.eulerAngles = SCNVector3(a.hip, 0, 0)
            leg.knee.eulerAngles = SCNVector3(a.knee, 0, 0)
            leg.ankle.eulerAngles = SCNVector3(a.ankle, 0, 0)
        }
    }

    /// Standing, feet flat under the hips.
    func settle() { pose(phase: 0, amount: 0, bob: 0) }
    var stepLength: Float { legs.step }
    var bodyHeight: Float { legs.hipHeight + legs.jointRadius * 0.5 }
}


// MARK: - Oct 22 (evening): the Camera on a walking tripod

/// A vintage camera on three long tripod legs: a ball head under the body,
/// each leg an upper tube with a locking collar, a slimmer lower tube that
/// telescopes in and out of it, and a small rubber foot. Standing: a tripod
/// stance (two legs forward, one back). Walking: one leg at a time lifts -- its
/// lower tube sliding up into the upper -- swings forward and plants; the other
/// two stay planted. The legs only ever point at their feet and telescope to
/// reach them (no bending: a tripod has no knees).
nonisolated struct CastTripod: Sendable {
    /// Metres (in the world). The ball head's height above the floor.
    var mountHeight: Float = 0.82
    /// Hips round the ball head (radius), and feet round the centre on the floor.
    var hipRadius: Float = 0.05
    var footRadius: Float = 0.30
    /// Each leg's bearing from straight ahead (radians; resident front is -z): two forward, one back.
    var bearings: [Float] = [-1.05, 1.05, .pi]
    var upperLength: Float = 0.50
    var lowerLength: Float = 0.46
    var upperRadius: Float = 0.016
    var lowerRadius: Float = 0.0105
    var footRadiusBall: Float = 0.022
    /// The step: one leg at a time (each a third of the cycle apart), long on the ground.
    var step: Float = 0.16
    var duty: Float = 0.72
    var lift: Float = 0.07
    var reach: Float { duty * step }

    static let byMember: [String: CastTripod] = [
        "cast.camera": CastTripod(),
    ]
    /// The model parts the tripod replaces (hidden).
    static let replaces: [String: [String]] = [
        "cast.camera": ["foot", "foot_001"],
    ]
}

/// One body's tripod: built once, posed per frame (three orientations and
/// three slides -- no allocations).
nonisolated final class CastTripodRig: CastWalkerRig, @unchecked Sendable {
    struct Leg {
        let hip: SCNNode                 // points its -y at the foot
        let lower: SCNNode               // slides along -y (telescoping)
        let foot: SCNNode
        let hipAt: SIMD3<Float>          // in the mount's frame
        let rest: SIMD3<Float>           // the foot's place standing (mount frame; floor at -mountHeight)
        let phase: Float
    }
    let spec: CastTripod
    let mount: SCNNode
    private(set) var legs: [Leg] = []

    init(_ spec: CastTripod, parent: SCNNode) {
        self.spec = spec
        func material(_ color: UIColor, metal: CGFloat, rough: CGFloat) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color
            m.metalness.contents = metal
            m.roughness.contents = rough
            return m
        }
        let black = material(UIColor(white: 0.07, alpha: 1), metal: 0.5, rough: 0.35)      // (anodised tubes, the head)
        let alloy = material(UIColor(white: 0.72, alpha: 1), metal: 0.9, rough: 0.25)      // (the sliding lower tubes)
        let brass = material(UIColor(red: 0.78, green: 0.60, blue: 0.30, alpha: 1), metal: 0.6, rough: 0.3)   // (collars, as the Hallwaysians' joints)
        let rubber = material(UIColor(white: 0.06, alpha: 1), metal: 0, rough: 0.85)
        func part(_ g: SCNGeometry, _ m: SCNMaterial, _ p: SCNNode, _ at: SIMD3<Float> = .zero) -> SCNNode {
            g.materials = [m]
            let n = SCNNode(geometry: g)
            n.simdPosition = at
            p.addChildNode(n)
            return n
        }
        mount = SCNNode()
        mount.name = "castTripod"
        mount.simdPosition = SIMD3(0, spec.mountHeight, 0)
        parent.addChildNode(mount)
        // The ball head and its plate.
        _ = part(SCNCylinder(radius: 0.06, height: 0.018), black, mount, SIMD3(0, 0.012, 0))
        _ = part(SCNSphere(radius: 0.034), black, mount)
        let phases: [Float] = [0, 2 * .pi / 3, 4 * .pi / 3]
        for (i, b) in spec.bearings.enumerated() {
            let dir = SIMD3<Float>(sin(b), 0, -cos(b))                       // (bearing 0: straight ahead, -z)
            let hipAt = dir * spec.hipRadius - SIMD3(0, 0.02, 0)
            let hip = SCNNode()
            hip.name = "tripodLeg\(i)"
            hip.simdPosition = hipAt
            mount.addChildNode(hip)
            _ = part(SCNSphere(radius: CGFloat(spec.upperRadius * 1.5)), brass, hip)                 // (the hinge)
            _ = part(SCNCylinder(radius: CGFloat(spec.upperRadius), height: CGFloat(spec.upperLength)), black, hip,
                     SIMD3(0, -spec.upperLength / 2, 0))
            _ = part(SCNCylinder(radius: CGFloat(spec.upperRadius * 1.35), height: 0.03), brass, hip,
                     SIMD3(0, -spec.upperLength + 0.015, 0))                                     // (the locking collar)
            let lower = SCNNode()
            hip.addChildNode(lower)
            _ = part(SCNCylinder(radius: CGFloat(spec.lowerRadius), height: CGFloat(spec.lowerLength)), alloy, lower,
                     SIMD3(0, -spec.lowerLength / 2, 0))
            let foot = part(SCNSphere(radius: CGFloat(spec.footRadiusBall)), rubber, lower, SIMD3(0, -spec.lowerLength, 0))
            let rest = dir * spec.footRadius - SIMD3(0, spec.mountHeight - spec.footRadiusBall, 0)
            legs.append(Leg(hip: hip, lower: lower, foot: foot, hipAt: hipAt, rest: rest, phase: phases[i % 3]))
        }
        settle()
    }

    /// The legs at cycle `phase`, `amount` of a full step (0: standing); `bob`: how
    /// high the body is lifted now (planted feet stay on the floor); `reachScale` 0:
    /// stepping in place (turning).
    func pose(phase: Float, amount: Float, bob: Float, reachScale: Float = 1) {
        let s = spec
        for leg in legs {
            let o = CastFeet.offset(phase: phase + leg.phase, reach: s.reach * reachScale, lift: s.lift, duty: s.duty)
            // The foot's target in the mount's frame: forward is -z; the floor drops by `bob`.
            let target = leg.rest + SIMD3(0, o.up * amount - bob, -o.forward * amount)
            let v = target - leg.hipAt
            let length = simd_length(v)
            guard length > 0.01 else { continue }
            // Point the leg's -y along v, then slide the lower tube so the foot lands on it.
            leg.hip.simdOrientation = simd_quatf(from: SIMD3(0, -1, 0), to: v / length)
            let lowerTop = min(s.upperLength - 0.02, max(0.08, length - s.lowerLength))
            leg.lower.simdPosition = SIMD3(0, -lowerTop, 0)
        }
    }

    /// Standing in its tripod stance.
    func settle() { pose(phase: 0, amount: 0, bob: 0) }
    var stepLength: Float { spec.step }
    var bodyHeight: Float { spec.mountHeight + 0.02 }
}
