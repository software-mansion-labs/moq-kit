# Architecture

moq-kit provides native Swift and Kotlin SDKs for publishing and playing low-latency media
streams over QUIC. The repository does not implement the MoQ protocol itself; it wraps the
Rust `moq-ffi` UniFFI crate from the `vendor/moq` submodule and adds platform-native
capture, encoding, playback, lifecycle, and demo-app integrations.

The stack is:

```text
moq-kit Swift / Kotlin APIs
moq-ffi UniFFI bindings
hang media and catalog layer
moq-lite transport
QUIC / WebTransport
```

moq-kit currently targets `moq-lite`, not the fast-moving IETF `moq-transport` wire format.

## Codemap

`Package.swift` defines the Swift package. The public Swift SDK lives under
`ios/Sources/MoQKit`. The `MoQKitFFI` target contains the generated UniFFI Swift bindings
and small extensions around generated types.

`android/moqkit` is the Android Gradle project. The publishable Kotlin SDK module is
`android/moqkit/moqkit`. Public Kotlin APIs live under `com.swmansion.moqkit`; generated
UniFFI Kotlin bindings live under `uniffi.moq`.

`vendor/moq` is a git submodule pointing at `moq-dev/moq`. The important crate for moq-kit
is `moq-ffi`; it is the only Rust API the Swift and Kotlin SDKs bind to directly. `libmoq`
also exists in the submodule, but moq-kit does not use it for platform bindings.

`Session` is the main SDK entry point on both platforms. It owns one relay connection,
creates separate consume and publish origins, starts broadcast discovery, registers
publishers, and tears down active work when the connection closes.

Publishing is centered on `Publisher`. A publisher collects track descriptors before start,
then connects frame sources to encoders and writes encoded frames or data objects to FFI
producers. Camera, microphone, screen capture, and raw data emitters are platform-specific
sources feeding the same publish shape.

Subscription and discovery are centered on `BroadcastSubscription`, `Broadcast`, `Catalog`,
and `TrackSubscription`. A session subscribes to announced broadcast paths by prefix. A
broadcast exposes catalog updates for media playback and raw track subscription for
app-defined data.

Playback is centered on `Player`. A player resolves selected tracks from a catalog,
subscribes to those tracks, decodes incoming frames with native platform media APIs,
buffers toward a target latency, renders audio/video, and exposes playback events and
stats.

The iOS playback internals are under `Subscribe/internal`, split between codec parsing and
playback/rendering helpers. The Android equivalents are under `subscribe/internal`,
especially `playback`. These internals should stay behind the public `Player`, `Broadcast`,
and `TrackSubscription` APIs.

The demo apps in `examples/ios/demo/MoQDemo` and `examples/android/demo/MoQDemo` are
integration references. They exercise player, publisher, and chat/data-track workflows and
are usually the fastest manual validation path.

`mise.toml` and `mise-tasks` are the local development command surface. The FFI tasks build
Rust artifacts, generate UniFFI bindings, and place platform artifacts where the Swift
package and Android module expect them.

## Architectural Invariants

Generated UniFFI bindings are build artifacts. Do not manually edit `moq.swift` or
`uniffi.moq` files; change Rust `moq-ffi` or the platform wrapper layer and regenerate.

The platform SDKs depend on `moq-ffi`, not on `libmoq`. Public Swift and Kotlin APIs should
hide generated UniFFI types unless there is a deliberate API reason to expose them.

A `Session` represents one relay connection. Publishing and consuming may share that
connection, but their origins are separate.

Catalogs describe media tracks. Raw data tracks do not need to appear in a media catalog and
should remain usable through explicit track subscription APIs.

Platform capture, codec, decoder, renderer, and lifecycle details belong in Swift/Kotlin
wrappers. Transport, relay, broadcast, track, group, and catalog protocol behavior belongs
below the UniFFI boundary.

The iOS and Android APIs should stay equivalent as much as the platforms allow. This keeps
the SDKs predictable and preserves a clean path toward future React Native bindings.

Public API shape should stay idiomatic per platform: Swift uses async/await, actors,
`AsyncStream`, and AVFoundation; Kotlin uses coroutines, `Flow`, Android media APIs, and
lifecycle-owned scopes.

## Cross-Cutting Concerns

Latency is a first-class behavior. Playback code should preserve live-position behavior,
target buffering controls, frame skipping, and metrics visibility.

Resource ownership matters across the FFI boundary. Sessions, subscriptions, broadcasts,
players, publishers, encoders, renderers, and capture sources must close or cancel their
native and FFI resources deterministically.

Codec support is platform-dependent. H.264/AAC/Opus are the best-tested paths; newer codecs
may depend on device hardware and platform decoder support.

The repository has limited formal tests. Android has focused unit tests for playback helpers
and selection behavior; the native demo apps act as integration tests for end-to-end relay,
publish, playback, and data-track flows.

Release artifacts are platform-specific. iOS publishes a Swift package backed by a prebuilt
`moqFFI` XCFramework binary target; Android publishes an AAR containing Kotlin wrappers,
generated UniFFI bindings, and JNI libraries.
