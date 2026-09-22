import SwiftUI
import UIKit

/// The grid alone owns these touches. Edits are committed after a one-finger
/// gesture ends, so a second finger can turn it into a pinch without painting.
struct EditorGridViewport<Content: View>: UIViewRepresentable {
    let interactionID: String
    let content: Content
    let edit: ([CGPoint]) -> Void

    func makeUIView(context: Context) -> GridTouchViewport<Content> {
        GridTouchViewport(content: content)
    }
    func updateUIView(_ view: GridTouchViewport<Content>, context: Context) {
        if view.interactionID != interactionID {
            view.cancelPendingEdits()
            view.interactionID = interactionID
        }
        NSLog("%@", "[PLACEDIAG] VIEW UPDATE id=\(interactionID) viewport=\(ObjectIdentifier(view))")
        view.host.rootView = content
        view.edit = edit
    }
    static func dismantleUIView(_ view: GridTouchViewport<Content>, coordinator: ()) {
        view.cancelPendingEdits()
    }
}

final class GridTouchViewport<Content: View>: UIView {
    let host: UIHostingController<Content>
    var edit: ([CGPoint]) -> Void = { _ in }
    var interactionID = ""
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var fingers: [UITouch: CGPoint] = [:]
    private var points: [CGPoint] = []
    private var start = CGPoint.zero
    private var previous = CGPoint.zero
    private var pinchCenter = CGPoint.zero
    private var pinchDistance: CGFloat = 1
    private var usedMultipleFingers = false
    private var moved = false
    private var resetting = false

    init(content: Content) {
        host = UIHostingController(rootView: content)
        super.init(frame: .zero)
        clipsToBounds = true
        isMultipleTouchEnabled = true
        backgroundColor = .white
        host.view.backgroundColor = .white
        host.view.isUserInteractionEnabled = false
        host.view.layer.anchorPoint = .zero
        addSubview(host.view)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.bounds = CGRect(origin: .zero, size: bounds.size)
        applyTransform()
    }
    func cancelPendingEdits() {
        NSLog("%@", "[PLACEDIAG] CANCEL PENDING id=\(interactionID) fingers=\(fingers.count) samples=\(points.count)")
        points = []
        // Suppress the rest of any gesture spanning a floor/tool change.
        if !fingers.isEmpty { usedMultipleFingers = true }
    }
    private func applyTransform() {
        offset.x = min(0, max(bounds.width * (1 - zoom), offset.x))
        offset.y = min(0, max(bounds.height * (1 - zoom), offset.y))
        host.view.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        host.view.layer.position = offset
    }
    private func gridPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom)
    }
    private func pinchMeasurement() -> (CGPoint, CGFloat) {
        let p = Array(fingers.values.prefix(2))
        return (CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2),
                max(1, hypot(p[0].x - p[1].x, p[0].y - p[1].y)))
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        NSLog("%@", "[PLACEDIAG] TOUCH BEGIN id=\(interactionID) points=\(touches.map { $0.location(in: self) }) tapCounts=\(touches.map { $0.tapCount }) bounds=\(bounds)")
        if fingers.isEmpty, let touch = touches.first {
            moved = false
            usedMultipleFingers = false
            // Sept 20 (tap-latency/dropped-placement fix): a same-spot
            // double-tap still resets zoom (below), but no longer holds
            // back or discards the tap that triggered it -- see
            // touchesEnded's own comment for why the previous
            // "wait 300ms to see if a second tap follows, then decide
            // whether to deliver or discard" scheme was both the
            // sluggish-pencil-tap complaint AND, for a genuinely
            // same-spot follow-up tap (e.g. tapping again because
            // nothing visibly happened yet), a way for a real object
            // placement to be silently thrown away with no error.
            resetting = touch.tapCount == 2
            start = touch.location(in: self)
            previous = start
            points = [gridPoint(start)]
            if resetting {
                zoom = 1
                offset = .zero
                applyTransform()
            }
        }
        for touch in touches { fingers[touch] = touch.location(in: self) }
        if fingers.count >= 2 {
            usedMultipleFingers = true
            points = []
            (pinchCenter, pinchDistance) = pinchMeasurement()
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { fingers[touch] = touch.location(in: self) }
        if fingers.count >= 2 {
            let (center, distance) = pinchMeasurement()
            let anchor = gridPoint(pinchCenter)
            zoom = min(4, max(1, zoom * distance / pinchDistance))
            offset = CGPoint(x: center.x - anchor.x * zoom, y: center.y - anchor.y * zoom)
            pinchCenter = center
            pinchDistance = distance
            applyTransform()
        } else if !usedMultipleFingers, !resetting, let p = fingers.values.first {
            if hypot(p.x - start.x, p.y - start.y) > 6 { moved = true }
            if zoom > 1 {
                if moved {
                    offset.x += p.x - previous.x
                    offset.y += p.y - previous.y
                    applyTransform()
                }
            } else {
                points.append(gridPoint(p))
            }
            previous = p
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { fingers.removeValue(forKey: touch) }
        guard fingers.isEmpty else { return }
        guard !usedMultipleFingers, !resetting else {
            NSLog("%@", "[PLACEDIAG] GridTouchViewport.touchesEnded: SWALLOWED -- usedMultipleFingers=\(usedMultipleFingers) resetting=\(resetting), edit() NOT called")
            points = []
            return
        }
        if moved {
            if zoom == 1 {
                NSLog("%@", "[PLACEDIAG] GridTouchViewport.touchesEnded: MOVED gesture, delivering edit(points) with \(points.count) points, zoom=\(zoom)")
                edit(points)
            } else {
                NSLog("%@", "[PLACEDIAG] GridTouchViewport.touchesEnded: MOVED gesture but zoom=\(zoom) != 1 -- edit() NOT called (pan, not paint)")
            }
        } else {
            // Sept 20 (tap-latency/dropped-placement fix): deliver a
            // plain tap immediately instead of waiting ~300ms to see
            // whether a second tap follows -- see touchesBegan's own
            // comment. A genuine double-tap still resets zoom (handled
            // above, on the SECOND tap's touchesBegan/touchesEnded,
            // which reaches the guard right above this and returns
            // without editing), it just no longer holds the first tap
            // hostage while it waits to find out.
            // TEMPORARY DIAGNOSTIC (Eddie, Sept 20, object-placement trace) -- remove after root cause is found.
            let tapLocation = gridPoint(start)
            NSLog("%@", "[PLACEDIAG] GridTouchViewport.touchesEnded: PLAIN TAP at start=\(start) -> gridPoint=\(tapLocation), zoom=\(zoom), offset=\(offset), bounds=\(bounds), delivering edit([\(tapLocation)])")
            edit([tapLocation])
        }
        points = []
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        NSLog("%@", "[PLACEDIAG] TOUCH CANCELLED id=\(interactionID) samples=\(points.count)")
        for touch in touches { fingers.removeValue(forKey: touch) }
        usedMultipleFingers = true
        points = []
    }
}
