import Foundation
import MurmurCore
import MurmurShared
import UIKit

/// The engine and key state behind both the Settings screen and onboarding's engine step —
/// the phone's `src/components/EngineSettings.tsx`.
///
/// Nothing here ever holds a key longer than the call that needs it: ``saveKey(_:for:)`` puts
/// it straight into the Keychain and ``verify(_:)`` reads it back, hands it to the core, and
/// drops it. ``keyPresent`` is a boolean, never a value, so no screen and no log can show one.
@MainActor
final class EngineSettingsViewModel: ObservableObject {
    /// Where a provider's key stands right now. `failed` carries the core's own sentence.
    enum VerifyState: Equatable {
        case idle, verifying, connected
        case failed(String)
    }

    @Published private(set) var stt: SttEngine
    @Published private(set) var cleanup: CleanupEngine
    @Published private(set) var keyPresent: [ProviderId: Bool] = [:]
    @Published private(set) var verifyState: [ProviderId: VerifyState] = [:]
    /// The provider whose key is being saved, so its button can say "Connecting…".
    @Published private(set) var saving: ProviderId?

    private let settings: SettingsStore
    private let secrets: SecretStore
    private let verifyProvider: (CloudConfig) async throws -> Void
    private let openURL: (URL) -> Void

    init(
        settings: SettingsStore,
        secrets: SecretStore,
        verify: @escaping (CloudConfig) async throws -> Void = MurmurCore.verifyProvider(cfg:),
        // Hopped to the main actor because a default argument is evaluated outside the
        // type's isolation, and `UIApplication.shared` is main-actor only.
        openURL: @escaping (URL) -> Void = { url in Task { @MainActor in UIApplication.shared.open(url) } }
    ) {
        self.settings = settings
        self.secrets = secrets
        verifyProvider = verify
        self.openURL = openURL
        stt = settings.settings.stt
        cleanup = settings.settings.cleanup
        for provider in ProviderId.allCases {
            keyPresent[provider] = ((try? secrets.get(provider.keychainAccount)) ?? nil) != nil
        }
    }

    /// The cloud providers this configuration actually uses, transcription first — the same
    /// rule as the desktop's `cloudProvidersInUse`, which exists so that Local speech with
    /// OpenAI cleanup still shows the OpenAI key block.
    var providersInUse: [ProviderId] {
        var seen: [ProviderId] = []
        for provider in [stt.provider, cleanup.provider].compactMap({ $0 }) where !seen.contains(provider) {
            seen.append(provider)
        }
        return seen
    }

    // MARK: - Engine choice

    /// Persisted the moment it is tapped: there is no Save button anywhere in Murmur, and the
    /// keyboard extension reads the App Group defaults directly.
    func set(stt engine: SttEngine) {
        settings.update { $0.stt = engine }
        stt = engine
    }

    func set(cleanup engine: CleanupEngine) {
        settings.update { $0.cleanup = engine }
        cleanup = engine
    }

    // MARK: - Keys

    /// Stores a pasted key and immediately verifies it, so "did that work?" is answered on the
    /// same screen instead of at the start of the user's next dictation.
    ///
    /// A whitespace-only paste is not an error, just nothing: the field clears and the state
    /// is unchanged.
    func saveKey(_ key: String, for provider: ProviderId) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        saving = provider
        verifyState[provider] = .idle
        do {
            try secrets.set(provider.keychainAccount, trimmed)
            keyPresent[provider] = true
        } catch {
            saving = nil
            verifyState[provider] = .failed(Self.describe(error))
            return
        }
        saving = nil
        await verify(provider)
    }

    /// Forgets the key and everything the app had concluded about it.
    func removeKey(for provider: ProviderId) {
        try? secrets.delete(provider.keychainAccount)
        keyPresent[provider] = false
        verifyState[provider] = .idle
    }

    /// One round trip to the provider. A rejected key is left in the Keychain: the user may
    /// have pasted a good key for the wrong provider, and deleting it behind their back would
    /// lose the paste as well as the answer.
    func verify(_ provider: ProviderId) async {
        guard let key = try? secrets.get(provider.keychainAccount), !key.isEmpty else {
            verifyState[provider] = .failed(Copy.addKeyFirst)
            return
        }
        verifyState[provider] = .verifying
        do {
            try await verifyProvider(CloudConfig(provider: provider.core, apiKey: key))
            verifyState[provider] = .connected
        } catch {
            verifyState[provider] = .failed(Self.describe(error))
        }
    }

    /// Opens the provider's key page in Safari. The URL comes from the core so the Mac and the
    /// phone can never drift apart on it.
    func openKeyPage(_ provider: ProviderId) {
        guard let url = URL(string: CoreClient.keyPage(for: provider)) else { return }
        openURL(url)
    }

    // MARK: - Helpers

    /// The core's user-facing sentence when there is one; a `CoreError` case name never
    /// reaches the screen, and neither does anything derived from the key.
    private static func describe(_ error: Error) -> String {
        if let error = error as? CoreError { return error.message }
        return error.localizedDescription
    }
}
