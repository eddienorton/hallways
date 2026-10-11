//
//  TinCanRat.swift
//  Hallways
//
//  Oct 3 -- TIN CAN RAT, PROTOTYPE 1 (experiment).
//
//  One question: does a small living thing moving through Hallways change
//  how the place feels? Tin Can Rat is a READ-ONLY VISUAL FOLLOWER:
//
//  - He reads the existing player camera's position/heading every frame and
//    never writes to it. Navigation knows nothing about him.
//  - He chases a point a little ahead of the player, on the floor, and is
//    kept out of walls by one segment hit test against the real scene.
//  - A companion camera (a child of the player camera: a bit higher, a bit
//    back, tilted down) is what the view looks through while he's on, so it
//    rides along with every existing movement for free.
//  - Off the grid (inside the elevator cab) the companion camera eases back
//    to the exact first-person pose and he hides; he reappears on exit.
//  - A three-finger tap toggles first-person <-> companion + rat (A/B test),
//    remembered across floors.
//
//  Everything is built from SceneKit primitives and driven by one repeating
//  SCNAction on his own root node -- no renderer-delegate hook, no timers.
//  A new scene is built on every floor change, so he is rebuilt fresh there.
//

import SceneKit
import UIKit
import simd

enum TinCanRat {
    static let enabledKey = "tinCanRat.enabled"
    static let rootName = "tinCanRat"
    static let companionCameraName = "tinCanRatCompanionCamera"
    /// Oct 5: Fred is a character in the world, not the camera. Every install
    /// (floor build, elevator arrival, Administration, relaunch) keeps the
    /// player's first-person camera as the view; the companion camera is
    /// still built and driven (unseen), so flipping this brings it back.
    static let usesCompanionCameraByDefault = false
    /// Category bit for every rat node, so his own segment hit test skips him.
    nonisolated static let categoryBit = CritterCategory.jeff     // 1 << 9

    /// Prototype 1.1: the whole creature, uniformly, at 2x.
    nonisolated static let scale: Float = 2

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Called once per floor build, right after the scene is attached.
    /// `wallThings`: wall-mounted things he may glance at (pictures, maps,
    /// mission boards, mirrors) as (cell, wall direction).
    /// Oct 6 (Cast stage 3): `existingBody` = drive THIS Jeff body (the one
    /// that was performing) instead of building a new one; `held` = start
    /// under a performance hold (TinCanRatDriver.hold/release) -- the driver
    /// moves nothing until released. Returns the body it drives.
    @discardableResult
    static func install(in view: SCNView, scene: SCNScene, playerCamera: SCNNode, cells: Set<GridCoordinate>, cellSize: CGFloat,
                        wallThings: [(GridCoordinate, Direction)] = [], arrivingInsideCab: Bool = false,
                        usesCompanionCamera: Bool = TinCanRat.usesCompanionCameraByDefault, startAt: (position: SIMD2<Float>, heading: Float)? = nil,
                        existingBody: SCNNode? = nil, held: Bool = false) -> SCNNode {
        let companion = SCNNode()
        companion.name = companionCameraName
        companion.camera = (playerCamera.camera?.copy() as? SCNCamera) ?? SCNCamera()
        playerCamera.addChildNode(companion)

        let traceModel = ElevatorArrivalTrace.shared.beginPhase("TinCanRat.model")
        let rat: SCNNode
        if let existingBody {
            rat = existingBody                                       // the same Jeff goes on
        } else {
            rat = Cast.makeJeffBody()                                // the one Jeff factory (tagged, scaled)
            rat.name = rootName
            scene.rootNode.addChildNode(rat)
        }

        ElevatorArrivalTrace.shared.endPhase("TinCanRat.model", traceModel)
        let traceDriver = ElevatorArrivalTrace.shared.beginPhase("TinCanRat.driverAndWallTargets")
        let driver = TinCanRatDriver(rat: rat, companion: companion, playerCamera: playerCamera,
                                     sceneRoot: scene.rootNode, cellKeys: Set(cells.map { TinCanRatDriver.cellKey(row: $0.row, col: $0.col) }),
                                     cellSize: Float(cellSize), bodyHeight: TinCanRatModel.bodyHeight, arrivingInsideCab: arrivingInsideCab,
                                     startsHeld: held)
        driver.enabled = isEnabled
        // Habitat pass: points just in front of each wall thing, at about eye
        // height for a person -- what he looks up toward.
        let half = Float(cellSize) / 2
        driver.wallThings = wallThings.map { coord, direction in
            SIMD3<Float>(Float(CGFloat(coord.col) * cellSize) + Float(direction.delta.col) * (half - 0.08), 1.5,
                         Float(CGFloat(coord.row) * cellSize) + Float(direction.delta.row) * (half - 0.08))
        }
        ElevatorArrivalTrace.shared.endPhase("TinCanRat.driverAndWallTargets", traceDriver)
        let traceSounds = ElevatorArrivalTrace.shared.beginPhase("TinCanRat.stepSounds")
        driver.stepSounds = TinCanRatSound.stepSources()
        ElevatorArrivalTrace.shared.endPhase("TinCanRat.stepSounds", traceSounds)
        // Oct 5 (Fred joins): the companion can run WITHOUT owning the view.
        // First-person: the view stays on the player camera (the driver keeps
        // moving its own companion node, unseen), the player's own footsteps
        // stay on, and he leads a little further out so he's in frame.
        if !usesCompanionCamera { driver.leadDistance = TinCanRatDriver.firstPersonLeadDistance }
        if held { driver.hold() } else if let startAt { driver.placeAt(startAt.position, heading: startAt.heading) }
        SoundEffects.humanFootstepsSuppressed = isEnabled && usesCompanionCamera
        rat.runAction(.repeatForever(driver.tickAction()), forKey: tickActionKey)
        view.pointOfView = (isEnabled && usesCompanionCamera) ? companion : playerCamera
        diag("tinCanRat.installed", ["enabled": isEnabled, "admissionPending": Admission.isPending,
                                     "companionCamera": usesCompanionCamera, "placed": startAt != nil,
                                     "existingBody": existingBody != nil, "held": held])
        return rat
    }

