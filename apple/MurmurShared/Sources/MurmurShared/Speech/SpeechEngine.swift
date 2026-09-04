import AVFoundation
import Foundation
import MurmurCore
import Speech

/// Anything that turns a stream of microphone chunks into one string.
///
/// The three implementations — ``AnalyzerSpeechEngine`` (iOS 26), ``LegacySpeechEngine``
/// (iOS 17–25) and ``CloudSpeechEngine`` — are interchangeable behind this, which is what
/// lets ``DictationPipeline`` fall back from cloud to local without knowing either.
///
/// `partial` is called with the best guess so far, on whatever thread the engine happens to
/// be on; the recorder hops to the main actor itself.
public protocol SpeechEngine {
    func transcribe(_ audio: AsyncStream<AudioChunk>, partial: @escaping (String) -> Void) async throws -> String
}

/// Picks and prepares engines. The only place in the app that knows iOS 26 exists.
public enum SpeechEngines {
    /// The on-device engine. Which one is decided per dictation, not here — see
    /// ``LocalSpeechEngine``.
    public static func local() -> SpeechEngine {
        LocalSpeechEngine()
    }

    public static func cloud(_ cfg: MurmurCore.CloudConfig) -> SpeechEngine {
        CloudSpeechEngine(cfg: cfg)
    }

    /// Whether a dictation can run entirely on device right now: an installed
    /// `SpeechTranscriber` locale on iOS 26, on-device support in `SFSpeechRecognizer` before
    /// that. Onboarding gates the "Local" engine choice on this.
    public static func isLocalAvailable() async -> Bool {
        if #available(iOS 26, *) {
            if await analyzerLocale() != nil { return true }
        }
        return legacyRecognizer() != nil
    }

    /// Downloads the on-device model for the user's language if it is missing and reserves the
    /// locale, so the first dictation is never stuck behind a download. No-op before iOS 26,
    /// where `SFSpeechRecognizer` manages its own assets.
    public static func prepareLocalAssets() async throws {
        guard #available(iOS 26, *) else { return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { return }

        let transcriber = AnalyzerSpeechEngine.makeTranscriber(locale: locale)
        if !(await isInstalled(locale)) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        // Reservations are a small fixed pool shared with the rest of the system; taking the
        // last slot from something else would be rude, and the engine works unreserved (the
        // asset is just evictable), so a full pool is not an error.
        let reserved = await AssetInventory.reservedLocales
        let alreadyOurs = reserved.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        guard !alreadyOurs, reserved.count < AssetInventory.maximumReservedLocales else { return }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    /// The user's language as `SpeechTranscriber` names it, or `nil` when its model is not
    /// installed (or the language is unsupported).
    @available(iOS 26, *)
    static func analyzerLocale() async -> Locale? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current),
              await isInstalled(locale)
        else { return nil }
        return locale
    }

    @available(iOS 26, *)
    private static func isInstalled(_ locale: Locale) async -> Bool {
        await SpeechTranscriber.installedLocales
            .contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// An `SFSpeechRecognizer` that can work offline, or `nil`.
    static func legacyRecognizer() -> SFSpeechRecognizer? {
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(),
              recognizer.supportsOnDeviceRecognition
        else { return nil }
        return recognizer
    }
}

/// Chooses between the two on-device engines at the moment of transcription.
///
/// The choice cannot be made when the engine is *built*, because "is the iOS 26 model
/// installed" is an async question and ``SpeechEngines/local()`` is called from a view
/// model's init. Deciding here also implements the spec's rule that a phone on iOS 26 with
/// the assets still downloading falls back to `SFSpeechRecognizer` for that dictation
/// instead of failing.
struct LocalSpeechEngine: SpeechEngine {
    func transcribe(_ audio: AsyncStream<AudioChunk>, partial: @escaping (String) -> Void) async throws -> String {
        if #available(iOS 26, *), let locale = await SpeechEngines.analyzerLocale() {
            return try await AnalyzerSpeechEngine(locale: locale).transcribe(audio, partial: partial)
        }
        return try await LegacySpeechEngine().transcribe(audio, partial: partial)
    }
}
