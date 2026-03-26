package com.swmansion.moqkit

import android.util.Log

private const val TAG = "JitterBuffer"

/**
 * Sorted jitter buffer for media frames.
 * Port of iOS JitterBuffer<CMSampleBuffer>, generic over item type.
 *
 * Manages buffering->playing state transitions and playability decisions
 * based on wall-clock-to-PTS offset tracking.
 */
internal class JitterBuffer<T>(
    private var targetBufferingUs: Long,
) {
    enum class State { BUFFERING, PLAYING }

    data class Entry<T>(
        val item: T,
        val timestampUs: Long,
        var offsetUs: Long,
    )

    private val lock = Object()
    private val entries = mutableListOf<Entry<T>>()
    private var mode = State.BUFFERING
    private var maxOffset = Long.MIN_VALUE
    private var onDataAvailable: (() -> Unit)? = null
    var onStartPlaying: (() -> Unit)? = null
    var onStartBuffering: (() -> Unit)? = null

    private var exhausted = true

    fun setOnDataAvailable(callback: (() -> Unit)?) {
        synchronized(lock) { onDataAvailable = callback }
    }

    /**
     * Insert an item, sorted by timestamp.
     * Tracks wall-clock-to-PTS offset and transitions buffering->playing.
     */
    fun insert(item: T, timestampUs: Long) {
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
            val entry = Entry(item, timestampUs, offset)

            // Sorted insert by timestampUs (ascending)
            val index = entries.indexOfFirst { it.timestampUs > timestampUs }
            if (index >= 0) {
                entries.add(index, entry)
            } else {
                entries.add(entry)
            }

            // Transition buffering -> playing when we have enough depth
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
            notify = exhausted || (wasEmpty && mode == State.PLAYING)
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
    fun dequeue(mediaTimeUs: Long? = null): Pair<Entry<T>?, Boolean> {
        synchronized(lock) {
            if (mode != State.PLAYING || entries.isEmpty()) {
                exhausted = true
                return null to false
            }

            exhausted = false

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
     * Peek the PTS of the oldest buffered entry without removing it.
     * Returns null if not in PLAYING state or if buffer is empty.
     */
    fun peekNextTimestampUs(): Long? {
        synchronized(lock) {
            if (mode != State.PLAYING || entries.isEmpty()) return null
            return entries.first().timestampUs
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
        synchronized(lock) { 
          targetBufferingUs = us 
          mode = State.BUFFERING
        }
    }

    /**
     * Discard all entries and reset to buffering state.
     */
    fun flush() {
        synchronized(lock) {
            entries.clear()
            mode = State.BUFFERING
            maxOffset = Long.MIN_VALUE
            onStartBuffering?.invoke()
        }
    }

    val state: State get() = synchronized(lock) { mode }
    val count: Int get() = synchronized(lock) { entries.size }
    val depthMs: Double get() = synchronized(lock) {
        if (entries.size < 2) 0.0
        else (entries.last().timestampUs - entries.first().timestampUs).toDouble() / 1000.0
    }

    private fun wallClockTimeUs(): Long = System.nanoTime() / 1000
}
