import Testing
import SceneKit
@testable import Hallways

/// Oct 8: the lobby mirror lands like any wall object; Floor 1's cab button reads LOBBY.
@MainActor
struct LobbyMirrorAndLobbyButtonTests {
    private func controller(floor: Int) -> TapNavigationController {
        let cell = HallwayScene.lobbyMirrorFace.coord
        return TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: [cell],
            cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell, floorNumber: floor)
    }

    private func lobbyMirror() -> (root: SCNNode, surface: SCNNode) {
        let mirror = HallwayScene.makeMirrorNode(at: HallwayScene.lobbyMirrorFace.coord,
                                                 direction: HallwayScene.lobbyMirrorFace.direction, cellSize: 3.2)
        mirror.name = HallwayScene.lobbyMirrorNodeName
        let surface = mirror.childNode(withName: "mirrorSurface", recursively: true)!
        return (mirror, surface)
    }

    @Test func tappingTheLobbyMirrorTargetsItsSquareWallFace() throws {
        let nav = controller(floor: 1)
        let mirror = lobbyMirror()
        let target = try #require(nav.wallInteractionTarget(for: mirror.surface))   // the glass
        #expect(target.kind == "lobbyMirror")
        #expect(target.face == WallFace(coord: GridCoordinate(row: 11, col: 7), direction: .east))
        #expect(target.action == nil)                                                // passive, like a picture
        let frame = try #require(mirror.root.childNodes.first { $0.name != "mirrorSurface" })
        #expect(nav.wallInteractionTarget(for: frame)?.kind == "lobbyMirror")       // the frame too
        #expect(nav.isWallInteractionAnchor(mirror.root))                           // finger-width assist
    }

    @Test func otherFloorsAreUnchanged() {
        let nav = controller(floor: 2)
        let mirror = lobbyMirror()
        #expect(nav.wallInteractionTarget(for: mirror.surface) == nil)
        #expect(!nav.isWallInteractionAnchor(mirror.root))
    }

    @Test func floorOneButtonReadsLobbyButStillSelectsFloorOne() throws {
        #expect(HallwayScene.elevatorButtonLabel(floor: 1) == "LOBBY")
        #expect(HallwayScene.elevatorButtonLabel(floor: 2) == "2")
        #expect(HallwayScene.elevatorButtonLabel(floor: 16) == "16")
        let cell = GridCoordinate(row: 0, col: 0)
        let result = HallwayScene.build(fromMaze: [cell], cellSize: 3.2, wallHeight: 3,
            floorNumber: 12, totalFloors: 16, playerStart: cell, playerEnd: cell)
        let plate = try #require(result.scene.rootNode.childNode(withName: "elevatorControlPanel", recursively: true))
        #expect(plate.childNode(withName: "elevatorControlButton_1", recursively: false) != nil)  // same identity
        let label = try #require(plate.childNode(withName: "elevatorControlButtonLabel_1", recursively: false))
        let text = try #require(label.childNodes.first?.geometry as? SCNText)
        #expect(text.string as? String == "LOBBY")
        let cap = try #require(plate.childNode(withName: "elevatorControlButton_1", recursively: false))
        #expect(cap.scale.x == 1.9 && cap.scale.y == 1 && cap.scale.z == 1)   // oval, same height
        // The lettering is sized on its own allowance: LOBBY far wider than a number's.
        let lobbyText = try #require(plate.childNode(withName: "elevatorControlButtonLabel_1", recursively: false)?.childNodes.first)
        let (lo, hi) = lobbyText.boundingBox
        #expect(Float(hi.x - lo.x) * lobbyText.scale.x > 0.1)            // was ~0.068 (1.6) / ~0.11 now ~0.15
        #expect(Float(hi.x - lo.x) * lobbyText.scale.x <= 0.15 + 1e-4)
        // The oval rim still sits inside the (wider) plate.
        let plateBox = try #require(plate.geometry as? SCNBox)
        #expect(plateBox.width > 0.34 && plateBox.width < 0.36)
        #expect(0.063 * 2 * 1.9 < Double(plateBox.width))
        #expect(plate.childNode(withName: "elevatorControlButton_2", recursively: false)?.scale.x == 1)
        let two = try #require(plate.childNode(withName: "elevatorControlButtonLabel_2", recursively: false))
        #expect((two.childNodes.first?.geometry as? SCNText)?.string as? String == "2")
    }
}
