package com.collavre.voice.events

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import com.collavre.voice.MainActivity
import com.collavre.voice.R
import com.collavre.voice.network.model.AgentEvent

object Notifications {
    const val EVENT_CHANNEL = "agent_events"
    const val SERVICE_CHANNEL = "agent_event_service"
    const val SERVICE_NOTIFICATION_ID = 1001

    fun ensureChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(
                EVENT_CHANNEL,
                context.getString(R.string.event_channel_name),
                NotificationManager.IMPORTANCE_HIGH
            ).apply { description = context.getString(R.string.event_channel_desc) }
        )
        nm.createNotificationChannel(
            NotificationChannel(
                SERVICE_CHANNEL,
                context.getString(R.string.service_channel_name),
                NotificationManager.IMPORTANCE_LOW
            )
        )
    }

    fun serviceNotification(context: Context): Notification =
        NotificationCompat.Builder(context, SERVICE_CHANNEL)
            .setContentTitle(context.getString(R.string.service_channel_name))
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

    /** A surfaced event; tapping opens the app and starts listening for a reply. */
    fun postEvent(context: Context, event: AgentEvent) {
        val open = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(MainActivity.EXTRA_OPEN_AND_LISTEN, true)
            putExtra(MainActivity.EXTRA_EVENT_ID, event.id)
            putExtra(MainActivity.EXTRA_EVENT_REQUIRES_RESPONSE, event.requiresResponse)
        }
        val pending = PendingIntent.getActivity(
            context, event.id.toInt(), open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, EVENT_CHANNEL)
            .setContentTitle(event.title ?: "Collavre")
            .setContentText(event.summary)
            .setStyle(NotificationCompat.BigTextStyle().bigText(event.summary))
            .setSmallIcon(R.drawable.ic_notification)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setPriority(NotificationCompat.PRIORITY_HIGH)

        if (event.isApproval) {
            builder.addAction(0, "✓", quickResponse(context, event.id, "approve"))
            builder.addAction(0, "✗", quickResponse(context, event.id, "deny"))
        }

        context.getSystemService(NotificationManager::class.java)
            .notify(event.id.toInt(), builder.build())
    }

    private fun quickResponse(context: Context, eventId: Long, response: String): PendingIntent {
        val intent = Intent(context, QuickResponseReceiver::class.java).apply {
            action = QuickResponseReceiver.ACTION
            putExtra(QuickResponseReceiver.EXTRA_EVENT_ID, eventId)
            putExtra(QuickResponseReceiver.EXTRA_RESPONSE, response)
        }
        return PendingIntent.getBroadcast(
            context, (eventId.toInt() * 31) + response.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
