//
//  CritterTapTarget.swift
//  Hallways
//
//  Oct 22 -- TAP A CRITTER: WHAT COUNTS AS TAPPING IT.
//
//  iPhone: "critters whose heads are clearly visible and close enough to touch,
//  yet tapping them does absolutely nothing" (Floor 2: the blue bulging-eyed
//  creature, the yellow one beside the elevator).
//
//  WHAT THE OLD TEST DID (CritterFollow.handleTap): ONE hit-test result -- the
//  single closest thing under the finger -- and only if that very node sat
//  inside a resident's `bodyNode`. So a tap failed whenever:
//    1. anything else was the closest surface on that ray -- an invisible hit
//       volume (the wall terminals' and photo booths' clear 0.001 boxes, the
//       floor objects' decorator plates, a supply slot's tap box), a hidden
//       material (colorBufferWriteMask []), a glass pane, a hanging string, the
//       carried tool -- even with the critter plainly visible behind it;
//    2. the finger landed a few points off a thin part (an eye on a stalk, an
//       antenna, a slim neck): the ray went past it to the wall behind;
//    3. the critter was standing in the cab (seen through the car's open doors):
//       that figure isn't `bodyNode` at all, so it never counted.
//  (And a refused tap -- during an escort, the meeting -- said nothing anywhere.)
//
//  NOW, one shared rule for every resident (Hallwaysians, the chair, the
//  butterfly, the Pottle, the conference cast -- anything BuildingLife presents):
//    DIRECT    every hit along the ray, nearest first: helpers and see-through
//              surfaces are looked past; the first that belongs to a resident's
//              body (any part: head, eyes, limbs -- anything under its root) is
//              that resident; the first solid thing that isn't stops the search.
//    GENEROUS  no direct hit: the tap within a finger's margin of a resident's
//              whole on-screen silhouette box (its every part, projected) -- if
//              nothing solid stands in front of it on that ray, and within ten
//              metres. Never when the finger is on the elevator's doors or call
//              panel. Two candidates: the one whose centre is nearer the finger.
//  Misses near a resident are logged (follow.tapMiss) with why.
//

import SceneKit
import UIKit
import simd

enum CritterTapTarget {
    enum Resolution {
        /// A resident, and how ("direct" / "generous").
        case resident(String, how: String)
        /// No resident; a report when one was near enough on screen to be worth one.
        case miss(MissReport?)
    }

    struct MissReport {
        let fields: KeyValuePairs<String, Any?>
    }

    /// A finger's margin around a resident's on-screen box (points).
    static let screenMargin: CGFloat = 14
    /// Oct 22 (stability pass): a small figure (the butterfly, a far-off critter)
    /// is given a target at least this big on screen (points), round its centre --
    /// a fingertip's worth, whatever its size. Nothing about its look changes.
    static let minimumTarget: CGFloat = 64
    /// The generous target only this near (metres).
    static let generousRange: Float = 10
    /// A solid surface this much nearer than a resident's nearest part hides it (metres).
    static let occlusionSlack: Float = 0.25
    /// A miss within this of a resident on screen is reported (points).
    static let reportWithin: CGFloat = 90

    /// Invisible helpers every tap test looks past (by name).
    static let lookThroughNames: Set<String> = ["decoratorHitProxy", "hangingPickupString", "meetingProjectorBeam",
                                                 "photoBoothHitArea", "supplySlotHit", "tvStatic"]

