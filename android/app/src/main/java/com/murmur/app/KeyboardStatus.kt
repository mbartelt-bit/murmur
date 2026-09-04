package com.murmur.app

import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.view.inputmethod.InputMethodInfo
import android.view.inputmethod.InputMethodManager
import com.murmur.app.ime.MurmurInputMethodService

/**
 * Where the Murmur keyboard stands with the system, and the two trips that change it.
 *
 * Android publishes no notification for "the user added a keyboard", so everything here is a
 * question asked again rather than an answer waited for — onboarding polls [isEnabled] once a
 * second while its keyboard step is on screen. The iOS twin is `KeyboardStatus`, which has the
 * same problem for the same reason.
 */
object KeyboardStatus {

    /** Whether Murmur is in the user's enabled keyboard list. */
    fun isEnabled(context: Context): Boolean {
        val manager = context.getSystemService(InputMethodManager::class.java) ?: return false
        val enabled = runCatching { manager.enabledInputMethodList }.getOrNull() ?: return false
        return enabled.any { it.matchesMurmur(context.packageName) }
    }

    /**
     * The system's keyboard list, where Murmur is turned on. This is the only screen that can
     * do it — an app cannot add its own input method.
     */
    fun openImeSettings(context: Context) {
        val intent = Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
    }

    /**
     * The keyboard switcher — the second half of turning Murmur on, and the one the user
     * forgets: an enabled keyboard still has to be picked once for the field in front of them.
     */
    fun showImePicker(context: Context) {
        val manager = context.getSystemService(InputMethodManager::class.java) ?: return
        runCatching { manager.showInputMethodPicker() }
    }

    /**
     * Our service, by package and class rather than by the flattened id: the id's short form
     * depends on how the class name and the package line up, which is not something a check
     * this small should have an opinion about.
     */
    private fun InputMethodInfo.matchesMurmur(packageName: String): Boolean =
        this.packageName == packageName && serviceName == MurmurInputMethodService::class.java.name
}
