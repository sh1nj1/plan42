package com.collavre.voice.network.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire models for the api/v1/mobile endpoints. The server owns intent resolution and
 * summarization; these mirror its JSON. Json is configured with
 * ignoreUnknownKeys so server-side additions never break the client.
 */

@Serializable
data class AgentEvent(
    val id: Long,
    val type: String,                       // approval_requested | agent_reply
    val title: String? = null,
    val summary: String,
    val speak: Boolean = true,
    @SerialName("requires_response") val requiresResponse: Boolean = false,
    @SerialName("topic_id") val topicId: Long? = null,
    @SerialName("created_at") val createdAt: String
) {
    val isApproval: Boolean get() = type == "approval_requested"
}

@Serializable
data class RespondRequest(
    @SerialName("device_id") val deviceId: String,
    val response: String
)

@Serializable
data class VoiceCommandRequest(
    val text: String,
    @SerialName("device_id") val deviceId: String,
    val locale: String? = null,
    @SerialName("session_id") val sessionId: String? = null
)

@Serializable
data class VoiceResponse(
    val reply: String,
    val speak: Boolean = true,
    val action: ActionDto? = null
)

@Serializable
data class ActionDto(
    val type: String? = null,
    @SerialName("comment_id") val commentId: Long? = null,
    @SerialName("topic_id") val topicId: Long? = null,
    @SerialName("agent_session_id") val agentSessionId: String? = null
)

@Serializable
data class DeviceRequest(
    val device: DeviceBody
)

@Serializable
data class DeviceBody(
    @SerialName("client_id") val clientId: String,
    @SerialName("device_type") val deviceType: String = "android",
    @SerialName("fcm_token") val fcmToken: String,
    @SerialName("app_version") val appVersion: String? = null
)
