package com.murmur.app

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.emptyPreferences
import app.murmur.core.CleanResult
import app.murmur.core.CloudConfig
import app.murmur.core.Provider
import com.murmur.app.data.CleanupEngine
import com.murmur.app.data.InMemorySecretStore
import com.murmur.app.data.ProviderId
import com.murmur.app.data.Settings
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.SttEngine
import com.murmur.app.data.history.HistoryStore
import com.murmur.app.data.history.TranscriptDao
import com.murmur.app.data.history.TranscriptEntity
import com.murmur.app.data.history.TranscriptSource
import com.murmur.app.engine.AudioSession
import com.murmur.app.engine.DictationPipeline
import com.murmur.app.engine.PipelineError
import com.murmur.app.engine.SpeechEngine
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pipeline's five rules, with fake engines and a fake cleanup — no microphone, no network,
 * no `libmurmur_core.so` (a JVM test cannot load it, so `clean` is always injected here).
 */
class DictationPipelineTest {

    // ── Fakes ────────────────────────────────────────────────────────────────

    private class FakeDataStore : DataStore<Preferences> {
        private val state = MutableStateFlow(emptyPreferences())
        override val data: Flow<Preferences> = state
        override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences =
            transform(state.value).also { state.value = it }
    }

    private object SilentSession : AudioSession {
        override val levels: Flow<Float> = emptyFlow()
        override suspend fun samples16kMono() = FloatArray(0)
        override fun stop() = Unit
    }

    private class FakeEngine(
        private val result: String = "",
        private val error: Exception? = null,
        private val partials: List<String> = emptyList(),
    ) : SpeechEngine {
        var calls = 0
            private set
        var lastSession: AudioSession? = null
            private set

        override suspend fun transcribe(session: AudioSession, partial: (String) -> Unit): String {
            calls++
            lastSession = session
            partials.forEach(partial)
            error?.let { throw it }
            return result
        }
    }

    /** In-memory [TranscriptDao]; ids are assigned the way Room assigns them. */
    private class FakeDao(private val events: MutableList<String>) : TranscriptDao {
        val rows = mutableListOf<TranscriptEntity>()
        private var nextId = 1L

        override suspend fun insert(transcript: TranscriptEntity): Long {
            events += "insert"
            val id = nextId++
            rows += transcript.copy(id = id)
            return id
        }

        override suspend fun recent(limit: Int) = rows.sortedByDescending { it.id }.take(limit)

        override suspend fun search(query: String, limit: Int) =
            recent(limit).filter { it.cleanText.contains(query, true) || it.rawText.contains(query, true) }

        override suspend fun delete(id: Long) {
            rows.removeAll { it.id == id }
        }

        override fun observeRecent(limit: Int): Flow<List<TranscriptEntity>> = flowOf(rows.takeLast(limit))
    }

    // ── Fixture ──────────────────────────────────────────────────────────────

    private val events = mutableListOf<String>()
    private val dao = FakeDao(events)
    private val history = HistoryStore(dao)
    private val secrets = InMemorySecretStore()
    private val settings = SettingsStore(FakeDataStore())
    private val cleanupConfigs = mutableListOf<CloudConfig?>()
    private val partials = mutableListOf<String>()

    private var cleanUsedCloud = false

    private suspend fun fakeClean(raw: String, cfg: CloudConfig?): CleanResult {
        events += "clean"
        cleanupConfigs += cfg
        return CleanResult(raw = raw, clean = "Clean: $raw", usedCloud = cleanUsedCloud)
    }

    private fun pipeline(
        local: SpeechEngine,
        cloud: SpeechEngine = FakeEngine(error = IllegalStateException("cloud must not be used")),
        offlineAvailable: Boolean = true,
    ): Pair<DictationPipeline, MutableList<CloudConfig>> {
        val sttConfigs = mutableListOf<CloudConfig>()
        val pipeline = DictationPipeline(
            settings = settings,
            secrets = secrets,
            history = history,
            localEngine = { local },
            cloudEngine = { cfg -> sttConfigs += cfg; cloud },
            offlineAvailable = { offlineAvailable },
            clean = ::fakeClean,
        )
        return pipeline to sttConfigs
    }

    private suspend fun settings(change: (Settings) -> Settings) = settings.update(change)

    // ── Rule 1: engine choice ────────────────────────────────────────────────

