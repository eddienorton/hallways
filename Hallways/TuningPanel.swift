//
//  TuningPanel.swift
//  Hallways
//
//  Small on-screen slider panel so movement feel can be tuned live,
//  on-device, without recompiling. Tap the slider icon to show/hide it.
//

import SwiftUI

struct TuningPanel: View {
    @ObservedObject var tuning: TuningParams

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Accel", $tuning.acceleration, 0.5...8)
            row("Decel", $tuning.deceleration, 0.5...10)
            row("Max Speed", $tuning.maxForwardSpeed, 0.5...12)
            Divider().overlay(Color.white.opacity(0.2))
            row("Steer Sens.", $tuning.steeringSensitivity, 0.2...3)
            row("Steer Inertia", $tuning.steeringInertia, 0.0...0.6)
            Divider().overlay(Color.white.opacity(0.2))
            row("Steer Radius", $tuning.joystickRadius, 40...200)
            row("Steer Deadzone", $tuning.joystickDeadzone, 0...40)
            row("Steer Curve", $tuning.steeringCurve, 1...5)
            row("Field of View", $tuning.fieldOfView, 50...110)
        }
        .padding(12)
        .frame(width: 230)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func row(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            Slider(value: value, in: range)
        }
    }
}
