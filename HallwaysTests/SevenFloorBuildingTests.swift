import Testing
import SceneKit
@testable import Hallways

/// Oct 25 (PP 2): the seven-floor building -- floors in use, stand-ins for 8-16, resume from a floor out
/// of use, and the seven-button cab panel (larger caps, shared look, tap target that grows with them).
@MainActor
struct SevenFloorBuildingTests {

    // MARK: Floors in use

    @Test func theBuildingIsSevenFloors() {
        #expect(ActiveBuilding.experimentTopFloor == 7)
        ActiveBuilding.testTopFloor = 7
        defer { ActiveBuilding.testTopFloor = nil }
        #expect((1...7).allSatisfy(ActiveBuilding.isActive))
        #expect(!(8...16).contains(where: ActiveBuilding.isActive))
    }

    @Test func everyFloorOutOfUseHasAStandInAmongTheResidentsFloors() {
        ActiveBuilding.testTopFloor = 7
        defer { ActiveBuilding.testTopFloor = nil }
        var load: [Int: Int] = [:]
        for f in 8...16 {
            let s = ActiveBuilding.standIn(for: f)
            #expect((4...7).contains(s), "floor \(f) -> \(s)")
            #expect(ActiveBuilding.standIns[f] == s)             // its own line, not the fallback
            load[s, default: 0] += 1
        }
        #expect((load[5] ?? 0) <= 2)                              // no pile-up on Floor 5
        #expect(load.values.allSatisfy { $0 <= 3 })
        for f in 1...7 { #expect(ActiveBuilding.standIn(for: f) == f) }
    }

    @Test func foldingKeepsEveryLikingOnFloorsInUse() {
        ActiveBuilding.testTopFloor = 7
        defer { ActiveBuilding.testTopFloor = nil }
        let liked: [Int: Double] = [4: 1, 6: 2, 9: 3, 12: 1.5, 16: 0.5]
        let folded = ActiveBuilding.fold(liked)
        #expect(folded.keys.allSatisfy(ActiveBuilding.isActive))
        #expect(abs(folded.values.reduce(0, +) - liked.values.reduce(0, +)) < 1e-9)   // nothing lost or doubled
    }

    @Test func aPointSavedOnAFloorOutOfUseIsNotResumed() throws {
        let d = UserDefaults.standard
        let keys = [ResumeState.pointKey, Admission.initialEntranceKey, Admission.prologueCompletedKey]
        let saved = keys.map { d.object(forKey: $0) }
        let wasRecording = ResumeState.isRecording
        ActiveBuilding.testTopFloor = 7
        defer {
            for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            ResumeState.isRecording = wasRecording
            ActiveBuilding.testTopFloor = nil
        }
        ResumeState.isRecording = true
        d.set(true, forKey: Admission.initialEntranceKey)
        d.set(true, forKey: Admission.prologueCompletedKey)
        func savePoint(floor: Int) throws {
            d.set(try JSONEncoder().encode(ResumeState.Point(floor: floor, x: 1, z: 2, yaw: 0)), forKey: ResumeState.pointKey)
        }
        // Floor 9 (out of use): the ordinary launch -- and nothing else is lost.
        try savePoint(floor: 9)
        #expect(!ResumeState.resumesAtSavedPoint)
        #expect(ResumeState.launchFloor(available: Set((1...16).filter(ActiveBuilding.isActive))) == nil)
        #expect(ResumeState.point?.floor == 9)                                     // the point itself is kept
        #expect(d.bool(forKey: Admission.prologueCompletedKey) && d.bool(forKey: Admission.initialEntranceKey))
        // Floor 6 (in use): resumed as before.
        try savePoint(floor: 6)
        #expect(ResumeState.resumesAtSavedPoint)
        #expect(ResumeState.launchFloor(available: Set((1...16).filter(ActiveBuilding.isActive))) == 6)
    }

    // MARK: The cab panel

    private func panel(floor: Int = 3, totalFloors: Int = 7) throws -> (root: SCNNode, plate: SCNNode) {
        let cell = GridCoordinate(row: 0, col: 0)
        let result = HallwayScene.build(fromMaze: [cell], cellSize: 3.52, wallHeight: 3,
                                        floorNumber: floor, totalFloors: totalFloors, playerStart: cell, playerEnd: cell)
        let root = result.scene.rootNode
        return (root, try #require(root.childNode(withName: "elevatorControlPanel", recursively: true)))
    }

    @Test func sevenButtonsInFourRows() throws {
        let (_, plate) = try panel()
        func cap(_ f: Int) throws -> SCNNode { try #require(plate.childNode(withName: "elevatorControlButton_\(f)", recursively: false)) }
        #expect(plate.childNode(withName: "elevatorControlButton_8", recursively: false) == nil)
        for (a, b) in [(6, 7), (4, 5), (2, 3)] {
            #expect(abs(try cap(a).position.y - cap(b).position.y) < 1e-5)       // a row
            #expect(try cap(a).position.x > cap(b).position.x)                     // even on the passenger's left (+X)
        }
        #expect(try cap(6).position.y > cap(4).position.y && cap(4).position.y > cap(2).position.y && cap(2).position.y > cap(1).position.y)
        #expect(abs(try cap(1).position.x) < 1e-5)                                  // LOBBY centred, alone
    }

    @Test func largerCapsThatNeverTouchAndStayOnThePlate() throws {
        let m = HallwayScene.ElevatorPanelMetrics.self
        #expect(m.buttonRadius >= 0.048 * 1.25 && m.buttonRadius <= 0.048 * 1.3)
        #expect(m.colSpacing > m.rimRadius * 2 && m.rowSpacing > m.rimRadius * 2)  // rims clear in rows and columns
        let (_, plate) = try panel()
        let box = try #require(plate.geometry as? SCNBox)
        let lobbyHalfWidth = m.rimRadius * CGFloat(HallwayScene.elevatorButtonWidthScale(floor: 1))
        #expect(lobbyHalfWidth * 2 < box.width - 0.04)                              // LOBBY's oval well inside
        #expect(m.colSpacing / 2 + m.rimRadius < box.width / 2)                     // the pairs too
        for child in plate.childNodes where child.name?.hasPrefix("elevatorControlButton_") == true {
            #expect(abs(child.position.y) + Float(m.rimRadius) < Float(box.height) / 2)
        }
    }

    @Test func theTapTargetCoversTheWholeVisibleButton() {
        let m = HallwayScene.ElevatorPanelMetrics.self
        #expect(m.hitRadius >= Float(m.rimRadius))                                   // the outer rim registers
        #expect(m.hitRadius <= Float(min(m.colSpacing, m.rowSpacing)) / 2 + 1e-6)    // never past halfway to a neighbour
    }

    @Test func buttonsAreSilverGrayUntilChosen() throws {
        let (_, plate) = try panel()
        for f in 1...7 {
            let cap = try #require(plate.childNode(withName: "elevatorControlButton_\(f)", recursively: false))
            #expect(cap.geometry?.firstMaterial?.diffuse.contents as? UIColor == HallwayScene.ElevatorButtonLook.unselectedDiffuse)
        }
        let lit = HallwayScene.ElevatorButtonLook.selected()
        #expect(lit.diffuse.contents as? UIColor == UIColor(red: 1.0, green: 0.82, blue: 0.35, alpha: 1))   // the orange, unchanged
    }

    @Test func readerAndIndicatorSitWithTheSevenFloorPanel() throws {
        let (root, plate) = try panel()
        let box = try #require(plate.geometry as? SCNBox)
        let reader = try #require(root.childNode(withName: ElevatorCardReader.nodeName, recursively: true))
        #expect(reader.position.x < plate.position.x - Float(box.width) / 2)                     // passenger's right
        #expect(abs(reader.position.y - plate.position.y) < 0.005)                               // no 8-9 row: the panel's centre
        let indicator = try #require(root.childNode(withName: "elevatorFloorIndicator", recursively: true))
        #expect(indicator.position.y > plate.position.y + Float(box.height) / 2)                 // above the plate
        #expect(abs(indicator.position.x - plate.position.x) < 1e-4)
    }
}
