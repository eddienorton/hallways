import AVFoundation
import Foundation

/// Oct 9 (audio static investigation) -- MEASUREMENT ONLY. Nothing here
/// changes what plays or how loud.
///
/// Puts the numbers a "static" report needs into the diagnostics log:
///   - audio.session ..... sample rate, IO buffer, output latency, route,
///                         category -- at start and on every route change
///   - audio.event ....... interruptions, media-services resets, and any
///                         configuration change of an AVAudioEngine (SceneKit's
///                         included) -- engine restarts are a classic crackle
///   - audio.load ........ at most every 2 s, only while something happens:
///                         critter 3D players started / still live / peak live
///                         (each is a node attached to SceneKit's running
///                         engine), footstep loop start/stops, and the
///                         loudest sample leaving SceneKit's main mixer
///                         (peak >= 0.99 = clipping) with how many buffers hit it
/// The mixer reading covers SceneKit's audio (critters, Juanita, the reader
/// beep). SoundEffects' AVAudioPlayers (footsteps, elevator) play outside it.
nonisolated final class AudioHealth: @unchecked Sendable {
    static let shared = AudioHealth()

    private let lock = NSLock()
    private var started = false
    private final class WeakEngine { weak var engine: AVAudioEngine?; init(_ e: AVAudioEngine) { engine = e } }
    private var tappedEngines: [WeakEngine] = []
    // Window counters (reset on each audio.load line).
    private var critterStarts = 0
    private var footstepToggles = 0
    private var mixerPeak: Float = 0
    private var clippedBuffers = 0
    private var lastEmit = ProcessInfo.processInfo.systemUptime
    // Running.
    private var critterLive = 0
    private var critterPeakLive = 0

    func start() {
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        logSession("start")
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).map { "\($0)" } ?? "?"
            AudioHealth.shared.logSession("routeChange reason=\(reason)")
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).map { "\($0)" } ?? "?"
            diag("audio.event", ["what": "interruption", "type": type])
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
            diag("audio.event", ["what": "mediaServicesReset"])
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { note in
            let running = (note.object as? AVAudioEngine)?.isRunning
            diag("audio.event", ["what": "engineConfigurationChange", "engineRunning": running])
        }
    }

    func logSession(_ why: String) {
        let s = AVAudioSession.sharedInstance()
        let outputs = s.currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
        diag("audio.session", ["why": why, "sampleRate": s.sampleRate,
                               "ioBufferMs": String(format: "%.1f", s.ioBufferDuration * 1000),
                               "outputLatencyMs": String(format: "%.1f", s.outputLatency * 1000),
                               "category": s.category.rawValue, "outputs": outputs])
    }

    /// SceneKit's engine (from HallwaysAudio.attach): one level tap on its
    /// main mixer, once per engine.
    func watch(engine: AVAudioEngine) {
        start()
        lock.lock()
        tappedEngines.removeAll { $0.engine == nil }
        let already = tappedEngines.contains { $0.engine === engine }
        if !already { tappedEngines.append(WeakEngine(engine)) }
        lock.unlock()
        guard !already else { return }
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            var peak: Float = 0
            let n = Int(buffer.frameLength)
            for c in 0..<Int(buffer.format.channelCount) {
                let p = channels[c]
                for i in 0..<n { let v = abs(p[i]); if v > peak { peak = v } }
            }
            AudioHealth.shared.mixerBuffer(peak: peak)
        }
        diag("audio.tap", ["installed": true])
    }

    func critterPlayerStarted() {
        lock.lock()
        critterStarts += 1
        critterLive += 1
        critterPeakLive = max(critterPeakLive, critterLive)
        lock.unlock()
        emitIfDue()
    }

    func critterPlayerFinished() {
        lock.lock(); critterLive = max(0, critterLive - 1); lock.unlock()
    }

    func footstepToggled() {
        lock.lock(); footstepToggles += 1; lock.unlock()
        emitIfDue()
    }

    private func mixerBuffer(peak: Float) {
        lock.lock()
        mixerPeak = max(mixerPeak, peak)
        if peak >= 0.99 { clippedBuffers += 1 }
        lock.unlock()
        emitIfDue()
    }

    /// One compact line for the 30 s snapshot.
    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        return "live=\(critterLive) peakLive=\(critterPeakLive)"
    }

    private func emitIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard now - lastEmit >= 2 else { lock.unlock(); return }
        let quiet = critterStarts == 0 && footstepToggles == 0 && clippedBuffers == 0 && mixerPeak < 0.01
        let fields: KeyValuePairs<String, Any?> = [
            "critterStarts": critterStarts, "critterLive": critterLive, "critterPeakLive": critterPeakLive,
            "footstepToggles": footstepToggles, "mixerPeak": String(format: "%.3f", mixerPeak),
            "clippedBuffers": clippedBuffers, "seconds": String(format: "%.1f", now - lastEmit)
        ]
        lastEmit = now
        critterStarts = 0
        footstepToggles = 0
        mixerPeak = 0
        clippedBuffers = 0
        critterPeakLive = critterLive
        lock.unlock()
        if !quiet { diag("audio.load", fields) }
    }
}
