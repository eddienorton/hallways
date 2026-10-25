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
    /// Oct 18 (audio as a navigation cue): 1.0 m, fading CONTINUOUSLY -- a
    /// curve, steeper close by -- to silence at 16 m (about four and a half
    /// hallway cells): walk toward a sound and it grows all the way, walk
    /// away and it fades all the way. (Was 1.2 -> 11 m, in four quantized steps.)
    static let fullVolumeDistance: Float = 1.0
    static let silentDistance: Float = 16.0
    /// How the fade bends: gain = (1 - t)^fadeCurve. Above 1 makes the last
    /// few metres count most -- what a single iPhone speaker can still convey
    /// when left/right can't.
    static let fadeCurve: Float = 1.6
    /// Gain applied on top of the distance fade when ONE solid band of
    /// building separates player and critter. Oct 18: 0.35 (about -9 dB) --
    /// muffled, still findable (was 0.2).
    static let oneWallGain: Float = 0.35
    /// Two or more bands: very faint, not silent (Oct 18; was silence).
    static let wallsGain: Float = 0.12
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
        /// Oct 9: walkable-to-walkable edges blocked by a CLOSED door (room
        /// entrances: offices, Administration, the conference room).
        var closedDoorEdges: Set<DoorEdge> = []
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
    static let obviousFadeSteps = false          // Oct 18: off -- the smooth fade is the navigation cue
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

    /// Oct 9 (closed doors): an edge between two grid cells, order-free.
    struct DoorEdge: Hashable, Sendable {
        let a: Int64
        let b: Int64
        init(_ r1: Int, _ c1: Int, _ r2: Int, _ c2: Int) {
            let k1 = CritterAudio.key(r1, c1), k2 = CritterAudio.key(r2, c2)
            a = min(k1, k2)
            b = max(k1, k2)
        }
    }

    /// Oct 9: the doors that are shut right now, as (anchor cell, wall it is
    /// in). Pushed by the navigation controller whenever a door opens or
    /// closes, and on every floor install. A closed door between two
    /// otherwise-joined cells now counts as one solid band (oneWallGain):
    /// before this, the separation test only knew walkable cells, so a room
    /// behind a shut door was "connected" and heard at full volume.
    static func setClosedDoors(_ doors: [(row: Int, col: Int, dRow: Int, dCol: Int)]) {
        let edges = Set(doors.map { DoorEdge($0.row, $0.col, $0.row + $0.dRow, $0.col + $0.dCol) })
        state.lock.lock()
        let changed = state.closedDoorEdges != edges
        state.closedDoorEdges = edges
        state.lock.unlock()
        if changed { diag("critterAudio.closedDoors", ["count": edges.count]) }
    }

    /// Grid-level acoustic separation between two cells. Connected when a
    /// walk through walkable cells joins them within the straight grid route
    /// plus connectedDetourCells (straight hall, corner, opening). Otherwise
    /// the straight line between the cell centres is sampled and the solid
    /// (non-walkable) bands it crosses are counted.
    private static func separation(from a: (row: Int, col: Int), to b: (row: Int, col: Int),
                                   cells: Set<Int64>, closedDoors: Set<DoorEdge> = []) -> Separation {
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
                        if !closedDoors.isEmpty, closedDoors.contains(DoorEdge(r, c, r + dr, c + dc)) { continue }
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
        _ = start(source, on: node, scale: 1)
    }

    /// Oct 23 (walking music): `play`, at `scale` of its usual loudness (on its own
    /// player's mixer, like the distance fade), returning that player (nil: not
    /// played -- muted, too far, the cab, off the main thread...) so it can be faded.
    @discardableResult
    static func start(_ source: SCNAudioSource, on node: SCNNode, scale: Float) -> SCNAudioPlayer? {
        // Oct 16 (crash + static investigation): SceneKit audio players are
        // attached AND removed on the main thread only. Critters call this from
        // their tick on SceneKit's render thread; until now the player was
        // attached there while finished players were removed on main
        // (didFinishPlayback below) -- two threads changing the same node's
        // player list, and SceneKit's audio graph, at once.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { _ = start(source, on: node, scale: scale) }
            return nil
        }
        // Isolation switch (testing): `-HallwaysNoCritterAudio YES` -- no critter sound at all.
        if UserDefaults.standard.bool(forKey: "HallwaysNoCritterAudio") || AudioDiagnostics.audioOff { return nil }   // (Oct 24: + audio-off)
        state.lock.lock()
        let listener = state.listener
        let cab = state.cab
        let cells = state.cells
        let size = state.cellSize
        let hallway = state.hallwayCell
        let suppressed = state.suppressed
        let closedDoors = state.closedDoorEdges
        state.lock.unlock()
        if suppressed { report("SUPPRESSED_OPENING", ["critter": node.name ?? "?"]); return nil }
        // Oct 9 (heating): with Mute on (or Settings open) every sound is
        // silent anyway -- don't build, attach and run a positional player
        // into the 3D audio graph just to play it at zero. Audibly identical.
        if HallwaysAudio.shared.isMuted || HallwaysAudio.shared.isSuppressed {
            report("SUPPRESSED_MUTED", ["critter": node.name ?? "?"])
            return nil
        }
        guard let listener else {
            report("PLAY", ["why": "no listener yet", "gain": 1.0])
            // Oct 22 (sound audit): this one path played without reaching the [Sound] lines.
            AudioWatch.heard(critter: AudioWatch.critterName(node), source: source, outcome: "played (no listener yet: unattenuated)",
                             gain: source.volume, distance: 0)
            node.runAction(.playAudio(source, waitForCompletion: false))
            return nil
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
        let who = AudioWatch.critterName(node)
        if earInCab && !meInCab {
            report("SUPPRESSED_ELEVATOR", sample(0))
            AudioWatch.heard(critter: who, source: source, outcome: "silent: you're in the cab", gain: 0, distance: distance)
            return nil
        }
        // Distance fade.
        guard distance < silentDistance else {
            report("SUPPRESSED_DISTANCE", sample(0))
            AudioWatch.heard(critter: who, source: source, outcome: "silent: too far", gain: 0, distance: distance)
            return nil
        }
        let desired = fadeGain(distance)
        let level = obviousFadeSteps ? obviousLevel(desired) : desired
        // Wall separation.
        var wallFactor: Float = 1
        if !cells.isEmpty, !(earInCab && meInCab) {
            switch separation(from: earCell, to: meCell, cells: cells, closedDoors: closedDoors) {
            case .connected: break
            case .oneWall: wallFactor = oneWallGain
            case .walls: wallFactor = wallsGain               // (Oct 18: muffled through the building, not silenced)
            }
        }
        let gain = level * wallFactor * scale          // (Oct 23: `scale` -- a quieter take, e.g. walking music at 50%)
        guard node.parent != nil else { report("FAILED_TO_PLAY", sample(gain)); return nil }
        // Oct 5 (fade fix): the volume is set on THIS sound's own player --
        // its AVAudio mixer input in the 3D environment -- rather than via a
        // copied SCNAudioSource whose `volume` the device did not honour
        // (loud -> loud -> loud -> off). The source itself is untouched.
        let player = SCNAudioPlayer(source: source)
        // Oct 19 (the audio crash): the ledger owns this player from now until
        // well after SceneKit's last callback for it -- see PlayingSounds. The
        // callbacks capture nothing that can be freed under them: the start
        // callback a player the ledger keeps alive, the finish callback a number.
        let id = MainActor.assumeIsolated {
            PlayingSounds.shared.register(PlayingSound(player: player, node: node),
                                          label: "\(who) \(SoundCatalog.name(of: source))",
                                          maxAge: source.loops ? nil : PlayingSounds.oneShotMaxAge,
                                          now: CACurrentMediaTime())
        }
        player.willStartPlayback = { [weak player] in
            (player?.audioNode as? AVAudioMixing)?.volume = gain
        }
        player.didFinishPlayback = {
            // (SceneKit's audio thread: no SceneKit, no objects -- the id goes to the main thread)
            PlayingSounds.finishedOffMain(id)
        }
        (player.audioNode as? AVAudioMixing)?.volume = gain
        node.addAudioPlayer(player)
        MainActor.assumeIsolated { PlayingSounds.scheduleSweep() }      // (Oct 19: retire anything removed under it)
        let mixer = player.audioNode as? AVAudioMixing
        mixer?.volume = gain
        playLine(distance: distance, desired: desired, level: level, wallFactor: wallFactor, gain: gain,
                 sourceVolume: source.volume, appliedVolume: mixer?.volume, critter: node.name ?? "?")
        AudioWatch.heard(critter: who, source: source,
                         outcome: wallFactor == 1 ? "clear" : (wallFactor == oneWallGain ? "through a wall" : "through walls"),
                         gain: gain * source.volume, distance: distance, at: SIMD2<Float>(me.x, me.z))
        report("PLAY", sample(gain))
        return player
    }

    /// Oct 22 (musical building): would a sound from `node` reach the player
    /// in the open -- close enough, the same side of the cab's doors, and joined
    /// by a short walk (not merely near through a wall)? The residents' music
    /// asks before it plays, so nothing is begun just to be muffled by a wall.
    @MainActor
    static func isOpen(to node: SCNNode, within range: Float) -> Bool {
        state.lock.lock()
        let listener = state.listener
        let cab = state.cab
        let cells = state.cells
        let size = state.cellSize
        let closedDoors = state.closedDoorEdges
        state.lock.unlock()
        guard let listener, node.parent != nil else { return false }
        let e = listener.presentation.worldPosition, m = node.presentation.worldPosition
        let ear = SIMD3<Float>(e.x, e.y, e.z), me = SIMD3<Float>(m.x, m.y, m.z)
        guard simd_distance(SIMD2<Float>(ear.x, ear.z), SIMD2<Float>(me.x, me.z)) <= min(range, silentDistance) else { return false }
        let earInCab = cab?.contains(ear) ?? false
        let meInCab = cab?.contains(me) ?? false
        guard earInCab == meInCab else { return false }
        if earInCab || cells.isEmpty { return true }
        func cell(_ p: SIMD3<Float>) -> (row: Int, col: Int) { (row: Int((p.z / size).rounded()), col: Int((p.x / size).rounded())) }
        if case .connected = separation(from: cell(ear), to: cell(me), cells: cells, closedDoors: closedDoors) { return true }
        return false
    }

    // MARK: Oct 9 -- building sounds that aren't critters (the elevator)

    /// A building sound heard from `point` (world): full within
    /// `fullWithin` metres, falling linearly to `floorGain` at
    /// `farDistance` (a building's elevator chime carries -- it never fades
    /// to nothing by distance alone), then the SAME grid separation critters
    /// use, closed doors included: one wall/door 0.2, more 0.1. Returns 1
    /// before any floor has been installed (no listener yet).
    static func buildingGain(at point: SIMD3<Float>, fullWithin: Float = 3.5, farDistance: Float = 20,
                             floorGain: Float = 0.25) -> Float {
        state.lock.lock()
        let listener = state.listener
        let cab = state.cab
        let cells = state.cells
        let size = state.cellSize
        let hallway = state.hallwayCell
        let closedDoors = state.closedDoorEdges
        state.lock.unlock()
        guard let listener else { return 1 }
        let e = listener.presentation.worldPosition
        let ear = SIMD3<Float>(e.x, e.y, e.z)
        let distance = simd_distance(SIMD2<Float>(ear.x, ear.z), SIMD2<Float>(point.x, point.z))
        let t = min(1, max(0, (distance - fullWithin) / max(0.01, farDistance - fullWithin)))
        let distanceGain = 1 - t * (1 - floorGain)
        let earInCab = cab?.contains(ear) ?? false
        let earCell = earInCab ? hallway : (row: Int((ear.z / size).rounded()), col: Int((ear.x / size).rounded()))
        let pointCell = (row: Int((point.z / size).rounded()), col: Int((point.x / size).rounded()))
        var wallFactor: Float = 1
        if !cells.isEmpty {
            switch separation(from: earCell, to: pointCell, cells: cells, closedDoors: closedDoors) {
            case .connected: break
            case .oneWall: wallFactor = oneWallGain
            case .walls: wallFactor = 0.1
            }
        }
        return distanceGain * wallFactor
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
        let t = min(1, max(0, (distance - fullVolumeDistance) / (silentDistance - fullVolumeDistance)))
        return pow(1 - t, fadeCurve)
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

// MARK: - Oct 19 -- who owns a playing critter sound

/// THE AUDIO CRASH (Oct 19: EXC_BAD_ACCESS at 0x10 inside the old
/// didFinishPlayback closure). Before: a critter sound's SCNAudioPlayer was
/// owned ONLY by its node's player list, and its finish callback -- a closure
/// stored IN that player -- ran on SceneKit's audio thread. The main thread
/// freed players whenever a node lost them: a resident body taken down
/// (removeAllAudioPlayers, a floor change, boarding the elevator), a body
/// released, a scene replaced -- and SceneKit fires didFinishPlayback when it
/// stops a player that is removed mid-sound. So the closure could be running
/// on the audio thread while the main thread freed the player that held it,
/// its captured context with it (a closure's first capture sits at offset
/// 0x10 of its context: the faulting address).
///
/// The rules now:
///  - OWNER: this ledger (main thread) holds every critter player strongly
///    from the moment it is made. A node's list is just where it plays.
///  - CALLBACKS: didFinishPlayback captures only an Int; it posts it to the
///    main thread and touches nothing else. willStartPlayback only reaches a
///    player the ledger is keeping alive.
///  - REMOVAL (main thread only, idempotent): when the finish arrives, or a
///    sweep finds the player no longer on its node (someone removed it), its
///    node gone, or a one-shot sound long overdue -- detached if still
///    attached, never twice.
///  - RELEASE: a retired player is kept a further `grace` before the last
///    reference goes, so a callback SceneKit is still delivering can never
///    find it freed. A finish that arrives after retirement is just noted.
///  - COUNTS: AudioHealth's live count is started/retired here, once each.
final class SoundLedger<Item: AnyObject> {
    struct Entry {
        let item: Item
        let label: String
        let started: TimeInterval
        let maxAge: TimeInterval?
    }
    private(set) var live: [Int: Entry] = [:]
    private var graveyard: [(item: Item, id: Int, until: TimeInterval)] = []
    private var retired: [Int] = []                       // (recent, for "finished after retirement")
    private var nextID = 1
    let grace: TimeInterval
    private let detach: (Item) -> Void
    private let isAttached: (Item) -> Bool
    /// (event, id, label, why) -- diagnostics.
    var onEvent: (String, Int, String, String) -> Void = { _, _, _, _ in }

    init(grace: TimeInterval, detach: @escaping (Item) -> Void, isAttached: @escaping (Item) -> Bool) {
        self.grace = grace
        self.detach = detach
        self.isAttached = isAttached
    }

    var liveCount: Int { live.count }
    var holdingCount: Int { live.count + graveyard.count }

    /// A sound starts: the ledger owns it. Its id is what its callbacks carry.
    func register(_ item: Item, label: String, maxAge: TimeInterval?, now: TimeInterval) -> Int {
        let id = nextID
        nextID += 1
        live[id] = Entry(item: item, label: label, started: now, maxAge: maxAge)
        onEvent("created", id, label, "")
        return id
    }

    /// Its finish callback arrived (on the main thread now).
    func finished(_ id: Int, now: TimeInterval) {
        if live[id] != nil {
            retire(id, why: "finished", now: now)
        } else if retired.contains(id) {
            onEvent("finishedAfterRetire", id, "", "callback after the ledger had retired it (harmless: still held)")
        } else {
            onEvent("finishedUnknown", id, "", "no such sound")
        }
        purge(now: now)
    }

    /// Anything taken off its node by someone else, whose node is gone, or a
    /// one-shot long overdue: retired. Then the graveyard past its grace is released.
    func sweep(now: TimeInterval) {
        for (id, e) in live {
            if !isAttached(e.item) {
                retire(id, why: "detachedElsewhere", now: now)
            } else if let age = e.maxAge, now - e.started > age {
                retire(id, why: "overdue", now: now)
            }
        }
        purge(now: now)
    }

    /// Releases what has been retired for longer than `grace`.
    func purge(now: TimeInterval) {
        graveyard.removeAll { g in
            guard g.until <= now else { return false }
            onEvent("released", g.id, "", "")
            return true
        }
    }

    private func retire(_ id: Int, why: String, now: TimeInterval) {
        guard let e = live.removeValue(forKey: id) else { return }
        if isAttached(e.item) { detach(e.item) }
        graveyard.append((e.item, id, now + grace))
        retired.append(id)
        if retired.count > 256 { retired.removeFirst(retired.count - 256) }
        onEvent("retired", id, e.label, why)
    }
}

/// A critter player and the node it plays on (the node is never owned here).
final class PlayingSound {
    let player: SCNAudioPlayer
    weak var node: SCNNode?
    init(player: SCNAudioPlayer, node: SCNNode) {
        self.player = player
        self.node = node
    }
}

/// The game's critter sounds (CritterAudio.play) -- main thread only.
enum PlayingSounds {
    /// A one-shot critter sound is a few seconds at most: past this it is retired anyway.
    static let oneShotMaxAge: TimeInterval = 30
    /// How long a retired player is still held (SceneKit's callbacks for it long over).
    static let grace: TimeInterval = 3

    static let shared: SoundLedger<PlayingSound> = {
        let ledger = SoundLedger<PlayingSound>(grace: grace, detach: { s in
            s.node?.removeAudioPlayer(s.player)
        }, isAttached: { s in
            guard let node = s.node else { return false }
            return node.audioPlayers.contains { $0 === s.player }
        })
        ledger.onEvent = { [unowned ledger] event, id, label, why in
            switch event {
            case "created":
                AudioHealth.shared.critterPlayerStarted()
            case "retired":
                AudioHealth.shared.critterPlayerFinished()
                diag("audio.player.retired", ["id": id, "sound": label, "why": why, "live": ledger.liveCount])
                if why != "finished" {
                    print("[Audio] player \(id) \(label) retired: \(why) (live \(ledger.liveCount), held \(ledger.holdingCount))")
                }
            case "finishedAfterRetire", "finishedUnknown":
                diag("audio.player.\(event)", ["id": id, "note": why])
            default:
                break
            }
        }
        return ledger
    }()

    private static var sweeping = false

    /// From SceneKit's audio thread: the id only, to the main thread.
    nonisolated static func finishedOffMain(_ id: Int) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                shared.finished(id, now: CACurrentMediaTime())
                scheduleSweep()
            }
        }
    }

    /// While anything is held: a sweep every second (cheap: a handful of entries).
    static func scheduleSweep() {
        guard !sweeping, shared.holdingCount > 0 else { return }
        sweeping = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                sweeping = false
                shared.sweep(now: CACurrentMediaTime())
                scheduleSweep()
            }
        }
    }
}

