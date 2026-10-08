//
//  RealAnimals.swift
//  Hallways
//
//  Oct 3 -- CALIBRATION EXPERIMENT: how real can procedural SceneKit get?
//  A dog and a cat, built from primitives (ellipsoid "muscle" volumes over a
//  jointed skeleton), with procedural fur textures, two-bone leg IK driven by
//  real gait timing, secondary motion, and formant-synthesised voices.
//
//  Self-contained: they live on the Menagerie's Habitat (floor graph, who's
//  where, line of sight) and reuse Critter for cell-to-cell travel only.
//  Remove the one `RealAnimals.populate` line in Menagerie.install (and this
//  file) to delete the experiment.
//

import SceneKit
import UIKit
import simd

// MARK: - Install

enum RealAnimals {
    static let dogEnabled = false
    /// Places one dog and one cat a few cells from where the player arrives.
    static func populate(habitat: Habitat, scene: SCNScene, start: Int, fromStart: [Int: Int], busy: Set<Int>, shadow: UIImage) {
        let tracePhase = ElevatorArrivalTrace.shared.beginPhase("RealAnimals.populate")
        defer { ElevatorArrivalTrace.shared.endPhase("RealAnimals.populate", tracePhase) }
        let graph = habitat.graph
        func spot(_ range: ClosedRange<Int>, avoiding: Int?) -> Int? {
            let options = graph.centers.keys.filter { k in
                guard let d = fromStart[k], range.contains(d), !busy.contains(k), !habitat.blockedCells.contains(k),
                      graph.degree(k) > 0, k != avoiding else { return false }
                return true
            }
            return options.randomElement()
        }
        let traceSkins = ElevatorArrivalTrace.shared.beginPhase("RealAnimals.skinMaterials")
        let coats = RealAnimalSkins.make()
        ElevatorArrivalTrace.shared.endPhase("RealAnimals.skinMaterials", traceSkins)
        var placed: [String] = []
        // Oct 4 (Freddy slice): the realistic dog is out of the normal population
        // (judged against real dogs, his procedural gait reads stiff). Set
        // dogEnabled back to true to bring him back; his code is untouched.
        let dogCell = dogEnabled ? (spot(2...4, avoiding: nil) ?? spot(1...6, avoiding: nil)) : nil
        let traceDog = ElevatorArrivalTrace.shared.beginPhase("RealAnimals.dogBuildAndInstall")
        if let k = dogCell {
            let (dog, node) = Dog.make(habitat: habitat, cell: k, skins: coats, shadow: shadow)
            install(dog, node, in: scene, habitat: habitat)
            placed.append("dog")
        }
        ElevatorArrivalTrace.shared.endPhase("RealAnimals.dogBuildAndInstall", traceDog)
        let traceCat = ElevatorArrivalTrace.shared.beginPhase("RealAnimals.catBuildAndInstall")
        if let k = spot(2...5, avoiding: dogCell) ?? spot(1...7, avoiding: dogCell) {
            let (cat, node) = Cat.make(habitat: habitat, cell: k, skins: coats, shadow: shadow)
            install(cat, node, in: scene, habitat: habitat)
            placed.append("cat")
        }
        ElevatorArrivalTrace.shared.endPhase("RealAnimals.catBuildAndInstall", traceCat)
        diag("realAnimals.installed", ["placed": placed.joined(separator: ",")])
    }

    private static func install(_ critter: Critter, _ node: SCNNode, in scene: SCNScene, habitat: Habitat) {
        guard LivingWorld.admit() else { return }         // Oct 4 DIAGNOSTIC population cap
        node.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }
        scene.rootNode.addChildNode(node)
        LivingWorld.track(node)
        habitat.add(critter)
        node.runAction(.repeatForever(critter.tickAction()), forKey: "critterTick")
    }
}

// MARK: - Skins (fresh materials per floor, shared immutable fur images)

nonisolated struct RealAnimalSkins {
    private struct FurImageKey: Hashable {
        let colors: [CGFloat]
        let stripes: Bool
    }
    // Six small procedural images, independent of floor/topology. Materials
    // remain private to each floor so painting cannot affect another animal.
    @MainActor private static var furImages: [FurImageKey: UIImage] = [:]

    let dogCoat: SCNMaterial
    let dogSaddle: SCNMaterial
    let dogCream: SCNMaterial
    let catTabby: SCNMaterial
    let catWhite: SCNMaterial
    let catDark: SCNMaterial

    @MainActor static func make() -> RealAnimalSkins {
        RealAnimalSkins(
            dogCoat: fur(base: (0.66, 0.45, 0.25), dark: (0.45, 0.28, 0.14), light: (0.82, 0.64, 0.42), stripes: false, scale: 3),
            dogSaddle: fur(base: (0.22, 0.15, 0.09), dark: (0.1, 0.07, 0.05), light: (0.42, 0.3, 0.18), stripes: false, scale: 3),
            dogCream: fur(base: (0.86, 0.76, 0.6), dark: (0.7, 0.58, 0.42), light: (0.95, 0.9, 0.8), stripes: false, scale: 4),
            catTabby: fur(base: (0.5, 0.47, 0.42), dark: (0.17, 0.15, 0.13), light: (0.7, 0.66, 0.58), stripes: true, scale: 2),
            catWhite: fur(base: (0.9, 0.88, 0.84), dark: (0.74, 0.72, 0.68), light: (1, 0.99, 0.96), stripes: false, scale: 4),
            catDark: fur(base: (0.22, 0.2, 0.18), dark: (0.1, 0.09, 0.08), light: (0.35, 0.32, 0.28), stripes: false, scale: 3))
    }

    /// A tileable fur texture: base colour, thousands of short directional
    /// strokes (hair flow) in darker and lighter tones, optional tabby bands.
    @MainActor private static func fur(base: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat),
                            stripes: Bool, scale: Float) -> SCNMaterial {
        let traceFur = ElevatorArrivalTrace.shared.beginPhase("RealAnimals.furMaterial", "stripes=\(stripes) scale=\(scale)")
        defer { ElevatorArrivalTrace.shared.endPhase("RealAnimals.furMaterial", traceFur) }
        let key = FurImageKey(colors: [base.0, base.1, base.2, dark.0, dark.1, dark.2,
                                       light.0, light.1, light.2], stripes: stripes)
        let image: UIImage
        if let cached = furImages[key] {
            image = cached
            ElevatorArrivalTrace.shared.event("RealAnimals.furImage.cacheHit")
        } else {
            let size = CGSize(width: 256, height: 256)
            var rng = SystemRandomNumberGenerator()
            image = UIGraphicsImageRenderer(size: size).image { context in
                let cg = context.cgContext
                cg.setFillColor(UIColor(red: base.0, green: base.1, blue: base.2, alpha: 1).cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
                if stripes {
                    cg.setStrokeColor(UIColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 0.75).cgColor)
                    for band in 0..<7 {
                        let y0 = CGFloat(band) * 256 / 7 + CGFloat.random(in: -6...6, using: &rng)
                        cg.setLineWidth(CGFloat.random(in: 7...14, using: &rng))
                        cg.move(to: CGPoint(x: -10, y: y0))
                        var x: CGFloat = -10
                        while x < 266 {
                            x += 16
                            cg.addLine(to: CGPoint(x: x, y: y0 + 9 * sin(x / 30 + CGFloat(band)) + CGFloat.random(in: -2...2, using: &rng)))
                        }
                        cg.strokePath()
                    }
                }
                cg.setLineCap(.round)
                for i in 0..<4200 {
                    let t = CGFloat.random(in: 0...1, using: &rng)
                    let tone = i % 2 == 0 ? dark : light
                    let mix = (base.0 + (tone.0 - base.0) * t, base.1 + (tone.1 - base.1) * t, base.2 + (tone.2 - base.2) * t)
                    cg.setStrokeColor(UIColor(red: mix.0, green: mix.1, blue: mix.2, alpha: CGFloat.random(in: 0.25...0.6, using: &rng)).cgColor)
                    cg.setLineWidth(CGFloat.random(in: 0.6...1.6, using: &rng))
                    let x = CGFloat.random(in: 0...256, using: &rng)
                    let y = CGFloat.random(in: 0...256, using: &rng)
                    let length = CGFloat.random(in: 3...9, using: &rng)
                    let angle = CGFloat.random(in: -0.35...0.35, using: &rng) + .pi / 2
                    cg.move(to: CGPoint(x: x, y: y))
                    cg.addLine(to: CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length))
                    cg.strokePath()
                }
            }
            furImages[key] = image
        }
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = image
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(scale, scale, 1)
        m.roughness.contents = 0.92
        m.metalness.contents = 0.0
        return m
    }
}

// MARK: - Rig helpers

