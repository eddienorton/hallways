//
//  WaterCoolerFurniture.swift
//  Hallways
//
//  Sept 28 (third furniture object): an office Water Cooler as
//  procedural SceneKit geometry -- a narrow off-white cabinet with a dark
//  dispensing recess, hot/cold taps and a drip tray on its front, and a
//  big inverted translucent blue bottle on top (the visual signature).
//  Deliberately concrete, like TableFurniture/DeskFurniture.
//
//  Data lives in MazeStore.waterCoolers (see FurnitureWaterCooler). The
//  cooler is scenery: never an ObjectKind, never in MazeStore.objects,
//  never registered with TapNavigationController. Every part is a child
//  of the one tagged root, so tapping the bottle, taps, tray or body in
//  DECORATE selects the whole cooler through the existing parent walk.
//

import SceneKit
import UIKit

extension HallwayScene {
    static let waterCoolerWidth: CGFloat = 0.34   // along the hallway axis
    static let waterCoolerDepth: CGFloat = 0.34   // across the hallway
    static let waterCoolerBodyHeight: CGFloat = 0.95
    /// Gap between the cabinet's back and the side wall's face.
    private static let waterCoolerWallClearance: CGFloat = 0.05
    private static let waterCoolerWallHalfThickness: CGFloat = 0.05

    /// World-space offset from the cell center for a water cooler at
    /// LEFT/RIGHT along its authored hallway axis. Same side convention as
    /// tableFloorOffset/deskFloorOffset (northSouth: left = -x/west;
    /// eastWest: left = -z/north), using the cooler's own small depth so
    /// it parks right against the wall. CENTER is treated as LEFT.
    static func waterCoolerFloorOffset(position: FloorPosition, orientation: FluorescentOrientation, cellSize: CGFloat) -> (dx: CGFloat, dz: CGFloat) {
        let magnitude = cellSize / 2 - waterCoolerWallHalfThickness - waterCoolerWallClearance - waterCoolerDepth / 2
        let signed = position == .right ? magnitude : -magnitude
        return orientation == .northSouth ? (signed, 0) : (0, signed)
    }

    /// Yaw that turns the cooler's local front (+z, taps and recess)
    /// toward the cell center. LEFT on a north-south axis sits at -x, so
    /// its front faces +x (yaw +pi/2); RIGHT faces -x (-pi/2). On an
    /// east-west axis LEFT sits at -z (north) and faces +z (yaw 0); RIGHT
    /// faces -z (yaw pi).
    static func waterCoolerYaw(position: FloorPosition, orientation: FluorescentOrientation) -> Float {
        let isRight = position == .right
        switch orientation {
        case .northSouth: return isRight ? -Float.pi / 2 : Float.pi / 2
        case .eastWest: return isRight ? Float.pi : 0
        }
    }

    /// Builds one complete water cooler, tagged as a DECORATE
    /// `.waterCooler` target and positioned in world space. Used by BOTH
    /// build(fromMaze:)'s per-cell loop and DecoratorState's live add/edit.
    /// Does not parent the node.
    static func buildWaterCoolerNode(at coord: GridCoordinate, cellSize: CGFloat, floorNumber: Int, cooler: FurnitureWaterCooler) -> SCNNode {
        let placement = cooler.sanitized
        let node = makeWaterCoolerNode()
        node.name = "furnitureWaterCooler"
        node.eulerAngles.y = waterCoolerYaw(position: placement.position, orientation: placement.orientation)
        let offset = waterCoolerFloorOffset(position: placement.position, orientation: placement.orientation, cellSize: cellSize)
        node.position = SCNVector3(Float(CGFloat(coord.col) * cellSize + offset.dx),
                                   0,
                                   Float(CGFloat(coord.row) * cellSize + offset.dz))
        DecoratorTarget(floor: floorNumber, coord: coord, kind: .waterCooler).tag(node)
        return node
    }

    /// The cooler alone: origin on the floor under the cabinet's center,
    /// local +z toward the front (taps).
    private static func makeWaterCoolerNode() -> SCNNode {
        let root = SCNNode()

        func material(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, metalness: CGFloat = 0, roughness: CGFloat = 0.5) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
            m.metalness.contents = metalness
            m.roughness.contents = roughness
            return m
        }
        func add(_ geometry: SCNGeometry, _ m: SCNMaterial, at p: SCNVector3, name: String? = nil) -> SCNNode {
            geometry.materials = [m]
            let n = SCNNode(geometry: geometry)
            n.position = p
            n.name = name
            root.addChildNode(n)
            return n
        }

