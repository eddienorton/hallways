import Foundation
import SceneKit
import UIKit

struct RoomDoorPlacement: Codable, Equatable {
    var coord: GridCoordinate
    var direction: Direction
    var roomNumber: Int
    /// A reward makes this a locked room; nil means a mail-delivery door.
    var cashReward: Int? = nil
}

struct RoomAssignment: Codable {
    var coord: GridCoordinate
    var roomNumber: Int
}

struct CarriedRoomItem: Identifiable, Equatable {
    let id: GridCoordinate
    let roomNumber: Int
}

extension HallwayScene {
    static func makeEnvelopeNode(roomNumber: Int?, width: CGFloat = 0.85, spinning: Bool = true) -> SCNNode {
        let texture = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 550)).image { context in
            let cg = context.cgContext
            UIColor(red: 1, green: 0.98, blue: 0.9, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: 900, height: 550))
            UIColor(white: 0.65, alpha: 1).setStroke()
            cg.setLineWidth(5)
            cg.stroke(CGRect(x: 6, y: 6, width: 888, height: 538))
            cg.move(to: CGPoint(x: 8, y: 8))
            cg.addLine(to: CGPoint(x: 450, y: 210))
            cg.addLine(to: CGPoint(x: 892, y: 8))
            cg.strokePath()
            UIColor(red: 0.15, green: 0.35, blue: 0.65, alpha: 1).setFill()
            cg.fill(CGRect(x: 755, y: 35, width: 100, height: 115))
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            let address = roomNumber.map { "To: Rm \($0)" } ?? "Address needed"
            (address as NSString).draw(in: CGRect(x: 30, y: 295, width: 840, height: 130), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 92), .foregroundColor: UIColor(white: 0.1, alpha: 1), .paragraphStyle: centered
            ])
        }
        let root = SCNNode()
        // Two outward-facing planes keep the address readable from either side.
        for back in [false, true] {
            let material = SCNMaterial()
            material.diffuse.contents = texture
            material.lightingModel = .constant
            let plane = SCNPlane(width: width, height: width * 550 / 900)
            plane.materials = [material]
            let face = SCNNode(geometry: plane)
            face.position.z = back ? -0.008 : 0.008
            face.eulerAngles.y = back ? .pi : 0
            root.addChildNode(face)
        }
        if spinning {
            root.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 9)))
        }
        return root
    }

    private static let doorHardwareReflection: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 256, height: 128)).image { context in
            let colors = [UIColor.white.cgColor, UIColor(white: 0.75, alpha: 1).cgColor,
                          UIColor(white: 0.08, alpha: 1).cgColor, UIColor(white: 0.5, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.38, 0.5, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 128), options: [])
            }
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 32, y: 12, width: 22, height: 35))
        }
    }()

    static func makeRoomDoorNode(_ door: RoomDoorPlacement, cellSize: CGFloat) -> SCNNode {
        let root = SCNNode()
        root.name = "roomDoor_\(door.roomNumber)"
        let texture = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 1000)).image { context in
            let cg = context.cgContext
            UIColor(red: 0.74, green: 0.59, blue: 0.39, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: 480, height: 1000))
            // Subtle vertical grain, drawn deterministically at build time.
            for index in 0..<100 {
                let x = CGFloat(index) * 5
                UIColor(red: 0.4, green: 0.25, blue: 0.12, alpha: index % 3 == 0 ? 0.16 : 0.07).setStroke()
                cg.setLineWidth(index % 4 == 0 ? 2 : 1)
                cg.move(to: CGPoint(x: x, y: 0))
                cg.addCurve(to: CGPoint(x: x + 4, y: 1000), control1: CGPoint(x: x + 14, y: 300), control2: CGPoint(x: x - 12, y: 700))
                cg.strokePath()
            }
        }
        func box(_ width: CGFloat, _ height: CGFloat, _ depth: CGFloat, _ color: UIColor, _ x: Float, _ y: Float, _ z: Float) -> SCNNode {
            let geo = SCNBox(width: width, height: height, length: depth, chamferRadius: 0.005)
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.lightingModel = .constant
            geo.materials = [material]
            let node = SCNNode(geometry: geo)
            node.position = SCNVector3(x, y, z)
            root.addChildNode(node)
            return node
        }
        let frameColor = UIColor(red: 0.22, green: 0.16, blue: 0.1, alpha: 1)
        _ = box(1.15, 2.35, 0.09, frameColor, 0, 1.175, 0)
        let panel = box(1.01, 2.27, 0.055, .brown, 0, 1.135, 0.06)
        panel.geometry?.firstMaterial?.diffuse.contents = texture
        let plaqueImage = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 160)).image { _ in
            UIColor(red: 0.15, green: 0.12, blue: 0.09, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 400, height: 160))
            let style = NSMutableParagraphStyle(); style.alignment = .center
            ("\(door.roomNumber)" as NSString).draw(in: CGRect(x: 0, y: 8, width: 400, height: 150), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 120), .foregroundColor: UIColor.white, .paragraphStyle: style
            ])
        }
        let plaque = box(0.46, 0.184, 0.02, .black, 0, 1.8, 0.102)
        plaque.geometry?.firstMaterial?.diffuse.contents = plaqueImage
        _ = box(0.32, 0.085, 0.02, .darkGray, 0, 1.05, 0.105) // mail slot
        // Rounded chrome hardware catches the moving headlamp; the reflection texture
        // provides stylized light/dark reflections even in a dim corridor.
        let chrome = SCNMaterial()
        chrome.lightingModel = .blinn
        chrome.diffuse.contents = UIColor(white: 0.48, alpha: 1)
        chrome.specular.contents = UIColor.white
        chrome.shininess = 0.95
        chrome.reflective.contents = Self.doorHardwareReflection
        chrome.reflective.intensity = 0.65
        func hardware(_ geometry: SCNGeometry, name: String, z: Float) -> SCNNode {
            geometry.materials = [chrome]
            let node = SCNNode(geometry: geometry)
            node.name = name
            node.position = SCNVector3(0.36, 0.98, z)
            root.addChildNode(node)
            return node
        }
        let rose = hardware(SCNCylinder(radius: 0.075, height: 0.018), name: "doorKnobRose", z: 0.1)
        rose.eulerAngles.x = .pi / 2
        let stem = hardware(SCNCylinder(radius: 0.025, height: 0.07), name: "doorKnobStem", z: 0.14)
        stem.eulerAngles.x = .pi / 2
        let knob = SCNSphere(radius: 0.06)
        knob.segmentCount = 32
        let grip = hardware(knob, name: "doorKnob", z: 0.195)
        grip.scale.z = 0.8
        let delta = door.direction.delta
        root.position = SCNVector3(
            Float(CGFloat(door.coord.col) * cellSize + CGFloat(delta.col) * (cellSize / 2 - 0.07)),
            0,
            Float(CGFloat(door.coord.row) * cellSize + CGFloat(delta.row) * (cellSize / 2 - 0.07)))
        switch door.direction {
        case .north: break
        case .south: root.eulerAngles.y = .pi
        case .east: root.eulerAngles.y = -.pi / 2
        case .west: root.eulerAngles.y = .pi / 2
        }
        return root
    }
}
