package com.murmur.app

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.murmur.app.data.CleanupEngine
import com.murmur.app.data.Settings
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.SttEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SettingsStoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private lateinit var dataStore: DataStore<Preferences>
    private lateinit var store: SettingsStore

    @Before
    fun setUp() {
        val file = File(tmp.newFolder(), "settings.preferences_pb")
        dataStore = PreferenceDataStoreFactory.create(scope = scope) { file }
        store = SettingsStore(dataStore)
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    @Test
    fun `an empty store reads the defaults`() = runTest {
        val settings = store.current()

        assertEquals(SttEngine.LOCAL, settings.stt)
        assertEquals(CleanupEngine.RULE, settings.cleanup)
        assertTrue(settings.autoStopOnSilence)
        assertTrue(settings.autoListen)
        assertTrue(settings.returnToPreviousKeyboard)
        // Android commits straight into the field, so the clipboard copy is off by default.
        assertFalse(settings.copyToClipboard)
        assertFalse(settings.onboardingComplete)
    }

    @Test
    fun `every field round trips`() = runTest {
        val wanted = Settings(
            stt = SttEngine.GROQ,
            cleanup = CleanupEngine.OPENAI,
            autoStopOnSilence = false,
            copyToClipboard = true,
            autoListen = false,
            returnToPreviousKeyboard = false,
            onboardingComplete = true,
        )

        store.update { wanted }

        assertEquals(wanted, store.current())
        // A second store over the same file sees it too — this is how the IME reads the app's
        // choices.
        assertEquals(wanted, SettingsStore(dataStore).current())
    }

    @Test
    fun `update sees the current value and the flow emits the change`() = runTest {
        store.update { it.copy(stt = SttEngine.OPENAI) }
        store.update { it.copy(cleanup = CleanupEngine.GROQ) }

        val settings = store.settings.first()
        assertEquals(SttEngine.OPENAI, settings.stt)
        assertEquals(CleanupEngine.GROQ, settings.cleanup)
    }

    @Test
    fun `an engine id this build does not know falls back to the default`() = runTest {
        dataStore.edit {
            it[stringPreferencesKey("stt")] = "quantum"
            it[stringPreferencesKey("cleanup")] = "telepathy"
            it[booleanPreferencesKey("auto_listen")] = false
        }

        val settings = store.current()
        assertEquals(SttEngine.LOCAL, settings.stt)
        assertEquals(CleanupEngine.RULE, settings.cleanup)
        // The keys it did understand still survive.
        assertFalse(settings.autoListen)
    }

    @Test
    fun `a store missing keys keeps the defaults for them`() = runTest {
        dataStore.edit { it[stringPreferencesKey("stt")] = "groq" }

        val settings = store.current()
        assertEquals(SttEngine.GROQ, settings.stt)
        assertTrue(settings.autoStopOnSilence)
        assertTrue(settings.returnToPreviousKeyboard)
    }
}
