//
//  Audition.swift
//  Hallways
//
//  Oct 4 -- CREATURE AUDITION: a frog, and one more resident.
//  Both live on the Menagerie's Habitat and reuse Critter for legal
//  cell-to-cell travel; everything else (bodies, gaits, wants, voices) is
//  their own. Remove the `Audition.populate` line in Menagerie.install (and
//  this file) to delete them.
//

import SceneKit
import UIKit
import simd

enum Audition {
    static func populate(habitat: Habitat, scene: SCNScene, fromStart: [Int: Int], busy: Set<Int>, shadow: UIImage) {
        let graph = habitat.graph
        func spot(_ range: ClosedRange<Int>, prefer: (Int) -> Bool, avoiding: Int? = nil) -> Int? {
            let ok = graph.centers.keys.filter { k in
                guard let d = fromStart[k], range.contains(d), !busy.contains(k), !habitat.blockedCells.contains(k),
                      graph.degree(k) > 0, k != avoiding else { return false }
                return true
            }
            return ok.filter(prefer).randomElement() ?? ok.randomElement()
        }
        var placed: [String] = []
        let frogCell = spot(3...9, prefer: { graph.lit.contains($0) }) ?? spot(1...14, prefer: { _ in true })
        if let k = frogCell {
            let (frog, node) = Frog.make(habitat: habitat, cell: k, shadow: shadow)
            add(frog, node, extra: nil, scene: scene, habitat: habitat)
            placed.append("frog")
        }
        if let k = spot(4...10, prefer: { graph.degree($0) >= 3 }, avoiding: frogCell) ?? spot(1...14, prefer: { _ in true }, avoiding: frogCell) {
            let (slinky, node, rings) = Slinky.make(habitat: habitat, cell: k, shadow: shadow)
            add(slinky, node, extra: rings, scene: scene, habitat: habitat)
            placed.append("slinky")
        }
        // Oct 4 DIAGNOSTIC "DOUBLE THE ZOO" (32 setting only): two more frogs,
        // anywhere on the floor (the surprise resident stays unique).
        if LivingWorld.isCrowd {
            for _ in 0..<2 {
                if let k = spot(3...60, prefer: { graph.lit.contains($0) }) {
                    let (frog, node) = Frog.make(habitat: habitat, cell: k, shadow: shadow)
                    add(frog, node, extra: nil, scene: scene, habitat: habitat)
                    placed.append("frog")
                }
            }
        }
        diag("audition.installed", ["placed": placed.joined(separator: ",")])
    }

    private static func add(_ critter: Critter, _ node: SCNNode, extra: SCNNode?, scene: SCNScene, habitat: Habitat) {
        guard LivingWorld.admit() else { return }         // Oct 4 DIAGNOSTIC population cap
        node.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }
        extra?.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }
        scene.rootNode.addChildNode(node)
        if let extra { scene.rootNode.addChildNode(extra) }
        LivingWorld.track(extra ?? node, extra: extra == nil ? nil : node)
        habitat.add(critter)
        node.runAction(.repeatForever(critter.tickAction()), forKey: "critterTick")
    }
}

// MARK: - Frog

