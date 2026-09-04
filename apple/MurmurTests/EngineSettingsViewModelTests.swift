import XCTest

import MurmurCore
import MurmurShared
@testable import Murmur

/// Engine choice and key state, with an in-memory secret store and a scripted verifier: no
/// Keychain, no network, and no key that outlives the test.
@MainActor
final class EngineSettingsViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var secrets: InMemorySecretStore!

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = SettingsStore(defaults: defaults)
        secrets = InMemorySecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        settings = nil
        secrets = nil
        super.tearDown()
    }

    /// Records what the core would have been handed, and answers however the test wants.
    private final class FakeVerifier {
        var error: Error?
        private(set) var configs: [CloudConfig] = []

        func verify(_ cfg: CloudConfig) async throws {
            configs.append(cfg)
            if let error { throw error }
        }
    }

    private func makeViewModel(_ verifier: FakeVerifier) -> EngineSettingsViewModel {
        EngineSettingsViewModel(
            settings: settings,
            secrets: secrets,
            verify: verifier.verify,
            openURL: { _ in }
        )
    }

    // MARK: - Keys

    func testSaveKeyTrimsStoresAndVerifies() async throws {
        let verifier = FakeVerifier()
        let viewModel = makeViewModel(verifier)

        await viewModel.saveKey("  gsk_live_key  ", for: .groq)

        XCTAssertEqual(try secrets.get("groq_api_key"), "gsk_live_key")
        XCTAssertEqual(viewModel.keyPresent[.groq], true)
        XCTAssertEqual(viewModel.verifyState[.groq], .connected)
        XCTAssertEqual(verifier.configs.count, 1)
        XCTAssertEqual(verifier.configs.first?.apiKey, "gsk_live_key")
        XCTAssertEqual(verifier.configs.first?.provider, .groq)
    }

    func testRejectedKeyShowsTheCoreMessageAndKeepsTheKey() async throws {
        let verifier = FakeVerifier()
        verifier.error = CoreError.Rejected(message: "Invalid API key")
        let viewModel = makeViewModel(verifier)

        await viewModel.saveKey("sk-bad", for: .openai)

        XCTAssertEqual(viewModel.verifyState[.openai], .failed("Invalid API key"))
        // The paste is still there: the user may have used the wrong provider's key, and
        // throwing it away would lose the paste as well as the answer.
        XCTAssertEqual(try secrets.get("openai_api_key"), "sk-bad")
        XCTAssertEqual(viewModel.keyPresent[.openai], true)
    }

    func testEmptyKeyIsIgnored() async throws {
        let verifier = FakeVerifier()
        let viewModel = makeViewModel(verifier)

        await viewModel.saveKey("   ", for: .groq)

        XCTAssertNil(try secrets.get("groq_api_key"))
        XCTAssertTrue(verifier.configs.isEmpty)
        XCTAssertEqual(viewModel.verifyState[.groq] ?? .idle, .idle)
    }

    func testRemoveKeyClearsTheSecretAndTheVerifyState() async throws {
        let verifier = FakeVerifier()
        let viewModel = makeViewModel(verifier)
        await viewModel.saveKey("gsk_live_key", for: .groq)
        XCTAssertEqual(viewModel.verifyState[.groq], .connected)

        viewModel.removeKey(for: .groq)

        XCTAssertNil(try secrets.get("groq_api_key"))
        XCTAssertEqual(viewModel.keyPresent[.groq], false)
        XCTAssertEqual(viewModel.verifyState[.groq], .idle)
    }

    func testVerifyWithoutAKeySaysSoInsteadOfCallingTheCore() async {
        let verifier = FakeVerifier()
        let viewModel = makeViewModel(verifier)

        await viewModel.verify(.openai)

        XCTAssertEqual(viewModel.verifyState[.openai], .failed(Copy.addKeyFirst))
        XCTAssertTrue(verifier.configs.isEmpty)
    }

    func testExistingKeyIsDetectedAtLaunch() throws {
        try secrets.set("openai_api_key", "sk-existing")

        let viewModel = makeViewModel(FakeVerifier())

        XCTAssertEqual(viewModel.keyPresent[.openai], true)
        XCTAssertEqual(viewModel.keyPresent[.groq], false)
    }

    // MARK: - Engine choice

    func testEngineChoicesPersistImmediately() {
        let viewModel = makeViewModel(FakeVerifier())

        viewModel.set(stt: .groq)
        viewModel.set(cleanup: .openai)

        let reloaded = SettingsStore(defaults: defaults).settings
        XCTAssertEqual(reloaded.stt, .groq)
        XCTAssertEqual(reloaded.cleanup, .openai)
        XCTAssertEqual(viewModel.stt, .groq)
        XCTAssertEqual(viewModel.cleanup, .openai)
    }

    func testProvidersInUseIsTranscriptionThenCleanupDeduped() {
        let viewModel = makeViewModel(FakeVerifier())

        XCTAssertEqual(viewModel.providersInUse, [])

        viewModel.set(stt: .groq)
        XCTAssertEqual(viewModel.providersInUse, [.groq])

        // Local speech with cloud cleanup still needs that provider's key — the gap the
        // desktop's `cloudProvidersInUse` was written to close.
        viewModel.set(stt: .local)
        viewModel.set(cleanup: .openai)
        XCTAssertEqual(viewModel.providersInUse, [.openai])

        viewModel.set(stt: .openai)
        XCTAssertEqual(viewModel.providersInUse, [.openai])

        viewModel.set(stt: .groq)
        XCTAssertEqual(viewModel.providersInUse, [.groq, .openai])
    }
}
