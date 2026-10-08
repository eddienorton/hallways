import Testing
import SceneKit
@testable import Hallways

@MainActor
struct ElevatorArrivalWorkTests {
    @Test(arguments: [1, 2, 7, 15])
    func countingUsesTheOriginalReadableSchedule(steps: Int) {
        let times = (1...steps).map { TapNavigationController.elevatorIndicatorStepDelay(step: $0, steps: steps) }
        #expect(abs((times.last ?? 0) - 3.8) < 0.000001)
        for (index, time) in times.enumerated() {
            let original = 0.5 + (4.5 - 0.5 - 0.7) * Double(index + 1) / Double(steps)
            #expect(abs(time - original) < 0.000001)
        }
    }

    @Test func animalPixelsAreReusedButMaterialsRemainIndependent() throws {
        let firstStarted = ProcessInfo.processInfo.systemUptime
        let first = RealAnimalSkins.make()
        let firstMS = (ProcessInfo.processInfo.systemUptime - firstStarted) * 1000
        let reusedStarted = ProcessInfo.processInfo.systemUptime
        let second = RealAnimalSkins.make()
        let reusedMS = (ProcessInfo.processInfo.systemUptime - reusedStarted) * 1000
        print("ARRIVAL_WORK_TEST animalMaterials firstRequestMS=\(firstMS) reusedRequestMS=\(reusedMS)")
        let originals = [first.dogCoat, first.dogSaddle, first.dogCream, first.catTabby, first.catWhite, first.catDark]
        let copies = [second.dogCoat, second.dogSaddle, second.dogCream, second.catTabby, second.catWhite, second.catDark]
        for (a, b) in zip(originals, copies) {
            #expect(a !== b)
            let imageA = try #require(a.diffuse.contents as? UIImage)
            let imageB = try #require(b.diffuse.contents as? UIImage)
            #expect(imageA === imageB)
            a.diffuse.contents = UIColor.magenta
            #expect((b.diffuse.contents as? UIImage) === imageB)
        }
    }

    @Test func proceduralSurfacePixelsAreReusedAndMissingAssetsStayMissing() throws {
        let first = try #require(HallwayScene.resolveThemeImage(HallwayScene.officeWallGradientName))
        let second = try #require(HallwayScene.resolveThemeImage(HallwayScene.officeWallGradientName))
        #expect(first === second)
        #expect(first.size.width > 0 && first.size.height > 0)
        #expect(HallwayScene.resolveThemeImage(nil) == nil)
        #expect(HallwayScene.resolveThemeImage("__missing_arrival_test_texture__") == nil)
    }
}
