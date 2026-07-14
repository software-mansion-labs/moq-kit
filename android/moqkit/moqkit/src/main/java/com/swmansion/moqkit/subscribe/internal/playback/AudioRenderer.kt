package com.swmansion.moqkit.subscribe.internal.playback

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Process
import android.util.Log
import com.swmansion.moqkit.subscribe.DecoderFlushReason
import com.swmansion.moqkit.subscribe.DiscontinuityReason
import com.swmansion.moqkit.subscribe.DropReason
import com.swmansion.moqkit.subscribe.DropStage
import com.swmansion.moqkit.subscribe.MediaFrame
import com.swmansion.moqkit.subscribe.PipelineContext
import com.swmansion.moqkit.subscribe.PipelineEvent
import com.swmansion.moqkit.subscribe.PipelineMediaKind
import com.swmansion.moqkit.subscribe.RecoveryStep
import com.swmansion.moqkit.subscribe.internal.pipeline.AdmissionPolicy
import com.swmansion.moqkit.subscribe.internal.pipeline.AdmissionEffect
import com.swmansion.moqkit.subscribe.internal.pipeline.AdmissionRejectReason
import com.swmansion.moqkit.subscribe.internal.pipeline.AudioDeviceClockDriver
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderEvent
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderEventObserver
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderRecoveryExecutor
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderRecoveryResult
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderSupervisor
import com.swmansion.moqkit.subscribe.internal.pipeline.FrameBuffer
import com.swmansion.moqkit.subscribe.internal.pipeline.MonotonicTimeSource
import com.swmansion.moqkit.subscribe.internal.pipeline.PcmRing
import com.swmansion.moqkit.subscribe.internal.pipeline.PipelineBus
import com.swmansion.moqkit.subscribe.internal.pipeline.PipelinePolicies
import com.swmansion.moqkit.subscribe.internal.pipeline.PlaybackClock
import com.swmansion.moqkit.subscribe.internal.pipeline.RecoveryAttempt
import com.swmansion.moqkit.subscribe.internal.pipeline.TimedFrame
import com.swmansion.moqkit.subscribe.internal.pipeline.TimelineResetReason
import com.swmansion.moqkit.subscribe.internal.pipeline.TrackTimeline
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
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
    private val trackEpoch: Long,
    private val config: MoqAudio,
    private val targetBuffering: Duration,
    private val timeline: TrackTimeline,
    private val metrics: PlaybackStatsTracker? = null,
    private val pipelineBus: PipelineBus? = null,
    private val onError: (Throwable) -> Unit = {},
    initialVolume: Float = 1f,
    private val clock: PlaybackClock,
) {
    private val sampleRate = config.sampleRate.toInt()
    private val channels = config.channelCount.toInt()
    private val lock = ReentrantLock()
    private val decoderInputLock = Any()
    private val decoderScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val decoderEventObserver = DecoderEventObserver<AudioDecoder>(
        scope = decoderScope,
        onEvent = ::onDecoderEvent,
    )
    private val decoderFormat = AudioMediaFormatFactory.from(config)
        ?: throw IllegalStateException("Unsupported audio codec: ${config.codec}")
    private val audioClockDriver = AudioDeviceClockDriver(sampleRate) {
        audioTrack?.playbackHeadPosition?.toLong()
    }

    private var ringBuffer = PcmRing(
        sampleRate = sampleRate,
        channels = channels,
        policy = pcmPolicy(targetBuffering),
    )
    private val compressedInput = FrameBuffer(
        PipelinePolicies.admission.copy(
            evictWholeGops = false,
            requireKeyframeAfterReset = false,
        ),
    ).apply { reset(trackEpoch) }

    private var audioTrack: AudioTrack? = null
    private var decoderRecovery: DecoderRecoveryExecutor<AudioDecoder>? = null
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
        clock.attachAudioDriver(audioClockDriver)

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
            try {
                track.play()
                Log.d(TAG, "Playback thread started")

                // ~10ms worth of frames for read chunks
                val chunkFrames = sampleRate / 100
                val chunkBuf = ShortArray(chunkFrames * channels)

                while (running) {
                    val (framesRead, mediaEndUs) = lock.withLock {
                        Pair(ringBuffer.read(chunkBuf, chunkFrames), ringBuffer.timestampUs)
                    }

                    if (framesRead > 0) {
                        val mediaStartUs = subtractClamped(mediaEndUs, framesToUs(framesRead))
                        val totalSamples = framesRead * channels
                        var writtenSamples = 0
                        while (running && writtenSamples < totalSamples) {
                            val count = track.write(
                                chunkBuf,
                                writtenSamples,
                                totalSamples - writtenSamples,
                            )
                            check(count >= 0) { "AudioTrack write failed: $count" }
                            if (count == 0) {
                                Thread.sleep(1)
                                continue
                            }
                            val frameOffset = writtenSamples / channels
                            val writtenFrames = count / channels
                            audioClockDriver.onFramesWritten(
                                mediaStartUs = addClamped(mediaStartUs, framesToUs(frameOffset)),
                                frameCount = writtenFrames,
                            )
                            writtenSamples += count
                        }
                        val renderedFrames = writtenSamples / channels
                        val renderedEndUs = addClamped(mediaStartUs, framesToUs(renderedFrames))
                        metrics?.audioPlaybackStarted(renderedEndUs, hostTime = null)
                        pipelineBus?.emit(
                            PipelineEvent.FrameRendered(
                                context = diagnosticsContext(),
                                ptsUs = renderedEndUs,
                                renderNanos = System.nanoTime(),
                            ),
                        )
                    } else {
                        Thread.sleep(5)
                    }
                }
            } catch (error: Throwable) {
                if (running) onError(error)
            } finally {
                try {
                    track.stop()
                } catch (_: Throwable) {
                }
                Log.d(TAG, "Playback thread stopped")
            }
        }, "AudioPlayback")
        playbackThread!!.start()

        Log.d(TAG, "AudioRenderer started")
    }

    /** Submit a compressed audio frame for decoding. */
    fun submitFrame(payload: ByteArray, timestampUs: Long) {
        val frame = TimedFrame(
            mediaFrame = MediaFrame(payload, timestampUs, keyframe = false),
            epoch = trackEpoch,
        )
        val effects = synchronized(decoderInputLock) { compressedInput.offer(frame) }
        effects.forEach { effect ->
            when (effect) {
                is AdmissionEffect.Admitted -> pipelineBus?.emit(
                    PipelineEvent.FrameAdmitted(
                        context = diagnosticsContext(),
                        ptsUs = effect.frame.timestampUs,
                        bufferDepth = synchronized(decoderInputLock) { compressedInput.depth() },
                    ),
                )
                is AdmissionEffect.EvictedGop -> recordCompressedDrop(
                    reason = DropReason.BACKLOG_OVERFLOW,
                    count = effect.count,
                    bytes = effect.bytes,
                )
                is AdmissionEffect.Rejected -> recordCompressedDrop(
                    reason = effect.reason.toDropReason(),
                    count = 1,
                    bytes = effect.frame.sizeBytes.toLong(),
                    ptsUs = effect.frame.timestampUs,
                )
            }
        }
        drainDecoderInput()
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

    /** Flush decoder and ring buffer after a timeline discontinuity. */
    fun flush(reason: TimelineResetReason, gapUs: Long?) {
        val droppedFrames = resetAudioPipelineState()
        try {
            decoder?.let { session ->
                decoderEventObserver.flush(session)
                emitDecoderFlushed(
                    reason = DecoderFlushReason.TIMELINE_RESET,
                    trigger = buildTimelineResetTrigger(reason, gapUs),
                    droppedFrames = droppedFrames,
                )
            }
        } catch (error: Throwable) {
            recoverDecoder(error)
        }
    }

    private fun resetAudioPipelineState(): Int {
        val compressedFrames = synchronized(decoderInputLock) { compressedInput.reset(trackEpoch) }
        lock.withLock {
            ringBuffer.reset()
            pendingReadyContext = null
        }
        metrics?.disarmAudioPlaybackStart()
        if (compressedFrames > 0) {
            recordCompressedDrop(DropReason.RESET_FLUSH, compressedFrames)
        }
        return compressedFrames
    }

    fun stop() {
        Log.d(TAG, "Stopping AudioRenderer")
        running = false
        playbackThread?.takeIf { it !== Thread.currentThread() }?.join(1000)
        playbackThread = null

        decoderEventObserver.close()
        decoderRecovery?.release()
        decoderRecovery = null
        decoderScope.cancel()

        try {
            audioTrack?.release()
        } catch (_: Exception) {}
        audioTrack = null

        clock.detachAudioDriver()
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
        observeDecoderEvents(session)
        try {
            session.start()
        } catch (error: Throwable) {
            decoderEventObserver.close()
            session.release()
            throw error
        }
        return session
    }

    private fun observeDecoderEvents(session: AudioDecoder) {
        decoderEventObserver.observe(session)
    }

    private fun onDecoderEvent(session: AudioDecoder, event: DecoderEvent) {
        if (decoder != null && decoder !== session) return
        when (event) {
            DecoderEvent.InputAvailable -> drainDecoderInput()
            DecoderEvent.Reconfigured -> Unit
            is DecoderEvent.OutputReady -> {
                val handle = event.handle as AudioOutputHandle
                val output = handle.session.consumeOutput(handle) ?: return
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

    private fun drainDecoderInput() {
        val queued = mutableListOf<TimedFrame>()
        synchronized(decoderInputLock) {
            val session = decoder ?: return
            while (true) {
                val frame = compressedInput.peekFront() ?: break
                if (!session.queueInput(frame)) break
                compressedInput.removeFront()
                queued += frame
            }
        }
        queued.forEach { frame ->
            pipelineBus?.emit(
                PipelineEvent.DecoderInputQueued(
                    context = diagnosticsContext(),
                    ptsUs = frame.timestampUs,
                ),
            )
        }
        if (queued.isNotEmpty()) {
            pipelineBus?.emit(
                PipelineEvent.BufferDepthChanged(
                    context = diagnosticsContext(),
                    depth = synchronized(decoderInputLock) { compressedInput.depth() },
                ),
            )
        }
    }

    private fun recordCompressedDrop(
        reason: DropReason,
        count: Int,
        bytes: Long = 0L,
        ptsUs: Long? = null,
    ) {
        metrics?.recordAudioFramesDropped(count)
        pipelineBus?.emit(
            PipelineEvent.FrameDropped(
                context = diagnosticsContext(),
                stage = DropStage.BUFFER,
                reason = reason,
                ptsUs = ptsUs,
                count = count,
                bytes = bytes,
            ),
        )
    }

    private fun AdmissionRejectReason.toDropReason(): DropReason = when (this) {
        AdmissionRejectReason.WAITING_FOR_KEYFRAME -> DropReason.WAITING_FOR_KEYFRAME
        AdmissionRejectReason.FRAME_TOO_LARGE -> DropReason.BACKLOG_OVERFLOW
        AdmissionRejectReason.OLD_EPOCH,
        AdmissionRejectReason.UNEXPECTED_EPOCH -> DropReason.PUBLISHER_REWIND
        AdmissionRejectReason.DUPLICATE -> DropReason.COVERED
    }

    private fun recoverDecoder(error: Throwable) {
        val recovery = decoderRecovery ?: return
        val reset = timeline.requestReset()
        val droppedFrames = resetAudioPipelineState()
        pipelineBus?.emit(
            PipelineEvent.Discontinuity(
                context = diagnosticsContext(),
                epoch = reset.epoch,
                reason = DiscontinuityReason.LOCAL_RESET,
            ),
        )
        val result = recovery.recover(error)
        when (result) {
            is DecoderRecoveryResult.Recovered -> {
                observeDecoderEvents(result.session)
                if (result.attempt.step == RecoveryStep.FLUSH) {
                    emitDecoderFlushed(
                        reason = DecoderFlushReason.DECODER_RECOVERY,
                        trigger = result.attempt.trigger,
                        droppedFrames = droppedFrames,
                    )
                }
                drainDecoderInput()
            }
            is DecoderRecoveryResult.Failed -> {
                decoderEventObserver.close()
                onError(result.error)
            }
        }
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

    private fun emitDecoderFlushed(
        reason: DecoderFlushReason,
        trigger: String,
        droppedFrames: Int,
    ) {
        pipelineBus?.emit(
            PipelineEvent.DecoderFlushed(
                context = diagnosticsContext(),
                reason = reason,
                trigger = trigger,
                droppedFrames = droppedFrames,
            ),
        )
    }

    private fun buildTimelineResetTrigger(reason: TimelineResetReason, gapUs: Long?): String =
        if (gapUs == null) reason.name else "${reason.name} gapUs=$gapUs"

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

    private fun framesToUs(frames: Int): Long = try {
        Math.multiplyExact(frames.toLong(), 1_000_000L) / sampleRate
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }

    private fun addClamped(left: Long, right: Long): Long = try {
        Math.addExact(left, right)
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }

    private fun subtractClamped(left: Long, right: Long): Long = try {
        Math.subtractExact(left, right).coerceAtLeast(0L)
    } catch (_: ArithmeticException) {
        0L
    }
}
