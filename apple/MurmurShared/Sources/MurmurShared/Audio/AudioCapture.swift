import Accelerate
import AVFoundation
import Foundation

/// One tap's worth of microphone audio, in the two shapes the app needs at once.
///
/// `samples16kMono` is what `murmur-core` uploads (16 kHz mono float, the format every cloud
/// STT endpoint wants); `buffer` is the untouched capture buffer the on-device engines want,
/// because `SpeechAnalyzer` and `SFSpeechRecognizer` each pick their own preferred format and
/// resample from the original rather than from our downmix. `level` is the RMS of the buffer,
/// 0...1, and drives the recording dot.
public struct AudioChunk {
    public var samples16kMono: [Float]
    /// RMS amplitude of this buffer, clamped to 0...1.
    public var level: Float
    /// The capture buffer in the input node's native format (a copy — see ``AudioCapture``).
    public var buffer: AVAudioPCMBuffer

    public init(samples16kMono: [Float], level: Float, buffer: AVAudioPCMBuffer) {
        self.samples16kMono = samples16kMono
        self.level = level
        self.buffer = buffer
    }
}

/// Anything that can hand the recorder a stream of microphone chunks. Exists so the recorder
/// view model and the pipeline tests can run without a microphone.
public protocol AudioSource {
    func start() throws -> AsyncStream<AudioChunk>
    func stop()
}

/// What can go wrong before a single sample is captured. Nothing here carries audio.
public enum AudioCaptureError: Error, Equatable {
    /// The input node reported a zero sample rate or no channels — usually no input route.
    case invalidInputFormat
    /// `AVAudioConverter` refused the input → 16 kHz mono conversion.
    case converterUnavailable
}

/// The microphone. One `AVAudioEngine` tap feeds every engine: the local ones consume
/// ``AudioChunk/buffer``, the cloud one accumulates ``AudioChunk/samples16kMono``, and the
/// recorder's level meter reads ``AudioChunk/level`` — so a dictation is captured once no
/// matter which engine ends up transcribing it.
public final class AudioCapture: AudioSource {
    /// What `murmur-core` expects: 16 kHz mono float32, deinterleaved.
    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let engine = AVAudioEngine()

    /// Guards everything the audio thread touches. The tap block runs on a realtime thread
    /// while `start`/`stop` run on the caller's, so the continuation and the converter are
    /// only ever read or written under it.
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var converter: AVAudioConverter?
    private var running = false

    public init() {}

    /// Configures the session, taps the input node, and returns the chunk stream.
    ///
    /// The stream is unbounded: dropping buffers would silently drop words, and a dictation
    /// is capped at 120 s upstream, so the backlog is bounded by that instead.
    public func start() throws -> AsyncStream<AudioChunk> {
        stop()

        // `.measurement` turns off the processing that colours the signal (AGC, EQ); ducking
        // means music keeps playing quietly instead of stopping dead.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }
        // Created once for the whole session: a sample-rate converter carries filter state
        // between calls, and rebuilding it per buffer would click at every seam.
        guard let converter = AVAudioConverter(from: format, to: Self.targetFormat) else {
            throw AudioCaptureError.converterUnavailable
        }

        var made: AsyncStream<AudioChunk>.Continuation!
        let stream = AsyncStream<AudioChunk>(bufferingPolicy: .unbounded) { made = $0 }

        lock.lock()
        continuation = made
        self.converter = converter
        running = true
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
        return stream
    }

    /// Tears the session down and finishes the stream. Safe to call twice, and safe to call
    /// when `start` threw half-way — the recorder does exactly that.
    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        let continuation = self.continuation
        self.continuation = nil
        converter = nil
        lock.unlock()

        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        // Tells whatever we ducked that it can come back up.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Runs on the audio thread: no allocation-heavy work, no logging, no `self` retained.
    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let continuation = self.continuation
        let converter = self.converter
        lock.unlock()
        guard let continuation, let converter else { return }

        let level = AudioMath.rms(buffer)
        // The tap may reuse its buffer once this block returns, and the local engines read it
        // asynchronously well after that, so the chunk gets its own copy.
        guard let owned = AudioMath.copy(buffer) else { return }
        let converted = AudioMath.convert(owned, with: converter, to: Self.targetFormat)
        continuation.yield(
            AudioChunk(samples16kMono: AudioMath.floats(converted), level: level, buffer: owned)
        )
    }
}

/// Buffer arithmetic shared by the capture path and the on-device engines.
enum AudioMath {
    /// RMS of the first channel, clamped to 0...1 for the level meter.
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(data[0], 1, &meanSquare, vDSP_Length(buffer.frameLength))
        return min(1, sqrt(meanSquare))
    }

    /// A private copy of `buffer`, format and all.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength

        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(source.count, destination.count) {
            var slot = destination[i]
            slot.mDataByteSize = source[i].mDataByteSize
            destination[i] = slot
            if let from = source[i].mData, let to = destination[i].mData {
                memcpy(to, from, Int(source[i].mDataByteSize))
            }
        }
        return copy
    }

    /// Pushes one buffer through `converter`. Returns `nil` rather than throwing: a dropped
    /// buffer costs a few milliseconds of audio, a thrown error would cost the dictation.
    static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        // Slack on top of the ratio: a resampler can emit a frame or two more than the
        // arithmetic suggests as its filter tail drains.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// First channel of `buffer` as plain floats.
    static func floats(_ buffer: AVAudioPCMBuffer?) -> [Float] {
        guard let buffer, let data = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    /// Wraps 16 kHz mono samples back up as a buffer — the replay path in the pipeline.
    static func buffer16kMono(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: AudioCapture.targetFormat,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}
