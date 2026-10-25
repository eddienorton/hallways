import SceneKit
import UIKit

/// Oct 11 -- CAMERA MAGNIFIER: pinch to look closer, without moving.
///
/// A lens zoom on the live 3D camera: the field of view narrows (up to
/// `maxZoom`) and the camera turns by the small angle that keeps the spot
/// under the pinch where the fingers are. The camera never MOVES, so it can
/// never clip through the monitor, desk or walls. The whole rendered world
/// scales together; SwiftUI layers on top (HUD, the phone) are untouched.
///
/// It always stays inside the original view: at any zoom the visible area is
/// clamped to what was on screen at 1x, so the view can't wander off, and
/// pinching back below `snapBackBelow` restores the original field of view
/// and angles exactly.
///
/// Oct 11 -- PANNING while zoomed (never past the 1x view):
///   * TWO fingers: the pinch follows the live centre of the fingers, so
///     moving both fingers together pans (zoom and pan in one gesture, as in
///     Photos/Maps). This works over the computer's own screen too, through
///     `CameraMagnifierGestures` -- a window-level pinch that sees the
///     fingers wherever they land.
///   * ONE finger on the room around the monitor drags the view.
///   * One finger ON the monitor stays the computer's (taps, games, lists).
///
/// WHERE IT APPLIES: `applies` -- stationary viewing states where a pinch
/// would otherwise do nothing. Today only seated at the office computer. Out
/// in the building a pinch still WALKS (direct touch, unchanged); adding a
/// state here (e.g. a wall game terminal) is a one-line change.
@MainActor
final class CameraMagnifier {
    static let shared = CameraMagnifier()
    /// THE TUNING NUMBERS: the closest look, and where a release snaps home.
    static let maxZoom: Double = 3.0
    static let snapBackBelow: Double = 1.05

    static var applies: Bool { OfficeComputer.shared.phase == .on || ConferenceMeeting.magnifierApplies }   // Oct 11: + seated at the conference table

    private(set) var zoom: Double = 1
    var isZoomed: Bool { zoom > 1.0001 }
    /// A pinch is driving the zoom right now.
    var isDriving: Bool { gestureSource != nil }
    /// Called after every change of the view (the computer re-lays its screen).
    var onViewChanged: (() -> Void)?

    private weak var camera: SCNNode?
    private weak var view: SCNView?
    private var baseFOV: CGFloat = 75
    private var baseEuler = SCNVector3Zero
    /// The view centre's angle off the original forward (radians; +x right, +y up).
    private var center = (x: 0.0, y: 0.0)
    private var gestureSource: String?
    private var startZoom: Double = 1
    private var anchorNDC = (x: 0.0, y: 0.0)
    private var anchorAngle = (x: 0.0, y: 0.0)

    private init() {}