    /// The driver's own per-frame action key (never removed by a performance).
    static let tickActionKey = "tinCanRatTick"

    /// Oct 6 (Cast stage 3): the tap-walk view for a specific body.
    static func observeTapWalk(rat: SCNNode, destination: @escaping @Sendable () -> SCNVector3?) {
        TinCanRatDriver.driver(for: rat)?.tapDestination = destination
    }

    /// Prototype 1.1: hand him a read-only view of the accepted tap-walk
    /// destination (nil when no tap walk is running). Navigation never
    /// learns he exists.
    static func observeTapWalk(in scene: SCNScene, destination: @escaping @Sendable () -> SCNVector3?) {
        guard let rat = scene.rootNode.childNode(withName: rootName, recursively: false),
              let driver = TinCanRatDriver.driver(for: rat) else { return }
        driver.tapDestination = destination
    }

    /// Three-finger tap: flip the A/B state for this floor and later floors.
    static func toggle(in view: SCNView) {
        guard let root = view.scene?.rootNode,
              let rat = root.childNode(withName: rootName, recursively: false),
              let companion = root.childNode(withName: companionCameraName, recursively: true),
              let playerCamera = companion.parent,
              let driver = TinCanRatDriver.driver(for: rat) else { return }
        let on = !isEnabled
        UserDefaults.standard.set(on, forKey: enabledKey)
        driver.enabled = on
        SoundEffects.humanFootstepsSuppressed = on && usesCompanionCameraByDefault
        view.pointOfView = (on && usesCompanionCameraByDefault) ? companion : playerCamera
        diag("tinCanRat.toggled", ["enabled": on])
    }
}

