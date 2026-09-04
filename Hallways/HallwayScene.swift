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
    static func build(fromMaze cells: Set<GridCoordinate>, cellSize: CGFloat, wallHeight: CGFloat, objects: [GridCoordinate: ObjectKind] = [:], theme: HallwayTheme = .brick) -> (scene: SCNScene, cameraNode: SCNNode, walkableRects: [FloorRect], wallMaterials: [SCNMaterial], floorMaterial: SCNMaterial, ceilingMaterial: SCNMaterial, deadEndCapMaterials: [SCNMaterial]) {
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
        // Same per-node idea for dead-end caps — one fresh material per
        // true dead end, so a maze with several dead ends shows a
        // different photo at each one under My Photos rather than the
        // same picture everywhere.
        var deadEndCapMaterials: [SCNMaterial] = []

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

        // Thin, neutral "grout line" so the cell-by-cell structure still
        // reads even though every room is now the same color — same idea
        // as the black grid lines in the 2D editor.
        let gridLineMaterial = SCNMaterial()
        gridLineMaterial.diffuse.contents = UIColor(white: 0.05, alpha: 1)
        gridLineMaterial.lightingModel = .constant

        // Builds one boundary marker (red header bar + floor/ceiling
        // threshold lines) centered at (x, z). wideAlongX true = a
        // north/south-facing boundary (the bar runs along X); false = an
        // east/west-facing boundary (the bar runs along Z).
        func addDoorwayMarker(atX x: CGFloat, z: CGFloat, wideAlongX: Bool) {
            let header = wideAlongX
                ? SCNBox(width: cellSize * 0.9, height: 0.22, length: 0.14, chamferRadius: 0.03)
                : SCNBox(width: 0.14, height: 0.22, length: cellSize * 0.9, chamferRadius: 0.03)
            header.materials = [doorwayMaterial]
            let headerNode = SCNNode(geometry: header)
            headerNode.position = SCNVector3(Float(x), Float(wallHeight - 0.15), Float(z))
            root.addChildNode(headerNode)

            let floorLine = wideAlongX
                ? SCNBox(width: cellSize, height: 0.02, length: 0.08, chamferRadius: 0)
                : SCNBox(width: 0.08, height: 0.02, length: cellSize, chamferRadius: 0)
            floorLine.materials = [gridLineMaterial]
            let floorLineNode = SCNNode(geometry: floorLine)
            floorLineNode.position = SCNVector3(Float(x), 0.011, Float(z))
            root.addChildNode(floorLineNode)

            let ceilingLine = wideAlongX
                ? SCNBox(width: cellSize, height: 0.02, length: 0.08, chamferRadius: 0)
                : SCNBox(width: 0.08, height: 0.02, length: cellSize, chamferRadius: 0)
            ceilingLine.materials = [gridLineMaterial]
            let ceilingLineNode = SCNNode(geometry: ceilingLine)
            ceilingLineNode.position = SCNVector3(Float(x), Float(wallHeight) - 0.011, Float(z))
            root.addChildNode(ceilingLineNode)
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

            let hasWallNorth = !isOpen(coord.row - 1, coord.col)
            let hasWallSouth = !isOpen(coord.row + 1, coord.col)
            let hasWallEast = !isOpen(coord.row, coord.col + 1)
            let hasWallWest = !isOpen(coord.row, coord.col - 1)

            // A true dead end has exactly one open side — the way you
            // came in, and the only way back out. The wall directly
            // opposite that opening is the one you end up staring at,
            // so that's the one that gets the full-picture treatment.
            let openDirs: [Direction] = [
                !hasWallNorth ? .north : nil,
                !hasWallSouth ? .south : nil,
                !hasWallEast ? .east : nil,
                !hasWallWest ? .west : nil,
            ].compactMap { $0 }
            let capSide: Direction? = openDirs.count == 1 ? openDirs[0].opposite : nil

            // One fresh material per wall segment (see the comment
            // above wallMaterials) — either a dead-end cap or a regular
            // wall material, added to its matching array so the live
            // theme swap in ContentView's Coordinator can reach it.
            func addWall(width: CGFloat, length: CGFloat, x: CGFloat, z: CGFloat, isCap: Bool) {
                let geo = SCNBox(width: width, height: wallHeight, length: length, chamferRadius: 0)
                if isCap {
                    let material = makeDeadEndCapMaterial(imageName: theme.wallImageName)
                    geo.materials = [material]
                    deadEndCapMaterials.append(material)
                } else {
                    let material = makeWallMaterial(imageName: theme.wallImageName)
                    geo.materials = [material]
                    wallMaterials.append(material)
                }
                let node = SCNNode(geometry: geo)
                node.position = SCNVector3(Float(x), Float(wallHeight / 2), Float(z))
                root.addChildNode(node)
            }

            if hasWallNorth {
                addWall(width: cellSize, length: 0.1, x: x, z: z - half, isCap: capSide == .north)
            }
            if hasWallSouth {
                addWall(width: cellSize, length: 0.1, x: x, z: z + half, isCap: capSide == .south)
            }
            if hasWallEast {
                addWall(width: 0.1, length: cellSize, x: x + half, z: z, isCap: capSide == .east)
            }
            if hasWallWest {
                addWall(width: 0.1, length: cellSize, x: x - half, z: z, isCap: capSide == .west)
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
                if !hasWallNorth { addDoorwayMarker(atX: x, z: z - half, wideAlongX: true) }
                if !hasWallSouth { addDoorwayMarker(atX: x, z: z + half, wideAlongX: true) }
                if !hasWallEast { addDoorwayMarker(atX: x + half, z: z, wideAlongX: false) }
                if !hasWallWest { addDoorwayMarker(atX: x - half, z: z, wideAlongX: false) }
            }

            // First slice of the pick-up/deliver mechanic — this pass
            // only places what it LOOKS like, a spinning heart or star
            // marking a cell with something in it, so it can be seen and
            // judged before any carrying/delivering logic gets built on
            // top.
            if let kind = objects[coord] {
                let node: SCNNode
                switch kind {
                case .heart:
                    node = makeHeartNode(size: cellSize * 0.22)
                case .star:
                    node = makeStarNode(size: cellSize * 0.22)
                }
                node.position = SCNVector3(Float(x), Float(wallHeight * 0.25), Float(z))
                root.addChildNode(node)
            }

            let xLower = x - half + (hasWallWest ? margin : 0)
            let xUpper = x + half - (hasWallEast ? margin : 0)
            let zLower = z - half + (hasWallNorth ? margin : 0)
            let zUpper = z + half - (hasWallSouth ? margin : 0)
            walkableRects.append(FloorRect(xRange: xLower...xUpper, zRange: zLower...zUpper))
        }

        // Spawn at the top-left-most open cell (lowest row, then lowest
        // col), facing the first open neighbor going south/east/north/west
        // — so you start already looking down a hallway, not into a wall.
        let start = cells.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }).first ?? GridCoordinate(row: 0, col: 0)
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

        // End marker — the same bottom-right-most cell GridEditorView
        // labels "E". A glowing, self-lit ball, unaffected by scene
        // lighting, so it always reads clearly.
        let end = cells.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }).last ?? start
        if end != start {
            let markerGeo = SCNSphere(radius: 0.35)
            let markerMat = SCNMaterial()
            markerMat.diffuse.contents = UIColor.white
            markerMat.emission.contents = UIColor.white
            markerMat.lightingModel = .constant
            markerGeo.materials = [markerMat]
            let markerNode = SCNNode(geometry: markerGeo)
            markerNode.position = SCNVector3(Float(worldX(end.col)), Float(wallHeight) * 0.5, Float(worldZ(end.row)))
            root.addChildNode(markerNode)
        }

        return (scene, cameraNode, walkableRects, wallMaterials, floorMaterial, ceilingMaterial, deadEndCapMaterials)
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

    /// Shared by walls/floor/ceiling: an optional real photo, tiled, or a
    /// flat fallback color if there's no image name, or the named file
    /// isn't in the bundle for some reason (so a missing asset never
    /// turns into a blank surface). The returned material is kept by the
    /// caller (ContentView's Coordinator) so the theme button can swap
    /// `.diffuse.contents` on it directly later without rebuilding the
    /// whole scene.
    private static func makeSurfaceMaterial(imageName: String?, fallbackColor: UIColor, roughness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        if let imageName,
           let path = Bundle.main.path(forResource: imageName, ofType: "jpg"),
           let image = UIImage(contentsOfFile: path) {
            m.diffuse.contents = image
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(2, 2, 1)
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
    private static func makeDeadEndCapMaterial(imageName: String?) -> SCNMaterial {
        let m = SCNMaterial()
        if let imageName,
           let path = Bundle.main.path(forResource: imageName, ofType: "jpg"),
           let image = UIImage(contentsOfFile: path) {
            m.diffuse.contents = image
            m.diffuse.wrapS = .clamp
            m.diffuse.wrapT = .clamp
            m.diffuse.contentsTransform = SCNMatrix4Identity
        } else {
            m.diffuse.contents = wallFallbackColor
        }
        m.lightingModel = .constant
        return m
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

        let spin = SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 4))
        node.runAction(spin)
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

        let spin = SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 4))
        node.runAction(spin)
        return node
    }

    private static func makeMarkerMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(red: 1.0, green: 0.72, blue: 0.2, alpha: 1)
        m.emission.contents = UIColor(red: 0.5, green: 0.32, blue: 0.05, alpha: 1)
        m.lightingModel = .physicallyBased
        return m
    }
}
