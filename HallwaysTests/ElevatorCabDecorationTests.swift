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
            let store = MazeStore(cabDecorationDefaults: prefs, bundledElevatorCab: { nil })
            store.setElevatorCabDecoration(expected)
            #expect(MazeStore(cabDecorationDefaults: prefs, bundledElevatorCab: { nil }).elevatorCabDecoration == expected)
        }
    }

    @Test func sharedAcrossFloorsAndIndependentOfFloorReset() {
        let store = MazeStore(cabDecorationDefaults: defaults(), bundledElevatorCab: { nil })
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
        let store = MazeStore(cabDecorationDefaults: prefs, bundledElevatorCab: { nil })
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
        #expect(MazeStore(cabDecorationDefaults: prefs, bundledElevatorCab: { nil }).elevatorCabDecoration == store.elevatorCabDecoration)
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
        #expect(MazeStore(cabDecorationDefaults: prefs, bundledElevatorCab: { nil }).elevatorCabDecoration.ceilingFixture == nil)
        #expect(try mount(in: build(floor: 3, decoration: store.elevatorCabDecoration)).childNodes.isEmpty)
        // Existing editor Undo restores the shared record and persists the restoration.
        store.undo()
        #expect(store.elevatorCabDecoration.ceilingFixture?.brightness == 10)
        #expect(MazeStore(cabDecorationDefaults: prefs, bundledElevatorCab: { nil }).elevatorCabDecoration == store.elevatorCabDecoration)
    }

    @Test func liveCeilingAddAtZeroReconstructsAsCeilingNotFluorescent() async throws {
        let store = MazeStore(cabDecorationDefaults: defaults(), bundledElevatorCab: { nil })
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

    // MARK: - Elevator lighting fix #1: "+ -> Ceiling" is cab-aware

    /// A store floor cell with no ceiling light of either kind.
    private func emptyLightCell(_ store: MazeStore) throws -> GridCoordinate {
        try #require(store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
            .first { !store.spotlights.contains($0) && store.fluorescentLights[$0] == nil })
    }

    private func plusMenuState(store: MazeStore, scene: SCNScene, cell: GridCoordinate, inCab: Bool) async -> DecoratorState {
        let state = DecoratorState()
        await attach(state, scene: scene, store: store)
        state.currentPlayerCell = { cell }
        state.isPlayerInElevatorCab = { inCab }
        return state
    }

    @Test func hallwayPlusCeilingStillCreatesOrdinaryFloorCellLights() async throws {
        let store = MazeStore(cabDecorationDefaults: defaults(), bundledElevatorCab: { nil })
        let cell = try emptyLightCell(store)
        let state = await plusMenuState(store: store, scene: build(floor: store.currentMazeID), cell: cell, inCab: false)
        #expect(state.canAddCeilingObjectAtCurrentCell(.spotlight))
        state.addCeilingObjectAtCurrentCell(.spotlight)
        #expect(store.spotlights.contains(cell))
        #expect(state.canAddCeilingObjectAtCurrentCell(.fluorescent))
        state.addCeilingObjectAtCurrentCell(.fluorescent)
        #expect(store.fluorescentLights[cell] != nil)
        #expect(store.elevatorCabDecoration.ceilingFixture == nil) // cab untouched
        // Same-kind stacking still refused in the hallway.
        #expect(!state.canAddCeilingObjectAtCurrentCell(.spotlight))
        #expect(!state.canAddCeilingObjectAtCurrentCell(.fluorescent))
    }

    @Test func inCabPlusCeilingTargetsTheOneCabSlotNotTheHallwayCell() async throws {
        for (item, kind) in [(DecoratorState.CeilingObjectCatalogItem.spotlight, ElevatorCabDecoration.Fixture.Kind.ceiling),
                             (.fluorescent, .fluorescent)] {
            let prefs = defaults()
            let store = MazeStore(cabDecorationDefaults: prefs, bundledElevatorCab: { nil })
            let cell = try emptyLightCell(store)
            let scene = build(floor: store.currentMazeID)
            let state = await plusMenuState(store: store, scene: scene, cell: cell, inCab: true)
            let spotlights = store.spotlights, fluorescents = store.fluorescentLights
            #expect(state.canAddCeilingObjectAtCurrentCell(item))
            state.addCeilingObjectAtCurrentCell(item)
            #expect(store.elevatorCabDecoration.ceilingFixture?.kind == kind)
            #expect(store.spotlights == spotlights && store.fluorescentLights == fluorescents) // no floor-cell fixture
            let fixture = try #require(try mount(in: scene).childNodes.first)
            #expect(try mount(in: scene).childNodes.count == 1)
            #expect(DecoratorTarget.read(fixture)?.isCab == true)
            #expect(state.selection == DecoratorTarget.read(fixture)) // opens the same cab inspector
            // One slot: neither kind can be added again through "+".
            #expect(!state.canAddCeilingObjectAtCurrentCell(.spotlight))
            #expect(!state.canAddCeilingObjectAtCurrentCell(.fluorescent))
            state.addCeilingObjectAtCurrentCell(item == .spotlight ? .fluorescent : .spotlight)
            #expect(try mount(in: scene).childNodes.count == 1)
            #expect(store.elevatorCabDecoration.ceilingFixture?.kind == kind)
            // The direct cab-ceiling inspector edits that SAME fixture, and it persists.
            state.changeBrightness(by: 2)
            #expect(store.elevatorCabDecoration.ceilingFixture?.brightness == 5)
            #expect(MazeStore(cabDecorationDefaults: prefs, bundledElevatorCab: { nil }).elevatorCabDecoration == store.elevatorCabDecoration)
            let rebuilt = build(floor: 3, decoration: MazeStore(cabDecorationDefaults: prefs, bundledElevatorCab: { nil }).elevatorCabDecoration)
            #expect(try mount(in: rebuilt).childNodes.count == 1)
        }
    }

    @Test func hallwayLightsAtTheElevatorCellDoNotDecideCabAvailability() async throws {
        let store = MazeStore(cabDecorationDefaults: defaults(), bundledElevatorCab: { nil })
        let cell = try emptyLightCell(store)
        store.placeSpotlight(at: cell, brightness: 3)
        store.placeFluorescent(.northSouth, at: cell, brightness: 3)
        let scene = build(floor: store.currentMazeID)
        let inCab = await plusMenuState(store: store, scene: scene, cell: cell, inCab: true)
        #expect(inCab.canAddCeilingObjectAtCurrentCell(.spotlight))      // cab slot is empty
        #expect(inCab.canAddCeilingObjectAtCurrentCell(.fluorescent))
        let outside = await plusMenuState(store: store, scene: scene, cell: cell, inCab: false)
        #expect(!outside.canAddCeilingObjectAtCurrentCell(.spotlight))   // hallway semantics outside
        #expect(!outside.canAddCeilingObjectAtCurrentCell(.fluorescent))
        // A cab that can't be edited right now (ride / animation) offers nothing.
        inCab.canEditCab = { false }
        #expect(!inCab.canAddCeilingObjectAtCurrentCell(.spotlight))
    }

    // MARK: - Building-default portability (cab rides on Floor 1 of the building JSON)

    private let sample = ElevatorCabDecoration(
        ceilingFixture: .init(kind: .ceiling, brightness: 7, orientation: .eastWest),
        backArtwork: .cameraRoll("PHASSET-ONLY-ON-THIS-PHONE"),
        sideArtwork: .builtIn("IMG_7416"),
        sideRightArtwork: .lobbyDefault("lobby-outside"))

    private func records(_ json: String) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    @Test func olderBuildingJSONWithoutCabStillDecodesAndHasNoCabDefault() {
        let old = Data(#"[{"id":1,"cells":[{"row":0,"col":0}]},{"id":2,"cells":[]}]"#.utf8)
        #expect(MazeStore.elevatorCabDefault(inLibraryJSON: old) == nil)
        // A cab field on any floor other than 1 is not the building's.
        let misplaced = Data(#"[{"id":2,"cells":[],"elevatorCab":{}}]"#.utf8)
        #expect(MazeStore.elevatorCabDefault(inLibraryJSON: misplaced) == nil)
    }

    @Test func exportCarriesThePortableCabOnFloorOneOnlyAndRoundTrips() throws {
        let store = MazeStore(cabDecorationDefaults: defaults(), bundledElevatorCab: { nil })
        store.setElevatorCabDecoration(sample)
        let json = try #require(store.exportLibraryJSON())
        let rows = try records(json)
        #expect(rows.filter { $0["elevatorCab"] != nil }.map { $0["id"] as? Int } == [1])
        let decoded = try #require(MazeStore.elevatorCabDefault(inLibraryJSON: Data(json.utf8)))
        #expect(decoded.ceilingFixture == sample.ceilingFixture)           // same fixture
        #expect(decoded.sideArtwork == .builtIn("IMG_7416"))                // built-in travels
        #expect(decoded.sideRightArtwork == .lobbyDefault("lobby-outside")) // bundled resource travels
        #expect(decoded.backArtwork == nil)                                 // camera roll does not
        #expect(store.elevatorCabDecoration == sample)                      // local choice untouched
        // An empty cab exports explicitly as empty (not "absent").
        store.setElevatorCabDecoration(ElevatorCabDecoration())
        let empty = try #require(store.exportLibraryJSON())
        #expect(MazeStore.elevatorCabDefault(inLibraryJSON: Data(empty.utf8)) == ElevatorCabDecoration())
    }

    @Test func freshDeviceSeedsFromBundledDefaultButSavedLocalStateWins() {
        let bundled = sample.portable
        let fresh = defaults()
        let seeded = MazeStore(cabDecorationDefaults: fresh, bundledElevatorCab: { bundled })
        #expect(seeded.elevatorCabDecoration == bundled)
        #expect(!ElevatorCabDecoration.hasSavedValue(in: fresh)) // seed is not written back
        let oldBundle = MazeStore(cabDecorationDefaults: defaults(), bundledElevatorCab: { nil })
        #expect(oldBundle.elevatorCabDecoration == ElevatorCabDecoration()) // unchanged old behavior

        let existing = defaults()
        let local = ElevatorCabDecoration(ceilingFixture: .init(kind: .fluorescent, brightness: 2))
        local.save(to: existing)
        #expect(MazeStore(cabDecorationDefaults: existing, bundledElevatorCab: { bundled }).elevatorCabDecoration == local)
        // Even a deliberately EMPTY saved cab beats a bundled fixture.
        let emptied = defaults()
        ElevatorCabDecoration().save(to: emptied)
        #expect(MazeStore(cabDecorationDefaults: emptied, bundledElevatorCab: { bundled }).elevatorCabDecoration.ceilingFixture == nil)
    }

    @Test func resetCurrentFloorKeepsCabAndResetAllRestoresTheBuildingDefault() {
        let prefs = defaults()
        let bundled = sample.portable
        let store = MazeStore(cabDecorationDefaults: prefs, bundledElevatorCab: { bundled })
        let local = ElevatorCabDecoration(ceilingFixture: .init(kind: .fluorescent, brightness: 9))
        store.setElevatorCabDecoration(local)
        store.resetCurrentFloorToDefault()
        #expect(store.elevatorCabDecoration == local) // floors don't own the cab
        store.resetAllFloorsToDefaults()
        #expect(store.elevatorCabDecoration == bundled) // the building comes back
        #expect(MazeStore(cabDecorationDefaults: prefs, bundledElevatorCab: { nil }).elevatorCabDecoration == bundled) // persisted
        #expect(store.elevatorCabDecoration.ceilingFixture?.kind == .ceiling) // still ONE slot

        let oldDefaults = MazeStore(cabDecorationDefaults: defaults(), bundledElevatorCab: { nil })
        oldDefaults.setElevatorCabDecoration(local)
        oldDefaults.resetAllFloorsToDefaults()
        #expect(oldDefaults.elevatorCabDecoration == ElevatorCabDecoration()) // bundle predates the field
    }
}
