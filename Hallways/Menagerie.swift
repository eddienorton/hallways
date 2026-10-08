//
//  Menagerie.swift
//  Hallways
//
//  Oct 3 -- "LET THE DWEEZILS TALK" (experiment).
//
//  A small cast of living ordinary objects that share the building with
//  Noodle and the Bobbins. Each has its own body, gait, voice and tiny brain;
//  they share only plumbing:
//
//  - HabitatGraph: the floor as cells + open links (doors count as closed).
//  - Habitat: who is where (refreshed 5x a second, not per frame), recent
//    sounds, and a line-of-sight test. Creatures read it; nothing else does.
//  - Critter: cell-to-cell locomotion with a loose, drifting lane (so nobody
//    rides a rail), heading smoothing, pauses, a cage mode, and a positional
//    voice. Each creature subclass supplies its own perception, choices and
//    animation -- deliberately NOT one generic personality engine.
//  - MenagerieSound: every sound is synthesised in code (no assets).
//
//  Like Noodle and the Bobbins, everything is driven by repeating SCNActions
//  on the creatures' own nodes and is rebuilt with each floor's scene.
//  Navigation, missions and the elevator know nothing about any of it.
//
//  Future note (not built): a creature's position is just `pos` + its graph
//  cell, so "follow someone into the elevator cab" can be a mode later
//  without changing this structure.
//

import SceneKit
import UIKit
import simd

// MARK: - Install

enum Menagerie {
    /// Category bit for every Menagerie creature node (Noodle's and the Bobbins'
    /// own probes and this file's sight lines skip creatures).
    nonisolated static let categoryBit = 1 << 11

    /// Builds the cast for this floor. Returns the cage's cell (if one was
    /// placed) so other residents can be kept from walking through it.
    @discardableResult
    static func install(in view: SCNView, scene: SCNScene, playerCamera: SCNNode, cells: Set<GridCoordinate>,
                        cellSize: CGFloat, doors: [(GridCoordinate, Direction)], litCells: Set<GridCoordinate>,
                        busyCells: Set<GridCoordinate>) -> GridCoordinate? {
        let tracePhase = ElevatorArrivalTrace.shared.beginPhase("Menagerie.install")
        defer { ElevatorArrivalTrace.shared.endPhase("Menagerie.install", tracePhase) }
        guard cells.count >= 20 else { return nil }      // the lobby and tiny floors stay quiet
        let traceGraph = ElevatorArrivalTrace.shared.beginPhase("Menagerie.habitatGraph")
        func key(_ c: GridCoordinate) -> Int { HabitatGraph.key(row: c.row, col: c.col) }
        var blocked = Set<Int64>()
        func edge(_ a: Int, _ b: Int) -> Int64 { Int64(min(a, b)) << 32 | Int64(max(a, b)) }
        for (coord, direction) in doors {
            blocked.insert(edge(key(coord), key(GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col))))
        }
        var neighbors: [Int: [Int]] = [:]
        var centers: [Int: SIMD2<Float>] = [:]
        var coordOf: [Int: GridCoordinate] = [:]
        for c in cells {
            centers[key(c)] = SIMD2<Float>(Float(CGFloat(c.col) * cellSize), Float(CGFloat(c.row) * cellSize))
            coordOf[key(c)] = c
            neighbors[key(c)] = Direction.allCases.compactMap { d in
                let n = GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
                guard cells.contains(n), !blocked.contains(edge(key(c), key(n))) else { return nil }
                return key(n)
            }
        }
        let graph = HabitatGraph(neighbors: neighbors, centers: centers, cellSize: Float(cellSize),
                                 lit: Set(litCells.map(key)))
        let eye = playerCamera.presentation.worldPosition
        let start = key(GridCoordinate(row: Int((CGFloat(eye.z) / cellSize).rounded()), col: Int((CGFloat(eye.x) / cellSize).rounded())))
        let fromStart = graph.distances(from: centers[start] != nil ? [start] : [])
        let farthest = fromStart.values.max() ?? 0
        let busy = Set(busyCells.map(key))
        var used: [Int] = []

        /// A cell for something to start in: matching `prefer` if possible, far
        /// enough from the player, not busy, and not crowding earlier picks.
        func pick(minFraction: Double, prefer: (Int) -> Bool) -> Int? {
            let apart = graph.distances(from: used)
            func ok(_ k: Int, _ spacing: Int) -> Bool {
                guard !busy.contains(k), !used.contains(k), !(neighbors[k] ?? []).isEmpty else { return false }
                let d = fromStart[k] ?? 99
                return d >= max(3, Int(Double(farthest) * minFraction)) && (used.isEmpty || (apart[k] ?? 99) >= spacing)
            }
            for spacing in [3, 2, 1] {
                let preferred = centers.keys.filter { ok($0, spacing) && prefer($0) }
                if let k = preferred.randomElement() { used.append(k); return k }
            }
            for spacing in [3, 2, 1] {
                let any = centers.keys.filter { ok($0, spacing) }
                if let k = any.randomElement() { used.append(k); return k }
            }
            return nil
        }
        let deadEnd: (Int) -> Bool = { graph.degree($0) == 1 }
        let crossing: (Int) -> Bool = { graph.degree($0) >= 3 }

        ElevatorArrivalTrace.shared.endPhase("Menagerie.habitatGraph", traceGraph)
        let traceHabitat = ElevatorArrivalTrace.shared.beginPhase("Menagerie.shadowAndHabitat")
        let shadow = shadowImage()
        let habitat = Habitat(graph: graph, root: scene.rootNode, playerCamera: playerCamera)
        var critters: [Critter] = []
        func add(_ critter: Critter, _ node: SCNNode) {
            guard LivingWorld.admit() else { return }     // Oct 4 DIAGNOSTIC population cap
            node.enumerateHierarchy { n, _ in n.categoryBitMask = categoryBit }
            scene.rootNode.addChildNode(node)
            LivingWorld.track(node)
            habitat.add(critter)
            critters.append(critter)
            node.runAction(.repeatForever(critter.tickAction()), forKey: "critterTick")
        }

        ElevatorArrivalTrace.shared.endPhase("Menagerie.shadowAndHabitat", traceHabitat)
        let traceCast = ElevatorArrivalTrace.shared.beginPhase("Menagerie.cageAndObjectCast")
        // The enclosure first (a discovery, somewhere off the beaten track).
        var cageCell: GridCoordinate?
        if LivingWorld.fullCast, let k = pick(minFraction: 0.45, prefer: deadEnd), let center = centers[k] {   // Oct 4 DIAGNOSTIC: cage only at ALL / 32
            cageCell = coordOf[k]
            let doorToward = (neighbors[k] ?? []).first.flatMap { centers[$0] } ?? (center + SIMD2<Float>(0, 1))
            let cage = Cage(habitat: habitat, cell: k, center: center, doorToward: doorToward)
            scene.rootNode.addChildNode(cage.node)
            LivingWorld.trackStructure(cage.node)
            cage.node.runAction(.repeatForever(cage.tickAction()), forKey: "cageTick")
            habitat.blockedCells.insert(k)
            let inmates: [(Critter, SCNNode)] = [
                Clacker.make(habitat: habitat, cell: k, shadow: shadow, scale: 0.85),
                Clacker.make(habitat: habitat, cell: k, shadow: shadow, scale: 0.8),
                Pottle.make(habitat: habitat, cell: k, shadow: shadow, scale: 0.72)
            ]
            for (i, (critter, node)) in inmates.enumerated() {
                let angle = Float(i) * 2.1 + 0.4
                critter.pos = center + SIMD2<Float>(cos(angle), sin(angle)) * 0.35
                critter.cage = center
                cage.inmates.append(critter)
                add(critter, node)
            }
        }
        // The ones already loose.
        if let k = pick(minFraction: 0.3, prefer: { graph.lit.contains($0) }) {
            let (c, n) = Stalk.make(habitat: habitat, cell: k, shadow: shadow); add(c, n)
        }
        if let k = pick(minFraction: 0.35, prefer: crossing) {
            let (c, n) = Ladder.make(habitat: habitat, cell: k, shadow: shadow); add(c, n)
        }
        if let k = pick(minFraction: 0.55, prefer: crossing) {
            let (c, n) = Chair.make(habitat: habitat, cell: k, shadow: shadow); add(c, n)
        }
        if let k = pick(minFraction: 0.3, prefer: deadEnd) {
            let (c, n) = Pottle.make(habitat: habitat, cell: k, shadow: shadow, scale: 1); add(c, n)
        }
        if let k = pick(minFraction: 0.5, prefer: { _ in true }) {
            let (c, n) = Clacker.make(habitat: habitat, cell: k, shadow: shadow, scale: 1); add(c, n)
        }
        // Oct 4 DIAGNOSTIC "DOUBLE THE ZOO" (32 setting only): more of the lighter
        // office-object species, spread over the floor by the same pick() rules.
        if LivingWorld.isCrowd {
            let crowdScales: [Float] = [1, 0.9, 0.95, 0.85]
            for i in 0..<3 {
                if let k = pick(minFraction: 0.15, prefer: { _ in true }) {
                    let (c, n) = Clacker.make(habitat: habitat, cell: k, shadow: shadow, scale: crowdScales[i % 4]); add(c, n)
                }
            }
            for i in 0..<3 {
                if let k = pick(minFraction: 0.15, prefer: { graph.degree($0) <= 2 }) {
                    let (c, n) = Pottle.make(habitat: habitat, cell: k, shadow: shadow, scale: crowdScales[(i + 1) % 4]); add(c, n)
                }
            }
            for _ in 0..<2 {
                if let k = pick(minFraction: 0.2, prefer: crossing) {
                    let (c, n) = Chair.make(habitat: habitat, cell: k, shadow: shadow); add(c, n)
                }
            }
            if let k = pick(minFraction: 0.2, prefer: { graph.lit.contains($0) }) {
                let (c, n) = Stalk.make(habitat: habitat, cell: k, shadow: shadow); add(c, n)
            }
            if let k = pick(minFraction: 0.2, prefer: crossing) {
                let (c, n) = Ladder.make(habitat: habitat, cell: k, shadow: shadow); add(c, n)
            }
        }
        ElevatorArrivalTrace.shared.endPhase("Menagerie.cageAndObjectCast", traceCast)
        // Calibration experiment (RealAnimals.swift): a dog and a cat near the start.
        // Delete this line (and that file) to remove them.
        let traceAnimals = ElevatorArrivalTrace.shared.beginPhase("Menagerie.RealAnimals")
        RealAnimals.populate(habitat: habitat, scene: scene, start: start, fromStart: fromStart, busy: busy, shadow: shadow)
        ElevatorArrivalTrace.shared.endPhase("Menagerie.RealAnimals", traceAnimals)
        // Audition (Audition.swift): two more residents. Delete this line (and that file) to remove them.
        let traceAudition = ElevatorArrivalTrace.shared.beginPhase("Menagerie.Audition")
        Audition.populate(habitat: habitat, scene: scene, fromStart: fromStart, busy: busy, shadow: shadow)
        ElevatorArrivalTrace.shared.endPhase("Menagerie.Audition", traceAudition)
        diag("menagerie.installed", ["creatures": critters.count, "caged": cageCell != nil,
                                     "kinds": critters.map { "\($0.kind)" }.joined(separator: ","),
                                     "admissionPending": Admission.isPending])
        return cageCell
    }

    static func shadowImage() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(white: 0, alpha: 0.45).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                                 endCenter: center, endRadius: size.width / 2, options: [])
        }
    }
}

