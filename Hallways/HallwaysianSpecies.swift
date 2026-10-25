//
//  HallwaysianSpecies.swift
//  Hallways
//
//  Oct 19 -- THE HALLWAYSIANS: one species, many people. Every Hallwaysian is
//  the same simple construction --
//
//    an ellipsoid head on a short rod neck, an ellipsoid body,
//    pencil-thin arms and legs with ball joints (brass), three-fingered hands,
//    small rubber feet, two big dimensional eyes under enamel lids,
//    a bent-wire mouth, and (optionally) a round gauge on the belly whose
//    needle is his mood
//
//  Oct 19 (the six): optional FEATURES -- hair, a moustache, brows, a skirt --
//  are data, not code: hair and moustaches are lists of ellipsoid pieces in
//  HEAD UNITS (so one style fits any head), brows sit on the eyes, a skirt is a
//  pleated cone from the waist. Finishes (metal, roughness) are per genome.
//  The chest gauge is gone (gaugeRadius 0 by default, the audition's Feddy
//  too). The six residents' genomes: HallwaysianResidents.swift.
//
//  -- built from SceneKit primitives at runtime from a HallwaysianGenome, so a
//  sister, an old fellow, a fat one or a child is a new genome, not a new
//  model. HallwaysianBody owns the node tree and turns a HallwaysianPose
//  (HallwaysianMotion.swift) into joint angles every frame.
//
//  The face is part of the head: the eyes are half sunk into it, the lids are
//  shells of the head's own enamel (they close over the eye, slant for
//  worry or temper, and the lower ones rise for a smile), and the mouth is one
//  dark wire that bends -- smile, frown, a wavy doubt -- or rounds into an "o".
//
//  Frame (SceneKit): Y up, metres, facing -Z at yaw 0; his right is +X.
//  Design sketchpad: the same construction in Blender (renders in the report).
//

import Foundation
import SceneKit
import UIKit
import simd

// MARK: - Genome

