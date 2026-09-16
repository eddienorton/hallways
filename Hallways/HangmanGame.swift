import Foundation

/// Floor 12's embedded mini-game -- HANGMAN (Eddie, Sept 14), replacing
/// the removed Whack-A-Mole in the same Floor 12 slot.
///
/// Product intent (Eddie): "We are trying to trigger recognition and
/// nostalgia... The player gets to enjoy a short, recognizable version
/// of it, succeeds without excessive difficulty, and continues up the
/// Building... Do not reinvent Hangman. Do not add a clever
/// Hallways-specific ruleset... Hangman should simply feel like
/// Hangman." This is classic Hangman, nothing more: exactly 5-letter
/// words, 6 wrong guesses allowed, guess the whole word to win.
///
/// Pure game STATE only, no SwiftUI/timer/RNG of its own -- the
/// SwiftUI overlay (HangmanOverlay.swift) owns word selection (via
/// HangmanWordPicker) and calls into this struct with plain, fully
/// deterministic state transitions (start(word:), guess(_:), reset())
/// that are all testable without any real waiting. Same shape as
/// SimonGame/ShellGameRound -- a small, honest state machine, no
/// hidden framework.
nonisolated struct HangmanGame: Equatable {
    enum Phase: Equatable {
        case ready
        case playing
        case success
        case failure
    }

    /// Eddie: "Allow 6 wrong guesses before losing."
    static let maxWrongGuesses = 6
    /// Eddie: "Exactly 5-letter words."
    static let wordLength = 5
    /// Single source of truth for the on-screen alphabet control --
    /// A...Z, nothing more, nothing fewer.
    static let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    private(set) var phase: Phase = .ready
    /// The word for this playthrough -- always uppercase, always
    /// exactly wordLength letters. Set once by start(word:), never
    /// mutated afterward (only reset() clears it).
    private(set) var word: String = ""
    /// Every letter the PLAYER has tapped so far, right or wrong --
    /// Eddie: "Already-guessed letters cannot be guessed again."
    private(set) var guessedLetters: Set<Character> = []
    private(set) var wrongGuessCount = 0

    /// Eddie: "Correct letters appear in their appropriate positions."
    /// Derived every time from word + guessedLetters, never cached or
    /// set directly -- there is no separate "revealed" array that
    /// could ever drift out of sync with what's actually been
    /// guessed.
    var revealedWord: [Character?] {
        word.map { guessedLetters.contains($0) ? $0 : nil }
    }

    /// Only reachable from .ready, and only with a properly-sized,
    /// uppercase word (HangmanOverlay always supplies one via
    /// HangmanWordPicker, drawn from HangmanWordBank).
    mutating func start(word: String) {
        guard phase == .ready, word.count == Self.wordLength, word == word.uppercased() else { return }
        self.word = word
        guessedLetters = []
        wrongGuessCount = 0
        phase = .playing
    }

    /// Eddie: "Correct letters appear in their appropriate positions.
    /// Already-guessed letters cannot be guessed again. Wrong guesses
    /// progressively construct the classic Hangman drawing... Win
    /// when all five letters are revealed. Lose after the sixth
    /// incorrect guess." A no-op outside .playing, or for a letter
    /// already tried, so a stale/duplicate tap can never double-count
    /// a wrong guess or flip an already-decided game.
    mutating func guess(_ letter: Character) {
        guard phase == .playing else { return }
        let upper = Character(String(letter).uppercased())
        guard !guessedLetters.contains(upper) else { return }
        guessedLetters.insert(upper)
        guard word.contains(upper) else {
            wrongGuessCount += 1
            if wrongGuessCount >= Self.maxWrongGuesses {
                phase = .failure
            }
            return
        }
        if Set(word).isSubset(of: guessedLetters) {
            phase = .success
        }
    }

    /// Eddie: "structure the game cleanly enough that we could later
    /// add a hint which reveals one unguessed letter... version 1
    /// does not need it." This is that seam -- not wired to any UI in
    /// this version, but a future Hint button would just call
    /// guess(firstUnguessedLetter) directly, with no other changes
    /// needed anywhere in this file.
    var firstUnguessedLetter: Character? {
        word.first { !guessedLetters.contains($0) }
    }

    /// Eddie: "On loss, reveal the word and provide an immediate
    /// RETRY... RETRY should select another word if reasonably
    /// possible." Resets back to the .ready slate -- HangmanOverlay's
    /// view model is what actually picks the next word (excluding the
    /// one just played) and calls start(word:) again.
    mutating func reset() {
        phase = .ready
        word = ""
        guessedLetters = []
        wrongGuessCount = 0
    }
}

/// Eddie: "curated local list of very common, instantly recognizable
/// English words... Avoid obscure words, slang, proper nouns, unusual
/// spellings, Scrabble-type vocabulary." All entries are exactly 5
/// letters, uppercase, ordinary enough that a player recognizes the
/// word instantly -- this is a recognition game, not a vocabulary
/// test. (See HangmanGameTests for the automated shape checks --
/// length, uppercase, no duplicates -- that keep this list honest.)
nonisolated enum HangmanWordBank {
    static let words: [String] = [
        "HOUSE", "CHAIR", "MONEY", "LIGHT", "WATER", "MUSIC", "BREAD", "BEACH", "APPLE", "HAPPY",
        "TABLE", "PHONE", "STORY", "SMILE", "DANCE", "BRAIN", "HEART", "CLOUD", "RIVER", "OCEAN",
        "PIANO", "PIZZA", "SUGAR", "HONEY", "SNAKE", "TIGER", "HORSE", "SHEEP", "MOUSE", "EAGLE",
        "PLANT", "GRASS", "STONE", "SHIRT", "PANTS", "GLOVE", "TOWEL", "BROOM", "KNIFE", "SPOON",
        "CANDY", "SWEET", "BERRY", "LEMON", "GRAPE", "MANGO", "PEACH", "MELON", "OLIVE", "GRAIN",
        "WHEAT", "CREAM", "JUICE", "STEAK", "TOAST", "SALAD", "CLOCK", "GLASS", "BENCH", "FENCE",
        "FIELD", "TRAIN", "PLANE", "TRUCK", "WHEEL", "BRICK", "STAIR", "ROOMS", "DOORS", "COUCH",
        "FLAME", "SMOKE", "STORM", "SHORE", "WAVES", "SHELL", "STARS", "EARTH", "NORTH", "SOUTH",
        "CROWN", "SWORD", "ARROW", "MAGIC", "GHOST", "CLOWN", "PARTY", "SOUND", "VOICE", "RADIO",
        "VIDEO", "MOVIE", "PAPER", "BRUSH", "PAINT", "COLOR", "BLACK", "WHITE", "GREEN", "BROWN",
        "SMALL", "LARGE", "QUICK", "SLEEP", "DREAM", "NIGHT"
    ]
}

/// Eddie: "Choose one word randomly when a game begins... RETRY should
/// select another word if reasonably possible." A small, pure,
/// testable picker -- always returns a word from HangmanWordBank, and
/// when `excluding` is supplied (a RETRY) and the bank has more than
/// one entry, guarantees a different word than the one just played.
nonisolated enum HangmanWordPicker {
    static func pickWord<G: RandomNumberGenerator>(excluding previous: String? = nil, using rng: inout G) -> String {
        let bank = HangmanWordBank.words
        guard let previous, bank.count > 1 else {
            return bank.randomElement(using: &rng) ?? bank[0]
        }
        var candidate = bank.randomElement(using: &rng) ?? bank[0]
        while candidate == previous {
            candidate = bank.randomElement(using: &rng) ?? bank[0]
        }
        return candidate
    }
}
