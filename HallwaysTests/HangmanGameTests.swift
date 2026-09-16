import Testing
@testable import Hallways

/// Pure state-transition tests for Floor 12's Hangman -- no timers, no
/// waiting, since HangmanGame itself owns none of the word-selection
/// or presentation logic (the SwiftUI overlay's view model owns that).
/// See HangmanTerminalTests.swift for the mission-completion/elevator-
/// lock integration.
struct HangmanGameTests {
    @Test func initialStateIsReady() {
        let game = HangmanGame()
        #expect(game.phase == .ready)
        #expect(game.word.isEmpty)
        #expect(game.guessedLetters.isEmpty)
        #expect(game.wrongGuessCount == 0)
    }

    @Test func startEntersPlayingWithTheGivenWord() {
        var game = HangmanGame()
        game.start(word: "HOUSE")
        #expect(game.phase == .playing)
        #expect(game.word == "HOUSE")
        #expect(game.wrongGuessCount == 0)
    }

    @Test func startRejectsAWronglySizedWord() {
        var game = HangmanGame()
        game.start(word: "CAT")
        #expect(game.phase == .ready)
        #expect(game.word.isEmpty)
    }

    @Test func startRejectsALowercaseWord() {
        var game = HangmanGame()
        game.start(word: "house")
        #expect(game.phase == .ready)
        #expect(game.word.isEmpty)
    }

    @Test func startIsANoOpOnceAlreadyPlaying() {
        var game = HangmanGame()
        game.start(word: "HOUSE")
        game.start(word: "CHAIR") // no-op: phase is no longer .ready
        #expect(game.word == "HOUSE")
    }

    @Test func correctGuessRevealsTheLetterWithoutCountingAsWrong() {
        var game = HangmanGame()
        game.start(word: "HOUSE")
        game.guess("H")
        #expect(game.wrongGuessCount == 0)
        #expect(game.revealedWord == [Character("H"), nil, nil, nil, nil])
    }

    @Test func wrongGuessIncrementsCountAndDoesNotRevealAnything() {
        var game = HangmanGame()
        game.start(word: "HOUSE")
        game.guess("Z")
        #expect(game.wrongGuessCount == 1)
        #expect(game.revealedWord == [nil, nil, nil, nil, nil])
        #expect(game.phase == .playing)
    }

    @Test func guessNormalizesLowercaseInput() {
        var game = HangmanGame()
        game.start(word: "HOUSE")
        game.guess("h") // lowercase tap should still count as "H"
        #expect(game.guessedLetters.contains("H"))
        #expect(game.revealedWord[0] == Character("H"))
    }

    @Test func alreadyGuessedLetterIsANoOp() {
        var game = HangmanGame()
        game.start(word: "HOUSE")
        game.guess("Z") // wrong, count -> 1
        game.guess("Z") // same letter again -- must not double-count
        #expect(game.wrongGuessCount == 1)
    }

    @Test func fifthWrongGuessDoesNotYetFail() {
        var game = HangmanGame()
        game.start(word: "HOUSE")
        for letter in ["B", "C", "D", "F", "G"] { // 5 wrong guesses, none in HOUSE
            game.guess(Character(letter))
        }
        #expect(game.wrongGuessCount == 5)
        #expect(game.phase == .playing)
    }

    @Test func sixthWrongGuessCausesFailure() {
        var game = HangmanGame()
        game.start(word: "HOUSE")
        for letter in ["B", "C", "D", "F", "G", "J"] { // 6 wrong guesses
            game.guess(Character(letter))
        }
        #expect(game.wrongGuessCount == 6)
        #expect(game.phase == .failure)
    }

    @Test func noFurtherScoringAfterFailure() {
        var game = HangmanGame()
        game.start(word: "HOUSE")
        for letter in ["B", "C", "D", "F", "G", "J"] {
            game.guess(Character(letter))
        }
        #expect(game.phase == .failure)
        game.guess("H") // no-op: phase is no longer .playing
        #expect(game.wrongGuessCount == 6)
        #expect(game.revealedWord == [nil, nil, nil, nil, nil])
    }

    @Test func allLettersRevealedCausesSuccess() {
        var game = HangmanGame()
        game.start(word: "HOUSE")
        for letter in ["H", "O", "U", "S", "E"] {
            game.guess(Character(letter))
        }
        #expect(game.phase == .success)
        #expect(game.wrongGuessCount == 0)
    }

