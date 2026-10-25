import SceneKit
import simd

/// Oct 12 (stability pass) -- DIAGNOSTICS ONLY: a census of the lights that
/// can reach each surface, taken once per floor build (a few seconds after
/// the floor is installed, when its characters are in).
///
/// Why: Floor 3 was once seen with black/dark doors, ceilings and fixtures
/// that "came right" as the player walked; the next run was fine. The
/// leading suspect is SceneKit's limit on lights per node (historically 8):
/// the hallways have no ambient fallback (HallwayScene), each fixture adds
/// two long-reach spots, and the order fixtures are added follows a Swift
/// Set (`cells`), which changes from launch to launch -- so which lights a
/// crowded surface keeps can change between runs. This logs the evidence;
/// it changes nothing in the scene.
///
///   lightCensus        floor, total lights, zero-intensity lights, nodes
///                      reachable by more than 8 lights, the worst count,
///                      and `order`: a fingerprint of the order the fixture
///                      lights sit in the scene graph (differs between a bad
///                      and a good run => the Set-order explanation holds).
///   lightCensus.node   up to 12 of the most crowded surfaces (name, count).
enum LightCensus {
    static let perNodeLimit = 8

    /// Once per floor per app session (a good run and a bad run are different sessions).
    private static var counted: Set<Int> = []

    static func schedule(scene: SCNScene, floor: Int, after seconds: Double = 4) {
        guard !counted.contains(floor) else { return }
        counted.insert(floor)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak scene] in
            guard let scene else { return }
            run(scene: scene, floor: floor)
        }
    }

    static func run(scene: SCNScene, floor: Int) {
        let started = CACurrentMediaTime()
        struct L { let p: SIMD3<Float>; let reach: Float; let mask: Int; let zero: Bool }
        var lights: [L] = []
        var orderHash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a over the fixture lights' positions, in graph order
        scene.rootNode.enumerateHierarchy { n, _ in
            guard let l = n.light, l.type == .omni || l.type == .spot, !n.isHidden else { return }
            let p = n.simdWorldPosition
            let reach = l.attenuationEndDistance > 0 ? Float(l.attenuationEndDistance) : .infinity
            lights.append(L(p: p, reach: reach, mask: l.categoryBitMask, zero: l.intensity <= 0))
            if lights.count <= 64 {
                for v in [p.x, p.y, p.z] where v.isFinite {
                    orderHash ^= UInt64(bitPattern: Int64((v * 10).rounded()))
                    orderHash = orderHash &* 0x100_0000_01b3
                }
            }
        }
        var over = 0, worst = 0, surfaces = 0
        var crowded: [(String, Int, Int)] = []
        scene.rootNode.enumerateHierarchy { n, _ in
            guard let geometry = n.geometry, !n.isHidden else { return }
            surfaces += 1
            let (lo, hi) = geometry.boundingBox                    // this surface only (not its children)
            let corners = [SIMD3<Float>(lo.x, lo.y, lo.z), SIMD3<Float>(hi.x, hi.y, hi.z)].map { n.simdConvertPosition($0, to: nil) }
            let centre = (corners[0] + corners[1]) / 2
            let radius = simd_distance(corners[0], corners[1]) / 2
            var count = 0, zero = 0
            for l in lights where (l.mask & n.categoryBitMask) != 0 && simd_distance(l.p, centre) <= l.reach + radius {
                count += 1
                if l.zero { zero += 1 }
            }
            worst = max(worst, count)
            if count > perNodeLimit {
                over += 1
                crowded.append((n.name ?? n.parent?.name ?? "?", count, zero))
            }
        }
        crowded.sort { $0.1 > $1.1 }
        diag("lightCensus", ["floor": floor, "lights": lights.count, "zeroIntensity": lights.filter { $0.zero }.count,
                             "surfaces": surfaces, "over\(perNodeLimit)": over, "worst": worst,
                             "order": String(orderHash, radix: 16),
                             "ms": Int((CACurrentMediaTime() - started) * 1000)])
        for (name, count, zero) in crowded.prefix(12) {
            diag("lightCensus.node", ["floor": floor, "node": name, "lights": count, "zeroIntensity": zero])
        }
    }
}
