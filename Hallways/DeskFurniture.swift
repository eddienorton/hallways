//
//  DeskFurniture.swift
//  Hallways
//
//  Sept 28 (second furniture object): an office Desk as procedural
//  SceneKit geometry -- a substantial top over two drawer pedestals,
//  a modesty panel at the back, and open knee space between. Deliberately
//  concrete (no shared furniture framework) while we learn what these
//  objects need.
//
//  Data lives in MazeStore.desks (see FurnitureDesk). Like the Table,
//  the desk is scenery: never an ObjectKind, never in MazeStore.objects,
//  never registered with TapNavigationController.
//

import SceneKit
import UIKit

extension HallwayScene {
    static let deskWidth: CGFloat = 1.3      // along the hallway axis
    static let deskDepth: CGFloat = 0.7      // across the hallway
    static let deskHeight: CGFloat = 0.75    // floor to top surface
    private static let deskTopThickness: CGFloat = 0.045
    private static let deskPedestalWidth: CGFloat = 0.38
    private static let deskPedestalDepth: CGFloat = 0.64
    private static let deskKickHeight: CGFloat = 0.06
    /// Same wall conventions as tableFloorOffset: 0.1 m walls centered on
    /// the cell boundary, plus a small gap behind the desk.
    private static let deskWallClearance: CGFloat = 0.06
    private static let deskWallHalfThickness: CGFloat = 0.05

    /// World-space offset from the cell center for a desk at LEFT/RIGHT
    /// along its authored hallway axis -- the same side convention as
    /// tableFloorOffset (northSouth: left = -x/west; eastWest: left =
    /// -z/north), using the desk's own depth. CENTER is treated as LEFT.
    static func deskFloorOffset(position: FloorPosition, orientation: FluorescentOrientation, cellSize: CGFloat) -> (dx: CGFloat, dz: CGFloat) {
        let magnitude = cellSize / 2 - deskWallHalfThickness - deskWallClearance - deskDepth / 2
        let signed = position == .right ? magnitude : -magnitude
        return orientation == .northSouth ? (signed, 0) : (0, signed)
    }

    /// Yaw that turns the desk's local front (+z, the drawer/knee side)
    /// toward the cell center, with its long side (local x) running along
    /// the hallway axis. A LEFT desk on a north-south axis sits at -x, so
    /// its front faces +x; and so on for the other three cases.
    static func deskYaw(position: FloorPosition, orientation: FluorescentOrientation) -> Float {
        let isRight = position == .right
        switch orientation {
        case .northSouth: return isRight ? -Float.pi / 2 : Float.pi / 2
        case .eastWest: return isRight ? Float.pi : 0
        }
    }

    /// Builds one complete desk, tagged as a DECORATE `.desk` target and
    /// positioned in world space. Used by BOTH build(fromMaze:)'s per-cell
    /// loop and DecoratorState's live add/edit. Does not parent the node.
    static func buildDeskNode(at coord: GridCoordinate, cellSize: CGFloat, floorNumber: Int, desk: FurnitureDesk) -> SCNNode {
        let placement = desk.sanitized
        let node = makeDeskNode()
        node.name = "furnitureDesk"
        node.eulerAngles.y = deskYaw(position: placement.position, orientation: placement.orientation)
        let offset = deskFloorOffset(position: placement.position, orientation: placement.orientation, cellSize: cellSize)
        node.position = SCNVector3(Float(CGFloat(coord.col) * cellSize + offset.dx),
                                   0,
                                   Float(CGFloat(coord.row) * cellSize + offset.dz))
        DecoratorTarget(floor: floorNumber, coord: coord, kind: .desk).tag(node)
        return node
    }

    /// The desk alone: origin at floor level under the top's center,
    /// local +x along its width, local +z toward the front (knee side).
    private static func makeDeskNode() -> SCNNode {
        let root = SCNNode()

        func material(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, metalness: CGFloat = 0, roughness: CGFloat = 0.65) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
            m.metalness.contents = metalness
            m.roughness.contents = roughness
            return m
        }
        let topWood = material(0.36, 0.24, 0.15, roughness: 0.55)
        let bodyWood = material(0.42, 0.29, 0.18)
        let drawerWood = material(0.48, 0.34, 0.22)
        let kick = material(0.16, 0.12, 0.09, roughness: 0.8)
        // Low metalness on purpose -- near-1.0 PBR metal blackens under
        // Hallways' no-environment lighting (see PropLibrary's note).
        let handleMetal = material(0.72, 0.72, 0.70, metalness: 0.3, roughness: 0.4)

