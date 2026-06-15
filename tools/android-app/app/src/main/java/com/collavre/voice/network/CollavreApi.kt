package com.collavre.voice.network

import com.collavre.voice.network.model.AgentEvent
import com.collavre.voice.network.model.DeviceRequest
import com.collavre.voice.network.model.RespondRequest
import com.collavre.voice.network.model.VoiceCommandRequest
import com.collavre.voice.network.model.VoiceResponse
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Path
import retrofit2.http.Query

interface CollavreApi {

    @GET("api/v1/mobile/agent_events")
    suspend fun agentEvents(
        @Query("device_id") deviceId: String
    ): List<AgentEvent>

    @POST("api/v1/mobile/agent_events/{id}/respond")
    suspend fun respond(
        @Path("id") id: Long,
        @Body body: RespondRequest
    ): VoiceResponse

    // Mark a notice read once it has been spoken aloud, so the server (driven by
    // the inbox read pointer) stops re-emitting it. No body: auth is the bearer token.
    @POST("api/v1/mobile/agent_events/{id}/read")
    suspend fun markEventRead(@Path("id") id: Long): Response<Unit>

    @POST("api/v1/mobile/voice_commands")
    suspend fun voiceCommand(@Body body: VoiceCommandRequest): VoiceResponse

    @POST("api/v1/mobile/devices")
    suspend fun registerDevice(@Body body: DeviceRequest): Response<Unit>
}