/// One leg: shoulder/hip joint -> upper bone -> lower bone -> pastern
/// (front) / metatarsus (hind) -> paw. Solved each frame with two-bone IK in
/// the torso's sagittal plane; the last segment holds a set ground angle.
nonisolated final class LegRig {
    let upper: SCNNode
    let lower: SCNNode
    let end: SCNNode
    let a: Float, b: Float, c: Float
    let jointY: Float, jointZ: Float          // joint position in the torso frame
    let kneeForward: Bool                     // hind: stifle forward; front: elbow back
    let endAngle: Float                       // world angle of the last segment when planted
    var phaseOffset: Float
    var planted = true

    init(upper: SCNNode, lower: SCNNode, end: SCNNode, a: Float, b: Float, c: Float, jointY: Float, jointZ: Float,
         kneeForward: Bool, endAngle: Float, phaseOffset: Float) {
        self.upper = upper; self.lower = lower; self.end = end
        self.a = a; self.b = b; self.c = c
        self.jointY = jointY; self.jointZ = jointZ
        self.kneeForward = kneeForward; self.endAngle = endAngle; self.phaseOffset = phaseOffset
    }

    /// Place the paw at `forward` metres ahead of the joint's ground point and
    /// `lift` above the floor, given the torso's height and pitch (+ = nose up).
    /// `extraEnd` bends the last segment (e.g. a paw lifted to the face).
    func solve(torsoHeight h: Float, pitch p: Float, forward: Float, lift: Float, extraEnd: Float = 0) {
        // Joint in world (relative to the torso origin's ground point).
        let jointWorldY = h + (jointY * cos(p) - jointZ * sin(p))
        let jointWorldF = -(jointZ * cos(p) + jointY * sin(p))            // forward = -z
        // Wanted end of the two-bone chain: above the paw by the last segment.
        let endWorld = endAngle + extraEnd
        let targetF = jointWorldF + forward - c * sin(endWorld)
        let targetY = lift + 0.02 + c * cos(endWorld)
        let dyW = targetY - jointWorldY
        let dzW = -(targetF - jointWorldF)
        // World vector -> torso frame (undo the pitch).
        let yT = dyW * cos(p) + dzW * sin(p)
        let zT = -dyW * sin(p) + dzW * cos(p)
        var f = -zT, d = -yT
        var dist = (f * f + d * d).squareRoot()
        let reach = a + b - 0.002
        let fold = abs(a - b) + 0.01
        if dist > reach { f *= reach / dist; d *= reach / dist; dist = reach }
        if dist < fold { let k = fold / max(dist, 0.0001); f *= k; d *= k; dist = fold }
        let theta = atan2(f, d)
        let cosAlpha = max(-1, min(1, (a * a + dist * dist - b * b) / (2 * a * dist)))
        let alpha = acos(cosAlpha)
        let u = kneeForward ? theta + alpha : theta - alpha
        let kneeF = a * sin(u), kneeD = a * cos(u)
        let l = atan2(f - kneeF, d - kneeD)
        upper.eulerAngles.x = u
        lower.eulerAngles.x = l - u
        end.eulerAngles.x = (endWorld - p) - l
    }
}

/// A tail as a chain of segments; each follows the one before with a lag.
nonisolated final class TailRig {
    let joints: [SCNNode]
    private var pitch: [Float]
    private var yaw: [Float]

    init(joints: [SCNNode]) {
        self.joints = joints
        pitch = Array(repeating: 0, count: joints.count)
        yaw = Array(repeating: 0, count: joints.count)
    }

    /// `basePitch`/`baseYaw` drive the root; `curl` bends every joint;
    /// `stiffness` = how quickly each joint catches up (lower = floppier).
    func update(dt: Float, basePitch: Float, baseYaw: Float, curlPitch: Float, curlYaw: Float, stiffness: Float) {
        var targetPitch = basePitch
        var targetYaw = baseYaw
        for i in joints.indices {
            let k = min(1, dt * stiffness * (1 - Float(i) * 0.06))
            pitch[i] += (targetPitch - pitch[i]) * k
            yaw[i] += (targetYaw - yaw[i]) * k
            joints[i].eulerAngles = SCNVector3(pitch[i], yaw[i], 0)
            targetPitch = curlPitch
            targetYaw = curlYaw + (yaw[i] - (i == 0 ? baseYaw : curlYaw)) * 0.5
        }
    }
}

/// Shared model-building bits for both animals.
nonisolated enum AnimalBuild {
    /// An ellipsoid "volume" -- the basic muscle/skull/fat shape.
    @discardableResult
    static func blob(_ parent: SCNNode, _ c: SCNVector3, _ r: SCNVector3, _ m: SCNMaterial, segments: Int = 28) -> SCNNode {
        let s = SCNSphere(radius: 1)
        s.segmentCount = segments
        s.materials = [m]
        let n = SCNNode(geometry: s)
        n.position = c
        n.scale = r
        parent.addChildNode(n)
        return n
    }

    /// A tapered bone segment hanging down (-y) from `parent`'s origin, with a
    /// rounded joint at the top; returns the node at its far end.
    static func bone(_ parent: SCNNode, length: Float, top: Float, bottom: Float, _ m: SCNMaterial) -> SCNNode {
        let cone = SCNCone(topRadius: CGFloat(top), bottomRadius: CGFloat(bottom), height: CGFloat(length))
        cone.radialSegmentCount = 18
        cone.materials = [m]
        let n = SCNNode(geometry: cone)
        n.position = SCNVector3(0, -length / 2, 0)
        parent.addChildNode(n)
        blob(parent, SCNVector3Zero, SCNVector3(top * 1.05, top * 1.05, top * 1.05), m, segments: 16)
        let tip = SCNNode()
        tip.position = SCNVector3(0, -length, 0)
        parent.addChildNode(tip)
        return tip
    }

    static func gloss(_ color: UIColor, rough: CGFloat = 0.25) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = rough
        m.metalness.contents = 0.0
        return m
    }

    /// An eye: iris ball, pupil, a bright catch-light, and a furred lid that
    /// blinks (scale y 0.05 open -> 1 closed). Returns the lid.
    static func eye(_ parent: SCNNode, at p: SCNVector3, radius r: Float, iris: UIColor, slit: Bool, lid: SCNMaterial) -> SCNNode {
        let ball = blob(parent, p, SCNVector3(r, r, r), gloss(iris, rough: 0.12), segments: 20)
        let pupilScale = slit ? SCNVector3(0.22, 0.95, 0.35) : SCNVector3(0.55, 0.55, 0.35)
        blob(ball, SCNVector3(0, 0, -0.82), pupilScale, gloss(.black, rough: 0.1), segments: 14)
        let glint = SCNMaterial()
        glint.lightingModel = .constant
        glint.diffuse.contents = UIColor.white
        blob(ball, SCNVector3(0.3, 0.35, -0.86), SCNVector3(0.12, 0.12, 0.08), glint, segments: 8)
        let lidNode = blob(parent, p, SCNVector3(r * 1.06, r * 0.05, r * 1.06), lid, segments: 16)
        return lidNode
    }

    static func shadow(_ image: UIImage, width: CGFloat, length: CGFloat, to root: SCNNode) {
        let plane = SCNPlane(width: width, height: length)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let n = SCNNode(geometry: plane)
        n.eulerAngles.x = -.pi / 2
        n.position.y = 0.004
        n.renderingOrder = 1
        root.addChildNode(n)
    }
}

// MARK: - Voices (formant synthesis: a glottal pulse train through resonances)

nonisolated enum AnimalVoice {
    static let rate = MenagerieSound.rate

    struct Resonator {
        var y1: Float = 0, y2: Float = 0
        var a1: Float = 0, a2: Float = 0, g: Float = 0
        mutating func tune(_ f: Float, _ bw: Float) {
            let r = exp(-.pi * bw / AnimalVoice.rate)
            a1 = 2 * r * cos(2 * .pi * f / AnimalVoice.rate)
            a2 = -r * r
            g = 1 - r
        }
        mutating func run(_ x: Float) -> Float {
            let y = g * x + a1 * y1 + a2 * y2
            y2 = y1; y1 = y
            return y
        }
    }

    /// `f0(u)` pitch contour, `formants(u)` = [(freq, bandwidth, gain)], `breath`
    /// mixes noise into the source, `env(u)` shapes loudness (u = 0...1).
    static func voice(seconds: Float, breath: Float, rng: inout Rand, f0: (Float) -> Float,
                      formants: (Float) -> [(Float, Float, Float)], env: (Float) -> Float) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        var bank: [Resonator] = []
        var gains: [Float] = []
        var previous: Float = 0
        for i in 0..<n {
            let u = Float(i) / Float(n)
            if i % 64 == 0 {
                let fs = formants(u)
                if bank.count != fs.count { bank = Array(repeating: Resonator(), count: fs.count) }
                gains = fs.map { $0.2 }
                for (j, f) in fs.enumerated() { bank[j].tune(f.0, f.1) }
            }
            let jitter = 1 + (rng.unit() - 0.5) * 0.03
            phase += f0(u) * jitter / rate
            if phase >= 1 { phase -= 1 }
            let pulse = phase < 0.42 ? sin(.pi * phase / 0.42) : 0
            let excitation = (pulse - previous) * 6 * (1 - breath) + (rng.unit() * 2 - 1) * breath
            previous = pulse
            var v: Float = 0
            for j in bank.indices { v += bank[j].run(excitation) * gains[j] }
            out[i] = v * env(u)
        }
        return out
    }

    /// Filtered breath (no voicing): sniffs, pants, hisses.
    static func breathNoise(seconds: Float, centre: Float, width: Float, rng: inout Rand, env: (Float) -> Float) -> [Float] {
        let n = Int(seconds * rate)
        var r = Resonator()
        r.tune(centre, width)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = r.run(rng.unit() * 2 - 1) * env(Float(i) / Float(n)) * 4 }
        return out
    }

    static func attackDecay(_ attack: Float, _ decay: Float) -> (Float) -> Float {
        { u in min(1, u / attack) * exp(-max(0, u - attack) / decay) }
    }
}

