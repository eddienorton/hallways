import Testing
import SceneKit
@testable import Hallways

@MainActor
struct ElevatorCabDecorationTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ElevatorCabDecorationTests.\(UUID().uuidString)")!
    }

    private func build(floor: Int, decoration: ElevatorCabDecoration = .init()) -> SCNScene {
        let a = GridCoordinate(row: 0, col: 0)
        let b = GridCoordinate(row: 1, col: 0)
        return HallwayScene.build(fromMaze: [a, b], cellSize: 3.2, wallHeight: 3,
                                  floorNumber: floor, playerStart: a, playerEnd: b,
                                  elevatorCabDecoration: decoration).scene
    }

    private func mount(in scene: SCNScene) throws -> SCNNode {
        try #require(scene.rootNode.childNode(withName: "elevatorCabCeilingMount", recursively: true))
    }

    private func source(in node: SCNNode) throws -> SCNNode {
        var result: SCNNode?
        node.enumerateHierarchy { child, _ in if child.light != nil { result = child } }
        return try #require(result)
    }

    private func attach(_ state: DecoratorState, scene: SCNScene, store: MazeStore) async {
        state.attach(scene: scene, store: store)
        state.canEditCab = { true }
        state.enabled = true
        // Allow the existing attach-time deferred selection reset to finish.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func oldOrMalformedSaveHasNoFixtureAndDoesNotInventOne() throws {
        let prefs = defaults()
        #expect(ElevatorCabDecoration.load(from: prefs).ceilingFixture == nil)
        prefs.set(Data("{}".utf8), forKey: ElevatorCabDecoration.storageKey)
        #expect(ElevatorCabDecoration.load(from: prefs).ceilingFixture == nil)
        prefs.set(Data("not json".utf8), forKey: ElevatorCabDecoration.storageKey)
        #expect(ElevatorCabDecoration.load(from: prefs).ceilingFixture == nil)
        #expect(try mount(in: build(floor: 2)).childNodes.isEmpty)
    }

    @Test func fixtureTypeZeroBrightnessAndOrientationPersistAcrossStoreInstances() {
        let prefs = defaults()
        for kind: ElevatorCabDecoration.Fixture.Kind in [.ceiling, .fluorescent] {
            let expected = ElevatorCabDecoration(ceilingFixture: .init(kind: kind, brightness: 0, orientation: .eastWest))
            let store = MazeStore(cabDecorationDefaults: prefs)
            store.setElevatorCabDecoration(expected)
            #expect(MazeStore(cabDecorationDefaults: prefs).elevatorCabDecoration == expected)
        }
    }

    @Test func sharedAcrossFloorsAndIndependentOfFloorReset() {
        let store = MazeStore(cabDecorationDefaults: defaults())
        let expected = ElevatorCabDecoration(ceilingFixture: .init(kind: .fluorescent, brightness: 8, orientation: .eastWest))
        store.setElevatorCabDecoration(expected)
        store.switchTo(id: 2)
        #expect(store.elevatorCabDecoration == expected)
        store.switchTo(id: 3)
        #expect(store.elevatorCabDecoration == expected)
        store.resetCurrentFloorToDefault()
        #expect(store.elevatorCabDecoration == expected)
    }

    @Test func cabIdentityHasNoGridCoordinateAndCannotCollide() {
        let cab = DecoratorTarget(floor: 2, location: .elevatorCeiling, kind: .ceiling)
        #expect(cab.coord == nil)
        #expect(cab != DecoratorTarget(floor: 2, coord: .init(row: 0, col: 0), kind: .ceiling))
    }

    @Test func reconstructionUsesCabLocalCeilingFaceAndSameSharedFixture() throws {
        let decoration = ElevatorCabDecoration(ceilingFixture: .init(kind: .fluorescent, brightness: 10, orientation: .eastWest))
        for floor in [2, 3, 10] {
            let scene = build(floor: floor, decoration: decoration)
            let ceilingMount = try mount(in: scene)
            #expect(ceilingMount.parent?.name == "elevatorCab")
            #expect(abs(ceilingMount.position.x) < 0.00001)
            #expect(abs(ceilingMount.position.y - 1.285) < 0.00001)
            #expect(abs(ceilingMount.position.z + 1.6) < 0.00001)
            #expect(abs(ceilingMount.worldPosition.y - 2.585) < 0.00001)
            #expect(ceilingMount.childNodes.count == 1)
            let fixture = try #require(ceilingMount.childNodes.first)
            #expect(DecoratorTarget.read(fixture) == .init(floor: floor, location: .elevatorCeiling, kind: .fluorescent))
            #expect(abs(fixture.eulerAngles.y - .pi / 2) < 0.00001)
            #expect(try source(in: fixture).light?.intensity == 240)
            #expect(abs(try source(in: fixture).worldPosition.y - 2.435) < 0.00001)
            var ceilingTargets = 0
            scene.rootNode.enumerateChildNodes { node, _ in
                if DecoratorTarget.read(node) == .init(floor: floor, location: .elevatorCeiling, kind: .ceilingSurface) {
                    ceilingTargets += 1
                    #expect(node.geometry is SCNBox)
                }
            }
            #expect(ceilingTargets == 1)
        }
    }

    @Test func liveAddDimRotateDeleteUsesOneSlotWithoutRebuildingOrMutatingGrid() async throws {
        let prefs = defaults()
        let store = MazeStore(cabDecorationDefaults: prefs)
        let scene = build(floor: store.currentMazeID)
        let state = DecoratorState()
        await attach(state, scene: scene, store: store)
        let surface = DecoratorTarget(floor: store.currentMazeID, location: .elevatorCeiling, kind: .ceilingSurface)
        state.selection = surface
        let version = store.version
        let gridLights = store.spotlights
        let gridFluorescents = store.fluorescentLights
        state.add(.fluorescent)
        let ceilingMount = try mount(in: scene)
        let fixture = try #require(ceilingMount.childNodes.first)
        #expect(ceilingMount.childNodes.count == 1)
        #expect(!state.canAdd(surface))
        #expect(!state.canMove(.north))
        state.move(.north)
        #expect(fixture.position.x == 0 && fixture.position.z == 0)
        state.changeBrightness(by: -3)
        #expect(store.elevatorCabDecoration.ceilingFixture?.brightness == 0)
        #expect(try source(in: fixture).light?.intensity == 0)
        #expect(!fixture.childNodes.isEmpty)
        state.changeBrightness(by: 10)
        #expect(try source(in: fixture).light?.intensity == 240)
        state.changeOrientation(.eastWest)
        #expect(abs(fixture.eulerAngles.y - .pi / 2) < 0.00001)
        #expect(ceilingMount.childNodes.first === fixture)
        #expect(store.version == version)
        #expect(store.spotlights == gridLights && store.fluorescentLights == gridFluorescents)
        #expect(MazeStore(cabDecorationDefaults: prefs).elevatorCabDecoration == store.elevatorCabDecoration)
        // Simulates a retained inspector becoming unavailable while travel starts.
        state.canEditCab = { false }
        state.changeBrightness(by: -1)
        state.changeOrientation(.northSouth)
        state.deleteSelected()
        #expect(store.elevatorCabDecoration.ceilingFixture?.brightness == 10)
        #expect(store.elevatorCabDecoration.ceilingFixture?.orientation == .eastWest)
        #expect(ceilingMount.childNodes.count == 1)
        state.canEditCab = { true }
        state.deleteSelected()
        #expect(ceilingMount.childNodes.isEmpty)
        #expect(MazeStore(cabDecorationDefaults: prefs).elevatorCabDecoration.ceilingFixture == nil)
        #expect(try mount(in: build(floor: 3, decoration: store.elevatorCabDecoration)).childNodes.isEmpty)
        // Existing editor Undo restores the shared record and persists the restoration.
        store.undo()
        #expect(store.elevatorCabDecoration.ceilingFixture?.brightness == 10)
        #expect(MazeStore(cabDecorationDefaults: prefs).elevatorCabDecoration == store.elevatorCabDecoration)
    }

    @Test func liveCeilingAddAtZeroReconstructsAsCeilingNotFluorescent() async throws {
        let store = MazeStore(cabDecorationDefaults: defaults())
        let scene = build(floor: store.currentMazeID)
        let state = DecoratorState()
        await attach(state, scene: scene, store: store)
        state.selection = .init(floor: store.currentMazeID, location: .elevatorCeiling, kind: .ceilingSurface)
        state.add(.ceiling)
        state.changeBrightness(by: -3)
        let next = build(floor: 3, decoration: store.elevatorCabDecoration)
        let fixture = try #require(try mount(in: next).childNodes.first)
        #expect(fixture.childNodes.contains { $0.geometry is SCNCylinder })
        #expect(try source(in: fixture).light?.intensity == 0)
        #expect(DecoratorTarget.read(fixture)?.kind == .ceiling)
    }
}
