import SceneKit
import UIKit

enum PaintPalette {
    static let blue = UIColor(red: 0.22, green: 0.48, blue: 0.88, alpha: 1)
}

/// Recolors only the wall panels that belong to one hallway cell.
/// HallwayScene gives those panels unique materials and a per-cell name,
/// so painting one cube cannot retint frames, floors, ceilings, or every
/// other wall that happens to share a theme texture.
///
/// Sept 12: paint must be a TINT over whatever the wall is already
/// showing (brick, a dev pattern, any other theme), not a replacement --
/// baked into a new `diffuse.contents` image via a multiply blend,
/// preserving the original image's pixel dimensions (and therefore its
/// existing wrapS/wrapT/contentsTransform tiling) exactly. This is a
/// one-time composite at paint time, not a per-frame cost.
///
/// SCNMaterial.multiply would be the simpler way to tint, but these
/// walls use lightingModel = .physicallyBased, and SceneKit does not
/// apply `multiply` (or most of the other legacy material slots) under
/// the PBR pipeline -- diffuse is the only channel guaranteed to show up
/// here, hence baking the tint directly into it instead.
///
/// Every material write below is wrapped in a zero-duration
/// SCNTransaction, matching ContentView's applySurface -- SceneKit
/// otherwise cross-fades a material property change over its own
/// implicit ~0.25s default, which is a concrete, if partial, candidate
/// for the reported "not blue yet, then suddenly is" lag.
final class WallPainter {
    static func nodeName(_ coord: GridCoordinate) -> String {
        "cellWall-\(coord.row)-\(coord.col)"
    }

    private weak var scene: SCNScene?
    /// The material's un-tinted look -- whatever it would show if this
    /// cell weren't painted, image or flat fallback color alike. Always
    /// the true original, never the tinted result, so re-tinting (from
    /// updateBase, when a theme/pattern swap changes this out from under
    /// an already-painted wall) never compounds the tint.
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
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            material.diffuse.contents = original
            SCNTransaction.commit()
        }
        paintedMaterials.removeAll()
        originalDiffuse.removeAll()
    }

    /// Theme/pattern swaps rewrite `diffuse.contents`. If that material is
    /// already painted, remember the new look as the un-tinted base and
    /// re-tint from it, so a palette tap or a dev-pattern change can never
    /// wipe progress or leave a flat, un-tinted texture showing.
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
        let id = ObjectIdentifier(material)
        paintedMaterials.insert(id)
        let base = originalDiffuse[id] ?? material.diffuse.contents
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        material.diffuse.contents = Self.tinted(base)
        SCNTransaction.commit()
    }

    /// Multiplies whatever the surface would normally show by the paint
    /// color -- an actual image keeps its detail (brick mortar lines, a
    /// dev pattern's motif) darkened and shifted toward blue, exactly
    /// like a color wash over the existing surface; a flat fallback
    /// color just becomes its own tinted flat color.
    private static func tinted(_ base: Any?) -> Any {
        if let image = base as? UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
            return renderer.image { _ in
                image.draw(at: .zero)
                blue.setFill()
                UIRectFillUsingBlendMode(CGRect(origin: .zero, size: image.size), .multiply)
            }
        }
        if let color = base as? UIColor {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            var pr: CGFloat = 0, pg: CGFloat = 0, pb: CGFloat = 0, pa: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            blue.getRed(&pr, green: &pg, blue: &pb, alpha: &pa)
            return UIColor(red: r * pr, green: g * pg, blue: b * pb, alpha: 1)
        }
        return blue
    }

    private static let blue = PaintPalette.blue
}
