import AVFoundation
import CoreImage
import SceneKit
import UIKit

extension HallwayScene {
    static func mirrorPlaceholder(_ message: String = "Mirror") -> UIImage {
        let size = CGSize(width: 400, height: 560)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(white: 0.22, alpha: 1).cgColor,
                          UIColor(white: 0.65, alpha: 1).cgColor,
                          UIColor(white: 0.3, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 400, y: 560), options: [])
            }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            (message as NSString).draw(in: CGRect(x: 30, y: 220, width: 340, height: 220), withAttributes: [
                .font: UIFont.systemFont(ofSize: 25, weight: .medium),
                .foregroundColor: UIColor.white, .paragraphStyle: style
            ])
        }
    }

    static func makeMirrorNode(at coord: GridCoordinate, direction: Direction, cellSize: CGFloat, frameLightingModel: SCNMaterial.LightingModel = .blinn) -> SCNNode {
        let root = SCNNode()
        root.name = "mirror"
        let frame = SCNBox(width: 0.86, height: 1.16, length: 0.055, chamferRadius: 0.018)
        let silver = SCNMaterial()
        silver.diffuse.contents = UIColor(white: 0.7, alpha: 1)
        // Eddie, Sept 20: the frame was reading as if it emitted its
        // own light -- there's no .emission set here and never was, but
        // a pure-white specular (UIColor.white) at shininess 0.9 under
        // .blinn throws a small, very hot, tightly-focused highlight
        // wherever a nearby fixture (wall light, spotlight) catches it,
        // which reads exactly like a glow on a physical iPhone screen
        // even though nothing here is technically emissive. Toning the
        // specular down to a dim gray and pulling shininess way back
        // keeps the frame reading as brushed metal -- still reflective,
        // still responds to real scene lights -- without ever flaring
        // into what looks like its own light source. Diffuse, geometry,
        // the live mirror surface, and every other material are
        // untouched.
        silver.specular.contents = UIColor(white: 0.35, alpha: 1)
        silver.shininess = 0.25
        silver.lightingModel = frameLightingModel
        frame.materials = [silver]
        root.addChildNode(SCNNode(geometry: frame))
        let plane = SCNPlane(width: 0.75, height: 1.05)
        let surface = SCNMaterial()
        surface.lightingModel = .physicallyBased // mirror surface -- needs real illumination to be usefully visible
        surface.metalness.contents = 0.0
        surface.roughness.contents = 0.6
        surface.diffuse.contents = mirrorPlaceholder()
        plane.materials = [surface]
        let node = SCNNode(geometry: plane)
        node.name = "mirrorSurface"
        node.position.z = 0.031
        root.addChildNode(node)
        let delta = direction.delta
        root.position = SCNVector3(Float(CGFloat(coord.col) * cellSize + CGFloat(delta.col) * (cellSize / 2 - 0.12)),
                                  1.6,
                                  Float(CGFloat(coord.row) * cellSize + CGFloat(delta.row) * (cellSize / 2 - 0.12)))
        switch direction {
        case .north: break
        case .south: root.eulerAngles.y = .pi
        case .east: root.eulerAngles.y = -.pi / 2
        case .west: root.eulerAngles.y = .pi / 2
        }
        return root
    }

    // Eddie, Sept 16 (Floor 1 lobby mirror aspect-fill correction): the
    // lobby mirror is built from this same makeMirrorNode() surface plane,
    // but its ROOT node is later given a non-uniform scale (mirror.scale.y
    // = 2) to make it tall and narrow. That scale stretches whatever
    // texture is already applied to the plane right along with the
    // geometry -- the live camera feed was never wrong, the surface it was
    // being painted onto was ancestor-scaled after the fact. This measures
    // the surface's ACTUAL rendered (world-space) width/height ratio,
    // walking through any ancestor scale/rotation rather than assuming the
    // plane's own local 0.75x1.05 size, so MirrorCamera can crop the feed
    // to match instead of letting SceneKit stretch it.
    static func mirrorSurfaceAspect(of node: SCNNode) -> CGFloat {
        guard let plane = node.geometry as? SCNPlane else { return 0.75 / 1.05 }
        let halfWidth = Float(plane.width / 2)
        let halfHeight = Float(plane.height / 2)
        let left = node.convertPosition(SCNVector3(-halfWidth, 0, 0), to: nil)
        let right = node.convertPosition(SCNVector3(halfWidth, 0, 0), to: nil)
        let bottom = node.convertPosition(SCNVector3(0, -halfHeight, 0), to: nil)
        let top = node.convertPosition(SCNVector3(0, halfHeight, 0), to: nil)
        let worldWidth = mirrorWorldDistance(left, right)
        let worldHeight = mirrorWorldDistance(bottom, top)
        guard worldHeight > 0 else { return plane.width / plane.height }
        return worldWidth / worldHeight
    }
}

