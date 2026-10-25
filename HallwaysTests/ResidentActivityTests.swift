import Foundation
import SceneKit
import simd
import Testing
@testable import Hallways

/// Oct 18 -- RESIDENT LIFE, PHASE 2: what's in a room (found in the scene, by
/// its real geometry), what a resident chooses to do about it, where it
/// stands to do it, how its eyes aim, and what it can see. No renderer: plain
/// nodes and numbers.
@MainActor
struct ResidentActivityTests {
    private let cs: Float = 3.52
    private func at(_ row: Int, _ col: Int) -> SIMD2<Float> { SIMD2<Float>(Float(col) * cs, Float(row) * cs) }

    private func thing(_ kind: RoomThing.Kind, _ label: String, at p: SIMD2<Float> = .zero, top: Float = 0.8, radius: Float = 0.5) -> RoomThing {
        RoomThing(kind: kind, label: label, center: p, top: top, radius: radius)
    }

    // MARK: What's in the room

    @Test func roomThingsAreFoundInTheSceneByTheirGeometry() throws {
        let root = SCNNode()
        func add(_ name: String, w: CGFloat, h: CGFloat, l: CGFloat, row: Int, col: Int) {
            let n = SCNNode(geometry: SCNBox(width: w, height: h, length: l, chamferRadius: 0))
            n.name = name
            let p = at(row, col)
            n.position = SCNVector3(p.x + 0.3, Float(h) / 2, p.y - 0.2)
            root.addChildNode(n)
        }
        add("furnitureDesk", w: 1.2, h: 0.76, l: 0.6, row: 9, col: 5)
        add("furnitureFloorLamp", w: 0.3, h: 1.6, l: 0.3, row: 8, col: 5)
        add("breakerPanel", w: 0.5, h: 0.8, l: 0.1, row: 9, col: 5)            // a mission's, never an idle look
        add("furnitureDesk", w: 1.2, h: 0.76, l: 0.6, row: 10, col: 7)          // in the hall, not the room
        add("furnitureDeskTop", w: 1.2, h: 0.05, l: 0.6, row: 9, col: 5)        // (a part, not a thing)
        let room: Set<GridCoordinate> = [GridCoordinate(row: 9, col: 5), GridCoordinate(row: 8, col: 5)]
        let things = RoomThings.find(in: root, cells: room, cellSize: cs)
        #expect(things.count == 2)
        let desk = try #require(things.first { $0.kind == .desk })
        #expect(desk.label == "desk")
        #expect(abs(desk.top - 0.76) < 0.01)
        #expect(abs(desk.center.x - (at(9, 5).x + 0.3)) < 0.01)
        #expect(abs(desk.center.y - (at(9, 5).y - 0.2)) < 0.01)
        #expect(abs(desk.radius - 0.6) < 0.01)
        let lamp = try #require(things.first { $0.kind == .lamp })
        #expect(lamp.label == "floor lamp")
        #expect(lamp.lookPoint.y > 1.4)
    }

    // MARK: Choosing

    @Test func anEmptyRoomMeansRestingOrLookingAround() {
        for seed in UInt64(0)..<40 {
            let c = ResidentActivities.choose(for: .chair, things: [], seed: seed)
            #expect(c.thing == nil)
            #expect([.resting, .lookingAround].contains(c.kind))
        }
    }

    @Test func theChairWorksAtDesksAndTheButterflyCirclesLamps() {
        let desk = thing(.desk, "desk"), lamp = thing(.lamp, "floor lamp", top: 1.6)
        var working = 0, circling = 0
        for seed in UInt64(0)..<200 {
            let chair = ResidentActivities.choose(for: .chair, things: [desk], seed: seed)
            #expect(chair.kind != .circling && chair.kind != .investigating)          // (the chair's tastes only)
            if chair.kind == .working { working += 1; #expect(chair.thing == desk) }
            let fly = ResidentActivities.choose(for: .butterfly, things: [lamp], seed: seed)
            #expect(fly.kind != .working && fly.kind != .visiting)
            if fly.kind == .circling { circling += 1; #expect(fly.thing == lamp) }
        }
        #expect(working > 60)                         // (about half: never fixed, never never)
        #expect(circling > 60)
        // The same seed, the same choice: a life replays the same way.
        #expect(ResidentActivities.choose(for: .chair, things: [desk, lamp], seed: 7).kind
                == ResidentActivities.choose(for: .chair, things: [desk, lamp], seed: 7).kind)
    }

    // MARK: Where to stand

    @Test func itStandsBesideTheThingOnItsOwnSide() throws {
        let desk = thing(.desk, "desk", radius: 0.5)
        let p = try #require(ResidentActivities.standPoint(for: desk, from: SIMD2<Float>(3, 0), standoff: 0.35, allowed: { _ in true }))
        #expect(abs(p.x - 0.85) < 0.001)
        #expect(abs(p.y) < 0.001)
        // That side not allowed (out of the room): round to a side that is, the same distance off.
        let q = try #require(ResidentActivities.standPoint(for: desk, from: SIMD2<Float>(3, 0), standoff: 0.35, allowed: { $0.x < -0.1 }))
        #expect(q.x < -0.1)
        #expect(abs(simd_length(q) - 0.85) < 0.001)
        // Nowhere allowed: none.
        #expect(ResidentActivities.standPoint(for: desk, from: SIMD2<Float>(3, 0), standoff: 0.35, allowed: { _ in false }) == nil)
    }

    @Test func thePanelSaysRoomActivityAndAttention() {
        #expect(ResidentActivities.note(room: "Copy Center", doing: "inspecting the desk", attention: "looking at desk")
                == "Copy Center / inspecting the desk / looking at desk")
        #expect(ResidentActivities.note(room: nil, doing: "walking", attention: nil) == "hallway / walking")
    }

