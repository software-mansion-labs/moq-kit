package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import uniffi.moq.MoqAudio

internal object AudioMediaFormatFactory {
    fun from(config: MoqAudio): MediaFormat? =
        AudioFormatSpecBuilder.from(config)?.toMediaFormat()
}
