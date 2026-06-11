package com.collavre.voice.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

data class AppSettings(
    val serverUrl: String,
    val token: String,
    val ttsRate: Float,
    val locale: String,
    val eventVoiceEnabled: Boolean,
    val deviceId: String,
    val sinceCursor: String?
)

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "collavre_voice")

@Singleton
class SettingsRepository @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private object Keys {
        val SERVER_URL = stringPreferencesKey("server_url")
        val TOKEN = stringPreferencesKey("token")
        val TTS_RATE = floatPreferencesKey("tts_rate")
        val LOCALE = stringPreferencesKey("locale")
        val EVENT_VOICE = booleanPreferencesKey("event_voice_enabled")
        val DEVICE_ID = stringPreferencesKey("device_id")
        val SINCE = stringPreferencesKey("since_cursor")
    }

    companion object {
        const val DEFAULT_SERVER_URL = "https://collavre.com"
        const val DEFAULT_LOCALE = "ko-KR"
    }

    val settings: Flow<AppSettings> = context.dataStore.data.map { it.toAppSettings() }

    suspend fun snapshot(): AppSettings = context.dataStore.data.first().toAppSettings()

    private fun Preferences.toAppSettings(): AppSettings = AppSettings(
        serverUrl = this[Keys.SERVER_URL] ?: DEFAULT_SERVER_URL,
        token = this[Keys.TOKEN].orEmpty(),
        ttsRate = this[Keys.TTS_RATE] ?: 1.0f,
        locale = this[Keys.LOCALE] ?: DEFAULT_LOCALE,
        eventVoiceEnabled = this[Keys.EVENT_VOICE] ?: true,
        deviceId = this[Keys.DEVICE_ID] ?: "",
        sinceCursor = this[Keys.SINCE]
    )

    /** Generates and persists a stable device id on first use. */
    suspend fun ensureDeviceId(): String {
        val existing = context.dataStore.data.first()[Keys.DEVICE_ID]
        if (!existing.isNullOrBlank()) return existing
        val id = "android-${UUID.randomUUID()}"
        context.dataStore.edit { it[Keys.DEVICE_ID] = id }
        return id
    }

    suspend fun update(
        serverUrl: String? = null,
        token: String? = null,
        ttsRate: Float? = null,
        locale: String? = null,
        eventVoiceEnabled: Boolean? = null
    ) {
        context.dataStore.edit { prefs ->
            serverUrl?.let { prefs[Keys.SERVER_URL] = it.trim().trimEnd('/') }
            token?.let { prefs[Keys.TOKEN] = it.trim() }
            ttsRate?.let { prefs[Keys.TTS_RATE] = it }
            locale?.let { prefs[Keys.LOCALE] = it }
            eventVoiceEnabled?.let { prefs[Keys.EVENT_VOICE] = it }
        }
    }

    suspend fun setSinceCursor(cursor: String) {
        context.dataStore.edit { it[Keys.SINCE] = cursor }
    }
}
