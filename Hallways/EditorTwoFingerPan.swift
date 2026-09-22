import SwiftUI
import UIKit

/// Gesture only: all grid rendering stays in the existing SwiftUI hierarchy.
struct EditorTwoFingerPan: UIGestureRecognizerRepresentable {
    var update: (CGSize, CGPoint, Bool) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard let translation = context.converter.localTranslation else { return }
        update(CGSize(width: translation.x, height: translation.y), context.converter.localLocation,
               recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed)
    }
}
