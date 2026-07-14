package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import com.swmansion.moqkit.subscribe.BufferDepth
import com.swmansion.moqkit.subscribe.MediaFrame
import com.swmansion.moqkit.subscribe.internal.pipeline.AdmissionEffect
import com.swmansion.moqkit.subscribe.internal.pipeline.FrameBuffer
import com.swmansion.moqkit.subscribe.internal.pipeline.PipelinePolicies
import com.swmansion.moqkit.subscribe.internal.pipeline.TimedFrame
import com.swmansion.moqkit.subscribe.internal.pipeline.TrackTimeline
import uniffi.moq.MoqVideo
import java.time.Duration

/** Processed Annex B video frame ready for MediaCodec input. */
internal data class ProcessedFrame(
    val payload: ByteArray,
    val timestampUs: Long,
    val isKeyframe: Boolean,
)

internal data class VideoBufferEntry(
    val item: ProcessedFrame,
    val timestampUs: Long,
)

internal enum class VideoBufferState { BUFFERING, PLAYING, PENDING }

internal sealed interface VideoTrackInsertResult {
    data object InvalidPayload : VideoTrackInsertResult
    data class Buffered(val effects: List<AdmissionEffect>) : VideoTrackInsertResult
}

/**
 * Platform shell joining payload processing to the shared compressed-frame buffer.
 * Timeline decisions happen before [insert]; this class only executes buffer admission.
 */
