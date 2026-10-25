//
//  FrameTiming.swift
//  Hallways
//
//  Oct 24 -- MEASUREMENT ONLY: 30 fps vs 60 fps.
//
//  At 60 fps swipes feel sluggish even while the HUD shows a steady 60 fps and
//  6-8 ms of GPU; at 30 fps they're much more responsive. Two captures of the
//  mud found the main thread waiting in SceneKit's scene lock (a camera read, a
//  door read) while the render thread sat in nextDrawable. The question this
//  file answers: is the 60 fps sluggishness SceneKit lock contention (the
//  renderer holding the scene for most of each frame, every main-thread scene
//  access waiting behind it), or game logic that does more work at 60?
//  It changes nothing it measures: it only reads clocks.
//
//  Three groups of timings, each a DISTRIBUTION (count, average, p95, max, and
//  how many went over 8 / 16 / 33 ms) -- an intermittent stall shows in the
//  p95, the max and the over-counts, never averaged away:
//
//   RENDER THREAD (SceneKit's delegate callbacks on TapNavigationController)
//    render.callbackSpan  willRenderScene -> didRenderScene. Named for what it
//                         is: the span between two callbacks, NOT a measured
//                         lock hold. SceneKit holds its scene lock through at
//                         least this span; it may hold it longer (or wait for a
//                         drawable outside it) -- we can't see inside.
//    render.updateToDid   updateAtTime -> didRenderScene: the whole callback
//                         sequence of one frame (update, animations, physics,
//                         constraints, encoding).
//    render.didToUpdate   didRenderScene -> the next updateAtTime: everything
//                         SceneKit does outside our callbacks (presenting,
//                         waiting for a drawable, idling until its next tick).
//                         At 30 fps on a 60 Hz screen this includes the skipped
//                         refresh; a sum of the two "render.*To*" is one frame.
//
//   MAIN THREAD, INSIDE SCENEKIT CALLS (each one a few microseconds when the
//   scene is free -- anything longer is waiting for the renderer)
//    main.scn.pose        the shared playerPose closures (camera
//                         presentation.worldPosition + eulerAngles): critters,
//                         eyes, leads, follow.
//    main.scn.camera      each camera access a swipe makes (the yaw write in
//                         updateDragRotate; the yaw + position read and the
//                         position write in updateFreePan).
//    main.scn.doorFrac    elevatorDoorsOpenFraction (the elevator door's
//                         presentation position; door-sound timer, car poll).
//    main.pan             the whole of one updateFreePan call (its camera
//                         accesses + walk geometry + footsteps) -- compare with
//                         main.scn.camera to see how much of a swipe step is
//                         SceneKit waiting.
//
//   MAIN THREAD, RECEIVING TOUCHES (no SceneKit involved)
//    main.touch.deliver   every touch-down and touch-move: the system's touch
//                         time -> the app's watcher seeing it. Late delivery
//                         means the main thread was occupied (by anything --
//                         SceneKit waits included) when the touch arrived.
//
//  Where they appear (Settings > Share Diagnostics):
//   - every PERFORMANCE second line gets "| timing ..." with that second's
//     exact distributions (series with no samples are left out);
//   - a FRAME TIMING block in the report: the run's conditions (frame-rate
//     setting, screen rate, debugger attached, Metal HUD env), then the
//     distributions over the LAST 120 SECONDS and SINCE LAUNCH.
//  Bounded memory: per second, at most 8192 samples kept per series (counts,
//  totals and max stay exact past that); windows are log-bucket histograms.
//
//  On with PerfMonitor (DEBUG builds; Release with -HallwaysPerf YES).
//

import Foundation
import Darwin

