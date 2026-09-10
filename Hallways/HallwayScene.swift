//
//  HallwayScene.swift
//  Hallways
//
//  Prototype 2: one straight run, then a single 90-degree turn into a
//  second straight run. Floor/ceiling/walls are built as two adjoining,
//  non-overlapping rectangles (no gap, no z-fighting) — see the wall/rect
//  math below. Flat colors still, no textures/photos yet.
//

import SceneKit
import UIKit

enum HallwayScene {

    struct Config {
        var leg1Length: CGFloat = 34      // straight run before the turn
        var leg2Length: CGFloat = 34      // straight run after the turn
        var width: CGFloat = 3.2
        var height: CGFloat = 3.0
        var segmentLength: CGFloat = 4.0  // spacing of marker panels / lights
        var collisionMargin: CGFloat = 0.5 // keeps the player a bit clear of the visual walls
    }

    /// A straight leg's floor footprint in the XZ plane. Also used, at a
    /// smaller inset width, as the walkable collision bounds.
    struct FloorRect {
        var xRange: ClosedRange<CGFloat>
        var zRange: ClosedRange<CGFloat>
    }

    /// SceneKit declares its various floating-point distance properties
    /// (fog, light attenuation) inconsistently across SDK versions —
    /// CGFloat in some, Double in others. This bridges a Double through
    /// whichever concrete type Swift infers from the assignment target,
    /// so these lines compile correctly either way instead of guessing.
    private static func distance<T: BinaryFloatingPoint>(_ value: Double) -> T {
        T(value)
    }

    static func build(config: Config = Config(), theme: HallwayTheme = .brick) -> (scene: SCNScene, cameraNode: SCNNode, walkableRects: [FloorRect], wallMaterial: SCNMaterial, floorMaterial: SCNMaterial, ceilingMaterial: SCNMaterial) {
        let scene = SCNScene()
        scene.background.contents = UIColor(white: 0.04, alpha: 1)
        scene.fogColor = UIColor(white: 0.04, alpha: 1)
        let totalLength = config.leg1Length + config.leg2Length
        scene.fogStartDistance = distance(Double(totalLength) * 0.3)
        scene.fogEndDistance = distance(Double(totalLength) * 0.7)

        let root = SCNNode()
        scene.rootNode.addChildNode(root)

        let h = config.width / 2
        let L1 = config.leg1Length
        let L2 = config.leg2Length

        // Two straight legs sharing the turn square, laid out with no gap
        // and no overlap:
        //   leg 1 runs along -Z from the start, occupying x in [-h, h]
        //   leg 2 runs along +X after the turn, continuing on from there
        let rect1 = FloorRect(xRange: -h...h, zRange: -(L1 + h)...0)
        let rect2 = FloorRect(xRange: h...L2, zRange: -(L1 + h)...(-(L1 - h)))

        // Same shape, built again at a smaller half-width, purely for
        // collision — keeps the player clear of the walls without
        // narrowing the actual turn opening (both rects shrink from the
        // *same* hCol, so the shared doorway edge between them still lines
        // up and isn't accidentally blocked).
        let hCol = max(0.2, h - config.collisionMargin)
        let walkable1 = FloorRect(xRange: -hCol...hCol, zRange: -(L1 + hCol)...0)
        let walkable2 = FloorRect(xRange: hCol...L2, zRange: -(L1 + hCol)...(-(L1 - hCol)))

        let wallMaterial = makeWallMaterial(imageName: theme.wallImageName)
        let floorMaterial = makeFloorMaterial(imageName: theme.floorImageName)
        let ceilingMaterial = makeCeilingMaterial(imageName: theme.ceilingImageName)
        let markerMaterial = makeMarkerMaterial()

        // Floor + ceiling: one slab per leg, meeting with no overlap.
        for rect in [rect1, rect2] {
            let width = rect.xRange.upperBound - rect.xRange.lowerBound
            let length = rect.zRange.upperBound - rect.zRange.lowerBound
            let cx = (rect.xRange.lowerBound + rect.xRange.upperBound) / 2
            let cz = (rect.zRange.lowerBound + rect.zRange.upperBound) / 2

            let floorGeo = SCNBox(width: width, height: 0.1, length: length, chamferRadius: 0)
            floorGeo.materials = [floorMaterial]
            let floorNode = SCNNode(geometry: floorGeo)
            floorNode.position = SCNVector3(Float(cx), -0.05, Float(cz))
            root.addChildNode(floorNode)

            let ceilingGeo = SCNBox(width: width, height: 0.1, length: length, chamferRadius: 0)
            ceilingGeo.materials = [ceilingMaterial]
            let ceilingNode = SCNNode(geometry: ceilingGeo)
            ceilingNode.position = SCNVector3(Float(cx), Float(config.height) + 0.05, Float(cz))
            root.addChildNode(ceilingNode)
        }

        // Walls: the 4 boundary edges of the L, hand-derived from rect1/rect2
        // above (each rect's edge is either a real wall, if nothing borders
        // it, or the open doorway between the two rects, if the other rect
        // covers that same edge):
        //   A: outer wall of leg 1        — x = -h,        z in [-(L1+h), 0]
        //   B: outer wall of the turn+leg2— z = -(L1+h),   x in [-h, L2]
        //   C: inner corner wall (short)  — z = -(L1-h),   x in [h, L2]
        //   D: inner wall of leg 1 (short)— x = h,         z in [-(L1-h), 0]
        struct WallSpec { var cx: CGFloat; var cz: CGFloat; var length: CGFloat; var alongX: Bool }
        let wallSpecs: [WallSpec] = [
            WallSpec(cx: -h, cz: -(L1 + h) / 2, length: L1 + h, alongX: false),
            WallSpec(cx: (L2 - h) / 2, cz: -(L1 + h), length: L2 + h, alongX: true),
            WallSpec(cx: (L2 + h) / 2, cz: -(L1 - h), length: L2 - h, alongX: true),
            WallSpec(cx: h, cz: -(L1 - h) / 2, length: L1 - h, alongX: false),
        ]

        for spec in wallSpecs where spec.length > 0.01 {
            let geo: SCNGeometry
            if spec.alongX {
                geo = SCNBox(width: spec.length, height: config.height, length: 0.1, chamferRadius: 0)
            } else {
                geo = SCNBox(width: 0.1, height: config.height, length: spec.length, chamferRadius: 0)
            }
            geo.materials = [wallMaterial]
            let node = SCNNode(geometry: geo)
            node.position = SCNVector3(Float(spec.cx), Float(config.height / 2), Float(spec.cz))
            root.addChildNode(node)
        }

        // Marker panels + lights along the two long outer walls (A and B) —
        // the ones you actually travel alongside. Skipped on the two short
        // inner-corner walls to keep this simple.
        let panelGeo = SCNBox(width: 0.06, height: config.height * 0.55, length: 0.4, chamferRadius: 0)
        panelGeo.materials = [markerMaterial]

        func addMarkersAndLights(runsAlongX: Bool, from: CGFloat, to: CGFloat, fixed: CGFloat) {
            let total = abs(to - from)
            let count = max(1, Int(total / config.segmentLength))
            let increasing = from < to
            for i in 0..<count {
                let t = increasing
                    ? from + CGFloat(i) * config.segmentLength + config.segmentLength / 2
                    : from - CGFloat(i) * config.segmentLength - config.segmentLength / 2
                guard let pg = panelGeo.copy() as? SCNGeometry else { continue }
                let panel = SCNNode(geometry: pg)
                let px = runsAlongX ? t : fixed
                let pz = runsAlongX ? fixed : t
                panel.position = SCNVector3(Float(px), Float(config.height / 2), Float(pz))
                root.addChildNode(panel)

                if i % 2 == 0 {
                    let light = SCNLight()
                    light.type = .omni
                    light.intensity = 350
                    light.color = UIColor.white
                    light.attenuationEndDistance = distance(Double(config.segmentLength) * 3)
                    let lightNode = SCNNode()
                    lightNode.light = light
                    lightNode.position = SCNVector3(Float(px), Float(config.height) - 0.25, Float(pz))
                    root.addChildNode(lightNode)
                }
            }
        }

        addMarkersAndLights(runsAlongX: false, from: 0, to: -(L1 + h), fixed: -h)       // wall A
        addMarkersAndLights(runsAlongX: true, from: -h, to: L2, fixed: -(L1 + h))       // wall B

        // Ambient fill so unlit stretches aren't pure black
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 180
        ambient.color = UIColor(white: 0.6, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        // Camera — same spawn as Prototype 1, just inside the mouth of leg 1
        let camera = SCNCamera()
        camera.fieldOfView = 75
        camera.zNear = 0.05
        camera.zFar = Double(L1 + L2) + 40
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 1.6, -1.0)
        root.addChildNode(cameraNode)

        return (scene, cameraNode, [walkable1, walkable2], wallMaterial, floorMaterial, ceilingMaterial)
    }

