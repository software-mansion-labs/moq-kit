package com.swmansion.moqkit.subscribe.internal.playback

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Process
import android.util.Log
import uniffi.moq.MoqAudio
import java.time.Duration
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

private const val TAG = "AudioRenderer"

/**
 * Orchestrates AudioDecoder, AudioRingBuffer, AudioTrack, and a dedicated playback thread.
 *
 * Thread safety: ReentrantLock guards the ring buffer between the decoder callback thread
 * (writes) and the playback thread (reads).
 */
internal class AudioRenderer(
    private val config: MoqAudio,
    private val targetBuffering: Duration,
    private val metrics: PlaybackStatsTracker? = null,
    initialVolume: Float = 1f,
    clock: AudioDrivenClock = AudioDrivenClock(),
) {
    private val sampleRate = config.sampleRate.toInt()
    private val channels = config.channelCount.toInt()
    private val lock = ReentrantLock()
    internal val clock = clock

    private var ringBuffer = AudioRingBuffer(
        rate = sampleRate,
        channels = channels,
        latency = targetBuffering,
    )

    private var audioTrack: AudioTrack? = null
    private var decoder: AudioDecoder? = null
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

        // Build MediaFormat for the decoder
        val format = AudioMediaFormatFactory.from(config)
            ?: throw IllegalStateException("Unsupported audio codec: ${config.codec}")

        decoder = AudioDecoder(format) { pcmData, frameCount, timestampUs ->
            var readyContext: TrackReadyContext? = null
            lock.withLock {
                // Seed the audio clock from the first decoded frame.
                if (clock.currentTimeUs == 0L) {
                    clock.setCurrentTimeUs(timestampUs)
                }
                val discarded = ringBuffer.write(timestampUs, pcmData, frameCount)
                metrics?.recordAudioFramesDropped(discarded)
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
        decoder!!.start()

        // Start playback thread
        running = true
        playbackThread = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            track.play()
            Log.d(TAG, "Playback thread started")

            // ~10ms worth of frames for read chunks
            val chunkFrames = sampleRate / 100
            val chunkBuf = ShortArray(chunkFrames * channels)
            var wasStalled = true // start as stalled (no data yet)
            var everPlayed = false

            while (running) {
                val (framesRead, ts) = lock.withLock {
                    Pair(ringBuffer.read(chunkBuf, chunkFrames), ringBuffer.timestampUs)
                }

                if (framesRead > 0) {
                    if (wasStalled || !everPlayed) {
                        wasStalled = false
                        everPlayed = true
                        metrics?.noteStall(MediaFrameKind.AUDIO, stalled = false)
                    }
                    track.write(chunkBuf, 0, framesRead * channels)
                    clock.setCurrentTimeUs(ts)
                    metrics?.audioPlaybackStarted(ts, hostTime = null)
                } else {
                    if (!wasStalled && everPlayed) {
                        wasStalled = true
                        metrics?.noteStall(MediaFrameKind.AUDIO, stalled = true)
                    }
                    // Stalled — avoid busy-wait
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
        decoder?.submitFrame(payload, timestampUs)
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
            ringBuffer.resize(latency)
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
        lock.withLock {
            ringBuffer.reset()
            pendingReadyContext = null
        }
        metrics?.disarmAudioPlaybackStart()
        decoder?.flush()
        clock.reset()
    }

    fun stop() {
        Log.d(TAG, "Stopping AudioRenderer")
        running = false
        playbackThread?.join(1000)
        playbackThread = null

        decoder?.release()
        decoder = null

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
}