/// Per-frame motion. Runs inside an SCNAction block (render thread); touches
/// only his own nodes and the companion camera's LOCAL transform.
nonisolated final class TinCanRatDriver: @unchecked Sendable {
    // Feel constants -- tune by eye.
    static let leadDistance: Float = 1.9        // how far ahead of the player he runs (m)
    /// Oct 5 (Fred joins): with the view in first person, 1.9 m ahead puts
    /// him at the bottom edge of the frame; 2.6 m keeps him in view.
    static let firstPersonLeadDistance: Float = 2.6
    /// This driver's lead (set once at install, before the first tick).
    var leadDistance: Float = TinCanRatDriver.leadDistance
    /// Set by placeAt: the first tick adopts its target without the
    /// "fresh floor -> just appear there" snap.
    private var adoptTargetOnNextTick = false
    static let wallClearance: Float = 0.4       // stop this far short of a wall (1.1: body is 2x)
    static let springStiffness: Float = 16      // follow spring
    static let springDamping: Float = 6.5       // < 2*sqrt(k): a touch of overshoot
    static let maxSpeed: Float = 6
    static let dashSpeed: Float = 11            // 1.1: heading for a tapped spot, he outruns the walk (6 m/s)
    static let strideLength: Float = 0.22       // metres per half leg cycle (1.1: 2x body)
    static let legSwing: Float = 0.75           // radians at full trot
    static let bobHeight: Float = 0.012
    static let turnRate: Float = 9              // heading smoothing (1/s)
    // Habitat pass ("giraffe" fix): the companion camera now sits at a fixed
    // 1.25 m above the floor (was the player's eye + 0.45 m, about 2.05 m),
    // 0.3 m back (was 0.2), tilted 14 degrees down (was 22). Noodle stays in
    // the same lower part of the frame; the ceiling and EXIT signs move up and
    // away, and the hallway fills the frame.
    static let companionHeight: Float = 1.25
    static let companionBack: Float = 0.3
    static let companionPitch: Float = -14 * .pi / 180
    static let bodyRadius: Float = 0.22         // habitat pass: keep-out distance from walls

    var enabled = true
    /// Habitat pass: wall-mounted things he may glance at, and his step sounds.
    var wallThings: [SIMD3<Float>] = []
    var stepSounds: [SCNAudioSource] = []
    /// Prototype 1.1: the accepted tap-walk destination, read each frame.
    var tapDestination: (@Sendable () -> SCNVector3?)?

    private weak var rat: SCNNode?
    private weak var companion: SCNNode?
    private weak var playerCamera: SCNNode?
    private weak var sceneRoot: SCNNode?
    private let body: SCNNode?
    private let legs: [(node: SCNNode, phaseOffset: Float)]
    private let tail: SCNNode?
    private let cellKeys: Set<Int>
    private let cellSize: Float
    private let bodyHeight: Float

    private var lastTime: CFTimeInterval = 0
    private var position = SIMD2<Float>(0, 0)
    private var velocity = SIMD2<Float>(0, 0)
    /// 1.2: the player's own ground velocity, measured from the camera.
    private var playerVelocity = SIMD2<Float>(0, 0)
    private var lastGround: SIMD2<Float>?
    private var heading: Float = 0
    private var gaitPhase: Float = 0
    private var gaitAmount: Float = 0
    private var lean: Float = 0
    private var roll: Float = 0
    private var companionBlend: Float = 1
    private var placed = false
    private var lastTarget = SIMD2<Float>(0, 0)
    private var wasDashing = false
    // Habitat pass: glances and footfalls.
    private var glanceCheckTimer: Double = 1
    private var glanceCooldown: Double = 4
    private var glanceTimeLeft: Double = 0
    private var glanceAt: SIMD3<Float>?
    private var glanceAmount: Float = 0
    private var glanceYaw: Float = 0
    private var glancePitch: Float = 0
    private var lastGlancedAt: [Int: CFTimeInterval] = [:]
    private var footfallIndex = 0
    // Dweezil pass: idle life -- rare, irregular, small.
    private var ears: [SCNNode] = []
    private var idleClock: Double = 3
    private var idleRoll: Float = 0, idleRollTarget: Float = 0
    private var idlePitch: Float = 0, idlePitchTarget: Float = 0
    private var idleYaw: Float = 0, idleYawTarget: Float = 0
    private var idleOffset = SIMD2<Float>(0, 0)
    private var earTwitch: (index: Int, t: Float)?
    private var tailFlick: Float?
    private var legShuffle: (index: Int, t: Float, size: Float)?
    private var lastFootfall: CFTimeInterval = 0
    /// Oct 5 (wall-embed fix): how long he has been pinned (no progress
    /// toward a distant target) -- see the recovery in tick().
    private var stuckTime: Float = 0
    /// Keep-out from a solid cell side when he is PLACED (his 2x body is
    /// much longer than bodyRadius, the moving keep-out).
    static let placementMargin: Float = 0.6

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [ObjectIdentifier: TinCanRatDriver] = [:]

    static func cellKey(row: Int, col: Int) -> Int { row * 100_000 + col }

    init(rat: SCNNode, companion: SCNNode, playerCamera: SCNNode, sceneRoot: SCNNode, cellKeys: Set<Int>, cellSize: Float, bodyHeight: Float, arrivingInsideCab: Bool = false,
         startsHeld: Bool = false) {
        self.rat = rat
        self.companion = companion
        self.playerCamera = playerCamera
        self.sceneRoot = sceneRoot
        self.body = rat.childNode(withName: "tinCanRatBody", recursively: false)
        var legs: [(node: SCNNode, phaseOffset: Float)] = []
        for i in 0..<4 {
            // Trot: front-left + back-right together, front-right + back-left opposite.
            if let leg = rat.childNode(withName: "tinCanRatLeg\(i)", recursively: true) {
                legs.append((node: leg, phaseOffset: (i == 0 || i == 3) ? Float(0) : Float.pi))
            }
        }
        self.legs = legs
        self.tail = rat.childNode(withName: "tinCanRatTail", recursively: true)
        self.ears = (0..<2).compactMap { rat.childNode(withName: "tinCanRatEar\($0)", recursively: true) }
        self.cellKeys = cellKeys
        self.cellSize = cellSize
        self.bodyHeight = bodyHeight
        Self.registryLock.lock()
        Self.registry = Self.registry.filter { $0.value.rat != nil }
        Self.registry[ObjectIdentifier(rat)] = self
        Self.registryLock.unlock()
        // A destination cab starts at the exact parent pose, not a hallway
        // viewpoint that must visibly ease back after the floor is revealed.
        companionBlend = arrivingInsideCab ? 0 : 1
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        companion.position = SCNVector3(0, (Self.companionHeight - playerCamera.position.y) * companionBlend,
                                       Self.companionBack * companionBlend)
        companion.eulerAngles = SCNVector3(Self.companionPitch * companionBlend, 0, 0)
        SCNTransaction.commit()
        // Oct 6: a body taken over mid-performance stays exactly as it is.
        if startsHeld { _held = true } else { rat.isHidden = true }
    }

    // MARK: Performance hold (Oct 6, Cast stage 3)

    /// While held, a choreographed performance owns the body: the driver
    /// writes nothing to it (position, heading, legs, ears, tail, visibility).
    /// release(at:heading:) hands it back -- the next tick adopts that spot
    /// with no snap, exactly like placeAt -- and ordinary motion resumes.
    private let holdLock = NSLock()
    private var _held = false
    private var _pendingRelease: (point: SIMD2<Float>, heading: Float)?

    func hold() {
        holdLock.lock(); _held = true; _pendingRelease = nil; holdLock.unlock()
    }

    func release(at point: SIMD2<Float>, heading: Float) {
        holdLock.lock(); _pendingRelease = (point, heading); holdLock.unlock()
    }

    /// Oct 5 (Fred joins): start exactly where something else left him (the
    /// office performance), visible, with no snap -- he then trots from here
    /// to his usual spot. Call before the tick action starts.
    func placeAt(_ point: SIMD2<Float>, heading: Float) {
        position = point
        velocity = .zero
        self.heading = heading
        placed = true
        stuckTime = 0
        adoptTargetOnNextTick = true
        rat?.position = SCNVector3(point.x, 0, point.y)
        rat?.eulerAngles = SCNVector3(0, heading, 0)
        rat?.isHidden = false
    }

    static func driver(for rat: SCNNode) -> TinCanRatDriver? {
        registryLock.lock(); defer { registryLock.unlock() }
        return registry[ObjectIdentifier(rat)]
    }

    func tickAction() -> SCNAction {
        SCNAction.customAction(duration: 1) { [weak self] _, _ in self?.tick() }
    }

    private func tick() {
        guard let rat, let companion, let playerCamera else { return }
        let now = CACurrentMediaTime()
        let dt = Float(lastTime == 0 ? 1.0 / 60 : min(max(now - lastTime, 0), 1.0 / 20))
        lastTime = now
        guard dt > 0 else { return }

        let eye = playerCamera.presentation.worldPosition
        let yaw = playerCamera.presentation.eulerAngles.y
        let forward = SIMD2<Float>(-sin(yaw), -cos(yaw))
        let ground = SIMD2<Float>(eye.x, eye.z)

        // 1.2: how fast the player (the existing navigation) is moving, read
        // from the camera's own travel. A jump (elevator, floor) counts as 0.
        if let lastGround {
            let raw = (ground - lastGround) / dt
            let measured = simd_length(ground - lastGround) > 2 ? SIMD2<Float>(0, 0) : raw
            playerVelocity += (measured - playerVelocity) * min(1, dt * 12)
        }
        lastGround = ground

        // On the maze grid? (Off it = the elevator cab.) First-person there.
        let onGrid = cellKeys.contains(Self.cellKey(row: Int((ground.y / cellSize).rounded()), col: Int((ground.x / cellSize).rounded())))
        let wantCompanion: Float = (enabled && onGrid) ? 1 : 0
        companionBlend += (wantCompanion - companionBlend) * min(1, dt * 4)
        companion.position = SCNVector3(0, (Self.companionHeight - eye.y) * companionBlend, Self.companionBack * companionBlend)
        companion.eulerAngles = SCNVector3(Self.companionPitch * companionBlend, 0, 0)

        // Oct 6 (Cast stage 3): a performance owns him until released; on
        // release, adopt the spot the performance left him on.
        holdLock.lock()
        let held = _held
        let pendingRelease = _pendingRelease
        if pendingRelease != nil { _held = false; _pendingRelease = nil }
        holdLock.unlock()
        if let pendingRelease {
            placeAt(pendingRelease.point, heading: pendingRelease.heading)
        } else if held {
            return
        }

        // Oct 4 DIAGNOSTIC (LivingWorldDiagnostic.swift): the companion camera
        // above always updates; his creature work below is switchable.
        guard enabled, onGrid, LivingWorld.noodleActive else {
            rat.isHidden = true
            placed = false
            return
        }

        // Target: a point ahead on the floor, pulled short of any wall.
        var target = ground + forward * leadDistance
        if let root = sceneRoot {
            let from = SCNVector3(ground.x, 0.12, ground.y)
            let to = SCNVector3(target.x, 0.12, target.y)
            let hits = root.hitTestWithSegment(from: from, to: to, options: [
                SCNHitTestOption.categoryBitMask.rawValue: ~CritterCategory.storyCritters,
                SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue,
                SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
                SCNHitTestOption.backFaceCulling.rawValue: false
            ])
            if let hit = hits.first {
                let p = hit.worldCoordinates
                let reach = simd_length(SIMD2<Float>(p.x, p.z) - ground)
                target = ground + forward * max(0, reach - Self.wallClearance)
            }
        }

        // Prototype 1.1: "Tin Can Rat, go THERE." While an accepted tap walk
        // is running he heads for its destination itself, and waits there;
        // once the player is within his usual lead of it, he simply goes back
        // to running just ahead (so he's never hidden under the camera).
        var dashing = false
        if let destination = tapDestination?() {
            let spot = SIMD2<Float>(destination.x, destination.z)
            if simd_length(spot - ground) > leadDistance {
                target = spot
                dashing = true
            }
        }

        // Dweezil pass: a tiny settle-in step now and then while you're standing
        // still (see idleLife); forgotten as soon as you move.
        if simd_length(playerVelocity) > 0.3 || dashing { idleOffset = .zero }
        if !dashing { target += idleOffset }

        // Fresh floor, back out of the cab, or a scripted jump: just appear there.
        // (Never while a dash starts/ends: that target jump is him running, not a teleport.)
        if adoptTargetOnNextTick {
            lastTarget = target
            adoptTargetOnNextTick = false
        }
        if !placed || (!dashing && !wasDashing && simd_length(target - lastTarget) > 2.5) {
            // Oct 5 (wall-embed fix): never appear inside building -- the
            // spot is clamped into an open, walkable cell clear of its walls.
            position = openSpot(target, fallback: ground)
            velocity = .zero
            heading = yaw
            placed = true
            stuckTime = 0
        }
        lastTarget = target
        wasDashing = dashing
        rat.isHidden = false

        // Springy follow.
        let previousVelocity = velocity
        // 1.2: the spring damps toward the PLAYER's velocity, not toward zero.
        // A plain spring chasing a moving point trails it by damping/stiffness
        // x speed (~2.4-3.7 m at long-press walking speed) -- more than his
        // 1.9 m lead, which is why he slid under the camera while holding.
        // Matching the player's velocity removes that lag, so he holds his
        // settled screen spot while you walk, and stops with you on release.
        // (A dash to a tapped spot keeps the old damping: that target is still.)
        let matchVelocity = dashing ? SIMD2<Float>(0, 0) : playerVelocity
        let accel = (target - position) * Self.springStiffness - (velocity - matchVelocity) * Self.springDamping
        velocity += accel * dt
        let speed = simd_length(velocity)
        let speedLimit = max(dashing ? Self.dashSpeed : Self.maxSpeed, simd_length(playerVelocity) * 1.3)
        if speed > speedLimit { velocity *= speedLimit / speed }
        // Habitat pass: walls are solid. The spring may aim him across a corner;
        // this keeps each frame's step out of wall/door/furniture geometry and
        // lets him slide along it instead (see containedStep).
        let step = containedStep(velocity * dt)
        position += step
        let moved = simd_length(step)
        // Oct 5 (wall-embed fix): pinned in geometry (every step blocked while
        // his target is well away) -> re-place him in the open near it.
        if !dashing, moved < 0.002, simd_length(target - position) > 1.0 {
            stuckTime += dt
            if stuckTime > 1.0 {
                let from = position
                position = openSpot(target, fallback: ground)
                velocity = .zero
                stuckTime = 0
                diag("tinCanRat.unstuck", ["from": "\(from.x),\(from.y)", "to": "\(position.x),\(position.y)"])
            }
        } else {
            stuckTime = 0
        }

        // Face where he's going; face the player's way when (nearly) still.
        let desiredHeading = speed > 0.2 ? atan2(-velocity.x, -velocity.y) : yaw
        var turn = desiredHeading - heading
        while turn > .pi { turn -= 2 * .pi }
        while turn < -.pi { turn += 2 * .pi }
        let headingStep = turn * min(1, dt * Self.turnRate)
        heading += headingStep

        // Gait: driven by distance travelled (and a little by turning on the
        // spot), never by time -- so no moonwalking, and legs stop when he does.
        gaitPhase += (moved + abs(headingStep) * 0.06) / Self.strideLength * .pi
        let wantGait: Float = min(1, speed / 0.6) + min(1, abs(headingStep) / max(dt, 0.001) / 3)
        gaitAmount += (min(1, wantGait) - gaitAmount) * min(1, dt * 8)
        let swing = sin(gaitPhase)

        // Lean with forward acceleration, roll into turns.
        let fwd = SIMD2<Float>(-sin(heading), -cos(heading))
        let forwardAccel = simd_dot(velocity - previousVelocity, fwd) / dt
        lean += (max(-0.22, min(0.22, -forwardAccel * 0.02)) - lean) * min(1, dt * 6)
        roll += (max(-0.25, min(0.25, headingStep / dt * 0.05)) - roll) * min(1, dt * 6)

        rat.position = SCNVector3(position.x, 0, position.y)
        rat.eulerAngles = SCNVector3(0, heading, 0)
        body?.position.y = bodyHeight + abs(swing) * Self.bobHeight * gaitAmount
        updateGlance(dt: Double(dt), speed: speed)
        idleLife(dt: dt, still: speed < 0.1 && simd_length(playerVelocity) < 0.2 && !dashing, rat: rat)
        body?.eulerAngles = SCNVector3(lean + glancePitch * glanceAmount + idlePitch,
                                       glanceYaw * glanceAmount + idleYaw, roll + idleRoll)
        for (i, leg) in legs.enumerated() {
            var swingX = sin(gaitPhase + leg.phaseOffset) * Self.legSwing * gaitAmount
            if let shuffle = legShuffle, shuffle.index == i { swingX += sin(shuffle.t * .pi) * shuffle.size }
            leg.node.eulerAngles.x = swingX
        }
        var tailSwing = sin(gaitPhase * 0.5) * 0.35 * gaitAmount
        if let flick = tailFlick { tailSwing += sin(flick * .pi * 2) * 0.5 * (1 - flick) }
        tail?.eulerAngles.y = tailSwing
        for (i, ear) in ears.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            var twitch: Float = 0
            if let e = earTwitch, e.index == i { twitch = sin(e.t * .pi) * 0.5 }
            ear.eulerAngles = SCNVector3(.pi / 2 + twitch * 0.4, 0, side * (0.35 + twitch))
        }
        footfalls(on: rat, now: now)
    }

    // MARK: Dweezil pass -- idle life

    /// While he and you are both standing still, every 1.5-6 s (irregular) he
    /// MIGHT do one small thing -- most often nothing at all: shift his weight
    /// among his pencil legs, reposition one foot (with a single soft step),
    /// turn his face a little, twitch one ear, flick his tail, or, rarely, take
    /// a tiny settle-in step. Each held pose eases in; all of it melts away
    /// the moment he moves.
    private func idleLife(dt: Float, still: Bool, rat: SCNNode) {
        if still {
            idleClock -= Double(dt)
            if idleClock <= 0 {
                idleClock = Double.random(in: 1.5...6)
                let roll = Float.random(in: 0...1)
                switch roll {
                case ..<0.42: break                                           // nothing
                case ..<0.58:                                                 // weight shift
                    idleRollTarget = Float.random(in: 0.03...0.07) * (Bool.random() ? 1 : -1)
                    idlePitchTarget = Float.random(in: -0.04...0.03)
                case ..<0.69:                                                 // one foot repositions
                    legShuffle = (Int.random(in: 0..<4), 0, Float.random(in: 0.25...0.45) * (Bool.random() ? 1 : -1))
                case ..<0.79:                                                 // small look
                    idleYawTarget = Float.random(in: 0.12...0.32) * (Bool.random() ? 1 : -1)
                case ..<0.88:
                    earTwitch = (Int.random(in: 0..<2), 0)
                case ..<0.95:
                    tailFlick = 0
                default:                                                      // tiny settle-in step
                    let angle = Float.random(in: 0...(2 * .pi))
                    idleOffset = SIMD2<Float>(cos(angle), sin(angle)) * Float.random(in: 0.08...0.18)
                    idleYawTarget = 0
                }
            }
        } else {
            idleClock = max(idleClock, Double.random(in: 1.5...3))
            idleRollTarget = 0; idlePitchTarget = 0; idleYawTarget = 0
            legShuffle = nil
        }
        let ease = min(1, dt * 3)
        idleRoll += (idleRollTarget - idleRoll) * ease
        idlePitch += (idlePitchTarget - idlePitch) * ease
        idleYaw += (idleYawTarget - idleYaw) * min(1, dt * 2)
        if var shuffle = legShuffle {
            let before = shuffle.t
            shuffle.t += dt / 0.32
            if before < 0.85, shuffle.t >= 0.85, let sound = stepSounds.randomElement() {
                CritterAudio.play(sound, on: rat)   // the foot sets down
            }
            legShuffle = shuffle.t >= 1 ? nil : shuffle
        }
        if var twitch = earTwitch {
            twitch.t += dt / 0.18
            earTwitch = twitch.t >= 1 ? nil : twitch
        }
        if let flick = tailFlick {
            let next = flick + dt / 0.5
            tailFlick = next >= 1 ? nil : next
        }
    }

    // MARK: Habitat pass -- solid walls

    /// The part of this frame's step that doesn't run him into geometry: a
    /// probe one body-radius past the step; on a hit, the into-the-wall part of
    /// the step (and of his velocity) is removed so he slides along it. Two
    /// passes handle an inside corner. Starting inside something (a snap) is
    /// let through so he can never get stuck.
    /// Oct 5 (wall-embed fix): `point` moved into an open walkable cell (its
    /// own, else the player's), kept placementMargin away from every side of
    /// that cell that borders solid building (or the elevator cab).
    private func openSpot(_ point: SIMD2<Float>, fallback: SIMD2<Float>) -> SIMD2<Float> {
        func cellOf(_ p: SIMD2<Float>) -> (row: Int, col: Int) {
            (row: Int((p.y / cellSize).rounded()), col: Int((p.x / cellSize).rounded()))
        }
        var cell = cellOf(point)
        var p = point
        if !cellKeys.contains(Self.cellKey(row: cell.row, col: cell.col)) {
            cell = cellOf(fallback)
            p = fallback
            guard cellKeys.contains(Self.cellKey(row: cell.row, col: cell.col)) else { return fallback }
        }
        let cx = Float(cell.col) * cellSize, cz = Float(cell.row) * cellSize
        let half = cellSize / 2, margin = min(Self.placementMargin, half * 0.9)
        func open(_ dr: Int, _ dc: Int) -> Bool { cellKeys.contains(Self.cellKey(row: cell.row + dr, col: cell.col + dc)) }
        let minX = cx - (open(0, -1) ? half : half - margin), maxX = cx + (open(0, 1) ? half : half - margin)
        let minZ = cz - (open(-1, 0) ? half : half - margin), maxZ = cz + (open(1, 0) ? half : half - margin)
        p.x = min(max(p.x, minX), maxX)
        p.y = min(max(p.y, minZ), maxZ)
        if simd_length(p - point) > 0.05 {
            diag("tinCanRat.placementClamped", ["wanted": "\(point.x),\(point.y)", "placed": "\(p.x),\(p.y)"])
        }
        return p
    }

    private func containedStep(_ wanted: SIMD2<Float>) -> SIMD2<Float> {
        guard let root = sceneRoot else { return wanted }
        var step = wanted
        for _ in 0..<2 {
            let length = simd_length(step)
            guard length > 1e-5 else { return .zero }
            let direction = step / length
            let reach = length + Self.bodyRadius
            let hits = root.hitTestWithSegment(from: SCNVector3(position.x, 0.12, position.y),
                                               to: SCNVector3(position.x + direction.x * reach, 0.12, position.y + direction.y * reach),
                                               options: Self.solidHitOptions)
            guard let hit = hits.first else { return step }
            let at = SIMD2<Float>(hit.worldCoordinates.x, hit.worldCoordinates.z)
            if simd_length(at - position) < 0.01 { return step }
            var normal = SIMD2<Float>(hit.worldNormal.x, hit.worldNormal.z)
            guard simd_length(normal) > 1e-3 else { return .zero }
            normal = simd_normalize(normal)
            if simd_dot(normal, direction) > 0 { normal = -normal }
            step -= normal * simd_dot(step, normal)
            let into = simd_dot(velocity, normal)
            if into < 0 { velocity -= normal * into }
        }
        return .zero
    }

    private static let solidHitOptions: [String: Any] = [
        SCNHitTestOption.categoryBitMask.rawValue: ~(CritterCategory.storyCritters | Bobbin.categoryBit),
        SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue,
        SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
        SCNHitTestOption.backFaceCulling.rawValue: false
    ]

    // MARK: Habitat pass -- occasionally noticing wall things

    /// Twice a second, if he isn't already looking and isn't in his cooldown:
    /// the nearest wall thing within 2.4 m that he can actually see (and hasn't
    /// looked at in the last 25 s) wins a glance only 15% of the time. A
    /// glance lasts 1-1.8 s, then he leaves it alone for 6-14 s. Nothing
    /// about where he goes changes -- only where his head (body) points.
    private func updateGlance(dt: Double, speed: Float) {
        glanceCooldown = max(0, glanceCooldown - dt)
        if glanceAt != nil {
            glanceTimeLeft -= dt
            if glanceTimeLeft <= 0 {
                glanceAt = nil
                glanceCooldown = Double.random(in: 6...14)
            }
        } else {
            glanceCheckTimer -= dt
            if glanceCheckTimer <= 0, glanceCooldown <= 0, !wallThings.isEmpty {
                glanceCheckTimer = 0.5
                pickGlance()
            }
        }
        // Where to look, relative to his body (gentler while running).
        var wantAmount: Float = 0
        if let at = glanceAt {
            let to = SIMD2<Float>(at.x, at.z) - position
            var yaw = atan2(-to.x, -to.y) - heading
            while yaw > .pi { yaw -= 2 * .pi }
            while yaw < -.pi { yaw += 2 * .pi }
            let limit: Float = speed > 1 ? 0.5 : 1.2
            glanceYaw = max(-limit, min(limit, yaw))
            glancePitch = min(0.45, atan2(at.y - bodyHeight * TinCanRat.scale, max(0.3, simd_length(to))) * 0.6)
            wantAmount = 1
        }
        glanceAmount += (wantAmount - glanceAmount) * min(1, Float(dt) * 5)
    }

    private func pickGlance() {
        let now = CACurrentMediaTime()
        var best: (index: Int, distance: Float)?
        for (i, thing) in wallThings.enumerated() {
            let d = simd_length(SIMD2<Float>(thing.x, thing.z) - position)
            guard d < 2.4, now - (lastGlancedAt[i] ?? -100) > 25 else { continue }
            if best == nil || d < best!.distance { best = (i, d) }
        }
        guard let best, Float.random(in: 0...1) < 0.15, let root = sceneRoot else { return }
        let thing = wallThings[best.index]
        let eyeHeight = bodyHeight * TinCanRat.scale + 0.05
        let hits = root.hitTestWithSegment(from: SCNVector3(position.x, eyeHeight, position.y),
                                           to: SCNVector3(thing.x, thing.y, thing.z), options: Self.solidHitOptions)
        if let hit = hits.first {
            let blockedAt = simd_length(SIMD3<Float>(hit.worldCoordinates.x, hit.worldCoordinates.y, hit.worldCoordinates.z)
                                        - SIMD3<Float>(position.x, eyeHeight, position.y))
            let full = simd_length(thing - SIMD3<Float>(position.x, eyeHeight, position.y))
            if blockedAt < full - 0.15 { return }          // something (a wall) is in the way
        }
        lastGlancedAt[best.index] = now
        glanceAt = thing
        glanceTimeLeft = Double.random(in: 1...1.8)
    }

    // MARK: Habitat pass -- his own footsteps

    /// One soft step each time a diagonal pair of pencil feet lands -- i.e. every
    /// half leg cycle, the same distance-driven phase that swings the legs, so
    /// what you hear is what you see. Thinned to at most ~13 a second when he
    /// sprints; silent when his legs aren't really moving.
    private func footfalls(on rat: SCNNode, now: CFTimeInterval) {
        let index = Int(floor(gaitPhase / .pi))
        guard index != footfallIndex else { return }
        footfallIndex = index
        guard gaitAmount > 0.35, now - lastFootfall > 1.0 / 13, let sound = stepSounds.randomElement() else { return }
        lastFootfall = now
        CritterAudio.play(sound, on: rat)
    }
}

