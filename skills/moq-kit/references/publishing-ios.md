# Publishing — iOS (Swift)

## Independent capture and publication

`CameraCapture` and `MicrophoneCapture` own hardware. Their async `start()` and `stop()`
are idempotent; `close()` is terminal. Preview never starts capture implicitly.
Audio/video registration returns `PublishedMediaTrack`, with `enabled: true` by default.

```swift
let camera = CameraCapture(camera: Camera(position: .front))
let microphone = MicrophoneCapture()
let publisher = try Publisher()
let video = try publisher.addVideoTrack(source: camera)
let audio = try publisher.addAudioTrack(source: microphone, enabled: false)
try await session.publish(path: "live/ios", publisher: publisher)
try await publisher.start() // idle media handles; no camera/mic encoders yet

try await camera.start()       // preview and enabled video publication
try await microphone.start()   // hardware only: audio publication is disabled
try await audio.setEnabled(true)
microphone.isMuted = true      // silence; capture, encoder and catalog stay active
try await video.setEnabled(false) // release video encoder; preview continues
await camera.stop()           // release camera hardware and suspend preview
try await video.setEnabled(true)  // records intent; does not start the camera
try await camera.start()       // preview and publication resume on the same objects

await video.stop()             // terminal detach; capture may continue
await publisher.stop()         // end broadcast; captures remain app-owned
await camera.close()
await microphone.close()
await session.close()
```

Disabling publication or stopping its capture finishes the media producer, removes its
hang catalog entry and releases the encoder. Restart creates a new wire track name;
subscribers must follow catalog updates. The logical handle stays the same.
A publisher remains open with an empty catalog until explicitly stopped or its session ends.

Use one publication attachment per built-in camera/microphone. Disable and capture stop
retain that attachment; track stop, publisher stop, or capture close release it.
The camera supports one preview plus publication simultaneously.

`isEnabled` reports requested publication intent. Per-track states are `idle`
(waiting for capture), `disabled`, `starting`, `active`, `failed(message)`, and terminal
`stopped`. Await `setEnabled` for local encoder setup/teardown; `active` follows the
first publishable output. Failure retains intent: `setEnabled(true)` retries, as does
a new capture run. Calls on a terminal handle throw.

To release this SDK's camera/microphone use, await capture `stop()`; mute and publication
disable leave explicitly started hardware active. Other app/OS consumers and the OS's
recent-use indicator can still report device use. The app owns its `AVAudioSession`
category and activation.

## Camera and preview

```swift
let camera = CameraCapture(camera: Camera(position: .front, width: 720, height: 1280, orientation: .portrait))
try await camera.start()                       // NSCameraUsageDescription required
try camera.switch(to: Camera(position: .back)) // flip
await camera.stop()
```

`CameraCapture` exposes `captureSession: AVCaptureSession` — attach an `AVCaptureVideoPreviewLayer` (e.g. a `UIView` whose `layerClass` is `AVCaptureVideoPreviewLayer`) and reuse the same `CameraCapture` for preview and publishing.

## Multi-camera

```swift
guard MultiCameraCapture.isSupported else { … }   // fails on many devices — always check
let cameras = MultiCameraCapture(front: Camera(position: .front, width: 720, height: 1280),
                                 back: Camera(position: .back, width: 720, height: 1280),
                                 maxFrameRate: 30)
try await cameras.start()
try publisher.addVideoTrack(name: "front-camera", source: cameras.frontSource, config: videoConfig)
try publisher.addVideoTrack(name: "back-camera", source: cameras.backSource, config: videoConfig)
```

Front and back are two separate sources → two video tracks. Multi-cam preview needs `AVCaptureVideoPreviewLayer(sessionWithNoConnection:)` with manually wired connections.

## Microphone and AVAudioSession

```swift
// Configure AVAudioSession BEFORE start — MicrophoneCapture sets
// usesApplicationAudioSession = true and will NOT configure it for you.
let audioSession = AVAudioSession.sharedInstance()
try audioSession.setCategory(.playAndRecord, mode: .videoRecording,
                             options: [.defaultToSpeaker, .allowBluetoothHFP]) // .allowBluetooth on pre-iOS-26 SDKs
try audioSession.setActive(true)

let microphone = MicrophoneCapture() // NSMicrophoneUsageDescription required
try await microphone.start()
```

Wrong/missing category is the classic "no mic audio" bug; switch back to `.playback` when returning to watch-only mode. `MicrophoneCapture` has no sample-rate knob — the encoder resamples to `AudioEncoderConfig.sampleRate` internally.

Set `microphone.isMuted = true` to send silence, and `false` to resume microphone audio.
Muting keeps capture, the encoder, and the published audio track running with continuous
timestamps. It does not release the microphone or change `AVAudioSession`; use `stop()` to
stop capture. The property is thread-safe, defaults to `false`, can be set before `start()`,
and persists across stop/start. Changes affect subsequent captured buffers; audio already
queued for encoding or playback is unaffected.

## Encoder configs and codec gating

```swift
VideoEncoderConfig(codec: .h264, width: 1920, height: 1080, bitrate: 1_500_000,
                   keyframeInterval: 2.0, maxFrameRate: 30.0)   // defaults shown; also optional profileLevel, naluFormat
AudioEncoderConfig(codec: .opus, sampleRate: 48000, channels: 1, bitrate: 128_000) // iOS default codec: opus
```

Build codec pickers from `VideoEncoderConfig.supportedCodecs()` / `AudioEncoderConfig.supportedCodecs()`; check an exact config with `.isSupported` / `.unsupportedReason`. Video encode is H.264/H.265 only (no AV1); H.265 auto-selects Annex B NALU format, and concurrent H.265 encoders (multi-cam) are unreliable on many devices — default to H.264.

## Custom sources

Any `FrameSource` (class-bound, `Sendable`; a settable `var onFrame: (@Sendable (CMSampleBuffer) -> Bool)?`) works as a track source; `FrameRelay` is the ready-made bridge — call `relay.send(sampleBuffer)` with your own video or audio samples.

- **The callback's `Bool` return is the stop signal.** `false` means the consumer is gone (the track stopped) — stop producing. Built-in captures remain explicitly app-owned; publication detaches the callback when disabled.
- **Timestamps must be host-clock.** `Publisher` shares one `PublisherClock` across all its tracks and takes the epoch from the first frame of *any* track, so PTS from a private zero-based timeline drifts against a live mic or schedules video far ahead of the render clock. Stamp buffers with `CMClockGetTime(CMClockGetHostTimeClock())` — the domain `CameraCapture` and `MicrophoneCapture` already produce.

## Permissions

Info.plist: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription` (relays on the local network). The SDK adds none of these.

## Teardown

Cancel observer tasks, then await `publisher.stop()` and capture `close()` when their
owning screen ends. Restore the app's audio session and await `session.close()` if no
longer needed. To keep preview, leave camera capture running after publisher stop.
`session.unpublish(path:)` and `PublishedTrack.stop()` are also async.
Registration methods throw on duplicate names, closed sources, or a second attachment.
Automatic availability propagation is specific to camera and microphone; custom sources,
screen capture and multi-camera retain their existing source contracts.