        func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, at p: SCNVector3, chamfer: CGFloat = 0) -> SCNNode {
            let geometry = SCNBox(width: w, height: h, length: l, chamferRadius: chamfer)
            geometry.materials = [m]
            let n = SCNNode(geometry: geometry)
            n.position = p
            return n
        }

        // Top: a substantial slab overhanging the pedestals slightly.
        let top = box(deskWidth, deskTopThickness, deskDepth, topWood,
                      at: SCNVector3(0, Float(deskHeight - deskTopThickness / 2), 0), chamfer: 0.008)
        top.name = "furnitureDeskTop"
        root.addChildNode(top)

        let underTop = deskHeight - deskTopThickness
        let pedestalCenterX = deskWidth / 2 - deskPedestalWidth / 2 - 0.01
        let frontZ = deskPedestalDepth / 2 // pedestal front face (local +z)

        // Two pedestals: a recessed dark kick at the floor, a carcass above.
        for side in [-1.0, 1.0] as [CGFloat] {
            let x = Float(side * pedestalCenterX)
            root.addChildNode(box(deskPedestalWidth - 0.03, deskKickHeight, deskPedestalDepth - 0.04, kick,
                                  at: SCNVector3(x, Float(deskKickHeight / 2), -0.01)))
            let carcassHeight = underTop - deskKickHeight
            root.addChildNode(box(deskPedestalWidth, carcassHeight, deskPedestalDepth, bodyWood,
                                  at: SCNVector3(x, Float(deskKickHeight + carcassHeight / 2), 0)))
        }

        // Modesty panel across the back of the knee space.
        let kneeWidth = 2 * (pedestalCenterX - deskPedestalWidth / 2)
        let panelHeight: CGFloat = 0.42
        root.addChildNode(box(kneeWidth, panelHeight, 0.02, bodyWood,
                              at: SCNVector3(0, Float(underTop - panelHeight / 2), Float(-deskPedestalDepth / 2 + 0.01))))

        // Drawer fronts with bar handles. Left pedestal: three drawers.
        // Right pedestal: one drawer over a deep file drawer. Plus a thin
        // pencil drawer under the top, spanning the knee opening.
        let gap: CGFloat = 0.012
        let usable = underTop - deskKickHeight - gap
        func addDrawers(centerX: CGFloat, width: CGFloat, heights: [CGFloat], topY: CGFloat) {
            var y = topY
            for h in heights {
                let centerY = y - h / 2
                root.addChildNode(box(width, h, 0.018, drawerWood,
                                      at: SCNVector3(Float(centerX), Float(centerY), Float(frontZ + 0.009)), chamfer: 0.003))
                root.addChildNode(box(min(0.14, width * 0.4), 0.014, 0.02, handleMetal,
                                      at: SCNVector3(Float(centerX), Float(y - min(0.05, h * 0.3)), Float(frontZ + 0.028))))
                y -= h + gap
            }
        }
        let drawerWidth = deskPedestalWidth - 2 * gap
        let small = (usable - 2 * gap) / 3
        addDrawers(centerX: -pedestalCenterX, width: drawerWidth, heights: [small, small, small], topY: underTop - gap)
        addDrawers(centerX: pedestalCenterX, width: drawerWidth, heights: [small, usable - small - gap], topY: underTop - gap)

        let pencilHeight: CGFloat = 0.07
        let pencilDepth = deskPedestalDepth - 0.06
        root.addChildNode(box(kneeWidth, pencilHeight, pencilDepth, bodyWood,
                              at: SCNVector3(0, Float(underTop - pencilHeight / 2), Float(frontZ - pencilDepth / 2))))
        addDrawers(centerX: 0, width: kneeWidth - 2 * gap, heights: [pencilHeight - gap], topY: underTop - gap / 2)

        return root
    }
}
