package com.collavre.voice.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.collavre.voice.voice.VoiceMessage
import com.collavre.voice.voice.VoiceState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    viewModel: VoiceViewModel,
    onOpenSettings: () -> Unit,
    onMicClick: () -> Unit
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val messages by viewModel.messages.collectAsStateWithLifecycle()
    val activeEventId by viewModel.activeEventId.collectAsStateWithLifecycle()
    val partial by viewModel.partialTranscript.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Collavre Voice") },
                actions = {
                    IconButton(onClick = onOpenSettings) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            StatusChip(state)
            Spacer(Modifier.height(32.dp))

            MicButton(state = state, onClick = onMicClick)

            Spacer(Modifier.height(16.dp))
            LiveCaption(state = state, partial = partial)
            Spacer(Modifier.height(16.dp))

            if (messages.isNotEmpty()) {
                SectionLabel("Messages")
                messages.forEach { msg ->
                    MessageRow(
                        message = msg,
                        selected = msg.eventId == activeEventId,
                        onClick = { viewModel.selectMessage(msg.eventId) }
                    )
                }
            }
        }
    }
}

@Composable
private fun StatusChip(state: VoiceState) {
    val label = when (state) {
        VoiceState.IDLE -> "Idle"
        VoiceState.LISTENING -> "Listening…"
        VoiceState.THINKING -> "Thinking…"
        VoiceState.SPEAKING -> "Speaking…"
    }
    Surface(
        color = MaterialTheme.colorScheme.secondaryContainer,
        shape = MaterialTheme.shapes.large
    ) {
        Text(label, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
    }
}

/** Real-time transcript of what's being spoken, shown live while the mic is open. */
@Composable
private fun LiveCaption(state: VoiceState, partial: String) {
    if (state != VoiceState.LISTENING && partial.isBlank()) return
    val text = when {
        partial.isNotBlank() -> partial
        state == VoiceState.LISTENING -> "말씀하세요…"
        else -> ""
    }
    Text(
        text,
        style = MaterialTheme.typography.titleMedium,
        color = if (partial.isBlank()) {
            MaterialTheme.colorScheme.onSurfaceVariant
        } else {
            MaterialTheme.colorScheme.onSurface
        },
        textAlign = TextAlign.Center,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp)
    )
}

@Composable
private fun MicButton(state: VoiceState, onClick: () -> Unit) {
    val active = state == VoiceState.LISTENING
    FilledTonalButton(
        onClick = onClick,
        shape = CircleShape,
        modifier = Modifier.size(160.dp)
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                Icons.Default.Mic,
                contentDescription = if (active) "Stop" else "Talk",
                modifier = Modifier.size(72.dp)
            )
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
    )
}

/**
 * One arrived message. Title is "Creative#Topic". Tapping reads the thread's
 * last message aloud and listens for a reply; the active row is highlighted.
 */
@Composable
private fun MessageRow(message: VoiceMessage, selected: Boolean, onClick: () -> Unit) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .clickable(onClick = onClick),
        colors = if (selected) {
            CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)
        } else {
            CardDefaults.cardColors()
        }
    ) {
        Column(Modifier.padding(12.dp)) {
            Text(
                message.title,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                message.text,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}
