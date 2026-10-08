import SceneKit
import AVFAudio
import QuartzCore
import simd

/// Oct 5 (critter audio as a proximity sense). Every critter sound is a
/// positional SCNAudioSource played on the critter's own node; this sets the
/// view's shared 3D attenuation so those voices fade smoothly to SILENCE with
/// distance (they used to fade only slightly and never reach zero), and keeps
/// critters outside the elevator cab inaudible while the player is inside it.
/// Oct 5 (walls): on top of the distance fade, the floor's logical grid
/// decides whether player and critter are acoustically CONNECTED (a short
/// walk through open cells joins them -- straight hall, around a corner,
/// through an opening) or SEPARATED by solid building (one solid band between
/// them: strongly attenuated; two or more: silent).
/// Purely cosmetic: nothing in movement, capture, missions or navigation
/// reads it. Non-critter game audio is non-positional and unaffected.
nonisolated enum CritterAudio {
    /// Full intended volume within this distance (metres)...
    static let fullVolumeDistance: Float = 1.2
    /// ...fading smoothly (linear gain) to silence here -- about three
    /// hallway cells (cellSize 3.52 m).
    static let silentDistance: Float = 11.0
    /// Gain applied on top of the distance fade when ONE solid band of
    /// building separates player and critter (about -14 dB).
    static let oneWallGain: Float = 0.2
    /// A critter whose walking route (in cells) is at most this much longer
    /// than the straight grid route counts as connected -- around a corner
    /// costs nothing extra; a short jog through an opening costs a little.
    static let connectedDetourCells = 2

    private struct Cab {
        let door: SIMD2<Float>      // doorway centre (closed-door plane), x/z
        let inward: SIMD2<Float>    // unit, from the doorway into the cab
        let depth: Float
        let halfWidth: Float
        func contains(_ p: SIMD3<Float>) -> Bool {
            let v = SIMD2<Float>(p.x, p.z) - door
            let along = simd_dot(v, inward)
            let across = abs(v.x * inward.y - v.y * inward.x)
            return along > 0.05 && along < depth + 0.3 && across < halfWidth + 0.2
        }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        weak var listener: SCNNode?
        var cab: Cab?
        var cells: Set<Int64> = []          // walkable grid cells (row/col keys)
        var cellSize: Float = 3.52
        var hallwayCell: (row: Int, col: Int) = (0, 0)
        var lastPlayLine: CFTimeInterval = 0
        var suppressed = false
        // TEMP diagnostics (Oct 5 silence investigation): outcome counts,
        // reported at most every 2 s with the latest sample.
        var counts: [String: Int] = [:]
        var lastReport: CFTimeInterval = 0
    }
    /// TEMP (Oct 5 fade test): quantize the fade into four unmistakable
    /// levels -- full / half / quarter / very faint -- so the physical test
    /// can prove per-sound volume is honoured. Same 11 m cutoff. Set false
    /// for the smooth continuous fade.
    static let obviousFadeSteps = true
    static func key(_ row: Int, _ col: Int) -> Int64 { Int64(row) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: col))) }
    private static let state = State()

    /// Oct 5 (clean onboarding): while true, NO critter sound plays at all --
    /// set while the opening (building exterior) screen is up, so the live
    /// lobby behind it can never be heard outside. Thread-safe.
    static func setSuppressed(_ suppressed: Bool, reason: String) {
        state.lock.lock()
        let changed = state.suppressed != suppressed
        state.suppressed = suppressed
        state.lock.unlock()
        if changed { diag("critterAudio.suppressed", ["suppressed": suppressed, "reason": reason]) }
    }

    /// Called on every floor install, once the floor's camera is the view's
    /// point of view (the audio listener). `doors` are the cab's doors at
    /// their built (closed) positions; `hallwayCell` is the elevator's
    /// hallway cell centre, used only to tell which side of the doors the
    /// cab is on.
    @MainActor
    static func beginFloor(view: SCNView, listener: SCNNode,
                           doors: (left: SCNNode, right: SCNNode)?, hallwayCell: SIMD2<Float>, cellSize: CGFloat,
                           walkableCells: [(row: Int, col: Int)]) {
        // Oct 5 (silence fix): the environment's own .linear curve left every
        // critter silent on device. The environment is back on the model the
        // old (audible) setup used -- .inverse -- but with its reference
        // distance at silentDistance, so it applies NO attenuation inside the
        // audible range (it still pans left/right). The 1.2 m -> 11 m linear
        // fade is applied per sound in play() instead (fadeGain).
        let attenuation = view.audioEnvironmentNode.distanceAttenuationParameters
        attenuation.distanceAttenuationModel = .inverse
        attenuation.referenceDistance = silentDistance
        attenuation.maximumDistance = 40
        attenuation.rolloffFactor = 1

        var cab: Cab?
        if let doors {
            let l = doors.left.worldPosition, r = doors.right.worldPosition
            let door = SIMD2<Float>((l.x + r.x) / 2, (l.z + r.z) / 2)
            let along = SIMD2<Float>(r.x - l.x, r.z - l.z)
            if simd_length(along) > 0.001 {
                var inward = simd_normalize(SIMD2<Float>(-along.y, along.x))
                if simd_dot(door - hallwayCell, inward) < 0 { inward = -inward }   // away from the hallway
                let size = Float(HallwayScene.ElevatorGeometry(cellSize: cellSize).cabDepth)
                cab = Cab(door: door, inward: inward, depth: size, halfWidth: size / 2)
            }
        }
        let size = Float(cellSize)
        let cellKeys = Set(walkableCells.map { key($0.row, $0.col) })
        let hallway = (row: Int((hallwayCell.y / size).rounded()), col: Int((hallwayCell.x / size).rounded()))
        state.lock.lock()
        state.listener = listener
        state.cab = cab
        state.cells = cellKeys
        state.cellSize = size
        state.hallwayCell = hallway
        state.lock.unlock()
    }

    private enum Separation { case connected, oneWall, walls }

    /// Grid-level acoustic separation between two cells. Connected when a
    /// walk through walkable cells joins them within the straight grid route
    /// plus connectedDetourCells (straight hall, corner, opening). Otherwise
    /// the straight line between the cell centres is sampled and the solid
    /// (non-walkable) bands it crosses are counted.
    private static func separation(from a: (row: Int, col: Int), to b: (row: Int, col: Int),
                                   cells: Set<Int64>) -> Separation {
        if a == b { return .connected }
        let manhattan = abs(a.row - b.row) + abs(a.col - b.col)
        let limit = manhattan + connectedDetourCells
        if cells.contains(key(a.row, a.col)), cells.contains(key(b.row, b.col)) {
            var seen: Set<Int64> = [key(a.row, a.col)]
            var frontier = [(a.row, a.col)]
            var depth = 0
            let target = key(b.row, b.col)
            while !frontier.isEmpty, depth < limit {
                depth += 1
                var next: [(Int, Int)] = []
                for (r, c) in frontier {
                    for (dr, dc) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let n = key(r + dr, c + dc)
                        guard cells.contains(n), !seen.contains(n) else { continue }
                        if n == target { return .connected }
                        seen.insert(n)
                        next.append((r + dr, c + dc))
                    }
                }
                frontier = next
            }
        }
        // Not joined by a short walk: count solid bands on the straight line.
        let steps = max(1, manhattan * 4)
        var bands = 0
        var inSolid = false
        for i in 1..<steps {
            let t = Float(i) / Float(steps)
            let r = Int((Float(a.row) + Float(b.row - a.row) * t).rounded())
            let c = Int((Float(a.col) + Float(b.col - a.col) * t).rounded())
            let solid = !cells.contains(key(r, c))
            if solid && !inSolid { bands += 1 }
            inSolid = solid
        }
        return bands <= 1 ? .oneWall : .walls
    }

    /// The one way a critter voices a sound: elevator rule, then the
    /// distance fade (full <= fullVolumeDistance, linear to silence at
    /// silentDistance), then wall separation; the result plays on the
    /// critter's own node (positional: left/right still from SceneKit).
    static func play(_ source: SCNAudioSource, on node: SCNNode) {
        state.lock.lock()
        let listener = state.listener
        let cab = state.cab
        let cells = state.cells
        let size = state.cellSize
        let hallway = state.hallwayCell
        let suppressed = state.suppressed
        state.lock.unlock()
        if suppressed { report("SUPPRESSED_OPENING", ["critter": node.name ?? "?"]); return }
        guard let listener else {
            report("PLAY", ["why": "no listener yet", "gain": 1.0])
            node.runAction(.playAudio(source, waitForCompletion: false))
            return
        }
        let e = listener.presentation.worldPosition, m = node.presentation.worldPosition
        let ear = SIMD3<Float>(e.x, e.y, e.z), me = SIMD3<Float>(m.x, m.y, m.z)
        let distance = simd_distance(SIMD2<Float>(ear.x, ear.z), SIMD2<Float>(me.x, me.z))
        let earInCab = cab?.contains(ear) ?? false
        let meInCab = cab?.contains(me) ?? false
        func cell(_ p: SIMD3<Float>, inCab: Bool) -> (row: Int, col: Int) {
            inCab ? hallway : (row: Int((p.z / size).rounded()), col: Int((p.x / size).rounded()))
        }
        let earCell = cell(ear, inCab: earInCab), meCell = cell(me, inCab: meInCab)
        func sample(_ gain: Float) -> KeyValuePairs<String, Any?> {
            ["distance": Double(distance), "gain": Double(gain), "earCell": "\(earCell.row),\(earCell.col)",
             "critterCell": "\(meCell.row),\(meCell.col)", "earInCab": earInCab, "critterInCab": meInCab,
             "sourceVolume": Double(source.volume), "positional": source.isPositional,
             "earWalkable": cells.contains(key(earCell.row, earCell.col)),
             "critterWalkable": cells.contains(key(meCell.row, meCell.col))]
        }
        // Elevator rule: inside the cab, only critters in the cab are heard.
        if earInCab && !meInCab { report("SUPPRESSED_ELEVATOR", sample(0)); return }
        // Distance fade.
        guard distance < silentDistance else { report("SUPPRESSED_DISTANCE", sample(0)); return }
        let desired = fadeGain(distance)
        let level = obviousFadeSteps ? obviousLevel(desired) : desired
        // Wall separation.
        var wallFactor: Float = 1
        if !cells.isEmpty, !(earInCab && meInCab) {
            switch separation(from: earCell, to: meCell, cells: cells) {
            case .connected: break
            case .oneWall: wallFactor = oneWallGain
            case .walls: report("SUPPRESSED_WALLS", sample(0)); return
            }
        }
        let gain = level * wallFactor
        guard node.parent != nil else { report("FAILED_TO_PLAY", sample(gain)); return }
        // Oct 5 (fade fix): the volume is set on THIS sound's own player --
        // its AVAudio mixer input in the 3D environment -- rather than via a
        // copied SCNAudioSource whose `volume` the device did not honour
        // (loud -> loud -> loud -> off). The source itself is untouched.
        let player = SCNAudioPlayer(source: source)
        player.willStartPlayback = { [weak player] in
            (player?.audioNode as? AVAudioMixing)?.volume = gain
        }
        player.didFinishPlayback = { [weak node, weak player] in
            guard let player else { return }
            DispatchQueue.main.async { node?.removeAudioPlayer(player) }
        }
        (player.audioNode as? AVAudioMixing)?.volume = gain
        node.addAudioPlayer(player)
        let mixer = player.audioNode as? AVAudioMixing
        mixer?.volume = gain
        playLine(distance: distance, desired: desired, level: level, wallFactor: wallFactor, gain: gain,
                 sourceVolume: source.volume, appliedVolume: mixer?.volume, critter: node.name ?? "?")
        report("PLAY", sample(gain))
    }

    /// TEMP: full / half / quarter / very faint (proves volume is honoured).
    static func obviousLevel(_ desired: Float) -> Float {
        switch desired {
        case 0.75...: return 1
        case 0.5..<0.75: return 0.5
        case 0.25..<0.5: return 0.25
        default: return 0.08
        }
    }

    /// TEMP diagnostics: one concise line per played critter sound (at most
    /// ~4 a second) proving the fade: distance -> desired gain -> level ->
    /// wall factor -> the volume actually applied on the playing node.
    private static func playLine(distance: Float, desired: Float, level: Float, wallFactor: Float, gain: Float,
                                 sourceVolume: Float, appliedVolume: Float?, critter: String) {
        let now = CACurrentMediaTime()
        state.lock.lock()
        let due = now - state.lastPlayLine >= 0.25
        if due { state.lastPlayLine = now }
        state.lock.unlock()
        guard due else { return }
        diag("critterAudio.play", ["critter": critter,
                                   "distance": String(format: "%.2f", distance),
                                   "desiredGain": String(format: "%.2f", desired),
                                   "selectedLevel": String(format: "%.2f", level),
                                   "wallFactor": String(format: "%.2f", wallFactor),
                                   "finalGain": String(format: "%.2f", gain),
                                   "sourceVolume": String(format: "%.2f", sourceVolume),
                                   "playerMixerVolume": appliedVolume.map { String(format: "%.2f", $0) } ?? "NO_AUDIO_NODE",
                                   "outcome": "PLAY"])
    }

    /// Linear in gain: 1 up to fullVolumeDistance, 0 at silentDistance.
    static func fadeGain(_ distance: Float) -> Float {
        let t = (distance - fullVolumeDistance) / (silentDistance - fullVolumeDistance)
        return min(1, max(0, 1 - t))
    }

    /// TEMP diagnostics: counts every outcome; logs a summary (with the
    /// latest sample) at most every 2 s. Remove once confirmed on device.
    private static func report(_ outcome: String, _ fields: KeyValuePairs<String, Any?>) {
        let now = CACurrentMediaTime()
        state.lock.lock()
        state.counts[outcome, default: 0] += 1
        let due = now - state.lastReport >= 2
        var summary = ""
        if due {
            state.lastReport = now
            summary = state.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            state.counts = [:]
        }
        state.lock.unlock()
        guard due else { return }
        diag("critterAudio.summary", ["counts": summary, "latest": outcome])
        diag("critterAudio.\(outcome)", fields)
    }
}
