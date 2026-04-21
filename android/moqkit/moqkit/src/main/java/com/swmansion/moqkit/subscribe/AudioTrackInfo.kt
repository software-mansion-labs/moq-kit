package com.swmansion.moqkit.subscribe

import uniffi.moq.MoqAudio
import uniffi.moq.MoqBroadcastConsumer

/**
 * An audio track discovered from a broadcast catalog.
 *
 * @property name Track name as announced in the catalog.
 * @property config Codec, container, sample rate, and channel count for this track.
 * @property broadcast Handle to the broadcast that owns this track; used to open a subscription.
 */
data class AudioTrackInfo(
    override val name: String,
    val config: MoqAudio,
    val broadcast: MoqBroadcastConsumer,
) : TrackInfo
