import XCTest

import MurmurShared

/// The crash journal, in a throwaway directory: what reaches the disk and when, which
/// leftovers count as "finish this", and that the samples survive the round trip.
final class RecordingJournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Reference point for every date in these tests; the injected clock keeps them exact.
    private let now = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func makeJournal(writtenAt: Date? = nil) -> RecordingJournal {
        let stamp = writtenAt ?? now
        return RecordingJournal(directory: directory, clock: { stamp })
    }

    private func bytes(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    }

    private func ramp(_ count: Int) -> [Float] {
        (0..<count).map { Float($0 % 1_000) / 1_000 }
    }

    // MARK: - Writing

    func testNothingReachesTheDiskUnderTwoSecondsOfAudio() {
        let journal = makeJournal()

        journal.append(ramp(RecordingJournal.flushThreshold - 1))

        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path))
    }

    func testTwoSecondsOfAudioIsWritten() {
        let journal = makeJournal()

        // 32,000 samples is the threshold; neither half of this reaches it alone.
        journal.append(ramp(20_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path))

        journal.append(ramp(20_000))

        XCTAssertEqual(bytes(at: journal.url), 40_000 * 4)
    }

    func testFlushWritesTheRemainder() throws {
        let journal = makeJournal()
        journal.append(ramp(40_000))
        XCTAssertEqual(bytes(at: journal.url), 160_000)

        journal.append(ramp(1_000))
        // Under the threshold, so still only the first write.
        XCTAssertEqual(bytes(at: journal.url), 160_000)

        try journal.flush()

        XCTAssertEqual(bytes(at: journal.url), 41_000 * 4)
    }

    func testDiscardRemovesTheFileAndStopsTheJournal() throws {
        let journal = makeJournal()
        journal.append(ramp(40_000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.url.path))

        journal.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path))

        // A chunk still in flight when the dictation was delivered must not resurrect it.
        journal.append(ramp(40_000))
        try journal.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path))
    }

    // MARK: - Pending

    func testAFreshFileIsNotPending() throws {
        let journal = makeJournal()
        journal.append(ramp(40_000))
        try journal.flush()

        // Four seconds after the last write: a recording this recent may still be live.
        XCTAssertNil(RecordingJournal.pending(in: directory, now: now.addingTimeInterval(4)))
        XCTAssertNotNil(RecordingJournal.pending(in: directory, now: now.addingTimeInterval(5)))
    }

    func testTheNewestStaleFileIsPendingWithItsDuration() throws {
        let older = makeJournal(writtenAt: now.addingTimeInterval(-100))
        older.append(ramp(16_000))
        try older.flush()

        let newer = makeJournal(writtenAt: now.addingTimeInterval(-50))
        newer.append(ramp(40_000))
        try newer.flush()

        let pending = RecordingJournal.pending(in: directory, now: now)

        XCTAssertEqual(pending?.url, newer.url)
        XCTAssertEqual(pending?.modifiedAt.timeIntervalSinceReferenceDate ?? 0,
                       now.addingTimeInterval(-50).timeIntervalSinceReferenceDate,
                       accuracy: 1)
        // 40,000 samples at 16 kHz.
        XCTAssertEqual(pending?.duration ?? 0, 2.5, accuracy: 0.001)
    }

    func testATapShorterThanHalfASecondIsIgnored() throws {
        let journal = makeJournal(writtenAt: now.addingTimeInterval(-100))
        // 0.25 s — under the threshold, so only the explicit flush writes it.
        journal.append(ramp(4_000))
        try journal.flush()

        XCTAssertNil(RecordingJournal.pending(in: directory, now: now))
    }

    func testNothingIsPendingInAnEmptyDirectory() {
        XCTAssertNil(RecordingJournal.pending(in: directory, now: now))
    }

    func testDiscardingAPendingRecordingRemovesIt() throws {
        let journal = makeJournal(writtenAt: now.addingTimeInterval(-50))
        journal.append(ramp(40_000))
        try journal.flush()
        let pending = try XCTUnwrap(RecordingJournal.pending(in: directory, now: now))

        RecordingJournal.discard(pending)

        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.url.path))
        XCTAssertNil(RecordingJournal.pending(in: directory, now: now))
    }

    // MARK: - Round trip

    func testTheSamplesSurviveTheRoundTrip() throws {
        let samples = ramp(40_000)
        let journal = makeJournal(writtenAt: now.addingTimeInterval(-50))
        journal.append(samples)
        try journal.flush()

        let pending = try XCTUnwrap(RecordingJournal.pending(in: directory, now: now))
        let loaded = try RecordingJournal.load(pending)

        XCTAssertEqual(loaded.count, samples.count)
        XCTAssertEqual(loaded, samples)
    }

    func testChunksRebuildTheAudioForThePipeline() async throws {
        let samples = ramp(10_000)

        var rebuilt: [Float] = []
        var count = 0
        for await chunk in RecordingJournal.chunks(from: samples) {
            count += 1
            XCTAssertEqual(Int(chunk.buffer.frameLength), chunk.samples16kMono.count)
            XCTAssertEqual(chunk.buffer.format.sampleRate, 16_000)
            rebuilt.append(contentsOf: chunk.samples16kMono)
        }

        // ceil(10,000 / 4,096)
        XCTAssertEqual(count, 3)
        XCTAssertEqual(rebuilt, samples)
    }

    func testChunksOfNothingYieldNothing() async {
        var count = 0
        for await _ in RecordingJournal.chunks(from: []) { count += 1 }
        XCTAssertEqual(count, 0)
    }
}
