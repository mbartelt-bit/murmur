package com.murmur.app.debug

import android.content.Context
import androidx.annotation.RawRes
import com.murmur.app.R
import com.murmur.app.engine.AudioSession
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.DataInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.min
import kotlin.math.sqrt

/**
 * A microphone that is not a microphone: a bundled 16 kHz mono WAV, played into the pipeline as
 * if someone had just said it.
 *
 * **Debug builds only** — this whole source set is compiled out of release, and even in a debug
 * build nothing reaches it until [DebugHooks] has seen `murmurFakeAudio=1` on a launch intent.
 *
 * ### What it can and cannot prove
 * It stands in for [com.murmur.app.audio.AudioRecorder], which is the **cloud** path's
 * microphone. The on-device path never uses an `AudioSession` for audio at all — Android's
 * `SpeechRecognizer` opens the microphone itself and cannot be handed a buffer (see
 * `DictationPipeline`'s class comment) — so this fake says nothing whatsoever about local
 * dictation. On an emulator with no audio input, local dictation cannot be exercised at all;
 * that is Task 6's device gate.
 *
 * What it does prove, headlessly: the recorder→engine handoff, the level meter, the silence
 * detector's auto-stop, `transcribeCloud` over the JNI boundary with real samples, cleanup,
 * the history write, and the commit into the focused field.
 *
 * The levels are a ramp rather than the real RMS of the file: speech-level readings for the
 * length of the clip, then silence, so [com.murmur.app.audio.SilenceDetector] ends the
 * "recording" on its own exactly the way a real pause does.
 */
class FakeAudioSession(
    private val context: Context,
    @RawRes private val clip: Int = R.raw.sample_dictation,
) : AudioSession {

    private val _levels = MutableStateFlow(0f)
    override val levels: Flow<Float> = _levels.asStateFlow()

    private val finished = CompletableDeferred<Unit>()

    /**
     * Decodes the clip, then plays a level ramp in real time until something stops the session
     * — the silence detector, a tap on the mic button, or the controller's 120 s cap.
     */
    override suspend fun samples16kMono(): FloatArray {
        val samples = decode()
        val clipMs = samples.size * 1000L / SAMPLE_RATE

        var elapsed = 0L
        while (!finished.isCompleted) {
            _levels.value = levelAt(elapsed, clipMs)
            delay(TICK_MS)
            elapsed += TICK_MS
            // Belt and braces: if nothing is watching the meter (no silence detector, no
            // tapping user), end the session rather than looping forever.
            if (elapsed > clipMs + TAIL_MS) stop()
        }
        _levels.value = 0f
        return samples
    }

    override fun stop() {
        finished.complete(Unit)
    }

    /**
     * Speech while the clip is playing, silence afterwards.
     *
     * The speech readings wobble around 0.2 — comfortably over `SilenceDetector`'s 0.015
     * threshold — and the first 200 ms ramp up the way a real utterance does, so the meter on
     * screen looks like a voice rather than a square wave.
     */
    private fun levelAt(elapsedMs: Long, clipMs: Long): Float = when {
        elapsedMs >= clipMs -> 0f
        elapsedMs < RAMP_MS -> 0.2f * elapsedMs / RAMP_MS
        else -> 0.18f + 0.08f * sqrt((elapsedMs % 700L) / 700f)
    }

    /**
     * The `data` chunk of a 16-bit PCM mono RIFF file, as floats in -1..1.
     *
     * Chunks are walked rather than assuming the header is 44 bytes: `afconvert` writes the
     * audio at offset 4096, behind padding, which a fixed offset would read as noise.
     */
    private fun decode(): FloatArray {
        val bytes = context.resources.openRawResource(clip).use { stream ->
            DataInputStream(stream).readBytes()
        }
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        require(bytes.size > 12 && String(bytes, 0, 4, Charsets.US_ASCII) == "RIFF") {
            "sample_dictation.wav is not a RIFF file"
        }

        var at = 12
        while (at + 8 <= bytes.size) {
            val id = String(bytes, at, 4, Charsets.US_ASCII)
            val size = buffer.getInt(at + 4)
            val body = at + 8
            if (id == "data") {
                val length = min(size, bytes.size - body).coerceAtLeast(0)
                val samples = FloatArray(length / 2)
                for (i in samples.indices) {
                    samples[i] = buffer.getShort(body + i * 2) / 32768f
                }
                return samples
            }
            // Chunk bodies are word-aligned; an odd size is followed by a pad byte.
            at = body + size + (size and 1)
        }
        error("sample_dictation.wav has no data chunk")
    }

    private companion object {
        const val SAMPLE_RATE = 16_000
        const val TICK_MS = 100L
        const val RAMP_MS = 200L

        /** Long enough for `SilenceDetector`'s 1.5 s hangover to fire before this does. */
        const val TAIL_MS = 3_000L
    }
}
