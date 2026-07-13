package com.swmansion.moqkit.subscribe.internal.playback

import android.util.Log

private const val TAG = "JitterBuffer"

/**
 * Decode-order jitter buffer for media frames.
 *
 * Manages buffering->playing state transitions and playability decisions
 * based on wall-clock-to-PTS offset tracking.
 */
internal class JitterBuffer<T>(
    private var targetBufferingUs: Long,
    private val wallClockUs: () -> Long = { System.nanoTime() / 1000 },
) {
    enum class State { BUFFERING, PLAYING, PENDING }

    data class Entry<T>(
        val item: T,
        val timestampUs: Long,
        var offsetUs: Long,
    )

    private val lock = Object()
    private val entries = ArrayDeque<Entry<T>>()
    private var mode = State.BUFFERING
    private var maxOffset = Long.MIN_VALUE
    private var onDataAvailable: (() -> Unit)? = null
    var onStartPlaying: (() -> Unit)? = null
    var onStartBuffering: (() -> Unit)? = null

    private var exhausted = true

    fun setOnDataAvailable(callback: (() -> Unit)?) {
        synchronized(lock) { onDataAvailable = callback }
    }

    /** Force-set the buffer state, bypassing normal transition logic. */
    fun setState(state: State) {
        synchronized(lock) { mode = state }
    }

    /**
     * Peek at the front entry without removing it.
     * Returns the entry regardless of mode (works in PENDING, BUFFERING, and PLAYING).
     */
    fun peekFront(): Entry<T>? {
        synchronized(lock) { return entries.firstOrNull() }
    }

    /**
     * Peek at the first entry matching the predicate.
     */
    fun peekWhere(predicate: (Entry<T>) -> Boolean): Entry<T>? {
        synchronized(lock) { return entries.firstOrNull(predicate) }
    }

    /**
     * Unconditionally remove the front entry regardless of mode.
     * Returns true if an entry was removed.
     */
    fun discardFront(): Boolean {
        synchronized(lock) {
            if (entries.isEmpty()) return false
            entries.removeFirst()
            return true
        }
    }

    /**
     * Insert an item in decode order.
     * Tracks wall-clock-to-PTS offset and transitions buffering->playing.
     */
    fun insert(item: T, timestampUs: Long) {
        val notify: Boolean
        var startedPlaying = false
        synchronized(lock) {
            val offset = timestampUs - wallClockTimeUs()

            if (offset > maxOffset) {
                val diff = offset - maxOffset
                for (entry in entries) {
                    entry.offsetUs += diff
                }
                maxOffset = offset
            }

            val wasEmpty = entries.isEmpty()
            val entry = Entry(item, timestampUs, offset)

            // moq-mux emits frames in decode order. Presentation timestamps may move
            // backwards for B-frames, so sorting by PTS would corrupt decoder input order.
            entries.addLast(entry)

            // Transition buffering -> playing when we have enough depth
            if (mode == State.BUFFERING && entries.size >= 2) {
                val oldest = entries.minOf { it.timestampUs }
                val newest = entries.maxOf { it.timestampUs }
                if (newest - oldest >= targetBufferingUs) {
                    mode = State.PLAYING
                    Log.d(TAG, "Transitioned to PLAYING (${entries.size} frames buffered)")
                    notify = onDataAvailable != null
                    startedPlaying = true
                    return@synchronized
                }
            }

            // Notify if inserting into empty buffer while playing
            notify = exhausted || (wasEmpty && mode == State.PLAYING)
        }

        if (startedPlaying) onStartPlaying?.invoke()
        if (notify) {
            onDataAvailable?.invoke()
        }
    }

    /**
     * Dequeue the oldest entry.
     * Returns (entry, playable) where playable indicates the frame should be rendered vs dropped.
     * Returns (null, false) if buffering or empty.
     *
     * Playability is decided against the estimated video live-edge target
     * (`estimatedLivePTS - targetBufferingUs`), mirroring the iOS `dequeue()` path. The
     * finer-grained late-drop and render-scheduling decisions happen later in VideoRenderer
     * against the playback clock, so this gate intentionally carries headroom.
     */
    fun dequeue(): Pair<Entry<T>?, Boolean> {
        synchronized(lock) {
            if (mode != State.PLAYING || entries.isEmpty()) {
                if (mode != State.PENDING) exhausted = true
                return null to false
            }

            exhausted = false

            val entry = entries.removeFirst()
            val estimatedLivePts = wallClockTimeUs() + maxOffset
            val targetPlaybackPts = estimatedLivePts - targetBufferingUs
            val playable = entry.timestampUs >= targetPlaybackPts

            return entry to playable
        }
    }

    /**
     * Peek the PTS of the oldest buffered entry without removing it.
     * Returns null if not in PLAYING state or if buffer is empty.
     */
    fun peekNextTimestampUs(): Long? {
        synchronized(lock) {
            if (mode != State.PLAYING) return null
            return entries.firstOrNull()?.timestampUs
        }
    }

    /**
     * Estimated live-edge PTS from the maximum sender timestamp to local wall-clock offset.
     */
    fun estimatedLivePTS(): Long? {
        synchronized(lock) {
            if (maxOffset == Long.MIN_VALUE) return null
            return try {
                Math.addExact(wallClockTimeUs(), maxOffset)
            } catch (_: ArithmeticException) {
                null
            }
        }
    }

    /**
     * Current desired playback PTS (`estimatedLivePTS - targetBufferingUs`).
     */
    fun targetPlaybackPTS(): Long? {
        val estimated = estimatedLivePTS() ?: return null
        return try {
            Math.subtractExact(estimated, targetBufferingUs).takeIf { it >= 0L }
        } catch (_: ArithmeticException) {
            null
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

    /**
     * Update target buffering depth.
     *
     * Returns true when a buffer that was waiting for enough depth became playable.
     */
    fun updateTargetBuffering(us: Long): Boolean {
        synchronized(lock) {
            targetBufferingUs = us
            return updateBufferingStateIfReady()
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
        }
        onStartBuffering?.invoke()
    }

    val state: State get() = synchronized(lock) { mode }
    val count: Int get() = synchronized(lock) { entries.size }
    val depthMs: Double get() = synchronized(lock) {
        if (entries.size < 2) 0.0
        else (entries.maxOf { it.timestampUs } - entries.minOf { it.timestampUs }).toDouble() / 1000.0
    }

    val frontFrameIntervalUs: Long? get() = synchronized(lock) {
        if (entries.size < 2) return@synchronized null
        val iterator = entries.iterator()
        val first = iterator.next().timestampUs
        val second = iterator.next().timestampUs
        if (second > first) second - first else null
    }

    private fun updateBufferingStateIfReady(): Boolean {
        if (mode != State.BUFFERING || entries.size < 2) return false
        val oldest = entries.minOf { it.timestampUs }
        val newest = entries.maxOf { it.timestampUs }
        if (newest < oldest || newest - oldest < targetBufferingUs) return false
        mode = State.PLAYING
        Log.d(TAG, "Transitioned to PLAYING (${entries.size} frames buffered)")
        return true
    }

    private fun wallClockTimeUs(): Long = wallClockUs()
}
