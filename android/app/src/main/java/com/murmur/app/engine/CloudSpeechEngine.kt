package com.murmur.app.engine

import app.murmur.core.CloudConfig
import app.murmur.core.CoreException
import app.murmur.core.transcribeCloud

/**
 * Groq or OpenAI, through `murmur-core` — the iOS twin of
 * `MurmurShared/Speech/CloudSpeechEngine.swift`.
 *
 * Cloud STT is one request over the whole recording rather than a stream, so this waits for the
 * session's 16 kHz mono samples and posts them when the microphone stops. There are no partial
 * results to report.
 *
 * The key inside [cfg] came straight from `EncryptedSharedPreferences` and goes straight into
 * the core. It is never copied anywhere else and never appears in an error.
 */
class CloudSpeechEngine(
    private val cfg: CloudConfig,
    /**
     * The core call, injectable because `libmurmur_core.so` cannot be loaded by a JVM test.
     */
    private val transcribe: suspend (List<Float>, CloudConfig, String) -> String = ::transcribeCloud,
) : SpeechEngine {

    override suspend fun transcribe(session: AudioSession, partial: (String) -> Unit): String {
        val samples = session.samples16kMono()
        return try {
            this.transcribe.invoke(samples.asList(), cfg, "")
        } catch (failure: CoreException) {
            // The core's own user-facing sentence — the same wording the Mac app shows.
            throw PipelineError.Cloud(failure.message ?: "Cloud transcription failed")
        }
    }
}
