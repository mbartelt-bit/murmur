package com.murmur.app

import android.os.Bundle
import android.speech.SpeechRecognizer
import com.murmur.app.engine.LocalSpeechEngine
import com.murmur.app.engine.PipelineError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The on-device engine's mapping, driven through the `RecognitionListener` it builds.
 *
 * A fake `SpeechRecognizer` is not feasible (the class is final and talks to a system service),
 * so the engine keeps every decision in `LocalSpeechEngine.listener` and the test calls its
 * callbacks the way the platform would. Robolectric is here only for `Bundle`; no recognizer,
 * no microphone and no Google speech service is touched.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class LocalSpeechEngineTest {

    private val partials = mutableListOf<String>()
    private val levels = mutableListOf<Float>()
    private var result: String? = null
    private var error: PipelineError? = null

    private val listener = LocalSpeechEngine.listener(
        partial = { partials += it },
        onLevel = { levels += it },
        onResult = { result = it },
        onError = { error = it },
    )

    private fun results(vararg hypotheses: String) = Bundle().apply {
        putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, ArrayList(hypotheses.toList()))
    }

    @Test
    fun `partial results reach the strip`() {
        listener.onPartialResults(results("hello", "hallo"))

        assertEquals(listOf("hello"), partials)
        assertNull(result)
        assertNull(error)
    }

    @Test
    fun `a final result is the first hypothesis`() {
        listener.onResults(results("hello there", "hello their"))

        assertEquals("hello there", result)
        assertNull(error)
    }

    @Test
    fun `an empty bundle is an empty result, not a crash`() {
        listener.onResults(Bundle())

        assertEquals("", result)
        assertNull(error)
    }

    @Test
    fun `no match is silence, not a failure`() {
        listener.onError(SpeechRecognizer.ERROR_NO_MATCH)

        assertEquals("", result)
        assertNull(error)
    }

    @Test
    fun `a speech timeout is silence too`() {
        listener.onError(SpeechRecognizer.ERROR_SPEECH_TIMEOUT)

        assertEquals("", result)
        assertNull(error)
    }

    @Test
    fun `missing permission is MicDenied`() {
        listener.onError(SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS)

        assertTrue(error is PipelineError.MicDenied)
        assertNull(result)
    }

    @Test
    fun `every other error is NoSpeechEngine`() {
        for (code in listOf(
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
            SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE,
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY,
            SpeechRecognizer.ERROR_CLIENT,
            SpeechRecognizer.ERROR_NETWORK,
            SpeechRecognizer.ERROR_SERVER,
        )) {
            error = null
            listener.onError(code)
            assertTrue("error $code should be NoSpeechEngine", error is PipelineError.NoSpeechEngine)
        }
        assertNull(result)
    }

    @Test
    fun `rms in dB becomes a 0 to 1 level`() {
        listener.onRmsChanged(4f)
        listener.onRmsChanged(-2f)
        listener.onRmsChanged(10f)
        listener.onRmsChanged(-40f)
        listener.onRmsChanged(40f)

        assertEquals(0.5f, levels[0], 0.01f)
        assertEquals(0f, levels[1], 0.001f)
        assertEquals(1f, levels[2], 0.001f)
        assertEquals(0f, levels[3], 0.001f)
        assertEquals(1f, levels[4], 0.001f)
    }
}
