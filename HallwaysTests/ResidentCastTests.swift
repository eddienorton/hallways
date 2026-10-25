import Foundation
import Testing
@testable import Hallways

/// Oct 21 (late) -- ONE POPULATION. The meeting's cast (the Mailbox first),
/// Juanita and Tinky are residents: one identity each, a movement policy that
/// is data, and the meeting's hold on the cast (the reservation).
@MainActor
struct ResidentCastTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private var mailbox: CastMember { CastResidents.member("cast.mailbox")! }

    @Test func theMailboxIsOneResidentWithOneIdentity() throws {
        let m = try #require(CastResidents.member("cast.mailbox"))
        #expect(m.actorName == "AuditionMailbox")                         // (the meeting's figure of the same character)
        let identity = try #require(CharacterRegistry.identity(m.id))
        #expect(identity.name == "Mailbox")
        #expect(CharacterRegistry.all.filter { $0.id == m.id }.count == 1)
        // Restricted roaming: never the lobby, Administration, or the meeting's floor.
        guard case .restricted(let floors) = m.policy else { Issue.record("not restricted"); return }
        #expect(!floors.isEmpty)
        #expect(!floors.contains(1) && !floors.contains(2) && !floors.contains(ConferenceRoom.floor))
        // A newcomer: in the lobby, no place yet, arriving later.
        let n = CastResidentKind(m).newcomers(now: t0)
        #expect(n.count == 1 && n[0].floor == ResidentPolicy.lobbyFloor && n[0].cell == nil && n[0].since > t0)
    }

    @Test func heldByTheMeetingItIsInTheConferenceRoomAndStaysPut() {
        var r = Resident(id: mailbox.id, kind: mailbox.id, floor: 6, cell: GridCoordinate(row: 4, col: 4), since: t0, dwell: 30)
        r.leg = ResidentLeg(from: ResidentPlace(floor: 6, cell: GridCoordinate(row: 4, col: 2)), departed: t0)
        CastResidents.hold(&r, now: t0)
        #expect(r.floor == ConferenceRoom.floor)
        #expect(r.cell == CastResidents.meetingCell)
        #expect(ConferenceRoom.roomCells.contains(CastResidents.meetingCell))
        #expect(r.leg == nil && r.why == CastResidents.reservedWhy)
        // Held again later: nothing changes (no save every tick, no second place).
        let before = (r.floor, r.cell, r.since, r.dwell)
        CastResidents.hold(&r, now: t0.addingTimeInterval(500))
        #expect(r.floor == before.0 && r.cell == before.1 && r.since == before.2 && r.dwell == before.3)
    }

    @Test func juanitaAndTinkyAreStationedAndTinkyCanTakeATrip() throws {
        let post = ResidentPlace(floor: 2, cell: GridCoordinate(row: 13, col: 9))
        var trip: ResidentPlace?
        let kind = StationedResidentKind(id: "test.stationed", station: post, duty: "a post", away: { trip })
        guard case .stationed(let p) = kind.policy else { Issue.record("not stationed"); return }
        #expect(p == post)
        var r = try #require(kind.newcomers(now: t0).first)
        #expect(r.floor == 2 && r.cell == post.cell)                     // (at the post from the start: no arrival)
        // Unchanged while it stays put (no save every tick).
        kind.advance(&r, to: t0.addingTimeInterval(10), plans: { _ in nil })
        #expect(r.since == t0)
        // A story trip moves it; when it's over, back at its post.
        trip = ResidentPlace(floor: 3, cell: GridCoordinate(row: 6, col: 13))
        kind.advance(&r, to: t0.addingTimeInterval(20), plans: { _ in nil })
        #expect(r.floor == 3 && r.cell == GridCoordinate(row: 6, col: 13))
        trip = nil
        kind.advance(&r, to: t0.addingTimeInterval(30), plans: { _ in nil })
        #expect(r.floor == 2 && r.cell == post.cell)
        // No roaming body of its own: its scripted scenes are its figure.
        #expect(StationedResidents.kinds.count == 2)
        #expect(Set(StationedResidents.kinds.map { ($0 as? StationedResidentKind)?.id ?? "" })
                == [CharacterRegistry.juanitaID, CharacterRegistry.tinkyID])
    }

    @Test func identitiesAndPlacesSurviveARelaunch() throws {
        let storage = ThrowawayStorage()
        let kinds: [ResidentKind] = [CastResidentKind(mailbox)] + StationedResidents.kinds
        let first = BuildingLife(defaults: storage.defaults, persists: true, kinds: kinds)
        var m = try #require(first.resident(mailbox.id))
        m.floor = 6
        m.cell = GridCoordinate(row: 4, col: 4)
        first.store(m)
        let second = BuildingLife(defaults: storage.defaults, persists: true, kinds: kinds)
        #expect(second.residentIDs == first.residentIDs)
        #expect(Set(second.residentIDs).count == second.residentIDs.count)                     // (one record each)
        let again = try #require(second.resident(mailbox.id))
        #expect(again.floor == 6 && again.cell == GridCoordinate(row: 4, col: 4))
        #expect(second.resident(CharacterRegistry.juanitaID)?.floor == Admission.administrationFloor)
        #expect(second.resident(CharacterRegistry.tinkyID)?.floor == Admission.administrationFloor)
    }

    /// Oct 22: the whole cast -- six independent residents, each the meeting's own
    /// figure (one identity each), on floors 4-7 only, arriving one at a time, each
    /// moving its own way.
    @Test func allSixAreResidentsEachInItsOwnWay() {
        let cast = CastResidents.members
        #expect(cast.count == 6)
        #expect(Set(cast.map(\.actorName)) == ["AuditionTelephone", "AuditionViewMaster2", "AuditionStove",
                                                "AuditionMailbox", "AuditionCamera", "AuditionTelevision"])
        #expect(Set(cast.map(\.id)).count == 6)
        for m in cast {
            #expect(CharacterRegistry.identity(m.id) != nil)
            #expect(CharacterRegistry.all.filter { $0.id == m.id }.count == 1)
            #expect(Set(m.floors.keys).isSubset(of: [4, 5, 6, 7]))                 // (never 1-3: onboarding, the meeting)
            #expect(!m.preview.isEmpty)
        }
        // One at a time, a minute or more apart.
        let arrivals = cast.map(\.arrivalDelay).sorted()
        for (a, b) in zip(arrivals, arrivals.dropFirst()) { #expect(b - a >= 60) }
        // No two get about the same way.
        let gaits = Set(cast.map { "\($0.gait.speed)/\($0.gait.hop)/\($0.gait.roll)" })
        #expect(gaits.count == cast.count)
        // Not a group: different favourite floors.
        let favourites = Set(cast.map { m in m.floors.max { $0.value < $1.value }?.key ?? 0 })
        #expect(favourites.count >= 3)
    }
}
