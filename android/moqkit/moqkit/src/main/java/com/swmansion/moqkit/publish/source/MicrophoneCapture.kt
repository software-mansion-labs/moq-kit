package com.swmansion.moqkit.publish.source

import android.Manifest
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.Log
import androidx.annotation.RequiresPermission

private const val TAG = "MicrophoneCapture"

/**
 * Pulls PCM frames from the device microphone.
 *
 * Calling apps must both request and declare `RECORD_AUDIO` in their own manifest. The moqkit
 * library does not add that permission transitively.
 */
class MicrophoneCapture(
    private val sampleRate: Int = 48_000,
    private val channels: Int = 1,
) : AudioFrameSource {

    override var onPcmData: ((data: ByteArray, size: Int, timestampUs: Long) -> Unit)? = null

    private var record: AudioRecord? = null
    private var recordThread: Thread? = null
    @Volatile private var running = false

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
            while (running) {
                val read = newRecord.read(buf, 0, buf.size)
                if (read > 0) {
                    val timestampUs = SystemClock.elapsedRealtimeNanos() / 1_000L
                    onPcmData?.invoke(buf, read, timestampUs)
                }
            }
        }.apply {
            name = "MicCapture"
            isDaemon = true
            start()
        }
    }

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
