//
//  HallwaysApp.swift
//  Hallways
//
//  Created by Edward Brayman on 9/2/26.
//

import SwiftUI

@main
struct HallwaysApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Oct 2: persistent diagnostics (see DiagnosticRecorder). Appends a
        // SESSION START block -- never clears earlier sessions.
        DiagnosticRecorder.shared.startSession()
        DiagnosticRecorder.shared.startMainThreadWatchdog()
        // Oct 21 (slowdown hunt): main-thread / render / CPU / memory evidence,
        // developer builds only (see PerfMonitor). Measurement only.
        if !ResumeState.runningUnderTests { PerfMonitor.shared.start() }
        // Oct 11: the audio session is configured ONCE, here, before the 3D
        // view's audio engine (or any sound) exists -- changing it under a
        // running engine restarts the engine, a classic launch crackle.
        SoundEffects.configureAudioSession(reason: "launch")
        // Oct 11 (resume): save/restore the player's place (off under tests).
        ResumeState.isRecording = !ResumeState.runningUnderTests
        // Oct 12: what was saved and what this launch will do with it (diagnostics).
        ResumeState.logLaunchState()
        // Oct 12: an escort quit in its first phase is under way again before any floor builds.
        GuidedJourney.prepareForLaunch()
        // Oct 18: the arguments as received, and the resident test/fast modes they turn on.
        BuildingLife.reportLaunch()
    }

    var body: some Scene {
        WindowGroup {
            // Oct 19: `-HallwaysFeddyAudition YES` opens the Feddy audition
            // (FeddyAudition.swift) INSTEAD of the game; without it, the game.
            if FeddyAudition.isRequested {
                FeddyAuditionView()
            } else {
                ContentView()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            let name: String
            switch phase {
            case .active: name = "active"
            case .inactive: name = "inactive"
            case .background: name = "background"
            @unknown default: name = "unknown"
            }
            DiagnosticRecorder.shared.noteLifecycle(name)
        }
    }
}
