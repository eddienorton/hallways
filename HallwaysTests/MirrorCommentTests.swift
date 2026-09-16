import Testing
import SwiftUI
import SceneKit
import Vision
@testable import Hallways

@MainActor
struct MirrorCommentTests {
    // Sept 13: frown added as a fourth ordinary-mirror expression --
    // count bumped from 3 to 4, plus frown-specific assertions
    // (neutral/near-threshold must NOT read as a frown; a clearly
    // downturned value must).
    @Test func fourGesturesWithMouthSmileFrownBrowPriority() {
        #expect(MirrorGesture.allCases.count == 4)
        #expect(MirrorFaceSignals(smile: true).dominant(retaining: nil).0 == .smile)
        #expect(MirrorFaceSignals(mouth: 0.5).dominant(retaining: nil).0 == .mouthOpen)
        #expect(MirrorFaceSignals(brows: 0.8).dominant(retaining: nil).0 == .eyebrowsRaised)
        #expect(MirrorFaceSignals().dominant(retaining: nil).0 == nil)
        #expect(MirrorFaceSignals(smile: true, mouth: 0.5, brows: 0.8).dominant(retaining: .smile).0 == .mouthOpen)
        #expect(MirrorFaceSignals(smile: true, brows: 0.8).dominant(retaining: .eyebrowsRaised).0 == .smile)
        #expect(MirrorFaceSignals(mouth: 0.34).dominant(retaining: .mouthOpen).0 == .mouthOpen)
        #expect(MirrorFaceSignals(brows: 0.65).dominant(retaining: .eyebrowsRaised).0 == .eyebrowsRaised)
        // A neutral/resting mouth (frown == 0, same default as an
        // unset signal) must not read as a frown.
        #expect(MirrorFaceSignals(frown: 0).dominant(retaining: nil).0 == nil)
        // Small noise below the conservative 0.16 threshold -- still
        // must not fire.
        #expect(MirrorFaceSignals(frown: 0.1).dominant(retaining: nil).0 == nil)
        // A clearly downturned mouth crosses the threshold.
        #expect(MirrorFaceSignals(frown: 0.2).dominant(retaining: nil).0 == .frown)
        // Same "retained state gets a slightly lower bar" hysteresis
        // the other three gestures already use (0.88x).
        #expect(MirrorFaceSignals(frown: 0.15).dominant(retaining: .frown).0 == .frown)
    }
    @Test func quickStableChangesNoFrameChurnAndNeutralGrace() {
        let state = MirrorCommentState(); state.setLooking(true)
        state.receive(.init(smile: true), time: 1)
        state.receive(.init(smile: true), time: 1.10)
        #expect(state.comment == nil)
        state.receive(.init(smile: true), time: 1.14)
        let first = state.comment; #expect(first != nil)
        state.receive(.init(smile: true), time: 1.3)
        #expect(state.comment == first)
        state.receive(.init(mouth: 0.5), time: 1.4)
        state.receive(.init(mouth: 0.5), time: 1.54)
        #expect(state.active == .mouthOpen)
        state.receive(.init(smile: true), time: 1.7)
        state.receive(.init(smile: true), time: 1.84)
        #expect(state.active == .smile && state.comment != first)
        state.receive(.init(), time: 2)
        state.receive(.init(), time: 2.2)
        #expect(state.comment != nil)
        state.receive(.init(), time: 2.6)
        #expect(state.comment == nil)
        state.setLooking(false)
        state.receive(.init(smile: true), time: 3)
        state.receive(.init(smile: true), time: 3.2)
        #expect(state.comment == nil)
    }
    @Test func eachBankHasTenDistinctShortComments() {
        for gesture in MirrorGesture.allCases {
            #expect(gesture.comments.count == 10)
            #expect(Set(gesture.comments).count == 10)
            #expect(gesture.comments.allSatisfy { $0.count < 60 })
        }
    }
    @Test func ordinaryMirrorCaptionRendersInSwiftUI() throws {
        let coord = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: [coord],
            cellSize: 3.2, startCell: coord, startFacing: .north, endCell: coord)
        let state = MirrorCommentState(); state.setLooking(true)
        state.receive(.init(mouth: 0.5), time: 1)
        state.receive(.init(mouth: 0.5), time: 1.2)
        let overlay = MirrorCommentOverlay(controller: controller, state: state, mirrors: [coord: .north], gameplayActive: true)
            .frame(width: 390, height: 844)
        let image = try #require(ImageRenderer(content: overlay).uiImage)
        let cg = try #require(image.cgImage)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: cg).perform([request])
        let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        #expect(!text.contains("THE MIRROR"))
        #expect(!text.isEmpty)
    }
}
