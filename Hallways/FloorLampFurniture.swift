//
//  FloorLampFurniture.swift
//  Hallways
//
//  Sept 28 (fifth furniture object): a Floor Lamp -- the first furniture
//  whose job is to light the space around it. Procedural SceneKit
//  geometry (weighted bronze base, slender pole with a switch collar,
//  socket, bulb, tapered linen drum shade) plus ONE local warm omni
//  SCNLight inside the shade.
//
//  Lifecycle: the light lives INSIDE the lamp's own node tree, and every
//  state change (on/off, side, axis) replaces the whole lamp node with a
//  freshly built one (see DecoratorState.rebuildFloorLamp). Deleting the
//  lamp or rebuilding the floor therefore removes its light with it --
//  there is never a second, detached light to leak or duplicate.
//
//  Data lives in MazeStore.floorLamps (see FurnitureFloorLamp). Scenery
//  for gameplay purposes: never an ObjectKind, never in MazeStore.objects,
//  never registered with TapNavigationController. A Play-mode tap on it
//  toggles it (ContentView's tap handler -> DecoratorState.toggleFloorLamp).
//

import SceneKit
import UIKit

extension HallwayScene {
    static let floorLampHeight: CGFloat = 1.62       // floor to the top of the shade
    static let floorLampShadeBottomRadius: CGFloat = 0.22
    static let floorLampShadeTopRadius: CGFloat = 0.15
    static let floorLampShadeHeight: CGFloat = 0.30
    static let floorLampBaseRadius: CGFloat = 0.16
    /// Height of the bulb and its light (the middle of the shade).
    static let floorLampLightHeight: CGFloat = 1.45
    /// Local accent light: roughly a wall sconce at level 2 (Hallways'
    /// wall lights run 100...460 over the same 0.2 x cell -> 2 x cell
    /// omni falloff), warmer, and with a shorter reach (~1.1 cells) so it
    /// lights its own corner of the hallway, not the building.
    static let floorLampIntensity: CGFloat = 190
    /// Sept 28 (brightness calibration, from on-device testing): the first
    /// brightness pass used these multiples of floorLampIntensity for UI
    /// levels 1...5 (47.5, 95, 190, 285, 380). Eddie found its level 1
    /// still too bright to be the minimum and its level 5 washing surfaces
    /// out, with its "3.5" (237.5) a good practical maximum. Kept here only
    /// as the reference scale the calibrated levels below are defined on.
    private static let floorLampFirstPassScale: [CGFloat] = [0.25, 0.5, 1.0, 1.5, 2.0]

