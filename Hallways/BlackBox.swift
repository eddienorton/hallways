import SceneKit
import UIKit
import AVFoundation
import simd

// MARK: - THE BLACK BOX (Oct 12)
//
// One small black cube on the player's desk (Floor 3 office). No name, no
// label, no introduction. It watches the player; touch it and it thinks,
// counts itself in on its corner, and performs a short tune it has just
// composed (BlackBoxMusic), dancing to it. Touch it again while it plays and
// it stops. Every performance is new.
//
// Pieces:
//   BlackBox        -- install / attach / taps (main actor; tiny hooks only)
//   BlackBoxFace    -- the face: warm phosphor light behind the dark glass
//   BlackBoxBrain   -- its life, run on SceneKit's render thread
//
// Reversible: launch with `-HallwaysNoBlackBox YES` and no box is built; or
// delete BlackBox.swift, BlackBoxMusic.swift, BlackBox.usdz and the four
// marked "Oct 12" hooks (PlayerOffice.install; ContentView: attach, the
// seated tap, the standing tap).

enum BlackBox {
    /// `-HallwaysNoBlackBox YES` (or the same user default) leaves the desk as it was.
    static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: "HallwaysNoBlackBox") }
    /// Desk-local spot: the front-left corner of the new-hire desk as seen
    /// from the door -- in front of the banker's lamp, well left of the
    /// blotter, the computer and its keyboard; 0.21 m back from the front
    /// edge so even turned 45 degrees it stays on the top.
    static let deskSpot = SCNVector3(-0.62, 0.774, 0.21)

    private static var brain: BlackBoxBrain?
    private static weak var lastCamera: SCNNode?

    /// Called at the end of PlayerOffice.install with the desk node.
    static func install(onDesk desk: SCNNode) {
        brain?.shutdown(reason: "rebuilt")
        brain = nil
        guard isEnabled else { diag("blackBox.disabled"); return }
        let body = makeBody()
        let face = BlackBoxFace.build()
        let cells = PlayerOffice.officeCells.map { BlackBoxBrain.cellKey($0.row, $0.col) }
        let b = BlackBoxBrain(body: body, face: face, cellSize: PlayerOffice.cellSize, officeCells: Set(cells))
        b.root.position = deskSpot
        desk.addChildNode(b.root)
        if let cam = lastCamera { b.setCamera(cam) }
        b.start()
        brain = b
        diag("blackBox.installed", ["model": body.name ?? "?"])
    }

    /// Called on every floor install with the player's camera (a box in
    /// another scene ignores it; a rebuilt office replaces its box).
    static func attach(camera: SCNNode) {
        lastCamera = camera
        brain?.setCamera(camera)            // ignored by a box in another scene
    }

    /// Is `node` part of the box?
    static func owns(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let cur = n {
            if cur.name == BlackBoxBrain.rootName { return true }
            n = cur.parent
        }
        return false
    }

    /// A tap on the box. Only from inside the office (standing or seated at
    /// the desk); returns false (ordinary tap) from anywhere else.
    @discardableResult
    static func tapped(playerCell: GridCoordinate) -> Bool {
        guard let b = brain, PlayerOffice.officeCells.contains(playerCell) else { return false }
        b.tap()
        return true
    }

    /// The body: the Blender model (BlackBox.usdz); a plain chamfered black
    /// cube with a dark glass panel if the asset is missing.
    static func makeBody() -> SCNNode {                       // (Oct 12: also THE BIG REVEAL's projected box)
        if let model = HallwaysianModel.load("BlackBox", required: ["bbShell", "bbVisor"])?.clone() {
            return model
        }
        let node = SCNNode()
        node.name = "blackBoxFallback"
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.02, alpha: 1)
        m.roughness.contents = 0.5
        let cube = SCNNode(geometry: SCNBox(width: 0.28, height: 0.278, length: 0.28, chamferRadius: 0.008))
        cube.geometry?.materials = [m]
        cube.position = SCNVector3(0, 0.151, 0)
        node.addChildNode(cube)
        let g = SCNMaterial()
        g.lightingModel = .physicallyBased
        g.diffuse.contents = UIColor(white: 0.005, alpha: 1)
        g.roughness.contents = 0.08
        let glass = SCNNode(geometry: SCNPlane(width: 0.204, height: 0.15))
        glass.geometry?.materials = [g]
        glass.position = SCNVector3(0, BlackBoxLayout.visorY, 0.1405)
        node.addChildNode(glass)
        return node
    }
}

// MARK: - The face

/// Warm phosphor light behind the visor glass: two tall pill eyes (they
/// close into smiling arcs), two short brows that only appear when it means
/// something, a mouth that is a smile or an open, singing shape, and two
/// cheeks that glow when it is pleased or embarrassed. Plus the glow in the
/// top grille and a small warm light that spills onto the desk.
/// All in body space (origin: centre of the underside; face toward +Z).
nonisolated enum BlackBoxLayout {
    static let visorY: Float = 0.166
    static let faceZ: Float = 0.1375
    static let eyeX: Float = 0.046, eyeY: Float = 0.010
    static let eyeW: Float = 0.030, eyeH: Float = 0.050
    static let browY: Float = 0.050, browW: Float = 0.030, browH: Float = 0.007
    static let mouthY: Float = -0.040
    static let smileW: Float = 0.056, smileH: Float = 0.021
    static let mouthW: Float = 0.032, mouthH: Float = 0.024
    static let happyW: Float = 0.050, happyH: Float = 0.028
    static let blushX: Float = 0.074, blushY: Float = -0.022, blushW: Float = 0.034, blushH: Float = 0.018
    static let grilleR: Float = 0.082
    static let topY: Float = 0.29
}

enum BlackBoxFace {
    static let amber = UIColor(red: 1.0, green: 0.84, blue: 0.59, alpha: 1)
    static let blushColor = UIColor(red: 1.0, green: 0.47, blue: 0.47, alpha: 1)

