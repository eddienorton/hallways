//
//  ContinuousWalkControls.swift
//  Hallways
//
//  Oct 10 experiment: ◀ LEFT | center | RIGHT ▶ along the bottom.
//  The center button is contextual (TapNavigationController.hudCenter):
//  WALK, STOP while walking, or the one existing interaction in front of a
//  stopped player (OPEN / TAKE / USE / PLAY / PHOTO / KNOCK / MAIL / SPRAY /
//  ENTER). Pure input: every tap goes to the controller, which owns the walk
//  and runs the same handlers a tap on the object would. What the buttons
//  show is read straight from the controller, re-read a few times a second
//  so door/object state that changes on its own is reflected too.
//

import SwiftUI

struct ContinuousWalkControls: View {
    @ObservedObject var controller: TapNavigationController

    /// Bottom inset shared with the Settings gear (PlayerSettingsButton), so
    /// the row sits on the same line as it, clear of the gear and the phone.
    /// Oct 10 (playthrough): lowered from 28 -- the row now sits just above
    /// the safe area (home indicator), clear of the ID kiosk's card slot.
    /// The views stay inside the safe area, so iPad/iPhone insets still apply.
    static let bottomPadding: CGFloat = 4
    static let rowHeight: CGFloat = 56

    private var queued: TapNavigationController.ContinuousWalkTurn? {
        if case .walkingQueued(let turn) = controller.continuousWalkState { return turn }
        return nil
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            row(center: controller.hudCenter)
        }
    }

    private func row(center: TapNavigationController.HUDCenter) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                arrowButton(.left)
                centerButton(center)
                arrowButton(.right)
            }
            .padding(.bottom, Self.bottomPadding)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.12), value: center)
        .animation(.easeInOut(duration: 0.12), value: controller.continuousWalkState)
    }

    private func centerButton(_ center: TapNavigationController.HUDCenter) -> some View {
        let isAction: Bool = { if case .action = center { return true }; return false }()
        let enabled = center != .unavailable
        return Button { controller.hudCenterTapped() } label: {
            Text(center.label)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .tracking(1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isAction ? Color.black : Color.white)
                .frame(width: 88, height: Self.rowHeight)
                .background(isAction ? Color.white.opacity(0.92) : Color.black.opacity(0.62), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(center == .stop ? 0.85 : 0), lineWidth: 2))
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("continuousWalkButton")
        .accessibilityLabel(center == .stop ? "Stop walking" : center.label.capitalized)
    }

    private func arrowButton(_ turn: TapNavigationController.ContinuousWalkTurn) -> some View {
        let lit = queued == turn
        return Button { controller.continuousWalkTurnTapped(turn) } label: {
            Image(systemName: turn == .left ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(lit ? Color.black : Color.white)
                .frame(width: Self.rowHeight, height: Self.rowHeight)
                .background(lit ? Color(red: 1.0, green: 0.80, blue: 0.30) : Color.black.opacity(0.62), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(lit ? 0.9 : 0), lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(turn == .left ? "continuousWalkLeft" : "continuousWalkRight")
        .accessibilityLabel(turn == .left ? "Left" : "Right")
        .accessibilityValue(lit ? "queued" : "")
    }
}
