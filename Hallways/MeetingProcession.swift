import SceneKit
import UIKit
import simd

/// Oct 11 -- EPISODE 3: THE STAFF-MEETING PROCESSION (Floor 3).
///
/// The building's first little rush hour. Once the staff-meeting invitation
/// has gone out (and Mr. Tinky's onboarding is over), the first time the
/// player opens their office door two of the building's own objects are
/// already in the corridor, heading for the Conference Room on purpose --
/// not wandering:
///
///   the Chair  (worrier)  scurries ahead, bouncing, fretting in bursts --
///                         late again; it gets there first.
///   the Stalk  (beckoner) a desk lamp, nearest the player: when the player
///                         falls behind it turns back, bobs and calls
///                         ("you coming?") -- then goes on. It waits for at
///                         most `beckonLimit` seconds in all; it never blocks
///                         and never forces anyone to follow.
///
/// HALLENESE ONLY: no words, captions or balloons -- voices (synthesised
/// here), hops, looks and pace. At the Conference Room each critter pushes
/// the glass doors open, walks in and takes its place AT the table (Oct 11:
/// the west side of ConferenceMeeting's layout); the doors close behind them.
/// (Oct 19, Stage A: the Clacker, once the third walker, is retired.)
/// From then on each is one of the
/// meeting's attendees (MeetingAttendee: chatting, settling, listening),
/// heard (muffled by the closed doors, CritterAudio) only near the room.
/// They stay there. The meeting itself is ConferenceMeeting's.
///
/// STORY STATE: `doneBeat` (StoryBeats, persisted) is recorded once all of
/// them are inside. Interrupted (the player left the floor or quit midway) -> it
/// plays again the next time the office door opens. Done -> never again; the
/// room is simply occupied on every later build. A player who reaches the
/// room by another way before it ever played finds them already inside (and
/// that counts as done). No timers, locks or forced moves.
///
/// Reuses the Menagerie bodies, gaits and travel (Critter.errand / beginErrand
/// / freePoint / lift -- the only additions there) and the controller's own
/// character door open/close. Nothing else is touched.
enum MeetingProcession {
    static let doneBeat = "meeting.staff1.procession.done"
    static let floor = ConferenceRoom.floor
    /// The alcove whose east wall holds the glass doors.
    static let doorCell = ConferenceRoom.doorCell
    /// The middle corridor on either side of the room's alcove, one step
    /// short of seeing the glass doors: coming this way while the procession
    /// has never finished (interrupted, or never set off) seats them inside
    /// before the doors come into view -- they got there first.
    static let approachCells: Set<GridCoordinate> = [
        GridCoordinate(row: 4, col: 7), GridCoordinate(row: 5, col: 7), GridCoordinate(row: 7, col: 7), GridCoordinate(row: 8, col: 7),
    ]
    /// Standing here when the floor is built (e.g. a resume): seated at once.
    static let nearRoomCells: Set<GridCoordinate> = approachCells
        .union(ConferenceRoom.roomCells)
        .union([GridCoordinate(row: 6, col: 7), ConferenceRoom.doorCell])

    struct Hooks {
        var openDoor: (GridCoordinate) -> Void
        var closeDoor: (GridCoordinate) -> Void
        var isDoorOpen: (GridCoordinate) -> Bool
        var playerCell: () -> GridCoordinate?
    }

    /// Invitation out, onboarding over: the commute is on.
    static var isDue: Bool { Admission.isPrologueCompleted && StoryBeats.shared.has(BuildingDispatch.staffMeetingInvitedBeat) }
    static var isDone: Bool { StoryBeats.shared.has(doneBeat) }

    private static weak var scene: SCNScene?
    private static var habitat: Habitat?
    private static var hooks: Hooks?
    private static var cellSize: Float = 3.52
    private static var generation = 0
    private static var errands: [MeetingErrand] = []
    private static var running = false
    private static var lastPlayerCell: GridCoordinate?

    // MARK: Floor lifecycle (ContentView)

