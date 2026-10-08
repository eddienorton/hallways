import Testing
import SceneKit
@testable import Hallways

/// Oct 8 (Cool Hallways): the front camera runs only while a mirror needs it.
@MainActor
struct MirrorDemandTests {
    /// A mirror on the north wall of cell (0,0), glass facing south (+z).
    private let north = MirrorPlacement(center: SIMD2(0, -1.48), normal: SIMD2(0, 1))
    /// Yaw that looks along -z (north, at the north mirror) / +z (away).
    private let lookNorth: Float = 0
    private let lookSouth: Float = .pi

    private func wanted(_ m: [MirrorPlacement?], at p: SIMD2<Float>, yaw: Float, on: Bool = false) -> Bool {
        MirrorDemand.evaluate(m, player: p, yaw: yaw, on: on).wanted
    }

    @Test func approachingAMirrorWakesItEarly() {
        #expect(!wanted([north], at: SIMD2(0, 8), yaw: lookNorth))          // 9.5 m: too far
        #expect(wanted([north], at: SIMD2(0, 5), yaw: lookNorth))           // 6.5 m, facing: on
        #expect(wanted([north], at: SIMD2(0, 0), yaw: lookNorth))
    }

    @Test func turningAwayAndBackUsesHysteresis() {
        let p = SIMD2<Float>(0, 3)                                          // 4.5 m in front
        #expect(wanted([north], at: p, yaw: lookNorth))
        #expect(!wanted([north], at: p, yaw: lookSouth))                    // facing away, off
        let ninety: Float = .pi / 2                                         // mirror 90 degrees off
        #expect(!wanted([north], at: p, yaw: ninety, on: false))            // won't wake at 90
        #expect(wanted([north], at: p, yaw: ninety, on: true))              // but stays on at 90
        #expect(!wanted([north], at: p, yaw: lookSouth, on: true))          // 180: lets go
    }

    @Test func standingRightAtTheMirrorKeepsItOnWhateverTheHeading() {
        #expect(wanted([north], at: SIMD2(0, 0.3), yaw: lookSouth))         // 1.8 m, back turned
        #expect(wanted([north], at: SIMD2(0, 0.9), yaw: lookSouth, on: true)) // 2.4 m: still on
    }

    @Test func leavingRangeAndBeingBehindTheWallTurnItOff() {
        #expect(wanted([north], at: SIMD2(0, 7), yaw: lookNorth, on: true))   // 8.5 m: still on
        #expect(!wanted([north], at: SIMD2(0, 8), yaw: lookNorth, on: true))  // 9.5 m: off
        #expect(!wanted([north], at: SIMD2(0, -3), yaw: lookSouth))           // behind the wall
    }

    @Test func anyOneOfSeveralMirrorsIsEnough() {
        let east = MirrorPlacement(center: SIMD2(20, 0), normal: SIMD2(-1, 0))
        #expect(!wanted([north, east], at: SIMD2(10, 10), yaw: lookNorth))
        #expect(wanted([north, east], at: SIMD2(16, 0), yaw: .pi / 2 * -1))  // facing +x, toward east
        #expect(wanted([north, east], at: SIMD2(0, 2), yaw: lookNorth))
        #expect(wanted([north, nil], at: SIMD2(50, 50), yaw: lookSouth))     // unknown glass: always
        #expect(!MirrorDemand.evaluate([], player: .zero, yaw: 0, on: true).wanted)
    }

    @Test func trackerWakesAtOnceAndSleepsOnlyAfterTheDelay() {
        var t = MirrorDemandTracker()
        #expect(t.update(wanted: true, now: 0) == true)
        #expect(t.update(wanted: false, now: 1) == nil)                     // grace starts
        #expect(t.update(wanted: true, now: 1.4) == nil)                    // back in time: no restart
        #expect(t.update(wanted: false, now: 2) == nil)
        #expect(t.update(wanted: false, now: 3.4) == nil)                   // 1.4 s
        #expect(t.update(wanted: false, now: 3.6) == false)                 // 1.6 s: off
        #expect(!t.on)
        #expect(t.update(wanted: false, now: 9) == nil)
    }

    @Test(arguments: Direction.allCases)
    func placementFromARealMirrorNodeFacesIntoTheCell(direction: Direction) throws {
        let root = SCNNode()
        let mirror = HallwayScene.makeMirrorNode(at: GridCoordinate(row: 2, col: 3), direction: direction, cellSize: 3.2)
        root.addChildNode(mirror)
        let surface = try #require(mirror.childNode(withName: "mirrorSurface", recursively: true))
        let placement = try #require(MirrorPlacement(surface: surface))
        let cell = SIMD2<Float>(3 * 3.2, 2 * 3.2)
        // The glass faces the cell centre it hangs in.
        #expect(simd_dot(cell - placement.center, placement.normal) > 1)
        #expect(abs(simd_length(placement.normal) - 1) < 0.001)
    }

    @Test func cameraStaysOffWhenNoMirrorNeedsIt() {
        let material = SCNMaterial()
        let camera = MirrorCamera(surfaces: [MirrorSurfaceTarget(material: material, aspect: 0.71, placement: north)])
        camera.playerPose = { (SIMD2(0, 30), 0) }                           // far away
        camera.setActive(true)
        #expect(!camera.isDemanded)
        #expect(!camera.isCapturing)
        camera.setActive(false)                                              // background
        #expect(!camera.isCapturing)
        let empty = MirrorCamera(surfaces: [])                               // a floor with no mirrors
        empty.playerPose = { (.zero, 0) }
        empty.setActive(true)
        #expect(!empty.isDemanded)
        #expect(!empty.isCapturing)
    }
}
