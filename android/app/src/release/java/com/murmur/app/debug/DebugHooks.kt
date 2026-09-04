package com.murmur.app.debug

import android.content.Context
import android.content.Intent
import com.murmur.app.engine.AudioSession

/**
 * The release twin of the debug build's [DebugHooks]: the same two entry points, both inert.
 *
 * Written as a second source set rather than a `BuildConfig.DEBUG` branch so that neither the
 * flag nor `FakeAudioSession` — nor the WAV it plays — exists in a shipped build at all.
 */
object DebugHooks {

    /** No debug extras in a release build. */
    fun noteLaunchIntent(intent: Intent?) = Unit

    /** The real microphone, always. */
    fun sessionFactory(
        @Suppress("UNUSED_PARAMETER") context: Context,
        real: (cloud: Boolean) -> AudioSession,
    ): (cloud: Boolean) -> AudioSession = real
}
