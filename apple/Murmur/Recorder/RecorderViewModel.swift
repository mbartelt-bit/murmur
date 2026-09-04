import AVFoundation
import Combine
import Foundation
import MurmurShared
import UIKit

/// Drives one dictation from the moment the recorder appears to the moment its text is on the
/// clipboard and in the App Group.
///
/// The state machine is the testable half of the recorder: every collaborator that needs a
/// microphone, a clock, a pasteboard or a real sleep is injected, so the whole of it —
/// auto-stop, the 120 s cap, the 8 s auto-dismiss, the handoff write — runs in milliseconds
/// under XCTest with no hardware and no waiting.
///
/// Nothing here logs. Partial and final transcripts pass through this object and are never
/// printed; the API keys never reach it at all (the pipeline reads them straight from the
/// Keychain into the core call).
@MainActor
final class RecorderViewModel: ObservableObject {
    /// The five things the screen can be showing. `Equatable` so tests can wait for one.
    enum Phase: Equatable {
        /// Permission checked, microphone opening.
        case starting
        /// Live. `level` is the current RMS 0...1, `elapsed` seconds since the first sample.
        case recording(level: Float, elapsed: TimeInterval)
        /// Microphone closed, the engine still working. `partial` is what it has so far.
        case transcribing(partial: String)
        /// Finished. The text is in history; `copied` says whether it also reached the clipboard.
        case done(clean: String, copied: Bool)
        case failed(message: String)
    }

    @Published var phase: Phase = .starting

    /// `true` when the failure is a denied permission, i.e. when the only way forward is the
    /// Settings app rather than trying again.
    private(set) var failedNeedsSettings = false

    /// Set by the view. Called when the finished text has been on screen for
    /// ``autoDismissAfter`` seconds — never on a failure, where the user needs to read the
    /// message and choose.
    var onDismiss: (() -> Void)?

    let request: DictationRequest

    private let pipeline: DictationPipeline
    private let audio: AudioSource
    private let settings: SettingsStore
    private let clock: () -> Date
    private let maxDuration: TimeInterval
    private let micStatus: () -> PermissionStatus
    private let requestMic: () async -> Bool
    private let copy: (String) -> Void
    private let defaults: UserDefaults
    private let sleeper: (TimeInterval) async -> Void

    private var startedAt = Date()
    private var silence = SilenceDetector()
    private var lastPartial = ""
    /// Elapsed time of the last published level, for the ~20 Hz coalescing below.
    private var lastPublish = -Double.infinity
    private var isRecording = false
    private var isBusy = false
    private var capTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    /// Level updates faster than this are dropped: the tap delivers a buffer every ~85 ms
    /// already, and a `@Published` write per buffer is a whole SwiftUI pass.
    private static let publishInterval: TimeInterval = 0.05

    init(
        request: DictationRequest,
        pipeline: DictationPipeline,
        audio: AudioSource = AudioCapture(),
        settings: SettingsStore,
        clock: @escaping () -> Date = Date.init,
        maxDuration: TimeInterval = 120,
        micStatus: @escaping () -> PermissionStatus = Permissions.micStatus,
        requestMic: @escaping () async -> Bool = Permissions.requestMic,
        copy: @escaping (String) -> Void = { UIPasteboard.general.string = $0 },
        defaults: UserDefaults = AppGroup.defaults,
        sleeper: @escaping (TimeInterval) async -> Void = RecorderViewModel.liveSleep
    ) {
        self.request = request
        self.pipeline = pipeline
        self.audio = audio
        self.settings = settings
        self.clock = clock
        self.maxDuration = maxDuration
        self.micStatus = micStatus
        self.requestMic = requestMic
        self.copy = copy
        self.defaults = defaults
        self.sleeper = sleeper
    }

    /// `true` only when the keyboard sent the user here, because only then is there a host app
    /// to swipe back to.
    ///
    /// A session id alone is not enough: an Action Button, Shortcut or Control Center dictation
    /// also carries one (``Handoff/intentSession``, so a Murmur keyboard can still pick the text
    /// up on its next appearance) but the user came from the Home Screen, the Lock Screen or
    /// Siri, and telling them to swipe back would point at nothing.
    var showsSwipeBackHint: Bool { request.session != nil && request.source == .keyboard }

    /// How long the finished text stays on screen before the sheet closes itself.
    var autoDismissAfter: TimeInterval { 8 }

    // MARK: - Running

    /// The whole dictation: permission, microphone, pipeline, delivery. Returns when the
    /// screen has reached `.done` or `.failed`; safe to call again after a failure, which is
    /// what the Try again button does.
    func start() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        capTask?.cancel()
        capTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        silence = SilenceDetector()
        lastPartial = ""
        lastPublish = -.infinity
        failedNeedsSettings = false
        phase = .starting

        // 1. Microphone. Onboarding normally asks first, so `notDetermined` here means the
        //    user arrived from the keyboard or a shortcut before finishing onboarding.
        var status = micStatus()
        if status == .notDetermined {
            status = await requestMic() ? .granted : .denied
        }
        guard status == .granted else {
            fail("Murmur needs the microphone. Allow it in Settings.", needsSettings: true)
            return
        }

