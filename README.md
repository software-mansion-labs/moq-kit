# moq-kit

Native Swift and Kotlin SDKs for publishing and playing low-latency media streams over QUIC.

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Platform: iOS](https://img.shields.io/badge/iOS-16%2B-blue.svg)
![Platform: Android](https://img.shields.io/badge/Android-API%2029%2B-3DDC84.svg)
[![Swift Package Manager](https://img.shields.io/github/v/tag/software-mansion-labs/moq-kit?label=SPM&sort=semver)](https://github.com/software-mansion-labs/moq-kit/tags)
[![Maven Central](https://img.shields.io/maven-central/v/com.swmansion.moqkit/moqkit?label=Maven%20Central)](https://central.sonatype.com/artifact/com.swmansion.moqkit/moqkit)

moq-kit gives iOS and Android apps platform-native APIs for Media over QUIC-style live
streaming: connect to a relay, discover broadcasts, publish camera/microphone/screen
tracks, play catalog-described streams, and send or receive raw data tracks.

It is built on top of the published UniFFI bindings generated from
[`moq-ffi`](https://github.com/moq-dev/moq/tree/main/rs/moq-ffi), the Rust bindings from
Luke Curley's [`moq-dev/moq`](https://github.com/moq-dev/moq) project.

For the repository codemap, layer boundaries, and invariants, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Table of contents

- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [What moq-kit supports](#what-moq-kit-supports)
- [Protocol](#protocol)
- [Installation](#installation)
- [Usage](#usage)
- [Demo apps](#demo-apps)
- [Local development](#local-development)
- [Status](#status)
- [License](#license)
- [Acknowledgments](#acknowledgments)

## Quick Start

Get a playing demo stream in two terminals:

1. Clone the repository with submodules (the Rust `vendor/moq` checkout is a submodule):

   ```bash
   git clone --recurse-submodules https://github.com/software-mansion-labs/moq-kit.git
   ```

2. Install [`mise`](https://mise.jdx.dev) — the project task runner used for every build
   and run command.

3. Start a local moq-lite relay in one terminal:

   ```bash
   mise run relay:run
   ```

4. Run the iOS or Android demo in another terminal:

   ```bash
   mise run ios:run --simulator    # or: mise run android:run
   ```

For SDK integration, jump to [Installation](#installation) and [Usage](#usage). See
[Prerequisites](#prerequisites) for the toolchains each workflow needs.

## Prerequisites

The repository's `mise.toml` is intentionally minimal and does **not** auto-install
language toolchains. Install the tools below manually before running the build commands.

Consumers integrating the published Swift Package or Maven Central artifact do not need
Rust, the Android NDK, or `cargo-ndk`.

### All platforms

- [`mise-en-place`](https://mise.jdx.dev) — task runner used for every build and run command.
- Rust toolchain (`rustup`, stable channel) — required for `vendor/moq` tasks such as
  running the local relay or Rust checks. Skip if you only consume the published packages.
- Git with submodule support (`vendor/moq` is a submodule).

### iOS development

- Xcode 16+ with Command Line Tools.
- Deployment target: iOS 16+ / macOS 13+.

### Android development

- Android Studio (Hedgehog or newer).
- Android SDK with API 35 (`compileSdk`) and platform 29+ (`minSdk`).
- Java 11+.

## Protocol

moq-kit currently targets [`moq-lite`](https://datatracker.ietf.org/doc/draft-lcurley-moq-lite/)
rather than the fast-changing IETF
[`moq-transport`](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/) draft wire
format.

MoQ is mainly a transport protocol. Media behavior is application-defined on top of that
transport, and moq-kit uses media catalogs and track conventions to describe codecs,
renditions, and app-level streams.

The main MOQ draft is still moving quickly and can break compatibility between versions.
moq-kit focuses on practical mobile functionality first: native capture, native playback,
catalogs, relay workflows, and usable app-level APIs. Luke Curley's moq-lite work is a good
fit for that direction because it emphasizes real deployments and concrete media use cases.

When the main MOQ draft stabilizes further, moq-kit may consider moving toward it.

## What moq-kit supports

- **Native SDKs** for iOS Swift and Android Kotlin.
- **Relay sessions** for publishing and consuming through the same MoQ relay.
- **Broadcast discovery** with catalog-driven track selection.
- **Publishing** from camera, iOS and Android multi-camera capture, microphone, iOS
  ReplayKit screen capture, Android screen capture, and raw data tracks.
- **Playback** with native low-latency renderers, dynamically adjustable target latency,
  track switching, and playback stats.
- **Data tracks** for app-defined payloads such as JSON chat messages.

The best-tested media path today is H.264 video with AAC or Opus audio.

| Codec        | iOS publish | iOS playback | Android publish | Android playback |
| ------------ | ----------- | ------------ | --------------- | ---------------- |
| H.264 / AVC  | ✅          | ✅           | ✅              | ✅               |
| H.265 / HEVC | ✅          | ✅           | ✅              | ✅               |
| AAC          | ✅          | ✅           | ✅              | ✅               |
| Opus         | ✅          | ✅           | ✅              | ✅               |
| AV1          | Not yet     | ✅\*         | Not yet         | ✅\*             |

\* AV1 playback depends on the platform decoder available at runtime. On Apple devices,
Apple documents AV1 playback for iPhone 15 Pro and says A17 Pro includes a dedicated AV1
decoder. moq-kit does not currently expose AV1 publishing, and iOS AV1 playback should be
treated as iPhone 15 Pro-class device support rather than broad Apple platform support.
See Apple's [iPhone 15 Pro tech specs](https://support.apple.com/en-us/111829) and
[A17 Pro announcement](https://www.apple.com/newsroom/2023/09/apple-unveils-iphone-15-pro-and-iphone-15-pro-max/)
for more context.

## Installation

moq-kit is in active preview. APIs, package versions, and relay compatibility may still change.

### iOS

Add the Swift package and depend on the `MoQKit` product:

```swift
.package(
    url: "https://github.com/software-mansion-labs/moq-kit",
    from: "0.1.0"
)
```

```swift
.product(name: "MoQKit", package: "moq-kit")
```

The Swift package depends on `https://github.com/moq-dev/moq-swift` from `0.2.29` for the
generated `MoqFFI` Swift bindings and prebuilt XCFramework.

The iOS SDK does not add permissions, entitlements, or audio-session configuration for
you. Camera publishing requires `NSCameraUsageDescription`. Microphone publishing requires
`NSMicrophoneUsageDescription`, and your app is responsible for configuring
`AVAudioSession` before starting `MicrophoneCapture`. ReplayKit Broadcast Upload
integrations also need a Broadcast Upload Extension target plus an App Group shared by the
host app and the extension.

### Android

Add Maven Central and the Android artifact:

```kotlin
repositories {
    google()
    mavenCentral()
}

dependencies {
    implementation("com.swmansion.moqkit:moqkit:0.1.0")
}
```

The Android SDK includes Kotlin APIs backed by the upstream `dev.moq:moq` Maven package,
which provides the UniFFI-generated Kotlin bindings and JNI libraries.

Android apps must declare the permissions they use. Typical integrations need `INTERNET`.
Camera publishing needs `CAMERA`, microphone publishing needs `RECORD_AUDIO`, and screen
capture needs the Android MediaProjection permission flow plus a foreground service with
the `mediaProjection` service type on Android versions that require it. The library does
not add these permissions transitively.

## Usage

Everything in moq-kit starts with a `Session`. A session owns one QUIC connection to a
relay and is the starting point for subscribing to broadcasts, publishing tracks, and
sharing relay state across app workflows.

### Play a broadcast in Swift

```swift
import MoQKit

let session = Session(url: "http://localhost:4443/anon")
try await session.connect()

let subscription = try session.subscribe(prefix: "live")

for await broadcast in subscription.broadcasts {
    for await catalog in broadcast.catalogs() {
        let videoTrack = catalog.playableVideoTracks.first?.name
        let audioTrack = catalog.playableAudioTracks.first?.name
        guard videoTrack != nil || audioTrack != nil else { continue }

        let player = try await MainActor.run {
            try Player(
                catalog: catalog,
                videoTrackName: videoTrack,
                audioTrackName: audioTrack,
                targetBuffering: .milliseconds(100)
            )
        }

        try await player.play()

        // Keep a strong reference to the player for as long as playback should continue.
    }
}
```

### Publish camera and microphone in Swift

```swift
import AVFoundation
import MoQKit

let audioSession = AVAudioSession.sharedInstance()
try audioSession.setCategory(
    .playAndRecord,
    mode: .videoRecording,
    options: [.defaultToSpeaker, .allowBluetoothHFP]
)
try audioSession.setActive(true)

let session = Session(url: "http://localhost:4443/anon")
try await session.connect()

let camera = CameraCapture(camera: Camera(position: .front))
let microphone = MicrophoneCapture()

try await camera.start()
try await microphone.start()

let publisher = try Publisher()
publisher.addVideoTrack(name: "camera", source: camera)
publisher.addAudioTrack(name: "mic", source: microphone)

try session.publish(path: "live/ios", publisher: publisher)
try await publisher.start()

// When the broadcast ends:
// publisher.stop()
// camera.stop()
// microphone.stop()
// await session.close()
```

The `name` passed to `addVideoTrack` and `addAudioTrack` is a local SDK label used by
`PublishedTrack` and publisher events. Media catalog track names are generated by the
underlying muxer, so subscribers should discover actual media track names from
`Catalog.videoTracks` and `Catalog.audioTracks`.

### Publish front and back cameras in Swift

```swift
import MoQKit

guard MultiCameraCapture.isSupported else {
    throw SessionError.invalidConfiguration("Multi-camera capture is not supported")
}

let session = Session(url: "http://localhost:4443/anon")
try await session.connect()

let cameras = MultiCameraCapture(
    front: Camera(position: .front, width: 720, height: 1280),
    back: Camera(position: .back, width: 720, height: 1280),
    maxFrameRate: 30
)
try await cameras.start()

let videoConfig = VideoEncoderConfig(width: 720, height: 1280, bitrate: 900_000)

let publisher = try Publisher()
publisher.addVideoTrack(name: "front-camera", source: cameras.frontSource, config: videoConfig)
publisher.addVideoTrack(name: "back-camera", source: cameras.backSource, config: videoConfig)

try session.publish(path: "live/ios-multicam", publisher: publisher)
try await publisher.start()

// When the broadcast ends:
// publisher.stop()
// cameras.stop()
// await session.close()
```

### Play a broadcast in Kotlin

```kotlin
lifecycleScope.launch {
    val session = Session(
        url = "http://localhost:4443/anon",
        parentScope = lifecycleScope,
    )

    session.connect()
    val subscription = session.subscribe(prefix = "live")

    subscription.broadcasts.collect { broadcast ->
        broadcast.catalogs().collect { catalog ->
            val videoTrack = catalog.playableVideoTracks.firstOrNull()?.name
            val audioTrack = catalog.playableAudioTracks.firstOrNull()?.name
            if (videoTrack == null && audioTrack == null) return@collect

            val player = Player(
                catalog = catalog,
                videoTrackName = videoTrack,
                audioTrackName = audioTrack,
                targetBuffering = java.time.Duration.ofMillis(100),
                parentScope = lifecycleScope,
            )

            player.setSurface(surfaceView.holder.surface)
            player.play()

            // Keep the player while the screen is active, then call player.close().
        }
    }
}
```

### Publish camera and microphone in Kotlin

```kotlin
lifecycleScope.launch {
    val session = Session(
        url = "http://localhost:4443/anon",
        parentScope = lifecycleScope,
    )
    session.connect()

    val camera = CameraCapture(position = CameraPosition.Front)
    camera.start(context, lifecycleOwner)

    val microphone = MicrophoneCapture(sampleRate = 48_000)
    microphone.start()

    val publisher = Publisher()
    publisher.addVideoTrack(name = "camera", source = camera)
    publisher.addAudioTrack(name = "mic", source = microphone)

    session.publish(path = "live/android", publisher = publisher)
    publisher.start()

    // When the broadcast ends, stop the publisher, captures, and session.
    // publisher.stop()
    // camera.stop()
    // microphone.stop()
    // session.close()
}
```

### Publish front and back cameras in Kotlin

```kotlin
lifecycleScope.launch {
    if (!MultiCameraCapture.isFrontBackSupported(context)) {
        error("Multi-camera capture is not supported")
    }

    val session = Session(
        url = "http://localhost:4443/anon",
        parentScope = lifecycleScope,
    )
    session.connect()

    val cameras = MultiCameraCapture(
        front = CameraStreamConfig(
            position = CameraPosition.Front,
            width = 1280,
            height = 720,
            frameRate = 30,
        ),
        back = CameraStreamConfig(
            position = CameraPosition.Back,
            width = 1280,
            height = 720,
            frameRate = 30,
        ),
    )
    cameras.start(context, lifecycleOwner)

    val videoConfig = VideoEncoderConfig(width = 1280, height = 720, bitrate = 900_000)

    val publisher = Publisher()
    publisher.addVideoTrack(name = "front-camera", source = cameras.frontSource, config = videoConfig)
    publisher.addVideoTrack(name = "back-camera", source = cameras.backSource, config = videoConfig)

    session.publish(path = "live/android-multicam", publisher = publisher)
    publisher.start()

    // When the broadcast ends:
    // publisher.stop()
    // cameras.stop()
    // session.close()
}
```

Use `VideoEncoderConfig.isSupported`, `AudioEncoderConfig.isSupported`, and the
`supportedCodecs()` helpers before offering codec choices in UI. Use
`Catalog.playableVideoTracks` and `Catalog.playableAudioTracks` when selecting tracks for
playback. On iOS, video track playability is based on codec families recognized by
MoQKit's renderer; actual decode/render support is still determined by AVFoundation at
runtime. For app-defined messages or telemetry, add a `DataTrackEmitter` with
`Publisher.addDataTrack` and read it with `Broadcast.subscribeTrack`.

On iOS, camera and microphone publishing are app-owned integrations: your app handles the
privacy usage strings and `AVAudioSession` setup. On Android, your app declares and requests
camera and audio permissions. Multi-camera capture requires hardware support reported by
`MultiCameraCapture.isSupported` on iOS. On Android, `MultiCameraCapture.isSupported(context)`
is the fast platform feature check, while `MultiCameraCapture.isFrontBackSupported(context)`
verifies that CameraX exposes an actual concurrent front/back pair. For screen publishing,
use `ScreenCapture` when in-app capture is enough, and use the ReplayKit Broadcast Upload
flow for full-device iOS capture that survives app switches. The iOS demo shows the App
Group and extension wiring for that path.

For complete app-shaped code, use the native demos.

## Demo apps

The demo apps are the best integration references in this repository:

- **Player**: connect to a relay, discover broadcasts, select tracks, and play streams.
- **Publisher**: publish camera, microphone, and screen capture streams.
- **Chat**: publish and receive JSON messages over raw MoQ data tracks.

Native demo paths:

- [iOS demo](examples/ios/demo/MoQDemo)
- [Android demo](examples/android/demo/MoQDemo)

The iOS demo also includes Luke's experimental [Boy demo](https://moq.dev/blog/moq-boy/)
with announced games, live playback, and viewer controls.

## Local development

Use [`mise-en-place`](https://mise.jdx.dev/) (`mise`) as the task runner for local
development.

```bash
mise tasks
```

### Build platform SDKs

iOS resolves `moq-swift` through Swift Package Manager and compiles the Swift SDK:

```bash
mise run ios:build
```

Android resolves the upstream `dev.moq:moq` Maven package and assembles the Kotlin SDK:

```bash
mise run android:build
```

The task scripts in [mise-tasks](mise-tasks) are the source of truth for exact build
outputs. Android generated bindings and JNI libraries come from the resolved `dev.moq:moq`
package. iOS generated bindings come from the resolved `moq-swift` package. See
[ARCHITECTURE.md](ARCHITECTURE.md) for binding boundaries and invariants.

For local SDK development, the demo apps are usually the fastest feedback loop. Prefer
wiring demos to local Swift and Android modules instead of published package versions when
you are iterating on moq-kit itself. The Android demo already uses Gradle substitution for
the local `android/moqkit` build.

### Run a local relay and test streams

For development, the regular flow is to run the local moq-lite relay and publish a single
prepared media file into it. Start by checking the task list:

```bash
mise tasks
```

The main streaming tasks are:

- `relay:run` — run the local moq-lite relay from this checkout.
- `media:to-fmp4` — convert a source video to CMAF fragmented MP4.
- `stream:file` — loop one or more CMAF fragmented MP4 file streams into a relay.
- `stream:obs` — control OBS through `obs-cmd` and publish an OBS stream.

Use `mise task <task>` to see what a task does and which flags it accepts before running
it:

```bash
mise task relay:run
mise task stream:file
mise task media:to-fmp4
mise task stream:obs
```

`stream:file` expects a CMAF fragmented MP4 input. Prepare local media with
`media:to-fmp4` first, then run `relay:run` and publish the file with `stream:file`.

Run the demos with:

```bash
mise run ios:run --simulator
mise run android:run
```

You can also split the Android demo flow with `mise run android:install` and
`mise run android:launch`.

## Status

moq-kit is an active preview. It is suitable for demos, prototypes, and early integrations,
but the public APIs, packages, codec coverage, and protocol compatibility can still evolve.

Protocol compatibility relies on what moq-lite provides. For more detail, see the
[`moq-lite` draft](https://datatracker.ietf.org/doc/draft-lcurley-moq-lite/) and Luke
Curley's [`moq-dev/moq`](https://github.com/moq-dev/moq) repository.

## License

[Apache License, Version 2.0](LICENSE)

## Acknowledgments

Built on top of [`moq-dev/moq`](https://github.com/moq-dev/moq) by
[Luke Curley](https://github.com/kixelated) and contributors.

## MoqKit is created by Software Mansion

Since 2012 [Software Mansion](https://swmansion.com) is a software agency with experience
in building web and mobile apps. We are Core React Native Contributors and experts in
dealing with all kinds of React Native issues. We can help you build your next dream
product - [Hire us][hire-us].

[![swm][swm-logo]][swm]

Copyright 2026, [Software Mansion](https://swmansion.com/)

[hire-us]: https://swmansion.com/contact/projects?utm_source=react-native-executorch&utm_medium=readme
[swm]: https://swmansion.com
[swm-logo]: https://logo.swmansion.com/logo?color=white&variant=desktop&width=150&tag=react-native-executorch-github
