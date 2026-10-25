//
//  MudProbe.swift
//  Hallways
//
//  Oct 24 -- MEASUREMENT ONLY: THE MUD BUG.
//
//  "Mud": swipes and taps take a long time to show any effect (a tap-walk
//  starts late, then walks normally), sometimes with chaotic static in the
//  audio; it can begin at launch; it has once cleared a few seconds after the
//  speaker button was pressed (and not come back when sound was turned on).
//  This file times each step from a finger to the screen, so an episode says
//  WHICH step is slow -- with nothing logged per frame and nothing kept beyond
//  a small ring:
//
//    in.touch>handle   the finger touched down -> the game's gesture handler ran
//                      (includes the system's own recognition wait: a tap is
//                      only a tap once the finger lifts -- so ~100 ms is normal)
//    in.handle>frame   the handler ran -> the next frame SceneKit finished
//    in.handle>move    a tap / WALK -> the first rendered frame in which the
//                      player actually moved (none: it wasn't a walk)
//
//  ...each a section in PerfMonitor's per-second line (count, total, max), so
//  they sit beside the main thread's busy %, its stalls, the frame gaps, CPU per
//  thread and memory that PerfMonitor already records. Any input with a step
//  over 250 ms: one `mud.slowInput` line in the diagnostics (at most one every
//  2 s) with the last few inputs.
//
//  Once a second it also puts the audio machinery's state in that line (as
//  live counts): SceneKit's positional players playing now (aud.scnPlayers),
//  the sound ledger's live and retired-but-held players (aud.ledgerLive /
//  aud.ledgerHeld), whether the orchestra's engine runs and its level
//  (orch.running / orch.master%), and whether audio-off mode is on. Audio
//  render trouble shows as `aud.tapGap` (AudioHealth: the SceneKit mixer's
//  buffers arriving late -- the usual cause of static).
//
//  On with PerfMonitor (DEBUG builds; Release with -HallwaysPerf YES).
//

import Foundation
import QuartzCore

