//
//  TuningParams.swift
//  Hallways
//
//  Live-tunable movement/feel parameters for Prototype 1/2.
//  Bound to sliders in TuningPanel so Eddie can adjust feel on-device
//  without rebuilding — MovementController reads these directly every frame.
//

import Foundation
import Combine

final class TuningParams: ObservableObject {
    // Forward motion
    @Published var acceleration: Double = 2.2       // units/s^2 while touching
    @Published var deceleration: Double = 3.5       // units/s^2 once released (snappier than accel by default)
    @Published var maxForwardSpeed: Double = 8.0    // units/s at full speed

    // Steering (left/right only — up/down was tried and cut, see project notes)
    @Published var steeringSensitivity: Double = 1.1   // max yaw rate, rad/s, at full drag
    @Published var steeringInertia: Double = 0.12       // seconds; higher = smoother/laggier turning

    // Steering input: drag distance relative to where you first touched
    // down (not absolute screen position). Response is eased, not linear —
    // steeringCurve > 1 means small drags barely turn you at all, and it
    // takes a real, deliberate drag before turning ramps up to sharp.
    @Published var joystickRadius: Double = 110      // points of drag for full steering input
    @Published var joystickDeadzone: Double = 8       // points of drag ignored right at touch-down, so
                                                       // ordinary hand tremor while "holding still" doesn't
                                                       // read as a steering command
    @Published var steeringCurve: Double = 2.5        // 1 = linear; higher = gentler near the touch point,
                                                       // sharper only once you've dragged a real distance

    // Camera
    @Published var fieldOfView: Double = 75
}
