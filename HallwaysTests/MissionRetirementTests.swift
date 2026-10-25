import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 25 (PP 3) -- THE OLD MISSIONS RETIRED: Floor 5 always fully lit (whatever was saved), Panel 5A
/// inert, the butterfly's lights concern gone, task.01 never an objective, nothing taken from Floor 4's
/// supply room. Their types and saved keys stay; the butterfly stays a resident and the band's flute.
@MainActor
struct MissionRetirementTests {

    /// Floor 5's eight circuit areas, plus a fluorescent fixture (an authored one, as the floor's
    /// build makes them) hanging in the West Hall, circuit 1.
    private func floorFive() -> (root: SCNNode, cells: Set<GridCoordinate>, lamp: SCNLight) {
        let s: Float = 3.52
        let cells = FloorFiveBlackout.circuits.reduce(Set<GridCoordinate>()) { $0.union($1.cells) }
        let root = SCNNode()
        let fixture = SCNNode()
        fixture.name = "authored_fluorescent"
        fixture.position = SCNVector3(9 * s, 2.9, 10 * s)                  // (row 10, col 9: West Hall)
        let bulb = SCNNode()
        bulb.light = SCNLight()
        bulb.light?.type = .omni
        bulb.light?.intensity = 300
        fixture.addChildNode(bulb)
        root.addChildNode(fixture)
        return (root, cells, bulb.light!)
    }

    /// Runs `body` with floor5.circuits.v1 set to `mask` (nil: absent -- a fresh game / Start Over),
    /// and puts the real saved value back afterwards.
    private func withSavedCircuits(_ mask: Int?, _ body: () throws -> Void) rethrows {
        let d = UserDefaults.standard
        let old = d.object(forKey: FloorFiveBlackout.circuitsKey)
        defer { if let old { d.set(old, forKey: FloorFiveBlackout.circuitsKey) } else { d.removeObject(forKey: FloorFiveBlackout.circuitsKey) } }
        if let mask { d.set(mask, forKey: FloorFiveBlackout.circuitsKey) } else { d.removeObject(forKey: FloorFiveBlackout.circuitsKey) }
        try body()
    }

    // 1, 4 (relaunch: nothing saved but the old key) -- a fresh game: all eight on.
    @Test func aFreshFloorFiveHasEveryCircuitOn() {
        #expect(FloorFiveBlackout.retired)
        withSavedCircuits(nil) {
            #expect((1...8).allSatisfy(FloorFiveBlackout.isOn))
            #expect(FloorFiveBlackout.allPowered && FloorFiveBlackout.effectiveMask == 0xFF)
        }
    }

    // 2 -- an old save with every circuit (or some) off can't darken the floor, and isn't rewritten.
    @Test func savedOffCircuitsCannotDarkenFloorFive() {
        for mask in [0, 0b0000_0101, 0b0111_1111] {
            withSavedCircuits(mask) {
                #expect((1...8).allSatisfy(FloorFiveBlackout.isOn))
                #expect(FloorFiveBlackout.allPowered)
                #expect(FloorFiveBlackout.savedMask == mask)                 // (the saved value is left as it was)
            }
        }
    }

    // 1, 2, 3 -- built (and built again, as leaving and coming back does) with every circuit saved
    // off: the hall's fixture at full strength, no emergency fill.
    @Test func floorFiveIsBuiltLitEveryTime() {
        withSavedCircuits(0) {
            for visit in 1...2 {
                let f = floorFive()
                FloorFiveBlackout.install(into: f.root, cellSize: 3.52, cells: f.cells)
                let bulb = f.root.childNodes.first?.childNodes.first
                #expect(f.lamp.intensity == 300, "visit \(visit)")
                #expect(bulb?.isHidden == false, "visit \(visit)")
                #expect(FloorFiveBlackout.emergencyIntensity == 0, "visit \(visit)")
            }
            #expect(FloorFiveBlackout.savedMask == 0)                       // (still never written)
        }
    }

    // 6, 9 -- the butterfly has no concern: no prompt, no waypoint (panel or flashlight), no progress to celebrate.
    @Test func theButterflyNoLongerHasTheLightsMission() {
        withSavedCircuits(0) {
            let concern = FloorFiveLightsConcern()
            #expect(!concern.isActive)
            #expect(!Butterfly.concern.isActive)
            for floor in [4, 5] { #expect(concern.nextWaypoint(onFloor: floor) == nil) }
        }
        #expect(BandInstruments.byResident["butterfly"] == "flute")       // still the band's flute
    }

    // 7 -- task.01 is completed (never offered, never assigned), even if the breakers' test said otherwise.
    @Test func taskOneIsNeverAnObjective() throws {
        let storage = ThrowawayStorage()
        let reg = TaskRegistry(defaults: storage.defaults, persists: false)
        reg.fuseBoxDone = { false }
        var cells = Set<GridCoordinate>()
        for r in 0..<18 { for c in 0..<20 { cells.insert(GridCoordinate(row: r, col: c)) } }
        reg.ensureGenerated(plans: { f in
            guard (1...7).contains(f) else { return nil }
            return FloorPlan(floor: f, cells: cells, doors: [:], bathroomDoors: [:], elevator: GridCoordinate(row: 5, col: 0),
                             furnished: [], cellSize: 3.52)
        }, seed: 9)
        let fuse = try #require(reg.task(TaskRegistry.fuseBoxID))             // (kept in the saved list)
        #expect(reg.state(of: fuse) == .completed)
        #expect(!reg.available().contains { $0.id == fuse.id })
        #expect(!reg.assign(fuse.id))
        #expect(reg.available().count == TaskRegistry.placeholderCount)    // the placeholders FOLLOW leads to remain
    }

    // 10 -- the supply room is retired as a mission but still a residents' room.
    @Test func theSupplyRoomIsRetiredButStillARoom() throws {
        #expect(SuppliesShowroom.retired)
        var cells = SuppliesShowroom.roomCells
        cells.insert(GridCoordinate(row: 10, col: 6))
        cells.insert(SuppliesShowroom.foyerCell)
        let floor4 = FloorPlan(floor: SuppliesShowroom.floor, cells: cells, doors: [:], bathroomDoors: [:],
                               elevator: GridCoordinate(row: 10, col: 6), furnished: [], cellSize: 3.52)
        #expect(floor4.rooms.map(\.name) == ["Supply Room"])
    }
}