nonisolated final class Frog: Critter {
    enum Mode: String { case sit, travel, startled, watch }
    enum HopStage { case none, crouch, air, land, settle }
    private var mode: Mode = .sit
    private var modeTime: Double = 0
    private var modeLength: Double = 8
    private var hopsLeft = 0
    private var threat: SIMD2<Float>?

    // The hop.
    private var stage: HopStage = .none
    private var stageTime: Float = 0
    private var crouchTime: Float = 0.2, airTime: Float = 0.4, landTime: Float = 0.16
    private var hopDistance: Float = 0.6, hopHeight: Float = 0.18
    private var nextHopIn: Double = 1.5
    private var lift: Float = 0

    // Pose (all blended).
    private var fold: Float = 1, crouchDepth: Float = 0, pitch: Float = 0.28, reach: Float = 0, squash: Float = 0
    private var throat: Float = 0, croakT: Float = -1, blinkT: Float = -1, blinkClock = Double.random(in: 3...8)
    private var tongueT: Float = -1, tongueAt: SIMD2<Float>?, tongueCooldown: Double = 4
    private var croakClock = Double.random(in: 15...40)

    private let bodyNode: SCNNode, throatSac: SCNNode, tongue: SCNNode
    private let eyes: [SCNNode]
    private let fronts: [(shoulder: SCNNode, elbow: SCNNode)]
    private let hinds: [(hip: SCNNode, knee: SCNNode, ankle: SCNNode)]

    private static let croaks: [SCNAudioSource] = (0..<3).compactMap { i in
        MenagerieSound.source("frog-croak-\(i)", volume: 0.75) {
            var rng = Rand(seed: UInt64(500 + i))
            // "rib-bit": two pulsed syllables; each pulse rings a throaty resonance.
            func syllable(_ seconds: Float, _ pulseHz: Float, _ formant: Float, rng: inout Rand) -> [Float] {
                AnimalVoice.voice(seconds: seconds, breath: 0.15, rng: &rng, f0: { u in pulseHz * (1 - 0.1 * u) },
                                  formants: { _ in [(formant, 90, 1), (formant * 2.6, 160, 0.4), (formant * 5.1, 300, 0.12)] },
                                  env: { u in min(1, u / 0.15) * min(1, (1 - u) / 0.3) })
            }
            let a = syllable(rng.range(0.1, 0.14), rng.range(62, 75), rng.range(380, 460), rng: &rng)
            let b = syllable(rng.range(0.08, 0.11), rng.range(80, 95), rng.range(520, 600), rng: &rng)
            return MenagerieSound.mix([(0, a, 1), (Float(a.count) / MenagerieSound.rate + rng.range(0.03, 0.06), b, 0.85)])
        }
    }
    private static let plaps = MenagerieSound.variants("frog-plap", count: 4, volume: 0.35) { rng in
        let thud = MenagerieSound.strike([(rng.range(150, 190), 0.03, 0.6), (rng.range(420, 520), 0.012, 0.25)],
                                         seconds: 0.08, noise: 0.8, noiseDecay: 0.006, rng: &rng)
        let wet = AnimalVoice.breathNoise(seconds: 0.05, centre: rng.range(1400, 1900), width: 900, rng: &rng, env: { u in exp(-u * 6) })
        return MenagerieSound.mix([(0, thud, 1), (0.004, wet, 0.4)])
    }
    private static let thwip = MenagerieSound.source("frog-thwip", volume: 0.4) {
        var rng = Rand(seed: 9)
        let swish = AnimalVoice.breathNoise(seconds: 0.09, centre: 2600, width: 2000, rng: &rng, env: { u in sin(.pi * u) })
        let smack = MenagerieSound.strike([(900, 0.01, 0.4)], seconds: 0.03, noise: 0.6, noiseDecay: 0.002, rng: &rng)
        return MenagerieSound.mix([(0, swish, 0.8), (0.07, smack, 1)])
    }

    override var modeName: String { mode.rawValue }

    static func make(habitat: Habitat, cell: Int, shadow: UIImage) -> (Critter, SCNNode) {
        let root = SCNNode()
        root.name = "frog"
        AnimalBuild.shadow(shadow, width: 0.42, length: 0.55, to: root)
        let B = AnimalBuild.self
        func skin(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, rough: CGFloat) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
            m.roughness.contents = rough
            m.metalness.contents = 0.0
            return m
        }
        let green = skin(0.28, 0.55, 0.2, rough: 0.35)          // a little wet sheen
        let dark = skin(0.14, 0.3, 0.1, rough: 0.4)
        let pale = skin(0.86, 0.86, 0.6, rough: 0.5)
        let body = SCNNode()
        body.position = SCNVector3(0, 0.13, 0)
        root.addChildNode(body)
        let bodyNode = SCNNode()                                  // squash/stretch lives here
        body.addChildNode(bodyNode)
        B.blob(bodyNode, SCNVector3(0, 0, 0.03), SCNVector3(0.13, 0.08, 0.16), green)          // torso
        B.blob(bodyNode, SCNVector3(0, 0.018, -0.115), SCNVector3(0.115, 0.062, 0.095), green)  // head
        B.blob(bodyNode, SCNVector3(0, -0.04, 0.0), SCNVector3(0.11, 0.05, 0.14), pale)         // belly
        B.blob(bodyNode, SCNVector3(0, -0.012, -0.155), SCNVector3(0.1, 0.006, 0.07), dark)    // mouth line
        for (x, z, r) in [(Float(-0.05), Float(0.04), Float(0.03)), (0.06, 0.1, 0.025), (0.02, -0.02, 0.022), (-0.03, 0.12, 0.02)] {
            B.blob(bodyNode, SCNVector3(x, 0.07, z), SCNVector3(r, 0.012, r), dark)            // spots
        }
        let throatSac = B.blob(bodyNode, SCNVector3(0, -0.045, -0.135), SCNVector3(0.055, 0.03, 0.05), pale)
        var eyes: [SCNNode] = []
        for side in [Float(-1), 1] {
            B.blob(bodyNode, SCNVector3(side * 0.06, 0.06, -0.125), SCNVector3(0.042, 0.04, 0.042), green)
            let eye = SCNNode()
            eye.position = SCNVector3(side * 0.066, 0.075, -0.13)
            bodyNode.addChildNode(eye)
            let ball = B.blob(eye, SCNVector3Zero, SCNVector3(0.031, 0.031, 0.031), B.gloss(UIColor(red: 0.85, green: 0.62, blue: 0.12, alpha: 1), rough: 0.1))
            B.blob(ball, SCNVector3(side * 0.5, 0.05, -0.75), SCNVector3(0.62, 0.26, 0.35), B.gloss(.black, rough: 0.05), segments: 14)
            let glint = SCNMaterial()
            glint.lightingModel = .constant
            glint.diffuse.contents = UIColor.white
            B.blob(ball, SCNVector3(side * 0.35, 0.45, -0.78), SCNVector3(0.12, 0.12, 0.1), glint, segments: 8)
            eyes.append(eye)
        }
        // Tongue: hidden inside the mouth until it fires.
        let tongue = SCNNode()
        tongue.position = SCNVector3(0, -0.015, -0.14)
        bodyNode.addChildNode(tongue)
        let tongueGeo = SCNCapsule(capRadius: 0.012, height: 1)
        tongueGeo.materials = [B.gloss(UIColor(red: 0.9, green: 0.42, blue: 0.5, alpha: 1), rough: 0.3)]
        let tongueBody = SCNNode(geometry: tongueGeo)
        tongueBody.eulerAngles.x = .pi / 2
        tongueBody.position = SCNVector3(0, 0, -0.5)
        tongue.addChildNode(tongueBody)
        tongue.scale = SCNVector3(1, 1, 0.001)
        // Front legs: short, splayed, little hands.
        var fronts: [(shoulder: SCNNode, elbow: SCNNode)] = []
        for side in [Float(-1), 1] {
            let shoulder = SCNNode()
            shoulder.position = SCNVector3(side * 0.08, -0.03, -0.09)
            bodyNode.addChildNode(shoulder)
            let elbowEnd = B.bone(shoulder, length: 0.06, top: 0.018, bottom: 0.014, green)
            let elbow = SCNNode()
            elbowEnd.addChildNode(elbow)
            let hand = B.bone(elbow, length: 0.07, top: 0.013, bottom: 0.011, green)
            for k in 0..<4 {
                let a = (Float(k) - 1.5) * 0.45
                B.blob(hand, SCNVector3(sin(a) * 0.022, -0.004, -cos(a) * 0.022), SCNVector3(0.006, 0.004, 0.018), pale, segments: 10)
            }
            fronts.append((shoulder, elbow))
        }
        // Hind legs: long, folding Z, webbed feet. Segments point back (+z).
        var hinds: [(hip: SCNNode, knee: SCNNode, ankle: SCNNode)] = []
        func segment(_ parent: SCNNode, _ length: Float, _ r0: Float, _ r1: Float, _ m: SCNMaterial) -> SCNNode {
            let cone = SCNCone(topRadius: CGFloat(r0), bottomRadius: CGFloat(r1), height: CGFloat(length))
            cone.radialSegmentCount = 14
            cone.materials = [m]
            let n = SCNNode(geometry: cone)
            n.eulerAngles.x = .pi / 2
            n.position = SCNVector3(0, 0, length / 2)
            parent.addChildNode(n)
            B.blob(parent, SCNVector3Zero, SCNVector3(r0, r0, r0), m, segments: 12)
            let end = SCNNode()
            end.position = SCNVector3(0, 0, length)
            parent.addChildNode(end)
            return end
        }
        for side in [Float(-1), 1] {
            let hip = SCNNode()
            hip.position = SCNVector3(side * 0.095, -0.02, 0.11)
            bodyNode.addChildNode(hip)
            B.blob(hip, SCNVector3(0, 0, 0.05), SCNVector3(0.042, 0.035, 0.07), green)              // thigh muscle
            let kneeEnd = segment(hip, 0.13, 0.03, 0.02, green)
            let knee = SCNNode()
            kneeEnd.addChildNode(knee)
            let ankleEnd = segment(knee, 0.13, 0.019, 0.013, dark)
            let ankle = SCNNode()
            ankleEnd.addChildNode(ankle)
            let footEnd = segment(ankle, 0.06, 0.012, 0.01, green)
            for k in 0..<4 {
                let a = (Float(k) - 1.5) * 0.28
                let toe = SCNNode()
                toe.position = SCNVector3Zero
                toe.eulerAngles.y = a
                footEnd.addChildNode(toe)
                B.blob(toe, SCNVector3(0, -0.003, 0.03), SCNVector3(0.006, 0.004, 0.032), pale, segments: 10)
            }
            B.blob(footEnd, SCNVector3(0, -0.004, 0.022), SCNVector3(0.03, 0.002, 0.028), skin(0.5, 0.6, 0.35, rough: 0.5)) // web
            hinds.append((hip, knee, ankle))
        }
        root.scale = SCNVector3(1.15, 1.15, 1.15)
        let frog = Frog(habitat: habitat, node: root, body: body, cell: cell, bodyNode: bodyNode, throatSac: throatSac, tongue: tongue,
                        eyes: eyes, fronts: fronts, hinds: hinds)
        return (frog, root)
    }

    init(habitat: Habitat, node: SCNNode, body: SCNNode, cell: Int, bodyNode: SCNNode, throatSac: SCNNode, tongue: SCNNode,
         eyes: [SCNNode], fronts: [(shoulder: SCNNode, elbow: SCNNode)], hinds: [(hip: SCNNode, knee: SCNNode, ankle: SCNNode)]) {
        self.bodyNode = bodyNode; self.throatSac = throatSac; self.tongue = tongue
        self.eyes = eyes; self.fronts = fronts; self.hinds = hinds
        super.init(kind: .frog, habitat: habitat, node: node, body: body, cell: cell)
        maxLane = 0.6
        personalSpace = 0.5
        acceleration = 400            // airborne speed is set exactly per hop
        turnRate = 5
        senseInterval = 0.3
    }

    private func set(_ m: Mode, for seconds: ClosedRange<Double>) {
        mode = m
        modeTime = 0
        modeLength = Double.random(in: seconds)
    }

    private var bodyFacing: SIMD2<Float> { SIMD2<Float>(-sin(heading), -cos(heading)) }

    override func sense(now: CFTimeInterval) {
        tongueCooldown = max(0, tongueCooldown - senseInterval)
        // Anything big closing in fast: one enormous leap away.
        let big: Set<Habitat.Kind> = [.noodle, .player, .dog, .cat, .ladder, .chair, .stalk]
        if mode != .startled, stage == .none || stage == .settle,
           case let (s, d)? = nearest(big, within: 1.7), closingSpeed(s) > 0.8 || d < 0.6 {
            threat = s.pos
            set(.startled, for: 1.5...2.5)
            if simd_dot(direction, s.pos - pos) > 0 { reverse() }
            startHop(size: 2)
            say(Self.croaks.randomElement())
            return
        }
        // Something small and moving, right in front: the tongue.
        if tongueCooldown <= 0, stage == .none, tongueT < 0 {
            for s in habitat.sightings where s.id != id && s.kind != .frog {
                let to = s.pos - pos
                let d = simd_length(to)
                guard d > 0.15, d < 1.25, simd_length(s.velocity) > 0.15 else { continue }
                if simd_dot(to / d, bodyFacing) > 0.85 {
                    tongueAt = s.pos
                    tongueT = 0
                    tongueCooldown = Double.random(in: 4...9)
                    say(Self.thwip, loud: false)
                    break
                }
            }
        }
        // Anything at all moving within view while sitting: turn to watch it.
        if mode == .sit, case let (s, d)? = nearest([.noodle, .bobbin, .clacker, .slinky, .cat, .dog, .pottle], within: 4),
           d > 0.6, simd_length(s.velocity) > 0.2, Float.random(in: 0...1) < 0.3 {
            lookAt = s.pos
        }
    }

    override func think(dt: Double, now: CFTimeInterval) {
        modeTime += dt
        switch mode {
        case .sit, .watch:
            if modeTime > modeLength {
                // Off somewhere: usually towards light, otherwise wherever.
                set(.travel, for: 6...14)
                hopsLeft = Int.random(in: 2...6)
                if !graph.lit.contains(from), Float.random(in: 0...1) < 0.7 {
                    let lit = graph.lit.filter { !habitat.blockedCells.contains($0) }
                    let near = graph.distances(from: [from])
                    goal = lit.min { (near[$0] ?? 999) < (near[$1] ?? 999) }
                }
            }
            croakClock -= dt
            if croakClock <= 0, stage == .none {
                croakClock = Double.random(in: 25...70)
                croakT = 0
                say(Self.croaks.randomElement())
            }
            // The odd little shuffle to face something.
            if stage == .none, let look = lookAt, Float.random(in: 0...1) < Float(dt) * 0.2,
               abs(angleTo(look)) > 0.9 { startHop(size: 0) }
        case .travel:
            nextHopIn -= dt
            if stage == .none, nextHopIn <= 0 {
                if hopsLeft <= 0 || (goal != nil && goal == from) {
                    goal = nil
                    set(.sit, for: graph.lit.contains(from) ? 12...35 : 5...14)
                } else {
                    hopsLeft -= 1
                    startHop(size: Float.random(in: 0...1) < 0.08 ? 2 : 1)
                }
            }
        case .startled:
            if stage == .none, modeTime > modeLength { set(.sit, for: 4...10); threat = nil; lookAt = nil }
        }
    }

    override func arrived(at cell: Int) {
        if cell == goal { goal = nil }
    }

    override func giveWay(to other: Habitat.Sighting) {}     // a hop is a hop; no stopping mid-air

    override func choose(options: [Int]) -> Int {
        if mode == .startled, let threat { return choice(options, awayFrom: threat) }
        return roamChoice(options)
    }

    private func angleTo(_ p: SIMD2<Float>) -> Float {
        let to = p - pos
        var a = atan2(-to.x, -to.y) - heading
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }

    /// size 0 = a little repositioning hop, 1 = a travelling hop, 2 = the big leap.
    private func startHop(size: Int) {
        switch size {
        case 0: hopDistance = 0.22; hopHeight = 0.07; crouchTime = 0.14; airTime = 0.24; landTime = 0.12
        case 2: hopDistance = Float.random(in: 1.4...1.9); hopHeight = 0.5; crouchTime = 0.32; airTime = 0.72; landTime = 0.26
        default: hopDistance = Float.random(in: 0.5...0.75); hopHeight = 0.17; crouchTime = 0.2; airTime = 0.4; landTime = 0.16
        }
        stage = .crouch
        stageTime = 0
        // Face the way it is about to go while it gathers itself.
        lookAt = pos + direction * 2
    }

    override func animate(dt: Float, moved: Float, turning: Float) {
        let t = Float(time)
        stageTime += dt
        // Hop sequence -- the body only travels while airborne.
        var wantFold: Float = 1, wantCrouch: Float = 0, wantPitch: Float = 0.28, wantReach: Float = 0, wantSquash: Float = 0
        wantSpeed = 0
        lift = 0
        switch stage {
        case .none:
            break
        case .crouch:
            let k = min(1, stageTime / crouchTime)
            wantCrouch = k                                   // sink, load the hind legs
            wantPitch = 0.28 - 0.25 * k
            wantFold = 1
            if stageTime >= crouchTime { stage = .air; stageTime = 0; lookAt = nil }
        case .air:
            let s = min(1, stageTime / airTime)
            wantSpeed = hopDistance / airTime
            lift = 4 * hopHeight * s * (1 - s)
            // Explosive extension, then reach for the ground with the hands
            // while the hind legs gather back up.
            wantFold = s < 0.35 ? 0 : (s - 0.35) / 0.65
            wantPitch = -0.35 + 0.15 * s - (s > 0.6 ? (s - 0.6) * 0.4 : 0)
            wantReach = s > 0.4 ? (s - 0.4) / 0.6 : -0.4
            wantCrouch = 0
            if stageTime >= airTime { stage = .land; stageTime = 0; say(Self.plaps.randomElement(), loud: false) }
        case .land:
            let k = min(1, stageTime / landTime)
            wantSquash = sin(.pi * k)
            wantCrouch = 0.7 * (1 - k)
            wantPitch = -0.3 + 0.55 * k                      // hands down first, then the rear settles
            wantReach = 1 - k
            wantFold = 1
            if stageTime >= landTime { stage = .settle; stageTime = 0 }
        case .settle:
            wantPitch = 0.28 + 0.06 * sin(stageTime * 18) * (1 - stageTime / 0.3)
            if stageTime >= 0.3 {
                stage = .none
                nextHopIn = Double.random(in: 0.25...1.3)
            }
        }
        if mode != .travel && mode != .startled && stage == .none { wantPitch = 0.28 }
        let rate: Float = stage == .air || stage == .land ? 22 : 12
        fold += (wantFold - fold) * min(1, dt * rate)
        crouchDepth += (wantCrouch - crouchDepth) * min(1, dt * rate)
        pitch += (wantPitch - pitch) * min(1, dt * rate)
        reach += (wantReach - reach) * min(1, dt * rate)
        squash += (wantSquash - squash) * min(1, dt * 25)

        body.position.y = 0.13 - 0.045 * crouchDepth + lift
        body.eulerAngles = SCNVector3(pitch, 0, 0)
        let breathe = 1 + 0.015 * sin(t * 2.2)
        bodyNode.scale = SCNVector3(1 + 0.12 * squash, (1 - 0.18 * squash) * breathe, 1 + 0.05 * squash)

        // Hind legs: folded Z (sitting) <-> straight back (thrust).
        for (i, leg) in hinds.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            let f = fold
            leg.hip.eulerAngles = SCNVector3(0.42 * f + 0.5 * (1 - f) - 0.25 * crouchDepth, side * 2.6 * f, 0)
            leg.knee.eulerAngles = SCNVector3(0.25 * f, -side * 2.25 * f, 0)
            leg.ankle.eulerAngles = SCNVector3(-0.35 * f + 0.3 * (1 - f), side * 2.35 * f, 0)
        }
        // Front legs: propping (sitting) / swept back (thrust) / reaching (landing).
        for (i, leg) in fronts.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            leg.shoulder.eulerAngles = SCNVector3(0.2 + 0.7 * reach - 0.3 * crouchDepth, 0, side * -0.35)
            leg.elbow.eulerAngles = SCNVector3(-0.5 + 0.3 * reach + 0.4 * crouchDepth, 0, 0)
        }
        // Throat: always gently pumping; balloons on a croak.
        var sac: Float = 1 + 0.08 * sin(t * 9)
        if croakT >= 0 {
            croakT += dt / 0.55
            sac += 0.9 * sin(.pi * min(1, croakT))
            if croakT >= 1 { croakT = -1 }
        }
        throatSac.scale = SCNVector3(0.055 * sac, 0.03 * sac, 0.05 * sac)
        // Blink: the eyes sink into the head.
        blinkClock -= Double(dt)
        if blinkClock <= 0 { blinkClock = Double.random(in: 3...9); blinkT = 0 }
        var sink: Float = 0
        if blinkT >= 0 { blinkT += dt / 0.25; sink = sin(.pi * min(1, blinkT)); if blinkT >= 1 { blinkT = -1 } }
        if stage == .land { sink = max(sink, 0.5 * squash) }
        for (i, eye) in eyes.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            eye.position = SCNVector3(side * 0.066, 0.075 - 0.025 * sink, -0.13)
        }
        // Tongue: out and back in a quarter second.
        if tongueT >= 0 {
            tongueT += dt / 0.26
            let out = sin(.pi * min(1, tongueT))
            var length: Float = 0.8
            if let target = tongueAt { length = min(1.1, simd_length(target - pos)) }
            tongue.scale = SCNVector3(1, 1, max(0.001, out * length))
            if tongueT >= 1 { tongueT = -1; tongue.scale = SCNVector3(1, 1, 0.001) }
        }
        // Hold the body exactly on its path (lane taken only while airborne),
        // so it never slides on after landing or drifts while sitting.
        if stage == .air { hopLane = lane } else { lane = hopLane; laneTarget = hopLane }
        if let a = graph.centers[from] {
            let d = direction
            let spot = a + d * (from == to ? 0 : progress) + SIMD2<Float>(-d.y, d.x) * hopLane
            pos = spot
            node?.position = SCNVector3(spot.x, 0, spot.y)
        }
    }
    private var hopLane: Float = 0
}