// MARK: - Dog

nonisolated final class Dog: Critter {
    enum Mode: String { case wander, trot, sniff, look, watch, approach, sit, startled }
    private var mode: Mode = .look
    private var modeTime: Double = 0
    private var modeLength: Double = 3
    private var target: Habitat.Sighting?

    private let neck: SCNNode, head: SCNNode, jaw: SCNNode, ribs: SCNNode
    private let ribsScale: SCNVector3
    private let ears: [SCNNode]
    private let lids: [SCNNode]
    private let legs: [LegRig]          // LF, RF, LH, RH
    private let tail: TailRig

    private var gaitPhase: Float = 0, gaitMix: Float = 0, amplitude: Float = 0
    private var sitAmount: Float = 0, sniffAmount: Float = 0
    private var lookYaw: Float = 0, lookPitch: Float = 0, tilt: Float = 0, tiltTarget: Float = 0
    private var wag: Float = 0, tailHeight: Float = -0.25
    private var earPerk: Float = 0, earLag: [Float] = [0, 0], earVel: [Float] = [0, 0], lastHeadYaw: Float = 0
    private var blinkClock = Double.random(in: 1...4), blinkT: Float = -1
    private var jawOpen: Float = 0, barkT: Float = -1
    private var panting: Double = 0, pantClock: Double = 0
    private var sniffClock: Double = 0
    private var woofCooldown: Double = 10
    private var wanderLook: Float = 0
    private var breath: Float = 0

    private static let woofs: [SCNAudioSource] = (0..<3).compactMap { i in
        MenagerieSound.source("dog-woof-\(i)", volume: 0.8) {
            var rng = Rand(seed: UInt64(100 + i))
            let start = rng.range(150, 185), end = rng.range(95, 120)
            let body = AnimalVoice.voice(seconds: rng.range(0.18, 0.26), breath: 0.32, rng: &rng,
                f0: { u in start + (end - start) * u },
                formants: { u in [(560 - 120 * u, 140, 1), (1150, 170, 0.55), (2450, 260, 0.22), (3400, 400, 0.08)] },
                env: AnimalVoice.attackDecay(0.06, 0.35))
            let thump = MenagerieSound.strike([(rng.range(85, 100), 0.06, 1)], seconds: 0.15, rng: &rng)
            return MenagerieSound.mix([(0, thump, 0.5), (0.005, body, 1)])
        }
    }
    private static let whine = MenagerieSound.source("dog-whine", volume: 0.45) {
        var rng = Rand(seed: 7)
        return AnimalVoice.voice(seconds: 0.75, breath: 0.12, rng: &rng,
            f0: { u in (700 + 260 * sin(.pi * u * 0.9)) * (1 + 0.025 * sin(u * 40)) },
            formants: { _ in [(820, 90, 1), (1550, 110, 0.6), (2900, 200, 0.15)] },
            env: { u in sin(.pi * u) })
    }
    private static let sniffs: [SCNAudioSource] = (0..<3).compactMap { i in
        MenagerieSound.source("dog-sniff-\(i)", volume: 0.5) {
            var rng = Rand(seed: UInt64(40 + i))
            var parts: [(at: Float, samples: [Float], gain: Float)] = []
            var at: Float = 0
            for _ in 0..<Int(rng.range(2, 4.9)) {
                let burst = AnimalVoice.breathNoise(seconds: rng.range(0.04, 0.07), centre: rng.range(2200, 3200), width: 1600,
                                                    rng: &rng, env: { u in sin(.pi * u) })
                parts.append((at, burst, 1))
                at += rng.range(0.08, 0.11)
            }
            return MenagerieSound.mix(parts)
        }
    }
    private static let pant = MenagerieSound.source("dog-pant", volume: 0.4) {
        var rng = Rand(seed: 77)
        var parts: [(at: Float, samples: [Float], gain: Float)] = []
        for i in 0..<6 {
            let out = i % 2 == 0
            let burst = AnimalVoice.breathNoise(seconds: 0.11, centre: out ? 1250 : 950, width: 700, rng: &rng,
                                                env: { u in sin(.pi * u) * (out ? 1 : 0.6) })
            parts.append((Float(i) * 0.16, burst, 1))
        }
        return MenagerieSound.mix(parts)
    }
    private static let paws = MenagerieSound.variants("dog-paw", count: 5, volume: 0.18) { rng in
        let click = MenagerieSound.strike([(rng.range(3600, 4400), 0.004, 0.5), (rng.range(5600, 6400), 0.003, 0.3)],
                                          seconds: 0.02, noise: 0.4, noiseDecay: 0.0008, rng: &rng)
        let pad = MenagerieSound.strike([(rng.range(140, 180), 0.02, 0.4)], seconds: 0.05, noise: 0.5, noiseDecay: 0.004, rng: &rng)
        return MenagerieSound.mix([(0, pad, 1), (0.004, click, rng.range(0.3, 0.9))])
    }

    override var modeName: String { mode.rawValue }

    static func make(habitat: Habitat, cell: Int, skins: RealAnimalSkins, shadow: UIImage) -> (Critter, SCNNode) {
        let root = SCNNode()
        root.name = "dog"
        AnimalBuild.shadow(shadow, width: 0.55, length: 1.0, to: root)
        let coat = skins.dogCoat, saddle = skins.dogSaddle, cream = skins.dogCream
        let torso = SCNNode()
        torso.position = SCNVector3(0, 0.47, 0)
        root.addChildNode(torso)
        let B = AnimalBuild.self
        // Trunk volumes.
        B.blob(torso, SCNVector3(0, -0.005, -0.17), SCNVector3(0.125, 0.165, 0.17), coat)              // chest
        B.blob(torso, SCNVector3(0, -0.095, -0.19), SCNVector3(0.09, 0.09, 0.12), cream)               // brisket
        let ribs = B.blob(torso, SCNVector3(0, 0.0, -0.02), SCNVector3(0.13, 0.145, 0.2), coat)       // ribcage
        B.blob(torso, SCNVector3(0, -0.07, 0.07), SCNVector3(0.09, 0.075, 0.13), cream)                // belly / tuck
        B.blob(torso, SCNVector3(0, 0.025, 0.14), SCNVector3(0.105, 0.105, 0.13), coat)                // loin
        B.blob(torso, SCNVector3(0, 0.025, 0.245), SCNVector3(0.12, 0.115, 0.115), coat)               // croup
        B.blob(torso, SCNVector3(0, 0.085, 0.03), SCNVector3(0.1, 0.065, 0.27), saddle)               // dark saddle
        B.blob(torso, SCNVector3(0, 0.08, -0.2), SCNVector3(0.09, 0.07, 0.09), coat)                   // withers
        // Neck and head.
        let neck = SCNNode()
        neck.position = SCNVector3(0, 0.06, -0.27)
        torso.addChildNode(neck)
        B.blob(neck, SCNVector3(0, 0.09, 0), SCNVector3(0.075, 0.13, 0.085), coat)
        B.blob(neck, SCNVector3(0, 0.08, 0.025), SCNVector3(0.05, 0.12, 0.06), saddle)                 // mane line
        B.blob(neck, SCNVector3(0, 0.05, -0.04), SCNVector3(0.06, 0.1, 0.05), cream)                   // throat
        let head = SCNNode()
        head.position = SCNVector3(0, 0.2, 0)
        neck.addChildNode(head)
        B.blob(head, SCNVector3(0, 0.02, 0.005), SCNVector3(0.072, 0.068, 0.088), coat)                // skull
        B.blob(head, SCNVector3(0, 0.055, 0.01), SCNVector3(0.05, 0.035, 0.07), saddle)                // crown
        for side in [Float(-1), 1] {
            B.blob(head, SCNVector3(side * 0.045, -0.012, -0.025), SCNVector3(0.038, 0.04, 0.05), coat) // cheeks
            B.blob(head, SCNVector3(side * 0.034, 0.042, -0.06), SCNVector3(0.024, 0.012, 0.02), coat)  // brow
        }
        B.blob(head, SCNVector3(0, 0.005, -0.085), SCNVector3(0.036, 0.03, 0.07), coat)                // bridge
        B.blob(head, SCNVector3(0, -0.022, -0.105), SCNVector3(0.042, 0.038, 0.072), cream)            // muzzle
        B.blob(head, SCNVector3(0, -0.012, -0.165), SCNVector3(0.024, 0.02, 0.022), saddle)            // dark muzzle tip
        B.blob(head, SCNVector3(0, -0.004, -0.183), SCNVector3(0.019, 0.015, 0.012), B.gloss(UIColor(white: 0.05, alpha: 1), rough: 0.22))
        let jaw = SCNNode()
        jaw.position = SCNVector3(0, -0.045, -0.02)
        head.addChildNode(jaw)
        B.blob(jaw, SCNVector3(0, -0.006, -0.085), SCNVector3(0.03, 0.016, 0.075), cream)
        B.blob(jaw, SCNVector3(0, 0.004, -0.09), SCNVector3(0.02, 0.006, 0.06), B.gloss(UIColor(red: 0.85, green: 0.42, blue: 0.45, alpha: 1), rough: 0.35))
        var lids: [SCNNode] = []
        for side in [Float(-1), 1] {
            lids.append(B.eye(head, at: SCNVector3(side * 0.041, 0.024, -0.058), radius: 0.0155,
                              iris: UIColor(red: 0.28, green: 0.16, blue: 0.07, alpha: 1), slit: false, lid: coat))
        }
        var ears: [SCNNode] = []
        for side in [Float(-1), 1] {
            let ear = SCNNode()
            ear.position = SCNVector3(side * 0.048, 0.06, 0.02)
            head.addChildNode(ear)
            let cone = SCNCone(topRadius: 0.004, bottomRadius: 0.036, height: 0.1)
            cone.radialSegmentCount = 16
            cone.materials = [saddle]
            let flap = SCNNode(geometry: cone)
            flap.position = SCNVector3(0, 0.045, 0)
            flap.scale = SCNVector3(1, 1, 0.32)
            ear.addChildNode(flap)
            ears.append(ear)
        }
        // Legs.
        func leg(front: Bool, side: Float) -> LegRig {
            let joint = SCNNode()
            let jy: Float = front ? -0.06 : -0.03
            let jz: Float = front ? -0.19 : 0.225
            joint.position = SCNVector3(side * (front ? 0.072 : 0.07), jy, jz)
            torso.addChildNode(joint)
            let upper = SCNNode()
            joint.addChildNode(upper)
            if front {
                B.blob(upper, SCNVector3(0, -0.05, 0.01), SCNVector3(0.048, 0.1, 0.06), coat)          // shoulder/upper arm
            } else {
                B.blob(upper, SCNVector3(0, -0.07, 0.015), SCNVector3(0.058, 0.12, 0.08), coat)        // thigh
            }
            let a: Float = front ? 0.19 : 0.2, b: Float = front ? 0.2 : 0.21, c: Float = front ? 0.06 : 0.12
            let knee = B.bone(upper, length: a, top: front ? 0.036 : 0.042, bottom: front ? 0.028 : 0.03, coat)
            let lower = SCNNode()
            knee.addChildNode(lower)
            let ankle = B.bone(lower, length: b, top: front ? 0.026 : 0.028, bottom: front ? 0.021 : 0.019, front ? coat : coat)
            let end = SCNNode()
            ankle.addChildNode(end)
            let pawEnd = B.bone(end, length: c, top: 0.02, bottom: 0.018, cream)
            B.blob(pawEnd, SCNVector3(0, -0.004, -0.018), SCNVector3(0.026, 0.017, 0.036), cream)      // paw
            let offsets: Float = front ? (side < 0 ? 0.25 : 0.75) : (side < 0 ? 0 : 0.5)
            return LegRig(upper: upper, lower: lower, end: end, a: a, b: b, c: c, jointY: jy, jointZ: jz,
                          kneeForward: !front, endAngle: front ? 0.22 : 0.18, phaseOffset: offsets)
        }
        let legs = [leg(front: true, side: -1), leg(front: true, side: 1), leg(front: false, side: -1), leg(front: false, side: 1)]
        // Tail: six joints out of the croup, pointing back (+z).
        var joints: [SCNNode] = []
        var parent: SCNNode = torso
        var place = SCNVector3(0, 0.07, 0.34)
        for i in 0..<6 {
            let j = SCNNode()
            j.position = place
            parent.addChildNode(j)
            let r = CGFloat(0.022 - Float(i) * 0.0025)
            let seg = SCNCapsule(capRadius: r, height: 0.075)
            seg.materials = [i >= 4 ? saddle : coat]
            let n = SCNNode(geometry: seg)
            n.eulerAngles.x = .pi / 2
            n.position = SCNVector3(0, 0, 0.032)
            j.addChildNode(n)
            joints.append(j)
            parent = j
            place = SCNVector3(0, 0, 0.06)
        }
        let dog = Dog(habitat: habitat, node: root, torso: torso, cell: cell, neck: neck, head: head, jaw: jaw, ribs: ribs,
                      ears: ears, lids: lids, legs: legs, tail: TailRig(joints: joints))
        return (dog, root)
    }

    init(habitat: Habitat, node: SCNNode, torso: SCNNode, cell: Int, neck: SCNNode, head: SCNNode, jaw: SCNNode, ribs: SCNNode,
         ears: [SCNNode], lids: [SCNNode], legs: [LegRig], tail: TailRig) {
        self.neck = neck; self.head = head; self.jaw = jaw; self.ribs = ribs; self.ribsScale = ribs.scale
        self.ears = ears; self.lids = lids; self.legs = legs; self.tail = tail
        super.init(kind: .dog, habitat: habitat, node: node, body: torso, cell: cell)
        maxLane = 0.5
        personalSpace = 0.8
        acceleration = 2.2
        turnRate = 3.2
        senseInterval = 0.4
        modeLength = Double.random(in: 2...4)
    }

    private func set(_ m: Mode, for seconds: ClosedRange<Double>) {
        mode = m
        modeTime = 0
        modeLength = Double.random(in: seconds)
    }

    override func sense(now: CFTimeInterval) {
        woofCooldown = max(0, woofCooldown - senseInterval)
        // Something rushing right at it.
        for s in habitat.sightings where s.id != id && s.kind != .player {
            let d = simd_length(s.pos - pos)
            if d < 1.6, closingSpeed(s) > 2.0, mode != .startled {
                target = s
                set(.startled, for: 1.5...2.5)
                pause = 0
                if woofCooldown <= 0 { barkT = 0; say(Self.woofs.randomElement()); woofCooldown = 25 }
                return
            }
        }
        // Something interesting in view: maybe stop and watch it.
        let interesting: Set<Habitat.Kind> = [.noodle, .player, .cat, .clacker, .bobbin, .chair, .pottle, .ladder, .stalk]
        if mode == .wander || mode == .look || mode == .sit || mode == .sniff,
           case let (s, d)? = nearest(interesting, within: 7), d > 0.9, Float.random(in: 0...1) < 0.3,
           habitat.canSee(pos, s.pos, height: 0.5) {
            target = s
            set(.watch, for: 2...5)
            if s.kind == .player || s.kind == .noodle, Float.random(in: 0...1) < 0.35 { tiltTarget = Float.random(in: 0.22...0.38) * (Bool.random() ? 1 : -1) }
        }
        if let t = target, let fresh = habitat.sightings.first(where: { $0.id == t.id }) { target = fresh }
    }

    override func think(dt: Double, now: CFTimeInterval) {
        modeTime += dt
        let done = modeTime > modeLength
        lookAt = nil
        switch mode {
        case .wander:
            wantSpeed = 0.85
            goal = nil
            if done {
                let r = Float.random(in: 0...1)
                if r < 0.35 { set(.sniff, for: 2...5) }
                else if r < 0.62 { set(.look, for: 1.5...4) }
                else if r < 0.78 { set(.sit, for: 6...18) }
                else if r < 0.9 { set(.trot, for: 3...7) }
                else { set(.wander, for: 5...12) }
            }
        case .trot:
            wantSpeed = 1.9
            if done { panting = Double.random(in: 4...7); set(.look, for: 2...4) }
        case .sniff:
            wantSpeed = 0.22
            sniffClock -= dt
            if sniffClock <= 0 { sniffClock = Double.random(in: 0.7...1.6); say(Self.sniffs.randomElement(), loud: false) }
            if done { set(.wander, for: 5...12) }
        case .look:
            wantSpeed = 0
            if Float.random(in: 0...1) < Float(dt) * 0.6 { wanderLook = Float.random(in: -1.0...1.0) }
            if done { set(.wander, for: 5...12) }
        case .sit:
            wantSpeed = 0
            if Float.random(in: 0...1) < Float(dt) * 0.3 { wanderLook = Float.random(in: -0.9...0.9) }
            if done { set(.wander, for: 5...12) }
        case .watch, .startled:
            wantSpeed = 0
            lookAt = target?.pos
            if done {
                tiltTarget = 0
                if let t = target, mode == .watch, ([.noodle, .player, .cat, .clacker] as [Habitat.Kind]).contains(t.kind), Float.random(in: 0...1) < 0.45 {
                    set(.approach, for: 6...10)
                    goal = graph.cell(near: t.pos)
                } else {
                    set(.wander, for: 5...12)
                    if Float.random(in: 0...1) < 0.08, target?.kind == .player { say(Self.whine) }
                }
            }
        case .approach:
            wantSpeed = 0.8
            if let t = target {
                let d = simd_length(t.pos - pos)
                if d < 1.3 { wantSpeed = 0; goal = nil; lookAt = t.pos; set(.sniff, for: 1.5...3) }
                else { goal = graph.cell(near: t.pos) }
            }
            if done { goal = nil; set(.wander, for: 5...12) }
        }
        panting = max(0, panting - dt)
        if panting > 0 {
            pantClock -= dt
            if pantClock <= 0 { pantClock = 1.0; say(Self.pant, loud: false) }
        }
    }

    override func animate(dt: Float, moved: Float, turning: Float) {
        let t = Float(time)
        // Gait: walk (lateral sequence) blending into trot (diagonal pairs).
        let wantMix: Float = speed > 1.25 ? 1 : 0
        gaitMix += (wantMix - gaitMix) * min(1, dt * 2.5)
        let stride = 0.55 + 0.4 * gaitMix
        let duty = 0.63 - 0.18 * gaitMix
        let liftHeight = 0.05 + 0.035 * gaitMix
        let walkOffsets: [Float] = [0.25, 0.75, 0, 0.5]
        let trotOffsets: [Float] = [0, 0.5, 0.5, 0]
        gaitPhase += moved / stride + abs(turning) * dt * 0.12
        let wantAmp = min(1, max(speed / 0.35, abs(turning) / 1.2)) * (1 - sitAmount)
        amplitude += (wantAmp - amplitude) * min(1, dt * 5)

        // Postures blend continuously.
        sitAmount += ((mode == .sit ? 1 : 0) - sitAmount) * min(1, dt * 1.6)
        sniffAmount += ((mode == .sniff ? 1 : 0) - sniffAmount) * min(1, dt * 2.5)
        breath += dt * (panting > 0 ? 3.2 : 0.42) * 2 * .pi
        let breathe = sin(breath) * (panting > 0 ? 0.035 : 0.018)
        ribs.scale = SCNVector3(ribsScale.x * (1 + breathe), ribsScale.y * (1 + breathe), ribsScale.z)

        let bob = -0.012 * cos(gaitPhase * 4 * .pi) * amplitude * (1 - gaitMix) - 0.02 * abs(sin(gaitPhase * 2 * .pi)) * amplitude * gaitMix
        let h: Float = 0.47 - 0.17 * sitAmount + bob
        let pitch: Float = 0.55 * sitAmount - 0.04 * sniffAmount + 0.02 * sin(gaitPhase * 2 * .pi) * amplitude
        body.position.y = h
        body.eulerAngles = SCNVector3(pitch, 0, 0.03 * sin(gaitPhase * 2 * .pi) * amplitude)

        for (i, leg) in legs.enumerated() {
            let front = i < 2
            let offset = walkOffsets[i] + (trotOffsets[i] - walkOffsets[i]) * gaitMix
            let u = (gaitPhase + offset).truncatingRemainder(dividingBy: 1)
            let reach = stride * duty
            var forward: Float, lift: Float
            if u < duty { forward = reach * (0.5 - u / duty); lift = 0 }
            else { let s = (u - duty) / (1 - duty); forward = reach * (s - 0.5); lift = sin(.pi * s) * liftHeight }
            let planted = u < duty
            if planted && !leg.planted && amplitude > 0.4 { say(Self.paws.randomElement(), loud: false) }
            leg.planted = planted
            forward *= amplitude
            lift *= amplitude
            forward += front ? 0.025 + 0.03 * sitAmount : -0.02 + 0.2 * sitAmount
            leg.solve(torsoHeight: h, pitch: pitch, forward: forward, lift: lift, extraEnd: front ? 0 : 1.2 * sitAmount)
        }

        // Head: look target, sniffing, walk nod, curious tilt.
        var wantYaw: Float = wanderLook * (mode == .look || mode == .sit ? 1 : 0)
        var wantPitch: Float = 0
        if let p = lookAt ?? target.flatMap({ mode == .watch || mode == .startled ? $0.pos : nil }) {
            let to = p - pos
            var yaw = atan2(-to.x, -to.y) - heading
            while yaw > .pi { yaw -= 2 * .pi }
            while yaw < -.pi { yaw += 2 * .pi }
            wantYaw = max(-1.2, min(1.2, yaw))
            wantPitch = target?.kind == .player ? 0.25 : -0.1
        }
        lookYaw += (wantYaw - lookYaw) * min(1, dt * 3)
        lookPitch += (wantPitch - lookPitch) * min(1, dt * 3)
        tilt += (tiltTarget - tilt) * min(1, dt * 4)
        let nod = 0.05 * sin(gaitPhase * 4 * .pi) * amplitude * (1 - gaitMix)
        let neckX = -0.78 - 0.7 * sniffAmount + 0.3 * lookPitch + 0.25 * sitAmount
        neck.eulerAngles = SCNVector3(neckX - pitch * 0.3, lookYaw * 0.45, 0)
        let headWorld = lookPitch - 0.85 * sniffAmount + nod
        head.eulerAngles = SCNVector3(headWorld - (neckX - pitch * 0.3) - pitch, lookYaw * 0.55, tilt)

        // Ears: lag behind head turns, perk when watching.
        earPerk += ((mode == .watch || mode == .startled ? 1 : 0) - earPerk) * min(1, dt * 4)
        let headYawSpeed = (lookYaw - lastHeadYaw) / max(dt, 0.001)
        lastHeadYaw = lookYaw
        for (i, ear) in ears.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            let force = -earLag[i] * 60 - earVel[i] * 6 - headYawSpeed * 0.6 + (amplitude * sin(gaitPhase * 4 * .pi + Float(i)) * 3)
            earVel[i] += force * dt
            earLag[i] += earVel[i] * dt
            ear.eulerAngles = SCNVector3(-0.25 + 0.3 * earPerk + earLag[i] * 0.4, side * 0.1, side * (0.35 - 0.2 * earPerk) + earLag[i])
        }

        // Eyes blink now and then.
        blinkClock -= Double(dt)
        if blinkClock <= 0 { blinkClock = Double.random(in: 2.5...7); blinkT = 0 }
        var lid: Float = 0.05
        if blinkT >= 0 { blinkT += dt / 0.16; lid = blinkT < 1 ? 0.05 + 0.95 * sin(.pi * blinkT) : 0.05; if blinkT >= 1 { blinkT = -1 } }
        for l in lids { l.scale.y = l.scale.x * lid }

        // Jaw: barks, panting.
        var wantJaw: Float = panting > 0 ? 0.18 + 0.06 * sin(breath) : 0
        if barkT >= 0 { barkT += dt / 0.25; wantJaw = max(wantJaw, 0.35 * sin(.pi * min(1, barkT))); if barkT >= 1 { barkT = -1 } }
        jawOpen += (wantJaw - jawOpen) * min(1, dt * 14)
        jaw.eulerAngles.x = -jawOpen

        // Tail: carriage from mood, wag when watching/greeting, droops when sitting.
        let happy: Float = (mode == .watch || mode == .approach) && (target?.kind == .player || target?.kind == .noodle) ? 1 : 0
        wag += (happy * 0.9 + (mode == .wander ? 0.15 : 0) - wag) * min(1, dt * 2)
        let carriage: Float = mode == .startled ? -0.9 : (mode == .sniff ? -0.25 : -0.45)
        tailHeight += (carriage + 0.75 * sitAmount - tailHeight) * min(1, dt * 2)
        let wagAngle = sin(t * 2 * .pi * 2.6) * 0.55 * wag + sin(t * 1.3) * 0.05
        tail.update(dt: dt, basePitch: tailHeight, baseYaw: wagAngle, curlPitch: 0.12 + 0.15 * sitAmount, curlYaw: wagAngle * 0.3, stiffness: 9)
    }
}