nonisolated final class MudProbe: @unchecked Sendable {
    static let shared = MudProbe()

    private let lock = NSLock()
    private var lastTouchDown: CFTimeInterval = 0
    private var pendingFrame: Int?                       // (ring index waiting for its frame)
    private var pendingMove: Int?                        // (ring index waiting for movement)

    private struct Entry {
        var kind: String
        var at: CFTimeInterval
        var touchToHandleMs: Double?
        var handleToFrameMs: Double?
        var handleToMoveMs: Double?
        var reported = false
    }
    private var ring: [Entry] = []
    private static let ringSize = 24
    private var lastSlowReport: CFTimeInterval = 0

    // MARK: Inputs (main thread)

    /// A finger touched down (InputLagProbe), at the system's event time.
    func touchDown(eventTime: TimeInterval) {
        guard PerfMonitor.enabled else { return }
        lock.withLock { lastTouchDown = eventTime }
    }

    /// A gesture handler took the input. `mayWalk`: a tap or WALK (wait for movement).
    func handled(_ kind: String, mayWalk: Bool) {
        guard PerfMonitor.enabled else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        var e = Entry(kind: kind, at: now)
        if lastTouchDown > 0, now - lastTouchDown < 3 { e.touchToHandleMs = (now - lastTouchDown) * 1000 }
        if ring.count >= Self.ringSize { ring.removeFirst(); shift() }
        ring.append(e)
        let i = ring.count - 1
        pendingFrame = i
        pendingMove = mayWalk ? i : nil
        lock.unlock()
        if let ms = e.touchToHandleMs { PerfMonitor.record("in.touch>handle", ns: UInt64(ms * 1e6)) }
    }

    private func shift() {                              // (under the lock: indices after removeFirst)
        pendingFrame = pendingFrame.flatMap { $0 > 0 ? $0 - 1 : nil }
        pendingMove = pendingMove.flatMap { $0 > 0 ? $0 - 1 : nil }
    }

    // MARK: Render thread (PerfMonitor's own hooks)

    func frameRendered() {
        guard PerfMonitor.enabled else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        guard let i = pendingFrame else { lock.unlock(); return }
        pendingFrame = nil
        guard i < ring.count else { lock.unlock(); return }
        let ms = (now - ring[i].at) * 1000
        ring[i].handleToFrameMs = ms
        let finished: Entry? = pendingMove == i ? nil : ring[i]     // (a possible walk: finished at its first step)
        lock.unlock()
        PerfMonitor.record("in.handle>frame", ns: UInt64(ms * 1e6))
        if let finished { check(finished) }
    }

    func walkMoved(metres: Double) {
        guard PerfMonitor.enabled, metres > 0.0005, let i = lock.withLock({ pendingMove }) else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        guard i < ring.count else { pendingMove = nil; lock.unlock(); return }
        let waited = now - ring[i].at
        guard waited < 5 else { pendingMove = nil; lock.unlock(); return }      // (that tap never walked)
        ring[i].handleToMoveMs = waited * 1000
        pendingMove = nil
        let e = ring[i]
        lock.unlock()
        PerfMonitor.record("in.handle>move", ns: UInt64(waited * 1e9))
        check(e)
    }

    /// One input done: any step over 250 ms is said (with the inputs before it).
    private func check(_ e: Entry) {
        let slow = [e.touchToHandleMs, e.handleToFrameMs, e.handleToMoveMs].contains { ($0 ?? 0) > 250 }
        guard slow else { return }
        let now = CACurrentMediaTime()
        let recent: [Entry]? = lock.withLock {
            guard now - lastSlowReport >= 2 else { return nil }
            lastSlowReport = now
            return Array(ring.suffix(6))
        }
        guard let recent else { return }
        func ms(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
        let line = recent.map { "\($0.kind) \(ms($0.touchToHandleMs))/\(ms($0.handleToFrameMs))/\(ms($0.handleToMoveMs))" }.joined(separator: "; ")
        diag("mud.slowInput", ["kind": e.kind, "touchToHandleMs": ms(e.touchToHandleMs), "handleToFrameMs": ms(e.handleToFrameMs),
                               "handleToMoveMs": ms(e.handleToMoveMs), "recent(touch>handle/handle>frame/handle>move)": line])
    }

    // MARK: Once a second (main thread, StickyProbe.tick): the audio machinery's state

    private var lastGauges: [String: Int] = [:]

    @MainActor
    func secondTick() {
        guard PerfMonitor.enabled else { return }
        let ledger = PlayingSounds.shared
        let o = LivingOrchestra.shared
        set("aud.scnPlayers", AudioHealth.shared.livePlayers) { PerfMonitor.gauge("aud.scnPlayers", $0) }
        set("aud.ledgerLive", ledger.liveCount) { PerfMonitor.gauge("aud.ledgerLive", $0) }
        set("aud.ledgerHeld", ledger.holdingCount) { PerfMonitor.gauge("aud.ledgerHeld", $0) }
        set("orch.running", o.engineRunning ? 1 : 0) { PerfMonitor.gauge("orch.running", $0) }
        set("orch.master%", Int((o.masterLevel * 100).rounded())) { PerfMonitor.gauge("orch.master%", $0) }
        set("audioOff", AudioDiagnostics.audioOff ? 1 : 0) { PerfMonitor.gauge("audioOff", $0) }
    }

    /// PerfMonitor's gauges count up and down: the change since last second.
    private func set(_ key: String, _ value: Int, _ apply: (Int) -> Void) {
        let delta = value - (lastGauges[key] ?? 0)
        guard delta != 0 else { return }
        lastGauges[key] = value
        apply(delta)
    }
}

// MARK: - True audio-off (diagnostic)

/// Oct 24 -- AUDIO OFF, for finding the mud: not a volume mute (that's the
/// speaker button), but Hallways' audio WORK switched off for a whole run --
/// the orchestra never starts, the walking music and the residents' music
/// conductor never run, no critter sound is ever built (CritterAudio), no
/// SoundEffects player is ever loaded (chimes, doors, footsteps, street...),
/// every other managed AVAudioPlayer is held at zero, the SceneKit mixer gets
/// no measuring tap and is silenced, and the signatures aren't rendered at
/// launch. Gameplay, critters, navigation, the elevator and floors are untouched.
///
/// On: Settings > Diagnostics > "Audio off (next launch)", or the launch
/// argument `-HallwaysAudioOff YES`. It's read once, at launch: switch it, then
/// quit and relaunch. Off again the same way.
///
/// What still runs (can't safely be removed from here): SceneKit's own audio
/// engine (SceneKit owns it; it idles with nothing attached), the audio session,
/// and the few scripted-scene / mini-game sounds that bypass CritterAudio and
/// SoundEffects (they play silently).
nonisolated enum AudioDiagnostics {
    static let audioOffKey = "HallwaysAudioOff"
    /// For this run (read once).
    static let audioOff: Bool = {
        let on = UserDefaults.standard.bool(forKey: audioOffKey)
        if on { diag("audio.off", ["note": "diagnostic audio-off mode: Hallways' audio work is switched off for this run"]) }
        return on
    }()
}
