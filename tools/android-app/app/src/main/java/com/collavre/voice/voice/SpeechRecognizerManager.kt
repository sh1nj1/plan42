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

    private var onResult: ((String) -> Unit)? = null
    private var onError: ((Int) -> Unit)? = null

    fun start(locale: String, onResult: (String) -> Unit, onError: (Int) -> Unit) {
        this.onResult = onResult
        this.onError = onError

        if (recognizer == null) {
            recognizer = SpeechRecognizer.createSpeechRecognizer(context).apply {
                setRecognitionListener(listener)
            }
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }
        _partial.value = ""
        _listening.value = true
        recognizer?.startListening(intent)
    }

    /**
     * Abandon the current session WITHOUT delivering a final transcript. Calling
     * stopListening() would still fire onResults with the buffered audio (which
     * could post as a reply to the wrong thread), so for interruptions we drop the
     * session's callbacks and call cancel() instead.
     */
    fun cancel() {
        onResult = null
        onError = null
        recognizer?.cancel()
        _listening.value = false
        _partial.value = ""
    }

    /** Clear the on-screen transcript before a new turn (e.g. reading a new message). */
    fun reset() {
        _partial.value = ""
    }

    fun destroy() {
        recognizer?.destroy()
        recognizer = null
        _listening.value = false
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() { _listening.value = false }

        override fun onPartialResults(partialResults: Bundle?) {
            partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.takeIf { it.isNotBlank() }
                ?.let { _partial.value = it }
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onError(error: Int) {
            _listening.value = false
            _partial.value = ""
            onError?.invoke(error)
        }

        override fun onResults(results: Bundle?) {
            _listening.value = false
            val text = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                .orEmpty()
            // Keep the final transcript on screen so the user sees their complete
            // utterance (partials often omit the last words); cleared on the next turn.
            _partial.value = text
            if (text.isBlank()) onError?.invoke(SpeechRecognizer.ERROR_NO_MATCH)
            else onResult?.invoke(text)
        }
    }
}
