//
//  OfficeChairFurniture.swift
//  Hallways
//
//  Sept 28 (fourth furniture object): an Office Chair as procedural
//  SceneKit geometry -- a five-spoke base on casters, a gas post, a
//  padded seat and a slightly reclined padded back, with armrests.
//  Deliberately concrete, like the other *Furniture files.
//
//  Placement differs from Table/Desk/Water Cooler: the chair is NOT
//  against the wall. It sits pulled up to the wall-side work area (a
//  Desk-sized zone) on its LEFT/RIGHT side, FACING that wall, so its back
//  is toward the cell center. It is an independent object -- never a
//  child of a Desk -- even when it shares a cell with one.
//
//  Data lives in MazeStore.officeChairs (see FurnitureOfficeChair).
//  Scenery only: never an ObjectKind, never in MazeStore.objects, never
//  registered with TapNavigationController.
//

import SceneKit
import UIKit

extension HallwayScene {
    static let officeChairSeatHeight: CGFloat = 0.50   // top of the seat cushion
    static let officeChairSeatDepth: CGFloat = 0.48
    static let officeChairBackTop: CGFloat = 1.06
    static let officeChairBaseRadius: CGFloat = 0.32  // spoke tip distance from the post
    /// Wall face to the front edge of the work area it serves -- the
    /// Desk's own wall clearance (0.06) + depth (0.70), so a same-side
    /// chair lines up with a Desk.
    private static let officeChairWorkAreaDepth: CGFloat = 0.76
    /// How far the seat's front edge tucks under that work area's edge.
    private static let officeChairTuck: CGFloat = 0.05
    private static let officeChairWallHalfThickness: CGFloat = 0.05

    /// World-space offset from the cell center for a chair at LEFT/RIGHT
    /// along its authored hallway axis (same side convention as the other
    /// furniture: northSouth left = -x/west; eastWest left = -z/north).
    /// The seat's center sits in front of the work area, not at the wall.
    static func officeChairFloorOffset(position: FloorPosition, orientation: FluorescentOrientation, cellSize: CGFloat) -> (dx: CGFloat, dz: CGFloat) {
        let magnitude = cellSize / 2 - officeChairWallHalfThickness - officeChairWorkAreaDepth + officeChairTuck - officeChairSeatDepth / 2
        let signed = position == .right ? magnitude : -magnitude
        return orientation == .northSouth ? (signed, 0) : (0, signed)
    }

    /// Yaw that turns the chair's local front (+z, the direction a seated
    /// person faces) TOWARD its side wall -- the opposite of the Desk,
    /// whose front faces the cell center. LEFT on a north-south axis sits
    /// at -x and faces -x (yaw -pi/2); RIGHT faces +x (+pi/2). On an
    /// east-west axis LEFT faces -z/north (yaw pi); RIGHT faces +z (0).
    static func officeChairYaw(position: FloorPosition, orientation: FluorescentOrientation) -> Float {
        let isRight = position == .right
        switch orientation {
        case .northSouth: return isRight ? Float.pi / 2 : -Float.pi / 2
        case .eastWest: return isRight ? 0 : Float.pi
        }
    }

    /// Builds one complete chair, tagged as a DECORATE `.officeChair`
    /// target and positioned in world space. Used by BOTH
    /// build(fromMaze:)'s per-cell loop and DecoratorState's live add/edit.
    /// Does not parent the node.
    static func buildOfficeChairNode(at coord: GridCoordinate, cellSize: CGFloat, floorNumber: Int, chair: FurnitureOfficeChair) -> SCNNode {
        let placement = chair.sanitized
        let node = makeOfficeChairNode()
        node.name = "furnitureOfficeChair"
        node.eulerAngles.y = officeChairYaw(position: placement.position, orientation: placement.orientation)
        let offset = officeChairFloorOffset(position: placement.position, orientation: placement.orientation, cellSize: cellSize)
        node.position = SCNVector3(Float(CGFloat(coord.col) * cellSize + offset.dx),
                                   0,
                                   Float(CGFloat(coord.row) * cellSize + offset.dz))
        DecoratorTarget(floor: floorNumber, coord: coord, kind: .officeChair).tag(node)
        return node
    }