        let cabinet = material(0.90, 0.90, 0.87, roughness: 0.45)
        let base = material(0.55, 0.55, 0.55, roughness: 0.6)
        let recess = material(0.12, 0.13, 0.15, roughness: 0.7)
        let trayMetal = material(0.62, 0.63, 0.65, metalness: 0.3, roughness: 0.35)
        let hot = material(0.80, 0.12, 0.10, roughness: 0.4)
        let cold = material(0.12, 0.35, 0.85, roughness: 0.4)

        let w = waterCoolerWidth, d = waterCoolerDepth, h = waterCoolerBodyHeight
        let front = Float(d / 2)

        // Cabinet on a slightly darker plinth.
        _ = add(SCNBox(width: w + 0.02, height: 0.04, length: d + 0.02, chamferRadius: 0.005), base, at: SCNVector3(0, 0.02, 0))
        _ = add(SCNBox(width: w, height: h - 0.04, length: d, chamferRadius: 0.02), cabinet,
                at: SCNVector3(0, Float(0.04 + (h - 0.04) / 2), 0), name: "furnitureWaterCoolerBody")

        // Dark dispensing recess on the front, upper half.
        let recessBottom: CGFloat = 0.56
        let recessTop: CGFloat = 0.86
        _ = add(SCNBox(width: w * 0.7, height: recessTop - recessBottom, length: 0.012, chamferRadius: 0.004), recess,
                at: SCNVector3(0, Float((recessTop + recessBottom) / 2), front + 0.006))

        // Hot (red, left) and cold (blue, right) taps, pointing out of the
        // recess, each with a small push paddle under it.
        for (x, m) in [(-0.055, hot), (0.055, cold)] as [(Float, SCNMaterial)] {
            let spout = SCNCylinder(radius: 0.017, height: 0.05)
            let spoutNode = add(spout, m, at: SCNVector3(x, Float(recessTop - 0.05), front + 0.035))
            spoutNode.eulerAngles.x = Float.pi / 2 // axis along +z
            _ = add(SCNBox(width: 0.03, height: 0.022, length: 0.02, chamferRadius: 0.004), m,
                    at: SCNVector3(x, Float(recessTop - 0.085), front + 0.05))
        }

        // Drip tray at the bottom of the recess.
        _ = add(SCNBox(width: w * 0.62, height: 0.02, length: 0.08, chamferRadius: 0.004), trayMetal,
                at: SCNVector3(0, Float(recessBottom + 0.01), front + 0.03))

        // Collar the bottle sits in.
        _ = add(SCNCylinder(radius: 0.13, height: 0.03), cabinet, at: SCNVector3(0, Float(h + 0.015), 0))

        // The inverted bottle: neck down into the collar, a tapered
        // shoulder, a ribbed body, and a rounded top (the bottle's base).
        let bottle = SCNMaterial()
        bottle.lightingModel = .physicallyBased
        bottle.diffuse.contents = UIColor(red: 0.50, green: 0.72, blue: 0.95, alpha: 1)
        bottle.emission.contents = UIColor(red: 0.04, green: 0.08, blue: 0.14, alpha: 1) // keeps it from going black in dim halls
        bottle.metalness.contents = 0.0
        bottle.roughness.contents = 0.15
        bottle.transparency = 0.6
        bottle.transparencyMode = .dualLayer
        bottle.isDoubleSided = false

        let ribs = bottle.copy() as! SCNMaterial
        ribs.transparency = 0.8

        let bottleRadius: CGFloat = 0.135
        let neckBottom = h + 0.01
        let neckHeight: CGFloat = 0.07
        let shoulderHeight: CGFloat = 0.08
        let bodyHeight: CGFloat = 0.36
        _ = add(SCNCylinder(radius: 0.045, height: neckHeight), bottle,
                at: SCNVector3(0, Float(neckBottom + neckHeight / 2), 0), name: "furnitureWaterCoolerBottle")
        let shoulderBottom = neckBottom + neckHeight
        _ = add(SCNCone(topRadius: bottleRadius, bottomRadius: 0.045, height: shoulderHeight), bottle,
                at: SCNVector3(0, Float(shoulderBottom + shoulderHeight / 2), 0))
        let bodyBottom = shoulderBottom + shoulderHeight
        _ = add(SCNCylinder(radius: bottleRadius, height: bodyHeight), bottle,
                at: SCNVector3(0, Float(bodyBottom + bodyHeight / 2), 0))
        for fraction in [0.3, 0.7] as [CGFloat] {
            _ = add(SCNTorus(ringRadius: bottleRadius, pipeRadius: 0.008), ribs,
                    at: SCNVector3(0, Float(bodyBottom + bodyHeight * fraction), 0))
        }
        let dome = add(SCNSphere(radius: bottleRadius), bottle, at: SCNVector3(0, Float(bodyBottom + bodyHeight), 0))
        dome.scale = SCNVector3(1, 0.3, 1)

        return root
    }
}
