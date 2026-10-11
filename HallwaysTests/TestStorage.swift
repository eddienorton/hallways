import Foundation
@testable import Hallways

/// Oct 8 -- throwaway storage for communications tests. Every Mail / HallChat /
/// Player History / story-beat test builds its stores on one of these, so a
/// test run NEVER reads or writes the player's real messages, history or
/// progress (UserDefaults.standard, PlayerHistory.json).
@MainActor
final class ThrowawayStorage {
    let suiteName = "hallways.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    /// In-memory only: no file at all.
    let history = PlayerHistory(fileURL: nil)

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit { defaults.removePersistentDomain(forName: suiteName) }

    func mail() -> MailStore { MailStore(defaults: defaults) }
    func chat() -> ChatStore { ChatStore(defaults: defaults, history: history) }
}

/// The real stores' keys, as raw values -- to prove a test left them alone.
enum RealCommunicationsSnapshot {
    static let keys = ["mail.delivered", "mail.read", "hallchat.delivered", "hallchat.read"]
    static func take() -> [String: String] {
        var out: [String: String] = [:]
        for key in keys { out[key] = String(describing: UserDefaults.standard.object(forKey: key)) }
        return out
    }
}
