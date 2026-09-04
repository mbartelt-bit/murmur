import AVFoundation
import XCTest

import MurmurCore
import MurmurShared
@testable import Murmur

/// The pipeline decides which engine runs, what happens when one fails, and whether a
/// transcript survives. Every engine here is a fake: nothing in this file touches the
/// microphone, Apple's speech services, or the network.
final class DictationPipelineTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var secrets: InMemorySecretStore!
    private var history: HistoryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = SettingsStore(defaults: defaults)
        secrets = InMemorySecretStore()
        history = try HistoryStore.inMemory()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        settings = nil
        secrets = nil
        history = nil
        try super.tearDownWithError()
    }

    // MARK: - Fakes

    /// A speech engine that drains its audio and then returns (or throws) whatever the test
    /// told it to.
    private final class FakeEngine: SpeechEngine {
        private let outcome: Result<String, Error>
        private let partials: [String]
        private(set) var calls = 0
        private(set) var chunksSeen = 0
        private(set) var samplesSeen = 0

        init(_ text: String, partials: [String] = []) {
            outcome = .success(text)
            self.partials = partials
        }

        init(failing error: Error) {
            outcome = .failure(error)
            partials = []
        }

        func transcribe(
            _ audio: AsyncStream<AudioChunk>,
            partial: @escaping (String) -> Void
        ) async throws -> String {
            calls += 1
            for await chunk in audio {
                chunksSeen += 1
                samplesSeen += chunk.samples16kMono.count
            }
            partials.forEach(partial)
            return try outcome.get()
        }
    }

    /// Records what the pipeline asked the cleanup pass for.
    private final class CleanSpy {
        private(set) var configs: [CloudConfig?] = []
        private(set) var raws: [String] = []
        var result: (String) -> CleanResult = { raw in
            CleanResult(raw: raw, clean: "Clean: \(raw)", usedCloud: false)
        }

        func clean(_ raw: String, _ cfg: CloudConfig?) async -> CleanResult {
            raws.append(raw)
            configs.append(cfg)
            return result(raw)
        }
    }

    /// Hands out one cloud engine and remembers the config it was built with — i.e. the key.
    private final class CloudSpy {
        private(set) var configs: [CloudConfig] = []
        let engine: FakeEngine

        init(_ engine: FakeEngine) { self.engine = engine }

        func make(_ cfg: CloudConfig) -> SpeechEngine {
            configs.append(cfg)
            return engine
        }
    }

    // MARK: - Audio

    /// A 16 kHz mono buffer of `frames` silent samples — enough for a chunk to be a chunk.
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

    /// A finished stream of `count` scripted chunks.
    private func audio(chunks count: Int = 3) -> AsyncStream<AudioChunk> {
        let chunks = (0..<count).map { i in
            AudioChunk(
                samples16kMono: Array(repeating: Float(i) / 10, count: 160),
                level: Float(i) / 10,
                buffer: buffer()
            )
        }
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            chunks.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    private func makePipeline(
        local: SpeechEngine,
        cloud: @escaping (CloudConfig) -> SpeechEngine = { _ in XCTFail("cloud engine not expected"); return FakeEngine("") },
        clean: @escaping (String, CloudConfig?) async -> CleanResult
    ) -> DictationPipeline {
        DictationPipeline(
            settings: settings,
            secrets: secrets,
            history: history,
            localEngine: { local },
            cloudEngine: cloud,
            clean: clean
        )
    }

    // MARK: - Local path

    func testLocalPathWritesHistoryWithTheInAppSource() async throws {
        let local = FakeEngine("um hello there")
        let spy = CleanSpy()
        let pipeline = makePipeline(local: local, clean: spy.clean)

        let outcome = try await pipeline.run(audio: audio(), source: .inApp, partial: { _ in })

        XCTAssertEqual(local.calls, 1)
        XCTAssertEqual(local.chunksSeen, 3)
        XCTAssertFalse(outcome.usedCloudStt)
        XCTAssertEqual(outcome.transcript.rawText, "um hello there")
        XCTAssertEqual(outcome.transcript.cleanText, "Clean: um hello there")
        XCTAssertEqual(outcome.transcript.source, .inApp)
        XCTAssertNotNil(outcome.transcript.id)

        // The row is in the store, not just in the returned value. (SQLite keeps dates to
        // the millisecond, so the timestamp is compared with a tolerance, not for equality.)
        let stored = try XCTUnwrap(history.list().first)
        XCTAssertEqual(try history.list().count, 1)
        XCTAssertEqual(stored.id, outcome.transcript.id)
        XCTAssertEqual(stored.rawText, "um hello there")
        XCTAssertEqual(stored.cleanText, "Clean: um hello there")
        XCTAssertEqual(stored.source, .inApp)
        XCTAssertEqual(
            stored.createdAt.timeIntervalSinceReferenceDate,
            outcome.transcript.createdAt.timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
    }

    func testSourceIsRecordedAsGiven() async throws {
        let pipeline = makePipeline(local: FakeEngine("hi"), clean: CleanSpy().clean)
        let outcome = try await pipeline.run(audio: audio(), source: .keyboard, partial: { _ in })
        XCTAssertEqual(outcome.transcript.source, .keyboard)
        XCTAssertEqual(try history.list().first?.source, .keyboard)
    }

    func testPartialsReachTheCaller() async throws {
        let local = FakeEngine("hello there", partials: ["hel", "hello", "hello there"])
        let pipeline = makePipeline(local: local, clean: CleanSpy().clean)

        let seen = Box<[String]>([])
        _ = try await pipeline.run(audio: audio(), source: .inApp, partial: { seen.value.append($0) })

        XCTAssertEqual(seen.value, ["hel", "hello", "hello there"])
    }

    func testRawTextIsTrimmedBeforeItIsStored() async throws {
        let spy = CleanSpy()
        let pipeline = makePipeline(local: FakeEngine("  hello there\n"), clean: spy.clean)
        let outcome = try await pipeline.run(audio: audio(), source: .inApp, partial: { _ in })
        XCTAssertEqual(outcome.transcript.rawText, "hello there")
        XCTAssertEqual(spy.raws, ["hello there"])
    }

    // MARK: - Cloud path

    func testCloudPathBuildsTheConfigFromTheStoredKey() async throws {
        settings.update { $0.stt = .groq }
        // Stored with the stray whitespace a paste tends to bring along.
        try secrets.set(ProviderId.groq.keychainAccount, "  gsk_live_test\n")

        let local = FakeEngine("local should not run")
        let cloudSpy = CloudSpy(FakeEngine("cloud heard this"))
        let pipeline = makePipeline(local: local, cloud: cloudSpy.make, clean: CleanSpy().clean)

        let outcome = try await pipeline.run(audio: audio(), source: .inApp, partial: { _ in })

        XCTAssertEqual(cloudSpy.configs.count, 1)
        XCTAssertEqual(cloudSpy.configs.first?.provider, .groq)
        XCTAssertEqual(cloudSpy.configs.first?.apiKey, "gsk_live_test")
        XCTAssertEqual(local.calls, 0)
        XCTAssertTrue(outcome.usedCloudStt)
        XCTAssertEqual(outcome.transcript.rawText, "cloud heard this")
        XCTAssertEqual(cloudSpy.engine.chunksSeen, 3)
    }

    func testOpenAiSttUsesItsOwnKeychainAccount() async throws {
        settings.update { $0.stt = .openai }
        try secrets.set(ProviderId.groq.keychainAccount, "gsk_wrong")
        try secrets.set(ProviderId.openai.keychainAccount, "sk_right")

        let cloudSpy = CloudSpy(FakeEngine("heard"))
        let pipeline = makePipeline(local: FakeEngine("local"), cloud: cloudSpy.make, clean: CleanSpy().clean)
        _ = try await pipeline.run(audio: audio(), source: .inApp, partial: { _ in })

        XCTAssertEqual(cloudSpy.configs.first?.provider, .openAi)
        XCTAssertEqual(cloudSpy.configs.first?.apiKey, "sk_right")
    }

    func testMissingKeyFallsBackToLocalWithoutTouchingTheCloud() async throws {
        settings.update { $0.stt = .groq }

        let local = FakeEngine("local heard this")
        let pipeline = makePipeline(
            local: local,
            cloud: { _ in XCTFail("no key, so no cloud engine"); return FakeEngine("") },
            clean: CleanSpy().clean
        )

        let outcome = try await pipeline.run(audio: audio(), source: .inApp, partial: { _ in })

        XCTAssertEqual(local.calls, 1)
        XCTAssertFalse(outcome.usedCloudStt)
        XCTAssertEqual(outcome.transcript.rawText, "local heard this")
    }

    func testABlankKeyCountsAsMissing() async throws {
        settings.update { $0.stt = .groq }
        try secrets.set(ProviderId.groq.keychainAccount, "   ")

        let local = FakeEngine("local heard this")
        let pipeline = makePipeline(
            local: local,
            cloud: { _ in XCTFail("a blank key is not a key"); return FakeEngine("") },
            clean: CleanSpy().clean
        )

        let outcome = try await pipeline.run(audio: audio(), source: .inApp, partial: { _ in })
        XCTAssertFalse(outcome.usedCloudStt)
        XCTAssertEqual(local.calls, 1)
    }

    func testCloudFailureRetriesOnDeviceWithTheSameAudio() async throws {
        settings.update { $0.stt = .groq }
        try secrets.set(ProviderId.groq.keychainAccount, "gsk_live_test")

        let local = FakeEngine("local rescued it")
        let cloudSpy = CloudSpy(FakeEngine(failing: PipelineError.cloud("Groq is unreachable.")))
        let pipeline = makePipeline(local: local, cloud: cloudSpy.make, clean: CleanSpy().clean)

        let outcome = try await pipeline.run(audio: audio(), source: .inApp, partial: { _ in })

        XCTAssertEqual(local.calls, 1)
        XCTAssertFalse(outcome.usedCloudStt)
        XCTAssertEqual(outcome.transcript.rawText, "local rescued it")
        // The retry gets the recording back, not an empty stream — the whole point of the tape.
        XCTAssertEqual(local.chunksSeen, 3)
        XCTAssertEqual(local.samplesSeen, 480)
    }

    func testLocalFailureAfterACloudFailureThrows() async throws {
        settings.update { $0.stt = .groq }
        try secrets.set(ProviderId.groq.keychainAccount, "gsk_live_test")

        let cloudSpy = CloudSpy(FakeEngine(failing: PipelineError.cloud("offline")))
        let pipeline = makePipeline(
            local: FakeEngine(failing: PipelineError.noSpeechEngine),
            cloud: cloudSpy.make,
            clean: CleanSpy().clean
        )

        await assertThrows(.noSpeechEngine) {
            _ = try await pipeline.run(audio: self.audio(), source: .inApp, partial: { _ in })
        }
        XCTAssertEqual(try history.list(), [])
    }

    // MARK: - Empty transcripts

    func testEmptyTranscriptThrowsAndWritesNothing() async throws {
        let spy = CleanSpy()
        let pipeline = makePipeline(local: FakeEngine(""), clean: spy.clean)

        await assertThrows(.empty) {
            _ = try await pipeline.run(audio: self.audio(), source: .inApp, partial: { _ in })
        }
        XCTAssertEqual(try history.list(), [])
        XCTAssertTrue(spy.raws.isEmpty, "cleanup should not run on nothing")
    }

    func testWhitespaceOnlyTranscriptIsAlsoEmpty() async throws {
        let pipeline = makePipeline(local: FakeEngine("  \n\t "), clean: CleanSpy().clean)
        await assertThrows(.empty) {
            _ = try await pipeline.run(audio: self.audio(), source: .inApp, partial: { _ in })
        }
        XCTAssertEqual(try history.list(), [])
    }

    // MARK: - Cleanup

    func testRuleCleanupGetsNoConfigEvenWhenKeysExist() async throws {
        try secrets.set(ProviderId.groq.keychainAccount, "gsk_live_test")
        try secrets.set(ProviderId.openai.keychainAccount, "sk_live_test")
        let spy = CleanSpy()
        let pipeline = makePipeline(local: FakeEngine("hello"), clean: spy.clean)

        let outcome = try await pipeline.run(audio: audio(), source: .inApp, partial: { _ in })

        XCTAssertEqual(spy.configs.count, 1)
        XCTAssertNil(spy.configs.first ?? nil)
        XCTAssertFalse(outcome.usedCloudCleanup)
    }

    func testCloudCleanupGetsTheConfigForItsOwnProvider() async throws {
        settings.update { $0.cleanup = .openai }
        try secrets.set(ProviderId.groq.keychainAccount, "gsk_live_test")
        try secrets.set(ProviderId.openai.keychainAccount, "sk_live_test")

        let spy = CleanSpy()
        spy.result = { CleanResult(raw: $0, clean: "Hello.", usedCloud: true) }
        let pipeline = makePipeline(local: FakeEngine("hello"), clean: spy.clean)

        let outcome = try await pipeline.run(audio: audio(), source: .inApp, partial: { _ in })

        let cfg = try XCTUnwrap(spy.configs.first ?? nil)
        XCTAssertEqual(cfg.provider, .openAi)
        XCTAssertEqual(cfg.apiKey, "sk_live_test")
        XCTAssertTrue(outcome.usedCloudCleanup)
        XCTAssertEqual(outcome.transcript.cleanText, "Hello.")
    }

    func testCloudCleanupWithNoKeyFallsBackToRules() async throws {
        settings.update { $0.cleanup = .groq }
        let spy = CleanSpy()
        let pipeline = makePipeline(local: FakeEngine("hello"), clean: spy.clean)

        _ = try await pipeline.run(audio: audio(), source: .inApp, partial: { _ in })

        XCTAssertNil(spy.configs.first ?? nil, "no key means the core's rules pass, not a failure")
    }

    func testAnEmptyCleanupResultKeepsTheRawWords() async throws {
        let spy = CleanSpy()
        spy.result = { _ in CleanResult(raw: "hello", clean: "   ", usedCloud: true) }
        let pipeline = makePipeline(local: FakeEngine("hello"), clean: spy.clean)

        let outcome = try await pipeline.run(audio: audio(), source: .inApp, partial: { _ in })
        XCTAssertEqual(outcome.transcript.cleanText, "hello")
    }

    // MARK: - Helpers

    private func assertThrows(
        _ expected: PipelineError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PipelineError, expected, file: file, line: line)
        }
    }
}

/// Somewhere for an escaping closure to write that a test can read afterwards.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
