package com.murmur.app.ime

import com.murmur.app.audio.SilenceDetector
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.SttEngine
import com.murmur.app.data.history.TranscriptSource
import com.murmur.app.engine.AudioSession
import com.murmur.app.engine.DictationPipeline
import com.murmur.app.engine.PipelineError
import com.murmur.app.engine.PipelineOutcome
import com.murmur.app.engine.SpeechEngines
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.coroutines.coroutineContext

/** The six things the keyboard can be showing. The iOS twin is `RecorderViewModel.Phase`. */
sealed interface ImePhase {

    /** Waiting for a mic tap: auto-listen is off, or a dictation has finished. */
    data object Idle : ImePhase

    /** `RECORD_AUDIO` is missing. Only the containing app can ask for it. */
    data object NeedsPermission : ImePhase

    /** Live. [level] is the meter 0..1, [elapsedMs] the time since the microphone opened. */
    data class Listening(val level: Float, val elapsedMs: Long) : ImePhase

    /** Microphone closed, engine still working; [partial] is its best guess so far. */
    data class Transcribing(val partial: String) : ImePhase

    /** The text is in history and has been committed into the field. */
    data class Done(val clean: String) : ImePhase

    /** [canRetryOnDevice] turns the strip's "Try on device" button on. */
    data class Failed(val message: String, val canRetryOnDevice: Boolean) : ImePhase
}

/** Whatever the keyboard is typing into. `InputConnectionSink` is the real one. */
interface TextSink {
    fun commit(text: String)
    fun deleteBackward()

    /** The text just before the cursor, for the leading-space decision. `null` when unknown. */
    fun contextBefore(): String?
}

/** The input method service, as the controller sees it. */
interface ImeHost {
    /** Back to whatever keyboard the user came from, after a finished dictation. */
    fun switchToPrevious()

    /** The globe key: the next input method in the user's rotation. */
    fun switchToNext()

    /** Opens Murmur at the microphone step — the only way to grant `RECORD_AUDIO`. */
    fun openApp()

    /** Whether the system wants us to draw a globe key at all. */
    val needsInputModeSwitch: Boolean
}

/**
 * The controller's view of [DictationPipeline] — a port, so the tests can hand it a fake
 * without a microphone, a database or `libmurmur_core.so`. [asDictation] is the real adapter.
 */
interface Dictation {
    suspend fun run(
        session: AudioSession,
        source: TranscriptSource,
        partial: (String) -> Unit,
        forceLocal: Boolean,
    ): PipelineOutcome
}

/** The production [Dictation]: the real pipeline, unchanged. */
fun DictationPipeline.asDictation(): Dictation = object : Dictation {
    override suspend fun run(
        session: AudioSession,
        source: TranscriptSource,
        partial: (String) -> Unit,
        forceLocal: Boolean,
    ): PipelineOutcome = this@asDictation.run(session, source, partial, forceLocal)
}

/**
 * The whole keyboard, minus the pixels: one dictation from the moment the keyboard appears to
 * the moment its words are in the user's text field and Gboard is back.
 *
 * Everything that needs a microphone, a clock, an input connection or a real wait is injected,
 * so the auto-listen path, the 120 s cap, the silence stop and the commit all run in
 * milliseconds under JUnit with no hardware. The iOS twin is `RecorderViewModel`; the phases
 * are deliberately the same five plus [ImePhase.NeedsPermission], which iOS handles with a
 * system prompt the keyboard cannot show.
 *
 * Nothing here logs. Partials, transcripts and the committed text pass through this object and
 * are never printed; API keys never reach it at all — the pipeline reads them straight from
 * `EncryptedSharedPreferences` into the core call.
 */
