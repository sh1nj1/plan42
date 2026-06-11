package com.collavre.voice.events

import com.collavre.voice.data.SettingsRepository
import com.collavre.voice.network.CollavreApi
import com.collavre.voice.network.model.AgentEvent
import com.collavre.voice.network.model.DeviceBody
import com.collavre.voice.network.model.DeviceRequest
import com.collavre.voice.network.model.RespondRequest
import com.collavre.voice.network.model.SessionDto
import com.collavre.voice.network.model.VoiceCommandRequest
import com.collavre.voice.network.model.VoiceResponse
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Owns talking to the api/v1/mobile endpoints: a polling cursor for agent_events plus the
 * voice_command / respond / sessions calls. The server assigns stable ref
 * numbers, so the cursor only governs which events are NEW — refs are preserved
 * across polls server-side.
 */
@Singleton
class AgentEventRepository @Inject constructor(
    private val api: CollavreApi,
    private val settings: SettingsRepository
) {
    /** One poll for new events; advances the persisted `since` cursor. */
    suspend fun pollOnce(): List<AgentEvent> {
        val cfg = settings.snapshot()
        if (cfg.token.isBlank()) return emptyList()
        val events = api.agentEvents(deviceId = cfg.deviceId, since = cfg.sinceCursor)
        events.maxByOrNull { it.createdAt }?.let { settings.setSinceCursor(it.createdAt) }
        return events
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

    suspend fun sessions(): List<SessionDto> {
        val cfg = settings.snapshot()
        if (cfg.token.isBlank()) return emptyList()
        return api.sessions(cfg.deviceId)
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
