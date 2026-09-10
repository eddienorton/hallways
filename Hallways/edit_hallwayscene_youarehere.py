# -*- coding: utf-8 -*-
import sys

path = "HallwayScene.swift"
with open(path, "r", encoding="utf-8") as f:
    text = f.read()

edits = []

# 1. makeFloorMapTexture, a plain private static func alongside the
# other texture/material builders -- right after makeElevatorShaftMaterial
# since both exist to dress up an auto-placed wall fixture.
old = '''    private static func makeElevatorShaftMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(white: 0.03, alpha: 1)
        m.lightingModel = .physicallyBased
        m.metalness.contents = 0.0
        m.roughness.contents = 0.9
        m.emission.contents = UIColor(red: 0.01, green: 0.02, blue: 0.04, alpha: 1)
        return m
    }'''
new = '''    private static func makeElevatorShaftMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(white: 0.03, alpha: 1)
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
    /// v1 marks `start` as "here" and never updates after that. That's
    /// exactly right the moment you arrive on a floor (which is the
    /// one guaranteed encounter this fixture gets, same reasoning as
    /// mounting it at `start` at all -- see addFloorMapNode below) and
    /// goes stale if you wander off and circle back to it, which is a
    /// real, known limitation of this first pass, not an oversight --
    /// a live-updating dot needs a path from TapNavigationController's
    /// per-move position back into this material's contents, which is
    /// real additional plumbing saved for once the static version's
    /// been seen on-device.
    private static func makeFloorMapTexture(cells: Set<GridCoordinate>, start: GridCoordinate, maxRow: Int, maxCol: Int) -> UIImage {
        let cellPx: CGFloat = 22
        let margin: CGFloat = 16
        let width = CGFloat(maxCol + 1) * cellPx + margin * 2
        let height = CGFloat(maxRow + 1) * cellPx + margin * 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let stoneColor = UIColor(red: 0.08, green: 0.06, blue: 0.03, alpha: 1)
        let floorColor = UIColor(red: 0.86, green: 0.74, blue: 0.46, alpha: 1)
        let markerColor = UIColor(red: 0.85, green: 0.12, blue: 0.1, alpha: 1)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            stoneColor.setFill()
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

            let markerRect = CGRect(x: margin + CGFloat(start.col) * cellPx, y: margin + CGFloat(start.row) * cellPx, width: cellPx, height: cellPx)
            markerColor.setFill()
            cg.fillEllipse(in: markerRect.insetBy(dx: cellPx * 0.15, dy: cellPx * 0.15))

            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 12),
                .foregroundColor: markerColor,
                .paragraphStyle: style,
            ]
            let labelWidth: CGFloat = 130
            let labelRect = CGRect(x: markerRect.midX - labelWidth / 2, y: max(2, markerRect.minY - 18), width: labelWidth, height: 16)
            ("YOU ARE HERE" as NSString).draw(in: labelRect, withAttributes: labelAttrs)
        }
    }'''
edits.append((old, new))

# 2. addFloorMapNode, a nested func in build() (needs `root` and
# `wallHeight` from that scope, same as addDestinationDoor/
# addElevatorDoor right above it) -- right after addElevatorDoor,
# before the per-cell loop starts.
old = '''            root.addChildNode(shaft)
            root.addChildNode(leftDoor)
            root.addChildNode(rightDoor)
            return (left: leftDoor, right: rightDoor, direction: direction)
        }

        for coord in cells {'''
new = '''            root.addChildNode(shaft)
            root.addChildNode(leftDoor)
            root.addChildNode(rightDoor)
            return (left: leftDoor, right: rightDoor, direction: direction)
        }

        // Wall-mounted, not a deep cubby like the destination doors --
        // this is a flat picture in a frame, so it only needs one thin
        // backing box (for a visible frame edge) plus a plane carrying
        // the actual map texture, nudged just proud of the frame face.
        func addFloorMapNode(direction: Direction, wallCenterX: CGFloat, wallCenterZ: CGFloat, texture: UIImage) -> SCNNode {
            let aspect = texture.size.height / max(texture.size.width, 1)
            var panelWidth: CGFloat = 1.3
            var panelHeight = panelWidth * aspect
            let maxPanelHeight: CGFloat = 2.0
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
            // Core Graphics renders top-left origin; SceneKit's UV
            // space is bottom-left -- without this flip the map reads
            // upside down (mirrored top-to-bottom) on the wall.
            planeMaterial.diffuse.contentsTransform = SCNMatrix4Translate(SCNMatrix4MakeScale(1, -1, 1), 0, 1, 0)
            planeMaterial.diffuse.wrapT = .clamp
            planeMaterial.lightingModel = .constant // reads as a lit sign, not shaded by scene lights/shadows
            let planeGeo = SCNPlane(width: panelWidth, height: panelHeight)
            planeGeo.materials = [planeMaterial]
            let plane = SCNNode(geometry: planeGeo)
            plane.position = SCNVector3(0, 0, 0.021)
            frame.addChildNode(plane)

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
            return frame
        }

        for coord in cells {'''
edits.append((old, new))

# 3. mapMountDirection, computed the same "before any wall panel gets
# built" way as destinationMountDirection/elevatorMountDirection just
# above it -- placed at `start` specifically, the one cell every run of
# this floor is guaranteed to pass through (same "auto from topology"
# reasoning as the elevator itself, and as Exit Signs above).
old = '''            let elevatorMountDirection: Direction? = {
                guard coord == end, end != start else { return nil }
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

            // One fresh material per wall segment (see the comment'''