    nonisolated struct Nodes {
        var face: SCNNode
        var eyes: [SCNNode] = []         // containers (left = -x first)
        var eyeShapes: [SCNNode] = []    // the pills
        var happyShapes: [SCNNode] = []  // the closed, smiling arcs
        var brows: [SCNNode] = []
        var smile: SCNNode
        var mouth: SCNNode
        var blush: [SCNNode] = []
        var ring: SCNNode
        var light: SCNLight
        var lightNode: SCNNode
    }

    private static var cache: [String: UIImage] = [:]

    static func build() -> Nodes {
        typealias L = BlackBoxLayout
        let face = SCNNode()
        face.name = "blackBoxFace"
        face.position = SCNVector3(0, L.visorY, L.faceZ)
        func plane(_ kind: String, _ w: Float, _ h: Float, layer: Int, color: UIColor = amber) -> SCNNode {
            let (fx, fy) = padScale(kind)
            let p = SCNPlane(width: CGFloat(w * fx), height: CGFloat(h * fy))
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = sprite(kind, color: color)
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            m.isDoubleSided = false
            p.materials = [m]
            let n = SCNNode(geometry: p)
            n.renderingOrder = 40 + layer
            n.castsShadow = false
            return n
        }
        var eyes: [SCNNode] = [], shapes: [SCNNode] = [], happy: [SCNNode] = [], brows: [SCNNode] = [], blush: [SCNNode] = []
        for side: Float in [-1, 1] {
            let c = SCNNode()
            c.position = SCNVector3(side * L.eyeX, L.eyeY, 0.0004)
            let e = plane("eye", L.eyeW, L.eyeH, layer: 2)
            let h = plane("happy", L.happyW, L.happyH, layer: 2)
            h.position = SCNVector3(0, 0.004, 0)
            h.opacity = 0
            c.addChildNode(e); c.addChildNode(h)
            face.addChildNode(c)
            eyes.append(c); shapes.append(e); happy.append(h)
            let b = plane("brow", L.browW, L.browH, layer: 2)
            b.position = SCNVector3(side * L.eyeX, L.browY, 0.0004)
            b.opacity = 0
            face.addChildNode(b)
            brows.append(b)
            let k = plane("blush", L.blushW, L.blushH, layer: 1, color: blushColor)
            k.position = SCNVector3(side * L.blushX, L.blushY, 0.0002)
            k.opacity = 0
            face.addChildNode(k)
            blush.append(k)
        }
        let smile = plane("smile", L.smileW, L.smileH, layer: 2)
        smile.position = SCNVector3(0, L.mouthY + 0.004, 0.0004)
        face.addChildNode(smile)
        let mouth = plane("mouth", L.mouthW, L.mouthH, layer: 2)
        mouth.position = SCNVector3(0, L.mouthY, 0.0004)
        mouth.opacity = 0
        face.addChildNode(mouth)

        let ring = plane("ring", L.grilleR * 2.3, L.grilleR * 2.3, layer: 0)
        ring.eulerAngles.x = -.pi / 2
        ring.position = SCNVector3(0, L.topY - 0.0008, 0)
        ring.opacity = 0.1

        let light = SCNLight()
        light.type = .omni
        light.color = UIColor(red: 1.0, green: 0.78, blue: 0.5, alpha: 1)
        light.intensity = 0
        light.attenuationStartDistance = 0.05
        light.attenuationEndDistance = 0.75
        light.castsShadow = false
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(0, 0.12, 0.24)
        return Nodes(face: face, eyes: eyes, eyeShapes: shapes, happyShapes: happy, brows: brows, smile: smile, mouth: mouth,
                     blush: blush, ring: ring, light: light, lightNode: lightNode)
    }

    /// Pixel size of each sprite (shape + glow margin).
    private static func pixels(_ kind: String) -> CGSize {
        let px: CGFloat = 128
        switch kind {
        case "eye": return CGSize(width: floor(px * 0.62), height: floor(px * 0.90))
        case "brow": return CGSize(width: px, height: floor(px * 0.25))
        case "smile", "happy": return CGSize(width: px, height: floor(px * 0.55))
        case "mouth": return CGSize(width: px, height: floor(px * 0.75))
        case "blush": return CGSize(width: px, height: floor(px * 0.6))
        case "ring": return CGSize(width: px * 2, height: px * 2)
        default: return CGSize(width: px, height: px)
        }
    }

    /// Plane size per shape size: filled shapes sit inside a glow margin.
    private static func padScale(_ kind: String) -> (Float, Float) {
        guard ["eye", "brow", "mouth", "blush"].contains(kind) else { return (1, 1) }
        let s = pixels(kind)
        let p = floor(min(s.width, s.height) * 0.22)
        return (Float(s.width / (s.width - 2 * p)), Float(s.height / (s.height - 2 * p)))
    }

