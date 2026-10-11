import SceneKit
import Testing
@testable import Hallways

/// Oct 9 -- Hallwaysians: the bundled Juanita and Mr. Tinky models load in
/// SceneKit and keep the joint contracts the existing code animates. Reads
/// only the app bundle; nothing saved is touched. Simulator only.
@MainActor
struct HallwaysianModelTests {
    // JUANITA -----------------------------------------------------------

    @Test func juanitaLoadsWithEveryJointHerAnimationsUse() throws {
        let model = try #require(HallwaysianJuanita.load())
        for name in HallwaysianJuanita.requiredNodes + ["adminElbowPoint", "adminElbowRest", "adminHandPoint", "adminHandRest"] {
            #expect(model.childNode(withName: name, recursively: true) != nil, "\(name)")
        }
    }

    // SceneKit frame: on the floor, ~1.85 m to the top of her bell, facing +Z
    // (her eyes in front), her stamp (pointing) arm on -X; joints unrotated.
    @Test func juanitaStandsInTheGamesFrame() throws {
        let model = try #require(HallwaysianJuanita.load())
        let (lo, hi) = model.boundingBox
        #expect(abs(lo.y) < 0.03)
        #expect(hi.y > 1.75 && hi.y < 1.95)
        let eyes = try #require(model.childNode(withName: "adminEyes", recursively: true))
        var eyeZ: Float = -1
        eyes.enumerateHierarchy { n, _ in if n.geometry != nil { eyeZ = max(eyeZ, n.worldPosition.z) } }
        #expect(eyeZ > 0)
        let point = try #require(model.childNode(withName: "adminArmPoint", recursively: true))
        let rest = try #require(model.childNode(withName: "adminArmRest", recursively: true))
        #expect(point.worldPosition.x < -0.15 && rest.worldPosition.x > 0.15)
        for name in HallwaysianJuanita.requiredNodes {
            let n = try #require(model.childNode(withName: name, recursively: true))
            #expect(abs(n.eulerAngles.x) + abs(n.eulerAngles.y) + abs(n.eulerAngles.z) < 0.001, "\(name) rotated")
            #expect(abs(n.scale.x - 1) + abs(n.scale.y - 1) + abs(n.scale.z - 1) < 0.001, "\(name) scaled")
        }
        let pupils = try #require(model.childNode(withName: "adminPupils", recursively: true))
        #expect(abs(pupils.position.x) + abs(pupils.position.y) + abs(pupils.position.z) < 0.001)
    }

    // Her telescoping neck: two nested sections above the collar, the head
    // riding on the top one -- raising them lifts her head.
    @Test func juanitasNeckTelescopes() throws {
        let node = try #require(HallwaysianJuanita.makeNode())
        let n1 = try #require(node.childNode(withName: "juanitaNeck1", recursively: true))
        let n2 = try #require(node.childNode(withName: "juanitaNeck2", recursively: true))
        let head = try #require(node.childNode(withName: "adminHead", recursively: true))
        #expect(n2.parent === n1)
        var p: SCNNode? = head.parent
        var underNeck = false
        while let q = p { if q === n2 { underNeck = true }; p = q.parent }
        #expect(underNeck)
        let before = head.worldPosition.y
        n1.position.y += 0.1; n2.position.y += 0.1
        #expect(abs(head.worldPosition.y - before - 0.2) < 0.001)
        #expect(HallwaysianJuanita.neckRest != nil)
    }

    @Test func noJuanitaPartIsAnAntenna() throws {
        let model = try #require(HallwaysianJuanita.load())
        var names: [String] = []
        model.enumerateHierarchy { n, _ in names.append((n.name ?? "").lowercased()) }
        #expect(!names.contains { $0.contains("antenna") })
    }

    // MR. TINKY ---------------------------------------------------------

    @Test func tinkyKeepsTheRatsJoints() throws {
        let body = try #require(HallwaysianTinky.makeBody())
        #expect(body.name == "tinCanRatBody")
        for name in HallwaysianTinky.requiredNodes where name != "tinCanRatBody" {
            #expect(body.childNode(withName: name, recursively: true) != nil, "\(name)")
        }
        // Ears start at the classic rest tilt (the driver animates from there).
        let ear0 = try #require(body.childNode(withName: "tinCanRatEar0", recursively: true))
        #expect(abs(ear0.eulerAngles.x - .pi / 2) < 0.001 && abs(ear0.eulerAngles.z + 0.35) < 0.001)
    }

    // Same proportions as the classic rat: legs reach the floor from bodyHeight,
    // the face is on the -Z (forward) lid, the tail off the +Z (back) lid.
    @Test func tinkyHasTheClassicProportions() throws {
        let root = TinCanRatModel.make()
        let body = try #require(root.childNode(withName: "tinCanRatBody", recursively: false))
        #expect(abs(body.position.y - TinCanRatModel.bodyHeight) < 0.001)
        let (lo, hi) = body.boundingBox
        #expect(abs((body.position.y + lo.y)) < 0.01)                         // eraser feet on the floor
        #expect(hi.y + body.position.y < 0.35)
        let tail = try #require(body.childNode(withName: "tinCanRatTail", recursively: true))
        #expect(tail.position.z > 0.05)
        let leg0 = try #require(body.childNode(withName: "tinCanRatLeg0", recursively: true))
        #expect(leg0.position.z < 0 && leg0.position.x < 0)                     // front-left
        var everyNodeTagged = true
        root.enumerateHierarchy { n, _ in if n.categoryBitMask != TinCanRat.categoryBit { everyNodeTagged = false } }
        #expect(everyNodeTagged)
    }

    @Test func copiesAreIndependent() throws {
        let a = try #require(HallwaysianTinky.makeBody())
        let b = try #require(HallwaysianTinky.makeBody())
        let legA = try #require(a.childNode(withName: "tinCanRatLeg0", recursively: true))
        let legB = try #require(b.childNode(withName: "tinCanRatLeg0", recursively: true))
        legA.eulerAngles.x = 0.7
        #expect(legB.eulerAngles.x == 0)
    }
}
