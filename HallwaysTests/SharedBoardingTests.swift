import Foundation
import Testing
import SceneKit
@testable import Hallways

/// Oct 20 (iPhone: "when a critter is getting into the elevator, I cannot
/// enter") -- the car's doors, opened by the building for a resident, are a way
/// in for the player too: the threshold swipe crosses them (the car's gate makes
/// the doors the player's), a tap through the open doorway boards as a tap on
/// the doors does, and the resident and the player end up riding together, each
/// to their own floor. Follow mode is not needed for any of it.
@MainActor
struct SharedBoardingTests {
    /// A hallway cell at the elevator, its doors on the north wall (closed), F12.
    private struct Cab {
        let scene = SCNScene()
        let camera = SCNNode()
        let left = SCNNode()
        let right = SCNNode()
        let controller: TapNavigationController
        init() {
            let cell = GridCoordinate(row: 0, col: 0)
            camera.position = SCNVector3(0, 1.6, 0)                     // (yaw 0: facing north, the doors)
            left.position = SCNVector3(-0.24, 1.3, -1.6)
            right.position = SCNVector3(0.24, 1.3, -1.6)
            controller = TapNavigationController(cameraNode: camera, scene: scene, cells: [cell],
                cellSize: 3.2, startCell: cell, startFacing: .north, endCell: cell,
                elevatorLeftDoor: left, elevatorRightDoor: right,
                elevatorMountDirection: .north, floorNumber: 12)
            [camera, left, right].forEach { scene.rootNode.addChildNode($0) }
            controller.elevatorReachableFloors = Set(1...16)
        }
    }

    private func tick(_ renderer: SCNRenderer, from start: Double, through end: Double,
                      until done: (() -> Bool)? = nil) async -> Double {
        var t = start
        while t <= end {
            renderer.update(atTime: t)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            t += 0.025
            if let done, done() { return t }
        }
        return t
    }

    private func renderer(_ cab: Cab) -> SCNRenderer {
        let r = SCNRenderer(device: nil, options: nil)
        r.scene = cab.scene
        r.delegate = cab.controller
        return r
    }

    /// The building opens the car's doors here for a resident (as ElevatorBoard.present does).
    private func openForAResident(_ cab: Cab, _ r: SCNRenderer) async -> Double {
        cab.controller.runCarDoors(open: true)
        return await tick(r, from: 1, through: 3.2)
    }

    @Test func theSwipeCrossesAResidentsOpenDoorsAndTheyBecomeThePlayers() async {
        let cab = Cab()
        var gate: [(Int, String)] = []
        var holds: [Bool] = []
        cab.controller.carGate = { floor, who in gate.append((floor, who)); return true }     // (the car stands here)
        cab.controller.holdCarDoorway = { holds.append($0) }
        // Shut: nothing to cross (the swipe as it was).
        #expect(cab.controller.elevatorThresholdCrossing(forward: true) == nil)
        let r = renderer(cab)
        var t = await openForAResident(cab, r)
        #expect(cab.controller.carDoorsOpenHere)
        #expect(cab.controller.mayBoardThroughCarDoors)
        #expect(cab.controller.elevatorThresholdCrossing(forward: true) == .enter)        // finger down, facing in: in
        #expect(cab.controller.crossElevatorThreshold(forward: true))
        t = await tick(r, from: t, through: t + 8) { cab.controller.isElevatorRideInProgress && !cab.controller.isAnimating }
        _ = await tick(r, from: t, through: t + 1)
        // In the cab -- walked in (the threshold walk), never placed.
        let depth = Float(HallwayScene.ElevatorGeometry(cellSize: 3.2).entryDistance)
        #expect(abs(cab.camera.position.z + depth) < 0.01)
        #expect(cab.controller.elevatorAwaitingEntryDirection == .south)
        // The doors were taken through the car's own gate, once, by the player -- held for them meanwhile.
        #expect(gate.count == 1 && gate[0].0 == 12 && gate[0].1 == "player")
        #expect(holds.first == true && holds.last == false)
        // ...and they stay open: the resident still gets in; a floor button closes them.
        #expect(cab.right.position.x > 0.24 + 0.7)
        #expect(cab.controller.canStartElevatorExit)
        #expect(cab.controller.elevatorDoorsOpenIdle)
        #expect(cab.controller.elevatorThresholdCrossing(forward: false) == .exit)          // (and out again by swipe)
    }

