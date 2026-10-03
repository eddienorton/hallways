import Testing
import SceneKit
import UIKit
@testable import Hallways

/// Oct 1 (cell-surface overrides): per-cell wall/floor/ceiling textures that
/// truly inherit the floor default when absent.
@MainActor
@Suite(.serialized)
struct CellSurfaceOverrideTests {
    private func withIsolatedPersistence(_ body: (URL) throws -> Void) rethrows {
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
        try? FileManager.default.removeItem(at: url)
        UserDefaults.standard.removeObject(forKey: key)
        try body(url)
    }

    private func textures() throws -> (String, String, String, String) {
        let names = HallwayScene.availableHallwayTextureNames().filter { HallwayScene.resolveThemeImage($0) != nil }
        try #require(names.count >= 4)
        return (names[0], names[1], names[2], names[3])
    }

    /// The image a material is showing equals the named texture's image.
    private func shows(_ material: SCNMaterial?, _ name: String?) -> Bool {
        guard let name, let a = (material?.diffuse.contents as? UIImage)?.cgImage?.dataProvider?.data,
              let b = HallwayScene.resolveThemeImage(name)?.cgImage?.dataProvider?.data else { return false }
        return (a as Data) == (b as Data)
    }

    private func nodes(_ root: SCNNode, named name: String) -> [SCNNode] {
        var found: [SCNNode] = []
        root.enumerateChildNodes { node, _ in if node.name == name { found.append(node) } }
        return found
    }

    private func firstCell(_ store: MazeStore) throws -> GridCoordinate {
        try #require(store.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }.first)
    }

    // MARK: Data / persistence

