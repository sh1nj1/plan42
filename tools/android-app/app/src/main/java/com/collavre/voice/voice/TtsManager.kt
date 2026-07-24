package com.collavre.voice.voice

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.Locale
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Thin TextToSpeech wrapper. Tracks speaking state and invokes onDone after the
 * last queued utterance finishes — that callback is the hook the orchestrator
 * uses to auto-resume listening for a hands-free reply.
 */
@Singleton
class TtsManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private var tts: TextToSpeech? = null
    private var ready = false
    private var pendingOnDone: (() -> Unit)? = null

    private val _speaking = MutableStateFlow(false)
    val speaking: StateFlow<Boolean> = _speaking

    fun init(locale: String, rate: Float) {
        if (tts == null) {
            tts = TextToSpeech(context) { status ->
                ready = status == TextToSpeech.SUCCESS
                applyConfig(locale, rate)
                tts?.setOnUtteranceProgressListener(progressListener)
            }
        } else {
            applyConfig(locale, rate)
        }
    }

    private fun applyConfig(locale: String, rate: Float) {
        val t = tts ?: return
        t.language = toLocale(locale)
        t.setSpeechRate(rate.coerceIn(0.5f, 2.0f))
    }

    /** Speaks [text]; [onDone] fires when this utterance completes (or fails). */
    fun speak(text: String, onDone: (() -> Unit)? = null) {
        val t = tts
        if (text.isBlank()) { onDone?.invoke(); return }
        if (t == null || !ready) { onDone?.invoke(); return }
        pendingOnDone = onDone
        _speaking.value = true
        val id = UUID.randomUUID().toString()
        t.speak(text, TextToSpeech.QUEUE_FLUSH, null, id)
    }

    fun stop() {
        tts?.stop()
        _speaking.value = false
        pendingOnDone = null
    }

    fun shutdown() {
        tts?.shutdown()
        tts = null
        ready = false
    }

    private val progressListener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) { _speaking.value = true }
        override fun onDone(utteranceId: String?) = finish()
        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) = finish()
        override fun onError(utteranceId: String?, errorCode: Int) = finish()

        private fun finish() {
            _speaking.value = false
            val cb = pendingOnDone
            pendingOnDone = null
            cb?.invoke()
        }
    }

    private fun toLocale(tag: String): Locale =
        runCatching { Locale.forLanguageTag(tag) }.getOrDefault(Locale.KOREA)
}
