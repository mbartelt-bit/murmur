package com.murmur.app.engine

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import com.murmur.app.audio.LevelSink
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Android's own recognizer, offline when the phone has a model for the language.
 *
 * Unlike every other engine in the app this one owns the microphone itself: `SpeechRecognizer`
 * records, endpoints and transcribes in one go and cannot be handed a buffer. So the
 * [AudioSession] it is given is a `RecognizerSession` — a session with no audio in it, used only
 * to stop listening and to carry the level meter (`onRmsChanged` in dB, mapped to 0..1).
 *
 * Nothing here logs a partial, a result or an error string.
 */
class LocalSpeechEngine(
    context: Context,
    private val recognizerFactory: (Context) -> SpeechRecognizer? = SpeechEngines::onDeviceRecognizer,
    /**
     * How long a pause ends the utterance, or `null` to leave the endpointing entirely to the
     * recognizer (the keyboard's own silence detector then decides).
     */
    private val autoStopMs: Long? = 1_500L,
) : SpeechEngine {

    private val app: Context = context.applicationContext

    override suspend fun transcribe(session: AudioSession, partial: (String) -> Unit): String {
        val meter = session as? LevelSink
        val main = Handler(Looper.getMainLooper())

        // `SpeechRecognizer` must be created, started and destroyed on the thread that owns a
        // Looper — the main one. Its callbacks then arrive there too.
        return withContext(Dispatchers.Main.immediate) {
            suspendCancellableCoroutine { cont ->
                val recognizer = recognizerFactory(app)
                if (recognizer == null) {
                    cont.resumeWithException(PipelineError.NoSpeechEngine)
                    return@suspendCancellableCoroutine
                }

                val finished = AtomicBoolean(false)
                fun settle(resume: () -> Unit) {
                    if (!finished.compareAndSet(false, true)) return
                    runCatching { recognizer.destroy() }
                    (session as? RecognizerSession)?.clearStopHandler()
                    resume()
                }

                recognizer.setRecognitionListener(
                    listener(
                        partial = partial,
                        onLevel = { meter?.push(it) },
                        onResult = { text -> settle { cont.resume(text.trim()) } },
                        onError = { error -> settle { cont.resumeWithException(error) } },
                    ),
                )

                // A tap, the silence detector or the 120 s cap stops the session; for this
                // engine that means asking the recognizer to finish the utterance it has.
                (session as? RecognizerSession)?.onStop {
                    main.post { runCatching { recognizer.stopListening() } }
                }

                cont.invokeOnCancellation {
                    if (finished.compareAndSet(false, true)) {
                        main.post {
                            runCatching { recognizer.cancel() }
                            runCatching { recognizer.destroy() }
                        }
                        (session as? RecognizerSession)?.clearStopHandler()
                    }
                }

                try {
                    recognizer.startListening(intent())
                } catch (failure: Exception) {
                    settle { cont.resumeWithException(PipelineError.NoSpeechEngine) }
                }
            }
        }
    }

    private fun intent(): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        // Honoured on 28-30, where `createSpeechRecognizer` may still reach Google's servers;
        // on 31+ the on-device recognizer is offline by construction.
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        autoStopMs?.let {
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, it)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, it)
        }
    }

    companion object {
        /**
         * The whole of this engine's behaviour, in one object with no recognizer attached — a
         * fake `SpeechRecognizer` is not feasible on the JVM, so the tests build this and call
         * its callbacks directly.
         *
         * - `onPartialResults` → [partial] with the best guess so far.
         * - `onResults` → [onResult] with the first hypothesis.
         * - `onRmsChanged` → [onLevel], dB mapped to 0..1.
         * - "no match" and "speech timeout" are not failures: they mean silence, which the
         *   pipeline turns into `PipelineError.Empty` and the keyboard shows as
         *   "Didn't catch that." — so they resolve as an empty result.
         * - Missing permission is [PipelineError.MicDenied]; everything else — no model, busy,
         *   client error, network — is [PipelineError.NoSpeechEngine], the one thing the
         *   keyboard can act on (offer the cloud, or the offline-download deep link).
         */
        fun listener(
            partial: (String) -> Unit,
            onLevel: (Float) -> Unit,
            onResult: (String) -> Unit,
            onError: (PipelineError) -> Unit,
        ): RecognitionListener = object : RecognitionListener {

            override fun onReadyForSpeech(params: Bundle?) = Unit

            override fun onBeginningOfSpeech() = Unit

            override fun onRmsChanged(rmsdB: Float) = onLevel(levelFromDb(rmsdB))

            override fun onBufferReceived(buffer: ByteArray?) = Unit

            override fun onEndOfSpeech() = Unit

            override fun onError(error: Int) = when (error) {
                SpeechRecognizer.ERROR_NO_MATCH,
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
                -> onResult("")

                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> onError(PipelineError.MicDenied)

                else -> onError(PipelineError.NoSpeechEngine)
            }

            override fun onResults(results: Bundle?) = onResult(firstHypothesis(results).orEmpty())

            override fun onPartialResults(partialResults: Bundle?) {
                firstHypothesis(partialResults)?.let(partial)
            }

            override fun onEvent(eventType: Int, params: Bundle?) = Unit
        }

        /**
         * `onRmsChanged` reports roughly -2 dB (silence) to 10 dB (loud); the meter wants 0..1.
         */
        fun levelFromDb(rmsdB: Float): Float = ((rmsdB - QUIET_DB) / (LOUD_DB - QUIET_DB))
            .coerceIn(0f, 1f)

        private const val QUIET_DB = -2f
        private const val LOUD_DB = 10f

        private fun firstHypothesis(bundle: Bundle?): String? = bundle
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
    }
}
