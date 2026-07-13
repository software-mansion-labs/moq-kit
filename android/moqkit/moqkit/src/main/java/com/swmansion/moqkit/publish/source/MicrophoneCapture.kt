package com.swmansion.moqkit.publish.source

import android.Manifest
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.MediaRecorder
import android.util.Log
import androidx.annotation.RequiresPermission
import com.swmansion.moqkit.publish.encoder.AudioEncoderConfig

private const val TAG = "MicrophoneCapture"

internal class AudioCaptureTimestampTracker(
    private val sampleRate: Int,
    private val monotonicTimeNs: () -> Long = System::nanoTime,
) {
    private var deliveredFrames = 0L

    fun timestampUs(
        framesRead: Int,
        anchorFramePosition: Long?,
        anchorTimeNs: Long?,
    ): Long {
        val firstFrameNs = if (anchorFramePosition != null && anchorTimeNs != null) {
            val frameDelta = deliveredFrames - anchorFramePosition
            anchorTimeNs + frameDelta * 1_000_000_000L / sampleRate
        } else {
            monotonicTimeNs() - framesRead.toLong() * 1_000_000_000L / sampleRate
        }
        deliveredFrames += framesRead
        return firstFrameNs / 1_000L
    }
}

/**
 * Pulls PCM frames from the device microphone.
 *
 * Calling apps must both request and declare `RECORD_AUDIO` in their own manifest. The moqkit
 * library does not add that permission transitively.
 *
 * @param sampleRate Samples per second. Use the same value in [AudioEncoderConfig].
 * @param channels Channel count. `1` is mono, `2` is stereo.
 */
class MicrophoneCapture(
    private val sampleRate: Int = 48_000,
    private val channels: Int = 1,
) : AudioFrameSource {

    /**
     * Callback used by [com.swmansion.moqkit.publish.Publisher] to receive microphone PCM.
     *
     * Apps using [MicrophoneCapture] directly should not set this manually.
     */
    override var onPcmData: ((data: ByteArray, size: Int, timestampUs: Long) -> Unit)? = null

    private var record: AudioRecord? = null
    private var recordThread: Thread? = null
    @Volatile private var running = false

    /**
     * Starts microphone capture.
     *
     * Requires `RECORD_AUDIO` permission. If Android cannot initialize the microphone, the
     * call returns without producing audio.
     */
    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    fun start() {
        val channelConfig = if (channels == 1) AudioFormat.CHANNEL_IN_MONO else AudioFormat.CHANNEL_IN_STEREO
        val minBufSize = AudioRecord.getMinBufferSize(
            sampleRate, channelConfig, AudioFormat.ENCODING_PCM_16BIT
        )
        val bufSize = maxOf(minBufSize * 2, 4096)

        val newRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            channelConfig,
            AudioFormat.ENCODING_PCM_16BIT,
            bufSize,
        )

        if (newRecord.state != AudioRecord.STATE_INITIALIZED) {
            newRecord.release()
            Log.e(TAG, "AudioRecord initialization failed")
            return
        }

        record = newRecord
        running = true
        newRecord.startRecording()

        val buf = ByteArray(bufSize)
        recordThread = Thread {
            val timestamp = AudioTimestamp()
            val timestampTracker = AudioCaptureTimestampTracker(sampleRate)
            val bytesPerFrame = channels * 2
            while (running) {
                val read = newRecord.read(buf, 0, buf.size)
                if (read > 0) {
                    val framesRead = read / bytesPerFrame
                    val hasHardwareTimestamp =
                        newRecord.getTimestamp(timestamp, AudioTimestamp.TIMEBASE_MONOTONIC) ==
                            AudioRecord.SUCCESS
                    val timestampUs = timestampTracker.timestampUs(
                        framesRead = framesRead,
                        anchorFramePosition = timestamp.framePosition.takeIf { hasHardwareTimestamp },
                        anchorTimeNs = timestamp.nanoTime.takeIf { hasHardwareTimestamp },
                    )
                    onPcmData?.invoke(buf, read, timestampUs)
                }
            }
        }.apply {
            name = "MicCapture"
            isDaemon = true
            start()
        }
    }

    /**
     * Stops microphone capture and releases the underlying [AudioRecord].
     */
    fun stop() {
        running = false
        onPcmData = null
        recordThread?.interrupt()
        recordThread = null
        try {
            record?.stop()
            record?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping AudioRecord: $e")
        }
        record = null
    }
}
