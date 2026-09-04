package com.murmur.app.engine

import app.murmur.core.CleanResult
import app.murmur.core.CloudConfig
import app.murmur.core.cleanText
import com.murmur.app.data.CleanupEngine
import com.murmur.app.data.ProviderId
import com.murmur.app.data.SecretStore
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.history.HistoryStore
import com.murmur.app.data.history.TranscriptEntity
import com.murmur.app.data.history.TranscriptSource
import kotlinx.coroutines.CancellationException

/** What a completed dictation produced. The flags are what a history row's banner reports. */
data class PipelineOutcome(
    /** Already written to history, with its id. */
    val transcript: TranscriptEntity,
    val usedCloudStt: Boolean,
    val usedCloudCleanup: Boolean,
)

/**
 * A microphone session in, a saved [TranscriptEntity] out.
 *
 * This is the one place the engine choice, the fallbacks and the history write live, so the
 * in-app recorder and the input method behave identically. The order matters: the row is
 * written *before* the caller gets the text, so a transcript can never be lost between here
 * and the text field.
 *
 * ### The five rules (the iOS twin's, with one deliberate difference)
 * 1. A cloud engine with no key stored is not an error — the user still gets their words, from
 *    the on-device recognizer.
 * 2. **Cloud failure does not silently retry on device here.** iOS replays the recorded samples
 *    into `SFSpeechRecognizer`/`SpeechAnalyzer`, which accept a buffer. Android's
 *    `SpeechRecognizer` records from the microphone itself and cannot be handed one, so a
 *    retry means asking the user to speak again. Instead this throws
 *    [PipelineError.Cloud] with `canRetryOnDevice` set from [offlineAvailable], and the
 *    keyboard offers "Try on device" — which calls back in with `forceLocal = true`.
 * 3. Silence writes nothing at all: no row, no clipboard, no commit.
 * 4. A cleanup config is built only when the cleanup engine is not `RULE`; the core falls back
 *    to its rules pass on any cloud failure, so cleanup cannot lose words.
 * 5. History first, always.
 */
class DictationPipeline(
    private val settings: SettingsStore,
    private val secrets: SecretStore,
    private val history: HistoryStore,
    private val localEngine: () -> SpeechEngine,
    private val cloudEngine: (CloudConfig) -> SpeechEngine,
    /** Whether this phone has an offline recognizer, for rule 2's "Try on device" offer. */
    private val offlineAvailable: () -> Boolean = { false },
    private val clean: suspend (String, CloudConfig?) -> CleanResult = ::cleanText,
) {

    /**
     * Runs one dictation to a saved transcript.
     *
     * @param forceLocal skips the cloud engine even when a key is stored — the keyboard's
     *   "Try on device" retry after a [PipelineError.Cloud] failure.
     */
    suspend fun run(
        session: AudioSession,
        source: TranscriptSource,
        partial: (String) -> Unit,
        forceLocal: Boolean = false,
    ): PipelineOutcome {
        val current = settings.current()

        // 1. Speech to text.
        var usedCloudStt = false
        val sttConfig = if (forceLocal) null else config(current.stt.provider)
        val raw = if (sttConfig != null) {
            try {
                cloudEngine(sttConfig).transcribe(session, partial).also { usedCloudStt = true }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                // 2. No silent on-device replay on Android — see the class comment.
                throw PipelineError.Cloud(
                    message = failure.message ?: "Cloud transcription failed",
                    canRetryOnDevice = offlineAvailable(),
                )
            }
        } else {
            localEngine().transcribe(session, partial)
        }

        // 3. Silence writes nothing at all.
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) throw PipelineError.Empty

        // 4. Cleanup. The core falls back to its rules engine on any cloud failure, so this
        //    call cannot fail and cannot lose words.
        val cleanupConfig =
            if (current.cleanup == CleanupEngine.RULE) null else config(current.cleanup.provider)
        val cleaned = clean(trimmed, cleanupConfig)
        val cleanedText = cleaned.clean.trim()

        // 5. History first, always.
        val saved = history.insert(
            TranscriptEntity(
                rawText = trimmed,
                cleanText = cleanedText.ifEmpty { trimmed },
                source = source.id,
            ),
        )
        return PipelineOutcome(
            transcript = saved,
            usedCloudStt = usedCloudStt,
            usedCloudCleanup = cleaned.usedCloud,
        )
    }

    /**
     * The stored key for [provider], wrapped for the core. `null` for the on-device engine and
     * for a provider whose key was never entered. The value is read here and passed straight
     * into the core call; it is never stored, logged or returned.
     */
    private fun config(provider: ProviderId?): CloudConfig? {
        if (provider == null) return null
        val key = secrets.get(provider.keychainAccount)?.trim()
        if (key.isNullOrEmpty()) return null
        return CloudConfig(provider = provider.core, apiKey = key)
    }
}
