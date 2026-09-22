import SwiftUI
import SceneKit
import Combine
import ObjectiveC

private var decoratorIdentityKey: UInt8 = 0
private final class DecoratorIdentityBox: NSObject {
    let target: DecoratorTarget
    init(_ target: DecoratorTarget) { self.target = target }
}

/// Authored identity, independent of mesh names and the player's current cell.
/// Future object families can add kinds without changing child-hit resolution.
struct DecoratorTarget: Equatable {
    /// Sept 21 (Decorator Picture support): `.picture` is NOT a light --
    /// it deliberately does not participate in lightKind/level/
    /// changeBrightness/changeOrientation/move/deleteSelected below
    /// (each of those now explicitly requires .ceiling or .fluorescent),
    /// only in its own changePictureSize. Keeping it out of the light
    /// machinery is what keeps a picture selection from ever reading or
    /// writing lightBrightness data for its coord.
    ///
    /// Sept 21 (3D Decorator wall authoring): `.wallSurface` is the
    /// empty-wall counterpart to `.ceilingSurface` -- tagged on every
    /// ordinary ADDWall-built wall panel (see HallwayScene.
    /// buildWallPanel), always "exists" the same way ceilingSurface
    /// does, and is the only kind that currently offers ADD (Picture
    /// only, this pass -- see DecoratorState.addPicture). It
    /// deliberately does not participate in the light machinery either.
    /// Sept 21 (Floor Object placement, first pass): `.floorObject` tags
    /// a physical floor-standing object -- trash cans only, this pass --
    /// selectable in DECORATE the same way every other kind is. It
    /// participates in neither the light machinery (lightKind/level/
    /// changeBrightness/changeOrientation) nor Picture's own machinery;
    /// it gets its own small set of methods (floorPosition/
    /// changeFloorPosition/floorObjectOrientation/changeFloorOrientation)
    /// further down in this file.
    enum Kind: String { case ceilingSurface, ceiling, fluorescent, picture, wallSurface, missionSign, floorMap, floorObject }
    let floor: Int
    enum Location: Equatable { case grid(GridCoordinate), elevatorCeiling }
    let location: Location
    let kind: Kind
    /// Which wall face this target refers to. nil for every kind above
    /// except `.wallSurface` -- unlike ceiling/fluorescent/picture
    /// (each capped at one authored object per CELL, so a coordinate
    /// alone already identifies them uniquely -- see MazeStore's
    /// canPlaceMirror/canPlaceWallLight/canPlacePhotoBooth, which all
    /// key off coord alone), a single cell can have up to 4 solid
    /// walls, and an empty one needs its own direction to be
    /// distinguishable from its neighbors.
    let direction: Direction?

    init(floor: Int, coord: GridCoordinate, kind: Kind, direction: Direction? = nil) {
        self.init(floor: floor, location: .grid(coord), kind: kind, direction: direction)
    }

    init(floor: Int, location: Location, kind: Kind, direction: Direction? = nil) {
        self.floor = floor
        self.location = location
        self.kind = kind
        self.direction = direction
    }

    var coord: GridCoordinate? {
        if case .grid(let coord) = location { return coord }
        return nil
    }
    var isCab: Bool { location == .elevatorCeiling }
    var locationLabel: String {
        guard let coord else { return "Elevator cab · Center ceiling" }
        let base = "Floor \(floor) · Row \(coord.row), Column \(coord.col)"
        guard let direction else { return base }
        return base + " · \(direction.rawValue.capitalized) wall"
    }

    var supportsPictureLight: Bool { kind == .picture || kind == .missionSign || kind == .floorMap }

    var lightKind: AuthoredLightKind { kind == .fluorescent ? .fluorescent : .ceiling }
    var title: String {
        switch kind {
        case .ceilingSurface: return "Add ceiling light"
        case .ceiling: return "Ceiling Light"
        case .fluorescent: return "Fluorescent"
        case .picture: return "Picture"
        case .missionSign: return "Mission Statement"
        case .floorMap: return "Floor Map"
        case .wallSurface: return "Empty Wall"
        case .floorObject: return "Trash Can" // first pass: the only Floor Object kind
        }
    }

    func tag(_ node: SCNNode) {
        objc_setAssociatedObject(node, &decoratorIdentityKey, DecoratorIdentityBox(self), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func read(_ node: SCNNode) -> DecoratorTarget? {
        (objc_getAssociatedObject(node, &decoratorIdentityKey) as? DecoratorIdentityBox)?.target
    }

}

/// Owns only authoring selection and live-scene references. MazeStore remains
/// the source of truth; no parallel light values or scene-rebuild token.
final class DecoratorState: ObservableObject {
    @Published var enabled = false {
        didSet { selection = nil; if enabled { stopWalking?() } }
    }
    @Published var selection: DecoratorTarget?
    private weak var scene: SCNScene?
    private weak var store: MazeStore?
    private var floor: Int = 0
    var stopWalking: (() -> Void)?
    var canEditCab: () -> Bool = { false }
    /// Sept 21 (3D Decorator wall authoring): the one piece of live
    /// scene-build state DecoratorState itself has no other way to
    /// reach -- MazeStore doesn't know the current theme, and this
    /// class deliberately has no reference to ContentView's Coordinator
    /// or its WallThemeStore. Wired up alongside canEditCab/stopWalking
    /// above. See HallwayScene.effectiveWallImageName.
    var currentWallImageName: () -> String? = { nil }
    /// Sept 21 (3D Decorator wall authoring): after addPicture() below
    /// builds a live Picture, this registers it into the OTHER live
    /// state that already exists for every build-time Picture --
    /// Coordinator.pictureMaterials (so the ordinary in-world "Change
    /// Picture" menu can retexture it) and TapNavigationController's
    /// own picture bookkeeping (so walking up to it also offers that
    /// menu) -- plus appends any new wall/backing/strip materials this
    /// Picture's own construction created into Coordinator.wallMaterials
    /// (so a later theme cycle repaints them too, same as every other
    /// wall material). Wired up in ContentView.
    var registerAddedPicture: (_ coord: GridCoordinate, _ direction: Direction, _ material: SCNMaterial, _ newWallMaterials: [SCNMaterial]) -> Void = { _, _, _, _ in }
    /// Sept 21 (Picture Decorator complete pass): a live Picture Size
    /// change or a live Delete can each create fresh wall backfill
    /// materials (HallwayScene.buildPictureBackfill/buildWallPanel) the
    /// same way addPicture's own construction does -- this is that
    /// same "append into Coordinator.wallMaterials so a later theme
    /// cycle repaints them too" step, pulled out on its own rather than
    /// folded into registerAddedPicture above, since those two callers
    /// have no picture-registration/material bookkeeping of their own
    /// to do alongside it.
    var appendWallMaterials: (_ newWallMaterials: [SCNMaterial]) -> Void = { _ in }
    /// Sept 21 (Picture Decorator complete pass, Goal 4): the reverse
    /// of registerAddedPicture above -- after deletePicture() below
    /// restores the ordinary wall, this removes the deleted Picture
    /// from Coordinator.pictureMaterials and TapNavigationController's
    /// own picture bookkeeping (TapNavigationController.
    /// unregisterPicture), so no stale in-world "Change Picture" menu
    /// or material reference is left pointing at a coordinate that no
    /// longer has a Picture.
    var unregisterPicture: (_ coord: GridCoordinate) -> Void = { _ in }
    /// Sept 21 (Floor Object current-cell authoring): the ONE piece of
    /// live navigation state this class has no other way to reach --
    /// same shape as canEditCab/stopWalking above, wired up in
    /// ContentView. addFloorObject below reads this instead of holding
    /// a reference to TapNavigationController itself.
    var currentPlayerCell: () -> GridCoordinate? = { nil }
    /// Sept 21 (Floor Object current-cell authoring): after
    /// addFloorObject below builds a live Floor Object node, this
    /// registers it into TapNavigationController's objectKinds/
    /// objectNodes -- the same "hand the new live node to the
    /// navigation controller" step registerAddedPicture does for a
    /// live Picture, just for objects instead. Wired up in ContentView.
    var registerFloorObject: (_ kind: ObjectKind, _ coord: GridCoordinate, _ node: SCNNode) -> Void = { _, _, _ in }
    /// Sept 21 (current-cell Ceiling/Wall authoring): the player's
    /// current facing -- same shape/reason as currentPlayerCell above,
    /// wired up in ContentView. selectWallAtCurrentCell below reads
    /// this to translate player-relative Left/Right into an absolute
    /// Direction via Direction.left/right (MazeNavigation.swift's
    /// existing relative-turn convention), never a second one.
    var currentPlayerFacing: () -> Direction? = { nil }

    func attach(scene: SCNScene?, store: MazeStore) {
        self.scene = scene
        self.store = store
        floor = store.currentMazeID
        // makeUIView runs during a SwiftUI update. Clear old selection afterward.
        DispatchQueue.main.async { [weak self, weak scene] in
            guard let self, self.scene === scene else { return }
            self.selection = nil
        }
    }

    func select(at point: CGPoint, in view: SCNView) -> Bool {
        guard enabled, view.scene === scene, store?.currentMazeID == floor else { return false }
        // Only the nearest visible geometry counts. Never select through walls.
        guard let hit = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue,
                                                       .ignoreHiddenNodes: true]).first else { return false }
        var node: SCNNode? = hit.node
        while let current = node {
            if let target = DecoratorTarget.read(current), target.floor == floor {
                guard !target.isCab || canEditCab() else { return false }
                guard target.kind == .ceilingSurface || target.kind == .wallSurface || exists(target) else { return false }
                stopWalking?()
                selection = target
                return true
            }
            node = current.parent
        }
        return false
    }

