import XCTest

import MurmurCore
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
    /// The crash journal Home reads its "finish last dictation" offer from — a throwaway
    /// directory, never the App Group.
    private var journalDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = SettingsStore(defaults: defaults)
        secrets = InMemorySecretStore()
        history = try HistoryStore.inMemory()
        copied = []
        journalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        settings = nil
        secrets = nil
        history = nil
        try? FileManager.default.removeItem(at: journalDirectory)
        journalDirectory = nil
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

    /// A speech engine that ignores its audio and returns what the test scripted. Only the
    /// recovery tests run the pipeline; everything else builds it and never calls it.
    private final class FakeEngine: SpeechEngine {
        private let text: String
        private(set) var samplesSeen = 0

        init(_ text: String) { self.text = text }

        func transcribe(
            _ audio: AsyncStream<AudioChunk>,
            partial: @escaping (String) -> Void
        ) async throws -> String {
            for await chunk in audio { samplesSeen += chunk.samples16kMono.count }
            return text
        }
    }

    private func makeApp(engine: FakeEngine? = nil) -> AppState {
        let pipeline: DictationPipeline
        if let engine {
            pipeline = DictationPipeline(
                settings: settings,
                secrets: secrets,
                history: history,
                localEngine: { engine },
                cloudEngine: { _ in engine },
                clean: { raw, _ in CleanResult(raw: raw, clean: "Clean: \(raw)", usedCloud: false) }
            )
        } else {
            pipeline = DictationPipeline(settings: settings, secrets: secrets, history: history)
        }
        return AppState(settings: settings, secrets: secrets, history: history, pipeline: pipeline)
    }

    /// Journals `seconds` of audio and back-dates it a minute, which is what makes it read as
    /// abandoned rather than live.
    @discardableResult
    private func writeAbandonedRecording(seconds: Double = 3) throws -> URL {
        let stale = Date().addingTimeInterval(-60)
        let journal = RecordingJournal(directory: journalDirectory, clock: { stale })
        let count = Int(seconds * Double(RecordingJournal.sampleRate))
        journal.append((0..<count).map { Float(sin(Double($0) * 0.02)) * 0.4 })
        try journal.flush()
        return journal.url
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
            hasActionButton: hasActionButton,
            recoveryProvider: { [journalDirectory] in
                RecordingJournal.pending(in: journalDirectory!)
            },
            loader: RecordingJournal.load
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

    // MARK: - Finish the last dictation

    func testNoBannerWhenNothingWasAbandoned() {
        let viewModel = makeViewModel(FakePermissions())

        viewModel.reload()

        XCTAssertNil(viewModel.pendingRecovery)
        XCTAssertNil(viewModel.recoveryError)
    }

    func testTheBannerReportsHowMuchAudioWasAbandoned() throws {
        try writeAbandonedRecording(seconds: 3)
        let viewModel = makeViewModel(FakePermissions())

        viewModel.reload()

        XCTAssertEqual(viewModel.pendingRecovery?.duration ?? 0, 3, accuracy: 0.01)
        XCTAssertEqual(Copy.recoveryDuration(viewModel.pendingRecovery?.duration ?? 0), "about 3 s")
    }

    func testFinishingTheAbandonedRecordingWritesItToHistoryAndClearsTheBanner() async throws {
        let url = try writeAbandonedRecording(seconds: 3)
        let engine = FakeEngine("hello there")
        let viewModel = makeViewModel(FakePermissions(), app: makeApp(engine: engine))
        viewModel.reload()
        XCTAssertNotNil(viewModel.pendingRecovery)

        await viewModel.finishPending()

        // The journalled audio really went through the pipeline, not a shortcut.
        XCTAssertEqual(engine.samplesSeen, 3 * RecordingJournal.sampleRate)
        XCTAssertEqual(viewModel.recent.map(\.cleanText), ["Clean: hello there"])
        XCTAssertEqual(copied, ["Clean: hello there"])
        XCTAssertNil(viewModel.pendingRecovery)
        XCTAssertNil(viewModel.recoveryError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNothingIsCopiedWhenTheClipboardSettingIsOff() async throws {
        settings.update { $0.copyToClipboard = false }
        try writeAbandonedRecording()
        let viewModel = makeViewModel(FakePermissions(), app: makeApp(engine: FakeEngine("hello there")))
        viewModel.reload()

        await viewModel.finishPending()

        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(viewModel.recent.count, 1)
    }

    func testAnUnusableRecordingSaysSoOnceAndIsThrownAway() async throws {
        let url = try writeAbandonedRecording()
        // Nothing recognised: the pipeline throws `PipelineError.empty`.
        let viewModel = makeViewModel(FakePermissions(), app: makeApp(engine: FakeEngine("")))
        viewModel.reload()

        await viewModel.finishPending()

        XCTAssertEqual(viewModel.recoveryError, Copy.recoveryFailed)
        XCTAssertNil(viewModel.pendingRecovery)
        XCTAssertTrue(viewModel.recent.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a second tap would fail the same way")
    }

    func testDiscardingTheAbandonedRecordingClearsTheBannerAndWritesNothing() throws {
        let url = try writeAbandonedRecording()
        let viewModel = makeViewModel(FakePermissions())
        viewModel.reload()
        XCTAssertNotNil(viewModel.pendingRecovery)

        viewModel.discardPending()

        XCTAssertNil(viewModel.pendingRecovery)
        XCTAssertTrue(viewModel.recent.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
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
