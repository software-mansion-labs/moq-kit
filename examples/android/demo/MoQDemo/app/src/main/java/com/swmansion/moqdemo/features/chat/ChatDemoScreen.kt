package com.swmansion.moqdemo.features.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.swmansion.moqkit.Session
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun ChatDemoScreen(vm: ChatDemoViewModel = viewModel()) {
    var draftMessage by remember { mutableStateOf("") }
    val messagesListState = rememberLazyListState()

    LaunchedEffect(vm.messages.size) {
        val lastIndex = vm.messages.lastIndex
        if (lastIndex >= 0) {
            messagesListState.animateScrollToItem(lastIndex)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .systemBarsPadding(),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 16.dp),
        ) {
            ConnectionPanel(vm = vm)
        }

        LazyColumn(
            state = messagesListState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (vm.messages.isEmpty()) {
                item {
                    EmptyMessagesCard()
                }
            } else {
                items(vm.messages, key = { it.id }) { message ->
                    ChatMessageRow(message = message)
                }
            }
        }

        Composer(
            text = draftMessage,
            enabled = vm.canSend && draftMessage.trim().isNotEmpty() && vm.displayName.trim().isNotEmpty(),
            onTextChange = { draftMessage = it },
            onSend = {
                if (vm.send(draftMessage)) {
                    draftMessage = ""
                }
            },
        )
    }
}

@Composable
private fun ConnectionPanel(vm: ChatDemoViewModel) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                value = vm.relayUrl,
                onValueChange = { vm.relayUrl = it },
                label = { Text("Relay URL") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = vm.subscribePrefix,
                onValueChange = { vm.subscribePrefix = it },
                label = { Text("Subscribe Prefix") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = vm.publishPath,
                onValueChange = { vm.publishPath = it },
                label = { Text("Publish Path") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = vm.displayName,
                onValueChange = { vm.displayName = it },
                label = { Text("Display Name") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(
                    onClick = { vm.connect() },
                    enabled = vm.canConnect &&
                        vm.relayUrl.trim().isNotEmpty() &&
                        vm.subscribePrefix.trim().isNotEmpty() &&
                        vm.publishPath.trim().isNotEmpty(),
                ) {
                    Text("Connect")
                }
                OutlinedButton(
                    onClick = { vm.stop() },
                    enabled = vm.canStop,
                ) {
                    Text("Stop")
                }
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .background(stateColor(vm.sessionState), RoundedCornerShape(5.dp)),
                )
                Text(
                    text = stateLabel(vm.sessionState),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = "${vm.activeBroadcastCount} chats",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Text(
                text = vm.statusMessage,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun EmptyMessagesCard() {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = "No messages",
                style = MaterialTheme.typography.titleMedium,
            )
            Text(
                text = "Connected broadcasts with a chat track will appear here.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ChatMessageRow(message: ChatMessage) {
    Row(modifier = Modifier.fillMaxWidth()) {
        if (message.isLocal) {
            Box(modifier = Modifier.weight(1f))
        }

        Column(
            modifier = Modifier
                .fillMaxWidth(0.78f)
                .background(
                    color = if (message.isLocal) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.surfaceVariant
                    },
                    shape = RoundedCornerShape(12.dp),
                )
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
            horizontalAlignment = if (message.isLocal) Alignment.End else Alignment.Start,
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = message.from,
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = if (message.isLocal) {
                        MaterialTheme.colorScheme.onPrimary
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
                Text(
                    text = formatTime(message.timestampMs),
                    style = MaterialTheme.typography.labelSmall,
                    color = if (message.isLocal) {
                        MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.72f)
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }

            Text(
                text = message.text,
                style = MaterialTheme.typography.bodyMedium,
                color = if (message.isLocal) {
                    MaterialTheme.colorScheme.onPrimary
                } else {
                    MaterialTheme.colorScheme.onSurface
                },
            )

            Text(
                text = message.broadcastPath,
                style = MaterialTheme.typography.labelSmall,
                color = if (message.isLocal) {
                    MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.72f)
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        if (!message.isLocal) {
            Box(modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun Composer(
    text: String,
    enabled: Boolean,
    onTextChange: (String) -> Unit,
    onSend: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        OutlinedTextField(
            value = text,
            onValueChange = onTextChange,
            label = { Text("Message") },
            minLines = 1,
            maxLines = 4,
            modifier = Modifier.weight(1f),
        )
        IconButton(
            onClick = onSend,
            enabled = enabled,
        ) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.Send,
                contentDescription = "Send",
            )
        }
    }
}

private fun stateLabel(state: Session.State): String = when (state) {
    Session.State.Idle -> "idle"
    Session.State.Connecting -> "connecting..."
    Session.State.Connected -> "connected"
    is Session.State.Error -> "error: ${state.message}"
    Session.State.Closed -> "closed"
}

@Composable
private fun stateColor(state: Session.State): Color = when (state) {
    Session.State.Idle -> Color.Gray
    Session.State.Connecting -> Color(0xFFFFA500)
    Session.State.Connected -> Color.Blue
    is Session.State.Error -> Color.Red
    Session.State.Closed -> Color.Gray
}

private val timeFormatter = SimpleDateFormat("HH:mm:ss", Locale.US)

private fun formatTime(timestampMs: Long): String {
    return timeFormatter.format(Date(timestampMs))
}
