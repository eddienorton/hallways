import Testing
import SceneKit
@testable import Hallways

/// Oct 8: Hallways runs on real local time -- the analog wall clock.
@MainActor
@Suite(.serialized)
struct WallClockTests {
    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, in zone: String) -> Date {
        calendar(zone).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    private let turn = 2 * Double.pi

    @Test func handsFollowHoursMinutesAndSeconds() {
        let utc = calendar("UTC")
        let half3 = WallClock.handAngles(for: date(2026, 10, 8, 15, 30, 0, in: "UTC"), calendar: utc)
        #expect(close(half3.hour, 3.5 / 12 * turn))          // hour hand halfway between 3 and 4
        #expect(close(half3.minute, turn / 2))
        #expect(close(half3.second, 0))
        let noon = WallClock.handAngles(for: date(2026, 10, 8, 12, 0, 0, in: "UTC"), calendar: utc)
        #expect(close(noon.hour, 0) && close(noon.minute, 0) && close(noon.second, 0))
        let t = WallClock.handAngles(for: date(2026, 10, 8, 9, 15, 30, in: "UTC"), calendar: utc)
        #expect(close(t.hour, (9 + 15.0 / 60 + 30.0 / 3600) / 12 * turn))
        #expect(close(t.minute, 15.5 / 60 * turn))           // minute hand moves with the seconds
        #expect(close(t.second, turn / 2))
    }

    @Test func theSameInstantReadsAsEachZonesLocalTime() {
        let instant = date(2026, 1, 15, 15, 0, 0, in: "UTC")            // 15:00 UTC
        let london = WallClock.handAngles(for: instant, calendar: calendar("Europe/London"))
        let newYork = WallClock.handAngles(for: instant, calendar: calendar("America/New_York"))
        let tokyo = WallClock.handAngles(for: instant, calendar: calendar("Asia/Tokyo"))
        #expect(close(london.hour, 3.0 / 12 * turn))                     // 3:00 pm
        #expect(close(newYork.hour, 10.0 / 12 * turn))                   // 10:00 am (EST)
        #expect(close(tokyo.hour, 0))                                    // midnight next day
        let summer = date(2026, 7, 15, 15, 0, 0, in: "UTC")
        #expect(close(WallClock.handAngles(for: summer, calendar: calendar("America/New_York")).hour, 11.0 / 12 * turn)) // EDT
    }

    @Test func everyClockShowsTheSameTime() throws {
        let a = WallClock.makeNode(), b = WallClock.makeNode(radius: 0.2)
        #expect(WallClock.liveClockCount >= 2)
        let utc = calendar("UTC")
        let when = date(2026, 10, 8, 4, 20, 45, in: "UTC")
        WallClock.refreshAll(at: when, calendar: utc)
        let expected = WallClock.handAngles(for: when, calendar: utc)
        for clock in [a, b] {
            let shown = try #require(WallClock.shownAngles(of: clock))
            #expect(abs(shown.hour - expected.hour) < 1e-5)
            #expect(abs(shown.minute - expected.minute) < 1e-5)
            #expect(abs(shown.second - expected.second) < 1e-5)
        }
        // A clock just made already shows the current time (no waiting for a tick).
        let fresh = WallClock.makeNode()
        let now = WallClock.handAngles(for: Date())
        let shown = try #require(WallClock.shownAngles(of: fresh))
        #expect(abs(shown.minute - now.minute) < 0.2)
    }

    @Test func aClockOnAWallFaceSitsOnThatWallFacingIntoTheCell() {
        let cell = GridCoordinate(row: 2, col: 3)
        for direction in Direction.allCases {
            let node = WallClock.makeWallNode(at: WallFace(coord: cell, direction: direction), cellSize: 3.2)
            let centre = SIMD2<Float>(3 * 3.2, 2 * 3.2)
            let p = SIMD2<Float>(node.position.x, node.position.z)
            let along = simd_dot(p - centre, SIMD2(Float(direction.delta.col), Float(direction.delta.row)))
            #expect(along > 1.4 && along < 1.55)                          // just inside the wall
            let front = node.convertVector(SCNVector3(0, 0, 1), to: nil)
            #expect(simd_dot(SIMD2(front.x, front.z), SIMD2(Float(-direction.delta.col), Float(-direction.delta.row))) > 0.99)
            #expect(node.position.y == WallClock.mountHeight)
        }
    }

    @Test func buildPlacesTaggedClocksForEveryFace() {
        let cells = Set((0...2).map { GridCoordinate(row: 0, col: $0) })
        let faces: Set<WallFace> = [WallFace(coord: GridCoordinate(row: 0, col: 1), direction: .north),
                                    WallFace(coord: GridCoordinate(row: 0, col: 1), direction: .south)]
        let result = HallwayScene.build(fromMaze: cells, cellSize: 3.2, wallHeight: 3, floorNumber: 9, totalFloors: 16,
                                        playerStart: GridCoordinate(row: 0, col: 0), playerEnd: GridCoordinate(row: 0, col: 2),
                                        clocks: faces)
        let clocks = result.scene.rootNode.childNodes { node, _ in node.name == WallClock.nodeName }
        #expect(clocks.count == 2)
        let tagged = clocks.compactMap { DecoratorTarget.read($0) }
        #expect(tagged.count == 2 && tagged.allSatisfy { $0.kind == .clock })
    }

    private func withIsolatedPersistence(_ body: () throws -> Void) rethrows {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mazes.json")
        let backup = try? Data(contentsOf: url)
        let key = "maze.savedFloorOverrideIDs"
        let oldOverrides = UserDefaults.standard.object(forKey: key)
        defer {
            if let backup { try? backup.write(to: url, options: .atomic) }
            else { try? FileManager.default.removeItem(at: url) }
            if let oldOverrides { UserDefaults.standard.set(oldOverrides, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try body()
    }

    /// The two default clocks, exactly as MazeStore.swift's MazeRecord.defaultClocks seeds them
    /// (MazeRecord is private to MazeStore.swift, so a test can't read it; change both together).
    private static let defaultClocks: [Int: WallFace] = [
        1: WallFace(coord: GridCoordinate(row: 12, col: 7), direction: .west),
        2: WallFace(coord: GridCoordinate(row: 10, col: 6), direction: .north)
    ]

    @Test func clocksPersistAreExclusiveAndDefaultsStayDeleted() throws {
        try withIsolatedPersistence {
            let store = MazeStore()
            store.switchTo(id: 2)
            let elevatorClock = Self.defaultClocks[2]!
            #expect(store.clocks.contains(elevatorClock))                 // Floor 2 default
            // A second clock on another free wall; it takes that face.
            let face = try #require(store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.lazy.flatMap { c in
                Direction.allCases.map { WallFace(coord: c, direction: $0) } }.first { store.canPlaceClock($0.direction, at: $0.coord) })
            store.placeClock(face.direction, at: face.coord)
            #expect(store.hasClock(face.direction, at: face.coord))
            #expect(!store.canPlaceMirror(face.direction, at: face.coord))
            #expect(!store.canPlacePicture(face.direction, at: face.coord))
            #expect(!store.canPlaceClock(face.direction, at: face.coord))
            store.removeClock(elevatorClock.direction, at: elevatorClock.coord)
            store.saveCurrentFloorAsOverride()

            let relaunched = MazeStore()
            relaunched.switchTo(id: 2)
            #expect(relaunched.clocks.contains(face))                     // survives a restart
            #expect(!relaunched.clocks.contains(elevatorClock))           // a deleted default stays deleted
            relaunched.switchTo(id: 1)
            #expect(relaunched.clocks.contains(Self.defaultClocks[1]!))  // lobby default
        }
    }
}
