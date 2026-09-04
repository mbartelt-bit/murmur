package com.murmur.app

import app.murmur.core.CloudConfig
import app.murmur.core.CoreException
import app.murmur.core.Provider
import com.murmur.app.engine.AudioSession
import com.murmur.app.engine.CloudSpeechEngine
import com.murmur.app.engine.PipelineError
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The cloud engine with the core call injected — `libmurmur_core.so` cannot be loaded by a JVM
 * test, and nothing here touches the network or a real key.
 */
class CloudSpeechEngineTest {

    private val cfg = CloudConfig(provider = Provider.GROQ, apiKey = "gsk-test-value")

    /** A session that "recorded" [samples] and hands them over when asked. */
    private class RecordedSession(private val samples: FloatArray) : AudioSession {
        override val levels: Flow<Float> = emptyFlow()
        var stops = 0
            private set

        override suspend fun samples16kMono(): FloatArray = samples
        override fun stop() {
            stops++
        }
    }

    @Test
    fun `posts the session's samples to the core`() = runTest {
        val recorded = floatArrayOf(0.1f, -0.2f, 0.3f, -0.4f)
        val session = RecordedSession(recorded)
        var seen: List<Float>? = null
        var seenCfg: CloudConfig? = null
        var seenPrompt: String? = null

        val engine = CloudSpeechEngine(cfg) { audio, config, prompt ->
            seen = audio
            seenCfg = config
            seenPrompt = prompt
            "hello there"
        }

        val text = engine.transcribe(session) { fail("cloud STT has no partials") }

        assertEquals("hello there", text)
        assertEquals(recorded.toList(), seen)
        assertEquals(Provider.GROQ, seenCfg?.provider)
        assertEquals("", seenPrompt)
    }

    @Test
    fun `a rejected key becomes PipelineError Cloud with the core's message`() = runTest {
        val session = RecordedSession(floatArrayOf(0f, 0f))
        val engine = CloudSpeechEngine(cfg) { _, _, _ ->
            throw CoreException.Rejected("Groq rejected the key")
        }

        val failure = runCatching { engine.transcribe(session) {} }.exceptionOrNull()

        assertTrue("expected PipelineError.Cloud, got $failure", failure is PipelineError.Cloud)
        assertEquals("Groq rejected the key", failure?.message)
    }

    private fun fail(reason: String): Nothing = throw AssertionError(reason)
}