    /// Builds the 3D scene directly from a MazeStore's grid: one room per
    /// open cell, using the SAME brick/dark materials as the original
    /// hand-built prototype (per-cell random color was tried and
    /// dropped — made the hallway look dark and blocky instead of like a
    /// hallway). No wall on any side that opens onto another open cell,
    /// so you walk straight through — a red header bar and a dark
    /// threshold line on the floor/ceiling still mark that boundary, so
    /// the cell-by-cell structure stays visible even though every room
    /// now looks the same. Same rect-union collision approach as
    /// Prototype 2, just generalized: each cell contributes its own
    /// FloorRect, inset only on the sides that actually have a wall, so
    /// open sides meet the neighbor's rect edge-to-edge with no gap and
    /// no overlap.
    static func build(fromMaze cells: Set<GridCoordinate>, cellSize: CGFloat, wallHeight: CGFloat, objects: [GridCoordinate: ObjectKind] = [:], destinations: [GridCoordinate: ObjectKind] = [:], exitSigns: [GridCoordinate: Direction] = [:], floorMaps: [GridCoordinate: Direction] = [:], spotlights: Set<GridCoordinate> = [], missionSigns: [GridCoordinate: Direction] = [:], pictures: [GridCoordinate: Direction] = [:], picturesUseCameraRoll: Bool = false, roomDoors: [GridCoordinate: RoomDoorPlacement] = [:], itemRooms: [GridCoordinate: Int] = [:], missionHeading: String = "", missionBody: String = "", missionObjectKind: ObjectKind? = nil, floorNumber: Int = 1, totalFloors: Int = 1, playerStart: GridCoordinate? = nil, playerEnd: GridCoordinate? = nil, theme: HallwayTheme = .brick) -> (scene: SCNScene, cameraNode: SCNNode, walkableRects: [FloorRect], wallMaterials: [SCNMaterial], floorMaterial: SCNMaterial, ceilingMaterial: SCNMaterial, objectNodes: [GridCoordinate: SCNNode], destinationNodes: [GridCoordinate: SCNNode], elevatorDoors: (left: SCNNode, right: SCNNode, direction: Direction, buttonNodes: [Int: SCNNode], shaft: SCNNode)?, exitSignNodes: [GridCoordinate: SCNNode], floorMapPlaneNodes: [SCNNode]) {
        let scene = SCNScene()
        scene.background.contents = UIColor(white: 0.04, alpha: 1)
        scene.fogColor = UIColor(white: 0.04, alpha: 1)
        let maxRow = cells.map { $0.row }.max() ?? 0
        let maxCol = cells.map { $0.col }.max() ?? 0
        let span = CGFloat(max(maxRow, maxCol) + 1) * cellSize
        scene.fogStartDistance = distance(Double(span) * 0.6)
        scene.fogEndDistance = distance(Double(span) * 1.1)

        let root = SCNNode()
        scene.rootNode.addChildNode(root)

        let half = cellSize / 2
        let margin: CGFloat = 0.4 // keeps the player clear of an actual wall, same idea as Prototype 2's collisionMargin

        func worldX(_ col: Int) -> CGFloat { CGFloat(col) * cellSize }
        func worldZ(_ row: Int) -> CGFloat { CGFloat(row) * cellSize }
        func isOpen(_ row: Int, _ col: Int) -> Bool { cells.contains(GridCoordinate(row: row, col: col)) }

        var walkableRects: [FloorRect] = []
        var objectNodes: [GridCoordinate: SCNNode] = [:]
        // Every Exit Sign built below, keyed by the intersection cell
        // it's mounted at -- TapNavigationController uses this to know
        // exactly which node to light up neon-bright once the player
        // actually reaches that cell (see makeExitSignNode's own doc
        // comment for why the DEFAULT look is dim/small instead).
        var exitSignNodes: [GridCoordinate: SCNNode] = [:]
        // The DOOR node specifically for each destination (not the icon
        // behind it) -- this is what TapNavigationController animates
        // sliding up on a successful deposit.
        var destinationNodes: [GridCoordinate: SCNNode] = [:]
        // Every "You Are Here" map's own picture plane (there can be
        // several placed around one floor, all showing the identical
        // layout) -- a flat array, not coordinate-keyed, since
        // TapNavigationController only ever needs "was one of these
        // tapped" and "push a refreshed texture to all of them," never
        // "which specific one." See addFloorMapNode's own doc comment
        // for why this is the PLANE, not its frame.
        var floorMapPlaneNodes: [SCNNode] = []
        // The elevator's 2 door panels + which wall they're mounted on,
        // or nil for a maze so small its start and end cells are the
        // same (nothing to reach). TapNavigationController needs the
        // mount direction too, to know which world axis the doors
        // slide along when it animates them open.
        var elevatorDoors: (left: SCNNode, right: SCNNode, direction: Direction, buttonNodes: [Int: SCNNode], shaft: SCNNode)? = nil

        // Spawn AND the elevator, both the same building-fixed cell now
        // -- MazeStore.elevatorCoordinate, not anything derived from
        // this floor's own shape. Eddie, Sept 5: "one elevator, one
        // coord, that is the starting point and ending point for all
        // floors." `start`/`end` stay 2 separate lets (rather than
        // deleting one) purely so the per-cell loop below can keep
        // saying whichever name reads clearer at each call site --
        // they're never expected to differ. Falls back to (0,0) only
        // for the literal empty-maze case, same as before.
        let start = playerStart ?? (cells.isEmpty ? GridCoordinate(row: 0, col: 0) : MazeStore.elevatorCoordinate)
        let end = playerEnd ?? (cells.isEmpty ? GridCoordinate(row: 0, col: 0) : MazeStore.elevatorCoordinate)

        // Floor/ceiling stay one material shared by every cell (a
        // repeating tiled pattern reads fine repeated; no per-cell
        // photo variety requested there yet). Walls are different: each
        // one gets its OWN fresh material instance (built fresh inside
        // the loop below, not shared) so a live theme swap can put a
        // DIFFERENT photo on each wall segment under My Photos instead
        // of the same single image repeated on every one. For the
        // bundled tiled themes (brick, cave, etc.) every wall material
        // still gets the exact same image, so visually nothing changes
        // for those — only My Photos actually varies wall to wall.
        let floorMaterial = makeFloorMaterial(imageName: theme.floorImageName)
        let ceilingMaterial = makeCeilingMaterial(imageName: theme.ceilingImageName)
        var wallMaterials: [SCNMaterial] = []

        // Warm brass/amber, lit like metal trim rather than flat-red
        // tape — same color family as the end-of-maze glowing marker, so
        // "amber glow" reads consistently as "something to notice" instead
        // of a hazard-stripe red that looked out of place on real brick.
        let doorwayMaterial = SCNMaterial()
        doorwayMaterial.diffuse.contents = UIColor(red: 0.72, green: 0.52, blue: 0.18, alpha: 1)
        doorwayMaterial.emission.contents = UIColor(red: 0.5, green: 0.32, blue: 0.06, alpha: 1)
        doorwayMaterial.lightingModel = .physicallyBased
        doorwayMaterial.roughness.contents = 0.35
        doorwayMaterial.metalness.contents = 0.65

        // Builds one intersection marker centered at (x, z): a flat
        // amber "+" (or "T"/"Y" at a 3-way) lying on the floor, one arm
        // per open side, each arm ending in a flat triangular
        // arrowhead pointing out into that doorway -- Eddie's "2 cris
        // cross lines that form arrows pointing in 4 directions,"
        // replacing the old per-doorway header bars.
        func addIntersectionMarker(atX x: CGFloat, z: CGFloat, openNorth: Bool, openSouth: Bool, openEast: Bool, openWest: Bool) {
            let armLength = cellSize * 0.42
            let armThickness: CGFloat = 0.08
            let markerY: CGFloat = 0.015 // just proud of the floor, like the old threshold lines were
            let arrowBaseWidth: CGFloat = 0.26
            let arrowLength: CGFloat = 0.24

            func addArm(_ direction: Direction, dx: CGFloat, dz: CGFloat) {
                let shaft = dx == 0
                    ? SCNBox(width: armThickness, height: 0.02, length: armLength, chamferRadius: 0)
                    : SCNBox(width: armLength, height: 0.02, length: armThickness, chamferRadius: 0)
                shaft.materials = [doorwayMaterial]
                let shaftNode = SCNNode(geometry: shaft)
                shaftNode.position = SCNVector3(Float(x + dx * armLength / 2), Float(markerY), Float(z + dz * armLength / 2))
                root.addChildNode(shaftNode)

                let arrowGeometry = makeArrowheadGeometry(direction: direction, baseWidth: arrowBaseWidth, length: arrowLength, material: doorwayMaterial)
                let arrowNode = SCNNode(geometry: arrowGeometry)
                arrowNode.position = SCNVector3(Float(x + dx * armLength), Float(markerY), Float(z + dz * armLength))
                root.addChildNode(arrowNode)
            }

            if openNorth { addArm(.north, dx: 0, dz: -1) }
            if openSouth { addArm(.south, dx: 0, dz: 1) }
            if openEast { addArm(.east, dx: 1, dz: 0) }
            if openWest { addArm(.west, dx: -1, dz: 0) }
        }

        // The deposit half of the pick-up/deliver mechanic (Eddie,
        // Sept 5): a small metallic shutter mounted on one solid wall
        // of a destination cell, hiding a matching critter icon behind
        // it. You can't tell what it wants until you actually arrive
        // there -- see addDestinationDoor below for exactly what
        // "arrival" reveals and TapNavigationController for the
        // slide-up animation itself, which only ever plays on a real
        // match ("if you dont have a matching image, that door never
        // budges"). Eddie's first on-device look (Sept 5) landed low
        // enough on screen to sit under the D-pad, and read as a flat
        // icon rather than the "dark 3d looking inside of a cube" he
        // wanted -- raised the mount height and added a real recessed,
        // dark-walled cubby behind the shutter in response.
        let destinationDoorMaterial = makeDestinationDoorMaterial()
        let destinationCubbyInteriorMaterial = makeCubbyInteriorMaterial(imageName: theme.wallImageName)
        let destinationDoorWidth: CGFloat = 0.9
        let destinationDoorHeight: CGFloat = 0.6
        let destinationDoorThickness: CGFloat = 0.04
        let destinationCenterY: CGFloat = 1.35 // was 1.0 -- too close to the D-pad on screen, Sept 5
        let destinationIconGap: CGFloat = 0.01 // shutter/cubby mouth sits almost flush with the wall
        let destinationDoorGap: CGFloat = 0.07 // door sits further proud, fully covering the cubby mouth when shut
        let destinationCubbyDepth: CGFloat = 1.1 // was 0.5 -- needed real depth to read as "looking down a short hallway," not a shallow box (Eddie, Sept 5: "like an oven")
        let destinationPanelThickness: CGFloat = 0.03

        // direction says which way is "into the room" so the cubby and
        // its shutter end up facing the hallway and sitting flush
        // against the correct wall face. The cubby (icon + dark
        // interior panels, now a full short passage rather than a
        // shallow box -- Eddie, Sept 5: "like an oven") is built once
        // in LOCAL space where +Z always means "into the room"
        // (matching the .north case's untouched orientation below),
        // then carried into place as one unit by the same per-direction
        // position/rotation math used throughout this file.
        // The flat, normally-lit slice of ordinary wall that
        // surrounds a small wall fixture's own opening -- Eddie, Sept
        // 5: "the background texture is being used to render the
        // inside of the chute container. it should be the wall,
        // itself, not the inside of the container." Root cause: the
        // wall-skip conditionals further down (hasWallNorth && ... &&
        // destinationMountDirection != .north, etc.) omit the ordinary
        // addWall panel for this cell's ENTIRE wall face, not just the
        // doorway rectangle -- barely noticeable for the elevator,
        // whose 2 sliding doors cover most of a 3.2 x 3.0 wall, but
        // the destination shutter is only 0.9 x 0.6, so nearly the
        // whole "wall" there was really just empty space with the fog/
        // background showing through it, and only the recessed
        // cubby's own dark, photo-textured interior panels (sized to
        // match the doorway) filled the opening -- which reads exactly
        // like "the wall texture is on the inside of the container"
        // instead of on the wall. Four ordinary wall-textured strips
        // (same material/tiling as addWall, just sized to frame the
        // opening instead of a full cell) fill in everything AROUND
        // the door, so the cubby becomes a small hole in a
        // normal-looking wall again, not the entire wall itself.
        func addDoorFrame(direction: Direction, wallCenterX: CGFloat, wallCenterZ: CGFloat, doorWidth: CGFloat, doorHeight: CGFloat, doorCenterY: CGFloat) {
            let thick: CGFloat = 0.1
            let doorTop = doorCenterY + doorHeight / 2
            let doorBottom = doorCenterY - doorHeight / 2
            let sideStripWidth = (cellSize - doorWidth) / 2

            // Eddie, Sept 5, comparing a wall with a floor map (built
            // almost entirely out of these 4 strips) against an
            // ordinary wall: "more bricks per sq in... the wall with
            // the map should be the same scaling as the normal blank
            // wall." Root cause: makeWallMaterial's 2x repeat is tuned
            // for a normal wall panel's fixed cellSize x wallHeight
            // face -- fine there since every ordinary wall is exactly
            // that size, but SceneKit maps EVERY box face to the same
            // 0...1 UV range regardless of its actual physical size,
            // so reusing one material (and its one fixed 2x transform)
            // across these 4 strips -- each a different, much smaller
            // size than a full wall -- crammed that same 2 repeats
            // into a much smaller area, i.e. smaller-looking, denser
            // bricks. A material of its own per strip, with the repeat
            // count scaled down by that strip's own size relative to
            // the normal cellSize x wallHeight reference, keeps brick
            // size constant in world units everywhere, strips
            // included.
            func stripMaterial(width: CGFloat, height: CGFloat) -> SCNMaterial {
                let material = makeWallMaterial(imageName: theme.wallImageName)
                let sScale = Float(2 * width / cellSize)
                let tScale = Float(2 * height / wallHeight)
                material.diffuse.contentsTransform = SCNMatrix4MakeScale(sScale, tScale, 1)
                // ContentView's Coordinator.applySurface(_:imageName:fallbackColor:)
                // re-applies a flat 2x2 repeat to every material in
                // wallMaterials on every theme cycle -- correct for a
                // normal full wall (that IS its right scale) but it
                // would silently undo THIS strip's own smaller,
                // size-correct scale the moment Eddie taps the palette
                // button. Stashing the intended scale in the
                // material's own name (nothing else on SCNMaterial
                // holds arbitrary per-instance data) lets applySurface
                // recover and reapply the right one instead of the
                // generic one -- see that function's own comment.
                material.name = "wallRepeat:\(sScale)x\(tScale)"
                wallMaterials.append(material)
                return material
            }

            func strip(alongLength: CGFloat, verticalHeight: CGFloat, alongOffset: CGFloat, verticalCenter: CGFloat) {
                guard verticalHeight > 0, alongLength > 0 else { return }
                let geo: SCNBox
                let x: CGFloat
                let z: CGFloat
                switch direction {
                case .north, .south:
                    geo = SCNBox(width: alongLength, height: verticalHeight, length: thick, chamferRadius: 0)
                    x = wallCenterX + alongOffset
                    z = wallCenterZ
                case .east, .west:
                    geo = SCNBox(width: thick, height: verticalHeight, length: alongLength, chamferRadius: 0)
                    x = wallCenterX
                    z = wallCenterZ + alongOffset
                }
                geo.materials = [stripMaterial(width: alongLength, height: verticalHeight)]
                let node = SCNNode(geometry: geo)
                node.position = SCNVector3(Float(x), Float(verticalCenter), Float(z))
                root.addChildNode(node)
            }

            // Top strip -- full cell width, floor-to-ceiling gap above the door.
            strip(alongLength: cellSize, verticalHeight: wallHeight - doorTop, alongOffset: 0, verticalCenter: doorTop + (wallHeight - doorTop) / 2)
            // Bottom strip -- full cell width, floor up to the door's sill.
            strip(alongLength: cellSize, verticalHeight: doorBottom, alongOffset: 0, verticalCenter: doorBottom / 2)
            // Side strips -- only alongside the door's own height band.
            strip(alongLength: sideStripWidth, verticalHeight: doorHeight, alongOffset: -(doorWidth / 2 + sideStripWidth / 2), verticalCenter: doorCenterY)
            strip(alongLength: sideStripWidth, verticalHeight: doorHeight, alongOffset: doorWidth / 2 + sideStripWidth / 2, verticalCenter: doorCenterY)
        }

        func addDestinationDoor(direction: Direction, wallCenterX: CGFloat, wallCenterZ: CGFloat, kind: ObjectKind) -> SCNNode {
            let halfW = Float(destinationDoorWidth / 2)
            let halfH = Float(destinationDoorHeight / 2)
            let depth = Float(destinationCubbyDepth)
            let thick = Float(destinationPanelThickness)

            func panel(width: CGFloat, height: CGFloat, length: CGFloat) -> SCNNode {
                let geo = SCNBox(width: width, height: height, length: length, chamferRadius: 0)
                // Each face tiles at the hallway's brick size, even on a
                // six-unit shaft. One stretched texture cannot fit all faces.
                func faceMaterial(horizontal: CGFloat, vertical: CGFloat) -> SCNMaterial {
                    let material = destinationCubbyInteriorMaterial.copy() as! SCNMaterial
                    material.diffuse.wrapS = .repeat
                    material.diffuse.wrapT = .repeat
                    material.diffuse.contentsTransform = SCNMatrix4MakeScale(
                        Float(2 * horizontal / cellSize), Float(2 * vertical / wallHeight), 1)
                    return material
                }
                // SCNBox: front, right, back, left, top, bottom.
                geo.materials = [
                    faceMaterial(horizontal: width, vertical: height),
                    faceMaterial(horizontal: length, vertical: height),
                    faceMaterial(horizontal: width, vertical: height),
                    faceMaterial(horizontal: length, vertical: height),
                    faceMaterial(horizontal: width, vertical: length),
                    faceMaterial(horizontal: width, vertical: length)
                ]
                return SCNNode(geometry: geo)
            }

            let cubby = SCNNode()
            cubby.position = SCNVector3(Float(wallCenterX), Float(destinationCenterY), Float(wallCenterZ))

            cubby.name = "chuteInterior"
            // The opening leads into a vertical shaft, with no horizontal floor.
            let shaftHeight: CGFloat = 6
            let shaftCenter = halfH - Float(shaftHeight / 2)
            let back = panel(width: CGFloat(halfW * 2), height: shaftHeight, length: CGFloat(thick))
            back.position = SCNVector3(0, shaftCenter, -depth)
            let top = panel(width: CGFloat(halfW * 2), height: CGFloat(thick), length: CGFloat(depth))
            top.position = SCNVector3(0, halfH, -depth / 2)
            let left = panel(width: CGFloat(thick), height: shaftHeight, length: CGFloat(depth))
            left.position = SCNVector3(-halfW, shaftCenter, -depth / 2)
            let right = panel(width: CGFloat(thick), height: shaftHeight, length: CGFloat(depth))
            right.position = SCNVector3(halfW, shaftCenter, -depth / 2)
            // The front wall continues below the mouth, enclosing the downshaft.
            let front = panel(width: CGFloat(halfW * 2), height: shaftHeight - CGFloat(halfH * 2), length: CGFloat(thick))
            // Recess behind the ordinary wall below the opening, not over its face.
            front.position = SCNVector3(0, -Float(shaftHeight / 2), -0.12)
            [back, top, left, right, front].forEach { cubby.addChildNode($0) }


            // Rather than a point light (which bled its glow onto the
            // shutter itself, then -- once isolated with categoryBitMask
            // -- made the icon invisible instead, most likely because
            // the actual mesh lives on a child node under the wrapper
            // makeObjectNode returns, not the wrapper itself), the icon
            // just glows on its own: emission set to match its own
            // diffuse color makes it visible against the dark cube
            // regardless of any light in the scene, with zero risk of
            // spilling onto anything else. Eddie, Sept 5: "the steel
            // door slides open perfectly but theres just a frame behind it."
            let icon = makeObjectNode(kind, size: destinationDoorHeight * 0.55)
            icon.position = SCNVector3(0, 0, -depth * 0.55) // sits back inside the cube, not flush with the wall
            icon.enumerateHierarchy { node, _ in
                node.geometry?.materials.forEach { material in
                    material.emission.contents = material.diffuse.contents
                }
            }
            icon.name = "deliveryTemplate"
            icon.isHidden = true // Empty-handed openings must show an empty shaft.
            icon.enumerateHierarchy { node, _ in node.removeAllActions() }
            cubby.addChildNode(icon)

            let doorGeo = SCNBox(width: destinationDoorWidth, height: destinationDoorHeight, length: destinationDoorThickness, chamferRadius: 0.01)
            doorGeo.materials = [destinationDoorMaterial]
            let door = SCNNode(geometry: doorGeo)
            door.position = SCNVector3(Float(wallCenterX), Float(destinationCenterY), Float(wallCenterZ))

            switch direction {
            case .north:
                cubby.position.z += Float(0.05 + destinationIconGap)
                door.position.z += Float(0.05 + destinationDoorGap)
            case .south:
                cubby.position.z -= Float(0.05 + destinationIconGap)
                door.position.z -= Float(0.05 + destinationDoorGap)
                cubby.eulerAngles.y = .pi
                door.eulerAngles.y = .pi
            case .east:
                cubby.position.x -= Float(0.05 + destinationIconGap)
                door.position.x -= Float(0.05 + destinationDoorGap)
                cubby.eulerAngles.y = -.pi / 2
                door.eulerAngles.y = -.pi / 2
            case .west:
                cubby.position.x += Float(0.05 + destinationIconGap)
                door.position.x += Float(0.05 + destinationDoorGap)
                cubby.eulerAngles.y = .pi / 2
                door.eulerAngles.y = .pi / 2
            }

            addDoorFrame(direction: direction, wallCenterX: wallCenterX, wallCenterZ: wallCenterZ, doorWidth: destinationDoorWidth, doorHeight: destinationDoorHeight, doorCenterY: destinationCenterY)

            // "we need to put a sign on the chutes that says trash in
            // small letters" (Eddie, Sept 5) -- a child of `door` so it
            // rides along with the door's own per-direction position/
            // rotation for free, offset toward -z same as the icon
            // inside the cubby (see icon.position above) since that's
            // this codebase's established "faces the player" local
            // direction regardless of which of the 4 ways the door
            // itself got rotated to mount.
            let label = makeDestinationLabelNode(kind: kind, doorHeight: destinationDoorHeight, doorThickness: destinationDoorThickness)
            door.addChildNode(label)

            let assembly = SCNNode()
            assembly.addChildNode(cubby)
            assembly.addChildNode(door)
            root.addChildNode(assembly)
            return door
        }

        // The elevator -- Sept 5, the 2nd Hallway Activity/wall
        // fixture (see hallways.md for the full "Hallway Activities"
        // conversation), and the actual mechanism behind changing
        // floors: this used to be an instantly-triggering floating
        // glow-ball with no visual door at all (see the old end-marker
        // block this replaced, further down -- MazeStore.
        // advanceToNextMaze, the actual floor-switch logic, is
        // unchanged). Wall-mounted using the exact same "compute the
        // mount wall before any ordinary wall panel gets built there"
        // fix as the destination cubby above, but with 2 vertical
        // panels that slide apart -- a real elevator -- instead of 1
        // panel sliding up, and a distinct warm brass tone instead of
        // the destination shutter's bright chrome so the two wall
        // fixtures never read as the same thing. Eddie, Sept 5:
        // "obviously it will be on a wall... make it look different
        // (maybe diff color metal)... and of course the 2 vertical
        // sliding doors that open and close."
        let elevatorDoorMaterial = makeElevatorDoorMaterial()
        let elevatorShaftInteriorMaterial = makeElevatorShaftMaterial()
        let elevatorDoorWidth: CGFloat = 1.6 // full opening, both panels combined -- door-scaled, not shutter-scaled
        // Eddie, Sept 8, once the brick frame around the doorway
        // was filled in (see addDoorFrame call below): "the
        // elevator is even lower... instead of black the back wall
        // is brick." The void-vs-brick bug is fixed, but that also
        // made the real proportions plain to see -- 2.2 out of a
        // 3.0 wallHeight left a 0.8 header, ~27% of the wall,
        // noticeably more overhead brick than a real elevator door
        // (which runs nearly to the ceiling). 2.6 leaves a 0.4
        // header instead, ~13%, reading as a proper door frame
        // rather than a low, small door in a tall wall.
        let elevatorDoorHeight: CGFloat = 2.6 // bottom-aligned to the floor, real-door height
        let elevatorDoorThickness: CGFloat = 0.05
        let elevatorCenterY: CGFloat = elevatorDoorHeight / 2
        // Eddie, Sept 8: "its still zooming in just as much to
        // that back wall - and all walls as its turning to the
        // doors." Shrinking the photo (below) didn't touch this --
        // proof the "zoom" feel is the camera's actual resting
        // distance from every wall, not the size of what's drawn on
        // them. The shaft was only 0.4 deep, so even dead-center the
        // camera sat a mere 0.2 from the back wall/photo AND 0.2 from
        // the doors after the pivot -- point-blank either way. Now
        // as deep as the doorway is wide (a roughly square car, same
        // 1.6 as elevatorDoorWidth), so dead-center becomes 0.8 from
        // every wall -- 4x the breathing room, no more nose-to-the-
        // glass feeling on the photo or on the doors at pivot's end.
        let elevatorShaftDepth: CGFloat = 1.6
        let elevatorPanelThickness: CGFloat = 0.03
        let elevatorShaftGap: CGFloat = 0.01
        let elevatorDoorGap: CGFloat = 0.06
        // How far each of the 2 panels sits from the opening's own
        // center when closed (their inner edges just meet) -- also
        // exactly how far each one slides further out to fully clear
        // the opening when open. TapNavigationController's own
        // open/close animation is hand-kept in sync with this same
        // 0.8 distance (see its openElevator(), same convention
        // already used for the destination door's slide-up amount).
        let elevatorPanelWidth = elevatorDoorWidth / 2
        let elevatorSplitOffset = elevatorPanelWidth / 2

        func addElevatorDoor(direction: Direction, wallCenterX: CGFloat, wallCenterZ: CGFloat, floorNumber: Int, totalFloors: Int) -> (left: SCNNode, right: SCNNode, direction: Direction, buttonNodes: [Int: SCNNode], shaft: SCNNode) {
            let halfW = Float(elevatorDoorWidth / 2)
            let halfH = Float(elevatorDoorHeight / 2)
            let depth = Float(elevatorShaftDepth)
            let thick = Float(elevatorPanelThickness)

            func panel(width: CGFloat, height: CGFloat, length: CGFloat) -> SCNNode {
                let geo = SCNBox(width: width, height: height, length: length, chamferRadius: 0)
                geo.materials = [elevatorShaftInteriorMaterial]
                return SCNNode(geometry: geo)
            }

            let shaft = SCNNode()
            shaft.position = SCNVector3(Float(wallCenterX), Float(elevatorCenterY), Float(wallCenterZ))
            let back = panel(width: CGFloat(halfW * 2), height: CGFloat(halfH * 2), length: CGFloat(thick))
            back.position = SCNVector3(0, 0, -depth)
            let top = panel(width: CGFloat(halfW * 2), height: CGFloat(thick), length: CGFloat(depth))
            top.position = SCNVector3(0, halfH, -depth / 2)
            let bottom = panel(width: CGFloat(halfW * 2), height: CGFloat(thick), length: CGFloat(depth))
            bottom.position = SCNVector3(0, -halfH, -depth / 2)
            let left = panel(width: CGFloat(thick), height: CGFloat(halfH * 2), length: CGFloat(depth))
            left.position = SCNVector3(-halfW, 0, -depth / 2)
            let right = panel(width: CGFloat(thick), height: CGFloat(halfH * 2), length: CGFloat(depth))
            right.position = SCNVector3(halfW, 0, -depth / 2)
            [back, top, bottom, left, right].forEach { shaft.addChildNode($0) }

            // Eddie, Sept 8: "the back of the elevator wall... it
            // should be the same thing on that wall thats there every
            // time we step into the elevator. its their homebase...
            // use that same pic and frame it and put it on the wall."
            // The exact building photo from the intro screen, loaded
            // the same bundled-file way IntroScreenView loads it
            // (Bundle.main.path(forResource:ofType:) ->
            // UIImage(contentsOfFile:)), so swapping in Eddie's real
            // building photo later is just replacing BuildingIntro.png
            // -- nothing here changes. Same frame-plus-plane recipe as
            // addFloorMapNode's wall pictures, sized down for the
            // elevator's own back wall. A child of shaft, so the
            // per-direction position/rotation applied to shaft below
            // carries it along for free. Handrails skipped for now --
            // "may be overkill... but for now you can just get the pic
            // in there."
            if let buildingPhotoPath = Bundle.main.path(forResource: "BuildingIntro", ofType: "png"),
               let buildingPhoto = UIImage(contentsOfFile: buildingPhotoPath) {
                let photoAspect = buildingPhoto.size.height / max(buildingPhoto.size.width, 1)
                // Eddie, Sept 8: shrinking this from 0.75 to 0.5
                // did NOT cut the zoom down -- "its still zooming in
                // just as much." Confirms the zoom was never about
                // this photo's own size, only about how close the
                // camera's fixed resting spot was to the wall it's
                // mounted on. elevatorShaftDepth (above) now backs
                // that resting spot off to a real distance, so this
                // goes back to its original, actually-readable size.
                // Eddie, Sept 8, from a screenshot at the dolly's
                // resting spot: "the side borders of the pic...
                // they look weird being bigger than the width
                // [of the screen]." The camera's own fieldOfView
                // (75) is the VERTICAL angle, so on a phone's tall,
                // narrow portrait screen the HORIZONTAL angle is a
                // good deal tighter -- on a typical iPhone's ~0.46
                // width/height ratio, about 39 degrees wide versus
                // 75 tall. At the ride's fixed ~0.77 camera-to-
                // frame distance, that narrower horizontal frustum
                // only has about 0.54 of clearance.
                //
                // Eddie, Sept 8, next report: "the borders are
                // just overlapping the edges of the screen." 0.48
                // fit the PHOTO itself inside that 0.54, but missed
                // that the visible edge is the FRAME around it
                // (photoFrameGeo below is photoWidth + 0.08), which
                // came out to 0.56 -- wider than the 0.54 available,
                // so of course it still clipped. 0.4 makes the
                // frame 0.48, comfortably inside 0.54 with real
                // margin this time, not just barely under it.
                let photoWidth: CGFloat = 0.4
                let photoHeight = photoWidth * photoAspect

                // Same point-blank headlamp blowout as the doors --
                // see makeElevatorDoorMaterial's comment.
                let photoFrameMaterial = SCNMaterial()
                photoFrameMaterial.diffuse.contents = UIColor(red: 0.55, green: 0.42, blue: 0.22, alpha: 1) // same warm brass as the doors
                photoFrameMaterial.lightingModel = .physicallyBased
                photoFrameMaterial.metalness.contents = 0.4
                photoFrameMaterial.roughness.contents = 0.55
                let photoFrameGeo = SCNBox(width: photoWidth + 0.08, height: photoHeight + 0.08, length: 0.03, chamferRadius: 0.005)
                photoFrameGeo.materials = [photoFrameMaterial]
                let photoFrame = SCNNode(geometry: photoFrameGeo)
                // Eddie, Sept 8, watching the dolly-in: "its as if our
                // vantage point is above the image, so the image moves
                // down. it should be at eye level." It was mounted low
                // on the wall (0.05 above shaft-center, well under the
                // 1.6 world-space eye height the camera actually rides
                // at -- shaft-center itself is elevatorCenterY, 1.1),
                // so the camera was always looking down at it, worst
                // of all right up close during the zoom. 0.5 above
                // shaft-center puts the frame's own center at 1.6,
                // dead level with the camera regardless of how close
                // the dolly gets.
                // 0.3 instead of 0.5 -- elevatorCenterY moved from
                // 1.1 to 1.3 along with the taller door above, so
                // this offset shrinks to match, keeping the frame's
                // center at the same 1.6 world-space eye height
                // (1.3 + 0.3 = 1.6, same as before's 1.1 + 0.5).
                photoFrame.position = SCNVector3(0, 0.3, -depth + thick / 2 + 0.02)

                let photoPlaneMaterial = SCNMaterial()
                photoPlaneMaterial.diffuse.contents = buildingPhoto
                photoPlaneMaterial.diffuse.wrapT = .clamp
                photoPlaneMaterial.lightingModel = .constant // reads as a lit picture, not shaded by scene lights/shadows
                let photoPlaneGeo = SCNPlane(width: photoWidth, height: photoHeight)
                photoPlaneGeo.materials = [photoPlaneMaterial]
                let photoPlane = SCNNode(geometry: photoPlaneGeo)
                photoPlane.position = SCNVector3(0, 0, 0.016)
                photoFrame.addChildNode(photoPlane)

                shaft.addChildNode(photoFrame)
            }

            // Eddie, Sept 8: "that hand rail i spoke about may be
            // necessary to confirm its an elevator. maybe just a
            // metalic long cylinder along the wall." One per side
            // wall, chrome-toned, running the depth of the shaft at
            // roughly waist height -- purely decorative, no
            // interaction, just the visual cue a real elevator car
            // has. Handrails only, per Eddie -- no back-wall rail.
            // Same point-blank headlamp blowout as the doors below
            // (see makeElevatorDoorMaterial's comment) -- a near-mirror
            // handrail sitting inches from the camera the whole ride
            // was the biggest single contributor. Satin/brushed instead
            // of chrome: still reads as metal, doesn't spike to white.
            let handrailMaterial = SCNMaterial()
            handrailMaterial.diffuse.contents = UIColor(white: 0.7, alpha: 1)
            handrailMaterial.lightingModel = .physicallyBased
            handrailMaterial.metalness.contents = 0.4
            handrailMaterial.roughness.contents = 0.6
            let handrailRadius: CGFloat = 0.015
            let handrailY = -halfH + 0.5
            let handrailInset: Float = 0.03
            func addHandrail(x: Float) {
                let geo = SCNCylinder(radius: handrailRadius, height: CGFloat(depth))
                geo.materials = [handrailMaterial]
                let node = SCNNode(geometry: geo)
                node.eulerAngles.x = .pi / 2
                node.position = SCNVector3(x, handrailY, -depth / 2)
                shaft.addChildNode(node)
            }
            addHandrail(x: -halfW + handrailInset)
            addHandrail(x: halfW - handrailInset)

            // Which world axis the wall itself runs along -- north/
            // south walls run east-west (world X), east/west walls run
            // north-south (world Z). The 2 panels split apart along
            // THIS axis, never the axis perpendicular to the wall
            // (that would push them out into the room instead of
            // tucking them sideways into the wall, the way a real
            // elevator's panels recess left and right).
            let alongWallX: CGFloat
            let alongWallZ: CGFloat
            switch direction {
            case .north, .south: (alongWallX, alongWallZ) = (1, 0)
            case .east, .west: (alongWallX, alongWallZ) = (0, 1)
            }

            let leftDoorGeo = SCNBox(width: elevatorPanelWidth, height: elevatorDoorHeight, length: elevatorDoorThickness, chamferRadius: 0.01)
            leftDoorGeo.materials = [elevatorDoorMaterial]
            let leftDoor = SCNNode(geometry: leftDoorGeo)
            leftDoor.position = SCNVector3(Float(wallCenterX - elevatorSplitOffset * alongWallX), Float(elevatorCenterY), Float(wallCenterZ - elevatorSplitOffset * alongWallZ))

            let rightDoorGeo = SCNBox(width: elevatorPanelWidth, height: elevatorDoorHeight, length: elevatorDoorThickness, chamferRadius: 0.01)
            rightDoorGeo.materials = [elevatorDoorMaterial]
            let rightDoor = SCNNode(geometry: rightDoorGeo)
            rightDoor.position = SCNVector3(Float(wallCenterX + elevatorSplitOffset * alongWallX), Float(elevatorCenterY), Float(wallCenterZ + elevatorSplitOffset * alongWallZ))

            switch direction {
            case .north:
                shaft.position.z += Float(0.05 + elevatorShaftGap)
                leftDoor.position.z += Float(0.05 + elevatorDoorGap)
                rightDoor.position.z += Float(0.05 + elevatorDoorGap)
            case .south:
                shaft.position.z -= Float(0.05 + elevatorShaftGap)
                leftDoor.position.z -= Float(0.05 + elevatorDoorGap)
                rightDoor.position.z -= Float(0.05 + elevatorDoorGap)
                shaft.eulerAngles.y = .pi
                leftDoor.eulerAngles.y = .pi
                rightDoor.eulerAngles.y = .pi
            case .east:
                shaft.position.x -= Float(0.05 + elevatorShaftGap)
                leftDoor.position.x -= Float(0.05 + elevatorDoorGap)
                rightDoor.position.x -= Float(0.05 + elevatorDoorGap)
                shaft.eulerAngles.y = -.pi / 2
                leftDoor.eulerAngles.y = -.pi / 2
                rightDoor.eulerAngles.y = -.pi / 2
            case .west:
                shaft.position.x += Float(0.05 + elevatorShaftGap)
                leftDoor.position.x += Float(0.05 + elevatorDoorGap)
                rightDoor.position.x += Float(0.05 + elevatorDoorGap)
                shaft.eulerAngles.y = .pi / 2
                leftDoor.eulerAngles.y = .pi / 2
                rightDoor.eulerAngles.y = .pi / 2
            }

            // Eddie, Sept 8: "the elevator doors are dropped (see
            // all the black at the top). its as if youre slightly
            // above the elevator." Not the camera -- this whole
            // wall face is skipped for the elevator's own cell (see
            // the hasWallNorth/etc conditionals further down that
            // omit it whenever elevatorMountDirection matches), and
            // unlike addDestinationDoor, addElevatorDoor never
            // called addDoorFrame to fill the leftover wall back
            // in around its own doorway. So above the 2.2-tall
            // doors, up to the 3.0 wallHeight, there was nothing
            // but fog/void -- reading as a black gap over doors
            // that look like they don't reach the ceiling. Same 4
            // brick-textured strips the destination doors and
            // floor maps already get, sized to this doorway.
            addDoorFrame(direction: direction, wallCenterX: wallCenterX, wallCenterZ: wallCenterZ, doorWidth: elevatorDoorWidth, doorHeight: elevatorDoorHeight, doorCenterY: elevatorCenterY)

            // Eddie, Sept 7, after watching the ride play out: the old
            // console (a centered arrow + big digit + a full row of
            // press-style buttons, all parked at chest height dead
            // center in the doorway) was the first thing you saw the
            // instant the doors opened -- blocking the plain back wall
            // he actually wants there ("we need to decide what we want
            // to put there"), and turning every step forward into "a
            // zoom into those buttons." Replaced with what he asked
            // for instead: "just a small row of numbers along the top
            // ... we really want to see the elevator doors from the
            // inside." One small digit per floor, mounted high near
            // the door's own header instead of dead center, so the
            // doorway itself stays the main thing in view. Whichever
            // floor is current starts lit; TapNavigationController's
            // lightElevatorPanel just shifts that lit digit from this
            // floor to the next one as the ride plays out.
            let indicatorY = Float(halfH) * 0.86
            let indicatorZ = Float(-0.05)
            let indicatorSpacing: Float = 0.14

            func billboardedText(_ string: String, sizeFactor: CGFloat, color: UIColor) -> SCNNode {
                let text = SCNText(string: string, extrusionDepth: 0.6)
                text.font = UIFont.boldSystemFont(ofSize: 32)
                text.flatness = 0.1
                let material = SCNMaterial()
                material.diffuse.contents = color
                material.emission.contents = UIColor(white: 0.05, alpha: 1)
                material.lightingModel = .physicallyBased
                material.isDoubleSided = true
                text.materials = [material]
                let node = SCNNode(geometry: text)
                let (minBound, maxBound) = text.boundingBox
                let w = maxBound.x - minBound.x
                let h = maxBound.y - minBound.y
                node.pivot = SCNMatrix4MakeTranslation(minBound.x + w / 2, minBound.y + h / 2, 0)
                let scale = h > 0 ? Float(elevatorDoorHeight * sizeFactor) / h : 1
                node.scale = SCNVector3(scale, scale, scale)
                let billboard = SCNBillboardConstraint()
                billboard.freeAxes = .Y
                node.constraints = [billboard]
                return node
            }

            var buttonNodes: [Int: SCNNode] = [:]
            let indicatorStartX = -indicatorSpacing * Float(totalFloors - 1) / 2
            for f in 1...max(totalFloors, 1) {
                let digitAnchor = SCNNode()
                digitAnchor.position = SCNVector3(indicatorStartX + indicatorSpacing * Float(f - 1), indicatorY, indicatorZ)
                let digitNode = billboardedText("\(f)", sizeFactor: 0.08, color: UIColor(white: 0.7, alpha: 1))
                if f == floorNumber {
                    digitNode.geometry?.firstMaterial?.emission.contents = UIColor(red: 1.0, green: 0.78, blue: 0.2, alpha: 1)
                }
                // Eddie, Sept 8: "the numbers still appear at the top
                // of the back wall. get rid of them." Hidden at build
                // time -- TapNavigationController.lightElevatorPanel
                // is the one place that reveals them again, right as
                // the ride turns to face the doors.
                digitNode.opacity = 0
                digitAnchor.addChildNode(digitNode)
                shaft.addChildNode(digitAnchor)
                buttonNodes[f] = digitNode
            }

            root.addChildNode(shaft)
            root.addChildNode(leftDoor)
            root.addChildNode(rightDoor)
            // Eddie, Sept 9: "tapping the elevator doors that
            // first time sometimes takes a while." The shaft's
            // own interior (back wall, side panels, photo, hand-
            // rails) sits behind the closed doors and is never
            // actually rendered until the FIRST open -- that's
            // exactly when SceneKit is forced to compile those
            // materials' shaders and upload the photo's texture
            // to the GPU for the first time, which is the hitch.
            // Returning `shaft` here (previously just added to
            // the scene and never handed back) lets ContentView
            // warm all of that up in the background the moment
            // the floor loads, well before the player ever
            // reaches the doors -- see view.prepare(...) in
            // HallwaySceneView.makeUIView.
            return (left: leftDoor, right: rightDoor, direction: direction, buttonNodes: buttonNodes, shaft: shaft)
        }

        // Wall-mounted, not a deep cubby like the destination doors --
        // this is a flat picture in a frame, so it only needs one thin
        // backing box (for a visible frame edge) plus a plane carrying
        // the actual map texture, nudged just proud of the frame face.
        // Returns the PLANE, not the frame -- Eddie, Sept 6: "when you
        // tap the wall map, let it blow up." The plane is the actual
        // visible, tappable picture (proud of the frame face, so a
        // straight-on tap's hit-test lands on it first), and it's also
        // what carries the live texture that needs refreshing as the
        // player moves (see makeFloorMapTexture's playerAt) -- callers
        // that want either "was this tapped" or "push a new image here"
        // need this specific node, not its frame.
        func addFloorMapNode(direction: Direction, wallCenterX: CGFloat, wallCenterZ: CGFloat, texture: UIImage) -> SCNNode {
            let aspect = texture.size.height / max(texture.size.width, 1)
            var panelWidth: CGFloat = 0.7
            var panelHeight = panelWidth * aspect
            let maxPanelHeight: CGFloat = 0.98
            if panelHeight > maxPanelHeight {
                panelHeight = maxPanelHeight
                panelWidth = panelHeight / aspect
            }

            let frameMaterial = SCNMaterial()
            frameMaterial.diffuse.contents = UIColor(red: 0.3, green: 0.22, blue: 0.1, alpha: 1)
            frameMaterial.lightingModel = .physicallyBased
            frameMaterial.metalness.contents = 0.6
            frameMaterial.roughness.contents = 0.4
            let frameGeo = SCNBox(width: panelWidth + 0.14, height: panelHeight + 0.14, length: 0.04, chamferRadius: 0.01)
            frameGeo.materials = [frameMaterial]
            let frame = SCNNode(geometry: frameGeo)

            let planeMaterial = SCNMaterial()
            planeMaterial.diffuse.contents = texture
            // No manual flip here -- SceneKit already maps a UIImage
            // texture's top-left origin correctly on its own. An
            // earlier attempt added a Y-flip transform "to correct for"
            // Core Graphics vs. SceneKit's UV convention; on-device that
            // flip was the actual bug (wall map ran upside down relative
            // to the real S/E layout), not a fix for one.
            planeMaterial.diffuse.wrapT = .clamp
            planeMaterial.lightingModel = .constant // reads as a lit sign, not shaded by scene lights/shadows
            let planeGeo = SCNPlane(width: panelWidth, height: panelHeight)
            planeGeo.materials = [planeMaterial]
            let plane = SCNNode(geometry: planeGeo)
            plane.position = SCNVector3(0, 0, 0.021)
            frame.addChildNode(plane)

            // Legend plaque, mounted BELOW the frame now instead of a
            // single "You Are Here" line above it -- Eddie, Sept 7:
            // "get rid of the you are here plaque above, and make it
            // the first item in the plaque we put at the bottom... a
            // legend... a list." Row 1 (red) is that same "You Are
            // Here," row 2 (black) is new -- the elevator dot already
            // existed on the map itself but was never explained. Rows
            // 3/4 (green) are conditional on this floor actually having
            // a mission: what to find, and -- if this floor also has a
            // delivery destination for it -- where to bring it. Eddie,
            // Sept 7: "a mission may have more than one item in the
            // map -- but 4 max," which is exactly what 2 fixed + 2
            // conditional rows caps out at. A CHILD of frame, same as
            // the plaque it replaces, so it inherits frame's own
            // per-direction position/rotation for free.
            let hasMissionItem = missionObjectKind != nil
            let hasMissionDestination = missionObjectKind != nil && (destinations.values.contains(missionObjectKind!) || (missionObjectKind == .envelope && !roomDoors.isEmpty))
            let legendTexture = makeMapLegendTexture(hasMissionItem: hasMissionItem, missionItemLabel: missionObjectKind?.missionLegendLabel ?? "", hasMissionDestination: hasMissionDestination)
            let legendAspect = legendTexture.size.height / max(legendTexture.size.width, 1)
            let legendWidth = (panelWidth / 1.4) * 0.85
            let legendHeight = legendWidth * legendAspect
            let legendGap: CGFloat = 0.09 // same gap the old plaque used
            let legendMaterial = SCNMaterial()
            legendMaterial.diffuse.contents = legendTexture
            legendMaterial.lightingModel = .constant
            let legendGeo = SCNPlane(width: legendWidth, height: legendHeight)
            legendGeo.materials = [legendMaterial]
            let legendNode = SCNNode(geometry: legendGeo)
            legendNode.position = SCNVector3(0, Float(-(panelHeight / 2 + legendGap + legendHeight / 2)), 0.021)
            frame.addChildNode(legendNode)

            // Same fix the destination chute just got (Eddie, Sept 5:
            // "the background texture is being used to render the
            // inside of the chute container") -- addWall was skipped
            // for this cell's ENTIRE wall face, not just the picture's
            // own small footprint, so without this the rest of that
            // wall would be empty space with fog showing through it.
            addDoorFrame(direction: direction, wallCenterX: wallCenterX, wallCenterZ: wallCenterZ, doorWidth: panelWidth + 0.14, doorHeight: panelHeight + 0.14, doorCenterY: wallHeight * 0.55 + 0.2)

            frame.position = SCNVector3(Float(wallCenterX), Float(wallHeight * 0.55 + 0.2), Float(wallCenterZ))
            switch direction {
            case .north:
                frame.position.z += Float(0.07)
            case .south:
                frame.position.z -= Float(0.07)
                frame.eulerAngles.y = .pi
            case .east:
                frame.position.x -= Float(0.07)
                frame.eulerAngles.y = -.pi / 2
            case .west:
                frame.position.x += Float(0.07)
                frame.eulerAngles.y = .pi / 2
            }

            root.addChildNode(frame)
            return plane
        }

        // A Floor Mission sign -- same wall-mounted-picture-frame shape
        // as addFloorMapNode just above, sized bigger (a heading +
        // paragraph needs more room than a small map thumbnail) and with
        // no "You Are Here" plaque. Doesn't return anything -- unlike
        // the floor map's plane, nothing ever needs to push a refreshed
        // texture to this later (the mission text is baked once, at
        // build time, and never changes live the way the map's tracking
        // dot does), so there's no reason for build()'s own return tuple
        // to track these nodes at all.
        func addMissionSignNode(direction: Direction, wallCenterX: CGFloat, wallCenterZ: CGFloat, texture: UIImage) {
            let aspect = texture.size.height / max(texture.size.width, 1)
            // 0.75, not 1.1 -- see the patch-script comment above this
            // call site for the "why" (portrait FOV is narrow; this
            // was overflowing the screen width edge to edge up close).
            var panelWidth: CGFloat = 0.75
            var panelHeight = panelWidth * aspect
            let maxPanelHeight: CGFloat = 1.5
            if panelHeight > maxPanelHeight {
                panelHeight = maxPanelHeight
                panelWidth = panelHeight / aspect
            }

            let frameMaterial = SCNMaterial()
            frameMaterial.diffuse.contents = UIColor(red: 0.3, green: 0.22, blue: 0.1, alpha: 1)
            frameMaterial.lightingModel = .physicallyBased
            frameMaterial.metalness.contents = 0.6
            frameMaterial.roughness.contents = 0.4
            let frameGeo = SCNBox(width: panelWidth + 0.12, height: panelHeight + 0.12, length: 0.04, chamferRadius: 0.01)
            frameGeo.materials = [frameMaterial]
            let frame = SCNNode(geometry: frameGeo)

            let planeMaterial = SCNMaterial()
            planeMaterial.diffuse.contents = texture
            planeMaterial.diffuse.wrapT = .clamp
            planeMaterial.lightingModel = .constant // reads as a lit sign, not shaded by scene lights/shadows
            let planeGeo = SCNPlane(width: panelWidth, height: panelHeight)
            planeGeo.materials = [planeMaterial]
            let plane = SCNNode(geometry: planeGeo)
            plane.position = SCNVector3(0, 0, 0.021)
            frame.addChildNode(plane)

            // Same fix the destination chute/floor map already needed
            // (Eddie, Sept 5: "the background texture is being used to
            // render the inside of the chute container") -- addWall was
            // skipped for this cell's ENTIRE wall face via
            // missionDirection above, not just the sign's own small
            // footprint.
            addDoorFrame(direction: direction, wallCenterX: wallCenterX, wallCenterZ: wallCenterZ, doorWidth: panelWidth + 0.12, doorHeight: panelHeight + 0.12, doorCenterY: wallHeight * 0.55)

            frame.position = SCNVector3(Float(wallCenterX), Float(wallHeight * 0.55), Float(wallCenterZ))
            switch direction {
            case .north:
                frame.position.z += Float(0.07)
            case .south:
                frame.position.z -= Float(0.07)
                frame.eulerAngles.y = .pi
            case .east:
                frame.position.x -= Float(0.07)
                frame.eulerAngles.y = -.pi / 2
            case .west:
                frame.position.x += Float(0.07)
                frame.eulerAngles.y = .pi / 2
            }

            root.addChildNode(frame)
        }

        // A decorative Picture -- same wall-mounted-picture-frame shape
        // as addFloorMapNode/addMissionSignNode above, sized like the
        // floor map (a snapshot-sized photo, not a full sign). Eddie,
        // Sept 9: "unlike trash chutes and sim mission objects, pictures
        // are there for esthetic reasons only... not anything that has
        // to be solved - just looked at." No legend, nothing to push a
        // live refresh to later (same as the mission sign) -- the ONE
        // difference from both of those is the texture argument here is
        // a different random photo per call, not one shared baked/still
        // texture, so two pictures placed on the same floor will most
        // likely show two different photos, not the same one twice.
        func addPictureNode(direction: Direction, wallCenterX: CGFloat, wallCenterZ: CGFloat, texture: UIImage) -> SCNMaterial {
            let aspect = texture.size.height / max(texture.size.width, 1)
            var panelWidth: CGFloat = 0.6
            var panelHeight = panelWidth * aspect
            let maxPanelHeight: CGFloat = 0.85
            if panelHeight > maxPanelHeight {
                panelHeight = maxPanelHeight
                panelWidth = panelHeight / aspect
            }

            let frameMaterial = SCNMaterial()
            frameMaterial.diffuse.contents = UIColor(red: 0.3, green: 0.22, blue: 0.1, alpha: 1)
            frameMaterial.lightingModel = .physicallyBased
            frameMaterial.metalness.contents = 0.6
            frameMaterial.roughness.contents = 0.4
            let frameGeo = SCNBox(width: panelWidth + 0.1, height: panelHeight + 0.1, length: 0.04, chamferRadius: 0.01)
            frameGeo.materials = [frameMaterial]
            let frame = SCNNode(geometry: frameGeo)

            let planeMaterial = SCNMaterial()
            planeMaterial.diffuse.contents = texture
            planeMaterial.diffuse.wrapT = .clamp
            planeMaterial.lightingModel = .constant // reads as a lit photo, not shaded by scene lights/shadows
            let planeGeo = SCNPlane(width: panelWidth, height: panelHeight)
            planeGeo.materials = [planeMaterial]
            let plane = SCNNode(geometry: planeGeo)
            plane.position = SCNVector3(0, 0, 0.021)
            frame.addChildNode(plane)

            // Same fix every other wall-mounted picture frame needs
            // (Eddie, Sept 5: "the background texture is being used to
            // render the inside of the chute container") -- addWall was
            // skipped for this cell's entire wall face via
            // pictureDirection above, not just this frame's own small
            // footprint.
            addDoorFrame(direction: direction, wallCenterX: wallCenterX, wallCenterZ: wallCenterZ, doorWidth: panelWidth + 0.1, doorHeight: panelHeight + 0.1, doorCenterY: wallHeight * 0.55)

            frame.position = SCNVector3(Float(wallCenterX), Float(wallHeight * 0.55), Float(wallCenterZ))
            switch direction {
            case .north:
                frame.position.z += Float(0.07)
            case .south:
                frame.position.z -= Float(0.07)
                frame.eulerAngles.y = .pi
            case .east:
                frame.position.x -= Float(0.07)
                frame.eulerAngles.y = -.pi / 2
            case .west:
                frame.position.x += Float(0.07)
                frame.eulerAngles.y = .pi / 2
            }

            root.addChildNode(frame)
            return planeMaterial
        }

        for coord in cells {
            let x = worldX(coord.col)
            let z = worldZ(coord.row)

            let floorGeo = SCNBox(width: cellSize, height: 0.1, length: cellSize, chamferRadius: 0)
            floorGeo.materials = [floorMaterial]
            let floorNode = SCNNode(geometry: floorGeo)
            floorNode.position = SCNVector3(Float(x), -0.05, Float(z))
            root.addChildNode(floorNode)

            let ceilingGeo = SCNBox(width: cellSize, height: 0.1, length: cellSize, chamferRadius: 0)
            ceilingGeo.materials = [ceilingMaterial]
            let ceilingNode = SCNNode(geometry: ceilingGeo)
            ceilingNode.position = SCNVector3(Float(x), Float(wallHeight) + 0.05, Float(z))
            root.addChildNode(ceilingNode)

            // Manually placed ceiling spotlight (Eddie, Sept 6: "how
            // difficult to have a spotlight that we could place on the
            // ceiling of a box?") -- same "editor decides where, build()
            // just draws it" split every other manual placement in this
            // file uses. A real SCNLight (.spot), aimed straight down
            // from just under the ceiling slab. This hallway's lighting
            // has already gone through several rounds of washout fixes
            // (see the headlamp/ambient rebalancing later in this
            // function), so intensity/attenuation started deliberately
            // conservative on the first pass -- Eddie's two follow-up
            // reports widened it from there: (1) "i see the floor lit up
            // in a circle... but there is no light on the ceiling" --
            // root cause, not a bug: the fixture sits just BELOW the
            // ceiling slab and points straight down and away from it, so
            // the ceiling's underside is physically never in the beam's
            // path no matter how it's tuned -- there was never going to
            // be a lit patch up there from illumination alone. Fixed by
            // giving the fixture an actual visible body: a small
            // self-lit disc flush with the ceiling (.constant lighting
            // model + emission, same "reads as lit regardless of scene
            // shading" trick the exit sign panel already uses), so
            // there's something to actually see up there independent of
            // what the real SCNLight illuminates below it. (2) "can you
            // make the spot bigger? so it catches some of the walls and
            // not just lights up the floor" -- widened spotOuterAngle
            // and the attenuation range so the cone's edge reaches out
            // to the cell's walls partway up, not just the floor
            // directly underneath. No cast shadows: real-time
            // shadow-casting spotlights are the expensive part of this
            // feature, and several lit at once is exactly the case where
            // that cost would show up on an iPad -- easy to turn on
            // later for a single accent light if the flat-lit look
            // isn't enough.
            if spotlights.contains(coord) {
                let fixtureMaterial = SCNMaterial()
                fixtureMaterial.diffuse.contents = UIColor(white: 0.98, alpha: 1)
                fixtureMaterial.emission.contents = UIColor(white: 0.95, alpha: 1)
                fixtureMaterial.lightingModel = .constant // reads as a lit fixture, not shaded like the ceiling around it
                let fixtureGeo = SCNCylinder(radius: cellSize * 0.12, height: 0.04)
                fixtureGeo.materials = [fixtureMaterial]
                let fixtureNode = SCNNode(geometry: fixtureGeo)
                fixtureNode.position = SCNVector3(Float(x), Float(wallHeight) - 0.02, Float(z))
                root.addChildNode(fixtureNode)

                // Eddie, Sept 6 (round 2): "decrease the target radius
                // quite a bunch... about half way between where it is
                // and what it was" -- splitting the difference between
                // the original tight cone (inner 20/outer 50, end
                // distance 1.6x wallHeight, intensity 400) and the
                // widened-to-catch-the-walls version just above
                // (30/100, 2.4x, 550) on every knob that controls reach,
                // not just angle -- intensity was raised alongside the
                // wider cone to keep the same energy from reading
                // dimmer over more area, so pulling the spread back in
                // without also pulling intensity back down would leave
                // it overbright for its new, smaller footprint.
                let spot = SCNLight()
                spot.type = .spot
                spot.color = UIColor.white
                spot.intensity = 475
                spot.spotInnerAngle = 25
                spot.spotOuterAngle = 75
                spot.attenuationStartDistance = distance(Double(cellSize) * 0.1)
                spot.attenuationEndDistance = distance(Double(wallHeight) * 2.0)
                spot.castsShadow = false
                let spotNode = SCNNode()
                spotNode.light = spot
                spotNode.position = SCNVector3(Float(x), Float(wallHeight) - 0.15, Float(z))
                spotNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0) // aim straight down
                root.addChildNode(spotNode)
            }

            let hasWallNorth = !isOpen(coord.row - 1, coord.col)
            let hasWallSouth = !isOpen(coord.row + 1, coord.col)
            let hasWallEast = !isOpen(coord.row, coord.col + 1)
            let hasWallWest = !isOpen(coord.row, coord.col - 1)

            // A true dead end has exactly one open side — the way you
            // came in, and the only way back out. The wall directly
            // opposite that opening is the one you end up staring at
            // -- kept only as a placement PREFERENCE for a destination
            // cubby or the elevator (below): Eddie, Sept 7, found this
            // wall was ALSO getting special visual treatment (a
            // clamped, untiled "full picture" texture instead of the
            // normal tiled one everyone else gets), and with left/right
            // walls present that read as bigger/brighter than its
            // neighbors purely from the different tiling -- not
            // wanted, so that visual distinction is gone; every wall
            // (dead-end or not) now uses the exact same material.
            let openDirs: [Direction] = [
                !hasWallNorth ? .north : nil,
                !hasWallSouth ? .south : nil,
                !hasWallEast ? .east : nil,
                !hasWallWest ? .west : nil,
            ].compactMap { $0 }
            let capSide: Direction? = openDirs.count == 1 ? openDirs[0].opposite : nil

            // Which wall (if any) this cell's destination cubby will be
            // recessed into. Computed here, before any wall gets built,
            // so that specific wall can be skipped outright rather than
            // built solid and then merely fronted by the cubby -- see
            // the addDestinationDoor call below for the fix this feeds.
            let destinationMountDirection: Direction? = {
                guard destinations[coord] != nil else { return nil }
                let solidDirections: [Direction] = [.north, .south, .east, .west].filter { d in
                    switch d {
                    case .north: return hasWallNorth
                    case .south: return hasWallSouth
                    case .east: return hasWallEast
                    case .west: return hasWallWest
                    }
                }
                return capSide ?? solidDirections.first
            }()

            // Same idea, for the elevator -- but only ever true for ONE
            // cell per floor: MazeStore.elevatorCoordinate, computed
            // above the loop as both `start` and `end`. Used to skip
            // building an elevator at all when end == start ("nothing
            // to reach") -- that used to mean a degenerate 1-cell
            // maze, but now start and end are ALWAYS the same cell by
            // design (Eddie, Sept 5's one-elevator-for-the-building
            // change), so that guard would have silently deleted the
            // elevator from every floor in the game.
            let elevatorMountDirection: Direction? = {
                guard coord == end else { return nil }
                let solidDirections: [Direction] = [.north, .south, .east, .west].filter { d in
                    switch d {
                    case .north: return hasWallNorth
                    case .south: return hasWallSouth
                    case .east: return hasWallEast
                    case .west: return hasWallWest
                    }
                }
                return capSide ?? solidDirections.first
            }()

            // Manually placed now (Eddie, Sept 5: "let me control that
            // and put maps wherever i want") -- the wall-skip check
            // just below needs to know whether THIS cell has one, same
            // as it already does for destinations/the elevator.
            let mapDirection = floorMaps[coord]

            // Same idea once more, for the Floor Mission sign -- manually
            // placed (Eddie, Sept 7: "just add it to the thingies on the
            // map/edit view so i can put mission statement banners
            // wherever i want"), same wall-skip check as the floor map.
            let missionDirection = missionSigns[coord]

            // Same idea once more, for a decorative Picture -- manually
            // placed (Eddie, Sept 9: "make the picture appear as a
            // picture on the wall"), same wall-skip check as the floor
            // map/mission sign.
            let pictureDirection = pictures[coord]

            // One fresh material per wall segment (see the comment
            // above wallMaterials) — either a dead-end cap or a regular
            // wall material, added to its matching array so the live
            // theme swap in ContentView's Coordinator can reach it.
            func addWall(width: CGFloat, length: CGFloat, x: CGFloat, z: CGFloat) {
                let geo = SCNBox(width: width, height: wallHeight, length: length, chamferRadius: 0)
                let material = makeWallMaterial(imageName: theme.wallImageName)
                geo.materials = [material]
                wallMaterials.append(material)
                let node = SCNNode(geometry: geo)
                node.position = SCNVector3(Float(x), Float(wallHeight / 2), Float(z))
                root.addChildNode(node)
            }

            if hasWallNorth && destinationMountDirection != .north && elevatorMountDirection != .north && mapDirection != .north && missionDirection != .north && pictureDirection != .north {
                addWall(width: cellSize, length: 0.1, x: x, z: z - half)
            }
            if hasWallSouth && destinationMountDirection != .south && elevatorMountDirection != .south && mapDirection != .south && missionDirection != .south && pictureDirection != .south {
                addWall(width: cellSize, length: 0.1, x: x, z: z + half)
            }
            if hasWallEast && destinationMountDirection != .east && elevatorMountDirection != .east && mapDirection != .east && missionDirection != .east && pictureDirection != .east {
                addWall(width: 0.1, length: cellSize, x: x + half, z: z)
            }
            if hasWallWest && destinationMountDirection != .west && elevatorMountDirection != .west && mapDirection != .west && missionDirection != .west && pictureDirection != .west {
                addWall(width: 0.1, length: cellSize, x: x - half, z: z)
            }

            // Doorway markers — only at TRUE intersections (3 or 4 open
            // sides), where you actually have a choice to make under tap
            // navigation. A plain pass-through or a turn (exactly 2 open
            // sides) auto-advances and never stops there, so marking every
            // boundary was just clutter — especially along a long straight
            // run like the cross maze's arms. A real decision point gets a
            // red header bar + threshold line over each of its open sides,
            // so arriving there it's obvious you've hit a choice.
            let openSides = [!hasWallNorth, !hasWallSouth, !hasWallEast, !hasWallWest].filter { $0 }.count
            if openSides >= 3 {
                addIntersectionMarker(atX: x, z: z, openNorth: !hasWallNorth, openSouth: !hasWallSouth, openEast: !hasWallEast, openWest: !hasWallWest)
            }

            // First slice of the pick-up/deliver mechanic — this pass
            // only places what it LOOKS like, a spinning heart or star
            // marking a cell with something in it, so it can be seen and
            // judged before any carrying/delivering logic gets built on
            // top.
            if let kind = objects[coord] {
                let node = kind == .envelope ? makeEnvelopeNode(roomNumber: itemRooms[coord]) : makeObjectNode(kind, size: cellSize * 0.22)
                node.position = SCNVector3(Float(x), Float(wallHeight * (kind == .envelope ? 0.4 : 0.25)), Float(z))
                root.addChildNode(node)
                objectNodes[coord] = node
            }

            // The deposit half -- manually placed per cell (GridEditorView).
            // WHICH wall it mounts on was already decided above
            // (destinationMountDirection), before that wall's ordinary
            // panel got a chance to be built -- the dead-end cap wall if
            // this is a dead end (the one wall you're already staring
            // at), otherwise the first solid wall found in a fixed
            // order. Never placed on an open side -- nothing to mount on.
            if let destKind = destinations[coord], let mountDirection = destinationMountDirection {
                let wx: CGFloat
                let wz: CGFloat
                switch mountDirection {
                case .north: (wx, wz) = (x, z - half)
                case .south: (wx, wz) = (x, z + half)
                case .east: (wx, wz) = (x + half, z)
                case .west: (wx, wz) = (x - half, z)
                }
                let door = addDestinationDoor(direction: mountDirection, wallCenterX: wx, wallCenterZ: wz, kind: destKind)
                destinationNodes[coord] = door
            }

            // The elevator -- same "which wall, computed before any
            // wall panel gets built" pattern as the destination cubby
            // just above, just for whichever ONE cell is this floor's
            // end.
            if let mountDirection = elevatorMountDirection {
                let wx: CGFloat
                let wz: CGFloat
                switch mountDirection {
                case .north: (wx, wz) = (x, z - half)
                case .south: (wx, wz) = (x, z + half)
                case .east: (wx, wz) = (x + half, z)
                case .west: (wx, wz) = (x - half, z)
                }
                elevatorDoors = addElevatorDoor(direction: mountDirection, wallCenterX: wx, wallCenterZ: wz, floorNumber: floorNumber, totalFloors: totalFloors)
            }

            let xLower = x - half + (hasWallWest ? margin : 0)
            let xUpper = x + half - (hasWallEast ? margin : 0)
            let zLower = z - half + (hasWallNorth ? margin : 0)
            let zUpper = z + half - (hasWallSouth ? margin : 0)
            walkableRects.append(FloorRect(xRange: xLower...xUpper, zRange: zLower...zUpper))
        }

