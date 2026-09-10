# -*- coding: utf-8 -*-
import sys

path = "HallwayScene.swift"
with open(path, "r", encoding="utf-8") as f:
    text = f.read()

edits = []

# 1. BFS distance-to-end field, computed once right after end is known
# -- Exit Signs (below) look up "which open neighbor gets me closer"
# with a plain dictionary read per intersection rather than re-walking
# the maze from every fork.
old = '''        let start = cells.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }).first ?? GridCoordinate(row: 0, col: 0)
        let end = cells.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }).last ?? start'''
new = '''        let start = cells.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }).first ?? GridCoordinate(row: 0, col: 0)
        let end = cells.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }).last ?? start

        // Exit Sign wayfinding (Eddie, Sept 5): a breadth-first distance
        // field over the open-cell graph, rooted at `end` -- the same
        // Direction-delta neighbor stepping walkToNextDecision uses in
        // MazeNavigation.swift, just outward from every cell at once
        // instead of forward along a single walked path. Computed once,
        // up front, so the per-cell loop below can answer "which open
        // direction actually gets closer to the elevator" with one
        // dictionary read per fork instead of a fresh search each time.
        var distanceToEnd: [GridCoordinate: Int] = [end: 0]
        var distanceFrontier = [end]
        while !distanceFrontier.isEmpty {
            var nextFrontier: [GridCoordinate] = []
            for coord in distanceFrontier {
                let d = distanceToEnd[coord]!
                for dir in Direction.allCases {
                    let neighbor = GridCoordinate(row: coord.row + dir.delta.row, col: coord.col + dir.delta.col)
                    if cells.contains(neighbor), distanceToEnd[neighbor] == nil {
                        distanceToEnd[neighbor] = d + 1
                        nextFrontier.append(neighbor)
                    }
                }
            }
            distanceFrontier = nextFrontier
        }'''
edits.append((old, new))

# 2. Place an Exit Sign at every true intersection, right after the
# doorway-marker block that already defines "true intersection" for
# this file (openSides >= 3) -- reusing that exact definition rather
# than inventing a second notion of "decision point."
old = '''            let openSides = [!hasWallNorth, !hasWallSouth, !hasWallEast, !hasWallWest].filter { $0 }.count
            if openSides >= 3 {
                if !hasWallNorth { addDoorwayMarker(atX: x, z: z - half, wideAlongX: true) }
                if !hasWallSouth { addDoorwayMarker(atX: x, z: z + half, wideAlongX: true) }
                if !hasWallEast { addDoorwayMarker(atX: x + half, z: z, wideAlongX: false) }
                if !hasWallWest { addDoorwayMarker(atX: x - half, z: z, wideAlongX: false) }
            }'''
new = '''            let openSides = [!hasWallNorth, !hasWallSouth, !hasWallEast, !hasWallWest].filter { $0 }.count
            if openSides >= 3 {
                if !hasWallNorth { addDoorwayMarker(atX: x, z: z - half, wideAlongX: true) }
                if !hasWallSouth { addDoorwayMarker(atX: x, z: z + half, wideAlongX: true) }
                if !hasWallEast { addDoorwayMarker(atX: x + half, z: z, wideAlongX: false) }
                if !hasWallWest { addDoorwayMarker(atX: x - half, z: z, wideAlongX: false) }
            }

            // Exit Signs -- Eddie's own idea, Sept 5: "hallway objects,
            // mounted higher than normal objects" that auto-point
            // toward the elevator, with no manual placement in
            // GridEditorView at all (same "auto-computed from topology"
            // spirit as the elevator itself -- nobody hand-picks a cell
            // for that either, it's just whichever cell is `end`).
            // Reuses this exact same "true intersection" test the
            // doorway markers just above use, since that's already this
            // file's established idea of an actual decision point -- a
            // plain pass-through or a 2-way turn auto-advances under tap
            // navigation and never needs a sign, only a fork where
            // you're genuinely choosing. `openDirs` (computed earlier in
            // this loop, for the dead-end cap) is exactly this cell's
            // list of open directions, so it's reused rather than
            // recomputed here.
            if openSides >= 3, coord != end {
                let towardEnd = openDirs.min(by: { a, b in
                    let na = GridCoordinate(row: coord.row + a.delta.row, col: coord.col + a.delta.col)
                    let nb = GridCoordinate(row: coord.row + b.delta.row, col: coord.col + b.delta.col)
                    return (distanceToEnd[na] ?? Int.max) < (distanceToEnd[nb] ?? Int.max)
                })
                if let towardEnd {
                    let sign = makeExitSignNode(pointing: towardEnd, cellSize: cellSize)
                    sign.position = SCNVector3(Float(x), Float(wallHeight * 0.72), Float(z))
                    root.addChildNode(sign)
                }
            }'''
