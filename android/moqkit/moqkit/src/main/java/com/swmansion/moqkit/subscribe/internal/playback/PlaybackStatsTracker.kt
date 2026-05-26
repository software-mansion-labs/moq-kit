package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.FrameArrivalStats
import com.swmansion.moqkit.subscribe.PlaybackStats
import com.swmansion.moqkit.subscribe.PlayerAudioPlaybackOutput
import com.swmansion.moqkit.subscribe.PlayerEventType
import com.swmansion.moqkit.subscribe.PlayerPlaybackEndEvent
import com.swmansion.moqkit.subscribe.PlayerTrackErrorEvent
import com.swmansion.moqkit.subscribe.PlayerTrackEvent
import com.swmansion.moqkit.subscribe.PlayerTrackKind
import com.swmansion.moqkit.subscribe.PlayerTrackPlaybackOutput
import com.swmansion.moqkit.subscribe.PlayerTrackPlayingEvent
import com.swmansion.moqkit.subscribe.PlayerTrackReadyEvent
import com.swmansion.moqkit.subscribe.PlayerVideoPlaybackOutput
import com.swmansion.moqkit.subscribe.StallStats
import com.swmansion.moqkit.subscribe.TimeToFirstPlaybackStats
import com.swmansion.moqkit.subscribe.TrackSwitch
import com.swmansion.moqkit.subscribe.TrackSwitchStats
import com.swmansion.moqkit.subscribe.VideoDecodeStats
import uniffi.moq.MoqFrame
import java.time.Duration

internal data class PlaybackStartContext(
    val kind: MediaFrameKind,
    val trackName: String,
    val sourceTimestampUs: Long,
    val targetBuffering: Duration,
    val trackEpoch: Long,
)

internal data class TrackReadyContext(
    val kind: MediaFrameKind,
    val trackName: String,
    val sourceTimestampUs: Long,
    val targetBuffering: Duration,
    val trackEpoch: Long,
    val keyframe: Boolean,
    val payloadBytes: Int,
)

/**
 * Thread-safe tracker for playback quality metrics and lifecycle events.
 */
