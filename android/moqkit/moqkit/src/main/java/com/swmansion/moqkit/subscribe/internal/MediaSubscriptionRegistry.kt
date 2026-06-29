package com.swmansion.moqkit.subscribe.internal

import com.swmansion.moqkit.subscribe.MediaContainer
import com.swmansion.moqkit.subscribe.MediaFrame
import com.swmansion.moqkit.subscribe.MediaTrackBufferingPolicy
import com.swmansion.moqkit.subscribe.MediaTrackRequest
import com.swmansion.moqkit.subscribe.internal.playback.toMillisecondsLongClamped
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import uniffi.moq.Container
import uniffi.moq.MoqBroadcastConsumer
import uniffi.moq.MoqFrame
import uniffi.moq.MoqMediaConsumer

internal interface MediaSubscriptionSource {
    fun subscribeMedia(
        name: String,
        container: Container,
        maxLatencyMs: ULong,
    ): MediaConsumerHandle
}

internal interface MediaConsumerHandle : AutoCloseable {
    suspend fun next(): MoqFrame?
    fun cancel()
}

internal class UniFFIMediaSubscriptionSource(
    private val consumerProvider: () -> MoqBroadcastConsumer,
) : MediaSubscriptionSource {
    override fun subscribeMedia(
        name: String,
        container: Container,
        maxLatencyMs: ULong,
    ): MediaConsumerHandle =
        UniFFIMediaConsumerHandle(
            consumerProvider().subscribeMedia(
                name = name,
                container = container,
                maxLatencyMs = maxLatencyMs,
            ),
        )
}

private class UniFFIMediaConsumerHandle(
    private val consumer: MoqMediaConsumer,
) : MediaConsumerHandle {
    override suspend fun next(): MoqFrame? = consumer.next()

    override fun cancel() {
        consumer.cancel()
    }

    override fun close() {
        consumer.close()
    }
}

internal class MediaFrameStream(
    private val channel: Channel<MediaFrameEvent>,
    private val closeHandler: () -> Unit,
) : AutoCloseable {
    private val lock = Any()
    private var closed = false
    private var collectionStarted = false

    val frames: Flow<MediaFrame> = flow {
        markCollectionStarted()
        try {
            for (event in channel) {
                when (event) {
                    is MediaFrameEvent.Frame -> emit(event.frame)
                    is MediaFrameEvent.Error -> throw event.throwable
                }
            }
        } finally {
            close()
        }
    }

    override fun close() {
        val shouldClose = synchronized(lock) {
            if (closed) {
                false
            } else {
                closed = true
                true
            }
        }
        if (!shouldClose) return

        channel.close()
        closeHandler()
    }

    private fun markCollectionStarted() {
        synchronized(lock) {
            check(!closed) { "Media track is closed" }
            check(!collectionStarted) { "Media track supports only a single collector" }
            collectionStarted = true
        }
    }
}

internal sealed class MediaFrameEvent {
    data class Frame(val frame: MediaFrame) : MediaFrameEvent()
    data class Error(val throwable: Throwable) : MediaFrameEvent()
}

private data class MediaSubscriptionKey(
    val name: String,
    val container: MediaContainer,
) {
    constructor(request: MediaTrackRequest) : this(
        name = request.name,
        container = request.container,
    )
}

internal class MediaSubscriptionRegistry(
    private val source: MediaSubscriptionSource,
) : AutoCloseable {
    private val lock = Any()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val subscriptions = mutableMapOf<MediaSubscriptionKey, SharedMediaSubscription>()

    val activeSubscriptionCount: Int
        get() = synchronized(lock) { subscriptions.size }

    fun subscribeMedia(
        request: MediaTrackRequest,
        bufferingPolicy: MediaTrackBufferingPolicy = MediaTrackBufferingPolicy.Unbounded,
    ): MediaFrameStream {
        val key = MediaSubscriptionKey(request)

        return synchronized(lock) {
            val existing = subscriptions[key]
            if (existing != null) {
                existing.subscribe(bufferingPolicy)?.let { return@synchronized it }
                // The finished subscription can still be present before its finish callback runs.
                subscriptions.remove(key)
            }

            val consumer = source.subscribeMedia(
                name = request.name,
                container = request.container.toRawContainer(),
                maxLatencyMs = request.targetBuffering.toMillisecondsLongClamped().toULong(),
            )
            val subscription = SharedMediaSubscription(
                consumer = consumer,
                scope = scope,
                onFinished = { finishedSubscription ->
                    removeSubscription(key, matchingSubscription = finishedSubscription)
                },
            )
            subscriptions[key] = subscription
            subscription.subscribe(bufferingPolicy)
                ?: error("Newly created shared media subscription was unexpectedly finished")
        }
    }

    override fun close() {
        val activeSubscriptions = synchronized(lock) {
            subscriptions.values.toList().also { subscriptions.clear() }
        }
        activeSubscriptions.forEach { it.close() }
        scope.cancel()
    }

    private fun removeSubscription(
        key: MediaSubscriptionKey,
        matchingSubscription: SharedMediaSubscription,
    ) {
        synchronized(lock) {
            if (subscriptions[key] === matchingSubscription) {
                subscriptions.remove(key)
            }
        }
    }
}

