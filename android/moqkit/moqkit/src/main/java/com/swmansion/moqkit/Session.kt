package com.swmansion.moqkit

import android.util.Log
import com.swmansion.moqkit.publish.Publisher
import com.swmansion.moqkit.subscribe.BroadcastSubscription
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import uniffi.moq.MoqClient
import uniffi.moq.MoqOriginProducer
import uniffi.moq.MoqSession as UniMoqSession

/**
 * A QUIC connection to a MOQ relay used for publishing and creating broadcast subscriptions.
 *
 * ### Lifecycle
 * 1. Create a session with the relay [url].
 * 2. Call [connect] (suspend) to establish the QUIC connection.
 * 3. Call [subscribe] to discover live broadcasts, and/or [publish] to publish media.
 * 4. Call [close] to tear down the connection and free all resources.
 *
 * @param url WebTransport URL of the MOQ relay (e.g. `"https://relay.example.com:4443/moq"`).
 * @param parentScope Coroutine scope whose lifetime bounds the session. Defaults to a new
 *   IO-dispatched scope with a [SupervisorJob].
 */
class Session(
    private val url: String,
    parentScope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
) {
    companion object {
        private const val TAG = "Session"
    }

    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob())

    /** Connection state machine for this session. */
    sealed class State {
        /** Session has not been started yet. */
        object Idle : State()
        /** QUIC handshake is in progress. */
        object Connecting : State()
        /** Handshake complete; the session may now publish and subscribe. */
        object Connected : State()
        /** The session ended due to a transport or protocol error.
         * @property message Human-readable error description. */
        data class Error(val message: String) : State()
        /** [Session.close] was called and all resources have been released. */
        object Closed : State()
    }

    private val _state = MutableStateFlow<State>(State.Idle)

    /**
     * Current connection state. Starts at [State.Idle] and progresses through
     * [State.Connecting] → [State.Connected] → [State.Closed] (or [State.Error]).
     */
    val state: StateFlow<State> = _state.asStateFlow()

    private var session: UniMoqSession? = null
    private var client: MoqClient? = null
    private var consumeOrigin: MoqOriginProducer? = null
    private var publishOrigin: MoqOriginProducer? = null
    private var monitorJob: Job? = null

    private val activeSubscriptions = mutableMapOf<String, BroadcastSubscription>()
    private val activePublishers = mutableMapOf<String, Publisher>()

    /**
     * Opens the QUIC connection.
     *
     * Suspends until the handshake is complete. Once this function returns, [state] is
     * [State.Connected] and the session may publish or create broadcast subscriptions.
     *
     * @throws IllegalStateException if called on a session that has already been started.
     * @throws Exception if the connection attempt fails (state becomes [State.Error]).
     */
    suspend fun connect() {
        check(_state.value == State.Idle) { "Session already started" }
        _state.value = State.Connecting
        Log.d(TAG, "Connecting to $url")
        try {
            val newConsumeOrigin = MoqOriginProducer()
            consumeOrigin = newConsumeOrigin
            Log.d(TAG, "Consume origin created")

            val newPublishOrigin = MoqOriginProducer()
            publishOrigin = newPublishOrigin
            Log.d(TAG, "Publish origin created")

            val newClient = MoqClient()
            newClient.setTlsDisableVerify(true)
            client = newClient
            newClient.setConsume(newConsumeOrigin)
            newClient.setPublish(newPublishOrigin)

            val newSession = newClient.connect(url)
            session = newSession
            _state.value = State.Connected
            Log.d(TAG, "Connected successfully")

            monitorJob = scope.launch {
                try {
                    newSession.closed()
                } catch (e: Exception) {
                    Log.w(TAG, "Session closed with error: $e")
                    _state.compareAndSet(State.Connected, State.Error("Session ended: $e"))
                    close()
                    return@launch
                }

                if (_state.value == State.Connected) {
                    Log.w(TAG, "Session ended unexpectedly")
                    _state.value = State.Error("Session ended unexpectedly")
                    close()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Connection failed: ${e.message}", e)
            _state.value = State.Error(e.message ?: "Connection failed")
            tearDown()
            throw e
        }
    }

    /**
     * Starts watching for broadcast announcements under the supplied prefix.
     *
     * @param prefix Only broadcasts whose path starts with this string will be surfaced.
     *   Pass `""` (the default) to receive all broadcasts.
     * @throws IllegalStateException if the session is not connected or the exact prefix
     *   already has an active subscription.
     */
    fun subscribe(prefix: String = ""): BroadcastSubscription {
        check(_state.value == State.Connected) { "Session must be connected before subscribing" }

        return synchronized(activeSubscriptions) {
            check(_state.value == State.Connected) {
                "Session must be connected before subscribing"
            }

            val existing = activeSubscriptions[prefix]
            check(existing == null || existing.isClosed) {
                "Already subscribed to prefix '$prefix'"
            }

            val sessionConsumeOrigin = consumeOrigin
                ?: error("Consume origin not available")
            val originConsumer = sessionConsumeOrigin.consume()
            try {
                val announced = originConsumer.announced(prefix)
                var subscriptionRef: BroadcastSubscription? = null
                val subscription = BroadcastSubscription(
                    prefix = prefix,
                    originConsumer = originConsumer,
                    announced = announced,
                    onClosed = {
                        synchronized(activeSubscriptions) {
                            if (activeSubscriptions[prefix] === subscriptionRef) {
                                activeSubscriptions.remove(prefix)
                            }
                        }
                    },
                )
                subscriptionRef = subscription
                activeSubscriptions[prefix] = subscription
                subscription
            } catch (t: Throwable) {
                try {
                    originConsumer.close()
                } catch (closeError: Exception) {
                    Log.w(TAG, "Failed to close origin consumer for prefix '$prefix'", closeError)
                }
                throw t
            }
        }
    }

    /**
     * Publish a broadcast to the relay at the given path.
     *
     * The publisher's broadcast is registered with the relay. Call [Publisher.start] after
     * this to begin encoding and sending frames.
     *
     * @param path Broadcast path on the relay (e.g. `"live/my-stream"`).
     * @param publisher A configured [Publisher] with at least one track added.
     * @throws IllegalStateException if the session is not connected.
     */
    fun publish(path: String, publisher: Publisher) {
        check(_state.value == State.Connected) { "Session must be connected before publishing" }
        check(!activePublishers.containsKey(path)) {
            "Already publishing at '$path'. Call unpublish() first."
        }
        val origin = publishOrigin ?: error("Publish origin not available")
        Log.d(TAG, "Publishing broadcast at '$path'")
        origin.publish(path, publisher.broadcast)
        activePublishers[path] = publisher
    }

    /**
     * Stop publishing at the given path. Calls [Publisher.stop] on the associated publisher.
     */
    fun unpublish(path: String) {
        val publisher = activePublishers.remove(path) ?: return
        Log.d(TAG, "Unpublishing broadcast at '$path'")
        publisher.stop()
    }

    /**
     * Closes the session and releases all resources.
     *
     * Safe to call from any thread. No-op if the session is already [State.Closed].
     * After this returns, [state] is [State.Closed] and the coroutine scope is cancelled.
     */
    fun close() {
        val wasConnected = _state.compareAndSet(State.Connected, State.Closed)
        val wasConnecting = if (!wasConnected) {
            _state.compareAndSet(State.Connecting, State.Closed)
        } else {
            false
        }
        val wasError = if (!wasConnected && !wasConnecting) {
            val current = _state.value
            if (current is State.Error) {
                _state.compareAndSet(current, State.Closed)
            } else {
                false
            }
        } else {
            false
        }

        if (!wasConnected && !wasConnecting && !wasError) {
            Log.d(TAG, "close() called but already in state ${_state.value}")
            return
        }

        Log.d(
            TAG,
            "Closing session (was: connected=$wasConnected connecting=$wasConnecting error=$wasError)",
        )
        tearDown()
    }

    private fun tearDown() {
        val subscriptions = synchronized(activeSubscriptions) {
            activeSubscriptions.values.toList().also { activeSubscriptions.clear() }
        }
        Log.d(TAG, "Tearing down: ${subscriptions.size} active subscriptions")

        subscriptions.forEach { subscription ->
            try {
                subscription.close()
            } catch (e: Exception) {
                Log.w(TAG, "Failed to close broadcast subscription '${subscription.prefix}'", e)
            }
        }

        activePublishers.values.forEach { publisher ->
            try {
                publisher.stop()
            } catch (e: Exception) {
                Log.w(TAG, "Failed to stop publisher during teardown", e)
            }
        }
        activePublishers.clear()

        monitorJob?.cancel()
        monitorJob = null

        session?.cancel(0u)
        try {
            session?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to close session", e)
        }
        session = null

        client?.cancel()
        try {
            client?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to close client", e)
        }
        client = null

        try {
            publishOrigin?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to close publish origin", e)
        }
        publishOrigin = null

        try {
            consumeOrigin?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to close consume origin", e)
        }
        consumeOrigin = null

        scope.cancel()
        Log.d(TAG, "Teardown complete")
    }
}
