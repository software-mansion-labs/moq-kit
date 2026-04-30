package com.swmansion.moqdemo.features.publisher

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import com.swmansion.moqkit.Session
import com.swmansion.moqkit.publish.PublishedTrackState
import com.swmansion.moqkit.publish.PublisherState
import com.swmansion.moqkit.publish.encoder.AudioCodec
import com.swmansion.moqkit.publish.encoder.VideoCodec

@Composable
fun PublisherDemoScreen(vm: PublisherViewModel = viewModel()) {
    val lifecycleOwner = LocalLifecycleOwner.current
    val context = LocalContext.current

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        val allGranted = results.values.all { it }
        if (allGranted) vm.startCamera(lifecycleOwner)
    }

    val screenCaptureLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            // Must start the foreground service here, inside the activity result callback.
            // Android 14+ enforces that mediaProjection foreground services are started
            // from the same callback that received the screen capture permission.
            context.startForegroundService(Intent(context, ScreenCaptureService::class.java))
            vm.setScreenProjection(result.resultCode, result.data!!)
        } else {
            vm.screenEnabled = false
        }
    }

    // Start camera preview when screen appears if camera is enabled
    LaunchedEffect(vm.cameraEnabled) {
        if (vm.cameraEnabled) {
            permissionLauncher.launch(
                arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
            )
        } else {
            vm.stopCamera()
        }
    }

    // Request screen capture permission when toggle is enabled
    LaunchedEffect(vm.screenEnabled) {
        if (vm.screenEnabled) {
            val manager = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            screenCaptureLauncher.launch(manager.createScreenCaptureIntent())
        } else {
            vm.clearScreenProjection()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(WindowInsets.systemBars.asPaddingValues())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // Connection controls
        ConnectionSection(vm = vm, lifecycleOwner = lifecycleOwner, permissionLauncher = { permissions ->
            permissionLauncher.launch(permissions)
        })

        // Session state indicator
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(stateColor(vm.sessionState))
            )
            Spacer(Modifier.width(8.dp))
            Text(vm.stateLabel, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        // Camera preview
        if (vm.cameraEnabled) {
            CameraPreviewCard(vm = vm)
        }

        // Config (when not publishing)
        if (!vm.isPublishing) {
            SourceConfigCard(vm = vm)
            CodecConfigCard(vm = vm)
        }

        // Publishing status (when publishing)
        if (vm.isPublishing || vm.publisherState == PublisherState.Stopped) {
            PublishingStatusCard(vm = vm)
        }

        // Error banner
        vm.lastError?.let { error ->
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
                Text(
                    error,
                    modifier = Modifier.padding(12.dp),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onErrorContainer,
                )
            }
        }

        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun ConnectionSection(
    vm: PublisherViewModel,
    lifecycleOwner: androidx.lifecycle.LifecycleOwner,
    permissionLauncher: (Array<String>) -> Unit,
) {
    Card {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Connection", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)

            OutlinedTextField(
                value = vm.relayUrl,
                onValueChange = { vm.relayUrl = it },
                label = { Text("Relay URL") },
                singleLine = true,
                enabled = !vm.isPublishing,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = vm.broadcastPath,
                onValueChange = { vm.broadcastPath = it },
                label = { Text("Broadcast path") },
                singleLine = true,
                enabled = !vm.isPublishing,
                modifier = Modifier.fillMaxWidth(),
            )

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = {
                        permissionLauncher(arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO))
                        vm.publish(lifecycleOwner)
                    },
                    enabled = vm.canPublish,
                    modifier = Modifier.weight(1f),
                ) { Text("Publish") }

                OutlinedButton(
                    onClick = vm::stop,
                    enabled = vm.canStop,
                    modifier = Modifier.weight(1f),
                ) { Text("Stop") }
            }
        }
    }
}

@Composable
private fun CameraPreviewCard(vm: PublisherViewModel) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(16f / 9f)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.Black),
    ) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { context ->
                SurfaceView(context).apply {
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(h: SurfaceHolder) = vm.setPreviewSurface(h.surface)
                        override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, height: Int) = Unit
                        override fun surfaceDestroyed(h: SurfaceHolder) = vm.setPreviewSurface(null)
                    })
                }
            },
        )
        // Flip camera button
        IconButton(
            onClick = vm::flipCamera,
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(8.dp)
                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.7f), CircleShape),
        ) {
            Icon(Icons.Default.Cameraswitch, contentDescription = "Flip camera")
        }
    }
}