    @Test func legacyJSONWithoutCellSurfacesLoads() throws {
        // The bundled DefaultMazes.json predates cellSurfaces entirely.
        let url = try #require(Bundle.main.url(forResource: "DefaultMazes", withExtension: "json"))
        let floors = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(floors.allSatisfy { $0["cellSurfaces"] == nil })
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 3)
            #expect(!store.cells.isEmpty)
            #expect(store.cellSurfaces.isEmpty)
        }
    }

    @Test func overridesSaveReloadSwitchUndoAndClearEmptyRecords() throws {
        let (a, b, c, _) = try textures()
        try withIsolatedPersistence { url in
            let store = MazeStore()
            store.switchTo(id: 3)
            let coord = try firstCell(store)
            store.setCellSurfaceTexture(a, for: .wall, at: coord)
            store.setCellSurfaceTexture(b, for: .floor, at: coord)
            store.setCellSurfaceTexture(c, for: .ceiling, at: coord)
            #expect(store.cellSurfaces[coord] == CellSurfaceOverride(wallTexture: a, floorTexture: b, ceilingTexture: c))
            store.saveCurrentFloorAsOverride()

            let relaunched = MazeStore()
            relaunched.switchTo(id: 3)
            #expect(relaunched.cellSurfaces[coord] == CellSurfaceOverride(wallTexture: a, floorTexture: b, ceilingTexture: c))
            relaunched.switchTo(id: 4)
            #expect(relaunched.cellSurfaces[coord] == nil || relaunched.cellSurfaces[coord] != CellSurfaceOverride(wallTexture: a, floorTexture: b, ceilingTexture: c))
            relaunched.switchTo(id: 3)
            #expect(relaunched.cellSurfaceTexture(.wall, at: coord) == a)

            // Use Floor Default on one surface keeps the others.
            relaunched.snapshotForUndo()
            relaunched.setCellSurfaceTexture(nil, for: .wall, at: coord)
            #expect(relaunched.cellSurfaces[coord] == CellSurfaceOverride(wallTexture: nil, floorTexture: b, ceilingTexture: c))
            relaunched.undo()
            #expect(relaunched.cellSurfaceTexture(.wall, at: coord) == a)

            // All three inherited -> the record disappears entirely.
            for surface in CellSurfaceKind.allCases { relaunched.setCellSurfaceTexture(nil, for: surface, at: coord) }
            #expect(relaunched.cellSurfaces[coord] == nil)
            relaunched.saveCurrentFloorAsOverride()
            let records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            let floor3 = try #require(records.first { $0["id"] as? Int == 3 })
            #expect(floor3["cellSurfaces"] == nil)
        }
    }

    @Test func resetToDefaultDropsLocalOverridesAndExportRoundTrips() throws {
        let (a, b, _, _) = try textures()
        try withIsolatedPersistence { url in
            let store = MazeStore()
            store.switchTo(id: 3)
            let coord = try firstCell(store)
            store.setCellSurfaceTexture(a, for: .wall, at: coord)
            store.setCellSurfaceTexture(b, for: .floor, at: coord)
            store.saveCurrentFloorAsOverride()

            // SHARE/export carries the override in the same representation the
            // saved local floor uses (which the relaunch tests reload).
            let json = try #require(store.exportLibraryJSON())
            let exported = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
            let floor3 = try #require(exported.first { $0["id"] as? Int == 3 })
            let entries = try #require(floor3["cellSurfaces"] as? [[String: Any]])
            let entry = try #require(entries.first { ($0["coord"] as? [String: Int]) == ["row": coord.row, "col": coord.col] })
            #expect(entry["wallTexture"] as? String == a)
            #expect(entry["floorTexture"] as? String == b)
            #expect(entry["ceilingTexture"] == nil)
            let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            let savedEntries = try #require(saved.first { $0["id"] as? Int == 3 }?["cellSurfaces"] as? [[String: Any]])
            #expect(savedEntries.count == entries.count)

            // Reset restores the bundled floor -- whose JSON has no cellSurfaces
            // today -- so the local overrides are gone.
            store.resetCurrentFloorToDefault()
            #expect(store.cellSurfaces.isEmpty)
            store.undo() // reset is undoable like any other edit
            #expect(store.cellSurfaceTexture(.wall, at: coord) == a)
        }
    }

    // MARK: Rendering

    private let cs: CGFloat = 3.52
    private var corridor: Set<GridCoordinate> { Set((4...6).map { GridCoordinate(row: 5, col: $0) }) }
    private let special = GridCoordinate(row: 5, col: 5)

    private func buildCorridor(_ overrides: [GridCoordinate: CellSurfaceOverride], floorWall: String, floorFloor: String, floorCeiling: String,
                               destinations: [GridCoordinate: ObjectKind] = [:]) -> (scene: SCNScene, wallMaterials: [SCNMaterial], floorMaterial: SCNMaterial, ceilingMaterial: SCNMaterial) {
        let r = HallwayScene.build(fromMaze: corridor, cellSize: cs, wallHeight: 3, destinations: destinations,
            mirrors: [special: .north], floorNumber: 3, playerStart: GridCoordinate(row: 5, col: 4), playerEnd: GridCoordinate(row: 5, col: 4),
            wallTexture: floorWall, floorTexture: floorFloor, ceilingTexture: floorCeiling, cellSurfaces: overrides)
        return (r.scene, r.wallMaterials, r.floorMaterial, r.ceilingMaterial)
    }

    @Test func builtFloorAppliesOverridesOnlyToTheirCellIncludingDoorFrameStrips() throws {
        let (a, b, c, d) = try textures()
        let o = [special: CellSurfaceOverride(wallTexture: a, floorTexture: b, ceilingTexture: c)]
        let built = buildCorridor(o, floorWall: d, floorFloor: d, floorCeiling: d)
        let root = built.scene.rootNode
        let specialWalls = nodes(root, named: WallPainter.nodeName(special))
        #expect(specialWalls.count > 2) // its panels plus the mirror's backfill strips
        for node in specialWalls { #expect(shows(node.geometry?.firstMaterial, a)) }
        let neighbor = GridCoordinate(row: 5, col: 6)
        for node in nodes(root, named: WallPainter.nodeName(neighbor)) { #expect(shows(node.geometry?.firstMaterial, d)) }
        #expect(shows(nodes(root, named: HallwayScene.cellFloorNodeName(special)).first?.geometry?.firstMaterial, b))
        #expect(shows(nodes(root, named: HallwayScene.cellCeilingNodeName(special)).first?.geometry?.firstMaterial, c))
        #expect(nodes(root, named: HallwayScene.cellFloorNodeName(neighbor)).first?.geometry?.firstMaterial === built.floorMaterial)
        #expect(nodes(root, named: HallwayScene.cellCeilingNodeName(neighbor)).first?.geometry?.firstMaterial === built.ceilingMaterial)
    }

    @Test func specialDestinationCubbyGeometryIgnoresTheOverride() throws {
        let (a, _, _, d) = try textures()
        let cubbyCell = GridCoordinate(row: 5, col: 6)
        let built = buildCorridor([cubbyCell: CellSurfaceOverride(wallTexture: a)], floorWall: d, floorFloor: d, floorCeiling: d,
                                  destinations: [cubbyCell: .trashCan])
        let pieces = nodes(built.scene.rootNode, named: WallPainter.nodeName(cubbyCell))
        let exempt = pieces.filter { HallwayScene.isCellSurfaceExempt($0) }
        #expect(!exempt.isEmpty)
        for node in exempt { #expect(shows(node.geometry?.firstMaterial, d)) }      // cubby frame: floor default
        for node in pieces where !HallwayScene.isCellSurfaceExempt(node) { #expect(shows(node.geometry?.firstMaterial, a)) }
        // and live re-skins never pick the exempt pieces up
        let live = HallwayScene.cellWallOverrideMaterials(in: built.scene.rootNode, cellSurfaces: [cubbyCell: CellSurfaceOverride(wallTexture: a)])
        for node in exempt { #expect(!live.contains { $0.material === node.geometry?.firstMaterial }) }
    }

    @Test func floorWideChangeSparesOverridesAndRemovalInheritsTheCurrentDefault() throws {
        let (a, b, c, d) = try textures()
        let o = [special: CellSurfaceOverride(wallTexture: a, floorTexture: b, ceilingTexture: c)]
        let built = buildCorridor(o, floorWall: d, floorFloor: d, floorCeiling: d)
        let root = built.scene.rootNode
        let coordinator = HallwaySceneView.Coordinator()
        coordinator.wallMaterials = built.wallMaterials
        coordinator.floorMaterial = built.floorMaterial
        coordinator.ceilingMaterial = built.ceilingMaterial
        coordinator.currentFloorNumber = 3
        let neighbor = GridCoordinate(row: 5, col: 6)

        // Floor-wide change to `c`: inherited cells follow, the special cell stays.
        coordinator.applyTheme(.brick, wallTexture: c, floorTexture: c, ceilingTexture: a, cellSurfaces: o, root: root)
        for node in nodes(root, named: WallPainter.nodeName(special)) { #expect(shows(node.geometry?.firstMaterial, a)) }
        for node in nodes(root, named: WallPainter.nodeName(neighbor)) { #expect(shows(node.geometry?.firstMaterial, c)) }
        #expect(shows(nodes(root, named: HallwayScene.cellFloorNodeName(special)).first?.geometry?.firstMaterial, b))
        #expect(shows(nodes(root, named: HallwayScene.cellFloorNodeName(neighbor)).first?.geometry?.firstMaterial, c))
        #expect(shows(nodes(root, named: HallwayScene.cellCeilingNodeName(special)).first?.geometry?.firstMaterial, c))
        #expect(shows(nodes(root, named: HallwayScene.cellCeilingNodeName(neighbor)).first?.geometry?.firstMaterial, a))

        // Use Floor Default everywhere: the cell inherits the CURRENT default (c / c / a).
        coordinator.applyTheme(.brick, wallTexture: c, floorTexture: c, ceilingTexture: a, cellSurfaces: [:], root: root)
        for node in nodes(root, named: WallPainter.nodeName(special)) { #expect(shows(node.geometry?.firstMaterial, c)) }
        #expect(nodes(root, named: HallwayScene.cellFloorNodeName(special)).first?.geometry?.firstMaterial === built.floorMaterial)
        #expect(nodes(root, named: HallwayScene.cellCeilingNodeName(special)).first?.geometry?.firstMaterial === built.ceilingMaterial)
    }

    @Test func paintMissionStillTintsAndRestoresAnOverriddenWall() throws {
        let (a, _, _, d) = try textures()
        let built = buildCorridor([special: CellSurfaceOverride(wallTexture: a)], floorWall: d, floorFloor: d, floorCeiling: d)
        let painter = WallPainter(scene: built.scene)
        let panel = try #require(nodes(built.scene.rootNode, named: WallPainter.nodeName(special)).first?.geometry?.firstMaterial)
        #expect(shows(panel, a))
        painter.paint(special)
        #expect(!shows(panel, a)) // tinted blue over the override image
        painter.reset()
        #expect(shows(panel, a))  // restored to the override, not the floor default
    }

    // MARK: Live editing through Decorate

    @Test func decorateCellSurfaceEditAppliesAndPersists() throws {
        let (a, _, _, _) = try textures()
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 3)
            let coord = try firstCell(store)
            let state = DecoratorState()
            state.enabled = true
            state.attach(scene: SCNScene(), store: store)
            state.currentPlayerCell = { coord }
            #expect(state.cellForSurfaceEditing() == coord)
            state.setCellSurface(a, for: .wall, at: coord)
            #expect(store.cellSurfaceTexture(.wall, at: coord) == a)
            let relaunched = MazeStore()
            relaunched.switchTo(id: 3)
            #expect(relaunched.cellSurfaceTexture(.wall, at: coord) == a)
            state.setCellSurface(nil, for: .wall, at: coord)
            #expect(store.cellSurfaces[coord] == nil)
        }
    }

    // MARK: Surfaces editor "This Cell" scope (Oct 1 UI consolidation)

    private func decorating(_ store: MazeStore, at coord: GridCoordinate) -> DecoratorState {
        let state = DecoratorState()
        state.enabled = true
        state.attach(scene: SCNScene(), store: store)
        state.currentPlayerCell = { coord }
        return state
    }

    @Test func surfacesEditorWholeFloorModeIsUnchanged() throws {
        let (a, b, _, _) = try textures()
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 3)
            let coord = try firstCell(store)
            let state = decorating(store, at: coord)
            SurfaceTexturePicker.applyChoice(a, walls: true, floor: false, ceiling: true, cell: nil, store: store, state: state)
            #expect(store.wallTexture == a && store.ceilingTexture == a)
            #expect(store.cellSurfaces.isEmpty)                         // floor-wide only, no cell writes
            SurfaceTexturePicker.applyChoice(b, walls: false, floor: true, ceiling: false, cell: nil, store: store, state: state)
            #expect(store.floorTexture == b && store.wallTexture == a)
            SurfaceTexturePicker.applyChoice(nil, walls: true, floor: false, ceiling: false, cell: nil, store: store, state: state)
            #expect(store.wallTexture == nil)                           // existing whole-floor Default
            let relaunched = MazeStore()
            relaunched.switchTo(id: 3)
            #expect(relaunched.floorTexture == b && relaunched.ceilingTexture == a && relaunched.wallTexture == nil)
        }
    }

    @Test func surfacesEditorThisCellAppliesOnlySelectedTargetsToThatCell() throws {
        let (a, b, c, _) = try textures()
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 3)
            let coord = try firstCell(store)
            let other = try #require(store.cells.first { $0 != coord })
            let state = decorating(store, at: coord)
            let floorWall = store.wallTexture, floorFloor = store.floorTexture, floorCeiling = store.ceilingTexture
            store.setCellSurfaceTexture(c, for: .floor, at: coord)       // pre-existing floor override

            // Walls + Ceiling, This Cell ON: only those two, only this cell.
            SurfaceTexturePicker.applyChoice(a, walls: true, floor: false, ceiling: true, cell: state.cellForSurfaceEditing(), store: store, state: state)
            #expect(store.cellSurfaces[coord] == CellSurfaceOverride(wallTexture: a, floorTexture: c, ceilingTexture: a))
            #expect(store.cellSurfaces[other] == nil)
            #expect(store.wallTexture == floorWall && store.floorTexture == floorFloor && store.ceilingTexture == floorCeiling)

            // Use Floor Default on Walls + Ceiling removes just those; floor override stays.
            SurfaceTexturePicker.applyChoice(nil, walls: true, floor: false, ceiling: true, cell: coord, store: store, state: state)
            #expect(store.cellSurfaces[coord] == CellSurfaceOverride(wallTexture: nil, floorTexture: c, ceilingTexture: nil))

            // All three selected: one undo step for the multi-target edit.
            SurfaceTexturePicker.applyChoice(b, walls: true, floor: true, ceiling: true, cell: coord, store: store, state: state)
            #expect(store.cellSurfaces[coord] == CellSurfaceOverride(wallTexture: b, floorTexture: b, ceilingTexture: b))
            store.undo()
            #expect(store.cellSurfaces[coord] == CellSurfaceOverride(wallTexture: nil, floorTexture: c, ceilingTexture: nil))
            SurfaceTexturePicker.applyChoice(nil, walls: false, floor: true, ceiling: false, cell: coord, store: store, state: state)
            #expect(store.cellSurfaces[coord] == nil)                   // nothing left -> record gone

            // Persisted through the normal floor-override save.
            SurfaceTexturePicker.applyChoice(a, walls: true, floor: false, ceiling: false, cell: coord, store: store, state: state)
            let relaunched = MazeStore()
            relaunched.switchTo(id: 3)
            #expect(relaunched.cellSurfaces[coord] == CellSurfaceOverride(wallTexture: a))

            // Toggle back OFF: the same picker call is whole-floor again.
            SurfaceTexturePicker.applyChoice(b, walls: true, floor: false, ceiling: false, cell: nil, store: store, state: state)
            #expect(store.wallTexture == b)
            #expect(store.cellSurfaces[coord] == CellSurfaceOverride(wallTexture: a)) // cell keeps its own
        }
    }

    @Test func thisCellIsUnavailableOutsideAnOpenCellOnThisFloor() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 3)
            let state = decorating(store, at: GridCoordinate(row: -50, col: -50))
            #expect(state.cellForSurfaceEditing() == nil)
            state.currentPlayerCell = { try? self.firstCell(store) }
            state.isPlayerInElevatorCab = { true }
            #expect(state.cellForSurfaceEditing() == nil)
        }
    }
}