/// Everything that makes one Hallwaysian look and move like himself.
nonisolated struct HallwaysianGenome {
    var name: String
    // head: a wide egg, set forward of the body on a short neck
    var headRadii = SIMD3<Float>(0.19, 0.145, 0.16)
    var headForward: Float = 0.02
    var neckLength: Float = 0.11
    var neckRadius: Float = 0.015
    /// The neck's forward lean (radians): his peering posture.
    var neckLean: Float = 0.30
    // body
    var torsoRadii = SIMD3<Float>(0.13, 0.15, 0.115)
    var torsoLean: Float = 0.04
    /// The round gauge on the belly (0 = none) and its height above the body's centre.
    /// (Oct 19: none by default -- the species has no chest gauge now.)
    var gaugeRadius: Float = 0
    var gaugeHeight: Float = 0.01
    // legs (pencil-thin)
    var hipWidth: Float = 0.06
    var thigh: Float = 0.17
    var shin: Float = 0.175
    var legRadius: Float = 0.0105
    var shinTip: Float = 0.0075
    var footLength: Float = 0.12
    var footWidth: Float = 0.05
    var footHeight: Float = 0.04
    // arms
    var shoulderWidth: Float = 0.125
    var shoulderDrop: Float = 0.06
    var upperArm: Float = 0.15
    var forearm: Float = 0.145
    var armRadius: Float = 0.0085
    var handRadius: Float = 0.021
    var fingerLength: Float = 0.042
    var fingerRadius: Float = 0.0055
    /// The brass ball at shoulder, hip (elbow and knee a little smaller).
    var jointRadius: Float = 0.017
    // face
    var eyeRadius: Float = 0.064
    /// Centre to centre, halved.
    var eyeSpacing: Float = 0.072
    /// Above the head's centre.
    var eyeHeight: Float = 0.06
    /// How much of each eye is inside the head (0..1 of its radius).
    var eyeSink: Float = 0.35
    /// The eyes splay outward a little (radians).
    var eyeToe: Float = 0.14
    var pupilSize: Float = 0.47
    var mouthWidth: Float = 0.075
    var mouthHeight: Float = -0.05
    var mouthWire: Float = 0.0042
    // gait
    /// One full stride (two steps), metres; and strides per second at a full walk.
    var stride: Float = 0.36
    var cadence: Float = 1.9
    // materials (sRGB)
    var enamel = UIColor(red: 0.42, green: 0.62, blue: 0.58, alpha: 1)
    var enamelRoughness: CGFloat = 0.42
    /// Oct 19: the paint's finish -- 0 enamel .. ~0.4 a brushed, metallic coat.
    var enamelMetalness: CGFloat = 0
    var trim = UIColor(red: 0.78, green: 0.60, blue: 0.30, alpha: 1)        // brass
    var trimMetalness: CGFloat = 0.45
    var trimRoughness: CGFloat = 0.32
    var limb = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)        // rods
    var rubber = UIColor(red: 0.36, green: 0.13, blue: 0.11, alpha: 1)      // feet
    var wire = UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)        // the mouth
    var dial = UIColor(red: 0.93, green: 0.89, blue: 0.78, alpha: 1)
    // Oct 19: optional features (all off by default)
    /// Hair: ellipsoid pieces around the head's centre, in head units (HallwaysianStyle).
    var hair: [HallwaysianPiece] = []
    var hairColor = UIColor(red: 0.2, green: 0.14, blue: 0.1, alpha: 1)
    var hairRoughness: CGFloat = 0.8
    /// A moustache: pieces placed on the face's front surface (HallwaysianStyle).
    var moustache: [HallwaysianPiece] = []
    /// nil: the hair's colour.
    var moustacheColor: UIColor?
    /// Brows: one bar over each eye, riding on the eye (nil: none).
    var brows: HallwaysianBrows?
    var browColor: UIColor?
    /// A pleated skirt hung from the waist (nil: none).
    var skirt: HallwaysianSkirt?
    var skirtColor = UIColor(red: 0.42, green: 0.25, blue: 0.43, alpha: 1)
    var skirtRoughness: CGFloat = 0.8
    /// Oct 19 (the five newcomers): extra shell pieces on the body -- a pear's
    /// low bulge, a shoulder yoke, barrel hoops -- in TORSO units around the
    /// body shell's centre (x: the torso's width radius, y: height, z: depth).
    var torsoPieces: [HallwaysianPiece] = []
    /// nil: the enamel.
    var torsoPieceColor: UIColor?
    /// Oct 19 (Lopsy): a lopsided build -- the LEFT shoulder this much higher
    /// than the right (metres, split between them; 0: level).
    var shoulderTilt: Float = 0
    /// Oct 19 (Lopsy): the LEFT eye this much bigger, the right this much smaller
    /// (a fraction of eyeRadius; 0: a matched pair).
    var eyeSkew: Float = 0
    /// One eye's radius (`side` -1 left, +1 right).
    func eyeRadiusFor(side: Float) -> Float { eyeRadius * (1 - side * eyeSkew) }

    /// Pelvis height standing (legs all but straight, feet flat).
    var hipHeight: Float { (thigh + shin) * 0.996 + footHeight }
    /// Roughly where his eyes are, standing (for gaze).
    var eyeLevel: Float { hipHeight + 0.02 + torsoRadii.y * 1.84 + neckLength + headRadii.y * 0.78 + eyeHeight }
    /// The top of his head, standing.
    var height: Float { hipHeight + 0.02 + torsoRadii.y * 1.84 + neckLength + headRadii.y * 1.78 }

    /// FEDDY -- the first Hallwaysian: a technician/programmer. Curious, capable,
    /// a little eccentric: a big head pushed forward to peer at things, big
    /// eyes, long thin arms, a needle that jumps when something interests him.
    static var feddy: HallwaysianGenome { HallwaysianGenome(name: "Feddy") }
}

// MARK: - Features (Oct 19)

/// One ellipsoid of a feature, in HEAD units (x: head width radius, y: height, z: depth).
/// Hair: `centre` is around the head's centre (x right, y up, +z BEHIND the face).
/// Moustache: `centre.x`, `centre.y` are on the face's front surface; `centre.z` is how far out.
nonisolated struct HallwaysianPiece: Sendable, Equatable {
    var centre: SIMD3<Float>
    var radii: SIMD3<Float>
    var euler: SIMD3<Float> = .zero
    init(_ centre: SIMD3<Float>, _ radii: SIMD3<Float>, _ euler: SIMD3<Float> = .zero) {
        self.centre = centre; self.radii = radii; self.euler = euler
    }
}

/// Brows: in eye-radius units, on each eye's socket (so they follow the eye).
nonisolated struct HallwaysianBrows: Sendable, Equatable {
    var length: Float = 0.8
    var thickness: Float = 0.2
    var lift: Float = 1.12
    var shift: Float = 0.1
    /// Outer ends down (+) -- kindly, or tired.
    var tilt: Float = 0.15
}

/// A skirt: a pleated cone from the waist.
nonisolated struct HallwaysianSkirt: Sendable, Equatable {
    /// How far below the torso's centre it starts (x the torso's height radius).
    var waist: Float = 0.35
    var length: Float = 0.16
    var flare: Float = 1.6
    var pleats: Int = 14
}

