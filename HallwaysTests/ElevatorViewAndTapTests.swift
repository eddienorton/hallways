import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 20 (night) -- two navigation repairs.
///  1. Walked right up to the closed elevator, the player eases back (once per
///     visit) to where the whole front -- frame, floor sign, call panel -- is in
///     view, still in the elevator's cell; the doors, calling and boarding as ever.
///  2. A tap well off to the side of the view (leaving Tinky's office for its
///     doors) no longer starts the latched walk straight ahead -- which slid along
///     the walls across the room -- but the tap-a-place walk toward where it landed.
@MainActor
struct ElevatorViewAndTapTests {
    // MARK: 2 -- the tap

    @Test func onlyATapRoughlyAheadLatchesAWalkStraightOn() {
        typealias C = TapNavigationController
        let yaw = 0.0                                                     // (facing -z)
        func toward(_ degrees: Double) -> (x: Double, z: Double) {        // a bearing `degrees` to the left
            let b = yaw + degrees * .pi / 180
            return (-sin(b), -cos(b))
        }
        #expect(C.aimsAhead(nil, yaw: yaw))
        #expect(C.aimsAhead(toward(0), yaw: yaw))
        #expect(C.aimsAhead(toward(10), yaw: yaw))
        #expect(C.aimsAhead(toward(-12), yaw: yaw))
        #expect(!C.aimsAhead(toward(25), yaw: yaw))                        // (the office doors, off to one side)
        #expect(!C.aimsAhead(toward(-40), yaw: yaw))
        #expect(!C.aimsAhead(toward(180), yaw: yaw))                       // (behind: never "walk on")
        // Facing west (yaw +90): a tap straight ahead (west) still latches.
        let west = Direction.west.yaw
        #expect(C.aimsAhead((x: -1, z: 0), yaw: west))
    }

    // MARK: 1 -- the elevator view

    @Test func theFramingDistanceComesFromTheLensAndTheScreen() {
        // The real front: 1.35 m across (jamb to call panel) + margins; the sign's top
        // 1.18 m above a 1.6 m eye; 75-degree lens; a 390 x 844 portrait screen.
        let d = TapNavigationController.elevatorViewDistance(halfSpan: 0.735, rise: 1.18, verticalFOV: 75, aspect: 390.0 / 844.0)
        #expect(abs(d - 2.07) < 0.05)                                      // (width decides: about 2.1 m back)
        // A wider screen (landscape) needs less; a taller sign more height.
        #expect(TapNavigationController.elevatorViewDistance(halfSpan: 0.735, rise: 1.18, verticalFOV: 75, aspect: 1.8) < d)
    }

    /// A hallway cell at the elevator (doors on its north wall) with the elevator's front as the scene builds it.
    private struct Hall {
        let scene = SCNScene()
        let camera = SCNNode()
        let left = SCNNode(), right = SCNNode()
        let controller: TapNavigationController
        init() {
            let cell = GridCoordinate(row: 0, col: 0)
            camera.position = SCNVector3(0, 1.6, 0)                       // (yaw 0: facing the doors)
            left.position = SCNVector3(-0.24, 1.3, -1.84)
            right.position = SCNVector3(0.24, 1.3, -1.84)
            controller = TapNavigationController(cameraNode: camera, scene: scene, cells: [cell, GridCoordinate(row: 1, col: 0)],
                cellSize: 3.52, startCell: cell, startFacing: .north, endCell: cell,
                elevatorLeftDoor: left, elevatorRightDoor: right, elevatorMountDirection: .north, floorNumber: 6)
            [camera, left, right].forEach { scene.rootNode.addChildNode($0) }
            // The front (HallwayScene's sizes; its face 1.64 m north of the cell centre).
            func part(_ name: String, w: CGFloat, h: CGFloat, x: Float, y: Float) {
                let n = SCNNode(geometry: SCNBox(width: w, height: h, length: 0.04, chamferRadius: 0))
                n.name = name
                n.position = SCNVector3(x, y, -1.66)
                scene.rootNode.addChildNode(n)
            }
            part("elevatorExteriorJamb", w: 0.06, h: 2.5, x: -0.51, y: 1.25)
            part("elevatorExteriorJamb", w: 0.06, h: 2.5, x: 0.51, y: 1.25)
            part("elevatorExteriorHeader", w: 1.08, h: 0.24, x: 0, y: 2.62)
            part("elevatorExteriorDisplay", w: 0.40, h: 0.18, x: 0, y: 2.62)
            part("elevatorExteriorCallPanel", w: 0.20, h: 0.54, x: 0.71, y: 1.28)
        }
    }

