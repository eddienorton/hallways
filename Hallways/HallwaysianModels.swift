import SceneKit
import UIKit

/// Oct 9 -- HALLWAYSIANS: the building's own objects, alive. Modeled
/// characters built in Blender from CharacterModels/Hallwaysians (one script
/// per character + hallwaysian_kit.py) and bundled as USDZ.
///
/// Every asset is authored in SceneKit's frame (Y up, metres, joints
/// unrotated/unscaled at rest) and carries the SAME named joints the
/// existing code animates, so behaviour is unchanged -- only the body is new.
///
/// REVERSIBLE (Xcode scheme > Run > Arguments):
///   -HallwaysClassicCharacters YES   every classic body
///   -HallwaysClassicJuanita YES      classic Juanita only
///   -HallwaysClassicTinky YES        classic Mr. Tinky only
/// A missing or incomplete asset falls back to the classic body by itself.
enum HallwaysianModel {
    static let classicAllKey = "HallwaysClassicCharacters"

    private static var cache: [String: SCNNode] = [:]
    private static var failed: Set<String> = []

    static func classic(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: classicAllKey) || UserDefaults.standard.bool(forKey: key)
    }

    /// The loaded asset (once per launch), or nil if unusable.
    static func load(_ resource: String, required: [String], bundle: Bundle = .main) -> SCNNode? {
        if let model = cache[resource] { return model }
        guard !failed.contains(resource) else { return nil }
        func fail(_ reason: String) -> SCNNode? {
            failed.insert(resource)
            diag("hallwaysian.unavailable", ["model": resource, "reason": reason])
            return nil
        }
        guard let url = bundle.url(forResource: resource, withExtension: "usdz") else { return fail("assetMissing") }
        let scene: SCNScene
        do { scene = try SCNScene(url: url, options: nil) } catch { return fail("loadError \(error.localizedDescription)") }
        let model = SCNNode()
        model.name = "hallwaysian_\(resource)"
        for child in Array(scene.rootNode.childNodes) { model.addChildNode(child) }
        let missing = required.filter { model.childNode(withName: $0, recursively: true) == nil }
        guard missing.isEmpty else { return fail("missingJoints \(missing.joined(separator: ","))") }
        let materials = tune(model)
        let (lo, hi) = model.boundingBox
        diag("hallwaysian.loaded", ["model": resource, "materials": materials, "height": Double(hi.y - lo.y)])
        cache[resource] = model
        return model
    }

    /// The building has no environment map, so fully metallic surfaces would
    /// read near-black: brass, chrome and tin keep a strong metallic sheen
    /// but carry their colour diffusely. Everything stays physically based.
    @discardableResult
    private static func tune(_ root: SCNNode) -> Int {
        var seen = Set<ObjectIdentifier>()
        root.enumerateHierarchy { node, _ in
            for m in node.geometry?.materials ?? [] where seen.insert(ObjectIdentifier(m)).inserted {
                m.lightingModel = .physicallyBased
                var metal: CGFloat = 0
                if let number = m.metalness.contents as? NSNumber { metal = CGFloat(number.doubleValue) }
                else if let color = m.metalness.contents as? UIColor { color.getWhite(&metal, alpha: nil) }
                if metal > 0.45 { m.metalness.contents = 0.45 }
            }
        }
        return seen.count
    }
}

// MARK: - Juanita

/// Juanita, Hallwaysian: a slate-enamel pillar on a weighted brass base with
/// castors, brass collar, a three-stage TELESCOPING NECK (her signature: it
/// rises with her temper), a broad flat head with bulging frog-set eyes under
/// sly lids, a service bell on her crown, a rubber-stamp right hand and a
/// brass pincer left hand. No mouth.
enum HallwaysianJuanita {
    static let resourceName = "Juanita"
    static let classicKey = "HallwaysClassicJuanita"
    static let requiredNodes = ["adminBody", "adminHead", "adminEyes", "adminPupils",
                                "adminArmPoint", "adminArmRest", "juanitaNeck1", "juanitaNeck2"]
    static var isEnabled: Bool { !HallwaysianModel.classic(classicKey) }

    static func load() -> SCNNode? { HallwaysianModel.load(resourceName, required: requiredNodes) }
    static func makeNode() -> SCNNode? { load()?.clone() }

    /// The neck sections' rest positions (from the asset itself).
    static var neckRest: (SCNVector3, SCNVector3)? {
        guard let model = load(),
              let n1 = model.childNode(withName: "juanitaNeck1", recursively: true),
              let n2 = model.childNode(withName: "juanitaNeck2", recursively: true) else { return nil }
        return (n1.position, n2.position)
    }
    static let neckActionKey = "juanitaNeck"

    /// Her signature move: both neck sections slide up by `rise` (so her head
    /// rises 2 x rise) in `up` seconds, hold for `hold`, then settle back.
    /// No-op on a body without a telescoping neck (the classic stand-in).
    static func raiseNeck(on standIn: SCNNode, rise: Float, up: Double, hold: Double, down: Double = 0.5) {
        guard rise > 0, let rest = neckRest,
              let n1 = standIn.childNode(withName: "juanitaNeck1", recursively: true),
              let n2 = standIn.childNode(withName: "juanitaNeck2", recursively: true) else { return }
        for (node, r) in [(n1, rest.0), (n2, rest.1)] {
            let lift = SCNAction.move(to: SCNVector3(r.x, r.y + rise, r.z), duration: up)
            lift.timingMode = .easeOut
            let settle = SCNAction.move(to: r, duration: down)
            settle.timingMode = .easeInEaseOut
            node.removeAction(forKey: neckActionKey)
            node.runAction(.sequence([lift, .wait(duration: hold), settle]), forKey: neckActionKey)
        }
    }
}

// MARK: - Mr. Tinky

/// Mr. Tinky, Hallwaysian: a tin can on its side on four pencil legs (eraser
/// feet), bottle-cap ears, bead eyes on springs, a coiled-spring tail. Same
/// proportions and joints as TinCanRatModel (tinCanRatBody > tinCanRatLeg0-3,
/// tinCanRatEar0/1, tinCanRatTail); forward is -Z; the game scales him 2x.
enum HallwaysianTinky {
    static let resourceName = "MrTinky"
    static let classicKey = "HallwaysClassicTinky"
    static let requiredNodes = ["tinCanRatBody", "tinCanRatLeg0", "tinCanRatLeg1", "tinCanRatLeg2", "tinCanRatLeg3",
                                "tinCanRatEar0", "tinCanRatEar1", "tinCanRatTail"]
    static var isEnabled: Bool { !HallwaysianModel.classic(classicKey) }

    /// A fresh copy of his body subtree (tinCanRatBody and everything on it),
    /// ready to be a DIRECT child of the rat's root, ears at their rest tilt.
    static func makeBody() -> SCNNode? {
        guard let model = HallwaysianModel.load(resourceName, required: requiredNodes),
              let template = model.childNode(withName: "tinCanRatBody", recursively: true) else { return nil }
        let body = template.clone()
        for (i, side) in [(0, Float(-1)), (1, Float(1))] {
            // The caps are discs with their axis up; the driver tilts them
            // forward from here exactly as it did the classic ears.
            body.childNode(withName: "tinCanRatEar\(i)", recursively: true)?.eulerAngles = SCNVector3(Float.pi / 2, 0, side * 0.35)
        }
        return body
    }
}
