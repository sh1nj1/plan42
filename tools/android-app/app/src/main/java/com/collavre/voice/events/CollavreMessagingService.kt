package com.collavre.voice.events

import com.collavre.voice.data.SettingsRepository
import com.collavre.voice.network.model.AgentEvent
import com.collavre.voice.voice.TtsManager
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * FCM transport — the push counterpart of [AgentEventService]'s poll loop, and
 * the reason an approval can wake a pocketed phone instead of waiting for the
 * next poll. Only ever invoked when google-services.json is present; otherwise
 * Firebase never registers this service and polling carries the app.
 *
 * - [onNewToken]: keep the server's Device record current (so it knows where to push).
 * - [onMessageReceived]: turn a data push into the same notification + spoken
 *   summary the poll loop produces, reusing [Notifications] and [TtsManager].
 *
 * Server contract: push as a DATA message (not notification-only) so this fires
 * even in the background, with keys: event_id, type, title, summary,
 * requires_response, topic_id, created_at.
 */
@AndroidEntryPoint
class CollavreMessagingService : FirebaseMessagingService() {

    @Inject lateinit var repository: AgentEventRepository
    @Inject lateinit var settings: SettingsRepository
    @Inject lateinit var tts: TtsManager

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onNewToken(token: String) {
        scope.launch { runCatching { repository.registerPushToken(token) } }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val event = message.toAgentEvent() ?: return
        Notifications.ensureChannels(this)
        Notifications.postEvent(this, event)

        scope.launch {
            val cfg = settings.snapshot()
            if (cfg.eventVoiceEnabled && event.speak) {
                tts.init(cfg.locale, cfg.ttsRate)
                tts.speak(event.summary)
            }
        }
    }

    private fun RemoteMessage.toAgentEvent(): AgentEvent? {
        val summary = data["summary"] ?: notification?.body ?: return null
        val id = (data["event_id"] ?: data["id"])?.toLongOrNull() ?: return null
        return AgentEvent(
            id = id,
            type = data["type"] ?: "agent_reply",
            title = data["title"] ?: notification?.title,
            summary = summary,
            speak = data["speak"]?.toBooleanStrictOrNull() ?: true,
            requiresResponse = data["requires_response"]?.toBooleanStrictOrNull() ?: false,
            topicId = data["topic_id"]?.toLongOrNull(),
            createdAt = data["created_at"].orEmpty()
        )
    }
}
