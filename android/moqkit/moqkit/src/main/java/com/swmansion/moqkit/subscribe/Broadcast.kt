package com.swmansion.moqkit.subscribe

import android.util.Log
import com.swmansion.moqkit.subscribe.internal.playback.PlaybackCodecSupport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import uniffi.moq.MoqAnnounced
import uniffi.moq.MoqAudio
import uniffi.moq.MoqBroadcastConsumer
import uniffi.moq.MoqCatalog
import uniffi.moq.MoqCatalogConsumer
import uniffi.moq.MoqOriginConsumer
import uniffi.moq.MoqVideo

private const val TAG = "Broadcast"

/**
 * A pair of pixel dimensions used to describe video resolution or display ratio.
 *
 * @property width Width in pixels.
 * @property height Height in pixels.
 */
data class VideoSize(
    val width: UInt,
    val height: UInt,
)

/**
 * Codec and format parameters for a video rendition.
 *
 * @property codec Catalog codec string, such as `"avc1"` or `"hev1"`.
 * @property coded Encoded frame size, when announced by the broadcaster.
 * @property displayRatio Display aspect ratio, when announced by the broadcaster.
 * @property bitrate Advertised bitrate in bits per second, when available.
 * @property framerate Advertised frame rate, when available.
 */
data class VideoTrackConfig(
    val codec: String,
    val coded: VideoSize?,
    val displayRatio: VideoSize?,
    val bitrate: ULong?,
    val framerate: Double?,
)

/**
 * Codec and format parameters for an audio rendition.
 *
 * @property codec Catalog codec string, such as `"aac"` or `"opus"`.
 * @property sampleRate Samples per second.
 * @property channelCount Number of audio channels.
 * @property bitrate Advertised bitrate in bits per second, when available.
 */
data class AudioTrackConfig(
    val codec: String,
    val sampleRate: UInt,
    val channelCount: UInt,
    val bitrate: ULong?,
)

/** Base interface for a single media track within a broadcast. */
interface TrackInfo {
    /** Track name as announced in the catalog (e.g. `"video/high"`, `"audio/main"`). */
    val name: String
}

/**
 * A video track discovered from a broadcast catalog.
 *
 * @property name Track name to pass to [Player] when selecting this video track.
 * @property config Catalog metadata announced for this track.
 */
@ConsistentCopyVisibility
data class VideoTrackInfo internal constructor(
    override val name: String,
    val config: VideoTrackConfig,
    internal val rawConfig: MoqVideo,
) : TrackInfo {
    /** Whether this track can be decoded on the current device. */
    val isPlayable: Boolean
        get() = PlaybackCodecSupport.video(rawConfig).isSupported

    /** Human-readable reason this track is not playable, or null when playable. */
    val unsupportedReason: String?
        get() = PlaybackCodecSupport.video(rawConfig).reason
}

/**
 * An audio track discovered from a broadcast catalog.
 *
 * @property name Track name to pass to [Player] when selecting this audio track.
 * @property config Catalog metadata announced for this track.
 */
@ConsistentCopyVisibility
data class AudioTrackInfo internal constructor(
    override val name: String,
    val config: AudioTrackConfig,
    internal val rawConfig: MoqAudio,
) : TrackInfo {
    /** Whether this track can be decoded on the current device. */
    val isPlayable: Boolean
        get() = PlaybackCodecSupport.audio(rawConfig).isSupported

    /** Human-readable reason this track is not playable, or null when playable. */
    val unsupportedReason: String?
        get() = PlaybackCodecSupport.audio(rawConfig).reason
}

/**
 * The latest catalog metadata for a single broadcast path.
 *
 * [videoTracks] and [audioTracks] include everything announced in the catalog.
 * Use [playableVideoTracks] and [playableAudioTracks] when choosing tracks for
 * [Player], because codec support can vary by device.
 *
 * @property path Broadcast path that produced this catalog.
 * @property videoTracks Video tracks announced by the broadcaster.
 * @property audioTracks Audio tracks announced by the broadcaster.
 */
