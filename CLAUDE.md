# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Architecture

moq-kit wraps **moq-ffi** (Rust) with idiomatic Swift and Kotlin APIs. The stack:

```
moq-kit (Swift / Kotlin)    ← platform APIs in this repo
moq-ffi (UniFFI bindings)   ← vendor/moq/rs/moq-ffi/
libmoq (C bindings)         ← vendor/moq/rs/libmoq/ (pure C API)
hang (media layer)          ← codecs, containers, catalogs
moq-lite (transport)        ← pub/sub over QUIC
QUIC / WebTransport         ← network transport
```

**vendor/moq** is a git submodule pointing to `moq-dev/moq`. The UniFFI crate lives at `vendor/moq/rs/moq-ffi/`, the C bindings at `vendor/moq/rs/libmoq/`.

## UniFFI Bindings

Both platforms use **UniFFI** via the standalone `moq-ffi` crate (NOT libmoq). **Never edit generated binding files manually** — they're overwritten every build.

- iOS generated bindings: `ios/Sources/MoQKit/moq.swift`
- Android generated bindings: `android/moqkit/MoQKit/src/main/java/uniffi/moq/`

## Key Concepts

- **Origin** — routing point; publishers and subscribers connect through the same origin
- **Session** — a QUIC connection to a MOQ relay with publish/consume origins
- **Broadcast** — named collection of tracks addressed by path
- **Track** — single media stream (one video rendition or audio track)
- **Group** — decodable unit starting with a keyframe; can be independently decoded for latency-based skipping
- **Catalog** — JSON track describing all other tracks (codec params, resolution, sample rate)

## Examples

- iOS: `examples/ios/demo/MoQDemo/`
- Android: `examples/android/demo/MoQDemo/`

Examples function as integration tests — no formal test suite exists.

## Prerequisites

- **Rust toolchain** (rustup) with targets `aarch64-apple-ios`, `aarch64-apple-ios-sim`
- **iOS**: Xcode 16+, Swift 5.9+
- **Android**: NDK r23+, SDK 30+, `cargo-ndk` (`cargo install cargo-ndk`)
