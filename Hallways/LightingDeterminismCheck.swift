//
//  LightingDeterminismCheck.swift
//  Hallways
//
//  Sept 22 (Eddie): temporary DEBUG-only instrumentation to answer one
//  question -- does Hallways actually construct the identical Floor 2
//  fluorescent-lighting scene on every launch, or is something in OUR
//  code building/mutating it differently each time? Physical testing
//  has shown the rendered illumination pattern changing between
//  launches with no authored data changed (see FluorescentLight.swift's
//  own history of comments for the full experiment trail). This file
//  captures a deterministic fingerprint of every fluorescent fixture's
//  actual constructed SceneKit state on each launch, compares it
//  against the previous launch's fingerprint (persisted in UserDefaults
//  under a clearly diagnostic key), and prints an unmistakable
//  pass/fail/baseline block to the Xcode console -- plus, on a
//  mismatch, the EXACT fixture/property differences, not just "the
//  fingerprints differ."
//
//  Entirely #if DEBUG-gated (this whole file), so it has zero effect on
//  Release/App Store builds -- consistent with every other dev-only
//  tool in this project (see MazeStore's devJump/devLastJumpedFloorKey
//  for the same convention). Does NOT touch normal Hallways
//  persistence -- it uses its own separate UserDefaults keys.
//
//  IMPORTANT: this file only READS the already-constructed scene graph
//  (via DecoratorTarget.read, exactly the same mechanism
//  DecoratorMode.nodes(for:) already relies on to resolve fixtures) and
//  already-authored MazeStore data. It does not create, mutate, move,
//  rename, or reconfigure anything -- see its own call site in
//  ContentView.swift for confirmation it runs strictly AFTER the scene
//  is fully built and attached to the view.
//
#if DEBUG
import SceneKit
import UIKit

enum LightingDeterminismCheck {

    // MARK: - Process-lifetime rebuild counter (Sept 22, Eddie: in-
    // process rebuild-lifecycle investigation). One number per Floor 2
    // scene (re)construction for as long as the app process is alive --
    // NOT persisted, NOT reset per floor -- so every console block this
    // file prints during one run of the app can be tied back to exactly
    // which rebuild produced it, and two blocks from the SAME rebuild
    // (see the three checkpoint labels ContentView.swift now passes:
    // EARLY / POST / NEXT-RUNLOOP) can be told apart from two blocks
    // from two DIFFERENT rebuilds.
    private static var buildCounter = 0
    static func nextBuildNumber() -> Int {
        buildCounter += 1
        return buildCounter
    }

    // MARK: - Public entry point