internal class VideoRendererTrack(
    val trackName: String,
    val trackEpoch: Long,
    targetBuffering: Duration,
    val timeline: TrackTimeline,
    private val processor: VideoPayloadProcessor,
) {
    constructor(
        trackName: String,
        trackEpoch: Long,
        config: MoqVideo,
        targetBuffering: Duration,
        timeline: TrackTimeline,
    ) : this(
        trackName = trackName,
        trackEpoch = trackEpoch,
        targetBuffering = targetBuffering,
        timeline = timeline,
        processor = VideoFrameProcessor(config),
    )

    private val lock = Object()
    private val buffer = FrameBuffer(PipelinePolicies.admission)
    private var mode = VideoBufferState.BUFFERING
    private var targetBufferingUs = targetBuffering.toMicrosecondsLongClamped()
    private var onDataAvailable: (() -> Unit)? = null
    private var currentGroupSequence = 0L
    private var currentFrameIndex = 0

    var targetBuffering: Duration = targetBuffering
        private set

    init {
        buffer.reset(trackEpoch)
    }

    fun insert(payload: ByteArray, timestampUs: Long, keyframe: Boolean): VideoTrackInsertResult {
        val candidate = synchronized(lock) {
            val groupSequence = if (keyframe) currentGroupSequence + 1L else currentGroupSequence
            val frameIndex = if (keyframe) 0 else currentFrameIndex + 1
            val frame = TimedFrame(
                mediaFrame = MediaFrame(payload, timestampUs, keyframe),
                groupSequence = groupSequence,
                frameIndex = frameIndex,
                epoch = trackEpoch,
            )
            buffer.rejectionReason(frame)?.let { reason ->
                return VideoTrackInsertResult.Buffered(listOf(AdmissionEffect.Rejected(frame, reason)))
            }
            frame
        }

        val processed = processor.processPayload(payload, keyframe)
            ?: return VideoTrackInsertResult.InvalidPayload
        val callback: (() -> Unit)?
        val effects: List<AdmissionEffect>
        synchronized(lock) {
            val frame = candidate.copy(
                mediaFrame = MediaFrame(processed, timestampUs, keyframe),
            )
            effects = buffer.offer(frame)
            val admitted = effects.any { it is AdmissionEffect.Admitted }
            if (admitted) {
                currentGroupSequence = requireNotNull(candidate.groupSequence)
                currentFrameIndex = requireNotNull(candidate.frameIndex)
            }
            if (admitted && mode == VideoBufferState.BUFFERING && isBufferedToTarget()) {
                mode = VideoBufferState.PLAYING
            }
            callback = when {
                !admitted -> null
                mode == VideoBufferState.PENDING && !keyframe -> null
                else -> onDataAvailable
            }
        }
        callback?.invoke()
        return VideoTrackInsertResult.Buffered(effects)
    }

    fun peekFront(): Pair<Long, Boolean>? = synchronized(lock) {
        buffer.peekFront()?.let { it.timestampUs to it.keyframe }
    }

    /** Returns the PTS of the oldest entry only when in PLAYING state. */
    fun peekNextTimestampUs(): Long? = synchronized(lock) {
        if (mode != VideoBufferState.PLAYING) null else buffer.peekFront()?.timestampUs
    }

    fun dequeue(): Pair<VideoBufferEntry?, Boolean> = synchronized(lock) {
        if (mode != VideoBufferState.PLAYING) return@synchronized null to false
        val frame = buffer.pollPlayable(System.nanoTime() / 1_000L) ?: return@synchronized null to false
        VideoBufferEntry(
            item = ProcessedFrame(frame.mediaFrame.payload, frame.timestampUs, frame.keyframe),
            timestampUs = frame.timestampUs,
        ) to true
    }

    fun setBufferState(state: VideoBufferState) {
        synchronized(lock) { mode = state }
    }

    val firstKeyframePts: Long?
        get() = synchronized(lock) { buffer.firstWhere { it.keyframe }?.timestampUs }

    fun discardNonKeyframesBeforePts(pts: Long) {
        synchronized(lock) {
            while (true) {
                val front = buffer.peekFront() ?: break
                if (front.keyframe || front.timestampUs >= pts) break
                buffer.removeFront() ?: break
            }
        }
    }

    fun discardFront(): Boolean = synchronized(lock) { buffer.removeFront() != null }

    fun setOnDataAvailable(callback: (() -> Unit)?) {
        synchronized(lock) { onDataAvailable = callback }
    }

    fun updateTargetBuffering(targetBuffering: Duration): Boolean = synchronized(lock) {
        this.targetBuffering = targetBuffering
        targetBufferingUs = targetBuffering.toMicrosecondsLongClamped()
        timeline.setTargetLatency(targetBufferingUs)
        if (mode != VideoBufferState.BUFFERING || !isBufferedToTarget()) return@synchronized false
        mode = VideoBufferState.PLAYING
        true
    }

    fun flush(): Int = synchronized(lock) {
        mode = VideoBufferState.BUFFERING
        buffer.reset(trackEpoch)
    }

    val state: VideoBufferState get() = synchronized(lock) { mode }
    val depthMs: Double get() = synchronized(lock) { buffer.depth().durationUs.toDouble() / 1_000.0 }
    val depth: Duration get() = durationFromMicroseconds(bufferDepth.durationUs)
    val bufferDepth: BufferDepth get() = synchronized(lock) { buffer.depth() }

    fun estimatedPlaybackTimeUs(): Long = targetPlaybackPTS()
        ?: peekFront()?.first
        ?: 0L

    fun targetPlaybackPTS(): Long? {
        val liveEdgeUs = timeline.liveEdgeUs() ?: return null
        return try {
            Math.subtractExact(liveEdgeUs, targetBufferingUs).takeIf { it >= 0L }
        } catch (_: ArithmeticException) {
            null
        }
    }

    val frontFrameIntervalUs: Long? get() = synchronized(lock) {
        val first = buffer.peekAt(0) ?: return@synchronized null
        val second = buffer.peekAt(1)
        if (second != null && second.timestampUs > first.timestampUs) {
            second.timestampUs - first.timestampUs
        } else {
            null
        }
    }

    val isProcessorReady: Boolean get() = processor.isReady
    fun getFormat(): MediaFormat? = processor.getFormat()

    private fun isBufferedToTarget(): Boolean =
        buffer.depth().let { it.durationUs >= targetBufferingUs && it.frames >= 2 }
}
