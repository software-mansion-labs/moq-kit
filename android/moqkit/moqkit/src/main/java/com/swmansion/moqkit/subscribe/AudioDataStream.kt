package com.swmansion.moqkit.subscribe

import android.media.MediaFormat
import com.swmansion.moqkit.subscribe.internal.playback.AudioDecoder
import com.swmansion.moqkit.subscribe.internal.playback.AudioMediaFormatFactory
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import uniffi.moq.MoqAudio
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.Duration
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * PCM sample representation emitted by [AudioDataStream].
 */
enum class AudioSampleFormat {
    /** 32-bit floating point PCM. */
    Float32,

    /** Signed 16-bit integer PCM. */
    Int16,
}

/**
 * Parameters needed to subscribe to and decode a MoQ audio track.
 *
 * Catalog-advertised tracks provide these values through [AudioTrackInfo]. Advanced callers
 * can provide them directly when subscribing to an audio track that is not listed in the
 * catalog.
 */
class AudioTrackRequest(
    /** Compressed media subscription parameters. */
    val media: MediaTrackRequest,
    /** Audio codec identifier, such as `"opus"` or `"mp4a.40.2"`. */
    val codec: String,
    /** Optional codec description or magic cookie bytes. */
    codecDescription: ByteArray? = null,
    /** Source audio sample rate in Hz. */
    val sampleRate: UInt,
    /** Source audio channel count. */
    val channelCount: UInt,
    /** Optional advertised bitrate in bits per second. */
    val bitrate: ULong? = null,
) {
    val codecDescription: ByteArray? = codecDescription?.copyOf()

    constructor(
        name: String,
        container: MediaContainer,
        codec: String,
        codecDescription: ByteArray? = null,
        sampleRate: UInt,
        channelCount: UInt,
        bitrate: ULong? = null,
        targetBuffering: Duration = Duration.ofMillis(100),
    ) : this(
        media = MediaTrackRequest(
            name = name,
            container = container,
            targetBuffering = targetBuffering,
        ),
        codec = codec,
        codecDescription = codecDescription,
        sampleRate = sampleRate,
        channelCount = channelCount,
        bitrate = bitrate,
    )

    internal constructor(track: AudioTrackInfo, targetBuffering: Duration) : this(
        name = track.name,
        container = MediaContainer.fromRaw(track.rawConfig.container),
        codec = track.rawConfig.codec,
        codecDescription = track.rawConfig.description,
        sampleRate = track.rawConfig.sampleRate,
        channelCount = track.rawConfig.channelCount,
        bitrate = track.rawConfig.bitrate,
        targetBuffering = targetBuffering,
    )

    internal val rawConfig: MoqAudio
        get() = MoqAudio(
            codec = codec,
            description = codecDescription?.copyOf(),
            sampleRate = sampleRate,
            channelCount = channelCount,
            bitrate = bitrate,
            container = media.container.toRawContainer(),
        )

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is AudioTrackRequest) return false
        return media == other.media &&
            codec == other.codec &&
            codecDescription.contentEqualsNullable(other.codecDescription) &&
            sampleRate == other.sampleRate &&
            channelCount == other.channelCount &&
            bitrate == other.bitrate
    }

    override fun hashCode(): Int {
        var result = media.hashCode()
        result = 31 * result + codec.hashCode()
        result = 31 * result + (codecDescription?.contentHashCode() ?: 0)
        result = 31 * result + sampleRate.hashCode()
        result = 31 * result + channelCount.hashCode()
        result = 31 * result + (bitrate?.hashCode() ?: 0)
        return result
    }
}

/**
 * Requested PCM format for [AudioDataStream] output.
 *
 * Leave [sampleRate] or [channelCount] as `null` to keep the subscribed track's source
 * configuration.
 */
