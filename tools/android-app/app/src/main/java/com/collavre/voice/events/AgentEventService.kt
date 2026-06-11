package com.collavre.voice.events

import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import com.collavre.voice.data.SettingsRepository
import com.collavre.voice.voice.TtsManager
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Foreground service that keeps polling agent_events while the app is
 * backgrounded, surfacing each new event as a notification and (optionally)
 * speaking the decision summary. MVP transport is polling; FCM is a drop-in
 * replacement later (registration already wired via DevicesController).
 */
@AndroidEntryPoint
class AgentEventService : LifecycleService() {

    @Inject lateinit var repository: AgentEventRepository
    @Inject lateinit var settings: SettingsRepository
    @Inject lateinit var tts: TtsManager

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
            tts.init(cfg.locale, cfg.ttsRate)
            repository.poll().collectLatest { batch ->
                val speakEnabled = settings.snapshot().eventVoiceEnabled
                batch.forEach { event ->
                    Notifications.postEvent(this@AgentEventService, event)
                    if (speakEnabled && event.speak) tts.speak(event.summary)
                }
            }
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
