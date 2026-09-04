import Foundation

/// Decides when the user has stopped talking, from nothing but the level meter.
///
/// Two rules, both from the Mac app: a pause only counts once real speech has been heard
/// (so the detector never fires on the silence *before* the first word), and it has to last
/// ``hangover`` seconds (so a breath between sentences is not the end of a dictation).
///
/// Pure value type on purpose — the recorder feeds it live levels, the tests feed it a
/// script, and neither needs a microphone.
public struct SilenceDetector {
    /// RMS below this counts as silence. 0.015 is roughly a quiet room on an iPhone mic.
    public let threshold: Float
    /// How much continuous silence ends the dictation.
    public let hangover: TimeInterval
    /// How much speech has to be heard first, so a door slam cannot end a dictation.
    public let minSpeech: TimeInterval

    /// Total above-threshold audio heard so far, accumulated across pauses.
    private var speechHeard: TimeInterval = 0
    /// Timestamp of the first below-threshold sample of the current pause.
    private var silenceStarted: TimeInterval?
    private var lastTime: TimeInterval?
    private var fired = false

    public init(threshold: Float = 0.015, hangover: TimeInterval = 1.5, minSpeech: TimeInterval = 0.4) {
        self.threshold = threshold
        self.hangover = hangover
        self.minSpeech = minSpeech
    }

    /// Feed one level reading. Returns `true` exactly once, on the first sample that completes
    /// `minSpeech` of speech followed by `hangover` of silence; every call after that is
    /// `false`, so the caller can keep feeding while it winds the recording down.
    ///
    /// The interval since the previous reading is credited to the current sample, so the
    /// first ever call contributes no time at all.
    public mutating func feed(level: Float, at t: TimeInterval) -> Bool {
        guard !fired else { return false }
        let elapsed = max(0, t - (lastTime ?? t))
        lastTime = t

        guard level < threshold else {
            speechHeard += elapsed
            silenceStarted = nil
            return false
        }

        let started = silenceStarted ?? t
        silenceStarted = started
        guard speechHeard >= minSpeech, t - started >= hangover else { return false }
        fired = true
        return true
    }
}
