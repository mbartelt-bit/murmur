import Combine
import Foundation
import MurmurCore

/// Which engine turns speech into text.
public enum SttEngine: String, Codable, CaseIterable {
    case local, groq, openai
}

/// Which engine cleans the transcript up. `rule` is the core's offline rules pass.
public enum CleanupEngine: String, Codable, CaseIterable {
    case rule, groq, openai
}

/// The two cloud providers, and everything the UI needs to talk about one.
///
/// The copy here is lifted verbatim from the desktop's `src/components/EngineSettings.tsx`
/// `PROVIDER_INFO` so the phone and the Mac say exactly the same things.
public enum ProviderId: String, Codable, CaseIterable {
    case groq, openai

    /// Keychain account name — the desktop's, so a future sync sees the same items.
    public var keychainAccount: String {
        switch self {
        case .groq: return "groq_api_key"
        case .openai: return "openai_api_key"
        }
    }

    /// The matching `murmur-core` provider for a ``MurmurCore/CloudConfig``.
    public var core: MurmurCore.Provider {
        switch self {
        case .groq: return .groq
        case .openai: return .openAi
        }
    }

    public var displayName: String {
        switch self {
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        }
    }

    public var costLabel: String {
        switch self {
        case .groq: return "Free tier · no card"
        case .openai: return "Pay-as-you-go · card required"
        }
    }

    public var signupSteps: [String] {
        switch self {
        case .groq:
            return [
                "Sign in with Google or GitHub",
                "Click \"Create API Key\"",
                "Copy it and paste below",
            ]
        case .openai:
            return [
                "Add ~$5 credit + a card",
                "Click \"Create new secret key\"",
                "Copy it and paste below",
            ]
        }
    }
}

/// Everything the app remembers that is not a secret. Persisted as JSON in the App Group so
/// the keyboard extension can read the engine choice without launching the app.
public struct Settings: Codable, Equatable {
    public var stt: SttEngine = .local
    public var cleanup: CleanupEngine = .rule
    public var autoStopOnSilence = true
    public var copyToClipboard = true
    public var onboardingComplete = false

    public init() {}

    /// Decoded field by field so a blob written by an older build (or a future one that drops
    /// a key) still loads with the defaults instead of throwing the user's settings away.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stt = try c.decodeIfPresent(SttEngine.self, forKey: .stt) ?? .local
        cleanup = try c.decodeIfPresent(CleanupEngine.self, forKey: .cleanup) ?? .rule
        autoStopOnSilence = try c.decodeIfPresent(Bool.self, forKey: .autoStopOnSilence) ?? true
        copyToClipboard = try c.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? true
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? false
    }
}

/// Observable owner of ``Settings``. Views bind to it; every mutation goes through
/// ``update(_:)`` so persisting and publishing can never drift apart.
public final class SettingsStore: ObservableObject {
    @Published public private(set) var settings: Settings

    private let defaults: UserDefaults
    private static let storageKey = "settings.v1"

    public init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        } else {
            settings = Settings()
        }
    }

    /// Mutate, persist, publish — in that order.
    public func update(_ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.storageKey)
        }
        settings = next
    }
}