class Catalog internal constructor(
    val path: String,
    val videoTracks: List<VideoTrackInfo>,
    val audioTracks: List<AudioTrackInfo>,
    internal val owner: BroadcastOwner,
) {
    /** Video tracks from this catalog that can be decoded on the current device. */
    val playableVideoTracks: List<VideoTrackInfo>
        get() = videoTracks.filter { it.isPlayable }

    /** Audio tracks from this catalog that can be decoded on the current device. */
    val playableAudioTracks: List<AudioTrackInfo>
        get() = audioTracks.filter { it.isPlayable }

    internal constructor(path: String, catalog: MoqCatalog, owner: BroadcastOwner) : this(
        path = path,
        videoTracks = catalog.video.map { (name, rendition) ->
            VideoTrackInfo(name = name, config = rendition.toTrackConfig(), rawConfig = rendition)
        },
        audioTracks = catalog.audio.map { (name, rendition) ->
            AudioTrackInfo(name = name, config = rendition.toTrackConfig(), rawConfig = rendition)
        },
        owner = owner,
    )

    internal fun retainBroadcastOwner(): BroadcastOwner = owner.retain()
}

/**
 * A live broadcast announcement surfaced by a [BroadcastSubscription].
 *
 * Keep this broadcast open for as long as you need to create players or observe catalog updates.
 * A [Player] created from one of this broadcast's catalogs retains the underlying broadcast handle
 * until the player is closed.
 *
 * @property path Announced broadcast path.
 */
