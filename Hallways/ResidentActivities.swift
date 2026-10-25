//
//  ResidentActivities.swift
//  Hallways
//
//  Oct 18 (resident life, phase 2) -- WHAT A RESIDENT DOES IN A ROOM.
//
//  A room visit is more than standing in it: the resident finds something
//  there and does something about it -- the chair settles at a desk as though
//  working, the butterfly circles a lamp, either may inspect a cabinet or
//  simply rest and look about. Nothing is scripted per room:
//
//    RoomThings          what's actually IN the room, found in the floor's scene
//                        (the furniture the editor placed, the authored rooms'
//                        own fixtures -- by their node names), with its real
//                        position and size from the geometry.
//    ResidentActivities  which activity, chosen from what's there by the
//                        species' tastes and the resident's own seed; and
//                        where to stand (or hover) to do it -- a point beside
//                        the thing, on the room's side of it, in a cell of the
//                        room it may be in.
//
//  The doing is the species' own (RoamPresentation for the chair,
//  ButterflyFloor for her), in beats a few seconds apart that any decision,
//  floor change or rebuild simply stops: an activity never holds a resident.
//

import Foundation
import QuartzCore
import SceneKit
import simd

/// Something in a room worth a resident's attention.
struct RoomThing: Equatable {
    enum Kind: String { case desk, table, seat, lamp, cabinet, water, aquarium, screen, mirror, shelf, other }
    let kind: Kind
    /// In words ("desk", "floor lamp"...).
    let label: String
    /// Its centre at floor level (world x, z).
    let center: SIMD2<Float>
    /// The height of its top (world y).
    let top: Float
    /// Its half-size across the floor (metres): how far from its centre its edge is.
    let radius: Float

    /// The point to look at: its top (a work surface, a lamp's shade), never above eye-ish height.
    var lookPoint: SIMD3<Float> { SIMD3<Float>(center.x, min(top, 1.9) - (kind == .lamp ? 0.05 : 0.02), center.y) }
}

enum RoomThings {
    /// The scene nodes that are things, by exact name: (kind, label).
    static let catalog: [String: (RoomThing.Kind, String)] = [
        "furnitureDesk": (.desk, "desk"), "playerOfficeDesk": (.desk, "desk"), "administrationOfficeDesk": (.desk, "desk"),
        "furnitureTable": (.table, "table"), "conferenceRoomTable": (.table, "conference table"),
        "furnitureOfficeChair": (.seat, "office chair"), "playerOfficeChair": (.seat, "office chair"),
        "administrationOfficeChair": (.seat, "office chair"), "administrationVisitorChair": (.seat, "visitor's chair"),
        "furnitureFloorLamp": (.lamp, "floor lamp"), "playerOfficeLamp": (.lamp, "desk lamp"), "administrationOfficeLamp": (.lamp, "desk lamp"),
        "furnitureFilingCabinet": (.cabinet, "filing cabinet"), "playerOfficeCabinet": (.cabinet, "cabinet"),
        "administrationBookcase": (.shelf, "bookcase"), "playerOfficeShelf": (.shelf, "shelf"),
        "furnitureWaterCooler": (.water, "water cooler"), "furnitureAquarium": (.aquarium, "aquarium"),
        "playerOfficeComputer": (.screen, "computer"), "conferenceRoomBoard": (.screen, "whiteboard"),
        "photoBooth": (.screen, "photo booth"), "ticTacToeTerminal": (.screen, "terminal"), "shellGameStation": (.screen, "terminal"),
        "rockPaperScissorsTerminal": (.screen, "terminal"), "higherLowerTerminal": (.screen, "terminal"),
        "fiveCardDrawTerminal": (.screen, "terminal"), "simonTerminal": (.screen, "terminal"), "hangmanTerminal": (.screen, "terminal"),
        "connectFourTerminal": (.screen, "terminal"), "checkersTerminal": (.screen, "terminal"), "woidleTerminal": (.screen, "terminal"),
        "mirror": (.mirror, "mirror"), "trashCan": (.other, "wastebasket"), "administrationPlanter": (.other, "planter"),
        "supplyDisplay": (.shelf, "supply shelf"),
    ]
    // (Never the breaker panel: that belongs to a mission, not to an idle look.)

