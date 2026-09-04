package com.murmur.app.audio

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import com.murmur.app.engine.AudioSession
import com.murmur.app.engine.PipelineError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Anywhere a microphone level (0..1) can be published for the meter.
 *
 * The two capture paths produce levels in completely different ways — [AudioRecorder] computes
 * the RMS of the samples it just read, while the on-device recognizer hands us a dB reading
 * through `onRmsChanged` — but the keyboard only ever wants one number, so both push into this.
 */
interface LevelSink {
    /** Publish one level reading, already clamped to 0..1. */
    fun push(level: Float)
}

/**
 * The microphone, for the cloud path: 16 kHz mono PCM16 in, float samples and a level meter out.
 *
 * `murmur-core`'s cloud STT takes one buffer for the whole utterance, so this accumulates every
 * sample of a dictation and hands the lot over when something stops it — a tap, the silence
 * detector, or the 120 s cap. The on-device recognizer never uses this class; it records for
 * itself (see `SpeechEngines.localSession`), which is what keeps exactly one component on the
 * microphone per dictation.
 *
 * Nothing here logs: not the samples, not the levels, not the buffer size.
 */
class AudioRecorder(
    private val recorderFactory: () -> AudioRecord = ::openMicrophone,
    /** The dictation cap from the spec; past it the recorder stops itself. */
    private val maxDurationMs: Long = 120_000L,
) : AudioSession, LevelSink {

    private val _levels = MutableStateFlow(0f)
    override val levels: Flow<Float> = _levels.asStateFlow()

    /** Completed exactly once, with everything captured, when the session ends. */
    private val captured = CompletableDeferred<FloatArray>()

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    /** Guards [record], [running] and [stopRequested] — the reader and the caller share them. */
    private val lock = Any()
    private var record: AudioRecord? = null
    private var running = false
    private var stopRequested = false
    private var startAttempted = false
    private var reader: Job? = null

    /** Only the reader coroutine touches these. */
    private val chunks = mutableListOf<FloatArray>()
    private var total = 0

    private val maxSamples: Int = (SAMPLE_RATE * maxDurationMs / 1000L).toInt()

    /**
     * Opens the microphone and starts the reader. Idempotent, and a no-op once [stop] has run.
     *
     * @throws PipelineError.MicDenied when `AudioRecord` comes back uninitialised, which is what
     *   happens when `RECORD_AUDIO` was never granted (the app asks for it; an input method
     *   cannot show the dialog).
     */
    fun start() {
        synchronized(lock) {
            if (startAttempted || stopRequested) return
            startAttempted = true
        }
        val opened = try {
            recorderFactory()
        } catch (denied: SecurityException) {
            finish()
            throw PipelineError.MicDenied
        }
        if (opened.state != AudioRecord.STATE_INITIALIZED) {
            opened.release()
            finish()
            throw PipelineError.MicDenied
        }
        opened.startRecording()
        synchronized(lock) {
            record = opened
            running = true
            reader = scope.launch { read(opened) }
        }
    }

    /** Every sample of this session, once something has stopped it. Starts the microphone. */
    override suspend fun samples16kMono(): FloatArray {
        start()
        return captured.await()
    }

    /** A tap, the silence detector, the cap, or the keyboard going away. Safe to call twice. */
    override fun stop() {
        val neverStarted = synchronized(lock) {
            if (stopRequested) return
            stopRequested = true
            running = false
            // Waking the blocking read here rather than waiting for it to fill keeps the stop
            // instant. Held under the lock so it cannot race the reader's release().
            record?.let { runCatching { it.stop() } }
            reader == null
        }
        if (neverStarted) finish()
    }

    override fun push(level: Float) {
        _levels.value = level.coerceIn(0f, 1f)
    }

    /**
     * The blocking read loop. PCM16 in, float -1..1 out, one RMS reading per read, and the cap
     * enforced by sample count so no clock is needed.
     */
    private fun read(source: AudioRecord) {
        val shorts = ShortArray(minBufferSizeBytes() / 2)
        try {
            while (true) {
                val live = synchronized(lock) { if (running) source else null } ?: break
                val n = live.read(shorts, 0, shorts.size)
                if (n <= 0) {
                    // Negative is an error code (including the read that races our own stop);
                    // zero only happens on a non-blocking read, which this is not.
                    if (n < 0) break else continue
                }
                var sum = 0.0
                val floats = FloatArray(n)
                for (i in 0 until n) {
                    val sample = shorts[i] / 32768f
                    floats[i] = sample
                    sum += (sample * sample).toDouble()
                }
                chunks += floats
                total += n
                push(sqrt(sum / n).toFloat())
                if (total >= maxSamples) {
                    stop()
                    break
                }
            }
        } finally {
            synchronized(lock) {
                running = false
                record = null
                runCatching { source.release() }
            }
            finish()
        }
    }

    /** Concatenates what was captured and completes the session, at most once. */
    private fun finish() {
        if (captured.isCompleted) return
        val all = FloatArray(total)
        var at = 0
        for (chunk in chunks) {
            chunk.copyInto(all, at)
            at += chunk.size
        }
        chunks.clear()
        _levels.value = 0f
        captured.complete(all)
    }

    companion object {
        /** What `murmur-core` and every cloud STT endpoint want. */
        const val SAMPLE_RATE = 16_000

        /** Big enough that a slow reader cannot drop words; ~256 ms at 16 kHz mono PCM16. */
        const val MIN_BUFFER_BYTES = 8192

        private fun minBufferSizeBytes(): Int = max(
            AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            ),
            MIN_BUFFER_BYTES,
        )

        /**
         * The real microphone. `VOICE_RECOGNITION` is the source tuned for speech — no AGC
         * colouring, no music-oriented processing.
         *
         * Lint cannot see the permission check because it does not happen here: the app grants
         * `RECORD_AUDIO` during onboarding, the keyboard refuses to listen without it
         * (`Permissions.hasRecordAudio`), and if it is missing anyway the returned recorder is
         * `STATE_UNINITIALIZED`, which [start] turns into `PipelineError.MicDenied`.
         */
        @SuppressLint("MissingPermission")
        fun openMicrophone(): AudioRecord = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            minBufferSizeBytes(),
        )
    }
}
