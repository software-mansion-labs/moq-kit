package com.swmansion.moqkit

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import uniffi.moq.FrameData
import uniffi.moq.MoqBroadcast

fun subscribeTrack(
    broadcast: MoqBroadcast,
    name: String,
    maxLatencyMs: ULong = 1000u,
): Flow<FrameData> = flow {
    val track = broadcast.subscribeTrack(name, maxLatencyMs)
    try {
        while (true) {
            val frame = track.next() ?: break
            emit(frame)
        }
    } finally {
        track.unsubscribe()
    }
}.flowOn(Dispatchers.IO)