/// The shared styles (the Blender sketchpad's STYLES, one for one).
nonisolated enum HallwaysianStyle {
    private typealias P = HallwaysianPiece
    /// A rounded bob: one shell set back and up so the face shows, two side drops.
    static let bob: [HallwaysianPiece] = [
        P(SIMD3(0, 0.12, 0.2), SIMD3(1.1, 1.0, 1.0)),
        P(SIMD3(-0.86, -0.25, 0.25), SIMD3(0.3, 0.55, 0.6), SIMD3(0, 0, 0.12)),
        P(SIMD3(0.86, -0.25, 0.25), SIMD3(0.3, 0.55, 0.6), SIMD3(0, 0, -0.12)),
    ]
    /// The bob with a bun on top.
    static let bobBun: [HallwaysianPiece] = bob + [P(SIMD3(0, 1.12, 0.38), SIMD3(0.36, 0.36, 0.36))]
    /// Bald on top: puffs over the ears and round the back.
    static let fringe: [HallwaysianPiece] = [
        P(SIMD3(-0.93, -0.02, 0.32), SIMD3(0.15, 0.26, 0.42), SIMD3(0, 0, 0.2)),
        P(SIMD3(0.93, -0.02, 0.32), SIMD3(0.15, 0.26, 0.42), SIMD3(0, 0, -0.2)),
        P(SIMD3(0, 0.0, 0.9), SIMD3(0.62, 0.26, 0.16)),
    ]
    /// Strands combed over the crown: thin slices of a head-sized egg (only the crown pokes through).
    static let combover: [HallwaysianPiece] = [Float(-0.28), 0, 0.28].map {
        P(SIMD3($0, 0.3, 0.15), SIMD3(0.09, 0.76, 0.9), SIMD3(0, 0, 0.12))
    }
    /// Short, slicked back.
    static let slick: [HallwaysianPiece] = [P(SIMD3(0, 0.32, 0.24), SIMD3(1.05, 0.8, 0.92))]
    /// One sprouting curl.
    static let sprout: [HallwaysianPiece] = [
        P(SIMD3(0.05, 1.08, 0), SIMD3(0.07, 0.28, 0.07), SIMD3(0, 0, -0.3)),
        P(SIMD3(0.17, 1.33, 0), SIMD3(0.13, 0.13, 0.13)),
    ]
    /// Moustaches.
    static let walrus: [HallwaysianPiece] = [
        P(SIMD3(-0.2, -0.2, 0.05), SIMD3(0.3, 0.16, 0.16), SIMD3(0, 0, 0.35)),
        P(SIMD3(0.2, -0.2, 0.05), SIMD3(0.3, 0.16, 0.16), SIMD3(0, 0, -0.35)),
        P(SIMD3(0, -0.15, 0.08), SIMD3(0.16, 0.12, 0.14)),
    ]
    /// Oct 19: a short crew cut (Mitts).
    static let crew: [HallwaysianPiece] = [P(SIMD3(0, 0.4, 0.1), SIMD3(1.03, 0.72, 0.98))]
    static let handlebar: [HallwaysianPiece] = [
        P(SIMD3(-0.17, -0.18, 0.03), SIMD3(0.22, 0.07, 0.08), SIMD3(0, 0, -0.15)),
        P(SIMD3(0.17, -0.18, 0.03), SIMD3(0.22, 0.07, 0.08), SIMD3(0, 0, 0.15)),
        P(SIMD3(-0.38, -0.1, 0.02), SIMD3(0.07, 0.07, 0.07)),
        P(SIMD3(0.38, -0.1, 0.02), SIMD3(0.07, 0.07, 0.07)),
    ]
}

// MARK: - Body

/// The node tree of one Hallwaysian, and the joints a pose drives.
final class HallwaysianBody {
    let genome: HallwaysianGenome
    let root = SCNNode()
    private let pelvis = SCNNode(), torso = SCNNode(), neck = SCNNode(), head = SCNNode(), face = SCNNode()
    private(set) var needle: SCNNode?
    private struct Eye { let side: Float; let ball: SCNNode; let pupil: SCNNode; let upper: SCNNode; let lower: SCNNode }
    private var eyes: [Eye] = []
    private struct Arm { let side: Float; let shoulder, elbow, wrist: SCNNode; let fingers: [SCNNode] }
    private var arms: [Arm] = []
    private struct Leg { let side: Float; let hip, knee, ankle: SCNNode }
    private var legs: [Leg] = []
    private var mouthBeads: [SCNNode] = []
    private var mouthRods: [SCNNode] = []
    private static let mouthPoints = 9

    /// The head node (for cameras that want to frame his face).
    var headNode: SCNNode { head }

