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
/// The order is the spec's (§5): microphone, speech recognition, engine, the keyboard, the
/// other ways to trigger a dictation, and one test dictation. Each
/// step has exactly one thing to do and ``canAdvance`` says whether it has been done; the view
/// owns no rules of its own, which is what makes the whole flow testable with fakes.
///
/// MM2 adds the two steps that make Murmur reachable from outside the app: the keyboard,
/// which is a gate (the keyboard *is* the product), and the triggers, which is not.
@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Equatable, CaseIterable {
        case microphone, speech, engine, keyboard, triggers, test
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
    /// The Murmur keyboard is in the user's keyboard list. Polled once a second while the
    /// keyboard step is on screen: iOS posts no notification when it changes.
    @Published var keyboardEnabled = false
    /// The keyboard's Full Access heartbeat: `nil` until the keyboard has appeared once, which
    /// is why the step tells the user how to make it appear.
    @Published var fullAccess: Bool?
    /// Set by the "Later" link: the Full Access nag is dismissed for this run. It never gated
    /// anything — the keyboard explains it again at the mic key.
    @Published var fullAccessDeferred = false

    /// This iPhone has an Action Button, so the triggers step has something to say about it.
    let hasActionButton: Bool

    /// The triggers step's "Test it". The view owns it because only the view can reach
    /// ``AppState``.
    var onTestTrigger: (() -> Void)?

    private let settings: SettingsStore
    private let permissions: PermissionsProviding
    private let speechAvailability: () async -> Bool
    private let prepareLocalAssets: () async throws -> Void
    private let hasTestTranscript: () -> Bool
    private let keyboardEnabledProvider: () -> Bool
    private let fullAccessProvider: () -> Bool?

    /// `prepareLocalAssets` and `hasTestTranscript` are injected after the three parameters
    /// the plan names so the documented call site still reads the same; they exist so a unit
    /// test never reaches the Speech framework or the App Group database.
    init(
        settings: SettingsStore,
        permissions: PermissionsProviding = LivePermissions(),
        speechAvailability: @escaping () async -> Bool = SpeechEngines.isLocalAvailable,
        prepareLocalAssets: @escaping () async throws -> Void = SpeechEngines.prepareLocalAssets,
        hasTestTranscript: @escaping () -> Bool = { false },
        keyboardEnabledProvider: @escaping () -> Bool = { KeyboardStatus.isEnabled() },
        fullAccessProvider: @escaping () -> Bool? = { KeyboardStatus.hasFullAccess() },
        hasActionButton: Bool = KeyboardStatus.hasActionButton
    ) {
        self.settings = settings
        self.permissions = permissions
        self.speechAvailability = speechAvailability
        self.prepareLocalAssets = prepareLocalAssets
        self.hasTestTranscript = hasTestTranscript
        self.keyboardEnabledProvider = keyboardEnabledProvider
        self.fullAccessProvider = fullAccessProvider
        self.hasActionButton = hasActionButton
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
        case .keyboard:
            // The one hard gate MM2 adds. Full Access is not part of it: the keyboard types
            // without it, and the mic key explains it in place when it is missing.
            return keyboardEnabled
        case .triggers:
            // Nothing to require — the Control Center button and the Action Button are extra
            // ways in, not the product.
            return true
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
            return .keyboard
        case .keyboard:
            return .triggers
        case .triggers:
            return .test
        case .test:
            return nil
        }
    }

    func advance() {
        guard let next = nextStep else { return }
        step = next
    }

    // MARK: - The keyboard

    /// Re-reads both keyboard answers. Cheap: two `UserDefaults` lookups.
    func refreshKeyboardStatus() {
        keyboardEnabled = keyboardEnabledProvider()
        fullAccess = fullAccessProvider()
    }

    /// Keeps asking while the keyboard step is on screen.
    ///
    /// There is no notification for "the user added a keyboard in Settings", and the user is
    /// expected to leave for Settings and come back mid-step, so the only way for the check to
    /// turn green on its own is to look again every second. The view runs this in a `.task`
    /// bound to the step, which cancels it on the way out.
    func pollKeyboardStatus(interval: TimeInterval = 1) async {
        while !Task.isCancelled {
            refreshKeyboardStatus()
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    /// "Later" on the Full Access row: stop showing it for this run.
    func deferFullAccess() {
        fullAccessDeferred = true
    }

    /// The triggers step's "Test it".
    func testTrigger() {
        onTestTrigger?()
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
        refreshKeyboardStatus()
        if stt == .local {
            localReady = await speechAvailability()
        }
    }

    /// Onboarding is over: the tabs replace this screen on the next render.
    func finish() {
        settings.update { $0.onboardingComplete = true }
    }
}
