package com.swmansion.moqkit

import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
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
    val callback = object : FrameCallback {
        override fun onFrame(frameId: UInt) {
            try {
                trySend(moqConsumeFrame(frameId))
            } catch (_: MoqException) {
            } finally {
                try { moqConsumeFrameClose(frameId) } catch (_: MoqException) {}
            }
        }
    }
    val trackHandle = moqConsumeVideoOrdered(broadcastHandle, index, maxLatencyMs, callback)
    awaitClose { try { moqConsumeVideoClose(trackHandle) } catch (_: MoqException) {} }
}

fun subscribeAudioTrack(
    broadcastHandle: UInt,
    index: UInt,
    maxLatencyMs: ULong = 1000u,
): Flow<FrameData> = callbackFlow {
    val callback = object : FrameCallback {
        override fun onFrame(frameId: UInt) {
            try {
                trySend(moqConsumeFrame(frameId))
            } catch (_: MoqException) {
            } finally {
                try { moqConsumeFrameClose(frameId) } catch (_: MoqException) {}
            }
        }
    }
    val trackHandle = moqConsumeAudioOrdered(broadcastHandle, index, maxLatencyMs, callback)
    awaitClose { try { moqConsumeAudioClose(trackHandle) } catch (_: MoqException) {} }
}
