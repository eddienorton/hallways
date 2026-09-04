//
//  MovementController.swift
//  Hallways
//
//  The interaction, current version: touch anywhere to move forward, and
//  keep moving forward as long as you hold. The touch-down point is the
//  origin; dragging away from it steers, but the response is EASED, not
//  linear — a small drag barely turns you, and only a real, deliberate
//  drag ramps up to a sharp turn (see steeringCurve in TuningParams).
//  Release decelerates smoothly to a stop. A second finger down reverses
//  (drive backward without turning around) — steering still works the
//  same way off the first finger's drag the whole time.
//
//  (Tried and cut along the way: reading absolute finger position against
//  screen-center instead of drag-from-origin — that's gone, this is back
//  to origin-relative, just with the eased curve added on top.)
//
//  Movement is grounded: forward motion is always horizontal at a fixed
//  eye height, camera always level — no up/down look at all (tried and
//  cut, see TuningParams for why).
//

import SceneKit
import UIKit

/// SCNView subclass that remembers where the current touch started and
/// where it is now. No gesture recognizers — this is the raw input for
/// the origin-relative steering above.
final class TouchTrackingSCNView: SCNView {
    private(set) var touchOrigin: CGPoint?
    private(set) var currentTouch: CGPoint?
    /// How many fingers are down right now. 1 = drive forward (as
    /// before), 2+ = reverse — see MovementController.
    private(set) var activeTouchCount = 0

    private var activeTouches: Set<UITouch> = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        activeTouches.formUnion(touches)
        activeTouchCount = activeTouches.count

        // The steering origin is whichever finger touched down first, and
        // it stays put until every finger has lifted — a second finger
        // landing (to trigger reverse) doesn't reset it or interrupt the
        // drag already in progress.
        guard touchOrigin == nil, let touch = touches.first else { return }
        let point = touch.location(in: self)
        touchOrigin = point
        currentTouch = point
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first else { return }
        currentTouch = touch.location(in: self)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        activeTouches.subtract(touches)
        activeTouchCount = activeTouches.count
        guard activeTouches.isEmpty else { return }
        touchOrigin = nil
        currentTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        activeTouches.subtract(touches)
        activeTouchCount = activeTouches.count
        guard activeTouches.isEmpty else { return }
        touchOrigin = nil
        currentTouch = nil
    }
}

final class MovementController: NSObject, SCNSceneRendererDelegate {
    weak var touchView: TouchTrackingSCNView?
    let cameraNode: SCNNode
    let tuning: TuningParams

    // Walkable floor rectangles (in world XZ), from HallwayScene — the
    // player is clamped to whichever one of these is nearest, which
    // naturally handles a multi-leg path like the current L-shaped hall.
    var walkableRects: [HallwayScene.FloorRect] = []

    private let spawnPosition: SCNVector3
    // Whatever yaw the scene builder pointed the camera at on creation —
    // 0 for the fixed prototypes, but a maze built from the grid editor
    // faces the player down whichever hallway is open at the start cell.
    private let spawnYaw: Double

    private var lastTime: TimeInterval = 0
    private var forwardSpeed: Double = 0
    private var yaw: Double = 0     // radians, 0 = facing -Z (SceneKit's default camera facing)
    private var smoothedYawRate: Double = 0

    init(cameraNode: SCNNode, tuning: TuningParams) {
        self.cameraNode = cameraNode
        self.tuning = tuning
        self.spawnPosition = cameraNode.position
        self.spawnYaw = Double(cameraNode.eulerAngles.y)
        super.init()
        self.yaw = spawnYaw
    }