    static func resolve(at point: CGPoint, in view: SCNView, controller: TapNavigationController) -> Resolution {
        // Every node a tap may land on, per resident (not the butterfly while she guides).
        var owners: [ObjectIdentifier: String] = [:]
        var targets: [(id: String, node: SCNNode)] = []
        for p in BuildingLife.shared.presentations where !p.isGuiding {
            for node in p.tapTargets {
                owners[ObjectIdentifier(node)] = p.residentID
                targets.append((p.residentID, node))
            }
        }
        let hits = Posse.navigationHits(view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                                      .ignoreHiddenNodes: true]))
        guard !targets.isEmpty else {
            // (no residents shown here at all: what the finger did land on, for the record --
            // a creature that isn't a resident shows up by its node's name)
            let first = hits.first { !isSeeThrough($0) }.map { describe($0.node) } ?? "nothing"
            return .miss(MissReport(fields: ["point": String(format: "%.0f,%.0f", point.x, point.y), "hit": first,
                                             "reason": "no residents on this floor"]))
        }
        // 1. DIRECT
        var blocker: SCNHitTestResult?
        var lookedPast = 0
        for hit in hits {
            if let id = owner(of: hit.node, owners) { return .resident(id, how: lookedPast > 0 ? "direct (past \(lookedPast))" : "direct") }
            if isSeeThrough(hit) { lookedPast += 1; continue }
            blocker = hit
            break
        }
        let eyeNode = view.pointOfView ?? controller.cameraNode
        let e = eyeNode.presentation.worldPosition
        let eye = SIMD3<Float>(e.x, e.y, e.z)
        let blockerName = blocker.map { describe($0.node) } ?? "nothing"
        // 2. GENEROUS (over the elevator's own doors or call panel: only a finger
        // squarely on a resident's figure -- Oct 22, stability pass: Layla standing at
        // the doors, 12 pt from the finger, was refused outright)
        let overElevator = blocker.map { controller.isElevatorDoor($0.node) || controller.isElevatorCallPanel($0.node) } ?? false
        let wall: Float = blocker.map { simd_distance(eye, SIMD3<Float>($0.worldCoordinates.x, $0.worldCoordinates.y, $0.worldCoordinates.z)) } ?? .infinity
        var best: (id: String, score: CGFloat)?
        var rejected: String?
        for (id, node) in targets {
            guard let box = screenBox(of: node, in: view, eye: eye) else { continue }
            let outside = overElevator ? gap(point, box.rect) : gap(point, atLeast(box.rect, minimumTarget))
            guard overElevator ? outside == 0 : outside <= screenMargin else { continue }
            guard box.distance <= generousRange else { rejected = "\(id): too far (\(Int(box.distance)) m)"; continue }
            guard box.near <= wall + occlusionSlack else { rejected = "\(id): behind \(blockerName)"; continue }
            let score = hypot(point.x - box.rect.midX, point.y - box.rect.midY) / max(20, min(box.rect.width, box.rect.height))
            if best == nil || score < best!.score { best = (id, score) }
        }
        if let best { return .resident(best.id, how: overElevator ? "on its figure (at the elevator)" : "generous") }
        return .miss(nearestReport(point: point, view: view, eye: eye, targets: targets, hit: blockerName,
                                   reason: overElevator ? "the elevator's doors or panel under the finger"
                                                        : (rejected ?? "outside every resident's target")))
    }

    // MARK: Pieces

    /// The resident whose node this is part of (walking up its parents).
    private static func owner(of node: SCNNode, _ owners: [ObjectIdentifier: String]) -> String? {
        var n: SCNNode? = node
        while let m = n {
            if let id = owners[ObjectIdentifier(m)] { return id }
            n = m.parent
        }
        return nil
    }

    /// A surface the eye sees through (or that isn't drawn at all): a tap goes on past it.
    static func isSeeThrough(_ hit: SCNHitTestResult) -> Bool {
        var opacity: CGFloat = 1
        var n: SCNNode? = hit.node
        while let m = n {
            if let name = m.name, lookThroughNames.contains(name) { return true }
            if ToolBelt.owns(m) { return true }
            opacity *= m.opacity
            n = m.parent
        }
        if opacity < 0.5 { return true }
        guard let materials = hit.node.geometry?.materials, !materials.isEmpty else { return false }
        let m = materials[max(0, hit.geometryIndex) % materials.count]
        if m.transparency < 0.5 || m.colorBufferWriteMask.isEmpty { return true }
        if let c = m.diffuse.contents as? UIColor {
            var a: CGFloat = 1
            c.getRed(nil, green: nil, blue: nil, alpha: &a)
            if a < 0.1 { return true }
        }
        return false
    }

    /// A resident's whole figure on screen: the box round every drawn part,
    /// how far it is, and how near its nearest part comes.
    static func screenBox(of root: SCNNode, in view: SCNView, eye: SIMD3<Float>)
        -> (rect: CGRect, distance: Float, near: Float)? {
        guard root.parent != nil, !root.isHidden else { return nil }
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var near = Float.infinity
        var sum = SIMD3<Float>(0, 0, 0), count: Float = 0
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry, !node.isHidden, node.opacity > 0.05 else { return }
            let (lo, hi) = geometry.boundingBox
            for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] {
                let w = node.presentation.convertPosition(SCNVector3(x, y, z), to: nil)
                let p = SIMD3<Float>(w.x, w.y, w.z)
                sum += p; count += 1
                near = min(near, simd_distance(eye, p))
                let s = view.projectPoint(w)
                guard s.z > 0, s.z < 1 else { continue }                     // (behind the eye)
                minX = min(minX, CGFloat(s.x)); maxX = max(maxX, CGFloat(s.x))
                minY = min(minY, CGFloat(s.y)); maxY = max(maxY, CGFloat(s.y))
            } } }
        }
        guard count > 0, minX.isFinite, maxX > minX, maxY > minY else { return nil }
        return (CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), simd_distance(eye, sum / count), near)
    }

    /// The rect grown (about its centre) to at least `side` x `side`.
    static func atLeast(_ r: CGRect, _ side: CGFloat) -> CGRect {
        let w = max(r.width, side), h = max(r.height, side)
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    /// How far a point lies outside a rect (0: inside).
    static func gap(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// The node's name, or its nearest named parent's (diagnostics).
    static func describe(_ node: SCNNode) -> String {
        var n: SCNNode? = node
        var depth = 0
        while let m = n, depth < 6 {
            if let name = m.name, !name.isEmpty { return depth == 0 ? name : "\(name)/+\(depth)" }
            n = m.parent
            depth += 1
        }
        return "unnamed"
    }

    /// A miss, for the record (one line per tap, human-rate): the nearest resident if one was near.
    private static func nearestReport(point: CGPoint, view: SCNView, eye: SIMD3<Float>, targets: [(id: String, node: SCNNode)],
                                      hit: String, reason: String) -> MissReport? {
        var nearest: (id: String, gap: CGFloat)?
        for (id, node) in targets {
            guard let box = screenBox(of: node, in: view, eye: eye) else { continue }
            let g = gap(point, box.rect)
            if nearest == nil || g < nearest!.gap { nearest = (id, g) }
        }
        guard let nearest, nearest.gap <= reportWithin else {
            return MissReport(fields: ["point": String(format: "%.0f,%.0f", point.x, point.y), "hit": hit,
                                       "reason": "no resident near the finger"])
        }
        return MissReport(fields: ["point": String(format: "%.0f,%.0f", point.x, point.y), "hit": hit,
                                   "nearest": nearest.id, "gapPoints": Double(nearest.gap), "reason": reason])
    }
}
