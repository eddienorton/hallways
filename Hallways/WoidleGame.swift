import Foundation

/// Floor 16's embedded mini-game -- WOIDLE (Eddie, Sept 14), the
/// Building's five-letter word deduction assessment. Working internal
/// name per Eddie: "WOIDLE / WEIRDLE."
///
/// Product intent (Eddie): "This should evoke the familiar five-letter
/// word deduction game immediately without copying branded visual
/// design... Do not over-explain it. Do not reinvent the rules to
/// make it 'ours.' Hallways is the novel context; the familiar
/// mechanic should stay familiar." This is the classic mechanic,
/// nothing more: a secret 5-letter answer, 6 guesses, each guessed
/// letter scored CORRECT-POSITION / WRONG-POSITION / ABSENT with
/// correct duplicate-letter accounting.
///
/// Pure game STATE only, no SwiftUI/timer/RNG of its own -- same
/// separation as HangmanGame: the SwiftUI overlay (WoidleOverlay.swift)
/// owns answer selection (via WoidleAnswerPicker) and word-list
/// validation (via WoidleWordBank), and calls into this struct with
/// plain, fully deterministic state transitions (start(answer:),
/// typeLetter(_:), deleteLetter(), submit(isAllowed:), reset()) that
/// are all testable without any real waiting or any dependency on the
/// word lists themselves -- evaluate(guess:answer:) in particular is
/// a free function testable with completely made-up 5-letter strings.
nonisolated struct WoidleGame: Equatable {
    enum Phase: Equatable {
        case playing
        case won
        case lost
    }

    /// Per-letter result of one submitted guess.
    enum LetterResult: Equatable {
        case correct
        case present
        case absent
    }

    /// Strongest known information about one keyboard letter across
    /// every guess submitted so far. Eddie: "If a letter receives
    /// multiple statuses across guesses, preserve the strongest known
    /// information: CORRECT > PRESENT > ABSENT." Ordered by rawValue
    /// so "strongest" is just "greatest."
    enum KeyStatus: Int, Equatable {
        case unknown = 0
        case absent = 1
        case present = 2
        case correct = 3
    }

    /// Eddie: "Secret answer is exactly 5 letters... Player gets 6
    /// guesses."
    static let wordLength = 5
    static let maxGuesses = 6

    private(set) var phase: Phase = .playing
    /// Always uppercase, always exactly wordLength letters once
    /// start(answer:) has run. Set once, never mutated afterward
    /// (only reset() clears it) -- same "never drifts" contract as
    /// HangmanGame.word.
    private(set) var answer: String = ""
    /// Every guess the player has SUBMITTED so far, in order, always
    /// uppercase and exactly wordLength letters.
    private(set) var guesses: [String] = []
    /// evaluations[i] is the per-letter result of guesses[i] -- kept
    /// as a parallel array (rather than zipped into one struct) so
    /// both stay trivial value types with no risk of one entry
    /// silently outliving or outrunning the other.
    private(set) var evaluations: [[LetterResult]] = []
    /// Letters typed for the CURRENT, not-yet-submitted row. Cleared
    /// on every successful submit, never on a rejected one -- Eddie:
    /// "keep the row editable" when a guess is rejected.
    private(set) var currentInput: String = ""
    /// Set the instant a submit() call is rejected (not a real
    /// English word per the allowed list, per Eddie's "brief clear
    /// feedback such as 'NOT IN WORD LIST'... no modal alert").
    /// Cleared the moment the player types or deletes a letter, or
    /// successfully submits -- so it reads as transient feedback tied
    /// to the row they're actively editing, not a lingering banner.
    private(set) var lastRejectionReason: String?

    /// Only reachable with a properly-sized, uppercase answer
    /// (WoidleOverlay always supplies one via WoidleAnswerPicker,
    /// drawn from WoidleAnswerBank). Safe to call from any phase --
    /// this is also how RETRY starts the next puzzle, via reset()
    /// then start(answer:).
    mutating func start(answer: String) {
        guard answer.count == Self.wordLength, answer == answer.uppercased() else { return }
        self.answer = answer
        guesses = []
        evaluations = []
        currentInput = ""
        lastRejectionReason = nil
        phase = .playing
    }

    /// Eddie: "Large, forgiving tap targets... Do not submit until
    /// exactly 5 letters are entered." A no-op once 5 letters are
    /// already typed, or outside .playing, so a stale tap can never
    /// grow a row past the board.
    mutating func typeLetter(_ letter: Character) {
        guard phase == .playing, currentInput.count < Self.wordLength else { return }
        lastRejectionReason = nil
        currentInput.append(Character(String(letter).uppercased()))
    }

    mutating func deleteLetter() {
        guard phase == .playing, !currentInput.isEmpty else { return }
        lastRejectionReason = nil
        currentInput.removeLast()
    }

    /// Eddie: "If the guess is not in the allowed-word list: give
    /// brief clear feedback such as 'NOT IN WORD LIST', keep the row
    /// editable, do not consume an attempt, no modal alert." The
    /// caller supplies the dictionary check (WoidleOverlay passes
    /// WoidleWordBank.isAllowed) so this struct never needs to know
    /// about the word lists themselves -- keeps evaluate() and every
    /// other rule here testable with any made-up 5-letter string.
    mutating func submit(isAllowed: (String) -> Bool) {
        guard phase == .playing, currentInput.count == Self.wordLength else { return }
        guard isAllowed(currentInput) else {
            lastRejectionReason = "NOT IN WORD LIST"
            return
        }
        let evaluation = Self.evaluate(guess: currentInput, answer: answer)
        guesses.append(currentInput)
        evaluations.append(evaluation)
        lastRejectionReason = nil
        if currentInput == answer {
            phase = .won
        } else if guesses.count >= Self.maxGuesses {
            phase = .lost
        }
        currentInput = ""
    }

    /// The classic two-pass Wordle scoring algorithm, factored out as
    /// a free function so it's directly testable against hand-picked
    /// guess/answer pairs with no CheckersGame-style board fixture
    /// needed. Pass 1 claims every correct-position match and removes
    /// that letter from the answer's "still available" pool. Pass 2
    /// then scores every remaining letter as present-or-absent purely
    /// against what's left in that pool -- this is what makes
    /// duplicate-letter accounting correct: Eddie's own example, "if
    /// the answer contains one E and the guess contains two Es, do
    /// not mark both as present unless the answer actually supports
    /// both occurrences," falls out for free, since the pool only
    /// ever has as many of a letter as the answer actually contains,
    /// and pass 1 already spent whichever copies landed in the right
    /// spot.
    static func evaluate(guess: String, answer: String) -> [LetterResult] {
        let g = Array(guess)
        let a = Array(answer)
        var result = [LetterResult](repeating: .absent, count: g.count)
        var remaining: [Character: Int] = [:]
        for i in 0..<a.count {
            if i < g.count, g[i] == a[i] {
                result[i] = .correct
            } else {
                remaining[a[i], default: 0] += 1
            }
        }
        for i in 0..<g.count where result[i] != .correct {
            let letter = g[i]
            if let count = remaining[letter], count > 0 {
                result[i] = .present
                remaining[letter] = count - 1
            } else {
                result[i] = .absent
            }
        }
        return result
    }

    /// Drives the on-screen keyboard's per-key coloring. Derived
    /// fresh from guesses + evaluations every time, never cached --
    /// same "single source of truth, nothing to drift" discipline as
    /// HangmanGame.revealedWord.
    var keyStatuses: [Character: KeyStatus] {
        var result: [Character: KeyStatus] = [:]
        for (guess, evaluation) in zip(guesses, evaluations) {
            for (letter, letterResult) in zip(guess, evaluation) {
                let newStatus: KeyStatus
                switch letterResult {
                case .correct: newStatus = .correct
                case .present: newStatus = .present
                case .absent: newStatus = .absent
                }
                let existing = result[letter] ?? .unknown
                if newStatus.rawValue > existing.rawValue {
                    result[letter] = newStatus
                }
            }
        }
        return result
    }

    /// Eddie: "retry starts a fresh puzzle." Resets everything back
    /// to a blank slate -- WoidleOverlay's view model is what actually
    /// picks the next answer (excluding the one just played) and
    /// calls start(answer:) again, same shape as HangmanViewModel.
    mutating func reset() {
        phase = .playing
        answer = ""
        guesses = []
        evaluations = []
        currentInput = ""
        lastRejectionReason = nil
    }
}

