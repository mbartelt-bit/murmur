import AVFoundation
import Foundation

/// The crash log for audio: while a dictation records, its 16 kHz mono samples are appended
/// to a file in the App Group every couple of seconds, and a dictation that ends — however it
/// ends — deletes that file. So a file still on disk at the next launch means exactly one
/// thing: Murmur was killed with the microphone open, and those samples are words the user
/// already said (design spec §9, "App killed mid-recording").
///
/// There is no sidecar and no index — the file *is* the journal. Its name carries a fresh
/// UUID so two recordings can never collide, its modification date says when the last sample
/// landed, and its length says how much audio it holds; the three questions Home has to
/// answer ("is one pending, how old, how long") are all answered by the directory listing.
///
/// Nothing but audio is ever written here: no transcript, no partial, no engine choice. The
/// worst a leftover file can leak is the recording the user was already making, and it lives
/// for one relaunch.
public final class RecordingJournal: @unchecked Sendable {
    /// How much audio buffers before it reaches the disk. Two seconds is the spec's number:
    /// one ~128 KB write per two seconds, and a crash can never cost more than that.
    public static let flushInterval: TimeInterval = 2

    /// How long a file must sit untouched before it counts as abandoned rather than live. A
    /// running recorder rewrites its file every ``flushInterval``, so five quiet seconds mean
    /// the process that owned it is gone.
    public static let staleAfter: TimeInterval = 5

    /// Shorter than this is a stray tap, not a dictation worth offering back.
    public static let minimumDuration: TimeInterval = 0.5

    /// What ``AudioCapture/targetFormat`` produces, and the only rate this file format has.
    public static let sampleRate = 16_000
    /// Float32.
    public static let bytesPerSample = 4

    private static let prefix = "recording-"
    private static let ext = "f32"

    /// Samples that must accumulate before ``append(_:)`` writes: 2 s × 16 kHz.
    public static var flushThreshold: Int { Int(flushInterval * Double(sampleRate)) }

    /// This recording's file. It does not exist until the first flush — a dictation that is
    /// stopped inside two seconds leaves nothing behind at all.
    public let url: URL

    private let clock: () -> Date
    private let lock = NSLock()
    private var buffered: [Float] = []
    /// Once discarded, this journal is inert: a chunk still in flight on the capture task
    /// cannot resurrect the file the delivery path just deleted.
    private var discarded = false

