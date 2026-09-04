import Foundation

/// What the keyboard writes before it opens `murmur://dictate?session=…`. The session id is
/// what stops a stale result from an earlier round trip being typed into the wrong field.
public struct PendingDictation: Codable, Equatable {
    public var session: UUID
    public var requestedAt: Date

    public init(session: UUID, requestedAt: Date) {
        self.session = session
        self.requestedAt = requestedAt
    }
}

/// What the recorder writes back once a dictation is finished and already in history.
public struct DictationResult: Codable, Equatable {
    public var session: UUID
    public var raw: String
    public var clean: String
    public var createdAt: Date
    /// Flipped by ``Handoff/takeResult(for:now:defaults:)`` so text is inserted exactly once.
    public var inserted: Bool

    public init(session: UUID, raw: String, clean: String, createdAt: Date, inserted: Bool) {
        self.session = session
        self.raw = raw
        self.clean = clean
        self.createdAt = createdAt
        self.inserted = inserted
    }
}

/// The App Group handoff codec: two JSON blobs in the shared defaults, one in each direction.
///
/// Dictated text is the only user content that lives outside the app, so it is short-lived —
/// ``expiry`` seconds, or until it has been inserted (design spec §10).
public enum Handoff {
    /// Ten minutes, matching the spec's "until inserted or for 10 minutes".
    public static let expiry: TimeInterval = 600

    private static let pendingKey = "handoff.pending"
    private static let resultKey = "handoff.result"

    // MARK: - Pending (keyboard → app)

    public static func writePending(_ p: PendingDictation, defaults: UserDefaults = AppGroup.defaults) {
        write(p, key: pendingKey, defaults: defaults)
    }

    /// The outstanding request, or `nil` when there is none or it has gone stale.
    public static func readPending(now: Date = .init(), defaults: UserDefaults = AppGroup.defaults) -> PendingDictation? {
        guard let p: PendingDictation = read(key: pendingKey, defaults: defaults) else { return nil }
        guard now.timeIntervalSince(p.requestedAt) <= expiry else { return nil }
        return p
    }

    public static func clearPending(defaults: UserDefaults = AppGroup.defaults) {
        defaults.removeObject(forKey: pendingKey)
    }

    // MARK: - Result (app → keyboard)

    public static func writeResult(_ r: DictationResult, defaults: UserDefaults = AppGroup.defaults) {
        write(r, key: resultKey, defaults: defaults)
    }

    /// Claim the result for `session`, exactly once.
    ///
    /// Returns it only when the session matches, it has not been inserted yet, and it is
    /// younger than ``expiry``; the stored copy is then marked inserted and the pending
    /// request cleared, so a second call — or a different session — gets `nil`.
    ///
    /// The returned value is the result *as it was stored*, i.e. with `inserted == false`:
    /// it is the caller who is about to do the inserting.
    public static func takeResult(for session: UUID, now: Date = .init(), defaults: UserDefaults = AppGroup.defaults) -> DictationResult? {
        guard let r: DictationResult = read(key: resultKey, defaults: defaults) else { return nil }
        guard r.session == session, !r.inserted, now.timeIntervalSince(r.createdAt) <= expiry else { return nil }

        var claimed = r
        claimed.inserted = true
        write(claimed, key: resultKey, defaults: defaults)
        clearPending(defaults: defaults)
        return r
    }

    public static func clearResult(defaults: UserDefaults = AppGroup.defaults) {
        defaults.removeObject(forKey: resultKey)
    }

    // MARK: - JSON

    private static func write<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func read<T: Decodable>(key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
