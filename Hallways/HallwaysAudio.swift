import AVFoundation
import Combine

/// Oct 8 -- the player's MUTE switch for everything Hallways itself plays.
///
/// Two routes cover all of the game's sound:
///  - SceneKit audio (critters, voices, the elevator, everything positional)
///    plays through the 3D view's own AVAudioEngine: muting sets that
///    engine's main-mixer output to 0 -- the engine keeps running, nothing
///    is stopped or rebuilt.
///  - AVAudioPlayer sounds (footsteps, chimes, music, street ambience, the
///    computer games, the phone) register here when created; muting sets
///    their volume to 0 and unmuting restores the volume each one was set
///    to. Code that changes a registered player's volume later goes
///    through setVolume so the mute still wins.
/// Never touches the system volume or the audio session (other apps are
/// unaffected). Persisted across launches.
nonisolated final class HallwaysAudio: ObservableObject, @unchecked Sendable {
    static let shared = HallwaysAudio()
    nonisolated static let mutedKey = "hallwaysAudio.muted"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var _isMuted: Bool
    private var players: [ObjectIdentifier: (player: Weak<AVAudioPlayer>, volume: Float)] = [:]
    private var engines: [Weak<AVAudioEngine>] = []
    /// Oct 9: temporary silences that are NOT the player's Mute (Settings
    /// open). Never persisted; Mute's own state is untouched by them.
    private var suppressions: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _isMuted = defaults.bool(forKey: Self.mutedKey)
    }

    var isMuted: Bool { lock.withLock { _isMuted } }

    func setMuted(_ muted: Bool) {
        let (ps, es, silent): ([(AVAudioPlayer, Float)], [AVAudioEngine], Bool) = lock.withLock {
            _isMuted = muted
            players = players.filter { $0.value.player.value != nil }
            engines.removeAll { $0.value == nil }
            return (players.values.compactMap { e in e.player.value.map { ($0, e.volume) } },
                    engines.compactMap(\.value), muted || !suppressions.isEmpty)
        }
        defaults.set(muted, forKey: Self.mutedKey)
        for (player, volume) in ps { player.volume = silent || AudioDiagnostics.audioOff ? 0 : volume }
        for engine in es { engine.mainMixerNode.outputVolume = silent ? 0 : 1 }
        diag("audio.mute", ["muted": muted, "silent": silent, "players": ps.count, "engines": es.count])
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    /// Oct 9: is any temporary silence (not Mute) on right now?
    var isSuppressed: Bool { lock.withLock { !suppressions.isEmpty } }

    /// Oct 24 -- MUSIC LAB FOCUS: while Building Life's Directory (the Music Lab) is
    /// on screen, every Hallways sound is silenced through this same suppression
    /// (the 3D view's engine, every managed player, and -- through storyQuiet --
    /// the orchestra, walking music and greetings), exactly as Settings does it.
    /// Only the lab's own engine plays (it isn't one of these). Lifted when the
    /// Directory goes; Mute and the other silences are untouched.
    static let musicLabFocus = "musicLab"

    /// Oct 24: a temporary silence other than `reason` is on (the lab's own focus
    /// never silences the lab; Settings' silence still does).
    func isSuppressed(otherThan reason: String) -> Bool { lock.withLock { !suppressions.subtracting([reason]).isEmpty } }

    /// Oct 9 -- a temporary silence for `reason` (Settings open): every
    /// Hallways sound goes quiet exactly as Mute does it, and comes back when
    /// the last reason is lifted -- unless the player has Mute on. Mute's
    /// state and its saved setting are never changed by this.
    func setSuppressed(_ on: Bool, reason: String) {
        let result: (ps: [(AVAudioPlayer, Float)], es: [AVAudioEngine], silent: Bool)? = lock.withLock {
            let was = !suppressions.isEmpty
            if on { suppressions.insert(reason) } else { suppressions.remove(reason) }
            guard was != !suppressions.isEmpty else { return nil }
            players = players.filter { $0.value.player.value != nil }
            engines.removeAll { $0.value == nil }
            return (players.values.compactMap { e in e.player.value.map { ($0, e.volume) } },
                    engines.compactMap(\.value), _isMuted || !suppressions.isEmpty)
        }
        guard let result else { return }
        for (player, volume) in result.ps { player.volume = result.silent || AudioDiagnostics.audioOff ? 0 : volume }
        for engine in result.es { engine.mainMixerNode.outputVolume = result.silent ? 0 : 1 }
        diag("audio.suppressed", ["on": on, "reason": reason, "silent": result.silent])
    }

    func toggle() { setMuted(!isMuted) }

    /// Call once a player's own volume is set (before or after play):
    /// remembers that volume and applies the mute.
    @discardableResult
    func manage(_ player: AVAudioPlayer) -> AVAudioPlayer {
        let muted: Bool = lock.withLock {
            players[ObjectIdentifier(player)] = (Weak(player), player.volume)
            if players.count > 64 { players = players.filter { $0.value.player.value != nil } }
            return _isMuted || !suppressions.isEmpty
        }
        if muted || AudioDiagnostics.audioOff { player.volume = 0 }           // (Oct 24: audio-off -- silent)
        return player
    }

    /// A later volume change for a managed player (fades): recorded as its
    /// volume, applied only while unmuted.
    func setVolume(_ player: AVAudioPlayer, _ volume: Float) {
        let muted: Bool = lock.withLock {
            players[ObjectIdentifier(player)] = (Weak(player), volume)
            return _isMuted || !suppressions.isEmpty
        }
        player.volume = muted || AudioDiagnostics.audioOff ? 0 : volume
    }

    /// The 3D view's audio engine (SceneKit's). Safe to call repeatedly.
    func attach(engine: AVAudioEngine) {
        // Oct 24: audio-off (diagnostic) -- SceneKit's engine silenced, never measured, never unmuted.
        if AudioDiagnostics.audioOff {
            if engine.mainMixerNode.outputVolume != 0 { engine.mainMixerNode.outputVolume = 0 }
            return
        }
        let muted: Bool = lock.withLock {
            if !engines.contains(where: { $0.value === engine }) { engines.append(Weak(engine)) }
            return _isMuted || !suppressions.isEmpty
        }
        let level: Float = muted ? 0 : 1
        if engine.mainMixerNode.outputVolume != level { engine.mainMixerNode.outputVolume = level }
        AudioHealth.shared.watch(engine: engine)                       // Oct 9: static investigation, measurement only
    }

    /// Tests: the volume a managed player will return to.
    func rememberedVolume(of player: AVAudioPlayer) -> Float? {
        lock.withLock { players[ObjectIdentifier(player)]?.volume }
    }
}

nonisolated final class Weak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
