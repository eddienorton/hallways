import Foundation
import AVFoundation
import SceneKit
import Testing
@testable import Hallways

/// Oct 9 -- sound isolation: Settings silences the game without touching
/// Mute; a shut office door muffles building sounds from outside. Throwaway
/// defaults only. Simulator only.
@MainActor
@Suite(.serialized)
struct SoundIsolationTests {
    private func defaults() -> UserDefaults {
        let name = "SoundIsolationTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
    private func player(volume: Float) throws -> AVAudioPlayer {
        let p = try AVAudioPlayer(data: BobbinSound.wav([Float](repeating: 0, count: 2_000)))
        p.volume = volume
        return p
    }

    // MARK: Settings

    @Test func settingsSilencesAndRestoresWithoutTouchingMute() throws {
        let store = defaults()
        let audio = HallwaysAudio(defaults: store)
        let chime = audio.manage(try player(volume: 0.8))
        audio.setSuppressed(true, reason: "settings")
        #expect(chime.volume == 0 && audio.isSuppressed && !audio.isMuted)
        #expect(store.object(forKey: HallwaysAudio.mutedKey) == nil)          // nothing persisted
        audio.setSuppressed(false, reason: "settings")
        #expect(chime.volume == 0.8 && !audio.isSuppressed)
    }

    @Test func muteStillWinsAfterSettingsCloses() throws {
        let audio = HallwaysAudio(defaults: defaults())
        let chime = audio.manage(try player(volume: 0.8))
        audio.setMuted(true)
        audio.setSuppressed(true, reason: "settings")
        audio.setSuppressed(false, reason: "settings")
        #expect(chime.volume == 0 && audio.isMuted)                           // still muted
        audio.setMuted(false)
        #expect(chime.volume == 0.8)
    }

    @Test func aVolumeChangeWhileSettingsIsOpenWaitsUntilItCloses() throws {
        let audio = HallwaysAudio(defaults: defaults())
        let ding = audio.manage(try player(volume: 1))
        audio.setSuppressed(true, reason: "settings")
        audio.setVolume(ding, 0.3)
        #expect(ding.volume == 0)
        audio.setSuppressed(false, reason: "settings")
        #expect(ding.volume == 0.3)
    }

    // MARK: Closed doors (the office on Floor 3)

    /// A small piece of Floor 3: the east corridor (rows 3-7, col 12) and the
    /// office below its door at (7,12) -> (8,12).
    private func installOfficeFloor(listenerAt cell: GridCoordinate) {
        let s: CGFloat = 3.52
        var cells: [(row: Int, col: Int)] = (3...7).map { (row: $0, col: 12) }
        cells += [(8, 12), (8, 13), (9, 12), (9, 13)]
        let listener = SCNNode()
        listener.position = SCNVector3(Float(cell.col) * Float(s), 1.6, Float(cell.row) * Float(s))
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        CritterAudio.beginFloor(view: view, listener: listener, doors: nil,
                                hallwayCell: SIMD2<Float>(0, 0), cellSize: s, walkableCells: cells)
    }
    private func point(_ c: GridCoordinate) -> SIMD3<Float> { SIMD3<Float>(Float(c.col) * 3.52, 1.5, Float(c.row) * 3.52) }

    @Test func aShutOfficeDoorMufflesTheCorridorAndOpeningItRestoresIt() {
        installOfficeFloor(listenerAt: GridCoordinate(row: 9, col: 13))       // the far corner, by the desk
        let corridor = point(GridCoordinate(row: 6, col: 12))
        CritterAudio.setClosedDoors([])
        let open = CritterAudio.buildingGain(at: corridor)
        CritterAudio.setClosedDoors([(row: 7, col: 12, dRow: 1, dCol: 0)])
        let shut = CritterAudio.buildingGain(at: corridor)
        CritterAudio.setClosedDoors([])
        #expect(open > 0.5)
        #expect(shut <= open * CritterAudio.oneWallGain + 0.0001)
        #expect(shut > 0)                                                     // muffled, not silenced
    }

    @Test func insideTheSameRoomTheDoorChangesNothing() {
        installOfficeFloor(listenerAt: GridCoordinate(row: 9, col: 13))
        let desk = point(GridCoordinate(row: 8, col: 13))
        CritterAudio.setClosedDoors([(row: 7, col: 12, dRow: 1, dCol: 0)])
        let gain = CritterAudio.buildingGain(at: desk)
        CritterAudio.setClosedDoors([])
        #expect(gain > 0.99)                                                  // only the tiny distance fade
    }

    @Test func farBuildingSoundsFadeButNeverVanishByDistanceAlone() {
        installOfficeFloor(listenerAt: GridCoordinate(row: 3, col: 12))
        let near = CritterAudio.buildingGain(at: point(GridCoordinate(row: 3, col: 12)))
        let far = CritterAudio.buildingGain(at: point(GridCoordinate(row: 7, col: 12)))   // ~14 m down the corridor
        #expect(near == 1)
        #expect(far < near && far >= 0.25)
    }
}
