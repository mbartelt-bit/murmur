package com.murmur.app.engine

/**
 * Anything that turns one microphone session into one string.
 *
 * The implementations — Task 2's `LocalSpeechEngine` (Android's on-device `SpeechRecognizer`)
 * and `CloudSpeechEngine` (`AudioRecord` plus `murmur-core`) — are interchangeable behind
 * this, which is what lets [DictationPipeline] choose between them without knowing either.
 *
 * `partial` is called with the best guess so far, on whatever thread the engine happens to be
 * on; the keyboard hops to the main thread itself.
 */
interface SpeechEngine {
    suspend fun transcribe(session: AudioSession, partial: (String) -> Unit): String
}

/**
 * Everything that can stop a dictation, in the app's own vocabulary. Nothing here ever carries
 * an API key, and only the user's own words reach the UI through [PipelineOutcome], never a log.
 */
sealed class PipelineError(message: String) : Exception(message) {

    /** `RECORD_AUDIO` is not granted. Only the containing app can ask for it. */
    object MicDenied : PipelineError("Open Murmur to allow the microphone")

    /** No on-device recognizer and no cloud key: there is nothing to transcribe with. */
    object NoSpeechEngine : PipelineError("No speech engine is available")

    /**
     * A cloud transcription failed. [message] is the core's user-facing sentence.
     *
     * [canRetryOnDevice] is true when this phone has an offline recognizer, so the keyboard can
     * offer "Try on device" instead of losing the dictation.
     */
    class Cloud(message: String, val canRetryOnDevice: Boolean = false) : PipelineError(message)

    /** Nothing was said. The keyboard shows "Didn't catch that." and writes nothing. */
    object Empty : PipelineError("Didn't catch that.")
}
