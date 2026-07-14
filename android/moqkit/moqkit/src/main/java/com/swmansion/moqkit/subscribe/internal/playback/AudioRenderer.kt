package com.swmansion.moqkit.subscribe.internal.playback

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Process
import android.util.Log
import com.swmansion.moqkit.subscribe.DiscontinuityReason
import com.swmansion.moqkit.subscribe.MediaFrame
import com.swmansion.moqkit.subscribe.PipelineContext
import com.swmansion.moqkit.subscribe.PipelineEvent
import com.swmansion.moqkit.subscribe.PipelineMediaKind
import com.swmansion.moqkit.subscribe.internal.pipeline.AdmissionPolicy
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderEvent
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderRecoveryExecutor
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderRecoveryResult
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderSupervisor
import com.swmansion.moqkit.subscribe.internal.pipeline.MonotonicTimeSource
import com.swmansion.moqkit.subscribe.internal.pipeline.PcmRing
import com.swmansion.moqkit.subscribe.internal.pipeline.PipelineBus
import com.swmansion.moqkit.subscribe.internal.pipeline.PipelinePolicies
import com.swmansion.moqkit.subscribe.internal.pipeline.RecoveryAttempt
import com.swmansion.moqkit.subscribe.internal.pipeline.TimedFrame
import com.swmansion.moqkit.subscribe.internal.pipeline.TrackTimeline
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import uniffi.moq.MoqAudio
import java.time.Duration
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

private const val TAG = "AudioRenderer"

/**
 * Orchestrates a supervised AudioDecoder session, PcmRing, AudioTrack, and playback thread.
 *
 * Thread safety: ReentrantLock guards the ring buffer between the decoder callback thread
 * (writes) and the playback thread (reads).
 */
