//
//  Freddy.swift
//  Hallways
//
//  Oct 4 -- FIRST GAMEPLAY VERTICAL SLICE: Freddy the fire extinguisher.
//
//  A living wall extinguisher (same red, same black valve head, hose and
//  nozzle as HallwayScene.makeFireExtinguisherNode), off the wall and on the
//  move. He gets around the way a heavy cylinder would: rocking from one rim
//  of his base to the other and pivoting forward on it -- a clanking waddle,
//  faster and sillier when he hurries. His pressure gauge is his face: the
//  needle is how he feels.
//
//  Skill: when he is following and sees a burning fire, he goes to it on his
//  own, plants himself, aims his hose and sprays it out (the fire's own
//  knock-down in TapNavigationController.creatureExtinguishFire), then comes
//  back. He is not used up.
//
//  Follow / stay / elevator: see Posse.swift (he is the first PosseMember and
//  uses the shared FollowLeash).
//

import SceneKit
import UIKit
import simd

// MARK: - Install

enum Freddy {
    nonisolated static let memberID = "freddy"
    static let scale: Float = 1.1

    /// Builds him on this floor if the posse says he is here.
    static func install(context: Posse.FloorContext, placement: Posse.Placement?) -> FreddyDriver? {
        let tracePhase = ElevatorArrivalTrace.shared.beginPhase("Freddy.install")
        defer { ElevatorArrivalTrace.shared.endPhase("Freddy.install", tracePhase) }
        guard let placement else { return nil }
        let traceModel = ElevatorArrivalTrace.shared.beginPhase("Freddy.modelAndMaterials")
        let parts = FreddyModel.make(shadow: Menagerie.shadowImage(), puff: puffImage())
        parts.root.scale = SCNVector3(scale, scale, scale)
        // Oct 6 (Cast stage 1): his own identity and his own category bit
        // (he used to borrow Jeff's); every probe still looks through him.
        parts.root.enumerateHierarchy { n, _ in n.categoryBitMask = CritterCategory.freddy }
        CritterTags.tag(parts.root, as: .freddy)
        context.scene.rootNode.addChildNode(parts.root)

        ElevatorArrivalTrace.shared.endPhase("Freddy.modelAndMaterials", traceModel)
        let traceDriver = ElevatorArrivalTrace.shared.beginPhase("Freddy.driverAndLeash")
        let leash = FollowLeash(playerCamera: context.playerCamera, root: context.scene.rootNode,
                                cells: context.cells, cellSize: context.cellSize)
        leash.diagLabel = memberID                               // Oct 8: flight recorder label
        let fires = context.fires.map { (coord: $0.key, node: $0.value) }
        let extinguish = context.extinguish
        let driver = FreddyDriver(parts: parts, leash: leash, sceneRoot: context.scene.rootNode, fires: fires,
                                  puff: puffImage()) { @Sendable coord in
            DispatchQueue.main.async { _ = MainActor.assumeIsolated { extinguish(coord) } }
        }
        ElevatorArrivalTrace.shared.endPhase("Freddy.driverAndLeash", traceDriver)
        let traceSounds = ElevatorArrivalTrace.shared.beginPhase("Freddy.sounds")
        driver.sounds = FreddySound.make()
        ElevatorArrivalTrace.shared.endPhase("Freddy.sounds", traceSounds)
        switch placement {
        case .besidePlayer:
            // The camera's model pose (the arrival pose was just set; its
            // presentation catches up on the next frame).
            let eye = context.playerCamera.worldPosition
            let yaw = context.playerCamera.eulerAngles.y
            let player = SIMD2<Float>(eye.x, eye.z)
            let forward = SIMD2<Float>(-sin(yaw), -cos(yaw))
            let right = SIMD2<Float>(-forward.y, forward.x)
            let spot = leash.onGrid(player) ? player + forward * 0.5 + right * 0.7
                                            : player + forward * leash.cabAhead + right * leash.cabSide
            driver.place(at: leash.clear(player, spot) ? spot : player - forward * 0.6, yaw: atan2(forward.x, forward.y))
            driver.startFollowing()
        case .at(let home, let yaw):
            driver.place(at: home, yaw: yaw)
        }
        parts.root.runAction(.repeatForever(driver.tickAction()), forKey: "freddyTick")
        diag("freddy.installed", ["following": driver.isFollowing, "admissionPending": Admission.isPending])
        return driver
    }

