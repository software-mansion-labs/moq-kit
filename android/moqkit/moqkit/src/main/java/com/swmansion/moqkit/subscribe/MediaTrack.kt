package com.swmansion.moqkit.subscribe

import com.swmansion.moqkit.subscribe.internal.MediaFrameEvent
import com.swmansion.moqkit.subscribe.internal.MediaFrameStream
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.asStateFlow
import uniffi.moq.Container
import uniffi.moq.MoqFrame
import java.time.Duration

/**
 * Container format used by a MoQ media track.
 *
 * Catalog-advertised tracks provide this automatically through [AudioTrackInfo] and
 * [VideoTrackInfo]. Advanced callers can provide it directly when subscribing to a known
 * media track that is not advertised in the catalog.
 */
sealed class MediaContainer {
    /** Legacy MoQ media container. */
    object Legacy : MediaContainer()

    /** LOC media container. */
    object Loc : MediaContainer()

    /**
     * CMAF/fMP4 media container with initialization segment bytes.
     */
    class Cmaf(initializationData: ByteArray) : MediaContainer() {
        val initializationData: ByteArray = initializationData.copyOf()

        override fun equals(other: Any?): Boolean =
            other is Cmaf && initializationData.contentEquals(other.initializationData)

        override fun hashCode(): Int = initializationData.contentHashCode()

        override fun toString(): String =
            "Cmaf(initializationData=${initializationData.contentToString()})"
    }

    internal fun toRawContainer(): Container = when (this) {
        Legacy -> Container.Legacy
        Loc -> Container.Loc
        is Cmaf -> Container.Cmaf(initializationData.copyOf())
    }

    internal companion object {
        fun fromRaw(container: Container): MediaContainer = when (container) {
            Container.Legacy -> Legacy
            Container.Loc -> Loc
            is Container.Cmaf -> Cmaf(container.init)
        }
    }
}

/**
 * Parameters needed to subscribe to a MoQ media track.
 *
 * When multiple consumers subscribe to the same track on the same broadcast, the first
 * subscriber creates the shared upstream subscription and chooses [targetBuffering].
 */
data class MediaTrackRequest(
    /** Track name on the broadcast. */
    val name: String,
    /** Track container format. */
    val container: MediaContainer,
    /** Target live buffering depth for the upstream media subscription. */
    val targetBuffering: Duration = Duration.ofMillis(100),
) {
    internal constructor(track: AudioTrackInfo, targetBuffering: Duration) : this(
        name = track.name,
        container = MediaContainer.fromRaw(track.rawConfig.container),
        targetBuffering = targetBuffering,
    )

    internal constructor(track: VideoTrackInfo, targetBuffering: Duration) : this(
        name = track.name,
        container = MediaContainer.fromRaw(track.rawConfig.container),
        targetBuffering = targetBuffering,
    )
}

/**
 * Buffering behavior for frames emitted by a [MediaTrack].
 */
sealed class MediaTrackBufferingPolicy {
    /** Buffers every frame until the consumer reads it. */
    object Unbounded : MediaTrackBufferingPolicy()

    /**
     * Keeps only the newest [limit] frames when the consumer falls behind.
     *
     * Non-positive limits are treated as `1`.
     */
    data class BufferingNewest(val limit: Int) : MediaTrackBufferingPolicy()
}

/**
 * Options for subscribing to a compressed media track.
 */
data class MediaTrackOptions(
    /** Buffering behavior for delivered frames. */
    val bufferingPolicy: MediaTrackBufferingPolicy = MediaTrackBufferingPolicy.Unbounded,
)

/**
 * A single compressed media frame received from the relay.
 */
class MediaFrame(
    /** Raw compressed payload bytes. */
    val payload: ByteArray,
    /** Presentation timestamp in microseconds, relative to the stream origin. */
    val timestampUs: Long,
    /** Whether this frame is a keyframe or sync point. */
    val keyframe: Boolean,
) {
    internal constructor(raw: MoqFrame) : this(
        payload = raw.payload,
        timestampUs = raw.timestampUs.toLong(),
        keyframe = raw.keyframe,
    )

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is MediaFrame) return false
        return payload.contentEquals(other.payload) &&
            timestampUs == other.timestampUs &&
            keyframe == other.keyframe
    }

    override fun hashCode(): Int {
        var result = payload.contentHashCode()
        result = 31 * result + timestampUs.hashCode()
        result = 31 * result + keyframe.hashCode()
        return result
    }

    override fun toString(): String =
        "MediaFrame(payload=${payload.contentToString()}, timestampUs=$timestampUs, keyframe=$keyframe)"
}

/**
 * Lifecycle state of a [MediaTrack].
 */
sealed class MediaTrackState {
    /** Subscribed to the track but no frames have arrived yet. */
    object Idle : MediaTrackState()

    /** Frames are arriving and being emitted on [MediaTrack.frames]. */
    object Active : MediaTrackState()

    /** The track ended normally or was closed by the caller. */
    object Closed : MediaTrackState()

    /**
     * The track ended with an error.
     *
     * @property message Human-readable error description.
     */
    data class Error(val message: String) : MediaTrackState()
}

/**
 * Advanced low-level subscription to one MoQ media track.
 *
 * [frames] emits raw compressed [MediaFrame] values. Most applications should use [Player]
 * or [AudioDataStream], which manage decoding and playback or processing.
 */
class MediaTrack internal constructor(
    private val media: MediaFrameStream,
    private val onClose: (() -> Unit)? = null,
) : AutoCloseable {
    private val lock = Any()
    private val _state = MutableStateFlow<MediaTrackState>(MediaTrackState.Idle)
    private var closed = false

    internal val events: Flow<MediaFrameEvent> = flow {
        var firstFrame = true
        try {
            media.events.collect { event ->
                if (firstFrame && event is MediaFrameEvent.Frame) {
                    firstFrame = false
                    _state.value = MediaTrackState.Active
                }
                emit(event)
            }
            _state.value = MediaTrackState.Closed
        } catch (t: Throwable) {
            if (!isClosed) {
                _state.value = MediaTrackState.Error(t.message ?: t::class.java.simpleName)
            }
            throw t
        } finally {
            close()
        }
    }

    /** A stream of raw media frames as they arrive from the relay. */
    val frames: Flow<MediaFrame> = flow {
        events.collect { event ->
            if (event is MediaFrameEvent.Frame) emit(event.frame)
        }
    }

    /** Current lifecycle state for this track. */
    val state: StateFlow<MediaTrackState> = _state.asStateFlow()

    /** Whether this subscription has been closed. */
    val isClosed: Boolean
        get() = synchronized(lock) { closed }

    /** Cancels the track subscription and completes [frames]. */
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

        media.close()
        _state.value = MediaTrackState.Closed
        onClose?.invoke()
    }
}