        // Exit Signs -- manually placed in GridEditorView now (Eddie,
        // Sept 5, round 5: "let me lay the exit signs down manually...
        // doing it auto in the code comes up with funky layouts where
        // theres a bunch of exits in a row"), so this just draws
        // whatever's in `exitSigns`: no topology test, no BFS toward
        // `end`, no auto-picked direction. A coordinate the editor
        // placed one at that's since been walled back off (setClosed
        // already scrubs exitSigns for that cell, but a stale save file
        // could in principle predate that) is skipped rather than
        // built floating in a wall.
        for door in roomDoors.values {
            let neighbor = GridCoordinate(row: door.coord.row + door.direction.delta.row, col: door.coord.col + door.direction.delta.col)
            guard cells.contains(door.coord), !cells.contains(neighbor) else { continue }
            root.addChildNode(makeRoomDoorNode(door, cellSize: cellSize))
        }

        for (coord, direction) in exitSigns {
            guard cells.contains(coord) else { continue }
            let x = worldX(coord.col)
            let z = worldZ(coord.row)
            let sign = makeExitSignNode(pointing: direction, cellSize: cellSize)

            // Which way to offset the mount point -- Eddie, Sept 5
            // (round 7): a forced-turn cell (exactly 2 open sides) is
            // arrived at STILL FACING the way you were walking, not
            // the way the sign points -- e.g. you walk south into a
            // corner whose only other way onward is west; you arrive
            // facing south, and a sign offset toward west sits a full
            // 90 degrees off your view, so close (one cell away) that
            // no amount of billboard rotation puts it back in frame.
            // "i hit fwd again... it hits the corner which also has an
            // exit sign... although im in that corner box, the exit
            // sign does not appear. i just see the wall." That "wall"
            // IS the right place for the sign -- it's the wall that
            // stopped you, so it's exactly what you're already looking
            // at. For a true fork (3-4 open sides) `direction` itself
            // is usually the "keep going straight" option anyway
            // (already tested working at the very first intersection),
            // so this only overrides the offset for the narrower,
            // unambiguous 2-open-sides case.
            let openDirections = Direction.allCases.filter { d in
                isOpen(coord.row + d.delta.row, coord.col + d.delta.col)
            }
            var offsetDirection = direction
            if openDirections.count == 2, let onlyOtherOpen = openDirections.first(where: { $0 != direction }) {
                offsetDirection = onlyOtherOpen.opposite
            }
            // Still not showing up even after last round's reposition
            // (Eddie, Sept 5, round 8: "the corner one still does
            // not"). The turn fix above got the ANGLE right -- offsetting
            // toward the wall the player is actually facing -- but for a
            // forced turn that wall is, by definition, a SOLID one (the
            // reason it's a forced turn at all), and 1.05x half pushes
            // the sign almost to that wall's far face. addWall's panel
            // is 0.1 thick, centered on the cell boundary, so at 1.05x
            // the sign lands only ~0.03 units short of coming out the
            // BACK of it -- comfortably behind the wall's near face from
            // the camera's side, i.e. hidden behind solid geometry
            // instead of merely out of frame. Every OPEN-direction
            // offset (the original "toward the doorway" case, and the
            // true-fork case above) keeps the full 1.05x, since there's
            // no wall there to hide behind; only a CLOSED-direction
            // offset (this forced-turn case) needs real clearance from
            // that wall's near face, which sits at half - 0.05.
            let offsetIsOpen = isOpen(coord.row + offsetDirection.delta.row, coord.col + offsetDirection.delta.col)
            let offsetFraction: CGFloat = offsetIsOpen ? 1.05 : 0.8
            let towardOffsetX = CGFloat(offsetDirection.delta.col) * half * offsetFraction
            let towardOffsetZ = CGFloat(offsetDirection.delta.row) * half * offsetFraction
            sign.position = SCNVector3(Float(x + towardOffsetX), Float(wallHeight * 0.72), Float(z + towardOffsetZ))
            root.addChildNode(sign)
            exitSignNodes[coord] = sign
        }