/// The model: a tin can on four pencil legs. Local forward is -z.
enum TinCanRatModel {
    static let legLength: CGFloat = 0.09
    static let canRadius: CGFloat = 0.07
    static let canLength: CGFloat = 0.2
    static var bodyHeight: Float { Float(legLength + canRadius) }

    static func make() -> SCNNode {
        let root = SCNNode()

        func mat(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.6, glow: UIColor? = nil) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color
            m.metalness.contents = metal
            m.roughness.contents = rough
            if let glow { m.emission.contents = glow }
            return m
        }
        let tin = mat(UIColor(red: 0.78, green: 0.79, blue: 0.80, alpha: 1), metal: 0.3, rough: 0.4)
        let rim = mat(UIColor(red: 0.62, green: 0.63, blue: 0.65, alpha: 1), metal: 0.3, rough: 0.35)
        let label = mat(UIColor(red: 0.78, green: 0.16, blue: 0.12, alpha: 1), rough: 0.7)
        let pencil = mat(UIColor(red: 0.96, green: 0.77, blue: 0.16, alpha: 1), rough: 0.6)
        let wood = mat(UIColor(red: 0.86, green: 0.70, blue: 0.50, alpha: 1), rough: 0.8)
        let graphite = mat(UIColor(white: 0.18, alpha: 1), rough: 0.5)
        let eyeWhite = mat(.white, rough: 0.3, glow: UIColor(white: 0.25, alpha: 1))
        let pupil = mat(.black, rough: 0.2)
        let pink = mat(UIColor(red: 0.93, green: 0.62, blue: 0.66, alpha: 1), rough: 0.7)

