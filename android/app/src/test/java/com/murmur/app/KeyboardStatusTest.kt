package com.murmur.app

import android.content.Context
import android.view.inputmethod.InputMethodInfo
import android.view.inputmethod.InputMethodManager
import androidx.test.core.app.ApplicationProvider
import com.murmur.app.ime.MurmurInputMethodService
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Whether Murmur is in the user's enabled keyboard list — the answer onboarding polls for and
 * the Home chip reports. Robolectric's shadow `InputMethodManager` stands in for the system's
 * list, so the check runs without a device and without a real input method installed.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class KeyboardStatusTest {

    private lateinit var context: Context
    private lateinit var manager: InputMethodManager

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        manager = context.getSystemService(InputMethodManager::class.java)
    }

    private fun ime(packageName: String, className: String, label: String) =
        InputMethodInfo(packageName, className, label, "")

    @Test
    fun `an empty keyboard list means Murmur is off`() {
        shadowOf(manager).setEnabledInputMethodInfoList(emptyList())

        assertFalse(KeyboardStatus.isEnabled(context))
    }

    @Test
    fun `Murmur in the enabled list means it is on`() {
        shadowOf(manager).setEnabledInputMethodInfoList(
            listOf(ime(context.packageName, MurmurInputMethodService::class.java.name, "Murmur")),
        )

        assertTrue(KeyboardStatus.isEnabled(context))
    }

    @Test
    fun `another keyboard being enabled is not Murmur`() {
        shadowOf(manager).setEnabledInputMethodInfoList(
            listOf(ime("com.google.android.inputmethod.latin", "com.android.inputmethod.latin.LatinIME", "Gboard")),
        )

        assertFalse(KeyboardStatus.isEnabled(context))
    }

    @Test
    fun `Murmur is found among other keyboards`() {
        shadowOf(manager).setEnabledInputMethodInfoList(
            listOf(
                ime("com.google.android.inputmethod.latin", "com.android.inputmethod.latin.LatinIME", "Gboard"),
                ime(context.packageName, MurmurInputMethodService::class.java.name, "Murmur"),
            ),
        )

        assertTrue(KeyboardStatus.isEnabled(context))
    }

    @Test
    fun `another app shipping a service with our class name does not count`() {
        shadowOf(manager).setEnabledInputMethodInfoList(
            listOf(ime("com.example.copycat", MurmurInputMethodService::class.java.name, "Murmur")),
        )

        assertFalse(KeyboardStatus.isEnabled(context))
    }

    @Test
    fun `a different service in our own package does not count`() {
        shadowOf(manager).setEnabledInputMethodInfoList(
            listOf(ime(context.packageName, "com.murmur.app.ime.SomeOtherService", "Murmur")),
        )

        assertFalse(KeyboardStatus.isEnabled(context))
    }
}
