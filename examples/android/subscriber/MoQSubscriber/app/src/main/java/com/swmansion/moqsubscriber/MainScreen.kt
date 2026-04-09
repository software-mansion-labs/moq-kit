package com.swmansion.moqsubscriber

import android.app.Activity
import android.content.pm.ActivityInfo
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.swmansion.moqkit.MoQSession
import com.swmansion.moqkit.MoQVideoTrackInfo
import com.swmansion.moqkit.PlaybackStats
import kotlinx.coroutines.delay

@Composable
fun MainScreen(vm: MainViewModel = viewModel()) {
    var fullscreenEntry by remember { mutableStateOf<BroadcastEntry?>(null) }

    val context = LocalContext.current
    DisposableEffect(fullscreenEntry != null) {
        val activity = context as Activity
        if (fullscreenEntry != null) {
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            WindowCompat.getInsetsController(activity.window, activity.window.decorView).apply {
                hide(WindowInsetsCompat.Type.systemBars())
                systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            WindowCompat.getInsetsController(activity.window, activity.window.decorView)
                .show(WindowInsetsCompat.Type.systemBars())
        }
        onDispose {
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            WindowCompat.getInsetsController(activity.window, activity.window.decorView)
                .show(WindowInsetsCompat.Type.systemBars())
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
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
                    BroadcastCard(
                        entry = entry,
                        vm = vm,
                        isFullscreen = fullscreenEntry?.id == entry.id,
                        onFullscreen = { fullscreenEntry = entry },
                    )
                }
            }
        }

        fullscreenEntry?.let { entry ->
            FullscreenPlayerOverlay(
                entry = entry,
                vm = vm,
                onDismiss = { fullscreenEntry = null },
                modifier = Modifier
                    .fillMaxSize()
                    .zIndex(1f),
            )
        }
    }
}

@Composable
private fun BroadcastCard(
    entry: BroadcastEntry,
    vm: MainViewModel,
    isFullscreen: Boolean,
    onFullscreen: () -> Unit,
) {
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

            // Video surface with tap-to-show overlaid controls
            var showControls by remember { mutableStateOf(false) }
            LaunchedEffect(showControls) {
                if (showControls) {
                    delay(3000)
                    showControls = false
                }
            }

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(16f / 9f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color.Black)
                    .clickable(
                        indication = null,
                        interactionSource = remember { MutableInteractionSource() },
                    ) { showControls = !showControls },
            ) {
                if (isFullscreen) {
                    Box(
                        modifier = Modifier.fillMaxSize(),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = "Playing in fullscreen",
                            color = Color.Gray,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                } else {
                    val player = entry.player
                    AndroidView(
                        factory = { ctx ->
                            SurfaceView(ctx).also { sv ->
                                sv.holder.addCallback(object : SurfaceHolder.Callback {
                                    override fun surfaceCreated(holder: SurfaceHolder) {
                                        entry.player?.setSurface(holder.surface)
                                    }
                                    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
                                    override fun surfaceDestroyed(holder: SurfaceHolder) {
                                        entry.player?.setSurface(null)
                                    }
                                })
                            }
                        },
                        update = { sv ->
                            val surface = sv.holder.surface
                            if (player != null && surface != null && surface.isValid) {
                                player.setSurface(surface)
                            }
                        },
                        modifier = Modifier.fillMaxSize(),
                    )
                }

                if (showControls) {
                    // Pause — centred
                    IconButton(
                        onClick = { vm.togglePause(entry) },
                        enabled = entry.isPlaying || entry.isPaused,
                        modifier = Modifier.align(Alignment.Center),
                    ) {
                        Icon(
                            imageVector = if (entry.isPaused) Icons.Default.PlayArrow else Icons.Default.Pause,
                            contentDescription = if (entry.isPaused) "Resume" else "Pause",
                            tint = Color.White,
                            modifier = Modifier.size(40.dp),
                        )
                    }

                    // Fullscreen — bottom-right corner
                    IconButton(
                        onClick = onFullscreen,
                        enabled = entry.isPlaying || entry.isPaused,
                        modifier = Modifier.align(Alignment.BottomEnd),
                    ) {
                        Icon(
                            imageVector = Icons.Default.Fullscreen,
                            contentDescription = "Fullscreen",
                            tint = Color.White,
                        )
                    }
                }
            }

            RenditionPickerRow(entry = entry, vm = vm)

            // Per-player latency slider
            Column {
                Text(
                    text = "Target latency: ${entry.targetLatencyMs} ms",
                    style = MaterialTheme.typography.bodySmall,
                )
                Slider(
                    value = entry.targetLatencyMs.toFloat(),
                    onValueChange = { vm.updateTargetLatency(entry, it.toInt()) },
                    valueRange = 50f..2000f,
                    steps = (2000 - 50) / 50 - 1,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            entry.playbackStats?.let { stats ->
                StatsCard(stats)
            }
        }
    }
}