        // The "You Are Here" wall map -- manually placed now (Eddie,
        // Sept 5: "let me control that and put maps wherever i want"),
        // the exact same "editor decides where, build() just draws it"
        // split exit signs already use, one loop below theirs. Unlike
        // an Exit Sign, `direction` has to actually be a solid wall --
        // nothing to hang a picture on across an open doorway -- so a
        // stale save from before a wall came down is skipped here
        // rather than drawn floating in a doorway.
        if !floorMaps.isEmpty {
            // playerAt: start -- the cell you're actually standing in
            // the instant this floor is built, which (since start ==
            // end == the elevator now) is also where the black elevator
            // dot goes. TapNavigationController regenerates this same
            // texture and pushes it to every plane in floorMapPlaneNodes
            // (below) whenever currentCell changes afterward, so the red
            // dot tracks you live from here on -- see its
            // refreshFloorMapTexture().
            let mapTexture = makeFloorMapTexture(cells: cells, end: end, maxRow: maxRow, maxCol: maxCol, playerAt: start, missionItemCells: Array(objects.filter { $0.value == missionObjectKind }.keys), missionDestinationCells: Array(destinations.filter { $0.value == missionObjectKind }.keys), roomDoors: roomDoors, itemRooms: itemRooms)
            for (coord, direction) in floorMaps {
                guard cells.contains(coord) else { continue }
                guard !isOpen(coord.row + direction.delta.row, coord.col + direction.delta.col) else { continue }
                let mapX = worldX(coord.col)
                let mapZ = worldZ(coord.row)
                let wx: CGFloat
                let wz: CGFloat
                switch direction {
                case .north: (wx, wz) = (mapX, mapZ - half)
                case .south: (wx, wz) = (mapX, mapZ + half)
                case .east: (wx, wz) = (mapX + half, mapZ)
                case .west: (wx, wz) = (mapX - half, mapZ)
                }
                let plane = addFloorMapNode(direction: direction, wallCenterX: wx, wallCenterZ: wz, texture: mapTexture)
                floorMapPlaneNodes.append(plane)
            }
        }