class ImeController(
    private val settings: SettingsStore,
    private val pipeline: Dictation,
    /**
     * The microphone for one dictation. `cloud = true` wants the real recorder (the cloud
     * engine needs a buffer); `false` wants the recognizer's session, because Android's
     * on-device `SpeechRecognizer` records for itself. Exactly one component records per
     * dictation (design spec section 7.1).
     */
    private val sessionFactory: (cloud: Boolean) -> AudioSession = { cloud ->
        if (cloud) SpeechEngines.cloudSession() else SpeechEngines.localSession()
    },
    private val permissions: () -> Boolean,
    /** Whether this phone can transcribe offline — the "Try on device" offer. */
    private val offlineAvailable: () -> Boolean,
    private val clock: () -> Long = System::currentTimeMillis,
    private val scope: CoroutineScope,
    private val maxDurationMs: Long = 120_000,
) {

    private val _phase = MutableStateFlow<ImePhase>(ImePhase.Idle)
    val phase: StateFlow<ImePhase> = _phase.asStateFlow()

    private val _showsGlobe = MutableStateFlow(false)

    /** Whether to draw the globe key. Known only once the service has shown us. */
    val showsGlobe: StateFlow<Boolean> = _showsGlobe.asStateFlow()

    private var host: ImeHost? = null
    private var sink: TextSink? = null

    private var dictationJob: Job? = null
    private var afterJob: Job? = null
    private var session: AudioSession? = null

    private var startedAt = 0L
    private var lastLevel = 0f
    private var lastPartial = ""

    /**
     * Set the moment a dictation's words are committed, cleared when the keyboard goes away.
     *
     * `commitText` makes some apps restart the input session, which calls `onStartInputView`
     * again — without this, auto-listen would immediately open the microphone for a second
     * dictation the user never asked for. One auto-listen per appearance; the mic key is
     * always there for another.
     */
    private var autoListenSpent = false

    // MARK: - Appearing and disappearing

    /**
     * The keyboard is on screen. Starts listening straight away when auto-listen is on, which
     * is the default and what makes the whole round trip globe → speak → done.
     *
     * Safe to call again mid-dictation: some apps restart the input session while we are
     * listening (or right after we commit), and that must not interrupt or repeat anything.
     */
    fun onShown(host: ImeHost, sink: TextSink) {
        this.host = host
        this.sink = sink
        _showsGlobe.value = host.needsInputModeSwitch
        if (dictationJob?.isActive == true) return
        if (!permissions()) {
            _phase.value = ImePhase.NeedsPermission
            return
        }
        if (_phase.value is ImePhase.NeedsPermission) _phase.value = ImePhase.Idle
        if (autoListenSpent) return
        scope.launch {
            if (settings.current().autoListen) startListening()
        }
    }

    /**
     * The keyboard is gone — switched away, or the field lost focus. Everything stops and
     * nothing is committed: half a sentence typed into a field the user has left is worse
     * than a lost dictation, and the audio is still in history if the pipeline got that far.
     */
    fun onHidden() {
        dictationJob?.cancel()
        dictationJob = null
        afterJob?.cancel()
        afterJob = null
        // Cancel first, then release the microphone: the pipeline is suspended inside the
        // cancelled job, so completing the session cannot make it commit on the way out.
        session?.stop()
        session = null
        autoListenSpent = false
        lastPartial = ""
        lastLevel = 0f
        _phase.value = ImePhase.Idle
        host = null
        sink = null
    }

    // MARK: - One dictation

    /** The mic key, or auto-listen. A no-op while a dictation is already running. */
    fun startListening() {
        start(forceLocal = false)
    }

    /** The strip's "Try on device" button, after a cloud failure. A fresh on-device session. */
    fun retryOnDevice() {
        start(forceLocal = true)
    }

    private fun start(forceLocal: Boolean) {
        if (dictationJob?.isActive == true) return
        if (!permissions()) {
            _phase.value = ImePhase.NeedsPermission
            return
        }
        afterJob?.cancel()
        afterJob = null
        dictationJob = scope.launch { dictate(forceLocal) }
    }

    /**
     * Ends the recording: the user tapped, the silence detector fired, or the cap ran out.
     * Idempotent, and a no-op once the microphone is already closed.
     *
     * Stopping the session is all it takes — the engine inside the pipeline sees the audio
     * end and finishes on its own, which is what carries us into [ImePhase.Done].
     */
    fun stop() {
        if (_phase.value !is ImePhase.Listening) return
        _phase.value = ImePhase.Transcribing(lastPartial)
        session?.stop()
    }

    private suspend fun dictate(forceLocal: Boolean) {
        val current = settings.current()
        // The engine choice and the microphone go together: cloud STT needs a buffer, the
        // on-device recognizer refuses one. The pipeline picks the matching engine from the
        // same setting, so the two can never disagree.
        val cloud = !forceLocal && current.stt != SttEngine.LOCAL
        val session = sessionFactory(cloud)
        this.session = session

        startedAt = clock()
        lastLevel = 0f
        lastPartial = ""
        _phase.value = ImePhase.Listening(level = 0f, elapsedMs = 0L)

        // The silence detector belongs to the cloud path only: the on-device recognizer
        // endpoints for itself through EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, and
        // two things racing to end the same utterance would cut words off.
        val silence = if (cloud && current.autoStopOnSilence) SilenceDetector() else null

        val levelJob = scope.launch { meter(session, silence) }
        val tickJob = scope.launch { tick() }
        // The hard cap, so a keyboard left open in a pocket cannot record forever.
        val capJob = scope.launch {
            delay(maxDurationMs)
            stop()
        }

        try {
            val outcome = pipeline.run(session, TranscriptSource.KEYBOARD, ::notePartial, forceLocal)
            deliver(outcome, returnToPrevious = current.returnToPreviousKeyboard)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            fail(failure)
        } finally {
            levelJob.cancel()
            tickJob.cancel()
            capJob.cancel()
            this.session = null
        }
    }

    /** Meter readings, straight from whichever session owns the microphone. */
    private suspend fun meter(session: AudioSession, silence: SilenceDetector?) {
        session.levels.collect { level ->
            val now = clock()
            lastLevel = level
            if (_phase.value is ImePhase.Listening) {
                _phase.value = ImePhase.Listening(level = level, elapsedMs = now - startedAt)
            }
            if (silence != null && silence.feed(level, now)) stop()
        }
    }

    /**
     * The elapsed counter. Levels alone would leave the timer frozen through a long pause,
     * and it stops itself at the cap so nothing can tick forever.
     */
    private suspend fun tick() {
        while (coroutineContext.isActive) {
            delay(TICK_MS)
            val elapsed = clock() - startedAt
            if (elapsed >= maxDurationMs) return
            if (_phase.value is ImePhase.Listening) {
                _phase.value = ImePhase.Listening(level = lastLevel, elapsedMs = elapsed)
            }
        }
    }

    /**
     * A volatile result from the engine. Like iOS, it is only shown once the microphone is
     * closed — while listening the strip belongs to the level meter.
     */
    private fun notePartial(text: String) {
        lastPartial = text
        if (_phase.value is ImePhase.Transcribing) _phase.value = ImePhase.Transcribing(text)
    }

    // MARK: - Delivery

    /**
     * History was already written by the pipeline — this is everything after it.
     *
     * The text lands with a single trailing space so the next word does not run into it, and
     * with a leading one when the cursor is sitting straight after a word: dictating twice in
     * a row should read as a sentence, not as onerunontrainwreck.
     */
    private fun deliver(outcome: PipelineOutcome, returnToPrevious: Boolean) {
        val clean = outcome.transcript.cleanText
        val sink = this.sink ?: return
        _phase.value = ImePhase.Done(clean)

        val before = sink.contextBefore()
        val needsLeadingSpace = !before.isNullOrEmpty() && !before.last().isWhitespace()
        sink.commit(if (needsLeadingSpace) " $clean " else "$clean ")
        autoListenSpent = true

        if (!returnToPrevious) return
        val host = this.host ?: return
        afterJob = scope.launch {
            // Long enough that the committed text is on screen before the keyboards swap, short
            // enough that it still feels like one gesture.
            delay(RETURN_DELAY_MS)
            host.switchToPrevious()
        }
    }

    /** The keyboard's own words for a pipeline failure, mirroring `RecorderViewModel.describe`. */
    private fun fail(failure: Throwable) {
        when (failure) {
            is PipelineError.Empty -> {
                _phase.value = ImePhase.Failed(EMPTY_MESSAGE, canRetryOnDevice = false)
                // Nothing to decide and nothing to read twice: the keyboard clears itself and
                // waits for another tap rather than leaving an error sitting there.
                afterJob = scope.launch {
                    delay(EMPTY_RESET_MS)
                    if (_phase.value == ImePhase.Failed(EMPTY_MESSAGE, false)) {
                        _phase.value = ImePhase.Idle
                    }
                }
            }

            is PipelineError.Cloud -> _phase.value = ImePhase.Failed(
                message = failure.message ?: CLOUD_MESSAGE,
                // Either source of truth will do: the pipeline probes the device too, and the
                // offer only has to be right about this phone having an offline recognizer.
                canRetryOnDevice = failure.canRetryOnDevice || offlineAvailable(),
            )

            is PipelineError.MicDenied -> _phase.value = ImePhase.NeedsPermission

            is PipelineError.NoSpeechEngine ->
                _phase.value = ImePhase.Failed(NO_ENGINE_MESSAGE, canRetryOnDevice = false)

            else -> _phase.value =
                ImePhase.Failed(failure.message ?: CLOUD_MESSAGE, canRetryOnDevice = false)
        }
    }

    // MARK: - Keys

    /**
     * The big button: start when idle, stop when listening, and — when the microphone was
     * never granted — the same trip to the app the strip's button offers.
     */
    fun tapMic() {
        when (_phase.value) {
            is ImePhase.Listening -> stop()
            is ImePhase.Transcribing -> Unit
            ImePhase.NeedsPermission -> openApp()
            else -> startListening()
        }
    }

    fun tapGlobe() {
        host?.switchToNext()
    }

    fun tapDelete() {
        sink?.deleteBackward()
    }

    fun tapSpace() {
        sink?.commit(" ")
    }

    fun tapReturn() {
        sink?.commit("\n")
    }

    /** The permission strip's button. */
    fun openApp() {
        host?.openApp()
    }

    companion object {
        /** The empty-result copy, the desktop's and iOS's, verbatim. */
        const val EMPTY_MESSAGE = "Didn't catch that."
        const val NO_ENGINE_MESSAGE =
            "On-device speech isn't available. Pick Groq or OpenAI in Settings."
        private const val CLOUD_MESSAGE = "Cloud transcription failed"

        private const val TICK_MS = 200L
        private const val RETURN_DELAY_MS = 400L
        private const val EMPTY_RESET_MS = 2_000L
    }
}