@Composable
private fun FullscreenPlayerOverlay(
    entry: BroadcastEntry,
    vm: MainViewModel,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var showControls by remember { mutableStateOf(true) }

    BackHandler { onDismiss() }

    LaunchedEffect(showControls) {
        if (showControls) {
            delay(3000)
            showControls = false
        }
    }

    Box(
        modifier = modifier
            .background(Color.Black)
            .clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
            ) { showControls = !showControls },
    ) {
        AndroidView(
            factory = { ctx ->
                SurfaceView(ctx).also { sv ->
                    sv.holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) {
                            entry.player?.setSurface(holder.surface)
                        }
                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
                        override fun surfaceDestroyed(holder: SurfaceHolder) {
                            entry.player?.setSurface(null)
                        }
                    })
                }
            },
            modifier = Modifier.fillMaxSize(),
        )

        if (showControls) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.4f)),
            ) {
                // Close — top right
                IconButton(
                    onClick = onDismiss,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(8.dp),
                ) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "Exit fullscreen",
                        tint = Color.White,
                    )
                }

                // Play / pause — centre
                IconButton(
                    onClick = { vm.togglePause(entry) },
                    enabled = entry.isPlaying || entry.isPaused,
                    modifier = Modifier.align(Alignment.Center),
                ) {
                    Icon(
                        imageVector = if (entry.isPaused) Icons.Default.PlayArrow else Icons.Default.Pause,
                        contentDescription = if (entry.isPaused) "Resume" else "Pause",
                        tint = Color.White,
                        modifier = Modifier.size(48.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun StatsCard(stats: PlaybackStats) {
    var isExpanded by remember { mutableStateOf(false) }

    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
        ),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            // Header — always visible
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { isExpanded = !isExpanded },
            ) {
                Text(
                    text = "Playback Stats",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Medium,
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.weight(1f).padding(start = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // Summary in collapsed header
                    stats.videoLatencyMs?.let { ms ->
                        Text(
                            text = "${ms.toInt()} ms",
                            style = MaterialTheme.typography.labelSmall,
                            color = latencyColor(ms),
                        )
                    }
                    stats.videoFps?.let { fps ->
                        Text(
                            text = "${fps.toInt()} fps",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Text(
                    text = if (isExpanded) "▼" else "▶",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            if (isExpanded) {
                HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))

                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    // Latency section
                    if (stats.videoLatencyMs != null || stats.audioLatencyMs != null) {
                        StatsSection("Latency") {
                            stats.videoLatencyMs?.let { ms ->
                                StatRow("Video", "${ms.toInt()} ms", latencyColor(ms))
                            }
                            stats.audioLatencyMs?.let { ms ->
                                StatRow("Audio", "${ms.toInt()} ms", latencyColor(ms))
                            }
                        }
                    }

                    // Throughput section
                    if (stats.videoBitrateKbps != null || stats.audioBitrateKbps != null || stats.videoFps != null) {
                        StatsSection("Throughput") {
                            stats.videoBitrateKbps?.let { kbps ->
                                StatRow("Video bitrate", formatBitrate(kbps))
                            }
                            stats.audioBitrateKbps?.let { kbps ->
                                StatRow("Audio bitrate", formatBitrate(kbps))
                            }
                            stats.videoFps?.let { fps ->
                                StatRow("Frame rate", "${fps.toInt()} fps")
                            }
                        }
                    }

                    // Startup section
                    if (stats.timeToFirstVideoFrameMs != null || stats.timeToFirstAudioFrameMs != null) {
                        StatsSection("Startup") {
                            stats.timeToFirstVideoFrameMs?.let { ms ->
                                StatRow("First video frame", "${ms.toInt()} ms")
                            }
                            stats.timeToFirstAudioFrameMs?.let { ms ->
                                StatRow("First audio frame", "${ms.toInt()} ms")
                            }
                        }
                    }

                    // Buffers section
                    if (stats.audioRingBufferMs != null || stats.videoJitterBufferMs != null) {
                        StatsSection("Buffers") {
                            stats.videoJitterBufferMs?.let { ms ->
                                StatRow("Video jitter buffer", "${ms.toInt()} ms")
                            }
                            stats.audioRingBufferMs?.let { ms ->
                                StatRow("Audio ring buffer", "${ms.toInt()} ms")
                            }
                        }
                    }

                    // Health section
                    val hasHealth = (stats.videoStalls?.let { it.count > 0 } == true)
                        || (stats.audioStalls?.let { it.count > 0 } == true)
                        || (stats.videoFramesDropped?.let { it > 0 } == true)
                        || (stats.audioFramesDropped?.let { it > 0 } == true)
                    if (hasHealth) {
                        StatsSection("Health") {
                            stats.videoStalls?.takeIf { it.count > 0 }?.let { s ->
                                StatRow("Video stalls", "${s.count} (${s.totalDurationMs.toInt()} ms)", Color(0xFFFFA500))
                            }
                            stats.audioStalls?.takeIf { it.count > 0 }?.let { s ->
                                StatRow("Audio stalls", "${s.count} (${s.totalDurationMs.toInt()} ms)", Color(0xFFFFA500))
                            }
                            stats.videoFramesDropped?.takeIf { it > 0L }?.let { d ->
                                StatRow("Video frames dropped", "$d", Color.Red)
                            }
                            stats.audioFramesDropped?.takeIf { it > 0L }?.let { d ->
                                StatRow("Audio frames dropped", "$d", Color.Red)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StatsSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            text = title.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
        )
        content()
    }
}

@Composable
private fun StatRow(label: String, value: String, color: Color = MaterialTheme.colorScheme.onSurface) {
    Row(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Box(modifier = Modifier.weight(1f))
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = color,
        )
    }
}

private fun latencyColor(ms: Double): Color {
    if (ms < 150) return Color(0xFF4CAF50) // green
    if (ms < 500) return Color(0xFFFFA500) // orange
    return Color.Red
}

private fun formatBitrate(kbps: Double): String {
    if (kbps >= 1000) return String.format("%.1f Mbps", kbps / 1000)
    return "${kbps.toInt()} kbps"
}

@Composable
private fun RenditionPickerRow(entry: BroadcastEntry, vm: MainViewModel) {
    val tracks = remember(entry.info.videoTracks) {
        entry.info.videoTracks.sortedByDescending {
            it.config.coded?.let { d -> d.width.toLong() * d.height.toLong() } ?: 0L
        }
    }
    if (tracks.size < 2) return

    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        tracks.forEach { track ->
            val isSelected = track.name == entry.selectedVideoTrack?.name
            val isPending = track.name == entry.pendingVideoTrack?.name
            val label = track.config.coded?.height?.let { "${it}p" } ?: track.name

            Button(
                onClick = { vm.switchVideoTrack(entry, track) },
                enabled = !isSelected && entry.pendingVideoTrack == null,
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (isSelected || isPending)
                        MaterialTheme.colorScheme.primary
                    else
                        MaterialTheme.colorScheme.surfaceVariant,
                    contentColor = if (isSelected || isPending)
                        MaterialTheme.colorScheme.onPrimary
                    else
                        MaterialTheme.colorScheme.onSurfaceVariant,
                    disabledContainerColor = if (isSelected || isPending)
                        MaterialTheme.colorScheme.primary.copy(alpha = 0.8f)
                    else
                        MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                    disabledContentColor = if (isSelected || isPending)
                        MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.8f)
                    else
                        MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                ),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
                modifier = Modifier.height(32.dp),
            ) {
                Text(label, style = MaterialTheme.typography.labelMedium)
            }
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
