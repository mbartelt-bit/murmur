package com.murmur.app.ime

import android.content.Intent
import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import com.murmur.app.MainActivity
import com.murmur.app.Permissions
import com.murmur.app.di.AppGraph
import com.murmur.app.engine.SpeechEngines
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/**
 * The Murmur keyboard.
 *
 * It runs in the app's own process, so the settings, the API keys and the history it uses are
 * literally the same objects the app uses (design spec section 7.2) — there is no IPC, no
 * duplicated store and no second copy of a key.
 *
 * Everything interesting is in [ImeController]; this class is the Android surface around it:
 * the three view-tree owners Compose needs, the input connection, and the two keyboard
 * switches. Nothing here logs.
 */
class MurmurInputMethodService :
    InputMethodService(),
    ImeHost,
    LifecycleOwner,
    ViewModelStoreOwner,
    SavedStateRegistryOwner {

    private val lifecycleRegistry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = lifecycleRegistry

    override val viewModelStore: ViewModelStore = ViewModelStore()

    private val savedStateController = SavedStateRegistryController.create(this)
    override val savedStateRegistry: SavedStateRegistry get() = savedStateController.savedStateRegistry

    /** The keyboard is on the main thread; the pipeline's own work moves itself off it. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private lateinit var controller: ImeController

    /**
     * Resolved per call rather than captured: `currentInputConnection` changes as the user
     * moves between fields, and a stale one silently drops the text.
     */
    private val sink = InputConnectionSink { currentInputConnection }

    override fun onCreate() {
        // Before the lifecycle leaves INITIALIZED, which is what the registry requires.
        savedStateController.performRestore(null)
        super.onCreate()
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)

        val graph = AppGraph.get(this)
        controller = ImeController(
            settings = graph.settings,
            pipeline = graph.pipeline.asDictation(),
            permissions = { Permissions.hasRecordAudio(this) },
            offlineAvailable = { SpeechEngines.isLocalAvailable(this) },
            scope = scope,
        )
    }

    override fun onCreateInputView(): View {
        moveToResumed()
        val view = ComposeInputView(this) { ImeView(controller) }
        view.installOwners(this)
        // The recomposer is found from the window's decor view, not from ours — without this
        // the keyboard dies with "ViewTreeLifecycleOwner not found from DecorView".
        window?.window?.decorView?.installOwners(this)
        return view
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        moveToResumed()
        controller.onShown(host = this, sink = sink)
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        // Switched away, or the field lost focus: stop everything, commit nothing.
        controller.onHidden()
    }

    /** 220 dp of keyboard is not worth taking the whole screen for in landscape. */
    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onDestroy() {
        controller.onHidden()
        scope.cancel()
        viewModelStore.clear()
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
        super.onDestroy()
    }

    // MARK: - ImeHost

    /**
     * Back to the keyboard the user came from. When Murmur was picked from Settings rather
     * than switched to, there is no previous one — then the next in the rotation is the way
     * back to typing.
     */
    override fun switchToPrevious() {
        val switched = runCatching { switchToPreviousInputMethod() }.getOrDefault(false)
        if (!switched) runCatching { switchToNextInputMethod(false) }
    }

    override fun switchToNext() {
        runCatching { switchToNextInputMethod(false) }
    }

    /**
     * Opens Murmur at the microphone step. An input method cannot show the runtime permission
     * dialog itself; the containing app can, and this is the only way there.
     */
    override fun openApp() {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(EXTRA_REQUEST_MIC, true)
        runCatching { startActivity(intent) }
    }

    override val needsInputModeSwitch: Boolean
        get() = runCatching { shouldOfferSwitchingToNextInputMethod() }.getOrDefault(false)

    /**
     * Compose only composes while the lifecycle is resumed, and an input method's is ours to
     * drive. Idempotent: the system starts the input view again on every field change.
     */
    private fun moveToResumed() {
        if (lifecycleRegistry.currentState == Lifecycle.State.RESUMED) return
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
    }

    companion object {
        /** Set on the launch intent so the app can jump straight to the microphone step. */
        const val EXTRA_REQUEST_MIC = "com.murmur.app.extra.REQUEST_MIC"
    }
}

/**
 * The real [TextSink]: the focused field, through its `InputConnection`.
 *
 * `newCursorPosition = 1` leaves the cursor after the committed text, which is what makes two
 * dictations in a row read as two sentences.
 */
class InputConnectionSink(private val connection: () -> InputConnection?) : TextSink {

    override fun commit(text: String) {
        connection()?.commitText(text, 1)
    }

    override fun deleteBackward() {
        connection()?.deleteSurroundingText(1, 0)
    }

    /** Enough context to tell "…the end of a word" from "…the end of a sentence. ". */
    override fun contextBefore(): String? =
        connection()?.getTextBeforeCursor(CONTEXT_CHARS, 0)?.toString()

    private companion object {
        const val CONTEXT_CHARS = 64
    }
}