        // The Floor Mission sign -- manually placed the same way floor
        // maps are (Eddie, Sept 7: "just add it to the thingies on the
        // map/edit view so i can put mission statement banners wherever
        // i want... much simpler (just like the wall maps)"). One
        // shared heading+body texture baked once per floor (static
        // text, no live per-frame refresh needed unlike the map's
        // tracking dot), same solid-wall-required check as floor maps.
        if !missionSigns.isEmpty {
            let missionTexture = makeMissionSignTexture(heading: missionHeading, body: missionBody)
            for (coord, direction) in missionSigns {
                guard cells.contains(coord) else { continue }
                guard !isOpen(coord.row + direction.delta.row, coord.col + direction.delta.col) else { continue }
                let signX = worldX(coord.col)
                let signZ = worldZ(coord.row)
                let wx: CGFloat
                let wz: CGFloat
                switch direction {
                case .north: (wx, wz) = (signX, signZ - half)
                case .south: (wx, wz) = (signX, signZ + half)
                case .east: (wx, wz) = (signX + half, signZ)
                case .west: (wx, wz) = (signX - half, signZ)
                }
                addMissionSignNode(direction: direction, wallCenterX: wx, wallCenterZ: wz, texture: missionTexture)
            }
        }

        // Decorative Pictures -- manually placed the same way floor
        // maps/mission signs are (Eddie, Sept 9: "make the picture
        // appear as a picture on the wall (like we do to the mission
        // and maps)... when a picture is on a wall, grab a random
        // picture from that folder"). Unlike those two, no ONE shared
        // texture is baked up front -- randomPictureImage() is called
        // fresh inside the loop, once per placement, so a floor with
        // several pictures mounted around it most likely shows several
        // different photos, not the same one repeated.
        var cameraRollMaterials: [SCNMaterial] = []
        if !pictures.isEmpty {
            for (coord, direction) in pictures {
                guard cells.contains(coord) else { continue }
                guard !isOpen(coord.row + direction.delta.row, coord.col + direction.delta.col) else { continue }
                guard let pictureTexture = randomPictureImage() else { continue }
                let picX = worldX(coord.col)
                let picZ = worldZ(coord.row)
                let wx: CGFloat
                let wz: CGFloat
                switch direction {
                case .north: (wx, wz) = (picX, picZ - half)
                case .south: (wx, wz) = (picX, picZ + half)
                case .east: (wx, wz) = (picX + half, picZ)
                case .west: (wx, wz) = (picX - half, picZ)
                }
                let texture = Self.framedPhoto(pictureTexture)
                let material = addPictureNode(direction: direction, wallCenterX: wx, wallCenterZ: wz, texture: texture)
                if picturesUseCameraRoll { cameraRollMaterials.append(material) }
            }
        }

        if !cameraRollMaterials.isEmpty {
            // Weak references let a discarded floor go away during an iCloud download.
            let applyImages: [(UIImage?) -> Void] = cameraRollMaterials.map { material in
                { [weak material] image in
                    guard let material, let image else { return }
                    material.diffuse.contents = Self.framedPhoto(image)
                }
            }
            PhotoRollProvider.shared.randomImages(count: applyImages.count) { index, image in
                applyImages[index](image)
            }
        }

        // Spawn at the top-left-most open cell (lowest row, then lowest
        // col), facing the first open neighbor going south/east/north/west
        // — so you start already looking down a hallway, not into a wall.
        // (start itself is computed earlier now, alongside end -- see
        // the per-cell loop's own comment above.)
        let startX = worldX(start.col)
        let startZ = worldZ(start.row)

        var spawnYaw: Double = 0
        let facingCandidates: [(Int, Int)] = [(1, 0), (0, 1), (-1, 0), (0, -1)]
        for (dRow, dCol) in facingCandidates {
            if isOpen(start.row + dRow, start.col + dCol) {
                spawnYaw = atan2(-Double(dCol), -Double(dRow))
                break
            }
        }

        let camera = SCNCamera()
        camera.fieldOfView = 75
        camera.zNear = 0.05
        camera.zFar = Double(span) + 40
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(Float(startX), 1.6, Float(startZ))
        cameraNode.eulerAngles = SCNVector3(0, Float(spawnYaw), 0)
        root.addChildNode(cameraNode)

        // A single light, attached to the camera so it always travels
        // with you. It can never stack with another light because there
        // is no other light.
        //
        // Round 4 on this same wash-out-to-white bug. Round 1 pulled
        // attenuationStartDistance in from the exact minimum wall
        // distance (see below). Round 2/3: Eddie's A/B test (same cell,
        // only turning left, so distance never changed) proved a plain
        // distance-boundary fix wasn't enough — the cap wall (immune,
        // .constant-lit) was fine, the ordinary side wall at the same
        // distance still washed out — so the raw peak intensity (170,
        // then 90) attacks the ceiling directly instead. Still not
        // enough per Eddie's next report, and the extra detail he gave
        // pins down why: it's not just close range, it's close range
        // AND looking straight-on at the wall (fine from an angle at
        // the screen's edge, washes out once you turn to face it
        // dead-on). That's the geometric worst case for ANY light
        // riding on the camera: when you're pointed straight at
        // something nearby, its surface directly faces both the light
        // and your eye at once — the single brightest configuration
        // this setup can ever produce, by construction, not a fluke.
        // A real flashlight does the same thing pointed point-blank at
        // a close wall.
        //
        // Rather than keep hunting for one intensity number that
        // survives that worst case (two guesses down), rebalancing the
        // MIX is more robust: shrink the directional/spiking part
        // (headlamp) hard, and lean more on the flat ambient term below
        // instead, since ambient can't spike — it's the same everywhere
        // regardless of distance or viewing angle. Less of the scene's
        // total light comes from the one component capable of blowing
        // out at point-blank-and-square-on; more comes from the one
        // that structurally can't.
        let headlamp = SCNLight()
        headlamp.type = .omni
        headlamp.intensity = 30
        headlamp.color = UIColor.white
        // Keeps every wall solidly past the "flat, undimmed" boundary
        // (see history above) instead of sitting right at its edge;
        // attenuationEndDistance reaches a couple of cells out, giving a
        // near-brighter/far-dimmer depth cue for free, from real falloff.
        headlamp.attenuationStartDistance = distance(Double(cellSize) * 0.15)
        headlamp.attenuationEndDistance = distance(Double(cellSize) * 2.2)
        let headlampNode = SCNNode()
        headlampNode.light = headlamp
        cameraNode.addChildNode(headlampNode)

        // Carries more of the baseline visibility now that the headlamp
        // above is intentionally weak (see its comment) — raised from
        // 70 so the far end of a hallway doesn't just go dark instead of
        // washing out. Still flat/angle-independent, so it can't
        // reproduce the point-blank-and-square-on spike no matter how
        // high it goes; if the hallway still reads too dim at a normal
        // walking distance, raise this rather than the headlamp.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 110
        ambient.color = UIColor(white: 0.6, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        // The end cell's marker used to be a floating glowing ball
        // here (a placeholder before there was a real elevator to
        // draw) -- it's gone now that the elevator built inside the
        // per-cell loop above is a real wall fixture that already
        // marks the spot, and reads a lot more like "the mechanism
        // that takes you to the next floor" than a stray ball did.

        return (scene, cameraNode, walkableRects, wallMaterials, floorMaterial, ceilingMaterial, objectNodes, destinationNodes, elevatorDoors, exitSignNodes, floorMapPlaneNodes)
    }

    // MARK: - Materials (unchanged from Prototype 1)

    // Flat fallback colors for each surface — used whenever a theme
    // doesn't supply a texture for that surface (imageName nil or the
    // file's missing from the bundle). Exposed so ContentView's
    // Coordinator can fall back to the exact same colors when it swaps
    // materials live on a theme change, without duplicating these values.
    static let wallFallbackColor = UIColor(red: 0.45, green: 0.22, blue: 0.18, alpha: 1)
    static let floorFallbackColor = UIColor(white: 0.16, alpha: 1)
    static let ceilingFallbackColor = UIColor(white: 0.10, alpha: 1)

    // The "Office" theme (Eddie, Sept 6: "add a wall/floor/ceiling
    // style... one that looks more like an office... beige walls with
    // gradient") has no bundled photo -- there's nothing to shoot a
    // picture of, it's a plain painted gradient. Rather than requiring a
    // real jpg dropped into the Xcode project (which needs its own
    // target-membership step Eddie would have to do by hand in Xcode),
    // these two sentinel strings stand in for "generate this gradient
    // in code instead of loading a file" -- resolveThemeImage below is
    // the one place that distinction gets made, so every surface that
    // already knows how to take an imageName (walls/floor/ceiling here,
    // plus the dead-end cap and destination cubby elsewhere in this
    // file) gets the office theme for free with no other changes.
    static let officeWallGradientName = "__officeWallGradient"
    static let officeCeilingGradientName = "__officeCeilingGradient"

    /// True for the two sentinel names above -- callers that tile
    /// photos 2x2 (see makeSurfaceMaterial) need to know NOT to tile a
    /// gradient that way, or the smooth fade would visibly repeat/seam
    /// partway up the wall instead of running once, top to bottom.
    static func isProceduralGradientImage(_ imageName: String?) -> Bool {
        imageName == officeWallGradientName || imageName == officeCeilingGradientName
    }

    /// Resolves an imageName into an actual UIImage -- either a real
    /// bundled photo, looked up the same way every existing theme's jpg
    /// already was (this is exactly the lookup that used to be written
    /// out, separately, at every call site below AND in ContentView's
    /// Coordinator.applySurface; centralizing it here
    /// means the office theme (or any future procedural one) only has
    /// to be taught to ONE place instead of several that have to be kept
    /// in sync by hand), or, for the two sentinel names above, a
    /// generated gradient. nil (missing bundle file, or no imageName at
    /// all) is still nil -- every caller already has its own flat
    /// fallback color for that case.
    /// Every bundled decorative-picture filename (no extension --
    /// loaded as "<name>.jpg", same Bundle.main.path(forResource:ofType:)
    /// lookup every other bundled photo here already uses). Eddie, Sept
    /// 9's first batch of 9.
    private static let pictureAssetNames: [String] = [
        "IMG_7416", "IMG_7439", "IMG_7487", "IMG_7598", "IMG_7604",
        "IMG_7605", "IMG_7606", "IMG_7607", "IMG_7608",
    ]

    /// CSS-cover equivalent for the 0.6 × 0.85 portrait picture opening.
    /// Scale uniformly to fill it, center the image, and clip the overflow.
    /// Both bundled and camera-roll photos use the same frame and crop.
    private static func framedPhoto(_ image: UIImage) -> UIImage {
        let size = CGSize(width: 512, height: 512 * 0.85 / 0.6)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.08, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let scale = max(size.width / max(image.size.width, 1), size.height / max(image.size.height, 1))
            let width = image.size.width * scale
            let height = image.size.height * scale
            image.draw(in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
        }
    }

    private static func randomPictureImage() -> UIImage? {
        guard let name = pictureAssetNames.randomElement(),
              let path = Bundle.main.path(forResource: name, ofType: "jpg") else { return nil }
        return UIImage(contentsOfFile: path)
    }

    static func resolveThemeImage(_ imageName: String?) -> UIImage? {
        guard let imageName else { return nil }
        switch imageName {
        case officeWallGradientName:
            return makeGradientImage(
                top: UIColor(red: 0.86, green: 0.80, blue: 0.68, alpha: 1),
                bottom: UIColor(red: 0.72, green: 0.65, blue: 0.52, alpha: 1)
            )
        case officeCeilingGradientName:
            return makeGradientImage(top: UIColor(white: 0.93, alpha: 1), bottom: UIColor(white: 0.85, alpha: 1))
        default:
            guard let path = Bundle.main.path(forResource: imageName, ofType: "jpg") else { return nil }
            return UIImage(contentsOfFile: path)
        }
    }

