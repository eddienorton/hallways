import SceneKit
import UIKit

extension HallwayScene {
    /// Frame-local coordinates: +Z projects into the hallway. The picture frame
    /// supplies the wall rotation, so fixture and beam always follow the artwork.
    static func makePictureLight(panelWidth: CGFloat, panelHeight: CGFloat, level: Int) -> SCNNode {
        let fixture = SCNNode()
        fixture.name = "pictureLight"
        // Lower the entire assembly together: frame top is panelHeight/2 + 0.05,
        // and the lowest backplate edge now leaves a 0.015-unit mounting gap.
        fixture.position.y = -0.055
        let brass = SCNMaterial()
        brass.diffuse.contents = UIColor(red: 0.48, green: 0.33, blue: 0.13, alpha: 1)
        brass.metalness.contents = 0.65
        brass.roughness.contents = 0.38
        brass.lightingModel = .physicallyBased
        let barWidth = max(0.22, panelWidth * 0.8) * 0.7
        let barY = Float(panelHeight / 2 + 0.16)
        func box(_ width: CGFloat, _ height: CGFloat, _ depth: CGFloat, at position: SCNVector3) {
            let geometry = SCNBox(width: width, height: height, length: depth, chamferRadius: 0.006)
            geometry.materials = [brass]
            let node = SCNNode(geometry: geometry)
            node.position = position
            fixture.addChildNode(node)
        }
        // Two small backplates and forward support arms; no part crosses the frame.
        for x in [-Float(barWidth * 0.23), Float(barWidth * 0.23)] {
            box(0.045, 0.08, 0.025, at: SCNVector3(x, barY, 0))
            box(0.018, 0.018, 0.24, at: SCNVector3(x, barY, 0.13))
        }
        box(barWidth, 0.065, 0.085, at: SCNVector3(0, barY, 0.26))
        let lens = SCNMaterial()
        lens.lightingModel = .constant
        lens.diffuse.contents = UIColor(red: 0.8, green: 0.65, blue: 0.4, alpha: 1)
        let lensGeometry = SCNBox(width: barWidth * 0.9, height: 0.003, length: 0.025, chamferRadius: 0)
        lensGeometry.materials = [lens]
        let lensNode = SCNNode(geometry: lensGeometry)
        lensNode.position = SCNVector3(0, barY - 0.035, 0.26)
        fixture.addChildNode(lensNode)

        let light = SCNLight()
        light.type = .spot
        light.color = UIColor(red: 1, green: 0.88, blue: 0.68, alpha: 1)
        light.intensity = AuthoredLightKind.picture.intensity(level: level)
        light.spotInnerAngle = 38
        light.spotOuterAngle = 64
        light.attenuationStartDistance = 0
        light.attenuationEndDistance = panelHeight + 0.4
        light.attenuationFalloffExponent = 2
        light.castsShadow = false
        let source = SCNNode()
        source.name = "pictureLightSource"
        source.light = light
        source.position = SCNVector3(0, barY + 0.122, 0.24)
        // SceneKit spots emit along local -Z. Pitch toward the picture center.
        source.eulerAngles.x = -atan2(source.position.y, source.position.z - 0.021)
        fixture.addChildNode(source)
        return fixture
    }
}
