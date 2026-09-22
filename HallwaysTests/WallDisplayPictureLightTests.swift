import Testing
import SceneKit
@testable import Hallways

@MainActor
struct WallDisplayPictureLightTests {
    enum Display: CaseIterable { case picture, mission, map }

    private func fixtures(display: Display, direction: Direction, authoredDirection: Direction?, level: Int = 3) -> (scene: SCNScene, nodes: [SCNNode]) {
        let coord = GridCoordinate(row: 0, col: 0)
        let scene = HallwayScene.build(fromMaze: [coord], cellSize: 3.2, wallHeight: 3,
            floorMaps: display == .map ? [coord: direction] : [:],
            missionSigns: display == .mission ? [coord: direction] : [:],
            pictures: display == .picture ? [coord: (direction: direction, size: .standard)] : [:],
            missionHeading: "Test mission", missionBody: "Test instructions", floorNumber: 20,
            playerStart: coord, playerEnd: coord,
            pictureLights: authoredDirection.map { [coord: $0] } ?? [:],
            lightBrightness: [LightBrightness(coord: coord, kind: .picture, level: level)]).scene
        var result: [SCNNode] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            if node.name == "pictureLight" { result.append(node) }
        }
        return (scene, result)
    }

    @Test(arguments: Display.allCases, [Direction.north, .east, .south, .west])
    func matchingAuthoredLightCreatesExactlyOneUnchangedFixture(display: Display, direction: Direction) throws {
        let built = fixtures(display: display, direction: direction, authoredDirection: direction)
        defer { withExtendedLifetime(built.scene) {} }
        #expect(built.nodes.count == 1)
        let fixture = try #require(built.nodes.first)
        let frame = try #require(fixture.parent)
        let panel = try #require(frame.childNodes.compactMap { $0.geometry as? SCNPlane }.first)
        let source = try #require(fixture.childNode(withName: "pictureLightSource", recursively: false))
        let reference = HallwayScene.makePictureLight(panelWidth: panel.width, panelHeight: panel.height, level: 3)
        let referenceSource = try #require(reference.childNode(withName: "pictureLightSource", recursively: false))
        #expect(fixture.childNodes.count == reference.childNodes.count)
        #expect(fixture.position.y == reference.position.y)
        #expect(source.position.y == referenceSource.position.y)
        #expect(source.eulerAngles.x == referenceSource.eulerAngles.x)
        #expect(source.light?.intensity == 6)
        #expect(source.light?.spotInnerAngle == 38)
        #expect(source.light?.spotOuterAngle == 64)
        #expect(abs((source.light?.attenuationEndDistance ?? -1) - (panel.height + 0.4)) < 0.000001)
        let widths = fixture.childNodes.compactMap { ($0.geometry as? SCNBox)?.width }
        let expectedWidths = reference.childNodes.compactMap { ($0.geometry as? SCNBox)?.width }
        #expect(widths == expectedWidths)
    }

    @Test(arguments: Display.allCases)
    func absentOrDifferentWallLightDoesNotCreateFixture(display: Display) {
        #expect(fixtures(display: display, direction: .east, authoredDirection: nil).nodes.isEmpty)
        #expect(fixtures(display: display, direction: .east, authoredDirection: .west).nodes.isEmpty)
    }

    @Test(arguments: Display.allCases, [1, 2, 3, 4, 5])
    func authoredBrightnessKeepsExistingPictureCurve(display: Display, level: Int) throws {
        let fixture = try #require(fixtures(display: display, direction: .east, authoredDirection: .east, level: level).nodes.first)
        let light = try #require(fixture.childNode(withName: "pictureLightSource", recursively: false)?.light)
        #expect(AuthoredLightKind.picture.levelRange == 1...5)
        #expect(light.intensity == [CGFloat(1), 3, 6, 10, 16][level - 1])
    }
}