edits.append((old, new))

# 3. makeExitSignNode, right after makeCashNode (the other SCNText-based
# builder, so the two "text authored directly in Swift, no SVG/icon
# pipeline" builders sit next to each other).
old = '''    private static func makeMarkerMaterial() -> SCNMaterial {'''
new = '''        let spin = SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 4))
        node.runAction(spin)
        return node
    }

    /// A non-interactive hallway fixture (never in the ObjectKind/
    /// objects dictionary at all -- see the placement site in build(),
    /// right after the doorway markers) auto-built at every true
    /// intersection to point toward whichever open direction actually
    /// gets closer to the elevator, per the distanceToEnd BFS field
    /// computed once at the top of build().
    ///
    /// Two independent pieces, not one rotated node:
    ///  - "EXIT" billboards to the camera (Y-axis only, so it stays
    ///    upright) because its job is to stay LEGIBLE from whichever of
    ///    the fork's branches you approached from -- unlike the arrow,
    ///    it never rotates to match `direction`.
    ///  - The arrow is a single SCNCone lying on its side (its apex is
    ///    the point) aimed at `direction` via Direction.yaw -- the same
    ///    "north yaw = 0, forward = (-sin(yaw), -cos(yaw))" convention
    ///    MovementController/startingFacing already use, so an Exit
    ///    Sign and the camera itself always agree on which way "north"
    ///    visually is.
    ///
    /// Bright emissive red, self-illuminating for the same reason every
    /// other pickup is (no dependence on scene lights reaching a nested
    /// child via categoryBitMask) -- and red specifically because it's
    /// the one color in this game not already claimed by trash (white),
    /// cash (gold), or the doorway/amber "notice this" markers, so an
    /// Exit Sign reads as its own distinct category at a glance.
    private static func makeExitSignNode(pointing direction: Direction, cellSize: CGFloat) -> SCNNode {
        let anchor = SCNNode()

        let signColor = UIColor(red: 0.85, green: 0.12, blue: 0.1, alpha: 1)
        let glowColor = UIColor(red: 0.55, green: 0.05, blue: 0.03, alpha: 1)

        let text = SCNText(string: "EXIT", extrusionDepth: 4)
        text.font = UIFont.boldSystemFont(ofSize: 44)
        text.flatness = 0.2
        let textMaterial = SCNMaterial()
        textMaterial.diffuse.contents = signColor
        textMaterial.emission.contents = glowColor
        textMaterial.lightingModel = .physicallyBased
        textMaterial.metalness.contents = 0.3
        textMaterial.roughness.contents = 0.3
        text.materials = [textMaterial]

        let textNode = SCNNode(geometry: text)
        let (minBound, maxBound) = text.boundingBox
        let textWidth = maxBound.x - minBound.x
        let textHeight = maxBound.y - minBound.y
        textNode.pivot = SCNMatrix4MakeTranslation(minBound.x + textWidth / 2, minBound.y + textHeight / 2, 0)
        let textScale = textHeight > 0 ? Float(cellSize * 0.16) / textHeight : 1
        textNode.scale = SCNVector3(textScale, textScale, textScale)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        textNode.constraints = [billboard]
        anchor.addChildNode(textNode)

        let cone = SCNCone(topRadius: 0, bottomRadius: cellSize * 0.07, height: cellSize * 0.3)
        let coneMaterial = SCNMaterial()
        coneMaterial.diffuse.contents = signColor
        coneMaterial.emission.contents = glowColor
        coneMaterial.lightingModel = .physicallyBased
        coneMaterial.metalness.contents = 0.3
        coneMaterial.roughness.contents = 0.3
        cone.materials = [coneMaterial]
        let coneNode = SCNNode(geometry: cone)
        // Lying flat: rotating -90 degrees about X swings the cone's
        // apex from pointing +Y (its default) to pointing -Z, which is
        // north under this file's own yaw convention -- see the doc
        // comment above.
        coneNode.eulerAngles.x = -Float.pi / 2
        coneNode.position = SCNVector3(0, -Float(cellSize * 0.1), 0)

        let arrowWrapper = SCNNode()
        arrowWrapper.eulerAngles.y = Float(direction.yaw)
        arrowWrapper.addChildNode(coneNode)
        anchor.addChildNode(arrowWrapper)

        return anchor
    }

    private static func makeMarkerMaterial() -> SCNMaterial {'''
edits.append((old, new))

for i, (old, new) in enumerate(edits, 1):
    count = text.count(old)
    if count != 1:
        print(f"ERROR on edit {i}: expected 1 occurrence, found {count}")
        sys.exit(1)
    text = text.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
print(f"OK: applied {len(edits)} edits to HallwayScene.swift (exit signs)")
