package com.swmansion.moqkit

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import uniffi.moq.FrameCallback
import uniffi.moq.FrameData
import uniffi.moq.MoqException
import uniffi.moq.moqConsumeAudioClose
import uniffi.moq.moqConsumeAudioOrdered
import uniffi.moq.moqConsumeFrame
import uniffi.moq.moqConsumeFrameClose
import uniffi.moq.moqConsumeVideoClose
import uniffi.moq.moqConsumeVideoOrdered

fun subscribeVideoTrack(
    broadcastHandle: UInt,
    index: UInt,
    maxLatencyMs: ULong = 1000u,
): Flow<FrameData> = callbackFlow {
    val rawChannel = Channel<Int>(Channel.UNLIMITED)

    val callback = object : FrameCallback {
        override fun onFrame(frameId: Int) {
            rawChannel.trySend(frameId)
        }
    }

    val trackHandle = moqConsumeVideoOrdered(broadcastHandle, index, maxLatencyMs, callback)

    launch(Dispatchers.IO) {
        for (frameId in rawChannel) {
            if (frameId < 0) {
                if (frameId == -1) {
                    channel.close()
                } else {
                    channel.close(MoQSessionException("Video track closed with error code: $frameId"))
                }
                break
            }
            val id = frameId.toUInt()
            try {
                trySend(moqConsumeFrame(id))
            } catch (_: MoqException) {
            } finally {
                try { moqConsumeFrameClose(id) } catch (_: MoqException) {}
            }
        }
    }

    awaitClose {
        rawChannel.close()
        try { moqConsumeVideoClose(trackHandle) } catch (_: MoqException) {}
    }
}

fun subscribeAudioTrack(
    broadcastHandle: UInt,
    index: UInt,
    maxLatencyMs: ULong = 1000u,
): Flow<FrameData> = callbackFlow {
    val rawChannel = Channel<Int>(Channel.UNLIMITED)

    val callback = object : FrameCallback {
        override fun onFrame(frameId: Int) {
            rawChannel.trySend(frameId)
        }
    }

    val trackHandle = moqConsumeAudioOrdered(broadcastHandle, index, maxLatencyMs, callback)

    launch(Dispatchers.IO) {
        for (frameId in rawChannel) {
            if (frameId < 0) {
                if (frameId == -1) {
                    channel.close()
                } else {
                    channel.close(MoQSessionException("Audio track closed with error code: $frameId"))
                }
                break
            }
            val id = frameId.toUInt()
            try {
                trySend(moqConsumeFrame(id))
            } catch (_: MoqException) {
            } finally {
                try { moqConsumeFrameClose(id) } catch (_: MoqException) {}
            }
        }
    }

    awaitClose {
        rawChannel.close()
        try { moqConsumeAudioClose(trackHandle) } catch (_: MoqException) {}
    }
}
