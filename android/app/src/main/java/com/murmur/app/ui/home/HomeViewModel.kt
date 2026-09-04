package com.murmur.app.ui.home

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import com.murmur.app.data.SecretStore
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.SttEngine
import com.murmur.app.data.history.HistoryStore
import com.murmur.app.data.history.TranscriptEntity
import kotlinx.coroutines.flow.Flow

/**
 * What the Home screen knows: is Murmur ready, and what did it write last.
 *
 * Home is the screen a user lands on every time, so it is also the app's standing health
 * check — a permission revoked in system settings months later shows up here as a chip with a
 * fix, not as a failed dictation. The iOS twin is `HomeViewModel`, minus the chips Android has
 * no equivalent for (speech permission, Full Access, the Action Button).
 */
class HomeViewModel(
    private val settings: SettingsStore,
    private val secrets: SecretStore,
    history: HistoryStore,
    private val micGranted: () -> Boolean,
    private val keyboardEnabled: () -> Boolean,
) : ViewModel() {

    /** The last three dictations, re-emitted the moment the keyboard writes one (spec §5). */
    val recent: Flow<List<TranscriptEntity>> = history.observeRecent(RECENT_COUNT)

    var mic by mutableStateOf(false)
        private set

    /** The dialog has been shown once, so a second denial is worth a trip to app settings. */
    var micAsked by mutableStateOf(false)

    var keyboardOn by mutableStateOf(false)
        private set

    var stt by mutableStateOf(SttEngine.LOCAL)
        private set

    /** Whether the chosen engine has what it needs — always true for the on-device one. */
    var engineReady by mutableStateOf(true)
        private set

    /** The row whose "Copied" check is showing, if any. */
    var copiedId by mutableStateOf<Long?>(null)

    /** Re-reads the permission, the keyboard and the engine. The list flows on its own. */
    suspend fun refresh() {
        mic = micGranted()
        keyboardOn = keyboardEnabled()
        val current = settings.current()
        stt = current.stt
        engineReady = current.stt.provider
            ?.let { !secrets.get(it.keychainAccount).isNullOrEmpty() } ?: true
    }

    fun onMicResult(granted: Boolean) {
        micAsked = true
        mic = granted
    }

    companion object {
        /** How many dictations Home shows (spec §5: "the last three dictations"). */
        const val RECENT_COUNT = 3
    }
}
