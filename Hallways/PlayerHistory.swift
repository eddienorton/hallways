import Foundation

/// Oct 7 -- PLAYER HISTORY (foundation).
///
/// HISTORY RECORDS WHAT HAPPENED. RATING WILL LATER BE DERIVED FROM HISTORY.
///
/// This is a plain, persisted ledger of FACTS: what the player did, when,
/// for how long. It holds no judgement -- no score, no rating, no morality,
/// no "productive"/"unproductive" labels -- and nothing in the game reads it
/// to change behaviour yet. A future Rating (or anything else) is meant to be
/// computed FROM this record, never stored in it.
///
/// Shape:
///   - `HistoryEvent`: one immutable fact. A durable UUID, a kind (an open,
///     string-backed name such as "game.launched" -- new floors, meetings,
///     etc. add kinds without a schema change), a timestamp, and optional
///     subject (the durable ID of what it was about: "mail.it.workstation",
///     "game.ticTacToe"), session link, duration and small detail strings.
///   - `HistoryAggregates`: running totals kept alongside the events, so
///     cheap questions ("how many times was Mail opened", "seconds spent in
///     each game") never need a full replay. Derived from the events; the
///     events stay the source of truth.
///   - `HistorySpan`: a begin/end pair helper. Beginning records the begin
///     event; ending records the end event with the measured duration and
///     the same session ID.
///
/// Persistence: one JSON file in Application Support (PlayerHistory.json),
/// rewritten atomically after each event. Survives relaunch; cleared only by
/// the dev New Player reset.
nonisolated struct HistoryEventKind: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }

    // The office computer (Floor 3).
    static let computerSessionBegan = HistoryEventKind("computer.session.began")
    static let computerSessionEnded = HistoryEventKind("computer.session.ended")
    // Mail.
    static let mailOpened = HistoryEventKind("mail.opened")
    static let mailClosed = HistoryEventKind("mail.closed")
    static let mailMessageRead = HistoryEventKind("mail.message.read")
    // Games.
    static let gamesOpened = HistoryEventKind("games.opened")
    static let gamesClosed = HistoryEventKind("games.closed")
    static let gameLaunched = HistoryEventKind("game.launched")
    static let gameExited = HistoryEventKind("game.exited")
}

nonisolated struct HistoryEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let kind: HistoryEventKind
    let at: Date
    var floor: Int?
    /// Durable ID of the thing this fact is about (a mail ID, a game ID...).
    var subject: String?
    /// Links the two halves of a span (begin/end) together.
    var session: UUID?
    /// Seconds, on span-ending events.
    var duration: TimeInterval?
    var detail: [String: String]?
}

nonisolated struct HistoryAggregates: Codable, Sendable, Equatable {
    var computerSessions = 0
    var computerSeconds: TimeInterval = 0
    var mailOpens = 0
    var mailSeconds: TimeInterval = 0
    /// Mail ID -> times opened.
    var mailReads: [String: Int] = [:]
    var gamesOpens = 0
    var gamesSeconds: TimeInterval = 0
    /// Game ID -> launches.
    var gameLaunches: [String: Int] = [:]
    /// Game ID -> seconds played.
    var gameSeconds: [String: TimeInterval] = [:]
    var firstEventAt: Date?
    var lastEventAt: Date?
}

/// A begin/end pair in progress (see PlayerHistory.begin/end).
nonisolated struct HistorySpan: Sendable {
    let session: UUID
    let started: Date
    let endKind: HistoryEventKind
    let subject: String?
    let floor: Int?
}

final class PlayerHistory {
    static let shared = PlayerHistory(fileURL: PlayerHistory.defaultFileURL)

    private(set) var events: [HistoryEvent] = []
    private(set) var aggregates = HistoryAggregates()

    private nonisolated struct Archive: Codable {
        var schema: Int
        var events: [HistoryEvent]
        var aggregates: HistoryAggregates
    }
    private static let schema = 1

    /// The real ledger's file. Oct 8: the store's location is injectable so
    /// tests can use a throwaway one (or none) and never touch the player's.
    static let defaultFileURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("PlayerHistory.json")

    private let fileURL: URL?

    /// `fileURL` nil = in memory only (tests). The app uses `shared`.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    // MARK: Recording

    @discardableResult
    func record(_ kind: HistoryEventKind, subject: String? = nil, floor: Int? = nil, session: UUID? = nil,
                duration: TimeInterval? = nil, detail: [String: String]? = nil, at date: Date = Date()) -> HistoryEvent {
        let event = HistoryEvent(id: UUID(), kind: kind, at: date, floor: floor, subject: subject, session: session,
                                 duration: duration, detail: detail)
        events.append(event)
        apply(event)
        save()
        diag("history.record", ["kind": kind.rawValue, "subject": subject, "duration": duration, "session": session?.uuidString])
        return event
    }

    /// Records `kind` now and returns the span; `end(_:)` records its end kind.
    func begin(_ kind: HistoryEventKind, endKind: HistoryEventKind, subject: String? = nil, floor: Int? = nil,
               detail: [String: String]? = nil) -> HistorySpan {
        let span = HistorySpan(session: UUID(), started: Date(), endKind: endKind, subject: subject, floor: floor)
        record(kind, subject: subject, floor: floor, session: span.session, detail: detail, at: span.started)
        return span
    }

    @discardableResult
    func end(_ span: HistorySpan, detail: [String: String]? = nil) -> TimeInterval {
        let now = Date()
        let duration = max(0, now.timeIntervalSince(span.started))
        record(span.endKind, subject: span.subject, floor: span.floor, session: span.session, duration: duration,
               detail: detail, at: now)
        return duration
    }

    /// The events of one kind (newest last).
    func events(of kind: HistoryEventKind) -> [HistoryEvent] { events.filter { $0.kind == kind } }

    // MARK: Aggregates

    private func apply(_ e: HistoryEvent) {
        var a = aggregates
        if a.firstEventAt == nil { a.firstEventAt = e.at }
        a.lastEventAt = e.at
        switch e.kind {
        case .computerSessionBegan: a.computerSessions += 1
        case .computerSessionEnded: a.computerSeconds += e.duration ?? 0
        case .mailOpened: a.mailOpens += 1
        case .mailClosed: a.mailSeconds += e.duration ?? 0
        case .mailMessageRead: if let s = e.subject { a.mailReads[s, default: 0] += 1 }
        case .gamesOpened: a.gamesOpens += 1
        case .gamesClosed: a.gamesSeconds += e.duration ?? 0
        case .gameLaunched: if let s = e.subject { a.gameLaunches[s, default: 0] += 1 }
        case .gameExited: if let s = e.subject { a.gameSeconds[s, default: 0] += e.duration ?? 0 }
        default: break                                  // unknown/future kinds: kept as events only
        }
        aggregates = a
    }

    // MARK: Persistence

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let archive = try decoder.decode(Archive.self, from: data)
            events = archive.events
            aggregates = archive.aggregates
            diag("history.loaded", ["events": events.count, "schema": archive.schema])
        } catch {
            diag("history.loadFailed", ["error": String(describing: error)])
        }
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(Archive(schema: Self.schema, events: events, aggregates: aggregates))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            diag("history.saveFailed", ["error": String(describing: error)])
        }
    }

    /// DEV (New Player reset): a new hire has no history.
    func resetForNewPlayer() {
        events = []
        aggregates = HistoryAggregates()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        diag("history.reset", [:])
    }
}