/// Eddie: "a curated answer list of common, recognizable 5-letter
/// English words... Avoid obscure dictionary garbage, proper nouns,
/// abbreviations, offensive/slur words, highly specialized archaic
/// words. This is more about recognition, deduction, and nostalgia
/// than trying to defeat expert word-game players." All entries are
/// exactly 5 letters, uppercase, ordinary. (See WoidleGameTests for
/// the automated shape checks -- length, uppercase, no duplicates --
/// that keep this list honest.)
nonisolated enum WoidleAnswerBank {
    static let words: [String] = [
        "ABOUT", "ABOVE", "ADULT", "AFTER", "AGAIN", "AGREE", "AHEAD", "ALARM", "ALBUM", "ALERT",
        "ALIVE", "ALLOW", "ALONE", "ALONG", "ANGEL", "ANGER", "ANGLE", "ANGRY", "APPLY", "ARENA",
        "ARGUE", "ARISE", "ARROW", "ASIDE", "AVOID", "AWAKE", "AWARD", "AWARE", "BADLY", "BASIC",
        "BEGIN", "BELOW", "BENCH", "BIRTH", "BLAME", "BLANK", "BLAST", "BLEND", "BLESS", "BLIND",
        "BLOCK", "BLOOD", "BOARD", "BOOST", "BOUND", "BRAND", "BRAVE", "BREAK", "BRIEF", "BRING",
        "BROAD", "BROKE", "BUILD", "BUNCH", "BURST", "CABIN", "CARGO", "CARRY", "CATCH", "CAUSE",
        "CHAIN", "CHALK", "CHARM", "CHART", "CHASE", "CHEAP", "CHECK", "CHEST", "CHIEF", "CHILD",
        "CIVIL", "CLAIM", "CLASS", "CLEAN", "CLEAR", "CLICK", "CLIFF", "CLIMB", "CLOSE", "CLOTH",
        "COAST", "COUNT", "COURT", "COVER", "CRAFT", "CRASH", "CRAZY", "CREEK", "CRIME", "CROSS",
        "CROWD", "CRUEL", "CURVE", "CYCLE", "DAILY", "DEPTH", "DOUBT", "DOZEN", "DRAFT", "DRAMA"
    ]
}

