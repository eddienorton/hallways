//
//  Bobbin.swift
//  Hallways
//
//  Oct 3 -- FIRST AUTONOMOUS CRITTER (experiment). Working name: BOBBIN.
//
//  One small creature that roams the floor on its own. Nobody controls it.
//  It walks the maze graph (cell centre to cell centre, only through open
//  boundaries -- never a wall, never any door), makes its own choices at
//  intersections, pauses now and then, and has one tiny instinct about
//  Noodle: notice -> maybe come closer -> run off if he gets too close.
//  It chirps now and then through SceneKit's positional audio.
//
//  Self-contained like TinCanRat.swift: it READS the floor topology (handed
//  over at install), the player camera and Noodle's node; it never writes to
//  navigation or to Noodle. One repeating SCNAction on its own root drives it;
//  every floor change builds a new scene, so it is rebuilt fresh there.
//

import SceneKit
import UIKit
import AVFoundation
import simd

enum Bobbin {
    static let rootName = "bobbin"
    nonisolated static let categoryBit = 1 << 10
    /// Habitat pass: 25% bigger than the first Bobbin, uniformly.
    static let scale: Float = 1.25

    /// Called once per floor build, after TinCanRat.install.
    static func install(in view: SCNView, scene: SCNScene, playerCamera: SCNNode, cells: Set<GridCoordinate>,
                        cellSize: CGFloat, doors: [(GridCoordinate, Direction)]) {
        // Topology as plain numbers: open neighbours of every cell, minus any
        // boundary that has a door of any kind (he never uses doors).
        func key(_ c: GridCoordinate) -> Int { BobbinDriver.cellKey(row: c.row, col: c.col) }
        var blocked = Set<Int64>()
        func edge(_ a: Int, _ b: Int) -> Int64 { Int64(min(a, b)) << 32 | Int64(max(a, b)) }
        for (coord, direction) in doors {
            let n = GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col)
            blocked.insert(edge(key(coord), key(n)))
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

        // Start somewhere far (by walking distance) from the player.
        let eye = playerCamera.presentation.worldPosition
        let startCell = key(GridCoordinate(row: Int((CGFloat(eye.z) / cellSize).rounded()), col: Int((CGFloat(eye.x) / cellSize).rounded())))
        var distance: [Int: Int] = [:]
        var queue = [startCell]
        if centers[startCell] != nil { distance[startCell] = 0 }
        while !queue.isEmpty {
            let k = queue.removeFirst()
            for n in neighbors[k] ?? [] where distance[n] == nil {
                distance[n] = (distance[k] ?? 0) + 1
                queue.append(n)
            }
        }
        // Habitat pass: about four Bobbins (fewer on small floors -- one per ~8
        // cells), spread out: the first in the far part of the floor, each next
        // one in the far-part cell farthest (by walking) from those already
        // placed. Same brain for all of them.
        var wanted = min(4, max(1, cells.count / 8))
        // Oct 4 DIAGNOSTIC "DOUBLE THE ZOO": up to eight (one per ~4 cells) at 32 only.
        if LivingWorld.isCrowd { wanted = min(8, max(1, cells.count / 4)) }
        let farthest = distance.values.max() ?? 0
        var candidates = distance.filter { $0.value >= max(1, Int(Double(farthest) * 0.4)) }.map(\.key)
        if candidates.isEmpty {
            candidates = neighbors.keys.filter { $0 != startCell && !(neighbors[$0] ?? []).isEmpty }
        }
        guard let first = candidates.randomElement() else {
            diag("bobbin.skipped", ["reason": "no room to roam", "cells": cells.count])
            return
        }
        func walkingDistances(from sources: [Int]) -> [Int: Int] {
            var result: [Int: Int] = [:]
            var frontier = sources
            for k in sources { result[k] = 0 }
            while !frontier.isEmpty {
                let k = frontier.removeFirst()
                for n in neighbors[k] ?? [] where result[n] == nil {
                    result[n] = (result[k] ?? 0) + 1
                    frontier.append(n)
                }
            }
            return result
        }
        var spawns = [first]
        while spawns.count < wanted {
            let apart = walkingDistances(from: spawns)
            guard let next = candidates.filter({ !spawns.contains($0) }).max(by: { (apart[$0] ?? 0) < (apart[$1] ?? 0) }) else { break }
            spawns.append(next)
        }

        // Positional audio: quiet far away, louder close up, panned left/right.
        // (Oct 5: the view's attenuation is now set per floor by CritterAudio.)

        let flock = BobbinFlock()
        for spawn in spawns {
            guard LivingWorld.admit() else { continue }   // Oct 4 DIAGNOSTIC population cap
            let node = BobbinModel.make()
            node.name = rootName
            node.scale = SCNVector3(scale, scale, scale)
            scene.rootNode.addChildNode(node)
            LivingWorld.track(node)
            let driver = BobbinDriver(node: node, sceneRoot: scene.rootNode, playerCamera: playerCamera,
                                      neighbors: neighbors, centers: centers, cellSize: Float(cellSize), spawn: spawn)
            driver.flock = flock
            flock.add(driver)
            node.runAction(.repeatForever(driver.tickAction()), forKey: "bobbinTick")
        }
        diag("bobbin.installed", ["count": spawns.count, "cells": cells.count, "admissionPending": Admission.isPending,
                                  "spawnSteps": spawns.map { distance[$0] ?? -1 }.map(String.init).joined(separator: ","),
                                  "doorEdgesBlocked": blocked.count])
    }
}

