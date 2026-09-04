import AVFoundation
import Foundation
import Speech

/// The iOS 17–25 on-device engine.
///
/// `requiresOnDeviceRecognition = true` is the whole point: without it Apple ships the audio
/// to its servers, which is exactly what a "Local" engine must never do. Recognisers that
/// cannot work offline are rejected up front rather than silently going online.
public final class LegacySpeechEngine: SpeechEngine {
    /// `kAFAssistantErrorDomain` 1110 is "no speech detected" — silence, not a failure. It
    /// becomes an empty transcript so the pipeline reports "Didn't catch that." like every
    /// other empty result.
    private static let noSpeechDomain = "kAFAssistantErrorDomain"
    private static let noSpeechCode = 1_110

    /// Held for the duration of the call: dropping either cancels recognition mid-flight.
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?

    public init() {}

    public func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        partial: @escaping (String) -> Void
    ) async throws -> String {
        guard let onDevice = SpeechEngines.legacyRecognizer() else {
            throw PipelineError.noSpeechEngine
        }
        recognizer = onDevice

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        let text: String = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeGuard()
            task = onDevice.recognitionTask(with: request) { result, error in
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        if resumed.claim() { continuation.resume(returning: text) }
                    } else {
                        partial(text)
                    }
                    return
                }
                guard let error = error as NSError?, resumed.claim() else { return }
                if error.domain == Self.noSpeechDomain, error.code == Self.noSpeechCode {
                    continuation.resume(returning: "")
                } else {
                    continuation.resume(throwing: error)
                }
            }

            Task {
                for await chunk in audio { request.append(chunk.buffer) }
                request.endAudio()
            }
        }

        task = nil
        recognizer = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One-shot latch: `SFSpeechRecognitionTask` can deliver a final result *and* an error, and
/// resuming a continuation twice is a crash.
private final class ResumeGuard {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