private func mirrorWorldDistance(_ a: SCNVector3, _ b: SCNVector3) -> CGFloat {
    let dx = CGFloat(a.x - b.x)
    let dy = CGFloat(a.y - b.y)
    let dz = CGFloat(a.z - b.z)
    return (dx * dx + dy * dy + dz * dz).squareRoot()
}

/// A mirror surface's material paired with its actual rendered aspect ratio
/// (width / height in world space, from HallwayScene.mirrorSurfaceAspect),
/// so MirrorCamera can center-crop the live feed to match that surface's
/// true on-screen shape instead of letting SceneKit stretch it.
struct MirrorSurfaceTarget {
    let material: SCNMaterial
    let aspect: CGFloat
    /// Oct 8 (Cool Hallways): where the surface is, for camera demand.
    /// nil = unknown -- that surface then always counts as wanting the
    /// camera (the old floor-wide behaviour), so it can never go dark.
    var placement: MirrorPlacement? = nil
}

/// Oct 8 (Cool Hallways): a mirror surface on the floor plan, world x/z.
/// `normal` is the unit direction the glass faces (out into the room).
struct MirrorPlacement: Equatable {
    var center: SIMD2<Float>
    var normal: SIMD2<Float>

    /// From the live "mirrorSurface" node (its plane faces local +Z).
    init?(surface node: SCNNode) {
        let c = node.convertPosition(SCNVector3Zero, to: nil)
        let n = node.convertVector(SCNVector3(0, 0, 1), to: nil)
        let flat = SIMD2<Float>(n.x, n.z)
        let length = simd_length(flat)
        guard length > 0.001 else { return nil }
        center = SIMD2<Float>(c.x, c.z)
        normal = flat / length
    }

    init(center: SIMD2<Float>, normal: SIMD2<Float>) {
        self.center = center
        self.normal = simd_normalize(normal)
    }
}

/// Oct 8 (Cool Hallways): does any mirror need the front camera right now?
/// Pure geometry on the player's floor position and heading -- no raycasts.
/// Waking is strict and early (well before the glass is big on screen);
/// staying on is looser, so small turns and steps never cycle the camera.
enum MirrorDemand {
    /// Wake within this distance (m) when facing the mirror's way...
    static let wakeDistance: Float = 7.0
    /// ...and stay on until beyond this one.
    static let sleepDistance: Float = 9.0
    /// This close, it wakes whatever the heading (a quick turn must not
    /// find a stale or empty mirror)...
    static let nearWakeDistance: Float = 2.0
    /// ...and stays on regardless of heading until beyond this.
    static let nearSleepDistance: Float = 2.6
    /// Wake when the mirror is within 70 degrees of straight ahead...
    static let wakeCos: Float = cos(70 * .pi / 180)
    /// ...and stay on until it is more than 105 degrees off.
    static let sleepCos: Float = cos(105 * .pi / 180)
    /// In front of the glass by at least this (m) to wake; staying on
    /// tolerates standing just past its plane.
    static let wakeFront: Float = 0.05
    static let sleepFront: Float = -0.3
    /// Keep running this long after the last moment any mirror wanted it.
    static let sleepDelay: TimeInterval = 1.5
    /// How often the demand is re-checked (s).
    static let checkInterval: TimeInterval = 0.25

