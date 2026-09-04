import Foundation
import MurmurCore

/// Groq or OpenAI, through `murmur-core`.
///
/// Cloud STT is one request over the whole recording rather than a stream, so this engine
/// buffers the 16 kHz mono samples the capture path already produced and hands them over when
/// the microphone stops. There are no partial results to report.
public final class CloudSpeechEngine: SpeechEngine {
    private let cfg: MurmurCore.CloudConfig

    /// The key inside `cfg` came straight from the Keychain and goes straight into the core.
    /// It is never copied anywhere else, and never appears in an error.
    public init(cfg: MurmurCore.CloudConfig) {
        self.cfg = cfg
    }

    public func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        partial: @escaping (String) -> Void
    ) async throws -> String {
        var samples: [Float] = []
        for await chunk in audio {
            samples.append(contentsOf: chunk.samples16kMono)
        }
        do {
            return try await transcribeCloud(audio16kMono: samples, cfg: cfg, prompt: "")
        } catch let error as CoreError {
            throw PipelineError.cloud(error.message)
        }
    }
}

public extension CoreError {
    /// The user-facing sentence the core produced — the same wording the Mac app shows. The
    /// error case itself is an implementation detail; this is what goes on screen.
    var message: String {
        switch self {
        case let .Network(message), let .Rejected(message), let .Http(message), let .Empty(message):
            return message
        }
    }
}
