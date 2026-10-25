import Testing
import SceneKit
@testable import Hallways

@MainActor
struct ElevatorArrivalWorkTests {
    @Test(arguments: [1, 2, 7, 15])
    func countingUsesTheOriginalReadableSchedule(steps: Int) {
        // Oct 18 (open the building): the car's one timing -- floors counted evenly,
        // the last landing at the lead-in plus ElevatorTiming.ride (35% slower than
        // the old 4.5 s count; longer for a longer run).
        let times = (1...steps).map { TapNavigationController.elevatorIndicatorStepDelay(step: $0, steps: steps) }
        let lead = TapNavigationController.elevatorIndicatorLeadIn
        #expect(abs((times.last ?? 0) - (lead + ElevatorTiming.ride(floors: steps))) < 0.000001)
        #expect(abs(ElevatorTiming.ride(floors: 1) - 4.5 / 0.65) < 0.000001)
        for (index, time) in times.enumerated() {
            let even = lead + ElevatorTiming.ride(floors: steps) * Double(index + 1) / Double(steps)
            #expect(abs(time - even) < 0.000001)
            if index > 0 { #expect(time > times[index - 1]) }                 // (never a pause, never backwards)
        }
    }

    // (Oct 19, Stage A: the Dog and Cat skins test went with the Dog and the Cat.)

    @Test func proceduralSurfacePixelsAreReusedAndMissingAssetsStayMissing() throws {
        let first = try #require(HallwayScene.resolveThemeImage(HallwayScene.officeWallGradientName))
        let second = try #require(HallwayScene.resolveThemeImage(HallwayScene.officeWallGradientName))
        #expect(first === second)
        #expect(first.size.width > 0 && first.size.height > 0)
        #expect(HallwayScene.resolveThemeImage(nil) == nil)
        #expect(HallwayScene.resolveThemeImage("__missing_arrival_test_texture__") == nil)
    }
}
