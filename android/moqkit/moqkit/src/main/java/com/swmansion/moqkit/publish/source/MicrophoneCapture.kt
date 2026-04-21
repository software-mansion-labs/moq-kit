package com.swmansion.moqkit.publish.source

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.Log

private const val TAG = "MicrophoneCapture"

class MicrophoneCapture(
    private val sampleRate: Int = 48_000,
    private val channels: Int = 1,
) : AudioFrameSource {

    override var onPcmData: ((data: ByteArray, size: Int, timestampUs: Long) -> Unit)? = null

    private var record: AudioRecord? = null
    private var recordThread: Thread? = null
    @Volatile private var running = false

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