// MARK: - Shared plumbing

nonisolated final class HabitatGraph: @unchecked Sendable {
    let neighbors: [Int: [Int]]
    let centers: [Int: SIMD2<Float>]
    let cellSize: Float
    let lit: Set<Int>

    static func key(row: Int, col: Int) -> Int { row * 100_000 + col }

    init(neighbors: [Int: [Int]], centers: [Int: SIMD2<Float>], cellSize: Float, lit: Set<Int>) {
        self.neighbors = neighbors
        self.centers = centers
        self.cellSize = cellSize
        self.lit = lit
    }

    func degree(_ k: Int) -> Int { neighbors[k]?.count ?? 0 }

    /// Walking distance (in cells) from any of `sources` to every reachable cell.
    func distances(from sources: [Int]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var frontier: [Int] = []
        for k in sources where centers[k] != nil { result[k] = 0; frontier.append(k) }
        var i = 0
        while i < frontier.count {
            let k = frontier[i]; i += 1
            for n in neighbors[k] ?? [] where result[n] == nil {
                result[n] = (result[k] ?? 0) + 1
                frontier.append(n)
            }
        }
        return result
    }

    /// The cell whose centre is nearest `p`.
    func cell(near p: SIMD2<Float>) -> Int? {
        let k = Self.key(row: Int((p.y / cellSize).rounded()), col: Int((p.x / cellSize).rounded()))
        return centers[k] != nil ? k : nil
    }
}

/// Who is where. Refreshed at most 5 times a second by whichever creature
/// ticks first; everyone reads the same snapshot (render thread only).
nonisolated final class Habitat: @unchecked Sendable {
    enum Kind: String { case noodle, player, bobbin, clacker, stalk, ladder, chair, pottle, dog, cat, frog, slinky }

    struct Sighting {
        let id: String
        let kind: Kind
        let pos: SIMD2<Float>
        let velocity: SIMD2<Float>
        weak var critter: Critter?
    }

    struct Sound {
        let pos: SIMD2<Float>
        let time: CFTimeInterval
        let kind: Kind
        let id: String
    }

    let graph: HabitatGraph
    weak var root: SCNNode?
    weak var playerCamera: SCNNode?
    var blockedCells = Set<Int>()            // the closed cage's cell
    private(set) var sightings: [Sighting] = []
    private(set) var sounds: [Sound] = []
    private var residents: [WeakCritter] = []
    private var lastPositions: [String: SIMD2<Float>] = [:]
    private var lastRefresh: CFTimeInterval = 0

    private struct WeakCritter { weak var critter: Critter? }

    init(graph: HabitatGraph, root: SCNNode, playerCamera: SCNNode) {
        self.graph = graph
        self.root = root
        self.playerCamera = playerCamera
    }

    func add(_ critter: Critter) { residents.append(WeakCritter(critter: critter)) }

    func refreshIfNeeded(_ now: CFTimeInterval) {
        guard now - lastRefresh >= 0.2, let root else { return }
        let dt = Float(lastRefresh == 0 ? 0.2 : min(1, now - lastRefresh))
        lastRefresh = now
        var list: [(String, Kind, SIMD2<Float>, Critter?)] = []
        // Oct 6 (Cast stage 1): Jeff by identity (only while he's out with
        // the player -- exactly what the old "tinCanRat" child lookup found).
        if let rat = CritterTags.ecosystemBody(.jeff, under: root), !rat.isHidden {
            let p = rat.presentation.worldPosition
            list.append(("noodle", .noodle, SIMD2<Float>(p.x, p.z), nil))
        }
        if let eye = playerCamera?.presentation.worldPosition {
            list.append(("player", .player, SIMD2<Float>(eye.x, eye.z), nil))
        }
        for (i, node) in root.childNodes.enumerated() where node.name == "bobbin" {
            let p = node.presentation.worldPosition
            list.append(("bobbin\(i)", .bobbin, SIMD2<Float>(p.x, p.z), nil))
        }
        for entry in residents {
            if let c = entry.critter { list.append((c.id, c.kind, c.pos, c)) }
        }
        var fresh: [Sighting] = []
        var positions: [String: SIMD2<Float>] = [:]
        for (id, kind, pos, critter) in list {
            let v = lastPositions[id].map { (pos - $0) / dt } ?? .zero
            let velocity = simd_length(v) > 30 ? SIMD2<Float>(0, 0) : v      // a jump, not a run
            fresh.append(Sighting(id: id, kind: kind, pos: pos, velocity: velocity, critter: critter))
            positions[id] = pos
        }
        sightings = fresh
        lastPositions = positions
        sounds.removeAll { now - $0.time > 3 }
    }

    func post(_ sound: Sound) {
        sounds.append(sound)
        if sounds.count > 16 { sounds.removeFirst(sounds.count - 16) }
    }

    /// Clear sight between two floor points at `height` (walls/doors/furniture block).
    func canSee(_ a: SIMD2<Float>, _ b: SIMD2<Float>, height: Float) -> Bool {
        guard let root else { return false }
        let hits = root.hitTestWithSegment(from: SCNVector3(a.x, height, a.y), to: SCNVector3(b.x, height, b.y), options: [
            SCNHitTestOption.categoryBitMask.rawValue: ~(Menagerie.categoryBit | CritterCategory.storyCritters | Bobbin.categoryBit | Cage.panelBit),
            SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue,
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: false
        ])
        return hits.isEmpty
    }
}

// MARK: - Critter: shared body plumbing (not a shared personality)

