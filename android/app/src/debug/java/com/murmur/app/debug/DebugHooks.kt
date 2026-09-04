package com.murmur.app.debug

import android.content.Context
import android.content.Intent
import com.murmur.app.engine.AudioSession

/**
 * The debug build's back doors. Its twin in `src/release/java/` has the same signatures and
 * does nothing at all, so the release build cannot be talked into any of this — there is no
 * flag to flip and no fake to reach, because neither class is compiled into it.
 *
 * Today there is one door: [FakeAudioSession], so an emulator with no microphone can still run
 * a whole cloud dictation end to end.
 */
object DebugHooks {

    /**
     * Process-wide on purpose. The keyboard runs in the same process as [com.murmur.app.MainActivity]
     * but has no intent of its own, so the only way to arm it is a flag the activity sets:
     *
     * ```
     * adb shell am start -n com.murmur.app/.MainActivity -e murmurFakeAudio 1
     * ```
     */
    @Volatile
    private var fakeAudio = false

    /** Call from `MainActivity.onCreate` with the launch intent. `-e murmurFakeAudio 0` clears it. */
    fun noteLaunchIntent(intent: Intent?) {
        val raw = intent?.getStringExtra(EXTRA_FAKE_AUDIO) ?: return
        fakeAudio = raw == "1" || raw.equals("true", ignoreCase = true)
    }

    /**
     * Wraps the app's real session factory.
     *
     * Only the `cloud = true` side is ever replaced: the on-device recognizer opens the
     * microphone itself and cannot be handed a buffer, so there is nothing here for it (see
     * [FakeAudioSession]).
     */
    fun sessionFactory(
        context: Context,
        real: (cloud: Boolean) -> AudioSession,
    ): (cloud: Boolean) -> AudioSession = { cloud ->
        if (cloud && fakeAudio) FakeAudioSession(context) else real(cloud)
    }

    private const val EXTRA_FAKE_AUDIO = "murmurFakeAudio"
}