    enum Verdict: String { case near, facing, far, behind, facingAway }

    static func verdict(_ m: MirrorPlacement, player: SIMD2<Float>, yaw: Float, on: Bool) -> Verdict {
        let toPlayer = player - m.center
        let d = simd_length(toPlayer)
        if simd_dot(toPlayer, m.normal) <= (on ? sleepFront : wakeFront) { return .behind }
        if d > (on ? sleepDistance : wakeDistance) { return .far }
        if d <= (on ? nearSleepDistance : nearWakeDistance) { return .near }
        let forward = SIMD2<Float>(-sin(yaw), -cos(yaw))      // SceneKit camera looks down -Z
        let toMirror = -toPlayer / max(d, 0.001)
        return simd_dot(forward, toMirror) >= (on ? sleepCos : wakeCos) ? .facing : .facingAway
    }

    /// The decision for a whole floor: (wanted, reason). Unknown placements
    /// always want it.
    static func evaluate(_ mirrors: [MirrorPlacement?], player: SIMD2<Float>, yaw: Float, on: Bool) -> (wanted: Bool, reason: String) {
        var closest: (verdict: Verdict, distance: Float)?
        for (i, m) in mirrors.enumerated() {
            guard let m else { return (true, "mirror\(i):placementUnknown") }
            let v = verdict(m, player: player, yaw: yaw, on: on)
            let d = simd_length(player - m.center)
            if v == .near || v == .facing {
                return (true, "mirror\(i):\(v.rawValue) d=\(String(format: "%.1f", d))")
            }
            if closest == nil || d < closest!.distance { closest = (v, d) }
        }
        guard let closest else { return (false, "noMirrors") }
        return (false, "\(closest.verdict.rawValue) d=\(String(format: "%.1f", closest.distance))")
    }
}

/// Oct 8: wake at once, sleep only after `sleepDelay` of nobody wanting it.
struct MirrorDemandTracker {
    private(set) var on = false
    private var unwantedSince: TimeInterval?

    /// Returns the new state when it changes, else nil.
    mutating func update(wanted: Bool, now: TimeInterval) -> Bool? {
        if wanted {
            unwantedSince = nil
            guard !on else { return nil }
            on = true
            return true
        }
        guard on else { unwantedSince = nil; return nil }
        if let since = unwantedSince {
            guard now - since >= MirrorDemand.sleepDelay else { return nil }
            on = false
            unwantedSince = nil
            return false
        }
        unwantedSince = now
        return nil
    }

    mutating func reset() { on = false; unwantedSince = nil }
}

/// Owns only a live preview: no microphone input, still capture, or recording output.
@MainActor
final class MirrorCamera {
    /// Sept 25 (Designer wall authoring, live Mirror ADD): `private(set)
    /// var` (was `let`) so DecoratorState-authored mirrors can register
    /// their surface into the live reflection feed via addSurface (and out
    /// again via removeSurface) without a floor reload -- see
    /// ContentView's decorator closure wiring.
    private(set) var surfaces: [MirrorSurfaceTarget]
    /// The capture pipeline is running (camera on, frames painted).
    private var active = false
    /// Oct 8 (Cool Hallways): the app/lifecycle allows the camera
    /// (ContentView's cameraEnabled) -- necessary, no longer sufficient.
    private var allowed = false
    /// Oct 8: a mirror is near enough and in view to need it.
    private var demand = MirrorDemandTracker()
    private var demandTimer: Timer?
    /// The player's floor position (x, z) and yaw; nil = unknown (the
    /// demand then stays as it is).
    var playerPose: (() -> (position: SIMD2<Float>, yaw: Float)?)?
    /// Diagnostics/tests: is the capture pipeline running? Does a mirror want it?
    var isCapturing: Bool { active }
    var isDemanded: Bool { demand.on }
    private var requestedPermission = false
    private var worker: MirrorCaptureWorker?
    private var rotationObserver: NSObjectProtocol?
    private let expressionAnalyzer: MirrorGestureAnalyzer?