nonisolated class Critter: @unchecked Sendable {
    let kind: Habitat.Kind
    let id: String
    let habitat: Habitat
    weak var node: SCNNode?
    let body: SCNNode
    var graph: HabitatGraph { habitat.graph }

    // Cell-to-cell travel with a drifting lane.
    var from: Int
    var to: Int
    var progress: Float = 0
    var cameFrom: Int?
    var lane: Float = 0
    var laneTarget: Float = 0
    var laneClock: Double = 0
    var maxLane: Float = 0.55
    var goal: Int?                          // when set, choices follow the shortest way there
    private var goalDistances: [Int: Int] = [:]
    private var goalFor: Int?

    // Body state.
    var pos: SIMD2<Float>
    var velocity = SIMD2<Float>(0, 0)
    var speed: Float = 0
    var wantSpeed: Float = 0
    var acceleration: Float = 4
    var heading: Float = Float.random(in: 0...(2 * .pi))
    var turnRate: Float = 6
    var lookAt: SIMD2<Float>?
    var pause: Double = 0
    var time: Double = 0
    var personalSpace: Float = 0.7

    // Cage.
    var cage: SIMD2<Float>?
    var cageRadius: Float = 0.42
    private var cageGoal: SIMD2<Float>?

    private var lastTime: CFTimeInterval = 0
    private var senseClock: Double = Double.random(in: 0...0.4)
    var senseInterval: Double = 0.35
    private var aliveClock: Double = 4
    private var aliveLines = 0
    var modeName: String { "?" }

    init(kind: Habitat.Kind, habitat: Habitat, node: SCNNode, body: SCNNode, cell: Int) {
        self.kind = kind
        self.id = "\(kind)-\(UUID().uuidString.prefix(6))"
        self.habitat = habitat
        self.node = node
        self.body = body
        self.from = cell
        self.to = (habitat.graph.neighbors[cell] ?? []).randomElement() ?? cell
        self.pos = habitat.graph.centers[cell] ?? .zero
        node.position = SCNVector3(pos.x, 0, pos.y)
    }

    func tickAction() -> SCNAction {
        // Strong: the action on its own node is the creature's only owner.
        SCNAction.customAction(duration: 1) { _, _ in self.tick() }
    }

    private func tick() {
        guard let node else { return }
        let now = CACurrentMediaTime()
        let dt = Float(lastTime == 0 ? 1.0 / 60 : min(max(now - lastTime, 0), 1.0 / 20))
        lastTime = now
        guard dt > 0 else { return }
        let dtd = Double(dt)
        time += dtd
        habitat.refreshIfNeeded(now)
        senseClock -= dtd
        if senseClock <= 0 {
            senseClock = senseInterval * Double.random(in: 0.8...1.25)
            sense(now: now)
        }
        think(dt: dtd, now: now)
        if pause > 0 { pause -= dtd }
        let target = pause > 0 ? 0 : wantSpeed
        speed += (target - speed) * min(1, dt * acceleration)
        let previous = pos
        if let cage { moveInCage(cage, dt: dt) } else { moveOnGraph(dt: dt) }
        let moved = simd_length(pos - previous)
        velocity = (pos - previous) / dt
        var desired = heading
        if moved / dt > 0.12 {
            desired = atan2(-(pos.x - previous.x), -(pos.y - previous.y))
        } else if let lookAt, simd_length(lookAt - pos) > 0.05 {
            desired = atan2(-(lookAt.x - pos.x), -(lookAt.y - pos.y))
        }
        var turn = desired - heading
        while turn > .pi { turn -= 2 * .pi }
        while turn < -.pi { turn += 2 * .pi }
        let turnStep = turn * min(1, dt * turnRate)
        heading += turnStep
        node.position = SCNVector3(pos.x, 0, pos.y)
        node.eulerAngles = SCNVector3(0, heading, 0)
        animate(dt: dt, moved: moved, turning: turnStep / dt)

        aliveClock -= dtd
        if aliveClock <= 0, aliveLines < 6 {
            aliveClock = 20
            aliveLines += 1
            diag("critter.alive", ["id": id, "mode": modeName, "cell": from, "caged": cage != nil, "speed": speed])
        }
    }

    // Overridden per creature.
    func sense(now: CFTimeInterval) {}
    func think(dt: Double, now: CFTimeInterval) {}
    func animate(dt: Float, moved: Float, turning: Float) {}
    func arrived(at cell: Int) {}
    func giveWay(to other: Habitat.Sighting) {
        pause = Double.random(in: 0.3...0.8)
        if Float.random(in: 0...1) < 0.35 { reverse() }
    }

    /// Default choice: mostly carry on, never back unless it's the only way.
    func choose(options: [Int]) -> Int { roamChoice(options) }

    // MARK: Travel

    private func moveOnGraph(dt: Float) {
        let openWays = (graph.neighbors[from] ?? []).filter { !habitat.blockedCells.contains($0) }
        if from == to || habitat.blockedCells.contains(to) {
            if let next = pickNext(openWays) { to = next } else { to = from }
        }
        // Don't walk into someone just ahead.
        if speed > 0.1, from != to {
            let ahead = direction
            for other in habitat.sightings where other.id != id && other.kind != .player {
                let offset = other.pos - pos
                let d = simd_length(offset)
                if d > 0.001, d < personalSpace, simd_dot(offset / d, ahead) > 0.35 {
                    giveWay(to: other)
                    break
                }
            }
        }
        var move = speed * dt
        while move > 0, from != to {
            let remaining = graph.cellSize - progress
            if move < remaining { progress += move; move = 0 }
            else {
                move -= remaining
                cameFrom = from
                from = to
                progress = 0
                arrived(at: from)
                let options = (graph.neighbors[from] ?? []).filter { !habitat.blockedCells.contains($0) }
                to = pickNext(options) ?? from
            }
        }
        // Loose lane: drifts every few seconds, so nobody rides the centreline.
        laneClock -= Double(dt)
        if laneClock <= 0 {
            laneClock = Double.random(in: 2.5...7)
            laneTarget = Float.random(in: -maxLane...maxLane)
        }
        lane += (laneTarget - lane) * min(1, dt * 0.8)
        let d = direction
        let rail = (graph.centers[from] ?? pos) + d * (from == to ? 0 : progress)
        let desired = rail + SIMD2<Float>(-d.y, d.x) * lane
        pos += (desired - pos) * min(1, dt * 5)
    }

    private func pickNext(_ options: [Int]) -> Int? {
        guard !options.isEmpty else { return nil }
        if let goal, goal != from {
            if goalFor != goal {
                goalDistances = graph.distances(from: [goal])
                goalFor = goal
            }
            if let best = options.min(by: { (goalDistances[$0] ?? 999) < (goalDistances[$1] ?? 999) }),
               (goalDistances[best] ?? 999) < 999 { return best }
        }
        return choose(options: options)
    }

    var direction: SIMD2<Float> {
        guard from != to, let a = graph.centers[from], let b = graph.centers[to] else {
            return SIMD2<Float>(-sin(heading), -cos(heading))
        }
        return simd_normalize(b - a)
    }

    func reverse() {
        guard from != to else { return }
        swap(&from, &to)
        progress = graph.cellSize - progress
        cameFrom = nil
    }

    private func moveInCage(_ center: SIMD2<Float>, dt: Float) {
        if cageGoal == nil || simd_length((cageGoal ?? pos) - pos) < 0.05 {
            if cageGoal != nil { pause = Double.random(in: 0.6...3.5) }
            let angle = Float.random(in: 0...(2 * .pi))
            cageGoal = center + SIMD2<Float>(cos(angle), sin(angle)) * Float.random(in: 0...cageRadius)
        }
        guard let goalPoint = cageGoal else { return }
        let toGoal = goalPoint - pos
        let d = simd_length(toGoal)
        if d > 0.0001 { pos += toGoal / d * min(d, speed * 0.45 * dt) }
    }

    /// Let out: from here on it uses the floor like everyone else.
    func release() {
        guard let center = cage else { return }
        cage = nil
        let here = graph.cell(near: center) ?? from
        from = here
        progress = 0
        cameFrom = nil
        to = pickNext(graph.neighbors[here] ?? []) ?? here
    }

    // MARK: Choices

    func roamChoice(_ options: [Int]) -> Int {
        let forward = options.filter { $0 != cameFrom }
        let pool = forward.isEmpty ? options : forward
        if let prev = cameFrom.flatMap({ graph.centers[$0] }), let here = graph.centers[from] {
            let straight = pool.first { k in
                guard let c = graph.centers[k] else { return false }
                return simd_dot(simd_normalize(here - prev), simd_normalize(c - here)) > 0.9
            }
            if let straight, Float.random(in: 0...1) < 0.5 { return straight }
        }
        return pool.randomElement() ?? options[0]
    }

    func choice(_ options: [Int], toward point: SIMD2<Float>) -> Int {
        options.min { simd_length((graph.centers[$0] ?? pos) - point) < simd_length((graph.centers[$1] ?? pos) - point) } ?? options[0]
    }

    func choice(_ options: [Int], awayFrom point: SIMD2<Float>) -> Int {
        options.max { simd_length((graph.centers[$0] ?? pos) - point) < simd_length((graph.centers[$1] ?? pos) - point) } ?? options[0]
    }

    // MARK: Senses

    func nearest(_ kinds: Set<Habitat.Kind>, within range: Float) -> (Habitat.Sighting, Float)? {
        var best: (Habitat.Sighting, Float)?
        for s in habitat.sightings where s.id != id && kinds.contains(s.kind) {
            let d = simd_length(s.pos - pos)
            if d < range, best == nil || d < best!.1 { best = (s, d) }
        }
        return best
    }

    /// How fast `s` is closing on me (m/s, positive = approaching).
    func closingSpeed(_ s: Habitat.Sighting) -> Float {
        let toMe = pos - s.pos
        let d = simd_length(toMe)
        guard d > 0.001 else { return 0 }
        return simd_dot(s.velocity, toMe / d)
    }

    // MARK: Voice

    func say(_ source: SCNAudioSource?, loud: Bool = true) {
        guard let source, let node else { return }
        CritterAudio.play(source, on: node)
        if loud { habitat.post(Habitat.Sound(pos: pos, time: CACurrentMediaTime(), kind: kind, id: id)) }
    }

    // MARK: Model helpers

    static func mat(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.65, glow: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        if let glow { m.emission.contents = glow }
        return m
    }

    @discardableResult
    static func part(_ geometry: SCNGeometry, _ material: SCNMaterial, in parent: SCNNode,
                     at p: SCNVector3 = SCNVector3Zero, euler: SCNVector3 = SCNVector3Zero, name: String? = nil) -> SCNNode {
        geometry.materials = [material]
        let n = SCNNode(geometry: geometry)
        n.position = p
        n.eulerAngles = euler
        n.name = name
        parent.addChildNode(n)
        return n
    }

    static func pivot(in parent: SCNNode, at p: SCNVector3, name: String? = nil) -> SCNNode {
        let n = SCNNode()
        n.position = p
        n.name = name
        parent.addChildNode(n)
        return n
    }

    static func addShadow(_ image: UIImage, size: CGFloat, to root: SCNNode) {
        let plane = SCNPlane(width: size, height: size)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let n = SCNNode(geometry: plane)
        n.eulerAngles.x = -.pi / 2
        n.position.y = 0.004
        n.renderingOrder = 1
        root.addChildNode(n)
    }
}

// MARK: - Sound: everything synthesised, cached as tiny mono WAVs

nonisolated enum MenagerieSound {
    static let rate: Float = Float(BobbinSound.rate)

    /// Renders (once per install of the app) and loads a positional source.
    static func source(_ name: String, volume: Float, _ render: () -> [Float]) -> SCNAudioSource? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mng-v1-\(name).wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? BobbinSound.wav(normalized(render())).write(to: url)) != nil else { return nil }
        }
        guard let s = SCNAudioSource(url: url) else { return nil }
        s.isPositional = true
        s.shouldStream = false
        s.volume = volume
        s.load()
        return s
    }

    static func variants(_ name: String, count: Int, volume: Float, _ render: (inout Rand) -> [Float]) -> [SCNAudioSource] {
        (0..<count).compactMap { i in
            var rng = Rand(seed: UInt64(i) &* 7919 &+ UInt64(name.count))
            return source("\(name)-\(i)", volume: volume) { render(&rng) }
        }
    }

    static func normalized(_ x: [Float]) -> [Float] {
        let peak = x.map { abs($0) }.max() ?? 0
        guard peak > 0.0001 else { return x }
        return x.map { $0 / peak * 0.8 }
    }

    static func silence(_ seconds: Float) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }

    /// A struck object: decaying sine partials (freq Hz, decay s, amplitude).
    static func strike(_ partials: [(Float, Float, Float)], seconds: Float, noise: Float = 0, noiseDecay: Float = 0.002,
                       rng: inout Rand) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var lp: Float = 0
        for i in 0..<n {
            let t = Float(i) / rate
            var v: Float = 0
            for (f, decay, a) in partials { v += sin(2 * .pi * f * t) * exp(-t / decay) * a }
            let w = rng.unit() * 2 - 1
            lp += (w - lp) * 0.35
            v += lp * exp(-t / noiseDecay) * noise
            out[i] = v * min(1, t / 0.0005)
        }
        return out
    }

    /// A sweep (Hz) with a soft envelope; `wobble` adds a little roughness.
    static func sweep(_ f0: Float, _ f1: Float, seconds: Float, wobble: Float = 0, curve: Float = 1) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        for i in 0..<n {
            let u = Float(i) / Float(n)
            let f = f0 + (f1 - f0) * pow(u, curve)
            phase += 2 * .pi * f / rate
            out[i] = sin(phase + wobble * sin(phase * 0.5)) * sin(.pi * u)
        }
        return out
    }

    /// Stick-slip creak: a slowing train of tiny impulses ringing a resonance.
    static func creak(resonance: Float, q: Float, startHz: Float, endHz: Float, seconds: Float, rng: inout Rand) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        let w = 2 * Float.pi * resonance / rate
        let r = 1 - (Float.pi * resonance / q) / rate
        var y1: Float = 0, y2: Float = 0
        var clock: Float = 0
        for i in 0..<n {
            let u = Float(i) / Float(n)
            let hz = startHz + (endHz - startHz) * u + (rng.unit() - 0.5) * 6
            clock += hz / rate
            var x: Float = 0
            if clock >= 1 { clock -= 1; x = 0.8 + rng.unit() * 0.4 }
            let y = 2 * r * cos(w) * y1 - r * r * y2 + x
            y2 = y1; y1 = y
            out[i] = y * sin(.pi * u)
        }
        return out
    }

    /// Short bursts of bright noise, scattered: leaves, papers, bristles.
    static func rustle(grains: Int, seconds: Float, grainLength: Float, rng: inout Rand) -> [Float] {
        var out = [Float](repeating: 0, count: Int(seconds * rate))
        let g = Int(grainLength * rate)
        for _ in 0..<grains {
            let start = Int(rng.unit() * Float(max(1, out.count - g)))
            var prev: Float = 0
            let amp = 0.3 + rng.unit() * 0.7
            for j in 0..<g where start + j < out.count {
                let w = rng.unit() * 2 - 1
                let hp = w - prev; prev = w
                out[start + j] += hp * amp * sin(.pi * Float(j) / Float(g))
            }
        }
        return out
    }

    static func mix(_ parts: [(at: Float, samples: [Float], gain: Float)]) -> [Float] {
        let length = parts.map { Int($0.at * rate) + $0.samples.count }.max() ?? 0
        var out = [Float](repeating: 0, count: length)
        for p in parts {
            let o = Int(p.at * rate)
            for (i, v) in p.samples.enumerated() { out[o + i] += v * p.gain }
        }
        return out
    }

    struct Rand {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x2545F4914F6CDD1D }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
        mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * unit() }
    }
}

typealias Rand = MenagerieSound.Rand

// MARK: - Clacker

