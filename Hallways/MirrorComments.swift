import SwiftUI
import Combine
import Vision
import CoreImage

nonisolated enum MirrorGesture: String, CaseIterable, Sendable {
    case smile, mouthOpen, eyebrowsRaised, frown
    var comments: [String] {
        switch self {
        case .smile: return ["You have a nice smile.", "There it is.", "I saw that smile.", "Someone’s pleased.", "Keep that one.", "Now we’re talking.", "That works.", "Okay, charming.", "Something good happen?", "There you go."]
        case .mouthOpen: return ["Do you have something to say?", "I’m listening.", "Go ahead.", "Was it something I said?", "Well?", "Say ahhh.", "That’s quite a reaction.", "You can close it now.", "Cat got your tongue?", "I’m waiting."]
        case .eyebrowsRaised: return ["Oh really?", "That got your attention.", "Interesting, huh?", "I know that look.", "Surprised?", "Didn’t expect that?", "Those eyebrows have questions.", "Something just happened.", "You seem intrigued.", "Go on…"]
        // Eddie, Sept 13: "add frown as a fourth ordinary-mirror
        // expression." Same short, dry, slightly teasing voice as the
        // other three pools -- never mocking, never therapy-toned.
        case .frown: return ["Rough one, huh?", "That bad?", "Turn that frown around.", "Someone rain on your parade?", "That’s a lot of frown.", "Chin up.", "Not your day, huh?", "I’ve seen sunnier faces in here.", "Whatever it is, it’ll pass.", "Want to try that again?"]
        }
    }
}

/// Ratios describe visible geometry, not emotions. No ARKit/camera session here.
nonisolated struct MirrorFaceSignals: Sendable {
    var smile = false
    var mouth: Double = 0
    var brows: Double = 0.45
    /// How far the mouth's outer corners droop below its own vertical
    /// center, normalized by mouth width -- see MirrorGestureAnalyzer.
    /// analyze()'s cornerDroop(_:) for the actual geometry and sign
    /// convention. 0 (or negative) is a neutral/upturned mouth; bigger
    /// positive values are a more visibly downturned one.
    var frown: Double = 0
    func dominant(retaining active: MirrorGesture?) -> (MirrorGesture?, Double) {
        func above(_ value: Double, _ threshold: Double, _ state: MirrorGesture) -> Bool {
            value > threshold * (active == state ? 0.88 : 1)
        }
        if above(mouth, 0.36, .mouthOpen) { return (.mouthOpen, mouth) }
        if smile { return (.smile, 1) }
        // Checked before eyebrowsRaised (mouth-shape gestures grouped
        // together) -- smile/frown are opposite mouth-corner curls, so
        // in practice they never both cross threshold at once and no
        // extra conflict-resolution against the other three gestures
        // was needed. Threshold is a conservative first pass (Eddie:
        // "a neutral face must NOT constantly be classified as a
        // frown") -- tune from on-device MIRRORDIAG logging.
        if above(frown, 0.16, .frown) { return (.frown, frown) }
        if above(brows, 0.70, .eyebrowsRaised) { return (.eyebrowsRaised, brows) }
        return (nil, 0)
    }
}

@MainActor
final class MirrorCommentState: ObservableObject {
    @Published private(set) var looking = false
    @Published private(set) var comment: String?
    private(set) var active: MirrorGesture?
    private var candidate: MirrorGesture?
    private var candidateSince: Double = 0
    private var lastComment: [MirrorGesture: String] = [:]

    func setLooking(_ value: Bool) {
        guard value != looking else { return }
        looking = value
        active = nil; candidate = nil; candidateSince = 0; comment = nil
    }

    func receive(_ signals: MirrorFaceSignals?, time: Double) {
        guard looking else { return }
        let (next, score) = signals?.dominant(retaining: active) ?? (nil, 0)
        if next == active { candidate = next; candidateSince = time; return }
        if next != candidate { candidate = next; candidateSince = time; return }
        // Brief stability for gestures; neutral/tracking gaps clear gently.
        guard time - candidateSince >= (next == nil ? 0.55 : 0.12) else { return }
        active = next
        if let next {
            let choices = next.comments.filter { $0 != lastComment[next] }
            comment = choices.randomElement()
            lastComment[next] = comment
        } else { comment = nil }
        navLog("MIRRORDIAG state=\(next?.rawValue ?? "neutral") score=\(String(format: "%.2f", score)) comment=\(comment ?? "<clear>")")
    }
}

struct MirrorCommentOverlay: View {
    @ObservedObject var controller: TapNavigationController
    @ObservedObject var state: MirrorCommentState
    let mirrors: [GridCoordinate: Direction]
    let gameplayActive: Bool
    private var looking: Bool {
        gameplayActive && controller.canRotate && mirrors[controller.currentCell] == controller.facing
    }
    var body: some View {
        VStack {
            Spacer()
            if looking, let comment = state.comment {
                Text(comment).font(.title3.weight(.semibold)).multilineTextAlignment(.center).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)
                .accessibilityIdentifier("ordinaryMirrorComment")
            }
        }
        .padding(.bottom, 94)
        .allowsHitTesting(false)
        .onAppear { state.setLooking(looking) }
        .onChange(of: looking) { _, value in state.setLooking(value) }
        .onDisappear { state.setLooking(false) }
    }
}