    private func exists(_ target: DecoratorTarget) -> Bool {
        guard let store, target.floor == floor, store.currentMazeID == floor else { return false }
        if target.isCab {
            guard canEditCab(), cabMount != nil else { return false }
            switch target.kind {
            case .ceilingSurface: return true
            case .ceiling: return store.elevatorCabDecoration.ceilingFixture?.kind == .ceiling
            case .fluorescent: return store.elevatorCabDecoration.ceilingFixture?.kind == .fluorescent
            case .picture, .missionSign, .floorMap: return false
            case .wallSurface: return false
            case .floorObject: return false // no Floor Objects in the elevator cab
            }
        }
        guard let coord = target.coord else { return false }
        switch target.kind {
        case .ceiling: return store.spotlights.contains(coord)
        case .fluorescent: return store.fluorescentLights[coord] != nil
        case .ceilingSurface: return store.cells.contains(coord)
        case .picture: return store.pictures[coord] != nil
        case .missionSign: return store.missionSigns[coord] != nil
        case .floorMap: return store.floorMaps[coord] != nil
        case .wallSurface: return store.cells.contains(coord)
        case .floorObject: return store.objects[coord] == .trashCan // first pass: trash cans only
        }
    }

    private func nodes(for target: DecoratorTarget) -> [SCNNode] {
        var nodes: [SCNNode] = []
        scene?.rootNode.enumerateChildNodes { node, _ in
            if DecoratorTarget.read(node) == target { nodes.append(node) }
        }
        return nodes
    }

    private var cabMount: SCNNode? {
        scene?.rootNode.childNode(withName: "elevatorCabCeilingMount", recursively: true)
    }

    func level(_ target: DecoratorTarget) -> Int {
        if target.isCab { return store?.elevatorCabDecoration.ceilingFixture?.brightness ?? 3 }
        guard let coord = target.coord else { return 3 }
        return store?.lightBrightnessLevel(target.lightKind, at: coord) ?? 3
    }

    func orientation(_ target: DecoratorTarget) -> FluorescentOrientation {
        if target.isCab { return store?.elevatorCabDecoration.ceilingFixture?.orientation ?? .northSouth }
        guard let coord = target.coord else { return .northSouth }
        return store?.fluorescentLights[coord] ?? .northSouth
    }

    private func save(_ target: DecoratorTarget) {
        // Cab mutations persist immediately without saving or rebuilding a floor.
        if !target.isCab { store?.saveCurrentFloorAsOverride() }
    }

    private func place(_ target: DecoratorTarget, level: Int, orientation: FluorescentOrientation) {
        if target.isCab {
            store?.setElevatorCabDecoration(ElevatorCabDecoration(ceilingFixture: .init(
                kind: target.kind == .fluorescent ? .fluorescent : .ceiling,
                brightness: level, orientation: orientation)))
            return
        }
        guard let coord = target.coord else { return }
        if target.kind == .fluorescent {
            store?.placeFluorescent(orientation, at: coord, brightness: level)
        } else {
            store?.placeSpotlight(at: coord, brightness: level)
        }
    }

    private func remove(_ target: DecoratorTarget) {
        if target.isCab {
            store?.setElevatorCabDecoration(ElevatorCabDecoration())
            return
        }
        guard let coord = target.coord else { return }
        if target.kind == .fluorescent { store?.removeFluorescent(at: coord) }
        else { store?.removeSpotlight(at: coord) }
    }

    func changeBrightness(by delta: Int) {
        guard enabled, let target = selection, target.kind == .ceiling || target.kind == .fluorescent,
              exists(target), let store else { return }
        let range = target.lightKind.levelRange
        let next = min(range.upperBound, max(range.lowerBound, level(target) + delta))
        guard next != level(target) else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        store.snapshotForUndo()
        place(target, level: next, orientation: orientation(target))
        for node in liveNodes {
            node.enumerateHierarchy { child, _ in
                child.light?.intensity = target.lightKind.intensity(level: next)
            }
        }
        save(target)
    }

    func changeOrientation(_ orientation: FluorescentOrientation) {
        guard enabled, let target = selection, target.kind == .fluorescent,
              exists(target), let store, self.orientation(target) != orientation else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        store.snapshotForUndo()
        place(target, level: level(target), orientation: orientation)
        for node in liveNodes { node.eulerAngles.y = orientation == .eastWest ? .pi / 2 : 0 }
        save(target)
    }

    /// Sept 21 (Floor Object placement, first pass): reads this trash
    /// can's own authored placement straight off MazeStore (never a
    /// second/cached copy) -- a coordinate with no entry reads as
    /// FloorObjectPlacement()'s own default (center, north-south), via
    /// MazeStore.floorObjectPlacement(at:).
    func floorPosition(_ target: DecoratorTarget) -> FloorPosition {
        guard let coord = target.coord else { return .center }
        return store?.floorObjectPlacement(at: coord).position ?? .center
    }

    /// Deliberately its OWN accessor, not a reuse of the generic
    /// `orientation(_:)` above -- that one reads store.fluorescentLights,
    /// an entirely different authored property (a fluorescent fixture's
    /// own rotation) that happens to share the same FluorescentOrientation
    /// type. Reusing it here would silently read/write the wrong data
    /// for any cell that has both a fluorescent light AND a trash can.
    func floorObjectOrientation(_ target: DecoratorTarget) -> FluorescentOrientation {
        guard let coord = target.coord else { return .northSouth }
        return store?.floorObjectPlacement(at: coord).orientation ?? .northSouth
    }

