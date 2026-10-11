import Foundation
import Testing
import simd
@testable import Hallways

/// Oct 9 -- the stuck-guide fix: Tinky's final stop in the office is released
/// as soon as the player is IN the office, however far across it they are,
/// and a lead whose body leaves the scene reports it. No saved data touched.
@MainActor
@Suite(.serialized)
struct OnboardingGuideReleaseTests {
    final class FakePerformer: LeadPerformer {
        var position: SIMD2<Float>? = .zero
        var calls = 0
        var groundPosition: SIMD2<Float>? { position }
        var isGesturing: Bool { false }
        func travel(_ path: [SIMD2<Float>], then: @escaping () -> Void) { position = path.last ?? position; then() }
        func touch(_ point: SIMD2<Float>, contact: @escaping () -> Void, then: @escaping () -> Void) { contact(); then() }
        func watch(_ player: SIMD2<Float>) {}
        func pointOnward(_ onward: SIMD2<Float>, player: SIMD2<Float>) {}
        func call() { calls += 1 }
        func urge(player: SIMD2<Float>, onward: SIMD2<Float>?, then: @escaping () -> Void) { then() }
        func arrive(player: SIMD2<Float>) {}
        func depart() {}
        func settle(facing heading: Float?) {}
    }

    private let s: Float = 3.52
    private func center(_ c: GridCoordinate) -> SIMD2<Float> { SIMD2<Float>(Float(c.col) * s, Float(c.row) * s) }

    /// The office's final stop, as GuidedJourney builds it.
    private func lead(player: @escaping () -> SIMD2<Float>, performer: FakePerformer) -> CharacterLead {
        let context = CharacterLead.Context(cells: PlayerOffice.officeCells.union([PlayerOffice.doorCell]), doors: [:], cellSize: s,
                                            playerPose: { (player(), 0) }, isDoorOpen: { _ in true }, openDoor: { _ in })
        var stop = CharacterLead.Stop(point: PlayerOffice.welcomeSpot, onward: nil, isFinal: true, cell: PlayerOffice.entryCell)
        stop.waitsForPlayer = true
        stop.release = 2.0
        stop.releaseCells = PlayerOffice.officeCells
        performer.position = PlayerOffice.welcomeSpot
        return CharacterLead(performer: performer, context: context, steps: [.stop(stop)])
    }

    @Test func aPlayerAcrossTheOfficeReleasesTheFinalStopOnce() async throws {
        let far = center(GridCoordinate(row: 9, col: 13))           // the far corner: ~5 m from him
        #expect(simd_distance(far, PlayerOffice.welcomeSpot) > 2.0)
        let performer = FakePerformer()
        let lead = lead(player: { far }, performer: performer)
        var released = 0
        lead.onFinalRelease = { released += 1 }
        lead.start()
        try await Task.sleep(for: .milliseconds(600))
        lead.cancel()
        #expect(released == 1)
    }

    @Test func aPlayerStillOutsideTheOfficeIsWaitedFor() async throws {
        let outside = center(GridCoordinate(row: 5, col: 12))       // up the corridor, not in the office
        let performer = FakePerformer()
        let lead = lead(player: { outside }, performer: performer)
        var released = 0
        lead.onFinalRelease = { released += 1 }
        lead.start()
        try await Task.sleep(for: .milliseconds(600))
        lead.cancel()
        #expect(released == 0)
    }

    @Test func aLeadWhoseBodyLeavesTheSceneReportsItOnce() async throws {
        let performer = FakePerformer()
        let lead = lead(player: { .zero }, performer: performer)
        var lost = 0, released = 0
        lead.onLost = { lost += 1 }
        lead.onFinalRelease = { released += 1 }
        lead.start()
        performer.position = nil                                       // the scene was rebuilt
        try await Task.sleep(for: .milliseconds(600))
        #expect(lost == 1 && released == 0 && !lead.isRunning)
    }

    @Test func noJourneyNeverBlocksTheComputer() {
        GuidedJourney.end()
        #expect(!GuidedJourney.isPerformingInOffice())
    }
}