nonisolated final class Clacker: Critter {
    enum Mode: String { case forage, seek, attend, flee }
    private var mode: Mode = .forage
    private var modeTime: Double = 0
    private var hopsLeft = Int.random(in: 1...4)
    private var hopPhase: Float = 0
    private var peckTime: Float = 0
    private var callClock = Double.random(in: 2...8)
    private var replyAt: Double?
    private var alarmCooldown: Double = 0
    private var seekPoint: SIMD2<Float>?
    private var threat: SIMD2<Float>?
    private let jaw: SCNNode?
    private let legs: [SCNNode]
    private let sizeScale: Float

    private static let calls = MenagerieSound.variants("clacker-call", count: 4, volume: 0.75) { rng in
        let snap = MenagerieSound.strike([(rng.range(2900, 3400), 0.012, 0.5), (rng.range(5200, 6100), 0.006, 0.25)],
                                         seconds: 0.04, noise: 0.9, noiseDecay: 0.0015, rng: &rng)
        let a = rng.range(3300, 3800)
        let chirp = MenagerieSound.sweep(a, a * rng.range(1.25, 1.45), seconds: rng.range(0.06, 0.09), wobble: 0.6, curve: 0.7)
        let chirp2 = MenagerieSound.sweep(a * 1.1, a * rng.range(0.9, 1.3), seconds: 0.05, wobble: 0.4)
        return MenagerieSound.mix([(0, snap, 1), (0.035, chirp, 0.7), (rng.range(0.11, 0.16), chirp2, 0.5)])
    }
    private static let alarm = MenagerieSound.source("clacker-alarm", volume: 0.85) {
        var rng = Rand(seed: 41)
        var parts: [(at: Float, samples: [Float], gain: Float)] = []
        var at: Float = 0
        for _ in 0..<6 {
            parts.append((at, MenagerieSound.strike([(rng.range(2800, 3600), 0.01, 0.5)], seconds: 0.03, noise: 1, rng: &rng), 1))
            parts.append((at + 0.012, MenagerieSound.sweep(4200, 5400, seconds: 0.03), 0.4))
            at += rng.range(0.045, 0.07)
        }
        return MenagerieSound.mix(parts)
    }
    private static let ticks = MenagerieSound.variants("clacker-tick", count: 4, volume: 0.25) { rng in
        MenagerieSound.strike([(rng.range(1800, 2400), 0.006, 0.4)], seconds: 0.025, noise: 0.6, noiseDecay: 0.001, rng: &rng)
    }

    override var modeName: String { mode.rawValue }

    static func make(habitat: Habitat, cell: Int, shadow: UIImage, scale: Float) -> (Critter, SCNNode) {
        let root = SCNNode()
        root.name = "clacker"
        root.scale = SCNVector3(scale, scale, scale)
        addShadow(shadow, size: 0.32, to: root)
        let body = pivot(in: root, at: SCNVector3(0, 0.11, 0))
        let steel = mat(UIColor(white: 0.25, alpha: 1), metal: 0.3, rough: 0.4)
        let red = mat(UIColor(red: 0.82, green: 0.08, blue: 0.07, alpha: 1), rough: 0.35)
        let chrome = mat(UIColor(white: 0.8, alpha: 1), metal: 0.5, rough: 0.3)
        part(SCNBox(width: 0.06, height: 0.025, length: 0.24, chamferRadius: 0.008), steel, in: body)
        part(SCNBox(width: 0.045, height: 0.012, length: 0.04, chamferRadius: 0.003), chrome, in: body, at: SCNVector3(0, 0.016, -0.1))
        // The top arm -- hinged at the back, opens at the front.
        let jaw = pivot(in: body, at: SCNVector3(0, 0.02, 0.105), name: "jaw")
        part(SCNBox(width: 0.055, height: 0.032, length: 0.225, chamferRadius: 0.012), red, in: jaw, at: SCNVector3(0, 0.017, -0.105))
        let white = mat(.white, rough: 0.3, glow: UIColor(white: 0.25, alpha: 1))
        let black = mat(.black, rough: 0.2)
        for side in [Float(-1), 1] {
            let eye = part(SCNSphere(radius: 0.012), white, in: jaw, at: SCNVector3(side * 0.029, 0.03, -0.17))
            part(SCNSphere(radius: 0.006), black, in: eye, at: SCNVector3(side * 0.006, 0, -0.006))
        }
        // A little spring-steel tail.
        part(SCNBox(width: 0.02, height: 0.004, length: 0.07, chamferRadius: 0.001), chrome, in: body,
             at: SCNVector3(0, 0.02, 0.14), euler: SCNVector3(-0.5, 0, 0))
        let orange = mat(UIColor(red: 0.95, green: 0.55, blue: 0.1, alpha: 1))
        var legs: [SCNNode] = []
        for side in [Float(-1), 1] {
            let hip = pivot(in: body, at: SCNVector3(side * 0.018, -0.012, 0.01), name: "leg")
            part(SCNCylinder(radius: 0.0025, height: 0.095), steel, in: hip, at: SCNVector3(0, -0.048, 0))
            part(SCNBox(width: 0.02, height: 0.004, length: 0.03, chamferRadius: 0.002), orange, in: hip, at: SCNVector3(0, -0.097, -0.008))
            legs.append(hip)
        }
        let critter = Clacker(habitat: habitat, node: root, body: body, cell: cell, jaw: jaw, legs: legs, scale: scale)
        return (critter, root)
    }

    init(habitat: Habitat, node: SCNNode, body: SCNNode, cell: Int, jaw: SCNNode, legs: [SCNNode], scale: Float) {
        self.jaw = jaw
        self.legs = legs
        self.sizeScale = scale
        super.init(kind: .clacker, habitat: habitat, node: node, body: body, cell: cell)
        maxLane = 0.9
        personalSpace = 0.45
        acceleration = 10
        turnRate = 12
        senseInterval = 0.25
    }

    private func set(_ m: Mode) { mode = m; modeTime = 0 }

    override func sense(now: CFTimeInterval) {
        alarmCooldown = max(0, alarmCooldown - senseInterval)
        // Anything big coming at it fast, or right on top of it: off it goes.
        for s in habitat.sightings where s.id != id && s.kind != .clacker && s.kind != .pottle {
            let d = simd_length(s.pos - pos)
            if d < 1.0 || (d < 2.6 && closingSpeed(s) > 1.2) {
                threat = s.pos
                if mode != .flee {
                    set(.flee)
                    pause = 0
                    hopsLeft = 12
                    if alarmCooldown <= 0 { say(Self.alarm); alarmCooldown = 2.5 }
                    if cage == nil, simd_dot(direction, s.pos - pos) > 0 { reverse() }
                }
                return
            }
        }
        guard mode != .flee else { return }
        // A sound somewhere (not its own): sometimes go and see; another
        // clacker's call: sometimes answer.
        if let heard = habitat.sounds.last(where: { $0.id != id && now - $0.time < 1.2 }),
           simd_length(heard.pos - pos) < 16 {
            if heard.kind == .clacker, replyAt == nil, Float.random(in: 0...1) < 0.45 {
                replyAt = time + Double.random(in: 0.3...1.3)
            }
            if mode == .forage, Float.random(in: 0...1) < 0.35 {
                seekPoint = heard.pos
                set(.seek)
                goal = graph.cell(near: heard.pos)
            }
        }
        // Noodle, sitting still nearby: worth a closer look.
        if mode == .forage, case let (n, d)? = nearest([.noodle], within: 5), simd_length(n.velocity) < 0.3, d > 1.1,
           habitat.canSee(pos, n.pos, height: 0.15) {
            if Float.random(in: 0...1) < 0.3 { set(.attend); seekPoint = n.pos; goal = graph.cell(near: n.pos) }
        }
    }

    override func think(dt: Double, now: CFTimeInterval) {
        modeTime += dt
        switch mode {
        case .flee:
            wantSpeed = 3.0
            if modeTime > 3 { set(.forage); threat = nil; hopsLeft = 0; pause = Double.random(in: 0.5...1.5) }
        case .seek:
            wantSpeed = 1.7
            if let p = seekPoint, simd_length(p - pos) < 1.2 || modeTime > 8 { set(.forage); goal = nil; pause = 1 }
        case .attend:
            wantSpeed = 1.1
            lookAt = seekPoint
            if let p = seekPoint, simd_length(p - pos) < 1.0 { goal = nil; wantSpeed = 0 }
            if modeTime > 7 { set(.forage); goal = nil; lookAt = nil }
        case .forage:
            wantSpeed = hopsLeft > 0 ? 1.25 : 0
        }
        // Hop bursts: a few hops, a stop to peck, again.
        if hopsLeft <= 0 && pause <= 0 && mode != .flee {
            pause = Double.random(in: 0.4...2.2)
            peckTime = Float.random(in: 0.3...1.2)
            hopsLeft = Int.random(in: 2...6)
        }
        if let r = replyAt, time >= r { replyAt = nil; say(Self.calls.randomElement()) }
        callClock -= dt
        if callClock <= 0 {
            callClock = cage != nil ? Double.random(in: 2.5...7) : Double.random(in: 4...12)
            say(Self.calls.randomElement())
        }
    }

    override func choose(options: [Int]) -> Int {
        if mode == .flee, let threat { return choice(options, awayFrom: threat) }
        return roamChoice(options)
    }

    override func animate(dt: Float, moved: Float, turning: Float) {
        // Hops: each 0.2 m of travel is one arc; landing ticks.
        let before = hopPhase
        hopPhase += moved / (0.2 * sizeScale)
        if floor(hopPhase) > floor(before) {
            hopsLeft -= 1
            if Float.random(in: 0...1) < 0.7 { say(Self.ticks.randomElement(), loud: false) }
        }
        let inHop = speed > 0.15
        let arc = inHop ? sin((hopPhase - floor(hopPhase)) * .pi) : 0
        body.position.y = 0.11 + arc * 0.07
        for leg in legs { leg.eulerAngles.x = inHop ? -0.6 * arc : 0 }
        // Pecking while paused: tip forward, snap the jaw.
        var pitch: Float = inHop ? 0.15 * arc : 0
        var jawOpen: Float = mode == .flee ? 0.5 + 0.3 * sin(Float(time) * 40) : 0
        if !inHop, peckTime > 0 {
            peckTime -= dt
            let p = sin(Float(time) * 14)
            pitch = -0.35 * max(0, p)
            jawOpen = 0.35 * max(0, -p)
        } else if !inHop, mode == .forage {
            jawOpen = 0.05 * (1 + sin(Float(time) * 1.7))
        }
        body.eulerAngles = SCNVector3(pitch, 0, sin(Float(time) * 3.1) * 0.04)
        jaw?.eulerAngles.x = jawOpen
    }
}

// MARK: - Stalk

