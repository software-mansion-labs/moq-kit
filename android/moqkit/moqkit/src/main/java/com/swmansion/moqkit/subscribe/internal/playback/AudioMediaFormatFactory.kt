package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import dev.moq.Audio

internal object AudioMediaFormatFactory {
    fun from(config: Audio): MediaFormat? =
        AudioFormatSpecBuilder.from(config)?.toMediaFormat()
}