internal class AudioRenderer(
    private val trackName: String,
    private val config: MoqAudio,
    private val targetBuffering: Duration,
    private val timeline: TrackTimeline,
    private val metrics: PlaybackStatsTracker? = null,
    private val pipelineBus: PipelineBus? = null,
    private val onError: (Throwable) -> Unit = {},
    initialVolume: Float = 1f,
    clock: AudioDrivenClock = AudioDrivenClock(),
) {
    private val sampleRate = config.sampleRate.toInt()
    private val channels = config.channelCount.toInt()
    private val lock = ReentrantLock()
    private val decoderScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val decoderFormat = AudioMediaFormatFactory.from(config)
        ?: throw IllegalStateException("Unsupported audio codec: ${config.codec}")
    internal val clock = clock

    private var ringBuffer = PcmRing(
        sampleRate = sampleRate,
        channels = channels,
        policy = pcmPolicy(targetBuffering),
    )

    private var audioTrack: AudioTrack? = null
    private var decoderRecovery: DecoderRecoveryExecutor<AudioDecoder>? = null
    private var decoderEventsJob: Job? = null
    private val decoder: AudioDecoder?
        get() = decoderRecovery?.currentSession
    private var playbackThread: Thread? = null
    private var pendingReadyContext: TrackReadyContext? = null

    @Volatile
    private var volume = initialVolume.coerceIn(0f, 1f)

    @Volatile
    private var running = false

    val bufferFill: Duration get() = durationFromMilliseconds(
        lock.withLock {
            (ringBuffer.length.toDouble() / sampleRate) * 1000.0
        },
    ) ?: Duration.ZERO

    fun start() {
        Log.d(TAG, "Starting: ${sampleRate}Hz ${channels}ch, targetBuffering=${targetBuffering.toMillisecondsLongClamped()}ms")

        val channelMask = if (channels == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }

        val minBufSize = AudioTrack.getMinBufferSize(
            sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT
        )
        val bufferSize = minBufSize * 2

        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelMask)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build()
            )
            .setBufferSizeInBytes(bufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        audioTrack = track
        track.setVolume(volume)

        decoderRecovery = DecoderRecoveryExecutor(
            supervisor = DecoderSupervisor(PipelinePolicies.recovery, MonotonicTimeSource),
            createSession = ::createStartedDecoder,
            onRecovery = ::emitDecoderRecovery,
        )
        decoderRecovery!!.start()

        // Start playback thread
        running = true
        playbackThread = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            track.play()
            Log.d(TAG, "Playback thread started")

            // ~10ms worth of frames for read chunks
            val chunkFrames = sampleRate / 100
            val chunkBuf = ShortArray(chunkFrames * channels)

            while (running) {
                val (framesRead, ts) = lock.withLock {
                    Pair(ringBuffer.read(chunkBuf, chunkFrames), ringBuffer.timestampUs)
                }

                if (framesRead > 0) {
                    track.write(chunkBuf, 0, framesRead * channels)
                    clock.setCurrentTimeUs(ts)
                    metrics?.audioPlaybackStarted(ts, hostTime = null)
                } else {
                    Thread.sleep(5)
                }
            }

            track.stop()
            Log.d(TAG, "Playback thread stopped")
        }, "AudioPlayback")
        playbackThread!!.start()

        Log.d(TAG, "AudioRenderer started")
    }

    /** Submit a compressed audio frame for decoding. */
    fun submitFrame(payload: ByteArray, timestampUs: Long) {
        val accepted = decoder?.queueInput(
            TimedFrame(MediaFrame(payload, timestampUs, keyframe = false)),
        ) == true
        if (accepted) {
            pipelineBus?.emit(
                PipelineEvent.DecoderInputQueued(
                    context = diagnosticsContext(),
                    ptsUs = timestampUs,
                ),
            )
        } else {
            metrics?.recordAudioFramesDropped(1)
        }
    }

    fun expectPlaybackStart(context: TrackReadyContext) {
        lock.withLock {
            pendingReadyContext = context
        }
        metrics?.armAudioPlaybackStart(
            PlaybackStartContext(
                kind = context.kind,
                trackName = context.trackName,
                sourceTimestampUs = context.sourceTimestampUs,
                targetBuffering = context.targetBuffering,
                trackEpoch = context.trackEpoch,
            ),
        )
    }

    /** Update the target latency, resizing the ring buffer. */
    fun updateTargetLatency(latency: Duration) {
        lock.withLock {
            ringBuffer.resize(pcmPolicy(latency))
        }
    }

    /** Sets AudioTrack output volume, clamped to the 0.0-1.0 range. */
    fun setVolume(value: Float) {
        val clampedValue = value.coerceIn(0f, 1f)
        volume = clampedValue
        audioTrack?.setVolume(clampedValue)
    }

    /** Flush decoder and ring buffer (e.g. on discontinuity). */
    fun flush() {
        resetAudioPipelineState()
        try {
            decoder?.flush()
        } catch (error: Throwable) {
            recoverDecoder(error)
        }
    }

    private fun resetAudioPipelineState() {
        lock.withLock {
            ringBuffer.reset()
            pendingReadyContext = null
        }
        metrics?.disarmAudioPlaybackStart()
        clock.reset()
    }

    fun stop() {
        Log.d(TAG, "Stopping AudioRenderer")
        running = false
        playbackThread?.join(1000)
        playbackThread = null

        decoderEventsJob?.cancel()
        decoderEventsJob = null
        decoderRecovery?.release()
        decoderRecovery = null
        decoderScope.cancel()

        try {
            audioTrack?.release()
        } catch (_: Exception) {}
        audioTrack = null

        clock.reset()
        Log.d(TAG, "AudioRenderer stopped")
    }

    fun canAcceptConfig(newConfig: MoqAudio): Boolean =
        config.codec == newConfig.codec &&
            config.sampleRate == newConfig.sampleRate &&
            config.channelCount == newConfig.channelCount &&
            descriptionsMatch(config.description, newConfig.description)

    private fun descriptionsMatch(lhs: ByteArray?, rhs: ByteArray?): Boolean {
        if (lhs == null || rhs == null) return lhs === rhs
        return lhs.contentEquals(rhs)
    }

    private fun createStartedDecoder(): AudioDecoder {
        val session = AudioDecoder(decoderFormat)
        decoderEventsJob = decoderScope.launch {
            session.events().collect(::onDecoderEvent)
        }
        try {
            session.start()
        } catch (error: Throwable) {
            decoderEventsJob?.cancel()
            decoderEventsJob = null
            session.release()
            throw error
        }
        return session
    }

    private fun onDecoderEvent(event: DecoderEvent) {
        when (event) {
            DecoderEvent.InputAvailable,
            DecoderEvent.Reconfigured -> Unit
            is DecoderEvent.OutputReady -> {
                val output = event.handle as AudioPcmOutput
                onDecoded(output.samples, output.frameCount, event.timestampUs)
            }
            is DecoderEvent.Error -> recoverDecoder(event.throwable)
        }
    }

    private fun onDecoded(pcmData: ShortArray, frameCount: Int, timestampUs: Long) {
        pipelineBus?.emit(
            PipelineEvent.DecoderOutputReady(
                context = diagnosticsContext(),
                ptsUs = timestampUs,
            ),
        )
        var readyContext: TrackReadyContext? = null
        lock.withLock {
            if (clock.currentTimeUs == 0L) clock.setCurrentTimeUs(timestampUs)
            val result = ringBuffer.write(timestampUs, pcmData, frameCount)
            metrics?.recordAudioFramesDropped(result.rejectedOldFrames + result.evictedFrames)
            readyContext = pendingReadyContext
            pendingReadyContext = null
        }
        readyContext?.let { context ->
            metrics?.emitTrackReady(context)
            if (context.trackEpoch > 1L) {
                metrics?.emitTrackSwitch(MediaFrameKind.AUDIO, context.trackName, context.trackEpoch)
            }
        }
    }

    private fun recoverDecoder(error: Throwable) {
        val recovery = decoderRecovery ?: return
        val reset = timeline.requestReset()
        resetAudioPipelineState()
        pipelineBus?.emit(
            PipelineEvent.Discontinuity(
                context = diagnosticsContext(),
                epoch = reset.epoch,
                reason = DiscontinuityReason.LOCAL_RESET,
            ),
        )
        val result = recovery.recover(error)
        if (result is DecoderRecoveryResult.Failed) onError(result.error)
    }

    private fun emitDecoderRecovery(attempt: RecoveryAttempt) {
        pipelineBus?.emit(
            PipelineEvent.DecoderRecovery(
                context = diagnosticsContext(),
                attempt = attempt.attempt,
                step = attempt.step,
                trigger = attempt.trigger,
            ),
        )
    }

    private fun diagnosticsContext() = PipelineContext(
        trackId = trackName,
        mediaKind = PipelineMediaKind.AUDIO,
        timestampNanos = System.nanoTime(),
    )

    private fun pcmPolicy(latency: Duration): AdmissionPolicy {
        require(!latency.isNegative && !latency.isZero) { "invalid latency" }
        val durationUs = latency.toMicrosecondsLongClamped().coerceAtLeast(1L)
        val frames = kotlin.math.ceil(sampleRate.toDouble() * durationUs / 1_000_000.0)
            .coerceIn(1.0, Int.MAX_VALUE.toDouble())
            .toInt()
        val bytes = try {
            Math.multiplyExact(frames.toLong(), channels.toLong() * 2L)
        } catch (_: ArithmeticException) {
            Long.MAX_VALUE
        }
        return AdmissionPolicy(
            maxBytes = bytes,
            maxFrames = frames,
            maxDurationUs = durationUs,
            evictWholeGops = false,
            requireKeyframeAfterReset = false,
        )
    }
}
