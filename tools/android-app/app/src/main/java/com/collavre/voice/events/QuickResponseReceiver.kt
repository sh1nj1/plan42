package com.collavre.voice.events

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Handles the notification approve/deny quick actions without opening the app. */
@AndroidEntryPoint
class QuickResponseReceiver : BroadcastReceiver() {

    @Inject lateinit var repository: AgentEventRepository

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val eventId = intent.getLongExtra(EXTRA_EVENT_ID, -1L)
        val response = intent.getStringExtra(EXTRA_RESPONSE) ?: return
        if (eventId < 0) return

        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            runCatching { repository.respond(eventId, response) }
            context.getSystemService(NotificationManager::class.java).cancel(eventId.toInt())
            pending.finish()
        }
    }

    companion object {
        const val ACTION = "com.collavre.voice.QUICK_RESPONSE"
        const val EXTRA_EVENT_ID = "event_id"
        const val EXTRA_RESPONSE = "response"
    }
}
