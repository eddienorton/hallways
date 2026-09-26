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
    /// Resolve lazy audio players while the title screen is visible, without playing.
    static func prepareForGameplay() async {
        let loaders: [() -> AVAudioPlayer?] = [
            { walkingPlayer }, { elevatorArrivalPlayer }, { elevatorMusicPlayer },
            { cashPickupPlayer }, { intersectionLockPlayer }, { alarmPlayer },
            { trashPickup1Player }, { trashPickup2Player }, { trashChuteOpenPlayer }, { trashChuteClosePlayer },
            { mailPickupPlayer }, { mailDeliveryPlayer }, { extinguisherSprayPlayer }, { extinguisherGrabPlayer },
            { cameraClickPlayer }, { hitWallPlayer }, { warningBuzzPlayer }, { paintSplatPlayer },
            { ticTacToeXPlayer }, { ticTacToeOPlayer }, { ticTacToeWinPlayer }, { ticTacToeLosePlayer },
            { streetAudioPlayer }, { knockSoftPlayer }, { knockMediumPlayer }, { knockHardPlayer }
        ]
        for load in loaders {
            try? await Task.sleep(for: .milliseconds(10))
            _ = load()
        }
    }

    /// Loads one bundled sound by filename (extension included) into a
    /// ready-to-play AVAudioPlayer, or nil (with a console log, not a
    /// crash) if that file isn't in the app bundle yet -- lets every
    /// sound below be declared before its asset necessarily exists.
    private static func loadPlayer(_ filename: String) -> AVAudioPlayer? {
        let name = filename as NSString
        let ext = name.pathExtension
        let base = name.deletingPathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "audio")
            ?? Bundle.main.url(forResource: base, withExtension: ext) else {
            print("SoundEffects: \(filename) not found in the app bundle yet -- check it's in Hallways-Assets/audio.")
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

    private static let hitWallPlayer = loadPlayer("hit-wall.mp3")
    private static let warningBuzzPlayer = loadPlayer("warning-buzz.mp3")
    private static let paintSplatPlayer = loadPlayer("paint-splat.mp3")

    static func playHitWall() { hitWallPlayer?.currentTime = 0; hitWallPlayer?.play() }
    static func playWarningBuzz() { warningBuzzPlayer?.currentTime = 0; warningBuzzPlayer?.play() }
    static func playPaintSplat() { paintSplatPlayer?.currentTime = 0; paintSplatPlayer?.play() }

    private(set) static var walkingRate: Float = 1
    static func setWalkingPace(_ pace: Float) {
        walkingRate = min(1.6, max(1, pace))
        walkingPlayer?.rate = walkingRate
    }

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
    // One existing footstep loop; the preference changes only its source file.
    private static var loadedFeet = PlayerFeet.current
    private static var walkingPlayer: AVAudioPlayer? = makeWalkingPlayer(loadedFeet)

    private static func makeWalkingPlayer(_ feet: PlayerFeet) -> AVAudioPlayer? {
        let player = loadPlayer(feet.filename)
        player?.numberOfLoops = -1
        player?.enableRate = true
        return player
    }

    static func startWalking() {
        let selected = PlayerFeet.current
        if selected != loadedFeet {
            walkingPlayer?.pause()
            walkingPlayer = makeWalkingPlayer(selected)
            loadedFeet = selected
        }
        guard let player = walkingPlayer, !player.isPlaying else { return }
        player.rate = walkingRate
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

    /// Eddie, Sept 18: street/city ambience for the building-exterior
    /// opening screen (street1.mp3 from Eddie's Downloads, one
    /// long-ish ambient loop rather than the short one-shots above).
    /// Same explicit start/stop model as walking/elevator music --
    /// NOT a play-from-zero sound effect. Starts when the intro/
    /// opening screen appears (ContentView's showIntroScreen onChange),
    /// loops for as long as that screen is up, and fades out over
    /// ~0.8s (midrange of Eddie's "~0.5-1s") the moment the player
    /// dismisses it and steps inside on the ceremonial walk
    /// (stopStreetAudio from the IntroScreenView onEnter). By the
    /// time the walk hands off to floor 1, the street is gone -- it
    /// never bleeds into the lobby or any gameplay floor, exactly
    /// per spec: exterior only, no lobby ambience.
    private static let streetAudioPlayer: AVAudioPlayer? = {
        let player = loadPlayer("street1.mp3")
        player?.numberOfLoops = -1
        return player
    }()

    static func startStreetAudio() {
        guard let player = streetAudioPlayer else { return }
        // Explicit game-audio activation, same as the chute/mail
        // helpers -- the intro screen is exactly when the OS may
        // still have the session unconfigured.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("SoundEffects: could not activate street audio: \(error)")
        }
        player.volume = 1
        player.currentTime = 0
        player.play()
    }

    static func stopStreetAudio() {
        guard let player = streetAudioPlayer, player.isPlaying else { return }
        let duration = 0.8
        let steps = 8
        let step = duration / Double(steps)
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(i)) {
                guard player.isPlaying else { return }
                player.volume = Float(1 - Double(i) / Double(steps))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            player.stop()
            player.volume = 1
        }
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
    private static let trashChuteOpenPlayer = loadPlayer("trash-chute-open.mp3")
    private static let trashChuteClosePlayer = loadPlayer("trash-chute-close.mp3")

    @discardableResult
    static func playTrashChuteOpen() -> Bool { playChuteSound(trashChuteOpenPlayer) }

    @discardableResult
    static func playTrashChuteClose() -> Bool { playChuteSound(trashChuteClosePlayer) }

    private static func playChuteSound(_ player: AVAudioPlayer?) -> Bool {
        guard let player else { return false }
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
            print("SoundEffects: chute playback did not start")
        }
        return started
    }
    private static let mailPickupPlayer = loadPlayer("mail-pick-up.mp3")
    private static let mailDeliveryPlayer = loadPlayer("mail-letter-drop-in-door-slot.mp3")

    @discardableResult
    static func playMailPickup() -> Bool { playMailSound(mailPickupPlayer) }

    @discardableResult
    static func playMailDelivery() -> Bool { playMailSound(mailDeliveryPlayer) }

    private static let extinguisherSprayPlayer = loadPlayer("fire_extinguisher.mp3")
    private static let fireExtinguishedPlayer = loadPlayer("fire-extinguished.mp3")
    private static let cameraClickPlayer = loadPlayer("iphone-camera-click.mp3")

    /// Eddie, Sept 12: "Grabbing the fire extinguisher currently has
    /// no sound... Add it to the existing Audio resources using the
    /// same safe/preloaded audio architecture already used by the
    /// game." Distinct from extinguisherSprayPlayer above (that one
    /// is the put-out-a-fire spray, playExtinguisherSpray()) -- this
    /// is the one-shot pickup cue, called once from
    /// collectExtinguisherIfPresent's completed-pickup branch only
    /// (never from a mere tap/visibility check).
    private static let extinguisherGrabPlayer = loadPlayer("extinguisher-grab.mp3")

    @discardableResult
    static func playExtinguisherGrab() -> Bool {
        playMailSound(extinguisherGrabPlayer)
    }

    static func playCameraClick() {
        _ = playMailSound(cameraClickPlayer)
    }

    @discardableResult
    static func playExtinguisherSpray() -> Bool {
        playMailSound(extinguisherSprayPlayer)
    }

    static func stopExtinguisherSpray() { extinguisherSprayPlayer?.stop() }

    static func playFireExtinguished() {
        guard let player = fireExtinguishedPlayer else { return }
        player.currentTime = 0
        player.play()
    }

    private static func playMailSound(_ player: AVAudioPlayer?) -> Bool {
        guard let player else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("SoundEffects: could not activate mail audio: \(error)")
        }
        player.currentTime = 0
        return player.play()
    }

    /// Eddie, Sept 13: four sounds for Floor 7's Tic-Tac-Toe aptitude
    /// test, supplied after confirming the game itself is "FUCKING
    /// PERFECT" on-device -- wired to the four obvious events only,
    /// reusing the same preloaded-AVAudioPlayer/playMailSound
    /// architecture as everything else in this file rather than a
    /// second audio system. Each is called from exactly one place in
    /// TicTacToeOverlay.swift so it fires once per event:
    /// ticTacToeXPlayer/ticTacToeOPlayer right after a mark lands on
    /// the board, ticTacToeWinPlayer the instant the player completes
    /// a winning line, ticTacToeLosePlayer on either the computer's
    /// winning line or a full-board draw.
    private static let ticTacToeXPlayer = loadPlayer("game-ttt-x.mp3")
    private static let ticTacToeOPlayer = loadPlayer("game-ttt-o.mp3")
    private static let ticTacToeWinPlayer = loadPlayer("game-ttt-win.mp3")
    private static let ticTacToeLosePlayer = loadPlayer("game-ttt-lose.mp3")

    @discardableResult
    static func playTicTacToeX() -> Bool { playMailSound(ticTacToeXPlayer) }

    @discardableResult
    static func playTicTacToeO() -> Bool { playMailSound(ticTacToeOPlayer) }

    @discardableResult
    static func playTicTacToeWin() -> Bool { playMailSound(ticTacToeWinPlayer) }

    @discardableResult
    static func playTicTacToeLose() -> Bool { playMailSound(ticTacToeLosePlayer) }

    /// Eddie, Sept 24: door-knock escalation -- the first knock is soft,
    /// the second within five seconds is medium, the third hard, and
    /// every further knock inside the same five-second window stays hard;
    /// any gap greater than five seconds resets the ladder so the next
    /// knock is soft again. All three MP3s live in Audio/ like every
    /// other sound here. They are NOT interchangeable: a stage MUST play
    /// its own file -- if the file for the stage in question can't be
    /// loaded or won't start, that is reported loudly and never silently
    /// substituted (no bouncing back to soft/medium just because the hard
    /// knock is missing).
    static let knockResetInterval: TimeInterval = 5

    private static let knockSoftPlayer = loadPlayer("knock-soft.mp3")
    private static let knockMediumPlayer = loadPlayer("knock-medium.mp3")
    private static let knockHardPlayer = loadPlayer("knock-hard.mp3")

    /// Ladder position for the NEXT knock: 0 = soft, 1 = medium, 2 = hard
    /// (capped). Last-knock timestamp decides whether the five-second
    /// window is still open.
    private static var knockStage = 0
    private static var lastKnockAt: Date = .distantPast

    /// The exact file each ladder stage must play -- internal (not
    /// private) so tests can assert the escalation names directly.
    static func knockFilename(forStage stage: Int) -> String? {
        switch stage {
        case 0: return "knock-soft.mp3"
        case 1: return "knock-medium.mp3"
        default: return "knock-hard.mp3"
        }
    }

    /// The filename played by the most recent playKnock (nil if it never
    /// started) -- lets tests observe the ladder without timing audio.
    internal private(set) static var lastKnockFilename: String?

    /// Test harness seam: forget the ladder so a fresh ladder can be
    /// stamped without real sleeping.
    static func resetKnockLadder() {
        knockStage = 0
        lastKnockAt = .distantPast
        lastKnockFilename = nil
    }

    static func playKnock() -> Bool { playKnock(at: Date()) }

    /// now is injected so the five-second reset is deterministic in
    /// tests; the real callers go through the no-argument playKnock().
    static func playKnock(at now: Date) -> Bool {
        if now.timeIntervalSince(lastKnockAt) > knockResetInterval {
            knockStage = 0
        }
        lastKnockAt = now
        defer { knockStage = min(knockStage + 1, 2) }

        let player: AVAudioPlayer?
        switch knockStage {
        case 0: player = knockSoftPlayer
        case 1: player = knockMediumPlayer
        default: player = knockHardPlayer
        }
        guard let player else {
            print("SoundEffects: knock stage \(knockStage) needs \(knockFilename(forStage: knockStage) ?? "?") but it could not be loaded -- NOT substituting another knock sound.")
            return false
        }
        let started = playKnockSound(player)
        if started { lastKnockFilename = knockFilename(forStage: knockStage) }
        return started
    }

    /// knockStep shares the session-activation + rewind + start shape of
    /// playChuteSound (the closest sibling: also reports a play() that
    /// didn't start), which is exactly what the no-substitution rule
    /// needs -- a hard-knock failure is reported, not muffled.
    private static func playKnockSound(_ player: AVAudioPlayer) -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("SoundEffects: could not activate knock audio: \(error)")
        }
        player.currentTime = 0
        let started = player.play()
        if !started {
            print("SoundEffects: knock playback did not start (\(player.url?.lastPathComponent ?? "unknown"))")
        }
        return started
    }

}
