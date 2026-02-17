# moq-kit

Native MOQ (Media over QUIC) SDK for iOS and Android.

<!-- badges -->

## What is moq-kit?

moq-kit provides idiomatic Swift and Kotlin APIs for publishing and consuming real-time media streams using the MOQ protocol. It wraps [libmoq](https://github.com/moq-dev/moq) — a Rust library that exposes C FFI bindings for the moq-lite transport protocol.

## What is MOQ?

[Media over QUIC (MOQ)](https://datatracker.ietf.org/group/moq/about/) is a new protocol for live media delivery. It combines the low latency of WebRTC with the scalability of CDN-based protocols like HLS/DASH:

- **Sub-second latency** — frames are delivered over QUIC streams as soon as they're encoded
- **CDN-scale distribution** — pub/sub architecture works naturally with relay networks
- **Resilience** — QUIC handles packet loss, connection migration, and multiplexing natively
- **Adaptive** — latency-based frame skipping drops old GoPs instead of buffering

MOQ replaces the trade-offs between RTMP (low latency, no scale), HLS/DASH (scale, high latency), and WebRTC (low latency, complex infrastructure).

## Architecture

```
┌─────────────────────────────────┐
│  moq-kit (Swift / Kotlin)       │  ← Platform-idiomatic APIs
├─────────────────────────────────┤
│  libmoq (C FFI)                 │  ← Rust → C bindings
├─────────────────────────────────┤
│  hang (media layer)             │  ← Codecs, containers, catalogs
├─────────────────────────────────┤
│  moq-lite (transport)           │  ← Pub/sub over QUIC
├─────────────────────────────────┤
│  QUIC / WebTransport            │  ← Network transport
└─────────────────────────────────┘
```

See [docs/architecture.md](docs/architecture.md) for details on the layering, key concepts, and C API mapping.

## Project Structure

```
moq-kit/
├── android/          # Android SDK — Kotlin wrapper with JNI bridge
├── ios/              # iOS SDK — Swift wrapper with C interop
├── vendor/moq/       # libmoq source (git submodule → moq-dev/moq)
├── examples/
│   ├── android/      # Android example apps (publisher, subscriber)
│   └── ios/          # iOS example apps (publisher, subscriber)
└── docs/             # Architecture and design documentation
```

## Features (Planned)

- Publish live video/audio streams to MOQ relays
- Subscribe to and render live streams
- Automatic codec handling (H.264, Opus, AAC)
- Latency-based frame skipping (configurable max latency)
- Broadcast discovery via relay announcements
- Catalog-driven track negotiation

## Prerequisites

- **Rust toolchain** — for building libmoq (`rustup` recommended)
- **Android**: Android SDK, NDK, Kotlin 1.9+
- **iOS**: Xcode 16+, Swift 5.9+

## Status

Early development. Not ready for production use.

## License

Licensed under either of

- [Apache License, Version 2.0](LICENSE-APACHE)
- [MIT License](LICENSE-MIT)

at your option.

## Acknowledgments

Built on top of [moq-dev/moq](https://github.com/moq-dev/moq) by [Luke Curley](https://github.com/kixelated) and contributors.
