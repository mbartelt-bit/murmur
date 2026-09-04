import AVFoundation
import Foundation
import Speech

/// The iOS 26 on-device engine: `SpeechAnalyzer` driving a `SpeechTranscriber`.
///
/// It is faster and markedly more accurate than `SFSpeechRecognizer`, has no 60-second
/// ceiling, and shares its language models with system Dictation, so most phones already
/// have the assets. Everything stays on the device.
@available(iOS 26, *)
public final class AnalyzerSpeechEngine: SpeechEngine {
    private let locale: Locale?

    /// Resolves the user's language at transcription time.
    public init() {
        locale = nil
    }

    /// Uses a locale the caller has already resolved (and knows is installed).
    init(locale: Locale) {
        self.locale = locale
    }

    /// The transcriber configuration used everywhere, including by the asset installer, so
    /// the model that gets downloaded is the model that gets used.
    ///
    /// `volatileResults` is what produces the live partial text; no attributes are requested
    /// because nothing in the app reads timing or confidence.
    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    public func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        partial: @escaping (String) -> Void
    ) async throws -> String {
        var locale = self.locale
        if locale == nil {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        }
        // en-US is the model every device ships with, and a wrong-language transcript beats
        // no transcript at all.
        let transcriber = Self.makeTranscriber(locale: locale ?? Locale(identifier: "en-US"))
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // The analyzer names the format it wants; feeding it anything else yields no results
        // and no error, so the conversion below is not optional.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw PipelineError.noSpeechEngine
        }

        let (input, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)

        // Started before the analyzer so no early result can be missed.
        let collector = Task<String, Error> {
            var settled = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    settled += text
                    partial(settled)
                } else {
                    // Volatile results only cover the unfinalized tail, so the settled prefix
                    // is prepended — otherwise the live text would jump backwards every time
                    // the transcriber finalizes a phrase.
                    partial(settled + text)
                }
            }
            return settled
        }

        do {
            try await analyzer.start(inputSequence: input)
        } catch {
            collector.cancel()
            inputContinuation.finish()
            throw error
        }

        var converter: AVAudioConverter?
        for await chunk in audio {
            let source = chunk.buffer.format
            if converter == nil {
                // One converter for the session: it carries resampler state between buffers.
                converter = AVAudioConverter(from: source, to: format)
            }
            guard let converter,
                  let converted = AudioMath.convert(chunk.buffer, with: converter, to: format)
            else { continue }
            inputContinuation.yield(AnalyzerInput(buffer: converted))
        }
        inputContinuation.finish()

        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
