package com.swmansion.moqkit

import uniffi.moq.MoqAudio
import uniffi.moq.MoqBroadcastConsumer
import uniffi.moq.MoqVideo

// MARK: - Track Info Types

/** Base interface for a single media track within a broadcast. */
interface MoQTrackInfo {
    /** Track name as announced in the catalog (e.g. `"video/high"`, `"audio/main"`). */
    val name: String
}

/**
 * A video track discovered from a broadcast catalog.
 *
 * @property name Track name as announced in the catalog.
 * @property config Codec, container, and resolution parameters for this rendition.
 * @property broadcast Handle to the broadcast that owns this track; used to open a subscription.
 */
data class MoQVideoTrackInfo(
    override val name: String,
    val config: MoqVideo,
    val broadcast: MoqBroadcastConsumer,
) : MoQTrackInfo

/**
 * An audio track discovered from a broadcast catalog.
 *
 * @property name Track name as announced in the catalog.
 * @property config Codec, container, sample rate, and channel count for this track.
 * @property broadcast Handle to the broadcast that owns this track; used to open a subscription.
 */
data class MoQAudioTrackInfo(
    override val name: String,
    val config: MoqAudio,
    val broadcast: MoqBroadcastConsumer,
) : MoQTrackInfo

/**
 * All tracks available in a single named broadcast.
 *
 * @property path Broadcast path as announced by the relay (e.g. `"live/camera1"`).
 * @property videoTracks Available video renditions, ordered as declared in the catalog.
 * @property audioTracks Available audio tracks, ordered as declared in the catalog.
 */
data class MoQBroadcastInfo(
    val path: String,
    val videoTracks: List<MoQVideoTrackInfo>,
    val audioTracks: List<MoQAudioTrackInfo>,
)

/**
 * Lifecycle event emitted on [MoQSession.broadcasts] for a single broadcast path.
 */
sealed class MoQBroadcastEvent {
    /**
     * A broadcast became available or its catalog was updated.
     *
     * @property info The latest catalog snapshot for this broadcast.
     */
    data class Available(val info: MoQBroadcastInfo) : MoQBroadcastEvent()

    /**
     * A broadcast is no longer available (publisher disconnected or path unannounced).
     *
     * @property path The broadcast path that went away.
     */
    data class Unavailable(val path: String) : MoQBroadcastEvent()
}
