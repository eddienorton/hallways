//
//  SoundEffects.swift
//  Hallways
//
//  One tiny shared place for bundled sound-effect playback. Eddie's own
//  plan: wav files (free, no licensing to think about) dropped into the
//  Audio folder here, with "many, many more" coming over time -- so
//  loadPlayer(_:) below is the one bit of shared plumbing every future
//  sound reuses (load once, reuse the AVAudioPlayer, rewind before each
//  play), and adding a new sound is just one more `static let` plus one
//  more `static func play...()`, no changes to the shared part at all.
//
//  The Audio folder is a synced Xcode group (this project uses Xcode
//  16's file-system-synchronized groups, not manually-added file
//  references), so anything dropped in there is picked up as a bundle
//  resource automatically -- no "add to target" step needed on Eddie's
//  end, same as every .swift file in this project.
//

import AVFoundation

enum SoundEffects {
    /// Loads one bundled sound by filename (extension included) into a
    /// ready-to-play AVAudioPlayer, or nil (with a console log, not a
    /// crash) if that file isn't in the app bundle yet -- lets every
    /// sound below be declared before its asset necessarily exists.
    private static func loadPlayer(_ filename: String) -> AVAudioPlayer? {
        let name = filename as NSString
        let ext = name.pathExtension
        let base = name.deletingPathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext) else {
            print("SoundEffects: \(filename) not found in the app bundle yet -- check it's in Hallways/Audio.")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            return player
        } catch {
            print("SoundEffects: could not decode \(filename): \(error)")
            return nil
        }
    }

    // Built once and reused (not a fresh AVAudioPlayer per call) so
    // rapid repeats don't pay file-load cost -- currentTime is rewound
    // before each play so a second trigger mid-sound restarts cleanly.
    private static let cashPickupPlayer = loadPlayer("ka-ching.wav")

    static func playCashPickup() {
        guard let player = cashPickupPlayer else { return }
        player.currentTime = 0
        player.play()
    }

    /// Eddie, Sept 6: wants a sound the instant a walk locks into an
    /// intersection (a real fork OR a forced single turn -- see
    /// walkToNextDecision's .intersection case, which covers both) --
    /// a "these are your options now" cue, not a reward, so this
    /// should land as short, crisp, and neutral rather than
    /// celebratory like the cash ka-ching. womp2.wav is Eddie's own
    /// pick, dropped straight into Audio/ (no more staging sounds
    /// outside the project first -- see his own workflow call, Sept 6).
    private static let intersectionLockPlayer = loadPlayer("womp2.wav")

    static func playIntersectionLock() {
        guard let player = intersectionLockPlayer else { return }
        player.currentTime = 0
        player.play()
    }

    /// Eddie, Sept 7: "are we checking... for the trash sequence when
    /// we get to the elevator?... we want red flashing lights,
    /// sirens... make them feel shitty" -- plays the instant
    /// openElevator() refuses entry because isMissionComplete is
    /// false. Same "declare the call before the asset exists" pattern
    /// as every sound above -- drop alarm.wav into Audio/ and this
    /// starts working with no other changes; silently no-ops (with a
    /// console log) until then.
    private static let alarmPlayer = loadPlayer("alarm.wav")

    static func playAlarm() {
        guard let player = alarmPlayer else { return }
        player.currentTime = 0
        player.play()
    }

    /// Eddie, Sept 9, wiring up the first real music/sfx from
    /// Archive.zip (9 files -- these 3 in use now, the other 6 --
    /// elevator-arrived-ding-dong x2, walking-giant, walking-heels,
    /// walking-in-grass, walking-in-water -- dropped into Audio/ for
    /// later, "we'll prob use them later"): "use 'walking.mp3' for
    /// normal walking down hallway. so its only when there is forward
    /// movement." A footstep loop, not a one-shot like everything
    /// above -- start/stop rather than play-from-zero, so
    /// startWalking()/stopWalking() below are called from
    /// TapNavigationController right as a forward glide begins/ends
    /// (advance()'s .translate phase), never fired directly by a UI
    /// action the way playCashPickup() etc. are. numberOfLoops = -1
    /// loops indefinitely for however long a single glide lasts;
    /// stopWalking() uses pause() (not stop()) so a footstep cut off
    /// mid-stride resumes from that same point on the next glide
    /// instead of always restarting at 0.
    private static let walkingPlayer: AVAudioPlayer? = {
        let player = loadPlayer("walking.mp3")
        player?.numberOfLoops = -1
        return player
    }()

    static func startWalking() {
        guard let player = walkingPlayer, !player.isPlaying else { return }
        player.play()
    }

    static func stopWalking() {
        walkingPlayer?.pause()
    }

    /// Both entry and arrival use the same chime before the doors move.
    private static let elevatorArrivalPlayer = loadPlayer("elevator-arrived-ding-dong.mp3")

    /// The bundled chime begins about 0.08 seconds into the recording.
    /// Start moving at that attack, while the rest of the chime rings out.
    static let elevatorDoorOpeningDelay: TimeInterval = 0.08

    /// Includes the scene-settle beat, sound lead-in, slide, and reveal buffer.
    static var elevatorRevealDuration: TimeInterval {
        0.2 + elevatorDoorOpeningDelay + 1.0 + 0.1
    }

    static func playElevatorArrival() {
        guard let player = elevatorArrivalPlayer else { return }
        player.currentTime = 0
        player.play()
    }

    /// Eddie, Sept 9: "use elevator-music" -- for the scripted ride
    /// itself (step in, 180 spin, floor change), not the door-open
    /// above. Explicit start/stop like walking, but no loop: this
    /// track is longer than the few-second ride, so it just plays
    /// once and playElevatorRide stops it as soon as the ride hands
    /// off to ContentView's curtain, rather than looping or bleeding
    /// into the next floor.
    private static let elevatorMusicPlayer = loadPlayer("elevator-music.mp3")

    static func playElevatorMusic() {
        guard let player = elevatorMusicPlayer else { return }
        player.currentTime = 0
        player.play()
    }

    static func stopElevatorMusic() {
        elevatorMusicPlayer?.pause()
    }

    /// Eddie, Sept 9: "improve the picking up of trash... enclosed are
    /// a few sounds associated with picking up and throwing out the
    /// trash." Two distinct pickup takes rather than one -- playTrashPickup()
    /// below picks between them at random each call, purely for
    /// variety across a run that can pick up several trash cans in a
    /// row.
    private static let trashPickup1Player = loadPlayer("picking-up-trash1.mp3")
    private static let trashPickup2Player = loadPlayer("picking-up-trash2.mp3")

    static func playTrashPickup() {
        guard let player = [trashPickup1Player, trashPickup2Player].compactMap({ $0 }).randomElement() else { return }
        player.currentTime = 0
        player.play()
    }

    /// The chute swallowing a delivered trash can -- collectObjectIfPresent's
    /// pickup sound above has its deposit-side counterpart here,
    /// called from depositIfPresent.
    private static let trashChutePlayer = loadPlayer("trash-chute.mp3")

    @discardableResult
    static func playTrashChute() -> Bool {
        guard let player = trashChutePlayer else { return false }
        // Explicit game audio avoids the default session silently following
        // the device's Ring/Silent switch. Keep other background audio mixing.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("SoundEffects: could not activate chute audio: \(error)")
        }
        player.currentTime = 0
        let started = player.play()
        if !started {
            print("SoundEffects: trash-chute.mp3 playback did not start")
        }
        return started
    }
}
