@file:OptIn(UnstableApi::class)
package com.swmansion.moqkit

import android.net.Uri
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.TrackGroup
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.TransferListener
import androidx.media3.decoder.DecoderInputBuffer
import androidx.media3.exoplayer.FormatHolder
import androidx.media3.exoplayer.LoadingInfo
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.source.BaseMediaSource
import androidx.media3.exoplayer.source.MediaPeriod
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.SampleQueue
import androidx.media3.exoplayer.source.SampleStream
import androidx.media3.exoplayer.source.SinglePeriodTimeline
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.upstream.Allocator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import uniffi.moq.MoqFrame
import java.net.URI

internal class MoQMediaSource(
    private val videoFormat: Format?,
    private val audioFormat: Format?,
    private val videoFlow: Flow<MoqFrame>?,
    private val audioFlow: Flow<MoqFrame>?,
    private val scope: CoroutineScope,
) : BaseMediaSource() {
    companion object {
        private const val TAG = "MoQMediaSource"
    }

    private val timeline = SinglePeriodTimeline(
        /* durationUs= */ C.TIME_UNSET,
        /* isSeekable= */ false,
        /* isDynamic= */ true,
        /* isLive= */ true,
        /* manifest= */ null,
        MediaItem.fromUri(Uri.EMPTY),
    )

    override fun prepareSourceInternal(mediaTransferListener: TransferListener?) {
        Log.d(TAG, "prepareSourceInternal: video=${videoFormat != null} audio=${audioFormat != null}")
        refreshSourceInfo(timeline)
    }

    override fun getMediaItem(): MediaItem {
        return MediaItem.fromUri(Uri.EMPTY)
    }

    override fun maybeThrowSourceInfoRefreshError() {}

    override fun createPeriod(
        id: MediaSource.MediaPeriodId,
        allocator: Allocator,
        startPositionUs: Long,
    ): MediaPeriod {
        Log.d(TAG, "createPeriod: startPositionUs=$startPositionUs")
        return MoQMediaPeriod(allocator)
    }

    override fun releasePeriod(period: MediaPeriod) {
        Log.d(TAG, "releasePeriod")
        (period as MoQMediaPeriod).release()
    }

    override fun releaseSourceInternal() {
        Log.d(TAG, "releaseSourceInternal")
    }

    @UnstableApi inner class MoQMediaPeriod(allocator: Allocator) : MediaPeriod {

        private val videoQueue = videoFormat?.let { SampleQueue.createWithoutDrm(allocator) }
        private val audioQueue = audioFormat?.let { SampleQueue.createWithoutDrm(allocator) }
        private val videoStream = videoQueue?.let { SampleStreamImpl(it) }
        private val audioStream = audioQueue?.let { SampleStreamImpl(it) }

        private val trackGroups: TrackGroupArray = run {
            val groups = buildList {
                videoFormat?.let { add(TrackGroup("video", it)) }
                audioFormat?.let { add(TrackGroup("audio", it)) }
            }
            TrackGroupArray(*groups.toTypedArray())
        }

        private var loadingCallback: MediaPeriod.Callback? = null
        private var videoJob: Job? = null
        private var audioJob: Job? = null

        @Volatile private var firstVideoTimestampUs = -1L
        @Volatile private var firstAudioTimestampUs = -1L
        @Volatile private var commonBaseTimestampUs = -1L

        private fun updateCommonBaseIfReady() {
            if (commonBaseTimestampUs != -1L) return
            val v = firstVideoTimestampUs
            val a = firstAudioTimestampUs
            if (v != -1L && a != -1L) {
                synchronized(this) {
                    if (commonBaseTimestampUs == -1L && firstVideoTimestampUs != -1L && firstAudioTimestampUs != -1L) {
                        commonBaseTimestampUs = minOf(firstVideoTimestampUs, firstAudioTimestampUs)
                        Log.d(TAG, "Common base timestamp set: ${commonBaseTimestampUs}us (video=$firstVideoTimestampUs audio=$firstAudioTimestampUs)")
                    }
                }
            }
        }

        private fun getAdjustedVideoTimestampUs(rawTimestampUs: Long): Long {
            if (firstVideoTimestampUs == -1L) {
                synchronized(this) {
                    if (firstVideoTimestampUs == -1L) {
                        firstVideoTimestampUs = rawTimestampUs
                        Log.d(TAG, "First video timestamp: ${rawTimestampUs}us")
                    }
                }
                updateCommonBaseIfReady()
            }
            val base = if (commonBaseTimestampUs != -1L) commonBaseTimestampUs else firstVideoTimestampUs
            return rawTimestampUs - base
        }

        private fun getAdjustedAudioTimestampUs(rawTimestampUs: Long): Long {
            if (firstAudioTimestampUs == -1L) {
                synchronized(this) {
                    if (firstAudioTimestampUs == -1L) {
                        firstAudioTimestampUs = rawTimestampUs
                        Log.d(TAG, "First audio timestamp: ${rawTimestampUs}us")
                    }
                }
                updateCommonBaseIfReady()
            }
            val base = if (commonBaseTimestampUs != -1L) commonBaseTimestampUs else firstAudioTimestampUs
            return rawTimestampUs - base
        }

        override fun prepare(callback: MediaPeriod.Callback, positionUs: Long) {
            Log.d(TAG, "Period prepare: positionUs=$positionUs video=${videoFormat != null} audio=${audioFormat != null}")
            loadingCallback = callback
            videoFormat?.let { videoQueue?.format(it) }
            audioFormat?.let { audioQueue?.format(it) }

            videoJob = scope.launch(Dispatchers.IO) {
                Log.d(TAG, "Video flow collection started")
                try {
                    videoFlow?.collect { frame ->
                        val annexB = frame.payload.avccToAnnexB()
                        val pba = ParsableByteArray(annexB)
                        videoQueue?.sampleData(pba, annexB.size)
                        val flags = if (frame.keyframe) C.BUFFER_FLAG_KEY_FRAME else 0
                        val adjustedTimestamp = getAdjustedVideoTimestampUs(frame.timestampUs.toLong())
                        videoQueue?.sampleMetadata(
                            adjustedTimestamp,
                            flags,
                            annexB.size,
                            0,
                            null
                        )
                        loadingCallback?.onContinueLoadingRequested(this@MoQMediaPeriod)
                    }
                    Log.d(TAG, "Video flow ended normally")
                } catch (e: Exception) {
                    Log.e(TAG, "Video flow error: $e")
                }
            }

            audioJob = scope.launch(Dispatchers.IO) {
                Log.d(TAG, "Audio flow collection started")
                try {
                    audioFlow?.collect { frame ->
                        val pba = ParsableByteArray(frame.payload)
                        audioQueue?.sampleData(pba, frame.payload.size)
                        val adjustedTimestamp = getAdjustedAudioTimestampUs(frame.timestampUs.toLong())
                        // Log.d("MoQMediaSource", "Audio frame: raw=${frame.timestampUs} adj=$adjustedTimestamp size=${frame.payload.size}")
                        audioQueue?.sampleMetadata(
                            adjustedTimestamp,
                            C.BUFFER_FLAG_KEY_FRAME,
                            frame.payload.size,
                            0,
                            null
                        )
                        loadingCallback?.onContinueLoadingRequested(this@MoQMediaPeriod)
                    }
                    Log.d(TAG, "Audio flow ended normally")
                } catch (e: Exception) {
                    Log.e(TAG, "Audio flow error: $e")
                }
            }

            callback.onPrepared(this)
            Log.d(TAG, "Period prepared, ${trackGroups.length} track groups")
        }

        override fun selectTracks(
            selections: Array<out ExoTrackSelection?>,
            mayRetainStreamFlags: BooleanArray,
            streams: Array<SampleStream?>,
            streamResetFlags: BooleanArray,
            positionUs: Long,
        ): Long {
            for (i in selections.indices) {
                val selection = selections[i]
                if (selection == null) {
                    streams[i] = null
                    continue
                }

                val group = selection.trackGroup
                if (videoFormat != null && group == trackGroups[0]) {
                    if (streams[i] == null || !mayRetainStreamFlags[i]) {
                        streams[i] = videoStream
                        streamResetFlags[i] = true
                    }
                } else if (audioFormat != null && group == trackGroups[if (videoFormat != null) 1 else 0]) {
                    if (streams[i] == null || !mayRetainStreamFlags[i]) {
                        streams[i] = audioStream
                        streamResetFlags[i] = true
                    }
                }
            }
            return positionUs
        }

        override fun getTrackGroups(): TrackGroupArray = trackGroups

        override fun getBufferedPositionUs(): Long {
            var minBufferedUs = Long.MAX_VALUE
            var hasAnyTrack = false
            videoQueue?.let {
                val timestamp = it.largestQueuedTimestampUs
                if (timestamp != Long.MIN_VALUE) {
                    minBufferedUs = minOf(minBufferedUs, timestamp)
                    hasAnyTrack = true
                } else {
                    return 0L // Missing data for video
                }
            }
            audioQueue?.let {
                val timestamp = it.largestQueuedTimestampUs
                if (timestamp != Long.MIN_VALUE) {
                    minBufferedUs = minOf(minBufferedUs, timestamp)
                    hasAnyTrack = true
                }
                // If audio queue is empty, omit it from the min until the first frame arrives
            }
            return if (hasAnyTrack) minBufferedUs else 0L
        }

        override fun getNextLoadPositionUs(): Long {
            var maxBufferedUs = Long.MIN_VALUE
            videoQueue?.let {
                maxBufferedUs = maxOf(maxBufferedUs, it.largestQueuedTimestampUs)
            }
            audioQueue?.let {
                maxBufferedUs = maxOf(maxBufferedUs, it.largestQueuedTimestampUs)
            }
            return if (maxBufferedUs == Long.MIN_VALUE) 0L else maxBufferedUs
        }

        override fun continueLoading(loadingInfo: LoadingInfo): Boolean = true

        override fun isLoading(): Boolean =
            videoJob?.isActive == true || audioJob?.isActive == true

        override fun seekToUs(positionUs: Long): Long = positionUs

        override fun getAdjustedSeekPositionUs(
            positionUs: Long,
            seekParameters: SeekParameters
        ): Long = positionUs

        override fun discardBuffer(positionUs: Long, toKeyframe: Boolean) {}
        override fun readDiscontinuity(): Long = C.TIME_UNSET

        override fun maybeThrowPrepareError() {}

        override fun reevaluateBuffer(positionUs: Long) {}

        fun release() {
            Log.d(TAG, "Period release: cancelling video=${videoJob != null} audio=${audioJob != null}")
            videoJob?.cancel()
            audioJob?.cancel()
            videoQueue?.release()
            audioQueue?.release()
        }
    }

    @UnstableApi private inner class SampleStreamImpl(private val queue: SampleQueue) : SampleStream {

        override fun isReady(): Boolean = queue.isReady(/* loadingFinished= */ false)

        override fun maybeThrowError() {}

        @androidx.annotation.OptIn(UnstableApi::class) override fun readData(
            formatHolder: FormatHolder,
            buffer: DecoderInputBuffer,
            readFlags: Int,
        ): Int = queue.read(formatHolder, buffer, readFlags, false)

        override fun skipData(positionUs: Long): Int  {
            val toSkip = queue.getSkipCount(positionUs, /* allowEndOfQueue= */ false)
            queue.skip(toSkip)
            return toSkip
        }
    }
}
