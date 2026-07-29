# Architecture

moq-kit provides native Swift and Kotlin SDKs for publishing and playing low-latency media
streams over QUIC. The repository does not implement the MoQ protocol itself; it builds on
the published platform packages backed by the Rust `moq-ffi` crate and adds platform-native
capture, encoding, playback, lifecycle, and demo-app integrations.

The stack is:

```text
moq-kit Swift / Kotlin APIs
moq-swift wrappers (iOS) / dev.moq Kotlin wrappers (Android)
moq-ffi UniFFI bindings
hang media and catalog layer
moq-lite transport
QUIC / WebTransport
```

moq-kit currently targets `moq-lite`, not the fast-moving IETF `moq-transport` wire format.

## Codemap

`Package.swift` defines the Swift package. The public Swift SDK lives under
`ios/Sources/MoQKit`. The Swift SDK depends on the upstream
`https://github.com/moq-dev/moq-swift` package, using its `Moq` module for stateful client,
session, origin, broadcast, track, and media wrappers plus its public record aliases. The
package supplies the generated UniFFI Swift bindings and binary artifacts underneath those
wrappers.

`android/moqkit` is the Android Gradle project. The publishable Kotlin SDK module is
`android/moqkit/moqkit`. Public Kotlin APIs live under `com.swmansion.moqkit`; the upstream
`dev.moq:moq` Maven dependency supplies the idiomatic `dev.moq` Kotlin facade, aliases, and
Flow helpers. Its transitive `dev.moq:moq-ffi` dependency supplies the generated UniFFI
bindings and JNI libraries.

`vendor/moq` is a git submodule pointing at `moq-dev/moq`. The important crate for moq-kit
is `moq-ffi`; iOS consumes the published `moq-swift` package, and Android consumes the
published `dev.moq:moq` wrapper with `dev.moq:moq-ffi` underneath it. `libmoq` also exists
in the submodule, but moq-kit does not use it for platform bindings.

`Session` is the main SDK entry point on both platforms. It owns one relay connection,
creates separate consume and publish origins, starts broadcast discovery, registers
publishers, exposes point-in-time `ConnectionStats` snapshots, and tears down active work
when the connection closes.

Publishing is centered on `Publisher`. A publisher collects track descriptors before start,
then connects frame sources to encoders and writes encoded frames or data objects to Moq
producers. Registering a publisher with `Session.publish` creates the Moq broadcast
producer at the chosen path, so registration must happen before `Publisher.start`. Camera, multi-camera capture, microphone, screen capture, and raw data emitters
are platform-specific sources feeding the same publish shape.

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

Both playback implementations follow the same ownership model: a typed pipeline event bus,
one timeline authority per track, one bounded compressed-frame buffer before video decode,
central policy values, explicit render/switch/recovery decisions, and statistics derived
from typed events. Platform adapters remain deliberately different. Android owns
`MediaCodec` sessions; iOS feeds AVFoundation and uses `AVSampleBufferVideoRenderer` on
iOS 17+/macOS 14+ with the display-layer API retained for the older deployment baseline.
iOS audio decoding is synchronous through `AVAudioConverter`, and its PCM ring stores
non-interleaved Float32 samples.

The demo apps in `examples/ios/demo/MoQDemo` and `examples/android/demo/MoQDemo` are
integration references. They exercise player, publisher, and chat/data-track workflows and
are usually the fastest manual validation path.

`mise.toml` and `mise-tasks` are the local development command surface. Android package
builds resolve `dev.moq:moq` through Gradle/Maven Central, and iOS package builds resolve
`moq-swift` through Swift Package Manager.

## Architectural Invariants

Generated UniFFI bindings are build artifacts. Do not manually edit generated Swift or
Kotlin bindings; change Rust `moq-ffi` upstream or the platform wrapper layer. iOS production
code should import the public `Moq` module rather than `MoqFFI`, using its stateful wrappers
and record aliases whenever available. Inspect the resolved `MoqFFI` sources only when an
underlying generated type shape is unclear. Android production code should similarly import
the public `dev.moq` facade, aliases, and Flow helpers instead of `uniffi.moq` whenever the
wrapper exposes the needed shape. The generated sealed `MoqContainer` and `MoqException`
types remain explicit exceptions because Kotlin cannot access their subtypes through an
alias. Inspect `uniffi.moq` from the resolved transitive `dev.moq:moq-ffi` dependency only
when an underlying generated type shape is unclear.

The platform SDKs depend on bindings built from `moq-ffi`, not on `libmoq`. Public Swift
and Kotlin APIs should hide generated UniFFI types unless there is a deliberate API reason
to expose them.

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

Every media discard must have one owning stage and one typed `DropReason`. The same
`PipelineEvent` is the source for detailed diagnostics and aggregate drop/stall statistics;
downstream layers must not count the same discard again.

`Player.diagnostics()` is non-replayed and bounded independently for each subscriber.
Diagnostics must never apply backpressure to ingest, decode, or rendering. On iOS,
`frameRendered` means AVFoundation accepted a sample for visible scheduled output; it is
not a hardware scanout acknowledgement. The current published `MoqFFI` bindings do not
expose transport group ranges, so iOS frame events leave group metadata empty.

Connection metrics are connection-scoped rather than player- or track-scoped. Both SDKs
expose them by converting the generated `MoqConnectionStats` record returned by
`MoqSession.stats()` into the public `ConnectionStats` type. The snapshot contains the
transport's smoothed RTT, a send-rate estimate from the local QUIC congestion controller,
a receive-rate estimate learned from the peer through MoQ PROBE, and cumulative transport
byte/packet counters. Every field remains optional because a backend may not report it or
the estimate may not be ready yet; missing and zero are distinct. Callers choose their own
polling cadence. The player demos poll once per second and display RTT plus estimated send
and receive rates. These connection snapshots do not produce the track-level
`PipelineEvent.bandwidthSample` event.

## Cross-Cutting Concerns

Latency is a first-class behavior. Playback code should preserve live-position behavior,
target buffering controls, frame skipping, and metrics visibility.

Resource ownership matters across the FFI boundary. Sessions, subscriptions, broadcasts,
players, publishers, encoders, renderers, and capture sources must close or cancel their
native and FFI resources deterministically.

Codec support is platform-dependent. H.264/AAC/Opus are the best-tested paths; newer codecs
may depend on platform decoder support and runtime availability.

Android and iOS have focused unit tests for playback policy, buffering, timeline, selection,
and lifecycle behavior. Run the iOS package suite with `mise run ios:test`. The native demo
apps remain the integration tests for end-to-end relay, publish, playback, and data-track
flows.

Release artifacts are platform-specific. iOS publishes a Swift package that depends on the
published `moq-swift` package for the prebuilt `MoqFFI` XCFramework; moq-kit does not build
or upload its own iOS XCFramework. Android publishes an AAR containing Kotlin wrappers and
declares `dev.moq:moq` as the transitive Kotlin wrapper dependency; that package resolves
`dev.moq:moq-ffi` for the generated UniFFI bindings and JNI libraries.
