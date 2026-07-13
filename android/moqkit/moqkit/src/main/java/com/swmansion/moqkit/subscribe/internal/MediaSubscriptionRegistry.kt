package com.swmansion.moqkit.subscribe.internal

import com.swmansion.moqkit.subscribe.MediaContainer
import com.swmansion.moqkit.subscribe.MediaFrame
import com.swmansion.moqkit.subscribe.MediaTrackBufferingPolicy
import com.swmansion.moqkit.subscribe.MediaTrackRequest
import com.swmansion.moqkit.subscribe.internal.playback.toMillisecondsLongClamped
import com.swmansion.moqkit.subscribe.internal.playback.toMicrosecondsLongClamped
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
    private val eventFlow: Flow<MediaFrameEvent>,
    private val cancelBuffer: () -> Unit,
    private val closeHandler: () -> Unit,
) : AutoCloseable {
    private val lock = Any()
    private var closed = false
    private var collectionStarted = false

    internal val events: Flow<MediaFrameEvent> = flow {
        markCollectionStarted()
        try {
            eventFlow.collect { event ->
                if (event is MediaFrameEvent.Error) throw event.throwable
                emit(event)
            }
        } finally {
            close()
        }
    }

    val frames: Flow<MediaFrame> = flow {
        events.collect { event ->
            if (event is MediaFrameEvent.Frame) emit(event.frame)
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

        cancelBuffer()
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

    sealed class Discontinuity : MediaFrameEvent() {
        object BacklogOverflow : Discontinuity()
    }
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

    fun subscribeLiveVideo(
        request: MediaTrackRequest,
        maxBytes: Long = LIVE_VIDEO_MAX_BYTES,
    ): MediaFrameStream {
        val key = MediaSubscriptionKey(request)

        return synchronized(lock) {
            val existing = subscriptions[key]
            if (existing != null) {
                existing.subscribeLiveVideo(
                    maxDurationUs = request.targetBuffering.toMicrosecondsLongClamped(),
                    maxBytes = maxBytes,
                )?.let { return@synchronized it }
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
            subscription.subscribeLiveVideo(
                maxDurationUs = request.targetBuffering.toMicrosecondsLongClamped(),
                maxBytes = maxBytes,
            ) ?: error("Newly created shared media subscription was unexpectedly finished")
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

private const val LIVE_VIDEO_MAX_BYTES = 64L * 1024L * 1024L

private interface SubscriberBuffer {
    val events: Flow<MediaFrameEvent>
    fun offer(frame: MediaFrame)
    fun finish(throwing: Throwable?)
    fun cancel()
}

private class ChannelSubscriberBuffer(
    bufferingPolicy: MediaTrackBufferingPolicy,
) : SubscriberBuffer {
    private val channel = makeChannel(bufferingPolicy)

    override val events: Flow<MediaFrameEvent> = flow {
        for (event in channel) emit(event)
    }

    override fun offer(frame: MediaFrame) {
        channel.trySend(MediaFrameEvent.Frame(frame))
    }

    override fun finish(throwing: Throwable?) {
        if (throwing != null) channel.trySend(MediaFrameEvent.Error(throwing))
        channel.close()
    }

    override fun cancel() {
        channel.close()
    }
}

private class LiveVideoSubscriberBuffer(
    maxDurationUs: Long,
    maxBytes: Long,
) : SubscriberBuffer {
    private sealed class ReadResult {
        data class Event(val event: MediaFrameEvent) : ReadResult()
        data class Finished(val throwing: Throwable?) : ReadResult()
        object Empty : ReadResult()
    }

    private val lock = Any()
    private val buffer = LiveVideoBuffer(maxDurationUs = maxDurationUs, maxBytes = maxBytes)
    private val signal = Channel<Unit>(Channel.CONFLATED)
    private var finished = false
    private var failure: Throwable? = null

    override val events: Flow<MediaFrameEvent> = flow {
        while (true) {
            signal.receiveCatching()
            while (true) {
                when (val result = readNext()) {
                    is ReadResult.Event -> emit(result.event)
                    is ReadResult.Finished -> {
                        result.throwing?.let { throw it }
                        return@flow
                    }
                    ReadResult.Empty -> break
                }
            }
        }
    }

    override fun offer(frame: MediaFrame) {
        val accepted = synchronized(lock) {
            if (finished) false else {
                buffer.offer(frame)
                true
            }
        }
        if (accepted) signal.trySend(Unit)
    }

    override fun finish(throwing: Throwable?) {
        synchronized(lock) {
            if (finished) return
            finished = true
            failure = throwing
        }
        signal.trySend(Unit)
        signal.close()
    }

    override fun cancel() {
        synchronized(lock) {
            buffer.clear()
            finished = true
            failure = null
        }
        signal.close()
    }

    private fun readNext(): ReadResult = synchronized(lock) {
        buffer.poll()?.let { return@synchronized ReadResult.Event(it) }
        if (finished) ReadResult.Finished(failure) else ReadResult.Empty
    }
}

private class SharedMediaSubscription(
    private val consumer: MediaConsumerHandle,
    private val scope: CoroutineScope,
    private val onFinished: (SharedMediaSubscription) -> Unit,
) : AutoCloseable {
    private data class Subscriber(
        val id: Long,
        val buffer: SubscriberBuffer,
    )

    private val lock = Any()
    private val subscribers = mutableMapOf<Long, SubscriberBuffer>()
    private var nextSubscriberId = 0L
    private var readJob: Job? = null
    private var finished = false

    fun subscribe(bufferingPolicy: MediaTrackBufferingPolicy): MediaFrameStream? {
        return subscribe(ChannelSubscriberBuffer(bufferingPolicy))
    }

    fun subscribeLiveVideo(maxDurationUs: Long, maxBytes: Long): MediaFrameStream? {
        return subscribe(LiveVideoSubscriberBuffer(maxDurationUs, maxBytes))
    }

    private fun subscribe(buffer: SubscriberBuffer): MediaFrameStream? {
        val subscriber = synchronized(lock) {
            if (finished) return null

            val id = nextSubscriberId++
            subscribers[id] = buffer

            if (readJob == null) {
                readJob = scope.launch { readFrames() }
            }
            Subscriber(id = id, buffer = buffer)
        }

        return MediaFrameStream(
            eventFlow = subscriber.buffer.events,
            cancelBuffer = subscriber.buffer::cancel,
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
        val buffers = synchronized(lock) {
            subscribers.values.toList()
        }
        buffers.forEach { it.offer(frame) }
    }

    private fun removeSubscriber(id: Long) {
        val result = synchronized(lock) {
            val buffer = subscribers.remove(id)
            if (subscribers.isNotEmpty() || finished) {
                RemoveSubscriberResult(buffer = buffer, shouldStop = false, job = null)
            } else {
                finished = true
                val job = readJob
                readJob = null
                RemoveSubscriberResult(buffer = buffer, shouldStop = true, job = job)
            }
        }

        result.buffer?.cancel()
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
                FinishAllResult(didFinish = false, buffers = emptyList(), job = null)
            } else {
                finished = true
                val buffers = subscribers.values.toList()
                subscribers.clear()
                val job = readJob
                readJob = null
                FinishAllResult(didFinish = true, buffers = buffers, job = job)
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

        result.buffers.forEach { it.finish(throwing) }
        onFinished(this)
    }

    private data class RemoveSubscriberResult(
        val buffer: SubscriberBuffer?,
        val shouldStop: Boolean,
        val job: Job?,
    )

    private data class FinishAllResult(
        val didFinish: Boolean,
        val buffers: List<SubscriberBuffer>,
        val job: Job?,
    )
}

private fun makeChannel(bufferingPolicy: MediaTrackBufferingPolicy): Channel<MediaFrameEvent> =
    when (bufferingPolicy) {
        MediaTrackBufferingPolicy.Unbounded -> Channel(Channel.UNLIMITED)
        is MediaTrackBufferingPolicy.BufferingNewest -> Channel(
            capacity = maxOf(1, bufferingPolicy.limit),
            onBufferOverflow = BufferOverflow.DROP_OLDEST,
        )
    }