/// The tiny brain + body motion. Runs inside an SCNAction block (render thread).
nonisolated final class BobbinDriver: @unchecked Sendable {
    // Speeds (m/s). The player's walk runs at 6.
    static let roamSpeed: Float = 1.5
    static let curiousSpeed: Float = 0.9
    static let fleeSpeed: Float = 3.4
    // Noodle instinct distances (m).
    static let noticeRange: Float = 9
    static let comfortRange: Float = 3     // curiosity stops closing in here
    static let tooClose: Float = 2         // run away
    static let safeAgain: Float = 7        // stop running
    static let strideLength: Float = 0.16
    static let bodyHeight: Float = 0.24        // = BobbinModel leg length + half the spool

    enum Mode { case roam, notice, curious, flee }

    private weak var node: SCNNode?
    private weak var sceneRoot: SCNNode?
    private weak var playerCamera: SCNNode?
    private let body: SCNNode?
    private let eyeStalk: SCNNode?
    private let legs: [SCNNode]
    private let neighbors: [Int: [Int]]
    private let centers: [Int: SIMD2<Float>]
    private let cellSize: Float

    private var from: Int
    private var to: Int
    private var progress: Float = 0
    private var speed: Float = 0
    private var heading: Float = 0
    private var gaitPhase: Float = 0
    private var gaitAmount: Float = 0
    private var mode: Mode = .roam
    private var modeTime: Double = 0
    private var pause: Double = 0
    private var noticeCooldown: Double = 0
    private var senseTimer: Double = 0
    private var chirpTimer: Double = Double.random(in: 1...4)
    /// Habitat pass: the other Bobbins on this floor (for not bumping into them).
    var flock: BobbinFlock?
    private var bumpCooldown: Double = 0
    private var lastTime: CFTimeInterval = 0
    private var noodle = SIMD2<Float>(0, 0)
    private var noodleDistance: Float = .greatestFiniteMagnitude
    private var canSeeNoodle = false

    private static let chirpRoam = BobbinSound.source(.chirrup)
    private static let chirpNotice = BobbinSound.source(.query)
    private static let chirpFlee = BobbinSound.source(.alarm)

    static func cellKey(row: Int, col: Int) -> Int { row * 100_000 + col }

    init(node: SCNNode, sceneRoot: SCNNode, playerCamera: SCNNode, neighbors: [Int: [Int]], centers: [Int: SIMD2<Float>],
         cellSize: Float, spawn: Int) {
        self.node = node
        self.sceneRoot = sceneRoot
        self.playerCamera = playerCamera
        self.body = node.childNode(withName: "bobbinBody", recursively: false)
        self.eyeStalk = node.childNode(withName: "bobbinStalk", recursively: true)
        self.legs = (0..<2).compactMap { node.childNode(withName: "bobbinLeg\($0)", recursively: true) }
        self.neighbors = neighbors
        self.centers = centers
        self.cellSize = cellSize
        self.from = spawn
        self.to = (neighbors[spawn] ?? []).randomElement() ?? spawn
        if let c = centers[spawn] { node.position = SCNVector3(c.x, 0, c.y) }
        let d = direction()
        heading = atan2(-d.x, -d.y)
        pause = Double.random(in: 0.5...2)
    }

    func tickAction() -> SCNAction {
        // Strong on purpose: this action (on his own node) is the ONLY owner
        // of the driver. With [weak self] nothing kept it alive, so it was
        // freed the moment install returned and every tick was a no-op.
        // No cycle: the driver holds its node weakly; the driver dies with
        // the node/scene on the next floor build.
        SCNAction.customAction(duration: 1) { _, _ in self.tick() }
    }

    private func direction() -> SIMD2<Float> {
        guard let a = centers[from], let b = centers[to], from != to else { return SIMD2<Float>(0, -1) }
        return simd_normalize(b - a)
    }

    private var position: SIMD2<Float> {
        (centers[from] ?? .zero) + direction() * (from == to ? 0 : progress)
    }

    private func tick() {
        guard let node else { return }
        let now = CACurrentMediaTime()
        let dt = Float(lastTime == 0 ? 1.0 / 60 : min(max(now - lastTime, 0), 1.0 / 20))
        lastTime = now
        guard dt > 0 else { return }
        let dtd = Double(dt)
        modeTime += dtd
        noticeCooldown = max(0, noticeCooldown - dtd)

        sense(dt: dtd)
        decide()

        // Speed for this mode; paused = stand still.
        var wanted: Float
        switch mode {
        case .roam: wanted = Self.roamSpeed
        case .notice: wanted = 0
        case .curious: wanted = noodleDistance > Self.comfortRange ? Self.curiousSpeed : 0
        case .flee: wanted = Self.fleeSpeed
        }
        if pause > 0 { pause -= dtd; wanted = 0 }
        // Habitat pass: don't walk straight into another Bobbin just ahead --
        // stop for a moment, and sometimes turn back. (No social rules: this
        // only keeps two of them from occupying the same spot.)
        bumpCooldown = max(0, bumpCooldown - dtd)
        if mode != .flee, wanted > 0, bumpCooldown <= 0, from != to, let flock {
            let here = position
            let ahead = direction()
            for other in flock.members where other !== self {
                let offset = other.position - here
                let d = simd_length(offset)
                if d > 0.001, d < 0.75, simd_dot(offset / d, ahead) > 0.3 {
                    bumpCooldown = 1.5
                    pause = Double.random(in: 0.3...0.9)
                    wanted = 0
                    if Float.random(in: 0...1) < 0.4 { reverse() }
                    break
                }
            }
        }
        if from == to { wanted = 0; chooseNext() }
        speed += (wanted - speed) * min(1, dt * (mode == .flee ? 9 : 4))

        // Advance along the current cell-to-cell segment.
        var moved = speed * dt
        let travelled = moved
        while moved > 0, from != to {
            let remaining = cellSize - progress
            if moved < remaining { progress += moved; moved = 0 }
            else {
                moved -= remaining
                arrive()
            }
        }

        // Face where he's going; when standing, face Noodle if he's watching him.
        let p = position
        var desired = heading
        if speed > 0.15 {
            let d = direction()
            desired = atan2(-d.x, -d.y)
        } else if (mode == .notice || mode == .curious) && canSeeNoodle {
            let toNoodle = noodle - p
            desired = atan2(-toNoodle.x, -toNoodle.y)
        }
        var turn = desired - heading
        while turn > .pi { turn -= 2 * .pi }
        while turn < -.pi { turn += 2 * .pi }
        let headingStep = turn * min(1, dt * 7)
        heading += headingStep

        // Gait from distance (and a little from turning on the spot).
        gaitPhase += (travelled + abs(headingStep) * 0.05) / Self.strideLength * .pi
        let wantGait = min(1, speed / 0.5 + abs(headingStep) / max(dt, 0.001) / 3)
        gaitAmount += (wantGait - gaitAmount) * min(1, dt * 8)

        node.position = SCNVector3(p.x, 0, p.y)
        node.eulerAngles = SCNVector3(0, heading, 0)
        let hop = abs(sin(gaitPhase))
        body?.position.y = Self.bodyHeight + hop * 0.03 * gaitAmount
        body?.eulerAngles.z = sin(gaitPhase) * 0.12 * gaitAmount          // waddle
        body?.eulerAngles.x = -min(0.25, speed / Self.fleeSpeed * 0.25)   // leans in when running
        for (i, leg) in legs.enumerated() {
            leg.eulerAngles.x = sin(gaitPhase + (i == 0 ? 0 : .pi)) * 0.8 * gaitAmount
        }
        // Eye stalk: looks about while paused, bounces while moving.
        let idleLook = (pause > 0 && mode == .roam) ? sin(Float(modeTime) * 2.3) * 0.9 : 0
        eyeStalk?.eulerAngles = SCNVector3(-0.15 + hop * 0.12 * gaitAmount, idleLook, 0)

        chirp(dt: dtd, at: node)

        // TEMPORARY DIAGNOSTIC (Oct 3, "Bobbin is dead" fix): once a second for
        // his first minute -- proves the loop runs and shows what he's doing.
        diagnosticTimer -= dtd
        if diagnosticTimer <= 0, diagnosticLines < 60 {
            diagnosticTimer = 1
            diagnosticLines += 1
            diag("bobbin.alive", ["mode": "\(mode)", "from": from, "to": to, "progress": progress, "speed": speed,
                                  "pause": pause, "noodleDistance": noodleDistance.isFinite ? noodleDistance : -1,
                                  "seesNoodle": canSeeNoodle, "noodleNodeFound": noodleNodeFound])
        }
    }
    private var diagnosticTimer: Double = 0          // TEMPORARY DIAGNOSTIC
    private var diagnosticLines = 0                  // TEMPORARY DIAGNOSTIC
    private var noodleNodeFound = false              // TEMPORARY DIAGNOSTIC

    // MARK: Senses -- where is Noodle (or the player, if Noodle is switched off)?

    private func sense(dt: Double) {
        senseTimer -= dt
        guard senseTimer <= 0 else { return }
        senseTimer = 0.3
        let ratNode = sceneRoot.flatMap { CritterTags.ecosystemBody(.jeff, under: $0) } // Oct 6: by identity
        noodleNodeFound = ratNode != nil                 // TEMPORARY DIAGNOSTIC
        if let rat = ratNode, !rat.isHidden {
            let r = rat.presentation.worldPosition
            noodle = SIMD2<Float>(r.x, r.z)
        } else if let eye = playerCamera?.presentation.worldPosition {
            noodle = SIMD2<Float>(eye.x, eye.z)
        }
        let p = position
        noodleDistance = simd_length(noodle - p)
        canSeeNoodle = false
        if noodleDistance < Self.noticeRange, let root = sceneRoot {
            let hits = root.hitTestWithSegment(from: SCNVector3(p.x, 0.3, p.y), to: SCNVector3(noodle.x, 0.3, noodle.y), options: [
                SCNHitTestOption.categoryBitMask.rawValue: ~(Self.categoryBits),
                SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue,
                SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
                SCNHitTestOption.backFaceCulling.rawValue: false
            ])
            canSeeNoodle = hits.isEmpty
        }
    }

    private static let categoryBits = Bobbin.categoryBit | CritterCategory.storyCritters

    // MARK: The whole brain

    private func decide() {
        // Too close (seen or not -- he can hear him): run.
        if noodleDistance < Self.tooClose, mode != .flee {
            setMode(.flee)
            pause = 0
            play(Self.chirpFlee)
            // Heading straight at Noodle? Turn round on the spot.
            if from != to, simd_dot(direction(), noodle - position) > 0 { reverse() }
            return
        }
        switch mode {
        case .flee:
            if noodleDistance > Self.safeAgain || modeTime > 6 {
                setMode(.roam)
                noticeCooldown = 5
            }
        case .roam:
            if canSeeNoodle, noticeCooldown <= 0 {
                setMode(.notice)
                pause = 0
                play(Self.chirpNotice)
            }
        case .notice:
            if modeTime > Double.random(in: 0.9...1.8) {
                noticeCooldown = 8
                setMode(Bool.random() ? .curious : .roam)
            }
        case .curious:
            if modeTime > 6 || !canSeeNoodle && modeTime > 2 { setMode(.roam) }
        }
    }

    private func setMode(_ m: Mode) {
        mode = m
        modeTime = 0
    }

    private func reverse() {
        swap(&from, &to)
        progress = cellSize - progress
    }

    /// Reached `to`: it becomes the new `from`, and he picks where next.
    private func arrive() {
        let cameFrom = from
        from = to
        progress = 0
        chooseNext(cameFrom: cameFrom)
    }

    private func chooseNext(cameFrom: Int? = nil) {
        let options = neighbors[from] ?? []
        guard !options.isEmpty else { to = from; return }
        let forward = options.filter { $0 != cameFrom }
        let pool = forward.isEmpty ? options : forward          // dead end: the only way is back
        let here = centers[from] ?? .zero
        func distanceToNoodle(_ k: Int) -> Float { simd_length((centers[k] ?? here) - noodle) }
        switch mode {
        case .flee:
            to = options.max { distanceToNoodle($0) < distanceToNoodle($1) } ?? pool[0]
        case .curious:
            to = pool.min { distanceToNoodle($0) < distanceToNoodle($1) } ?? pool[0]
        case .roam, .notice:
            // Mostly carry on straight if he can; otherwise any open way but back.
            let previous = cameFrom.flatMap { centers[$0] }
            let straight = pool.first { k in
                guard let previous, let c = centers[k] else { return false }
                return simd_dot(simd_normalize(here - previous), simd_normalize(c - here)) > 0.9
            }
            if let straight, Float.random(in: 0...1) < 0.55 { to = straight } else { to = pool.randomElement() ?? pool[0] }
            // Now and then he stops to think -- more often where the ways divide.
            if mode == .roam, cameFrom != nil {
                let odds: Float = options.count >= 3 ? 0.3 : 0.06
                if Float.random(in: 0...1) < odds { pause = Double.random(in: 0.8...3) }
            }
        }
    }

    // MARK: Voice

    private func chirp(dt: Double, at node: SCNNode) {
        chirpTimer -= dt
        guard chirpTimer <= 0 else { return }
        switch mode {
        case .flee: play(Self.chirpFlee); chirpTimer = Double.random(in: 1.2...2)
        case .curious: play(Self.chirpRoam); chirpTimer = Double.random(in: 2...3.5)
        default: play(Self.chirpRoam); chirpTimer = Double.random(in: 3...7)
        }
    }

    private func play(_ source: SCNAudioSource?) {
        guard let source, let node else { return }
        CritterAudio.play(source, on: node)
    }
}