    /// Half-extent tangents of the ORIGINAL (1x) view.
    private func baseTangents() -> (h: Double, v: Double)? {
        guard let view, let lens = camera?.camera else { return nil }
        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return nil }
        let aspect = Double(size.width / size.height)
        let t = tan(Double(baseFOV) * .pi / 360)
        return lens.projectionDirection == .horizontal ? (t, t / aspect) : (t * aspect, t)
    }

    /// A pinch began at `point` (in `view`'s own coordinates). False = not taken
    /// (another pinch is already driving, or there is no camera).
    @discardableResult
    func begin(source: String, at point: CGPoint, camera: SCNNode, view: SCNView, takeover: Bool = false) -> Bool {
        // The same source may restart (its last gesture was cancelled without
        // an end); a different source never steals a pinch in progress --
        // except `takeover` (the window-level pinch, which also pans): it
        // re-anchors from the current view, so nothing jumps.
        guard gestureSource == nil || gestureSource == source || takeover, camera.camera != nil else { return false }
        if self.camera !== camera { reset(animated: false) }
        self.camera = camera
        self.view = view
        if !isZoomed {                                      // the 1x view is the home view
            baseFOV = camera.camera?.fieldOfView ?? 75
            baseEuler = camera.eulerAngles
            center = (0, 0)
            zoom = 1
        }
        guard let t = baseTangents() else { return false }
        let size = view.bounds.size
        anchorNDC = (Double(point.x / size.width) * 2 - 1, 1 - Double(point.y / size.height) * 2)
        anchorAngle = (center.x + atan(anchorNDC.x * t.h / zoom), center.y + atan(anchorNDC.y * t.v / zoom))
        startZoom = zoom
        gestureSource = source
        diag("magnifier.begin", ["source": source, "zoom": zoom])
        return true
    }

    func update(source: String, scale: Double) {
        guard gestureSource == source else { return }
        apply(zoom: startZoom * scale)
    }

    /// Oct 11: the pinch's fingers have moved -- `point` (view coordinates)
    /// is their live centre. Zoom from the spread, pan by keeping the spot
    /// first pinched under the fingers' centre.
    func update(source: String, scale: Double, at point: CGPoint) {
        guard gestureSource == source, let view else { return }
        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        anchorNDC = (Double(point.x / size.width) * 2 - 1, 1 - Double(point.y / size.height) * 2)
        apply(zoom: startZoom * scale)
    }

    // MARK: One-finger pan (on the room around the monitor)

    private var panStartCenter = (x: 0.0, y: 0.0)

    /// Only while zoomed (at 1x there is nothing to pan to) and no pinch is on.
    @discardableResult
    func panBegan(source: String) -> Bool {
        guard gestureSource == nil, isZoomed, camera != nil else { return false }
        gestureSource = source
        panStartCenter = center
        diag("magnifier.panBegin", ["source": source, "zoom": zoom])
        return true
    }

    /// `translation`: the finger's travel since the pan began (view points).
    /// The world follows the finger.
    func panChanged(source: String, translation: CGPoint) {
        guard gestureSource == source, let view, let t = baseTangents() else { return }
        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let ax = Double(translation.x / size.width) * 2 * t.h / zoom
        let ay = Double(translation.y / size.height) * 2 * t.v / zoom
        show(zoom: zoom, cx: panStartCenter.x - ax, cy: panStartCenter.y + ay)
    }

    func panEnded(source: String) {
        guard gestureSource == source else { return }
        gestureSource = nil
        diag("magnifier.panEnd", ["source": source])
    }

    func end(source: String, scale: Double) {
        guard gestureSource == source else { return }
        gestureSource = nil
        apply(zoom: startZoom * scale)
        if zoom < Self.snapBackBelow { reset(animated: true) }
        diag("magnifier.end", ["source": source, "zoom": zoom])
    }

    private func apply(zoom requested: Double) {
        guard let t = baseTangents() else { return }
        let z = min(Self.maxZoom, max(1, requested))
        // Keep the anchor under the fingers (then `show` keeps the view inside the 1x view).
        show(zoom: z, cx: anchorAngle.x - atan(anchorNDC.x * t.h / z), cy: anchorAngle.y - atan(anchorNDC.y * t.v / z))
    }

    /// The one place the lens is set: clamped so the view never leaves the 1x view.
    private func show(zoom z: Double, cx requestedX: Double, cy requestedY: Double) {
        guard let camera, let lens = camera.camera, let t = baseTangents() else { return }
        var cx = requestedX, cy = requestedY
        let roomX = atan(t.h) - atan(t.h / z), roomY = atan(t.v) - atan(t.v / z)
        cx = min(roomX, max(-roomX, cx))
        cy = min(roomY, max(-roomY, cy))
        zoom = z
        center = (cx, cy)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        lens.fieldOfView = CGFloat(atan(tan(Double(baseFOV) * .pi / 360) / z) * 360 / .pi)
        camera.eulerAngles = SCNVector3(baseEuler.x + Float(cy), baseEuler.y - Float(cx), baseEuler.z)
        SCNTransaction.commit()
        onViewChanged?()
    }

    /// Back to the exact original view (field of view and angles). Safe to
    /// call at any time; does nothing to a camera that was never zoomed.
    func reset(animated: Bool) {
        gestureSource = nil
        let wasOff = !isZoomed && center.x == 0 && center.y == 0
        zoom = 1
        center = (0, 0)
        guard !wasOff, let camera, let lens = camera.camera else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.25 : 0
        SCNTransaction.completionBlock = { [weak self] in DispatchQueue.main.async { self?.onViewChanged?() } }
        lens.fieldOfView = baseFOV
        camera.eulerAngles = baseEuler
        SCNTransaction.commit()
        onViewChanged?()
        diag("magnifier.reset", ["animated": animated])
    }
}

/// Oct 11 -- the window-level pinch for the magnifier. Installed once on the
/// app window (TouchTrackingSCNView.didMoveToWindow), so it sees a two-finger
/// pinch wherever the fingers land -- on the computer's SwiftUI screen as well
/// as on the 3D room. It only ever begins while `CameraMagnifier.applies`
/// (seated at the office computer); everywhere else it declines at once, so
/// the hallways' own pinch (walking) is untouched. It recognizes alongside
/// every other recognizer and never cancels or delays their touches, so taps
/// and the computer's own controls behave exactly as before.
@MainActor
final class CameraMagnifierGestures: NSObject, UIGestureRecognizerDelegate {
    static let shared = CameraMagnifierGestures()
    private weak var window: UIWindow?
    private weak var pinch: UIPinchGestureRecognizer?

    func install(on window: UIWindow) {
        guard self.window !== window else { return }
        if let old = pinch { old.view?.removeGestureRecognizer(old) }
        let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        window.addGestureRecognizer(recognizer)
        self.window = window
        pinch = recognizer
        diag("magnifier.windowPinchInstalled", [:])
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Oct 21: never for a pinch inside the Building Life tray (it was: never
        // while the phone's Building GPS map had the touch).
        CameraMagnifier.applies && gestureRecognizer.location(in: nil).y < BuildingLifeTrayCover.top
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        let computer = OfficeComputer.shared
        let point = g.location(in: nil)                          // window coordinates
        // Oct 11: seated at the conference table -- the same lens, its own camera.
        if computer.phase != .on, ConferenceMeeting.magnifierApplies || CameraMagnifier.shared.isDriving {
            switch g.state {
            case .began: ConferenceMeeting.pinchBegan(windowPoint: point, source: "window")
            case .changed:
                if g.numberOfTouches >= 2 { ConferenceMeeting.pinchMoved(windowPoint: point, scale: Double(g.scale), source: "window") }
                else { CameraMagnifier.shared.update(source: "window", scale: Double(g.scale)) }
            case .ended, .cancelled, .failed: CameraMagnifier.shared.end(source: "window", scale: Double(g.scale))
            default: break
            }
            return
        }
        switch g.state {
        case .began:
            computer.pinchBegan(windowPoint: point, source: "window", takeover: true)
        case .changed:
            // A lifted finger makes the centre jump: hold the last pan until both are down.
            if g.numberOfTouches >= 2 {
                computer.pinchMoved(windowPoint: point, scale: Double(g.scale), source: "window")
            } else {
                computer.pinchChanged(scale: Double(g.scale), source: "window")
            }
        case .ended, .cancelled, .failed:
            computer.pinchEnded(scale: Double(g.scale), source: "window")
        default:
            break
        }
    }
}
