//
//  StickyProbe.swift
//  Hallways
//
//  Oct 22 (evening) -- MEASUREMENT ONLY: the intermittent "sticky controls".
//
//  On the iPhone the game sometimes stops answering a slow swipe until the end
//  of it, even standing still for 15 s -- and has twice come back at once (the
//  Directory opened and a critter's music played; an elevator chime). The one
//  diagnostics file we have shows, in the sticky seconds, the main thread "busy"
//  by the clock but barely using the CPU, every timed section taking about one
//  rendered frame (~33 ms): the main thread WAITING, most likely for SceneKit's
//  render lock (any `presentation` read waits for the frame being drawn). That
//  is a measurement, not yet a cause. This file adds what the next sticky spell
//  needs to name its cause -- cheaply, and changing nothing it measures:
//
//    input.lag           per touch event: how long from the touch reaching the
//                        system to the app seeing it (a gesture recognizer that
//                        only watches; it never recognises anything). In the
//                        per-second PERFORMANCE lines with the other sections.
//    probe.sceneLock     once a second: one `presentation` read of the scene
//                        root -- its time is how long the main thread had to
//                        wait for the renderer.
//    audio engine        once a second: is SceneKit's audio engine running? A
//                        change is marked ("audio engine stopped/running").
//    events              tray opened / put away, Directory and its previews,
//                        a resident's music, the elevator chime, Settings --
//                        each marked in the PERFORMANCE line of its second.
//    recovery            when touches were late (>= 250 ms) for 2 s or more and
//                        then are prompt again (< 60 ms): one mark naming what
//                        happened in the 4 s before -- so "it recovered when..."
//                        is in the file, not only in memory.
//
//  Off with everything else in PerfMonitor (Release builds unless -HallwaysPerf YES).
//

import AVFAudio
import QuartzCore
import SceneKit
import UIKit

@MainActor
enum StickyProbe {
    // MARK: Events (for the recovery note)

    private static var recent: [(t: CFTimeInterval, what: String)] = []

    /// Something that might matter happened (marked in this second's PERFORMANCE line).
    static func note(_ what: String) {
        guard PerfMonitor.enabled else { return }
        let now = CACurrentMediaTime()
        recent.append((now, what))
        recent.removeAll { now - $0.t > 6 }
        PerfMonitor.shared.mark(what)
    }

    // MARK: Input lag (main thread, per touch event)

    private static var lagMaxThisSecond: CFTimeInterval = 0
    private static var lateStreak = 0
    private static var lateSince: CFTimeInterval?

    static func touchArrived(eventTime: TimeInterval) {
        let lag = max(0, CACurrentMediaTime() - eventTime)
        lagMaxThisSecond = max(lagMaxThisSecond, lag)
        // (only late ones go in the PERFORMANCE line: a prompt touch says nothing)
        if lag >= 0.05 { PerfMonitor.record("input.lag", ns: UInt64(lag * 1e9)) }
    }

    // MARK: Once a second (BuildingLife.tick)

    private static weak var engine: AVAudioEngine?
    private static var engineWasRunning: Bool?

    static func watch(engine e: AVAudioEngine) { engine = e }

    static func tick(sceneRoot: SCNNode?) {
        guard PerfMonitor.enabled else { return }
        MudProbe.shared.secondTick()                                         // Oct 24 (mud probe): the audio machinery's state
        // How long one presentation read waits for the renderer right now.
        if let root = sceneRoot {
            let p = PerfMonitor.begin("probe.sceneLock")
            _ = root.presentation.worldPosition
            PerfMonitor.end(p)
        }
        // SceneKit's audio engine: running or not (a change is marked).
        if let e = engine {
            let running = e.isRunning
            if let was = engineWasRunning, was != running { note(running ? "audio engine running" : "audio engine STOPPED") }
            engineWasRunning = running
        }
        // Late touches, then prompt again: say what happened just before.
        let lag = lagMaxThisSecond
        lagMaxThisSecond = 0
        let now = CACurrentMediaTime()
        if lag >= 0.25 {
            if lateStreak == 0 { lateSince = now }
            lateStreak += 1
        } else if lag > 0, lag < 0.06 {
            if lateStreak >= 2, let since = lateSince {
                let before = recent.filter { now - $0.t <= 4 }.map(\.what)
                let text = String(format: "input recovered after %.0f s late", now - since)
                    + (before.isEmpty ? " (nothing marked just before)" : " after: " + before.joined(separator: "; "))
                PerfMonitor.shared.mark(text)
                diag("sticky.recovered", ["lateSeconds": Int(now - since), "before": before.joined(separator: "; ")])
            }
            lateStreak = 0
            lateSince = nil
        }
        if lateStreak == 2 { diag("sticky.started", ["lagMs": Int(lag * 1000)]) }
    }
}

/// Watches touches on the game view and reports how late each reached the app.
/// Never recognises, never delays or cancels a touch, works alongside every
/// other recognizer.
final class InputLagProbe: UIGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        StickyProbe.touchArrived(eventTime: event.timestamp)
        MudProbe.shared.touchDown(eventTime: event.timestamp)                // Oct 24 (mud probe)
        FrameTiming.shared.touchDelivered(eventTime: event.timestamp)       // Oct 24 (frame timing): every delivery
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        StickyProbe.touchArrived(eventTime: event.timestamp)
        FrameTiming.shared.touchDelivered(eventTime: event.timestamp)       // Oct 24 (frame timing): every delivery
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed                                                  // (never recognised: others carry on)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
