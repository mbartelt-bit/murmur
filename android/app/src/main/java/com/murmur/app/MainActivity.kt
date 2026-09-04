package com.murmur.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.lifecycle.lifecycleScope
import com.murmur.app.data.history.HistoryStore
import com.murmur.app.data.history.TranscriptEntity
import com.murmur.app.data.history.TranscriptSource
import com.murmur.app.debug.DebugHooks
import com.murmur.app.di.AppGraph
import com.murmur.app.ime.MurmurInputMethodService
import com.murmur.app.ui.Route
import com.murmur.app.ui.RootNav
import com.murmur.app.ui.SystemStatus
import com.murmur.app.ui.theme.MurmurTheme
import kotlinx.coroutines.launch

/**
 * The whole app, in one activity. Compose owns everything past [RootNav]; this class only
 * answers the two questions the system can ask before the UI exists: did the keyboard send the
 * user here for the microphone, and — in a debug build only — which screen should a screenshot
 * pass land on.
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // `-e murmurFakeAudio 1`: an emulator has no microphone, so a debug build can be told
        // to play a bundled WAV into the cloud path instead. A no-op in release, where neither
        // the flag nor the fake session is compiled in.
        DebugHooks.noteLaunchIntent(intent)
        val graph = AppGraph.get(this)

        // The keyboard's "Open Murmur" button. An input method cannot show the runtime
        // permission dialog, so this is the only way `RECORD_AUDIO` ever gets granted.
        val requestMic = intent?.getBooleanExtra(MurmurInputMethodService.EXTRA_REQUEST_MIC, false) == true
        val forcedRoute = debugScreen()
        if (forcedRoute != null) seedHistoryForScreenshots(graph.history)

        setContent {
            MurmurTheme {
                RootNav(
                    graph = graph,
                    micGranted = { SystemStatus.micGranted(this) },
                    keyboardEnabled = { SystemStatus.keyboardEnabled(this) },
                    localAvailable = { SystemStatus.localAvailable(this) },
                    forcedRoute = forcedRoute,
                    requestMic = requestMic,
                )
            }
        }
    }

    /**
     * `adb shell am start … --es murmurScreen home|history|settings|onboarding|recorder`.
     *
     * It exists so a screenshot pass can land on a known screen without driving the UI. A
     * release build reports no screen and cannot be talked into one.
     */
    private fun debugScreen(): String? {
        if (!BuildConfig.DEBUG) return null
        return Route.fromDebugName(intent?.getStringExtra(EXTRA_SCREEN))
    }

    /**
     * Two rows, so the History and Home screenshots show a real list. Debug builds launched
     * with `murmurScreen` only, and only while the database is empty, so a developer's own
     * dictations are never mixed in with these.
     */
    private fun seedHistoryForScreenshots(history: HistoryStore) {
        if (!BuildConfig.DEBUG) return
        lifecycleScope.launch {
            if (history.recent(1).isNotEmpty()) return@launch
            val now = System.currentTimeMillis()
            history.insert(
                TranscriptEntity(
                    rawText = "picking up milk and uh coffee on the way home",
                    cleanText = "Picking up milk and coffee on the way home.",
                    source = TranscriptSource.KEYBOARD.id,
                    createdAt = now - 90 * 60 * 1000L,
                ),
            )
            history.insert(
                TranscriptEntity(
                    rawText = "um so can you send me the deck before the meeting tomorrow",
                    cleanText = "Can you send me the deck before the meeting tomorrow?",
                    source = TranscriptSource.IN_APP.id,
                    createdAt = now - 4 * 60 * 1000L,
                ),
            )
        }
    }

    private companion object {
        const val EXTRA_SCREEN = "murmurScreen"
    }
}
