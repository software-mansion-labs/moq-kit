# moq-kit

Native Swift and Kotlin SDKs for publishing and playing low-latency media streams over QUIC.

moq-kit gives iOS and Android apps platform-native APIs for Media over QUIC-style live
streaming: connect to a relay, discover broadcasts, publish camera/microphone/screen
tracks, play catalog-described streams, and send or receive raw data tracks.

It is built on top of [`moq-ffi`](https://github.com/moq-dev/moq/tree/main/rs/moq-ffi),
the UniFFI Rust bindings from Luke Curley's [`moq-dev/moq`](https://github.com/moq-dev/moq)
project.

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
- **Publishing** from camera, microphone, iOS ReplayKit screen capture, Android screen
  capture, and raw data tracks.
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

\* AV1 playback depends on the platform decoder and device hardware. On Apple devices,
Apple documents AV1 playback for iPhone 15 Pro and says A17 Pro includes a dedicated AV1
decoder. VideoToolbox also exposes runtime hardware decode checks through
[`VTIsHardwareDecodeSupported`](https://developer.apple.com/documentation/videotoolbox).
moq-kit does not currently expose AV1 publishing, and iOS AV1 playback should be treated
as iPhone 15 Pro-class device support rather than broad Apple platform support.
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

The Swift package imports a prebuilt `moqFFI` XCFramework binary target. For local
development, rebuild that binary with `mise run ios:ffi`.

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

The Android SDK includes Kotlin APIs backed by UniFFI-generated JNI bindings to the Rust
`moq-ffi` library.

## Usage

Everything in moq-kit starts with a `Session`. A session owns one QUIC connection to a
relay and is the starting point for subscribing to broadcasts, publishing tracks, and
sharing relay state across app workflows.

### Play a broadcast in Swift

```swift
import MoQKit

let session = Session(url: "http://localhost:4443/anon")
try await session.connect()

let subscription = try await session.subscribe(prefix: "live")

for await broadcast in subscription.broadcasts {
    for await catalog in broadcast.catalogs() {
        let player = try await MainActor.run {
            try Player(
                catalog: catalog,
                videoTrackName: catalog.videoTracks.first?.name,
                audioTrackName: catalog.audioTracks.first?.name,
                targetBufferingMs: 100
            )
        }

        try await player.play()
    }
}
```

### Publish camera and microphone in Swift

```swift
import MoQKit

let session = Session(url: "http://localhost:4443/anon")
try await session.connect()

let camera = CameraCapture(camera: Camera(position: .front))
let microphone = MicrophoneCapture()

try await camera.start()
try await microphone.start()

let publisher = try Publisher()
publisher.addVideoTrack(name: "camera", source: camera)
publisher.addAudioTrack(name: "mic", source: microphone)

try await session.publish(path: "live/ios", publisher: publisher)
try await publisher.start()
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
            val player = Player(
                catalog = catalog,
                videoTrackName = catalog.videoTracks.firstOrNull()?.name,
                audioTrackName = catalog.audioTracks.firstOrNull()?.name,
                targetLatencyMs = 100,
                parentScope = lifecycleScope,
            )

            player.setSurface(surfaceView.holder.surface)
            player.play()
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
}
```

For complete app-shaped code, use the native demos.

## Demo apps

The demo apps are the best integration references in this repository:

- **Player**: connect to a relay, discover broadcasts, select tracks, and play streams.
- **Publisher**: publish camera, microphone, and screen capture streams.
- **Chat**: publish and receive JSON messages over raw MoQ data tracks.

Native demo paths:

- [iOS demo](examples/ios/demo/MoQDemo)
- [Android demo](examples/android/demo/MoQDemo)

The iOS demo also includes an experimental Boy demo with announced games, live playback,
and viewer controls.

## Local development

Use [`mise-en-place`](https://mise.jdx.dev/) (`mise`) as the task runner for local development.

```bash
mise tasks
```

Both platform SDKs use `moq-ffi` from the `vendor/moq` git submodule:

```text
moq-kit Swift / Kotlin APIs
        |
moq-ffi UniFFI bindings
        |
hang media layer
        |
moq-lite transport
        |
QUIC / WebTransport
```

### Build platform bindings

iOS builds Rust `moq-ffi` into an XCFramework that the Swift package imports through
`MoQKitFFI`:

```bash
mise run ios:ffi
mise run ios:build
```

Android builds Rust `moq-ffi` into JNI/shared-library artifacts and generates Kotlin
UniFFI bindings:

```bash
mise run android:ffi
mise run android:build
```

The task scripts in [mise-tasks](mise-tasks) are the source of truth for exact build
outputs and generated files. Generated UniFFI bindings are overwritten by these builds and
should not be edited manually.

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

## Project structure

```text
moq-kit/
|-- Package.swift      # Swift package for iOS
|-- android/           # Android SDK and publishing setup
|-- ios/               # Swift sources and moqFFI XCFramework
|-- vendor/moq/        # moq-dev/moq submodule, including moq-ffi
|-- examples/
|   |-- android/       # Android demo app
|   `-- ios/           # iOS demo app
`-- mise-tasks/        # Local build, run, relay, and stream tasks
```

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
product - [Hire us](https://swmansion.com/contact/projects?utm_source=react-native-executorch&utm_medium=readme).

[![swm](https://logo.swmansion.com/logo?color=white&variant=desktop&width=150&tag=react-native-executorch-github "Software Mansion")](https://swmansion.com)

Copyright 2026, [Software Mansion](https://swmansion.com/)