    static func installFloor(scene: SCNScene, playerCamera: SCNNode, cells: Set<GridCoordinate>, cellSize: Float,
                             doors: [GridCoordinate: Direction], hooks: Hooks) {
        generation += 1
        errands = []
        running = false
        lastPlayerCell = hooks.playerCell()
        self.scene = scene
        self.hooks = hooks
        self.cellSize = cellSize
        habitat = nil
        guard ConferenceRoom.roomCells.isSubset(of: cells), cells.contains(doorCell),
              PlayerOffice.officeCells.isSubset(of: cells) else {
            diag("procession.layoutMismatch", [:])
            ConferenceMeeting.leaveFloor()
            return
        }
        habitat = makeHabitat(scene: scene, playerCamera: playerCamera, cells: cells, cellSize: cellSize, doors: doors)
        // Oct 11 (the staff meeting): the room itself -- screen, projector,
        // the boss and the colleagues already in their places -- before the
        // procession's two are placed or set off (ConferenceMeeting).
        if let habitat {
            ConferenceMeeting.installFloor(scene: scene, habitat: habitat, cellSize: cellSize, playerCell: lastPlayerCell)
        }
        // Oct 11 (late): during the cast audition the room belongs to the
        // cast -- the procession neither sets off nor sits its two in there
        // (its story beat is untouched and resumes when the audition is off).
        guard isDue, !ConferenceAudition.enabled else { return }
        if isDone {
            seatEveryone(record: false)                       // the room is simply occupied
        } else if let cell = lastPlayerCell, nearRoomCells.contains(cell) {
            seatEveryone(record: true)
        }
    }

    /// Any other floor: forget this one (its critters went with its scene).
    static func leaveFloor() {
        generation += 1
        errands = []
        running = false
        habitat = nil
        hooks = nil
        ConferenceMeeting.leaveFloor()
    }

    // MARK: Triggers

    /// The player opened a Room Entrance door. From inside the office: go.
    static func roomDoorOpened(_ coord: GridCoordinate) {
        guard coord == PlayerOffice.doorCell, let cell = hooks?.playerCell(), PlayerOffice.officeCells.contains(cell) else { return }
        start(spawnFar: false)
    }

    static func playerCellChanged(_ cell: GridCoordinate) {
        defer { lastPlayerCell = cell }
        guard isDue, !isDone, !running, habitat != nil, !ConferenceAudition.enabled else { return }
        // Stepping out through an already-open office door: start a little further off.
        if cell == PlayerOffice.doorCell, let last = lastPlayerCell, PlayerOffice.officeCells.contains(last) {
            start(spawnFar: true)
        } else if approachCells.contains(cell) {
            // Got to the room another way before it ever played: they're already in.
            seatEveryone(record: true)
        }
    }

    // MARK: The procession

    private enum Walker { case chair, stalk }

    private static func start(spawnFar: Bool) {
        guard isDue, !isDone, !running, !ConferenceAudition.enabled, let habitat, let scene, hooks != nil else { return }
        running = true
        MeetingErrand.prepareSounds()
        // Ahead of the player, up the office corridor (col 12), nearest last.
        let spots: [(Walker, MeetingErrand.Role, GridCoordinate, Float)] = spawnFar
            ? [(.chair, .worrier, GridCoordinate(row: 3, col: 11), 1.9),
               (.stalk, .beckoner, GridCoordinate(row: 4, col: 12), 1.3)]
            : [(.chair, .worrier, GridCoordinate(row: 3, col: 12), 1.9),
               (.stalk, .beckoner, GridCoordinate(row: 5, col: 12), 1.3)]
        for (cast, role, cell, cruise) in spots {
            add(cast, role: role, at: cell, cruise: cruise, seated: false, habitat: habitat, scene: scene)
        }
        diag("procession.start", ["spawnFar": spawnFar, "critters": errands.count])
    }

    /// Everyone already in their places (a later build, or found there first).
    private static func seatEveryone(record: Bool) {
        guard let habitat, let scene, errands.isEmpty else { return }
        MeetingErrand.prepareSounds()
        add(.chair, role: .worrier, at: ConferenceRoom.entryCell, cruise: 0, seated: true, habitat: habitat, scene: scene)
        add(.stalk, role: .beckoner, at: ConferenceRoom.entryCell, cruise: 0, seated: true, habitat: habitat, scene: scene)
        if record { complete(reason: "foundAlreadyInside") }
        diag("procession.seated", ["record": record])
    }

