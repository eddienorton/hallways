import Testing
import AVFoundation
@testable import Hallways

/// Oct 8: the mute switch silences and restores without touching anyone's
/// own volume, and persists.
struct HallwaysAudioMuteTests {
    private func defaults() -> UserDefaults {
        let name = "HallwaysAudioMuteTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func player(volume: Float) throws -> AVAudioPlayer {
        let p = try AVAudioPlayer(data: BobbinSound.wav([Float](repeating: 0, count: 2_000)))
        p.volume = volume
        return p
    }

    @Test func muteSilencesAndUnmuteRestoresEachPlayersOwnVolume() throws {
        let audio = HallwaysAudio(defaults: defaults())
        let chime = audio.manage(try player(volume: 0.9))
        let steps = audio.manage(try player(volume: 0.35))
        audio.setMuted(true)
        #expect(chime.volume == 0 && steps.volume == 0)
        audio.setMuted(false)
        #expect(chime.volume == 0.9 && steps.volume == 0.35)
    }

    @Test func playersMadeWhileMutedStartSilentAndFadesRespectTheMute() throws {
        let audio = HallwaysAudio(defaults: defaults())
        audio.setMuted(true)
        let late = audio.manage(try player(volume: 0.9))
        #expect(late.volume == 0)
        audio.setVolume(late, 0.5)                      // a fade step while muted
        #expect(late.volume == 0)
        #expect(audio.rememberedVolume(of: late) == 0.5)
        audio.setMuted(false)
        #expect(late.volume == 0.5)
    }

    @Test func sceneKitEngineIsMutedAtItsMixerNotStopped() {
        let audio = HallwaysAudio(defaults: defaults())
        let engine = AVAudioEngine()
        audio.attach(engine: engine)
        #expect(engine.mainMixerNode.outputVolume == 1)
        audio.setMuted(true)
        #expect(engine.mainMixerNode.outputVolume == 0)
        let next = AVAudioEngine()                      // e.g. after a rebuild
        audio.attach(engine: next)
        #expect(next.mainMixerNode.outputVolume == 0)
        audio.toggle()
        #expect(engine.mainMixerNode.outputVolume == 1 && next.mainMixerNode.outputVolume == 1)
    }

    @Test func theSettingPersists() {
        let store = defaults()
        HallwaysAudio(defaults: store).setMuted(true)
        #expect(HallwaysAudio(defaults: store).isMuted)
        HallwaysAudio(defaults: store).setMuted(false)
        #expect(!HallwaysAudio(defaults: store).isMuted)
    }
}