    /// Snap straight back to the start, fully stopped. Wired to the
    /// on-screen Reset button.
    func reset() {
        yaw = spawnYaw
        forwardSpeed = 0
        smoothedYawRate = 0
        lastTime = 0
        cameraNode.position = spawnPosition
        cameraNode.eulerAngles = SCNVector3(0, Float(spawnYaw), 0)
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        defer { lastTime = time }
        guard lastTime > 0 else { return }
        let dt = min(time - lastTime, 1.0 / 20.0) // clamp so a stall doesn't cause a big jump
        guard dt > 0 else { return }

        let origin = touchView?.touchOrigin
        let current = touchView?.currentTouch
        let isTouching = origin != nil
        // 1 finger drives forward, 2 (or more) reverses — direction only,
        // your facing doesn't spin around, same as backing up a car.
        let isReversing = (touchView?.activeTouchCount ?? 0) >= 2
        let direction: Double = isReversing ? -1 : 1

        // --- steering target: eased drag distance from the touch origin ---
        var targetYawRate = 0.0
        if let origin, let current, tuning.joystickRadius > tuning.joystickDeadzone {
            let dx = Double(current.x - origin.x)
            let magnitude = abs(dx)
            // Deadzone: ignore drag distance right around touch-down so
            // ordinary hand tremor from "holding still" isn't read as a
            // steering command.
            if magnitude > tuning.joystickDeadzone {
                let usableRange = tuning.joystickRadius - tuning.joystickDeadzone
                let linear = min(1.0, (magnitude - tuning.joystickDeadzone) / usableRange)
                // Eased response: raising to steeringCurve (>1) keeps small
                // drags gentle and only ramps up to sharp near full drag —
                // "gradual unless you really mean it."
                let eased = pow(linear, max(1.0, tuning.steeringCurve))
                let sign = dx < 0 ? -1.0 : 1.0
                targetYawRate = -(sign * eased) * tuning.steeringSensitivity
            }
        }

        // Exponential smoothing so steering has a bit of weight/inertia
        // instead of snapping instantly to the raw input.
        let yawLerp = tuning.steeringInertia > 0.001 ? 1 - exp(-dt / tuning.steeringInertia) : 1
        smoothedYawRate += (targetYawRate - smoothedYawRate) * yawLerp
        yaw += smoothedYawRate * dt

        // --- forward speed: accelerate while touching, decelerate on release ---
        if isTouching {
            forwardSpeed = min(tuning.maxForwardSpeed, forwardSpeed + tuning.acceleration * dt)
        } else {
            forwardSpeed = max(0, forwardSpeed - tuning.deceleration * dt)
        }

        // --- integrate position: horizontal only, fixed eye height ---
        let forwardX = -sin(yaw)
        let forwardZ = -cos(yaw)

        var pos = cameraNode.position
        pos.x += Float(forwardX * forwardSpeed * direction * dt)
        pos.z += Float(forwardZ * forwardSpeed * direction * dt)
        pos.y = spawnPosition.y

        let clamped = clampToWalkable(x: Double(pos.x), z: Double(pos.z))
        let hitWall = abs(clamped.x - Double(pos.x)) > 0.0005 || abs(clamped.z - Double(pos.z)) > 0.0005
        pos.x = Float(clamped.x)
        pos.z = Float(clamped.z)

        if hitWall {
            // Pressed against a wall — bleed off speed instead of grinding
            // at full speed while pinned there.
            forwardSpeed = max(0, forwardSpeed - tuning.deceleration * dt * 3)
        }

        cameraNode.position = pos
        cameraNode.eulerAngles = SCNVector3(0, Float(yaw), 0)

        if let camera = cameraNode.camera {
            camera.fieldOfView = tuning.fieldOfView
        }
    }

    /// Clamps (x, z) to the nearest point in the union of walkableRects —
    /// i.e. "stay inside whichever leg you're actually in," which also
    /// naturally lets you walk through the open doorway between legs.
    private func clampToWalkable(x: Double, z: Double) -> (x: Double, z: Double) {
        guard !walkableRects.isEmpty else { return (x, z) }
        var best: (x: Double, z: Double, dist: Double)?
        for rect in walkableRects {
            let cx = min(max(x, Double(rect.xRange.lowerBound)), Double(rect.xRange.upperBound))
            let cz = min(max(z, Double(rect.zRange.lowerBound)), Double(rect.zRange.upperBound))
            let dist = (cx - x) * (cx - x) + (cz - z) * (cz - z)
            if best == nil || dist < best!.dist {
                best = (cx, cz, dist)
            }
        }
        return (best!.x, best!.z)
    }
}