        // Contact shadow: soft dark disc on the floor (scene lights cast none).
        let shadowPlane = SCNPlane(width: 0.3, height: 0.42)
        let shadowMat = SCNMaterial()
        shadowMat.lightingModel = .constant
        shadowMat.diffuse.contents = shadowImage()
        shadowMat.writesToDepthBuffer = false
        shadowMat.isDoubleSided = false
        shadowPlane.materials = [shadowMat]
        let shadow = SCNNode(geometry: shadowPlane)
        shadow.eulerAngles.x = -.pi / 2
        shadow.position.y = 0.004
        shadow.renderingOrder = 1
        root.addChildNode(shadow)

        // Oct 9: Mr. Tinky, Hallwaysian -- the modeled body (same joints,
        // proportions and forward), unless the classic one is asked for.
        if HallwaysianTinky.isEnabled, let modeled = HallwaysianTinky.makeBody() {
            modeled.position = SCNVector3(0, bodyHeight, 0)
            root.addChildNode(modeled)
            root.enumerateHierarchy { node, _ in node.categoryBitMask = TinCanRat.categoryBit }
            return root
        }

        // Body: a can lying on its side along z.
        let body = SCNNode()
        body.name = "tinCanRatBody"
        body.position.y = bodyHeight
        root.addChildNode(body)
        let can = SCNCylinder(radius: canRadius, height: canLength)
        can.radialSegmentCount = 28
        can.materials = [tin]
        let canNode = SCNNode(geometry: can)
        canNode.eulerAngles.x = .pi / 2
        body.addChildNode(canNode)
        let band = SCNCylinder(radius: canRadius + 0.002, height: canLength * 0.5)
        band.radialSegmentCount = 28
        band.materials = [label]
        let bandNode = SCNNode(geometry: band)
        bandNode.eulerAngles.x = .pi / 2
        body.addChildNode(bandNode)
        for z in [-canLength / 2, canLength / 2] {
            let ring = SCNTorus(ringRadius: canRadius, pipeRadius: 0.006)
            ring.materials = [rim]
            let ringNode = SCNNode(geometry: ring)
            ringNode.eulerAngles.x = .pi / 2
            ringNode.position.z = Float(z)
            body.addChildNode(ringNode)
        }