    // MARK: Eyes

    @Test func eyeAnglesPointTheEyeAtItsTarget() {
        let ahead = CritterEyes.angles(toward: SIMD3<Float>(0, 0, -1))
        #expect(abs(ahead.yaw) < 0.0001 && abs(ahead.pitch) < 0.0001)
        let right = CritterEyes.angles(toward: SIMD3<Float>(1, 0, -1))
        #expect(abs(right.yaw + .pi / 4) < 0.001)                     // (yaw h faces (-sin h, ., -cos h))
        let up = CritterEyes.angles(toward: SIMD3<Float>(0, 1, -1))
        #expect(abs(up.pitch - .pi / 4) < 0.001)
        // The angles and the look agree both ways, and the eye's turn carries -z onto the look.
        for d in [SIMD3<Float>(0.4, -0.3, -1), SIMD3<Float>(-0.7, 0.5, -0.6)] {
            let a = CritterEyes.angles(toward: d)
            let look = CritterEyes.direction(yaw: a.yaw, pitch: a.pitch)
            #expect(simd_distance(simd_normalize(look), simd_normalize(d)) < 0.001)
            let turned = CritterEyes.rotation(yaw: a.yaw, pitch: a.pitch).act(SIMD3<Float>(0, 0, -1))
            #expect(simd_distance(turned, simd_normalize(d)) < 0.001)
        }
    }

    @Test func eyesTurnWithinTheirLimitsAndSayWhenATargetIsBeyond() {
        let body = SCNNode()
        let pivot = SCNNode()
        body.addChildNode(pivot)
        let eyes = CritterEyes(pivots: [pivot], lids: [pivot], maxYaw: 0.8, maxPitch: 0.5)
        let ahead = eyes.aim(at: SIMD3<Float>(0.5, 0, -3), duration: 0.1)
        #expect(ahead.yaw < 0 && ahead.yaw > -0.8)
        #expect(ahead.beyond == 0)
        let behind = eyes.aim(at: SIMD3<Float>(3, 0, 0.5), duration: 0.1)          // round to its right and back
        #expect(abs(behind.yaw + 0.8) < 0.0001)                                      // as far as it goes
        #expect(behind.beyond > 0.25)                                                // (time to turn the body)
        // Turned with the body: the same world point is now ahead of it.
        body.eulerAngles = SCNVector3(0, -Float.pi / 2, 0)
        let turned = eyes.aim(at: SIMD3<Float>(3, 0, 0), duration: 0.1)
        #expect(abs(turned.yaw) < 0.01)
        #expect(eyes.aim(at: nil, duration: 0.1).yaw == 0)
    }

    // MARK: Sight

    @Test func itSeesAlongOpenCellsButNotThroughAShutDoor() {
        // A hall row 10, cols 4-8; a room (9,5) behind a door on (10,5)'s north wall.
        var cells = Set<GridCoordinate>()
        for col in 4...8 { cells.insert(GridCoordinate(row: 10, col: col)) }
        cells.insert(GridCoordinate(row: 9, col: 5))
        let doors: [GridCoordinate: Direction] = [GridCoordinate(row: 10, col: 5): .north]
        let hallA = GridCoordinate(row: 10, col: 4), hallB = GridCoordinate(row: 10, col: 7), room = GridCoordinate(row: 9, col: 5)
        #expect(CritterSight.connected(hallA, hallB, cells: cells, doors: doors, isOpen: { _ in false }))
        #expect(!CritterSight.connected(room, hallA, cells: cells, doors: doors, isOpen: { _ in false }))
        #expect(CritterSight.connected(room, hallA, cells: cells, doors: doors, isOpen: { _ in true }))
        #expect(!CritterSight.connected(room, GridCoordinate(row: 3, col: 3), cells: cells, doors: doors, isOpen: { _ in true }))
    }
}
