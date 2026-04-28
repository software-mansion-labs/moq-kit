package com.swmansion.moqkit.subscribe

import android.util.Log
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
 */
data class VideoSize(
    val width: UInt,
    val height: UInt,
)

/**
 * Codec and format parameters for a video rendition.
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
 */
@ConsistentCopyVisibility
data class VideoTrackInfo internal constructor(
    override val name: String,
    val config: VideoTrackConfig,
    internal val rawConfig: MoqVideo,
) : TrackInfo

/**
 * An audio track discovered from a broadcast catalog.
 */
@ConsistentCopyVisibility
data class AudioTrackInfo internal constructor(
    override val name: String,
    val config: AudioTrackConfig,
    internal val rawConfig: MoqAudio,
) : TrackInfo

/**
 * The latest playable track metadata for a single broadcast path.
 */
class Catalog internal constructor(
    val path: String,
    val videoTracks: List<VideoTrackInfo>,
    val audioTracks: List<AudioTrackInfo>,
    internal val owner: BroadcastOwner,
) {
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
 */
class Broadcast internal constructor(
    val path: String,
    private val owner: BroadcastOwner,
) : AutoCloseable {
    private val lock = Any()
    private var closed = false

    /**
     * Streams catalog updates for this broadcast until the catalog track ends.
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

    val isClosed: Boolean
        get() = synchronized(lock) { closed }

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
