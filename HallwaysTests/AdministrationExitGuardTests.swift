import Foundation
import SceneKit
import Testing
import simd
@testable import Hallways

/// Oct 9 -- Juanita keeps a new employee in Administration until Tinky has
/// them. Pure rule and geometry checks: nothing here reads or writes the
/// player's saved progress. Simulator only.
@MainActor
@Suite(.serialized)          // the guard is one shared, static state: one test at a time
struct AdministrationExitGuardTests {
    // The rule: only between the ID and Tinky taking over.
    @Test func sheEnforcesOnlyBetweenTheIDAndTinky() {
        #expect(!AdministrationExitGuard.isEnforcing(admitted: false, prologueDone: false, journeyUnderway: false))  // no ID yet: free to leave
        #expect(AdministrationExitGuard.isEnforcing(admitted: true, prologueDone: false, journeyUnderway: false))    // ID, no Tinky: blocked
        #expect(!AdministrationExitGuard.isEnforcing(admitted: true, prologueDone: false, journeyUnderway: true))    // Tinky leading: open
        #expect(!AdministrationExitGuard.isEnforcing(admitted: true, prologueDone: true, journeyUnderway: false))    // onboarded: open
    }

    // Restrained escalation: impatient, impatient, exasperated once, then silent.
    @Test func repeatedTriesEscalateWithRestraint() {
        let r = (1...6).map { AdministrationExitGuard.refusal(forAttempt: $0) }
        #expect(r[0].mood == .impatient && !r[0].silent)
        #expect(r[1].mood == .impatient && !r[1].silent)
        #expect(r[2].mood == .exasperated && !r[2].silent)
        for later in r[3...] { #expect(later.silent) }                                 // no flood of voices
        #expect(r.filter { $0.mood == .exasperated }.count == 1)
    }

    // Oct 9 (voice and gesture): each voiced reaction carries her existing
    // voice with the gesture timed to it; the silent ones are a deliberate
    // wordless point -- no voice, no syllable jabs, no talking head-shake.
    @Test func voicedReactionsSpeakAndSilentOnesDontMime() {
        for n in 1...6 {
            let r = AdministrationExitGuard.refusal(forAttempt: n)
            let g = AdministrationReception.exitReaction(r.mood, silent: r.silent)
            if r.silent {
                #expect(!g.speaks && g.jabs == 0 && !g.talkingNotice, "attempt \(n)")
            } else {
                #expect(g.speaks && g.jabs > 0, "attempt \(n)")
            }
        }
    }

    // Floor 2's Administration cells, just enough for the exit: the elevator
    // nook, the vestibule, the public side of reception and the office.
    private func administration(startCell: GridCoordinate, facing: Direction) -> TapNavigationController {
        var cells: Set<GridCoordinate> = [GridCoordinate(row: 10, col: 6), AdministrationReception.vestibule]
        cells.formUnion(AdministrationExitGuard.receptionCells)
        cells.formUnion(AdministrationExitGuard.retreatCells)
        return TapNavigationController(cameraNode: SCNNode(), scene: SCNScene(), cells: cells, cellSize: 3.52,
                                       startCell: startCell, startFacing: facing, endCell: GridCoordinate(row: 10, col: 6),
                                       roomEntranceDoors: [AdministrationExitGuard.exitDoor: .east])
    }

    // Where she stands closes the exit like a wall -- even with the doors
    // standing open -- and only that boundary.
    @Test func herDoorwayIsClosedToThePlayerEvenWithTheDoorsOpen() {
        let nav = administration(startCell: AdministrationExitGuard.insideCell, facing: .west)
        nav.openRoomEntranceDoor(at: AdministrationExitGuard.exitDoor)
        #expect(nav.openDirections.contains(.west))                                     // doors open normally
        nav.characterBlockedEdges.insert(AdministrationExitGuard.exitEdge)
        #expect(!nav.openDirections.contains(.west))                                    // but she's in the way
        #expect(nav.openDirections.contains(.north) && nav.openDirections.contains(.south))   // never trapped
        // Both sides of the boundary are hers.
        #expect(nav.isBlockedByCharacter(from: AdministrationExitGuard.exitDoor, direction: .east))
        #expect(!nav.isBlockedByCharacter(from: GridCoordinate(row: 9, col: 8), direction: .west))
        nav.characterBlockedEdges.remove(AdministrationExitGuard.exitEdge)
        #expect(nav.openDirections.contains(.west))                                     // she steps aside: open again
    }

    // The free walk can't squeeze past her: from any approach, no legal
    // position reaches her or the doorway behind her.
    @Test func theFreeWalkCannotSqueezePastHer() {
        let s = 3.52
        let nav = administration(startCell: AdministrationExitGuard.insideCell, facing: .west)
        nav.openRoomEntranceDoor(at: AdministrationExitGuard.exitDoor)
        let open = nav.makeFreeWalkGeometry()
        nav.characterBlockedEdges.insert(AdministrationExitGuard.exitEdge)
        let blocked = nav.makeFreeWalkGeometry()
        let boundaryX = (Double(AdministrationExitGuard.insideCell.col) - 0.5) * s
        let spot = AdministrationExitGuard.blockingSpot(cellSize: Float(s))
        let rowZ = Double(AdministrationExitGuard.insideCell.row) * s
        #expect(open.isLegal(x: boundaryX + 0.05, z: rowZ))                                 // doors open, nobody there: walk through
        for dz in stride(from: -1.7, through: 1.7, by: 0.1) {
            for x in stride(from: boundaryX - 1.0, through: Double(spot.x) + 0.2, by: 0.05) {
                #expect(!blocked.isLegal(x: x, z: rowZ + dz), "x \(x) dz \(dz)")
            }
        }
        // ...and the closest anyone gets is still in front of her.
        #expect(Double(spot.x) < boundaryX + FreeWalkGeometry.playerClearance)
    }

    // Oct 9 (conversational distance): with her on guard and the doors OPEN,
    // no free-walk approach -- one tap, rapid repeated taps, a held walk,
    // any angle, aimed at her or far beyond the doorway -- ever brings the
    // camera inside her circle or into the doorway behind her.
    private func guardedNav() -> (TapNavigationController, SIMD2<Double>, Double) {
        let nav = administration(startCell: AdministrationExitGuard.insideCell, facing: .west)
        nav.openRoomEntranceDoor(at: AdministrationExitGuard.exitDoor)
        nav.characterBlockedEdges.insert(AdministrationExitGuard.exitEdge)
        let spot = AdministrationExitGuard.blockingSpot(cellSize: 3.52)
        let r = Double(AdministrationExitGuard.conversationDistance)
        nav.characterKeepOuts = [FreeWalkGeometry.KeepOut(x: Double(spot.x), z: Double(spot.y), radius: r)]
        return (nav, SIMD2<Double>(Double(spot.x), Double(spot.y)), r)
    }

    @Test func noApproachReachesHerOrTheDoorway() {
        let s = 3.52
        let (nav, her, r) = guardedNav()
        #expect(nav.openRoomEntranceDoors.contains(AdministrationExitGuard.exitDoor))  // the doors work as always
        let g = nav.makeFreeWalkGeometry()
        let doorwayX = 7.5 * s
        func check(_ p: SCNVector3, _ label: String) {
            let d = ((Double(p.x) - her.x) * (Double(p.x) - her.x) + (Double(p.z) - her.y) * (Double(p.z) - her.y)).squareRoot()
            #expect(d >= r - 1e-6, "\(label): \(d) m from her")
            #expect(Double(p.x) >= doorwayX + FreeWalkGeometry.playerClearance - 1e-6, "\(label): reached the doorway")
        }
        let starts: [(Double, Double)] = [(9 * s, 10 * s), (8 * s, 9 * s), (8 * s, 11 * s), (9 * s, 9 * s),
                                          (9 * s, 11 * s), (8 * s + 1.4, 10 * s), (8 * s + 1.4, 10 * s - 1.2)]
        let vestibule = (7 * s, 10 * s)
        for (sx, sz) in starts {
            let start = SCNVector3(Float(sx), 1.6, Float(sz))
            #expect(g.isLegal(x: sx, z: sz))
            // Every direction, short and long taps (long = "tap beyond the doorway").
            for a in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 18) {
                for len in [1.0, s, 8.0, 15.0] {
                    check(g.slideEndpoint(from: start, dx: cos(a) * len, dz: sin(a) * len), "tap a=\(a) len=\(len)")
                }
            }
            // Rapid repeated taps aimed through her at the vestibule.
            var p = start
            for i in 0..<12 {
                let dx = vestibule.0 - Double(p.x), dz = vestibule.1 - Double(p.z)
                let d = max((dx * dx + dz * dz).squareRoot(), 1e-6)
                p = g.slideEndpoint(from: p, dx: dx / d * s, dz: dz / d * s)
                check(p, "rapid tap \(i)")
            }
            // A held walk: 400 small steps, angled slightly off her each way.
            for offset in [-0.4, 0.0, 0.4] {
                var q = start
                for i in 0..<400 {
                    let dx = vestibule.0 - Double(q.x), dz = vestibule.1 + offset - Double(q.z)
                    let d = max((dx * dx + dz * dz).squareRoot(), 1e-6)
                    q = g.slideEndpoint(from: q, dx: dx / d * 0.1, dz: dz / d * 0.1)
                    if i % 50 == 0 { check(q, "held offset=\(offset) step \(i)") }
                }
                check(q, "held offset=\(offset) end")
            }
        }
    }

