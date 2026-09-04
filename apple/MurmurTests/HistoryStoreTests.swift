import XCTest

import MurmurShared
@testable import Murmur

/// History is the only durable copy of a dictation, so the cases here are the ones that would
/// lose or hide a transcript: ordering, search, deletion, and surviving a relaunch.
final class HistoryStoreTests: XCTestCase {
    private var store: HistoryStore!
    /// Only created by the file-backed test; removed here either way.
    private var tempDir: URL?

    /// Whole seconds, so the round trip through SQLite's millisecond date format is exact.
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try HistoryStore.inMemory()
    }

    override func tearDownWithError() throws {
        store = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
            self.tempDir = nil
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func transcript(_ n: Int, source: TranscriptSource = .inApp) -> Transcript {
        Transcript(
            rawText: "um raw \(n)",
            cleanText: "Clean \(n).",
            source: source,
            createdAt: t0.addingTimeInterval(TimeInterval(n))
        )
    }

    /// Inserts `1...n` oldest first and returns them with their ids.
    @discardableResult
    private func seed(_ n: Int) throws -> [Transcript] {
        try (1...n).map { try store.insert(transcript($0)) }
    }

    // MARK: - Insert and list

    func testInsertAssignsAnIdAndReturnsTheRow() throws {
        let saved = try store.insert(transcript(1))
        XCTAssertNotNil(saved.id)
        XCTAssertEqual(saved.rawText, "um raw 1")
        XCTAssertEqual(saved.cleanText, "Clean 1.")
        XCTAssertEqual(saved.source, .inApp)
        XCTAssertEqual(saved.createdAt, t0.addingTimeInterval(1))
    }

    func testListReturnsNewestFirst() throws {
        let seeded = try seed(3)
        XCTAssertEqual(try store.list(), seeded.reversed())
        XCTAssertEqual(try store.list().map(\.cleanText), ["Clean 3.", "Clean 2.", "Clean 1."])
    }

    func testListIsEmptyOnAFreshStore() throws {
        XCTAssertEqual(try store.list(), [])
    }

    func testListHonoursTheLimit() throws {
        try seed(5)
        XCTAssertEqual(try store.list(limit: 2).map(\.cleanText), ["Clean 5.", "Clean 4."])
    }

    func testSourceRoundTripsThroughItsHyphenatedRawValue() throws {
        try store.insert(transcript(1, source: .actionButton))
        try store.insert(transcript(2, source: .keyboard))
        XCTAssertEqual(try store.list().map(\.source), [.keyboard, .actionButton])
    }

    // MARK: - Search

    func testSearchMatchesTheCleanedText() throws {
        try seed(3)
        XCTAssertEqual(try store.list(matching: "Clean 2").map(\.cleanText), ["Clean 2."])
    }

    func testSearchMatchesTheRawTextToo() throws {
        // "um" only ever appears in the raw column.
        try seed(2)
        XCTAssertEqual(try store.list(matching: "um raw 1").map(\.cleanText), ["Clean 1."])
    }

    func testSearchIsCaseInsensitive() throws {
        try store.insert(Transcript(rawText: "raw", cleanText: "Hello There.", source: .inApp, createdAt: t0))
        XCTAssertEqual(try store.list(matching: "hello there").count, 1)
        XCTAssertEqual(try store.list(matching: "HELLO THERE").count, 1)
    }

    func testSearchWithNoMatchReturnsNothing() throws {
        try seed(3)
        XCTAssertEqual(try store.list(matching: "nothing like this"), [])
    }

    func testEmptySearchIsTheSameAsNoSearch() throws {
        try seed(3)
        XCTAssertEqual(try store.list(matching: ""), try store.list())
    }

    // MARK: - Delete

    func testDeleteRemovesJustThatRow() throws {
        let seeded = try seed(3)
        try store.delete(id: XCTUnwrap(seeded[1].id))
        XCTAssertEqual(try store.list().map(\.cleanText), ["Clean 3.", "Clean 1."])
    }

    func testDeletingAMissingIdIsANoOp() throws {
        try seed(1)
        XCTAssertNoThrow(try store.delete(id: 9_999))
        XCTAssertEqual(try store.list().count, 1)
    }

    // MARK: - Recent

    func testRecentReturnsTheThreeNewest() throws {
        try seed(5)
        XCTAssertEqual(try store.recent(3).map(\.cleanText), ["Clean 5.", "Clean 4.", "Clean 3."])
    }

    func testRecentReturnsWhatThereIsWhenAskedForMore() throws {
        try seed(2)
        XCTAssertEqual(try store.recent(3).count, 2)
    }

    // MARK: - Durability

    /// The app opens `HistoryStore.defaultURL` fresh on every launch; rows must outlive the
    /// process, and the migrator must be happy to run against an already-migrated file.
    func testFileBackedStoreSurvivesReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        let url = dir.appendingPathComponent("murmur.sqlite")

        let written = try HistoryStore(url: url).insert(transcript(1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        XCTAssertEqual(try HistoryStore(url: url).list(), [written])
    }

    func testDefaultURLSitsInTheAppGroupContainer() {
        XCTAssertEqual(HistoryStore.defaultURL.lastPathComponent, "murmur.sqlite")
        XCTAssertEqual(
            HistoryStore.defaultURL.deletingLastPathComponent().path,
            AppGroup.containerURL.path
        )
    }
}