@Composable
private fun SourceConfigCard(vm: PublisherViewModel) {
    Card {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Sources", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)

            Text(
                "Video",
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Camera", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                Switch(checked = vm.cameraEnabled, onCheckedChange = { vm.cameraEnabled = it })
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Screen Capture", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                Switch(checked = vm.screenEnabled, onCheckedChange = { vm.screenEnabled = it })
            }

            Text(
                "Audio",
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Microphone", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                Switch(checked = vm.micEnabled, onCheckedChange = { vm.micEnabled = it })
            }
        }
    }
}

@Composable
private fun CodecConfigCard(vm: PublisherViewModel) {
    val availableAudioSampleRates = if (vm.audioCodec == AudioCodec.OPUS) {
        listOf(48_000)
    } else {
        listOf(44_100, 48_000)
    }

    Card {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Codec", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)

            // Video codec
            LabeledRow("Video codec") {
                SingleChoiceSegmentedButtonRow {
                    VideoCodec.entries.forEachIndexed { i, codec ->
                        SegmentedButton(
                            selected = vm.videoCodec == codec,
                            onClick = { vm.videoCodec = codec },
                            shape = SegmentedButtonDefaults.itemShape(i, VideoCodec.entries.size),
                            label = { Text(codec.name) },
                        )
                    }
                }
            }

            // Resolution
            LabeledRow("Resolution") {
                SingleChoiceSegmentedButtonRow {
                    VideoResolution.entries.forEachIndexed { i, res ->
                        SegmentedButton(
                            selected = vm.videoResolution == res,
                            onClick = { vm.videoResolution = res },
                            shape = SegmentedButtonDefaults.itemShape(i, VideoResolution.entries.size),
                            label = { Text(res.label) },
                        )
                    }
                }
            }

            // Frame rate
            LabeledRow("Frame rate") {
                SingleChoiceSegmentedButtonRow {
                    VideoFrameRate.entries.forEachIndexed { i, fps ->
                        SegmentedButton(
                            selected = vm.videoFrameRate == fps,
                            onClick = { vm.videoFrameRate = fps },
                            shape = SegmentedButtonDefaults.itemShape(i, VideoFrameRate.entries.size),
                            label = { Text("${fps.fps}fps") },
                        )
                    }
                }
            }

            // Audio codec
            LabeledRow("Audio codec") {
                SingleChoiceSegmentedButtonRow {
                    AudioCodec.entries.forEachIndexed { i, codec ->
                        SegmentedButton(
                            selected = vm.audioCodec == codec,
                            onClick = { vm.selectAudioCodec(codec) },
                            shape = SegmentedButtonDefaults.itemShape(i, AudioCodec.entries.size),
                            label = { Text(if (codec == AudioCodec.OPUS) "Opus" else "AAC") },
                        )
                    }
                }
            }

            // Audio sample rate
            LabeledRow("Sample rate") {
                SingleChoiceSegmentedButtonRow {
                    availableAudioSampleRates.forEachIndexed { i, rate ->
                        SegmentedButton(
                            selected = vm.audioSampleRate == rate,
                            onClick = { vm.audioSampleRate = rate },
                            shape = SegmentedButtonDefaults.itemShape(i, availableAudioSampleRates.size),
                            label = { Text(if (rate == 44_100) "44.1 kHz" else "48 kHz") },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun PublishingStatusCard(vm: PublisherViewModel) {
    Card {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(publisherStateColor(vm.publisherState))
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    "Publisher: ${vm.publisherStateLabel}",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                )
            }

            if (vm.publishedTracks.isNotEmpty()) {
                HorizontalDivider()
                vm.publishedTracks.forEach { track ->
                    val trackState = vm.trackStates[track.name] ?: PublishedTrackState.Idle
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .size(8.dp)
                                .clip(CircleShape)
                                .background(trackStateColor(trackState))
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            track.name,
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            trackState.name.lowercase(),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun LabeledRow(label: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        content()
    }
}

private fun stateColor(state: Session.State): Color = when (state) {
    Session.State.Idle -> Color.Gray
    Session.State.Connecting -> Color(0xFFFFA500)
    Session.State.Connected -> Color(0xFF2196F3)
    is Session.State.Error -> Color.Red
    Session.State.Closed -> Color.Gray
}

private fun publisherStateColor(state: PublisherState): Color = when (state) {
    PublisherState.Idle -> Color.Gray
    PublisherState.Publishing -> Color(0xFF4CAF50)
    PublisherState.Stopped -> Color(0xFFFFA500)
    is PublisherState.Error -> Color.Red
}

private fun trackStateColor(state: PublishedTrackState): Color = when (state) {
    PublishedTrackState.Idle -> Color.Gray
    PublishedTrackState.Starting -> Color(0xFFFFA500)
    PublishedTrackState.Active -> Color(0xFF4CAF50)
    PublishedTrackState.Stopped -> Color.Gray
}
