package com.swmansion.moqkit

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import uniffi.moq.AnnounceCallback
import uniffi.moq.AnnouncedInfo
import uniffi.moq.MoqException
import uniffi.moq.moqOriginAnnounced
import uniffi.moq.moqOriginAnnouncedClose
import uniffi.moq.moqOriginAnnouncedInfo
import uniffi.moq.moqOriginClose
import uniffi.moq.moqOriginConsume
import uniffi.moq.moqOriginCreate
import uniffi.moq.moqOriginPublish

class MoQOrigin(val handle: UInt = moqOriginCreate()) : AutoCloseable {

    fun consume(path: String): UInt = moqOriginConsume(handle, path)
    fun publish(broadcast: UInt, path: String) = moqOriginPublish(handle, path, broadcast)

    /**
     * Emits AnnouncedInfo for each broadcast announced on this origin.
     * Flow is active until the collector cancels or the origin is closed.
     */
    fun announced(): Flow<AnnouncedInfo> = callbackFlow {
        val rawChannel = Channel<Int>(Channel.UNLIMITED)

        val callback = object : AnnounceCallback {
            override fun onAnnounce(announcedId: Int) {
                rawChannel.trySend(announcedId)
            }
        }

        val announcedHandle = moqOriginAnnounced(handle, callback)

        launch(Dispatchers.IO) {
            for (announcedId in rawChannel) {
                if (announcedId < 0) {
                    if (announcedId == -1) {
                        channel.close()
                    } else {
                        channel.close(MoQSessionException("Announce subscription closed with error code: $announcedId"))
                    }
                    break
                }
                try {
                    trySend(moqOriginAnnouncedInfo(announcedId.toUInt()))
                } catch (_: MoqException) {}
            }
        }

        awaitClose {
            rawChannel.close()
            moqOriginAnnouncedClose(announcedHandle)
        }
    }

    override fun close() { try { moqOriginClose(handle) } catch (_: MoqException) {} }
}