    @Test func duplicateLettersInAWordAreAllRevealedByOneGuess() {
        // "APPLE" has two P's -- a single correct guess of "P" must
        // reveal both positions at once, and success must not require
        // guessing "P" twice.
        var game = HangmanGame()
        game.start(word: "APPLE")
        game.guess("A")
        game.guess("P")
        #expect(game.revealedWord == [Character("A"), Character("P"), Character("P"), nil, nil])
        game.guess("L")
        game.guess("E")
        #expect(game.phase == .success)
    }

    @Test func noFurtherGuessesAfterSuccess() {
        var game = HangmanGame()
        game.start(word: "HOUSE")
        for letter in ["H", "O", "U", "S", "E"] {
            game.guess(Character(letter))
        }
        #expect(game.phase == .success)
        game.guess("Z") // no-op: phase is no longer .playing
        #expect(game.phase == .success)
        #expect(game.wrongGuessCount == 0)
    }

    @Test func retryResetReturnsToReady() {
        var game = HangmanGame()
        game.start(word: "HOUSE")
        for letter in ["B", "C", "D", "F", "G", "J"] {
            game.guess(Character(letter))
        }
        #expect(game.phase == .failure)
        game.reset()
        #expect(game.phase == .ready)
        #expect(game.word.isEmpty)
        #expect(game.guessedLetters.isEmpty)
        #expect(game.wrongGuessCount == 0)
    }

    @Test func firstUnguessedLetterReflectsRemainingLetters() {
        // Documents the seam a future Hint button would use -- not
        // wired to any UI yet, but must behave correctly today.
        var game = HangmanGame()
        game.start(word: "HOUSE")
        #expect(game.firstUnguessedLetter == "H")
        game.guess("H")
        #expect(game.firstUnguessedLetter == "O")
        for letter in ["O", "U", "S", "E"] {
            game.guess(Character(letter))
        }
        #expect(game.firstUnguessedLetter == nil)
    }

    @Test func aFreshGameNeverCarriesOverPriorState() {
        // Mirrors SimonGameTests' equivalent check: a brand new
        // HangmanGame() is always a clean .ready slate regardless of
        // what any other instance did.
        var gameA = HangmanGame()
        gameA.start(word: "HOUSE")
        gameA.guess("Z")

        let gameB = HangmanGame()
        #expect(gameB.phase == .ready)
        #expect(gameB.word.isEmpty)
        #expect(gameB.wrongGuessCount == 0)
    }
}

/// Shape checks for the curated word bank, plus the RETRY-excludes-
/// previous-word picker. Eddie: "curated local list of very common,
/// instantly recognizable English words" -- these tests are the
/// automated guardrail that keeps every entry exactly 5 letters,
/// uppercase, and unique, and keeps the bank reasonably sized.
struct HangmanWordBankTests {
    @Test func everyWordIsExactlyFiveLetters() {
        for word in HangmanWordBank.words {
            #expect(word.count == HangmanGame.wordLength, "\(word) is not 5 letters")
        }
    }

    @Test func everyWordIsUppercaseLettersOnly() {
        for word in HangmanWordBank.words {
            #expect(word == word.uppercased(), "\(word) is not uppercase")
            #expect(word.allSatisfy { $0.isLetter }, "\(word) contains a non-letter character")
        }
    }

    @Test func noDuplicateWords() {
        #expect(Set(HangmanWordBank.words).count == HangmanWordBank.words.count)
    }

    @Test func bankIsReasonablySized() {
        // Eddie: "Please create a reasonably sized curated word bank
        // rather than only [the ten] examples." Not pinned to an
        // exact number -- just guards against the bank shrinking back
        // down to a token handful.
        #expect(HangmanWordBank.words.count >= 50)
    }

    @Test func pickWordAlwaysReturnsABankMember() {
        var rng = SeededRNG(seed: 10)
        for _ in 0..<50 {
            let word = HangmanWordPicker.pickWord(using: &rng)
            #expect(HangmanWordBank.words.contains(word))
        }
    }

    @Test func pickWordExcludingPreviousNeverRepeatsImmediately() {
        var rng = SeededRNG(seed: 11)
        var previous = HangmanWordPicker.pickWord(using: &rng)
        for _ in 0..<200 {
            let next = HangmanWordPicker.pickWord(excluding: previous, using: &rng)
            #expect(next != previous)
            #expect(HangmanWordBank.words.contains(next))
            previous = next
        }
    }
}
