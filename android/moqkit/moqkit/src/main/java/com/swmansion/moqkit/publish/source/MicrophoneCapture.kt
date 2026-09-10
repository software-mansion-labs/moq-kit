package com.swmansion.moqkit.publish.source

import android.Manifest
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import androidx.annotation.RequiresPermission
import com.swmansion.moqkit.publish.encoder.AudioEncoderConfig

private const val TAG = "MicrophoneCapture"

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
    @Volatile override var onPcmData: ((data: ByteArray, size: Int, timestampUs: Long) -> Unit)? = null

    /** Mute sends silence while capture and publication stay active. */
    @Volatile var isMuted: Boolean = false
    val isCapturing: Boolean get() = captureLifecycle.snapshot.running

    private var record: AudioRecord? = null
    private var recordThread: Thread? = null
    private var recording: AtomicBoolean? = null
    internal val captureLifecycle = CaptureLifecycle()

    /**
     * Starts microphone capture.
     *
     * Requires `RECORD_AUDIO` permission. Startup failure throws and releases partial resources.
     */
    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    suspend fun start() {
        val caller = currentCoroutineContext()
        caller.ensureActive()
        var acquired = false
        try {
            PublishControl.run {
                caller.ensureActive()
                acquired = record == null
                startOwned()
            }
            caller.ensureActive()
        } catch (e: kotlinx.coroutines.CancellationException) {
            if (acquired) stop()
            throw e
        }
    }

    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    private fun startOwned() {
        check(!captureLifecycle.snapshot.closed) { "Capture is closed" }
        if (record != null) return
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
            error("AudioRecord initialization failed")
        }

        record = newRecord
        try {
            newRecord.startRecording()
            check(newRecord.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "Microphone did not start" }
            val running = AtomicBoolean(true)
            recording = running
            captureLifecycle.setRunning(true)
            val buf = ByteArray(bufSize)
            recordThread = Thread {
                while (running.get()) {
                    val read = newRecord.read(buf, 0, buf.size)
                    if (read > 0 && running.get()) {
                        val timestampUs = SystemClock.elapsedRealtimeNanos() / 1_000L
                        deliverPcm(buf, read, timestampUs)
                    } else if (read < 0 && running.get()) {
                        PublishControl.post { if (record === newRecord) stopOwned() }
                        break
                    }
                }
            }.apply {
                name = "MicCapture"
                isDaemon = true
                start()
            }
        } catch (e: Exception) {
            stopOwned()
            throw e
        }
    }

    internal fun deliverPcm(data: ByteArray, size: Int, timestampUs: Long) {
        if (isMuted) data.fill(0, 0, size)
        onPcmData?.invoke(data, size, timestampUs)
    }

    /**
     * Stops capture, releases [AudioRecord], and removes the publisher's media track.
     * Calling [start] on this instance resumes through the same logical publisher track.
     */
    suspend fun stop() = PublishControl.run { stopOwned() }

    suspend fun close() = PublishControl.run {
        stopOwned()
        captureLifecycle.close()
    }

    private fun stopOwned() {
        recording?.set(false)
        recording = null
        captureLifecycle.setRunning(false)
        val oldRecord = record
        val oldThread = recordThread
        record = null
        recordThread = null
        try {
            oldRecord?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping AudioRecord: $e")
        }
        if (oldThread !== Thread.currentThread()) {
            oldThread?.join()
        }
        oldRecord?.release()
    }
}
