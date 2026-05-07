package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.FrameArrivalStats
import com.swmansion.moqkit.subscribe.PlaybackStats
import com.swmansion.moqkit.subscribe.StallStats
import com.swmansion.moqkit.subscribe.VideoDecodeStats
import uniffi.moq.MoqFrame

/**
 * Thread-safe tracker for playback quality metrics and received-frame diagnostics.
 *
 * All write methods are lightweight (synchronized on a single lock).
 * One [snapshot] method reads all fields under the lock and returns [PlaybackStats].
 */
internal class PlaybackStatsTracker(
    private val clock: () -> Long = System::nanoTime,
) : MediaFrameObserver {
    private data class ArrivalInterval(val ns: Long, val ms: Double)

    private data class FrameArrivalState(
        var lastWallNs: Long? = null,
        var lastPtsUs: Long? = null,
        var highestPtsUs: Long? = null,
        val frameTimestamps: MutableList<Long> = mutableListOf(),
        val intervalsWindow: MutableList<ArrivalInterval> = mutableListOf(),
        var intervalMsTotal: Double = 0.0,
        var arrivalGapCount: Long = 0,
        var burstCount: Long = 0,
        var outOfOrderCount: Long = 0,
        var maxOutOfOrderDeltaMs: Double = 0.0,
        var discontinuityCount: Long = 0,
        var maxDiscontinuityGapMs: Double = 0.0,
    ) {
        val hasData: Boolean
            get() = frameTimestamps.isNotEmpty() ||
                arrivalGapCount > 0 ||
                burstCount > 0 ||
                outOfOrderCount > 0 ||
                discontinuityCount > 0

        fun resetAll() {
            lastWallNs = null
            lastPtsUs = null
            highestPtsUs = null
            frameTimestamps.clear()
            intervalsWindow.clear()
            intervalMsTotal = 0.0
            arrivalGapCount = 0
            burstCount = 0
            outOfOrderCount = 0
            maxOutOfOrderDeltaMs = 0.0
            discontinuityCount = 0
            maxDiscontinuityGapMs = 0.0
        }

        fun resetTimingBaseline() {
            lastWallNs = null
            lastPtsUs = null
            highestPtsUs = null
        }
    }

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

    // Bitrate — audio/video (1-sec rolling window)
    private val audioBytesWindow = mutableListOf<Pair<Long, Int>>()
    private var audioBytesTotal: Int = 0
    private val videoBytesWindow = mutableListOf<Pair<Long, Int>>()
    private var videoBytesTotal: Int = 0

    // FPS — displayed video (1-sec rolling window)
    private val videoFrameTimestamps = mutableListOf<Long>()

    // Received-frame arrival diagnostics
    private val audioArrival = FrameArrivalState()
    private val videoArrival = FrameArrivalState()

    // Dropped frames
    private var audioFramesDroppedCount: Long = 0
    private var videoFramesDroppedCount: Long = 0

    // Video decode timing
    private var videoDecodeTrackName: String? = null
    private var videoDecodeSampleCount: Long = 0
    private var videoDecodeMinNs: Long = Long.MAX_VALUE
    private var videoDecodeMaxNs: Long = 0
    private var videoDecodeTotalNs: Long = 0
    private var videoDecodeLastNs: Long = 0
    private var videoDecodeInFlightBufferCount: Int = 0
    private var videoDecodeLastOutputNs: Long = 0
    private var videoDecodeOutputIntervalCount: Long = 0
    private var videoDecodeMinOutputIntervalNs: Long = Long.MAX_VALUE
    private var videoDecodeMaxOutputIntervalNs: Long = 0
    private var videoDecodeTotalOutputIntervalNs: Long = 0

    companion object {
        private const val WINDOW_NS = 1_000_000_000L
        private const val MIN_WINDOW_SPAN_NS = 100_000_000L
        private const val ARRIVAL_GAP_FACTOR = 2.0
        private const val BURST_FACTOR = 0.3
        private const val DISCONTINUITY_THRESHOLD_US = 2_000_000L
    }

    override fun onMediaFrame(frame: MoqFrame, kind: MediaFrameKind) {
        val now = clock()
        val timestampUs = frame.timestampUs.toLong()
        val payloadSize = frame.payload.size

        synchronized(lock) {
            when (kind) {
                MediaFrameKind.AUDIO -> {
                    if (firstAudioFrameNs == 0L) {
                        firstAudioFrameNs = now
                    }
                    audioBytesWindow.add(now to payloadSize)
                    audioBytesTotal += payloadSize
                    pruneWindow(audioBytesWindow, now) { audioBytesTotal -= it }
                    recordArrival(timestampUs, now, audioArrival)
                }

                MediaFrameKind.VIDEO -> {
                    if (firstVideoFrameNs == 0L) {
                        firstVideoFrameNs = now
                    }
                    videoBytesWindow.add(now to payloadSize)
                    videoBytesTotal += payloadSize
                    pruneWindow(videoBytesWindow, now) { videoBytesTotal -= it }
                    recordArrival(timestampUs, now, videoArrival)
                }
            }
        }
    }

    override fun onFrameDiscontinuity(kind: MediaFrameKind, gapUs: Long) {
        synchronized(lock) {
            val gapMs = gapUs.toDouble() / 1_000.0
            when (kind) {
                MediaFrameKind.AUDIO -> {
                    audioArrival.discontinuityCount++
                    audioArrival.maxDiscontinuityGapMs =
                        maxOf(audioArrival.maxDiscontinuityGapMs, gapMs)
                    audioArrival.resetTimingBaseline()
                }

                MediaFrameKind.VIDEO -> {
                    videoArrival.discontinuityCount++
                    videoArrival.maxDiscontinuityGapMs =
                        maxOf(videoArrival.maxDiscontinuityGapMs, gapMs)
                    videoArrival.resetTimingBaseline()
                }
            }
        }
    }

    // -- TTFF --

    fun markPlayStart() {
        val now = clock()
        synchronized(lock) {
            playStartNs = now
        }
    }

    // -- Stalls --

    fun audioStallBegan() {
        val now = clock()
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
        val now = clock()
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
        val now = clock()
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
        val now = clock()
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

    // -- FPS --

    fun recordVideoFrameDisplayed() {
        val now = clock()
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

    // -- Video decode timing --

    fun resetVideoDecodeStats(trackName: String?) {
        synchronized(lock) {
            videoDecodeTrackName = trackName
            videoDecodeSampleCount = 0
            videoDecodeMinNs = Long.MAX_VALUE
            videoDecodeMaxNs = 0
            videoDecodeTotalNs = 0
            videoDecodeLastNs = 0
            videoDecodeInFlightBufferCount = 0
            videoDecodeLastOutputNs = 0
            videoDecodeOutputIntervalCount = 0
            videoDecodeMinOutputIntervalNs = Long.MAX_VALUE
            videoDecodeMaxOutputIntervalNs = 0
            videoDecodeTotalOutputIntervalNs = 0
        }
    }

    fun recordVideoDecodeBufferSubmitted(trackName: String) {
        synchronized(lock) {
            if (videoDecodeTrackName == null) {
                videoDecodeTrackName = trackName
            } else if (videoDecodeTrackName != trackName) {
                return
            }

            videoDecodeInFlightBufferCount++
        }
    }

    fun recordVideoDecodeTime(
        trackName: String,
        durationNs: Long,
        outputAtNs: Long = clock(),
    ) {
        if (durationNs < 0) return
        synchronized(lock) {
            if (videoDecodeTrackName == null) {
                videoDecodeTrackName = trackName
            } else if (videoDecodeTrackName != trackName) {
                return
            }

            if (videoDecodeInFlightBufferCount > 0) {
                videoDecodeInFlightBufferCount--
            }

            if (videoDecodeLastOutputNs > 0L) {
                val intervalNs = outputAtNs - videoDecodeLastOutputNs
                if (intervalNs >= 0L) {
                    videoDecodeOutputIntervalCount++
                    videoDecodeMinOutputIntervalNs =
                        minOf(videoDecodeMinOutputIntervalNs, intervalNs)
                    videoDecodeMaxOutputIntervalNs =
                        maxOf(videoDecodeMaxOutputIntervalNs, intervalNs)
                    videoDecodeTotalOutputIntervalNs += intervalNs
                }
            }
            videoDecodeLastOutputNs = outputAtNs

            videoDecodeSampleCount++
            videoDecodeMinNs = minOf(videoDecodeMinNs, durationNs)
            videoDecodeMaxNs = maxOf(videoDecodeMaxNs, durationNs)
            videoDecodeTotalNs += durationNs
            videoDecodeLastNs = durationNs
        }
    }

    // -- Snapshot --

    fun snapshot(
        audioLatencyMs: Double?,
        videoLatencyMs: Double?,
        audioRingBufferMs: Double? = null,
        videoJitterBufferMs: Double? = null,
        videoDecodeStatsEnabled: Boolean = true,
    ): PlaybackStats {
        val now = clock()
        synchronized(lock) {
            val ttfAudio = if (playStartNs > 0 && firstAudioFrameNs > 0) {
                (firstAudioFrameNs - playStartNs).toDouble() / 1_000_000.0
            } else null

            val ttfVideo = if (playStartNs > 0 && firstVideoFrameNs > 0) {
                (firstVideoFrameNs - playStartNs).toDouble() / 1_000_000.0
            } else null

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

            val aBitrate = computeBitrateKbps(audioBytesWindow, audioBytesTotal, now)
            val vBitrate = computeBitrateKbps(videoBytesWindow, videoBytesTotal, now)
            val fps = computeFps(videoFrameTimestamps, now)
            val aDrop = if (audioFramesDroppedCount > 0) audioFramesDroppedCount else null
            val vDrop = if (videoFramesDroppedCount > 0) videoFramesDroppedCount else null
            val decodeStats = if (videoDecodeStatsEnabled) makeVideoDecodeStats() else null

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
                videoDecodeStats = decodeStats,
                audioArrival = makeFrameArrivalStats(audioArrival, now),
                videoArrival = makeFrameArrivalStats(videoArrival, now),
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
            audioArrival.resetAll()
            videoArrival.resetAll()

            audioFramesDroppedCount = 0
            videoFramesDroppedCount = 0

            videoDecodeTrackName = null
            videoDecodeSampleCount = 0
            videoDecodeMinNs = Long.MAX_VALUE
            videoDecodeMaxNs = 0
            videoDecodeTotalNs = 0
            videoDecodeLastNs = 0
            videoDecodeInFlightBufferCount = 0
            videoDecodeLastOutputNs = 0
            videoDecodeOutputIntervalCount = 0
            videoDecodeMinOutputIntervalNs = Long.MAX_VALUE
            videoDecodeMaxOutputIntervalNs = 0
            videoDecodeTotalOutputIntervalNs = 0
        }
    }

    // -- Private helpers (called under lock) --

    private fun recordArrival(timestampUs: Long, now: Long, state: FrameArrivalState) {
        state.frameTimestamps.add(now)
        pruneTimestamps(state.frameTimestamps, now)
        pruneArrivalIntervals(state, now)

        val highestPtsUs = state.highestPtsUs
        if (highestPtsUs != null && timestampUs < highestPtsUs) {
            state.outOfOrderCount++
            val deltaMs = (highestPtsUs - timestampUs).toDouble() / 1_000.0
            state.maxOutOfOrderDeltaMs = maxOf(state.maxOutOfOrderDeltaMs, deltaMs)
        }
        state.highestPtsUs = maxOf(state.highestPtsUs ?: 0L, timestampUs)

        val previousWallNs = state.lastWallNs
        val previousPtsUs = state.lastPtsUs
        if (previousWallNs != null && previousPtsUs != null) {
            val isOutOfOrder = timestampUs < previousPtsUs
            val ptsDeltaUs = if (isOutOfOrder) 0L else timestampUs - previousPtsUs

            if (!isOutOfOrder && ptsDeltaUs <= DISCONTINUITY_THRESHOLD_US) {
                val wallDeltaMs = (now - previousWallNs).toDouble() / 1_000_000.0
                state.intervalsWindow.add(ArrivalInterval(now, wallDeltaMs))
                state.intervalMsTotal += wallDeltaMs
                pruneArrivalIntervals(state, now)

                val ptsDeltaMs = ptsDeltaUs.toDouble() / 1_000.0
                if (ptsDeltaMs > 0.0) {
                    if (wallDeltaMs > ptsDeltaMs * ARRIVAL_GAP_FACTOR) {
                        state.arrivalGapCount++
                    } else if (wallDeltaMs < ptsDeltaMs * BURST_FACTOR) {
                        state.burstCount++
                    }
                }
            }
        }

        state.lastWallNs = now
        state.lastPtsUs = timestampUs
    }

    private fun makeVideoDecodeStats(): VideoDecodeStats? {
        val trackName = videoDecodeTrackName ?: return null
        if (videoDecodeSampleCount == 0L && videoDecodeInFlightBufferCount == 0) return null
        val minOutputIntervalMs = if (videoDecodeOutputIntervalCount > 0L) {
            videoDecodeMinOutputIntervalNs.toDouble() / 1_000_000.0
        } else null
        val averageOutputIntervalMs = if (videoDecodeOutputIntervalCount > 0L) {
            videoDecodeTotalOutputIntervalNs.toDouble() /
                videoDecodeOutputIntervalCount.toDouble() /
                1_000_000.0
        } else null
        val maxOutputIntervalMs = if (videoDecodeOutputIntervalCount > 0L) {
            videoDecodeMaxOutputIntervalNs.toDouble() / 1_000_000.0
        } else null

        return VideoDecodeStats(
            trackName = trackName,
            sampleCount = videoDecodeSampleCount,
            minMs = if (videoDecodeSampleCount > 0L) videoDecodeMinNs.toDouble() / 1_000_000.0 else 0.0,
            maxMs = if (videoDecodeSampleCount > 0L) videoDecodeMaxNs.toDouble() / 1_000_000.0 else 0.0,
            averageMs = if (videoDecodeSampleCount > 0L) {
                videoDecodeTotalNs.toDouble() / videoDecodeSampleCount.toDouble() / 1_000_000.0
            } else 0.0,
            lastMs = if (videoDecodeSampleCount > 0L) videoDecodeLastNs.toDouble() / 1_000_000.0 else 0.0,
            inFlightBufferCount = videoDecodeInFlightBufferCount,
            minOutputIntervalMs = minOutputIntervalMs,
            averageOutputIntervalMs = averageOutputIntervalMs,
            maxOutputIntervalMs = maxOutputIntervalMs,
        )
    }

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

    private fun pruneArrivalIntervals(state: FrameArrivalState, now: Long) {
        val cutoff = if (now >= WINDOW_NS) now - WINDOW_NS else 0L
        while (state.intervalsWindow.isNotEmpty() && state.intervalsWindow[0].ns < cutoff) {
            state.intervalMsTotal -= state.intervalsWindow.removeAt(0).ms
        }
    }

    private fun computeBitrateKbps(
        entries: List<Pair<Long, Int>>,
        total: Int,
        now: Long,
    ): Double? {
        if (entries.isEmpty()) return null
        val spanNs = now - entries[0].first
        if (spanNs < MIN_WINDOW_SPAN_NS) return null
        val spanSec = spanNs.toDouble() / 1_000_000_000.0
        return total.toDouble() * 8.0 / 1000.0 / spanSec
    }

    private fun computeFps(entries: List<Long>, now: Long): Double? {
        if (entries.size < 2) return null
        val spanNs = now - entries[0]
        if (spanNs < MIN_WINDOW_SPAN_NS) return null
        val spanSec = spanNs.toDouble() / 1_000_000_000.0
        return entries.size.toDouble() / spanSec
    }

    private fun makeFrameArrivalStats(
        state: FrameArrivalState,
        now: Long,
    ): FrameArrivalStats? {
        if (!state.hasData) return null
        val averageInterarrivalMs = if (state.intervalsWindow.isNotEmpty()) {
            state.intervalMsTotal / state.intervalsWindow.size.toDouble()
        } else null

        return FrameArrivalStats(
            receivedFramesPerSecond = computeFps(state.frameTimestamps, now),
            averageInterarrivalMs = averageInterarrivalMs,
            maxInterarrivalMs = state.intervalsWindow.maxOfOrNull { it.ms },
            arrivalGapCount = state.arrivalGapCount,
            burstCount = state.burstCount,
            outOfOrderCount = state.outOfOrderCount,
            maxOutOfOrderDeltaMs = state.maxOutOfOrderDeltaMs.takeIf { it > 0.0 },
            discontinuityCount = state.discontinuityCount,
            maxDiscontinuityGapMs = state.maxDiscontinuityGapMs.takeIf { it > 0.0 },
        )
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