    /// The glowing sprite: the shape in a lighter core, with a soft glow.
    static func sprite(_ kind: String, color: UIColor = amber) -> UIImage {
        let key = kind + (color == amber ? "" : "-alt")
        if let image = cache[key] { return image }
        let size = pixels(kind)
        let W = size.width, H = size.height
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let pad = floor(min(W, H) * 0.22)
            var path: UIBezierPath
            var stroke: CGFloat = 0
            switch kind {
            case "eye":
                let r = CGRect(x: pad, y: pad, width: W - 2 * pad, height: H - 2 * pad)
                path = UIBezierPath(roundedRect: r, cornerRadius: r.width / 2)
            case "brow":
                let p = floor(H * 0.3)
                let r = CGRect(x: p, y: p, width: W - 2 * p, height: H - 2 * p)
                path = UIBezierPath(roundedRect: r, cornerRadius: r.height / 2)
            case "smile", "happy":
                let p = W * 0.16
                let rect = kind == "smile" ? CGRect(x: p, y: -H + 2 * p, width: W - 2 * p, height: 2 * H - 3 * p)
                                           : CGRect(x: p, y: p, width: W - 2 * p, height: 2 * H - 3 * p)
                let (a0, a1): (CGFloat, CGFloat) = kind == "smile" ? (25, 155) : (205, 335)
                path = UIBezierPath(arcCenter: .zero, radius: 1, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: true)
                path.apply(CGAffineTransform(scaleX: rect.width / 2, y: rect.height / 2))
                path.apply(CGAffineTransform(translationX: rect.midX, y: rect.midY))
                stroke = W * (kind == "smile" ? 0.085 : 0.11)
            case "mouth":
                let p = W * 0.22
                let r = CGRect(x: p, y: p, width: W - 2 * p, height: H - 2 * p)
                path = UIBezierPath(roundedRect: r, cornerRadius: r.height * 0.48)
            case "blush":
                let p = W * 0.18
                path = UIBezierPath(ovalIn: CGRect(x: p, y: p, width: W - 2 * p, height: H - 2 * p))
            case "ring":
                path = UIBezierPath()
                let c = W / 2
                for rr: CGFloat in [0.90, 0.62, 0.34] {
                    path.append(UIBezierPath(ovalIn: CGRect(x: c - c * rr, y: c - c * rr, width: 2 * c * rr, height: 2 * c * rr)))
                }
                stroke = c * 0.032
            default:
                path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: W, height: H))
            }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let core = UIColor(red: r * 0.35 + 0.65, green: g * 0.35 + 0.65, blue: b * 0.35 + 0.65, alpha: 1)
            let blur = max(2, min(W, H) * (kind == "blush" ? 0.16 : 0.10)) * 2
            path.lineCapStyle = .round
            path.lineWidth = stroke
            // Glow pass.
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: blur, color: color.withAlphaComponent(kind == "blush" ? 0.8 : 0.95).cgColor)
            if stroke > 0 {
                color.setStroke(); path.stroke()
            } else {
                (kind == "blush" ? color.withAlphaComponent(0.55) : color).setFill(); path.fill()
            }
            cg.restoreGState()
            // Hot core.
            if kind != "blush" {
                if stroke > 0 { core.setStroke(); path.stroke() } else { core.setFill(); path.fill() }
            }
        }
        cache[key] = image
        return image
    }
}

// MARK: - Its life

