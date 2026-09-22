import SceneKit
import UIKit

/// A rectangular fixture has two axes, not four wall-facing directions.
enum FluorescentOrientation: String, Codable, CaseIterable {
    case northSouth, eastWest

    var title: String { self == .northSouth ? "North–South" : "East–West" }
}

struct FluorescentPlacement: Codable {
    let coord: GridCoordinate
    let orientation: FluorescentOrientation
}

extension HallwayScene {
    /// Flush-mounted steel housing with a recessed prismatic diffuser.
    /// Local long axis is Z (north/south); all parts and the source rotate together.
    static func makeFluorescentLight(orientation: FluorescentOrientation, level: Int, cellSize: CGFloat) -> SCNNode {
        let fixture = SCNNode()
        fixture.name = "authored_fluorescent"
        fixture.eulerAngles.y = orientation == .eastWest ? .pi / 2 : 0

        let housing = SCNMaterial()
        housing.lightingModel = .physicallyBased
        housing.diffuse.contents = UIColor(white: 0.72, alpha: 1)
        housing.metalness.contents = 0.2
        housing.roughness.contents = 0.65

        let diffuser = SCNMaterial()
        diffuser.lightingModel = .physicallyBased
        diffuser.diffuse.contents = UIColor(red: 0.88, green: 0.9, blue: 0.86, alpha: 1)
        diffuser.emission.contents = UIColor(red: 0.8, green: 0.84, blue: 0.78, alpha: 1)
        diffuser.roughness.contents = 0.85

        func box(_ width: CGFloat, _ height: CGFloat, _ length: CGFloat,
                 _ position: SCNVector3, _ material: SCNMaterial, radius: CGFloat = 0.003) {
            let geometry = SCNBox(width: width, height: height, length: length, chamferRadius: radius)
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.position = position
            fixture.addChildNode(node)
        }

        // Top touches the ceiling. The lower rim surrounds, rather than covers,
        // the glowing panel, making it read as a manufactured ceiling fixture.
        box(0.42, 0.06, 1.24, SCNVector3(0, -0.03, 0), housing)
        for x: Float in [-0.2, 0.2] {
            box(0.02, 0.045, 1.24, SCNVector3(x, -0.075, 0), housing)
        }
        for z: Float in [-0.605, 0.605] {
            box(0.38, 0.045, 0.03, SCNVector3(0, -0.075, z), housing)
        }
        box(0.376, 0.015, 1.174, SCNVector3(0, -0.08, 0), diffuser)
        // Small retaining clips, typical of older surface-mounted fixtures.
        for z: Float in [-0.42, 0.42] {
            for x: Float in [-0.19, 0.19] {
                box(0.025, 0.008, 0.035, SCNVector3(x, -0.101, z), housing, radius: 0.001)
            }
        }

        let light = SCNLight()
        light.type = .omni
        light.color = UIColor(red: 0.96, green: 1, blue: 0.94, alpha: 1)
        light.intensity = AuthoredLightKind.fluorescent.intensity(level: level)
        light.attenuationStartDistance = 0
        light.attenuationEndDistance = cellSize * 1.6
        light.attenuationFalloffExponent = 2
        light.castsShadow = false
        let source = SCNNode()
        source.name = "fluorescentLightSource"
        source.position.y = -0.15
        source.light = light
        fixture.addChildNode(source)
        // Sept 21 (ceiling-selection trap fix): this housing's top face is
        // exactly coincident with the ceiling slab's bottom face (by design,
        // "top touches the ceiling") -- SCNHitTest can't reliably break that
        // tie, which was routing taps aimed at the fixture to the ceiling
        // slab's Add-Light target instead. See makeDecoratorHitProxy's own
        // doc comment (DecoratorMode.swift) for the full explanation; this
        // fixture just needs the same invisible, closer-to-camera hit
        // target as a child, no other change.
        fixture.addChildNode(HallwayScene.makeDecoratorHitProxy(cellSize: cellSize))
        return fixture
    }
}
