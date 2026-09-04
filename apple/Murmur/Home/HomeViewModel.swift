import Foundation
import MurmurShared
import UIKit

/// What the Home screen knows: is Murmur ready, and what did it write last.
///
/// Home is the screen a user lands on every time, so it is also the app's standing health
/// check — a permission revoked in Settings months later shows up here as a chip with a fix,
/// not as a failed dictation.
@MainActor
final class HomeViewModel: ObservableObject {
    @Published var recent: [Transcript] = []
    @Published var mic: PermissionStatus = .notDetermined
    @Published var speech: PermissionStatus = .notDetermined
    /// The engine chip's second line, e.g. "Local · on device" or "Groq · no key".
    @Published var engineSummary: String = ""
    /// `true` when the chosen engine cannot actually run — no on-device model, or a cloud
    /// engine with no key.
    @Published var engineNeedsAttention = false
    /// The row whose "Copied" check is showing.
    @Published var copiedID: Int64?
    /// The Murmur keyboard is in the user's keyboard list.
    @Published var keyboardEnabled = false
    /// The keyboard's Full Access heartbeat — `nil` until the keyboard has appeared once.
    @Published var fullAccess: Bool?

    /// This iPhone has an Action Button, so Home offers to set it up. Hardware never changes
    /// under a running app, so it is read once.
    let hasActionButton: Bool

    /// How many dictations Home shows (spec §5: "the last three dictations").
    static let recentCount = 3

    private let app: AppState
    private let permissions: PermissionsProviding
    private let pasteboard: (String) -> Void
    private let keyboardEnabledProvider: () -> Bool
    private let fullAccessProvider: () -> Bool?
    private var copyResetTask: Task<Void, Never>?

    /// `permissions` and `copy` are injected after `app` so the documented `init(app:)` call
    /// still reads the same, and so the tests never touch the microphone or the pasteboard.
    init(
        app: AppState,
        permissions: PermissionsProviding = LivePermissions(),
        copy: @escaping (String) -> Void = { UIPasteboard.general.string = $0 },
        keyboardEnabledProvider: @escaping () -> Bool = { KeyboardStatus.isEnabled() },
        fullAccessProvider: @escaping () -> Bool? = { KeyboardStatus.hasFullAccess() },
        hasActionButton: Bool = KeyboardStatus.hasActionButton
    ) {
        self.app = app
        self.permissions = permissions
        pasteboard = copy
        self.keyboardEnabledProvider = keyboardEnabledProvider
        self.fullAccessProvider = fullAccessProvider
        self.hasActionButton = hasActionButton
    }

    /// The speech chip only exists while the on-device engine is the one that would run: a
    /// user on Groq has no reason to be nagged about a permission Murmur will never use.
    var showsSpeechChip: Bool {
        app.settings.settings.stt == .local
    }

    var historyUnavailable: Bool { app.historyUnavailable }

    /// Re-reads permissions, the engine choice, the keyboard's two answers and the last three
    /// rows. Called when the screen appears and every time a dictation finishes.
    func reload() {
        mic = permissions.micStatus()
        speech = permissions.speechStatus()

        let stt = app.settings.settings.stt
        let keyPresent: Bool
        if let provider = stt.provider {
            keyPresent = ((try? app.secrets.get(provider.keychainAccount)) ?? nil)?.isEmpty == false
        } else {
            keyPresent = true
        }
        engineSummary = Copy.engineSummary(stt: stt, keyPresent: keyPresent)
        engineNeedsAttention = !keyPresent

        keyboardEnabled = keyboardEnabledProvider()
        fullAccess = fullAccessProvider()

        recent = (try? app.history.recent(Self.recentCount)) ?? []
    }

    func startDictation() {
        app.startInAppDictation()
    }

    /// Same behaviour as a History row: tap copies the cleaned text and shows a check.
    func copy(_ transcript: Transcript) {
        pasteboard(transcript.cleanText)
        copiedID = transcript.id
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.copiedID == transcript.id else { return }
                self.copiedID = nil
            }
        }
    }

    /// What tapping the microphone chip should do: ask, if the system will still ask; send the
    /// user to Settings once it will not.
    func fixMic() async {
        if mic == .notDetermined {
            _ = await permissions.requestMic()
            mic = permissions.micStatus()
        } else if mic == .denied {
            Permissions.openSettings()
        }
    }

    func fixSpeech() async {
        if speech == .notDetermined {
            _ = await permissions.requestSpeech()
            speech = permissions.speechStatus()
        } else if speech == .denied {
            Permissions.openSettings()
        }
    }
}
