package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import dev.moq.Video

internal object VideoMediaFormatFactory {
    fun from(config: Video): MediaFormat? =
        VideoFormatSpecBuilder.fromDescription(config)?.toMediaFormat()

    fun from(config: Video, inBandKeyframe: ByteArray): MediaFormat? =
        VideoFormatSpecBuilder.fromInBandKeyframe(config, inBandKeyframe)?.toMediaFormat()
}
