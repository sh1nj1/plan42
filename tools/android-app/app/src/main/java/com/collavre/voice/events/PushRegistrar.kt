package com.collavre.voice.events

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging

/**
 * Bridges "is push even configured?" so the rest of the app can stay oblivious.
 *
 * Without a google-services.json, [FirebaseApp] never initializes, so every call
 * here short-circuits and the app keeps running on polling alone. Once the file
 * is shipped, [fetchToken] returns the current FCM token to register.
 */
object PushRegistrar {

    /** True only when Firebase credentials were baked into the build. */
    fun isConfigured(context: Context): Boolean =
        FirebaseApp.getApps(context).isNotEmpty()

    /** Best-effort current-token fetch; [onToken] is skipped when push is off. */
    fun fetchToken(context: Context, onToken: (String) -> Unit) {
        if (!isConfigured(context)) return
        FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
            if (!token.isNullOrBlank()) onToken(token)
        }
    }
}
