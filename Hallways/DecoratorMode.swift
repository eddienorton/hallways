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
    enum Kind: String { case ceilingSurface, ceiling, fluorescent, picture, wallSurface, missionSign, floorMap, floorObject, exitSign, fire, roomDoor, mirror, extinguisher, photoBooth, roomEntranceDoor }
    let floor: Int
    /// Sept 26 (Decorate-mode elevator pictures): identifies WHICH of
    /// the elevator cab's 3 built-in posters a target refers to -- back
    /// wall or side wall, the same 2 surfaces
    /// TapNavigationController.ElevatorPosterTarget already names for
    /// Play mode's own Change Picture routing. Deliberately its OWN
    /// small type here rather than reusing that one directly: this
    /// file has no dependency on TapNavigationController (every other
    /// live-scene reach-through here is a closure, e.g. registerMirror/
    /// canEditCab), and this keeps that decoupling intact. ContentView's
    /// Coordinator (which already holds both) is the one place that
    /// converts between the two.
    enum ElevatorPosterSurface: Equatable {
        case back
        case side
        // Sept 26 (third elevator poster, right wall): .side above is
        // the ORIGINAL single side poster (physically the LEFT wall) --
        // kept as-is, unrenamed, so every existing switch over this
        // enum stays untouched. This is the new, second lateral wall.
        case sideRight
    }
    enum Location: Equatable { case grid(GridCoordinate), elevatorCeiling, elevatorPoster(ElevatorPosterSurface) }
    let location: Location
    let kind: Kind
    /// Which wall face this target refers to. nil for ceiling/
    /// fluorescent (capped at one authored object per CELL, so a
    /// coordinate alone already identifies them uniquely -- see
    /// MazeStore's canPlaceMirror/canPlaceWallLight/canPlacePhotoBooth,
    /// which all key off coord alone) and for missionSign/floorMap
    /// (same one-per-cell cap; still queried straight off the store's
    /// own coord-keyed dict via pictureDirection(_:)). Sept 22
    /// (wall-face authoring expansion): `.wallSurface` AND `.picture`
    /// both always carry a concrete direction now -- a cell can hold up
    /// to 4 solid walls, and since a cell can now also hold more than
    /// one Picture (one per wall), a Picture's own identity needs its
    /// wall face too, not just `.wallSurface`'s.
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
    /// Sept 26 (Decorate-mode elevator pictures): which built-in
    /// poster this target refers to -- nil for every other kind/
    /// location, same "nil unless this specific case" shape as coord
    /// above. Drives DecoratorOverlay's elevator-poster Image section
    /// (which surface to write store.setElevatorBackArtwork/
    /// setElevatorSideArtwork to) and its two picker sheets.
    var elevatorPosterSurface: ElevatorPosterSurface? {
        if case .elevatorPoster(let surface) = location { return surface }
        return nil
    }
    var isCab: Bool {
        switch location {
        case .elevatorCeiling, .elevatorPoster: return true
        case .grid: return false
        }
    }
    var locationLabel: String {
        switch location {
        case .grid(let coord):
            let base = "Floor \(floor) · Row \(coord.row), Column \(coord.col)"
            guard let direction else { return base }
            return base + " · \(direction.rawValue.capitalized) wall"
        case .elevatorCeiling:
            return "Elevator cab · Center ceiling"
        case .elevatorPoster(let surface):
            let surfaceLabel: String
            switch surface {
            case .back: surfaceLabel = "Back"
            // Sept 26 (third elevator poster, right wall): relabeled
            // from the old bare "Side" to "Left" now that a "Right"
            // exists too -- label text only, the .side CASE NAME is
            // unchanged.
            case .side: surfaceLabel = "Left"
            case .sideRight: surfaceLabel = "Right"
            }
            return "Elevator cab · \(surfaceLabel) wall"
        }
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
        // Sept 23 (Decorator Floor expansion): now covers Trash Can,
        // Envelope, and Paint Bucket -- DecoratorOverlay looks up the
        // SPECIFIC kind from MazeStore.objects for display instead of
        // hardcoding one here (see its own floorObjectTitle helper).
        case .floorObject: return "Object"
        // Sept 23 (Decorator Ceiling expansion): Exit Sign -- its own
        // independent authored kind (MazeStore.exitSigns), not part of
        // the ceiling/fluorescent light machinery.
        case .exitSign: return "Exit Sign"
        // Sept 23 (Decorator Floor expansion): Fire -- the project's
        // other existing physical light source (MazeStore.fires), kept
        // fully independent of the ceiling/fluorescent machinery below
        // (own add/remove/brightness functions) so the recently-tuned
        // fluorescent recipe/brightness logic is never touched by this.
        case .fire: return "Fire"
        // Sept 24 (Empty Wall chooser): a decorative (nonfunctional)
        // room door -- same visual + number as a map-authored door, but
        // architectural only.
        case .roomDoor: return "Room Door"
        // Sept 25 (Designer wall authoring): Mirror -- wall-mounted
        // fixture with a live camera feed (MirrorCamera) and a real
        // reflection on the "mirrorSurface" child node; stops navigation
        // on every pass like a Picture.
        case .mirror: return "Mirror"
        // Sept 25 (Designer wall authoring): Fire Extinguisher -- the
        // Floor-5 mission pickup (MazeStore.extinguishers), now
        // authorable on any unclaimed solid wall (Wall chooser).
        case .extinguisher: return "Fire Extinguisher"
        // Sept 25 (Designer wall authoring): Photo Booth -- the Floor-6
        // mission fixture (MazeStore.photoBooths), now authorable on
        // any unclaimed solid wall (Wall chooser).
        case .photoBooth: return "Photo Booth"
        // Sept 27 (Decorator Room Entrance authoring): the generic
        // cell-to-cell swinging door authored via "+" -> Door Entry
        // (or the 2D Grid Editor's own Room Entrance tool) -- MazeStore.
        // roomEntranceDoors, sharing the exact bathroomDoors/windowRooms
        // swinging-door machinery, just with no sign and no window/
        // perimeter requirement.
        case .roomEntranceDoor: return "Room Entrance"
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
    var unregisterPicture: (_ coord: GridCoordinate, _ direction: Direction) -> Void = { _, _ in }
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
    /// Sept 27 (Decorator delete-staleness fix): the reverse of
    /// registerFloorObject above -- deleteFloorObject below calls this
    /// so TapNavigationController.objectKinds/objectNodes (and the live
    /// floor map / mission progress they drive) drop the deleted object
    /// immediately, matching what registerFloorObject already does on
    /// the add side.
    var unregisterFloorObject: (_ coord: GridCoordinate) -> Void = { _ in }
    /// Keep the navigation controller’s map data in sync with live additions.
    var registerRoomDoor: (_ door: RoomDoorPlacement) -> Void = { _ in }
    /// Sept 27 (Decorator delete-staleness fix): deleteRoomDoor below
    /// calls this so TapNavigationController.roomDoors -- read directly
    /// by the live floor map texture and by every walk-stop/knock/
    /// deliverMail gate -- drops the deleted door immediately, instead
    /// of continuing to block walks and draw on the map until the floor
    /// is fully rebuilt.
    var unregisterRoomDoor: (_ coord: GridCoordinate) -> Void = { _ in }
    /// Sept 21 (current-cell Ceiling/Wall authoring): the player's
    /// current facing -- same shape/reason as currentPlayerCell above,
    /// wired up in ContentView. selectWallAtCurrentCell below reads
    /// this to translate player-relative Left/Right into an absolute
    /// Direction via Direction.left/right (MazeNavigation.swift's
    /// existing relative-turn convention), never a second one.
    var currentPlayerFacing: () -> Direction? = { nil }
    /// Sept 25 (Designer wall authoring, live Mirror ADD): the two places
    /// a live-added mirror must reach that this class has no other handle
    /// on -- MirrorCamera (so the player's face shows in the new glass,
    /// via addSurface/removeSurface on the cover of MirrorCamera.surfaces)
    /// and TapNavigationController (so walks stop at the new mirror, via
    /// registerMirror/unregisterMirror on pictureCoords). Wired up in
    /// ContentView like registerAddedPicture above.
    var registerMirrorSurface: (_ material: SCNMaterial, _ aspect: CGFloat) -> Void = { _, _ in }
    var unregisterMirrorSurface: (_ material: SCNMaterial) -> Void = { _ in }
    var registerMirror: (_ coord: GridCoordinate, _ direction: Direction) -> Void = { _, _ in }
    var unregisterMirror: (_ coord: GridCoordinate, _ direction: Direction) -> Void = { _, _ in }
    /// Sept 25 (Designer authoring, live mission-object ADD): the
    /// navigation-state registration closures for the three mission
    /// objects the Floor/Wall catalogs can now author live -- fire,
    /// extinguisher, photo booth -- each paired 1:1 with its reverse.
    /// Wired up in ContentView to TapNavigationController.registerFire/
    /// registerExtinguisher/registerPhotoBooth and their unregister
    /// counterparts, so authored objects join the real mission per
    /// Eddie's Sept 25 direction.
    var registerLiveFire: (_ coord: GridCoordinate, _ node: SCNNode) -> Void = { _, _ in }
    var unregisterLiveFire: (_ coord: GridCoordinate) -> Void = { _ in }
    var registerLiveExtinguisher: (_ direction: Direction, _ coord: GridCoordinate, _ node: SCNNode) -> Void = { _, _, _ in }
    var unregisterLiveExtinguisher: (_ coord: GridCoordinate) -> Void = { _ in }
    var registerLivePhotoBooth: (_ direction: Direction, _ coord: GridCoordinate, _ node: SCNNode) -> Void = { _, _, _ in }
    var unregisterLivePhotoBooth: (_ coord: GridCoordinate) -> Void = { _ in }
    /// Sept 27 (Decorator Room Entrance authoring): same shape as the
    /// mirror/fire/extinguisher/photo-booth register/unregister
    /// closures just above -- addRoomEntranceDoorAtCurrentCell/
    /// deleteRoomEntranceDoor below call these instead of holding a
    /// reference to TapNavigationController directly. Wired up in
    /// ContentView to registerRoomEntranceDoor/unregisterRoomEntranceDoor.
    var registerLiveRoomEntranceDoor: (_ direction: Direction, _ coord: GridCoordinate) -> Void = { _, _ in }
    var unregisterLiveRoomEntranceDoor: (_ coord: GridCoordinate) -> Void = { _ in }

    /// Sept 28 (EXIT sign map markers): same register/unregister
    /// routing as registerLiveRoomEntranceDoor/
    /// unregisterLiveRoomEntranceDoor just above -- addExitSignAtCurrentCell/
    /// changeExitSignDirection/deleteExitSign below call these instead
    /// of holding a reference to TapNavigationController directly, so
    /// the popup map's new EXIT arrow stays correct across a live add,
    /// re-point, or delete without a full floor rebuild. Wired up in
    /// ContentView to registerExitSign/unregisterExitSign.
    var registerLiveExitSign: (_ direction: Direction, _ coord: GridCoordinate) -> Void = { _, _ in }
    var unregisterLiveExitSign: (_ coord: GridCoordinate) -> Void = { _ in }

    /// Sept 28 (picture content moved to Decorator): Decorator's
    /// Picture panel "Content..." button calls this instead of holding
    /// a reference to TapNavigationController directly -- same
    /// "closure crosses the boundary" shape as every registerLiveX
    /// pair above. Wired up in ContentView to set
    /// navigationController.activePictureMenu, which is exactly the
    /// @Published property PictureChangeMenuHost (PictureChangeMenu.
    /// swift) already observes to present the existing Change Picture
    /// confirmationDialog -- so Decorator opens the SAME menu Play
    /// mode used to open on a picture tap, with no second
    /// implementation of picture-changing logic.
    var presentPictureChangeMenu: (_ face: WallFace) -> Void = { _ in }

    var navigationArrowsEnabledAtCurrentCell: Bool {
        guard let coord = currentPlayerCell(), let store else { return true }
        return !store.hiddenNavigationArrows.contains(coord)
    }

    var canEditNavigationArrowsAtCurrentCell: Bool {
        guard enabled, let coord = currentPlayerCell(), let store else { return false }
        return store.cells.contains(coord)
    }

    func setNavigationArrowsEnabledAtCurrentCell(_ enabled: Bool) {
        guard canEditNavigationArrowsAtCurrentCell, let coord = currentPlayerCell(),
              let store, let scene, navigationArrowsEnabledAtCurrentCell != enabled else { return }
        store.snapshotForUndo()
        store.setNavigationArrowsEnabled(enabled, at: coord)
        HallwayScene.setNavigationArrowsHidden(!enabled, at: coord, in: scene)
        store.saveCurrentFloorAsOverride()
    }

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
            // Sept 26 (Decorate-mode elevator pictures): a target with
            // isCab true and kind .picture is, by construction, always
            // an elevatorPoster location (see HallwayScene's tagging of
            // the 2 poster nodes) -- never elevatorCeiling. Both built-
            // in posters are permanent geometry (addElevatorDoor always
            // builds both, unconditionally), so unlike the ceiling
            // fixture there is no ADD/DELETE state to check here: a
            // poster target always exists.
            case .picture: return true
            case .missionSign, .floorMap: return false
            case .wallSurface: return false
            case .floorObject: return false // no Floor Objects in the elevator cab
            case .exitSign: return false // no Exit Sign in the elevator cab
            case .fire: return false // no Fire in the elevator cab
            case .roomDoor: return false // no Room Door in the elevator cab
            case .mirror: return false // no Mirror in the elevator cab
            case .extinguisher: return false // no Fire Extinguisher in the elevator cab
            case .photoBooth: return false // no Photo Booth in the elevator cab
            case .roomEntranceDoor: return false // no Room Entrance door in the elevator cab
            }
        }
        guard let coord = target.coord else { return false }
        switch target.kind {
        case .ceiling: return store.spotlights.contains(coord)
        case .fluorescent: return store.fluorescentLights[coord] != nil
        case .ceilingSurface: return store.cells.contains(coord)
        // Sept 22 (wall-face authoring expansion): face-specific --
        // target.direction is always set on a `.picture` target now
        // (see HallwayScene's build loop and DecoratorState.addPicture).
        case .picture:
            guard let direction = target.direction else { return false }
            return store.hasPicture(direction, at: coord)
        case .missionSign: return store.missionSigns[coord] != nil
        case .floorMap: return store.floorMaps[coord] != nil
        case .wallSurface: return store.cells.contains(coord)
        // Floor objects and Hanging Money share the authored-object selection/delete path.
        case .floorObject:
            guard let kind = store.objects[coord] else { return false }
            return kind == .trashCan || kind == .envelope || kind == .paintBucket || kind == .cash100
        // Sept 23 (Decorator Ceiling expansion): Exit Sign reads straight
        // off MazeStore.exitSigns, its own independent authored dictionary.
        case .exitSign: return store.hasExitSign(coord)
        // Sept 23 (Decorator Floor expansion): Fire reads straight off
        // MazeStore.fires, its own independent authored Set.
        case .fire: return store.hasFire(coord)
        // Sept 24 (Empty Wall chooser): reads straight off MazeStore.
        // roomDoors, the door's own authored dictionary -- a decorative
        // door placed here is a RoomDoorPlacement like any other, only
        // with its isDecorative flag set.
        case .roomDoor:
            guard let direction = target.direction else { return false }
            return store.roomDoors[coord]?.direction == direction
        // Sept 25 (Designer wall authoring): mirrors/extinguishers/photo
        // booths are wall-mounted (direction-carrying), one per cell,
        // keyed off their own authored dictionaries.
        case .mirror:
            guard let direction = target.direction else { return false }
            return store.mirrors[coord] == direction
        case .extinguisher:
            guard let direction = target.direction else { return false }
            return store.extinguishers[coord] == direction
        case .photoBooth:
            guard let direction = target.direction else { return false }
            return store.photoBooths[coord]?.direction == direction
        // Sept 27 (Decorator Room Entrance authoring): reads straight
        // off MazeStore.roomEntranceDoors, its own independent authored
        // dictionary (same face-keyed shape as mirror/extinguisher/
        // photoBooth just above).
        case .roomEntranceDoor:
            guard let direction = target.direction else { return false }
            return store.roomEntranceDoors[coord]?.direction == direction
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
            // Mutate a copy of the CURRENT cab decoration -- constructing
            // a fresh ElevatorCabDecoration(...) here would silently wipe
            // any persisted elevator-poster artwork (backArtwork/
            // sideArtwork) every time the ceiling fixture is placed.
            var decoration = store?.elevatorCabDecoration ?? ElevatorCabDecoration()
            decoration.ceilingFixture = .init(
                kind: target.kind == .fluorescent ? .fluorescent : .ceiling,
                brightness: level, orientation: orientation)
            store?.setElevatorCabDecoration(decoration)
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
            // Same rationale as place(...) above: preserve any persisted
            // elevator-poster artwork, only clear the ceiling fixture.
            var decoration = store?.elevatorCabDecoration ?? ElevatorCabDecoration()
            decoration.ceilingFixture = nil
            store?.setElevatorCabDecoration(decoration)
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
        let previousLevel = level(target)
        let next = min(range.upperBound, max(range.lowerBound, previousLevel + delta))
        guard next != previousLevel else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        store.snapshotForUndo()
        place(target, level: next, orientation: orientation(target))
        // Sept 22 (Eddie: brightness-range cleanup -- retires the
        // stale three-Area x100 fluorescent multiplier from the
        // abandoned Area-light experiment). The fluorescent fixture
        // now carries TWO independently-tuned `.spot` lights (far-
        // above the ceiling aimed down at nominal x20, far-below the
        // floor aimed up at nominal x5 -- see FluorescentLight.swift),
        // not one flat intensity shared by every light under the
        // fixture. Overwriting every light with the SAME new flat
        // value (the old x100 approach's shape) would silently erase
        // that 20:5 ratio the moment brightness is nudged in Decorator
        // mode. Instead, each light is SCALED by the ratio between the
        // new and previous NOMINAL intensity for this target's kind --
        // whatever multiplier a given light already carries on top of
        // nominal (x20, x5, or none) is preserved exactly. This also
        // reduces correctly to a plain overwrite for `.ceiling`, which
        // has exactly one light already sitting at the nominal value
        // with no multiplier -- so one code path is now correct for
        // both kinds, with no per-kind special case left.
        let previousNominal = target.lightKind.intensity(level: previousLevel)
        let newNominal = target.lightKind.intensity(level: next)
        for node in liveNodes {
            node.enumerateHierarchy { child, _ in
                guard let light = child.light else { return }
                if previousNominal > 0 {
                    light.intensity = light.intensity * (newNominal / previousNominal)
                } else {
                    // Coming from OFF (previousNominal == 0): no
                    // existing ratio to scale from, so fall back to
                    // the plain nominal value -- matches what
                    // construction time would produce from this level
                    // for a light with no extra multiplier. A
                    // multiplied fluorescent light turning on this way
                    // will briefly not carry its x20/x5 multiplier
                    // until the NEXT brightness change re-establishes a
                    // real ratio; acceptable for this diagnostic pass.
                    light.intensity = newNominal
                }
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
        guard let coord = target.coord, let direction = pictureDirection(target) else { return .standard }
        return store?.pictureSize(direction: direction, at: coord) ?? .standard
    }

    /// Sept 22 (wall-face authoring expansion): a `.picture` target NOW
    /// DOES carry its own `direction` (see DecoratorTarget's own doc
    /// comment) -- tagged at construction time by HallwayScene's build
    /// loop and by DecoratorState.addPicture below, exactly like
    /// `.wallSurface` already did, since a coordinate alone can no
    /// longer identify a specific Picture once a cell can hold two.
    /// `.missionSign`/`.floorMap` are unaffected (still capped at one
    /// per cell) and keep reading straight off the store.
    private func pictureDirection(_ target: DecoratorTarget) -> Direction? {
        guard let coord = target.coord else { return nil }
        switch target.kind {
        case .picture: return target.direction
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
        return store?.pictureLights.contains(WallFace(coord: coord, direction: direction)) ?? false
    }

    func pictureLightBrightness(_ target: DecoratorTarget) -> Int {
        guard let coord = target.coord, let direction = pictureDirection(target) else { return 3 }
        return store?.lightBrightnessLevel(.picture, direction: direction, at: coord) ?? 3
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
            let brightness = store.lightBrightnessLevel(.picture, direction: direction, at: coord)
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
            store.removePictureLight(direction, at: coord)
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
    /// pictures[WallFace(coord, direction)], none of which change on a
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
        let currentSize = store.pictureSize(direction: direction, at: coord)
        guard currentSize != size else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        guard let hallwayRoot = scene.rootNode.childNode(withName: "hallwaySceneRoot", recursively: false) else { return }
        store.snapshotForUndo()
        store.setPictureSize(size, direction: direction, at: coord)
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
                let level = store.lightBrightnessLevel(.picture, direction: direction, at: coord)
                frame.addChildNode(HallwayScene.makePictureLight(panelWidth: newPanelWidth, panelHeight: newPanelHeight, level: level))
            }
        }

        let backfillTarget = PictureBackfillTarget(floor: floor, coord: coord, direction: direction)
        var oldBackfillNodes: [SCNNode] = []
        hallwayRoot.enumerateChildNodes { node, _ in
            if PictureBackfillTarget.read(node) == backfillTarget { oldBackfillNodes.append(node) }
        }
        for node in oldBackfillNodes { node.removeFromParentNode() }
        if currentSize == .lobbyOriginal {
            let wall = DecoratorTarget(floor: floor, coord: coord, kind: .wallSurface, direction: direction)
            for node in nodes(for: wall) { node.removeFromParentNode() }
        }

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
        if let coord = target.coord { syncCeilingFixtureVisibility(at: coord) }
        selection = nil
        save(target)
    }

    /// Sept 23 (ceiling light coexistence). Kind-aware on purpose: a
    /// coordinate can hold at most ONE of a given ceiling light kind
    /// (a second Fluorescent can never stack on a Fluorescent, same as
    /// before), but no longer requires BOTH kinds to be absent -- a
    /// Spotlight and a Fluorescent may now occupy the same coordinate
    /// at once. This is the single rule change coexistence needed;
    /// every caller below just needed to start passing which kind it
    /// actually means.
    func canPlace(_ kind: DecoratorTarget.Kind, at coord: GridCoordinate) -> Bool {
        guard let store, store.currentMazeID == floor else { return false }
        guard store.cells.contains(coord) else { return false }
        if kind == .fluorescent { return store.fluorescentLights[coord] == nil }
        return !store.spotlights.contains(coord)
    }

    func canMove(_ direction: Direction) -> Bool {
        guard let target = selection, target.kind == .ceiling || target.kind == .fluorescent, exists(target), let coord = target.coord else { return false }
        return canPlace(target.kind, at: GridCoordinate(row: coord.row + direction.delta.row,
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
        // Sept 23 (ceiling light coexistence): the coordinate this
        // fixture just left may have a same-cell sibling of the OTHER
        // kind left behind (previously hidden, now the only kind
        // there -- must become visible again), and the destination
        // coordinate may have just gained a same-cell sibling of the
        // other kind (this moved-in fixture may now need to be
        // hidden). Both are no-ops when no coexistence is involved.
        syncCeilingFixtureVisibility(at: coord)
        syncCeilingFixtureVisibility(at: destination)
        selection = moved
        save(target)
    }

    /// `kind` defaults to `.ceiling` purely so existing single-argument
    /// call sites (the elevator cab path, which never reaches the
    /// kind-aware canPlace check below -- it returns from its own
    /// isCab branch first) keep compiling unchanged. Every non-cab
    /// caller now passes the specific kind it means.
    func canAdd(_ target: DecoratorTarget, kind: DecoratorTarget.Kind = .ceiling) -> Bool {
        guard exists(target) else { return false }
        if target.isCab { return store?.elevatorCabDecoration.ceilingFixture == nil }
        guard let coord = target.coord else { return false }
        return canPlace(kind, at: coord)
    }

    /// Sept 23 (ceiling light coexistence). Re-syncs BOTH ceiling light
    /// kinds' live fixture geometry at `coord` to whatever
    /// MazeStore.visibleCeilingFixtureKind(at:) currently resolves to.
    /// Safe/idempotent to call whenever occupancy or the visible choice
    /// at a coordinate might have changed (add/move/delete/picker) --
    /// harmless no-op for a coordinate with only one kind (or none),
    /// which is every coordinate on a floor authored before this
    /// feature existed.
    private func syncCeilingFixtureVisibility(at coord: GridCoordinate) {
        guard let store else { return }
        let visible = store.visibleCeilingFixtureKind(at: coord)
        for (kind, lightKind) in [(DecoratorTarget.Kind.ceiling, AuthoredLightKind.ceiling), (.fluorescent, .fluorescent)] {
            for node in nodes(for: DecoratorTarget(floor: floor, coord: coord, kind: kind)) {
                HallwayScene.setCeilingFixtureGeometryHidden(node, hidden: visible != nil && visible != lightKind)
            }
        }
    }

    /// Whether `target`'s coordinate currently has BOTH a spotlight and
    /// a fluorescent authored -- the only situation the "Lights at this
    /// location" picker has anything to actually choose between. Never
    /// true for the elevator cab, which only ever holds one ceiling
    /// fixture (ElevatorCabDecoration.Fixture is a single value, not a
    /// per-kind collection) -- cab coexistence is out of scope for this
    /// pass.
    func hasCoexistingCeilingLights(_ target: DecoratorTarget) -> Bool {
        guard !target.isCab, let store, let coord = target.coord else { return false }
        return store.spotlights.contains(coord) && store.fluorescentLights[coord] != nil
    }

    /// Which fixture currently renders at `target`'s coordinate --
    /// drives the "Lights at this location" picker's selection.
    func visibleCeilingFixture(_ target: DecoratorTarget) -> AuthoredLightKind {
        guard let coord = target.coord else { return target.lightKind }
        return store?.visibleCeilingFixtureKind(at: coord) ?? target.lightKind
    }

    /// The picker's write path. Presentation-only, straight through to
    /// MazeStore.setVisibleCeilingFixture -- never places, removes, or
    /// changes the intensity of either light, only which one's
    /// geometry is shown.
    func setVisibleCeilingFixture(_ kind: AuthoredLightKind, target: DecoratorTarget) {
        guard let coord = target.coord, let store else { return }
        store.setVisibleCeilingFixture(kind, at: coord)
        syncCeilingFixtureVisibility(at: coord)
    }

    func add(_ kind: DecoratorTarget.Kind) {
        guard enabled, let target = selection, target.kind == .ceilingSurface,
              kind == .ceiling || kind == .fluorescent, canAdd(target, kind: kind),
              let store, let scene else { return }
        if target.isCab {
            guard let mount = cabMount else { return }
            let fixture = ElevatorCabDecoration.Fixture(kind: kind == .fluorescent ? .fluorescent : .ceiling)
            let node = HallwayScene.makeElevatorCabFixture(fixture, cellSize: store.cellSize, floorNumber: floor)
            store.snapshotForUndo()
            var decoration = store.elevatorCabDecoration
            decoration.ceilingFixture = fixture
            store.setElevatorCabDecoration(decoration)
            mount.addChildNode(node)
            selection = DecoratorTarget.read(node)
            return
        }
        guard let coord = target.coord else { return }
        // Auto-orientation (Fluorescent): derive the corridor's own axis
        // from the open sides of the cell the player is standing in --
        // a straight N/S or E/W hallway gets a fixture aligned with it;
        // corners/junctions/dead ends (no single axis) keep the default.
        let addedOrientation = store.autoFluorescentOrientation(at: coord) ?? .northSouth
        let added = DecoratorTarget(floor: floor, coord: coord, kind: kind)
        let node = kind == .fluorescent
            ? HallwayScene.makeFluorescentLight(orientation: addedOrientation, level: 3, cellSize: store.cellSize)
            : HallwayScene.makeAuthoredCeilingFixture(cellSize: store.cellSize, level: 3)
        node.position = SCNVector3(Float(coord.col) * Float(store.cellSize), Float(store.wallHeight),
                                  Float(coord.row) * Float(store.cellSize))
        added.tag(node)
        store.snapshotForUndo()
        place(added, level: 3, orientation: addedOrientation)
        scene.rootNode.addChildNode(node)
        // Sept 23 (ceiling light coexistence): if the OTHER ceiling
        // light kind was already at this coord, place(...) above just
        // pinned it as the still-visible fixture (see MazeStore.
        // placeSpotlight/placeFluorescent's own comments) -- this
        // hides the fixture just added, since a newly-added kind
        // arrives hidden-by-default, never auto-visible. A no-op when
        // this is the only kind at the coord.
        syncCeilingFixtureVisibility(at: coord)
        selection = added
        save(target)
    }

    /// Sept 25 (Auto Lights). A RESET + REGENERATE authoring
    /// convenience for the CURRENT FLOOR's fluorescent layout only --
    /// scoped to fluorescents alone, nothing else authored on the
    /// floor is touched (spotlights, pictures, mirrors, doors, floor
    /// objects, mission content, fires, extinguishers, photo booths,
    /// maps, signs all pass through untouched). This never changes HOW
    /// a fluorescent produces light -- it reuses the exact same
    /// construction/placement/orientation machinery the manual
    /// "+ -> Ceiling -> Fluorescent Light" entrance above uses (same
    /// HallwayScene.makeFluorescentLight, same
    /// store.autoFluorescentOrientation(at:)/store.placeFluorescent,
    /// same level-3 default, same syncCeilingFixtureVisibility
    /// bookkeeping) -- only WHERE fluorescents land differs.
    ///
    /// STEP 1 (reset): every fluorescent currently on this floor is
    /// removed the same way deleteSelected() removes one -- its live
    /// node, store.removeFluorescent(at:) (which also clears that
    /// coordinate's persisted brightness record and any dormant
    /// ceiling-visible-fixture override, so no stale data survives),
    /// and a visibility re-sync for whatever's left at that coord.
    ///
    /// STEP 2 (regenerate): a small, deterministic depth-first walk of
    /// the floor's open cells (hallwayWalkOrder below) -- not raw
    /// dictionary/array ordering, which isn't stable or topology-aware
    /// -- covering every reachable cell exactly once. Every 4th cell
    /// visited gets a fluorescent, oriented via the SAME
    /// autoFluorescentOrientation(at:) corridor-axis lookup the manual
    /// add path already uses (falling back to .northSouth on a corner/
    /// junction/dead end, exactly like a manual add does).
    ///
    /// The whole reset+regenerate is ONE undo step (a single
    /// snapshotForUndo() up front, matching Clear/
    /// resetCurrentFloorToDefault's own "batch of edits, one undo"
    /// convention) and ONE save at the end, not one per fixture.
    func autoLightsCurrentFloor(spacing: Int = 4, brightness: Int = 10) {
        guard enabled, let store, let scene, store.currentMazeID == floor else { return }
        store.snapshotForUndo()

        // STEP 1 -- reset only the PREVIOUSLY AUTO-GENERATED fluorescents
        // on this floor (Sept 27: preserve-manual-lights fix). Iterating
        // autoGeneratedFluorescentCoords instead of every key in
        // fluorescentLights means a manually placed/customized fixture
        // (never tagged auto -- see placeFluorescent's own doc comment)
        // is left completely untouched by a regeneration.
        for coord in Array(store.autoGeneratedFluorescentCoords) {
            guard store.fluorescentLights[coord] != nil else { continue }
            let target = DecoratorTarget(floor: floor, coord: coord, kind: .fluorescent)
            for node in nodes(for: target) { node.removeFromParentNode() }
            store.removeFluorescent(at: coord)
            syncCeilingFixtureVisibility(at: coord)
        }

        // STEP 2 -- regenerate: walk the floor, light every `spacing`th
        // cell (index % spacing == 0 in hallwayWalkOrder's own stable
        // order -- unchanged semantics, spacing is just what used to be
        // the hardcoded 4). A walk position a manual fixture already
        // occupies (STEP 1 never removes those) is skipped rather than
        // overwritten, so a manual light can never be silently
        // reclassified as auto-generated.
        let walk = Self.hallwayWalkOrder(cells: store.cells)
        for (index, coord) in walk.enumerated() where index % spacing == 0 {
            guard store.fluorescentLights[coord] == nil else { continue }
            let orientation = store.autoFluorescentOrientation(at: coord) ?? .northSouth
            let node = HallwayScene.makeFluorescentLight(orientation: orientation, level: 3, cellSize: store.cellSize)
            node.position = SCNVector3(Float(coord.col) * Float(store.cellSize), Float(store.wallHeight),
                                      Float(coord.row) * Float(store.cellSize))
            let added = DecoratorTarget(floor: floor, coord: coord, kind: .fluorescent)
            added.tag(node)
            store.placeFluorescent(orientation, at: coord, brightness: brightness, isAutoGenerated: true)
            scene.rootNode.addChildNode(node)
            syncCeilingFixtureVisibility(at: coord)
        }

        selection = nil
        store.saveCurrentFloorAsOverride()
    }

    /// Deterministic depth-first walk of every cell in `cells`,
    /// covering each reachable region exactly once. Component starts
    /// are visited in row-major order (lowest row, then lowest col)
    /// and, within a walk, neighbors are explored in Direction.
    /// allCases' own fixed declared order (north, south, east, west) --
    /// so the SAME cell set always produces the SAME walk, which is
    /// what makes running Auto Lights twice on an unchanged floor
    /// reproduce the same layout. Deliberately just a walk, not a
    /// pathfinder or an optimizer -- Auto Lights only needs "some
    /// reasonably even, repeatable order to count cells along."
    private static func hallwayWalkOrder(cells: Set<GridCoordinate>) -> [GridCoordinate] {
        var visited: Set<GridCoordinate> = []
        var order: [GridCoordinate] = []
        let starts = cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        for start in starts where !visited.contains(start) {
            var stack: [GridCoordinate] = [start]
            while let coord = stack.popLast() {
                guard !visited.contains(coord) else { continue }
                visited.insert(coord)
                order.append(coord)
                let neighbors = Direction.allCases.compactMap { direction -> GridCoordinate? in
                    let candidate = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
                    return (cells.contains(candidate) && !visited.contains(candidate)) ? candidate : nil
                }
                stack.append(contentsOf: neighbors.reversed())
            }
        }
        return order
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
        // Sept 26 ("Keep This Picture"): a live-added Picture with no
        // explicit selection starts out just as randomly-sourced as a
        // freshly built floor's own unselected pictures -- reports its
        // identity into store.currentPictureIdentity the same way, so
        // Keep works on it immediately, without waiting for a rebuild.
        if store.picturesUseCameraRoll {
            // Same "Loading photo…" placeholder build(fromMaze:...) shows
            // every camera-roll picture until PhotoRollProvider resolves.
            baseTexture = HallwayScene.mirrorPlaceholder("Loading photo…")
        } else if let picked = HallwayScene.randomPictureImageWithName(caller: "decorator live add floor \(floor) coord \(coord) wall \(direction)") {
            baseTexture = picked.image
            store.reportCurrentPictureIdentity(.builtIn(picked.name), at: WallFace(coord: coord, direction: direction))
        } else {
            baseTexture = HallwayScene.mirrorPlaceholder("Photo unavailable")
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
        DecoratorTarget(floor: floor, coord: coord, kind: .picture, direction: direction).tag(frameNode)
        registerAddedPicture(coord, direction, material, newWallMaterials)

        if store.picturesUseCameraRoll {
            PhotoRollProvider.shared.randomImages(count: 1, caller: "decorator live add floor \(floor) coord \(coord) wall \(direction)") { [weak material, weak store] _, identifier, image in
                guard let material else { return }
                material.diffuse.contents = image.map { HallwayScene.framedPhoto($0) } ?? HallwayScene.mirrorPlaceholder("Photo unavailable")
                if let identifier { store?.reportCurrentPictureIdentity(.cameraRoll(identifier), at: WallFace(coord: coord, direction: direction)) }
            }
        }

        selection = DecoratorTarget(floor: floor, coord: coord, kind: .picture, direction: direction)
        save(target)
    }

    /// Sept 24 (Empty Wall chooser, decorative room doors): whether ADD
    /// -> Door should be enabled for the tapped empty wall -- the choice
    /// beside "Add Picture", backed by MazeStore.canPlaceRoomDoor, its
    /// own full face-specific occupancy check (modeled on
    /// canPlacePicture: genuinely solid, unclaimed, non-elevator,
    /// non-mission walls only).
    func canAddDoor(_ target: DecoratorTarget) -> Bool {
        guard enabled, target.kind == .wallSurface, let store, let coord = target.coord, let direction = target.direction else { return false }
        return store.canPlaceRoomDoor(direction, at: coord)
    }

    /// Sept 24 (Empty Wall chooser, decorative room doors): tap an empty
    /// ordinary wall -> ADD -> Door. Places a NONFUNCTIONAL/
    /// architectural room door -- the SAME visual (makeRoomDoorNode) and
    /// the SAME automatic room-number assignment (MazeStore.
    /// placeRoomDoor, the editor/functional door's own placer, shared
    /// rather than re-implemented) -- but with its `decorative` flag set
    /// so it carries zero gameplay: no mail, no opening, no walk stop,
    /// no room of its own (see the TapNavigationController door gates).
    /// Like addPicture, this keeps the snapshot -> mutate store -> build
    /// the live node -> tag it -> select it -> save shape. Unlike
    /// addPicture, the ordinary wall panel underneath is deliberately
    /// KEPT: HallwayScene.build builds every room door the same way --
    /// over its own ordinary panel -- so a live-added door must render
    /// identically to a build-time one. Deleting the door simply
    /// reveals the panel that was always behind it, so the restored
    /// face is immediately a valid Empty Wall target again.
    func addDoor() {
        guard enabled, let target = selection, target.kind == .wallSurface,
              let coord = target.coord, let direction = target.direction,
              canAddDoor(target), let store, let scene else { return }
        guard let hallwayRoot = scene.rootNode.childNode(withName: "hallwaySceneRoot", recursively: false) else { return }
        store.snapshotForUndo()
        store.placeRoomDoor(direction, at: coord, decorative: true)
        guard let door = store.roomDoors[coord] else { return }
        let doorNode = HallwayScene.makeRoomDoorNode(door, cellSize: store.cellSize)
        hallwayRoot.addChildNode(doorNode)
        DecoratorTarget(floor: floor, coord: coord, kind: .roomDoor, direction: direction).tag(doorNode)
        registerRoomDoor(door)
        selection = DecoratorTarget(floor: floor, coord: coord, kind: .roomDoor, direction: direction)
        save(target)
    }

    /// Sept 24: the reverse of addDoor. Removes the tagged door node
    /// (the panel was never removed, so nothing to restore -- the face
    /// simply reads "Empty Wall" again), removes the authored placement
    /// from MazeStore, and persists. Only ever reached with a tagged
    /// .roomDoor target, and only DECORATIVE doors are tagged (see
    /// HallwayScene.build's door loop), so functional/mail doors are
    /// not reachable here.
    func deleteRoomDoor() {
        guard enabled, let target = selection, target.kind == .roomDoor,
              exists(target), let coord = target.coord, let direction = target.direction,
              let store, let scene else { return }
        guard let hallwayRoot = scene.rootNode.childNode(withName: "hallwaySceneRoot", recursively: false) else { return }
        let liveNodes = nodes(for: target)
        store.snapshotForUndo()
        store.removeRoomDoor(at: coord)
        unregisterRoomDoor(coord)
        for node in liveNodes { node.removeFromParentNode() }
        selection = DecoratorTarget(floor: floor, coord: coord, kind: .wallSurface, direction: direction)
        save(target)
    }

    /// Sept 25 (Designer wall authoring, live Mirror ADD): whether
    /// ADD -> Mirror should be enabled for the tapped empty wall --
    /// backed by MazeStore.canPlaceMirror, the same full face-specific
    /// occupancy check the build-time mirror loop and the Floor Editor
    /// already rely on.
    func canAddMirror(_ target: DecoratorTarget) -> Bool {
        guard enabled, target.kind == .wallSurface, let store, let coord = target.coord, let direction = target.direction else { return false }
        return store.canPlaceMirror(direction, at: coord)
    }

    /// Sept 25 (Designer wall authoring): tap an empty wall -> ADD ->
    /// Mirror. Places a REAL working mirror -- the SAME makeMirrorNode
    /// build(fromMaze:)'s mirror loop uses, including its
    /// "mirrorSurface"-named child -- then registers it into the two
    /// pieces of live state build-time mirrors already have: the walk-
    /// stop bookkeeping (registerMirror -> TapNavigationController.
    /// pictureCoords, so walks halt on every pass exactly like build-
    /// time mirrors) and the live camera feed (registerMirrorSurface ->
    /// MirrorCamera.addSurface, with the surface's real aspect, so the
    /// player's reflection shows in the new glass without a floor
    /// reload).
    ///
    /// The ordinary wall panel underneath is deliberately KEPT -- same
    /// reasoning as addDoor above (the mirror simply mounts proud of the
    /// existing face; the build-time loop skips the panel because it
    /// wall-mounts mirrors flush, but over an intact panel the same
    /// frame reads identically), so no wall backfill is needed and
    /// deleting the mirror immediately re-reveals a valid Empty Wall.
    func addMirror() {
        guard enabled, let target = selection, target.kind == .wallSurface,
              let coord = target.coord, let direction = target.direction,
              canAddMirror(target), let store, let scene else { return }
        store.snapshotForUndo()
        store.placeMirror(direction, at: coord)
        let mirrorNode = HallwayScene.makeMirrorNode(at: coord, direction: direction, cellSize: store.cellSize)
        scene.rootNode.addChildNode(mirrorNode)
        DecoratorTarget(floor: floor, coord: coord, kind: .mirror, direction: direction).tag(mirrorNode)
        registerMirror(coord, direction)
        if let surface = mirrorNode.childNode(withName: "mirrorSurface", recursively: true),
           let material = surface.geometry?.firstMaterial {
            registerMirrorSurface(material, HallwayScene.mirrorSurfaceAspect(of: surface))
        }
        selection = DecoratorTarget(floor: floor, coord: coord, kind: .mirror, direction: direction)
        save(target)
    }

    /// Sept 25: the reverse of addMirror. Deregisters the walk-stop and
    /// camera feed (unregisterMirror/unregisterMirrorSurface), removes
    /// the authored placement from MazeStore, and removes the tagged
    /// node. The wall panel was never removed, so the restored face
    /// immediately reads "Empty Wall" again.
    func deleteMirror() {
        guard enabled, let target = selection, target.kind == .mirror,
              exists(target), let coord = target.coord, let direction = target.direction,
              let store, let scene else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        var surfaceMaterial: SCNMaterial?
        for node in liveNodes {
            if let surface = node.childNode(withName: "mirrorSurface", recursively: true) {
                surfaceMaterial = surface.geometry?.firstMaterial
            }
        }
        store.snapshotForUndo()
        store.removeMirror(at: coord)
        unregisterMirror(coord, direction)
        if let material = surfaceMaterial { unregisterMirrorSurface(material) }
        for node in liveNodes { node.removeFromParentNode() }
        selection = DecoratorTarget(floor: floor, coord: coord, kind: .wallSurface, direction: direction)
        save(target)
    }

    /// Sept 25 (Designer wall authoring, live Extinguisher ADD): whether
    /// ADD -> Fire Extinguisher should be enabled for the tapped empty
    /// wall -- backed by the new MazeStore.canPlaceExtinguisher, the
    /// face-specific check modeled on canPlacePhotoBooth.
    func canAddExtinguisher(_ target: DecoratorTarget) -> Bool {
        guard enabled, target.kind == .wallSurface, let store, let coord = target.coord, let direction = target.direction else { return false }
        return store.canPlaceExtinguisher(direction, at: coord)
    }

    /// Sept 25 (Designer wall authoring): tap an empty wall -> ADD ->
    /// Fire Extinguisher. Places the Floor-5 mission pickup (same
    /// makeFireExtinguisherNode the build loop uses), on top of the kept
    /// wall panel like addMirror above, and registers it into
    /// TapNavigationController (registerLiveExtinguisher -> extinguisher
    /// bookkeeping + resting transform) so the player can pick it up
    /// immediately and it behaves exactly like a map-authored one.
    func addExtinguisher() {
        guard enabled, let target = selection, target.kind == .wallSurface,
              let coord = target.coord, let direction = target.direction,
              canAddExtinguisher(target), let store, let scene else { return }
        store.snapshotForUndo()
        store.placeExtinguisher(direction, at: coord)
        let node = HallwayScene.makeFireExtinguisherNode(at: coord, direction: direction, cellSize: store.cellSize)
        scene.rootNode.addChildNode(node)
        DecoratorTarget(floor: floor, coord: coord, kind: .extinguisher, direction: direction).tag(node)
        registerLiveExtinguisher(direction, coord, node)
        selection = DecoratorTarget(floor: floor, coord: coord, kind: .extinguisher, direction: direction)
        save(target)
    }

    /// Sept 25: the reverse of addExtinguisher. Deregisters the pickup
    /// bookkeeping (including dropping the item if it happens to be
    /// carried), removes the authored placement, and removes the node.
    func deleteExtinguisher() {
        guard enabled, let target = selection, target.kind == .extinguisher,
              exists(target), let store, let coord = target.coord else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        // deleteContent takes its own snapshot (one undo step, same as
        // deleteRoomDoor's removeRoomDoor path above).
        store.deleteContent([.extinguishers], at: coord)
        unregisterLiveExtinguisher(coord)
        for node in liveNodes { node.removeFromParentNode() }
        selection = DecoratorTarget(floor: floor, coord: coord, kind: .wallSurface, direction: target.direction)
        save(target)
    }

    /// Sept 25 (Designer wall authoring, live Photo Booth ADD): whether
    /// ADD -> Photo Booth should be enabled for the tapped empty wall --
    /// backed by MazeStore.canPlacePhotoBooth.
    func canAddPhotoBooth(_ target: DecoratorTarget) -> Bool {
        guard enabled, target.kind == .wallSurface, let store, let coord = target.coord, let direction = target.direction else { return false }
        return store.canPlacePhotoBooth(direction, at: coord)
    }

    /// Sept 25 (Designer wall authoring): tap an empty wall -> ADD ->
    /// Photo Booth. Places the Floor-6 mission fixture (same
    /// makePhotoBoothNode the build loop uses; expression defaults to
    /// .smile, the same authoring default every DefaultMazes.json booth
    /// starts from) on top of the kept wall panel, and registers it into
    /// TapNavigationController (registerLivePhotoBooth -> booth
    /// bookkeeping) so the player can pose/activate it immediately and
    /// the floor's photo-booth mission count includes it -- Eddie's
    /// Sept 25 "join the real mission" direction.
    func addPhotoBooth() {
        guard enabled, let target = selection, target.kind == .wallSurface,
              let coord = target.coord, let direction = target.direction,
              canAddPhotoBooth(target), let store, let scene else { return }
        store.snapshotForUndo()
        store.placePhotoBooth(direction, expression: .smile, at: coord)
        let node = HallwayScene.makePhotoBoothNode(at: coord, direction: direction, expression: .smile, cellSize: store.cellSize)
        scene.rootNode.addChildNode(node)
        DecoratorTarget(floor: floor, coord: coord, kind: .photoBooth, direction: direction).tag(node)
        registerLivePhotoBooth(direction, coord, node)
        selection = DecoratorTarget(floor: floor, coord: coord, kind: .photoBooth, direction: direction)
        save(target)
    }

    /// Sept 25: the reverse of addPhotoBooth. Deregisters the booth
    /// bookkeeping (and cancels any in-flight session), removes the
    /// authored placement, and removes the node.
    func deletePhotoBooth() {
        guard enabled, let target = selection, target.kind == .photoBooth,
              exists(target), let store, let coord = target.coord else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        // deleteContent takes its own snapshot (one undo step, same as
        // deleteExtinguisher above).
        store.deleteContent([.photoBooths], at: coord)
        unregisterLivePhotoBooth(coord)
        for node in liveNodes { node.removeFromParentNode() }
        selection = DecoratorTarget(floor: floor, coord: coord, kind: .wallSurface, direction: target.direction)
        save(target)
    }

    /// Sept 21 (Floor Object current-cell authoring): the catalog
    /// behind the small ADD menu beside DECORATE/DONE (DecoratorOverlay,
    /// below in this file). Deliberately just an extensible dispatch
    /// key, not a generalized object registry -- Eddie: "avoid
    /// hard-wiring the BUTTON itself as a Trash Can button," but "do
    /// NOT build speculative systems" for anything beyond today's one
    /// item.
    ///
    /// Sept 23 (Decorator Floor expansion, Eddie: decorating Floors
    /// 2-6): three more cases -- Envelope and Paint Bucket are the
    /// Floor 3/4 mission pickups, both EXISTING ObjectKind cases with
    /// no authoring path anywhere in the app before now (GridEditorView
    /// never placed them either -- their only route onto a floor was a
    /// hand-authored MazeStore.objects entry). Fire is the Floor 5
    /// mission's OTHER existing physical light source (see
    /// MazeStore.placeFire's own doc comment) -- NOT an ObjectKind at
    /// all, its own independent Set<GridCoordinate>, so unlike the
    /// other three cases it does not go through `kind`/placeObject
    /// below; canAddFloorObjectAtCurrentCell/addFloorObject switch on
    /// `self` now instead of being 100% generic, exactly as this
    /// doc comment's own predecessor anticipated ("one more case here
    /// and one more branch in addFloorObject below").
    enum FloorObjectCatalogItem: CaseIterable, Hashable {
        case trashCan
        case envelope
        case paintBucket
        case fire

        var title: String {
            switch self {
            case .trashCan: return "Trash Can"
            case .envelope: return "Envelope"
            case .paintBucket: return "Paint Bucket"
            case .fire: return "Fire"
            }
        }

        fileprivate var kind: ObjectKind? {
            switch self {
            case .trashCan: return .trashCan
            case .envelope: return .envelope
            case .paintBucket: return .paintBucket
            case .fire: return nil // not an ObjectKind -- see this enum's own doc comment
            }
        }
    }

    /// Sept 21 (Floor Object current-cell authoring): whether ADD ->
    /// Floor Object -> <item> would succeed right now -- DECORATE must
    /// be on, the player's current cell must be known (currentPlayerCell,
    /// wired from ContentView) and open. Trash Can/Envelope/Paint Bucket
    /// share the existing one-object-per-cell data model (MazeStore.
    /// objects is keyed by a single GridCoordinate -- must be empty);
    /// Fire (Sept 23) is a completely independent authored set with its
    /// own occupancy check (MazeStore.hasFire), since a cell can hold a
    /// Fire AND a Floor Object/ceiling fixture at the same time in the
    /// existing data model (different Y heights, never drawn on top of
    /// each other). Backs the menu item's own .disabled(...) in
    /// DecoratorOverlay, so an occupied/unknown current cell refuses
    /// cleanly instead of silently overwriting whatever's already there.
    func canAddFloorObjectAtCurrentCell(_ item: FloorObjectCatalogItem) -> Bool {
        guard enabled, let store, let coord = currentPlayerCell(), store.cells.contains(coord) else { return false }
        switch item {
        case .trashCan, .envelope, .paintBucket: return store.objects[coord] == nil
        case .fire: return !store.hasFire(coord)
        }
    }

    /// Sept 21 (Floor Object current-cell authoring): the world-tap-free
    /// entrance for creating a Floor Object -- tap ADD (beside DONE) ->
    /// Floor Object -> <item>, no trip to the Floor Editor. Same overall
    /// shape as addPicture() above (snapshot -> mutate store -> build
    /// the live node -> tag/register it -> select it -> save).
    ///
    /// Trash Can still goes through HallwayScene.buildTrashCanNode --
    /// the SAME static method the per-cell scene-build loop itself
    /// calls -- exactly as before. Envelope/Paint Bucket (Sept 23) go
    /// through the SAME two functions build(fromMaze:)'s own per-cell
    /// loop calls for every non-trash-can pickup (HallwayScene.
    /// makeEnvelopeNode(roomNumber:)/makeObjectNode(_:size:floorNumber:),
    /// both widened from `private` to internal for this -- see their
    /// own doc comments), at the SAME height/no-offset convention that
    /// loop uses, then tagged the same way buildTrashCanNode already
    /// tags itself. Fire (Sept 23) goes through HallwayScene.
    /// makeFireNode, already internal, and MazeStore.placeFire/
    /// removeFire -- its own independent authored kind, kept
    /// deliberately OUT of the ceiling/fluorescent light machinery
    /// elsewhere in this file (place/remove/changeBrightness/
    /// deleteSelected/move/add) so the recently-tuned fluorescent
    /// recipe is never at risk from this addition; see fireBrightness/
    /// changeFireBrightness/deleteFire below for its own small,
    /// independent add/remove/brightness path.
    func addFloorObject(_ item: FloorObjectCatalogItem) {
        guard canAddFloorObjectAtCurrentCell(item), let store, let coord = currentPlayerCell(), let scene else { return }
        store.snapshotForUndo()
        switch item {
        case .trashCan:
            guard let hallwayRoot = scene.rootNode.childNode(withName: "hallwaySceneRoot", recursively: false) else { return }
            store.placeObject(.trashCan, at: coord)
            let placement = FloorObjectPlacement()
            store.setFloorObjectPlacement(placement, at: coord)
            let node = HallwayScene.buildTrashCanNode(at: coord, cellSize: store.cellSize, floorNumber: floor, placement: placement)
            hallwayRoot.addChildNode(node)
            registerFloorObject(.trashCan, coord, node)
            let target = DecoratorTarget(floor: floor, coord: coord, kind: .floorObject)
            selection = target
            save(target)
        case .envelope, .paintBucket:
            guard let hallwayRoot = scene.rootNode.childNode(withName: "hallwaySceneRoot", recursively: false), let kind = item.kind else { return }
            store.placeObject(kind, at: coord)
            let node = kind == .envelope
                ? HallwayScene.makeEnvelopeNode(roomNumber: store.itemRooms[coord])
                : HallwayScene.makeObjectNode(kind, size: store.cellSize * 0.22, floorNumber: floor)
            let objectY = store.wallHeight * (kind == .envelope ? 0.4 : 0.25)
            node.position = SCNVector3(Float(coord.col) * Float(store.cellSize), Float(objectY), Float(coord.row) * Float(store.cellSize))
            let target = DecoratorTarget(floor: floor, coord: coord, kind: .floorObject)
            target.tag(node)
            hallwayRoot.addChildNode(node)
            registerFloorObject(kind, coord, node)
            selection = target
            save(target)
        case .fire:
            store.placeFire(at: coord, brightness: 3)
            let node = HallwayScene.makeFireNode(at: coord, cellSize: store.cellSize, brightness: 3)
            let target = DecoratorTarget(floor: floor, coord: coord, kind: .fire)
            target.tag(node)
            scene.rootNode.addChildNode(node)
            // Sept 25: register into TapNavigationController's fire
            // bookkeeping so a Designer-authored fire is extinguishable
            // AND counted by the floor's fire mission, exactly like a
            // DefaultMazes.json-authored one (Eddie: join the real
            // mission, not just the scenery).
            registerLiveFire(coord, node)
            selection = target
            save(target)
        }
    }

    /// Sept 21 (Floor Object placement, first pass): the specific
    /// removal path Floor Objects never got in that first pass --
    /// added Sept 23 alongside Envelope/Paint Bucket/Fire so every
    /// Floor-category item is fully removable, per this task's own
    /// requirement. Covers Trash Can/Envelope/Paint Bucket (Fire has
    /// its own deleteFire below, since it's a different DecoratorTarget
    /// kind). Same shape as deleteSelected() elsewhere in this file.
    func deleteFloorObject() {
        guard enabled, let target = selection, target.kind == .floorObject,
              exists(target), let store, let coord = target.coord else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        store.snapshotForUndo()
        store.removeObject(at: coord)
        unregisterFloorObject(coord)
        for node in liveNodes { node.removeFromParentNode() }
        selection = nil
        save(target)
    }

    /// Sept 27 (Decorator Room Entrance authoring): whether "+" -> Door
    /// Entry would succeed right now -- unlike every other "+" menu
    /// item, Room Entrance has NO catalog/direction picker in Decorator:
    /// the player's current cell and current facing ALREADY determine
    /// the exact wall face (current cell -> facing direction ->
    /// boundary -> neighbor cell), so this reads both live-navigation
    /// closures instead of a target/selection. Backed by MazeStore.
    /// canPlaceRoomEntranceDoor -- the SAME validation the 2D Grid
    /// Editor's own Room Entrance tool placer uses -- so a face already
    /// claimed by another fixture, a missing/solid cell behind it, or
    /// the elevator/mission cell all refuse identically in both
    /// authoring routes, never a fake door.
    func canAddRoomEntranceDoorAtCurrentCell() -> Bool {
        guard enabled, let store, let coord = currentPlayerCell(), let direction = currentPlayerFacing() else { return false }
        return store.canPlaceRoomEntranceDoor(direction, at: coord)
    }

    /// Sept 27 (Decorator Room Entrance authoring): the "+" -> Door
    /// Entry entrance. Reuses MazeStore.placeRoomEntranceDoor (the SAME
    /// store mutation the 2D Grid Editor's own Room Entrance tool
    /// calls -- one persisted dictionary, two authoring routes) and the
    /// EXACT rendering HallwayScene.build's own roomEntranceDoors loop
    /// uses for a build-time door: HallwayScene.buildDoorFrame (the 4
    /// frame strips around the opening) plus HallwayScene.
    /// makeBathroomDoorPanel(hingeNamePrefix: "roomEntranceDoor",
    /// includeSign: false) (the hinge + swinging panel) -- same door
    /// size constants (doorWidth/doorHeight/doorCenterY) as that loop,
    /// so a Decorator-placed door is pixel-identical to a build-time
    /// one. The hinge node's name ("roomEntranceDoor_<row>_<col>") is
    /// exactly what Play mode's EXISTING roomEntranceDoorCoordinate(for:)/
    /// openRoomEntranceDoor tap handling already looks for by name --
    /// zero new Play-mode wiring needed; tapping this live-added door
    /// in Play swings it open exactly like a build-time one.
    ///
    /// Both the frame strips (tagged via buildDoorFrame's own `tag:`
    /// closure, the same mechanism buildPictureBackfill already uses)
    /// and the hinge node are tagged with the SAME DecoratorTarget, so
    /// tapping either one in Decorate selects the whole door assembly,
    /// never an internal panel/frame child on its own -- see nodes(for:)
    /// above, which collects every node carrying that identical tag.
    ///
    /// No wall panel exists to remove or restore here (unlike addDoor/
    /// addMirror/addPicture, which all operate on an existing solid
    /// `.wallSurface`): both cells are already ordinary open cells, so
    /// the build-time render loop never draws a wall at this boundary
    /// in the first place -- the frame is purely decorative dressing
    /// around the opening, same as it is at build time.
    func addRoomEntranceDoorAtCurrentCell() {
        guard canAddRoomEntranceDoorAtCurrentCell(), let store, let scene,
              let coord = currentPlayerCell(), let direction = currentPlayerFacing() else { return }
        guard let hallwayRoot = scene.rootNode.childNode(withName: "hallwaySceneRoot", recursively: false) else { return }
        store.snapshotForUndo()
        store.placeRoomEntranceDoor(direction, at: coord)

        let target = DecoratorTarget(floor: floor, coord: coord, kind: .roomEntranceDoor, direction: direction)

        // Sept 27 (live-delete leak fix): one owning "assembly" node
        // for the whole thing this function creates -- frame strips
        // AND hinge both become its children instead of siblings added
        // separately to hallwayRoot. Named the same predictable way
        // the hinge itself already is (mirrors "roomEntranceDoor_<row>_
        // <col>") so deleteRoomEntranceDoor can also find and remove
        // this exact node by name as a deterministic safety net,
        // completely independent of tag-based lookup.
        let assembly = SCNNode()
        assembly.name = "roomEntranceDoorAssembly_\(coord.row)_\(coord.col)"
        target.tag(assembly)
        hallwayRoot.addChildNode(assembly)

        let half = store.cellSize / 2
        let doorX = CGFloat(coord.col) * store.cellSize
        let doorZ = CGFloat(coord.row) * store.cellSize
        let wx: CGFloat
        let wz: CGFloat
        switch direction {
        case .north: (wx, wz) = (doorX, doorZ - half)
        case .south: (wx, wz) = (doorX, doorZ + half)
        case .east: (wx, wz) = (doorX + half, doorZ)
        case .west: (wx, wz) = (doorX - half, doorZ)
        }
        // Same fixed door size as HallwayScene.build's own
        // roomEntranceDoors render loop (roomEntranceDoorWidth/Height/
        // CenterY there) -- kept in sync by hand since neither is
        // exposed as a shared constant; both call sites are small and
        // unlikely to drift, and extracting one wasn't necessary for
        // this pass.
        let doorWidth: CGFloat = 1.0
        let doorHeight: CGFloat = 2.2
        let doorCenterY = doorHeight / 2

        var newWallMaterials: [SCNMaterial] = []
        _ = HallwayScene.buildDoorFrame(direction: direction, wallCenterX: wx, wallCenterZ: wz, doorWidth: doorWidth, doorHeight: doorHeight, doorCenterY: doorCenterY, cellSize: store.cellSize, wallHeight: store.wallHeight, effectiveWallImageName: currentWallImageName(), root: assembly, wallMaterials: &newWallMaterials, tag: { target.tag($0) })
        let hinge = HallwayScene.makeBathroomDoorPanel(at: coord, direction: direction, wallCenterX: wx, wallCenterZ: wz, doorWidth: doorWidth, doorHeight: doorHeight, doorCenterY: doorCenterY, hingeNamePrefix: "roomEntranceDoor", includeSign: false)
        target.tag(hinge)
        assembly.addChildNode(hinge)
        appendWallMaterials(newWallMaterials)
        registerLiveRoomEntranceDoor(direction, coord)
        selection = target
        save(target)
    }

    /// Sept 27 (Decorator Room Entrance authoring): removal -- same
    /// overall shape as deleteFire()/deleteRoomDoor() above. Unlike
    /// those two (which restore an ordinary wall panel, or reveal an
    /// already-intact Empty Wall), a Room Entrance has NO wall panel
    /// underneath it at all: both cells were already ordinary open
    /// cells before the door existed, so removing every tagged node
    /// (frame strips + hinge) simply leaves the boundary between them
    /// open again, with no floor reload needed -- exactly Eddie's own
    /// "CELL | DOOR | CELL" -> "CELL     CELL" requirement.
    /// unregisterLiveRoomEntranceDoor drops TapNavigationController's
    /// own copy immediately, so movement gating, the tap-to-open
    /// lookup, and the map's red door-face indicator all update without
    /// a rebuild.
    func deleteRoomEntranceDoor() {
        guard enabled, let target = selection, target.kind == .roomEntranceDoor,
              exists(target), let store, let coord = target.coord else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        store.snapshotForUndo()
        store.removeRoomEntranceDoor(at: coord)
        unregisterLiveRoomEntranceDoor(coord)
        for node in liveNodes { node.removeFromParentNode() }
        // Sept 27 (live-delete leak fix): the frame strips and hinge
        // both live inside one owning "roomEntranceDoorAssembly_<row>_
        // <col>" node now (see addRoomEntranceDoorAtCurrentCell and
        // HallwayScene.build's own roomEntranceDoors loop, both of
        // which create it) -- removing that ONE node by its stable
        // name is a deterministic guarantee the whole architectural
        // assembly is gone, independent of the tag-based nodes(for:)
        // lookup just above (which stays, as a harmless first pass --
        // removeFromParentNode() on an already-detached node is a
        // no-op).
        scene?.rootNode.childNode(withName: "roomEntranceDoorAssembly_\(coord.row)_\(coord.col)", recursively: true)?.removeFromParentNode()
        selection = nil
        save(target)
    }

    /// Sept 27 (door cosmetics pass): read-only lookups the selected-
    /// object panel's Texture/Style controls use to show the door's
    /// CURRENT choice (checkmark in the texture grid, checkmark in the
    /// Style menu) -- both nil/.plain-safe if nothing is selected, no
    /// Room Entrance is selected, or the coordinate's door was deleted
    /// out from under an open sheet.
    func currentRoomEntranceDoorStyle() -> RoomEntranceDoorStyle? {
        guard let target = selection, target.kind == .roomEntranceDoor, let store, let coord = target.coord else { return nil }
        return store.roomEntranceDoors[coord]?.style
    }

    func currentRoomEntranceDoorTexture() -> String? {
        guard let target = selection, target.kind == .roomEntranceDoor, let store, let coord = target.coord else { return nil }
        return store.roomEntranceDoors[coord]?.textureName
    }

    /// Sept 27 (door cosmetics pass): the Texture/Style controls' own
    /// mutators -- persist via the new MazeStore setters (which keep
    /// coord/direction untouched, only style/textureName change) and
    /// immediately rebuild JUST this one door's swinging leaf in the
    /// live scene (rebuildLiveRoomEntranceDoorVisual below), same
    /// "player stays exactly where he is" contract as every other live
    /// Decorator edit in this file.
    func setRoomEntranceDoorStyle(_ style: RoomEntranceDoorStyle) {
        guard let target = selection, target.kind == .roomEntranceDoor, let store, let coord = target.coord else { return }
        store.setRoomEntranceDoorStyle(style, at: coord)
        rebuildLiveRoomEntranceDoorVisual(at: coord)
        save(target)
    }

    func setRoomEntranceDoorTexture(_ textureName: String?) {
        guard let target = selection, target.kind == .roomEntranceDoor, let store, let coord = target.coord else { return }
        store.setRoomEntranceDoorTexture(textureName, at: coord)
        rebuildLiveRoomEntranceDoorVisual(at: coord)
        save(target)
    }

    /// Sept 27 (door cosmetics live update): swaps out ONLY this door's
    /// swinging leaf node -- never the doorway's own frame strips
    /// (those are ordinary wall material, untouched by a door's own
    /// style/texture) and never the whole floor. Finds the CURRENT
    /// hinge purely by its stable name (roomEntranceDoor_<row>_<col>,
    /// unaffected by style/texture changes -- the exact name
    /// TapNavigationController's swing/gating logic also looks up by),
    /// removes it, and rebuilds it fresh via the same
    /// makeRoomEntranceDoorPanel construction HallwayScene.build's own
    /// render loop and addRoomEntranceDoorAtCurrentCell both use, so a
    /// Decorator-edited door stays pixel-identical to a build-time one.
    /// Re-tags the fresh hinge with the SAME DecoratorTarget identity so
    /// it stays selectable/deletable afterward without needing to
    /// re-tap it. Swing rotation is deliberately not preserved across
    /// this swap -- Decorate mode never shows a Room Entrance open, so
    /// there is never a non-zero rotation to carry over.
    func rebuildLiveRoomEntranceDoorVisual(at coord: GridCoordinate) {
        guard let store, let scene, let placement = store.roomEntranceDoors[coord] else { return }
        guard let hallwayRoot = scene.rootNode.childNode(withName: "hallwaySceneRoot", recursively: false) else { return }
        let hingeName = "roomEntranceDoor_\(coord.row)_\(coord.col)"
        hallwayRoot.childNode(withName: hingeName, recursively: true)?.removeFromParentNode()
        // Sept 27 (live-delete leak fix): the fresh hinge belongs back
        // inside this door's own owning assembly node (found by its
        // stable name), not loose under hallwayRoot -- otherwise a
        // Style/Texture change would silently pull the hinge back OUT
        // of the assembly deleteRoomEntranceDoor removes by name,
        // reintroducing exactly the leak this pass fixes. Falls back
        // to hallwayRoot only for the unreachable case of a door whose
        // assembly node somehow doesn't exist.
        let assemblyName = "roomEntranceDoorAssembly_\(coord.row)_\(coord.col)"
        let assemblyParent = hallwayRoot.childNode(withName: assemblyName, recursively: true) ?? hallwayRoot

        let direction = placement.direction
        let half = store.cellSize / 2
        let doorX = CGFloat(coord.col) * store.cellSize
        let doorZ = CGFloat(coord.row) * store.cellSize
        let wx: CGFloat
        let wz: CGFloat
        switch direction {
        case .north: (wx, wz) = (doorX, doorZ - half)
        case .south: (wx, wz) = (doorX, doorZ + half)
        case .east: (wx, wz) = (doorX + half, doorZ)
        case .west: (wx, wz) = (doorX - half, doorZ)
        }
        let doorWidth: CGFloat = 1.0
        let doorHeight: CGFloat = 2.2
        let doorCenterY = doorHeight / 2
        let hinge = HallwayScene.makeRoomEntranceDoorPanel(at: coord, direction: direction, wallCenterX: wx, wallCenterZ: wz, doorWidth: doorWidth, doorHeight: doorHeight, doorCenterY: doorCenterY, style: placement.style, textureName: placement.textureName)
        // Sept 27 (tap-routing fix): tag with a FRESH target built
        // straight from this door's own coord/direction/floor -- not
        // conditionally reused from `selection` -- so a rebuilt door
        // stays Decorator-selectable exactly like the build-time and
        // live-add paths, with nothing left to fall out of sync.
        DecoratorTarget(floor: floor, coord: coord, kind: .roomEntranceDoor, direction: direction).tag(hinge)
        assemblyParent.addChildNode(hinge)
    }

    /// Hanging is a catalog category; each item retains its own gameplay behavior.
    enum HangingObjectCatalogItem: CaseIterable, Hashable {
        case money

        var title: String {
            switch self {
            case .money: return "Money"
            }
        }

        var kind: ObjectKind {
            switch self {
            case .money: return .cash100
            }
        }
    }

    func canAddHangingObjectAtCurrentCell(_ item: HangingObjectCatalogItem) -> Bool {
        guard enabled, let store, store.currentMazeID == floor,
              let coord = currentPlayerCell(), store.cells.contains(coord) else { return false }
        return store.objects[coord] == nil
    }

    func addHangingObjectAtCurrentCell(_ item: HangingObjectCatalogItem) {
        guard canAddHangingObjectAtCurrentCell(item), let store,
              let coord = currentPlayerCell(),
              let hallwayRoot = scene?.rootNode.childNode(withName: "hallwaySceneRoot", recursively: false) else { return }
        store.snapshotForUndo()
        store.placeObject(item.kind, at: coord)
        let assembly = HallwayScene.buildPickupAssembly(item.kind, at: coord,
            cellSize: store.cellSize, wallHeight: store.wallHeight, floorNumber: floor)
        hallwayRoot.addChildNode(assembly)
        registerFloorObject(item.kind, coord, assembly)
        let target = DecoratorTarget(floor: floor, coord: coord, kind: .floorObject)
        selection = target
        save(target)
    }

    /// Sept 21 (current-cell Ceiling authoring): the catalog behind
    /// "+" -> Ceiling, same extensible-dispatch-key shape as
    /// FloorObjectCatalogItem above.
    ///
    /// Sept 23 (Decorator Ceiling expansion, Eddie: decorating Floors
    /// 2-6): two more cases. Spotlight is the EXISTING plain (non-
    /// fluorescent) ceiling fixture -- DecoratorTarget.Kind.ceiling,
    /// MazeStore.spotlights, `add(.ceiling)` -- which already had a
    /// full world-tap authoring path (tap an empty ceiling -> "Add
    /// Ceiling") but was never in this current-cell catalog; exposing
    /// it here reuses `add(.ceiling)` completely unchanged, same as
    /// Fluorescent already does with `add(.fluorescent)`. Exit Sign is
    /// its own independent authored kind (see canAddExitSignAtCurrentCell/
    /// addExitSignAtCurrentCell below), deliberately NOT routed through
    /// add(_:)/canAdd(_:) since it participates in neither the light
    /// machinery nor that machinery's mutual-exclusion rule (a cell can
    /// hold a ceiling light/fluorescent AND an Exit Sign at once in the
    /// existing data model -- GridEditorView already allows this).
    enum CeilingObjectCatalogItem: CaseIterable, Hashable {
        case fluorescent
        case spotlight
        case exitSign

        var title: String {
            switch self {
            case .fluorescent: return "Fluorescent Light"
            case .spotlight: return "Spotlight"
            case .exitSign: return "Exit Sign"
            }
        }
    }

    /// Sept 21 (current-cell Ceiling authoring): whether "+" -> Ceiling
    /// -> <item> would succeed right now -- Fluorescent/Spotlight reuse
    /// canAdd(_:) UNCHANGED (exists(target) + canPlace(at:), the SAME
    /// legality a world tap on this cell's ceiling already goes
    /// through), just keyed off the player's current cell instead of a
    /// tapped DecoratorTarget. Exit Sign (Sept 23) has its own
    /// independent legality -- see canAddExitSignAtCurrentCell below.
    /// Backs the menu item's own .disabled(...) in DecoratorOverlay.
    func canAddCeilingObjectAtCurrentCell(_ item: CeilingObjectCatalogItem) -> Bool {
        guard enabled, let coord = currentPlayerCell() else { return false }
        switch item {
        case .fluorescent: return canAdd(DecoratorTarget(floor: floor, coord: coord, kind: .ceilingSurface), kind: .fluorescent)
        case .spotlight: return canAdd(DecoratorTarget(floor: floor, coord: coord, kind: .ceilingSurface), kind: .ceiling)
        case .exitSign: return canAddExitSignAtCurrentCell()
        }
    }

    /// Sept 21 (current-cell Ceiling authoring): the "+" -> Ceiling ->
    /// Fluorescent Light/Spotlight entrance -- builds the EXACT
    /// .ceilingSurface DecoratorTarget a world tap on the current
    /// cell's ceiling would produce, selects it (same as select(at:in:)
    /// does for a real tap), then calls the EXISTING add(_:) UNCHANGED.
    /// add(_:) does everything else: build the live fixture node, tag
    /// it, author it (brightness 3, MazeStore.placeFluorescent/
    /// placeSpotlight), persist, and select the new fixture -- opening
    /// the SAME inspector (brightness/orientation/move/delete) a
    /// world-tapped one already gets. No new construction, no new
    /// inspector for either case -- this function's only job is
    /// supplying the coordinate add(_:) would otherwise get from a tap.
    /// Exit Sign (Sept 23) is its own independent entrance -- see
    /// addExitSignAtCurrentCell below.
    func addCeilingObjectAtCurrentCell(_ item: CeilingObjectCatalogItem) {
        guard canAddCeilingObjectAtCurrentCell(item), let coord = currentPlayerCell() else { return }
        switch item {
        case .fluorescent:
            selection = DecoratorTarget(floor: floor, coord: coord, kind: .ceilingSurface)
            add(.fluorescent)
        case .spotlight:
            selection = DecoratorTarget(floor: floor, coord: coord, kind: .ceilingSurface)
            add(.ceiling)
        case .exitSign:
            addExitSignAtCurrentCell()
        }
    }

    /// Sept 23 (Decorator Ceiling expansion: Exit Sign): whether "+" ->
    /// Ceiling -> Exit Sign would succeed right now. Deliberately NOT
    /// canAdd(_:)/canPlace(at:) -- those gate specifically on
    /// spotlights/fluorescentLights mutual exclusion, which an Exit
    /// Sign has never participated in (MazeStore.placeExitSign's own
    /// guard is just `cells.contains(coord)`; GridEditorView already
    /// lets one go on any open cell regardless of what else is there).
    /// One Exit Sign per cell is the only rule here -- repointing an
    /// existing one is a direction change (changeExitSignDirection
    /// below), not a second add.
    func canAddExitSignAtCurrentCell() -> Bool {
        guard enabled, let store, let coord = currentPlayerCell() else { return false }
        return store.cells.contains(coord) && !store.hasExitSign(coord)
    }

    /// Sept 23 (Decorator Ceiling expansion: Exit Sign): the "+" ->
    /// Ceiling -> Exit Sign entrance -- authors a new Exit Sign at the
    /// player's current cell, defaulting to `.north` (an arbitrary but
    /// harmless starting direction; changeExitSignDirection below lets
    /// it be repointed immediately from the inspector, same as every
    /// other authored direction in this app starts at a default and is
    /// then adjusted). Builds the live node through the EXACT same
    /// HallwayScene.makeExitSignNode(pointing:cellSize:) the per-cell
    /// scene-build loop itself now calls (widened from `private` to
    /// internal for this -- see that function's own doc comment), not
    /// a second implementation.
    func addExitSignAtCurrentCell() {
        guard canAddExitSignAtCurrentCell(), let store, let coord = currentPlayerCell(), let scene else { return }
        store.snapshotForUndo()
        store.placeExitSign(.north, at: coord)
        registerLiveExitSign(.north, coord)
        let node = HallwayScene.makeExitSignNode(pointing: .north, cellSize: store.cellSize)
        node.position = SCNVector3(Float(coord.col) * Float(store.cellSize), Float(store.wallHeight), Float(coord.row) * Float(store.cellSize))
        let target = DecoratorTarget(floor: floor, coord: coord, kind: .exitSign)
        target.tag(node)
        scene.rootNode.addChildNode(node)
        selection = target
        save(target)
    }

    /// Sept 23 (Decorator Ceiling expansion: Exit Sign): reads the
    /// authored direction straight off MazeStore.exitSigns -- same
    /// "no second source of truth" shape orientation(_:)/floorPosition(_:)
    /// elsewhere in this file already use.
    func exitSignDirection(_ target: DecoratorTarget) -> Direction {
        guard let coord = target.coord else { return .north }
        return store?.exitSignDirection(at: coord) ?? .north
    }

    /// Sept 23 (Decorator Ceiling expansion: Exit Sign): repoints an
    /// existing Exit Sign. Unlike Fluorescent's changeOrientation
    /// (a plain node rotation), an Exit Sign's `direction` determines
    /// BOTH the fixture's rotation AND which fixed arrow text each face
    /// prints (see HallwayScene.makeExitSignNode's own doc comment --
    /// "EXIT ->" vs "<- EXIT" depends on direction, not just axis), so
    /// there is no cheap in-place rotation that produces a correct
    /// result for all 4 directions. This rebuilds the fixture exactly
    /// the way add/move elsewhere in this file already rebuild-on-
    /// change: remove the old live node, author the new direction
    /// (MazeStore.placeExitSign re-points rather than duplicating, per
    /// its own doc comment), build a fresh node, tag/select it.
    func changeExitSignDirection(_ direction: Direction) {
        guard enabled, let target = selection, target.kind == .exitSign,
              exists(target), let store, let coord = target.coord, let scene,
              exitSignDirection(target) != direction else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        store.snapshotForUndo()
        store.placeExitSign(direction, at: coord)
        registerLiveExitSign(direction, coord)
        for node in liveNodes { node.removeFromParentNode() }
        let node = HallwayScene.makeExitSignNode(pointing: direction, cellSize: store.cellSize)
        node.position = SCNVector3(Float(coord.col) * Float(store.cellSize), Float(store.wallHeight), Float(coord.row) * Float(store.cellSize))
        let newTarget = DecoratorTarget(floor: floor, coord: coord, kind: .exitSign)
        newTarget.tag(node)
        scene.rootNode.addChildNode(node)
        selection = newTarget
        save(target)
    }

    /// Sept 23 (Decorator Ceiling expansion: Exit Sign): removal, same
    /// shape as deleteSelected()/deleteFloorObject() elsewhere in this
    /// file.
    func deleteExitSign() {
        guard enabled, let target = selection, target.kind == .exitSign,
              exists(target), let store, let coord = target.coord else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        store.snapshotForUndo()
        store.removeExitSign(at: coord)
        unregisterLiveExitSign(coord)
        for node in liveNodes { node.removeFromParentNode() }
        selection = nil
        save(target)
    }

    /// Sept 23 (Decorator Floor expansion: Fire): current brightness,
    /// reading the SAME MazeStore.lightBrightnessLevel(_:at:) every
    /// other authored light in this file reads (AuthoredLightKind.fire
    /// has its own 1...5 range, unrelated to ceiling/fluorescent's
    /// 0...10 -- see LightBrightness.swift).
    func fireBrightness(_ target: DecoratorTarget) -> Int {
        guard let coord = target.coord else { return 3 }
        return store?.lightBrightnessLevel(.fire, at: coord) ?? 3
    }

    /// Sept 23 (Decorator Floor expansion: Fire): live brightness
    /// change -- same proportional-scaling shape changeBrightness above
    /// uses for ceiling/fluorescent (scale each light's CURRENT
    /// intensity by the ratio between the new and previous nominal
    /// value, correct for Fire's single unmultiplied glow light and
    /// harmless for a light coming from off), but its OWN, entirely
    /// separate function -- deliberately not folded into the shared
    /// changeBrightness above, so that function (and the fluorescent
    /// recipe it protects) is never touched by this addition.
    /// MazeStore.placeFire re-authors brightness the same "call place
    /// again" way placeExitSign/placeSpotlight already do.
    func changeFireBrightness(by delta: Int) {
        guard enabled, let target = selection, target.kind == .fire,
              exists(target), let store, let coord = target.coord else { return }
        let range = AuthoredLightKind.fire.levelRange
        let previous = fireBrightness(target)
        let next = min(range.upperBound, max(range.lowerBound, previous + delta))
        guard next != previous else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        store.snapshotForUndo()
        store.placeFire(at: coord, brightness: next)
        let previousNominal = AuthoredLightKind.fire.intensity(level: previous)
        let newNominal = AuthoredLightKind.fire.intensity(level: next)
        for node in liveNodes {
            node.enumerateHierarchy { child, _ in
                guard let light = child.light else { return }
                light.intensity = previousNominal > 0 ? light.intensity * (newNominal / previousNominal) : newNominal
            }
        }
        save(target)
    }

    /// Sept 23 (Decorator Floor expansion: Fire): removal, same shape
    /// as deleteSelected()/deleteFloorObject()/deleteExitSign() above.
    func deleteFire() {
        guard enabled, let target = selection, target.kind == .fire,
              exists(target), let store, let coord = target.coord else { return }
        let liveNodes = nodes(for: target)
        guard !liveNodes.isEmpty else { return }
        store.snapshotForUndo()
        store.removeFire(at: coord)
        for node in liveNodes { node.removeFromParentNode() }
        // Sept 25: reverse the registerLiveFire above so the removed
        // fire also leaves TapNavigationController's fire bookkeeping.
        unregisterLiveFire(coord)
        selection = nil
        save(target)
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
        if store.pictureLights.contains(WallFace(coord: coord, direction: direction)) {
            store.removePictureLight(direction, at: coord)
        }
        store.removePicture(direction, at: coord)

        for node in liveNodes { node.removeFromParentNode() }
        for node in backfillNodes { node.removeFromParentNode() }

        var newWallMaterials: [SCNMaterial] = []
        let wall = DecoratorTarget(floor: floor, coord: coord, kind: .wallSurface, direction: direction)
        if nodes(for: wall).isEmpty {
            HallwayScene.buildWallPanel(coord: coord, direction: direction, width: panelWidth, length: panelLength, x: wx, z: wz, wallHeight: store.wallHeight, effectiveWallImageName: currentWallImageName(), floorNumber: floor, root: hallwayRoot, wallMaterials: &newWallMaterials)
            appendWallMaterials(newWallMaterials)
        }
        unregisterPicture(coord, direction)

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
    @State private var pictureSheetTarget: WallFace?
    /// Sept 26 (Decorate-mode elevator pictures): the elevator-poster
    /// counterpart to pictureSheetTarget above, for the same two
    /// picker sheets -- an ordinary wall Picture sets pictureSheetTarget,
    /// an elevator poster sets this one instead; each sheet's
    /// completion handler checks whichever is non-nil.
    @State private var elevatorPosterSheetTarget: DecoratorTarget.ElevatorPosterSurface?
    @State private var showSystemPhotoPicker = false
    @State private var showHallwaysArtPicker = false
    /// Sept 27 (Decorator Surfaces + Auto Lights config): the "+" menu's
    /// two new entries each open a small config sheet instead of acting
    /// immediately -- same @State-flag-backed .sheet(isPresented:) shape
    /// showSystemPhotoPicker/showHallwaysArtPicker above already use.
    @State private var showSurfacesSheet = false
    @State private var showAutoLightsSheet = false
    /// Sept 27 (door cosmetics pass): the selected Room Entrance's
    /// "Texture" control opens this visual thumbnail picker -- same
    /// @State-flag-backed .sheet(isPresented:) shape as the two above.
    @State private var showRoomEntranceDoorTextureSheet = false

    /// Sept 23 (Decorator Floor expansion): DecoratorTarget.Kind.
    /// floorObject now covers Trash Can/Envelope/Paint Bucket (see its
    /// own doc comment), so target.title alone can no longer name the
    /// specific object -- this looks the real ObjectKind up from
    /// MazeStore (the same single source of truth every other kind-
    /// specific accessor in this file reads from) for display only.
    private func floorObjectTitle(_ target: DecoratorTarget) -> String {
        guard let coord = target.coord, let kind = store.objects[coord] else { return target.title }
        switch kind {
        case .cash100: return "Money"
        case .trashCan: return "Trash Can"
        case .envelope: return "Envelope"
        case .paintBucket: return "Paint Bucket"
        default: return kind.rawValue.capitalized
        }
    }

    /// Sept 24 (Empty Wall chooser): one row of the "Empty Wall" chooser.
    /// Data-modeled (not hand-rolled per kind) so future choices are a
    /// list entry, and shaped with a `children` seam for the future
    /// grouped categories (Games > Checkers/Ping Pong, humor category,
    /// etc.) Eddie described -- but NO current item has children and NO
    /// UI renders a submenu today: the Empty Wall branch below stays a
    /// flat ForEach over these two direct choices, and the submenu
    /// behavior arrives only when a real multi-choice category lands.
    private struct WallChooserItem: Identifiable {
        let id = UUID()
        let title: String
        let isEnabled: Bool
        let action: () -> Void
        var children: [WallChooserItem]? = nil
    }

    private func emptyWallChoices(_ target: DecoratorTarget) -> [WallChooserItem] {
        [
            WallChooserItem(title: "Picture", isEnabled: state.canAddPicture(target)) { state.addPicture() },
            WallChooserItem(title: "Door", isEnabled: state.canAddDoor(target)) { state.addDoor() },
            // Sept 25 (Designer wall authoring): the three mission-fixture
            // choices -- each disabled when its own face-specific occupancy
            // check refuses this wall (would collide with any wall-mounted
            // object already here).
            WallChooserItem(title: "Mirror", isEnabled: state.canAddMirror(target)) { state.addMirror() },
            WallChooserItem(title: "Fire Extinguisher", isEnabled: state.canAddExtinguisher(target)) { state.addExtinguisher() },
            WallChooserItem(title: "Photo Booth", isEnabled: state.canAddPhotoBooth(target)) { state.addPhotoBooth() }
        ]
    }

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
            Spacer()
            if state.enabled, let target = state.selection, target.floor == store.currentMazeID {
                VStack(spacing: 10) {
                    HStack {
                        Text(target.kind == .floorObject ? floorObjectTitle(target) : target.title).font(.headline)
                        Spacer()
                        Button("Close") { state.selection = nil }
                    }
                    Text(target.locationLabel)
                        .font(.caption).foregroundStyle(.secondary)
                    if target.kind == .ceilingSurface {
                        HStack {
                            Button("Add Ceiling") { state.add(.ceiling) }
                                .disabled(!state.canAdd(target, kind: .ceiling))
                            Button("Add Fluorescent") { state.add(.fluorescent) }
                                .disabled(!state.canAdd(target, kind: .fluorescent))
                        }
                    } else if target.kind == .picture, let surface = target.elevatorPosterSurface {
                        // Sept 26 (Decorate-mode elevator pictures):
                        // the cab's 3 built-in posters ARE Pictures
                        // (kind == .picture) once tagged via
                        // HallwayScene's DecoratorTarget(...,
                        // location: .elevatorPoster(...), kind:
                        // .picture) -- this reuses the ordinary
                        // Picture inspector's Image section UI below
                        // almost verbatim (same 4 buttons, same
                        // picker sheets), but Image ONLY: a poster is
                        // permanent cab geometry (see exists(_:)'s
                        // isCab branch) with no wall-face-relative
                        // Size, no independent Picture Light of its
                        // own, and nothing to Delete -- so those three
                        // controls are deliberately left off, per
                        // Eddie's "only genuinely sensible picture
                        // operations" instruction. Store writes go
                        // through setElevatorBackArtwork/
                        // setElevatorSideArtwork (MazeStore.swift)
                        // rather than setPictureImageSelection/
                        // saveCurrentFloorAsOverride -- building-wide
                        // persistence, no floor to save (see save(_:)
                        // above's own "Cab mutations persist
                        // immediately" comment).
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Image").font(.caption).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Button("Hallways Collection — Select") {
                                    elevatorPosterSheetTarget = surface
                                    showHallwaysArtPicker = true
                                }
                                Button("Hallways Collection — Random") {
                                    guard let name = HallwayScene.pictureAssetNames.randomElement() else { return }
                                    switch surface {
                                    case .back: store.setElevatorBackArtwork(.builtIn(name))
                                    case .side: store.setElevatorSideArtwork(.builtIn(name))
                                    case .sideRight: store.setElevatorSideRightArtwork(.builtIn(name))
                                    }
                                }
                                Button("Camera Roll — Select") {
                                    elevatorPosterSheetTarget = surface
                                    showSystemPhotoPicker = true
                                }
                                Button("Camera Roll — Random") {
                                    PhotoRollProvider.shared.randomImageWithIdentifier(caller: "Decorator: Elevator Camera Roll — Random") { identifier, _ in
                                        guard let identifier else { return }
                                        switch surface {
                                        case .back: store.setElevatorBackArtwork(.cameraRoll(identifier))
                                        case .side: store.setElevatorSideArtwork(.cameraRoll(identifier))
                                        case .sideRight: store.setElevatorSideRightArtwork(.cameraRoll(identifier))
                                        }
                                    }
                                }
                                // Sept 26 ("Keep This Picture"): promotes
                                // whatever's currently showing on this
                                // poster into the same authored,
                                // building-wide persistence the 4
                                // buttons above already use -- see
                                // MazeStore.currentElevatorBackIdentity/
                                // currentElevatorSideIdentity's own doc
                                // comment. Only shown when there's no
                                // authored choice yet AND a known
                                // current identity to promote (already
                                // selected -> nothing to Keep; unknown
                                // identity -> nothing safe to persist).
                                let elevatorKeepIdentity: PictureImageSelection? = {
                                    switch surface {
                                    case .back:
                                        guard store.elevatorCabDecoration.backArtwork == nil else { return nil }
                                        return store.currentElevatorBackIdentity
                                    case .side:
                                        guard store.elevatorCabDecoration.sideArtwork == nil else { return nil }
                                        return store.currentElevatorSideIdentity
                                    case .sideRight:
                                        guard store.elevatorCabDecoration.sideRightArtwork == nil else { return nil }
                                        return store.currentElevatorSideRightIdentity
                                    }
                                }()
                                if let identity = elevatorKeepIdentity {
                                    Button("Keep This Picture") {
                                        switch surface {
                                        case .back: store.setElevatorBackArtwork(identity)
                                        case .side: store.setElevatorSideArtwork(identity)
                                        case .sideRight: store.setElevatorSideRightArtwork(identity)
                                        }
                                    }
                                }
                            }.font(.caption)
                        }
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
                            // Sept 28 (picture content moved to
                            // Decorator): the five direct image-source
                            // actions that used to sit here (Hallways
                            // Collection Select/Random, Camera Roll
                            // Select/Random, Keep This Picture) now live
                            // behind this one "Content..." button, which
                            // opens the EXISTING Play-mode Change Picture
                            // menu (PictureChangeMenuHost, PictureChange
                            // Menu.swift) via DecoratorState.
                            // presentPictureChangeMenu -- no second
                            // implementation of picture-changing logic;
                            // all five actions (including Keep This
                            // Picture) behave exactly as they did when
                            // this menu opened from a Play-mode tap.
                            Text("Content").font(.caption).foregroundStyle(.secondary)
                            Button("Content...") {
                                if let coord = target.coord, let direction = target.direction {
                                    state.presentPictureChangeMenu(WallFace(coord: coord, direction: direction))
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
                        // Sept 24 (Empty Wall chooser): the extensible
                        // wall-placement chooser replacing the single
                        // "Add Picture" button -- today exactly two
                        // DIRECT choices (Picture, Door), no extra
                        // "Wall Objects" level. Picture routes through
                        // the SAME existing addPicture flow it always
                        // has (zero regression); Door is the new
                        // decorative/architectural door placement (see
                        // DecoratorState.addDoor). Both entries
                        // independently disable via their own occupancy
                        // checks.
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(emptyWallChoices(target)) { item in
                                Button(item.title) { item.action() }
                                    .disabled(!item.isEnabled)
                                    .font(.body)
                            }
                        }
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
                        //
                        // Sept 23 (Decorator Floor expansion): gated to
                        // Trash Can specifically -- Envelope/Paint
                        // Bucket render dead-center with no LEFT/CENTER/
                        // RIGHT concept (HallwayScene.build(fromMaze:)'s
                        // own per-cell loop never reads
                        // floorObjectPlacements for them), so offering
                        // this picker for them would silently move the
                        // live node somewhere a rebuild would then
                        // snap back from.
                        VStack(alignment: .leading, spacing: 8) {
                            if let coord = target.coord, store.objects[coord] == .trashCan {
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
                            // Sept 23 (Decorator Floor expansion): Floor
                            // Objects had no removal path at all before
                            // this pass -- see deleteFloorObject's own
                            // doc comment.
                            Button("Delete Object", role: .destructive) { state.deleteFloorObject() }
                        }
                    } else if target.kind == .exitSign {
                        // Sept 23 (Decorator Ceiling expansion: Exit
                        // Sign): a Direction picker over all 4 cardinal
                        // values, same segmented-picker shape the
                        // Fluorescent Orientation control below already
                        // uses, writing through changeExitSignDirection
                        // (a full node rebuild under the hood -- see its
                        // own doc comment for why a plain rotation isn't
                        // enough here).
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Exit Direction").font(.caption).foregroundStyle(.secondary)
                            Picker("Direction", selection: Binding(
                                get: { state.exitSignDirection(target) },
                                set: { state.changeExitSignDirection($0) })) {
                                    ForEach([Direction.north, .east, .south, .west], id: \.self) { direction in
                                        Text(direction.rawValue.capitalized).tag(direction)
                                    }
                                }
                                .pickerStyle(.segmented)
                            Button("Delete Exit Sign", role: .destructive) { state.deleteExitSign() }
                        }
                    } else if target.kind == .fire {
                        // Sept 23 (Decorator Floor expansion: Fire): its
                        // own brightness control -- same +/- shape the
                        // ceiling/fluorescent Brightness row below uses,
                        // but reading fireBrightness/changeFireBrightness
                        // (its own independent functions, AuthoredLightKind.
                        // fire's 1...5 range) rather than target.lightKind/
                        // state.level/state.changeBrightness, which stay
                        // scoped to ceiling/fluorescent only.
                        HStack {
                            Text("Brightness")
                            Button { state.changeFireBrightness(by: -1) } label: { Image(systemName: "minus.circle.fill") }
                                .disabled(state.fireBrightness(target) == AuthoredLightKind.fire.levelRange.lowerBound)
                            Text("\(state.fireBrightness(target)) / \(AuthoredLightKind.fire.levelRange.upperBound)").monospacedDigit()
                            Button { state.changeFireBrightness(by: 1) } label: { Image(systemName: "plus.circle.fill") }
                                .disabled(state.fireBrightness(target) == AuthoredLightKind.fire.levelRange.upperBound)
                        }
                        Button("Delete Fire", role: .destructive) { state.deleteFire() }
                    } else if target.kind == .roomDoor {
                        // Sept 24 (Empty Wall chooser, decorative room
                        // doors): an existing decorative door's only
                        // authoring affordance is its removal -- same
                        // "restores the ordinary Empty Wall face"
                        // outcome as Delete Picture. Functional/mail
                        // doors are never tagged, so they can never
                        // reach this branch.
                        Button("Delete Room Door", role: .destructive) { state.deleteRoomDoor() }
                    } else if target.kind == .mirror {
                        // Sept 25 (Designer wall authoring): an existing
                        // Mirror's only authoring affordance is removal
                        // (deregisters the walk-stop and the live camera
                        // feed, reveals the still-intact wall panel).
                        // Tapping the mirror's own in-world node selects
                        // it here -- it also stops the walk by design.
                        Button("Delete Mirror", role: .destructive) { state.deleteMirror() }
                    } else if target.kind == .extinguisher {
                        // Sept 25 (Designer wall authoring): a placed
                        // Fire Extinguisher's only authoring affordance
                        // is removal (deregisters the pickup bookkeeping,
                        // including dropping it if carried).
                        Button("Delete Fire Extinguisher", role: .destructive) { state.deleteExtinguisher() }
                    } else if target.kind == .photoBooth {
                        // Sept 25 (Designer wall authoring): a placed
                        // Photo Booth's only authoring affordance is
                        // removal (deregisters the booth bookkeeping and
                        // cancels any in-flight session).
                        Button("Delete Photo Booth", role: .destructive) { state.deletePhotoBooth() }
                    } else if target.kind == .roomEntranceDoor {
                        // Sept 27 (Decorator Room Entrance authoring):
                        // same minimal shape as the .roomDoor branch
                        // above -- an existing Room Entrance's only
                        // Decorator authoring affordance is removal.
                        // Unlike a decorative Room Door, deleting it
                        // does not "reveal an Empty Wall" -- it simply
                        // leaves the two already-open cells as an
                        // ordinary connected boundary (see
                        // deleteRoomEntranceDoor's own doc comment).
                        Button("Texture") { showRoomEntranceDoorTextureSheet = true }
                        Menu {
                            ForEach(RoomEntranceDoorStyle.allCases, id: \.self) { style in
                                Button {
                                    state.setRoomEntranceDoorStyle(style)
                                } label: {
                                    if state.currentRoomEntranceDoorStyle() == style {
                                        Label(style.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(style.displayName)
                                    }
                                }
                            }
                        } label: {
                            Text("Style")
                        }
                        Button("Delete Room Entrance", role: .destructive) { state.deleteRoomEntranceDoor() }
                    } else {
                        // Sept 23 (ceiling light coexistence). Only
                        // ever shown when this coordinate genuinely
                        // has BOTH a spotlight and a fluorescent
                        // authored -- hasCoexistingCeilingLights is
                        // false for every floor authored before this
                        // feature existed, and always false for the
                        // elevator cab. Presentation-only: switching
                        // this selection never places, removes, or
                        // dims either light -- see setVisibleCeilingFixture's
                        // own doc comment.
                        if state.hasCoexistingCeilingLights(target) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Lights at this location").font(.caption).foregroundStyle(.secondary)
                                Picker("Visible Fixture", selection: Binding(
                                    get: { state.visibleCeilingFixture(target) },
                                    set: { state.setVisibleCeilingFixture($0, target: target) })) {
                                        Text(state.visibleCeilingFixture(target) == .fluorescent ? "✓ Fluorescent" : "Fluorescent")
                                            .tag(AuthoredLightKind.fluorescent)
                                        Text(state.visibleCeilingFixture(target) == .ceiling ? "✓ Spotlight" : "Spotlight")
                                            .tag(AuthoredLightKind.ceiling)
                                    }
                                    .pickerStyle(.segmented)
                            }
                        }
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
            // Sept 25 (HUD fix): the "complete Decorate control group" --
            // DECORATE/DECORATING · Done pill plus the orange + ADD menu,
            // which used to sit upper-middle where it rode over the
            // carried-objects strip and the 3D view. Moved to BOTTOM
            // CENTER, just above the FLOOR N pill (which is a separate
            // NavigationOverlay element, untouched -- see its own doc).
            HStack(spacing: 8) {
                Button(state.enabled ? "DECORATING · Done" : "DECORATE") { state.enabled.toggle() }
                    .font(.system(size: 12, weight: .bold))
                    .padding(10)
                    .background(state.enabled ? Color.orange : Color.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
                if state.enabled {
                    Menu {
                        // Sept 27 (Decorator Room Entrance authoring):
                        // Door Entry is architectural connectivity
                        // between two cells, not wall decoration, so it
                        // sits at this SAME top tier as Floor/Ceiling/
                        // Hanging/Wall/Surfaces/Auto Lights below --
                        // deliberately NOT nested inside Wall. No
                        // catalog/direction picker (unlike those four
                        // Menu entries): the player's current cell and
                        // current facing already determine the exact
                        // wall face, same one-tap-acts-immediately shape
                        // as Surfaces/Auto Lights just below, except
                        // scoped to the current cell like Floor/Ceiling/
                        // Hanging/Wall are.
                        Button("Door Entry") { state.addRoomEntranceDoorAtCurrentCell() }
                            .disabled(!state.canAddRoomEntranceDoorAtCurrentCell())
                        Menu("Floor") {
                            Toggle("Navigation Arrows", isOn: Binding(
                                get: { state.navigationArrowsEnabledAtCurrentCell },
                                set: { state.setNavigationArrowsEnabledAtCurrentCell($0) }))
                                .disabled(!state.canEditNavigationArrowsAtCurrentCell)
                            ForEach(DecoratorState.FloorObjectCatalogItem.allCases, id: \.self) { item in
                                Button(item.title) { state.addFloorObject(item) }
                                    .disabled(!state.canAddFloorObjectAtCurrentCell(item))
                            }
                        }
                        Menu("Ceiling") {
                            ForEach(DecoratorState.CeilingObjectCatalogItem.allCases, id: \.self) { item in
                                Button(item.title) { state.addCeilingObjectAtCurrentCell(item) }
                                    .disabled(!state.canAddCeilingObjectAtCurrentCell(item))
                            }
                        }
                        Menu("Hanging") {
                            ForEach(DecoratorState.HangingObjectCatalogItem.allCases, id: \.self) { item in
                                Button(item.title) { state.addHangingObjectAtCurrentCell(item) }
                                    .disabled(!state.canAddHangingObjectAtCurrentCell(item))
                            }
                        }
                        Menu("Wall") {
                            ForEach(DecoratorState.WallSide.allCases, id: \.self) { side in
                                Button(side.title) { state.selectWallAtCurrentCell(side) }
                                    .disabled(!state.canSelectWallAtCurrentCell(side))
                            }
                        }
                        // Sept 27 (Decorator Surfaces): opens a small
                        // Walls/Floor/Ceiling picker, then a visual
                        // texture browser -- see DecoratorSurfacesSheet/
                        // SurfaceTexturePicker (DecoratorConfigSheets.swift).
                        // Not scoped to the player's current cell, like
                        // Auto Lights below -- it's a whole-floor surface
                        // change, not a per-cell placement.
                        Button("Surfaces") { showSurfacesSheet = true }
                        // Sept 25 (Auto Lights), Sept 27 (config sheet):
                        // opens a small Spacing/Brightness sheet instead
                        // of acting immediately -- unlike Floor/Ceiling/
                        // Hanging/Wall above, it has no catalog item to
                        // pick and isn't scoped to the player's current
                        // cell; it resets and regenerates the WHOLE
                        // current floor's fluorescent layout in one tap.
                        // See autoLightsCurrentFloor()'s own doc comment.
                        Button("Auto Lights") { showAutoLightsSheet = true }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.orange, in: Circle())
                    }
                }
            }
            // Sept 26 (Eddie: orange Decorate controls covering the
            // large map's bottom row): this HStack used to rely on the
            // outer VStack's default .center alignment, landing it
            // dead-center at the bottom of the screen -- squarely under
            // the full map card, which is anchored bottom-RIGHT and
            // grows left (see HandheldMapGeometry.fullRect), so it
            // spans most of the screen's width. Left-aligning ONLY this
            // HStack (not the outer VStack, which the selection-editor
            // panel above still centers as before) moves it clear of
            // the map's left edge while keeping the exact same vertical
            // position (still just above the FLOOR N pill, per the
            // comment above), same Button/Menu content, same size,
            // same spacing between the two controls.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 12)
        .padding(.horizontal, 12)
        .sheet(isPresented: $showSystemPhotoPicker) {
            SystemPhotoPicker { identifier in
                if let identifier, let face = pictureSheetTarget {
                    store.setPictureImageSelection(.cameraRoll(identifier), direction: face.direction, at: face.coord)
                    store.saveCurrentFloorAsOverride()
                } else if let identifier, let surface = elevatorPosterSheetTarget {
                    switch surface {
                    case .back: store.setElevatorBackArtwork(.cameraRoll(identifier))
                    case .side: store.setElevatorSideArtwork(.cameraRoll(identifier))
                    case .sideRight: store.setElevatorSideRightArtwork(.cameraRoll(identifier))
                    }
                }
                pictureSheetTarget = nil
                elevatorPosterSheetTarget = nil
            }
        }
        .sheet(isPresented: $showHallwaysArtPicker) {
            HallwaysArtPicker { name in
                if let name, let face = pictureSheetTarget {
                    store.setPictureImageSelection(.builtIn(name), direction: face.direction, at: face.coord)
                    store.saveCurrentFloorAsOverride()
                } else if let name, let surface = elevatorPosterSheetTarget {
                    switch surface {
                    case .back: store.setElevatorBackArtwork(.builtIn(name))
                    case .side: store.setElevatorSideArtwork(.builtIn(name))
                    case .sideRight: store.setElevatorSideRightArtwork(.builtIn(name))
                    }
                }
                pictureSheetTarget = nil
                elevatorPosterSheetTarget = nil
            }
        }
        // Sept 27 (Decorator Surfaces + Auto Lights config): both new
        // sheets live in DecoratorConfigSheets.swift -- split out the
        // same way SystemPhotoPicker/HallwaysArtPicker were, to keep
        // this already very large file's own diff small.
        .sheet(isPresented: $showSurfacesSheet) {
            DecoratorSurfacesSheet(store: store, isPresented: $showSurfacesSheet)
        }
        .sheet(isPresented: $showAutoLightsSheet) {
            AutoLightsConfigSheet(state: state)
        }
        .sheet(isPresented: $showRoomEntranceDoorTextureSheet) {
            RoomEntranceDoorTexturePicker(state: state, isPresented: $showRoomEntranceDoorTextureSheet)
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

    /// Sept 23 (ceiling light coexistence). Hides (or shows) a ceiling
    /// fixture's visible GEOMETRY only -- every light-bearing node
    /// (the fixture's own SCNLight(s)) and the shared decoratorHitProxy
    /// (see makeDecoratorHitProxy above) are left completely untouched,
    /// so the fixture's light keeps contributing illumination and stays
    /// selectable via hit-test even while its physical body is
    /// invisible. This is the ONLY mechanism the coexistence feature
    /// uses to decide which fixture is seen -- it never enables,
    /// disables, or removes a light, and it never touches either
    /// fixture's own construction recipe (makeAuthoredCeilingFixture/
    /// FluorescentLight.makeFluorescentLight are both unchanged).
    /// Works for both fixture types unmodified: both build their
    /// visible parts as plain geometry-only child nodes, their
    /// SCNLight(s) on separate light-only nodes, and share this same
    /// named hit-proxy shape -- see each one's own construction.
    static func setCeilingFixtureGeometryHidden(_ fixture: SCNNode, hidden: Bool) {
        fixture.enumerateHierarchy { node, _ in
            guard node.geometry != nil, node.light == nil, node.name != "decoratorHitProxy" else { return }
            node.isHidden = hidden
        }
    }
}