    /// `<App Group container>/journal`, created on demand.
    ///
    /// Inside the group container rather than `NSTemporaryDirectory()` so iOS cannot reclaim
    /// it between the crash and the relaunch, which is the one moment the file has a job.
    public static func defaultDirectory() -> URL {
        let directory = AppGroup.containerURL.appendingPathComponent("journal", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `clock` stamps each flush's modification date, so ``pending(in:now:)`` and the tests
    /// agree on what "five seconds ago" means without waiting five seconds.
    public init(directory: URL = defaultDirectory(), clock: @escaping () -> Date = Date.init) {
        url = directory.appendingPathComponent("\(Self.prefix)\(UUID().uuidString).\(Self.ext)")
        self.clock = clock
    }

    // MARK: - Writing

    /// One chunk of captured audio. Buffers in memory and writes once ``flushInterval``
    /// seconds' worth has piled up; failures are swallowed, because a journal that cannot be
    /// written must never be the reason a live dictation stops.
    public func append(_ samples16kMono: [Float]) {
        lock.lock()
        guard !discarded else {
            lock.unlock()
            return
        }
        buffered.append(contentsOf: samples16kMono)
        let ready = buffered.count >= Self.flushThreshold
        lock.unlock()
        guard ready else { return }
        try? flush()
    }

    /// Appends everything buffered to the file, creating it if this is the first write.
    ///
    /// Called by ``append(_:)`` on the two-second boundary and by the recorder when the
    /// microphone closes, so the file on disk is complete while the engine is still thinking —
    /// which is the other moment iOS is entitled to kill the app.
    public func flush() throws {
        lock.lock()
        guard !discarded, !buffered.isEmpty else {
            lock.unlock()
            return
        }
        let samples = buffered
        buffered = []
        lock.unlock()

        let data = Self.encode(samples)
        let manager = FileManager.default
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
        try? manager.setAttributes([.modificationDate: clock()], ofItemAtPath: url.path)
    }

    /// The dictation is safely elsewhere (in history, or deliberately abandoned): drop the
    /// file and make this journal inert.
    public func discard() {
        lock.lock()
        discarded = true
        buffered = []
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Recovery

    /// A recording the app never finished, as Home offers it back.
    public struct Pending: Equatable {
        public let url: URL
        /// When the last samples were written — how the file is judged abandoned.
        public let modifiedAt: Date
        /// Seconds of audio in the file: `bytes / 4 / 16000`.
        public let duration: TimeInterval

        public init(url: URL, modifiedAt: Date, duration: TimeInterval) {
            self.url = url
            self.modifiedAt = modifiedAt
            self.duration = duration
        }
    }

    /// The newest abandoned recording worth finishing, or `nil`.
    ///
    /// "Abandoned" is ``staleAfter`` seconds without a write, which is what keeps this from
    /// ever showing the *live* recording's own file — a second dictation running while Home is
    /// on screen has been touched within the last two seconds by definition. "Worth
    /// finishing" is ``minimumDuration``, so a tap-and-crash never becomes a banner.
    ///
    /// Only the newest is offered: older files are the user's problem to never see, and they
    /// are cleaned up the moment the newest one is finished or discarded.
    public static func pending(in directory: URL = defaultDirectory(), now: Date = .init()) -> Pending? {
        candidates(in: directory)
            .filter { now.timeIntervalSince($0.modifiedAt) >= staleAfter && $0.duration >= minimumDuration }
            .max { $0.modifiedAt < $1.modifiedAt }
    }

    /// The samples in a pending recording, ready for ``chunks(from:chunkSize:)``.
    public static func load(_ pending: Pending) throws -> [Float] {
        decode(try Data(contentsOf: pending.url, options: .mappedIfSafe))
    }

    /// Deletes a pending recording — and every older one with it, so a phone that crashed
    /// three times does not hold three recordings of the user's voice forever.
    public static func discard(_ pending: Pending) {
        let manager = FileManager.default
        try? manager.removeItem(at: pending.url)
        for other in candidates(in: pending.url.deletingLastPathComponent())
        where other.modifiedAt <= pending.modifiedAt {
            try? manager.removeItem(at: other.url)
        }
    }

    /// The journalled samples rebuilt as capture chunks, so a recovered dictation runs through
    /// exactly the same ``DictationPipeline`` a live one does — same engines, same fallbacks,
    /// same history write. `level` is the chunk's RMS, as the live tap reports it.
    public static func chunks(from samples16kMono: [Float], chunkSize: Int = 4096) -> AsyncStream<AudioChunk> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            var index = 0
            while index < samples16kMono.count {
                let end = min(index + chunkSize, samples16kMono.count)
                let slice = Array(samples16kMono[index..<end])
                index = end
                guard let buffer = AudioMath.buffer16kMono(slice) else { continue }
                continuation.yield(
                    AudioChunk(samples16kMono: slice, level: AudioMath.rms(buffer), buffer: buffer)
                )
            }
            continuation.finish()
        }
    }

    // MARK: - Directory

    /// Every `recording-*.f32` in `directory`, with the two facts the caller judges them by.
    private static func candidates(in directory: URL) -> [Pending] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url in
            guard url.pathExtension == ext, url.lastPathComponent.hasPrefix(prefix) else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modifiedAt = values.contentModificationDate,
                  let size = values.fileSize
            else { return nil }
            return Pending(
                url: url,
                modifiedAt: modifiedAt,
                duration: Double(size / bytesPerSample) / Double(sampleRate)
            )
        }
    }

    // MARK: - Float32 LE

    /// Every Apple platform is little-endian, so the in-memory bytes of a `[Float]` are
    /// already the file format; this is a `memcpy`, not a conversion loop.
    private static func encode(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// A trailing partial sample — the last write that a kill interrupted — is dropped.
    private static func decode(_ data: Data) -> [Float] {
        let count = data.count / bytesPerSample
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        samples.withUnsafeMutableBytes { destination in
            _ = data.copyBytes(to: destination, count: count * bytesPerSample)
        }
        return samples
    }
}
