//
//  TableFurniture.swift
//  Hallways
//
//  Sept 28 (first furniture proof of concept): the Table and its
//  optional Potted Plant as real SceneKit geometry. Procedural
//  primitives only -- this pass tests architecture and spatial
//  appearance, not final art.
//
//  The data lives in MazeStore.tables (see FurnitureTable). The table is
//  scenery: it is never an ObjectKind, never in MazeStore.objects, and
//  never registered with TapNavigationController, so it has no pickup,
//  walk-stop, mission, or HUD behavior. The plant is a CHILD node of the
//  table, so it inherits the table's position/rotation and is removed
//  with it; the plant carries no Decorator tag of its own, so tapping it
//  in DECORATE resolves to the table through DecoratorState.select's
//  existing parent walk.
//

import SceneKit
import UIKit

extension HallwayScene {
    // Table dimensions (meters). The long side runs ALONG the hallway
    // axis, the short side across it, so the table hugs the side wall.
    static let tableWidth: CGFloat = 0.9       // along the hallway axis
    static let tableDepth: CGFloat = 0.6       // across the hallway
    static let tableHeight: CGFloat = 0.75     // floor to top surface
    private static let tableTopThickness: CGFloat = 0.04
    private static let tableLegSize: CGFloat = 0.05
    private static let tableLegInset: CGFloat = 0.06
    /// Gap between the table's back edge and the side wall's face.
    private static let tableWallClearance: CGFloat = 0.08
    /// Half the thickness of the wall panels HallwayScene builds (0.1 m,
    /// centered on the cell boundary) -- the wall face sits this far
    /// inside the boundary.
    private static let tableWallHalfThickness: CGFloat = 0.05

    /// World-space offset from the cell center for a table at LEFT/RIGHT
    /// along its authored hallway axis. Same side convention as
    /// trashCanFloorOffset (northSouth: left = -x/west, right = +x/east;
    /// eastWest: left = -z/north, right = +z/south), but with the
    /// table's own depth -- never the trash can's radius. CENTER is not a
    /// valid table position and is treated as LEFT.
    static func tableFloorOffset(position: FloorPosition, orientation: FluorescentOrientation, cellSize: CGFloat) -> (dx: CGFloat, dz: CGFloat) {
        let magnitude = cellSize / 2 - tableWallHalfThickness - tableWallClearance - tableDepth / 2
        let signed = position == .right ? magnitude : -magnitude
        return orientation == .northSouth ? (signed, 0) : (0, signed)
    }

    /// Builds one complete table (plus its plant when hasPlant), tagged
    /// as a DECORATE `.table` target and positioned in world space. Used
    /// by BOTH build(fromMaze:)'s per-cell loop and DecoratorState's live
    /// add/edit, so a live-placed table is identical to a rebuilt one.
    /// Does not parent the node anywhere -- the caller does.
    static func buildTableNode(at coord: GridCoordinate, cellSize: CGFloat, floorNumber: Int, table: FurnitureTable) -> SCNNode {
        let node = makeTableNode()
        node.name = "furnitureTable"
        if table.hasPlant {
            let plant = makePottedPlantNode()
            // Local origin of the plant is its pot's base, so placing it
            // exactly at the tabletop's top surface seats it ON the table.
            plant.position = SCNVector3(0, Float(tableHeight), 0)
            node.addChildNode(plant)
        }
        let placement = table.sanitized
        // Local +x is the table's long side; turn it to run along the
        // hallway. An east-west hallway already runs along world x.
        node.eulerAngles.y = placement.orientation == .northSouth ? Float.pi / 2 : 0
        let offset = tableFloorOffset(position: placement.position, orientation: placement.orientation, cellSize: cellSize)
        node.position = SCNVector3(Float(CGFloat(coord.col) * cellSize + offset.dx),
                                   0,
                                   Float(CGFloat(coord.row) * cellSize + offset.dz))
        DecoratorTarget(floor: floorNumber, coord: coord, kind: .table).tag(node)
        return node
    }

