package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.PlaybackStats
import com.swmansion.moqkit.subscribe.StallStats

/**
 * Thread-safe accumulator for playback quality metrics.
 *
 * All write methods are lightweight (synchronized on a single lock).
 * One [snapshot] method reads all fields under the lock and returns [PlaybackStats].
 */
internal class PlaybackMetricsAccumulator {
    private val lock = Any()

    // TTFF
    private var playStartNs: Long = 0
    private var firstAudioFrameNs: Long = 0
    private var firstVideoFrameNs: Long = 0

    // Stalls — audio
    private var audioStallCount: Long = 0
    private var audioStallStartNs: Long = 0
    private var audioStallTotalNs: Long = 0
    private var audioIsStalled: Boolean = false
    private var audioPlayTimeNs: Long = 0
    private var audioPlayStartNs: Long = 0
    private var audioIsPlaying: Boolean = false

    // Stalls — video
    private var videoStallCount: Long = 0
    private var videoStallStartNs: Long = 0
    private var videoStallTotalNs: Long = 0
    private var videoIsStalled: Boolean = false
    private var videoPlayTimeNs: Long = 0
    private var videoPlayStartNs: Long = 0
    private var videoIsPlaying: Boolean = false

    // Bitrate — audio (1-sec rolling window)
    private val audioBytesWindow = mutableListOf<Pair<Long, Int>>() // (ns, bytes)
    private var audioBytesTotal: Int = 0

    // Bitrate — video (1-sec rolling window)
    private val videoBytesWindow = mutableListOf<Pair<Long, Int>>()
    private var videoBytesTotal: Int = 0

    // FPS — video (1-sec rolling window)
    private val videoFrameTimestamps = mutableListOf<Long>()

    // Dropped frames
    private var audioFramesDroppedCount: Long = 0
    private var videoFramesDroppedCount: Long = 0

    companion object {
        private const val WINDOW_NS = 1_000_000_000L // 1 second
    }

    // -- TTFF --

    fun markPlayStart() {
        val now = System.nanoTime()
        synchronized(lock) {
            playStartNs = now
        }
    }

    fun markFirstAudioFrame() {
        val now = System.nanoTime()
        synchronized(lock) {
            if (firstAudioFrameNs == 0L) {
                firstAudioFrameNs = now
            }
        }
    }

    fun markFirstVideoFrame() {
        val now = System.nanoTime()
        synchronized(lock) {
            if (firstVideoFrameNs == 0L) {
                firstVideoFrameNs = now
            }
        }
    }

    // -- Stalls --

    fun audioStallBegan() {
        val now = System.nanoTime()
        synchronized(lock) {
            if (!audioIsStalled) {
                audioIsStalled = true
                audioStallCount++
                audioStallStartNs = now
                if (audioIsPlaying) {
                    audioPlayTimeNs += now - audioPlayStartNs
                    audioIsPlaying = false
                }
            }
        }
    }

    fun audioStallEnded() {
        val now = System.nanoTime()
        synchronized(lock) {
            if (audioIsStalled) {
                audioIsStalled = false
                audioStallTotalNs += now - audioStallStartNs
                audioIsPlaying = true
                audioPlayStartNs = now
            } else if (!audioIsPlaying) {
                audioIsPlaying = true
                audioPlayStartNs = now
            }
        }
    }

    fun videoStallBegan() {
        val now = System.nanoTime()
        synchronized(lock) {
            if (!videoIsStalled) {
                videoIsStalled = true
                videoStallCount++
                videoStallStartNs = now
                if (videoIsPlaying) {
                    videoPlayTimeNs += now - videoPlayStartNs
                    videoIsPlaying = false
                }
            }
        }
    }

    fun videoStallEnded() {
        val now = System.nanoTime()
        synchronized(lock) {
            if (videoIsStalled) {
                videoIsStalled = false
                videoStallTotalNs += now - videoStallStartNs
                videoIsPlaying = true
                videoPlayStartNs = now
            } else if (!videoIsPlaying) {
                videoIsPlaying = true
                videoPlayStartNs = now
            }
        }
    }

    // -- Bitrate --

    fun recordAudioBytes(count: Int) {
        val now = System.nanoTime()
        synchronized(lock) {
            audioBytesWindow.add(now to count)
            audioBytesTotal += count
            pruneWindow(audioBytesWindow, now) { audioBytesTotal -= it }
        }
    }

    fun recordVideoBytes(count: Int) {
        val now = System.nanoTime()
        synchronized(lock) {
            videoBytesWindow.add(now to count)
            videoBytesTotal += count
            pruneWindow(videoBytesWindow, now) { videoBytesTotal -= it }
        }
    }

    // -- FPS --

    fun recordVideoFrameDisplayed() {
        val now = System.nanoTime()
        synchronized(lock) {
            videoFrameTimestamps.add(now)
            pruneTimestamps(videoFrameTimestamps, now)
        }
    }

    // -- Dropped frames --

    fun recordVideoFrameDropped() {
        synchronized(lock) {
            videoFramesDroppedCount++
        }
    }

    fun recordAudioFramesDropped(count: Int) {
        if (count <= 0) return
        synchronized(lock) {
            audioFramesDroppedCount += count
        }
    }

    // -- Snapshot --

