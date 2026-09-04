import XCTest

import MurmurShared
@testable import Murmur

/// One behaviour suite, run twice: against the device keychain (the real thing, on the
/// simulator) and against the in-memory double the other tests and previews use. If the two
/// ever diverge, every later task that fakes secrets is testing a fiction.
final class KeychainTests: XCTestCase {
    /// A `test-` prefixed account so a stray item is obvious, and unique per run.
    private let account = "test-\(UUID().uuidString)"

    override func tearDown() {
        // Belt and braces: the suite deletes as its last step, but a failed assertion earlier
        // would skip that and leave an item behind in the simulator keychain.
        try? Keychain().delete(account)
        super.tearDown()
    }

    func testRealKeychainRoundTrip() throws {
        try assertRoundTrip(Keychain(), account: account)
    }

    func testInMemoryStoreRoundTrip() throws {
        try assertRoundTrip(InMemorySecretStore(), account: account)
    }

    /// Two stores over the same service must not see each other's accounts.
    func testAccountsAreIndependent() throws {
        let other = "test-\(UUID().uuidString)"
        let keychain = Keychain()
        defer { try? keychain.delete(other) }

        try keychain.set(account, "one")
        try keychain.set(other, "two")
        XCTAssertEqual(try keychain.get(account), "one")
        XCTAssertEqual(try keychain.get(other), "two")
    }

    /// Xcode expands `$(AppIdentifierPrefix)` from `DEVELOPMENT_TEAM` on the simulator as
    /// well, so the group the MM2 keyboard extension will share is the one under test here.
    func testDefaultAccessGroupResolvesTheTeamPrefix() {
        let group = Keychain.defaultAccessGroup
        XCTAssertNotNil(group, "AppIdentifierPrefix missing from the host app's Info.plist")
        XCTAssertTrue(group?.hasSuffix(".com.murmur.app") ?? false, "unexpected group \(group ?? "nil")")
        // Never the unexpanded build setting — that would be a group nothing can open.
        XCTAssertFalse(group?.contains("$(") ?? true)
    }

    // MARK: - Shared behaviour

    private func assertRoundTrip(
        _ store: SecretStore,
        account: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNil(try store.get(account), "should start empty", file: file, line: line)

        try store.set(account, "sk-first")
        XCTAssertEqual(try store.get(account), "sk-first", file: file, line: line)

        // set() on an existing account overwrites rather than failing with a duplicate.
        try store.set(account, "sk-second")
        XCTAssertEqual(try store.get(account), "sk-second", file: file, line: line)

        try store.delete(account)
        XCTAssertNil(try store.get(account), file: file, line: line)

        // Deleting something that is not there is a no-op, not an error.
        XCTAssertNoThrow(try store.delete(account), file: file, line: line)
    }
}
