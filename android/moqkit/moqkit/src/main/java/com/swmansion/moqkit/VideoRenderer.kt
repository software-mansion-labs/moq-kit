package com.swmansion.moqkit

import android.util.Log
import android.view.Surface
import uniffi.moq.MoqVideo

private const val TAG = "VideoRenderer"

/**
 * Processed video frame ready for MediaCodec input.
 * Annex B encoded bytes with prepended CSD if needed.
 */
internal data class ProcessedFrame(
    val payload: ByteArray,
    val timestampUs: Long,
)

/**
 * Orchestrates JitterBuffer + VideoDecoder for real-time video rendering.
 *
 * Frames are buffered in the jitter buffer as raw payloads (before decoding).
 * When MediaCodec signals input buffer availability, frames are pulled from
 * the jitter buffer and submitted for decoding. All frames (playable or not)
 * are decoded to maintain the decoder's reference picture chain; non-playable
 * frames are released with render=false.
 *
 * Uses MediaCodec's scheduled release (`releaseOutputBuffer(index, renderTimestampNs)`)
 * to let the system compositor handle vsync-aligned display timing.
 *
 * Thread model: decoder callbacks + jitter buffer feeding run on the decoder's HandlerThread.
 */
internal class VideoRenderer(
    private val config: MoqVideo,
    private val surface: Surface,
    targetBufferingUs: Long,
    private val timebase: MediaTimebase? = null,
    private val metrics: PlaybackMetricsAccumulator? = null,
) {
    private val jitterBuffer = JitterBuffer<ProcessedFrame>(targetBufferingUs).also { jb ->
        if (metrics != null) {
            jb.onStartPlaying = { metrics.videoStallEnded() }
            jb.onStartBuffering = { metrics.videoStallBegan() }
        }
    }
    private val processor = VideoFrameProcessor(config)
    private var decoder: VideoDecoder? = null

    // Maps PTS -> playable flag, set at dequeue time, consumed at output time
    private val playabilityMap = HashMap<Long, Boolean>()
    private val playabilityLock = Object()

    // Input buffers from MediaCodec that arrived when jitter buffer was empty
    private val parkedInputBuffers = ArrayDeque<Int>()
    private val parkedLock = Object()

    /** PTS of the most recently submitted frame, in microseconds. */
    @Volatile
    var lastIngestPtsUs: Long = 0L
        private set

    val bufferFillMs: Double get() = jitterBuffer.depthMs

    fun start() {
        Log.d(TAG, "Starting: codec=${config.codec}")

        if (processor.isReady) {
            initDecoder()
        } else {
            Log.d(TAG, "Deferring decoder init until CSD is available")
        }

        Log.d(TAG, "VideoRenderer started")
    }

    private fun initDecoder() {
        val format = processor.getFormat()
            ?: throw IllegalStateException("Cannot init decoder: format not ready")

        val videoDecoder = VideoDecoder(
            format,
            surface,
            onInputBufferAvailable = { index -> feedDecoder(index) },
            onOutputBufferAvailable = { bufferIndex, timestampUs ->
                onDecodedFrame(bufferIndex, timestampUs)
            },
        )
        decoder = videoDecoder

        jitterBuffer.setOnDataAvailable {
            videoDecoder.handler.post { drainJitterBufferToDecoder() }
        }

        videoDecoder.start()
        Log.d(TAG, "Decoder initialized: $format")
    }

    /** Submit a compressed video frame for buffering and eventual decoding. */
    fun submitFrame(payload: ByteArray, timestampUs: Long, keyframe: Boolean) {
        lastIngestPtsUs = timestampUs
        val processed = processor.processPayload(payload, keyframe) ?: return

        if (decoder == null && processor.isReady) {
            initDecoder()
        }

        jitterBuffer.insert(ProcessedFrame(processed, timestampUs), timestampUs)
    }

    /**
     * Called on decoder HandlerThread when MediaCodec has an input buffer available.
     * Pulls from the jitter buffer if data is available, otherwise parks the index.
     */
    private fun feedDecoder(inputBufferIndex: Int) {
        val tb = timebase
        val mediaTimeUs = if (tb != null && tb.currentTimeUs > 0L) tb.currentTimeUs else null

        val (entry, playable) = jitterBuffer.dequeue(mediaTimeUs)
        if (entry != null) {
            synchronized(playabilityLock) {
                playabilityMap[entry.item.timestampUs] = playable
            }
            decoder?.fillInputBuffer(inputBufferIndex, entry.item.payload, entry.item.timestampUs)
        } else {
            synchronized(parkedLock) {
                parkedInputBuffers.addLast(inputBufferIndex)
            }
        }
    }

    /**
     * Called when jitter buffer transitions to non-empty (onDataAvailable).
     * Consumes parked input buffers by pulling frames from the jitter buffer.
     * Runs on decoder HandlerThread.
     */
    private fun drainJitterBufferToDecoder() {
        val tb = timebase
        val mediaTimeUs = if (tb != null && tb.currentTimeUs > 0L) tb.currentTimeUs else null

        while (true) {
            val inputBufferIndex: Int
            synchronized(parkedLock) {
                inputBufferIndex = parkedInputBuffers.removeFirstOrNull() ?: return
            }

            val (entry, playable) = jitterBuffer.dequeue(mediaTimeUs)
            if (entry != null) {
                synchronized(playabilityLock) {
                    playabilityMap[entry.item.timestampUs] = playable
                }
                decoder?.fillInputBuffer(inputBufferIndex, entry.item.payload, entry.item.timestampUs)
            } else {
                // No more data, re-park this buffer
                synchronized(parkedLock) {
                    parkedInputBuffers.addFirst(inputBufferIndex)
                }
                return
            }
        }
    }

    /** Called on decoder HandlerThread when a frame is decoded. */
    private fun onDecodedFrame(bufferIndex: Int, timestampUs: Long) {
        val playable: Boolean
        synchronized(playabilityLock) {
            playable = playabilityMap.remove(timestampUs) ?: true
        }

        val dec = decoder ?: return
        if (playable) {
            val tb = timebase
            val mediaTimeUs = if (tb != null && tb.currentTimeUs > 0L) tb.currentTimeUs else null
            val delayUs = if (mediaTimeUs != null) {
                timestampUs - mediaTimeUs
            } else {
                timestampUs - jitterBuffer.estimatedPlaybackTimeUs()
            }
            val renderNs = System.nanoTime() + delayUs * 1000
            dec.releaseOutputBuffer(bufferIndex, renderNs)
            metrics?.recordVideoFrameDisplayed()
        } else {
            dec.releaseOutputBuffer(bufferIndex, false)
            metrics?.recordVideoFrameDropped()
        }
    }

    fun updateTargetBuffering(ms: Int) {
        jitterBuffer.updateTargetBuffering(ms.toLong() * 1000)
    }

    /** Flush: discard buffered frames and flush decoder. */
    fun flush() {
        jitterBuffer.flush()
        synchronized(parkedLock) {
            parkedInputBuffers.clear()
        }
        synchronized(playabilityLock) {
            playabilityMap.clear()
        }
        decoder?.flush()
        Log.d(TAG, "VideoRenderer flushed")
    }

    fun stop() {
        Log.d(TAG, "Stopping VideoRenderer")
        flush()
        decoder?.release()
        decoder = null
        Log.d(TAG, "VideoRenderer stopped")
    }
}