    @Test func theCarGoneMeanwhileTheSwipeGlidesBack() async {
        let cab = Cab()
        cab.controller.carGate = { _, _ in false }                                           // (it left: called instead)
        let r = renderer(cab)
        var t = await openForAResident(cab, r)
        let start = cab.camera.position
        #expect(cab.controller.crossElevatorThreshold(forward: true))
        t = await tick(r, from: t, through: t + 3) { !cab.controller.isAnimating }
        _ = await tick(r, from: t, through: t + 0.5)
        #expect(!cab.controller.isElevatorRideInProgress)
        #expect(cab.controller.elevatorAwaitingEntryDirection == nil)
        #expect(abs(cab.camera.position.z - start.z) < 0.01)                                 // back where it began
    }

    @Test func aTapThroughTheOpenDoorwayBoardsAsATapOnTheDoorsDoes() async {
        let cab = Cab()
        cab.controller.carGate = { _, _ in true }
        let r = renderer(cab)
        _ = await openForAResident(cab, r)
        #expect(!cab.controller.boardThroughOpenCarDoorsByTap(direction: (x: 1, z: 0)))   // (sideways: not through the doors)
        #expect(cab.controller.boardThroughOpenCarDoorsByTap(direction: (x: 0.2, z: -0.98)))
        #expect(cab.controller.isElevatorRideInProgress)                                     // the ordinary boarding
    }

    @Test func noWayInWithTheDoorsShut() {
        let cab = Cab()
        cab.controller.carGate = { _, _ in true }
        #expect(!cab.controller.carDoorsOpenHere)
        #expect(!cab.controller.boardThroughOpenCarDoorsByTap(direction: (x: 0, z: -1)))
        #expect(!cab.controller.isElevatorRideInProgress)
    }

    @Test func throughTheDoorwayIsWithinFiftyDegreesOfStraightIn() {
        typealias C = TapNavigationController
        #expect(C.aimsThroughDoorway(direction: (x: 0, z: -1), mount: .north))
        #expect(C.aimsThroughDoorway(direction: (x: sin(0.7), z: -cos(0.7)), mount: .north))      // 40 degrees off
        #expect(!C.aimsThroughDoorway(direction: (x: sin(1.0), z: -cos(1.0)), mount: .north))     // 57 degrees off
        #expect(!C.aimsThroughDoorway(direction: (x: 0, z: 1), mount: .north))                    // away from it
    }

    // MARK: The car: a resident boarding and the player getting in, together

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func aResidentBoardingAndThePlayerShareTheCarEachToTheirFloor() {
        let c = BuildingElevator()
        c.placeIfNeeded(at: 4, now: t0)
        // The resident (its body acting, on the player's floor) calls; the car opens for it.
        c.call("hw.feddy", at: 4, to: 8, now: t0)
        var t = 0.0
        while t < 5, c.position(now: at(t))?.doors != .open { t += 0.25; c.advance(to: at(t), acting: ["hw.feddy"], actingFloor: 4) }
        #expect(c.position(now: at(t))?.doors == .open)
        // It walks in (holding the doors) -- and the player steps in through the same doors.
        c.hold("hw.feddy", until: at(t + 4))
        c.take(.player, name: "player", at: 4, now: at(t + 0.5))
        c.mirrorDoors(.open, now: at(t + 0.5), acting: ["hw.feddy"], actingFloor: 4)
        // Its walk-in still lands it aboard: the doors are still open (the player's now).
        #expect(c.board("hw.feddy", destination: nil, now: at(t + 2), at: 4))
        c.restoreRider("player", destination: nil, now: at(t + 2))
        #expect(c.rider("hw.feddy")?.destination == 8)
        #expect(c.rider("player") != nil)
        // The player chooses 12: the doors shut, the car runs there; Feddy rides on.
        c.mirrorDoors(.closing, now: at(t + 6))
        c.mirrorDoors(.closed, now: at(t + 7.6))
        let go = c.playerRuns(to: 12, now: at(t + 8))
        #expect(go.map(\.event) == [.departed(from: 4, to: 12)])
        let arrive = t + 8 + ElevatorTiming.run(floors: 8)
        c.advance(to: at(arrive + 0.5))
        c.playerArrived(at: 12, now: at(arrive + 0.5))
        #expect(c.rider("hw.feddy")?.destination == 8)                     // (not let out at the player's floor)
        // The player out, their doors shut: the building's car takes Feddy to 8.
        c.alight("player", now: at(arrive + 3))
        c.giveBack(now: at(arrive + 3))
        var out = [BuildingElevator.Happening]()
        var u = arrive + 3
        while u < arrive + 60 { u += 0.25; out += c.advance(to: at(u)) }
        #expect(out.map(\.event).contains(.alighted("hw.feddy", floor: 8)))
    }
}
