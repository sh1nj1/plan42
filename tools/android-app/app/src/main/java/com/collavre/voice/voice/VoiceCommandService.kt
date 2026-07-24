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
    companion object {
        /**
         * Sentinel "event id" for the always-present Inbox#Main row. It is not a real
         * agent_event — selecting it (or replying with it active) routes a cold
         * utterance to Inbox#Main via sendCommand instead of respond(eventId).
         */
        const val INBOX_MAIN_ID = -1L
    }

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

    // FIFO of unread incoming messages; drained one at a time while IDLE.
    private val queue = ArrayDeque<VoiceMessage>()
    private val seen = mutableSetOf<Long>()

    // The notice whose OWN text is being spoken right now (null while speaking a
    // reply). This is what an interruption marks read — see interrupt(). It is also
    // the row the Stop button belongs to: the selection can move to another row
    // mid-read, so activeEventId would point the toggle at a row that is silent.
    private val _speakingEventId = MutableStateFlow<Long?>(null)
    val speakingEventId: StateFlow<Long?> = _speakingEventId

    // Bumped by every interrupt(). A reply request spans a suspension point, so this is
    // what tells its completion that the loop has already moved on without it.
    private var currentTurn = 0L

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
        speakNotice(msg) {
            markSpokenRead()
            listen()
        }
    }

    /** Speak a notice's own text, remembering which one so an interruption can still
     *  settle its read state. */
    private fun speakNotice(msg: VoiceMessage, onDone: () -> Unit) {
        _speakingEventId.value = msg.eventId
        speak(msg.text, onDone)
    }

    /**
     * Settle the read state of the notice that was being spoken: mark it read so the
     * server stops re-emitting it. Called when TTS finishes it AND when the user cuts
     * it off — stopping is a deliberate "that's enough", and leaving it unread would
     * strand it, since ingest's `seen` set suppresses the re-emitted notice for the
     * rest of the process (it would only be spoken again after an app restart). The
     * row keeps its play button, so a replay is one tap. A crash is different: the
     * callback never runs, nothing is marked read, and the next poll re-reads it —
     * at-least-once is for the unattended failure, not for an explicit stop.
     */
    private fun markSpokenRead() {
        val eventId = _speakingEventId.value ?: return
        _speakingEventId.value = null
        markRead(eventId)
    }

    private fun markRead(eventId: Long) {
        scope.launch { runCatching { repository.markRead(eventId) } }
    }

    /** Stop whatever is in flight so something else can start. */
    private fun interrupt() {
        if (_state.value == VoiceState.IDLE) return
        tts.stop()
        recognizer.cancel() // discard any in-flight utterance; don't post it as a reply
        markSpokenRead()
        // Retire the turn: a reply request may still be in flight, and its completion
        // must not drive the session that is about to start.
        currentTurn++
        _state.value = VoiceState.IDLE
    }

    /** Tap a list row: mark it the selection (highlight). Reading/replying are the
     *  explicit per-row play/reply buttons now. The Inbox#Main row is selectable too
     *  — with it active, the mic/reply routes a cold utterance to Main. The reply
     *  target is derived from this selection at transcript time, so re-selecting mid
     *  read/listen redirects the in-flight reply to the highlighted row (never to a
     *  thread other than the one shown as selected). */
    fun selectMessage(eventId: Long) {
        _activeEventId.value = eventId
    }

    /** Play/stop toggle for a row: read this message aloud, or stop if it's already
     *  speaking. Inbox#Main has nothing to read, so it's a no-op there. */
    fun playMessage(eventId: Long) {
        if (eventId == INBOX_MAIN_ID) return
        // Already reading this one → stop and let the queue advance. Keyed on what is
        // actually being spoken, not on the selection: tapping another row moves the
        // selection while this read continues.
        if (_speakingEventId.value == eventId) {
            interrupt()
            pump()
            return
        }
        val msg = _messages.value.firstOrNull { it.eventId == eventId } ?: return
        // Reading it here IS its turn in the queue; leaving the entry there would have
        // the pump() below immediately read it a second time.
        queue.removeAll { it.eventId == eventId }
        interrupt() // whatever was mid-read settles its own read state first
        recognizer.reset()
        _activeEventId.value = eventId
        speakNotice(msg) {
            markSpokenRead()
            _state.value = VoiceState.IDLE
            pump()
        }
    }

    /** Reply button (and notification tap): listen for a spoken reply to this event.
     *  With the Inbox#Main sentinel active, the reply is a cold utterance to Main. */
    fun replyTo(eventId: Long) {
        interrupt() // drops the prior listen so its tail can't post to the old thread
        // Answering a still-queued notice is dealing with it: drop the entry so it is not
        // read aloud after the reply, and settle its read state — ingest's `seen` set now
        // suppresses the re-emitted notice, so leaving it unread would strand it.
        if (queue.removeAll { it.eventId == eventId }) markRead(eventId)
        _activeEventId.value = eventId
        listen()
    }

    /** Mic button: toggle off if busy, else reply to the active message or cold-start to Inbox#Main. */
    fun pushToTalk() {
        when (_state.value) {
            VoiceState.SPEAKING, VoiceState.LISTENING -> { interrupt(); pump() }
            // Reply to the highlighted message, or cold-start to Inbox#Main when the
            // Main row (or nothing) is selected — resolved from _activeEventId in onTranscript.
            else -> listen()
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
                // (spec: silence means no reply is sent for that message)
                _state.value = VoiceState.IDLE
                pump()
            }
        )
    }

    private fun onTranscript(text: String) {
        // Resolve the reply target from the currently highlighted row (single source
        // of truth): re-selecting mid read/listen redirects the reply to match the
        // visible selection. Inbox#Main / no selection → cold utterance to Main.
        val eventId = _activeEventId.value?.takeIf { it != INBOX_MAIN_ID }
        if (text.isBlank()) {
            _state.value = VoiceState.IDLE
            pump()
            return
        }
        _state.value = VoiceState.THINKING
        val turn = currentTurn
        scope.launch {
            val result = runCatching {
                if (eventId != null) repository.respond(eventId, text) else repository.sendCommand(text)
            }
            // An interruption during THINKING hands the loop to a new play/reply session
            // while this request is still open. Everything below belongs to a turn that no
            // longer owns the state — speaking here would talk over the new session, and
            // pump()/clearing the selection would pull the queue and the reply target out
            // from under it. Keep the answer in the log and stop.
            if (turn != currentTurn) {
                result.onSuccess { addExchange(text, it.reply) }
                return@launch
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
