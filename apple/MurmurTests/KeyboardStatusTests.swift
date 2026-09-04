import XCTest

import MurmurShared

/// The three questions the app cannot ask iOS directly. Each answer is a guess from a
/// side-channel, so each one is pinned here: a wrong "Full Access is on" would send a user to
/// a mic key that silently does nothing.
final class KeyboardStatusTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    /// Exactly representable as a Double, so nothing is lost through `UserDefaults`.
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

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

    // MARK: - Enabled

    func testEnabledWhenTheKeyboardListContainsMurmur() {
        defaults.set(
            ["com.apple.keyboard.QWERTY", KeyboardStatus.extensionBundleId, "com.apple.keyboard.Emoji"],
            forKey: "AppleKeyboards"
        )

        XCTAssertTrue(KeyboardStatus.isEnabled(defaults: defaults))
    }

    func testNotEnabledWhenTheListHasOtherKeyboardsOnly() {
        defaults.set(["com.apple.keyboard.QWERTY", "com.someoneelse.keyboard"], forKey: "AppleKeyboards")

        XCTAssertFalse(KeyboardStatus.isEnabled(defaults: defaults))
    }

    func testNotEnabledWhenTheListIsMissing() {
        XCTAssertFalse(KeyboardStatus.isEnabled(defaults: defaults))
    }

    // MARK: - Full Access

    func testFullAccessIsOnFromAFreshHeartbeat() {
        defaults.set(true, forKey: KeyboardStatus.fullAccessKey)
        defaults.set(now.addingTimeInterval(-60), forKey: KeyboardStatus.lastSeenKey)

        XCTAssertEqual(KeyboardStatus.hasFullAccess(appGroup: defaults, now: now), true)
    }

    func testFullAccessIsOffFromAFreshHeartbeat() {
        defaults.set(false, forKey: KeyboardStatus.fullAccessKey)
        defaults.set(now.addingTimeInterval(-60), forKey: KeyboardStatus.lastSeenKey)

        XCTAssertEqual(KeyboardStatus.hasFullAccess(appGroup: defaults, now: now), false)
    }

    func testFullAccessIsUnknownWhenTheHeartbeatIsStale() {
        defaults.set(true, forKey: KeyboardStatus.fullAccessKey)
        // A week and a minute ago: the keyboard may have been removed or its Full Access
        // revoked since, and a stale yes is worse than an honest "don't know".
        defaults.set(
            now.addingTimeInterval(-(KeyboardStatus.heartbeatValidity + 60)),
            forKey: KeyboardStatus.lastSeenKey
        )

        XCTAssertNil(KeyboardStatus.hasFullAccess(appGroup: defaults, now: now))
    }

    func testFullAccessIsUnknownBeforeTheKeyboardHasEverAppeared() {
        XCTAssertNil(KeyboardStatus.hasFullAccess(appGroup: defaults, now: now))
    }

    // MARK: - Action Button

    func testActionButtonByModelIdentifier() {
        // iPhone 14 Pro: the last generation without one.
        XCTAssertFalse(KeyboardStatus.hasActionButton(modelIdentifier: "iPhone15,2"))
        // iPhone 15 Pro / Pro Max: the first two that shipped one.
        XCTAssertTrue(KeyboardStatus.hasActionButton(modelIdentifier: "iPhone16,1"))
        XCTAssertTrue(KeyboardStatus.hasActionButton(modelIdentifier: "iPhone16,2"))
        // The non-Pro iPhone 15s are iPhone15,4 / 15,5 — same generation, no button.
        XCTAssertFalse(KeyboardStatus.hasActionButton(modelIdentifier: "iPhone15,4"))
        // iPhone 16 family and later: the whole line has it.
        XCTAssertTrue(KeyboardStatus.hasActionButton(modelIdentifier: "iPhone17,3"))
        XCTAssertTrue(KeyboardStatus.hasActionButton(modelIdentifier: "iPhone18,1"))
        // Not an iPhone at all.
        XCTAssertFalse(KeyboardStatus.hasActionButton(modelIdentifier: "iPad16,3"))
        XCTAssertFalse(KeyboardStatus.hasActionButton(modelIdentifier: ""))
    }

    func testModelIdentifierIsReadable() {
        // Whatever this is running on, the identifier is a real one — the simulator answers
        // from its environment rather than with the Mac's `utsname`.
        XCTAssertTrue(KeyboardStatus.modelIdentifier.hasPrefix("iPhone") || KeyboardStatus.modelIdentifier.hasPrefix("iPad"))
        XCTAssertEqual(
            KeyboardStatus.hasActionButton,
            KeyboardStatus.hasActionButton(modelIdentifier: KeyboardStatus.modelIdentifier)
        )
    }
}
