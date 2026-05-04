# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Architecture

Read `ARCHITECTURE.md` for the repository codemap, layer boundaries, and invariants.
In particular, Swift and Kotlin APIs should stay equivalent as much as the platforms allow
because future React Native bindings should be able to sit on top of both SDKs cleanly.

## UniFFI Bindings

Both platforms use **UniFFI** via the standalone `moq-ffi` crate, not `libmoq`. Never edit
generated binding files manually; they're overwritten every build.

- iOS generated bindings: `ios/Sources/MoQKitFFI/moq.swift`
- Android generated bindings: `android/moqkit/moqkit/src/main/java/uniffi/moq/`

## Key Concepts

- **Origin** — routing point; publishers and subscribers connect through the same origin
- **Session** — a QUIC connection to a MOQ relay with publish/consume origins
- **Broadcast** — named collection of tracks addressed by path
- **Track** — single media stream (one video rendition or audio track)
- **Group** — decodable unit starting with a keyframe; can be independently decoded for
  latency-based skipping
- **Catalog** — JSON track describing all other tracks (codec params, resolution, sample rate)

## Examples

- iOS: `examples/ios/demo/MoQDemo/`
- Android: `examples/android/demo/MoQDemo/`

Examples function as integration tests — no formal test suite exists.

## Prerequisites

- **Rust toolchain** (rustup) with targets `aarch64-apple-ios`, `aarch64-apple-ios-sim`
- **iOS**: Xcode 16+, Swift 5.9+
- **Android**: NDK r23+, SDK 30+, `cargo-ndk` (`cargo install cargo-ndk`)