    /// Sept 21 (Floor Object placement, first pass): live LEFT/CENTER/
    /// RIGHT move -- same "look up the live node(s), mutate position
    /// directly, no rebuild" shape changeOrientation above uses for
    /// live rotation. Deliberately skips store.snapshotForUndo(): this
    /// property isn't part of the existing undo-stack snapshot tuple
    /// (a larger change out of scope for this first pass -- see the
    /// task report), so snapshotting here would create a misleading
    /// checkpoint the Decorator's own Undo command couldn't actually
    /// restore.
    func changeFloorPosition(_ position: FloorPosition) {
        guard enabled, let target = selection, target.kind == .floorObject,
              exists(target), let store, let coord = target.coord,
              floorPosition(target) != position else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        let current = store.floorObjectPlacement(at: coord)
        store.setFloorObjectPlacement(FloorObjectPlacement(position: position, orientation: current.orientation), at: coord)
        let offset = HallwayScene.trashCanFloorOffset(position: position, orientation: current.orientation, cellSize: store.cellSize)
        let baseX = CGFloat(coord.col) * store.cellSize
        let baseZ = CGFloat(coord.row) * store.cellSize
        for node in liveNodes {
            node.position.x = Float(baseX + offset.dx)
            node.position.z = Float(baseZ + offset.dz)
        }
        save(target)
    }

    /// Same shape as changeFloorPosition above, for the object's
    /// authored hallway axis instead of its LEFT/CENTER/RIGHT slot --
    /// changing axis while already LEFT/RIGHT moves it live to the new
    /// axis' corresponding side (a CENTER object visibly stays put,
    /// since trashCanFloorOffset's own (0,0) doesn't depend on axis).
    func changeFloorOrientation(_ orientation: FluorescentOrientation) {
        guard enabled, let target = selection, target.kind == .floorObject,
              exists(target), let store, let coord = target.coord,
              floorObjectOrientation(target) != orientation else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        let current = store.floorObjectPlacement(at: coord)
        store.setFloorObjectPlacement(FloorObjectPlacement(position: current.position, orientation: orientation), at: coord)
        let offset = HallwayScene.trashCanFloorOffset(position: current.position, orientation: orientation, cellSize: store.cellSize)
        let baseX = CGFloat(coord.col) * store.cellSize
        let baseZ = CGFloat(coord.row) * store.cellSize
        for node in liveNodes {
            node.position.x = Float(baseX + offset.dx)
            node.position.z = Float(baseZ + offset.dz)
        }
        save(target)
    }

    func pictureSize(_ target: DecoratorTarget) -> PictureSize {
        guard let coord = target.coord else { return .standard }
        return store?.pictureSize(at: coord) ?? .standard
    }

    /// Sept 21 (Picture Decorator complete pass): a `.picture` target
    /// never carries its own `direction` (see DecoratorTarget's own doc
    /// comment -- only `.wallSurface` does, since every other kind is
    /// capped at one authored object per coordinate), so every method
    /// below that needs this Picture's wall face -- for
    /// pictureLights/canPlacePictureLight/placePictureLight lookups, or
    /// for rebuilding its backfill/wall -- recovers it from the
    /// authoritative store, via MazeStore's own existing
    /// pictureDirection(at:), rather than reading store.pictures
    /// directly a second way.
    private func pictureDirection(_ target: DecoratorTarget) -> Direction? {
        guard let coord = target.coord else { return nil }
        switch target.kind {
        case .picture: return store?.pictureDirection(at: coord)
        case .missionSign: return store?.missionSigns[coord]
        case .floorMap: return store?.floorMaps[coord]
        default: return nil
        }
    }

    /// Sept 21 (Picture Decorator complete pass, Goal 3): THE PICTURE
    /// DOES NOT OWN A LIGHT. This reads derived state, straight off the
    /// existing, independent `pictureLights` authored-light data
    /// (MazeStore.canPlacePictureLight/placePictureLight/
    /// removePictureLight) -- ON means an ordinary Picture Light
    /// already exists at this Picture's own coordinate/direction, OFF
    /// means it doesn't. No second source of truth (no
    /// `picture.hasLight` or equivalent) is introduced anywhere here.
    func pictureLightIsOn(_ target: DecoratorTarget) -> Bool {
        guard let coord = target.coord, let direction = pictureDirection(target) else { return false }
        return store?.pictureLights[coord] == direction
    }

    func pictureLightBrightness(_ target: DecoratorTarget) -> Int {
        guard let coord = target.coord else { return 3 }
        return store?.lightBrightnessLevel(.picture, at: coord) ?? 3
    }

    /// Sept 21 (Picture Decorator complete pass, Goal 3): OFF -> ON
    /// persists an ordinary Picture Light (MazeStore.placePictureLight
    /// -- the SAME independent authored-light call build-time
    /// construction and the Floor Editor both already use) AND adds the
    /// SAME real HallwayScene.makePictureLight fixture/SCNLight this
    /// Picture would already have if it had been authored with a light
    /// from the start -- recovering this Picture's own current
    /// panelWidth/panelHeight from its live frame box (frameBox.width/
    /// height are always exactly panelWidth/panelHeight + 0.1, by
    /// construction) so the fixture is sized to match. ON -> OFF is the
    /// exact reverse: MazeStore.removePictureLight, then remove the
    /// live "pictureLight" child node. No rebuild, no teleport, live on
    /// this exact node -- same shape as changeBrightness/
    /// changeOrientation elsewhere in this file.
    func setPictureLightOn(_ on: Bool) {
        guard enabled, let target = selection, target.supportsPictureLight,
              exists(target), let coord = target.coord, let direction = pictureDirection(target),
              let store else { return }
        guard pictureLightIsOn(target) != on else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        store.snapshotForUndo()
        if on {
            let brightness = store.lightBrightnessLevel(.picture, at: coord)
            store.placePictureLight(direction, at: coord, brightness: brightness)
            for frame in liveNodes {
                guard frame.childNode(withName: "pictureLight", recursively: false) == nil,
                      let frameBox = frame.geometry as? SCNBox else { continue }
                let padding: CGFloat = target.kind == .floorMap ? 0.14 : (target.kind == .missionSign ? 0.12 : 0.1)
                let panelWidth = frameBox.width - padding
                let panelHeight = frameBox.height - padding
                frame.addChildNode(HallwayScene.makePictureLight(panelWidth: panelWidth, panelHeight: panelHeight, level: brightness))
            }
        } else {
            store.removePictureLight(at: coord)
            for frame in liveNodes {
                frame.childNode(withName: "pictureLight", recursively: false)?.removeFromParentNode()
            }
        }
        save(target)
    }

    /// Sept 21 (Picture Decorator complete pass, Goal 3): re-authors the
    /// SAME ordinary Picture Light at a new 1-5 level (MazeStore.
    /// placePictureLight has no re-author bypass, but none is needed --
    /// canPlacePictureLight's own guard only depends on cells/neighbor/
    /// pictures[coord]?.direction, none of which change on a
    /// brightness-only re-call) and mutates the live SCNLight's
    /// intensity in place via enumerateHierarchy, exactly like
    /// changeBrightness does for ceiling/fluorescent lights elsewhere
    /// in this file -- "should feel exactly like the live dimmer
    /// behavior already working elsewhere in Decorator."
    func changePictureLightBrightness(by delta: Int) {
        guard enabled, let target = selection, target.supportsPictureLight,
              exists(target), pictureLightIsOn(target),
              let coord = target.coord, let direction = pictureDirection(target), let store else { return }
        let range = AuthoredLightKind.picture.levelRange
        let current = pictureLightBrightness(target)
        let next = min(range.upperBound, max(range.lowerBound, current + delta))
        guard next != current else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        store.snapshotForUndo()
        store.placePictureLight(direction, at: coord, brightness: next)
        for frame in liveNodes {
            frame.childNode(withName: "pictureLight", recursively: false)?.enumerateHierarchy { child, _ in
                child.light?.intensity = AuthoredLightKind.picture.intensity(level: next)
            }
        }
        save(target)
    }

