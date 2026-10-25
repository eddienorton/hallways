import Foundation
import SceneKit
import Testing
import simd
@testable import Hallways

/// Oct 19 -- THE SIX HALLWAYSIANS as residents: six configurations of one
/// species (one builder, one rig), registered with the building's life,
/// listed in Contacts, saved and resumed like everyone else -- and the
/// resident walk that no longer cuts through walls at junctions.
@MainActor
struct HallwaysianResidentTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func g(_ r: Int, _ c: Int) -> GridCoordinate { GridCoordinate(row: r, col: c) }

    /// The body's extent from its geometry (the contact shadow aside).
    private func bounds(_ root: SCNNode) -> (SIMD3<Float>, SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        root.enumerateHierarchy { node, _ in
            guard let geo = node.geometry, node.name != "hwContactShadow" else { return }
            let (a, b) = geo.boundingBox
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let p = root.simdConvertPosition(node.simdConvertPosition(SIMD3(x, y, z), to: nil), from: nil)
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            } } }
        }
        return (lo, hi)
    }

    // MARK: Six of one species

    @Test func sixPeopleOneSpecies() throws {
        let cast = HallwaysianCast.all
        #expect(cast.map(\.name) == ["Feddy", "Sister", "Big Fellow", "Old Gent", "Lanky", "Tiny",
                                      "Barrel", "Owl", "Auntie", "Pear", "Mitts",       // (Oct 19: the five newcomers, appended)
                                      "Stilts", "Clunk", "Topper", "Scope", "Lopsy"])   // (Oct 19: five more -- sixteen)
        #expect(Set(cast.map(\.id)).count == 16)
        // The same rig, every joint, in every one of them.
        let joints = ["hwPelvis", "hwTorso", "hwNeck", "hwHead", "hwFace", "hwEyeL", "hwEyeR", "hwLidUpperL", "hwLidLowerR",
                      "hwMouth", "hwShoulderL", "hwElbowR", "hwWristL", "hwHipR", "hwKneeL", "hwAnkleR"]
        var extents: [String: (SIMD3<Float>, SIMD3<Float>)] = [:]
        for p in cast {
            let body = HallwaysianBody(genome: p.genome)
            for j in joints { #expect(body.root.childNode(withName: j, recursively: true) != nil, "\(p.name) \(j)") }
            #expect(body.root.childNode(withName: "hwGauge", recursively: true) == nil, "\(p.name): no chest gauge")
            let (lo, hi) = bounds(body.root)
            #expect(abs(lo.y) < 0.015, "\(p.name) stands on the floor")
            #expect(abs(hi.y - p.genome.height) < 0.12, "\(p.name) is as tall as his genome says")
            extents[p.name] = (lo, hi)
        }
        // Different silhouettes: heights in the lineup's order, the Big Fellow the widest.
        func height(_ n: String) -> Float { extents[n]!.1.y }
        func width(_ n: String) -> Float { extents[n]!.1.x - extents[n]!.0.x }
        #expect(height("Tiny") < height("Big Fellow"))
        #expect(height("Big Fellow") < height("Feddy"))
        #expect(height("Feddy") < height("Sister"))
        #expect(height("Sister") < height("Lanky"))
        #expect(height("Lanky") > 1.4)
        for n in ["Feddy", "Sister", "Old Gent", "Lanky", "Tiny"] { #expect(width("Big Fellow") > width(n)) }
    }

    /// Oct 19: the five newcomers are five SHAPES, not five paint jobs.
    @Test func theFiveNewcomersAreFiveSilhouettes() throws {
        var extents: [String: (SIMD3<Float>, SIMD3<Float>)] = [:]
        for p in HallwaysianCast.all { extents[p.name] = bounds(HallwaysianBody(genome: p.genome).root) }
        func height(_ n: String) -> Float { extents[n]!.1.y }
        func width(_ n: String) -> Float { extents[n]!.1.x - extents[n]!.0.x }
        let names = HallwaysianCast.all.map(\.name)
        func g(_ n: String) -> HallwaysianGenome { HallwaysianCast.all.first { $0.name == n }!.genome }
        // Barrel: short and very wide -- the widest of all, and wider for its height than anyone.
        for n in names where n != "Barrel" {
            #expect(width("Barrel") > width(n), "Barrel wider than \(n)")
            #expect(width("Barrel") / height("Barrel") > width(n) / height(n), "Barrel squatter than \(n)")
        }
        // Owl: tall, the biggest head and the biggest eyes of all.
        #expect(height("Owl") > height("Feddy"))
        for n in names where n != "Owl" {
            #expect(g("Owl").headRadii.x > g(n).headRadii.x && g("Owl").eyeRadius > g(n).eyeRadius, "Owl vs \(n)")
        }
        // Auntie: small and the most stooped.
        #expect(height("Auntie") < height("Big Fellow") && height("Auntie") < height("Feddy"))
        for n in names where n != "Auntie" { #expect(g("Auntie").torsoLean > g(n).torsoLean, "Auntie vs \(n)") }
        // Pear: a bottom far wider than the shoulders, and the shortest arms for her height.
        let pear = g("Pear")
        let bottom = try #require(pear.torsoPieces.first)
        #expect(bottom.centre.y < 0 && bottom.radii.x * pear.torsoRadii.x > 1.8 * pear.shoulderWidth)
        func reach(_ n: String) -> Float { (g(n).upperArm + g(n).forearm) / g(n).height }
        for n in names where n != "Pear" { #expect(reach("Pear") < reach(n), "Pear's arms vs \(n)") }
        // Mitts: shoulders far wider than the waist, big hands and the longest arms for his height.
        let mitts = g("Mitts")
        #expect(mitts.shoulderWidth > 2.2 * mitts.torsoRadii.x)
        #expect(mitts.handRadius > 1.8 * HallwaysianGenome.feddy.handRadius)
        for n in names where n != "Mitts" { #expect(reach("Mitts") > reach(n), "Mitts vs \(n)") }
        // Their extra body pieces are built (data, the one builder).
        for n in ["Barrel", "Pear", "Mitts"] {
            let body = HallwaysianBody(genome: g(n))
            let pieces = try #require(body.root.childNode(withName: "hwTorsoPieces", recursively: true), "\(n)")
            #expect(pieces.childNodes.count == g(n).torsoPieces.count)
        }
        #expect(HallwaysianBody(genome: g("Feddy")).root.childNode(withName: "hwTorsoPieces", recursively: true) == nil)
        // Five different paints.
        let paints = Set(HallwaysianCast.all.map { p -> String in
            var r: CGFloat = 0, gg: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            p.genome.enamel.getRed(&r, green: &gg, blue: &b, alpha: &a)
            return "\(Int(r * 20)),\(Int(gg * 20)),\(Int(b * 20))"
        })
        #expect(paints.count == HallwaysianCast.all.count)
    }

    /// Oct 19 (five more): Stilts, Clunk, Topper, Scope and Lopsy -- five more SHAPES.
    @Test func fiveMoreAreFiveMoreSilhouettes() throws {
        var extents: [String: (SIMD3<Float>, SIMD3<Float>)] = [:]
        var bodies: [String: HallwaysianBody] = [:]
        for p in HallwaysianCast.all {
            let b = HallwaysianBody(genome: p.genome)
            bodies[p.name] = b
            extents[p.name] = bounds(b.root)
        }
        func height(_ n: String) -> Float { extents[n]!.1.y }
        func g(_ n: String) -> HallwaysianGenome { HallwaysianCast.all.first { $0.name == n }!.genome }
        let names = HallwaysianCast.all.map(\.name)
        // Stilts: the tallest of all, with the smallest head for its height.
        for n in names where n != "Stilts" {
            #expect(height("Stilts") > height(n), "Stilts taller than \(n)")
            #expect(g("Stilts").headRadii.y / height("Stilts") < g(n).headRadii.y / height(n), "Stilts' head vs \(n)")
        }
        // Clunk: round (a ball), short, and the biggest hands of anyone.
        let clunk = g("Clunk")
        #expect(clunk.torsoRadii.max() / clunk.torsoRadii.min() < 1.1)
        #expect(height("Clunk") < height("Feddy"))
        for n in names where n != "Clunk" { #expect(clunk.handRadius > g(n).handRadius, "Clunk's hands vs \(n)") }
        // Topper: a chest far wider than the hips, and the smallest feet in the building.
        let topper = g("Topper")
        let chest = try #require(topper.torsoPieces.first)
        #expect(chest.centre.y > 0 && chest.radii.x * topper.torsoRadii.x > 4 * topper.hipWidth)
        for n in names where n != "Topper" { #expect(topper.footLength < g(n).footLength, "Topper's feet vs \(n)") }
        // Scope: the most neck for its height, and the widest-set eyes.
        func neckShare(_ n: String) -> Float { g(n).neckLength / g(n).height }
        for n in names where n != "Scope" {
            #expect(neckShare("Scope") > neckShare(n), "Scope's neck vs \(n)")
            #expect(g("Scope").eyeSpacing > g(n).eyeSpacing, "Scope's eyes vs \(n)")
        }
        // Lopsy: the only lopsided one -- the shoulders built at different heights, one eye bigger.
        for n in names {
            let b = bodies[n]!
            let l = try #require(b.root.childNode(withName: "hwShoulderL", recursively: true))
            let r = try #require(b.root.childNode(withName: "hwShoulderR", recursively: true))
            let le = try #require(b.root.childNode(withName: "hwEyeballL", recursively: true)?.childNodes.first?.geometry as? SCNSphere)
            let re = try #require(b.root.childNode(withName: "hwEyeballR", recursively: true)?.childNodes.first?.geometry as? SCNSphere)
            if n == "Lopsy" {
                #expect(l.position.y - r.position.y > 0.03)
                #expect(le.radius > re.radius * 1.5)
            } else {
                #expect(abs(l.position.y - r.position.y) < 1e-5, "\(n) level")
                #expect(abs(le.radius - re.radius) < 1e-6, "\(n) matched eyes")
            }
        }
    }

    @Test func featuresAreDataAndGoWhereAsked() throws {
        func has(_ p: HallwaysianPersona, _ name: String) -> Bool {
            HallwaysianBody(genome: p.genome).root.childNode(withName: name, recursively: true) != nil
        }
        let sister = HallwaysianCast.sister, gent = HallwaysianCast.oldGent, feddy = HallwaysianCast.feddy
        #expect(has(sister, "hwHair") && has(sister, "hwSkirt"))
        #expect(!has(sister, "hwMoustache"))
        #expect(has(gent, "hwHair") && has(gent, "hwMoustache") && has(gent, "hwBrowL") && has(gent, "hwBrowR"))
        #expect(!has(feddy, "hwHair") && !has(feddy, "hwSkirt"))
        // One style, any head: the bob on Feddy's head is the same pieces, scaled by his head.
        var bobbed = HallwaysianGenome.feddy
        bobbed.hair = HallwaysianStyle.bob
        let body = HallwaysianBody(genome: bobbed)
        let hair = try #require(body.root.childNode(withName: "hwHair", recursively: true))
        #expect(hair.childNodes.count == HallwaysianStyle.bob.count)
        let shell = hair.childNodes[0]
        #expect(abs(shell.simdScale.x - HallwaysianStyle.bob[0].radii.x * bobbed.headRadii.x) < 1e-5)
        // The skirt hangs from the waist, below the torso's middle, above the knees.
        let skirt = try #require(HallwaysianBody(genome: sister.genome).root.childNode(withName: "hwSkirt", recursively: true))
        #expect(skirt.simdPosition.y < sister.genome.torsoRadii.y * 0.92)
    }

    @Test func everyoneWalksOnTheSameMotor() {
        for p in HallwaysianCast.all {
            var m = HallwaysianMotor(genome: p.genome)
            m.place(x: 0, z: 0, yaw: 0)
            m.walk(to: SIMD2(0, -1.5))
            var o = HallwaysianOverlay()
            o.targets = p.posture
            for _ in 0..<(60 * 12) { _ = m.update(dt: 1.0 / 60, overlay: o, camera: SIMD3(0, 1.5, 3)) }
            #expect(abs(m.pose[.z] + 1.5) < 0.05, "\(p.name) got there")
            #expect(m.pose.values.allSatisfy { $0.isFinite })
            // ...and stop() stops him where he is, with no drift on.
            m.walk(to: SIMD2(0, -4))
            for _ in 0..<30 { _ = m.update(dt: 1.0 / 60, overlay: o, camera: SIMD3(0, 1.5, 3)) }
            m.stop()
            let z = m.pose[.z]
            for _ in 0..<60 { _ = m.update(dt: 1.0 / 60, overlay: o, camera: SIMD3(0, 1.5, 3)) }
            #expect(abs(m.pose[.z] - z) < 0.01, "\(p.name) stopped")
        }
        // Different paces.
        let paces = HallwaysianCast.all.map(\.pace)
        #expect(Set(paces.map { Int($0 * 100) }).count == paces.count)
    }

    // MARK: Residents

    @Test func theyAreResidentsLikeEveryoneElse() throws {
        let kinds = HallwaysianCast.kinds
        #expect(Set(kinds.map(\.kind)).count == 16)
        for k in kinds {
            #expect(k.abilities == [.walk, .rideElevator])
            let n = k.newcomers(now: t0)
            #expect(n.count == 1)
            #expect(n[0].floor == ResidentPolicy.lobbyFloor && n[0].cell == nil)        // (in at the lobby entrance)
            #expect(!ResidentRoster.retiredIDs.contains(n[0].id))
            #expect(ResidentRoster.profile(n[0].id) == nil)                              // (not a Menagerie resident)
        }
        // Never Floor 2, the lobby or Floor 3 by preference.
        for p in HallwaysianCast.all {
            #expect(p.floors[1] == nil && p.floors[2] == nil && p.floors[3] == nil)
        }
        // One at a time: their arrivals, the chair's and the Pottle's are all at least 30 s apart.
        let arrivals = [ResidentRoster.arrivalDelay(order: 0), ResidentRoster.arrivalDelay(order: 1)] + HallwaysianCast.all.map(\.arrivalDelay)
        let sorted = arrivals.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) { #expect(b - a >= 30) }
    }

    @Test func aNewHallwaysianWaitsForTheBuildingToOpen() throws {
        let p = HallwaysianCast.tiny
        var r = try #require(HallwaysianResidentKind(p).newcomers(now: t0).first)
        #expect(ResidentRoster.holdArrival(&r, delay: p.arrivalDelay, open: false, now: t0))
        #expect(r.since >= ResidentRoster.notYet)
        let opened = t0.addingTimeInterval(900)
        #expect(!ResidentRoster.holdArrival(&r, delay: p.arrivalDelay, open: true, now: opened))
        #expect(r.since == opened.addingTimeInterval(p.arrivalDelay))
    }

    /// Oct 19 (later): an existing save (building open) gets them at the front door
    /// soon -- one every 30 s from 30 s after load -- not minutes later.
    @Test func anExistingSaveGetsThemAtTheFrontDoorSoon() {
        let delays = HallwaysianCast.all.map(\.joinDelay)
        #expect(delays == [30, 60, 90, 120, 150, 180,             // (the six: unchanged)
                           45, 75, 105, 135, 165,                 // (Oct 19: the five, in between)
                           38, 68, 98, 128, 158])                 // (Oct 19: five more, in between again)
        #expect(Set(delays).count == delays.count)
        for k in HallwaysianCast.kinds {
            let r = k.newcomers(now: t0)[0]
            #expect(r.floor == ResidentPolicy.lobbyFloor && r.cell == nil)
            #expect(r.since.timeIntervalSince(t0) <= 180)
        }
    }

    /// A save the first build had already scattered them in: once, they go back
    /// to the street to come in at the front door shortly; never again after that.
    @Test func aSaveThatAlreadyHadThemGetsTheirArrivalOnce() throws {
        let storage = ThrowawayStorage()
        var scattered = Resident(id: "hw.tiny", kind: "hallwaysian.hw.tiny", floor: 11, cell: g(9, 4), since: t0, dwell: 200)
        scattered.moves = 7
        let chair = try #require(RoamingChairKind().newcomers(now: t0).first)
        storage.defaults.set(try JSONEncoder().encode([chair, scattered]), forKey: BuildingLife.storageKey)
        let life = BuildingLife(defaults: storage.defaults, persists: true, kinds: [RoamingChairKind()] + HallwaysianCast.kinds)
        let tiny = try #require(life.resident("hw.tiny"))
        #expect(tiny.floor == ResidentPolicy.lobbyFloor && tiny.cell == nil && tiny.leg == nil)
        #expect(tiny.moves == 7)
        #expect(life.resident(chair.id)?.since == chair.since)                     // (nobody else touched)
        #expect(Set(life.residentIDs) == Set([chair.id] + HallwaysianCast.ids))
        #expect(storage.defaults.bool(forKey: HallwaysianCast.frontDoorArrivalKey))
        // Placed somewhere again, then reloaded: left where it is this time.
        var placed = tiny
        placed.floor = 8; placed.cell = g(10, 6); placed.since = t0; placed.dwell = 60
        life.store(placed)
        let again = BuildingLife(defaults: storage.defaults, persists: true, kinds: [RoamingChairKind()] + HallwaysianCast.kinds)
        #expect(again.resident("hw.tiny")?.floor == 8)
    }

    /// Oct 19: a save that already has the six (their front-door arrival long
    /// done) gets the five newcomers -- once, at the front door, soon -- and the
    /// six, the chair and everyone else are left exactly as they were. A reload
    /// adds nobody twice.
    @Test func anExistingSaveGetsTheFiveNewcomersOnce() throws {
        let storage = ThrowawayStorage()
        storage.defaults.set(true, forKey: HallwaysianCast.frontDoorArrivalKey)            // (that arrival already happened)
        let later = Date().addingTimeInterval(7200)                                        // (nobody due to move during the test)
        var saved: [Resident] = [try #require(RoamingChairKind().newcomers(now: t0).first)]
        for (i, p) in HallwaysianCast.all.prefix(HallwaysianCast.originalSix).enumerated() {
            var r = Resident(id: p.id, kind: p.kind, floor: 4 + i, cell: g(3, 3 + i), since: later, dwell: 7200)
            r.moves = 10 + i
            saved.append(r)
        }
        storage.defaults.set(try JSONEncoder().encode(saved), forKey: BuildingLife.storageKey)
        let before = Date()
        let life = BuildingLife(defaults: storage.defaults, persists: true, kinds: [RoamingChairKind()] + HallwaysianCast.kinds)
        #expect(Set(life.residentIDs) == Set([saved[0].id] + HallwaysianCast.ids))
        #expect(life.residentIDs.count == 1 + HallwaysianCast.all.count)
        for r in saved.dropFirst() {                                                       // (the six: untouched)
            let now = try #require(life.resident(r.id))
            #expect(now.floor == r.floor && now.cell == r.cell && now.moves == r.moves, "\(r.id)")
        }
        let newcomers = HallwaysianCast.all.dropFirst(HallwaysianCast.originalSix)
        #expect(newcomers.map(\.name) == ["Barrel", "Owl", "Auntie", "Pear", "Mitts", "Stilts", "Clunk", "Topper", "Scope", "Lopsy"])
        var times: [String: Date] = [:]
        for p in newcomers {
            let r = try #require(life.resident(p.id))
            #expect(r.floor == ResidentPolicy.lobbyFloor && r.cell == nil && r.leg == nil, "\(p.name) comes in at the front door")
            let wait = r.since.timeIntervalSince(before)
            #expect(wait > 30 && wait < 200, "\(p.name) soon (\(wait) s)")
            times[p.id] = r.since
        }
        // Reloaded: the same eleven, the newcomers' arrival times as they were.
        let again = BuildingLife(defaults: storage.defaults, persists: true, kinds: [RoamingChairKind()] + HallwaysianCast.kinds)
        #expect(again.residentIDs.count == 1 + HallwaysianCast.all.count)
        #expect(Set(again.residentIDs).count == again.residentIDs.count)
        for p in newcomers { #expect(again.resident(p.id)?.since == times[p.id], "\(p.name) scheduled once") }
    }

    /// Oct 19 (five more): a save that already has eleven gets just the latest
    /// five -- at the front door, soon, once -- and the eleven stay as they were.
    @Test func aSaveWithElevenGetsTheLatestFiveOnce() throws {
        let storage = ThrowawayStorage()
        storage.defaults.set(true, forKey: HallwaysianCast.frontDoorArrivalKey)
        let later = Date().addingTimeInterval(7200)
        var saved: [Resident] = []
        for (i, p) in HallwaysianCast.all.prefix(11).enumerated() {
            var r = Resident(id: p.id, kind: p.kind, floor: 4 + i % 10, cell: g(3, 3 + i), since: later, dwell: 7200)
            r.moves = 20 + i
            saved.append(r)
        }
        storage.defaults.set(try JSONEncoder().encode(saved), forKey: BuildingLife.storageKey)
        let before = Date()
        let life = BuildingLife(defaults: storage.defaults, persists: true, kinds: HallwaysianCast.kinds)
        #expect(Set(life.residentIDs) == Set(HallwaysianCast.ids))
        #expect(life.residentIDs.count == 16)
        for r in saved {
            let now = try #require(life.resident(r.id))
            #expect(now.floor == r.floor && now.cell == r.cell && now.moves == r.moves, "\(r.id) untouched")
        }
        let latest = HallwaysianCast.all.dropFirst(11)
        #expect(latest.map(\.name) == ["Stilts", "Clunk", "Topper", "Scope", "Lopsy"])
        var times: [String: Date] = [:]
        for p in latest {
            let r = try #require(life.resident(p.id))
            #expect(r.floor == ResidentPolicy.lobbyFloor && r.cell == nil && r.leg == nil, "\(p.name) at the front door")
            let wait = r.since.timeIntervalSince(before)
            #expect(wait > 30 && wait < 200, "\(p.name) soon (\(wait) s)")
            times[p.id] = r.since
        }
        let again = BuildingLife(defaults: storage.defaults, persists: true, kinds: HallwaysianCast.kinds)
        #expect(again.residentIDs.count == 16)
        for p in latest { #expect(again.resident(p.id)?.since == times[p.id], "\(p.name) scheduled once") }
    }

    @Test func theyAreSavedAndComeBack() throws {
        let storage = ThrowawayStorage()
        let first = BuildingLife(defaults: storage.defaults, persists: true, kinds: HallwaysianCast.kinds)
        #expect(Set(first.residentIDs) == Set(HallwaysianCast.ids))
        var moved = try #require(first.resident("hw.lanky"))
        moved.floor = 7
        moved.cell = g(10, 6)
        moved.since = t0
        moved.dwell = 60
        first.store(moved)
        let second = BuildingLife(defaults: storage.defaults, persists: true, kinds: HallwaysianCast.kinds)
        #expect(Set(second.residentIDs) == Set(HallwaysianCast.ids))
        let back = try #require(second.resident("hw.lanky"))
        #expect(back.floor == 7 && back.cell == g(10, 6) && back.kind == "hallwaysian.hw.lanky")
    }

    @Test func theyAreInContactsUnderTheirOwnNames() throws {
        for p in HallwaysianCast.all {
            let c = try #require(CharacterRegistry.identity(p.id))
            #expect(c.name == p.name)
            #expect(!c.metByEventOnly)                            // (met the usual way: near the player)
            #expect(c.preview.count == 1)
        }
        #expect(Set(CharacterRegistry.all.map(\.id)).count == CharacterRegistry.all.count)   // (no duplicates)
        let storage = ThrowawayStorage()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("contacts-\(UUID().uuidString)")
        let contacts = ContactsStore(defaults: storage.defaults, persists: false, portraitDirectory: dir)
        #expect(contacts.meet("hw.oldgent"))
        #expect(contacts.contacts.map(\.name) == ["Old Gent"])
        #expect(!contacts.meet("hw.oldgent"))
    }

    // MARK: Walls (Oct 19)

    private func context(_ cells: Set<GridCoordinate>) -> CharacterLead.Context {
        CharacterLead.Context(cells: cells, doors: [:], cellSize: 3.52, playerPose: { nil }, isDoorOpen: { _ in false }, openDoor: { _ in })
    }

    /// The walk's points from a plan (as RoamPresentation keeps them: travel only).
    private func walked(_ steps: [CharacterLead.Step], from start: SIMD2<Float>) -> [SIMD2<Float>] {
        var pts = [start]
        for step in steps { if case .travel(let p) = step { pts += p } }
        return pts
    }

    /// A T-junction: a corridor along row 5, a stub north at col 6 (so (5,6) is a
    /// junction), the branch south down col 6. The walk turns south at the junction.
    @Test func aJunctionTurnNoLongerCutsThroughTheWall() {
        var cells = Set((0...8).map { g(5, $0) })
        cells.formUnion((6...9).map { g($0, 6) })
        cells.insert(g(4, 6))
        let route = (1...6).map { g(5, $0) } + (6...9).map { g($0, 6) }
        let ctx = context(cells)
        let start = SIMD2<Float>(1 * 3.52, 5 * 3.52)
        // Before: a junction turn became a waiting stop; dropped, the walk went diagonally through the wall.
        let before = CharacterLead.plan(route: route, context: ctx).filter { step in
            if case .stop(let s) = step { return s.isFinal }
            return true
        }
        #expect(CharacterLead.firstPointOffCells(walked(before, from: start), cells: cells, cellSize: 3.52) != nil)
        // Now: every corner at the cell's centre -- never off the walkable cells.
        let now = CharacterLead.plan(route: route, context: ctx, turnAtCentres: true)
        #expect(CharacterLead.firstPointOffCells(walked(now, from: start), cells: cells, cellSize: 3.52) == nil)
        // (The guides' plan is untouched: by default the junction is still a stop.)
        #expect(CharacterLead.plan(route: route, context: ctx).contains { step in
            if case .stop(let s) = step { return !s.isFinal }
            return false
        })
    }

    /// Every route a walker could take on a small floor of corridors and turns
    /// stays on walkable cells, junction or not.
    @Test func everyRouteOnAFloorStaysOnItsCells() {
        // A ring with spurs: rows 2 and 8, cols 2 and 10, and spurs at (5,6)-(2..8,6).
        var cells = Set<GridCoordinate>()
        for c in 2...10 { cells.insert(g(2, c)); cells.insert(g(8, c)) }
        for r in 2...8 { cells.insert(g(r, 2)); cells.insert(g(r, 10)); cells.insert(g(r, 6)) }
        cells.insert(g(5, 1)); cells.insert(g(5, 11)); cells.insert(g(1, 6))
        let ctx = context(cells)
        let list = cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        var checked = 0
        for a in list { for b in list where a != b {
            guard let route = CharacterLead.route(from: a, to: b, cells: cells, doors: [:]), route.count >= 2 else { continue }
            let steps = CharacterLead.plan(route: route, context: ctx, turnAtCentres: true)
            let start = SIMD2<Float>(Float(a.col) * 3.52, Float(a.row) * 3.52)
            #expect(CharacterLead.firstPointOffCells(walked(steps, from: start), cells: cells, cellSize: 3.52) == nil, "\(a)->\(b)")
            checked += 1
        } }
        #expect(checked > 500)
    }

    /// Bathroom and window-room doors are never walked through (they're not doors
    /// a resident opens): the way round, however long, instead of the shortcut.
    @Test func aShutDoorIsNotAShortcut() throws {
        // Two corridors (rows 3 and 5) joined at both ends, and in the middle
        // only through a bathroom doorway at (3,3) -> (4,3) -> (5,3).
        var cells = Set<GridCoordinate>()
        for c in 0...6 { cells.insert(g(3, c)); cells.insert(g(5, c)) }
        cells.formUnion([g(4, 0), g(4, 6), g(4, 3)])
        let shut: [GridCoordinate: Direction] = [g(3, 3): .south]
        let open = try #require(CharacterLead.route(from: g(3, 3), to: g(5, 3), cells: cells, doors: [:]))
        #expect(open.count == 3)                                             // (the shortcut exists...)
        let round = try #require(CharacterLead.route(from: g(3, 3), to: g(5, 3), cells: cells, doors: shut, canCross: { _ in false }))
        #expect(!round.contains(g(4, 3)))                                     // (...and is never taken)
        #expect(round.count > 3)
    }
}
