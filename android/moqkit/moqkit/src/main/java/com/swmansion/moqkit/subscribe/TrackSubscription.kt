package com.swmansion.moqkit.subscribe

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.coroutines.flow.flow
import uniffi.moq.MoqGroupConsumer
import uniffi.moq.MoqTrackConsumer

/**
 * How raw MoQ track groups should be delivered.
 */
enum class TrackDelivery {
    /**
     * Delivers groups with monotonically increasing sequence numbers.
     *
     * Late groups are skipped. Use this for live data where newer messages are more useful
     * than replaying old ones.
     */
    Monotonic,

    /**
     * Delivers groups in arrival order.
     *
     * Sequence numbers may move backwards. Use this when every received group should be
     * delivered to the app.
     */
    Arrival,
}

/**
 * A raw object received from a MoQ track.
 *
 * @property payload Application-defined binary payload.
 * @property groupSequence Sequence number of the group that carried this object.
 * @property objectIndex Object position within the group.
 */
data class TrackObject(
    val payload: ByteArray,
    val groupSequence: ULong,
    val objectIndex: ULong,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TrackObject) return false

        return payload.contentEquals(other.payload) &&
            groupSequence == other.groupSequence &&
            objectIndex == other.objectIndex
    }

    override fun hashCode(): Int {
        var result = payload.contentHashCode()
        result = 31 * result + groupSequence.hashCode()
        result = 31 * result + objectIndex.hashCode()
        return result
    }
}

/**
 * A subscription to a raw MoQ track.
 *
 * Unlike [Player], this reads unparsed MoQ objects and does not require the track to appear
 * in a broadcast catalog.
 *
 * A track subscription supports a single active collector. Call [close] when the app no
 * longer needs the track.
 */
class TrackSubscription internal constructor(
    private val name: String,
    private val owner: BroadcastOwner,
    private val track: MoqTrackConsumer,
    private val delivery: TrackDelivery,
) : AutoCloseable {
    private val lock = Any()
    private var closed = false
    private var collectionStarted = false

    /**
     * Emits raw objects from the track until the track ends or [close] is called.
     *
     * A subscription supports a single active collector because it is backed by one UniFFI
     * track stream.
     */
    val objects: Flow<TrackObject> = flow {
        markCollectionStarted()

        try {
            while (true) {
                val group = nextGroup() ?: break
                try {
                    emitGroupObjects(group)
                } finally {
                    try {
                        group.cancel()
                    } catch (_: Exception) {
                    }
                    try {
                        group.close()
                    } catch (_: Exception) {
                    }
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (!isClosed) {
                throw e
            }
        } finally {
            close()
        }
    }

    /**
     * Whether this subscription has been closed.
     */
    val isClosed: Boolean
        get() = synchronized(lock) { closed }

    /**
     * Stops receiving objects and releases the underlying track subscription.
     */
    override fun close() {
        val shouldRelease = synchronized(lock) {
            if (closed) {
                false
            } else {
                closed = true
                true
            }
        }

        if (shouldRelease) {
            try {
                track.cancel()
            } catch (_: Exception) {
            }
            try {
                track.close()
            } catch (_: Exception) {
            }
            owner.release()
        }
    }

    private fun markCollectionStarted() {
        synchronized(lock) {
            check(!closed) { "Track subscription '$name' is closed" }
            check(!collectionStarted) {
                "Track subscription '$name' supports only a single collector"
            }
            collectionStarted = true
        }
    }

    private suspend fun nextGroup(): MoqGroupConsumer? = when (delivery) {
        TrackDelivery.Monotonic -> track.nextGroup()
        TrackDelivery.Arrival -> track.recvGroup()
    }

    private suspend fun FlowCollector<TrackObject>.emitGroupObjects(
        group: MoqGroupConsumer,
    ) {
        val sequence = group.sequence()
        var objectIndex = 0uL

        while (true) {
            val payload = group.readFrame() ?: break
            emit(
                TrackObject(
                    payload = payload,
                    groupSequence = sequence,
                    objectIndex = objectIndex,
                ),
            )
            objectIndex += 1uL
        }
    }
}
