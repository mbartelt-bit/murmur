package com.murmur.app

import com.murmur.app.audio.SilenceDetector
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The same three cases as the iOS twin's `SilenceDetectorTests`: a room that is never spoken
 * in, a real dictation, and a blip too short to count as speech.
 *
 * Levels are fed on a 100 ms grid, which is roughly what a 16 kHz reader produces.
 */
class SilenceDetectorTest {

    private val loud = 0.2f
    private val quiet = 0.001f

    /** Feeds [level] for [ms] milliseconds from [from]; returns the time it stopped at. */
    private fun feed(
        detector: SilenceDetector,
        level: Float,
        ms: Long,
        from: Long,
        onFire: (Long) -> Unit = {},
    ): Long {
        var t = from
        val end = from + ms
        while (t <= end) {
            if (detector.feed(level, t)) onFire(t)
            t += STEP
        }
        return t
    }

    @Test
    fun `silence alone never fires`() {
        val detector = SilenceDetector()
        var fires = 0
        feed(detector, quiet, ms = 10_000, from = 0) { fires++ }
        assertFalse("silence before the first word must not end a dictation", fires > 0)
    }

    @Test
    fun `speech then a second and a half of silence fires once`() {
        val detector = SilenceDetector()
        val fires = mutableListOf<Long>()

        val afterSpeech = feed(detector, loud, ms = 1_000, from = 0) { fires += it }
        assertTrue("speech alone must not fire", fires.isEmpty())

        // Well past the hangover, so a second fire would show up here if it could.
        feed(detector, quiet, ms = 4_000, from = afterSpeech) { fires += it }

        assertEqualsOnce(fires)
        val firedAt = fires.single()
        val silenceStarted = afterSpeech
        assertTrue(
            "fired after $firedAt ms, silence started at $silenceStarted ms",
            firedAt - silenceStarted >= 1_500 && firedAt - silenceStarted < 1_500 + STEP * 2,
        )
    }

    @Test
    fun `a 200 ms blip never fires`() {
        val detector = SilenceDetector()
        var fires = 0

        val afterBlip = feed(detector, loud, ms = 200, from = 0) { fires++ }
        feed(detector, quiet, ms = 10_000, from = afterBlip) { fires++ }

        assertFalse("200 ms is under minSpeech, so this is a door slam not a dictation", fires > 0)
    }

    private fun assertEqualsOnce(fires: List<Long>) {
        assertTrue("expected exactly one fire, got ${fires.size}", fires.size == 1)
    }

    private companion object {
        const val STEP = 100L
    }
}
