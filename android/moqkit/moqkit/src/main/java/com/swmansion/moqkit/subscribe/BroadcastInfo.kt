package com.swmansion.moqkit.subscribe

/**
 * All tracks available in a single named broadcast.
 *
 * @property path Broadcast path as announced by the relay (e.g. `"live/camera1"`).
 * @property videoTracks Available video renditions, ordered as declared in the catalog.
 * @property audioTracks Available audio tracks, ordered as declared in the catalog.
 */
data class BroadcastInfo(
    val path: String,
    val videoTracks: List<VideoTrackInfo>,
    val audioTracks: List<AudioTrackInfo>,
)
