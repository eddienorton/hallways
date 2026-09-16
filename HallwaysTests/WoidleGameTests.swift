import Testing
@testable import Hallways

/// Pure state-transition tests for Floor 16's Woidle (working name per
/// Eddie: "WOIDLE / WEIRDLE") -- no timers, no waiting, since
/// WoidleGame itself owns none of the answer-selection or word-list
/// validation logic (the SwiftUI overlay's view model owns that, via
/// WoidleAnswerPicker/WoidleWordBank). See WoidleTerminalTests.swift
/// for the mission-completion/elevator-lock integration.
///
/// Eddie's explicit emphasis: "Duplicate letter handling is the
/// classic place these games get subtly wrong... validate this
/// independently before trusting the UI to just 'look right.'" Every
/// evaluate(guess:answer:) fixture below (and the ones baked into
/// duplicateLetter* in particular) was independently checked against a
/// standalone Python re-implementation of the exact two-pass algorithm
/// in WoidleGame.evaluate before being transcribed here -- the same
/// technique used for Checkers' move fixtures.
struct WoidleGameTests {
    // MARK: - start / typing / deleting

    @Test func startSetsTheAnswerAndEntersPlaying() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        #expect(game.phase == .playing)
        #expect(game.answer == "CRANE")
        #expect(game.guesses.isEmpty)
        #expect(game.evaluations.isEmpty)
        #expect(game.currentInput.isEmpty)
    }

    // Eddie's required test: "the secret answer is always exactly 5
    // letters." start(answer:) itself is the single choke point every
    // answer passes through (both a fresh puzzle and a retry), so
    // guarding it here guarantees the invariant everywhere else.
    @Test func startRejectsAWronglySizedAnswer() {
        var game = WoidleGame()
        game.start(answer: "CAT")
        #expect(game.phase == .playing) // unchanged from the default
        #expect(game.answer.isEmpty)
    }

    @Test func startRejectsALowercaseAnswer() {
        var game = WoidleGame()
        game.start(answer: "crane")
        #expect(game.answer.isEmpty)
    }

    @Test func typingAppendsUppercaseLetters() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        game.typeLetter("c")
        game.typeLetter("R")
        #expect(game.currentInput == "CR")
    }

    // Eddie: "Do not submit until exactly 5 letters are entered." --
    // and correspondingly, typing must never be able to grow a row
    // past 5 letters in the first place.
    @Test func typingStopsAtFiveLetters() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        for letter in "CRANES" { game.typeLetter(letter) }
        #expect(game.currentInput == "CRANE")
    }

    @Test func deleteLetterRemovesTheLastCharacter() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        for letter in "CRA" { game.typeLetter(letter) }
        game.deleteLetter()
        #expect(game.currentInput == "CR")
    }

    @Test func deletingOnAnEmptyRowIsANoOp() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        game.deleteLetter()
        #expect(game.currentInput.isEmpty)
    }

    // MARK: - submit gating

    // Eddie's required test: "cannot submit fewer than 5 letters."
    @Test func submittingFewerThanFiveLettersIsANoOp() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        for letter in "CRA" { game.typeLetter(letter) }
        game.submit(isAllowed: { _ in true })
        #expect(game.guesses.isEmpty)
        #expect(game.phase == .playing)
        #expect(game.currentInput == "CRA")
    }

    // Eddie's required test: "an invalid dictionary guess does not
    // consume an attempt." Also: "keep the row editable... no modal
    // alert" -- currentInput must survive the rejection untouched.
    @Test func aWordNotInTheAllowedListIsRejectedWithoutConsumingAnAttempt() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        for letter in "ZZZZZ" { game.typeLetter(letter) }
        game.submit(isAllowed: { _ in false })
        #expect(game.guesses.isEmpty)
        #expect(game.phase == .playing)
        #expect(game.currentInput == "ZZZZZ")
        #expect(game.lastRejectionReason == "NOT IN WORD LIST")
    }

    @Test func typingAfterARejectionClearsTheRejectionReason() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        for letter in "ZZZZZ" { game.typeLetter(letter) }
        game.submit(isAllowed: { _ in false })
        #expect(game.lastRejectionReason != nil)
        game.deleteLetter()
        #expect(game.lastRejectionReason == nil)
    }

    @Test func aValidGuessClearsCurrentInputAndRecordsTheGuess() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        for letter in "CRATE" { game.typeLetter(letter) }
        game.submit(isAllowed: { _ in true })
        #expect(game.guesses == ["CRATE"])
        #expect(game.currentInput.isEmpty)
        #expect(game.lastRejectionReason == nil)
    }

    // MARK: - evaluate(guess:answer:) -- correct / present / absent

    @Test func correctPositionEvaluation() {
        // CRATE vs CRANE: first three and last letters land in the
        // right spot; only T (not present anywhere in CRANE) is absent.
        let result = WoidleGame.evaluate(guess: "CRATE", answer: "CRANE")
        #expect(result == [.correct, .correct, .correct, .absent, .correct])
    }

    @Test func presentButWrongPositionEvaluation() {
        // SNIPE vs CRANE: N is in CRANE but at a different index, so
        // it scores present rather than correct; E lands correct.
        let result = WoidleGame.evaluate(guess: "SNIPE", answer: "CRANE")
        #expect(result == [.absent, .present, .absent, .absent, .correct])
    }

    @Test func absentLetterEvaluation() {
        let result = WoidleGame.evaluate(guess: "CRANE", answer: "CRANE")
        #expect(!result.contains(.absent))
        let noOverlap = WoidleGame.evaluate(guess: "CRANE", answer: "SPOIL")
        #expect(noOverlap.allSatisfy { $0 == .absent })
    }

    // MARK: - duplicate-letter accounting (Eddie's explicit emphasis)

    // "If the answer has one E and the guess has two Es, do not mark
    // both as present unless the answer actually supports both
    // occurrences." Guess EAGLE has two Es; answer ABIDE has only one,
    // and that one E lands at the guess's correct-position slot (index
    // 4) -- so the SECOND E (index 0, wrong position) must come back
    // absent, not present, since the answer's only E was already
    // spent by the correct-position match.
    @Test func duplicateLetterInGuessWithOneCorrectPositionMatchDoesNotDoubleCountThePresentCopy() {
        let result = WoidleGame.evaluate(guess: "EAGLE", answer: "ABIDE")
        #expect(result == [.absent, .present, .absent, .absent, .correct])
        // Explicitly the case Eddie called out: exactly one of the two
        // guessed Es is ever marked present/correct, never both.
        let eIndices = [0, 4]
        let eStatuses = eIndices.map { result[$0] }
        #expect(eStatuses.filter { $0 == .correct }.count == 1)
        #expect(eStatuses.filter { $0 == .present }.count == 0)
    }

    // Guess has two copies of a letter (W), the answer has exactly
    // one, and NEITHER guessed copy is at the correct position. The
    // classic under-counting bug would mark both present (or, less
    // commonly, both absent) -- the correct behavior is exactly one
    // present (the earlier occurrence) and one absent.
    @Test func duplicateLetterInGuessWithNoCorrectPositionMatchMarksOnlyOneCopyPresent() {
        let result = WoidleGame.evaluate(guess: "WQWRT", answer: "XYZWA")
        #expect(result == [.present, .absent, .absent, .absent, .absent])
        let wIndices = [0, 2]
        let wStatuses = wIndices.map { result[$0] }
        #expect(wStatuses.filter { $0 == .present }.count == 1)
        #expect(wStatuses.filter { $0 == .absent }.count == 1)
    }

    // The answer itself contains a repeated letter (DOLLY has two Ls)
    // and the guess also has two Ls at different positions -- one
    // landing correct, one landing present. This is the mirror image
    // of the two cases above: when the answer genuinely supports both
    // occurrences, both guessed copies DO get credited.
    @Test func repeatedLetterInTheAnswerCreditsBothGuessedCopiesWhenSupported() {
        let result = WoidleGame.evaluate(guess: "ALLOY", answer: "DOLLY")
        #expect(result == [.absent, .present, .correct, .present, .correct])
        let lIndices = [1, 2]
        let lStatuses = lIndices.map { result[$0] }
        #expect(lStatuses.contains(.correct))
        #expect(lStatuses.contains(.present))
        #expect(!lStatuses.contains(.absent))
    }

    // MARK: - win / loss

    @Test func aWinningGuessEntersTheWonPhase() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        for letter in "CRANE" { game.typeLetter(letter) }
        game.submit(isAllowed: { _ in true })
        #expect(game.phase == .won)
        #expect(game.guesses == ["CRANE"])
    }

    // Eddie's required test: "the sixth failed guess produces the
    // loss/reveal state." Six wrong-but-valid guesses in a row, none
    // of them the answer, must flip to .lost exactly on the sixth --
    // never earlier, and the answer itself must still be readable off
    // the struct for the reveal screen.
    @Test func theSixthFailedGuessProducesTheLossState() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        let wrongGuesses = ["BLIMP", "TOUGH", "SQUID", "JUMPY", "WALTZ"]
        for guess in wrongGuesses {
            for letter in guess { game.typeLetter(letter) }
            game.submit(isAllowed: { _ in true })
            #expect(game.phase == .playing)
        }
        for letter in "GROVE" { game.typeLetter(letter) }
        game.submit(isAllowed: { _ in true })
        #expect(game.phase == .lost)
        #expect(game.guesses.count == 6)
        #expect(game.answer == "CRANE")
    }

    // MARK: - keyStatuses (on-screen keyboard coloring)

    // Eddie: "If a letter receives multiple statuses across guesses,
    // preserve the strongest known information: CORRECT > PRESENT >
    // ABSENT." A letter scored .present by an earlier guess must never
    // be downgraded to .absent by a later guess that happens to place
    // it somewhere it isn't.
    @Test func keyStatusesNeverRegressFromAStrongerToAWeakerStatus() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        // SNIPE marks N as .present (it's in CRANE, wrong spot).
        for letter in "SNIPE" { game.typeLetter(letter) }
        game.submit(isAllowed: { _ in true })
        #expect(game.keyStatuses[Character("N")] == .present)
        // ONION has two Ns; CRANE has only one (at index 3, which
        // ONION's own N's never land on), so this guess's own pass
        // scores one N .present (index 1) and the other N .absent
        // (index 4) -- keyStatuses must still report .present for N
        // overall, not regress to .absent.
        for letter in "ONION" { game.typeLetter(letter) }
        game.submit(isAllowed: { _ in true })
        #expect(game.keyStatuses[Character("N")] == .present)
        // CRANE (the winning guess) upgrades N all the way to .correct.
        for letter in "CRANE" { game.typeLetter(letter) }
        game.submit(isAllowed: { _ in true })
        #expect(game.keyStatuses[Character("N")] == .correct)
    }

    @Test func unguessedLettersHaveNoKeyStatus() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        for letter in "CRANE" { game.typeLetter(letter) }
        game.submit(isAllowed: { _ in true })
        #expect(game.keyStatuses[Character("Z")] == nil)
    }

    // MARK: - reset / retry

    // Eddie's required test: "retry resets the puzzle." reset() alone
    // clears everything back to a blank slate; WoidleOverlay's view
    // model is what calls start(answer:) again with a freshly picked
    // answer, same two-step shape as every other retry in Hallways.
    @Test func resetClearsEverythingBackToABlankSlate() {
        var game = WoidleGame()
        game.start(answer: "CRANE")
        for letter in "CRATE" { game.typeLetter(letter) }
        game.submit(isAllowed: { _ in true })
        game.reset()
        #expect(game.phase == .playing)
        #expect(game.answer.isEmpty)
        #expect(game.guesses.isEmpty)
        #expect(game.evaluations.isEmpty)
        #expect(game.currentInput.isEmpty)
        game.start(answer: "SPOIL")
        #expect(game.answer == "SPOIL")
        #expect(game.guesses.isEmpty)
    }

    // MARK: - word banks

    // Eddie's required test: "the answer is always exactly 5 letters."
    // Applies to every entry in both banks, not just the picker's
    // output -- a malformed bank entry would otherwise only surface
    // the day it happened to get picked.
    @Test func everyAnswerBankWordIsExactlyFiveUppercaseLetters() {
        let letters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for word in WoidleAnswerBank.words {
            #expect(word.count == 5, "\(word) is not 5 letters")
            #expect(word == word.uppercased(), "\(word) is not uppercase")
            #expect(word.unicodeScalars.allSatisfy { letters.contains($0) }, "\(word) has non-letter characters")
        }
    }

    @Test func everyExtraAllowedWordIsExactlyFiveUppercaseLetters() {
        let letters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for word in WoidleWordBank.extraAllowedWords {
            #expect(word.count == 5, "\(word) is not 5 letters")
            #expect(word == word.uppercased(), "\(word) is not uppercase")
            #expect(word.unicodeScalars.allSatisfy { letters.contains($0) }, "\(word) has non-letter characters")
        }
    }

    @Test func noDuplicateWordsWithinEitherBank() {
        #expect(Set(WoidleAnswerBank.words).count == WoidleAnswerBank.words.count)
        #expect(Set(WoidleWordBank.extraAllowedWords).count == WoidleWordBank.extraAllowedWords.count)
    }

    // The answer bank and the supplementary allowed-guess list are
    // meant to be two disjoint pools that together form allWords --
    // an overlap wouldn't break anything functionally, but it would
    // mean the two lists were curated with duplicated effort.
    @Test func theTwoBanksDoNotOverlap() {
        let overlap = Set(WoidleAnswerBank.words).intersection(WoidleWordBank.extraAllowedWords)
        #expect(overlap.isEmpty)
    }

    @Test func allWordsIsTheUnionOfBothBanks() {
        #expect(WoidleWordBank.allWords.count == WoidleAnswerBank.words.count + WoidleWordBank.extraAllowedWords.count)
        for word in WoidleAnswerBank.words {
            #expect(WoidleWordBank.isAllowed(word))
        }
        for word in WoidleWordBank.extraAllowedWords {
            #expect(WoidleWordBank.isAllowed(word))
        }
    }

    @Test func answerBankIsReasonablySized() {
        #expect(WoidleAnswerBank.words.count >= 50)
    }

    // MARK: - WoidleAnswerPicker

    @Test func pickAnswerAlwaysReturnsABankMember() {
        var rng = SeededRNG(seed: 20)
        for _ in 0..<50 {
            let answer = WoidleAnswerPicker.pickAnswer(using: &rng)
            #expect(WoidleAnswerBank.words.contains(answer))
        }
    }

    // Eddie: "avoid repeating the same answer on immediate retry, if
    // practical."
    @Test func pickAnswerExcludingPreviousNeverRepeatsImmediately() {
        var rng = SeededRNG(seed: 21)
        var previous = WoidleAnswerPicker.pickAnswer(using: &rng)
        for _ in 0..<200 {
            let next = WoidleAnswerPicker.pickAnswer(excluding: previous, using: &rng)
            #expect(next != previous)
            #expect(WoidleAnswerBank.words.contains(next))
            previous = next
        }
    }

    // MARK: - word validation fallback (Eddie, Sept 14: adapted from
    // the older Word Puzzie project's WordValidator.swift/
    // WordDictionary.swift -- see WoidleSystemDictionary.swift)

    // Eddie's explicit requirement: "LIKES must be accepted." None of
    // these four are in the curated list (verified below), so this
    // only passes if the WoidleSystemDictionary fallback tier is
    // actually being consulted, not just the curated one.
    @Test func isAllowedAcceptsOrdinaryInflectedWordsViaTheSystemDictionaryFallback() {
        let inflectedForms = ["LIKES", "LIKED", "MAKES", "TAKES"]
        for word in inflectedForms {
            #expect(!WoidleWordBank.allWords.contains(word), "\(word) unexpectedly already in the curated list -- this test would no longer prove the fallback tier works")
            #expect(WoidleWordBank.isAllowed(word), "\(word) should be accepted via the system-dictionary fallback")
        }
    }

    // Eddie's explicit requirement: "Nonsense strings must still be
    // rejected."
    @Test func isAllowedRejectsNonsenseStrings() {
        let nonsenseStrings = ["QXZKV", "ZZZZQ", "VVPXQ"]
        for word in nonsenseStrings {
            #expect(!WoidleWordBank.isAllowed(word), "\(word) should not be accepted as a word")
        }
    }

    // Regression guard: adding the fallback tier must never change
    // the outcome for a word already in the curated list -- tier 1
    // (allWords.contains) short-circuits before tier 2 is ever
    // consulted.
    @Test func isAllowedStillAcceptsCuratedWordsUnaffectedByTheFallback() {
        #expect(WoidleWordBank.isAllowed("CRANE")) // from WoidleAnswerBank
        #expect(WoidleWordBank.isAllowed("DRANK")) // from WoidleWordBank.extraAllowedWords
    }

    // Direct tests of the wrapper itself (not routed through
    // WoidleWordBank.isAllowed), per Eddie: "add tests where feasible
    // for the validation wrapper itself."
    @Test func systemDictionaryDirectlyAcceptsAnOrdinaryInflectedWord() {
        #expect(WoidleSystemDictionary.isValidWord("LIKES"))
    }

    @Test func systemDictionaryDirectlyRejectsANonsenseString() {
        #expect(!WoidleSystemDictionary.isValidWord("QXZKV"))
    }

    // Word Puzzie: "reject words with repeated letters like AAA,
    // EEE... must have at least 2 different letters." Ported guard
    // rail, tested directly against the wrapper.
    @Test func systemDictionaryRejectsSingleRepeatedLetterStrings() {
        #expect(!WoidleSystemDictionary.isValidWord("AAAAA"))
    }

    // Defense-in-depth: Woidle's on-screen keyboard can only ever
    // produce A-Z, but the wrapper itself should still refuse
    // anything containing a non-letter character if ever called with
    // one directly (e.g. from a future input path, or a test).
    @Test func systemDictionaryRejectsInputContainingNonLetterCharacters() {
        #expect(!WoidleSystemDictionary.isValidWord("AB12C"))
    }
}
