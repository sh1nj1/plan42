package com.collavre.voice.permission

import android.Manifest
import android.os.Build

/** Single source of truth for the runtime permissions the loop needs. */
object PermissionManager {

    fun required(): Array<String> = buildList {
        add(Manifest.permission.RECORD_AUDIO)
        // POST_NOTIFICATIONS is the only other runtime-dangerous one we need;
        // FOREGROUND_SERVICE_DATA_SYNC is install-time (declared in manifest).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.POST_NOTIFICATIONS)
        }
    }.toTypedArray()
}