/// Eddie: "a broader local allowed-guess list if useful." Kept
/// separate from the answer bank so the answer pool can stay small
/// and tightly curated while the set of WORDS THE PLAYER MAY TYPE is
/// more generous -- WoidleWordBank.allWords is the union of both, so
/// the secret answer itself is always guaranteed to be a legal guess.
nonisolated enum WoidleWordBank {
    static let extraAllowedWords: [String] = [
        "DRANK", "DRAWN", "DRESS", "DRIED", "DRIFT", "DRINK", "DRIVE", "DROVE", "EAGER", "EARLY",
        "ELECT", "EMPTY", "ENEMY", "ENJOY", "ENTER", "ENTRY", "EQUAL", "ERROR", "EVENT", "EVERY",
        "EXACT", "EXIST", "EXTRA", "FAITH", "FALSE", "FAULT", "FIFTH", "FIGHT", "FINAL", "FIXED",
        "FLASH", "FLEET", "FLOOR", "FLUID", "FOCUS", "FORCE", "FORTH", "FORTY", "FORUM", "FOUND",
        "FRAME", "FRESH", "FRONT", "FROST", "FRUIT", "FUNNY", "GIANT", "GLOBE", "GLORY", "GRACE",
        "GRADE", "GRAND", "GRANT", "GRAPH", "GRASP", "GREAT", "GREET", "GROSS", "GROUP", "GROWN",
        "GUARD", "GUESS", "GUEST", "GUIDE", "HABIT", "HAPPY", "HEAVY", "HELLO", "HONOR", "HORSE",
        "HOTEL", "HOUSE", "HUMAN", "IDEAL", "IMAGE", "IMPLY", "INDEX", "INNER", "INPUT", "ISSUE",
        "JOINT", "JUDGE", "JUICE", "KNIFE", "KNOWN", "LABEL", "LABOR", "LARGE", "LAUGH", "LAYER",
        "LEARN", "LEAST", "LEAVE", "LEGAL", "LEVEL", "LIGHT", "LIMIT", "LOCAL", "LOGIC", "LOOSE"
    ]

    /// Every word the player is allowed to submit as a guess -- the
    /// answer bank plus the supplementary list above. A Set, computed
    /// once, since submit() calls this on every ENTER tap.
    static let allWords: Set<String> = Set(WoidleAnswerBank.words).union(extraAllowedWords)

    static func isAllowed(_ word: String) -> Bool {
        let uppercased = word.uppercased()
        // Tier 1: the curated list -- fast, and guarantees every
        // word already accepted keeps being accepted exactly as
        // before.
        if allWords.contains(uppercased) { return true }
        // Tier 2 (Eddie, Sept 14): the same fallback mechanism his
        // older Word Puzzie project used -- Apple's on-device system
        // dictionary -- for ordinary words the curated list doesn't
        // happen to cover (e.g. inflected forms like LIKES/MAKES/
        // TAKES). See WoidleSystemDictionary.swift.
        return WoidleSystemDictionary.isValidWord(uppercased)
    }
}

/// Eddie: "Choose answers randomly, and on immediate retry avoid
/// repeating the same answer if practical." Same shape as
/// HangmanWordPicker -- a small, pure, testable picker that always
/// returns a word from WoidleAnswerBank, and when `excluding` is
/// supplied (a RETRY) and the bank has more than one entry, guarantees
/// a different answer than the one just played.
nonisolated enum WoidleAnswerPicker {
    static func pickAnswer<G: RandomNumberGenerator>(excluding previous: String? = nil, using rng: inout G) -> String {
        let bank = WoidleAnswerBank.words
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
