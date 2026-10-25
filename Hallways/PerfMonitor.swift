//
//  PerfMonitor.swift
//  Hallways
//
//  Oct 21 (night) -- MEASUREMENT ONLY. "Diagnose intermittent whole-app
//  slowdown": the iPhone sometimes turns sluggish for a while (gestures,
//  zoom, the phone badge's blink, Building Life scrolling, sometimes even
//  the Xcode console) and then recovers by itself, while automatic walks
//  can look normal. This is the evidence-gatherer. It changes no gameplay.
//
//  What it records (developer builds: always in DEBUG; in a Release build
//  only with the launch argument `-HallwaysPerf YES`):
//
//   - MAIN THREAD. A run-loop observer on the main run loop times every
//     stretch of work between two sleeps: busy % per second, the longest
//     stretch, how many ran over 50 / 250 ms. A stretch still running is
//     seen from the background watchdog ("stuck N ms in <section>").
//   - WATCHDOG. Its own high-priority serial queue, every 100 ms, touching
//     no UIKit / SwiftUI / SceneKit: reads only this class's counters (under
//     a lock) and Mach / ProcessInfo facts. Its own lateness is recorded too:
//     a late watchdog means the whole process (or phone) was starved, not
//     just the main thread.
//   - RENDER. SceneKit's frame gaps (from didRenderScene), frames per second.
//   - AUTO-WALK. Metres actually walked per second, per walk kind (latched
//     WALK cruise / held finger / tap walk), and how often the renderer's
//     per-frame time step hit its 1/20 s clamp -- measured, not assumed.
//   - CPU. Whole process, the main thread, the render thread, the busiest
//     other thread (Mach thread_info, once a second).
//   - MEMORY. phys_footprint (what iOS's memory limit counts), once a second.
//   - THERMAL / Low Power Mode, once a second.
//   - SECTIONS. Named timings around the recurring work (life tick, car step,
//     door-sound sampling, walk-geometry builds, cruise guidance, path
//     searches, follow / lead / eye ticks, the Hallwaysian display link, the
//     30 s state snapshot and its scene census, the renderer update, the held
//     walk tick): count, total and max per second -- aggregated, never logged
//     per call.
//   - LOGGING. Flight-recorder lines per second and its write backlog;
//     console prints per second and the time each print blocked its thread.
//   - LIVE COUNTS. Navigation controllers alive, door-sound timers, eye
//     timers, running leads, Hallwaysian bodies on the display link, follow.
//
//  History is bounded: the last 600 one-second summaries (10 minutes) in a
//  ring, plus the last 4 detected episodes (30 s before through 30 s after,
//  at most 300 s each). Nothing is written to disk per frame; an episode's
//  start and end and a compact summary every 30 s go to the existing flight
//  recorder (Settings > Share Diagnostics), and the whole history is added
//  to the top of that shared report.
//

import Foundation
import Darwin