data class AudioDataFormat(
    /** Sample representation for emitted [AudioData.bytes]. */
    val sampleFormat: AudioSampleFormat = AudioSampleFormat.Float32,
    /** Output sample rate in Hz. `null` keeps the subscribed track's sample rate. */
    val sampleRate: UInt? = null,
    /** Output channel count. `null` keeps the subscribed track's channel count. */
    val channelCount: UInt? = null,
)

/**
 * One decoded PCM audio chunk emitted by [AudioDataStream].
 */
class AudioData(
    /** Interleaved PCM bytes in [sampleFormat]. */
    val bytes: ByteArray,
    /** Presentation timestamp in microseconds, relative to the stream origin. */
    val timestampUs: Long,
    /** PCM sample rate in Hz. */
    val sampleRate: UInt,
    /** Number of audio channels. */
    val channelCount: UInt,
    /** Sample representation for [bytes]. */
    val sampleFormat: AudioSampleFormat,
    /** Number of PCM frames in [bytes]. */
    val frameCount: Int,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is AudioData) return false
        return bytes.contentEquals(other.bytes) &&
            timestampUs == other.timestampUs &&
            sampleRate == other.sampleRate &&
            channelCount == other.channelCount &&
            sampleFormat == other.sampleFormat &&
            frameCount == other.frameCount
    }

    override fun hashCode(): Int {
        var result = bytes.contentHashCode()
        result = 31 * result + timestampUs.hashCode()
        result = 31 * result + sampleRate.hashCode()
        result = 31 * result + channelCount.hashCode()
        result = 31 * result + sampleFormat.hashCode()
        result = 31 * result + frameCount
        return result
    }
}