        // Face on the front lid: two eyes, two ears.
        let front = Float(-canLength / 2)
        for side in [Float(-1), 1] {
            let eye = SCNNode(geometry: SCNSphere(radius: 0.019))
            eye.geometry?.materials = [eyeWhite]
            eye.position = SCNVector3(side * 0.03, 0.025, front - 0.004)
            body.addChildNode(eye)
            let dot = SCNNode(geometry: SCNSphere(radius: 0.009))
            dot.geometry?.materials = [pupil]
            dot.position = SCNVector3(0, 0, -0.014)
            eye.addChildNode(dot)
            let ear = SCNNode(geometry: SCNCylinder(radius: 0.026, height: 0.006))
            ear.name = side < 0 ? "tinCanRatEar0" : "tinCanRatEar1"
            ear.geometry?.materials = [pink]
            ear.eulerAngles = SCNVector3(.pi / 2, 0, side * 0.35)
            ear.position = SCNVector3(side * 0.045, Float(canRadius) + 0.012, front + 0.03)
            body.addChildNode(ear)
        }

        // Tail: a bent wire off the back lid.
        let tailPivot = SCNNode()
        tailPivot.name = "tinCanRatTail"
        tailPivot.position = SCNVector3(0, 0.01, Float(canLength / 2))
        body.addChildNode(tailPivot)
        let wire = SCNNode(geometry: SCNCylinder(radius: 0.0035, height: 0.2))
        wire.geometry?.materials = [graphite]
        wire.eulerAngles.x = .pi / 2 - 0.45
        wire.position = SCNVector3(0, 0.04, 0.09)
        tailPivot.addChildNode(wire)