    static func puffImage() -> UIImage {
        let size = CGSize(width: 32, height: 32)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(white: 1, alpha: 0.9).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let c = CGPoint(x: 16, y: 16)
            context.cgContext.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: 16, options: [])
        }
    }
}

// MARK: - Model

nonisolated struct FreddyParts {
    let root: SCNNode
    let rock: SCNNode        // the whole body, pivoted onto a rim of the base
    let head: SCNNode        // valve head: looks around
    let needle: SCNNode      // gauge needle: mood
    let lever: SCNNode       // squeeze lever
    let hose: [SCNNode]      // three pivots: root, mid, nozzle
    let tip: SCNNode         // spray comes out of here (local -Y)
    let spray: SCNParticleSystem
}

nonisolated enum FreddyModel {
    static let radius: Float = 0.17

    static func make(shadow: UIImage, puff: UIImage) -> FreddyParts {
        let red = Critter.mat(UIColor(red: 0.72, green: 0.035, blue: 0.025, alpha: 1), metal: 0.08, rough: 0.42)
        let dark = Critter.mat(UIColor(white: 0.035, alpha: 1), rough: 0.72)
        let rubber = Critter.mat(UIColor(white: 0.06, alpha: 1), rough: 0.85)
        let chrome = Critter.mat(UIColor(white: 0.78, alpha: 1), metal: 0.9, rough: 0.2)
        let label = Critter.mat(UIColor(white: 0.93, alpha: 1), rough: 0.8)
        let face = Critter.mat(UIColor(white: 0.97, alpha: 1), rough: 0.5)
        let needleRed = Critter.mat(UIColor(red: 0.85, green: 0.05, blue: 0.03, alpha: 1), rough: 0.4)
        let yellow = Critter.mat(UIColor(red: 0.95, green: 0.78, blue: 0.1, alpha: 1), metal: 0.5, rough: 0.35)

        let root = SCNNode()
        root.name = "freddy"
        Critter.addShadow(shadow, size: 0.55, to: root)
        let rock = SCNNode()
        root.addChildNode(rock)

        // Body: the wall extinguisher's cylinder, a dark foot ring, a domed shoulder.
        let foot = SCNCylinder(radius: CGFloat(radius) + 0.006, height: 0.03); foot.radialSegmentCount = 20
        Critter.part(foot, dark, in: rock, at: SCNVector3(0, 0.015, 0))
        let body = SCNCylinder(radius: CGFloat(radius), height: 0.6); body.radialSegmentCount = 24
        Critter.part(body, red, in: rock, at: SCNVector3(0, 0.33, 0))
        let dome = SCNSphere(radius: CGFloat(radius)); dome.segmentCount = 20
        let shoulder = Critter.part(dome, red, in: rock, at: SCNVector3(0, 0.63, 0))
        shoulder.scale = SCNVector3(1, 0.42, 1)
        // Instruction label on his front, with a little red stripe.
        Critter.part(SCNPlane(width: 0.17, height: 0.22), label, in: rock, at: SCNVector3(0, 0.34, Float(radius) + 0.002))
        Critter.part(SCNPlane(width: 0.12, height: 0.025), needleRed, in: rock, at: SCNVector3(0, 0.4, Float(radius) + 0.003))
        Critter.part(SCNPlane(width: 0.12, height: 0.012), dark, in: rock, at: SCNVector3(0, 0.31, Float(radius) + 0.003))
        Critter.part(SCNPlane(width: 0.1, height: 0.012), dark, in: rock, at: SCNVector3(0, 0.285, Float(radius) + 0.003))

        // Valve head: neck, valve block, carry handle + squeeze lever, the gauge (his face), the yellow pull-pin.
        let head = Critter.pivot(in: rock, at: SCNVector3(0, 0.69, 0))
        let neck = SCNCylinder(radius: 0.07, height: 0.1); neck.radialSegmentCount = 16
        Critter.part(neck, dark, in: head, at: SCNVector3(0, 0.04, 0))
        Critter.part(SCNBox(width: 0.12, height: 0.07, length: 0.11, chamferRadius: 0.012), dark, in: head, at: SCNVector3(0, 0.12, 0))
        Critter.part(SCNBox(width: 0.035, height: 0.016, length: 0.2, chamferRadius: 0.005), dark, in: head,
                     at: SCNVector3(0, 0.162, -0.05), euler: SCNVector3(-0.12, 0, 0))
        let lever = Critter.pivot(in: head, at: SCNVector3(0, 0.17, 0.04))
        Critter.part(SCNBox(width: 0.036, height: 0.014, length: 0.19, chamferRadius: 0.005), dark, in: lever,
                     at: SCNVector3(0, 0.02, -0.08), euler: SCNVector3(-0.32, 0, 0))
        let rim = SCNTorus(ringRadius: 0.052, pipeRadius: 0.007); rim.ringSegmentCount = 20; rim.pipeSegmentCount = 6
        Critter.part(rim, chrome, in: head, at: SCNVector3(0, 0.12, 0.066), euler: SCNVector3(Float.pi / 2, 0, 0))
        let dial = SCNCylinder(radius: 0.05, height: 0.006); dial.radialSegmentCount = 20
        Critter.part(dial, face, in: head, at: SCNVector3(0, 0.12, 0.064), euler: SCNVector3(Float.pi / 2, 0, 0))
        // Green "good" arc + red "low" arc on the dial, as two little bars.
        Critter.part(SCNBox(width: 0.03, height: 0.008, length: 0.002, chamferRadius: 0), Critter.mat(UIColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1)),
                     in: head, at: SCNVector3(0.018, 0.142, 0.068), euler: SCNVector3(0, 0, -0.5))
        Critter.part(SCNBox(width: 0.026, height: 0.008, length: 0.002, chamferRadius: 0), needleRed,
                     in: head, at: SCNVector3(-0.022, 0.14, 0.068), euler: SCNVector3(0, 0, 0.5))
        let needle = Critter.pivot(in: head, at: SCNVector3(0, 0.12, 0.07))
        Critter.part(SCNBox(width: 0.006, height: 0.042, length: 0.003, chamferRadius: 0.001), needleRed, in: needle, at: SCNVector3(0, 0.018, 0))
        Critter.part(SCNCylinder(radius: 0.006, height: 0.004), dark, in: needle, at: SCNVector3(0, 0, 0.002), euler: SCNVector3(Float.pi / 2, 0, 0))
        let pin = SCNTorus(ringRadius: 0.022, pipeRadius: 0.005); pin.ringSegmentCount = 12; pin.pipeSegmentCount = 6
        Critter.part(pin, yellow, in: head, at: SCNVector3(0.075, 0.13, 0.01), euler: SCNVector3(0, 0, Float.pi / 2))

        // Hose: three pivots hanging down his left side; the last is the nozzle.
        let hoseRoot = Critter.pivot(in: head, at: SCNVector3(-0.08, 0.1, 0.0))
        let seg1 = SCNCapsule(capRadius: 0.019, height: 0.22)
        Critter.part(seg1, rubber, in: hoseRoot, at: SCNVector3(0, -0.11, 0))
        let hoseMid = Critter.pivot(in: hoseRoot, at: SCNVector3(0, -0.2, 0))
        let seg2 = SCNCapsule(capRadius: 0.019, height: 0.2)
        Critter.part(seg2, rubber, in: hoseMid, at: SCNVector3(0, -0.1, 0))
        let nozzle = Critter.pivot(in: hoseMid, at: SCNVector3(0, -0.19, 0))
        let horn = SCNCone(topRadius: 0.022, bottomRadius: 0.034, height: 0.12); horn.radialSegmentCount = 12
        Critter.part(horn, dark, in: nozzle, at: SCNVector3(0, -0.06, 0))
        let tip = Critter.pivot(in: nozzle, at: SCNVector3(0, -0.125, 0))

        let spray = SCNParticleSystem()
        spray.particleImage = puff
        spray.birthRate = 0
        spray.loops = true
        spray.emissionDuration = 1
        spray.particleLifeSpan = 0.6
        spray.particleLifeSpanVariation = 0.15
        spray.particleVelocity = 3.4
        spray.particleVelocityVariation = 0.7
        spray.spreadingAngle = 9
        spray.emittingDirection = SCNVector3(0, -1, 0)
        spray.particleSize = 0.04
        spray.particleSizeVariation = 0.015
        spray.particleColor = UIColor(white: 0.96, alpha: 0.8)
        spray.blendMode = .alpha
        spray.isLightingEnabled = false
        spray.dampingFactor = 1.4
        spray.acceleration = SCNVector3(0, -0.5, 0)
        let grow = CAKeyframeAnimation()
        grow.values = [0.04, 0.22]
        let fade = CAKeyframeAnimation()
        fade.values = [0.85, 0.0]
        spray.propertyControllers = [
            .size: SCNParticlePropertyController(animation: grow),
            .opacity: SCNParticlePropertyController(animation: fade)
        ]
        tip.addParticleSystem(spray)

        // Oct 4 follow-up: an invisible, generous tap target (hit-testable,
        // never drawn) so a tap anywhere on or right around him counts.
        let proxyMaterial = SCNMaterial()
        proxyMaterial.colorBufferWriteMask = []
        proxyMaterial.writesToDepthBuffer = false
        let proxy = SCNCapsule(capRadius: 0.27, height: 1.1)
        Critter.part(proxy, proxyMaterial, in: root, at: SCNVector3(0, 0.55, 0), name: "freddyTapTarget")

        return FreddyParts(root: root, rock: rock, head: head, needle: needle, lever: lever,
                           hose: [hoseRoot, hoseMid, nozzle], tip: tip, spray: spray)
    }

    /// A short white cloud where the spray meets the fire.
    static func cloud(puff: UIImage) -> SCNParticleSystem {
        let c = SCNParticleSystem()
        c.particleImage = puff
        c.birthRate = 70
        c.loops = true
        c.emissionDuration = 1
        c.particleLifeSpan = 1.5
        c.particleLifeSpanVariation = 0.4
        c.particleVelocity = 0.45
        c.particleVelocityVariation = 0.3
        c.spreadingAngle = 180
        c.emitterShape = SCNSphere(radius: 0.25)
        c.particleSize = 0.25
        c.particleSizeVariation = 0.1
        c.particleColor = UIColor(white: 0.93, alpha: 0.55)
        c.blendMode = .alpha
        c.isLightingEnabled = false
        c.acceleration = SCNVector3(0, 0.25, 0)
        let fade = CAKeyframeAnimation()
        fade.values = [0.0, 0.6, 0.0]
        c.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        return c
    }
}