    /// Intensity at a point on that first-pass scale: piecewise-linear
    /// between its whole levels, and proportional (from zero) below level 1,
    /// so 0.25 means 25% of the old level 1.
    private static func floorLampFirstPassIntensity(at value: CGFloat) -> CGFloat {
        let scale = floorLampFirstPassScale
        if value <= 1 { return floorLampIntensity * scale[0] * max(0, value) }
        let clamped = min(value, CGFloat(scale.count))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lower + 1, scale.count)
        let fraction = clamped - CGFloat(lower)
        let lowerMultiple = scale[lower - 1]
        let upperMultiple = scale[upper - 1]
        return floorLampIntensity * (lowerMultiple + (upperMultiple - lowerMultiple) * fraction)
    }

    /// The calibrated UI levels, expressed on the first-pass scale: UI 1 =
    /// 0.25 (25% of the old level 1), UI 5 = 3.5 (the old "3.5"), and 2-4
    /// evenly between -- 0.25, 1.0625, 1.875, 2.6875, 3.5. Resulting SCNLight
    /// intensities: about 11.9, 50.5, 89.1, 160.3, 237.5.
    private static let floorLampCalibratedLevels: [CGFloat] = [0.25, 1.0625, 1.875, 2.6875, 3.5]

    /// Per-lamp brightness (FurnitureFloorLamp.brightness, UI 1...5) ->
    /// SCNLight intensity when the lamp is ON. The one conversion point;
    /// OFF never reaches here (an off lamp has no light at all).
    static func floorLampIntensity(brightness: Int) -> CGFloat {
        let range = FurnitureFloorLamp.brightnessRange
        let level = min(range.upperBound, max(range.lowerBound, brightness))
        return floorLampFirstPassIntensity(at: floorLampCalibratedLevels[level - range.lowerBound])
    }
    private static let floorLampWallClearance: CGFloat = 0.04
    private static let floorLampWallHalfThickness: CGFloat = 0.05

    /// World-space offset from the cell center for a lamp at LEFT/RIGHT
    /// along its authored hallway axis (same side convention as the other
    /// furniture). The shade -- the widest part -- clears the wall face.
    static func floorLampFloorOffset(position: FloorPosition, orientation: FluorescentOrientation, cellSize: CGFloat) -> (dx: CGFloat, dz: CGFloat) {
        let magnitude = cellSize / 2 - floorLampWallHalfThickness - floorLampWallClearance - floorLampShadeBottomRadius
        let signed = position == .right ? magnitude : -magnitude
        return orientation == .northSouth ? (signed, 0) : (0, signed)
    }

    /// Builds one complete lamp -- geometry, its ON/OFF look, and its own
    /// light (lit only when ON) -- tagged as a DECORATE `.floorLamp`
    /// target and positioned in world space. Used by BOTH build(fromMaze:)
    /// and DecoratorState's live add/edit/toggle. Does not parent the node.
    static func buildFloorLampNode(at coord: GridCoordinate, cellSize: CGFloat, floorNumber: Int, lamp: FurnitureFloorLamp) -> SCNNode {
        let placement = lamp.sanitized
        let node = makeFloorLampNode(isOn: placement.isOn, brightness: placement.brightness, cellSize: cellSize)
        node.name = "furnitureFloorLamp"
        let offset = floorLampFloorOffset(position: placement.position, orientation: placement.orientation, cellSize: cellSize)
        node.position = SCNVector3(Float(CGFloat(coord.col) * cellSize + offset.dx),
                                   0,
                                   Float(CGFloat(coord.row) * cellSize + offset.dz))
        DecoratorTarget(floor: floorNumber, coord: coord, kind: .floorLamp).tag(node)
        return node
    }

    /// Walks up from a hit-tested node to the lamp it belongs to, if any
    /// (the lamp root is the one node carrying the `.floorLamp` tag).
    static func floorLampCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let target = DecoratorTarget.read(candidate), target.kind == .floorLamp { return target.coord }
            current = candidate.parent
        }
        return nil
    }

    private static func makeFloorLampNode(isOn: Bool, brightness: Int, cellSize: CGFloat) -> SCNNode {
        let root = SCNNode()

        func material(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, metalness: CGFloat = 0, roughness: CGFloat = 0.5) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
            m.metalness.contents = metalness
            m.roughness.contents = roughness
            return m
        }
        @discardableResult
        func add(_ geometry: SCNGeometry, _ materials: [SCNMaterial], at y: CGFloat, name: String? = nil) -> SCNNode {
            geometry.materials = materials
            let n = SCNNode(geometry: geometry)
            n.position = SCNVector3(0, Float(y), 0)
            n.name = name
            root.addChildNode(n)
            return n
        }

        // Dark brushed bronze. Metalness kept low on purpose -- near-1.0
        // PBR metal blackens under Hallways' no-environment lighting.
        let bronze = material(0.30, 0.25, 0.20, metalness: 0.35, roughness: 0.35)

        // Weighted round base with a soft conical boss.
        add(SCNCylinder(radius: floorLampBaseRadius, height: 0.025), [bronze], at: 0.0125)
        add(SCNCone(topRadius: 0.025, bottomRadius: 0.07, height: 0.045), [bronze], at: 0.025 + 0.0225)

        // Slender pole, with a small switch collar partway up.
        let poleBottom: CGFloat = 0.07
        let socketBottom = floorLampLightHeight - 0.10
        add(SCNCylinder(radius: 0.012, height: socketBottom - poleBottom), [bronze], at: (poleBottom + socketBottom) / 2)
        add(SCNCylinder(radius: 0.02, height: 0.035), [bronze], at: 1.0)

        // Socket and bulb.
        add(SCNCylinder(radius: 0.02, height: 0.06), [bronze], at: socketBottom + 0.03)
        let bulbMaterial = SCNMaterial()
        if isOn {
            bulbMaterial.lightingModel = .constant
            bulbMaterial.diffuse.contents = UIColor(red: 1.0, green: 0.93, blue: 0.78, alpha: 1)
            bulbMaterial.emission.contents = UIColor(red: 1.0, green: 0.86, blue: 0.62, alpha: 1)
        } else {
            bulbMaterial.lightingModel = .physicallyBased
            bulbMaterial.diffuse.contents = UIColor(white: 0.82, alpha: 1)
            bulbMaterial.roughness.contents = 0.25
            bulbMaterial.metalness.contents = 0.0
        }
        add(SCNSphere(radius: 0.045), [bulbMaterial], at: floorLampLightHeight - 0.01, name: "furnitureFloorLampBulb")

        // Tapered linen drum shade, open at top and bottom (its two caps get
        // an invisible material), visible inside and out. When ON its
        // fabric glows warmly -- restrained, so it reads as lit linen, not
        // a light blob; the real illumination comes from the light below.
        let shade = SCNMaterial()
        shade.lightingModel = .physicallyBased
        shade.diffuse.contents = UIColor(red: 0.90, green: 0.85, blue: 0.74, alpha: 1)
        shade.metalness.contents = 0.0
        shade.roughness.contents = 0.9
        shade.isDoubleSided = true
        if isOn {
            shade.emission.contents = UIColor(red: 0.50, green: 0.38, blue: 0.22, alpha: 1)
        }
        let openCap = SCNMaterial()
        openCap.transparency = 0
        openCap.writesToDepthBuffer = false
        let shadeCenterY = floorLampHeight - floorLampShadeHeight / 2
        add(SCNCone(topRadius: floorLampShadeTopRadius, bottomRadius: floorLampShadeBottomRadius, height: floorLampShadeHeight),
            [shade, openCap, openCap], at: shadeCenterY, name: "furnitureFloorLampShade")

        // The one real light, only when ON. When OFF there is simply no
        // light node at all, so an off lamp contributes nothing.
        if isOn {
            let light = SCNLight()
            light.type = .omni
            light.color = UIColor(red: 1.0, green: 0.80, blue: 0.56, alpha: 1)
            light.intensity = floorLampIntensity(brightness: brightness)
            light.attenuationStartDistance = cellSize * 0.1
            light.attenuationEndDistance = cellSize * 1.1
            light.attenuationFalloffExponent = 2
            light.castsShadow = false
            let lightNode = SCNNode()
            lightNode.name = "furnitureFloorLampLight"
            lightNode.light = light
            lightNode.position = SCNVector3(0, Float(floorLampLightHeight), 0)
            root.addChildNode(lightNode)
        }

        // Invisible, generously sized touch target around the pole, so the
        // whole lamp is easy to tap, not just the shade. It never renders
        // (transparency 0, no depth writes) but is still hit-testable.
        let proxyMaterial = SCNMaterial()
        proxyMaterial.transparency = 0
        proxyMaterial.writesToDepthBuffer = false
        proxyMaterial.readsFromDepthBuffer = false
        add(SCNCylinder(radius: 0.14, height: floorLampHeight - floorLampShadeHeight), [proxyMaterial],
            at: (floorLampHeight - floorLampShadeHeight) / 2, name: "furnitureFloorLampTouchTarget")

        return root
    }
}