/**
 * Subscribes to one audio media track and emits decoded PCM chunks.
 *
 * `AudioDataStream` is independent from [Player] and is intended for apps that want to
 * process audio instead of rendering it. When used alongside [Player] with the same catalog
 * audio track, MoQKit shares the compressed media subscription and each consumer decodes
 * independently.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AudioDataStream private constructor(
    private val owner: BroadcastOwner,
    private val retainOwner: Boolean,
    private val track: AudioTrackRequest,
    private val format: AudioDataFormat,
) : AutoCloseable {
    private val lock = Any()
    private val decoderFormat: MediaFormat
    private val converter: AudioDataConverter
    private val mediaTrack: MediaTrack
    private var closed = false
    private var collectionStarted = false

    init {
        validateTrack(track)
        decoderFormat = AudioMediaFormatFactory.from(track.rawConfig)
            ?: throw IllegalStateException("Unsupported audio codec: ${track.codec}")
        converter = AudioDataConverter(
            sourceSampleRate = track.sampleRate,
            sourceChannelCount = track.channelCount,
            requestedFormat = format,
        )

        if (retainOwner) {
            owner.retain()
        }
        try {
            mediaTrack = owner.subscribeMedia(
                request = track.media,
                options = MediaTrackOptions(
                    bufferingPolicy = MediaTrackBufferingPolicy.BufferingNewest(bufferedAudioDataLimit),
                ),
            )
        } catch (t: Throwable) {
            if (retainOwner) {
                owner.release()
            }
            throw t
        }
    }

    /**
     * Creates a decoded audio stream for an advertised catalog audio track.
     */
    constructor(
        catalog: Catalog,
        track: AudioTrackInfo,
        format: AudioDataFormat = AudioDataFormat(),
        targetBuffering: Duration = Duration.ofMillis(100),
    ) : this(
        owner = catalog.owner,
        retainOwner = true,
        track = AudioTrackRequest(
            track = catalog.audioTracks.firstOrNull { it.name == track.name }
                ?: throw IllegalArgumentException(
                    "Unknown audio track '${track.name}' for catalog '${catalog.path}'",
                ),
            targetBuffering = targetBuffering,
        ),
        format = format,
    )

    /**
     * Creates a decoded audio stream by resolving [trackName] from [Catalog.audioTracks].
     */
    constructor(
        catalog: Catalog,
        trackName: String,
        format: AudioDataFormat = AudioDataFormat(),
        targetBuffering: Duration = Duration.ofMillis(100),
    ) : this(
        catalog = catalog,
        track = catalog.audioTracks.firstOrNull { it.name == trackName }
            ?: throw IllegalArgumentException(
                "Unknown audio track '$trackName' for catalog '${catalog.path}'",
            ),
        format = format,
        targetBuffering = targetBuffering,
    )

    /**
     * Creates a decoded audio stream for a known audio track on a broadcast.
     */
    constructor(
        broadcast: Broadcast,
        track: AudioTrackRequest,
        format: AudioDataFormat = AudioDataFormat(),
    ) : this(
        owner = broadcast.broadcastOwner(),
        retainOwner = true,
        track = track,
        format = format,
    )

    /**
     * Decoded PCM chunks.
     *
     * This is a live stream with a small bounded buffer. If the consumer falls behind, older
     * decoded chunks may be dropped in favor of newer chunks.
     */
    val audio: Flow<AudioData> = callbackFlow {
        markCollectionStarted()

        var decoder: AudioDecoder? = null
        try {
            val createdDecoder = AudioDecoder(
                format = decoderFormat,
                onDecoded = { pcmData, frameCount, timestampUs ->
                    try {
                        trySend(
                            converter.convert(
                                pcmData = pcmData,
                                frameCount = frameCount,
                                timestampUs = timestampUs,
                            ),
                        )
                    } catch (t: Throwable) {
                        close(t)
                    }
                },
                onError = { error ->
                    close(error)
                },
            )
            decoder = createdDecoder
            createdDecoder.start()

            val ingestJob = launch(Dispatchers.IO) {
                try {
                    mediaTrack.frames.collect { frame ->
                        createdDecoder.submitFrame(frame.payload, frame.timestampUs)
                    }
                    close()
                } catch (e: CancellationException) {
                    throw e
                } catch (t: Throwable) {
                    close(t)
                }
            }

            awaitClose {
                ingestJob.cancel()
                createdDecoder.release()
                this@AudioDataStream.close()
            }
        } catch (t: Throwable) {
            decoder?.release()
            this@AudioDataStream.close()
            throw t
        }
    }.buffer(
        capacity = bufferedAudioDataLimit,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /** Cancels the subscription and finishes [audio]. */
    override fun close() {
        val shouldClose = synchronized(lock) {
            if (closed) {
                false
            } else {
                closed = true
                true
            }
        }
        if (!shouldClose) return

        mediaTrack.close()
        if (retainOwner) {
            owner.release()
        }
    }

    private fun markCollectionStarted() {
        synchronized(lock) {
            check(!closed) { "Audio data stream is closed" }
            check(!collectionStarted) { "Audio data stream supports only a single collector" }
            collectionStarted = true
        }
    }

    private fun validateTrack(track: AudioTrackRequest) {
        require(track.sampleRate > 0u) { "Audio track sample rate must be greater than zero" }
        require(track.channelCount > 0u) { "Audio track channel count must be greater than zero" }
    }

    private companion object {
        const val bufferedAudioDataLimit = 3
    }
}

