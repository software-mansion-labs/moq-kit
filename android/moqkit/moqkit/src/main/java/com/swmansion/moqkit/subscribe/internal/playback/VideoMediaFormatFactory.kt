package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import uniffi.moq.MoqVideo

internal object VideoMediaFormatFactory {
    fun from(config: MoqVideo): MediaFormat? =
        VideoFormatSpecBuilder.fromDescription(config)?.toMediaFormat()

    fun from(config: MoqVideo, inBandKeyframe: ByteArray): MediaFormat? =
        VideoFormatSpecBuilder.fromInBandKeyframe(config, inBandKeyframe)?.toMediaFormat()
}
