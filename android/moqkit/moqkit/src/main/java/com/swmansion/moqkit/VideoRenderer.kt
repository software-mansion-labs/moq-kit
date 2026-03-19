package com.swmansion.moqkit

import android.util.Log
import android.view.Surface
import uniffi.moq.MoqVideo

private const val TAG = "VideoRenderer"

/**
 * Orchestrates VideoJitterBuffer + VideoDecoder for real-time video rendering.
 *
 * Uses MediaCodec's scheduled release (`releaseOutputBuffer(index, renderTimestampNs)`)
 * to let the system compositor handle vsync-aligned display timing.
 *
 * Thread model: decoder callbacks + jitter buffer drain run on the decoder's HandlerThread.
 */
internal class VideoRenderer(
    private val config: MoqVideo,
    private val surface: Surface,
    targetBufferingUs: Long,
    private val timebase: MediaTimebase? = null,
    private val metrics: PlaybackMetricsAccumulator? = null,
) {
    private val jitterBuffer = VideoJitterBuffer(targetBufferingUs).also { jb ->
        if (metrics != null) {
            jb.onStartPlaying = { metrics.videoStallEnded() }
            jb.onStartBuffering = { metrics.videoStallBegan() }
        }
    }
    private val processor = VideoFrameProcessor(config)
    private var decoder: VideoDecoder? = null

    /** PTS of the most recently submitted frame, in microseconds. */
    @Volatile
    var lastIngestPtsUs: Long = 0L
        private set

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

        val videoDecoder = VideoDecoder(format, surface) { bufferIndex, timestampUs ->
            onDecodedFrame(bufferIndex, timestampUs)
        }
        decoder = videoDecoder

        jitterBuffer.setOnDataAvailable {
            videoDecoder.handler.post { drain() }
        }

        videoDecoder.start()
        Log.d(TAG, "Decoder initialized: $format")
    }

    /** Submit a compressed video frame for decoding. */
    fun submitFrame(payload: ByteArray, timestampUs: Long, keyframe: Boolean) {
        lastIngestPtsUs = timestampUs
        val processed = processor.processPayload(payload, keyframe) ?: return

        if (decoder == null && processor.isReady) {
            initDecoder()
        }

        decoder?.submitFrame(processed, timestampUs)
    }

    /** Called on decoder HandlerThread when a frame is decoded. */
    private fun onDecodedFrame(bufferIndex: Int, timestampUs: Long) {
        jitterBuffer.insert(bufferIndex, timestampUs)
        drain()
    }

    /** Dequeue all ready frames from the jitter buffer and release them. */
    private fun drain() {
        val tb = timebase
        val mediaTimeUs = if (tb != null && tb.currentTimeUs > 0L) tb.currentTimeUs else null

        while (true) {
            val (entry, playable) = jitterBuffer.dequeue(mediaTimeUs)
            entry ?: break

            val dec = decoder ?: break
            if (playable) {
                val delayUs = if (mediaTimeUs != null) {
                    entry.timestampUs - mediaTimeUs
                } else {
                    entry.timestampUs - jitterBuffer.estimatedPlaybackTimeUs()
                }
                val renderNs = System.nanoTime() + delayUs * 1000
                dec.releaseOutputBuffer(entry.bufferIndex, renderNs)
                metrics?.recordVideoFrameDisplayed()
            } else {
                // Frame is too late — drop it
                dec.releaseOutputBuffer(entry.bufferIndex, false)
                metrics?.recordVideoFrameDropped()
            }
        }
    }

    fun updateTargetBuffering(ms: Int) {
        jitterBuffer.updateTargetBuffering(ms.toLong() * 1000)
    }

    /** Flush: drain all buffered frames (dropping them), then flush decoder and jitter buffer. */
    fun flush() {
        val remaining = jitterBuffer.flush()
        val dec = decoder
        if (dec != null) {
            for (entry in remaining) {
                dec.releaseOutputBuffer(entry.bufferIndex, false)
            }
            dec.flush()
        }
        Log.d(TAG, "VideoRenderer flushed (released ${remaining.size} frames)")
    }

    fun stop() {
        Log.d(TAG, "Stopping VideoRenderer")
        flush()
        decoder?.release()
        decoder = null
        Log.d(TAG, "VideoRenderer stopped")
    }
}