internal class PlaybackStatsTracker(
    private val events: PlayerEventHub = PlayerEventHub(),
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
        var slowArrivalCount: Long = 0,
        var fastArrivalCount: Long = 0,
        var outOfOrderCount: Long = 0,
        var maxOutOfOrderDeltaMs: Double = 0.0,
        var discontinuityCount: Long = 0,
        var maxDiscontinuityGapMs: Double = 0.0,
    ) {
        val hasData: Boolean
            get() = frameTimestamps.isNotEmpty() ||
                slowArrivalCount > 0 ||
                fastArrivalCount > 0 ||
                outOfOrderCount > 0 ||
                discontinuityCount > 0

        fun resetAll() {
            resetTimingBaseline()
            frameTimestamps.clear()
            intervalsWindow.clear()
            intervalMsTotal = 0.0
            slowArrivalCount = 0
            fastArrivalCount = 0
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

    private data class StallState(
        var readyAtNs: Long = 0L,
        var count: Long = 0L,
        var activeStartNs: Long = 0L,
        var totalNs: Long = 0L,
        var active: Boolean = false,
    ) {
        fun markReady(now: Long) {
            if (readyAtNs == 0L) readyAtNs = now
        }

        fun start(now: Long) {
            markReady(now)
            if (active) return
            active = true
            activeStartNs = now
            count++
        }

        fun end(now: Long) {
            if (!active) return
            totalNs += now - activeStartNs
            active = false
            activeStartNs = 0L
        }

        fun stats(now: Long): StallStats? {
            if (readyAtNs == 0L) return null
            val total = totalNs + if (active) now - activeStartNs else 0L
            val elapsed = (now - readyAtNs).coerceAtLeast(0L)
            val ratio = if (elapsed > 0L) total.toDouble() / elapsed.toDouble() else 0.0
            return StallStats(
                count = count,
                totalDuration = durationFromNanoseconds(total),
                rebufferingRatio = ratio,
            )
        }
    }

    private data class SwitchAttempt(
        var trackName: String?,
        val startedAtNs: Long,
        var readyAtNs: Long = 0L,
        var playingAtNs: Long = 0L,
        var activeAtNs: Long = 0L,
        var errorMessage: String? = null,
    )

    private data class SwitchState(
        var requestedCount: Long = 0L,
        var completedCount: Long = 0L,
        var latestAttempt: SwitchAttempt? = null,
        var countedLatestCompletion: Boolean = false,
    ) {
        fun start(trackName: String?, now: Long) {
            requestedCount++
            latestAttempt = SwitchAttempt(trackName = trackName, startedAtNs = now)
            countedLatestCompletion = false
        }

        fun markReady(now: Long) {
            val latest = latestAttempt ?: return
            if (latest.readyAtNs == 0L) latest.readyAtNs = now
        }

        fun markPlaying(now: Long) {
            val latest = latestAttempt ?: return
            if (latest.playingAtNs == 0L) latest.playingAtNs = now
        }

        fun markActive(now: Long) {
            val latest = latestAttempt ?: return
            if (latest.activeAtNs == 0L) latest.activeAtNs = now
            if (!countedLatestCompletion) {
                countedLatestCompletion = true
                completedCount++
            }
        }

        fun markError(message: String?) {
            latestAttempt?.errorMessage = message
        }

        fun stats(): TrackSwitchStats? {
            if (requestedCount == 0L) return null
            val latest = latestAttempt?.let { attempt ->
                TrackSwitch(
                    trackName = attempt.trackName,
                    isCompleted = attempt.activeAtNs > 0L,
                    errorMessage = attempt.errorMessage,
                    switchToReady = durationBetween(attempt.startedAtNs, attempt.readyAtNs),
                    readyToPlaying = durationBetween(attempt.readyAtNs, attempt.playingAtNs),
                    switchToPlaying = durationBetween(attempt.startedAtNs, attempt.playingAtNs),
                    switchToActive = durationBetween(attempt.startedAtNs, attempt.activeAtNs),
                )
            }
            return TrackSwitchStats(
                requestedCount = requestedCount,
                completedCount = completedCount,
                latest = latest,
            )
        }

        private fun durationBetween(startNs: Long, endNs: Long): Duration? {
            if (startNs == 0L || endNs == 0L) return null
            return durationFromNanoseconds((endNs - startNs).coerceAtLeast(0L))
        }
    }

    private val lock = Any()

    private var playStartNs: Long = 0L
    private var firstAudioFrameNs: Long = 0L
    private var firstVideoFrameNs: Long = 0L
    private var firstAudioPlayingNs: Long = 0L
    private var firstVideoPlayingNs: Long = 0L
    private var rebufferKind: MediaFrameKind? = null
    private var rebuffering = false
    private var playbackStartEmitted = false

    private val audioStalls = StallState()
    private val videoStalls = StallState()
    private val audioSwitches = SwitchState()
    private val videoSwitches = SwitchState()

    private val audioBytesWindow = mutableListOf<Pair<Long, Int>>()
    private var audioBytesTotal: Int = 0
    private val videoBytesWindow = mutableListOf<Pair<Long, Int>>()
    private var videoBytesTotal: Int = 0
    private val videoFrameTimestamps = mutableListOf<Long>()
    private val audioArrival = FrameArrivalState()
    private val videoArrival = FrameArrivalState()
    private var audioFramesDroppedCount: Long = 0
    private var videoFramesDroppedCount: Long = 0

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

    private var pendingAudioPlaybackStart: PlaybackStartContext? = null

    companion object {
        private const val WINDOW_NS = 1_000_000_000L
        private const val MIN_WINDOW_SPAN_NS = 100_000_000L
        private const val ARRIVAL_GAP_FACTOR = 2.0
        private const val BURST_FACTOR = 0.3
        private const val DISCONTINUITY_THRESHOLD_US = 2_000_000L
    }

    fun beginSession(rebufferKind: MediaFrameKind) {
        val now = clock()
        synchronized(lock) {
            this.rebufferKind = rebufferKind
            playStartNs = now
            firstAudioFrameNs = 0L
            firstVideoFrameNs = 0L
            firstAudioPlayingNs = 0L
            firstVideoPlayingNs = 0L
            rebuffering = false
            playbackStartEmitted = false
            audioStalls.reset()
            videoStalls.reset()
            audioSwitches.reset()
            videoSwitches.reset()
            pendingAudioPlaybackStart = null
        }
    }

    fun closeOutInFlightStalls() {
        val now = clock()
        synchronized(lock) {
            audioStalls.end(now)
            videoStalls.end(now)
            rebuffering = false
        }
    }

    fun emitSubscribeStart(kind: MediaFrameKind, trackName: String, trackEpoch: Long) {
        events.emit(PlayerEventType.TrackSubscribeStart(trackEvent(kind, trackName, trackEpoch)))
        if (trackEpoch <= 1L) return
        val now = clock()
        synchronized(lock) {
            switchState(kind).start(trackName, now)
        }
    }

    fun emitSubscribeError(kind: MediaFrameKind, trackName: String, message: String, trackEpoch: Long) {
        events.emit(
            PlayerEventType.TrackSubscribeError(
                PlayerTrackErrorEvent(
                    track = trackEvent(kind, trackName, trackEpoch),
                    message = message,
                ),
            ),
        )
        if (trackEpoch <= 1L) return
        synchronized(lock) {
            switchState(kind).markError(message)
        }
    }

    fun emitSubscribeEnd(kind: MediaFrameKind, trackName: String, trackEpoch: Long) {
        events.emit(PlayerEventType.TrackSubscribeEnd(trackEvent(kind, trackName, trackEpoch)))
    }

    fun emitTrackReady(context: TrackReadyContext) {
        events.emit(
            PlayerEventType.TrackReady(
                PlayerTrackReadyEvent(
                    track = trackEvent(context.kind, context.trackName, context.trackEpoch),
                    sourceTimestampUs = context.sourceTimestampUs,
                    targetBuffering = context.targetBuffering,
                    keyframe = context.keyframe,
                    payloadBytes = context.payloadBytes.coerceAtLeast(0).toLong(),
                ),
            ),
        )
        val now = clock()
        synchronized(lock) {
            if (context.trackEpoch == 1L && playStartNs > 0L) {
                when (context.kind) {
                    MediaFrameKind.AUDIO -> if (firstAudioFrameNs == 0L) firstAudioFrameNs = now
                    MediaFrameKind.VIDEO -> if (firstVideoFrameNs == 0L) firstVideoFrameNs = now
                }
            }
            if (context.trackEpoch > 1L) {
                switchState(context.kind).markReady(now)
            }
        }
    }

    fun emitTrackSwitch(kind: MediaFrameKind, trackName: String, trackEpoch: Long) {
        events.emit(PlayerEventType.TrackSwitch(trackEvent(kind, trackName, trackEpoch)))
        val now = clock()
        synchronized(lock) {
            switchState(kind).markActive(now)
        }
    }

    fun emitDecodeError(kind: MediaFrameKind, trackName: String, message: String) {
        events.emit(
            PlayerEventType.DecodeError(
                PlayerTrackErrorEvent(
                    track = trackEvent(kind, trackName),
                    message = message,
                ),
            ),
        )
    }

    fun emitPlaybackEnd(reason: String?) {
        events.emit(PlayerEventType.PlaybackEnd(PlayerPlaybackEndEvent(reason)))
    }

    fun noteStall(kind: MediaFrameKind, stalled: Boolean) {
        val now = clock()
        val rebufferChanged: Boolean
        val changed = synchronized(lock) {
            val state = stallState(kind)
            if (state.active == stalled) {
                return
            }
            if (stalled) state.start(now) else state.end(now)
            rebufferChanged = kind == rebufferKind && rebuffering != stalled
            if (rebufferChanged) rebuffering = stalled
            true
        }
        if (!changed) return

        val track = trackEvent(kind)
        events.emit(
            if (stalled) {
                PlayerEventType.TrackStallStart(track)
            } else {
                PlayerEventType.TrackStallEnd(track)
            },
        )
        if (rebufferChanged) {
            events.emit(
                if (stalled) {
                    PlayerEventType.RebufferStart(track)
                } else {
                    PlayerEventType.RebufferEnd(track)
                },
            )
        }
    }

    fun armAudioPlaybackStart(context: PlaybackStartContext) {
        synchronized(lock) {
            pendingAudioPlaybackStart = context
        }
    }

    fun disarmAudioPlaybackStart() {
        synchronized(lock) {
            pendingAudioPlaybackStart = null
        }
    }

    fun audioPlaybackStarted(timestampUs: Long, hostTime: Long?) {
        val context = synchronized(lock) {
            val pending = pendingAudioPlaybackStart ?: return
            if (timestampUs < pending.sourceTimestampUs) return
            pendingAudioPlaybackStart = null
            pending
        }
        emitTrackPlaying(
            context = context,
            output = PlayerTrackPlaybackOutput.Audio(
                PlayerAudioPlaybackOutput(
                    timestampUs = timestampUs,
                    hostTime = hostTime,
                ),
            ),
        )
    }

    fun videoPlaybackStarted(
        context: PlaybackStartContext,
        presentationTimeUs: Long,
        clockTimeUs: Long,
        buffer: Duration,
    ) {
        emitTrackPlaying(
            context = context,
            output = PlayerTrackPlaybackOutput.Video(
                PlayerVideoPlaybackOutput(
                    presentationTimeUs = presentationTimeUs,
                    clockTimeUs = clockTimeUs,
                    buffer = buffer,
                ),
            ),
        )
    }

    fun recordVideoFrameDisplayed() {
        val now = clock()
        synchronized(lock) {
            videoFrameTimestamps.add(now)
            pruneTimestamps(videoFrameTimestamps, now)
        }
    }

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

    fun recordVideoDecodeTime(trackName: String, durationNs: Long, outputAtNs: Long = clock()) {
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
                    videoDecodeMinOutputIntervalNs = minOf(videoDecodeMinOutputIntervalNs, intervalNs)
                    videoDecodeMaxOutputIntervalNs = maxOf(videoDecodeMaxOutputIntervalNs, intervalNs)
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

    fun snapshot(
        audioLatency: Duration?,
        videoLatency: Duration?,
        audioRingBuffer: Duration? = null,
        videoJitterBuffer: Duration? = null,
        videoDecodeStatsEnabled: Boolean = true,
    ): PlaybackStats {
        val now = clock()
        synchronized(lock) {
            return makeStatsLocked(
                audioLatency = audioLatency,
                videoLatency = videoLatency,
                audioRingBuffer = audioRingBuffer,
                videoJitterBuffer = videoJitterBuffer,
                videoDecodeStatsEnabled = videoDecodeStatsEnabled,
                now = now,
            )
        }
    }

    fun reset() {
        synchronized(lock) {
            playStartNs = 0L
            firstAudioFrameNs = 0L
            firstVideoFrameNs = 0L
            firstAudioPlayingNs = 0L
            firstVideoPlayingNs = 0L
            rebufferKind = null
            rebuffering = false
            playbackStartEmitted = false
            audioStalls.reset()
            videoStalls.reset()
            audioSwitches.reset()
            videoSwitches.reset()
            audioBytesWindow.clear()
            audioBytesTotal = 0
            videoBytesWindow.clear()
            videoBytesTotal = 0
            videoFrameTimestamps.clear()
            audioArrival.resetAll()
            videoArrival.resetAll()
            audioFramesDroppedCount = 0
            videoFramesDroppedCount = 0
            pendingAudioPlaybackStart = null
            resetVideoDecodeStatsLocked(null)
        }
    }

    override fun onMediaTrackStarted(kind: MediaFrameKind) {
        synchronized(lock) {
            when (kind) {
                MediaFrameKind.AUDIO -> audioArrival.resetTimingBaseline()
                MediaFrameKind.VIDEO -> videoArrival.resetTimingBaseline()
            }
        }
    }

    override fun onMediaFrame(frame: MoqFrame, kind: MediaFrameKind) {
        val now = clock()
        val timestampUs = frame.timestampUs.toLong()
        val payloadSize = frame.payload.size
        synchronized(lock) {
            when (kind) {
                MediaFrameKind.AUDIO -> {
                    audioBytesWindow.add(now to payloadSize)
                    audioBytesTotal += payloadSize
                    pruneWindow(audioBytesWindow, now) { audioBytesTotal -= it }
                    recordArrival(timestampUs, now, audioArrival)
                }
                MediaFrameKind.VIDEO -> {
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
                    audioArrival.maxDiscontinuityGapMs = maxOf(audioArrival.maxDiscontinuityGapMs, gapMs)
                    audioArrival.resetTimingBaseline()
                }
                MediaFrameKind.VIDEO -> {
                    videoArrival.discontinuityCount++
                    videoArrival.maxDiscontinuityGapMs = maxOf(videoArrival.maxDiscontinuityGapMs, gapMs)
                    videoArrival.resetTimingBaseline()
                }
            }
        }
    }

    private fun emitTrackPlaying(context: PlaybackStartContext, output: PlayerTrackPlaybackOutput) {
        val playing = PlayerTrackPlayingEvent(
            track = trackEvent(context.kind, context.trackName, context.trackEpoch),
            sourceTimestampUs = context.sourceTimestampUs,
            targetBuffering = context.targetBuffering,
            output = output,
        )
        events.emit(PlayerEventType.TrackPlaying(playing))

        val shouldEmitPlaybackStart = synchronized(lock) {
            val now = clock()
            stallState(context.kind).markReady(now)
            if (context.trackEpoch == 1L) {
                when (context.kind) {
                    MediaFrameKind.AUDIO -> if (firstAudioPlayingNs == 0L) firstAudioPlayingNs = now
                    MediaFrameKind.VIDEO -> if (firstVideoPlayingNs == 0L) firstVideoPlayingNs = now
                }
                if (!playbackStartEmitted && context.kind == rebufferKind) {
                    playbackStartEmitted = true
                    true
                } else {
                    false
                }
            } else {
                switchState(context.kind).markPlaying(now)
                false
            }
        }
        if (shouldEmitPlaybackStart) {
            events.emit(PlayerEventType.PlaybackStart(playing))
        }
    }

    private fun makeStatsLocked(
        audioLatency: Duration?,
        videoLatency: Duration?,
        audioRingBuffer: Duration?,
        videoJitterBuffer: Duration?,
        videoDecodeStatsEnabled: Boolean,
        now: Long,
    ): PlaybackStats =
        PlaybackStats(
            audioLatency = audioLatency,
            videoLatency = videoLatency,
            audioStalls = audioStalls.stats(now),
            videoStalls = videoStalls.stats(now),
            audioBitrateKbps = computeBitrateKbps(audioBytesWindow, audioBytesTotal, now),
            videoBitrateKbps = computeBitrateKbps(videoBytesWindow, videoBytesTotal, now),
            timeToFirst = TimeToFirstPlaybackStats(
                audioFrame = durationSincePlayStart(firstAudioFrameNs),
                videoFrame = durationSincePlayStart(firstVideoFrameNs),
                audioPlaying = durationSincePlayStart(firstAudioPlayingNs),
                videoPlaying = durationSincePlayStart(firstVideoPlayingNs),
            ),
            videoFps = computeFps(videoFrameTimestamps, now),
            audioFramesDropped = audioFramesDroppedCount.takeIf { it > 0L },
            videoFramesDropped = videoFramesDroppedCount.takeIf { it > 0L },
            audioRingBuffer = audioRingBuffer,
            videoJitterBuffer = videoJitterBuffer,
            audioArrival = makeFrameArrivalStats(audioArrival, now),
            videoArrival = makeFrameArrivalStats(videoArrival, now),
            audioSwitches = audioSwitches.stats(),
            videoSwitches = videoSwitches.stats(),
            videoDecodeStats = if (videoDecodeStatsEnabled) makeVideoDecodeStats() else null,
        )

    private fun durationSincePlayStart(endNs: Long): Duration? {
        if (playStartNs == 0L || endNs == 0L) return null
        return durationFromNanoseconds((endNs - playStartNs).coerceAtLeast(0L))
    }

    private fun resetVideoDecodeStatsLocked(trackName: String?) {
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
                        state.slowArrivalCount++
                    } else if (wallDeltaMs < ptsDeltaMs * BURST_FACTOR) {
                        state.fastArrivalCount++
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
        return VideoDecodeStats(
            trackName = trackName,
            sampleCount = videoDecodeSampleCount,
            min = durationFromNanoseconds(if (videoDecodeSampleCount > 0L) videoDecodeMinNs else 0L),
            max = durationFromNanoseconds(if (videoDecodeSampleCount > 0L) videoDecodeMaxNs else 0L),
            average = durationFromNanoseconds(
                if (videoDecodeSampleCount > 0L) {
                    videoDecodeTotalNs / videoDecodeSampleCount
                } else {
                    0L
                },
            ),
            last = durationFromNanoseconds(if (videoDecodeSampleCount > 0L) videoDecodeLastNs else 0L),
            inFlightBufferCount = videoDecodeInFlightBufferCount,
            minOutputInterval = if (videoDecodeOutputIntervalCount > 0L) {
                durationFromNanoseconds(videoDecodeMinOutputIntervalNs)
            } else null,
            averageOutputInterval = if (videoDecodeOutputIntervalCount > 0L) {
                durationFromNanoseconds(videoDecodeTotalOutputIntervalNs / videoDecodeOutputIntervalCount)
            } else null,
            maxOutputInterval = if (videoDecodeOutputIntervalCount > 0L) {
                durationFromNanoseconds(videoDecodeMaxOutputIntervalNs)
            } else null,
        )
    }

    private inline fun pruneWindow(entries: MutableList<Pair<Long, Int>>, now: Long, onRemove: (Int) -> Unit) {
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

    private fun computeBitrateKbps(entries: List<Pair<Long, Int>>, total: Int, now: Long): Double? {
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

    private fun makeFrameArrivalStats(state: FrameArrivalState, now: Long): FrameArrivalStats? {
        if (!state.hasData) return null
        val averageInterarrivalMs = if (state.intervalsWindow.isNotEmpty()) {
            state.intervalMsTotal / state.intervalsWindow.size.toDouble()
        } else null
        return FrameArrivalStats(
            receivedFramesPerSecond = computeFps(state.frameTimestamps, now),
            averageInterarrival = durationFromMilliseconds(averageInterarrivalMs),
            maxInterarrival = durationFromMilliseconds(state.intervalsWindow.maxOfOrNull { it.ms }),
            slowArrivalCount = state.slowArrivalCount,
            fastArrivalCount = state.fastArrivalCount,
            outOfOrderCount = state.outOfOrderCount,
            maxOutOfOrderDelta = durationFromMilliseconds(state.maxOutOfOrderDeltaMs.takeIf { it > 0.0 }),
            discontinuityCount = state.discontinuityCount,
            maxDiscontinuityGap = durationFromMilliseconds(state.maxDiscontinuityGapMs.takeIf { it > 0.0 }),
        )
    }

    private fun trackEvent(kind: MediaFrameKind, trackName: String? = null, trackEpoch: Long = 0L): PlayerTrackEvent =
        PlayerTrackEvent(kind = kind.playerTrackKind, trackName = trackName, epoch = trackEpoch)

    private fun stallState(kind: MediaFrameKind): StallState =
        when (kind) {
            MediaFrameKind.AUDIO -> audioStalls
            MediaFrameKind.VIDEO -> videoStalls
        }

    private fun switchState(kind: MediaFrameKind): SwitchState =
        when (kind) {
            MediaFrameKind.AUDIO -> audioSwitches
            MediaFrameKind.VIDEO -> videoSwitches
        }

    private fun StallState.reset() {
        readyAtNs = 0L
        count = 0L
        activeStartNs = 0L
        totalNs = 0L
        active = false
    }

    private fun SwitchState.reset() {
        requestedCount = 0L
        completedCount = 0L
        latestAttempt = null
        countedLatestCompletion = false
    }
}

internal val MediaFrameKind.playerTrackKind: PlayerTrackKind
    get() = when (this) {
        MediaFrameKind.AUDIO -> PlayerTrackKind.AUDIO
        MediaFrameKind.VIDEO -> PlayerTrackKind.VIDEO
    }
