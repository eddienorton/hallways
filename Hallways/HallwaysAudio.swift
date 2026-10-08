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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _isMuted = defaults.bool(forKey: Self.mutedKey)
    }

    var isMuted: Bool { lock.withLock { _isMuted } }

    func setMuted(_ muted: Bool) {
        let (ps, es): ([(AVAudioPlayer, Float)], [AVAudioEngine]) = lock.withLock {
            _isMuted = muted
            players = players.filter { $0.value.player.value != nil }
            engines.removeAll { $0.value == nil }
            return (players.values.compactMap { e in e.player.value.map { ($0, e.volume) } },
                    engines.compactMap(\.value))
        }
        defaults.set(muted, forKey: Self.mutedKey)
        for (player, volume) in ps { player.volume = muted ? 0 : volume }
        for engine in es { engine.mainMixerNode.outputVolume = muted ? 0 : 1 }
        diag("audio.mute", ["muted": muted, "players": ps.count, "engines": es.count])
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    func toggle() { setMuted(!isMuted) }

    /// Call once a player's own volume is set (before or after play):
    /// remembers that volume and applies the mute.
    @discardableResult
    func manage(_ player: AVAudioPlayer) -> AVAudioPlayer {
        let muted: Bool = lock.withLock {
            players[ObjectIdentifier(player)] = (Weak(player), player.volume)
            if players.count > 64 { players = players.filter { $0.value.player.value != nil } }
            return _isMuted
        }
        if muted { player.volume = 0 }
        return player
    }

    /// A later volume change for a managed player (fades): recorded as its
    /// volume, applied only while unmuted.
    func setVolume(_ player: AVAudioPlayer, _ volume: Float) {
        let muted: Bool = lock.withLock {
            players[ObjectIdentifier(player)] = (Weak(player), volume)
            return _isMuted
        }
        player.volume = muted ? 0 : volume
    }

    /// The 3D view's audio engine (SceneKit's). Safe to call repeatedly.
    func attach(engine: AVAudioEngine) {
        let muted: Bool = lock.withLock {
            if !engines.contains(where: { $0.value === engine }) { engines.append(Weak(engine)) }
            return _isMuted
        }
        let level: Float = muted ? 0 : 1
        if engine.mainMixerNode.outputVolume != level { engine.mainMixerNode.outputVolume = level }
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
