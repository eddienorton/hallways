import Foundation
import UIKit

/// Floor 16's fallback word-validation tier (Eddie, Sept 14) --
/// adapted from the exact mechanism his older Word Puzzie project
/// (WordValidator.swift / WordDictionary.swift, in
/// Development/Active/Wordpuzzie) used to accept ordinary English
/// words like LIKES/LIKED/MAKES/TAKES without hand-maintaining every
/// inflected form of every word. Word Puzzie tried its own curated
/// word list FIRST and only fell back to Apple's on-device
/// UITextChecker -- the same system dictionary the iOS keyboard's
/// spell-checker uses -- for words the curated list didn't cover.
/// WoidleWordBank.isAllowed does the same: WoidleWordBank.allWords
/// (the curated ~200-word list) stays the fast first tier, and this
/// type is only consulted when that tier misses, so every word
/// already accepted today keeps being accepted exactly as before.
///
/// Entirely local/offline, same as Word Puzzie's own use of it: no
/// network call, no cloud API, no new dependency (UIKit is already
/// imported elsewhere in Hallways -- MailDelivery.swift,
/// PhotoRollProvider.swift, TapNavigationController.swift,
/// HallwayScene.swift, MovementController.swift).
nonisolated enum WoidleSystemDictionary {
    /// Mirrors WordValidator.isValidWord's guard rails ahead of the
    /// UITextChecker call itself -- Word Puzzie: "reject words with
    /// repeated letters like AAA, EEE... must have at least 2
    /// different letters." Also rejects anything that isn't a plain
    /// A-Z word outright (Woidle's on-screen keyboard can only ever
    /// produce letters, but this keeps the wrapper safe and directly
    /// testable on its own with arbitrary strings).
    static func isValidWord(_ word: String) -> Bool {
        let uppercase = word.uppercased()
        guard uppercase.allSatisfy({ $0.isLetter }) else { return false }

        let uniqueLetters = Set(uppercase)
        guard uniqueLetters.count >= 2 else { return false }

        let lowercase = word.lowercased()
        let checker = UITextChecker()
        let range = NSRange(location: 0, length: lowercase.utf16.count)
        let misspelledRange = checker.rangeOfMisspelledWord(
            in: lowercase,
            range: range,
            startingAt: 0,
            wrap: false,
            language: "en"
        )
        guard misspelledRange.location == NSNotFound else { return false }

        // Word Puzzie: the system dictionary doesn't distinguish "a
        // real word" from "a real word, but only as a proper noun" --
        // reject names/places that only pass spell-check capitalized.
        return !isProperNoun(word)
    }

    /// Ported near-verbatim from WordValidator.isProperNoun: tags the
    /// word inside a throwaway sentence, and if it's tagged as a noun
    /// AND only the capitalized form (not the lowercase form) passes
    /// spell-check, treats it as a proper noun.
    private static func isProperNoun(_ word: String) -> Bool {
        let tagger = NSLinguisticTagger(tagSchemes: [.lexicalClass], options: 0)
        let sentence = "The \(word) is here."
        tagger.string = sentence

        let wordRange = (sentence as NSString).range(of: word)
        guard wordRange.location != NSNotFound else { return false }

        let tag = tagger.tag(at: wordRange.location, scheme: .lexicalClass, tokenRange: nil, sentenceRange: nil)
        guard tag == .noun else { return false }

        let checker = UITextChecker()
        let lowercase = word.lowercased()
        let capitalized = word.capitalized

        let lowercaseValid = checker.rangeOfMisspelledWord(
            in: lowercase,
            range: NSRange(location: 0, length: lowercase.utf16.count),
            startingAt: 0, wrap: false, language: "en"
        ).location == NSNotFound

        let capitalizedValid = checker.rangeOfMisspelledWord(
            in: capitalized,
            range: NSRange(location: 0, length: capitalized.utf16.count),
            startingAt: 0, wrap: false, language: "en"
        ).location == NSNotFound

        return capitalizedValid && !lowercaseValid
    }
}
