import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 22 (stability pass): the elevator header line, the car sentinel in the
/// residents' reports, small tap targets, and the residents' voices.
@MainActor
struct StabilityPassTests {
    /// The elevator's top strip is flush with the wall across the whole cell;
    /// only a short lip over the doorway (the exterior header's width) stands
    /// proud -- no ledge (and no dark line) running across the wallpaper.
    @Test func theElevatorTopStripHasNoLedgeAcrossTheWall() {
        var materials: [SCNMaterial] = []
        let root = SCNNode()
        let interior = SCNMaterial()
        let doorWidth: CGFloat = 0.96, doorHeight: CGFloat = 2.5
        let nodes = HallwayScene.buildDoorFrame(direction: .north, wallCenterX: 3.52, wallCenterZ: 1.76, doorWidth: doorWidth,
                                                doorHeight: doorHeight, doorCenterY: doorHeight / 2, interiorMaterial: interior,
                                                topFrontExtension: 0.04, cellSize: 3.52, wallHeight: 3.0,
                                                effectiveWallImageName: nil, root: root, wallMaterials: &materials)
        let boxes = nodes.compactMap { $0.geometry as? SCNBox }
        #expect(boxes.count == 5)                                            // (top, bottom, two sides, and the lip)
        let lips = boxes.filter { abs($0.length - 0.04) < 0.0001 }
        #expect(lips.count == 1)
        #expect(abs((lips.first?.width ?? 0) - (doorWidth + 0.12)) < 0.0001)  // (the doorway only)
        for b in boxes where abs(b.length - 0.04) >= 0.0001 { #expect(abs(b.length - 0.1) < 0.0001) }   // (flush strips)
        // Without an extension (every other doorway): four strips, as before.
        let plain = HallwayScene.buildDoorFrame(direction: .north, wallCenterX: 3.52, wallCenterZ: 1.76, doorWidth: doorWidth,
                                                doorHeight: doorHeight, doorCenterY: doorHeight / 2, cellSize: 3.52, wallHeight: 3.0,
                                                effectiveWallImageName: nil, root: root, wallMaterials: &materials)
        #expect(plain.count == 4)
    }

    /// A resident riding (or waiting for) the car has the sentinel .distantFuture --
    /// the reports say "after the car", never ~62 billion seconds.
    @Test func theCarSentinelIsReportedInWords() {
        let r = Resident(id: "x", kind: "x", floor: 5, cell: nil, since: .distantFuture, dwell: 30)
        #expect(r.awaitsCar)
        let s = Resident(id: "y", kind: "y", floor: 5, cell: nil, since: Date(), dwell: 30)
        #expect(!s.awaitsCar)
    }

    /// A tiny figure gets a fingertip-sized target round its centre.
    @Test func smallFiguresGetAFingertipTarget() {
        let tiny = CGRect(x: 100, y: 100, width: 10, height: 8)
        let grown = CritterTapTarget.atLeast(tiny, CritterTapTarget.minimumTarget)
        #expect(grown.width == CritterTapTarget.minimumTarget && grown.height == CritterTapTarget.minimumTarget)
        #expect(abs(grown.midX - tiny.midX) < 0.001 && abs(grown.midY - tiny.midY) < 0.001)
        let big = CGRect(x: 0, y: 0, width: 200, height: 300)
        #expect(CritterTapTarget.atLeast(big, CritterTapTarget.minimumTarget) == big)
    }

    /// With the musical identities on, residents don't speak Hallenese in ordinary life.
    @Test func theIdentitiesHushOrdinaryVoices() {
        let key = HallwaysianMusic.defaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(true, forKey: key)
        #expect(ResidentMusic.hushesVoices)
        UserDefaults.standard.set(false, forKey: key)
        #expect(!ResidentMusic.hushesVoices)
    }
}
