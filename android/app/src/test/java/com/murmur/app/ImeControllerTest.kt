package com.murmur.app

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.emptyPreferences
import com.murmur.app.data.Settings
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.SttEngine
import com.murmur.app.data.history.TranscriptEntity
import com.murmur.app.data.history.TranscriptSource
import com.murmur.app.engine.AudioSession
import com.murmur.app.engine.PipelineError
import com.murmur.app.engine.PipelineOutcome
import com.murmur.app.ime.Dictation
import com.murmur.app.ime.ImeController
import com.murmur.app.ime.ImeHost
import com.murmur.app.ime.ImePhase
import com.murmur.app.ime.TextSink
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The keyboard's whole state machine, with no microphone, no pipeline and no clock.
 *
 * Time is virtual: the controller's clock reads the test scheduler, so the 120 s cap and the
 * 400 ms hand-back fire in microseconds. Nothing here touches Android — the controller is
 * plain Kotlin on purpose.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ImeControllerTest {

    // ── Fakes ────────────────────────────────────────────────────────────────

    private class FakeDataStore : DataStore<Preferences> {
        private val state = MutableStateFlow(emptyPreferences())
        override val data: Flow<Preferences> = state
        override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences =
            transform(state.value).also { state.value = it }
    }

    /**
     * A microphone session that ends when something stops it — exactly what both real engines
     * see. A shared flow rather than a state flow so two identical level readings both arrive
     * (the silence detector cares about the second one).
     */
    private class FakeSession : AudioSession {
        private val meter = MutableSharedFlow<Float>(replay = 1, extraBufferCapacity = 64)
        override val levels: Flow<Float> = meter
        private val stopped = CompletableDeferred<Unit>()

        var stops = 0
            private set

        fun push(level: Float) {
            meter.tryEmit(level)
        }

        override suspend fun samples16kMono(): FloatArray {
            stopped.await()
            return FloatArray(0)
        }

        override fun stop() {
            stops++
            stopped.complete(Unit)
        }
    }

    private class FakeSink : TextSink {
        val commits = mutableListOf<String>()
        var deletes = 0
            private set
        var before: String? = ""

        override fun commit(text: String) {
            commits += text
        }

        override fun deleteBackward() {
            deletes++
        }

        override fun contextBefore(): String? = before
    }

    private class FakeHost : ImeHost {
        var previous = 0
            private set
        var next = 0
            private set
        var opened = 0
            private set

        override fun switchToPrevious() {
            previous++
        }

        override fun switchToNext() {
            next++
        }

        override fun openApp() {
            opened++
        }

        override val needsInputModeSwitch: Boolean = true
    }

    private data class Call(
        val session: AudioSession,
        val source: TranscriptSource,
        val forceLocal: Boolean,
    )

    /** The pipeline, minus the engines: it waits for the microphone, then answers. */
    private class FakeDictation : Dictation {
        val calls = mutableListOf<Call>()

        /** One entry per run, in order; runs past the end return [defaultClean]. */
        val results = ArrayDeque<Result<String>>()
        var defaultClean = "Hello there"
        var partials: List<String> = emptyList()

        override suspend fun run(
            session: AudioSession,
            source: TranscriptSource,
            partial: (String) -> Unit,
            forceLocal: Boolean,
        ): PipelineOutcome {
            calls += Call(session, source, forceLocal)
            // Every real engine ends when the audio does.
            session.samples16kMono()
            partials.forEach(partial)
            val text = (results.removeFirstOrNull() ?: Result.success(defaultClean)).getOrThrow()
            return PipelineOutcome(
                transcript = TranscriptEntity(
                    id = 1,
                    rawText = text,
                    cleanText = text,
                    source = source.id,
                    createdAt = 0L,
                ),
                usedCloudStt = false,
                usedCloudCleanup = false,
            )
        }
    }

    // ── Fixture ──────────────────────────────────────────────────────────────

    private val store = SettingsStore(FakeDataStore())
    private val sink = FakeSink()
    private val host = FakeHost()
    private val dictation = FakeDictation()

    /** Every session the controller asked for, with the `cloud` flag it asked with. */
    private val sessions = mutableListOf<Pair<Boolean, FakeSession>>()

    private var permission = true
    private var offline = true
    private var imeScope: CoroutineScope? = null

    @After
    fun tearDown() {
        imeScope?.cancel()
    }

    private fun TestScope.build(maxDurationMs: Long = 120_000): ImeController {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        imeScope = scope
        return ImeController(
            settings = store,
            pipeline = dictation,
            sessionFactory = { cloud -> FakeSession().also { sessions += cloud to it } },
            permissions = { permission },
            offlineAvailable = { offline },
            clock = { testScheduler.currentTime },
            scope = scope,
            maxDurationMs = maxDurationMs,
        )
    }

    private val session: FakeSession get() = sessions.last().second

    // ── Permission ───────────────────────────────────────────────────────────

    @Test
    fun `no microphone permission asks for the app and records nothing`() = runTest {
        permission = false
        val controller = build()

        controller.onShown(host, sink)
        testScheduler.runCurrent()

        assertEquals(ImePhase.NeedsPermission, controller.phase.value)
        assertTrue(sessions.isEmpty())
        assertTrue(dictation.calls.isEmpty())

        // The strip's button, and the mic key, both lead to the one place that can grant it.
        controller.openApp()
        assertEquals(1, host.opened)
    }

    // ── Auto-listen ──────────────────────────────────────────────────────────

    @Test
    fun `auto-listen opens the microphone as soon as the keyboard appears`() = runTest {
        val controller = build()

        controller.onShown(host, sink)
        testScheduler.runCurrent()

        assertTrue(controller.phase.value is ImePhase.Listening)
        assertEquals(1, dictation.calls.size)
        assertEquals(TranscriptSource.KEYBOARD, dictation.calls[0].source)
        assertFalse(dictation.calls[0].forceLocal)
        // The default engine is on-device, so the recognizer owns the microphone.
        assertFalse(sessions[0].first)

        controller.onHidden()
    }

    @Test
    fun `auto-listen off waits for the mic key`() = runTest {
        store.update { it.copy(autoListen = false) }
        val controller = build()

        controller.onShown(host, sink)
        testScheduler.runCurrent()
        assertEquals(ImePhase.Idle, controller.phase.value)
        assertTrue(dictation.calls.isEmpty())

        controller.tapMic()
        testScheduler.runCurrent()
        assertTrue(controller.phase.value is ImePhase.Listening)

        controller.onHidden()
    }

    // ── The happy path ───────────────────────────────────────────────────────

    @Test
    fun `stopping commits once with a trailing space and hands the keyboard back`() = runTest {
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()

        controller.stop()
        assertEquals(ImePhase.Transcribing(""), controller.phase.value)
        testScheduler.runCurrent()

        assertEquals(listOf("Hello there "), sink.commits)
        assertEquals(ImePhase.Done("Hello there"), controller.phase.value)
        assertEquals(1, session.stops)

        // The text is on screen for a beat before the keyboards swap.
        assertEquals(0, host.previous)
        testScheduler.advanceTimeBy(400)
        testScheduler.runCurrent()
        assertEquals(1, host.previous)
        assertEquals(1, sink.commits.size)
    }

    @Test
    fun `a dictation straight after a word gets a leading space too`() = runTest {
        sink.before = "Tell them"
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()

        controller.stop()
        testScheduler.runCurrent()

        assertEquals(listOf(" Hello there "), sink.commits)
        controller.onHidden()
    }

    @Test
    fun `return-to-previous off leaves the keyboard where it is`() = runTest {
        store.update { it.copy(returnToPreviousKeyboard = false) }
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()

        controller.stop()
        testScheduler.runCurrent()
        testScheduler.advanceTimeBy(2_000)
        testScheduler.runCurrent()

        assertEquals(listOf("Hello there "), sink.commits)
        assertEquals(0, host.previous)
    }

    @Test
    fun `the partial shows while the engine is still working`() = runTest {
        dictation.partials = listOf("hello")
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()

        controller.stop()
        testScheduler.runCurrent()

        // The partial arrived during Transcribing and was replaced by the finished text.
        assertEquals(ImePhase.Done("Hello there"), controller.phase.value)
        controller.onHidden()
    }

    @Test
    fun `a restarted input session after a commit does not dictate again`() = runTest {
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()
        controller.stop()
        testScheduler.runCurrent()
        assertEquals(1, sink.commits.size)

        // committing text makes some apps restart the input session, which shows us again.
        controller.onShown(host, sink)
        testScheduler.runCurrent()

        assertEquals(1, dictation.calls.size)
        assertEquals(1, sink.commits.size)
    }

    // ── Nothing said ─────────────────────────────────────────────────────────

    @Test
    fun `silence commits nothing and says so for two seconds`() = runTest {
        dictation.results += Result.failure(PipelineError.Empty)
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()

        controller.stop()
        testScheduler.runCurrent()

        assertEquals(ImePhase.Failed("Didn't catch that.", false), controller.phase.value)
        assertTrue(sink.commits.isEmpty())
        assertEquals(0, host.previous)

        testScheduler.advanceTimeBy(2_000)
        testScheduler.runCurrent()
        assertEquals(ImePhase.Idle, controller.phase.value)
    }

    // ── Cloud failure ────────────────────────────────────────────────────────

    @Test
    fun `a cloud failure offers the on-device retry and runs it locally`() = runTest {
        store.update { it.copy(stt = SttEngine.GROQ) }
        dictation.results += Result.failure(
            PipelineError.Cloud("Groq is unreachable.", canRetryOnDevice = false),
        )
        dictation.results += Result.success("Local words")
        val controller = build()

        controller.onShown(host, sink)
        testScheduler.runCurrent()
        // A cloud engine means the recorder owns the microphone.
        assertTrue(sessions[0].first)

        controller.stop()
        testScheduler.runCurrent()
        assertEquals(ImePhase.Failed("Groq is unreachable.", true), controller.phase.value)
        assertTrue(sink.commits.isEmpty())

        controller.retryOnDevice()
        testScheduler.runCurrent()
        assertEquals(2, dictation.calls.size)
        assertTrue(dictation.calls[1].forceLocal)
        // ...on a fresh on-device session, because the recognizer cannot replay a buffer.
        assertFalse(sessions[1].first)

        controller.stop()
        testScheduler.runCurrent()
        assertEquals(listOf("Local words "), sink.commits)
    }

    @Test
    fun `a cloud failure with no offline recognizer offers nothing`() = runTest {
        offline = false
        store.update { it.copy(stt = SttEngine.OPENAI) }
        dictation.results += Result.failure(PipelineError.Cloud("No network.", canRetryOnDevice = false))
        val controller = build()

        controller.onShown(host, sink)
        testScheduler.runCurrent()
        controller.stop()
        testScheduler.runCurrent()

        assertEquals(ImePhase.Failed("No network.", false), controller.phase.value)
    }

    @Test
    fun `no engine at all says which settings to change`() = runTest {
        dictation.results += Result.failure(PipelineError.NoSpeechEngine)
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()
        controller.stop()
        testScheduler.runCurrent()

        assertEquals(
            ImePhase.Failed(
                "On-device speech isn't available. Pick Groq or OpenAI in Settings.",
                false,
            ),
            controller.phase.value,
        )
    }

    @Test
    fun `a mic denied mid-dictation sends the user to the app`() = runTest {
        dictation.results += Result.failure(PipelineError.MicDenied)
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()
        controller.stop()
        testScheduler.runCurrent()

        assertEquals(ImePhase.NeedsPermission, controller.phase.value)
        assertTrue(sink.commits.isEmpty())
    }

    // ── The cap and the silence detector ─────────────────────────────────────

    @Test
    fun `the two-minute cap stops the recording by itself`() = runTest {
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()

        testScheduler.advanceTimeBy(119_000)
        testScheduler.runCurrent()
        assertTrue(controller.phase.value is ImePhase.Listening)
        assertEquals(0, session.stops)

        testScheduler.advanceTimeBy(1_000)
        testScheduler.runCurrent()

        assertEquals(1, session.stops)
        assertEquals(listOf("Hello there "), sink.commits)
    }

    @Test
    fun `a pause ends a cloud dictation`() = runTest {
        store.update { it.copy(stt = SttEngine.GROQ) }
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()

        speakThenPause()

        assertEquals(1, session.stops)
        assertEquals(listOf("Hello there "), sink.commits)
    }

    @Test
    fun `the same pause does not cut the on-device recognizer off`() = runTest {
        // The recognizer endpoints for itself through the intent extras; a second detector
        // racing it would clip the last word.
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()

        speakThenPause()

        assertEquals(0, session.stops)
        assertTrue(sink.commits.isEmpty())
        assertTrue(controller.phase.value is ImePhase.Listening)

        controller.onHidden()
    }

    /** Half a second of speech, then two seconds of room tone — the detector's two rules. */
    private fun TestScope.speakThenPause() {
        session.push(0.5f)
        testScheduler.runCurrent()
        testScheduler.advanceTimeBy(600)
        session.push(0.4f)
        testScheduler.runCurrent()
        session.push(0.001f)
        testScheduler.runCurrent()
        testScheduler.advanceTimeBy(2_000)
        session.push(0.002f)
        testScheduler.runCurrent()
    }

    // ── Keys ─────────────────────────────────────────────────────────────────

    @Test
    fun `the delete, space, return and globe keys reach the sink and the host`() = runTest {
        store.update { it.copy(autoListen = false) }
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()

        controller.tapDelete()
        controller.tapSpace()
        controller.tapReturn()
        controller.tapGlobe()

        assertEquals(1, sink.deletes)
        assertEquals(listOf(" ", "\n"), sink.commits)
        assertEquals(1, host.next)
        assertEquals(0, host.previous)
        assertTrue(controller.showsGlobe.value)
    }

    // ── Going away ───────────────────────────────────────────────────────────

    @Test
    fun `hiding the keyboard mid-dictation commits nothing`() = runTest {
        val controller = build()
        controller.onShown(host, sink)
        testScheduler.runCurrent()

        controller.onHidden()
        testScheduler.runCurrent()

        assertEquals(ImePhase.Idle, controller.phase.value)
        assertTrue(sink.commits.isEmpty())
        // The microphone is released even though nothing will be typed.
        assertEquals(1, session.stops)

        testScheduler.advanceTimeBy(5_000)
        testScheduler.runCurrent()
        assertTrue(sink.commits.isEmpty())
        assertEquals(0, host.previous)
    }
}