nonisolated final class PerfMonitor: @unchecked Sendable {
    static let shared = PerfMonitor()

    /// DEBUG builds always; Release only with `-HallwaysPerf YES`.
    static let enabled: Bool = {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "HallwaysPerf")
        #endif
    }()

    /// Monotonic nanoseconds (mach_absolute_time based; never jumps with the clock).
    @inline(__always) static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static let historySeconds = 600
    static let episodesKept = 4
    static let episodeSecondsCap = 300

    // MARK: State (all under `lock`)

    private let lock = NSLock()
    private var started = false
    private let launchNs = PerfMonitor.now()

    // main run loop
    private var busySince: UInt64 = 0            // 0: the main thread is asleep (waiting for events)
    private var busyNs: UInt64 = 0
    private var longestNs: UInt64 = 0
    private var over50 = 0, over250 = 0, over1000 = 0
    private var iterations = 0
    private var stuckMaxNs: UInt64 = 0
    private var stuckIn = ""
    private var mainSection: Int = 0              // key of the section the main thread is inside (0: none)
    private var mainPort: mach_port_t = 0

    // render
    private var lastFrameNs: UInt64 = 0
    private var frames = 0
    private var frameGapMaxNs: UInt64 = 0
    private var frameGapsOver50 = 0, frameGapsOver250 = 0
    private var renderPort: mach_port_t = 0

    // auto-walk
    private var walkMetres: [Double] = [0, 0, 0]  // cruise, held, tap/other
    private var walkStepSeconds = 0.0
    private var walkRawSeconds = 0.0
    private var walkClamps = 0

    // sections
    private nonisolated struct Agg { var count = 0; var totalNs: UInt64 = 0; var maxNs: UInt64 = 0 }
    private var names: [Int: String] = [:]
    private var perSecond: [Int: Agg] = [:]
    private var sinceLaunch: [Int: Agg] = [:]

    // logging
    private var diagLines = 0
    private var recorderBacklog = 0
    private var recorderBacklogMax = 0
    private var prints = 0
    private var printNs: UInt64 = 0
    private var printMaxNs: UInt64 = 0
    private var printsSuppressed = 0

    // live counts (cumulative gauges)
    private var gauges: [Int: Int] = [:]

    // marks in the current second
    private var marks: [String] = []

    // watchdog (queue-confined, but read for the report under the lock)
    private var lastTickNs: UInt64 = 0
    private var watchdogLateMaxNs: UInt64 = 0
    private var ticksThisSecond = 0
    private var secondStartNs: UInt64 = 0

    // history
    private var ring: [Second] = []
    private var ringHead = 0
    private var episodes: [Episode] = []
    private var openEpisode: Episode?
    private var goodRun = 0
    private var lastSummaryT = 0.0
    private var lastFloor: Int?

    private let queue = DispatchQueue(label: "Hallways.PerfMonitor", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var observer: CFRunLoopObserver?

    // MARK: One second

    nonisolated struct SectionSample { var name: String; var count: Int; var totalMs: Double; var maxMs: Double }

    nonisolated struct Second {
        var t: Double = 0                 // seconds since launch
        var floor: Int?
        var mainBusyPct = 0.0
        var mainLongestMs = 0.0
        var mainOver50 = 0, mainOver250 = 0
        var mainStuckMs = 0.0             // longest still-running stretch the watchdog saw
        var mainStuckIn = ""
        var frames = 0
        var frameGapMaxMs = 0.0
        var frameGapsOver50 = 0
        var walkMetres: [Double] = [0, 0, 0]
        var walkClamps = 0
        var walkStepSeconds = 0.0, walkRawSeconds = 0.0
        var cpuTotal = -1.0, cpuMain = -1.0, cpuRender = -1.0, cpuOtherMax = -1.0
        var threads = 0
        var memMB = -1.0
        var thermal = ""
        var lowPower = false
        var watchdogLateMs = 0.0
        var diagLines = 0, backlogMax = 0
        var prints = 0, printMaxMs = 0.0, printTotalMs = 0.0, printsSuppressed = 0
        var sections: [SectionSample] = []
        var gauges = ""
        var marks: [String] = []
        var timing = ""                   // Oct 24: FrameTiming's distributions this second

        /// The thresholds an "episode" second crosses (any one).
        var isBad: Bool {
            mainBusyPct >= 70 || mainLongestMs >= 250 || mainStuckMs >= 250
                || frameGapMaxMs >= 250 || watchdogLateMs >= 250
        }

        var line: String {
            func f(_ v: Double, _ d: Int = 0) -> String { v < 0 ? "?" : String(format: "%.\(d)f", v) }
            var s = String(format: "%7.1f", t) + " F" + (floor.map(String.init) ?? "?")
            s += " | main \(f(mainBusyPct))% long \(f(mainLongestMs))ms >50:\(mainOver50) >250:\(mainOver250)"
            if mainStuckMs > 0 { s += " STUCK \(f(mainStuckMs))ms@\(mainStuckIn.isEmpty ? "-" : mainStuckIn)" }
            s += " | fps \(frames) gap \(f(frameGapMaxMs))ms >50:\(frameGapsOver50)"
            if walkStepSeconds > 0 || walkMetres.contains(where: { $0 > 0 }) {
                s += " | walk c\(f(walkMetres[0], 2)) h\(f(walkMetres[1], 2)) t\(f(walkMetres[2], 2))m step \(f(walkStepSeconds, 2))/\(f(walkRawSeconds, 2))s clamp \(walkClamps)"
            }
            s += " | cpu \(f(cpuTotal))% main \(f(cpuMain))% rend \(f(cpuRender))% other \(f(cpuOtherMax))% thr \(threads)"
            s += " | mem \(f(memMB))MB \(thermal)\(lowPower ? " LPM" : "")"
            s += " | wdLate \(f(watchdogLateMs))ms"
            s += " | log diag \(diagLines) backlog \(backlogMax) print \(prints)"
            if prints > 0 { s += " (\(f(printTotalMs, 1))ms max \(f(printMaxMs, 1)))" }
            if printsSuppressed > 0 { s += " quiet \(printsSuppressed)" }
            if !sections.isEmpty {
                s += " | " + sections.map { "\($0.name) \($0.count)x \(String(format: "%.1f", $0.totalMs))ms max \(String(format: "%.1f", $0.maxMs))" }.joined(separator: ", ")
            }
            if !gauges.isEmpty { s += " | live " + gauges }
            if !marks.isEmpty { s += " | MARK " + marks.joined(separator: ";") }
            if !timing.isEmpty { s += " | timing " + timing }
            return s
        }
    }

    nonisolated struct Episode {
        var startT: Double
        var endT: Double?
        var worst: Second
        var seconds: [Second] = []
        var captured = false
    }

    // MARK: Start (main thread, once at launch)

    func start() {
        guard Self.enabled else { return }
        let first = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            mainPort = pthread_mach_thread_np(pthread_self())
            secondStartNs = Self.now()
            lastTickNs = secondStartNs
            return true
        }
        guard first, pthread_main_np() != 0 else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let obs = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, 0) { [weak self] _, activity in
            self?.runLoop(activity)
        }
        if let obs { CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes) }
        observer = obs
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.watchdogTick() }
        timer = t
        t.resume()
        let on = PerfSwitches.activeList
        diag("perf.start", ["switches": on.isEmpty ? "none" : on.joined(separator: ",")])
        if !on.isEmpty {
            Swift.print("[Perf] EXPERIMENT SWITCHES ON: \(on.joined(separator: ", ")) -- see PerfSwitches")
        }
    }

    // MARK: Main run loop (main thread)

    private func runLoop(_ activity: CFRunLoopActivity) {
        let t = Self.now()
        lock.lock()
        if activity == .afterWaiting {
            busySince = t
        } else if busySince != 0 {
            let d = t - busySince
            busySince = 0
            busyNs += d
            iterations += 1
            if d > longestNs { longestNs = d }
            if d >= 50_000_000 { over50 += 1 }
            if d >= 250_000_000 { over250 += 1 }
            if d >= 1_000_000_000 { over1000 += 1 }
        }
        lock.unlock()
    }

    // MARK: Sections (any thread)

    nonisolated struct Token {
        fileprivate let key: Int
        fileprivate let start: UInt64
        fileprivate let previousMain: Int
        fileprivate let onMain: Bool
    }

    @inline(__always) private static func key(_ name: StaticString) -> Int {
        name.hasPointerRepresentation ? Int(bitPattern: name.utf8Start) : Int(name.unicodeScalar.value)
    }

    /// `let t = PerfMonitor.begin("life.tick"); defer { PerfMonitor.end(t) }`
    static func begin(_ name: StaticString) -> Token {
        guard enabled else { return Token(key: 0, start: 0, previousMain: 0, onMain: false) }
        let k = key(name)
        let onMain = pthread_main_np() != 0
        let m = shared
        m.lock.lock()
        if m.names[k] == nil { m.names[k] = "\(name)" }
        let previous = m.mainSection
        if onMain { m.mainSection = k }
        m.lock.unlock()
        return Token(key: k, start: now(), previousMain: previous, onMain: onMain)
    }

    static func end(_ token: Token) {
        guard token.start != 0 else { return }
        let d = now() - token.start
        let m = shared
        m.lock.lock()
        if token.onMain { m.mainSection = token.previousMain }
        var a = m.perSecond[token.key] ?? Agg()
        a.count += 1; a.totalNs += d; if d > a.maxNs { a.maxNs = d }
        m.perSecond[token.key] = a
        var b = m.sinceLaunch[token.key] ?? Agg()
        b.count += 1; b.totalNs += d; if d > b.maxNs { b.maxNs = d }
        m.sinceLaunch[token.key] = b
        m.lock.unlock()
    }

    /// Oct 22 (evening): a time measured elsewhere, counted as a section sample
    /// (e.g. "input.lag": how late a touch reached the app).
    static func record(_ name: StaticString, ns: UInt64) {
        guard enabled else { return }
        let k = key(name)
        let m = shared
        m.lock.lock()
        if m.names[k] == nil { m.names[k] = "\(name)" }
        var a = m.perSecond[k] ?? Agg()
        a.count += 1; a.totalNs += ns; if ns > a.maxNs { a.maxNs = ns }
        m.perSecond[k] = a
        var b = m.sinceLaunch[k] ?? Agg()
        b.count += 1; b.totalNs += ns; if ns > b.maxNs { b.maxNs = ns }
        m.sinceLaunch[k] = b
        m.lock.unlock()
    }

    /// Live counts: `PerfMonitor.gauge("doorSoundTimers", +1)`.
    static func gauge(_ name: StaticString, _ delta: Int) {
        guard enabled else { return }
        let k = key(name)
        let m = shared
        m.lock.lock()
        if m.names[k] == nil { m.names[k] = "\(name)" }
        m.gauges[k, default: 0] += delta
        m.lock.unlock()
    }

    /// A marker in the history (Settings' "Mark Slowdown Now", or code).
    func mark(_ text: String) {
        guard Self.enabled else { return }
        lock.withLock { if marks.count < 8 { marks.append(text) } }
        diag("perf.mark", ["text": text])
    }

    // MARK: Render thread

    func frameRendered() {
        guard Self.enabled else { return }
        let t = Self.now()
        let port = pthread_mach_thread_np(pthread_self())
        lock.lock()
        renderPort = port
        frames += 1
        if lastFrameNs != 0, t > lastFrameNs {
            let gap = t - lastFrameNs
            if gap > frameGapMaxNs { frameGapMaxNs = gap }
            if gap >= 50_000_000 { frameGapsOver50 += 1 }
            if gap >= 250_000_000 { frameGapsOver250 += 1 }
        }
        lastFrameNs = t
        lock.unlock()
        MudProbe.shared.frameRendered()                                      // Oct 24 (mud probe): an input's first frame
    }

    /// Walk kinds for `walkFrame`.
    nonisolated enum WalkKind: Int { case cruise = 0, held = 1, tap = 2 }

    /// One renderer update while the player is moving: how far the camera
    /// actually went, the time step used, the raw time since the last update.
    func walkFrame(_ kind: WalkKind, metres: Double, step: Double, raw: Double) {
        guard Self.enabled else { return }
        lock.lock()
        walkMetres[kind.rawValue] += metres
        walkStepSeconds += step
        walkRawSeconds += raw
        if raw > step + 0.0005 { walkClamps += 1 }
        lock.unlock()
        MudProbe.shared.walkMoved(metres: metres)                            // Oct 24 (mud probe): a walk's first step
    }

    // MARK: Logging counters (any thread)

    func diagEnqueued() {
        guard Self.enabled else { return }
        lock.lock()
        diagLines += 1
        recorderBacklog += 1
        if recorderBacklog > recorderBacklogMax { recorderBacklogMax = recorderBacklog }
        lock.unlock()
    }

    func diagWritten() {
        guard Self.enabled else { return }
        lock.lock(); recorderBacklog = max(0, recorderBacklog - 1); lock.unlock()
    }

    func printed(ns: UInt64, suppressed: Bool) {
        guard Self.enabled else { return }
        lock.lock()
        if suppressed { printsSuppressed += 1 } else {
            prints += 1
            printNs += ns
            if ns > printMaxNs { printMaxNs = ns }
        }
        lock.unlock()
    }

    // MARK: Watchdog (its own queue; never UIKit / SwiftUI / SceneKit)

    private func watchdogTick() {
        let t = Self.now()
        var closeSecond = false
        lock.lock()
        let late = t > lastTickNs + 100_000_000 ? t - lastTickNs - 100_000_000 : 0
        if late > watchdogLateMaxNs { watchdogLateMaxNs = late }
        lastTickNs = t
        if busySince != 0, t > busySince {                 // (the main thread may have stamped after `t`)
            let stuck = t - busySince
            if stuck > stuckMaxNs {
                stuckMaxNs = stuck
                stuckIn = mainSection == 0 ? "" : (names[mainSection] ?? "")
            }
        }
        ticksThisSecond += 1
        if t - secondStartNs >= 1_000_000_000 { closeSecond = true }
        lock.unlock()
        if closeSecond { finishSecond(at: t) }
    }

    private func finishSecond(at t: UInt64) {
        // Facts that don't need the lock first (Mach / ProcessInfo are thread-safe).
        let (mainPortNow, renderPortNow) = lock.withLock { (mainPort, renderPort) }
        let cpu = Self.threadCPU(main: mainPortNow, render: renderPortNow)
        let mem = Self.footprintMB()
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "SERIOUS"
        case .critical: thermal = "CRITICAL"
        @unknown default: thermal = "?"
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let floor = DiagnosticRecorder.shared.floor
        let timing = FrameTiming.shared.closeSecond()                       // Oct 24 (its own lock; taken before ours)

        lock.lock()
        let wall = Double(t - secondStartNs) / 1e9
        var s = Second()
        s.t = Double(t - launchNs) / 1e9
        s.floor = floor
        // a stretch still running counts toward this second's busy time
        var busy = busyNs
        if busySince != 0, busySince < t {
            busy += t - max(busySince, secondStartNs)
        }
        s.mainBusyPct = min(100, Double(busy) / 1e9 / max(wall, 0.001) * 100)
        s.mainLongestMs = Double(longestNs) / 1e6
        s.mainOver50 = over50
        s.mainOver250 = over250
        s.mainStuckMs = Double(stuckMaxNs) / 1e6
        s.mainStuckIn = stuckIn
        s.frames = frames
        s.frameGapMaxMs = Double(frameGapMaxNs) / 1e6
        // a renderer that stopped altogether shows as one long gap
        if lastFrameNs != 0, t > lastFrameNs, Double(t - lastFrameNs) / 1e6 > s.frameGapMaxMs {
            s.frameGapMaxMs = Double(t - lastFrameNs) / 1e6
        }
        s.frameGapsOver50 = frameGapsOver50
        s.walkMetres = walkMetres
        s.walkClamps = walkClamps
        s.walkStepSeconds = walkStepSeconds
        s.walkRawSeconds = walkRawSeconds
        s.cpuTotal = cpu.total
        s.cpuMain = cpu.main
        s.cpuRender = cpu.render
        s.cpuOtherMax = cpu.otherMax
        s.threads = cpu.threads
        s.memMB = mem
        s.thermal = thermal
        s.lowPower = lowPower
        s.watchdogLateMs = Double(watchdogLateMaxNs) / 1e6
        s.diagLines = diagLines
        s.backlogMax = recorderBacklogMax
        s.prints = prints
        s.printTotalMs = Double(printNs) / 1e6
        s.printMaxMs = Double(printMaxNs) / 1e6
        s.printsSuppressed = printsSuppressed
        s.sections = perSecond.sorted { $0.value.totalNs > $1.value.totalNs }.prefix(6).map {
            SectionSample(name: names[$0.key] ?? "?", count: $0.value.count,
                          totalMs: Double($0.value.totalNs) / 1e6, maxMs: Double($0.value.maxNs) / 1e6)
        }
        s.gauges = gauges.filter { $0.value != 0 }.map { "\(names[$0.key] ?? "?")=\($0.value)" }.sorted().joined(separator: " ")
        s.marks = marks
        s.timing = timing
        if floor != lastFloor {
            s.marks.append("floor \(lastFloor.map(String.init) ?? "?")->\(floor.map(String.init) ?? "?")")
            lastFloor = floor
        }
        // reset the second
        busyNs = 0; longestNs = 0; over50 = 0; over250 = 0; iterations = 0
        stuckMaxNs = 0; stuckIn = ""
        frames = 0; frameGapMaxNs = 0; frameGapsOver50 = 0; frameGapsOver250 = 0
        walkMetres = [0, 0, 0]; walkStepSeconds = 0; walkRawSeconds = 0; walkClamps = 0
        perSecond.removeAll(keepingCapacity: true)
        diagLines = 0; recorderBacklogMax = recorderBacklog
        prints = 0; printNs = 0; printMaxNs = 0; printsSuppressed = 0
        marks.removeAll()
        watchdogLateMaxNs = 0
        ticksThisSecond = 0
        secondStartNs = t
        let events = store(s)
        lock.unlock()
        for e in events { diag(e.event, e.fields) }
    }

    private nonisolated struct Note { let event: String; let fields: KeyValuePairs<String, Any?> }

    /// Ring + episodes (under the lock). Returns flight-recorder lines to write after unlocking.
    private func store(_ s: Second) -> [Note] {
        var notes: [Note] = []
        if ring.count < Self.historySeconds { ring.append(s) } else { ring[ringHead] = s; ringHead = (ringHead + 1) % Self.historySeconds }

        if s.isBad {
            goodRun = 0
            if var e = openEpisode {
                if e.endT != nil {                       // bad again within 30 s of its end: the same episode
                    e.endT = nil
                    notes.append(Note(event: "perf.episode.resumed", fields: ["line": s.line]))
                }
                if Self.severity(s) > Self.severity(e.worst) { e.worst = s }
                openEpisode = e
            } else {
                openEpisode = Episode(startT: s.t, endT: nil, worst: s)
                notes.append(Note(event: "perf.episode.start", fields: ["line": s.line]))
            }
        } else if var e = openEpisode, e.endT == nil {
            goodRun += 1
            if goodRun >= 5 {
                e.endT = s.t
                openEpisode = e
                notes.append(Note(event: "perf.episode.end", fields: ["seconds": String(format: "%.0f", s.t - e.startT), "worst": e.worst.line]))
            }
        }
        // 30 s after an episode ends, its window is copied out of the ring.
        if var e = openEpisode, let end = e.endT, s.t >= end + 30 {
            e.seconds = Array(orderedRing().filter { $0.t >= e.startT - 30 && $0.t <= s.t }.suffix(Self.episodeSecondsCap))
            e.captured = true
            episodes.append(e)
            if episodes.count > Self.episodesKept { episodes.removeFirst(episodes.count - Self.episodesKept) }
            openEpisode = nil
        }
        if s.t - lastSummaryT >= 30 {
            lastSummaryT = s.t
            notes.append(Note(event: "perf.summary", fields: ["line": s.line]))
        }
        return notes
    }

    private static func severity(_ s: Second) -> Double {
        max(s.mainLongestMs, s.mainStuckMs, s.frameGapMaxMs, s.watchdogLateMs) + s.mainBusyPct * 5
    }

    private func orderedRing() -> [Second] {
        ring.count < Self.historySeconds ? ring : Array(ring[ringHead...] + ring[..<ringHead])
    }

    // MARK: Report (for the shared diagnostics; any thread)

    func report() -> String {
        guard Self.enabled else { return "PERFORMANCE: off in this build (Release without -HallwaysPerf YES).\n\n" }
        lock.lock()
        let seconds = orderedRing()
        let eps = episodes
        let current = openEpisode
        let totals = sinceLaunch.sorted { $0.value.totalNs > $1.value.totalNs }.prefix(20).map {
            (names[$0.key] ?? "?", $0.value)
        }
        let live = gauges.map { "\(names[$0.key] ?? "?")=\($0.value)" }.sorted().joined(separator: " ")
        let up = Double(Self.now() - launchNs) / 1e9
        lock.unlock()

        var r = "==================== PERFORMANCE (PerfMonitor) ====================\n"
        r += String(format: "Up %.0f s. Experiment switches: %@.\n", up, PerfSwitches.activeList.isEmpty ? "none" : PerfSwitches.activeList.joined(separator: ", "))
        r += """
        Each line is ONE SECOND: t (s since launch) floor | main = main-thread busy %, longest uninterrupted stretch, \
        stretches over 50/250 ms, STUCK = a stretch still running when the watchdog looked (and the section it was in) \
        | fps = frames SceneKit rendered, longest gap between frames | walk = metres moved by the cruise (c) / held (h) / \
        tap (t) walks, renderer time step used/raw, clamped frames | cpu = process total (100 = one core), main thread, \
        render thread, busiest other thread, thread count | mem = phys_footprint, thermal state, LPM = Low Power Mode \
        | wdLate = how late the background watchdog itself ran (process-wide starvation) | log = flight-recorder lines, \
        its write backlog, console prints (time spent printing) | top sections by time this second | live counts | marks \
        | timing = FrameTiming's distributions this second (see FRAME TIMING below).

        """
        if let current, current.endT == nil {
            r += String(format: "\nEPISODE IN PROGRESS since t=%.0f. Worst so far:\n  %@\n", current.startT, current.worst.line)
        }
        r += "\nEPISODES (last \(Self.episodesKept); a second is bad when main busy >= 70%, a main stretch or frame gap >= 250 ms, or the watchdog ran >= 250 ms late):\n"
        if eps.isEmpty && current == nil { r += "  none detected\n" }
        for (i, e) in eps.enumerated() {
            r += String(format: "\n-- Episode %d: t=%.0f to t=%.0f (%.0f s). Worst second:\n  %@\n", i + 1, e.startT, e.endT ?? e.startT, (e.endT ?? e.startT) - e.startT, e.worst.line)
            for s in e.seconds { r += "  " + s.line + "\n" }
        }
        r += "\nSECTIONS SINCE LAUNCH (by total time): name count total max\n"
        for (name, a) in totals {
            r += String(format: "  %@ %d %.0f ms max %.1f ms\n", name, a.count, Double(a.totalNs) / 1e6, Double(a.maxNs) / 1e6)
        }
        r += "\nLIVE COUNTS NOW: \(live.isEmpty ? "-" : live)\n"
        r += "\nLAST \(seconds.count) SECONDS (oldest first):\n"
        for s in seconds { r += s.line + "\n" }
        r += "==================== END PERFORMANCE ====================\n\n"
        r += FrameTiming.shared.report()                                     // Oct 24: 30 vs 60 fps (measurement only)
        return r
    }

    // MARK: Mach (background-safe)

    private static func threadCPU(main: mach_port_t, render: mach_port_t) -> (total: Double, main: Double, render: Double, otherMax: Double, threads: Int) {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return (-1, -1, -1, -1, 0) }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0, mainCPU = 0.0, renderCPU = 0.0, other = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            let cpu = Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            total += cpu
            if list[i] == main { mainCPU = cpu } else if list[i] == render { renderCPU = cpu } else { other = max(other, cpu) }
        }
        return (total, mainCPU, renderCPU, other, Int(count))
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Oct 24 (FrameTiming): seconds since PerfMonitor started.
    var secondsSinceLaunch: Double { Double(Self.now() - launchNs) / 1e9 }

    // MARK: Tests

    /// Closes the current second now (tests only).
    func closeSecondForTests() { queue.sync { finishSecond(at: Self.now()) } }
    var historyCountForTests: Int { lock.withLock { ring.count } }
}

