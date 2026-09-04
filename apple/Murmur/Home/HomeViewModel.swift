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

    /// How many dictations Home shows (spec §5: "the last three dictations").
    static let recentCount = 3

    private let app: AppState
    private let permissions: PermissionsProviding
    private let pasteboard: (String) -> Void
    private var copyResetTask: Task<Void, Never>?

    /// `permissions` and `copy` are injected after `app` so the documented `init(app:)` call
    /// still reads the same, and so the tests never touch the microphone or the pasteboard.
    init(
        app: AppState,
        permissions: PermissionsProviding = LivePermissions(),
        copy: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }
    ) {
        self.app = app
        self.permissions = permissions
        pasteboard = copy
    }

    /// The speech chip only exists while the on-device engine is the one that would run: a
    /// user on Groq has no reason to be nagged about a permission Murmur will never use.
    var showsSpeechChip: Bool {
        app.settings.settings.stt == .local
    }

    var historyUnavailable: Bool { app.historyUnavailable }

    /// Re-reads permissions, the engine choice and the last three rows. Called when the screen
    /// appears and every time a dictation finishes.
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
