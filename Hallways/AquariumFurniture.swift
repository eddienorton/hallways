//
//  AquariumFurniture.swift
//  Hallways
//
//  Sept 28 (sixth furniture object): a freestanding Aquarium on a cabinet
//  stand -- procedural SceneKit geometry with real depth (gravel, rocks,
//  swaying plants and swimming fish inside the water volume), one soft
//  tank light, and lightweight looping SCNActions for the fish and plants.
//
//  Transparency, kept deliberately simple for stable sorting on iPhone:
//  the glass AND water are ONE transparent box (no nested transparent
//  surfaces to sort against each other). Everything inside it is opaque,
//  so SceneKit draws the contents first and blends the single water
//  volume over them. Black corner posts and trims read as the glass edges.
//
//  Lifecycle: the light, the fish and every animation live INSIDE the
//  aquarium's own node tree. Removing the node (delete, side/axis edit,
//  floor rebuild) removes all of them with it -- no orphans.
//
//  Data lives in MazeStore.aquariums (see FurnitureAquarium). Scenery only:
//  never an ObjectKind, never in MazeStore.objects, never registered with
//  TapNavigationController.
//

import SceneKit
import UIKit

extension HallwayScene {
    static let aquariumWidth: CGFloat = 1.25        // along the hallway axis
    static let aquariumDepth: CGFloat = 0.45        // across the hallway
    static let aquariumStandHeight: CGFloat = 0.75
    static let aquariumWaterHeight: CGFloat = 0.50
    private static let aquariumTrim: CGFloat = 0.03
    private static let aquariumHoodHeight: CGFloat = 0.06
    /// Top of the hood -- the aquarium's overall height (~1.37 m).
    static var aquariumHeight: CGFloat { aquariumStandHeight + aquariumTrim + aquariumWaterHeight + aquariumTrim + aquariumHoodHeight }
    /// Inner water volume (inside the glass edges).
    static var aquariumWaterWidth: CGFloat { aquariumWidth - 0.03 }
    static var aquariumWaterDepth: CGFloat { aquariumDepth - 0.03 }
    static var aquariumWaterBottom: CGFloat { aquariumStandHeight + aquariumTrim }
    private static let aquariumWallClearance: CGFloat = 0.05
    private static let aquariumWallHalfThickness: CGFloat = 0.05

    /// World-space offset from the cell center for an aquarium at
    /// LEFT/RIGHT along its authored hallway axis (same side convention as
    /// the other furniture).
    static func aquariumFloorOffset(position: FloorPosition, orientation: FluorescentOrientation, cellSize: CGFloat) -> (dx: CGFloat, dz: CGFloat) {
        let magnitude = cellSize / 2 - aquariumWallHalfThickness - aquariumWallClearance - aquariumDepth / 2
        let signed = position == .right ? magnitude : -magnitude
        return orientation == .northSouth ? (signed, 0) : (0, signed)
    }

    /// Yaw that turns the aquarium's local front (+z, the cabinet doors)
    /// toward the cell center -- same rule as the Desk and Water Cooler.
    static func aquariumYaw(position: FloorPosition, orientation: FluorescentOrientation) -> Float {
        let isRight = position == .right
        switch orientation {
        case .northSouth: return isRight ? -Float.pi / 2 : Float.pi / 2
        case .eastWest: return isRight ? Float.pi : 0
        }
    }

    /// Builds one complete aquarium -- stand, tank, contents, light and
    /// animations -- tagged as a DECORATE `.aquarium` target and positioned
    /// in world space. Used by BOTH build(fromMaze:) and DecoratorState's
    /// live add/edit. Does not parent the node.
    static func buildAquariumNode(at coord: GridCoordinate, cellSize: CGFloat, floorNumber: Int, aquarium: FurnitureAquarium) -> SCNNode {
        let placement = aquarium.sanitized
        let node = makeAquariumNode()
        node.name = "furnitureAquarium"
        node.eulerAngles.y = aquariumYaw(position: placement.position, orientation: placement.orientation)
        let offset = aquariumFloorOffset(position: placement.position, orientation: placement.orientation, cellSize: cellSize)
        node.position = SCNVector3(Float(CGFloat(coord.col) * cellSize + offset.dx),
                                   0,
                                   Float(CGFloat(coord.row) * cellSize + offset.dz))
        DecoratorTarget(floor: floorNumber, coord: coord, kind: .aquarium).tag(node)
        return node
    }

