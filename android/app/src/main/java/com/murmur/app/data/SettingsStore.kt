package com.murmur.app.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

/**
 * Reads and writes [Settings]. The iOS twin is `SettingsStore` over the App Group defaults;
 * the shape is the same so the two apps stay easy to reason about together.
 *
 * Nothing secret is ever written here — API keys live in [SecretStore] only.
 */
class SettingsStore(private val dataStore: DataStore<Preferences>) {

    /** Every change, starting with the current value. */
    val settings: Flow<Settings> = dataStore.data.map { it.toSettings() }

    suspend fun current(): Settings = settings.first()

    /** Mutate and persist in one transaction; the [settings] flow emits the result. */
    suspend fun update(change: (Settings) -> Settings) {
        dataStore.edit { prefs ->
            val next = change(prefs.toSettings())
            prefs[Keys.STT] = next.stt.id
            prefs[Keys.CLEANUP] = next.cleanup.id
            prefs[Keys.AUTO_STOP] = next.autoStopOnSilence
            prefs[Keys.COPY_CLIPBOARD] = next.copyToClipboard
            prefs[Keys.AUTO_LISTEN] = next.autoListen
            prefs[Keys.RETURN_PREV] = next.returnToPreviousKeyboard
            prefs[Keys.ONBOARDING_DONE] = next.onboardingComplete
        }
    }

    private object Keys {
        val STT = stringPreferencesKey("stt")
        val CLEANUP = stringPreferencesKey("cleanup")
        val AUTO_STOP = booleanPreferencesKey("auto_stop")
        val COPY_CLIPBOARD = booleanPreferencesKey("copy_clipboard")
        val AUTO_LISTEN = booleanPreferencesKey("auto_listen")
        val RETURN_PREV = booleanPreferencesKey("return_prev")
        val ONBOARDING_DONE = booleanPreferencesKey("onboarding_done")
    }

    /**
     * Field by field, with a default for every one, so a store written by an older build (or
     * one carrying an engine id this build has never heard of) still loads instead of throwing
     * the user's settings away.
     */
    private fun Preferences.toSettings(): Settings {
        val defaults = Settings()
        return Settings(
            stt = SttEngine.fromId(this[Keys.STT]),
            cleanup = CleanupEngine.fromId(this[Keys.CLEANUP]),
            autoStopOnSilence = this[Keys.AUTO_STOP] ?: defaults.autoStopOnSilence,
            copyToClipboard = this[Keys.COPY_CLIPBOARD] ?: defaults.copyToClipboard,
            autoListen = this[Keys.AUTO_LISTEN] ?: defaults.autoListen,
            returnToPreviousKeyboard = this[Keys.RETURN_PREV] ?: defaults.returnToPreviousKeyboard,
            onboardingComplete = this[Keys.ONBOARDING_DONE] ?: defaults.onboardingComplete,
        )
    }
}