nonisolated final class Stalk: Critter {
    enum Mode: String { case wander, bask, peer, startled }
    private var mode: Mode = .wander
    private var modeTime: Double = 0
    private var stepPhase: Float = 0
    private var peerAt: SIMD2<Float>?
    private var bend: Float = 0          // 0 = standing tall, 1 = bowed right down
    private var sway: Float = 0
    private var swayVelocity: Float = 0
    private var flicker: Double = 0
    private var humClock = Double.random(in: 6...14)
    private var peerCooldown: Double = 0
    private let base: SCNNode
    private let neck: SCNNode
    private let head: SCNNode
    private let bulb: SCNMaterial
    private let lamp: SCNLight

    private static let steps = MenagerieSound.variants("stalk-step", count: 4, volume: 0.4) { rng in
        let k = rng.range(0.9, 1.1)
        let clunk = MenagerieSound.strike([(180 * k, 0.09, 0.5), (412 * k, 0.06, 0.3), (1270 * k, 0.03, 0.12), (2210 * k, 0.02, 0.06)],
                                          seconds: 0.22, noise: 0.3, noiseDecay: 0.004, rng: &rng)
        let scrape = MenagerieSound.rustle(grains: 40, seconds: 0.12, grainLength: 0.004, rng: &rng)
        return MenagerieSound.mix([(0, scrape, 0.25), (0.06, clunk, 1)])
    }
    private static let buzz = MenagerieSound.source("stalk-buzz", volume: 0.7) {
        var rng = Rand(seed: 77)
        let n = Int(0.5 * MenagerieSound.rate)
        var out = [Float](repeating: 0, count: n)
        var gate: Float = 1
        for i in 0..<n {
            let t = Float(i) / MenagerieSound.rate
            if i % 900 == 0 { gate = rng.unit() < 0.3 ? 0.1 : 1 }
            var v: Float = 0
            for h in 1...9 { v += sin(2 * .pi * 120 * Float(h) * t) / Float(h) }
            out[i] = v * gate * sin(.pi * t / 0.5)
        }
        return out
    }
    private static let hum = MenagerieSound.source("stalk-hum", volume: 0.3) {
        let n = Int(1.4 * MenagerieSound.rate)
        return (0..<n).map { i -> Float in
            let t = Float(i) / MenagerieSound.rate
            let v = sin(2 * .pi * 120 * t) + 0.4 * sin(2 * .pi * 240 * t) + 0.15 * sin(2 * .pi * 360 * t)
            return v * sin(.pi * t / 1.4) * (1 + 0.2 * sin(2 * .pi * 3 * t))
        }
    }
    private static let creak = MenagerieSound.source("stalk-creak", volume: 0.45) {
        var rng = Rand(seed: 5)
        return MenagerieSound.creak(resonance: 900, q: 18, startHz: 55, endHz: 25, seconds: 0.55, rng: &rng)
    }

    override var modeName: String { mode.rawValue }

    static func make(habitat: Habitat, cell: Int, shadow: UIImage) -> (Critter, SCNNode) {
        let root = SCNNode()
        root.name = "stalk"
        addShadow(shadow, size: 0.5, to: root)
        let body = pivot(in: root, at: SCNVector3(0, 0, 0))
        let brass = mat(UIColor(red: 0.72, green: 0.56, blue: 0.3, alpha: 1), metal: 0.45, rough: 0.35)
        let black = mat(UIColor(white: 0.12, alpha: 1), metal: 0.3, rough: 0.4)
        let shadeMat = mat(UIColor(red: 0.95, green: 0.9, blue: 0.78, alpha: 1), rough: 0.8,
                           glow: UIColor(red: 0.35, green: 0.28, blue: 0.15, alpha: 1))
        shadeMat.isDoubleSided = true
        let base = pivot(in: body, at: SCNVector3(0, 0.015, 0))
        part(SCNCylinder(radius: 0.17, height: 0.03), brass, in: base)
        part(SCNCylinder(radius: 0.012, height: 0.95), black, in: base, at: SCNVector3(0, 0.49, 0))
        let joint = pivot(in: base, at: SCNVector3(0, 0.96, 0))
        part(SCNSphere(radius: 0.03), brass, in: joint)
        let neck = pivot(in: joint, at: SCNVector3Zero, name: "neck")
        part(SCNCylinder(radius: 0.01, height: 0.7), black, in: neck, at: SCNVector3(0, 0.35, 0))
        let head = pivot(in: neck, at: SCNVector3(0, 0.7, 0), name: "head")
        part(SCNSphere(radius: 0.02), brass, in: head)
        part(SCNCone(topRadius: 0.055, bottomRadius: 0.15, height: 0.18), shadeMat, in: head, at: SCNVector3(0, -0.07, 0))
        let bulb = mat(UIColor(white: 1, alpha: 1), rough: 0.2, glow: UIColor(red: 1, green: 0.85, blue: 0.55, alpha: 1))
        part(SCNSphere(radius: 0.04), bulb, in: head, at: SCNVector3(0, -0.11, 0))
        let light = SCNLight()
        light.type = .omni
        light.color = UIColor(red: 1, green: 0.85, blue: 0.6, alpha: 1)
        light.intensity = 250
        light.attenuationStartDistance = 0.2
        light.attenuationEndDistance = 2.6
        light.castsShadow = false
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(0, -0.14, 0)
        head.addChildNode(lightNode)
        let critter = Stalk(habitat: habitat, node: root, body: body, cell: cell, base: base, neck: neck, head: head, bulb: bulb, lamp: light)
        return (critter, root)
    }

    init(habitat: Habitat, node: SCNNode, body: SCNNode, cell: Int, base: SCNNode, neck: SCNNode, head: SCNNode,
         bulb: SCNMaterial, lamp: SCNLight) {
        self.base = base
        self.neck = neck
        self.head = head
        self.bulb = bulb
        self.lamp = lamp
        super.init(kind: .stalk, habitat: habitat, node: node, body: body, cell: cell)
        maxLane = 0.4
        personalSpace = 0.9
        acceleration = 1.5
        turnRate = 2.2
        senseInterval = 0.45
    }

    private func set(_ m: Mode) { mode = m; modeTime = 0 }

    override func sense(now: CFTimeInterval) {
        peerCooldown = max(0, peerCooldown - senseInterval)
        // Something rushing right up to it: head up, flicker, shuffle off.
        if mode != .startled, case let (s, d)? = nearest([.noodle, .player, .chair, .ladder, .bobbin], within: 1.4),
           closingSpeed(s) > 1.0 || d < 0.7 {
            set(.startled)
            flicker = 0.8
            peerAt = nil
            say(Self.buzz)
            if simd_dot(direction, s.pos - pos) > 0 { reverse() }
            goal = nil
            return
        }
        // Small things nearby: bow down for a good long look.
        if mode == .wander || mode == .bask, peerCooldown <= 0,
           case let (s, _)? = nearest([.noodle, .clacker, .pottle, .bobbin], within: 2.8),
           simd_length(s.velocity) < 1.5, habitat.canSee(pos, s.pos, height: 0.6), Float.random(in: 0...1) < 0.5 {
            set(.peer)
            peerAt = s.pos
            if Float.random(in: 0...1) < 0.4 { say(Self.creak, loud: false) }
        }
        if mode == .peer, let s = habitat.sightings.first(where: { simd_length($0.pos - (peerAt ?? pos)) < 1.2 && $0.id != id }) {
            peerAt = s.pos         // keep watching it if it shuffles a little
        }
    }

    override func think(dt: Double, now: CFTimeInterval) {
        modeTime += dt
        switch mode {
        case .wander:
            wantSpeed = 0.42
            if goal == nil, Float.random(in: 0...1) < Float(dt) * 0.08, let lit = graph.lit.randomElement() {
                goal = lit           // now and then it sets off for somewhere bright
            }
        case .bask:
            wantSpeed = 0
            humClock -= dt
            if humClock <= 0 { humClock = Double.random(in: 7...16); say(Self.hum, loud: false) }
            if modeTime > Double.random(in: 8...20) { set(.wander) }
        case .peer:
            wantSpeed = 0
            lookAt = peerAt
            if modeTime > 4.5 { set(.wander); lookAt = nil; peerCooldown = Double.random(in: 6...12) }
        case .startled:
            wantSpeed = 0.75
            if modeTime > 3.5 { set(.wander) }
        }
        flicker = max(0, flicker - dt)
    }

    override func arrived(at cell: Int) {
        if goal == cell { goal = nil }
        if mode == .wander, graph.lit.contains(cell), Float.random(in: 0...1) < 0.6 {
            set(.bask)
        }
    }

    override func choose(options: [Int]) -> Int {
        let lit = options.filter { graph.lit.contains($0) && $0 != cameFrom }
        if mode != .startled, !lit.isEmpty, Float.random(in: 0...1) < 0.7 { return lit.randomElement() ?? options[0] }
        return roamChoice(options)
    }

    override func animate(dt: Float, moved: Float, turning: Float) {
        // Rock-shuffle: the base tips onto one edge, then the other.
        stepPhase += moved / 0.16 * .pi
        let rocking = min(1, speed / 0.3)
        let before = sin(stepPhase - moved / 0.16 * .pi)
        let now = sin(stepPhase)
        if rocking > 0.3, (before < 0) != (now < 0) { say(Self.steps.randomElement(), loud: false) }
        base.eulerAngles = SCNVector3(abs(now) * -0.05 * rocking, 0, now * 0.11 * rocking)
        // The long neck lags behind the base like a sprung pole.
        let force = -sway * 30 - swayVelocity * 4 + (now * 0.11 * rocking) * 20 + turning * 0.2
        swayVelocity += force * dt
        sway += swayVelocity * dt
        // Bowing to look at something small.
        var wantBend: Float = 0
        if mode == .peer, let p = peerAt {
            wantBend = min(1, max(0.35, 1.4 - simd_length(p - pos) / 2.5))
        }
        bend += (wantBend - bend) * min(1, dt * (mode == .startled ? 6 : 1.2))
        neck.eulerAngles = SCNVector3(-0.25 - bend * 1.15, 0, sway * 0.6)
        head.eulerAngles = SCNVector3(0.25 + bend * 0.5, 0, 0)
        // The bulb: brighter when looking, flickers when startled.
        var glow: Float = 1 + (mode == .peer ? 0.6 * bend : 0) + (mode == .bask ? 0.2 : 0)
        if flicker > 0 { glow *= Float.random(in: 0...1) < 0.5 ? 0.15 : 1.2 }
        bulb.emission.intensity = CGFloat(glow)
        lamp.intensity = CGFloat(250 * glow)
    }
}

// MARK: - Ladder