// MARK: - Sound (synthesised, positional)

nonisolated struct FreddySound {
    var clanks: [SCNAudioSource] = []
    var spray: SCNAudioSource?
    var puff: SCNAudioSource?
    var yes: SCNAudioSource?
    var okay: SCNAudioSource?
    var ting: SCNAudioSource?

    static func make() -> FreddySound {
        typealias S = MenagerieSound
        var s = FreddySound()
        // A hollow steel cylinder set down on one rim.
        s.clanks = S.variants("freddy-clank", count: 4, volume: 0.32) { rng in
            S.strike([(rng.range(360, 440), 0.07, 1), (rng.range(1000, 1200), 0.04, 0.5), (rng.range(2300, 2800), 0.018, 0.3)],
                     seconds: 0.25, noise: 0.5, noiseDecay: 0.003, rng: &rng)
        }
        s.spray = S.source("freddy-spray", volume: 0.85) { hiss(seconds: 3.9, attack: 0.05, release: 0.35, seed: 11) }
        s.puff = S.source("freddy-puff", volume: 0.4) { hiss(seconds: 0.32, attack: 0.01, release: 0.25, seed: 5) }
        s.yes = S.source("freddy-yes", volume: 0.6) {
            var rng = S.Rand(seed: 3)
            return S.mix([(0, S.sweep(820, 1380, seconds: 0.12, wobble: 0.2), 0.7),
                          (0.1, hiss(seconds: 0.18, attack: 0.005, release: 0.14, seed: 7), 0.5),
                          (0.05, S.strike([(410, 0.07, 1), (1120, 0.04, 0.5)], seconds: 0.2, noise: 0.4, rng: &rng), 0.6)])
        }
        s.okay = S.source("freddy-okay", volume: 0.55) {
            var rng = S.Rand(seed: 9)
            return S.mix([(0, S.sweep(1150, 700, seconds: 0.17, wobble: 0.15), 0.7),
                          (0.14, S.strike([(380, 0.08, 1), (1040, 0.04, 0.5)], seconds: 0.22, noise: 0.4, rng: &rng), 0.7)])
        }
        s.ting = S.source("freddy-ting", volume: 0.45) {
            var rng = S.Rand(seed: 13)
            return S.strike([(1870, 0.35, 1), (4150, 0.18, 0.35), (2960, 0.25, 0.3)], seconds: 0.7, rng: &rng)
        }
        return s
    }

    /// Pressurised dry-chemical hiss: band-limited noise, a hard start, a
    /// slightly fluttering sustain that sags as the pressure drops.
    static func hiss(seconds: Float, attack: Float, release: Float, seed: UInt64) -> [Float] {
        var rng = MenagerieSound.Rand(seed: seed)
        let rate = MenagerieSound.rate
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var lp: Float = 0, lp2: Float = 0, prev: Float = 0
        for i in 0..<n {
            let t = Float(i) / rate
            let w = rng.unit() * 2 - 1
            let hp = w - prev; prev = w
            lp += (hp - lp) * 0.55
            lp2 += (lp - lp2) * 0.8
            let env = min(1, t / max(attack, 0.001)) * min(1, (seconds - t) / max(release, 0.001))
            let sag = 1 - 0.35 * (t / seconds)
            let flutter = 1 + 0.12 * sin(2 * .pi * 7 * t) * (t / seconds)
            out[i] = lp2 * env * sag * flutter
        }
        return out
    }
}

