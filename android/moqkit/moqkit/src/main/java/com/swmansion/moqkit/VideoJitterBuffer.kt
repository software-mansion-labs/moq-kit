package com.swmansion.moqkit

import android.util.Log

private const val TAG = "VideoJitterBuffer"

/**
 * Sorted jitter buffer for video decoder output buffer indices.
 * Port of iOS JitterBuffer<CMSampleBuffer>, specialized for MediaCodec buffer indices.
 *
 * Manages buffering→playing state transitions and playability decisions
 * based on wall-clock-to-PTS offset tracking.
 */
internal class VideoJitterBuffer(
    private var targetBufferingUs: Long,
) {
    enum class State { BUFFERING, PLAYING }

    data class Entry(
        val bufferIndex: Int,
        val timestampUs: Long,
        var offsetUs: Long,
    )

    private val lock = Object()
    private val entries = mutableListOf<Entry>()
    private var mode = State.BUFFERING
    private var maxOffset = Long.MIN_VALUE
    private var onDataAvailable: (() -> Unit)? = null
    var onStartPlaying: (() -> Unit)? = null
    var onStartBuffering: (() -> Unit)? = null

    fun setOnDataAvailable(callback: (() -> Unit)?) {
        synchronized(lock) { onDataAvailable = callback }
    }

    /**
     * Insert a decoded frame's buffer index, sorted by timestamp.
     * Tracks wall-clock-to-PTS offset and transitions buffering→playing.
     */
    fun insert(bufferIndex: Int, timestampUs: Long) {
        val notify: Boolean
        synchronized(lock) {
            val offset = timestampUs - wallClockTimeUs()

            if (offset > maxOffset) {
                val diff = offset - maxOffset
                for (i in entries.indices) {
                    entries[i] = entries[i].copy(offsetUs = entries[i].offsetUs + diff)
                }
                maxOffset = offset
            }

            val wasEmpty = entries.isEmpty()
            val entry = Entry(bufferIndex, timestampUs, offset)

            // Sorted insert by timestampUs (ascending)
            val index = entries.indexOfFirst { it.timestampUs > timestampUs }
            if (index >= 0) {
                entries.add(index, entry)
            } else {
                entries.add(entry)
            }

            // Transition buffering → playing when we have enough depth
            if (mode == State.BUFFERING && entries.size >= 2) {
                val oldest = entries.first().timestampUs
                val newest = entries.last().timestampUs
                if (newest - oldest >= targetBufferingUs) {
                    mode = State.PLAYING
                    Log.d(TAG, "Transitioned to PLAYING (${entries.size} frames buffered)")
                    notify = onDataAvailable != null
                    onStartPlaying?.invoke()
                    return@synchronized
                }
            }

            // Notify if inserting into empty buffer while playing
            notify = wasEmpty && mode == State.PLAYING && onDataAvailable != null
        }

        if (notify) {
            onDataAvailable?.invoke()
        }
    }

    /**
     * Dequeue the oldest entry.
     * Returns (entry, playable) where playable indicates the frame should be rendered vs dropped.
     * Returns (null, false) if buffering or empty.
     *
     * @param mediaTimeUs When non-null, uses audio hardware clock for the drop decision
     *                    instead of wall-clock estimate.
     */
    fun dequeue(mediaTimeUs: Long? = null): Pair<Entry?, Boolean> {
        synchronized(lock) {
            if (mode != State.PLAYING || entries.isEmpty()) return null to false

            val entry = entries.removeAt(0)
            val playable = if (mediaTimeUs != null) {
                entry.timestampUs >= mediaTimeUs
            } else {
                val estimatedLivePts = wallClockTimeUs() + maxOffset
                val targetPlaybackPts = estimatedLivePts - targetBufferingUs
                entry.timestampUs >= targetPlaybackPts
            }

            return entry to playable
        }
    }

    /**
     * Estimated playback time in microseconds.
     * Used by VideoRenderer to compute render timestamps.
     */
    fun estimatedPlaybackTimeUs(): Long {
        synchronized(lock) {
            return wallClockTimeUs() + maxOffset - targetBufferingUs
        }
    }

    fun updateTargetBuffering(us: Long) {
        synchronized(lock) { targetBufferingUs = us }
    }

    /**
     * Drain all entries, returning them for release.
     * Resets to buffering state. Does NOT reset maxOffset (caller handles codec flush).
     */
    fun flush(): List<Entry> {
        synchronized(lock) {
            val drained = entries.toList()
            entries.clear()
            mode = State.BUFFERING
            maxOffset = Long.MIN_VALUE
            onStartBuffering?.invoke()
            return drained
        }
    }

    val state: State get() = synchronized(lock) { mode }
    val count: Int get() = synchronized(lock) { entries.size }

    private fun wallClockTimeUs(): Long = System.nanoTime() / 1000
}