    fun snapshot(
        audioLatencyMs: Double?,
        videoLatencyMs: Double?,
        audioRingBufferMs: Double? = null,
        videoJitterBufferMs: Double? = null,
    ): PlaybackStats {
        val now = System.nanoTime()
        synchronized(lock) {
            // TTFF
            val ttfAudio = if (playStartNs > 0 && firstAudioFrameNs > 0) {
                (firstAudioFrameNs - playStartNs).toDouble() / 1_000_000.0
            } else null

            val ttfVideo = if (playStartNs > 0 && firstVideoFrameNs > 0) {
                (firstVideoFrameNs - playStartNs).toDouble() / 1_000_000.0
            } else null

            // Stalls
            val aStalls = if (audioStallCount > 0 || audioIsPlaying || audioIsStalled) {
                makeStallStats(
                    audioStallCount, audioStallTotalNs,
                    audioIsStalled, audioStallStartNs,
                    audioPlayTimeNs, audioIsPlaying,
                    audioPlayStartNs, now,
                )
            } else null

            val vStalls = if (videoStallCount > 0 || videoIsPlaying || videoIsStalled) {
                makeStallStats(
                    videoStallCount, videoStallTotalNs,
                    videoIsStalled, videoStallStartNs,
                    videoPlayTimeNs, videoIsPlaying,
                    videoPlayStartNs, now,
                )
            } else null

            // Bitrate
            val aBitrate = computeBitrateKbps(audioBytesWindow, audioBytesTotal, now)
            val vBitrate = computeBitrateKbps(videoBytesWindow, videoBytesTotal, now)

            // FPS
            val fps = computeFps(videoFrameTimestamps, now)

            // Dropped
            val aDrop = if (audioFramesDroppedCount > 0) audioFramesDroppedCount else null
            val vDrop = if (videoFramesDroppedCount > 0) videoFramesDroppedCount else null

            return PlaybackStats(
                audioLatencyMs = audioLatencyMs,
                videoLatencyMs = videoLatencyMs,
                audioStalls = aStalls,
                videoStalls = vStalls,
                audioBitrateKbps = aBitrate,
                videoBitrateKbps = vBitrate,
                timeToFirstAudioFrameMs = ttfAudio,
                timeToFirstVideoFrameMs = ttfVideo,
                videoFps = fps,
                audioFramesDropped = aDrop,
                videoFramesDropped = vDrop,
                audioRingBufferMs = audioRingBufferMs,
                videoJitterBufferMs = videoJitterBufferMs,
            )
        }
    }

    // -- Reset --

    fun reset() {
        synchronized(lock) {
            playStartNs = 0
            firstAudioFrameNs = 0
            firstVideoFrameNs = 0

            audioStallCount = 0
            audioStallStartNs = 0
            audioStallTotalNs = 0
            audioIsStalled = false
            audioPlayTimeNs = 0
            audioPlayStartNs = 0
            audioIsPlaying = false

            videoStallCount = 0
            videoStallStartNs = 0
            videoStallTotalNs = 0
            videoIsStalled = false
            videoPlayTimeNs = 0
            videoPlayStartNs = 0
            videoIsPlaying = false

            audioBytesWindow.clear()
            audioBytesTotal = 0
            videoBytesWindow.clear()
            videoBytesTotal = 0
            videoFrameTimestamps.clear()

            audioFramesDroppedCount = 0
            videoFramesDroppedCount = 0
        }
    }

    // -- Private helpers (called under lock) --

    private inline fun pruneWindow(
        entries: MutableList<Pair<Long, Int>>,
        now: Long,
        onRemove: (Int) -> Unit,
    ) {
        val cutoff = if (now >= WINDOW_NS) now - WINDOW_NS else 0L
        while (entries.isNotEmpty() && entries[0].first < cutoff) {
            onRemove(entries.removeAt(0).second)
        }
    }

    private fun pruneTimestamps(entries: MutableList<Long>, now: Long) {
        val cutoff = if (now >= WINDOW_NS) now - WINDOW_NS else 0L
        while (entries.isNotEmpty() && entries[0] < cutoff) {
            entries.removeAt(0)
        }
    }

    private fun computeBitrateKbps(
        entries: List<Pair<Long, Int>>,
        total: Int,
        now: Long,
    ): Double? {
        if (entries.isEmpty()) return null
        val spanNs = now - entries[0].first
        if (spanNs < 100_000_000L) return null // need at least 100ms
        val spanSec = spanNs.toDouble() / 1_000_000_000.0
        return total.toDouble() * 8.0 / 1000.0 / spanSec
    }

    private fun computeFps(entries: List<Long>, now: Long): Double? {
        if (entries.size < 2) return null
        val spanNs = now - entries[0]
        if (spanNs < 100_000_000L) return null
        val spanSec = spanNs.toDouble() / 1_000_000_000.0
        return entries.size.toDouble() / spanSec
    }

    private fun makeStallStats(
        count: Long,
        stallTotalNs: Long,
        isStalled: Boolean,
        stallStartNs: Long,
        playTimeNs: Long,
        isPlaying: Boolean,
        playStartNs: Long,
        now: Long,
    ): StallStats {
        var totalStallNs = stallTotalNs
        if (isStalled) {
            totalStallNs += now - stallStartNs
        }
        var totalPlayNs = playTimeNs
        if (isPlaying) {
            totalPlayNs += now - playStartNs
        }
        val totalMs = totalStallNs.toDouble() / 1_000_000.0
        val totalTime = (totalPlayNs + totalStallNs).toDouble()
        val ratio = if (totalTime > 0) totalStallNs.toDouble() / totalTime else 0.0
        return StallStats(count = count, totalDurationMs = totalMs, rebufferingRatio = ratio)
    }
}
