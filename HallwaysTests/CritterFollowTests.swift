import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 20 -- FOLLOW A CRITTER: a tap on a roaming resident's body is that
/// resident (wherever on it the finger lands); the follow walk is the escort's
/// own continuous walk, sent along the way to the critter -- turning round
/// first if the way is behind -- and stopping a gap short of it.
@MainActor
struct CritterFollowTests {
    @MainActor private final class Body: ResidentPresentation {
        let residentID: String
        let node = SCNNode()
        var guiding = false
        init(_ id: String) { residentID = id }
        var holdsResident: Bool { true }
        var isRendered: Bool { true }
        var isGuiding: Bool { guiding }
        var bodyNode: SCNNode? { node }
        func tick(now: Date) {}
        func teardown() {}
        func playerBoarding() -> Bool { false }
        func arrivalDoorsOpening() {}
        /// Oct 20 (later): how many come-hithers it was asked for.
        var acknowledged = 0
        func acknowledgeFollower(player: SIMD2<Float>?) { acknowledged += 1 }
    }

    private func corridor(facing: Direction = .east) -> TapNavigationController {
        let cells = Set((0...10).map { GridCoordinate(row: 0, col: $0) })
        return TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: cells, cellSize: 3.2,
                                       startCell: GridCoordinate(row: 0, col: 0), startFacing: facing,
                                       endCell: GridCoordinate(row: 0, col: 10), floorNumber: 4)
    }

    @Test func aTapAnywhereOnItsBodyIsThatResident() {
        let feddy = Body("hw.feddy"), sister = Body("hw.sister")
        let arm = SCNNode(), hand = SCNNode()
        feddy.node.addChildNode(arm)
        arm.addChildNode(hand)
        let saved = BuildingLife.shared.presentations
        defer { BuildingLife.shared.presentations = saved }
        BuildingLife.shared.presentations = [feddy, sister]
        #expect(CritterFollow.residentID(owning: hand) == "hw.feddy")
        #expect(CritterFollow.residentID(owning: sister.node) == "hw.sister")
        #expect(CritterFollow.residentID(owning: SCNNode()) == nil)          // (a wall, a door: nobody)
        sister.guiding = true                                                 // (the butterfly guiding: not followable)
        #expect(CritterFollow.residentID(owning: sister.node) == nil)
    }

    @Test func theFollowWalkGoesTheWayToItAndStopsAGapShort() async {
        // A corridor along row 0, cols 0...10; the player at col 0 facing WEST (away).
        let cells = Set((0...10).map { GridCoordinate(row: 0, col: $0) })
        let c = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: cells, cellSize: 3.2,
                                        startCell: GridCoordinate(row: 0, col: 0), startFacing: .west,
                                        endCell: GridCoordinate(row: 0, col: 10), floorNumber: 4)
        let leader = SIMD2<Float>(6 * 3.2, 0)
        c.followGuidance = { (route: (0...6).map { GridCoordinate(row: 0, col: $0) }, leader: leader) }
        #expect(c.startFollowWalk())
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        for _ in 0..<(12 * 40) {
            time += 0.025
            c.renderer(renderer, updateAtTime: time)
            try? await Task.sleep(for: .milliseconds(2))
        }
        let x = Double(c.cameraNode.position.x)
        #expect(x > 3 * 3.2)                                                 // (it turned round and went east, to the critter)
        #expect(x < Double(leader.x) - TapNavigationController.escortFollowGap + 0.3)   // (and kept its distance)
        c.stopContinuousWalk(reason: "test")
    }

    @Test func noFloorButtonPressedOutsideTheCab() {
        let cell = GridCoordinate(row: 0, col: 0)
        let c = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: [cell], cellSize: 3.2,
                                        startCell: cell, startFacing: .east, endCell: cell, floorNumber: 4)
        #expect(!c.pressElevatorFloorForFollow(9))
        #expect(!c.stepOutOfElevatorForFollow())
        #expect(!c.playerIsSteering)
    }

    // MARK: Oct 20 (later) -- the iPhone fix: follow, unfollow, switch; acknowledged once

    @Test func aTapFollowsAgainStopsAnotherSwitches() {
        #expect(CritterFollow.outcome(tapping: "hw.feddy", following: nil) == .follow("hw.feddy"))
        #expect(CritterFollow.outcome(tapping: "hw.feddy", following: "hw.feddy") == .unfollow("hw.feddy"))
        #expect(CritterFollow.outcome(tapping: "hw.sister", following: "hw.feddy") == .switchTo(from: "hw.feddy", to: "hw.sister"))
    }

    @Test func followingIsAcknowledgedOnceUnfollowingIsntSwitchingAcknowledgesTheNewOne() {
        let feddy = Body("hw.feddy"), sister = Body("hw.sister"), pottle = Body("pottle.1")
        let saved = BuildingLife.shared.presentations
        defer {
            CritterFollow.stop(reason: "test over")
            BuildingLife.shared.presentations = saved
        }
        BuildingLife.shared.presentations = [feddy, sister, pottle]
        let c = corridor()
        // Tap Feddy: following him, and he acknowledges it -- once.
        CritterFollow.tapped("hw.feddy", controller: c)
        #expect(CritterFollow.targetID == "hw.feddy")
        #expect(feddy.acknowledged == 1)
        // The following goes on (ticks, path updates): no second gesture.
        CritterFollow.tick(); CritterFollow.tick(); CritterFollow.tick()
        #expect(feddy.acknowledged == 1)
        // Tap Feddy again: stopped -- and no come-hither for that.
        CritterFollow.tapped("hw.feddy", controller: c)
        #expect(CritterFollow.targetID == nil)
        #expect(feddy.acknowledged == 1)
        // Tap Feddy, then Sister: switched -- she acknowledges, he isn't asked again.
        CritterFollow.tapped("hw.feddy", controller: c)
        CritterFollow.tapped("hw.sister", controller: c)
        #expect(CritterFollow.targetID == "hw.sister")
        #expect(feddy.acknowledged == 2 && sister.acknowledged == 1)
        // A critter of another kind (Pottle) is followed the same way.
        CritterFollow.tapped("pottle.1", controller: c)
        #expect(CritterFollow.targetID == "pottle.1")
        #expect(pottle.acknowledged == 1)
    }

    @Test func tapDetectionFindsEveryKindOfResident() {
        // A Hallwaysian's arm, the chair's seat, a critter's pot -- each its own resident.
        let feddy = Body("hw.feddy"), chair = Body("chair.1"), pottle = Body("pottle.1"), butterfly = Body("butterfly")
        let arm = SCNNode(), seat = SCNNode(), pot = SCNNode(), wing = SCNNode()
        feddy.node.addChildNode(arm); chair.node.addChildNode(seat); pottle.node.addChildNode(pot); butterfly.node.addChildNode(wing)
        let saved = BuildingLife.shared.presentations
        defer { BuildingLife.shared.presentations = saved }
        BuildingLife.shared.presentations = [feddy, chair, pottle, butterfly]
        #expect(CritterFollow.residentID(owning: arm) == "hw.feddy")
        #expect(CritterFollow.residentID(owning: seat) == "chair.1")
        #expect(CritterFollow.residentID(owning: pot) == "pottle.1")
        #expect(CritterFollow.residentID(owning: wing) == "butterfly")
        // Mr. Tinky (and any scripted character) is no resident: never followed by a tap.
        #expect(CritterFollow.residentID(owning: SCNNode()) == nil)
    }

    @Test func theWalksOwnHeadingDecidesNotTheCamera() {
        // Facing WEST, the critter EAST: the walk sets off east -- its heading is east at
        // once, while the camera is still turning (the old check read the camera and
        // stopped the walk every tick).
        let c = corridor(facing: .west)
        c.followGuidance = { (route: (0...6).map { GridCoordinate(row: 0, col: $0) }, leader: SIMD2<Float>(6 * 3.2, 0)) }
        #expect(c.startFollowWalk())
        #expect(c.walkHeading == .east)
        c.stopContinuousWalk(reason: "test")
        #expect(CritterFollow.turnBackGrace >= 0.5)
    }

    @Test func followingRoundACorner() async {
        // An L: east along row 0 to col 4, then south down col 4 to row 4; the critter at (4,4).
        var cells = Set((0...4).map { GridCoordinate(row: 0, col: $0) })
        for r in 1...4 { cells.insert(GridCoordinate(row: r, col: 4)) }
        let c = TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: cells, cellSize: 3.2,
                                        startCell: GridCoordinate(row: 0, col: 0), startFacing: .east,
                                        endCell: GridCoordinate(row: 4, col: 4), floorNumber: 4)
        var route = (0...4).map { GridCoordinate(row: 0, col: $0) }
        route += (1...4).map { GridCoordinate(row: $0, col: 4) }
        let leader = SIMD2<Float>(4 * 3.2, 4 * 3.2)
        c.followGuidance = { (route: Array(route.drop { $0 != c.currentCell }), leader: leader) }
        #expect(c.startFollowWalk())
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        for _ in 0..<(20 * 40) {
            time += 0.025
            c.renderer(renderer, updateAtTime: time)
            try? await Task.sleep(for: .milliseconds(2))
            if c.continuousWalkState == .stopped { break }
        }
        let p = c.cameraNode.position
        #expect(abs(p.x - 4 * 3.2) < 1.0)                                       // round the corner, down col 4
        #expect(p.z > 1.5 * 3.2)
        #expect(Double(simd_distance(SIMD2<Float>(p.x, p.z), leader)) >= TapNavigationController.escortFollowGap - 0.3)   // (and kept its distance)
        c.stopContinuousWalk(reason: "test")
    }

    // MARK: Evening, Oct 20 -- the sticky, slow following

    @Test func theFollowWalkNeverTakesOverUnderTheFinger() {
        let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // A finger down (looking round): never.
        #expect(!CritterFollow.mayRestart(touching: true, lastManual: .distantPast, now: t))
        // Just let go: not yet -- the view is theirs a moment longer.
        #expect(!CritterFollow.mayRestart(touching: false, lastManual: t, now: t.addingTimeInterval(0.2)))
        #expect(CritterFollow.handsOffGrace <= 0.5)                           // (prompt: not a sluggish wait)
        // Hands off a while: it carries on after the critter.
        #expect(CritterFollow.mayRestart(touching: false, lastManual: t, now: t.addingTimeInterval(CritterFollow.handsOffGrace + 0.01)))
        #expect(CritterFollow.mayRestart(touching: false, lastManual: .distantPast, now: t))
    }

    @Test func roundACornerTheCritterStillSetsThePace() {
        typealias C = TapNavigationController
        let east = (x: 1.0, z: 0.0)
        // Ahead: it holds the walk (escort and critter alike).
        #expect(C.leaderHolds(along: east, dx: 3, dz: 0.5, beside: false))
        #expect(C.leaderHolds(along: east, dx: 3, dz: 0.5, beside: true))
        // Round the corner, off to the side: the escort's rule lets the walk run on (as it
        // always did); following a critter it holds -- no sprint to the corner.
        #expect(!C.leaderHolds(along: east, dx: 0, dz: 4, beside: false))
        #expect(C.leaderHolds(along: east, dx: 0, dz: 4, beside: true))
        #expect(C.leaderHolds(along: east, dx: -1, dz: 4, beside: true))           // (a little behind the side: still)
        // Behind: never (the follow turns round instead).
        #expect(!C.leaderHolds(along: east, dx: -4, dz: 0.5, beside: true))
    }

    @Test func theMeterSaysHowFastEachReallyGoes() throws {
        var meter = FollowMeter()
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var line: String?
        for k in 0...20 {                                                    // 5 s of ticks, 0.25 s apart
            let t = Double(k) * 0.25
            let guide = SIMD2<Float>(Float(0.7 * t), 0)                      // the guide at 0.7 m/s
            let player = SIMD2<Float>(Float(0.7 * t) - 1.8, 0)                // the player 1.8 m behind, the same pace
            line = meter.sample(now: t0.addingTimeInterval(t), guide: guide, player: player, who: "hw.feddy") ?? line
        }
        let said = try #require(line)
        #expect(said.contains("guide 0.70 m/s"))
        #expect(said.contains("you 0.70 m/s"))
        #expect(said.contains("walk restarts 0"))
        #expect(said.contains("gap 1.8 m"))
    }
}

