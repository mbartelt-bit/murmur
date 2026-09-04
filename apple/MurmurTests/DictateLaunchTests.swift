import XCTest

import MurmurIntents
import MurmurShared
@testable import Murmur

/// The Action Button / Shortcut / Control Center path (design spec §6.3), which is a single
/// string in the App Group standing in for a launch reason: ``DictateIntent`` writes it from
/// its own short-lived process, and ``AppState/consumeLaunchFlag(defaults:)`` turns it into a
/// recorder the next time Murmur's scene goes active.
///
/// These tests own both ends of that contract — the key, the value the app reacts to, the
/// session the keyboard will later look for, and the fact that the flag is consumed exactly
/// once so a second activation does not reopen the recorder.
final class DictateLaunchTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var state: AppState!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let settings = SettingsStore(defaults: defaults)
        let secrets = InMemorySecretStore()
        let history = try HistoryStore.inMemory()
        state = AppState(
            settings: settings,
            secrets: secrets,
            history: history,
            pipeline: DictationPipeline(settings: settings, secrets: secrets, history: history)
        )
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        state = nil
        // `perform()` writes to the real shared defaults — it has no injection point — so the
        // intent test's flag is cleaned up here rather than left for the next run to find.
        AppGroup.defaults.removeObject(forKey: DictateIntent.launchFlagKey)
        try super.tearDownWithError()
    }

    // MARK: - AppState

    func testASetFlagOpensAnActionButtonDictationOnTheIntentSession() {
        defaults.set("action-button", forKey: DictateIntent.launchFlagKey)

        state.consumeLaunchFlag(defaults: defaults)

        XCTAssertEqual(state.activeDictation?.source, .actionButton)
        XCTAssertEqual(
            state.activeDictation?.session,
            Handoff.intentSession,
            "the keyboard picks an intent dictation up on this fixed session"
        )
        XCTAssertNil(
            defaults.object(forKey: DictateIntent.launchFlagKey),
            "the flag is consumed, or every later activation would reopen the recorder"
        )
    }

    func testNoFlagOpensNothing() {
        state.consumeLaunchFlag(defaults: defaults)
        XCTAssertNil(state.activeDictation)
    }

    func testTheFlagIsConsumedExactlyOnce() {
        defaults.set("action-button", forKey: DictateIntent.launchFlagKey)
        state.consumeLaunchFlag(defaults: defaults)
        state.activeDictation = nil

        state.consumeLaunchFlag(defaults: defaults)

        XCTAssertNil(state.activeDictation)
    }

    /// A `murmur://` open and a flagged launch can arrive together on a cold start; the flag is
    /// read first so it is never left behind, and the URL then has the last word on screen.
    func testHandlingAUrlAlsoConsumesTheFlag() {
        // `handle` uses the real shared defaults, the way the app does.
        AppGroup.defaults.set("action-button", forKey: DictateIntent.launchFlagKey)

        state.handle(URL(string: "murmur://dictate")!)

        XCTAssertNil(AppGroup.defaults.object(forKey: DictateIntent.launchFlagKey))
        XCTAssertEqual(state.activeDictation?.source, .inApp)
    }

    // MARK: - The intent

    func testPerformingTheIntentWritesTheLaunchFlag() async throws {
        AppGroup.defaults.removeObject(forKey: DictateIntent.launchFlagKey)

        _ = try await DictateIntent().perform()

        XCTAssertEqual(
            AppGroup.defaults.string(forKey: DictateIntent.launchFlagKey),
            "action-button"
        )
    }

    func testTheIntentOpensTheApp() {
        // Nothing else can: an intent process may not record (spec §2 constraint 1).
        XCTAssertTrue(DictateIntent.openAppWhenRun)
        XCTAssertEqual(DictateIntent.launchFlagKey, "launch.dictate")
    }
}
