//
//  DiagnosticRecorder.swift
//  Hallways
//
//  Oct 2 (beta: Carol's Floor 2 -> 3 elevator hang on an iPhone 15 Plus,
//  never reproducible on Eddie's phone): a tiny, local, persistent "flight
//  recorder". Plain-text lines, one event per line, appended to a file in
//  Application Support/Diagnostics. Each write is handed to the kernel
//  immediately (no in-process buffering), so a hang followed by a force
//  quit loses nothing already recorded. Two files roll (current +
//  previous, ~512 KB each), nothing is cleared at launch, and Settings ->
//  Share Diagnostics hands a snapshot of both to the iOS share sheet.
//
//  Never on the critical path: every write is fire-and-forget on a private
//  serial queue and every failure is swallowed. No gameplay state reads it.
//  No network, no personal data -- only Hallways' own state.
//

import Foundation
import os

nonisolated final class DiagnosticRecorder: @unchecked Sendable {
    static let shared = DiagnosticRecorder(directory: DiagnosticRecorder.defaultDirectory)

    static var defaultDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    let directory: URL
    let maxBytes: Int
    let sessionID: String
    var currentURL: URL { directory.appendingPathComponent("hallways-diagnostics.log") }
    var previousURL: URL { directory.appendingPathComponent("hallways-diagnostics.previous.log") }
    private var foregroundFlagURL: URL { directory.appendingPathComponent("foreground.flag") }

    private let queue = DispatchQueue(label: "Hallways.DiagnosticRecorder", qos: .utility)
    private let startUptime = ProcessInfo.processInfo.systemUptime
    private let version: String
    private let lock = NSLock()
    private var _floor: Int?
    private var _snapshotProvider: (@MainActor (String) -> Void)?
    private var _beats = 0
    private var _lastMainBeat = ProcessInfo.processInfo.systemUptime
    private var _watching = false
    // Queue-confined.
    private var handle: FileHandle?
    private var currentBytes = 0
    private var stallStarted: TimeInterval?
    private var stallReports = 0
    private var watchdog: DispatchSourceTimer?   // set once at launch
    private var mainBeat: DispatchSourceTimer?
    private let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(directory: URL, maxBytes: Int = 512 * 1024, sessionID: String = String(UUID().uuidString.prefix(8))) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.sessionID = sessionID
        let info = Bundle.main.infoDictionary
        version = "\(info?["CFBundleShortVersionString"] as? String ?? "?")(\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// The floor every line is stamped with (set by the scene build).
    var floor: Int? {
        get { lock.withLock { _floor } }
        set { lock.withLock { _floor = newValue } }
    }

    // MARK: Recording

    /// Fire-and-forget. Values are rendered on the caller's thread (cheap
    /// string work), then appended on the private queue.
    func record(_ event: String, _ fields: KeyValuePairs<String, Any?> = [:]) {
        let now = Date()
        let elapsed = ProcessInfo.processInfo.systemUptime - startUptime
        let floorText = floor.map { "F\($0)" } ?? "F?"
        let rendered = fields.map { "\($0.key)=\(Self.render($0.value))" }.joined(separator: " ")
        queue.async { [weak self] in
            guard let self else { return }
            let line = "\(self.timestampFormatter.string(from: now)) +\(String(format: "%.3f", elapsed))s S=\(self.sessionID) v=\(self.version) \(floorText) \(event)\(rendered.isEmpty ? "" : " " + rendered)\n"
            self.append(line)
        }
    }

    /// Writes the SESSION START block. Notes whether the previous session
    /// ended while the app was still in the foreground (crash, hang +
    /// force quit, or a kill) -- the only lifecycle fact reliably knowable.
    func startSession() {
        let previousInForeground = FileManager.default.fileExists(atPath: foregroundFlagURL.path)
        queue.async { [weak self] in
            self?.append("\n===================== SESSION START \(self?.sessionID ?? "?") =====================\n")
        }
        record("session.start", [
            "app": version,
            "ios": ProcessInfo.processInfo.operatingSystemVersionString,
            "device": Self.deviceModel,
            "previousSessionEndedInForeground": previousInForeground
        ])
    }

    /// scenePhase changes. Keeps the foreground flag for startSession and
    /// pauses the main-thread watchdog while backgrounded.
    func noteLifecycle(_ phase: String) {
        record("app.lifecycle", ["phase": phase])
        let active = phase == "active"
        lock.withLock {
            _watching = active
            _lastMainBeat = ProcessInfo.processInfo.systemUptime
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.stallStarted = nil
            self.stallReports = 0
            if phase == "background" {
                try? FileManager.default.removeItem(at: self.foregroundFlagURL)
            } else if active {
                self.ensureDirectory()
                FileManager.default.createFile(atPath: self.foregroundFlagURL.path, contents: nil)
            }
        }
    }

    // MARK: State snapshots (Oct 8)

    /// Seconds between periodic state snapshots while the app is active.
    static let snapshotInterval: TimeInterval = 30

    /// Installed by the scene: records ONE line of the current player/world
    /// state (see TapNavigationController.diagStateSnapshot). Reads only.
    var snapshotProvider: (@MainActor (String) -> Void)? {
        get { lock.withLock { _snapshotProvider } }
        set { lock.withLock { _snapshotProvider = newValue } }
    }

    /// Record a state snapshot now (if a scene is installed), tagged `reason`.
    @MainActor func snapshot(_ reason: String) {
        snapshotProvider?(reason)
    }

    /// Blocks until every queued write has reached the file (tests, share).
    func flush() { queue.sync {} }

    // MARK: Main-thread watchdog

    /// A main-queue heartbeat (every 0.5 s) and a background check (every
    /// 1 s). Logs when the main thread has been unresponsive for 2 s while
    /// active (again at 10 s, 30 s, 60 s) and when it recovers -- the one
    /// thing that can't log itself from a hung main thread.
    func startMainThreadWatchdog() {
        let beat = DispatchSource.makeTimerSource(queue: .main)
        beat.schedule(deadline: .now() + 0.5, repeating: 0.5)
        beat.setEventHandler { [weak self] in
            guard let self else { return }
            // Every `snapshotInterval` of active time, one state snapshot.
            let due = self.lock.withLock { () -> Bool in
                self._lastMainBeat = ProcessInfo.processInfo.systemUptime
                guard self._watching else { return false }
                self._beats += 1
                guard Double(self._beats) * 0.5 >= Self.snapshotInterval else { return false }
                self._beats = 0
                return true
            }
            if due { MainActor.assumeIsolated { self.snapshot("periodic") } }
        }
        let check = DispatchSource.makeTimerSource(queue: queue)
        check.schedule(deadline: .now() + 1, repeating: 1)
        check.setEventHandler { [weak self] in self?.checkMainThread() }
        // Called once at launch; held only to keep the timers alive.
        mainBeat = beat
        watchdog = check
        beat.resume()
        check.resume()
    }

    private func checkMainThread() {
        let (last, watching) = lock.withLock { (_lastMainBeat, _watching) }
        guard watching else { stallStarted = nil; stallReports = 0; return }
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - last
        if gap >= 2 {
            if stallStarted == nil { stallStarted = last; stallReports = 0 }
            let marks: [Double] = [2, 10, 30, 60]
            if stallReports < marks.count, gap >= marks[stallReports] {
                stallReports += 1
                record("watchdog.mainThreadUnresponsive", ["seconds": gap])
            }
        } else if let started = stallStarted {
            record("watchdog.mainThreadRecovered", ["stalledFor": now - started])
            stallStarted = nil
            stallReports = 0
        }
    }

    // MARK: Sharing

    /// Snapshot of previous + current log into a uniquely named temp file
    /// that can be shared while logging continues. Completion on main.
    func makeShareSnapshot(completion: @escaping @MainActor (URL?) -> Void) {
        queue.async { [weak self] in
            let url = self?.snapshotOnQueue()
            Task { @MainActor in completion(url) }
        }
    }

    /// Synchronous variant (tests).
    func makeShareSnapshotNow() -> URL? { queue.sync { snapshotOnQueue() } }

    private func snapshotOnQueue() -> URL? {
        try? handle?.synchronize()
        var data = Data("Hallways Diagnostics -- shared \(timestampFormatter.string(from: Date())) from session \(sessionID), app \(version), device \(Self.deviceModel), \(ProcessInfo.processInfo.operatingSystemVersionString)\nOldest first. Each SESSION START line marks an app launch.\n\n".utf8)
        if let previous = try? Data(contentsOf: previousURL) { data.append(previous) }
        if let current = try? Data(contentsOf: currentURL) { data.append(current) }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Hallways-Diagnostics-\(stamp.string(from: Date())).txt")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: File (queue only)

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func openIfNeeded() {
        guard handle == nil else { return }
        ensureDirectory()
        if !FileManager.default.fileExists(atPath: currentURL.path) {
            FileManager.default.createFile(atPath: currentURL.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: currentURL) else { return }
        currentBytes = Int((try? h.seekToEnd()) ?? 0)
        handle = h
    }

    private func append(_ line: String) {
        openIfNeeded()
        guard let handle else { return }
        let data = Data(line.utf8)
        do {
            try handle.write(contentsOf: data)
            currentBytes += data.count
        } catch {
            return
        }
        if currentBytes > maxBytes { rotate() }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: currentURL, to: previousURL)
        currentBytes = 0
        openIfNeeded()
        if let handle {
            let note = Data("(log rolled -- earlier events are in the previous file)\n".utf8)
            try? handle.write(contentsOf: note)
            currentBytes += note.count
        }
    }

    // MARK: Rendering

    static func render(_ value: Any?) -> String {
        guard let value else { return "nil" }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return "nil" }
            return render(child.value)
        }
        switch value {
        case let v as Double: return String(format: "%.3f", v)
        case let v as Float: return String(format: "%.3f", v)
        case let v as CGFloat: return String(format: "%.3f", Double(v))
        default:
            let s = String(describing: value)
            if s.isEmpty { return "\"\"" }
            if s.contains(" ") || s.contains("=") || s.contains("\n") {
                return "\"" + s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ") + "\""
            }
            return s
        }
    }

    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Shorthand: `diag("elevator.accepted", ["next": 3])`. Safe from any thread.