/// Bobbin's voice, synthesised once into small mono WAV files (no assets).
nonisolated enum BobbinSound {
    enum Kind: String { case chirrup, query, alarm }

    static func source(_ kind: Kind) -> SCNAudioSource? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bobbin-\(kind.rawValue).wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? wav(samples(kind)).write(to: url)) != nil else { return nil }
        }
        guard let source = SCNAudioSource(url: url) else { return nil }
        source.isPositional = true      // mono + positional: distance + left/right
        source.shouldStream = false
        source.volume = 0.9
        source.load()
        return source
    }

    static let rate = 44_100

    /// Little rising sweeps with soft edges (no clicks).
    private static func samples(_ kind: Kind) -> [Float] {
        typealias Sweep = (start: Float, end: Float, seconds: Float, gapAfter: Float)
        let sweeps: [Sweep]
        switch kind {
        case .chirrup: sweeps = [(1900, 3000, 0.07, 0.045), (2100, 3300, 0.06, 0)]
        case .query: sweeps = [(1500, 2900, 0.16, 0)]
        case .alarm: sweeps = [(2800, 4200, 0.05, 0.03), (2800, 4300, 0.05, 0.03), (2900, 4500, 0.05, 0)]
        }
        var out: [Float] = []
        for s in sweeps {
            let n = Int(s.seconds * Float(rate))
            var phase: Float = 0
            for i in 0..<n {
                let t = Float(i) / Float(n)
                let f = s.start + (s.end - s.start) * t
                phase += 2 * .pi * f / Float(rate)
                let envelope = sin(.pi * t)                   // soft attack + release
                let warble = 1 + 0.15 * sin(phase * 0.031)    // a little roughness
                out.append(sin(phase) * envelope * 0.55 * warble)
            }
            out.append(contentsOf: repeatElement(0, count: Int(s.gapAfter * Float(rate))))
        }
        return out
    }

    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        let byteCount = UInt32(samples.count * 2)
        data.append("RIFF".data(using: .ascii)!); u32(36 + byteCount)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(byteCount)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32_000))) }
        return data
    }
}