nonisolated final class Ladder: Critter {
    enum Mode: String { case commute, survey, accompany, standAside }
    private var mode: Mode = .commute
    private var modeTime: Double = 0
    private var homes: [Int] = []
    private var homeIndex = 0
    private var companion: String?
    private var companyCooldown: Double = 12
    private var stridePhase: Float = 0
    private var creakClock = Double.random(in: 10...25)
    private let front: SCNNode
    private let back: SCNNode
    private let cap: SCNNode

    private static let clonks = MenagerieSound.variants("ladder-step", count: 6, volume: 0.42) { rng in
        let k = rng.range(0.88, 1.12)
        return MenagerieSound.strike([(212 * k, 0.05, 0.5), (523 * k, 0.03, 0.32), (1013 * k, 0.015, 0.16), (1730 * k, 0.008, 0.08)],
                                     seconds: 0.16, noise: 0.5, noiseDecay: 0.002, rng: &rng)
    }
    private static let creaks = MenagerieSound.variants("ladder-creak", count: 2, volume: 0.55) { rng in
        let a = MenagerieSound.creak(resonance: rng.range(320, 380), q: 9, startHz: rng.range(32, 40), endHz: 18, seconds: 0.45, rng: &rng)
        let b = MenagerieSound.creak(resonance: rng.range(260, 300), q: 9, startHz: 22, endHz: rng.range(30, 38), seconds: 0.35, rng: &rng)
        return MenagerieSound.mix([(0, a, 1), (0.42, b, 0.8)])
    }

    override var modeName: String { mode.rawValue }

    static func make(habitat: Habitat, cell: Int, shadow: UIImage) -> (Critter, SCNNode) {
        let root = SCNNode()
        root.name = "ladder"
        addShadow(shadow, size: 0.7, to: root)
        let body = pivot(in: root, at: SCNVector3(0, 1.22, 0))
        let wood = mat(UIColor(red: 0.74, green: 0.55, blue: 0.33, alpha: 1), rough: 0.75)
        let paint = mat(UIColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 1), rough: 0.9)
        let dark = mat(UIColor(white: 0.1, alpha: 1), rough: 0.3)
        func half(_ name: String) -> SCNNode {
            let p = pivot(in: body, at: SCNVector3Zero, name: name)
            for side in [Float(-1), 1] {
                part(SCNBox(width: 0.03, height: 1.26, length: 0.022, chamferRadius: 0.004), wood, in: p, at: SCNVector3(side * 0.17, -0.63, 0))
            }
            for i in 1...3 {
                part(SCNBox(width: 0.34, height: 0.02, length: 0.07, chamferRadius: 0.003), wood, in: p,
                     at: SCNVector3(0, -0.3 * Float(i) - 0.05, 0))
            }
            // A few drips of old paint -- it's had a working life.
            part(SCNBox(width: 0.05, height: 0.003, length: 0.07, chamferRadius: 0.001), paint, in: p, at: SCNVector3(0.06, -0.39, 0))
            return p
        }
        let front = half("front")
        let back = half("back")
        // The cap: the top step, which turns to look about, with two eyes.
        let cap = pivot(in: body, at: SCNVector3(0, 0.02, 0), name: "cap")
        part(SCNBox(width: 0.4, height: 0.04, length: 0.22, chamferRadius: 0.01), wood, in: cap)
        for side in [Float(-1), 1] {
            let eye = part(SCNSphere(radius: 0.02), mat(.white, rough: 0.3, glow: UIColor(white: 0.2, alpha: 1)), in: cap,
                           at: SCNVector3(side * 0.07, 0.035, -0.08))
            part(SCNSphere(radius: 0.01), dark, in: eye, at: SCNVector3(0, 0.004, -0.013))
        }
        let critter = Ladder(habitat: habitat, node: root, body: body, cell: cell, front: front, back: back, cap: cap)
        return (critter, root)
    }

    init(habitat: Habitat, node: SCNNode, body: SCNNode, cell: Int, front: SCNNode, back: SCNNode, cap: SCNNode) {
        self.front = front
        self.back = back
        self.cap = cap
        super.init(kind: .ladder, habitat: habitat, node: node, body: body, cell: cell)
        maxLane = 0.35
        personalSpace = 1.0
        acceleration = 2.5
        turnRate = 3
        senseInterval = 0.5
        // Two favourite crossings, far apart: its commute.
        let crossings = graph.centers.keys.filter { graph.degree($0) >= 3 }
        let pool = crossings.count >= 2 ? crossings : Array(graph.centers.keys)
        let first = pool.randomElement() ?? cell
        let far = graph.distances(from: [first])
        let second = pool.max { (far[$0] ?? 0) < (far[$1] ?? 0) } ?? cell
        homes = [first, second]
        homeIndex = Int.random(in: 0...1)
        goal = homes[homeIndex]
    }

    private func set(_ m: Mode) { mode = m; modeTime = 0 }

    override func sense(now: CFTimeInterval) {
        companyCooldown = max(0, companyCooldown - senseInterval)
        // Noodle about to walk into it: step to one side and wait.
        if mode != .standAside, case let (n, d)? = nearest([.noodle], within: 1.5), d < 1.5, closingSpeed(n) > 0.4 {
            set(.standAside)
            let side = simd_dot(n.pos - pos, SIMD2<Float>(-direction.y, direction.x)) > 0 ? Float(-1) : 1
            laneTarget = side * maxLane * 1.4
            pause = Double.random(in: 0.6...1.4)
            return
        }
        // Someone to keep company with, now and then.
        if mode == .commute, companyCooldown <= 0,
           case let (s, _)? = nearest([.stalk, .chair, .pottle, .clacker, .bobbin], within: 7),
           habitat.canSee(pos, s.pos, height: 1.0), Float.random(in: 0...1) < 0.25 {
            set(.accompany)
            companion = s.id
            goal = graph.cell(near: s.pos)
        }
    }

    override func think(dt: Double, now: CFTimeInterval) {
        modeTime += dt
        switch mode {
        case .commute:
            wantSpeed = 1.0
            goal = homes[homeIndex]
            lookAt = nil
        case .survey:
            wantSpeed = 0
            if modeTime > Double.random(in: 4...9) {
                homeIndex = 1 - homeIndex
                set(.commute)
            }
        case .accompany:
            wantSpeed = 0.9
            if let s = habitat.sightings.first(where: { $0.id == companion }) {
                let d = simd_length(s.pos - pos)
                if d < 1.7 { wantSpeed = 0; lookAt = s.pos; goal = nil }
                else if d > 9 { set(.commute); companyCooldown = 25 }
                else { goal = graph.cell(near: s.pos) }
            }
            if modeTime > Double.random(in: 9...14) || companion == nil {
                set(.commute); companion = nil; lookAt = nil; companyCooldown = Double.random(in: 20...40)
            }
        case .standAside:
            wantSpeed = 0.3
            if modeTime > 2.2 { set(.commute); laneTarget = 0 }
        }
        creakClock -= dt
        if creakClock <= 0 {
            creakClock = Double.random(in: 14...35)
            say(Self.creaks.randomElement())
        }
    }

    override func arrived(at cell: Int) {
        if mode == .commute, cell == homes[homeIndex] {
            goal = nil
            set(.survey)
        }
    }

    override func giveWay(to other: Habitat.Sighting) {
        // It doesn't turn round for anyone; it waits, edging aside.
        pause = Double.random(in: 0.5...1.2)
        laneTarget = -lane
    }

    override func animate(dt: Float, moved: Float, turning: Float) {
        // Two legs: the halves of the A-frame swing alternately; the whole
        // ladder rolls side to side over each planted foot.
        let before = stridePhase
        stridePhase += moved / 0.34 * .pi
        if floor(before / .pi) != floor(stridePhase / .pi), speed > 0.2 { say(Self.clonks.randomElement(), loud: false) }
        let walking = min(1, speed / 0.5)
        let s = sin(stridePhase)
        front.eulerAngles.x = 0.2 + s * 0.22 * walking
        back.eulerAngles.x = -0.2 + s * 0.22 * walking
        body.position.y = 1.22 + abs(cos(stridePhase)) * 0.025 * walking
        body.eulerAngles = SCNVector3(0, 0, s * 0.07 * walking)
        // Surveying: the cap turns to look about, unhurriedly.
        var capYaw: Float = 0
        if mode == .survey { capYaw = sin(Float(modeTime) * 0.9) * 0.9 }
        if mode == .standAside { capYaw = 0.5 }
        cap.eulerAngles.y += (capYaw - cap.eulerAngles.y) * min(1, dt * 2)
    }
}

// MARK: - Chair