    /// The chair alone: origin on the floor under the post, local +z the
    /// direction it faces, the back at -z.
    private static func makeOfficeChairNode() -> SCNNode {
        let root = SCNNode()

        func material(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, metalness: CGFloat = 0, roughness: CGFloat = 0.6) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
            m.metalness.contents = metalness
            m.roughness.contents = roughness
            return m
        }
        @discardableResult
        func add(_ geometry: SCNGeometry, _ m: SCNMaterial, at p: SCNVector3, name: String? = nil) -> SCNNode {
            geometry.materials = [m]
            let n = SCNNode(geometry: geometry)
            n.position = p
            n.name = name
            root.addChildNode(n)
            return n
        }

        let fabric = material(0.14, 0.14, 0.16, roughness: 0.9)
        let plastic = material(0.07, 0.07, 0.08, roughness: 0.5)
        // Low metalness on purpose -- near-1.0 PBR metal blackens under
        // Hallways' no-environment lighting.
        let post = material(0.58, 0.58, 0.60, metalness: 0.3, roughness: 0.35)

        // Five-spoke base with a caster at each tip.
        let spokeY: Float = 0.07
        for i in 0..<5 {
            let angle = Float(i) * 2 * Float.pi / 5
            let arm = SCNNode()
            arm.eulerAngles.y = angle
            root.addChildNode(arm)
            let spoke = SCNBox(width: 0.045, height: 0.035, length: officeChairBaseRadius, chamferRadius: 0.01)
            spoke.materials = [plastic]
            let spokeNode = SCNNode(geometry: spoke)
            spokeNode.position = SCNVector3(0, spokeY, Float(officeChairBaseRadius / 2))
            arm.addChildNode(spokeNode)
            let caster = SCNSphere(radius: 0.03)
            caster.materials = [plastic]
            let casterNode = SCNNode(geometry: caster)
            casterNode.position = SCNVector3(0, 0.03, Float(officeChairBaseRadius - 0.01))
            arm.addChildNode(casterNode)
        }
        add(SCNCylinder(radius: 0.05, height: 0.07), plastic, at: SCNVector3(0, spokeY + 0.01, 0))

        // Gas post up to the seat mechanism.
        let seatCushion: CGFloat = 0.08
        let seatBottom = officeChairSeatHeight - seatCushion
        let postBottom: CGFloat = 0.1
        add(SCNCylinder(radius: 0.025, height: seatBottom - 0.03 - postBottom), post,
            at: SCNVector3(0, Float((postBottom + seatBottom - 0.03) / 2), 0))
        add(SCNBox(width: 0.22, height: 0.04, length: 0.22, chamferRadius: 0.01), plastic,
            at: SCNVector3(0, Float(seatBottom - 0.02), 0))

        // Seat cushion.
        add(SCNBox(width: 0.50, height: seatCushion, length: officeChairSeatDepth, chamferRadius: 0.03), fabric,
            at: SCNVector3(0, Float(officeChairSeatHeight - seatCushion / 2), 0), name: "furnitureOfficeChairSeat")

        // Back: a support spine from the rear of the seat to a padded,
        // slightly reclined backrest.
        let backZ = -Float(officeChairSeatDepth / 2) - 0.02
        add(SCNBox(width: 0.06, height: 0.22, length: 0.03, chamferRadius: 0.01), plastic,
            at: SCNVector3(0, Float(officeChairSeatHeight + 0.06), backZ))
        let backHeight: CGFloat = 0.52
        let back = add(SCNBox(width: 0.46, height: backHeight, length: 0.07, chamferRadius: 0.03), fabric,
                       at: SCNVector3(0, Float(officeChairBackTop - backHeight / 2), backZ - 0.02),
                       name: "furnitureOfficeChairBack")
        back.eulerAngles.x = -0.12 // top leans back, away from the front

        // Armrests: a post and a pad on each side.
        for side in [-1.0, 1.0] as [Float] {
            add(SCNBox(width: 0.03, height: 0.17, length: 0.03, chamferRadius: 0.005), plastic,
                at: SCNVector3(side * 0.24, Float(officeChairSeatHeight + 0.085), -0.04))
            add(SCNBox(width: 0.06, height: 0.03, length: 0.24, chamferRadius: 0.01), plastic,
                at: SCNVector3(side * 0.24, Float(officeChairSeatHeight + 0.185), -0.02))
        }

        return root
    }
}
