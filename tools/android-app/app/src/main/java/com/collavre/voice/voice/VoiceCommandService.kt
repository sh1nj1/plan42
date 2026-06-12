package com.collavre.voice.voice

import android.content.Context
import com.collavre.voice.data.SettingsRepository
import com.collavre.voice.events.AgentEventRepository
import com.collavre.voice.events.Notifications
import com.collavre.voice.network.model.AgentEvent
import dagger.hilt.android.qualifiers.ApplicationContext
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
 * A message that needs the user's attention. Shown in the on-screen list (titled
 * "Creative#Topic") and queued for sequential read→reply. eventId is the
 * agent_event id we POST a reply back to; topicId is the thread it belongs to.
 */
data class VoiceMessage(
    val eventId: Long,
    val title: String,
    val text: String,
    val topicId: Long?,
    val createdAt: String
)

/**
 * Single orchestration entry point for the voice loop.
 *
 * Drives the spec's System-message flow: incoming agent events are listed and
 * queued; each is read aloud (TTS) then auto-listens for a spoken reply that is
 * relayed back to THAT message's topic. A plain mic press with no active message
 * starts a cold utterance routed to Inbox#Main. Arriving events never interrupt
 * an in-flight read/reply — they queue and are processed one at a time, so an
 * unanswered message simply gets no reply.
 *
 * Kept as one injectable singleton so the foreground service and the UI share
 * the exact same loop (and a future Bluetooth button can drive it too).
 */
@Singleton
class VoiceCommandService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val recognizer: SpeechRecognizerManager,
    private val tts: TtsManager,
    private val repository: AgentEventRepository,
    private val settings: SettingsRepository
) {
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private val _state = MutableStateFlow(VoiceState.IDLE)
    val state: StateFlow<VoiceState> = _state

    /** Latest messages that arrived, newest first — the on-screen list. */
    private val _messages = MutableStateFlow<List<VoiceMessage>>(emptyList())
    val messages: StateFlow<List<VoiceMessage>> = _messages

    /** The message currently being read / awaiting a reply (the "selection"). */
    private val _activeEventId = MutableStateFlow<Long?>(null)
    val activeEventId: StateFlow<Long?> = _activeEventId

    private val _exchanges = MutableStateFlow<List<Exchange>>(emptyList())
    val exchanges: StateFlow<List<Exchange>> = _exchanges

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError

    // Live transcript of the current utterance, surfaced straight from the recognizer.
    val partialTranscript: StateFlow<String> = recognizer.partial

    private var locale: String = SettingsRepository.DEFAULT_LOCALE
    private var pendingRespondEventId: Long? = null

    // FIFO of unread incoming messages; drained one at a time while IDLE.
    private val queue = ArrayDeque<VoiceMessage>()
    private val seen = mutableSetOf<Long>()

    @Volatile private var loopStarted = false

    fun configure(locale: String, ttsRate: Float) {
        this.locale = locale
        tts.init(locale, ttsRate)
    }

    /** Start the single poll → queue loop. Idempotent (Activity + Service both call it). */
    fun startEventLoop() {
        if (loopStarted) return
        loopStarted = true
        scope.launch {
            repository.poll().collect { batch ->
                val speakEnabled = settings.snapshot().eventVoiceEnabled
                batch.sortedBy { it.createdAt }.forEach { event -> ingest(event, speakEnabled) }
            }
        }
    }

    private fun ingest(event: AgentEvent, speakEnabled: Boolean) {
        if (!seen.add(event.id)) return
        val msg = VoiceMessage(
            eventId = event.id,
            title = event.title ?: "Collavre",
            text = event.summary,
            topicId = event.topicId,
            createdAt = event.createdAt
        )
        _messages.value = (listOf(msg) + _messages.value).take(20)
        Notifications.postEvent(context, event)
        if (speakEnabled && event.speak) {
            queue.addLast(msg)
            pump()
        }
    }

    /** Process the next queued message only when nothing else is in flight. */
    private fun pump() {
        if (_state.value != VoiceState.IDLE) return
        val msg = queue.removeFirstOrNull() ?: return
        readThenListen(msg)
    }

    /** Read a message aloud, auto-select it, then listen for a reply to its topic. */
    private fun readThenListen(msg: VoiceMessage) {
        recognizer.reset() // start the turn with a clean caption (drop prior utterance)
        _activeEventId.value = msg.eventId
        speak(msg.text) {
            // Heard it → mark read so the server stops re-emitting it. Done only
            // after TTS completes, so a crash mid-read leaves it unread to re-read.
            scope.launch { runCatching { repository.markRead(msg.eventId) } }
            pendingRespondEventId = msg.eventId
            listen()
        }
    }

    /** Tap a list row: interrupt any in-flight turn and read that thread's last message. */
    fun selectMessage(eventId: Long) {
        val msg = _messages.value.firstOrNull { it.eventId == eventId } ?: return
        if (_state.value != VoiceState.IDLE) {
            tts.stop()
            recognizer.stop()
            _state.value = VoiceState.IDLE
        }
        readThenListen(msg)
    }

    /** Notification tap with an explicit event id: reply to it without re-reading. */
    fun replyTo(eventId: Long) {
        _activeEventId.value = eventId
        pendingRespondEventId = eventId
        listen()
    }

    /** Mic button: toggle off if busy, else reply to the active message or cold-start to Inbox#Main. */
    fun pushToTalk() {
        when (_state.value) {
            VoiceState.SPEAKING -> { tts.stop(); _state.value = VoiceState.IDLE; pump() }
            VoiceState.LISTENING -> { recognizer.stop(); _state.value = VoiceState.IDLE; pump() }
            else -> {
                pendingRespondEventId = _activeEventId.value
                listen()
            }
        }
    }

    private fun listen() {
        if (!recognizer.isAvailable) {
            _lastError.value = "Speech recognition unavailable"
            _state.value = VoiceState.IDLE
            return
        }
        _state.value = VoiceState.LISTENING
        recognizer.start(
            locale = locale,
            onResult = { text -> onTranscript(text) },
            onError = {
                // No speech / cancelled: don't send a reply, just advance the queue.
                // (spec: 사용자가 아무 발화를 하지 않으면 그 메시지는 응답이 안 감)
                pendingRespondEventId = null
                _state.value = VoiceState.IDLE
                pump()
            }
        )
    }

    private fun onTranscript(text: String) {
        val eventId = pendingRespondEventId
        pendingRespondEventId = null
        if (text.isBlank()) {
            _state.value = VoiceState.IDLE
            pump()
            return
        }
        _state.value = VoiceState.THINKING
        scope.launch {
            val result = runCatching {
                if (eventId != null) repository.respond(eventId, text) else repository.sendCommand(text)
            }
            result.onSuccess { resp ->
                addExchange(text, resp.reply)
                if (eventId != null && _activeEventId.value == eventId) _activeEventId.value = null
                if (resp.speak) speak(resp.reply) else { _state.value = VoiceState.IDLE; pump() }
            }.onFailure {
                _lastError.value = it.message
                _state.value = VoiceState.IDLE
                pump()
            }
        }
    }

    private fun speak(text: String, onDone: (() -> Unit)? = null) {
        _state.value = VoiceState.SPEAKING
        tts.speak(text) {
            scope.launch {
                if (onDone != null) {
                    onDone()
                } else {
                    _state.value = VoiceState.IDLE
                    pump()
                }
            }
        }
    }

    private fun addExchange(command: String, reply: String) {
        _exchanges.value = (listOf(Exchange(command, reply)) + _exchanges.value).take(3)
    }
}