/// The body: an upright wooden thread spool on two wire legs, with one big
/// eye on a stalk. Local forward is -z. About 0.45 m tall.
enum BobbinModel {
    static let legLength: Float = 0.14
    static let spoolHeight: Float = 0.2
    static var bodyHeight: Float { BobbinDriver.bodyHeight }

    static func make() -> SCNNode {
        let root = SCNNode()
        func mat(_ color: UIColor, rough: CGFloat = 0.7, glow: UIColor? = nil) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color
            m.metalness.contents = 0.0
            m.roughness.contents = rough
            if let glow { m.emission.contents = glow }
            return m
        }
        let wood = mat(UIColor(red: 0.80, green: 0.62, blue: 0.40, alpha: 1))
        let thread = mat(UIColor(red: 0.10, green: 0.62, blue: 0.60, alpha: 1), rough: 0.9)
        let wire = mat(UIColor(white: 0.15, alpha: 1), rough: 0.4)
        let shoe = mat(UIColor(red: 0.95, green: 0.45, blue: 0.12, alpha: 1), rough: 0.6)
        let eyeWhite = mat(.white, rough: 0.3, glow: UIColor(white: 0.3, alpha: 1))
        let pupil = mat(.black, rough: 0.2)

        // Contact shadow (scene lights cast none).
        let shadowPlane = SCNPlane(width: 0.34, height: 0.34)
        let shadowMat = SCNMaterial()
        shadowMat.lightingModel = .constant
        shadowMat.diffuse.contents = shadowImage()
        shadowMat.writesToDepthBuffer = false
        shadowPlane.materials = [shadowMat]
        let shadow = SCNNode(geometry: shadowPlane)
        shadow.eulerAngles.x = -.pi / 2
        shadow.position.y = 0.004
        shadow.renderingOrder = 1
        root.addChildNode(shadow)

