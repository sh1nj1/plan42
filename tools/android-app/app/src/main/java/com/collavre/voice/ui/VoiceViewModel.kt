package com.collavre.voice.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.collavre.voice.data.AppSettings
import com.collavre.voice.data.SettingsRepository
import com.collavre.voice.voice.VoiceCommandService
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class VoiceViewModel @Inject constructor(
    private val voice: VoiceCommandService,
    private val settings: SettingsRepository
) : ViewModel() {

    val state = voice.state
    val messages = voice.messages
    val activeEventId = voice.activeEventId
    val speakingEventId = voice.speakingEventId
    val exchanges = voice.exchanges
    val lastError = voice.lastError
    val partialTranscript = voice.partialTranscript

    val settingsState: StateFlow<AppSettings?> =
        settings.settings.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    init {
        viewModelScope.launch {
            settings.ensureDeviceId()
            val cfg = settings.snapshot()
            voice.configure(cfg.locale, cfg.ttsRate)
            voice.startEventLoop()
        }
    }

    fun pushToTalk() = voice.pushToTalk()

    /** Tap a listed message: mark it the selection (highlight). */
    fun selectMessage(eventId: Long) = voice.selectMessage(eventId)

    /** Play/stop toggle on a row: read that message aloud, or stop if already reading. */
    fun playMessage(eventId: Long) = voice.playMessage(eventId)

    /** Reply button / notification tap carrying an event id: listen and reply to it. */
    fun replyTo(eventId: Long) = voice.replyTo(eventId)

    fun saveSettings(
        serverUrl: String,
        token: String,
        ttsRate: Float,
        locale: String,
        eventVoiceEnabled: Boolean
    ) {
        viewModelScope.launch {
            settings.update(
                serverUrl = serverUrl,
                token = token,
                ttsRate = ttsRate,
                locale = locale,
                eventVoiceEnabled = eventVoiceEnabled
            )
            voice.configure(locale, ttsRate)
        }
    }
}
