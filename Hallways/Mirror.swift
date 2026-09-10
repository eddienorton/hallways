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

    static func makeMirrorNode(at coord: GridCoordinate, direction: Direction, cellSize: CGFloat) -> SCNNode {
        let root = SCNNode()
        root.name = "mirror"
        let frame = SCNBox(width: 0.86, height: 1.16, length: 0.055, chamferRadius: 0.018)
        let silver = SCNMaterial()
        silver.diffuse.contents = UIColor(white: 0.7, alpha: 1)
        silver.specular.contents = UIColor.white
        silver.shininess = 0.9
        silver.lightingModel = .blinn
        frame.materials = [silver]
        root.addChildNode(SCNNode(geometry: frame))
        let plane = SCNPlane(width: 0.75, height: 1.05)
        let surface = SCNMaterial()
        surface.lightingModel = .constant
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
}

/// Owns only a live preview: no microphone input, still capture, or recording output.
@MainActor
final class MirrorCamera {
    private let materials: [SCNMaterial]
    private var active = false
    private var requestedPermission = false
    private var worker: MirrorCaptureWorker?

    init(materials: [SCNMaterial]) { self.materials = materials }

    func setActive(_ enabled: Bool) {
        if !enabled {
            if active {
                active = false
                worker?.stop()
                show("Mirror")
            }
            return
        }
        if active {
            updateOrientation()
            return
        }
        active = true
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

    private func start() {
        if worker == nil {
            worker = MirrorCaptureWorker { [weak self] image in
                guard let self, self.active else { return }
                for material in self.materials { material.diffuse.contents = image }
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
        for material in materials { material.diffuse.contents = image }
    }

    deinit { worker?.stop() }
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

    init(onFrame: @escaping @MainActor @Sendable (UIImage) -> Void,
         unavailable: @escaping @MainActor @Sendable () -> Void) {
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
    }
}
