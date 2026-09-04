package com.murmur.app.audio

import kotlin.math.max

/**
 * Decides when the user has stopped talking, from nothing but the level meter.
 *
 * Two rules, both from the Mac app and identical to the iOS twin
 * (`MurmurShared/Audio/SilenceDetector.swift`): a pause only counts once real speech has been
 * heard (so it never fires on the silence *before* the first word), and the pause has to last
 * [hangoverMs] (so a breath between sentences is not the end of a dictation).
 *
 * Pure Kotlin on purpose — the recorder feeds it live levels, the tests feed it a script, and
 * neither needs a microphone.
 */
class SilenceDetector(
    /** RMS below this counts as silence. 0.015 is roughly a quiet room on a phone mic. */
    private val threshold: Float = 0.015f,
    /** How much continuous silence ends the dictation. */
    private val hangoverMs: Long = 1_500L,
    /** How much speech has to be heard first, so a door slam cannot end a dictation. */
    private val minSpeechMs: Long = 400L,
) {

    /** Total above-threshold audio heard so far, accumulated across pauses. */
    private var speechHeardMs = 0L

    /** Timestamp of the first below-threshold reading of the current pause. */
    private var silenceStartedMs: Long? = null
    private var lastMs: Long? = null
    private var fired = false

    /**
     * Feed one level reading. Returns `true` exactly once, on the first reading that completes
     * [minSpeechMs] of speech followed by [hangoverMs] of silence; every call after that is
     * `false`, so the caller can keep feeding while it winds the recording down.
     *
     * The interval since the previous reading is credited to the current one, so the first ever
     * call contributes no time at all.
     */
    fun feed(level: Float, atMs: Long): Boolean {
        if (fired) return false
        val elapsed = max(0L, atMs - (lastMs ?: atMs))
        lastMs = atMs

        if (level >= threshold) {
            speechHeardMs += elapsed
            silenceStartedMs = null
            return false
        }

        val started = silenceStartedMs ?: atMs
        silenceStartedMs = started
        if (speechHeardMs < minSpeechMs || atMs - started < hangoverMs) return false
        fired = true
        return true
    }
}
