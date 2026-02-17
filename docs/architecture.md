# Architecture

## Layer Stack

moq-kit sits at the top of a layered architecture. Each layer has a single responsibility:

```
┌─────────────────────────────────┐
│  moq-kit (Swift / Kotlin)       │  Platform-idiomatic APIs
├─────────────────────────────────┤
│  libmoq (C FFI)                 │  Rust → C bindings
├─────────────────────────────────┤
│  hang (media layer)             │  Codecs, containers, catalogs
├─────────────────────────────────┤
│  moq-lite (transport)           │  Pub/sub over QUIC
├─────────────────────────────────┤
│  QUIC / WebTransport            │  Network transport
└─────────────────────────────────┘
```

- **moq-kit** provides Swift (iOS) and Kotlin (Android) APIs that feel native to each platform. It manages the lifecycle of libmoq handles and translates C callbacks into platform-native async patterns (Swift concurrency, Kotlin coroutines).
- **libmoq** is the C FFI surface of the Rust `moq` crate. It exposes opaque handle IDs and callback-based async operations. All functions return `i32`: non-zero positive values are handles, zero is success, negative values are error codes.
- **hang** is the media layer. It handles codec containers (e.g. CMAF), catalog encoding/decoding, and timestamp management.
- **moq-lite** implements the MOQ transport protocol — pub/sub semantics over QUIC streams with origins, broadcasts, tracks, groups, and frames.
- **QUIC / WebTransport** provides the underlying reliable, multiplexed, encrypted transport.

## Key Concepts

- **Origin** — A routing point that connects publishers and subscribers. Broadcasts are published to origins and consumed from origins. Origins can be shared across sessions for fanout/relay scenarios.
- **Session** — A QUIC connection to a MOQ relay server. A session references a publish origin and a consume origin.
- **Broadcast** — A named collection of media tracks addressed by path within an origin.
- **Track** — A single media stream (e.g. one video rendition or one audio track) within a broadcast.
- **Group** — A decodable unit within a track, starting with a keyframe. Groups can be independently decoded, enabling latency-based skipping.
- **Frame** — A single encoded media frame with a presentation timestamp. Frames may be split into multiple chunks for delivery.
- **Catalog** — Metadata describing the tracks in a broadcast, including codec parameters, resolution, sample rate, and channel count.

## libmoq C API Mapping

The libmoq C API follows consistent patterns that moq-kit wraps:

### Handle-Based Resource Management

All resources (sessions, origins, broadcasts, tracks) are represented as opaque `u32` handles. Each resource type has `create`/`close` or `open`/`close` pairs. Handle `0` is reserved (means "disabled" or "none").

### Callback-Based Async

Asynchronous events are delivered via C function pointer callbacks with an associated `user_data` pointer. The caller must ensure the callback remains valid until the corresponding `close` function is called.

### Error Convention

All functions return `i32`:
- **Positive non-zero** — a new handle ID (success for create/open operations)
- **Zero** — success (for operations that don't return a handle)
- **Negative** — error code

### API Surface

**Lifecycle:**
- `moq_log_level` — Initialize logging

**Sessions:**
- `moq_session_connect` / `moq_session_close` — Connect to a relay server

**Origins:**
- `moq_origin_create` / `moq_origin_close` — Create a routing point
- `moq_origin_publish` — Publish a broadcast to an origin
- `moq_origin_consume` — Consume a broadcast from an origin by path
- `moq_origin_announced` / `moq_origin_announced_close` — Discover broadcasts on an origin

**Publishing:**
- `moq_publish_create` / `moq_publish_close` — Create/close a broadcast for publishing
- `moq_publish_media_ordered` / `moq_publish_media_close` — Create/close a media track
- `moq_publish_media_frame` — Write a frame to a track

**Consuming:**
- `moq_consume_catalog` / `moq_consume_catalog_close` — Subscribe to broadcast catalog updates
- `moq_consume_video_config` / `moq_consume_audio_config` — Query track codec parameters
- `moq_consume_video_ordered` / `moq_consume_video_close` — Subscribe to video frames
- `moq_consume_audio_ordered` / `moq_consume_audio_close` — Subscribe to audio frames
- `moq_consume_frame_chunk` / `moq_consume_frame_close` — Read frame payload data

## Publishing Flow

1. `moq_origin_create()` — Create an origin
2. `moq_session_connect(url, origin, 0, ...)` — Connect to relay with the origin for publishing
3. `moq_publish_create()` — Create a broadcast
4. `moq_origin_publish(origin, path, broadcast)` — Announce the broadcast on the origin
5. `moq_publish_media_ordered(broadcast, format, init)` — Create a media track (e.g. H.264 video)
6. `moq_publish_media_frame(media, payload, timestamp)` — Write frames in decode order
7. Clean up in reverse order: close media, close broadcast, close session, close origin

## Consuming Flow

1. `moq_origin_create()` — Create an origin
2. `moq_session_connect(url, 0, origin, ...)` — Connect to relay with the origin for consuming
3. `moq_origin_announced(origin, callback)` — Discover available broadcasts (or skip if path is known)
4. `moq_origin_consume(origin, path)` — Start consuming a broadcast by path
5. `moq_consume_catalog(broadcast, callback)` — Subscribe to the broadcast catalog
6. `moq_consume_video_config(catalog, index)` — Query video track parameters
7. `moq_consume_video_ordered(broadcast, index, max_latency, callback)` — Subscribe to video frames
8. In the frame callback: `moq_consume_frame_chunk(frame, 0)` — Read frame payload
9. Clean up in reverse order
