import Testing
import SceneKit
@testable import Hallways

@MainActor
struct DecoratorModeTests {
    @Test func identitiesFollowAuthoredParentWithoutChangingNodeNames() {
        let root = SCNNode()
        root.name = "existing-fixture-name"
        let child = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0))
        root.addChildNode(child)
        let target = DecoratorTarget(floor: 3, coord: GridCoordinate(row: 4, col: 5), kind: .fluorescent)
        target.tag(root)
        #expect(DecoratorTarget.read(child) == nil)
        #expect(DecoratorTarget.read(child.parent!) == target)
        #expect(root.name == "existing-fixture-name")
        let moved = DecoratorTarget(floor: 3, coord: GridCoordinate(row: 4, col: 6), kind: .fluorescent)
        moved.tag(root)
        #expect(DecoratorTarget.read(root) == moved)
    }

    @Test func ceilingFactoryPreservesExistingFixtureAndLightParameters() throws {
        let fixture = HallwayScene.makeAuthoredCeilingFixture(cellSize: 3.2, level: 3)
        let disc = try #require(fixture.childNodes.first { $0.geometry is SCNCylinder })
        let cylinder = try #require(disc.geometry as? SCNCylinder)
        #expect(abs(cylinder.radius - 0.384) < 0.00001)
        #expect(cylinder.height == 0.04)
        #expect(disc.position.y == -0.02)
        let source = try #require(fixture.childNodes.first { $0.light != nil })
        let light = try #require(source.light)
        #expect(light.type == .omni)
        // Sept 21 (0-10 brightness expansion): level 3 on the new
        // ceiling/fluorescent curve [0,5,12,22,35,52,75,100,135,180,240]
        // is 22.
        #expect(light.intensity == 22)
        #expect(abs(light.attenuationStartDistance - 0.48) < 0.00001)
        #expect(light.attenuationEndDistance == 8)
        #expect(source.position.y == -0.15)
    }

    @Test func floorBuildTagsActualFixturesAndCeilingSurface() {
        let a = GridCoordinate(row: 0, col: 0)
        let b = GridCoordinate(row: 1, col: 0)
        let built = HallwayScene.build(fromMaze: [a, b], cellSize: 3.2, wallHeight: 3,
            spotlights: [a], floorNumber: 2, playerStart: a, playerEnd: b,
            fluorescentLights: [b: .eastWest])
        var targets: [DecoratorTarget] = []
        built.scene.rootNode.enumerateChildNodes { node, _ in
            if let target = DecoratorTarget.read(node) { targets.append(target) }
        }
        #expect(targets.filter { $0.kind == .ceilingSurface && !$0.isCab }.count == 2)
        #expect(targets.contains(DecoratorTarget(floor: 2, coord: a, kind: .ceiling)))
        #expect(targets.contains(DecoratorTarget(floor: 2, coord: b, kind: .fluorescent)))
    }

    // Sept 21 (0-10 brightness expansion): ceiling/fluorescent moved to an
    // 11-step authored range (0...10) with a new canonical curve; level 0
    // is a real, meaningful "OFF" value, not a missing/default one. wall/
    // fire/picture are untouched and still clamp to 1...5. This only
    // exercises AuthoredLightKind directly -- no SceneKit/MazeStore involved.
    @Test func ceilingAndFluorescentUseTheNewElevenStepCurveAndRange() {
        #expect(AuthoredLightKind.ceiling.levelRange == 0...10)
        #expect(AuthoredLightKind.fluorescent.levelRange == 0...10)
        #expect(AuthoredLightKind.ceiling.intensity(level: 0) == 0)
        #expect(AuthoredLightKind.ceiling.intensity(level: 1) == 5)
        #expect(AuthoredLightKind.ceiling.intensity(level: 2) == 12)
        #expect(AuthoredLightKind.ceiling.intensity(level: 3) == 22)
        #expect(AuthoredLightKind.ceiling.intensity(level: 4) == 35)
        #expect(AuthoredLightKind.ceiling.intensity(level: 5) == 52)
        #expect(AuthoredLightKind.ceiling.intensity(level: 6) == 75)
        #expect(AuthoredLightKind.ceiling.intensity(level: 7) == 100)
        #expect(AuthoredLightKind.ceiling.intensity(level: 8) == 135)
        #expect(AuthoredLightKind.ceiling.intensity(level: 9) == 180)
        #expect(AuthoredLightKind.ceiling.intensity(level: 10) == 240)
        #expect(AuthoredLightKind.fluorescent.intensity(level: 0) == 0)
        #expect(AuthoredLightKind.fluorescent.intensity(level: 3) == 22)
        #expect(AuthoredLightKind.fluorescent.intensity(level: 10) == 240)
        // Existing clamping policy (values outside the range clamp to the
        // nearest bound) still applies, just against the new bounds of 0...10.
        #expect(AuthoredLightKind.ceiling.intensity(level: 11) == 240)
        #expect(AuthoredLightKind.ceiling.intensity(level: -1) == 0)
    }

    @Test func wallFireAndPictureKeepTheirOriginalFiveStepRangeAndCurve() {
        #expect(AuthoredLightKind.wall.levelRange == 1...5)
        #expect(AuthoredLightKind.fire.levelRange == 1...5)
        #expect(AuthoredLightKind.picture.levelRange == 1...5)
        #expect(AuthoredLightKind.wall.intensity(level: 3) == 260)
        #expect(AuthoredLightKind.fire.intensity(level: 3) == 85)
        #expect(AuthoredLightKind.picture.intensity(level: 3) == 6)
        // Clamping policy unchanged: still clamps to 5, not the new 10.
        #expect(AuthoredLightKind.wall.intensity(level: 8) == AuthoredLightKind.wall.intensity(level: 5))
    }

    // A pre-existing saved level of 3 (authored under an earlier curve)
    // must decode/read back as exactly 3 -- no migration/rescaling -- and
    // simply produces a different physical intensity under whichever
    // curve is current, per Eddie's "old level 3 stays level 3" requirement.
    @Test func existingSavedLevelThreeIsUnchangedByTheRangeExpansion() {
        let coord = GridCoordinate(row: 0, col: 0)
        let settings = [LightBrightness(coord: coord, kind: .ceiling, level: 3)]
        #expect(LightBrightness.level(for: .ceiling, at: coord, in: settings) == 3)
        #expect(AuthoredLightKind.ceiling.intensity(level: 3) == 22)
    }

    // Sept 21 (0-10 brightness expansion, level 0 = OFF): the read path
    // must not treat a genuinely-stored 0 as "no value" and fall back to
    // the default of 3 -- that fallback only fires when NO LightBrightness
    // entry exists at all for this coord/kind, never when one exists with
    // level == 0. Traced every call site of this path (MazeStore's own
    // lightBrightnessLevel, DecoratorState.level, the Floor Editor's paint
    // comparisons) and none of them special-case a zero return value either.
    @Test func levelZeroSurvivesThePersistenceReadPathAsOffNotAsDefault() {
        let coord = GridCoordinate(row: 0, col: 0)
        let settings = [LightBrightness(coord: coord, kind: .ceiling, level: 0)]
        #expect(LightBrightness.level(for: .ceiling, at: coord, in: settings) == 0)
        #expect(AuthoredLightKind.ceiling.intensity(level: 0) == 0)
        // A coord/kind with NO entry at all is the only case that still
        // falls back to the default of 3 -- confirms the two cases
        // ("stored 0" vs "nothing stored") stay distinct.
        #expect(LightBrightness.level(for: .ceiling, at: coord, in: []) == 3)
    }

    // Sept 21 (ceiling-selection trap fix): the ceiling slab's bottom face
    // and a flush-mounted fixture's top face are exactly coincident (proven
    // by direct computation, see makeDecoratorHitProxy's doc comment), so
    // hit-testing needs an untagged, invisible, closer-to-camera child proxy
    // on every fixture to reliably win that tie. This locks in that the
    // proxy exists, is untagged itself (so it resolves to the fixture root
    // via the parent walk, not by carrying its own identity), and sits
    // below the fixture's own lowest visible geometry.
    @Test func ceilingFixtureCarriesAnUntaggedHitProxyBelowItsOwnGeometry() {
        let fixture = HallwayScene.makeAuthoredCeilingFixture(cellSize: 3.2, level: 3)
        let proxy = fixture.childNodes.first { $0.name == "decoratorHitProxy" }
        #expect(proxy != nil)
        #expect(DecoratorTarget.read(proxy!) == nil)
        let lowestVisibleY = fixture.childNodes
            .filter { $0.name != "decoratorHitProxy" }
            .compactMap { node -> Float? in
                guard let box = node.geometry as? SCNCylinder else { return nil }
                return node.position.y - Float(box.height) / 2
            }
            .min() ?? 0
        #expect(proxy!.position.y < lowestVisibleY)
    }

    @Test func fluorescentFixtureCarriesAnUntaggedHitProxy() {
        let fixture = HallwayScene.makeFluorescentLight(orientation: .northSouth, level: 3, cellSize: 3.2)
        let proxy = fixture.childNodes.first { $0.name == "decoratorHitProxy" }
        #expect(proxy != nil)
        #expect(DecoratorTarget.read(proxy!) == nil)
    }

    // Sept 21 (Decorator Picture support + Picture Size): mirrors
    // floorBuildTagsActualFixturesAndCeilingSurface above, but for an
    // ordinary authored Picture -- confirms (a) its frame root carries
    // a .picture DecoratorTarget the same tag-and-parent-walk way every
    // other Decorator target does, and (b) at .standard (scale 1) the
    // frame box is EXACTLY today's pre-existing dimensions: base panel
    // 0.6 x 0.85 (framedPhoto's own fixed Standard aspect) + the 0.1
    // frame padding addPictureNode has always added, unaffected by the
    // new fixed-at-fullLength wall reservation behind it.
    @Test func floorBuildTagsOrdinaryPicturesAtStandardDimensions() throws {
        let a = GridCoordinate(row: 0, col: 0)
        let b = GridCoordinate(row: 1, col: 0)
        let built = HallwayScene.build(fromMaze: [a, b], cellSize: 3.2, wallHeight: 3,
            missionSigns: [:], pictures: [a: (direction: .east, size: .standard)],
            floorNumber: 2, playerStart: a, playerEnd: b)
        var pictureFrame: SCNNode?
        built.scene.rootNode.enumerateChildNodes { node, _ in
            if let target = DecoratorTarget.read(node), target.kind == .picture { pictureFrame = node }
        }
        let frame = try #require(pictureFrame)
        #expect(DecoratorTarget.read(frame) == DecoratorTarget(floor: 2, coord: a, kind: .picture))
        let box = try #require(frame.geometry as? SCNBox)
        #expect(abs(box.width - 0.7) < 0.001)
        #expect(abs(box.height - 0.95) < 0.001)
    }

    // Sept 21 (3D Decorator wall authoring, Pass 1): every ordinary,
    // empty wall panel buildWallPanel constructs now carries its own
    // wallSurface identity (coord + direction) -- but a wall face a
    // Picture already occupies must NOT also get one, since no
    // ordinary addWall panel is built there at all (see the wall-skip
    // conditionals in HallwayScene.build(fromMaze:...)'s per-cell
    // loop) -- confirming existing Picture selection still wins over
    // any wall behind it, because there is no wall tag to compete
    // with in the first place.
    @Test func floorBuildTagsEmptyOrdinaryWallsAsWallSurfaceButNotAPictureWall() throws {
        let a = GridCoordinate(row: 0, col: 0)
        let b = GridCoordinate(row: 1, col: 0)
        let built = HallwayScene.build(fromMaze: [a, b], cellSize: 3.2, wallHeight: 3,
            missionSigns: [:], pictures: [a: (direction: .east, size: .standard)],
            floorNumber: 2, playerStart: a, playerEnd: b)
        var wallSurfaceTargets: [DecoratorTarget] = []
        built.scene.rootNode.enumerateChildNodes { node, _ in
            if let target = DecoratorTarget.read(node), target.kind == .wallSurface { wallSurfaceTargets.append(target) }
        }
        // a's east wall is occupied by the Picture -- must NOT also be
        // tagged wallSurface (no ordinary wall panel exists there).
        #expect(!wallSurfaceTargets.contains(DecoratorTarget(floor: 2, coord: a, kind: .wallSurface, direction: .east)))
        // a's north and west walls are ordinary and empty -- tagged, with direction.
        #expect(wallSurfaceTargets.contains(DecoratorTarget(floor: 2, coord: a, kind: .wallSurface, direction: .north)))
        #expect(wallSurfaceTargets.contains(DecoratorTarget(floor: 2, coord: a, kind: .wallSurface, direction: .west)))
        // b's south/east/west walls are all ordinary and empty.
        #expect(wallSurfaceTargets.contains(DecoratorTarget(floor: 2, coord: b, kind: .wallSurface, direction: .south)))
        #expect(wallSurfaceTargets.contains(DecoratorTarget(floor: 2, coord: b, kind: .wallSurface, direction: .east)))
        #expect(wallSurfaceTargets.contains(DecoratorTarget(floor: 2, coord: b, kind: .wallSurface, direction: .west)))
    }

    // Sept 21 (Picture Decorator complete pass, Goal 1): a Small
    // Picture's wall backfill (backing panel + 4 door-frame strips,
    // tagged via PictureBackfillTarget) is sized to THIS Picture's own
    // current size -- not always the largest authored size
    // (.fullLength) -- which is what caused the
    // oversized-cutout-with-visible-seams bug Eddie reported on device
    // around Small/Standard/Poster pictures.
    @Test func pictureBackfillIsSizedToTheActualPictureNotAlwaysFullLength() throws {
        let a = GridCoordinate(row: 0, col: 0)
        let b = GridCoordinate(row: 1, col: 0)
        let built = HallwayScene.build(fromMaze: [a, b], cellSize: 3.2, wallHeight: 3,
            missionSigns: [:], pictures: [a: (direction: .east, size: .small)],
            floorNumber: 2, playerStart: a, playerEnd: b)
        let backfillTarget = PictureBackfillTarget(floor: 2, coord: a, direction: .east)
        var backfillNodes: [SCNNode] = []
        built.scene.rootNode.enumerateChildNodes { node, _ in
            if PictureBackfillTarget.read(node) == backfillTarget { backfillNodes.append(node) }
        }
        // 4 door-frame strips + 1 wall-matching backing panel.
        #expect(backfillNodes.count == 5)
        let backing = try #require(backfillNodes.first { ($0.geometry as? SCNBox)?.length == 0.02 })
        let box = try #require(backing.geometry as? SCNBox)
        // Small's own panel (base 0.6 * .small's 0.65 scale = 0.39) +
        // 0.1 frame padding -- NOT the old, always-fullLength-sized
        // reservation (0.6 * 2.6 + 0.1 = 1.66).
        #expect(abs(box.width - 0.49) < 0.001)
        #expect(box.width < 1.0)
    }

    // Sept 21 (Picture Decorator complete pass): the full Picture
    // Decorator inspector lifecycle, live, on one real Picture wall
    // from MazeStore's own floor 2 -- ADD -> resize Standard ->
    // Full Length -> back to Standard (backfill expands then restores
    // correctly) -> Picture Light OFF -> ON (creates the existing real
    // Picture Light fixture/SCNLight) -> brightness change (mutates
    // that same SCNLight in place) -> OFF again (removes it) -> ON
    // again -> DELETE PICTURE (removes the Picture AND its Picture
    // Light, restores the ordinary wall as a valid wallSurface target
    // again). Never rebuilds the scene -- every step mutates the SAME
    // live nodes in place, exactly like Eddie's on-device requirement.
    @Test func pictureAddResizeLightAndDeleteAllWorkLiveWithoutRebuilding() async throws {
        let store = MazeStore()
        store.switchTo(id: 2)
        let coord = GridCoordinate(row: 4, col: 0)
        let direction = Direction.west
        #expect(store.canPlacePicture(direction, at: coord))

        let scene = HallwayScene.build(fromMaze: store.cells, cellSize: store.cellSize, wallHeight: store.wallHeight, floorNumber: store.currentMazeID).scene
        let state = DecoratorState()
        state.attach(scene: scene, store: store)
        state.enabled = true
        // Allow the existing attach-time deferred selection reset to finish.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        let wallTarget = DecoratorTarget(floor: store.currentMazeID, coord: coord, kind: .wallSurface, direction: direction)
        state.selection = wallTarget
        #expect(state.canAddPicture(wallTarget))
        state.addPicture()

        let pictureTarget = DecoratorTarget(floor: store.currentMazeID, coord: coord, kind: .picture, direction: direction)
        #expect(state.selection == pictureTarget)
        #expect(store.hasPicture(direction, at: coord))
        #expect(store.pictureSize(direction: direction, at: coord) == .standard)

        var frame: SCNNode?
        scene.rootNode.enumerateChildNodes { node, _ in
            if DecoratorTarget.read(node) == pictureTarget { frame = node }
        }
        let frameNode = try #require(frame)
        let frameBox = try #require(frameNode.geometry as? SCNBox)
        #expect(abs(frameBox.width - 0.7) < 0.001) // 0.6 + 0.1, standard scale 1

        let backfillTarget = PictureBackfillTarget(floor: store.currentMazeID, coord: coord, direction: direction)
        func backfillNodes() -> [SCNNode] {
            var nodes: [SCNNode] = []
            scene.rootNode.enumerateChildNodes { node, _ in
                if PictureBackfillTarget.read(node) == backfillTarget { nodes.append(node) }
            }
            return nodes
        }
        #expect(backfillNodes().count == 5)
        let standardBacking = try #require(backfillNodes().first { ($0.geometry as? SCNBox)?.length == 0.02 })
        let standardBackingBox = try #require(standardBacking.geometry as? SCNBox)
        #expect(abs(standardBackingBox.width - 0.7) < 0.001)

        // Live resize to Full Length expands both the frame AND the
        // backfill -- no scene rebuild, same node identity throughout.
        state.changePictureSize(.fullLength)
        #expect(store.pictureSize(direction: direction, at: coord) == .fullLength)
        #expect(abs(frameBox.width - (0.6 * 2.6 + 0.1)) < 0.01)
        let fullLengthBackfill = backfillNodes()
        #expect(fullLengthBackfill.count == 5)
        let fullLengthBacking = try #require(fullLengthBackfill.first { ($0.geometry as? SCNBox)?.length == 0.02 })
        let fullLengthBackingBox = try #require(fullLengthBacking.geometry as? SCNBox)
        #expect(abs(fullLengthBackingBox.width - (0.6 * 2.6 + 0.1)) < 0.01)

        // ...and restoring to Standard shrinks it back down again,
        // while Eddie remains standing there -- no rebuild the whole
        // time (frameNode/frameBox are the SAME objects throughout).
        state.changePictureSize(.standard)
        #expect(abs(frameBox.width - 0.7) < 0.001)
        let restoredBackfill = backfillNodes()
        #expect(restoredBackfill.count == 5)
        let restoredBacking = try #require(restoredBackfill.first { ($0.geometry as? SCNBox)?.length == 0.02 })
        let restoredBackingBox = try #require(restoredBacking.geometry as? SCNBox)
        #expect(abs(restoredBackingBox.width - 0.7) < 0.001)

        // Picture Light: THE PICTURE DOES NOT OWN A LIGHT -- OFF/ON is
        // derived from the existing independent pictureLights data.
        #expect(!state.pictureLightIsOn(pictureTarget))
        #expect(frameNode.childNode(withName: "pictureLight", recursively: false) == nil)
        state.setPictureLightOn(true)
        #expect(store.pictureLights.contains(WallFace(coord: coord, direction: direction)))
        #expect(state.pictureLightIsOn(pictureTarget))
        let light = try #require(frameNode.childNode(withName: "pictureLight", recursively: false))
        let lightSource = try #require(light.childNode(withName: "pictureLightSource", recursively: false))
        #expect(lightSource.light?.intensity == AuthoredLightKind.picture.intensity(level: 3))

        state.changePictureLightBrightness(by: 2)
        #expect(store.lightBrightnessLevel(.picture, direction: direction, at: coord) == 5)
        let brighterLight = try #require(frameNode.childNode(withName: "pictureLight", recursively: false))
        let brighterSource = try #require(brighterLight.childNode(withName: "pictureLightSource", recursively: false))
        #expect(brighterSource.light?.intensity == AuthoredLightKind.picture.intensity(level: 5))

        state.setPictureLightOn(false)
        #expect(!store.pictureLights.contains(WallFace(coord: coord, direction: direction)))
        #expect(frameNode.childNode(withName: "pictureLight", recursively: false) == nil)

        // Re-authoring the light, then deleting the Picture, must ALSO
        // remove that Picture Light -- an orphaned authored Picture
        // Light with no Picture is invalid data (Eddie's explicit
        // integrity rule), even though Picture never owned it.
        state.setPictureLightOn(true)
        #expect(store.pictureLights.contains(WallFace(coord: coord, direction: direction)))
        state.deletePicture()

        #expect(!store.hasPicture(direction, at: coord))
        #expect(!store.pictureLights.contains(WallFace(coord: coord, direction: direction)))
        #expect(state.selection == DecoratorTarget(floor: store.currentMazeID, coord: coord, kind: .wallSurface, direction: direction))
        var restoredWallTargets = 0
        scene.rootNode.enumerateChildNodes { node, _ in
            if let target = DecoratorTarget.read(node), target.kind == .wallSurface, target.coord == coord, target.direction == direction {
                restoredWallTargets += 1
            }
        }
        #expect(restoredWallTargets == 1)
        var remainingPictureTargets = 0
        scene.rootNode.enumerateChildNodes { node, _ in
            if DecoratorTarget.read(node) == pictureTarget { remainingPictureTargets += 1 }
        }
        #expect(remainingPictureTargets == 0)
        #expect(backfillNodes().isEmpty)

        // The restored wall is immediately a legal ADD -> Picture
        // target again, repeatedly, without ever rebuilding the scene.
        #expect(state.canAddPicture(DecoratorTarget(floor: store.currentMazeID, coord: coord, kind: .wallSurface, direction: direction)))
    }

    // Sept 24 (auto-fluorescent orientation): a freshly added fluorescent
    // fixture follows the corridor axis the cell actually opens along --
    // N/S for a straight north-south hallway, E/W for an east-west one --
    // rather than defaulting to .northSouth unconditionally. Junctions
    // (3+ open sides), dead ends (1 open side), non-cells, and cells that
    // already hold a fixture all keep the existing/default orientation.
    // The store is the real bundled floor 2, so this exercises the actual
    // maze data path, not synthesized geometry.
    @Test func autoFluorescentOrientationFollowsTheOpenCorridorAxisOfBundledCells() {
        let store = MazeStore()
        store.switchTo(id: 2)
        #expect(store.autoFluorescentOrientation(at: GridCoordinate(row: 1, col: 7)) == .northSouth)
        #expect(store.autoFluorescentOrientation(at: GridCoordinate(row: 4, col: 1)) == .eastWest)
        #expect(store.autoFluorescentOrientation(at: GridCoordinate(row: 4, col: 7)) == nil)
        #expect(store.autoFluorescentOrientation(at: GridCoordinate(row: 0, col: 7)) == nil)
        #expect(store.autoFluorescentOrientation(at: GridCoordinate(row: 20, col: 20)) == nil)
    }
}