private class SharedMediaSubscription(
    private val consumer: MediaConsumerHandle,
    private val scope: CoroutineScope,
    private val onFinished: (SharedMediaSubscription) -> Unit,
) : AutoCloseable {
    private data class Subscriber(
        val id: Long,
        val channel: Channel<MediaFrameEvent>,
    )

    private val lock = Any()
    private val subscribers = mutableMapOf<Long, Channel<MediaFrameEvent>>()
    private var nextSubscriberId = 0L
    private var readJob: Job? = null
    private var finished = false

    fun subscribe(bufferingPolicy: MediaTrackBufferingPolicy): MediaFrameStream? {
        val subscriber = synchronized(lock) {
            if (finished) return null

            val id = nextSubscriberId++
            val channel = makeChannel(bufferingPolicy)
            subscribers[id] = channel

            if (readJob == null) {
                readJob = scope.launch { readFrames() }
            }
            Subscriber(id = id, channel = channel)
        }

        return MediaFrameStream(
            channel = subscriber.channel,
            closeHandler = { removeSubscriber(subscriber.id) },
        )
    }

    override fun close() {
        finishAll(throwing = null, cancelUpstream = true)
    }

    private suspend fun readFrames() {
        try {
            while (true) {
                val rawFrame = consumer.next()
                if (rawFrame == null) {
                    finishAll(throwing = null, cancelUpstream = false)
                    return
                }
                yield(MediaFrame(rawFrame))
            }
        } catch (_: CancellationException) {
            finishAll(throwing = null, cancelUpstream = true)
        } catch (t: Throwable) {
            finishAll(throwing = t, cancelUpstream = true)
        }
    }

    private fun yield(frame: MediaFrame) {
        val channels = synchronized(lock) {
            subscribers.values.toList()
        }
        channels.forEach { channel ->
            channel.trySend(MediaFrameEvent.Frame(frame))
        }
    }

    private fun removeSubscriber(id: Long) {
        val result = synchronized(lock) {
            val channel = subscribers.remove(id)
            if (subscribers.isNotEmpty() || finished) {
                RemoveSubscriberResult(channel = channel, shouldStop = false, job = null)
            } else {
                finished = true
                val job = readJob
                readJob = null
                RemoveSubscriberResult(channel = channel, shouldStop = true, job = job)
            }
        }

        result.channel?.close()
        if (!result.shouldStop) return

        try {
            consumer.cancel()
        } catch (_: Exception) {
        }
        try {
            consumer.close()
        } catch (_: Exception) {
        }
        result.job?.cancel()
        onFinished(this)
    }

    private fun finishAll(throwing: Throwable?, cancelUpstream: Boolean) {
        val result = synchronized(lock) {
            if (finished) {
                FinishAllResult(didFinish = false, channels = emptyList(), job = null)
            } else {
                finished = true
                val channels = subscribers.values.toList()
                subscribers.clear()
                val job = readJob
                readJob = null
                FinishAllResult(didFinish = true, channels = channels, job = job)
            }
        }

        if (!result.didFinish) return

        if (cancelUpstream) {
            try {
                consumer.cancel()
            } catch (_: Exception) {
            }
        }
        try {
            consumer.close()
        } catch (_: Exception) {
        }
        result.job?.cancel()

        result.channels.forEach { channel ->
            if (throwing != null) {
                channel.trySend(MediaFrameEvent.Error(throwing))
            }
            channel.close()
        }
        onFinished(this)
    }

    private fun makeChannel(bufferingPolicy: MediaTrackBufferingPolicy): Channel<MediaFrameEvent> =
        when (bufferingPolicy) {
            MediaTrackBufferingPolicy.Unbounded -> Channel(Channel.UNLIMITED)
            is MediaTrackBufferingPolicy.BufferingNewest -> Channel(
                capacity = maxOf(1, bufferingPolicy.limit),
                onBufferOverflow = BufferOverflow.DROP_OLDEST,
            )
        }

    private data class RemoveSubscriberResult(
        val channel: Channel<MediaFrameEvent>?,
        val shouldStop: Boolean,
        val job: Job?,
    )

    private data class FinishAllResult(
        val didFinish: Boolean,
        val channels: List<Channel<MediaFrameEvent>>,
        val job: Job?,
    )
}
