import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 21 -- ONE TAP, ONE WALK (Administration). The pieces that can be tried
/// without the floor itself: the counter's capped pose stops a tap toward it ON
/// the pose (no walking in close and being glided back), the walk toward Tinky's
/// office stops in the anteroom (never his desk landing), and a card-taken walk
/// never starts once the player has moved off the kiosk.
@MainActor
struct AdministrationWalkTests {
    /// Floor 2's reception row: the elevator (10,6), the vestibule (10,7), the hall (10,8),
    /// the counter cell (10,9) whose pose faces east 0.6 m back from its centre.
    private func reception() -> TapNavigationController {
        let cells = Set((6...9).map { GridCoordinate(row: 10, col: $0) })
        let c = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: cells, cellSize: 3.52,
                                        startCell: GridCoordinate(row: 10, col: 7), startFacing: .east,
                                        endCell: GridCoordinate(row: 10, col: 6), floorNumber: 2)
        c.landingSpots = [.init(kind: "receptionDesk", face: AdministrationReception.deskLanding,
                                standOff: AdministrationReception.deskStandOff, onLanded: {}, capsApproach: true)]
        return c
    }

    @Test func aTapTowardTheCounterStopsOnItsPoseNotPastIt() {
        let c = reception()
        c.cameraNode.position = SCNVector3(7 * 3.52, 1.6, 10 * 3.52)                // (the vestibule's centre)
        // Toward the counter, far enough: the pose lies along it -- the point walk, which stops there.
        #expect(c.cappedLandingAhead(direction: (1, 0), distance: 12))
        // Not toward it (along the vestibule), or not far enough to reach it: the latch as ever.
        #expect(!c.cappedLandingAhead(direction: (0, 1), distance: 12))
        #expect(!c.cappedLandingAhead(direction: (1, 0), distance: 2))
        #expect(!c.cappedLandingAhead(direction: nil, distance: 12))
    }

    @Test func theWalkTowardTinkyStopsInTheAnteroomFacingHisOffice() {
        #expect(TapNavigationController.towardTinkyStop.coord == AdministrationReception.officeAnteroom)
        #expect(TapNavigationController.towardTinkyStop.direction == .south)
        #expect(TapNavigationController.towardTinkyStop.coord != FredOfficeEncounter.landing.coord)   // (never his desk landing)
        #expect(AdministrationReception.entranceDoorCell == GridCoordinate(row: 10, col: 7))
    }

    @Test func noCardWalkOnceThePlayerHasMovedOffTheKiosk() async {
        let c = reception()                                                          // (not in the kiosk's pose)
        c.scheduleWalkTowardTinky(after: 0.05)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(c.adminWalk == nil)
        #expect(c.continuousWalkState == .stopped)
    }

    @Test func noWalkToJuanitaOnceTheIDIsDoneOrOffFloorTwo() {
        // Off Floor 2 (a plain hall): never.
        let cells = Set((0...4).map { GridCoordinate(row: 0, col: $0) })
        let c = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: cells, cellSize: 3.52,
                                        startCell: GridCoordinate(row: 0, col: 0), startFacing: .east,
                                        endCell: GridCoordinate(row: 0, col: 4), floorNumber: 6)
        #expect(!c.startAdminWalk(.toJuanita))
        #expect(c.adminWalk == nil && c.continuousWalkState == .stopped)
    }
}