    /// The table alone, origin at floor level under the tabletop's center.
    private static func makeTableNode() -> SCNNode {
        let root = SCNNode()

        let wood = SCNMaterial()
        wood.lightingModel = .physicallyBased
        wood.diffuse.contents = UIColor(red: 0.45, green: 0.30, blue: 0.18, alpha: 1)
        wood.metalness.contents = 0.0
        wood.roughness.contents = 0.7

        let top = SCNBox(width: tableWidth, height: tableTopThickness, length: tableDepth, chamferRadius: 0.01)
        top.materials = [wood]
        let topNode = SCNNode(geometry: top)
        topNode.name = "furnitureTableTop"
        topNode.position = SCNVector3(0, Float(tableHeight - tableTopThickness / 2), 0)
        root.addChildNode(topNode)

        let legHeight = tableHeight - tableTopThickness
        let legX = tableWidth / 2 - tableLegInset
        let legZ = tableDepth / 2 - tableLegInset
        for (sx, sz) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] as [(CGFloat, CGFloat)] {
            let leg = SCNBox(width: tableLegSize, height: legHeight, length: tableLegSize, chamferRadius: 0)
            leg.materials = [wood]
            let legNode = SCNNode(geometry: leg)
            legNode.position = SCNVector3(Float(sx * legX), Float(legHeight / 2), Float(sz * legZ))
            root.addChildNode(legNode)
        }
        return root
    }

    /// A terracotta pot with a soil disc and a clump of foliage. Local
    /// origin is the BOTTOM of the pot (y = 0), so whatever it's placed
    /// on, it sits on. Total height ~0.43 m -- on a 0.75 m table the top
    /// is ~1.18 m, comfortably below the ~1.6 m eye height.
    static func makePottedPlantNode() -> SCNNode {
        let root = SCNNode()
        root.name = "furnitureTablePlant"

        let terracotta = SCNMaterial()
        terracotta.lightingModel = .physicallyBased
        terracotta.diffuse.contents = UIColor(red: 0.72, green: 0.40, blue: 0.26, alpha: 1)
        terracotta.metalness.contents = 0.0
        terracotta.roughness.contents = 0.85

        let soil = SCNMaterial()
        soil.lightingModel = .physicallyBased
        soil.diffuse.contents = UIColor(red: 0.20, green: 0.14, blue: 0.10, alpha: 1)
        soil.metalness.contents = 0.0
        soil.roughness.contents = 1.0

        let leaf = SCNMaterial()
        leaf.lightingModel = .physicallyBased
        leaf.diffuse.contents = UIColor(red: 0.20, green: 0.50, blue: 0.22, alpha: 1)
        leaf.metalness.contents = 0.0
        leaf.roughness.contents = 0.8

        // Pot: slightly tapered, wider at the rim. SCNCone is centered on
        // its origin, so lift it by half its height to rest on y = 0.
        let potHeight: CGFloat = 0.18
        let potTopRadius: CGFloat = 0.11
        let pot = SCNCone(topRadius: potTopRadius, bottomRadius: 0.08, height: potHeight)
        pot.materials = [terracotta]
        let potNode = SCNNode(geometry: pot)
        potNode.position = SCNVector3(0, Float(potHeight / 2), 0)
        root.addChildNode(potNode)

        // Rim band standing slightly proud of the pot's top so the pot
        // reads as a pot, not a cone.
        let rim = SCNTube(innerRadius: potTopRadius - 0.012, outerRadius: potTopRadius + 0.012, height: 0.03)
        rim.materials = [terracotta]
        let rimNode = SCNNode(geometry: rim)
        rimNode.position = SCNVector3(0, Float(potHeight), 0)
        root.addChildNode(rimNode)

        // Soil resting on the pot's (capped) top, inside the rim.
        let soilDisc = SCNCylinder(radius: potTopRadius - 0.012, height: 0.01)
        soilDisc.materials = [soil]
        let soilNode = SCNNode(geometry: soilDisc)
        soilNode.position = SCNVector3(0, Float(potHeight + 0.005), 0)
        root.addChildNode(soilNode)

        // Foliage: a few overlapping spheres rising out of the soil.
        let clumps: [(x: CGFloat, y: CGFloat, z: CGFloat, r: CGFloat)] = [
            (0.00, 0.30, 0.00, 0.13),
            (0.07, 0.25, 0.04, 0.09),
            (-0.07, 0.26, -0.03, 0.09),
            (0.02, 0.24, -0.08, 0.08),
            (-0.03, 0.23, 0.08, 0.08),
        ]
        for clump in clumps {
            let sphere = SCNSphere(radius: clump.r)
            sphere.segmentCount = 16
            sphere.materials = [leaf]
            let sphereNode = SCNNode(geometry: sphere)
            sphereNode.position = SCNVector3(Float(clump.x), Float(clump.y), Float(clump.z))
            root.addChildNode(sphereNode)
        }
        return root
    }
}