    // She arrived next to someone: they may step away, never closer, never past.
    @Test func startingInsideHerCircleOnlyLetsYouLeave() {
        let s = 3.52
        let (nav, her, _) = guardedNav()
        let g = nav.makeFreeWalkGeometry()
        let start = SCNVector3(Float(8 * s), 1.6, Float(10 * s))                       // the cell centre: 0.81 m from her
        func dist(_ p: SCNVector3) -> Double {
            ((Double(p.x) - her.x) * (Double(p.x) - her.x) + (Double(p.z) - her.y) * (Double(p.z) - her.y)).squareRoot()
        }
        for a in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 12) {
            let end = g.slideEndpoint(from: start, dx: cos(a) * s, dz: sin(a) * s)
            #expect(dist(end) >= dist(start) - 1e-6, "a=\(a)")
            #expect(Double(end.x) >= 7.5 * s + FreeWalkGeometry.playerClearance - 1e-6, "a=\(a)")
        }
    }

    // Tapping the guarded doors composes the player OUTSIDE her circle, still
    // in the entry cell (so the doors still open for them), facing them.
    @Test func facingTheGuardedDoorsStopsAtConversationDistance() {
        let s = 3.52
        let (nav, her, r) = guardedNav()
        let centre = SCNVector3(Float(8 * s), 1.6, Float(10 * s))
        let back = Direction.west.opposite.delta
        let p = nav.pointClearOfCharacters(centre, retreat: (Double(back.col), Double(back.row)))
        let d = ((Double(p.x) - her.x) * (Double(p.x) - her.x) + (Double(p.z) - her.y) * (Double(p.z) - her.y)).squareRoot()
        #expect(d >= r)
        #expect(FreeWalkGeometry.containingCell(x: Double(p.x), z: Double(p.z), cellSize: s) == AdministrationExitGuard.insideCell)
        #expect(abs(p.z - centre.z) < 0.001)
        #expect(nav.makeFreeWalkGeometry().isLegal(x: Double(p.x), z: Double(p.z)))
        // Away from her: unchanged.
        let far = SCNVector3(Float(9 * s), 1.6, Float(10 * s))
        #expect(nav.pointClearOfCharacters(far, retreat: (1, 0)).x == far.x)
    }

    // The camera can never be near enough to enter her: her widest point
    // (pointing arm ~0.95 m from her centre) is well inside the circle.
    @Test func herCircleKeepsTheCameraOutOfHer() {
        #expect(AdministrationExitGuard.conversationDistance >= 1.5)
        #expect(AdministrationExitGuard.personalSpace >= 0.6)
    }

    // Oct 9 (door taps while guarded): a guarded door never opens -- not on
    // a single tap, not on twenty rapid ones -- every try goes to the guard,
    // and the tap is consumed before any glide (the player doesn't move).
    @Test func guardedDoorTapsNeverOpenTheDoors() {
        let nav = administration(startCell: AdministrationExitGuard.insideCell, facing: .west)
        var tries = 0
        nav.roomEntranceDoorGuarded = { $0 == AdministrationExitGuard.exitDoor }
        nav.onGuardedRoomEntranceDoorTap = { _ in tries += 1 }
        for _ in 0..<20 { nav.openRoomEntranceDoor(at: AdministrationExitGuard.exitDoor) }
        #expect(!nav.openRoomEntranceDoors.contains(AdministrationExitGuard.exitDoor))
        #expect(tries == 20)
        // The wall-interaction path (what a tap on the glass resolves to).
        let before = nav.cameraNode.position
        let target = TapNavigationController.WallInteractionTarget(
            kind: TapNavigationController.guardedDoorKind,
            face: WallFace(coord: AdministrationExitGuard.insideCell, direction: .west),
            action: { nav.guardedRoomEntranceDoorTapped(AdministrationExitGuard.exitDoor) })
        for _ in 0..<5 { #expect(nav.composeWallInteraction(target)) }
        #expect(tries == 25)
        #expect(!nav.isFreeTapWalking)                                                // no glide started
        #expect(nav.cameraNode.position.x == before.x && nav.cameraNode.position.z == before.z)
        #expect(!nav.openRoomEntranceDoors.contains(AdministrationExitGuard.exitDoor))
        // Released (Tinky's escort): the very same tap opens them as always.
        nav.roomEntranceDoorGuarded = { _ in false }
        nav.openRoomEntranceDoor(at: AdministrationExitGuard.exitDoor)
        #expect(nav.openRoomEntranceDoors.contains(AdministrationExitGuard.exitDoor))
        #expect(tries == 25)
    }

    // The guard's own state is the one answer: not while she waits beside the
    // doors, yes from her step into the doorway, no once Tinky leads. Tries
    // at the doors are attempts to leave -- the existing sequence, with its
    // cooldown (rapid tries count once) and never reset by repetition.
    @Test func theGuardStateDecidesTheDoorsAndTriesEscalate() {
        let root = SCNNode()
        let juanita = SCNNode()
        root.addChildNode(juanita)
        var closes = 0
        AdministrationExitGuard.install(standIn: juanita, cellSize: 3.52)
        AdministrationExitGuard.setExitBlocked = { if $0 { closes += 1 } }
        defer { AdministrationExitGuard.setExitBlocked = nil }
        let door = AdministrationExitGuard.exitDoor

        #expect(!AdministrationExitGuard.guardsDoor(door))                          // at her desk
        AdministrationExitGuard.photoAccepted(admitted: false, prologueDone: false)
        AdministrationExitGuard.finishWalkForTesting()
        if AdministrationExitGuard.post == .standingBy {
            #expect(!AdministrationExitGuard.guardsDoor(door))                      // beside the doors: normal
        }
        AdministrationExitGuard.visitorAdmitted(enforcing: true)
        AdministrationExitGuard.finishWalkForTesting()
        #expect(AdministrationExitGuard.post == .blocking)
        #expect(AdministrationExitGuard.guardsDoor(door))                            // on guard
        #expect(!AdministrationExitGuard.guardsDoor(GridCoordinate(row: 11, col: 9))) // only her doors
        #expect(closes == 1)                                                        // she pulls them to once

        let before = AdministrationExitGuard.attempts
        for _ in 0..<10 { AdministrationExitGuard.doorTried() }                     // rapid tries
        #expect(AdministrationExitGuard.attempts == before + 1)                    // cooldown: one reaction
        #expect(AdministrationExitGuard.refusal(forAttempt: AdministrationExitGuard.attempts).mood == .impatient)

        AdministrationExitGuard.release(reason: "Tinky is leading")
        #expect(!AdministrationExitGuard.guardsDoor(door))                          // doors normal again
        AdministrationExitGuard.doorTried()
        #expect(AdministrationExitGuard.attempts == before + 1)                    // no reactions off duty
    }

    // She stands clear of the glass leaves' swing (0.95 m each, into the room,
    // hinged at the jambs), facing the room, in the doorway's centre.
    @Test func sheStandsClearOfTheDoorLeaves() {
        let s: Float = 3.52
        let spot = AdministrationExitGuard.blockingSpot(cellSize: s)
        let boundaryX = (Float(AdministrationExitGuard.insideCell.col) - 0.5) * s
        let rowZ = Float(AdministrationExitGuard.insideCell.row) * s
        #expect(abs(spot.y - rowZ) < 0.01)
        let leaf: Float = 0.95, bodyRadius: Float = 0.25
        for side: Float in [-1, 1] {
            let hinge = SIMD2<Float>(boundaryX, rowZ + side * leaf)
            #expect(simd_distance(hinge, spot) > leaf + bodyRadius)
        }
        #expect(spot.x > boundaryX)                                                     // inside the room
    }

    // Where the visitor is decides where she is: reception = keep the exit;
    // the anteroom or the office = she may go back. Never both.
    @Test func receptionAndTinkysOfficeAreDistinct() {
        #expect(AdministrationExitGuard.receptionCells.contains(AdministrationExitGuard.insideCell))
        #expect(AdministrationExitGuard.receptionCells.contains(AdministrationReception.deskLanding.coord))
        #expect(AdministrationExitGuard.receptionCells.isDisjoint(with: AdministrationReception.staffCells))
        #expect(!AdministrationExitGuard.receptionCells.contains(AdministrationReception.vestibule))
        #expect(AdministrationExitGuard.retreatCells.contains(AdministrationReception.officeAnteroom))
        #expect(AdministrationExitGuard.receptionCells.isDisjoint(with: AdministrationExitGuard.retreatCells))
    }

    // Oct 9 (no loophole): only the story releases her. Going into Tinky's
    // anteroom or office, turning straight round, or staying there a while
    // never opens the exit; the escort beginning (enforcing == false, as when
    // GuidedJourney.trip is set) does, at once -- no invisible wall left.
    // The `enforcing` argument stands in for the saved story state, which
    // this test never reads or writes.
    @Test func onlyTinkysEscortReleasesTheExit() async throws {
        let root = SCNNode()
        let juanita = SCNNode()
        root.addChildNode(juanita)
        var blocked: [Bool] = []
        AdministrationExitGuard.install(standIn: juanita, cellSize: 3.52)
        AdministrationExitGuard.setExitBlocked = { blocked.append($0) }
        defer { AdministrationExitGuard.setExitBlocked = nil }

        // Photo accepted: she comes out to stand BESIDE the doorway --
        // nothing is closed while she walks or while she stands by.
        AdministrationExitGuard.photoAccepted(admitted: false, prologueDone: false)
        #expect(AdministrationExitGuard.isAway)
        #expect(!AdministrationExitGuard.isExitBlocked)
        AdministrationExitGuard.finishWalkForTesting()
        if AdministrationExitGuard.post == .standingBy {
            #expect(!AdministrationExitGuard.isExitBlocked)
        }
        // The card is taken: she steps in, and the doorway is hers.
        AdministrationExitGuard.visitorAdmitted(enforcing: true)
        #expect(AdministrationExitGuard.isExitBlocked)
        #expect(AdministrationExitGuard.keepOut?.radius == AdministrationExitGuard.conversationDistance)
        AdministrationExitGuard.finishWalkForTesting()
        #expect(AdministrationExitGuard.post == .blocking)

        // Into Tinky's anteroom and office, then straight back out.
        AdministrationExitGuard.playerCellChanged(GridCoordinate(row: 11, col: 9), enforcing: true)
        AdministrationExitGuard.playerCellChanged(AdministrationReception.officeAnteroom, enforcing: true)
        for office in AdministrationReception.officeCells {
            AdministrationExitGuard.playerCellChanged(office, enforcing: true)
        }
        #expect(AdministrationExitGuard.isExitBlocked)
        // ...and a wait longer than the old 2-second "she goes back" delay.
        try await Task.sleep(for: .seconds(2.5))
        #expect(AdministrationExitGuard.isExitBlocked)
        AdministrationExitGuard.playerCellChanged(AdministrationReception.officeAnteroom, enforcing: true)
        AdministrationExitGuard.playerCellChanged(AdministrationExitGuard.insideCell, enforcing: true)
        #expect(AdministrationExitGuard.isExitBlocked)                               // still there on the way out
        #expect(!blocked.contains(false))                                            // never opened, not even briefly

        // Tinky's escort begins: she steps away and the exit opens at once.
        AdministrationExitGuard.release(reason: "Tinky is leading")
        #expect(!AdministrationExitGuard.isExitBlocked)
        #expect(AdministrationExitGuard.keepOut == nil)                              // nothing left behind
        #expect(blocked.last == false)
        // While he leads, the visitor's moves never call her back out.
        AdministrationExitGuard.playerCellChanged(GridCoordinate(row: 11, col: 9), enforcing: false)
        AdministrationExitGuard.playerCellChanged(AdministrationExitGuard.insideCell, enforcing: false)
        #expect(!AdministrationExitGuard.isExitBlocked)
    }

    // Oct 9 (Juanita 2.0): before the ID she only stands by. A visitor who
    // leaves without their card is free to go, and she goes back to work.
    @Test func withoutTheCardTheExitStaysOpen() {
        let root = SCNNode()
        let juanita = SCNNode()
        root.addChildNode(juanita)
        AdministrationExitGuard.install(standIn: juanita, cellSize: 3.52)
        AdministrationExitGuard.photoAccepted(admitted: false, prologueDone: false)
        AdministrationExitGuard.playerCellChanged(AdministrationExitGuard.insideCell, enforcing: false, admitted: false)
        #expect(!AdministrationExitGuard.isExitBlocked)
        AdministrationExitGuard.playerCellChanged(AdministrationReception.vestibule, enforcing: false, admitted: false)
        #expect(!AdministrationExitGuard.isExitBlocked)
        #expect(AdministrationExitGuard.post == .goingBack)
        // A returning employee (card already taken) never gets her stand-by.
        AdministrationExitGuard.install(standIn: juanita, cellSize: 3.52)
        AdministrationExitGuard.photoAccepted(admitted: true, prologueDone: false)
        #expect(AdministrationExitGuard.post == .atDesk)
    }

    // Her walk: out round the counter's END (never through it), and she
    // ends in the doorway, between the room and the doors.
    @Test func herRouteGoesRoundTheCounterIntoTheDoorway() {
        let s: Float = 3.52
        let desk = SIMD2<Float>((Float(AdministrationReception.publicCol) + 0.5) * s + 0.6, Float(AdministrationReception.counterRow) * s)
        let path = AdministrationExitGuard.route(cellSize: s, desk: desk)
        let counterZ = Float(AdministrationReception.counterRow) * s
        // Leaving the staff side happens beyond the counter's north end.
        #expect(abs(path[1].y - counterZ) > 1.7)
        #expect(abs(path[2].y - counterZ) > 1.7)
        // She ends where she blocks: the doorway, inside the room.
        let end = path[path.count - 1]
        #expect(end == AdministrationExitGuard.blockingSpot(cellSize: s))
        let doorX = (Float(AdministrationReception.vestibule.col) + 0.5) * s
        let visitor = SIMD2<Float>(Float(AdministrationExitGuard.insideCell.col) * s, Float(AdministrationExitGuard.insideCell.row) * s)
        #expect(end.x > doorX && end.x < visitor.x)
        // Her approach comes down the north side, never through the cell's centre.
        #expect(path[path.count - 2].y < visitor.y - 1.0)
    }
}