// MARK: - Driver

nonisolated final class FreddyDriver: PosseMember, @unchecked Sendable {
    enum Mode { case idle, follow, toFire, aim, spray, proud }

    let memberID = Freddy.memberID
    let displayName = "Freddy"
    var sounds = FreddySound()

    // Feel constants.
    static let walkMax: Float = 7.5          // has to keep up with a walking player
    static let hurry: Float = 3.4            // to a fire
    static let accel: Float = 10
    static let stride: Float = 0.15          // metres per rim-to-rim rock
    /// Oct 4 tune: the rock rate followed distance with no ceiling, so keeping
    /// up with Noodle drove it to ~20 rocks a second ("on both sides at once").
    /// Capped here; slow walking is unchanged.
    static let maxGaitRate: Float = 2 * .pi * 4.5   // radians/s = 4.5 full side-to-side cycles a second
    static let rollAmount: Float = 0.2       // radians onto each rim at full waddle
    static let bodyRadius: Float = 0.2

    private let parts: FreddyParts
    private let leash: FollowLeash
    private weak var sceneRoot: SCNNode?
    private let fires: [(coord: GridCoordinate, node: SCNNode)]
    private let requestExtinguish: @Sendable (GridCoordinate) -> Void
    private let puffImage: UIImage

    private let lock = NSLock()
    private var _following = false
    private var _pos = SIMD2<Float>(0, 0)

    private var mode: Mode = .idle
    private var modeTime: Double = 0
    private var heading: Float = 0
    private var velocity = SIMD2<Float>(0, 0)
    private var pace = SIMD2<Float>(0, 0)
    private var gaitPhase: Float = 0
    private var gaitAmount: Float = 0
    private var lastFootfall: Double = 0
    private var needleAngle: Float = -0.5
    private var needleVelocity: Float = 0
    private var headYaw: Float = 0
    private var aimBlend: Float = 0
    private var hop: Float = 0
    private var lastTime: CFTimeInterval = 0
    private var clock: Double = 0
    private var home = SIMD2<Float>(0, 0)
    private var wanderTarget: SIMD2<Float>?
    private var nextIdleBit: Double = 4
    private var fireScan: Double = 0
    private var claimed: Set<GridCoordinate> = []
    private var fireCoord: GridCoordinate?
    private var firePos = SIMD2<Float>(0, 0)
    private var standOff = SIMD2<Float>(0, 0)
    private var cloudNode: SCNNode?

    init(parts: FreddyParts, leash: FollowLeash, sceneRoot: SCNNode, fires: [(coord: GridCoordinate, node: SCNNode)],
         puff: UIImage, extinguish: @escaping @Sendable (GridCoordinate) -> Void) {
        self.parts = parts
        self.leash = leash
        self.sceneRoot = sceneRoot
        self.fires = fires
        self.puffImage = puff
        self.requestExtinguish = extinguish
    }

    // MARK: PosseMember (main thread)

    var groundPosition: SIMD2<Float> { lock.withLock { _pos } }
    var sceneNode: SCNNode? { parts.root }

    func acknowledge() { nudge = 1 }
    var isFollowing: Bool { lock.withLock { _following } }

    func startFollowing() {
        lock.withLock { _following = true }
        excite = 1
    }

    func stayHere() {
        lock.withLock { _following = false }
        settle = 1
    }

    // Main -> render thread one-shots (read and cleared in tick).
    private var excite: Float = 0
    private var settle: Float = 0
    private var nudge: Float = 0

    func place(at p: SIMD2<Float>, yaw: Float) {
        lock.withLock { _pos = p }
        home = p
        heading = yaw
        parts.root.position = SCNVector3(p.x, 0, p.y)
        parts.root.eulerAngles = SCNVector3(0, yaw, 0)
    }

    func tickAction() -> SCNAction {
        // Strong: the action on his own node is the driver's owner.
        SCNAction.customAction(duration: 1) { _, _ in self.tick() }
    }

    // MARK: Tick (render thread)

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(lastTime == 0 ? 1.0 / 60 : min(max(now - lastTime, 0), 1.0 / 20))
        lastTime = now
        guard dt > 0 else { return }
        let dtd = Double(dt)
        clock += dtd
        modeTime += dtd
        var pos = lock.withLock { _pos }
        let following = isFollowing

        // One-shots from the main thread.
        if excite > 0 {
            excite = 0
            hop = 1
            needleVelocity += 9
            play(sounds.yes)
            if mode == .idle { setMode(.follow) }
        }
        if nudge > 0 {
            nudge = 0
            hop = 0.7
            needleVelocity += 6
            play(sounds.puff)
        }
        if settle > 0 {
            settle = 0
            play(sounds.okay)
            needleVelocity -= 5
            if mode == .follow { setMode(.idle) }
            home = pos
            wanderTarget = nil
        }
        if !following, mode == .follow { setMode(.idle); home = pos }
        if following, mode == .idle { setMode(.follow) }

        let reading = following ? leash.update(follower: pos, dt: dtd) : nil
        if let jump = reading?.reposition, mode == .follow {
            pos = jump
            velocity = .zero
        }
        let player = reading?.player ?? leash.playerGround()?.pos
        let playerDistance = player.map { simd_distance($0, pos) } ?? 99

        // What he wants this frame.
        var target: SIMD2<Float>? = nil
        var maxSpeed = Self.walkMax
        var lookAt: SIMD2<Float>? = nil
        var moodTarget: Float = -0.4

        switch mode {
        case .idle:
            moodTarget = playerDistance < 4 ? 0.15 : -0.45
            if playerDistance < 4, let player { lookAt = player }
            nextIdleBit -= dtd
            if nextIdleBit <= 0 {
                nextIdleBit = Double.random(in: 5...12)
                switch Int.random(in: 0..<4) {
                case 0: puffLittle()
                case 1: hop = 0.6; needleVelocity += 4
                default:
                    // A little wander about his spot (never out of sight of it).
                    let a = Float.random(in: 0...(2 * .pi)), r = Float.random(in: 0.25...0.7)
                    let t = home + SIMD2<Float>(cos(a), sin(a)) * r
                    if leash.clear(home, t) { wanderTarget = t }
                }
            }
            if let w = wanderTarget {
                if simd_distance(w, pos) < 0.05 { wanderTarget = nil } else { target = w; maxSpeed = 0.7 }
            }
        case .follow:
            moodTarget = 0.35
            if let reading {
                target = reading.target
                let gap = simd_distance(reading.target, pos)
                maxSpeed = min(Self.walkMax, 0.8 + gap * 3)
                // Keep pace: move with the player, plus a pull toward the slot.
                if reading.direct { pace = reading.playerVelocity } else { pace = .zero }
                if gap < 0.25 { lookAt = reading.player + reading.playerForward * 3 }
                if playerDistance < 2.2, simd_length(velocity) < 0.2, sin(Float(clock) * 0.7) > 0.6 { lookAt = reading.player }
            }
            fireScan -= dtd
            if fireScan <= 0 { fireScan = 0.25; lookForFire(pos: pos, player: player) }
        case .toFire:
            moodTarget = 1.0
            target = standOff
            maxSpeed = Self.hurry
            lookAt = firePos
            if simd_distance(standOff, pos) < 0.08 { setMode(.aim) }
            if modeTime > 7 || !fireIsBurning(fireCoord) { finishFire(success: false) }
        case .aim:
            moodTarget = 1.1
            lookAt = firePos
            aimBlend = min(1, aimBlend + dt / 0.45)
            if modeTime > 0.5 { startSpray() }
        case .spray:
            // Pressure falls while he empties himself onto it.
            moodTarget = 1.1 - 2.0 * Float(min(1, modeTime / 3.8))
            lookAt = firePos
            parts.lever.eulerAngles.x = 0.28
            heading += sin(Float(clock) * 31) * 0.004          // recoil shiver
            if modeTime > 3.9 { stopSpray() }
        case .proud:
            moodTarget = -0.2 + Float(min(1, modeTime / 2)) * 0.6
            aimBlend = max(0, aimBlend - dt / 0.5)
            if modeTime > 1.4 { setMode(following ? .follow : .idle); home = pos }
        }
        if mode != .spray { parts.lever.eulerAngles.x += (0 - parts.lever.eulerAngles.x) * min(1, dt * 8) }
        if mode != .aim && mode != .spray && mode != .proud { aimBlend = max(0, aimBlend - dt / 0.4) }

        // Move: accelerate toward the target, never through anything solid.
        var desired = SIMD2<Float>(0, 0)
        if mode == .follow, simd_length(pace) > 0.05, let target {
            // Following a moving player: his pace plus a firm pull onto the slot.
            desired = pace + (target - pos) * 3.5
            let s = simd_length(desired)
            if s > 9 { desired *= 9 / s }
        } else if let target {
            let d = target - pos
            let dist = simd_length(d)
            if dist > 0.02 {
                let speed = min(maxSpeed, dist * 4)
                desired = d / dist * speed
            }
        }
        if mode != .follow { pace = .zero }
        velocity += (desired - velocity) * min(1, dt * Self.accel)
        var moved: Float = 0
        if simd_length(velocity) > 0.001 {
            let want = pos + velocity * dt
            let next = leash.safeStep(from: pos, to: want, radius: Self.bodyRadius)
            moved = simd_distance(next, pos)
            if moved < simd_length(want - pos) * 0.5 { velocity *= 0.5 }   // bumped something
            pos = next
        }
        lock.withLock { _pos = pos }
        let speed = moved / dt

        // Heading: where he is going, else what he is looking at.
        var face: SIMD2<Float>? = nil
        if speed > 0.25 { face = velocity }
        else if let lookAt { face = lookAt - pos }
        if let face, simd_length(face) > 0.01 {
            var turn = atan2(face.x, face.y) - heading
            while turn > .pi { turn -= 2 * .pi }
            while turn < -.pi { turn += 2 * .pi }
            heading += turn * min(1, dt * (mode == .aim || mode == .spray ? 10 : 6))
        }

        animate(dt: dt, moved: moved, speed: speed, lookAt: lookAt, pos: pos, moodTarget: moodTarget, now: now)
        parts.root.position = SCNVector3(pos.x, 0, pos.y)
        parts.root.eulerAngles = SCNVector3(0, heading, 0)
    }

    // MARK: Body language

    private func animate(dt: Float, moved: Float, speed: Float, lookAt: SIMD2<Float>?, pos: SIMD2<Float>,
                         moodTarget: Float, now: CFTimeInterval) {
        // The rim-to-rim waddle: the phase advances with distance travelled.
        gaitAmount += (min(1, speed / 0.9) - gaitAmount) * min(1, dt * 6)
        let before = gaitPhase
        gaitPhase += min(moved / Self.stride * .pi, Self.maxGaitRate * dt)
        if Int(floor(before / .pi)) != Int(floor(gaitPhase / .pi)), gaitAmount > 0.25, now - lastFootfall > 0.07 {
            lastFootfall = now
            play(sounds.clanks.randomElement())
        }
        if gaitAmount < 0.02 { gaitPhase = (gaitPhase / .pi).rounded() * .pi }   // settle flat on his base
        var roll = sin(gaitPhase) * Self.rollAmount * gaitAmount
        // A hop (recruited / pleased): up onto his rim and back, twice.
        if hop > 0 {
            hop = max(0, hop - dt * 1.6)
            roll += sin((1 - hop) * .pi * 4) * 0.16 * hop
        }
        // Pivot about the rim he is standing on (see FreddyModel.radius).
        let r = FreddyModel.radius
        let s: Float = roll > 0 ? -1 : 1
        let lean = min(0.18, speed / Self.walkMax * 0.3) - aimBlend * 0.08   // + = toward his front
        parts.rock.position = SCNVector3(s * r * (1 - cos(roll)), r * abs(sin(roll)), 0)
        parts.rock.eulerAngles = SCNVector3(lean, cos(gaitPhase) * 0.1 * gaitAmount, roll)

        // Gauge needle: a spring toward his mood, with a little life in it.
        let jitter = sin(Float(now) * 5.3) * 0.04 + sin(Float(now) * 11.7) * 0.02
        needleVelocity += ((moodTarget + jitter) - needleAngle) * 60 * dt
        needleVelocity *= max(0, 1 - 9 * dt)
        needleAngle += needleVelocity * dt
        parts.needle.eulerAngles.z = -max(-1.3, min(1.3, needleAngle))

        // Head looks a little toward whatever he is watching.
        var wantHead: Float = 0
        if let lookAt {
            let d = lookAt - pos
            if simd_length(d) > 0.05 {
                var rel = atan2(d.x, d.y) - heading
                while rel > .pi { rel -= 2 * .pi }
                while rel < -.pi { rel += 2 * .pi }
                wantHead = max(-0.7, min(0.7, rel))
            }
        }
        headYaw += (wantHead - headYaw) * min(1, dt * 5)
        parts.head.eulerAngles = SCNVector3(0, headYaw, -roll * 0.3)

        // Hose: swings with the waddle; lifts to aim.
        let swing = -roll * 1.4
        let a = aimBlend
        parts.hose[0].eulerAngles = SCNVector3(0.15 * (1 - a) + (-1.45) * a, 0.25 * a, -0.65 * (1 - a) + swing * (1 - a))
        parts.hose[1].eulerAngles = SCNVector3(-0.45 * (1 - a) + (-0.12) * a, 0, swing * 0.5 * (1 - a))
        parts.hose[2].eulerAngles = SCNVector3(-0.5 * (1 - a) + 0.05 * a, 0, 0)
    }

    private func play(_ source: SCNAudioSource?) {
        guard let source else { return }
        CritterAudio.play(source, on: parts.root)
    }

    private func puffLittle() {
        play(sounds.puff)
        parts.spray.birthRate = 160
        parts.root.runAction(.sequence([.wait(duration: 0.18), .run { [weak self] _ in self?.parts.spray.birthRate = 0 }]))
        needleVelocity -= 3
    }

    private func setMode(_ m: Mode) {
        mode = m
        modeTime = 0
    }

    // MARK: Fire

    private func fireIsBurning(_ coord: GridCoordinate?) -> Bool {
        guard let coord, let node = fires.first(where: { $0.coord == coord })?.node else { return false }
        return node.parent != nil && !node.isHidden && node.presentation.opacity > 0.5
    }

    /// Following, a burning fire close by that he (and the player) can get at.
    private func lookForFire(pos: SIMD2<Float>, player: SIMD2<Float>?) {
        guard let player, !fires.isEmpty else { return }
        var best: (GridCoordinate, SIMD2<Float>, SIMD2<Float>, Float)?
        for (coord, node) in fires where !claimed.contains(coord) && fireIsBurning(coord) {
            let p = node.worldPosition
            let fp = SIMD2<Float>(p.x, p.z)
            let dF = simd_distance(fp, pos), dP = simd_distance(fp, player)
            guard dF < 6.5, dP < 7 else { continue }
            // Stand off along the corridor axis he is coming from.
            let away = pos - fp
            let axis = abs(away.x) > abs(away.y) ? SIMD2<Float>(away.x > 0 ? 1 : -1, 0) : SIMD2<Float>(0, away.y > 0 ? 1 : -1)
            let spot = fp + axis * 1.25
            guard leash.clear(spot, fp + axis * 0.5), leash.clear(pos, spot) || leash.clear(player, spot) else { continue }
            if best == nil || dF < best!.3 { best = (coord, fp, spot, dF) }
        }
        guard let best else { return }
        claimed.insert(best.0)
        fireCoord = best.0
        firePos = best.1
        standOff = best.2
        needleVelocity += 8
        play(sounds.yes)
        setMode(.toFire)
        diag("freddy.fireSpotted", ["row": best.0.row, "col": best.0.col])
    }

    private func startSpray() {
        guard let coord = fireCoord else { finishFire(success: false); return }
        setMode(.spray)
        parts.spray.birthRate = 420
        play(sounds.spray)
        requestExtinguish(coord)
        // The cloud where it lands.
        let cloud = SCNNode()
        cloud.position = SCNVector3(firePos.x, 0.45, firePos.y)
        cloud.addParticleSystem(FreddyModel.cloud(puff: puffImage))
        sceneRoot?.addChildNode(cloud)
        cloudNode = cloud
    }

    private func stopSpray() {
        parts.spray.birthRate = 0
        if let cloud = cloudNode {
            cloud.particleSystems?.forEach { $0.birthRate = 0 }
            cloud.runAction(.sequence([.wait(duration: 2), .removeFromParentNode()]))
        }
        cloudNode = nil
        finishFire(success: true)
    }

    private func finishFire(success: Bool) {
        if success {
            play(sounds.ting)
            hop = 1
            setMode(.proud)
        } else {
            if let coord = fireCoord { claimed.remove(coord) }   // may try again later
            setMode(isFollowing ? .follow : .idle)
        }
        fireCoord = nil
        fireScan = success ? 2 : 4
    }
}