        // 2. Microphone open.
        let source: AsyncStream<AudioChunk>
        do {
            source = try audio.start()
        } catch {
            fail(error.localizedDescription, needsSettings: false)
            return
        }

        startedAt = clock()
        isRecording = true
        phase = .recording(level: 0, elapsed: 0)

        // 3. The hard cap, so a pocket-dialled dictation cannot record forever. Cancelled the
        //    moment anything else stops the recording.
        let sleeper = self.sleeper
        let cap = maxDuration
        capTask = Task { [weak self] in
            await sleeper(cap)
            guard !Task.isCancelled else { return }
            self?.stop()
        }

        // 4. One capture, two consumers: the pipeline eats `forwarded` while every chunk also
        //    updates the level meter and feeds the silence detector on the way past. Teeing
        //    here rather than in `AudioCapture` keeps the capture class ignorant of the UI.
        let forwarded = AsyncStream<AudioChunk>(bufferingPolicy: .unbounded) { continuation in
            Task { [weak self] in
                for await chunk in source {
                    continuation.yield(chunk)
                    await self?.observe(chunk)
                }
                continuation.finish()
                // The source ended on its own (a capture failure, or a scripted test stream):
                // wind the screen down the same way a tap would.
                await self?.stop()
            }
        }

        // 5. Transcribe, clean, write history — all inside the pipeline, which returns only
        //    once the row exists.
        do {
            let outcome = try await pipeline.run(audio: forwarded, source: request.source) { [weak self] text in
                Task { @MainActor in self?.note(partial: text) }
            }
            capTask?.cancel()
            capTask = nil
            deliver(outcome)
        } catch {
            capTask?.cancel()
            capTask = nil
            let (message, needsSettings) = Self.describe(error)
            fail(message, needsSettings: needsSettings)
        }
    }

    /// Ends the recording: the user tapped, the silence detector fired, or the cap ran out.
    /// Idempotent, and a no-op once the dictation has left the recording phase — the view
    /// calls it again from `onDisappear`.
    func stop() {
        capTask?.cancel()
        capTask = nil
        guard isRecording else { return }
        isRecording = false
        // Closing the microphone finishes the chunk stream, which is what tells the engine
        // inside the pipeline that there is no more audio coming.
        audio.stop()
        phase = .transcribing(partial: lastPartial)
    }

    // MARK: - Per-chunk

    /// One buffer's worth of level, on its way to the pipeline.
    private func observe(_ chunk: AudioChunk) {
        guard isRecording else { return }
        let elapsed = clock().timeIntervalSince(startedAt)

        if settings.settings.autoStopOnSilence, silence.feed(level: chunk.level, at: elapsed) {
            stop()
            return
        }
        if elapsed >= maxDuration {
            stop()
            return
        }
        guard elapsed - lastPublish >= Self.publishInterval else { return }
        lastPublish = elapsed
        phase = .recording(level: chunk.level, elapsed: elapsed)
    }

    /// A volatile result from the engine. It is only shown once the microphone is closed —
    /// while recording the screen belongs to the dot, as on the Mac.
    private func note(partial text: String) {
        lastPartial = text
        if case .transcribing = phase {
            phase = .transcribing(partial: text)
        }
    }

    // MARK: - Delivery

    /// History was already written by the pipeline. This is everything after it: clipboard,
    /// handoff, screen.
    private func deliver(_ outcome: PipelineOutcome) {
        let clean = outcome.transcript.cleanText

        var copied = false
        if settings.settings.copyToClipboard {
            copy(clean)
            copied = true
        }

        // Only a keyboard-initiated dictation has somebody waiting for the text.
        if let session = request.session {
            Handoff.writeResult(
                DictationResult(
                    session: session,
                    raw: outcome.transcript.rawText,
                    clean: clean,
                    createdAt: outcome.transcript.createdAt,
                    inserted: false
                ),
                defaults: defaults
            )
        }

        phase = .done(clean: clean, copied: copied)

        let sleeper = self.sleeper
        let delay = autoDismissAfter
        dismissTask = Task { [weak self] in
            await sleeper(delay)
            guard !Task.isCancelled else { return }
            self?.onDismiss?()
        }
    }

    private func fail(_ message: String, needsSettings: Bool) {
        isRecording = false
        audio.stop()
        failedNeedsSettings = needsSettings
        phase = .failed(message: message)
    }

    /// The recorder's own words for a pipeline failure. `cloud` already carries the core's
    /// user-facing sentence, so it is passed through untouched.
    private static func describe(_ error: Error) -> (message: String, needsSettings: Bool) {
        guard let error = error as? PipelineError else {
            return (error.localizedDescription, false)
        }
        switch error {
        case .empty:
            return ("Didn't catch that.", false)
        case let .cloud(message):
            return (message, false)
        case .noSpeechEngine:
            return ("On-device speech isn't available. Pick Groq or OpenAI in Settings.", false)
        case .micDenied:
            return ("Murmur needs the microphone. Allow it in Settings.", true)
        case .speechDenied:
            return ("Murmur needs speech recognition. Allow it in Settings.", true)
        }
    }

    /// The default for `sleeper`. Tests replace it so the cap and the auto-dismiss fire at
    /// once instead of two minutes from now.
    static func liveSleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