    /// Live Decorator resize (Sept 21, Picture Size; rewritten as part
    /// of the Picture Decorator complete pass, Goal 1) -- mutates the
    /// SAME SCNBox/SCNPlane dimensions buildPictureNode itself set,
    /// exactly like changeBrightness mutates a light's intensity in
    /// place: no scene rebuild, no player movement. Recovers this
    /// picture's aspect-clamped BASE (pre-scale) dimensions from its
    /// own live frame box and its CURRENT authored size, rather than
    /// stashing a separate value on the node -- the frame box's
    /// width/height are, by construction, always exactly
    /// base*currentSize.scale (+0.1 frame padding), so that division is
    /// exact and self-consistent across any number of repeated resizes.
    /// UNLIKE the original version of this method, the wall backfill
    /// (backing panel + 4 door-frame strips) is no longer fixed at the
    /// largest authored size forever -- it's found via
    /// PictureBackfillTarget, removed, and rebuilt at the NEW size
    /// through HallwayScene.buildPictureBackfill, so Standard -> Full
    /// Length -> Standard genuinely expands and then restores the
    /// surrounding wall geometry, not just the frame/photo inside it.
    /// Any existing Picture Light is also removed and rebuilt at the
    /// new panel dimensions (same brightness level), so the fixture
    /// stays correctly scaled to its Picture.
    func changePictureSize(_ size: PictureSize) {
        guard enabled, let target = selection, target.kind == .picture,
              exists(target), let coord = target.coord, let direction = pictureDirection(target),
              let store, let scene else { return }
        let currentSize = store.pictureSize(at: coord)
        guard currentSize != size else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        guard let hallwayRoot = scene.rootNode.childNode(withName: "hallwaySceneRoot", recursively: false) else { return }
        store.snapshotForUndo()
        store.setPictureSize(size, at: coord)
        var newPanelWidth: CGFloat = 0
        var newPanelHeight: CGFloat = 0
        for frame in liveNodes {
            guard let frameBox = frame.geometry as? SCNBox else { continue }
            let baseWidth = (frameBox.width - 0.1) / currentSize.scale
            let baseHeight = (frameBox.height - 0.1) / currentSize.scale
            newPanelWidth = baseWidth * size.scale
            newPanelHeight = baseHeight * size.scale
            frameBox.width = newPanelWidth + 0.1
            frameBox.height = newPanelHeight + 0.1
            if let plane = frame.childNode(withName: "authoredPicturePlane", recursively: false),
               let planeGeo = plane.geometry as? SCNPlane {
                planeGeo.width = newPanelWidth
                planeGeo.height = newPanelHeight
            }
            if let light = frame.childNode(withName: "pictureLight", recursively: false) {
                light.removeFromParentNode()
                let level = store.lightBrightnessLevel(.picture, at: coord)
                frame.addChildNode(HallwayScene.makePictureLight(panelWidth: newPanelWidth, panelHeight: newPanelHeight, level: level))
            }
        }

        let backfillTarget = PictureBackfillTarget(floor: floor, coord: coord, direction: direction)
        var oldBackfillNodes: [SCNNode] = []
        hallwayRoot.enumerateChildNodes { node, _ in
            if PictureBackfillTarget.read(node) == backfillTarget { oldBackfillNodes.append(node) }
        }
        for node in oldBackfillNodes { node.removeFromParentNode() }

        if newPanelWidth > 0, newPanelHeight > 0 {
            let half = store.cellSize / 2
            let picX = CGFloat(coord.col) * store.cellSize
            let picZ = CGFloat(coord.row) * store.cellSize
            let wx: CGFloat
            let wz: CGFloat
            switch direction {
            case .north: (wx, wz) = (picX, picZ - half)
            case .south: (wx, wz) = (picX, picZ + half)
            case .east: (wx, wz) = (picX + half, picZ)
            case .west: (wx, wz) = (picX - half, picZ)
            }
            var newWallMaterials: [SCNMaterial] = []
            HallwayScene.buildPictureBackfill(direction: direction, wallCenterX: wx, wallCenterZ: wz, coord: coord, floorNumber: floor, reservedWidth: newPanelWidth, reservedHeight: newPanelHeight, cellSize: store.cellSize, wallHeight: store.wallHeight, effectiveWallImageName: currentWallImageName(), root: hallwayRoot, wallMaterials: &newWallMaterials)
            appendWallMaterials(newWallMaterials)
        }

        save(target)
    }

    func deleteSelected() {
        guard enabled, let target = selection, target.kind == .ceiling || target.kind == .fluorescent,
              exists(target), let store else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        store.snapshotForUndo()
        remove(target)
        for node in liveNodes { node.removeFromParentNode() }
        selection = nil
        save(target)
    }

    func canPlace(at coord: GridCoordinate) -> Bool {
        guard let store, store.currentMazeID == floor else { return false }
        return store.cells.contains(coord) && !store.spotlights.contains(coord) && store.fluorescentLights[coord] == nil
    }

    func canMove(_ direction: Direction) -> Bool {
        guard let target = selection, target.kind == .ceiling || target.kind == .fluorescent, exists(target), let coord = target.coord else { return false }
        return canPlace(at: GridCoordinate(row: coord.row + direction.delta.row,
                                          col: coord.col + direction.delta.col))
    }

    func move(_ direction: Direction) {
        guard enabled, canMove(direction), let target = selection, let coord = target.coord, let store else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        let destination = GridCoordinate(row: coord.row + direction.delta.row,
                                         col: coord.col + direction.delta.col)
        let moved = DecoratorTarget(floor: floor, coord: destination, kind: target.kind)
        let brightness = level(target)
        let orientation = orientation(target)
        store.snapshotForUndo()
        remove(target)
        place(moved, level: brightness, orientation: orientation)
        for node in liveNodes {
            node.position.x += Float(direction.delta.col) * Float(store.cellSize)
            node.position.z += Float(direction.delta.row) * Float(store.cellSize)
            moved.tag(node)
        }
        selection = moved
        save(target)
    }

    func canAdd(_ target: DecoratorTarget) -> Bool {
        guard exists(target) else { return false }
        if target.isCab { return store?.elevatorCabDecoration.ceilingFixture == nil }
        guard let coord = target.coord else { return false }
        return canPlace(at: coord)
    }

    func add(_ kind: DecoratorTarget.Kind) {
        guard enabled, let target = selection, target.kind == .ceilingSurface,
              kind == .ceiling || kind == .fluorescent, canAdd(target),
              let store, let scene else { return }
        if target.isCab {
            guard let mount = cabMount else { return }
            let fixture = ElevatorCabDecoration.Fixture(kind: kind == .fluorescent ? .fluorescent : .ceiling)
            let node = HallwayScene.makeElevatorCabFixture(fixture, cellSize: store.cellSize, floorNumber: floor)
            store.snapshotForUndo()
            store.setElevatorCabDecoration(ElevatorCabDecoration(ceilingFixture: fixture))
            mount.addChildNode(node)
            selection = DecoratorTarget.read(node)
            return
        }
        guard let coord = target.coord else { return }
        let added = DecoratorTarget(floor: floor, coord: coord, kind: kind)
        let node = kind == .fluorescent
            ? HallwayScene.makeFluorescentLight(orientation: .northSouth, level: 3, cellSize: store.cellSize)
            : HallwayScene.makeAuthoredCeilingFixture(cellSize: store.cellSize, level: 3)
        node.position = SCNVector3(Float(coord.col) * Float(store.cellSize), Float(store.wallHeight),
                                  Float(coord.row) * Float(store.cellSize))
        added.tag(node)
        store.snapshotForUndo()
        place(added, level: 3, orientation: .northSouth)
        scene.rootNode.addChildNode(node)
        selection = added
        save(target)
    }

    /// Sept 21 (3D Decorator wall authoring, Pass 3). Legality for a
    /// live wall-tap "ADD -> Picture" -- deliberately NOT
    /// placePicture's own looser guard (it only ever checked
    /// roomDoors/mirrors/cells, fine for the Floor Editor's
    /// paint-a-legal-cell flow, not enough for a runtime wall tap that
    /// must also refuse a wall that isn't solid or is already claimed
    /// by another wall-mounted object -- see MazeStore.canPlacePicture's
    /// own doc comment).
    func canAddPicture(_ target: DecoratorTarget) -> Bool {
        guard enabled, target.kind == .wallSurface, let store, let coord = target.coord, let direction = target.direction else { return false }
        return store.canPlacePicture(direction, at: coord)
    }

