package com.collavre.voice.voice

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Wraps Android SpeechRecognizer. Must be driven from the main thread.
 * Results/errors are delivered through callbacks set per listening session.
 */
@Singleton
class SpeechRecognizerManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private var recognizer: SpeechRecognizer? = null

    private val _listening = MutableStateFlow(false)
    val listening: StateFlow<Boolean> = _listening

    // Live partial transcript so the UI can show speech as it's recognized.
    private val _partial = MutableStateFlow("")
    val partial: StateFlow<String> = _partial

    val isAvailable: Boolean get() = SpeechRecognizer.isRecognitionAvailable(context)

    /** The listening session currently allowed to deliver callbacks. */
    private var session: Session? = null

    fun start(locale: String, onResult: (String) -> Unit, onError: (Int) -> Unit) {
        val session = Session(onResult, onError)
        this.session = session

        val recognizer = this.recognizer
            ?: SpeechRecognizer.createSpeechRecognizer(context).also { this.recognizer = it }
        recognizer.setRecognitionListener(session)

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }
        _partial.value = ""
        _listening.value = true
        recognizer.startListening(intent)
    }

    /**
     * Abandon the current session WITHOUT delivering a final transcript. Calling
     * stopListening() would still fire onResults with the buffered audio (which
     * could post as a reply to the wrong thread), so for interruptions we abandon
     * the session and call cancel() instead.
     *
     * An abandoned session can still deliver a terminal callback: the framework
     * posts it to the main thread, so it lands after the caller has already
     * restarted recognition. Two guards make that harmless. The session is marked
     * finished, so its own callbacks become no-ops; and the recognizer instance is
     * dropped, because the framework resolves the listener at delivery time and a
     * reused instance would hand the stale callback to the next session's listener.
     */
    fun cancel() {
        val session = this.session
        this.session = null
        _partial.value = ""
        // Already terminated — nothing can still be in flight, so keep the instance.
        if (session == null || session.finished) return
        session.finished = true
        recognizer?.cancel()
        recognizer?.destroy()
        recognizer = null
        _listening.value = false
    }

    /** Clear the on-screen transcript before a new turn (e.g. reading a new message). */
    fun reset() {
        _partial.value = ""
    }

    fun destroy() {
        session?.finished = true
        session = null
        recognizer?.destroy()
        recognizer = null
        _listening.value = false
    }

    /**
     * One listening session. Callbacks are held by the session that started it
     * rather than by the manager, so a late callback from an abandoned session
     * can never reach the callbacks of the session that replaced it.
     */
    private inner class Session(
        private val resultCallback: (String) -> Unit,
        private val errorCallback: (Int) -> Unit
    ) : RecognitionListener {
        /** Terminated (delivered a result/error) or abandoned by cancel(). */
        var finished = false

        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() { if (!finished) _listening.value = false }

        override fun onPartialResults(partialResults: Bundle?) {
            if (finished) return
            partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.takeIf { it.isNotBlank() }
                ?.let { _partial.value = it }
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onError(error: Int) {
            if (finished) return
            finished = true
            _listening.value = false
            _partial.value = ""
            errorCallback(error)
        }

        override fun onResults(results: Bundle?) {
            if (finished) return
            finished = true
            _listening.value = false
            val text = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                .orEmpty()
            // Keep the final transcript on screen so the user sees their complete
            // utterance (partials often omit the last words); cleared on the next turn.
            _partial.value = text
            if (text.isBlank()) errorCallback(SpeechRecognizer.ERROR_NO_MATCH)
            else resultCallback(text)
        }
    }
}