nonisolated final class Chair: Critter {
    enum Mode: String { case graze, freeze, bolt, tagAlong }
    private var mode: Mode = .graze
    private var modeTime: Double = 0
    private var gait: Float = 0
    private var threat: SIMD2<Float>?
    private var nervous: Double = 0           // after a scare it won't freeze again straight away
    private var grazeClock = Double.random(in: 2...5)
    private var grazing: Double = 0
    private var creakClock = Double.random(in: 8...20)
    private var landed = true
    private let legs: [SCNNode]
    private let seat: SCNNode

    private static let taps = MenagerieSound.variants("chair-step", count: 4, volume: 0.22) { rng in
        MenagerieSound.strike([(rng.range(380, 460), 0.025, 0.4), (rng.range(900, 1100), 0.012, 0.2)],
                              seconds: 0.07, noise: 0.4, noiseDecay: 0.0015, rng: &rng)
    }
    private static let thumps = MenagerieSound.variants("chair-thump", count: 3, volume: 0.55) { rng in
        let k = rng.range(0.9, 1.1)
        return MenagerieSound.strike([(150 * k, 0.07, 0.6), (330 * k, 0.05, 0.35), (720 * k, 0.025, 0.15)],
                                     seconds: 0.2, noise: 0.6, noiseDecay: 0.004, rng: &rng)
    }
    private static let alarm = MenagerieSound.source("chair-alarm", volume: 0.8) {
        var rng = Rand(seed: 19)
        let knock = { (rng: inout Rand) -> [Float] in
            MenagerieSound.strike([(640, 0.03, 0.5), (1450, 0.015, 0.3), (2600, 0.008, 0.12)], seconds: 0.08, noise: 0.7,
                                  noiseDecay: 0.001, rng: &rng)
        }
        let a = knock(&rng)
        let b = knock(&rng)
        return MenagerieSound.mix([(0, a, 1), (0.085, b, 0.85)])
    }
    private static let creak = MenagerieSound.source("chair-creak", volume: 0.4) {
        var rng = Rand(seed: 23)
        return MenagerieSound.creak(resonance: 470, q: 11, startHz: 28, endHz: 44, seconds: 0.4, rng: &rng)
    }

    override var modeName: String { mode.rawValue }

    static func make(habitat: Habitat, cell: Int, shadow: UIImage) -> (Critter, SCNNode) {
        let root = SCNNode()
        root.name = "chair"
        addShadow(shadow, size: 0.75, to: root)
        let body = pivot(in: root, at: SCNVector3(0, 0.46, 0))
        let wood = mat(UIColor(red: 0.45, green: 0.28, blue: 0.16, alpha: 1), rough: 0.55)
        let cushion = mat(UIColor(red: 0.2, green: 0.36, blue: 0.3, alpha: 1), rough: 0.95)
        let seat = pivot(in: body, at: SCNVector3Zero, name: "seat")
        part(SCNBox(width: 0.42, height: 0.04, length: 0.42, chamferRadius: 0.01), wood, in: seat)
        part(SCNBox(width: 0.38, height: 0.03, length: 0.38, chamferRadius: 0.015), cushion, in: seat, at: SCNVector3(0, 0.03, 0))
        // The back rest, at the rear -- it flicks up when alarmed.
        for side in [Float(-1), 1] {
            part(SCNCylinder(radius: 0.017, height: 0.5), wood, in: seat, at: SCNVector3(side * 0.18, 0.25, 0.19))
        }
        part(SCNBox(width: 0.4, height: 0.07, length: 0.025, chamferRadius: 0.01), wood, in: seat, at: SCNVector3(0, 0.46, 0.19))
        part(SCNBox(width: 0.36, height: 0.03, length: 0.02, chamferRadius: 0.005), wood, in: seat, at: SCNVector3(0, 0.3, 0.19))
        var legs: [SCNNode] = []
        let corners: [(Float, Float)] = [(-0.18, -0.18), (0.18, -0.18), (-0.18, 0.18), (0.18, 0.18)]   // FL FR BL BR
        for c in corners {
            let hip = pivot(in: seat, at: SCNVector3(c.0, -0.02, c.1), name: "leg")
            part(SCNCylinder(radius: 0.016, height: 0.44), wood, in: hip, at: SCNVector3(0, -0.22, 0))
            legs.append(hip)
        }
        let critter = Chair(habitat: habitat, node: root, body: body, cell: cell, seat: seat, legs: legs)
        return (critter, root)
    }

    init(habitat: Habitat, node: SCNNode, body: SCNNode, cell: Int, seat: SCNNode, legs: [SCNNode]) {
        self.seat = seat
        self.legs = legs
        super.init(kind: .chair, habitat: habitat, node: node, body: body, cell: cell)
        maxLane = 0.6
        personalSpace = 0.9
        acceleration = 3
        turnRate = 5
        senseInterval = 0.3
    }

    private func set(_ m: Mode) { mode = m; modeTime = 0 }

    override func sense(now: CFTimeInterval) {
        nervous = max(0, nervous - senseInterval)
        let scary: Set<Habitat.Kind> = [.noodle, .player, .ladder, .bobbin]
        // Anyone getting close: freeze first (if it can see them), then bolt.
        if mode == .graze || mode == .tagAlong, nervous <= 0,
           case let (s, d)? = nearest(scary, within: 4.5), d < 2 || habitat.canSee(pos, s.pos, height: 0.6) {
            threat = s.pos
            set(.freeze)
            return
        }
        if mode == .bolt, case let (s, _)? = nearest(scary, within: 6) { threat = s.pos }
        // The tall lamp-thing: it likes to keep it in sight, not too close.
        if mode == .graze, case let (lamp, d)? = nearest([.stalk], within: 10), d > 3.5,
           habitat.canSee(pos, lamp.pos, height: 0.8), Float.random(in: 0...1) < 0.3 {
            set(.tagAlong)
            goal = graph.cell(near: lamp.pos)
        }
    }

    override func think(dt: Double, now: CFTimeInterval) {
        modeTime += dt
        switch mode {
        case .graze:
            wantSpeed = grazing > 0 ? 0 : 0.55
            grazing = max(0, grazing - dt)
            grazeClock -= dt
            if grazeClock <= 0 { grazeClock = Double.random(in: 6...14); grazing = Double.random(in: 2...6) }
        case .freeze:
            wantSpeed = 0
            pause = 0
            lookAt = threat
            if modeTime > Double.random(in: 0.7...1.3) {
                set(.bolt)
                say(Self.alarm)
                goal = nil
                if let threat, simd_dot(direction, threat - pos) > 0 { reverse() }
            }
        case .bolt:
            wantSpeed = 3.6
            lookAt = nil
            if modeTime > 4, threat.map({ simd_length($0 - pos) > 6 }) ?? true {
                set(.graze); nervous = 4; grazing = Double.random(in: 1...3)
            }
            if modeTime > 8 { set(.graze); nervous = 4 }
        case .tagAlong:
            wantSpeed = 0.7
            if let lamp = habitat.sightings.first(where: { $0.kind == .stalk }) {
                let d = simd_length(lamp.pos - pos)
                if d < 3 { wantSpeed = 0; lookAt = lamp.pos; goal = nil } else { goal = graph.cell(near: lamp.pos); lookAt = nil }
            }
            if modeTime > Double.random(in: 15...30) { set(.graze); goal = nil; lookAt = nil }
        }
        creakClock -= dt
        if creakClock <= 0, mode == .graze {
            creakClock = Double.random(in: 10...25)
            say(Self.creak, loud: false)
        }
    }

    override func choose(options: [Int]) -> Int {
        if mode == .bolt, let threat { return choice(options, awayFrom: threat) }
        // It likes open crossings: it heads for them when it can.
        let crossings = options.filter { graph.degree($0) >= 3 && $0 != cameFrom }
        if mode == .graze, !crossings.isEmpty, Float.random(in: 0...1) < 0.6 { return crossings.randomElement() ?? options[0] }
        return roamChoice(options)
    }

    override func arrived(at cell: Int) {
        if mode == .graze, graph.degree(cell) >= 3, Float.random(in: 0...1) < 0.5 { grazing = Double.random(in: 3...8) }
    }

    override func animate(dt: Float, moved: Float, turning: Float) {
        let bounding = mode == .bolt && speed > 1.5
        let before = gait
        gait += moved / (bounding ? 0.9 : 0.2) * .pi
        let cycles = floor(gait / .pi) != floor(before / .pi)
        let s = sin(gait)
        let walking = min(1, speed / 0.4)
        if bounding {
            // Bounds: front pair together, back pair together, body arcing.
            let lift = max(0, s)
            body.position.y = 0.46 + lift * 0.16
            seat.eulerAngles = SCNVector3(cos(gait) * 0.22, 0, 0)
            for (i, leg) in legs.enumerated() { leg.eulerAngles.x = (i < 2 ? 1 : -1) * cos(gait) * 0.55 }
            if cycles, s < 0.2 { say(Self.thumps.randomElement(), loud: false) }
            landed = false
        } else {
            body.position.y = 0.46 + abs(s) * 0.012 * walking
            var pitch: Float = 0
            if grazing > 0, mode == .graze { pitch = -0.18 + 0.05 * sin(Float(time) * 2.3) }   // nose down, nibbling
            if mode == .freeze { pitch = 0.12 }                                                 // back up, rigid
            seat.eulerAngles.x += (pitch - seat.eulerAngles.x) * min(1, dt * 6)
            seat.eulerAngles.z = mode == .freeze ? 0 : s * 0.03 * walking
            for (i, leg) in legs.enumerated() {
                let pairOffset: Float = (i == 0 || i == 3) ? 0 : .pi
                leg.eulerAngles.x = sin(gait + pairOffset) * 0.4 * walking
            }
            if cycles, walking > 0.4, Float.random(in: 0...1) < 0.6 { say(Self.taps.randomElement(), loud: false) }
            if !landed { landed = true; say(Self.thumps.randomElement(), loud: false) }
        }
    }
}

// MARK: - Pottle

nonisolated final class Pottle: Critter {
    enum Mode: String { case seekCorner, settled, uneasy, relocate }
    private var mode: Mode = .seekCorner
    private var modeTime: Double = 0
    private var pivotPhase: Float = 0
    private var shiver: Float = 0
    private var leafSway: Float = 0
    private var rustleClock = Double.random(in: 10...25)
    private var corner: Int?
    private let pot: SCNNode
    private let plant: SCNNode
    private let sizeScale: Float

    private static let tocks = MenagerieSound.variants("pottle-tock", count: 5, volume: 0.35) { rng in
        let k = rng.range(0.92, 1.08)
        return MenagerieSound.strike([(640 * k, 0.03, 0.5), (1480 * k, 0.018, 0.3), (2650 * k, 0.01, 0.12)],
                                     seconds: 0.09, noise: 0.35, noiseDecay: 0.006, rng: &rng)
    }
    private static let rustles = MenagerieSound.variants("pottle-rustle", count: 3, volume: 0.45) { rng in
        MenagerieSound.rustle(grains: Int(rng.range(18, 34)), seconds: rng.range(0.3, 0.55), grainLength: 0.004, rng: &rng)
    }

    override var modeName: String { mode.rawValue }

    static func make(habitat: Habitat, cell: Int, shadow: UIImage, scale: Float) -> (Critter, SCNNode) {
        let root = SCNNode()
        root.name = "pottle"
        root.scale = SCNVector3(scale, scale, scale)
        addShadow(shadow, size: 0.42, to: root)
        let body = pivot(in: root, at: SCNVector3Zero)
        let clay = mat(UIColor(red: 0.74, green: 0.38, blue: 0.22, alpha: 1), rough: 0.85)
        let soil = mat(UIColor(red: 0.18, green: 0.12, blue: 0.08, alpha: 1), rough: 1)
        let leaf = mat(UIColor(red: 0.2, green: 0.55, blue: 0.22, alpha: 1), rough: 0.6)
        let petal = mat(UIColor(red: 0.98, green: 0.82, blue: 0.2, alpha: 1), rough: 0.5)
        let pot = pivot(in: body, at: SCNVector3Zero, name: "pot")
        part(SCNCone(topRadius: 0.15, bottomRadius: 0.105, height: 0.24), clay, in: pot, at: SCNVector3(0, 0.12, 0))
        part(SCNTorus(ringRadius: 0.15, pipeRadius: 0.018), clay, in: pot, at: SCNVector3(0, 0.235, 0))
        part(SCNCylinder(radius: 0.14, height: 0.01), soil, in: pot, at: SCNVector3(0, 0.225, 0))
        let plant = pivot(in: pot, at: SCNVector3(0, 0.23, 0), name: "plant")
        for i in 0..<5 {
            let a = Float(i) / 5 * 2 * .pi + 0.3
            let stem = pivot(in: plant, at: SCNVector3Zero)
            stem.eulerAngles = SCNVector3(0.55 * cos(a), 0, 0.55 * sin(a))
            part(SCNCylinder(radius: 0.005, height: 0.14), leaf, in: stem, at: SCNVector3(0, 0.07, 0))
            let blade = part(SCNSphere(radius: 0.045), leaf, in: stem, at: SCNVector3(0, 0.15, 0))
            blade.scale = SCNVector3(0.5, 1.2, 0.18)
        }
        part(SCNCylinder(radius: 0.005, height: 0.3), leaf, in: plant, at: SCNVector3(0, 0.15, 0))
        part(SCNSphere(radius: 0.03), petal, in: plant, at: SCNVector3(0, 0.31, 0))
        let critter = Pottle(habitat: habitat, node: root, body: body, cell: cell, pot: pot, plant: plant, scale: scale)
        return (critter, root)
    }

    init(habitat: Habitat, node: SCNNode, body: SCNNode, cell: Int, pot: SCNNode, plant: SCNNode, scale: Float) {
        self.pot = pot
        self.plant = plant
        self.sizeScale = scale
        super.init(kind: .pottle, habitat: habitat, node: node, body: body, cell: cell)
        maxLane = 0.5
        personalSpace = 0.6
        acceleration = 2
        turnRate = 2.5
        senseInterval = 0.5
    }

    private func set(_ m: Mode) { mode = m; modeTime = 0 }

    private func findCorner() {
        let ends = graph.centers.keys.filter { graph.degree($0) == 1 && $0 != corner && !habitat.blockedCells.contains($0) }
        let occupied = Set(habitat.sightings.filter { $0.id != id }.compactMap { graph.cell(near: $0.pos) })
        let free = ends.filter { !occupied.contains($0) }
        let near = graph.distances(from: [from])
        corner = (free.isEmpty ? ends : free).min { (near[$0] ?? 999) < (near[$1] ?? 999) }
        goal = corner
    }

    override func sense(now: CFTimeInterval) {
        guard cage == nil else {
            if nearest([.clacker], within: 0.5) != nil { shiver = 1 }
            return
        }
        let company = nearest([.noodle, .player, .clacker, .chair, .ladder, .bobbin, .stalk], within: 2.2)
        let birds = nearest([.clacker], within: 3)
        switch mode {
        case .settled:
            if company != nil || birds != nil {
                set(.uneasy)
                shiver = 1
                say(Self.rustles.randomElement())
            }
        case .uneasy:
            if company == nil && birds == nil, modeTime > 2 { set(.settled) }
            else if modeTime > 3 || birds != nil && modeTime > 1 {
                set(.relocate)
                findCorner()
            }
        default:
            if company != nil { shiver = max(shiver, 0.5) }
        }
    }

    override func think(dt: Double, now: CFTimeInterval) {
        modeTime += dt
        switch mode {
        case .seekCorner, .relocate:
            wantSpeed = mode == .relocate ? 0.42 : 0.3
            if corner == nil { findCorner() }
            if goal == nil, let c = corner, c == from { set(.settled); laneTarget = maxLane * (Bool.random() ? 1 : -1) }
        case .settled, .uneasy:
            wantSpeed = 0
            rustleClock -= dt
            if rustleClock <= 0, mode == .settled {
                rustleClock = Double.random(in: 12...30)
                say(Self.rustles.randomElement(), loud: false)
            }
        }
        if cage != nil { wantSpeed = 0.35 }
        shiver = max(0, shiver - Float(dt) * 0.5)
    }

    override func arrived(at cell: Int) {
        if cell == corner { goal = nil; set(.settled); laneTarget = maxLane * (Bool.random() ? 1 : -1) }
    }

    override func giveWay(to other: Habitat.Sighting) {
        pause = Double.random(in: 0.8...2)       // it waits; it doesn't back off
        shiver = max(shiver, 0.6)
    }

    override func animate(dt: Float, moved: Float, turning: Float) {
        // Walks by tipping onto its rim and pivoting: left edge, right edge.
        let before = pivotPhase
        pivotPhase += moved / (0.12 * sizeScale) * .pi
        if floor(before / .pi) != floor(pivotPhase / .pi), speed > 0.08 { say(Self.tocks.randomElement(), loud: false) }
        let walking = min(1, speed / 0.2)
        let s = sin(pivotPhase)
        pot.eulerAngles = SCNVector3(-0.06 * walking, s * 0.05 * walking, s * 0.17 * walking)
        pot.position.y = abs(s) * 0.012 * walking
        // Leaves: lag behind the pot; shiver when uneasy.
        leafSway += ((-s * 0.25 * walking) - leafSway) * min(1, dt * 4)
        let jitter = shiver > 0 ? sin(Float(time) * 47) * 0.12 * shiver : 0
        let breeze = sin(Float(time) * 0.7 + Float(id.count)) * 0.03
        plant.eulerAngles = SCNVector3(jitter + breeze, 0, leafSway + jitter * 0.7)
        if cage != nil, Float.random(in: 0...1) < dt * 0.05 { shiver = 1 }
    }
}