class Broadcast internal constructor(
    val path: String,
    private val owner: BroadcastOwner,
) : AutoCloseable {
    private val lock = Any()
    private var closed = false

    /**
     * Subscribes to a raw MoQ track by name.
     *
     * This does not require the track to appear in the broadcast catalog. The returned
     * subscription emits every object from each received group as a [TrackObject].
     *
     * Raw tracks are useful for app-defined data such as chat messages, telemetry, or
     * control events.
     */
    fun subscribeTrack(
        name: String,
        delivery: TrackDelivery = TrackDelivery.Monotonic,
    ): TrackSubscription {
        val retainedOwner = owner.retain()
        return try {
            val track = retainedOwner.consumer().subscribeTrack(name)
            TrackSubscription(
                name = name,
                owner = retainedOwner,
                track = track,
                delivery = delivery,
            )
        } catch (t: Throwable) {
            retainedOwner.release()
            throw t
        }
    }

    /**
     * Streams catalog updates for this broadcast until the catalog track ends.
     *
     * Collect this flow to discover playable audio and video tracks. The flow may emit more
     * than once if the broadcaster updates its catalog.
     */
    fun catalogs(): Flow<Catalog> = flow {
        val broadcast = owner.consumer()
        var catalogConsumer: MoqCatalogConsumer? = null
        try {
            catalogConsumer = broadcast.subscribeCatalog()
            while (true) {
                val catalog = catalogConsumer.next() ?: break
                emit(Catalog(path = path, catalog = catalog, owner = owner))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (!owner.isClosed()) {
                throw e
            }
        } finally {
            try {
                catalogConsumer?.cancel()
            } catch (_: Exception) {
            }
            try {
                catalogConsumer?.close()
            } catch (_: Exception) {
            }
        }
    }

    override fun close() {
        val shouldRelease = synchronized(lock) {
            if (closed) {
                false
            } else {
                closed = true
                true
            }
        }
        if (shouldRelease) {
            owner.release()
        }
    }
}

/**
 * A prefix-based subscription created by [com.swmansion.moqkit.Session.subscribe].
 *
 * Collect [broadcasts] to receive matching announcements. A subscription owns one native
 * announcement stream, so it supports only a single active collector.
 *
 * @property prefix Prefix passed to [com.swmansion.moqkit.Session.subscribe].
 */
class BroadcastSubscription internal constructor(
    val prefix: String,
    private var originConsumer: MoqOriginConsumer?,
    private var announced: MoqAnnounced?,
    private val onClosed: () -> Unit,
) : AutoCloseable {
    private val lock = Any()
    private var closed = false
    private var collectionStarted = false

    /**
     * Emits broadcasts announced under [prefix].
     *
     * A subscription supports a single active collector because it is backed by one UniFFI
     * announcement stream.
     */
    val broadcasts: Flow<Broadcast> = flow {
        markCollectionStarted()

        val currentAnnounced = synchronized(lock) { announced }
            ?: throw IllegalStateException("Broadcast subscription for prefix '$prefix' is closed")

        try {
            while (true) {
                val announcement = try {
                    currentAnnounced.next()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (isClosed) {
                        break
                    }
                    throw e
                } ?: break
                val path: String
                val consumer: MoqBroadcastConsumer
                try {
                    path = announcement.path()
                    consumer = announcement.broadcast()
                } finally {
                    try {
                        announcement.close()
                    } catch (_: Exception) {
                    }
                }

                val owner = BroadcastOwner(path = path, consumer = consumer)
                val broadcast = Broadcast(path = path, owner = owner)
                try {
                    emit(broadcast)
                } catch (t: Throwable) {
                    owner.release()
                    throw t
                }
            }
        } finally {
            finish()
        }
    }

    /**
     * Whether this subscription has been closed.
     */
    val isClosed: Boolean
        get() = synchronized(lock) { closed }

    /**
     * Stops receiving broadcast announcements and releases subscription resources.
     */
    override fun close() {
        finish()
    }

    private fun markCollectionStarted() {
        synchronized(lock) {
            check(!closed) { "Broadcast subscription for prefix '$prefix' is closed" }
            check(!collectionStarted) {
                "Broadcast subscription for prefix '$prefix' supports only a single collector"
            }
            collectionStarted = true
        }
    }

    private fun finish() {
        val resources = synchronized(lock) {
            if (closed) {
                null
            } else {
                closed = true
                val currentAnnounced = announced
                announced = null
                val currentOriginConsumer = originConsumer
                originConsumer = null
                currentAnnounced to currentOriginConsumer
            }
        } ?: return

        try {
            resources.first?.cancel()
        } catch (_: Exception) {
        }

        try {
            resources.first?.close()
        } catch (_: Exception) {
        }

        try {
            resources.second?.close()
        } catch (_: Exception) {
        }

        onClosed()
    }
}

internal class BroadcastOwner(
    private val path: String,
    consumer: MoqBroadcastConsumer,
) {
    private val lock = Any()
    private var refCount = 1
    private var consumer: MoqBroadcastConsumer? = consumer

    fun retain(): BroadcastOwner = synchronized(lock) {
        check(refCount > 0 && consumer != null) { "Broadcast '$path' is already closed" }
        refCount += 1
        this
    }

    fun consumer(): MoqBroadcastConsumer = synchronized(lock) {
        consumer ?: throw IllegalStateException("Broadcast '$path' is already closed")
    }

    fun isClosed(): Boolean = synchronized(lock) { consumer == null }

    fun release() {
        val consumerToClose = synchronized(lock) {
            check(refCount > 0) { "Broadcast '$path' has already been released" }
            refCount -= 1
            if (refCount == 0) {
                consumer.also { consumer = null }
            } else {
                null
            }
        }

        if (consumerToClose != null) {
            Log.d(TAG, "Closing broadcast '$path'")
            try {
                consumerToClose.close()
            } catch (e: Exception) {
                Log.w(TAG, "Failed to close broadcast '$path'", e)
            }
        }
    }
}

private fun MoqVideo.toTrackConfig(): VideoTrackConfig = VideoTrackConfig(
    codec = codec,
    coded = coded?.let { VideoSize(width = it.width, height = it.height) },
    displayRatio = displayRatio?.let { VideoSize(width = it.width, height = it.height) },
    bitrate = bitrate,
    framerate = framerate,
)

private fun MoqAudio.toTrackConfig(): AudioTrackConfig = AudioTrackConfig(
    codec = codec,
    sampleRate = sampleRate,
    channelCount = channelCount,
    bitrate = bitrate,
)
