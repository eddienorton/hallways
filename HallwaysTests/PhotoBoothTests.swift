import Testing
import SceneKit
import UIKit
@testable import Hallways

@MainActor
struct PhotoBoothTests {
    private func finishNavigation(_ controller: TapNavigationController) async {
        let renderer = SCNRenderer(device: nil, options: nil)
        for tick in 1...400 {
            controller.renderer(renderer, updateAtTime: Double(tick) * 0.05)
            await Task.yield()
            if !controller.isAnimating { return }
        }
        #expect(!controller.isAnimating)
    }

    @Test func swipeCancelsUnfinishedBoothAndAllowsTurning() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            photoBooths: [cell: (direction: .north, expression: .smile)])
        controller.activatePhotoBooth(at: cell)
        controller.beginDragRotate()
        #expect(controller.activePhotoBooth == nil)
        controller.endDragRotate(fraction: 1)
        #expect(controller.isAnimating)
        #expect(!controller.isMissionComplete)
    }

    @Test func employeeIDRequiresOnlyOneSmileStation() {
        let store = MazeStore()
        store.switchTo(id: 6)
        #expect(store.photoBooths.count == 1)
        #expect(store.photoBooths.values.first?.expression == .smile)
    }

    @Test func finishingTurnTowardBoothStartsCameraWithoutTap() async {
        let cell = GridCoordinate(row: 2, col: 1)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            photoBooths: [cell: (direction: .west, expression: .smile)])
        #expect(controller.activePhotoBooth == nil)
        controller.beginDragRotate()
        controller.endDragRotate(fraction: 1)
        await finishNavigation(controller)
        #expect(controller.facing == .west)
        #expect(controller.activePhotoBooth == cell)
        #expect(controller.photoBoothCameraState == "starting")
        #expect(!controller.canRotate)
    }

    @Test func walkingTowardBoothStartsCameraButSidewaysArrivalDoesNot() async {
        let start = GridCoordinate(row: 1, col: 0)
        let booth = GridCoordinate(row: 0, col: 0)
        for direction in [Direction.north, .west] {
            let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
                cells: [start, booth], cellSize: 3.2, startCell: start, startFacing: .north,
                endCell: GridCoordinate(row: 9, col: 9),
                photoBooths: [booth: (direction: direction, expression: .smile)])
            controller.advance()
            await finishNavigation(controller)
            #expect(controller.currentCell == booth)
            #expect((controller.activePhotoBooth == booth) == (direction == .north))
            #expect(controller.canRotate == (direction == .west))
        }
    }

    @Test func sidewaysBoothDoesNotLockOrConsumeForwardTap() {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
            photoBooths: [cell: (direction: .west, expression: .smile)])
        controller.activatePhotoBooth(at: cell)
        #expect(controller.activePhotoBooth == nil)
        #expect(controller.photoBoothAtCurrentCell == nil)
        #expect(controller.canRotate)
        controller.beginDragRotate()
        controller.updateDragRotate(fraction: 0.5)
        #expect(controller.activePhotoBooth == nil)
    }

    @Test func captureLocksNavigationAndReplacesFlashWithPhoto() async throws {
        let cell = GridCoordinate(row: 0, col: 0)
        let scene = SCNScene()
        let camera = SCNNode()
        let booth = HallwayScene.makePhotoBoothNode(at: cell, direction: .north, expression: .smile, cellSize: 3.2)
        scene.rootNode.addChildNode(booth)
        let controller = TapNavigationController(cameraNode: camera, scene: scene,
            cells: [cell, GridCoordinate(row: 1, col: 0)], cellSize: 3.2,
            startCell: cell, startFacing: .north, endCell: cell,
            photoBooths: [cell: (direction: .north, expression: .smile)], photoBoothNodes: [cell: booth])
        controller.activatePhotoBooth(at: cell)
        #expect(!controller.canRotate && !controller.canGoForward)
        controller.advanceWhileHeld()
        #expect(!controller.isAnimating)
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        controller.completePhotoBooth(at: cell, image: photo)
        controller.updatePhotoBoothLiveImage(UIImage(), at: cell)
        #expect(controller.photoBoothCameraState == "captured")
        try await Task.sleep(for: .milliseconds(250))
        let material = try #require(booth.childNode(withName: "photoBoothScreen", recursively: true)?.geometry?.firstMaterial)
        #expect(material.diffuse.contents as? UIImage === photo)
        #expect((material.emission.contents as? UIColor) == UIColor.black)
        #expect(controller.activePhotoBooth == nil)
        #expect(controller.canRotate)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
    }
}