        // Legs: pencil shafts hanging from hip pivots, sharpened tips as feet.
        let hips: [(Float, Float)] = [(-0.042, -0.06), (0.042, -0.06), (-0.042, 0.06), (0.042, 0.06)] // FL FR BL BR
        for (i, hip) in hips.enumerated() {
            let pivot = SCNNode()
            pivot.name = "tinCanRatLeg\(i)"
            pivot.position = SCNVector3(hip.0, -Float(canRadius) * 0.55, hip.1)
            body.addChildNode(pivot)
            let shaftLength = legLength * 0.7
            let shaft = SCNNode(geometry: SCNCylinder(radius: 0.0055, height: shaftLength))
            shaft.geometry?.materials = [pencil]
            shaft.position.y = -Float(shaftLength / 2)
            pivot.addChildNode(shaft)
            let tipLength = legLength * 0.3 + CGFloat(Float(canRadius) * 0.45)
            let cone = SCNNode(geometry: SCNCone(topRadius: 0.0055, bottomRadius: 0.0, height: tipLength))
            cone.geometry?.materials = [wood]
            cone.position.y = -Float(shaftLength) - Float(tipLength / 2)
            pivot.addChildNode(cone)
            let lead = SCNNode(geometry: SCNSphere(radius: 0.0022))
            lead.geometry?.materials = [graphite]
            lead.position.y = -Float(shaftLength + tipLength)
            pivot.addChildNode(lead)
        }

