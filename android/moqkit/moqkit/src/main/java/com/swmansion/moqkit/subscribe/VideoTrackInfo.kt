package com.swmansion.moqkit.subscribe

import uniffi.moq.MoqBroadcastConsumer
import uniffi.moq.MoqVideo

/**
 * A video track discovered from a broadcast catalog.
 *
 * @property name Track name as announced in the catalog.
 * @property config Codec, container, and resolution parameters for this rendition.
 * @property broadcast Handle to the broadcast that owns this track; used to open a subscription.
 */
data class VideoTrackInfo(
    override val name: String,
    val config: MoqVideo,
    val broadcast: MoqBroadcastConsumer,
) : TrackInfo
