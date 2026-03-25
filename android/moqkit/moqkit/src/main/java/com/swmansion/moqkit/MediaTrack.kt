package com.swmansion.moqkit

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import uniffi.moq.MoqAudio
import uniffi.moq.MoqBroadcastConsumer
import uniffi.moq.MoqFrame
import uniffi.moq.MoqVideo

private const val TAG = "MediaTrack"

sealed class MoQMediaTrackConfig {
    data class Audio(val config: MoqAudio) : MoQMediaTrackConfig()
    data class Video(val config: MoqVideo) : MoQMediaTrackConfig()
}

fun subscribeTrack(
    broadcast: MoqBroadcastConsumer,
    name: String,
    config: MoQMediaTrackConfig,
    maxLatencyMs: ULong = 1000u,
): Flow<MoqFrame> = flow {
    var consumer: uniffi.moq.MoqMediaConsumer? = null
    try {
        Log.d(TAG, "Subscribing to track '$name' (maxLatencyMs=$maxLatencyMs)")
        consumer = when (config) {
            is MoQMediaTrackConfig.Audio -> broadcast.subscribeAudio(name, config.config, maxLatencyMs)
            is MoQMediaTrackConfig.Video -> broadcast.subscribeVideo(name, config.config, maxLatencyMs)
        }
        Log.d(TAG, "Track '$name' subscribed successfully")
        while (true) {
            val frame = consumer.next() ?: break
            emit(frame)
        }
        Log.d(TAG, "Track '$name' stream ended")
    } catch (e: Exception) {
        Log.e(TAG, "Track '$name' error: $e")
        throw e
    } finally {
        Log.d(TAG, "Unsubscribing from track '$name'")
        consumer?.cancel()
        consumer?.close()
    }
}.flowOn(Dispatchers.IO)
