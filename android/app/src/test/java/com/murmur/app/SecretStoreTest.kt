package com.murmur.app

import android.content.Context
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import com.murmur.app.data.EncryptedSecretStore
import com.murmur.app.data.InMemorySecretStore
import com.murmur.app.data.ProviderId
import com.murmur.app.data.SecretStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The same contract, twice: the fake the other tests inject, and the real store.
 *
 * [EncryptedSecretStore] is driven through its injectable constructor here, because
 * `EncryptedSharedPreferences` needs the `AndroidKeyStore` JCE provider and neither the JVM nor
 * Robolectric has one. What is under test is Murmur's own behaviour — which file, which
 * accounts, get/set/delete; the encryption is androidx's and is exercised on the emulator.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SecretStoreTest {

    private val context: Context = ApplicationProvider.getApplicationContext()

    /** Robolectric hands back the same instance for a name, so this survives across stores. */
    private fun prefs(): SharedPreferences =
        context.getSharedPreferences(EncryptedSecretStore.FILE_NAME, Context.MODE_PRIVATE)

    private fun encrypted(): SecretStore = EncryptedSecretStore { prefs() }

    private fun roundTrips(store: SecretStore) {
        assertNull(store.get(ProviderId.GROQ.keychainAccount))

        store.set(ProviderId.GROQ.keychainAccount, "gsk-test-value")
        store.set(ProviderId.OPENAI.keychainAccount, "sk-test-value")

        assertEquals("gsk-test-value", store.get(ProviderId.GROQ.keychainAccount))
        assertEquals("sk-test-value", store.get(ProviderId.OPENAI.keychainAccount))

        // Overwriting replaces rather than appends.
        store.set(ProviderId.GROQ.keychainAccount, "gsk-second")
        assertEquals("gsk-second", store.get(ProviderId.GROQ.keychainAccount))

        // Deleting one leaves the other alone.
        store.delete(ProviderId.GROQ.keychainAccount)
        assertNull(store.get(ProviderId.GROQ.keychainAccount))
        assertEquals("sk-test-value", store.get(ProviderId.OPENAI.keychainAccount))

        // Deleting something that was never there is not an error.
        store.delete(ProviderId.GROQ.keychainAccount)
        store.delete(ProviderId.OPENAI.keychainAccount)
        assertNull(store.get(ProviderId.OPENAI.keychainAccount))
    }

    @Test
    fun `in memory store round trips`() {
        roundTrips(InMemorySecretStore())
    }

    @Test
    fun `encrypted store round trips`() {
        roundTrips(encrypted())
    }

    @Test
    fun `the encrypted store persists across instances`() {
        encrypted().set(ProviderId.OPENAI.keychainAccount, "sk-persisted")

        assertEquals("sk-persisted", encrypted().get(ProviderId.OPENAI.keychainAccount))

        encrypted().delete(ProviderId.OPENAI.keychainAccount)
        assertNull(encrypted().get(ProviderId.OPENAI.keychainAccount))
    }

    @Test
    fun `keys live in their own file, not the app's default preferences`() {
        encrypted().set(ProviderId.GROQ.keychainAccount, "gsk-isolated")

        assertEquals("murmur.secrets", EncryptedSecretStore.FILE_NAME)
        assertNull(
            context.getSharedPreferences("com.murmur.app_preferences", Context.MODE_PRIVATE)
                .getString(ProviderId.GROQ.keychainAccount, null),
        )
    }

    @Test
    fun `the account names are the desktop's`() {
        assertEquals("groq_api_key", ProviderId.GROQ.keychainAccount)
        assertEquals("openai_api_key", ProviderId.OPENAI.keychainAccount)
    }
}