internal class AudioDataConverter(
    private val sourceSampleRate: UInt,
    private val sourceChannelCount: UInt,
    requestedFormat: AudioDataFormat,
) {
    private val targetSampleRate = requestedFormat.sampleRate ?: sourceSampleRate
    private val targetChannelCount = requestedFormat.channelCount ?: sourceChannelCount
    private val sampleFormat = requestedFormat.sampleFormat

    init {
        require(sourceSampleRate > 0u) { "Audio track sample rate must be greater than zero" }
        require(sourceChannelCount > 0u) { "Audio track channel count must be greater than zero" }
        require(targetSampleRate > 0u) { "Audio data sample rate must be greater than zero" }
        require(targetChannelCount > 0u) { "Audio data channel count must be greater than zero" }
    }

    fun convert(
        pcmData: ShortArray,
        frameCount: Int,
        timestampUs: Long,
    ): AudioData {
        val sourceChannels = sourceChannelCount.toInt()
        val expectedSamples = frameCount * sourceChannels
        require(frameCount >= 0) { "Audio data frame count must be non-negative" }
        require(pcmData.size >= expectedSamples) {
            "Audio data contains fewer samples than declared frame count"
        }

        val samples = remapAndResample(pcmData, frameCount)
        val bytes = when (sampleFormat) {
            AudioSampleFormat.Float32 -> float32InterleavedBytes(samples)
            AudioSampleFormat.Int16 -> int16InterleavedBytes(samples)
        }

        return AudioData(
            bytes = bytes,
            timestampUs = timestampUs,
            sampleRate = targetSampleRate,
            channelCount = targetChannelCount,
            sampleFormat = sampleFormat,
            frameCount = if (targetChannelCount == 0u) 0 else samples.size / targetChannelCount.toInt(),
        )
    }

    private fun remapAndResample(pcmData: ShortArray, frameCount: Int): FloatArray {
        if (frameCount == 0) return FloatArray(0)

        val sourceRate = sourceSampleRate.toDouble()
        val targetRate = targetSampleRate.toDouble()
        val outputFrames = if (sourceSampleRate == targetSampleRate) {
            frameCount
        } else {
            maxOf(1, (frameCount * targetRate / sourceRate).roundToInt())
        }
        val targetChannels = targetChannelCount.toInt()
        val output = FloatArray(outputFrames * targetChannels)

        for (outFrame in 0 until outputFrames) {
            val sourcePosition = if (sourceSampleRate == targetSampleRate) {
                outFrame.toDouble()
            } else {
                outFrame * sourceRate / targetRate
            }
            val baseFrame = floor(sourcePosition).toInt().coerceIn(0, frameCount - 1)
            val nextFrame = (baseFrame + 1).coerceAtMost(frameCount - 1)
            val fraction = (sourcePosition - baseFrame).coerceIn(0.0, 1.0).toFloat()

            for (channel in 0 until targetChannels) {
                val baseSample = remapSample(pcmData, baseFrame, channel)
                val nextSample = remapSample(pcmData, nextFrame, channel)
                output[outFrame * targetChannels + channel] =
                    baseSample + (nextSample - baseSample) * fraction
            }
        }

        return output
    }

    private fun remapSample(
        pcmData: ShortArray,
        frame: Int,
        targetChannel: Int,
    ): Float {
        val sourceChannels = sourceChannelCount.toInt()
        if (targetChannelCount == 1u && sourceChannels > 1) {
            var sum = 0f
            for (channel in 0 until sourceChannels) {
                sum += sampleToFloat(pcmData[frame * sourceChannels + channel])
            }
            return sum / sourceChannels
        }

        val sourceChannel = if (sourceChannels == 1) {
            0
        } else {
            targetChannel.coerceAtMost(sourceChannels - 1)
        }
        return sampleToFloat(pcmData[frame * sourceChannels + sourceChannel])
    }

    private fun float32InterleavedBytes(samples: FloatArray): ByteArray {
        val buffer = ByteBuffer
            .allocate(samples.size * Float.SIZE_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { buffer.putFloat(it) }
        return buffer.array()
    }

    private fun int16InterleavedBytes(samples: FloatArray): ByteArray {
        val buffer = ByteBuffer
            .allocate(samples.size * Short.SIZE_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { sample ->
            val clamped = sample.coerceIn(-1f, 1f)
            val scale = if (clamped < 0f) 32_768f else 32_767f
            buffer.putShort((clamped * scale).roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort())
        }
        return buffer.array()
    }

    private fun sampleToFloat(sample: Short): Float =
        if (sample < 0) {
            sample.toFloat() / 32_768f
        } else {
            sample.toFloat() / 32_767f
        }
}

private fun ByteArray?.contentEqualsNullable(other: ByteArray?): Boolean =
    when {
        this == null && other == null -> true
        this == null || other == null -> false
        else -> contentEquals(other)
    }
