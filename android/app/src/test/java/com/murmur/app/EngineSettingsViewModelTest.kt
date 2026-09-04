package com.murmur.app

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.emptyPreferences
import app.murmur.core.CloudConfig
import com.murmur.app.data.CleanupEngine
import com.murmur.app.data.InMemorySecretStore
import com.murmur.app.data.ProviderId
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.SttEngine
import com.murmur.app.ui.settings.EngineSettingsViewModel
import com.murmur.app.ui.settings.EngineSettingsViewModel.VerifyState
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The engine and key screen, with no network and no keystore.
 *
 * The one thing every test here also proves: a key exists in the secret store and in the
 * argument handed to `verify`, and nowhere else — never in the view model's own state.
 */
class EngineSettingsViewModelTest {

    private class FakeDataStore : DataStore<Preferences> {
        private val state = MutableStateFlow(emptyPreferences())
        override val data: Flow<Preferences> = state
        override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences =
            transform(state.value).also { state.value = it }
    }

    private val settings = SettingsStore(FakeDataStore())
    private val secrets = InMemorySecretStore()

    /** Every config `verify` was called with, so a test can see the exact key that went out. */
    private val verified = mutableListOf<CloudConfig>()
    private var rejection: Exception? = null

    private fun model() = EngineSettingsViewModel(
        settings = settings,
        secrets = secrets,
        verifyKey = { cfg ->
            verified += cfg
            rejection?.let { throw it }
        },
        keyPage = { "https://example.test/${it.id}" },
    )

    // ── Saving a key ─────────────────────────────────────────────────────────

    @Test
    fun `saveKey trims, stores and verifies`() = runTest {
        val model = model()

        model.saveKey("  gsk_abc123  ", ProviderId.GROQ)

        assertEquals("gsk_abc123", secrets.get(ProviderId.GROQ.keychainAccount))
        assertEquals(1, verified.size)
        assertEquals("gsk_abc123", verified.single().apiKey)
        assertEquals(ProviderId.GROQ.core, verified.single().provider)
        assertEquals(VerifyState.Connected, model.state(ProviderId.GROQ))
        assertTrue(model.hasKey(ProviderId.GROQ))
        assertNull(model.saving)
    }

    @Test
    fun `a rejected key keeps the key and shows the core's own sentence`() = runTest {
        rejection = app.murmur.core.CoreException.Rejected("That key was rejected. Check it and try again.")
        val model = model()

        model.saveKey("gsk_wrong", ProviderId.GROQ)

        assertEquals(
            VerifyState.Failed("That key was rejected. Check it and try again."),
            model.state(ProviderId.GROQ),
        )
        // Left in the store on purpose: the user may have pasted a good key for the wrong
        // provider, and deleting it would lose the paste as well as the answer.
        assertEquals("gsk_wrong", secrets.get(ProviderId.GROQ.keychainAccount))
        assertTrue(model.hasKey(ProviderId.GROQ))
    }

    @Test
    fun `a blank paste changes nothing`() = runTest {
        val model = model()

        model.saveKey("   \n ", ProviderId.OPENAI)

        assertNull(secrets.get(ProviderId.OPENAI.keychainAccount))
        assertTrue(verified.isEmpty())
        assertEquals(VerifyState.Idle, model.state(ProviderId.OPENAI))
    }

    @Test
    fun `verifying with no key asks for one instead of calling out`() = runTest {
        val model = model()

        model.verify(ProviderId.OPENAI)

        assertTrue(verified.isEmpty())
        assertEquals(VerifyState.Failed(EngineSettingsViewModel.ADD_KEY_FIRST), model.state(ProviderId.OPENAI))
    }

    @Test
    fun `removeKey forgets the key and everything concluded about it`() = runTest {
        val model = model()
        model.saveKey("gsk_abc123", ProviderId.GROQ)
        assertEquals(VerifyState.Connected, model.state(ProviderId.GROQ))

        model.removeKey(ProviderId.GROQ)

        assertNull(secrets.get(ProviderId.GROQ.keychainAccount))
        assertFalse(model.hasKey(ProviderId.GROQ))
        assertEquals(VerifyState.Idle, model.state(ProviderId.GROQ))
    }

    // ── Which key blocks to show ─────────────────────────────────────────────

    @Test
    fun `providersInUse is transcription first, then cleanup`() = runTest {
        val model = model()

        model.setStt(SttEngine.GROQ)
        model.setCleanup(CleanupEngine.OPENAI)

        assertEquals(listOf(ProviderId.GROQ, ProviderId.OPENAI), model.providersInUse)
    }

    @Test
    fun `one provider on both sides is listed once`() = runTest {
        val model = model()

        model.setStt(SttEngine.OPENAI)
        model.setCleanup(CleanupEngine.OPENAI)

        assertEquals(listOf(ProviderId.OPENAI), model.providersInUse)
    }

    @Test
    fun `local speech with cloud cleanup still shows the cleanup provider`() = runTest {
        val model = model()

        model.setStt(SttEngine.LOCAL)
        model.setCleanup(CleanupEngine.GROQ)

        assertEquals(listOf(ProviderId.GROQ), model.providersInUse)
    }

    @Test
    fun `the fully local configuration shows no key blocks`() = runTest {
        val model = model()
        model.load()

        assertEquals(emptyList<ProviderId>(), model.providersInUse)
    }

    // ── Persistence ──────────────────────────────────────────────────────────

    @Test
    fun `engine choices are persisted the moment they are made`() = runTest {
        val model = model()

        model.setStt(SttEngine.GROQ)
        model.setCleanup(CleanupEngine.OPENAI)

        val stored = settings.current()
        assertEquals(SttEngine.GROQ, stored.stt)
        assertEquals(CleanupEngine.OPENAI, stored.cleanup)
    }

    @Test
    fun `load reads the stored engines and which keys exist`() = runTest {
        settings.update { it.copy(stt = SttEngine.OPENAI, cleanup = CleanupEngine.GROQ) }
        secrets.set(ProviderId.OPENAI.keychainAccount, "sk_stored")
        val model = model()

        model.load()

        assertEquals(SttEngine.OPENAI, model.stt)
        assertEquals(CleanupEngine.GROQ, model.cleanup)
        assertTrue(model.hasKey(ProviderId.OPENAI))
        assertFalse(model.hasKey(ProviderId.GROQ))
    }

    @Test
    fun `the key page comes from the core, per provider`() {
        val model = model()

        assertEquals("https://example.test/groq", model.keyPageUrl(ProviderId.GROQ))
        assertEquals("https://example.test/openai", model.keyPageUrl(ProviderId.OPENAI))
    }
}
