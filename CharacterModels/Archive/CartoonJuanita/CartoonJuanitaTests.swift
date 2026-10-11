import SceneKit
import Testing
@testable import Hallways

/// Oct 9 -- Cartoon Juanita: the bundled model loads in SceneKit and keeps
/// the joint contract the existing animation code relies on. Reads only
/// the app bundle; nothing saved is touched. Simulator only.
@MainActor
struct CartoonJuanitaTests {
    @Test func theModelLoadsWithEveryJointHerAnimationsUse() throws {
        let model = try #require(CartoonJuanita.load())
        for name in CartoonJuanita.requiredNodes + ["adminElbowPoint", "adminElbowRest", "adminHandPoint", "adminHandRest"] {
            #expect(model.childNode(withName: name, recursively: true) != nil, "\(name)")
        }
    }

    // SceneKit's frame: standing on the floor, about 1.8 m tall (bald, no
    // antenna), facing +Z (her lips are in front), her right (pointing) arm
    // on -X, and every joint unrotated at rest (the game sets absolute angles).
    @Test func sheStandsInTheGamesFrame() throws {
        let model = try #require(CartoonJuanita.load())
        let (lo, hi) = model.boundingBox
        #expect(abs(lo.y) < 0.05)
        #expect(hi.y > 1.7 && hi.y < 1.9)
        let lips = try #require(model.childNode(withName: "adminMouth", recursively: true))
        #expect(lips.worldPosition.z > 0.2)
        let point = try #require(model.childNode(withName: "adminArmPoint", recursively: true))
        let rest = try #require(model.childNode(withName: "adminArmRest", recursively: true))
        #expect(point.worldPosition.x < -0.3 && rest.worldPosition.x > 0.3)
        for name in CartoonJuanita.requiredNodes {
            let n = try #require(model.childNode(withName: name, recursively: true))
            #expect(abs(n.eulerAngles.x) + abs(n.eulerAngles.y) + abs(n.eulerAngles.z) < 0.001, "\(name) rotated")
            #expect(abs(n.scale.x - 1) + abs(n.scale.y - 1) + abs(n.scale.z - 1) < 0.001, "\(name) scaled")
        }
        // The pupils glance by moving to absolute x offsets: they sit at the eyes' origin.
        let pupils = try #require(model.childNode(withName: "adminPupils", recursively: true))
        #expect(abs(pupils.position.x) + abs(pupils.position.y) + abs(pupils.position.z) < 0.001)
    }

    // Oct 9: no antenna anywhere -- no node, nothing above the crown.
    @Test func sheHasNoAntenna() throws {
        let model = try #require(CartoonJuanita.load())
        var names: [String] = []
        model.enumerateHierarchy { n, _ in names.append((n.name ?? "").lowercased()) }
        #expect(!names.contains { $0.contains("antenna") })
        let head = try #require(model.childNode(withName: "adminHead", recursively: true))
        let (_, hi) = model.boundingBox
        let (_, headHi) = head.boundingBox
        #expect(abs(hi.y - (head.worldPosition.y + headHi.y)) < 0.01)                  // the crown is the top
    }

    // Each floor build gets its own copy; posing one never poses another.
    @Test func copiesAreIndependent() throws {
        let a = try #require(CartoonJuanita.makeNode())
        let b = try #require(CartoonJuanita.makeNode())
        let armA = try #require(a.childNode(withName: "adminArmPoint", recursively: true))
        let armB = try #require(b.childNode(withName: "adminArmPoint", recursively: true))
        armA.eulerAngles = SCNVector3(0, 0, -1.75)
        #expect(armB.eulerAngles.z == 0)
    }
}
