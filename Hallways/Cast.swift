//
//  Cast.swift
//  Hallways
//
//  Oct 6 -- "ALL CRITTERS ARE CREATED EQUAL", stages 1-3 (plumbing only;
//  no intended visible change).
//
//  IDENTITY (stage 1). A critter's identity is a CritterID, not a node
//  name. Every body built for a story critter is tagged with its id
//  (CritterTags); anything that needs "is this Jeff?" or "where is Jeff?"
//  asks the tags. Names stay as role labels only ("tinCanRat",
//  "administrationOfficeFred", ...), so existing lookups keep working.
//
//  ONE AUTHORITY (stage 2). Cast.jeffPlacement(floor:) is the single
//  decision of what Jeff is doing on a floor when it is built: absent, at
//  his office door (before the ID), at his desk (after it), riding in as a
//  journey guide, or hanging with the player. Every install site asks it;
//  nothing else decides. Cast also holds his LIVE role as it changes
//  (performing, leading, bonding, ...) and audits each finished floor build
//  so there is never more than one Jeff in a scene.
//
//  ONE BODY (stage 3). Cast.bond(_:holdFor:) turns whatever body Jeff is
//  in (office model, journey guide) into the hanging companion WITHOUT a
//  new body: the companion driver is attached to that same node under a
//  performance hold (TinCanRatDriver.hold/release), the pet performance
//  plays, and the driver resumes from wherever the performance left him.
//
//  [Cast] lines (Debug console + flight recorder) report every change.
//

import SceneKit
import simd

// MARK: - Identity

nonisolated struct CritterID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    var description: String { rawValue }
    /// The tin-can character (code: Noodle / TinCanRat / Fred; story: Jeff, for now).
    static let jeff = CritterID(rawValue: "jeff")
    /// The fire extinguisher (Posse member).
    static let freddy = CritterID(rawValue: "freddy")
}

/// Collision/probe identity: each story critter has its own category bit.
nonisolated enum CritterCategory {
    /// Jeff's bodies (historically TinCanRat.categoryBit).
    static let jeff = 1 << 9
    /// Freddy's body (Oct 6: his own bit; he used to borrow Jeff's).
    static let freddy = 1 << 13
    /// Story critters every wall/sight probe looks straight through.
    static let storyCritters = jeff | freddy
}

/// Which nodes are which critter. Thread-safe (the ecosystem reads it on the
/// render thread). Weak: a body that leaves its scene simply drops out.
nonisolated final class CritterTags: @unchecked Sendable {
    private static let lock = NSLock()
    private static let table = NSMapTable<SCNNode, NSString>.weakToStrongObjects()
    nonisolated(unsafe) private static var ecosystem: [CritterID: WeakBody] = [:]
    private final class WeakBody { weak var node: SCNNode?; init(_ n: SCNNode?) { node = n } }

    static func tag(_ node: SCNNode, as id: CritterID) {
        lock.lock(); defer { lock.unlock() }
        table.setObject(id.rawValue as NSString, forKey: node)
    }

    /// The critter this node belongs to (the node or any ancestor is tagged).
    static func id(of node: SCNNode) -> CritterID? {
        lock.lock(); defer { lock.unlock() }
        var n: SCNNode? = node
        while let current = n {
            if let raw = table.object(forKey: current) { return CritterID(rawValue: raw as String) }
            n = current.parent
        }
        return nil
    }

    /// Every live tagged body of this critter.
    static func bodies(of id: CritterID) -> [SCNNode] {
        lock.lock(); defer { lock.unlock() }
        var out: [SCNNode] = []
        for case let node as SCNNode in table.keyEnumerator().allObjects {
            if let raw = table.object(forKey: node), (raw as String) == id.rawValue { out.append(node) }
        }
        return out
    }

    /// The body the rest of the ecosystem (Habitat, Bobbins) perceives for
    /// this critter -- only while it is out and about with the player, as
    /// before the refactor (they never saw the office model or the guide).
    static func setEcosystemBody(_ node: SCNNode?, for id: CritterID) {
        lock.lock(); defer { lock.unlock() }
        ecosystem[id] = WeakBody(node)
    }

    /// That body, if it is a direct child of `root` (the old "tinCanRat"
    /// child-of-root lookup, by identity instead of by name).
    static func ecosystemBody(_ id: CritterID, under root: SCNNode) -> SCNNode? {
        lock.lock(); let node = ecosystem[id]?.node; lock.unlock()
        guard let node, node.parent === root else { return nil }
        return node
    }
}

// MARK: - The cast (main thread)

enum Cast {
    /// What Jeff is doing. Install placements are the first five; the rest
    /// are live states he passes through.
    enum JeffRole: String {
        case absent, doorGuard, officeDesk, journeyGuide, hanging
        case performing, leading, waitingAtJourneyEnd, bonding
        /// Oct 6: going somewhere on his own (no one following).
        case travelling
    }

    private(set) static var jeffRole: JeffRole = .absent
    private(set) static weak var jeffBody: SCNNode?
    private static var floor = 0

    /// Turn a body into the hanging companion (set by ContentView each build:
    /// attaches the TinCanRat driver to THIS node, held). True = attached.
    static var adoptAsHanging: ((SCNNode) -> Bool)?

    // MARK: Authority

