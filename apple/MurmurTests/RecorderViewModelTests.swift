import AVFoundation
import XCTest

import MurmurCore
import MurmurShared
@testable import Murmur

/// The recorder state machine, end to end, with no hardware and no waiting: the microphone,
/// the speech engine, the clock, the clipboard and every `sleep` are injected, so the 1.5 s
/// silence hangover, the 120 s cap and the 8 s auto-dismiss all resolve in milliseconds.
final class RecorderViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var secrets: InMemorySecretStore!
    private var history: HistoryStore!
    private var sleeper: FakeSleeper!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = SettingsStore(defaults: defaults)
        secrets = InMemorySecretStore()
        history = try HistoryStore.inMemory()
        sleeper = FakeSleeper()
    }

    override func tearDownWithError() throws {
        // Nothing may be left parked on a continuation after a test finishes.
        sleeper.drain()
        sleeper = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        settings = nil
        secrets = nil
        history = nil
        try super.tearDownWithError()
    }

    // MARK: - Fakes

    /// A microphone that yields a script and then stays open, exactly like the real one: the
    /// stream ends when — and only when — the recorder closes it.
    private final class FakeAudio: AudioSource {
        var chunks: [AudioChunk] = []
        var startError: Error?
        private(set) var starts = 0
        private(set) var stops = 0
        private var continuation: AsyncStream<AudioChunk>.Continuation?

        func start() throws -> AsyncStream<AudioChunk> {
            if let startError { throw startError }
            starts += 1
            let script = chunks
            return AsyncStream(bufferingPolicy: .unbounded) { continuation in
                self.continuation = continuation
                script.forEach { continuation.yield($0) }
            }
        }

        func stop() {
            stops += 1
            continuation?.finish()
            continuation = nil
        }
    }

    /// A speech engine that drains its audio, emits its partials, waits for its gate and then
    /// returns (or throws) whatever the test scripted. The gate is open unless a test wants to
    /// hold the engine inside the `.transcribing` phase long enough to look at it.
    private final class FakeEngine: SpeechEngine {
        private let outcome: Result<String, Error>
        private let partials: [String]
        private let gate: Gate
        private(set) var chunksSeen = 0

        init(_ text: String, partials: [String] = [], gate: Gate = Gate(open: true)) {
            outcome = .success(text)
            self.partials = partials
            self.gate = gate
        }

        init(failing error: Error) {
            outcome = .failure(error)
            partials = []
            gate = Gate(open: true)
        }

        func transcribe(
            _ audio: AsyncStream<AudioChunk>,
            partial: @escaping (String) -> Void
        ) async throws -> String {
            for await _ in audio { chunksSeen += 1 }
            partials.forEach(partial)
            await gate.wait()
            return try outcome.get()
        }
    }

    /// A `sleep` that never sleeps. Durations in `returns` complete at once; every other
    /// duration parks forever, which is how a test stops the 120 s cap or the 8 s
    /// auto-dismiss from firing while it looks at an earlier phase.
    private final class FakeSleeper {
        private let returns: Set<TimeInterval>
        private let gate = Gate(open: false)
        private let lock = NSLock()
        private var asked: [TimeInterval] = []

        init(returningFor returns: Set<TimeInterval> = []) {
            self.returns = returns
        }

        func sleep(_ duration: TimeInterval) async {
            lock.lock()
            asked.append(duration)
            lock.unlock()
            guard !returns.contains(duration) else { return }
            await gate.wait()
        }

        var requested: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return asked
        }

        /// Releases everything still parked, so no test leaves a suspended task behind.
        func drain() { gate.openUp() }
    }

    /// A clock that steps by a fixed amount every time it is read. The recorder reads it once
    /// when the microphone opens and once per chunk, so a script of N chunks lands on
    /// timestamps `step, 2·step, …` — which is what makes the silence hangover deterministic.
    private final class StepClock {
        private let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        private let step: TimeInterval
        private var reads = 0

        init(step: TimeInterval) { self.step = step }

        func now() -> Date {
            defer { reads += 1 }
            return base.addingTimeInterval(step * Double(reads))
        }
    }

    /// Somewhere an escaping closure can write that a test can read afterwards.
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - Audio scripts

    private func buffer(frames: Int = 160) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    private func chunks(levels: [Float]) -> [AudioChunk] {
        levels.map {
            AudioChunk(
                samples16kMono: Array(repeating: $0, count: 160),
                level: $0,
                buffer: buffer()
            )
        }
    }

    /// Loud enough to count as speech, forever.
    private func speech(_ count: Int = 6) -> [AudioChunk] {
        chunks(levels: Array(repeating: 0.5, count: count))
    }

    /// Two chunks of speech and then silence: with a 0.5 s clock step that is 1.5 s of
    /// quiet after 0.5 s of speech, i.e. exactly the detector's trigger.
    private func speechThenSilence() -> [AudioChunk] {
        chunks(levels: [0.5, 0.5, 0, 0, 0, 0])
    }

    // MARK: - Subject

    @MainActor
    private func makeModel(
        request: DictationRequest = DictationRequest(source: .inApp),
        audio: FakeAudio,
        engine: FakeEngine,
        clockStep: TimeInterval = 0.5,
        maxDuration: TimeInterval = 120,
        micStatus: @escaping () -> PermissionStatus = { .granted },
        requestMic: @escaping () async -> Bool = { true },
        copy: @escaping (String) -> Void = { _ in }
    ) -> RecorderViewModel {
        let pipeline = DictationPipeline(
            settings: settings,
            secrets: secrets,
            history: history,
            localEngine: { engine },
            cloudEngine: { _ in engine },
            clean: { raw, _ in CleanResult(raw: raw, clean: "Clean: \(raw)", usedCloud: false) }
        )
        let clock = StepClock(step: clockStep)
        return RecorderViewModel(
            request: request,
            pipeline: pipeline,
            audio: audio,
            settings: settings,
            clock: clock.now,
            maxDuration: maxDuration,
            micStatus: micStatus,
            requestMic: requestMic,
            copy: copy,
            defaults: defaults,
            sleeper: sleeper.sleep
        )
    }

    // MARK: - Waiting

    @MainActor
    private func wait(
        on model: RecorderViewModel,
        for what: String,
        timeout: TimeInterval = 5,
        until predicate: (RecorderViewModel.Phase) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(model.phase) { return }
            try? await Task.sleep(nanoseconds: 500_000)
        }
        XCTFail("timed out waiting for \(what); phase is \(Self.name(model.phase))", file: file, line: line)
    }

    /// The phase's name only — a failure message must not print a transcript.
    private static func name(_ phase: RecorderViewModel.Phase) -> String {
        switch phase {
        case .starting: return "starting"
        case let .recording(_, elapsed): return "recording(\(elapsed)s)"
        case .transcribing: return "transcribing"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private static func isRecording(_ phase: RecorderViewModel.Phase) -> Bool {
        if case .recording = phase { return true }
        return false
    }

    private static func isDone(_ phase: RecorderViewModel.Phase) -> Bool {
        if case .done = phase { return true }
        return false
    }

    // MARK: - Recording

    @MainActor
    func testStartsRecordingOnceTheMicrophoneIsOpen() async {
        let audio = FakeAudio()
        audio.chunks = speech()
        let model = makeModel(audio: audio, engine: FakeEngine("hello there"))

        let run = Task { await model.start() }
        await wait(on: model, for: "recording", until: Self.isRecording)

        XCTAssertEqual(audio.starts, 1)
        // The level meter is live: the script's chunks are at 0.5.
        if case let .recording(level, elapsed) = model.phase {
            XCTAssertEqual(level, 0.5, accuracy: 0.001)
            XCTAssertGreaterThan(elapsed, 0)
        } else {
            XCTFail("expected a recording phase")
        }

        model.stop()
        await run.value
    }

    @MainActor
    func testATapStopsTheRecordingAndFinishesTheDictation() async {
        let audio = FakeAudio()
        audio.chunks = speech()
        let model = makeModel(audio: audio, engine: FakeEngine("hello there"))

        let run = Task { await model.start() }
        await wait(on: model, for: "recording", until: Self.isRecording)
        model.stop()
        await run.value

        XCTAssertGreaterThanOrEqual(audio.stops, 1)
        XCTAssertEqual(model.phase, .done(clean: "Clean: hello there", copied: true))
    }

    @MainActor
    func testSilenceAutoStopsTheRecording() async {
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        let model = makeModel(audio: audio, engine: FakeEngine("hello there"))

        await model.start()

        XCTAssertGreaterThanOrEqual(audio.stops, 1, "the detector should have closed the microphone")
        XCTAssertEqual(model.phase, .done(clean: "Clean: hello there", copied: true))
        XCTAssertEqual(try? history.list().count, 1)
    }

    @MainActor
    func testSilenceIsIgnoredWhenAutoStopIsOff() async {
        settings.update { $0.autoStopOnSilence = false }
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        let model = makeModel(audio: audio, engine: FakeEngine("hello there"))

        let run = Task { await model.start() }
        // The last scripted chunk lands at 3.0 s; reaching it proves all six were seen and
        // none of them ended the recording.
        await wait(on: model, for: "the whole script", timeout: 2) { phase in
            if case let .recording(_, elapsed) = phase { return elapsed >= 3 }
            return false
        }
        XCTAssertEqual(audio.stops, 0)

        model.stop()
        await run.value
    }

    @MainActor
    func testTheDurationCapStopsTheRecording() async {
        // Only the 120 s cap returns from `sleep`; everything else parks.
        sleeper = FakeSleeper(returningFor: [120])
        let audio = FakeAudio()
        audio.chunks = speech()
        let model = makeModel(audio: audio, engine: FakeEngine("hello there"))

        await model.start()

        XCTAssertTrue(sleeper.requested.contains(120))
        XCTAssertGreaterThanOrEqual(audio.stops, 1)
        XCTAssertEqual(model.phase, .done(clean: "Clean: hello there", copied: true))
    }

    @MainActor
    func testTheCapIsAlsoEnforcedFromTheChunkTimestamps() async {
        // No sleeper help at all: the elapsed time carried by the chunks passes maxDuration.
        let audio = FakeAudio()
        audio.chunks = speech()
        let model = makeModel(audio: audio, engine: FakeEngine("hello there"), maxDuration: 1.2)

        await model.start()

        XCTAssertGreaterThanOrEqual(audio.stops, 1)
        XCTAssertTrue(Self.isDone(model.phase), "phase is \(Self.name(model.phase))")
    }

    // MARK: - Partials

    @MainActor
    func testPartialTextIsShownWhileTranscribing() async {
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        // The gate holds the engine inside `.transcribing` until this test has looked at it.
        let gate = Gate(open: false)
        let model = makeModel(
            audio: audio,
            engine: FakeEngine("hello there", partials: ["hel", "hello there"], gate: gate)
        )

        let run = Task { await model.start() }
        await wait(on: model, for: "transcribing with a partial") { phase in
            phase == .transcribing(partial: "hello there")
        }

        gate.openUp()
        await run.value
        XCTAssertTrue(Self.isDone(model.phase), "phase is \(Self.name(model.phase))")
    }

    // MARK: - Delivery

    @MainActor
    func testTheCleanTextGoesToTheClipboardWhenTheSettingIsOn() async {
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        let pasted = Box<[String]>([])
        let model = makeModel(
            audio: audio,
            engine: FakeEngine("hello there"),
            copy: { pasted.value.append($0) }
        )

        await model.start()

        XCTAssertEqual(pasted.value, ["Clean: hello there"])
        XCTAssertEqual(model.phase, .done(clean: "Clean: hello there", copied: true))
    }

    @MainActor
    func testNothingIsCopiedWhenTheSettingIsOff() async {
        settings.update { $0.copyToClipboard = false }
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        let pasted = Box<[String]>([])
        let model = makeModel(
            audio: audio,
            engine: FakeEngine("hello there"),
            copy: { pasted.value.append($0) }
        )

        await model.start()

        XCTAssertTrue(pasted.value.isEmpty)
        XCTAssertEqual(model.phase, .done(clean: "Clean: hello there", copied: false))
    }

    @MainActor
    func testAKeyboardRequestWritesTheHandoffResultForItsOwnSession() async {
        let session = UUID()
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        let model = makeModel(
            request: DictationRequest(session: session, source: .keyboard),
            audio: audio,
            engine: FakeEngine("hello there")
        )

        await model.start()

        XCTAssertTrue(model.showsSwipeBackHint)
        let result = Handoff.takeResult(for: session, defaults: defaults)
        XCTAssertEqual(result?.clean, "Clean: hello there")
        XCTAssertEqual(result?.raw, "hello there")
        XCTAssertEqual(result?.session, session)
        XCTAssertEqual(result?.inserted, false, "the keyboard is the one that marks it inserted")
        // The row itself carries the keyboard source.
        XCTAssertEqual(try? history.list().first?.source, .keyboard)
    }

    @MainActor
    func testAnInAppRequestWritesNoHandoffResult() async {
        // A result left over from an earlier round trip must survive an in-app dictation.
        let other = UUID()
        Handoff.writeResult(
            DictationResult(session: other, raw: "old", clean: "old", createdAt: Date(), inserted: false),
            defaults: defaults
        )

        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        let model = makeModel(audio: audio, engine: FakeEngine("hello there"))

        await model.start()

        XCTAssertFalse(model.showsSwipeBackHint)
        XCTAssertEqual(Handoff.takeResult(for: other, defaults: defaults)?.clean, "old")
        XCTAssertEqual(try? history.list().first?.source, .inApp)
    }

    // MARK: - Auto-dismiss

    @MainActor
    func testTheFinishedTextDismissesItselfAfterEightSeconds() async {
        sleeper = FakeSleeper(returningFor: [8])
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        let model = makeModel(audio: audio, engine: FakeEngine("hello there"))
        let dismissed = Box(false)
        model.onDismiss = { dismissed.value = true }

        await model.start()
        XCTAssertEqual(model.autoDismissAfter, 8)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !dismissed.value {
            try? await Task.sleep(nanoseconds: 500_000)
        }
        XCTAssertTrue(dismissed.value)
    }

    @MainActor
    func testAFailureDoesNotDismissItself() async {
        sleeper = FakeSleeper(returningFor: [8])
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        let model = makeModel(audio: audio, engine: FakeEngine(""))
        let dismissed = Box(false)
        model.onDismiss = { dismissed.value = true }

        await model.start()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(model.phase, .failed(message: "Didn't catch that."))
        XCTAssertFalse(dismissed.value, "the user has to read the message and choose")
    }

    // MARK: - Failures

    @MainActor
    func testAnEmptyTranscriptFailsAndWritesNothing() async {
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        let model = makeModel(audio: audio, engine: FakeEngine(""))

        await model.start()

        XCTAssertEqual(model.phase, .failed(message: "Didn't catch that."))
        XCTAssertFalse(model.failedNeedsSettings)
        XCTAssertEqual(try? history.list().count, 0)
    }

    @MainActor
    func testAMissingSpeechEngineExplainsTheAlternative() async {
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        let model = makeModel(audio: audio, engine: FakeEngine(failing: PipelineError.noSpeechEngine))

        await model.start()

        XCTAssertEqual(
            model.phase,
            .failed(message: "On-device speech isn't available. Pick Groq or OpenAI in Settings.")
        )
        XCTAssertFalse(model.failedNeedsSettings)
    }

    @MainActor
    func testACloudFailurePassesTheCoresSentenceThrough() async {
        settings.update { $0.stt = .groq }
        try? secrets.set(ProviderId.groq.keychainAccount, "gsk_live_test")
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        // Both engines are this one, so the local retry fails the same way.
        let model = makeModel(
            audio: audio,
            engine: FakeEngine(failing: PipelineError.cloud("Groq is unreachable."))
        )

        await model.start()

        XCTAssertEqual(model.phase, .failed(message: "Groq is unreachable."))
    }

    @MainActor
    func testADeniedMicrophoneSendsTheUserToSettings() async {
        let audio = FakeAudio()
        audio.chunks = speech()
        let model = makeModel(audio: audio, engine: FakeEngine("never runs"), micStatus: { .denied })

        await model.start()

        XCTAssertEqual(model.phase, .failed(message: "Murmur needs the microphone. Allow it in Settings."))
        XCTAssertTrue(model.failedNeedsSettings)
        XCTAssertEqual(audio.starts, 0, "nothing should be recorded without permission")
    }

    @MainActor
    func testAnUndeterminedMicrophoneIsRequestedAndThenUsed() async {
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        let asked = Box(false)
        let model = makeModel(
            audio: audio,
            engine: FakeEngine("hello there"),
            micStatus: { .notDetermined },
            requestMic: { asked.value = true; return true }
        )

        await model.start()

        XCTAssertTrue(asked.value)
        XCTAssertEqual(audio.starts, 1)
        XCTAssertEqual(model.phase, .done(clean: "Clean: hello there", copied: true))
    }

    @MainActor
    func testARefusedPromptIsTreatedAsDenied() async {
        let audio = FakeAudio()
        audio.chunks = speech()
        let model = makeModel(
            audio: audio,
            engine: FakeEngine("never runs"),
            micStatus: { .notDetermined },
            requestMic: { false }
        )

        await model.start()

        XCTAssertEqual(model.phase, .failed(message: "Murmur needs the microphone. Allow it in Settings."))
        XCTAssertTrue(model.failedNeedsSettings)
        XCTAssertEqual(audio.starts, 0)
    }

    @MainActor
    func testTryAgainRunsASecondDictation() async {
        let audio = FakeAudio()
        audio.chunks = speechThenSilence()
        let model = makeModel(audio: audio, engine: FakeEngine(""))

        await model.start()
        XCTAssertEqual(model.phase, .failed(message: "Didn't catch that."))

        // What the Try again button does. The microphone is re-opened from scratch.
        audio.chunks = speechThenSilence()
        await model.start()

        XCTAssertEqual(audio.starts, 2)
        XCTAssertEqual(model.phase, .failed(message: "Didn't catch that."))
    }
}

/// A latch the fake engine and the fake sleeper share: `wait()` parks until `openUp()`, and
/// nothing here ever actually sleeps.
private final class Gate {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open: Bool

    init(open: Bool) { self.open = open }

    func wait() async {
        lock.lock()
        if open {
            lock.unlock()
            return
        }
        lock.unlock()
        await withCheckedContinuation { continuation in
            lock.lock()
            if open {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func openUp() {
        lock.lock()
        open = true
        let waiting = waiters
        waiters = []
        lock.unlock()
        waiting.forEach { $0.resume() }
    }
}
