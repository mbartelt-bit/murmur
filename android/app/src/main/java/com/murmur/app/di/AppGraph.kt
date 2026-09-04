package com.murmur.app.di

import android.annotation.SuppressLint
import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.preferencesDataStore
import com.murmur.app.data.EncryptedSecretStore
import com.murmur.app.data.SecretStore
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.history.HistoryDatabase
import com.murmur.app.data.history.HistoryStore
import com.murmur.app.debug.DebugHooks
import com.murmur.app.engine.AudioSession
import com.murmur.app.engine.DictationPipeline
import com.murmur.app.engine.SpeechEngines

/** The one settings file. `preferencesDataStore` refuses to open it twice in a process. */
private val Context.settingsDataStore: DataStore<Preferences> by preferencesDataStore(name = "murmur.settings")

/**
 * The app's object graph, hand-rolled — one small singleton instead of a dependency-injection
 * framework, because there are four objects and one process.
 *
 * The input method service builds it the same way the activity does, which is exactly what
 * makes them share the settings, the keys and the history (design spec section 7.2).
 *
 * Everything is lazy, so `get` from the IME costs nothing until the first dictation.
 */
class AppGraph private constructor(context: Context) {
    private val app: Context = context.applicationContext

    val settings: SettingsStore by lazy { SettingsStore(app.settingsDataStore) }

    val secrets: SecretStore by lazy { EncryptedSecretStore(app) }

    val history: HistoryStore by lazy { HistoryStore(HistoryDatabase.file(app).transcripts()) }

    /**
     * The microphone for one dictation, for both the keyboard and the in-app recorder.
     *
     * `cloud = true` wants the real recorder (the cloud engine needs a buffer); `false` wants
     * the recognizer's session, because Android's on-device `SpeechRecognizer` records for
     * itself. Exactly one component records per dictation (design spec section 7.1).
     *
     * It lives on the graph rather than in each caller's default so a debug build has one
     * place to swap in the emulator's fake audio; in a release build `DebugHooks` is the no-op
     * twin and this is the real factory, unchanged.
     */
    val sessionFactory: (cloud: Boolean) -> AudioSession by lazy {
        DebugHooks.sessionFactory(app) { cloud ->
            if (cloud) SpeechEngines.cloudSession() else SpeechEngines.localSession()
        }
    }

    val pipeline: DictationPipeline by lazy {
        DictationPipeline(
            settings = settings,
            secrets = secrets,
            history = history,
            localEngine = { SpeechEngines.local(app) },
            cloudEngine = SpeechEngines::cloud,
            offlineAvailable = { SpeechEngines.isLocalAvailable(app) },
        )
    }

    companion object {
        // The graph holds the *application* context and lives as long as the process does, so
        // there is nothing here to leak; lint cannot tell the two kinds of Context apart.
        @SuppressLint("StaticFieldLeak")
        @Volatile
        private var instance: AppGraph? = null

        fun get(context: Context): AppGraph =
            instance ?: synchronized(this) {
                instance ?: AppGraph(context).also { instance = it }
            }
    }
}