/// One independent, already-rendered CGImage in flight. Never retain capture
/// buffers; never queue camera frames or interrupt the reflection's worker.
nonisolated final class MirrorGestureAnalyzer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Hallways.mirror.gestures", qos: .userInitiated)
    private let lock = NSLock()
    private var enabled = false
    private var generation = 0
    private var busy = false
    private var lastTime = -Double.infinity
    private let request = VNDetectFaceLandmarksRequest()
    private lazy var detector = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyLow])
    private let onResult: @MainActor @Sendable (MirrorFaceSignals?, Double) -> Void
    init(onResult: @escaping @MainActor @Sendable (MirrorFaceSignals?, Double) -> Void) { self.onResult = onResult }
    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        if enabled != value { enabled = value; generation += 1; lastTime = -Double.infinity }
    }
    func submit(_ image: CGImage, time: Double) {
        lock.lock()
        guard enabled, !busy, time - lastTime >= 0.1 else { lock.unlock(); return }
        busy = true; lastTime = time
        let token = generation
        lock.unlock()
        queue.async { [self] in
            let signals = analyze(image)
            DispatchQueue.main.async { [self] in
                lock.lock(); let valid = enabled && generation == token; lock.unlock()
                if valid { onResult(signals, time) }
                lock.lock(); busy = false; lock.unlock()
            }
        }
    }
    private func analyze(_ image: CGImage) -> MirrorFaceSignals? {
        do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]) }
        catch { return nil }
        guard let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
              face.confidence > 0.5, abs(face.yaw?.doubleValue ?? 0) < 0.45,
              let landmarks = face.landmarks else { return nil }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            region?.normalizedPoints.map { CGPoint(x: $0.x * face.boundingBox.width * Double(image.width), y: $0.y * face.boundingBox.height * Double(image.height)) } ?? []
        }
        func center(_ p: [CGPoint]) -> CGPoint {
            CGPoint(x: p.map(\.x).reduce(0,+) / Double(max(1,p.count)), y: p.map(\.y).reduce(0,+) / Double(max(1,p.count)))
        }
        let left = points(landmarks.leftEye), right = points(landmarks.rightEye)
        guard left.count >= 4, right.count >= 4 else { return nil }
        let centers = [center(left), center(right)].sorted { $0.x < $1.x }
        let angle = atan2(centers[1].y - centers[0].y, centers[1].x - centers[0].x)
        func upright(_ p: [CGPoint]) -> [CGPoint] {
            p.map { CGPoint(x: $0.x * cos(angle) + $0.y * sin(angle), y: -$0.x * sin(angle) + $0.y * cos(angle)) }
        }
        func width(_ p: [CGPoint]) -> Double { max(0.001, (p.map(\.x).max() ?? 0) - (p.map(\.x).min() ?? 0)) }
        func ratio(_ p: [CGPoint]) -> Double { ((p.map(\.y).max() ?? 0) - (p.map(\.y).min() ?? 0)) / width(p) }
        let l = upright(left), r = upright(right)
        let lb = upright(points(landmarks.leftEyebrow)), rb = upright(points(landmarks.rightEyebrow))
        let lips = upright(points(landmarks.innerLips))
        guard lips.count >= 4, !lb.isEmpty, !rb.isEmpty else { return nil }
        // Core Image supplies the smile flag; eye closure/opening never classifies gestures.
        let ciFaces = detector?.features(in: CIImage(cgImage: image), options: [CIDetectorSmile: true]) as? [CIFaceFeature]
        let ciFace = ciFaces?.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        // Frown vs. smile is which way the mouth's own OUTER corners
        // curl relative to its center -- up toward the cheeks (smile)
        // or down toward the chin (frown) -- not merely "mouth
        // narrow/closed" (a plain neutral resting mouth reads near
        // zero here, same idea Eddie asked for: "NOT merely a
        // neutral/resting mouth"). landmarks y increases upward here
        // (same convention the brows math above already relies on:
        // eyebrow-above-eye reads positive), so corners sitting BELOW
        // center come out negative -- centerY - cornerY flips that so
        // a bigger positive number means a more visibly downturned
        // mouth, same "bigger = more of the gesture" shape as mouth/
        // brows.
        func cornerDroop(_ p: [CGPoint]) -> Double {
            let sorted = p.sorted { $0.x < $1.x }
            guard let leftCorner = sorted.first, let rightCorner = sorted.last else { return 0 }
            let cornerY = (leftCorner.y + rightCorner.y) / 2
            let centerY = p.map(\.y).reduce(0, +) / Double(p.count)
            return (centerY - cornerY) / width(p)
        }
        return MirrorFaceSignals(smile: ciFace?.hasSmile ?? false,
            mouth: ratio(lips),
            brows: ((center(lb).y - center(l).y) / width(l) + (center(rb).y - center(r).y) / width(r)) / 2,
            frown: cornerDroop(lips))
    }
}
