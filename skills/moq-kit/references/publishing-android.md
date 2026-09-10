# Publishing — Android (Kotlin)

## Independent capture and publication

`CameraCapture` and `MicrophoneCapture` own hardware. `start`, `stop`, and terminal
`close` are suspend functions. Start/stop are idempotent; preview never starts capture.
Audio/video registration returns `PublishedMediaTrack`, with `enabled = true` by default.

```kotlin
val camera = CameraCapture(position = CameraPosition.Front)
val microphone = MicrophoneCapture()
val publisher = Publisher()
val video = publisher.addVideoTrack(source = camera)
val audio = publisher.addAudioTrack(source = microphone, enabled = false)
session.publish("live/android", publisher)
publisher.start() // idle media handles; no camera/mic encoders yet

camera.start(context, lifecycleOwner) // preview and enabled video publication
microphone.start()                    // hardware only; audio is disabled
audio.setEnabled(true)
microphone.isMuted = true             // silence; encoder and catalog stay active
video.setEnabled(false)               // release encoder; preview continues
camera.stop()                         // release hardware and suspend preview
video.setEnabled(true)                // records intent; does not start hardware
camera.start(context, lifecycleOwner) // resume using the same objects

video.stop()                          // terminal detach; capture may continue
publisher.stop()                      // end broadcast; captures remain app-owned
camera.close()
microphone.close()
session.close()
```

Disabling publication or stopping its capture finishes the media producer, removes its
hang catalog entry and releases the encoder. Restart creates a new wire track name;
subscribers must follow catalog updates. The logical handle stays the same.
A publisher remains open with zero active tracks until explicitly stopped or its session ends.

A built-in camera/microphone accepts one publication attachment. Disable and capture stop
retain it; track stop, publisher stop, or capture close release it.
`isEnabled` reports intent. States are `Idle` (waiting for capture), `Disabled`,
`Starting`, `Active`, `Failed(message)`, and terminal `Stopped`.
Await `setEnabled` for local setup/teardown; active follows the first publishable output.
After failure, `setEnabled(true)` retries; a new capture run also retries.
Calls on a terminal handle throw.

To release this SDK's camera/microphone use, await capture `stop()`. Mute and publication
disable leave explicitly started hardware active. Other consumers and the OS's recent-use
indicator can still report use.

## Camera and preview

```kotlin
val camera = CameraCapture(position = CameraPosition.Back, width = 1920, height = 1080, frameRate = 30)
camera.start(context, lifecycleOwner) // suspend; CameraX binds to this lifecycle; CAMERA permission required
camera.switchCamera()                 // suspend
camera.stop()
```

Preview: call `camera.setPreviewSurface(surface)` with one `SurfaceView` surface,
including before start. Call `setPreviewSurface(null)` synchronously in
`surfaceDestroyed` before the surface owner releases it. For a `TextureView`, release
the app-created `Surface` wrapper after detaching it. The capture borrows preview surfaces.

CameraX feeds one GL input texture, which fans out to preview and the publisher's encoder
surface simultaneously. Capture owns GL; publication owns the codec surface. Disabling
publication detaches that destination without affecting preview.

## Multi-camera

```kotlin
if (!MultiCameraCapture.isFrontBackSupported(context)) return // suspend; real CameraX pair check
val cameras = MultiCameraCapture(
    front = CameraStreamConfig(CameraPosition.Front, 1280, 720, 30),
    back = CameraStreamConfig(CameraPosition.Back, 1280, 720, 30),
)
cameras.start(context, lifecycleOwner)
publisher.addVideoTrack("front-camera", cameras.frontSource, videoConfig)
publisher.addVideoTrack("back-camera", cameras.backSource, videoConfig)
```

Two checks: `isSupported(context)` (cheap `PackageManager` feature check — gate UI on it) and `isFrontBackSupported(context)` (suspend; verifies an actual concurrent front/back pair — gate `start()` on it). They're enforced, not advisory: `start()` throws `IllegalStateException` without a concurrent pair, and the constructor `require`s that `front`/`back` positions match their labels. Front and back are two separate sources → two video tracks. The demo previews multi-cam with two `TextureView`s.

## Microphone

```kotlin
val microphone = MicrophoneCapture(sampleRate = 48_000, channels = 1)
microphone.start() // suspend; throws if permission or AudioRecord startup fails
microphone.stop()
```

Request `RECORD_AUDIO` before starting. `start()` is annotated
`@RequiresPermission(RECORD_AUDIO)`. Keep the capture and encoder sample rates equal
(Opus requires 48 kHz). Failed startup releases partial resources and can be retried.

Set `microphone.isMuted = true` to send silence, and `false` to resume microphone audio.
Muting keeps capture, the encoder, and the published audio track running with continuous
timestamps. It does not release the microphone; use `stop()` to stop capture. The property
is thread-safe, defaults to `false`, can be set before `start()`, and persists across
stop/start. Changes affect subsequent captured buffers; audio already queued for encoding
or playback is unaffected. Do not implement mute by replacing `onPcmData`: the publisher
owns that callback and installs it when the track starts.

## Encoder configs and codec gating

```kotlin
VideoEncoderConfig(codec = VideoCodec.H264, width = 1920, height = 1080, bitrate = 1_500_000,
                   keyframeIntervalSeconds = 2, frameRate = 30)  // defaults shown; also optional profile
AudioEncoderConfig(codec = AudioCodec.AAC, sampleRate = 48_000, channels = 1, bitrate = 128_000) // Android default codec: aac
```

Build codec pickers from `VideoEncoderConfig.supportedCodecs()` / `AudioEncoderConfig.supportedCodecs()`; check an exact config with `.isSupported` / `.unsupportedReason`. Encoder support varies per device — H.264 is the safe default; gate H.265 explicitly.

## Custom sources

Implement `VideoFrameSource` (encoder-`Surface`-based: `attachEncoderSurface`/`detachEncoderSurface`/`setPreviewSurface`) or `AudioFrameSource` (`onPcmData: (ByteArray, Int, Long) -> Unit`, 16-bit PCM). Advanced — the built-in captures cover camera/mic/screen.

**Timestamps must share one clock domain.** `Publisher` stamps all of its tracks against a single epoch taken from the first frame of *any* track, so a source with a private zero-based timeline drifts against a live mic or leaves video scheduled far ahead. Use `SystemClock.elapsedRealtimeNanos() / 1_000` for `onPcmData`'s `timestampUs` (exactly what `MicrophoneCapture` does) and drive the encoder surface's presentation timestamps off the same clock.

`Publisher` sets `onPcmData` when the audio track starts and clears it when the track stops — don't set it yourself on a source you hand to a publisher.

## Permissions

Manifest: `INTERNET`, `CAMERA`, `RECORD_AUDIO` — declare **and** request at runtime (`RequestMultiplePermissions`) before starting captures. The library does not add them transitively. Screen capture additionally needs the MediaProjection foreground-service setup (see the screen-capture reference).

## Teardown

Cancel observer jobs → `publisher.stop()` → `camera.stop()` / `microphone.stop()` → `session.close()` if no longer needed. `session.unpublish(path)` is equivalent to `publisher.stop()` for that path.

Automatic source availability propagation is specific to camera and microphone. Custom,
screen and multi-camera sources keep their existing contracts. Data handles expose terminal
`stop()` and state only; `setEnabled` belongs to `PublishedMediaTrack`.
