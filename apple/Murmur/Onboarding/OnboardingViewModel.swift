import Combine
import Foundation
import MurmurShared

/// The two system permissions, behind a protocol so onboarding and Home can be tested without
/// a microphone and without the one-shot system prompts (which a simulator only ever shows
/// once per install).
protocol PermissionsProviding {
    func micStatus() -> PermissionStatus
    func requestMic() async -> Bool
    func speechStatus() -> PermissionStatus
    func requestSpeech() async -> Bool
}

/// The real thing: a thin forward to ``Permissions``.
struct LivePermissions: PermissionsProviding {
    func micStatus() -> PermissionStatus { Permissions.micStatus() }
    func requestMic() async -> Bool { await Permissions.requestMic() }
    func speechStatus() -> PermissionStatus { Permissions.speechStatus() }
    func requestSpeech() async -> Bool { await Permissions.requestSpeech() }
}

/// First run, one step per screen.
///
/// The order is the spec's (§5): microphone, speech recognition, engine, test dictation. Each
/// step has exactly one thing to do and ``canAdvance`` says whether it has been done; the view
/// owns no rules of its own, which is what makes the whole flow testable with fakes.
///
/// MM2 appends the keyboard and Action Button steps to ``Step``; nothing else here changes.
@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Equatable, CaseIterable {
        case microphone, speech, engine, test
    }

    @Published var step: Step = .microphone
    @Published var mic: PermissionStatus = .notDetermined
    @Published var speech: PermissionStatus = .notDetermined
    /// On-device speech can run right now: the model for the user's language is installed.
    @Published var localReady = false
    /// The asset download from ``prepareLocal()`` is in flight.
    @Published var preparingLocal = false
    /// Mirrors `settings.stt` so the view redraws on a choice; ``choose(stt:)`` is the only
    /// thing that writes it, and it persists through the store in the same breath.
    @Published private(set) var stt: SttEngine
    /// Set by the engine step once a cloud key has verified. Onboarding cannot ask the
    /// Keychain itself — that is ``EngineSettingsViewModel``'s job, and this is the one bit of
    /// its state the step gate needs.
    @Published var cloudVerified = false
    /// A dictation has been completed from inside the app; refreshed by ``refresh()``.
    @Published var didTest = false

    private let settings: SettingsStore
    private let permissions: PermissionsProviding
    private let speechAvailability: () async -> Bool
    private let prepareLocalAssets: () async throws -> Void
    private let hasTestTranscript: () -> Bool

    /// `prepareLocalAssets` and `hasTestTranscript` are injected after the three parameters
    /// the plan names so the documented call site still reads the same; they exist so a unit
    /// test never reaches the Speech framework or the App Group database.
    init(
        settings: SettingsStore,
        permissions: PermissionsProviding = LivePermissions(),
        speechAvailability: @escaping () async -> Bool = SpeechEngines.isLocalAvailable,
        prepareLocalAssets: @escaping () async throws -> Void = SpeechEngines.prepareLocalAssets,
        hasTestTranscript: @escaping () -> Bool = { false }
    ) {
        self.settings = settings
        self.permissions = permissions
        self.speechAvailability = speechAvailability
        self.prepareLocalAssets = prepareLocalAssets
        self.hasTestTranscript = hasTestTranscript
        stt = settings.settings.stt
    }

    // MARK: - Gating

    /// Whether the current step's one job is done.
    ///
    /// The engine step is the only interesting one: `local` needs the on-device model to be
    /// there, a cloud engine needs a key that actually verified — a saved-but-rejected key is
    /// not a working engine and must not let anyone through to a dictation that will fail.
    var canAdvance: Bool {
        switch step {
        case .microphone:
            return mic == .granted
        case .speech:
            // A cloud engine does not need Apple speech recognition at all, so the step is
            // not a gate for anyone who has already switched away from Local.
            return speech == .granted || stt != .local
        case .engine:
            return stt == .local ? localReady : cloudVerified
        case .test:
            return didTest
        }
    }

    /// The next step, skipping the ones that do not apply. `nil` on the last step.
    var nextStep: Step? {
        switch step {
        case .microphone:
            return stt == .local ? .speech : .engine
        case .speech:
            return .engine
        case .engine:
            return .test
        case .test:
            return nil
        }
    }

    func advance() {
        guard let next = nextStep else { return }
        step = next
    }

    // MARK: - Actions

    func requestMic() async {
        if permissions.micStatus() == .notDetermined {
            _ = await permissions.requestMic()
        }
        mic = permissions.micStatus()
    }

    func requestSpeech() async {
        if permissions.speechStatus() == .notDetermined {
            _ = await permissions.requestSpeech()
        }
        speech = permissions.speechStatus()
    }

    /// Persists the engine choice immediately — someone who quits during onboarding and comes
    /// back should not have to pick again — and starts the on-device download for Local.
    func choose(stt engine: SttEngine) {
        settings.update { $0.stt = engine }
        stt = engine
        if engine == .local {
            Task { await prepareLocal() }
        }
    }

    /// Makes sure the on-device model is present. Cheap and idempotent: if the language is
    /// already installed this is one availability check and no download.
    func prepareLocal() async {
        if await speechAvailability() {
            localReady = true
            preparingLocal = false
            return
        }
        preparingLocal = true
        try? await prepareLocalAssets()
        localReady = await speechAvailability()
        preparingLocal = false
    }

    /// Re-reads everything the system may have changed behind the app's back — the user can
    /// leave for Settings at any step and come back with a different answer.
    func refresh() async {
        mic = permissions.micStatus()
        speech = permissions.speechStatus()
        didTest = hasTestTranscript()
        if stt == .local {
            localReady = await speechAvailability()
        }
    }

    /// Onboarding is over: the tabs replace this screen on the next render.
    func finish() {
        settings.update { $0.onboardingComplete = true }
    }
}
