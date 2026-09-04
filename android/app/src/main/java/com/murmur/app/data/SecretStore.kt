package com.murmur.app.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Where API keys live. Deliberately tiny: get, set, delete, and nothing that could log a value.
 *
 * A key leaves this abstraction only to be handed straight to a `murmur-core` call
 * (design spec section 10). Nothing here prints, logs or copies a value anywhere else, and no
 * key is ever written to DataStore, Room or a log.
 */
interface SecretStore {
    fun get(account: String): String?
    fun set(account: String, value: String)
    fun delete(account: String)
}

/**
 * The real store: `EncryptedSharedPreferences`, keyed by the desktop's account names
 * (`groq_api_key`, `openai_api_key`) so a future sync sees the same items.
 *
 * Both the preference names and their values are encrypted, with the master key held in the
 * Android keystore, so the file on disk carries neither the account names nor the keys.
 */
class EncryptedSecretStore internal constructor(
    /**
     * Lazy on purpose: opening the file unlocks a keystore-held master key, which is work the
     * app should do on the first key read, not while the object graph is being built.
     */
    openPrefs: () -> SharedPreferences,
) : SecretStore {

    constructor(context: Context) : this({ encryptedPrefs(context.applicationContext) })

    private val prefs: SharedPreferences by lazy(openPrefs)

    override fun get(account: String): String? = prefs.getString(account, null)

    override fun set(account: String, value: String) {
        prefs.edit().putString(account, value).apply()
    }

    override fun delete(account: String) {
        prefs.edit().remove(account).apply()
    }

    companion object {
        const val FILE_NAME = "murmur.secrets"

        /**
         * The real file. Only reachable on a device or emulator: it needs the `AndroidKeyStore`
         * JCE provider, which the JVM (and so Robolectric) does not have — `SecretStoreTest`
         * drives the store's own behaviour through the injectable constructor instead, and the
         * encryption itself is androidx's, exercised in the emulator run-through.
         */
        internal fun encryptedPrefs(context: Context): SharedPreferences =
            EncryptedSharedPreferences.create(
                context,
                FILE_NAME,
                MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
    }
}

/** A throwaway store for tests and previews. Nothing reaches disk. */
class InMemorySecretStore : SecretStore {
    private val values = mutableMapOf<String, String>()

    override fun get(account: String): String? = values[account]

    override fun set(account: String, value: String) {
        values[account] = value
    }

    override fun delete(account: String) {
        values.remove(account)
    }
}