    @Test
    fun `the local engine transcribes when stt is local`() = runTest {
        val local = FakeEngine(result = "um hello world", partials = listOf("um", "um hello"))
        val (pipeline, sttConfigs) = pipeline(local)

        val outcome = pipeline.run(SilentSession, TranscriptSource.KEYBOARD, partials::add)

        assertEquals(1, local.calls)
        assertEquals(SilentSession, local.lastSession)
        assertTrue(sttConfigs.isEmpty())
        assertEquals(listOf("um", "um hello"), partials)
        assertFalse(outcome.usedCloudStt)
        assertEquals("Clean: um hello world", outcome.transcript.cleanText)
        assertEquals("keyboard", outcome.transcript.source)
    }

    @Test
    fun `a stored key sends the dictation to the cloud engine`() = runTest {
        settings { it.copy(stt = SttEngine.GROQ) }
        secrets.set(ProviderId.GROQ.keychainAccount, "  gsk-test  ")
        val local = FakeEngine(error = IllegalStateException("local must not be used"))
        val cloud = FakeEngine(result = "hello from groq")
        val (pipeline, sttConfigs) = pipeline(local, cloud)

        val outcome = pipeline.run(SilentSession, TranscriptSource.IN_APP, partials::add)

        assertEquals(1, cloud.calls)
        assertEquals(0, local.calls)
        assertEquals(1, sttConfigs.size)
        assertEquals(Provider.GROQ, sttConfigs.single().provider)
        // The stored key is trimmed on its way into the core and nowhere else.
        assertEquals("gsk-test", sttConfigs.single().apiKey)
        assertTrue(outcome.usedCloudStt)
        assertEquals("in-app", outcome.transcript.source)
    }

    @Test
    fun `a cloud engine with no key stored falls back to the local engine`() = runTest {
        settings { it.copy(stt = SttEngine.OPENAI) }
        val local = FakeEngine(result = "heard on device")
        val (pipeline, sttConfigs) = pipeline(local)

        val outcome = pipeline.run(SilentSession, TranscriptSource.KEYBOARD, partials::add)

        assertEquals(1, local.calls)
        assertTrue(sttConfigs.isEmpty())
        assertFalse(outcome.usedCloudStt)
        assertEquals("heard on device", outcome.transcript.rawText)
    }

    @Test
    fun `a key of only whitespace counts as no key`() = runTest {
        settings { it.copy(stt = SttEngine.GROQ) }
        secrets.set(ProviderId.GROQ.keychainAccount, "   ")
        val local = FakeEngine(result = "heard on device")
        val (pipeline, sttConfigs) = pipeline(local)

        pipeline.run(SilentSession, TranscriptSource.KEYBOARD, partials::add)

        assertEquals(1, local.calls)
        assertTrue(sttConfigs.isEmpty())
    }

    // ── Rule 2: cloud failure (the Android difference) ───────────────────────

    @Test
    fun `a cloud failure asks the user before retrying on device`() = runTest {
        settings { it.copy(stt = SttEngine.GROQ) }
        secrets.set(ProviderId.GROQ.keychainAccount, "gsk-test")
        val local = FakeEngine(result = "never reached")
        val cloud = FakeEngine(error = RuntimeException("Groq is unreachable"))
        val (pipeline, _) = pipeline(local, cloud, offlineAvailable = true)

        val error = runCatching { pipeline.run(SilentSession, TranscriptSource.KEYBOARD, partials::add) }
            .exceptionOrNull()

        val cloudError = error as PipelineError.Cloud
        assertEquals("Groq is unreachable", cloudError.message)
        assertTrue(cloudError.canRetryOnDevice)
        // Unlike iOS, the on-device recognizer is never handed the recorded buffer — it cannot
        // take one — so nothing is transcribed or written behind the user's back.
        assertEquals(0, local.calls)
        assertTrue(dao.rows.isEmpty())
    }

    @Test
    fun `a phone with no offline recognizer cannot offer the retry`() = runTest {
        settings { it.copy(stt = SttEngine.OPENAI) }
        secrets.set(ProviderId.OPENAI.keychainAccount, "sk-test")
        val cloud = FakeEngine(error = RuntimeException("offline"))
        val (pipeline, _) = pipeline(FakeEngine(), cloud, offlineAvailable = false)

        val error = runCatching { pipeline.run(SilentSession, TranscriptSource.KEYBOARD, partials::add) }
            .exceptionOrNull()

        assertFalse((error as PipelineError.Cloud).canRetryOnDevice)
    }