// MARK: - The enclosure

/// A wire cage in a cell. No sign, no prompt. If Noodle noses at its door for
/// a couple of seconds, the latch gives and the door swings open; whoever is
/// inside comes out in their own time (or not straight away). Closed, its
/// cell is off the map for the other creatures; Noodle simply bumps its bars.
nonisolated final class Cage: @unchecked Sendable {
    static let panelBit = 1 << 12
    let node: SCNNode
    var inmates: [Critter] = []
    private let habitat: Habitat
    private let cell: Int
    private let doorPoint: SIMD2<Float>
    private let door: SCNNode
    private var nudge: Double = 0
    private var isOpen = false
    private var releaseAt: [Double] = []
    private var clock: Double = 0
    private var lastTime: CFTimeInterval = 0
    private var rattleClock = Double.random(in: 8...16)

    private static let creak = MenagerieSound.source("cage-creak", volume: 0.8) {
        var rng = Rand(seed: 101)
        let a = MenagerieSound.creak(resonance: 1150, q: 30, startHz: 70, endHz: 28, seconds: 0.9, rng: &rng)
        let b = MenagerieSound.creak(resonance: 2300, q: 40, startHz: 60, endHz: 35, seconds: 0.7, rng: &rng)
        let clank = MenagerieSound.strike([(520, 0.15, 0.5), (1310, 0.1, 0.3), (2870, 0.05, 0.2)], seconds: 0.35,
                                          noise: 0.6, noiseDecay: 0.003, rng: &rng)
        return MenagerieSound.mix([(0, clank, 0.8), (0.05, a, 1), (0.2, b, 0.5)])
    }
    private static let rattle = MenagerieSound.source("cage-rattle", volume: 0.35) {
        var rng = Rand(seed: 202)
        var parts: [(at: Float, samples: [Float], gain: Float)] = []
        for i in 0..<5 {
            parts.append((Float(i) * rng.range(0.04, 0.07),
                          MenagerieSound.strike([(rng.range(1900, 2500), 0.04, 0.4), (rng.range(4100, 4800), 0.02, 0.2)],
                                                seconds: 0.08, noise: 0.3, rng: &rng), 1))
        }
        return MenagerieSound.mix(parts)
    }

    init(habitat: Habitat, cell: Int, center: SIMD2<Float>, doorToward: SIMD2<Float>) {
        self.habitat = habitat
        self.cell = cell
        let root = SCNNode()
        root.name = "cage"
        root.position = SCNVector3(center.x, 0, center.y)
        let toward = simd_normalize(doorToward - center)
        root.eulerAngles.y = atan2(-toward.x, -toward.y)       // local -z faces the way out
        doorPoint = center + toward * 0.8
        let metal = Critter.mat(UIColor(white: 0.22, alpha: 1), metal: 0.5, rough: 0.4)
        let side: Float = 1.4, height: Float = 1.0
        let bar = SCNCylinder(radius: 0.008, height: CGFloat(height))
        bar.materials = [metal]
        let count = 10
        func bars(_ parent: SCNNode, from a: SIMD2<Float>, to b: SIMD2<Float>) {
            for i in 0...count {
                let p = a + (b - a) * Float(i) / Float(count)
                let n = SCNNode(geometry: bar)
                n.position = SCNVector3(p.x, height / 2, p.y)
                parent.addChildNode(n)
            }
        }
        let h = side / 2
        bars(root, from: SIMD2(-h, h), to: SIMD2(h, h))          // back
        bars(root, from: SIMD2(-h, -h), to: SIMD2(-h, h))        // left
        bars(root, from: SIMD2(h, -h), to: SIMD2(h, h))          // right
        // The door: the front wall of bars, hinged at its left edge.
        let hinge = SCNNode()
        hinge.position = SCNVector3(-h, 0, -h)
        root.addChildNode(hinge)
        bars(hinge, from: SIMD2(0, 0), to: SIMD2(side, 0))
        let latch = SCNNode(geometry: SCNBox(width: 0.05, height: 0.08, length: 0.03, chamferRadius: 0.005))
        latch.geometry?.materials = [Critter.mat(UIColor(red: 0.7, green: 0.55, blue: 0.2, alpha: 1), metal: 0.6, rough: 0.3)]
        latch.position = SCNVector3(side - 0.03, 0.55, -0.02)
        hinge.addChildNode(latch)
        door = hinge
        // Invisible solid panels behind the bars, so Noodle's (single-line)
        // wall probes can't slip between them. Own category bit: sight lines
        // (Habitat.canSee) look straight through them.
        let panel = SCNBox(width: CGFloat(side), height: CGFloat(height), length: 0.03, chamferRadius: 0)
        let clear = SCNMaterial()
        clear.transparency = 0
        clear.writesToDepthBuffer = false
        clear.colorBufferWriteMask = []
        panel.materials = [clear]
        for (parent, x, z, rot) in [(root, Float(0), h, Float(0)), (root, -h, 0, Float.pi / 2), (root, h, 0, Float.pi / 2),
                                    (hinge, h, 0, Float(0))] {
            let p = SCNNode(geometry: panel)
            p.position = SCNVector3(x, height / 2, z)
            p.eulerAngles.y = rot
            p.categoryBitMask = Cage.panelBit
            parent.addChildNode(p)
        }
        // Rails top and bottom, and a lid of thin slats.
        let rail = SCNBox(width: CGFloat(side), height: 0.02, length: 0.02, chamferRadius: 0)
        rail.materials = [metal]
        for y in [Float(0.01), height] {
            for (dx, dz, rot) in [(Float(0), h, Float(0)), (0, -h, 0), (-h, 0, Float.pi / 2), (h, 0, Float.pi / 2)] {
                let r = SCNNode(geometry: rail)
                r.position = SCNVector3(dx, y, dz)
                r.eulerAngles.y = rot
                root.addChildNode(r)
            }
        }
        let slat = SCNBox(width: CGFloat(side), height: 0.008, length: 0.012, chamferRadius: 0)
        slat.materials = [metal]
        for i in 0...6 {
            let s = SCNNode(geometry: slat)
            s.position = SCNVector3(0, height, -h + side * Float(i) / 6)
            root.addChildNode(s)
        }
        node = root
    }

    func tickAction() -> SCNAction {
        SCNAction.customAction(duration: 1) { _, _ in self.tick() }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 1.0 / 60 : min(max(now - lastTime, 0), 1.0 / 20)
        lastTime = now
        clock += dt
        if !isOpen {
            // Noodle nosing at the door wears the latch loose; walking off
            // lets it settle back slowly.
            let noodle = habitat.sightings.first { $0.kind == .noodle }
            if let n = noodle, simd_length(n.pos - doorPoint) < 1.3 { nudge += dt } else { nudge = max(0, nudge - dt * 0.3) }
            if nudge > 2.2 { swingOpen() }
            rattleClock -= dt
            if rattleClock <= 0 {
                rattleClock = Double.random(in: 9...22)
                if let rattle = Self.rattle { CritterAudio.play(rattle, on: node) }
            }
        }
        for (i, at) in releaseAt.enumerated().reversed() where clock >= at {
            if i < inmates.count { inmates[i].release() }
            releaseAt[i] = .infinity
        }
    }

    private func swingOpen() {
        isOpen = true
        let swing = SCNAction.rotateBy(x: 0, y: CGFloat(Float.pi * 0.6), z: 0, duration: 1.1)
        swing.timingMode = .easeOut
        door.runAction(swing)
        if let creak = Self.creak { CritterAudio.play(creak, on: node) }
        habitat.blockedCells.remove(cell)
        // They don't all bolt at once.
        releaseAt = inmates.map { _ in clock + Double.random(in: 0.8...9) }
        diag("cage.opened", ["inmates": inmates.count])
    }
}
