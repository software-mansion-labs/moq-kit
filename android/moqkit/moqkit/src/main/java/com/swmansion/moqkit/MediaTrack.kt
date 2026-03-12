package com.swmansion.moqkit

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import uniffi.moq.FrameData
import uniffi.moq.MoqBroadcast

private const val TAG = "MediaTrack"

fun subscribeTrack(
    broadcast: MoqBroadcast,
    name: String,
    maxLatencyMs: ULong = 1000u,
): Flow<FrameData> = flow {
    var track: uniffi.moq.MoqTrack? = null
    try {
        Log.d(TAG, "Subscribing to track '$name' (maxLatencyMs=$maxLatencyMs)")
        track = broadcast.subscribeTrack(name, maxLatencyMs)
        Log.d(TAG, "Track '$name' subscribed successfully")
        while (true) {
            val frame = track.next() ?: break
            emit(frame)
        }
        Log.d(TAG, "Track '$name' stream ended")
    } catch (e: Exception) {
        Log.e(TAG, "Track '$name' error: $e")
        throw e
    } finally {
        Log.d(TAG, "Unsubscribing from track '$name'")
        track?.unsubscribe()
    }
}.flowOn(Dispatchers.IO)
