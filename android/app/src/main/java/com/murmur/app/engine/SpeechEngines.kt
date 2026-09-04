package com.murmur.app.engine

import android.content.Context
import android.os.Build
import android.speech.SpeechRecognizer
import app.murmur.core.CloudConfig
import com.murmur.app.audio.AudioRecorder
import com.murmur.app.audio.LevelSink
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Which engine, and which microphone session goes with it.
 *
 * The two paths take the microphone in incompatible ways — the on-device recognizer records for
 * itself, the cloud engine needs a buffer — so the session is chosen together with the engine
 * and exactly one component ever records per dictation (design spec section 7.1).
 */
object SpeechEngines {

    /** Android's recognizer, offline where the phone has a model. Pair with [localSession]. */
    fun local(context: Context): SpeechEngine = LocalSpeechEngine(context)

    /** Groq or OpenAI through `murmur-core`. Pair with [cloudSession]. */
    fun cloud(cfg: CloudConfig): SpeechEngine = CloudSpeechEngine(cfg)

    /**
     * Whether this phone can transcribe without the network — what the keyboard's
     * "Try on device" offer and the onboarding engine step both key off.
     */
    fun isLocalAvailable(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        } else {
            SpeechRecognizer.isRecognitionAvailable(context)
        }

    /**
     * The best recognizer this phone has, or `null` when it has none.
     *
     * API 31+ has a real on-device one. On 28-30 the only recognizer is the installed speech
     * service, which `EXTRA_PREFER_OFFLINE` asks to stay local.
     */
    fun onDeviceRecognizer(context: Context): SpeechRecognizer? = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context) ->
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)

        SpeechRecognizer.isRecognitionAvailable(context) -> SpeechRecognizer.createSpeechRecognizer(context)

        else -> null
    }

    /** The session for [local]: no audio of its own, just stop and the level meter. */
    fun localSession(): AudioSession = RecognizerSession()

    /** The session for [cloud]: the real microphone. */
    fun cloudSession(): AudioSession = AudioRecorder()
}

/**
 * The [AudioSession] for the on-device path.
 *
 * `SpeechRecognizer` records, endpoints and transcribes by itself, so this session holds no
 * audio at all: [stop] forwards to the recognizer's `stopListening`, and [push] carries the dB
 * meter readings it reports. [samples16kMono] is empty by construction — the cloud engine is
 * never given one of these.
 */
class RecognizerSession : AudioSession, LevelSink {

    private val _levels = MutableStateFlow(0f)
    override val levels: Flow<Float> = _levels.asStateFlow()

    private val lock = Any()
    private var handler: (() -> Unit)? = null
    private var stopped = false

    /**
     * Installs what [stop] should do. Called by [LocalSpeechEngine] once its recognizer exists;
     * if the session was already stopped in that gap, the action runs immediately.
     */
    internal fun onStop(action: () -> Unit) {
        val already = synchronized(lock) {
            handler = action
            stopped
        }
        if (already) action()
    }

    /** Forgets the recognizer once it is destroyed, so a late [stop] cannot touch it. */
    internal fun clearStopHandler() {
        synchronized(lock) { handler = null }
    }

    override suspend fun samples16kMono(): FloatArray = FloatArray(0)

    override fun stop() {
        val action = synchronized(lock) {
            stopped = true
            handler
        }
        action?.invoke()
    }

    override fun push(level: Float) {
        _levels.value = level.coerceIn(0f, 1f)
    }
}
