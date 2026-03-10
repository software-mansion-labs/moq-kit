package com.swmansion.moqsubscriber

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.media3.ui.PlayerView
import com.swmansion.moqkit.MoQSession

@Composable
fun MainScreen(vm: MainViewModel = viewModel()) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        OutlinedTextField(
            value = vm.relayUrl,
            onValueChange = { vm.relayUrl = it },
            label = { Text("Relay URL") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = { vm.connect() },
                enabled = vm.sessionState is MoQSession.State.Idle &&
                        vm.relayUrl.isNotEmpty(),
            ) {
                Text("Connect")
            }
            OutlinedButton(
                onClick = { vm.stop() },
                enabled = vm.sessionState is MoQSession.State.Connecting ||
                        vm.sessionState is MoQSession.State.Connected,
            ) {
                Text("Stop")
            }
            OutlinedButton(
                onClick = { if (vm.broadcasts.any { it.isPaused }) vm.resume() else vm.pause() },
                enabled = vm.broadcasts.any { it.isPlaying || it.isPaused },
            ) {
                Text(if (vm.broadcasts.any { it.isPaused }) "Resume" else "Pause")
            }
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .background(stateColor(vm.sessionState), shape = RoundedCornerShape(5.dp))
            )
            Text(
                text = stateLabel(vm.sessionState),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        LazyColumn(
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            items(vm.broadcasts, key = { it.id }) { entry ->
                BroadcastCard(entry)
            }
        }
    }
}

@Composable
private fun BroadcastCard(entry: BroadcastEntry) {
    Card(
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val color = when {
                    entry.offline -> Color.Red
                    entry.isPlaying -> Color.Green
                    entry.isPaused -> Color(0xFFFFA500)
                    else -> Color.Gray
                }
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .background(color, shape = RoundedCornerShape(5.dp))
                )
                Text(
                    text = entry.id,
                    style = MaterialTheme.typography.titleSmall,
                )
                val statusLabel = when {
                    entry.offline -> "offline"
                    entry.isPlaying -> "playing"
                    entry.isPaused -> "paused"
                    else -> "loading"
                }
                Text(
                    text = statusLabel,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            val info = entry.info
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                info.videoTracks.firstOrNull()?.let { track ->
                    Text(
                        text = "Video: ${track.config.codec}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                info.audioTracks.firstOrNull()?.let { track ->
                    Text(
                        text = "Audio: ${track.config.codec} ${track.config.sampleRate} Hz",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            AndroidView(
                factory = { ctx -> PlayerView(ctx).also { it.useController = false } },
                update = { pv -> pv.player = entry.player },
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(16f / 9f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color.Black),
            )
        }
    }
}

private fun stateLabel(state: MoQSession.State): String = when (state) {
    MoQSession.State.Idle -> "idle"
    MoQSession.State.Connecting -> "connecting..."
    MoQSession.State.Connected -> "connected"
    is MoQSession.State.Error -> "error: ${state.message}"
    MoQSession.State.Closed -> "closed"
}

@Composable
private fun stateColor(state: MoQSession.State): Color = when (state) {
    MoQSession.State.Idle -> Color.Gray
    MoQSession.State.Connecting -> Color(0xFFFFA500)
    MoQSession.State.Connected -> Color.Blue
    is MoQSession.State.Error -> Color.Red
    MoQSession.State.Closed -> Color.Gray
}
