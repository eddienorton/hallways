//
//  FilingCabinetFurniture.swift
//  Hallways
//
//  Sept 28 (seventh furniture object): a three-drawer office Filing
//  Cabinet -- procedural SceneKit geometry whose drawers really open.
//
//  Node hierarchy (local front = +z, the drawer fronts):
//
//    furnitureFilingCabinet            root: world position + yaw, the ONLY
//    |                                 DecoratorTarget-tagged node
//    +- furnitureFilingCabinetShell    fixed carcass: sides, top, back,
//    |                                 bottom, plinth, front rails
//    +- furnitureFilingCabinetDrawer0  top drawer root (moves along z)
//    |    front panel, pull, label holder, and an open-topped box:
//    |    bottom, two sides, back, inner front
//    +- furnitureFilingCabinetDrawer1  middle drawer root
//    +- furnitureFilingCabinetDrawer2  bottom drawer root
//
//  A drawer root's position is ALWAYS one of two fixed values --
//  filingCabinetDrawerPosition(index:open:) -- set directly on build, or
//  reached with SCNAction.move(to:) (absolute, never moveBy) when a Play
//  tap changes which drawer is open. Nothing accumulates.
//
//  The drawers are empty.
//
//  Data lives in MazeStore.filingCabinets (see FurnitureFilingCabinet).
//  Scenery only: never an ObjectKind, never in MazeStore.objects, never
//  registered with TapNavigationController.
//

import SceneKit
import UIKit

extension HallwayScene {
    static let filingCabinetWidth: CGFloat = 0.47     // along the hallway axis
    static let filingCabinetDepth: CGFloat = 0.60     // across the hallway (drawer travel direction)
    static let filingCabinetHeight: CGFloat = 1.33
    /// How far an open drawer slides out of the carcass.
    static let filingCabinetDrawerTravel: CGFloat = 0.40
    static let filingCabinetDrawerSlideDuration: TimeInterval = 0.32
    static let filingCabinetDrawerActionKey = "filingCabinetDrawerSlide"
    /// Exact drawer-root names, top (0) to bottom (2).
    static let filingCabinetDrawerNames = (0..<FurnitureFilingCabinet.drawerCount).map { "furnitureFilingCabinetDrawer\($0)" }

    private static let filingCabinetPlinth: CGFloat = 0.05
    private static let filingCabinetPanel: CGFloat = 0.012
    private static let filingCabinetWallClearance: CGFloat = 0.03
    private static let filingCabinetWallHalfThickness: CGFloat = 0.05

    /// Height of one drawer slot inside the carcass.
    private static var filingCabinetSlotHeight: CGFloat {
        (filingCabinetHeight - filingCabinetPlinth - 2 * filingCabinetPanel) / CGFloat(FurnitureFilingCabinet.drawerCount)
    }

    /// The authoritative position of drawer `index`'s root, closed or
    /// open, in the cabinet's local space. The ONLY two places a drawer
    /// is ever put.
    static func filingCabinetDrawerPosition(index: Int, open: Bool) -> SCNVector3 {
        let slotBottom = filingCabinetPlinth + filingCabinetPanel
            + CGFloat(FurnitureFilingCabinet.drawerCount - 1 - index) * filingCabinetSlotHeight
        return SCNVector3(0, Float(slotBottom + filingCabinetSlotHeight / 2), open ? Float(filingCabinetDrawerTravel) : 0)
    }

    /// World-space offset from the cell center for a cabinet at LEFT/RIGHT
    /// along its authored hallway axis (same convention as the other furniture).
    static func filingCabinetFloorOffset(position: FloorPosition, orientation: FluorescentOrientation, cellSize: CGFloat) -> (dx: CGFloat, dz: CGFloat) {
        let magnitude = cellSize / 2 - filingCabinetWallHalfThickness - filingCabinetWallClearance - filingCabinetDepth / 2
        let signed = position == .right ? magnitude : -magnitude
        return orientation == .northSouth ? (signed, 0) : (0, signed)
    }

    /// Yaw that turns local +z (the drawer fronts) toward the cell center
    /// -- same rule as the Desk, Water Cooler and Aquarium.
    static func filingCabinetYaw(position: FloorPosition, orientation: FluorescentOrientation) -> Float {
        let isRight = position == .right
        switch orientation {
        case .northSouth: return isRight ? -Float.pi / 2 : Float.pi / 2
        case .eastWest: return isRight ? Float.pi : 0
        }
    }

