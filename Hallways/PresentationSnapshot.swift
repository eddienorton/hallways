//
//  PresentationSnapshot.swift
//  Hallways
//
//  Oct 25 (PP 8) -- THE "MOVING THROUGH MUD" FIX: the drawn scene's few animated values that the main
//  thread's timers keep asking for, captured once per rendered frame on SceneKit's own thread.
//
//  WHY: reading a node's `presentation` takes SceneKit's scene lock. In the muddy state SceneKit holds that
//  lock for nearly all of every frame, so each such read on the main thread waited up to a whole frame --
//  Instruments (Documents/Hallways-mud-2026-10-25.trace): the main thread spent 19.8 s of 25.2 s waiting on
//  it (1.6% when healthy), and 99% of that was two values read over and over by timers:
//    * the elevator's right door, as drawn (elevatorDoorsOpenFraction: the door-sound sampler, runCarDoors)
//    * the player camera's drawn world position / yaw (BuildingLife.playerPosition -- the living orchestra,
//      the residents' music, BuildingLife's tick -- the mirror's demand check, the leads' playerPose)
//
//  HOW: TapNavigationController's renderer(_:didRenderScene:atTime:) -- already inside SceneKit's frame,
//  the scene lock already held by that thread -- reads exactly those values and publishes them here.
//  Timers read the last frame's values instead of SceneKit. Only VALUES are published (no SceneKit
//  objects); the store is a small struct behind an unfair lock held for a copy (no allocation per frame,
//  never held across SceneKit calls, so it can't contend with SceneKit's own lock).
//
//  NEVER STALE: one snapshot per controller -- every scene install makes a new TapNavigationController, so
//  a new floor or scene starts empty and can't see the old scene's values. And a frame older than `maxAge`
//  (the renderer paused, backgrounded, or the view now drawing another controller's scene) is ignored: the
//  caller then reads SceneKit directly, as before -- which can't wait long then, as nothing is rendering.
//  Before the first frame of a scene the same direct read applies.
//

import Foundation
import QuartzCore
import os
import simd

nonisolated final class PresentationSnapshot: @unchecked Sendable {
    nonisolated struct Frame: Sendable, Equatable {
        /// When it was captured (CACurrentMediaTime). 0: nothing captured yet.
        var time: CFTimeInterval = 0
        /// Frames published so far (0: none).
        var count: UInt64 = 0
        /// The camera's presentation world position and Euler Y (yaw), as drawn.
        var cameraWorld = SIMD3<Float>(repeating: 0)
        var cameraYaw: Float = 0
        /// The elevator's right door's presentation position (in its parent's space), as drawn.
        var hasRightDoor = false
        var rightDoor = SIMD3<Float>(repeating: 0)
    }

    /// A frame older than this is not used (seconds; a frame is 1/30 s).
    static let maxAge: CFTimeInterval = 0.25

    private let state = OSAllocatedUnfairLock(initialState: Frame())

    init() {}

    /// SceneKit's render thread, inside its frame callback (the scene lock is already that thread's).
    func publish(cameraWorld: SIMD3<Float>, cameraYaw: Float, rightDoor: SIMD3<Float>?, at time: CFTimeInterval) {
        state.withLock { f in
            f.time = time
            f.count &+= 1
            f.cameraWorld = cameraWorld
            f.cameraYaw = cameraYaw
            f.hasRightDoor = rightDoor != nil
            f.rightDoor = rightDoor ?? .zero
        }
    }

    /// Any thread: the last drawn frame, if it is recent enough to stand for "now"; else nil (read SceneKit).
    func fresh(now: CFTimeInterval = CACurrentMediaTime()) -> Frame? {
        let f = state.withLock { $0 }
        return Self.isFresh(f, now: now) ? f : nil
    }

    /// (pure; tests) A captured frame no older than `maxAge` -- and never one "from the future".
    static func isFresh(_ f: Frame, now: CFTimeInterval, maxAge: CFTimeInterval = maxAge) -> Bool {
        guard f.count > 0 else { return false }
        let age = now - f.time
        return age >= -0.05 && age <= maxAge
    }
}