    private static func add(_ cast: Walker, role: MeetingErrand.Role, at cell: GridCoordinate, cruise: Float, seated: Bool,
                            habitat: Habitat, scene: SCNScene) {
        let key = HabitatGraph.key(row: cell.row, col: cell.col)
        let shadow = Menagerie.shadowImage()
        let made: (Critter, SCNNode)
        switch cast {
        case .chair: made = Chair.make(habitat: habitat, cell: key, shadow: shadow)
        case .stalk: made = Stalk.make(habitat: habitat, cell: key, shadow: shadow)
        }
        let (critter, node) = made
        let s = cellSize
        func at(_ row: Float, _ col: Float) -> SIMD2<Float> { SIMD2<Float>(col * s, row * s) }
        // Oct 11 (the staff meeting): their places are AT the conference
        // table (ConferenceMeeting's layout): the Stalk stands at the
        // south-west place, the Chair takes the foot. Once there they are attendees like
        // the rest (MeetingAttendee) and follow the meeting's script.
        let layout = ConferenceMeeting.layout ?? MeetingLayout(cellSize: s)
        let place: MeetingPlace
        let seed: Int
        switch role {
        case .beckoner: place = layout.place(4); seed = 2          // the Stalk stands in place 4
        case .worrier: place = layout.place(7); seed = 4           // the Chair takes the foot of the table
        case .walker: place = layout.place(0); seed = 0            // (no walker since the Clacker retired, Oct 19)
        }
        let attendee = MeetingAttendee(place: place, layout: layout, mood: ConferenceMeeting.mood,
                                       pose: ConferenceMeeting.addPose(to: critter), seed: seed)
        let errand = MeetingErrand(role: role, generation: generation,
                                   goalCell: HabitatGraph.key(row: doorCell.row, col: doorCell.col),
                                   doorPoint: at(Float(doorCell.row), Float(doorCell.col)),
                                   insidePoint: at(Float(ConferenceRoom.entryCell.row), Float(ConferenceRoom.entryCell.col)) + SIMD2<Float>(-0.7, 0),
                                   place: place, attendee: attendee, cruise: cruise, seated: seated)
        if seated {
            critter.pos = place.spot
            critter.freePoint = place.spot
            critter.lift = place.height
            critter.heading = atan2(-(place.facing.x - place.spot.x), -(place.facing.y - place.spot.y))
            critter.errand = errand
        } else {
            critter.heading = 0                                    // facing up the corridor (north)
            critter.beginErrand(errand, toward: errand.goalCell)
        }
        node.position = SCNVector3(critter.pos.x, critter.lift, critter.pos.y)
        node.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }
        scene.rootNode.addChildNode(node)
        habitat.add(critter)
        node.runAction(.repeatForever(critter.tickAction()), forKey: "critterTick")
        errands.append(errand)
    }

    // MARK: At the doors (from the critters' ticks, hopped to main)

    static func arrivedAtDoor(_ errand: MeetingErrand) {
        guard errand.generation == generation, let hooks else { return }
        diag("procession.atDoor", ["role": errand.role.rawValue])
        if hooks.isDoorOpen(doorCell) { errand.doorOpen = true; return }
        hooks.openDoor(doorCell)
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard gen == generation else { return }
            errand.doorOpen = true
        }
    }

    static func tookPlace(_ errand: MeetingErrand) {
        guard errand.generation == generation else { return }
        diag("procession.inside", ["role": errand.role.rawValue])
        if errands.allSatisfy({ $0.currentPhase == .seated }) { complete(reason: "allInside") }
        // The doors close behind them once nobody else is coming through
        // (never on the player standing in the doorway).
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard gen == generation, let hooks,
                  !errands.contains(where: { $0.currentPhase == .atDoor || $0.currentPhase == .entering }) else { return }
            if let p = hooks.playerCell(), p == doorCell || p == ConferenceRoom.entryCell { return }
            if hooks.isDoorOpen(doorCell) { hooks.closeDoor(doorCell) }
        }
    }

    private static func complete(reason: String) {
        running = false
        if StoryBeats.shared.record(doneBeat, at: Date()) {
            diag("procession.done", ["reason": reason])
        }
    }

    // MARK: The floor as the critters see it (same graph Menagerie builds)

    private static func makeHabitat(scene: SCNScene, playerCamera: SCNNode, cells: Set<GridCoordinate>, cellSize: Float,
                                    doors: [GridCoordinate: Direction]) -> Habitat {
        func key(_ c: GridCoordinate) -> Int { HabitatGraph.key(row: c.row, col: c.col) }
        func edge(_ a: Int, _ b: Int) -> Int64 { Int64(min(a, b)) << 32 | Int64(max(a, b)) }
        var blocked = Set<Int64>()
        for (coord, direction) in doors {
            blocked.insert(edge(key(coord), key(GridCoordinate(row: coord.row + direction.delta.row, col: coord.col + direction.delta.col))))
        }
        var neighbors: [Int: [Int]] = [:]
        var centers: [Int: SIMD2<Float>] = [:]
        for c in cells {
            centers[key(c)] = SIMD2<Float>(Float(c.col) * cellSize, Float(c.row) * cellSize)
            neighbors[key(c)] = Direction.allCases.compactMap { d in
                let n = GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
                guard cells.contains(n), !blocked.contains(edge(key(c), key(n))) else { return nil }
                return key(n)
            }
        }
        let graph = HabitatGraph(neighbors: neighbors, centers: centers, cellSize: cellSize, lit: [])
        return Habitat(graph: graph, root: scene.rootNode, playerCamera: playerCamera)
    }
}

