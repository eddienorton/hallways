import Foundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 9 -- employee ID access control for the elevator. Pure rule and
/// scene checks: nothing reads or writes the player's saved progress.
/// Simulator only.
@MainActor
struct ElevatorAccessTests {
    // 1. A new player (no ID) may ride only between the Lobby and Administration.
    @Test func withoutAnIDOnlyLobbyAndAdministrationAreOpen() {
        #expect(ElevatorAccess.permits(1, hasEmployeeID: false))
        #expect(ElevatorAccess.permits(2, hasEmployeeID: false))
        for floor in 3...16 { #expect(!ElevatorAccess.permits(floor, hasEmployeeID: false), "floor \(floor)") }
    }

    // 2./3. With the ID (the persisted admission state) every floor is open.
    @Test func withAnIDEveryFloorIsOpen() {
        for floor in 1...16 { #expect(ElevatorAccess.permits(floor, hasEmployeeID: true), "floor \(floor)") }
    }

    // The open floors are exactly the way to the ID kiosk.
    @Test func administrationIsTheLastOpenFloor() {
        #expect(ElevatorAccess.openFloorsMax == Admission.administrationFloor)
    }

    // 4. Mission progress is a separate rule, still switched off.
    @Test func missionsStillDoNotGateTheElevator() {
        #expect(TapNavigationController.missionGatesElevator == false)
    }

    // 7. Every cab has the reader, to the passenger's right of the plate,
    // its centre level with the 8-9 buttons (halfway up the panel), facing
    // the same way -- and the plate itself is unchanged (buttons intact).
    @Test func everyCabHasTheReaderBesideThePanel() throws {
        for floor in [1, 2, 3, 12] {
            let cell = GridCoordinate(row: 0, col: 0)
            let result = HallwayScene.build(fromMaze: [cell], cellSize: 3.52, wallHeight: 3,
                                            floorNumber: floor, totalFloors: 16, playerStart: cell, playerEnd: cell)
            let root = result.scene.rootNode
            let plate = try #require(root.childNode(withName: "elevatorControlPanel", recursively: true))
            let reader = try #require(root.childNode(withName: ElevatorCardReader.nodeName, recursively: true))
            #expect(plate.childNode(withName: "elevatorControlButton_1", recursively: false) != nil)
            #expect(reader.parent === plate.parent)                                   // same wall
            let plateBox = try #require(plate.geometry as? SCNBox)
            #expect(reader.position.x < plate.position.x - Float(plateBox.width) / 2)  // passenger's right
            #expect(reader.position.x > plate.position.x - Float(plateBox.width) / 2 - 0.2)
            let eight = try #require(plate.childNode(withName: "elevatorControlButton_8", recursively: false))
            #expect(abs(reader.position.y - (plate.position.y + eight.position.y)) < 0.005)   // level with 8-9
            #expect(abs(reader.position.y - plate.position.y) < Float(plateBox.height) / 4)    // about halfway up
            let halfHeight = ElevatorCardReader.baseHeight * ElevatorCardReader.scale / 2
            #expect(reader.position.y + halfHeight < plate.position.y + Float(plateBox.height) / 2)  // within the panel's height
            #expect(reader.position.y - halfHeight > plate.position.y - Float(plateBox.height) / 2)
            #expect(abs(reader.position.z - plate.position.z) < 0.03)                 // flush on the same liner
        }
    }

    // The lamp starts at a dim neutral standby; a refusal shows red, a read
    // shows green; repeated flashes leave exactly one pending return.
    @Test func theLampAnswersAndReturnsToStandby() throws {
        let root = SCNNode()
        root.addChildNode(ElevatorCardReader.make())
        let lamp = try #require(root.childNode(withName: ElevatorCardReader.lampName, recursively: true))
        let material = try #require(lamp.geometry?.firstMaterial)
        #expect(material.emission.contents as? UIColor == ElevatorCardReader.standbyGlow)
        ElevatorCardReader.flash(granted: false, in: root)
        #expect(material.emission.contents as? UIColor == ElevatorCardReader.deniedGlow)
        ElevatorCardReader.flash(granted: false, in: root)
        ElevatorCardReader.flash(granted: true, in: root)
        #expect(material.emission.contents as? UIColor == ElevatorCardReader.grantedGlow)
        #expect(lamp.actionKeys == [ElevatorCardReader.flashActionKey])
    }

    // Oct 9 (green holds): choosing an authorized floor turns the reader
    // green with nothing to swipe, and it stays green for the trip -- through
    // the floor rebuild (the arriving cab's own reader) until the doors open.
    @Test func greenHoldsForTheAuthorizedTrip() throws {
        defer { ElevatorCardReader.tripAuthorized = false }
        let departing = SCNNode()
        departing.addChildNode(ElevatorCardReader.make())
        let lamp = try #require(departing.childNode(withName: ElevatorCardReader.lampName, recursively: true))
        ElevatorCardReader.showGranted(in: departing)
        #expect(lamp.geometry?.firstMaterial?.emission.contents as? UIColor == ElevatorCardReader.grantedGlow)
        #expect(lamp.actionKeys.isEmpty)                                                  // nothing scheduled: it holds
        // The arriving cab (a fresh build) is green too while the trip lasts.
        ElevatorCardReader.tripAuthorized = true
        let arriving = SCNNode()
        arriving.addChildNode(ElevatorCardReader.make())
        let arrivingLamp = try #require(arriving.childNode(withName: ElevatorCardReader.lampName, recursively: true))
        ElevatorCardReader.presentArrival(in: arriving)
        #expect(arrivingLamp.geometry?.firstMaterial?.emission.contents as? UIColor == ElevatorCardReader.grantedGlow)
        // Doors opening: the trip is over -- one pending return to standby.
        ElevatorCardReader.arrivalDoorsOpening(in: arriving)
        #expect(!ElevatorCardReader.tripAuthorized)
        #expect(arrivingLamp.actionKeys == [ElevatorCardReader.flashActionKey])
        // An unauthorized arrival stays at standby.
        let plain = SCNNode()
        plain.addChildNode(ElevatorCardReader.make())
        ElevatorCardReader.presentArrival(in: plain)
        let plainLamp = try #require(plain.childNode(withName: ElevatorCardReader.lampName, recursively: true))
        #expect(plainLamp.geometry?.firstMaterial?.emission.contents as? UIColor == ElevatorCardReader.standbyGlow)
        // Denial is unchanged: a brief red that returns.
        ElevatorCardReader.flash(granted: false, in: departing)
        #expect(lamp.geometry?.firstMaterial?.emission.contents as? UIColor == ElevatorCardReader.deniedGlow)
        #expect(lamp.actionKeys == [ElevatorCardReader.flashActionKey])
    }

    // Oct 9: the reader is enlarged (about 11 x 16.5 cm) and still fits beside the plate.
    @Test func theReaderIsTheEnlargedSize() {
        let reader = ElevatorCardReader.make()
        #expect(reader.scale.x == ElevatorCardReader.scale && ElevatorCardReader.scale >= 1.5)
        #expect(ElevatorCardReader.baseWidth * ElevatorCardReader.scale > 0.1)
        #expect(ElevatorCardReader.baseHeight * ElevatorCardReader.scale > 0.16)
    }

    // Each cab's lamp is its own: flashing one never lights another build's.
    @Test func eachReaderHasItsOwnLamp() throws {
        let a = SCNNode(), b = SCNNode()
        a.addChildNode(ElevatorCardReader.make())
        b.addChildNode(ElevatorCardReader.make())
        ElevatorCardReader.flash(granted: false, in: a)
        let other = try #require(b.childNode(withName: ElevatorCardReader.lampName, recursively: true)?.geometry?.firstMaterial)
        #expect(other.emission.contents as? UIColor == ElevatorCardReader.standbyGlow)
    }
}
