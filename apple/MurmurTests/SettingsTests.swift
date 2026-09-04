import XCTest

import MurmurShared
@testable import Murmur

/// Every case gets its own `UserDefaults` suite so nothing leaks between tests or into the
/// real App Group defaults the app uses.
final class SettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

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

    func testDefaultsAreLocalAndRuleBased() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings.stt, .local)
        XCTAssertEqual(store.settings.cleanup, .rule)
        XCTAssertTrue(store.settings.autoStopOnSilence)
        XCTAssertTrue(store.settings.copyToClipboard)
        XCTAssertFalse(store.settings.onboardingComplete)
    }

    func testUpdatePersistsAcrossStores() {
        let store = SettingsStore(defaults: defaults)
        store.update {
            $0.stt = .groq
            $0.cleanup = .openai
            $0.autoStopOnSilence = false
            $0.onboardingComplete = true
        }
        XCTAssertEqual(store.settings.stt, .groq)

        let reopened = SettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.settings.stt, .groq)
        XCTAssertEqual(reopened.settings.cleanup, .openai)
        XCTAssertFalse(reopened.settings.autoStopOnSilence)
        XCTAssertTrue(reopened.settings.copyToClipboard)
        XCTAssertTrue(reopened.settings.onboardingComplete)
    }

    func testPartialStoredBlobKeepsDefaultsForMissingKeys() throws {
        // A blob written by an older build: only `stt` is present.
        defaults.set(Data(#"{"stt":"openai"}"#.utf8), forKey: "settings.v1")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings.stt, .openai)
        XCTAssertEqual(store.settings.cleanup, .rule)
        XCTAssertTrue(store.settings.copyToClipboard)
    }

    func testCorruptBlobFallsBackToDefaults() {
        defaults.set(Data("not json".utf8), forKey: "settings.v1")
        XCTAssertEqual(SettingsStore(defaults: defaults).settings, Settings())
    }

    // MARK: - Provider copy (verbatim from the desktop's EngineSettings.tsx PROVIDER_INFO)

    func testProviderKeychainAccountsMatchTheDesktop() {
        XCTAssertEqual(ProviderId.groq.keychainAccount, "groq_api_key")
        XCTAssertEqual(ProviderId.openai.keychainAccount, "openai_api_key")
    }

    func testProviderMapsToTheCoreEnum() {
        XCTAssertEqual(ProviderId.groq.core, .groq)
        XCTAssertEqual(ProviderId.openai.core, .openAi)
    }

    func testProviderCopy() {
        XCTAssertEqual(ProviderId.groq.displayName, "Groq")
        XCTAssertEqual(ProviderId.groq.costLabel, "Free tier · no card")
        XCTAssertEqual(ProviderId.groq.signupSteps, [
            "Sign in with Google or GitHub",
            "Click \"Create API Key\"",
            "Copy it and paste below",
        ])
        XCTAssertEqual(ProviderId.openai.displayName, "OpenAI")
        XCTAssertEqual(ProviderId.openai.costLabel, "Pay-as-you-go · card required")
        XCTAssertEqual(ProviderId.openai.signupSteps, [
            "Add ~$5 credit + a card",
            "Click \"Create new secret key\"",
            "Copy it and paste below",
        ])
    }

    // MARK: - App Group

    /// Proves the `com.apple.security.application-groups` entitlement is really on the host
    /// app: without it `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil and
    /// `AppGroup.containerURL` would fall back to the temporary directory.
    func testAppGroupContainerIsEntitled() {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
        XCTAssertNotNil(container, "host app is missing the \(AppGroup.id) entitlement")
        XCTAssertEqual(AppGroup.containerURL, container)
        XCTAssertNotEqual(AppGroup.containerURL, FileManager.default.temporaryDirectory)
    }

    func testAppGroupDefaultsRoundTrip() {
        let key = "test.\(UUID().uuidString)"
        AppGroup.defaults.set("hello", forKey: key)
        defer { AppGroup.defaults.removeObject(forKey: key) }
        XCTAssertEqual(AppGroup.defaults.string(forKey: key), "hello")
    }
}