// MARK: - One critter's errand (runs in its own tick)

nonisolated final class MeetingErrand: CritterErrand, @unchecked Sendable {
    enum Role: String { case beckoner, worrier, walker }
    enum Phase: String { case walking, beckoning, atDoor, entering, seated }

    /// The beckoner waits for the player this long in all, then goes on.
    static let beckonLimit: Double = 30
    /// It turns back when the player is farther than this...
    static let waitFar: Float = 7.5
    /// ...and walks on once they are within this.
    static let waitNear: Float = 4.5

    let role: Role
    let generation: Int
    let goalCell: Int
    let doorPoint: SIMD2<Float>
    let insidePoint: SIMD2<Float>
    /// Oct 11: its place at the conference table, and its life there.
    let place: MeetingPlace
    let attendee: MeetingAttendee
    let cruise: Float
    /// Hopping up onto a chair seat or the table top (seconds).
    static let climbTime: Double = 0.5
    private var climb: Double = -1

    private let lock = NSLock()
    private var _phase: Phase
    private var _doorOpen = false
    var currentPhase: Phase { lock.withLock { _phase } }
    var doorOpen: Bool {
        get { lock.withLock { _doorOpen } }
        set { lock.withLock { _doorOpen = newValue } }
    }

    private var clock: Double = 0
    private var nextVoice: Double
    private var beckoned: Double = 0
    private var askedDoor = false
    private var toSeat = false
    private var hopStart: Double = -10
    private var hopLength: Double = 0.5
    private var hopCount: Double = 2
    private var hopHeight: Float = 0.06

    init(role: Role, generation: Int, goalCell: Int, doorPoint: SIMD2<Float>, insidePoint: SIMD2<Float>,
         place: MeetingPlace, attendee: MeetingAttendee, cruise: Float, seated: Bool) {
        self.role = role
        self.generation = generation
        self.goalCell = goalCell
        self.doorPoint = doorPoint
        self.insidePoint = insidePoint
        self.place = place
        self.attendee = attendee
        self.cruise = cruise
        _phase = seated ? .seated : .walking
        nextVoice = Double.random(in: 0.4...1.6)
    }

    private func setPhase(_ p: Phase) { lock.withLock { _phase = p } }

    override func step(_ c: Critter, dt: Double, now: CFTimeInterval) {
        clock += dt
        let player: SIMD2<Float>? = c.habitat.playerCamera.map {
            let p = $0.presentation.worldPosition
            return SIMD2<Float>(p.x, p.z)
        }
        var bounce: Float = 0
        var perch: Float = 0
        switch currentPhase {
        case .walking:
            c.freePoint = nil
            c.goal = goalCell
            c.lookAt = nil
            c.wantSpeed = cruise
            if role == .worrier {
                bounce = abs(sin(Float(clock) * 13)) * 0.03          // a fretful scurry
                if clock >= nextVoice {
                    c.say(Self.fluster, loud: false)
                    hop(count: 3, length: 0.42, height: 0.05)
                    nextVoice = clock + Double.random(in: 1.8...3.2)
                }
            }
            if role == .beckoner, beckoned < Self.beckonLimit, let p = player, simd_length(p - c.pos) > Self.waitFar {
                setPhase(.beckoning)
                nextVoice = clock + 0.35
            }
            if c.from == goalCell {
                setPhase(.atDoor)
                c.goal = nil
            }
        case .beckoning:
            c.wantSpeed = 0
            c.freePoint = nil
            c.lookAt = player
            beckoned += dt
            if clock >= nextVoice {
                c.say(Self.beckon, loud: false)
                hop(count: 2, length: 0.5, height: 0.07)
                nextVoice = clock + 2.8
            }
            let near = player.map { simd_length($0 - c.pos) < Self.waitNear } ?? true
            if near || beckoned >= Self.beckonLimit { setPhase(.walking) }
        case .atDoor:
            c.freePoint = doorPoint
            c.wantSpeed = 0.6
            c.lookAt = doorPoint + SIMD2<Float>(1, 0)                 // the doors, east
            if !askedDoor {
                askedDoor = true
                Task { @MainActor in MeetingProcession.arrivedAtDoor(self) }
            }
            if doorOpen {
                setPhase(.entering)
                toSeat = false
                c.freePoint = insidePoint
            }
        case .entering:
            c.wantSpeed = 0.95
            c.lookAt = nil
            if climb >= 0 {
                // Up onto its perch: one hop from beside its chair.
                climb += dt
                let u = Float(min(1, climb / Self.climbTime))
                let e = u * u * (3 - 2 * u)
                let p = place.approach + (place.spot - place.approach) * e
                c.pos = p
                c.freePoint = p
                perch = place.height * e + 0.22 * sin(.pi * u)
                if u >= 1 {
                    c.freePoint = place.spot
                    took()
                }
            } else if !toSeat {
                c.freePoint = insidePoint
                if simd_length(insidePoint - c.pos) < 0.15 { toSeat = true }
            } else {
                c.freePoint = place.approach
                if simd_length(place.approach - c.pos) < 0.08 {
                    if place.height > 0.01 {
                        climb = 0
                        c.say(Self.scrape, loud: false)
                    } else {
                        took()
                    }
                }
            }
        case .seated:
            // Oct 11: in its place at the meeting -- one of the attendees.
            c.lift = attendee.step(c, dt: dt)
            return
        }
        c.lift = perch + bounce + hopLift()
    }

    private func took() {
        setPhase(.seated)
        Task { @MainActor in MeetingProcession.tookPlace(self) }
    }

    private func hop(count: Double, length: Double, height: Float) {
        hopStart = clock
        hopCount = count
        hopLength = length
        hopHeight = height
    }

    private func hopLift() -> Float {
        let t = clock - hopStart
        guard t >= 0, t < hopLength else { return 0 }
        return hopHeight * abs(sin(Float(.pi * hopCount * t / hopLength)))
    }

    // MARK: Hallenese (synthesised, like every critter voice)

    static func prepareSounds() { _ = (beckon, fluster, laugh, scrape, murmurs) }

    /// "Mm-HM?" -- a rising two-note call: you coming?
    static let beckon: SCNAudioSource? = MenagerieSound.source("mtg-beckon", volume: 0.9) {
        MenagerieSound.mix([(at: 0, samples: MenagerieSound.sweep(470, 700, seconds: 0.17, wobble: 0.3), gain: 0.8),
                            (at: 0.24, samples: MenagerieSound.sweep(600, 1020, seconds: 0.24, wobble: 0.3, curve: 0.7), gain: 1)])
    }

    /// A tumbling, worried stutter -- late again!
    static let fluster: SCNAudioSource? = MenagerieSound.source("mtg-fluster", volume: 0.75) {
        var rng = MenagerieSound.Rand(seed: 1101)
        var parts: [(at: Float, samples: [Float], gain: Float)] = []
        for i in 0..<6 {
            let f = 980 - Float(i) * 70 + rng.range(-25, 25)
            parts.append((at: Float(i) * 0.068, samples: MenagerieSound.sweep(f, f * 0.82, seconds: 0.055, wobble: 0.5), gain: 1))
        }
        return MenagerieSound.mix(parts)
    }

    /// A little "heh-heh-heh".
    static let laugh: SCNAudioSource? = MenagerieSound.source("mtg-laugh", volume: 0.5) {
        var parts: [(at: Float, samples: [Float], gain: Float)] = []
        for i in 0..<4 {
            let f = 430 - Float(i) * 22
            parts.append((at: Float(i) * 0.15, samples: MenagerieSound.sweep(f, f * 0.78, seconds: 0.09, wobble: 0.8), gain: 1 - Float(i) * 0.15))
        }
        return MenagerieSound.mix(parts)
    }

    /// A chair shifting on the floor.
    static let scrape: SCNAudioSource? = MenagerieSound.source("mtg-scrape", volume: 0.4) {
        var rng = MenagerieSound.Rand(seed: 1103)
        return MenagerieSound.creak(resonance: 760, q: 5, startHz: 85, endHz: 35, seconds: 0.45, rng: &rng)
    }

    /// Low, friendly babble -- several takes.
    static let murmurs: [SCNAudioSource] = MenagerieSound.variants("mtg-murmur", count: 5, volume: 0.35) { rng in
        var parts: [(at: Float, samples: [Float], gain: Float)] = []
        var t: Float = 0
        for _ in 0..<Int(rng.range(4, 7)) {
            let f = rng.range(170, 310)
            let length = rng.range(0.09, 0.18)
            parts.append((at: t, samples: MenagerieSound.sweep(f, f + rng.range(-45, 45), seconds: length, wobble: 0.6), gain: rng.range(0.6, 1)))
            t += length + rng.range(0.03, 0.09)
        }
        return MenagerieSound.mix(parts)
    }
}