    @Test func theViewPointShowsTheWholeFrontAndStaysInTheElevatorsCell() throws {
        let hall = Hall()
        let pose = try #require(hall.controller.elevatorViewingPose())
        // Back from the doors (south, +z) by about 2.1 m from the front's face, a little toward the panel (+x).
        #expect(pose.z > 0.3 && pose.z < 0.6)
        #expect(pose.x > 0.05 && pose.x <= 0.36 + 1e-4)
        #expect(abs(pose.z) < 1.76 && abs(pose.x) < 1.76)                  // (still the elevator's cell)
    }

    private func tick(_ r: SCNRenderer, from start: Double, through end: Double, until done: (() -> Bool)? = nil) async -> Double {
        var t = start
        while t <= end {
            r.update(atTime: t)
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            t += 0.025
            if let done, done() { return t }
        }
        return t
    }

    @Test func walkedUpToTheDoorsItEasesBackOnceAndNeverFights() async throws {
        let hall = Hall()
        let c = hall.controller
        let r = SCNRenderer(device: nil, options: nil)
        r.scene = hall.scene
        r.delegate = c
        // Walk right up to the closed doors (a tap ahead).
        c.advance(travelDirection: (0, -1), travelDistance: 3)
        var t = await tick(r, from: 1, through: 4) { !c.isAnimating }
        t = await tick(r, from: t, through: t + 1.5)                          // (the settle, 0.45 s)
        let pose = try #require(c.elevatorViewingPose())
        #expect(abs(hall.camera.position.z - pose.z) < 0.08)                  // eased back to the view point
        #expect(c.currentCell == GridCoordinate(row: 0, col: 0))              // (still at the elevator: call, board as ever)
        #expect(!c.isAnimating)
        // Walk up close again: it stays where the player put it (once per visit).
        c.advance(travelDirection: (0, -1), travelDistance: 3)
        t = await tick(r, from: t, through: t + 3) { !c.isAnimating }
        let close = hall.camera.position.z
        _ = await tick(r, from: t, through: t + 1.5)
        #expect(close < pose.z - 0.3)
        #expect(abs(hall.camera.position.z - close) < 0.01)                   // (not pushed back again)
    }

    @Test func noViewSettleFacingAwayOrWithTheDoorsOpen() async {
        // Facing away from the doors (south): a walk ending in the cell is left alone.
        let hall = Hall()
        let c = hall.controller
        hall.camera.eulerAngles = SCNVector3(0, Float.pi, 0)
        hall.camera.position = SCNVector3(0, 1.6, -0.3)
        let r = SCNRenderer(device: nil, options: nil)
        r.scene = hall.scene
        r.delegate = c
        c.advance(travelDirection: (0, 1), travelDistance: 0.2)
        let t = await tick(r, from: 1, through: 3) { !c.isAnimating }
        let z = hall.camera.position.z
        _ = await tick(r, from: t, through: t + 1)
        #expect(abs(hall.camera.position.z - z) < 0.01)
        // Doors open (the car here for a resident): no settle -- boarding through them stays as it is.
        let open = Hall()
        open.controller.runCarDoors(open: true)
        let r2 = SCNRenderer(device: nil, options: nil)
        r2.scene = open.scene
        r2.delegate = open.controller
        var t2 = await tick(r2, from: 1, through: 3.2)
        open.controller.advance(travelDirection: (0, -1), travelDistance: 3)
        t2 = await tick(r2, from: t2, through: t2 + 3) { !open.controller.isAnimating }
        let z2 = open.camera.position.z
        _ = await tick(r2, from: t2, through: t2 + 1)
        #expect(abs(open.camera.position.z - z2) < 0.01)
    }
}