        let body = SCNNode()
        body.name = "bobbinBody"
        body.position.y = bodyHeight
        root.addChildNode(body)
        let core = SCNNode(geometry: SCNCylinder(radius: 0.075, height: CGFloat(spoolHeight)))
        core.geometry?.materials = [thread]
        body.addChildNode(core)
        for y in [-spoolHeight / 2, spoolHeight / 2] {
            let flange = SCNNode(geometry: SCNCylinder(radius: 0.105, height: 0.025))
            flange.geometry?.materials = [wood]
            flange.position.y = y
            body.addChildNode(flange)
        }

        // Eye on a stalk, sprouting from the top flange.
        let stalk = SCNNode()
        stalk.name = "bobbinStalk"
        stalk.position.y = spoolHeight / 2 + 0.012
        body.addChildNode(stalk)
        let rod = SCNNode(geometry: SCNCylinder(radius: 0.006, height: 0.12))
        rod.geometry?.materials = [wire]
        rod.position.y = 0.06
        stalk.addChildNode(rod)
        let eye = SCNNode(geometry: SCNSphere(radius: 0.045))
        eye.geometry?.materials = [eyeWhite]
        eye.position.y = 0.14
        stalk.addChildNode(eye)
        let dot = SCNNode(geometry: SCNSphere(radius: 0.02))
        dot.geometry?.materials = [pupil]
        dot.position = SCNVector3(0, 0, -0.035)
        eye.addChildNode(dot)