    /// Sept 21 (3D Decorator wall authoring, Pass 3): tap an empty
    /// ordinary wall -> ADD -> Picture. Standard size, no explicit
    /// image selection -- same default a build-time Picture with no
    /// explicit selection gets. Mirrors add(_:)'s existing shape
    /// (snapshot -> mutate store -> build the live node -> tag it ->
    /// select it -> save), but a wall face additionally has to remove
    /// the exact ordinary wall panel that would never have been built
    /// had this Picture existed when the floor was originally
    /// constructed (found via `nodes(for:)`, the SAME lookup already
    /// used everywhere else in this file, since buildWallPanel tags
    /// that panel with this very target) and then build the Picture
    /// through HallwayScene.buildPictureNode -- the SAME static method
    /// HallwayScene.build(fromMaze:...) itself now calls (see that
    /// file's Sept 21 MARK section), not a second implementation of it.
    func addPicture() {
        guard enabled, let target = selection, target.kind == .wallSurface,
              let coord = target.coord, let direction = target.direction,
              canAddPicture(target), let store, let scene else { return }
        guard let hallwayRoot = scene.rootNode.childNode(withName: "hallwaySceneRoot", recursively: false) else { return }
        let wallNodes = nodes(for: target)
        guard !wallNodes.isEmpty else { return }

        let baseTexture: UIImage
        if store.picturesUseCameraRoll {
            // Same "Loading photo…" placeholder build(fromMaze:...) shows
            // every camera-roll picture until PhotoRollProvider resolves.
            baseTexture = HallwayScene.mirrorPlaceholder("Loading photo…")
        } else {
            baseTexture = HallwayScene.randomPictureImage(caller: "decorator live add floor \(floor) coord \(coord) wall \(direction)") ?? HallwayScene.mirrorPlaceholder("Photo unavailable")
        }
        let texture = HallwayScene.framedPhoto(baseTexture)

        let half = store.cellSize / 2
        let picX = CGFloat(coord.col) * store.cellSize
        let picZ = CGFloat(coord.row) * store.cellSize
        let wx: CGFloat
        let wz: CGFloat
        switch direction {
        case .north: (wx, wz) = (picX, picZ - half)
        case .south: (wx, wz) = (picX, picZ + half)
        case .east: (wx, wz) = (picX + half, picZ)
        case .west: (wx, wz) = (picX - half, picZ)
        }

        store.snapshotForUndo()
        store.placePicture(direction, at: coord, size: .standard)
        for node in wallNodes { node.removeFromParentNode() }

        var newWallMaterials: [SCNMaterial] = []
        let (material, frameNode) = HallwayScene.buildPictureNode(direction: direction, wallCenterX: wx, wallCenterZ: wz, texture: texture, backfillWall: true, scale: PictureSize.standard.scale, pictureLightLevel: nil, coord: coord, floorNumber: floor, cellSize: store.cellSize, wallHeight: store.wallHeight, effectiveWallImageName: currentWallImageName(), root: hallwayRoot, wallMaterials: &newWallMaterials)
        DecoratorTarget(floor: floor, coord: coord, kind: .picture).tag(frameNode)
        registerAddedPicture(coord, direction, material, newWallMaterials)

        if store.picturesUseCameraRoll {
            PhotoRollProvider.shared.randomImages(count: 1, caller: "decorator live add floor \(floor) coord \(coord) wall \(direction)") { [weak material] _, image in
                guard let material else { return }
                material.diffuse.contents = image.map { HallwayScene.framedPhoto($0) } ?? HallwayScene.mirrorPlaceholder("Photo unavailable")
            }
        }

        selection = DecoratorTarget(floor: floor, coord: coord, kind: .picture)
        save(target)
    }

    /// Sept 21 (Floor Object current-cell authoring): the catalog
    /// behind the small ADD menu beside DECORATE/DONE (DecoratorOverlay,
    /// below in this file). Deliberately just an extensible dispatch
    /// key, not a generalized object registry -- Eddie: "avoid
    /// hard-wiring the BUTTON itself as a Trash Can button," but "do
    /// NOT build speculative systems" for anything beyond today's one
    /// item. Adding a second Floor Object later means one more case
    /// here and one more branch in addFloorObject below, nothing
    /// structural.
    enum FloorObjectCatalogItem: CaseIterable, Hashable {
        case trashCan

        var title: String {
            switch self {
            case .trashCan: return "Trash Can"
            }
        }

        fileprivate var kind: ObjectKind {
            switch self {
            case .trashCan: return .trashCan
            }
        }
    }

    /// Sept 21 (Floor Object current-cell authoring): whether ADD ->
    /// Floor Object -> <item> would succeed right now -- DECORATE must
    /// be on, the player's current cell must be known (currentPlayerCell,
    /// wired from ContentView) and open, and -- the existing
    /// one-object-per-cell data model, MazeStore.objects is keyed by a
    /// single GridCoordinate -- empty. Backs the menu item's own
    /// .disabled(...) in DecoratorOverlay, so an occupied/unknown
    /// current cell refuses cleanly instead of silently overwriting
    /// whatever's already there.
    func canAddFloorObjectAtCurrentCell() -> Bool {
        guard enabled, let store, let coord = currentPlayerCell() else { return false }
        return store.cells.contains(coord) && store.objects[coord] == nil
    }

    /// Sept 21 (Floor Object current-cell authoring): the world-tap-free
    /// entrance for creating a Floor Object -- tap ADD (beside DONE) ->
    /// Floor Object -> <item>, no trip to the Floor Editor. Same overall
    /// shape as addPicture() above (snapshot -> mutate store -> build
    /// the live node -> tag/register it -> select it -> save), except
    /// the coordinate comes from the player's OWN current cell
    /// (currentPlayerCell) rather than a tapped DecoratorTarget, and the
    /// live node is built through HallwayScene.buildTrashCanNode -- the
    /// SAME static method the per-cell scene-build loop itself now
    /// calls (see that method's own doc comment) -- rather than a
    /// second implementation. Refuses cleanly (no-op) if the cell
    /// already holds anything, per canAddFloorObjectAtCurrentCell above
    /// -- this pass doesn't migrate the one-object-per-cell data model.
    /// Explicitly authors the default FloorObjectPlacement (CENTER /
    /// north-south) rather than relying on floorObjectPlacement(at:)'s
    /// own missing-entry default, so the authored data is unambiguous
    /// from the moment this object exists.
    func addFloorObject(_ item: FloorObjectCatalogItem) {
        guard canAddFloorObjectAtCurrentCell(), let store, let coord = currentPlayerCell(), let scene else { return }
        guard let hallwayRoot = scene.rootNode.childNode(withName: "hallwaySceneRoot", recursively: false) else { return }
        store.snapshotForUndo()
        store.placeObject(item.kind, at: coord)
        let placement = FloorObjectPlacement()
        store.setFloorObjectPlacement(placement, at: coord)
        let node = HallwayScene.buildTrashCanNode(at: coord, cellSize: store.cellSize, floorNumber: floor, placement: placement)
        hallwayRoot.addChildNode(node)
        registerFloorObject(item.kind, coord, node)
        let target = DecoratorTarget(floor: floor, coord: coord, kind: .floorObject)
        selection = target
        save(target)
    }

    /// Sept 21 (current-cell Ceiling authoring): the catalog behind
    /// "+" -> Ceiling, same extensible-dispatch-key shape as
    /// FloorObjectCatalogItem above -- one case today (Eddie asked for
    /// Fluorescent Light only, not the plain non-fluorescent Ceiling
    /// Light add(_:) also supports), a second case later means one more
    /// case here and one more switch branch below, nothing structural.
    enum CeilingObjectCatalogItem: CaseIterable, Hashable {
        case fluorescent

        var title: String {
            switch self {
            case .fluorescent: return "Fluorescent Light"
            }
        }
    }