    /// Call once per checkpoint, any time after a floor's scene has
    /// been built AND attached to the SCNView. `buildNumber` is this
    /// process's LIGHTBUILD counter value for the rebuild this
    /// checkpoint belongs to (see nextBuildNumber() above); `checkpoint`
    /// is a short human label for WHERE in that rebuild's lifecycle this
    /// call is happening (e.g. "EARLY", "POST", "NEXT-RUNLOOP").
    ///
    /// Calling this more than once per rebuild is intentional and is
    /// how the within-build (not just across-launch) comparison works:
    /// each call compares against whatever this same mechanism last
    /// persisted -- which, for the 2nd/3rd checkpoint of ONE rebuild,
    /// is the 1st/2nd checkpoint of that SAME rebuild (moments earlier),
    /// not a previous app launch. So "IDENTICAL" on a POST or
    /// NEXT-RUNLOOP block means "nothing observable changed between
    /// this checkpoint and the previous one IN THIS SAME REBUILD";
    /// "SCENE CHANGED" there means something mutated the fluorescent
    /// scene state after an earlier checkpoint already ran, which is
    /// exactly the "code after construction" question under
    /// investigation.
    static func run(scene: SCNScene, floor: Int, mazeStore: MazeStore, buildNumber: Int, checkpoint: String) {
        let fixtures = captureFixtures(scene: scene, floor: floor, mazeStore: mazeStore)
        let currentLines = serialize(fixtures)
        let currentState = currentLines.joined(separator: "\n")
        let currentFingerprint = fnv1aHex(currentState)

        let lightCount = fixtures.reduce(0) { $0 + $1.lights.count }

        let stateKey = "debug.lightingDeterminism.floor\(floor).serializedState"
        let fingerprintKey = "debug.lightingDeterminism.floor\(floor).fingerprint"
        let defaults = UserDefaults.standard

        let previousState = defaults.string(forKey: stateKey)
        let previousFingerprint = defaults.string(forKey: fingerprintKey)

        let tag = "[LIGHTBUILD #\(buildNumber)] [\(checkpoint)]"
        let bar = String(repeating: "=", count: 60)

        if previousState == nil || previousFingerprint == nil {
            print(bar)
            print("\(tag) LIGHTING DETERMINISM CHECK")
            print("BASELINE CAPTURED")
            print("Restart Hallways without changing anything.")
            print("Floor: \(floor)")
            print("Fixtures: \(fixtures.count)")
            print("SCNLights: \(lightCount)")
            print("Fingerprint: \(currentFingerprint)")
            print(bar)
        } else if previousFingerprint == currentFingerprint {
            print(bar)
            print("\(tag) LIGHTING DETERMINISM CHECK")
            print("\u{2705} IDENTICAL TO PREVIOUS CHECKPOINT")
            print("Floor: \(floor)")
            print("Fixtures: \(fixtures.count)")
            print("SCNLights: \(lightCount)")
            print("Fingerprint: \(currentFingerprint)")
            print(bar)
        } else {
            print(bar)
            print("\(tag) LIGHTING DETERMINISM CHECK")
            print("\u{1F6A8} SCENE CHANGED SINCE PREVIOUS CHECKPOINT")
            print("Floor: \(floor)")
            print("Previous fingerprint: \(previousFingerprint ?? "?")")
            print("Current fingerprint: \(currentFingerprint)")
            print("")
            print("DIFFERENCES:")
            print("")
            printDifferences(previous: previousState ?? "", current: currentState)
            print(bar)
        }

        defaults.set(currentState, forKey: stateKey)
        defaults.set(currentFingerprint, forKey: fingerprintKey)
    }

    // MARK: - Capture

    private struct LightRecord {
        let name: String
        let fields: [(String, String)] // ordered, deterministic
    }

    private struct FixtureRecord {
        let row: Int
        let col: Int
        let key: String
        let fields: [(String, String)]
        let lights: [LightRecord]
    }

    private static func captureFixtures(scene: SCNScene, floor: Int, mazeStore: MazeStore) -> [FixtureRecord] {
        var results: [FixtureRecord] = []

        // Recursive traversal -- finds every fluorescent fixture root
        // anywhere in the scene graph, however deep, however many.
        // Filtering by DecoratorTarget (not name/position) is the same
        // mechanism DecoratorMode.nodes(for:) already trusts to resolve
        // a fixture reliably.
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let target = DecoratorTarget.read(node),
                  target.kind == .fluorescent,
                  target.floor == floor,
                  case .grid(let coord) = target.location else { return }

            let orientation = mazeStore.fluorescentLights[coord]?.rawValue ?? "missing"
            let level = LightBrightness.level(for: .fluorescent, at: coord, in: mazeStore.lightBrightness)

            var fields: [(String, String)] = []
            fields.append(("nodeName", node.name ?? "<nil>"))
            fields.append(("authoredOrientation", orientation))
            fields.append(("authoredBrightnessLevel", String(level)))
            appendTransformFields(prefix: "fixture", node: node, into: &fields)

            var lights: [LightRecord] = []
            node.enumerateChildNodes { child, _ in
                guard let light = child.light else { return }
                lights.append(captureLight(named: child.name ?? "<unnamed>", node: child, light: light))
            }
            // Deterministic order -- never rely on traversal/Set order.
            lights.sort { $0.name < $1.name }

            let key = "r\(coord.row)c\(coord.col)"
            results.append(FixtureRecord(row: coord.row, col: coord.col, key: key, fields: fields, lights: lights))
        }