    /// Builds one complete cabinet, tagged as a DECORATE `.filingCabinet`
    /// target and positioned in world space, with its drawers placed
    /// straight from the persisted `openDrawerIndex` (no animation). Used
    /// by BOTH build(fromMaze:) and DecoratorState's live add/edit. Does
    /// not parent the node.
    static func buildFilingCabinetNode(at coord: GridCoordinate, cellSize: CGFloat, floorNumber: Int, cabinet: FurnitureFilingCabinet) -> SCNNode {
        let placement = cabinet.sanitized
        let node = makeFilingCabinetNode()
        node.name = "furnitureFilingCabinet"
        node.eulerAngles.y = filingCabinetYaw(position: placement.position, orientation: placement.orientation)
        let offset = filingCabinetFloorOffset(position: placement.position, orientation: placement.orientation, cellSize: cellSize)
        node.position = SCNVector3(Float(CGFloat(coord.col) * cellSize + offset.dx),
                                   0,
                                   Float(CGFloat(coord.row) * cellSize + offset.dz))
        setFilingCabinetDrawers(node, openDrawerIndex: placement.openDrawerIndex, animated: false)
        DecoratorTarget(floor: floorNumber, coord: coord, kind: .filingCabinet).tag(node)
        return node
    }

    /// Puts every drawer of `cabinetNode` at its authoritative closed/open
    /// position for `openDrawerIndex`. Animated: any in-flight slide is
    /// cancelled and each drawer moves (absolute move(to:)) from wherever
    /// it is right now -- so rapid taps retarget, never accumulate. The
    /// drawer that is closing and the one that is opening slide together.
    static func setFilingCabinetDrawers(_ cabinetNode: SCNNode, openDrawerIndex: Int?, animated: Bool) {
        for (index, name) in filingCabinetDrawerNames.enumerated() {
            guard let drawer = cabinetNode.childNode(withName: name, recursively: false) else { continue }
            let target = filingCabinetDrawerPosition(index: index, open: index == openDrawerIndex)
            drawer.removeAction(forKey: filingCabinetDrawerActionKey)
            let dz = abs(drawer.position.z - target.z)
            if !animated || dz < 0.0005 {
                drawer.position = target
                continue
            }
            // Scale the time to the remaining distance, so a drawer caught
            // halfway doesn't crawl back at full-travel pace.
            let fraction = min(1, Double(dz) / Double(filingCabinetDrawerTravel))
            let slide = SCNAction.move(to: target, duration: max(0.08, filingCabinetDrawerSlideDuration * fraction))
            slide.timingMode = index == openDrawerIndex ? .easeOut : .easeInEaseOut
            drawer.runAction(slide, forKey: filingCabinetDrawerActionKey)
        }
    }

    /// Walks up from a hit-tested node. Returns the cabinet's coordinate
    /// and, if the hit was on (any part of) a drawer, that drawer's index
    /// -- nil for the carcass. nil overall if the node isn't part of a
    /// filing cabinet. Pure scene-graph ancestry: works from any viewing
    /// angle.
    static func filingCabinetHit(for node: SCNNode) -> (coord: GridCoordinate, drawerIndex: Int?)? {
        var drawerIndex: Int?
        var current: SCNNode? = node
        while let candidate = current {
            if drawerIndex == nil, let name = candidate.name, let index = filingCabinetDrawerNames.firstIndex(of: name) {
                drawerIndex = index
            }
            if let target = DecoratorTarget.read(candidate) {
                guard target.kind == .filingCabinet, let coord = target.coord else { return nil }
                return (coord, drawerIndex)
            }
            current = candidate.parent
        }
        return nil
    }