    /// Sept 21 (current-cell Ceiling authoring): whether "+" -> Ceiling
    /// -> <item> would succeed right now -- reuses canAdd(_:) UNCHANGED
    /// (exists(target) + canPlace(at:), the SAME legality a world tap
    /// on this cell's ceiling already goes through), just keyed off the
    /// player's current cell instead of a tapped DecoratorTarget. Backs
    /// the menu item's own .disabled(...) in DecoratorOverlay.
    func canAddCeilingObjectAtCurrentCell(_ item: CeilingObjectCatalogItem) -> Bool {
        guard enabled, let coord = currentPlayerCell() else { return false }
        switch item {
        case .fluorescent: return canAdd(DecoratorTarget(floor: floor, coord: coord, kind: .ceilingSurface))
        }
    }

    /// Sept 21 (current-cell Ceiling authoring): the "+" -> Ceiling ->
    /// Fluorescent Light entrance -- builds the EXACT .ceilingSurface
    /// DecoratorTarget a world tap on the current cell's ceiling would
    /// produce, selects it (same as select(at:in:) does for a real
    /// tap), then calls the EXISTING add(_:) UNCHANGED. add(_:) does
    /// everything else: build the live fluorescent node, tag it, author
    /// it (brightness 3, north-south, MazeStore.placeFluorescent),
    /// persist, and select the new fixture -- opening the SAME
    /// fluorescent inspector (orientation/brightness/move/delete) a
    /// world-tapped one already gets. No new construction, no new
    /// inspector -- this function's only job is supplying the
    /// coordinate add(_:) would otherwise get from a tap.
    func addCeilingObjectAtCurrentCell(_ item: CeilingObjectCatalogItem) {
        guard canAddCeilingObjectAtCurrentCell(item), let coord = currentPlayerCell() else { return }
        switch item {
        case .fluorescent:
            selection = DecoratorTarget(floor: floor, coord: coord, kind: .ceilingSurface)
            add(.fluorescent)
        }
    }

    /// Sept 21 (current-cell Wall authoring): the catalog behind "+" ->
    /// Wall -- Left/Right are PLAYER-relative (Direction.left/right on
    /// their current facing, MazeNavigation.swift's existing
    /// relative-turn convention -- never a second coordinate system),
    /// translated to an absolute Direction only at the moment of use
    /// (absoluteDirection(for:) below), never exposed as N/E/S/W to
    /// Eddie in this flow.
    enum WallSide: CaseIterable, Hashable {
        case left, right

        var title: String {
            switch self {
            case .left: return "Left Wall"
            case .right: return "Right Wall"
            }
        }
    }

    private func absoluteDirection(for side: WallSide) -> Direction? {
        guard let facing = currentPlayerFacing() else { return nil }
        switch side {
        case .left: return facing.left
        case .right: return facing.right
        }
    }

    /// Sept 21 (current-cell Wall authoring): whether "+" -> Wall ->
    /// Left/Right Wall would succeed right now -- reuses
    /// canAddPicture's own underlying legality check
    /// (store.canPlacePicture), the ONLY existing "is this an
    /// available ordinary wall surface" rule this codebase has (solid,
    /// not a door/opening/existing picture/mission sign/map/mirror/
    /// other wall-mounted object -- see that method's own doc
    /// comment). Backs the Left Wall/Right Wall menu items' own
    /// .disabled(...) in DecoratorOverlay.
    func canSelectWallAtCurrentCell(_ side: WallSide) -> Bool {
        guard enabled, let store, let coord = currentPlayerCell(), let direction = absoluteDirection(for: side) else { return false }
        return store.canPlacePicture(direction, at: coord)
    }

    /// Sept 21 (current-cell Wall authoring): the "+" -> Wall ->
    /// Left/Right Wall entrance. Deliberately does NOT create a Picture
    /// or any new UI -- it builds the EXACT .wallSurface DecoratorTarget
    /// (title "Empty Wall") a world tap on that ordinary wall panel
    /// would produce and simply assigns it to `selection`, exactly what
    /// select(at:in:) itself does for a real tap. DecoratorOverlay's
    /// existing .wallSurface branch (Button("Add Picture") {
    /// state.addPicture() }.disabled(!state.canAddPicture(target)))
    /// then renders automatically -- Eddie taps "Add Picture" there
    /// himself, running the completely unchanged existing Picture
    /// creation/details flow. This function's only job is selecting the
    /// right wall; addPicture() (above in this file) is untouched.
    func selectWallAtCurrentCell(_ side: WallSide) {
        guard canSelectWallAtCurrentCell(side), let coord = currentPlayerCell(), let direction = absoluteDirection(for: side) else { return }
        selection = DecoratorTarget(floor: floor, coord: coord, kind: .wallSurface, direction: direction)
    }

    /// Sept 21 (Picture Decorator complete pass, Goal 4): tap an
    /// existing Picture -> DELETE PICTURE -> the Picture disappears
    /// immediately, the ordinary wall is restored, no rebuild/floor
    /// reload/teleport, player/camera stay exactly where they are.
    /// Mirrors addPicture()'s own shape in reverse: find every live
    /// node for this target (frame, tagged via DecoratorTarget) and
    /// its backfill (backing + strips, tagged via
    /// PictureBackfillTarget) -> mutate the store -> remove those
    /// nodes -> build the ordinary wall panel through the SAME
    /// HallwayScene.buildWallPanel static method build(fromMaze:...)
    /// itself uses (which already tags its own result `.wallSurface`,
    /// so the restored wall is immediately a valid ADD -> Picture
    /// target again, at this exact floor+coord+direction) -> unregister
    /// Coordinator/TapNavigationController bookkeeping -> select the
    /// restored wall -> save.
    ///
    /// Deliberate integrity rule (Eddie, Sept 21): if this Picture
    /// currently has a Picture Light, it is ALSO removed here -- NOT
    /// because Picture owns the light (it doesn't; see
    /// pictureLightIsOn's own doc comment), but because a Picture
    /// Light's placement is only ever legal when a Picture exists at
    /// its exact coordinate/direction (MazeStore.canPlacePictureLight),
    /// so leaving one authored after its Picture is deleted would be
    /// invalid/orphaned data. This is maintaining a valid authored
    /// state, not an ownership/cascade framework -- nothing else in
    /// this file generalizes a delete into removing other independent
    /// objects.
    func deletePicture() {
        guard enabled, let target = selection, target.kind == .picture,
              exists(target), let coord = target.coord, let direction = pictureDirection(target),
              let store, let scene else { return }
        guard let hallwayRoot = scene.rootNode.childNode(withName: "hallwaySceneRoot", recursively: false) else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }

        let backfillTarget = PictureBackfillTarget(floor: floor, coord: coord, direction: direction)
        var backfillNodes: [SCNNode] = []
        hallwayRoot.enumerateChildNodes { node, _ in
            if PictureBackfillTarget.read(node) == backfillTarget { backfillNodes.append(node) }
        }

        let half = store.cellSize / 2
        let picX = CGFloat(coord.col) * store.cellSize
        let picZ = CGFloat(coord.row) * store.cellSize
        let wx: CGFloat
        let wz: CGFloat
        let panelWidth: CGFloat
        let panelLength: CGFloat
        switch direction {
        case .north: (wx, wz, panelWidth, panelLength) = (picX, picZ - half, store.cellSize, 0.1)
        case .south: (wx, wz, panelWidth, panelLength) = (picX, picZ + half, store.cellSize, 0.1)
        case .east: (wx, wz, panelWidth, panelLength) = (picX + half, picZ, 0.1, store.cellSize)
        case .west: (wx, wz, panelWidth, panelLength) = (picX - half, picZ, 0.1, store.cellSize)
        }

        store.snapshotForUndo()
        if store.pictureLights[coord] == direction {
            store.removePictureLight(at: coord)
        }
        store.removePicture(at: coord)

        for node in liveNodes { node.removeFromParentNode() }
        for node in backfillNodes { node.removeFromParentNode() }

