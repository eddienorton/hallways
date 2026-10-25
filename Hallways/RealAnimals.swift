//
//  RealAnimals.swift
//  Hallways
//
//  Oct 3 -- began as a calibration experiment: a procedural dog and cat.
//  Oct 19 (Stage A, final cast): the Dog and the Cat are retired for good, with
//  their install, skins and leg/tail rigs. What stays here is shared by the
//  surviving cast: AnimalBuild (primitive-building helpers) and AnimalVoice
//  (formant-synthesised voices) -- used by the Frog and the Slinky
//  (Audition.swift), the meeting's voices (ConferenceMeeting) and the
//  conference audition.
//

import SceneKit
import UIKit
import simd

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
    /// Oct 12 (Telephone voice audition): `jitter` (cycle-to-cycle pitch
    /// roughness -- the rasp) and `openQuotient` (how much of each cycle the
    /// glottal pulse fills: lower = brighter/buzzier, higher = smoother) were
    /// fixed at 0.03 and 0.42; those stay the defaults, so every existing
    /// voice renders exactly as before.
    static func voice(seconds: Float, breath: Float, jitter: Float = 0.03, openQuotient: Float = 0.42,
                      rng: inout Rand, f0: (Float) -> Float,
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
            let wobble = 1 + (rng.unit() - 0.5) * jitter
            phase += f0(u) * wobble / rate
            if phase >= 1 { phase -= 1 }
            let pulse = phase < openQuotient ? sin(.pi * phase / openQuotient) : 0
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