// MARK: - Experiment switches

/// Oct 21 -- developer-only EXPERIMENTS for the slowdown hunt. Each is a launch
/// argument (Xcode: Product > Scheme > Edit Scheme > Run > Arguments Passed On
/// Launch; tick to switch on), read once at launch, never saved: argument
/// values live in NSArgumentDomain and vanish when the argument is unticked.
/// Every one that is on is named at launch in the console ("[Perf]
/// EXPERIMENT SWITCHES ON"), in the flight recorder (`perf.start`), at the
/// top of the shared report, and in Settings.
///
///  -HallwaysPerfNoCensus YES       The 30 s state snapshot skips its whole-scene
///                                  node/light count (nodes=-1). Nothing else changes.
///  -HallwaysPerfQuietConsole YES   Console prints are dropped (still counted).
///                                  The flight recorder is untouched.
///  -HallwaysPerfSlowCruiseRebuild YES
///                                  TEST ONLY: the WALK cruise rebuilds its walk
///                                  geometry once a second instead of every 0.15 s
///                                  (its stop checks still run every 0.15 s). A door
///                                  that changes mid-walk is noticed up to ~1 s later.
///  -HallwaysPerfPauseLife YES      TEST ONLY: the residents' 1 Hz life tick
///                                  (decisions, wandering, errands) does not run --
///                                  residents stand where they are. The car's 4 Hz
///                                  step (the player's own elevator) still runs.
///                                  Records simply don't change, so nothing is saved
///                                  wrongly; next launch without it they catch up as
///                                  after a stay in the background. Don't use it for
///                                  onboarding or task guiding (those wait on residents).
nonisolated enum PerfSwitches {
    static let noCensus = UserDefaults.standard.bool(forKey: "HallwaysPerfNoCensus")
    static let quietConsole = UserDefaults.standard.bool(forKey: "HallwaysPerfQuietConsole")
    static let slowCruiseRebuild = UserDefaults.standard.bool(forKey: "HallwaysPerfSlowCruiseRebuild")
    static let pauseLife = UserDefaults.standard.bool(forKey: "HallwaysPerfPauseLife")

    static var activeList: [String] {
        var on: [String] = []
        if noCensus { on.append("NoCensus") }
        if quietConsole { on.append("QuietConsole") }
        if slowCruiseRebuild { on.append("SlowCruiseRebuild") }
        if pauseLife { on.append("PauseLife") }
        return on
    }
}

// MARK: - Console prints, counted and timed

/// Oct 21: every `print` in the app module comes here first (a module-level
/// function shadows the standard library's), so console volume and how long a
/// print blocks its thread -- a slow or backed-up Xcode console can block the
/// printing thread, the main thread included -- are measured. Prints exactly
/// what Swift.print would. With -HallwaysPerfQuietConsole YES, prints are dropped.
nonisolated func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    if PerfSwitches.quietConsole {
        PerfMonitor.shared.printed(ns: 0, suppressed: true)
        return
    }
    let text = items.map { "\($0)" }.joined(separator: separator)
    let t0 = PerfMonitor.now()
    Swift.print(text, terminator: terminator)
    PerfMonitor.shared.printed(ns: PerfMonitor.now() - t0, suppressed: false)
}
