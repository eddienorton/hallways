import Testing
import SceneKit
@testable import Hallways

/// Oct 1 (Decorator Games): all ten existing games are placeable through
/// Decorate, persist through the existing per-game floor dictionaries, and
/// rebuild as the same real game fixture.
@MainActor
@Suite(.serialized)
struct DecoratorGamesTests {
    /// Same isolation as the furniture tests; `fresh` also clears saved
    /// overrides so the store starts from the bundled DefaultMazes.json.
    private func withIsolatedPersistence(fresh: Bool = true, _ body: (URL) throws -> Void) rethrows {
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
        if fresh {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: key)
        }
        try body(url)
    }

    private func freeWall(_ store: MazeStore, skipping used: Set<GridCoordinate> = []) -> (GridCoordinate, Direction)? {
        for coord in store.cells.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }) where !used.contains(coord) {
            for direction in Direction.allCases where store.canPlaceGame(direction, at: coord) { return (coord, direction) }
        }
        return nil
    }

    @Test func defaultFloorGamesAreStillThere() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            let expected: [(Int, GameFixtureKind)] = [(7, .ticTacToeTerminals), (8, .shellGameStations), (9, .rockPaperScissorsTerminals),
                (10, .higherLowerTerminals), (11, .fiveCardDrawTerminals), (12, .hangmanTerminals), (13, .simonTerminals),
                (14, .connectFourTerminals), (15, .checkersTerminals), (16, .woidleTerminals)]
            for (floor, kind) in expected {
                store.switchTo(id: floor)
                let coord = GridCoordinate(row: 11, col: 12)
                #expect(store.gameFixture(at: coord)?.kind == kind, "floor \(floor)")
                #expect(store.gameFixture(at: coord)?.direction == .east)
            }
        }
    }

    @Test func everyGameIsPlaceablePersistsAndDeletes() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 7)
            var placed: [GameFixtureKind: (GridCoordinate, Direction)] = [:]
            var used: Set<GridCoordinate> = []
            for kind in GameFixtureKind.allCases {
                let (coord, direction) = try #require(freeWall(store, skipping: used))
                store.placeGame(kind, direction: direction, at: coord)
                #expect(store.gameFixture(at: coord)?.kind == kind)
                #expect(!store.canPlaceGame(direction, at: coord)) // one game per cell
                placed[kind] = (coord, direction)
                used.insert(coord)
            }
            store.saveCurrentFloorAsOverride()

            let restarted = MazeStore() // app relaunch
            restarted.switchTo(id: 7)
            for (kind, (coord, direction)) in placed {
                #expect(restarted.gameFixture(at: coord)?.kind == kind)
                #expect(restarted.gameFixture(at: coord)?.direction == direction)
            }
            restarted.switchTo(id: 8) // floor switch and back
            restarted.switchTo(id: 7)
            let (ttCoord, _) = try #require(placed[.ticTacToeTerminals])
            #expect(restarted.gameFixture(at: ttCoord)?.kind == .ticTacToeTerminals)

            restarted.deleteContent([GameFixtureKind.ticTacToeTerminals.editorContentKind], at: ttCoord)
            restarted.saveCurrentFloorAsOverride()
            let again = MazeStore()
            again.switchTo(id: 7)
            #expect(again.gameFixture(at: ttCoord) == nil)
            #expect(again.gameFixture(at: placed[.simonTerminals]!.0)?.kind == .simonTerminals)
        }
    }

    @Test func builtGamesAreTheRealFixtureAndSelectableInDecorate() throws {
        let corridor = Set((4...6).map { GridCoordinate(row: 5, col: $0) })
        let coord = GridCoordinate(row: 5, col: 5)
        let result = HallwayScene.build(fromMaze: corridor, cellSize: 3.52, wallHeight: 3,
            ticTacToeTerminals: [coord: .north], simonTerminals: [GridCoordinate(row: 5, col: 6): .south],
            floorNumber: 7, playerStart: GridCoordinate(row: 5, col: 4), playerEnd: GridCoordinate(row: 5, col: 6))
        let tt = try #require(result.ticTacToeTerminalNodes[coord])
        #expect(DecoratorTarget.read(tt) == DecoratorTarget(floor: 7, coord: coord, kind: .game, direction: .north))
        let simon = try #require(result.simonTerminalNodes[GridCoordinate(row: 5, col: 6)])
        #expect(DecoratorTarget.read(simon)?.kind == .game)
    }

    @Test func decoratorAddGameBuildsRegistersAndDeletes() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 7)
            let scene = SCNScene()
            let state = DecoratorState()
            state.enabled = true
            state.attach(scene: scene, store: store)
            var registered: [(GameFixtureKind, GridCoordinate)] = []
            var unregistered: [(GameFixtureKind, GridCoordinate)] = []
            state.registerLiveGame = { kind, _, coord, _ in registered.append((kind, coord)) }
            state.unregisterLiveGame = { kind, coord in unregistered.append((kind, coord)) }

            for kind in [GameFixtureKind.ticTacToeTerminals, .connectFourTerminals] {
                let (coord, direction) = try #require(freeWall(store))
                state.selection = DecoratorTarget(floor: 7, coord: coord, kind: .wallSurface, direction: direction)
                #expect(state.canAddGame(state.selection!))
                state.addGame(kind)
                #expect(store.gameFixture(at: coord)?.kind == kind)
                #expect(registered.last?.0 == kind && registered.last?.1 == coord)
                let target = DecoratorTarget(floor: 7, coord: coord, kind: .game, direction: direction)
                #expect(state.selection == target)
                var tagged: [SCNNode] = []
                scene.rootNode.enumerateChildNodes { node, _ in if DecoratorTarget.read(node) == target { tagged.append(node) } }
                #expect(tagged.count == 1)

                state.deleteGame()
                #expect(store.gameFixture(at: coord) == nil)
                #expect(unregistered.last?.0 == kind)
                #expect(state.selection?.kind == .wallSurface)
                var left = 0
                scene.rootNode.enumerateChildNodes { node, _ in if DecoratorTarget.read(node) == target { left += 1 } }
                #expect(left == 0)

                // Place again on the same wall.
                state.addGame(kind)
                #expect(store.gameFixture(at: coord)?.kind == kind)
            }
        }
    }

    @Test func liveRegisteredGameLaunchesLikeABuiltOne() throws {
        let cells = Set((5...9).map { GridCoordinate(row: 5, col: $0) })
        let camera = SCNNode()
        let start = GridCoordinate(row: 5, col: 6)
        camera.position = SCNVector3(Float(6 * 3.52), 1.6, Float(5 * 3.52))
        camera.eulerAngles = SCNVector3(0, Float(Direction.north.yaw), 0)
        let controller = TapNavigationController(cameraNode: camera, scene: SCNScene(), cells: cells, cellSize: 3.52,
            startCell: start, startFacing: .north, endCell: GridCoordinate(row: 5, col: 9), floorNumber: 7)
        #expect(controller.ticTacToeTerminalAtCurrentCell == nil)
        let node = GameFixtureKind.ticTacToeTerminals.makeNode(at: start, direction: .north, cellSize: 3.52)
        controller.registerGame(.ticTacToeTerminals, direction: .north, node: node, at: start)
        #expect(controller.ticTacToeTerminalAtCurrentCell == start)
        #expect(controller.ticTacToeTerminalCoordinate(for: node) == start)
        controller.unregisterGame(.ticTacToeTerminals, at: start)
        #expect(controller.ticTacToeTerminalAtCurrentCell == nil)
    }

    /// Oct 1 (invisible game fixtures diagnosis): the bundled Floor 7 build,
    /// through MazeStore exactly as the app loads it -- the Tic-Tac-Toe
    /// node must exist, be attached, and be the FIRST thing a ray from the
    /// corridor toward its wall hits (nothing in front of it).
    @Test func bundledFloorSevenTicTacToeIsBuiltAndUnoccluded() throws {
        try withIsolatedPersistence { _ in
            let store = MazeStore()
            store.switchTo(id: 7)
            let coord = GridCoordinate(row: 11, col: 12)
            #expect(store.ticTacToeTerminals[coord] == .east)
            let result = HallwayScene.build(fromMaze: store.cells, cellSize: store.cellSize, wallHeight: store.wallHeight,
                photoBooths: store.photoBooths, ticTacToeTerminals: store.ticTacToeTerminals,
                floorNumber: 7, playerStart: store.startCoordinate, playerEnd: store.endCoordinate)
            let node = try #require(result.ticTacToeTerminalNodes[coord])
            #expect(node.parent?.name == "hallwaySceneRoot")
            #expect(!node.isHidden && node.opacity == 1)
            let cs = Float(store.cellSize)
            let from = SCNVector3(Float(coord.col) * cs, 1.6, Float(coord.row) * cs)
            let to = SCNVector3(Float(coord.col) * cs + cs, 1.6, Float(coord.row) * cs)
            let hits = result.scene.rootNode.hitTestWithSegment(from: from, to: to, options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue, SCNHitTestOption.backFaceCulling.rawValue: false])
            let first = try #require(hits.min { abs($0.worldCoordinates.x - from.x) < abs($1.worldCoordinates.x - from.x) })
            var owner: SCNNode? = first.node
            while let o = owner, o !== node { owner = o.parent }
            #expect(owner === node, "first hit was \(first.node.name ?? "unnamed") at x=\(first.worldCoordinates.x)")
        }
    }

    /// Oct 1 (game map markers): the in-game map shows a game marker the
    /// moment a game is registered live, and drops it on unregister.
    @Test func inGameMapShowsGamesLive() throws {
        let cells = Set((5...9).map { GridCoordinate(row: 5, col: $0) })
        let start = GridCoordinate(row: 5, col: 6)
        let camera = SCNNode()
        camera.position = SCNVector3(Float(6 * 3.52), 1.6, Float(5 * 3.52))
        let controller = TapNavigationController(cameraNode: camera, scene: SCNScene(), cells: cells, cellSize: 3.52,
            startCell: start, startFacing: .north, endCell: GridCoordinate(row: 5, col: 9), floorNumber: 7)
        let before = try #require(controller.currentFloorMapImage().pngData())
        let coord = GridCoordinate(row: 5, col: 8)
        controller.registerGame(.connectFourTerminals, direction: .north,
                                node: GameFixtureKind.connectFourTerminals.makeNode(at: coord, direction: .north, cellSize: 3.52), at: coord)
        let with = try #require(controller.currentFloorMapImage().pngData())
        #expect(with != before)
        controller.unregisterGame(.connectFourTerminals, at: coord)
        #expect(try #require(controller.currentFloorMapImage().pngData()) == before)
        // Build-time path: a floor built with a game draws it too.
        let plain = HallwayScene.makeFloorMapTexture(cells: cells, end: start, playerAt: start).pngData()
        let marked = HallwayScene.makeFloorMapTexture(cells: cells, end: start, playerAt: start, gameCells: [coord]).pngData()
        #expect(plain != marked)
    }
}
