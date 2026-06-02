package com.swmansion.moqdemo.features.player

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
import androidx.compose.foundation.layout.width
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
import androidx.compose.runtime.saveable.rememberSaveable
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
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
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
import com.swmansion.moqkit.Session
import com.swmansion.moqkit.subscribe.FrameArrivalStats
import com.swmansion.moqkit.subscribe.PlaybackStats
import com.swmansion.moqkit.subscribe.PlayerTrackKind
import com.swmansion.moqkit.subscribe.StallStats
import com.swmansion.moqkit.subscribe.TrackSwitch
import com.swmansion.moqkit.subscribe.TrackSwitchStats
import com.swmansion.moqkit.subscribe.VideoTrackInfo
import kotlinx.coroutines.delay
import java.time.Duration
import java.time.Instant

@Composable
fun PlayerDemoScreen(
    initialRelayUrl: String,
    vm: PlayerDemoViewModel = viewModel(),
) {
    var relayUrl by rememberSaveable(initialRelayUrl) { mutableStateOf(initialRelayUrl) }
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
                value = relayUrl,
                onValueChange = { relayUrl = it },
                label = { Text("Relay URL") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            OutlinedTextField(
                value = vm.broadcastPath,
                onValueChange = { vm.broadcastPath = it },
                label = { Text("Broadcast Path (Optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(
                    onClick = { vm.connect(relayUrl) },
                    enabled = canConnect(vm.sessionState) && relayUrl.trim().isNotEmpty(),
                ) {
                    Text("Connect")
                }
                OutlinedButton(
                    onClick = { vm.stop() },
                    enabled = canStop(vm.sessionState),
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
    vm: PlayerDemoViewModel,
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

            val catalog = entry.catalog
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                catalog.playableVideoTracks.firstOrNull()?.let { track ->
                    Text(
                        text = "Video: ${track.config.codec}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                catalog.playableAudioTracks.firstOrNull()?.let { track ->
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

                    Row(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(end = 4.dp, bottom = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        if (entry.catalog.playableAudioTracks.isNotEmpty()) {
                            VolumeControl(
                                volume = entry.volume,
                                enabled = entry.isPlaying || entry.isPaused,
                                onVolumeChange = { vm.updateVolume(entry, it) },
                                onToggleMute = { vm.toggleMute(entry) },
                            )
                        }
                        IconButton(
                            onClick = onFullscreen,
                            enabled = entry.isPlaying || entry.isPaused,
                        ) {
                            Icon(
                                imageVector = Icons.Default.Fullscreen,
                                contentDescription = "Fullscreen",
                                tint = Color.White,
                            )
                        }
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

            if (entry.player != null) {
                DiagnosticsCard(entry)
            }
        }
    }
}

@Composable
private fun FullscreenPlayerOverlay(
    entry: BroadcastEntry,
    vm: PlayerDemoViewModel,
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

                if (entry.catalog.playableAudioTracks.isNotEmpty()) {
                    VolumeControl(
                        volume = entry.volume,
                        enabled = entry.isPlaying || entry.isPaused,
                        onVolumeChange = { vm.updateVolume(entry, it) },
                        onToggleMute = { vm.toggleMute(entry) },
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(end = 16.dp, bottom = 16.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun VolumeControl(
    volume: Float,
    enabled: Boolean,
    onVolumeChange: (Float) -> Unit,
    onToggleMute: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        IconButton(
            onClick = onToggleMute,
            enabled = enabled,
            modifier = Modifier.size(40.dp),
        ) {
            Icon(
                imageVector = if (volume == 0f) {
                    Icons.AutoMirrored.Filled.VolumeOff
                } else {
                    Icons.AutoMirrored.Filled.VolumeUp
                },
                contentDescription = if (volume == 0f) "Unmute" else "Mute",
                tint = if (enabled) Color.White else Color.White.copy(alpha = 0.38f),
            )
        }
        Slider(
            value = volume,
            onValueChange = onVolumeChange,
            enabled = enabled,
            valueRange = 0f..1f,
            modifier = Modifier.width(104.dp),
        )
    }
}

@Composable
private fun DiagnosticsCard(entry: BroadcastEntry) {
    var isExpanded by remember { mutableStateOf(true) }
    val stats = entry.playbackStats

    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
        ),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { isExpanded = !isExpanded },
            ) {
                Text(
                    text = "Stats for Nerds",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Medium,
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    entry.startupDiagnostics.playRequestToPlaybackStart?.let { duration ->
                        Text(
                            text = "start ${formatMs(duration)}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    stats?.videoLatency?.let { latency ->
                        Text(
                            text = formatMs(latency),
                            style = MaterialTheme.typography.labelSmall,
                            color = latencyColor(latency),
                        )
                    }
                    stats?.videoFps?.let { fps ->
                        Text(
                            text = formatFps(fps),
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
                    StartupDiagnosticsSection(entry)
                    SelectedTracksSection(entry)
                    if (stats != null) {
                        LiveStatsSections(entry, stats)
                    } else {
                        StatsSection("Live") {
                            StatRow("Playback samples", "pending", MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StartupDiagnosticsSection(entry: BroadcastEntry) {
    val startup = entry.startupDiagnostics

    StatsSection("Startup") {
        val initToPlayRequest = startup.initToPlayRequest
        if (initToPlayRequest != null) {
            StatRow("Init -> play request", formatMs(initToPlayRequest))
        } else {
            StatRow("Init -> play request", "pending", MaterialTheme.colorScheme.onSurfaceVariant)
        }

        val playRequestToPlaybackStart = startup.playRequestToPlaybackStart
        if (playRequestToPlaybackStart != null) {
            StatRow(
                "Play request -> playback",
                formatMs(playRequestToPlaybackStart),
                startupColor(playRequestToPlaybackStart),
            )
        } else if (startup.playRequestedAt != null) {
            StatRow("Play request -> playback", "pending", MaterialTheme.colorScheme.onSurfaceVariant)
        }

        startup.playbackStartedByKind?.let { kind ->
            StatRow("Playback start trigger", kind.value)
        }

        entry.playbackStats?.let { stats ->
            stats.timeToFirst.videoFrame?.let { duration ->
                StatRow("Play request -> video playable", formatMs(duration), startupColor(duration))
            }
            stats.timeToFirst.audioFrame?.let { duration ->
                StatRow("Play request -> audio playable", formatMs(duration), startupColor(duration))
            }
            stats.timeToFirst.videoPlaying?.let { duration ->
                StatRow("Play request -> video playing", formatMs(duration), startupColor(duration))
            }
            stats.timeToFirst.audioPlaying?.let { duration ->
                StatRow("Play request -> audio playing", formatMs(duration), startupColor(duration))
            }
        }
    }

    if (startup.orderedTracks.isNotEmpty()) {
        StatsSection("Track Lifecycle") {
            startup.orderedTracks.forEach { track ->
                TrackStartupView(
                    track = track,
                    playRequestedAt = startup.playRequestedAt,
                    formatMs = { duration -> formatMs(duration) },
                    startupColor = { duration -> startupColor(duration) },
                )
            }
        }
    }
}

@Composable
private fun SelectedTracksSection(entry: BroadcastEntry) {
    if (entry.selectedVideoTrack == null && entry.selectedAudioTrack == null) return

    StatsSection("Selected Tracks") {
        entry.selectedVideoTrack?.let { video ->
            StatRow("Video track", trackLabel(video.name))
            StatRow("Video codec", video.config.codec)
            video.config.coded?.let { coded ->
                StatRow("Video coded size", "${coded.width}x${coded.height}")
            }
            video.config.framerate?.let { fps ->
                StatRow("Declared frame rate", formatFps(fps))
            }
            video.config.bitrate?.let { bitrate ->
                StatRow("Declared video bitrate", formatBitsPerSecond(bitrate))
            }
        }
        entry.selectedAudioTrack?.let { audio ->
            StatRow("Audio track", trackLabel(audio.name))
            StatRow("Audio codec", audio.config.codec)
            StatRow(
                "Audio format",
                "${audio.config.sampleRate} Hz / ${audio.config.channelCount} ch",
            )
            audio.config.bitrate?.let { bitrate ->
                StatRow("Declared audio bitrate", formatBitsPerSecond(bitrate))
            }
        }
    }
}

@Composable
private fun LiveStatsSections(entry: BroadcastEntry, stats: PlaybackStats) {
    if (stats.videoLatency != null || stats.audioLatency != null) {
        StatsSection("Latency") {
            stats.videoLatency?.let { latency ->
                StatRow("Video live latency", formatMs(latency), latencyColor(latency))
            }
            stats.audioLatency?.let { latency ->
                StatRow("Audio live latency", formatMs(latency), latencyColor(latency))
            }
        }
    }

    if (stats.audioRingBuffer != null || stats.videoJitterBuffer != null) {
        StatsSection("Buffers") {
            stats.videoJitterBuffer?.let { buffer ->
                StatRow("Video jitter buffer", formatMs(buffer), bufferColor(buffer, entry.targetLatencyMs))
            }
            stats.audioRingBuffer?.let { buffer ->
                StatRow("Audio ring buffer", formatMs(buffer), bufferColor(buffer, entry.targetLatencyMs))
            }
            StatRow("Target buffer", formatMs(entry.targetLatencyMs.toDouble()))
        }
    }

    if (stats.videoBitrateKbps != null || stats.audioBitrateKbps != null || stats.videoFps != null) {
        StatsSection("Throughput") {
            stats.videoBitrateKbps?.let { kbps ->
                StatRow("Video bitrate", formatBitrate(kbps))
            }
            stats.audioBitrateKbps?.let { kbps ->
                StatRow("Audio bitrate", formatBitrate(kbps))
            }
            stats.videoFps?.let { fps ->
                StatRow("Displayed frame rate", formatFps(fps))
            }
        }
    }

    stats.videoDecodeStats?.let { decode ->
        StatsSection("Decode") {
            StatRow("Track", decode.trackName)
            StatRow(
                "Min / avg / max",
                "${formatMs(decode.min)} / ${formatMs(decode.average)} / ${formatMs(decode.max)}",
            )
            val minOutputInterval = decode.minOutputInterval
            val averageOutputInterval = decode.averageOutputInterval
            val maxOutputInterval = decode.maxOutputInterval
            if (
                minOutputInterval != null &&
                averageOutputInterval != null &&
                maxOutputInterval != null
            ) {
                StatRow(
                    "Output interval",
                    "${formatMs(minOutputInterval)} / " +
                        "${formatMs(averageOutputInterval)} / " +
                        formatMs(maxOutputInterval),
                )
            }
            StatRow("In flight", decode.inFlightBufferCount.toString())
            StatRow("Last", formatMs(decode.last))
            StatRow("Samples", decode.sampleCount.toString())
        }
    }

    if (stats.videoSwitches != null || stats.audioSwitches != null) {
        StatsSection("Track Switches") {
            stats.videoSwitches?.let { switches ->
                TrackSwitchStatsView(
                    kind = "Video",
                    switches = switches,
                    formatMs = { duration -> formatMs(duration) },
                    startupColor = { duration -> startupColor(duration) },
                )
            }
            stats.audioSwitches?.let { switches ->
                TrackSwitchStatsView(
                    kind = "Audio",
                    switches = switches,
                    formatMs = { duration -> formatMs(duration) },
                    startupColor = { duration -> startupColor(duration) },
                )
            }
        }
    }

    if (hasHealthStats(stats)) {
        StatsSection("Health") {
            stats.videoStalls?.let { stalls ->
                StatRow("Video stalls", formatStalls(stalls), stallColor(stalls))
            }
            stats.audioStalls?.let { stalls ->
                StatRow("Audio stalls", formatStalls(stalls), stallColor(stalls))
            }
            stats.videoFramesDropped?.let { dropped ->
                StatRow(
                    "Video frames dropped",
                    dropped.toString(),
                    if (dropped > 0L) Color.Red else MaterialTheme.colorScheme.onSurface,
                )
            }
            stats.audioFramesDropped?.let { dropped ->
                StatRow(
                    "Audio frames dropped",
                    dropped.toString(),
                    if (dropped > 0L) Color.Red else MaterialTheme.colorScheme.onSurface,
                )
            }
        }
    }

    if (stats.videoArrival != null || stats.audioArrival != null) {
        StatsSection("Frame Arrival") {
            stats.videoArrival?.let { arrival ->
                ArrivalStatsView(kind = "Video", arrival = arrival)
            }
            stats.audioArrival?.let { arrival ->
                ArrivalStatsView(kind = "Audio", arrival = arrival)
            }
        }
    }
}

@Composable
private fun TrackStartupView(
    track: TrackStartupDiagnostics,
    playRequestedAt: Instant?,
    formatMs: (Duration) -> String,
    startupColor: (Duration) -> Color,
) {
    val kind = when (track.kind) {
        PlayerTrackKind.AUDIO -> "Audio"
        PlayerTrackKind.VIDEO -> "Video"
    }
    val title = if (track.isTrackSwitch) "$kind switch" else "$kind startup"
    val status = when {
        track.errorAt != null -> "error" to Color.Red
        track.activeAt != null -> "active" to Color(0xFF4CAF50)
        track.playingAt != null -> "playing" to Color(0xFF4CAF50)
        track.readyAt != null -> "ready" to Color(0xFF4CAF50)
        track.subscribeStartedAt != null -> "subscribing" to Color(0xFFFFA500)
        else -> "pending" to MaterialTheme.colorScheme.onSurfaceVariant
    }

    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Medium,
            )
            Text(
                text = status.first,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = status.second,
            )
        }
        track.trackName?.let { trackName ->
            StatRow("Track", trackName)
        }
        if (track.isTrackSwitch) {
            val operationToReady = track.operationToReady(playRequestedAt)
            if (operationToReady != null) {
                StatRow("Switch -> ready", formatMs(operationToReady), startupColor(operationToReady))
            } else if (track.subscribeStartedAt != null && track.errorAt == null) {
                StatRow("Switch -> ready", "pending", MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            val subscribeToReady = track.subscribeToReady()
            if (subscribeToReady != null) {
                StatRow("Subscribe -> ready", formatMs(subscribeToReady), startupColor(subscribeToReady))
            } else if (track.subscribeStartedAt != null && track.errorAt == null) {
                StatRow("Subscribe -> ready", "pending", MaterialTheme.colorScheme.onSurfaceVariant)
            }
            track.operationToReady(playRequestedAt)?.let { duration ->
                StatRow("Play request -> ready", formatMs(duration), startupColor(duration))
            }
        }
        track.readyToPlaying()?.let { duration ->
            StatRow("Ready -> playing", formatMs(duration), startupColor(duration))
        }
        track.operationToPlaying(playRequestedAt)?.let { duration ->
            StatRow("${track.operationLabel} -> playing", formatMs(duration), startupColor(duration))
        }
        track.operationToActive(playRequestedAt)?.let { duration ->
            StatRow("${track.operationLabel} -> active", formatMs(duration), startupColor(duration))
        }
        track.errorMessage?.let { message ->
            StatRow("Error", message, Color.Red)
        }
    }
}

@Composable
private fun TrackSwitchStatsView(
    kind: String,
    switches: TrackSwitchStats,
    formatMs: (Duration) -> String,
    startupColor: (Duration) -> Color,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            text = kind,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Medium,
        )
        StatRow("Switches", "${switches.completedCount} / ${switches.requestedCount}")
        switches.latest?.let { latest ->
            latest.trackName?.let { trackName ->
                StatRow("Latest track", trackName)
            }
            StatRow("Latest status", latestStatus(latest), latestStatusColor(latest))
            latest.switchToReady?.let { duration ->
                StatRow("Switch -> ready", formatMs(duration), startupColor(duration))
            }
            latest.readyToPlaying?.let { duration ->
                StatRow("Ready -> playing", formatMs(duration), startupColor(duration))
            }
            latest.switchToPlaying?.let { duration ->
                StatRow("Switch -> playing", formatMs(duration), startupColor(duration))
            }
            latest.switchToActive?.let { duration ->
                StatRow("Switch -> active", formatMs(duration), startupColor(duration))
            }
            latest.errorMessage?.let { message ->
                StatRow("Error", message, Color.Red)
            }
        }
    }
}

@Composable
private fun ArrivalStatsView(kind: String, arrival: FrameArrivalStats) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            text = kind,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Medium,
        )
        arrival.receivedFramesPerSecond?.let { fps ->
            StatRow("Received rate", formatFps(fps))
        }
        arrival.averageInterarrival?.let { average ->
            StatRow("Average interarrival", formatMs(average))
        }
        arrival.maxInterarrival?.let { max ->
            StatRow("Max interarrival", formatMs(max))
        }
        StatRow(
            "Slow arrivals",
            arrival.slowArrivalCount.toString(),
            if (arrival.slowArrivalCount > 0L) Color(0xFFFFA500) else MaterialTheme.colorScheme.onSurface,
        )
        StatRow(
            "Fast arrivals",
            arrival.fastArrivalCount.toString(),
            if (arrival.fastArrivalCount > 0L) Color(0xFFFFA500) else MaterialTheme.colorScheme.onSurface,
        )
        StatRow(
            "Out of order",
            outOfOrderValue(arrival),
            if (arrival.outOfOrderCount > 0L) Color.Red else MaterialTheme.colorScheme.onSurface,
        )
        StatRow(
            "Discontinuities",
            discontinuityValue(arrival),
            if (arrival.discontinuityCount > 0L) Color(0xFFFFA500) else MaterialTheme.colorScheme.onSurface,
        )
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

private fun hasHealthStats(stats: PlaybackStats): Boolean {
    return stats.videoStalls != null ||
        stats.audioStalls != null ||
        stats.videoFramesDropped != null ||
        stats.audioFramesDropped != null
}

private fun latestStatus(latest: TrackSwitch): String {
    if (latest.errorMessage != null) return "error"
    if (latest.isCompleted) return "active"
    if (latest.switchToPlaying != null) return "playing"
    if (latest.switchToReady != null) return "ready"
    return "pending"
}

private fun latestStatusColor(latest: TrackSwitch): Color {
    if (latest.errorMessage != null) return Color.Red
    if (latest.isCompleted || latest.switchToPlaying != null || latest.switchToReady != null) {
        return Color(0xFF4CAF50)
    }
    return Color(0xFFFFA500)
}

private fun latencyColor(ms: Double): Color {
    if (ms < 150) return Color(0xFF4CAF50)
    if (ms < 500) return Color(0xFFFFA500)
    return Color.Red
}

private fun latencyColor(duration: Duration): Color = latencyColor(duration.milliseconds)

private fun startupColor(ms: Double): Color {
    if (ms < 250) return Color(0xFF4CAF50)
    if (ms < 1000) return Color(0xFFFFA500)
    return Color.Red
}

private fun startupColor(duration: Duration): Color = startupColor(duration.milliseconds)

private fun bufferColor(duration: Duration, targetLatencyMs: Int): Color {
    val ms = duration.milliseconds
    if (ms < targetLatencyMs * 0.25) return Color(0xFFFFA500)
    if (ms > targetLatencyMs * 2) return Color(0xFFFFA500)
    return Color.Unspecified
}

private fun stallColor(stats: StallStats): Color {
    return if (stats.count > 0L) Color(0xFFFFA500) else Color.Unspecified
}

private fun formatBitrate(kbps: Double): String {
    if (kbps >= 1000) return String.format("%.1f Mbps", kbps / 1000)
    return "${kbps.toInt()} kbps"
}

private fun formatBitsPerSecond(bps: ULong): String = formatBitrate(bps.toDouble() / 1000.0)

private fun formatFps(fps: Double): String {
    if (fps >= 10) return "${fps.toInt()} fps"
    return String.format("%.1f fps", fps)
}

private fun formatStalls(stats: StallStats): String {
    return "${stats.count} / ${formatMs(stats.totalDuration)} / ${formatPercent(stats.rebufferingRatio)}"
}

private fun formatPercent(ratio: Double): String = String.format("%.1f%%", ratio * 100.0)

private fun formatMs(ms: Double): String {
    if (ms >= 1000) return String.format("%.2f s", ms / 1000)
    return "${ms.toInt()} ms"
}

private fun formatMs(duration: Duration): String = formatMs(duration.milliseconds)

private fun trackLabel(value: String): String = value.ifEmpty { "unnamed" }

private fun outOfOrderValue(arrival: FrameArrivalStats): String {
    val delta = arrival.maxOutOfOrderDelta ?: return arrival.outOfOrderCount.toString()
    return "${arrival.outOfOrderCount} / max ${formatMs(delta)}"
}

private fun discontinuityValue(arrival: FrameArrivalStats): String {
    val gap = arrival.maxDiscontinuityGap ?: return arrival.discontinuityCount.toString()
    return "${arrival.discontinuityCount} / max ${formatMs(gap)}"
}

private val Duration.milliseconds: Double
    get() = seconds.toDouble() * 1_000.0 + nano.toDouble() / 1_000_000.0

@Composable
private fun RenditionPickerRow(entry: BroadcastEntry, vm: PlayerDemoViewModel) {
    val tracks = remember(entry.catalog.playableVideoTracks) {
        entry.catalog.playableVideoTracks.sortedByDescending {
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

private fun canConnect(state: Session.State): Boolean = when (state) {
    Session.State.Idle,
    is Session.State.Error,
    Session.State.Closed -> true

    Session.State.Connecting,
    Session.State.Connected -> false
}

private fun canStop(state: Session.State): Boolean = when (state) {
    Session.State.Connecting,
    Session.State.Connected -> true

    Session.State.Idle,
    is Session.State.Error,
    Session.State.Closed -> false
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