        // Deterministic order -- sorted by cell coordinate, never by
        // scene-graph traversal order (which itself depends on `cells`
        // being a Set -- see this file's header comment / the audit
        // report for why that matters).
        results.sort { ($0.row, $0.col) < ($1.row, $1.col) }
        return results
    }

    private static func captureLight(named name: String, node: SCNNode, light: SCNLight) -> LightRecord {
        var fields: [(String, String)] = []
        fields.append(("type", light.type.rawValue))
        fields.append(("areaType", String(describing: light.areaType)))
        fields.append(("areaExtents", formatSIMD3(light.areaExtents)))
        fields.append(("doubleSided", String(light.doubleSided)))
        fields.append(("drawsArea", String(light.drawsArea)))
        fields.append(("castsShadow", String(light.castsShadow)))
        fields.append(("intensity", formatDouble(Double(light.intensity))))
        fields.append(("color", formatColor(light.color)))
        fields.append(("temperature", formatDouble(light.temperature)))
        fields.append(("categoryBitMask", String(node.categoryBitMask)))
        // Spot/attenuation properties don't apply to `.area`, but are
        // captured anyway (cheap, and guards against a silent future
        // regression back toward Spot-relevant values going unnoticed).
        fields.append(("attenuationStartDistance", formatDouble(light.attenuationStartDistance)))
        fields.append(("attenuationEndDistance", formatDouble(light.attenuationEndDistance)))
        fields.append(("attenuationFalloffExponent", formatDouble(light.attenuationFalloffExponent)))
        fields.append(("spotInnerAngle", formatDouble(light.spotInnerAngle)))
        fields.append(("spotOuterAngle", formatDouble(light.spotOuterAngle)))
        appendTransformFields(prefix: "light", node: node, into: &fields)
        return LightRecord(name: name, fields: fields)
    }

    private static func appendTransformFields(prefix: String, node: SCNNode, into fields: inout [(String, String)]) {
        fields.append(("\(prefix).local.position", formatVector3(node.position)))
        fields.append(("\(prefix).local.eulerAngles", formatVector3(node.eulerAngles)))
        fields.append(("\(prefix).local.rotation", formatVector4(node.rotation)))
        fields.append(("\(prefix).local.scale", formatVector3(node.scale)))
        fields.append(("\(prefix).local.transform", formatMatrix4(node.transform)))
        fields.append(("\(prefix).world.position", formatVector3(node.worldPosition)))
        fields.append(("\(prefix).world.orientation", formatVector4Quat(node.worldOrientation)))
        fields.append(("\(prefix).world.transform", formatMatrix4(node.worldTransform)))
    }

    // MARK: - Presentation-state capture (Sept 22, Eddie: closing the
    // presentation-vs-model blind spot)
    //
    // Everything above this point reads MODEL state (node.position,
    // node.transform, node.worldTransform, ...) -- the values OUR code
    // set. `.presentation` is a separate, read-only SceneKit proxy
    // node that reflects what the renderer is ACTUALLY drawing this
    // frame, which can differ from the model while an implicit
    // animation or SCNAction is still in flight (this codebase has
    // hit exactly that bug before -- see presentArrivalInsideElevator's
    // own SCNTransaction.disableActions comment). Two builds can be
    // byte-for-byte identical in model state while still rendering
    // differently if one of them has a fluorescent fixture or Area
    // light whose presentation hasn't caught up to its model yet.
    //
    // Deliberately a SEPARATE, minimal capture path (not folded into
    // captureFixtures/serialize above): it only captures presentation
    // transforms, nothing authored/model, and is persisted under its
    // own UserDefaults keys so it can never contaminate or be
    // contaminated by the model-state run() comparisons above.

    private static func appendPresentationTransformFields(prefix: String, node: SCNNode, into fields: inout [(String, String)]) {
        let p = node.presentation
        fields.append(("\(prefix).presentation.position", formatVector3(p.position)))
        fields.append(("\(prefix).presentation.eulerAngles", formatVector3(p.eulerAngles)))
        fields.append(("\(prefix).presentation.rotation", formatVector4(p.rotation)))
        fields.append(("\(prefix).presentation.scale", formatVector3(p.scale)))
        fields.append(("\(prefix).presentation.transform", formatMatrix4(p.transform)))
        fields.append(("\(prefix).presentation.worldPosition", formatVector3(p.worldPosition)))
        fields.append(("\(prefix).presentation.worldTransform", formatMatrix4(p.worldTransform)))
    }

    private static func capturePresentationFixtures(scene: SCNScene, floor: Int) -> [FixtureRecord] {
        var results: [FixtureRecord] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let target = DecoratorTarget.read(node),
                  target.kind == .fluorescent,
                  target.floor == floor,
                  case .grid(let coord) = target.location else { return }

            var fields: [(String, String)] = []
            appendPresentationTransformFields(prefix: "fixture", node: node, into: &fields)

            var lights: [LightRecord] = []
            node.enumerateChildNodes { child, _ in
                guard child.light != nil else { return }
                var lightFields: [(String, String)] = []
                appendPresentationTransformFields(prefix: "light", node: child, into: &lightFields)
                lights.append(LightRecord(name: child.name ?? "<unnamed>", fields: lightFields))
            }
            lights.sort { $0.name < $1.name }

            let key = "r\(coord.row)c\(coord.col)"
            results.append(FixtureRecord(row: coord.row, col: coord.col, key: key, fields: fields, lights: lights))
        }
        results.sort { ($0.row, $0.col) < ($1.row, $1.col) }
        return results
    }

    /// Call exactly once per rebuild, from the EARLIEST point
    /// `.presentation` is guaranteed to reflect an actually-drawn
    /// frame -- i.e. from inside an SCNSceneRendererDelegate callback
    /// that fires AFTER SceneKit has rendered (see TapNavigationController.
    /// renderer(_:didRenderScene:atTime:)), never from makeUIView
    /// itself (no frame has been drawn yet at that point, so
    /// presentation would be trivially equal to model and this check
    /// would prove nothing).
    static func runPresentationCheck(scene: SCNScene, floor: Int, buildNumber: Int, checkpoint: String) {
        let fixtures = capturePresentationFixtures(scene: scene, floor: floor)
        let currentLines = serialize(fixtures)
        let currentState = currentLines.joined(separator: "\n")
        let currentFingerprint = fnv1aHex(currentState)
        let lightCount = fixtures.reduce(0) { $0 + $1.lights.count }

        let stateKey = "debug.lightingDeterminism.presentation.floor\(floor).serializedState"
        let fingerprintKey = "debug.lightingDeterminism.presentation.floor\(floor).fingerprint"
        let defaults = UserDefaults.standard

        let previousState = defaults.string(forKey: stateKey)
        let previousFingerprint = defaults.string(forKey: fingerprintKey)

        let tag = "[LIGHTBUILD #\(buildNumber)] [\(checkpoint)] [PRESENTATION]"
        let bar = String(repeating: "-", count: 60)

        if previousState == nil || previousFingerprint == nil {
            print(bar)
            print("\(tag) PRESENTATION-STATE CHECK")
            print("BASELINE CAPTURED")
            print("Floor: \(floor)")
            print("Fixtures: \(fixtures.count)")
            print("SCNLights: \(lightCount)")
            print("Fingerprint: \(currentFingerprint)")
            print(bar)
        } else if previousFingerprint == currentFingerprint {
            print(bar)
            print("\(tag) PRESENTATION-STATE CHECK")
            print("\u{2705} IDENTICAL TO PREVIOUS PRESENTATION CHECKPOINT")
            print("Floor: \(floor)")
            print("Fixtures: \(fixtures.count)")
            print("SCNLights: \(lightCount)")
            print("Fingerprint: \(currentFingerprint)")
            print(bar)
        } else {
            print(bar)
            print("\(tag) PRESENTATION-STATE CHECK")
            print("\u{1F6A8} PRESENTATION STATE CHANGED SINCE PREVIOUS PRESENTATION CHECKPOINT")
            print("Floor: \(floor)")
            print("Previous fingerprint: \(previousFingerprint ?? "?")")
            print("Current fingerprint: \(currentFingerprint)")
            print("")
            print("DIFFERENCES:")
            print("")
            printDifferences(previous: previousState ?? "", current: currentState)
            print(bar)
        }

        defaults.set(currentState, forKey: stateKey)
        defaults.set(currentFingerprint, forKey: fingerprintKey)
    }

    // MARK: - Deterministic formatting

    private static func formatDouble(_ v: Double) -> String { String(format: "%.6f", v) }
    private static func formatFloat(_ v: Float) -> String { String(format: "%.6f", v) }

    private static func formatVector3(_ v: SCNVector3) -> String {
        "(\(formatFloat(v.x)), \(formatFloat(v.y)), \(formatFloat(v.z)))"
    }
    private static func formatVector4(_ v: SCNVector4) -> String {
        "(\(formatFloat(v.x)), \(formatFloat(v.y)), \(formatFloat(v.z)), \(formatFloat(v.w)))"
    }
    private static func formatVector4Quat(_ v: SCNQuaternion) -> String {
        "(\(formatFloat(v.x)), \(formatFloat(v.y)), \(formatFloat(v.z)), \(formatFloat(v.w)))"
    }
    private static func formatSIMD3(_ v: SIMD3<Float>) -> String {
        "(\(formatFloat(v.x)), \(formatFloat(v.y)), \(formatFloat(v.z)))"
    }
    private static func formatMatrix4(_ m: SCNMatrix4) -> String {
        let vals = [m.m11, m.m12, m.m13, m.m14,
                    m.m21, m.m22, m.m23, m.m24,
                    m.m31, m.m32, m.m33, m.m34,
                    m.m41, m.m42, m.m43, m.m44]
        return "[" + vals.map(formatFloat).joined(separator: ",") + "]"
    }
    private static func formatColor(_ contents: Any?) -> String {
        guard let color = contents as? UIColor else { return String(describing: contents) }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return "rgba(\(formatDouble(Double(r))),\(formatDouble(Double(g))),\(formatDouble(Double(b))),\(formatDouble(Double(a))))"
    }

    // MARK: - Serialization (deterministic, order fixed by caller)

    /// One line per (fixture, child-or-fixture-itself, property) --
    /// "key=value", where key uniquely and deterministically identifies
    /// that property. This shape is what makes the automatic diff
    /// possible without a full parser: both launches produce the same
    /// KEY for the same logical property, so a plain dictionary compare
    /// finds exactly what changed.
    private static func serialize(_ fixtures: [FixtureRecord]) -> [String] {
        var lines: [String] = []
        for fixture in fixtures {
            for (name, value) in fixture.fields {
                lines.append("\(fixture.key)|fixture|\(name)=\(value)")
            }
            lines.append("\(fixture.key)|lightCount|count=\(fixture.lights.count)")
            for light in fixture.lights {
                for (name, value) in light.fields {
                    lines.append("\(fixture.key)|\(light.name)|\(name)=\(value)")
                }
            }
        }
        // Already built in deterministic order (fixtures sorted by
        // coordinate, lights sorted by name, fields appended in fixed
        // source order) -- an extra explicit sort here costs nothing
        // and removes any doubt.
        lines.sort()
        return lines
    }

    private static func parseLines(_ state: String) -> [String: String] {
        var dict: [String: String] = [:]
        for line in state.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            dict[key] = value
        }
        return dict
    }

    private static func printDifferences(previous: String, current: String) {
        let prevDict = parseLines(previous)
        let currDict = parseLines(current)
        let allKeys = Set(prevDict.keys).union(currDict.keys).sorted()
        var shown = 0
        for key in allKeys {
            let prevValue = prevDict[key]
            let currValue = currDict[key]
            guard prevValue != currValue else { continue }
            // key shape: "<fixtureKey>|<childName>|<property>"
            let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            let label = parts.count == 3 ? "Fixture \(parts[0]), \(parts[1]) -- \(parts[2])" : key
            print("\(label):")
            print("    previous: \(prevValue ?? "<absent>")")
            print("    current:  \(currValue ?? "<absent>")")
            shown += 1
        }
        if shown == 0 {
            print("(fingerprints differed but no line-level differences were found -- this would itself be a bug in this diagnostic's own serialization; report it rather than trusting the fingerprint.)")
        }
    }

    // MARK: - Deterministic hash (FNV-1a 64-bit; NOT Swift's randomized Hasher)

    private static func fnv1aHex(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }
}
#endif
