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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
