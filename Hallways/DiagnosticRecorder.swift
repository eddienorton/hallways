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
            self.lock.withLock { self._lastMainBeat = ProcessInfo.processInfo.systemUptime }
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