nonisolated func diag(_ event: String, _ fields: KeyValuePairs<String, Any?> = [:]) {
    DiagnosticRecorder.shared.record(event, fields)
}

/// One trip per launch; observation only. All elapsed times are captured at
/// the call site using systemUptime, including render/background callbacks.
nonisolated final class ElevatorArrivalTrace: @unchecked Sendable {
    static let shared = ElevatorArrivalTrace()
    private let lock = NSLock()
    private var start: Double?
    private var used = false
    private var destinationScene: ObjectIdentifier?
    private var frames = 0
    private var indicatorRendered = false
    private var indicatorAssigned = false
    private var lastPan = 0.0
    private var doorX: Float?
    private var doorZ: Float?
    private var doorMoved = false
    private var phaseCounts: [String: Int] = [:]

    func begin(from: Int, to: Int) {
        let enabled = lock.withLock { () -> Bool in
            guard !used else { return false }
            used = true
            start = ProcessInfo.processInfo.systemUptime
            return true
        }
        guard enabled else { return }
        event("indicator.assignmentBegin", "from=\(from) to=\(to)")
        probe()
    }

    func event(_ name: String, _ detail: String = "") {
        let now = ProcessInfo.processInfo.systemUptime
        guard let origin = lock.withLock({ start }), now - origin < 30 else { return }
        diag("ELEVATOR_TRACE", ["ms": String(format: "%.3f", (now - origin) * 1000),
                                "event": name, "main": Thread.isMainThread, "detail": detail])
    }

    /// Bounded phase pairs: no per-object logs. The optional token means inactive
    /// traces do no formatting/writing. Repeated UI passes cap at 24 per phase.
    func beginPhase(_ name: String, _ detail: @autoclosure () -> String = "") -> Double? {
        let now = ProcessInfo.processInfo.systemUptime
        let enabled = lock.withLock { () -> Bool in
            guard let start, now - start < 30 else { return false }
            let count = phaseCounts[name, default: 0]
            guard count < 24 else { return false }
            phaseCounts[name] = count + 1
            return true
        }
        guard enabled else { return nil }
        event(name + ".begin", detail())
        return now
    }

    func endPhase(_ name: String, _ began: Double?) {
        guard let began else { return }
        let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
        event(name + ".end", "elapsedMS=\(String(format: "%.3f", elapsed))")
    }

    private func probe() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { [self] in
            guard let origin = lock.withLock({ start }),
                  ProcessInfo.processInfo.systemUptime - origin < 30 else { return }
            let sent = ProcessInfo.processInfo.systemUptime
            event("heartbeat.sent")
            DispatchQueue.main.async { [self] in
                event("heartbeat.ack", "queueDelayMS=\((ProcessInfo.processInfo.systemUptime - sent) * 1000)")
                probe() // At most one pending probe, even through a long stall.
            }
        }
    }

    func destinationNumberAssigned() {
        lock.withLock { indicatorAssigned = true }
        event("indicator.assignmentEnd")
    }

    func registerScene(_ scene: AnyObject) {
        lock.withLock { destinationScene = ObjectIdentifier(scene) }
    }

    func registerDestination(_ controller: AnyObject) {
        event("controller.installed", "controller=\(ObjectIdentifier(controller))")
    }

    func rendered(_ controller: AnyObject, scene: AnyObject, doorPosition: (Float, Float)?) {
        let marks: [String] = lock.withLock {
            guard start != nil else { return [] }
            guard destinationScene == ObjectIdentifier(scene) else {
                if indicatorAssigned && !indicatorRendered { indicatorRendered = true; return ["indicator.firstRenderAfterAssignment"] }
                return []
            }
            frames += 1
            var result = frames <= 2 ? ["destination.renderedFrame.\(frames)"] : []
            if !doorMoved, let x = doorX, let z = doorZ, let p = doorPosition,
               abs(p.0 - x) + abs(p.1 - z) > 0.00001 {
                doorMoved = true
                result.append("doors.firstRenderedMovement")
            }
            return result
        }
        for mark in marks { event(mark, "controller=\(ObjectIdentifier(controller))") }
        if marks.contains("doors.firstRenderedMovement") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                event("trace.end")
                lock.withLock { start = nil }
            }
        }
    }

    func doorsScheduled(x: Float, z: Float) {
        lock.withLock { doorX = x; doorZ = z }
        event("doors.actionsScheduled")
    }

    func samplePan(changed: Bool) -> Bool {
        lock.withLock {
            guard let start, ProcessInfo.processInfo.systemUptime - start < 30 else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            if changed && now - lastPan < 0.1 { return false }
            lastPan = now
            return true
        }
    }
}