// MARK: - The other one

/// A coil that walks end over end. Rings live in world space (a container at
/// the scene root); the Critter node itself is just its anchor/voice/shadow.
nonisolated final class Slinky: Critter {
    enum Mode: String { case wander, follow, lost, sulk }
    private var mode: Mode = .wander
    private var modeTime: Double = 0
    private var modeLength: Double = 6
    private var leaderID: String?
    private var lastSawLeader: Double = 0
    private var snubbed: [String: Double] = [:]      // who it recently gave up on

    private let rings: [SCNNode]
    private let ringCount: Int
    private let gap: Float = 0.0105
    private let archHeight: Float = 0.36

    // Walking.
    private var stackAt: SIMD2<Float>
    private var stepFrom = SIMD2<Float>(0, 0), stepTo = SIMD2<Float>(0, 0)
    private var stepT: Float = -1
    private var stepDuration: Float = 0.9
    private var stepLength: Float = 0.55
    private var restClock: Double = 1.5
    private var stepLane: Float = 0

    // Idle life.
    private var sway = SIMD2<Float>(0, 0), swayVelocity = SIMD2<Float>(0, 0)
    private var squish: Float = 0, squishVelocity: Float = 0
    private var lean = SIMD2<Float>(0, 0)
    private var slump: Float = 0
    private var boingCooldown: Double = 0

    private static let shhh: [SCNAudioSource] = (0..<3).compactMap { i in
        MenagerieSound.source("slinky-step-\(i)", volume: 0.4) {
            var rng = Rand(seed: UInt64(600 + i))
            let a = MenagerieSound.creak(resonance: rng.range(3200, 3900), q: 14, startHz: 35, endHz: rng.range(150, 190),
                                         seconds: 0.55, rng: &rng)
            let b = MenagerieSound.creak(resonance: rng.range(2100, 2500), q: 10, startHz: 160, endHz: 40, seconds: 0.35, rng: &rng)
            let chime = MenagerieSound.strike([(rng.range(2500, 2800), 0.05, 0.4), (rng.range(3900, 4300), 0.03, 0.25)],
                                              seconds: 0.12, rng: &rng)
            return MenagerieSound.mix([(0, a, 1), (0.5, b, 0.7), (0.82, chime, 0.6)])
        }
    }
    private static let boing = MenagerieSound.source("slinky-boing", volume: 0.65) {
        let n = Int(0.7 * MenagerieSound.rate)
        var phase: Float = 0
        return (0..<n).map { i -> Float in
            let t = Float(i) / MenagerieSound.rate
            let f = 210 * (1 + 0.35 * sin(2 * .pi * 17 * t) * exp(-t * 3)) * (1 - 0.15 * t)
            phase += 2 * .pi * f / MenagerieSound.rate
            return (sin(phase) + 0.35 * sin(phase * 2.76)) * exp(-t * 4.5) * min(1, t / 0.004)
        }
    }
    private static let droop = MenagerieSound.source("slinky-droop", volume: 0.55) {
        var rng = Rand(seed: 66)
        let fall = MenagerieSound.sweep(620, 160, seconds: 0.8, wobble: 0.8, curve: 0.6)
        let rattle = MenagerieSound.creak(resonance: 2400, q: 12, startHz: 90, endHz: 20, seconds: 0.8, rng: &rng)
        return MenagerieSound.mix([(0, fall, 0.7), (0, rattle, 0.5)])
    }

    override var modeName: String { mode.rawValue }

    static func make(habitat: Habitat, cell: Int, shadow: UIImage) -> (Critter, SCNNode, SCNNode) {
        let anchor = SCNNode()
        anchor.name = "slinky"
        AnimalBuild.shadow(shadow, width: 0.36, length: 0.36, to: anchor)
        let world = SCNNode()
        world.name = "slinkyRings"
        let count = 30
        let torus = (0..<count).map { i -> SCNTorus in
            let t = SCNTorus(ringRadius: 0.085, pipeRadius: 0.0055)
            t.ringSegmentCount = 28
            t.pipeSegmentCount = 6
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(hue: CGFloat(i) / CGFloat(count) * 0.85, saturation: 0.75, brightness: 0.95, alpha: 1)
            m.roughness.contents = 0.3
            m.metalness.contents = 0.0
            t.materials = [m]
            return t
        }
        let rings = torus.map { geo -> SCNNode in
            let n = SCNNode(geometry: geo)
            world.addChildNode(n)
            return n
        }
        let slinky = Slinky(habitat: habitat, node: anchor, cell: cell, rings: rings)
        return (slinky, anchor, world)
    }

    init(habitat: Habitat, node: SCNNode, cell: Int, rings: [SCNNode]) {
        self.rings = rings
        self.ringCount = rings.count
        self.stackAt = habitat.graph.centers[cell] ?? .zero
        super.init(kind: .slinky, habitat: habitat, node: node, body: node, cell: cell)
        maxLane = 0.5
        personalSpace = 0.45
        acceleration = 400
        turnRate = 6
        senseInterval = 0.35
    }

    private func set(_ m: Mode, for seconds: ClosedRange<Double>) {
        mode = m
        modeTime = 0
        modeLength = Double.random(in: seconds)
    }

    private var leader: Habitat.Sighting? {
        guard let leaderID else { return nil }
        return habitat.sightings.first { $0.id == leaderID }
    }

    override func sense(now: CFTimeInterval) {
        boingCooldown = max(0, boingCooldown - senseInterval)
        for (k, v) in snubbed where v < time { snubbed.removeValue(forKey: k) }
        // Bumped into, or rushed at: BOING, and it skips back a little.
        for s in habitat.sightings where s.id != id && s.kind != .player {
            let d = simd_length(s.pos - stackAt)
            if d < 0.55, boingCooldown <= 0, closingSpeed(s) > 0.3 || d < 0.3 {
                boing(away: s.pos)
                break
            }
        }
        switch mode {
        case .wander:
            // The first thing it sees going somewhere becomes the one to follow.
            var best: (Habitat.Sighting, Float)?
            for s in habitat.sightings where s.id != id && s.kind != .player && snubbed[s.id] == nil {
                let d = simd_length(s.pos - stackAt)
                guard d < 4.5, simd_length(s.velocity) > 0.25 else { continue }
                if best == nil || d < best!.1 { best = (s, d) }
            }
            if case let (s, _)? = best, habitat.canSee(stackAt, s.pos, height: 0.3) {
                leaderID = s.id
                lastSawLeader = time
                set(.follow, for: 40...90)
                boing(away: nil)
            }
        case .follow:
            if let l = leader, simd_length(l.pos - stackAt) < 10, habitat.canSee(stackAt, l.pos, height: 0.3) {
                lastSawLeader = time
            }
            if time - lastSawLeader > 5 || modeTime > modeLength {
                set(.lost, for: 3...6)
                goal = nil
            }
        default:
            break
        }
    }

    override func think(dt: Double, now: CFTimeInterval) {
        modeTime += dt
        switch mode {
        case .wander:
            stepDuration = 0.95
            if modeTime > modeLength { set(.wander, for: 5...12); restClock = Double.random(in: 1...4) }
        case .follow:
            stepDuration = 0.75
            if let l = leader {
                let d = simd_length(l.pos - stackAt)
                // Keep a respectful distance; when the leader stops, stop too
                // and lean in to see what it's looking at.
                if d > 1.6 { goal = graph.cell(near: l.pos) } else { goal = nil }
                if d < 1.6 || simd_length(l.velocity) < 0.1 { restClock = max(restClock, 0.4) }
                let to = l.pos - stackAt
                let len = simd_length(to)
                if len > 0.01 { lean += ((to / len) * 0.35 - lean) * min(1, Float(dt) * 3) }
                if d < 1.6 { restClock = 0.6 }
            }
        case .lost:
            stepDuration = 0.55                          // a frantic little hurry
            if modeTime > modeLength {
                set(.sulk, for: 4...8)
                say(Self.droop)
                if let leaderID { snubbed[leaderID] = time + 45 }
                leaderID = nil
            }
        case .sulk:
            stepDuration = 1.3
            restClock = max(restClock, 0.5)
            if modeTime > modeLength { set(.wander, for: 6...14) }
        }
        if mode != .follow { lean *= max(0, 1 - Float(dt) * 2) }
        slump += ((mode == .sulk ? 1 : 0) - slump) * min(1, Float(dt) * 1.5)

        // Steps: rest, then flip end over end to the next spot.
        if stepT < 0 {
            restClock -= dt
            if restClock <= 0, mode != .sulk {
                stepFrom = stackAt
                stepLength = mode == .lost ? 0.45 : 0.55
                stepTo = stackAt + direction * stepLength
                stepT = 0
                stepLane = lane
                say(Self.shhh.randomElement(), loud: false)
            }
        }
    }

    override func giveWay(to other: Habitat.Sighting) {}     // it never stops mid-flip

    private func boing(away: SIMD2<Float>?) {
        boingCooldown = 2.5
        squishVelocity = -9
        say(Self.boing)
        if let away, stepT < 0 {
            let push = stackAt - away
            let len = simd_length(push)
            if len > 0.01 { swayVelocity += push / len * 3 }
        }
    }

    override func animate(dt: Float, moved: Float, turning: Float) {
        let t = Float(time)
        // Base travel only runs during a step, at exactly the step's pace.
        if stepT >= 0 {
            stepT += dt / stepDuration
            wantSpeed = stepLength / stepDuration
            if stepT >= 1 {
                stepT = -1
                wantSpeed = 0
                stackAt = pos
                squishVelocity = -2.5                    // lands with a little jiggle
                restClock = Double.random(in: mode == .wander ? 0.6...3.5 : 0.15...0.6)
            }
        } else {
            wantSpeed = 0
        }
        // Lock the anchor to its path (lane only changes mid-step).
        if stepT >= 0 { stepLane = lane } else { lane = stepLane; laneTarget = stepLane }
        if let a = graph.centers[from] {
            let d = direction
            let spot = a + d * (from == to ? 0 : progress) + SIMD2<Float>(-d.y, d.x) * stepLane
            pos = spot
            node?.position = SCNVector3(spot.x, 0, spot.y)
        }
        // Springs: sway (top of the stack) and squish (stack height).
        swayVelocity += (-sway * 40 - swayVelocity * 3) * dt
        sway += swayVelocity * dt
        squishVelocity += (-squish * 60 - squishVelocity * 4) * dt
        squish += squishVelocity * dt
        let breathing = 0.03 * sin(t * 1.7)

        let n = ringCount
        let up = SIMD3<Float>(0, 1, 0)
        for i in 0..<n {
            let ring = rings[i]
            let h = Float(i) * gap * (1 + squish * 0.6 + breathing) * (1 - 0.45 * slump)
            var p: SIMD3<Float>
            var axis = up
            if stepT >= 0 {
                // Top rings leave first, arc over, and become the bottom of the new stack.
                let rank = Float(n - 1 - i)
                let delay = rank / Float(n - 1) * 0.55
                var tau = max(0, min(1, (stepT - delay) / 0.45))
                tau = tau * tau * (3 - 2 * tau)
                let hEnd = rank * gap
                let flat = stepFrom + (stepTo - stepFrom) * tau
                let y = h + (hEnd - h) * tau + archHeight * sin(.pi * tau)
                p = SIMD3<Float>(flat.x, y, flat.y)
                let along = stepTo - stepFrom
                let tangent = SIMD3<Float>(along.x, (hEnd - h) + archHeight * .pi * cos(.pi * tau), along.y)
                let w = sin(.pi * tau)
                if simd_length(tangent) > 0.0001 { axis = simd_normalize(up * (1 - w) + simd_normalize(tangent) * w) }
            } else {
                // Standing: the stack leans/sways, more at the top.
                let k = Float(i) / Float(n - 1)
                let offset = (sway + lean) * (k * k * 0.18) + SIMD2<Float>(sin(t * 2.3 + Float(i) * 0.2), 0) * 0.002 * slump
                let base = stackAt + offset
                p = SIMD3<Float>(base.x, h, base.y)
                let tilt = SIMD3<Float>(sway.x + lean.x, 0, sway.y + lean.y) * (k * 0.8)
                axis = simd_normalize(up + tilt)
            }
            ring.simdPosition = p + SIMD3<Float>(0, 0.006, 0)
            ring.simdOrientation = simd_quatf(from: up, to: axis)
        }
    }
}
