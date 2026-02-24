package com.swmansion.moqkit

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.withContext
import uniffi.moq.MoqException
import uniffi.moq.SessionCallback
import uniffi.moq.moqSessionClose
import uniffi.moq.moqSessionConnect

class MoQTransport private constructor(
    private val sessionHandle: UInt,
    private val closedDeferred: CompletableDeferred<Unit>,
    val statusFlow: Flow<Int>,
) {
    /** Closes session and suspends until Rust fires the final non-zero onStatus callback. */
    suspend fun close() {
        try { moqSessionClose(sessionHandle) } catch (_: MoqException) {}
        closedDeferred.await()
    }

    companion object {
        suspend fun connect(
            url: String,
            publishOrigin: UInt = 0u,
            consumeOrigin: UInt = 0u,
        ): MoQTransport = withContext(Dispatchers.IO) {
            val statusChannel = Channel<Int>(Channel.UNLIMITED)
            val closedDeferred = CompletableDeferred<Unit>()

            val callback = object : SessionCallback {
                override fun onStatus(code: Int) {
                    statusChannel.trySend(code)
                    if (code != 0) {
                        statusChannel.close()
                        closedDeferred.complete(Unit)
                    }
                }
            }

            val handle = moqSessionConnect(url, publishOrigin, consumeOrigin, callback)

            val firstStatus = statusChannel.receive()
            if (firstStatus < 0) {
                closedDeferred.await()
                throw MoQTransportException(firstStatus, "Connection failed: $firstStatus")
            }

            MoQTransport(handle, closedDeferred, statusChannel.receiveAsFlow())
        }
    }
}
