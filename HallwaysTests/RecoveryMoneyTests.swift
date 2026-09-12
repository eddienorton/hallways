import Testing
import SceneKit
@testable import Hallways

@MainActor
struct RecoveryMoneyTests {
    @Test func authoredMoneyLoadsWithoutTruncationAndIncreasesByFloor() {
        let store = MazeStore()
        let counts = [0, 13, 8, 17, 26, 30]
        var previousTotal = -1
        for floor in 1...6 {
            store.switchTo(id: floor)
            let cash = store.objects.filter { $0.value.cashValue != nil }
            #expect(cash.count == counts[floor - 1])
            #expect(cash.keys.allSatisfy { store.cells.contains($0) })
            let total = cash.values.reduce(0) { $0 + ($1.cashValue(onFloor: floor) ?? 0) }
            #expect(total > previousTotal)
            previousTotal = total
        }
        store.switchTo(id: 2)
        #expect(store.objects.values.filter { $0.cashValue != nil }.count == 13)
    }

    @Test func movementAwardsCorrectDenominationOnceWithoutCarryingCash() async {
        for floor in 2...6 {
            let start = GridCoordinate(row: 0, col: 0)
            let pickup = GridCoordinate(row: 0, col: 1)
            let controller = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(),
                cells: [start, pickup], cellSize: 3.2, startCell: start, startFacing: .east,
                endCell: pickup, objects: [pickup: .cash100], floorNumber: floor)
            var awards: [Int] = []
            controller.onCollectCash = { awards.append($0) }
            let renderer = SCNRenderer(device: nil, options: nil)
            var time = 0.0
            controller.advance()
            for _ in 0..<100 {
                time += 0.025
                controller.renderer(renderer, updateAtTime: time)
                await Task.yield()
            }
            #expect(controller.currentCell == pickup)
            #expect(awards == [(floor - 1) * 100])
            #expect(controller.collectedObjects.isEmpty)
            controller.stepBackward()
            for _ in 0..<100 {
                time += 0.025
                controller.renderer(renderer, updateAtTime: time)
                await Task.yield()
            }
            controller.advance()
            for _ in 0..<100 {
                time += 0.025
                controller.renderer(renderer, updateAtTime: time)
                await Task.yield()
            }
            #expect(awards == [(floor - 1) * 100])
        }
    }
}