    init(genome g: HallwaysianGenome) {
        genome = g
        root.name = "hallwaysian_\(g.name)"
        let enamel = Self.material(g.enamel, metal: g.enamelMetalness, rough: g.enamelRoughness)
        let lidEnamel = Self.material(g.enamel, metal: g.enamelMetalness, rough: g.enamelRoughness)
        lidEnamel.isDoubleSided = true
        let trim = Self.material(g.trim, metal: g.trimMetalness, rough: g.trimRoughness)
        let limb = Self.material(g.limb, metal: 0.3, rough: 0.4)
        let rubber = Self.material(g.rubber, rough: 0.8)
        let wire = Self.material(g.wire, metal: 0.2, rough: 0.45)
        let dial = Self.material(g.dial, rough: 0.5)
        let white = Self.material(UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1), rough: 0.18)
        white.emission.contents = UIColor(white: 0.18, alpha: 1)               // (as Mr. Tinky's: the whites never go grey)
        let pupilMat = Self.material(.black, rough: 0.12)
        let shine = SCNMaterial()
        shine.lightingModel = .constant
        shine.diffuse.contents = UIColor.white

        let tr = g.torsoRadii, hr = g.headRadii
        // Contact shadow (the building's lights cast none), as the other characters have.
        root.addChildNode(Self.contactShadow(width: CGFloat(tr.x * 3.2), depth: CGFloat(tr.z * 3.6)))
        pelvis.name = "hwPelvis"
        pelvis.position = SCNVector3(0, g.hipHeight, 0)
        root.addChildNode(pelvis)
        // body
        torso.name = "hwTorso"
        torso.position = SCNVector3(0, 0.02, 0)
        pelvis.addChildNode(torso)
        let tc = SIMD3<Float>(0, tr.y * 0.92, 0)
        let shell = Self.part(SCNSphere(radius: 1), enamel, torso, tc)
        (shell.geometry as? SCNSphere)?.segmentCount = 48
        shell.simdScale = tr
        let topY = tc.y + tr.y
        if !g.torsoPieces.isEmpty {
            // Oct 19: the body's extra pieces (a bulge, a yoke, hoops), riding with the torso.
            let m = g.torsoPieceColor.map { Self.material($0, metal: g.trimMetalness, rough: g.trimRoughness) } ?? enamel
            let node = Self.pivot(torso, .zero, "hwTorsoPieces")
            for piece in g.torsoPieces {
                let n = Self.part(SCNSphere(radius: 1), m, node, tc + piece.centre * tr, piece.euler)
                (n.geometry as? SCNSphere)?.segmentCount = 40
                n.simdScale = piece.radii * tr
            }
        }
        if g.gaugeRadius > 0 {
            let gr = g.gaugeRadius, yy = g.gaugeHeight
            let zz = -tr.z * (max(0, 1 - (yy / tr.y) * (yy / tr.y))).squareRoot()
            let gauge = Self.pivot(torso, SIMD3(0, tc.y + yy, zz + 0.004), "hwGauge")
            gauge.eulerAngles.x = atan2(yy / (tr.y * tr.y), -zz / (tr.z * tr.z))   // along the surface normal
            Self.part(SCNTorus(ringRadius: CGFloat(gr), pipeRadius: CGFloat(gr * 0.16)), trim, gauge, .zero, SIMD3(.pi / 2, 0, 0))
            Self.part(SCNCylinder(radius: CGFloat(gr * 0.98), height: 0.006), dial, gauge, .zero, SIMD3(.pi / 2, 0, 0))
            let n = Self.pivot(gauge, SIMD3(0, -gr * 0.35, -0.0045), "hwNeedle")
            Self.part(SCNBox(width: 0.0035, height: CGFloat(gr * 1.05), length: 0.0015, chamferRadius: 0), wire, n, SIMD3(0, gr * 0.52, 0))
            Self.part(SCNSphere(radius: CGFloat(gr * 0.11)), trim, n)
            needle = n
        }
        // neck: leans forward out of the top of the body
        neck.name = "hwNeck"
        neck.simdPosition = SIMD3(0, topY - 0.012, -tr.z * 0.12)
        torso.addChildNode(neck)
        Self.part(SCNCylinder(radius: CGFloat(g.neckRadius), height: CGFloat(g.neckLength)), limb, neck, SIMD3(0, g.neckLength / 2, 0))
        Self.part(SCNSphere(radius: CGFloat(g.neckRadius * 1.7)), trim, neck)
        // head
        head.name = "hwHead"
        head.simdPosition = SIMD3(0, g.neckLength, 0)
        neck.addChildNode(head)
        let headCentre = SIMD3<Float>(0, hr.y * 0.78, -g.headForward)
        let skull = Self.part(SCNSphere(radius: 1), enamel, head, headCentre)
        (skull.geometry as? SCNSphere)?.segmentCount = 48
        skull.simdScale = hr
        Self.part(SCNSphere(radius: CGFloat(g.neckRadius * 1.5)), trim, head)
        face.name = "hwFace"
        face.simdPosition = headCentre
        head.addChildNode(face)
        // eyes: half sunk into the head, splayed a little; enamel lids
        var eyeSockets: [(Float, SCNNode)] = []
        for side in [Float(-1), 1] {
            let r = g.eyeRadiusFor(side: side)                                      // (Oct 19: a matched pair unless eyeSkew)
            let (p, _) = surface(side * g.eyeSpacing, g.eyeHeight, out: 0)
            let centre = p + SIMD3<Float>(0, 0, -1) * (r * (1 - 2 * g.eyeSink))
            let socket = Self.pivot(face, centre, side < 0 ? "hwEyeL" : "hwEyeR")
            socket.eulerAngles.y = -side * g.eyeToe
            eyeSockets.append((side, socket))
            let ball = Self.pivot(socket, .zero, side < 0 ? "hwEyeballL" : "hwEyeballR")
            let eyeball = Self.part(SCNSphere(radius: CGFloat(r)), white, ball)
            (eyeball.geometry as? SCNSphere)?.segmentCount = 40
            let pupil = Self.pivot(ball, SIMD3(0, 0, -r * 0.76), side < 0 ? "hwPupilL" : "hwPupilR")
            let dot = Self.part(SCNSphere(radius: CGFloat(r * g.pupilSize)), pupilMat, pupil)
            (dot.geometry as? SCNSphere)?.segmentCount = 28
            Self.part(SCNSphere(radius: CGFloat(r * 0.11)), shine, ball, SIMD3(r * 0.17, r * 0.2, -r * 1.2))
            let upper = Self.pivot(socket, .zero, side < 0 ? "hwLidUpperL" : "hwLidUpperR")
            Self.part(HallwaysianMesh.cap(radius: r * 1.07, from: 0, to: .pi / 2), lidEnamel, upper)
            let lower = Self.pivot(socket, .zero, side < 0 ? "hwLidLowerL" : "hwLidLowerR")
            Self.part(HallwaysianMesh.cap(radius: r * 1.06, from: .pi / 2, to: .pi), lidEnamel, lower)
            eyes.append(Eye(side: side, ball: ball, pupil: pupil, upper: upper, lower: lower))
        }
        // the wire mouth: rods between points, a bead at every point (no seams)
        let mouth = Self.pivot(face, .zero, "hwMouth")
        for _ in 0..<Self.mouthPoints {
            mouthBeads.append(Self.part(SCNSphere(radius: CGFloat(g.mouthWire)), wire, mouth))
        }
        for _ in 0..<(Self.mouthPoints - 1) {
            let rod = SCNCylinder(radius: CGFloat(g.mouthWire), height: 1)
            rod.radialSegmentCount = 12
            mouthRods.append(Self.part(rod, wire, mouth))
        }
        buildFeatures(eyeSockets: eyeSockets)
        // arms
        for side in [Float(-1), 1] {
            let tilt = -side * g.shoulderTilt / 2                                 // (Oct 19: level unless shoulderTilt)
            let sh = Self.pivot(torso, SIMD3(side * g.shoulderWidth, topY - g.shoulderDrop + tilt, -0.02), side < 0 ? "hwShoulderL" : "hwShoulderR")
            Self.part(SCNSphere(radius: CGFloat(g.jointRadius)), trim, sh)
            Self.part(SCNCylinder(radius: CGFloat(g.armRadius), height: CGFloat(g.upperArm)), limb, sh, SIMD3(0, -g.upperArm / 2, 0))
            let el = Self.pivot(sh, SIMD3(0, -g.upperArm, 0), side < 0 ? "hwElbowL" : "hwElbowR")
            Self.part(SCNSphere(radius: CGFloat(g.jointRadius * 0.72)), trim, el)
            Self.part(SCNCone(topRadius: CGFloat(g.armRadius), bottomRadius: CGFloat(g.armRadius * 0.8), height: CGFloat(g.forearm)),
                      limb, el, SIMD3(0, -g.forearm / 2, 0))
            let wr = Self.pivot(el, SIMD3(0, -g.forearm, 0), side < 0 ? "hwWristL" : "hwWristR")
            let hr_ = g.handRadius
            Self.part(SCNSphere(radius: CGFloat(hr_)), trim, wr, SIMD3(0, -hr_ * 0.7, 0))
            var fingers: [SCNNode] = []
            // index and middle at the front, a thumb behind
            for (k, at) in [SIMD2<Float>(0.45, -0.55), SIMD2(-0.45, -0.55), SIMD2(0, 0.62)].enumerated() {
                let f = Self.pivot(wr, SIMD3(side * at.x * hr_, -hr_ * 1.2, at.y * hr_), "hwFinger\(k)")
                let len = g.fingerLength * (k == 2 ? 0.8 : 1)
                Self.part(SCNCapsule(capRadius: CGFloat(g.fingerRadius), height: CGFloat(len)), limb, f, SIMD3(0, -len / 2, 0))
                fingers.append(f)
            }
            arms.append(Arm(side: side, shoulder: sh, elbow: el, wrist: wr, fingers: fingers))
        }
        // legs
        for side in [Float(-1), 1] {
            let hip = Self.pivot(pelvis, SIMD3(side * g.hipWidth, 0, 0), side < 0 ? "hwHipL" : "hwHipR")
            Self.part(SCNSphere(radius: CGFloat(g.jointRadius)), trim, hip)
            Self.part(SCNCylinder(radius: CGFloat(g.legRadius), height: CGFloat(g.thigh)), limb, hip, SIMD3(0, -g.thigh / 2, 0))
            let knee = Self.pivot(hip, SIMD3(0, -g.thigh, 0), side < 0 ? "hwKneeL" : "hwKneeR")
            Self.part(SCNSphere(radius: CGFloat(g.jointRadius * 0.8)), trim, knee)
            Self.part(SCNCone(topRadius: CGFloat(g.legRadius), bottomRadius: CGFloat(g.shinTip), height: CGFloat(g.shin)),
                      limb, knee, SIMD3(0, -g.shin / 2, 0))
            let ankle = Self.pivot(knee, SIMD3(0, -g.shin, 0), side < 0 ? "hwAnkleL" : "hwAnkleR")
            let foot = Self.part(SCNSphere(radius: 1), rubber, ankle, SIMD3(0, -g.footHeight * 0.45, -g.footLength * 0.36))
            foot.simdScale = SIMD3(g.footWidth / 2, g.footHeight / 2 * 1.1, g.footLength / 2)
            legs.append(Leg(side: side, hip: hip, knee: knee, ankle: ankle))
        }
        apply(.rest)
    }

    // MARK: Features (Oct 19)

    /// Hair, moustache, brows, skirt -- whichever the genome asks for, all from data.
    private func buildFeatures(eyeSockets: [(Float, SCNNode)]) {
        let g = genome, hr = g.headRadii
        let hairMat = Self.material(g.hairColor, rough: g.hairRoughness)
        if !g.hair.isEmpty {
            let hairNode = Self.pivot(face, .zero, "hwHair")
            for piece in g.hair {
                let n = Self.part(SCNSphere(radius: 1), hairMat, hairNode, piece.centre * hr, piece.euler)
                (n.geometry as? SCNSphere)?.segmentCount = 32
                n.simdScale = piece.radii * hr
            }
        }
        if !g.moustache.isEmpty {
            let m = g.moustacheColor.map { Self.material($0, rough: 0.85) } ?? hairMat
            let node = Self.pivot(face, .zero, "hwMoustache")
            for piece in g.moustache {
                let (p, _) = surface(piece.centre.x * hr.x, piece.centre.y * hr.y, out: piece.centre.z * hr.z)
                let n = Self.part(SCNSphere(radius: 1), m, node, p, piece.euler)
                (n.geometry as? SCNSphere)?.segmentCount = 24
                n.simdScale = piece.radii * hr
            }
        }
        if let b = g.brows {
            let m = (g.browColor ?? g.moustacheColor).map { Self.material($0, rough: 0.85) } ?? hairMat
            for (side, socket) in eyeSockets {
                let r = g.eyeRadiusFor(side: side)
                let n = Self.part(SCNSphere(radius: 1), m, socket, SIMD3(side * r * b.shift, r * b.lift, -r * 0.35),
                                  SIMD3(0, 0, -side * b.tilt))
                n.name = side < 0 ? "hwBrowL" : "hwBrowR"
                n.simdScale = SIMD3(r * b.length, r * b.thickness, r * 0.32)
            }
        }
        if let k = g.skirt {
            let tr = g.torsoRadii
            let w = max(0, min(0.95, k.waist))
            let top = tr.x * (1 - w * w).squareRoot() * 1.02
            let m = Self.material(g.skirtColor, rough: g.skirtRoughness)
            m.isDoubleSided = true
            let n = Self.part(HallwaysianMesh.pleatedSkirt(top: top, bottom: top * k.flare, height: k.length, pleats: max(6, k.pleats)),
                              m, torso, SIMD3(0, tr.y * 0.92 - tr.y * w - k.length / 2, 0))
            n.name = "hwSkirt"
            n.simdScale = SIMD3(1, 1, tr.z / tr.x)
        }
    }

    // MARK: Pose

    /// Every joint from one pose (absolute; radians and metres).
    func apply(_ p: HallwaysianPose) {
        let g = genome
        root.simdPosition = SIMD3(p[.x], 0, p[.z])
        root.eulerAngles = SCNVector3(0, p[.yaw], 0)
        pelvis.simdPosition = SIMD3(0, g.hipHeight + p[.bob], 0)
        pelvis.eulerAngles = SCNVector3(0, p[.hipYaw], p[.hipRoll])
        torso.eulerAngles = SCNVector3(g.torsoLean + p[.lean], p[.twist], p[.sway])
        torso.simdScale = SIMD3(1 + p[.breath] * 0.5, 1 + p[.breath], 1 + p[.breath] * 0.5)
        neck.eulerAngles = SCNVector3(-g.neckLean + p[.neckPitch], p[.neckYaw], 0)
        head.eulerAngles = SCNVector3(g.neckLean - g.torsoLean + p[.headPitch], p[.headYaw], p[.headRoll])
        for e in eyes {
            let left = e.side < 0
            e.ball.eulerAngles = SCNVector3(p[.lookY] + p[left ? .lookLY : .lookRY], p[.lookX] + p[left ? .lookLX : .lookRX], 0)
            let lid = p[.lid] + p[left ? .lidL : .lidR]
            let low = p[.low] + p[left ? .lowL : .lowR]
            let tilt = p[.lidTilt] * -e.side
            e.upper.eulerAngles = SCNVector3(1.0 - lid * (.pi / 2 + 1.0), 0, tilt)
            e.lower.eulerAngles = SCNVector3(-0.75 + low * 0.95, 0, -tilt * 0.4)
            let pupil = max(0.4, p[.pupil])
            e.pupil.simdScale = SIMD3(repeating: pupil)
        }
        setMouth(curve: p[.smile], width: p[.mouthW], round: p[.mouthO])
        needle?.eulerAngles = SCNVector3(0, 0, -max(-1.2, min(1.2, p[.needle])) * 1.1)
        for a in arms {
            let left = a.side < 0
            a.shoulder.eulerAngles = SCNVector3(p[left ? .shPitchL : .shPitchR], a.side * p[left ? .shYawL : .shYawR],
                                                a.side * p[left ? .shRollL : .shRollR])
            a.elbow.eulerAngles = SCNVector3(p[left ? .elbowL : .elbowR], 0, 0)
            a.wrist.eulerAngles = SCNVector3(p[left ? .wrPitchL : .wrPitchR], a.side * p[left ? .wrTwistL : .wrTwistR], 0)
            let curl = p[left ? .curlL : .curlR], thumb = p[left ? .thumbL : .thumbR], point = p[left ? .pointL : .pointR]
            a.fingers[0].eulerAngles = SCNVector3(-curl * (1 - point), 0, 0)
            a.fingers[1].eulerAngles = SCNVector3(-curl, 0, 0)
            a.fingers[2].eulerAngles = SCNVector3(thumb, 0, 0)
        }
        for l in legs {
            let left = l.side < 0
            l.hip.eulerAngles = SCNVector3(p[left ? .hipPitchL : .hipPitchR], l.side * p[left ? .legYawL : .legYawR],
                                           l.side * p[left ? .legRollL : .legRollR])
            l.knee.eulerAngles = SCNVector3(p[left ? .kneeL : .kneeR], 0, 0)
            l.ankle.eulerAngles = SCNVector3(p[left ? .ankleL : .ankleR], 0, 0)
        }
    }

    // MARK: Face helpers

    /// A point on the head's front surface (head-centre frame), pushed out along the normal.
    func surface(_ x: Float, _ y: Float, out: Float) -> (SIMD3<Float>, SIMD3<Float>) {
        let a = genome.headRadii.x, b = genome.headRadii.y, c = genome.headRadii.z
        let q = 1 - (x / a) * (x / a) - (y / b) * (y / b)
        let z = -c * max(0, q).squareRoot()
        let n = simd_normalize(SIMD3(x / (a * a), y / (b * b), z / (c * c)))
        return (SIMD3(x, y, z) + n * out, n)
    }

    /// The mouth's points: `curve` + smile / - frown, `width` (x mouthWidth), `round` 0 a line .. 1 an "o".
    func mouthPoints(curve: Float, width: Float, round: Float) -> [SIMD3<Float>] {
        let g = genome
        let n = Self.mouthPoints
        let hw = g.mouthWidth * max(0.2, width) / 2
        let o = max(0, min(1, round))
        return (0..<n).map { i in
            let u = Float(i) / Float(n - 1) * 2 - 1
            let line = SIMD2<Float>(u * hw, g.mouthHeight + curve * hw * 0.55 * (u * u - 0.35))
            let ang = Float.pi / 2 + u * .pi                      // an "o", starting and ending at the bottom
            let ro = g.mouthWidth * 0.24
            let circ = SIMD2<Float>(cos(ang) * ro, g.mouthHeight - ro * 0.15 + sin(ang) * ro * 1.15)
            let q = line + (circ - line) * o
            return surface(q.x, q.y, out: g.mouthWire * 0.6).0
        }
    }

    private func setMouth(curve: Float, width: Float, round: Float) {
        let pts = mouthPoints(curve: curve, width: width, round: round)
        for (i, b) in mouthBeads.enumerated() { b.simdPosition = pts[i] }
        for (i, rod) in mouthRods.enumerated() {
            let a = pts[i], b = pts[i + 1]
            let d = b - a
            let len = simd_length(d)
            rod.simdPosition = (a + b) / 2
            if len > 1e-5 { rod.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: d / len) }
            rod.simdScale = SIMD3(1, max(len, 1e-4), 1)
        }
    }

    // MARK: Building helpers

    static func material(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.5) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        return m
    }

    @discardableResult
    private static func part(_ geometry: SCNGeometry, _ material: SCNMaterial, _ parent: SCNNode,
                             _ at: SIMD3<Float> = .zero, _ euler: SIMD3<Float> = .zero) -> SCNNode {
        geometry.materials = [material]
        let n = SCNNode(geometry: geometry)
        n.simdPosition = at
        n.simdEulerAngles = euler
        parent.addChildNode(n)
        return n
    }

    @discardableResult
    private static func pivot(_ parent: SCNNode, _ at: SIMD3<Float>, _ name: String) -> SCNNode {
        let n = SCNNode()
        n.name = name
        n.simdPosition = at
        parent.addChildNode(n)
        return n
    }

    private static func contactShadow(width: CGFloat, depth: CGFloat) -> SCNNode {
        let size = CGSize(width: 64, height: 64)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(white: 0, alpha: 0.42).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            context.cgContext.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: size.width / 2, options: [])
        }
        let plane = SCNPlane(width: width, height: depth)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let n = SCNNode(geometry: plane)
        n.name = "hwContactShadow"
        n.eulerAngles.x = -.pi / 2
        n.position.y = 0.004
        n.renderingOrder = 1
        return n
    }
}