nonisolated final class BlackBoxBrain: @unchecked Sendable {
    static let rootName = "blackBox"

    nonisolated enum Mode { case idle, dozing, thinking, countIn, performing, ending, bow, embarrassed, startled }

    nonisolated struct Pose {
        var hop: Float = 0, squash: Float = 0, roll: Float = 0, pitch: Float = 0, yaw: Float = 0
        var eyeOpen: Float = 1, happy: Float = 0, lookX: Float = 0, lookY: Float = 0
        var browRaise: Float = 0, browAngle: Float = 0, brow: Float = 0
        var mouthOpen: Float = 0, smile: Float = 0.6, blush: Float = 0
        var ring: Float = 0.08, light: Float = 0
    }

    // Nodes (built on main; touched afterwards only from the render thread).
    let root = SCNNode()            // on the desk; turns toward the player
    private let hopNode = SCNNode() // lifts and squashes
    private let pivot = SCNNode()   // tips on an edge or a corner
    private let body = SCNNode()    // the cube itself (offset back from the pivot)
    private let speaker = SCNNode() // where the sound comes from
    private let face: BlackBoxFace.Nodes

    private let lock = NSLock()
    private weak var _camera: SCNNode?
    private var pendingTap = false
    private var ready: (piece: BlackBoxMusic.Piece, source: SCNAudioSource?)?
    private var generation = 0
    private var dead = false

    // Render-thread state.
    private var lastTime: CFTimeInterval = 0
    private var clock: Double = 0
    private var mode: Mode = .dozing
    private var modeStart: Double = 0
    private var pose = Pose()
    private var facing: Float = 0               // root yaw (desk-local), toward the player
    private var turnFrom: Float = 0, turnTo: Float = 0, turnStart: Double = -10
    private var nextBlink: Double = 2, blinkStart: Double = -10, doubleBlink = false
    private var nextFidget: Double = 6, fidget = 0, fidgetStart: Double = -10
    private var playerAway: Double = 0
    private var playerSeen = false
    private var shyUntil: Double = 0
    private var performances = 0
    private var lastStyle: BlackBoxMusic.Style?
    private var piece: BlackBoxMusic.Piece?
    private var melody: [BlackBoxMusic.TimedNote] = []
    private var melodyIndex = 0
    private var songPlayer: SCNAudioPlayer?
    private var fadeOutStart: Double = -1
    private var embarrassedEnding = false
    private var balanceSide: Float = 1
    private var thinkLook: Float = 1
    private var lastTap: Double = -10
    private var lastLook = SIMD2<Float>(0, 0)
    private var playerDistance: Float = 5

    private let cellSize: Float
    private let officeCells: Set<Int>
    private var wallNow: CFTimeInterval = 0
    private var songStartWall: CFTimeInterval = 0

    static func cellKey(_ row: Int, _ col: Int) -> Int { row * 10_000 + col }

    // MARK: Oct 12 -- THE BIG REVEAL: a second box, on the conference-room screen
    //
    // `presentation` boxes live in their own little scene (rendered onto the
    // projector screen). They never look for the office: the audience is
    // `setCamera`'s camera, they are awake only when told, they follow an
    // optional `lookNode`, they play their music on `audioAnchor` (a node in
    // the room, so the sound comes from the screen) and they compose what
    // they are told. Harold in the office never sets any of this.
    nonisolated enum Command { case wake, sleep, surprise, blush, bow, compose(seed: UInt64, style: BlackBoxMusic.Style) }
    private let presentation: Bool
    private var commands: [Command] = []
    private var stageAwake = false
    private var forcedPiece: (seed: UInt64, style: BlackBoxMusic.Style)?
    private weak var _lookNode: SCNNode?
    private weak var _audioAnchor: SCNNode?
    private var _busy = false

    /// Presentation: tell it what to do (main thread).
    func command(_ c: Command) { lock.withLock { commands.append(c) } }
    /// Presentation: something for its eyes to follow (nil: the audience).
    func setLookNode(_ node: SCNNode?) { lock.withLock { _lookNode = node } }
    /// Presentation: where its music comes from (a node in the player's scene).
    func setAudioAnchor(_ node: SCNNode?) { lock.withLock { _audioAnchor = node } }
    /// Thinking, counting in, playing or finishing a piece.
    var isBusy: Bool { lock.withLock { _busy } }
    private var soundNode: SCNNode { lock.withLock { _audioAnchor } ?? speaker }

    init(body model: SCNNode, face: BlackBoxFace.Nodes, cellSize: Float, officeCells: Set<Int>, presentation: Bool = false) {
        self.presentation = presentation
        self.face = face
        self.cellSize = cellSize
        self.officeCells = officeCells
        root.name = Self.rootName
        root.addChildNode(hopNode)
        hopNode.addChildNode(pivot)
        pivot.addChildNode(body)
        body.addChildNode(model)
        body.addChildNode(face.face)
        body.addChildNode(face.ring)
        body.addChildNode(face.lightNode)
        speaker.position = SCNVector3(0, 0.2, 0.1)
        body.addChildNode(speaker)
        nextFidget = Double.random(in: 5...9)
    }

    func start() {
        root.runAction(.repeatForever(SCNAction.customAction(duration: 1) { [weak self] _, _ in self?.tick() }), forKey: "blackBoxLife")
    }

    func setCamera(_ camera: SCNNode) { lock.withLock { _camera = camera } }

    /// Main thread: a touch.
    func tap() { lock.withLock { pendingTap = true } }

    /// Main thread: let go (floor change / rebuild).
    func shutdown(reason: String) {
        lock.withLock { dead = true; generation += 1; ready = nil }
        root.removeAction(forKey: "blackBoxLife")
        soundNode.removeAllAudioPlayers()
        diag("blackBox.shutdown", ["reason": reason])
    }

    // MARK: The beat (render thread)

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(lastTime == 0 ? 1.0 / 60 : min(max(now - lastTime, 0), 1.0 / 20))
        lastTime = now
        wallNow = now
        guard dt > 0 else { return }
        clock += Double(dt)
        let (tapNow, camera, isDead, orders, lookNode) = lock.withLock { () -> (Bool, SCNNode?, Bool, [Command], SCNNode?) in
            let t = pendingTap
            pendingTap = false
            let c = commands
            commands = []
            return (t, _camera, dead, c, _lookNode)
        }
        if isDead { return }
        for order in orders {
            switch order {
            case .wake:                                    // eyes open, gently (no start): the audience
                stageAwake = true
                playerSeen = true
                if mode == .dozing { enter(.idle) }
            case .sleep: stageAwake = false; enter(.dozing)
            case .surprise: if mode == .idle || mode == .dozing { enter(.startled) }
            // (presentation) shy delight; a little bow of thanks -- only from a free moment
            case .blush: if mode == .idle { enter(.embarrassed) }
            case .bow: if mode == .idle { enter(.bow) }
            case .compose(let seed, let style): forcedPiece = (seed, style); compose()
            }
        }

        // Where is the player? (desk-local; the desk is the root's parent)
        var playerHere = false
        var toPlayer: Float = facing
        var elevation: Float = 0.2
        if let camera, let desk = root.parent, sameScene(camera) {
            var w = camera.presentation.worldPosition
            if presentation {
                playerHere = stageAwake                                   // awake only when the show says so
                if let lookNode { w = lookNode.presentation.worldPosition }
            } else {
                let row = Int((w.z / cellSize).rounded()), col = Int((w.x / cellSize).rounded())
                playerHere = officeCells.contains(Self.cellKey(row, col))
            }
            let local = desk.presentation.convertPosition(w, from: nil)
            let p = root.position
            let dx = local.x - p.x, dz = local.z - p.z
            playerDistance = sqrtf(dx * dx + dz * dz)
            toPlayer = atan2f(dx, dz)
            elevation = atan2f(local.y - (p.y + 0.17), max(0.2, playerDistance))
            if presentation, lookNode != nil { playerDistance = max(playerDistance, 1) }   // watching, not being looked at: no shyness
        }
        playerAway = playerHere ? 0 : playerAway + Double(dt)

        if tapNow, clock - lastTap > 0.35 {
            lastTap = clock
            handleTap()
        }
        // Walked out mid-song: stop (no music left playing behind the player).
        if !presentation, playerAway > 0.6, [.thinking, .countIn, .performing, .ending].contains(mode) {
            interrupt(reason: "playerLeft", startle: false)
        }

        var target = Pose()
        let rel = wrap(toPlayer - facing)
        // Eyes follow the player (within the glass), body turns when needed.
        let lookX = max(-1, min(1, rel / 0.9)) * 0.032
        let lookY = max(-1, min(1, elevation / 0.6)) * 0.014
        lastLook = SIMD2(lookX, lookY)

        switch mode {
        case .dozing:
            doze(&target)
            if playerHere {
                if !playerSeen || clock - modeStart > 2 { enter(.startled) } else { enter(.idle) }
                playerSeen = true
            }
        case .idle:
            idle(&target, rel: rel, toPlayer: toPlayer, here: playerHere)
            if playerAway > 8 { enter(.dozing) }
        case .startled:
            startled(&target)
            if clock - modeStart > 1.1 { enter(.idle) }
        case .thinking:
            think(&target)
            let r = lock.withLock { ready }
            if let r, clock - modeStart > 1.4 {
                lock.withLock { ready = nil }
                begin(r.piece, r.source)
            } else if clock - modeStart > 12 {
                enter(.idle)            // composing failed or took too long: give up quietly
            }
        case .countIn, .performing, .ending:
            perform(&target)
        case .bow:
            bow(&target)
            if clock - modeStart > 2.4 { enter(.idle) }
        case .embarrassed:
            embarrassed(&target)
            if clock - modeStart > 3.4 { enter(.idle) }
        }

        if mode == .idle || mode == .dozing || mode == .startled || mode == .bow || mode == .embarrassed {
            target.lookX += lookX
            target.lookY += lookY
        }
        blink(&target)
        fadeAudio()
        let busy = [.thinking, .countIn, .performing, .ending].contains(mode)
        lock.withLock { _busy = busy }
        apply(target, dt: dt)
    }

    private func sameScene(_ camera: SCNNode) -> Bool {
        var a: SCNNode = camera
        while let p = a.parent { a = p }
        var b: SCNNode = root
        while let p = b.parent { b = p }
        return a === b
    }

    private func enter(_ m: Mode) {
        mode = m
        modeStart = clock
        if m == .idle { nextFidget = clock + Double.random(in: 4...9) }
    }

    private func wrap(_ a: Float) -> Float {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x < -.pi { x += 2 * .pi }
        return x
    }

    // MARK: Taps

    private func handleTap() {
        switch mode {
        case .thinking, .countIn, .performing, .ending:
            interrupt(reason: "tap", startle: true)
        default:
            compose()
        }
    }

    private func compose() {
        enter(.thinking)
        thinkLook = Bool.random() ? 1 : -1
        let gen: Int = lock.withLock { generation += 1; ready = nil; return generation }
        let first = performances == 0
        let previous = lastStyle
        let forced = forcedPiece
        forcedPiece = nil
        let seed: UInt64 = forced?.seed ?? (first ? 105 : UInt64.random(in: 1...UInt64.max))
        diag("blackBox.compose", ["first": first, "seed": "\(seed)"])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = CACurrentMediaTime()
            let piece = forced != nil ? BlackBoxMusic.compose(seed: seed, style: forced!.style)
                      : first ? BlackBoxMusic.compose(seed: seed, style: .bounce)
                              : BlackBoxMusic.compose(seed: seed, previous: previous)
            let samples = BlackBoxMusic.render(piece)
            let source = Self.writeSource(samples, seed: seed)
            diag("blackBox.composed", ["style": piece.style.rawValue, "bpm": piece.bpm, "lead": piece.lead.rawValue,
                                       "seconds": String(format: "%.1f", piece.totalDuration),
                                       "renderMs": Int((CACurrentMediaTime() - started) * 1000)])
            guard let self else { return }
            self.lock.withLock {
                if self.generation == gen && !self.dead { self.ready = (piece, source) }
            }
        }
    }

    private static func writeSource(_ samples: [Float], seed: UInt64) -> SCNAudioSource? {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("blackbox-\(seed).wav")
        do {
            // Old performances' files are let go.
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where f.lastPathComponent.hasPrefix("blackbox-") && f != url {
                try? FileManager.default.removeItem(at: f)
            }
            try BlackBoxMusic.wavData(samples).write(to: url, options: .atomic)
        } catch {
            diag("blackBox.wavFailed", ["error": error.localizedDescription])
            return nil
        }
        guard let source = SCNAudioSource(url: url) else { return nil }
        source.isPositional = true
        source.shouldStream = false
        source.loops = false
        source.volume = 1
        source.load()
        return source
    }

    private func begin(_ p: BlackBoxMusic.Piece, _ source: SCNAudioSource?) {
        piece = p
        melody = p.melodyNotes
        melodyIndex = 0
        performances += 1
        lastStyle = p.style
        embarrassedEnding = !p.flourish && performances >= 3 && Int.random(in: 0..<10) < 3   // carried away past the last hit
        balanceSide = Bool.random() ? 1 : -1
        enter(.countIn)
        songStartWall = wallNow + 0.04      // the audio engine's start-up, roughly
        fadeOutStart = -1
        let sound = soundNode
        sound.removeAllAudioPlayers()
        songPlayer = nil
        if let source {
            CritterAudio.play(source, on: sound)         // Mute, Settings, distance, walls
            songPlayer = sound.audioPlayers.last
        }
        diag("blackBox.perform", ["n": performances, "style": p.style.rawValue, "audible": songPlayer != nil])
    }

    private func interrupt(reason: String, startle: Bool) {
        lock.withLock { generation += 1; ready = nil }
        if songPlayer != nil { fadeOutStart = clock }
        piece = nil
        diag("blackBox.stopped", ["reason": reason])
        enter(startle ? .startled : .idle)
        if !startle { playerSeen = true }
    }

    private func fadeAudio() {
        if fadeOutStart < 0 {
            // While it plays: full within 2 m, gently less across the office.
            if let mixer = songPlayer?.audioNode as? AVAudioMixing {
                mixer.volume = 1 - 0.45 * max(0, min(1, (playerDistance - 2) / 4))
            }
            return
        }
        let k = Float(clock - fadeOutStart) / 0.25
        if k >= 1 {
            soundNode.removeAllAudioPlayers()
            songPlayer = nil
            fadeOutStart = -1
        } else if let mixer = songPlayer?.audioNode as? AVAudioMixing {
            mixer.volume = min(mixer.volume, 1 - k)
        }
    }

    // MARK: Moods

    private func doze(_ t: inout Pose) {
        let breathe = Float(0.5 + 0.5 * sin(clock * 0.9))
        t.eyeOpen = 0.12
        t.lookY = -0.008
        t.smile = 0.25
        t.ring = 0.03 + 0.06 * breathe
        t.squash = 0.012 * breathe
    }

    private func startled(_ t: inout Pose) {
        let a = Float(clock - modeStart)
        t.eyeOpen = a < 0.5 ? 1.25 : 1.05
        t.brow = a < 0.9 ? 1 : 0
        t.browRaise = 0.008
        t.browAngle = -0.12
        t.mouthOpen = a < 0.45 ? 0.55 : 0
        t.smile = a < 0.45 ? 0 : 0.9
        t.hop = a < 0.3 ? 0.022 * sinf(.pi * a / 0.3) : 0
        t.squash = a > 0.3 && a < 0.5 ? 0.06 : 0
        t.ring = 0.25
    }

    private func idle(_ t: inout Pose, rel: Float, toPlayer: Float, here: Bool) {
        // Turn to face the player, in a little shuffle.
        if here, abs(rel) > 0.5, clock - turnStart > 0.8 {
            turnFrom = facing
            turnTo = facing + max(-1.2, min(1.2, rel))
            turnStart = clock
        }
        let tt = Float(clock - turnStart) / 0.42
        if tt < 1 {
            let e = tt * tt * (3 - 2 * tt)
            facing = turnFrom + (turnTo - turnFrom) * e
            t.hop = 0.007 * sinf(.pi * tt)
            t.roll = 0.05 * sinf(2 * .pi * tt) * (turnTo > turnFrom ? 1 : -1)
        }
        t.smile = 0.65
        t.ring = 0.07 + 0.03 * Float(0.5 + 0.5 * sin(clock * 1.3))
        // Shy when the player leans right in.
        if here && playerDistance < 0.85 { shyUntil = clock + 1.5 }
        if clock < shyUntil {
            t.blush = 0.45
            t.smile = 0.9
            t.lookY = 0.004
        }
        // Small habits.
        if clock >= nextFidget, here {
            fidget = Int.random(in: 0..<5)
            fidgetStart = clock
            nextFidget = clock + Double.random(in: 7...15)
        }
        let f = Float(clock - fidgetStart)
        switch fidget {
        case 0 where f < 1.6:       // a curious tilt of the head
            let e = sinf(.pi * min(1, f / 1.6))
            t.roll += 0.11 * e
            t.brow = e
            t.browRaise = 0.006 * e
            t.browAngle = -0.15 * e
        case 1 where f < 2.6:       // humming to itself (silent): a tiny bob, eyes closed
            let beat = f / 0.62
            t.happy = min(1, f * 3) * min(1, (2.6 - f) * 3)
            t.squash += 0.025 * expf(-(beat - floorf(beat)) * 6)
            t.roll += 0.035 * sinf(.pi * beat)
            t.ring = 0.2 * expf(-(beat - floorf(beat)) * 4)
        case 2 where f < 1.4:       // glance at the lamp, then back
            t.lookX += (f < 1.1 ? -0.03 : 0) - lastLook.x * (f < 1.1 ? 1 : 0)
            t.lookY += f < 1.1 ? 0.01 : 0
        case 3 where f < 2.0:       // a yawn
            let e = sinf(.pi * min(1, f / 2.0))
            t.mouthOpen = 0.8 * e
            t.smile = 0.6 * (1 - e)
            t.eyeOpen = 1 - 0.8 * e
            t.pitch = -0.05 * e
        case 4 where f < 0.9:       // a little settle
            t.squash += 0.03 * sinf(.pi * f / 0.9)
        default:
            break
        }
    }

    private func think(_ t: inout Pose) {
        let a = Float(clock - modeStart)
        t.eyeOpen = 0.45
        t.lookX = 0.02 * thinkLook * (a < 0.7 ? 1 : -1)
        t.lookY = 0.012
        t.brow = 1
        t.browAngle = 0.3
        t.browRaise = -0.002
        t.mouthOpen = 0.12
        t.smile = 0
        t.roll = 0.03 * sinf(2 * .pi * a * 0.7)
        t.ring = 0.18 + 0.22 * abs(sinf(a * 9))      // working
        t.light = 4
    }

    private func bow(_ t: inout Pose) {
        let a = Float(clock - modeStart)
        let down = a < 0.35 ? a / 0.35 : (a < 0.95 ? 1 : max(0, 1 - (a - 0.95) / 0.45))
        let e = down * down * (3 - 2 * down)
        t.pitch = 0.2 * e
        t.happy = a < 1.6 ? 1 : 0
        t.blush = a < 1.8 ? 0.85 : 0.3
        t.smile = 1
        t.ring = 0.12
        t.light = 6 * max(0, 1 - a)
    }

    private func embarrassed(_ t: inout Pose) {
        let a = Float(clock - modeStart)
        // Frozen in silence, eyes darting, then shrinking a little, then a sheepish smile.
        t.blush = min(1, a * 2)
        t.brow = 1
        t.browAngle = -0.25
        t.eyeOpen = a < 0.4 ? 1.15 : 0.6
        t.lookX = a < 0.4 ? 0 : (a < 0.9 ? -0.028 : (a < 1.4 ? 0.028 : (a < 2.6 ? -0.012 : 0)))
        t.lookY = a < 2.6 ? -0.01 : 0
        t.squash = a > 1.4 && a < 3.0 ? 0.05 : 0
        t.smile = a > 2.4 ? 0.7 : 0.3
        t.ring = 0.04
    }

    // MARK: The performance

    private func perform(_ t: inout Pose) {
        guard let p = piece else { enter(.idle); return }
        let s = Float(wallNow - songStartWall)        // song time (wall clock, like the audio)
        let spb = Float(p.secondsPerBeat)
        let beats = max(0, s) / spb
        let bar = Int(beats) / p.meter
        let beatInBar = Int(beats) % p.meter
        let ph = beats - floorf(beats)
        let barPh = (beats - Float(bar * p.meter)) / Float(p.meter)
        let pulse = expf(-ph * 6)
        let endT = Float(p.endingTime)        // bar 9's downbeat (song time)

        // Melody -> the mouth and the eyes.
        var amp: Float = 0
        var pitchLift: Float = 0
        while melodyIndex + 1 < melody.count && Double(s) >= melody[melodyIndex + 1].start { melodyIndex += 1 }
        if melodyIndex < melody.count {
            let n = melody[melodyIndex]
            let age = s - Float(n.start)
            if age >= 0 && age < Float(n.dur) + 0.06 {
                amp = n.vel * min(1, age / 0.025) * (0.4 + 0.6 * expf(-age / 0.2))
                pitchLift = Float(n.midi - p.tonic) / 12
            }
        }

        t.ring = 0.2 + 0.6 * pulse
        t.light = 10 + 25 * pulse
        t.smile = 0.5
        t.mouthOpen = amp * 0.9
        t.lookX = lastLook.x * 0.6
        t.lookY = lastLook.y * 0.5 + pitchLift * 0.006
        t.brow = min(1, max(0, pitchLift - 0.3) * 2)
        t.browRaise = 0.006 * t.brow
        t.browAngle = -0.1 * t.brow
        t.eyeOpen = 1.05

        if s < Float(p.barStart(1)) {
            // The count-in: it taps the beat on its corner.
            if mode != .countIn { mode = .countIn }
            let lift = ph > 0.55 ? sinf(.pi * (ph - 0.55) / 0.45) : 0
            t.roll = -0.075 * lift
            t.squash = 0.03 * pulse
            t.eyeOpen = 1.15
            t.brow = 1
            t.browRaise = 0.007
            t.browAngle = -0.1
            t.mouthOpen = 0
            t.smile = 0.7
            t.ring = 0.15 + 0.5 * pulse
            t.light = 6 + 10 * pulse
            if beatInBar == p.meter - 1 && ph > 0.5 { t.eyeOpen = 1.25 }
            return
        }
        if s < endT {
            if mode != .performing { mode = .performing }
            groove(p, &t, bar: bar, beat: beatInBar, ph: ph, barPh: barPh, beats: beats)
            phrasing(p, &t, s: s, bar: bar, beat: beatInBar, ph: ph, endT: endT, spb: spb)
            return
        }
        if mode != .ending { mode = .ending; modeStart = clock }
        let te = s - endT
        finale(p, &t, te: te, spb: spb, pulse: pulse)
        let holdFor: Float = p.flourish ? 1.9 : 1.25
        if te > holdFor {
            songPlayer = nil                      // it finishes and removes itself
            piece = nil
            enter(embarrassedEnding ? .embarrassed : .bow)
        }
    }

    /// The groove: how each style moves the body, beat by beat.
    private func groove(_ p: BlackBoxMusic.Piece, _ t: inout Pose, bar: Int, beat: Int, ph: Float, barPh: Float, beats: Float) {
        let climax = bar == 7
        switch p.style {
        case .bounce:
            t.squash = 0.06 * expf(-ph * 9)
            if beat % 2 == 1 || climax {
                let h: Float = climax ? 0.032 : 0.018
                t.hop = ph < 0.55 ? h * sinf(.pi * ph / 0.55) : 0
            }
            t.roll = 0.065 * sinf(2 * .pi * barPh)
            if climax {
                let dir: Float = beat % 2 == 0 ? 1 : -1
                let e = min(1, ph / 0.25)
                t.yaw = 0.24 * dir * e * e * (3 - 2 * e)
                t.happy = 1
            }
        case .waltz:
            t.roll = 0.13 * sinf(2 * .pi * barPh)
            if beat == 0 { t.squash = 0.04 * expf(-ph * 7) }
            t.yaw = 0.3 * sinf(.pi * (beats / Float(p.meter)) / 2)
            t.eyeOpen = 0.7
            if climax {                                  // a twirl
                let e = barPh * barPh * (3 - 2 * barPh)
                t.yaw += 2 * .pi * e
                t.hop = 0.012 * sinf(.pi * barPh)
                t.roll *= 0.3
                t.happy = 1
            }
        case .bossa:
            t.roll = 0.09 * sinf(2 * .pi * barPh)
            t.yaw = 0.06 * sinf(4 * .pi * ph)
            t.squash = 0.025 * expf(-ph * 8)
            t.eyeOpen = 0.72
            if climax {                                  // round on its corners, like a hip circle
                t.roll = 0.12 * cosf(2 * .pi * barPh)
                t.pitch = 0.1 * sinf(2 * .pi * barPh)
                t.happy = 0.8
            }
        case .spy:
            t.pitch = 0.08                                // up on its front edge, sneaking
            let dir: Float = beat % 2 == 0 ? 1 : -1
            let e = min(1, ph / 0.2)
            let step = e * e * (3 - 2 * e)
            t.yaw = 0.18 * (dir * step - dir * (1 - step))
            t.lookX = -0.024 * dir * step + 0.024 * dir * (1 - step)   // shifty eyes
            t.squash = 0.035 * expf(-ph * 10)
            t.eyeOpen = 0.62
            if climax {
                t.hop = ph < 0.4 ? 0.016 * sinf(.pi * ph / 0.4) : 0
                t.roll = 0.06 * dir
            }
        }
    }

    /// Phrasing: bar 4's held note is a balance on an edge (eyes closed);
    /// the last beat of bar 8 gathers for the finish.
    private func phrasing(_ p: BlackBoxMusic.Piece, _ t: inout Pose, s: Float, bar: Int, beat: Int, ph: Float, endT: Float, spb: Float) {
        if bar == 4 {
            let bp = Float(beat) + ph
            let into = max(0, min(1, (bp - 1.3) / 0.7))
            let out = max(0, min(1, (Float(p.meter) - bp) / 0.3))
            let b = min(into, out)
            let e = b * b * (3 - 2 * b)
            t.roll = t.roll * (1 - e) + 0.24 * balanceSide * e
            t.pitch = t.pitch * (1 - e) + 0.05 * e
            t.yaw *= 1 - e
            t.hop *= 1 - e
            t.happy = max(t.happy, e)
        }
        if bar == 8 {
            // Settle on the held tonic; for a hit ending, crouch then jump to land on it.
            let toEnd = endT - s
            t.roll *= 0.4
            t.yaw *= 0.4
            if !p.flourish {
                let launch: Float = 0.38 * spb
                if toEnd < spb * 1.4 && toEnd > launch {
                    let c = 1 - (toEnd - launch) / (spb * 1.4 - launch)
                    t.squash = 0.09 * c
                    t.hop = 0
                } else if toEnd <= launch {
                    let a = 1 - toEnd / launch
                    t.hop = 0.05 * sinf(.pi * a)
                    t.squash = -0.04
                }
            }
        }
    }

    private func finale(_ p: BlackBoxMusic.Piece, _ t: inout Pose, te: Float, spb: Float, pulse: Float) {
        if p.flourish {
            // Up onto a corner with the arpeggio, eyes closed, and hold as it rings.
            let a = min(1, te / 0.6)
            let e = a * a * (3 - 2 * a)
            t.roll = 0.2 * balanceSide * e
            t.pitch = 0.07 * e
            t.happy = 1
            t.smile = 1
            t.mouthOpen = 0.3 * max(0, 1 - te)
            t.blush = 0.5 * e
            t.ring = 0.3 + 0.4 * max(0, 1 - te)
            t.light = 25 * max(0, 1 - te * 0.6)
        } else {
            // Ta-da: land on the hit, lean back proudly.
            t.squash = 0.12 * expf(-te * 10)
            let a = min(1, te / 0.25)
            t.pitch = -0.11 * a
            t.happy = 1
            t.smile = 1
            t.mouthOpen = te < 0.3 ? 0.6 : 0
            t.ring = 0.9 * expf(-te * 2)
            t.light = 40 * expf(-te * 2.5)
            if embarrassedEnding && te > spb * 0.6 && te < spb * 1.6 {
                // ...and it keeps going one beat too long.
                let k = (te - spb * 0.6) / spb
                t.hop = 0.03 * sinf(.pi * k)
                t.pitch = 0
                t.happy = 1
            }
        }
    }

    // MARK: Blinks, and putting the pose on the nodes

    private func blink(_ t: inout Pose) {
        if clock >= nextBlink && mode != .dozing && mode != .thinking {
            blinkStart = clock
            doubleBlink = Int.random(in: 0..<5) == 0
            nextBlink = clock + Double.random(in: 2.2...5.5)
        }
        let b = Float(clock - blinkStart)
        var close: Float = 0
        if b < 0.16 { close = sinf(.pi * b / 0.16) }
        else if doubleBlink && b > 0.24 && b < 0.4 { close = sinf(.pi * (b - 0.24) / 0.16) }
        t.eyeOpen *= 1 - 0.92 * close
    }

    private func apply(_ target: Pose, dt: Float) {
        let lively = mode == .countIn || mode == .performing || mode == .ending
        let kBody: Float = lively ? 30 : 10
        let kFace: Float = lively ? 22 : 12
        func approach(_ v: inout Float, _ to: Float, _ k: Float) { v += (to - v) * (1 - expf(-dt * k)) }
        approach(&pose.hop, target.hop, kBody * 1.4)
        approach(&pose.squash, target.squash, kBody * 1.4)
        approach(&pose.roll, target.roll, kBody)
        approach(&pose.pitch, target.pitch, kBody)
        if abs(target.yaw - pose.yaw) > 3 { pose.yaw = target.yaw } else { approach(&pose.yaw, target.yaw, kBody) }
        approach(&pose.eyeOpen, target.eyeOpen, kFace * 1.5)
        approach(&pose.happy, target.happy, kFace)
        approach(&pose.lookX, target.lookX, kFace)
        approach(&pose.lookY, target.lookY, kFace)
        approach(&pose.browRaise, target.browRaise, kFace)
        approach(&pose.browAngle, target.browAngle, kFace)
        approach(&pose.brow, target.brow, kFace * 0.8)
        approach(&pose.mouthOpen, target.mouthOpen, lively ? 30 : kFace)
        approach(&pose.smile, target.smile, kFace)
        approach(&pose.blush, target.blush, 5)
        approach(&pose.ring, target.ring, 14)
        approach(&pose.light, target.light, 12)

        // Body.
        root.eulerAngles.y = facing + pose.yaw
        hopNode.position = SCNVector3(0, max(0, pose.hop), 0)
        let sq = max(-0.06, min(0.15, pose.squash))
        hopNode.scale = SCNVector3(1 + sq * 0.5, 1 - sq, 1 + sq * 0.5)
        let roll = max(-0.4, min(0.4, pose.roll)), pitch = max(-0.3, min(0.35, pose.pitch))
        let edge: Float = 0.12
        let pv = SCNVector3(roll > 0 ? -edge : edge, 0.001, pitch > 0 ? edge : -edge)
        pivot.position = pv
        pivot.eulerAngles = SCNVector3(pitch, 0, roll)
        body.position = SCNVector3(-pv.x, -pv.y, -pv.z)

        // Face.
        let lx = max(-0.04, min(0.04, pose.lookX)), ly = max(-0.02, min(0.02, pose.lookY))
        let limit: Float = 0.026
        let excess = max(0, abs(lx) - limit)
        let squishX = max(0.6, 1 - excess * 12), squishY = 1 + excess * 6
        let open = max(0.05, pose.eyeOpen)
        for (i, side) in [Float(-1), 1].enumerated() {
            let c = face.eyes[i]
            c.position = SCNVector3(side * BlackBoxLayout.eyeX + lx, BlackBoxLayout.eyeY + ly - BlackBoxLayout.eyeH * (1 - min(1, open)) * 0.25, 0.0004)
            face.eyeShapes[i].scale = SCNVector3(squishX * (open > 1 ? 1 + (open - 1) * 0.4 : 1), open * squishY, 1)
            face.eyeShapes[i].opacity = CGFloat(1 - pose.happy)
            face.happyShapes[i].opacity = CGFloat(pose.happy)
            let b = face.brows[i]
            b.position = SCNVector3(side * BlackBoxLayout.eyeX + lx * 0.7, BlackBoxLayout.browY + pose.browRaise + ly * 0.6, 0.0004)
            b.eulerAngles.z = side * pose.browAngle
            b.opacity = CGFloat(max(0, min(1, pose.brow)))
            face.blush[i].opacity = CGFloat(max(0, min(1, pose.blush)))
        }
        let mo = max(0, min(1.2, pose.mouthOpen))
        face.mouth.opacity = CGFloat(min(1, mo * 4))
        face.mouth.scale = SCNVector3(0.8 + 0.3 * mo, 0.2 + 0.9 * mo, 1)
        face.mouth.position = SCNVector3(lx * 0.4, BlackBoxLayout.mouthY + ly * 0.5, 0.0004)
        let sm = max(0, min(1, pose.smile))
        face.smile.opacity = CGFloat(min(1, sm * 1.5) * max(0, 1 - mo * 3))
        face.smile.scale = SCNVector3(0.6 + 0.4 * sm, 0.5 + 0.5 * sm, 1)
        face.smile.position = SCNVector3(lx * 0.4, BlackBoxLayout.mouthY + 0.004 + ly * 0.5, 0.0004)
        face.ring.opacity = CGFloat(max(0.02, min(1, pose.ring)))
        face.light.intensity = CGFloat(max(0, pose.light))
    }
}

