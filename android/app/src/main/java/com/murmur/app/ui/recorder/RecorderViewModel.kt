package com.murmur.app.ui.recorder

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.history.TranscriptSource
import com.murmur.app.engine.AudioSession
import com.murmur.app.engine.SpeechEngines
import com.murmur.app.ime.Dictation
import com.murmur.app.ime.ImeController
import com.murmur.app.ime.ImeHost
import com.murmur.app.ime.TextSink
import kotlinx.coroutines.CoroutineScope

/**
 * "Try dictation", inside the app.
 *
 * It is deliberately not a second recorder: it is the *keyboard's* [ImeController] with a
 * different text sink, so the phases, the silence stop, the 120 s cap, the history-before-
 * commit order and the failure copy are all literally the same code the keyboard runs. The
 * only differences are where the words land (Compose state instead of an `InputConnection`)
 * and what history calls them ([TranscriptSource.IN_APP]).
 *
 * Nothing here logs; the committed text passes through [text] and is never printed.
 */
class RecorderViewModel(
    settings: SettingsStore,
    pipeline: Dictation,
    permissions: () -> Boolean,
    offlineAvailable: () -> Boolean,
    sessionFactory: (cloud: Boolean) -> AudioSession = { cloud ->
        if (cloud) SpeechEngines.cloudSession() else SpeechEngines.localSession()
    },
    /** Injected in tests; production uses the view model's own scope. */
    scope: CoroutineScope? = null,
) : ViewModel() {

    /** What has been committed so far — the read-only field on screen. */
    var text by mutableStateOf("")
        private set

    /** The Compose-backed sink. The same three operations the keys drive on the keyboard. */
    private val sink = object : TextSink {
        override fun commit(text: String) {
            this@RecorderViewModel.text += text
        }

        override fun deleteBackward() {
            this@RecorderViewModel.text = this@RecorderViewModel.text.dropLast(1)
        }

        override fun contextBefore(): String = this@RecorderViewModel.text
    }

    /**
     * There is no other keyboard to hand back to and no app to open — this *is* the app — so
     * the two switches and the permission trip are no-ops, and the globe key never draws.
     */
    private val host = object : ImeHost {
        override fun switchToPrevious() = Unit
        override fun switchToNext() = Unit
        override fun openApp() = Unit
        override val needsInputModeSwitch: Boolean = false
    }

    val controller = ImeController(
        settings = settings,
        pipeline = pipeline,
        sessionFactory = sessionFactory,
        permissions = permissions,
        offlineAvailable = offlineAvailable,
        scope = scope ?: viewModelScope,
        source = TranscriptSource.IN_APP,
    )

    /** The screen appeared: same entry point the keyboard uses, auto-listen included. */
    fun onShown() {
        controller.onShown(host = host, sink = sink)
    }

    /** The screen is going away. Stops everything and commits nothing. */
    fun onHidden() {
        controller.onHidden()
    }

    override fun onCleared() {
        controller.onHidden()
        super.onCleared()
    }
}
