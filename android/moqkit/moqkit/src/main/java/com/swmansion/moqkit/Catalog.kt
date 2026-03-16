package com.swmansion.moqkit

import uniffi.moq.MoqAudio
import uniffi.moq.MoqBroadcastConsumer
import uniffi.moq.MoqVideo

// MARK: - Track Info Types

interface MoQTrackInfo {
    val name: String
}

data class MoQVideoTrackInfo(
    override val name: String,
    val config: MoqVideo,
    val broadcast: MoqBroadcastConsumer,
) : MoQTrackInfo

data class MoQAudioTrackInfo(
    override val name: String,
    val config: MoqAudio,
    val broadcast: MoqBroadcastConsumer,
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
