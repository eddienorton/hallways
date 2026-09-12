import Testing
import SceneKit
import UIKit
import Vision
@testable import Hallways

@MainActor
struct RecoveryBatchTests {
    private func tick(_ controller: TapNavigationController, renderer: SCNRenderer, time: inout Double, count: Int) async {
        for _ in 0..<count {
            time += 0.025
            controller.renderer(renderer, updateAtTime: time)
            await Task.yield()
        }
    }

    @Test func mapPausesActiveHeldWalkAndBlocksNewMovementWithoutReset() async {
        let start = GridCoordinate(row: 0, col: 0), end = GridCoordinate(row: 0, col: 5)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: Set((0...5).map { GridCoordinate(row: 0, col: $0) }), cellSize: 3.2,
            startCell: start, startFacing: .east, endCell: end)
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 0.0, cancelledHolds = 0
        controller.onHandheldMapOpened = { cancelledHolds += 1 }
        controller.advanceWhileHeld()
        await tick(controller, renderer: renderer, time: &time, count: 25)
        let position = controller.cameraNode.position, cell = controller.currentCell
        #expect(position.x > 0)
        controller.openHandheldMap()
        #expect(cancelledHolds == 1)
        #expect(!controller.canGoForward && !controller.canRotate)
        controller.advance(); controller.advanceWhileHeld(); controller.stepBackward(); controller.rotate(toward: .west)
        await tick(controller, renderer: renderer, time: &time, count: 120)
        #expect(SCNVector3EqualToVector3(controller.cameraNode.position, position))
        #expect(controller.currentCell == cell)
        #expect(controller.facing == .east)
        controller.closeHandheldMap()
        #expect(SCNVector3EqualToVector3(controller.cameraNode.position, position))
        await tick(controller, renderer: renderer, time: &time, count: 240)
        #expect(controller.currentCell == end)
        #expect(!controller.isAnimating)
    }

    @Test func queuedArrivalWaitsForMapCloseAndIsDeliveredOnce() async {
        let start = GridCoordinate(row: 0, col: 0), end = GridCoordinate(row: 0, col: 1)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [start,end], cellSize: 3.2, startCell: start, startFacing: .east,
            endCell: end, objects: [end: .cash100])
        var pickups = 0
        controller.onCollectCash = { _ in pickups += 1 }
        controller.advanceWhileHeld()
        let renderer = SCNRenderer(device: nil, options: nil)
        // Queue the arrival on main, then open the map before that queue runs.
        for i in 1...24 { controller.renderer(renderer, updateAtTime: Double(i) * 0.025) }
        controller.openHandheldMap()
        for _ in 0..<10 { await Task.yield() }
        #expect(controller.currentCell == start)
        #expect(pickups == 0)
        controller.closeHandheldMap()
        #expect(controller.currentCell == end)
        #expect(pickups == 1)
        controller.closeHandheldMap()
        #expect(pickups == 1)
    }

    @Test func openingMapDuringDragDoesNotLeaveRotationLocked() async {
        let cell = GridCoordinate(row: 0, col: 0)
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
            cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell)
        controller.beginDragRotate(); controller.updateDragRotate(fraction: 0.4)
        controller.openHandheldMap()
        #expect(!controller.isDragRotating)
        let angle = controller.cameraNode.eulerAngles.y
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 0.0
        await tick(controller, renderer: renderer, time: &time, count: 20)
        #expect(controller.cameraNode.eulerAngles.y == angle)
        controller.closeHandheldMap()
        await tick(controller, renderer: renderer, time: &time, count: 20)
        #expect(controller.canRotate)
        #expect(controller.facing == .north)
        #expect(abs(controller.cameraNode.eulerAngles.y) < 0.001)
    }

    @Test func allFourMapTrianglesMatchGridMovementAndWallMap() async throws {
        let center = GridCoordinate(row: 1, col: 1)
        let cells = Set((0...2).flatMap { row in (0...2).map { GridCoordinate(row: row, col: $0) } })
        let mapPlane = SCNNode(geometry: SCNPlane(width: 1, height: 1))
        mapPlane.geometry?.materials = [SCNMaterial()]
        let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: cells,
            cellSize: 3.2, startCell: center, startFacing: .north,
            endCell: GridCoordinate(row: 0, col: 0), floorMapPlaneNodes: [mapPlane])
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 0.0
        for direction in [Direction.east, .south, .west, .north] {
            controller.rotate(toward: direction)
            await tick(controller, renderer: renderer, time: &time, count: 20)
            #expect(controller.facing == direction)
            let image = controller.currentFloorMapImage()
            let delta = direction.delta
            let tip = CGPoint(x: 88 + CGFloat(delta.col) * 13, y: 88 + CGFloat(delta.row) * 13)
            let behind = CGPoint(x: 88 - CGFloat(delta.col) * 13, y: 88 - CGFloat(delta.row) * 13)
            #expect(try isBlue(image, at: tip))
            #expect(try !isBlue(image, at: behind))
            #expect((mapPlane.geometry?.firstMaterial?.diffuse.contents as? UIImage)?.pngData() == image.pngData())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-map-\(direction).png")
            try image.pngData()?.write(to: url)
            print("RECOVERY_VISUAL \(url.path)")
            // Match the compass marker to actual SceneKit/world translation.
            let neighbor = GridCoordinate(row: center.row + delta.row, col: center.col + delta.col)
            let walker = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: [center,neighbor],
                cellSize: 3.2, startCell: center, startFacing: direction, endCell: neighbor)
            walker.advance()
            var walkTime = 0.0
            await tick(walker, renderer: renderer, time: &walkTime, count: 50)
            #expect(walker.currentCell == neighbor)
            #expect(abs(walker.cameraNode.position.x - Float(neighbor.col) * 3.2) < 0.001)
            #expect(abs(walker.cameraNode.position.z - Float(neighbor.row) * 3.2) < 0.001)
        }
    }

    private func isBlue(_ image: UIImage, at point: CGPoint) throws -> Bool {
        let cg = try #require(image.cgImage)
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let result = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
            let offset = (y * cg.width + x) * 4
            return bytes[offset] < 60 && bytes[offset + 1] < 70 && bytes[offset + 2] > 180
        }
        return result
    }

    @Test func floorLabelsAndNewMapsUseFreeSolidWalls() throws {
        let store = MazeStore()
        let additions: [Int: [(GridCoordinate, Direction)]] = [
            2: [(GridCoordinate(row: 10, col: 7), .west)],
            3: [(GridCoordinate(row: 10, col: 7), .west)],
            4: [(GridCoordinate(row: 10, col: 7), .west), (GridCoordinate(row: 5, col: 3), .west)],
            5: [(GridCoordinate(row: 10, col: 7), .west), (GridCoordinate(row: 2, col: 1), .west), (GridCoordinate(row: 17, col: 13), .east)],
            6: [(GridCoordinate(row: 10, col: 7), .west), (GridCoordinate(row: 2, col: 13), .east), (GridCoordinate(row: 18, col: 13), .east)]
        ]
        for floor in 1...store.floorCount {
            store.switchTo(id: floor)
            let cells = store.cells
            let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: cells,
                cellSize: 3.2, startCell: MazeStore.elevatorCoordinate, startFacing: .south,
                endCell: MazeStore.elevatorCoordinate, floorNumber: floor)
            #expect(controller.floorLabel == (floor == 1 ? "LOBBY" : "FLOOR \(floor)"))
            // Floor 1 remains the cash-free introduction in every recovery batch.
            if floor == 1 { #expect(store.objects.values.allSatisfy { $0.cashValue == nil }) }
            for (coord,direction) in additions[floor] ?? [] {
                #expect(store.floorMaps[coord] == direction)
                #expect(cells.contains(coord))
                #expect(!cells.contains(GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)))
                #expect(!(coord == MazeStore.elevatorCoordinate && direction == .north))
                #expect(store.pictures[coord] != direction)
                #expect(store.mirrors[coord] != direction)
                #expect(store.missionSigns[coord] != direction)
                #expect(store.roomDoors[coord]?.direction != direction)
                #expect(store.extinguishers[coord] != direction)
                #expect(store.photoBooths[coord]?.direction != direction)
            }
        }
    }

    @Test func welcomeSignIsTallAndContainsCompleteInstructions() throws {
        let store = MazeStore(); store.switchTo(id: 2)
        let image = HallwayScene.makeMissionSignTexture(heading: store.missionHeading, body: store.missionBody)
        #expect(image.size == CGSize(width: 700, height: 900))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-welcome-sign.png")
        try image.pngData()?.write(to: url)
        print("RECOVERY_VISUAL \(url.path)")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: #require(image.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
        for phrase in ["WELCOME TO HALLWAYS", "COMPLETE EACH FLOOR'S MISSION", "TO UNLOCK THE ELEVATOR", "AND MOVE UP", "COLLECT ALL TRASH", "DROP IT IN THE CHUTE"] {
            #expect(text.contains(phrase), "Missing or clipped sign text: \(phrase); read: \(text)")
        }
    }
}