    @Test
    fun `forceLocal skips the cloud engine even with a key stored`() = runTest {
        settings { it.copy(stt = SttEngine.GROQ) }
        secrets.set(ProviderId.GROQ.keychainAccount, "gsk-test")
        val local = FakeEngine(result = "second try, on device")
        val cloud = FakeEngine(error = RuntimeException("still offline"))
        val (pipeline, sttConfigs) = pipeline(local, cloud)

        val outcome =
            pipeline.run(SilentSession, TranscriptSource.KEYBOARD, partials::add, forceLocal = true)

        assertEquals(1, local.calls)
        assertEquals(0, cloud.calls)
        assertTrue(sttConfigs.isEmpty())
        assertFalse(outcome.usedCloudStt)
        assertEquals("second try, on device", outcome.transcript.rawText)
    }

    // ── Rule 3: silence ──────────────────────────────────────────────────────

    @Test
    fun `an empty transcript is Empty and writes no row`() = runTest {
        val (pipeline, _) = pipeline(FakeEngine(result = ""))

        val error = runCatching { pipeline.run(SilentSession, TranscriptSource.KEYBOARD, partials::add) }
            .exceptionOrNull()

        assertTrue(error is PipelineError.Empty)
        assertTrue(dao.rows.isEmpty())
        assertTrue(events.isEmpty())
    }

    @Test
    fun `whitespace only is silence too`() = runTest {
        val (pipeline, _) = pipeline(FakeEngine(result = "  \n \t "))

        val error = runCatching { pipeline.run(SilentSession, TranscriptSource.KEYBOARD, partials::add) }
            .exceptionOrNull()

        assertTrue(error is PipelineError.Empty)
        assertTrue(dao.rows.isEmpty())
    }

    // ── Rule 4: cleanup config gating ────────────────────────────────────────

    @Test
    fun `rules cleanup gets no cloud config even when a key is stored`() = runTest {
        secrets.set(ProviderId.GROQ.keychainAccount, "gsk-test")
        val (pipeline, _) = pipeline(FakeEngine(result = "hello"))

        pipeline.run(SilentSession, TranscriptSource.KEYBOARD, partials::add)

        assertEquals(1, cleanupConfigs.size)
        assertNull(cleanupConfigs.single())
    }

    @Test
    fun `a cloud cleanup engine gets its own provider config`() = runTest {
        settings { it.copy(cleanup = CleanupEngine.OPENAI) }
        secrets.set(ProviderId.OPENAI.keychainAccount, "sk-cleanup")
        cleanUsedCloud = true
        val (pipeline, _) = pipeline(FakeEngine(result = "hello"))

        val outcome = pipeline.run(SilentSession, TranscriptSource.KEYBOARD, partials::add)

        assertEquals(Provider.OPEN_AI, cleanupConfigs.single()?.provider)
        assertEquals("sk-cleanup", cleanupConfigs.single()?.apiKey)
        assertTrue(outcome.usedCloudCleanup)
    }

    @Test
    fun `a cloud cleanup engine with no key falls back to the rules pass`() = runTest {
        settings { it.copy(cleanup = CleanupEngine.GROQ) }
        val (pipeline, _) = pipeline(FakeEngine(result = "hello"))

        val outcome = pipeline.run(SilentSession, TranscriptSource.KEYBOARD, partials::add)

        assertNull(cleanupConfigs.single())
        assertFalse(outcome.usedCloudCleanup)
    }

    @Test
    fun `an empty cleanup result keeps the raw words`() = runTest {
        val (pipeline, _) = pipeline(FakeEngine(result = "hello"))
        val emptyCleanup = DictationPipeline(
            settings = settings,
            secrets = secrets,
            history = history,
            localEngine = { FakeEngine(result = "the words") },
            cloudEngine = { FakeEngine() },
            offlineAvailable = { true },
            clean = { raw, _ -> CleanResult(raw = raw, clean = "   ", usedCloud = false) },
        )
        assertTrue(pipeline !== emptyCleanup)

        val outcome = emptyCleanup.run(SilentSession, TranscriptSource.KEYBOARD, partials::add)

        assertEquals("the words", outcome.transcript.cleanText)
    }

    // ── Rule 5: history first ────────────────────────────────────────────────

    @Test
    fun `the history row is written before the outcome comes back`() = runTest {
        val (pipeline, _) = pipeline(FakeEngine(result = "  um hello world  "))

        val outcome = pipeline.run(SilentSession, TranscriptSource.KEYBOARD, partials::add)

        assertEquals(listOf("clean", "insert"), events)
        assertEquals(1, dao.rows.size)
        val row = dao.rows.single()
        assertEquals(row.id, outcome.transcript.id)
        assertTrue(outcome.transcript.id > 0)
        // Trimmed once, on the way in: what is stored is what gets committed.
        assertEquals("um hello world", row.rawText)
        assertEquals("Clean: um hello world", row.cleanText)
        assertTrue(row.createdAt > 0)
    }
}