new = '''            let elevatorMountDirection: Direction? = {
                guard coord == end, end != start else { return nil }
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

            // Same idea again, for the "You Are Here" wall map -- only
            // ever true at `start`. Explicitly steers clear of whatever
            // wall the destination cubby or elevator already claimed at
            // THIS exact cell (rare, but a destination can in principle
            // share the start cell), rather than assuming it never
            // collides the way destinationMountDirection/
            // elevatorMountDirection can safely assume about each other
            // (a cell is never both a destination AND the end).
            let mapMountDirection: Direction? = {
                guard coord == start else { return nil }
                let claimed: [Direction] = [destinationMountDirection, elevatorMountDirection].compactMap { $0 }
                let solidDirections: [Direction] = [.north, .south, .east, .west].filter { d in
                    switch d {
                    case .north: return hasWallNorth
                    case .south: return hasWallSouth
                    case .east: return hasWallEast
                    case .west: return hasWallWest
                    }
                }
                if let capSide, !claimed.contains(capSide) { return capSide }
                return solidDirections.first(where: { !claimed.contains($0) })
            }()

            // One fresh material per wall segment (see the comment'''
edits.append((old, new))

# 4. Exclude mapMountDirection from the 4 ordinary wall panels, same as
# destinationMountDirection/elevatorMountDirection already are.
old = '''            if hasWallNorth && destinationMountDirection != .north && elevatorMountDirection != .north {
                addWall(width: cellSize, length: 0.1, x: x, z: z - half, isCap: capSide == .north)
            }
            if hasWallSouth && destinationMountDirection != .south && elevatorMountDirection != .south {
                addWall(width: cellSize, length: 0.1, x: x, z: z + half, isCap: capSide == .south)
            }
            if hasWallEast && destinationMountDirection != .east && elevatorMountDirection != .east {
                addWall(width: 0.1, length: cellSize, x: x + half, z: z, isCap: capSide == .east)
            }
            if hasWallWest && destinationMountDirection != .west && elevatorMountDirection != .west {
                addWall(width: 0.1, length: cellSize, x: x - half, z: z, isCap: capSide == .west)
            }'''
new = '''            if hasWallNorth && destinationMountDirection != .north && elevatorMountDirection != .north && mapMountDirection != .north {
                addWall(width: cellSize, length: 0.1, x: x, z: z - half, isCap: capSide == .north)
            }
            if hasWallSouth && destinationMountDirection != .south && elevatorMountDirection != .south && mapMountDirection != .south {
                addWall(width: cellSize, length: 0.1, x: x, z: z + half, isCap: capSide == .south)
            }
            if hasWallEast && destinationMountDirection != .east && elevatorMountDirection != .east && mapMountDirection != .east {
                addWall(width: 0.1, length: cellSize, x: x + half, z: z, isCap: capSide == .east)
            }
            if hasWallWest && destinationMountDirection != .west && elevatorMountDirection != .west && mapMountDirection != .west {
                addWall(width: 0.1, length: cellSize, x: x - half, z: z, isCap: capSide == .west)
            }'''
edits.append((old, new))

# 5. Actually build+place the map fixture, right after the elevator
# placement block (same "wx/wz from mountDirection" pattern).
old = '''            if let mountDirection = elevatorMountDirection {
                let wx: CGFloat
                let wz: CGFloat
                switch mountDirection {
                case .north: (wx, wz) = (x, z - half)
                case .south: (wx, wz) = (x, z + half)
                case .east: (wx, wz) = (x + half, z)
                case .west: (wx, wz) = (x - half, z)
                }
                elevatorDoors = addElevatorDoor(direction: mountDirection, wallCenterX: wx, wallCenterZ: wz)
            }

            let xLower = x - half + (hasWallWest ? margin : 0)'''
new = '''            if let mountDirection = elevatorMountDirection {
                let wx: CGFloat
                let wz: CGFloat
                switch mountDirection {
                case .north: (wx, wz) = (x, z - half)
                case .south: (wx, wz) = (x, z + half)
                case .east: (wx, wz) = (x + half, z)
                case .west: (wx, wz) = (x - half, z)
                }
                elevatorDoors = addElevatorDoor(direction: mountDirection, wallCenterX: wx, wallCenterZ: wz)
            }

            // The "You Are Here" wall map -- only ever built once, at
            // `start`, on whichever wall mapMountDirection settled on
            // above.
            if let mountDirection = mapMountDirection {
                let wx: CGFloat
                let wz: CGFloat
                switch mountDirection {
                case .north: (wx, wz) = (x, z - half)
                case .south: (wx, wz) = (x, z + half)
                case .east: (wx, wz) = (x + half, z)
                case .west: (wx, wz) = (x - half, z)
                }
                let mapTexture = makeFloorMapTexture(cells: cells, start: start, maxRow: maxRow, maxCol: maxCol)
                _ = addFloorMapNode(direction: mountDirection, wallCenterX: wx, wallCenterZ: wz, texture: mapTexture)
            }

            let xLower = x - half + (hasWallWest ? margin : 0)'''
edits.append((old, new))

for i, (old, new) in enumerate(edits, 1):
    count = text.count(old)
    if count != 1:
        print(f"ERROR on edit {i}: expected 1 occurrence, found {count}")
        sys.exit(1)
    text = text.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
print(f"OK: applied {len(edits)} edits to HallwayScene.swift (you-are-here map)")
