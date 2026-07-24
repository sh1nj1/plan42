package com.collavre.voice.events

import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import com.collavre.voice.data.SettingsRepository
import com.collavre.voice.voice.VoiceCommandService
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Foreground service that keeps the process alive so the shared voice loop in
 * VoiceCommandService can keep polling agent_events (read → listen → reply) and
 * posting notifications while the app is backgrounded. The loop is owned by the
 * singleton VoiceCommandService and started idempotently, so the Activity and
 * this service never double-poll. MVP transport is polling; FCM is a drop-in
 * replacement later (registration already wired via DevicesController).
 */
@AndroidEntryPoint
class AgentEventService : LifecycleService() {

    @Inject lateinit var repository: AgentEventRepository
    @Inject lateinit var settings: SettingsRepository
    @Inject lateinit var voice: VoiceCommandService

    override fun onCreate() {
        super.onCreate()
        Notifications.ensureChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        startAsForeground()

        // If push is configured, refresh the registered FCM token now that the
        // user is (likely) signed in — onNewToken alone can fire before sign-in.
        // No-op without google-services.json.
        PushRegistrar.fetchToken(this) { token ->
            lifecycleScope.launch { runCatching { repository.registerPushToken(token) } }
        }

        lifecycleScope.launch {
            val cfg = settings.snapshot()
            voice.configure(cfg.locale, cfg.ttsRate)
            voice.startEventLoop()
        }
        return START_STICKY
    }

    private fun startAsForeground() {
        val notification = Notifications.serviceNotification(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                Notifications.SERVICE_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(Notifications.SERVICE_NOTIFICATION_ID, notification)
        }
    }
}
