import XCTest

import MurmurShared
@testable import Murmur

/// Auto-stop is the feature people notice most when it misfires: stopping in the middle of a
/// sentence loses words, never stopping wastes a dictation. These cases pin both edges.
final class SilenceDetectorTests: XCTestCase {
    /// Levels are fed on a 0.1 s grid, the same order of magnitude as a real 4096-frame tap.
    private let step: TimeInterval = 0.1
    private let loud: Float = 0.5
    private let quiet: Float = 0.001

    /// Feeds `levels` starting at `from` and returns the time of the first fire, or `nil`.
    @discardableResult
    private func feed(
        _ detector: inout SilenceDetector,
        _ levels: [Float],
        from start: TimeInterval = 0
    ) -> TimeInterval? {
        var fired: TimeInterval?
        for (i, level) in levels.enumerated() {
            let t = start + Double(i) * step
            if detector.feed(level: level, at: t), fired == nil { fired = t }
        }
        return fired
    }

    private func levels(_ level: Float, seconds: TimeInterval) -> [Float] {
        Array(repeating: level, count: Int((seconds / step).rounded()))
    }

    func testSilenceAloneNeverFires() {
        var detector = SilenceDetector()
        XCTAssertNil(feed(&detector, levels(quiet, seconds: 10)))
    }

    func testSpeechThenAPauseFires() {
        var detector = SilenceDetector()
        // 0.5 s of speech (past minSpeech), then 1.5 s of silence.
        XCTAssertNotNil(feed(&detector, levels(loud, seconds: 0.5) + levels(quiet, seconds: 2)))
    }

    func testItFiresOnlyOnceEvenIfTheCallerKeepsFeeding() {
        var detector = SilenceDetector()
        let script = levels(loud, seconds: 0.5) + levels(quiet, seconds: 5)
        var fires = 0
        for (i, level) in script.enumerated() where detector.feed(level: level, at: Double(i) * step) {
            fires += 1
        }
        XCTAssertEqual(fires, 1)
    }

    func testItFiresOnceTheHangoverHasElapsedAndNotBefore() {
        var detector = SilenceDetector()
        // Speech across 0...0.5 (0.5 s credited), so the first quiet sample is at 0.6.
        let fired = feed(&detector, levels(loud, seconds: 0.6) + levels(quiet, seconds: 3))
        XCTAssertEqual(try XCTUnwrap(fired), 2.1, accuracy: 0.001)
    }

    func testABlipShorterThanMinSpeechNeverFires() {
        var detector = SilenceDetector()
        // 0.2 s of noise — a door, not a sentence — then a long silence.
        XCTAssertNil(feed(&detector, levels(loud, seconds: 0.2) + levels(quiet, seconds: 10)))
    }

    func testSpeechAccumulatesAcrossShortPauses() {
        var detector = SilenceDetector()
        // Two 0.3 s bursts either side of a 0.5 s pause: together they pass minSpeech.
        let script = levels(loud, seconds: 0.3) + levels(quiet, seconds: 0.5)
            + levels(loud, seconds: 0.3) + levels(quiet, seconds: 2)
        XCTAssertNotNil(feed(&detector, script))
    }

    func testResumedSpeechRestartsTheHangover() {
        var detector = SilenceDetector()
        // A 1.4 s pause (just under the hangover), then more speech, then a short pause.
        let script = levels(loud, seconds: 0.5) + levels(quiet, seconds: 1.4)
            + levels(loud, seconds: 0.3) + levels(quiet, seconds: 1.0)
        XCTAssertNil(feed(&detector, script))
    }

    func testTheFirstSampleContributesNoTime() {
        var detector = SilenceDetector()
        // A single loud sample is an instant, not 0.4 s of speech, so this must not fire.
        XCTAssertFalse(detector.feed(level: loud, at: 0))
        XCTAssertNil(feed(&detector, levels(quiet, seconds: 5), from: step))
    }

    func testExactlyAtTheThresholdCountsAsSpeech() {
        var detector = SilenceDetector(threshold: 0.015)
        XCTAssertNil(feed(&detector, levels(0.015, seconds: 10)))
    }

    func testCustomParametersAreHonoured() {
        var detector = SilenceDetector(threshold: 0.5, hangover: 0.3, minSpeech: 0.1)
        // 0.4 is silence at this threshold; 0.6 is speech.
        let fired = feed(&detector, levels(0.6, seconds: 0.3) + levels(0.4, seconds: 1))
        XCTAssertEqual(try XCTUnwrap(fired), 0.6, accuracy: 0.001)
    }

    func testTimeGoingBackwardsIsIgnored() {
        var detector = SilenceDetector()
        XCTAssertFalse(detector.feed(level: loud, at: 5))
        XCTAssertFalse(detector.feed(level: loud, at: 0))
        XCTAssertNil(feed(&detector, levels(quiet, seconds: 5), from: 5.1))
    }
}
