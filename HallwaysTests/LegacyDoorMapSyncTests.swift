import Testing
import SceneKit
import Combine
@testable import Hallways

@MainActor
struct LegacyDoorMapSyncTests {
    @Test func liveAddAndDeleteMatchRebuiltMapsAndNotifyHUD() throws {
        let cell = GridCoordinate(row: 5, col: 5)
        let other = GridCoordinate(row: 5, col: 6)
        let cells: Set<GridCoordinate> = [cell, other]
        let scene = SCNScene()
        let wallMap = SCNNode(geometry: SCNPlane(width: 1, height: 1))
        wallMap.geometry?.materials = [SCNMaterial()]
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: scene,
            cells: cells, cellSize: 3.2, startCell: other, startFacing: .north, endCell: other,
            floorMapPlaneNodes: [wallMap])
        let door = RoomDoorPlacement(coord: cell, direction: .north, roomNumber: 501, isDecorative: true)
        let rebuilt = TapNavigationController(cameraNode: SCNNode(), scene: scene,
            cells: cells, cellSize: 3.2, startCell: other, startFacing: .north, endCell: other,
            roomDoors: [cell: door])
        let emptyFull = try #require(controller.currentFloorMapImage().pngData())
        let emptyMini = try #require(controller.currentFloorMapImage(backgroundOpacity: 0, simplified: true, includeWallObjectIndicators: true).pngData())
        var notifications = 0
        let observation = controller.objectWillChange.sink { notifications += 1 }
        defer { observation.cancel() }

        controller.registerRoomDoor(door)
        #expect(notifications == 1)
        let added = try #require(controller.currentFloorMapImage().pngData())
        #expect(added != emptyFull)
        #expect(added == rebuilt.currentFloorMapImage().pngData())
        #expect((wallMap.geometry?.firstMaterial?.diffuse.contents as? UIImage)?.pngData() == added)
        #expect(controller.currentFloorMapImage(backgroundOpacity: 0, simplified: true, includeWallObjectIndicators: true).pngData() == rebuilt.currentFloorMapImage(backgroundOpacity: 0, simplified: true, includeWallObjectIndicators: true).pngData())

        controller.unregisterRoomDoor(at: cell)
        #expect(notifications == 2)
        #expect(controller.currentFloorMapImage().pngData() == emptyFull)
        #expect(controller.currentFloorMapImage(backgroundOpacity: 0, simplified: true, includeWallObjectIndicators: true).pngData() == emptyMini)
        #expect((wallMap.geometry?.firstMaterial?.diffuse.contents as? UIImage)?.pngData() == emptyFull)
    }
}
