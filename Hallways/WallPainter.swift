import SceneKit
import UIKit

enum PaintPalette {
    static let blue = UIColor(red: 0.22, green: 0.48, blue: 0.88, alpha: 1)
}

/// Recolors only the wall panels that belong to one hallway cell.
/// HallwayScene gives those panels unique materials and a per-cell name,
/// so painting one cube cannot retint frames, floors, ceilings, or every
/// other wall that happens to share a theme texture.
final class WallPainter {
    static func nodeName(_ coord: GridCoordinate) -> String {
        "cellWall-\(coord.row)-\(coord.col)"
    }

    private weak var scene: SCNScene?
    private var originalDiffuse: [ObjectIdentifier: Any] = [:]
    private var paintedMaterials = Set<ObjectIdentifier>()

    init(scene: SCNScene) {
        self.scene = scene
    }

    func paint(_ coord: GridCoordinate) {
        scene?.rootNode.enumerateChildNodes { node, _ in
            guard node.name == Self.nodeName(coord), let material = node.geometry?.firstMaterial else { return }
            remember(material)
            applyPaint(to: material)
        }
    }

    func reset() {
        scene?.rootNode.enumerateChildNodes { node, _ in
            guard let material = node.geometry?.firstMaterial else { return }
            let id = ObjectIdentifier(material)
            guard paintedMaterials.contains(id), let original = originalDiffuse[id] else { return }
            material.diffuse.contents = original
            material.emission.contents = UIColor.black
        }
        paintedMaterials.removeAll()
    }

    /// Theme swaps rewrite `diffuse.contents`. If that material is already
    /// painted, keep the new image as the restore-base and put the paint
    /// color back on top so a palette tap cannot wipe progress.
    func updateBase(for material: SCNMaterial) {
        let id = ObjectIdentifier(material)
        guard paintedMaterials.contains(id) else { return }
        originalDiffuse[id] = material.diffuse.contents
        applyPaint(to: material)
    }

    private func remember(_ material: SCNMaterial) {
        let id = ObjectIdentifier(material)
        if originalDiffuse[id] == nil {
            originalDiffuse[id] = material.diffuse.contents
        }
    }

    private func applyPaint(to material: SCNMaterial) {
        paintedMaterials.insert(ObjectIdentifier(material))
        material.diffuse.contents = PaintPalette.blue
        material.emission.contents = UIColor(red: 0.08, green: 0.18, blue: 0.4, alpha: 1)
    }
}
