import Foundation
import SceneKit
import UIKit
import Testing
@testable import Hallways

/// Oct 22 -- TAP A CRITTER: any part of it, looked at past invisible helpers and
/// glass, with a finger's margin -- never through a wall, never over the
/// elevator's own controls.
@MainActor
struct CritterTapTargetTests {
    @MainActor private final class Figure: ResidentPresentation {
        let residentID: String
        let node = SCNNode()
        let cab: SCNNode?
        init(_ id: String, cab: SCNNode? = nil) { residentID = id; self.cab = cab }
        var holdsResident: Bool { true }
        var isRendered: Bool { true }
        var isGuiding: Bool { false }
        var bodyNode: SCNNode? { node }
        var tapTargets: [SCNNode] { [node] + (cab.map { [$0] } ?? []) }
        func tick(now: Date) {}
        func teardown() {}
        func playerBoarding() -> Bool { false }
        func arrivalDoorsOpening() {}
    }

    @Test func itsHeadEyesAndItsFigureInTheCabAreAllIt() {
        let cabFigure = SCNNode()
        let hw = Figure("hw.lopsy", cab: cabFigure)
        let head = SCNNode(), eye = SCNNode()
        hw.node.addChildNode(head)
        head.addChildNode(eye)
        let saved = BuildingLife.shared.presentations
        defer { BuildingLife.shared.presentations = saved }
        BuildingLife.shared.presentations = [hw]
        #expect(CritterFollow.residentID(owning: eye) == "hw.lopsy")              // (an eye on its head)
        #expect(CritterFollow.residentID(owning: cabFigure) == "hw.lopsy")        // (seen in the cab)
        #expect(CritterFollow.residentID(owning: SCNNode()) == nil)
    }

    @Test func tapsLookPastInvisibleHelpersAndGlassButNotWalls() {
        // A scene with, along one ray: a clear hit box, a glass pane, a wall.
        let scene = SCNScene()
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(0, 1.5, 3)
        scene.rootNode.addChildNode(camera)
        func pane(_ z: Float, _ name: String, _ configure: (SCNMaterial) -> Void) -> SCNNode {
            let m = SCNMaterial()
            configure(m)
            let box = SCNBox(width: 2, height: 2, length: 0.02, chamferRadius: 0)
            box.materials = [m]
            let n = SCNNode(geometry: box)
            n.name = name
            n.position = SCNVector3(0, 1.5, z)
            scene.rootNode.addChildNode(n)
            return n
        }
        _ = pane(2, "clearHitBox") { $0.transparency = 0.001 }
        _ = pane(1.5, "glass") { $0.transparency = 0.25 }
        _ = pane(1, "wall") { $0.diffuse.contents = UIColor.gray }
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.scene = scene
        view.pointOfView = camera
        let hits = view.hitTest(CGPoint(x: 195, y: 422), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        let names = hits.map { $0.node.name ?? "" }
        #expect(names.prefix(3) == ["clearHitBox", "glass", "wall"])
        let seeThrough = hits.prefix(3).map { CritterTapTarget.isSeeThrough($0) }
        #expect(seeThrough == [true, true, false])
    }

    @Test func aFingersMarginAroundTheFigure() {
        let r = CGRect(x: 100, y: 100, width: 40, height: 80)
        #expect(CritterTapTarget.gap(CGPoint(x: 120, y: 140), r) == 0)
        #expect(CritterTapTarget.gap(CGPoint(x: 150, y: 140), r) == 10)
        #expect(CritterTapTarget.gap(CGPoint(x: 150, y: 140), r) <= CritterTapTarget.screenMargin)
        #expect(CritterTapTarget.gap(CGPoint(x: 170, y: 140), r) > CritterTapTarget.screenMargin)
    }
}