    private static func makeFilingCabinetNode() -> SCNNode {
        let root = SCNNode()

        func material(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, metalness: CGFloat, roughness: CGFloat) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
            m.metalness.contents = metalness
            m.roughness.contents = roughness
            return m
        }
        @discardableResult
        func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, x: CGFloat = 0, y: CGFloat, z: CGFloat = 0,
                 chamfer: CGFloat = 0, parent: SCNNode, name: String? = nil) -> SCNNode {
            let g = SCNBox(width: w, height: h, length: l, chamferRadius: chamfer)
            g.materials = [m]
            let n = SCNNode(geometry: g)
            n.position = SCNVector3(Float(x), Float(y), Float(z))
            n.name = name
            parent.addChildNode(n)
            return n
        }

        // Classic institutional painted steel: a muted warm gray, a darker
        // gray for the inside of the drawers, charcoal plinth/rails, and
        // satin chrome hardware.
        let paint = material(0.56, 0.57, 0.54, metalness: 0.3, roughness: 0.5)
        let interior = material(0.40, 0.41, 0.39, metalness: 0.2, roughness: 0.7)
        let charcoal = material(0.14, 0.14, 0.15, metalness: 0.2, roughness: 0.6)
        let chrome = material(0.78, 0.79, 0.80, metalness: 0.9, roughness: 0.25)
        let card = material(0.93, 0.92, 0.86, metalness: 0, roughness: 0.9)

        let w = filingCabinetWidth, d = filingCabinetDepth, h = filingCabinetHeight
        let t = filingCabinetPanel, plinth = filingCabinetPlinth
        let front = d / 2
        let slot = filingCabinetSlotHeight

        // --- Carcass: open at the front where the drawers sit.
        let shell = SCNNode()
        shell.name = "furnitureFilingCabinetShell"
        root.addChildNode(shell)
        box(w - 0.03, plinth, d - 0.04, charcoal, y: plinth / 2, z: -0.01, parent: shell)            // recessed plinth
        let bodyHeight = h - plinth
        for side in [-1.0, 1.0] as [CGFloat] {
            box(t, bodyHeight, d, paint, x: side * (w / 2 - t / 2), y: plinth + bodyHeight / 2, parent: shell)
        }
        box(w, t, d + 0.004, paint, y: h - t / 2, z: 0.002, chamfer: 0.003, parent: shell)          // top
        box(w - 2 * t, t, d, paint, y: plinth + t / 2, parent: shell)                                // bottom
        box(w - 2 * t, bodyHeight, t, paint, y: plinth + bodyHeight / 2, z: -front + t / 2, parent: shell) // back
        // Dark rails between the drawer openings -- what shows through the seams.
        for i in 1..<FurnitureFilingCabinet.drawerCount {
            box(w - 2 * t, 0.014, 0.02, charcoal, y: plinth + t + CGFloat(i) * slot, z: front - 0.01, parent: shell)
        }
        // Dark interior lining so the carcass reads as hollow behind an open drawer.
        box(w - 2 * t - 0.002, bodyHeight - 2 * t, 0.004, charcoal, y: plinth + bodyHeight / 2, z: -front + t + 0.003, parent: shell)

        // --- Drawers: each an open-topped box with its front panel.
        let gap: CGFloat = 0.006                 // seam between neighbouring fronts
        let frontThickness: CGFloat = 0.02
        let frontHeight = slot - gap
        let frontWidth = w - 0.004
        let boxDepth: CGFloat = d - 0.06         // leaves the rear of the box inside when open
        let boxWidth = w - 2 * t - 0.02
        let boxHeight = slot * 0.72
        let wall: CGFloat = 0.008
        for (index, name) in filingCabinetDrawerNames.enumerated() {
            let drawer = SCNNode()
            drawer.name = name
            drawer.position = filingCabinetDrawerPosition(index: index, open: false)
            root.addChildNode(drawer)
            // Everything below is relative to the drawer root (slot center, closed at z = 0).
            let frontZ = front + frontThickness / 2
            box(frontWidth, frontHeight, frontThickness, paint, y: 0, z: frontZ, chamfer: 0.004, parent: drawer,
                name: "furnitureFilingCabinetDrawerFront")
            // Pull: a chrome bar on two standoffs, upper-middle of the front.
            let pullY = frontHeight * 0.18
            box(0.15, 0.016, 0.014, chrome, y: pullY, z: front + frontThickness + 0.03, chamfer: 0.006, parent: drawer)
            for side in [-1.0, 1.0] as [CGFloat] {
                box(0.012, 0.012, 0.03, chrome, x: side * 0.065, y: pullY, z: front + frontThickness + 0.015, parent: drawer)
            }
            // Label holder above the pull: a thin chrome frame with a blank card.
            let labelY = frontHeight * 0.36
            box(0.095, 0.05, 0.004, chrome, y: labelY, z: front + frontThickness + 0.002, chamfer: 0.001, parent: drawer)
            box(0.083, 0.038, 0.002, card, y: labelY, z: front + frontThickness + 0.0045, parent: drawer)
            // The box itself -- bottom, sides, back, inner front -- in the
            // darker interior gray. Open at the top. Empty.
            let boxBottom = -frontHeight / 2 + 0.03
            let boxCenterZ = front - boxDepth / 2
            box(boxWidth, wall, boxDepth, interior, y: boxBottom + wall / 2, z: boxCenterZ, parent: drawer)
            for side in [-1.0, 1.0] as [CGFloat] {
                box(wall, boxHeight, boxDepth, interior, x: side * (boxWidth / 2 - wall / 2), y: boxBottom + boxHeight / 2,
                    z: boxCenterZ, parent: drawer)
            }
            box(boxWidth, boxHeight, wall, interior, y: boxBottom + boxHeight / 2, z: front - boxDepth + wall / 2, parent: drawer)
            box(boxWidth, boxHeight, wall, interior, y: boxBottom + boxHeight / 2, z: front - wall / 2, parent: drawer)
        }
        return root
    }
}
