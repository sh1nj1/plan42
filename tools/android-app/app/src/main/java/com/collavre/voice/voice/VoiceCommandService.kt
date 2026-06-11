package com.collavre.voice.voice

import com.collavre.voice.data.SettingsRepository
import com.collavre.voice.events.AgentEventRepository
import com.collavre.voice.network.model.SessionDto
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

enum class VoiceState { IDLE, LISTENING, THINKING, SPEAKING }

data class Exchange(val command: String, val reply: String)

/**
 * Single orchestration entry point for the voice loop: push-to-talk recognition
 * → server → spoken reply, and event-driven decision answers (speak summary →
 * auto-resume listening → relay the answer to the right event). Kept as one
 * injectable object so a future Bluetooth media-button receiver can drive the
 * exact same loop without going through the UI.
 */
@Singleton
class VoiceCommandService @Inject constructor(
    private val recognizer: SpeechRecognizerManager,
    private val tts: TtsManager,
    private val repository: AgentEventRepository,
    private val settings: SettingsRepository
) {
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private val _state = MutableStateFlow(VoiceState.IDLE)
    val state: StateFlow<VoiceState> = _state

    private val _exchanges = MutableStateFlow<List<Exchange>>(emptyList())
    val exchanges: StateFlow<List<Exchange>> = _exchanges

    private val _sessions = MutableStateFlow<List<SessionDto>>(emptyList())
    val sessions: StateFlow<List<SessionDto>> = _sessions

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError

    private var locale: String = SettingsRepository.DEFAULT_LOCALE
    private var pendingRespondEventId: Long? = null

    fun configure(locale: String, ttsRate: Float) {
        this.locale = locale
        tts.init(locale, ttsRate)
    }

    /** Toggle: cancel speaking/listening, or start a fresh push-to-talk turn. */
    fun pushToTalk() {
        when (_state.value) {
            VoiceState.SPEAKING -> { tts.stop(); _state.value = VoiceState.IDLE }
            VoiceState.LISTENING -> { recognizer.stop(); _state.value = VoiceState.IDLE }
            else -> { pendingRespondEventId = null; listen() }
        }
    }

    /** Speak the event's decision summary, then auto-listen for the answer. */
    fun respondToEvent(eventId: Long, summary: String) {
        speak(summary) {
            pendingRespondEventId = eventId
            listen()
        }
    }

    fun refreshSessions() {
        scope.launch {
            runCatching { repository.sessions() }.onSuccess { _sessions.value = it }
        }
    }

    private fun listen() {
        if (!recognizer.isAvailable) {
            _lastError.value = "Speech recognition unavailable"
            return
        }
        _state.value = VoiceState.LISTENING
        recognizer.start(
            locale = locale,
            onResult = { text -> onTranscript(text) },
            onError = { _state.value = VoiceState.IDLE }
        )
    }

    private fun onTranscript(text: String) {
        _state.value = VoiceState.THINKING
        val eventId = pendingRespondEventId
        pendingRespondEventId = null
        scope.launch {
            val result = runCatching {
                if (eventId != null) repository.respond(eventId, text)
                else repository.sendCommand(text)
            }
            result.onSuccess { resp ->
                addExchange(text, resp.reply)
                if (resp.speak) speak(resp.reply) else _state.value = VoiceState.IDLE
                refreshSessions()
            }.onFailure {
                _lastError.value = it.message
                _state.value = VoiceState.IDLE
            }
        }
    }

    private fun speak(text: String, onDone: (() -> Unit)? = null) {
        _state.value = VoiceState.SPEAKING
        tts.speak(text) {
            scope.launch {
                if (onDone != null) onDone() else _state.value = VoiceState.IDLE
            }
        }
    }

    private fun addExchange(command: String, reply: String) {
        _exchanges.value = (listOf(Exchange(command, reply)) + _exchanges.value).take(3)
    }
}
