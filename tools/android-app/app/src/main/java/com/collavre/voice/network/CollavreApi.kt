package com.collavre.voice.network

import com.collavre.voice.network.model.AgentEvent
import com.collavre.voice.network.model.DeviceRequest
import com.collavre.voice.network.model.RespondRequest
import com.collavre.voice.network.model.SessionDto
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
        @Query("device_id") deviceId: String,
        @Query("since") since: String? = null
    ): List<AgentEvent>

    @POST("api/v1/mobile/agent_events/{id}/respond")
    suspend fun respond(
        @Path("id") id: Long,
        @Body body: RespondRequest
    ): VoiceResponse

    @POST("api/v1/mobile/voice_commands")
    suspend fun voiceCommand(@Body body: VoiceCommandRequest): VoiceResponse

    @GET("api/v1/mobile/sessions")
    suspend fun sessions(@Query("device_id") deviceId: String): List<SessionDto>

    @POST("api/v1/mobile/devices")
    suspend fun registerDevice(@Body body: DeviceRequest): Response<Unit>
}
