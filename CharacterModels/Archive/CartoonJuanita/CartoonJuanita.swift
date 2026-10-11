import SceneKit

/// Oct 9 -- CARTOON JUANITA. The modeled, articulated character (the
/// "Cartoon Juanita" concept Eddie and Annette chose: gold bald head (Oct 9:
/// no antenna -- Hallwaysians are not antenna-bearing creatures),
/// big lidded eyes with lashes, a smirk, cream blouse with collar, buttons
/// and name badge, dark pencil skirt, ball-jointed gold arms and legs, black
/// flats) in place of the primitive stand-in.
///
/// The asset, JuanitaCartoon.usdz (in the app bundle), is generated in
/// Blender from CharacterModels/Juanita/build.py -- rebuildable, editable.
/// It is authored in SceneKit's own frame (Y up, facing +Z, metres, every
/// joint node unrotated at rest) and carries the SAME named joints the
/// existing animation code drives, so her behaviour is unchanged:
///   adminBody (breathing, shake) > adminHead (pivot at the neck: tilts,
///   looks) > adminEyes (pivot at eye height: blinks, squint) > adminPupils
///   (at the eyes' origin: glances),
///   adminArmPoint / adminArmRest (shoulder pivots; arms hang along -Y; her
///   right, -X, points). New joints for later poses: adminElbowPoint/Rest,
///   adminHandPoint/Rest, adminMouth.
///
/// REVERSIBLE: launch with `-HallwaysClassicJuanita YES` (Xcode scheme >
/// Run > Arguments) for the original stand-in; a missing or incomplete
/// asset also falls back to it automatically.
enum CartoonJuanita {
    static let resourceName = "JuanitaCartoon"
    static let classicDefaultsKey = "HallwaysClassicJuanita"
    /// The joints the existing animation code needs.
    static let requiredNodes = ["adminBody", "adminHead", "adminEyes", "adminPupils",
                                "adminArmPoint", "adminArmRest"]

    static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: classicDefaultsKey) }

    private static var template: SCNNode?
    private static var loadFailed = false

    /// The loaded model (once per launch), or nil if it can't be used.
    static func load(bundle: Bundle = .main) -> SCNNode? {
        if let template { return template }
        guard !loadFailed else { return nil }
        guard let url = bundle.url(forResource: resourceName, withExtension: "usdz") else {
            return fail("assetMissing")
        }
        let scene: SCNScene
        do { scene = try SCNScene(url: url, options: nil) } catch {
            return fail("loadError \(error.localizedDescription)")
        }
        let model = SCNNode()
        model.name = "cartoonJuanitaModel"
        for child in Array(scene.rootNode.childNodes) { model.addChildNode(child) }
        let missing = requiredNodes.filter { model.childNode(withName: $0, recursively: true) == nil }
        guard missing.isEmpty else { return fail("missingJoints \(missing.joined(separator: ","))") }
        let materials = tuneMaterials(model)
        let (minB, maxB) = model.boundingBox
        diag("juanita.cartoon.loaded", ["materials": materials.count, "names": materials.sorted().joined(separator: ","),
                                        "height": Double(maxB.y - minB.y), "width": Double(maxB.x - minB.x)])
        template = model
        return model
    }

    /// A fresh copy for one floor build (geometry and materials shared).
    static func makeNode() -> SCNNode? {
        load()?.clone()
    }

    private static func fail(_ reason: String) -> SCNNode? {
        loadFailed = true
        diag("juanita.cartoon.unavailable", ["reason": reason])
        return nil
    }

    /// The building has no environment map, so a strongly metallic surface
    /// reads dark: her gold is made satin (mostly diffuse, a metallic sheen).
    /// Everything stays physically based, like the rest of the building.
    @discardableResult
    private static func tuneMaterials(_ root: SCNNode) -> Set<String> {
        var seen = Set<ObjectIdentifier>()
        var names = Set<String>()
        root.enumerateHierarchy { node, _ in
            for m in node.geometry?.materials ?? [] where seen.insert(ObjectIdentifier(m)).inserted {
                m.lightingModel = .physicallyBased
                names.insert(m.name ?? "?")
                let name = (m.name ?? "").lowercased()
                if name.contains("gold") {
                    m.metalness.contents = 0.3
                    m.roughness.contents = 0.38
                }
            }
        }
        return names
    }
}
