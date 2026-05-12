package com.swmansion.moqkit

/**
 * Thrown when the selected media codec cannot be encoded or decoded on this device.
 *
 * Use [com.swmansion.moqkit.publish.encoder.VideoEncoderConfig.isSupported],
 * [com.swmansion.moqkit.publish.encoder.AudioEncoderConfig.isSupported],
 * [com.swmansion.moqkit.subscribe.VideoTrackInfo.isPlayable], or
 * [com.swmansion.moqkit.subscribe.AudioTrackInfo.isPlayable] to check support before
 * starting publish or playback work.
 */
class UnsupportedCodecException(message: String) : IllegalArgumentException(message)