        // Two wire legs from the bottom flange, with orange ball shoes.
        for (i, side) in [Float(-1), 1].enumerated() {
            let hip = SCNNode()
            hip.name = "bobbinLeg\(i)"
            hip.position = SCNVector3(side * 0.045, -spoolHeight / 2 - 0.012, 0)
            body.addChildNode(hip)
            let leg = SCNNode(geometry: SCNCylinder(radius: 0.005, height: CGFloat(legLength - 0.02)))
            leg.geometry?.materials = [wire]
            leg.position.y = -(legLength - 0.02) / 2
            hip.addChildNode(leg)
            let foot = SCNNode(geometry: SCNSphere(radius: 0.022))
            foot.geometry?.materials = [shoe]
            foot.scale = SCNVector3(1, 0.6, 1.4)
            foot.position = SCNVector3(0, -(legLength - 0.02) - 0.005, -0.01)
            hip.addChildNode(foot)
        }

        root.enumerateHierarchy { node, _ in node.categoryBitMask = Bobbin.categoryBit }
        return root
    }

    private static func shadowImage() -> UIImage {
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

/// Habitat pass: just "who else is on this floor" -- weak references, so the
/// Bobbins' own actions stay their only owners.
nonisolated final class BobbinFlock: @unchecked Sendable {
    private struct Entry { weak var driver: BobbinDriver? }
    private var entries: [Entry] = []
    func add(_ driver: BobbinDriver) { entries.append(Entry(driver: driver)) }
    var members: [BobbinDriver] { entries.compactMap(\.driver) }
}
