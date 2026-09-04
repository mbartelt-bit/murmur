package com.murmur.app.ui.settings

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import app.murmur.core.CloudConfig
import app.murmur.core.keyPageUrl
import app.murmur.core.verifyProvider
import com.murmur.app.data.CleanupEngine
import com.murmur.app.data.ProviderId
import com.murmur.app.data.SecretStore
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.SttEngine
import kotlinx.coroutines.CancellationException

/**
 * The engine and key state behind both the Settings screen and onboarding's engine step — the
 * phone's `src/components/EngineSettings.tsx`, and the twin of iOS's `EngineSettingsViewModel`.
 *
 * Nothing here holds a key longer than the call that needs it: [saveKey] puts it straight into
 * the [SecretStore] and [verify] reads it back, hands it to the core and drops it. [keyPresent]
 * is a boolean, never a value, so no screen and no log can show one.
 */
class EngineSettingsViewModel(
    private val settings: SettingsStore,
    private val secrets: SecretStore,
    /** One round trip to the provider. Injected so a test never opens a socket. */
    private val verifyKey: suspend (CloudConfig) -> Unit = { cfg -> verifyProvider(cfg) },
    /** The provider's key page, from the core so the Mac and the phone cannot drift apart. */
    private val keyPage: (ProviderId) -> String = { keyPageUrl(it.core) },
) : ViewModel() {

    /** Where a provider's key stands right now. [Failed] carries the core's own sentence. */
    sealed interface VerifyState {
        data object Idle : VerifyState
        data object Verifying : VerifyState
        data object Connected : VerifyState
        data class Failed(val message: String) : VerifyState
    }

    var stt by mutableStateOf(SttEngine.LOCAL)
        private set

    var cleanup by mutableStateOf(CleanupEngine.RULE)
        private set

    /** Whether a key is stored, per provider. Never the key itself. */
    var keyPresent by mutableStateOf<Map<ProviderId, Boolean>>(emptyMap())
        private set

    var verifyState by mutableStateOf<Map<ProviderId, VerifyState>>(emptyMap())
        private set

    /** The provider whose key is being saved, so its button can say "Connecting…". */
    var saving by mutableStateOf<ProviderId?>(null)
        private set

    /**
     * The cloud providers this configuration actually uses, transcription first — the same
     * rule as the desktop's `cloudProvidersInUse`, which exists so that Local speech with
     * OpenAI cleanup still shows the OpenAI key block.
     */
    val providersInUse: List<ProviderId>
        get() = listOfNotNull(stt.provider, cleanup.provider).distinct()

    /** Reads the stored engines and which keys exist. Call it when the screen appears. */
    suspend fun load() {
        val current = settings.current()
        stt = current.stt
        cleanup = current.cleanup
        keyPresent = ProviderId.entries.associateWith { !secrets.get(it.keychainAccount).isNullOrEmpty() }
    }

    fun state(provider: ProviderId): VerifyState = verifyState[provider] ?: VerifyState.Idle

    fun hasKey(provider: ProviderId): Boolean = keyPresent[provider] == true

    fun keyPageUrl(provider: ProviderId): String = keyPage(provider)

    // MARK: - Engine choice

    /**
     * Persisted the moment it is tapped: there is no Save button anywhere in Murmur, and the
     * keyboard reads the same DataStore directly.
     */
    suspend fun setStt(engine: SttEngine) {
        settings.update { it.copy(stt = engine) }
        stt = engine
    }

    suspend fun setCleanup(engine: CleanupEngine) {
        settings.update { it.copy(cleanup = engine) }
        cleanup = engine
    }

    // MARK: - Keys

    /**
     * Stores a pasted key and immediately verifies it, so "did that work?" is answered on the
     * same screen instead of at the start of the user's next dictation.
     *
     * A whitespace-only paste is not an error, just nothing: the field clears and the state is
     * unchanged.
     */
    suspend fun saveKey(key: String, provider: ProviderId) {
        val trimmed = key.trim()
        if (trimmed.isEmpty()) return

        saving = provider
        put(provider, VerifyState.Idle)
        try {
            secrets.set(provider.keychainAccount, trimmed)
            keyPresent = keyPresent + (provider to true)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            saving = null
            put(provider, VerifyState.Failed(describe(failure)))
            return
        }
        saving = null
        verify(provider)
    }

    /** Forgets the key and everything the app had concluded about it. */
    fun removeKey(provider: ProviderId) {
        runCatching { secrets.delete(provider.keychainAccount) }
        keyPresent = keyPresent + (provider to false)
        put(provider, VerifyState.Idle)
    }

    /**
     * One round trip to the provider. A rejected key is left in the store: the user may have
     * pasted a good key for the wrong provider, and deleting it behind their back would lose
     * the paste as well as the answer.
     */
    suspend fun verify(provider: ProviderId) {
        val key = secrets.get(provider.keychainAccount)?.trim()
        if (key.isNullOrEmpty()) {
            put(provider, VerifyState.Failed(ADD_KEY_FIRST))
            return
        }
        put(provider, VerifyState.Verifying)
        try {
            verifyKey(CloudConfig(provider = provider.core, apiKey = key))
            put(provider, VerifyState.Connected)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            put(provider, VerifyState.Failed(describe(failure)))
        }
    }

    private fun put(provider: ProviderId, state: VerifyState) {
        verifyState = verifyState + (provider to state)
    }

    companion object {
        /**
         * iOS's `Copy.addKeyFirst`. It lives here rather than in `strings.xml` because it is
         * one of the `VerifyState.Failed` messages, and those come from the core as plain
         * sentences — a view model with no `Context` cannot resolve a resource.
         */
        const val ADD_KEY_FIRST = "Add your key first."

        /**
         * The core's user-facing sentence — `CoreException`'s message is exactly what the
         * desktop shows. A class name never reaches the screen, and neither does anything
         * derived from the key.
         */
        internal fun describe(failure: Throwable): String = failure.message ?: GENERIC

        private const val GENERIC = "That didn't work. Check the key and try again."
    }
}
