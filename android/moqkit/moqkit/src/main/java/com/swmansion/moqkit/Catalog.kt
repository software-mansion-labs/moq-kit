package com.swmansion.moqkit

import uniffi.moq.MoqAudioRendition
import uniffi.moq.MoqBroadcast
import uniffi.moq.MoqVideoRendition

// MARK: - Track Info Types

interface MoQTrackInfo {
    val name: String
}

data class MoQVideoTrackInfo(
    override val name: String,
    val config: MoqVideoRendition,
    val broadcast: MoqBroadcast,
) : MoQTrackInfo

data class MoQAudioTrackInfo(
    override val name: String,
    val config: MoqAudioRendition,
    val broadcast: MoqBroadcast,
) : MoQTrackInfo

data class MoQBroadcastInfo(
    val path: String,
    val videoTracks: List<MoQVideoTrackInfo>,
    val audioTracks: List<MoQAudioTrackInfo>,
)

sealed class MoQBroadcastEvent {
    data class Available(val info: MoQBroadcastInfo) : MoQBroadcastEvent()
    data class Unavailable(val path: String) : MoQBroadcastEvent()
}