    init(surfaces: [MirrorSurfaceTarget], comments: MirrorCommentState? = nil) {
        self.surfaces = surfaces
        expressionAnalyzer = comments.map { state in
            MirrorGestureAnalyzer { [weak state] signals, time in state?.receive(signals, time: time) }
        }
        // Eddie, Sept 12, item 6: "View the mirror while the iPhone
        // is in PORTRAIT. Rotate the phone to LANDSCAPE. My camera
        // image/face in the mirror rotates incorrectly and appears
        // SIDEWAYS." Root cause: updateOrientation() below was only
        // ever called from setActive() -- i.e. when the mirror is
        // freshly (re)activated (ContentView's makeUIView/updateUIView/
        // dismantleUIView) -- nothing anywhere re-invoked it while the
        // player is already looking into an already-active mirror and
        // simply rotates the phone in place, so the capture
        // connection's videoOrientation stayed stuck at whatever it
        // was the moment the mirror last turned on.
        //
        // This observer is the missing trigger -- it doesn't read the
        // device orientation itself (that stays updateOrientation()'s
        // job, via the more reliable interfaceOrientation, which
        // already ignores face-up/face-down and respects any rotation
        // lock); it just re-runs that same existing check whenever ANY
        // device-rotation notification fires, including spurious/flat
        // ones (harmless -- MirrorCaptureWorker.setOrientation already
        // no-ops unless the value actually changed). No other mirror/
        // camera behavior changes: this only re-applies the same
        // orientation logic that already ran at activation time.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        rotationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.active else { return }
            self.updateOrientation()
        }
    }

    func setExpressionAnalysisEnabled(_ enabled: Bool) { expressionAnalyzer?.setEnabled(enabled) }

    /// Registers a mirror surface added live via the Designer (Decorator)
    /// into the live reflection feed -- CenterContentView creates the
    /// camera once per floor by enumerating "mirrorSurface"-named nodes,
    /// so a newly-authored mirror needs this to show the player's face
    /// without reloading the floor.
    func addSurface(_ material: SCNMaterial, aspect: CGFloat, placement: MirrorPlacement? = nil) {
        surfaces.append(MirrorSurfaceTarget(material: material, aspect: aspect, placement: placement))
        refreshDemand(reason: "surfaceAdded")
    }

    /// Reverse of addSurface above -- drops the given surface (identity
    /// match on the material) when its mirror is deleted in the Designer.
    func removeSurface(_ material: SCNMaterial) {
        surfaces.removeAll { $0.material === material }
        refreshDemand(reason: "surfaceRemoved")
    }

    // Eddie, Sept 17: reverted to its original form -- routing the
    // startup permission gate through here (an onPermissionResolved
    // completion) raced updateUIView's own, unconditional
    // setActive(cameraEnabled) call, which runs right after this one
    // and (with cameraEnabled still false pre-tap) flipped `active`
    // back off before the async requestAccess completion could see
    // `guard self.active` succeed -- so the completion silently never
    // fired. See MirrorCamera.resolveAuthorization below: a completely
    // separate, non-reentrant permission check that doesn't touch
    // `active`/`worker`/the placeholder text at all, so nothing can
    // race it.
    func setActive(_ enabled: Bool) {
        if !enabled {
            expressionAnalyzer?.setEnabled(false)
            if allowed {
                allowed = false
                stopDemandChecks()
            }
            if active {
                stopCapture(reason: "lifecycle")
                show("Mirror")
            }
            return
        }
        if !allowed {
            allowed = true
            startDemandChecks()
            refreshDemand(reason: "allowed")     // decide at once, no tick wait
        }
        guard demand.on else { return }
        if active {
            updateOrientation()
            return
        }
        startCapture()
    }

    // MARK: Oct 8 (Cool Hallways) -- demand-driven capture

    private func startDemandChecks() {
        guard demandTimer == nil else { return }
        demandTimer = Timer.scheduledTimer(withTimeInterval: MirrorDemand.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDemand(reason: nil) }
        }
    }

    private func stopDemandChecks() {
        demandTimer?.invalidate()
        demandTimer = nil
        demand.reset()
    }

    /// Re-decide whether any mirror needs the camera; start or stop it.
    private func refreshDemand(reason forced: String?) {
        guard allowed else { return }
        let decision: (wanted: Bool, reason: String)
        if surfaces.isEmpty {
            decision = (false, "noMirrors")
        } else if let pose = playerPose?() {
            decision = MirrorDemand.evaluate(surfaces.map(\.placement), player: pose.position, yaw: pose.yaw, on: demand.on)
        } else if surfaces.contains(where: { $0.placement == nil }) {
            decision = (true, "placementUnknown")
        } else {
            return                                   // no pose yet: leave it as it is
        }
        // A surface removal with nothing left is immediate, not delayed.
        if surfaces.isEmpty, demand.on { demand.reset(); stopCapture(reason: "noMirrors"); return }
        guard let change = demand.update(wanted: decision.wanted, now: CACurrentMediaTime()) else { return }
        if change {
            diag("mirror.demand.on", ["why": decision.reason, "trigger": forced ?? "check", "mirrors": surfaces.count])
            if !active { startCapture() }
        } else {
            diag("mirror.demand.off", ["why": decision.reason, "mirrors": surfaces.count])
            // Out of sight by definition: the last reflection stays on the
            // glass (no placeholder flash on the way back); fresh frames
            // replace it as soon as capture restarts.
            if active { stopCapture(reason: decision.reason) }
        }
    }

    private func stopCapture(reason: String) {
        guard active else { return }
        active = false
        worker?.stop()
        diag("mirror.camera.stopped", ["why": reason])
    }

    /// The original activation path (permission handling unchanged).
    private func startCapture() {
        guard !active else { return }
        active = true
        diag("mirror.camera.starting", ["auth": AVCaptureDevice.authorizationStatus(for: .video).rawValue])
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            show("Allow camera access\nto see your reflection")
            guard !requestedPermission else { return }
            requestedPermission = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.requestedPermission = false
                    guard self.active else { return }
                    if allowed { self.start() }
                    else { self.show("Enable camera access\nin Settings to use\nthis mirror") }
                }
            }
        default: show("Enable camera access\nin Settings to use\nthis mirror")
        }
    }

    // Eddie, Sept 17 (startup permission gate v2): a standalone
    // authorization check/request, deliberately independent of any
    // MirrorCamera instance and its active/inactive toggle above --
    // reuses the exact same AVCaptureDevice APIs setActive's
    // .notDetermined branch already calls, just without touching
    // `active`, `worker`, or the placeholder text, so updateUIView's
    // repeated setActive(cameraEnabled) calls can never race it. Not a
    // second camera-permission mechanism -- the only mechanism, called
    // from two different moments.
    static func resolveAuthorization(completion: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { completion() }
            }
        default:
            completion()
        }
    }

    private func start() {
        if worker == nil {
            worker = MirrorCaptureWorker(analyzer: expressionAnalyzer) { [weak self] image in
                guard let self, self.active else { return }
                for surface in self.surfaces {
                    surface.material.diffuse.contents = Self.coverCropped(image, toAspect: surface.aspect)
                }
            } unavailable: { [weak self] in
                guard let self, self.active else { return }
                self.show("Live mirror\nrequires a front camera")
            }
        }
        updateOrientation()
        worker?.start()
    }

    private func updateOrientation() {
        let orientation = (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?.interfaceOrientation ?? .portrait
        worker?.setOrientation(orientation.rawValue)
    }

    private func show(_ message: String) {
        let image = HallwayScene.mirrorPlaceholder(message)
        for surface in surfaces {
            surface.material.diffuse.contents = Self.coverCropped(image, toAspect: surface.aspect)
        }
    }

    // Eddie, Sept 16 (Floor 1 lobby mirror aspect-fill correction):
    // center-crop -- CSS `object-fit: cover` -- rather than stretch, so a
    // surface whose rendered shape differs from the source image's aspect
    // (e.g. a mirror made taller via ancestor node scale) gets a correctly
    // proportioned image instead of a distorted one. A no-op (returns the
    // same image) whenever the aspects already match to within a hundredth,
    // which is true today for every ordinary, unscaled mirror -- this only
    // does real cropping work for a surface like the Floor 1 lobby mirror.
    private static func coverCropped(_ image: UIImage, toAspect aspect: CGFloat) -> UIImage {
        guard aspect > 0, let cgImage = image.cgImage else { return image }
        let sourceWidth = CGFloat(cgImage.width)
        let sourceHeight = CGFloat(cgImage.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return image }
        let sourceAspect = sourceWidth / sourceHeight
        guard abs(sourceAspect - aspect) > 0.01 else { return image }
        let width: CGFloat
        let height: CGFloat
        if aspect < sourceAspect {
            height = sourceHeight
            width = height * aspect
        } else {
            width = sourceWidth
            height = width / aspect
        }
        let cropRect = CGRect(x: (sourceWidth - width) / 2, y: (sourceHeight - height) / 2, width: width, height: height)
        guard let cropped = cgImage.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    deinit {
        demandTimer?.invalidate()
        expressionAnalyzer?.setEnabled(false)
        worker?.stop()
        if let rotationObserver { NotificationCenter.default.removeObserver(rotationObserver) }
    }
}

/// All session and frame state is confined to queue, including delegate callbacks.
nonisolated private final class MirrorCaptureWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Hallways.mirror.capture", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let context = CIContext()
    private var configured = false
    private var lastFrameTime = -Double.infinity
    private var orientationRawValue = 1
    private let onFrame: @MainActor @Sendable (UIImage) -> Void
    private let unavailable: @MainActor @Sendable () -> Void
    private let analyzer: MirrorGestureAnalyzer?

    init(analyzer: MirrorGestureAnalyzer? = nil, onFrame: @escaping @MainActor @Sendable (UIImage) -> Void,
         unavailable: @escaping @MainActor @Sendable () -> Void) {
        self.analyzer = analyzer
        self.onFrame = onFrame
        self.unavailable = unavailable
    }

    func setOrientation(_ value: Int) {
        queue.async {
            guard self.orientationRawValue != value else { return }
            self.orientationRawValue = value
            self.orientConnection()
        }
    }

    private func orientConnection() {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = AVCaptureVideoOrientation(rawValue: orientationRawValue) ?? .portrait
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    func start() {
        queue.async {
            if !self.configured {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                      let input = try? AVCaptureDeviceInput(device: device) else {
                    DispatchQueue.main.async { self.unavailable() }
                    return
                }
                self.session.beginConfiguration()
                self.session.sessionPreset = .vga640x480
                guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.unavailable() }
                    return
                }
                self.session.addInput(input)
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.output.setSampleBufferDelegate(self, queue: self.queue)
                self.session.addOutput(self.output)
                self.orientConnection()
                self.session.commitConfiguration()
                self.configured = true
            }
            self.lastFrameTime = -Double.infinity
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard time - lastFrameTime >= 1.0 / 15, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = time
        let image = CIImage(cvPixelBuffer: buffer)
        let bounds = image.extent
        // Center-crop to the frame, preserving proportions (CSS cover).
        let width = min(bounds.width, bounds.height * 5 / 7)
        let height = width * 7 / 5
        let crop = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        guard let cgImage = context.createCGImage(image, from: crop) else { return }
        let preview = UIImage(cgImage: cgImage)
        DispatchQueue.main.async { self.onFrame(preview) }
        analyzer?.submit(cgImage, time: time)
    }
}