        var newWallMaterials: [SCNMaterial] = []
        HallwayScene.buildWallPanel(coord: coord, direction: direction, width: panelWidth, length: panelLength, x: wx, z: wz, wallHeight: store.wallHeight, effectiveWallImageName: currentWallImageName(), floorNumber: floor, root: hallwayRoot, wallMaterials: &newWallMaterials)
        appendWallMaterials(newWallMaterials)
        unregisterPicture(coord)

        selection = DecoratorTarget(floor: floor, coord: coord, kind: .wallSurface, direction: direction)
        save(target)
    }
}

struct DecoratorOverlay: View {
    @ObservedObject var state: DecoratorState
    @ObservedObject var store: MazeStore

    /// Sept 21 (Picture Decorator complete pass, Goal 2): backs the two
    /// picker sheets below -- same "capture the target coord into its
    /// own @State at button-press time" shape PictureChangeMenuHost
    /// (PictureChangeMenu.swift) already uses for the in-world Change
    /// Picture menu, so a sheet's completion handler never depends on
    /// state.selection still being the same target by the time the
    /// person finishes picking.
    @State private var pictureSheetTarget: GridCoordinate?
    @State private var showSystemPhotoPicker = false
    @State private var showHallwaysArtPicker = false

    @ViewBuilder
    private func pictureLightControls(_ target: DecoratorTarget) -> some View {
        Text("Picture Light").font(.caption).foregroundStyle(.secondary)
        HStack {
            Button(state.pictureLightIsOn(target) ? "ON" : "OFF") {
                state.setPictureLightOn(!state.pictureLightIsOn(target))
            }
            .tint(state.pictureLightIsOn(target) ? .pink : nil)
            if state.pictureLightIsOn(target) {
                Button { state.changePictureLightBrightness(by: -1) } label: { Image(systemName: "minus.circle.fill") }
                    .disabled(state.pictureLightBrightness(target) == AuthoredLightKind.picture.levelRange.lowerBound)
                Text("\(state.pictureLightBrightness(target)) / \(AuthoredLightKind.picture.levelRange.upperBound)").monospacedDigit()
                Button { state.changePictureLightBrightness(by: 1) } label: { Image(systemName: "plus.circle.fill") }
                    .disabled(state.pictureLightBrightness(target) == AuthoredLightKind.picture.levelRange.upperBound)
            }
        }.font(.caption)
    }

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Button(state.enabled ? "DECORATING · Done" : "DECORATE") { state.enabled.toggle() }
                    .font(.system(size: 12, weight: .bold))
                    .padding(10)
                    .background(state.enabled ? Color.orange : Color.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
                // Sept 21 (current-cell authoring front door): the
                // explicit authoring entrance -- "ADD SOMETHING TO THE
                // CELL I AM CURRENTLY STANDING IN" -- Eddie was clear
                // this must NOT be a tap on the empty 3D world (world
                // taps already mean movement), so it's this small
                // button beside DONE instead, visually subordinate (a
                // plain icon, no capsule/color of its own) and present
                // ONLY while DECORATE is active. Three top-level
                // categories -- Floor/Ceiling/Wall -- each a nested
                // Menu over its own small CaseIterable catalog
                // (FloorObjectCatalogItem/CeilingObjectCatalogItem/
                // WallSide, all defined above in this file), so a
                // future item in any category is one more case + one
                // more switch branch, never a redesign of this menu.
                // Every leaf here reuses an existing authoring system
                // (Floor Object placement, fluorescent add(_:), the
                // Empty Wall -> Add Picture flow) -- nothing here
                // constructs new authored content on its own.
                if state.enabled {
                    Menu {
                        Menu("Floor") {
                            ForEach(DecoratorState.FloorObjectCatalogItem.allCases, id: \.self) { item in
                                Button(item.title) { state.addFloorObject(item) }
                                    .disabled(!state.canAddFloorObjectAtCurrentCell())
                            }
                        }
                        Menu("Ceiling") {
                            ForEach(DecoratorState.CeilingObjectCatalogItem.allCases, id: \.self) { item in
                                Button(item.title) { state.addCeilingObjectAtCurrentCell(item) }
                                    .disabled(!state.canAddCeilingObjectAtCurrentCell(item))
                            }
                        }
                        Menu("Wall") {
                            ForEach(DecoratorState.WallSide.allCases, id: \.self) { side in
                                Button(side.title) { state.selectWallAtCurrentCell(side) }
                                    .disabled(!state.canSelectWallAtCurrentCell(side))
                            }
                        }
                    } label: {
                        // Sept 21 (visual polish -- Eddie, on device:
                        // the "+" was functionally right but far too
                        // small next to DECORATING . Done). Plain
                        // "plus" (not "plus.circle.fill", which already
                        // draws its own circle and would double up with
                        // the Circle() background below) on an explicit
                        // orange Circle matching the pill's own
                        // Color.orange -- same visual language, just a
                        // compact circular control instead of a second
                        // long pill. 34x34 is a deliberate explicit
                        // frame (not padding-derived) so the shape stays
                        // a perfect circle regardless of glyph metrics,
                        // sized to match DECORATING . Done's own
                        // rendered height (12pt bold text + 10pt
                        // padding on each side). Menu's own behavior
                        // (Floor/Ceiling/Wall submenus) is completely
                        // unchanged -- only this label's appearance.
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.orange, in: Circle())
                    }
                }
            }
            Spacer()
            if state.enabled, let target = state.selection, target.floor == store.currentMazeID {
                VStack(spacing: 10) {
                    HStack {
                        Text(target.title).font(.headline)
                        Spacer()
                        Button("Close") { state.selection = nil }
                    }
                    Text(target.locationLabel)
                        .font(.caption).foregroundStyle(.secondary)
                    if target.kind == .ceilingSurface {
                        HStack {
                            Button("Add Ceiling") { state.add(.ceiling) }
                            Button("Add Fluorescent") { state.add(.fluorescent) }
                        }
                        .disabled(!state.canAdd(target))
                    } else if target.kind == .picture {
                        // Sept 21 (Picture Decorator complete pass):
                        // Image, Size, Picture Light, and Delete --
                        // Eddie's full target inspector layout for an
                        // existing Picture. Image reuses
                        // SystemPhotoPicker/HallwaysArtPicker
                        // (PictureChangeMenu.swift) completely
                        // unmodified and calls store.
                        // setPictureImageSelection/
                        // saveCurrentFloorAsOverride directly -- no
                        // scene-manipulation code needed here at all,
                        // since ContentView.updateUIView's existing
                        // generic lastPictureImageSelections diff
                        // already applies the live material swap for
                        // ANY caller of setPictureImageSelection,
                        // build-time picture or Decorator-added alike.
                        // Picture Light is a convenience over the
                        // EXISTING independent Picture Light
                        // architecture (state.pictureLightIsOn/
                        // setPictureLightOn/changePictureLightBrightness)
                        // -- see those methods' own doc comments.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Image").font(.caption).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Button("Hallways Collection — Select") {
                                    pictureSheetTarget = target.coord
                                    showHallwaysArtPicker = true
                                }
                                Button("Hallways Collection — Random") {
                                    guard let coord = target.coord, let name = HallwayScene.pictureAssetNames.randomElement() else { return }
                                    store.setPictureImageSelection(.builtIn(name), at: coord)
                                    store.saveCurrentFloorAsOverride()
                                }
                                Button("Camera Roll — Select") {
                                    pictureSheetTarget = target.coord
                                    showSystemPhotoPicker = true
                                }
                                Button("Camera Roll — Random") {
                                    guard let coord = target.coord else { return }
                                    PhotoRollProvider.shared.randomImageWithIdentifier(caller: "Decorator: Camera Roll — Random") { identifier, _ in
                                        if let identifier {
                                            store.setPictureImageSelection(.cameraRoll(identifier), at: coord)
                                            store.saveCurrentFloorAsOverride()
                                        }
                                    }
                                }
                            }.font(.caption)

                            Text("Size").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                ForEach(PictureSize.allCases, id: \.self) { size in
                                    Button(size.displayName) { state.changePictureSize(size) }
                                        .tint(state.pictureSize(target) == size ? .pink : nil)
                                }
                            }.font(.caption)

                            pictureLightControls(target)

                            Button("Delete Picture", role: .destructive) { state.deletePicture() }
                        }
                    } else if target.kind == .missionSign || target.kind == .floorMap {
                        pictureLightControls(target)
                    } else if target.kind == .wallSurface {
                        // Sept 21 (3D Decorator wall authoring, Pass 3):
                        // Picture only this pass -- Mirror/Wall Light
                        // ADD are deliberately not offered here yet
                        // (see the Sept 21 recon report's own
                        // recommended sequencing).
                        Button("Add Picture") { state.addPicture() }
                            .disabled(!state.canAddPicture(target))
                    } else if target.kind == .floorObject {
                        // Sept 21 (Floor Object placement, first pass --
                        // trash cans only): LEFT/CENTER/RIGHT is a
                        // position across the hallway's usable width,
                        // relative to this object's OWN authored axis,
                        // not absolute compass direction -- see
                        // HallwayScene.trashCanFloorOffset's own doc
                        // comment for the exact convention. Both pickers
                        // write straight through DecoratorState.
                        // changeFloorPosition/changeFloorOrientation,
                        // which move the SAME live node immediately (no
                        // rebuild) -- same shape as the Fluorescent
                        // Orientation picker just below in this file.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Position").font(.caption).foregroundStyle(.secondary)
                            Picker("Position", selection: Binding(
                                get: { state.floorPosition(target) },
                                set: { state.changeFloorPosition($0) })) {
                                    ForEach(FloorPosition.allCases, id: \.self) { position in
                                        Text(position.title).tag(position)
                                    }
                                }
                                .pickerStyle(.segmented)

                            Text("Hallway Axis").font(.caption).foregroundStyle(.secondary)
                            Picker("Axis", selection: Binding(
                                get: { state.floorObjectOrientation(target) },
                                set: { state.changeFloorOrientation($0) })) {
                                    ForEach(FluorescentOrientation.allCases, id: \.self) { orientation in
                                        Text(orientation.title).tag(orientation)
                                    }
                                }
                                .pickerStyle(.segmented)
                        }
                    } else {
                        HStack {
                            Text("Brightness")
                            Button { state.changeBrightness(by: -1) } label: { Image(systemName: "minus.circle.fill") }
                                .disabled(state.level(target) == target.lightKind.levelRange.lowerBound)
                            Text("\(state.level(target)) / \(target.lightKind.levelRange.upperBound)").monospacedDigit()
                            Button { state.changeBrightness(by: 1) } label: { Image(systemName: "plus.circle.fill") }
                                .disabled(state.level(target) == target.lightKind.levelRange.upperBound)
                        }
                        if target.kind == .fluorescent {
                            Picker("Orientation", selection: Binding(
                                get: { state.orientation(target) },
                                set: { state.changeOrientation($0) })) {
                                    ForEach(FluorescentOrientation.allCases, id: \.self) { orientation in
                                        Text(orientation.title).tag(orientation)
                                    }
                                }
                                .pickerStyle(.segmented)
                        }
                        if !target.isCab {
                            HStack {
                                Text("Move")
                                ForEach([Direction.north, .east, .south, .west], id: \.self) { direction in
                                    Button(direction.rawValue.capitalized) { state.move(direction) }
                                        .disabled(!state.canMove(direction))
                                }
                            }.font(.caption)
                        }
                        Button("Delete Light", role: .destructive) { state.deleteSelected() }
                    }
                }
                .buttonStyle(.bordered)
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: 350)
            }
        }
        .padding(.top, 110)
        .padding(.bottom, 100)
        .padding(.horizontal, 12)
        .sheet(isPresented: $showSystemPhotoPicker) {
            SystemPhotoPicker { identifier in
                if let identifier, let coord = pictureSheetTarget {
                    store.setPictureImageSelection(.cameraRoll(identifier), at: coord)
                    store.saveCurrentFloorAsOverride()
                }
                pictureSheetTarget = nil
            }
        }
        .sheet(isPresented: $showHallwaysArtPicker) {
            HallwaysArtPicker { name in
                if let name, let coord = pictureSheetTarget {
                    store.setPictureImageSelection(.builtIn(name), at: coord)
                    store.saveCurrentFloorAsOverride()
                }
                pictureSheetTarget = nil
            }
        }
    }
}