    /// The things in a room: catalogued nodes of the scene whose centre lies in
    /// one of its cells. Measured from the geometry itself.
    static func find(in root: SCNNode, cells: Set<GridCoordinate>, cellSize: Float) -> [RoomThing] {
        var out: [RoomThing] = []
        root.enumerateHierarchy { node, stop in
            guard let name = node.name, let entry = catalog[name], !node.isHidden else { return }
            let (kind, label) = entry
            let (lo, hi) = node.boundingBox
            guard hi.x > lo.x || hi.y > lo.y || hi.z > lo.z else { return }
            var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude), maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] {
                let w = node.convertPosition(SCNVector3(x, y, z), to: nil)
                let v = SIMD3<Float>(w.x, w.y, w.z)
                minP = simd_min(minP, v)
                maxP = simd_max(maxP, v)
            } } }
            let c = SIMD2<Float>((minP.x + maxP.x) / 2, (minP.z + maxP.z) / 2)
            let cell = GridCoordinate(row: Int((c.y / cellSize).rounded()), col: Int((c.x / cellSize).rounded()))
            guard cells.contains(cell) else { return }
            let radius = max(0.15, max(maxP.x - minP.x, maxP.z - minP.z) / 2)
            out.append(RoomThing(kind: kind, label: label, center: c, top: maxP.y, radius: min(radius, 1.4)))
        }
        return out.sorted { ($0.center.x, $0.center.y) < ($1.center.x, $1.center.y) }
    }
}

// MARK: - Choosing and placing

enum ResidentActivities {
    enum Species { case chair, butterfly, critter }   // (Oct 18: critter -- the Menagerie residents; Oct 19: the Pottle)
    enum Kind: String {
        case working = "working"
        case inspecting = "inspecting"
        case visiting = "visiting"          // (another chair)
        case circling = "circling"
        case investigating = "investigating"
        case resting = "resting"
        case lookingAround = "looking around"
    }

    /// What to do in a room with these things in it -- by its tastes, from its seed.
    static func choose(for species: Species, things: [RoomThing], seed: UInt64) -> (kind: Kind, thing: RoomThing?) {
        var rng = Rand(seed: seed)
        let roll = rng.unit()
        // Now and then nothing in particular, whatever's there.
        if things.isEmpty || roll < 0.18 {
            return (rng.unit() < 0.5 ? .resting : .lookingAround, nil)
        }
        func pick(_ list: [RoomThing]) -> RoomThing { list[Int(rng.unit() * Float(list.count)) % list.count] }
        switch species {
        case .chair:
            let work = things.filter { [.desk, .table, .screen].contains($0.kind) }
            let seats = things.filter { $0.kind == .seat }
            if !work.isEmpty, rng.unit() < 0.6 { return (.working, pick(work)) }
            if !seats.isEmpty, rng.unit() < 0.4 { return (.visiting, pick(seats)) }
            return (.inspecting, pick(things))
        case .butterfly:
            let lights = things.filter { [.lamp, .aquarium, .screen].contains($0.kind) }
            if !lights.isEmpty, rng.unit() < 0.65 { return (.circling, pick(lights)) }
            return (.investigating, pick(things))
        case .critter:
            // Oct 18 (open the building): a curious animal -- sniffs round a thing, settles near it, or just looks about.
            if rng.unit() < 0.55 { return (.investigating, pick(things)) }
            return (rng.unit() < 0.5 ? .resting : .inspecting, pick(things))
        }
    }

    /// Where to stand to attend to `thing`: `standoff` metres off its edge, on
    /// the side toward `from` if that's allowed, else the nearest side round it
    /// that is (`allowed`: a point in a cell of the room it may be in).
    static func standPoint(for thing: RoomThing, from: SIMD2<Float>, standoff: Float,
                           allowed: (SIMD2<Float>) -> Bool) -> SIMD2<Float>? {
        let away = from - thing.center
        let base = simd_length(away) > 0.01 ? atan2(away.y, away.x) : 0
        let reach = thing.radius + standoff
        for k in 0..<12 {
            let step = Float((k + 1) / 2) * (.pi / 6) * (k % 2 == 0 ? 1 : -1)
            let a = base + step
            let p = thing.center + SIMD2<Float>(cos(a), sin(a)) * reach
            if allowed(p) { return p }
        }
        return nil
    }

    /// Facing a point from another (Noodle convention: yaw h faces (-sin h, -cos h)).
    static func heading(from p: SIMD2<Float>, to q: SIMD2<Float>) -> Float {
        let d = q - p
        return simd_length(d) > 0.001 ? atan2(-d.x, -d.y) : 0
    }

    /// The panel's words: "Copy Center / inspecting desk / looking at desk".
    static func note(room: String?, doing: String, attention: String?) -> String {
        "\(room ?? "hallway") / \(doing)" + (attention.map { " / \($0)" } ?? "")
    }
}