        root.enumerateHierarchy { node, _ in node.categoryBitMask = TinCanRat.categoryBit }
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

/// Habitat pass: Noodle's own footstep, synthesised (no assets). Each step is
/// ~60 ms of three layers -- a dry pencil-tip "tk" (a 4 ms burst of brightened
/// noise), a soft carpet scritch (a short burst of darker noise), and a faint
/// two-partial tin "tink" (inharmonic sines, like a tapped can) -- built as 8
/// slightly different variants (tip brightness, can pitch, layer levels and
/// overall level all jittered) so consecutive steps never sound identical.
/// Mono + positional, quiet, coming from Noodle himself.
nonisolated enum TinCanRatSound {
    static func stepSources() -> [SCNAudioSource] {
        (0..<8).compactMap { i in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-step-v1-\(i).wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                guard (try? BobbinSound.wav(samples(seed: UInt64(i) &+ 7)).write(to: url)) != nil else { return nil }
            }
            guard let source = SCNAudioSource(url: url) else { return nil }
            source.isPositional = true
            source.shouldStream = false
            source.volume = 0.35
            source.load()
            return source
        }
    }

    private static func samples(seed: UInt64) -> [Float] {
        var rng = SplitMix(seed: seed)
        func r(_ a: Float, _ b: Float) -> Float { a + (b - a) * rng.unit() }
        let rate = Float(BobbinSound.rate)
        let count = Int(0.065 * rate)
        let gain = r(0.65, 1.0)
        let tipBright = r(0.55, 0.85)            // high-pass amount for the tip
        let scritchLevel = r(0.10, 0.20)
        let canFreq = r(2250, 2750)
        let canRatio = r(1.46, 1.54)
        let canLevel = r(0.06, 0.11)
        var out = [Float](repeating: 0, count: count)
        var lowpass: Float = 0
        var previous: Float = 0
        for i in 0..<count {
            let t = Float(i) / rate
            let noise = rng.unit() * 2 - 1
            // Tip: brightened noise (difference = crude high-pass), very fast decay.
            let tip = (noise - previous * tipBright) * exp(-t / 0.0012) * 0.5
            previous = noise
            // Scritch: darker noise (one-pole low-pass), short decay.
            lowpass += (noise - lowpass) * 0.25
            let scritch = lowpass * exp(-t / 0.008) * scritchLevel
            // Tin: two inharmonic partials, gentle ring.
            let tin = (sin(2 * .pi * canFreq * t) * exp(-t / 0.022)
                       + 0.6 * sin(2 * .pi * canFreq * canRatio * t) * exp(-t / 0.014)) * canLevel
            let attack = min(1, t / 0.0006)      // no click at the start
            out[i] = (tip + scritch + tin) * attack * gain
        }
        return out
    }

    /// Tiny deterministic generator, so each variant is fixed between launches.
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    }
}