nonisolated enum TimingSeries: Int, CaseIterable, Sendable {
    case renderCallbackSpan, renderUpdateToDid, renderDidToUpdate
    case scnPose, scnCamera, scnDoorFrac, pan
    case touchDeliver

    var name: String {
        switch self {
        case .renderCallbackSpan: return "render.callbackSpan"
        case .renderUpdateToDid: return "render.updateToDid"
        case .renderDidToUpdate: return "render.didToUpdate"
        case .scnPose: return "main.scn.pose"
        case .scnCamera: return "main.scn.camera"
        case .scnDoorFrac: return "main.scn.doorFrac"
        case .pan: return "main.pan"
        case .touchDeliver: return "main.touch.deliver"
        }
    }

    /// Series whose time is the main thread inside a SceneKit call.
    var isMainSceneKit: Bool { self == .scnPose || self == .scnCamera || self == .scnDoorFrac }
}

nonisolated final class FrameTiming: @unchecked Sendable {
    static let shared = FrameTiming()

    /// Start a timing: `let t = FrameTiming.start()` ... `FrameTiming.shared.record(.scnPose, since: t)`.
    /// 0 when measuring is off (then record ignores it).
    @inline(__always) static func start() -> UInt64 { PerfMonitor.enabled ? PerfMonitor.now() : 0 }

    private let lock = NSLock()
    private static let n = TimingSeries.allCases.count

    // per second: exact samples (capped) + exact count / total / max / over-counts
    private nonisolated struct Exact {
        var samples: [UInt64] = []
        var count = 0
        var total: UInt64 = 0
        var max: UInt64 = 0
        var over8 = 0, over16 = 0, over33 = 0
    }
    private static let samplesCap = 8192
    private var second = [Exact](repeating: Exact(), count: FrameTiming.n)

    // windows: log-bucket histograms (bucket k holds 1 us * 1.2^k .. 1.2^(k+1); 100 buckets reach ~80 s)
    private static let buckets = 100
    private nonisolated struct Hist {
        var b = [UInt32](repeating: 0, count: FrameTiming.buckets)
        var count = 0
        var total: UInt64 = 0
        var max: UInt64 = 0
        var over8 = 0, over16 = 0, over33 = 0
        mutating func add(_ o: Hist) {
            for i in 0..<b.count { b[i] &+= o.b[i] }
            count += o.count; total += o.total; max = Swift.max(max, o.max)
            over8 += o.over8; over16 += o.over16; over33 += o.over33
        }
    }
    private var secondHist = [Hist](repeating: Hist(), count: FrameTiming.n)
    private var sinceLaunch = [Hist](repeating: Hist(), count: FrameTiming.n)
    private static let windowSeconds = 120
    private var window: [[Hist]] = []                     // ring of per-second histograms
    private var windowHead = 0

    // render-thread frame stamps
    private var updateNs: UInt64 = 0
    private var willNs: UInt64 = 0
    private var didNs: UInt64 = 0

    // conditions (set once, main thread)
    private var conditions: [String] = []

    // MARK: Recording (any thread)

    func record(_ s: TimingSeries, since start: UInt64) {
        guard start != 0 else { return }
        let now = PerfMonitor.now()
        guard now > start else { return }
        record(s, ns: now - start)
    }

    func record(_ s: TimingSeries, ns: UInt64) {
        guard PerfMonitor.enabled else { return }
        let k = Self.bucket(ns)
        lock.lock()
        let i = s.rawValue
        var e = second[i]
        if e.samples.count < Self.samplesCap { e.samples.append(ns) }
        e.count += 1; e.total += ns; if ns > e.max { e.max = ns }
        if ns >= 8_000_000 { e.over8 += 1 }
        if ns >= 16_000_000 { e.over16 += 1 }
        if ns >= 33_000_000 { e.over33 += 1 }
        second[i] = e
        secondHist[i].b[k] &+= 1
        secondHist[i].count += 1; secondHist[i].total += ns
        if ns > secondHist[i].max { secondHist[i].max = ns }
        if ns >= 8_000_000 { secondHist[i].over8 += 1 }
        if ns >= 16_000_000 { secondHist[i].over16 += 1 }
        if ns >= 33_000_000 { secondHist[i].over33 += 1 }
        lock.unlock()
    }

    @inline(__always) private static func bucket(_ ns: UInt64) -> Int {
        let us = Double(ns) / 1000
        guard us > 1 else { return 0 }
        return min(buckets - 1, Int(log(us) / log(1.2)))
    }

    /// Upper edge of bucket k, in ms (a histogram percentile is "at most this").
    private static func bucketTopMs(_ k: Int) -> Double { pow(1.2, Double(k + 1)) / 1000 }

    // MARK: Render thread (SceneKit delegate)

    func rendererUpdate() {
        guard PerfMonitor.enabled else { return }
        let t = PerfMonitor.now()
        let did = lock.withLock { () -> UInt64 in
            let d = didNs
            updateNs = t
            return d
        }
        if did != 0, t > did, t - did < 1_000_000_000 { record(.renderDidToUpdate, ns: t - did) }
    }

    func rendererWillRender() {
        guard PerfMonitor.enabled else { return }
        let t = PerfMonitor.now()
        lock.withLock { willNs = t }
    }

    func rendererDidRender() {
        guard PerfMonitor.enabled else { return }
        let t = PerfMonitor.now()
        let (u, w) = lock.withLock { () -> (UInt64, UInt64) in
            let r = (updateNs, willNs)
            didNs = t
            updateNs = 0
            willNs = 0
            return r
        }
        if w != 0, t > w { record(.renderCallbackSpan, ns: t - w) }
        if u != 0, t > u { record(.renderUpdateToDid, ns: t - u) }
    }

    // MARK: Touches (main thread)

    /// A touch-down or touch-move reached the app; `eventTime` is the system's
    /// touch time (the same clock as CACurrentMediaTime / systemUptime).
    func touchDelivered(eventTime: TimeInterval) {
        guard PerfMonitor.enabled else { return }
        let lag = ProcessInfo.processInfo.systemUptime - eventTime
        guard lag >= 0, lag < 10 else { return }
        record(.touchDeliver, ns: UInt64(lag * 1e9))
    }

    // MARK: Conditions (main thread, at floor install)

    func noteConditions(preferredFPS: Int, fpsArgument: Int?, screenMaxFPS: Int?) {
        guard PerfMonitor.enabled else { return }
        let hud = ProcessInfo.processInfo.environment["MTL_HUD_ENABLED"] ?? "unset"
        let c = [
            "SCNView.preferredFramesPerSecond = \(preferredFPS) (-HallwaysFPS: \(fpsArgument.map(String.init) ?? "not set"))",
            "screen maximumFramesPerSecond = \(screenMaxFPS.map(String.init) ?? "?")",
            "debugger attached = \(Self.debuggerAttached() ? "YES" : "no")",
            "MTL_HUD_ENABLED (scheme env) = \(hud)  (the device's own Developer > Metal HUD switch can't be seen from here)",
        ]
        let changed = lock.withLock { () -> Bool in
            guard c != conditions else { return false }
            conditions = c
            return true
        }
        if changed {
            diag("timing.conditions", ["preferredFPS": preferredFPS, "fpsArgument": fpsArgument.map(String.init) ?? "none",
                                       "screenMaxFPS": screenMaxFPS.map(String.init) ?? "?",
                                       "debugger": Self.debuggerAttached(), "metalHUDEnv": hud])
        }
    }

    static func debuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    // MARK: Once a second (PerfMonitor's watchdog queue)

    /// This second's distributions as one line fragment; resets the second.
    func closeSecond() -> String {
        guard PerfMonitor.enabled else { return "" }
        lock.lock()
        let exact = second
        let hists = secondHist
        second = [Exact](repeating: Exact(), count: Self.n)
        secondHist = [Hist](repeating: Hist(), count: Self.n)
        for i in 0..<Self.n { sinceLaunch[i].add(hists[i]) }
        if window.count < Self.windowSeconds { window.append(hists) } else {
            window[windowHead] = hists
            windowHead = (windowHead + 1) % Self.windowSeconds
        }
        lock.unlock()

        var parts: [String] = []
        var mainSceneKitNs: UInt64 = 0
        for s in TimingSeries.allCases {
            let e = exact[s.rawValue]
            guard e.count > 0 else { continue }
            if s.isMainSceneKit { mainSceneKitNs += e.total }
            let sorted = e.samples.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
            var p = "\(s.name) \(e.count)x avg \(Self.ms(e.total / UInt64(e.count))) p95 \(Self.ms(p95)) max \(Self.ms(e.max))"
            if e.over8 > 0 { p += " >8:\(e.over8)" }
            if e.over16 > 0 { p += " >16:\(e.over16)" }
            if e.over33 > 0 { p += " >33:\(e.over33)" }
            if s == .renderCallbackSpan || s == .renderUpdateToDid || s == .renderDidToUpdate {
                p += " (\(String(format: "%.0f", Double(e.total) / 1e7))% of s)"          // (total ms / 1000 ms * 100)
            }
            parts.append(p)
        }
        guard !parts.isEmpty else { return "" }
        if mainSceneKitNs > 0 { parts.append("main in SceneKit calls \(Self.ms(mainSceneKitNs))ms") }
        return parts.joined(separator: "; ")
    }

    @inline(__always) private static func ms(_ ns: UInt64) -> String { String(format: "%.2f", Double(ns) / 1e6) }

    // MARK: Report (any thread)

    func report() -> String {
        guard PerfMonitor.enabled else { return "" }
        lock.lock()
        let cond = conditions
        let launch = sinceLaunch
        var recent = [Hist](repeating: Hist(), count: Self.n)
        for sec in window { for i in 0..<Self.n { recent[i].add(sec[i]) } }
        let secondsInWindow = window.count
        lock.unlock()

        var r = "==================== FRAME TIMING (FrameTiming, measurement only) ====================\n"
        r += "Conditions (as of the last floor install):\n"
        r += cond.isEmpty ? "  (not recorded yet)\n" : cond.map { "  " + $0 + "\n" }.joined()
        r += """
        Distributions in ms. p50/p95/p99 from log buckets: each is "at most" that value (within 20%); \
        count, avg, max and the >8/>16/>33 ms counts are exact. render.callbackSpan is the span between \
        SceneKit's willRender and didRender callbacks, not a measured lock hold. "% of time" = total / window length.

        """
        func block(_ title: String, _ h: [Hist], seconds: Double) {
            r += "\n\(title)\n"
            r += "  series                 count     avg     p50     p95     p99      max   >8ms  >16ms  >33ms  %time\n"
            for s in TimingSeries.allCases {
                let x = h[s.rawValue]
                guard x.count > 0 else { r += "  " + s.name.padding(toLength: 22, withPad: " ", startingAt: 0) + "      0\n"; continue }
                func pct(_ q: Double) -> String {
                    let target = Int((Double(x.count) * q).rounded(.up))
                    var run = 0
                    for k in 0..<x.b.count {
                        run += Int(x.b[k])
                        if run >= target { return String(format: "%7.2f", Self.bucketTopMs(k)) }
                    }
                    return "      ?"
                }
                let avg = Double(x.total) / Double(x.count) / 1e6
                let share = seconds > 0 ? Double(x.total) / 1e9 / seconds * 100 : 0
                r += "  " + s.name.padding(toLength: 22, withPad: " ", startingAt: 0)
                r += String(format: " %6d %7.2f ", x.count, avg) + pct(0.5) + " " + pct(0.95) + " " + pct(0.99)
                r += String(format: " %8.2f %6d %6d %6d %5.1f%%\n", Double(x.max) / 1e6, x.over8, x.over16, x.over33, share)
            }
        }
        block("LAST \(secondsInWindow) SECONDS:", recent, seconds: Double(secondsInWindow))
        block("SINCE LAUNCH:", launch, seconds: PerfMonitor.shared.secondsSinceLaunch)
        r += "==================== END FRAME TIMING ====================\n\n"
        return r
    }
}
