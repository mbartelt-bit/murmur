import Foundation
import GRDB

/// One saved dictation. `rawText` is what the speech engine heard, `cleanText` what the
/// cleanup pass produced and what actually gets inserted or copied — both are kept so a user
/// can see what was changed on their behalf.
public struct Transcript: Codable, Equatable, Identifiable {
    /// `nil` until the row is written; ``HistoryStore/insert(_:)`` returns a copy with it set.
    public var id: Int64?
    public var rawText: String
    public var cleanText: String
    public var source: TranscriptSource
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        rawText: String,
        cleanText: String,
        source: TranscriptSource,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.rawText = rawText
        self.cleanText = cleanText
        self.source = source
        self.createdAt = createdAt
    }
}

/// Where a dictation came from. The raw values are the strings stored in `transcripts.source`,
/// hyphenated to match the desktop's vocabulary rather than Swift's camel case.
public enum TranscriptSource: String, Codable {
    case inApp = "in-app"
    case keyboard
    case actionButton = "action-button"
}

// MARK: - GRDB mapping

extension Transcript: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transcripts"

    /// Column names, not property names: the schema is the desktop's (`src-tauri/src/lib.rs`)
    /// so a future sync between the Mac and the phone is a copy, not a translation.
    public enum CodingKeys: String, CodingKey {
        case id
        case rawText = "raw_text"
        case cleanText = "clean_text"
        case source
        case createdAt = "created_at"
    }

    /// SQLite hands back the rowid it assigned; without this the caller's copy stays `nil`.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Store

/// The dictation history: a single SQLite file in the App Group container, so the MM2
/// keyboard extension reads the same rows the app writes.
///
/// Every dictation is written here *before* it is copied or handed off (design spec §8), which
/// makes this the one place a transcript can never be lost.
public final class HistoryStore {
    /// The app's database. In the App Group container so extensions can open it too.
    public static var defaultURL: URL {
        AppGroup.containerURL.appendingPathComponent("murmur.sqlite")
    }

    private let dbQueue: DatabaseQueue

    private init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    /// Opens (creating if needed) the database at `url` and brings it up to the latest schema.
    public convenience init(url: URL) throws {
        try self.init(DatabaseQueue(path: url.path))
    }

    /// A throwaway database for tests and previews. Nothing is written to disk.
    public static func inMemory() throws -> HistoryStore {
        try HistoryStore(DatabaseQueue())
    }

    // MARK: Schema

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        // Column-for-column the desktop's `transcripts` table, minus `app_name` (no such
        // concept on iOS) plus `source`, which records which entry point produced the row.
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE transcripts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    raw_text TEXT NOT NULL,
                    clean_text TEXT NOT NULL,
                    source TEXT NOT NULL,
                    created_at DATETIME NOT NULL
                )
                """)
        }
        return migrator
    }()

    // MARK: Reads and writes

    /// Writes `t` and returns it with the assigned ``Transcript/id``.
    @discardableResult
    public func insert(_ t: Transcript) throws -> Transcript {
        try dbQueue.write { db in
            var record = t
            try record.insert(db)
            return record
        }
    }

    /// Newest first. `query`, when given, keeps rows whose cleaned *or* raw text contains it;
    /// SQLite's `LIKE` is case-insensitive for ASCII, which is the match the search field wants.
    public func list(limit: Int = 50, matching query: String? = nil) throws -> [Transcript] {
        try dbQueue.read { db in
            guard let query, !query.isEmpty else {
                return try Transcript.fetchAll(db, sql: """
                    SELECT * FROM transcripts ORDER BY id DESC LIMIT ?
                    """, arguments: [limit])
            }
            // `%` and `_` typed into the search field are literal characters, not wildcards.
            let pattern = "%" + Self.escapedForLike(query) + "%"
            return try Transcript.fetchAll(db, sql: """
                SELECT * FROM transcripts
                WHERE clean_text LIKE ? ESCAPE '\\' OR raw_text LIKE ? ESCAPE '\\'
                ORDER BY id DESC LIMIT ?
                """, arguments: [pattern, pattern, limit])
        }
    }

    public func delete(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transcripts WHERE id = ?", arguments: [id])
        }
    }

    /// The `n` newest transcripts — what the home screen shows.
    public func recent(_ n: Int) throws -> [Transcript] {
        try list(limit: n)
    }

    private static func escapedForLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