// MARK: - Cat

nonisolated final class Cat: Critter {
    enum Mode: String { case prowl, pause, sit, groom, stretch, stalk, alert, flee }
    private var mode: Mode = .sit
    private var modeTime: Double = 0
    private var modeLength: Double = 6
    private var target: Habitat.Sighting?
    private var threat: SIMD2<Float>?

    private let neck: SCNNode, head: SCNNode, ribs: SCNNode
    private let ribsScale: SCNVector3
    private let chest: SCNNode, hips: SCNNode
    private let blades: [SCNNode]
    private let ears: [SCNNode]
    private let lids: [SCNNode]
    private let legs: [LegRig]          // LF, RF, LH, RH
    private let tail: TailRig

    private var gaitPhase: Float = 0, gaitMix: Float = 0, amplitude: Float = 0
    private var sitAmount: Float = 0, crouch: Float = 0, stretchAmount: Float = 0, groomAmount: Float = 0
    private var lookYaw: Float = 0, lookPitch: Float = 0, idleLook: Float = 0
    private var earYaw: Float = 0, earFlat: Float = 0, earTwitch: (index: Int, t: Float)?
    private var blinkClock = Double.random(in: 2...6), blinkT: Float = -1, blinkLength: Float = 0.14
    private var tailTwitch: Float = 0, tailSide: Float = 1
    private var breath: Float = 0
    private var voiceClock = Double.random(in: 25...60)
    private var chatterClock: Double = 0
    private var pounce: Double = 0

    private static let meows: [SCNAudioSource] = (0..<3).compactMap { i in
        MenagerieSound.source("cat-meow-\(i)", volume: 0.55) {
            var rng = Rand(seed: UInt64(300 + i))
            let peak = rng.range(700, 820), startF = rng.range(480, 560), endF = rng.range(380, 460)
            let length = rng.range(0.5, 0.75)
            return AnimalVoice.voice(seconds: length, breath: 0.1, rng: &rng,
                f0: { u in
                    let f = u < 0.35 ? startF + (peak - startF) * (u / 0.35) : peak + (endF - peak) * ((u - 0.35) / 0.65)
                    return f * (1 + 0.018 * sin(u * 34))
                },
                formants: { u in
                    // "mi" -> "a" -> "ow": first two formants open then close.
                    let open = sin(.pi * min(1, u * 1.3))
                    let f1 = 380 + 520 * open - 120 * max(0, u - 0.6)
                    let f2 = 2100 - 700 * u - 300 * open
                    return [(f1, 110, 1), (f2, 160, 0.55), (3200, 300, 0.18), (4400, 500, 0.06)]
                },
                env: { u in min(1, u / 0.08) * min(1, (1 - u) / 0.25) })
        }
    }
    private static let chirp = MenagerieSound.source("cat-chirp", volume: 0.45) {
        var rng = Rand(seed: 31)
        return AnimalVoice.voice(seconds: 0.22, breath: 0.1, rng: &rng,
            f0: { u in 620 + 380 * u },
            formants: { _ in [(560, 120, 1), (1900, 180, 0.5), (3300, 300, 0.15)] },
            env: { u in sin(.pi * u) * (0.6 + 0.4 * sin(u * 2 * .pi * 6)) })
    }
    private static let chatter = MenagerieSound.source("cat-chatter", volume: 0.4) {
        var rng = Rand(seed: 33)
        var parts: [(at: Float, samples: [Float], gain: Float)] = []
        var at: Float = 0
        for _ in 0..<8 {
            let click = MenagerieSound.strike([(rng.range(2200, 2800), 0.008, 0.6), (rng.range(4000, 4800), 0.004, 0.3)],
                                              seconds: 0.03, noise: 0.5, noiseDecay: 0.002, rng: &rng)
            parts.append((at, click, rng.range(0.6, 1)))
            at += rng.range(0.065, 0.085)
        }
        let squeak = AnimalVoice.voice(seconds: 0.12, breath: 0.2, rng: &rng, f0: { u in 900 + 300 * u },
                                       formants: { _ in [(700, 150, 1), (2100, 200, 0.4)] }, env: { u in sin(.pi * u) })
        parts.append((at, squeak, 0.6))
        return MenagerieSound.mix(parts)
    }
    private static let purr = MenagerieSound.source("cat-purr", volume: 0.5) {
        var rng = Rand(seed: 35)
        return AnimalVoice.voice(seconds: 1.6, breath: 0.45, rng: &rng,
            f0: { _ in 26 },
            formants: { _ in [(260, 160, 1), (750, 260, 0.4)] },
            env: { u in (0.55 + 0.45 * sin(u * 2 * .pi * 1.25 - .pi / 2)) * min(1, u / 0.1) * min(1, (1 - u) / 0.15) })
    }
    private static let pads = MenagerieSound.variants("cat-pad", count: 4, volume: 0.08) { rng in
        AnimalVoice.breathNoise(seconds: 0.03, centre: rng.range(500, 800), width: 900, rng: &rng, env: { u in exp(-u * 5) })
    }

    override var modeName: String { mode.rawValue }

    static func make(habitat: Habitat, cell: Int, skins: RealAnimalSkins, shadow: UIImage) -> (Critter, SCNNode) {
        let root = SCNNode()
        root.name = "cat"
        AnimalBuild.shadow(shadow, width: 0.3, length: 0.55, to: root)
        let tabby = skins.catTabby, white = skins.catWhite, dark = skins.catDark
        let B = AnimalBuild.self
        let torso = SCNNode()
        torso.position = SCNVector3(0, 0.235, 0)
        root.addChildNode(torso)
        // A flexible trunk: chest and hips each turn a little on their own.
        let chest = SCNNode()
        chest.position = SCNVector3(0, 0, -0.08)
        torso.addChildNode(chest)
        let hips = SCNNode()
        hips.position = SCNVector3(0, 0, 0.09)
        torso.addChildNode(hips)
        B.blob(chest, SCNVector3(0, 0.0, -0.02), SCNVector3(0.06, 0.075, 0.085), tabby)
        B.blob(chest, SCNVector3(0, -0.05, -0.04), SCNVector3(0.045, 0.04, 0.06), white)              // white bib
        let ribs = B.blob(torso, SCNVector3(0, 0.005, 0.0), SCNVector3(0.065, 0.07, 0.11), tabby)
        B.blob(torso, SCNVector3(0, -0.04, 0.04), SCNVector3(0.05, 0.045, 0.09), white)               // belly
        B.blob(hips, SCNVector3(0, 0.01, 0.02), SCNVector3(0.06, 0.068, 0.07), tabby)                  // haunches
        var blades: [SCNNode] = []
        for side in [Float(-1), 1] {
            blades.append(B.blob(chest, SCNVector3(side * 0.033, 0.055, -0.02), SCNVector3(0.028, 0.03, 0.045), tabby))
        }
        // Neck, head.
        let neck = SCNNode()
        neck.position = SCNVector3(0, 0.035, -0.17)
        torso.addChildNode(neck)
        B.blob(neck, SCNVector3(0, 0.035, 0), SCNVector3(0.042, 0.06, 0.045), tabby)
        B.blob(neck, SCNVector3(0, 0.02, -0.025), SCNVector3(0.032, 0.05, 0.03), white)
        let head = SCNNode()
        head.position = SCNVector3(0, 0.075, 0)
        neck.addChildNode(head)
        B.blob(head, SCNVector3(0, 0.012, 0.0), SCNVector3(0.048, 0.043, 0.047), tabby)                // round skull
        for side in [Float(-1), 1] {
            B.blob(head, SCNVector3(side * 0.03, -0.01, -0.022), SCNVector3(0.03, 0.026, 0.03), tabby)   // cheeks
            B.blob(head, SCNVector3(side * 0.012, -0.02, -0.046), SCNVector3(0.014, 0.012, 0.012), white) // whisker pads
        }
        B.blob(head, SCNVector3(0, -0.032, -0.036), SCNVector3(0.014, 0.008, 0.013), white)             // chin
        B.blob(head, SCNVector3(0, -0.007, -0.054), SCNVector3(0.007, 0.005, 0.004), B.gloss(UIColor(red: 0.85, green: 0.5, blue: 0.52, alpha: 1), rough: 0.35))
        B.blob(head, SCNVector3(0, 0.03, -0.032), SCNVector3(0.02, 0.012, 0.018), dark)                 // forehead "M"
        var lids: [SCNNode] = []
        for side in [Float(-1), 1] {
            lids.append(B.eye(head, at: SCNVector3(side * 0.021, 0.008, -0.039), radius: 0.0125,
                              iris: UIColor(red: 0.78, green: 0.62, blue: 0.16, alpha: 1), slit: true, lid: tabby))
        }
        // Whiskers.
        let whiskerMat = SCNMaterial()
        whiskerMat.lightingModel = .constant
        whiskerMat.diffuse.contents = UIColor(white: 0.96, alpha: 0.75)
        for side in [Float(-1), 1] {
            for k in 0..<3 {
                let w = SCNCylinder(radius: 0.0006, height: 0.075)
                w.materials = [whiskerMat]
                let n = SCNNode(geometry: w)
                n.position = SCNVector3(side * 0.04, -0.018 + Float(k) * 0.004, -0.044)
                n.eulerAngles = SCNVector3(0.1 * Float(k - 1), 0, side * (Float.pi / 2 - 0.15 + 0.12 * Float(k)))
                head.addChildNode(n)
            }
        }
        var ears: [SCNNode] = []
        let pink = B.gloss(UIColor(red: 0.85, green: 0.6, blue: 0.6, alpha: 1), rough: 0.7)
        for side in [Float(-1), 1] {
            let ear = SCNNode()
            ear.position = SCNVector3(side * 0.028, 0.04, -0.002)
            head.addChildNode(ear)
            let outer = SCNCone(topRadius: 0.002, bottomRadius: 0.024, height: 0.046)
            outer.radialSegmentCount = 16
            outer.materials = [tabby]
            let o = SCNNode(geometry: outer)
            o.position = SCNVector3(0, 0.02, 0)
            o.scale = SCNVector3(1, 1, 0.42)
            ear.addChildNode(o)
            let inner = SCNCone(topRadius: 0.001, bottomRadius: 0.017, height: 0.036)
            inner.materials = [pink]
            let n = SCNNode(geometry: inner)
            n.position = SCNVector3(0, 0.017, -0.006)
            n.scale = SCNVector3(1, 1, 0.25)
            ear.addChildNode(n)
            ears.append(ear)
        }
        func leg(front: Bool, side: Float) -> LegRig {
            let joint = SCNNode()
            let jy: Float = front ? -0.03 : -0.015
            let jz: Float = front ? -0.11 : 0.12
            joint.position = SCNVector3(side * 0.035, jy, jz)
            torso.addChildNode(joint)
            let upper = SCNNode()
            joint.addChildNode(upper)
            if front {
                B.blob(upper, SCNVector3(0, -0.035, 0.005), SCNVector3(0.024, 0.05, 0.03), tabby)
            } else {
                B.blob(upper, SCNVector3(0, -0.04, 0.012), SCNVector3(0.03, 0.06, 0.042), tabby)
            }
            let a: Float = front ? 0.1 : 0.11, b: Float = front ? 0.1 : 0.12, c: Float = front ? 0.035 : 0.07
            let knee = B.bone(upper, length: a, top: 0.02, bottom: 0.015, tabby)
            let lower = SCNNode()
            knee.addChildNode(lower)
            let ankle = B.bone(lower, length: b, top: 0.014, bottom: 0.011, tabby)
            let end = SCNNode()
            ankle.addChildNode(end)
            let pawEnd = B.bone(end, length: c, top: 0.011, bottom: 0.01, white)
            B.blob(pawEnd, SCNVector3(0, -0.003, -0.008), SCNVector3(0.014, 0.009, 0.018), white)
            let offsets: Float = front ? (side < 0 ? 0.25 : 0.75) : (side < 0 ? 0 : 0.5)
            return LegRig(upper: upper, lower: lower, end: end, a: a, b: b, c: c, jointY: jy, jointZ: jz,
                          kneeForward: !front, endAngle: front ? 0.18 : 0.25, phaseOffset: offsets)
        }
        let legs = [leg(front: true, side: -1), leg(front: true, side: 1), leg(front: false, side: -1), leg(front: false, side: 1)]
        var joints: [SCNNode] = []
        var parent: SCNNode = hips
        var place = SCNVector3(0, 0.03, 0.08)
        for i in 0..<10 {
            let j = SCNNode()
            j.position = place
            parent.addChildNode(j)
            let r = CGFloat(0.0135 - Float(i) * 0.0006)
            let seg = SCNCapsule(capRadius: r, height: 0.042)
            seg.materials = [i == 9 ? dark : tabby]
            let n = SCNNode(geometry: seg)
            n.eulerAngles.x = .pi / 2
            n.position = SCNVector3(0, 0, 0.016)
            j.addChildNode(n)
            joints.append(j)
            parent = j
            place = SCNVector3(0, 0, 0.032)
        }
        let cat = Cat(habitat: habitat, node: root, torso: torso, cell: cell, neck: neck, head: head, ribs: ribs, chest: chest,
                      hips: hips, blades: blades, ears: ears, lids: lids, legs: legs, tail: TailRig(joints: joints))
        return (cat, root)
    }

    init(habitat: Habitat, node: SCNNode, torso: SCNNode, cell: Int, neck: SCNNode, head: SCNNode, ribs: SCNNode, chest: SCNNode,
         hips: SCNNode, blades: [SCNNode], ears: [SCNNode], lids: [SCNNode], legs: [LegRig], tail: TailRig) {
        self.neck = neck; self.head = head; self.ribs = ribs; self.ribsScale = ribs.scale
        self.chest = chest; self.hips = hips; self.blades = blades
        self.ears = ears; self.lids = lids; self.legs = legs; self.tail = tail
        super.init(kind: .cat, habitat: habitat, node: node, body: torso, cell: cell)
        maxLane = 0.7
        personalSpace = 0.5
        acceleration = 3
        turnRate = 3.5
        senseInterval = 0.3
        sitAmount = 1
        tailSide = Bool.random() ? 1 : -1
    }

    private func set(_ m: Mode, for seconds: ClosedRange<Double>) {
        mode = m
        modeTime = 0
        modeLength = Double.random(in: seconds)
    }

    override func sense(now: CFTimeInterval) {
        // Too close, or the dog anywhere near: away.
        if mode != .flee {
            for s in habitat.sightings where s.id != id {
                let d = simd_length(s.pos - pos)
                let wary: Float = s.kind == .dog ? 2.4 : 1.2
                let big: Set<Habitat.Kind> = [.dog, .noodle, .player, .ladder, .chair, .stalk]
                if big.contains(s.kind), d < wary, closingSpeed(s) > 0.2 || d < 0.7 {
                    threat = s.pos
                    set(.flee, for: 2.5...4)
                    pause = 0
                    if simd_dot(direction, s.pos - pos) > 0 { reverse() }
                    return
                }
            }
        }
        // Something approaching at a distance: freeze and watch it.
        if mode == .prowl || mode == .pause || mode == .sit || mode == .groom,
           case let (s, d)? = nearest([.dog, .noodle, .player, .ladder, .chair, .bobbin], within: 3.5),
           closingSpeed(s) > 0.4, d > 1.2, habitat.canSee(pos, s.pos, height: 0.25) {
            target = s
            set(.alert, for: 1...2.5)
            return
        }
        // Small fluttery things: stalk them.
        if mode == .prowl || mode == .pause,
           case let (s, d)? = nearest([.clacker, .bobbin], within: 6), d > 1.6, habitat.canSee(pos, s.pos, height: 0.2),
           Float.random(in: 0...1) < 0.35 {
            target = s
            set(.stalk, for: 6...12)
            say(Self.chirp)
            goal = graph.cell(near: s.pos)
        }
        if let t = target, let fresh = habitat.sightings.first(where: { $0.id == t.id }) { target = fresh }
        // Ears follow the most recent sound.
        if let heard = habitat.sounds.last(where: { $0.id != id && now - $0.time < 1.5 }) {
            let to = heard.pos - pos
            var yaw = atan2(-to.x, -to.y) - heading - lookYaw
            while yaw > .pi { yaw -= 2 * .pi }
            while yaw < -.pi { yaw += 2 * .pi }
            earYaw = max(-0.7, min(0.7, yaw * 0.5))
        }
    }

    override func think(dt: Double, now: CFTimeInterval) {
        modeTime += dt
        let done = modeTime > modeLength
        lookAt = nil
        switch mode {
        case .prowl:
            wantSpeed = 0.42
            goal = nil
            if done {
                let r = Float.random(in: 0...1)
                if r < 0.4 { set(.pause, for: 1.5...4) } else if r < 0.75 { set(.sit, for: 8...22) } else { set(.prowl, for: 5...10) }
            }
        case .pause:
            wantSpeed = 0
            if Float.random(in: 0...1) < Float(dt) * 0.5 { idleLook = Float.random(in: -1.1...1.1) }
            if done { set(.prowl, for: 5...12) }
        case .sit:
            wantSpeed = 0
            if Float.random(in: 0...1) < Float(dt) * 0.25 { idleLook = Float.random(in: -1.0...1.0) }
            if modeTime > 3, Float.random(in: 0...1) < Float(dt) * 0.08 { set(.groom, for: 3...7) }
            if let close = nearest([.player, .noodle], within: 1.6), close.1 > 0.7, Float.random(in: 0...1) < Float(dt) * 0.05 {
                say(Self.purr, loud: false)
            }
            if done {
                if Float.random(in: 0...1) < 0.45 { set(.stretch, for: 2.2...3.2) } else { set(.prowl, for: 5...12) }
            }
        case .groom:
            wantSpeed = 0
            if done { set(.sit, for: 4...12) }
        case .stretch:
            wantSpeed = 0
            if done { set(.prowl, for: 5...12) }
        case .stalk:
            wantSpeed = 0.22
            if let t = target {
                let d = simd_length(t.pos - pos)
                lookAt = t.pos
                if d < 1.6 {
                    wantSpeed = 0
                    goal = nil
                    chatterClock -= dt
                    if chatterClock <= 0 { chatterClock = Double.random(in: 2...4); say(Self.chatter, loud: false) }
                    if pounce <= 0, modeTime > 3, Float.random(in: 0...1) < Float(dt) * 0.4 { pounce = 0.45 }
                } else { goal = graph.cell(near: t.pos) }
            }
            if pounce > 0 { pounce -= dt; wantSpeed = 1.6 }
            if done { goal = nil; set(.pause, for: 1...3) }
        case .alert:
            wantSpeed = 0
            lookAt = target?.pos
            if done { set(.prowl, for: 4...9) }
        case .flee:
            wantSpeed = 1.7
            goal = nil
            if done { set(.pause, for: 1...3); threat = nil }
        }
        voiceClock -= dt
        if voiceClock <= 0 {
            voiceClock = Double.random(in: 40...100)
            if mode == .sit || mode == .pause, nearest([.player, .noodle], within: 5) != nil { say(Self.meows.randomElement()) }
        }
    }

    override func choose(options: [Int]) -> Int {
        if mode == .flee, let threat { return choice(options, awayFrom: threat) }
        return roamChoice(options)
    }

    override func giveWay(to other: Habitat.Sighting) {
        pause = Double.random(in: 0.4...1.2)
        if Float.random(in: 0...1) < 0.5 { reverse() }
    }

    override func animate(dt: Float, moved: Float, turning: Float) {
        let t = Float(time)
        let wantMix: Float = speed > 1.0 ? 1 : 0
        gaitMix += (wantMix - gaitMix) * min(1, dt * 3)
        let stride = 0.3 + 0.32 * gaitMix
        let duty = 0.66 - 0.24 * gaitMix
        let liftHeight = 0.028 + 0.025 * gaitMix
        let walkOffsets: [Float] = [0.25, 0.75, 0, 0.5]
        let runOffsets: [Float] = [0, 0.5, 0.5, 0]
        gaitPhase += moved / stride + abs(turning) * dt * 0.1
        let postureHold = max(sitAmount, max(groomAmount, stretchAmount))
        let wantAmp = min(1, max(speed / 0.2, abs(turning) / 1.0)) * (1 - postureHold)
        amplitude += (wantAmp - amplitude) * min(1, dt * 5)

        let sitting = mode == .sit || mode == .groom
        sitAmount += ((sitting ? 1 : 0) - sitAmount) * min(1, dt * 1.4)
        groomAmount += ((mode == .groom ? 1 : 0) - groomAmount) * min(1, dt * 2)
        stretchAmount += ((mode == .stretch ? 1 : 0) - stretchAmount) * min(1, dt * 1.5)
        let wantCrouch: Float = mode == .stalk ? 1 : (mode == .alert ? 0.6 : 0)
        crouch += (wantCrouch - crouch) * min(1, dt * 3)
        breath += dt * (sitting ? 0.35 : 0.5) * 2 * .pi
        let breathe = sin(breath) * 0.022
        ribs.scale = SCNVector3(ribsScale.x * (1 + breathe), ribsScale.y * (1 + breathe), ribsScale.z)

        // Body carriage: low and level when stalking, haunches down when
        // sitting, rump high and chest low when stretching.
        let bob = -0.006 * cos(gaitPhase * 4 * .pi) * amplitude
        let h = 0.235 - 0.07 * crouch - 0.085 * sitAmount - 0.04 * stretchAmount + bob
        let pitch = 0.62 * sitAmount - 0.32 * stretchAmount
        body.position.y = h
        body.eulerAngles = SCNVector3(pitch, 0, 0)
        // Spine flex: chest and hips counter-turn with the gait and into turns.
        let flex = sin(gaitPhase * 2 * .pi) * 0.07 * amplitude + max(-0.3, min(0.3, turning * 0.12))
        chest.eulerAngles = SCNVector3(0, flex, 0)
        hips.eulerAngles = SCNVector3(0, -flex * 0.8, 0)

        for (i, leg) in legs.enumerated() {
            let front = i < 2
            let offset = walkOffsets[i] + (runOffsets[i] - walkOffsets[i]) * gaitMix
            let u = (gaitPhase + offset).truncatingRemainder(dividingBy: 1)
            let reach = stride * duty
            var forward: Float, lift: Float
            if u < duty { forward = reach * (0.5 - u / duty); lift = 0 }
            else { let s = (u - duty) / (1 - duty); forward = reach * (s - 0.5); lift = sin(.pi * s) * liftHeight }
            let planted = u < duty
            if planted && !leg.planted && amplitude > 0.5 && Float.random(in: 0...1) < 0.6 { say(Self.pads.randomElement(), loud: false) }
            leg.planted = planted
            forward *= amplitude
            lift *= amplitude
            var extra: Float = 0
            if front {
                forward += 0.01 + 0.02 * sitAmount + 0.13 * stretchAmount
                // Grooming: one forepaw comes up to the face, again and again.
                if i == 0, groomAmount > 0.01 {
                    let lick = 0.5 + 0.5 * sin(t * 7)
                    lift += groomAmount * (0.1 + 0.02 * lick)
                    forward += groomAmount * 0.03
                    extra = groomAmount * 1.1
                }
            } else {
                forward += -0.015 + 0.1 * sitAmount - 0.02 * stretchAmount
                extra = 1.3 * sitAmount
            }
            leg.solve(torsoHeight: h, pitch: pitch, forward: forward, lift: lift, extraEnd: extra)
            if front {
                // Shoulder blades ride up as each foreleg takes weight.
                let blade = blades[i]
                blade.position.y = 0.055 + (planted ? 0.008 : 0) * amplitude + 0.01 * crouch
            }
        }

        // Head: steady while walking (cats keep the head level), looks about,
        // locks on when stalking or alert, dips to the paw when grooming.
        var wantYaw = (mode == .pause || mode == .sit) ? idleLook : 0
        var wantPitch: Float = 0
        if let p = lookAt {
            let to = p - pos
            var yaw = atan2(-to.x, -to.y) - heading
            while yaw > .pi { yaw -= 2 * .pi }
            while yaw < -.pi { yaw += 2 * .pi }
            wantYaw = max(-1.3, min(1.3, yaw))
            wantPitch = -0.05
        }
        if groomAmount > 0.5 { wantYaw = -0.25; wantPitch = -0.55 - 0.15 * sin(t * 7) }
        lookYaw += (wantYaw - lookYaw) * min(1, dt * (mode == .stalk || mode == .alert ? 6 : 2.5))
        lookPitch += (wantPitch - lookPitch) * min(1, dt * 4)
        let neckX = -0.6 + 0.35 * sitAmount + 0.25 * crouch - 0.2 * stretchAmount
        neck.eulerAngles = SCNVector3(neckX, lookYaw * 0.4, 0)
        let headWorld = lookPitch - 0.15 * crouch
        head.eulerAngles = SCNVector3(headWorld - neckX - pitch, lookYaw * 0.6, 0)

        // Ears: towards sounds, forward when stalking, flattened when fleeing, twitches.
        let wantFlat: Float = mode == .flee ? 1 : 0
        earFlat += (wantFlat - earFlat) * min(1, dt * 6)
        if earTwitch == nil, Float.random(in: 0...1) < dt * 0.25 { earTwitch = (Int.random(in: 0..<2), 0) }
        for (i, ear) in ears.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            var twitch: Float = 0
            if let e = earTwitch, e.index == i { twitch = sin(e.t * .pi) * 0.5 }
            let forwardLock: Float = mode == .stalk || mode == .alert ? 0.25 : 0
            ear.eulerAngles = SCNVector3(-0.1 + forwardLock - 0.9 * earFlat, earYaw * 0.8 + side * twitch, side * (0.22 + 0.9 * earFlat))
        }
        if var e = earTwitch { e.t += dt / 0.2; earTwitch = e.t >= 1 ? nil : e }
        earYaw *= max(0, 1 - dt * 0.4)

        // Blinks; now and then a slow one when sitting near company.
        blinkClock -= Double(dt)
        if blinkClock <= 0 {
            blinkClock = Double.random(in: 3...9)
            blinkT = 0
            blinkLength = sitting && nearest([.player, .noodle], within: 3) != nil && Float.random(in: 0...1) < 0.5 ? 0.9 : 0.14
        }
        var lid: Float = mode == .sit ? 0.35 : 0.05
        if blinkT >= 0 { blinkT += dt / blinkLength; lid = max(lid, blinkT < 1 ? sin(.pi * blinkT) : 0); if blinkT >= 1 { blinkT = -1 } }
        for l in lids { l.scale.y = l.scale.x * max(0.05, lid) }

        // Tail: up with a hooked tip when walking, low and twitching when
        // stalking, wrapped round the feet when sitting, straight out in flight.
        var base: Float = -1.25, curl: Float = 0.22, curlYaw: Float = 0, yaw: Float = sin(t * 0.9) * 0.12
        if mode == .stalk || mode == .alert { base = 0.15; curl = -0.05; tailTwitch = sin(t * 9) * 0.5 }
        else { tailTwitch *= max(0, 1 - dt * 3) }
        if mode == .flee { base = -0.15; curl = 0.02 }
        if sitAmount > 0.3 {
            base = base + (1.35 - base) * sitAmount
            curl = 0.03
            curlYaw = tailSide * 0.32 * sitAmount
            yaw = tailSide * 0.5 * sitAmount
        }
        if stretchAmount > 0.3 { base = -0.6 }
        tail.update(dt: dt, basePitch: base, baseYaw: yaw, curlPitch: curl, curlYaw: curlYaw + tailTwitch * 0.3, stiffness: 5)
    }
}