    /// A plain vertical gradient, painted in code rather than shot as a
    /// photo -- lighter at the top fading to darker at the bottom, the
    /// same direction real ambient light would fall in an office with
    /// ceiling-mounted fixtures. Reused for both the wall and ceiling
    /// sentinels above with different color pairs.
    private static func makeGradientImage(top: UIColor, bottom: UIColor, size: CGSize = CGSize(width: 256, height: 256)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [top.cgColor, bottom.cgColor] as CFArray,
                locations: [0, 1]
            ) else { return }
            context.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: size.height),
                options: []
            )
        }
    }

    /// Shared by walls/floor/ceiling: an optional real photo (or the
    /// Office theme's generated gradient -- see resolveThemeImage),
    /// tiled, or a flat fallback color if there's no image name, or the
    /// named file isn't in the bundle for some reason (so a missing
    /// asset never turns into a blank surface). The returned material is
    /// kept by the caller (ContentView's Coordinator) so the theme
    /// button can swap `.diffuse.contents` on it directly later without
    /// rebuilding the whole scene.
    private static func makeSurfaceMaterial(imageName: String?, fallbackColor: UIColor, roughness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        if let image = resolveThemeImage(imageName) {
            m.diffuse.contents = image
            m.diffuse.wrapS = .repeat
            if isProceduralGradientImage(imageName) {
                // One smooth fade top-to-bottom per wall panel, not
                // tiled -- clamping vertically (and leaving the
                // vertical scale at 1x) means the gradient image maps
                // exactly once instead of repeating and visibly
                // seaming partway up.
                m.diffuse.wrapT = .clamp
                m.diffuse.contentsTransform = SCNMatrix4MakeScale(2, 1, 1)
            } else {
                m.diffuse.wrapT = .repeat
                m.diffuse.contentsTransform = SCNMatrix4MakeScale(2, 2, 1)
            }
        } else {
            m.diffuse.contents = fallbackColor
        }
        m.lightingModel = .physicallyBased
        m.roughness.contents = roughness
        m.metalness.contents = 0.0
        return m
    }

    private static func makeWallMaterial(imageName: String?) -> SCNMaterial {
        makeSurfaceMaterial(imageName: imageName, fallbackColor: wallFallbackColor, roughness: 0.9)
    }

    private static func makeFloorMaterial(imageName: String?) -> SCNMaterial {
        makeSurfaceMaterial(imageName: imageName, fallbackColor: floorFallbackColor, roughness: 0.95)
    }

    private static func makeCeilingMaterial(imageName: String?) -> SCNMaterial {
        makeSurfaceMaterial(imageName: imageName, fallbackColor: ceilingFallbackColor, roughness: 0.95)
    }

    /// A full, undistorted photo — clamped (not tiled) and lit with
    /// .constant so it's immune to the headlamp/ambient falloff that
    /// can wash a normal wall out to near-white at close range. Falls
    /// back to the same flat wall color as a normal wall if there's no
    /// image (or the theme doesn't have one, e.g. My Photos before its
    /// first camera-roll fetch completes).
    /// Builds the actual 3D piece for one ObjectKind at a given size --
    /// shared by floor placement (spinning on the ground) and
    /// destination-icon placement (mounted flat behind a wall shutter),
    /// so there's exactly one switch over ObjectKind's cases instead of
    /// one per call site.
    private static func makeObjectNode(_ kind: ObjectKind, size: CGFloat) -> SCNNode {
        switch kind {
        case .heart:
            return makeHeartNode(size: size)
        case .star:
            return makeStarNode(size: size)
        case .iceCream:
            return makeIceCreamNode(size: size)
        case .appleWhole:
            return makeAppleWholeNode(size: size)
        case .babyCarriage:
            return makeBabyCarriageNode(size: size)
        case .snowman:
            return makeSnowmanNode(size: size)
        case .personBiking:
            return makePersonBikingNode(size: size)
        case .cakeCandles:
            return makeCakeCandlesNode(size: size)
        case .trashCan:
            return makeTrashCanNode(size: size)
        case .cash100:
            return makeCash100Node(size: size)
        case .envelope:
            return makeEnvelopeNode(size: size)
        case .key:
            // Keep the existing key object renderable while its mission evolves.
            return makeIconNode(
                pathData: "M256 24 A112 112 0 1 1 208 237 L208 488 L304 488 L304 440 L264 440 L264 400 L304 400 L304 237 A112 112 0 0 1 256 24 Z M256 80 A56 56 0 1 0 256 192 A56 56 0 1 0 256 80 Z",
                nativeWidth: 512, nativeHeight: 512, size: size,
                diffuseColor: UIColor(red: 0.95, green: 0.72, blue: 0.2, alpha: 1),
                emissionColor: UIColor(red: 0.3, green: 0.18, blue: 0.02, alpha: 1))
        }
    }

    /// The shiny metal shutter that hides a destination's matching icon
    /// until you arrive with the right critter -- physically based,
    /// high metalness/low roughness so it actually reads as polished
    /// metal (a dumbwaiter-style panel) rather than flat gray paint.
    private static func makeDestinationDoorMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(white: 0.78, alpha: 1)
        m.lightingModel = .physicallyBased
        m.metalness.contents = 1.0
        m.roughness.contents = 0.22
        return m
    }

    /// The dark interior of a destination's recessed cubby -- near-black
    /// and non-reflective so it reads as a genuinely dark box under the
    /// hallway's normal ambient light, not just a dim gray wall (Eddie,
    /// Sept 5: "a very dark 3d looking inside of a cube").
    private static func makeCubbyInteriorMaterial(imageName: String?) -> SCNMaterial {
        let m = SCNMaterial()
        // Eddie, Sept 5 (round 2): "is there a way to fix the issue of
        // things on the wall... have a black background. cant we use
        // the real wall texturing for those." Same photo the ordinary
        // walls use, when this theme has one -- falls back to the
        // original flat near-black for a theme without a photo (a
        // built-in tiled theme, or My Photos before its first fetch).
        if let image = resolveThemeImage(imageName) {
            m.diffuse.contents = image
        } else {
            m.diffuse.contents = UIColor(white: 0.03, alpha: 1)
        }
        m.lightingModel = .physicallyBased
        m.metalness.contents = 0.0
        m.roughness.contents = 0.9
        // A faint warm ember glow, NOT scene lighting -- emission is a
        // per-surface property so it can never bleed onto the shutter or
        // anything outside the cubby the way an actual light did. Keeps
        // the passage's corners/walls faintly readable in the dark
        // instead of vanishing into flat black. Eddie, Sept 5: "like an
        // oven... dark and 3d." -- still true with a real photo here,
        // an unlit texture would just read as black anyway.
        m.emission.contents = UIColor(red: 0.05, green: 0.025, blue: 0.01, alpha: 1)
        return m
    }

    /// The elevator's own door material -- warm brushed brass instead
    /// of the destination shutter's bright chrome, so the two wall
    /// fixtures read as different things at a glance. Eddie, Sept 5:
    /// "make it look different (maybe diff color metal)."
    private static func makeElevatorDoorMaterial() -> SCNMaterial {
        // Eddie, Sept 8, from a run of slow-mo screenshots: stepping
        // into the shaft and turning to face these doors again "seems
        // to zoom in real tight and all i see is complete white."
        // Nothing was actually zooming -- see the headlamp's own
        // comment a few hundred lines down, on the exact same
        // point-blank-and-square-on blowout, from the SAME .omni light
        // riding on the camera. That fix shrank the LIGHT's spiking
        // component; this is the other half of the same fix, on the
        // MATERIAL side -- full metalness (1.0) turns this into a
        // near-mirror, and the 0.4-deep elevator shaft puts every
        // surface in it well inside the headlamp's unattenuated
        // "start distance," something no ordinary hallway wall (many
        // cells away) ever triggers. Dialed back so the doors still
        // read as metal without spiking to a blown-out highlight at
        // arm's length.
        // Eddie, Sept 8: "the pivot ends looking at the bigtime zoomed
        // in elev doors (where the white from the light takes up a
        // large part of the doors)." The camera's fixed dead-center
        // position (see playElevatorRide) puts it exactly 0.2 from
        // these doors for the whole dwell + pivot, same distance as
        // the back-wall photo -- close enough that even dimmed light
        // can still catch a metalness-0.55 surface's own specular
        // reflection dead-on. Metalness down to 0.2, roughness up to
        // 0.65 -- reads as painted metal with a little sheen instead
        // of a near-mirror, which is what actually stops it from
        // flaring regardless of exactly how bright the lights are.
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(red: 0.55, green: 0.42, blue: 0.22, alpha: 1)
        m.lightingModel = .physicallyBased
        m.metalness.contents = 0.2
        m.roughness.contents = 0.65
        return m
    }

    /// The dark interior behind the elevator doors -- same near-black,
    /// non-reflective idea as makeCubbyInteriorMaterial, but a cool
    /// blue-grey emissive tint instead of that one's warm ember, so a
    /// glimpse through open elevator doors never gets mistaken for a
    /// destination cubby.
    private static func makeElevatorShaftMaterial() -> SCNMaterial {
        // Eddie, Sept 8: "back wall... turns black for some reason."
        // This panel was always counting on getting hit near
        // point-blank by the FULL headlamp to read as dark charcoal
        // rather than black -- fine as long as the ride's dimming (see
        // playElevatorRide) only ever applied later, at a safe
        // distance. Now that the whole ride dims from the start, this
        // material needs enough of its own reflectance to still read
        // as a visible (if moody) dark surface under that dimmer
        // light, rather than depending on exactly when the scene
        // happens to dim relative to how close the camera is. 0.03 ->
        // 0.10 -- still reads as dark, matte, unremarkable metal
        // panel, not a lit one.
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(white: 0.10, alpha: 1)
        m.lightingModel = .physicallyBased
        m.metalness.contents = 0.0
        m.roughness.contents = 0.9
        m.emission.contents = UIColor(red: 0.01, green: 0.02, blue: 0.04, alpha: 1)
        return m
    }

    /// The "You Are Here" wall map -- Eddie's own idea, Sept 5: a
    /// mall-directory-style map of the whole floor with a marker
    /// showing where you are. Rendered once per floor with plain
    /// Core Graphics (the same top-down row/col layout GridEditorView
    /// draws for the dev map, just baked to a texture instead of an
    /// interactive SwiftUI grid) rather than anything 3D -- it's a
    /// picture on a wall, same idea as a real directory board.
    ///
    /// v1 marks only the one fixed elevator location (see
    /// MazeStore.elevatorCoordinate) -- no separate "here" dot at all
    /// anymore (Eddie, Sept 5: "get rid of the start position," right
    /// around the same conversation that made start and end the same
    /// cell in the first place, so there was never a second point left
    /// to mark). A live dot for wherever you're ACTUALLY standing,
    /// updating as you walk, is real additional plumbing -- this
    /// texture is baked once per floor-build, not re-rendered on every
    /// move -- saved for its own pass.
    static func makeFloorMapTexture(cells: Set<GridCoordinate>, end: GridCoordinate, maxRow: Int, maxCol: Int, playerAt: GridCoordinate, missionItemCells: [GridCoordinate] = [], missionDestinationCells: [GridCoordinate] = [], roomDoors: [GridCoordinate: RoomDoorPlacement] = [:], itemRooms: [GridCoordinate: Int] = [:]) -> UIImage {
        let cellPx: CGFloat = 48
        let margin: CGFloat = 16
        let width = CGFloat(maxCol + 1) * cellPx + margin * 2
        let height = CGFloat(maxRow + 1) * cellPx + margin * 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        // Eddie, Sept 5, on the FIRST version of this poster (which
        // drew the wall's own photo as its backdrop, same "reuse the
        // wall texture" idea the destination cubby's interior uses --
        // right for a shadowy recessed cubby, wrong for a paper map
        // you're meant to actually read): "you see the brick in the
        // map frame? that shouldnt be. that background could be a
        // very light gray or color to be determined." This flat tone
        // is a placeholder for whatever color he actually settles on.
        let backgroundColor = UIColor(white: 0.85, alpha: 1)
        let stoneColor = UIColor(red: 0.08, green: 0.06, blue: 0.03, alpha: 1)
        let floorColor = UIColor(red: 0.86, green: 0.74, blue: 0.46, alpha: 1)
        let elevatorColor = UIColor(white: 0.05, alpha: 1)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            backgroundColor.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))

            floorColor.setFill()
            for coord in cells {
                let rect = CGRect(x: margin + CGFloat(coord.col) * cellPx, y: margin + CGFloat(coord.row) * cellPx, width: cellPx, height: cellPx)
                cg.fill(rect)
            }

            // Thin grout between open cells so the corridor SHAPE reads
            // clearly rather than as one solid parchment blob.
            stoneColor.setStroke()
            cg.setLineWidth(1.5)
            for coord in cells {
                let rect = CGRect(x: margin + CGFloat(coord.col) * cellPx, y: margin + CGFloat(coord.row) * cellPx, width: cellPx, height: cellPx)
                cg.stroke(rect)
            }

            // The elevator -- a black circle, deliberately oversized
            // relative to a single cell (8% inset, not 15%) so it
            // still reads as a clear dot once this whole texture is
            // shrunk down to poster size on the wall. Used to be 2
            // dots -- a red "here" (start) plus this black one (end)
            // -- but start and end are always the exact same cell now
            // (Eddie, Sept 5's one-elevator-for-the-building change),
            // so a second dot drawn right on top of the first was just
            // clutter/confusion, not information. Eddie, Sept 5,
            // separately: "get rid of the start position."
            let elevatorRect = CGRect(x: margin + CGFloat(end.col) * cellPx, y: margin + CGFloat(end.row) * cellPx, width: cellPx, height: cellPx)
            elevatorColor.setFill()
            cg.fillEllipse(in: elevatorRect.insetBy(dx: cellPx * 0.08, dy: cellPx * 0.08))

            // Green dots for this floor's mission -- whatever's still
            // out there to find (missionItemCells, shrinks live as you
            // pick things up -- see TapNavigationController.
            // refreshFloorMapTexture()) and wherever it gets delivered
            // (missionDestinationCells, fixed). Same legend row these
            // match -- see makeMapLegendTexture below.
            let missionColor = UIColor(red: 0.15, green: 0.65, blue: 0.25, alpha: 1)
            missionColor.setFill()
            for coord in missionItemCells {
                let rect = CGRect(x: margin + CGFloat(coord.col) * cellPx, y: margin + CGFloat(coord.row) * cellPx, width: cellPx, height: cellPx)
                cg.fillEllipse(in: rect.insetBy(dx: cellPx * 0.08, dy: cellPx * 0.08))
            }

            UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1).setFill()
            for coord in missionDestinationCells {
                let rect = CGRect(x: margin + CGFloat(coord.col) * cellPx, y: margin + CGFloat(coord.row) * cellPx, width: cellPx, height: cellPx)
                cg.fillEllipse(in: rect.insetBy(dx: cellPx * 0.08, dy: cellPx * 0.08))
            }

            // A LIVE dot for wherever you actually are right now, as
            // opposed to the fixed elevator location above -- Eddie,
            // Sept 6: "the you-are-here wall maps show where the
            // elevator is (black dot) but dont show where you are... a
            // red dot... with you are here text would be nice." Drawn
            // AFTER the elevator dot so it wins when the two coincide
            // (standing right at the elevator) -- knowing "I'm here"
            // matters more in that moment than the elevator marker it's
            // covering, which you already know is there. This texture
            // itself is still just a static image, so a LIVE-looking
            // dot needs the caller to regenerate it and push a fresh
            // one in whenever the player's cell changes -- see
            // TapNavigationController.refreshFloorMapTexture(), the
            // "real additional plumbing" this comment used to say was
            // saved for later.
            let centerStyle = NSMutableParagraphStyle()
            centerStyle.alignment = .center
            for door in roomDoors.values {
                let rect = CGRect(x: margin + CGFloat(door.coord.col) * cellPx + 2, y: margin + CGFloat(door.coord.row) * cellPx + 2, width: cellPx - 4, height: cellPx - 4)
                UIColor(red: 0.4, green: 0.22, blue: 0.1, alpha: 1).setFill()
                cg.fill(rect)
                ("\(door.roomNumber)" as NSString).draw(in: rect.offsetBy(dx: 0, dy: 9), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.white, .paragraphStyle: centerStyle])
            }
            for coord in missionItemCells {
                guard let room = itemRooms[coord] else { continue }
                let rect = CGRect(x: margin + CGFloat(coord.col) * cellPx + 2, y: margin + CGFloat(coord.row) * cellPx + 10, width: cellPx - 4, height: 28)
                UIColor.white.setFill(); cg.fill(rect)
                ("\(room)" as NSString).draw(in: rect, withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.black, .paragraphStyle: centerStyle])
            }

            let playerColor = UIColor(red: 0.1, green: 0.35, blue: 0.95, alpha: 1)
            let playerRect = CGRect(x: margin + CGFloat(playerAt.col) * cellPx, y: margin + CGFloat(playerAt.row) * cellPx, width: cellPx, height: cellPx)
            playerColor.setFill()
            cg.fillEllipse(in: playerRect.insetBy(dx: cellPx * 0.08, dy: cellPx * 0.08))

            let labelFont = UIFont.boldSystemFont(ofSize: cellPx * 0.5)
            let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: playerColor]
            let label = "HERE" as NSString
            let labelSize = label.size(withAttributes: labelAttrs)
            // Above the dot by default, below it instead if that would
            // draw off the top edge (playerAt in row 0) -- and clamped
            // horizontally so a dot in the leftmost/rightmost column
            // doesn't push the label past the canvas edge either.
            let aboveY = playerRect.minY - labelSize.height - 2
            let labelY = aboveY >= 0 ? aboveY : playerRect.maxY + 2
            let labelX = min(max(playerRect.midX - labelSize.width / 2, 2), width - labelSize.width - 2)
            label.draw(at: CGPoint(x: labelX, y: labelY), withAttributes: labelAttrs)
        }
    }

    /// A small brass "● You Are Here" legend mounted just under each
    /// wall map's own frame -- Eddie, Sept 6: "under the map frame, put
    /// a plaque or something with the text 'You Are Here' followed by
    /// the red ball." The live red dot is already baked into the map
    /// picture itself (see makeFloorMapTexture above), but nothing on
    /// the wall previously explained what that dot meant at a glance --
    /// this is the same idea a real building directory uses, pairing
    /// its floor plan with a small fixed legend below it.
    private static func makeMapLegendTexture(hasMissionItem: Bool, missionItemLabel: String, hasMissionDestination: Bool) -> UIImage {
        struct LegendRow {
            let color: UIColor
            let text: String
        }
        let missionColor = UIColor(red: 0.15, green: 0.65, blue: 0.25, alpha: 1)
        var rows: [LegendRow] = [
            LegendRow(color: UIColor(red: 0.1, green: 0.35, blue: 0.95, alpha: 1), text: "You Are Here"),
            LegendRow(color: UIColor(white: 0.05, alpha: 1), text: "Elevator"),
        ]
        if hasMissionItem {
            rows.append(LegendRow(color: missionColor, text: missionItemLabel))
        }
        if hasMissionDestination {
            rows.append(LegendRow(color: missionItemLabel == "Mail" ? UIColor(red: 0.4, green: 0.22, blue: 0.1, alpha: 1) : UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1), text: missionItemLabel == "Mail" ? "Rooms" : "Chute"))
        }

        let rowHeight: CGFloat = 90
        let size = CGSize(width: 400, height: rowHeight * CGFloat(rows.count))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor(red: 0.75, green: 0.62, blue: 0.32, alpha: 1).setFill() // brass plate
            cg.fill(CGRect(origin: .zero, size: size))

            let dotRadius: CGFloat = 22
            let font = UIFont.boldSystemFont(ofSize: 40)
            let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(white: 0.12, alpha: 1)]
            for (index, row) in rows.enumerated() {
                let rowY = CGFloat(index) * rowHeight
                let dotRect = CGRect(x: 26, y: rowY + rowHeight / 2 - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                row.color.setFill()
                cg.fillEllipse(in: dotRect)

                let text = row.text as NSString
                let textSize = text.size(withAttributes: textAttrs)
                let textY = rowY + (rowHeight - textSize.height) / 2
                text.draw(at: CGPoint(x: dotRect.maxX + 16, y: textY), withAttributes: textAttrs)
            }
        }
    }

    /// The Floor Mission sign's own picture -- a big heading ("1st
    /// Floor") over a wrapped mission paragraph ("collect all the
    /// trash and put it in the trash chute"), typed in via
    /// GridEditorView's mission-editor sheet (Eddie, Sept 7: "you
    /// could put a button to pop open a text input field so you could
    /// type the paragraph in it"). One shared texture per floor,
    /// reused by every placed sign, same idea as makeFloorMapTexture
    /// -- but this one's static (baked once at build time, no
    /// per-frame refresh) since there's no live "you are here" dot to
    /// track here.
    static func makeMissionSignTexture(heading: String, body: String) -> UIImage {
        let width: CGFloat = 700
        let height: CGFloat = 625
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let backgroundColor = UIColor(white: 0.93, alpha: 1)
        let borderColor = UIColor(red: 0.3, green: 0.22, blue: 0.1, alpha: 1)
        let headingColor = UIColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        let bodyColor = UIColor(red: 0.25, green: 0.25, blue: 0.28, alpha: 1)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            backgroundColor.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))

            borderColor.setStroke()
            cg.setLineWidth(10)
            cg.stroke(CGRect(x: 5, y: 5, width: width - 10, height: height - 10))

            let margin: CGFloat = 40

            let headingFont = UIFont.boldSystemFont(ofSize: 80)
            let headingStyle = NSMutableParagraphStyle()
            headingStyle.alignment = .center
            headingStyle.lineBreakMode = .byWordWrapping
            let headingAttrs: [NSAttributedString.Key: Any] = [.font: headingFont, .foregroundColor: headingColor, .paragraphStyle: headingStyle]
            let headingRect = CGRect(x: margin, y: margin, width: width - margin * 2, height: 110)
            (heading as NSString).draw(in: headingRect, withAttributes: headingAttrs)

            let bodyFont = UIFont.systemFont(ofSize: 45, weight: .medium)
            let bodyStyle = NSMutableParagraphStyle()
            bodyStyle.lineBreakMode = .byWordWrapping
            let bodyAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: bodyColor, .paragraphStyle: bodyStyle]
            let bodyTop = margin + 135
            let bodyRect = CGRect(x: margin, y: bodyTop, width: width - margin * 2, height: height - bodyTop - margin)
            (body as NSString).draw(in: bodyRect, withAttributes: bodyAttrs)
        }
    }

    // MARK: - Objects (pick-up/deliver mechanic, first slice)

    /// SceneKit does not Y-flip a UIBezierPath's coordinates the way
    /// on-screen UIKit rendering does, so a path drawn with ordinary
    /// "point at the bottom" 2D heart-drawing conventions may come out
    /// point-up here instead — not something verifiable without seeing
    /// it render on device. This applies the 180-degree correction by
    /// default (best guess); flip this one constant if Eddie reports
    /// it's still upside down, nothing else about the shape changes.
    private static let heartRendersUpsideDown = true

    /// A flat heart outline — two round lobes plus a diamond whose top
    /// vertex tucks into the notch between them and whose bottom vertex
    /// forms the heart's single sharp point — in a size x size square,
    /// standard UIKit y-down convention (small y near the lobes/notch,
    /// large y at the sharp point).
    private static func heartPath(size: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let lobeRadius = size * 0.28
        let leftCenter = CGPoint(x: size * 0.32, y: size * 0.32)
        let rightCenter = CGPoint(x: size * 0.68, y: size * 0.32)
        path.append(UIBezierPath(ovalIn: CGRect(x: leftCenter.x - lobeRadius, y: leftCenter.y - lobeRadius, width: lobeRadius * 2, height: lobeRadius * 2)))
        path.append(UIBezierPath(ovalIn: CGRect(x: rightCenter.x - lobeRadius, y: rightCenter.y - lobeRadius, width: lobeRadius * 2, height: lobeRadius * 2)))

        let point = UIBezierPath()
        point.move(to: CGPoint(x: size * 0.5, y: size * 0.06))
        point.addLine(to: CGPoint(x: size * 0.94, y: size * 0.5))
        point.addLine(to: CGPoint(x: size * 0.5, y: size * 0.94))
        point.addLine(to: CGPoint(x: size * 0.06, y: size * 0.5))
        point.close()
        path.append(point)
        return path
    }

    /// Shared by every spinning pickup/fixture below (heart, star,
    /// every Font-Awesome icon, cash) instead of each one hand-rolling
    /// its own SCNAction -- Eddie, Sept 5: "if i can see 5 $100's
    /// spinning, theyre all perfectly in synch... maybe start a spin
    /// in a random orientation... or perhaps the speeds could be
    /// slightly diff." Does both: a random starting yaw so nothing
    /// launches face-first in lockstep, and a randomized duration
    /// (+/-15% of `baseDuration`) so even identical pickups drift out
    /// of phase over time rather than just starting offset and staying
    /// in sync forever.
    private static func addRandomSpin(to node: SCNNode, baseDuration: TimeInterval = 4) {
        node.eulerAngles.y += Float.random(in: 0..<(2 * .pi))
        let duration = baseDuration * Double.random(in: 0.85...1.15)
        let spin = SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: duration))
        node.runAction(spin)
    }

    /// A small rotating 3D heart — extruded from heartPath rather than
    /// hand-authored as a mesh, so any future shape is just a different
    /// 2D outline, not new modeling work. Eddie's ask specifically:
    /// spin it "on its point," like a top balanced on its tip — done by
    /// pivoting at the heart's own sharp-point vertex instead of its
    /// geometric center, so that point stays fixed in place (in the
    /// same spot the node is positioned at) while the continuous spin
    /// happens around a vertical line through it.
    private static func makeHeartNode(size: CGFloat) -> SCNNode {
        let path = heartPath(size: size)
        let extrusionDepth = size * 0.4
        let shape = SCNShape(path: path, extrusionDepth: extrusionDepth)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.85, green: 0.12, blue: 0.28, alpha: 1)
        material.emission.contents = UIColor(red: 0.45, green: 0.05, blue: 0.12, alpha: 1)
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0.25
        material.roughness.contents = 0.3
        shape.materials = [material]

        let node = SCNNode(geometry: shape)
        node.pivot = SCNMatrix4MakeTranslation(Float(size * 0.5), Float(size * 0.94), Float(extrusionDepth * 0.5))
        if heartRendersUpsideDown {
            node.eulerAngles.z = .pi
        }

        addRandomSpin(to: node)
        return node
    }

    /// Same best-guess-until-confirmed-on-device flag as
    /// heartRendersUpsideDown, extrapolated from that one confirmed
    /// result rather than independently verified — SCNShape's
    /// non-Y-flipping behavior should be a property of extrusion
    /// itself, not something specific to the heart's own path, so the
    /// same 180-degree correction is applied here too. Flip this one
    /// constant if Eddie reports the star renders upside down.
    private static let starRendersUpsideDown = true

    /// A 5-pointed star, computed exactly via trigonometry (not traced
    /// or eyeballed) rather than pulled from a downloaded icon file —
    /// fetching a real external SVG turned out to be blocked from this
    /// environment (see the parser's own file header for why), so this
    /// is the first real test of SVGPathParser using math instead, in
    /// the same style vector icon libraries export: a "d" attribute
    /// path string in a 0...100 box, outer points at radius 45,
    /// alternating with inner points at radius 45 * 0.382 (the classic
    /// golden-ratio-ish inset that keeps a 5-point star looking
    /// balanced rather than spiky or stubby).
    private static let starPathData = "M 50.0 5.0 L 60.1 36.09 L 92.8 36.09 L 66.35 55.31 L 76.45 86.41 L 50.0 67.19 L 23.55 86.41 L 33.65 55.31 L 7.2 36.09 L 39.9 36.09 Z"

    /// A small rotating 3D star — same extrusion approach as the
    /// heart, but built through SVGPathParser instead of a hand-typed
    /// UIBezierPath, and geometry kept at its native 0...100 size with
    /// the final scale-down applied to the node instead of baked into
    /// the path — proof the icon-import pipeline actually works before
    /// leaning on it for more shapes. Spins around its own center
    /// rather than "on a point" like the heart — a star has no single
    /// natural tip to balance on the way Eddie described the heart
    /// spinning like a top, so this uses the plain, simpler default.
    private static func makeStarNode(size: CGFloat) -> SCNNode {
        let nativeBox: CGFloat = 100
        let path = SVGPathParser.parse(starPathData)
        let extrusionDepth = nativeBox * 0.4
        let shape = SCNShape(path: path, extrusionDepth: extrusionDepth)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.95, green: 0.78, blue: 0.15, alpha: 1)
        material.emission.contents = UIColor(red: 0.5, green: 0.38, blue: 0.04, alpha: 1)
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0.35
        material.roughness.contents = 0.25
        shape.materials = [material]

        let node = SCNNode(geometry: shape)
        node.pivot = SCNMatrix4MakeTranslation(Float(nativeBox * 0.5), Float(nativeBox * 0.5), Float(extrusionDepth * 0.5))
        if starRendersUpsideDown {
            node.eulerAngles.z = .pi
        }
        node.scale = SCNVector3(Float(size / nativeBox), Float(size / nativeBox), Float(size / nativeBox))

        addRandomSpin(to: node)
        return node
    }

    /// Shared plumbing behind every Font-Awesome-sourced icon below,
    /// so adding a 7th one is just a path string, a native box size,
    /// and two colors -- not a new copy of this whole function. Same
    /// approach as makeStarNode: parse via SVGPathParser, extrude,
    /// pivot at the CENTER of the icon's own native bounding box
    /// (nativeWidth x nativeHeight, i.e. Font Awesome's own viewBox),
    /// and spin around that center rather than a special point like
    /// the heart's tip. `size` is the finished on-screen height; every
    /// icon here shares height=512 in its source viewBox (Font
    /// Awesome's convention regardless of an icon's own width), so
    /// scaling by size/nativeHeight uniformly on all three axes keeps
    /// every icon the same visual height while preserving its own
    /// natural aspect ratio -- e.g. person-biking, naturally wider
    /// than tall at 640x512, stays wider than tall on screen instead
    /// of getting squashed to a square.
    ///
    /// Reuses starRendersUpsideDown for the same 180-degree z
    /// correction: that flag is already documented as a property of
    /// SCNShape's extrusion itself, not something specific to the
    /// star's own path, so every icon built this way needs the same
    /// fix.
    private static func makeIconNode(pathData: String, nativeWidth: CGFloat, nativeHeight: CGFloat, size: CGFloat, diffuseColor: UIColor, emissionColor: UIColor) -> SCNNode {
        let path = SVGPathParser.parse(pathData)
        let extrusionDepth = nativeHeight * 0.4
        let shape = SCNShape(path: path, extrusionDepth: extrusionDepth)
        let material = SCNMaterial()
        material.diffuse.contents = diffuseColor
        material.emission.contents = emissionColor
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0.3
        material.roughness.contents = 0.28
        shape.materials = [material]

        let node = SCNNode(geometry: shape)
        node.pivot = SCNMatrix4MakeTranslation(Float(nativeWidth * 0.5), Float(nativeHeight * 0.5), Float(extrusionDepth * 0.5))
        if starRendersUpsideDown {
            node.eulerAngles.z = .pi
        }
        node.scale = SCNVector3(Float(size / nativeHeight), Float(size / nativeHeight), Float(size / nativeHeight))

        addRandomSpin(to: node)
        return node
    }

    // Path data for all 6 below is Font Awesome Free, Solid style,
    // pinned to version 6.7.2 and fetched by name (unpkg's per-icon
    // module, e.g. faIceCream.js) rather than as a raw .svg file --
    // .svg fetches are blocked outright in this environment regardless
    // of source. babyCarriage, snowman, and personBiking each lean on
    // A/a elliptical arcs (the reason SVGPathParser grew arc support),
    // and all three were cross-checked against a second independent
    // pinned-6.7.2 source (jsdelivr vs. unpkg) with a byte-for-byte
    // match before being typed in here.

    private static let iceCreamPathData = "M367.1 160c.6-5.3 .9-10.6 .9-16C368 64.5 303.5 0 224 0S80 64.5 80 144c0 5.4 .3 10.7 .9 16l-.9 0c-26.5 0-48 21.5-48 48s21.5 48 48 48l53.5 0 181 0 53.5 0c26.5 0 48-21.5 48-48s-21.5-48-48-48l-.9 0zM96 288L200.8 497.7c4.4 8.8 13.3 14.3 23.2 14.3s18.8-5.5 23.2-14.3L352 288 96 288z"

    private static let appleWholePathData = "M224 112c-8.8 0-16-7.2-16-16l0-16c0-44.2 35.8-80 80-80l16 0c8.8 0 16 7.2 16 16l0 16c0 44.2-35.8 80-80 80l-16 0zM0 288c0-76.3 35.7-160 112-160c27.3 0 59.7 10.3 82.7 19.3c18.8 7.3 39.9 7.3 58.7 0c22.9-8.9 55.4-19.3 82.7-19.3c76.3 0 112 83.7 112 160c0 128-80 224-160 224c-16.5 0-38.1-6.6-51.5-11.3c-8.1-2.8-16.9-2.8-25 0c-13.4 4.7-35 11.3-51.5 11.3C80 512 0 416 0 288z"

    private static let babyCarriagePathData = "M256 192L.1 192C2.7 117.9 41.3 52.9 99 14.1c13.3-8.9 30.8-4.3 39.9 8.8L256 192zm128-32c0-35.3 28.7-64 64-64l32 0c17.7 0 32 14.3 32 32s-14.3 32-32 32l-32 0 0 64c0 25.2-5.8 50.2-17 73.5s-27.8 44.5-48.6 62.3s-45.5 32-72.7 41.6S253.4 416 224 416s-58.5-5-85.7-14.6s-51.9-23.8-72.7-41.6s-37.3-39-48.6-62.3S0 249.2 0 224l224 0 160 0 0-64zM80 416a48 48 0 1 1 0 96 48 48 0 1 1 0-96zm240 48a48 48 0 1 1 96 0 48 48 0 1 1 -96 0z"

    private static let snowmanPathData = "M341.1 140.6c-2 3.9-1.6 8.6 1.2 12c7 8.5 12.9 18.1 17.2 28.4L408 160.2l0-40.2c0-13.3 10.7-24 24-24s24 10.7 24 24l0 19.6 22.5-9.7c12.2-5.2 26.3 .4 31.5 12.6s-.4 26.3-12.6 31.5l-56 24-73.6 31.5c-.5 9.5-2.1 18.6-4.8 27.3c-1.2 3.8-.1 8 2.8 10.8C396.7 296.9 416 338.2 416 384c0 44.7-18.3 85-47.8 114.1c-9.9 9.7-23.7 13.9-37.5 13.9l-149.3 0c-13.9 0-27.7-4.2-37.5-13.9C114.3 469 96 428.7 96 384c0-45.8 19.3-87.1 50.1-116.3c2.9-2.8 4-6.9 2.8-10.8c-2.7-8.7-4.3-17.9-4.8-27.3L70.5 198.1l-56-24C2.4 168.8-3.3 154.7 1.9 142.5s19.3-17.8 31.5-12.6L56 139.6 56 120c0-13.3 10.7-24 24-24s24 10.7 24 24l0 40.2L152.6 181c4.3-10.3 10.1-19.9 17.2-28.4c2.8-3.4 3.3-8.1 1.2-12C164 127.2 160 112.1 160 96c0-53 43-96 96-96s96 43 96 96c0 16.1-4 31.2-10.9 44.6zM224 96a16 16 0 1 0 0-32 16 16 0 1 0 0 32zm48 128a16 16 0 1 0 -32 0 16 16 0 1 0 32 0zm-16 80a16 16 0 1 0 0-32 16 16 0 1 0 0 32zm16 48a16 16 0 1 0 -32 0 16 16 0 1 0 32 0zM288 96a16 16 0 1 0 0-32 16 16 0 1 0 0 32zm-48 24l0 3.2c0 3.2 .8 6.3 2.3 9l9 16.9c.9 1.7 2.7 2.8 4.7 2.8s3.8-1.1 4.7-2.8l9-16.9c1.5-2.8 2.3-5.9 2.3-9l0-3.2c0-8.8-7.2-16-16-16s-16 7.2-16 16z"

    private static let personBikingPathData = "M400 96a48 48 0 1 0 0-96 48 48 0 1 0 0 96zm27.2 64l-61.8-48.8c-17.3-13.6-41.7-13.8-59.1-.3l-83.1 64.2c-30.7 23.8-28.5 70.8 4.3 91.6L288 305.1 288 416c0 17.7 14.3 32 32 32s32-14.3 32-32l0-128c0-10.7-5.3-20.7-14.2-26.6L295 232.9l60.3-48.5L396 217c5.7 4.5 12.7 7 20 7l64 0c17.7 0 32-14.3 32-32s-14.3-32-32-32l-52.8 0zM56 384a72 72 0 1 1 144 0A72 72 0 1 1 56 384zm200 0A128 128 0 1 0 0 384a128 128 0 1 0 256 0zm184 0a72 72 0 1 1 144 0 72 72 0 1 1 -144 0zm200 0a128 128 0 1 0 -256 0 128 128 0 1 0 256 0z"

    private static let cakeCandlesPathData = "M86.4 5.5L61.8 47.6C58 54.1 56 61.6 56 69.2L56 72c0 22.1 17.9 40 40 40s40-17.9 40-40l0-2.8c0-7.6-2-15-5.8-21.6L105.6 5.5C103.6 2.1 100 0 96 0s-7.6 2.1-9.6 5.5zm128 0L189.8 47.6c-3.8 6.5-5.8 14-5.8 21.6l0 2.8c0 22.1 17.9 40 40 40s40-17.9 40-40l0-2.8c0-7.6-2-15-5.8-21.6L233.6 5.5C231.6 2.1 228 0 224 0s-7.6 2.1-9.6 5.5zM317.8 47.6c-3.8 6.5-5.8 14-5.8 21.6l0 2.8c0 22.1 17.9 40 40 40s40-17.9 40-40l0-2.8c0-7.6-2-15-5.8-21.6L361.6 5.5C359.6 2.1 356 0 352 0s-7.6 2.1-9.6 5.5L317.8 47.6zM128 176c0-17.7-14.3-32-32-32s-32 14.3-32 32l0 48c-35.3 0-64 28.7-64 64l0 71c8.3 5.2 18.1 9 28.8 9c13.5 0 27.2-6.1 38.4-13.4c5.4-3.5 9.9-7.1 13-9.7c1.5-1.3 2.7-2.4 3.5-3.1c.4-.4 .7-.6 .8-.8l.1-.1s0 0 0 0s0 0 0 0s0 0 0 0s0 0 0 0c3.1-3.2 7.4-4.9 11.9-4.8s8.6 2.1 11.6 5.4c0 0 0 0 0 0s0 0 0 0l.1 .1c.1 .1 .4 .4 .7 .7c.7 .7 1.7 1.7 3.1 3c2.8 2.6 6.8 6.1 11.8 9.5c10.2 7.1 23 13.1 36.3 13.1s26.1-6 36.3-13.1c5-3.5 9-6.9 11.8-9.5c1.4-1.3 2.4-2.3 3.1-3c.3-.3 .6-.6 .7-.7l.1-.1c3-3.5 7.4-5.4 12-5.4s9 2 12 5.4l.1 .1c.1 .1 .4 .4 .7 .7c.7 .7 1.7 1.7 3.1 3c2.8 2.6 6.8 6.1 11.8 9.5c10.2 7.1 23 13.1 36.3 13.1s26.1-6 36.3-13.1c5-3.5 9-6.9 11.8-9.5c1.4-1.3 2.4-2.3 3.1-3c.3-.3 .6-.6 .7-.7l.1-.1c2.9-3.4 7.1-5.3 11.6-5.4s8.7 1.6 11.9 4.8c0 0 0 0 0 0s0 0 0 0s0 0 0 0l.1 .1c.2 .2 .4 .4 .8 .8c.8 .7 1.9 1.8 3.5 3.1c3.1 2.6 7.5 6.2 13 9.7c11.2 7.3 24.9 13.4 38.4 13.4c10.7 0 20.5-3.9 28.8-9l0-71c0-35.3-28.7-64-64-64l0-48c0-17.7-14.3-32-32-32s-32 14.3-32 32l0 48-64 0 0-48c0-17.7-14.3-32-32-32s-32 14.3-32 32l0 48-64 0 0-48zM448 394.6c-8.5 3.3-18.2 5.4-28.8 5.4c-22.5 0-42.4-9.9-55.8-18.6c-4.1-2.7-7.8-5.4-10.9-7.8c-2.8 2.4-6.1 5-9.8 7.5C329.8 390 310.6 400 288 400s-41.8-10-54.6-18.9c-3.5-2.4-6.7-4.9-9.4-7.2c-2.7 2.3-5.9 4.7-9.4 7.2C201.8 390 182.6 400 160 400s-41.8-10-54.6-18.9c-3.7-2.6-7-5.2-9.8-7.5c-3.1 2.4-6.8 5.1-10.9 7.8C71.2 390.1 51.3 400 28.8 400c-10.6 0-20.3-2.2-28.8-5.4L0 480c0 17.7 14.3 32 32 32l384 0c17.7 0 32-14.3 32-32l0-85.4z"

    private static func makeIceCreamNode(size: CGFloat) -> SCNNode {
        makeIconNode(pathData: iceCreamPathData, nativeWidth: 448, nativeHeight: 512, size: size,
                      diffuseColor: UIColor(red: 0.95, green: 0.75, blue: 0.85, alpha: 1),
                      emissionColor: UIColor(red: 0.5, green: 0.25, blue: 0.35, alpha: 1))
    }

    private static func makeAppleWholeNode(size: CGFloat) -> SCNNode {
        makeIconNode(pathData: appleWholePathData, nativeWidth: 448, nativeHeight: 512, size: size,
                      diffuseColor: UIColor(red: 0.8, green: 0.15, blue: 0.15, alpha: 1),
                      emissionColor: UIColor(red: 0.4, green: 0.05, blue: 0.05, alpha: 1))
    }

    private static func makeBabyCarriageNode(size: CGFloat) -> SCNNode {
        makeIconNode(pathData: babyCarriagePathData, nativeWidth: 512, nativeHeight: 512, size: size,
                      diffuseColor: UIColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 1),
                      emissionColor: UIColor(red: 0.15, green: 0.25, blue: 0.45, alpha: 1))
    }

    private static func makeSnowmanNode(size: CGFloat) -> SCNNode {
        makeIconNode(pathData: snowmanPathData, nativeWidth: 512, nativeHeight: 512, size: size,
                      diffuseColor: UIColor(red: 0.9, green: 0.92, blue: 0.95, alpha: 1),
                      emissionColor: UIColor(red: 0.35, green: 0.37, blue: 0.4, alpha: 1))
    }

    private static func makePersonBikingNode(size: CGFloat) -> SCNNode {
        makeIconNode(pathData: personBikingPathData, nativeWidth: 640, nativeHeight: 512, size: size,
                      diffuseColor: UIColor(red: 0.15, green: 0.65, blue: 0.55, alpha: 1),
                      emissionColor: UIColor(red: 0.05, green: 0.3, blue: 0.25, alpha: 1))
    }

    private static func makeCakeCandlesNode(size: CGFloat) -> SCNNode {
        makeIconNode(pathData: cakeCandlesPathData, nativeWidth: 448, nativeHeight: 512, size: size,
                      diffuseColor: UIColor(red: 0.9, green: 0.55, blue: 0.15, alpha: 1),
                      emissionColor: UIColor(red: 0.45, green: 0.25, blue: 0.05, alpha: 1))
    }

    private static let trashCanPathData = "M135.2 17.7C140.6 6.8 151.7 0 163.8 0L284.2 0c12.1 0 23.2 6.8 28.6 17.7L320 32l96 0c17.7 0 32 14.3 32 32s-14.3 32-32 32L32 96C14.3 96 0 81.7 0 64S14.3 32 32 32l96 0 7.2-14.3zM32 128l384 0 0 320c0 35.3-28.7 64-64 64L96 512c-35.3 0-64-28.7-64-64l0-320zm96 64c-8.8 0-16 7.2-16 16l0 224c0 8.8 7.2 16 16 16s16-7.2 16-16l0-224c0-8.8-7.2-16-16-16zm96 0c-8.8 0-16 7.2-16 16l0 224c0 8.8 7.2 16 16 16s16-7.2 16-16l0-224c0-8.8-7.2-16-16-16zm96 0c-8.8 0-16 7.2-16 16l0 224c0 8.8 7.2 16 16 16s16-7.2 16-16l0-224c0-8.8-7.2-16-16-16z"
    private static let envelopePathData = "M48 64C21.5 64 0 85.5 0 112c0 15.1 7.1 29.3 19.2 38.4L236.8 313.6c11.4 8.5 27 8.5 38.4 0L492.8 150.4c12.1-9.1 19.2-23.3 19.2-38.4c0-26.5-21.5-48-48-48L48 64zM0 176L0 384c0 35.3 28.7 64 64 64l384 0c35.3 0 64-28.7 64-64l0-208L294.4 339.2c-22.8 17.1-54 17.1-76.8 0L0 176z"

    private static func makeTrashCanNode(size: CGFloat) -> SCNNode {
        makeIconNode(pathData: trashCanPathData, nativeWidth: 448, nativeHeight: 512, size: size,
                      diffuseColor: UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1),
                      emissionColor: UIColor(red: 0.4, green: 0.4, blue: 0.42, alpha: 1))
    }

    private static func makeEnvelopeNode(size: CGFloat) -> SCNNode {
        makeIconNode(pathData: envelopePathData, nativeWidth: 512, nativeHeight: 512, size: size,
                      diffuseColor: UIColor(red: 0.94, green: 0.9, blue: 0.78, alpha: 1),
                      emissionColor: UIColor(red: 0.42, green: 0.38, blue: 0.26, alpha: 1))
    }

    private static func makeCash100Node(size: CGFloat) -> SCNNode {
        makeCashNode(value: 100, size: size)
    }


    /// Shared builder for every cash denomination — real extruded 3D
    /// text ("$100" etc.) via SceneKit's own SCNText, rather than the
    /// Font-Awesome-SVG pipeline every other object uses: there's no
    /// icon glyph for an arbitrary dollar amount, but SCNText does
    /// exactly this natively, no path data to source or verify at all.
    /// Eddie, Sept 5: "can we easily do letter svgs? so we could do
    /// $100 and things like that" -- yes, just not via SVG.
    ///
    /// Gold rather than the trash can's white or any of the other
    /// icons' pastels, both because it's the obvious "cash" color and
    /// because Eddie already flagged that green reads poorly against
    /// this game's gray walls/boxes — gold is a different enough value
    /// from that gray to actually pop, and won't be confused for the
    /// now-white trash can at a glance.
    ///
    /// Sizing mirrors makeIconNode's own approach: build at whatever
    /// scale SCNText naturally renders the string, measure its own
    /// bounding box, then scale uniformly so the text's actual height
    /// (not the font's point size, which isn't the same thing once
    /// bevels/descenders are involved) matches `size` exactly, same as
    /// every other spinning pickup.
    private static func makeCashNode(value: Int, size: CGFloat) -> SCNNode {
        let text = SCNText(string: "$\(value)", extrusionDepth: 8)
        text.font = UIFont.boldSystemFont(ofSize: 60)
        text.flatness = 0.2
        text.chamferRadius = 1.5

        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 1.0, green: 0.78, blue: 0.15, alpha: 1)
        material.emission.contents = UIColor(red: 0.5, green: 0.36, blue: 0.04, alpha: 1)
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0.5
        material.roughness.contents = 0.25
        text.materials = [material]

        let node = SCNNode(geometry: text)
        let (minBound, maxBound) = text.boundingBox
        let width = maxBound.x - minBound.x
        let height = maxBound.y - minBound.y
        let depth = maxBound.z - minBound.z
        node.pivot = SCNMatrix4MakeTranslation(minBound.x + width / 2, minBound.y + height / 2, minBound.z + depth / 2)
        let scale = height > 0 ? Float(size) / height : 1
        node.scale = SCNVector3(scale, scale, scale)

        addRandomSpin(to: node)
        return node
    }

    /// A non-interactive hallway fixture (never in the ObjectKind/
    /// objects dictionary at all -- see the placement site in build(),
    /// a separate pass right after the main per-cell loop) built
    /// wherever GridEditorView's exitSigns dictionary says one goes,
    /// pointing whichever way that dictionary says -- manually placed
    /// now (Eddie, Sept 5, round 5), not auto-computed from maze
    /// topology.
    ///
    /// v1 of this (Sept 5) was "EXIT" billboarded to the camera plus a
    /// separate SCNCone rotated to aim at `direction` -- on-device that
    /// cone read as a huge red ball head-on and an odd traffic-cone
    /// shape from the side, blotting out the text ("looking great" this
    /// was not). Eddie's own fix, same night: fold the arrow into the
    /// text itself as a plain character -- "< EXIT" / "EXIT >" / "EXIT
    /// ^" -- rather than a separate 3D shape at all. One SCNText now,
    /// no second node, using compass-style glyphs (^ north, v south, >
    /// east, < west) rather than true screen-relative left/right/
    /// straight, since those already match the "north is up" convention
    /// the new You Are Here wall map teaches -- both wayfinding
    /// features read off the same compass, not two different ones.
    ///
    /// Bright emissive red, self-illuminating for the same reason every
    /// other pickup is (no dependence on scene lights reaching a nested
    /// child via categoryBitMask) -- and red specifically because it's
    /// the one color in this game not already claimed by trash (white),
    /// cash (gold), or the doorway/amber "notice this" markers, so an
    /// Exit Sign reads as its own distinct category at a glance.
    // Dim (the DEFAULT look, from any distance) vs. neon (only the ONE
    // sign at the player's actual current cell, toggled live by
    // TapNavigationController) -- shared here as plain internal
    // constants, not private, specifically so TapNavigationController
    // can read and re-apply them without this file needing to know
    // anything about player position itself. See the doc comment on
    // makeExitSignNode below for why this split exists at all.
    static let exitSignDimDiffuse = UIColor(red: 0.7, green: 0.05, blue: 0.04, alpha: 1)
    static let exitSignDimEmission = UIColor(red: 0.26, green: 0.02, blue: 0.01, alpha: 1)
    static let exitSignNeonDiffuse = UIColor(red: 0.95, green: 0.08, blue: 0.05, alpha: 1)
    static let exitSignNeonEmission = UIColor(red: 0.85, green: 0.12, blue: 0.05, alpha: 1)
    static let exitSignNeonScaleMultiplier: Float = 1.1
    static let exitSignBaseSizeFactor: CGFloat = 0.05

    /// A non-interactive hallway fixture, hidden by default --
    /// TapNavigationController shows the ONE sign at the player's
    /// actual current cell (see exitSignNodes/updateExitSignHighlight
    /// there) and hides everything else, so build() never needs to
    /// worry about distance-based dimming here at all anymore.
    ///
    /// The `label` built here is only ever a placeholder -- it's never
    /// actually seen, since the node starts hidden and stays that way
    /// until TapNavigationController shows it, which is also exactly
    /// when it OVERWRITES this string with one computed relative to
    /// the player's CURRENT FACING (Eddie, Sept 5, round 9: a sign
    /// whose compass direction is west needs to say "turn right" to a
    /// player facing south, "turn left" to one facing north -- there's
    /// no single fixed glyph that's correct for every possible
    /// arrival, so build() has no business picking one). See
    /// TapNavigationController.relativeExitLabel(pointing:facing:).
    /// A single flat triangle lying in the floor plane, tip pointing
    /// out along `direction` -- used to cap each arm of
    /// addIntersectionMarker with a proper arrowhead instead of
    /// approximating one out of rotated boxes. Custom SCNGeometry
    /// (rather than a primitive like SCNPyramid, whose base is a
    /// rectangle, not a triangle) is what actually gets a flat,
    /// 3-vertex wedge that reads as an arrowhead from directly above,
    /// matching Eddie's reference sketch.
    private static func makeArrowheadGeometry(direction: Direction, baseWidth: CGFloat, length: CGFloat, material: SCNMaterial) -> SCNGeometry {
        let hw = Float(baseWidth / 2)
        let len = Float(length)
        let vertices: [SCNVector3]
        switch direction {
        case .north: vertices = [SCNVector3(-hw, 0, 0), SCNVector3(hw, 0, 0), SCNVector3(0, 0, -len)]
        case .south: vertices = [SCNVector3(-hw, 0, 0), SCNVector3(hw, 0, 0), SCNVector3(0, 0, len)]
        case .east: vertices = [SCNVector3(0, 0, -hw), SCNVector3(0, 0, hw), SCNVector3(len, 0, 0)]
        case .west: vertices = [SCNVector3(0, 0, -hw), SCNVector3(0, 0, hw), SCNVector3(-len, 0, 0)]
        }
        let source = SCNGeometrySource(vertices: vertices)
        // Both winding orders, so the triangle renders whichever side
        // of it the camera happens to be on -- it's a paper-thin floor
        // decal, not a solid, so there's no "back face" that should
        // stay hidden.
        let indices: [Int32] = [0, 1, 2, 0, 2, 1]
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [material]
        return geometry
    }

    private static func makeExitSignNode(pointing direction: Direction, cellSize: CGFloat) -> SCNNode {
        let anchor = SCNNode()

        let label: String
        switch direction {
        case .north, .south: label = "EXIT ^"
        case .east: label = "EXIT >"
        case .west: label = "< EXIT"
        }

        let text = SCNText(string: label, extrusionDepth: 4)
        text.font = UIFont.boldSystemFont(ofSize: 44)
        text.flatness = 0.2
        let textMaterial = SCNMaterial()
        textMaterial.diffuse.contents = exitSignDimDiffuse
        textMaterial.emission.contents = exitSignDimEmission
        textMaterial.lightingModel = .physicallyBased
        textMaterial.metalness.contents = 0.05
        textMaterial.roughness.contents = 0.6
        text.materials = [textMaterial]

        let textNode = SCNNode(geometry: text)
        let (minBound, maxBound) = text.boundingBox
        let textWidth = maxBound.x - minBound.x
        let textHeight = maxBound.y - minBound.y
        textNode.pivot = SCNMatrix4MakeTranslation(minBound.x + textWidth / 2, minBound.y + textHeight / 2, 0)
        let textScale = textHeight > 0 ? Float(cellSize * exitSignBaseSizeFactor) / textHeight : 1
        textNode.scale = SCNVector3(textScale, textScale, textScale)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        textNode.constraints = [billboard]
        anchor.addChildNode(textNode)

        return anchor
    }

    /// Small etched-looking label -- "TRASH" or "MAIL" -- on the
    /// chute's steel shutter, so it reads as what it is at a glance
    /// the same way "$100" and a neon EXIT sign already do without any
    /// legend. Eddie, Sept 5: "the trash is a bit tricky. we need to
    /// put a sign on the chutes that says trash in small letters...
    /// maybe metal etch into metal door." Sept 7 added a second
    /// destination kind (the Mail Mission's chute), so this now reads
    /// straight off ObjectKind.missionLegendLabel per chute instead of
    /// a hardcoded string.
    ///
    /// Billboarded (same trick makeExitSignNode uses just above) so it
    /// always faces the player dead-on -- sidesteps working out which
    /// of the 4 door rotations would read mirrored/backward if this
    /// were instead baked flat into the door's own rotated local frame.
    private static func makeDestinationLabelNode(kind: ObjectKind, doorHeight: CGFloat, doorThickness: CGFloat) -> SCNNode {
        let text = SCNText(string: kind.missionLegendLabel.uppercased(), extrusionDepth: 1)
        text.font = UIFont.boldSystemFont(ofSize: 32)
        text.flatness = 0.1

        let material = SCNMaterial()
        // Dark graphite against the shutter's own bright polished
        // silver (see makeDestinationDoorMaterial) -- reads as
        // engraved rather than another shiny highlight competing with
        // it for attention.
        material.diffuse.contents = UIColor(white: 0.22, alpha: 1)
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0.6
        material.roughness.contents = 0.8
        text.materials = [material]

        let textNode = SCNNode(geometry: text)
        let (minBound, maxBound) = text.boundingBox
        let textWidth = maxBound.x - minBound.x
        let textHeight = maxBound.y - minBound.y
        textNode.pivot = SCNMatrix4MakeTranslation(minBound.x + textWidth / 2, minBound.y + textHeight / 2, 0)
        // "in small letters" -- Eddie, Sept 5 -- a fraction of the
        // door's own height, nowhere near the full-height treatment
        // $100/EXIT get.
        let targetHeight = doorHeight * 0.16
        let textScale = textHeight > 0 ? Float(targetHeight) / textHeight : 1
        textNode.scale = SCNVector3(textScale, textScale, textScale)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        textNode.constraints = [billboard]

        let anchor = SCNNode()
        anchor.position = SCNVector3(0, 0, -Float(doorThickness / 2) - 0.02)
        anchor.addChildNode(textNode)
        return anchor
    }

    private static func makeMarkerMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(red: 1.0, green: 0.72, blue: 0.2, alpha: 1)
        m.emission.contents = UIColor(red: 0.5, green: 0.32, blue: 0.05, alpha: 1)
        m.lightingModel = .physicallyBased
        return m
    }
}
