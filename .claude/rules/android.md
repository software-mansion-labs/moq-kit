---
description: Android SDK conventions and patterns
globs:
  - "android/**"
  - "examples/android/**"
  - "mise-tasks/build-android"
---

# Android SDK Rules

## Build Config
- AGP 9.0.1, Kotlin 2.0.21, Media3 1.9.2, minSdk 30
- `media3-exoplayer` is an `api()` dependency — consumers get the `ExoPlayer` type

## Conventions
- `startTrack(context, videoIndex, audioIndex)` must be called on the main thread, returns `ExoPlayer?`
- `@file:OptIn(UnstableApi::class)` required in `MoQMediaSource.kt` and `MediaFactory.kt`
- State transitions use `compareAndSet()` for atomicity
- `MoQMediaSource` is a custom `BaseMediaSource` bridging `Flow<FrameData>` → `SampleQueue` → ExoPlayer

## Generated Bindings
- `android/moqkit/MoQKit/src/main/java/uniffi/moq/` — auto-generated, never edit
