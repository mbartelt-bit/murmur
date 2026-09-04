import XCTest

import MurmurShared
@testable import Murmur

/// The Home screen's readiness chips and recent list, built on an `AppState` made entirely of
/// fakes: no microphone, no Keychain, no App Group database.
@MainActor
final class HomeViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var secrets: InMemorySecretStore!
    private var history: HistoryStore!
    private var copied: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = SettingsStore(defaults: defaults)
        secrets = InMemorySecretStore()
        history = try HistoryStore.inMemory()
        copied = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        settings = nil
        secrets = nil
        history = nil
        super.tearDown()
    }

    private final class FakePermissions: PermissionsProviding {
        var mic: PermissionStatus = .granted
        var speech: PermissionStatus = .granted

        func micStatus() -> PermissionStatus { mic }
        func speechStatus() -> PermissionStatus { speech }
        func requestMic() async -> Bool { mic == .granted }
        func requestSpeech() async -> Bool { speech == .granted }
    }

    private func makeApp() -> AppState {
        AppState(
            settings: settings,
            secrets: secrets,
            history: history,
            pipeline: DictationPipeline(settings: settings, secrets: secrets, history: history)
        )
    }

    private func makeViewModel(
        _ permissions: FakePermissions,
        app: AppState? = nil,
        keyboardEnabled: @escaping () -> Bool = { false },
        fullAccess: @escaping () -> Bool? = { nil },
        hasActionButton: Bool = false
    ) -> HomeViewModel {
        HomeViewModel(
            app: app ?? makeApp(),
            permissions: permissions,
            copy: { [weak self] in self?.copied.append($0) },
            keyboardEnabledProvider: keyboardEnabled,
            fullAccessProvider: fullAccess,
            hasActionButton: hasActionButton
        )
    }

    // MARK: - Recent list

    func testRecentShowsTheThreeNewestDictations() throws {
        for index in 1...5 {
            try history.insert(Transcript(rawText: "raw \(index)", cleanText: "Clean \(index).", source: .inApp))
        }

        let viewModel = makeViewModel(FakePermissions())
        viewModel.reload()

        XCTAssertEqual(viewModel.recent.map(\.cleanText), ["Clean 5.", "Clean 4.", "Clean 3."])
    }

    func testCopyPutsTheCleanTextOnThePasteboard() throws {
        let row = try history.insert(Transcript(rawText: "um hi", cleanText: "Hi.", source: .inApp))
        let viewModel = makeViewModel(FakePermissions())
        viewModel.reload()

        viewModel.copy(row)

        XCTAssertEqual(copied, ["Hi."])
        XCTAssertEqual(viewModel.copiedID, row.id)
    }

    // MARK: - Chips

    func testChipsReportTheLivePermissionStatuses() {
        let permissions = FakePermissions()
        permissions.mic = .denied
        permissions.speech = .notDetermined
        let viewModel = makeViewModel(permissions)

        viewModel.reload()

        XCTAssertEqual(viewModel.mic, .denied)
        XCTAssertEqual(viewModel.speech, .notDetermined)
        // Local is the default engine, so Apple speech recognition is the one that matters.
        XCTAssertTrue(viewModel.showsSpeechChip)
    }

    func testSpeechChipDisappearsOnACloudEngine() {
        settings.update { $0.stt = .groq }
        let viewModel = makeViewModel(FakePermissions())

        viewModel.reload()

        XCTAssertFalse(viewModel.showsSpeechChip)
    }

    func testEngineChipDescribesTheLocalEngine() {
        let viewModel = makeViewModel(FakePermissions())

        viewModel.reload()

        XCTAssertEqual(viewModel.engineSummary, "Local · on device")
        XCTAssertFalse(viewModel.engineNeedsAttention)
    }

    func testEngineChipAsksForAKeyWhenACloudEngineHasNone() throws {
        settings.update { $0.stt = .groq }
        let viewModel = makeViewModel(FakePermissions())

        viewModel.reload()
        XCTAssertEqual(viewModel.engineSummary, "Groq · no key")
        XCTAssertTrue(viewModel.engineNeedsAttention)

        try secrets.set("groq_api_key", "gsk_live_key")
        viewModel.reload()
        XCTAssertEqual(viewModel.engineSummary, "Groq · connected")
        XCTAssertFalse(viewModel.engineNeedsAttention)
    }

    // MARK: - Keyboard chips

    func testKeyboardChipsReadTheLiveStatus() {
        var enabled = false
        var access: Bool?
        let viewModel = makeViewModel(
            FakePermissions(),
            keyboardEnabled: { enabled },
            fullAccess: { access }
        )

        viewModel.reload()
        XCTAssertFalse(viewModel.keyboardEnabled)
        // No heartbeat yet: unknown, not "off". The chip says so rather than guessing.
        XCTAssertNil(viewModel.fullAccess)

        enabled = true
        access = true
        viewModel.reload()
        XCTAssertTrue(viewModel.keyboardEnabled)
        XCTAssertEqual(viewModel.fullAccess, true)

        access = false
        viewModel.reload()
        XCTAssertEqual(viewModel.fullAccess, false)
    }

    func testActionButtonChipOnlyExistsOnHardwareThatHasOne() {
        XCTAssertFalse(makeViewModel(FakePermissions(), hasActionButton: false).hasActionButton)
        XCTAssertTrue(makeViewModel(FakePermissions(), hasActionButton: true).hasActionButton)
    }

    // MARK: - Dictation

    func testStartDictationRaisesAnInAppRequest() {
        let app = makeApp()
        let viewModel = makeViewModel(FakePermissions(), app: app)

        viewModel.startDictation()

        XCTAssertEqual(app.activeDictation?.source, .inApp)
        XCTAssertNil(app.activeDictation?.session)
    }

    func testHistoryUnavailableIsCarriedThrough() {
        let app = AppState(
            settings: settings,
            secrets: secrets,
            history: history,
            pipeline: DictationPipeline(settings: settings, secrets: secrets, history: history),
            historyUnavailable: true
        )

        XCTAssertTrue(makeViewModel(FakePermissions(), app: app).historyUnavailable)
    }
}
