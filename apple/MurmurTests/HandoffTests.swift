import XCTest

import MurmurShared
@testable import Murmur

/// The handoff is the one place a stale or duplicated result would type text into the wrong
/// app, so session matching, insert-once, and expiry all get their own case.
final class HandoffTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    /// Exactly representable as a Double, so the JSON round trip is bit-for-bit.
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func result(_ session: UUID, at date: Date? = nil) -> DictationResult {
        DictationResult(
            session: session,
            raw: "um hello world",
            clean: "Hello world.",
            createdAt: date ?? t0,
            inserted: false
        )
    }

    // MARK: - Pending

    func testPendingRoundTrip() {
        let p = PendingDictation(session: UUID(), requestedAt: t0)
        Handoff.writePending(p, defaults: defaults)
        XCTAssertEqual(Handoff.readPending(now: t0.addingTimeInterval(5), defaults: defaults), p)
    }

    func testPendingIsNilWhenExpired() {
        Handoff.writePending(PendingDictation(session: UUID(), requestedAt: t0), defaults: defaults)
        let justInside = t0.addingTimeInterval(Handoff.expiry)
        XCTAssertNotNil(Handoff.readPending(now: justInside, defaults: defaults))
        XCTAssertNil(Handoff.readPending(now: justInside.addingTimeInterval(1), defaults: defaults))
    }

    func testClearPending() {
        Handoff.writePending(PendingDictation(session: UUID(), requestedAt: t0), defaults: defaults)
        Handoff.clearPending(defaults: defaults)
        XCTAssertNil(Handoff.readPending(now: t0, defaults: defaults))
    }

    func testReadPendingIsNilWhenNothingWasWritten() {
        XCTAssertNil(Handoff.readPending(now: t0, defaults: defaults))
    }

    // MARK: - Result

    func testWriteThenTakeRoundTrip() {
        let session = UUID()
        Handoff.writePending(PendingDictation(session: session, requestedAt: t0), defaults: defaults)
        Handoff.writeResult(result(session), defaults: defaults)

        let taken = Handoff.takeResult(for: session, now: t0.addingTimeInterval(3), defaults: defaults)
        XCTAssertEqual(taken, result(session))
        // Claiming a result also retires the request that produced it.
        XCTAssertNil(Handoff.readPending(now: t0.addingTimeInterval(3), defaults: defaults))
    }

    func testTakeTwiceReturnsNilTheSecondTime() {
        let session = UUID()
        Handoff.writeResult(result(session), defaults: defaults)
        XCTAssertNotNil(Handoff.takeResult(for: session, now: t0, defaults: defaults))
        XCTAssertNil(Handoff.takeResult(for: session, now: t0, defaults: defaults))
    }

    func testWrongSessionReturnsNilAndLeavesTheResultClaimable() {
        let session = UUID()
        Handoff.writePending(PendingDictation(session: session, requestedAt: t0), defaults: defaults)
        Handoff.writeResult(result(session), defaults: defaults)

        XCTAssertNil(Handoff.takeResult(for: UUID(), now: t0, defaults: defaults))
        // Untouched: neither marked inserted nor was the pending request cleared.
        XCTAssertNotNil(Handoff.readPending(now: t0, defaults: defaults))
        XCTAssertEqual(Handoff.takeResult(for: session, now: t0, defaults: defaults), result(session))
    }

    func testExpiredResultIsNotTaken() {
        let session = UUID()
        Handoff.writeResult(result(session), defaults: defaults)
        let justInside = t0.addingTimeInterval(Handoff.expiry)
        XCTAssertNil(Handoff.takeResult(for: session, now: justInside.addingTimeInterval(1), defaults: defaults))
        // Still claimable inside the window — the expiry check did not consume it.
        XCTAssertNotNil(Handoff.takeResult(for: session, now: justInside, defaults: defaults))
    }

    func testClearResult() {
        let session = UUID()
        Handoff.writeResult(result(session), defaults: defaults)
        Handoff.clearResult(defaults: defaults)
        XCTAssertNil(Handoff.takeResult(for: session, now: t0, defaults: defaults))
    }

    func testTakeResultIsNilWhenNothingWasWritten() {
        XCTAssertNil(Handoff.takeResult(for: UUID(), now: t0, defaults: defaults))
    }
}
