import XCTest

import MurmurShared
@testable import Murmur

/// The onboarding gate, with fake permissions: the real ones prompt exactly once per install
/// and would make these tests order-dependent and unrepeatable.
@MainActor
final class OnboardingViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        settings = nil
        super.tearDown()
    }

    // MARK: - Fake

    private final class FakePermissions: PermissionsProviding {
        var mic: PermissionStatus = .notDetermined
        var speech: PermissionStatus = .notDetermined
        /// What the system prompt would answer.
        var micGrants = true
        var speechGrants = true
        private(set) var micRequests = 0
        private(set) var speechRequests = 0

        func micStatus() -> PermissionStatus { mic }
        func speechStatus() -> PermissionStatus { speech }

        func requestMic() async -> Bool {
            micRequests += 1
            mic = micGrants ? .granted : .denied
            return micGrants
        }

        func requestSpeech() async -> Bool {
            speechRequests += 1
            speech = speechGrants ? .granted : .denied
            return speechGrants
        }
    }

    private func makeViewModel(
        permissions: FakePermissions,
        localAvailable: Bool = true,
        hasTestTranscript: @escaping () -> Bool = { false },
        keyboardEnabled: @escaping () -> Bool = { false },
        fullAccess: @escaping () -> Bool? = { nil },
        hasActionButton: Bool = false
    ) -> OnboardingViewModel {
        OnboardingViewModel(
            settings: settings,
            permissions: permissions,
            speechAvailability: { localAvailable },
            prepareLocalAssets: {},
            hasTestTranscript: hasTestTranscript,
            keyboardEnabledProvider: keyboardEnabled,
            fullAccessProvider: fullAccess,
            hasActionButton: hasActionButton
        )
    }

    // MARK: - Order

    func testStepOrderIsTheSpecs() {
        XCTAssertEqual(
            OnboardingViewModel.Step.allCases,
            [.microphone, .speech, .engine, .keyboard, .triggers, .test]
        )

        let viewModel = makeViewModel(permissions: FakePermissions())
        viewModel.step = .engine
        XCTAssertEqual(viewModel.nextStep, .keyboard)
        viewModel.step = .keyboard
        XCTAssertEqual(viewModel.nextStep, .triggers)
        viewModel.step = .triggers
        XCTAssertEqual(viewModel.nextStep, .test)
    }

    // MARK: - Microphone

    func testMicrophoneStepBlocksUntilGranted() async {
        let permissions = FakePermissions()
        let viewModel = makeViewModel(permissions: permissions)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.step, .microphone)
        XCTAssertFalse(viewModel.canAdvance)

        await viewModel.requestMic()
        XCTAssertEqual(permissions.micRequests, 1)
        XCTAssertEqual(viewModel.mic, .granted)
        XCTAssertTrue(viewModel.canAdvance)
    }

    func testDeniedMicrophoneIsNotAskedAgain() async {
        let permissions = FakePermissions()
        permissions.mic = .denied
        let viewModel = makeViewModel(permissions: permissions)

        await viewModel.requestMic()

        // The system prompt is one-shot; asking again is a silent no-op, so the view has to
        // send the user to Settings instead.
        XCTAssertEqual(permissions.micRequests, 0)
        XCTAssertEqual(viewModel.mic, .denied)
        XCTAssertFalse(viewModel.canAdvance)
    }

    // MARK: - Speech

    func testSpeechStepBlocksTheLocalEngineUntilGranted() async {
        let permissions = FakePermissions()
        permissions.mic = .granted
        let viewModel = makeViewModel(permissions: permissions)

        await viewModel.refresh()
        viewModel.advance()
        XCTAssertEqual(viewModel.step, .speech)
        XCTAssertFalse(viewModel.canAdvance)

        await viewModel.requestSpeech()
        XCTAssertTrue(viewModel.canAdvance)
    }

    func testChoosingGroqSkipsTheSpeechRequirement() async {
        let permissions = FakePermissions()
        permissions.mic = .granted
        let viewModel = makeViewModel(permissions: permissions)
        await viewModel.refresh()

        viewModel.choose(stt: .groq)
        viewModel.step = .speech

        // Apple speech recognition is never used on a cloud engine, so a denied prompt is
        // not in the way of anything.
        XCTAssertEqual(viewModel.speech, .notDetermined)
        XCTAssertTrue(viewModel.canAdvance)
        // …and the step is skipped outright on the way through.
        viewModel.step = .microphone
        XCTAssertEqual(viewModel.nextStep, .engine)
    }

    // MARK: - Engine

    func testEngineStepNeedsTheLocalModel() async {
        let permissions = FakePermissions()
        permissions.mic = .granted
        permissions.speech = .granted
        let viewModel = makeViewModel(permissions: permissions, localAvailable: false)

        viewModel.step = .engine
        XCTAssertFalse(viewModel.canAdvance)

        await viewModel.prepareLocal()
        XCTAssertFalse(viewModel.localReady)
        XCTAssertFalse(viewModel.canAdvance)
    }

    func testEngineStepIsReadyOnceTheLocalModelIsInstalled() async {
        let viewModel = makeViewModel(permissions: FakePermissions(), localAvailable: true)
        viewModel.step = .engine

        await viewModel.prepareLocal()

        XCTAssertTrue(viewModel.localReady)
        XCTAssertFalse(viewModel.preparingLocal)
        XCTAssertTrue(viewModel.canAdvance)
    }

    func testCloudEngineStepNeedsAVerifiedKey() {
        let viewModel = makeViewModel(permissions: FakePermissions())
        viewModel.choose(stt: .openai)
        viewModel.step = .engine

        // A key that has not verified is not a working engine.
        XCTAssertFalse(viewModel.canAdvance)

        viewModel.cloudVerified = true
        XCTAssertTrue(viewModel.canAdvance)
    }

    func testChoosingAnEnginePersistsImmediately() {
        let viewModel = makeViewModel(permissions: FakePermissions())

        viewModel.choose(stt: .groq)

        XCTAssertEqual(viewModel.stt, .groq)
        XCTAssertEqual(SettingsStore(defaults: defaults).settings.stt, .groq)
    }

    // MARK: - Keyboard and triggers

    func testKeyboardStepBlocksUntilTheKeyboardIsEnabled() async {
        var enabled = false
        let viewModel = makeViewModel(permissions: FakePermissions(), keyboardEnabled: { enabled })
        viewModel.step = .keyboard

        await viewModel.refresh()
        XCTAssertFalse(viewModel.keyboardEnabled)
        XCTAssertFalse(viewModel.canAdvance)

        // The user left for Settings and added it; the poll picks it up with no further input.
        enabled = true
        viewModel.refreshKeyboardStatus()
        XCTAssertTrue(viewModel.keyboardEnabled)
        XCTAssertTrue(viewModel.canAdvance)
    }

    func testFullAccessDoesNotGateTheKeyboardStep() {
        let viewModel = makeViewModel(
            permissions: FakePermissions(),
            keyboardEnabled: { true },
            fullAccess: { false }
        )
        viewModel.step = .keyboard

        viewModel.refreshKeyboardStatus()

        // Every key types without Full Access (guideline 4.4.1); only the mic key needs it, and
        // it explains itself in place.
        XCTAssertEqual(viewModel.fullAccess, false)
        XCTAssertTrue(viewModel.canAdvance)

        XCTAssertFalse(viewModel.fullAccessDeferred)
        viewModel.deferFullAccess()
        XCTAssertTrue(viewModel.fullAccessDeferred)
    }

    func testFullAccessIsUnknownUntilTheKeyboardHasAppeared() {
        let viewModel = makeViewModel(permissions: FakePermissions(), keyboardEnabled: { true })

        viewModel.refreshKeyboardStatus()

        XCTAssertNil(viewModel.fullAccess)
    }

    func testTriggersStepAlwaysAdvances() {
        let viewModel = makeViewModel(permissions: FakePermissions(), keyboardEnabled: { false })
        viewModel.step = .triggers

        XCTAssertTrue(viewModel.canAdvance)

        viewModel.advance()
        XCTAssertEqual(viewModel.step, .test)
    }

    func testActionButtonOnlyChangesWhatTheTriggersStepShows() {
        for present in [false, true] {
            let viewModel = makeViewModel(permissions: FakePermissions(), hasActionButton: present)
            viewModel.step = .triggers

            XCTAssertEqual(viewModel.hasActionButton, present)
            XCTAssertTrue(viewModel.canAdvance)
            XCTAssertEqual(viewModel.nextStep, .test)
        }
    }

    func testTestItRunsTheInjectedTrigger() {
        var fired = 0
        let viewModel = makeViewModel(permissions: FakePermissions())
        viewModel.onTestTrigger = { fired += 1 }

        viewModel.testTrigger()

        XCTAssertEqual(fired, 1)
    }

    // MARK: - Test step and finish

    func testTestStepUnlocksOnceADictationExists() async {
        var dictated = false
        let viewModel = makeViewModel(permissions: FakePermissions(), hasTestTranscript: { dictated })
        viewModel.step = .test

        await viewModel.refresh()
        XCTAssertFalse(viewModel.canAdvance)

        dictated = true
        await viewModel.refresh()
        XCTAssertTrue(viewModel.didTest)
        XCTAssertTrue(viewModel.canAdvance)
        XCTAssertNil(viewModel.nextStep)
    }

    func testFinishFlipsTheSetting() {
        let viewModel = makeViewModel(permissions: FakePermissions())
        XCTAssertFalse(settings.settings.onboardingComplete)

        viewModel.finish()

        XCTAssertTrue(settings.settings.onboardingComplete)
        XCTAssertTrue(SettingsStore(defaults: defaults).settings.onboardingComplete)
    }
}
