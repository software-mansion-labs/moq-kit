package com.swmansion.moqkit

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaFormat
import android.os.Process
import android.util.Log
import uniffi.moq.MoqAudio
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
    private val targetLatencyMs: Int,
    private val metrics: PlaybackMetricsAccumulator? = null,
) {
    private val sampleRate = config.sampleRate.toInt()
    private val channels = config.channelCount.toInt()
    private val lock = ReentrantLock()
    internal val timebase = MediaTimebase()

    private var ringBuffer = AudioRingBuffer(
        rate = sampleRate,
        channels = channels,
        latencyMs = targetLatencyMs.toDouble(),
    )

    private var audioTrack: AudioTrack? = null
    private var decoder: AudioDecoder? = null
    private var playbackThread: Thread? = null

    @Volatile
    private var running = false

    /** PTS of the most recently submitted frame, in microseconds. */
    @Volatile
    var lastIngestPtsUs: Long = 0L
        private set

    /** Current playback time in microseconds, driven by AudioTrack head position. */
    val currentTimeUs: Long get() = timebase.currentTimeUs

    fun start() {
        Log.d(TAG, "Starting: ${sampleRate}Hz ${channels}ch, targetLatency=${targetLatencyMs}ms")

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

        // Build MediaFormat for the decoder
        val format = MediaFactory.makeAudioFormat(config)
            ?: throw IllegalStateException("Unsupported audio codec: ${config.codec}")

        decoder = AudioDecoder(format) { pcmData, frameCount, timestampUs ->
            lock.withLock {
                // Set timebase base on first decoded frame
                if (timebase.currentTimeUs == 0L) {
                    timebase.setBase(timestampUs, sampleRate)
                }
                ringBuffer.write(timestampUs, pcmData, frameCount)
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
                        metrics?.audioStallEnded()
                    }
                    track.write(chunkBuf, 0, framesRead * channels)
                    timebase.update(ts)
                } else {
                    if (!wasStalled && everPlayed) {
                        wasStalled = true
                        metrics?.audioStallBegan()
                    }
                    // Stalled — avoid busy-wait
                    Thread.sleep(5)
                }
            }

            track.stop()
            Log.d(TAG, "Playback thread stopped")
        }, "MoQ-AudioPlayback")
        playbackThread!!.start()

        Log.d(TAG, "AudioRenderer started")
    }

    /** Submit a compressed audio frame for decoding. */
    fun submitFrame(payload: ByteArray, timestampUs: Long) {
        lastIngestPtsUs = timestampUs
        decoder?.submitFrame(payload, timestampUs)
    }

    /** Update the target latency, resizing the ring buffer. */
    fun updateTargetLatency(ms: Int) {
        lock.withLock {
            ringBuffer.resize(ms.toDouble())
        }
    }

    /** Flush decoder and ring buffer (e.g. on discontinuity). */
    fun flush() {
        lock.withLock {
            ringBuffer.reset()
        }
        decoder?.flush()
        timebase.reset()
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

        timebase.reset()
        Log.d(TAG, "AudioRenderer stopped")
    }
}