extension HallwayScene {
    /// Sept 21 (ceiling-selection trap fix): the visible ceiling slab's
    /// bottom face and a flush-mounted fixture's top face are, by design
    /// ("top touches the ceiling"), the exact same world Y -- proven by
    /// direct computation from these two factories' own numbers: gap ==
    /// 0.0 exactly, not just very small. SCNHitTest's .closest search has
    /// no reliable way to break a tie between two geometrically coincident
    /// surfaces, so a tap aimed at the fixture was landing on the (much
    /// larger) .ceilingSurface slab instead almost every time -- exactly
    /// Eddie's "tapping the fixture opens Add Ceiling Light" report.
    ///
    /// This adds an invisible, hit-test-only proxy, generously sized and
    /// placed with real clearance below the ceiling slab, as a CHILD of
    /// the fixture root. It changes no visible geometry or appearance
    /// (fully transparent, no depth writes) and needs no DecoratorMode
    /// changes: select(at:in:) already walks a hit up through node.parent
    /// looking for a tag, so the proxy just needs to be spatially in front
    /// of (below) the slab -- the existing tag on the fixture root is
    /// found the same way child geometry already resolves to it. Being a
    /// plain child (not separately tagged), it moves for free with the
    /// fixture's own transform, so move()'s direct position mutation on
    /// the tagged root can't double-move it, and deleteSelected()'s
    /// removeFromParentNode() removes it along with the fixture -- no
    /// stale proxy left behind.
    static func makeDecoratorHitProxy(cellSize: CGFloat) -> SCNNode {
        let geometry = SCNBox(width: cellSize * 0.9, height: 0.02, length: cellSize * 0.9, chamferRadius: 0)
        let material = SCNMaterial()
        // transparency = 0 is the actual mechanism that makes this
        // invisible in SceneKit's standard rendering -- diffuse alpha
        // alone is not reliably respected without also setting a
        // transparencyMode, so this is the one property that matters.
        material.transparency = 0
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        geometry.materials = [material]
        let proxy = SCNNode(geometry: geometry)
        proxy.name = "decoratorHitProxy"
        proxy.castsShadow = false
        proxy.position.y = -0.08
        proxy.renderingOrder = 1000
        return proxy
    }

    /// Same existing ceiling-disc construction, shared by floor load and live ADD.
    static func makeAuthoredCeilingFixture(cellSize: CGFloat, level: Int) -> SCNNode {
        let root = SCNNode()
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.98, alpha: 1)
        material.emission.contents = UIColor(white: 0.95, alpha: 1)
        material.lightingModel = .constant
        let geometry = SCNCylinder(radius: cellSize * 0.12, height: 0.04)
        geometry.materials = [material]
        let disc = SCNNode(geometry: geometry)
        disc.position.y = -0.02
        root.addChildNode(disc)
        let light = SCNLight()
        light.type = .omni
        light.color = UIColor.white
        light.intensity = AuthoredLightKind.ceiling.intensity(level: level)
        light.attenuationStartDistance = cellSize * 0.15
        light.attenuationEndDistance = cellSize * 2.5
        light.attenuationFalloffExponent = 2
        light.castsShadow = false
        let source = SCNNode()
        source.light = light
        source.position.y = -0.15
        root.addChildNode(source)
        root.addChildNode(makeDecoratorHitProxy(cellSize: cellSize))
        return root
    }
}
