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
                        busyCells: Set<GridCoordinate>, floor: Int = 0) -> GridCoordinate? {
        let tracePhase = ElevatorArrivalTrace.shared.beginPhase("Menagerie.install")
        defer { ElevatorArrivalTrace.shared.endPhase("Menagerie.install", tracePhase) }
        guard cells.count >= 20 else { return nil }      // the lobby and tiny floors stay quiet
        let traceGraph = ElevatorArrivalTrace.shared.beginPhase("Menagerie.habitatGraph")
        func key(_ c: GridCoordinate) -> Int { HabitatGraph.key(row: c.row, col: c.col) }
        let graph = makeGraph(cells: cells, cellSize: cellSize, doors: doors, litCells: litCells)
        let neighbors = graph.neighbors
        let centers = graph.centers
        var coordOf: [Int: GridCoordinate] = [:]
        for c in cells { coordOf[key(c)] = c }
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
        // (Oct 16: the ambient cast only while LivingWorld.ambientCritters -- off for now.)
        let ambient = LivingWorld.ambientCritters
        var cageCell: GridCoordinate?
        if ambient, LivingWorld.fullCast, let k = pick(minFraction: 0.45, prefer: deadEnd), let center = centers[k] {   // Oct 4 DIAGNOSTIC: cage only at ALL / 32
            cageCell = coordOf[k]
            let doorToward = (neighbors[k] ?? []).first.flatMap { centers[$0] } ?? (center + SIMD2<Float>(0, 1))
            let cage = Cage(habitat: habitat, cell: k, center: center, doorToward: doorToward)
            scene.rootNode.addChildNode(cage.node)
            LivingWorld.trackStructure(cage.node)
            cage.node.runAction(.repeatForever(cage.tickAction()), forKey: "cageTick")
            habitat.blockedCells.insert(k)
            // (Oct 19, Stage A: the two caged Clackers retired -- the Pottle alone.)
            let inmates: [(Critter, SCNNode)] = [
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
        if ambient, let k = pick(minFraction: 0.3, prefer: { graph.lit.contains($0) }) {
            let (c, n) = Stalk.make(habitat: habitat, cell: k, shadow: shadow); add(c, n)
        }
        if ambient, let k = pick(minFraction: 0.35, prefer: crossing) {
            let (c, n) = Ladder.make(habitat: habitat, cell: k, shadow: shadow); add(c, n)
        }
        if ambient, let k = pick(minFraction: 0.55, prefer: crossing) {
            let (c, n) = Chair.make(habitat: habitat, cell: k, shadow: shadow); add(c, n)
        }
        if ambient, let k = pick(minFraction: 0.3, prefer: deadEnd) {
            let (c, n) = Pottle.make(habitat: habitat, cell: k, shadow: shadow, scale: 1); add(c, n)
        }
        // Oct 4 DIAGNOSTIC "DOUBLE THE ZOO" (32 setting only): more of the lighter
        // office-object species, spread over the floor by the same pick() rules.
        if ambient, LivingWorld.isCrowd {
            let crowdScales: [Float] = [1, 0.9, 0.95, 0.85]
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
        // (Oct 19, Stage A: the RealAnimals dog and cat retired; AnimalBuild and
        // AnimalVoice stay in RealAnimals.swift for the Frog, Slinky and the meeting.)
        // Audition (Audition.swift): two more residents. Delete this line (and that file) to remove them.
        let traceAudition = ElevatorArrivalTrace.shared.beginPhase("Menagerie.Audition")
        if ambient { Audition.populate(habitat: habitat, scene: scene, fromStart: fromStart, busy: busy, shadow: shadow) }
        ElevatorArrivalTrace.shared.endPhase("Menagerie.Audition", traceAudition)
        // Oct 16 -- THE FIRST MONSTER AUDITION: the Big Shot (one, Floor 3).
        // Oct 22 (later): RETIRED -- no longer placed at all (was: off unless
        // `-HallwaysBigShot YES`). His class, voice recipes and eviction script
        // remain below as unreachable code until a build confirms they can go.
        diag("menagerie.installed", ["creatures": critters.count, "caged": cageCell != nil,
                                     "kinds": critters.map { "\($0.kind)" }.joined(separator: ","),
                                     "admissionPending": Admission.isPending])
        return cageCell
    }

    /// The floor as the creatures walk it: a node per cell, joined where the
    /// cells meet with no door between them. (Oct 16: shared with the eviction,
    /// which needs one for the lobby, a floor too small for a menagerie.)
    static func makeGraph(cells: Set<GridCoordinate>, cellSize: CGFloat, doors: [(GridCoordinate, Direction)],
                          litCells: Set<GridCoordinate>) -> HabitatGraph {
        func key(_ c: GridCoordinate) -> Int { HabitatGraph.key(row: c.row, col: c.col) }
        var blocked = Set<Int64>()
        func edge(_ a: Int, _ b: Int) -> Int64 { Int64(min(a, b)) << 32 | Int64(max(a, b)) }
        for (coord, direction) in doors {
            blocked.insert(edge(key(coord), key(GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col))))
        }
        var neighbors: [Int: [Int]] = [:]
        var centers: [Int: SIMD2<Float>] = [:]
        for c in cells {
            centers[key(c)] = SIMD2<Float>(Float(CGFloat(c.col) * cellSize), Float(CGFloat(c.row) * cellSize))
            neighbors[key(c)] = Direction.allCases.compactMap { d in
                let n = GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
                guard cells.contains(n), !blocked.contains(edge(key(c), key(n))) else { return nil }
                return key(n)
            }
        }
        return HabitatGraph(neighbors: neighbors, centers: centers, cellSize: Float(cellSize), lit: Set(litCells.map(key)))
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
        guard p.x.isFinite, p.y.isFinite, abs(p.x) < 1e6, abs(p.y) < 1e6 else { return nil }   // (Oct 16: never trap on Int(nan))
        let k = Self.key(row: Int((p.y / cellSize).rounded()), col: Int((p.x / cellSize).rounded()))
        return centers[k] != nil ? k : nil
    }
}

/// Who is where. Refreshed at most 5 times a second by whichever creature
/// ticks first; everyone reads the same snapshot (render thread only).
nonisolated final class Habitat: @unchecked Sendable {
    enum Kind: String { case noodle, player, bobbin, stalk, ladder, chair, pottle, frog, slinky, bigShot }

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

// MARK: - Oct 11: errands

/// Something a critter has to do somewhere (see Critter.errand). Subclassed
/// by MeetingProcession; `step` is called from the critter's own tick.
nonisolated class CritterErrand: @unchecked Sendable {
    func step(_ critter: Critter, dt: Double, now: CFTimeInterval) {}
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

    // Oct 11 -- ERRANDS (MeetingProcession): somewhere to be. While `errand`
    // is set its own senses and choices sit out and the errand drives speed,
    // goal, pauses and looks; body, gait, voice and travel stay its own.
    var errand: CritterErrand?
    /// Height above the floor (a hop an errand asks for); 0 otherwise.
    var lift: Float = 0
    /// Off-graph travel (e.g. through an opened door into a room): when set,
    /// the critter heads straight for this point instead of along the graph.
    var freePoint: SIMD2<Float>?

    /// Sets off on `errand` toward graph cell `cell` from where it stands.
    /// Main thread, BEFORE the critter's tick starts running.
    func beginErrand(_ errand: CritterErrand, toward cell: Int) {
        self.errand = errand
        goal = cell
        progress = 0
        cameFrom = nil
        to = pickNext(graph.neighbors[from] ?? []) ?? from
        maxLane = 0.12
        lane = 0
        laneTarget = 0
    }

    private var lastTime: CFTimeInterval = 0
    /// Oct 16: set (main thread) while a script drives this body; read by the tick.
    var suspended = false
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
        SCNAction.customAction(duration: 1) { _, _ in let p = PerfMonitor.begin("critter.tick"); self.tick(); PerfMonitor.end(p) }   // (Oct 21: timed, measurement only)
    }

    private func tick() {
        guard let node else { return }
        // Oct 16 (Bonzo's eviction): a script has the body for now -- its own
        // tick stands aside entirely (the script moves it; see BonzoEviction).
        if suspended { lastTime = 0; return }
        let now = CACurrentMediaTime()
        let dt = Float(lastTime == 0 ? 1.0 / 60 : min(max(now - lastTime, 0), 1.0 / 20))
        lastTime = now
        guard dt > 0 else { return }
        let dtd = Double(dt)
        time += dtd
        habitat.refreshIfNeeded(now)
        if let errand {
            errand.step(self, dt: dtd, now: now)            // Oct 11: on an errand
        } else if fleeBigShot(dt: dtd) {
            // Oct 16 (the Big Shot): scattering -- its own senses and choices wait.
        } else {
            senseClock -= dtd
            if senseClock <= 0 {
                senseClock = senseInterval * Double.random(in: 0.8...1.25)
                sense(now: now)
            }
            think(dt: dtd, now: now)
        }
        if suspended { return }                     // (Oct 16: a script took the body during this very tick)
        if pause > 0 { pause -= dtd }
        let target = pause > 0 ? 0 : wantSpeed
        speed += (target - speed) * min(1, dt * acceleration)
        let previous = pos
        if let cage { moveInCage(cage, dt: dt) }
        else if let point = freePoint { moveFree(toward: point, dt: dt) }   // Oct 11 (errands)
        else { moveOnGraph(dt: dt) }
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
        node.position = SCNVector3(pos.x, lift, pos.y)
        node.eulerAngles = SCNVector3(0, heading, 0)
        animate(dt: dt, moved: moved, turning: turnStep / dt)

        aliveClock -= dtd
        if aliveClock <= 0, aliveLines < 6 {
            aliveClock = 20
            aliveLines += 1
            diag("critter.alive", ["id": id, "mode": modeName, "cell": from, "caged": cage != nil, "speed": speed])
        }
    }

    // MARK: Oct 16 -- scattering from the Big Shot (every loose critter, the
    // same simple rule; its own personality resumes the moment he's gone)

    private var panicFrom: SIMD2<Float>?
    private var panicClock: Double = 0
    private var panicCheck: Double = Double.random(in: 0...0.3)
    private var calmSpeed: Float = 0
    /// How fast this creature scurries away (a species may set its own).
    var panicSpeed: Float = 2.3

    /// True while it is fleeing (and its own brain is sitting out).
    private func fleeBigShot(dt: Double) -> Bool {
        // (Frog and Slinky move themselves in their own animation -- hopping, stepping --
        // so they aren't driven away; they just carry on.)
        guard kind != .bigShot, kind != .frog, kind != .slinky, cage == nil else { return false }
        panicCheck -= dt
        if panicCheck <= 0 {
            panicCheck = 0.25
            if case let (s, d)? = nearest([.bigShot], within: panicFrom == nil ? BigShot.scareRadius : BigShot.calmRadius) {
                if panicFrom == nil {
                    calmSpeed = wantSpeed
                    if from != to, simd_dot(direction, s.pos - pos) > 0.2 { reverse() }   // turn tail
                    goal = nil
                    lookAt = nil
                    pause = 0
                    diag("bigShot.scatter", ["who": id, "distance": (d * 10).rounded() / 10])
                    scattered()
                }
                panicFrom = s.pos
                panicClock = 1.4
            }
        }
        guard panicFrom != nil else { return false }
        panicClock -= dt
        if panicClock <= 0 {
            panicFrom = nil
            wantSpeed = calmSpeed                       // back to whatever it was doing
            return false
        }
        // Its own kind of hurry: about 2.5x its usual pace (never more than panicSpeed).
        // Cornered (nowhere further away to go), it holds still.
        wantSpeed = from == to ? 0 : min(panicSpeed, max(calmSpeed, 0.6) * 2.5)
        pause = 0
        return true
    }

    /// Oct 16: the moment it starts scattering (a species may change pose -- stand up, turn to run).
    func scattered() {}

    // Overridden per creature.
    func sense(now: CFTimeInterval) {}
    func think(dt: Double, now: CFTimeInterval) {}
    func animate(dt: Float, moved: Float, turning: Float) {}
    func arrived(at cell: Int) {}
    func giveWay(to other: Habitat.Sighting) {
        // Oct 11: on an errand -- a polite beat, never turning back.
        if errand != nil { pause = 0.2; return }
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
            for other in habitat.sightings where other.id != id && other.kind != .player && other.kind != .bigShot {
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
        if let panicFrom {                                                       // Oct 16: away from the Big Shot
            let best = choice(options, awayFrom: panicFrom)
            let here = graph.centers[from] ?? pos
            // Cornered (every way leads nearer him): hold still in its corner.
            if simd_length((graph.centers[best] ?? pos) - panicFrom) < simd_length(here - panicFrom) { return nil }
            return best
        }
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

    /// Oct 11 (errands): straight toward a point, off the graph.
    private func moveFree(toward point: SIMD2<Float>, dt: Float) {
        let d = point - pos
        let l = simd_length(d)
        if l > 0.0005 { pos += d / l * min(l, speed * dt) }
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
            // Oct 22 (evening, startup investigation): every render is named and timed --
            // which sounds are made on the main thread at launch, and how long each takes.
            let t0 = CACurrentMediaTime()
            guard (try? BobbinSound.wav(normalized(render())).write(to: url)) != nil else { return nil }
            diag("audio.render", ["name": name, "ms": Int((CACurrentMediaTime() - t0) * 1000), "main": Thread.isMainThread])
        }
        guard let s = SCNAudioSource(url: url) else { return nil }
        s.isPositional = true
        s.shouldStream = false
        s.volume = volume
        s.load()
        SoundCatalog.register(s, name: name)          // Oct 18: so AudioWatch can say which sound played
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
           case let (s, _)? = nearest([.noodle, .pottle, .bobbin], within: 2.8),
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
           case let (s, _)? = nearest([.stalk, .chair, .pottle, .bobbin], within: 7),
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

    static let taps = MenagerieSound.variants("chair-step", count: 4, volume: 0.22) { rng in
        MenagerieSound.strike([(rng.range(380, 460), 0.025, 0.4), (rng.range(900, 1100), 0.012, 0.2)],
                              seconds: 0.07, noise: 0.4, noiseDecay: 0.0015, rng: &rng)
    }
    static let thumps = MenagerieSound.variants("chair-thump", count: 3, volume: 0.55) { rng in
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
    static let creak = MenagerieSound.source("chair-creak", volume: 0.4) {
        var rng = Rand(seed: 23)
        return MenagerieSound.creak(resonance: 470, q: 11, startHz: 28, endHz: 44, seconds: 0.4, rng: &rng)
    }

    override var modeName: String { mode.rawValue }

    static func make(habitat: Habitat, cell: Int, shadow: UIImage) -> (Critter, SCNNode) {
        let m = model(shadow: shadow)
        let critter = Chair(habitat: habitat, node: m.root, body: m.body, cell: cell, seat: m.seat, legs: m.legs)
        return (critter, m.root)
    }

    /// Oct 18 (building life): the chair's model alone -- also the roaming
    /// chair resident's body (ResidentChair.swift). Facing -z (yaw 0).
    static func model(shadow: UIImage) -> (root: SCNNode, body: SCNNode, seat: SCNNode, legs: [SCNNode]) {
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
        return (root, body, seat, legs)
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
    private let legs: [SCNNode]
    private let sizeScale: Float
    /// Oct 20 (night): its step's length x (set by a resident errand while it guides: longer steps).
    var strideScale: Float = 1

    private static let tocks = MenagerieSound.variants("pottle-tock", count: 5, volume: 0.35) { rng in
        let k = rng.range(0.92, 1.08)
        return MenagerieSound.strike([(640 * k, 0.03, 0.5), (1480 * k, 0.018, 0.3), (2650 * k, 0.01, 0.12)],
                                     seconds: 0.09, noise: 0.35, noiseDecay: 0.006, rng: &rng)
    }
    static let rustles = MenagerieSound.variants("pottle-rustle", count: 3, volume: 0.45) { rng in
        MenagerieSound.rustle(grains: Int(rng.range(18, 34)), seconds: rng.range(0.3, 0.55), grainLength: 0.004, rng: &rng)
    }

    override var modeName: String { mode.rawValue }

    static func make(habitat: Habitat, cell: Int, shadow: UIImage, scale: Float) -> (Critter, SCNNode) {
        let root = SCNNode()
        root.name = "pottle"
        root.scale = SCNVector3(scale, scale, scale)
        addShadow(shadow, size: 0.42, to: root)
        // Oct 16 (Supplies II polish): the pot stands on three pencil legs with
        // eraser feet (Mr. Tinky's kind), so it walks rather than shuffles.
        let legLength: Float = 0.13
        let body = pivot(in: root, at: SCNVector3(0, legLength, 0))
        let pencil = mat(UIColor(red: 0.98, green: 0.78, blue: 0.12, alpha: 1), rough: 0.5)
        let eraser = mat(UIColor(red: 0.95, green: 0.55, blue: 0.6, alpha: 1), rough: 0.8)
        var legs: [SCNNode] = []
        for i in 0..<3 {
            let a = Float(i) / 3 * 2 * .pi + .pi / 2
            let hip = pivot(in: body, at: SCNVector3(0.06 * cos(a), 0.01, 0.06 * sin(a)), name: "leg")
            let shaft = SCNCylinder(radius: 0.0075, height: CGFloat(legLength))
            shaft.radialSegmentCount = 6
            part(shaft, pencil, in: hip, at: SCNVector3(0, -legLength / 2, 0))
            part(SCNSphere(radius: 0.011), eraser, in: hip, at: SCNVector3(0, -legLength - 0.002, 0))
            legs.append(hip)
        }
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
        let critter = Pottle(habitat: habitat, node: root, body: body, cell: cell, pot: pot, plant: plant, legs: legs, scale: scale)
        return (critter, root)
    }

    init(habitat: Habitat, node: SCNNode, body: SCNNode, cell: Int, pot: SCNNode, plant: SCNNode, legs: [SCNNode], scale: Float) {
        self.pot = pot
        self.plant = plant
        self.legs = legs
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
        guard cage == nil else { return }          // (Oct 19: its old cage-mates, the Clackers, are retired)
        let company = nearest([.noodle, .player, .chair, .ladder, .bobbin, .stalk], within: 2.2)
        switch mode {
        case .settled:
            if company != nil {
                set(.uneasy)
                shiver = 1
                say(Self.rustles.randomElement())
            }
        case .uneasy:
            if company == nil, modeTime > 2 { set(.settled) }
            else if modeTime > 3 {
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
        pivotPhase += moved / (0.12 * sizeScale * max(0.5, strideScale)) * .pi
        // Oct 23 (walking music): with the musical identities on, its walking sound is its
        // signature (ResidentWalkingMusic, the same for every critter) -- no tocks then.
        if floor(before / .pi) != floor(pivotPhase / .pi), speed > 0.08, !ResidentMusic.hushesVoices { say(Self.tocks.randomElement(), loud: false) }
        let walking = min(1, speed / 0.2)
        let s = sin(pivotPhase)
        pot.eulerAngles = SCNVector3(-0.06 * walking, s * 0.05 * walking, s * 0.17 * walking)
        pot.position.y = abs(s) * 0.012 * walking
        for (i, leg) in legs.enumerated() {                        // Oct 16: the legs take the steps
            leg.eulerAngles.x = 0.35 * sin(pivotPhase + Float(i) * 2.1) * walking
        }
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
        SCNAction.customAction(duration: 1) { _, _ in let p = PerfMonitor.begin("critter.tick"); self.tick(); PerfMonitor.end(p) }   // (Oct 21: timed, measurement only)
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

// MARK: - Oct 16 -- THE FIRST MONSTER AUDITION: THE BIG SHOT
//
// One enormous, pompous corporate bully (~2.5 m, mostly belly) who stomps the
// corridors of Floor 3 like he owns them. An original character: a lacquered
// silver pompadour, a ruddy jowly face with permanently indignant brows, a
// dark suit straining at its buttons, a loud striped tie, stubby little hands
// and enormous polished shoes. Signature: he stops, straightens his tie,
// lifts his chin, POINTS -- harrumphs -- and stomps on.
//
// Behaviour (his own Critter brain; the floor graph, travel and voice are the
// shared ones):
//   stroll    lumbering about; every 8-15 s a harrumph at whatever's ahead
//   chase     a critter he can see within 6.5 m: a short stomping pursuit
//             (3 s at most), then he points at where it fled
//   (Oct 16, meaner -- the player:)
//   spot      the player seen within 15 m (or within 2.5 m, seen or not):
//             he stops dead, swings round to face them, points -- "YOU"
//   pursue    then comes, at a charge (up to 5.2 m/s), finger first, along
//             the corridors to where he last saw them; easing off at the end
//             so he pulls up ~1.7 m from the player's face
//   search    lost sight (round a corner): to the last place he saw them,
//             a look one way and the other -- found: pursue; not: he
//             straightens his tie, harrumphs and strolls off (5-8 s)
//   confront  in your face: the accusation (point, jab, "YOU", stomp); run
//             and he's after you again; stand there and he gets furious
//             (jabbing, "no-no-NO", double stomp); stand there still and he
//             gives up in a huff and turns away (9-13 s). A pursuit gives up
//             after 24 s in any case; now and then he breaks off to chase a
//             critter on the way.
//             He never blocks or touches the player (no collision with the
//             camera; he stops short of them) and never follows them into
//             a room -- he glares from the nearest corridor cell.
// Every loose critter scatters from him (Critter.fleeBigShot) and goes back
// to its own life when he's gone. Nobody is hurt, caught or removed.
// Off: `-HallwaysNoBigShot YES`, or delete BigShot.populate's line in
// Menagerie.install.
nonisolated final class BigShot: Critter {
    // Oct 22: RETIRED FROM NORMAL PLAY (no longer wanted). Nothing of his is
    // deleted: he (and his eviction, which only he can start) comes back only
    // with `-HallwaysBigShot YES`; `-HallwaysNoBigShot YES` still wins.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "HallwaysBigShot") && !UserDefaults.standard.bool(forKey: "HallwaysNoBigShot")
    }
    static let floor = 3
    /// Critters bolt when he comes this close (m), and calm down beyond calmRadius.
    static let scareRadius: Float = 3.4
    static let calmRadius: Float = 5.0

    // Oct 16 (meaner): he notices you from further off, turns on you, and comes
    // -- fast. Round a corner and he checks where you were; stand your ground
    // and he gets in your face, then gets crosser; eventually he gives up in a
    // huff. Critters still get chased now and then -- even mid-pursuit.
    static let sightRange: Float = 15            // was 8
    static let hearRange: Float = 2.5            // this close he knows, line of sight or not
    static let strollSpeed: Float = 0.85
    static let pursueSpeed: Float = 5.2          // the charge (the player cruises at 6, 9 when sustained)
    static let searchSpeed: Float = 2.4
    static let chaseSpeed: Float = 2.4           // after a critter
    static let confrontRange: Float = 1.7        // as close as he comes (m, to the player's eye)
    static let retreatRange: Float = 3.6         // further than this after a confrontation = you ran
    static let pursuitMax: Double = 24           // then he's had enough
    static let searchMax: Double = 7

    enum Mode: String { case stroll, harrumph, chase, spot, pursue, search, escort }
    /// Oct 16 (Bonzo's eviction): this close, in sight, mid-pursuit -- he grabs.
    static let captureRange: Float = 1.8
    /// The signature gesture's three tempers.
    enum Gesture: String { case plain, accuse, fury }
    /// What comes after a gesture.
    private enum After { case stroll, turnAway, judge }

    private var mode: Mode = .stroll
    private var modeTime: Double = 0
    private var gestureClock = Double.random(in: 6...10)
    private var chaseCooldown: Double = 5
    private var playerCooldown: Double = 4
    private var chaseTarget: String?
    private var gestureTime: Double = 0
    private var gesture: Gesture = .plain
    private var after: After = .stroll
    private var stompsDone = 0
    private var saidInGesture = false
    // What he knows about the player.
    private var lastSeen: SIMD2<Float>?
    private var lastSeenAt: Double = -100
    private var lastSeenCell: Int?
    private var lastSeenOffGraph = false
    private var seenDistance: Float = 99
    private var pursuitTime: Double = 0
    private var annoyance = 0
    private var divertedFromPlayer = false
    private var lookAroundTime: Double = 0
    private var pathDistances: [Int: Int] = [:]
    private var pathFor: Int?
    private var lastStepSound: Double = -1
    // Oct 16 (Bonzo's eviction): the escort's body (a script moves him; see BonzoEviction).
    private var captureAskedAt: Double = -100
    /// 0 = arm down ... 1 = gripping the player's collar (main writes, render eases toward it).
    var escortReach: Float = 0
    /// 1 = his usual girth; < 1 = breathing in to squeeze through a doorway.
    var squeeze: Float = 1
    private var escortLast: SIMD2<Float>?
    private var escortClock: CFTimeInterval = 0
    private var reach: [Int: Int] = [:]          // cells he can walk to from `reachFrom`
    private var reachFrom: Int?
    private var diversionEndedAt: Double = -100

    // The rig.
    private let torso: SCNNode, belly: SCNNode, head: SCNNode, tie: SCNNode
    private let hips: [SCNNode], shoulders: [SCNNode], elbows: [SCNNode]
    private var gait: Float = 0
    private var lastSwing: Float = 0
    private var stomp: Float = 0                 // the body's dip after a footfall (decays)
    private var jiggle: Float = 0, jiggleVel: Float = 0

    override var modeName: String { mode.rawValue }

    private init(habitat: Habitat, node: SCNNode, body: SCNNode, cell: Int, torso: SCNNode, belly: SCNNode, head: SCNNode,
                 tie: SCNNode, hips: [SCNNode], shoulders: [SCNNode], elbows: [SCNNode]) {
        self.torso = torso; self.belly = belly; self.head = head; self.tie = tie
        self.hips = hips; self.shoulders = shoulders; self.elbows = elbows
        super.init(kind: .bigShot, habitat: habitat, node: node, body: body, cell: cell)
        acceleration = 2.2                       // a big body gets going slowly
        turnRate = 2.4
        maxLane = 0.18
        personalSpace = 1.1
        senseInterval = 0.4
        wantSpeed = 0.85
    }

    // MARK: Voice (synthesised, like everyone's)

    private typealias S = MeetingVoices.Syl
    private static let harrumphs: [String: SCNAudioSource] = {
        let lines: [(String, [S])] = [
            ("bigshot-hmph", [S(v: 6, s: 0.14, a: 104, b: 98), S(v: 5, s: 0.26, a: 128, b: 84, stop: true)]),
            ("bigshot-harrumph", [S(v: 0, s: 0.12, a: 96, b: 104, stop: true), S(v: 5, s: 0.3, a: 132, b: 88, stop: true)]),
            ("bigshot-you", [S(v: 3, s: 0.12, a: 112, b: 150), S(v: 3, s: 0.32, a: 158, b: 92)]),
            ("bigshot-nonono", [S(v: 1, s: 0.1, a: 120, b: 126, stop: true), S(v: 1, s: 0.1, a: 124, b: 130, stop: true),
                                S(v: 1, s: 0.22, a: 132, b: 92, stop: true)]),
        ]
        var out: [String: SCNAudioSource] = [:]
        for (name, syl) in lines {
            let source = MenagerieSound.source(name, volume: 0.75, {
                MeetingVoices.speak(syl, seed: AuditionVoices.stableSeed(name), formantScale: 0.74, breath: 0.16)
            })
            if let source { out[name] = source }
        }
        return out
    }()
    /// accuse = "YOU", fury = "no-no-NO", plain = a harrumph.
    private static func voice(for g: Gesture) -> SCNAudioSource? {
        switch g {
        case .accuse: return harrumphs["bigshot-you"] ?? harrumphs.values.first
        case .fury: return harrumphs["bigshot-nonono"] ?? harrumphs.values.first
        case .plain: return [harrumphs["bigshot-hmph"], harrumphs["bigshot-harrumph"]].compactMap { $0 }.randomElement()
        }
    }
    private static let stomps: [SCNAudioSource] = MenagerieSound.variants("bigshot-stomp", count: 3, volume: 0.55) { rng in
        MenagerieSound.strike([(rng.range(48, 60), 0.2, 1), (rng.range(100, 120), 0.1, 0.45), (rng.range(230, 270), 0.04, 0.2)],
                              seconds: 0.4, noise: 0.7, noiseDecay: 0.012, rng: &rng)
    }

    // MARK: Build

    static func make(habitat: Habitat, cell: Int, shadow: UIImage) -> (BigShot, SCNNode) {
        let root = SCNNode()
        root.name = "bigShot"
        addShadow(shadow, size: 1.8, to: root)
        let body = pivot(in: root, at: SCNVector3Zero)
        let suit = mat(UIColor(red: 0.14, green: 0.15, blue: 0.19, alpha: 1), rough: 0.78)
        let trousers = mat(UIColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1), rough: 0.8)
        let shirt = mat(UIColor(white: 0.93, alpha: 1), rough: 0.6)
        let skin = mat(UIColor(red: 0.88, green: 0.52, blue: 0.46, alpha: 1), rough: 0.5)
        let flush = mat(UIColor(red: 0.85, green: 0.36, blue: 0.36, alpha: 1), rough: 0.45)
        let hair = mat(UIColor(white: 0.8, alpha: 1), metal: 0.35, rough: 0.22)              // lacquered silver
        let brow = mat(UIColor(white: 0.32, alpha: 1), rough: 0.9)
        let shoeLeather = mat(UIColor(white: 0.04, alpha: 1), metal: 0.25, rough: 0.18)       // mirror-polished
        let navy = mat(UIColor(red: 0.1, green: 0.13, blue: 0.32, alpha: 1), rough: 0.5)
        let mustard = mat(UIColor(red: 0.86, green: 0.66, blue: 0.12, alpha: 1), rough: 0.5)
        let white = mat(UIColor(white: 0.97, alpha: 1), rough: 0.3)
        let black = mat(UIColor(white: 0.02, alpha: 1), rough: 0.25)
        let mouthRed = mat(UIColor(red: 0.45, green: 0.08, blue: 0.1, alpha: 1), rough: 0.6)
        let button = mat(UIColor(white: 0.08, alpha: 1), metal: 0.3, rough: 0.4)

        // Legs and enormous shoes (toes forward = -Z).
        var hips: [SCNNode] = []
        for side: Float in [-1, 1] {
            let hip = pivot(in: body, at: SCNVector3(side * 0.25, 0.82, 0))
            part(SCNCapsule(capRadius: 0.16, height: 0.8), trousers, in: hip, at: SCNVector3(0, -0.4, 0))
            part(SCNBox(width: 0.27, height: 0.13, length: 0.52, chamferRadius: 0.06), shoeLeather, in: hip,
                 at: SCNVector3(side * 0.02, -0.755, -0.11))
            hips.append(hip)
        }
        // The torso: a vast belly in a jacket that doesn't close, a broad chest.
        let torso = pivot(in: body, at: SCNVector3(0, 0.82, 0))
        let belly = pivot(in: torso, at: SCNVector3(0, 0.55, -0.05))
        let jacketBelly = part(SCNSphere(radius: 0.62), suit, in: belly)
        jacketBelly.scale = SCNVector3(1.08, 0.95, 1.0)
        part(SCNSphere(radius: 0.5), shirt, in: belly, at: SCNVector3(0, -0.13, -0.2))        // shirt bulging out below
        for (y, z) in [(Float(0.04), Float(-0.62)), (0.24, -0.585)] {                           // straining buttons
            part(SCNCylinder(radius: 0.035, height: 0.02), button, in: belly, at: SCNVector3(0, y, z), euler: SCNVector3(Float.pi / 2, 0, 0))
        }
        let chest = part(SCNSphere(radius: 0.5), suit, in: torso, at: SCNVector3(0, 0.95, 0.02))
        chest.scale = SCNVector3(1.22, 0.85, 0.9)
        for side: Float in [-1, 1] {                                                            // shoulder pads
            part(SCNBox(width: 0.32, height: 0.13, length: 0.42, chamferRadius: 0.05), suit, in: torso,
                 at: SCNVector3(side * 0.52, 1.15, 0.02), euler: SCNVector3(0, 0, side * -0.12))
        }
        part(SCNCylinder(radius: 0.16, height: 0.1), shirt, in: torso, at: SCNVector3(0, 1.3, -0.03))   // collar
        // The tie: knot at the collar, a short loud striped blade over the belly top.
        let tie = pivot(in: torso, at: SCNVector3(0, 1.25, -0.35))
        tie.eulerAngles.x = 0.5
        part(SCNBox(width: 0.1, height: 0.08, length: 0.05, chamferRadius: 0.015), navy, in: tie, at: SCNVector3(0, 0.0, 0))
        part(SCNBox(width: 0.15, height: 0.4, length: 0.02, chamferRadius: 0.01), navy, in: tie, at: SCNVector3(0, -0.22, -0.015))
        for k in 0..<4 {
            part(SCNBox(width: 0.17, height: 0.03, length: 0.022, chamferRadius: 0.004), mustard, in: tie,
                 at: SCNVector3(0, -0.08 - Float(k) * 0.09, -0.017), euler: SCNVector3(0, 0, 0.45))
        }
        // The head: ruddy, jowly, indignant -- and the pompadour.
        let head = pivot(in: torso, at: SCNVector3(0, 1.4, -0.04))
        let skull = part(SCNSphere(radius: 0.24), skin, in: head)
        skull.scale = SCNVector3(1, 1.04, 0.95)
        for side: Float in [-1, 1] {
            part(SCNSphere(radius: 0.125), skin, in: head, at: SCNVector3(side * 0.135, -0.13, -0.07))   // jowls
            part(SCNSphere(radius: 0.06), skin, in: head, at: SCNVector3(side * 0.24, 0.0, 0.0))         // ears
            part(SCNSphere(radius: 0.045), flush, in: head, at: SCNVector3(side * 0.13, -0.05, -0.18))  // flushed cheeks
            part(SCNSphere(radius: 0.042), white, in: head, at: SCNVector3(side * 0.072, 0.07, -0.195))  // beady eyes
            part(SCNSphere(radius: 0.02), black, in: head, at: SCNVector3(side * 0.072, 0.065, -0.234))
            // Brows: thick, inner ends down -- permanently indignant.
            part(SCNBox(width: 0.12, height: 0.035, length: 0.04, chamferRadius: 0.012), brow, in: head,
                 at: SCNVector3(side * 0.08, 0.135, -0.205), euler: SCNVector3(0, 0, side * 0.38))
        }
        part(SCNSphere(radius: 0.14), skin, in: head, at: SCNVector3(0, -0.2, -0.07))            // double chin
        part(SCNSphere(radius: 0.068), flush, in: head, at: SCNVector3(0, 0.0, -0.245))          // nose
        part(SCNBox(width: 0.11, height: 0.022, length: 0.02, chamferRadius: 0.008), mouthRed, in: head,
             at: SCNVector3(0, -0.1, -0.228))
        for side: Float in [-1, 1] {                                                              // the frown's ends
            part(SCNBox(width: 0.04, height: 0.02, length: 0.02, chamferRadius: 0.007), mouthRed, in: head,
                 at: SCNVector3(side * 0.065, -0.112, -0.222), euler: SCNVector3(0, 0, side * 0.6))
        }
        let pomp = part(SCNSphere(radius: 0.21), hair, in: head, at: SCNVector3(0, 0.2, -0.02))
        pomp.scale = SCNVector3(1.1, 0.55, 1.2)
        let swoop = part(SCNSphere(radius: 0.13), hair, in: head, at: SCNVector3(0.02, 0.26, -0.19))
        swoop.scale = SCNVector3(1.35, 0.85, 1.0)
        // Short arms, stubby little hands; the right one has a pointing finger.
        var shoulders: [SCNNode] = [], elbows: [SCNNode] = []
        for side: Float in [-1, 1] {
            let shoulder = pivot(in: torso, at: SCNVector3(side * 0.66, 1.1, 0))
            part(SCNCapsule(capRadius: 0.105, height: 0.44), suit, in: shoulder, at: SCNVector3(0, -0.2, 0))
            let elbow = pivot(in: shoulder, at: SCNVector3(0, -0.4, 0))
            part(SCNCapsule(capRadius: 0.09, height: 0.36), suit, in: elbow, at: SCNVector3(0, -0.16, 0))
            part(SCNCylinder(radius: 0.072, height: 0.04), shirt, in: elbow, at: SCNVector3(0, -0.34, 0))   // cuff
            part(SCNSphere(radius: 0.058), skin, in: elbow, at: SCNVector3(0, -0.4, 0))                     // hand
            if side > 0 {
                part(SCNCapsule(capRadius: 0.016, height: 0.1), skin, in: elbow, at: SCNVector3(0, -0.47, 0))
            }
            shoulder.eulerAngles.z = side * 0.32
            shoulders.append(shoulder)
            elbows.append(elbow)
        }
        let shot = BigShot(habitat: habitat, node: root, body: body, cell: cell, torso: torso, belly: belly, head: head,
                           tie: tie, hips: hips, shoulders: shoulders, elbows: elbows)
        _ = (harrumphs, stomps)                                     // render (and cache) the sounds now
        return (shot, root)
    }

    // MARK: Brain

    override func giveWay(to other: Habitat.Sighting) {
        // After the player he bulldozes through; otherwise small things scatter
        // and things that don't (Noodle, a Bobbin) he turns his back on.
        if mode == .pursue || mode == .search || mode == .spot { return }
        // Oct 16 (stuck + flicker report): a frog or the Slinky never scatters from him
        // (they move themselves), so waiting for one to get out of the way was a
        // stop-start stutter that could last; he steps over them, as he does the player.
        if other.kind == .frog || other.kind == .slinky { return }
        lastGiveWay = "\(other.kind)"
        if other.critter == nil { reverse() } else { pause = 0.1 }
    }

    // MARK: Oct 16 -- isolation switches and stuck/dither diagnostics (testing)

    /// `-HallwaysBigShotMute YES`: he makes no sound at all (everything else as usual).
    static let muted = UserDefaults.standard.bool(forKey: "HallwaysBigShotMute")
    /// `-HallwaysBigShotNoAnimation YES`: his body holds still (legs, arms, belly, tie);
    /// he still moves about and thinks.
    static let stillBody = UserDefaults.standard.bool(forKey: "HallwaysBigShotNoAnimation")

    private var lastGiveWay = "-"
    private var reverseTimes: [Double] = []
    private var lastDitherLog: Double = -100
    private var stuckClock: Double = 0
    private var stuckFrom = SIMD2<Float>(0, 0)

    override func say(_ source: SCNAudioSource?, loud: Bool = true) {
        super.say(Self.muted ? nil : source, loud: loud)
    }

    /// Every about-face is counted: four within 2 s is a dither, logged with what he was doing.
    override func reverse() {
        super.reverse()
        reverseTimes.append(time)
        reverseTimes.removeAll { time - $0 > 2 }
        if reverseTimes.count >= 4, time - lastDitherLog > 5 {
            lastDitherLog = time
            diag("bigShot.dither", ["reverses2s": reverseTimes.count, "mode": mode.rawValue, "from": from, "to": to,
                                    "goal": goal ?? -1, "speed": speed, "lastGiveWay": lastGiveWay])
        }
    }

    /// Every 3 s: wanting to walk but not getting anywhere is logged (mode, cells, who's near).
    private func noteProgress(dt: Double) {
        stuckClock += dt
        guard stuckClock >= 3 else { return }
        stuckClock = 0
        let went = simd_length(pos - stuckFrom)
        stuckFrom = pos
        let looking = mode == .harrumph || mode == .spot || (mode == .search && lookAroundTime > 0)
        guard !looking, wantSpeed > 0.3, went < 0.4 else { return }
        let near = habitat.sightings.filter { $0.id != id && simd_length($0.pos - pos) < 2 }.map { "\($0.kind)" }
        diag("bigShot.stuck", ["mode": mode.rawValue, "moved3s": (went * 100).rounded() / 100, "from": from, "to": to,
                               "goal": goal ?? -1, "speed": speed, "wantSpeed": wantSpeed, "pause": pause,
                               "lastGiveWay": lastGiveWay, "near": near.joined(separator: ",")])
    }

    override func sense(now: CFTimeInterval) {
        // Where is the player? Seen (clear line at eye height), or simply too close to miss.
        if case let (p, d)? = nearest([.player], within: Self.sightRange), p.pos.x.isFinite, p.pos.y.isFinite,
           d < Self.hearRange || habitat.canSee(pos, p.pos, height: 1.7) {
            lastSeen = p.pos
            lastSeenAt = time
            seenDistance = d
            if reachFrom != from {
                reach = graph.distances(from: [from])
                reachFrom = from
            }
            if let c = graph.cell(near: p.pos), reach[c] != nil {
                lastSeenCell = c
                lastSeenOffGraph = false
            } else {
                // Somewhere he can't walk to (a room behind a door, the office, the cab):
                // the nearest place he CAN get to -- and he glares from there.
                lastSeenCell = reach.keys.min { k1, k2 in
                    simd_length((graph.centers[k1] ?? pos) - p.pos) < simd_length((graph.centers[k2] ?? pos) - p.pos)
                }
                lastSeenOffGraph = true
            }
            if mode == .stroll, playerCooldown <= 0 {
                spot()
                return
            }
            if mode == .search {
                set(.pursue)
                diag("bigShot.reacquired", ["distance": (d * 10).rounded() / 10])
            }
        }
        guard mode == .stroll, chaseCooldown <= 0, let prey = nearestPrey(within: 6.5), habitat.canSee(pos, prey.0.pos, height: 1.0) else { return }
        startChase(prey.0, distance: prey.1)
    }

    override func think(dt: Double, now: CFTimeInterval) {
        modeTime += dt
        chaseCooldown -= dt
        playerCooldown -= dt
        noteProgress(dt: dt)
        let sinceSeen = time - lastSeenAt
        let livePlayer = nearest([.player], within: Self.sightRange)
        let liveDistance = livePlayer?.1 ?? seenDistance
        switch mode {
        case .stroll:
            wantSpeed = Self.strollSpeed
            goal = nil
            lookAt = nil
            gestureClock -= dt
            if gestureClock <= 0 { beginGesture(.plain, at: pos + direction * 3, then: .stroll) }
            // Close ahead of the player (between pursuits): he stands and glares,
            // and sooner or later, hmph, off he goes.
            if case let (p, _)? = nearest([.player], within: 2.4), simd_dot(direction, p.pos - pos) > 0.3 {
                wantSpeed = 0
                pause = 0.3
                lookAt = p.pos
                if Double.random(in: 0...1) < dt * 0.15 { reverse() }
            }

        case .chase:
            wantSpeed = Self.chaseSpeed
            let target = habitat.sightings.first { $0.id == chaseTarget }
            if let target, target.pos.x.isFinite, target.pos.y.isFinite, simd_length(target.pos - pos) < 9, modeTime < 3.0 {
                goal = graph.cell(near: target.pos)
                headTowardGoal()
            } else {
                chaseCooldown = Double.random(in: 7...11)
                if divertedFromPlayer {                                          // ...now, where was I
                    playerCooldown = min(playerCooldown, 1.0)
                    diversionEndedAt = time
                }
                divertedFromPlayer = false
                beginGesture(.plain, at: target?.pos ?? pos + direction * 3, then: .stroll)   // ...and point where it went
            }

        case .spot:
            // Caught sight of you: he stops dead, swings round, points -- YOU.
            wantSpeed = 0
            speed = max(0, speed - Float(dt) * 6)
            lookAt = lastSeen
            if modeTime > 0.75 {
                set(.pursue)
                diag("bigShot.pursue", ["distance": (seenDistance * 10).rounded() / 10, "offGraph": lastSeenOffGraph])
            }

        case .pursue:
            pursuitTime += dt
            lookAt = lastSeen
            // Oct 16 (Bonzo's eviction): caught -- in sight, within arm's reach: he grabs
            // (the main thread decides whether he may; meanwhile he stands over you).
            if time - captureAskedAt < 0.5 {
                wantSpeed = 0
                speed = max(0, speed - Float(dt) * 6)
                break
            }
            if BonzoEviction.isEnabled, liveDistance <= Self.captureRange, sinceSeen < 0.6, !lastSeenOffGraph,
               time - captureAskedAt > 2.5, now >= BonzoEviction.captureGraceUntil {
                captureAskedAt = time
                wantSpeed = 0
                let me = self
                DispatchQueue.main.async { MainActor.assumeIsolated { BonzoEviction.requestCapture(by: me) } }
                break
            }
            if sinceSeen > 0.9 {
                set(.search)                                                    // round a corner: where did you go
                diag("bigShot.search", ["since": (sinceSeen * 10).rounded() / 10])
            } else if pursuitTime > Self.pursuitMax {
                playerCooldown = Double.random(in: 8...12)
                endPursuit()
                beginGesture(.plain, at: lastSeen ?? pos, then: .turnAway)      // enough of you
                diag("bigShot.gaveUp", ["why": "tooLong"])
            } else if liveDistance <= Self.confrontRange || (from == goal && (lastSeenOffGraph || liveDistance < 3.2)) {
                confront()
            } else {
                goal = lastSeenCell
                headTowardGoal()
                // Charging -- but easing off for the last few metres (on the live distance, braking
                // hard), so he pulls up in your face, not through you.
                wantSpeed = max(0.8, min(Self.pursueSpeed, (liveDistance - Self.confrontRange) * 1.4))
                speed = min(speed, max(0, liveDistance - Self.confrontRange) * 1.5 + 0.3)
                // Now and then a critter in the way is too tempting.
                if pursuitTime > 3, Double.random(in: 0...1) < dt * 0.06, let prey = nearestPrey(within: 3) {
                    divertedFromPlayer = true
                    startChase(prey.0, distance: prey.1)
                }
            }

        case .search:
            pursuitTime += dt
            guard let seen = lastSeen else { endPursuit(); set(.stroll); break }
            let there = from == lastSeenCell || simd_length(seen - pos) < 1.5
            if there || lookAroundTime > 0 {
                // Where you were: he looks one way, then the other...
                wantSpeed = 0
                speed = max(0, speed - Float(dt) * 4)
                lookAroundTime += dt
                let side = SIMD2<Float>(-direction.y, direction.x) * (Int(lookAroundTime / 0.7) % 2 == 0 ? Float(3) : Float(-3))
                lookAt = pos + direction * 2 + side
            } else {
                goal = lastSeenCell
                headTowardGoal()
                wantSpeed = Self.searchSpeed
                lookAt = seen
            }
            if lookAroundTime > 2.1 || modeTime > Self.searchMax {
                // ...lost you. The tie gets straightened, with feeling.
                playerCooldown = Double.random(in: 5...8)
                endPursuit()
                beginGesture(.plain, at: seen, then: .stroll)
                diag("bigShot.lost", [:])
            }

        case .escort:
            break                                                               // (a script drives him)

        case .harrumph:
            wantSpeed = 0
            pause = 0.2
            speed = max(0, speed - Float(dt) * 5)
            gestureTime += dt
            if after == .judge { pursuitTime += dt }                               // (a confrontation counts toward his patience)
            let beat = Self.timeline(gesture)
            if after == .judge, case let (p, _)? = nearest([.player], within: 8) { lookAt = p.pos }   // glaring at you throughout
            if !saidInGesture, gestureTime > beat.voice {
                saidInGesture = true
                say(Self.voice(for: gesture))
            }
            if stompsDone < beat.stomps.count, gestureTime > beat.stomps[stompsDone] {
                stompsDone += 1
                footfall(heavy: true, always: true)
            }
            if gestureTime > beat.end { finishGesture() }
        }
        // Never through the player: chasing a critter or searching, close ahead of
        // them, he stands (the pursuit brakes on its own; strolling glares above).
        if mode == .chase || mode == .search, case let (p, d)? = livePlayer, d < 2.2, simd_dot(direction, p.pos - pos) > 0.3 {
            wantSpeed = 0
            pause = 0.3
            speed = max(0, speed - Float(dt) * 6)
        }
    }

    private func set(_ m: Mode) {
        mode = m
        modeTime = 0
        lookAroundTime = 0
        turnRate = (m == .spot || m == .harrumph) ? 5 : 2.6
        senseInterval = (m == .stroll || m == .chase) ? 0.4 : 0.25
    }

    /// Noticed you: the turn, the point, the "YOU".
    private func spot() {
        set(.spot)
        if time - diversionEndedAt > 4 {                                     // (back from a critter: same pursuit, same patience)
            pursuitTime = 0
            annoyance = 0
        }
        divertedFromPlayer = false
        lookAt = lastSeen
        goal = lastSeenCell
        if let seen = lastSeen, from != to, simd_dot(direction, seen - pos) < -0.2 { reverse() }   // never off the other way
        say(Self.voice(for: .accuse))
        footfall(heavy: true, always: true)
        diag("bigShot.spot", ["distance": (seenDistance * 10).rounded() / 10])
    }

    /// In your face (or as near as the corridors let him get): the accusation.
    private func confront() {
        diag("bigShot.confront", ["distance": (seenDistance * 10).rounded() / 10, "annoyance": annoyance])
        beginGesture(annoyance == 0 ? .accuse : .fury, at: lastSeen ?? pos, then: .judge)
    }

    private func endPursuit() {
        pursuitTime = 0
        annoyance = 0
        divertedFromPlayer = false
        goal = nil
    }

    private func nearestPrey(within range: Float) -> (Habitat.Sighting, Float)? {
        var prey: (Habitat.Sighting, Float)?
        for s in habitat.sightings where s.kind != .bigShot && s.kind != .player {
            guard let c = s.critter, c.cage == nil, c.errand == nil, s.pos.x.isFinite, s.pos.y.isFinite else { continue }
            let d = simd_length(s.pos - pos)
            if d < range, prey == nil || d < prey!.1 { prey = (s, d) }
        }
        return prey
    }

    private func startChase(_ prey: Habitat.Sighting, distance: Float) {
        chaseTarget = prey.id
        set(.chase)
        say(Self.voice(for: .plain))
        diag("bigShot.chase", ["target": prey.id, "distance": (distance * 10).rounded() / 10, "fromPlayer": divertedFromPlayer])
    }

    /// Mid-corridor and heading the wrong way for where he wants to be: about-face now,
    /// not at the far end of the corridor.
    private func headTowardGoal() {
        guard let goal, from != to, goal != from, to != goal else { return }
        if pathFor != goal {
            pathDistances = graph.distances(from: [goal])
            pathFor = goal
        }
        if let here = pathDistances[from], let there = pathDistances[to], there > here { reverse() }
    }

    private func beginGesture(_ g: Gesture, at point: SIMD2<Float>, then next: After) {
        set(.harrumph)
        gesture = g
        after = next
        lookAt = point
        goal = nil
        gestureTime = 0
        stompsDone = 0
        saidInGesture = false
    }

    private func finishGesture() {
        let next = after
        after = .stroll
        switch next {
        case .stroll:
            set(.stroll)
            gestureClock = Double.random(in: 8...15)
            goal = nil
            lookAt = nil
        case .turnAway:
            set(.stroll)
            gestureClock = Double.random(in: 8...15)
            goal = nil
            lookAt = nil
            turnAway()
        case .judge:
            // Did you run? Then after you. Still standing there? He gets crosser -- then gives up in a huff.
            let d = nearest([.player], within: Self.sightRange)?.1 ?? 99
            // (Somewhere he can't follow, and he's as near as he can get: that's standing your ground too.)
            let cantGetCloser = lastSeenOffGraph && from == lastSeenCell
            if d > Self.retreatRange, !cantGetCloser, pursuitTime < Self.pursuitMax, time - lastSeenAt < 1.5 {
                set(.pursue)
                diag("bigShot.pursue", ["why": "youRan", "distance": (d * 10).rounded() / 10])
            } else if d <= Self.retreatRange || cantGetCloser, annoyance < 1, time - lastSeenAt < 1.5 {
                annoyance += 1
                beginGesture(.fury, at: lastSeen ?? pos, then: .judge)
                diag("bigShot.confront", ["distance": (d * 10).rounded() / 10, "annoyance": annoyance])
            } else {
                playerCooldown = Double.random(in: 9...13)
                endPursuit()
                set(.stroll)
                gestureClock = Double.random(in: 8...15)
                lookAt = nil
                turnAway()
                diag("bigShot.gaveUp", ["why": d <= Self.retreatRange || cantGetCloser ? "youStood" : "gone"])
            }
        }
    }

    /// Hmph -- and off he goes, the other way from the player.
    private func turnAway() {
        guard case let (p, _)? = nearest([.player], within: 40) else { reverse(); return }
        if from != to {
            if simd_dot(direction, p.pos - pos) > 0 { reverse() }
        } else if let away = graph.neighbors[from].map({ $0.filter { !habitat.blockedCells.contains($0) } }), !away.isEmpty {
            to = choice(away, awayFrom: p.pos)
            progress = 0
        }
    }

    private func footfall(heavy: Bool, always: Bool = false) {
        stomp = heavy ? 0.075 : 0.04
        jiggleVel -= heavy ? 1.1 : 0.55
        // (Oct 16: a step's sound at most every 0.4 s -- a charge is a lot of feet; the gesture's stomps always.)
        guard always || time - lastStepSound > 0.4 else { return }
        lastStepSound = time
        say(Self.stomps.randomElement(), loud: heavy)
    }

    // MARK: Oct 16 -- the escort (Bonzo's eviction drives; these are his handles)
    //
    // While a script has him (suspended), his own brain and travel stand aside:
    // the script moves his node with SCNActions, and this per-frame action keeps
    // his body alive -- gait, belly, footsteps (from how far he actually moved),
    // the gripping arm, and any gesture the script asks for, with its voice and
    // stomps. Everything here runs on the render thread except the script calls.

    /// Main thread: the script takes him.
    func beginEscort() {
        suspended = true
        mode = .escort
        escortReach = 0
        squeeze = 1
        escortLast = nil
        escortClock = 0
        node?.removeAction(forKey: "bonzoEscort")
        node?.runAction(.repeatForever(SCNAction.customAction(duration: 1) { _, _ in let p = PerfMonitor.begin("critter.escortFrame"); self.escortFrame(); PerfMonitor.end(p) }), forKey: "bonzoEscort")
    }

    /// Main thread: the signature gesture, mid-escort (its voice and stomps included).
    func scriptGesture(_ g: Gesture) {
        gesture = g
        after = .stroll
        gestureTime = 0
        stompsDone = 0
        saidInGesture = false
        mode = .harrumph
    }

    /// Main thread: a word (never posted to the critters -- their list is the render thread's).
    func speak(_ g: Gesture) { say(Self.voice(for: g), loud: false) }

    /// Main thread: one heavy stomp.
    func scriptStomp() {
        stomp = 0.075
        jiggleVel -= 1.1
        say(Self.stomps.randomElement(), loud: false)
    }

    /// Main thread: the script lets him go (an eviction that couldn't go on):
    /// back on the floor where he stands, strolling, the player left alone a while.
    func releaseFromEscort() {
        node?.removeAction(forKey: "bonzoEscort")
        node?.removeAction(forKey: BonzoEviction.walkKey)
        escortReach = 0
        squeeze = 1
        if let node {
            let p = SIMD2<Float>(node.position.x, node.position.z)
            pos = p
            heading = node.eulerAngles.y
            if let k = graph.centers.min(by: { simd_length($0.value - p) < simd_length($1.value - p) })?.key {
                from = k
                to = k
                progress = 0
                cameFrom = nil
            }
        }
        endPursuit()
        playerCooldown = 15
        set(.stroll)
        suspended = false
    }

    /// Render thread, every frame while escorting.
    private func escortFrame() {
        guard let node else { return }
        let now = CACurrentMediaTime()
        let dt = Float(escortClock == 0 ? 1.0 / 60 : min(max(now - escortClock, 0), 1.0 / 20))
        escortClock = now
        guard dt > 0 else { return }
        time += Double(dt)
        let p = SIMD2<Float>(node.position.x, node.position.z)
        let moved = escortLast.map { simd_length(p - $0) } ?? 0
        escortLast = p
        pos = p                                                   // (the critters still see him -- and scatter)
        heading = node.eulerAngles.y
        speed += (moved / dt - speed) * min(1, dt * 6)
        if mode == .harrumph {
            gestureTime += Double(dt)
            let beat = Self.timeline(gesture)
            if !saidInGesture, gestureTime > beat.voice {
                saidInGesture = true
                say(Self.voice(for: gesture))
            }
            if stompsDone < beat.stomps.count, gestureTime > beat.stomps[stompsDone] {
                stompsDone += 1
                footfall(heavy: true, always: true)
            }
            if gestureTime > beat.end { mode = .escort }
        }
        animate(dt: dt, moved: moved, turning: 0)
    }

    // MARK: Body

    private struct Beat {
        let tieEnd: Double, pointStart: Double, pointEnd: Double, voice: Double, stomps: [Double], end: Double
    }

    /// The signature gesture's timing, per temper: plain (tie, chin up, point,
    /// STOMP), accuse (straight to the point), fury (jabbing, double stomp).
    private static func timeline(_ g: Gesture) -> Beat {
        switch g {
        case .plain: return Beat(tieEnd: 0.9, pointStart: 1.25, pointEnd: 2.6, voice: 1.35, stomps: [2.75], end: 3.2)
        case .accuse: return Beat(tieEnd: 0, pointStart: 0.15, pointEnd: 1.8, voice: 0.25, stomps: [2.0], end: 2.4)
        case .fury: return Beat(tieEnd: 0, pointStart: 0.1, pointEnd: 1.9, voice: 0.15, stomps: [1.55, 2.05], end: 2.6)
        }
    }

    private static func ease(_ n: SCNNode, x: Float? = nil, y: Float? = nil, z: Float? = nil, rate: Float, dt: Float) {
        let k = min(1, dt * rate)
        var e = n.eulerAngles
        if let x { e.x += (x - e.x) * k }
        if let y { e.y += (y - e.y) * k }
        if let z { e.z += (z - e.z) * k }
        n.eulerAngles = e
    }

    override func animate(dt: Float, moved: Float, turning: Float) {
        if Self.stillBody { return }                                      // (isolation switch)
        if torso.scale.x != squeeze { torso.scale = SCNVector3(squeeze, 1, 1) }   // (Oct 16: breathing in for a doorway)
        let walk = min(1, speed / 0.9)
        let run = max(0, min(1, (speed - 1.2) / 3.0))                     // 0 walking ... 1 charging
        gait += moved / (1.15 + run * 1.7) * .pi                           // longer, bounding strides at a charge
        if gait > 2000 * .pi { gait = gait.truncatingRemainder(dividingBy: 2 * .pi) }
        let swing = sin(gait)
        if walk > 0.15, (swing >= 0) != (lastSwing >= 0) { footfall(heavy: speed > 1.3) }   // each foot down
        lastSwing = swing
        stomp *= max(0, 1 - dt * 7)
        // Heavy gait: legs, a dip at every step, a roll from side to side; leaning in at a charge.
        let legSwing = (0.34 + run * 0.3) * walk
        Self.ease(hips[0], x: swing * legSwing, rate: 14, dt: dt)
        Self.ease(hips[1], x: -swing * legSwing, rate: 14, dt: dt)
        body.position.y = -abs(sin(gait)) * (0.045 + run * 0.06) * walk - stomp
        let t = Float(gestureTime)
        let fury = mode == .harrumph && gesture == .fury
        Self.ease(torso, x: -run * 0.14, z: swing * 0.05 * walk + (fury ? sin(t * 38) * 0.035 : 0), rate: 6, dt: dt)
        // The belly: a spring the footfalls set going.
        jiggleVel += (-70 * jiggle - 5 * jiggleVel) * dt
        jiggle += jiggleVel * dt
        let j = max(-0.08, min(0.08, jiggle))
        belly.scale = SCNVector3(1 - j * 0.5, 1 + j, 1 - j * 0.4)
        // Arms and head: walking, charging (pointing all the way), or the signature gesture.
        if mode == .harrumph {
            let beat = Self.timeline(gesture)
            let td = Double(t)
            let chin: Float = td > beat.tieEnd - 0.1 && td < beat.pointEnd + 0.2 ? 0.2 : 0
            Self.ease(head, x: chin, rate: 5, dt: dt)
            if td < beat.tieEnd {                                          // 1. straightens his tie
                for (i, side) in [Float(-1), 1].enumerated() {
                    Self.ease(shoulders[i], x: 0.95, z: side * -0.15, rate: 8, dt: dt)
                    Self.ease(elbows[i], x: 1.5, rate: 8, dt: dt)
                }
                tie.eulerAngles.z = sin(t * 22) * 0.12
            } else if td < beat.pointStart {                               // 2. hands down, chin up
                tie.eulerAngles.z = 0
                for (i, side) in [Float(-1), 1].enumerated() {
                    Self.ease(shoulders[i], x: 0, z: side * 0.32, rate: 8, dt: dt)
                    Self.ease(elbows[i], x: 0, rate: 8, dt: dt)
                }
            } else if td < beat.pointEnd {                                 // 3. POINTS
                tie.eulerAngles.z = 0
                let jab: Float = fury ? sin(t * 16) * 0.14 : sin(t * 9) * 0.06
                Self.ease(shoulders[1], x: 1.45, z: -0.08, rate: 9, dt: dt)
                Self.ease(elbows[1], x: 0.08 + jab, rate: fury ? 14 : 9, dt: dt)            // a jab or two (a flurry, furious)
                Self.ease(shoulders[0], x: -0.15, z: -0.45, rate: 5, dt: dt)         // the other hand on his hip-ish
                Self.ease(elbows[0], x: 1.1, rate: 5, dt: dt)
            } else {                                                       // 4. arms down -- STOMP
                for (i, side) in [Float(-1), 1].enumerated() {
                    Self.ease(shoulders[i], x: 0, z: side * 0.32, rate: 8, dt: dt)
                    Self.ease(elbows[i], x: 0, rate: 8, dt: dt)
                }
            }
        } else if mode == .escort {
            // Oct 16 (Bonzo's eviction): the right hand out in front, gripping the
            // player's collar; the left swings; he looks down his nose at them.
            Self.ease(head, x: 0.12, rate: 5, dt: dt)
            Self.ease(shoulders[1], x: 0.2 + 1.1 * escortReach, z: 0.32 - 0.66 * escortReach, rate: 7, dt: dt)   // (in toward the collar)
            Self.ease(elbows[1], x: 0.25 * escortReach, rate: 7, dt: dt)
            Self.ease(shoulders[0], x: -swing * 0.3 * walk, z: -0.32, rate: 8, dt: dt)
            Self.ease(elbows[0], x: 0.3, rate: 6, dt: dt)
            tie.eulerAngles.z = swing * 0.08 * walk
        } else if mode == .spot || mode == .pursue {
            // The finger leads: pointing at you all the way; the other arm pumps.
            let raise: Float = mode == .spot ? 1.6 : 1.3
            Self.ease(head, x: mode == .spot ? 0.18 : -0.06, rate: 6, dt: dt)
            Self.ease(shoulders[1], x: raise, z: -0.1, rate: 9, dt: dt)
            Self.ease(elbows[1], x: 0.1 + sin(Float(time) * 8) * 0.07 * run, rate: 9, dt: dt)
            Self.ease(shoulders[0], x: swing * (0.3 + run * 0.4) * walk, z: -0.5, rate: 8, dt: dt)
            Self.ease(elbows[0], x: 0.9 + run * 0.3, rate: 6, dt: dt)
            tie.eulerAngles.z = swing * (0.08 + run * 0.18) * walk                    // the tie flaps
        } else {
            Self.ease(head, x: -abs(swing) * 0.04 * walk, rate: 6, dt: dt)
            for (i, side) in [Float(-1), 1].enumerated() {
                let arm = (i == 0 ? swing : -swing) * 0.3 * walk
                Self.ease(shoulders[i], x: arm, z: side * (mode == .chase ? 0.55 : 0.32), rate: 8, dt: dt)
                Self.ease(elbows[i], x: mode == .chase ? 0.9 : 0.25, rate: 6, dt: dt)
            }
            tie.eulerAngles.z = swing * 0.08 * walk
        }
    }
}

/// Oct 16: puts the one Big Shot on his floor (main actor: LivingWorld's bookkeeping).
enum BigShotAudition {
    static func populate(habitat: Habitat, scene: SCNScene, fromStart: [Int: Int], busy: Set<Int>, shadow: UIImage, floor: Int) {
        guard BigShot.isEnabled, floor == BigShot.floor else { return }
        let graph = habitat.graph
        var fromStart = fromStart
        if fromStart.isEmpty, let eye = habitat.playerCamera?.presentation.worldPosition {
            // (the player is off the graph -- in the office: measure from the nearest corridor cell)
            let here = SIMD2<Float>(eye.x, eye.z)
            if let near = graph.centers.min(by: { simd_length($0.value - here) < simd_length($1.value - here) })?.key {
                fromStart = graph.distances(from: [near])
            }
        }
        // A corridor cell (not a dead end) as far from the player as the floor allows.
        let candidates = graph.centers.keys.filter { k in
            !busy.contains(k) && !habitat.blockedCells.contains(k) && graph.degree(k) >= 2 && (fromStart[k] ?? 0) >= 3
        }
        guard let cell = candidates.max(by: { (fromStart[$0] ?? 0) < (fromStart[$1] ?? 0) }) else {
            diag("bigShot.notPlaced", ["reason": "no corridor cell far enough"]); return
        }
        let (shot, node) = BigShot.make(habitat: habitat, cell: cell, shadow: shadow)
        node.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }
        scene.rootNode.addChildNode(node)
        LivingWorld.track(node)
        habitat.add(shot)
        node.runAction(.repeatForever(shot.tickAction()), forKey: "critterTick")
        BonzoEviction.captureGraceUntil = CACurrentMediaTime() + BonzoEviction.graceOnArrival   // (Oct 16: never a grab on arrival)
        diag("bigShot.placed", ["cell": cell, "fromPlayer": fromStart[cell] ?? -1])
    }
}

// MARK: - Oct 16 -- BONZO'S EVICTION (audition)
//
// When the Big Shot catches the player (mid-pursuit, in sight, within arm's
// reach -- BigShot.captureRange) he grabs them by the collar and throws them
// out of the building -- the long way:
//   grab       he turns on them, the hand comes up, the view is hauled up off
//              its feet toward his face (CarryRig: the camera is held at a pose
//              in HIS frame -- every step, bob and turn of his is the camera's)
//   carry      Floor 3: along the corridors to the elevator (the floor's own
//              creature graph: no walls, no doors), held at arm's length facing
//              him, the corridor streaming away behind him
//   board      at the landing he turns them round to face the doors and plonks
//              them down; the ordinary elevator opens (TapNavigationController.
//              evictionBoard -> openElevator); the player is carried in by the
//              ride itself; he squeezes in after them into the back corner
//   ride       the building presses LOBBY (guidedAutoFloor -- the same automatic
//              press the onboarding rides use); the real ride, the real numbers
//   lobby      Floor 1 is built with him in the cab (floorBuilt); the doors
//              open, he steps up behind them, grabs again, and marches them out
//              of the cab and across the lobby to the entrance (the controller's
//              own route), facing forward this time: the doors coming at them
//   eject      at the doors he turns them round -- the accusation, "YOU",
//              STOMP -- turns them back, a shove, and they're outside
//              (the ordinary return to the street: NavigationBridge.
//              requestReturnToOpening -- the exterior view and the traffic)
// The player has no say from the grab to the street (evictionLocked). Progress
// is kept (ID, prologue, meetings, money, collected things); only where they
// are is reset: the resume point is cleared, so a relaunch opens outside.
// Anything that can't go on (no route, the elevator refuses, a scene torn
// down, a ride that never arrives) ends the eviction where it is: the player
// gets control back, he goes back to strolling, and a line is logged.
// Off: `-HallwaysNoBonzoEviction YES` (he still patrols and pursues).

/// The camera, held in the Big Shot's grip: a pose in his body's frame, eased
/// between poses; the grab itself blends from wherever the player was. Read on
/// the render thread by a transform constraint on the camera; set on main.
nonisolated final class CarryRig: @unchecked Sendable {
    struct Hold {
        var position: SIMD3<Float>
        var yaw: Float
        var pitch: Float
        var roll: Float

        /// Held at arm's length, facing him (he looms; the corridor recedes behind him).
        static let facingHim = Hold(position: SIMD3<Float>(0.25, 1.95, -0.85), yaw: .pi, pitch: 0.2, roll: 0.04)
        /// Held out in front of him, facing where he's going.
        static let forward = Hold(position: SIMD3<Float>(0.2, 1.9, -0.85), yaw: 0, pitch: -0.05, roll: -0.03)
        /// The shove: out of his hand, toward the doors.
        static let shove = Hold(position: SIMD3<Float>(0.2, 1.8, -1.45), yaw: 0, pitch: 0.06, roll: 0.02)

        static func mix(_ a: Hold, _ b: Hold, _ t: Float) -> Hold {
            Hold(position: a.position + (b.position - a.position) * t, yaw: a.yaw + (b.yaw - a.yaw) * t,
                 pitch: a.pitch + (b.pitch - a.pitch) * t, roll: a.roll + (b.roll - a.roll) * t)
        }

        var matrix: simd_float4x4 {
            func rot(_ angle: Float, _ axis: SIMD3<Float>) -> simd_float4x4 { simd_float4x4(simd_quatf(angle: angle, axis: axis)) }
            var t = matrix_identity_float4x4
            t.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
            return t * rot(yaw, SIMD3<Float>(0, 1, 0)) * rot(pitch, SIMD3<Float>(1, 0, 0)) * rot(roll, SIMD3<Float>(0, 0, 1))
        }
    }

    private let lock = NSLock()
    private weak var body: SCNNode?
    private var grabFrom: simd_float4x4?
    private var grabStart: CFTimeInterval
    private let grabDuration: Double
    private var holdFrom: Hold
    private var holdTo: Hold
    private var holdStart: CFTimeInterval = 0
    private var holdDuration: Double = 0

    init(body: SCNNode, from world: simd_float4x4, hold: Hold, grabDuration: Double) {
        self.body = body
        grabFrom = world
        grabStart = CACurrentMediaTime()
        self.grabDuration = grabDuration
        holdFrom = hold
        holdTo = hold
    }

    /// Main thread: ease to another hold.
    func move(to hold: Hold, duration: Double) {
        let now = CACurrentMediaTime()
        lock.lock()
        holdFrom = current(at: now)
        holdTo = hold
        holdStart = now
        holdDuration = duration
        lock.unlock()
    }

    private func current(at now: CFTimeInterval) -> Hold {
        guard holdDuration > 0 else { return holdTo }
        let u = Float(min(1, max(0, (now - holdStart) / holdDuration)))
        return Hold.mix(holdFrom, holdTo, u * u * (3 - 2 * u))
    }

    /// The camera's constraint (its block runs on the render thread, every frame).
    func makeConstraint() -> SCNTransformConstraint {
        SCNTransformConstraint(inWorldSpace: true) { [self] _, transform in self.worldTransform() ?? transform }
    }

    /// Render thread (the camera's constraint): where the camera is this frame.
    func worldTransform() -> SCNMatrix4? {
        let now = CACurrentMediaTime()
        lock.lock()
        let hold = current(at: now)
        let from = grabFrom
        let g = grabDuration > 0 ? min(1, (now - grabStart) / grabDuration) : 1
        lock.unlock()
        guard let body else { return nil }
        let b = body.presentation.simdWorldTransform
        // His frame without any scale (a squeeze through a doorway must never squash the view).
        var frame = matrix_identity_float4x4
        frame.columns.0 = SIMD4<Float>(simd_normalize(SIMD3<Float>(b.columns.0.x, b.columns.0.y, b.columns.0.z)), 0)
        frame.columns.1 = SIMD4<Float>(simd_normalize(SIMD3<Float>(b.columns.1.x, b.columns.1.y, b.columns.1.z)), 0)
        frame.columns.2 = SIMD4<Float>(simd_normalize(SIMD3<Float>(b.columns.2.x, b.columns.2.y, b.columns.2.z)), 0)
        frame.columns.3 = b.columns.3
        var target = frame * hold.matrix
        if let from, g < 1 {
            // The grab: from where they stood to his grip -- quick, with a jolt upward.
            let e = Float(1 - pow(1 - g, 3))
            let p0 = SIMD3<Float>(from.columns.3.x, from.columns.3.y, from.columns.3.z)
            let p1 = SIMD3<Float>(target.columns.3.x, target.columns.3.y, target.columns.3.z)
            let p = p0 + (p1 - p0) * e + SIMD3<Float>(0, sin(Float(g) * .pi) * 0.14, 0)
            let q = simd_slerp(simd_quatf(from), simd_quatf(target), e)
            target = simd_float4x4(q)
            target.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
        }
        return SCNMatrix4(target)
    }
}

enum BonzoEviction {
    nonisolated static let isEnabled = !UserDefaults.standard.bool(forKey: "HallwaysNoBonzoEviction")
    /// No grab before this (CACurrentMediaTime): set when Floor 3's Big Shot is
    /// placed, so arriving on the floor is never an instant capture.
    nonisolated(unsafe) static var captureGraceUntil: CFTimeInterval = 0
    static let graceOnArrival: CFTimeInterval = 20
    nonisolated static let walkKey = "bonzoWalk"
    static let carrySpeed: Float = 2.0

    enum Stage: String { case idle, grabbing, carrying, settingDown, boarding, lobbyWaiting, lobbyCarrying, ejecting }
    private(set) static var stage: Stage = .idle
    static var isActive: Bool { stage != .idle }

    /// Set by ContentView: the live controller, and the way out to the street.
    static var liveController: (() -> TapNavigationController?)?
    static var returnToStreet: (() -> Void)?

    private static var shot: BigShot?
    private static weak var controller: TapNavigationController?
    private static var rig: CarryRig?
    private static var constraint: SCNTransformConstraint?
    private static weak var heldCamera: SCNNode?
    private static var generation = 0
    private static var startedAt: CFTimeInterval = 0

    private static func log(_ event: String, _ fields: KeyValuePairs<String, Any?> = [:]) {
        diag("bonzo." + event, fields)
    }

    /// Heading (yaw) that faces along `d` (creatures face local -Z).
    private static func heading(_ d: SIMD2<Float>) -> Float { atan2(-d.x, -d.y) }

    /// Run `step` after `seconds` -- only if this eviction is still the one under way.
    private static func after(_ seconds: Double, _ step: @escaping () -> Void) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard gen == generation, stage != .idle else { return }
            step()
        }
    }

    // MARK: Capture

    /// The Big Shot has the player within reach (his tick asks; main decides).
    static func requestCapture(by shot: BigShot) {
        guard isEnabled, stage == .idle else { return }
        func refuse(_ why: String) { log("captureRefused", ["why": why]) }
        guard let c = liveController?(), c.currentFloorNumber == BigShot.floor else { return refuse("floor") }
        guard CACurrentMediaTime() >= captureGraceUntil else { return refuse("grace") }
        guard Admission.isPrologueCompleted, GuidedJourney.trip == nil else { return refuse("story") }
        guard !ConferenceMeeting.isActive, !OfficeComputer.shared.isActive, !BoxReveal.isRunning else { return refuse("scene") }
        guard !PlayerOffice.officeCells.contains(c.currentCell), !ConferenceRoom.roomCells.contains(c.currentCell) else {
            return refuse("room")
        }
        guard let node = shot.node, node.parent != nil, shot.habitat.playerCamera === c.cameraNode else { return refuse("scene") }
        if let why = c.evictionRefusal() { return refuse(why) }
        begin(shot: shot, node: node, controller: c)
    }

    private static func begin(shot: BigShot, node: SCNNode, controller c: TapNavigationController) {
        generation += 1
        stage = .grabbing
        startedAt = CACurrentMediaTime()
        self.shot = shot
        controller = c
        c.evictionLocked = true
        c.evictionStopMovement()
        ResumeState.clearPoint(reason: "bonzoCapture")
        let cam = c.cameraNode.presentation.worldPosition
        log("capture", ["cell": c.currentCell, "distance": Double(simd_distance(SIMD2<Float>(cam.x, cam.z),
                                                                                  SIMD2<Float>(node.position.x, node.position.z)))])
        shot.beginEscort()
        // He rounds on them; the hand comes up -- "YOU" -- and grabs.
        let toPlayer = SIMD2<Float>(cam.x - node.position.x, cam.z - node.position.z)
        if simd_length(toPlayer) > 0.01 {
            node.runAction(.rotateTo(x: 0, y: CGFloat(heading(toPlayer)), z: 0, duration: 0.25, usesShortestUnitArc: true))
        }
        shot.escortReach = 1
        shot.speak(.accuse)
        // However it goes, never for ever: the whole trip is well under this.
        after(150) { abort("watchdog") }
        after(0.3) {
            hold(camera: c.cameraNode, body: shot.body, hold: .facingHim, grab: 0.65)
            shot.scriptStomp()
            after(0.85) { carryToElevator() }
        }
    }

    /// The camera into his grip (a transform constraint reading the rig).
    private static func hold(camera: SCNNode, body: SCNNode, hold: CarryRig.Hold, grab: Double) {
        releaseCamera(settle: false)
        let rig = CarryRig(body: body, from: camera.presentation.simdWorldTransform, hold: hold, grabDuration: grab)
        let c = rig.makeConstraint()
        camera.constraints = (camera.constraints ?? []) + [c]
        self.rig = rig
        constraint = c
        heldCamera = camera
    }

    /// Let go of the camera exactly where it is (no jump); `settle` eases it level, at eye height.
    private static func releaseCamera(settle: Bool) {
        guard let camera = heldCamera, let c = constraint else { rig = nil; constraint = nil; return }
        let world = camera.presentation.worldTransform
        camera.constraints = camera.constraints?.filter { $0 !== c }
        camera.setWorldTransform(world)
        rig = nil
        constraint = nil
        heldCamera = nil
        guard settle, let ctl = controller else { return }
        let start = camera.position, startEuler = camera.eulerAngles
        let eye = ctl.eyeHeight
        camera.removeAllActions()
        camera.runAction(.customAction(duration: 0.3) { node, elapsed in
            let t = Float(min(1, elapsed / 0.3))
            let e = t * t * (3 - 2 * t)
            node.position = SCNVector3(start.x, start.y + (eye - start.y) * e, start.z)
            node.eulerAngles = SCNVector3(startEuler.x * (1 - e), startEuler.y, startEuler.z * (1 - e))
        })
    }

    /// Walk his node through `points` (x/z, floor level) at `speed`, turning as he goes.
    /// `turning: false` -- a step without turning (backing off, still facing the same way).
    private static func walk(_ node: SCNNode, _ points: [SIMD2<Float>], speed: Float, turning: Bool = true,
                             then done: @escaping () -> Void) {
        var here = SIMD2<Float>(node.position.x, node.position.z)
        var steps: [SCNAction] = []
        for p in points {
            let d = p - here
            let length = simd_length(d)
            guard length > 0.02 else { continue }
            let seconds = Double(length / speed)
            let turn = SCNAction.rotateTo(x: 0, y: CGFloat(heading(d)), z: 0, duration: min(0.35, seconds), usesShortestUnitArc: true)
            let move = SCNAction.move(to: SCNVector3(p.x, 0, p.y), duration: seconds)
            steps.append(turning ? .group([move, turn]) : move)
            here = p
        }
        let gen = generation
        node.removeAction(forKey: walkKey)
        guard !steps.isEmpty else {
            DispatchQueue.main.async { guard gen == generation, stage != .idle else { return }; done() }
            return
        }
        node.runAction(.sequence(steps), forKey: walkKey) {
            DispatchQueue.main.async { guard gen == generation, stage != .idle else { return }; done() }
        }
    }

    private static func turn(_ node: SCNNode, toward d: SIMD2<Float>, seconds: Double) {
        node.runAction(.rotateTo(x: 0, y: CGFloat(heading(d)), z: 0, duration: seconds, usesShortestUnitArc: true))
    }

    // MARK: Floor 3 -- to the elevator

    private static func carryToElevator() {
        guard stage == .grabbing, let shot, let node = shot.node, node.parent != nil, let c = controller,
              let landing = c.evictionLanding() else { return abort("floor3Gone") }
        let graph = shot.graph
        let here = SIMD2<Float>(node.position.x, node.position.z)
        // The landing's own cell (or, if the creatures' floor leaves it out, the nearest one to it).
        var goal = HabitatGraph.key(row: landing.cell.row, col: landing.cell.col)
        if graph.centers[goal] == nil {
            guard let near = graph.centers.min(by: { simd_length($0.value - landing.center) < simd_length($1.value - landing.center) }),
                  simd_length(near.value - landing.center) < graph.cellSize * 1.1 else { return abort("landingNotWalkable") }
            goal = near.key
        }
        let distance = graph.distances(from: [goal])
        guard var k = graph.centers.filter({ distance[$0.key] != nil })
                .min(by: { simd_length($0.value - here) < simd_length($1.value - here) })?.key else { return abort("noRoute") }
        var points: [SIMD2<Float>] = [graph.centers[k] ?? here]
        while k != goal {
            guard let n = (graph.neighbors[k] ?? []).filter({ (distance[$0] ?? .max) < (distance[k] ?? .max) })
                    .min(by: { (distance[$0] ?? .max) < (distance[$1] ?? .max) }), let p = graph.centers[n] else { return abort("noRoute") }
            points.append(p)
            k = n
        }
        if simd_length((points.last ?? here) - landing.center) > 0.05 { points.append(landing.center) }
        // (The nearest cell centre can lie behind him on the way: then straight on to the next.)
        if points.count >= 2, simd_dot(points[0] - here, points[1] - points[0]) < 0 { points.removeFirst() }
        stage = .carrying
        log("carry", ["cells": points.count])
        walk(node, points, speed: carrySpeed) { atTheElevator(landing: landing) }
    }

    private static func atTheElevator(landing: (center: SIMD2<Float>, outward: SIMD2<Float>, cell: GridCoordinate)) {
        guard stage == .carrying, let shot, let node = shot.node, node.parent != nil, let c = controller else { return abort("floor3Gone") }
        stage = .settingDown
        let u = landing.outward, l = landing.center
        // Facing the doors; he turns them round to face them too...
        turn(node, toward: -u, seconds: 0.35)
        rig?.move(to: .forward, duration: 0.7)
        after(0.75) {
            // ...steps back, so they stand on the landing...
            walk(node, [l + u * 0.85], speed: 1.4, turning: false) {
                // ...and plonks them down. The ordinary elevator takes it from here.
                releaseCamera(settle: true)
                shot.escortReach = 0
                shot.speak(.plain)
                after(0.32) { board(controller: c, shot: shot, node: node, landing: landing) }
            }
        }
    }

    private static func board(controller c: TapNavigationController, shot: BigShot, node: SCNNode,
                              landing: (center: SIMD2<Float>, outward: SIMD2<Float>, cell: GridCoordinate)) {
        stage = .boarding
        guard c.evictionBoard() else { return abort("elevatorRefused") }
        log("boarding", [:])
        // Doors open (0.08 s wait + 1.6 s), the ride carries the player in; he
        // squeezes in after them, into the back corner away from the panel.
        let u = landing.outward
        let door = c.elevatorDoorwayFrame()?.center ?? landing.center - u * (shot.graph.cellSize / 2)
        let lateral = SIMD2<Float>(-u.y, u.x)
        let side = panelSide(root: node.parent, door: door, lateral: lateral)
        let inside = door - u * 0.6 + lateral * (side * 1.05)
        let corner = door - u * 2.5 + lateral * (side * 1.05)
        after(3.3) {
            shot.squeeze = 0.72
            walk(node, [door, inside, corner], speed: 2.4) {
                shot.squeeze = 1
                turn(node, toward: u, seconds: 0.4)
            }
            after(1.6) { shot.squeeze = 1 }
        }
        // A ride that never reaches the lobby: give the player back their controls.
        after(45) {
            if stage == .boarding { abort("rideNeverArrived") }
        }
    }

    /// Which side of the cab (along `lateral`) is clear of the control panel: +1 or -1.
    private static func panelSide(root: SCNNode?, door: SIMD2<Float>, lateral: SIMD2<Float>) -> Float {
        guard let panel = root?.childNode(withName: "elevatorControlPanel", recursively: true) else { return 1 }
        let p = panel.worldPosition
        return simd_dot(SIMD2<Float>(p.x, p.z) - door, lateral) > 0 ? -1 : 1
    }

    /// The building presses LOBBY for this ride.
    static func autoFloor(from floor: Int) -> Int? {
        stage == .boarding && floor == BigShot.floor ? 1 : nil
    }

    // MARK: Floor 1 -- the lobby

    /// Every floor build. The lobby, built for the arriving ride: he's in the cab.
    static func floorBuilt(floor: Int, controller c: TapNavigationController, root: SCNNode, camera: SCNNode,
                           context: CharacterLead.Context?) {
        if stage != .idle, stage != .boarding { return abort("sceneRebuilt") }   // (any other stage: his scene is gone)
        guard stage == .boarding else { return }
        guard floor == 1 else {
            if floor != BigShot.floor { abort("diverted") }
            return
        }
        guard let context, let frame = c.elevatorDoorwayFrame() else { return abort("noLobbyCab") }
        let graph = Menagerie.makeGraph(cells: context.cells, cellSize: CGFloat(context.cellSize),
                                        doors: context.doors.map { ($0.key, $0.value) }, litCells: [])
        let habitat = Habitat(graph: graph, root: root, playerCamera: camera)
        let (bonzo, node) = BigShot.make(habitat: habitat, cell: graph.centers.keys.first ?? 0, shadow: Menagerie.shadowImage())
        node.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }
        let u = frame.outward, door = frame.center
        let lateral = SIMD2<Float>(-u.y, u.x)
        let spot = door - u * 2.5 + lateral * (panelSide(root: root, door: door, lateral: lateral) * 1.05)
        node.position = SCNVector3(spot.x, 0, spot.y)
        node.eulerAngles.y = heading(u)
        root.addChildNode(node)
        habitat.add(bonzo)
        bonzo.beginEscort()
        shot = bonzo
        controller = c
        c.evictionLocked = true
        stage = .lobbyWaiting
        log("lobbyCabReady", [:])
    }

    /// The lobby doors are opening (onArrivalDoorsOpening).
    static func arrivalDoorsOpening(floor: Int) {
        guard floor == 1, stage == .lobbyWaiting else { return }
        after(1.9) { lobbyGrab() }
    }

    private static func lobbyGrab() {
        guard stage == .lobbyWaiting, let shot, let node = shot.node, node.parent != nil,
              let c = liveController?(), c === controller, let frame = c.elevatorDoorwayFrame(),
              let route = c.evictionRouteToEntrance() else { return abort("lobbyUnavailable") }
        stage = .lobbyCarrying
        let u = frame.outward, door = frame.center
        let cam = c.cameraNode.presentation.worldPosition
        let player = SIMD2<Float>(cam.x, cam.z)
        let behind = player - u * 0.85
        // Up behind them, facing out of the cab...
        walk(node, [behind], speed: 1.5) {
            turn(node, toward: u, seconds: 0.3)
            after(0.3) {
                // ...grab, from behind, the doors and the lobby ahead...
                c.cameraNode.removeAllActions()                  // (the arrival's own turn to the doors)
                shot.escortReach = 1
                shot.speak(.plain)
                hold(camera: c.cameraNode, body: shot.body, hold: .forward, grab: 0.55)
                after(0.75) {
                    // ...and out: through the doorway (breathing in), across the lobby, to the entrance.
                    let depth = simd_dot(door - behind, u)          // (how deep in the cab he stands)
                    let axis = door - u * depth
                    var points = [axis, door + u * 0.4]
                    points.append(contentsOf: route.points)
                    shot.squeeze = 0.72
                    after(Double(simd_distance(behind, door) + 1.0) / Double(carrySpeed)) { shot.squeeze = 1 }
                    log("lobbyCarry", ["cells": route.points.count])
                    walk(node, points, speed: carrySpeed) {
                        turn(node, toward: route.entranceHeading, seconds: 0.4)
                        after(0.45) { eject() }
                    }
                }
            }
        }
    }

    // MARK: Out

    private static func eject() {
        guard stage == .lobbyCarrying, let shot, shot.node?.parent != nil else { return abort("lobbyGone") }
        stage = .ejecting
        // Round to face him: the last word.
        rig?.move(to: .facingHim, duration: 0.6)
        after(0.65) {
            shot.scriptGesture(.accuse)
            after(2.5) {
                // Back round to the doors -- and OUT.
                rig?.move(to: .forward, duration: 0.45)
                after(0.5) {
                    rig?.move(to: .shove, duration: 0.22)
                    shot.scriptStomp()
                    after(0.26) { finish() }
                }
            }
        }
    }

    private static func finish() {
        guard stage == .ejecting else { return }
        releaseCamera(settle: false)
        if let camera = controller?.cameraNode {
            let e = camera.eulerAngles
            camera.eulerAngles = SCNVector3(0, e.y, 0)
        }
        controller?.evictionLeftCab()                       // (the street's reset: at the entrance, not the cab)
        controller?.evictionLocked = false
        ResumeState.clearPoint(reason: "bonzoEjected")
        let node = shot?.node
        log("ejected", ["seconds": Int(CACurrentMediaTime() - startedAt)])
        stage = .idle
        generation += 1
        shot = nil
        controller = nil
        returnToStreet?()                                   // the exterior, the traffic -- as walking out does
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { node?.removeFromParentNode() }
    }

    // MARK: Can't go on

    /// End it where it is: the player gets control back; he goes back to strolling
    /// (on Floor 3) or leaves (the lobby). Logged.
    static func abort(_ reason: String) {
        guard stage != .idle else { return }
        log("aborted", ["reason": reason, "stage": stage.rawValue])
        let was = stage
        stage = .idle
        generation += 1
        releaseCamera(settle: false)
        // The controller back in step with where the camera actually is (unless the
        // ordinary ride is still carrying them -- the elevator's own flow ends that).
        if was != .boarding && was != .lobbyWaiting, let live = liveController?() { live.evictionResync() }
        controller?.evictionLocked = false
        liveController?()?.evictionLocked = false
        if let shot, let node = shot.node, node.parent != nil {
            if was == .grabbing || was == .carrying || was == .settingDown || was == .boarding {
                shot.releaseFromEscort()
            } else if was == .lobbyWaiting || was == .lobbyCarrying || was == .ejecting {
                node.removeFromParentNode()
            }
        }
        shot = nil
        controller = nil
    }
}
