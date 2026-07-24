package com.collavre.voice

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.hilt.navigation.compose.hiltViewModel
import com.collavre.voice.events.AgentEventService
import com.collavre.voice.events.Notifications
import com.collavre.voice.permission.PermissionManager
import com.collavre.voice.ui.MainScreen
import com.collavre.voice.ui.SettingsScreen
import com.collavre.voice.ui.VoiceViewModel
import com.collavre.voice.ui.theme.CollavreVoiceTheme
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    // Event id to reply to when launched from a notification (-1 = plain mic turn).
    private var openEventId by mutableStateOf(-1L)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Notifications.ensureChannels(this)
        openEventId = pendingEventId(intent)

        setContent {
            CollavreVoiceTheme {
                AppRoot(
                    consumeOpenEvent = { val v = openEventId; openEventId = -1L; v },
                    startEventService = ::startEventService
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        openEventId = pendingEventId(intent)
    }

    /** Returns the event id to reply to (>=0), 0 for "listen but no specific event", or -1 for none. */
    private fun pendingEventId(intent: Intent): Long {
        if (!intent.getBooleanExtra(EXTRA_OPEN_AND_LISTEN, false)) return -1L
        return intent.getLongExtra(EXTRA_EVENT_ID, 0L)
    }

    private fun startEventService() {
        val svc = Intent(this, AgentEventService::class.java)
        ContextCompat.startForegroundService(this, svc)
    }

    companion object {
        const val EXTRA_OPEN_AND_LISTEN = "open_and_listen"
        const val EXTRA_EVENT_ID = "event_id"
        const val EXTRA_EVENT_REQUIRES_RESPONSE = "event_requires_response"
    }
}

@Composable
private fun AppRoot(
    consumeOpenEvent: () -> Long,
    startEventService: () -> Unit
) {
    val viewModel: VoiceViewModel = hiltViewModel()
    var screen by remember { mutableStateOf(Screen.MAIN) }
    var permissionsGranted by remember { mutableStateOf(false) }

    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        permissionsGranted = result[android.Manifest.permission.RECORD_AUDIO] == true
        if (permissionsGranted) startEventService()
    }

    LaunchedEffect(Unit) {
        launcher.launch(PermissionManager.required())
    }

    // Notification tap → reply straight to that event (or a plain mic turn).
    LaunchedEffect(permissionsGranted) {
        if (!permissionsGranted) return@LaunchedEffect
        val eventId = consumeOpenEvent()
        when {
            eventId > 0L -> viewModel.replyTo(eventId)
            eventId == 0L -> viewModel.pushToTalk()
        }
    }

    when (screen) {
        Screen.MAIN -> MainScreen(
            viewModel = viewModel,
            onOpenSettings = { screen = Screen.SETTINGS },
            onMicClick = { viewModel.pushToTalk() }
        )
        Screen.SETTINGS -> SettingsScreen(
            viewModel = viewModel,
            onBack = { screen = Screen.MAIN }
        )
    }
}

private enum class Screen { MAIN, SETTINGS }
