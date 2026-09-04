import AVFoundation
import Foundation
import MurmurCore

/// Everything that can stop a dictation, in the app's own vocabulary. `cloud` carries the
/// core's user-facing sentence; nothing here ever carries a key or a transcript.
public enum PipelineError: Error, Equatable {
    case micDenied
    case speechDenied
    case noSpeechEngine
    case cloud(String)
    /// Nothing was said. The recorder shows "Didn't catch that." and writes nothing.
    case empty
}

/// What a completed dictation produced. The flags are what the history row's banner reports.
public struct PipelineOutcome: Equatable {
    /// Already written to history, with its id.
    public var transcript: Transcript
    public var usedCloudStt: Bool
    public var usedCloudCleanup: Bool

    public init(transcript: Transcript, usedCloudStt: Bool, usedCloudCleanup: Bool) {
        self.transcript = transcript
        self.usedCloudStt = usedCloudStt
        self.usedCloudCleanup = usedCloudCleanup
    }
}

/// Microphone chunks in, a saved ``Transcript`` out.
///
/// This is the one place the engine choice, the fallbacks and the history write live, so the
/// recorder, the MM2 keyboard and the App Intent all behave identically. The order matters:
/// the row is written *before* the caller gets the text, so a transcript can never be lost
/// between here and the clipboard.
public final class DictationPipeline {
    private let settings: SettingsStore
    private let secrets: SecretStore
    private let history: HistoryStore
    private let localEngine: () -> SpeechEngine
    private let cloudEngine: (CloudConfig) -> SpeechEngine
    private let clean: (String, CloudConfig?) async -> CleanResult

    public init(
        settings: SettingsStore,
        secrets: SecretStore,
        history: HistoryStore,
        localEngine: @escaping () -> SpeechEngine = SpeechEngines.local,
        cloudEngine: @escaping (CloudConfig) -> SpeechEngine = SpeechEngines.cloud,
        clean: @escaping (String, CloudConfig?) async -> CleanResult = MurmurCore.cleanText
    ) {
        self.settings = settings
        self.secrets = secrets
        self.history = history
        self.localEngine = localEngine
        self.cloudEngine = cloudEngine
        self.clean = clean
    }

    public func run(
        audio: AsyncStream<AudioChunk>,
        source: TranscriptSource,
        partial: @escaping (String) -> Void
    ) async throws -> PipelineOutcome {
        let settings = self.settings.settings

        // 1. Speech to text. A cloud engine with no key in the Keychain is not an error —
        //    the user still gets their words, from the on-device engine.
        var usedCloudStt = false
        let raw: String
        if let cfg = config(for: settings.stt.provider) {
            // Everything the cloud engine consumes is kept so rule 2 has audio to retry with.
            let tape = ChunkTape()
            do {
                raw = try await cloudEngine(cfg).transcribe(tape.tapping(audio), partial: partial)
                usedCloudStt = true
            } catch {
                // 2. One retry, on device. Local failing after that is a real failure.
                raw = try await localEngine().transcribe(tape.replay(), partial: partial)
            }
        } else {
            raw = try await localEngine().transcribe(audio, partial: partial)
        }

        // 3. Silence writes nothing at all — no row, no clipboard, no handoff.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PipelineError.empty }

        // 4. Cleanup. The core falls back to its rules engine on any cloud failure, so this
        //    call cannot fail and cannot lose words.
        let cleanupConfig = settings.cleanup == .rule ? nil : config(for: settings.cleanup.provider)
        let cleaned = await clean(trimmed, cleanupConfig)
        let cleanText = cleaned.clean.trimmingCharacters(in: .whitespacesAndNewlines)

        // 5. History first, always.
        let saved = try history.insert(
            Transcript(
                rawText: trimmed,
                cleanText: cleanText.isEmpty ? trimmed : cleanText,
                source: source
            )
        )
        return PipelineOutcome(
            transcript: saved,
            usedCloudStt: usedCloudStt,
            usedCloudCleanup: cleaned.usedCloud
        )
    }

    /// The Keychain key for `provider`, wrapped for the core. `nil` for the local engine and
    /// for a provider whose key was never entered. The value is read here and passed straight
    /// into the core call; it is never stored, logged or returned.
    private func config(for provider: ProviderId?) -> CloudConfig? {
        guard let provider,
              let key = try? secrets.get(provider.keychainAccount)
        else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return CloudConfig(provider: provider.core, apiKey: trimmed)
    }
}

// MARK: - Engine choice → provider

public extension SttEngine {
    /// The cloud provider behind this choice, or `nil` for on-device.
    var provider: ProviderId? {
        switch self {
        case .local: return nil
        case .groq: return .groq
        case .openai: return .openai
        }
    }
}

public extension CleanupEngine {
    /// The cloud provider behind this choice, or `nil` for the core's offline rules.
    var provider: ProviderId? {
        switch self {
        case .rule: return nil
        case .groq: return .groq
        case .openai: return .openai
        }
    }
}

// MARK: - Replay

/// Keeps a copy of the audio handed to a cloud engine so a network failure can be retried on
/// device instead of asking the user to say it again.
///
/// Only the 16 kHz mono samples are kept — under 4 MB for the 120 s maximum, against ~45 MB
/// if the native capture buffers were retained, and the on-device engines resample whatever
/// they are given anyway.
private final class ChunkTape {
    private let lock = NSLock()
    private var recorded: [(samples: [Float], level: Float)] = []

    /// Passes `audio` through untouched while recording it.
    func tapping(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<AudioChunk> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            Task {
                for await chunk in audio {
                    self.record(chunk)
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }

    /// Synchronous on purpose: taking a lock directly inside an async function is an error
    /// in the Swift 6 language mode, and this cannot suspend anyway.
    private func record(_ chunk: AudioChunk) {
        lock.lock(); defer { lock.unlock() }
        recorded.append((chunk.samples16kMono, chunk.level))
    }

    /// The same audio again, rebuilt as 16 kHz mono buffers.
    func replay() -> AsyncStream<AudioChunk> {
        lock.lock()
        let recorded = self.recorded
        lock.unlock()

        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            for entry in recorded {
                guard let buffer = AudioMath.buffer16kMono(entry.samples) else { continue }
                continuation.yield(
                    AudioChunk(samples16kMono: entry.samples, level: entry.level, buffer: buffer)
                )
            }
            continuation.finish()
        }
    }
}
