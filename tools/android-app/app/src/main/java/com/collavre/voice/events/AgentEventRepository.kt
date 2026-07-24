package com.collavre.voice.events

import com.collavre.voice.data.SettingsRepository
import com.collavre.voice.network.CollavreApi
import com.collavre.voice.network.model.AgentEvent
import com.collavre.voice.network.model.DeviceBody
import com.collavre.voice.network.model.DeviceRequest
import com.collavre.voice.network.model.RespondRequest
import com.collavre.voice.network.model.VoiceCommandRequest
import com.collavre.voice.network.model.VoiceResponse
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Owns talking to the api/v1/mobile endpoints: polling agent_events plus the
 * voice_command (cold mic → Inbox#Main) and respond (reply to a specific
 * message) calls.
 *
 * There is NO client cursor. The server emits the full set of currently-relevant
 * events each poll — unread Inbox#System notices (gated by the inbox read pointer)
 * and every still-pending approval. Dedup is the consumer's job: VoiceCommandService
 * keeps an in-memory "already spoken" set so a re-emitted event is not re-read,
 * while a crash/restart correctly re-surfaces anything still unread/undecided
 * (at-least-once). A fetch-time `since` high-water-mark could burn past an event
 * that was fetched but never spoken, losing it forever — hence its removal.
 */
@Singleton
class AgentEventRepository @Inject constructor(
    private val api: CollavreApi,
    private val settings: SettingsRepository
) {
    /** One poll for the current set of events to surface. */
    suspend fun pollOnce(): List<AgentEvent> {
        val cfg = settings.snapshot()
        if (cfg.token.isBlank()) return emptyList()
        return api.agentEvents(deviceId = cfg.deviceId)
    }

    /** Continuous poll loop; emits each batch of newly-surfaced events. */
    fun poll(intervalMs: Long = 5_000L): Flow<List<AgentEvent>> = flow {
        while (true) {
            val batch = runCatching { pollOnce() }.getOrDefault(emptyList())
            if (batch.isNotEmpty()) emit(batch)
            delay(intervalMs)
        }
    }

    suspend fun sendCommand(text: String): VoiceResponse {
        val cfg = settings.snapshot()
        return api.voiceCommand(
            VoiceCommandRequest(text = text, deviceId = cfg.deviceId, locale = cfg.locale)
        )
    }

    suspend fun respond(eventId: Long, response: String): VoiceResponse {
        val cfg = settings.snapshot()
        return api.respond(eventId, RespondRequest(deviceId = cfg.deviceId, response = response))
    }

    /**
     * Mark a notice read once it has actually been spoken aloud. The server gates
     * emission on the inbox read pointer, so this is what stops a heard message from
     * being read again — and skipping it (crash before this lands) means the message
     * stays unread and is re-read next poll (at-least-once delivery).
     */
    suspend fun markRead(eventId: Long) {
        if (settings.snapshot().token.isBlank()) return
        api.markEventRead(eventId)
    }

    /**
     * Registers the FCM token against the user's Device record so the server can
     * push agent events. No-op until the user is signed in (the server needs the
     * bearer token to attach the device to a user); re-run on every app open and
     * on token rotation. Server upserts by fcm_token, so repeat calls are cheap.
     */
    suspend fun registerPushToken(token: String) {
        val cfg = settings.snapshot()
        if (cfg.token.isBlank() || token.isBlank()) return
        val clientId = settings.ensureDeviceId()
        api.registerDevice(
            DeviceRequest(DeviceBody(clientId = clientId, fcmToken = token))
        )
    }
}
