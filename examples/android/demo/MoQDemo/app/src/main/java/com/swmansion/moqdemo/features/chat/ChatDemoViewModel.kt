package com.swmansion.moqdemo.features.chat

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.swmansion.moqkit.Session
import com.swmansion.moqkit.publish.DataTrackEmitter
import com.swmansion.moqkit.publish.Publisher
import com.swmansion.moqkit.subscribe.Broadcast
import com.swmansion.moqkit.subscribe.BroadcastSubscription
import com.swmansion.moqkit.subscribe.TrackDelivery
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class ChatDemoViewModel : ViewModel() {
    var relayUrl by mutableStateOf("http://192.168.92.140:4443")
    var subscribePrefix by mutableStateOf("chat")
    var publishPath by mutableStateOf("chat/android")
    var displayName by mutableStateOf("Android")

    var sessionState by mutableStateOf<Session.State>(Session.State.Idle)
    var statusMessage by mutableStateOf("Not connected")
    var activeBroadcastCount by mutableStateOf(0)
    val messages = mutableStateListOf<ChatMessage>()

    private var session: Session? = null
    private var subscription: BroadcastSubscription? = null
    private var publisher: Publisher? = null
    private var emitter: DataTrackEmitter? = null
    private var activeSubscribePrefix = ""
    private var activePublishPath = ""
    private var activePublishPathKey = ""
    private var activeAnnouncedSelfPathKey = ""
    private var connectionToken = 0L

    private var stateJob: Job? = null
    private var connectJob: Job? = null
    private var broadcastJob: Job? = null
    private val trackJobs = mutableMapOf<String, Job>()

    val canConnect: Boolean
        get() = sessionState is Session.State.Idle ||
            sessionState is Session.State.Error ||
            sessionState is Session.State.Closed

    val canStop: Boolean
        get() = sessionState is Session.State.Connecting ||
            sessionState is Session.State.Connected

    val canSend: Boolean
        get() = sessionState is Session.State.Connected && emitter != null

    fun connect() {
        stop()

        val url = relayUrl.trim()
        val prefix = subscribePrefix.trim()
        val path = publishPath.trim()

        if (url.isEmpty()) {
            sessionState = Session.State.Error("Relay URL is required")
            statusMessage = "Relay URL is required."
            return
        }
        if (prefix.isEmpty()) {
            sessionState = Session.State.Error("Subscribe prefix is required")
            statusMessage = "Subscribe prefix is required."
            return
        }
        if (path.isEmpty()) {
            sessionState = Session.State.Error("Publish path is required")
            statusMessage = "Publish path is required."
            return
        }

        messages.clear()
        activeBroadcastCount = 0
        statusMessage = "Connecting..."
        activeSubscribePrefix = prefix
        activePublishPath = path
        activePublishPathKey = broadcastPathKey(path)
        activeAnnouncedSelfPathKey = announcedPathKeyForPublishPath(
            publishPath = path,
            subscribePrefix = prefix,
        )
        val token = nextConnectionToken()
        cancelSelfTrackJobs(path)

        val newSession = Session(
            url = url,
            parentScope = viewModelScope,
        )
        session = newSession

        stateJob = viewModelScope.launch {
            newSession.state.collect {
                if (!isActiveConnection(token)) return@collect
                sessionState = it
            }
        }

        connectJob = viewModelScope.launch {
            try {
                newSession.connect()
                if (!isActiveConnection(token)) {
                    newSession.close()
                    return@launch
                }

                val newSubscription = newSession.subscribe(prefix)
                if (!isActiveConnection(token)) {
                    newSubscription.close()
                    newSession.close()
                    return@launch
                }
                subscription = newSubscription

                val newEmitter = DataTrackEmitter()
                val newPublisher = Publisher()
                newPublisher.addDataTrack(name = "chat", emitter = newEmitter)
                newSession.publish(path, newPublisher)
                newPublisher.start()
                if (!isActiveConnection(token)) {
                    newSubscription.close()
                    newSession.unpublish(path)
                    newSession.close()
                    return@launch
                }

                emitter = newEmitter
                publisher = newPublisher
                statusMessage = "Listening under $prefix, publishing $path"

                observeBroadcasts(newSubscription, path, token)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!isActiveConnection(token)) {
                    newSession.close()
                    return@launch
                }
                sessionState = Session.State.Error(e.message ?: "Connection failed")
                statusMessage = e.message ?: "Connection failed"
                newSession.close()
            }
        }
    }

    fun send(text: String): Boolean {
        val body = text.trim()
        val name = displayName.trim()

        if (body.isEmpty()) return false
        if (name.isEmpty()) {
            statusMessage = "Display name is required."
            return false
        }

        val currentEmitter = emitter
        if (currentEmitter == null) {
            statusMessage = "Connect before sending messages."
            return false
        }

        return try {
            val payload = ChatPayload(from = name, message = body)
            currentEmitter.send(ChatJson.encode(payload))
            appendMessage(payload, ChatMessage.Direction.Local, activePublishPath)
            true
        } catch (e: Exception) {
            statusMessage = "Send failed: ${e.message ?: "unknown error"}"
            false
        }
    }

    fun stop() {
        connectionToken += 1

        connectJob?.cancel()
        connectJob = null

        stateJob?.cancel()
        stateJob = null

        broadcastJob?.cancel()
        broadcastJob = null

        trackJobs.values.toList().forEach { it.cancel() }
        trackJobs.clear()
        activeBroadcastCount = 0

        subscription?.close()
        subscription = null

        val oldSession = session
        val oldPath = activePublishPath
        session = null
        publisher = null
        emitter = null
        activeSubscribePrefix = ""
        activePublishPath = ""
        activePublishPathKey = ""
        activeAnnouncedSelfPathKey = ""

        if (sessionState !is Session.State.Idle) {
            sessionState = Session.State.Idle
        }
        statusMessage = "Not connected"

        if (oldPath.isNotEmpty()) {
            oldSession?.unpublish(oldPath)
        }
        oldSession?.close()
    }

    private fun observeBroadcasts(
        subscription: BroadcastSubscription,
        publishPath: String,
        token: Long,
    ) {
        broadcastJob?.cancel()
        broadcastJob = viewModelScope.launch {
            try {
                subscription.broadcasts.collect { broadcast ->
                    if (!isActiveConnection(token)) {
                        broadcast.close()
                        return@collect
                    }
                    if (isSelfBroadcast(broadcast.path, publishPath)) {
                        cancelSelfTrackJobs(publishPath)
                        broadcast.close()
                    } else {
                        observeChatTrack(broadcast, token)
                    }
                }
            } catch (_: CancellationException) {
            } catch (e: Exception) {
                if (isActiveConnection(token)) {
                    statusMessage = "Broadcast subscription ended: ${e.message ?: "unknown error"}"
                }
            }
        }
    }

    private fun observeChatTrack(broadcast: Broadcast, token: Long) {
        val path = broadcast.path

        if (!isActiveConnection(token) || isSelfBroadcast(path)) {
            cancelSelfTrackJobs(activePublishPath)
            broadcast.close()
            return
        }

        trackJobs.remove(path)?.cancel()

        val job = viewModelScope.launch {
            try {
                if (!isActiveConnection(token) || isSelfBroadcast(path)) {
                    return@launch
                }

                val trackSubscription = broadcast.subscribeTrack(
                    name = "chat",
                    delivery = TrackDelivery.Arrival,
                )
                try {
                    activeBroadcastCount = trackJobs.size
                    trackSubscription.objects.collect { obj ->
                        if (!isActiveConnection(token) || isSelfBroadcast(path)) {
                            cancelSelfTrackJobs(activePublishPath)
                            return@collect
                        }

                        val payload = try {
                            ChatJson.decode(obj.payload)
                        } catch (_: Exception) {
                            statusMessage = "Ignored invalid chat payload from $path"
                            return@collect
                        }
                        appendMessage(payload, ChatMessage.Direction.Remote, path)
                    }
                } finally {
                    trackSubscription.close()
                }
            } catch (_: CancellationException) {
            } catch (e: Exception) {
                if (isActiveConnection(token)) {
                    statusMessage = "Chat track ended for $path: ${e.message ?: "unknown error"}"
                }
            } finally {
                broadcast.close()
                if (trackJobs[path] === coroutineContext[Job]) {
                    trackJobs.remove(path)
                }
                activeBroadcastCount = trackJobs.size
            }
        }
        trackJobs[path] = job
        activeBroadcastCount = trackJobs.size
    }

    private fun appendMessage(
        payload: ChatPayload,
        direction: ChatMessage.Direction,
        broadcastPath: String,
    ) {
        messages.add(
            ChatMessage(
                direction = direction,
                from = payload.from,
                text = payload.message,
                broadcastPath = broadcastPath,
            ),
        )
    }

    override fun onCleared() {
        super.onCleared()
        stop()
    }

    private fun nextConnectionToken(): Long {
        connectionToken += 1
        return connectionToken
    }

    private fun isActiveConnection(token: Long): Boolean {
        return token == connectionToken
    }

    private fun cancelSelfTrackJobs(publishPath: String) {
        if (publishPath.isBlank()) return

        val selfPaths = trackJobs.keys
            .filter { isSelfBroadcast(it, publishPath) }
            .toList()

        selfPaths.forEach { path ->
            trackJobs.remove(path)?.cancel()
        }
        activeBroadcastCount = trackJobs.size
    }

    private fun isSelfBroadcast(
        broadcastPath: String,
        publishPath: String = activePublishPath,
    ): Boolean {
        val publishKey = broadcastPathKey(publishPath)
        val announcedSelfKey = if (publishPath == activePublishPath) {
            activeAnnouncedSelfPathKey
        } else {
            announcedPathKeyForPublishPath(
                publishPath = publishPath,
                subscribePrefix = activeSubscribePrefix,
            )
        }
        val broadcastKey = broadcastPathKey(broadcastPath)

        return broadcastKey.isNotEmpty() &&
            (broadcastKey == publishKey || broadcastKey == announcedSelfKey)
    }

    private fun broadcastPathKey(path: String): String {
        return path.trim().trim('/')
    }

    private fun announcedPathKeyForPublishPath(
        publishPath: String,
        subscribePrefix: String,
    ): String {
        val publishKey = broadcastPathKey(publishPath)
        val prefixKey = broadcastPathKey(subscribePrefix)
        if (publishKey.isEmpty() || prefixKey.isEmpty()) return publishKey
        if (publishKey == prefixKey) return ""
        return if (publishKey.startsWith("$prefixKey/")) {
            publishKey.removePrefix("$prefixKey/")
        } else {
            publishKey
        }
    }
}