    /// Walks up from a hit-tested node to the aquarium it belongs to, if any.
    static func aquariumCoordinate(for node: SCNNode) -> GridCoordinate? {
        var current: SCNNode? = node
        while let candidate = current {
            if let target = DecoratorTarget.read(candidate), target.kind == .aquarium { return target.coord }
            current = candidate.parent
        }
        return nil
    }

    private static func makeAquariumNode() -> SCNNode {
        let root = SCNNode()

        func material(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, metalness: CGFloat = 0, roughness: CGFloat = 0.6,
                      emission: UIColor? = nil) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
            m.metalness.contents = metalness
            m.roughness.contents = roughness
            if let emission { m.emission.contents = emission }
            return m
        }
        @discardableResult
        func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, x: CGFloat = 0, y: CGFloat, z: CGFloat = 0,
                 chamfer: CGFloat = 0, parent: SCNNode? = nil, name: String? = nil) -> SCNNode {
            let g = SCNBox(width: w, height: h, length: l, chamferRadius: chamfer)
            g.materials = [m]
            let n = SCNNode(geometry: g)
            n.position = SCNVector3(Float(x), Float(y), Float(z))
            n.name = name
            (parent ?? root).addChildNode(n)
            return n
        }

        let w = aquariumWidth, d = aquariumDepth
        let front = d / 2

        // --- Stand: dark walnut cabinet with two doors, on a black kick.
        let walnut = material(0.24, 0.16, 0.10, roughness: 0.55)
        let walnutDoor = material(0.29, 0.20, 0.13, roughness: 0.5)
        let black = material(0.05, 0.05, 0.06, roughness: 0.4)
        let brass = material(0.62, 0.52, 0.32, metalness: 0.3, roughness: 0.35)
        let kick: CGFloat = 0.06
        box(w - 0.04, kick, d - 0.04, black, y: kick / 2, z: -0.01)
        box(w, aquariumStandHeight - kick, d, walnut, y: kick + (aquariumStandHeight - kick) / 2, chamfer: 0.008,
            name: "furnitureAquariumStand")
        let doorWidth = (w - 0.06) / 2
        let doorHeight = aquariumStandHeight - kick - 0.08
        for side in [-1.0, 1.0] as [CGFloat] {
            let x = side * (doorWidth / 2 + 0.01)
            box(doorWidth, doorHeight, 0.016, walnutDoor, x: x, y: kick + 0.04 + doorHeight / 2, z: front + 0.008, chamfer: 0.004)
            box(0.018, 0.12, 0.02, brass, x: side * 0.05, y: kick + 0.04 + doorHeight * 0.62, z: front + 0.026)
        }

        // --- Tank: bottom trim, four black corner posts, top trim, hood.
        let waterBottom = aquariumWaterBottom
        let waterTop = waterBottom + aquariumWaterHeight
        box(w + 0.01, aquariumTrim, d + 0.01, black, y: aquariumStandHeight + aquariumTrim / 2)
        for sx in [-1.0, 1.0] as [CGFloat] {
            for sz in [-1.0, 1.0] as [CGFloat] {
                box(0.018, aquariumWaterHeight, 0.018, black, x: sx * (w / 2 - 0.009), y: waterBottom + aquariumWaterHeight / 2,
                    z: sz * (d / 2 - 0.009))
            }
        }
        box(w + 0.01, aquariumTrim, d + 0.01, black, y: waterTop + aquariumTrim / 2)
        box(w + 0.02, aquariumHoodHeight, d + 0.02, black, y: waterTop + aquariumTrim + aquariumHoodHeight / 2, chamfer: 0.01,
            name: "furnitureAquariumHood")
        // A glowing strip on the hood's underside: the tank light fixture.
        box(w - 0.12, 0.008, 0.05, material(0.9, 0.95, 1.0, emission: UIColor(red: 0.75, green: 0.9, blue: 1.0, alpha: 1)),
            y: waterTop - 0.006)

        // --- Contents (all opaque), sitting on the gravel inside the water.
        let innerW = aquariumWaterWidth, innerD = aquariumWaterDepth
        let gravelHeight: CGFloat = 0.05
        box(innerW, gravelHeight, innerD, material(0.66, 0.58, 0.45, roughness: 0.95), y: waterBottom + gravelHeight / 2)
        let gravelTop = waterBottom + gravelHeight

        // Rocks: flattened spheres half-buried in the gravel.
        let rock = material(0.42, 0.42, 0.44, roughness: 0.9)
        for (x, z, r, sy) in [(-0.34, -0.08, 0.075, 0.6), (-0.24, -0.12, 0.05, 0.7), (0.30, 0.02, 0.06, 0.55), (0.05, -0.13, 0.045, 0.8)] as [(CGFloat, CGFloat, CGFloat, Float)] {
            let s = SCNSphere(radius: r)
            s.segmentCount = 14
            s.materials = [rock]
            let n = SCNNode(geometry: s)
            n.position = SCNVector3(Float(x), Float(gravelTop), Float(z))
            n.scale = SCNVector3(1.2, sy, 1)
            root.addChildNode(n)
        }

        // Plants: tall tapered blades in clumps at the back, gently swaying.
        let leaf = material(0.16, 0.55, 0.24, roughness: 0.7, emission: UIColor(red: 0.02, green: 0.06, blue: 0.02, alpha: 1))
        let leafDark = material(0.10, 0.40, 0.18, roughness: 0.7, emission: UIColor(red: 0.01, green: 0.04, blue: 0.02, alpha: 1))
        let clumps: [(x: CGFloat, z: CGFloat, count: Int)] = [(-0.46, -0.13, 5), (0.44, -0.12, 4), (-0.10, -0.15, 3)]
        for (clumpIndex, clump) in clumps.enumerated() {
            for i in 0..<clump.count {
                let height = 0.18 + CGFloat((i * 37 + clumpIndex * 11) % 17) / 100  // 0.18-0.34, varied
                let blade = SCNCone(topRadius: 0.002, bottomRadius: 0.014, height: height)
                blade.radialSegmentCount = 8
                blade.materials = [(i + clumpIndex) % 2 == 0 ? leaf : leafDark]
                let pivot = SCNNode() // rotates about the blade's base
                pivot.position = SCNVector3(Float(clump.x + CGFloat(i - clump.count / 2) * 0.025),
                                            Float(gravelTop),
                                            Float(clump.z + CGFloat(i % 2) * 0.03))
                let bladeNode = SCNNode(geometry: blade)
                bladeNode.position.y = Float(height / 2)
                pivot.addChildNode(bladeNode)
                pivot.eulerAngles = SCNVector3(Float(i % 3 - 1) * 0.12, 0, Float(i % 2 == 0 ? 0.1 : -0.1))
                let sway = CGFloat(0.06 + Double(i % 3) * 0.02)
                let period = 2.2 + Double((i + clumpIndex) % 4) * 0.35
                let swayAction = SCNAction.sequence([
                    .rotateBy(x: sway, y: 0, z: -sway, duration: period),
                    .rotateBy(x: -sway, y: 0, z: sway, duration: period),
                ])
                swayAction.timingMode = .easeInEaseOut
                pivot.runAction(.repeatForever(swayAction), forKey: "aquariumSway")
                root.addChildNode(pivot)
            }
        }

        // Fish: each swims a calm back-and-forth lane inside the water,
        // turning around at each end instead of swimming backward.
        let fishSpecs: [(color: UIColor, size: CGFloat, y: CGFloat, z: CGFloat, halfRun: CGFloat, duration: Double, delay: Double)] = [
            (UIColor(red: 1.00, green: 0.50, blue: 0.10, alpha: 1), 1.0, 0.30, 0.04, 0.46, 7.0, 0.0),
            (UIColor(red: 0.98, green: 0.84, blue: 0.20, alpha: 1), 0.8, 0.20, -0.06, 0.40, 5.5, 1.3),
            (UIColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1), 0.9, 0.38, -0.02, 0.44, 8.5, 2.6),
            (UIColor(red: 0.90, green: 0.22, blue: 0.20, alpha: 1), 0.7, 0.14, 0.09, 0.36, 6.2, 0.7),
            (UIColor(red: 0.80, green: 0.82, blue: 0.86, alpha: 1), 1.1, 0.25, 0.06, 0.42, 9.5, 3.4),
        ]
        for (index, spec) in fishSpecs.enumerated() {
            let lane = SCNNode()
            lane.name = "furnitureAquariumFish"
            lane.position = SCNVector3(Float(-spec.halfRun), Float(waterBottom + spec.y), Float(spec.z))
            root.addChildNode(lane)
            let fish = makeAquariumFish(color: spec.color, size: 0.042 * spec.size)
            lane.addChildNode(fish)
            // Swim right, turn, swim back, turn -- forever. The lane moves;
            // the fish itself (facing +x) turns with the lane's heading.
            let run = spec.halfRun * 2
            let out = SCNAction.moveBy(x: run, y: 0, z: 0, duration: spec.duration)
            out.timingMode = .easeInEaseOut
            let back = SCNAction.moveBy(x: -run, y: 0, z: 0, duration: spec.duration)
            back.timingMode = .easeInEaseOut
            let turn = SCNAction.rotateBy(x: 0, y: .pi, z: 0, duration: 0.6)
            turn.timingMode = .easeInEaseOut
            lane.runAction(.sequence([.wait(duration: spec.delay),
                                      .repeatForever(.sequence([out, turn, back, turn]))]), forKey: "aquariumSwim")
            // A gentle, independent bob.
            let bobHeight = CGFloat(0.012 + Double(index % 3) * 0.006)
            let bob = SCNAction.sequence([.moveBy(x: 0, y: bobHeight, z: 0, duration: 1.4 + Double(index) * 0.2),
                                          .moveBy(x: 0, y: -bobHeight, z: 0, duration: 1.4 + Double(index) * 0.2)])
            bob.timingMode = .easeInEaseOut
            fish.runAction(.repeatForever(bob), forKey: "aquariumBob")
        }

        // --- The water (and glass): ONE transparent volume over the opaque
        // contents. Slight emission keeps it reading as lit water even in a
        // dim hall. Not written to depth, so everything behind stays visible.
        let water = SCNMaterial()
        water.lightingModel = .physicallyBased
        water.diffuse.contents = UIColor(red: 0.45, green: 0.72, blue: 0.85, alpha: 1)
        water.emission.contents = UIColor(red: 0.03, green: 0.09, blue: 0.12, alpha: 1)
        water.metalness.contents = 0.0
        water.roughness.contents = 0.08
        water.transparency = 0.22
        water.transparencyMode = .aOne
        water.writesToDepthBuffer = false
        water.isDoubleSided = false
        box(innerW, aquariumWaterHeight, innerD, water, y: waterBottom + aquariumWaterHeight / 2, name: "furnitureAquariumWater")

        // --- One soft light under the hood, for the contents. Short reach
        // (about a meter), so it lights the tank, not the room.
        let light = SCNLight()
        light.type = .omni
        light.color = UIColor(red: 0.80, green: 0.92, blue: 1.0, alpha: 1)
        light.intensity = 90
        light.attenuationStartDistance = 0.1
        light.attenuationEndDistance = 1.0
        light.attenuationFalloffExponent = 2
        light.castsShadow = false
        let lightNode = SCNNode()
        lightNode.name = "furnitureAquariumLight"
        lightNode.light = light
        lightNode.position = SCNVector3(0, Float(waterTop - 0.05), 0)
        root.addChildNode(lightNode)

        return root
    }

    /// One procedural fish facing +x: an elongated body, a forked tail
    /// that wags, a dorsal fin, and two eyes.
    private static func makeAquariumFish(color: UIColor, size: CGFloat) -> SCNNode {
        let fish = SCNNode()
        let skin = SCNMaterial()
        skin.lightingModel = .physicallyBased
        skin.diffuse.contents = color
        skin.roughness.contents = 0.45
        skin.metalness.contents = 0.0
        skin.emission.contents = color.withAlphaComponent(1).blended(withFraction: 0.85, of: .black)
        let fin = skin.copy() as! SCNMaterial
        fin.isDoubleSided = true

        let body = SCNSphere(radius: size)
        body.segmentCount = 16
        body.materials = [skin]
        let bodyNode = SCNNode(geometry: body)
        bodyNode.scale = SCNVector3(1.7, 1.0, 0.55)
        fish.addChildNode(bodyNode)

        // Tail: a flattened cone, tip toward the body, pivoting at the joint.
        let tailPivot = SCNNode()
        tailPivot.position = SCNVector3(Float(-size * 1.55), 0, 0)
        let tail = SCNCone(topRadius: 0, bottomRadius: size * 0.85, height: size * 1.1)
        tail.radialSegmentCount = 12
        tail.materials = [fin]
        let tailNode = SCNNode(geometry: tail)
        tailNode.eulerAngles.z = -Float.pi / 2          // cone tip now points +x (toward the body)
        tailNode.position = SCNVector3(Float(-size * 0.5), 0, 0)
        tailNode.scale = SCNVector3(1, 1, 0.25)          // flat, like a fin
        tailPivot.addChildNode(tailNode)
        fish.addChildNode(tailPivot)
        let wag = SCNAction.sequence([.rotateBy(x: 0, y: 0.45, z: 0, duration: 0.28),
                                      .rotateBy(x: 0, y: -0.9, z: 0, duration: 0.56),
                                      .rotateBy(x: 0, y: 0.45, z: 0, duration: 0.28)])
        tailPivot.runAction(.repeatForever(wag), forKey: "aquariumWag")

        // Dorsal fin.
        let dorsal = SCNCone(topRadius: 0, bottomRadius: size * 0.45, height: size * 0.7)
        dorsal.radialSegmentCount = 10
        dorsal.materials = [fin]
        let dorsalNode = SCNNode(geometry: dorsal)
        dorsalNode.position = SCNVector3(Float(-size * 0.2), Float(size * 0.95), 0)
        dorsalNode.scale = SCNVector3(1.4, 1, 0.2)
        dorsalNode.eulerAngles.z = 0.35
        fish.addChildNode(dorsalNode)

        // Eyes.
        let eye = SCNMaterial()
        eye.lightingModel = .constant
        eye.diffuse.contents = UIColor(white: 0.03, alpha: 1)
        for side in [-1.0, 1.0] as [Float] {
            let e = SCNSphere(radius: size * 0.16)
            e.materials = [eye]
            let n = SCNNode(geometry: e)
            n.position = SCNVector3(Float(size * 1.05), Float(size * 0.22), side * Float(size * 0.42))
            fish.addChildNode(n)
        }
        return fish
    }
}

private extension UIColor {
    /// Mixes this color toward `other` by `fraction` (0 = self, 1 = other).
    func blended(withFraction fraction: CGFloat, of other: UIColor) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * fraction, green: g1 + (g2 - g1) * fraction,
                       blue: b1 + (b2 - b1) * fraction, alpha: a1 + (a2 - a1) * fraction)
    }
}