    /// THE decision: what Jeff is doing on `floor` when it is built.
    /// Oct 6 (onboarding ends in the player's office): Candy is NOT anyone's
    /// permanent companion. Before the ID he minds his door; after it he is
    /// at his desk; while guiding he rides in with the player; and once he
    /// has delivered them and gone home, he is at his Orientation desk --
    /// and absent everywhere else. (`.hanging` stays available for story
    /// beats that ask for it; no floor build installs it by default.)
    static func jeffPlacement(floor: Int) -> JeffRole {
        if GuidedJourney.guidesOn(floor: floor) { return .journeyGuide }
        if floor == AdministrationReception.floor {
            if Admission.isPrologueCompleted { return .officeDesk }      // home at Orientation
            return Admission.isCompleted ? .officeDesk : .doorGuard
        }
        return .absent
    }

    /// The one factory for a Jeff body (every role).
    static func makeJeffBody() -> SCNNode {
        let body = TinCanRatModel.make()
        body.scale = SCNVector3(TinCanRat.scale, TinCanRat.scale, TinCanRat.scale)
        CritterTags.tag(body, as: .jeff)
        return body
    }

    /// Jeff is now `role`, in `body` (nil = keep the current body).
    static func setJeff(_ role: JeffRole, body: SCNNode? = nil, _ note: String = "") {
        let previous = jeffRole
        if let body {
            if let old = jeffBody, old !== body, old.parent != nil, sceneRoot(of: old) === sceneRoot(of: body) {
                log("WARNING second Jeff body in one scene -- removing \(tag(old)), keeping \(tag(body))")
                old.removeFromParentNode()
            }
            jeffBody = body
        }
        jeffRole = role
        CritterTags.setEcosystemBody(role == .hanging ? jeffBody : nil, for: .jeff)
        var line = "jeff \(previous.rawValue) -> \(role.rawValue)"
        if let b = jeffBody { line += " body=\(tag(b)) at=\(where_(b))" }
        if !note.isEmpty { line += " (\(note))" }
        log(line)
    }

    /// A short activity note while the role stays the same.
    static func jeffActivity(_ note: String) {
        log("jeff \(jeffRole.rawValue): \(note)" + (jeffBody.map { " at=\(where_($0))" } ?? ""))
    }

    // MARK: Bond -- the same body goes on as the hanging companion

    /// The pet's handoff, one body: attach the companion driver to `body`
    /// now (held, so the pet performance owns him), and after `seconds`
    /// move him into the scene's own space and release the hold -- the
    /// driver resumes from exactly where the performance left him.
    @discardableResult
    static func bond(_ body: SCNNode, holdFor seconds: Double) -> Bool {
        guard let adopt = adoptAsHanging, adopt(body) else {
            log("bond FAILED -- no companion adopter on this floor; \(tag(body)) stays as is")
            return false
        }
        setJeff(.bonding, body: body, "driver attached, held \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard body.parent != nil, let root = sceneRoot(of: body) else { return }
            let world = body.presentation.worldPosition
            let heading = body.presentation.eulerAngles.y
            // The performance is over: stop whatever is left of it (never the
            // driver's own tick), then hand him to the driver where he stands.
            for key in body.actionKeys where key != TinCanRat.tickActionKey { body.removeAction(forKey: key) }
            body.enumerateChildNodes { child, _ in child.removeAllActions() }
            if body.parent !== root {
                body.removeFromParentNode()
                root.addChildNode(body)
            }
            body.position = SCNVector3(world.x, 0, world.z)
            body.eulerAngles = SCNVector3(0, heading, 0)
            body.name = TinCanRat.rootName
            TinCanRatDriver.driver(for: body)?.release(at: SIMD2<Float>(world.x, world.z), heading: heading)
            setJeff(.hanging, body: body, "same body, hold released")
        }
        return true
    }

    // MARK: Floor audit

    /// After a floor is fully installed: exactly one Jeff (or none) in this
    /// scene, and one summary line.
    static func floorBuilt(_ floor: Int, root: SCNNode) {
        self.floor = floor
        let here = CritterTags.bodies(of: .jeff).filter { $0.parent != nil && sceneRoot(of: $0) === root }
        if let body = jeffBody, here.contains(where: { $0 === body }) {
            for extra in here where extra !== body {
                log("WARNING extra Jeff body \(tag(extra)) in floor \(floor) -- removed")
                extra.removeFromParentNode()
            }
        } else if let first = here.first {
            jeffBody = first
            for extra in here.dropFirst() {
                log("WARNING extra Jeff body \(tag(extra)) in floor \(floor) -- removed")
                extra.removeFromParentNode()
            }
        } else {
            jeffBody = nil
            if jeffRole != .absent { jeffRole = .absent; CritterTags.setEcosystemBody(nil, for: .jeff) }
        }
        let jeff = jeffBody.map { "\(jeffRole.rawValue) \(tag($0)) at=\(where_($0))" } ?? "absent"
        log("floor \(floor) ready -- jeff: \(jeff) | freddy: \(Posse.castSummary(Freddy.memberID, floor: floor))")
    }

    // MARK: Helpers

    static func log(_ line: String) {
        navLog("[Cast] \(line)")
        DiagnosticRecorder.shared.record("cast", ["msg": line])
    }

    static func tag(_ node: SCNNode) -> String {
        "#" + String(UInt(bitPattern: ObjectIdentifier(node).hashValue) & 0xFFFF, radix: 16)
    }

    private static func where_(_ node: SCNNode) -> String {
        let p = node.presentation.worldPosition
        return String(format: "(%.1f,%.1f)", p.x, p.z)
    }

    static func sceneRoot(of node: SCNNode) -> SCNNode? {
        var n = node
        while let p = n.parent { n = p }
        return n === node ? nil : n
    }
}