// MARK: - Mesh

nonisolated enum HallwaysianMesh {
    /// Oct 19: an open, pleated frustum (flat-shaded sides: each pleat catches
    /// the light on its own), centred on its height, axis Y.
    static func pleatedSkirt(top: Float, bottom: Float, height: Float, pleats: Int) -> SCNGeometry {
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [UInt16] = []
        let h = height / 2
        for k in 0..<pleats {
            let a0 = 2 * Float.pi * Float(k) / Float(pleats), a1 = 2 * Float.pi * Float(k + 1) / Float(pleats)
            let p = [SIMD3<Float>(cos(a0) * top, h, sin(a0) * top), SIMD3<Float>(cos(a1) * top, h, sin(a1) * top),
                     SIMD3<Float>(cos(a1) * bottom, -h, sin(a1) * bottom), SIMD3<Float>(cos(a0) * bottom, -h, sin(a0) * bottom)]
            var n = simd_cross(p[1] - p[0], p[3] - p[0])
            let mid = (p[0] + p[2]) / 2
            if simd_dot(n, SIMD3(mid.x, 0, mid.z)) < 0 { n = -n }          // (outward)
            n = simd_normalize(n)
            let base = UInt16(vertices.count)
            for q in p { vertices.append(SCNVector3(q.x, q.y, q.z)); normals.append(SCNVector3(n.x, n.y, n.z)) }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                           elements: [element])
    }

    /// A spherical shell between two polar angles (radians from +Y) -- the eyelids.
    static func cap(radius: Float, from t0: Float, to t1: Float, segments: Int = 40) -> SCNGeometry {
        let rings = max(4, segments / 3)
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        for j in 0...rings {
            let t = t0 + (t1 - t0) * Float(j) / Float(rings)
            for k in 0...segments {
                let a = 2 * Float.pi * Float(k) / Float(segments)
                let n = SIMD3<Float>(sin(t) * cos(a), cos(t), sin(t) * sin(a))
                vertices.append(SCNVector3(n.x * radius, n.y * radius, n.z * radius))
                normals.append(SCNVector3(n.x, n.y, n.z))
            }
        }
        var indices: [UInt16] = []
        let row = segments + 1
        for j in 0..<rings {
            for k in 0..<segments {
                let a = UInt16(j * row + k), b = UInt16(j * row + k + 1)
                let c = UInt16((j + 1) * row + k + 1), d = UInt16((j + 1) * row + k)
                indices += [a, d, c, a, c, b]
            }
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                           elements: [element])
    }
}
