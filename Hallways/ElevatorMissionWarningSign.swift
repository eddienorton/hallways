import SceneKit
import UIKit

/// Runtime-only elevator equipment. Never tagged or registered as an authored object.
@MainActor
final class ElevatorMissionWarningSign {
    struct Content: Equatable {
        let headline: String
        let instruction: String
        var status: String? = nil
    }

    let node = SCNNode()
    private let panelMaterial = SCNMaterial()
    private(set) var content: Content?
    static let panelSize = CGSize(width: 900, height: 1100)

    init() {
        node.name = "systemElevatorMissionSign"
        let yellow = SCNMaterial()
        yellow.diffuse.contents = UIColor(red: 1, green: 0.66, blue: 0.025, alpha: 1)
        yellow.lightingModel = .physicallyBased
        yellow.roughness.contents = 0.48
        let dark = SCNMaterial()
        dark.diffuse.contents = UIColor(white: 0.12, alpha: 1)
        panelMaterial.lightingModel = .constant

        func box(_ parent: SCNNode, _ w: CGFloat, _ h: CGFloat, _ d: CGFloat,
                 _ position: SCNVector3, _ material: SCNMaterial) {
            let geometry = SCNBox(width: w, height: h, length: d, chamferRadius: 0.025)
            geometry.materials = [material]
            let part = SCNNode(geometry: geometry)
            part.position = position
            parent.addChildNode(part)
        }
        // Each leaf pivots at the hinge; local +Z is its printed outside face.
        let angle: Float = 0.22
        let length: Float = 1.62
        let hingeY = length * cos(angle) + 0.065
        for side: Float in [1, -1] {
            let leaf = SCNNode()
            leaf.position.y = hingeY
            leaf.eulerAngles = SCNVector3(-angle, side == 1 ? 0 : .pi, 0)
            node.addChildNode(leaf)
            box(leaf, 1.14, CGFloat(length), 0.075, SCNVector3(0, -length / 2, 0), yellow)
            let panel = SCNPlane(width: 0.96, height: 1.173333333)
            panel.materials = [panelMaterial]
            let face = SCNNode(geometry: panel)
            face.position = SCNVector3(0, -0.82, 0.041)
            leaf.addChildNode(face)
            for x: Float in [-0.46, 0.46] {
                box(node, 0.22, 0.13, 0.25,
                    SCNVector3(x, 0.065, side * length * sin(angle)), dark)
            }
        }
        let hinge = SCNCylinder(radius: 0.075, height: 1.22)
        hinge.materials = [yellow]
        let hingeNode = SCNNode(geometry: hinge)
        hingeNode.position.y = hingeY
        hingeNode.eulerAngles.z = .pi / 2
        node.addChildNode(hingeNode)
        for x: Float in [-0.46, 0.46] {
            box(node, 0.045, 0.045, 0.48, SCNVector3(x, 0.55, 0), dark)
        }
    }

    func place(left: SCNVector3, right: SCNVector3, direction: Direction, cellSize: CGFloat) {
        // Stay within the elevator cell, on the hallway side of the closed doors.
        let scale = Float(min(1, cellSize / 2.4))
        node.scale = SCNVector3(scale, scale, scale)
        let offset = min(Float(cellSize) * 0.30, 0.85)
        node.position = SCNVector3((left.x + right.x) / 2 - Float(direction.delta.col) * offset,
                                   0, (left.z + right.z) / 2 - Float(direction.delta.row) * offset)
        switch direction {
        case .north: node.eulerAngles.y = 0
        case .south: node.eulerAngles.y = .pi
        case .east: node.eulerAngles.y = -.pi / 2
        case .west: node.eulerAngles.y = .pi / 2
        }
    }

    func update(_ value: Content) {
        guard content != value else { return }
        content = value
        let layout = Self.layout(value)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        panelMaterial.diffuse.contents = UIGraphicsImageRenderer(size: Self.panelSize, format: format).image { context in
            UIColor(red: 0.72, green: 0.025, blue: 0.025, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: Self.panelSize))
            layout.manager.drawGlyphs(forGlyphRange: layout.manager.glyphRange(for: layout.container), at: layout.origin)
        }
    }

    struct TextLayout {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer
        let origin: CGPoint
        let bounds: CGRect
        let available: CGRect
    }

    /// Measure and draw with the same TextKit layout. No truncation, line cap, or
    /// minimum font clamp that could silently overflow with future longer copy.
    static func layout(_ content: Content) -> TextLayout {
        let available = CGRect(x: 40, y: 44, width: panelSize.width - 80, height: panelSize.height - 88)
        func measure(_ scale: CGFloat) -> TextLayout {
            let text = NSMutableAttributedString()
            let sections: [(String, CGFloat, UIFont.Weight)] = [
                (content.headline, 110, .heavy), (content.instruction, 94, .bold),
                (content.status ?? "", 72, .semibold)
            ].filter { !$0.0.isEmpty }
            for (index, section) in sections.enumerated() {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byWordWrapping
                paragraph.paragraphSpacing = 32 * scale
                let string = section.0 + (index == sections.count - 1 ? "" : "\n")
                text.append(NSAttributedString(string: string, attributes: [
                    .font: UIFont.systemFont(ofSize: section.1 * scale, weight: section.2),
                    .foregroundColor: UIColor.white, .paragraphStyle: paragraph
                ]))
            }
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: available.width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let bounds = manager.usedRect(for: container)
            return TextLayout(storage: storage, manager: manager, container: container,
                              origin: CGPoint(x: available.minX, y: available.midY - bounds.height / 2 - bounds.minY),
                              bounds: bounds, available: available)
        }
        func fits(_ layout: TextLayout) -> Bool {
            layout.bounds.height <= available.height && layout.bounds.width <= available.width &&
            layout.manager.glyphRange(for: layout.container).length == layout.manager.numberOfGlyphs
        }
        var high: CGFloat = 1
        var low: CGFloat = 1
        var result = measure(low)
        while !fits(result) {
            high = low
            low /= 2
            result = measure(low)
        }
        for _ in 0..<18 {
            let middle = (low + high) / 2
            let candidate = measure(middle)
            if fits(candidate) { low = middle; result = candidate } else { high = middle }
        }
        return result
    }
}
