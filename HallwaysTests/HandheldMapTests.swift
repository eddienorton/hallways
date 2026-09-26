import Testing
import UIKit
import SceneKit
@testable import Hallways

@MainActor
struct HandheldMapTests {
    @Test func bottomAnchoredAcrossRotation() {
        for size in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393), CGSize(width: 320, height: 568)] {
            let geometry = HandheldMapGeometry(viewport: size, topInset: 24, bottomInset: 34)
            // Rule 1: the FLOOR N pill has ONE fixed rect, bottom 8pt
            // above the safe visible edge; its height is real font metrics.
            #expect(geometry.pillRect.maxY == size.height - 34 - HandheldMapGeometry.hudPillToSafeGap)
            #expect(geometry.pillRect.height == HandheldMapGeometry.hudPillHeight)
            // Rules 2-4: the map's bottom-right corner is THE anchor,
            // derived from the pill (8pt above its top, fixed right
            // clearance). Mini and full maps show the SAME corner.
            #expect(geometry.mapBottomRight.x == size.width - HandheldMapGeometry.miniMapRightClearance)
            #expect(geometry.mapBottomRight.y == geometry.pillRect.minY - HandheldMapGeometry.mapToHudPillGap)
            #expect(geometry.miniRect.maxX == geometry.mapBottomRight.x)
            #expect(geometry.miniRect.maxY == geometry.mapBottomRight.y)
            #expect(geometry.fullRect.maxX == geometry.mapBottomRight.x)
            #expect(geometry.fullRect.maxY == geometry.mapBottomRight.y)
            // Mini is the fixed mini square; full is the fixed paper size.
            #expect(geometry.miniRect.size == CGSize(width: HandheldMapGeometry.miniSize, height: HandheldMapGeometry.miniSize))
            #expect(geometry.fullRect.size == geometry.paperSize)
            // Rule 3 zoom: the full card scaled by miniScale about its
            // bottom-trailing corner lands exactly on the mini rect --
            // zero positional jump at both ends of the swap.
            #expect(abs(geometry.miniScale - HandheldMapGeometry.miniSize / geometry.paperSize.width) < 0.0001)
            #expect(abs(geometry.paperSize.width * geometry.miniScale - HandheldMapGeometry.miniSize) < 0.0001)
            // Same tuning contract as before: ~2 points per cell smaller.
            let biggest = min(320, size.width - 24, size.height - 24 - 80)
            #expect(geometry.imageSize <= biggest - 30 + 0.001)
            // Both states stay on screen; the full map never drops below
            // the pill (its corner is 8pt above the pill by construction).
            #expect(geometry.miniRect.minX >= 0 && geometry.miniRect.minY >= 0)
            #expect(geometry.fullRect.minX >= 0 && geometry.fullRect.minY >= 0)
            #expect(geometry.fullRect.maxY < geometry.pillRect.minY)
        }
    }

    @Test func titleUsesActualFloor() {
        let cell = GridCoordinate(row: 0, col: 0)
        for floor in [2, 3, 16] {
            let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: [cell], cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell, floorNumber: floor)
            #expect(controller.handheldMapTitle == "Map of Floor \(floor)")
        }
    }

    @Test func missionFillWinsOverRoomAndBackgroundAloneCanBeTransparent() throws {
        let room = GridCoordinate(row: 5, col: 5)
        let other = GridCoordinate(row: 0, col: 0)
        func render(mission: Bool, opacity: CGFloat) -> UIImage {
            HallwayScene.makeFloorMapTexture(cells: [room], end: other, playerAt: other,
                missionItemCells: mission ? [room] : [],
                roomDoors: [room: RoomDoorPlacement(coord: room, direction: .north, roomNumber: 501)],
                backgroundOpacity: opacity)
        }
        func pixel(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
            let cg = try #require(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: 752 * 752 * 4)
            let context = try #require(CGContext(data: &bytes, width: 752, height: 752, bitsPerComponent: 8, bytesPerRow: 752 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 752, height: 752))
            let offset = (y * 752 + x) * 4
            return Array(bytes[offset..<offset + 4])
        }
        // Above the room-number glyphs, inside both the brown square and green dot.
        let green = try pixel(render(mission: true, opacity: 0), x: 280, y: 263)
        let brown = try pixel(render(mission: false, opacity: 1), x: 280, y: 263)
        #expect(green[1] > green[0] * 2)
        #expect(green[3] == 255)
        #expect(brown[0] > brown[1])
        #expect(try pixel(render(mission: true, opacity: 0), x: 740, y: 740)[3] == 0)
        #expect(try pixel(render(mission: true, opacity: 1), x: 740, y: 740)[3] == 255)
    }

    @Test func simplifiedTextureShowsFloorAndPlayerOnly() throws {
        let start = GridCoordinate(row: 0, col: 0)
        let cells: Set<GridCoordinate> = [start, GridCoordinate(row: 0, col: 1), GridCoordinate(row: 1, col: 0), GridCoordinate(row: 5, col: 5)]
        let image = HallwayScene.makeFloorMapTexture(cells: cells, end: GridCoordinate(row: 5, col: 5), playerAt: start,
            facing: .east, roomDoors: [GridCoordinate(row: 5, col: 5): RoomDoorPlacement(coord: GridCoordinate(row: 5, col: 5), direction: .north, roomNumber: 501)],
            simplified: true, backgroundOpacity: 1)
        let cg = try #require(image.cgImage)
        let w = cg.width
        let scale = CGFloat(w) / 192
        func sample(x: CGFloat, y: CGFloat) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: w * w * 4)
            let context = try #require(CGContext(data: &bytes, width: w, height: w, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: w))
            let offset = (Int(y * scale) * w + Int(x * scale)) * 4
            return Array(bytes[offset..<offset + 4])
        }
        // A plain corridor cell (row 0, col 1): warm floor tone, no annotation.
        let floor = try sample(x: 24, y: 12)
        #expect(floor[0] > floor[2])
        // The player cell's center (row 0, col 0) carries the blue arrow (facing east).
        let blue = try sample(x: 12, y: 12)
        #expect(blue[2] > blue[0] * 3)
    }
}