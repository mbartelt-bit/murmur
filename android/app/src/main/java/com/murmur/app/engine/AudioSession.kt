package com.murmur.app.engine

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * One microphone session, from the moment recording starts to the moment something stops it.
 *
 * A [SpeechEngine] is handed exactly one of these per dictation, so only one component is ever
 * recording (design spec section 7.1). Task 2's `AudioRecorder` is the real implementation.
 *
 * The two engines use it differently on purpose:
 *  - the cloud engine awaits [samples16kMono] and posts the buffer to `murmur-core`;
 *  - the on-device `SpeechRecognizer` records for itself, so it only uses [levels] for the
 *    meter and [stop] to end listening.
 */
interface AudioSession {
    /** Microphone level, 0..1, for the meter. */
    val levels: Flow<Float>

    /** All 16 kHz mono samples of this session; completes when the session is stopped. */
    suspend fun samples16kMono(): FloatArray

    /** User tap, silence detector or the duration cap. Safe to call more than once. */
    fun stop()
}

/**
 * An [AudioSession] whose audio can be read more than once: the first [samples16kMono] call
 * awaits the microphone, every later one returns the same buffer without re-recording.
 *
 * iOS uses its equivalent to replay a failed cloud dictation into the on-device engine. On
 * Android the on-device recognizer cannot be handed a buffer at all (see [DictationPipeline]),
 * so this exists for the cloud path's own retries and for callers that need the audio twice.
 */
class ReplayableAudioSession(private val upstream: AudioSession) : AudioSession {
    private val mutex = Mutex()

    @Volatile
    private var captured: FloatArray? = null

    override val levels: Flow<Float> get() = upstream.levels

    override suspend fun samples16kMono(): FloatArray =
        captured ?: mutex.withLock {
            captured ?: upstream.samples16kMono().also { captured = it }
        }

    override fun stop() = upstream.stop()

    /** True once the audio has been captured and can be replayed without the microphone. */
    val isReplayable: Boolean get() = captured != null
}
