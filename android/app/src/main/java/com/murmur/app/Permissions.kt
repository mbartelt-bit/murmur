package com.murmur.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.content.ContextCompat

/**
 * `RECORD_AUDIO`, from both sides of the app.
 *
 * Only the containing app can show the runtime dialog — an input method has no activity to host
 * it — so the keyboard checks [hasRecordAudio] and, when it is false, shows "Open Murmur to
 * allow the microphone" instead of listening. [openAppSettings] is the way back for a user who
 * denied it permanently.
 */
object Permissions {

    fun hasRecordAudio(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    /** Murmur's own page in system settings, where the microphone toggle lives. */
    fun openAppSettings(context: Context) {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }
}
