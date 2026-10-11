import Foundation
import Combine

/// Oct 8 -- STORY BEATS (Phone & Communications, Phase 1 D).
///
/// A tiny, durable record of named story facts and WHEN they happened:
/// "invite.staffMeeting.sent", later "meeting.staff1.attended" / ".missed".
/// Story logic reads beats to decide what the building does next; it never
/// infers outcomes from what happens to be on screen.
///
/// - Each beat is recorded ONCE (the first time wins; its timestamp is kept).
/// - Persisted in UserDefaults ("story.beats", [id: Date] as JSON), so it
///   survives relaunch. Cleared only by Start Over (a new employee).
/// - Holds facts, not judgement, and no schedule: nothing here runs on a
///   timer. Times are whatever the caller passes (tests inject them).
///
/// Player History remains the full ledger of what the player DID; beats are
/// the small set of story milestones the building ACTS on.
final class StoryBeats: ObservableObject {
    static let shared = StoryBeats()

    static let storageKey = "story.beats"

    @Published private(set) var beats: [String: Date] = [:]

    private let defaults: UserDefaults

    /// The app uses `shared` (standard defaults); tests pass a throwaway suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            beats = map
        }
    }

    func has(_ id: String) -> Bool { beats[id] != nil }

    /// When `id` happened, if it has.
    func time(_ id: String) -> Date? { beats[id] }

    /// Record `id` at `date`. True only the first time; a beat is never
    /// overwritten or moved.
    @discardableResult
    func record(_ id: String, at date: Date) -> Bool {
        guard beats[id] == nil else { return false }
        beats[id] = date
        save()
        diag("story.beat", ["id": id])
        return true
    }

    /// Start Over: a new employee has no story yet.
    func resetForNewPlayer() {
        beats = [:]
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(beats) { defaults.set(data, forKey: Self.storageKey) }
    }
}
