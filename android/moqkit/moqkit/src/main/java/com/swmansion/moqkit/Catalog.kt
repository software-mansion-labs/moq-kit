package com.swmansion.moqkit

import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import uniffi.moq.AudioConfig
import uniffi.moq.CatalogCallback
import uniffi.moq.MoqException
import uniffi.moq.VideoConfig
import uniffi.moq.moqConsumeAudioConfig
import uniffi.moq.moqConsumeCatalog
import uniffi.moq.moqConsumeCatalogClose
import uniffi.moq.moqConsumeClose
import uniffi.moq.moqConsumeVideoConfig

// MARK: - Track Info Types

interface MoQTrackInfo {
    val index: UInt
    val name: String
}

data class MoQVideoTrackInfo(
    override val index: UInt,
    val config: VideoConfig,
    val catalog: MoQCatalog,
) : MoQTrackInfo {
    override val name: String get() = config.name
}

data class MoQAudioTrackInfo(
    override val index: UInt,
    val config: AudioConfig,
    val catalog: MoQCatalog,
) : MoQTrackInfo {
    override val name: String get() = config.name
}

data class MoQBroadcastInfo(
    val path: String,
    val videoTracks: List<MoQVideoTrackInfo>,
    val audioTracks: List<MoQAudioTrackInfo>,
)

sealed class MoQBroadcastEvent {
    data class Available(val info: MoQBroadcastInfo) : MoQBroadcastEvent()
    data class Unavailable(val path: String) : MoQBroadcastEvent()
}

// MARK: - Catalog

class MoQCatalog(val handle: UInt) : AutoCloseable {
    fun videoConfig(index: UInt): VideoConfig = moqConsumeVideoConfig(handle, index)
    fun audioConfig(index: UInt): AudioConfig = moqConsumeAudioConfig(handle, index)
    override fun close() { try { moqConsumeCatalogClose(handle) } catch (_: MoqException) {} }
}

/**
 * Returns a Flow<MoQCatalog> that emits a new catalog each time the broadcast's
 * catalog is updated. Each emitted MoQCatalog must be closed by the consumer when no longer needed.
 * Flow is active until the collector cancels.
 */
fun subscribeCatalog(broadcastHandle: UInt): Flow<MoQCatalog> = callbackFlow {
    val callback = object : CatalogCallback {
        override fun onCatalog(catalogId: Int) {
            if (catalogId <= 0) {
                if (catalogId == 0) {
                    channel.close()
                } else {
                    channel.close(MoQSessionException("Catalog subscription closed with error code: $catalogId"))
                }
                return
            }
            trySend(MoQCatalog(catalogId.toUInt()))
        }
    }
    val subscriptionHandle = moqConsumeCatalog(broadcastHandle, callback)
    awaitClose { try { moqConsumeClose(subscriptionHandle) } catch (_: MoqException) {} }
}
