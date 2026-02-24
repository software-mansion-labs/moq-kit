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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
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

        OutlinedTextField(
            value = vm.broadcastPath,
            onValueChange = { vm.broadcastPath = it },
            label = { Text("Broadcast Path") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = { vm.connect() },
                enabled = vm.sessionState is MoQSession.State.Idle &&
                        vm.relayUrl.isNotEmpty() &&
                        vm.broadcastPath.isNotEmpty(),
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
            OutlinedButton(onClick = {}) {
                Text("Pause")
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

        vm.broadcastInfo?.let { info ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                info.videoTracks.firstOrNull()?.let { v ->
                    Text(
                        text = "Video: ${v.value.name} (${v.value.codec})",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                info.audioTracks.firstOrNull()?.let { a ->
                    Text(
                        text = "Audio: ${a.value.name} (${a.value.codec} ${a.value.sampleRate} Hz)",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .background(Color.Black, shape = RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = "No Video",
                color = Color.White.copy(alpha = 0.5f),
            )
        }
    }
}

private fun stateLabel(state: MoQSession.State): String = when (state) {
    MoQSession.State.Idle -> "idle"
    MoQSession.State.Connecting -> "connecting..."
    MoQSession.State.Connected -> "connected"
    is MoQSession.State.Error -> "error: ${state.code}"
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
